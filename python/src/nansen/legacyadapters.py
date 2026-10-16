"""NANSEN dev's file adapters, imported as file adapters of a project that run dev's code unchanged in MATLAB.

dev has two kinds of file adapter, both in a project's (or module's) ``+fileadapter`` package:

- a class that subclasses ``nansen.dataio.FileAdapter``, with ``readData`` (and ``writeData``), its constant
  ``DataType`` and ``SUPPORTED_FILE_TYPES``; or that subclasses one of dev's own adapter classes
  (``DEV_ADAPTER_BASES``: its ``ImageStack``, ``RoiGroup``, ``RoiSignalArray``, ...), whose constants it keeps;
- a folder ``+<Name>`` with ``fileadapter.json`` (``_type`` FileAdapter: Name, Description, SupportedFileTypes,
  DataType, ReadFunction, WriteFunction) and ``read.m`` / ``write.m`` in it (dev's DynamicFileAdapter).

Importing one copies its code into the project's ``matlab/`` folder, in the same packages, and writes a
``nansen.fileAdapter`` document with ``legacyFileAdapter``. MATLAB's adapter registry then reads and writes through dev's
class (``load``/``save``, with ``matlab/devcompat``'s ``nansen.dataio.FileAdapter`` as its base) or dev's read and write
functions (``nansen.legacy.FileAdapterShim``). Python has no way to run dev's MATLAB code in a data read, so there such
an adapter is ``adapter-unavailable``, naming MATLAB; the methods that use it run in MATLAB anyway.

dev's own adapter classes are readers of known formats. ``matlab/devcompat`` has a class of each of their names that
reads and writes a file with the adapter here of its file type (``legacyFileAdapter.builtIn``: the ophys module's, or
a built-in), so a subclass's own code (its readData and writeData, when it has them, and its other methods) runs on top
of it unchanged. The variables dev read with a subclass that has neither readData nor writeData of its own are read
with that adapter directly, in both languages.

What the document says is read from the files' text, without running them, by the same rules in both languages
(``nansen.legacy.analyzeFileAdapter``).
"""

from __future__ import annotations

import json
import re
from pathlib import Path, PurePosixPath
from typing import Any, Dict, List, Optional, Sequence, Tuple

from . import legacymethods
from .documents import check_document, write_json
from .errors import NansenError
from .schemas import current_version

FILE_ADAPTER_CLASS = "nansen.dataio.FileAdapter"
DEFINITION = "fileadapter.json"

_STACKS = ("ImageStack", [".ini", ".raw", ".tif", ".tiff", ".avi", ".h5", ".tsm"],
           [(".raw", "ophys.binary_stack"), (".tif", "ophys.tiff_stack"), (".tiff", "ophys.tiff_stack"),
            (".avi", "ophys.video_file"), (".h5", "ophys.hdf5_stack"), (".tsm", "ophys.tsm_stack")])
_ROI_GROUP = ("RoiArray", [".mat", ".npy"], [(".mat", "ophys.nansen_roi_array"), (".npy", "ophys.suite2p_rois")])
_ROI_ARRAY = ("RoiArray", [".mat"], [(".mat", "ophys.nansen_roi_array")])
_SIGNALS = ("RoiSignalArray", [".mat"], [(".mat", "mat")])
_NUMPY = ("struct", [".npy"], [(".npy", "npy")])
# dev's own file adapter classes that a project's adapter may subclass, as readers of known formats: the data type and
# the file types of dev's class (its constants, which a subclass keeps), and the adapter here that reads and writes a
# file of each type in its place (the ophys module's, or a built-in). The core and two-photon modules' classes of the
# same names only subclass these. dev's ImageStack read a .ini (a SciScan recording's header) too; nothing here does.
DEV_ADAPTER_BASES = {
    "nansen.dataio.fileadapter.imagestack.ImageStack": _STACKS,
    "nansen.module.general.core.fileadapter.ImageStack": _STACKS,
    "nansen.dataio.fileadapter.roi.RoiGroup": _ROI_GROUP,
    "nansen.module.ophys.twophoton.fileadapter.RoiGroup": _ROI_GROUP,
    "nansen.dataio.fileadapter.roi.RoiArray": _ROI_ARRAY,
    "nansen.internal.dataio.fileadapter.RoiArray": _ROI_ARRAY,
    "nansen.dataio.fileadapter.timeseries.RoiSignalArray": _SIGNALS,
    "nansen.module.ophys.twophoton.fileadapter.RoiSignalArray": _SIGNALS,
    "nansen.dataio.fileadapter.timeseries.TimeSeries": ("timeseries", [".mat"], [(".mat", "mat")]),
    "nansen.dataio.fileadapter.internal.RoiGroupStruct": ("struct", [".mat"], [(".mat", "mat")]),
    "nansen.dataio.fileadapter.numpy": _NUMPY,
    "nansen.module.general.core.fileadapter.Numpy2Mat": _NUMPY,
}
# those of them that keep each signal as a variable of its own name in the .mat file, as dev's RoiSignalArray does
NAMED_VARIABLE_BASES = ("nansen.dataio.fileadapter.timeseries.RoiSignalArray",
                        "nansen.module.ophys.twophoton.fileadapter.RoiSignalArray")


def analyze_class(name: str, text: str) -> dict:
    """What a dev file adapter class's file says: title (its name), description, extensions and dataType; and, for a
    class built on one of dev's adapter classes (DEV_ADAPTER_BASES), base (that class), builtIn ([(extension, the
    adapter here)], as DEV_ADAPTER_BASES) and overrides (whether it has a readData or writeData of its own); its data
    type and extensions are then dev's class's. ``unsupported-file`` when the file is not a dev file adapter class."""
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    first = next((i for i, line in enumerate(lines) if line.strip() and not line.strip().startswith("%")), None)
    if first is None:
        raise NansenError("unsupported-file", f"{name}.m holds no code")
    declaration = legacymethods._code(lines[first])[0].strip()
    if not re.match(r"^classdef\b", declaration):
        raise NansenError("unsupported-file", f"{name}.m is not a class, so it is not a dev file adapter")
    match = re.match(r"^classdef\s*(?:\([^)]*\))?\s*[A-Za-z][\w.]*\s*(?:<(.*))?$", declaration)
    supers = [s.strip() for s in (match.group(1) or "").split("&")] if match else []
    bases = [s for s in supers if s in DEV_ADAPTER_BASES]
    adapter = FILE_ADAPTER_CLASS in supers or bool(bases)
    others = [s for s in supers if s.startswith("nansen.") and s != FILE_ADAPTER_CLASS and s not in bases]
    if others:
        raise NansenError("unsupported-file", f"{name}.m {'also ' if adapter else ''}subclasses {', '.join(others)}, "
                                              "which nansen-core does not have")
    if not adapter:
        raise NansenError("unsupported-file", f"{name}.m is a class that does not subclass {FILE_ADAPTER_CLASS} "
                                              "or one of dev's file adapters, so it is not a dev file adapter")
    if len(bases) > 1:
        raise NansenError("unsupported-file", f"{name}.m subclasses several of dev's file adapters "
                                              f"({', '.join(bases)})")
    info: Dict[str, Any] = {"title": name, "description": legacymethods._description(lines, first, name),
                            "extensions": [], "dataType": ""}
    overrides = False
    for line in lines:
        code = legacymethods._code(line)[0]
        if re.match(r"^\s*function\s+(?:[^=(]*=\s*)?(?:readData|writeData)\s*(?:\(|$)", code):
            overrides = True
        data_type = re.match(r"^\s*DataType\s*=\s*(?:'([^']*)'|\"([^\"]*)\")", code)
        if data_type and not info["dataType"]:
            info["dataType"] = (data_type.group(1) or data_type.group(2) or "").strip()
        description = re.match(r"^\s*Description\s*=\s*(?:'([^']*)'|\"([^\"]*)\")", code)
        if description and (description.group(1) or description.group(2) or "").strip():
            info["description"] = (description.group(1) or description.group(2)).strip()
        types = re.match(r"^\s*SUPPORTED_FILE_TYPES\s*=\s*(.*)$", code)
        if types and not info["extensions"]:
            ok, value = legacymethods.literal(types.group(1))
            if ok:
                info["extensions"] = extensions_of(value)
    if bases:   # dev's class's constants, which a subclass cannot set again
        data_type, extensions, built_in = DEV_ADAPTER_BASES[bases[0]]
        info.update({"dataType": data_type, "extensions": list(extensions), "base": bases[0],
                     "builtIn": list(built_in), "overrides": overrides})
    return info


def analyze_function(namespace: str, text: str, files: Sequence[str]) -> dict:
    """What a dev function-based file adapter's fileadapter.json says (files: the names of the files in its folder):
    title (its Name), description, extensions, dataType, and its read and write functions. ``unsupported-file`` when
    it is not one, or has no read function."""
    try:
        document = json.loads(text)
    except ValueError:
        raise NansenError("unsupported-file", f"{namespace}: its {DEFINITION} is not valid JSON") from None
    properties = document.get("Properties") if isinstance(document, dict) else None
    if not isinstance(document, dict) or document.get("_type") != "FileAdapter" or not isinstance(properties, dict):
        raise NansenError("unsupported-file", f"{namespace}: its {DEFINITION} is not a dev file adapter (_type FileAdapter)")

    def text_of(name: str) -> str:
        value = properties.get(name)
        return value.strip() if isinstance(value, str) else ""

    info: Dict[str, Any] = {"title": text_of("Name") or namespace.split(".")[-1], "description": text_of("Description"),
                            "extensions": extensions_of(properties.get("SupportedFileTypes")),
                            "dataType": text_of("DataType")}
    for role in ("read", "write"):
        function = text_of(role.capitalize() + "Function")
        if not function and f"{role}.m" in files:
            function = f"{namespace}.{role}"
        if function and not re.fullmatch(r"[A-Za-z][A-Za-z0-9_.]*", function):
            raise NansenError("unsupported-file", f"{namespace}: its {role.capitalize()}Function {function} is not "
                                                  "the name of a function")
        info[role] = function
    if not info["read"]:
        raise NansenError("unsupported-file", f"{namespace}: it has no read function (ReadFunction or read.m)")
    return info


def extensions_of(value: Any) -> List[str]:
    """dev's SUPPORTED_FILE_TYPES ('tif' or {'tif', '.tiff'}) as extensions: '.tif', '.tiff' (as written, once each)."""
    items = [value] if isinstance(value, str) else (value if isinstance(value, list) else [])
    extensions: List[str] = []
    for item in items:
        if not isinstance(item, str):
            continue
        extension = "." + item.strip().lstrip(".")
        if re.fullmatch(r"\.[A-Za-z0-9.]+", extension) and extension not in extensions:
            extensions.append(extension)
    return extensions


def plan(sources: Sequence[Tuple[str, str]], taken: Sequence[str] = ()) -> Tuple[List[dict], List[str]]:
    """The file adapters of dev's +fileadapter files: sources are (path with its package folders, text), such as
    ('code/+RatNav/+fileadapter/MyFormat.m', text). Returns, per adapter, {document, name (dev's name of it, which
    dev's variables give as their FileAdapter), files: [(path under matlab/, text)]; and for a class on one of dev's
    adapter classes, base (that class) and reads ({extension: the adapter here}, when the class has no readData or
    writeData of its own, so that adapter reads its files as the class does; else {})}, and warnings for the files
    that are not file adapters."""
    entries: List[dict] = []
    warnings: List[str] = []
    ids = set(taken)
    by_folder: Dict[str, List[Tuple[str, str]]] = {}
    for path, text in sources:
        folder, _, name = path.rpartition("/")
        by_folder.setdefault(folder, []).append((name, text))
    functional = {folder for folder, files in by_folder.items() if any(name == DEFINITION for name, _ in files)}
    for path, text in sorted(sources, key=lambda s: s[0]):
        folder, _, file_name = path.rpartition("/")
        if folder in functional:
            if file_name != DEFINITION:
                continue   # the code of the function-based adapter of its folder
            namespace = legacymethods.function_name(PurePosixPath(folder + "/x.m")).rpartition(".")[0]
            if not namespace:
                warnings.append(f"file adapter {folder or '.'}: its folder is not a package (+name); left out")
                continue
            files = sorted(by_folder[folder], key=lambda f: f[0])
            try:
                info = analyze_function(namespace, text, [name for name, _ in files])
            except NansenError as error:
                warnings.append(f"file adapter {folder}: {error.message}; left out")
                continue
            implementation, legacy = namespace, {"kind": "function", "read": info["read"]}
            if info["write"]:
                legacy["write"] = info["write"]
            name = info["title"]
            copied = [(_matlab_path(namespace.split("."), file), content) for file, content in files]
        else:
            if not file_name.endswith(".m"):
                continue
            function = legacymethods.function_name(PurePosixPath(path))
            parts = function.split(".")
            try:
                info = analyze_class(parts[-1], text)
            except NansenError as error:
                warnings.append(f"file adapter {path}: {error.message}; left out")
                continue
            implementation, legacy = function, {"kind": "class"}
            if "base" in info:   # dev's class reads and writes with the adapter here of each file type
                legacy["base"] = info["base"]
                legacy["builtIn"] = [{"extension": e, "fileAdapter": a} for e, a in info["builtIn"]]
            name = parts[-1]
            copied = [(_matlab_path(parts[:-1], parts[-1] + ".m"), text)]
        adapter_id = base = "legacy." + legacymethods.snake(name)
        number = 2
        while adapter_id in ids:
            adapter_id, number = f"{base}_{number}", number + 1
        ids.add(adapter_id)
        document: Dict[str, Any] = {"schemaType": "nansen.fileAdapter", "schemaVersion": current_version("nansen.fileAdapter"),
                                    "id": adapter_id, "version": "1.0.0", "title": info["title"]}
        if info["description"]:
            document["description"] = info["description"]
        if info["extensions"]:
            document["extensions"] = info["extensions"]
        if info["dataType"]:
            document["dataType"] = info["dataType"]
        document["implementations"] = {"matlab": implementation}
        document["legacyFileAdapter"] = legacy
        check_document(document, "nansen.fileAdapter")
        entry: Dict[str, Any] = {"document": document, "name": name, "files": copied}
        if "base" in info:
            entry["base"] = info["base"]
            entry["reads"] = {} if info["overrides"] else dict(info["builtIn"])
        entries.append(entry)
    return entries, warnings


def _matlab_path(packages: Sequence[str], file: str) -> str:
    """Where a file of these packages goes under matlab/: +a/+b/file."""
    return "/".join(["+" + p for p in packages] + [file])


def write(folder: Path, entries: List[dict]) -> None:
    """Write planned adapters into a project folder: their documents in file-adapters/, their code in matlab/."""
    for entry in entries:
        for relative, text in entry["files"]:
            path = Path(folder) / "matlab" / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write(text)
        (Path(folder) / "file-adapters").mkdir(exist_ok=True)
        write_json(Path(folder) / "file-adapters" / f"{entry['document']['id']}.fileAdapter.nansen.json", entry["document"])


def sources_at(path: Path) -> List[Tuple[str, str]]:
    """(path with its package folders, text) of a dev file adapter: a .m file, a +<Name> folder with fileadapter.json,
    or each in a folder (such as a dev project's +fileadapter) and its package folders. The path starts at the
    outermost package folder (+name) above the file, so the function names come out right."""
    path = Path(path)

    def prefix(folder: Path) -> str:
        packages: List[str] = []
        for part in reversed(folder.parts):
            if not part.startswith("+") or len(part) < 2:
                break
            packages.insert(0, part)
        return "".join(p + "/" for p in packages)

    if path.is_file():
        if path.suffix != ".m":
            raise NansenError("unsupported-file", f"{path} is not a MATLAB file (.m)")
        return [(prefix(path.parent) + path.name, _read(path))]
    if not path.is_dir():
        raise NansenError("file-not-found", f"no file or folder {path}")
    found: List[Tuple[str, str]] = []

    def walk(folder: Path, relative: str) -> None:
        for item in sorted(folder.iterdir(), key=lambda p: p.name):
            if item.is_file() and (item.suffix == ".m" or item.name == DEFINITION):
                found.append((relative + item.name, _read(item)))
            elif item.is_dir() and item.name.startswith("+") and len(item.name) > 1:
                walk(item, relative + item.name + "/")

    walk(path, prefix(path))
    return sorted(found, key=lambda f: f[0])


def _read(path: Path) -> str:
    with open(path, encoding="utf-8", newline="") as f:
        return f.read()


def import_into(project, path: Any) -> dict:
    """Import dev file adapters (a class's .m file, a function-based adapter's folder, or a folder of them) into a
    project: {adapters: [document, with its files], warnings}. Nothing is written when an id or a file is taken."""
    folder = Path(project.folder)
    path = Path(path)
    sources = sources_at(path)
    if path.is_file():   # the reason a file is not a file adapter is the error
        analyze_class(path.stem, sources[0][1])
    entries, warnings = plan(sources)
    if not entries:
        raise NansenError("unsupported-file", f"{path} holds no dev file adapters")
    existing = set(project.adapters.ids)
    clashes = [f"a file adapter {e['document']['id']!r}" for e in entries if e["document"]["id"] in existing]
    clashes += [f"matlab/{relative}" for e in entries for relative, text in e["files"]
               if (folder / "matlab" / relative).exists() and _read(folder / "matlab" / relative) != text]
    clashes += [f"file-adapters/{e['document']['id']}.fileAdapter.nansen.json" for e in entries
                if (folder / "file-adapters" / f"{e['document']['id']}.fileAdapter.nansen.json").exists()]
    if clashes:
        raise NansenError("adapter-exists", f"the project already has {', '.join(dict.fromkeys(clashes))}")
    write(folder, entries)
    adapters = [dict(e["document"], files=[f"file-adapters/{e['document']['id']}.fileAdapter.nansen.json"] +
                     [f"matlab/{relative}" for relative, _ in e["files"]]) for e in entries]
    return {"adapters": adapters, "warnings": warnings}


def unavailable(document: dict) -> NansenError:
    """The error for reading or writing with a dev file adapter outside MATLAB."""
    return NansenError("adapter-unavailable",
                       f"file adapter {document['id']!r} is NANSEN dev's {document['implementations']['matlab']}, which only "
                       "MATLAB runs: read and write its files in MATLAB (open the project there, or run the method in a "
                       "MATLAB worker)")
