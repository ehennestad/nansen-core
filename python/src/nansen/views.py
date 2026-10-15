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
        if view.get("default"):   # one default view: the others are not
            views = [dict(v, default=False) if v.get("default") else v for v in views]
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


def filter_passes(value: Any, view_filter: dict) -> bool:
    """Whether a value passes one filter of a view (as the dashboard applies them): none is null or empty text."""
    none = value is None or value == ""
    op = view_filter["op"]
    if op == "in":
        return any(none if v is None else (v == value and type(v) is type(value) or _same_number(v, value))
                   for v in view_filter.get("values", []))
    if op == "range":
        if none:
            return False
        for bound, ok in (("min", lambda b: value >= b), ("max", lambda b: value <= b)):
            b = view_filter.get(bound)
            if b is None:
                continue
            if not (_numbers(value, b) or (isinstance(value, str) and isinstance(b, str))) or not ok(b):
                return False
        return True
    if op == "is":
        return value is view_filter.get("value") or (isinstance(value, bool) and value == view_filter.get("value"))
    if op == "contains":
        return not none and str(view_filter.get("text", "")).lower() in str(value).lower()
    if op == "empty":
        return none
    if op == "notEmpty":
        return not none
    return True


def _numbers(*values: Any) -> bool:
    return all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in values)


def _same_number(a: Any, b: Any) -> bool:
    return _numbers(a, b) and a == b

