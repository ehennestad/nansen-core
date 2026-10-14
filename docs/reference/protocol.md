# App protocol

The frontend talks to the core through one JSON protocol. Python serves it over HTTP (`nansen app`), and MATLAB serves it through `uihtml` (`nansen.app.App`). Both answer with the same methods and result shapes, and the [`conformance/api`](../../conformance/api) cases hold them to that.

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
| `task` | A task was queued, started, made progress or finished | The task document |
| `removed` | A task was removed | `{id}` |
| `log` | A running task logged a line | `{id, line}` |

## Transports

- **HTTP (Python).** `POST /api` takes a request and returns the response. `GET /events` is a Server-Sent Events stream of events. Static files are served from `ui/`.
- **uihtml (MATLAB).** The page calls `htmlComponent.sendEventToMATLAB("request", json)`. MATLAB answers with `sendEventToHTMLSource(h, "response", json)`, and pushes events as `sendEventToHTMLSource(h, "event", json)`.

## Methods

| Method | Params | Result |
|---|---|---|
| `app.info` | | `{name, language, version, protocolVersion, methods}` |
| `catalog.list` | | Projects in the catalog, most recently opened first |
| `catalog.remove` | `path` | The remaining projects |
| `project.open` | `path`, `environment?` | `project.info` |
| `project.create` | `path`, `name`, `title?`, `description?`, `dataset?` (a config in the folder) or `datasetSource?` (a config to copy in; its relative roots are made absolute), `modules?`, `entityTypes?` (true: one per DSM entity type, with `core.notes` when `core` is listed) | `project.info` |
| `project.setDataset` | `datasetSource`, `modules?`, `entityTypes?` | `project.info`: the open project with a copy of that DSM config (`dataset-exists` if it has one) |
| `dataset.setRoot` | `dataLocation`, `path`, `rootStoragePath?` or `environment?` | `project.info`. With `rootStoragePath`, that root gets the path. Otherwise the location's root in that environment (default: the active one, else this machine's host name) gets the path, or a root is added; a new environment becomes active on this machine (the config's `.local.json`), and other locations with no root there get one at their current path |
| `demo.create` | `path` (an empty or new folder) | `project.info` of the demo project, now open |
| `legacy.import` | `source` (a NANSEN dev project folder, MATLAB only, or a `nansen.legacyExport` JSON file), `path` | `{project: project.info, warnings}` |
| `project.info` | | `{name, title, description, folder, entityTypes[{name, title, fragments, rows, records}], modules, lastScan, dataset{environment, entityTypes, locations, roots}}` |
| `project.scan` | `listing?` (a DSM DirectoryListing, instead of the file system) | `{scannedAt, records{type: count}, roots, unmatched}` |
| `project.sync` | `entityType?` | `{added{type: [keys]}}` |
| `entities.list` | `entityType` | `{entityType, key, columns[{name, dataType, title, unit, fragment, source: key\|table\|attribute, editable}], rows[{key, inStore, inTable, values, issues?}]}` |
| `entities.get` | `entityType`, `key` | A row plus `locations`, `issueDetails`, `data` (data variable status) |
| `entities.update` | `entityType`, `key`, `values` | The updated row; key and computed columns are `read-only-column` |
| `entities.add` | `entityType`, `key`, `values?` | The new row |
| `entities.remove` | `entityType`, `key` | `{removed}` |
| `fragments.list` | | `[{id, version, title, description, computed, columns}]` |
| `fragments.create` | `document` (a `nansen.fragment`), `entityType?` | The fragment summary; with `entityType`, it is also added to that entity type (as `fragments.attach`) |
| `fragments.attach` | `entityType`, `fragmentId` | `{entityType, fragments}`; existing rows get the columns' defaults |
| `fragments.update` | `entityType`, `fragmentId`, `keys?` | `{updated, failed}` |
| `dataVariables.list` | `entityType?` | Data variable documents |
| `data.status` | `entityType`, `key` | `[{name, dataLocation, fileAdapter, files}]` |
| `methods.list` | `entityType?` | Method summaries, including the options schema |
| `methods.run` | `methodId`, `entityType`, `keys?`, `options?`, `preset?` | `{results}`, run in the foreground |
| `presets.list` / `presets.save` / `presets.delete` | `methodId`, `name`, `values`, `description?` | The method's presets |
| `pipelines.list` | `entityType?` | Pipeline documents, each step with its method's title |
| `pipelines.submit` | `pipelineId`, `entityType`, `keys?`, `language?` | The queued tasks: one chain per entity, each step waiting for the one before |
| `tasks.submit` | `methodId`, `entityType`, `keys?`, `options?`, `preset?`, `language?` | The queued task |
| `tasks.list` | `status?` | Tasks in creation order |
| `tasks.get` | `id` | The task plus `logText` |
| `tasks.cancel` / `tasks.retry` / `tasks.remove` | `id` | The task (or `{removed}`) |
| `tasks.clear` | | `{removed: count}` of finished tasks |
| `tasks.runNext` | | The task run now in the foreground, or null |
| `queue.status` / `queue.start` / `queue.stop` | | `{running, executor, counts}` |

Keys are objects of key column values, for example `{"subject_id": "m110", "session_id": "m110-20250523-001"}`. Row `values` hold the key, the DSM attributes and the authored values in JSON form, with dates and datetimes as strings.
