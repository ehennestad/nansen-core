"""A project folder (docs/reference/project-layout.md). Opened explicitly; nothing is global."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

from .adapters import AdapterRegistry
from .dataset import Dataset, Scan
from .datavars import DataVariable, check_against_pattern, read_paths
from .documents import PathLike, check_document, read_document, write_json
from .entities import Entity, join
from .errors import NansenError
from .schemas import current_version
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


class Project:
    def __init__(self, folder: PathLike, document: dict, environment: Optional[str] = None):
        self.folder = Path(folder)
        self.document = document
        # The environment (machine) whose root paths to use; None means the dataset's preference.
        self.environment = environment
        self._dataset: Optional[Dataset] = None
        self._adapters: Optional[AdapterRegistry] = None

    # -- creating and opening -------------------------------------------------------------

    @classmethod
    def create(cls, folder: PathLike, name: str, title: Optional[str] = None,
               dataset: Optional[str] = None) -> "Project":
        """Make a project folder. ``dataset`` is the path of a DSM config, relative to the folder."""
        folder = Path(folder)
        if (folder / PROJECT_FILE).exists():
            raise FileExistsError(f"{folder} already holds a project")
        document: dict = {"schemaType": "nansen.project", "schemaVersion": current_version("nansen.project"), "name": name}
        if title is not None:
            document["title"] = title
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
        path = self.fragment_path(fragment_id)
        if not path.is_file():
            raise NansenError("unknown-fragment", f"fragment {fragment_id!r} is not defined ({path})")
        return Fragment.read(path)

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
        table = self.table(entity_type)
        added = []
        for entity in self.entities(entity_type, scan):
            if entity.in_table or any(i["code"] == "incomplete-key" for i in entity.issues):
                continue
            table.add(dict(entity.key))
            added.append(dict(entity.key))
        if added:
            table.write()
        return added

    # -- data variables and file adapters -----------------------------------------------------

    @property
    def adapters(self) -> AdapterRegistry:
        """Built-in adapters plus those declared in file-adapters/."""
        if self._adapters is None:
            registry = AdapterRegistry()
            folder = self.folder / "file-adapters"
            for path in sorted(folder.glob("*.fileAdapter.nansen.json")) if folder.is_dir() else []:
                registry.declare(read_document(path, "nansen.fileAdapter"), folder)
            self._adapters = registry
        return self._adapters

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

    def _level_patterns(self, variable: DataVariable) -> Dict[str, str]:
        config = self.require_dataset().config
        index = config.entity_level_index(variable.data_location, variable.entity_type)
        if index is None:
            return {}
        level = config.layout(variable.data_location)[index]
        return {p["name"]: p["pattern"] for p in level.get("filePatterns", []) if "name" in p}

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

    def load(self, entity: Entity, name: str) -> Any:
        """Read the variable for the entity with its file adapter (the first file, when a pattern matches several)."""
        variable = self.data_variable(name)
        existing = [p for p in self.data_paths(entity, name) if p.is_file()]
        if not existing:
            raise NansenError("data-not-found", f"{entity.entity_type} {entity.key} has no {name!r}")
        return self.adapters.get(variable.file_adapter).read(existing[0])

    def save(self, entity: Entity, name: str, data: Any) -> Path:
        """Write the variable for the entity, creating folders as needed. Returns the path written."""
        variable = self.data_variable(name)
        path = self.write_path(entity, name)
        path.parent.mkdir(parents=True, exist_ok=True)
        self.adapters.get(variable.file_adapter).write(path, data)
        return path

    def data_status(self, entity: Entity) -> List[Dict[str, Any]]:
        """Each data variable of the entity's type: whether a file exists, and where."""
        status = []
        for variable in self.data_variables(entity.entity_type):
            try:
                paths = self.data_paths(entity, variable.name)
            except NansenError:
                paths = []
            status.append({"name": variable.name, "dataLocation": variable.data_location,
                           "fileAdapter": variable.file_adapter,
                           "files": [str(p) for p in paths if p.is_file()]})
        return status

    def add_fragment(self, document: dict) -> Fragment:
        """Save a project-defined fragment."""
        fragment = Fragment(check_document(document, "nansen.fragment"))
        write_json(self.fragment_path(fragment.id), fragment.document)
        return fragment

    def _check_and_save(self) -> None:
        self.document = check_document(self.document, "nansen.project")
        write_json(self.folder / PROJECT_FILE, self.document)


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
