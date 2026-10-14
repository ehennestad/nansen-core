"""The Api object directly: dispatch rules, events, catalog."""

import json
from pathlib import Path

import pytest

from nansen import Project
from nansen.api import Api
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
