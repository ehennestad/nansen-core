"""Saved views of an entity type's table: which rows and columns to show.

A view has a name, and any of: a list of keys (the rows it holds, as dev's extra metatables did),
filters on columns, hidden columns and a search text. The views of an entity type are kept in
views/<entityType>.views.nansen.json; the dashboard applies them, and the table is not changed.
nansen.Views does the same in MATLAB.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List, Sequence

from .documents import check_document, read_document, write_json
from .errors import NansenError
from .schemas import current_version


class Views:
    """The saved views of one entity type. Get one with Project.views(entityType)."""

    def __init__(self, path: Path, entity_type: str, key_names: Sequence[str]):
        self.path = Path(path)
        self.entity_type = entity_type
        self.key_names = list(key_names)

    def _read(self) -> dict:
        if not self.path.is_file():
            return {"schemaType": "nansen.views", "schemaVersion": current_version("nansen.views"),
                    "entityType": self.entity_type, "views": []}
        return read_document(self.path, "nansen.views")

    def list(self) -> List[dict]:
        """The views, in the order they were first saved."""
        return self._read()["views"]

    def save(self, view: Dict[str, Any]) -> dict:
        """Add a view, or replace the one of the same name (keeping its place)."""
        if not isinstance(view, dict) or not str(view.get("name", "")).strip():
            raise NansenError("invalid-params", "a view needs a name")
        for key in view.get("keys", []):
            if not isinstance(key, dict) or sorted(key) != sorted(self.key_names):
                raise NansenError("invalid-params", f"a key of {self.entity_type} has the columns {', '.join(self.key_names)}")
        document = self._read()
        views = [v for v in document["views"] if v["name"] != view["name"]]
        position = next((i for i, v in enumerate(document["views"]) if v["name"] == view["name"]), len(views))
        views.insert(position, view)
        document["views"] = views
        self.path.parent.mkdir(parents=True, exist_ok=True)
        write_json(self.path, check_document(document, "nansen.views"))
        return view

    def delete(self, name: str) -> None:
        document = self._read()
        kept = [v for v in document["views"] if v["name"] != name]
        if len(kept) == len(document["views"]):
            raise NansenError("unknown-view", f"{self.entity_type} has no view {name!r}")
        document["views"] = kept
        write_json(self.path, check_document(document, "nansen.views"))
