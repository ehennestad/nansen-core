"""A project's dataset: its Dataset Structure Model config, and walking the stores it describes."""

from __future__ import annotations

import datetime as dt
import json
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Tuple

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
             now: Optional[dt.datetime] = None) -> Scan:
        """Walk the stores. Pass a listing to walk a snapshot instead of the file system."""
        if listing is None:
            listing, summary = self.listing()
        else:
            summary = [{"dataLocation": r.data_location, "rootStoragePath": r.root_storage_path,
                        "available": True, "entries": len(r.entries)} for r in listing.roots]
        result = dsm.walk(self.config, listing, registry)
        stamp = (now or dt.datetime.now()).replace(microsecond=0).isoformat()
        document = result.to_dict(include_detail=True)
        return Scan(document["records"], document["unmatched"], summary,
                    listing.environment or self.environment, stamp)

    # -- writing --------------------------------------------------------------------------

    def generate_path(self, data_location: str, entity_type: str, values: Mapping[str, Any]) -> str:
        try:
            return dsm.generate_path(self.config, data_location, entity_type, values)
        except dsm.GenerationError as error:
            raise NansenError("generation-failed", f"[{error.code}] {error.message}") from None

    def absolute(self, data_location: str, relative: str, root_storage_path: Optional[str] = None) -> Path:
        return self.root(data_location, root_storage_path).path / relative


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
