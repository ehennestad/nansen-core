"""Data viewed without a project: what `nansen view` and nansen.view are given, as dev's imviewer(array),
imviewer(file), signalviewer and roimanager opened from the command line.

A viewable is an image stack (a file any stack adapter reads, or an array) with ROIs to show over it, read only,
or frames x N signals. The Api serves frames (view.frame), ROI signals (view.signal) and traces (view.traces) of
viewables only, each named by its id: viewables are registered from Python, never by a request, so the page reads no
file the user did not hand over. MATLAB's nansen.Viewables does the same.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple, Union

from .adapters import AdapterRegistry
from .errors import NansenError
from .stacks import Stack, as_stack

PathOrValue = Union[str, Path, Any]


def built_in_adapters() -> AdapterRegistry:
    """The built-in file adapters and those of the modules that ship with NANSEN (ophys reads TIFF, SciScan raw,
    HDF5, video, ...): what a file is read with when no project is open."""
    from .modules import available_modules

    registry = AdapterRegistry()
    for module in reversed(available_modules(None)):
        for document in module.file_adapter_documents():
            registry.declare(document, module.python_root)
    return registry


def _is_path(value: Any) -> bool:
    return isinstance(value, (str, Path))


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
        self.signals: Any = None

    def summary(self) -> dict:
        return {"id": self.id, "kind": self.kind, "name": self.name, "path": str(self.path) if self.path else "",
                "rois": self.rois is not None}

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
        ophys saves ROIs, or a file an RoiArray adapter reads, such as dev's roimanager .mat) or an ROI document,
        shown read only. Returns the id."""
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
            return _image_stack(stack, path.name), candidate
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
    rois="rois.json" shows ROIs over the (first) stack, read only, as its roimanager.

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
