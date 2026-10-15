# nansen-core

A rebuild of the NANSEN core for MATLAB and Python. It is built around versioned documents, has no global state, and has one HTML dashboard for both languages.

> **Status: 0.1.0, every step of the [plan](docs/architecture.md) is in.** MATLAB (R2023a+) and Python (3.9+) pass the same conformance cases on every change. Nothing is stable before 1.0: schemas may still change, with migrations.

## What it does

- **Projects are folders of documents.** Every JSON file carries `schemaType` and `schemaVersion` and has a schema in [`schema/`](schema). Entity tables are CSV with a typed JSON sidecar. A project can be opened from either language, put under version control, or diffed. See [conventions](docs/conventions.md) and [project layout](docs/reference/project-layout.md).
- **Entities come from the data.** The [Dataset Structure Model](https://github.com/framover/dataset-structure-model) (DSM) describes where the data is: data locations, folder levels, roots per machine and the rules that read ids and dates from names. A scan finds every subject and session, with their folders and files, in every location. It is joined with the entity tables, which hold only what people author, so a re-scan never overwrites what was typed. See [entities](docs/reference/entities.md).
- **Entity types are composed, not subclassed.** Columns come from *fragments*: versioned column groups such as notes, QC flags or file statistics. A fragment can be computed by a method, which replaces table variables. Data variables name a file, found through DSM, and the file adapter that reads it; what is loaded stays in the project's data cache until the file changes.
- **Methods, presets, pipelines and a task queue.** Methods declare their options as JSON Schema and can be implemented in MATLAB, in Python, or in both; a project starts its own from templates, and project tools run once on the whole project. Pipelines are assigned to entities and track each one's progress. Tasks are files holding entity keys, so either language's worker can run them, in the background or in other processes; queued tasks can be held, reordered and changed. See [modules](docs/reference/modules.md).
- **Two-photon processing.** The `ophys` module brings over dev's two-photon workflow natively in both languages, with the same results: motion correction, ROI detection, signal extraction, ΔF/F and downsampling, SciScan and TIFF readers, and suite2p, NoRMCorre and imviewer where they are installed. See [the ophys module](docs/reference/modules.md#the-ophys-module).
- **A dashboard.** One dependency-free HTML/JS app. MATLAB shows it in a `uihtml` (`nansen.App`), and Python serves it on localhost (`nansen app`). It covers the project overview, entity tables (virtual scrolling, search, sort, column filters, saved views, columns that can be moved, sized, edited and computed, inline editing with a lock, a detail drawer with each entity's files), method forms drawn from their options schemas, pipelines (with rules and steps run by hand), the live task queue and logs, notes on entities (typed, dated, with #tags), a wizard that describes the data folders, configuring data locations, data variables and modules, starting methods, tools and file adapters from templates, reviewing what a scan did not match, a project catalog, settings, keyboard shortcuts, and light and dark themes. Both backends answer the same [protocol](docs/reference/protocol.md).
- **No singletons.** A project is opened from a folder and passed to whatever needs it. CI fails on `global`, `persistent`, `getpref`/`setpref` or `setappdata(0, …)` in the core, so every test builds its project in a temporary folder.
- **Import from NANSEN.** Existing projects from the `dev` branch, with their tables and notebooks, convert in one call. See [legacy import](docs/reference/legacy-import.md).

## Quick start

### MATLAB

```matlab
addpath("matlab")                        % on a clean path: no other NANSEN installation
addpath("path/to/dataset-structure-model/src/matlab")   % the DSM reader

project = nansen.demo.create(fullfile(tempdir, "nansen-demo"));
app = nansen.App(Project=project.Folder);

sessions = project.entities("session");
project.run("core.file_stats", sessions(1:3));

results = runNansenCoreTests();          % unit tests and every conformance case
```

### Python

```bash
pip install -e ".[test]"
nansen demo /tmp/nansen-demo
nansen app /tmp/nansen-demo              # opens the dashboard in the browser
pytest && nansen conformance
```

```python
from nansen import Project

project = Project.open("/tmp/nansen-demo")
sessions = project.entities("session")
project.run("core.file_stats", sessions[:3])
table = project.table("session")
table.update(sessions[0].key, description="Good imaging")
table.write()

from nansen.server import open_app
server = open_app(project, namespace=globals())   # the dashboard, from a notebook; "To workspace" puts the selection in `entities`
```

### An existing NANSEN project

```matlab
report = nansen.legacy.importProject("~/NANSEN/projects/MyProject", "~/nansen/MyProject");
report.warnings
```

## Layout

| Path | Contents |
|---|---|
| `schema/` | JSON Schemas (draft-07) and `index.json`, which maps each `schemaType` to its file, version and status |
| `conformance/` | Cases both implementations must pass: documents, tables, projects, entities, data, legacy import and the app protocol |
| `docs/` | Conventions, architecture, and reference pages |
| `matlab/` | The `+nansen` package, `matlab.unittest` tests and `runNansenCoreTests` |
| `python/` | The `nansen` package (distribution `nansen-core`), pytest tests and the `nansen` command |
| `ui/` | The dashboard: classic scripts and CSS, no build step |
| `modules/` | Modules that ship with NANSEN: `core` (notes, file statistics, utility methods, the demo) and `ophys` (two-photon motion correction, ROI detection, signals and ΔF/F, SciScan and TIFF readers) |
| `tools/` | Repository checks |

## License

MIT. See [LICENSE](LICENSE).
