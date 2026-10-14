"""The Api object directly: dispatch rules, events, catalog."""

import json
from pathlib import Path

import pytest

from nansen import Project
from nansen.api import Api
from nansen.errors import NansenError
from nansen.catalog import Catalog


def test_dispatch_errors():
    api = Api(start_queue=False)
    assert api.handle({"id": 1})["error"]["code"] == "invalid-request"
    assert api.handle("nonsense")["error"]["code"] == "invalid-request"
    assert api.handle({"id": 2, "method": "app.info", "params": []})["error"]["code"] == "invalid-params"
    assert api.handle({"id": 3, "method": "app.info"})["id"] == 3


def test_events_and_catalog(tmp_path):
    catalog = Catalog(tmp_path / "catalog.json")
    api = Api(catalog=catalog, start_queue=False)
    events = []
    unsubscribe = api.subscribe(events.append)
    response = api.handle({"id": 1, "method": "project.create",
                           "params": {"path": str(tmp_path / "p"), "name": "Pilot", "modules": ["core"]}})
    assert response["result"]["name"] == "Pilot"
    assert events[-1] == {"event": "project", "data": {"name": "Pilot"}}
    projects = api.handle({"id": 2, "method": "catalog.list"})["result"]
    assert [p["name"] for p in projects] == ["Pilot"] and projects[0]["available"]
    unsubscribe()
    api.handle({"id": 3, "method": "project.open", "params": {"path": str(tmp_path / "p")}})
    assert len([e for e in events if e["event"] == "project"]) == 1
    assert api.handle({"id": 4, "method": "catalog.remove", "params": {"path": str(tmp_path / "p")}})["result"] == []
    api.close()


def test_background_queue_reports_task_events(tmp_path):
    from nansen import Column

    project = Project.create(tmp_path, "Pilot")
    project.add_module("core")
    table = project.add_entity_type("trial", [Column("trial", "integer")])
    table.add({"trial": 1})
    table.write()
    api = Api(project=project)
    statuses = []
    api.subscribe(lambda e: statuses.append(e["data"]["status"]) if e["event"] == "task" else None)
    task = api.handle({"id": 1, "method": "tasks.submit", "params": {
        "methodId": "core.wait", "entityType": "trial", "options": {"seconds": 0, "steps": 1}}})["result"]
    import time
    for _ in range(200):
        if "completed" in statuses:
            break
        time.sleep(0.02)
    api.close()
    assert statuses[0] == "queued" and "completed" in statuses
    detail = Api(project=Project.open(tmp_path), start_queue=False).handle(
        {"id": 2, "method": "tasks.get", "params": {"id": task["id"]}})["result"]
    assert "completed" in detail["logText"]


def test_a_copied_dataset_keeps_its_text_and_its_roots(tmp_path):
    import json

    from nansen.dataset import copy_dataset

    study = tmp_path / "study"
    study.mkdir()
    original = (Path(__file__).resolve().parents[2] / "testdata" / "entities-dataset.dsm.json").read_text()
    (study / "dataset.dsm.json").write_text(original)
    target = tmp_path / "copy.dsm.json"
    copy_dataset(study / "dataset.dsm.json", target)
    copied = target.read_text()
    paths = [root["path"] for loc in json.loads(copied)["dataLocations"]
             for root in loc["filesystemSource"]["rootStoragePaths"]]
    assert paths == [(study / "data" / "raw").as_posix(), "/nonexistent/lab/raw", (study / "data" / "processed").as_posix()]
    # only the relative paths changed
    assert copied.replace((study / "data").as_posix(), "data") == original


def test_the_app_creates_and_imports_projects(tmp_path):
    from nansen.catalog import Catalog

    api = Api(catalog=Catalog(tmp_path / "catalog.json"), start_queue=False)
    demo = api.handle({"id": 1, "method": "demo.create", "params": {"path": str(tmp_path / "demo")}})["result"]
    assert demo["name"] == "TwoPhotonDemo"
    assert [p["path"] for p in api.handle({"id": 2, "method": "catalog.list"})["result"]] == [str(tmp_path / "demo")]
    error = api.handle({"id": 3, "method": "legacy.import", "params": {"source": str(tmp_path), "path": str(tmp_path / "x")}})
    assert error["error"]["code"] == "legacy-needs-matlab"
    api.close()


def test_a_project_gets_its_dataset_later(tmp_path):
    from nansen.demo import demo_dir

    api = Api(start_queue=False)
    api.handle({"id": 1, "method": "project.create", "params": {"path": str(tmp_path / "p"), "name": "P", "modules": ["core"]}})
    info = api.handle({"id": 2, "method": "project.setDataset", "params": {
        "datasetSource": str(demo_dir() / "dataset.dsm.json"), "entityTypes": True}})["result"]
    assert [(e["name"], e["fragments"]) for e in info["entityTypes"]] == [("subject", ["core.notes"]), ("session", ["core.notes"])]
    again = api.handle({"id": 3, "method": "project.setDataset", "params": {"datasetSource": str(demo_dir() / "dataset.dsm.json")}})
    assert again["error"]["code"] == "dataset-exists"
    api.close()


def test_an_invalid_dataset_is_not_kept(tmp_path):
    bad = tmp_path / "bad.dsm.json"
    bad.write_text('{"schemaVersion": "0.1.0", "entityTypes": "no"}')
    project = Project.create(tmp_path / "p", "P")
    with pytest.raises(NansenError) as error:
        project.set_dataset(bad)
    assert error.value.code == "dataset-invalid"
    assert "dataset" not in Project.open(tmp_path / "p").document
    assert not (tmp_path / "p" / "dataset.dsm.json").exists()
