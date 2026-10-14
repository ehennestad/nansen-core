"""Entity tables: a CSV of values plus a nansen.table sidecar (docs/reference/table-format.md).

In memory a table is a list of rows, each a dict from column name to a
Python value: str, int, float, bool, datetime.date, datetime.datetime, or
None for a missing value.
"""

from __future__ import annotations

import datetime as dt
import math
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple, Union

from .csvio import Field, format_csv, parse_csv, quote_string
from .documents import PathLike, read_document, read_json, write_json
from .errors import NansenError
from .numbers import format_number
from .schemas import current_version

Row = Dict[str, Any]

_INTEGER = re.compile(r"^-?(0|[1-9][0-9]*)$")
_NUMBER = re.compile(r"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$")
_DATE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})$")
_DATETIME = re.compile(r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{3}))?$")
_MAX_INTEGER = 2**53
KEY_TYPES = ("string", "integer")


@dataclass(frozen=True)
class Column:
    name: str
    data_type: str
    fragment: Optional[str] = None
    unit: Optional[str] = None
    description: Optional[str] = None

    @classmethod
    def from_dict(cls, d: dict) -> "Column":
        return cls(d["name"], d["dataType"], d.get("fragment"), d.get("unit"), d.get("description"))

    def to_dict(self) -> dict:
        out: dict = {"name": self.name, "dataType": self.data_type}
        for key, value in (("fragment", self.fragment), ("unit", self.unit), ("description", self.description)):
            if value is not None:
                out[key] = value
        return out


@dataclass
class TableSpec:
    """The content of a table sidecar, minus the envelope."""

    entity_type: str
    key: List[str]
    columns: List[Column]
    fragments: Dict[str, str] = field(default_factory=dict)  # id -> version
    file: Optional[str] = None
    revision: int = 0

    @classmethod
    def from_document(cls, doc: dict) -> "TableSpec":
        spec = cls(
            entity_type=doc["entityType"],
            key=list(doc["key"]),
            columns=[Column.from_dict(c) for c in doc["columns"]],
            fragments={f["id"]: f["version"] for f in doc.get("fragments", [])},
            file=doc["file"],
            revision=doc["revision"],
        )
        spec.check()
        return spec

    def to_document(self) -> dict:
        doc: dict = {
            "schemaType": "nansen.table",
            "schemaVersion": current_version("nansen.table"),
            "entityType": self.entity_type,
            "file": self.csv_name,
            "revision": self.revision,
            "key": list(self.key),
            "columns": [c.to_dict() for c in self.columns],
        }
        if self.fragments:
            doc["fragments"] = [{"id": i, "version": v} for i, v in self.fragments.items()]
        return doc

    @property
    def csv_name(self) -> str:
        return self.file or f"{self.entity_type}.csv"

    @property
    def column_names(self) -> List[str]:
        return [c.name for c in self.columns]

    def column(self, name: str) -> Column:
        for c in self.columns:
            if c.name == name:
                return c
        raise KeyError(name)

    def check(self) -> None:
        names = self.column_names
        duplicates = sorted({n for n in names if names.count(n) > 1})
        if duplicates:
            raise NansenError("invalid-table-spec", f"duplicate column names: {', '.join(duplicates)}")
        for name in self.key:
            if name not in names:
                raise NansenError("invalid-table-spec", f"key column {name!r} is not among the columns")
            if self.column(name).data_type not in KEY_TYPES:
                raise NansenError("invalid-table-spec", f"key column {name!r} must be string or integer")


class EntityTable:
    """One entity type's authored values. Create with EntityTable.read or EntityTable(spec)."""

    def __init__(self, spec: TableSpec, rows: Optional[Iterable[Row]] = None, path: Optional[PathLike] = None):
        spec.check()
        self.spec = spec
        self.path = Path(path) if path is not None else None
        # Values for columns a new row leaves out; filled from fragment defaults.
        self.defaults: Dict[str, Any] = {}
        self._rows: List[Row] = []
        self._index: Dict[Tuple[Any, ...], int] = {}
        for row in rows or ():
            self.add(row)

    # -- reading and writing ------------------------------------------------------------

    @classmethod
    def read(cls, sidecar_path: PathLike) -> "EntityTable":
        sidecar_path = Path(sidecar_path)
        spec = TableSpec.from_document(read_document(sidecar_path, "nansen.table"))
        csv_path = sidecar_path.parent / spec.csv_name
        if not csv_path.is_file():
            raise NansenError("file-not-found", f"File not found: {csv_path}")
        with open(csv_path, encoding="utf-8", newline="") as f:
            records = parse_csv(f.read())
        header = [field.text for field in records[0]]
        if header != spec.column_names:
            raise NansenError(
                "header-mismatch", f"{csv_path}: header {header} does not match the sidecar columns {spec.column_names}"
            )
        table = cls(spec, path=sidecar_path)
        for number, record in enumerate(records[1:], start=2):
            if len(record) != len(spec.columns):
                raise NansenError(
                    "malformed-csv", f"{csv_path}: record {number} has {len(record)} fields, expected {len(spec.columns)}"
                )
            row = {c.name: decode_value(f, c, spec.key, number) for c, f in zip(spec.columns, record)}
            table._append(row, number)
        return table

    def write(self, sidecar_path: Optional[PathLike] = None) -> None:
        """Save the CSV and sidecar; fails with revision-conflict if the file changed since it was read."""
        path = Path(sidecar_path) if sidecar_path is not None else self.path
        if path is None:
            raise ValueError("no path given and the table was not read from a file")
        if path.is_file():
            on_disk = read_json(path)
            if not isinstance(on_disk, dict) or on_disk.get("revision") != self.spec.revision:
                raise NansenError(
                    "revision-conflict",
                    f"{path} has revision {on_disk.get('revision') if isinstance(on_disk, dict) else '?'}, "
                    f"this table was read at revision {self.spec.revision}",
                )
            new_revision = self.spec.revision + 1
        else:
            new_revision = self.spec.revision
        csv_path = path.parent / self.spec.csv_name
        csv_tmp = csv_path.with_name(csv_path.name + ".tmp")
        sidecar_tmp = path.with_name(path.name + ".tmp")
        document = self.spec.to_document()
        document["revision"] = new_revision
        with open(csv_tmp, "w", encoding="utf-8", newline="") as f:
            f.write(self.to_csv())
        write_json(sidecar_tmp, document)
        os.replace(csv_tmp, csv_path)
        os.replace(sidecar_tmp, path)
        self.spec.revision = new_revision
        self.path = path

    def to_csv(self) -> str:
        return format_csv(
            self.spec.column_names,
            [[encode_value(row[c.name], c) for c in self.spec.columns] for row in self._rows],
        )

    def to_json_rows(self) -> List[Row]:
        """The rows as JSON values, dates and datetimes in their CSV form; the conformance output."""
        return [self.json_row(row) for row in self._rows]

    def json_row(self, row: Row) -> Row:
        return {c.name: to_json_value(row[c.name], c) for c in self.spec.columns}

    # -- rows ----------------------------------------------------------------------------

    @property
    def rows(self) -> List[Row]:
        return [dict(row) for row in self._rows]

    def __len__(self) -> int:
        return len(self._rows)

    def key_of(self, row: Row) -> Tuple[Any, ...]:
        return tuple(row.get(name) for name in self.spec.key)

    def get(self, key: Union[Sequence[Any], Dict[str, Any]]) -> Row:
        return dict(self._rows[self._index[self._normalize_key(key)]])

    def has(self, key: Union[Sequence[Any], Dict[str, Any]]) -> bool:
        return self._normalize_key(key) in self._index

    def add(self, row: Row) -> None:
        """Add a row; columns it leaves out get their default, or None."""
        unknown = set(row) - set(self.spec.column_names)
        if unknown:
            raise KeyError(f"unknown columns: {', '.join(sorted(unknown))}")
        full = {c.name: check_value(row.get(c.name, self.defaults.get(c.name)), c, c.name in self.spec.key)
                for c in self.spec.columns}
        self._append(full, len(self._rows) + 2)

    def update(self, key: Union[Sequence[Any], Dict[str, Any]], **values: Any) -> None:
        index = self._index[self._normalize_key(key)]
        for name, value in values.items():
            if name in self.spec.key:
                raise NansenError("read-only-column", f"cannot change key column {name!r}")
            self._rows[index][name] = check_value(value, self.spec.column(name), False)

    def remove(self, key: Union[Sequence[Any], Dict[str, Any]]) -> None:
        index = self._index.pop(self._normalize_key(key))
        del self._rows[index]
        self._index = {self.key_of(row): i for i, row in enumerate(self._rows)}

    def add_columns(self, columns: Sequence[Column], defaults: Optional[Dict[str, Any]] = None,
                    fragment: Optional[Tuple[str, str]] = None) -> None:
        """Append columns, filling existing rows with each column's default."""
        defaults = defaults or {}
        new_spec = TableSpec(self.spec.entity_type, list(self.spec.key), self.spec.columns + list(columns),
                             dict(self.spec.fragments), self.spec.file, self.spec.revision)
        if fragment is not None:
            new_spec.fragments[fragment[0]] = fragment[1]
        new_spec.check()
        filled = {c.name: check_value(defaults.get(c.name), c, False) for c in columns}
        self.spec = new_spec
        self.defaults.update({c.name: defaults[c.name] for c in columns if c.name in defaults})
        for row in self._rows:
            row.update(filled)

    def _normalize_key(self, key: Union[Sequence[Any], Dict[str, Any]]) -> Tuple[Any, ...]:
        if isinstance(key, dict):
            return tuple(key[name] for name in self.spec.key)
        if isinstance(key, (str, int)):
            key = (key,)
        return tuple(key)

    def _append(self, row: Row, number: int) -> None:
        key = self.key_of(row)
        if key in self._index:
            raise NansenError("duplicate-key", f"record {number} repeats the key {dict(zip(self.spec.key, key))}")
        self._index[key] = len(self._rows)
        self._rows.append(row)


# -- values -------------------------------------------------------------------------------


def decode_value(field: Field, column: Column, key: Sequence[str], record: int) -> Any:
    text = field.text
    where = f"record {record}, column {column.name!r}"
    data_type = column.data_type
    if text == "" and not (field.quoted and data_type == "string"):
        if column.name in key:
            raise NansenError("missing-key", f"{where}: the key is empty")
        if data_type == "boolean":
            raise NansenError("missing-value", f"{where}: boolean cells must have a value")
        return None
    if data_type == "string":
        return text
    if data_type == "integer":
        if not _INTEGER.match(text) or abs(int(text)) > _MAX_INTEGER:
            raise NansenError("invalid-value", f"{where}: {text!r} is not an integer within +-2^53")
        return int(text)
    if data_type == "number":
        value = float(text) if _NUMBER.match(text) else math.nan
        if not math.isfinite(value):
            raise NansenError("invalid-value", f"{where}: {text!r} is not a finite number")
        return value
    if data_type == "boolean":
        if text not in ("true", "false"):
            raise NansenError("invalid-value", f"{where}: {text!r} is not true or false")
        return text == "true"
    if data_type == "date":
        return _parse_date(text, where)
    if data_type == "datetime":
        return _parse_datetime(text, where)
    raise NansenError("invalid-table-spec", f"unknown data type {data_type!r}")


def _parse_date(text: str, where: str) -> dt.date:
    match = _DATE.match(text)
    try:
        if match:
            return dt.date(*(int(g) for g in match.groups()))
    except ValueError:
        pass
    raise NansenError("invalid-value", f"{where}: {text!r} is not a date (YYYY-MM-DD)")


def _parse_datetime(text: str, where: str) -> dt.datetime:
    match = _DATETIME.match(text)
    try:
        if match:
            *parts, millis = match.groups()
            return dt.datetime(*(int(g) for g in parts), int(millis or 0) * 1000)
    except ValueError:
        pass
    raise NansenError("invalid-value", f"{where}: {text!r} is not a datetime (YYYY-MM-DDTHH:MM:SS[.fff])")


def check_value(value: Any, column: Column, is_key: bool) -> Any:
    """Coerce a Python value to the column's type, or raise."""
    where = f"column {column.name!r}"
    data_type = column.data_type
    if value is None or (isinstance(value, float) and math.isnan(value)):
        if is_key:
            raise NansenError("missing-key", f"{where}: the key is missing")
        if data_type == "boolean":
            raise NansenError("missing-value", f"{where}: boolean cells must have a value")
        return None
    if data_type == "string" and isinstance(value, str):
        return value
    if data_type == "integer" and isinstance(value, (int, float)) and not isinstance(value, bool):
        if float(value).is_integer() and abs(value) <= _MAX_INTEGER:
            return int(value)
    if data_type == "number" and isinstance(value, (int, float)) and not isinstance(value, bool):
        if math.isfinite(value):
            return float(value)
    if data_type == "boolean" and isinstance(value, bool):
        return value
    if data_type == "date":
        if isinstance(value, str):
            return _parse_date(value, where)
        if isinstance(value, dt.date) and not isinstance(value, dt.datetime):
            return value
    if data_type == "datetime":
        if isinstance(value, str):
            return _parse_datetime(value, where)
        if isinstance(value, dt.datetime) and value.tzinfo is None:
            return value.replace(microsecond=value.microsecond // 1000 * 1000)
    raise NansenError("invalid-value", f"{where}: {value!r} is not a valid {data_type}")


def encode_value(value: Any, column: Column) -> str:
    if value is None:
        return ""
    data_type = column.data_type
    if data_type == "string":
        return quote_string(value)
    if data_type == "integer":
        return str(int(value))
    if data_type == "number":
        return format_number(value)
    if data_type == "boolean":
        return "true" if value else "false"
    if data_type == "date":
        return value.isoformat()
    if data_type == "datetime":
        text = (f"{value.year:04d}-{value.month:02d}-{value.day:02d}"
                f"T{value.hour:02d}:{value.minute:02d}:{value.second:02d}")
        millis = value.microsecond // 1000
        return text + (f".{millis:03d}" if millis else "")
    raise NansenError("invalid-table-spec", f"unknown data type {data_type!r}")


def to_json_value(value: Any, column: Column) -> Any:
    if value is None:
        return None
    if column.data_type in ("date", "datetime"):
        return encode_value(value, column)
    return value
