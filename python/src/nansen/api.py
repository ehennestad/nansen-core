"""The app's API: JSON requests in, JSON responses and events out (docs/reference/protocol.md).

The same methods exist in MATLAB (nansen.Api), so the frontend talks to
either. An Api is given its catalog and opens projects on request; it holds
no global state.
"""

from __future__ import annotations

import json
import keyword
import re
import threading
import traceback
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

import dsm

from . import __version__
from .catalog import Catalog
from .dataset import Dataset
from .documents import check_document
from .entities import Entity
from .errors import NansenError
from .methods import MethodContext
from . import runs
from .project import Project
from .tasks import TaskQueue

PROTOCOL_VERSION = "0.1"


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


FILES_LIST_LIMIT = 500  # entries files.list gives at most, unless asked for more

class Api:
    def __init__(self, catalog: Optional[Catalog] = None, project: Optional[Project] = None,
                 executor: str = "thread", start_queue: bool = True):
        self.catalog = catalog
        self.project: Optional[Project] = None
        self.queue: Optional[TaskQueue] = None
        self.executor = executor
        self.start_queue = start_queue
        self._listeners: List[Listener] = []
        # Opens a folder in the system's file browser; tests put their own here
        self.open_folder: Callable[[Path], None] = open_in_file_browser
        # Where workspace.send puts entities: a namespace such as a notebook's globals(), or None for none
        self.workspace: Optional[Dict[str, Any]] = None
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

    def close(self) -> None:
        if self.queue is not None:
            self.queue.stop(timeout=5)

    # -- helpers ---------------------------------------------------------------------------------

    def _require_project(self) -> Project:
        if self.project is None:
            raise NansenError("no-project", "no project is open")
        return self.project

    def _set_project(self, project: Project) -> None:
        if self.queue is not None:
            self.queue.stop(timeout=5)
        self.project = project
        self.queue = TaskQueue(project, executor=self.executor,
                               on_event=lambda kind, data: self.emit(kind, data))
        if self.start_queue:
            self.queue.start()
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

    def app__info(self, params: dict) -> dict:
        return {"name": "nansen", "language": "python", "version": __version__, "protocolVersion": PROTOCOL_VERSION,
                "methods": self.method_names, "workspace": self.workspace is not None}

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

    def catalog__remove(self, params: dict) -> list:
        if self.catalog is None:
            raise NansenError("no-catalog", "this app has no project catalog")
        self.catalog.remove(params["path"])
        return self.catalog.projects()

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
        for module in params.get("modules", []):
            project.add_module(module)
        if params.get("entityTypes"):
            core = any(m["id"] == "core" for m in project.document.get("modules", []))
            added = project.add_dataset_entity_types(["core.notes"] if core else [])
            if core and "subject" in added:  # as dev's subject table: date of birth, sex, species
                project.attach_fragment("subject", "core.subject")

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
        from .demo import create_demo

        self._set_project(create_demo(params["path"]))
        self.emit("project", {"name": self.project.name})
        return self.project__info({})

    def legacy__import(self, params: dict) -> dict:
        """A project from a NANSEN dev project; Python reads the JSON export that MATLAB writes."""
        from .legacy import convert_legacy

        source = Path(params["source"])
        if source.is_dir():
            raise NansenError("legacy-needs-matlab", "reading a NANSEN dev project folder needs MATLAB: export it "
                                                     "with nansen.legacy.exportProject, then import the JSON file")
        if not source.is_file():
            raise NansenError("file-not-found", f"no file {source}")
        with open(source, encoding="utf-8") as f:
            report = convert_legacy(json.load(f), params["path"])
        self._set_project(Project.open(params["path"]))
        self.emit("project", {"name": self.project.name})
        return {"project": self.project__info({}), "warnings": report["warnings"]}

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
        result = {"scannedAt": scan.scanned_at, "records": counts, "roots": scan.roots, "unmatched": len(scan.unmatched)}
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
        return self._row(entity, project.table(params["entityType"]))

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

    def files__resolve(self, params: dict) -> dict:
        project = self._require_project()
        relative = str(params.get("path", ""))
        if relative.startswith(("/", "\\")) or re.match(r"^[A-Za-z]:", relative):
            raise NansenError("invalid-params", f"{relative!r} is not a relative path")
        if "dataLocation" in params:
            base = project.require_dataset().root(params["dataLocation"], params.get("rootStoragePath")).path
        else:
            base = project.folder
        base = Path(base).resolve()
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

    def files__reveal(self, params: dict) -> dict:
        resolved = self.files__resolve(params)
        if not resolved["exists"]:
            raise NansenError("file-not-found", f"{resolved['path']} does not exist")
        path = Path(resolved["path"])
        self.open_folder(path if resolved["isFolder"] else path.parent)
        return resolved

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
        return [self._fragment_summary(f) for f in project.fragments()]

    @staticmethod
    def _fragment_summary(f) -> dict:
        return {"id": f.id, "version": f.version, "title": f.document.get("title", f.id),
                "description": f.document.get("description", ""), "computed": "compute" in f.document,
                "columns": f.document["columns"]}

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

    def methods__list(self, params: dict) -> list:
        project = self._require_project()
        return [m.summary() for m in project.methods(params.get("entityType"))]

    def tools__list(self, params: dict) -> list:
        return [m.summary() for m in self._require_project().tools()]

    def tools__run(self, params: dict) -> dict:
        """Run a project tool now; its result and log."""
        project = self._require_project()
        method = project.method(params["methodId"])
        context = MethodContext(project=project, method=method)
        result = project.run_tool(method.id, params.get("options"), params.get("preset"), context)
        self.emit("entities", {"entityTypes": project.entity_types})
        return {"result": result, "log": context.lines}

    def methods__create(self, params: dict) -> dict:
        """Start a project method from the templates: its document, and a file to fill in per language."""
        method = self._require_project().create_method(
            params["id"], params.get("title", ""), params.get("entityType", "*"), params.get("description", ""),
            params.get("batchMode", "serial"), params.get("languages", ["python", "matlab"]))
        self.emit("project", {"name": self.project.name})
        files = [f"methods/{method.id}.method.nansen.json"] + [
            f"{language}/{method.id}.{'py' if language == 'python' else 'm'}" for language in method.languages]
        return dict(method.summary(), files=files)

    def presets__list(self, params: dict) -> list:
        return self._require_project().presets(params["methodId"])

    def presets__save(self, params: dict) -> list:
        project = self._require_project()
        project.save_preset(params["methodId"], params["name"], params.get("values", {}), params.get("description", ""))
        return project.presets(params["methodId"])

    def presets__delete(self, params: dict) -> list:
        project = self._require_project()
        project.delete_preset(params["methodId"], params["name"])
        return project.presets(params["methodId"])

    def methods__run(self, params: dict) -> dict:
        """Run a method now and wait for it (for quick methods); long ones go through tasks.submit."""
        project = self._require_project()
        results = project.run(params["methodId"], self._entities(params), params.get("options"), params.get("preset"))
        self.emit("entities", {"entityTypes": [params["entityType"]]})
        from .tasks import _json_result
        return {"results": _json_result(results)}

    # -- tasks --------------------------------------------------------------------------------

    def _queue(self) -> TaskQueue:
        self._require_project()
        return self.queue

    def tasks__submit(self, params: dict) -> dict:
        return self._queue().submit(params["methodId"], self._entities(params), params.get("options"),
                                    params.get("preset"), params.get("language"))

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

    def pipelines__queueNext(self, params: dict) -> dict:
        """For each entity with a pipeline, queue the steps not done yet (from the first not done on)."""
        project = self._require_project()
        progress = project.pipeline_progress(params["entityType"])
        in_flight = {(t["pipeline"]["id"], runs.key_id(t["entities"][0]["key"])) for t in self._queue().list()
                     if t.get("pipeline") and t["status"] in ("queued", "running")}
        by_pipeline: Dict[str, list] = {}
        skip: Dict[Any, set] = {}
        skipped = []
        for entity in self._entities(params):
            state = progress.get(runs.key_id(entity.key))
            if state is None or state["done"] == state["total"] or (state["pipeline"], runs.key_id(entity.key)) in in_flight:
                skipped.append(entity.key)  # no pipeline, all done, or its steps are queued already
                continue
            first = next(i for i, s in enumerate(state["steps"]) if not s["done"])
            skip[runs.key_id(entity.key)] = set(range(first))
            by_pipeline.setdefault(state["pipeline"], []).append(entity)
        tasks = []
        for pipeline_id, entities in by_pipeline.items():
            tasks += self._queue().submit_pipeline(pipeline_id, entities, params.get("language"), skip=skip)
        return {"tasks": tasks, "skipped": skipped}

    def pipelines__submit(self, params: dict) -> list:
        return self._queue().submit_pipeline(params["pipelineId"], self._entities(params), params.get("language"))

    def tasks__list(self, params: dict) -> list:
        return self._queue().list(params.get("status"))

    def tasks__get(self, params: dict) -> dict:
        queue = self._queue()
        return dict(queue.get(params["id"]), logText=queue.log(params["id"]))

    def tasks__cancel(self, params: dict) -> dict:
        return self._queue().cancel(params["id"])

    def tasks__retry(self, params: dict) -> dict:
        return self._queue().retry(params["id"])

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
        return {"running": queue.running, "executor": queue.executor, "counts": counts}

    def queue__start(self, params: dict) -> dict:
        self._queue().start()
        return self.queue__status({})

    def queue__stop(self, params: dict) -> dict:
        self._queue().stop(timeout=10)
        return self.queue__status({})
