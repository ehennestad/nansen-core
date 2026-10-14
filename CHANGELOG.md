# Changelog

## 0.1.0 (unreleased)

The first release covers every step of the plan in [docs/architecture.md](docs/architecture.md).

**Documents and tables**

- Added the document envelope: `schemaType` + `schemaVersion` on every JSON document, per-type semantic versions, and in-memory migrations ([conventions](docs/conventions.md)).
- Added schemas for projects, fragments, tables, scans, data variables, file adapters, modules, methods, options, tasks, pipelines, the project catalog and the legacy export.
- Added the table format: CSV plus a JSON sidecar, with typed columns, distinct missing values and empty strings, canonical number and datetime forms, a key, and a revision counter for optimistic concurrency ([table format](docs/reference/table-format.md)).
- Added the project layout ([project layout](docs/reference/project-layout.md)). A project is opened from a folder, with no global state, and CI checks that the core uses no `global`, `persistent`, preferences or root appdata.

**Entities and data**

- Entities are DSM records joined with the authored tables. Table keys are checked against DSM identity, `sync` adds rows for new entities, scans are cached, and roots are chosen per environment ([entities](docs/reference/entities.md)).
- New entities get their paths from DSM's path generation (added to DSM, in both of its readers).
- Data variables find their files through DSM file patterns or file name templates, and read and write them with file adapters: `json`, `text`, `mat`, and `npy` in Python.

**Methods and tasks**

- Added modules, which provide fragments, methods, file adapters and pipelines. Added the built-in `core` module: notes, file statistics, export and wait methods, an inspect pipeline, and the demo ([modules](docs/reference/modules.md)).
- Methods declare JSON Schema options and save presets, and can be implemented in MATLAB, in Python or both. Computed fragments are filled by a method.
- Added a task queue in the project folder, with atomic claims, cancellation, logs, recovery, retry, dependencies and pipelines. Python runs tasks in threads or processes, and MATLAB in the foreground or on a `backgroundPool`.

**App**

- Added the app protocol, with the same API in both languages ([protocol](docs/reference/protocol.md)), and the project catalog.
- Added the dashboard: one HTML/JS app, shown by `nansen.App` in MATLAB (`uihtml`) and by `nansen app` in Python (local server with Server-Sent Events). It shows the overview, entity tables, the detail drawer, method forms with presets, pipelines, the live task queue, data and the catalog, in light and dark themes.
- Added `nansen demo` / `nansen.demo.create`: a two-photon demo project.

**Import**

- Added the importer for NANSEN dev projects: `nansen.legacy.importProject` in MATLAB, and `nansen import-legacy` in Python for an exported project ([legacy import](docs/reference/legacy-import.md)).

**Tests**

- Added conformance cases for documents, tables, projects, entities, data, legacy import and the app protocol. The MATLAB package (R2023a+) and the Python package (3.9+) both pass every case. The dashboard has browser tests.
