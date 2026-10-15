"""Image stacks read a few frames at a time, and written the same way.

A stack is height x width (x channels (x planes)) x frames, frames last as everywhere in NANSEN. A file
adapter that can, gives one with ``open(paths)``: several files are one recording, joined along the frames
in natural order (``part2`` before ``part10``), and only the frames asked for are read. ``Project.open``
returns one for any variable (the whole value, for an adapter without ``open``), and ``Project.stack_writer``
writes one chunk of frames at a time. MATLAB's nansen.Stack and nansen.StackWriter do the same.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any, Callable, List, Optional, Sequence, Tuple

from .errors import NansenError


def natural_key(path: Any) -> str:
    """Sort key of a path: its runs of digits compared as numbers (padded with zeros to 20 places), the rest as
    text, as MATLAB's nansen.internal.naturalOrder."""
    return re.sub(r"\d+", lambda match: match.group().zfill(20), str(path))


def natural_order(paths: Sequence[Any]) -> list:
    return sorted(paths, key=natural_key)


class Stack:
    """Frames read on demand: ``frames(start, stop)`` gives [..., start:stop] as an array.

    ``stack[:, :, a:b]`` (any index whose last part picks frames) reads those frames only; ``np.asarray``
    reads them all. ``max_frames``, when set, is the most one read may ask for, reading them all included:
    a test sets it to show that a method reads a recording in chunks and never whole.

    ``metadata`` is what the files tell about the recording, each key only when they give it: ``frameRate``
    (frames per second; volumes per second for a stack with planes), ``pixelSize`` ([x, y] µm per pixel) and
    ``zStep`` (µm between planes).
    """

    max_frames: Optional[int] = None

    def __init__(self, shape: Tuple[int, ...], dtype: Any, read: Callable[[int, int], Any], metadata: Optional[dict] = None):
        self.shape = tuple(int(n) for n in shape)
        self.dtype = _numpy().dtype(dtype)
        self._read = read
        self.metadata = dict(metadata or {})

    @property
    def ndim(self) -> int:
        return len(self.shape)

    @property
    def size(self) -> int:
        size = 1
        for n in self.shape:
            size *= n
        return size

    @property
    def frame_count(self) -> int:
        return self.shape[-1]

    def frames(self, start: int, stop: int):
        """Frames start..stop-1 (cut to the stack), as an array of shape [..., stop - start]."""
        start, stop = max(0, int(start)), min(self.frame_count, int(stop))
        np = _numpy()
        if stop <= start:
            return np.zeros(self.shape[:-1] + (0,), dtype=self.dtype)
        if self.max_frames is not None and stop - start > self.max_frames:
            raise NansenError("invalid-params", f"{stop - start} frames asked for at once; this stack gives at most {self.max_frames}")
        data = np.asarray(self._read(start, stop))
        if data.shape != self.shape[:-1] + (stop - start,):
            raise NansenError("invalid-data", f"read {data.shape} for frames {start}..{stop - 1} of a {self.shape} stack")
        return data

    def __getitem__(self, index):
        if not isinstance(index, tuple):
            index = (index,)
        if Ellipsis in index:
            at = index.index(Ellipsis)
            index = index[:at] + (slice(None),) * (self.ndim - len(index) + 1) + index[at + 1:]
        index = index + (slice(None),) * (self.ndim - len(index))
        if len(index) != self.ndim:
            raise IndexError(f"{len(index)} indices for a {self.ndim}-D stack")
        last = index[-1]
        if isinstance(last, slice):
            start, stop, step = last.indices(self.frame_count)
            if step == 1:
                data = self.frames(start, stop)
            else:
                picked = range(start, stop, step)
                data = _numpy().stack([self.frames(t, t + 1)[..., 0] for t in picked], axis=-1) if len(picked) else self.frames(0, 0)
            return data[index[:-1] + (slice(None),)]
        t = int(last)
        if t < 0:
            t += self.frame_count
        if not 0 <= t < self.frame_count:
            raise IndexError(f"frame {last} of {self.frame_count}")
        return self.frames(t, t + 1)[index[:-1] + (0,)]

    def select(self, *index) -> "Stack":
        """The stack with the axes before the frames indexed (an int drops its axis): ``select(slice(None),
        slice(None), channel)`` is one channel of a height x width x channels x frames stack, still lazy."""
        np = _numpy()
        index = tuple(index) + (slice(None),)
        shape = np.empty(self.shape[:-1] + (0,), dtype=self.dtype)[index].shape[:-1] + (self.frame_count,)
        return Stack(shape, self.dtype, lambda start, stop: self.frames(start, stop)[index], self.metadata)

    def __array__(self, dtype=None, copy=None):
        data = self.frames(0, self.frame_count)   # with max_frames below the frame count, this is refused
        return data if dtype is None else data.astype(dtype)

    def __len__(self) -> int:
        return self.shape[0]

    def __repr__(self) -> str:
        return f"<Stack {'x'.join(map(str, self.shape))} {self.dtype}>"


def from_array(data: Any) -> Stack:
    """A stack over an array (or a memory map) already at hand."""
    np = _numpy()
    array = data if hasattr(data, "shape") and hasattr(data, "dtype") else np.asarray(data)
    if array.ndim == 0:
        raise NansenError("invalid-data", "a single value is not a stack")
    if array.ndim == 1:
        array = array[:, None]
    return Stack(array.shape, array.dtype, lambda start, stop: np.asarray(array[..., start:stop]))


def as_stack(value: Any) -> Stack:
    return value if isinstance(value, Stack) else from_array(value)


def join(stacks: Sequence[Any]) -> Stack:
    """Stacks one after the other along the frames; they must agree in everything else. The first one's metadata is kept."""
    parts = [as_stack(s) for s in stacks]
    if not parts:
        raise NansenError("invalid-data", "no stacks to join")
    if len(parts) == 1:
        return parts[0]
    first = parts[0]
    for part in parts[1:]:
        if part.shape[:-1] != first.shape[:-1]:
            raise NansenError("invalid-data", f"the files of a recording differ in frame size: {first.shape[:-1]} and {part.shape[:-1]}")
        if part.dtype != first.dtype:
            raise NansenError("invalid-data", f"the files of a recording differ in type: {first.dtype} and {part.dtype}")
    offsets = [0]
    for part in parts:
        offsets.append(offsets[-1] + part.frame_count)
    np = _numpy()

    def read(start, stop):
        pieces = []
        for part, offset in zip(parts, offsets):
            low, high = max(start, offset), min(stop, offset + part.frame_count)
            if low < high:
                pieces.append(part.frames(low - offset, high - offset))
        return np.concatenate(pieces, axis=-1)

    return Stack(first.shape[:-1] + (offsets[-1],), first.dtype, read, first.metadata)


def pages(path_list: Sequence[Path], page_info: Callable[[Path], Tuple[int, Tuple[int, ...], Any]],
          read_pages: Callable[[Path, int, int], Any], frame_shape: Tuple[int, ...], dtype: Any) -> Tuple[int, Callable[[int, int], Any]]:
    """For page-based files (TIFF): the pages of several files as one sequence, and a reader of pages a..b-1.
    page_info gives a file's page count and its pages' shape and type, which must be the same in every file."""
    np = _numpy()
    counts = []
    for path in path_list:
        count, shape, kind = page_info(path)
        if tuple(shape) != tuple(frame_shape) or np.dtype(kind) != np.dtype(dtype):
            raise NansenError("invalid-data", f"the files of a recording differ: {path_list[0]} has {tuple(frame_shape)} "
                                              f"{np.dtype(dtype)} pages, {path} {tuple(shape)} {np.dtype(kind)}")
        counts.append(count)
    offsets = [0]
    for n in counts:
        offsets.append(offsets[-1] + n)

    def read(start, stop):
        pieces = []
        for path, offset, n in zip(path_list, offsets, counts):
            low, high = max(start, offset), min(stop, offset + n)
            if low < high:
                pieces.append(np.asarray(read_pages(path, low - offset, high - offset)).reshape((high - low,) + tuple(frame_shape)))
        return np.concatenate(pieces, axis=0) if pieces else np.zeros((0,) + tuple(frame_shape), dtype=dtype)

    return offsets[-1], read


class StackWriter:
    """Writes a stack of a known shape a chunk of frames at a time; ``close`` (or leaving a ``with``) finishes it.

    ``target`` is an array-like the chunks are put in (a memory-mapped .npy file), and ``finish`` is called
    with it at the end (to write a file from an array in memory, for an adapter that cannot write in parts).
    """

    def __init__(self, shape: Tuple[int, ...], dtype: Any, target: Any = None, finish: Callable[[Any], None] = None):
        np = _numpy()
        self.shape = tuple(int(n) for n in shape)
        self.dtype = np.dtype(dtype)
        self.target = target if target is not None else (np.zeros(self.shape, dtype=self.dtype) if finish is not None else None)
        self._finish = finish
        self.written = 0
        self.closed = False

    def write(self, start: int, chunk: Any) -> None:
        if self.target is None:
            return  # a writer to no variable
        np = _numpy()
        chunk = np.asarray(chunk)
        if chunk.ndim == len(self.shape) - 1:
            chunk = chunk[..., None]
        stop = int(start) + chunk.shape[-1]
        if chunk.shape[:-1] != self.shape[:-1] or not 0 <= start <= stop <= self.shape[-1]:
            raise NansenError("invalid-params", f"a {chunk.shape} chunk at frame {start} does not fit a {self.shape} stack")
        self.target[..., int(start):stop] = chunk.astype(self.dtype, copy=False)
        self.written += chunk.shape[-1]

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        if self.target is not None and hasattr(self.target, "flush"):
            self.target.flush()
        if self._finish is not None and self.target is not None:
            self._finish(self.target)
        self.target = None

    def __enter__(self) -> "StackWriter":
        return self

    def __exit__(self, kind, value, traceback) -> None:
        if kind is None:
            self.close()
        else:
            self.closed = True
            self.target = None


def _numpy():
    try:
        import numpy
    except ImportError:
        raise NansenError("adapter-unavailable", 'image stacks need NumPy: pip install "nansen-core[npy]"') from None
    return numpy
