"""nansen: validate documents and run the conformance cases."""

from __future__ import annotations

import argparse
import sys
from typing import List, Optional

from .conformance import run_cases
from .documents import read_document
from .errors import NansenError
from .tables import EntityTable


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="nansen")
    commands = parser.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate", help="validate documents (a table sidecar also checks its CSV)")
    validate.add_argument("paths", nargs="+")
    conformance = commands.add_parser("conformance", help="run the conformance cases")
    conformance.add_argument("root", nargs="?", default=None)
    conformance.add_argument("-v", "--verbose", action="store_true")
    app = commands.add_parser("app", help="open the NANSEN app in the browser")
    app.add_argument("project", nargs="?", help="project folder to open")
    app.add_argument("--port", type=int, default=8765)
    app.add_argument("--catalog", default=None, help="project catalog file (default: the user's)")
    app.add_argument("--no-browser", action="store_true")
    app.add_argument("--executor", choices=["thread", "process"], default=None,
                     help="how queued tasks run (default: the user's setting, queue.worker)")
    view = commands.add_parser("view", help="view image stacks or signals without a project (as dev's imviewer, "
                                            "signalviewer and roimanager)")
    view.add_argument("files", nargs="*", help="image stack files: any a stack adapter reads (TIFF, .npy, SciScan .raw, "
                                               "HDF5, video, ...)")
    view.add_argument("--rois", default=None, help="ROIs to show and edit over the first stack (.json as ophys saves them, "
                                                   "saved back there; or dev's roimanager .mat, saved as .json beside it). "
                                                   "Without it, ROIs are saved to <stem>_rois.json beside each stack")
    view.add_argument("--signals", action="append", default=[], metavar="FILE",
                      help="frames x N signals to plot (.npy, or .mat: see --variable); may be given more than once")
    view.add_argument("--variable", default=None, help="the variable of a .mat signals file (default: its only numeric array)")
    view.add_argument("--adapter", default=None, help="the file adapter that reads the stacks (default: the first that opens each)")
    view.add_argument("--frame-rate", type=float, default=None, help="frames per second, when the files do not tell")
    view.add_argument("--port", type=int, default=0, help="the port to serve on (default: any free one)")
    view.add_argument("--catalog", default=None, help="project catalog file (default: the user's)")
    view.add_argument("--no-browser", action="store_true")
    demo = commands.add_parser("demo", help="create a demo project with a small dataset")
    demo.add_argument("folder")
    demo.add_argument("--kind", choices=["sessions", "two-photon"], default="sessions",
                      help="sessions (the default), or two-photon: the quickstart, with synthetic recordings to process")
    legacy = commands.add_parser("import-legacy", help="make a project from a NANSEN dev export (nansen.legacyExport)")
    legacy.add_argument("export", help="the JSON written by nansen.legacy.exportProject in MATLAB")
    legacy.add_argument("folder", help="new, empty project folder")
    worker = commands.add_parser("worker", help="run a project's queued Python tasks, without the app (a worker for "
                                                "tasks a MATLAB app queued for Python)")
    worker.add_argument("project")
    worker.add_argument("--environment", default=None)
    worker.add_argument("--until-empty", action="store_true", help="stop when no task is left for Python")
    worker.add_argument("--poll", type=float, default=1.0, help="seconds between looks at the queue")
    run_task = commands.add_parser("run-task", help="run one queued task of a project (used by worker processes)")
    run_task.add_argument("project")
    run_task.add_argument("task_id")
    run_task.add_argument("--environment", default=None)
    args = parser.parse_args(argv)

    if args.command == "app":
        from .api import Api
        from .catalog import Catalog, default_catalog_path
        from .project import Project
        from .server import run_app

        catalog = Catalog(args.catalog or default_catalog_path())
        project = Project.open(args.project) if args.project else None
        run_app(Api(catalog=catalog, project=project, executor=args.executor,
                    start_queue=catalog.settings()["queue"]["autoStart"]), port=args.port,
                open_browser=not args.no_browser)
        return 0

    if args.command == "view":
        from .api import Api
        from .catalog import Catalog, default_catalog_path
        from .server import run_app
        from .viewables import Viewables, register

        if not args.files and not args.signals:
            parser.error("view: give an image stack file, or --signals")
        try:
            viewables = register(Viewables(), args.files or None, rois=args.rois, signals=args.signals or None,
                                 adapter=args.adapter, variable=args.variable, frame_rate=args.frame_rate)
        except NansenError as error:
            print(f"nansen view: {error.message}", file=sys.stderr)
            return 1
        catalog = Catalog(args.catalog or default_catalog_path())
        run_app(Api(catalog=catalog, viewables=viewables, start_queue=False), port=args.port,
                open_browser=not args.no_browser, page="#/view/" + viewables.list()[0]["id"])
        return 0

    if args.command == "demo":
        from .demo import create_demo_kind

        project = create_demo_kind(args.folder, args.kind)
        print(f"Created {project.title} in {project.folder}. Open it with: nansen app {project.folder}")
        return 0

    if args.command == "import-legacy":
        import json

        from .legacy import convert_legacy

        with open(args.export, encoding="utf-8") as f:
            report = convert_legacy(json.load(f), args.folder)
        counts = ", ".join(f"{n} {name}(s)" for name, n in report["rows"].items()) or "no rows"
        print(f"Created {args.folder}: {counts}, {len(report['dataVariables'])} data variable(s), "
              f"{len(report['fileAdapters'])} file adapter(s), {len(report['methods'])} method(s), "
              f"{len(report['presets'])} preset(s), {report['tasks']} queued task(s) on hold, "
              f"{report['runs']} completed run(s)")
        if report["settings"]:   # app settings are the app's: legacy.import saves them, this command only names them
            print(f"  dev's preferences as settings (save them in the app's Settings): {json.dumps(report['settings'])}")
        for warning in report["warnings"]:
            print(f"  note: {warning}")
        return 0

    if args.command == "worker":
        from .project import Project
        from .tasks import TaskQueue, run_worker

        queue = TaskQueue(Project.open(args.project, environment=args.environment))
        done = run_worker(queue, until_empty=args.until_empty, poll_seconds=args.poll,
                          report=lambda task: print(f"{task['status']:<9} {task['method']['id']} {task['id']}", flush=True))
        return 0 if all(t["status"] in ("completed", "cancelled") for t in done) else 1

    if args.command == "run-task":
        from .project import Project
        from .tasks import run_task as run

        task = run(Project.open(args.project, environment=args.environment), args.task_id)
        return 0 if task["status"] in ("completed", "cancelled") else 1

    if args.command == "validate":
        failed = 0
        for path in args.paths:
            try:
                document = read_document(path)
                if document["schemaType"] == "nansen.table":
                    EntityTable.read(path)
                print(f"ok    {path}")
            except NansenError as error:
                failed += 1
                print(f"FAIL  {path}: {error}")
        return 1 if failed else 0

    results = run_cases(args.root)
    failed = [r for r in results if not r.passed]
    for result in results:
        if args.verbose or not result.passed:
            status = "ok  " if result.passed else "FAIL"
            print(f"{status}  {result.kind}/{result.name}" + (f": {result.detail}" if result.detail else ""))
    print(f"{len(results) - len(failed)} of {len(results)} cases passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
