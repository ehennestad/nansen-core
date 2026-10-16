"""The app's API: JSON requests in, JSON responses and events out (docs/reference/protocol.md).

The same methods exist in MATLAB (nansen.Api), so the frontend talks to
either. An Api is given its catalog and opens projects on request; it holds
no global state.
"""

from __future__ import annotations

import json
import keyword
import math
import re
import sys
import threading
import traceback
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

import dsm

from . import __version__, addons
from .catalog import Catalog
from .dataset import Dataset
from .documents import check_document, read_document, write_json
from .entities import Entity
from .errors import NansenError
from .autodetect import autodetect_roi
from .frames import NEUROPIL_DEFAULTS, _pick as pick_channel, alignment_entry, filter_image, image_frame, import_rois_at, mirror_rois_at, roi_neuropil, roi_outlines, roi_signal, rois_at, shown_image, signal_traces, update_rois_at
from .methods import MethodContext
from . import runs
from .project import Project
from .tasks import TaskQueue
from .viewables import Viewables

PROTOCOL_VERSION = "0.1"


def edit_in_editor(path: Path) -> None:
    """Open a code file for editing, without waiting: $VISUAL or $EDITOR, else the system's editor for it.

    Not the default app: on Windows that would run a .py file."""
    import os
    import shlex
    import subprocess
    import sys

    editor = os.environ.get("VISUAL") or os.environ.get("EDITOR")
    try:
        if editor:
            subprocess.Popen(shlex.split(editor) + [str(path)])
        elif sys.platform == "win32":
            os.startfile(str(path), "edit")  # type: ignore[attr-defined]
        elif sys.platform == "darwin":
            subprocess.Popen(["open", "-t", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            subprocess.Popen(["xdg-open", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError as error:
        raise NansenError("cannot-open", f"could not open {path} for editing: {error}") from None


def open_in_file_browser(folder: Path) -> None:
    """Show a folder in Finder, Explorer or the desktop's file manager, without waiting."""
    import os
    import subprocess
    import sys

    if sys.platform == "win32":
        os.startfile(str(folder))  # type: ignore[attr-defined]
    else:
        command = "open" if sys.platform == "darwin" else "xdg-open"
        try:
            subprocess.Popen([command, str(folder)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as error:
            raise NansenError("cannot-open", f"could not open {folder}: {error}") from None


def close_matplotlib_figures() -> int:
    """Close matplotlib's figure windows, when this process has imported pyplot (dev's Close All Figures: close all);
    how many there were. With no pyplot imported, there are none."""
    pyplot = sys.modules.get("matplotlib.pyplot")
    if pyplot is None:
        return 0
    count = len(pyplot.get_fignums())
    pyplot.close("all")
    return count


FILES_LIST_LIMIT = 500  # entries files.list gives at most, unless asked for more
FILES_INSPECT_LIMIT = 2000  # groups, datasets and links files.inspect gives at most
FILES_READ_LIMIT = 65536  # bytes files.read gives at most, unless asked for more
WORKER_START_SECONDS = 300  # how long methods.run waits for another language's worker to take a task
LEGACY_EXPORT_SECONDS = 1800  # how long MATLAB may take to read a dev project folder

def _frame_rate(params: dict, entity: Any, sidecar: Optional[float] = None) -> Optional[float]:
    """data.traces' frames per second: the frameRate given, else the one dev's metadata file of the signals says
    (sidecar), else the entity's frame_rate when it is a positive number."""
    rate = params.get("frameRate")
    if rate is not None:
        if isinstance(rate, bool) or not isinstance(rate, (int, float)) or not math.isfinite(rate) or rate <= 0:
            raise NansenError("invalid-params", "frameRate is a positive number of frames per second")
        return float(rate)
    if sidecar is not None:
        return float(sidecar)
    rate = entity.get("frame_rate")
    if isinstance(rate, bool) or not isinstance(rate, (int, float)) or not math.isfinite(rate) or rate <= 0:
        return None
    return float(rate)


def _entity_metadata(metadata: dict, entity: Any) -> dict:
    """A stack's metadata, with what its files do not give taken from the entity's columns (dev's Edit Stack Properties):
    frameRate from frame_rate, pixelSize from pixel_size_um (square pixels) and zStep from z_step_um, each a positive
    number, rounded to 6 decimals as the files' are. A processed stack (aligned, .npy) carries none of its own."""
    out = dict(metadata)
    usable = lambda v: not isinstance(v, bool) and isinstance(v, (int, float)) and math.isfinite(v) and v > 0
    rounded = lambda v: math.floor(float(v) * 1e6 + 0.5) / 1e6
    for key, column in (("frameRate", "frame_rate"), ("pixelSize", "pixel_size_um"), ("zStep", "z_step_um")):
        value = entity.get(column)
        if key not in out and usable(value):
            out[key] = [rounded(value), rounded(value)] if key == "pixelSize" else rounded(value)
    return out


def _detect_image(stack, params: dict):
    """The image detection modes 0 and 3-5 work on: the one the viewer shows (frame, projection, bin and filter as
    data.frame takes them; dev's imviewer image), or None for the stack's mean when none is given."""
    if "frame" not in params and not params.get("projection"):
        return None
    image = shown_image(stack, int(params.get("frame", 0)), params.get("projection") or None, None, _bin_of(params))[0]
    return filter_image(image, params["filter"]) if params.get("filter") else image


def _bin_of(params: dict) -> Optional[dict]:
    """data.frame's bin: {size (2 or more frames), method: mean or max}, or None."""
    value = params.get("bin")
    if value is None:
        return None
    size = value.get("size") if isinstance(value, dict) else None
    if isinstance(size, bool) or not isinstance(size, (int, float)) or size != int(size) or size < 2 \
            or value.get("method", "mean") not in ("mean", "max"):
        raise NansenError("invalid-params", "bin is {size: 2 or more frames, method: mean or max}")
    return {"size": int(size), "method": value.get("method", "mean")}


def _flag(params: dict, name: str) -> bool:
    """A true-or-false parameter, false when not given."""
    value = params.get(name, False)
    if not isinstance(value, bool):
        raise NansenError("invalid-params", f"{name} is true or false")
    return value


def _open_url(url: str) -> None:
    import webbrowser
    webbrowser.open(url)


def _matlab_text(text: Any) -> str:
    """A MATLAB character vector literal."""
    return "'" + str(text).replace("'", "''") + "'"


class Api:
    def __init__(self, catalog: Optional[Catalog] = None, project: Optional[Project] = None,
                 executor: Optional[str] = None, start_queue: bool = True, viewables: Optional[Viewables] = None):
        self.catalog = catalog
        # What view.frame, view.signal and view.traces may read, with no project: files and arrays handed to
        # `nansen view` or nansen.view (registered from Python, never by a request)
        self.viewables: Viewables = viewables if viewables is not None else Viewables()
        self.project: Optional[Project] = None
        self.queue: Optional[TaskQueue] = None
        # how queued tasks run: "thread" or "process"; without one given, the user's setting (queue.worker)
        self.executor = executor or (catalog.settings()["queue"]["worker"] if catalog is not None else "thread")
        self.start_queue = start_queue
        # Whether the project's task folder is watched for changes others make (TaskQueue.watch), so they reach the
        # listeners as task events: on while a dashboard is served (serve turns it on), so its Tasks page need not poll
        self.watch_tasks = False
        self._listeners: List[Listener] = []
        # Opens a folder in the system's file browser; tests put their own here
        self.open_folder: Callable[[Path], None] = open_in_file_browser
        self.open_file: Callable[[Path], None] = open_in_file_browser  # the file's default app
        self.open_url: Callable[[str], Any] = _open_url   # a web page in the system's browser
        # The dashboard's address, which the server that serves this Api sets (methods.run gives it to methods)
        self.app_url: Optional[str] = None
        self.edit_file: Callable[[Path], None] = edit_in_editor
        # Where workspace.send puts entities: a namespace such as a notebook's globals(), or None for none
        self.workspace: Optional[Dict[str, Any]] = None
        # Changes the working folder of the process the app was opened from (dev's Change Current Folder), or None when
        # the app runs on its own (nansen app), whose folder is no one's; open_app sets os.chdir
        self.change_folder: Optional[Callable[[Path], None]] = None
        # Closes the figure windows of this process (dev's Close All Figures): matplotlib's, where pyplot is imported
        self.close_figures: Callable[[], int] = close_matplotlib_figures
        self._lock = threading.RLock()
        self._methods: Dict[str, Callable[[dict], Any]] = {
            name.replace("__", "."): getattr(self, name) for name in dir(self)
            if "__" in name and not name.startswith("_") and callable(getattr(self, name))
        }
        if project is not None:
            self._set_project(project)

    # -- dispatch ------------------------------------------------------------------------------

    @property
    def method_names(self) -> List[str]:
        return sorted(self._methods)

    def handle(self, request: dict) -> dict:
        """Answer one request: {"id", "method", "params"} -> {"id", "result"} or {"id", "error"}."""
        request_id = request.get("id") if isinstance(request, dict) else None
        try:
            if not isinstance(request, dict) or not isinstance(request.get("method"), str):
                raise NansenError("invalid-request", "a request is an object with a method name")
            function = self._methods.get(request["method"])
            if function is None:
                raise NansenError("unknown-api-method", f"no API method {request['method']!r}")
            params = request.get("params")
            params = {} if params is None else params
            if not isinstance(params, dict):
                raise NansenError("invalid-params", "params must be an object")
            with self._lock:
                result = function(params)
            return {"id": request_id, "result": result}
        except NansenError as error:
            return {"id": request_id, "error": {"code": error.code, "message": error.message}}
        except KeyError as error:
            return {"id": request_id, "error": {"code": "invalid-params", "message": f"missing parameter {error}"}}
        except Exception as error:  # an API call must always answer
            return {"id": request_id, "error": {"code": "internal-error", "message": f"{type(error).__name__}: {error}",
                                                "stack": traceback.format_exc().splitlines()[-10:]}}

    def subscribe(self, listener: Listener) -> Callable[[], None]:
        """Call listener(event) for every event; returns a function that unsubscribes."""
        self._listeners.append(listener)
        return lambda: self._listeners.remove(listener) if listener in self._listeners else None

    def emit(self, event: str, data: Any) -> None:
        message = {"event": event, "data": data}
        for listener in list(self._listeners):
            try:
                listener(message)
            except Exception:  # a broken listener must not stop the others
                pass

    def watch(self, on: bool = True) -> None:
        """Watch the task folder of the project open now and of those opened later (watch_tasks), or stop."""
        self.watch_tasks = on
        if self.queue is not None:
            if on:
                self.queue.watch()
            else:
                self.queue.unwatch(timeout=5)

    def close(self) -> None:
        if self.queue is not None:
            self.queue.stop(timeout=5)
            self.queue.unwatch(timeout=5)

    # -- helpers ---------------------------------------------------------------------------------

    def _require_project(self) -> Project:
        if self.project is None:
            raise NansenError("no-project", "no project is open")
        return self.project

    def _set_project(self, project: Project) -> None:
        if self.queue is not None:
            self.queue.stop(timeout=5)
            self.queue.unwatch(timeout=5)
        self.project = project
        self.queue = TaskQueue(project, executor=self.executor,
                               on_event=lambda kind, data: self.emit(kind, data))
        if self.start_queue:
            self.queue.start()
        if self.watch_tasks:
            self.queue.watch()
        if self.catalog is not None:
            self.catalog.add(project)

    def _entity(self, params: dict) -> Entity:
        return self._require_project().entity(params["entityType"], params["key"])

    def _entities(self, params: dict) -> List[Entity]:
        project = self._require_project()
        everything = project.entities(params["entityType"])
        if "keys" not in params:
            return everything
        wanted = params["keys"]
        chosen = [e for e in everything if any(all(e.key.get(k) == v for k, v in key.items()) for key in wanted)]
        if len(chosen) != len(wanted):
            raise NansenError("unknown-entity", "some keys match no entity")
        return chosen

    def _row(self, entity: Entity, table) -> dict:
        values = dict(entity.key)
        values.update(entity.attributes)
        if entity.row is not None:
            values.update(table.json_row(entity.row))
        out = {"key": entity.key, "inStore": entity.in_store, "inTable": entity.in_table, "values": values}
        if entity.issues:
            out["issues"] = sorted({i["code"] for i in entity.issues})
        return out

    # -- app and catalog -------------------------------------------------------------------------

    def app__plugins(self, params: dict) -> list:
        """The dashboard scripts of the project's modules ([] with no project open)."""
        if self.project is None:
            return []
        return [{"module": module.id, "path": relative, "code": (module.folder / relative).read_text(encoding="utf-8")}
                for module in self.project.modules for relative in module.document.get("dashboard", [])]

    def modules__resource(self, params: dict) -> dict:
        """A text file in the folder of one of the project's modules, such as a dashboard page's data."""
        project = self._require_project()
        module = next((m for m in project.modules if m.id == params["module"]), None)
        if module is None:
            raise NansenError("unknown-module", f"the project does not use a module {params['module']!r}")
        relative = str(params["path"])
        parts = relative.replace("\\", "/").split("/")
        if relative.startswith(("/", "\\")) or ":" in relative or ".." in parts:
            raise NansenError("invalid-params", f"{relative!r} is not a path inside the module")
        path = module.folder.joinpath(*parts)
        if not path.is_file():
            raise NansenError("file-not-found", f"module {module.id} has no {relative}")
        return {"module": module.id, "path": relative, "text": path.read_text(encoding="utf-8")}

    def modules__data(self, params: dict) -> dict:
        """A module's data in the project, as JSON text ("null" when there is none), and its revision (0 then)."""
        path = self._module_data_path(params)
        if not path.is_file():
            return {"module": params["module"], "name": params["name"], "text": "null", "revision": 0}
        document = read_document(path, "nansen.moduleData")
        return {"module": document["module"], "name": document["name"], "text": document["text"], "revision": document["revision"]}

    def modules__saveData(self, params: dict) -> dict:
        """Save a module's data (JSON text); with revision, only when that is still the stored one (revision-conflict otherwise)."""
        path = self._module_data_path(params)
        current = read_document(path, "nansen.moduleData")["revision"] if path.is_file() else 0
        if params.get("revision") is not None and params["revision"] != current:
            raise NansenError("revision-conflict", f"{params['module']}/{params['name']} is at revision {current}, not {params['revision']}")
        text = params.get("text")
        try:
            json.loads(text)
        except (TypeError, ValueError):
            raise NansenError("invalid-params", "text is not JSON text") from None
        document = {"schemaType": "nansen.moduleData", "schemaVersion": "0.1.0", "module": params["module"],
                    "name": params["name"], "revision": current + 1, "text": text}
        check_document(document, "nansen.moduleData")
        path.parent.mkdir(parents=True, exist_ok=True)
        write_json(path, document)
        self.emit("moduleData", {"module": params["module"], "name": params["name"], "revision": current + 1})
        return {"module": params["module"], "name": params["name"], "revision": current + 1}

    def _module_data_path(self, params: dict) -> Path:
        project = self._require_project()
        if not any(m.id == params["module"] for m in project.modules):
            raise NansenError("unknown-module", f"the project does not use a module {params['module']!r}")
        if not re.match(r"^[A-Za-z0-9][A-Za-z0-9_-]*$", str(params["name"])):
            raise NansenError("invalid-params", f"{params['name']!r} is not a name for module data")
        return project.folder / "module-data" / params["module"] / f"{params['name']}.json"

    def app__openUrl(self, params: dict) -> dict:
        """Open a web page (http or https) in the system's browser: the help pages, an issue report."""
        url = str(params.get("url", ""))
        if not re.match(r"^https?://\S+$", url):
            raise NansenError("invalid-params", f"{url!r} is not an http or https address")
        self.open_url(url)
        return {"url": url}

    def app__info(self, params: dict) -> dict:
        return {"name": "nansen", "language": "python", "version": __version__, "protocolVersion": PROTOCOL_VERSION,
                "methods": self.method_names, "workspace": self.workspace is not None,
                "changeFolder": self.change_folder is not None}

    def app__changeFolder(self, params: dict) -> dict:
        """Make a folder the working folder of the process the app was opened from (dev's Change Current Folder, and
        its file viewer's Make Current Folder): the project's, or a folder as files.resolve finds it."""
        if self.change_folder is None:
            raise NansenError("no-workspace", "this app was not opened from a Python session")
        resolved = self.files__resolve(params)
        if not resolved["exists"]:
            raise NansenError("file-not-found", f"{resolved['path']} does not exist")
        if not resolved["isFolder"]:
            raise NansenError("invalid-params", f"{resolved['path']} is not a folder")
        self.change_folder(Path(resolved["path"]))
        return {"path": resolved["path"]}

    def app__closeFigures(self, params: dict) -> dict:
        """Close the figure windows of the process the app runs in (dev's Close All Figures); how many were open."""
        return {"closed": int(self.close_figures() or 0)}

    def workspace__send(self, params: dict) -> dict:
        """Put the entities into the workspace the app was opened from, as a list named name."""
        name = params.get("name", "entities")
        if not isinstance(name, str) or not name.isidentifier() or keyword.iskeyword(name):
            raise NansenError("invalid-params", f"{name!r} is not a variable name")
        if self.workspace is None:
            raise NansenError("no-workspace", "this app was not opened from a workspace")
        entities = self._entities(params)
        self.workspace[name] = entities
        return {"name": name, "count": len(entities)}

    def catalog__list(self, params: dict) -> list:
        return self.catalog.projects() if self.catalog is not None else []

    def settings__get(self, params: dict) -> dict:
        from .catalog import DEFAULT_SETTINGS

        return self.catalog.settings() if self.catalog is not None else {g: dict(v) for g, v in DEFAULT_SETTINGS.items()}

    def settings__save(self, params: dict) -> dict:
        if self.catalog is None:
            raise NansenError("no-catalog", "this app has no project catalog to keep settings in")
        settings = self.catalog.save_settings(params["settings"])
        self.executor = settings["queue"]["worker"]
        if self.queue is not None:
            self.queue.executor = self.executor   # from the next task on
        return settings

    # -- add-ons -----------------------------------------------------------------------------------

    def addons__list(self, params: dict) -> dict:
        """The add-ons the project's modules declare (the built-in modules' with no project open), and their state."""
        folder = self._addons_folder()
        return {"folder": str(folder), "language": "python", "addons": [addons.status(a, folder) for a in self._declared_addons()]}

    def addons__install(self, params: dict) -> dict:
        folder = self._addons_folder()
        addon = addons.find(self._declared_addons(), params["id"])
        addons.install(addon, folder, params.get("archive"))
        return addons.status(addon, folder)

    def addons__remove(self, params: dict) -> dict:
        folder = self._addons_folder()
        addon = addons.find(self._declared_addons(), params["id"])
        addons.remove(addon, folder)
        return addons.status(addon, folder)

    def _declared_addons(self) -> list:
        from .modules import available_modules

        return addons.declared(self.project.modules if self.project is not None else available_modules(None))

    def _addons_folder(self) -> Path:
        folder = self.settings__get({}).get("addons", {}).get("folder") or ""
        return Path(folder).expanduser() if folder else addons.default_folder()

    def catalog__relocate(self, params: dict) -> list:
        """A project was moved: point its entry at the new folder."""
        if self.catalog is None:
            raise NansenError("no-catalog", "this app has no project catalog")
        self.catalog.relocate(params["path"], params["newPath"])
        return self.catalog.projects()

    def catalog__install(self, params: dict) -> list:
        """A project shared in a git repository (on GitHub, say) cloned into a folder and added to the catalog, as dev's
        installProject: the folder must hold a project once cloned. Data locations' roots stay to be set."""
        import shutil
        import subprocess

        if self.catalog is None:
            raise NansenError("no-catalog", "this app has no project catalog")
        url, folder = str(params["url"]), Path(params["path"]).expanduser()
        if folder.exists() and any(folder.iterdir()):
            raise NansenError("folder-not-empty", f"{folder} is not empty")
        git = shutil.which("git")
        if git is None:
            raise NansenError("dependency-missing", "installing a project needs git")
        done = subprocess.run([git, "clone", "--depth", "1", "--", url, str(folder)], capture_output=True, text=True)
        if done.returncode != 0:
            raise NansenError("install-failed", f"git could not clone {url}: {done.stderr.strip()[-500:]}")
        try:
            project = Project.open(folder)
        except NansenError as error:
            raise NansenError("not-a-project", f"{url} holds no NANSEN project ({error.message}); it was cloned to {folder}") from None
        self.catalog.add(project, opened=False)
        return self.catalog.projects()

    def catalog__remove(self, params: dict) -> list:
        """Forget a project; with deleteFolder, delete its folder too (dev's project manager's Delete), which must hold
        the project, and not be the project open."""
        import shutil

        if self.catalog is None:
            raise NansenError("no-catalog", "this app has no project catalog")
        folder = Path(params["path"]).resolve()
        if params.get("deleteFolder"):
            self._not_open(folder)
            if not (folder / "project.nansen.json").is_file():
                raise NansenError("invalid-params", f"{folder} holds no project, so it is not deleted")
        self.catalog.remove(folder)
        if params.get("deleteFolder"):
            shutil.rmtree(folder)
        return self.catalog.projects()

    def catalog__rename(self, params: dict) -> list:
        """Give a project another name (dev's project manager's Rename): in its project.nansen.json and the catalog."""
        if self.catalog is None:
            raise NansenError("no-catalog", "this app has no project catalog")
        folder = Path(params["path"]).resolve()
        self.catalog.rename(folder, params["name"])
        if self.project is not None and Path(self.project.folder).resolve() == folder:   # the open one: read it again
            self._set_project(Project.open(folder, environment=self.project.environment))
            self.emit("project", {"name": self.project.name})
        return self.catalog.projects()

    def catalog__move(self, params: dict) -> list:
        """Move a project's folder (dev's project manager's Move): to newPath, which must not exist, and point the
        catalog there. Not the project open."""
        import shutil

        if self.catalog is None:
            raise NansenError("no-catalog", "this app has no project catalog")
        folder = Path(params["path"]).resolve()
        target = Path(params["newPath"]).expanduser().resolve()
        self._not_open(folder)
        if not folder.is_dir():
            raise NansenError("file-not-found", f"{folder} does not exist")
        if target.exists():
            raise NansenError("folder-not-empty", f"{target} exists already")
        if target == folder or folder in target.parents:
            raise NansenError("invalid-params", f"{target} is inside {folder}")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(folder), str(target))
        self.catalog.relocate(folder, target)
        return self.catalog.projects()

    def _not_open(self, folder: Path) -> None:
        if self.project is not None and Path(self.project.folder).resolve() == folder:
            raise NansenError("invalid-params", "that is the project open: open another one first")

    # -- projects ----------------------------------------------------------------------------

    def project__open(self, params: dict) -> dict:
        self._set_project(Project.open(params["path"], environment=params.get("environment")))
        self.emit("project", {"name": self.project.name})
        return self.project__info({})

    def project__create(self, params: dict) -> dict:
        """A new project; with datasetSource, a copy of that DSM config, and with entityTypes, its entity types."""
        source = params.get("datasetSource")
        if source:
            Dataset.load(source)  # file-not-found or dataset-invalid before anything is written
        project = Project.create(params["path"], params["name"], params.get("title"), params.get("dataset"),
                                 params.get("description"))
        self._configure(project, params)
        self._set_project(project)
        self.emit("project", {"name": project.name})
        return self.project__info({})

    def project__setDataset(self, params: dict) -> dict:
        """Give the open project a copy of a DSM config; also add modules, and with entityTypes, its entity types."""
        project = self._require_project()
        self._configure(project, params)
        self._set_project(Project.open(project.folder, environment=project.environment))
        self.emit("project", {"name": self.project.name})
        return self.project__info({})

    def _configure(self, project: Project, params: dict) -> None:
        if params.get("datasetSource"):
            project.set_dataset(params["datasetSource"])
        elif params.get("datasetText"):
            project.set_dataset_text(params["datasetText"])
        for module in params.get("modules", []):
            project.add_module(module)
        if params.get("entityTypes"):
            core = any(m["id"] == "core" for m in project.document.get("modules", []))
            added = project.add_dataset_entity_types(["core.notes"] if core else [])
            if core and "subject" in added:  # as dev's subject table: date of birth, sex, species
                project.attach_fragment("subject", "core.subject")

    def dataset__test(self, params: dict) -> dict:
        """What a scan with a candidate DSM config (its text) would find, without keeping anything."""
        return self._require_project().test_dataset_text(params["text"])

    def dataset__sample(self, params: dict) -> dict:
        """Example names at each folder level under a folder, for describing its layout: up to limit
        names per level, taken from up to limit folders of the level above."""
        project = self.project
        path = Path(str(params["path"])).expanduser()
        if not path.is_absolute():
            if project is None:
                raise NansenError("invalid-params", "a relative path needs an open project")
            path = project.folder / path
        if not path.is_dir():
            raise NansenError("file-not-found", f"{path} is not a folder")
        depth, limit = int(params.get("depth", 4)), int(params.get("limit", 8))
        levels, folders = [], [path]
        for _ in range(depth):
            names, files, next_folders = [], 0, []
            for folder in folders[:limit]:
                try:
                    children = sorted(folder.iterdir(), key=lambda p: p.name)
                except OSError:
                    continue
                for child in children:
                    if child.is_dir():
                        next_folders.append(child)
                        if child.name not in names:
                            names.append(child.name)
                    else:
                        files += 1
            if not names and not files:
                break
            levels.append({"folders": names[:limit], "moreFolders": max(0, len(names) - limit), "files": files})
            folders = next_folders
            if not folders:
                break
        return {"path": str(path), "levels": levels}

    def dataset__setRoot(self, params: dict) -> dict:
        """Where a data location is on this machine (or in the given environment)."""
        project = self._require_project()
        project.set_root(params["dataLocation"], params["path"], params.get("environment"), params.get("rootStoragePath"))
        self._set_project(Project.open(project.folder, environment=project.environment))
        self.emit("project", {"name": self.project.name})
        return self.project__info({})

    def project__update(self, params: dict) -> dict:
        """Change the project's title or description, or entity types' titles."""
        project = self._require_project()
        project.update_info(params.get("title"), params.get("description"), params.get("entityTypeTitles"))
        if self.catalog is not None:
            self.catalog.add(project)
        self.emit("project", {"name": project.name})
        return self.project__info({})

    def scan__unmatched(self, params: dict) -> dict:
        """What the last scan found that no entity accounts for: each with its location, path, reason and detail."""
        project = self._require_project()
        scan = project.last_scan()
        entries = sorted((u for u in (scan.unmatched if scan is not None else []) if u.get("reason") != "excluded"),
                         # excluded entries were skipped on purpose; the readers emit the rest in their own order
                         key=lambda u: (u.get("dataLocationIdentifier") or "", u.get("path") or ""))
        limit = int(params.get("limit", 1000))
        dataset = project.dataset
        shown = []
        for u in entries[:limit]:
            entry = {"dataLocation": u.get("dataLocationIdentifier"), "rootStoragePath": u.get("rootStoragePathIdentifier"),
                     "path": u.get("path", ""), "reason": u.get("reason", ""), "detail": u.get("detail", ""),
                     "entityType": None, "key": None}
            if dataset is not None:  # what it could be matched to by hand, and what its names say of the key
                entry["entityType"], entry["key"] = dataset.suggested_key(entry["dataLocation"] or "",
                                                                          entry["rootStoragePath"] or "", entry["path"])
            shown.append(entry)
        return {"scannedAt": scan.scanned_at if scan is not None else None, "total": len(entries), "entries": shown}

    def dataset__assign(self, params: dict) -> dict:
        """Match an entry of a data location to an entity by hand, from the next scan on (dev's FolderMatcherDialog)."""
        project = self._require_project()
        if not isinstance(params.get("key"), dict):
            raise NansenError("invalid-params", "key is an object of the entity's key values")
        result = project.assign_entry(params["dataLocation"], params["path"], params["key"])
        self.emit("project", {"name": project.name})
        return result

    def dataset__unassign(self, params: dict) -> dict:
        """Undo the matching of an entry to an entity by hand."""
        project = self._require_project()
        removed = project.unassign_entry(params["dataLocation"], params["path"])
        self.emit("project", {"name": project.name})
        return {"removed": removed}

    def dataset__assignments(self, params: dict) -> list:
        """The entries matched to an entity by hand."""
        return self._require_project().assignments()

    def dataset__exclude(self, params: dict) -> dict:
        """Skip an unmatched entry in later scans, by its exact name at its level."""
        project = self._require_project()
        result = project.exclude_from_scan(params["dataLocation"], params["path"])
        self._set_project(Project.open(project.folder, environment=project.environment))
        self.emit("project", {"name": self.project.name})
        return result

    def dataset__get(self, params: dict) -> dict:
        """The DSM config's text, for editing."""
        project = self._require_project()
        text = project.dataset_text()
        return {"path": project.document["dataset"], "text": text}

    def dataset__save(self, params: dict) -> dict:
        """Replace the DSM config's text; refused (and nothing changed) unless DSM accepts it and the keys still match."""
        project = self._require_project()
        project.save_dataset_text(params["text"])
        self._set_project(Project.open(project.folder, environment=project.environment))
        self.emit("project", {"name": self.project.name})
        return self.project__info({})

    def demo__create(self, params: dict) -> dict:
        """A demo project in a new folder, now open: kind sessions (the default) or two-photon (the quickstart)."""
        from .demo import create_demo_kind

        self._set_project(create_demo_kind(params["path"], params.get("kind", "sessions")))
        self.emit("project", {"name": self.project.name})
        return self.project__info({})

    def legacy__import(self, params: dict) -> dict:
        """A project from a NANSEN dev project; Python reads the JSON export that MATLAB writes. dev's app preferences
        that are settings here are saved to the catalog's settings."""
        from .legacy import convert_legacy

        source = Path(params["source"])
        if source.is_dir():
            exported = self._export_legacy(source, params.get("userFolder"))
        elif not source.is_file():
            raise NansenError("file-not-found", f"no file {source}")
        else:
            with open(source, encoding="utf-8") as f:
                exported = json.load(f)
        report = convert_legacy(exported, params["path"])
        if report["settings"] and self.catalog is not None:
            self.catalog.save_settings(report["settings"])
        self._set_project(Project.open(params["path"]))
        self.emit("project", {"name": self.project.name})
        return {"project": self.project__info({}), "settings": report["settings"], "warnings": report["warnings"]}

    def _export_legacy(self, folder: Path, user_folder: Optional[str] = None) -> dict:
        """A NANSEN dev project folder read by MATLAB (matlab -batch nansen.legacy.exportProject), as its JSON export:
        dev's .mat files are MATLAB objects that only MATLAB reads."""
        import subprocess
        import tempfile

        executable = self._matlab()
        if not executable:
            raise NansenError("legacy-needs-matlab", "reading a NANSEN dev project folder needs MATLAB: put matlab on the "
                                                     "PATH or set it in Settings, or export it with nansen.legacy.exportProject "
                                                     "and import the JSON file")
        with tempfile.TemporaryDirectory() as scratch:
            out = Path(scratch) / "export.json"
            user = f", UserFolder={_matlab_text(user_folder)}" if user_folder else ""   # dev's preferences, if not the default
            script = self._matlab_script(f"nansen.legacy.exportProject({_matlab_text(folder)}, File={_matlab_text(out)}{user});")
            done = subprocess.run([executable, "-batch", script], capture_output=True, text=True, stdin=subprocess.DEVNULL,
                                  timeout=LEGACY_EXPORT_SECONDS)
            if done.returncode != 0 or not out.is_file():
                raise NansenError("invalid-data",
                                  f"MATLAB could not export {folder}: {(done.stdout + done.stderr).strip()[-600:]}")
            with open(out, encoding="utf-8") as f:
                return json.load(f)

    def project__info(self, params: dict) -> dict:
        project = self._require_project()
        dataset = project.dataset
        scan = project.last_scan()
        entity_types = []
        for entry in project.document["entityTypes"]:
            name = entry["name"]
            try:
                count = len(project.table(name))
            except NansenError:
                count = None
            entity_types.append({"name": name, "title": entry.get("title", name.capitalize()),
                                 "fragments": entry.get("fragments", []), "rows": count,
                                 "records": len(scan.records_of(name)) if scan else None})
        info = {"name": project.name, "title": project.title, "folder": str(project.folder),
                "description": project.document.get("description", ""),
                "entityTypes": entity_types, "modules": [m.summary() for m in project.modules],
                "lastScan": scan.scanned_at if scan else None, "dataset": None}
        if dataset is not None:
            info["dataset"] = {
                "environment": dataset.environment,
                "entityTypes": dataset.entity_types,
                "locations": [{"id": loc["identifier"], "title": loc.get("displayName", loc["identifier"]),
                               "category": loc.get("dataCategory", ""), "access": loc.get("access", "read")}
                              for loc in dataset.config.locations],
                "roots": [{"dataLocation": r.data_location, "rootStoragePath": r.root_storage_path, "path": str(r.path),
                           "environment": r.environment, "available": r.available} for r in dataset.roots()],
            }
        return info

    def project__scan(self, params: dict) -> dict:
        project = self._require_project()
        listing = dsm.listing.listing_from_dict(params["listing"]) if "listing" in params else None
        scan = project.scan(listing)
        counts: Dict[str, int] = {}
        for record in scan.records:
            counts[record["entityType"]] = counts.get(record["entityType"], 0) + 1
        result = {"scannedAt": scan.scanned_at, "records": counts, "roots": scan.roots,
                  "unmatched": sum(1 for u in scan.unmatched if u.get("reason") != "excluded")}
        self.emit("scan", result)
        return result

    def project__sync(self, params: dict) -> dict:
        project = self._require_project()
        names = [params["entityType"]] if "entityType" in params else project.entity_types
        added = {name: project.sync(name) for name in names}
        self.emit("entities", {"entityTypes": names})
        return {"added": added}

    # -- entities -----------------------------------------------------------------------------

    def entities__list(self, params: dict) -> dict:
        project = self._require_project()
        entity_type = params["entityType"]
        table = project.table(entity_type)
        entities = project.entities(entity_type)
        columns = self._columns(entity_type, table, entities)
        rows = [self._row(e, table) for e in entities]
        if "core.pipeline" in project.entity_type(entity_type).get("fragments", []):
            progress = project.pipeline_progress(entity_type)
            columns.append({"name": "progress", "dataType": "number", "title": "Progress", "unit": None,
                            "fragment": "core.pipeline", "source": "progress", "editable": False})
            for row in rows:
                state = progress.get(runs.key_id(row["key"]))
                row["values"]["progress"] = state["done"] / state["total"] if state else None
                if state:
                    row["progress"] = {k: state[k] for k in ("pipeline", "title", "done", "total")}
        counts: Dict[Any, Dict[str, int]] = {}   # dev's Notebook column: each entity's notes, and how many of each kind
        for note in project.notebook(entity_type).notes(None):
            count = counts.setdefault(runs.key_id(note["key"]), {"count": 0, "important": 0, "todo": 0, "question": 0})
            count["count"] += 1
            if note.get("type") in ("important", "todo", "question"):
                count[note["type"]] += 1
        for row in rows:
            if runs.key_id(row["key"]) in counts:
                row["notes"] = counts[runs.key_id(row["key"])]
        return {"entityType": entity_type, "key": table.spec.key, "columns": columns, "rows": rows}

    def _columns(self, entity_type: str, table, entities: List[Entity]) -> List[dict]:
        project = self._require_project()
        titles: Dict[str, dict] = {}
        computed = set()
        for fragment_id in project.entity_type(entity_type).get("fragments", []):
            fragment = project.fragment(fragment_id)
            if "compute" in fragment.document:
                computed.add(fragment_id)
            for column in fragment.document["columns"]:
                titles[column["name"]] = column
        columns = []
        for column in table.spec.columns:
            is_key = column.name in table.spec.key
            info = titles.get(column.name, {})
            columns.append({"name": column.name, "dataType": column.data_type,
                            "title": info.get("title", column.name), "unit": column.unit or info.get("unit"),
                            "fragment": column.fragment, "source": "key" if is_key else "table",
                            "editable": not is_key and column.fragment not in computed})
            if "choices" in info:
                columns[-1]["choices"] = list(info["choices"])
            for hint in ("display", "action"):  # how the dashboard draws the cells, and what a double-click runs
                if hint in info:
                    columns[-1][hint] = info[hint]
            if column.name == "pipeline" and column.fragment == "core.pipeline":
                columns[-1]["choices"] = [p["id"] for p in project.pipelines(entity_type)]
        dataset = project.dataset
        if dataset is not None and entity_type in dataset.entity_types:
            definitions = dataset.config.definitions
            seen = {c["name"] for c in columns}
            for name, definition in definitions.items():
                if definition["ofEntity"] == entity_type and name not in seen:
                    columns.append({"name": name, "dataType": definition["dataType"],
                                    "title": definition.get("title", name), "unit": definition.get("unit"),
                                    "fragment": None, "source": "attribute", "editable": False})
        return columns

    def entities__get(self, params: dict) -> dict:
        project = self._require_project()
        entity = self._entity(params)
        table = project.table(entity.entity_type)
        detail = self._row(entity, table)
        detail["entityType"] = entity.entity_type
        detail["locations"] = entity.locations
        detail["issueDetails"] = entity.issues
        detail["data"] = project.data_status(entity) if project.dataset is not None else []
        if "core.pipeline" in project.entity_type(entity.entity_type).get("fragments", []):
            state = project.pipeline_progress(entity.entity_type).get(runs.key_id(entity.key))
            detail["values"]["progress"] = state["done"] / state["total"] if state else None
            if state is not None:
                detail["pipeline"] = state
        return detail

    def entities__update(self, params: dict) -> dict:
        project = self._require_project()
        table = project.table(params["entityType"])
        key = params["key"]
        if not table.has(key):
            raise NansenError("unknown-entity", f"no row with key {key}")
        editable = {c["name"] for c in self._columns(params["entityType"], table, []) if c["editable"]}
        for name in params["values"]:
            if name not in editable:
                raise NansenError("read-only-column", f"column {name!r} cannot be edited")
        project.check_choices(params["entityType"], params["values"])
        table.update(key, **params["values"])
        table.write()
        self.emit("entities", {"entityTypes": [params["entityType"]], "keys": [key]})
        entity = project.entity(params["entityType"], key)
        row = self._row(entity, project.table(params["entityType"]))
        if self.catalog is not None and self.catalog.settings()["tables"]["saveToDataFolders"]:
            self._save_to_data_folders(entity, row)
        return row

    def _save_to_data_folders(self, entity, row: dict) -> None:
        """The row as <entity type>_info.json in each of the entity's folders, as dev's AutosaveMetadataToDataFolders."""
        values = dict(row["key"], **{k: v for k, v in row["values"].items() if k not in row["key"]})
        text = json.dumps(values, indent=2, ensure_ascii=False) + "\n"
        for location in entity.locations:
            for path in location.get("paths", []):
                try:
                    folder = self.files__resolve({"dataLocation": location["dataLocationIdentifier"],
                                                  "rootStoragePath": location.get("rootStoragePathIdentifier"), "path": path})
                except NansenError:
                    continue   # a root not on this computer
                if folder["isFolder"]:
                    (Path(folder["path"]) / f"{entity.entity_type}_info.json").write_text(text, encoding="utf-8")

    def entities__add(self, params: dict) -> dict:
        project = self._require_project()
        table = project.table(params["entityType"])
        project.check_choices(params["entityType"], params.get("values", {}))
        table.add(dict(params["key"], **params.get("values", {})))
        table.write()
        self.emit("entities", {"entityTypes": [params["entityType"]]})
        entity = project.entity(params["entityType"], params["key"])
        return self._row(entity, project.table(params["entityType"]))

    def entities__remove(self, params: dict) -> dict:
        project = self._require_project()
        table = project.table(params["entityType"])
        table.remove(params["key"])
        table.write()
        self.emit("entities", {"entityTypes": [params["entityType"]]})
        return {"removed": params["key"]}

    # -- files ---------------------------------------------------------------------------------

    def _files_base(self, params: dict) -> Path:
        """The folder files.resolve takes paths in: the data location's root (dataLocation, rootStoragePath), or the
        project folder."""
        project = self._require_project()
        if "dataLocation" in params:
            return Path(project.require_dataset().root(params["dataLocation"], params.get("rootStoragePath")).path).resolve()
        return Path(project.folder).resolve()

    def files__resolve(self, params: dict) -> dict:
        self._require_project()
        relative = str(params.get("path", ""))
        if relative.startswith(("/", "\\")) or re.match(r"^[A-Za-z]:", relative):
            raise NansenError("invalid-params", f"{relative!r} is not a relative path")
        base = self._files_base(params)
        path = (base / relative).resolve()
        if path != base and base not in path.parents:
            raise NansenError("invalid-params", f"{relative!r} is outside {base}")
        return {"path": str(path), "exists": path.exists(), "isFolder": path.is_dir()}

    def files__list(self, params: dict) -> dict:
        """What a folder holds, as files.resolve finds it: folders first, then files, each by name."""
        import datetime as dt

        resolved = self.files__resolve(params)
        if not resolved["exists"]:
            raise NansenError("file-not-found", f"{resolved['path']} does not exist")
        if not resolved["isFolder"]:
            raise NansenError("invalid-params", f"{resolved['path']} is not a folder")
        limit = int(params.get("limit", FILES_LIST_LIMIT))
        entries = []
        for path in Path(resolved["path"]).iterdir():
            try:
                info = path.stat()
            except OSError:
                continue  # gone, or a broken link
            folder = path.is_dir()
            entries.append({"name": path.name, "isFolder": folder, "size": None if folder else info.st_size,
                            "modified": dt.datetime.fromtimestamp(info.st_mtime).isoformat(timespec="seconds")})
        entries.sort(key=lambda e: (not e["isFolder"], e["name"]))
        return dict(resolved, entries=entries[:limit], truncated=len(entries) > limit)

    def files__inspect(self, params: dict) -> dict:
        """The groups, datasets and links of an HDF5 file (NWB, MATLAB v7.3, .h5), as files.resolve finds it."""
        from .hdf5 import inspect

        resolved = self.files__resolve(params)
        if not resolved["exists"]:
            raise NansenError("file-not-found", f"{resolved['path']} does not exist")
        if resolved["isFolder"]:
            raise NansenError("invalid-params", f"{resolved['path']} is a folder; files.list shows folders")
        return dict(resolved, **inspect(Path(resolved["path"]), int(params.get("limit", FILES_INSPECT_LIMIT))))

    def files__read(self, params: dict) -> dict:
        """The start of a file as text, as dev's file viewer's preview: at most maxBytes (default 65536) bytes, decoded as
        UTF-8 (bytes that are not are replaced); binary when it has a NUL byte."""
        resolved = self.files__resolve(params)
        if not resolved["exists"]:
            raise NansenError("file-not-found", f"{resolved['path']} does not exist")
        if resolved["isFolder"]:
            raise NansenError("invalid-params", f"{resolved['path']} is a folder")
        limit = int(params.get("maxBytes", FILES_READ_LIMIT))
        path = Path(resolved["path"])
        with open(path, "rb") as f:
            data = f.read(limit + 1)
        binary = b"\0" in data[:limit]
        text = "" if binary else data[:limit].decode("utf-8", errors="replace")
        return dict(resolved, text=text, binary=binary, truncated=len(data) > limit, size=path.stat().st_size)

    def files__makeFolder(self, params: dict) -> dict:
        """A new folder, as files.resolve finds it (in the project folder or a data location's root)."""
        resolved = self.files__resolve(params)
        if resolved["exists"]:
            raise NansenError("invalid-params", f"{resolved['path']} exists already")
        Path(resolved["path"]).mkdir(parents=True)
        return dict(resolved, exists=True, isFolder=True)

    def files__send(self, params: dict) -> dict:
        """Read any file and put its value in the workspace the app was opened from, as dev's file viewer's Load to
        workspace: with the adapter given, or the first of those naming its extension that reads it."""
        if self.workspace is None:
            raise NansenError("no-workspace", "this app was not opened from a workspace")
        project = self._require_project()
        resolved = self.files__resolve(params)
        if not resolved["exists"]:
            raise NansenError("file-not-found", f"{resolved['path']} does not exist")
        if resolved["isFolder"]:
            raise NansenError("invalid-params", f"{resolved['path']} is a folder")
        path = Path(resolved["path"])
        dataset = params.get("dataset")
        if dataset is not None and (not isinstance(dataset, str) or not dataset.startswith("/")):
            raise NansenError("invalid-params", "dataset is the path of a dataset in the file, such as /acquisition/data")
        stem = dataset.rstrip("/").rsplit("/", 1)[-1] if dataset else path.stem
        name = params.get("name") or re.sub(r"\W", "_", stem)
        if not name or not name[0].isalpha():
            name = "data_" + name
        if not isinstance(name, str) or not name.isidentifier() or keyword.iskeyword(name):
            raise NansenError("invalid-params", f"{name!r} is not a variable name")
        if dataset:   # one dataset of an HDF5 file (NWB, MATLAB v7.3): dev's file viewer's NWB node Assign to Workspace
            from .hdf5 import read_dataset

            value, shape, data_type = read_dataset(path, dataset)
            self.workspace[name] = value
            return {"name": name, "path": str(path), "dataset": dataset, "shape": shape, "dataType": data_type}
        tries = [params["adapter"]] if params.get("adapter") else project.adapters.for_extension(path.suffix)
        if not tries:
            raise NansenError("unsupported-file", f"no file adapter of the project reads {path.suffix or 'these'} files")
        problems = []
        for adapter_id in tries:
            try:
                value = project.adapters.get(adapter_id).read(path)
            except NansenError as error:
                if params.get("adapter"):
                    raise
                problems.append(f"{adapter_id}: {error.message}")
                continue
            self.workspace[name] = value
            return {"name": name, "adapter": adapter_id, "path": str(path)}
        raise NansenError("invalid-data", f"{path.name} could not be read: " + "; ".join(problems))

    def files__run(self, params: dict) -> dict:
        """Run a file method (entityType @file) on a file now, as files.resolve finds it: dev's project filemethods on the
        file viewer's context menu (Download File). The method gets the file's path and its root: the data location's
        root folder it is in, or the project folder. Its result and log."""
        project = self._require_project()
        method = project.method(params["methodId"])
        resolved = self.files__resolve(params)
        if not resolved["exists"]:
            raise NansenError("file-not-found", f"{resolved['path']} does not exist")
        if resolved["isFolder"]:
            raise NansenError("invalid-params", f"{resolved['path']} is a folder")
        file = {"path": resolved["path"], "root": str(self._files_base(params))}
        context = MethodContext(project=project, method=method, app_url=self.app_url, open_url=self.open_url)
        result = project.run_file_method(method.id, file, params.get("options"), params.get("preset"), context)
        return {"result": result, "log": context.lines, "path": resolved["path"]}

    def files__frame(self, params: dict) -> dict:
        """A frame (or a projection) of any stack file, as data.frame gives one of a variable: dev's imviewer on a file.
        The adapter is the one given, or the first that reads the file (Project.open_file_stack)."""
        project = self._require_project()
        resolved = self.files__resolve(params)
        if not resolved["exists"]:
            raise NansenError("file-not-found", f"{resolved['path']} does not exist")
        if resolved["isFolder"]:
            raise NansenError("invalid-params", f"{resolved['path']} is a folder")
        limits = params.get("limits")
        if limits is not None and (not isinstance(limits, list) or len(limits) != 2):
            raise NansenError("invalid-params", "limits is [low, high]")
        stack, adapter, candidates = project.open_file_stack(Path(resolved["path"]), params.get("adapter"))
        result = image_frame(stack, int(params.get("frame", 0)), int(params.get("channel", 0)), params.get("projection"), limits,
                             int(params.get("plane", 0)), params.get("filter"), _bin_of(params))
        return dict(result, metadata=dict(stack.metadata), adapter=adapter, adapters=candidates, name=Path(resolved["path"]).name)

    def files__open(self, params: dict) -> dict:
        """Open a file in its default app, as files.resolve finds it."""
        resolved = self.files__resolve(params)
        if not resolved["exists"]:
            raise NansenError("file-not-found", f"{resolved['path']} does not exist")
        if resolved["isFolder"]:
            raise NansenError("invalid-params", f"{resolved['path']} is a folder; files.reveal shows folders")
        self.open_file(Path(resolved["path"]))
        return resolved

    def files__reveal(self, params: dict) -> dict:
        resolved = self.files__resolve(params)
        if not resolved["exists"]:
            raise NansenError("file-not-found", f"{resolved['path']} does not exist")
        path = Path(resolved["path"])
        self.open_folder(path if resolved["isFolder"] else path.parent)
        return resolved

    # -- viewing without a project: what `nansen view` and nansen.view registered ---------------------------------

    def view__list(self, params: dict) -> list:
        """The files and arrays this app was given to view: [{id, kind (stack or signals), name, path, rois, roiFile}]."""
        return self.viewables.list()

    def view__frame(self, params: dict) -> dict:
        """A frame (or a projection) of a registered stack, as files.frame gives one of a file; with rois, its ROIs of
        the plane and channel shown ([] when it has none yet). No project is needed, and nothing but what was
        registered is read."""
        viewable = self.viewables.get(params["viewable"])
        limits = params.get("limits")
        if limits is not None and (not isinstance(limits, list) or len(limits) != 2):
            raise NansenError("invalid-params", "limits is [low, high]")
        stack, adapter = self.viewables.stack(viewable, params.get("adapter"))
        plane, channel = int(params.get("plane", 0)), int(params.get("channel", 0))
        result = image_frame(stack, int(params.get("frame", 0)), channel, params.get("projection"), limits,
                             plane, params.get("filter"), _bin_of(params))
        result = dict(result, metadata=viewable.metadata(stack), adapter=adapter, adapters=list(viewable.adapters), name=viewable.name)
        if _flag(params, "rois"):
            result["rois"] = roi_outlines(rois_at(viewable.rois, plane + 1, channel + 1)) if viewable.rois is not None else []
        return result

    def view__updateRois(self, params: dict) -> dict:
        """Change the ROIs of a registered stack as rois.update changes an ROI variable's, and save them to its ROI file
        (roimanager's Save Rois): {rois, added, file}; file is "" for an array's, kept in memory. An import takes the
        ROIs of another registered stack ({viewable, mode?})."""
        viewable = self.viewables.get(params["viewable"])
        if viewable.kind != "stack":
            raise NansenError("invalid-params", f"{viewable.name} is signals; ROIs are drawn on image stacks")
        if params.get("mirror", False) is not False:
            raise NansenError("invalid-params", f"the ROIs of {viewable.name} are aligned with no others: there is nothing to mirror the change to")
        plane, channel = int(params.get("plane", 0)) + 1, int(params.get("channel", 0)) + 1
        current = viewable.rois if viewable.rois is not None else {"rois": []}
        if params.get("imageSize") and "imageSize" not in current:
            current = dict(current, imageSize=params["imageSize"])
        document, added = self._edit_rois(current, plane, channel, params, 1, self._viewable_rois)
        file = self.viewables.save_rois(viewable, document)
        return {"rois": roi_outlines(rois_at(document, plane, channel)), "added": added, "file": file}

    def _viewable_rois(self, spec: dict) -> Any:
        """The ROIs view.updateRois imports: those of another registered stack (none, when it has none yet)."""
        if spec.get("viewable") is None:
            raise NansenError("invalid-params", "a viewable's import names another viewable: {viewable, mode?}")
        other = self.viewables.get(spec["viewable"])
        if other.kind != "stack":
            raise NansenError("invalid-params", f"{other.name} is signals, which have no ROIs")
        return other.rois if other.rois is not None else {"rois": []}

    def view__detect(self, params: dict) -> dict:
        """The pixels of an ROI found around a point of a registered stack, as rois.detect finds one; not saved."""
        viewable = self.viewables.get(params["viewable"])
        point = params.get("point")
        if not isinstance(point, list) or len(point) != 2:
            raise NansenError("invalid-params", "point is [row, column]")
        stack, _ = self.viewables.stack(viewable, params.get("adapter"))
        stack, _, _ = pick_channel(stack, int(params.get("channel", 0)), int(params.get("plane", 0)))
        return {"pixels": autodetect_roi(stack, point, int(params.get("radius", 6)), params.get("mode", 1), _detect_image(stack, params))}

    def view__methods(self, params: dict) -> list:
        """Summaries of the built-in methods view.run runs on a registered stack."""
        return [m.summary() for m in self.viewables.methods()]

    def view__run(self, params: dict) -> dict:
        """Run a built-in method on a registered stack now, as dev's imviewer runs Align Images: {result, log, outputs};
        what it saves is written beside the stack's file, and its stacks and ROIs are registered as viewables."""
        viewable = self.viewables.get(params["viewable"])
        return self.viewables.run(viewable, params["methodId"], params.get("options"), params.get("preset"))

    def view__signal(self, params: dict) -> dict:
        """An ROI's signal read from a registered stack (the mean of its pixels per frame), as rois.signal gives one."""
        viewable = self.viewables.get(params["viewable"])
        pixels = params.get("pixels")
        if not isinstance(pixels, list) or not pixels:
            raise NansenError("invalid-params", "pixels is a list of [row, column] pairs")
        stack, _ = self.viewables.stack(viewable, params.get("adapter"))
        stack, _, _ = pick_channel(stack, int(params.get("channel", 0)), int(params.get("plane", 0)))
        start, stop = params.get("start", 0), params.get("stop")
        result = signal_traces({viewable.name: roi_signal(stack, pixels, start, stop)}, [0], start, stop, params.get("maxPoints", 2000))
        result["frameRate"] = viewable.rate()
        return result

    def view__traces(self, params: dict) -> dict:
        """Columns of registered signals (frames x N), a frame range thinned to maxPoints, as data.traces gives them."""
        viewable = self.viewables.get(params["viewable"])
        if viewable.kind != "signals":
            raise NansenError("invalid-params", f"{viewable.name} is an image stack; view.frame shows it")
        columns = params.get("columns", [0])
        if not isinstance(columns, list) or not all(isinstance(c, int) and not isinstance(c, bool) for c in columns):
            raise NansenError("invalid-params", "columns is a list of 0-based column numbers")
        result = signal_traces({viewable.name: viewable.signals}, columns, params.get("start", 0), params.get("stop"),
                               params.get("maxPoints", 2000))
        result["frameRate"] = viewable.rate()
        return result

    # -- views ---------------------------------------------------------------------------------

    def views__list(self, params: dict) -> list:
        return self._require_project().views(params["entityType"]).list()

    def views__save(self, params: dict) -> dict:
        view = self._require_project().views(params["entityType"]).save(params["view"])
        self.emit("views", {"entityType": params["entityType"]})
        return view

    def views__delete(self, params: dict) -> dict:
        self._require_project().views(params["entityType"]).delete(params["name"])
        self.emit("views", {"entityType": params["entityType"]})
        return {"removed": params["name"]}

    # -- notes ---------------------------------------------------------------------------------

    def notes__list(self, params: dict) -> list:
        project = self._require_project()
        types = [params["entityType"]] if "entityType" in params else project.entity_types
        if "key" in params and "entityType" not in params:
            raise NansenError("invalid-params", "a key needs its entityType")
        notes = []
        for entity_type in types:
            notes += [dict(n, entityType=entity_type) for n in project.notebook(entity_type).notes(params.get("key"))]
        notes.sort(key=lambda n: n["createdAt"], reverse=True)  # stable: within a type, newest first already
        return notes

    def notes__add(self, params: dict) -> dict:
        notebook = self._require_project().notebook(params["entityType"])
        note = notebook.add(params["key"], params.get("text", ""), title=params.get("title", ""),
                            note_type=params.get("type", "informal"), author=params.get("author"))
        self.emit("notes", {"entityType": params["entityType"], "key": note["key"]})
        return dict(note, entityType=params["entityType"])

    def notes__remove(self, params: dict) -> dict:
        notebook = self._require_project().notebook(params["entityType"])
        if isinstance(params["id"], bool) or not isinstance(params["id"], int):
            raise NansenError("invalid-params", "a note's id is an integer")
        notebook.remove(params["id"])
        self.emit("notes", {"entityType": params["entityType"]})
        return {"removed": params["id"]}

    # -- fragments, data, methods -------------------------------------------------------------

    def fragments__list(self, params: dict) -> list:
        project = self._require_project()
        return [dict(self._fragment_summary(f), source="project" if project.fragment_path(f.id).is_file() else "module")
                for f in project.fragments()]

    @staticmethod
    def _fragment_summary(f) -> dict:
        return {"id": f.id, "version": f.version, "title": f.document.get("title", f.id),
                "description": f.document.get("description", ""), "computed": "compute" in f.document,
                "columns": f.document["columns"]}

    def fragments__save(self, params: dict) -> dict:
        """Change a project fragment's definition (not its columns' names, types or order)."""
        project = self._require_project()
        fragment = project.save_fragment(params["document"])
        self.emit("entities", {"entityTypes": [e["name"] for e in project.document["entityTypes"]
                                               if fragment.id in e.get("fragments", [])]})
        return self._fragment_summary(fragment)

    def fragments__create(self, params: dict) -> dict:
        """Save a project fragment (the document); with entityType, also add it to that entity type."""
        project = self._require_project()
        document = check_document(params["document"], "nansen.fragment")
        entity_type = params.get("entityType")
        if entity_type is not None:
            names = {c["name"] for c in document["columns"]}
            clash = sorted(set(project.table(entity_type).spec.column_names) & names)
            if clash:  # checked before anything is written
                raise NansenError("column-exists", f"{entity_type} already has column(s) {', '.join(clash)}")
        if any(f.id == document["id"] for f in project.fragments()):
            raise NansenError("fragment-exists", f"the project already has a fragment {document['id']!r}")
        project.add_fragment(document)
        if entity_type is not None:
            project.attach_fragment(entity_type, document["id"])
            self.emit("entities", {"entityTypes": [entity_type]})
        return self._fragment_summary(project.fragment(document["id"]))

    def fragments__attach(self, params: dict) -> dict:
        project = self._require_project()
        project.attach_fragment(params["entityType"], params["fragmentId"])
        self.emit("entities", {"entityTypes": [params["entityType"]]})
        return {"entityType": params["entityType"], "fragments": project.entity_type(params["entityType"])["fragments"]}

    def fragments__detach(self, params: dict) -> dict:
        project = self._require_project()
        project.detach_fragment(params["entityType"], params["fragmentId"])
        self.emit("entities", {"entityTypes": [params["entityType"]]})
        return {"entityType": params["entityType"], "fragments": project.entity_type(params["entityType"]).get("fragments", [])}

    def columns__reset(self, params: dict) -> dict:
        project = self._require_project()
        count = project.reset_column(params["entityType"], params["column"], params.get("keys"))
        self.emit("entities", {"entityTypes": [params["entityType"]]})
        return {"reset": count}

    def columns__import(self, params: dict) -> dict:
        """A column of an entity type imported from a code file (dev's Import Table Variable): dev's table variable
        function or class, or a method of the rebuild that computes it."""
        project = self._require_project()
        if not isinstance(params.get("path"), str) or not params["path"]:
            raise NansenError("invalid-params", "columns.import needs the path of a .m or .py file")
        path = Path(params["path"]).expanduser()
        imported = project.import_column(params["entityType"], path if path.is_absolute() else project.folder / path,
                                         params.get("dataType"), params.get("title", ""), params.get("columns"), params.get("id"))
        self.emit("project", {"name": project.name})
        self.emit("entities", {"entityTypes": [params["entityType"]]})
        method = imported["method"]
        return {"fragment": self._fragment_summary(imported["fragment"]), "method": method.summary() if method else None,
                "files": imported["files"]}

    def fragments__update(self, params: dict) -> dict:
        project = self._require_project()
        summary = project.update_fragment(params["entityType"], params["fragmentId"], params.get("keys"))
        self.emit("entities", {"entityTypes": [params["entityType"]]})
        return summary

    def dataVariables__list(self, params: dict) -> list:
        project = self._require_project()
        return [v.document for v in project.data_variables(params.get("entityType"))]

    def dataVariables__options(self, params: dict) -> dict:
        """What a data variable of the entity type can name: the locations (with the file patterns of
        the entity type's level in each) and the file adapters."""
        project = self._require_project()
        project.entity_type(params["entityType"])
        dataset = project.require_dataset()
        locations = []
        for location in dataset.config.locations:
            locations.append({"id": location["identifier"], "title": location.get("displayName", location["identifier"]),
                              "access": location.get("access", "read"),
                              "filePatterns": sorted(project.file_patterns(location["identifier"], params["entityType"]))})
        return {"locations": locations, "fileAdapters": list(project.adapters.ids)}

    def adapters__create(self, params: dict) -> dict:
        """Start a project file adapter from the templates: its document, and a class to fill in per language."""
        project = self._require_project()
        result = project.create_adapter(params["id"], params.get("title", ""), params.get("extensions", []),
                                        params.get("languages", ["python", "matlab"]))
        self.emit("project", {"name": project.name})
        return result

    def adapters__import(self, params: dict) -> dict:
        """File adapters copied into the project from a document file or a folder, with their code (dev's Import File
        Adapter)."""
        project = self._require_project()
        if not isinstance(params.get("path"), str) or not params["path"]:
            raise NansenError("invalid-params", "adapters.import needs the path of a file adapter document or a folder")
        path = Path(params["path"]).expanduser()
        result = project.import_adapter(path if path.is_absolute() else project.folder / path)   # relative: to the project
        self.emit("project", {"name": project.name})
        return result

    def dataVariables__save(self, params: dict) -> dict:
        variable = self._require_project().add_data_variable(params["document"])
        self.emit("project", {"name": self.project.name})
        return variable.document

    def dataVariables__delete(self, params: dict) -> dict:
        self._require_project().delete_data_variable(params["name"])
        self.emit("project", {"name": self.project.name})
        return {"removed": params["name"]}

    def modules__list(self, params: dict) -> list:
        """The modules that can be listed (in the project's modules/ folder or built in), and whether they are."""
        from .modules import available_modules

        project = self._require_project()
        listed = {m["id"] for m in project.document.get("modules", [])}
        found = {m.id: m for m in available_modules(project.folder)}
        for module in project.modules:  # a listed module at its own path
            found.setdefault(module.id, module)
        return [dict(m.summary(), listed=m.id in listed) for m in found.values()]

    def modules__add(self, params: dict) -> dict:
        project = self._require_project()
        project.add_module(params["id"], params.get("path"))
        self._set_project(Project.open(project.folder, environment=project.environment))
        self.emit("project", {"name": self.project.name})
        return self.project__info({})

    def modules__remove(self, params: dict) -> dict:
        project = self._require_project()
        project.remove_module(params["id"])
        self._set_project(Project.open(project.folder, environment=project.environment))
        self.emit("project", {"name": self.project.name})
        return self.project__info({})

    def data__status(self, params: dict) -> list:
        project = self._require_project()
        return project.data_status(self._entity(params))

    def data__frame(self, params: dict) -> dict:
        """A frame (or a projection) of an image variable, scaled to 8 bits, with the ROIs of another variable and the
        stack's metadata (frameRate, pixelSize, zStep, as its files give them)."""
        project = self._require_project()
        entity = self._entity(params)
        limits = params.get("limits")
        if limits is not None and (not isinstance(limits, list) or len(limits) != 2):
            raise NansenError("invalid-params", "limits is [low, high]")
        stack = project.open_stack(entity, params["variable"])
        result = image_frame(stack, int(params.get("frame", 0)), int(params.get("channel", 0)), params.get("projection"), limits,
                             int(params.get("plane", 0)), params.get("filter"), _bin_of(params))
        result["metadata"] = _entity_metadata(stack.metadata, entity)
        at = int(params.get("plane", 0)) + 1, int(params.get("channel", 0)) + 1
        if params.get("rois"):   # those of the plane and channel shown, when they have places; none before the first is saved
            result["rois"] = roi_outlines(rois_at(self._rois_of(project, entity, params["rois"]), *at))
        also = params.get("alsoRois", [])
        if not isinstance(also, list) or not all(isinstance(name, str) for name in also):
            raise NansenError("invalid-params", "alsoRois is a list of ROI variables")
        if also:   # roimanager's showRoiGroups: other ROI groups, shown beside those edited
            result["roiGroups"] = [{"variable": name, "rois": roi_outlines(rois_at(self._rois_of(project, entity, name), *at))} for name in also]
        return result

    def data__traces(self, params: dict) -> dict:
        """Columns of signal variables (frames x ROIs) of an entity, a frame range thinned to maxPoints."""
        project = self._require_project()
        entity = self._entity(params)
        names = params.get("variables")
        if not isinstance(names, list) or not names:
            raise NansenError("invalid-params", "variables is a list of data variable names")
        columns = params.get("columns", [0])
        if not isinstance(columns, list) or not all(isinstance(c, int) and not isinstance(c, bool) for c in columns):
            raise NansenError("invalid-params", "columns is a list of 0-based column numbers")
        values = {name: project.load(entity, name) for name in names}
        result = signal_traces(values, columns, params.get("start", 0), params.get("stop"), params.get("maxPoints", 2000))
        result["frameRate"] = _frame_rate(params, entity, project.sidecar_metadata(entity, names[0]).get("frameRate"))
        for trace in result["traces"]:   # what each column is, when the data variable says (a time series' columns)
            names = project.data_variable(trace["variable"]).document.get("columnNames")
            if names:
                trace["columnNames"] = list(names)
        if params.get("rois"):
            result["rois"] = [{"id": r["id"], "classification": r["classification"]}
                              for r in roi_outlines(project.load(entity, params["rois"]))]
        return result

    def data__value(self, params: dict) -> dict:
        """The value of a JSON data variable of an entity (as ophys.roi_images saves), for a page to show."""
        project = self._require_project()
        variable = project.data_variable(params["variable"])
        if variable.file_adapter != "json":
            raise NansenError("invalid-params", f"{variable.name} is not a JSON variable; data.frame and data.traces read arrays")
        return {"value": project.load(self._entity(params), variable.name)}

    def data__cache(self, params: dict) -> dict:
        """The project's data cache: what load keeps in memory (dev's DataCache)."""
        return self._require_project().data_cache.stats()

    def data__clearCache(self, params: dict) -> dict:
        """Empty the project's data cache; the next load of each variable reads its file."""
        cache = self._require_project().data_cache
        cache.clear()
        return cache.stats()

    def rois__update(self, params: dict) -> dict:
        """Classify, remove and add ROIs in an ROI variable of an entity, and save it."""
        project = self._require_project()
        entity = self._entity(params)
        plane, channel = int(params.get("plane", 0)) + 1, int(params.get("channel", 0)) + 1
        if not project.data_variable_path(params["variable"]).is_file():   # a new ROI variable, as roimanager's Save Rois as
            project.add_data_variable(dict(project.new_variable_document(entity, params["variable"], {}), dataType="RoiArray"))
        current = self._rois_of(project, entity, params["variable"], cached=False)
        if params.get("imageSize") and "imageSize" not in current:
            current = dict(current, imageSize=params["imageSize"])
        mirror = params.get("mirror", False)
        if not isinstance(mirror, bool):
            raise NansenError("invalid-params", "mirror is true or false")
        aligned, first_id = (self._aligned_rois(project, entity, params, current) if mirror else ([], 1))
        document, added = self._edit_rois(current, plane, channel, params, first_id,
                                          lambda spec: self._imported_rois(project, entity, spec))
        project.save(entity, params["variable"], document)
        result = {"rois": roi_outlines(rois_at(document, plane, channel)), "added": added}
        if mirror:   # the same change made to the ROIs of the entities aligned with this one (dev's synchEntries 'Mirror')
            before, after = roi_outlines(rois_at(current, plane, channel)), roi_outlines(rois_at(document, plane, channel))
            alignment = current["alignment"]
            source = alignment_entry(alignment, entity.key)
            result["mirrored"] = []
            for other, entry, value in aligned:
                value, summary = mirror_rois_at(value, plane, channel, before, after, source, entry, alignment["imageSize"])
                project.save(other, entry["variable"], value)
                result["mirrored"].append(dict(key=dict(other.key), **summary))
        return result

    @staticmethod
    def _edit_rois(current: Any, plane: int, channel: int, params: dict, first_id: int,
                   imported: Callable[[dict], Any]) -> Any:
        """rois.update's changes to an ROI document at a plane and channel (from 1), in its order, the import last:
        (document, ids of the added ROIs). imported(spec) gives the ROIs an import takes. view.updateRois makes the
        same changes to a viewable's ROIs."""
        document, added = update_rois_at(current, plane, channel,
                                         classify=params.get("classify"), remove=params.get("remove"), add=params.get("add"),
                                         move=params.get("move"), merge=params.get("merge"), pixels=params.get("pixels"),
                                         restore=params.get("restore"), cell_type=params.get("cellType"), link=params.get("link"),
                                         first_id=first_id)
        if params.get("import") is not None:   # roimanager's loaded ROIs, or a segmentation's, added to these
            spec = params["import"]
            if not isinstance(spec, dict):
                raise NansenError("invalid-params", "import is an object: where the ROIs come from, and a mode")
            document, imported_ids = import_rois_at(document, plane, channel, imported(spec), spec.get("mode", "append"), first_id)
            added = added + imported_ids
        return document, added

    def _aligned_rois(self, project, entity, params: dict, current: Any) -> Any:
        """The entities aligned with this one by the alignment its ROI file has (ophys.align_sessions writes it): each
        with its alignment entry and ROI file, those gone or with no file left out; and the first id that is free in all
        of them, for ROIs added. invalid-params when the file has no alignment, or this entity is not in it."""
        alignment = current.get("alignment") if isinstance(current, dict) else None
        if alignment_entry(alignment, entity.key) is None or not isinstance(alignment.get("imageSize"), list):
            raise NansenError("invalid-params", f"the ROIs of {params['variable']} were not aligned with other entities' "
                                                "(ophys.align_sessions): there is nothing to mirror the change to")
        aligned, largest = [], max([int(r["id"]) for r in roi_outlines(current)] + [0])
        for entry in alignment["entities"]:
            if alignment_entry({"entities": [entry]}, entity.key) is not None:
                continue
            try:
                other = project.entity(params["entityType"], entry["key"])
                value = project.load(other, entry["variable"], cached=False)
            except NansenError as error:
                if error.code not in ("unknown-entity", "data-not-found", "unknown-data-variable"):
                    raise
                continue
            aligned.append((other, entry, value))
            largest = max([largest] + [int(r["id"]) for r in roi_outlines(value)])
        return aligned, largest + 1

    def _imported_rois(self, project, entity, spec: dict) -> Any:
        """The ROIs rois.update imports: another ROI variable of the entity, or a file (as files.resolve takes it) read
        by a file adapter (the json adapter for a .json file, when none is given), or a folder read by the adapter
        given, as ophys.suite2p_rois reads suite2p's output folder."""
        if spec.get("variable"):
            return project.load(entity, spec["variable"])
        if not spec.get("path"):
            raise NansenError("invalid-params", "import names an ROI variable or a file's path")
        resolved = self.files__resolve(spec)
        if not resolved["exists"]:
            raise NansenError("file-not-found", f"{resolved['path']} is not a file or folder")
        path = Path(resolved["path"])
        adapter = spec.get("adapter") or ("json" if path.suffix.lower() == ".json" and not resolved["isFolder"] else None)
        if not adapter:
            raise NansenError("invalid-params", f"which file adapter reads {path.name}? Give the import's adapter")
        if not resolved["isFolder"]:
            return project.adapters.get(adapter).read(path)
        reader = project.adapters.get(adapter)
        try:
            return reader.read(path)
        except Exception as error:   # an adapter of files, given a folder: it cannot open it
            if isinstance(error, NansenError) and error.code != "file-not-found":
                raise
            raise NansenError("invalid-data", f"{adapter} does not read the folder {path.name}") from None

    @staticmethod
    def _rois_of(project, entity, name, cached=True):
        """An ROI variable's value, or no ROIs when the entity has no file of it yet (or the project no such variable)."""
        try:
            return project.load(entity, name, cached=cached)
        except NansenError as error:
            if error.code not in ("data-not-found", "unknown-data-variable"):
                raise
            return {"rois": []}

    def rois__detect(self, params: dict) -> dict:
        """The pixels of an ROI found around a point of an image or stack variable, in one of dev's autodetection modes
        (nansen.autodetect; mode 0, the threshold of the stack's mean)."""
        project = self._require_project()
        entity = self._entity(params)
        point = params.get("point")
        if not isinstance(point, list) or len(point) != 2:
            raise NansenError("invalid-params", "point is [row, column]")
        stack, _, _ = pick_channel(project.open_stack(entity, params["variable"]), int(params.get("channel", 0)), int(params.get("plane", 0)))
        return {"pixels": autodetect_roi(stack, point, int(params.get("radius", 6)), params.get("mode", 1), _detect_image(stack, params))}

    def rois__neuropil(self, params: dict) -> dict:
        """An ROI's neuropil, as ophys.extract_signals takes it (nansen.frames.neuropil_masks), among the ROIs of its
        plane and channel: the viewer's neuropil overlay, as dev's roimanager's showNeuropilMask."""
        project = self._require_project()
        entity = self._entity(params)
        plane, channel = int(params.get("plane", 0)) + 1, int(params.get("channel", 0)) + 1
        options = self._neuropil_options(project, params)
        document = rois_at(self._rois_of(project, entity, params["variable"]), plane, channel)
        size = (document.get("imageSize") if isinstance(document, dict) else None) or params.get("imageSize")
        if not isinstance(size, list) or len(size) != 2:
            raise NansenError("invalid-params", f"the ROIs of {params['variable']} have no imageSize: give it")
        pixels, slices = roi_neuropil(document, params.get("roi"), options, int(size[0]), int(size[1]))
        result = {"roi": params.get("roi"), "pixels": pixels, "options": options}
        if options["numNeuropilSlices"] > 1:
            result["slices"] = slices
        return result

    def _neuropil_options(self, project, params: dict) -> dict:
        """rois.neuropil's options: those given on ophys.extract_signals's defaults, or with methodId, the method's
        options as methods.run takes them (its preset, or the preferred one when neither a preset nor options are
        given, with the options on top), validated by its schema."""
        values = params.get("options") or {}
        if not isinstance(values, dict):
            raise NansenError("invalid-params", "options is an object")
        if params.get("methodId"):
            method = project.method(params["methodId"])
            preset = self._preset_of(params)
            values = method.resolve_options(dict(project.preset(method.id, preset) if preset else {}, **values))
        options = {name: values.get(name, default) for name, default in NEUROPIL_DEFAULTS.items()}
        whole = lambda v, low: isinstance(v, (int, float)) and not isinstance(v, bool) and float(v).is_integer() and v >= low
        if options["neuropilMethod"] not in ("ring", "expansion") or not whole(options["neuropilGap"], 0) \
                or not whole(options["neuropilWidth"], 1) or not whole(options["neuropilSeparation"], 0) \
                or not whole(options["maxNeuropilRadius"], 1) or not whole(options["numNeuropilSlices"], 1) \
                or not isinstance(options["neuropilExpansionFactor"], (int, float)) or isinstance(options["neuropilExpansionFactor"], bool) \
                or not options["neuropilExpansionFactor"] > 0 or not isinstance(options["includeRejected"], bool):
            raise NansenError("invalid-options", "the neuropil is a ring (neuropilGap 0 or more, neuropilWidth 1 or more) or an "
                                                 "expansion (neuropilExpansionFactor above 0, neuropilSeparation 0 or more, "
                                                 "maxNeuropilRadius 1 or more), in numNeuropilSlices slices (1 or more)")
        return options

    def rois__signal(self, params: dict) -> dict:
        """An ROI's signal read from a stack now (the mean of its pixels per frame), as data.traces gives one: the
        viewer's live trace of an ROI that was added or changed since the signals were extracted."""
        project = self._require_project()
        entity = self._entity(params)
        pixels = params.get("pixels")
        if not isinstance(pixels, list) or not pixels:
            raise NansenError("invalid-params", "pixels is a list of [row, column] pairs")
        stack, _, _ = pick_channel(project.open_stack(entity, params["variable"]), int(params.get("channel", 0)), int(params.get("plane", 0)))
        start, stop = params.get("start", 0), params.get("stop")
        trace = roi_signal(stack, pixels, start, stop)
        result = signal_traces({params["variable"]: trace}, [0], start, stop, params.get("maxPoints", 2000))
        result["frameRate"] = _frame_rate(params, entity)
        return result

    def methods__list(self, params: dict) -> list:
        project = self._require_project()
        return self._marked_hidden(project, project.methods(params.get("entityType")))

    @staticmethod
    def _marked_hidden(project, methods) -> list:
        """Method summaries, those left out of the run menus with hidden: true."""
        hidden = set(project.hidden_methods())
        return [dict(m.summary(), hidden=True) if m.id in hidden else m.summary() for m in methods]

    def methods__setHidden(self, params: dict) -> list:
        """Leave a method out of the run menus or put it back (dev's Customize Menus); returns methods.list."""
        project = self._require_project()
        hidden = params.get("hidden", True)
        if not isinstance(hidden, bool):
            raise NansenError("invalid-params", "hidden is true or false")
        project.set_method_hidden(params["methodId"], hidden)
        return self.methods__list({})

    def methods__edit(self, params: dict) -> dict:
        """Open a method's code in an editor: in this language unless asked for the other."""
        method = self._require_project().method(params["methodId"])
        files = method.source_files()
        language = params.get("language") or ("python" if "python" in files else next(iter(files), None))
        if language not in files:
            raise NansenError("method-unavailable", f"{method.id} has no {language or 'code'} implementation")
        path = files[language]
        if not path.is_file():
            raise NansenError("file-not-found", f"{path} does not exist")
        self.edit_file(path)
        return {"language": language, "path": str(path)}

    def data__send(self, params: dict) -> dict:
        """Load a data variable of an entity and put it in the workspace the app was opened from."""
        name = params.get("name") or params["variable"]
        if not isinstance(name, str) or not name.isidentifier() or keyword.iskeyword(name):
            raise NansenError("invalid-params", f"{name!r} is not a variable name")
        if self.workspace is None:
            raise NansenError("no-workspace", "this app was not opened from a workspace")
        project = self._require_project()
        value = project.load(self._entity(params), params["variable"])
        self.workspace[name] = value
        return {"name": name, "variable": params["variable"]}

    def tools__list(self, params: dict) -> list:
        project = self._require_project()
        return self._marked_hidden(project, project.tools())

    def tools__run(self, params: dict) -> dict:
        """Run a project tool now; its result and log."""
        project = self._require_project()
        method = project.method(params["methodId"])
        context = MethodContext(project=project, method=method, app_url=self.app_url, open_url=self.open_url)
        result = project.run_tool(method.id, params.get("options"), params.get("preset"), context)
        self.emit("entities", {"entityTypes": project.entity_types})
        return {"result": result, "log": context.lines}

    def methods__create(self, params: dict) -> dict:
        """Start a project method from the templates: its document, and a file to fill in per language."""
        method = self._require_project().create_method(
            params["id"], params.get("title", ""), params.get("entityType", "*"), params.get("description", ""),
            params.get("batchMode", "serial"), params.get("languages", ["python", "matlab"]), params.get("queueable", True),
            params.get("computes"))
        self.emit("project", {"name": self.project.name})
        files = [f"methods/{method.id}.method.nansen.json"] + [
            f"{language}/{method.id}.{'py' if language == 'python' else 'm'}" for language in method.languages]
        if params.get("computes"):
            files.append(f"fragments/{method.id}.fragment.nansen.json")
            self.emit("entities", {"entityTypes": [method.entity_type]})
        return dict(method.summary(), files=files)

    def methods__importLegacy(self, params: dict) -> dict:
        """Import NANSEN dev session methods (a .m file, or a folder of them) as project methods run in MATLAB."""
        if not isinstance(params.get("path"), str) or not params["path"]:
            raise NansenError("invalid-params", "path is a .m file or a folder")
        entity_type = params.get("entityType") or None   # by default sessions, when the project has them
        result = self._require_project().import_legacy_methods(params["path"], entity_type)
        self.emit("project", {"name": self.project.name})
        return result

    def presets__list(self, params: dict) -> list:
        project = self._require_project()
        preferred = project.preferred_preset(params["methodId"])
        return [dict(p, preferred=True) if p["name"] == preferred else p for p in project.presets(params["methodId"])]

    def presets__setDefault(self, params: dict) -> list:
        """Make a preset the one the method runs with when a run gives neither a preset nor options (null: its defaults)."""
        project = self._require_project()
        project.set_preferred_preset(params["methodId"], params.get("name"))
        return self.presets__list(params)

    def _preset_of(self, params: dict):
        """The run's preset: the one given, or, when neither a preset nor options are, the method's preferred one."""
        if params.get("preset") is not None or params.get("options"):
            return params.get("preset")
        return self._require_project().preferred_preset(params["methodId"])

    def presets__save(self, params: dict) -> list:
        project = self._require_project()
        project.save_preset(params["methodId"], params["name"], params.get("values", {}), params.get("description", ""))
        return project.presets(params["methodId"])

    def presets__delete(self, params: dict) -> list:
        project = self._require_project()
        project.delete_preset(params["methodId"], params["name"])
        return project.presets(params["methodId"])

    def methods__run(self, params: dict) -> dict:
        """Run a method now and wait for it (for quick methods); long ones go through tasks.submit. With skipCompleted,
        the entities it already completed on whose outputs are there are left out (skipped)."""
        project = self._require_project()
        method = project.method(params["methodId"])
        params = dict(params, preset=self._preset_of(params))
        if method.languages and "python" not in method.languages:
            return self._run_in_worker(method, params)
        entities, skipped = self._entities(params), []
        if _flag(params, "skipCompleted"):
            values = project.preset(method.id, params["preset"]) if params.get("preset") else {}
            done = project.already_done(method.id, entities, dict(values, **(params.get("options") or {})))
            skipped = [dict(e.key) for e, d in zip(entities, done) if d]
            entities = [e for e, d in zip(entities, done) if not d]
        context = MethodContext(project=project, method=method, app_url=self.app_url, open_url=self.open_url)
        try:
            results = project.run(params["methodId"], entities, params.get("options"), params.get("preset"), context) if entities else []
        except Exception:
            self._debug_error()
            raise
        if entities:
            self.emit("entities", {"entityTypes": [params["entityType"]]})
        from .tasks import _json_result
        return {"results": _json_result(results), "skipped": skipped}

    def _debug_error(self) -> None:
        """Stop at the error being handled in the post-mortem debugger, when the user's settings say so (queue.debug, dev's
        SessionTaskDebug) and the app was started from a terminal to debug in."""
        if self.catalog is None or not self.catalog.settings()["queue"].get("debug") or not sys.stdin or not sys.stdin.isatty():
            return
        import pdb
        pdb.post_mortem(sys.exc_info()[2])

    def _run_in_worker(self, method, params: dict) -> dict:
        """Run a method only another language has: queue it for that language, start a worker for it (queue.startWorker)
        and wait for the task. A task no worker has started within startTimeout seconds is cancelled."""
        import time
        from .tasks import TERMINAL

        language = method.languages[0]
        queue = self._queue()
        task = queue.submit(method.id, self._entities(params), params.get("options"), params.get("preset"), language,
                            _flag(params, "skipCompleted"))
        self.queue__startWorker({"language": language})
        started, timeout = time.monotonic(), float(params.get("startTimeout", WORKER_START_SECONDS))
        while task["status"] not in TERMINAL:
            if task["status"] == "queued" and time.monotonic() - started > timeout:
                queue.cancel(task["id"])
                raise NansenError("task-failed", f"no {language} worker took {method.id} within {timeout:g} s, so it was "
                                  f"cancelled; see tasks/worker-{language}.log")
            time.sleep(0.2)
            task = queue.get(task["id"])
        self.emit("entities", {"entityTypes": [params["entityType"]]})
        if task["status"] != "completed":
            message = (task.get("error") or {}).get("message", "")
            raise NansenError("task-failed", f"{method.id} {task['status']} in a {language} worker" + (f": {message}" if message else ""))
        result = task.get("result")
        if len(task["entities"]) == len(task.get("skipped", [])):
            results = []   # every entity was left out
        else:
            results = result if method.batch_mode == "serial" else [result]
        return {"results": results, "skipped": task.get("skipped", []), "taskId": task["id"], "language": language}

    def methods__preview(self, params: dict) -> dict:
        """Run a method on the first frames of one entity's stacks, saving nothing (nansen.preview); with a column, on
        that column of the signals it loads, giving its outputs of one column as traces."""
        from .preview import FRAMES, MAX_POINTS, preview
        project = self._require_project()
        return preview(project, params["methodId"], self._entity(params), params.get("options"), params.get("preset"),
                       int(params.get("frames", FRAMES)), params.get("column"), int(params.get("maxPoints", MAX_POINTS)))

    # -- tasks --------------------------------------------------------------------------------

    def _queue(self) -> TaskQueue:
        self._require_project()
        return self.queue

    def tasks__submit(self, params: dict) -> dict:
        return self._queue().submit(params["methodId"], self._entities(params), params.get("options"),
                                    self._preset_of(params), params.get("language"), _flag(params, "skipCompleted"))

    def pipelines__list(self, params: dict) -> list:
        project = self._require_project()
        return [dict(p, source=project.pipeline_source(p["id"]),
                     steps=[dict(s, title=s.get("title") or project.method(s["method"]).title) for s in p["steps"]])
                for p in project.pipelines(params.get("entityType"))]

    def pipelines__save(self, params: dict) -> dict:
        document = self._require_project().save_pipeline(params["document"])
        self.emit("pipelines", {"id": document["id"]})
        return document

    def pipelines__delete(self, params: dict) -> dict:
        self._require_project().delete_pipeline(params["pipelineId"])
        self.emit("pipelines", {"id": params["pipelineId"]})
        return {"removed": params["pipelineId"]}

    def pipelines__assign(self, params: dict) -> dict:
        project = self._require_project()
        count = project.assign_pipeline(params["entityType"], params.get("keys"), params.get("pipelineId"))
        self.emit("entities", {"entityTypes": [params["entityType"]]})
        return {"assigned": count}

    def pipelines__markStep(self, params: dict) -> dict:
        """Mark a step (its method) done or not done for entities by hand, as dev's pipeline viewer's checkboxes."""
        project = self._require_project()
        method = project.method(params["method"])
        keys = params.get("keys") or []
        if not isinstance(params.get("done"), bool) or not keys:
            raise NansenError("invalid-params", "markStep takes keys (one or more) and done (true or false)")
        entities = [project.entity(params["entityType"], key) for key in keys]
        runs.record(project.folder, method.id, method.version, entities, mark="done" if params["done"] else "undone")
        self.emit("entities", {"entityTypes": [params["entityType"]]})
        return {"marked": len(entities)}

    def pipelines__queueNext(self, params: dict) -> dict:
        """For each entity with a pipeline, queue the steps not done yet (from the first not done on)."""
        project = self._require_project()
        progress = project.pipeline_progress(params["entityType"])
        in_flight = {(t["pipeline"]["id"], runs.key_id(t["entities"][0]["key"])) for t in self._queue().list()
                     if t.get("pipeline") and t["status"] in ("queued", "running")}
        by_pipeline: Dict[str, list] = {}
        skip: Dict[Any, set] = {}
        skipped, manual = [], []
        for entity in self._entities(params):
            state = progress.get(runs.key_id(entity.key))
            if state is None or state["done"] == state["total"] or (state["pipeline"], runs.key_id(entity.key)) in in_flight:
                skipped.append(entity.key)  # no pipeline, all done, or its steps are queued already
                continue
            steps = state["steps"]
            first = next(i for i, s in enumerate(steps) if not s["done"])
            if not steps[first]["queueable"]:  # a step to run by hand comes next
                manual.append({"key": entity.key, "step": first, "method": steps[first]["method"], "title": steps[first]["title"]})
                continue
            stop = next((i for i in range(first, len(steps)) if not steps[i]["queueable"]), len(steps))
            skip[runs.key_id(entity.key)] = set(range(first)) | set(range(stop, len(steps)))  # up to a manual step
            by_pipeline.setdefault(state["pipeline"], []).append(entity)
        tasks = []
        for pipeline_id, entities in by_pipeline.items():
            tasks += self._queue().submit_pipeline(pipeline_id, entities, params.get("language"), skip=skip)
        return {"tasks": tasks, "skipped": skipped, "manual": manual}

    def pipelines__runNext(self, params: dict) -> dict:
        """For each entity with a pipeline, run its next step not done now, in the foreground (manual steps too); with step
        (an index from 0), that step, done or not (dev's pipeline viewer runs any step)."""
        project = self._require_project()
        entity_type = params["entityType"]
        progress = project.pipeline_progress(entity_type)
        pipelines = {p["id"]: p for p in project.pipelines(entity_type)}
        in_flight = {runs.key_id(t["entities"][0]["key"]) for t in self._queue().list()
                     if t.get("pipeline") and t["status"] in ("queued", "running")}
        chosen = params.get("step")
        if chosen is not None and (isinstance(chosen, bool) or not isinstance(chosen, (int, float)) or chosen != int(chosen) or chosen < 0):
            raise NansenError("invalid-params", "step is the index of a step, from 0")
        ran, skipped = [], []
        for entity in self._entities(params):
            state = progress.get(runs.key_id(entity.key))
            if state is None or runs.key_id(entity.key) in in_flight or (chosen is None and state["done"] == state["total"]):
                skipped.append(entity.key)
                continue
            if chosen is not None and chosen >= state["total"]:
                raise NansenError("invalid-params", f"pipeline {state['pipeline']!r} has {state['total']} steps; step {int(chosen)} is not one")
            first = int(chosen) if chosen is not None else next(i for i, s in enumerate(state["steps"]) if not s["done"])
            step = pipelines[state["pipeline"]]["steps"][first]
            method = project.method(step["method"])
            if method.languages and "python" not in method.languages:   # in a worker of the language it has
                result = self._run_in_worker(method, {"methodId": method.id, "entityType": entity_type, "keys": [entity.key],
                                                      "options": step.get("options"), "preset": step.get("preset")})["results"]
            else:
                result = project.run(step["method"], [entity], step.get("options"), step.get("preset"))
            ran.append({"key": entity.key, "step": first, "method": step["method"], "result": result[0] if result else None})
        if ran:
            self.emit("entities", {"entityTypes": [entity_type]})
        return {"ran": ran, "skipped": skipped}

    def pipelines__submit(self, params: dict) -> list:
        return self._queue().submit_pipeline(params["pipelineId"], self._entities(params), params.get("language"))

    def tasks__comment(self, params: dict) -> dict:
        return self._queue().comment(params["id"], params.get("comment", ""))

    def tasks__list(self, params: dict) -> list:
        return self._queue().list(params.get("status"))

    def tasks__get(self, params: dict) -> dict:
        queue = self._queue()
        return dict(queue.get(params["id"]), logText=queue.log(params["id"]))

    def tasks__cancel(self, params: dict) -> dict:
        return self._queue().cancel(params["id"])

    def tasks__retry(self, params: dict) -> dict:
        skip = params.get("skipCompleted")
        return self._queue().retry(params["id"], None if skip is None else _flag(params, "skipCompleted"))

    def tasks__hold(self, params: dict) -> dict:
        return self._queue().hold(params["id"], params.get("hold", True))

    def tasks__update(self, params: dict) -> dict:
        return self._queue().update(params["id"], params.get("options"), params.get("preset"))

    def tasks__reorder(self, params: dict) -> list:
        return self._queue().reorder(list(params["ids"]))

    def tasks__remove(self, params: dict) -> dict:
        self._queue().remove(params["id"])
        return {"removed": params["id"]}

    def tasks__clear(self, params: dict) -> dict:
        return {"removed": self._queue().clear()}

    def tasks__runNext(self, params: dict) -> Optional[dict]:
        """Run the oldest queued task now (when the background worker is off)."""
        return self._queue().run_next()

    def queue__status(self, params: dict) -> dict:
        queue = self._queue()
        counts: Dict[str, int] = {}
        for task in queue.list():
            counts[task["status"]] = counts.get(task["status"], 0) + 1
        return {"running": queue.running, "executor": "python", "worker": queue.executor, "counts": counts}

    def queue__startWorker(self, params: dict) -> dict:
        """Start a worker for the tasks of a language: this app's own, or a MATLAB one (matlab -batch nansen.worker)
        for tasks only MATLAB runs, which stops when none is left. Its output goes to tasks/worker-matlab.log."""
        language = params.get("language")
        if language == "python":
            return self.queue__start(params)
        if language != "matlab":
            raise NansenError("invalid-params", "language is python or matlab")
        import subprocess

        project = self._require_project()
        executable = self._matlab()
        if not executable:
            raise NansenError("dependency-missing", "no MATLAB found: put matlab on the PATH, or set its path in Settings")
        script = self._matlab_script(f"nansen.worker({_matlab_text(project.folder)}, UntilEmpty=true)")
        if project.environment:
            script = script[:-1] + f", Environment={_matlab_text(project.environment)})"
        log = project.folder / "tasks" / "worker-matlab.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        with open(log, "ab") as out:
            subprocess.Popen([executable, "-batch", script], stdout=out, stderr=subprocess.STDOUT,
                             stdin=subprocess.DEVNULL, start_new_session=True)
        return {"language": "matlab", "started": True, "log": str(log)}

    def _matlab(self) -> Optional[str]:
        """The MATLAB to run: the one set in Settings, else matlab on the PATH; None when there is none."""
        import shutil

        settings = self.catalog.settings() if self.catalog is not None else {}
        return settings.get("workers", {}).get("matlab") or shutil.which("matlab")

    @staticmethod
    def _matlab_script(script: str) -> str:
        """A matlab -batch script, with nansen's MATLAB code on the path when this package is in a clone beside it."""
        own = Path(__file__).resolve().parents[3] / "matlab"
        return f"addpath({_matlab_text(own)}); " + script if (own / "+nansen").is_dir() else script

    def queue__start(self, params: dict) -> dict:
        self._queue().start()
        return self.queue__status({})

    def queue__stop(self, params: dict) -> dict:
        self._queue().stop(timeout=10)
        return self.queue__status({})
