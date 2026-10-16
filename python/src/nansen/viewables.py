"""Data viewed without a project: what `nansen view` and nansen.view are given, as dev's imviewer(array),
imviewer(file), signalviewer and roimanager opened from the command line.

A viewable is an image stack (a file any stack adapter reads, or an array) with its ROIs, or frames x N signals. The
Api serves frames (view.frame), ROI signals (view.signal) and traces (view.traces) of viewables only, each named by
its id: viewables are registered from Python, never by a request, so the page reads no file the user did not hand
over. ROIs drawn and edited on a stack (view.updateRois) are saved to its ROI file: the .json ROI file it was given,
else <stem>_rois.json beside its file (dev's roimanager saves <stem>_rois.mat there), which is read again when the
same file is viewed with no ROIs given; an array's are kept in memory. A method of the built-in modules runs on a
stack (view.run, as dev's imviewer runs Align Images and roimanager its autosegmentation): what it saves is written
beside the stack's file as <stem>_<variable>.npy or .json, and the stacks and ROIs among it are registered as
viewables too. MATLAB's nansen.Viewables does the same.
"""

from __future__ import annotations

import tempfile
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple, Union

from . import devyaml
from .adapters import AdapterRegistry
from .errors import NansenError
from .methods import Method
from .stacks import Stack, StackWriter, as_stack

PathOrValue = Union[str, Path, Any]

ROI_FILE_END = "_rois.json"   # a stack file's ROIs, when it was given none: <stem>_rois.json beside it


def built_in_adapters() -> AdapterRegistry:
    """The built-in file adapters and those of the modules that ship with NANSEN (ophys reads TIFF, SciScan raw,
    HDF5, video, ...): what a file is read with when no project is open."""
    from .modules import available_modules

    registry = AdapterRegistry()
    for module in reversed(available_modules(None)):
        for document in module.file_adapter_documents():
            registry.declare(document, module.python_root)
    return registry


def roi_file_beside(path: Path) -> Path:
    """Where the ROIs of a stack file are saved when it was given no ROI file: <stem>_rois.json beside it."""
    return path.with_name(path.stem + ROI_FILE_END)


def _is_path(value: Any) -> bool:
    return isinstance(value, (str, Path))


def _is_array(value: Any) -> bool:
    """An array of numbers or truth values, more than one: saved as .npy (as Project.save makes a variable), else .json."""
    import numpy as np
    return isinstance(value, np.ndarray) and value.size > 1 and value.dtype.kind in "biuf"


def _frame_rate(value: Any) -> Optional[float]:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not value > 0 or value == float("inf"):
        raise NansenError("invalid-params", "frame rate is a positive number of frames per second")
    return float(value)


class Viewable:
    """One thing to view: kind "stack" (stack, rois) or "signals" (signals: frames x N)."""

    def __init__(self, viewable_id: str, kind: str, name: str, path: Optional[Path] = None, frame_rate: Optional[float] = None):
        self.id = viewable_id
        self.kind = kind
        self.name = name
        self.path = path
        self.frame_rate = frame_rate
        self.stacks: Dict[str, Stack] = {}   # adapter id ("" for an array) -> the stack it read
        self.adapter = ""
        self.adapters: List[str] = []
        self.rois: Optional[dict] = None
        self.roi_file: Optional[Path] = None   # where ROI edits are saved; None: kept in memory (an array's)
        self.origin = ""   # "<viewable id>/<variable>" for what a method run on a viewable saved (view.run)
        self.signals: Any = None

    def summary(self) -> dict:
        return {"id": self.id, "kind": self.kind, "name": self.name, "path": str(self.path) if self.path else "",
                "rois": self.rois is not None, "roiFile": str(self.roi_file) if self.roi_file else ""}

    def metadata(self, stack: Stack) -> dict:
        metadata = dict(stack.metadata)
        if self.frame_rate is not None and "frameRate" not in metadata:
            metadata["frameRate"] = self.frame_rate
        return metadata

    def rate(self) -> Optional[float]:
        """Frames per second: the one given, else what the stack's files tell."""
        if self.frame_rate is not None:
            return self.frame_rate
        stack = self.stacks.get(self.adapter)
        rate = stack.metadata.get("frameRate") if stack is not None else None
        return float(rate) if isinstance(rate, (int, float)) and not isinstance(rate, bool) and rate > 0 else None


class Viewables:
    """The viewables of one app: an allow-list of files and arrays, by id (v1, v2, ...)."""

    def __init__(self, adapters: Optional[AdapterRegistry] = None):
        self._items: Dict[str, Viewable] = {}
        self._adapters = adapters
        self._methods: Optional[List[Method]] = None

    @property
    def adapters(self) -> AdapterRegistry:
        if self._adapters is None:
            self._adapters = built_in_adapters()
        return self._adapters

    def __len__(self) -> int:
        return len(self._items)

    def _next_id(self) -> str:
        return f"v{len(self._items) + 1}"

    def list(self) -> List[dict]:
        return [v.summary() for v in self._items.values()]

    def get(self, viewable_id: Any) -> Viewable:
        if not isinstance(viewable_id, str) or viewable_id not in self._items:
            raise NansenError("unknown-viewable", f"nothing to view is registered as {viewable_id!r}")
        return self._items[viewable_id]

    # -- registering ---------------------------------------------------------------------------------------------

    def add_stack(self, data: PathOrValue, name: Optional[str] = None, rois: Optional[PathOrValue] = None,
                  adapter: Optional[str] = None, frame_rate: Optional[float] = None) -> str:
        """Register an image stack: a file (read with the adapter given, or the first stack adapter of its extension
        that opens it) or an array, height x width (x channels (x planes)) x frames. rois is an ROI file (.json as
        ophys saves ROIs, or a file an RoiArray adapter reads, such as dev's roimanager .mat) or an ROI document.
        ROI edits are saved to a .json ROI file given, to the same name as .json beside any other ROI file, and else
        to <stem>_rois.json beside the stack's file, which is read when it is there and no ROIs are given; an
        array's are kept in memory. Returns the id."""
        viewable = Viewable(self._next_id(), "stack", name or "", frame_rate=_frame_rate(frame_rate))
        if _is_path(data):
            path = Path(data).expanduser().resolve()
            if not path.is_file():
                raise NansenError("file-not-found", f"{path} is not a file")
            viewable.path = path
            viewable.name = viewable.name or path.name
            viewable.adapters = self.adapters.for_stacks(path.suffix)
            stack, viewable.adapter = self._open_file(path, adapter, viewable.adapters)
            viewable.stacks[viewable.adapter] = stack
        else:
            viewable.name = viewable.name or "array"
            viewable.stacks[""] = _array_stack(data)
        if rois is not None:
            viewable.rois = self._read_rois(rois)
            if _is_path(rois):
                given = Path(rois).expanduser().resolve()
                viewable.roi_file = given if given.suffix.lower() == ".json" else given.with_suffix(".json")
            elif viewable.path is not None:
                viewable.roi_file = roi_file_beside(viewable.path)
        elif viewable.path is not None:
            viewable.roi_file = roi_file_beside(viewable.path)
            if viewable.roi_file.is_file():   # saved when the file was viewed before (view.updateRois)
                viewable.rois = self._read_rois(viewable.roi_file)
        self._items[viewable.id] = viewable
        return viewable.id

    def add_signals(self, data: PathOrValue, name: Optional[str] = None, variable: Optional[str] = None,
                    frame_rate: Optional[float] = None) -> str:
        """Register signals, frames x N (a vector is one): an array, a .npy file, or a variable of a .mat file (the
        one named, or its only numeric array). Returns the id."""
        import numpy as np

        viewable = Viewable(self._next_id(), "signals", name or "", frame_rate=_frame_rate(frame_rate))
        if _is_path(data):
            path = Path(data).expanduser().resolve()
            if not path.is_file():
                raise NansenError("file-not-found", f"{path} is not a file")
            viewable.path = path
            suffix = path.suffix.lower()
            if suffix == ".npy":
                value = self.adapters.get("npy").read(path)
            elif suffix == ".mat":
                value = _pick_variable(self.adapters.get("mat").read(path), variable, path.name)
            else:
                raise NansenError("unsupported-file", f"signals are read from .npy and .mat files, not {suffix or 'these'} files")
            viewable.name = viewable.name or (path.stem + (f".{variable}" if variable else ""))
        else:
            value = data
            viewable.name = viewable.name or "signals"
        array = np.asarray(value)
        if array.dtype.kind not in "biuf" or array.ndim not in (1, 2) or array.size == 0:
            raise NansenError("invalid-data", f"{viewable.name} is not a frames x signals array")
        viewable.signals = array
        self._items[viewable.id] = viewable
        return viewable.id

    # -- reading -------------------------------------------------------------------------------------------------

    def stack(self, viewable: Viewable, adapter: Optional[str] = None) -> Tuple[Stack, str]:
        """The viewable's stack, read with the adapter asked for: one of those that read its extension as stacks."""
        if viewable.kind != "stack":
            raise NansenError("invalid-params", f"{viewable.name} is signals, not an image stack")
        if not adapter or adapter == viewable.adapter:
            return viewable.stacks[viewable.adapter], viewable.adapter
        if viewable.path is None or adapter not in viewable.adapters:
            raise NansenError("invalid-params", f"{viewable.name} is read with one of: {', '.join(viewable.adapters) or 'none'}")
        if adapter not in viewable.stacks:
            viewable.stacks[adapter], _ = self._open_file(viewable.path, adapter, viewable.adapters)
        return viewable.stacks[adapter], adapter

    def _open_file(self, path: Path, adapter_id: Optional[str], candidates: Sequence[str]) -> Tuple[Stack, str]:
        tries = [adapter_id] if adapter_id else list(candidates)
        if not tries:
            raise NansenError("unsupported-file", f"no file adapter reads {path.suffix or 'these'} files as image stacks")
        problems = []
        for candidate in tries:
            adapter = self.adapters.get(candidate)
            try:
                stack = as_stack(adapter.open([path]) if hasattr(adapter, "open") else adapter.read(path))
            except NansenError as error:
                if adapter_id:
                    raise
                problems.append(f"{candidate}: {error.message}")
                continue
            return devyaml.with_sidecar(_image_stack(stack, path.name), path), candidate   # and dev's metadata file
        raise NansenError("invalid-data", f"{path.name} could not be read as a stack: " + "; ".join(problems))

    def _read_rois(self, rois: PathOrValue) -> dict:
        from .frames import roi_outlines

        if _is_path(rois):
            path = Path(rois).expanduser().resolve()
            if not path.is_file():
                raise NansenError("file-not-found", f"{path} is not a file")
            candidates = self.adapters.for_rois(path.suffix)
            if not candidates:
                raise NansenError("unsupported-file", f"no file adapter reads {path.suffix or 'these'} files as ROIs")
            problems = []
            for candidate in candidates:
                try:
                    value = self.adapters.get(candidate).read(path)
                    roi_outlines(value)
                except NansenError as error:
                    problems.append(f"{candidate}: {error.message}")
                    continue
                return value
            raise NansenError("invalid-data", f"{path.name} could not be read as ROIs: " + "; ".join(problems))
        roi_outlines(rois)   # an ROI document: {rois: [{pixels, ...}]}
        return rois

    # -- changing ROIs and running methods -------------------------------------------------------------------------

    def save_rois(self, viewable: Viewable, document: Any) -> str:
        """The stack's ROIs from now on, written to its ROI file (as ophys saves ROIs); returns the file, "" for an
        array's, kept in memory."""
        viewable.rois = document
        if viewable.roi_file is None:
            return ""
        self.adapters.get("json").write(viewable.roi_file, document)
        return str(viewable.roi_file)

    def _all_methods(self) -> List[Method]:
        if self._methods is None:
            from .modules import available_modules

            found: Dict[str, Method] = {}
            for module in available_modules(None):
                for method in module.methods():
                    found.setdefault(method.id, method)
            self._methods = list(found.values())
        return self._methods

    def methods(self) -> List[Method]:
        """The methods view.run runs on a stack: those of the built-in modules that run on any entity type, read the
        stack their stack option names, and have a Python implementation."""
        return [m for m in self._all_methods() if _runs_on_stacks(m) and "python" in m.languages]

    def method(self, method_id: Any) -> Method:
        for method in self._all_methods():
            if method.id == method_id:
                return method
        raise NansenError("unknown-method", f"no built-in method {method_id!r}")

    def preset(self, method: Method, name: str) -> dict:
        """A preset of a built-in method: its defaults ("default"), or one its module ships."""
        from .modules import available_modules

        if name == "default":
            return method.default_options()
        for module in available_modules(None):
            for document in module.preset_documents():
                if document["method"]["id"] == method.id and document["name"] == name:
                    return document["values"]
        raise NansenError("unknown-preset", f"method {method.id!r} has no preset {name!r}")

    def run(self, viewable: Viewable, method_id: Any, options: Optional[dict] = None, preset: Optional[str] = None) -> dict:
        """Run a built-in method on a stack, now: {result, log, outputs[{variable, path, kind, viewable}]}. The variable
        its stack option names is the viewable's stack, and the one its rois option names (extract_signals', ...) its
        ROIs; what it saves is written beside the stack's file as
        <stem>_<variable>.npy or .json (kept in memory for an array), and registered: a stack (3 or more dimensions)
        as a stack, ROIs as the viewable's stack with those ROIs, saved to that file. What one run saved replaces what
        the run before it saved to the same variable, under the same id. A run that stops starts over."""
        from .entities import Entity
        from .methods import MethodContext, run_method
        from .tasks import _json_result

        if viewable.kind != "stack":
            raise NansenError("invalid-params", f"{viewable.name} is signals; methods run on image stacks")
        method = self.method(method_id)
        if method.entity_type != "*":
            raise NansenError("wrong-entity-type", f"{method.id} runs on {method.entity_type}, not on a stack viewed without a project")
        if not _runs_on_stacks(method):
            raise NansenError("invalid-params", f"{method.id} reads no stack (it has no stack option), so it cannot run on {viewable.name}")
        if options is not None and not isinstance(options, dict):
            raise NansenError("invalid-params", "options is an object of option values")
        values = self.preset(method, preset) if preset else {}
        if options:
            values = dict(values, **options)
        resolved = method.resolve_options(values)
        sandbox = ViewableProject(self, viewable, resolved["stack"],
                                  resolved.get("rois") if "rois" in method.options_schema["properties"] else None)
        context = MethodContext(project=sandbox, method=method)
        results = run_method(method, [Entity("viewable", {"viewable": viewable.id})], values, context)
        outputs = [self._add_output(viewable, name, path, value) for name, (path, value) in sandbox.outputs.items()]
        return {"result": _json_result(results[0]), "log": list(context.lines), "outputs": outputs}

    def _add_output(self, source: Viewable, variable: str, path: Optional[Path], value: Any) -> dict:
        """Register what a run saved, when it is a stack or ROIs: the entry of view.run's outputs."""
        from .frames import roi_outlines

        stack, kind = None, "data"
        if path is not None and path.suffix == ".npy" and value is None:
            stack = as_stack(self.adapters.get("npy").open([path]))
        elif value is not None and _is_array(value):
            stack = as_stack(value)
        if stack is not None and stack.ndim >= 3:
            kind = "stack"
        elif isinstance(value, dict) and isinstance(value.get("rois"), list):
            try:
                roi_outlines(value)
                kind = "rois"
            except NansenError:
                pass
        entry = {"variable": variable, "path": str(path) if path else "", "kind": kind, "viewable": ""}
        if kind == "data":
            return entry
        origin = f"{source.id}/{variable}"
        existing = next((v for v in self._items.values() if v.origin == origin), None)
        viewable = Viewable(existing.id if existing else self._next_id(), "stack", f"{source.name} · {variable}",
                            frame_rate=source.frame_rate)
        viewable.origin = origin
        if kind == "stack":
            stack = _image_stack(stack, viewable.name)
            if not stack.metadata:   # an aligned stack keeps what the recording's files tell (pixel size, frame rate)
                stack.metadata = dict(source.stacks[source.adapter].metadata)
            viewable.path = path
            viewable.adapter = "npy" if path is not None else ""
            viewable.adapters = self.adapters.for_stacks(".npy") if path is not None else []
            viewable.stacks[viewable.adapter] = stack
            if path is not None:
                viewable.roi_file = roi_file_beside(path)
                if viewable.roi_file.is_file():
                    viewable.rois = self._read_rois(viewable.roi_file)
        else:   # ROIs found in the stack: shown over it, edits saved to their file
            viewable.path, viewable.adapter, viewable.adapters = source.path, source.adapter, list(source.adapters)
            viewable.stacks = dict(source.stacks)
            viewable.rois, viewable.roi_file = value, path
        self._items[viewable.id] = viewable
        entry["viewable"] = viewable.id
        return entry


def _runs_on_stacks(method: Method) -> bool:
    """A method view.run runs: of any entity type, with a stack option naming the stack it reads."""
    return method.entity_type == "*" and "stack" in method.options_schema.get("properties", {})


class ViewableProject:
    """A project as a method run on a viewable sees it (view.run). The variable named by its stack option is the
    viewable's stack, and the one its rois option names, when it has one, the viewable's ROIs; what it saves (save, a stack writer) is written beside the stack's file as <stem>_<name>.npy (an
    array of numbers or truth values, more than one) or <stem>_<name>.json (anything else), and read back from there;
    for an array, it is kept in memory. Nothing else is there to read (data-not-found). No progress is kept: a run
    that stops starts over. MATLAB's nansen.internal.ViewableProject does the same."""

    def __init__(self, viewables: Viewables, viewable: Viewable, stack_name: str, rois_name: Optional[str] = None):
        self._viewables = viewables
        self._viewable = viewable
        self._stack_name = stack_name
        self._rois_name = rois_name
        self.outputs: Dict[str, Tuple[Optional[Path], Any]] = {}   # name -> (file, or None; value, or None: in the file)
        self.stack_frame_limit = None
        self._scratch: Optional[str] = None

    @property
    def adapters(self) -> AdapterRegistry:
        return self._viewables.adapters

    @property
    def folder(self) -> Path:
        """Where relative paths a method is given lead: the stack's folder; a folder of its own for an array."""
        if self._viewable.path is not None:
            return self._viewable.path.parent
        if self._scratch is None:
            self._scratch = tempfile.mkdtemp(prefix="nansen-view-")
        return Path(self._scratch)

    def _output_path(self, name: str, array: bool) -> Optional[Path]:
        if self._viewable.path is None:
            return None
        path = self._viewable.path
        return path.with_name(f"{path.stem}_{name}{'.npy' if array else '.json'}")

    def open_stack(self, entity, name: str, frames=None) -> Stack:
        if name in self.outputs:
            path, value = self.outputs[name]
            stack = as_stack(value if value is not None else self.adapters.get("npy").open([path]))
        elif name == self._stack_name:
            stack, _ = self._viewables.stack(self._viewable)
        else:
            raise NansenError("data-not-found", f"{self._viewable.name} has no {name!r}: a method run on it reads its stack, as {self._stack_name!r}")
        return stack if frames is None else stack.cut(*frames)

    def load(self, entity, name: str, cached: bool = True) -> Any:
        import numpy as np

        if name in self.outputs:
            path, value = self.outputs[name]
            if value is not None:
                return value
            return self.adapters.get("npy" if path.suffix == ".npy" else "json").read(path)
        if name == self._rois_name and name != self._stack_name:
            if self._viewable.rois is None:
                raise NansenError("data-not-found", f"{self._viewable.name} has no ROIs yet: draw them, or find them first")
            return self._viewable.rois
        return np.asarray(self.open_stack(entity, name))

    def save(self, entity, name: str, data: Any) -> Path:
        array = _is_array(data)
        path = self._output_path(name, array)
        if path is None:
            self.outputs[name] = (None, data)
            return self.write_path(entity, name)
        self.adapters.get("npy" if array else "json").write(path, data)
        self.outputs[name] = (path, None if array else data)
        return path

    def stack_writer(self, entity, name: str, shape: Any, dtype: Any) -> StackWriter:
        if not name:
            return StackWriter(shape, dtype)
        path = self._output_path(name, True)
        if path is None:
            self.outputs[name] = (None, None)
            return StackWriter(shape, dtype, finish=lambda data: self.outputs.__setitem__(name, (None, data.copy())))
        self.outputs[name] = (path, None)
        return self.adapters.get("npy").create(path, shape, dtype)

    def checkpoint(self, entity, name: str, shape: Any, dtype: Any, options: Any, source: Any, passes: int = 1, method=None):
        """No progress is kept: the run starts from the first frame."""
        from .progress import Checkpoint
        return Checkpoint(None, name, shape, dtype, {}, passes, create=lambda: self.stack_writer(entity, name, shape, dtype))

    def update_values(self, entity, values: Dict[str, Any]) -> list:
        """There is no table: no column is written."""
        return []

    def write_path(self, entity, name: str) -> Path:
        """Where a method that writes files itself (an external tool) writes: <stem>_<name> beside the stack."""
        stem = self._viewable.path.stem if self._viewable.path is not None else self._viewable.name
        return self.folder / f"{stem}_{name}"


def _image_stack(stack: Stack, name: str) -> Stack:
    if stack.dtype.kind not in "biuf" or not 2 <= stack.ndim <= 5:
        raise NansenError("invalid-data", f"{name} is not an image or a stack of images")
    if stack.ndim == 2:   # an image: its columns are not frames
        import numpy as np
        return as_stack(np.asarray(stack)[:, :, None])
    return stack


def _array_stack(data: Any) -> Stack:
    if isinstance(data, Stack):
        return _image_stack(data, "the stack")
    import numpy as np

    array = data if hasattr(data, "shape") and hasattr(data, "dtype") else np.asarray(data)
    if array.dtype.kind not in "biuf" or not 2 <= array.ndim <= 5:
        raise NansenError("invalid-data", "the array is not an image (height x width) or a stack of images (frames last)")
    return as_stack(array[:, :, None] if array.ndim == 2 else array)


def _pick_variable(variables: Dict[str, Any], name: Optional[str], filename: str) -> Any:
    import numpy as np

    if name:
        if name not in variables:
            raise NansenError("invalid-params", f"{filename} has no variable {name!r}; it has {', '.join(sorted(variables)) or 'none'}")
        return variables[name]
    numeric = [k for k, v in variables.items() if np.asarray(v).dtype.kind in "biuf" and np.asarray(v).ndim in (1, 2)]
    if len(numeric) != 1:
        raise NansenError("invalid-params", f"which variable of {filename} are the signals? Name one of: {', '.join(sorted(numeric)) or 'none'}")
    return variables[numeric[0]]


def view(data: Union[PathOrValue, Sequence[PathOrValue], None] = None, *, rois: Optional[PathOrValue] = None,
         signals: Union[PathOrValue, Sequence[PathOrValue], None] = None, name: Optional[str] = None,
         adapter: Optional[str] = None, variable: Optional[str] = None, frame_rate: Optional[float] = None,
         catalog: Any = None, port: int = 0, open_browser: bool = True):
    """Open the dashboard's viewer on image stacks or signals, with no project: nansen.view(array) or
    nansen.view("recording.tif"), as dev's imviewer; nansen.view(signals=traces) as its signalviewer (frames x N);
    rois="rois.json" shows ROIs over the (first) stack, as its roimanager. ROIs drawn and edited are saved to that
    file, or to <stem>_rois.json beside the stack's file (an array's are kept in memory), and the viewables page
    runs a built-in method (motion correction, ROI detection, ...) on a stack, writing what it saves beside it.

    data is a file or an array (height x width (x channels (x planes)) x frames), or a list of them. Returns the
    server, without blocking; its view_url is the viewer's page. Call shutdown() on it to stop.
    """
    import webbrowser

    from .api import Api
    from .catalog import Catalog, default_catalog_path
    from .server import serve

    viewables = register(Viewables(), data, rois=rois, signals=signals, name=name, adapter=adapter, variable=variable,
                         frame_rate=frame_rate)
    catalog = catalog if catalog is not None else Catalog(default_catalog_path())
    api = Api(catalog=catalog, viewables=viewables, start_queue=False)
    server = serve(api, port=port)
    server.view_url = server.url + "#/view/" + viewables.list()[0]["id"]
    if open_browser:
        webbrowser.open(server.view_url)
    return server


def register(viewables: Viewables, data: Any = None, *, rois: Any = None, signals: Any = None, name: Optional[str] = None,
             adapter: Optional[str] = None, variable: Optional[str] = None, frame_rate: Optional[float] = None) -> Viewables:
    """Add stacks (data: one, or a list) and signals (one, or a list) to viewables; rois go with the first stack."""
    def items(value: Any) -> list:
        if value is None:
            return []
        several = isinstance(value, (list, tuple)) and value and all(_is_path(v) or hasattr(v, "shape") for v in value)
        return list(value) if several else [value]   # a nested list is one array

    stacks, traces = items(data), items(signals)
    if not stacks and not traces:
        raise NansenError("invalid-params", "give an image stack or signals to view")
    if rois is not None and not stacks:
        raise NansenError("invalid-params", "ROIs are shown over an image stack: give one")
    single = len(stacks) + len(traces) == 1
    for number, value in enumerate(stacks):
        viewables.add_stack(value, name=name if single else None, rois=rois if number == 0 else None, adapter=adapter,
                            frame_rate=frame_rate)
    for value in traces:
        viewables.add_signals(value, name=name if single else None, variable=variable, frame_rate=frame_rate)
    return viewables
