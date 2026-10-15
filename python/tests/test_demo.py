"""The demo projects build, scan and have their tables filled; the ophys methods find the quickstart's cells."""

import json

import pytest

from nansen.demo import create_demo
from nansen.errors import NansenError


def test_demo_project(tmp_path):
    project = create_demo(tmp_path / "demo")
    assert project.title == "Two-photon demo"
    assert project.entity_types == ["subject", "session"]
    assert len(project.table("subject").rows) == 4
    sessions = project.table("session")
    assert len(sessions.rows) == 14
    assert all(row["n_files"] >= 1 for row in sessions.rows)
    assert all(e.record is not None and e.row is not None for e in project.entities("session"))
    assert [p["name"] for p in project.presets("core.wait")] == ["default", "quick"]


def test_two_photon_quickstart(tmp_path):
    np = pytest.importorskip("numpy")
    from nansen.demo import create_demo_kind, create_two_photon_demo

    project = create_two_photon_demo(tmp_path / "tutorial")
    assert project.title == "Two-photon quickstart"
    assert [m.id for m in project.modules] == ["core", "ophys"]
    assert len(project.table("subject").rows) == 2
    rows = project.table("session").rows
    assert [(r["subject_id"], r["session_id"]) for r in rows] == [("m1", "s1"), ("m1", "s2"), ("m2", "s1"), ("m2", "s2")]
    assert all(r["frame_rate"] == 31.25 and r["pixel_size_um"] == 2.0 for r in rows)
    stack = project.open_stack(project.entities("session")[0], "TwoPhotonSeries_Original")
    assert stack.shape == (64, 64, 300) and stack.dtype == np.uint16
    with pytest.raises(NansenError) as error:
        create_demo_kind(tmp_path / "other", "imaging")
    assert error.value.code == "invalid-params"


def test_the_ophys_pipeline_finds_the_quickstart_cells(tmp_path):
    np = pytest.importorskip("numpy")
    from nansen.api import Api
    from nansen.demo import cell_centres, create_two_photon_demo, tutorial_dir

    api = Api(project=create_two_photon_demo(tmp_path / "tutorial"), start_queue=False)
    try:
        call = lambda method, **params: api.handle({"id": 1, "method": method, "params": params})["result"]
        call("pipelines.submit", pipelineId="ophys.preprocess", entityType="session")
        while call("tasks.runNext"):
            pass
        assert {t["status"] for t in call("tasks.list")} == {"completed"}
        project = api.project
        plan = json.loads((tutorial_dir() / "tutorial.json").read_text(encoding="utf-8"))
        for entity in project.entities("session"):
            truth = np.array(cell_centres(plan, 100 * int(entity.key["subject_id"][1:])))
            found = np.array([roi["center"] for roi in project.load(entity, "RoiArray")["rois"]])
            near = np.hypot(*(truth[:, None, :] - found[None, :, :]).transpose(2, 0, 1)).min(axis=1) <= 5
            assert near.sum() >= 10, (entity.key, truth.tolist(), found.tolist())   # within the motion corrected offset
            assert np.asarray(project.load(entity, "RoiSignals_Dff")).shape == (300, len(found))
            assert np.asarray(project.load(entity, "RoiSignals_Deconvolved")).shape == (300, len(found))
        results = call("methods.run", methodId="ophys.quicky", entityType="session", preset="tutorial")["results"]
        assert all(r["rois"] >= 10 for r in results)
    finally:
        api.close()


def test_demo_needs_an_empty_folder(tmp_path):
    (tmp_path / "x.txt").write_text("")
    with pytest.raises(NansenError) as error:
        create_demo(tmp_path)
    assert error.value.code == "folder-not-empty"
