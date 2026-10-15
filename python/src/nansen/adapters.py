"""File adapters: read a file into a value, write a value to a file.

A registry maps adapter ids to adapters. It is built per project (built-ins
plus the declared ones) and passed around; there is no global registry.
"""

from __future__ import annotations

import importlib
import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Protocol

from .documents import PathLike
from .errors import NansenError


class FileAdapter(Protocol):
    def read(self, path: Path) -> Any: ...

    def write(self, path: Path, data: Any) -> None: ...


class JsonAdapter:
    """Any JSON value."""

    extensions = [".json"]

    def read(self, path: Path) -> Any:
        with open(path, encoding="utf-8") as f:
            return json.load(f)

    def write(self, path: Path, data: Any) -> None:
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write("\n")


class TextAdapter:
    """A UTF-8 text file as a string."""

    extensions = [".txt", ".log", ".md"]

    def read(self, path: Path) -> str:
        return Path(path).read_text(encoding="utf-8")

    def write(self, path: Path, data: Any) -> None:
        with open(path, "w", encoding="utf-8", newline="") as f:  # Path.write_text has newline= from 3.10 only
            f.write(str(data))


class MatAdapter:
    """A MATLAB .mat file (v5/v7) as a dict of variables. Needs scipy."""

    extensions = [".mat"]

    def read(self, path: Path) -> Dict[str, Any]:
        io = _optional("scipy.io", "mat")
        data = io.loadmat(str(path), squeeze_me=True, simplify_cells=True)
        return {k: v for k, v in data.items() if not k.startswith("__")}

    def write(self, path: Path, data: Any) -> None:
        io = _optional("scipy.io", "mat")
        if not isinstance(data, dict):
            data = {"data": data}
        io.savemat(str(path), data)


class NpyAdapter:
    """A NumPy .npy array. Needs numpy."""

    extensions = [".npy"]

    def read(self, path: Path) -> Any:
        return _optional("numpy", "npy").load(str(path), allow_pickle=False)

    def write(self, path: Path, data: Any) -> None:
        numpy = _optional("numpy", "npy")
        numpy.save(str(path), numpy.asarray(data), allow_pickle=False)


def _optional(module: str, adapter: str):
    try:
        return importlib.import_module(module)
    except ImportError:
        raise NansenError("adapter-unavailable", f"the {adapter} adapter needs {module.split('.')[0]}") from None


BUILT_IN = {"json": JsonAdapter, "text": TextAdapter, "mat": MatAdapter, "npy": NpyAdapter}


class AdapterRegistry:
    """Adapter ids to adapters. Declared adapters are imported when first used."""

    def __init__(self, include_built_in: bool = True):
        self._adapters: Dict[str, Any] = {}
        self._declarations: Dict[str, dict] = {}
        self._roots: Dict[str, Optional[Path]] = {}
        if include_built_in:
            for adapter_id, cls in BUILT_IN.items():
                self._adapters[adapter_id] = cls()

    def register(self, adapter_id: str, adapter: Any) -> None:
        self._adapters[adapter_id] = adapter

    def declare(self, document: dict, root: Optional[PathLike] = None) -> None:
        """Add a nansen.fileAdapter declaration; ``root`` is the folder its Python module is imported from."""
        self._declarations[document["id"]] = document
        self._roots[document["id"]] = Path(root) if root is not None else None
        self._adapters.pop(document["id"], None)

    @property
    def ids(self) -> List[str]:
        return sorted(set(self._adapters) | set(self._declarations))

    def __contains__(self, adapter_id: str) -> bool:
        return adapter_id in self._adapters or adapter_id in self._declarations

    def describe(self, adapter_id: str) -> dict:
        if adapter_id in self._declarations:
            doc = self._declarations[adapter_id]
            return {"id": adapter_id, "title": doc.get("title", adapter_id), "extensions": doc.get("extensions", []),
                    "languages": sorted(doc["implementations"]), "builtIn": False}
        adapter = self.get(adapter_id)
        return {"id": adapter_id, "title": (type(adapter).__doc__ or adapter_id).strip().split("\n")[0],
                "extensions": list(getattr(adapter, "extensions", [])),
                "languages": ["matlab", "python"] if adapter_id in ("json", "text", "mat") else ["python"],
                "builtIn": adapter_id in BUILT_IN}

    def get(self, adapter_id: str) -> Any:
        if adapter_id in self._adapters:
            return self._adapters[adapter_id]
        if adapter_id not in self._declarations:
            raise NansenError("unknown-file-adapter", f"no file adapter {adapter_id!r}")
        implementation = self._declarations[adapter_id]["implementations"].get("python")
        if implementation is None:
            raise NansenError("adapter-unavailable", f"file adapter {adapter_id!r} has no Python implementation")
        adapter = load_object(implementation, self._roots[adapter_id])()
        self._adapters[adapter_id] = adapter
        return adapter


def load_object(reference: str, root: Optional[Path] = None) -> Any:
    """Import 'module.path:attribute'.

    With ``root``, the module file is loaded from that folder under a private
    name, without changing sys.path, so two projects can ship modules with
    the same name.
    """
    module_name, attribute = reference.split(":")
    try:
        module = _import_from(root, module_name) if root is not None else importlib.import_module(module_name)
    except (ImportError, FileNotFoundError, SyntaxError) as error:
        raise NansenError("adapter-unavailable", f"cannot import {module_name}: {error}") from None
    try:
        return getattr(module, attribute)
    except AttributeError:
        raise NansenError("adapter-unavailable", f"{module_name} has no {attribute}") from None


def _import_from(root: Path, module_name: str):
    import hashlib
    import importlib.util

    base = Path(root).joinpath(*module_name.split("."))
    path = base / "__init__.py" if base.is_dir() else base.with_suffix(".py")
    if not path.is_file():
        raise FileNotFoundError(f"{path} does not exist")
    private = "nansen_plugins._" + hashlib.sha1(str(path.resolve()).encode()).hexdigest()[:12] + "." + module_name
    # Imported again when the file changes, so an edited method is used without a restart; and compiled
    # here, so no __pycache__ is written into the project or module folder.
    info = path.stat()
    signature = (info.st_mtime_ns, info.st_size)
    module = sys.modules.get(private)
    if module is not None and getattr(module, "__nansen_signature__", None) == signature:
        return module
    spec = importlib.util.spec_from_file_location(private, path)
    module = importlib.util.module_from_spec(spec)
    module.__nansen_signature__ = signature
    sys.modules[private] = module
    try:
        exec(compile(path.read_bytes(), str(path), "exec"), module.__dict__)
    except BaseException:
        sys.modules.pop(private, None)
        raise
    return module
