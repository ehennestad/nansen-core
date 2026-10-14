# Table format

An entity table is stored as two files in the same folder:

- `<entityType>.csv`: the values.
- `<entityType>.table.nansen.json`: the sidecar. It is a `nansen.table` document (see [`schema/table.schema.json`](../../schema/table.schema.json)) giving column names, types, key, revision and fragment versions.

Readers parse the CSV using only the sidecar. Writers must produce exactly the bytes described here, so a file written by MATLAB and one written by Python are identical. [`conformance/tables`](../../conformance/tables) pins these rules.

## What the table holds

A project table holds **authored** values only: the key columns plus the columns of the entity type's fragments. Values derived from the dataset (paths, file lists and the attributes DSM extracts) are recomputed from the stores and kept elsewhere. A re-scan therefore never overwrites what people typed.

## Records

- Encoding is UTF-8 without a byte order mark.
- Each record ends with LF. A writer ends the file with LF after the last record. A reader also accepts CRLF, and a missing final LF.
- The first record is the header: the column names in sidecar order, separated by `,`. It must equal the sidecar's columns exactly, otherwise reading fails with `header-mismatch`.
- Every record has exactly as many fields as there are columns, otherwise `malformed-csv`. A blank line is a record with one empty field.

## Fields and quoting

- A field is either unquoted or enclosed in `"`. Inside quotes, `""` stands for one `"`, and `,`, LF and CR are literal.
- A `"` inside an unquoted field is `malformed-csv`. So is a closing quote that is not followed by `,`, a line end or the end of the file.
- A CR outside quotes that is not followed by LF is `malformed-csv`.
- Whitespace is never trimmed.

A writer quotes a field only when it must: when a string value contains `,`, `"`, LF or CR, or when it is the empty string.

## Missing values

An **unquoted empty** field is missing. A quoted empty field (`""`) is the empty string. This distinction applies to string columns. For every other type, an empty field, quoted or not, is missing.

- A missing **key** cell fails with `missing-key`.
- A missing **boolean** cell fails with `missing-value`: boolean columns always have a value, which is why a fragment's boolean column must declare a default.

## Values by type

| dataType | In the CSV | Reader | Writer |
|---|---|---|---|
| `string` | Any text | As written | Quoted only as above |
| `integer` | `-?(0\|[1-9][0-9]*)` | Must lie within ±2^53 (exact in a MATLAB double), otherwise `invalid-value` | Plain decimal |
| `number` | `-?(0\|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?` | Must be finite, otherwise `invalid-value` | Shortest round-trip form (below). NaN is written as missing; ±Inf cannot be written |
| `boolean` | `true` or `false` | Exactly these | Exactly these |
| `date` | `YYYY-MM-DD` | Must be a real calendar date | `YYYY-MM-DD` |
| `datetime` | `YYYY-MM-DDTHH:MM:SS` or `YYYY-MM-DDTHH:MM:SS.fff` | Naive: no time zone. Milliseconds precision | Adds `.fff` only when the milliseconds are non-zero; truncates anything below a millisecond |

### Writing numbers

The shortest round-trip form is produced the same way in both languages:

1. Find the smallest precision `p` (1 to 17) for which `sprintf('%.{p-1}e', x)` parses back to exactly `x`.
2. Take the decimal exponent `e` from that string.
3. If `-4 <= e < 17`, write `sprintf('%.{max(p-1-e, 0)}f', x)`, for example `100`, `1.5` or `0.001234`. Otherwise write the `%e` string from step 1, for example `1e+20` or `1.5e-07`.

## Keys

- `key` lists the columns that identify a row, outermost first, for example `subject_id`, `session_id`.
- Key columns must be among the columns and be of type `string` or `integer`, otherwise `invalid-table-spec`.
- Two rows with the same key fail with `duplicate-key`.

## Saving

A writer:

1. Reads the sidecar on disk, if one exists. If its `revision` differs from the revision the table was read with, it stops with `revision-conflict`.
2. Increments `revision`.
3. Writes both files to temporary names, then renames them over the targets: the CSV first, then the sidecar.

If a crash happens between the two renames, the CSV is new and the sidecar is old. The header check catches any column change on the next read.

## When reading stops

Reading stops at the first problem found, checked in this order:

1. The sidecar document: `file-not-found`, `malformed-json`, `unknown-schema-type`, `unsupported-version`, `schema-validation`.
2. Sidecar consistency: `invalid-table-spec`.
3. The CSV: `file-not-found`, `malformed-csv`, `header-mismatch`.
4. Row by row: the field count (`malformed-csv`), then the cells left to right (`invalid-value`, `missing-value`, `missing-key`), then the row's key against the rows before it (`duplicate-key`).
