# Modules, methods and tasks

A **module** is a folder that adds fragments, methods, file adapters and pipelines to the projects that list it. A module holds code for either language or both, and the same module can be used from MATLAB and from Python.

## A module folder

```
<module>/
  module.nansen.json                 nansen.module: id, version, and the paths of what it provides
  fragments/<name>.fragment.nansen.json
  methods/<name>.method.nansen.json
  adapters/<name>.fileAdapter.nansen.json
  pipelines/<name>.pipeline.nansen.json
  presets/<name>.options.nansen.json    option presets of its methods (or of other modules' methods)
  python/                            Python code, imported from here without changing sys.path
  matlab/                            MATLAB code, put on the path when one of the module's methods or adapters is first used
```

`module.nansen.json` lists each document by its path in the folder. Nothing is found by scanning. Ids of everything a module provides start with the module id, for example `core.notes` or `ophys.motion_correction`.

A project lists its modules in `project.nansen.json` (`modules: [{id, path?}]`). Add one with `project.addModule(id, path)` (MATLAB) or `project.add_module(id, path)` (Python). A module is looked for in this order: at `path` (relative to the project folder), at `<project>/modules/<id>`, and among the modules that ship with NANSEN (`modules/` in this repository). The project's own `fragments/`, `methods/` and `pipelines/` folders work like a module without an id prefix.

The built-in **`core`** module provides:

- `core.notes`: `ignore` and `description` for any entity;
- `core.subject`: date of birth, sex (a choice) and species, for subjects;
- `core.pipeline`: the pipeline an entity is assigned;
- `core.file_stats`: file count and size, computed by `core.file_stats`;
- the methods `core.export_keys` (batch), `core.backup` (copies an entity's folders to `<destination>/<data location>/<the same path>`, leaving copies that are up to date alone) and `core.wait` (for trying the queue);
- the pipeline `core.inspect`.

## Methods

A method is declared by a `nansen.method` document and implemented in either or both languages:

```json
{
  "schemaType": "nansen.method", "schemaVersion": "0.1.0",
  "id": "ophys.motion_correction", "version": "1.0.0", "title": "Correct motion",
  "entityType": "session",
  "batchMode": "serial",
  "implementations": { "python": "motion:correct", "matlab": "ophysCorrectMotion" },
  "options": {
    "type": "object",
    "properties": {
      "maxShift": { "type": "integer", "default": 20, "minimum": 0, "title": "Largest shift (px)" }
    }
  }
}
```

- `entityType` is the type the method runs on, or `*` for any type.
- `batchMode` is `serial` (the default: called once per entity) or `batch` (called once with all the entities).
- `options` is a JSON Schema. Its defaults are the method's `default` preset, and the dashboard draws its form from it. The options a method receives are the defaults, overlaid by a preset, overlaid by the options given to the run, and are validated against the schema.

The implementations take `(entity, options, context)` (or `(entities, options, context)` in batch mode) and return a value that can be written as JSON:

```python
def correct(entity, options, context):
    movie = context.project.load(entity, "movie")
    for i, frame in enumerate(movie):
        context.check_cancelled()
        context.progress(i / len(movie), "registering")
    context.project.save(entity, "motion_corrected", shifts)
    context.log(f"max shift {options['maxShift']}")
    return {"frames": len(movie)}
```

```matlab
function result = ophysCorrectMotion(entity, options, context)
    movie = context.Project.load(entity, "movie");
    ...
    context.progress(0.5, "registering"); context.checkCancelled(); context.log("max shift %d", options.maxShift);
    result = struct("frames", numel(movie));
end
```

`load` keeps what it read in the project's data cache (`project.data_cache`, `project.DataCache`), so methods run one after another on an entity read its files once. An entry is read again when its file changes on disk, `save` drops the entry of the file it writes, and the least recently used entries leave first once the cache holds 2 GiB. In Python, an array from the cache is read-only, so a method that changes it works on a copy (`movie.copy()`); dicts and lists are copied for each caller. MATLAB values are copied when changed anyway. `load(entity, name, cached=False)` (`Cached=false`) reads the file and keeps nothing.

The context gives the project, `log`, `progress(fraction, message)` and cancellation. Nothing else is shared: a method gets everything through its arguments.

Run a method now with `project.run(methodId, entities, Options=…, Preset=…)` / `project.run(method_id, entities, options=…, preset=…)`, or queue it as a task (below).

**Presets** are named option sets saved in `options/<methodId>/<name>.options.nansen.json` (`nansen.options`). Use `savePreset` / `save_preset`, `presets` and `deletePreset` / `delete_preset`, or the run dialog. A module can ship presets too, listed under `presets` in `module.nansen.json`; they come after the project's own, and a project preset of the same name is used instead. Only the project's presets can be deleted. The `default` preset is always the method's schema defaults.

## Columns with choices

A string column of a fragment can list its `choices`: `entities.update` and `entities.add` refuse other values (none is always allowed) with `invalid-value`, and the dashboard edits it with a list. The CSV is read as written, so a value typed in by hand stays. `core.subject` has one: `sex` is `female`, `male` or `not detected`, as in dev.

A fragment can be taken off an entity type again with `detachFragment` / `detach_fragment` (`fragments.detach`): its columns and their values leave the table. `resetColumn` / `reset_column` (`columns.reset`) gives a column its default again, in some rows or all.

## Computed fragments

A fragment with `compute.method` is computed: its columns are filled by that method instead of typed in. The method returns a struct or dict with a value per column. `updateFragment(entityType, fragmentId)` / `update_fragment` runs it for every row, or for the given keys, and writes the table. In the dashboard, computed columns are read-only. This replaces NANSEN's table variables with update functions.

## File adapters

A file adapter reads a file into a value and writes a value to a file. The built-in ones are `json`, `text` and `mat` (in Python, `mat` needs SciPy: `pip install "nansen-core[mat]"`), plus `npy` in Python only. A module adds others with a `nansen.fileAdapter` document:

```json
{ "schemaType": "nansen.fileAdapter", "schemaVersion": "0.1.0", "id": "ophys.tiff_stack", "version": "1.0.0",
  "extensions": [".tif", ".tiff"],
  "implementations": { "python": "stacks:TiffStack", "matlab": "ophys.TiffStack" } }
```

A Python implementation is a class with `read(path)` and `write(path, data)`. A MATLAB one is a subclass of `nansen.FileAdapter`. Data variables name the adapter by id. See [entities](entities.md) for how a data variable finds its file.

## Pipelines

A pipeline (`nansen.pipeline`) is an ordered list of method steps, each with an optional preset and options. Queueing it makes one chain of tasks per entity. Each step waits for the step before it, and is cancelled if that step fails or is cancelled.

An entity can also be assigned a pipeline, as in dev: the `pipeline` column of the `core.pipeline` fragment (`pipelines.assign`). Every method run that completes, in the queue or in the foreground, appends a line per entity to `runs/<entityType>.runs.jsonl`; a step is done for an entity once its method has completed on it. That gives each entity's progress (a column in the table, the steps in its drawer), and `pipelines.queueNext` queues the steps from the first not done on. Entities whose steps are queued or running already are left alone.

A project's own pipelines are in `pipelines/` and can be made and changed in the dashboard (`pipelines.save`, `pipelines.delete`). One with the id of a module's pipeline is used instead of it.

## Tasks

A task is a method run on entities, queued in the project as `tasks/<id>.task.nansen.json`. It records entity keys, never live objects, so any process in either language can run it:

| File | Meaning |
|---|---|
| `tasks/<id>.task.nansen.json` | The task: method, entity keys, options, status (`queued`, `running`, `completed`, `failed`, `cancelled`), progress, result or error, `after` (tasks it waits for), pipeline step |
| `tasks/<id>.claim/` | Made by the worker that runs it. Making a folder is atomic, so two workers never take the same task |
| `tasks/<id>.cancel` | Asks the running worker to stop at its next `checkCancelled` |
| `tasks/<id>.log` | Log lines as they are written |

A task may name the language that must run it, and a worker only takes tasks its language can run. A Python worker runs tasks in threads, or in separate processes (`nansen app --executor process`, which uses `python -m nansen run-task`). MATLAB runs them in the foreground (`queue.runNext`, `runAll`) or on a `backgroundPool` (`queue.start`). `recover` puts back the tasks of a worker that died. `retry` queues a failed or cancelled task again.

## From MATLAB and Python

| | MATLAB | Python |
|---|---|---|
| Open a project | `p = nansen.Project.open(folder)` | `p = Project.open(folder)` |
| Methods for an entity type | `p.entityMethods("session")` | `p.methods("session")` |
| Run now | `p.run("core.file_stats", p.entities("session"))` | `p.run("core.file_stats", p.entities("session"))` |
| Queue | `q = nansen.TaskQueue(p); q.submit(...); q.start()` | `q = TaskQueue(p); q.submit(...); q.start()` |
| Recompute a fragment | `p.updateFragment("session", "core.file_stats")` | `p.update_fragment("session", "core.file_stats")` |
