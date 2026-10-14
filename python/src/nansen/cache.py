"""Loaded data kept in memory, as dev's nansen.cache.DataCache keeps it.

dev's cache is one per MATLAB session. Here each project has its own (``project.data_cache``), since
the core keeps no global state. An entry is the data read from one file. Each entry is stored with the
file's modification time and size, so a file changed on disk is read again. ``Project.save`` also drops
the entry of the file it writes. The cache keeps the least recently used entries out when it would go
over its budget (2 GiB unless set).

A caller may change what it is given, so values are shared with care. NumPy arrays (anything with
``nbytes`` and ``setflags``) are kept read-only and shared. Dicts, lists, tuples and sets are copied on
every return, with the arrays in them shared. Other objects are shared as they are.
"""

from __future__ import annotations

import sys
import threading
from collections import OrderedDict
from typing import Any, Callable, Dict, Hashable, Tuple

DEFAULT_MAX_BYTES = 2 * 2**30


def size_of(value: Any) -> int:
    """Bytes a value holds, roughly: exact for arrays, bytes and text, estimated for containers."""
    nbytes = getattr(value, "nbytes", None)
    if isinstance(nbytes, int):
        return nbytes
    if isinstance(value, (bytes, bytearray, str)):
        return len(value)
    if isinstance(value, dict):
        return sys.getsizeof(value) + sum(size_of(k) + size_of(v) for k, v in value.items())
    if isinstance(value, (list, tuple, set, frozenset)):
        return sys.getsizeof(value) + sum(size_of(v) for v in value)
    return sys.getsizeof(value)


def _shared(value: Any) -> Any:
    """What a caller is given: arrays read-only and shared, containers copied around them."""
    if hasattr(value, "setflags") and hasattr(value, "nbytes"):
        value.setflags(write=False)
        return value
    if isinstance(value, dict):
        return {k: _shared(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_shared(v) for v in value]
    if isinstance(value, tuple):
        return tuple(_shared(v) for v in value)
    if isinstance(value, set):
        return set(value)
    return value


class DataCache:
    """A memory-bounded, least-recently-used cache of loaded data."""

    def __init__(self, max_bytes: int = DEFAULT_MAX_BYTES):
        self.max_bytes = max_bytes
        self._entries: "OrderedDict[Hashable, Tuple[Hashable, Any, int]]" = OrderedDict()  # key -> (signature, value, bytes)
        self._bytes = 0
        self._counts = {"hits": 0, "misses": 0, "evictions": 0}
        self._lock = threading.Lock()  # tasks run in threads

    def get_or_load(self, key: Hashable, signature: Hashable, loader: Callable[[], Any]) -> Any:
        """The value kept for key if it was kept with this signature, else loader()'s value, now kept."""
        with self._lock:
            entry = self._entries.get(key)
            if entry is not None and entry[0] == signature:
                self._entries.move_to_end(key)
                self._counts["hits"] += 1
                return _shared(entry[1])
            self._counts["misses"] += 1
        value = loader()  # outside the lock: reading can be slow
        size = size_of(value)
        with self._lock:
            self._drop(key)
            if size <= self.max_bytes:
                while self._bytes + size > self.max_bytes:
                    oldest = next(iter(self._entries))
                    self._drop(oldest)
                    self._counts["evictions"] += 1
                self._entries[key] = (signature, value, size)
                self._bytes += size
        return _shared(value)

    def remove(self, key: Hashable) -> None:
        with self._lock:
            self._drop(key)

    def clear(self) -> None:
        with self._lock:
            self._entries.clear()
            self._bytes = 0

    def stats(self) -> Dict[str, int]:
        with self._lock:
            return {"entries": len(self._entries), "bytes": self._bytes, "maxBytes": self.max_bytes, **self._counts}

    def _drop(self, key: Hashable) -> None:
        entry = self._entries.pop(key, None)
        if entry is not None:
            self._bytes -= entry[2]
