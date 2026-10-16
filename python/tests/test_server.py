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


def post(server, payload, headers=None):
    request = urllib.request.Request(server.url + "api", data=json.dumps(payload).encode(),
                                     headers=headers or {"Content-Type": "application/json", "X-Nansen-Token": server.token})
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.loads(response.read())


def test_serves_the_frontend(server):
    with urllib.request.urlopen(server.url, timeout=5) as response:
        assert b"<title>NANSEN</title>" in response.read()
    with urllib.request.urlopen(server.url + "js/app.js", timeout=5) as response:
        assert response.headers["Content-Type"].startswith("application/javascript") or \
            response.headers["Content-Type"].startswith("text/javascript")


def test_the_frontend_is_compressed_for_a_browser_that_takes_it(server):
    import gzip
    from pathlib import Path

    request = urllib.request.Request(server.url + "js/views.js", headers={"Accept-Encoding": "gzip, deflate"})
    with urllib.request.urlopen(request, timeout=5) as response:
        assert response.headers["Content-Encoding"] == "gzip" and response.headers["Vary"] == "Accept-Encoding"
        body = response.read()
    expected = (Path(__file__).resolve().parents[2] / "ui" / "js" / "views.js").read_bytes()
    assert gzip.decompress(body) == expected and len(body) < len(expected) / 3
    with urllib.request.urlopen(server.url + "js/views.js", timeout=5) as response:   # and not for one that does not
        assert response.headers["Content-Encoding"] is None and response.read() == expected


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
        with urllib.request.urlopen(server.url + "events?token=" + server.token, timeout=10) as response:
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


def test_answers_only_the_page_it_served(server):
    """Another web page in the browser cannot drive the app: it has no token, and its Origin or Host gives it away."""
    with urllib.request.urlopen(server.url, timeout=5) as response:
        assert f'<meta name="nansen-token" content="{server.token}">'.encode() in response.read()
    refused = [
        {"Content-Type": "application/json"},                                                    # no token
        {"Content-Type": "application/json", "X-Nansen-Token": "guess"},                         # a wrong one
        {"Content-Type": "application/json", "X-Nansen-Token": server.token, "Origin": "https://evil.example"},
        {"Content-Type": "application/json", "X-Nansen-Token": server.token, "Host": "evil.example"},   # DNS rebinding
    ]
    for headers in refused:
        with pytest.raises(urllib.error.HTTPError) as error:
            post(server, {"id": 1, "method": "project.info"}, headers)
        assert error.value.code == 403
    port = server.server_address[1]
    same_site = {"Content-Type": "application/json", "X-Nansen-Token": server.token, "Origin": f"http://127.0.0.1:{port}"}
    assert post(server, {"id": 1, "method": "project.info"}, same_site)["result"]["name"] == "Pilot"
    with pytest.raises(urllib.error.HTTPError) as error:
        urllib.request.urlopen(server.url + "events", timeout=5)   # the event stream needs the token too
    assert error.value.code == 403
