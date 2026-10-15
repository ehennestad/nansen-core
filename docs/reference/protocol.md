# App protocol

The frontend talks to the core through one JSON protocol. Python serves it over HTTP (`nansen app`), and MATLAB serves it through `uihtml` (`nansen.App`). Both answer with the same methods and result shapes, and the [`conformance/api`](../../conformance/api) cases hold them to that.

## Messages

A request:

```json
{ "id": 7, "method": "entities.list", "params": { "entityType": "session" } }
```

A response carries the same `id` and either `result` or `error`:

```json
{ "id": 7, "result": { ... } }
{ "id": 7, "error": { "code": "unknown-entity", "message": "..." } }
```

Error codes are those in [conventions](../conventions.md#error-codes), plus:

| Code | Meaning |
|---|---|
| `invalid-request` | The request is not an object with a method |
| `unknown-api-method` | No such method |
| `invalid-params` | A parameter is missing or has the wrong shape |
| `no-project` | The method needs an open project |
| `legacy-needs-matlab` | Python was asked to read a NANSEN dev project folder; export it from MATLAB first |
| `internal-error` | An unexpected failure; the message says what happened |

Events flow from the core to the frontend:

```json
{ "event": "task", "data": { ...nansen.task document... } }
```

| Event | When | Data |
|---|---|---|
| `project` | A project was opened or created | `{name}` |
| `scan` | The stores were scanned | The `project.scan` result |
| `entities` | Rows changed | `{entityTypes, keys?}` |
| `notes` | A note was added or removed | `{entityType, key?}` |
| `pipelines` | A pipeline was saved or deleted | `{id}` |
| `views` | A view was saved or deleted | `{entityType}` |
| `task` | A task was queued, started, made progress or finished | The task document |
| `removed` | A task was removed | `{id}` |
| `log` | A running task logged a line | `{id, line}` |

## Transports

- **HTTP (Python).** `POST /api` takes a request and returns the response. `GET /events` is a Server-Sent Events stream of events. Static files are served from `ui/`.
- **uihtml (MATLAB).** The page calls `htmlComponent.sendEventToMATLAB("request", json)`. MATLAB answers with `sendEventToHTMLSource(h, "response", json)`, and pushes events as `sendEventToHTMLSource(h, "event", json)`.

## Methods

| Method | Params | Result |
|---|---|---|
| `app.info` | | `{name, language, version, protocolVersion, methods, workspace}`; `workspace` says whether `workspace.send` has somewhere to put entities |
| `workspace.send` | `entityType`, `keys?`, `name?` (default `entities`) | `{name, count}`: the entities are put in the workspace the app was opened from, as a variable of that name: MATLAB's base workspace (a cell row of `nansen.Entity`), or in Python the namespace given to `nansen.server.open_app` (a list of `Entity`). `no-workspace` when there is none |
| `catalog.list` | | Projects in the catalog, most recently opened first |
| `catalog.remove` | `path` | The remaining projects |
| `project.open` | `path`, `environment?` | `project.info` |
| `project.create` | `path`, `name`, `title?`, `description?`, `dataset?` (a config in the folder) or `datasetSource?` (a config to copy in; its relative roots are made absolute), `modules?`, `entityTypes?` (true: one per DSM entity type, with `core.notes` when `core` is listed) | `project.info` |
| `project.setDataset` | `datasetSource`, `modules?`, `entityTypes?` | `project.info`: the open project with a copy of that DSM config (`dataset-exists` if it has one) |
| `dataset.setRoot` | `dataLocation`, `path`, `rootStoragePath?` or `environment?` | `project.info`. With `rootStoragePath`, that root gets the path. Otherwise the location's root in that environment (default: the active one, else this machine's host name) gets the path, or a root is added; a new environment becomes active on this machine (the config's `.local.json`), and other locations with no root there get one at their current path |
| `dataset.get` | | `{path, text}`: the DSM config's file name in the project and its text as written |
| `dataset.save` | `text` | `project.info`. The text is written as given, once DSM accepts it (`dataset-invalid` otherwise) and the key of each table still matches the identity it gives the entity type (`key-mismatch` otherwise); when refused, nothing changes. Scan again to see what the new config finds |
| `demo.create` | `path` (an empty or new folder) | `project.info` of the demo project, now open |
| `legacy.import` | `source` (a NANSEN dev project folder, MATLAB only, or a `nansen.legacyExport` JSON file), `path` | `{project: project.info, warnings}` |
| `project.info` | | `{name, title, description, folder, entityTypes[{name, title, fragments, rows, records}], modules, lastScan, dataset{environment, entityTypes, locations, roots}}` |
| `project.scan` | `listing?` (a DSM DirectoryListing, instead of the file system) | `{scannedAt, records{type: count}, roots, unmatched}` |
| `project.sync` | `entityType?` | `{added{type: [keys]}}` |
| `entities.list` | `entityType` | `{entityType, key, columns[{name, dataType, title, unit, fragment, source: key\|table\|attribute\|progress, editable, choices?}], rows[{key, inStore, inTable, values, issues?, progress?}]}; with `core.pipeline`, a `progress` column (the fraction of the pipeline done) and each row's `progress {pipeline, title, done, total}` |
| `entities.get` | `entityType`, `key` | A row plus `locations`, `issueDetails`, `data` (data variable status), and `pipeline` when it has one: `{pipeline, title, steps[{title, method, done, finishedAt}], done, total}` |
| `entities.update` | `entityType`, `key`, `values` | The updated row; key and computed columns are `read-only-column` |
| `entities.add` | `entityType`, `key`, `values?` | The new row |
| `entities.remove` | `entityType`, `key` | `{removed}` |
| `files.resolve` | `path` (relative; "" for the folder itself), `dataLocation?`, `rootStoragePath?` | `{path, exists, isFolder}`: the absolute path inside the project folder, or inside the location's root. `invalid-params` for an absolute path or one that leads out with `..` |
| `files.list` | `path`, `dataLocation?`, `rootStoragePath?`, `limit?` (default 500) | As `files.resolve`, plus `entries[{name, isFolder, size, modified}]` (folders first, then files, each by name; `size` is null for a folder) and `truncated`. `file-not-found` if there is nothing there, `invalid-params` if it is a file |
| `files.reveal` | as `files.resolve` | The same, after showing the folder (a file's folder) in the system's file browser; `file-not-found` if it does not exist |
| `views.list` | `entityType` | The entity type's saved views: `[{name, description?, keys?, filters?, hiddenColumns?, search?}]` |
| `views.save` | `entityType`, `view` | The view, added or put in place of the one of the same name. A filter is `{column, op}` with `op` `in` (`values`), `range` (`min`, `max`), `is` (`value`), `contains` (`text`), `empty` or `notEmpty` |
| `views.delete` | `entityType`, `name` | `{removed}` (`unknown-view` if there is no such view) |
| `notes.list` | `entityType?`, `key?` (needs `entityType`) | Notes, newest first, each with its `entityType`: `[{id, entityType, key, createdAt, author, type, title, text, tags}]` |
| `notes.add` | `entityType`, `key`, `text`, `title?`, `type?` (`informal`, `important`, `todo` or `question`; default `informal`), `author?` (default: the user name) | The note; its `tags` are the `#words` in the title and text |
| `notes.remove` | `entityType`, `id` | `{removed}` (`unknown-note` if there is no such note) |
| `fragments.list` | | `[{id, version, title, description, computed, columns}]` |
| `fragments.create` | `document` (a `nansen.fragment`), `entityType?` | The fragment summary; with `entityType`, it is also added to that entity type (as `fragments.attach`) |
| `fragments.attach` | `entityType`, `fragmentId` | `{entityType, fragments}`; existing rows get the columns' defaults |
| `fragments.detach` | `entityType`, `fragmentId` | `{entityType, fragments}`; the fragment's columns and their values leave the table |
| `columns.reset` | `entityType`, `column`, `keys?` | `{reset}`: how many rows got the column's default again (none if it has no default); key columns are `read-only-column` |
| `fragments.update` | `entityType`, `fragmentId`, `keys?` | `{updated, failed}` |
| `dataVariables.list` | `entityType?` | Data variable documents |
| `dataVariables.options` | `entityType` | `{locations[{id, title, access, filePatterns}], fileAdapters}`: what a data variable of the entity type can name; `filePatterns` are the names of the file patterns of the entity type's level in each location, sorted |
| `dataVariables.save` | `document` (a `nansen.dataVariable`) | The data variable, written into the project (replacing one of the same name) |
| `dataVariables.delete` | `name` | `{removed}` (`unknown-data-variable` if there is none) |
| `modules.list` | | `[{id, version, title, description, ..., listed}]`: the modules in the project's `modules/` folder and the built-in ones, and any listed elsewhere; `listed` says whether the project lists it |
| `modules.add` | `id`, `path?` | `project.info`: the project with the module listed (`unknown-module` if it cannot be found) |
| `modules.remove` | `id` | `project.info`; `module-in-use` while a fragment, data variable or project pipeline of the project uses the module |
| `data.status` | `entityType`, `key` | `[{name, dataLocation, fileAdapter, files}]` |
| `methods.list` | `entityType?` | Method summaries, including the options schema |
| `methods.create` | `id` (a lower-case letter, then letters, digits or `_`), `title?`, `entityType?` (default `*`), `description?`, `batchMode?` (`serial` or `batch`), `languages?` (default both) | The new project method's summary, plus `files`: its document in `methods/` and a file to fill in per language (`python/<id>.py` with `run`, `matlab/<id>.m`), made from the templates in `templates/`. `method-exists` if the id or a file is taken |
| `methods.run` | `methodId`, `entityType`, `keys?`, `options?`, `preset?` | `{results}`, run in the foreground |
| `presets.list` / `presets.save` / `presets.delete` | `methodId`, `name`, `values`, `description?` | The method's presets, each with its `source`: `default` (the schema's defaults, always first), `project` (saved in the project; only these can be deleted), or `module` (shipped by the module named in `module`, unless the project has one of the same name) |
| `pipelines.list` | `entityType?` | Pipeline documents, each step with its method's title, and `source`: `project` or `module` |
| `pipelines.save` | `document` (a `nansen.pipeline`) | The pipeline, written into the project; one with a module pipeline's id is used instead of it |
| `pipelines.delete` | `pipelineId` | `{removed}`; only the project's own pipelines (`unknown-pipeline` otherwise) |
| `pipelines.assign` | `entityType`, `keys?` (all rows when left out), `pipelineId` (null: none) | `{assigned}`; adds `core.pipeline` to the entity type if it has not got it |
| `pipelines.queueNext` | `entityType`, `keys?`, `language?` | `{tasks, skipped}`: for each entity with a pipeline, a chain of the steps from the first not done on. Entities with no pipeline, all steps done, or steps of it queued or running are skipped |
| `pipelines.submit` | `pipelineId`, `entityType`, `keys?`, `language?` | The queued tasks: one chain per entity, each step waiting for the one before |
| `tasks.submit` | `methodId`, `entityType`, `keys?`, `options?`, `preset?`, `language?` | The queued task |
| `tasks.list` | `status?` | Tasks in creation order; queued tasks start in queue order: those with an `order`, lowest first, then the others by creation |
| `tasks.get` | `id` | The task plus `logText` |
| `tasks.cancel` / `tasks.retry` / `tasks.remove` | `id` | The task (or `{removed}`) |
| `tasks.hold` | `id`, `hold?` (default true) | The task: a queued task on hold (`onHold`) is not started until it is released with `hold: false`; it keeps its place |
| `tasks.update` | `id`, `options?`, `preset?` | The task with new options: the preset's values with `options` on top, resolved and validated as in `tasks.submit` |
| `tasks.reorder` | `ids` | The queued tasks in their new order: these first, in this order, then the others as they were. A task still waits for the tasks in its `after` |
| `tasks.clear` | | `{removed: count}` of finished tasks |
| `tasks.runNext` | | The task run now in the foreground, or null |
| `queue.status` / `queue.start` / `queue.stop` | | `{running, executor, counts}` |

Keys are objects of key column values, for example `{"subject_id": "m110", "session_id": "m110-20250523-001"}`. Row `values` hold the key, the DSM attributes and the authored values in JSON form, with dates and datetimes as strings.
