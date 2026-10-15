"""File adapters: read a file into a value, write a value to a file.

A registry maps adapter ids to adapters. It is built per project (built-ins
plus the declared ones) and passed around; there is no global registry.
"""

from __future__ import annotations

import importlib
import json
import os
import sys
import threading
from pathlib import Path
from typing import Any, Dict, List, Optional, Protocol, Tuple

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
        # through a file beside it, so a reader (another process, the app) never sees half of it
        temporary = Path(path).with_name(f"{Path(path).name}.{os.getpid()}.{threading.get_ident()}.tmp")
        try:
            with open(temporary, "w", encoding="utf-8", newline="\n") as f:
                json.dump(data, f, indent=2, ensure_ascii=False)
                f.write("\n")
            os.replace(temporary, path)
        finally:
            if temporary.exists():
                temporary.unlink()


class TextAdapter:
    """A UTF-8 text file as a string."""

    extensions = [".txt", ".log", ".md"]

    def read(self, path: Path) -> str:
        return Path(path).read_text(encoding="utf-8")

    def write(self, path: Path, data: Any) -> None:
        with open(path, "w", encoding="utf-8", newline="") as f:  # Path.write_text has newline= from 3.10 only
            f.write(str(data))


class MatAdapter:
    """A MATLAB .mat file as a dict of variables. Needs scipy; v7.3 files (HDF5, which MATLAB writes for
    data of 2 GB or more) need h5py too."""

    extensions = [".mat"]

    def read(self, path: Path) -> Dict[str, Any]:
        io = _optional("scipy.io", "mat")
        try:
            data = io.loadmat(str(path), squeeze_me=True, simplify_cells=True)
        except NotImplementedError:   # scipy's word for a v7.3 file
            return read_mat73(path)
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

    def open(self, paths: List[Path]) -> Any:
        """The arrays as one stack, memory-mapped: frames are read when asked for. Several files are joined."""
        numpy = _optional("numpy", "npy")
        from .stacks import from_array, join, natural_order
        return join([from_array(numpy.load(str(p), mmap_mode="r", allow_pickle=False)) for p in natural_order(paths)])

    def create(self, path: Path, shape: Any, dtype: Any) -> Any:
        """A writer of a new array, a chunk of frames at a time, straight into the file. Frames are kept
        together (Fortran order), so a chunk of frames is one stretch of the file to read or write."""
        numpy = _optional("numpy", "npy")
        from .stacks import StackWriter
        target = numpy.lib.format.open_memmap(str(path), mode="w+", dtype=numpy.dtype(dtype), shape=tuple(shape), fortran_order=True)
        return StackWriter(shape, dtype, target=target)


def read_mat73(path: Path) -> Dict[str, Any]:
    """A v7.3 .mat file's variables, read with h5py as scipy reads older files (squeezed, cells simplified):
    numeric and logical arrays (MATLAB's column-major order turned back), text, structs as dicts, and cell
    arrays as lists."""
    h5py = _optional("h5py", "mat (v7.3)")
    numpy = _optional("numpy", "mat (v7.3)")

    def value(f, item):
        if isinstance(item, h5py.Group):   # a struct
            return {name: value(f, item[name]) for name in item if not name.startswith("#")}
        kind = item.attrs.get("MATLAB_class", b"double")
        kind = kind.decode() if isinstance(kind, bytes) else str(kind)
        if item.attrs.get("MATLAB_empty", 0):
            return "" if kind == "char" else numpy.array([])
        array = numpy.asarray(item[()]).T   # HDF5 holds MATLAB's arrays with their dimensions reversed
        if array.dtype == object:   # references: a cell array, or a field of a struct array
            cells = [value(f, f[ref]) for ref in array.T.ravel()]   # in MATLAB's (column-major) order
            return cells[0] if len(cells) == 1 else cells
        if kind == "char":
            rows = ["".join(chr(int(c)) for c in row) for row in numpy.atleast_2d(array)]
            return rows[0] if len(rows) == 1 else rows
        if kind == "logical":
            array = array.astype(bool)
        array = numpy.squeeze(array)
        return array.item() if array.ndim == 0 else array

    with h5py.File(str(path), "r") as f:
        return {name: value(f, f[name]) for name in f if not name.startswith("#")}


def _optional(module: str, adapter: str):
    try:
        return importlib.import_module(module)
    except ImportError:
        raise NansenError("adapter-unavailable", f"the {adapter} adapter needs {module.split('.')[0]}") from None


def _columns(header: List[str], rows: List[List[Any]]) -> Dict[str, List[Any]]:
    """A table's rows as columns: a column whose filled cells are all numbers is floats, NaN where empty, as
    MATLAB's readtable reads it; any other column is strings, empty where empty."""
    out: Dict[str, List[Any]] = {}
    for c, name in enumerate(header):
        cells = [row[c] if c < len(row) else None for row in rows]
        def number(cell):
            if isinstance(cell, bool):
                return None
            if isinstance(cell, (int, float)):
                return float(cell)
            try:
                return float(str(cell).strip())
            except ValueError:
                return None
        filled = [cell for cell in cells if cell is not None and str(cell).strip() != ""]
        if filled and all(number(cell) is not None for cell in filled):
            out[str(name)] = [number(cell) if cell is not None and str(cell).strip() != "" else float("nan") for cell in cells]
        else:
            out[str(name)] = ["" if cell is None else str(cell) for cell in cells]
    return out


def _rows(data: Any) -> Tuple[List[str], List[List[Any]]]:
    """Header and rows of a table given as columns ({name: values}), records ([{name: value}]) or a pandas
    DataFrame. NaN and None are empty cells."""
    if hasattr(data, "to_dict") and hasattr(data, "columns"):
        data = data.to_dict("list")
    if isinstance(data, list):
        header = list(dict.fromkeys(name for record in data for name in record))
        data = {name: [record.get(name) for record in data] for name in header}
    if not isinstance(data, dict) or not all(isinstance(v, (list, tuple)) for v in data.values()):
        raise NansenError("invalid-params", "a table is columns ({name: [values]}) or records ([{name: value}])")
    header = [str(name) for name in data]
    count = max((len(v) for v in data.values()), default=0)
    def cell(value):
        if value is None or (isinstance(value, float) and value != value):
            return None
        return value
    return header, [[cell(column[i]) if i < len(column) else None for column in data.values()] for i in range(count)]


class CsvAdapter:
    """A table in a CSV file, read as columns ({name: [values]}): numeric columns as floats (NaN where empty),
    others as strings. Written from columns or records. MATLAB reads and writes it as a table."""

    extensions = [".csv"]

    def read(self, path: Path) -> Dict[str, List[Any]]:
        import csv
        with open(path, encoding="utf-8-sig", newline="") as f:
            rows = list(csv.reader(f))
        if not rows:
            return {}
        return _columns(rows[0], rows[1:])

    def write(self, path: Path, data: Any) -> None:
        import csv
        header, rows = _rows(data)
        text = lambda v: "" if v is None else repr(float(v)).removesuffix(".0") if isinstance(v, float) else str(v)
        with open(path, "w", encoding="utf-8", newline="") as f:
            writer = csv.writer(f, lineterminator="\n")
            writer.writerow(header)
            writer.writerows([[text(v) for v in row] for row in rows])


class ExcelAdapter:
    """A table in the first sheet of an Excel workbook (.xlsx), as CsvAdapter reads a CSV file. Needs openpyxl."""

    extensions = [".xlsx"]

    def read(self, path: Path) -> Dict[str, List[Any]]:
        openpyxl = _optional("openpyxl", "excel")
        book = openpyxl.load_workbook(str(path), read_only=True, data_only=True)
        try:
            rows = [list(row) for row in book.worksheets[0].iter_rows(values_only=True)]
        finally:
            book.close()
        while rows and all(v is None for v in rows[-1]):
            rows.pop()
        if not rows:
            return {}
        return _columns(["" if v is None else str(v) for v in rows[0]], rows[1:])

    def write(self, path: Path, data: Any) -> None:
        openpyxl = _optional("openpyxl", "excel")
        header, rows = _rows(data)
        book = openpyxl.Workbook()
        sheet = book.active
        sheet.append(header)
        for row in rows:
            sheet.append(row)
        book.save(str(path))


BUILT_IN = {"json": JsonAdapter, "text": TextAdapter, "mat": MatAdapter, "npy": NpyAdapter, "csv": CsvAdapter,
            "excel": ExcelAdapter}


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
                "languages": ["matlab", "python"],
                "builtIn": adapter_id in BUILT_IN}

    def for_extension(self, extension: str) -> List[str]:
        """Ids of the adapters, built-in and declared, that name an extension among theirs, in id order."""
        extension = extension.lower()
        ids = []
        for adapter_id in self.ids:
            if adapter_id in self._declarations:
                extensions = self._declarations[adapter_id].get("extensions", [])
            else:
                extensions = getattr(self._adapters[adapter_id], "extensions", [])
            if extension in [e.lower() for e in extensions]:
                ids.append(adapter_id)
        return ids

    def for_stacks(self, extension: str) -> List[str]:
        """Ids of the adapters that read files of an extension as image stacks (declared with data type ImageStack, and
        the built-in npy for .npy), in id order."""
        extension = extension.lower()
        ids = [i for i, doc in self._declarations.items()
               if doc.get("dataType") == "ImageStack" and extension in [e.lower() for e in doc.get("extensions", [])]]
        if extension == ".npy":
            ids.append("npy")
        return sorted(ids)

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
