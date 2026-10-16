"""NANSEN dev's metadata sidecars: the YAML files dev's adapters and image stacks write beside their data.

dev keeps an adapter's metadata (``FileAdapter.setMetadata``: groups ``File``, ``Data`` and ``Custom``) and an image
stack's (``nansen.stack.metadata.StackMetadata``: ``TimeIncrement``, ``PhysicalSizeX``, ...) in ``<name>.yaml`` beside
the file ``<name>.<ext>`` (or ``<name>.yaml.txt``, with dev's SaveYamlAsTxt preference), written with its YAML
toolbox (SnakeYAML). ``parse`` reads the simple YAML that writes, without a YAML package, by the same rules as MATLAB's
``nansen.internal.parseDevYaml`` (the cases in ``conformance/yaml`` hold the two to the same result):

- block mappings and sequences by indentation (a sequence may stand at its key's indentation, and an item may hold a
  mapping on its own line, ``- a: 1``), flow mappings and sequences (``{a: 1, b: x}``, ``[1, 2]``, over several
  lines), comments, a first ``---`` (a second, or ``...``, ends the document);
- scalars: plain (continued on more indented lines, joined by a space), ``'single'`` (``''`` is ``'``) and
  ``"double"`` quoted (with ``\\`` escapes), over several lines as YAML folds them; ``|`` and ``>`` blocks;
- a plain scalar is null (``~``, ``null``, empty), a boolean (``true``, ``yes``, ``on``, ``false``, ``no``, ``off``,
  in lower, title or upper case, as YAML 1.1), a decimal integer (``_`` allowed), a float (``1.5``, ``.5``,
  ``1.0E-5``, ``.inf``, ``.nan``), or else text;
- a mapping's key that is not a MATLAB name (a letter, then letters, digits or ``_``, at most 63) is left out with
  its value, so both languages give the same mapping; a key given twice keeps its first place and its last value.

Anchors, aliases, tags and complex keys are not read: ``invalid-data``, as is text that is not YAML.
"""

from __future__ import annotations

import math
import re
from pathlib import Path
from typing import Any, List, Optional

from .errors import NansenError

KEY = re.compile(r"[A-Za-z][A-Za-z0-9_]{0,62}")
KEYWORDS = ("break", "case", "catch", "classdef", "continue", "else", "elseif", "end", "for", "function", "global",
            "if", "otherwise", "parfor", "persistent", "return", "spmd", "switch", "try", "while")   # MATLAB's
INT = re.compile(r"[-+]?(0|[1-9][0-9_]*)")
FLOAT = re.compile(r"[-+]?(\.[0-9]+|[0-9][0-9_]*(\.[0-9_]*)?)([eE][-+]?[0-9]+)?")
NULLS = ("", "~", "null", "Null", "NULL")
TRUES = ("true", "True", "TRUE", "yes", "Yes", "YES", "on", "On", "ON")
FALSES = ("false", "False", "FALSE", "no", "No", "NO", "off", "Off", "OFF")
UNSUPPORTED = "&*!%@`"
ESCAPES = {"0": "\0", "a": "\a", "b": "\b", "t": "\t", "\t": "\t", "n": "\n", "v": "\v", "f": "\f", "r": "\r",
           "e": "\x1b", " ": " ", '"': '"', "/": "/", "\\": "\\", "N": "\x85", "_": "\xa0"}
SIDECAR_LIMIT = 4 * 1024 * 1024   # bytes: a larger sidecar (frame times of a long recording) is not read
LENGTH_UNITS = {"um": 1, "µm": 1, "μm": 1, "micrometer": 1, "micrometers": 1, "micrometre": 1, "micrometres": 1,
                "micron": 1, "microns": 1, "nm": -1000, "nanometer": -1000, "nanometers": -1000, "nanometre": -1000,
                "nanometres": -1000, "mm": 1000, "millimeter": 1000, "millimeters": 1000, "millimetre": 1000,
                "millimetres": 1000}


def parse(text: str) -> Any:
    """The value of the first YAML document in the text: dicts, lists, str, int, float, bool and None."""
    return _Parser(text).document()


def resolve(text: str) -> Any:
    """A plain scalar's value, as YAML 1.1 (SnakeYAML) resolves it."""
    if text in NULLS:
        return None
    if text in TRUES:
        return True
    if text in FALSES:
        return False
    if INT.fullmatch(text):
        return int(text.replace("_", ""))
    if FLOAT.fullmatch(text):
        return float(text.replace("_", ""))
    if re.fullmatch(r"[-+]?\.(inf|Inf|INF)", text):
        return -math.inf if text.startswith("-") else math.inf
    if text in (".nan", ".NaN", ".NAN"):
        return math.nan
    return text


def _error(message: str, row: int) -> NansenError:
    return NansenError("invalid-data", f"not YAML that dev writes: {message} (line {row + 1})")


class _Parser:
    def __init__(self, text: str):
        text = text.replace("\r\n", "\n").replace("\r", "\n")
        if text.startswith("﻿"):
            text = text[1:]
        self.lines = text.split("\n")
        self.row = -1   # the line read last; the rest of it is done once a node is read
        self.col = 0

    # -- lines ---------------------------------------------------------------------------------

    def rest(self) -> str:
        return self.lines[self.row][self.col:] if 0 <= self.row < len(self.lines) else ""

    def rest_blank(self) -> bool:
        rest = self.rest().lstrip(" \t")
        return rest == "" or rest.startswith("#")

    def indent_of(self, r: int) -> int:
        """The indentation of line r, or -1 when it is blank or a comment."""
        line = self.lines[r]
        n = len(line) - len(line.lstrip(" "))
        content = line[n:].lstrip(" \t")
        if content == "" or content.startswith("#"):
            return -1
        if line[n:n + 1] == "\t":
            raise _error("a tab in the indentation", r)
        return n

    def next_content(self) -> int:
        """Go to the next line with content and return its indentation (-1 at the end of the document)."""
        r = self.row + 1
        while r < len(self.lines):
            n = self.indent_of(r)
            if n >= 0:
                if n == 0 and _marker(self.lines[r]):
                    break
                self.row, self.col = r, n
                return n
            r += 1
        self.row, self.col = len(self.lines), 0
        return -1

    # -- the document --------------------------------------------------------------------------

    def document(self) -> Any:
        r = 0
        while r < len(self.lines) and (self.indent_of(r) < 0 or self.lines[r].startswith("%")):
            r += 1
        if r < len(self.lines) and self.lines[r].startswith("---") and self.lines[r][3:4] in ("", " ", "\t"):
            self.row, self.col = r, 3
            if not self.rest_blank():   # --- {a: 1}
                self.col += len(self.rest()) - len(self.rest().lstrip(" \t"))
                value = self.node_here(-1)
                self.end_of_value()
                return value
        else:
            self.row = r - 1
        value = self.block_node(-1)
        if self.next_content() >= 0:
            raise _error(f"unexpected {self.rest().strip()!r}", self.row)
        return value

    def end_of_value(self) -> None:
        if not self.rest_blank():
            raise _error(f"unexpected {self.rest().strip()!r}", self.row)

    def block_node(self, parent: int, sequence_at_parent: bool = False) -> Any:
        """The node on the lines after the current one, more indented than its parent (None when there is none)."""
        saved = (self.row, self.col)
        n = self.next_content()
        if n > parent or (sequence_at_parent and n == parent and n >= 0 and _entry(self.rest())):
            return self.node_here(parent)
        self.row, self.col = saved
        return None

    def node_here(self, parent: int) -> Any:
        """The node that starts at the current column: a block sequence, a block mapping or a value."""
        if _entry(self.rest()):
            return self.block_sequence(self.col)
        if self.key_ahead():
            return self.block_mapping(self.col)
        return self.inline_value(parent)

    def block_mapping(self, n: int) -> dict:
        out: dict = {}
        while True:
            key = self.read_key()
            self.col += len(self.rest()) - len(self.rest().lstrip(" \t"))
            if self.rest_blank():
                value = self.block_node(n, sequence_at_parent=True)
            else:
                value = self.inline_value(n)
            if _key_ok(key):
                out[key] = value
            saved = (self.row, self.col)
            m = self.next_content()
            if m < n or m < 0:
                self.row, self.col = saved
                return out
            if m > n or not self.key_ahead():
                raise _error("a mapping's entries must line up, as key: value", self.row)

    def block_sequence(self, n: int) -> list:
        out: list = []
        while True:
            self.col = n + 1
            self.col += len(self.rest()) - len(self.rest().lstrip(" \t"))
            if self.rest_blank():
                out.append(self.block_node(n))
            else:
                out.append(self.node_here(n))
            saved = (self.row, self.col)
            m = self.next_content()
            if m < n or m < 0 or (m == n and not _entry(self.rest())):
                self.row, self.col = saved
                return out
            if m > n:
                raise _error("a sequence's items must line up, as - item", self.row)

    def key_ahead(self) -> bool:
        return self.key_end() >= 0

    def key_end(self) -> int:
        """Where the ':' after a key at the current column is (in the line), or -1 when none is there."""
        line, i = self.lines[self.row], self.col
        if i >= len(line) or line[i] in "[{#|>?" + UNSUPPORTED or _entry(line[i:]):
            return -1
        if line[i] in "'\"":
            end = _quoted_end_in_line(line, i)
            if end < 0:
                return -1
            j = end + 1
            while j < len(line) and line[j] in " \t":
                j += 1
            return j if j < len(line) and line[j] == ":" and line[j + 1:j + 2] in ("", " ", "\t") else -1
        j = i
        while j < len(line):
            if line[j] == ":" and line[j + 1:j + 2] in ("", " ", "\t"):
                return j
            if line[j] == "#" and line[j - 1] in " \t":
                return -1
            j += 1
        return -1

    def read_key(self) -> str:
        line, j = self.lines[self.row], self.key_end()
        if line[self.col] in ("'", '"'):
            text = _unquote(line[self.col], line[self.col + 1:_quoted_end_in_line(line, self.col)], self.row)
        else:
            text = line[self.col:j].rstrip(" \t")
        self.col = j + 1
        return text

    # -- values ------------------------------------------------------------------------------

    def inline_value(self, parent: int) -> Any:
        """A value that starts at the current column: a flow collection, a quoted or plain scalar, or a block."""
        first = self.rest()[:1]
        if first in ("[", "{"):
            value = self.flow_node()
        elif first in ("'", '"'):
            value = self.quoted()
        elif first in ("|", ">"):
            return self.block_scalar(parent)
        elif first != "" and first in UNSUPPORTED:
            raise _error(f"anchors, aliases, tags and directives are not read: {self.rest().strip()!r}", self.row)
        else:
            return resolve(self.plain_block(parent))
        self.end_of_value()
        return value

    def plain_block(self, parent: int) -> str:
        """A plain scalar in a block, with the more indented lines after it that go on with it."""
        text = _cut_comment(self.rest()).strip(" \t")
        self.col = len(self.lines[self.row])
        breaks = 0
        r = self.row + 1
        while r < len(self.lines):
            line = self.lines[r]
            content = line.strip(" \t")
            if content == "":
                breaks += 1
                r += 1
                continue
            n = len(line) - len(line.lstrip(" "))
            if n <= parent or content.startswith("#") or (n == 0 and _marker(line)):
                break
            text += ("\n" * breaks if breaks else " ") + _cut_comment(content).strip(" \t")
            breaks = 0
            self.row, self.col = r, len(line)
            r += 1
        if re.search(r":([ \t\n]|$)", text):   # a key where a value goes on: "mapping values are not allowed here"
            raise _error(f"a mapping's entries must line up, as key: value ({text!r})", self.row)
        return text

    def quoted(self) -> str:
        """A quoted scalar from the current column, over as many lines as it takes."""
        quote = self.rest()[0]
        start_row = self.row
        parts: List[str] = []
        r, i = self.row, self.col + 1
        while True:
            if r >= len(self.lines):
                raise _error("a quoted scalar is not closed", start_row)
            line = self.lines[r]
            end = _quoted_end(line, i, quote)
            if end >= 0:
                parts.append(line[i:end])
                self.row, self.col = r, end + 1
                break
            parts.append(line[i:])
            r, i = r + 1, 0
        return _unquote(quote, _fold(parts, quote == '"'), start_row)

    def block_scalar(self, parent: int) -> str:
        """A literal (|) or folded (>) block scalar, with its chomping indicator (- or +)."""
        header = _cut_comment(self.rest()).strip(" \t")
        style, chomp = header[0], ""
        for c in header[1:]:
            if c in "+-" and not chomp:
                chomp = c
            elif c not in "123456789":
                raise _error(f"a block scalar's header {header!r}", self.row)
        self.col = len(self.lines[self.row])
        lines: List[str] = []
        indent = -1
        r = self.row + 1
        while r < len(self.lines):
            line = self.lines[r]
            if line.strip(" ") == "":
                lines.append("")
                r += 1
                continue
            n = len(line) - len(line.lstrip(" "))
            if indent < 0:
                if n <= parent:
                    break
                indent = n
            if n < indent:
                break
            lines.append(line[indent:])
            self.row, self.col = r, len(line)
            r += 1
        trailing = _trailing_empty(lines)
        content = lines[:len(lines) - trailing]
        if style == "|":
            text = "\n".join(content)
        else:
            text, empties = (content[0] if content else ""), 0
            for line in content[1:]:
                if line == "":
                    empties += 1
                else:
                    text += ("\n" * empties if empties else " ") + line
                    empties = 0
        if not content:
            return "\n" * trailing if chomp == "+" else ""
        if chomp == "-":
            return text
        return text + "\n" * (1 + trailing if chomp == "+" else 1)

    # -- flow collections ----------------------------------------------------------------------

    def flow_skip(self) -> None:
        """Past spaces, line breaks and comments inside a flow collection."""
        while True:
            line = self.lines[self.row]
            while self.col < len(line) and line[self.col] in " \t":
                self.col += 1
            if self.col < len(line) and not (line[self.col] == "#" and (self.col == 0 or line[self.col - 1] in " \t")):
                return
            self.row, self.col = self.row + 1, 0
            if self.row >= len(self.lines):
                raise _error("a flow collection is not closed", self.row - 1)

    def flow_node(self) -> Any:
        self.flow_skip()
        c = self.lines[self.row][self.col]
        if c == "[":
            self.col += 1
            items: list = []
            while True:
                self.flow_skip()
                if self.peek() == "]":
                    self.col += 1
                    return items
                items.append(self.flow_node())
                self.flow_skip()
                c = self.peek()
                self.col += 1
                if c == "]":
                    return items
                if c != ",":
                    raise _error(f"expected , or ] in a flow sequence, not {c!r}", self.row)
        if c == "{":
            self.col += 1
            out: dict = {}
            while True:
                self.flow_skip()
                if self.peek() == "}":
                    self.col += 1
                    return out
                c = self.peek()
                key = self.quoted() if c in ("'", '"') else self.plain_flow()
                if c not in ("'", '"') and key == "":
                    raise _error("a flow mapping's key is empty", self.row)
                self.flow_skip()
                value = None
                if self.peek() == ":":
                    self.col += 1
                    self.flow_skip()
                    if self.peek() not in (",", "}"):
                        value = self.flow_node()
                    self.flow_skip()
                if _key_ok(key):
                    out[key] = value
                c = self.peek()
                self.col += 1
                if c == "}":
                    return out
                if c != ",":
                    raise _error(f"expected , or }} in a flow mapping, not {c!r}", self.row)
        if c in ("'", '"'):
            return self.quoted()
        if c in UNSUPPORTED + "|>]},":
            raise _error(f"unexpected {c!r} in a flow collection", self.row)
        return resolve(self.plain_flow())

    def peek(self) -> str:
        line = self.lines[self.row]
        return line[self.col] if self.col < len(line) else ""

    def plain_flow(self) -> str:
        """A plain scalar in a flow collection: up to , [ ] { } or ': ', and on over lines that go on with it."""
        text = ""
        while True:
            line = self.lines[self.row]
            j = self.col
            while j < len(line):
                c = line[j]
                if c in ",[]{}" or (c == ":" and line[j + 1:j + 2] in ("", " ", "\t", ",", "[", "]", "{", "}")) or \
                        (c == "#" and j > 0 and line[j - 1] in " \t"):
                    break
                j += 1
            piece = line[self.col:j].strip(" \t")
            text = piece if not text else (text + " " + piece if piece else text)
            self.col = j
            if j < len(line) or self.row + 1 >= len(self.lines):
                return text
            following = self.lines[self.row + 1].strip(" \t")
            if following == "" or following[0] in ",[]{}:#":
                return text
            self.row, self.col = self.row + 1, 0


def _key_ok(key: str) -> bool:
    """Whether a mapping's key can be a MATLAB struct's field: a name that is not a keyword."""
    return KEY.fullmatch(key) is not None and key not in KEYWORDS


def _marker(line: str) -> bool:
    """A document marker: --- or ... at the start of a line."""
    return line[:3] in ("---", "...") and line[3:4] in ("", " ", "\t")


def _entry(rest: str) -> bool:
    """A block sequence's entry: - followed by a space or nothing."""
    return rest[:1] == "-" and rest[1:2] in ("", " ", "\t")


def _cut_comment(text: str) -> str:
    """The text before a comment (# after a space)."""
    for j in range(1, len(text)):
        if text[j] == "#" and text[j - 1] in " \t":
            return text[:j]
    return "" if text.startswith("#") else text


def _quoted_end(line: str, i: int, quote: str) -> int:
    """Where the closing quote is in the line from i, or -1 when it is not on it."""
    while i < len(line):
        c = line[i]
        if quote == '"' and c == "\\":
            i += 2
            continue
        if c == quote:
            if quote == "'" and line[i + 1:i + 2] == "'":
                i += 2
                continue
            return i
        i += 1
    return -1


def _quoted_end_in_line(line: str, i: int) -> int:
    return _quoted_end(line, i + 1, line[i])


def _trailing_empty(lines: List[str]) -> int:
    n = 0
    while n < len(lines) and lines[len(lines) - 1 - n] == "":
        n += 1
    return n


def _fold(parts: List[str], double: bool) -> str:
    """A quoted scalar's lines as YAML folds them: a line break is a space, an empty line a line break; in double
    quotes, a \\ at the end of a line joins it to the next."""
    if len(parts) == 1:
        return parts[0]
    lines = []
    joined = []   # whether the line ends with an escaped line break
    for k, part in enumerate(parts):
        if k > 0:
            part = part.lstrip(" \t")
        escaped = False
        if k < len(parts) - 1:
            stripped = part.rstrip(" \t")
            if double and (len(stripped) - len(stripped.rstrip("\\"))) % 2 == 1:
                part, escaped = stripped[:-1], True
            else:
                part = stripped
        lines.append(part)
        joined.append(escaped)
    text, empties = lines[0], 0
    for k in range(1, len(lines)):
        line = lines[k]
        if line == "" and k < len(lines) - 1:
            empties += 1
            continue
        separator = "\n" * empties if empties else ("" if joined[k - 1 - empties] else " ")
        text += separator + line
        empties = 0
    return text


def _unquote(quote: str, text: str, row: int) -> str:
    if quote == "'":
        return text.replace("''", "'")
    out = []
    i = 0
    while i < len(text):
        c = text[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        e = text[i + 1:i + 2]
        if e in ESCAPES:
            out.append(ESCAPES[e])
            i += 2
        elif e in ("x", "u", "U"):
            size = {"x": 2, "u": 4, "U": 8}[e]
            digits = text[i + 2:i + 2 + size]
            if len(digits) != size or not re.fullmatch(r"[0-9a-fA-F]+", digits):
                raise _error(f"the escape \\{e}{digits}", row)
            out.append(chr(int(digits, 16)))
            i += 2 + size
        else:
            raise _error(f"the escape \\{e}", row)
    return "".join(out)


# -- dev's sidecars ---------------------------------------------------------------------------

def sidecar_path(path) -> Optional[Path]:
    """dev's metadata file of a data file: <name>.yaml beside it, else <name>.yaml.txt; None when there is neither."""
    path = Path(path)
    for candidate in (path.with_suffix(".yaml"), path.with_name(path.with_suffix(".yaml").name + ".txt")):
        if candidate.is_file():
            return candidate
    return None


def read_sidecar(path) -> Optional[dict]:
    """The mapping in dev's metadata file of a data file; None when there is none, it is too large or not read."""
    sidecar = sidecar_path(path)
    if sidecar is None or sidecar.stat().st_size > SIDECAR_LIMIT:
        return None
    try:
        value = parse(sidecar.read_bytes().decode("utf-8", errors="replace"))
    except NansenError:
        return None
    return value if isinstance(value, dict) else None


def stack_metadata(document: Optional[dict]) -> dict:
    """What dev's metadata file says of a recording, as a stack's metadata (frameRate, pixelSize, zStep), each a
    positive number rounded as the stack adapters round theirs.

    Read at the top (dev's StackMetadata), else in the groups Data and Custom (an adapter's setMetadata): frameRate is
    1 / TimeIncrement in seconds (1000 / it in milliseconds, 1e6 / it in microseconds; dev's SampleRate), else
    SampleRate; pixelSize is [PhysicalSizeX, PhysicalSizeY] and zStep PhysicalSizeZ, in µm (their unit a length:
    micrometer or um, nanometer or nm, millimeter or mm; dev's default unit, pixel, says nothing)."""
    if not isinstance(document, dict):
        return {}
    groups = [document] + [document[g] for g in ("Data", "Custom") if isinstance(document.get(g), dict)]

    def field(name):
        for group in groups:
            if name in group:
                return group[name]
        return None

    def number(v):   # a positive finite number, or None
        usable = not isinstance(v, bool) and isinstance(v, (int, float)) and math.isfinite(v) and v > 0
        return float(v) if usable else None

    out = {}
    rate = None
    step, unit = number(field("TimeIncrement")), field("TimeIncrementUnit")
    if step is not None and isinstance(unit, str):
        unit = unit.strip().lower()
        if "millisecond" in unit or unit == "ms":
            rate = 1000 / step
        elif "microsecond" in unit or unit in ("us", "µs", "μs"):
            rate = 1000000 / step
        elif "second" in unit or unit in ("s", "sec"):
            rate = 1 / step
    if rate is None:
        rate = number(field("SampleRate"))
    sizes = [_micrometers(number(field(f"PhysicalSize{axis}")), field(f"PhysicalSize{axis}Unit")) for axis in "XYZ"]
    rounded = lambda v: math.floor(v * 1e6 + 0.5) / 1e6
    if rate is not None and math.isfinite(rate) and rate > 0:
        out["frameRate"] = rounded(rate)
    if sizes[0] is not None and sizes[1] is not None:
        out["pixelSize"] = [rounded(sizes[0]), rounded(sizes[1])]
    if sizes[2] is not None:
        out["zStep"] = rounded(sizes[2])
    return out


def with_sidecar(stack, path):
    """The stack, with what its files do not say of the recording taken from dev's metadata file beside path."""
    for key, value in stack_metadata(read_sidecar(path)).items():
        if key not in stack.metadata:
            stack.metadata[key] = value
    return stack


def _micrometers(value: Optional[float], unit: Any) -> Optional[float]:
    if value is None or not isinstance(unit, str):
        return None
    factor = LENGTH_UNITS.get(unit.strip().lower())
    if factor is None:
        return None
    value = value / 1000 if factor < 0 else value * factor
    return value if math.isfinite(value) and value > 0 else None
