# Conformance cases

These cases pin down how NANSEN documents are read and written. Both implementations must pass every case: the MATLAB suite (`matlab/tests`) and the Python suite (`python/tests`), and `nansen conformance` as well.

There are three kinds of case. Each case is a folder with an `expected.json` that has a `description` and either the expected result or `"error": "<code>"` (see [error codes](../docs/conventions.md#error-codes)).

## `documents/<case>/`

`document.json` is read as a generic document: envelope check, migration and schema validation.

- On success, `expected.json` gives `"valid": true` and the `schemaType`.
- On failure, it gives the error code.

## `tables/<case>/`

`session.table.nansen.json` is a table sidecar, and the CSV it names sits next to it.

- On success, `expected.json` gives `rows`, the table as JSON. Missing values are `null`. Dates and datetimes are given in their CSV form.
- `"canonical": true` means the CSV is exactly what a writer produces. Implementations must then also write the rows back, with the same sidecar, and produce the CSV byte for byte.

## `projects/<case>/`

`project/` is a project folder. The implementation opens it and reads every entity type's table.

- On success, `expected.json` gives the project `name` and `title`, the `entityTypes` in order, and for each table its `key`, column names, `revision` and `rows`.
- On failure, it gives the first error code.

## Adding a case

Write the expected output by hand. Don't generate it with one of the readers, or the case will just record that reader's behaviour. A new rule for the format goes in with a case here and a change to [`docs/reference`](../docs/reference).
