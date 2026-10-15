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
| `DataLocationModel` (root paths, subfolder structure, metadata rules) | A DSM config: locations, roots per environment, folder levels, extraction rules; the same file is read by DSM's own tools. The Data page sets roots per machine and edits the config as text, checked by DSM before it is saved |
| `VariableModel` (file path settings) | Data variables: DSM file pattern or file name template + file adapter; added, edited and deleted on the Data page |
| `MetaTable` of `Session`/`Subject` objects | Entity tables joined with DSM records; one generic entity, so entity types are documents, not classes |
| Table variables (with update functions) | Fragments; computed fragments for the ones with update functions |
| Session methods with `OptionsManager` presets | Methods with JSON Schema options and preset documents; MATLAB and/or Python implementations |
| Notebooks of sessions and subjects (`HasNotes`, note viewer) | Notebooks: dated, typed notes with #tags per entity, in one `nansen.notebook` per entity type; on an entity's drawer and the Notes page |
| Batch processor with `task_list.mat` | Task queue of `nansen.task` files: claims, cancellation, logs, recovery, retry, dependencies; queued tasks held, reordered and given new options |
| Pipelines | Pipelines: one chain of tasks per entity; assigned to entities, with each one's progress from a run journal |
| Extra metatables | Saved views of a table: rows (keys), column filters, hidden columns, a search |
| Session context menu (copy, remove, open folder, send to workspace) | The selection bar and the drawer: copy keys, remove rows, show or copy folders, browse an entity's files, `workspace.send` (MATLAB's base workspace, or a Python namespace) |
| Session method templates, project apps | `methods.create` from `templates/`; project tools (`entityType` `@project`) on the overview |
| File adapters | File adapters: built-in `json`, `text`, `mat` (and `npy` in Python), others from modules |
| `nansen.cache.DataCache`, one per MATLAB session | A data cache per project (`project.data_cache`, `project.DataCache`): the same 2 GiB least-recently-used budget, and an entry is read again when its file changes on disk |
| Modules (`module.nansen.json`) | Modules listing fragments, methods, adapters and pipelines by path; code for either language; added and removed from the overview |
| `nansen.App` on the Java Widgets Toolbox | One HTML/JS dashboard for MATLAB (`uihtml`) and Python (browser) |
| MATLAB only | MATLAB R2023a+ and Python 3.9+, held to the same behaviour by shared conformance cases |
| ~360 unit tests with a throwaway user session | Unit tests in both languages, conformance cases shared by both, browser tests for the dashboard |

Not carried over, by choice or not yet:

- **Add-on and toolbox management.** Out of scope for the core.

## Decisions recorded so far

- **Monorepo.** Schemas, conformance cases, both implementations and the frontend live in one repository, so a schema change and both implementations move in one pull request. This can be split once the schemas settle.
- **Envelope:** `schemaType` + `schemaVersion`, matching DSM. See [conventions](conventions.md#why-this-convention).
- **Namespace `nansen` in both languages.** The existing NANSEN also uses `+nansen`, and MATLAB merges package folders of the same name, so the two must never be on the path together. Run the new core on a path with nothing else on it; `runNansenCoreTests` refuses to start if another `+nansen` folder is on the path. The Python distribution is named `nansen-core` and imports as `nansen`.
- **MATLAB R2023a minimum.** This is what `uihtml`'s `sendEventToHTMLSource` needs, and it is what `dev` requires today. CI tests on R2023a and the latest release.
- **Validation in MATLAB** uses a small draft-07 interpreter ported from DSM's MATLAB reader, so both languages validate against the schema files themselves. A Python test keeps the schemas within the keywords it implements.
- **Fragments carry their own version.** A table records the version of each fragment its columns follow. A mismatch is an error for now (see the open questions).
- **Modules** (from `dev`) supply fragments, methods, adapters and pipelines through an explicit list in the project file, not by scanning the MATLAB path.

## Open questions

- **Mixed-language queues.** The project format is shared and each method declares its implementations; a task can name the language that must run it, so a Python app can queue MATLAB work for a MATLAB worker. Whether the dashboard should start that worker is open.
- **Fragment migrations.** When a fragment's columns change, who migrates existing tables? The likely answer is a migration function shipped by the module that owns the fragment.
- **Large tables.** Measured on CI runners: 20,000 rows read in 0.6 s (Python) and 0.5 s (MATLAB, column by column, falling back to cell by cell to report the first error in row order). For 5,000 sessions on disk, Python scans in 0.6 s and lists them in 0.25 s; MATLAB scans in 7 s (5 s of it DSM's walk) and lists them in 2 s. `EntitiesTest/largeProjectTimings` logs these on every CI run, and with `NANSEN_PROFILE=1` also where the time goes. Hundreds of thousands of entities would also want the scan cached per folder and the dashboard to page through `entities.list`.
