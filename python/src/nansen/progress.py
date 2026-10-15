"""Progress of a stack output while it is written, so a run that stopped goes on where it stopped.

As dev's ImageStackProcessor (checkIfPartIsFinished): a method that writes a stack a chunk of frames at a time asks
the project for a Checkpoint of its output (``Project.checkpoint``). After each chunk it saves how many frames are
done, with what it needs to go on from there (its state: arrays, kept exactly as the base64 of their bytes), in
``<output file>.progress.json`` beside the output file: a nansen.progress document. It also holds the inputs the run
started from (the options, the input stack's size and type, the method's version). Run again with the same inputs,
the method goes on from the first frame not done, writing into the output file it had begun (an adapter with
``reopen``: npy, ophys.binary_stack), and the result is the one a run that never stopped gives, byte for byte.
With other inputs, or an output that cannot be reopened, it starts over. The file is removed once the output is
complete, so a run after that starts from the first frame.

A method that goes through the frames more than once (motion correction's iterations) writes its output in the
last pass; the document says which pass it is in (from 1) and how many frames of that pass are done.
MATLAB's nansen.Checkpoint is the same, and reads and writes the same files.
"""

from __future__ import annotations

import base64
import datetime as dt
import json
import os
import threading
from pathlib import Path
from typing import Any, Callable, Dict, Optional

from .documents import check_document, read_document
from .errors import NansenError
from .schemas import current_version

SUFFIX = ".progress.json"


def progress_path(path: Any) -> Path:
    """The progress document of an output file: <file>.progress.json beside it."""
    return Path(str(path) + SUFFIX)


def encode(array: Any) -> dict:
    """An array as {dtype, shape, data}: data is the base64 of its values, little-endian, in column-major order (as
    MATLAB keeps an array), so it is read back exactly in either language."""
    np = _numpy()
    array = np.asarray(array)
    little = array.astype(array.dtype.newbyteorder("<"), copy=False)
    return {"dtype": array.dtype.name, "shape": [int(n) for n in array.shape],
            "data": base64.b64encode(little.tobytes(order="F")).decode("ascii")}


def decode(value: dict) -> Any:
    np = _numpy()
    dtype = np.dtype(value["dtype"]).newbyteorder("<")
    data = np.frombuffer(base64.b64decode(value["data"]), dtype=dtype)
    return data.reshape([int(n) for n in value["shape"]], order="F").astype(dtype.newbyteorder("="))


def plain(value: Any) -> Any:
    """The value as JSON gives it back: what a document's inputs are compared as."""
    return json.loads(json.dumps(value, default=str))


class Checkpoint:
    """The progress of one stack output (see the module).

    ``pass_number`` (from 1) and ``frames_done`` are where the method goes on from, with ``state`` (name -> array)
    as it was saved there; a run that starts from the beginning has pass 1, no frames done and no state.
    ``resumed`` says whether it goes on from a stopped run. ``writer()`` gives the output's writer: the reopened
    output when the run goes on in the pass that writes it, else a new one. ``save`` after each chunk, ``finish``
    once the output is complete.
    """

    def __init__(self, output_path: Optional[Path], variable: str, shape: Any, dtype: Any, inputs: Any,
                 passes: int = 1, method: Optional[dict] = None, create: Optional[Callable[[], Any]] = None,
                 reopen: Optional[Callable[[], Any]] = None):
        np = _numpy()
        self.output_path = Path(output_path) if output_path else None
        self.path = progress_path(self.output_path) if self.output_path else None
        self.variable = variable
        self.shape = tuple(int(n) for n in shape)
        self.dtype = np.dtype(dtype)
        self.inputs = plain(inputs)
        self.passes = int(passes)
        self.method = dict(method) if method else None
        self._create = create
        self._reopen = reopen
        self._writer = None
        self.pass_number, self.frames_done, self.state, self.resumed = 1, 0, {}, False
        self._load()

    @property
    def frames(self) -> int:
        return self.shape[-1]

    def first_frame(self, pass_number: int) -> int:
        """Where the pass starts: after the frames done when the run goes on in it, else at 0."""
        return self.frames_done if pass_number == self.pass_number else 0

    def _load(self) -> None:
        if self.path is None or not self.path.is_file():
            return
        try:
            document = read_document(self.path, "nansen.progress")
            state = {name: decode(value) for name, value in document.get("state", {}).items()}
        except (NansenError, ValueError, KeyError, TypeError, OSError):
            document = None
        if document is None or not self._matches(document):
            self.finish()   # another run's, or unreadable: start over
            return
        pass_number, done = int(document["pass"]), int(document["framesDone"])
        writer = None
        if pass_number == self.passes and done > 0:   # the output was being written: go on writing it
            writer = self._reopened(done)
            if writer is None:
                self.finish()   # it cannot be: start over
                return
        self.pass_number, self.frames_done, self.state, self.resumed, self._writer = pass_number, done, state, True, writer

    def _reopened(self, done: int) -> Any:
        """The output's writer over the file begun, when its adapter can reopen it and it holds the frames done."""
        if self._reopen is None or not self.output_path.is_file():
            return None
        try:
            writer = self._reopen()
        except (NansenError, ValueError, OSError):
            return None
        if writer is not None and getattr(writer, "frames_on_disk", 0) < done:
            writer.close()   # the file lacks frames it was said to have (written by a process that died)
            return None
        return writer

    def _matches(self, document: dict) -> bool:
        output = document.get("output", {})
        return (output.get("shape") == list(self.shape) and output.get("dtype") == self.dtype.name
                and document.get("passes") == self.passes and 1 <= document.get("pass", 0) <= self.passes
                and 0 <= document.get("framesDone", -1) <= self.frames and document.get("inputs") == self.inputs
                and (self.method is None or document.get("method") == self.method))

    def writer(self) -> Any:
        """The output's writer: the one reopened to go on with, or a new one (which starts the file afresh)."""
        if self._writer is None:
            from .stacks import StackWriter
            self._writer = self._create() if self._create is not None else StackWriter(self.shape, self.dtype)
        return self._writer

    def save(self, pass_number: int, frames_done: int, **state: Any) -> None:
        """That frames 0..frames_done-1 of the pass are done (and written, in the pass that writes the output), and
        what the method needs to go on from there. In the last pass of an output that cannot be reopened, nothing is
        saved: that pass starts over."""
        if self.path is None or (pass_number == self.passes and self._reopen is None):
            return
        if pass_number == self.passes and self._writer is not None and hasattr(self._writer, "flush"):
            self._writer.flush()   # the frames are in the file before the document says so
        document = {"schemaType": "nansen.progress", "schemaVersion": current_version("nansen.progress")}
        if self.method:
            document["method"] = self.method
        document.update({
            "output": {"variable": self.variable, "shape": list(self.shape), "dtype": self.dtype.name},
            "inputs": self.inputs, "pass": int(pass_number), "passes": self.passes, "framesDone": int(frames_done),
            "state": {name: encode(value) for name, value in state.items()},
            "updatedAt": dt.datetime.now().isoformat(timespec="seconds")})
        check_document(document, "nansen.progress")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_name(f"{self.path.name}.{os.getpid()}.{threading.get_ident()}.tmp")
        with open(temporary, "w", encoding="utf-8", newline="\n") as f:
            json.dump(document, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.replace(temporary, self.path)

    def finish(self) -> None:
        """The output is complete (or is started afresh): the progress document goes."""
        if self.path is not None and self.path.is_file():
            self.path.unlink()


def _numpy():
    try:
        import numpy
    except ImportError:
        raise NansenError("adapter-unavailable", 'image stacks need NumPy: pip install "nansen-core[npy]"') from None
    return numpy
