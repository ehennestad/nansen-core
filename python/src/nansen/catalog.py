"""The project catalog: the projects a user has opened, kept in a file the app is given."""

from __future__ import annotations

import datetime as dt
import re
import os
import sys
from pathlib import Path
from typing import List, Optional

from .documents import PathLike, check_document, read_document, write_json
from .errors import NansenError
from .schemas import current_version


def default_catalog_path() -> Path:
    """Where the app keeps the catalog for this user. Only entry points use it; the core takes a path."""
    if sys.platform == "win32":
        base = Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming"))
    elif sys.platform == "darwin":
        base = Path.home() / "Library" / "Application Support"
    else:
        base = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return base / "nansen" / "catalog.nansen.json"


DEFAULT_SETTINGS = {"queue": {"autoStart": True, "worker": "thread"}, "addons": {"folder": ""}, "workers": {"python": "", "matlab": ""},
                    "tables": {"saveToDataFolders": False}}


class Catalog:
    def __init__(self, path: PathLike):
        self.path = Path(path)

    def settings(self) -> dict:
        """The user's app settings, with the defaults for those not set."""
        stored = self._read().get("settings", {})
        return {group: dict(values, **stored.get(group, {})) for group, values in DEFAULT_SETTINGS.items()}

    def save_settings(self, settings: dict) -> dict:
        """Change some settings (a partial settings object); returns them all."""
        document = self._read()
        stored = document.get("settings", {})
        for group, values in (settings or {}).items():
            if not isinstance(values, dict):
                raise NansenError("invalid-params", f"settings.{group} must be an object")
            stored[group] = dict(stored.get(group, {}), **values)
        document["settings"] = stored
        try:
            self._write(document)
        except NansenError as error:
            raise NansenError("invalid-params", f"settings: {error.message}") from None
        return self.settings()

    def _read(self) -> dict:
        if not self.path.is_file():
            return {"schemaType": "nansen.catalog", "schemaVersion": current_version("nansen.catalog"), "projects": []}
        return read_document(self.path, "nansen.catalog")

    def _write(self, document: dict) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        write_json(self.path, check_document(document, "nansen.catalog"))

    def projects(self) -> List[dict]:
        """Projects, most recently opened first, each with whether its folder still holds a project."""
        # Entries are appended when added, so of two opened in the same second the later one is last
        projects = list(reversed(self._read()["projects"]))
        projects.sort(key=lambda p: p.get("lastOpened", ""), reverse=True)
        return [dict(p, available=(Path(p["path"]) / "project.nansen.json").is_file()) for p in projects]

    def add(self, project, opened: bool = True) -> dict:
        """Record a project (a Project); updates the entry for the same folder."""
        document = self._read()
        path = str(Path(project.folder).resolve())
        entry = {"name": project.name, "title": project.title, "path": path}
        if opened:
            entry["lastOpened"] = dt.datetime.now().isoformat(timespec="seconds")
        others = [p for p in document["projects"] if p["path"] != path]
        document["projects"] = others + [entry]
        self._write(document)
        return entry

    def relocate(self, path: PathLike, new_path: PathLike) -> dict:
        """Point an entry at the folder its project was moved to; the project there must have the entry's name."""
        from .documents import read_document

        document = self._read()
        path = str(Path(path).resolve())
        entry = next((p for p in document["projects"] if p["path"] == path), None)
        if entry is None:
            raise NansenError("unknown-project", f"{path} is not in the catalog")
        new_path = str(Path(new_path).expanduser().resolve())
        project_file = Path(new_path) / "project.nansen.json"
        if not project_file.is_file():
            raise NansenError("file-not-found", f"{new_path} holds no project.nansen.json")
        found = read_document(project_file, "nansen.project")
        if found["name"] != entry["name"]:
            raise NansenError("invalid-params", f"{new_path} holds project {found['name']!r}, not {entry['name']!r}")
        document["projects"] = [p for p in document["projects"] if p["path"] != new_path]
        for p in document["projects"]:
            if p["path"] == path:
                p["path"] = new_path
        self._write(document)
        return next(p for p in document["projects"] if p["path"] == new_path)

    def rename(self, path: PathLike, name: str) -> dict:
        """Give an entry's project another name, in its project.nansen.json (the rest of the file as it was) and here."""
        from . import jsontext
        from .documents import read_document

        if not isinstance(name, str) or not re.match(r"^[A-Za-z][A-Za-z0-9_]*$", name):
            raise NansenError("invalid-params", f"{name!r} is not a project name: a letter, then letters, digits or _")
        document = self._read()
        path = str(Path(path).resolve())
        entry = next((p for p in document["projects"] if p["path"] == path), None)
        if entry is None:
            raise NansenError("unknown-project", f"{path} is not in the catalog")
        project_file = Path(path) / "project.nansen.json"
        read_document(project_file, "nansen.project")   # it is a project
        text = project_file.read_text(encoding="utf-8")
        project_file.write_text(jsontext.replace(text, "/name", name), encoding="utf-8")
        entry["name"] = name
        self._write(document)
        return entry

    def remove(self, path: PathLike) -> None:
        document = self._read()
        path = str(Path(path).resolve())
        kept = [p for p in document["projects"] if p["path"] != path]
        if len(kept) == len(document["projects"]):
            raise NansenError("unknown-project", f"{path} is not in the catalog")
        document["projects"] = kept
        self._write(document)

    def find(self, name: str) -> Optional[dict]:
        for project in self.projects():
            if project["name"] == name:
                return project
        return None
