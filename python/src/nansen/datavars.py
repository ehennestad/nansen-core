"""Data variables: where an entity's named data is, and how to read and write it."""

from __future__ import annotations

import datetime as dt
import re
from dataclasses import dataclass
from typing import Any, List, Mapping, Optional, Tuple

from .errors import NansenError

TOKEN = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)\}")


@dataclass
class DataVariable:
    document: dict

    @property
    def name(self) -> str:
        return self.document["name"]

    @property
    def entity_type(self) -> str:
        return self.document["entityType"]

    @property
    def data_location(self) -> str:
        return self.document["dataLocation"]

    @property
    def file_pattern(self) -> Optional[str]:
        return self.document.get("filePattern")

    @property
    def file_name(self) -> Optional[str]:
        return self.document.get("fileName")

    @property
    def subfolder(self) -> str:
        return self.document.get("subfolder", "")

    @property
    def file_adapter(self) -> str:
        return self.document["fileAdapter"]

    def relative_file(self, values: Mapping[str, Any]) -> str:
        """subfolder/fileName with the tokens filled, relative to the entity's folder."""
        if self.file_name is None:
            raise NansenError("no-file-name", f"data variable {self.name!r} has no fileName, so it cannot be written")
        name = fill_template(self.file_name, values, self.name)
        return f"{self.subfolder}/{name}" if self.subfolder else name


def format_token(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, dt.datetime):
        text = value.strftime("%Y-%m-%dT%H:%M:%S")
        return text + (f".{value.microsecond // 1000:03d}" if value.microsecond // 1000 else "")
    if isinstance(value, dt.date):
        return value.isoformat()
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return str(value)


def fill_template(template: str, values: Mapping[str, Any], what: str) -> str:
    def replace(match):
        value = values.get(match.group(1))
        if value is None:
            raise NansenError("missing-value", f"{what}: '{match.group(1)}' has no value for this entity")
        return format_token(value)

    return TOKEN.sub(replace, template)


def check_against_pattern(variable: DataVariable, pattern: str, values: Mapping[str, Any]) -> None:
    """A generated file name must match the DSM file pattern it is read back through."""
    regex = TOKEN.sub(lambda m: re.escape(format_token(values.get(m.group(1), ""))), pattern)
    name = variable.relative_file(values).split("/")[-1]
    if not re.search(regex, name):
        raise NansenError("file-name-mismatch",
                          f"data variable {variable.name!r}: {name!r} does not match file pattern {pattern!r}")


def read_paths(variable: DataVariable, entity, level_patterns: Mapping[str, str]) -> List[Tuple[str, str]]:
    """(dataLocation, path relative to the root) of each file that holds the variable for the entity.

    Through the DSM file pattern when there is one, else subfolder/fileName in
    each of the entity's folders in the location (whether or not it exists).
    """
    location = entity.location(variable.data_location)
    if variable.file_pattern is not None:
        if variable.file_pattern not in level_patterns:
            raise NansenError("unknown-file-pattern",
                              f"no file pattern {variable.file_pattern!r} at the {variable.entity_type} level "
                              f"of {variable.data_location!r}")
        return [(variable.data_location, p) for p in entity.files(variable.data_location, variable.file_pattern)]
    if location is None:
        return []
    relative = variable.relative_file(entity.values)
    return [(variable.data_location, folder + relative) for folder in location["paths"]
            if location.get("fileSystemType", "folder") == "folder"]
