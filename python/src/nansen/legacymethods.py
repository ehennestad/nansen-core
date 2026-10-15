"""NANSEN dev's session methods, imported as methods of a project and run unchanged in MATLAB.

A dev session method is a MATLAB function, ``varargout = name(sessionObject, varargin)``, that returns its attributes
from ``nansen.session.SessionMethod.setAttributes`` when called with no inputs, or a class that subclasses
``nansen.session.SessionMethod`` (with ``runMethod`` and a static ``getDefaultOptions``). Importing one copies its file
into the project's ``matlab/`` folder, in the same packages, and writes a method document with
``legacySessionMethod``: MATLAB's ``nansen.runMethod`` then calls it with a ``nansen.legacy.SessionShim`` for each
session (dev's session object: loadData, saveData, getDataFilePath, getSessionFolder, sessionID, ...). Python runs it
in a MATLAB worker, as any method only MATLAB has.

Its options schema is read from the file's text, without running it, by the same rules in both languages
(``nansen.legacy.analyzeSessionMethod``): the defaults of ``getDefaultParameters`` (functions) or
``getDefaultOptions`` (classes) that are set field by field to plain values (true/false, numbers, text, rows of
numbers, cells of text). dev's ``<name>_`` fields that list the choices of a text option become its ``enum``. Other
defaults are dev's own at run time: the runner starts from dev's defaults and puts the run's options over them.
"""

from __future__ import annotations

import re
from pathlib import Path, PurePath
from typing import Any, Dict, List, Optional, Sequence, Tuple

from .documents import check_document, write_json
from .errors import NansenError
from .schemas import current_version

SESSION_METHOD_CLASS = "nansen.session.SessionMethod"
_QUOTED = r"'(?:[^']|'')*'|\"(?:[^\"]|\"\")*\""
_NUMBER = r"[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?"


def analyze(name: str, text: str) -> dict:
    """What a dev session method's file says about it: kind, title, description, batchMode, queueable and options
    (a JSON Schema). ``unsupported-file`` when the file is not a dev session method."""
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    first = next((i for i, line in enumerate(lines) if line.strip() and not line.strip().startswith("%")), None)
    if first is None:
        raise NansenError("unsupported-file", f"{name}.m holds no code")
    declaration = _code(lines[first])[0].strip()
    if re.match(r"^classdef\b", declaration):
        kind = "class"
    elif re.match(r"^function\b", declaration):
        kind = "function"
    else:
        raise NansenError("unsupported-file", f"{name}.m is a script, not a function or class")
    info: Dict[str, Any] = {"kind": kind, "title": "", "description": _description(lines, first, name),
                            "batchMode": "serial", "queueable": True}
    if kind == "function":
        assignments = _function_options(name, lines, first, info)
    else:
        assignments = _class_options(name, declaration, lines, info)
    info["options"] = {"type": "object", "properties": _properties(assignments)}
    if not info["title"]:
        info["title"] = label(name)
    return info


def _description(lines: List[str], first: int, name: str) -> str:
    """The first line of the help text (the comments after the declaration), less a leading word that is the name."""
    if first + 1 >= len(lines) or not lines[first + 1].strip().startswith("%"):
        return ""
    text = re.sub(r"^%+\s*", "", lines[first + 1].strip()).strip()
    match = re.match(r"^(\S+)\s*(.*)$", text)
    if match and match.group(1).lower() == name.lower():
        text = match.group(2).strip()
    return text


def _function_options(name: str, lines: List[str], first: int, info: dict) -> List[tuple]:
    """A function method's attributes (its ATTRIBUTES and setAttributes flags) and the assignments of its defaults."""
    call = next((i for i, line in enumerate(lines) if "SessionMethod.setAttributes" in _code(line)[0]), None)
    if call is None:
        raise NansenError("unsupported-file", f"{name}.m does not call nansen.session.SessionMethod.setAttributes, "
                                              "so it is not a dev session method")
    words: List[str] = []
    attributes = re.search(r"ATTRIBUTES\s*=\s*\{([^}]*)\}", "\n".join(_code(line)[0] for line in lines))
    if attributes:
        words += _strings(attributes.group(1))
    arguments = re.search(r"setAttributes\(([^)]*)\)", _code(lines[call])[0])
    variable = None
    if arguments:
        words += _strings(arguments.group(1))
        start = re.match(r"^\s*([A-Za-z]\w*)\s*(?:,|$)", arguments.group(1))
        variable = start.group(1) if start else None
    _flags(words, info)
    if variable is None:
        return []
    assignments: List[tuple] = []
    for line in lines[first + 1:call]:   # params = getDefaultParameters(): that local function's fields
        source = re.match(r"^\s*" + variable + r"\s*=\s*([A-Za-z]\w*)\s*(?:\(\s*\))?\s*;?\s*$", _code(line)[0])
        if source:
            assignments += _body_assignments(lines, source.group(1))
    assignments += _assignments(lines[first + 1:call], variable)   # and its fields set in the function itself
    return assignments


def _flags(words: List[str], info: dict) -> None:
    lowered = [w.lower() for w in words]
    if "batch" in lowered:
        info["batchMode"] = "batch"
    if "unqueueable" in lowered:
        info["queueable"] = False
    if "methodname" in lowered and lowered.index("methodname") + 1 < len(words):
        info["title"] = words[lowered.index("methodname") + 1].strip()


def _class_options(name: str, declaration: str, lines: List[str], info: dict) -> List[tuple]:
    """A class method's attributes (its constant properties) and the assignments of getDefaultOptions."""
    match = re.match(r"^classdef\s*(?:\([^)]*\))?\s*[A-Za-z][\w.]*\s*(?:<(.*))?$", declaration)
    supers = [s.strip() for s in (match.group(1) or "").split("&")] if match else []
    if SESSION_METHOD_CLASS not in supers:
        raise NansenError("unsupported-file", f"{name}.m is a class that does not subclass {SESSION_METHOD_CLASS}, "
                                              "so it is not a dev session method")
    others = [s for s in supers if s.startswith("nansen.") and s != SESSION_METHOD_CLASS]
    if others:
        raise NansenError("unsupported-file", f"{name}.m also subclasses {', '.join(others)}, which nansen-core "
                                              "does not have")
    for line in lines:
        code = _code(line)[0]
        batch = re.match(r"^\s*BatchMode\s*=\s*['\"](\w+)['\"]", code)
        if batch and batch.group(1).lower() == "batch":
            info["batchMode"] = "batch"
        queueable = re.match(r"^\s*IsQueueable\s*=\s*(true|false)\b", code)
        if queueable:
            info["queueable"] = queueable.group(1) == "true"
        title = re.match(r"^\s*MethodName\s*=\s*(?:'([^']*)'|\"([^\"]*)\")", code)
        if title and not info["title"]:
            info["title"] = (title.group(1) or title.group(2) or "").strip()
    return _body_assignments(lines, "getDefaultOptions")


def _body_assignments(lines: List[str], function: str) -> List[tuple]:
    """The field assignments of the output of a function (local, or a static method) of the file."""
    for index, line in enumerate(lines):
        match = re.match(r"^\s*function\s+([A-Za-z]\w*)\s*=\s*" + function + r"\b", _code(line)[0])
        if not match:
            continue
        indent = len(line) - len(line.lstrip())
        body = []
        for following in lines[index + 1:]:
            code = _code(following)[0].strip()
            if re.match(r"^function\b", code):
                break
            if re.match(r"^end\b", code) and len(following) - len(following.lstrip()) <= indent:
                break
            body.append(following)
        return _assignments(body, match.group(1))
    return []


def _assignments(lines: List[str], variable: str) -> List[tuple]:
    """(path, value text, comment) of each `variable.a.b = value` line."""
    found = []
    for line in lines:
        code, comment = _code(line)
        match = re.match(r"^\s*" + variable + r"((?:\.[A-Za-z]\w*)+)\s*=(?!=)\s*(.*)$", code)
        if match:
            found.append((match.group(1)[1:].split("."), match.group(2), comment))
    return found


def _code(line: str) -> Tuple[str, str]:
    """A line's code and its comment (the text after a % outside quotes)."""
    quote = ""
    for index, char in enumerate(line):
        if quote:
            if char == quote:
                quote = ""
        elif char == '"' or (char == "'" and (index == 0 or not re.match(r"[\w)\]}.]", line[index - 1]))):
            quote = char   # a ' after a name, a closing bracket or a dot is a transpose
        elif char == "%":
            return line[:index], re.sub(r"^%*\s*", "", line[index:]).strip()
    return line, ""


def _strings(text: str) -> List[str]:
    return [_unquote(s) for s in re.findall(_QUOTED, text)]


def _unquote(text: str) -> str:
    return text[1:-1].replace(text[0] * 2, text[0])


def literal(text: str) -> Tuple[bool, Any]:
    """(True, value) for a plain MATLAB value: true/false, a number, text, a row of numbers or a cell of text."""
    code = text.strip()
    while code.endswith((";", ",")):
        code = code[:-1].strip()
    if code in ("true", "false"):
        return True, code == "true"
    if re.fullmatch(_NUMBER, code):
        return True, _number(code)
    if re.fullmatch(_QUOTED, code):
        return True, _unquote(code)
    if code.startswith("[") and code.endswith("]"):
        items = [i for i in re.split(r"[\s,]+", code[1:-1].strip()) if i]
        if items and all(re.fullmatch(_NUMBER, i) for i in items):
            numbers = [_number(i) for i in items]
            return True, numbers[0] if len(numbers) == 1 else numbers
        return False, None
    if code.startswith("{") and code.endswith("}"):
        inner = code[1:-1]
        if re.sub(_QUOTED, "", inner).strip(" ,\t") == "":
            return True, [_unquote(s) for s in re.findall(_QUOTED, inner)]
    return False, None


def _number(text: str) -> Any:
    return int(text) if re.fullmatch(r"[+-]?\d+", text) else float(text)


def _schema_of(value: Any) -> dict:
    if isinstance(value, bool):
        return {"type": "boolean", "default": value}
    if isinstance(value, (int, float)):
        return {"type": "number", "default": value}
    if isinstance(value, str):
        return {"type": "string", "default": value}
    numbers = all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in value) and value != []
    return {"type": "array", "items": {"type": "number" if numbers else "string"}, "default": value}


def _properties(assignments: List[tuple]) -> dict:
    """The options' properties: one per field set to a plain value, nested for a.b; a later assignment wins."""
    properties: Dict[str, Any] = {}
    choices: List[tuple] = []
    for path, text, comment in assignments:
        ok, value = literal(text)
        if path[-1].endswith("_"):   # dev's config field: the choices of the field of that name
            if ok and isinstance(value, list) and all(isinstance(v, str) for v in value):
                choices.append((path[:-1] + [path[-1][:-1]], value))
            continue
        parent = properties
        for segment in path[:-1]:
            node = parent.get(segment)
            if not (isinstance(node, dict) and node.get("type") == "object"):
                if not ok:
                    parent = None
                    break
                node = {"type": "object", "properties": {}}
                parent[segment] = node
            parent = node["properties"]
        if parent is None:
            continue
        if not ok:
            parent.pop(path[-1], None)   # the default is not a plain value: dev's own is used
            continue
        schema = _schema_of(value)
        if comment:
            schema["description"] = comment
        parent[path[-1]] = schema
    for path, values in choices:
        node: Any = {"properties": properties}
        for segment in path:
            node = node.get("properties", {}).get(segment) if isinstance(node, dict) else None
        if isinstance(node, dict) and node.get("type") == "string" and node["default"] in values:
            node["enum"] = values
    return properties


def label(name: str) -> str:
    """dev's varname2label: words of a camelCase name, the first letter upper case."""
    text = " ".join(re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", name).replace("_", " ").split())
    return text[:1].upper() + text[1:]


def snake(name: str) -> str:
    text = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", name)
    text = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", text).lower()
    return re.sub(r"_+", "_", text).strip("_") or "method"


def function_name(path: PurePath) -> str:
    """The MATLAB name of a .m file: its package folders (+name) and its name."""
    packages = []
    for folder in reversed(path.parent.parts):
        if not folder.startswith("+") or len(folder) < 2:
            break
        packages.insert(0, folder[1:])
    return ".".join(packages + [path.stem])


def plan(sources: Sequence[Tuple[str, str, str]], entity_type: str, taken: Sequence[str] = ()) -> Tuple[List[dict], List[str]]:
    """The methods of dev session method files: sources are (label, function name, text). Returns, per method,
    {document, file (under matlab/), text, function}, and warnings for the files that are not session methods."""
    entries: List[dict] = []
    warnings: List[str] = []
    ids = set(taken)
    for where, function, text in sources:
        parts = function.split(".")
        try:
            info = analyze(parts[-1], text)
        except NansenError as error:
            warnings.append(f"session method {where}: {error.message}; left out")
            continue
        method_id = base = "legacy." + snake(parts[-1])
        number = 2
        while method_id in ids:
            method_id, number = f"{base}_{number}", number + 1
        ids.add(method_id)
        document: Dict[str, Any] = {"schemaType": "nansen.method", "schemaVersion": current_version("nansen.method"),
                                    "id": method_id, "version": "1.0.0", "title": info["title"]}
        if info["description"]:
            document["description"] = info["description"]
        lowered = [p.lower() for p in parts[:-1]]
        if "sessionmethod" in lowered:   # dev's menus: the packages under +sessionmethod
            groups = parts[len(lowered) - lowered[::-1].index("sessionmethod"):-1]
            if groups:
                document["category"] = "/".join(label(g) for g in groups)
        document["entityType"] = entity_type
        document["batchMode"] = info["batchMode"]
        if not info["queueable"]:
            document["queueable"] = False
        document["implementations"] = {"matlab": function}
        document["legacySessionMethod"] = {"kind": info["kind"]}
        document["options"] = info["options"]
        check_document(document, "nansen.method")
        file = "/".join(["+" + p for p in parts[:-1]] + [parts[-1] + ".m"])
        entries.append({"document": document, "file": file, "text": text, "function": function})
    return entries, warnings


def write(project, entries: List[dict]) -> None:
    """Write the planned methods into a project: their documents in methods/, their code in matlab/."""
    for entry in entries:
        path = project.folder / "matlab" / entry["file"]
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(entry["text"])
        (project.folder / "methods").mkdir(exist_ok=True)
        write_json(project.folder / "methods" / f"{entry['document']['id']}.method.nansen.json", entry["document"])


def sources_at(path: Path) -> Tuple[List[Tuple[str, str, str]], bool]:
    """(label, function name, text) of the .m file at path, or of each in a folder and its package folders (+name);
    and whether path is a folder."""
    if path.is_file():
        if path.suffix != ".m":
            raise NansenError("unsupported-file", f"{path} is not a MATLAB file (.m)")
        return [(path.name, function_name(path), _read(path))], False
    if not path.is_dir():
        raise NansenError("file-not-found", f"no file or folder {path}")
    files: List[Tuple[str, Path]] = []

    def walk(folder: Path, relative: str) -> None:
        for item in sorted(folder.iterdir(), key=lambda p: p.name):
            if item.is_file() and item.suffix == ".m":
                files.append((relative + item.name, item))
            elif item.is_dir() and item.name.startswith("+"):
                walk(item, relative + item.name + "/")

    walk(path, "")
    files.sort(key=lambda f: f[0])
    return [(where, function_name(file), _read(file)) for where, file in files], True


def _read(path: Path) -> str:
    with open(path, encoding="utf-8", newline="") as f:
        return f.read()


def import_into(project, path: Any, entity_type: Optional[str] = None) -> dict:
    """Import the dev session method of a .m file, or those of a folder, into a project: {methods, warnings}."""
    folder = Path(project.folder)
    path = Path(path)
    if not path.is_absolute():
        path = folder / path
    if entity_type is None:
        entity_type = "session" if "session" in project.entity_types else "*"
    elif entity_type != "*":
        project.entity_type(entity_type)
    sources, is_folder = sources_at(path)
    if not is_folder:   # the reason a file is not a session method is the error
        analyze(sources[0][1].split(".")[-1], sources[0][2])
    entries, warnings = plan(sources, entity_type)
    if not entries:
        raise NansenError("unsupported-file", f"{path} holds no dev session methods")
    existing = {m.id for m in project.methods()}
    clashes = [e["document"]["id"] for e in entries if e["document"]["id"] in existing]
    clashes += [f"matlab/{e['file']}" for e in entries if (folder / "matlab" / e["file"]).exists()]
    clashes += [f"methods/{e['document']['id']}.method.nansen.json" for e in entries
                if (folder / "methods" / f"{e['document']['id']}.method.nansen.json").exists()]
    if clashes:
        raise NansenError("method-exists", f"the project already has {', '.join(dict.fromkeys(clashes))}")
    write(project, entries)
    return {"methods": [project.method(e["document"]["id"]).summary() for e in entries], "warnings": warnings}
