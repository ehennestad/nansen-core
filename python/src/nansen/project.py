"""A project folder (docs/reference/project-layout.md). Opened explicitly; nothing is global."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

from .documents import PathLike, check_document, read_document, write_json
from .errors import NansenError
from .schemas import current_version
from .tables import Column, EntityTable, TableSpec

PROJECT_FILE = "project.nansen.json"


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
    def __init__(self, folder: PathLike, document: dict):
        self.folder = Path(folder)
        self.document = document

    # -- creating and opening -------------------------------------------------------------

    @classmethod
    def create(cls, folder: PathLike, name: str, title: Optional[str] = None) -> "Project":
        folder = Path(folder)
        if (folder / PROJECT_FILE).exists():
            raise FileExistsError(f"{folder} already holds a project")
        document: dict = {"schemaType": "nansen.project", "schemaVersion": current_version("nansen.project"), "name": name}
        if title is not None:
            document["title"] = title
        document["entityTypes"] = []
        document = check_document(document, "nansen.project")
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "fragments").mkdir(exist_ok=True)
        (folder / "tables").mkdir(exist_ok=True)
        project = cls(folder, document)
        project._check_and_save()
        return project

    @classmethod
    def open(cls, folder: PathLike) -> "Project":
        folder = Path(folder)
        return cls(folder, read_document(folder / PROJECT_FILE, "nansen.project"))

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
        key: Sequence[Column],
        fragments: Sequence[str] = (),
        title: Optional[str] = None,
    ) -> EntityTable:
        """Declare an entity type and write its empty table: the key columns, then each fragment's columns."""
        if name in self.entity_types:
            raise ValueError(f"entity type {name!r} already exists")
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

    def add_fragment(self, document: dict) -> Fragment:
        """Save a project-defined fragment."""
        fragment = Fragment(check_document(document, "nansen.fragment"))
        write_json(self.fragment_path(fragment.id), fragment.document)
        return fragment

    def _check_and_save(self) -> None:
        self.document = check_document(self.document, "nansen.project")
        write_json(self.folder / PROJECT_FILE, self.document)


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
