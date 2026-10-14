"""Notes on entities: what dev keeps in each session's and subject's Notebook.

A notebook holds the notes on one entity type's entities, at
notes/<entityType>.notebook.nansen.json in the project. A note is about one
entity, named by its key, and has a time, an author, a type, a title, text, and
the #tags written in them. nansen.Notebook does the same in MATLAB.
"""

from __future__ import annotations

import datetime as dt
import getpass
import re
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

from .documents import check_document, read_document, write_json
from .errors import NansenError
from .schemas import current_version

NOTE_TYPES = ("informal", "important", "todo", "question")
TAG = re.compile(r"#([A-Za-z0-9_]+)")  # ASCII, as MATLAB's \w is


def tags_of(*texts: str) -> List[str]:
    """The words written as #tag, in order, each once."""
    tags: List[str] = []
    for text in texts:
        for tag in TAG.findall(text):
            if tag not in tags:
                tags.append(tag)
    return tags


def default_author() -> str:
    try:
        return getpass.getuser()
    except Exception:  # no user name in this environment
        return ""


class Notebook:
    """The notes on one entity type's entities. Get one with Project.notebook(entityType)."""

    def __init__(self, path: Path, entity_type: str, key_names: Sequence[str]):
        self.path = Path(path)
        self.entity_type = entity_type
        self.key_names = list(key_names)

    def _read(self) -> dict:
        if not self.path.is_file():
            return {"schemaType": "nansen.notebook", "schemaVersion": current_version("nansen.notebook"),
                    "entityType": self.entity_type, "nextId": 1, "notes": []}
        return read_document(self.path, "nansen.notebook")

    def _write(self, document: dict) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        write_json(self.path, check_document(document, "nansen.notebook"))

    def check_key(self, key: Any) -> Dict[str, Any]:
        if not isinstance(key, dict) or sorted(key) != sorted(self.key_names):
            raise NansenError("invalid-params", f"a key of {self.entity_type} has the columns {', '.join(self.key_names)}")
        for name in self.key_names:
            if isinstance(key[name], bool) or not isinstance(key[name], (str, int)):
                raise NansenError("invalid-params", f"key column {name!r} must be text or an integer")
        return {name: key[name] for name in self.key_names}

    def notes(self, key: Optional[Dict[str, Any]] = None) -> List[dict]:
        """Notes, newest first; only the entity's when a key is given."""
        notes = self._read()["notes"]
        if key is not None:
            key = self.check_key(key)
            notes = [n for n in notes if n["key"] == key]
        return list(reversed(notes))

    def add(self, key: Dict[str, Any], text: str, title: str = "", note_type: str = "informal",
            author: Optional[str] = None, created_at: Optional[str] = None) -> dict:
        """Add a note; created_at (YYYY-MM-DDTHH:MM:SS) is now unless given, as when importing."""
        key = self.check_key(key)
        if note_type not in NOTE_TYPES:
            raise NansenError("invalid-params", f"a note's type is one of {', '.join(NOTE_TYPES)}, not {note_type!r}")
        if not str(text).strip() and not str(title).strip():
            raise NansenError("invalid-params", "a note needs a title or text")
        document = self._read()
        note = {"id": document["nextId"], "key": key,
                "createdAt": created_at or dt.datetime.now().isoformat(timespec="seconds"),
                "author": default_author() if author is None else author,
                "type": note_type, "title": title, "text": text, "tags": tags_of(title, text)}
        document["notes"].append(note)
        document["nextId"] += 1
        self._write(document)
        return note

    def remove(self, note_id: int) -> None:
        document = self._read()
        kept = [n for n in document["notes"] if n["id"] != note_id]
        if len(kept) == len(document["notes"]):
            raise NansenError("unknown-note", f"the {self.entity_type} notebook has no note {note_id}")
        document["notes"] = kept
        self._write(document)
