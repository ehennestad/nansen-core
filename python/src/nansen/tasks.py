"""The task queue: methods queued on entities, run in the background, kept as nansen.task documents.

A task file describes everything a worker needs, so a task can run in a
thread of this process, in a separate Python process, or in MATLAB. While a
task runs its worker owns the file; anyone else asks it to stop by creating
tasks/<id>.cancel.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import subprocess
import sys
import threading
import traceback
import uuid
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from .documents import PathLike, check_document, read_document
from .errors import NansenError
from .methods import Cancelled, MethodContext, run_method
from .schemas import current_version

TERMINAL = ("completed", "failed", "cancelled")
MAX_RESULT_BYTES = 64 * 1024

EventHandler = Callable[[str, dict], None]


def now() -> str:
    return dt.datetime.now().isoformat(timespec="milliseconds")


def write_task(path: Path, document: dict) -> None:
    """Validate and write atomically, so a reader never sees half a file."""
    document = check_document(document, "nansen.task")
    temporary = path.with_name(path.name + f".{os.getpid()}.{threading.get_ident()}.tmp")
    with open(temporary, "w", encoding="utf-8", newline="\n") as f:
        json.dump(document, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(temporary, path)


class TaskQueue:
    """The tasks of one project. Create one per project; there is no global queue.

    ``executor`` is "thread" (run in a worker thread of this process) or
    "process" (run each task in a separate Python process). ``on_event`` is
    called as on_event(kind, data) with kind "task" (a task changed) or
    "log" (a line was logged), from the worker thread.
    """

    def __init__(self, project, executor: str = "thread", on_event: Optional[EventHandler] = None):
        if executor not in ("thread", "process"):
            raise ValueError(f"unknown executor {executor!r}")
        self.project = project
        self.executor = executor
        self.on_event = on_event
        self.folder = Path(project.folder) / "tasks"
        self._worker: Optional[threading.Thread] = None
        self._stop = threading.Event()
        self._wake = threading.Event()
        self._lock = threading.Lock()

    # -- documents ----------------------------------------------------------------------------

    def path(self, task_id: str) -> Path:
        return self.folder / f"{task_id}.task.nansen.json"

    def log_path(self, task_id: str) -> Path:
        return self.folder / f"{task_id}.log"

    def cancel_path(self, task_id: str) -> Path:
        return self.folder / f"{task_id}.cancel"

    def claim_path(self, task_id: str) -> Path:
        return self.folder / f"{task_id}.claim"

    def claim(self, task_id: str) -> bool:
        """Take a queued task for this worker. Creating a folder is atomic, so two workers
        (threads, processes, MATLAB and Python) cannot both take the same task."""
        try:
            self.claim_path(task_id).mkdir()
            return True
        except FileExistsError:
            return False

    def release(self, task_id: str) -> None:
        path = self.claim_path(task_id)
        if path.is_dir():
            path.rmdir()

    def get(self, task_id: str) -> dict:
        path = self.path(task_id)
        if not path.is_file():
            raise NansenError("unknown-task", f"no task {task_id!r}")
        return read_document(path, "nansen.task")

    def list(self, status: Optional[str] = None) -> List[dict]:
        """Tasks in the order they were created."""
        if not self.folder.is_dir():
            return []
        tasks = []
        for path in self.folder.glob("*.task.nansen.json"):
            try:
                tasks.append(read_document(path, "nansen.task"))
            except NansenError:
                continue  # a file being replaced, or broken; it is not a task to show
        tasks.sort(key=lambda t: (t["createdAt"], t["id"]))
        return [t for t in tasks if status is None or t["status"] == status]

    def log(self, task_id: str) -> str:
        path = self.log_path(task_id)
        return path.read_text(encoding="utf-8") if path.is_file() else ""

    def _emit(self, kind: str, data: dict) -> None:
        if self.on_event is not None:
            self.on_event(kind, data)

    def _save(self, document: dict) -> None:
        self.folder.mkdir(exist_ok=True)
        write_task(self.path(document["id"]), document)
        self._emit("task", document)

    # -- queueing -----------------------------------------------------------------------------

    def submit(self, method_id: str, entities: List[Any], options: Optional[Dict[str, Any]] = None,
               preset: Optional[str] = None, language: Optional[str] = None) -> dict:
        """Queue a method on entities. Options are resolved and validated now, so a queued task is runnable."""
        method = self.project.method(method_id)
        if not method.queueable:
            raise NansenError("not-queueable", f"method {method_id!r} cannot run in the background")
        if not entities:
            raise NansenError("no-entities", "a task needs at least one entity")
        for entity in entities:
            if not method.applies_to(entity.entity_type):
                raise NansenError("wrong-entity-type", f"{method.id} runs on {method.entity_type}")
        values = self.project.preset(method_id, preset) if preset else {}
        values = method.resolve_options(dict(values, **(options or {})))
        task = {
            "schemaType": "nansen.task",
            "schemaVersion": current_version("nansen.task"),
            "id": str(uuid.uuid4()),
            "method": {"id": method.id, "version": method.version},
            "entities": [{"entityType": e.entity_type, "key": dict(e.key)} for e in entities],
            "options": {"values": values},
            "status": "queued",
            "createdAt": now(),
            "progress": 0,
        }
        if preset:
            task["options"]["preset"] = preset
        if language:
            task["language"] = language
        self._save(task)
        self._wake.set()
        return task

    def cancel(self, task_id: str) -> dict:
        """Cancel a queued task now; ask a running task to stop at its next check."""
        with self._lock:
            task = self.get(task_id)
            if task["status"] == "queued":
                task.update(status="cancelled", finishedAt=now())
                self._save(task)
            elif task["status"] == "running":
                self.cancel_path(task_id).write_text(now())
            return task

    def retry(self, task_id: str) -> dict:
        """Queue a finished task again, as a new task with the same method, entities and options."""
        old = self.get(task_id)
        if old["status"] not in TERMINAL:
            raise NansenError("task-active", f"task {task_id} is {old['status']}")
        task = {k: v for k, v in old.items() if k in ("schemaType", "schemaVersion", "method", "entities", "options",
                                                       "language")}
        task.update(id=str(uuid.uuid4()), status="queued", createdAt=now(), progress=0)
        self._save(task)
        self._wake.set()
        return task

    def remove(self, task_id: str) -> None:
        task = self.get(task_id)
        if task["status"] == "running":
            raise NansenError("task-active", f"task {task_id} is running")
        for path in (self.path(task_id), self.log_path(task_id), self.cancel_path(task_id)):
            if path.exists():
                path.unlink()
        self.release(task_id)
        self._emit("removed", {"id": task_id})

    def clear(self, statuses=TERMINAL) -> int:
        removed = 0
        for task in self.list():
            if task["status"] in statuses:
                self.remove(task["id"])
                removed += 1
        return removed

    def recover(self) -> List[str]:
        """Mark tasks left 'running' by a worker that died as failed. Call when no worker is running."""
        recovered = []
        for task in self.list("running"):
            task.update(status="failed", finishedAt=now(),
                        error={"message": "interrupted: the worker stopped while the task was running"})
            self._save(task)
            self.release(task["id"])
            recovered.append(task["id"])
        for path in self.folder.glob("*.claim") if self.folder.is_dir() else []:
            task_id = path.name[: -len(".claim")]
            if not self.path(task_id).is_file() or self.get(task_id)["status"] != "queued":
                path.rmdir()
        return recovered

    # -- running ------------------------------------------------------------------------------

    def next_task(self) -> Optional[dict]:
        for task in self.list("queued"):
            if task.get("language", "python") == "python" and not self.claim_path(task["id"]).exists():
                return task
        return None

    def run_next(self) -> Optional[dict]:
        """Run the oldest queued task in this thread. Returns it when done, or None when nothing is queued."""
        with self._lock:
            while True:
                task = self.next_task()
                if task is None:
                    return None
                if self.claim(task["id"]):
                    task = self.get(task["id"])
                    if task["status"] == "queued":
                        break
                    self.release(task["id"])
            task.update(status="running", startedAt=now(), progress=0)
            self._save(task)
        if self.executor == "process":
            self._run_in_process(task["id"])
        else:
            run_task(self.project, task["id"], on_event=self.on_event)
        return self.get(task["id"])

    def run_all(self) -> List[dict]:
        done = []
        while True:
            task = self.run_next()
            if task is None:
                return done
            done.append(task)

    def _run_in_process(self, task_id: str) -> None:
        command = [sys.executable, "-m", "nansen", "run-task", str(self.project.folder), task_id]
        if self.project.environment:
            command += ["--environment", self.project.environment]
        completed = subprocess.run(command, capture_output=True, text=True)
        task = self.get(task_id)
        if task["status"] == "running":  # the process died before it could finish the document
            task.update(status="failed", finishedAt=now(),
                        error={"message": f"worker process exited with {completed.returncode}",
                               "stack": completed.stderr.splitlines()[-20:]})
            self._save(task)
            self.release(task_id)
        else:
            self._emit("task", task)

    def start(self, poll_seconds: float = 0.5) -> None:
        """Run queued tasks one after another in a background thread until stop()."""
        if self._worker is not None and self._worker.is_alive():
            return
        self.recover()
        self._stop.clear()

        def loop():
            while not self._stop.is_set():
                try:
                    task = self.run_next()
                except Exception as error:  # keep the worker alive; report and go on
                    self._emit("log", {"id": None, "line": f"worker error: {error}"})
                    task = None
                if task is None:
                    self._wake.wait(poll_seconds)
                    self._wake.clear()

        self._worker = threading.Thread(target=loop, name="nansen-task-worker", daemon=True)
        self._worker.start()

    def stop(self, timeout: Optional[float] = None) -> None:
        self._stop.set()
        self._wake.set()
        if self._worker is not None:
            self._worker.join(timeout)

    @property
    def running(self) -> bool:
        return self._worker is not None and self._worker.is_alive()


def run_task(project, task_id: str, on_event: Optional[EventHandler] = None) -> dict:
    """Run one task to its end, keeping its document up to date. Usable from any worker.

    ``project`` is a Project or a project folder.
    """
    from .project import Project

    if not hasattr(project, "folder"):
        project = Project.open(project)
    queue = TaskQueue(project, on_event=on_event)
    task = queue.get(task_id)
    task.update(status="running", startedAt=task.get("startedAt") or now(), progress=0)
    task["log"] = f"tasks/{task_id}.log"
    queue._save(task)
    log_file = open(queue.log_path(task_id), "a", encoding="utf-8")
    cancel_event = threading.Event()
    last_saved = [0.0]

    def on_log(line: str) -> None:
        log_file.write(line + "\n")
        log_file.flush()
        queue._emit("log", {"id": task_id, "line": line})

    def on_progress(fraction: float, message: str) -> None:
        if queue.cancel_path(task_id).exists():
            cancel_event.set()
        task["progress"] = round(fraction, 4)
        if message:
            task["message"] = message
        stamp = dt.datetime.now().timestamp()
        if stamp - last_saved[0] > 0.25 or fraction >= 1:
            last_saved[0] = stamp
            queue._save(task)

    try:
        method = project.method(task["method"]["id"])
        context = MethodContext(project=project, method=method, on_log=on_log, on_progress=on_progress,
                                cancel_event=cancel_event)
        if queue.cancel_path(task_id).exists():
            cancel_event.set()
        entities = [project.entity(ref["entityType"], ref["key"]) for ref in task["entities"]]
        context.log(f"{method.id} {method.version} on {len(entities)} {entities[0].entity_type}(s)")
        results = run_method(method, entities, task["options"]["values"], context)
        task.update(status="completed", progress=1)
        result = _json_result(results if method.batch_mode == "serial" else results[0])
        if result is not None:
            task["result"] = result
        context.log("completed")
    except Cancelled:
        task.update(status="cancelled")
        on_log("cancelled")
    except Exception as error:  # the task failed; the worker goes on
        task.update(status="failed", error={"identifier": type(error).__name__, "message": str(error),
                                            "stack": traceback.format_exc().splitlines()[-20:]})
        on_log(f"failed: {error}")
    finally:
        log_file.close()
        cancel = queue.cancel_path(task_id)
        if cancel.exists():
            cancel.unlink()
    task["finishedAt"] = now()
    queue._save(task)
    queue.release(task_id)
    return task


def _json_result(value: Any) -> Any:
    try:
        text = json.dumps(value, default=str)
    except (TypeError, ValueError):
        return None
    return json.loads(text) if len(text) <= MAX_RESULT_BYTES else None
