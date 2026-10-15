"""NANSEN dev's file adapters imported as project file adapters: reading their files, the documents, the import, and
that only MATLAB reads with them."""

import json
from pathlib import Path

import pytest

from nansen import NansenError, Project
from nansen.legacyadapters import analyze_class, analyze_function, extensions_of, plan

REPO = Path(__file__).resolve().parents[2]
DATASET = json.loads((REPO / "testdata" / "entities-dataset.dsm.json").read_text())
DEV = REPO / "conformance" / "api" / "legacy-adapters" / "data"

CLASS = """classdef (Sealed) Trace < handle & nansen.dataio.FileAdapter % a comment
%TRACE A trace.

    properties (Constant)
        DataType = "double"
        % Description = 'commented out'
    end

    properties (Constant, Hidden, Access = protected)
        SUPPORTED_FILE_TYPES = {'trc', '.TRC', 'trc', 'no good'};
    end
end
"""


def test_a_class_adapter_reads_its_constants():
    info = analyze_class("Trace", CLASS)
    assert info == {"title": "Trace", "description": "A trace.", "extensions": [".trc", ".TRC"], "dataType": "double"}


@pytest.mark.parametrize("text, reason", [
    ("function data = read(f)\nend\n", "is not a class"),
    ("% only comments\n", "holds no code"),
    ("classdef Trace < handle\nend\n", "does not subclass nansen.dataio.FileAdapter"),
    ("classdef Trace < nansen.dataio.FileAdapter & nansen.dataio.fileadapter.imagestack.ImageStack\nend\n",
     "also subclasses nansen.dataio.fileadapter.imagestack.ImageStack"),
])
def test_files_that_are_not_class_adapters(text, reason):
    with pytest.raises(NansenError) as error:
        analyze_class("Trace", text)
    assert error.value.code == "unsupported-file" and reason in error.value.message


def test_a_function_adapter_reads_its_definition():
    definition = json.dumps({"_type": "FileAdapter", "Properties": {"Name": "Licks", "SupportedFileTypes": "lick",
                                                                   "DataType": "double", "ReadFunction": "load"}})
    info = analyze_function("lab.fileadapter.Licks", definition, ["fileadapter.json", "write.m"])
    assert info == {"title": "Licks", "description": "", "extensions": [".lick"], "dataType": "double",
                    "read": "load", "write": "lab.fileadapter.Licks.write"}
    for text, reason in [("{", "not valid JSON"), ('{"_type": "Other", "Properties": {}}', "not a dev file adapter"),
                         ('{"_type": "FileAdapter", "Properties": {}}', "no read function"),
                         ('{"_type": "FileAdapter", "Properties": {"ReadFunction": "@(f) load(f)"}}', "is not the name")]:
        with pytest.raises(NansenError) as error:
            analyze_function("lab.fileadapter.Licks", text, [])
        assert reason in error.value.message
    assert extensions_of(7) == [] and extensions_of(["a", 1, ".b.c"]) == [".a", ".b.c"]


def test_plan_groups_a_function_adapter_and_makes_unique_ids():
    sources = [("code/+P/+fileadapter/+Trace/fileadapter.json", json.dumps({"_type": "FileAdapter", "Properties": {"Name": "Trace"}})),
               ("code/+P/+fileadapter/+Trace/read.m", "function d = read(f)\nend\n"),
               ("code/+P/+fileadapter/Trace.m", CLASS),
               ("code/+P/+fileadapter/notes.txt", "not code"),
               ("Loose/fileadapter.json", json.dumps({"_type": "FileAdapter", "Properties": {"ReadFunction": "load"}}))]
    entries, warnings = plan(sources, taken=["legacy.trace"])
    assert [e["document"]["id"] for e in entries] == ["legacy.trace_2", "legacy.trace_3"]
    assert entries[0]["document"]["legacyFileAdapter"] == {"kind": "function", "read": "P.fileadapter.Trace.read"}
    assert entries[0]["files"] == [("+P/+fileadapter/+Trace/fileadapter.json", sources[0][1]),
                                   ("+P/+fileadapter/+Trace/read.m", sources[1][1])]
    assert entries[1]["document"]["implementations"] == {"matlab": "P.fileadapter.Trace"}
    assert warnings == ["file adapter Loose: its folder is not a package (+name); left out"]


@pytest.fixture
def project(tmp_path):
    (tmp_path / "dataset.dsm.json").write_text(json.dumps(DATASET))
    (tmp_path / "data" / "raw" / "sub-m1" / "ses-m1-001").mkdir(parents=True)
    project = Project.create(tmp_path, "Pilot", dataset="dataset.dsm.json")
    project.add_module("core")
    project.add_entity_type("subject", fragments=["core.notes"])
    project.add_entity_type("session", fragments=["core.notes"])
    project.scan()
    project.sync("subject")
    project.sync("session")
    return project


def test_an_imported_dev_adapter_is_read_by_matlab_only(project):
    result = project.import_adapter(DEV / "+lab" / "+fileadapter" / "SpeedTrace.m")
    assert result["adapters"][0]["files"] == ["file-adapters/legacy.speed_trace.fileAdapter.nansen.json",
                                              "matlab/+lab/+fileadapter/SpeedTrace.m"]
    assert project.adapters.describe("legacy.speed_trace")["languages"] == ["matlab"]
    project.add_data_variable({"schemaType": "nansen.dataVariable", "schemaVersion": "0.1.0", "name": "RunningSpeed",
                               "entityType": "session", "dataLocation": "processed", "fileName": "{session_id}_speed.speed",
                               "fileAdapter": "legacy.speed_trace"})
    session = project.entities("session", project.scan())[0]
    _, relative = project.write_target(session, "RunningSpeed")
    (project.folder / "data" / "processed" / relative).parent.mkdir(parents=True, exist_ok=True)
    (project.folder / "data" / "processed" / relative).write_text("1\n2\n")
    session = project.entities("session", project.scan())[0]
    with pytest.raises(NansenError) as error:   # dev's MATLAB code: MATLAB reads it (nansen.legacy.FileAdapterShim)
        project.load(session, "RunningSpeed")
    assert error.value.code == "adapter-unavailable"
    assert "lab.fileadapter.SpeedTrace" in error.value.message and "MATLAB" in error.value.message


def test_a_converted_document_imports_into_another_project_with_its_code(project, tmp_path):
    project.import_adapter(DEV / "+lab" / "+fileadapter" / "+LickLog")
    other_folder = tmp_path / "other"
    other_folder.mkdir()
    other = Project.create(other_folder, "Other")
    result = other.import_adapter(project.folder / "file-adapters" / "legacy.lick_log.fileAdapter.nansen.json")
    assert result["adapters"][0]["files"] == ["file-adapters/legacy.lick_log.fileAdapter.nansen.json",
                                              "matlab/+lab/+fileadapter/+LickLog"]
    assert (other_folder / "matlab" / "+lab" / "+fileadapter" / "+LickLog" / "read.m").is_file()


def test_legacy_import_brings_the_dev_projects_adapters_presets_tasks_and_progress(tmp_path):
    from nansen.legacy import convert_legacy

    export = json.loads((REPO / "conformance" / "legacy" / "two-photon" / "export.json").read_text())
    report = convert_legacy(export, tmp_path / "project")
    assert report["fileAdapters"] == ["legacy.lick_log", "legacy.speed_trace"]
    project = Project.open(tmp_path / "project")
    assert project.data_variable("RunningSpeed").document["fileAdapter"] == "legacy.speed_trace"
    assert project.preset("legacy.count_trials", "Strict")["MinDuration"] == 4
    assert project.preferred_preset("ophys.normcorre") == "thorough"
    from nansen.tasks import TaskQueue

    queue = TaskQueue(project)
    queued = sorted(queue.list("queued"), key=lambda t: t["order"])
    assert [t["method"]["id"] for t in queued] == ["legacy.count_trials", "ophys.normcorre", "legacy.count_trials"]
    assert all(t["onHold"] for t in queued) and queue.next_task() is None   # nothing runs until it is released
    assert queued[1]["options"]["preset"] == "rigid" and queued[1]["options"]["values"]["maxShift"] == 25
    progress = project.pipeline_progress("session")
    first = next(v for k, v in progress.items() if dict(k)["session_id"] == "m110-001")
    assert first["pipeline"] == "legacy.two_photon_preprocessing"
    assert [s["done"] for s in first["steps"]][:1] == [True]   # NoRMCorre, finished in dev
