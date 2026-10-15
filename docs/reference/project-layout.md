# Project layout

A project is a folder. Everything about it is in that folder, in files that follow the schemas, so a project can be opened by either implementation, copied, or put under version control.

```
<project>/
  project.nansen.json                        nansen.project: name, title, description, dataset, modules, entity types and their fragments
  dataset.dsm.json                           DSM config: entity identity and data locations
  dataset.dsm.local.json                     optional, per machine: the active environment (DSM overlay)
  fragments/<id>.fragment.nansen.json        nansen.fragment, project-defined fragments
  tables/<entityType>.table.nansen.json      nansen.table sidecar
  tables/<entityType>.csv                    authored values
  data-variables/<name>.dataVariable.nansen.json   nansen.dataVariable
  methods/<name>.method.nansen.json          nansen.method, project-defined methods
  python/, matlab/                           the code of project-defined methods and adapters
  pipelines/<name>.pipeline.nansen.json      nansen.pipeline, project-defined pipelines
  modules/<id>/                              optional: modules kept inside the project
  options/<methodId>/<name>.options.nansen.json    nansen.options: method presets
  notes/<entityType>.notebook.nansen.json    nansen.notebook: notes on the entity type's entities
  views/<entityType>.views.nansen.json      nansen.views: saved views of the table (rows by key or filter, columns shown)
  runs/<entityType>.runs.jsonl               nansen.run lines: each method run that completed on an entity (only appended to)
  tasks/<id>.task.nansen.json                nansen.task, plus <id>.claim/, <id>.cancel and <id>.log while it runs
  cache/scan.nansen.json                     nansen.scan: the last walk of the stores; derived, safe to delete
  exports/                                   files written by export methods
```

Everything except `cache/`, `tasks/` and `exports/` is authored and belongs under version control. The [modules](modules.md) page covers methods, presets, pipelines and tasks.

## Rules

- **No global state.** A project is opened from a folder path and returned as an object. Nothing records which project is "current": there is no preference, no singleton and no global path cache. Code that needs a project receives one.
- **Files are found by name, not by scanning.** An entity type's table is at `tables/<name>.table.nansen.json`. A fragment `a.b` is at `fragments/a.b.fragment.nansen.json`, else in one of the project's modules, which are found through the declared module list.
- **Per-machine settings stay out of the shared files.** Root paths per machine use DSM environments and DSM's `<config>.local.json` overlay.

## Creating a project

`Project.create(folder, name)` writes `project.nansen.json` with no entity types and creates `fragments/` and `tables/`. `addEntityType` (MATLAB) or `add_entity_type` (Python) records the entity type in the project file and writes an empty table. That table has the given key columns plus the columns of the entity type's fragments.

## Opening a project

`Project.open(folder)` reads and validates `project.nansen.json`. Tables are read when first asked for. Reading a table checks it against the entity type's fragments:

- Every fragment the entity type lists must exist, otherwise `unknown-fragment`.
- The table must record the same version of it, otherwise `fragment-mismatch`.
- The table's columns for that fragment must have the fragment's names and types, otherwise `fragment-mismatch`.
