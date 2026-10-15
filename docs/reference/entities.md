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

## What a scan does not match

A scan lists the folders and files it walked but could not account for (`scan.unmatched`): a name that does not match its level's pattern, a file where a folder is expected, or a name the naming rules cannot read the identity from. Each can be:

- **Left out of scans** (`dataset.exclude`): an `excludePatterns` entry for its exact name is added at its level of the DSM config.
- **Matched to an entity by hand** (`dataset.assign`, "Assign to…" in the dashboard), as dev's FolderMatcherDialog matched session folders. The entry must be at a level that holds an entity type; that type is the one it is matched to, and the key gives a value for each of its key columns. `scan.unmatched` gives each entry the entity type of its level and what the naming rules read of the key from its path, to start from.

Assignments are kept in `dataset.assignments.nansen.json` in the project (`nansen.assignments`), by data location and path relative to the location's root, so they hold for every root of the location. A scan then:

1. Walks the stores without each assigned entry and what is below it (an entry below two assigned entries belongs to the inner one).
2. Walks each assigned entry on its own, with DSM, as if the location had only the names on its path at its levels and the fields of the key had the assigned values (fixed values). So its record has the entry's location and files by the level's file patterns, its other fields are read from its names where the rules can read them, and the levels below it are walked as usual: a subject's folder brings its sessions, with that subject as their parent.
3. Adds the assigned entity and those below it to the records: to the record of the same entity (same type and key) when the walk found one, as one more location, or a second path of a location it has (flagged `duplicate-entity`); else as a new record. An entity above it (the subject of an assigned session) is added only when the walk found none, without locations.

An assignment that no longer fits the config (its level holds another entity type, or the key columns changed) is left out of scans and kept in the file. `dataset.unassign` takes an assignment out; the next scan matches the entry by its name again. `dataset.test` walks a candidate config without the assignments.

## Sync

`sync(type)` adds a row, with the fragments' defaults, for every entity found in the stores but not in the table, and returns their keys. It never removes rows.

## Roots and environments

- **Environments.** Each root storage path in the DSM config may name an `environment`. The active environment comes from the `Project` (`environment=`), else from the config's preferences, which the DSM `.local.json` overlay can set per machine. Roots of other environments are ignored.
- **Relative root paths** are resolved against the folder of the DSM config, so a project can carry its data with it.
- **Unavailable roots.** A root that does not exist on this machine is reported as unavailable and skipped.
- **Changing where data is.** `project.setRoot` / `set_root` (`dataset.setRoot` in the app, "Change path" on the Data page) sets the path of a named root, or of the root a location uses in an environment. For an environment that is not active yet, it adds a root there, makes the environment active on this machine in the config's `.local.json` overlay, and gives every other location that would have no root in it one at its current path. Only those values change in the config's text.

## Writing new entities

`dataset.generate_path(location, type, values)` / `generatePath` gives the path a new entity takes in a `readwrite` location. It uses DSM's generation, which checks every generated name against its level's pattern, so the next scan finds it.

## Removable drives

A root on a removable drive can name its volume (`volumeName` in the DSM root). When the root's folder is not there, NANSEN looks for the same path inside that volume where it is mounted now: under `/Volumes` (macOS), `/media/<user>`, `/run/media/<user>`, `/media` and `/mnt` (Linux), on the drive with that label (Windows), and under the folders listed in the `NANSEN_VOLUME_ROOTS` environment variable. The path inside the volume is what follows the drive letter, or the folder named as the volume. The config is not changed.

