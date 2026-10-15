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
import time
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
        """Version 5 (scipy), or version 7.3 (HDF5, with h5py) when a variable is MAT73_BYTES or more, as MATLAB's
        save needs -v7.3 for a variable of 2 GB or more."""
        if not isinstance(data, dict):
            data = {"data": data}
        numpy = _optional("numpy", "mat")
        if any(numpy.asarray(v).nbytes >= MAT73_BYTES for v in data.values()
               if isinstance(v, numpy.ndarray) or (isinstance(v, list) and v and all(_is_number(x) for x in v))):
            write_mat73(path, data)
            return
        _optional("scipy.io", "mat").savemat(str(path), data)


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

    def reopen(self, path: Path, shape: Any, dtype: Any) -> Any:
        """A writer that goes on writing into an array file create began (nansen.progress): None unless the file is
        an array of this shape and type, frames together. A file cut short (by MATLAB's writer, which writes
        frames in order) is filled out with zeros; frames_on_disk is how many frames it held."""
        numpy = _optional("numpy", "npy")
        from .stacks import StackWriter
        shape, dtype = tuple(int(n) for n in shape), numpy.dtype(dtype)
        with open(path, "rb") as f:
            version = numpy.lib.format.read_magic(f)
            read_header = numpy.lib.format.read_array_header_1_0 if version == (1, 0) else numpy.lib.format.read_array_header_2_0
            found, fortran, kind = read_header(f)
            offset = f.tell()
        if tuple(found) != shape or not fortran or kind != dtype.newbyteorder("<") and kind != dtype:
            return None
        frame_bytes = dtype.itemsize
        for n in shape[:-1]:
            frame_bytes *= n
        size = Path(path).stat().st_size
        needed = offset + frame_bytes * shape[-1]
        if size < needed:
            with open(path, "r+b") as f:
                f.truncate(needed)
        target = numpy.memmap(str(path), dtype=kind, mode="r+", offset=offset, shape=shape, order="F")
        writer = StackWriter(shape, dtype, target=target)
        writer.frames_on_disk = min(shape[-1], (size - offset) // frame_bytes) if frame_bytes else shape[-1]
        return writer


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


MAT73_BYTES = 2 ** 31   # a variable this large or larger is written to a version 7.3 file


def _is_number(x: Any) -> bool:
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def write_mat73(path: Path, data: Dict[str, Any]) -> None:
    """The variables as a MATLAB v7.3 .mat file (HDF5 with MATLAB's 512-byte header), written with h5py as MATLAB
    writes them, so MATLAB's load reads them and read_mat73 gives them back: arrays with their dimensions reversed
    (MATLAB's column-major order; a vector is 1 x n) and their MATLAB_class, bools as logical, text as char, dicts
    as structs, lists of numbers as arrays and other lists as cell arrays (1 x n), None and empty values as empty
    double. Written to a temporary file next to it and moved over it."""
    h5py = _optional("h5py", "mat (v7.3)")
    numpy = _optional("numpy", "mat (v7.3)")
    classes = {"float64": "double", "float32": "single", "int8": "int8", "uint8": "uint8", "int16": "int16",
               "uint16": "uint16", "int32": "int32", "uint32": "uint32", "int64": "int64", "uint64": "uint64",
               "bool": "logical"}
    counter = [0]

    def empty(where, name, kind="double"):
        where[name] = numpy.zeros(2, dtype=numpy.uint64)   # MATLAB keeps an empty array's size as its data
        where[name].attrs["MATLAB_class"] = numpy.bytes_(kind)
        where[name].attrs["MATLAB_empty"] = numpy.uint8(1)
        return where[name]

    def put(f, where, name, item):
        if isinstance(item, dict):
            group = where.create_group(name)
            group.attrs["MATLAB_class"] = numpy.bytes_("struct")
            fields = [str(k) for k in item]
            names = numpy.empty(len(fields), dtype=object)   # MATLAB's field order: each name as characters
            for i, k in enumerate(fields):
                names[i] = numpy.array(list(k), dtype="S1")
            group.attrs.create("MATLAB_fields", names, dtype=h5py.vlen_dtype(numpy.dtype("S1")))
            for k in fields:
                put(f, group, k, item[k])
            return group
        if isinstance(item, str):
            if not item:
                dataset = empty(where, name, "char")
            else:
                where[name] = numpy.array([[ord(c) for c in item]], dtype=numpy.uint16).T
                dataset = where[name]
                dataset.attrs["MATLAB_class"] = numpy.bytes_("char")
            dataset.attrs["MATLAB_int_decode"] = numpy.int32(2)
            return dataset
        if item is None or (isinstance(item, (list, tuple)) and not item):
            return empty(where, name)
        if isinstance(item, (list, tuple)) and not all(_is_number(x) or isinstance(x, (numpy.number, numpy.bool_)) for x in item) \
                or (isinstance(item, numpy.ndarray) and item.dtype == object):
            cells = list(item) if isinstance(item, (list, tuple)) else list(item.ravel())
            refs = f.require_group("#refs#")
            references = []
            for cell in cells:
                counter[0] += 1
                references.append(put(f, refs, f"c{counter[0]}", cell).ref)
            where.create_dataset(name, data=numpy.array([references], dtype=h5py.ref_dtype).T)
            where[name].attrs["MATLAB_class"] = numpy.bytes_("cell")
            return where[name]
        array = numpy.asarray(item)
        if array.dtype.kind in "US":
            return put(f, where, name, str(array.item()) if array.ndim == 0 else [str(x) for x in array.ravel()])
        kind = classes.get(array.dtype.name)
        if kind is None:
            raise NansenError("invalid-data", f"a .mat file cannot hold {array.dtype} values ({name})")
        if array.size == 0:
            return empty(where, name, kind)
        if array.ndim < 2:
            array = array.reshape(1, -1)   # a scalar is 1 x 1, a vector 1 x n, as MATLAB has them
        where.create_dataset(name, data=(array.astype(numpy.uint8) if kind == "logical" else array).T,
                             chunks=True if array.nbytes > 2 ** 20 else None)
        where[name].attrs["MATLAB_class"] = numpy.bytes_(kind)
        if kind == "logical":
            where[name].attrs["MATLAB_int_decode"] = numpy.int32(1)
        return where[name]

    path = Path(path)
    temporary = path.with_name(path.name + ".tmp")
    try:
        with h5py.File(str(temporary), "w", userblock_size=512) as f:
            for name, item in data.items():
                put(f, f, str(name), item)
        text = time.strftime("MATLAB 7.3 MAT-file, Platform: GLNXA64, Created on: %a %b %d %H:%M:%S %Y HDF5 schema 1.00 .")
        header = text.ljust(116).encode("ascii") + b"\x00" * 8 + b"\x00\x02" + b"IM"
        with open(temporary, "r+b") as handle:
            handle.write(header)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


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

    def for_rois(self, extension: str) -> List[str]:
        """Ids of the adapters that read files of an extension as ROIs (declared with data type RoiArray, and the
        built-in json for .json, the ROI document as ophys saves it), in id order."""
        extension = extension.lower()
        ids = [i for i, doc in self._declarations.items()
               if doc.get("dataType") == "RoiArray" and extension in [e.lower() for e in doc.get("extensions", [])]]
        if extension == ".json":
            ids.append("json")
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
