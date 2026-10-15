"""Convert a NANSEN dev project into a nansen-core project.

A dev project keeps its tables and settings in ``.mat`` files, and its MetaTables are MATLAB ``table``
objects, which only MATLAB can read. So the import has two steps. MATLAB's
``nansen.legacy.exportProject`` reads the dev files and writes what they say as a ``nansen.legacyExport``
document: plain JSON, with no MATLAB types left in it. ``convert_legacy`` turns that document into a
project, here or in MATLAB (``nansen.legacy.convert``); the conformance cases in ``conformance/legacy``
hold both to the same result.

What maps over:

- the project's name and description;
- data locations, with their roots, folder levels and metadata rules, become a DSM config;
- the master MetaTables of sessions and subjects become entity tables. ``Ignore`` and ``Description``
  go to ``core.notes``; other columns go to a ``legacy.<entityType>`` fragment in the project. An entity
  type the dataset has but dev kept no table of gets an empty table with ``core.notes``;
- file path settings become data variables, when their file adapter has an equivalent: built in, or in the ophys
  module for dev's ROI files (RoiArray, RoiGroup) and image stacks (ImageStack of TIFF, dev's binary or SciScan raw,
  HDF5 or npy files). A variable dev kept in a .mat file under its own name (its Default adapter, and RoiSignalArray,
  which kept all the ROI signals in one file) is that variable of the file (variableInFile);
- the notes of a ``Notebook`` column go into the entity type's notebook, in the order they were written;
- the project's own session methods (``code/+<package>/+sessionmethod``) become methods of sessions that run dev's
  code unchanged in MATLAB (``nansen.legacymethods``), and pipeline tasks that call them become steps;
- the project's own file adapters (``code/+<package>/+fileadapter``: classes and function-based ones) become file
  adapters that run dev's code unchanged in MATLAB (``nansen.legacyadapters``), and the variables dev read with them
  data variables;
- the option presets users made become presets of the methods here: those of the project's own session methods as
  they are, those of NoRMCorre and Quicky with dev's options mapped to the module's (``DEV_OPTIONS``); dev's chosen
  default preset becomes the method's preferred preset;
- the queued tasks of dev's task list become queued tasks, on hold; the completed tasks of its history and the
  finished tasks of the ``Progress`` column become lines of the run journal, and the column's pipeline the session's
  pipeline (``core.pipeline``);
- dev's app preferences that are app settings here are in the report's ``settings`` (``legacy.import`` saves them).

Whatever cannot be mapped is left out and named in the report's ``warnings``.
"""

from __future__ import annotations

import json
import re
from pathlib import Path, PurePosixPath
from typing import Any, Dict, List, Optional, Tuple

from . import legacyadapters, legacymethods
from .documents import PathLike, check_document, write_json
from .errors import NansenError
from .project import Project
from .tables import Column

LOCATION_CATEGORY = {"recorded": ("raw", "read"), "processed": ("processed", "readwrite"),
                     "curated": ("derived", "readwrite"), "temporary": ("temporary", "readwrite")}
LEVEL_KINDS = {"subject": ("subjects", "subject"), "session": ("sessions", "session"), "date": ("dates", None)}
METADATA = {"Subject ID": ("subject_id", "string", "subject"), "Session ID": ("session_id", "string", "session"),
            "Experiment Date": ("session_date", "date", "session"), "Experiment Time": ("session_time", "time", "session")}
ID_COLUMNS = {"sessionID": "session_id", "SessionID": "session_id", "subjectID": "subject_id", "SubjectID": "subject_id"}
NOTES = {"Ignore": "ignore", "Description": "description"}
# dev's subject table variables, in core.subject when their type matches: dev name -> (column, type)
SUBJECT = {"DateOfBirth": ("date_of_birth", "date"), "BiologicalSex": ("sex", "string"), "Species": ("species", "string")}
SEXES = ("female", "male", "not detected")
NOTE_TYPES = {"informal": "informal", "important": "important", "todo": "todo", "question": "question"}
# Columns the dev tables filled from the folder names; the DSM attributes hold them now.
DERIVED = {"session": {"Date": "session_date", "Time": "session_time"}}
ADAPTERS_BY_TYPE = {".mat": "mat", ".json": "json", ".txt": "text"}
ADAPTERS_BY_NAME = {"default": None, "": None, "matfile": "mat", "mat": "mat", "json": "json", "text": "text",
                    "roiarray": "ophys.nansen_roi_array", "roigroup": "ophys.nansen_roi_array", "roisignalarray": "mat"}
# dev's ImageStack adapter read stacks of many file types; the ophys module's adapters read these (a .raw is dev's
# own binary stack, or SciScan's: ophys.binary_stack reads both)
STACK_ADAPTERS_BY_TYPE = {".tif": "ophys.tiff_stack", ".tiff": "ophys.tiff_stack", ".raw": "ophys.binary_stack",
                          ".bin": "ophys.binary_stack", ".dat": "ophys.binary_stack",
                          ".h5": "ophys.hdf5_stack", ".hdf5": "ophys.hdf5_stack", ".npy": "npy"}
# dev saved these as one named variable of a .mat file (its Default adapter, its RoiSignalArray: several in one file)
NAMED_IN_FILE = {"default", "", "roisignalarray"}
# dev's session methods, by the end of their function name, and the method that does the same here
DEV_METHODS = {"motioncorrection.normcorre": "ophys.normcorre", "motioncorrection.flowreg": "ophys.flowreg",
               "autosegmentation.quicky": "ophys.quicky", "autosegmentation.suite2p": "ophys.suite2p",
               "autosegmentation.extract": "ophys.extract", "signalextraction.extractsignals": "ophys.extract_signals",
               "signalextraction.extractsignalsmultichannel": "ophys.extract_signals",
               "signalextraction.computedff": "ophys.compute_dff", "deconvolution.caiman": "ophys.caiman_deconvolution",
               "imageprocessing.downsamplestack": "ophys.downsample", "imageprocessing.denoisestack": "ophys.deep_interpolation",
               "data.backup": "core.backup"}


# dev's option presets of those methods, by name (any case; spaces and hyphens as _), and the module preset that holds
# the same values here: dev's Default of Quicky is its Soma values, of NoRMCorre its 4 x 4 nonrigid
DEV_PRESETS = {"ophys.quicky": {"default": "soma", "soma": "soma", "soma_virus": "soma_virus", "axon": "axon"},
               "ophys.normcorre": {"default": "nonrigid", "nonrigid": "nonrigid", "rigid": "rigid"}}
# dev keeps the presets of those methods under the class that defines their options (OptionsManager's file name)
DEV_OPTION_FUNCTIONS = {"nansen.wrapper.normcorre.Processor": "ophys.normcorre",
                        "nansen.wrapper.quicky.Processor": "ophys.quicky"}
# dev's options of those methods (nansen.wrapper.normcorre.Options, flufinder.getDefaultOptions), by their path, and the
# module method's option of the same meaning (None: covered by another; numCols is patches as numRows is)
DEV_OPTIONS = {"ophys.normcorre": [("Configuration.numRows", "patches"), ("Configuration.numCols", None),
                                   ("Configuration.patchOverlap", "overlap"), ("Template.initialBatchSize", "initialBatchSize"),
                                   ("Template.updateTemplate", "updateTemplate"), ("Template.binWidth", "binWidth"),
                                   ("Correction.maximumShift", "maxShift"), ("Correction.maximumDeviation", "maxDeviation"),
                                   ("Correction.subpixelUpsampling", "upsampling"), ("Correction.numIterations", "iterations")],
               "ophys.quicky": [("General.RoiDiameter", "roiDiameter"), ("Preprocessing.BinningSize", "binSize"),
                                ("Preprocessing.SmoothingSigma", "smoothingSigma"),
                                ("Detection.PrctileForBinarization", "binarizationPercentile"),
                                ("Detection.NumObservationsRequired", "observationsRequired"),
                                ("Detection.MaxNumRois", "maxRois"), ("Detection.UseShapeDetection", "useShapeDetection"),
                                ("Detection.InnerRadius", "innerRadius"), ("Detection.OuterRadius", "outerRadius")]}


def _dev_preset(method: str, name: str) -> Optional[str]:
    return DEV_PRESETS.get(method, {}).get(re.sub(r"[\s-]+", "_", name.strip().lower()))


def convert_legacy(export: dict, folder: PathLike) -> dict:
    """Write a project into ``folder`` from a ``nansen.legacyExport`` document; returns a report."""
    export = check_document(export, "nansen.legacyExport")
    plan = plan_legacy(export)
    folder = Path(folder)
    if folder.exists() and any(folder.iterdir()):
        raise NansenError("folder-not-empty", f"{folder} is not empty")
    folder.mkdir(parents=True, exist_ok=True)
    write_json(folder / "dataset.dsm.json", plan["dataset"])
    project = Project.create(folder, plan["name"], plan["title"], dataset="dataset.dsm.json",
                             description=plan["description"] or None)
    legacyadapters.write(folder, plan["fileAdapters"])   # before the modules, whose adding reads the adapters again
    for module in plan["modules"]:
        project.add_module(module)
    for fragment in plan["fragments"]:
        project.add_fragment(fragment)
    rows: Dict[str, int] = {}
    notes: Dict[str, int] = {}
    for table in plan["tables"]:
        key = [Column(name, data_type) for name, data_type in table["key"]]
        entity_table = project.add_entity_type(table["entityType"], key=key, fragments=table["fragments"],
                                               title=table["title"])
        for row in table["rows"]:
            entity_table.add(row)
        entity_table.write()
        rows[table["entityType"]] = len(table["rows"])
        for view in table.get("views", []):
            project.views(table["entityType"]).save(view)
        if table["notes"]:
            notebook = project.notebook(table["entityType"])
            for note in table["notes"]:
                notebook.add(note["key"], note["text"], title=note["title"], note_type=note["type"],
                             author=note["author"], created_at=note["createdAt"])
            notes[table["entityType"]] = len(table["notes"])
    for variable in plan["dataVariables"]:
        project.add_data_variable(variable)
    legacymethods.write(project, plan["methods"])
    warnings = list(plan["warnings"])
    presets = []
    for preset in plan["presets"]:
        method = project.method(preset["method"])
        where = f"option preset '{preset['name']}' of {method.id}"
        project.save_preset(method.id, preset["name"], _fitting(method, preset["values"], where, warnings),
                            preset["description"])
        presets.append(f"{method.id}/{preset['name']}")
    for preferred in plan["preferredPresets"]:
        project.set_preferred_preset(preferred["method"], preferred["preset"])
    for pipeline in plan["pipelines"]:
        project.save_pipeline(pipeline)
    tasks = _write_tasks(project, plan["tasks"], warnings)
    _write_runs(project, plan["runs"])
    return {"project": str(folder), "rows": rows, "notes": notes,
            "dataVariables": [v["name"] for v in plan["dataVariables"]],
            "fileAdapters": [a["document"]["id"] for a in plan["fileAdapters"]],
            "methods": [m["document"]["id"] for m in plan["methods"]],
            "presets": presets, "pipelines": [p["id"] for p in plan["pipelines"]], "tasks": tasks,
            "runs": len(plan["runs"]), "settings": plan["settings"], "warnings": warnings}


def _fitting(method, values: dict, where: str, warnings: List[str]) -> dict:
    """The values of the options the method's options schema has, or does not name, less those of a value it refuses."""
    from jsonschema import Draft7Validator

    properties = method.options_schema.get("properties", {})
    kept = {}
    for name, value in values.items():
        if name in properties and not Draft7Validator(properties[name]).is_valid(value):
            warnings.append(f"{where}: option '{name}' does not fit the method's options; left out")
            continue
        kept[name] = value
    return kept


def _write_tasks(project: Project, planned: List[dict], warnings: List[str]) -> int:
    """dev's queued tasks as queued tasks on hold, in dev's queue order, so nothing runs before it is released."""
    import uuid

    from .schemas import current_version
    from .tasks import now, write_task

    count = 0
    for item in planned:
        method = project.method(item["method"])
        where = f"queued task '{item['name']}' ({method.id})"
        if not method.queueable:
            warnings.append(f"{where}: {method.id} cannot run as a background task; left out")
            continue
        base = project.preset(method.id, item["preset"]) if item.get("preset") else {}   # dev's options over its preset's
        values = method.resolve_options(dict(base, **_fitting(method, item["values"], where, warnings)))
        task: Dict[str, Any] = {"schemaType": "nansen.task", "schemaVersion": current_version("nansen.task"),
                                "id": str(uuid.uuid4()), "method": {"id": method.id, "version": method.version},
                                "entities": [{"entityType": "session", "key": key} for key in item["entities"]],
                                "options": {"values": values}, "status": "queued",
                                "createdAt": item.get("createdAt") or now(), "progress": 0}
        if item.get("preset"):
            task["options"]["preset"] = item["preset"]
        if len(method.languages) == 1:   # only that language's worker takes it
            task["language"] = method.languages[0]
        task["order"] = count
        task["onHold"] = True
        if item.get("comment"):
            task["comment"] = item["comment"]
        (project.folder / "tasks").mkdir(exist_ok=True)
        write_task(project.folder / "tasks" / f"{task['id']}.task.nansen.json", task)
        count += 1
    return count


def _write_runs(project: Project, planned: List[dict]) -> None:
    """What dev recorded as done (its task history and Progress column) as lines of the run journal."""
    if not planned:
        return
    from .schemas import current_version

    versions = {}
    lines = []
    for run in planned:
        if run["method"] not in versions:
            versions[run["method"]] = project.method(run["method"]).version
        line = {"schemaType": "nansen.run", "schemaVersion": current_version("nansen.run"),
                "method": {"id": run["method"], "version": versions[run["method"]]}, "key": run["key"],
                "finishedAt": run["finishedAt"]}
        lines.append(json.dumps(check_document(line, "nansen.run"), ensure_ascii=False) + "\n")
    (project.folder / "runs").mkdir(exist_ok=True)
    with open(project.folder / "runs" / "session.runs.jsonl", "a", encoding="utf-8", newline="\n") as f:
        f.write("".join(lines))


def plan_legacy(export: dict) -> dict:
    """Work out every document of the new project, without writing anything."""
    warnings: List[str] = []
    info = export.get("project", {})
    dataset, levels = _dataset(export, warnings)
    adapters = _file_adapters(export, warnings)
    by_name: Dict[str, str] = {}   # dev's name of each of the project's own file adapters (any case) -> its id
    for adapter in adapters:
        by_name.setdefault(adapter["name"].lower(), adapter["document"]["id"])
    variables = _data_variables(export, dataset, levels, by_name, warnings)
    fragments, tables = _tables(export, dataset, warnings)
    methods = _session_methods(export, warnings)
    imported = {m["function"]: m["document"]["id"] for m in methods}
    preset_warnings: List[str] = []
    presets, preferred, preset_names = _presets(export, imported, preset_warnings)
    pipelines, pipeline_ids = _pipelines(export, imported, preset_names, warnings)
    warnings.extend(preset_warnings)
    session = next((t for t in tables if t["entityType"] == "session"), None)
    runs = _progress(tables, pipeline_ids, imported, warnings)
    tasks, done = _task_list(export, session, imported, preset_names, warnings)
    runs = _ordered_runs(done + runs)
    for table in tables:
        table.pop("progress", None)
    if pipelines:   # sessions keep the pipeline they follow, and its progress, in core.pipeline
        for table in tables:
            if table["entityType"] == "session" and "core.pipeline" not in table["fragments"]:
                table["fragments"].append("core.pipeline")
    name = _identifier(info.get("shortName") or info.get("name") or "imported", "p", sep="_", lower=False)
    # the ophys module, when a variable is read by one of its adapters (dev's ROI files and image stacks), or a
    # pipeline, preset, task or completed run is of one of its methods
    uses_ophys = any(v["fileAdapter"].startswith("ophys.") for v in variables) or \
        any(step["method"].startswith("ophys.") for p in pipelines for step in p["steps"]) or \
        any(item["method"].startswith("ophys.") for item in presets + tasks + runs)
    modules = ["core"] + (["ophys"] if uses_ophys else [])
    return {"name": name, "title": info.get("name") or name, "description": info.get("description") or "",
            "dataset": dataset, "modules": modules, "fragments": fragments, "tables": tables, "dataVariables": variables,
            "fileAdapters": adapters, "methods": methods, "presets": presets, "preferredPresets": preferred,
            "pipelines": pipelines, "tasks": tasks, "runs": runs, "settings": _settings(export), "warnings": warnings}


# -- session methods, pipelines and presets ----------------------------------------------------

def _session_methods(export: dict, warnings: List[str]) -> List[dict]:
    """The project's own session methods, as methods of sessions that run dev's code (legacymethods.plan)."""
    sources = [(item["file"], legacymethods.function_name(PurePosixPath(item["file"])), item["text"])
               for item in export.get("sessionMethods", [])]
    methods, skipped = legacymethods.plan(sources, "session")
    warnings.extend(skipped)
    return methods


def _file_adapters(export: dict, warnings: List[str]) -> List[dict]:
    """The project's own file adapters (code/+<package>/+fileadapter), as file adapters that run dev's code in MATLAB
    (legacyadapters.plan)."""
    entries, skipped = legacyadapters.plan([(item["file"], item["text"]) for item in export.get("fileAdapters", [])])
    warnings.extend(skipped)
    return entries


def _method_of(function: str, imported: Dict[str, str]) -> Optional[str]:
    """The method here of a dev function: one of the project's own session methods, imported, or the equivalent of one
    of dev's (by the end of its name, or the class whose options its presets are kept under)."""
    return imported.get(function) or DEV_OPTION_FUNCTIONS.get(function) or \
        DEV_METHODS.get(".".join(function.split(".")[-2:]).lower())


def _pipelines(export: dict, imported: Dict[str, str], preset_names: Dict[Tuple[str, str], str],
               warnings: List[str]) -> Tuple[List[dict], Dict[str, str]]:
    """dev's pipelines of sessions, with the tasks that have a method here (one of dev's that has an equivalent, or
    one of the project's own session methods, imported), and their rules for new sessions; and each one's id by dev's
    name of it."""
    pipelines: List[dict] = []
    ids: set = set()
    by_name: Dict[str, str] = {}
    for item in export.get("pipelines", []):
        label = item.get("name", "")
        steps = []
        for task in item.get("tasks", []):
            function = str(task.get("function") or "")
            method = imported.get(function) or DEV_METHODS.get(".".join(function.split(".")[-2:]).lower())
            if method is None:
                warnings.append(f"pipeline '{label}': task '{task.get('name', '')}' ({function}) has no method here; left out")
                continue
            step = {"method": method, "title": str(task.get("name") or method)}
            preset = str(task.get("preset") or "")
            if preset and (method, preset) in preset_names:   # a preset a user made, imported
                step["preset"] = preset_names[(method, preset)]
            elif _dev_preset(method, preset or "default"):   # the module's preset of dev's values
                step["preset"] = _dev_preset(method, preset or "default")
            elif preset and preset.lower() != "default":
                warnings.append(f"pipeline '{label}': task '{task.get('name', '')}' used dev's option preset '{preset}', "
                                "which is not carried over; the method's defaults are used")
            steps.append(step)
        if not steps:
            warnings.append(f"pipeline '{label}': none of its tasks has a method here; left out")
            continue
        document: Dict[str, Any] = {"schemaType": "nansen.pipeline", "schemaVersion": "0.1.0",
                                    "id": "legacy." + _unique(_identifier(label, "pipeline", sep="_", lower=True), ids),
                                    "version": "1.0.0", "title": label or "Imported pipeline", "entityType": "session", "steps": steps}
        rules = []
        for rule in item.get("assign", []):
            column = ID_COLUMNS.get(rule.get("variable", ""), _identifier(rule.get("variable", ""), "column", sep="_", lower=False))
            mode = str(rule.get("mode") or "").lower()
            if mode not in ("contains", "match"):
                warnings.append(f"pipeline '{label}': an assignment rule of mode '{mode}' is not carried over")
                continue
            rules.append({"column": column, "op": "contains" if mode == "contains" else "in", "values": [str(rule.get("expression") or "")]})
        if rules:
            document["assignWhen"] = rules
        pipelines.append(document)
        by_name.setdefault(label, document["id"])
    return pipelines, by_name


def _presets(export: dict, imported: Dict[str, str], warnings: List[str]) \
        -> Tuple[List[dict], List[dict], Dict[Tuple[str, str], str]]:
    """The option presets users made in dev (OptionsManager's Custom entries), as presets of the method here: those of
    the project's own session methods as dev saved them, those of NoRMCorre and Quicky with dev's options mapped to the
    module method's (DEV_OPTIONS). Returns the presets {method, name, description, values}, the preferred presets
    (dev's DefaultOptionsName, when a user chose one) and each preset's name here by (method, dev's name)."""
    presets: List[dict] = []
    preferred: List[dict] = []
    names: Dict[Tuple[str, str], str] = {}
    used: Dict[str, set] = {}
    for item in export.get("presets", []):
        function = str(item.get("function") or "")
        listed = ", ".join(item.get("names", []))
        method = _method_of(function, imported)
        if method is None:
            if listed:   # (an item with no names only says which preset dev runs the function with)
                warnings.append(f"option presets of {function} ({listed}) are not carried over: {function} has no method here")
            continue
        legacy = function in imported
        entries = item.get("entries")
        if not legacy and method not in DEV_OPTIONS:
            if listed:
                warnings.append(f"option presets of {function} ({listed}) are not carried over: dev's options of {function} "
                                f"have no equivalent in {method}")
            entries = []
        elif entries is None:
            if listed:
                warnings.append(f"option presets of {function} ({listed}) are not carried over: the export holds no values of them")
            entries = []
        for entry in entries:
            dev_name = str(entry.get("name") or "")
            where = f"option preset '{dev_name}' of {function}"
            name = _preset_name(dev_name, used.setdefault(method, set()))
            if dev_name.strip().lower() == "default":
                warnings.append(f"{where}: imported as '{name}', since 'default' is the method's own defaults here")
            if entry.get("skippedOptions"):
                warnings.append(f"{where}: {', '.join(entry['skippedOptions'])} hold values with no JSON form; left out")
            options = entry.get("options") or {}
            if legacy:
                values = dict(options)
            else:
                values, unmapped = _mapped_options(method, options)
                if unmapped:
                    warnings.append(f"{where}: dev's options {', '.join(unmapped)} have no equivalent in {method}; left out")
            presets.append({"method": method, "name": name, "description": str(entry.get("description") or ""),
                            "values": values})
            names[(method, dev_name)] = name
        default = str(item.get("defaultName") or "")
        target = names.get((method, default)) or (_dev_preset(method, default) if default.lower() != "default" else None)
        if default and target:   # the preset dev ran the method with when none was chosen
            preferred = [p for p in preferred if p["method"] != method] + [{"method": method, "preset": target}]
    return presets, preferred, names


def _preset_name(name: str, used: set) -> str:
    """A preset's name here: dev's, with characters other than letters, digits, _, . and - as _, and not 'default'."""
    text = re.sub(r"[^A-Za-z0-9_.-]+", "_", name.strip()).strip("_.") or "preset"
    if text.lower() == "default":
        text += "_dev"
    candidate, n = text, 2
    while candidate in used:
        candidate, n = f"{text}_{n}", n + 1
    used.add(candidate)
    return candidate


def _mapped_options(method: str, options: dict) -> Tuple[Dict[str, Any], List[str]]:
    """dev's options of NoRMCorre or Quicky (nested, as dev's Options classes give them) as the module method's
    options: each that DEV_OPTIONS maps, a row ([y, x, z] shifts and overlaps) as its first value; and the paths of
    those it does not map."""
    mapping = dict(DEV_OPTIONS[method])
    values: Dict[str, Any] = {}
    unmapped: List[str] = []

    def walk(node: dict, prefix: str) -> None:
        for key, value in node.items():
            path = prefix + key
            if isinstance(value, dict):
                walk(value, path + ".")
            elif path not in mapping:
                unmapped.append(path)
            elif mapping[path] is not None:
                if isinstance(value, list):
                    value = value[0] if value else None
                if value is not None:
                    values[mapping[path]] = value

    walk(options, "")
    return values, unmapped


def _progress(tables: List[dict], pipelines: Dict[str, str], imported: Dict[str, str], warnings: List[str]) -> List[dict]:
    """dev's Progress column: each session's pipeline (when it was imported) in core.pipeline, and the pipeline tasks
    dev marked finished, with their date, as completed runs of their method."""
    runs: List[dict] = []
    for table in tables:
        progress = table.get("progress")
        if not progress or table["entityType"] != "session":   # dev's pipelines are of sessions
            continue
        absent = undone = undated = 0
        for index, key, item in progress["rows"]:
            pipeline = str(item.get("pipeline") or "")
            if pipeline in pipelines:
                table["rows"][index]["pipeline"] = pipelines[pipeline]
            elif pipeline:
                absent += 1
            for task in item.get("tasks", []):
                method = _method_of(str(task.get("function") or ""), imported)
                if method is None:
                    undone += 1
                elif not task.get("finishedAt"):
                    undated += 1
                else:
                    runs.append({"method": method, "key": key, "finishedAt": task["finishedAt"]})
        label = progress["label"]
        if absent:
            warnings.append(f"table '{label}': {absent} row(s) follow a dev pipeline that is not here; they get no pipeline")
        if undone:
            warnings.append(f"table '{label}': {undone} finished pipeline task(s) of a method not here; left out")
        if undated:
            warnings.append(f"table '{label}': {undated} finished pipeline task(s) with no date; left out")
    return runs


def _session_keys(session: Optional[dict], ids: List[str]) -> Tuple[List[dict], List[str]]:
    """The keys of the sessions of these dev session ids that the session table has, and the ids it has not."""
    keys: List[dict] = []
    missing: List[str] = []
    for session_id in ids:
        found = [r for r in session["rows"] if r.get("session_id") == session_id] if session else []
        if len(found) != 1:
            missing.append(str(session_id))
            continue
        key = {k: found[0][k] for k, _ in session["key"]}
        if key not in keys:
            keys.append(key)
    return keys, missing


def _task_list(export: dict, session: Optional[dict], imported: Dict[str, str], preset_names: Dict[Tuple[str, str], str],
               warnings: List[str]) -> Tuple[List[dict], List[dict]]:
    """dev's task list: its queued tasks of a method here, on the sessions here (put on hold when written), and its
    history's completed tasks as completed runs."""
    tasks: List[dict] = []
    task_list = export.get("tasks") or {}
    for item in task_list.get("queue", []):
        function = str(item.get("function") or "")
        label = str(item.get("name") or "")
        where = f"queued task '{label}' ({function})"
        method = _method_of(function, imported)
        if method is None:
            warnings.append(f"{where} has no method here; left out")
            continue
        if not item.get("entities"):
            warnings.append(f"{where}: the task list does not name its sessions; left out")
            continue
        keys, missing = _session_keys(session, item["entities"])
        if missing:
            warnings.append(f"{where}: {', '.join(missing)} not in the session table; " +
                            ("left out of it" if keys else "left out"))
        if not keys:
            continue
        dev_preset = str(item.get("preset") or "")
        options = item.get("options") or {}
        preset = preset_names.get((method, dev_preset))
        if function in imported:
            values = dict(options)
        elif method in DEV_OPTIONS:
            values = _mapped_options(method, options)[0]
            preset = preset or _dev_preset(method, dev_preset or "default")
        else:
            values = {}
            preset = preset or _dev_preset(method, dev_preset or "default")
            if options and not preset:
                warnings.append(f"{where}: dev's options are not the method's here; it starts from the method's defaults")
        task = {"method": method, "name": label, "entities": keys, "values": values}
        if preset:
            task["preset"] = preset
        for field in ("createdAt", "comment"):
            if item.get(field):
                task[field] = item[field]
        tasks.append(task)
    runs: List[dict] = []
    recorded = left = 0
    for item in task_list.get("history", []):
        method = _method_of(str(item.get("function") or ""), imported)
        keys = _session_keys(session, item.get("entities", []))[0]
        if str(item.get("status") or "").lower() == "completed" and method and keys and item.get("finishedAt"):
            runs.extend({"method": method, "key": key, "finishedAt": item["finishedAt"]} for key in keys)
            recorded += 1
        else:
            left += 1
    if recorded or left:
        warnings.append(f"task history: {recorded} completed task(s) recorded in the run journal; {left} left out "
                        "(not completed, or of a method or session not here)")
    return tasks, runs


def _ordered_runs(runs: List[dict]) -> List[dict]:
    """Runs once each, in the order they finished (those of the same time in the order given)."""
    seen: set = set()
    unique = []
    for run in runs:
        identity = (run["method"], json.dumps(run["key"]), run["finishedAt"])
        if identity not in seen:
            seen.add(identity)
            unique.append(run)
    return sorted(unique, key=lambda run: run["finishedAt"])


def _settings(export: dict) -> dict:
    """dev's app preferences (nansen.App's settings) that are app settings here, in the shape of settings.save:
    AutosaveMetadataToDataFolders is tables.saveToDataFolders; RunTasksWhenQueued or RunTasksOnStartup is
    queue.autoStart (the worker starts with the app, and takes tasks as they are queued)."""
    settings = export.get("settings") if isinstance(export.get("settings"), dict) else {}
    table = settings.get("MetadataTable") if isinstance(settings.get("MetadataTable"), dict) else {}
    processor = settings.get("TaskProcessor") if isinstance(settings.get("TaskProcessor"), dict) else {}
    out: Dict[str, Any] = {}
    if isinstance(table.get("AutosaveMetadataToDataFolders"), bool):
        out["tables"] = {"saveToDataFolders": table["AutosaveMetadataToDataFolders"]}
    flags = [processor[k] for k in ("RunTasksWhenQueued", "RunTasksOnStartup") if isinstance(processor.get(k), bool)]
    if flags:
        out["queue"] = {"autoStart": any(flags)}
    return out


# -- data locations -------------------------------------------------------------------------

def _dataset(export: dict, warnings: List[str]) -> Tuple[dict, Dict[str, Dict[str, str]]]:
    """The DSM config, and per location the level name of each entity type."""
    definitions: Dict[str, dict] = {}
    locations: List[dict] = []
    entity_levels: Dict[str, Dict[str, str]] = {}
    used: set = set()
    for location in export.get("dataLocations", []):
        name = location.get("name", "")
        identifier = _unique(_identifier(name, "location", sep="_", lower=True), used)
        roots = []
        for index, root in enumerate(location.get("rootPaths", []), start=1):
            if not root.get("value"):
                continue
            entry = {"identifier": _root_identifier(root.get("key", ""), index, roots), "path": root["value"]}
            if root.get("diskName"):
                entry["volumeName"] = root["diskName"]
            roots.append(entry)
        if not roots:
            warnings.append(f"data location '{name}': no root path, left out")
            continue
        layout, by_type = _layout(location.get("subfolders", []))
        if "session" not in by_type:
            warnings.append(f"data location '{name}': no folder levels, left out")
            continue
        mapping = _mapping(location, layout, by_type, definitions, warnings)
        category, access = LOCATION_CATEGORY.get(str(location.get("type", "recorded")).lower(), ("raw", "read"))
        locations.append({"identifier": identifier, "displayName": name or identifier, "dataCategory": category,
                          "access": access, "sourceType": "filesystem",
                          "filesystemSource": {"rootStoragePaths": roots, "entityLayout": layout,
                                               "metadataMapping": mapping}})
        entity_levels[identifier] = by_type
    has_subject = "subject_id" in definitions
    entity_types = []
    if has_subject:
        entity_types.append({"name": "subject", "identifierRef": "subject_id"})
    entity_types.append({"name": "session", "identifierRef": "session_id"})
    definitions.setdefault("session_id", {"name": "session_id", "dataType": "string", "ofEntity": "session"})
    order = ["subject_id", "session_id", "session_date", "session_time"]
    ordered = {k: definitions[k] for k in order if k in definitions}
    ordered.update({k: v for k, v in definitions.items() if k not in ordered})
    if not has_subject:
        for location in locations:  # without subject identity, a subject level is structural
            for level in location["filesystemSource"]["entityLayout"]:
                if level.get("entityType") == "subject":
                    del level["entityType"]
        for levels in entity_levels.values():
            levels.pop("subject", None)
    dataset = {"schemaVersion": "0.1.0", "entityTypes": entity_types, "metadataDefinitions": ordered,
               "dataLocations": locations}
    return dataset, entity_levels


def _layout(subfolders: List[dict]) -> Tuple[List[dict], Dict[str, str]]:
    layout: List[dict] = []
    by_type: Dict[str, str] = {}
    names: set = set()
    for index, folder in enumerate(subfolders, start=1):
        kind = str(folder.get("type") or "").lower()
        level_name, entity_type = LEVEL_KINDS.get(kind, (f"level{index}", None))
        if entity_type in by_type:
            entity_type = None  # a second level of the same type is structural
        if level_name in names:
            level_name = f"{level_name}{index}"
        names.add(level_name)
        level: Dict[str, Any] = {"name": level_name}
        if entity_type:
            level["entityType"] = entity_type
            by_type[entity_type] = level_name
        if folder.get("isFolder") is False:
            level["fileSystemType"] = "file"
        level["matchPattern"] = folder.get("expression") or "."
        level["excludePatterns"] = ["^\\."] + [re.escape(item) for item in folder.get("ignoreList", []) if item]
        layout.append(level)
    if layout and "session" not in by_type:
        # In dev, sessions are the deepest folders, whatever their level is called.
        last = layout[-1]
        if "entityType" in last:
            by_type.pop(last["entityType"])
        last["entityType"] = "session"
        by_type["session"] = last["name"]
    return layout, by_type


def _mapping(location: dict, layout: List[dict], by_type: Dict[str, str], definitions: Dict[str, dict],
             warnings: List[str]) -> List[dict]:
    name = location.get("name", "")
    mapping: List[dict] = []
    for rule in location.get("metadata", []):
        variable = rule.get("variableName", "")
        field, data_type, entity = METADATA.get(variable) or (_identifier(variable, "field", sep="_", lower=True),
                                                             "string", "session")
        extraction = _extraction(rule, layout, f"data location '{name}', {variable}", warnings)
        if extraction is None:
            continue
        if rule.get("format") and data_type in ("date", "time"):
            extraction["valueFormat"] = rule["format"]
        definitions.setdefault(field, {"name": field, "dataType": data_type, "ofEntity": entity})
        mapping.append({"metadataRef": field, "extraction": extraction})
    for entity, field in (("subject", "subject_id"), ("session", "session_id")):
        # dev reads an id from the whole folder name when no rule says otherwise
        if entity in by_type and not any(m["metadataRef"] == field for m in mapping):
            mapping.append({"metadataRef": field,
                            "extraction": {"method": "substring", "pattern": ":", "entityLayoutLevel": by_type[entity]}})
            definitions.setdefault(field, {"name": field, "dataType": "string", "ofEntity": entity})
    return mapping


def _extraction(rule: dict, layout: List[dict], where: str, warnings: List[str]) -> Optional[dict]:
    mode = str(rule.get("mode") or "ind").lower()
    if mode == "func":
        function = str(rule.get("functionName") or "")
        if not function:
            return None
        key = _identifier(function.split(".")[-1], "extractor", sep="_", lower=False)
        warnings.append(f"{where}: read by the function {function}; register an extractor named '{key}'")
        return {"method": "function", "extractorFunction": key}
    levels = rule.get("subfolderLevel")
    levels = [levels] if isinstance(levels, int) else (levels or [])
    pattern = str(rule.get("input") or "")
    if not levels or not pattern:
        return None
    if len(levels) > 1:
        warnings.append(f"{where}: combines several folder levels, which has no DSM rule; left out")
        return None
    index = int(levels[0])
    if not 1 <= index <= len(layout):
        warnings.append(f"{where}: folder level {index} does not exist; left out")
        return None
    level = layout[index - 1]["name"]
    if mode == "ind":
        sliced = matlab_index_to_slice(pattern)
        if sliced is None:
            warnings.append(f"{where}: the index expression '{pattern}' has no slice form; left out")
            return None
        return {"method": "substring", "pattern": sliced, "entityLayoutLevel": level}
    if mode == "expr":
        # dev takes the whole match; DSM takes the first group when there is one
        if re.search(r"(?<!\\)\((?!\?)", pattern):
            pattern = "(" + pattern + ")"
        return {"method": "regex", "pattern": pattern, "entityLayoutLevel": level}
    warnings.append(f"{where}: unknown detection mode '{mode}'; left out")
    return None


def matlab_index_to_slice(expression: str) -> Optional[str]:
    """'1:5' -> ':5', '3:end' -> '2:', 'end-3:end' -> '-4:', '4' -> '3:4'; None if not a plain range."""
    text = expression.replace(" ", "")
    bound = r"(\d+|end(?:-\d+)?)"
    match = re.fullmatch(bound + r"(?::" + bound + r")?", text)
    if not match:
        return None
    first, last = match.group(1), match.group(2) or match.group(1)

    def offset(value: str) -> Optional[int]:  # 0-based index of a 1-based bound, negative from the end
        if value == "end":
            return -1
        if value.startswith("end-"):
            return -1 - int(value[4:])
        return int(value) - 1

    start, stop = offset(first), offset(last)
    if start is None or stop is None or (first.isdigit() and int(first) < 1):
        return None
    if (start >= 0) == (stop >= 0) and stop < start:
        return None
    start_text = "" if start == 0 else str(start)
    stop_text = "" if stop == -1 else str(stop + 1)
    return f"{start_text}:{stop_text}"


# -- data variables ---------------------------------------------------------------------------

def _data_variables(export: dict, dataset: dict, levels: Dict[str, Dict[str, str]], legacy_adapters: Dict[str, str],
                    warnings: List[str]) -> List[dict]:
    location_ids = {loc["displayName"]: loc["identifier"] for loc in dataset["dataLocations"]}
    layouts = {loc["identifier"]: loc["filesystemSource"]["entityLayout"] for loc in dataset["dataLocations"]}
    variables: List[dict] = []
    names: set = set()
    for item in export.get("variables", []):
        if item.get("isInternal"):
            continue
        legacy_name = item.get("name", "")
        location = location_ids.get(item.get("dataLocation", ""))
        if location is None or "session" not in levels.get(location, {}):
            warnings.append(f"variable '{legacy_name}': no session folders in data location "
                            f"'{item.get('dataLocation', '')}'; left out")
            continue
        file_type = str(item.get("fileType") or "")
        if file_type and not file_type.startswith("."):
            file_type = "." + file_type
        adapter_name = str(item.get("fileAdapter") or "")
        adapter = ADAPTERS_BY_NAME.get(adapter_name.lower(), "?")
        if adapter == "?" and adapter_name.lower() != "imagestack" and adapter_name.lower() in legacy_adapters:
            adapter = legacy_adapters[adapter_name.lower()]   # one of the project's own, imported (dev's code)
        elif adapter is None:
            adapter = ADAPTERS_BY_TYPE.get(file_type.lower())
        elif adapter_name.lower() == "imagestack":
            adapter = STACK_ADAPTERS_BY_TYPE.get(file_type.lower(), "?")
        if adapter in (None, "?"):
            warnings.append(f"variable '{legacy_name}': no built-in file adapter for "
                            f"'{adapter_name or 'Default'}' {file_type} files; left out")
            continue
        name = _unique(_identifier(legacy_name, "variable", sep="_", lower=False), names)
        expression = str(item.get("fileNameExpression") or "")
        if expression:
            base = expression if file_type and expression.endswith(file_type) else expression + file_type
        else:
            base = _snake(legacy_name) + file_type
        document: Dict[str, Any] = {"schemaType": "nansen.dataVariable", "schemaVersion": "0.1.0", "name": name,
                                    "entityType": "session", "dataLocation": location}
        subfolder = str(item.get("subfolder") or "").strip("/\\").replace("\\", "/")
        if expression and not subfolder:
            # Find existing files the way dev did, by the end of their name.
            level = next(lvl for lvl in layouts[location] if lvl["name"] == levels[location]["session"])
            level.setdefault("filePatterns", []).append(
                {"name": name, "pattern": re.escape(base) + "$", "cardinality": "one"})
            document["filePattern"] = name
        if subfolder:
            document["subfolder"] = subfolder
        document["fileName"] = "{session_id}_" + base
        document["fileAdapter"] = adapter
        if adapter == "mat" and adapter_name.lower() in NAMED_IN_FILE and re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", legacy_name):
            document["variableInFile"] = legacy_name   # dev loaded the variable of the data variable's name
        variables.append(document)
    return variables


# -- tables -------------------------------------------------------------------------------------

def _tables(export: dict, dataset: dict, warnings: List[str]) -> Tuple[List[dict], List[dict]]:
    declared = [t["name"] for t in dataset["entityTypes"]]
    attributes = set(dataset["metadataDefinitions"])
    fragments: List[dict] = []
    tables: List[dict] = []
    done: set = set()
    subsets: List[dict] = []
    for table in export.get("tables", []):
        label = table.get("name", "")
        entity_type = str(table.get("entityClass", "")).lower()
        if not table.get("isMaster", True):
            subsets.append(table)  # a dev "filtered" table holds a subset of the master's rows: a view
            continue
        if entity_type not in declared:
            warnings.append(f"table '{label}': the dataset has no {entity_type or 'such'} entity type; left out")
            continue
        if entity_type in done:
            warnings.append(f"table '{label}': a second master table of {entity_type}s; left out")
            continue
        done.add(entity_type)
        key = _key(entity_type, declared)
        key_names = [k for k, _ in key]
        derived = DERIVED.get(entity_type, {})
        columns = {c["name"]: c["dataType"] for c in table.get("columns", [])}
        notes = [c for c in NOTES if c in columns]
        subject = {c: SUBJECT[c][0] for c in SUBJECT
                   if entity_type == "subject" and columns.get(c) == SUBJECT[c][1]}
        extra: List[dict] = []
        renames: Dict[str, str] = {}
        taken = set(key_names) | attributes | {"ignore", "description"} | set(subject.values())
        for column, data_type in columns.items():
            if column in ID_COLUMNS or column in NOTES or column in subject or (column in derived and derived[column] in attributes):
                continue
            new = _identifier(column, "column", sep="_", lower=False)
            if new in taken:
                new = new + "_legacy"
            taken.add(new)
            renames[column] = new
            entry: Dict[str, Any] = {"name": new, "dataType": data_type}
            if data_type == "boolean":
                entry["default"] = False
            extra.append(entry)
        for skipped in table.get("skippedColumns", []):
            warnings.append(f"table '{label}': column '{skipped}' holds values with no table type; left out")
        fragment_ids = (["core.notes"] if notes else []) + (["core.subject"] if subject else [])
        if extra:
            fragment_id = f"legacy.{entity_type}"
            fragments.append({"schemaType": "nansen.fragment", "schemaVersion": "0.1.0", "id": fragment_id,
                              "version": "1.0.0", "title": f"Columns imported from the {label} table",
                              "columns": extra})
            fragment_ids.append(fragment_id)
        rows: List[dict] = []
        seen: set = set()
        incomplete = 0
        identities: Dict[int, Tuple[Any, ...]] = {}  # row index -> identity, for the notes
        progress = {item["row"]: item for item in table.get("progress", [])}   # dev's Progress column, by row
        kept_progress: List[tuple] = []   # (index in rows, key, dev's progress) of the rows kept
        odd_sexes = 0
        for index, legacy_row in enumerate(table.get("rows", [])):
            row: Dict[str, Any] = {}
            for column, value in legacy_row.items():
                if column in ID_COLUMNS:
                    row[ID_COLUMNS[column]] = value
                elif column in NOTES:
                    row[NOTES[column]] = value
                elif column in subject:
                    if column == "BiologicalSex" and value is not None:
                        text = str(value).strip().lower()
                        if text in ("", "n/a", "na"):
                            value = None
                        elif text in SEXES:
                            value = text
                        else:
                            odd_sexes += 1  # kept as written
                    row[subject[column]] = value
                elif column in renames:
                    row[renames[column]] = value
            if row.get("description") == "":
                row["description"] = None
            if "ignore" in row and row["ignore"] is None:
                row["ignore"] = False
            identity = tuple(row.get(k) for k in key_names)
            if any(v in (None, "") for v in identity):
                incomplete += 1
                continue
            identities[index] = identity
            if identity in seen:
                warnings.append(f"table '{label}': {'/'.join(map(str, identity))} appears twice; kept the first")
                continue
            seen.add(identity)
            if index in progress:
                kept_progress.append((len(rows), dict(zip(key_names, identity)), progress[index]))
            rows.append({k: v for k, v in row.items() if k in key_names or k in ("ignore", "description")
                         or k in renames.values() or k in subject.values()})
        if odd_sexes:
            warnings.append(f"table '{label}': {odd_sexes} BiologicalSex value(s) not among {', '.join(SEXES)}; kept as written")
        if incomplete:
            warnings.append(f"table '{label}': {incomplete} row(s) with no {' or '.join(key_names)}; left out")
        notes = _notes(table, identities, key_names, label, warnings)
        tables.append({"entityType": entity_type, "title": f"{entity_type.title()}s", "key": key,
                       "fragments": fragment_ids, "rows": rows, "notes": notes,
                       "progress": {"label": label, "rows": kept_progress}})
    for entity_type in declared:
        if entity_type not in done:  # a table to sync into, for entity types dev kept no table of
            tables.append({"entityType": entity_type, "title": f"{entity_type.title()}s",
                           "key": _key(entity_type, declared), "fragments": ["core.notes"], "rows": [], "notes": []})
    tables.sort(key=lambda t: declared.index(t["entityType"]))
    for subset in subsets:
        _view(subset, tables, declared, warnings)
    return fragments, tables


def _view(table: dict, tables: List[dict], declared: List[str], warnings: List[str]) -> None:
    """A dev filtered table as a view of its entity type: the keys of its rows, found in the master's."""
    label = table.get("name", "")
    entity_type = str(table.get("entityClass", "")).lower()
    target = next((t for t in tables if t["entityType"] == entity_type), None)
    if target is None:
        warnings.append(f"table '{label}': the dataset has no {entity_type or 'such'} entity type; left out")
        return
    key_names = [k for k, _ in target["key"]]
    keys: List[dict] = []
    unmatched = 0
    for legacy_row in table.get("rows", []):
        given = {ID_COLUMNS[c]: v for c, v in legacy_row.items() if c in ID_COLUMNS and v not in (None, "")}
        given = {k: v for k, v in given.items() if k in key_names}
        if len(given) == len(key_names):
            key = {k: given[k] for k in key_names}
        else:  # a filtered table may hold only the session id: find the row of the master table it is
            found = [r for r in target["rows"] if given and all(r.get(k) == v for k, v in given.items())]
            if len(found) != 1:
                unmatched += 1
                continue
            key = {k: found[0][k] for k in key_names}
        if key not in keys:
            keys.append(key)
    if unmatched:
        warnings.append(f"table '{label}': {unmatched} row(s) not found in the {entity_type} table; left out of its view")
    target.setdefault("views", []).append({"name": label, "description": f"Imported from the dev table {label}", "keys": keys})


def _notes(table: dict, identities: Dict[int, Tuple[Any, ...]], key_names: List[str], label: str,
           warnings: List[str]) -> List[dict]:
    """The Notebook column's notes, on the entity of their row, in the order they were written."""
    notes: List[dict] = []
    orphans = untimed = 0
    for note in table.get("notes", []):
        if note["row"] not in identities:
            orphans += 1
            continue
        if note["createdAt"] is None:
            untimed += 1
            continue
        note_type = NOTE_TYPES.get(note["type"].lower())
        if note_type is None:
            warnings.append(f"table '{label}': a note of type '{note['type']}' is imported as informal")
            note_type = "informal"
        notes.append({"key": dict(zip(key_names, identities[note["row"]])), "createdAt": note["createdAt"],
                      "author": note["author"], "type": note_type, "title": note["title"], "text": note["text"]})
    if orphans:
        warnings.append(f"table '{label}': {orphans} note(s) on rows that were left out; left out")
    if untimed:
        warnings.append(f"table '{label}': {untimed} note(s) with no time; left out")
    notes.sort(key=lambda n: n["createdAt"])  # stable: notes of the same second keep their order
    return notes


def _key(entity_type: str, declared: List[str]) -> List[Tuple[str, str]]:
    if entity_type == "subject":
        return [("subject_id", "string")]
    return ([("subject_id", "string")] if "subject" in declared else []) + [("session_id", "string")]


# -- names --------------------------------------------------------------------------------------

def _identifier(text: str, fallback: str, sep: str, lower: bool) -> str:
    out = re.sub(r"[^A-Za-z0-9]+", sep, str(text)).strip(sep)
    if lower:
        out = out.lower()
    if not out:
        return fallback
    if not out[0].isalpha():
        out = fallback + sep + out
    return out


def _snake(text: str) -> str:
    """dev's file name for a variable: an underscore before each capital or digit, then lower case."""
    return "".join(("_" + c if i and (c.isupper() or c in "123456789") else c) for i, c in enumerate(text)).lower()


def _unique(name: str, used: set) -> str:
    candidate, n = name, 2
    while candidate in used:
        candidate, n = f"{name}_{n}", n + 1
    used.add(candidate)
    return candidate


def _root_identifier(key: str, index: int, roots: List[dict]) -> str:
    candidate = key if re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", key or "") else f"root{index}"
    if any(r["identifier"] == candidate for r in roots):
        candidate = f"root{index}"
    return candidate
