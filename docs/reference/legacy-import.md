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
| `configurations/custom_options/*.mat` | Option presets a user made (`Custom`), by function: listed in the warnings only |
| `code/+<name>/+sessionmethod/**/*.m` | The project's own session methods: each file's path and text |

## How it maps

**Project.** `name` is the short name, made into an identifier. `title` is the full name, and `description` is copied over. The project lists the `core` module.

**Data locations → `dataset.dsm.json`.**

- Each location with a root path becomes a DSM filesystem location. Its identifier is the location name in lower case. `recorded` locations are `raw` and read-only, `processed` are `processed`, and `curated` are `derived`.
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
- Every other column with a table type goes to a fragment `legacy.<entityType>` in the project. Columns holding structs or objects, such as `DataLocation` and `Progress`, are left out and listed.
- Rows without a complete key are left out. A row whose key appears twice is left out after the first.
- An entity type the dataset has but dev kept no table of gets an empty table with `core.notes`. Fill it with `project.sync`.
- The notes in a `Notebook` column go into the entity type's [notebook](project-layout.md), on the entity of their row and in the order they were written. Their author, time, title and text are kept. Their type maps to `informal`, `important`, `todo` or `question`; any other type becomes `informal`, with a warning. Their tags are found again from the `#words`. Notes on rows that were left out, and notes without a time, are left out and counted in the warnings.

**Variables → data variables.**

- Each variable becomes a data variable of sessions in its location, when its file adapter has an equivalent. `Default` maps by file type (`.mat`, `.json`, `.txt`), and `MatFile`, `Json` and `Text` map to the adapter of the same name. dev's ROI files (`RoiArray`, `RoiGroup`) map to the ophys module's `ophys.nansen_roi_array`, which keeps their classifications, and `ImageStack` by file type to `ophys.tiff_stack` (`.tif`), `ophys.binary_stack` (`.raw`, `.bin`, `.dat`: dev's own binary stacks, such as its motion-corrected recordings, and SciScan's), `ophys.hdf5_stack` (`.h5`) or `npy`; the project then lists the ophys module. A variable dev kept as a named variable of a `.mat` file, through its `Default` adapter or `RoiSignalArray` (which keeps every ROI signal in one file), gets `variableInFile`: it loads that variable of the file, as dev did, and saving it keeps the file's other variables. Variables of other adapters are left out, named in the warnings.
- The file name follows dev's: `{session_id}_<expression><file type>`. Without an expression, the variable name is used in snake case.
- A variable without a subfolder also gets a DSM file pattern on the session level. Existing files are then found by the end of their name, as dev did.
- Internal variables are left out.

### Pipelines

- Each pipeline becomes a pipeline of sessions (`legacy.<name>`) with the tasks whose session method has an equivalent here: dev's NoRMCorre and Flow-Registration motion correction, Quicky, suite2p and EXTRACT segmentation, signal extraction, ΔF/F, CaImAn deconvolution, downsampling, DeepInterpolation denoising and backup. Tasks without one (plots, viewers, ROI curation apps) are left out, named in the warnings, and so is a pipeline left with no task. A Quicky or NoRMCorre task keeps its preset as the ophys module's preset of dev's values: Quicky's Soma, Soma_Virus and Axon (and Default, which is Soma's values) as `soma`, `soma_virus` and `axon`, NoRMCorre's Default (4 x 4 nonrigid) and Rigid as `nonrigid` and `rigid`. Other presets are named in the warnings, and those steps use the method's defaults.
- A task that calls one of the project's own session methods (by its full function name) becomes a step of that method as imported (see below).
- Its session properties become `assignWhen` rules: `contains` stays `contains`, `match` becomes `in`, on the column the variable was imported to. The session table gets `core.pipeline`, which keeps each session's pipeline and progress.
- A task's option preset other than `Default` is named in the warnings: dev's options are not the methods' here, so the step starts from the method's defaults. The presets users made are listed in the warnings for the same reason.

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

- Table variable functions and custom file adapters. They are code: port them as computed fragments and adapters. Session methods that need more of dev than `nansen.legacy.SessionShim` and `matlab/devcompat` give (other classes of dev's `nansen`, such as its motion correction and segmentation bases) are left out; the ophys module has their equivalents.
- Each session's pipeline progress (dev's `Progress` column), the task list and per-user preferences. Sessions start with no pipeline; a sync assigns one by its rules, or one can be assigned from the table.
- Option presets: dev's options are not the methods' here (see above).
- Local root path overrides. Set up the new project's per-machine roots with DSM environments.
