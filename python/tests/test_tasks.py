"""The task queue: submitting, running in threads and processes, cancelling, retrying, recovering."""

import json
import time
from pathlib import Path

import pytest

from nansen import NansenError, Project
from nansen.tasks import TaskQueue, run_task

DATASET = json.loads((Path(__file__).resolve().parents[2] / "testdata" / "entities-dataset.dsm.json").read_text())


@pytest.fixture
def project(tmp_path):
    (tmp_path / "dataset.dsm.json").write_text(json.dumps(DATASET))
    for path in ["sub-m1/ses-m1-001/movie.tif", "sub-m1/ses-m1-002/movie.tif"]:
        target = tmp_path / "data" / "raw" / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"x" * 10)
    project = Project.create(tmp_path, "Pilot", dataset="dataset.dsm.json")
    project.add_module("core")
    project.add_entity_type("subject")
    project.add_entity_type("session", fragments=["core.notes"])
    project.scan()
    project.sync("session")
    return project


def wait_for(predicate, timeout=10.0):
    end = time.time() + timeout
    while time.time() < end:
        if predicate():
            return True
        time.sleep(0.02)
    return False


def test_submit_resolves_options_and_queues(project):
    queue = TaskQueue(project)
    task = queue.submit("core.wait", project.entities("session"), {"seconds": 0})
    assert task["status"] == "queued"
    assert task["options"]["values"] == {"seconds": 0, "steps": 10, "message": "waiting", "fail": False}
    assert [t["id"] for t in queue.list()] == [task["id"]]
    with pytest.raises(NansenError) as error:
        queue.submit("core.wait", project.entities("session"), {"seconds": "soon"})
    assert error.value.code == "invalid-options"


def test_run_next_completes_with_log_and_result(project):
    events = []
    queue = TaskQueue(project, on_event=lambda kind, data: events.append((kind, data.get("status"))))
    task = queue.submit("core.wait", project.entities("session"), {"seconds": 0, "steps": 2})
    done = queue.run_next()
    assert done["status"] == "completed" and done["progress"] == 1
    assert done["result"] == [{"waited": 0}, {"waited": 0}]
    assert "completed" in queue.log(task["id"])
    statuses = [s for kind, s in events if kind == "task"]
    assert statuses[0] == "queued" and statuses[-1] == "completed" and "running" in statuses
    assert queue.run_next() is None


def test_failure_is_recorded_and_retry_makes_a_new_task(project):
    queue = TaskQueue(project)
    task = queue.submit("core.wait", project.entities("session")[:1], {"seconds": 0, "steps": 1, "fail": True})
    failed = queue.run_next()
    assert failed["status"] == "failed"
    assert failed["error"]["message"] == "failed on purpose"
    again = queue.retry(task["id"])
    assert again["id"] != task["id"] and again["status"] == "queued"
    assert again["options"] == task["options"]


def test_cancel_queued_task(project):
    queue = TaskQueue(project)
    task = queue.submit("core.wait", project.entities("session"), {"seconds": 0})
    assert queue.cancel(task["id"])["status"] == "cancelled"
    assert queue.run_next() is None


def test_cancel_running_task_in_the_background(project):
    queue = TaskQueue(project)
    task = queue.submit("core.wait", project.entities("session"), {"seconds": 5, "steps": 100})
    queue.start(poll_seconds=0.05)
    try:
        assert wait_for(lambda: queue.get(task["id"])["status"] == "running")
        queue.cancel(task["id"])
        assert wait_for(lambda: queue.get(task["id"])["status"] == "cancelled")
    finally:
        queue.stop(timeout=5)
    assert not queue.cancel_path(task["id"]).exists()


def test_background_worker_runs_tasks_in_order(project):
    queue = TaskQueue(project)
    first = queue.submit("core.wait", project.entities("session")[:1], {"seconds": 0, "steps": 1})
    second = queue.submit("core.export_keys", project.entities("session"))
    queue.start(poll_seconds=0.05)
    try:
        assert wait_for(lambda: all(t["status"] == "completed" for t in queue.list()))
    finally:
        queue.stop(timeout=5)
    tasks = queue.list()
    assert [t["id"] for t in tasks] == [first["id"], second["id"]]
    assert tasks[0]["finishedAt"] <= tasks[1]["startedAt"]
    assert tasks[1]["result"]["count"] == 2


def test_process_executor(project):
    queue = TaskQueue(project, executor="process")
    task = queue.submit("core.wait", project.entities("session")[:1], {"seconds": 0, "steps": 1})
    done = queue.run_next()
    assert done["status"] == "completed", done.get("error")
    assert "completed" in queue.log(task["id"])


def test_recover_marks_interrupted_tasks_failed(project):
    queue = TaskQueue(project)
    task = queue.submit("core.wait", project.entities("session")[:1])
    task["status"] = "running"
    queue._save(task)
    assert queue.recover() == [task["id"]]
    assert queue.get(task["id"])["status"] == "failed"


def test_remove_and_clear(project):
    queue = TaskQueue(project)
    a = queue.submit("core.wait", project.entities("session")[:1], {"seconds": 0, "steps": 1})
    queue.submit("core.wait", project.entities("session")[:1], {"seconds": 0, "steps": 1})
    queue.run_next()
    queue.remove(a["id"])
    assert len(queue.list()) == 1
    queue.run_next()
    assert queue.clear() == 1 and queue.list() == []


def test_tasks_for_another_language_are_left_alone(project):
    queue = TaskQueue(project)
    queue.submit("core.wait", project.entities("session")[:1], language="matlab")
    assert queue.run_next() is None


def test_run_task_from_a_folder(project):
    queue = TaskQueue(project)
    task = queue.submit("core.export_keys", project.entities("session"))
    assert run_task(project.folder, task["id"])["status"] == "completed"


def test_a_claimed_task_is_not_taken_twice(project):
    queue = TaskQueue(project)
    task = queue.submit("core.wait", project.entities("session")[:1], {"seconds": 0, "steps": 1})
    assert queue.claim(task["id"])
    assert queue.run_next() is None  # another worker holds it
    queue.release(task["id"])
    assert queue.run_next()["status"] == "completed"
    assert not queue.claim_path(task["id"]).exists()


def test_pipeline_runs_steps_in_order_per_entity(project):
    queue = TaskQueue(project)
    tasks = queue.submit_pipeline("core.inspect", project.entities("session"))
    assert len(tasks) == 4
    first, second = tasks[0], tasks[1]
    assert second["after"] == [first["id"]]
    assert second["pipeline"]["step"] == 1 and second["pipeline"]["run"] == first["pipeline"]["run"]
    assert second["options"]["values"]["message"] == "pausing"
    done = queue.run_all()
    assert [t["status"] for t in done] == ["completed"] * 4
    order = {t["id"]: i for i, t in enumerate(done)}
    assert order[first["id"]] < order[second["id"]]


def test_pipeline_step_after_a_failure_is_cancelled(project):
    queue = TaskQueue(project)
    tasks = queue.submit_pipeline("core.inspect", project.entities("session")[:1])
    queue.cancel(tasks[0]["id"])
    assert queue.run_next() is None
    second = queue.get(tasks[1]["id"])
    assert second["status"] == "cancelled" and "earlier step" in second["error"]["message"]


def test_waiting_task_is_not_run_before_its_dependency(project):
    queue = TaskQueue(project)
    tasks = queue.submit_pipeline("core.inspect", project.entities("session")[:1])
    assert queue.claim(tasks[0]["id"])  # another worker holds the first step
    assert queue.run_next() is None     # the second step waits
    queue.release(tasks[0]["id"])


def test_queued_tasks_are_held_changed_and_reordered(tmp_path):
    from nansen.demo import create_demo
    from nansen.tasks import TaskQueue

    project = create_demo(tmp_path / "demo")
    queue = TaskQueue(project)
    sessions = project.entities("session")[:3]
    first, second, third = (queue.submit("core.wait", [s], {"seconds": 0, "message": f"task {i}"})
                            for i, s in enumerate(sessions))
    assert queue.next_task()["id"] == first["id"]

    queue.hold(first["id"])
    assert queue.get(first["id"])["onHold"] is True
    assert queue.next_task()["id"] == second["id"]

    order = queue.reorder([third["id"]])
    assert [t["id"] for t in order] == [third["id"], first["id"], second["id"]]
    assert queue.next_task()["id"] == third["id"]
    late = queue.submit("core.wait", [sessions[0]], {"seconds": 0})
    assert [t["id"] for t in queue.reorder([])] == [third["id"], first["id"], second["id"], late["id"]]

    changed = queue.update(third["id"], {"seconds": 0, "message": "changed"})
    assert changed["options"]["values"]["message"] == "changed"
    with pytest.raises(NansenError) as error:
        queue.update(third["id"], {"seconds": "soon"})
    assert error.value.code == "invalid-options"

    done = queue.run_next()
    assert done["id"] == third["id"] and done["status"] == "completed"
    assert queue.run_next()["id"] == second["id"]  # the first is still on hold
    queue.hold(first["id"], False)
    assert "onHold" not in queue.get(first["id"])
    assert queue.run_next()["id"] == first["id"]
    for call in (lambda: queue.hold(first["id"]), lambda: queue.update(first["id"], {}), lambda: queue.reorder([first["id"]])):
        with pytest.raises(NansenError) as error:
            call()
        assert error.value.code == "task-not-queued"
    with pytest.raises(NansenError) as error:
        queue.hold("00000000-0000-4000-8000-000000000000")
    assert error.value.code == "unknown-task"
