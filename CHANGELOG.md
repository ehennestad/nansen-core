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
- `load` keeps what it read in the project's data cache, as dev's `DataCache` does: 2 GiB, least recently used out first. An entry is read again when its file's time or size changes, and `save` drops the entry of the file it writes. `load(..., cached=False)` / `Cached=false` reads without it.

**Methods and tasks**

- Added modules, which provide fragments, methods, file adapters and pipelines. Added the built-in `core` module: notes, file statistics, export and wait methods, an inspect pipeline, and the demo ([modules](docs/reference/modules.md)).
- Methods declare JSON Schema options and save presets, and can be implemented in MATLAB, in Python or both. Computed fragments are filled by a method.
- Added a task queue in the project folder, with atomic claims, cancellation, logs, recovery, retry, dependencies and pipelines. As in dev's batch processor, queued tasks can be put on hold, reordered and given new options (`tasks.hold`, `tasks.reorder`, `tasks.update`); a task is changed only while its claim is held, so no worker starts it halfway. Python runs tasks in threads or processes, and MATLAB in the foreground or on a `backgroundPool`.

**App**

- Added the app protocol, with the same API in both languages ([protocol](docs/reference/protocol.md)), and the project catalog.
- Added the dashboard: one HTML/JS app, shown by `nansen.App` in MATLAB (`uihtml`) and by `nansen app` in Python (local server with Server-Sent Events). It shows the overview, entity tables, the detail drawer, method forms with presets, pipelines, the live task queue, data and the catalog, in light and dark themes.
- Added `nansen demo` / `nansen.demo.create`: a two-photon demo project, built from the same description in both languages.
- The dashboard creates projects (optionally from an existing DSM config, with its entity types), the demo, and imports from NANSEN. A project without a dataset gets a form to set one up. Columns can be added to tables that already have rows (`fragments.create`, `fragments.attach`): NANSEN's table variables without code.
- The MATLAB app is tested end to end in CI: the dashboard loads in a `uihtml` under a virtual display, and its requests reach the API. On R2023a in CI a `uihtml` runs no page at all, so there the test checks that first and is marked incomplete.
- Added notebooks: dated notes on entities, typed as note, important, to do or question, with #tags, as dev's session and subject notebooks keep them. One `nansen.notebook` file per entity type, the `notes.list`, `notes.add` and `notes.remove` API methods, a Notes section in each entity's drawer, and a Notes page that filters by type and searches text, tags and keys.
- Saved views of entity tables, as dev's extra metatables: a view holds a list of rows (keys) and/or filters, hidden columns and a search (`views.list`, `views.save`, `views.delete`). The table has per-column filters (a list of values, a range, yes/no, text, empty or not) shown as chips, a Views menu to switch, save, update and delete views, and the selection bar adds rows to a view or makes one. The legacy importer makes a view of each filtered table.
- Pipelines can be assigned to entities, as in dev. Progress is read from a run journal (`runs/<entityType>.runs.jsonl`, appended to whenever a method completes), shown as a progress column and in the entity's drawer, and `pipelines.queueNext` queues the steps that are left. A Pipelines page makes, edits and deletes the project's pipelines (`pipelines.save`, `pipelines.delete`), and customizes a module's.
- Columns can have `choices`: the API refuses other values and the dashboard edits them with a list. A fragment can be removed from an entity type again (`fragments.detach`), and a column reset to its default (`columns.reset`), from a menu on each column header, which also sorts and hides. The new `core.subject` fragment holds date of birth, sex and species, as dev's subject table did; subject types made from a dataset get it, and the legacy importer maps dev's `DateOfBirth`, `BiologicalSex` and `Species` to it.
- Row and folder actions, as in dev's session context menu: copy the keys of the selected rows, remove rows from the table, show an entity's folders (or the project's) in the file browser and copy their paths (`files.resolve`, `files.reveal`, which never leave the project folder or the data roots). Ignored rows can be hidden, and a saved preset can be deleted.
- Data variables and modules are configured from the app. The Data page adds, edits and deletes data variables, choosing a location, a file pattern of the entity type's level there, and a file adapter (`dataVariables.options`, `dataVariables.save`, `dataVariables.delete`). The overview's Modules card adds and removes modules found in the project's `modules` folder or built in (`modules.list`, `modules.add`, `modules.remove`); a module the project still uses is not removed (`module-in-use`).
- Data locations can be pointed somewhere else per machine (`setRoot` / `set_root`, `dataset.setRoot`, "Change path" on the Data page). Roots per environment live in the DSM config and the active environment in its `.local.json` overlay. The whole DSM config can be edited as text from the Data page (`dataset.get`, `dataset.save`): it is written as given, but only once DSM accepts it and the tables' keys still match it.
- Shared JSON files, such as a DSM config, are edited as text (`nansen.jsontext`, `nansen.internal.JsonText`), so they keep their formatting and MATLAB does not change their arrays. A `jsontext` conformance kind holds both editors to the same bytes.

**Import**

- Added the importer for NANSEN dev projects: `nansen.legacy.importProject` in MATLAB, and `nansen import-legacy` in Python for an exported project ([legacy import](docs/reference/legacy-import.md)).

**Tests**

- Added conformance cases for documents, tables, projects, entities, data, legacy import and the app protocol. The MATLAB package (R2023a+) and the Python package (3.9+) both pass every case. The dashboard has browser tests.
- CI times a 5,000-session project and a 20,000-row table in both languages. CI also runs the DSM reader's own MATLAB suite against the DSM branch nansen-core uses.
