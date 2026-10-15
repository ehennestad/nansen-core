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
  dashboard/<name>.js                pages it adds to the dashboard
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

## The ophys module

The built-in **`ophys`** module brings over the core of dev's two-photon workflow (`+nansen/+module/+ophys/+twophoton`). Its methods are native in both languages and give the same results, which the `ophys` conformance case checks on a synthetic recording with known shifts and cells. Stacks are height x width x frames in both languages (`stack[y, x, t]` in Python is `stack(y+1, x+1, t+1)` in MATLAB, and `.npy` files keep that indexing). Python needs NumPy and, for TIFF, tifffile: `pip install "nansen-core[ophys]"`.

| Method | What it does |
|---|---|
| `ophys.setup_variables` | A project tool: adds the data variables the methods read and write (in a subfolder of each entity's folder in a data location: `.npy` arrays and a `.json` ROI file), `TwoPhotonSeries_Original` through a DSM file pattern of the raw recording, and the `ophys.imaging` and `ophys.image_stats` columns. Variables that exist are left alone |
| `ophys.motion_correction` | Motion correction: each frame is aligned to a reference by the shift of largest phase correlation (smoothed as suite2p does), within `maxShift`. Rigid and in whole pixels by default. `subpixel` finds shifts to 1/20 pixel, by computing the correlation on a finer grid around its peak (as NoRMCorre does), and moves frames bilinearly. `patches` above 1 corrects piecewise rigidly (as NoRMCorre): the frame is cut into patches x patches patches, each finds its shift within `maxDeviation` of the frame's, and each pixel moves by the shift interpolated between the patch centres. Both weight frames by a Hann taper first, so the frame's edges do not count. The reference is the average of the first `referenceFrames` frames, then of the aligned frames. Saves the aligned stack and the shifts (frames x 2, or frames x 2 x patches²). Preset `thorough` for large or slow drift |
| `ophys.image_stats` | Frames, size, mean and maximum intensity (the computed `ophys.image_stats` columns), and the average and maximum projections |
| `ophys.detect_rois` | ROIs as 4-connected areas of pixels whose average correlation with their 8 neighbours reaches `threshold`, of `minSize` to `maxSize` pixels, away from a `border`. ROI files are JSON: `imageSize` and `rois[{id, area, center, pixels}]`, with 0-based `[row, column]` pixels |
| `ophys.extract_signals` | The mean of each ROI's pixels per frame (frames x ROIs, rejected ROIs left out), and of a ring of neuropil around it, outside every ROI |
| `ophys.compute_dff` | ΔF/F = (F - F0) / F0, with F the signal less `neuropilFactor` times the neuropil, and F0 a percentile of F over the whole trace or a window of frames |
| `ophys.downsample` | Mean or maximum over bins of frames and of pixels |
| `ophys.deinterleave` | Frames of several channels and planes interleaved in one stack (channel fastest, then plane, as ScanImage saves them) put in a height x width x channels (x planes) x frames stack |
| `ophys.deconvolve` | Spikes and denoised calcium by OASIS for an AR(1) model, natively: the exact optimum of 1/2 |c - y|² + λ Σ s with s ≥ 0, g from `tauDecay` and the frame rate (`frameRate`, or the entity's `frame_rate`), λ = `sparsity` times the trace's noise |
| `ophys.denoise` | Gaussian smoothing in space and time, renormalised at the edges (dev used DeepInterpolation, which needs a trained network) |
| `ophys.deep_interpolation` | Python: DeepInterpolation with a trained model, as dev's Denoiser, when deepinterpolation and h5py are installed |
| `ophys.align_sessions` | Batch: aligns the selected entities' FOV images to the first one's and copies its ROIs, moved, to the others (dev's migrateRoisToFovs). With `maxRotation`, it also tries each angle up to that, in steps of `rotationStep`, and turns the ROIs by the angle that correlates best |
| `ophys.fov_region` | Computes the `brain_region` column: the atlas region at the FOV's position |
| `ophys.caiman_deconvolution` | CaImAn's constrained foopsi (Python) or OASIS through deconvolveCa (MATLAB), when installed |
| `ophys.extract` | MATLAB: cells and traces by EXTRACT, when it is on the path |
| `ophys.flowreg` | MATLAB: non-rigid motion correction by Flow-Registration, when it is on the path |
| `ophys.suite2p` | Python: runs suite2p, when it is installed, and saves its cells and signals in the same variables |
| `ophys.normcorre` | MATLAB: rigid or piecewise rigid motion correction with NoRMCorre, when it is on the path |
| `ophys.open_in_imviewer` | MATLAB R2024b or older (imviewer uses Java figures), run by hand: opens a stack in dev's imviewer, when it and the Widgets Toolbox are on the path |

Stacks with channels (height x width x channels x frames) or planes (height x width x channels x planes x frames) are taken a channel and plane at a time: image statistics, ROI detection, Quicky, signal extraction, downsampling and denoising have `channel` and `plane` options (from 1). Motion correction finds the shifts in its `channel` and aligns every channel of its `plane` by them, so a structural channel can steer the alignment of a functional one. The viewer offers the channels and planes of the stack it shows (`data.frame` gives their counts).

The viewer is also where ROIs are edited, as in dev's roimanager and roiclassifier. Its tools add a round ROI where you click, take the pixels inside a line you draw (those whose centre is inside it), or detect the cell around a click with `rois.detect`: the pixels brighter than halfway between the 20th percentile of the projection and the brightest pixel near the click, connected to that pixel, with holes filled. Ctrl-click selects several ROIs; `m` merges them into the first, dragging the selected ROI moves it (Alt and the arrow keys a pixel at a time), and `a`, `r`, `u` and Delete classify or remove what is selected. Every edit is a `rois.update` (classify, move, merge, remove, add, in that order). The wheel zooms, dragging pans, a double-click zooms in or back out, and the download button saves the image as PNG. The gallery button shows each ROI on the image around it, sorted by id, size or brightness, to go through with the arrow keys and classify with `a`, `r` and `u`.

A method that needs a package that is not installed fails with `dependency-missing`. The file adapters of stacks are `ophys.sciscan_raw` (a SciScan `.raw` file and its `.ini` file, as written by the microscope: big-endian, one channel after the other in each frame), `ophys.tiff_stack` (multi-page TIFF), `ophys.scanimage_tiff` (ScanImage TIFF files, read only: channels and planes from the metadata, and multi-ROI recordings with their ROIs side by side, without flyback lines; height x width x channels x planes x frames when there is more than one plane), `ophys.prairie_tseries` (a Bruker Prairie View T-series: its XML file, which lists a TIFF file per frame and channel; read only) and `ophys.hdf5_stack` (the dataset `data` of an HDF5 file, frames x height x width as h5py shows it, as suite2p, CaImAn and DeepInterpolation write them).

Other tools' ROIs are read, read only, as the module's ROI document, so they can be viewed, curated and have their signals extracted like the module's own: `ophys.nansen_roi_array` (dev's ROI `.mat` files: Mask, Circle and Polygon ROIs), `ophys.suite2p_rois` (suite2p's `Fall.mat`; cells its classifier left out are classified rejected), `ophys.caiman_rois` (CaImAn's HDF5 results) and `ophys.extract_rois` (EXTRACT's output saved in a `.mat` file). A footprint of weights (CaImAn, EXTRACT) becomes the connected area around its peak of pixels weighing at least 0.2 of it. `conformance/files/ophys` holds a small file of each kind and what it must read as, which both languages' tests check. The fragments are `ophys.imaging` (field of view, depth, indicator and frame rate, typed in) and `ophys.image_stats` (computed). The pipeline `ophys.preprocess` runs motion correction, image statistics, ROI detection, signal extraction, ΔF/F and deconvolution.

The ophys module's **FOV map** page (dev's fovmanager) draws the subjects' cranial windows and the sessions' fields of view on the mouse dorsal cortex atlas from fovmanager, in mm from bregma, and any number of injection sites per subject and notes on the map (fovmanager's annotations), and places them with a click: select a session and Place FOV, or a subject and Place window, Add injection or Add note. Positions of FOVs and windows are the columns of `ophys.fov_position` and `ophys.cranial_window`, so they can be typed in, filtered and exported as well; `ophys.fov_region` fills the brain region at each FOV, in both languages. `ophys.setup_variables` adds the columns. Injection sites and notes are the module's data (`modules.saveData`).

Its **ROI review** page (dev's classifyMultiSessionRois with roiclassifier) shows each ROI of the sessions that `ophys.align_sessions` copied ROIs to, side by side, cropped from each session's FOV image, and accepts or rejects an ROI in all of them at once.

In the dashboard, an entity's image variables (data type `Image` or `ImageStack`, or arrays without a data type) have a View button in its drawer: frames one by one or played, the average or maximum over frames, contrast limits, and the ROIs of a variable of data type `RoiArray` drawn over them. ROIs are curated there, as in dev's roimanager and roiclassifier: select one in the image or the list, accept (a), reject (r), clear (u) or delete it, or add a round one by clicking (`rois.update`). `ophys.extract_signals` and `ophys.align_sessions` leave rejected ROIs out.

## Dashboard pages

A module can add pages to the dashboard: scripts listed under `dashboard` in `module.nansen.json`. When a project that uses the module is open, the dashboard runs each one with `N` (its toolkit: `N.h` to build elements, `N.icon`, `N.dialog`, …) and `module` (the module's id). A script calls `N.registerPage({id, title, icon, render(app, el)})`; the page is listed under Modules in the sidebar, and `render` fills `el`, asking the backend for what it needs with `app.client.request(method, params)`. Files of the module, such as data a page draws, are read with `modules.resource`. Data a page keeps in the project, such as the FOV map's injection sites, is read and saved with `modules.data` and `modules.saveData` (JSON text with a revision, so two windows do not overwrite each other). A page works the same with either backend, since it only uses the protocol.

## Add-ons

A module lists the toolboxes and packages its methods use under `addons` in `module.nansen.json`, as dev's AddonManager kept its list: each with an `id`, `title`, `language` (`matlab` or `python`), `source` (`github`: owner/repository, `pip`: a requirement, or `conda`: a conda-forge package), and `check` (a function or module that is there once it is installed); optionally `url`, `pathOrder` (`end` keeps a MATLAB add-on behind NANSEN's own functions) and `setup` (a MATLAB script run in its folder after a download, to compile for example). The Add-ons card on the Settings page (`addons.list`, `addons.install`, `addons.remove`) shows whether each is installed and installs it: a GitHub add-on is downloaded into the add-ons folder (`~/.nansen/addons`, or the `addons.folder` setting), which MATLAB puts on its path whenever an app or API starts; a pip package is installed into the running Python; a conda package is not installed by NANSEN, which says how to.

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

`load` finds a file `save` wrote to a folder made since the last scan, and keeps what it read in the project's data cache (`project.data_cache`, `project.DataCache`), so methods run one after another on an entity read its files once. An entry is read again when its file changes on disk, `save` drops the entry of the file it writes, and the least recently used entries leave first once the cache holds 2 GiB. In Python, an array from the cache is read-only, so a method that changes it works on a copy (`movie.copy()`); dicts and lists are copied for each caller. MATLAB values are copied when changed anyway. `load(entity, name, cached=False)` (`Cached=false`) reads the file and keeps nothing.

The context gives the project, `log`, `progress(fraction, message)` and cancellation. Nothing else is shared: a method gets everything through its arguments.

Run a method now with `project.run(methodId, entities, Options=…, Preset=…)` / `project.run(method_id, entities, options=…, preset=…)`, or queue it as a task (below).

A method with `entityType` `@project` is a **project tool**, as dev's project apps and scripts: it runs once on the project, as `function(project, options, context)`, from the Tools card on the overview (`tools.run`), `project.runTool(id)` or `project.run_tool(id)`. Tools are not offered for entities.

A project's own methods are documents in `methods/`, with code in `python/` and `matlab/`. Start one with `methods.create` (or `project.createMethod` / `project.create_method`, or the Methods card on the Data page): it writes the document and, per language, a file with an empty function to fill in, from `templates/`. With `computes`, it also writes a computed fragment of those columns that the method fills, and adds it to the entity type. Python code is imported again when its file changes, so an edited method runs without a restart, and no `__pycache__` is written next to it.

A fragment column can also carry `display` (`progress` for a number from 0 to 1, `badge` with `colors` per value, or `link`) and `action` (a method id run on the row when one of its cells is double-clicked in the dashboard).

**Presets** are named option sets saved in `options/<methodId>/<name>.options.nansen.json` (`nansen.options`). Use `savePreset` / `save_preset`, `presets` and `deletePreset` / `delete_preset`, or the run dialog. A module can ship presets too, listed under `presets` in `module.nansen.json`; they come after the project's own, and a project preset of the same name is used instead. Only the project's presets can be deleted. The `default` preset is always the method's schema defaults.

## Columns with choices

A string column of a fragment can list its `choices`: `entities.update` and `entities.add` refuse other values (none is always allowed) with `invalid-value`, and the dashboard edits it with a list. The CSV is read as written, so a value typed in by hand stays. `core.subject` has one: `sex` is `female`, `male` or `not detected`, as in dev.

A fragment can be taken off an entity type again with `detachFragment` / `detach_fragment` (`fragments.detach`): its columns and their values leave the table. `resetColumn` / `reset_column` (`columns.reset`) gives a column its default again, in some rows or all.

## Computed fragments

A fragment with `compute.method` is computed: its columns are filled by that method instead of typed in. The method returns a struct or dict with a value per column. `updateFragment(entityType, fragmentId)` / `update_fragment` runs it for every row, or for the given keys, and writes the table. In the dashboard, computed columns are read-only. This replaces NANSEN's table variables with update functions.

## File adapters

A file adapter reads a file into a value and writes a value to a file. The built-in ones are `json`, `text` and `mat` (in Python, `mat` needs SciPy: `pip install "nansen-core[mat]"`), plus `npy` (NumPy arrays; read and written by MATLAB without Python, keeping NumPy's shape and indexing, and by Python with NumPy: `pip install "nansen-core[npy]"`). A module adds others with a `nansen.fileAdapter` document:

```json
{ "schemaType": "nansen.fileAdapter", "schemaVersion": "0.1.0", "id": "ophys.tiff_stack", "version": "1.0.0",
  "extensions": [".tif", ".tiff"],
  "implementations": { "python": "stacks:TiffStack", "matlab": "ophys.TiffStack" } }
```

A Python implementation is a class with `read(path)` and `write(path, data)`. A MATLAB one is a subclass of `nansen.FileAdapter`. Data variables name the adapter by id. See [entities](entities.md) for how a data variable finds its file.

### Image stacks larger than memory, and recordings in several files

An adapter of image stacks can also have `open(paths)`, which returns a stack read a chunk of frames at a time (`nansen.stacks.Stack` in Python, `nansen.Stack` in MATLAB): height x width (x channels (x planes)) x frames, with `frames(start, stop)` reading only those frames. Several files are one recording, joined along the frames in natural order (`part2` before `part10`), so a file pattern with `"cardinality": "many"` can match each file a microscope wrote. `npy`, `ophys.sciscan_raw`, `ophys.tiff_stack` and `ophys.scanimage_tiff` have it. A ScanImage volume may begin in one file and end in the next.

- `project.open_stack(entity, name)` (`openStack` in MATLAB) gives a variable as a stack: lazily through `open` where the adapter has it, else the whole value read by `load`.
- `project.load` reads a recording in several files as one array, through `open`; with an adapter without `open`, it reads the first file.
- `project.stack_writer(entity, name, shape, dtype)` (`stackWriter(entity, name, size, className)`) writes a stack a chunk of frames at a time. An adapter's `create(path, shape, dtype)` writes each chunk to the file as it comes (`npy` does, in Fortran order so a chunk of frames is one stretch of the file); otherwise the stack is kept in memory and written with `write` when the writer closes.

The ophys methods that handle whole recordings read them this way and never whole: image statistics, motion correction (which also writes the aligned stack in chunks), signal extraction and downsampling, and the viewer's frames and projections (`data.frame`). The others (ROI detection, Quicky, denoising and the external tools) read the stack whole. Setting `project.stack_frame_limit` (`StackFrameLimit`) makes any read of more frames than that fail; the tests use it to show which methods read in chunks.

## Pipelines

A pipeline (`nansen.pipeline`) is an ordered list of method steps, each with an optional preset and options. Queueing it makes one chain of tasks per entity. Each step waits for the step before it, and is cancelled if that step fails or is cancelled.

An entity can also be assigned a pipeline, as in dev: the `pipeline` column of the `core.pipeline` fragment (`pipelines.assign`). Every method run that completes, in the queue or in the foreground, appends a line per entity to `runs/<entityType>.runs.jsonl`; a step is done for an entity once its method has completed on it. That gives each entity's progress (a column in the table, the steps in its drawer), and `pipelines.queueNext` queues the steps from the first not done on. Entities whose steps are queued or running already are left alone.

A pipeline can also be given to new rows by rule: its `assignWhen` holds filters, as a view's (`in`, `range`, `is`, `contains`, `empty`, `notEmpty`), and when a sync adds rows, each gets the first pipeline (in id order) whose filters it passes, on its key, the attributes read from its folder names and the columns' defaults.

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
