# Changelog

## 0.1.0 (unreleased)

Step 1 of the plan in [docs/architecture.md](docs/architecture.md): versioned documents, the project layout and entity tables.

- Added the document envelope: `schemaType` + `schemaVersion` on every JSON document, per-type semantic versions, and in-memory migrations ([conventions](docs/conventions.md)).
- Added core schemas `nansen.project`, `nansen.fragment` and `nansen.table`, and DRAFT schemas `nansen.dataVariable`, `nansen.method`, `nansen.options` and `nansen.task`.
- Added the table format: CSV plus a JSON sidecar, with typed columns, distinct missing values and empty strings, canonical number and datetime forms, a key, and a revision counter for optimistic concurrency ([table format](docs/reference/table-format.md)).
- Added the project layout ([project layout](docs/reference/project-layout.md)): a project is opened from a folder, with no global state.
- Added conformance cases for documents, tables and projects.
- Added the MATLAB package `+nansen` (R2023a+) and the Python package `nansen` (3.9+), both passing every case.
- Added a CI check that the core uses no `global`, `persistent`, preferences or root appdata.
