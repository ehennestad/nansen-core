"""Split CSV text into fields and join fields into CSV text.

The reader keeps whether each field was quoted, because an unquoted empty
field is a missing value and a quoted one is the empty string.
"""

from __future__ import annotations

from typing import List, NamedTuple, Sequence

from .errors import NansenError


class Field(NamedTuple):
    text: str
    quoted: bool


Record = List[Field]


def parse_csv(text: str) -> List[Record]:
    if text.startswith("﻿"):
        raise NansenError("malformed-csv", "the CSV starts with a byte order mark")
    records: List[Record] = []
    record: Record = []
    field: List[str] = []
    quoted = False
    i, n = 0, len(text)
    if n == 0:
        raise NansenError("malformed-csv", "the CSV is empty; it must at least have a header")
    while i < n:
        if not field and not quoted and text[i] == '"':
            # A quoted field: read to the closing quote.
            quoted = True
            i += 1
            while True:
                if i >= n:
                    raise NansenError("malformed-csv", f"unterminated quoted field in record {len(records) + 1}")
                char = text[i]
                if char == '"':
                    if i + 1 < n and text[i + 1] == '"':
                        field.append('"')
                        i += 2
                        continue
                    i += 1
                    break
                field.append(char)
                i += 1
            if i < n and text[i] not in ",\n\r":
                raise NansenError("malformed-csv", f"text after a closing quote in record {len(records) + 1}")
            continue
        char = text[i]
        if char == ",":
            record.append(Field("".join(field), quoted))
            field, quoted = [], False
            i += 1
        elif char == "\n" or char == "\r":
            if char == "\r":
                if i + 1 >= n or text[i + 1] != "\n":
                    raise NansenError("malformed-csv", f"a carriage return without a line feed in record {len(records) + 1}")
                i += 1
            record.append(Field("".join(field), quoted))
            records.append(record)
            record, field, quoted = [], [], False
            i += 1
        elif char == '"':
            raise NansenError("malformed-csv", f"a double quote inside an unquoted field in record {len(records) + 1}")
        else:
            field.append(char)
            i += 1
    if field or quoted or record:
        # The last record had no line end.
        record.append(Field("".join(field), quoted))
        records.append(record)
    return records


def quote_string(value: str) -> str:
    if value == "" or any(char in value for char in ',"\n\r'):
        return '"' + value.replace('"', '""') + '"'
    return value


def format_csv(header: Sequence[str], rows: Sequence[Sequence[str]]) -> str:
    """Join already-encoded fields; each line ends with LF."""
    lines = [",".join(header)]
    lines.extend(",".join(row) for row in rows)
    return "\n".join(lines) + "\n"
