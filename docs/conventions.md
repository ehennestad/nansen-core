# Document conventions

Every file NANSEN reads or writes is described by a versioned schema in [`schema/`](../schema). This page fixes how a document says what it is, how versions change, and how readers deal with old documents.

## The envelope

Every JSON document starts with two fields:

```json
{
  "schemaType": "nansen.project",
  "schemaVersion": "0.1.0",
  ...
}
```

- `schemaType` names the kind of document. It is a dotted name starting with `nansen.`, and it selects the schema the document is validated against. [`schema/index.json`](../schema/index.json) maps each type to its schema file and current version.
- `schemaVersion` is the version of that type's schema, as a semantic version string. Each type is versioned on its own: a change to the task schema does not bump the project schema.
- An optional `$schema` field may point editors at the schema file. Readers ignore it.

CSV tables cannot carry an envelope, so each table has a JSON sidecar (`schemaType: "nansen.table"`) that carries it, together with the column types. See [Table format](reference/table-format.md).

### Why this convention

The NANSEN dev branch uses `_type`/`_version` (and `_schema_version` in `dependencies.nansen.json`). The Dataset Structure Model (DSM) uses `schemaVersion`. We settled on `schemaType` + `schemaVersion` for these reasons:

- It matches DSM, which NANSEN embeds. A project then holds one convention, not two.
- The `schema` prefix says that the version is the schema's version, not a revision of the document. On the dev branch, `_version` and `VersionedFile.VersionNumber` (a save counter) are easy to confuse. Here the save counter is a separate field, `revision`, and only tables have it.
- Plain camelCase names survive MATLAB's `jsondecode` unchanged. Leading underscores and `$` do not: `_type` becomes `x_type`.
- It needs no network and no URL parsing, so it works offline. `$schema` stays optional, for editors only.

DSM configs keep DSM's own envelope (`schemaVersion` only). A project points at its DSM config by path, so the config's type is known from where it is referenced.

## Versioning

- Versions are `MAJOR.MINOR.PATCH`.
- Before 1.0, any structural change to a schema bumps MINOR and ships with a migration from the previous minor version. A PATCH change never changes what validates; it is for descriptions and clarifications only.
- The policy after 1.0 is decided at 1.0. The likely rule: MINOR is additive and needs no migration, and MAJOR breaks and needs one.

## Reading old and new documents

A reader compares the document's `schemaVersion` with the current version of its type, using MAJOR.MINOR only:

| Document version | What the reader does |
|---|---|
| Same MAJOR.MINOR (any PATCH) | Validates and returns it |
| Older | Runs the migration chain one minor step at a time, then validates against the current schema. If a step is missing, fails with `unsupported-version` |
| Newer | Fails with `unsupported-version`; this reader is too old |

Migrations run in memory. A file on disk is only rewritten when the caller saves it, and writers always write the current version. Migrations are plain functions registered per type and step. They are injected, so tests can supply their own.

## A field enters the core when a reader consumes it

This rule is taken from DSM. A field goes into a core schema only when code in both implementations reads it. Schemas that describe parts not built yet are marked **DRAFT** in `schema/index.json`. They are validated, so they can be written by hand, but they may change in any release.

## Two implementations, one behaviour

The MATLAB and Python implementations must behave the same. [`conformance/`](../conformance) makes that checkable: each case is a set of input files plus the expected output, or the expected error code. Both test suites run every case. A change to a schema or to reading rules goes in with a conformance case.

## Error codes

Both implementations raise errors that carry one of these codes. MATLAB raises `nansen.NansenError`, with the code in its `Code` property. Python raises `nansen.NansenError`, with the code in its `code` attribute.

| Code | Meaning |
|---|---|
| `file-not-found` | A referenced file does not exist |
| `malformed-json` | The file is not valid JSON |
| `json-pointer-not-found` | An edit to JSON text names a member or element that is not there |
| `unknown-schema-type` | `schemaType` is missing or not in `schema/index.json` |
| `unsupported-version` | `schemaVersion` is not a semantic version, is newer than the reader, or has no migration path |
| `schema-validation` | The document does not validate against its schema |
| `invalid-table-spec` | A table sidecar validates, but is inconsistent (for example, a key column not among its columns) |
| `malformed-csv` | The CSV breaks the quoting or record rules, or a row has the wrong number of fields |
| `header-mismatch` | The CSV header differs from the columns in the sidecar |
| `invalid-value` | A cell cannot be parsed as its column's type |
| `missing-value` | A required cell is empty (boolean cells are always required) |
| `missing-key` | A key cell is empty |
| `duplicate-key` | Two rows share a key |
| `revision-conflict` | The table changed on disk since it was read |
| `unknown-entity-type` | The project has no entity type of that name |
| `unknown-fragment` | An entity type references a fragment that cannot be found |
| `fragment-exists` | The fragment is already defined, or already part of the entity type |
| `column-exists` | The entity type already has a column of that name |
| `fragment-mismatch` | A table's columns or fragment versions differ from the fragment definition |
| `no-dataset` | The operation needs a DSM config and the project has none |
| `dataset-invalid` | The project's DSM config is refused by the DSM reader |
| `dataset-exists` | The project already has a DSM config |
| `key-mismatch` | A table's key differs from the identity the dataset gives its entity type |
| `unknown-entity` | No entity of the type has the given key |
| `cannot-open` | The system's file browser could not be started for a folder |
| `unknown-column` | The entity type's table has no column of that name |
| `unknown-view` | The entity type has no saved view of that name |
| `unknown-note` | The entity type's notebook has no note with that id |
| `unknown-location` | The dataset has no root for the data location in the active environment |
| `read-only-column` | A key column, or a column of a computed fragment, cannot be edited |
| `generation-failed` | DSM cannot generate a path for the entity in the location (the DSM code is in the message) |
| `unknown-data-variable` | The project has no data variable of that name |
| `adapter-exists` | The project has a file adapter of that id, or a file a new adapter would be written to |
| `unknown-file-adapter` | No file adapter has that id |
| `unknown-file-pattern` | A data variable names a file pattern that its entity's level does not have |
| `adapter-unavailable` | The file adapter needs a package that is not installed (for example SciPy for `mat`) |
| `dependency-missing` | The method needs a package or toolbox that is not installed (for example suite2p for `ophys.suite2p`) |
| `unknown-addon` | No module of the project declares an add-on of that id |
| `install-failed` | An add-on or a shared project could not be installed or removed (the message says why, or how to install it) |
| `unsupported-file` | The file is not in a format the operation reads (`files.inspect` reads HDF5: NWB, MATLAB v7.3 and .h5 files) |
| `invalid-data` | A data file is not in the format its file adapter reads |
| `data-not-found` | The entity has no file for the data variable |
| `no-file-name` | The data variable has no `fileName`, so it cannot be written |
| `file-name-mismatch` | A generated file name would not match the variable's file pattern, so it would not be found again |
| `unknown-module` | A module listed by the project cannot be found |
| `fragment-read-only` | The fragment comes from a module; only the project's own fragments can be changed |
| `module-mismatch` | The folder of a listed module holds a different module |
| `module-in-use` | A module cannot be removed while the project uses its fragments, file adapters or methods |
| `unknown-method` | No method has that id |
| `method-exists` | The project has a method of that id, or a file a new method would be written to |
| `method-unavailable` | The method has no implementation in this language |
| `wrong-entity-type` | The method runs on another entity type |
| `invalid-options` | Options or a preset do not fit the method's options schema |
| `unknown-preset` | The method has no preset of that name |
| `not-computed` | The fragment has no compute method |
| `no-entities` | A task or run was given no entities |
| `not-queueable` | The method cannot run as a background task |
| `unknown-task` | No task has that id |
| `task-active` | The task is queued or running, so it cannot be retried or removed |
| `task-not-queued` | The task is no longer queued (or a worker is starting it), so it cannot be held, changed or reordered |
| `unknown-pipeline` | No pipeline has that id |
| `no-catalog` | The app was started without a project catalog |
| `no-workspace` | The app was not opened from a workspace that entities can be sent to |
| `unknown-project` | The project is not in the catalog |
| `folder-not-empty` | A new project, demo, import or installed project needs an empty folder |
| `not-a-project` | A repository installed as a project holds no `project.nansen.json` |
