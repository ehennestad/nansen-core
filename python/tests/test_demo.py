"""The demo project builds, scans and has its tables filled."""

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


def test_demo_needs_an_empty_folder(tmp_path):
    (tmp_path / "x.txt").write_text("")
    with pytest.raises(NansenError) as error:
        create_demo(tmp_path)
    assert error.value.code == "folder-not-empty"
