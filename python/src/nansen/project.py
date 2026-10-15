"""A project folder (docs/reference/project-layout.md). Opened explicitly; nothing is global."""

from __future__ import annotations

import json
import re

from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

from .adapters import AdapterRegistry
from .cache import DataCache
from .dataset import Dataset, Scan, copy_dataset
from .datavars import DataVariable, check_against_pattern, read_paths
from .documents import PathLike, check_document, read_document, write_json
from .entities import Entity, join
from .errors import NansenError
from .methods import Method, MethodContext, run_method
from .modules import Module, resolve_module
from .notebook import Notebook
from .views import Views
from . import runs
from .schemas import current_version
from .stacks import Stack, StackWriter, as_stack, natural_order
from .tables import Column, EntityTable, TableSpec

PROJECT_FILE = "project.nansen.json"
SCAN_FILE = "cache/scan.nansen.json"


class Fragment:
    """A fragment definition: a named, versioned group of columns."""

    def __init__(self, document: dict):
        self.document = document
        self.id: str = document["id"]
        self.version: str = document["version"]
        self.columns = [Column(c["name"], c["dataType"], self.id, c.get("unit"), c.get("description"))
                        for c in document["columns"]]
        self.defaults: Dict[str, Any] = {c["name"]: c.get("default") for c in document["columns"]}

    @classmethod
    def read(cls, path: PathLike) -> "Fragment":
        return cls(read_document(path, "nansen.fragment"))


EXCLUDE_ESCAPED = set("\\.^$|?*+()[]{}")  # characters escaped in an exclude pattern made from a name


def _version_tuple(version: str) -> Tuple[int, ...]:
    return tuple(int(part) for part in version.split("."))


class Project:
    def __init__(self, folder: PathLike, document: dict, environment: Optional[str] = None):
        self.folder = Path(folder)
        self.document = document
        # The environment (machine) whose root paths to use; None means the dataset's preference.
        self.environment = environment
        self._dataset: Optional[Dataset] = None
        self._adapters: Optional[AdapterRegistry] = None
        self._modules: Optional[List[Module]] = None
        # Data read by load, kept until its file changes; dev's DataCache, but this project's own
        self.data_cache = DataCache()
        # the most frames a stack from open_stack gives in one read (None: no limit); a test sets it to show
        # that a method reads a recording in chunks
        self.stack_frame_limit: Optional[int] = None

    # -- creating and opening -------------------------------------------------------------

    @classmethod
    def create(cls, folder: PathLike, name: str, title: Optional[str] = None,
               dataset: Optional[str] = None, description: Optional[str] = None) -> "Project":
        """Make a project folder. ``dataset`` is the path of a DSM config, relative to the folder."""
        folder = Path(folder)
        if (folder / PROJECT_FILE).exists():
            raise NansenError("folder-not-empty", f"{folder} already holds a project")
        document: dict = {"schemaType": "nansen.project", "schemaVersion": current_version("nansen.project"), "name": name}
        if title is not None:
            document["title"] = title
        if description:
            document["description"] = description
        if dataset is not None:
            document["dataset"] = dataset
        document["entityTypes"] = []
        document = check_document(document, "nansen.project")
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "fragments").mkdir(exist_ok=True)
        (folder / "tables").mkdir(exist_ok=True)
        project = cls(folder, document)
        project._check_and_save()
        return project

    @classmethod
    def open(cls, folder: PathLike, environment: Optional[str] = None) -> "Project":
        folder = Path(folder)
        return cls(folder, read_document(folder / PROJECT_FILE, "nansen.project"), environment)

    # -- properties -----------------------------------------------------------------------

    @property
    def name(self) -> str:
        return self.document["name"]

    @property
    def title(self) -> str:
        return self.document.get("title", self.name)

    @property
    def entity_types(self) -> List[str]:
        return [e["name"] for e in self.document["entityTypes"]]

    def entity_type(self, name: str) -> dict:
        for entry in self.document["entityTypes"]:
            if entry["name"] == name:
                return entry
        raise NansenError("unknown-entity-type", f"project {self.name!r} has no entity type {name!r}")

    # -- fragments and tables -------------------------------------------------------------

    def fragment_path(self, fragment_id: str) -> Path:
        return self.folder / "fragments" / f"{fragment_id}.fragment.nansen.json"

    def fragment(self, fragment_id: str) -> Fragment:
        """A fragment from the project's fragments/ folder, else from its modules."""
        path = self.fragment_path(fragment_id)
        if path.is_file():
            return Fragment.read(path)
        for module in self.modules:
            for document in module.fragment_documents():
                if document["id"] == fragment_id:
                    return Fragment(document)
        raise NansenError("unknown-fragment", f"fragment {fragment_id!r} is not defined ({path}, or in a module)")

    def fragments(self) -> List[Fragment]:
        """Every fragment the project can use: its own, then its modules'."""
        found: Dict[str, Fragment] = {}
        folder = self.folder / "fragments"
        for path in sorted(folder.glob("*.fragment.nansen.json")) if folder.is_dir() else []:
            fragment = Fragment.read(path)
            found.setdefault(fragment.id, fragment)
        for module in self.modules:
            for document in module.fragment_documents():
                found.setdefault(document["id"], Fragment(document))
        return list(found.values())

    def table_path(self, entity_type: str) -> Path:
        return self.folder / "tables" / f"{entity_type}.table.nansen.json"

    def table(self, entity_type: str) -> EntityTable:
        """Read an entity type's table and check it against the entity type's fragments."""
        entry = self.entity_type(entity_type)
        table = EntityTable.read(self.table_path(entity_type))
        if table.spec.entity_type != entity_type:
            raise NansenError("invalid-table-spec", f"{self.table_path(entity_type)} is a table of {table.spec.entity_type!r}")
        fragments = [self.fragment(f) for f in entry.get("fragments", [])]
        check_fragments(table.spec, fragments)
        for fragment in fragments:
            table.defaults.update(fragment.defaults)
        return table

    def notebook_path(self, entity_type: str) -> Path:
        return self.folder / "notes" / f"{entity_type}.notebook.nansen.json"

    def notebook(self, entity_type: str) -> Notebook:
        """The notes on an entity type's entities."""
        self.entity_type(entity_type)
        return Notebook(self.notebook_path(entity_type), entity_type, self.table(entity_type).spec.key)

    def views_path(self, entity_type: str) -> Path:
        return self.folder / "views" / f"{entity_type}.views.nansen.json"

    def views(self, entity_type: str) -> Views:
        """The saved views of an entity type's table."""
        self.entity_type(entity_type)
        return Views(self.views_path(entity_type), entity_type, self.table(entity_type).spec.key)

    def column_choices(self, entity_type: str) -> Dict[str, List[str]]:
        """The choices of the entity type's columns that have them, from their fragments."""
        choices: Dict[str, List[str]] = {}
        for fragment_id in self.entity_type(entity_type).get("fragments", []):
            for column in self.fragment(fragment_id).document["columns"]:
                if "choices" in column:
                    choices[column["name"]] = list(column["choices"])
        return choices

    def check_choices(self, entity_type: str, values: Dict[str, Any]) -> None:
        """Raise invalid-value when a value is not among its column's choices (none is always allowed)."""
        for name, allowed in self.column_choices(entity_type).items():
            value = values.get(name)
            if value is not None and value not in allowed:
                raise NansenError("invalid-value", f"{name!r} is one of {', '.join(allowed)}, not {value!r}")

    def add_entity_type(
        self,
        name: str,
        key: Optional[Sequence[Column]] = None,
        fragments: Sequence[str] = (),
        title: Optional[str] = None,
    ) -> EntityTable:
        """Declare an entity type and write its empty table: the key columns, then each fragment's columns.

        Without ``key``, the key comes from the dataset: the identity of the
        entity's ancestors and its own.
        """
        if name in self.entity_types:
            raise ValueError(f"entity type {name!r} already exists")
        if key is None:
            dataset = self.require_dataset()
            if name not in dataset.entity_types:
                raise NansenError("unknown-entity-type", f"the dataset has no entity type {name!r}")
            key = [Column(n, t) for n, t in dataset.key_columns(name)]
        definitions = [self.fragment(f) for f in fragments]
        spec = TableSpec(name, [c.name for c in key], list(key), file=f"{name}.csv")
        table = EntityTable(spec)
        for fragment in definitions:
            table.add_columns(fragment.columns, fragment.defaults, (fragment.id, fragment.version))
        entry: dict = {"name": name}
        if title is not None:
            entry["title"] = title
        if fragments:
            entry["fragments"] = list(fragments)
        self.document["entityTypes"].append(entry)
        self._check_and_save()
        table.write(self.table_path(name))
        return table

    # -- dataset and entities ---------------------------------------------------------------

    @property
    def dataset(self) -> Optional[Dataset]:
        """The project's DSM config, or None when the project has none."""
        if "dataset" not in self.document:
            return None
        if self._dataset is None:
            self._dataset = Dataset.load(self.folder / self.document["dataset"], self.environment)
        return self._dataset

    def set_dataset(self, source: PathLike) -> Dataset:
        """Copy a DSM config into the project as dataset.dsm.json (relative roots made absolute) and use it."""
        if "dataset" in self.document:
            raise NansenError("dataset-exists", f"project {self.name!r} already has a dataset")
        target = self.folder / "dataset.dsm.json"
        copy_dataset(source, target)
        self.document["dataset"] = "dataset.dsm.json"
        self._dataset = None
        try:
            dataset = self.require_dataset()
        except NansenError:
            del self.document["dataset"]
            target.unlink()
            raise
        self._check_and_save()
        return dataset

    def exclude_from_scan(self, data_location: str, path: str) -> Dict[str, Any]:
        """Have scans skip an entry the last scan did not match: an excludePatterns entry for its exact name,
        at its level in the data location, written into the DSM config's text. The last scan forgets it too."""
        from . import jsontext

        dataset = self.require_dataset()
        parts = [p for p in str(path).replace("\\", "/").split("/") if p]
        if not parts or any(p in (".", "..") for p in parts):
            raise NansenError("invalid-params", f"{path!r} is not a path in the data location")
        if data_location not in dataset.config.location_ids:
            raise NansenError("unknown-location", f"the dataset has no data location {data_location!r}")
        levels = dataset.config.layout(data_location)
        if len(parts) > len(levels):
            raise NansenError("invalid-params", f"{path!r} is deeper than the levels of {data_location!r}")
        level = len(parts) - 1
        pattern = "^" + "".join("\\" + c if c in EXCLUDE_ESCAPED else c for c in parts[-1]) + "$"
        text = self.dataset_text()
        config = json.loads(text)
        index = [loc.get("identifier") for loc in config["dataLocations"]].index(data_location)
        pointer = f"/dataLocations/{index}/filesystemSource/entityLayout/{level}"
        existing = config["dataLocations"][index]["filesystemSource"]["entityLayout"][level].get("excludePatterns")
        if existing is None:
            text = jsontext.set_member(text, pointer, "excludePatterns", [pattern])
        elif pattern not in existing:
            text = jsontext.append(text, pointer + "/excludePatterns", pattern)
        if text != self.dataset_text():
            self.save_dataset_text(text)
        scan = self.last_scan()
        if scan is not None:
            prefix = "/".join(parts) + "/"
            scan.unmatched = [u for u in scan.unmatched if not (u.get("dataLocationIdentifier") == data_location
                              and (u.get("path", "") + "/").replace("//", "/").startswith(prefix))]
            scan.write(self.scan_path)
        return {"dataLocation": data_location, "level": levels[level]["name"], "pattern": pattern}

    def dataset_text(self) -> str:
        """The DSM config as written, so it can be edited with its formatting."""
        self.require_dataset()
        return (self.folder / self.document["dataset"]).read_text(encoding="utf-8")

    def save_dataset_text(self, text: str) -> Dataset:
        """Replace the DSM config with this text once DSM accepts it and the tables' keys still match it.

        The file is written as given. If the new config cannot be used, the old text is put back.
        """
        import dsm

        self.require_dataset()
        name = self.document["dataset"]
        try:
            document = json.loads(text)
        except ValueError as error:
            raise NansenError("dataset-invalid", f"{name}: not valid JSON: {error}") from None
        if not isinstance(document, dict):
            raise NansenError("dataset-invalid", f"{name}: a DSM config is a JSON object")
        try:
            dsm.validate_config(document)
        except dsm.ConfigError as error:
            raise NansenError("dataset-invalid", f"{name}: {error}") from None
        config_path = self.folder / name
        old = config_path.read_text(encoding="utf-8")
        with open(config_path, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        self._dataset = None
        try:
            dataset = self.require_dataset()
            for entry in self.document["entityTypes"]:
                if entry["name"] in dataset.entity_types and self.table_path(entry["name"]).is_file():
                    key = list(self.table(entry["name"]).spec.key)
                    expected = [n for n, _ in dataset.key_columns(entry["name"])]
                    if expected != key:
                        raise NansenError("key-mismatch", f"the {entry['name']} table's key {key} differs from the "
                                                          f"identity the new config gives it {expected}")
        except NansenError:
            with open(config_path, "w", encoding="utf-8", newline="") as f:
                f.write(old)
            self._dataset = None
            raise
        return dataset

    def _parse_dataset_text(self, text: str) -> dict:
        """A DSM config from its text, as DSM accepts it (dataset-invalid otherwise)."""
        import dsm

        try:
            document = json.loads(text)
        except ValueError as error:
            raise NansenError("dataset-invalid", f"not valid JSON: {error}") from None
        if not isinstance(document, dict):
            raise NansenError("dataset-invalid", "a DSM config is a JSON object")
        try:
            dsm.validate_config(document)
        except dsm.ConfigError as error:
            raise NansenError("dataset-invalid", str(error)) from None
        return document

    def set_dataset_text(self, text: str) -> Dataset:
        """Give a project without a dataset this DSM config, written as dataset.dsm.json as given."""
        if "dataset" in self.document:
            raise NansenError("dataset-exists", f"project {self.name!r} already has a dataset")
        self._parse_dataset_text(text)
        target = self.folder / "dataset.dsm.json"
        with open(target, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        self.document["dataset"] = "dataset.dsm.json"
        self._dataset = None
        try:
            dataset = self.require_dataset()
        except NansenError:
            del self.document["dataset"]
            target.unlink()
            raise
        self._check_and_save()
        return dataset

    def test_dataset_text(self, text: str, examples: int = 5) -> Dict[str, Any]:
        """What a scan with this DSM config would find, without keeping it: counts and examples per entity type,
        and what it would not match. Relative roots are read from the project folder."""
        import dsm

        document = self._parse_dataset_text(text)
        config = dsm.Config(document, source=str(self.folder / "dataset.dsm.json"))
        dataset = Dataset(config, self.folder, self.environment)
        scan = dataset.scan()
        records: Dict[str, int] = {}
        found: Dict[str, List[dict]] = {}
        for record in scan.records:
            records[record["entityType"]] = records.get(record["entityType"], 0) + 1
            if len(found.setdefault(record["entityType"], [])) < examples:
                found[record["entityType"]].append(dataset.record_key(record))
        unmatched = sorted((u for u in scan.unmatched if u.get("reason") != "excluded"),
                           key=lambda u: (u.get("dataLocationIdentifier") or "", u.get("path") or ""))
        return {"records": records, "examples": found, "roots": scan.roots, "unmatched": len(unmatched),
                "unmatchedExamples": [{"dataLocation": u.get("dataLocationIdentifier"), "path": u.get("path", ""),
                                       "reason": u.get("reason", "")} for u in unmatched[:10]]}

    def set_root(self, data_location: str, path: str, environment: Optional[str] = None,
                 root_storage_path: Optional[str] = None) -> Dataset:
        """Say where a data location is: a given root, or the location in this machine's environment or another.

        With root_storage_path, that root gets the new path and nothing else changes. Otherwise the root
        the location uses in the environment gets it. Without one, a root is
        added for the environment. When the environment is not the active one, it becomes active on
        this machine (the DSM config's .local.json overlay), and every other location that would have
        no root there gets one at the path it uses now. Only those values change in the config's text.
        """
        from . import jsontext

        dataset = self.require_dataset()
        config_path = self.folder / self.document["dataset"]
        text = config_path.read_text(encoding="utf-8")
        config = json.loads(text)
        locations = config.get("dataLocations", [])
        index = next((i for i, loc in enumerate(locations) if loc.get("identifier") == data_location), None)
        if index is None:
            raise NansenError("unknown-location", f"the dataset has no data location {data_location!r}")
        active = dataset.environment
        target = environment or active
        roots = locations[index].get("filesystemSource", {}).get("rootStoragePaths", [])
        pointer = f"/dataLocations/{index}/filesystemSource/rootStoragePaths"
        if root_storage_path is not None:
            j = next((j for j, r in enumerate(roots) if r.get("identifier") == root_storage_path), None)
            if j is None:
                raise NansenError("unknown-location", f"{data_location!r} has no root {root_storage_path!r}")
            text = jsontext.replace(text, f"{pointer}/{j}/path", path)
            with open(config_path, "w", encoding="utf-8", newline="") as f:
                f.write(text)
            self._dataset = None
            return self.require_dataset()
        match = next((j for j, r in enumerate(roots) if r.get("environment") == target), None) if target else \
            next((j for j, r in enumerate(roots) if "environment" not in r), None)
        if match is None and target is None:
            target = default_environment()
        if match is not None:
            text = jsontext.replace(text, f"{pointer}/{match}/path", path)
        else:
            text = jsontext.append(text, pointer, {"identifier": _root_identifier(target, roots), "path": path,
                                                   "environment": target})
        if target != active:
            for i, location in enumerate(locations):
                others = location.get("filesystemSource", {}).get("rootStoragePaths", [])
                if i == index or any(r.get("environment") in (None, target) for r in others):
                    continue
                current = [r for r in dataset.roots() if r.data_location == location.get("identifier")]
                if current:  # keep it working where it is
                    text = jsontext.append(text, f"/dataLocations/{i}/filesystemSource/rootStoragePaths",
                                           {"identifier": _root_identifier(target, others),
                                            "path": current[0].path.as_posix(), "environment": target})
            _set_environment(config_path, target)
        with open(config_path, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        self._dataset = None
        return self.require_dataset()

    def add_dataset_entity_types(self, fragments: Sequence[str] = ()) -> List[str]:
        """Add every entity type of the dataset that the project does not have yet; returns their names."""
        added = []
        for name in self.require_dataset().entity_types:
            if name not in self.entity_types:
                self.add_entity_type(name, fragments=fragments, title=name.replace("_", " ").title() + "s")
                added.append(name)
        return added

    def require_dataset(self) -> Dataset:
        dataset = self.dataset
        if dataset is None:
            raise NansenError("no-dataset", f"project {self.name!r} has no dataset")
        return dataset

    @property
    def scan_path(self) -> Path:
        return self.folder / SCAN_FILE

    def scan(self, listing=None, registry=None, save: bool = True) -> Scan:
        """Walk the data locations (or a given listing) and keep the result in cache/."""
        result = self.require_dataset().scan(listing, registry)
        if save:
            result.write(self.scan_path)
        return result

    def last_scan(self) -> Optional[Scan]:
        return Scan.read(self.scan_path) if self.scan_path.is_file() else None

    def entities(self, entity_type: str, scan: Optional[Scan] = None) -> List[Entity]:
        """The entity type's entities: table rows joined with the records of the last (or given) scan."""
        table = self.table(entity_type)
        key = list(table.spec.key)
        dataset = self.dataset
        records: List[dict] = []
        if dataset is not None and entity_type in dataset.entity_types:
            expected = [n for n, _ in dataset.key_columns(entity_type)]
            if expected != key:
                raise NansenError("key-mismatch", f"table key {key} differs from the dataset identity {expected}")
            scan = scan if scan is not None else self.last_scan()
            records = scan.records_of(entity_type) if scan is not None else []
        entities = join(entity_type, key, records, table.rows, dataset.record_key if dataset else _record_key)
        for entity in entities:
            entity.project = self
        return entities

    def entity(self, entity_type: str, key: Dict[str, Any], scan: Optional[Scan] = None) -> Entity:
        for candidate in self.entities(entity_type, scan):
            if all(candidate.key.get(k) == v for k, v in key.items()):
                return candidate
        raise NansenError("unknown-entity", f"no {entity_type} with key {key}")

    def sync(self, entity_type: str, scan: Optional[Scan] = None) -> List[Dict[str, Any]]:
        """Add a table row for every entity found in the stores but not in the table. Returns their keys."""
        from .views import filter_passes

        table = self.table(entity_type)
        rules = [p for p in self.pipelines(entity_type) if p.get("assignWhen")] \
            if "core.pipeline" in self.entity_type(entity_type).get("fragments", []) else []
        added = []
        for entity in self.entities(entity_type, scan):
            if entity.in_table or any(i["code"] == "incomplete-key" for i in entity.issues):
                continue
            row = dict(entity.key)
            if rules:  # the first pipeline whose rule the new row passes, as dev assigns pipelines to new sessions
                values = dict(table.defaults)
                values.update(entity.attributes)
                values.update(entity.key)
                chosen = next((p for p in rules if all(filter_passes(values.get(f["column"]), f) for f in p["assignWhen"])), None)
                if chosen is not None:
                    row["pipeline"] = chosen["id"]
            table.add(row)
            added.append(dict(entity.key))
        if added:
            table.write()
        return added

    # -- data variables and file adapters -----------------------------------------------------

    # -- modules, methods and presets ----------------------------------------------------------

    @property
    def modules(self) -> List[Module]:
        if self._modules is None:
            self._modules = [resolve_module(entry, self.folder) for entry in self.document.get("modules", [])]
        return self._modules

    def add_module(self, module_id: str, path: Optional[str] = None) -> Module:
        """List a module in the project file (after checking it can be found)."""
        entry = {"id": module_id}
        if path is not None:
            entry["path"] = path
        module = resolve_module(entry, self.folder)
        modules = [m for m in self.document.get("modules", []) if m["id"] != module_id] + [entry]
        self.document["modules"] = modules
        self._check_and_save()
        self._modules = None
        self._adapters = None
        return module

    def remove_module(self, module_id: str) -> None:
        """Take a module off the project's list; module-in-use while the project uses what it provides."""
        listed = [m for m in self.document.get("modules", []) if m["id"] != module_id]
        if len(listed) == len(self.document.get("modules", [])):
            raise NansenError("unknown-module", f"the project does not list module {module_id!r}")
        prefix = module_id + "."
        users = [f"{t['name']} ({f})" for t in self.document["entityTypes"] for f in t.get("fragments", []) if f.startswith(prefix)]
        users += [f"data variable {v.name} ({v.file_adapter})" for v in self.data_variables() if v.file_adapter.startswith(prefix)]
        users += [f"pipeline {p['id']} ({s['method']})" for p in self.pipelines() if self.pipeline_source(p["id"]) == "project"
                  for s in p["steps"] if s["method"].startswith(prefix)]
        if users:
            raise NansenError("module-in-use", f"module {module_id!r} is used by {', '.join(users)}")
        self.document["modules"] = listed
        self._check_and_save()
        self._modules = None
        self._adapters = None

    def methods(self, entity_type: Optional[str] = None) -> List[Method]:
        """The project's own methods (methods/), then its modules'. The first declaration of an id wins."""
        found: Dict[str, Method] = {}
        folder = self.folder / "methods"
        for path in sorted(folder.glob("*.method.nansen.json")) if folder.is_dir() else []:
            method = Method(read_document(path, "nansen.method"), self.folder / "python", self.folder / "matlab",
                            "project")
            found.setdefault(method.id, method)
        for module in self.modules:
            for method in module.methods():
                found.setdefault(method.id, method)
        return [m for m in found.values() if entity_type is None or m.applies_to(entity_type)]

    def create_method(self, method_id: str, title: str, entity_type: str = "*", description: str = "",
                      batch_mode: str = "serial", languages: Sequence[str] = ("python", "matlab"),
                      queueable: bool = True, computes: Optional[Sequence[dict]] = None) -> Method:
        """Start a method of the project: its document in methods/ and, for each language, a file to fill in
        (python/<id>.py with run(), matlab/<id>.m), from the templates that ship with NANSEN."""
        from .modules import template_text

        if not re.match(r"^[a-z][a-z0-9_]*$", method_id or ""):
            raise NansenError("invalid-params", "a project method's id is a lower-case letter, then letters, digits or _")
        if entity_type not in ("*", "@project"):
            self.entity_type(entity_type)
        if batch_mode not in ("serial", "batch"):
            raise NansenError("invalid-params", "batchMode is serial or batch")
        languages = list(dict.fromkeys(languages))
        if not languages or any(language not in ("python", "matlab") for language in languages):
            raise NansenError("invalid-params", "languages are python and/or matlab")
        title = " ".join(str(title).split()) or method_id
        description = " ".join(str(description).split())
        files = {self.folder / "methods" / f"{method_id}.method.nansen.json": None}
        if "python" in languages:
            files[self.folder / "python" / f"{method_id}.py"] = "method.py.template"
        if "matlab" in languages:
            files[self.folder / "matlab" / f"{method_id}.m"] = "method.m.template"
        fragment = None
        if computes:  # a computed column, as dev's table variables with an update function: a fragment it fills
            if entity_type in ("*", "@project") or batch_mode != "serial":
                raise NansenError("invalid-params", "a method that computes columns runs on one entity type, once per entity")
            fragment = {"schemaType": "nansen.fragment", "schemaVersion": current_version("nansen.fragment"), "id": method_id,
                        "version": "1.0.0", "title": title, "columns": [dict(c) for c in computes], "compute": {"method": method_id}}
            check_document(fragment, "nansen.fragment")
            clash = sorted(set(self.table(entity_type).spec.column_names) & {c["name"] for c in computes})
            if clash:
                raise NansenError("column-exists", f"{entity_type} already has column(s) {', '.join(clash)}")
            if any(f.id == method_id for f in self.fragments()):
                raise NansenError("fragment-exists", f"the project already has a fragment {method_id!r}")
            files[self.fragment_path(method_id)] = None
        existing = [str(p.relative_to(self.folder)) for p in files if p.exists()]
        if existing or any(m.id == method_id for m in self.methods()):
            raise NansenError("method-exists", f"the project already has {', '.join(existing) or 'a method ' + repr(method_id)}")
        document = {"schemaType": "nansen.method", "schemaVersion": current_version("nansen.method"), "id": method_id,
                    "version": "0.1.0", "title": title, "entityType": entity_type, "batchMode": batch_mode,
                    "implementations": {}, "options": {"type": "object", "properties": {}}}
        if description:
            document["description"] = description
        if not queueable:
            document["queueable"] = False  # run by hand only, for example an interactive one
        if "python" in languages:
            document["implementations"]["python"] = f"{method_id}:run"
        if "matlab" in languages:
            document["implementations"]["matlab"] = method_id
        check_document(document, "nansen.method")
        batch = batch_mode == "batch"
        tool = entity_type == "@project"
        replacements = {
            "__ID__": method_id, "__TITLE__": title.replace('"', "'"),
            "__DESCRIPTION__": description or title,
            "__ARG__": "project" if tool else "entities" if batch else "entity",
            "__RESULT_M__": ("struct(" + ", ".join(f'"{c["name"]}", []' for c in computes) + ")") if computes else "struct()",
            "__RESULT__": ("{" + ", ".join(f'"{c["name"]}": None' for c in computes) + "}  # a value per column") if computes else "{}",
            "__ARG_HELP__": "project is the project it runs on: project.entities(entity_type), project.table(entity_type)." if tool
            else ("entities are the entities it runs on, all at once" if batch else "entity is the entity it runs on")
            + (" (each with .key, .values, .locations, .load(name))." if batch else ": entity.key, entity.values, entity.locations, entity.load(name)."),
            "__ARG_HELP_M__": "project is the project it runs on: project.entities(entityType), project.table(entityType)." if tool
            else ("entities is a cell row of the entities it runs on, all at once" if batch else "entity is the entity it runs on")
            + (" (each with .Key, .values(), .locations(), .load(name))." if batch else ": entity.Key, entity.values(), entity.locations(), entity.load(name)."),
        }
        for path, template in files.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            if template is None:
                write_json(path, fragment if fragment is not None and path == self.fragment_path(method_id) else document)
                continue
            text = template_text(template)
            for token, value in replacements.items():
                text = text.replace(token, value)
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write(text)
        if fragment is not None:
            self.attach_fragment(entity_type, method_id)
        return self.method(method_id)

    def method(self, method_id: str) -> Method:
        for method in self.methods():
            if method.id == method_id:
                return method
        raise NansenError("unknown-method", f"no method {method_id!r}")

    def pipelines(self, entity_type: Optional[str] = None) -> List[dict]:
        """Pipelines from the project's pipelines/ folder, then its modules'. The first of an id wins."""
        found: Dict[str, dict] = {}
        folder = self.folder / "pipelines"
        for path in sorted(folder.glob("*.pipeline.nansen.json")) if folder.is_dir() else []:
            document = read_document(path, "nansen.pipeline")
            found.setdefault(document["id"], document)
        for module in self.modules:
            for document in module.pipeline_documents():
                found.setdefault(document["id"], document)
        return [p for p in found.values() if entity_type is None or p["entityType"] in ("*", entity_type)]

    def pipeline(self, pipeline_id: str) -> dict:
        for document in self.pipelines():
            if document["id"] == pipeline_id:
                return document
        raise NansenError("unknown-pipeline", f"no pipeline {pipeline_id!r}")

    def pipeline_path(self, pipeline_id: str) -> Path:
        return self.folder / "pipelines" / f"{pipeline_id}.pipeline.nansen.json"

    def pipeline_source(self, pipeline_id: str) -> str:
        """'project' when the project's pipelines/ folder holds it (over a module's of the same id), else 'module'."""
        return "project" if self.pipeline_path(pipeline_id).is_file() else "module"

    def save_pipeline(self, document: dict) -> dict:
        """Write a pipeline into the project; one with a module pipeline's id is used instead of that one."""
        document = check_document(document, "nansen.pipeline")
        for step in document["steps"]:
            method = self.method(step["method"])
            if document["entityType"] != "*" and not method.applies_to(document["entityType"]):
                raise NansenError("wrong-entity-type", f"{method.id} runs on {method.entity_type}, not {document['entityType']}")
            if "preset" in step:
                self.preset(method.id, step["preset"])
        path = self.pipeline_path(document["id"])
        path.parent.mkdir(parents=True, exist_ok=True)
        write_json(path, document)
        return document

    def delete_pipeline(self, pipeline_id: str) -> None:
        """Delete one of the project's pipelines (a module's of the same id is then used again)."""
        path = self.pipeline_path(pipeline_id)
        if not path.is_file():
            raise NansenError("unknown-pipeline", f"{pipeline_id!r} is not one of the project's own pipelines")
        path.unlink()

    def assign_pipeline(self, entity_type: str, keys: Optional[List[Dict[str, Any]]], pipeline_id: Optional[str]) -> int:
        """Set the pipeline of the given rows (all rows when keys is None); None takes it away. Returns how many."""
        if pipeline_id is not None:
            pipeline = self.pipeline(pipeline_id)
            if pipeline["entityType"] not in ("*", entity_type):
                raise NansenError("wrong-entity-type", f"pipeline {pipeline_id!r} is for {pipeline['entityType']}")
        if "core.pipeline" not in self.entity_type(entity_type).get("fragments", []):
            self.attach_fragment(entity_type, "core.pipeline")
        table = self.table(entity_type)
        targets = keys if keys is not None else [dict(zip(table.spec.key, table.key_of(row))) for row in table.rows]
        for key in targets:
            if not table.has(key):
                raise NansenError("unknown-entity", f"no row with key {key}")
        for key in targets:
            table.update(key, pipeline=pipeline_id)
        table.write()
        return len(targets)

    def pipeline_progress(self, entity_type: str) -> Dict[runs.KeyId, dict]:
        """For each row with a pipeline: {pipeline, title, steps[{title, method, done, finishedAt}], done, total}."""
        if "core.pipeline" not in self.entity_type(entity_type).get("fragments", []):
            return {}
        table = self.table(entity_type)
        completed = runs.completed(self.folder, entity_type)
        known = {p["id"]: p for p in self.pipelines(entity_type)}
        step_methods: Dict[str, Method] = {}  # looked up once, not per row
        for pipeline in known.values():
            for s in pipeline["steps"]:
                if s["method"] not in step_methods:
                    step_methods[s["method"]] = self.method(s["method"])
        progress: Dict[runs.KeyId, dict] = {}
        for row in table.rows:
            pipeline = known.get(row.get("pipeline"))
            if pipeline is None:
                continue
            key = {name: row[name] for name in table.spec.key}
            done = completed.get(runs.key_id(key), {})
            steps = []
            for s in pipeline["steps"]:
                method = step_methods[s["method"]]
                steps.append({"title": s.get("title") or method.title, "method": s["method"], "queueable": method.queueable,
                              "done": s["method"] in done, "finishedAt": done.get(s["method"])})
            progress[runs.key_id(key)] = {"pipeline": pipeline["id"], "title": pipeline.get("title", pipeline["id"]),
                                          "steps": steps, "done": sum(s["done"] for s in steps), "total": len(steps)}
        return progress

    def preset_path(self, method_id: str, name: str) -> Path:
        return self.folder / "options" / method_id / f"{name}.options.nansen.json"

    def presets(self, method_id: str) -> List[Dict[str, Any]]:
        """Option sets of a method: the implicit 'default' (the schema's defaults), the project's saved
        ones, then those its modules ship that the project has none of the same name of.

        Each has a source: default, project, or module (with the module's id)."""
        method = self.method(method_id)
        presets = [{"name": "default", "description": "The method's defaults", "values": method.default_options(),
                    "source": "default"}]
        folder = self.folder / "options" / method_id
        for path in sorted(folder.glob("*.options.nansen.json")) if folder.is_dir() else []:
            doc = read_document(path, "nansen.options")
            presets.append({"name": doc["name"], "description": doc.get("description", ""), "values": doc["values"],
                            "source": "project"})
        for module in self.modules:
            for doc in module.preset_documents():
                if doc["method"]["id"] == method_id and all(p["name"] != doc["name"] for p in presets):
                    presets.append({"name": doc["name"], "description": doc.get("description", ""),
                                    "values": doc["values"], "source": "module", "module": module.id})
        return presets

    def preset(self, method_id: str, name: str) -> Dict[str, Any]:
        for preset in self.presets(method_id):
            if preset["name"] == name:
                return preset["values"]
        raise NansenError("unknown-preset", f"method {method_id!r} has no preset {name!r}")

    def save_preset(self, method_id: str, name: str, values: Dict[str, Any], description: str = "") -> None:
        if name == "default":
            raise NansenError("invalid-options", "the 'default' preset is the method's defaults and cannot be saved")
        method = self.method(method_id)
        resolved = method.resolve_options(values)
        document = {"schemaType": "nansen.options", "schemaVersion": current_version("nansen.options"),
                    "method": {"id": method.id, "version": method.version}, "name": name, "values": resolved}
        if description:
            document["description"] = description
        path = self.preset_path(method_id, name)
        path.parent.mkdir(parents=True, exist_ok=True)
        write_json(path, check_document(document, "nansen.options"))

    def delete_preset(self, method_id: str, name: str) -> None:
        path = self.preset_path(method_id, name)
        if not path.is_file():
            raise NansenError("unknown-preset", f"method {method_id!r} has no saved preset {name!r}")
        path.unlink()

    def run(self, method_id: str, entities: List[Entity], options: Optional[Dict[str, Any]] = None,
            preset: Optional[str] = None, context: Optional[MethodContext] = None) -> List[Any]:
        """Run a method now, in this process, on entities of its type."""
        method = self.method(method_id)
        values = self.preset(method_id, preset) if preset else {}
        if options:
            values = dict(values, **options)
        context = context or MethodContext(project=self, method=method)
        if context.project is None:
            context.project = self
        results = run_method(method, entities, values, context)
        runs.record(self.folder, method.id, method.version, entities)
        return results

    def tools(self) -> List[Method]:
        """The project tools: methods that run once on the project (entityType @project)."""
        return [m for m in self.methods() if m.is_tool]

    def run_tool(self, method_id: str, options: Optional[Dict[str, Any]] = None, preset: Optional[str] = None,
                 context: Optional[MethodContext] = None) -> Any:
        """Run a project tool now, in this process; returns what it returns."""
        from .methods import run_tool

        method = self.method(method_id)
        values = self.preset(method_id, preset) if preset else {}
        if options:
            values = dict(values, **options)
        context = context or MethodContext(project=self, method=method)
        if context.project is None:
            context.project = self
        return run_tool(method, self, values, context)

    def update_values(self, entity: Entity, values: Dict[str, Any]) -> List[str]:
        """Write values into the entity's table row, those of columns the table has: for a method that fills columns it
        does not compute. Returns the names written; unknown-entity for an entity the table has no row of."""
        table = self.table(entity.entity_type)
        if not table.has(entity.key):
            raise NansenError("unknown-entity", f"{entity.entity_type} {entity.key} has no row in the table")
        names = [n for n in values if n in table.spec.column_names and n not in table.spec.key]
        if names:
            table.update(entity.key, **{n: values[n] for n in names})
            table.write()
        return names

    def update_fragment(self, entity_type: str, fragment_id: str, keys: Optional[List[Dict[str, Any]]] = None,
                        context: Optional[MethodContext] = None) -> Dict[str, Any]:
        """Recompute a computed fragment's columns for the entity type's table rows (or those with the given keys)."""
        fragment = self.fragment(fragment_id)
        if "compute" not in fragment.document:
            raise NansenError("not-computed", f"fragment {fragment_id!r} has no compute method")
        if fragment_id not in self.entity_type(entity_type).get("fragments", []):
            raise NansenError("unknown-fragment", f"entity type {entity_type!r} does not carry {fragment_id!r}")
        method = self.method(fragment.document["compute"]["method"])
        table = self.table(entity_type)
        entities = [e for e in self.entities(entity_type) if e.in_table]
        if keys is not None:
            wanted = [tuple(k[n] for n in table.spec.key) for k in keys]
            entities = [e for e in entities if e.key_tuple(table.spec.key) in wanted]
        context = context or MethodContext(project=self, method=method)
        context.project = self
        options = method.resolve_options({})
        function = method.function()
        names = [c.name for c in fragment.columns]
        updated, failed = 0, []
        for number, entity in enumerate(entities):
            context.check_cancelled()
            try:
                result = function(entity, options, context) or {}
                table.update(entity.key, **{n: result.get(n) for n in names if n in result})
                updated += 1
            except Exception as error:  # one entity's failure must not stop the others
                failed.append({"key": entity.key, "error": f"{type(error).__name__}: {error}"})
                context.log(f"{entity.key}: {error}")
            context.progress((number + 1) / max(len(entities), 1))
        table.write()
        return {"updated": updated, "failed": failed}

    @property
    def adapters(self) -> AdapterRegistry:
        """Built-in adapters, those declared in file-adapters/ (code in python/), then the modules'."""
        if self._adapters is None:
            registry = AdapterRegistry()
            for module in reversed(self.modules):
                for document in module.file_adapter_documents():
                    registry.declare(document, module.python_root)
            folder = self.folder / "file-adapters"
            for path in sorted(folder.glob("*.fileAdapter.nansen.json")) if folder.is_dir() else []:
                registry.declare(read_document(path, "nansen.fileAdapter"), self.folder / "python")
            self._adapters = registry
        return self._adapters

    def create_adapter(self, adapter_id: str, title: str = "", extensions: Sequence[str] = (),
                       languages: Sequence[str] = ("python", "matlab")) -> dict:
        """Start a file adapter of the project: its document in file-adapters/ and, per language, a class to fill
        in (python/<id>_adapter.py, matlab/<Id>Adapter.m), from the templates that ship with NANSEN."""
        from .modules import template_text

        if not re.match(r"^[a-z][a-z0-9_]*$", adapter_id or ""):
            raise NansenError("invalid-params", "a project adapter's id is a lower-case letter, then letters, digits or _")
        languages = list(dict.fromkeys(languages))
        if not languages or any(language not in ("python", "matlab") for language in languages):
            raise NansenError("invalid-params", "languages are python and/or matlab")
        extensions = list(dict.fromkeys(extensions))
        for extension in extensions:
            if not re.match(r"^\.[A-Za-z0-9.]+$", extension):
                raise NansenError("invalid-params", f"{extension!r} is not a file extension such as .tif")
        title = " ".join(str(title).split()) or adapter_id
        class_name = "".join(part.capitalize() for part in adapter_id.split("_")) + "Adapter"
        files = {self.folder / "file-adapters" / f"{adapter_id}.fileAdapter.nansen.json": None}
        if "python" in languages:
            files[self.folder / "python" / f"{adapter_id}_adapter.py"] = "adapter.py.template"
        if "matlab" in languages:
            files[self.folder / "matlab" / f"{class_name}.m"] = "adapter.m.template"
        existing = [str(p.relative_to(self.folder)) for p in files if p.exists()]
        if existing or adapter_id in self.adapters.ids:
            raise NansenError("adapter-exists", f"the project already has {', '.join(existing) or 'a file adapter ' + repr(adapter_id)}")
        document = {"schemaType": "nansen.fileAdapter", "schemaVersion": current_version("nansen.fileAdapter"),
                    "id": adapter_id, "version": "0.1.0", "title": title, "implementations": {}}
        if extensions:
            document["extensions"] = extensions
        if "python" in languages:
            document["implementations"]["python"] = f"{adapter_id}_adapter:{class_name}"
        if "matlab" in languages:
            document["implementations"]["matlab"] = class_name
        check_document(document, "nansen.fileAdapter")
        replacements = {"__ID__": adapter_id, "__CLASS__": class_name, "__TITLE__": title.replace('"', "'"),
                        "__EXTENSIONS__": ", ".join(extensions) if extensions else "its"}
        for path, template in files.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            if template is None:
                write_json(path, document)
                continue
            text = template_text(template)
            for token, value in replacements.items():
                text = text.replace(token, value)
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write(text)
        self._adapters = None
        return dict(document, files=[str(p.relative_to(self.folder).as_posix()) for p in files])

    def data_variable_path(self, name: str) -> Path:
        return self.folder / "data-variables" / f"{name}.dataVariable.nansen.json"

    def data_variables(self, entity_type: Optional[str] = None) -> List[DataVariable]:
        folder = self.folder / "data-variables"
        found = [DataVariable(read_document(p, "nansen.dataVariable"))
                 for p in sorted(folder.glob("*.dataVariable.nansen.json"))] if folder.is_dir() else []
        return [v for v in found if entity_type is None or v.entity_type == entity_type]

    def data_variable(self, name: str) -> DataVariable:
        path = self.data_variable_path(name)
        if not path.is_file():
            raise NansenError("unknown-data-variable", f"no data variable {name!r}")
        return DataVariable(read_document(path, "nansen.dataVariable"))

    def add_data_variable(self, document: dict) -> DataVariable:
        """Save a data variable. Its entity type, location, file pattern and adapter must exist."""
        variable = DataVariable(check_document(document, "nansen.dataVariable"))
        self.entity_type(variable.entity_type)
        if variable.file_adapter not in self.adapters:
            raise NansenError("unknown-file-adapter", f"no file adapter {variable.file_adapter!r}")
        dataset = self.require_dataset()
        if variable.data_location not in dataset.config.location_ids:
            raise NansenError("unknown-location", f"the dataset has no data location {variable.data_location!r}")
        patterns = self._level_patterns(variable)
        if variable.file_pattern is not None and variable.file_pattern not in patterns:
            raise NansenError("unknown-file-pattern", f"no file pattern {variable.file_pattern!r} at that level")
        path = self.data_variable_path(variable.name)
        path.parent.mkdir(exist_ok=True)
        write_json(path, variable.document)
        return variable

    def delete_data_variable(self, name: str) -> None:
        path = self.data_variable_path(name)
        if not path.is_file():
            raise NansenError("unknown-data-variable", f"the project has no data variable {name!r}")
        path.unlink()

    def file_patterns(self, data_location: str, entity_type: str) -> Dict[str, str]:
        """The named file patterns of the entity type's level in a data location (name -> pattern)."""
        config = self.require_dataset().config
        index = config.entity_level_index(data_location, entity_type)
        if index is None:
            return {}
        level = config.layout(data_location)[index]
        return {p["name"]: p["pattern"] for p in level.get("filePatterns", []) if "name" in p}

    def _level_patterns(self, variable: DataVariable) -> Dict[str, str]:
        return self.file_patterns(variable.data_location, variable.entity_type)

    def data_paths(self, entity: Entity, name: str) -> List[Path]:
        """Absolute paths of the files that hold the variable for the entity (they may not exist)."""
        dataset = self.require_dataset()
        return [dataset.absolute(location, relative) for location, relative in self.read_targets(entity, name)]

    def read_targets(self, entity: Entity, name: str) -> List[Tuple[str, str]]:
        """(dataLocation, path relative to the root) of each file that holds the variable for the entity."""
        variable = self.data_variable(name)
        return read_paths(variable, entity, self._level_patterns(variable))

    def write_target(self, entity: Entity, name: str) -> Tuple[str, str]:
        """(dataLocation, path relative to the root) where the variable is written for the entity:
        in its folder, generated by DSM if it has none yet."""
        variable = self.data_variable(name)
        dataset = self.require_dataset()
        values = entity.values
        location = entity.location(variable.data_location)
        if location is not None and location.get("fileSystemType", "folder") == "folder" and location["paths"]:
            folder = sorted(location["paths"])[0]
        else:
            folder = dataset.generate_path(variable.data_location, entity.entity_type, values)
        if variable.file_pattern is not None:
            check_against_pattern(variable, self._level_patterns(variable)[variable.file_pattern], values)
        return variable.data_location, folder + variable.relative_file(values)

    def write_path(self, entity: Entity, name: str) -> Path:
        location, relative = self.write_target(entity, name)
        return self.require_dataset().absolute(location, relative)

    def existing_files(self, entity: Entity, name: str) -> List[Path]:
        """The files that hold the variable for the entity and exist: where a scan found its folders, or else
        where save writes it, for a folder made since the last scan."""
        variable = self.data_variable(name)
        existing = [p for p in self.data_paths(entity, name) if p.is_file()]
        if not existing and variable.file_pattern is None:
            try:
                existing = [p for p in [self.write_path(entity, name)] if p.is_file()]
            except NansenError:
                pass
        return existing

    def load(self, entity: Entity, name: str, cached: bool = True) -> Any:
        """Read the variable for the entity with its file adapter.

        When a file pattern matches several files, an adapter that can open stacks (``open``) reads them
        as one recording, joined along the frames in natural order; any other reads the first.
        What was read is kept in ``data_cache`` and given again until a file changes; ``cached=False``
        reads the files and keeps nothing.
        """
        variable = self.data_variable(name)
        existing = self.existing_files(entity, name)
        if not existing:
            raise NansenError("data-not-found", f"{entity.entity_type} {entity.key} has no {name!r}")
        adapter = self.adapters.get(variable.file_adapter)
        if len(existing) > 1 and hasattr(adapter, "open"):
            paths = natural_order(existing)
            read = lambda: _numpy_array(adapter.open(paths))
        else:
            paths = existing[:1]
            read = lambda: adapter.read(paths[0])
        if not cached:
            return self._in_file(variable, read(), paths[0])
        stamps = tuple((p.stat().st_mtime_ns, p.stat().st_size) for p in paths)
        key = (variable.file_adapter, *(str(p.resolve()) for p in paths))
        value = self.data_cache.get_or_load(key if len(paths) > 1 else key[:2], stamps if len(paths) > 1 else stamps[0], read)
        return self._in_file(variable, value, paths[0])

    @staticmethod
    def _in_file(variable, value: Any, path: Path) -> Any:
        """The variable's part of what its file holds: the whole, or the variable named variableInFile."""
        name = variable.variable_in_file
        if not name:
            return value
        if not isinstance(value, dict) or name not in value:
            raise NansenError("data-not-found", f"{path} has no variable {name!r} (for {variable.name!r})")
        return value[name]

    def open_stack(self, entity: Entity, name: str) -> Stack:
        """The variable as a stack read a few frames at a time (nansen.stacks.Stack).

        An adapter with ``open`` reads only the frames asked for, and joins a recording kept in several
        files; for any other, the whole value is read (``load``) and given as a stack.
        """
        variable = self.data_variable(name)
        existing = self.existing_files(entity, name)
        if not existing:
            raise NansenError("data-not-found", f"{entity.entity_type} {entity.key} has no {name!r}")
        adapter = self.adapters.get(variable.file_adapter)
        stack = as_stack(adapter.open(natural_order(existing)) if hasattr(adapter, "open") else self.load(entity, name))
        stack.max_frames = self.stack_frame_limit
        return stack

    def open_file_stack(self, path: PathLike, adapter_id: Optional[str] = None) -> Tuple[Stack, str, List[str]]:
        """Any file as a stack, as dev's imviewer opens one: with the adapter given, or the first of those that read its
        extension as image stacks (AdapterRegistry.for_stacks) that opens it. Returns the stack, the adapter's id and
        the candidates."""
        path = Path(path)
        candidates = self.adapters.for_stacks(path.suffix)
        tries = [adapter_id] if adapter_id else candidates
        if not tries:
            raise NansenError("unsupported-file", f"no file adapter of the project reads {path.suffix or 'these'} files as image stacks")
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
            stack.max_frames = self.stack_frame_limit
            return stack, candidate, candidates
        raise NansenError("invalid-data", f"{path.name} could not be read as a stack: " + "; ".join(problems))

    def stack_writer(self, entity: Entity, name: str, shape: Any, dtype: Any) -> StackWriter:
        """A writer of the variable as a stack of the given shape, a chunk of frames at a time.

        An adapter with ``create`` writes each chunk to the file as it comes; for any other, the stack is
        kept in memory and written with ``write`` when the writer closes. An empty name writes nothing.
        """
        if not name:
            return StackWriter(shape, dtype)
        variable = self.data_variable(name)
        path = self.write_path(entity, name)
        path.parent.mkdir(parents=True, exist_ok=True)
        adapter = self.adapters.get(variable.file_adapter)
        forget = lambda: self.data_cache.remove((variable.file_adapter, str(path.resolve())))
        if hasattr(adapter, "create"):
            writer = adapter.create(path, shape, dtype)
            forget()
            return writer
        return StackWriter(shape, dtype, finish=lambda data: (adapter.write(path, data), forget()))

    def save(self, entity: Entity, name: str, data: Any) -> Path:
        """Write the variable for the entity, creating folders as needed. Returns the path written.

        A variable the project does not have yet is made first, as dev's saveData makes one: of the entity's type, in
        the first data location that can be written, as <name>.npy for an array of numbers or truth values (more than
        one of them) and as <name>.json for anything else."""
        if not self.data_variable_path(name).is_file():
            self.add_data_variable(self.new_variable_document(entity, name, data))
        variable = self.data_variable(name)
        path = self.write_path(entity, name)
        path.parent.mkdir(parents=True, exist_ok=True)
        adapter = self.adapters.get(variable.file_adapter)
        if variable.variable_in_file:   # one variable of the file: the others are kept
            others = adapter.read(path) if path.is_file() else {}
            if not isinstance(others, dict):
                raise NansenError("invalid-data", f"{path} does not hold named variables; {name!r} cannot be one of them")
            data = dict(others, **{variable.variable_in_file: data})
        adapter.write(path, data)
        self.data_cache.remove((variable.file_adapter, str(path.resolve())))  # a rewrite in the same tick keeps mtime
        return path

    def new_variable_document(self, entity: Entity, name: str, data: Any) -> dict:
        """The data variable save makes for a value of a name the project does not have (see save)."""
        writable = [loc["identifier"] for loc in self.require_dataset().config.locations if loc.get("access", "read") == "readwrite"]
        if not writable:
            raise NansenError("unknown-data-variable", f"no data variable {name!r}, and no data location can be written to make one")
        array = False
        try:
            import numpy as np
            array = isinstance(data, np.ndarray) and data.size > 1 and (np.issubdtype(data.dtype, np.number) or data.dtype == bool)
        except ImportError:
            pass
        return {"schemaType": "nansen.dataVariable", "schemaVersion": current_version("nansen.dataVariable"), "name": name,
                "entityType": entity.entity_type, "dataLocation": writable[0],
                "fileName": f"{name}.npy" if array else f"{name}.json", "fileAdapter": "npy" if array else "json"}

    def data_status(self, entity: Entity) -> List[Dict[str, Any]]:
        """Each data variable of the entity's type: whether a file exists, and where."""
        status = []
        for variable in self.data_variables(entity.entity_type):
            try:
                files = self.existing_files(entity, variable.name)
            except NansenError:
                files = []
            status.append({"name": variable.name, "dataLocation": variable.data_location,
                           "fileAdapter": variable.file_adapter, "dataType": variable.document.get("dataType"),
                           "files": [str(p) for p in files]})
        return status

    def add_fragment(self, document: dict) -> Fragment:
        """Save a project-defined fragment."""
        fragment = Fragment(check_document(document, "nansen.fragment"))
        write_json(self.fragment_path(fragment.id), fragment.document)
        return fragment

    def save_fragment(self, document: dict) -> Fragment:
        """Change a project fragment's definition: titles, descriptions, units, defaults and choices.

        Its columns keep their names, types and order, so the values in the tables stay as they are; new
        choices must allow the values there. The version goes up (a patch step unless a higher one is
        given), and every table holding the fragment records it.
        """
        new = Fragment(check_document(document, "nansen.fragment"))
        path = self.fragment_path(new.id)
        if not path.is_file():
            self.fragment(new.id)  # unknown-fragment
            raise NansenError("fragment-read-only", f"fragment {new.id!r} comes from a module; only the project's own can be changed")
        old = Fragment.read(path)
        if [(c.name, c.data_type) for c in old.columns] != [(c.name, c.data_type) for c in new.columns]:
            raise NansenError("fragment-mismatch", f"the columns of {new.id} keep their names, types and order when it is changed")
        if _version_tuple(new.version) < _version_tuple(old.version):
            raise NansenError("invalid-params", f"{new.id} is at {old.version}; it cannot go back to {new.version}")
        version = new.version
        if version == old.version:
            parts = list(_version_tuple(version))
            version = ".".join(map(str, parts[:-1] + [parts[-1] + 1]))
        users = [e["name"] for e in self.document["entityTypes"] if new.id in e.get("fragments", [])]
        tables = [self.table(name) for name in users]
        for name, table in zip(users, tables):
            for column in new.document["columns"]:
                if "choices" in column:
                    stray = sorted({str(row[column["name"]]) for row in table.rows
                                    if row.get(column["name"]) is not None and row[column["name"]] not in column["choices"]})
                    if stray:
                        raise NansenError("invalid-value", f"{name} rows hold {', '.join(stray[:5])} in {column['name']!r}, "
                                                           f"which the choices leave out")
        changed = dict(new.document, version=version)
        write_json(path, check_document(changed, "nansen.fragment"))
        for table in tables:
            table.spec.fragments[new.id] = version
            table.write()
        return Fragment(changed)

    def attach_fragment(self, entity_type: str, fragment_id: str) -> EntityTable:
        """Add a fragment to an entity type that may already have rows; they get the columns' defaults."""
        entry = self.entity_type(entity_type)
        fragment = self.fragment(fragment_id)
        if fragment_id in entry.get("fragments", []):
            raise NansenError("fragment-exists", f"{entity_type} already has fragment {fragment_id!r}")
        table = self.table(entity_type)
        clash = sorted(set(table.spec.column_names) & {c.name for c in fragment.columns})
        if clash:
            raise NansenError("column-exists", f"{entity_type} already has column(s) {', '.join(clash)}")
        table.add_columns(fragment.columns, fragment.defaults, (fragment.id, fragment.version))
        table.write()
        entry["fragments"] = list(entry.get("fragments", [])) + [fragment_id]
        self._check_and_save()
        return table

    def detach_fragment(self, entity_type: str, fragment_id: str) -> EntityTable:
        """Take a fragment off an entity type: its columns, and their values, leave the table."""
        entry = self.entity_type(entity_type)
        if fragment_id not in entry.get("fragments", []):
            raise NansenError("unknown-fragment", f"{entity_type} has no fragment {fragment_id!r}")
        table = self.table(entity_type)
        table.remove_columns([c.name for c in table.spec.columns if c.fragment == fragment_id], fragment_id)
        table.write()
        entry["fragments"] = [f for f in entry["fragments"] if f != fragment_id]
        self._check_and_save()
        return table

    def reset_column(self, entity_type: str, column: str, keys: Optional[List[Dict[str, Any]]] = None) -> int:
        """Give a column its default again (none when it has none), in the given rows or all; returns how many."""
        table = self.table(entity_type)
        if column not in table.spec.column_names:
            raise NansenError("unknown-column", f"{entity_type} has no column {column!r}")
        if column in table.spec.key:
            raise NansenError("read-only-column", f"cannot reset key column {column!r}")
        targets = keys if keys is not None else [dict(zip(table.spec.key, table.key_of(row))) for row in table.rows]
        for key in targets:
            if not table.has(key):
                raise NansenError("unknown-entity", f"no row with key {key}")
        default = table.defaults.get(column)
        for key in targets:
            table.update(key, **{column: default})
        table.write()
        return len(targets)

    def update_info(self, title: Optional[str] = None, description: Optional[str] = None,
                    entity_type_titles: Optional[Dict[str, str]] = None) -> None:
        """Change the project's title or description, or entity types' titles; an empty text removes it."""
        for name in entity_type_titles or {}:
            self.entity_type(name)  # unknown-entity-type before anything changes
        for key, value in (("title", title), ("description", description)):
            if value is not None:
                if str(value).strip():
                    self.document[key] = str(value).strip()
                else:
                    self.document.pop(key, None)
        for entry in self.document["entityTypes"]:
            if entry["name"] in (entity_type_titles or {}):
                value = str(entity_type_titles[entry["name"]]).strip()
                if value:
                    entry["title"] = value
                else:
                    entry.pop("title", None)
        self._check_and_save()

    def _check_and_save(self) -> None:
        self.document = check_document(self.document, "nansen.project")
        write_json(self.folder / PROJECT_FILE, self.document)


def default_environment() -> str:
    """This machine's environment name when none is set: its host name, as a DSM identifier."""
    import socket

    name = re.sub(r"[^a-z0-9-]+", "-", socket.gethostname().lower()).strip("-")
    return name if name and name[0].isalpha() else "machine-" + (name or "local")


def _root_identifier(environment: str, roots: List[dict]) -> str:
    base = re.sub(r"[^A-Za-z0-9_-]+", "-", environment).strip("-") or "root"
    if not base[0].isalpha():
        base = "root-" + base
    used = {r.get("identifier") for r in roots}
    candidate, n = base, 2
    while candidate in used:
        candidate, n = f"{base}-{n}", n + 1
    return candidate


def _set_environment(config_path: Path, environment: str) -> None:
    """Make the environment active on this machine, in the DSM config's .local.json overlay."""
    from . import jsontext

    overlay = config_path.with_name(config_path.stem + ".local.json")
    if overlay.is_file():
        text = overlay.read_text(encoding="utf-8")
        if "preferences" in json.loads(text):
            text = jsontext.set_member(text, "/preferences", "environmentIdentifier", environment)
        else:
            text = jsontext.set_member(text, "", "preferences", {"environmentIdentifier": environment})
    else:
        text = '{\n  "preferences": {\n    "environmentIdentifier": ' + jsontext.encode(environment) + "\n  }\n}\n"
    with open(overlay, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def _record_key(record: dict) -> Dict[str, Any]:
    key: Dict[str, Any] = {}
    for parent in record["parents"]:
        key.update(parent["identity"])
    key.update(record["identity"])
    return key


def check_fragments(spec: TableSpec, fragments: Sequence[Fragment]) -> None:
    """A table must hold exactly the declared fragments, at their defined versions, with their columns."""
    declared = {f.id for f in fragments}
    for fragment_id in spec.fragments:
        if fragment_id not in declared:
            raise NansenError("fragment-mismatch", f"table holds fragment {fragment_id!r}, which the entity type does not list")
    for fragment in fragments:
        recorded = spec.fragments.get(fragment.id)
        if recorded != fragment.version:
            raise NansenError(
                "fragment-mismatch",
                f"table follows {fragment.id} {recorded or '(absent)'}, the definition is {fragment.version}",
            )
        actual = [(c.name, c.data_type) for c in spec.columns if c.fragment == fragment.id]
        expected = [(c.name, c.data_type) for c in fragment.columns]
        if actual != expected:
            raise NansenError("fragment-mismatch", f"table columns for {fragment.id} are {actual}, the definition has {expected}")


def _numpy_array(value: Any) -> Any:
    """A stack read whole into an array."""
    import numpy
    return numpy.asarray(value)

