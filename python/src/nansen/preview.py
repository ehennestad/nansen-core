"""Previewing a method: running it on the first frames of an entity's stacks, writing nothing.

The method gets a PreviewProject in place of the project: stacks it opens (or loads, for image stacks) are cut
to their first frames, and what it saves or writes as a stack is kept in memory, where it reads it back from.
The preview reports what the method returned and, for each variable it saved, its size, its smallest, largest
and mean value, and an image of it where it is one (a frame-like payload, as data.frame gives).

With a column, the method runs on one ROI: each frames x N array it loads (a 2-D numeric array that is not an
image stack; a vector is one column) is cut to that column, and each output of one column gives its values, as
data.traces gives a column (the deconvolution explorer's live traces). MATLAB's nansen.internal.previewMethod
does the same.
"""

import tempfile
from pathlib import Path
from typing import Any, Dict, Optional

from .errors import NansenError
from .frames import _rounded, image_frame, signal_traces
from .methods import MethodContext, run_method
from .stacks import Stack, StackWriter, as_stack

FRAMES = 20   # frames a preview runs on, unless asked otherwise
MAX_POINTS = 2000   # values of an output's trace, at most, as data.traces
SMALLEST_IMAGE = 8   # an output is shown as an image when it is at least this many rows and columns


class PreviewProject:
    """A project as a method sees it in a preview. Anything it does not change is the project's own."""

    def __init__(self, project, frames: int, column: Optional[int] = None):
        self._project = project
        self.frames = int(frames)
        self.column = column
        self.saved: Dict[str, Any] = {}
        self._folder = tempfile.TemporaryDirectory(prefix="nansen-preview-")

    def __getattr__(self, name):
        return getattr(self._project, name)

    def open_stack(self, entity, name: str, frames=None) -> Stack:
        """The stack cut to its first frames; with frames (start, stop), those of that range (Project.open_stack)."""
        if name in self.saved:
            stack = as_stack(self.saved[name])
            if frames is not None:
                stack = stack.cut(*frames)
        else:
            whole = self._project.open_stack(entity, name, frames)
            count = min(self.frames, whole.shape[-1])
            if whole.ndim < 3 or count == whole.shape[-1]:
                stack = whole
            else:
                stack = Stack(whole.shape[:-1] + (count,), whole.dtype, lambda start, stop: whole.frames(start, min(stop, count)),
                              whole.metadata)
        stack.max_frames = self._project.stack_frame_limit
        return stack

    def load(self, entity, name: str, cached: bool = True) -> Any:
        if name in self.saved:
            return self.saved[name]
        value = self._project.load(entity, name, cached=cached)
        is_stack = self._project.data_variable(name).document.get("dataType") == "ImageStack"
        if is_stack and getattr(value, "ndim", 0) >= 3:
            value = value[..., :self.frames]
        elif self.column is not None and not is_stack:
            value = one_column(name, value, self.column)
        return value

    def save(self, entity, name: str, data: Any) -> Path:
        self.saved[name] = data
        return self.write_path(entity, name)

    def stack_writer(self, entity, name: str, shape: Any, dtype: Any) -> StackWriter:
        if not name:
            return StackWriter(shape, dtype)
        return StackWriter(shape, dtype, finish=lambda data: self.saved.__setitem__(name, data.copy()))

    def checkpoint(self, entity, name: str, shape: Any, dtype: Any, options: Any, source: Any, passes: int = 1, method=None):
        """No progress is kept: a preview starts from the first frame, and its stacks are kept in memory."""
        from .progress import Checkpoint
        return Checkpoint(None, name, shape, dtype, {}, passes, create=lambda: self.stack_writer(entity, name, shape, dtype))

    def update_values(self, entity, values: Dict[str, Any]) -> list:
        """The columns the values would be written to; nothing is written."""
        table = self._project.table(entity.entity_type)
        return [n for n in values if n in table.spec.column_names and n not in table.spec.key]

    def write_path(self, entity, name: str) -> Path:
        """Where a method that writes files itself (an external tool) writes: a folder deleted after the preview."""
        path = self._project.write_path(entity, name)
        return Path(self._folder.name) / "_".join(str(v) for v in entity.key.values()) / path.name

    def close(self) -> None:
        self._folder.cleanup()


def preview(project, method_id: str, entity, options: Optional[dict] = None, preset: Optional[str] = None,
            frames: int = FRAMES, column: Optional[int] = None, max_points: int = MAX_POINTS) -> Dict[str, Any]:
    """Run a method on one entity with its stacks cut to their first frames, saving nothing; with a column, on that
    column of the signals it loads, giving the values of its outputs of one column (see the module's docstring)."""
    if int(frames) < 1:
        raise NansenError("invalid-params", "frames is 1 or more")
    if column is not None and (not isinstance(column, int) or isinstance(column, bool) or column < 0):
        raise NansenError("invalid-params", "column is a 0-based column number")
    method = project.method(method_id)
    values = project.preset(method_id, preset) if preset else {}
    if options:
        values = dict(values, **options)
    sandbox = PreviewProject(project, frames, column)
    context = MethodContext(project=sandbox, method=method)
    try:
        results = run_method(method, [entity], values, context)
        outputs = [describe(name, value, max_points if column is not None else None) for name, value in sandbox.saved.items()]
    finally:
        sandbox.close()
    from .tasks import _json_result
    return {"frames": int(frames), "results": _json_result(results), "outputs": outputs, "log": list(context.lines)}


def one_column(name: str, value: Any, column: int) -> Any:
    """A frames x N numeric array cut to one column (frames x 1); a vector is one column, and other values are as
    they are. invalid-params for a column the array does not have."""
    import numpy as np

    if not isinstance(value, np.ndarray) or value.dtype.kind not in "biuf" or value.ndim not in (1, 2) or value.size < 2:
        return value
    count = value.shape[1] if value.ndim == 2 else 1
    if column >= count:
        raise NansenError("invalid-params", f"{name} has {count} columns; column {column} is not one")
    return value[:, column:column + 1] if value.ndim == 2 else value


def describe(name: str, value: Any, max_points: Optional[int] = None) -> Dict[str, Any]:
    """What a preview tells of a saved value: its size and range, and an image of it where it is one; with
    max_points, the values of an array of one column (frames x 1, or a vector), as data.traces gives them."""
    import numpy as np

    if isinstance(value, dict):
        out: Dict[str, Any] = {"name": name, "kind": "document"}
        if isinstance(value.get("rois"), list):
            out["rois"] = len(value["rois"])
        return out
    array = np.asarray(value)
    if array.dtype.kind not in "biuf" or array.size == 0:
        return {"name": name, "kind": "value", "size": list(array.shape)}
    finite = array[np.isfinite(array)] if array.dtype.kind == "f" else array
    out = {"name": name, "kind": "array", "size": list(array.shape),
           "min": _rounded(finite.min()) if finite.size else None, "max": _rounded(finite.max()) if finite.size else None,
           "mean": _rounded(finite.astype(np.float64).mean()) if finite.size else None}
    if array.ndim >= 2 and array.shape[0] >= SMALLEST_IMAGE and array.shape[1] >= SMALLEST_IMAGE:
        image = image_frame(array, projection="mean") if array.ndim >= 3 else image_frame(array)
        out["image"] = {k: image[k] for k in ("height", "width", "low", "high", "pixels")}
    if max_points is not None and array.ndim in (1, 2) and array.size >= 2 and array.size == array.shape[0]:
        traces = signal_traces({name: array}, [0], 0, None, max_points)
        out["trace"] = {"frames": traces["frames"], "step": traces["step"], "values": traces["traces"][0]["columns"][0]["values"]}
    return out
