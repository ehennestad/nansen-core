"""Modules, methods, options, presets and computed fragments."""

import csv
import json
from pathlib import Path

import pytest

from nansen import NansenError, Project
from nansen.methods import Cancelled, MethodContext

DATASET = json.loads((Path(__file__).resolve().parents[2] / "testdata" / "entities-dataset.dsm.json").read_text())


@pytest.fixture
def project(tmp_path):
    (tmp_path / "dataset.dsm.json").write_text(json.dumps(DATASET))
    for path, size in [("sub-m1/ses-m1-001/movie.tif", 10), ("sub-m1/ses-m1-001/.hidden", 5),
                       ("sub-m1/ses-m1-002/movie.tif", 20), ("sub-m2/ses-m2-001/notes.txt", 1)]:
        target = tmp_path / "data" / "raw" / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"x" * size)
    project = Project.create(tmp_path, "Pilot", dataset="dataset.dsm.json")
    project.add_module("core")
    project.add_entity_type("subject", fragments=["core.notes"])
    project.add_entity_type("session", fragments=["core.notes", "core.file_stats"])
    project.scan()
    project.sync("subject")
    project.sync("session")
    return project


def sessions(project):
    return project.entities("session")


def test_module_fragments_shape_the_table(project):
    names = project.table("session").spec.column_names
    assert names == ["subject_id", "session_id", "ignore", "description", "n_files", "size_mb"]
    assert {f.id for f in project.fragments()} >= {"core.notes", "core.file_stats"}


def test_methods_apply_to_any_entity_type(project):
    assert {m.id for m in project.methods("session")} == {"core.file_stats", "core.export_keys", "core.wait"}
    assert project.method("core.wait").languages == ["matlab", "python"]


def test_default_options_and_validation(project):
    method = project.method("core.wait")
    assert method.default_options() == {"seconds": 2, "steps": 10, "message": "waiting", "fail": False}
    assert method.resolve_options({"seconds": 0})["steps"] == 10
    with pytest.raises(NansenError) as error:
        method.resolve_options({"seconds": -1})
    assert error.value.code == "invalid-options"


def test_presets(project):
    project.save_preset("core.wait", "quick", {"seconds": 0, "steps": 1}, "No waiting")
    names = [p["name"] for p in project.presets("core.wait")]
    assert names == ["default", "quick"]
    assert project.preset("core.wait", "quick")["seconds"] == 0
    with pytest.raises(NansenError):
        project.save_preset("core.wait", "default", {})
    with pytest.raises(NansenError):
        project.save_preset("core.wait", "broken", {"steps": 0})
    project.delete_preset("core.wait", "quick")
    assert [p["name"] for p in project.presets("core.wait")] == ["default"]


def test_run_serial_with_progress_and_log(project):
    seen = []
    context = MethodContext(on_progress=lambda f, m: seen.append(round(f, 2)))
    results = project.run("core.wait", sessions(project), {"seconds": 0, "steps": 2}, context=context)
    assert [r["waited"] for r in results] == [0, 0, 0]
    assert seen[-1] == 1.0
    assert len(context.lines) == 3


def test_run_batch(project):
    result = project.run("core.export_keys", sessions(project)[:2], {"fileName": "two.csv"})[0]
    with open(result["path"], newline="") as f:
        rows = list(csv.reader(f))
    assert rows == [["subject_id", "session_id"], ["m1", "m1-001"], ["m1", "m1-002"]]


def test_cancel_stops_before_the_next_entity(project):
    context = MethodContext()
    context.cancel()
    with pytest.raises(Cancelled):
        project.run("core.wait", sessions(project), {"seconds": 0, "steps": 1}, context=context)


def test_wrong_entity_type_is_refused(project, tmp_path):
    (project.folder / "methods").mkdir()
    (project.folder / "methods" / "only_subjects.method.nansen.json").write_text(json.dumps({
        "schemaType": "nansen.method", "schemaVersion": "0.1.0", "id": "lab.only_subjects", "version": "1.0.0",
        "entityType": "subject", "implementations": {"python": "lab:noop"}}))
    with pytest.raises(NansenError) as error:
        project.run("lab.only_subjects", sessions(project))
    assert error.value.code == "wrong-entity-type"


def test_project_method_with_project_code(project):
    (project.folder / "methods").mkdir()
    (project.folder / "python").mkdir()
    (project.folder / "python" / "lab.py").write_text("def double(entity, options, context):\n    return options['x'] * 2\n")
    (project.folder / "methods" / "double.method.nansen.json").write_text(json.dumps({
        "schemaType": "nansen.method", "schemaVersion": "0.1.0", "id": "lab.double", "version": "1.0.0",
        "entityType": "session", "implementations": {"python": "lab:double"},
        "options": {"type": "object", "properties": {"x": {"type": "integer", "default": 21}}}}))
    assert Project.open(project.folder).run("lab.double", sessions(project)[:1]) == [42]


def test_update_computed_fragment(project):
    summary = project.update_fragment("session", "core.file_stats")
    assert summary == {"updated": 3, "failed": []}
    stats = {e.key["session_id"]: (e.row["n_files"], e.row["size_mb"]) for e in sessions(project)}
    assert stats == {"m1-001": (1, 1e-05), "m1-002": (1, 2e-05), "m2-001": (1, 1e-06)}


def test_update_only_some_keys(project):
    project.update_fragment("session", "core.file_stats", keys=[{"subject_id": "m1", "session_id": "m1-002"}])
    filled = [e.key["session_id"] for e in sessions(project) if e.row["n_files"] is not None]
    assert filled == ["m1-002"]


def test_fragments_without_compute_cannot_be_updated(project):
    with pytest.raises(NansenError) as error:
        project.update_fragment("session", "core.notes")
    assert error.value.code == "not-computed"


def test_unknown_module(project):
    with pytest.raises(NansenError) as error:
        project.add_module("nope")
    assert error.value.code == "unknown-module"


def test_built_in_option_schemas_stay_within_the_matlab_validator():
    from nansen.modules import Module, built_in_modules_dir

    from test_schemas import MATLAB_KEYWORDS, keywords

    for folder in sorted(built_in_modules_dir().iterdir()):
        for method in Module.read(folder).methods():
            assert keywords(method.options_schema, set()) <= MATLAB_KEYWORDS, method.id
