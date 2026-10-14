"""Modules: versioned bundles of fragments, methods and file adapters, listed by path in module.nansen.json."""

from __future__ import annotations

from pathlib import Path
from typing import List, Optional

from .documents import PathLike, read_document
from .errors import NansenError
from .methods import Method

MODULE_FILE = "module.nansen.json"
_PACKAGE_DIR = Path(__file__).resolve().parent
_BUILT_IN_CANDIDATES = [_PACKAGE_DIR / "builtin_modules", _PACKAGE_DIR.parent.parent.parent / "modules"]


def built_in_modules_dir() -> Optional[Path]:
    for candidate in _BUILT_IN_CANDIDATES:
        if candidate.is_dir():
            return candidate
    return None


class Module:
    """A module folder. Its Python code is imported from python/, its MATLAB code is in matlab/."""

    def __init__(self, folder: PathLike, document: dict):
        self.folder = Path(folder)
        self.document = document

    @classmethod
    def read(cls, folder: PathLike) -> "Module":
        folder = Path(folder)
        return cls(folder, read_document(folder / MODULE_FILE, "nansen.module"))

    @property
    def id(self) -> str:
        return self.document["id"]

    @property
    def version(self) -> str:
        return self.document["version"]

    @property
    def python_root(self) -> Path:
        return self.folder / "python"

    @property
    def matlab_root(self) -> Path:
        return self.folder / "matlab"

    def _documents(self, key: str, schema_type: str) -> List[dict]:
        return [read_document(self.folder / relative, schema_type) for relative in self.document.get(key, [])]

    def fragment_documents(self) -> List[dict]:
        return self._documents("fragments", "nansen.fragment")

    def methods(self) -> List[Method]:
        return [Method(doc, self.python_root, self.matlab_root, self.id)
                for doc in self._documents("methods", "nansen.method")]

    def file_adapter_documents(self) -> List[dict]:
        return self._documents("fileAdapters", "nansen.fileAdapter")

    def pipeline_documents(self) -> List[dict]:
        return self._documents("pipelines", "nansen.pipeline")

    def summary(self) -> dict:
        return {"id": self.id, "version": self.version, "title": self.document.get("title", self.id),
                "description": self.document.get("description", ""), "folder": str(self.folder)}


def resolve_module(entry: dict, project_folder: Path) -> Module:
    """Find a module listed in a project: its path, else <project>/modules/<id>, else the built-in modules."""
    candidates = []
    if "path" in entry:
        path = Path(entry["path"])
        candidates.append(path if path.is_absolute() else project_folder / path)
    else:
        candidates.append(project_folder / "modules" / entry["id"])
        built_in = built_in_modules_dir()
        if built_in is not None:
            candidates.append(built_in / entry["id"])
    for candidate in candidates:
        if (candidate / MODULE_FILE).is_file():
            module = Module.read(candidate)
            if module.id != entry["id"]:
                raise NansenError("module-mismatch", f"{candidate} holds module {module.id!r}, not {entry['id']!r}")
            return module
    raise NansenError("unknown-module", f"module {entry['id']!r} not found (looked in {', '.join(map(str, candidates))})")
