# Project layout

A project is a folder. Everything about it is in that folder, in files that follow the schemas, so a project can be opened by either implementation, copied, or put under version control.

```
<project>/
  project.nansen.json                       nansen.project: name, entity types and their fragments
  dataset.dsm.json                          DSM config: entity identity and data locations (step 2)
  fragments/
    <id>.fragment.nansen.json               nansen.fragment, one per project-defined fragment
  tables/
    <entityType>.table.nansen.json          nansen.table sidecar
    <entityType>.csv                        authored values
```

These are reserved for later steps and are not read yet:

```
  data-variables/<name>.dataVariable.nansen.json    step 3
  methods/<id>.method.nansen.json                   step 4
  options/<methodId>/<preset>.options.nansen.json   step 4
  tasks/<id>.task.nansen.json                       step 4
  cache/                                            derived and recomputable (DSM records); safe to delete
```

## Rules

- **No global state.** A project is opened from a folder path and returned as an object. Nothing records which project is "current": there is no preference, no singleton and no global path cache. Code that needs a project receives one.
- **Files are found by name, not by scanning.** An entity type's table is at `tables/<name>.table.nansen.json`. A fragment `a.b` is at `fragments/a.b.fragment.nansen.json`. Fragments supplied by modules will be resolved the same way, through the project's declared module list.
- **Per-machine settings stay out of the shared files.** Root paths per machine use DSM environments and DSM's `<config>.local.json` overlay.

## Creating a project

`Project.create(folder, name)` writes `project.nansen.json` with no entity types and creates `fragments/` and `tables/`. `addEntityType` (MATLAB) or `add_entity_type` (Python) records the entity type in the project file and writes an empty table. That table has the given key columns plus the columns of the entity type's fragments.

## Opening a project

`Project.open(folder)` reads and validates `project.nansen.json`. Tables are read when first asked for. Reading a table checks it against the entity type's fragments:

- Every fragment the entity type lists must exist, otherwise `unknown-fragment`.
- The table must record the same version of it, otherwise `fragment-mismatch`.
- The table's columns for that fragment must have the fragment's names and types, otherwise `fragment-mismatch`.
