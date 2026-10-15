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
    assert {m.id for m in project.methods("session")} == {"core.file_stats", "core.export_keys", "core.wait", "core.backup"}
    assert project.method("core.wait").languages == ["matlab", "python"]


def test_backup_copies_only_what_changed(project):
    entities = sessions(project)[:2]
    results = project.run("core.backup", entities, options={"destination": "backup"})
    assert [r["copied"] for r in results] == [2, 1]  # ses-m1-001 has a hidden file too
    copy = project.folder / "backup" / "raw" / "sub-m1" / "ses-m1-001" / "movie.tif"
    assert copy.read_bytes() == b"x" * 10
    results = project.run("core.backup", entities, options={"destination": "backup"})
    assert [(r["copied"], r["unchanged"]) for r in results] == [(0, 2), (0, 1)]
    (project.folder / "data" / "raw" / "sub-m1" / "ses-m1-001" / "movie.tif").write_bytes(b"y" * 12)
    assert project.run("core.backup", entities[:1], options={"destination": "backup"})[0]["copied"] == 1
    assert copy.read_bytes() == b"y" * 12
    assert project.run("core.backup", entities[:1], options={"destination": "backup", "overwrite": True})[0]["copied"] == 2
    with pytest.raises(NansenError) as error:
        project.run("core.backup", entities[:1])  # no destination
    assert error.value.code == "invalid-options"
    with pytest.raises(ValueError):
        project.run("core.backup", entities[:1], options={"destination": str(project.folder / "data" / "raw" / "sub-m1" / "ses-m1-001" / "b")})


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


def test_a_method_started_from_the_templates_runs_and_is_reloaded_when_edited(project):
    method = project.create_method("count_frames", "Count frames", "session", "Counts the frames.")
    assert method.languages == ["matlab", "python"]
    code = project.folder / "python" / "count_frames.py"
    assert (project.folder / "matlab" / "count_frames.m").read_text().startswith("function result = count_frames(entity, options, context)")
    assert project.run("count_frames", sessions(project)[:1]) == [{}]
    code.write_text(code.read_text().replace("return {}", "return {'frames': 42}  # edited"))
    assert project.run("count_frames", sessions(project)[:1]) == [{"frames": 42}]
    assert not (project.folder / "python" / "__pycache__").exists()
    with pytest.raises(NansenError) as error:
        project.create_method("count_frames", "Again")
    assert error.value.code == "method-exists"
    batch = project.create_method("summarize", "", batch_mode="batch", languages=["python"])
    assert (batch.title, batch.batch_mode, batch.languages) == ("summarize", "batch", ["python"])
    assert "def run(entities, options, context):" in (project.folder / "python" / "summarize.py").read_text()


CASES = Path(__file__).resolve().parents[2] / "conformance" / "api"


def test_a_column_imported_from_a_python_method_is_computed(project):
    imported = project.import_column("session", CASES / "column-import" / "data" / "rebuild" / "frame_rate.py", title="Frame rate")
    assert imported["files"] == ["fragments/frame_rate.fragment.nansen.json", "methods/frame_rate.method.nansen.json", "python/frame_rate.py"]
    assert project.update_fragment("session", "frame_rate") == {"updated": 3, "failed": []}
    assert {e.key["session_id"]: e.row["frame_rate"] for e in sessions(project)} == {"m1-001": 30.0, "m1-002": 15.0, "m2-001": 30.0}


def test_columns_imported_from_dev_table_variables(project, tmp_path):
    dev = CASES / "column-import" / "data" / "dev"
    imported = project.import_column("session", dev / "numFrames.m")
    assert imported["method"].languages == ["matlab"] and imported["fragment"].document["compute"] == {"method": "num_frames"}
    wrapper = (project.folder / "matlab" / "num_frames.m").read_text()
    assert wrapper.startswith("function result = num_frames(entity, options, context)")
    assert "value = num_frames_value(entity);" in wrapper and 'result = struct("numFrames", {value});' in wrapper
    copied = (project.folder / "matlab" / "num_frames_value.m").read_text()
    assert copied == (dev / "numFrames.m").read_text().replace("function value = numFrames(", "function value = num_frames_value(", 1)
    quality = project.import_column("session", dev / "Quality.m")["fragment"].document
    assert quality["columns"] == [{"name": "Quality", "dataType": "string", "choices": ["good", "fair", "poor"]}] and "compute" not in quality
    assert [e.row["Quality"] for e in sessions(project)] == [None, None, None]   # typed in
    reviewed = project.import_column("subject", dev / "Reviewed.m")["fragment"].document["columns"]
    assert reviewed == [{"name": "Reviewed", "dataType": "boolean", "default": False}]
    # a function with CRLF line ends, its default a datetime, named in camel case with an abbreviation
    (tmp_path / "recordedAtUTC.m").write_bytes(b"function value = recordedAtUTC(sessionObject)\r\n    value = NaT;\r\n"
                                               b"    if nargin < 1; return; end\r\nend\r\n")
    imported = project.import_column("session", tmp_path / "recordedAtUTC.m")
    assert imported["fragment"].id == "recorded_at_utc" and imported["fragment"].document["columns"][0]["dataType"] == "datetime"
    assert b"\r" not in (project.folder / "matlab" / "recorded_at_utc_value.m").read_bytes()


def test_adapters_imported_with_their_code_read_files(project, tmp_path):
    data = CASES / "adapter-import" / "data"
    result = project.import_adapter(data / "single" / "thing.fileAdapter.nansen.json")
    assert [a["id"] for a in result["adapters"]] == ["thing"]
    (tmp_path / "a.thing").write_text("one two three")
    assert project.adapters.get("thing").read(tmp_path / "a.thing") == ["one", "two", "three"]
    project.import_adapter(data / "bundle")
    (tmp_path / "rows.txt").write_text("1 2 3\n4 5 6\n")
    assert project.adapters.get("three").read(tmp_path / "rows.txt") == [["1", "2", "3"], ["4", "5", "6"]]
    assert project.adapters.get("lab_two").read(tmp_path / "rows.txt") == [["1", "2"], ["4", "5"]]
    # a folder whose second adapter cannot be imported: nothing of it is copied
    mixed = tmp_path / "mixed"
    (mixed / "python").mkdir(parents=True)
    for name, module in (("alpha", "alpha_reader:AlphaReader"), ("beta", "beta_reader:BetaReader")):
        (mixed / f"{name}.fileAdapter.nansen.json").write_text(json.dumps({
            "schemaType": "nansen.fileAdapter", "schemaVersion": "0.1.0", "id": name, "version": "1.0.0",
            "implementations": {"python": module}}))
    code = "class AlphaReader:\n    def read(self, path):\n        return 1\n\n    def write(self, path, data):\n        pass\n"
    (mixed / "python" / "alpha_reader.py").write_text(code)
    with pytest.raises(NansenError) as error:
        project.import_adapter(mixed)
    assert error.value.code == "file-not-found"
    assert not (project.folder / "python" / "alpha_reader.py").exists() and "alpha" not in project.adapters.ids
    (mixed / "python" / "beta_reader.py").write_text(code.replace("Alpha", "Beta"))
    assert [a["id"] for a in project.import_adapter(mixed)["adapters"]] == ["alpha", "beta"]
    # other code where an adapter's would be copied is a clash
    again = tmp_path / "again"
    again.mkdir()
    (again / "gamma.fileAdapter.nansen.json").write_text(json.dumps({
        "schemaType": "nansen.fileAdapter", "schemaVersion": "0.1.0", "id": "gamma", "version": "1.0.0",
        "implementations": {"python": "alpha_reader:AlphaReader"}}))
    (again / "alpha_reader.py").write_text(code.replace("return 1", "return 2"))
    with pytest.raises(NansenError) as error:
        project.import_adapter(again)
    assert error.value.code == "adapter-exists"
