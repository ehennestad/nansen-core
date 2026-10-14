"""The HTTP server: static files, POST /api, and the event stream."""

import json
import threading
import urllib.request

import pytest

from nansen import Column, Project
from nansen.api import Api
from nansen.server import serve


@pytest.fixture
def server(tmp_path):
    project = Project.create(tmp_path, "Pilot")
    project.add_module("core")
    table = project.add_entity_type("trial", [Column("trial", "integer")])
    table.add({"trial": 1})
    table.write()
    api = Api(project=project)
    server = serve(api)
    yield server
    server.shutdown()
    api.close()


def post(server, payload):
    request = urllib.request.Request(server.url + "api", data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.loads(response.read())


def test_serves_the_frontend(server):
    with urllib.request.urlopen(server.url, timeout=5) as response:
        assert b"<title>NANSEN</title>" in response.read()
    with urllib.request.urlopen(server.url + "js/app.js", timeout=5) as response:
        assert response.headers["Content-Type"].startswith("application/javascript") or \
            response.headers["Content-Type"].startswith("text/javascript")


def test_does_not_serve_outside_the_ui_folder(server):
    with pytest.raises(urllib.error.HTTPError) as error:
        urllib.request.urlopen(server.url + "../pyproject.toml", timeout=5)
    assert error.value.code == 404


def test_api_round_trip(server):
    assert post(server, {"id": 1, "method": "project.info"})["result"]["name"] == "Pilot"
    assert post(server, {"id": 2, "method": "nope"})["error"]["code"] == "unknown-api-method"


def test_event_stream_delivers_task_events(server):
    lines = []
    ready = threading.Event()

    def listen():
        with urllib.request.urlopen(server.url + "events", timeout=10) as response:
            for raw in response:
                line = raw.decode().strip()
                if line.startswith(": connected"):
                    ready.set()
                if line.startswith("data:"):
                    lines.append(json.loads(line[5:]))
                    if lines[-1]["event"] == "task" and lines[-1]["data"]["status"] == "completed":
                        return

    thread = threading.Thread(target=listen, daemon=True)
    thread.start()
    assert ready.wait(5)
    post(server, {"id": 1, "method": "tasks.submit", "params": {
        "methodId": "core.wait", "entityType": "trial", "options": {"seconds": 0, "steps": 1}}})
    thread.join(10)
    statuses = [e["data"]["status"] for e in lines if e["event"] == "task"]
    assert statuses[0] == "queued" and statuses[-1] == "completed"
