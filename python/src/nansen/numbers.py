"""The canonical text form of a number in a table (docs/reference/table-format.md#writing-numbers)."""

from __future__ import annotations

import math


def format_number(value: float) -> str:
    value = float(value)
    if not math.isfinite(value):
        raise ValueError(f"cannot write {value!r} as a table number")
    for precision in range(1, 18):
        exponential = "%.*e" % (precision - 1, value)
        if float(exponential) == value:
            break
    exponent = int(exponential.split("e")[1])
    if -4 <= exponent < 17:
        return "%.*f" % (max(precision - 1 - exponent, 0), value)
    return exponential
