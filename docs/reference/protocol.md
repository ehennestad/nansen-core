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
| `moduleData` | A module's data was saved | `{module, name, revision}` |

## Transports

- **HTTP (Python).** `POST /api` takes a request and returns the response. `GET /events` is a Server-Sent Events stream of events. Static files are served from `ui/`. The server listens on this machine only and answers only the page it served: it writes a random token into the `index.html` it serves (`<meta name="nansen-token">`), and `POST /api` needs it in an `X-Nansen-Token` header, `GET /events` as `?token=`. Requests whose `Host` is not this machine (DNS rebinding) or whose `Origin` is another site get 403, so another web page open in the browser cannot drive the app.
- **uihtml (MATLAB).** The page calls `htmlComponent.sendEventToMATLAB("request", json)`. MATLAB answers with `sendEventToHTMLSource(h, "response", json)`, and pushes events as `sendEventToHTMLSource(h, "event", json)`.

## Methods

| Method | Params | Result |
|---|---|---|
| `app.info` | | `{name, language, version, protocolVersion, methods, workspace}`; `workspace` says whether `workspace.send` has somewhere to put entities |
| `app.plugins` | | `[{module, path, code}]`: the dashboard scripts of the project's modules (`dashboard` in `module.nansen.json`); `[]` with no project open. The dashboard runs each with `N` and the module id; a script adds pages with `N.registerPage({id, title, icon, render(app, el)})`, listed under Modules in the sidebar |
| `workspace.send` | `entityType`, `keys?`, `name?` (default `entities`) | `{name, count}`: the entities are put in the workspace the app was opened from, as a variable of that name: MATLAB's base workspace (a cell row of `nansen.Entity`), or in Python the namespace given to `nansen.server.open_app` (a list of `Entity`). `no-workspace` when there is none |
| `catalog.list` | | Projects in the catalog, most recently opened first |
| `catalog.relocate` | `path` (as the catalog has it), `newPath` | The catalog, with the entry pointing at the folder the project was moved to; the project there must have the entry's name (`invalid-params`), and must be there (`file-not-found`) |
| `catalog.remove` | `path` | The remaining projects |
| `catalog.install` | `url` (a git repository, e.g. on GitHub), `path` (an empty or new folder) | The catalog's projects, with the project cloned there (`git clone --depth 1`), as dev's installProject; its data locations' roots stay to be set on this computer. `folder-not-empty`, `install-failed` (git's message), `not-a-project` when the repository holds none, `dependency-missing` without git |
| `settings.get` | | The user's app settings, kept in the catalog, with defaults for those not set: `{queue: {autoStart, worker}, addons: {folder}, workers: {python, matlab}}` (`autoStart`, default true: the app starts the background worker whenever it opens a project; `worker`, default `thread`: `process` runs each task in a process of its own, in MATLAB on a process pool, for methods that cannot run on a thread) |
| `settings.save` | `settings` (some of them, in the same shape) | All the settings (`no-catalog` without a catalog, `invalid-params` for a setting that does not exist or a wrong value) |
| `addons.list` | | `{folder, language, addons[{id, title, description, language, module, url, source, spec, check, installed, location, installable, removable, how}]}`: the add-ons the project's modules declare (the built-in modules' with no project open). `installed` is true or false where this backend can tell (MATLAB toolboxes in MATLAB, Python packages in Python, and anything downloaded into `folder`), else null; `how` says how it is installed |
| `addons.install` | `id`, `archive?` (a local .zip of a GitHub add-on, or a file for pip, to use instead of the internet) | The add-on's entry, installed: a GitHub add-on is downloaded into the add-ons folder (and in MATLAB put on the path and its `setup` run); a pip one is installed into the running Python. `unknown-addon`, or `install-failed` with the reason (a conda package says how to install it) |
| `addons.remove` | `id` | The add-on's entry: a downloaded add-on deleted (and taken off MATLAB's path). `install-failed` for one NANSEN did not download |
| `project.open` | `path`, `environment?` | `project.info` |
| `project.create` | `path`, `name`, `title?`, `description?`, `dataset?` (a config in the folder) or `datasetSource?` (a config to copy in; its relative roots are made absolute), `modules?`, `entityTypes?` (true: one per DSM entity type, with `core.notes` when `core` is listed) | `project.info` |
| `project.update` | `title?`, `description?`, `entityTypeTitles?` (`{entityType: title}`) | `project.info`; an empty text removes the title (the name is shown) or description; `unknown-entity-type` before anything changes |
| `project.setDataset` | `datasetSource` (a config to copy) or `datasetText` (a config as text, written as given), `modules?`, `entityTypes?` | `project.info`: the open project with that DSM config (`dataset-exists` if it has one, `dataset-invalid` if DSM refuses it) |
| `dataset.setRoot` | `dataLocation`, `path`, `rootStoragePath?` or `environment?` | `project.info`. With `rootStoragePath`, that root gets the path. Otherwise the location's root in that environment (default: the active one, else this machine's host name) gets the path, or a root is added; a new environment becomes active on this machine (the config's `.local.json`), and other locations with no root there get one at their current path |
| `dataset.sample` | `path` (absolute, or in the project folder), `depth?` (default 4), `limit?` (default 8) | `{path, levels[{folders, moreFolders, files}]}`: example folder names at each level under the folder, up to `limit` per level, from up to `limit` folders of the level above, by name; `moreFolders` counts those left out and `files` the files seen. For describing a layout (the dashboard's dataset wizard) |
| `dataset.test` | `text` (a DSM config) | `{records{type: count}, examples{type: [keys]}, roots, unmatched, unmatchedExamples[{dataLocation, path, reason}]}`: what a scan with that config finds now, with up to 5 example keys per entity type and 10 unmatched entries; nothing is kept. Relative roots are read from the project folder |
| `dataset.get` | | `{path, text}`: the DSM config's file name in the project and its text as written |
| `dataset.save` | `text` | `project.info`. The text is written as given, once DSM accepts it (`dataset-invalid` otherwise) and the key of each table still matches the identity it gives the entity type (`key-mismatch` otherwise); when refused, nothing changes. Scan again to see what the new config finds |
| `demo.create` | `path` (an empty or new folder) | `project.info` of the demo project, now open |
| `legacy.import` | `source` (a NANSEN dev project folder, MATLAB only, or a `nansen.legacyExport` JSON file), `path` | `{project: project.info, warnings}` |
| `project.info` | | `{name, title, description, folder, entityTypes[{name, title, fragments, rows, records}], modules, lastScan, dataset{environment, entityTypes, locations, roots}}` |
| `project.scan` | `listing?` (a DSM DirectoryListing, instead of the file system) | `{scannedAt, records{type: count}, roots, unmatched}` |
| `scan.unmatched` | `limit?` (default 1000) | `{scannedAt, total, entries[{dataLocation, rootStoragePath, path, reason, detail}]}`: what the last scan found that no entity accounts for, by location and path. Entries a scan skipped on purpose (reason `excluded`) are left out, here and in `project.scan`'s `unmatched` count |
| `dataset.exclude` | `dataLocation`, `path` (as `scan.unmatched` gives it) | `{dataLocation, level, pattern}`: an `excludePatterns` entry for the entry's exact name is added at its level of the DSM config (once; the text keeps its formatting), and the last scan forgets the entry |
| `project.sync` | `entityType?` | `{added{type: [keys]}}`; added rows get the first pipeline whose `assignWhen` filters they pass |
| `entities.list` | `entityType` | `{entityType, key, columns[{name, dataType, title, unit, fragment, source: key\|table\|attribute\|progress, editable, choices?, display?, action?}], rows[{key, inStore, inTable, values, issues?, progress?}]}; with `core.pipeline`, a `progress` column (the fraction of the pipeline done) and each row's `progress {pipeline, title, done, total}` |
| `entities.get` | `entityType`, `key` | A row plus `locations`, `issueDetails`, `data` (data variable status), and `pipeline` when it has one: `{pipeline, title, steps[{title, method, queueable, done, finishedAt}], done, total}` |
| `entities.update` | `entityType`, `key`, `values` | The updated row; key and computed columns are `read-only-column` |
| `entities.add` | `entityType`, `key`, `values?` | The new row |
| `entities.remove` | `entityType`, `key` | `{removed}` |
| `files.resolve` | `path` (relative; "" for the folder itself), `dataLocation?`, `rootStoragePath?` | `{path, exists, isFolder}`: the absolute path inside the project folder, or inside the location's root. `invalid-params` for an absolute path or one that leads out with `..` |
| `files.list` | `path`, `dataLocation?`, `rootStoragePath?`, `limit?` (default 500) | As `files.resolve`, plus `entries[{name, isFolder, size, modified}]` (folders first, then files, each by name; `size` is null for a folder) and `truncated`. `file-not-found` if there is nothing there, `invalid-params` if it is a file |
| `files.inspect` | `path`, `dataLocation?`, `rootStoragePath?`, `limit?` (default 2000) | As `files.resolve`, plus the layout of an HDF5 file (NWB, MATLAB v7.3, .h5): `format: "hdf5"`, `items[{path, name, kind, ...}]` (the root first, then by path) and `truncated`. A `group` or `dataset` has `attributes` (those that are one string or number) and `neurodataType` when NWB gives it one; a `dataset` has `shape` (in the file's order; `[]` for a scalar), `dataType` (`float32`, `int16`, `uint8`, ..., `string`, `enum`, `compound`, `reference` or `other`) and, for a scalar string or number, `value`; a `link` has `target`. `unsupported-file` for any other file, `dependency-missing` without h5py in Python, `invalid-params` for a folder |
| `files.open` | `path`, `dataLocation?`, `rootStoragePath?` | As `files.resolve`; the file is opened in its default app (`file-not-found` if it is not there, `invalid-params` for a folder) |
| `files.reveal` | as `files.resolve` | The same, after showing the folder (a file's folder) in the system's file browser; `file-not-found` if it does not exist |
| `views.list` | `entityType` | The entity type's saved views: `[{name, description?, keys?, filters?, hiddenColumns?, search?}]` |
| `views.save` | `entityType`, `view` | The view, added or put in place of the one of the same name. A filter is `{column, op}` with `op` `in` (`values`), `range` (`min`, `max`), `is` (`value`), `contains` (`text`), `empty` or `notEmpty` |
| `views.delete` | `entityType`, `name` | `{removed}` (`unknown-view` if there is no such view) |
| `notes.list` | `entityType?`, `key?` (needs `entityType`) | Notes, newest first, each with its `entityType`: `[{id, entityType, key, createdAt, author, type, title, text, tags}]` |
| `notes.add` | `entityType`, `key`, `text`, `title?`, `type?` (`informal`, `important`, `todo` or `question`; default `informal`), `author?` (default: the user name) | The note; its `tags` are the `#words` in the title and text |
| `notes.remove` | `entityType`, `id` | `{removed}` (`unknown-note` if there is no such note) |
| `fragments.list` | | `[{id, version, title, description, computed, columns, source}]`; `source` is `project` (in its `fragments/`, so it can be changed) or `module` |
| `fragments.create` | `document` (a `nansen.fragment`), `entityType?` | The fragment summary; with `entityType`, it is also added to that entity type (as `fragments.attach`) |
| `fragments.save` | `document` (a `nansen.fragment` of the project) | The fragment summary. Titles, descriptions, units, defaults and choices change; the columns keep their names, types and order (`fragment-mismatch`), so the values stay. New choices must allow the values in every table holding it (`invalid-value`). The version goes up a patch step unless a higher one is given (a lower one is `invalid-params`), and the tables record it. A module's fragment is `fragment-read-only` |
| `fragments.attach` | `entityType`, `fragmentId` | `{entityType, fragments}`; existing rows get the columns' defaults |
| `fragments.detach` | `entityType`, `fragmentId` | `{entityType, fragments}`; the fragment's columns and their values leave the table |
| `columns.reset` | `entityType`, `column`, `keys?` | `{reset}`: how many rows got the column's default again (none if it has no default); key columns are `read-only-column` |
| `fragments.update` | `entityType`, `fragmentId`, `keys?` | `{updated, failed}` |
| `dataVariables.list` | `entityType?` | Data variable documents |
| `dataVariables.options` | `entityType` | `{locations[{id, title, access, filePatterns}], fileAdapters}`: what a data variable of the entity type can name; `filePatterns` are the names of the file patterns of the entity type's level in each location, sorted |
| `adapters.create` | `id` (a lower-case letter, then letters, digits or `_`), `title?`, `extensions?` (such as `.tif`), `languages?` (default both) | The new file adapter document of the project, plus `files`: it in `file-adapters/` and a class to fill in per language (`python/<id>_adapter.py`, `matlab/<Id>Adapter.m`, with read and write), from `templates/`. `adapter-exists` if the id (built in or not) or a file is taken |
| `dataVariables.save` | `document` (a `nansen.dataVariable`) | The data variable, written into the project (replacing one of the same name) |
| `dataVariables.delete` | `name` | `{removed}` (`unknown-data-variable` if there is none) |
| `modules.list` | | `[{id, version, title, description, ..., listed}]`: the modules in the project's `modules/` folder and the built-in ones, and any listed elsewhere; `listed` says whether the project lists it |
| `modules.resource` | `module`, `path` (relative, inside the module's folder) | `{module, path, text}`: a text file of one of the project's modules, such as a dashboard page's data. `unknown-module` for a module the project does not use, `invalid-params` for a path that leaves the folder, `file-not-found` |
| `modules.data` | `module`, `name` (letters, digits, `_` and `-`) | `{module, name, text, revision}`: data one of the project's modules keeps in the project (`module-data/<module>/<name>.json`, a `nansen.moduleData` document), as JSON text, given back exactly as it was saved; `"null"` and revision 0 when there is none |
| `modules.saveData` | `module`, `name`, `text` (JSON text), `revision?` | `{module, name, revision}`: the data saved, with its revision one up. With `revision`, only when that is still the stored revision (`revision-conflict` otherwise), so two windows do not overwrite each other; `invalid-params` for text that is not JSON |
| `modules.add` | `id`, `path?` | `project.info`: the project with the module listed (`unknown-module` if it cannot be found) |
| `modules.remove` | `id` | `project.info`; `module-in-use` while a fragment, data variable or project pipeline of the project uses the module |
| `data.status` | `entityType`, `key` | `[{name, dataLocation, fileAdapter, dataType, files}]`: `files` are those that exist, where a scan found the entity's folders or, for a folder made since, where `save` wrote |
| `data.frame` | `entityType`, `key`, `variable`, `frame?` (0-based, default 0), `channel?` (0-based, for height x width x channels x frames), `plane?` (0-based, for height x width x channels x planes x frames), `projection?` (`mean`, `max` or `std` over the frames, or `correlation`, each pixel's average Pearson correlation over time with its 8 neighbours; instead of a frame), `limits?` (`[low, high]`), `rois?` (a variable holding ROIs) | `{height, width, frames, frame, low, high, pixels, rois?, metadata}`: the frame of an image or stack (height x width x frames), for the viewer. Values from `low` to `high` (the `limits`, or else the frame's smallest and largest finite value) are scaled to 0..255 as floor((v - low) / (high - low) * 255 + 0.5), cut at both ends, NaN as 0; `pixels` is base64 of those bytes, row after row. `rois` are `[{id, pixels, classification}]`, with 0-based `[row, column]` pixels, from a JSON value `{imageSize?, rois: [{id?, pixels, classification?}]}` as `ophys.detect_rois` saves. `metadata` is what the stack's files tell about the recording, each key only when they give it: `frameRate` (frames per second; volumes per second for a stack with planes), `pixelSize` (`[x, y]`, µm per pixel) and `zStep` (µm between planes); `{}` for an array. The viewer shows a scalebar from `pixelSize` and each frame's time from `frameRate`. `invalid-data` if the variable is not a numeric array of 2 to 5 dimensions, `invalid-params` for a frame, channel, plane or projection that is not there |
| `data.traces` | `entityType`, `key`, `variables` (signal variables: frames x ROIs arrays, or a vector for one), `columns?` (0-based, default `[0]`), `start?`, `stop?` (0-based frames, `stop` excluded; default all), `maxPoints?` (default 2000), `rois?` (an ROI variable), `frameRate?` (frames per second) | `{frames, start, step, points, frameRate, traces: [{variable, count, columnNames?, columns: [{column, values}]}], rois?}`: the columns of each variable at frames `start`, `start + step`, … before `stop`, `step` the smallest that keeps it to `maxPoints`; `frames` is the longest variable's, `count` its number of columns. Values are rounded to 4 decimals as floor(v * 10000 + 0.5) / 10000; NaN, infinities and frames past a variable's end are null. `rois` are the ROI variable's `[{id, classification}]`, for naming the columns. `columnNames` are the data variable's, when it has them. `frameRate` is the one given, else the entity's `frame_rate` when that is a positive number, else null: the dashboard then shows time in seconds. `invalid-data` if a variable is not a 1-D or 2-D numeric array, `invalid-params` for a column that is not there |
| `rois.update` | `entityType`, `key`, `variable` (an ROI variable, as `data.frame` reads), `restore?` (`[{id, pixels, classification?}]`: the ROIs, all of them, as they were, ids kept: the viewer's undo and redo), `classify?` (`[{id, classification}]`: `accepted`, `rejected` or null for none), `pixels?` (`[{id, pixels}]`: an ROI's pixels from now on, its id and classification kept: grow, shrink),  `move?` (`[{id, rows, columns}]`: whole-pixel shifts; pixels leaving the image are left out), `merge?` (`[[id, id, ...]]`: the first ROI of each group takes the pixels of all of them and keeps its id and classification, the others are removed), `remove?` (ids), `add?` (`[{pixels}]`) | `{rois, added}`: the ROIs as `data.frame` gives them, after the change is saved, and the ids of the added ROIs. Changes are made in that order. A restored, reshaped, moved, merged or added ROI gets its `area` and `center` (rounded to 2 decimals) again, and pixels outside `imageSize` are left out; an added ROI gets the next free id. `invalid-params` for an id that is not there, another classification, a merge of fewer than two different ids, or an ROI that would have no pixels inside |
| `rois.detect` | `entityType`, `key`, `variable` (an image, or a stack: its mean over the frames), `point` (`[row, column]`, 0-based), `radius?` (default 6), `channel?`, `plane?` | `{pixels}`: an ROI found around the point, for the viewer's Detect tool, not saved. In the square of `radius` around the point, the threshold is halfway from its 20th percentile to the brightest pixel within `radius` of the point; the ROI is the 4-connected area of pixels within `radius` reaching it around the brightest pixel within 2 of the point, its holes filled. `[]` when that pixel is below the threshold; `invalid-params` for a point outside the image |
| `data.cache` / `data.clearCache` | | `{entries, bytes, maxBytes, hits, misses, evictions}`: what `load` keeps in memory for the project (dev's DataCache), and with `data.clearCache` after it is emptied, so the next load of each variable reads its file |
| `rois.signal` | `entityType`, `key`, `variable` (a stack), `pixels` (`[[row, column], ...]`, 0-based), `channel?`, `plane?`, `start?`, `stop?`, `maxPoints?`, `frameRate?` | The mean of the pixels in each frame, read from the stack now, as `data.traces` gives one column (`traces[0]` with the stack's name, `count` 1): the viewer's live signal of an ROI added or changed since the signals were extracted. `invalid-params` for pixels outside the image |
| `data.send` | `entityType`, `key`, `variable`, `name?` (default: the variable's name) | `{name, variable}`: the data variable is loaded for the entity and put in the workspace the app was opened from, as `workspace.send` does (`no-workspace` when there is none) |
| `methods.list` | `entityType?` | Method summaries, including the options schema and `tool` (whether it is a project tool); with `entityType`, only the methods that run on it, so no tools |
| `methods.edit` | `methodId`, `language?` | `{language, path}`: the method's code file, opened in an editor (MATLAB's editor; in Python `$VISUAL`, `$EDITOR` or the system's editor). Without `language`, the app's own language when the method has it. `method-unavailable` for a language it has no implementation in |
| `tools.list` | | Summaries of the project tools: methods with `entityType` `@project` |
| `tools.run` | `methodId`, `options?`, `preset?` | `{result, log}`: the tool, run now and once on the project, and the lines it logged; `wrong-entity-type` for a method that is not a tool |
| `methods.create` | `id` (a lower-case letter, then letters, digits or `_`), `title?`, `entityType?` (default `*`), `description?`, `batchMode?` (`serial` or `batch`), `languages?` (default both), `queueable?` (default true; false for a method run by hand), `computes?` (columns: a computed fragment of the same id that the method fills, added to `entityType`; the method then runs on that entity type, serially, and its function returns a value per column) | The new project method's summary, plus `files`: its document in `methods/` and a file to fill in per language (`python/<id>.py` with `run`, `matlab/<id>.m`), made from the templates in `templates/`. `method-exists` if the id or a file is taken |
| `methods.run` | `methodId`, `entityType`, `keys?`, `options?`, `preset?`, `startTimeout?` (seconds, default 300) | `{results}`, run in the foreground. A method only the other language has is queued for that language, a worker is started for it (`queue.startWorker`) and the call waits for the task: `{results, taskId, language}`; `task-failed` if it fails, is cancelled, or no worker takes it within `startTimeout` (it is then cancelled) |
| `methods.preview` | `methodId`, `entityType`, `key`, `options?`, `preset?`, `frames?` (default 20) | `{frames, results, outputs, log}`: the method run on one entity with every stack it opens cut to its first `frames` frames, writing nothing; what it saves is kept in memory (and read back from there). `outputs` has, per variable saved, `{name, kind}`: `array` with `size`, `min`, `max`, `mean` (4 decimals) and, when it is at least 8 x 8, `image` (`{height, width, low, high, pixels}` of its mean over the frames, as `data.frame`), `document` (with `rois`, their number, for ROIs), or `value` |
| `presets.list` / `presets.save` / `presets.delete` | `methodId`, `name`, `values`, `description?` | The method's presets, each with its `source`: `default` (the schema's defaults, always first), `project` (saved in the project; only these can be deleted), or `module` (shipped by the module named in `module`, unless the project has one of the same name) |
| `pipelines.list` | `entityType?` | Pipeline documents, each step with its method's title, and `source`: `project` or `module` |
| `pipelines.save` | `document` (a `nansen.pipeline`) | The pipeline, written into the project; one with a module pipeline's id is used instead of it |
| `pipelines.delete` | `pipelineId` | `{removed}`; only the project's own pipelines (`unknown-pipeline` otherwise) |
| `pipelines.assign` | `entityType`, `keys?` (all rows when left out), `pipelineId` (null: none) | `{assigned}`; adds `core.pipeline` to the entity type if it has not got it |
| `pipelines.queueNext` | `entityType`, `keys?`, `language?` | `{tasks, skipped, manual}`: for each entity with a pipeline, a chain of the steps from the first not done on, up to a step that cannot be queued (a method with `queueable: false`, run by hand). Entities with no pipeline, all steps done, or steps of it queued or running are `skipped`; those whose next step is to run by hand are in `manual` as `{key, step, method, title}` |
| `pipelines.runNext` | `entityType`, `keys?` | `{ran[{key, step, method, result}], skipped}`: each entity's next step not done, run now in the foreground (a manual step too), with the step's preset and options; entities with nothing left or steps in the queue are skipped |
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
| `queue.status` / `queue.start` / `queue.stop` | | `{running, executor, worker, counts}`: `executor` is the backend's language, `worker` how its worker runs tasks (`thread` or `process`, the `queue.worker` setting). `queue.start` with the `process` worker in a MATLAB without the Parallel Computing Toolbox is `dependency-missing` |
| `queue.startWorker` | `language` (`python` or `matlab`) | The app's own language: as `queue.start`. The other: `{language, started, log}`, a worker of that language started in the background for the tasks only it runs (`python -m nansen worker <folder> --until-empty`, or `matlab -batch "nansen.worker(<folder>, UntilEmpty=true)"`), which stops when none is left; its output goes to `tasks/worker-<language>.log`. The executable is the `workers` setting, else MATLAB's `pyenv` or `python3`, and `matlab` on the PATH. `dependency-missing` when it cannot be found |

Keys are objects of key column values, for example `{"subject_id": "m110", "session_id": "m110-20250523-001"}`. Row `values` hold the key, the DSM attributes and the authored values in JSON form, with dates and datetimes as strings.
