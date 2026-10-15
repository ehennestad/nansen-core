# Conformance cases

These cases pin down how NANSEN documents are read and written. Both implementations must pass every case: the MATLAB suite (`matlab/tests`) and the Python suite (`python/tests`), and `nansen conformance` as well.

There are eight kinds of case. Each case is a folder with an `expected.json` that has a `description` and either the expected result or `"error": "<code>"` (see [error codes](../docs/conventions.md#error-codes)).

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

## `entities/<case>/`

`project/` is a project with a DSM config, and `listing.json` is a DSM directory listing used instead of the file system. The implementation scans the listing, joins the records with the tables and then syncs.

- `expected.json` gives, per entity type, each entity's key, whether it is in the stores (`inStore`) and in the table (`inTable`), its DSM attributes and locations, and its table values; then the keys that `sync` adds.

## `data/<case>/`

Like `entities`, plus `requests.json`: a list of `{entityType, key, variable}`.

- `expected.json` gives, per request, the files the variable would be read from (`read`) and the location and relative path it would be written to (`write`), or an error code for either.

## `legacy/<case>/`

`export.json` is a `nansen.legacyExport` document, as MATLAB's `nansen.legacy.exportProject` writes it. The implementation converts it into a new project in an empty folder ([legacy import](../docs/reference/legacy-import.md)).

- `expected.json` gives the written `project.nansen.json` and `dataset.dsm.json`, the fragments and data variables (sorted by file name), each table's `key`, columns and `rows`, and the report's `warnings` in order.

## `jsontext/<case>/`

`input.json` is JSON text, and `edits.json` lists `edits`: `{op: "replace" | "append" | "setMember", pointer, key?, value}`, applied in order with the JSON text editor (`nansen.jsontext`, `nansen.internal.JsonText`). Pointers are JSON Pointers (RFC 6901).

- `expected.json` gives the resulting text as `output`, byte for byte, or an error code. Values in `edits.json` must not hold one-element arrays, which MATLAB's `jsondecode` cannot tell from scalars.

## `api/<case>/`

`session.json` is a list of `steps`, each a protocol `request` and what to `expect`: a `result` or an `error` code. Each case starts a fresh API. `${project}` in a request is replaced by the path of a scratch copy of `project/` (if the case has one), and `${listing}` by the contents of `listing.json`. A step can `keep` values from its result for the steps after it: `"keep": {"first": "/id"}` keeps the result's `id` (a JSON pointer into the result), and a string `"${first}"` in a later request or expected result stands for it.

- A result is compared as a subset: every key in the expected object must be present with the expected value, and arrays must have the same length. Other keys are ignored, so the cases pin down what clients rely on without freezing everything else.

## Adding a case

Write the expected output by hand. Don't generate it with one of the readers, or the case will just record that reader's behaviour. Where the expected values are numbers no one would work out by hand, compute them from the ground truth the data was made from, as `api/ophys/make_data.py` does for the synthetic recording, never with the code under test. A new rule for the format goes in with a case here and a change to [`docs/reference`](../docs/reference).
