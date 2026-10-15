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


def test_catalog_lists_the_last_opened_first_within_one_second(tmp_path):
    api = Api(catalog=Catalog(tmp_path / "catalog.json"), start_queue=False)
    for name in ["First", "Second", "Third"]:  # often in one second, which lastOpened cannot tell apart
        api.handle({"id": 1, "method": "project.create",
                    "params": {"path": str(tmp_path / name), "name": name, "modules": ["core"]}})
    projects = api.handle({"id": 2, "method": "catalog.list"})["result"]
    assert [p["name"] for p in projects] == ["Third", "Second", "First"]
    api.close()


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
    assert [(e["name"], e["fragments"]) for e in info["entityTypes"]] == [("subject", ["core.notes", "core.subject"]), ("session", ["core.notes"])]
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


def test_files_resolve_and_reveal_stay_inside_the_project(tmp_path):
    from nansen.demo import create_demo

    project = create_demo(tmp_path / "demo")
    api = Api(project=project, start_queue=False)
    opened = []
    api.open_folder = opened.append
    result = api.handle({"id": 1, "method": "files.reveal", "params": {"path": "tables/session.csv"}})["result"]
    assert result["exists"] and not result["isFolder"]
    assert opened == [(tmp_path / "demo" / "tables").resolve()]  # a file's folder is shown
    session = project.entities("session")[0]
    location = session.locations[0]
    params = {"dataLocation": location["dataLocationIdentifier"], "rootStoragePath": location["rootStoragePathIdentifier"],
              "path": location["paths"][0]}
    assert api.handle({"id": 2, "method": "files.resolve", "params": params})["result"]["isFolder"]
    for bad in ({"path": "../elsewhere"}, {"path": "/etc"}, dict(params, path="../../..")):
        assert api.handle({"id": 3, "method": "files.resolve", "params": bad})["error"]["code"] == "invalid-params"
    assert api.handle({"id": 4, "method": "files.reveal", "params": {"path": "nothing/here"}})["error"]["code"] == "file-not-found"
    assert len(opened) == 1
    api.close()


def test_choices_detach_and_reset(tmp_path):
    from nansen.demo import create_demo

    api = Api(project=create_demo(tmp_path / "demo"), start_queue=False)
    call = lambda method, **params: api.handle({"id": 1, "method": method, "params": params})
    fragment = {"schemaType": "nansen.fragment", "schemaVersion": "0.1.0", "id": "qc", "version": "1.0.0",
                "columns": [{"name": "quality", "dataType": "string", "choices": ["good", "poor"]},
                            {"name": "checked", "dataType": "boolean", "default": False}]}
    assert call("fragments.create", document=fragment, entityType="session")["result"]["id"] == "qc"
    rows = call("entities.list", entityType="session")["result"]
    quality = next(c for c in rows["columns"] if c["name"] == "quality")
    assert quality["choices"] == ["good", "poor"] and quality["editable"]
    key = rows["rows"][0]["key"]
    assert call("entities.update", entityType="session", key=key, values={"quality": "poor"})["result"]["values"]["quality"] == "poor"
    assert call("entities.update", entityType="session", key=key, values={"quality": "great"})["error"]["code"] == "invalid-value"
    assert call("entities.update", entityType="session", key=key, values={"quality": None})["result"]["values"]["quality"] is None
    bad = dict(fragment, id="bad", columns=[{"name": "n", "dataType": "integer", "choices": ["1"]}])
    assert call("fragments.create", document=bad)["error"]["code"] == "schema-validation"

    call("entities.update", entityType="session", key=key, values={"checked": True, "description": "x"})
    assert call("columns.reset", entityType="session", column="checked", keys=[key])["result"] == {"reset": 1}
    assert call("columns.reset", entityType="session", column="description")["result"]["reset"] == 14
    values = call("entities.get", entityType="session", key=key)["result"]["values"]
    assert values["checked"] is False and values["description"] is None
    assert call("columns.reset", entityType="session", column="session_id")["error"]["code"] == "read-only-column"
    assert call("columns.reset", entityType="session", column="nope")["error"]["code"] == "unknown-column"

    assert call("fragments.detach", entityType="session", fragmentId="qc")["result"]["fragments"] == ["core.notes", "core.file_stats"]
    names = [c["name"] for c in call("entities.list", entityType="session")["result"]["columns"]]
    assert "quality" not in names and "checked" not in names
    assert call("fragments.detach", entityType="session", fragmentId="qc")["error"]["code"] == "unknown-fragment"
    assert call("fragments.attach", entityType="session", fragmentId="qc")["result"]  # and back, with defaults
    api.close()


def test_the_dataset_config_is_edited_as_text(tmp_path):
    from nansen.demo import create_demo

    api = Api(project=create_demo(tmp_path / "demo"), start_queue=False)
    call = lambda method, **params: api.handle({"id": 1, "method": method, "params": params})
    got = call("dataset.get")["result"]
    assert got["path"] == "dataset.dsm.json"
    config = tmp_path / "demo" / "dataset.dsm.json"
    assert got["text"] == config.read_text()

    edited = got["text"].replace('"displayName": "Processed"', '"displayName": "Processed data"')
    info = call("dataset.save", text=edited)["result"]
    assert [l["title"] for l in info["dataset"]["locations"]] == ["Raw two-photon data", "Processed data"]
    assert config.read_text() == edited  # as written, formatting and all

    # A config DSM accepts, but whose identity no longer fits the session table, is not kept
    changed = edited.replace('"identifierRef": "session_id"', '"identifierRef": "session_date"')
    assert changed != edited
    assert call("dataset.save", text=changed)["error"]["code"] == "key-mismatch"
    assert config.read_text() == edited
    assert call("dataset.save", text="{")["error"]["code"] == "dataset-invalid"
    assert config.read_text() == edited
    assert call("entities.list", entityType="session")["result"]["rows"]


def test_entities_are_sent_to_the_workspace(tmp_path):
    from nansen.demo import create_demo

    api = Api(project=create_demo(tmp_path / "demo"), start_queue=False)
    call = lambda method, **params: api.handle({"id": 1, "method": method, "params": params})
    rows = call("entities.list", entityType="session")["result"]["rows"]
    assert call("app.info")["result"]["workspace"] is False
    assert call("workspace.send", entityType="session")["error"]["code"] == "no-workspace"
    namespace = {}
    api.workspace = namespace
    assert call("app.info")["result"]["workspace"] is True
    result = call("workspace.send", entityType="session", keys=[r["key"] for r in rows[:2]], name="picked")["result"]
    assert result == {"name": "picked", "count": 2}
    assert [e.key for e in namespace["picked"]] == [r["key"] for r in rows[:2]]
    assert call("workspace.send", entityType="session", name="not valid")["error"]["code"] == "invalid-params"
    assert call("workspace.send", entityType="session", name="class")["error"]["code"] == "invalid-params"


def test_open_files_edit_method_code_and_send_data(tmp_path):
    from nansen.demo import create_demo

    api = Api(project=create_demo(tmp_path / "demo"), start_queue=False)
    opened, edited = [], []
    api.open_file, api.edit_file = opened.append, edited.append
    call = lambda method, **params: api.handle({"id": 1, "method": method, "params": params})
    assert call("files.open", path="project.nansen.json")["result"]["exists"] is True
    assert opened == [tmp_path / "demo" / "project.nansen.json"]

    call("methods.create", id="count_frames", entityType="session")
    assert call("methods.edit", methodId="count_frames")["result"]["language"] == "python"
    assert call("methods.edit", methodId="count_frames", language="matlab")["result"]["path"].endswith("count_frames.m")
    assert [p.name for p in edited] == ["count_frames.py", "count_frames.m"]
    assert call("methods.edit", methodId="core.wait")["result"]["path"].endswith("core_methods.py")

    rows = call("entities.list", entityType="session")["result"]["rows"]
    key = next(r["key"] for r in rows if r["values"].get("ignore") is not True)
    assert call("data.send", entityType="session", key=key, variable="motion_corrected")["error"]["code"] == "no-workspace"
    namespace = {}
    api.workspace = namespace
    result = call("data.send", entityType="session", key=key, variable="motion_corrected", name="mc")["result"]
    assert result == {"name": "mc", "variable": "motion_corrected"}
    assert namespace["mc"] is not None


def test_the_worker_starts_as_the_settings_say(tmp_path):
    from nansen.demo import create_demo
    from nansen.server import open_app

    catalog = Catalog(tmp_path / "catalog.json")
    project = create_demo(tmp_path / "demo")
    assert catalog.settings() == {"queue": {"autoStart": True, "worker": "thread"}, "addons": {"folder": ""},
                                  "workers": {"python": "", "matlab": ""}, "tables": {"saveToDataFolders": False}}
    server = open_app(project, catalog=catalog, open_browser=False)
    try:
        assert server.api.queue.running
    finally:
        server.shutdown()
        server.api.close()
    catalog.save_settings({"queue": {"autoStart": False}})
    server = open_app(project, catalog=catalog, open_browser=False)
    try:
        assert not server.api.queue.running
    finally:
        server.shutdown()
        server.api.close()


def test_the_worker_runs_tasks_as_the_settings_say(tmp_path):
    from nansen.demo import create_demo

    catalog = Catalog(tmp_path / "catalog.json")
    catalog.save_settings({"queue": {"worker": "process"}})
    api = Api(catalog=catalog, project=create_demo(tmp_path / "demo"), start_queue=False)
    call = lambda method, **params: api.handle({"id": 1, "method": method, "params": params})
    try:
        assert api.queue.executor == "process"
        assert call("queue.status")["result"]["worker"] == "process"
        assert call("settings.save", settings={"queue": {"worker": "thread"}})["result"]["queue"]["worker"] == "thread"
        assert api.queue.executor == "thread" and call("queue.status")["result"] | {"counts": None} == \
            {"running": False, "executor": "python", "worker": "thread", "counts": None}
        assert call("settings.save", settings={"queue": {"worker": "fork"}})["error"]["code"] == "invalid-params"
        assert Api(catalog=catalog, executor="process", start_queue=False).executor == "process"   # given, not the setting
    finally:
        api.close()


def test_starting_a_matlab_worker_needs_matlab(tmp_path, monkeypatch):
    import shutil
    from nansen.demo import create_demo

    catalog = Catalog(tmp_path / "catalog.json")
    api = Api(catalog=catalog, project=create_demo(tmp_path / "demo"), start_queue=False)
    call = lambda method, **params: api.handle({"id": 1, "method": method, "params": params})
    try:
        monkeypatch.setattr(shutil, "which", lambda name: None)
        assert call("queue.startWorker", language="matlab")["error"]["code"] == "dependency-missing"
        assert call("queue.startWorker", language="r")["error"]["code"] == "invalid-params"
        assert call("queue.startWorker", language="python")["result"]["running"] is True   # its own: queue.start
        assert catalog.settings()["workers"] == {"python": "", "matlab": ""}
    finally:
        api.close()


def test_running_a_method_only_matlab_has_waits_for_a_matlab_worker(tmp_path):
    import sys
    from nansen.demo import create_demo

    # A stand-in for matlab -batch "nansen.worker(...)": it does what the outcome file says to the MATLAB task
    fake = tmp_path / "matlab"
    fake.write_text(f"""#!{sys.executable}
import json, re, sys
from pathlib import Path
from nansen.project import Project
from nansen.tasks import TaskQueue
folder = re.search(r"nansen.worker\\('([^']*)'", sys.argv[2]).group(1)
outcome = json.loads((Path(folder) / "outcome.json").read_text())
if outcome:
    queue = TaskQueue(Project.open(folder))
    task = next(t for t in queue.list("queued") if t.get("language") == "matlab")
    task.update(outcome)
    queue._save(task)
""")
    fake.chmod(0o755)
    catalog = Catalog(tmp_path / "catalog.json")
    catalog.save_settings({"workers": {"matlab": str(fake)}})
    project = create_demo(tmp_path / "demo")
    project.create_method("only_matlab", "Only MATLAB", entity_type="session", languages=["matlab"])
    api = Api(catalog=catalog, project=project, start_queue=False)
    key = project.entities("session")[0].key
    call = lambda method, **params: api.handle({"id": 1, "method": method, "params": params})
    outcome = lambda value: (project.folder / "outcome.json").write_text(json.dumps(value))
    try:
        outcome({"status": "completed", "result": [{"frames": 3}]})   # one per entity
        result = call("methods.run", methodId="only_matlab", entityType="session", keys=[key])["result"]
        assert result["language"] == "matlab" and result["results"] == [{"frames": 3}]
        assert api.queue.get(result["taskId"])["status"] == "completed"
        outcome({"status": "failed", "error": {"identifier": "MATLAB:x", "message": "no toolbox"}})
        error = call("methods.run", methodId="only_matlab", entityType="session", keys=[key])["error"]
        assert error["code"] == "task-failed" and "no toolbox" in error["message"]
        outcome({})   # the worker never takes it
        error = call("methods.run", methodId="only_matlab", entityType="session", keys=[key], startTimeout=1)["error"]
        assert error["code"] == "task-failed" and "worker-matlab.log" in error["message"]
        assert [t["status"] for t in api.queue.list()][-1] == "cancelled"
    finally:
        api.close()


def test_any_file_goes_to_the_workspace(tmp_path):
    from nansen.demo import create_demo

    api = Api(project=create_demo(tmp_path / "demo"), start_queue=False)
    call = lambda method, **params: api.handle({"id": 1, "method": method, "params": params})
    try:
        assert call("files.send", path="project.nansen.json")["error"]["code"] == "no-workspace"
        api.workspace = {}
        result = call("files.send", path="project.nansen.json")["result"]
        assert result["name"] == "project_nansen" and result["adapter"] == "json"   # the first adapter naming .json
        assert api.workspace["project_nansen"]["name"] == api.project.name
        assert call("files.send", path="tables/session.csv", name="sessions")["result"]["adapter"] == "csv"
        assert "sessions" in api.workspace
        (api.project.folder / "1 odd.txt").write_text("hello")
        assert call("files.send", path="1 odd.txt")["result"]["name"] == "data_1_odd"
        assert api.workspace["data_1_odd"] == "hello"
        (api.project.folder / "x.unknown").write_text("?")
        assert call("files.send", path="x.unknown")["error"]["code"] == "unsupported-file"
        assert call("files.send", path="project.nansen.json", name="not a name")["error"]["code"] == "invalid-params"
        assert call("files.send", path="tables")["error"]["code"] == "invalid-params"
    finally:
        api.close()


def test_projects_are_renamed_moved_and_deleted(tmp_path):
    catalog = Catalog(tmp_path / "catalog.json")
    one, two = Project.create(tmp_path / "one", "One"), Project.create(tmp_path / "two", "Two")
    catalog.add(one)
    catalog.add(two)
    api = Api(catalog=catalog, project=Project.open(tmp_path / "one"), start_queue=False)
    call = lambda method, **params: api.handle({"id": 1, "method": method, "params": params})
    try:
        before = (tmp_path / "one" / "project.nansen.json").read_text()
        names = {p["path"]: p["name"] for p in call("catalog.rename", path=str(tmp_path / "one"), name="First")["result"]}
        assert names[str((tmp_path / "one").resolve())] == "First" and api.project.name == "First"   # the open one, read again
        assert (tmp_path / "one" / "project.nansen.json").read_text() == before.replace('"One"', '"First"', 1)
        assert call("catalog.rename", path=str(tmp_path / "one"), name="no good")["error"]["code"] == "invalid-params"
        assert call("catalog.move", path=str(tmp_path / "one"), newPath=str(tmp_path / "moved"))["error"]["code"] == "invalid-params"   # open
        moved = call("catalog.move", path=str(tmp_path / "two"), newPath=str(tmp_path / "archive" / "two"))["result"]
        assert str((tmp_path / "archive" / "two").resolve()) in [p["path"] for p in moved] and not (tmp_path / "two").exists()
        assert call("catalog.move", path=str(tmp_path / "archive" / "two"), newPath=str(tmp_path / "one"))["error"]["code"] == "folder-not-empty"
        assert call("catalog.remove", path=str(tmp_path / "one"), deleteFolder=True)["error"]["code"] == "invalid-params"   # open
        left = call("catalog.remove", path=str(tmp_path / "archive" / "two"), deleteFolder=True)["result"]
        assert [p["name"] for p in left] == ["First"] and not (tmp_path / "archive" / "two").exists()
    finally:
        api.close()


def test_a_dev_project_folder_is_read_by_matlab(tmp_path, monkeypatch):
    import shutil
    import sys

    export = Path(__file__).resolve().parents[2] / "conformance" / "legacy" / "two-photon" / "export.json"
    catalog = Catalog(tmp_path / "catalog.json")
    api = Api(catalog=catalog, start_queue=False)
    call = lambda method, **params: api.handle({"id": 1, "method": method, "params": params})
    dev = tmp_path / "dev_project"
    dev.mkdir()
    try:
        monkeypatch.setattr(shutil, "which", lambda name: None)
        assert call("legacy.import", source=str(dev), path=str(tmp_path / "a"))["error"]["code"] == "legacy-needs-matlab"
        # a stand-in for matlab -batch "nansen.legacy.exportProject(folder, File=...)": it writes the export
        fake = tmp_path / "matlab"
        fake.write_text(f"""#!{sys.executable}
import re, shutil, sys
assert "nansen.legacy.exportProject('{dev}'" in sys.argv[2]
shutil.copyfile({str(export)!r}, re.search(r"File='([^']*)'", sys.argv[2]).group(1))
""")
        fake.chmod(0o755)
        catalog.save_settings({"workers": {"matlab": str(fake)}})
        result = call("legacy.import", source=str(dev), path=str(tmp_path / "b"))["result"]
        assert result["project"]["name"] and (tmp_path / "b" / "project.nansen.json").is_file()
        fake.write_text(f"#!{sys.executable}\nimport sys\nprint('Undefined function'); sys.exit(1)\n")
        error = call("legacy.import", source=str(dev), path=str(tmp_path / "c"))["error"]
        assert error["code"] == "invalid-data" and "Undefined function" in error["message"]
    finally:
        api.close()


def test_edited_rows_are_saved_into_the_data_folders(tmp_path):
    from nansen.demo import create_demo

    catalog = Catalog(tmp_path / "catalog.json")
    api = Api(catalog=catalog, project=create_demo(tmp_path / "demo"), start_queue=False)
    call = lambda method, **params: api.handle({"id": 1, "method": method, "params": params})
    try:
        row = call("entities.list", entityType="session")["result"]["rows"][0]
        detail = call("entities.get", entityType="session", key=row["key"])["result"]
        folders = [Path(call("files.resolve", dataLocation=loc["dataLocationIdentifier"], path=p)["result"]["path"])
                   for loc in detail["locations"] for p in loc.get("paths", [])]
        folders = [f for f in folders if f.is_dir()]
        assert folders
        call("entities.update", entityType="session", key=row["key"], values={"description": "first"})
        assert not any((f / "session_info.json").exists() for f in folders)   # off unless asked for
        catalog.save_settings({"tables": {"saveToDataFolders": True}})
        call("entities.update", entityType="session", key=row["key"], values={"description": "second"})
        for folder in folders:   # dev's AutosaveMetadataToDataFolders
            saved = json.loads((folder / "session_info.json").read_text())
            assert saved["description"] == "second" and all(saved[k] == v for k, v in row["key"].items())
    finally:
        api.close()


def test_a_shared_project_is_installed_from_git(tmp_path):
    import shutil
    import subprocess
    if shutil.which("git") is None:
        pytest.skip("git is not installed")
    git = lambda *args, cwd: subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], cwd=cwd, check=True, capture_output=True)
    shared = tmp_path / "shared"
    Project.create(shared, "Shared")
    git("init", "-q", cwd=shared)
    git("add", ".", cwd=shared)
    git("commit", "-q", "-m", "a project", cwd=shared)
    empty = tmp_path / "empty"
    empty.mkdir()
    (empty / "README.md").write_text("no project here")
    git("init", "-q", cwd=empty)
    git("add", ".", cwd=empty)
    git("commit", "-q", "-m", "not a project", cwd=empty)
    api = Api(catalog=Catalog(tmp_path / "catalog.json"), start_queue=False)
    call = lambda method, **params: api.handle({"id": 1, "method": method, "params": params})
    projects = call("catalog.install", url=str(shared), path=str(tmp_path / "mine"))["result"]
    assert [p["name"] for p in projects] == ["Shared"] and projects[0]["available"] is True
    assert (tmp_path / "mine" / "project.nansen.json").is_file()
    assert call("catalog.install", url=str(shared), path=str(tmp_path / "mine"))["error"]["code"] == "folder-not-empty"
    assert call("catalog.install", url=str(tmp_path / "nowhere"), path=str(tmp_path / "other"))["error"]["code"] == "install-failed"
    assert call("catalog.install", url=str(empty), path=str(tmp_path / "third"))["error"]["code"] == "not-a-project"


def test_a_moved_project_is_located_again(tmp_path):
    import shutil

    catalog = Catalog(tmp_path / "catalog.json")
    api = Api(catalog=catalog, start_queue=False)
    call = lambda method, **params: api.handle({"id": 1, "method": method, "params": params})
    call("project.create", path=str(tmp_path / "pilot"), name="Pilot")
    call("project.create", path=str(tmp_path / "other"), name="Other")
    api.close()
    shutil.move(str(tmp_path / "pilot"), str(tmp_path / "moved"))
    entry = next(p for p in call("catalog.list")["result"] if p["name"] == "Pilot")
    assert entry["available"] is False
    assert call("catalog.relocate", path=entry["path"], newPath=str(tmp_path / "other"))["error"]["code"] == "invalid-params"
    assert call("catalog.relocate", path=entry["path"], newPath=str(tmp_path / "nowhere"))["error"]["code"] == "file-not-found"
    projects = call("catalog.relocate", path=entry["path"], newPath=str(tmp_path / "moved"))["result"]
    moved = next(p for p in projects if p["name"] == "Pilot")
    assert moved["available"] is True and moved["path"] == str((tmp_path / "moved").resolve())
    assert call("catalog.relocate", path=entry["path"], newPath=str(tmp_path / "moved"))["error"]["code"] == "unknown-project"
