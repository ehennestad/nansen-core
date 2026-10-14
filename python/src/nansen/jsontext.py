"""Edits to JSON text that keep everything else in the text as it was.

Some files are shared and hand-written, a DSM config above all. Reading one and writing it back would
reformat it, and MATLAB cannot even write it back unchanged (jsondecode loses which arrays had one
element). So edits go to the text: find a value by JSON Pointer (RFC 6901) and replace it, append to an
array, or set an object member. nansen.internal.jsonText does the same in MATLAB, byte for byte; the
cases in conformance/jsontext hold the two to it.
"""

from __future__ import annotations

import json
from typing import Any, List, Tuple

from .errors import NansenError

WHITESPACE = " \t\r\n"


def _missing(message: str) -> NansenError:
    return NansenError("json-pointer-not-found", message)


def _malformed(message: str) -> NansenError:
    return NansenError("malformed-json", message)


def encode(value: Any) -> str:
    """A value as one line of JSON, the way both implementations write inserted values."""
    if isinstance(value, dict):
        return "{" + ", ".join(f"{json.dumps(k, ensure_ascii=False)}: {encode(v)}" for k, v in value.items()) + "}"
    if isinstance(value, list):
        return "[" + ", ".join(encode(v) for v in value) + "]"
    return json.dumps(value, ensure_ascii=False)


def find(text: str, pointer: str) -> Tuple[int, int]:
    """The [start, end) span of the value at the pointer."""
    position = _skip_whitespace(text, 0)
    for segment in _segments(pointer):
        if position >= len(text):
            raise _missing(f"no value at {pointer}")
        if text[position] == "{":
            position = _member(text, position, segment, pointer)
        elif text[position] == "[":
            if not segment.isdigit():
                raise _missing(f"{pointer}: {segment!r} is not an array index")
            position = _element(text, position, int(segment), pointer)
        else:
            raise _missing(f"{pointer}: {segment!r} is inside a value that is not an object or array")
    return position, _skip_value(text, position)


def replace(text: str, pointer: str, value: Any) -> str:
    start, end = find(text, pointer)
    return text[:start] + encode(value) + text[end:]


def append(text: str, pointer: str, value: Any) -> str:
    """Add a value at the end of the array at the pointer."""
    start, end = find(text, pointer)
    if text[start] != "[":
        raise _missing(f"{pointer} is not an array")
    return _insert(text, start, end, encode(value))


def set_member(text: str, pointer: str, key: str, value: Any) -> str:
    """Set a member of the object at the pointer: replace it if it is there, else add it at the end."""
    start, end = find(text, pointer)
    if text[start] != "{":
        raise _missing(f"{pointer} is not an object")
    try:
        return replace(text, pointer.rstrip("/") + "/" + key.replace("~", "~0").replace("/", "~1"), value)
    except NansenError as error:
        if error.code != "json-pointer-not-found":
            raise
        return _insert(text, start, end, f"{json.dumps(key, ensure_ascii=False)}: {encode(value)}")


# -- scanning --------------------------------------------------------------------------------

def _segments(pointer: str) -> List[str]:
    if pointer in ("", "/"):
        return []
    if not pointer.startswith("/"):
        raise _missing(f"a JSON Pointer starts with '/': {pointer!r}")
    return [s.replace("~1", "/").replace("~0", "~") for s in pointer[1:].split("/")]


def _skip_whitespace(text: str, i: int) -> int:
    while i < len(text) and text[i] in WHITESPACE:
        i += 1
    return i


def _skip_string(text: str, i: int) -> int:
    i += 1
    while i < len(text):
        if text[i] == "\\":
            i += 2
        elif text[i] == '"':
            return i + 1
        else:
            i += 1
    raise _malformed("unterminated string")


def _skip_value(text: str, i: int) -> int:
    if text[i] == '"':
        return _skip_string(text, i)
    if text[i] in "{[":
        depth = 0
        while i < len(text):
            c = text[i]
            if c == '"':
                i = _skip_string(text, i)
                continue
            if c in "{[":
                depth += 1
            elif c in "}]":
                depth -= 1
                if depth == 0:
                    return i + 1
            i += 1
        raise _malformed("unterminated object or array")
    while i < len(text) and text[i] not in ",}]" + WHITESPACE:
        i += 1
    return i


def _member(text: str, i: int, key: str, pointer: str) -> int:
    i = _skip_whitespace(text, i + 1)
    while i < len(text) and text[i] != "}":
        end = _skip_string(text, i)
        name = json.loads(text[i:end])
        i = _skip_whitespace(text, end)
        i = _skip_whitespace(text, i + 1)  # the colon
        if name == key:
            return i
        i = _skip_whitespace(text, _skip_value(text, i))
        if i < len(text) and text[i] == ",":
            i = _skip_whitespace(text, i + 1)
    raise _missing(f"no member {key!r} at {pointer}")


def _element(text: str, i: int, index: int, pointer: str) -> int:
    i = _skip_whitespace(text, i + 1)
    n = 0
    while i < len(text) and text[i] != "]":
        if n == index:
            return i
        i = _skip_whitespace(text, _skip_value(text, i))
        if i < len(text) and text[i] == ",":
            i = _skip_whitespace(text, i + 1)
        n += 1
    raise _missing(f"no element {index} at {pointer}")


def _insert(text: str, start: int, end: int, item: str) -> str:
    """Insert an item before the closing bracket of the object or array spanning [start, end)."""
    close = end - 1
    last = close - 1
    while last > start and text[last] in WHITESPACE:
        last -= 1
    if last == start:  # empty
        return text[:start + 1] + item + text[close:]
    first = _skip_whitespace(text, start + 1)
    newline = text.rfind("\n", start, first)
    if newline >= 0:  # one item per line: the new one goes on a line of its own, indented like the first
        return text[:last + 1] + ",\n" + text[newline + 1:first] + item + text[last + 1:]
    return text[:last + 1] + ", " + item + text[last + 1:]
