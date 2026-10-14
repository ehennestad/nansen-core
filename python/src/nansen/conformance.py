"""Run the cases in conformance/ against this implementation."""

from __future__ import annotations

import json
import shutil
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, List, Optional

import dsm

from .documents import PathLike, read_document
from .entities import entity_summary
from .errors import NansenError
from .project import Project
from .tables import EntityTable

KINDS = ("documents", "tables", "projects", "entities", "data")


@dataclass
class CaseResult:
    kind: str
    name: str
    passed: bool
    detail: str = ""


def default_root() -> Path:
    return Path(__file__).resolve().parent.parent.parent.parent / "conformance"


def run_cases(root: Optional[PathLike] = None) -> List[CaseResult]:
    root = Path(root) if root is not None else default_root()
    results = []
    for kind in KINDS:
        for case in sorted(p for p in (root / kind).iterdir() if p.is_dir()):
            results.append(run_case(kind, case))
    return results


def run_case(kind: str, case: Path) -> CaseResult:
    with open(case / "expected.json", encoding="utf-8") as f:
        expected = json.load(f)
    try:
        actual, written = _evaluate(kind, case, expected)
    except NansenError as error:
        if expected.get("error") == error.code:
            return CaseResult(kind, case.name, True)
        return CaseResult(kind, case.name, False, f"raised {error.code}: {error.message}")
    if "error" in expected:
        return CaseResult(kind, case.name, False, f"expected error {expected['error']}, got a result")
    mismatch = _compare(expected, actual)
    if mismatch:
        return CaseResult(kind, case.name, False, mismatch)
    if written is not None:
        csv_name = next(case.glob("*.csv")).name
        on_disk = (case / csv_name).read_bytes().decode("utf-8")
        if written != on_disk:
            return CaseResult(kind, case.name, False, f"writing the rows back gives {written!r}, expected {on_disk!r}")
    return CaseResult(kind, case.name, True)


def _evaluate(kind: str, case: Path, expected: dict):
    if kind == "documents":
        document = read_document(case / "document.json")
        return {"valid": True, "schemaType": document["schemaType"]}, None
    if kind == "tables":
        table = EntityTable.read(next(case.glob("*.table.nansen.json")))
        written = None
        if expected.get("canonical"):
            # Write from the expected rows, not the parsed ones, so writing is tested on its own.
            fresh = EntityTable(table.spec, [_from_json_row(table, row) for row in expected["rows"]])
            written = fresh.to_csv()
        return {"rows": table.to_json_rows()}, written
    if kind == "entities":
        return _evaluate_entities(case), None
    if kind == "data":
        return _evaluate_data(case), None
    project = Project.open(case / "project")
    tables = {}
    for name in project.entity_types:
        table = project.table(name)
        tables[name] = {"key": table.spec.key, "columns": table.spec.column_names,
                        "revision": table.spec.revision, "rows": table.to_json_rows()}
    return {"name": project.name, "title": project.title, "entityTypes": project.entity_types, "tables": tables}, None


def _evaluate_entities(case: Path) -> dict:
    # Sync writes the tables, so work on a copy.
    with tempfile.TemporaryDirectory() as scratch:
        folder = Path(scratch) / "project"
        shutil.copytree(case / "project", folder)
        project = Project.open(folder)
        scan = project.scan(dsm.load_listing(case / "listing.json"), save=False)
        entities, synced = {}, {}
        for name in project.entity_types:
            table = project.table(name)
            entities[name] = [dict(entity_summary(e), values=table.json_row(e.row) if e.row is not None else None)
                              for e in project.entities(name, scan)]
        for name in project.entity_types:
            synced[name] = project.sync(name, scan)
        return {"entities": entities, "sync": synced}


def _evaluate_data(case: Path) -> dict:
    project = Project.open(case / "project")
    scan = project.scan(dsm.load_listing(case / "listing.json"), save=False)
    with open(case / "requests.json", encoding="utf-8") as f:
        requests = json.load(f)["requests"]
    results = []
    for request in requests:
        entity = project.entity(request["entityType"], request["key"], scan)
        result = {}
        try:
            result["read"] = [list(t) for t in project.read_targets(entity, request["variable"])]
        except NansenError as error:
            result["read"] = {"error": error.code}
        try:
            result["write"] = list(project.write_target(entity, request["variable"]))
        except NansenError as error:
            result["write"] = {"error": error.code}
        results.append(result)
    return {"results": results}


def _from_json_row(table: EntityTable, row: dict) -> dict:
    return dict(row)  # check_value parses date and datetime strings


def _compare(expected: dict, actual: dict) -> str:
    for key, value in expected.items():
        if key in ("description", "canonical"):
            continue
        if not _equal(value, actual.get(key)):
            return f"{key}: expected {json.dumps(value)}, got {json.dumps(actual.get(key), default=str)}"
    return ""


def _equal(a: Any, b: Any) -> bool:
    if isinstance(a, bool) or isinstance(b, bool):
        return type(a) is type(b) and a == b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return float(a) == float(b)
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(_equal(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(_equal(x, y) for x, y in zip(a, b))
    return a == b
