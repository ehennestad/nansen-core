"""The app's API: JSON requests in, JSON responses and events out (docs/reference/protocol.md).

The same methods exist in MATLAB (nansen.Api), so the frontend talks to
either. An Api is given its catalog and opens projects on request; it holds
no global state.
"""

from __future__ import annotations

import threading
import traceback
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

import dsm

from . import __version__
from .catalog import Catalog
from .entities import Entity
from .errors import NansenError
from .project import Project
from .tasks import TaskQueue

PROTOCOL_VERSION = "0.1"
Listener = Callable[[dict], None]


class Api:
    def __init__(self, catalog: Optional[Catalog] = None, project: Optional[Project] = None,
                 executor: str = "thread", start_queue: bool = True):
        self.catalog = catalog
        self.project: Optional[Project] = None
        self.queue: Optional[TaskQueue] = None
        self.executor = executor
        self.start_queue = start_queue
        self._listeners: List[Listener] = []
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
                "methods": self.method_names}

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
        project = Project.create(params["path"], params["name"], params.get("title"), params.get("dataset"))
        for module in params.get("modules", []):
            project.add_module(module)
        self._set_project(project)
        self.emit("project", {"name": project.name})
        return self.project__info({})

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
        return {"entityType": entity_type, "key": table.spec.key, "columns": columns,
                "rows": [self._row(e, table) for e in entities]}

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
        table.update(key, **params["values"])
        table.write()
        self.emit("entities", {"entityTypes": [params["entityType"]], "keys": [key]})
        entity = project.entity(params["entityType"], key)
        return self._row(entity, project.table(params["entityType"]))

    def entities__add(self, params: dict) -> dict:
        project = self._require_project()
        table = project.table(params["entityType"])
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

    # -- fragments, data, methods -------------------------------------------------------------

    def fragments__list(self, params: dict) -> list:
        project = self._require_project()
        return [{"id": f.id, "version": f.version, "title": f.document.get("title", f.id),
                 "description": f.document.get("description", ""), "computed": "compute" in f.document,
                 "columns": f.document["columns"]} for f in project.fragments()]

    def fragments__update(self, params: dict) -> dict:
        project = self._require_project()
        summary = project.update_fragment(params["entityType"], params["fragmentId"], params.get("keys"))
        self.emit("entities", {"entityTypes": [params["entityType"]]})
        return summary

    def dataVariables__list(self, params: dict) -> list:
        project = self._require_project()
        return [v.document for v in project.data_variables(params.get("entityType"))]

    def data__status(self, params: dict) -> list:
        project = self._require_project()
        return project.data_status(self._entity(params))

    def methods__list(self, params: dict) -> list:
        project = self._require_project()
        return [m.summary() for m in project.methods(params.get("entityType"))]

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

    def tasks__list(self, params: dict) -> list:
        return self._queue().list(params.get("status"))

    def tasks__get(self, params: dict) -> dict:
        queue = self._queue()
        return dict(queue.get(params["id"]), logText=queue.log(params["id"]))

    def tasks__cancel(self, params: dict) -> dict:
        return self._queue().cancel(params["id"])

    def tasks__retry(self, params: dict) -> dict:
        return self._queue().retry(params["id"])

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
