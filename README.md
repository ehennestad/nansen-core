# nansen-core

A rebuild of the NANSEN core for MATLAB and Python. It is built around versioned documents and has no global state.

> **Status: 0.1.0, step 1 of the plan.** This release covers schemas, the project layout, entity tables and the conformance cases. Entities from the Dataset Structure Model, data variables, methods and tasks, and the HTML frontend come in later steps. Nothing is stable before 1.0.

## Design in one page

- **Every file has a versioned schema.** Each JSON document carries `schemaType` and `schemaVersion`, and old versions are migrated when read. Tables are CSV with a JSON sidecar that holds the column types. See [conventions](docs/conventions.md).
- **Entity tables hold what people author.** The key columns identify the entity. The other columns come from *fragments*, which are named, versioned groups of columns such as notes, QC flags or a lab's own table variables. Anything derived from the dataset's files (paths, file lists, attributes in folder names) comes from the [Dataset Structure Model](https://github.com/framover/dataset-structure-model) and is recomputed, never stored in the table. A re-scan never overwrites what people typed.
- **No singletons.** A project is opened from a folder and passed to whatever needs it. There is no "current project" in preferences, appdata or persistent variables, and CI fails on `global`, `persistent`, `getpref`/`setpref` or `setappdata(0, …)` in the core. Tests make a project in a temporary folder.
- **Two implementations, one behaviour.** MATLAB (R2023a+) and Python (3.9+) share the schemas and the [conformance cases](conformance). Both suites run every case on every change.

The full plan and the reasons behind it are in [docs/architecture.md](docs/architecture.md).

## Layout

| Path | Contents |
|---|---|
| `schema/` | JSON Schemas (draft-07) and `index.json`, which maps each `schemaType` to its file, version and status |
| `conformance/` | Cases for documents, tables and projects: input files plus expected output or error code |
| `docs/` | Conventions, architecture, and reference pages for the table format and project layout |
| `matlab/` | `+nansen` package and `matlab.unittest` tests |
| `python/` | `nansen` package (distribution `nansen-core`) and pytest tests |
| `ui/` | The HTML/JS frontend (step 5; not started) |
| `tools/` | Repository checks |

## Quick start

Python:

```bash
pip install -e ".[test]"
nansen conformance -v
pytest
```

```python
from nansen import Column, Project

project = Project.create("/tmp/pilot", "Pilot")
project.add_fragment({"schemaType": "nansen.fragment", "schemaVersion": "0.1.0", "id": "notes", "version": "1.0.0",
                      "columns": [{"name": "ignore", "dataType": "boolean", "default": False},
                                  {"name": "description", "dataType": "string"}]})
sessions = project.add_entity_type("session", key=[Column("session_id", "string")], fragments=["notes"])
sessions.add({"session_id": "m110-001", "description": "first session"})
sessions.write()
```

MATLAB:

```matlab
addpath("matlab")   % on a clean path: no other NANSEN installation
project = nansen.Project.create(tempname, "Pilot");
project.addFragment(struct("schemaType", "nansen.fragment", "schemaVersion", "0.1.0", "id", "notes", ...
    "version", "1.0.0", "columns", {{struct("name", "ignore", "dataType", "boolean", "default", false), ...
    struct("name", "description", "dataType", "string")}}));
sessions = project.addEntityType("session", nansen.Column("session_id", "string"), Fragments="notes");
sessions.addRow(struct("session_id", "m110-001", "description", "first session"));
sessions.write();

results = runNansenCoreTests();   % unit tests and every conformance case
```

## License

MIT. See [LICENSE](LICENSE).
