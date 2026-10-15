"""NANSEN dev's session methods imported as project methods: reading their files, the method documents, the import."""

import json
from pathlib import Path, PurePosixPath

import pytest

from nansen import NansenError, Project
from nansen.documents import check_document
from nansen.legacymethods import analyze, function_name, label, literal, plan, snake

REPO = Path(__file__).resolve().parents[2]
DATASET = json.loads((REPO / "testdata" / "entities-dataset.dsm.json").read_text())
DEV = REPO / "conformance" / "api" / "legacy-methods" / "data" / "+lab" / "+sessionmethod"

FUNCTION = '''function varargout = measure(sessionObject, varargin)
%MEASURE Measure something.
    params = getDefaultParameters();
    params.Inline = 'set here'; % set in the function itself
    ATTRIBUTES = {'batch', 'unqueueable', 'MethodName', 'Measure it'};
    S = nansen.session.SessionMethod.setAttributes(params, ATTRIBUTES{:});
    params.After = 1;   % after setAttributes: not a default
end

function P = getDefaultParameters()
    P = struct();
    P.Threshold = -1.5e-2;      % how low; it's 100% "sure"
    P.Count = +3
    P.Name = 'it''s';
    P.Quoted = "say ""hi""";
    P.Row = [1 2.5, 3];
    P.One = [7];
    P.Empty = [];
    P.Names = {'a' , "b"};
    P.NoNames = {};
    P.Flag = true;
    P.Mode = 'fast';
    P.Mode_ = {'fast', 'slow'};
    P.Other = 'x';
    P.Other_ = {'y', 'z'};
    P.Sub.Deep.Value = 2;
    P.Sub.Gone = 1;
    P.Sub.Gone = getenv('HOME');
    P.Computed = numel(x');
    P.Transposed = x'; % 'not a string
    P.Matrix = [1, 2; 3, 4];
end
'''


def test_a_function_method_reads_attributes_and_plain_defaults():
    info = analyze("measure", FUNCTION)
    assert info["kind"] == "function"
    assert info["title"] == "Measure it"
    assert info["description"] == "Measure something."
    assert info["batchMode"] == "batch" and info["queueable"] is False
    properties = info["options"]["properties"]
    assert list(properties) == ["Threshold", "Count", "Name", "Quoted", "Row", "One", "Names", "NoNames", "Flag", "Mode",
                                "Other", "Sub", "Inline"]
    assert properties["Threshold"] == {"type": "number", "default": -1.5e-2, "description": "how low; it's 100% \"sure\""}
    assert properties["Count"] == {"type": "number", "default": 3}
    assert properties["Name"]["default"] == "it's"
    assert properties["Quoted"]["default"] == 'say "hi"'
    assert properties["Row"] == {"type": "array", "items": {"type": "number"}, "default": [1, 2.5, 3]}
    assert properties["One"] == {"type": "number", "default": 7}
    assert properties["Names"] == {"type": "array", "items": {"type": "string"}, "default": ["a", "b"]}
    assert properties["NoNames"]["default"] == []
    assert properties["Mode"]["enum"] == ["fast", "slow"]
    assert "enum" not in properties["Other"]   # its default is not among the choices
    assert properties["Sub"] == {"type": "object", "properties": {
        "Deep": {"type": "object", "properties": {"Value": {"type": "number", "default": 2}}}}}
    assert properties["Inline"]["description"] == "set in the function itself"


def test_a_class_method_reads_its_constants_and_get_default_options():
    info = analyze("SummarizeSessions", (DEV / "+plot" / "SummarizeSessions.m").read_text())
    assert (info["kind"], info["title"], info["batchMode"], info["queueable"]) == ("class", "Summarize sessions", "batch", False)
    assert info["description"] == "Write a line about each session, all of them at once."
    assert info["options"]["properties"]["Mode"] == {"type": "string", "default": "short", "enum": ["short", "long"]}


@pytest.mark.parametrize("text, reason", [
    ("% only a comment\n", "holds no code"),
    ("x = 1;\n", "is a script"),
    ("function y = f(x)\n    y = x;\nend\n", "does not call nansen.session.SessionMethod.setAttributes"),
    ("classdef f < handle\nend\n", "does not subclass nansen.session.SessionMethod"),
    ("classdef f < nansen.processing.MotionCorrection & nansen.session.SessionMethod\nend\n",
     "also subclasses nansen.processing.MotionCorrection"),
])
def test_files_that_are_not_session_methods(text, reason):
    with pytest.raises(NansenError) as error:
        analyze("f", text)
    assert error.value.code == "unsupported-file" and reason in error.value.message


def test_a_commented_out_attribute_is_not_read():
    text = FUNCTION.replace("ATTRIBUTES = {'batch', 'unqueueable', 'MethodName', 'Measure it'};",
                            "% ATTRIBUTES = {'batch'};\n    ATTRIBUTES = {'serial'};")
    info = analyze("measure", text)
    assert (info["batchMode"], info["queueable"], info["title"]) == ("serial", True, "Measure")


def test_names_literals_and_function_names():
    assert snake("plotImageStats") == "plot_image_stats" and snake("EXTRACT") == "extract"
    assert snake("DownsampleStack") == "downsample_stack" and snake("ABCDef") == "abc_def"
    assert label("plotImageStats") == "Plot Image Stats" and label("motionCorrection") == "Motion Correction"
    assert literal("[1, 2; 3, 4]") == (False, None) and literal("1e3;") == (True, 1000.0)
    assert function_name(PurePosixPath("code/+RatNav/+sessionmethod/+process/x.m")) == "RatNav.sessionmethod.process.x"
    assert function_name(PurePosixPath("/a/+b/c/d.m")) == "d"


def test_plan_makes_unique_ids_and_valid_documents():
    text = (DEV / "+process" / "countFiles.m").read_text()
    entries, warnings = plan([("one", "lab.sessionmethod.process.countFiles", text),
                              ("two", "lab.sessionmethod.plot.countFiles", text),
                              ("three", "helper", "function x = helper(x)\nend\n")], "session", ["legacy.count_files"])
    assert [e["document"]["id"] for e in entries] == ["legacy.count_files_2", "legacy.count_files_3"]
    assert [e["file"] for e in entries] == ["+lab/+sessionmethod/+process/countFiles.m", "+lab/+sessionmethod/+plot/countFiles.m"]
    assert entries[1]["document"]["category"] == "Plot"
    assert warnings == ["session method three: helper.m does not call nansen.session.SessionMethod.setAttributes, "
                        "so it is not a dev session method; left out"]


def test_the_schema_needs_a_matlab_implementation_for_a_legacy_method():
    document = {"schemaType": "nansen.method", "schemaVersion": "0.1.0", "id": "legacy.x", "version": "1.0.0",
                "entityType": "session", "implementations": {"matlab": "x"}, "legacySessionMethod": {"kind": "function"}}
    check_document(document, "nansen.method")
    for broken in ({"implementations": {"python": "x:run"}}, {"legacySessionMethod": {"kind": "script"}},
                   {"legacySessionMethod": {}}, {"legacySessionMethod": {"kind": "class", "extra": 1}}):
        with pytest.raises(NansenError) as error:
            check_document(dict(document, **broken), "nansen.method")
        assert error.value.code == "schema-validation"


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


def test_import_a_folder_of_dev_methods(project):
    result = project.import_legacy_methods(DEV)
    assert [m["id"] for m in result["methods"]] == ["legacy.summarize_sessions", "legacy.count_files"]
    assert all(m["legacy"] and m["languages"] == ["matlab"] and m["entityType"] == "session" for m in result["methods"])
    assert len(result["warnings"]) == 1 and result["warnings"][0].startswith("session method helper.m: ")
    code = project.folder / "matlab" / "+lab" / "+sessionmethod" / "+process" / "countFiles.m"
    assert code.read_text() == (DEV / "+process" / "countFiles.m").read_text()
    method = project.method("legacy.count_files")
    assert method.is_legacy and method.source_files() == {"matlab": code}
    assert method.document["implementations"] == {"matlab": "lab.sessionmethod.process.countFiles"}
    assert method.default_options()["Window"] == [1, 10]
    with pytest.raises(NansenError) as error:   # Python runs it in a MATLAB worker, never here
        project.run("legacy.count_files", project.entities("session"))
    assert error.value.code == "method-unavailable"
    with pytest.raises(NansenError) as error:
        project.import_legacy_methods(DEV / "+process" / "countFiles.m")
    assert error.value.code == "method-exists"


def test_import_one_file_by_a_relative_path_for_any_entity_type(project):
    target = project.folder / "dev" / "countFiles.m"
    target.parent.mkdir()
    target.write_text((DEV / "+process" / "countFiles.m").read_text())
    result = project.import_legacy_methods("dev/countFiles.m", "*")
    assert result["warnings"] == [] and result["methods"][0]["entityType"] == "*"
    assert "category" not in project.method("legacy.count_files").document   # not in a +sessionmethod package
    assert (project.folder / "matlab" / "countFiles.m").is_file()
    with pytest.raises(NansenError) as error:
        project.import_legacy_methods(DEV, "probe")
    assert error.value.code == "unknown-entity-type"
    with pytest.raises(NansenError) as error:
        project.import_legacy_methods(project.folder / "dev")   # holds only countFiles.m, which is taken
    assert error.value.code == "method-exists"
    (project.folder / "empty").mkdir()
    with pytest.raises(NansenError) as error:
        project.import_legacy_methods(project.folder / "empty")
    assert error.value.code == "unsupported-file"


def test_the_api_imports_and_lists_them(project):
    from nansen.api import Api

    api = Api()
    assert api.handle({"id": 1, "method": "project.open", "params": {"path": str(project.folder)}})["result"]
    result = api.handle({"id": 2, "method": "methods.importLegacy", "params": {"path": str(DEV / "+plot"), "entityType": ""}})["result"]
    assert [m["id"] for m in result["methods"]] == ["legacy.summarize_sessions"]
    listed = api.handle({"id": 3, "method": "methods.list", "params": {"entityType": "session"}})["result"]
    assert [m.get("legacy", False) for m in listed][:2] == [True, False]
    assert api.handle({"id": 4, "method": "methods.importLegacy", "params": {}})["error"]["code"] == "invalid-params"
