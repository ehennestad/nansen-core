# Entities

An entity is one subject, session, trial or other unit of a dataset. NANSEN learns about it from two sources:

- **The stores**, through the project's Dataset Structure Model config (`dataset.dsm.json`). A scan walks the data locations and yields one DSM entity record per entity: its identity, its parents, where it is in each location, the files matching each pattern, and the attributes read from its names. A scan is derived data, kept in `cache/scan.nansen.json`.
- **The table**, `tables/<entityType>.csv`, which holds what people authored about the entity: the columns of the entity type's fragments.

## Keys

A table's key is the entity's identity in the dataset: each ancestor's identity fields, outermost first, then the type's own. For a session under a subject that is `subject_id`, `session_id`.

The ancestors are the entity types that have a level above this type in some location, plus those read from this type's own names. An identity field of type `integer` gives an integer key column; every other type gives a string column, and dates appear in their ISO form.

When the project has a dataset, `addEntityType` / `add_entity_type` without explicit key columns takes them from the dataset. When an entity's table is read, its key must equal the dataset's, otherwise `key-mismatch`.

## The join

`entities(type)` returns, in order:

1. One entity per table row, in table order, with the record that has the same key if the last scan found one.
2. One entity per record without a row, in walk order.
3. Records whose key could not be completed (an ancestor's identity is missing), with the issue `incomplete-key`.

Each entity has:

- `key`
- `inStore`: a record was found.
- `inTable`: a row exists.
- `attributes`: the record's metadata.
- `locations`: the paths in each data location.
- `files`
- `issues`: the record's issue codes plus `incomplete-key`.
- `values`: the row.

A row whose record disappears is kept: the stores may be offline, or the data moved. The app shows it as not found.

## Sync

`sync(type)` adds a row, with the fragments' defaults, for every entity found in the stores but not in the table, and returns their keys. It never removes rows.

## Roots and environments

- **Environments.** Each root storage path in the DSM config may name an `environment`. The active environment comes from the `Project` (`environment=`), else from the config's preferences, which the DSM `.local.json` overlay can set per machine. Roots of other environments are ignored.
- **Relative root paths** are resolved against the folder of the DSM config, so a project can carry its data with it.
- **Unavailable roots.** A root that does not exist on this machine is reported as unavailable and skipped.
- **Changing where data is.** `project.setRoot` / `set_root` (`dataset.setRoot` in the app, "Change path" on the Data page) sets the path of a named root, or of the root a location uses in an environment. For an environment that is not active yet, it adds a root there, makes the environment active on this machine in the config's `.local.json` overlay, and gives every other location that would have no root in it one at its current path. Only those values change in the config's text.

## Writing new entities

`dataset.generate_path(location, type, values)` / `generatePath` gives the path a new entity takes in a `readwrite` location. It uses DSM's generation, which checks every generated name against its level's pattern, so the next scan finds it.
