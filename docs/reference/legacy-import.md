# Importing a NANSEN dev project

A project made with the existing NANSEN (`dev` branch) can be converted into a nansen-core project. The old project is only read, never changed.

```matlab
report = nansen.legacy.importProject("~/NANSEN/projects/RatNav", "~/nansen/RatNav");
report.warnings      % what could not be carried over
```

The import has two steps, because the dev MetaTables are MATLAB `table` objects in `.mat` files, which only MATLAB can read:

1. **Export (MATLAB).** `nansen.legacy.exportProject(folder)` reads the dev files and returns a `nansen.legacyExport` document. This is plain JSON with no MATLAB types left in it ([schema](../../schema/legacy-export.schema.json)). Pass `File=` to save it.
2. **Convert (MATLAB or Python).** `nansen.legacy.convert(export, folder)` writes the new project. In Python, `nansen import-legacy export.json folder` does the same, so the export can be made on a machine with MATLAB and converted anywhere. The cases in [`conformance/legacy`](../../conformance/legacy) hold both implementations to the same result.

## What is read

| dev file | Contents used |
|---|---|
| `project.nansen.json` | `Properties.Name`, `ShortName`, `Description` |
| `configurations/datalocation_settings.mat` | Data locations: name, type, root paths, `SubfolderStructure`, `MetaDataDef` |
| `configurations/filepath_settings.mat` | Variables: name, data location, subfolder, file name expression, file type, file adapter |
| `metadata/tables/*.mat` | MetaTables: `MetaTableEntries`, `MetaTableClass`, `MetaTableName`, `IsMaster` |

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

- Each variable becomes a data variable of sessions in its location, when its file adapter has a built-in equivalent. `Default` maps by file type (`.mat`, `.json`, `.txt`), and `MatFile`, `Json` and `Text` map to the adapter of the same name. Variables of other adapters, such as `ImageStack`, are left out. They can be added once a module provides the adapter.
- The file name follows dev's: `{session_id}_<expression><file type>`. Without an expression, the variable name is used in snake case.
- A variable without a subfolder also gets a DSM file pattern on the session level. Existing files are then found by the end of their name, as dev did.
- Internal variables are left out.

## Not carried over

- Session methods, table variable functions and custom file adapters. They are code: port them as module methods, computed fragments and adapters.
- Pipelines, the task list and per-user preferences.
- Local root path overrides. Set up the new project's per-machine roots with DSM environments.
