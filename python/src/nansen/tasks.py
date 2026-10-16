"""The task queue: methods queued on entities, run in the background, kept as nansen.task documents.

A task file describes everything a worker needs, so a task can run in a
thread of this process, in a separate Python process, or in MATLAB. While a
task runs its worker owns the file; anyone else asks it to stop by creating
tasks/<id>.cancel. A worker of the other language or another process writes
task files without telling this app, so an app that shows the queue watches
the folder (TaskQueue.watch) and reports what changed there as events.
"""

from __future__ import annotations

import copy
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
from . import runs
from .methods import Cancelled, MethodContext, run_method
from .schemas import current_version

TERMINAL = ("completed", "failed", "cancelled")


def queue_position(task: dict) -> tuple:
    """Where a queued task stands in the queue: by its order when it was given one, else after those, by creation."""
    order = task.get("order")
    return (0, order, task["createdAt"], task["id"]) if order is not None else (1, 0, task["createdAt"], task["id"])
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
        self._last_created = ""
        self._created_lock = threading.Lock()  # creation times this queue gives out only grow, so tasks keep the order they were queued in
        self._lock = threading.Lock()
        # Watching the folder (watch, poll_changes): each task file's stat at the last look (None before the first), the
        # last document reported of each task (None once it was reported removed), and the thread that looks
        self._seen: Optional[Dict[str, tuple]] = None
        self._known: Dict[str, Optional[str]] = {}
        self._watch_lock = threading.Lock()
        self._watcher: Optional[threading.Thread] = None
        self._unwatch = threading.Event()

    # -- documents ----------------------------------------------------------------------------

    def path(self, task_id: str) -> Path:
        return self.folder / f"{task_id}.task.nansen.json"

    def log_path(self, task_id: str) -> Path:
        return self.folder / f"{task_id}.log"

    def cancel_path(self, task_id: str) -> Path:
        return self.folder / f"{task_id}.cancel"

    def claim_path(self, task_id: str) -> Path:
        return self.folder / f"{task_id}.claim"

    def _created_at(self) -> str:
        """Now, or a millisecond after the last task this queue made when that is not earlier: tasks queued
        within one millisecond would otherwise be ordered by their random ids."""
        with self._created_lock:
            created = now()
            if created <= self._last_created:
                later = dt.datetime.fromisoformat(self._last_created) + dt.timedelta(milliseconds=1)
                created = later.isoformat(timespec="milliseconds")
            self._last_created = created
            return created

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
        # what was reported, so a look at the folder does not report this queue's own changes again
        if kind == "task":
            self._known[data["id"]] = json.dumps(data, sort_keys=True)
        elif kind == "removed":
            self._known[data["id"]] = None
        if self.on_event is not None:
            self.on_event(kind, data)

    def _save(self, document: dict) -> None:
        self.folder.mkdir(exist_ok=True)
        write_task(self.path(document["id"]), document)
        # A copy: the worker keeps changing its document while listeners may serialize later.
        self._emit("task", copy.deepcopy(document))

    # -- queueing -----------------------------------------------------------------------------

    def submit(self, method_id: str, entities: List[Any], options: Optional[Dict[str, Any]] = None,
               preset: Optional[str] = None, language: Optional[str] = None, skip_completed: bool = False) -> dict:
        """Queue a method on entities. Options are resolved and validated now, so a queued task is runnable.

        With skip_completed, the task leaves out, when it runs, the entities the method already completed on whose
        outputs are there (Project.already_done), and lists them as skipped."""
        method = self.project.method(method_id)
        if not method.queueable:
            raise NansenError("not-queueable", f"method {method_id!r} cannot run in the background")
        if not entities:
            raise NansenError("no-entities", "a task needs at least one entity")
        for entity in entities:
            if not method.applies_to(entity.entity_type):
                raise NansenError("wrong-entity-type", f"{method.id} runs on {method.entity_type}")
        task = self._make(method, entities, options, preset, language)
        if skip_completed:
            task["skipCompleted"] = True
        self._save(task)
        self._wake.set()
        return task

    def _make(self, method, entities, options, preset, language, after=None, pipeline=None) -> dict:
        values = self.project.preset(method.id, preset) if preset else {}
        values = method.resolve_options(dict(values, **(options or {})))
        task = {
            "schemaType": "nansen.task",
            "schemaVersion": current_version("nansen.task"),
            "id": str(uuid.uuid4()),
            "method": {"id": method.id, "version": method.version},
            "entities": [{"entityType": e.entity_type, "key": dict(e.key)} for e in entities],
            "options": {"values": values},
            "status": "queued",
            "createdAt": self._created_at(),
            "progress": 0,
        }
        if preset:
            task["options"]["preset"] = preset
        if not language and method.languages and "python" not in method.languages:
            language = method.languages[0]   # only the other language runs it: that language's worker takes it
        if language:
            task["language"] = language
        if after:
            task["after"] = list(after)
        if pipeline:
            task["pipeline"] = pipeline
        return task

    def submit_pipeline(self, pipeline_id: str, entities: List[Any], language: Optional[str] = None,
                        skip: Optional[Dict[Any, set]] = None) -> List[dict]:
        """Queue a pipeline: per entity, one task per step, each waiting for the step before.

        skip maps an entity's key id (runs.key_id) to the numbers of the steps to leave out, as when only
        the steps not done yet are queued.
        """
        pipeline = self.project.pipeline(pipeline_id)
        if not entities:
            raise NansenError("no-entities", "a pipeline needs at least one entity")
        steps = []
        for step in pipeline["steps"]:
            method = self.project.method(step["method"])
            for entity in entities:
                if not method.applies_to(entity.entity_type):
                    raise NansenError("wrong-entity-type", f"{method.id} runs on {method.entity_type}")
            steps.append((method, step))
        tasks = []
        for entity in entities:
            run, previous = str(uuid.uuid4()), None
            left_out = (skip or {}).get(runs.key_id(entity.key), set())
            for number, (method, step) in enumerate(steps):
                if number in left_out:
                    continue
                info = {"id": pipeline["id"], "run": run, "step": number, "steps": len(steps),
                        "title": step.get("title", method.title)}
                task = self._make(method, [entity], step.get("options"), step.get("preset"), language,
                                  after=[previous["id"]] if previous else None, pipeline=info)
                tasks.append(task)
                previous = task
        for task in tasks:  # validated every step before writing any
            self._save(task)
        self._wake.set()
        return tasks

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

    def retry(self, task_id: str, skip_completed: Optional[bool] = None) -> dict:
        """Queue a finished task again, as a new task with the same method, entities and options (dev's Restart).

        A stack the task was writing when it stopped is gone on with where it stopped (nansen.progress). With
        skip_completed (when given; else as the task had it), the entities it already completed on are left out."""
        old = self.get(task_id)
        if old["status"] not in TERMINAL:
            raise NansenError("task-active", f"task {task_id} is {old['status']}")
        task = {k: v for k, v in old.items() if k in ("schemaType", "schemaVersion", "method", "entities", "options",
                                                       "language", "pipeline", "skipCompleted")}
        if skip_completed is not None:
            task.pop("skipCompleted", None)
            if skip_completed:
                task["skipCompleted"] = True
        task.update(id=str(uuid.uuid4()), status="queued", createdAt=self._created_at(), progress=0)
        self._save(task)
        self._wake.set()
        return task

    # -- changing queued tasks ------------------------------------------------------------------

    def _change_queued(self, task_id: str, change: Callable[[dict], None]) -> Optional[dict]:
        """Change a queued task while holding its claim, so no worker starts it meanwhile.

        Returns the changed task, or None when a worker is taking it right now."""
        self.get(task_id)  # unknown-task
        if not self.claim(task_id):
            return None
        try:
            task = self.get(task_id)
            if task["status"] != "queued":
                raise NansenError("task-not-queued", f"task {task_id} is {task['status']}")
            change(task)
            check_document(task, "nansen.task")
            self._save(task)
            return task
        finally:
            self.release(task_id)

    def _require_changed(self, task_id: str, task: Optional[dict]) -> dict:
        if task is None:
            raise NansenError("task-not-queued", f"task {task_id} is being started")
        self._wake.set()
        return task

    def hold(self, task_id: str, hold: bool = True) -> dict:
        """Keep a queued task from starting (hold) or let it start again; it keeps its place in the queue."""
        def change(task):
            if hold:
                task["onHold"] = True
            else:
                task.pop("onHold", None)
        return self._require_changed(task_id, self._change_queued(task_id, change))

    def update(self, task_id: str, options: Optional[Dict[str, Any]] = None, preset: Optional[str] = None) -> dict:
        """Give a queued task new options: the preset's values (if given) with these on top, resolved and validated."""
        method = self.project.method(self.get(task_id)["method"]["id"])
        values = self.project.preset(method.id, preset) if preset else {}
        values = method.resolve_options(dict(values, **(options or {})))

        def change(task):
            task["options"] = {"values": values}
            if preset:
                task["options"]["preset"] = preset
            task["method"]["version"] = method.version
        return self._require_changed(task_id, self._change_queued(task_id, change))

    def comment(self, task_id: str, text: str) -> dict:
        """A note on a queued or finished task (dev's Comment column); an empty one takes it away. A running task's file
        is its worker's to write, so it is commented on before it starts or once it is done."""
        text = str(text or "").strip()

        def change(task):
            if text:
                task["comment"] = text
            else:
                task.pop("comment", None)
        task = self.get(task_id)
        if task["status"] == "queued":
            return self._require_changed(task_id, self._change_queued(task_id, change))
        if task["status"] not in TERMINAL:
            raise NansenError("task-running", f"task {task_id} is {task['status']}: comment on it once it is done")
        change(task)
        check_document(task, "nansen.task")
        self._save(task)
        return task

    def reorder(self, task_ids: List[str]) -> List[dict]:
        """Put these queued tasks first, in this order; the other queued tasks follow in the order they had.

        Returns the queued tasks in their new order. A task cannot run before the tasks it waits for,
        whatever its place."""
        queued = sorted(self.list("queued"), key=queue_position)
        known = {t["id"] for t in queued}
        for task_id in task_ids:
            if task_id not in known:
                self.get(task_id)  # unknown-task
                raise NansenError("task-not-queued", f"task {task_id} is not queued")
        if len(set(task_ids)) != len(task_ids):
            raise NansenError("invalid-params", "a task is listed twice")
        first = {task_id: i for i, task_id in enumerate(task_ids)}
        ordered = sorted(queued, key=lambda t: (0, first[t["id"]]) if t["id"] in first else (1, queue_position(t)))
        result = []
        for i, task in enumerate(ordered):
            if task.get("order") != i:
                try:
                    task = self._change_queued(task["id"], lambda t, i=i: t.update(order=i)) or task
                except NansenError:
                    continue  # it left the queue meanwhile
            result.append(task)
        self._wake.set()
        return result

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
        """Mark Python tasks left 'running' by a worker that died as failed. Call when no Python worker is running;
        a MATLAB worker's tasks are its own."""
        recovered = []
        for task in self.list("running"):
            if task.get("language", "python") != "python":
                continue
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
        """The oldest queued task this worker can run now: its own language, not claimed, and every
        task it waits for completed. A task waiting for one that failed or was cancelled is cancelled."""
        tasks = self.list()
        status = {t["id"]: t["status"] for t in tasks}
        for task in sorted((t for t in tasks if t["status"] == "queued"), key=queue_position):
            waiting = [status.get(other, "missing") for other in task.get("after", [])]
            if any(s in ("failed", "cancelled", "missing") for s in waiting):
                task.update(status="cancelled", finishedAt=now(),
                            error={"message": "an earlier step did not complete"})
                self._save(task)
                status[task["id"]] = "cancelled"
                continue
            if any(s != "completed" for s in waiting) or task.get("onHold"):
                continue
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
                    if task["status"] == "queued" and not task.get("onHold"):
                        break
                    self.release(task["id"])
            task.update(status="running", startedAt=now(), progress=0)
            self._save(task)
        if self.executor == "process":
            self._run_in_process(task["id"])
        else:
            run_task(self.project, task["id"], on_event=self._emit)
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

    # -- watching the folder ------------------------------------------------------------------

    def _stats(self) -> Dict[str, tuple]:
        """Each task file's modification time, size and inode (a file replaced atomically is a new inode)."""
        found = {}
        for path in self.folder.glob("*.task.nansen.json") if self.folder.is_dir() else []:
            try:
                stat = path.stat()
            except OSError:
                continue  # removed meanwhile
            found[path.name[: -len(".task.nansen.json")]] = (stat.st_mtime_ns, stat.st_size, stat.st_ino)
        return found

    def poll_changes(self) -> List[str]:
        """Report the task files changed by others since the last look: a worker of the other language, a headless
        worker (nansen worker) or a task run in another process writes them without telling this app. Emits a task
        event for each task file that is new or changed and whose document differs from the one last reported, and
        removed for each one gone; returns their ids. The first look only takes stock."""
        with self._watch_lock:
            current = self._stats()
            if self._seen is None:
                self._seen = current
                return []
            changed = []
            for task_id, stat in list(current.items()):
                if self._seen.get(task_id) == stat:
                    continue
                try:
                    document = read_document(self.path(task_id), "nansen.task")
                except NansenError:   # being replaced, or broken: looked at again next time
                    if task_id in self._seen:
                        current[task_id] = self._seen[task_id]
                    else:
                        del current[task_id]
                    continue
                if self._known.get(task_id) != json.dumps(document, sort_keys=True):
                    self._emit("task", document)
                    changed.append(task_id)
            for task_id in set(self._seen) - set(current):
                if not (task_id in self._known and self._known[task_id] is None):   # not reported removed already
                    self._emit("removed", {"id": task_id})
                    changed.append(task_id)
                self._known.pop(task_id, None)
            self._seen = current
            return changed

    def watch(self, period: float = 0.5) -> None:
        """Look at the task files every period seconds in a background thread (poll_changes), until unwatch(): what
        others change there reaches on_event as this queue's own changes do. A look is a stat of each file; a file is
        read only when it changed."""
        if self._watcher is not None and self._watcher.is_alive():
            return
        self._unwatch.clear()
        self.poll_changes()   # take stock now: changes from here on are reported

        def loop():
            while not self._unwatch.wait(period):
                try:
                    self.poll_changes()
                except Exception:  # the folder unreadable for a moment; look again next time
                    pass

        self._watcher = threading.Thread(target=loop, name="nansen-task-watch", daemon=True)
        self._watcher.start()

    def unwatch(self, timeout: Optional[float] = None) -> None:
        self._unwatch.set()
        if self._watcher is not None:
            self._watcher.join(timeout)
        self._watcher = None

    @property
    def watching(self) -> bool:
        return self._watcher is not None and self._watcher.is_alive()


def run_worker(queue: "TaskQueue", until_empty: bool = False, poll_seconds: float = 1.0,
               report: Optional[Callable[[dict], None]] = None) -> List[dict]:
    """Run the queue's tasks for this language one after another, in this thread: a worker without an app (``nansen
    worker``). With until_empty it returns when none is left (tasks for another language are left alone); otherwise
    it runs until interrupted. Returns the tasks it ran."""
    import time

    done = []   # no recover: an app's worker may be running a task as this one starts
    try:
        while True:
            task = queue.run_next()
            if task is not None:
                done.append(task)
                if report:
                    report(task)
            elif until_empty:
                return done
            else:
                time.sleep(poll_seconds)
    except KeyboardInterrupt:
        return done


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
        if task.get("skipCompleted"):   # those it already ran on, with their outputs there, are left out
            done = project.already_done(method.id, entities, task["options"]["values"])
            task["skipped"] = [dict(e.key) for e, d in zip(entities, done) if d]
            for entity in (e for e, d in zip(entities, done) if d):
                context.log(f"skipped {entity.key}: {method.id} already ran on it and its outputs are there")
            entities = [e for e, d in zip(entities, done) if not d]
        results = run_method(method, entities, task["options"]["values"], context,
                             on_done=lambda finished: runs.record(project.folder, method.id, method.version, finished, task_id))
        task.update(status="completed", progress=1)
        result = _json_result(results if method.batch_mode == "serial" else results[0]) if results else None
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
