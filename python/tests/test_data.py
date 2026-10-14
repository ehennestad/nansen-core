"""Data variables and file adapters on a real folder."""

import json
from pathlib import Path

import pytest

from nansen import NansenError, Project

DATASET = json.loads((Path(__file__).resolve().parents[2] / "testdata" / "entities-dataset.dsm.json").read_text())


def variable(name, **fields):
    return dict({"schemaType": "nansen.dataVariable", "schemaVersion": "0.1.0", "name": name,
                 "entityType": "session"}, **fields)


@pytest.fixture
def project(tmp_path):
    (tmp_path / "dataset.dsm.json").write_text(json.dumps(DATASET))
    for path in ["sub-m1/ses-m1-001/movie.tif", "sub-m2/ses-m2-001/notes.txt"]:
        target = tmp_path / "data" / "raw" / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("frames")
    (tmp_path / "data" / "processed" / "m1" / "m1-001").mkdir(parents=True)
    project = Project.create(tmp_path, "Pilot", dataset="dataset.dsm.json")
    project.add_entity_type("subject")
    project.add_entity_type("session")
    project.add_data_variable(variable("movie", dataLocation="raw", filePattern="movie", fileAdapter="text"))
    project.add_data_variable(variable("rois", dataLocation="processed", filePattern="roi_signals",
                                       fileName="{session_id}_roi.json", fileAdapter="json"))
    project.add_data_variable(variable("summary", dataLocation="processed", subfolder="qc",
                                       fileName="summary.json", fileAdapter="json"))
    project.scan()
    return project


def session(project, session_id):
    return project.entity("session", {"session_id": session_id})


def test_read_through_the_file_pattern(project):
    assert session(project, "m1-001").load("movie") == "frames"
    with pytest.raises(NansenError) as error:
        session(project, "m2-001").load("movie")
    assert error.value.code == "data-not-found"


def test_write_then_read_back_after_a_scan(project):
    path = session(project, "m1-001").save("rois", {"n": 3})
    assert path == project.folder / "data" / "processed" / "m1" / "m1-001" / "m1-001_roi.json"
    project.scan()
    assert session(project, "m1-001").load("rois") == {"n": 3}


def test_write_generates_the_entity_folder(project):
    path = session(project, "m2-001").save("rois", [1, 2])
    assert path == project.folder / "data" / "processed" / "m2" / "m2-001" / "m2-001_roi.json"


def test_variable_without_pattern_uses_its_file_name(project):
    entity = session(project, "m1-001")
    entity.save("summary", {"ok": True})
    assert entity.load("summary") == {"ok": True}
    assert project.read_targets(entity, "summary") == [("processed", "m1/m1-001/qc/summary.json")]


def test_data_status(project):
    entity = session(project, "m1-001")
    entity.save("summary", {})
    status = {s["name"]: bool(s["files"]) for s in project.data_status(entity)}
    assert status == {"movie": True, "rois": False, "summary": True}


def test_file_name_must_match_the_pattern(project):
    project.add_data_variable(variable("bad", dataLocation="processed", filePattern="roi_signals",
                                       fileName="{session_id}.json", fileAdapter="json"))
    with pytest.raises(NansenError) as error:
        session(project, "m1-001").save("bad", {})
    assert error.value.code == "file-name-mismatch"


def test_reading_only_variable_cannot_be_written(project):
    with pytest.raises(NansenError) as error:
        session(project, "m1-001").save("movie", "x")
    assert error.value.code == "no-file-name"


@pytest.mark.parametrize("fields,code", [
    ({"dataLocation": "processed", "fileName": "x.json", "fileAdapter": "nope"}, "unknown-file-adapter"),
    ({"dataLocation": "archive", "fileName": "x.json", "fileAdapter": "json"}, "unknown-location"),
    ({"dataLocation": "processed", "filePattern": "nope", "fileAdapter": "json"}, "unknown-file-pattern"),
    ({"dataLocation": "processed", "fileAdapter": "json"}, "schema-validation"),
])
def test_invalid_variables_are_refused(project, fields, code):
    with pytest.raises(NansenError) as error:
        project.add_data_variable(variable("x", **fields))
    assert error.value.code == code


def test_declared_adapter_is_loaded_from_the_project(project):
    folder = project.folder / "file-adapters"
    folder.mkdir()
    (project.folder / "python").mkdir()
    (project.folder / "python" / "upper.py").write_text(
        "class Upper:\n"
        "    def read(self, path):\n        return open(path).read().upper()\n"
        "    def write(self, path, data):\n        open(path, 'w').write(str(data))\n")
    (folder / "upper.fileAdapter.nansen.json").write_text(json.dumps({
        "schemaType": "nansen.fileAdapter", "schemaVersion": "0.1.0", "id": "lab.upper", "version": "1.0.0",
        "extensions": [".txt"], "implementations": {"python": "upper:Upper"}}))
    reopened = Project.open(project.folder)
    reopened.add_data_variable(variable("shout", dataLocation="raw", filePattern="movie", fileAdapter="lab.upper"))
    assert session(reopened, "m1-001").load("shout") == "FRAMES"
    assert "lab.upper" in reopened.adapters.ids


def test_mat_adapter_round_trip(project):
    pytest.importorskip("scipy")
    project.add_data_variable(variable("traces", dataLocation="processed", fileName="{session_id}_traces.mat",
                                       fileAdapter="mat"))
    entity = session(project, "m1-001")
    entity.save("traces", {"dff": [1.0, 2.0, 3.0]})
    assert list(entity.load("traces")["dff"]) == [1.0, 2.0, 3.0]


# -- the data cache ---------------------------------------------------------------------------

def test_load_is_cached_until_the_file_changes(project):
    entity = session(project, "m1-001")
    project.save(entity, "summary", {"cells": [1, 2]})
    project.data_cache.clear()
    first = project.load(entity, "summary")
    first["cells"].append(3)  # what a caller is given is its own copy
    assert project.load(entity, "summary") == {"cells": [1, 2]}
    assert project.data_cache.stats()["hits"] == 1
    path = project.data_paths(entity, "summary")[0]
    path.write_text(json.dumps({"cells": [7, 8, 9]}))  # changed on disk, not through save
    assert project.load(entity, "summary") == {"cells": [7, 8, 9]}
    project.save(entity, "summary", {"cells": []})  # save drops the entry, whatever the clock says
    assert project.load(entity, "summary") == {"cells": []}
    assert project.load(entity, "summary", cached=False) == {"cells": []}


def test_cache_keeps_within_its_budget():
    from nansen.cache import DataCache, size_of

    cache = DataCache(max_bytes=size_of("x" * 100) * 2)
    for key in "abc":
        assert cache.get_or_load(key, 1, lambda: "x" * 100) == "x" * 100
    stats = cache.stats()
    assert (stats["entries"], stats["evictions"]) == (2, 1)
    loads = []
    cache.get_or_load("a", 1, lambda: loads.append("a") or "x" * 100)  # "a" was the least recently used
    assert loads == ["a"]
    cache.get_or_load("huge", 1, lambda: "y" * 1000)  # bigger than the budget: given, not kept
    assert cache.stats()["entries"] == 2


def test_cached_arrays_are_read_only():
    np = pytest.importorskip("numpy")
    from nansen.cache import DataCache

    cache = DataCache()
    array = cache.get_or_load("m", 1, lambda: {"frames": np.zeros(4)})["frames"]
    with pytest.raises(ValueError):
        array[0] = 1
    assert cache.get_or_load("m", 1, lambda: None)["frames"] is array
