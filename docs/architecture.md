# Architecture

This is the plan for rebuilding the NANSEN core and the reasons for it. It was drawn up from a review of NANSEN's `dev` branch and of the [Dataset Structure Model](https://github.com/framover/dataset-structure-model) (DSM).

## Why rebuild

The `dev` branch has moved a long way. It has modules (`module.nansen.json`), spec files carrying `_type`/`_version`, about 360 unit tests with fixtures and test doubles, an LRU `DataCache`, atomic `VersionedFile` saves, and a gate for modern UI components. These are the parts that carry over: they show up below as modules, versioned documents, the test approach, and the frontend.

What cannot be fixed one piece at a time:

- **Global state.** There is a `NansenUserSession` appdata singleton and a persistent `ProjectManager`, and `nansen.getCurrentProject()` is called across 37 files. Tests have to create a throwaway user session to isolate themselves.
- **Persistence.** MetaTables and catalogs are `.mat` files with no schema. Changes are handled by ad hoc fixes on load.
- **`Session` combines everything.** It is the entity, the I/O layer and the holder of both location models (1,438 lines).
- **Tasks hold live objects.** The task processor stores live entity objects in `task_list.mat`.
- **The UI is Java.** `nansen.App` (4,902 lines) runs on the Java Widgets Toolbox, and the README says R2025a and later are not supported.

## Principles

1. **Versioned documents, specs first.** Every file has a schema in `schema/`, and both implementations are checked against the same conformance cases ([conventions](conventions.md)).
2. **No global state.** Objects are created from explicit inputs and passed to whatever needs them. CI enforces this for the core.
3. **Derived data stays separate from authored data.** DSM derives what the stores say: entities, identity, locations, files and attributes in names. Tables persist only what people author. They are joined on identity, so a re-scan never overwrites user input.
4. **Composition, not inheritance.** An entity type is a document that lists its fragments, and in the future its data variables and methods. There is one generic entity at run time. That maps onto both MATLAB and Python, and it lets entity types be defined in project files instead of as classes.
5. **A field enters the core when a reader consumes it.** Parts not built yet are DRAFT schemas.

## Steps

Each step was usable without a GUI before the next one started.

| Step | Contents | Status |
|---|---|---|
| 1 | Envelope convention, schemas, project layout, entity tables (CSV + sidecar), fragments, conformance, `Project` without globals | Done |
| 2 | DSM integration: entity records joined with authored tables; key columns checked against DSM identity; records cached under `cache/`; path generation for new entities (in DSM, both readers) | Done |
| 3 | Data variables (DSM file pattern or file name template + file adapter) and an explicit adapter registry | Done |
| 4 | Modules, methods with JSON Schema options and presets, computed fragments, pipelines, tasks as `nansen.task` documents (entity keys, never live objects); MATLAB on `backgroundPool`, Python on threads or processes | Done |
| 5 | JSON message protocol and the HTML/JS dashboard in one `uihtml` (MATLAB) or a local server (Python); project catalog | Done |
| 6 | One-way importer from `dev` projects (`project.nansen.json` + `.mat` files), with the conversion in both languages | Done |

## Compared with NANSEN dev

| dev | nansen-core |
|---|---|
| `ProjectManager` singleton, `nansen.getCurrentProject()` | `Project.open(folder)`, passed explicitly; `nansen.catalog` lists known projects for the app |
| `project.nansen.json` + `.mat` catalogs | Versioned JSON documents and CSV tables, each with a schema |
| `DataLocationModel` (root paths, subfolder structure, metadata rules) | A DSM config: locations, roots per environment, folder levels, extraction rules; the same file is read by DSM's own tools. A wizard makes one from the data folders; the Data page sets roots per machine and edits the locations in forms (several locations, roots, folder levels and their file patterns, naming rules, a writable processed location derived from the raw one, with its folder names), or the config as text; DSM checks it before it is saved |
| `VariableModel` (file path settings) | Data variables: DSM file pattern or file name template + file adapter; added, edited and deleted on the Data page |
| `MetaTable` of `Session`/`Subject` objects | Entity tables joined with DSM records; one generic entity, so entity types are documents, not classes |
| Table variables (with update functions) | Fragments; computed fragments for the ones with update functions; dev's table variable files imported (`columns.import`) |
| Session methods with `OptionsManager` presets, and their preview mode | Methods with JSON Schema options and preset documents; MATLAB and/or Python implementations; `methods.preview` runs one on the first frames of an entity, writing nothing. dev's own session methods are imported as they are and run in MATLAB with a stand-in for dev's session object (`methods.importLegacy`); the presets users made, and dev's chosen default, come with them |
| Notebooks of sessions and subjects (`HasNotes`, note viewer) | Notebooks: dated, typed notes with #tags per entity, in one `nansen.notebook` per entity type; on an entity's drawer and the Notes page |
| Batch processor with `task_list.mat` | Task queue of `nansen.task` files: claims, cancellation, logs, recovery, retry, dependencies; queued tasks held, reordered and given new options. The legacy importer brings dev's queued tasks (on hold) and its history (into the run journal) |
| Pipelines | Pipelines: one chain of tasks per entity; assigned to entities, with each one's progress from a run journal |
| Extra metatables | Saved views of a table: rows (keys), column filters, hidden columns, a search |
| Session context menu (copy, remove, open folder, send to workspace) | The selection bar and the drawer: copy keys, remove rows, show or copy folders, browse an entity's files, `workspace.send` (MATLAB's base workspace, or a Python namespace) |
| Session method templates, project apps | `methods.create` from `templates/`; project tools (`entityType` `@project`) on the overview |
| File adapters | File adapters: built-in `json`, `text`, `mat`, `npy`, `csv` and `excel` in both languages, others from modules or imported with their code (`adapters.import`); dev's own adapters are imported as they are and run in MATLAB through a stand-in for dev's `FileAdapter` base |
| `nansen.cache.DataCache`, one per MATLAB session | A data cache per project (`project.data_cache`, `project.DataCache`): the same 2 GiB least-recently-used budget, and an entry is read again when its file changes on disk |
| Modules (`module.nansen.json`) | Modules listing fragments, methods, adapters and pipelines by path; code for either language; added and removed from the overview |
| `AddonManager` (toolboxes from GitHub and the File Exchange) | Add-ons declared by modules (`addons` in `module.nansen.json`): listed, downloaded from GitHub into an add-ons folder put on MATLAB's path, or installed with pip, from the Settings page in either language |
| `nansen.App` on the Java Widgets Toolbox | One HTML/JS dashboard for MATLAB (`uihtml`) and Python (browser) |
| Apps in `+nansen/apps` (imviewer, roimanager, roiclassifier, fovmanager) | Dashboard pages: the viewer in the core (frames, projections, channels and planes, channels in colour, plane montage and projection, zoom, PNG export; ROIs added round, drawn, detected, moved, merged and classified, alone or in a gallery; the selected ROI's signal and neuropil; a second stack beside it, linked frame, zoom and pan), the signals page, and pages that modules add (`dashboard` scripts): the ophys module's FOV map and ROI review. They use only the protocol, so they work with either backend |
| `ophys.twophoton` module: session methods, file adapters, toolbox wrappers | The `ophys` module: motion correction (rigid, subpixel or piecewise rigid), ROI detection, signals, ΔF/F, deconvolution, denoising, downsampling, deinterleaving and session alignment (with rotation) native in both languages with the same results, on recordings of any length, channels and planes; SciScan, TIFF, ScanImage, Bruker and HDF5 readers, and ROIs from suite2p (its `Fall.mat` or output folder), CaImAn, EXTRACT and VHLab; suite2p, CaImAn, NoRMCorre, EXTRACT, Flow-Registration, DeepInterpolation and imviewer where installed |
| MATLAB only | MATLAB R2023a+ and Python 3.9+, held to the same behaviour by shared conformance cases |
| ~360 unit tests with a throwaway user session | Unit tests in both languages, conformance cases shared by both, browser tests for the dashboard |

Not carried over, by choice or not yet:

- **Nothing of the two-photon module.** The `ophys` module brings over dev's two-photon workflow natively in both languages (see [modules](reference/modules.md#the-ophys-module)): Quicky as `ophys.quicky` (and dev's flufinder itself as `ophys.flufinder` in MATLAB), DeepInterpolation as `ophys.deep_interpolation` (and native smoothing, `ophys.denoise`, which needs no trained network), and wrappers for suite2p, NoRMCorre, EXTRACT, Flow-Registration and CaImAn; suite2p and DeepInterpolation in either language (the MATLAB Suite2P and DeepInterpolation-MATLAB, as dev ran them). Each wrapper is run against its real tool in CI. The imviewer, roimanager and roiclassifier apps are the dashboard's viewer (frames, projections, ROIs over them, curation), fovmanager is the module's FOV map page (windows, FOVs, any number of injection sites and notes per subject), and the multi-session ROI classifier is its ROI review page; `ophys.open_in_imviewer` still opens dev's imviewer where it is installed.
- **Dev's `+nansen` internals that the new architecture replaces** (the session object model, `OptionsManager`, `DataLocationModel`, Java table widgets): see the table above.

## Decisions recorded so far

- **Monorepo.** Schemas, conformance cases, both implementations and the frontend live in one repository, so a schema change and both implementations move in one pull request. This can be split once the schemas settle.
- **Envelope:** `schemaType` + `schemaVersion`, matching DSM. See [conventions](conventions.md#why-this-convention).
- **Namespace `nansen` in both languages.** The existing NANSEN also uses `+nansen`, and MATLAB merges package folders of the same name, so the two must never be on the path together. Run the new core on a path with nothing else on it; `runNansenCoreTests` refuses to start if another `+nansen` folder is on the path. The Python distribution is named `nansen-core` and imports as `nansen`.
- **MATLAB R2023a minimum.** This is what `uihtml`'s `sendEventToHTMLSource` needs, and it is what `dev` requires today. CI tests on R2023a and the latest release.
- **Validation in MATLAB** uses a small draft-07 interpreter ported from DSM's MATLAB reader, so both languages validate against the schema files themselves. A Python test keeps the schemas within the keywords it implements.
- **Fragments carry their own version.** A table records the version of each fragment its columns follow. A mismatch is an error for now (see the open questions).
- **Modules** (from `dev`) supply fragments, methods, adapters and pipelines through an explicit list in the project file, not by scanning the MATLAB path.

## Mixed-language queues

The project format is shared and each method declares its implementations. A task names the language that must run it when only the other language has the method (NoRMCorre or EXTRACT queued from Python), and each language's worker takes only its own tasks; recovering after a crash fails only its own. A headless worker runs a language's tasks without an app (`nansen worker <folder>`, `nansen.worker(folder)`), and the Tasks page starts one of the other language when tasks wait for it (`queue.startWorker`). Running such a method now (`methods.run`: the run dialog, Find ROIs in the viewer, a pipeline's next step) queues it for that language, starts a worker and waits for the task, so every method can be run from either app; only previews (`methods.preview`) stay in-language.

## Open questions

- **Fragment migrations.** When a fragment's columns change, who migrates existing tables? The likely answer is a migration function shipped by the module that owns the fragment.
- **Large tables.** Measured on CI runners: 20,000 rows read in 0.6 s (Python) and 0.5 s (MATLAB, column by column, falling back to cell by cell to report the first error in row order). For 5,000 sessions on disk, Python scans in 0.6 s and lists them in 0.25 s; MATLAB scans in 7 s (5 s of it DSM's walk) and lists them in 2 s. `EntitiesTest/largeProjectTimings` logs these on every CI run, and with `NANSEN_PROFILE=1` also where the time goes. Hundreds of thousands of entities would also want the scan cached per folder and the dashboard to page through `entities.list`.
