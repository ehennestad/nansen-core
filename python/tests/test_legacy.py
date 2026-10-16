"""The dev-project importer: the conversion rules, and a converted project that scans real folders."""

import json
from pathlib import Path

import pytest

from nansen import Project
from nansen.cli import main
from nansen.errors import NansenError
from nansen.legacy import convert_legacy, matlab_index_to_slice, plan_legacy

CASE = Path(__file__).resolve().parents[2] / "conformance" / "legacy" / "two-photon" / "export.json"


@pytest.mark.parametrize("expression, expected", [
    ("1:end", ":"), ("1:5", ":5"), ("3:end", "2:"), ("end-3:end", "-4:"), ("4", "3:4"),
    ("end-2:end-1", "-3:-1"), (" 2 : 6 ", "1:6"), ("end", "-1:"),
])
def test_index_ranges_become_slices(expression, expected):
    assert matlab_index_to_slice(expression) == expected


@pytest.mark.parametrize("expression", ["[1:3 5:7]", "0:4", "5:2", "1:2:9", "a:b", ""])
def test_index_expressions_without_a_slice(expression):
    assert matlab_index_to_slice(expression) is None


def export_for(raw: Path, processed: Path) -> dict:
    export = json.loads(CASE.read_text())
    export["dataLocations"][0]["rootPaths"][0]["value"] = str(raw)
    export["dataLocations"][1]["rootPaths"][0]["value"] = str(processed)
    return export


def test_a_converted_project_scans_and_joins(tmp_path):
    raw, processed = tmp_path / "raw", tmp_path / "processed"
    for subject, date, session in [("m110", "2025_05_23", "m110-001"), ("m110", "2025_05_24", "m110-002"),
                                   ("m111", "2025_05_25", "m111-001")]:
        folder = raw / subject / date / f"session-{session}"
        folder.mkdir(parents=True)
        (folder / f"{session}_config.json").write_text('{"zoom": 2}')
    (raw / "m112_old").mkdir()  # left out by the ignore list
    (raw / ".hidden").mkdir()
    project_folder = tmp_path / "project"
    report = convert_legacy(export_for(raw, processed), project_folder)
    assert report["rows"] == {"subject": 2, "session": 2}

    project = Project.open(project_folder)
    scan = project.scan()
    sessions = {e.key["session_id"]: e for e in project.entities("session", scan)}
    assert sorted(sessions) == ["m110-001", "m110-002", "m111-001"]
    first = sessions["m110-001"]
    assert first.row is not None and first.row["description"] == "Good" and first.row["NumRois"] == 120
    assert str(first.attributes["session_date"]) == "2025-05-23"
    assert sessions["m111-001"].row is None  # in the stores, not in the old table
    assert project.load(first, "SessionConfig") == {"zoom": 2}
    assert project.sync("session", scan) == [{"subject_id": "m111", "session_id": "m111-001"}]


def test_the_folder_must_be_empty(tmp_path):
    (tmp_path / "x.txt").write_text("")
    with pytest.raises(NansenError) as error:
        convert_legacy(json.loads(CASE.read_text()), tmp_path)
    assert error.value.code == "folder-not-empty"


def test_the_export_is_validated(tmp_path):
    with pytest.raises(NansenError) as error:
        convert_legacy({"schemaType": "nansen.legacyExport", "schemaVersion": "0.1.0"}, tmp_path / "p")
    assert error.value.code == "schema-validation"


def test_a_project_without_subject_ids_has_sessions_only():
    export = {"schemaType": "nansen.legacyExport", "schemaVersion": "0.1.0", "project": {"name": "Solo"},
              "dataLocations": [{"name": "Raw data", "rootPaths": [{"value": "/r"}],
                                 "subfolders": [{"type": "Other"}, {"type": "Other", "expression": "ses"}],
                                 "metadata": [{"variableName": "Session ID", "subfolderLevel": [2], "mode": "ind",
                                               "input": "4:end"}]}],
              "tables": [{"name": "Subjects", "entityClass": "subject", "columns": [], "rows": []}]}
    plan = plan_legacy(export)
    assert [t["name"] for t in plan["dataset"]["entityTypes"]] == ["session"]
    layout = plan["dataset"]["dataLocations"][0]["filesystemSource"]["entityLayout"]
    assert [lvl.get("entityType") for lvl in layout] == [None, "session"]  # the deepest level holds sessions
    assert plan["dataset"]["dataLocations"][0]["identifier"] == "raw_data"
    assert plan["dataset"]["dataLocations"][0]["filesystemSource"]["metadataMapping"] == [
        {"metadataRef": "session_id", "extraction": {"method": "substring", "pattern": "3:", "entityLayoutLevel": "level2"}}]
    assert plan["warnings"] == ["table 'Subjects': the dataset has no subject entity type; left out"]
    assert [(t["entityType"], t["fragments"], t["rows"]) for t in plan["tables"]] == [("session", ["core.notes"], [])]


def test_devs_column_layout_and_table_variables_come_with_the_tables(tmp_path):
    report = convert_legacy(json.loads(CASE.read_text()), tmp_path / "project")
    assert report["methods"][-1] == "num_rois"
    project = Project.open(tmp_path / "project")
    views = project.views("session").list()
    assert [v["name"] for v in views] == ["Sessions", "Sessions (curated)"]
    whole, curated = views
    assert "keys" not in whole and not whole.get("default") and curated["default"]   # dev opened the curated table first
    assert whole["hiddenColumns"] == ["Time", "ignore", "Quality"] == curated["hiddenColumns"]
    assert whole["columnOrder"][:3] == ["session_id", "subject_id", "session_date"]
    assert whole["columnWidths"]["description"] == 240 and "Reviewed" not in whole["columnWidths"]
    assert whole["filters"] == [{"column": "ignore", "op": "is", "value": False}]   # ShowIgnoredEntries false
    columns = {c["name"]: c for c in project.fragment("legacy.session").document["columns"]}
    assert columns["Reviewed"]["title"] == "Reviewed?" and columns["Reviewed"]["default"] is True
    assert columns["Rig"]["choices"] == ["Rig A", "Rig B", "Rig C"]   # dev's LIST_ALTERNATIVES, and a value the table has
    assert columns["Stage"] == {"name": "Stage", "dataType": "string", "choices": ["none", "trained", "expert"]}
    # dev's table variable function: a computed column, keeping dev's values, filled by a method calling dev's code
    computed = project.fragment("num_rois").document
    assert computed["compute"] == {"method": "num_rois"} and computed["columns"][0]["title"] == "ROIs"
    rows = {r["session_id"]: r for r in project.table("session").to_json_rows()}
    assert rows["m110-001"]["NumRois"] == 120
    assert project.method("num_rois").document["implementations"] == {"matlab": "num_rois"}
    value = (tmp_path / "project" / "matlab" / "num_rois_value.m").read_text()
    assert value.startswith("function numRois = num_rois_value(sessionObject)")
    assert 'result = struct("NumRois", {value});' in (tmp_path / "project" / "matlab" / "num_rois.m").read_text()


def test_without_a_column_layout_the_tables_get_no_view_of_their_own():
    export = json.loads(CASE.read_text())
    del export["columnSettings"]
    export["settings"]["MetadataTable"]["ShowIgnoredEntries"] = True
    tables = {t["entityType"]: t for t in plan_legacy(export)["tables"]}
    assert "views" not in tables["subject"]
    assert [v["name"] for v in tables["session"]["views"]] == ["Sessions (curated)"]


def test_regular_expressions_with_groups_keep_the_whole_match():
    export = {"schemaType": "nansen.legacyExport", "schemaVersion": "0.1.0", "project": {"name": "G"},
              "dataLocations": [{"name": "raw", "rootPaths": [{"value": "/r"}], "subfolders": [{"type": "Session"}],
                                 "metadata": [{"variableName": "Session ID", "subfolderLevel": [1], "mode": "expr",
                                               "input": "m(\\d+)-\\d+"}]}]}
    rule = plan_legacy(export)["dataset"]["dataLocations"][0]["filesystemSource"]["metadataMapping"][0]
    assert rule["extraction"]["pattern"] == "(m(\\d+)-\\d+)"


def test_cli(tmp_path, capsys):
    raw, processed = tmp_path / "raw", tmp_path / "processed"
    raw.mkdir(), processed.mkdir()
    export = tmp_path / "export.json"
    export.write_text(json.dumps(export_for(raw, processed)))
    assert main(["import-legacy", str(export), str(tmp_path / "project")]) == 0
    out = capsys.readouterr().out
    # dev's ROI, signal and binary stack variables too, and those read by the project's own file adapters (also those
    # built on dev's); the method of a table variable's computed column
    assert "2 subject(s), 2 session(s), 11 data variable(s), 4 file adapter(s), 3 method(s), 6 preset(s), " \
           "3 queued task(s) on hold, 2 completed run(s)" in out
    assert '"saveToDataFolders": true' in out
    assert "note: variable 'MotionCorrected'" not in out
