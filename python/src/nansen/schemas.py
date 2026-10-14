"""Locate the schemas: packaged copies when installed, the repo's schema/ folder when run in place."""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Any

from jsonschema import Draft7Validator

_PACKAGE_DIR = Path(__file__).resolve().parent
_CANDIDATE_DIRS = [_PACKAGE_DIR / "schemas", _PACKAGE_DIR.parent.parent.parent / "schema"]


def schema_dir() -> Path:
    for candidate in _CANDIDATE_DIRS:
        if (candidate / "index.json").is_file():
            return candidate
    raise FileNotFoundError("NANSEN schemas not found; looked in " + ", ".join(map(str, _CANDIDATE_DIRS)))


# The schema files ship with the package and never change at run time, so
# caching them is not application state.
@lru_cache(maxsize=None)
def schema_index() -> dict[str, dict[str, str]]:
    with open(schema_dir() / "index.json", encoding="utf-8") as f:
        return {entry["schemaType"]: entry for entry in json.load(f)["schemas"]}


@lru_cache(maxsize=None)
def load_schema(schema_type: str) -> dict[str, Any]:
    with open(schema_dir() / schema_index()[schema_type]["file"], encoding="utf-8") as f:
        return json.load(f)


@lru_cache(maxsize=None)
def validator(schema_type: str) -> Draft7Validator:
    return Draft7Validator(load_schema(schema_type))


def current_version(schema_type: str) -> str:
    return schema_index()[schema_type]["version"]
