"""The one exception type, carrying a code from docs/conventions.md#error-codes."""

from __future__ import annotations


class NansenError(Exception):
    """An error with a stable code that both implementations agree on."""

    def __init__(self, code: str, message: str):
        super().__init__(f"[{code}] {message}")
        self.code = code
        self.message = message
