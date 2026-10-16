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

KINDS = ("documents", "tables", "projects", "entities", "data", "legacy", "jsontext", "yaml", "api")


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
    if kind == "api":
        detail = _run_api_case(case)
        return CaseResult(kind, case.name, not detail, detail)
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
    if kind == "legacy":
        return _evaluate_legacy(case), None
    if kind == "jsontext":
        return _evaluate_jsontext(case), None
    if kind == "yaml":   # dev's metadata files (nansen.devyaml)
        from . import devyaml

        return {"value": devyaml.parse((case / "input.yaml").read_bytes().decode("utf-8"))}, None
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


def _evaluate_jsontext(case: Path) -> dict:
    from . import jsontext

    text = (case / "input.json").read_bytes().decode("utf-8")
    with open(case / "edits.json", encoding="utf-8") as f:
        edits = json.load(f)["edits"]
    for edit in edits:
        if edit["op"] == "replace":
            text = jsontext.replace(text, edit["pointer"], edit["value"])
        elif edit["op"] == "append":
            text = jsontext.append(text, edit["pointer"], edit["value"])
        else:
            text = jsontext.set_member(text, edit["pointer"], edit["key"], edit["value"])
    return {"output": text}


def _evaluate_legacy(case: Path) -> dict:
    """Convert export.json and read back every file the new project holds."""
    from .legacy import convert_legacy

    with open(case / "export.json", encoding="utf-8") as f:
        export = json.load(f)
    with tempfile.TemporaryDirectory() as scratch:
        folder = Path(scratch) / "project"
        report = convert_legacy(export, folder)

        def documents(pattern: str) -> list:
            return [json.loads(p.read_text(encoding="utf-8")) for p in sorted(folder.glob(pattern))]

        project = Project.open(folder)
        tables = {}
        for name in project.entity_types:
            table = project.table(name)
            tables[name] = {"key": table.spec.key, "columns": table.spec.column_names, "rows": table.to_json_rows()}
        presets = sorted(folder.glob("options/*/*.options.nansen.json"), key=lambda p: p.relative_to(folder).as_posix())
        # queued tasks in their queue order, then the finished ones by when they were made and finished; without their
        # ids (new ones each time), and with the text of their log in place of its path
        tasks = sorted(documents("tasks/*.task.nansen.json"), key=lambda t: (
            f"0|{t['order']:09d}" if "order" in t else f"1|{t['createdAt']}|{t.get('finishedAt', '')}"))
        tasks = [dict(t, log=(folder / t["log"]).read_text(encoding="utf-8")) if "log" in t else t for t in tasks]
        runs = folder / "runs" / "session.runs.jsonl"
        return {"project": json.loads((folder / "project.nansen.json").read_text(encoding="utf-8")),
                "fileAdapters": documents("file-adapters/*.fileAdapter.nansen.json"),
                "presets": [json.loads(p.read_text(encoding="utf-8")) for p in presets],
                "tasks": [{k: v for k, v in t.items() if k != "id"} for t in tasks],
                "runs": [json.loads(line) for line in runs.read_text(encoding="utf-8").splitlines()] if runs.is_file() else [],
                "settings": report["settings"],
                "dataset": json.loads((folder / "dataset.dsm.json").read_text(encoding="utf-8")),
                "fragments": documents("fragments/*.fragment.nansen.json"),
                "dataVariables": documents("data-variables/*.dataVariable.nansen.json"),
                "notebooks": documents("notes/*.notebook.nansen.json"),
                "views": documents("views/*.views.nansen.json"),
                "pipelines": documents("pipelines/*.pipeline.nansen.json"),
                "methods": documents("methods/*.method.nansen.json"),
                "methodFiles": sorted(p.relative_to(folder / "matlab").as_posix()
                                      for p in (folder / "matlab").rglob("*") if p.is_file()),
                "tables": tables, "warnings": report["warnings"]}


def _run_api_case(case: Path) -> str:
    """Send each request of session.json to a fresh Api and compare the answers as subsets."""
    from .api import Api

    session_text = (case / "session.json").read_text(encoding="utf-8")
    listing = None
    if (case / "listing.json").is_file():
        with open(case / "listing.json", encoding="utf-8") as f:
            listing = json.load(f)
    with tempfile.TemporaryDirectory() as scratch:
        # ${scratch} and ${case} may appear inside any string, in requests and expected results alike
        for placeholder, path in (("${scratch}", Path(scratch)), ("${case}", case.resolve())):
            session_text = session_text.replace(placeholder, json.dumps(path.as_posix())[1:-1])
        session = json.loads(session_text)
        steps = session["steps"]
        folder = Path(scratch) / "project"
        if (case / "project").is_dir():
            shutil.copytree(case / "project", folder)
        if (case / "data").is_dir():   # files viewed without a project
            shutil.copytree(case / "data", Path(scratch) / "data")
        api = Api(start_queue=False, viewables=_viewables(session.get("viewables", [])))
        kept: dict = {}  # values a step keeps from its result, as ${name}, for the steps after it
        try:
            for number, step in enumerate(steps, start=1):
                request = _substitute(step["request"], {"${project}": str(folder), "${listing}": listing, **kept})
                step = dict(step, expect=_substitute(step["expect"], kept))
                response = api.handle(request)
                if response.get("id") != request.get("id"):
                    return f"step {number}: response id {response.get('id')!r} for request {request.get('id')!r}"
                expect = step["expect"]
                if "error" in expect:
                    if "error" not in response or response["error"]["code"] != expect["error"]:
                        return f"step {number} {request['method']}: expected error {expect['error']}, got {json.dumps(response)[:400]}"
                    continue
                if "error" in response:
                    return f"step {number} {request['method']}: unexpected error {response['error']}"
                mismatch = subset_mismatch(expect["result"], response["result"], "result")
                if mismatch:
                    return f"step {number} {request['method']}: {mismatch}"
                for name, pointer in step.get("keep", {}).items():
                    value = response["result"]
                    for token in pointer.split("/")[1:]:
                        value = value[int(token)] if isinstance(value, list) else value[token]
                    kept["${" + name + "}"] = value
        finally:
            api.close()
    return ""


def _viewables(entries: List[dict]):
    """What the case's app is given to view, as `nansen view` gives it: [{stack, rois?, name?, frameRate?} or
    {signals, name?, frameRate?}], registered in order (v1, v2, ...)."""
    from .viewables import Viewables

    viewables = Viewables()
    for entry in entries:
        if "signals" in entry:
            viewables.add_signals(entry["signals"], name=entry.get("name"), frame_rate=entry.get("frameRate"))
        else:
            viewables.add_stack(entry["stack"], name=entry.get("name"), rois=entry.get("rois"), frame_rate=entry.get("frameRate"))
    return viewables


def _substitute(value: Any, replacements: dict) -> Any:
    if isinstance(value, str) and value in replacements:
        return replacements[value]
    if isinstance(value, dict):
        return {k: _substitute(v, replacements) for k, v in value.items()}
    if isinstance(value, list):
        return [_substitute(v, replacements) for v in value]
    return value


def subset_mismatch(expected: Any, actual: Any, where: str) -> str:
    """Where actual fails to contain expected: objects by the expected keys, arrays element by element."""
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return f"{where}: expected an object, got {json.dumps(actual, default=str)[:200]}"
        for key, value in expected.items():
            if key not in actual:
                return f"{where}.{key}: missing"
            mismatch = subset_mismatch(value, actual[key], f"{where}.{key}")
            if mismatch:
                return mismatch
        return ""
    if isinstance(expected, list):
        if not isinstance(actual, list) or len(actual) != len(expected):
            return f"{where}: expected {len(expected)} items, got {json.dumps(actual, default=str)[:300]}"
        for index, (e, a) in enumerate(zip(expected, actual)):
            mismatch = subset_mismatch(e, a, f"{where}[{index}]")
            if mismatch:
                return mismatch
        return ""
    if not _equal(expected, actual):
        return f"{where}: expected {json.dumps(expected)}, got {json.dumps(actual, default=str)}"
    return ""


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
