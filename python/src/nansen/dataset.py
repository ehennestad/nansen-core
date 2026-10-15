"""A project's dataset: its Dataset Structure Model config, and walking the stores it describes."""

from __future__ import annotations

import copy
import datetime as dt
import json
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

import dsm

from .documents import PathLike, check_document, read_document, write_json
from .errors import NansenError
from .schemas import current_version


@dataclass
class RootInfo:
    data_location: str
    root_storage_path: str
    path: Path
    environment: Optional[str]
    priority: float
    available: bool


def volume_mounts(name: str) -> List[Path]:
    """Where a volume of this name is mounted now: /Volumes on macOS; /media, /run/media and /mnt on Linux;
    a drive with this label on Windows; and the folders listed in NANSEN_VOLUME_ROOTS (os.pathsep-separated)."""
    import getpass
    import sys

    parents = [Path(p) for p in os.environ.get("NANSEN_VOLUME_ROOTS", "").split(os.pathsep) if p]
    found: List[Path] = []
    if sys.platform == "win32":
        found += _windows_drives_labelled(name)
    elif sys.platform == "darwin":
        parents.append(Path("/Volumes"))
    else:
        try:
            user = getpass.getuser()
        except Exception:  # no user name to be had
            user = ""
        parents += [Path("/media") / user, Path("/run/media") / user, Path("/media"), Path("/mnt")]
    found += [parent / name for parent in parents if (parent / name).is_dir()]
    return list(dict.fromkeys(found))


def _windows_drives_labelled(name: str) -> List[Path]:
    import ctypes
    import string

    drives = []
    for letter in string.ascii_uppercase:
        root = f"{letter}:\\"
        if not os.path.isdir(root):
            continue
        label = ctypes.create_unicode_buffer(261)
        if ctypes.windll.kernel32.GetVolumeInformationW(root, label, 261, None, None, None, None, 0) and label.value == name:  # type: ignore[attr-defined]
            drives.append(Path(root))
    return drives


def path_in_volume(path: str, name: str) -> Optional[str]:
    """The part of a root path inside its volume ("" for the volume itself), or None when that cannot be told:
    after a drive letter, or after a folder named as the volume (/Volumes/<name>, /media/<user>/<name>...)."""
    text = re.sub("/+", "/", path.replace("\\", "/"))
    drive = re.match(r"^[A-Za-z]:/?", text)
    if drive:
        return text[drive.end():].strip("/")
    parts = [p for p in text.split("/") if p]
    if name in parts:
        return "/".join(parts[parts.index(name) + 1:])
    return None


@dataclass
class Scan:
    """What one walk of the stores found: entity records in the DSM JSON form, and the roots read."""

    records: List[dict]
    unmatched: List[dict] = field(default_factory=list)
    roots: List[dict] = field(default_factory=list)
    environment: Optional[str] = None
    scanned_at: str = ""

    def to_document(self) -> dict:
        return {
            "schemaType": "nansen.scan",
            "schemaVersion": current_version("nansen.scan"),
            "scannedAt": self.scanned_at,
            "environment": self.environment,
            "roots": self.roots,
            "records": self.records,
            "unmatched": self.unmatched,
        }

    @classmethod
    def from_document(cls, doc: dict) -> "Scan":
        return cls(doc["records"], doc["unmatched"], doc["roots"], doc.get("environment"), doc["scannedAt"])

    @classmethod
    def read(cls, path: PathLike) -> "Scan":
        return cls.from_document(read_document(path, "nansen.scan"))

    def write(self, path: PathLike) -> None:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        write_json(path, check_document(self.to_document(), "nansen.scan"))

    def records_of(self, entity_type: str) -> List[dict]:
        return [r for r in self.records if r["entityType"] == entity_type]


class Dataset:
    """The DSM config of a project, with root paths resolved and an active environment."""

    def __init__(self, config: dsm.Config, folder: PathLike, environment: Optional[str] = None):
        self.config = config
        self.folder = Path(folder)
        self.environment = environment or config.preferences.get("environmentIdentifier")

    @classmethod
    def load(cls, path: PathLike, environment: Optional[str] = None) -> "Dataset":
        path = Path(path)
        if not path.is_file():
            raise NansenError("file-not-found", f"File not found: {path}")
        try:
            config = dsm.load_config(path)
        except dsm.ConfigError as error:
            raise NansenError("dataset-invalid", f"{path}: {error}") from None
        return cls(config, path.parent, environment)

    # -- entity types and keys ------------------------------------------------------------

    @property
    def entity_types(self) -> List[str]:
        return self.config.entity_types

    def identity_keys(self, entity_type: str) -> List[str]:
        return self.config.identity_keys(entity_type)

    def ancestor_types(self, entity_type: str) -> List[str]:
        """Entity types whose identity is part of this type's key: levels above it, or ancestors read from its names."""
        found = set()
        for location in self.config.location_ids:
            index = self.config.entity_level_index(location, entity_type)
            if index is None:
                continue
            levels = [lvl.get("entityType") for lvl in self.config.layout(location)[:index] if lvl.get("entityType")]
            found.update(levels)
            for candidate in self.config.types_before(entity_type):
                if candidate not in levels and self.config.rules_for(location, candidate):
                    found.add(candidate)
        return sorted(found, key=self.config.type_order)

    def key_columns(self, entity_type: str) -> List[Tuple[str, str]]:
        """(name, dataType) of each key column: ancestors' identity fields, outermost first, then the type's own."""
        names = [k for t in self.ancestor_types(entity_type) for k in self.identity_keys(t)]
        names += self.identity_keys(entity_type)
        return [(n, "integer" if self.config.definitions[n]["dataType"] == "integer" else "string") for n in names]

    def record_key(self, record: Mapping[str, Any]) -> Dict[str, Any]:
        key: Dict[str, Any] = {}
        for parent in record["parents"]:
            key.update(parent["identity"])
        key.update(record["identity"])
        return key

    # -- roots ------------------------------------------------------------------------------

    def roots(self) -> List[RootInfo]:
        """Every root storage path in the active environment (or with no environment), resolved on this machine."""
        roots = []
        for location in self.config.location_ids:
            for entry in self.config.filesystem(location)["rootStoragePaths"]:
                environment = entry.get("environment")
                if self.environment and environment and environment != self.environment:
                    continue
                path = Path(entry["path"])
                if not path.is_absolute():  # relative to the config's folder, "." and ".." resolved
                    path = Path(os.path.normpath(self.folder / path))
                if not path.is_dir() and entry.get("volumeName"):
                    path = self._found_on_volume(entry["path"], entry["volumeName"]) or path
                roots.append(RootInfo(location, entry["identifier"], path, environment,
                                      entry.get("priority", 0), path.is_dir()))
        return roots

    @staticmethod
    def _found_on_volume(path: str, volume: str) -> Optional[Path]:
        """The root on its volume mounted somewhere else now (a removable drive under another letter), if it is."""
        inside = path_in_volume(path, volume)
        if inside is None:
            return None
        for mount in volume_mounts(volume):
            candidate = mount / inside if inside else mount
            if candidate.is_dir():
                return candidate
        return None

    def root(self, data_location: str, root_storage_path: Optional[str] = None) -> RootInfo:
        """A root of the location: the named one, or the available one with the lowest priority number."""
        candidates = [r for r in self.roots() if r.data_location == data_location]
        if root_storage_path is not None:
            candidates = [r for r in candidates if r.root_storage_path == root_storage_path]
        candidates.sort(key=lambda r: (not r.available, r.priority))
        if not candidates:
            raise NansenError("unknown-location", f"no root for data location {data_location!r} in this environment")
        return candidates[0]

    def listing(self) -> Tuple[dsm.Listing, List[dict]]:
        """Snapshot every available root. Returns the listing and a summary of each root."""
        roots, summary = [], []
        for info in self.roots():
            item = {"dataLocation": info.data_location, "rootStoragePath": info.root_storage_path,
                    "path": str(info.path), "available": info.available}
            if info.available:
                root = dsm.root_from_directory(info.data_location, info.root_storage_path, info.path)
                roots.append(root)
                item["entries"] = len(root.entries)
            summary.append(item)
        return dsm.Listing(roots, self.environment), summary

    def scan(self, listing: Optional[dsm.Listing] = None, registry: Optional[dsm.ExtractorRegistry] = None,
             now: Optional[dt.datetime] = None, assignments: Sequence[Mapping[str, Any]] = ()) -> Scan:
        """Walk the stores. Pass a listing to walk a snapshot instead of the file system.

        ``assignments`` are entries matched to an entity by hand (``nansen.assignments``): each is that entity,
        whatever its name, and what lies below it is walked as usual. Those that no longer fit the config
        (another level, another key) are left out.
        """
        if listing is None:
            listing, summary = self.listing()
        else:
            summary = [{"dataLocation": r.data_location, "rootStoragePath": r.root_storage_path,
                        "available": True, "entries": len(r.entries)} for r in listing.roots]
        plans = self._assignment_plans(assignments)
        derived: List[Tuple[dict, dsm.Root]] = []
        if plans:
            listing, derived = self._split_listing(listing, plans)
        result = dsm.walk(self.config, listing, registry)
        stamp = (now or dt.datetime.now()).replace(microsecond=0).isoformat()
        document = result.to_dict(include_detail=True)
        records, unmatched = document["records"], document["unmatched"]
        key_columns: Dict[str, List[str]] = {}
        for plan, root in derived:
            walked = dsm.walk(self._assignment_config(plan), dsm.Listing([root], listing.environment), registry)
            part = walked.to_dict(include_detail=True)
            for record in part["records"]:
                below = record["entityType"] == plan["entityType"] or \
                    any(p["entityType"] == plan["entityType"] for p in record["parents"])
                if below:  # the assigned entity, and what is below it
                    self._merge_record(records, record, key_columns)
                else:  # an entity above it: its folders are the walk of the rest's, so it adds only an entity not found
                    self._merge_record(records, dict(record, locations=[]), key_columns, only_new=True)
            unmatched.extend(part["unmatched"])
        return Scan(records, unmatched, summary, listing.environment or self.environment, stamp)

    # -- entries matched by hand -------------------------------------------------------------

    def assignment_target(self, data_location: str, path: str) -> Tuple[str, int, str]:
        """(path as a scan lists it, level index, entity type) of an entry that can be matched to an entity:
        one at a level of the location that holds an entity type."""
        parts = entry_parts(path)
        if data_location not in self.config.location_ids:
            raise NansenError("unknown-location", f"the dataset has no data location {data_location!r}")
        levels = self.config.layout(data_location)
        if len(parts) > len(levels):
            raise NansenError("invalid-params", f"{path!r} is deeper than the levels of {data_location!r}")
        level = levels[len(parts) - 1]
        if not level.get("entityType"):
            raise NansenError("invalid-params", f"level {level['name']!r} of {data_location!r} holds no entity type")
        folder = level.get("fileSystemType", "folder") == "folder"
        return "/".join(parts) + ("/" if folder else ""), len(parts) - 1, level["entityType"]

    def check_key(self, entity_type: str, key: Any) -> Dict[str, Any]:
        """The key of an entity of the type, its values typed by the key columns (invalid-params otherwise)."""
        columns = self.key_columns(entity_type)
        names = [n for n, _ in columns]
        if not isinstance(key, dict) or sorted(key) != sorted(names):
            raise NansenError("invalid-params", f"the key of {entity_type} has the columns {', '.join(names)}")
        typed: Dict[str, Any] = {}
        for name, data_type in columns:
            value = key[name]
            if data_type == "integer":
                if isinstance(value, str) and re.fullmatch(r"\s*-?\d+\s*", value):
                    value = int(value)
                elif isinstance(value, float) and value.is_integer():
                    value = int(value)
                if not isinstance(value, int) or isinstance(value, bool):
                    raise NansenError("invalid-params", f"{name} is an integer, not {key[name]!r}")
            else:
                if not isinstance(value, str) or not value.strip():
                    raise NansenError("invalid-params", f"{name} is a text that is not empty, not {key[name]!r}")
                value = value.strip()
            typed[name] = value
        return typed

    def suggested_key(self, data_location: str, root_storage_path: str,
                      path: str) -> Tuple[Optional[str], Optional[Dict[str, Any]]]:
        """For an entry a scan did not match: the entity type of its level and what the naming rules read of
        its key from its path (None for a value they cannot read). (None, None) if it cannot be matched."""
        from dsm.extract import evaluate_fields

        try:
            relative, _, entity_type = self.assignment_target(data_location, path)
        except NansenError:
            return None, None
        if relative.endswith("/") != str(path).endswith("/"):  # a file where a folder is expected, or the reverse
            return None, None
        try:
            root = str(self.config.root_storage_path(data_location, root_storage_path)["path"])
        except KeyError:
            root = ""
        full_path = re.sub(r"[/\\]+$", "", root) + "/" + relative.rstrip("/")
        registry = dsm.ExtractorRegistry()
        key: Dict[str, Any] = {}
        seed: Dict[str, Any] = {}
        for owner in self.ancestor_types(entity_type) + [entity_type]:
            values: Dict[str, Any] = {}
            if self.config.rules_for(data_location, owner):
                try:
                    values, _ = evaluate_fields(self.config, data_location, relative, owner, dict(seed), registry, full_path)
                except Exception:  # a rule that cannot be read on this path reads nothing
                    values = {}
            for name in self.identity_keys(owner):
                key[name] = values.get(name)
                if key[name] is not None:
                    seed[name] = key[name]
        return entity_type, key

    def _assignment_plans(self, assignments: Sequence[Mapping[str, Any]]) -> List[dict]:
        """The assignments that still fit the config, with their path, level and typed key."""
        plans = []
        for assignment in assignments:
            try:
                path, level, entity_type = self.assignment_target(assignment["dataLocation"], assignment["path"])
                if entity_type != assignment["entityType"]:
                    continue
                key = self.check_key(entity_type, assignment["key"])
            except NansenError:
                continue
            plans.append({"dataLocation": assignment["dataLocation"], "path": path, "level": level,
                          "entityType": entity_type, "key": key})
        return plans

    def _split_listing(self, listing: dsm.Listing,
                       plans: List[dict]) -> Tuple[dsm.Listing, List[Tuple[dict, dsm.Root]]]:
        """The listing without the assigned entries and what lies below them; and for each assignment found
        in a root, a root of its entries (with the folders they are in). An entry belongs to the innermost
        assignment that holds it."""
        roots: List[dsm.Root] = []
        derived: List[Tuple[dict, dsm.Root]] = []
        for root in listing.roots:
            mine = [p for p in plans if p["dataLocation"] == root.data_location]
            owned: List[List[str]] = [[] for _ in mine]
            rest: List[str] = []
            for entry in root.entries:
                best = -1
                for i, plan in enumerate(mine):
                    if within(entry, plan["path"]) and (best < 0 or len(plan["path"]) > len(mine[best]["path"])):
                        best = i
                if best < 0:
                    rest.append(entry)
                else:
                    owned[best].append(entry)
            roots.append(dsm.Root(root.data_location, root.root_storage_path, rest))
            for plan, entries in zip(mine, owned):
                if entries:
                    derived.append((plan, dsm.Root(root.data_location, root.root_storage_path,
                                                   dsm.listing.normalize_entries(entries))))
        return dsm.Listing(roots, listing.environment), derived

    def _assignment_config(self, plan: dict) -> dsm.Config:
        """The config with only the assignment's location, in which the names on its path are taken as they
        are and the fields of its key have the assigned values."""
        document = copy.deepcopy(self.config.doc)
        location = copy.deepcopy(self.config.location(plan["dataLocation"]))
        source = location["filesystemSource"]
        names = plan["path"].rstrip("/").split("/")
        layout = list(source["entityLayout"])
        for i in range(plan["level"] + 1):
            level = {k: v for k, v in layout[i].items()
                     if k not in ("excludePatterns", "matchPattern", "isVariable", "fixedName")}
            level["isVariable"] = False
            level["fixedName"] = names[i]
            layout[i] = level
        source["entityLayout"] = layout
        mapping = [item for item in source.get("metadataMapping", []) if item["metadataRef"] not in plan["key"]]
        mapping += [{"metadataRef": name, "extraction": {"method": "fixed", "value": value}}
                    for name, value in plan["key"].items()]
        source["metadataMapping"] = mapping
        document["dataLocations"] = [location]
        return dsm.Config(document, self.config.source)

    def _merge_record(self, records: List[dict], record: dict, key_columns: Dict[str, List[str]],
                      only_new: bool = False) -> None:
        """Add a record found under an assigned entry to the record of the same entity, or as a new record."""
        entity_type = record["entityType"]
        if entity_type not in key_columns:
            key_columns[entity_type] = [n for n, _ in self.key_columns(entity_type)]
        names = key_columns[entity_type]
        wanted = [self.record_key(record).get(n) for n in names]
        existing = next((r for r in records if r["entityType"] == entity_type
                         and [self.record_key(r).get(n) for n in names] == wanted), None)
        if existing is None:
            records.append(record)
            return
        if only_new:
            return
        issues = list(existing.get("issues", []))
        for entry in record["locations"]:
            same = next((e for e in existing["locations"]
                         if e["dataLocationIdentifier"] == entry["dataLocationIdentifier"]
                         and e["rootStoragePathIdentifier"] == entry["rootStoragePathIdentifier"]), None)
            if same is None:
                existing["locations"].append(entry)
                continue
            same["paths"] = sorted(set(same["paths"]) | set(entry["paths"]))
            if "files" in entry:
                files = same.setdefault("files", {})
                for name, paths in entry["files"].items():
                    files[name] = sorted(set(files.get(name, [])) | set(paths))
            if "isComplete" in entry:
                same["isComplete"] = bool(same.get("isComplete", True)) and bool(entry["isComplete"])
            if same["fileSystemType"] == "folder" and len(same["paths"]) > 1:
                issues.append({"code": "duplicate-entity", "message": f"{len(same['paths'])} folders in "
                               f"'{same['dataLocationIdentifier']}' are this entity: {', '.join(same['paths'])}"})
        order = self.config.location_ids
        existing["locations"].sort(key=lambda e: (order.index(e["dataLocationIdentifier"]), e["rootStoragePathIdentifier"]))
        for name, value in record["metadata"].items():
            existing["metadata"].setdefault(name, value)
        for issue in record.get("issues", []):
            if issue["code"] in ("missing-required-file", "cardinality-violation") and issue not in issues:
                issues.append(issue)
        if issues:
            existing["issues"] = issues

    # -- writing --------------------------------------------------------------------------

    def generate_path(self, data_location: str, entity_type: str, values: Mapping[str, Any]) -> str:
        try:
            return dsm.generate_path(self.config, data_location, entity_type, values)
        except dsm.GenerationError as error:
            raise NansenError("generation-failed", f"[{error.code}] {error.message}") from None

    def absolute(self, data_location: str, relative: str, root_storage_path: Optional[str] = None) -> Path:
        return self.root(data_location, root_storage_path).path / relative


def entry_parts(path: str) -> List[str]:
    """The names of an entry's path in a data location (invalid-params for none, or a '.' or '..')."""
    parts = [p for p in str(path).replace("\\", "/").split("/") if p]
    if not parts or any(p in (".", "..") for p in parts):
        raise NansenError("invalid-params", f"{path!r} is not a path in the data location")
    return parts


def within(entry: str, path: str) -> bool:
    """Whether a listing entry is the entry at path, or below it (a folder's path ends with '/')."""
    return entry == path or (path.endswith("/") and entry.startswith(path))


def copy_dataset(source, target: Path) -> None:
    """Copy a DSM config into a project, making its relative root paths absolute so they still point there.

    Only those values change in the text (nansen.jsontext), as in MATLAB's nansen.internal.copyDataset.
    """
    source = Path(source)
    if not source.is_file():
        raise NansenError("file-not-found", f"no DSM config {source}")
    text = source.read_text(encoding="utf-8")
    try:
        config = json.loads(text)
    except ValueError as error:
        raise NansenError("malformed-json", f"{source}: {error}") from None
    from . import jsontext

    folder = source.resolve().parent
    for i, location in enumerate(config.get("dataLocations", [])):
        for j, root in enumerate(location.get("filesystemSource", {}).get("rootStoragePaths", [])):
            path = root.get("path")
            if isinstance(path, str) and not os.path.isabs(path) and not re.match(r"^[A-Za-z]:[\\/]", path):
                absolute = os.path.normpath(os.path.join(folder, path)).replace("\\", "/")
                text = jsontext.replace(text, f"/dataLocations/{i}/filesystemSource/rootStoragePaths/{j}/path", absolute)
    with open(target, "w", encoding="utf-8", newline="") as f:  # Path.write_text has newline= from 3.10 only
        f.write(text)
