# Importing a NANSEN dev project

A project made with the existing NANSEN (`dev` branch) can be converted into a nansen-core project. The old project is only read, never changed.

```matlab
report = nansen.legacy.importProject("~/NANSEN/projects/RatNav", "~/nansen/RatNav");
report.warnings      % what could not be carried over
```

The import has two steps, because the dev MetaTables are MATLAB `table` objects in `.mat` files, which only MATLAB can read:

1. **Export (MATLAB).** `nansen.legacy.exportProject(folder)` reads the dev files and returns a `nansen.legacyExport` document. This is plain JSON with no MATLAB types left in it ([schema](../../schema/legacy-export.schema.json)), and it holds the text of the project's own session methods. Pass `File=` to save it.
2. **Convert (MATLAB or Python).** `nansen.legacy.convert(export, folder)` writes the new project. In Python, `nansen import-legacy export.json folder` does the same, so the export can be made on a machine with MATLAB and converted anywhere. Given a dev project folder, the Python app (`legacy.import`) runs the export itself with `matlab -batch` when MATLAB is installed (on the PATH, or set in Settings). The cases in [`conformance/legacy`](../../conformance/legacy) hold both implementations to the same result.

## What is read

| dev file | Contents used |
|---|---|
| `project.nansen.json` | `Properties.Name`, `ShortName`, `Description` |
| `configurations/datalocation_settings.mat` | Data locations: name, type, root paths, `SubfolderStructure`, `MetaDataDef` |
| `configurations/filepath_settings.mat` | Variables: name, data location, subfolder, file name expression, file type, file adapter |
| `metadata/tables/*.mat` | MetaTables: `MetaTableEntries`, `MetaTableClass`, `MetaTableName`, `IsMaster` |
| `configurations/pipeline_settings.mat` | Pipelines: name, tasks (name, function, option preset), session properties that assign it |
| `configurations/custom_options/*.mat` | Option presets a user made (`OptionsEntries` of `Type` `Custom`: name, description, `Options`), by function, and `DefaultOptionsName` |
| `code/+<name>/+sessionmethod/**/*.m` | The project's own session methods: each file's path and text |
| `code/+<name>/+fileadapter/**` | The project's own file adapters: each `.m` file, and each `fileadapter.json` of a function-based adapter, with its path and text |
| `code/+<name>/+tablevariable/+<entity type>/*.m` | The project's own table variables, with their path and text |
| `metadata/tables/*.mat`, the `Progress` column | Each session's pipeline (`PipelineName`) and the tasks of it marked finished (`TaskList`: `FunctionName`, `IsFinished`, `DateFinished`) |
| `metadata/tables/metatable_catalog.mat` | The table of each kind dev opens first (`IsDefault` of `metaTableCatalog`) |
| `metadata/tables/metatable_column_settings.json` (or `.mat`, `MetatableColumnSettings`, of older versions) | The tables' column layout, as dev's table viewer saved it: per table variable `VariableName`, `ColumnLabel`, `ShowColumn`, `ColumnWidth`, `ColumnOrder` |

and, from the user's own preferences (dev's `nansen.prefdir`; `UserFolder=` of `exportProject` and `importProject`, `userFolder` of `legacy.import`; by default `prefdir/Nansen/default`, dev's default user):

| dev file | Contents used |
|---|---|
| `custom_options/*.mat` | Option presets a user made of dev's own methods (OptionsManager keeps those of `+nansen` functions here, such as `nansen.wrapper.normcorre.Processor`), as above |
| `projects/<name>/task_list.mat` | The task list (`<name>` is the project's package, `code/+<name>`): queued tasks (`method`, `name`, `entityId` or the sessions in `args`, the options in `args`, `parameters`, `timeCreated`, `comments`) and the history (the same, and `status`, `timeStarted`, `timeFinished`, `Diary` and `ErrorStack`: its identifier, message and stack) |
| `projects/<name>/datalocation_local_rootpath_settings.json` (or `.mat`) | The roots of the data locations on this computer, where dev kept them apart from the project's (`LocalRootPathManager`: `RootPathListLocal`, by each location's `Uuid` and each root's `Key`) |
| `settings/task_list.mat` | The task list of older versions of dev (`nansen.localpath('TaskList')`), one for all the user's projects, read as the other after it; a task the project's list has too is read once. Its tasks of other projects' sessions are named in the warnings as not here |
| `settings/nansen_app_settings.mat` | `nansen.App`'s preferences (`settings`) |

Values become JSON where they have a JSON form (structs, text, numbers, logicals, cells of text); options that have none (function handles, objects) are named in the export (`skippedOptions`) and in the warnings. dev's session objects in a task (a queued task's, and a finished one's in older versions, which kept them in the history) are of dev's session class, which is not there without dev: the export reads the task list with stand-ins of dev's session classes on the path (`nansen.metadata.type.Session` and `Subject`, and the classes the tables name, `MetaTableClass` and `ItemClassName`), which take the ids (`sessionID`, `subjectID`) of each object saved and drop the rest, and removes them again. So a task of several sessions (dev's `Multisession`) names its sessions too. With dev on the path, dev's own classes are used.

## How it maps

**Project.** `name` is the short name, made into an identifier. `title` is the full name, and `description` is copied over. The project lists the `core` module.

**Data locations → `dataset.dsm.json`.**

- Each location with a root path becomes a DSM filesystem location. Its identifier is the location name in lower case. `recorded` locations are `raw` and read-only, `processed` are `processed`, and `curated` are `derived`.
- dev's local root paths (the roots a computer that is not the one the project was made on keeps for itself) become roots of the DSM environment `dev-local`, beside the project's, which stay the default: a root of the same key, at the local path, its identifier the root's with `-dev-local` (`local-dev-local`). dev does not name the computer, so on that computer open the project in that environment (`environment=`, or `preferences.environmentIdentifier` in the config's `.local.json`; see [roots and environments](entities.md#roots-and-environments)). A local path that is the project's, or of a key the location has no root of (dev passed those over too), is left out; the warnings say how many were added.
- Each folder level becomes an `entityLayout` level. A level of type `Subject` holds subjects and a level of type `Session` holds sessions. `Date` and other levels are structural. When no level has the type `Session`, the deepest level holds sessions, as in dev.
- A level's `Expression` becomes its `matchPattern`, which is matched anywhere in the name as in dev. Its `IgnoreList` becomes `excludePatterns`, and hidden folders are excluded too.
- Metadata rules become `metadataMapping` entries. `Subject ID`, `Session ID`, `Experiment Date` and `Experiment Time` map to `subject_id`, `session_id`, `session_date` and `session_time`. Other variables keep their name in snake case.
  - An index rule (`ind`) becomes a `substring` slice. For example, `1:8` becomes `:8` and `5:end` becomes `4:`.
  - A regular expression (`expr`) becomes a `regex` rule. It keeps the whole match, as dev did.
  - A function (`func`) becomes a `function` rule. You must register an extractor of that name.
  - A rule that reads several levels at once has no DSM equivalent and is left out.
  - With no rule, a subject or session id is the whole folder name, as in dev.

**Tables.**

- The master table of sessions becomes the `session` table, keyed by `subject_id` and `session_id`. The master table of subjects becomes the `subject` table, keyed by `subject_id`. A filtered (non-master) table holds a subset of the master's rows; it becomes a saved view of the entity type with the keys of its rows. A row that holds only part of the key, such as the session id, is found in the master table; rows that are not found are left out of the view, with a warning.
- `Ignore` and `Description` go to the `core.notes` fragment.
- `Date` and `Time` are left out of the session table when the dataset reads them from folder names: they are DSM attributes now.
- Every other column with a table type goes to a fragment `legacy.<entityType>` in the project. Columns holding structs or objects, such as `DataLocation`, are left out and listed. The `Progress` column is read for the sessions' pipelines ([below](#pipeline-progress-and-the-task-list)).
- Rows without a complete key are left out. A row whose key appears twice is left out after the first.
- An entity type the dataset has but dev kept no table of gets an empty table with `core.notes`. Fill it with `project.sync`.
- The notes in a `Notebook` column go into the entity type's [notebook](project-layout.md), on the entity of their row and in the order they were written. Their author, time, title and text are kept. Their type maps to `informal`, `important`, `todo` or `question`; any other type becomes `informal`, with a warning. Their tags are found again from the `#words`. Notes on rows that were left out, and notes without a time, are left out and counted in the warnings.

**Table variables.** The project's own table variables (`code/+<name>/+tablevariable/+session/Name.m`, `+subject/...`) come in as `columns.import` brings them ([modules](modules.md#importing-columns-and-file-adapters)), with the values dev's table holds:

- A class (`classdef Name < nansen.metadata.abstract.TableVariable`) is the column of its name in `legacy.<entityType>`: a text column gets its `LIST_ALTERNATIVES` as `choices`, with the values the table holds besides them added (and named in the warnings); a yes/no column gets the default of its `DEFAULT_VALUE`.
- A function (`value = Name(sessionObject)`) makes its column computed: the column moves from `legacy.<entityType>` to a fragment of its own, the name in snake case (`num_rois`), filled by a MATLAB method of that id that calls dev's function, copied beside it as `matlab/num_rois_value.m`. The values dev computed stay in the table; updating the fragment computes them again.
- A table variable dev's table had no column of yet is added to `legacy.<entityType>` (of the type of its default). One whose column is a key, a dataset attribute or a module's here (`Date`), one of an entity type dev kept no table of, and a file that is not a table variable are left out, named in the warnings.

**Views and the column layout.**

- A filtered table becomes a view, as above. The table dev opened first (the catalog's `IsDefault`) is the view the table opens with (`default`).
- dev's column layout (which columns its table showed, in which order and how wide) goes onto the views of each table: `hiddenColumns` (`ShowColumn` false), `columnOrder` (by `ColumnOrder`) and `columnWidths` (`ColumnWidth`), each by the column's name here (`sessionID` is `session_id`, `Ignore` is `ignore`, `Date` is `session_date`). dev's preference `MetadataTable.ShowIgnoredEntries`, when false, adds the filter `ignore` is no. A table with a layout also gets a view of all its rows, of the master table's name, with them; it is the one the table opens with, unless dev opened a filtered table first.
- A column's `ColumnLabel` is the title of the column when it is the project's own (in `legacy.<entityType>`, or a table variable's); the keys, the dataset's attributes and the modules' columns keep their titles, and those labels are named in the warnings.

**Variables → data variables.**

- Each variable becomes a data variable of sessions in its location, when its file adapter has an equivalent. `Default` maps by file type (`.mat`, `.json`, `.txt`), and `MatFile`, `Json` and `Text` map to the adapter of the same name. dev's ROI files (`RoiArray`, `RoiGroup`) map to the ophys module's `ophys.nansen_roi_array`, which keeps their classifications, and `ImageStack` by file type to `ophys.tiff_stack` (`.tif`), `ophys.binary_stack` (`.raw`, `.bin`, `.dat`: dev's own binary stacks, such as its motion-corrected recordings, and SciScan's), `ophys.hdf5_stack` (`.h5`) or `npy`; the project then lists the ophys module. A variable read by one of the project's own file adapters (by its name, any case) gets that adapter as imported ([below](#file-adapters)). A variable dev kept as a named variable of a `.mat` file, through its `Default` adapter or `RoiSignalArray` (which keeps every ROI signal in one file), gets `variableInFile`: it loads that variable of the file, as dev did, and saving it keeps the file's other variables. Variables of other adapters are left out, named in the warnings.
- The file name follows dev's: `{session_id}_<expression><file type>`. Without an expression, the variable name is used in snake case.
- A variable without a subfolder also gets a DSM file pattern on the session level. Existing files are then found by the end of their name, as dev did.
- Internal variables are left out.

### Pipelines

- Each pipeline becomes a pipeline of sessions (`legacy.<name>`) with the tasks whose session method has an equivalent here: dev's NoRMCorre and Flow-Registration motion correction, Quicky, suite2p and EXTRACT segmentation, signal extraction, ΔF/F, CaImAn deconvolution, downsampling, DeepInterpolation denoising and backup. Tasks without one (plots, viewers, ROI curation apps) are left out, named in the warnings, and so is a pipeline left with no task. A Quicky or NoRMCorre task keeps its preset as the ophys module's preset of dev's values: Quicky's Soma, Soma_Virus and Axon (and Default, which is Soma's values) as `soma`, `soma_virus` and `axon`, NoRMCorre's Default (4 x 4 nonrigid) and Rigid as `nonrigid` and `rigid`. A preset a user made keeps its name, as imported ([below](#option-presets)). Other presets are named in the warnings, and those steps use the method's defaults.
- A task that calls one of the project's own session methods (by its full function name) becomes a step of that method as imported (see below).
- Its session properties become `assignWhen` rules: `contains` stays `contains`, `match` becomes `in`, on the column the variable was imported to. The session table gets `core.pipeline`, which keeps each session's pipeline and progress.

### Option presets

The presets users made (OptionsManager's `Custom` entries, of the project's functions and of the user's) become presets of the method here, `options/<method>/<name>.options.nansen.json`, with dev's description:

- of the project's own session methods: dev's options as they are (the method runs dev's code, which takes them);
- of NoRMCorre (`nansen.wrapper.normcorre.Processor`) and Quicky (`nansen.wrapper.quicky.Processor`): dev's options mapped to the ophys method's: `Configuration.numRows` (and `numCols`) is `patches`, `patchOverlap` `overlap`, `Template.initialBatchSize`, `updateTemplate` and `binWidth` the same, `Correction.maximumShift` `maxShift`, `maximumDeviation` `maxDeviation`, `subpixelUpsampling` `upsampling`, `numIterations` `iterations` (of a row such as `[40, 40, 5]`, the first); Quicky's (flufinder's) `General.RoiDiameter`, `Preprocessing.BinningSize` and `SmoothingSigma`, `Detection.PrctileForBinarization`, `NumObservationsRequired`, `MaxNumRois`, `UseShapeDetection`, `InnerRadius` and `OuterRadius` are `roiDiameter`, `binSize`, `smoothingSigma`, `binarizationPercentile`, `observationsRequired`, `maxRois`, `useShapeDetection`, `innerRadius` and `outerRadius`. dev's other options of them are named in the warnings.

A name keeps letters, digits, `_`, `.` and `-` (others become `_`); `Default`, the method's own defaults here, becomes `Default_dev`. An option whose value does not fit the method's options schema is left out of the preset, with a warning. dev's `DefaultOptionsName`, when it is one of these presets or one of dev's that the module has (NoRMCorre's `Rigid`), becomes the method's preferred preset (`presets.setDefault`): the one it runs with when none is chosen, as in dev.

### Pipeline progress and the task list

- **Progress column.** A session that follows one of the imported pipelines gets it in `core.pipeline`. The tasks of it dev marked finished (`IsFinished`, with `DateFinished`) become lines of the run journal (`runs/session.runs.jsonl`): the step is done, as the drawer and the table's progress show. A session whose pipeline was left out gets none; finished tasks of a method not here, or without a date, are counted in the warnings.
- **Queued tasks** become queued tasks of the method here, in dev's order (`order`), **on hold**, so nothing runs before they are released on the Tasks page; those of the project's task list first, then those of the older one. Their sessions are found in the session table by their ids, and a task of several sessions is one task of those sessions here, as in dev. The options are dev's (mapped as presets are, for NoRMCorre and Quicky) over the preset the task was queued with (dev's `parameters`: a preset imported, or the module's of dev's values); a method only one language has gets that language. Tasks of a method not here, of sessions not here, or of a method that cannot run in the background are left out, named in the warnings.
- **History.** Each task of the history (completed, failed or canceled) of a method here, on sessions here, is a finished task of the queue with dev's status (`completed`, `failed`, `cancelled`), options (as a queued task's), times (`timeCreated`, `timeStarted`, `timeFinished`) and comment: what it wrote in the command window (`Diary`) is its log (`tasks/<id>.log`), and dev's error (`ErrorStack`: identifier, message, stack as `name (line n)`) its `error`, so the Tasks page shows them as it shows a task's of this queue, and **Retry** runs it again with dev's options. A completed task is also a line of the run journal at the time it finished. Tasks of methods or sessions not here are counted in the warnings, as are those of a method that cannot run in the background.

### File adapters

The project's own file adapters (`code/+<name>/+fileadapter`) come in as `adapters.import` brings dev's ([modules](modules.md#importing-columns-and-file-adapters)): a class that subclasses `nansen.dataio.FileAdapter` or one of dev's own adapters (below), or a function-based adapter's folder (`fileadapter.json`, `read.m`, `write.m`), is copied into `matlab/` in its packages and gets a document `file-adapters/legacy.<name in snake case>.fileAdapter.nansen.json` with `legacyFileAdapter`. The variables dev read with it become data variables of that adapter. MATLAB reads and writes them with dev's code, unchanged (`nansen.legacy.FileAdapterShim`, with `matlab/devcompat`'s `nansen.dataio.FileAdapter`), and so do the session methods (`loadData`, `saveData`). Python cannot run dev's MATLAB code: reading one there is `adapter-unavailable`, naming MATLAB. Other files there (functions, classes built on other classes of dev's) are left out and named.

dev's own adapters are readers of known formats, and a project's adapter may subclass one of them to add to it. The document of such a class has dev's data type and file types (the constants a subclass keeps), and `legacyFileAdapter` names the class it is built on (`base`) and the adapter here that reads and writes a file of each type in its place (`builtIn`):

| dev's adapter (`base`) | Here (`builtIn`) |
|---|---|
| `nansen.dataio.fileadapter.imagestack.ImageStack`, the core module's `ImageStack` | `ophys.binary_stack` (`.raw`), `ophys.tiff_stack` (`.tif`, `.tiff`), `ophys.video_file` (`.avi`), `ophys.hdf5_stack` (`.h5`), `ophys.tsm_stack` (`.tsm`) |
| `nansen.dataio.fileadapter.roi.RoiGroup`, the two-photon module's `RoiGroup` | `ophys.nansen_roi_array` (`.mat`), `ophys.suite2p_rois` (`.npy`) |
| `nansen.dataio.fileadapter.roi.RoiArray`, `nansen.internal.dataio.fileadapter.RoiArray` | `ophys.nansen_roi_array` (`.mat`) |
| `nansen.dataio.fileadapter.timeseries.RoiSignalArray` (and the two-photon module's), `...timeseries.TimeSeries`, `...internal.RoiGroupStruct` | `mat` (`.mat`) |
| `nansen.dataio.fileadapter.numpy`, the core module's `Numpy2Mat` | `npy` (`.npy`) |

`matlab/devcompat` has a class of each of these names, with dev's constants, whose `readData` and `writeData` read and write with the adapter of `builtIn` for the file's type, which the shim gives it (`CoreAdapter`); a name given to the `.mat` ones reads or writes that variable of the file, keeping the others, as dev's did. The subclass's own code runs on top of it unchanged: its `readData` (which may call dev's, `readData@nansen.dataio.fileadapter.imagestack.ImageStack(obj)`), `writeData` and other methods. What dev's class gave is what the adapter here gives: an image stack as an array (height x width (x channels (x planes)) x frames) where dev gave its virtual `ImageStack`, ROIs as the ophys module's ROI document, signals as the arrays in the file. A variable dev read with a subclass that has no `readData` or `writeData` of its own reads as dev's class reads it, so it gets the adapter of `builtIn` for its file type directly, and reads in both languages; the project then lists the ophys module when one of these is of the ophys module.

### The user's preferences

dev's app preferences that are settings here come back in the report's `settings` (as `settings.save` takes them); `legacy.import` saves them to the app's settings:

| dev (`nansen.App` settings) | Here |
|---|---|
| `MetadataTable.AutosaveMetadataToDataFolders` | `tables.saveToDataFolders` |
| `MetadataTable.TableFontSize` | `tables.textSize`, the dashboard's table text size: `compact` up to 9, `large` from 13, else `normal` (dev's default, 10) |
| `MetadataTable.AllowTableEdits` | `tables.locked` (its opposite): editing is off in the dashboard's tables until unlocked |
| `TaskProcessor.RunTasksWhenQueued`, `TaskProcessor.RunTasksOnStartup` | `queue.autoStart`: true when either is (the worker starts with the app and takes tasks as they are queued) |
| `Session.SessionTaskDebug` | `queue.debug` (a method run now stops in the debugger where it fails) |

and `MetadataTable.ShowIgnoredEntries`, when false, is a filter of the tables' views ([above](#how-it-maps)). `tables.textSize` and `tables.locked` are the user's defaults: a browser that has chosen its own (in Settings, or with the lock in a table's toolbar) keeps that.

### dev's metadata files

dev's adapters and image stacks keep metadata in a YAML file beside the data, `<name>.yaml` beside `<name>.<ext>` (or `<name>.yaml.txt`, with dev's `SaveYamlAsTxt`), written with dev's YAML toolbox: an adapter's `setMetadata` (groups `File`, `Data`, `Custom`), and an image stack's `StackMetadata` (as dev's Edit Stack Properties set them). They stay where they are and are read when the data is: what a recording's own files do not say of it comes from the file beside its first file (in natural order), before the entity's columns (`frame_rate`, `pixel_size_um`, `z_step_um`), in both languages (`Project.open_stack`, `openStack`, and so `data.frame`, the methods, `files.frame` and `view.frame`):

| dev (at the top, else in `Data`, else in `Custom`) | Here (the stack's metadata) |
|---|---|
| `TimeIncrement` in `TimeIncrementUnit` seconds (dev's `SampleRate`; milliseconds and microseconds too), else `SampleRate` | `frameRate`, also `data.traces`' of signals (the file beside the first variable's) |
| `PhysicalSizeX`, `PhysicalSizeY` in `PhysicalSizeXUnit`, `PhysicalSizeYUnit` (micrometer or um, nanometer or nm, millimeter or mm) | `pixelSize`, in µm |
| `PhysicalSizeZ` in `PhysicalSizeZUnit` | `zStep`, in µm |

Each is a positive number, rounded to 6 decimals as the stack adapters round theirs; dev's defaults (a unit of `pixel`, `N/A`) say nothing. A project's own adapter class (dev's `FileAdapter`, `matlab/devcompat`) gets the file as its `Metadata`, as dev's did. The YAML is read without a YAML package, by the same rules in both languages (`nansen.devyaml`, `nansen.internal.parseDevYaml`; [`conformance/yaml`](../../conformance/yaml)): block and flow mappings and sequences, plain, quoted and block scalars, as SnakeYAML writes them, and YAML 1.1's null, booleans, decimal integers and floats. A key that is not a MATLAB name, or is one of its keywords, is left out (so a mapping is the same struct in MATLAB). A file of more than 4 MB, or one that is not YAML of that kind (anchors, aliases and tags are not read), is passed over.

### Session methods

The project's own session methods (the `.m` files of `code/+<name>/+sessionmethod` and the packages in it) become methods of sessions that run dev's code unchanged in MATLAB. A dev session method is one of these:

- a function made from dev's template, `varargout = name(sessionObject, varargin)`, which calls `nansen.session.SessionMethod.setAttributes(params, ATTRIBUTES{:})` and returns its attributes when called with no inputs;
- a class that subclasses `nansen.session.SessionMethod`, with a `runMethod` (or `main`), a static `getDefaultOptions` and constant `MethodName`, `BatchMode` and `IsQueueable`. It may subclass classes of its own too, but not other classes of dev's `nansen`, which nansen-core does not have.

Other files (helpers, scripts) are left out and named in the warnings. A session method's file is copied into the new project's `matlab/` folder, in the same packages (`matlab/+RatNav/+sessionmethod/+process/countTrials.m`, so its name stays `RatNav.sessionmethod.process.countTrials`), and gets a method document, `methods/legacy.<name in snake case>.method.nansen.json`:

```json
{
  "schemaType": "nansen.method", "schemaVersion": "0.1.0",
  "id": "legacy.count_trials", "version": "1.0.0", "title": "Count Trials",
  "description": "Count the trials of a session from its running speed.",
  "category": "Process", "entityType": "session", "batchMode": "batch",
  "implementations": { "matlab": "RatNav.sessionmethod.process.countTrials" },
  "legacySessionMethod": { "kind": "function" },
  "options": { "type": "object", "properties": {
    "MinDuration": { "type": "number", "default": 2.5, "description": "seconds" },
    "Method": { "type": "string", "default": "peaks", "enum": ["peaks", "threshold"] } } }
}
```

What the document says is read from the file's text, without running it, by the same rules in both languages:

- The title is the class's `MethodName` (or a function's `'MethodName'` attribute), or else the name as words (`countTrials`: Count Trials). The description is the first line of the help text, less a first word that is the name (`%COUNTTRIALS`). The category is the packages under `+sessionmethod`, as dev's menus (`+process/+motionCorrection`: Process/Motion Correction).
- `batchMode` is `batch` when the function's `ATTRIBUTES` (or the flags given to `setAttributes`) have `'batch'`, or the class's `BatchMode` is `'batch'`. `queueable` is false with `'unqueueable'`, or `IsQueueable = false`.
- The options are the fields that the defaults set to plain values, one assignment per line: `getDefaultParameters` (or whichever local function the variable given to `setAttributes` comes from, and that variable's fields set in the function itself) of a function, `getDefaultOptions` of a class. `true`/`false` are booleans, numbers are numbers, text in `'...'` or `"..."` is a string, a row of numbers (`[1, 10]`) and a cell of text (`{'a', 'b'}`) are arrays. `params.a.b = ...` makes an object option `a`. A comment after the value is the option's description. dev's `<name>_` field listing the choices of a text option (`params.Method_ = {'peaks', 'threshold'}`) is its `enum`. A default that is not a plain value (`[]`, `getenv('HOME')`, a struct) is left out of the schema; dev's own value is used.

**How it runs.** `nansen.runMethod` sees `legacySessionMethod` and calls `nansen.legacy.runSessionMethod`. That puts `matlab/devcompat` on the path (at the end): the parts of dev that these methods call, `nansen.session.SessionMethod` (with `setAttributes`), `nansen.OptionsManager` and `utility.parsenvpairs`. It makes a `nansen.legacy.SessionShim` for each entity and calls dev's code as dev did: a function as `name(sessions, options)`, a class as `name(sessions, options)` and then `run` (its `runMethod`). A batch method gets all the sessions as one array. The options are dev's defaults (the function's `DefaultOptions` attribute, the class's `getDefaultOptions`) with the run's options over them, each in the shape of dev's default (text as char, rows of numbers as rows, cells as cells). In Python the method has only a MATLAB implementation, so `methods.run`, `tasks.submit` and pipelines run it in a MATLAB worker.

`nansen.legacy.SessionShim` is dev's `nansen.metadata.type.Session` over the entity:

| dev | Here |
|---|---|
| `sessionID`, `subjectID`, `Date`, `Time`, `Ignore`, `Description` | `session_id`, `subject_id`, `session_date` (a `datetime`), `session_time`, `ignore`, `description` of the entity |
| Other table variables (`Experiment`, ...) | Each value of the entity (key, DSM attribute, table column) as a property of its name |
| `loadData(varName)` | The project's data variable of that name (of any case, or without underscores: `RoiArray`, `roi_array`), read by its file adapter; a `.mat` file without `variableInFile` gives the variable of the name, as dev's `Default` adapter. `NANSEN:Session:VariableNotFound` when there is no file |
| `saveData(varName, data, Name, Value)` | Written by its file adapter. A variable the project has not got is made as dev's `createVariable` made it: `<session_id>_<name in snake case>.mat` (`FileType` `.json` or `.txt` for those adapters), as a variable of its name in the file, in the `DataLocation` given or the first that can be written, in its `Subfolder`, named by its `FileNameExpression` if given |
| `getDataFilePath(varName, '-r' or '-w', Name, Value)` | The variable's file, or where it is written; `-w` makes its folder and a variable the project has not got. The second output is dev's variable info |
| `getSessionFolder(dataLocation, mode)` | The entity's folder in the location of that identifier or display name (`Rawdata`: `rawdata`); `create` makes it in a location that can be written, `force` in any. Without a location: the first the entity has a folder in. `NANSEN:Session:FolderNotFound` |
| `existVariable`, `validateVariable`, `existSessionFolder`, `createSessionFolder`, `getDataLocationRootDir`, `getDataId`, `toStruct` | As dev's |

A class method's `loadData`, `saveData`, `getDataFilePath` and `getTargetFolder` are those of its session, and `Options` holds its options, as in dev. What a method opens on screen (plots, dev's apps) needs those on the path, as in dev; its options and presets are edited in the dashboard's run dialog like any other method's, and code elsewhere in the dev project's `code` folder, which methods may call, must be put on the path by hand.

**One method or folder at a time.** `methods.importLegacy` with a `.m` file or a folder (and the Data page's *Import dev method*) imports dev session methods into any project the same way (`project.importLegacyMethods(path)`, `project.import_legacy_methods(path)`). The methods run on sessions (on any entity type in a project without sessions), or on `entityType` when it is given.

## Not carried over

What is left out is named in the report's warnings, except the preferences below, which have no place here, and the writing of dev's metadata files, which is not part of the import. Each is left out because nothing here could take it, or because carrying it would mean carrying dev itself:

- **Code built on dev's processing framework.** Session methods that subclass dev's processing classes (its `ImageStackProcessor`, motion correction and segmentation bases, toolbox wrappers) need dev's virtual image stacks and its processing loop, which is most of dev; the ophys module does what dev's own such methods did, natively in both languages, and pipeline steps and tasks of them come in as its methods. File adapters on a class of dev's that is not one of its format readers (`DynamicFileAdapter`, the machinery of function-based adapters, which come in as they are) have no reader to stand on here. Code that calls the rest of dev at run time (`nansen.stack.ImageStack`, dev's apps) fails there, as it would without dev.
- **What only dev's own objects gave:** dev's adapter classes here give the adapter's value (a stack as an array, ROIs as the ophys module's document, signals as the arrays in the file), not dev's `ImageStack`, `RoiGroup` or `timetable` objects, so a subclass that calls their methods on what it read needs those calls changed. `view` and `open` of dev's adapters open dev's apps; a subclass's own run as they are. A table variable class's code (how dev's Java table drew and edited its cells) is not copied: the fragment's `choices` and `display` do that here.
- **Writing dev's metadata files:** they are read ([above](#devs-metadata-files)), but an adapter's `setMetadata` does not write one here (it is an error, naming the adapter): what a method learns of an entity goes into the entity's table, and a recording's frame rate, pixel size and plane step into its columns. Other values of such a file (dev's `File` header, other `Data` and `Custom` values) reach only a project's own adapter class, as its `Metadata`.
- **dev's options of its own methods that have no equivalent here:** presets and queued options of methods other than NoRMCorre and Quicky (their options are not dev's: the steps and tasks start from the method's defaults, or from the module's preset of dev's values), dev's options of NoRMCorre and Quicky not listed above, and options with no JSON form (function handles, objects): nothing here takes them.
- **Tasks** of methods or sessions not here, or of a method that cannot run in the background (there is nothing to run them with, or on, so no task of this queue can stand for them). A task that was running is queued again, on hold.
- **Progress** of tasks of methods not here, or without a date (a run is a time something was done), and dev's `IsManual` and `WasAborted` flags (a method's `queueable` says the first; an aborted task is not done).
- **Preferences with no equivalent:** `AutosaveMetaTable` (every edit is saved), `Session.SessionObjectWorkspaceName` (`workspace.send` takes the name each time), `OptionEditMode` (the run dialog edits the options of each run), `General.MonitorDrives`; the user session's `CurrentProjectName`, `InteractionMode` and `UserdataDirectory` (the catalog keeps the projects); the menus' visibility (`methods.setHidden` does this here). A column dev's table viewer sized automatically keeps the dashboard's width.
