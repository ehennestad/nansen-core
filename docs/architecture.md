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

Each step is usable without a GUI before the next one starts.

| Step | Contents | Status |
|---|---|---|
| 1 | Envelope convention, schemas, project layout, entity tables (CSV + sidecar), fragments, conformance, `Project` without globals | **This release** |
| 2 | DSM integration: entity records joined with authored tables; key columns checked against DSM identity; records cached under `cache/`; path generation for derived locations (implemented in DSM first, both readers and conformance) | Next |
| 3 | Data variables (DSM file pattern + file adapter) and an explicit adapter registry; existing adapters wrapped | |
| 4 | Methods, options and tasks: method declarations with JSON Schema options, presets, tasks as `nansen.task` documents (entity references, never live objects); MATLAB runs on `parfeval`/`backgroundPool`, Python on a process pool | |
| 5 | JSON message protocol and the HTML/JS frontend in one `uihtml` (MATLAB) or a local server (Python) | |
| 6 | One-way importer from `dev` projects (`project.nansen.json` + `.mat` files) | |

## Decisions recorded so far

- **Monorepo.** Schemas, conformance cases, both implementations and the frontend live in one repository, so a schema change and both implementations move in one pull request. This can be split once the schemas settle.
- **Envelope:** `schemaType` + `schemaVersion`, matching DSM. See [conventions](conventions.md#why-this-convention).
- **Namespace `nansen` in both languages.** The existing NANSEN also uses `+nansen`, and MATLAB merges package folders of the same name, so the two must never be on the path together. Run the new core on a path with nothing else on it; `runNansenCoreTests` refuses to start if another `+nansen` folder is on the path. The Python distribution is named `nansen-core` and imports as `nansen`.
- **MATLAB R2023a minimum.** This is what `uihtml`'s `sendEventToHTMLSource` needs, and it is what `dev` requires today. CI tests on R2023a and the latest release.
- **Validation in MATLAB** uses a small draft-07 interpreter ported from DSM's MATLAB reader, so both languages validate against the schema files themselves. A Python test keeps the schemas within the keywords it implements.
- **Fragments carry their own version.** A table records the version of each fragment its columns follow. A mismatch is an error for now; fragment migrations come with modules.
- **Modules** (from `dev`) will supply fragments, methods, data variables and adapters through an explicit list in the project file, not by scanning the MATLAB path.

## Open questions

- **Projects and languages.** Can a Python project run MATLAB methods and the reverse? The current proposal: the project format is shared, and each method declares its language.
- **Fragment migrations.** When a fragment's columns change, who migrates existing tables? The likely answer is a migration function shipped by the module that owns the fragment.
- **Large tables.** Both CSV readers are simple loops. If tables reach tens of thousands of rows, MATLAB will need a column-vectorised parser that still reports the first error in row order.
