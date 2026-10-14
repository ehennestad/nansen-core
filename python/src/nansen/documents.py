"""Read and validate any NANSEN document: envelope, version check, migration, schema validation."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Optional, Sequence, Tuple, Union

from .errors import NansenError
from .schemas import current_version, schema_index, validator

PathLike = Union[str, Path]

_SEMVER = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


@dataclass(frozen=True)
class Migration:
    """Upgrade one document type from one MAJOR.MINOR to the next.

    ``apply`` receives the decoded document and returns the upgraded one; it
    does not need to set schemaVersion, the reader does that.
    """

    schema_type: str
    from_version: str  # "MAJOR.MINOR"
    to_version: str  # "MAJOR.MINOR"
    apply: Callable[[dict], dict]


# No schema has changed since 0.1, so there is nothing to migrate yet.
DEFAULT_MIGRATIONS: Tuple[Migration, ...] = ()


def parse_version(text: Any) -> Optional[Tuple[int, int, int]]:
    if not isinstance(text, str):
        return None
    match = _SEMVER.match(text)
    return tuple(int(part) for part in match.groups()) if match else None  # type: ignore[return-value]


def read_json(path: PathLike) -> Any:
    path = Path(path)
    if not path.is_file():
        raise NansenError("file-not-found", f"File not found: {path}")
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except json.JSONDecodeError as error:
        raise NansenError("malformed-json", f"{path}: {error}") from None


def write_json(path: PathLike, document: dict) -> None:
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(document, f, indent=2, ensure_ascii=False)
        f.write("\n")


def read_document(
    path: PathLike,
    expected_type: Optional[str] = None,
    migrations: Optional[Sequence[Migration]] = None,
) -> dict:
    """Read a document from disk; see check_document."""
    return check_document(read_json(path), expected_type, migrations, source=str(path))


def check_document(
    document: Any,
    expected_type: Optional[str] = None,
    migrations: Optional[Sequence[Migration]] = None,
    source: str = "document",
) -> dict:
    """Check the envelope, migrate an older version and validate against the current schema.

    Returns the document as the current version describes it. Raises
    NansenError with the codes in docs/conventions.md.
    """
    if migrations is None:
        migrations = DEFAULT_MIGRATIONS
    if not isinstance(document, dict):
        raise NansenError("unknown-schema-type", f"{source}: a document must be a JSON object")
    schema_type = document.get("schemaType")
    if not isinstance(schema_type, str) or schema_type not in schema_index():
        raise NansenError("unknown-schema-type", f"{source}: unknown schemaType {schema_type!r}")
    if expected_type is not None and schema_type != expected_type:
        raise NansenError("unknown-schema-type", f"{source}: expected a {expected_type} document, got {schema_type}")

    document = _migrate(document, schema_type, migrations, source)

    errors = sorted(validator(schema_type).iter_errors(document), key=lambda e: list(e.absolute_path))
    if errors:
        details = "; ".join(f"[{'/'.join(map(str, e.absolute_path)) or '$'}] {e.message}" for e in errors)
        raise NansenError("schema-validation", f"{source}: {details}")
    return document


def _migrate(document: dict, schema_type: str, migrations: Sequence[Migration], source: str) -> dict:
    version = parse_version(document.get("schemaVersion"))
    current = parse_version(current_version(schema_type))
    if version is None:
        raise NansenError("unsupported-version", f"{source}: schemaVersion {document.get('schemaVersion')!r} is not MAJOR.MINOR.PATCH")
    assert current is not None
    if version[:2] > current[:2]:
        raise NansenError(
            "unsupported-version",
            f"{source}: {schema_type} {document['schemaVersion']} is newer than this reader ({current_version(schema_type)})",
        )
    step = f"{version[0]}.{version[1]}"
    target = f"{current[0]}.{current[1]}"
    while step != target:
        migration = next((m for m in migrations if m.schema_type == schema_type and m.from_version == step), None)
        if migration is None:
            raise NansenError("unsupported-version", f"{source}: no migration for {schema_type} from {step}")
        if parse_version(migration.to_version + ".0") <= parse_version(step + ".0"):
            raise NansenError("unsupported-version", f"migration for {schema_type} from {step} does not move forward")
        document = migration.apply(dict(document))
        step = migration.to_version
        document["schemaVersion"] = f"{step}.0"
    return document
