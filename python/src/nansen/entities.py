"""Entities: what the stores say about an entity (a DSM record) joined with what people authored (a table row)."""

from __future__ import annotations

from typing import Any, Dict, List, Optional, Tuple


class Entity:
    """One entity of a type, found in the stores, in the table, or both.

    ``key`` holds the key column values; ``record`` is the DSM entity record
    (JSON form) or None; ``row`` is the table row or None.
    """

    def __init__(self, entity_type: str, key: Dict[str, Any], record: Optional[dict] = None,
                 row: Optional[dict] = None, issues: Optional[List[dict]] = None):
        self.entity_type = entity_type
        self.key = key
        self.record = record
        self.row = row
        self.issues: List[dict] = list(record.get("issues", [])) if record else []
        self.issues += issues or []
        # Set by Project.entities, so the entity can read and write its data.
        self.project = None

    def __repr__(self) -> str:
        return f"Entity({self.entity_type}, {self.key})"

    @property
    def in_store(self) -> bool:
        return self.record is not None

    @property
    def in_table(self) -> bool:
        return self.row is not None

    @property
    def attributes(self) -> Dict[str, Any]:
        """What DSM read from the entity's names, including ancestors' identity."""
        return dict(self.record["metadata"]) if self.record else {}

    @property
    def locations(self) -> List[dict]:
        return list(self.record["locations"]) if self.record else []

    def location(self, data_location: str) -> Optional[dict]:
        for entry in self.locations:
            if entry["dataLocationIdentifier"] == data_location:
                return entry
        return None

    def files(self, data_location: str, pattern: str) -> List[str]:
        entry = self.location(data_location)
        return list((entry or {}).get("files", {}).get(pattern, []))

    @property
    def values(self) -> Dict[str, Any]:
        """Key, attributes and authored values in one dict; authored values win."""
        merged = dict(self.key)
        merged.update(self.attributes)
        merged.update(self.row or {})
        return merged

    def get(self, name: str, default: Any = None) -> Any:
        return self.values.get(name, default)

    def load(self, name: str) -> Any:
        return self._project().load(self, name)

    def save(self, name: str, data: Any):
        return self._project().save(self, name, data)

    def data_paths(self, name: str):
        return self._project().data_paths(self, name)

    def _project(self):
        if self.project is None:
            raise RuntimeError("this entity was not obtained from a project, so it cannot read or write data")
        return self.project

    def key_tuple(self, key_columns: List[str]) -> Tuple[Any, ...]:
        return tuple(self.key.get(name) for name in key_columns)


def join(entity_type: str, key_columns: List[str], records: List[dict], rows: List[dict],
         record_key) -> List[Entity]:
    """Table rows in table order, then entities only found in the stores, in walk order."""
    by_key: Dict[Tuple[Any, ...], dict] = {}
    entities: List[Entity] = []
    for record in records:
        key = record_key(record)
        missing = [name for name in key_columns if key.get(name) is None]
        if missing:
            entities.append(Entity(entity_type, {n: key.get(n) for n in key_columns}, record,
                                   issues=[{"code": "incomplete-key", "message": f"no value for {', '.join(missing)}"}]))
            continue
        by_key[tuple(key[n] for n in key_columns)] = record
    joined: List[Entity] = []
    seen = set()
    for row in rows:
        key_values = tuple(row[n] for n in key_columns)
        record = by_key.get(key_values)
        seen.add(key_values)
        joined.append(Entity(entity_type, {n: row[n] for n in key_columns}, record, row))
    for key_values, record in by_key.items():
        if key_values not in seen:
            joined.append(Entity(entity_type, dict(zip(key_columns, key_values)), record))
    return joined + entities


def entity_summary(entity: Entity, columns: Optional[List[str]] = None) -> Dict[str, Any]:
    """The JSON form of an entity: the conformance output and the API's."""
    out: Dict[str, Any] = {
        "key": dict(entity.key),
        "inStore": entity.in_store,
        "inTable": entity.in_table,
        "attributes": entity.attributes,
        "locations": {e["dataLocationIdentifier"]: sorted(e["paths"]) for e in entity.locations},
    }
    if entity.issues:
        out["issues"] = sorted({i["code"] for i in entity.issues})
    return out
