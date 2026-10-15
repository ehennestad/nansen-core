"""Frames of image data for the dashboard's viewer: one frame or a projection, scaled to 8 bits.

MATLAB's nansen.internal.imageFrame computes the same bytes from the same array, so both backends draw
the same picture.
"""

from __future__ import annotations

import base64
import math
from typing import Any, Dict, List, Optional

from .errors import NansenError


def image_frame(data: Any, frame: int = 0, channel: int = 0, projection: Optional[str] = None,
                limits: Optional[List[float]] = None, plane: int = 0, filter: Optional[str] = None,
                bin: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """A frame of a height x width (x frames), height x width x channels x frames or height x width x channels x
    planes x frames array or stack (nansen.stacks.Stack, read a chunk of frames at a time), as 8-bit values.

    Values from low to high are scaled to 0..255 as floor((v - low) / (high - low) * 255 + 0.5), cut at
    both ends; NaN is 0. low and high are the limits given, or else the smallest and largest finite value
    of the frame. pixels is base64 of the bytes, row after row.
    """
    try:
        import numpy as np
    except ImportError:
        raise NansenError("adapter-unavailable", 'viewing arrays needs NumPy: pip install "nansen-core[npy]"') from None
    stack, channels, planes = _pick(data, channel, plane)
    height, width, frames = stack.shape
    if projection == "mean":
        image, frame = _mean(stack), None
    elif projection == "max":
        image = None
        for start in range(0, frames, CHUNK):
            peak = stack.frames(start, start + CHUNK).max(axis=2)
            image = peak if image is None else np.maximum(image, peak)
        image, frame = image.astype(np.float64), None
    elif projection == "min":
        image = None
        for start in range(0, frames, CHUNK):
            low_ = stack.frames(start, start + CHUNK).min(axis=2)
            image = low_ if image is None else np.minimum(image, low_)
        image, frame = image.astype(np.float64), None
    elif projection == "peakTime":   # the frame of each pixel's peak (the first, on a tie); its peak is the brightness
        peak = when = None
        for start in range(0, frames, CHUNK):
            chunk = stack.frames(start, start + CHUNK).astype(np.float64)
            here, at = chunk.max(axis=2), chunk.argmax(axis=2) + start
            if peak is None:
                peak, when = here, at
            else:
                later = here > peak
                peak, when = np.where(later, here, peak), np.where(later, at, when)
        image, frame = when.astype(np.float64), None
        if limits is None:
            limits = [0.0, float(max(frames - 1, 1))]
    elif projection == "std":
        image, frame = _std(stack), None
    elif projection == "correlation":
        image, frame = local_correlation(stack), None
    elif projection == "globalCorrelation":
        image, frame = global_correlation(stack), None
    elif projection is None and bin:   # imviewer's binning: the mean or max of the frames around the frame
        if not 0 <= frame < frames:
            raise NansenError("invalid-params", f"there are {frames} frames; frame {frame} is not one")
        first, stop = moving_window(frame, int(bin["size"]), frames)
        chunk = stack.frames(first, stop).astype(np.float64)
        image = chunk.sum(axis=2) / (stop - first) if bin.get("method", "mean") == "mean" else chunk.max(axis=2)
        binned = [first, stop]
    elif projection is None:
        if not 0 <= frame < frames:
            raise NansenError("invalid-params", f"there are {frames} frames; frame {frame} is not one")
        image = stack.frames(frame, frame + 1)[:, :, 0].astype(np.float64)
    else:
        raise NansenError("invalid-params", f"projection is mean, max, min, std, correlation, globalCorrelation or peakTime, not {projection!r}")
    if filter:
        image = filter_image(image, filter)
    if limits is not None:
        low, high = float(limits[0]), float(limits[1])
    else:
        finite = image[np.isfinite(image)]
        low, high = (float(finite.min()), float(finite.max())) if finite.size else (0.0, 0.0)
    scaled = np.zeros((height, width), dtype=np.uint8)
    if high > low:
        with np.errstate(invalid="ignore"):
            values = np.floor((image - low) / (high - low) * 255 + 0.5)
        scaled = np.clip(np.nan_to_num(values, nan=0.0), 0, 255).astype(np.uint8)
    result = {"height": height, "width": width, "frames": frames, "channels": channels, "planes": planes, "frame": frame,
              "low": _number(low), "high": _number(high),
              "pixels": base64.b64encode(scaled.tobytes()).decode("ascii")}
    if projection is None and bin:
        result["binned"] = binned
    if projection == "peakTime":   # the peaks, as 8-bit values from the smallest to the largest
        finite = peak[np.isfinite(peak)]
        bottom, top = (float(finite.min()), float(finite.max())) if finite.size else (0.0, 0.0)
        bright = np.zeros((height, width), dtype=np.uint8)
        if top > bottom:
            bright = np.clip(np.nan_to_num(np.floor((peak - bottom) / (top - bottom) * 255 + 0.5), nan=0.0), 0, 255).astype(np.uint8)
        result["brightness"] = base64.b64encode(bright.tobytes()).decode("ascii")
    return result


CHUNK = 100   # frames read at a time for a projection


def moving_window(frame: int, size: int, frames: int):
    """The frames binned around frame (0-based; [first, stop)), as dev's getMovingWindowFrameIndices: size frames from
    the first or to the last near the ends, else frame - size // 2 to frame + size // 2 (so an even size takes one more)."""
    number, half = frame + 1, -(-size // 2)
    if number <= half:
        return 0, min(frames, size)
    if frames - number < half:
        return max(frames - size + 1, 1) - 1, frames
    return number - size // 2 - 1, number + size // 2


def filter_image(image: Any, name: str) -> Any:
    """imviewer's 2-D filters of an image: smooth, a binomial blur ([1 4 6 4 1] / 16 along rows, then columns); gradient,
    the magnitude of the central differences ((next - previous) / 2). Edges repeat the last pixel. Exact sums in a fixed
    order, so MATLAB's nansen.internal.filterImage gives the same values."""
    import numpy as np
    image = np.asarray(image, dtype=np.float64)
    if name == "smooth":
        for axis in (0, 1):
            padded = np.pad(image, [(2, 2) if a == axis else (0, 0) for a in (0, 1)], mode="edge")
            take = lambda k: np.take(padded, range(k, k + image.shape[axis]), axis=axis)
            image = (take(0) + 4 * take(1) + 6 * take(2) + 4 * take(3) + take(4)) / 16
        return image
    if name == "gradient":
        padded = np.pad(image, 1, mode="edge")
        dy = (padded[2:, 1:-1] - padded[:-2, 1:-1]) / 2
        dx = (padded[1:-1, 2:] - padded[1:-1, :-2]) / 2
        return np.sqrt(dy * dy + dx * dx)
    raise NansenError("invalid-params", f"filter is smooth or gradient, not {name!r}")


def _pick(data: Any, channel: int = 0, plane: int = 0):
    """(height x width x frames stack, channels, planes): the channel and plane (0-based) of an image or stack."""
    import numpy as np
    from .stacks import Stack, from_array
    stack = data if isinstance(data, Stack) else None
    if stack is None:
        array = np.asarray(data)
        if array.dtype.kind not in "biuf" or not 2 <= array.ndim <= 5:
            raise NansenError("invalid-data", "the data is not an image or a stack of images")
        stack = from_array(array[:, :, None] if array.ndim == 2 else array)
    elif stack.ndim == 2:
        stack.max_frames = None   # an image's columns are not frames
        stack = from_array(np.asarray(stack)[:, :, None])
    if stack.dtype.kind not in "biuf" or not 3 <= stack.ndim <= 5:
        raise NansenError("invalid-data", "the data is not an image or a stack of images")
    channels = stack.shape[2] if stack.ndim >= 4 else 1
    planes = stack.shape[3] if stack.ndim == 5 else 1
    if stack.ndim == 5:
        if not 0 <= plane < stack.shape[3]:
            raise NansenError("invalid-params", f"there are {stack.shape[3]} planes; plane {plane} is not one")
        stack = stack.select(slice(None), slice(None), slice(None), plane)
    elif plane != 0:
        raise NansenError("invalid-params", f"there is 1 plane; plane {plane} is not one")
    if stack.ndim == 4:
        if not 0 <= channel < stack.shape[2]:
            raise NansenError("invalid-params", f"there are {stack.shape[2]} channels; channel {channel} is not one")
        stack = stack.select(slice(None), slice(None), channel)
    return stack, channels, planes


def _std(stack) -> Any:
    """Each pixel's standard deviation over the frames (the root mean square of its deviations from its mean), a
    chunk at a time, in two passes."""
    import numpy as np
    height, width, frames = stack.shape
    mean = _mean(stack)[:, :, None]
    squares = np.zeros((height, width))
    for start in range(0, frames, CHUNK):
        squares += ((stack.frames(start, start + CHUNK).astype(np.float64) - mean) ** 2).sum(axis=2)
    return np.sqrt(squares / frames)


def local_correlation(stack) -> Any:
    """Each pixel's average Pearson correlation over time with its in-frame 8 neighbours, read a chunk of frames at
    a time in three passes: each pixel's mean, its spread (the root mean square of its deviations), and the sums over
    time of its normalised deviations times each neighbour's. A pixel that does not change correlates 0."""
    import numpy as np
    from .stacks import as_stack
    stack = as_stack(stack)
    height, width, frames = stack.shape
    chunks = lambda: (stack.frames(start, start + CHUNK).astype(np.float64) for start in range(0, frames, CHUNK))
    mean = _mean(stack)[:, :, None]
    squares = np.zeros((height, width))
    for chunk in chunks():
        squares += ((chunk - mean) ** 2).sum(axis=2)
    spread = np.sqrt(squares / frames)[:, :, None]
    offsets = [(dy, dx) for dy in (-1, 0, 1) for dx in (-1, 0, 1) if dy or dx]
    span = lambda d, size: slice(max(0, d), min(size, size + d))
    products = {offset: np.zeros((height, width)) for offset in offsets}
    for chunk in chunks():
        data = np.divide(chunk - mean, spread, out=np.zeros_like(chunk), where=spread > 0)
        for dy, dx in offsets:
            here, there = (span(-dy, height), span(-dx, width)), (span(dy, height), span(dx, width))
            products[(dy, dx)][here] += (data[here] * data[there]).sum(axis=2)
    total, count = np.zeros((height, width)), np.zeros((height, width))
    for dy, dx in offsets:
        here = (span(-dy, height), span(-dx, width))
        total[here] += products[(dy, dx)][here] / frames
        count[here] += 1
    return np.divide(total, count, out=np.zeros_like(total), where=count > 0)


def global_correlation(stack) -> Any:
    """Each pixel's Pearson correlation over time with the mean of the whole frame (dev's globalCorrelation projection),
    read a chunk of frames at a time in two passes: each pixel's mean and the frames' means, then the sums over time of
    its deviations squared and times the frame mean's deviations. A pixel that does not change correlates 0."""
    import numpy as np
    from .stacks import as_stack
    stack = as_stack(stack)
    height, width, frames = stack.shape
    chunks = lambda: ((start, stack.frames(start, start + CHUNK).astype(np.float64)) for start in range(0, frames, CHUNK))
    mean = _mean(stack)[:, :, None]
    signal = np.zeros(frames)
    for start, chunk in chunks():
        signal[start:start + chunk.shape[2]] = chunk.sum(axis=(0, 1)) / (height * width)
    signal = signal - signal.sum() / frames
    squares, products = np.zeros((height, width)), np.zeros((height, width))
    for start, chunk in chunks():
        deviation = chunk - mean
        squares += (deviation ** 2).sum(axis=2)
        products += (deviation * signal[None, None, start:start + chunk.shape[2]]).sum(axis=2)
    spread = np.sqrt(squares * (signal ** 2).sum())
    return np.divide(products, spread, out=np.zeros_like(products), where=spread > 0)


def _mean(stack) -> Any:
    """The mean over the frames of a height x width x frames stack, a chunk at a time."""
    import numpy as np
    height, width, frames = stack.shape
    total = np.zeros((height, width))
    for start in range(0, frames, CHUNK):
        total += stack.frames(start, start + CHUNK).astype(np.float64).sum(axis=2)
    return total / frames


def roi_outlines(value: Any) -> List[Dict[str, Any]]:
    """The ROIs of an ROI file ({rois: [{id?, pixels: [[row, column], ...]}]}, 0-based) as the viewer draws them."""
    if not isinstance(value, dict) or not isinstance(value.get("rois", []), list):
        raise NansenError("invalid-data", "the ROIs are not a JSON object with a list of rois")
    out = []
    for number, roi in enumerate(value.get("rois", []), start=1):
        pixels = roi.get("pixels", []) if isinstance(roi, dict) else []
        if pixels and not isinstance(pixels[0], list):
            pixels = [pixels]
        outline = {"id": roi.get("id", number), "pixels": [[int(p[0]), int(p[1])] for p in pixels],
                   "classification": roi.get("classification")}
        for name in ("uid", "cellType", "links"):   # its identity, roimanager's cell type and links between ROIs, when there are
            if isinstance(roi, dict) and roi.get(name):
                outline[name] = roi[name]
        out.append(outline)
    return out


EXTRAS = ("uid", "cellType", "tags", "links")   # what an ROI may carry besides its pixels and classification


CLASSES = ("accepted", "rejected", "unresolved")


def update_rois(value: Any, classify: Optional[list] = None, remove: Optional[list] = None,
                add: Optional[list] = None, move: Optional[list] = None, merge: Optional[list] = None,
                pixels: Optional[list] = None, restore: Optional[list] = None, cell_type: Optional[list] = None,
                link: Optional[list] = None) -> Any:
    """The ROI file with ROIs restored, classified, reshaped, moved, merged, removed and added, in that order;
    returns (document, ids of the added ROIs).

    restore is [{id, pixels, classification?}]: the ROIs, all of them, as they were (the viewer's undo); their ids
    are kept. classify is [{id, classification}] with classification accepted, rejected or null (none). pixels is
    [{id, pixels}]: the ROI's pixels from now on (the viewer's grow and shrink), id and classification kept. move is
    [{id, rows, columns}]: the ROI's pixels shifted by whole pixels, those leaving the image left out. merge is
    [[id, id, ...]]: the first ROI of each group takes the pixels of all of them (and keeps its id and
    classification), the others are removed. An added ROI is {pixels}; it gets the next free id. A changed or
    added ROI gets its area and center again, and pixels outside imageSize are left out.

    cell_type is [{id, cellType}] (roimanager's excitatory, inhibitory or axon; any short text, or null for none). link
    is [[id, id, ...]]: the first ROI is linked with each of the others (links go both ways, roimanager's connected
    ROIs). A restored ROI has the uid, cell type, tags and links given (null for none), or else those its id had. A removed or
    merged-away ROI is taken out of the others' links. Cell types and links are set after the classifications.
    """
    roi_outlines(value)  # checks the shape
    rois = [dict(roi, id=roi.get("id", number)) for number, roi in enumerate(value.get("rois", []), start=1)]
    by_id = {roi["id"]: roi for roi in rois}
    size = value.get("imageSize")
    inside = lambda p: size is None or (0 <= p[0] < size[0] and 0 <= p[1] < size[1])

    def find(roi_id):
        if roi_id not in by_id:
            raise NansenError("invalid-params", f"there is no ROI {roi_id!r}")
        return by_id[roi_id]

    def measure(roi, pixels):
        pixels = sorted(set(pixels))
        if not pixels:
            raise NansenError("invalid-params", f"ROI {roi['id']} would have no pixels inside the image")
        roi.update(area=len(pixels), center=[_round2(sum(p[0] for p in pixels) / len(pixels)), _round2(sum(p[1] for p in pixels) / len(pixels))],
                   pixels=[list(p) for p in pixels])

    def pixels_of(roi):
        return [(int(p[0]), int(p[1])) for p in roi_outlines({"rois": [roi]})[0]["pixels"]]

    if restore is not None:
        rois = []
        for item in restore:
            roi_id = item.get("id")
            if not isinstance(roi_id, int) or isinstance(roi_id, bool) or roi_id < 1 or any(r["id"] == roi_id for r in rois):
                raise NansenError("invalid-params", "restored ROIs have different whole-number ids from 1")
            roi = {"id": roi_id}
            measure(roi, [(int(p[0]), int(p[1])) for p in item.get("pixels", []) if inside(p)])
            if item.get("classification") in CLASSES:
                roi["classification"] = item["classification"]
            before = by_id.get(roi_id, {})
            for name in EXTRAS:   # given (null for none), or else as the ROI of that id has it
                extra = item[name] if name in item else before.get(name)
                if extra:
                    roi[name] = extra
            rois.append(roi)
        by_id = {roi["id"]: roi for roi in rois}
    for change in classify or []:
        roi = find(change.get("id"))
        label = change.get("classification")
        if label is None:
            roi.pop("classification", None)
        elif label in CLASSES:
            roi["classification"] = label
        else:
            raise NansenError("invalid-params", f"an ROI is accepted, rejected or unresolved, not {label!r}")
    for change in cell_type or []:
        roi = find(change.get("id"))
        label = change.get("cellType")
        if label is None or label == "":
            roi.pop("cellType", None)
        elif isinstance(label, str) and len(label) <= 64:
            roi["cellType"] = label
        else:
            raise NansenError("invalid-params", f"a cell type is a short text, not {label!r}")
    for group in link or []:
        if not isinstance(group, list) or len(group) < 2 or len(set(group)) != len(group):
            raise NansenError("invalid-params", "a link is a list of two or more different ROI ids")
        first = find(group[0])
        for other_id in group[1:]:
            other = find(other_id)
            first["links"] = sorted(set(first.get("links", [])) | {other["id"]})
            other["links"] = sorted(set(other.get("links", [])) | {first["id"]})
    for change in pixels or []:
        roi = find(change.get("id"))
        measure(roi, [(int(p[0]), int(p[1])) for p in change.get("pixels", []) if inside(p)])
    for change in move or []:
        roi = find(change.get("id"))
        dy, dx = int(change.get("rows", 0)), int(change.get("columns", 0))
        measure(roi, [(r + dy, c + dx) for r, c in pixels_of(roi) if inside((r + dy, c + dx))])
    gone = set()
    for group in merge or []:
        if not isinstance(group, list) or len(group) < 2 or len(set(group)) != len(group):
            raise NansenError("invalid-params", "a merge is a list of two or more different ROI ids")
        first = find(group[0])
        pixels = pixels_of(first)
        for roi_id in group[1:]:
            pixels += pixels_of(find(roi_id))
            gone.add(roi_id)
        measure(first, pixels)
    for roi_id in remove or []:
        find(roi_id)
    gone |= set(remove or [])
    rois = [roi for roi in rois if roi["id"] not in gone]
    for roi in rois:   # links to ROIs that are gone go too
        if roi.get("links") and gone & set(roi["links"]):
            roi["links"] = [i for i in roi["links"] if i not in gone]
            if not roi["links"]:
                del roi["links"]
    next_id = max([int(i) for i in by_id] + [0]) + 1
    added = []
    for new in add or []:
        roi = {"id": next_id}
        try:
            measure(roi, [(int(p[0]), int(p[1])) for p in new.get("pixels", []) if inside(p)])
        except NansenError:
            raise NansenError("invalid-params", "an added ROI needs pixels inside the image") from None
        rois.append(roi)
        added.append(next_id)
        next_id += 1
    return dict(value, rois=rois), added


def placed(value: Any) -> bool:
    """Whether an ROI file's ROIs have places: a plane and channel each (dev's RoiGroup of several of them)."""
    return isinstance(value, dict) and any(isinstance(r, dict) and ("plane" in r or "channel" in r) for r in value.get("rois", []))


def rois_at(value: Any, plane: int, channel: int) -> Any:
    """The ROI file with the ROIs of a plane and channel (from 1) only, and those with no place; all, when none has one."""
    if not placed(value):
        return value
    return dict(value, rois=[r for r in value["rois"] if r.get("plane", plane) == plane and r.get("channel", channel) == channel])


def update_rois_at(value: Any, plane: int, channel: int, **changes) -> Any:
    """update_rois on the ROIs of a plane and channel (from 1) of a file whose ROIs have places: a restore puts back
    that place's ROIs only, and added ROIs are put there. Returns (document, ids of the added ROIs)."""
    if not placed(value):
        return update_rois(value, **changes)
    rois = [dict(roi, id=roi.get("id", number)) for number, roi in enumerate(value.get("rois", []), start=1)]
    places = {roi["id"]: (roi["plane"], roi.get("channel", 1)) for roi in rois if "plane" in roi}
    if changes.get("restore") is not None:   # the others stay as they are
        elsewhere = [roi for roi in rois if roi.get("plane", plane) != plane or roi.get("channel", channel) != channel]
        changes["restore"] = elsewhere + list(changes["restore"])
    document, added = update_rois(dict(value, rois=rois), **changes)
    for roi in document["rois"]:
        if "plane" not in roi:
            roi["plane"], roi["channel"] = places.get(roi["id"], (plane, channel))
    return document, added


def detect_roi(image: Any, point: List[int], radius: int = 6) -> List[List[int]]:
    """An ROI found around a point of an image (height x width), as the viewer's Detect tool does.

    In the square of radius pixels around the point, the threshold is halfway from the 20th percentile of the
    square to the brightest pixel within radius of the point (square distance, counted as dy^2 + dx^2 <= radius^2).
    The ROI is the 4-connected area of pixels within radius that reach it, around the brightest pixel within 2
    of the point (the first in row-major order of equal ones), with its holes filled. 0-based [row, column]
    pixels in row-major order. MATLAB's nansen.internal.detectRoi finds the same.
    """
    import numpy as np
    image = np.asarray(image, dtype=np.float64)
    if image.ndim != 2:
        raise NansenError("invalid-data", "an ROI is detected in an image (height x width)")
    height, width = image.shape
    y, x = int(point[0]), int(point[1])
    if not (0 <= y < height and 0 <= x < width):
        raise NansenError("invalid-params", f"the point {point} is not in the {height} x {width} image")
    radius = max(1, int(radius))
    top, bottom, left, right = max(0, y - radius), min(height, y + radius + 1), max(0, x - radius), min(width, x + radius + 1)
    window = image[top:bottom, left:right]
    rows, columns = np.mgrid[top:bottom, left:right]
    near = (rows - y) ** 2 + (columns - x) ** 2
    values = np.sort(window[np.isfinite(window)])
    if values.size == 0:
        return []
    position = (values.size - 1) * 0.2
    low = values[int(np.floor(position))] + (position - np.floor(position)) * (values[min(int(np.floor(position)) + 1, values.size - 1)] - values[int(np.floor(position))])
    disk = near <= radius * radius
    high = window[disk & np.isfinite(window)].max()
    mask = disk & (window >= low + 0.5 * (high - low))
    seed, best = None, -np.inf
    for r, c in zip(*np.nonzero(near <= 4)):   # row-major
        if window[r, c] > best:
            seed, best = (r, c), window[r, c]
    if seed is None or not mask[seed]:
        return []
    area, todo = {seed}, [seed]
    while todo:
        r, c = todo.pop()
        for n in ((r - 1, c), (r + 1, c), (r, c - 1), (r, c + 1)):
            if 0 <= n[0] < mask.shape[0] and 0 <= n[1] < mask.shape[1] and mask[n] and n not in area:
                area.add(n)
                todo.append(n)
    region = np.zeros_like(mask)
    for r, c in area:
        region[r, c] = True
    # holes: pixels not reachable from the window's edge through pixels outside the region
    outside = np.zeros_like(mask)
    todo = [(r, c) for r in range(mask.shape[0]) for c in range(mask.shape[1])
            if (r in (0, mask.shape[0] - 1) or c in (0, mask.shape[1] - 1)) and not region[r, c]]
    for r, c in todo:
        outside[r, c] = True
    while todo:
        r, c = todo.pop()
        for n in ((r - 1, c), (r + 1, c), (r, c - 1), (r, c + 1)):
            if 0 <= n[0] < mask.shape[0] and 0 <= n[1] < mask.shape[1] and not region[n] and not outside[n]:
                outside[n] = True
                todo.append(n)
    return [[int(r + top), int(c + left)] for r, c in zip(*np.nonzero(~outside))]


def _round2(value: float) -> float:
    return math.floor(value * 100 + 0.5) / 100


def _number(value: float):
    return int(value) if math.isfinite(value) and value == int(value) else value


def roi_signal(stack: Any, pixels: Any, start: int = 0, stop: Optional[int] = None) -> Any:
    """The mean of the pixels ([row, column], 0-based) in each frame of a height x width x frames stack, read a chunk
    at a time: frames start..stop-1, NaN outside them. For the viewer's live signal of an ROI being edited."""
    import numpy as np
    height, width, frames = stack.shape
    points = np.asarray(pixels, dtype=np.int64).reshape(-1, 2)
    if points.size == 0 or (points < 0).any() or (points[:, 0] >= height).any() or (points[:, 1] >= width).any():
        raise NansenError("invalid-params", f"pixels are [row, column] pairs inside the {height} x {width} image")
    index = np.unique(points[:, 0] * width + points[:, 1])
    start = min(max(0, int(start)), frames)
    stop = frames if stop is None else min(max(start, int(stop)), frames)
    out = np.full(frames, np.nan)
    for first in range(start, stop, CHUNK):
        last = min(first + CHUNK, stop)
        chunk = np.asarray(stack.frames(first, last)).reshape(height * width, last - first)
        out[first:last] = chunk[index].astype(np.float64).mean(axis=0)
    return out


def signal_traces(values: Dict[str, Any], columns: List[int], start: int = 0, stop: Optional[int] = None,
                  max_points: int = 2000) -> Dict[str, Any]:
    """Columns of frames x N signal arrays (a 1-D array is one column), for the dashboard's trace plot.

    values maps variable names to arrays. Frames start..stop-1 (cut to the longest array) are taken every
    step-th, step the smallest that keeps it to max_points. Values are rounded to 4 decimals as
    floor(v * 10000 + 0.5) / 10000; NaN, infinities and frames past an array's end are null. MATLAB's
    nansen.internal.signalTraces gives the same.
    """
    try:
        import numpy as np
    except ImportError:
        raise NansenError("adapter-unavailable", 'plotting arrays needs NumPy: pip install "nansen-core[npy]"') from None
    arrays = {}
    for name, data in values.items():
        array = np.asarray(data)
        if array.dtype.kind not in "biuf" or array.ndim not in (1, 2):
            raise NansenError("invalid-data", f"{name} is not a frames x signals array")
        arrays[name] = array.astype(np.float64).reshape(array.shape[0], -1)
    frames = max((a.shape[0] for a in arrays.values()), default=0)
    start = min(max(0, int(start)), frames)
    stop = frames if stop is None else min(max(start, int(stop)), frames)
    max_points = max(1, int(max_points))
    step = max(1, math.ceil((stop - start) / max_points))
    picked = list(range(start, stop, step))
    traces = []
    for name, array in arrays.items():
        out = []
        for column in columns:
            column = int(column)
            if not 0 <= column < array.shape[1]:
                raise NansenError("invalid-params", f"{name} has {array.shape[1]} columns; column {column} is not one")
            out.append({"column": column, "values": [_rounded(array[t, column]) if t < array.shape[0] else None for t in picked]})
        traces.append({"variable": name, "columns": out, "count": int(array.shape[1])})
    return {"frames": frames, "start": start, "step": step, "points": len(picked), "traces": traces}


def _rounded(value: float) -> Optional[float]:
    value = float(value)
    return math.floor(value * 10000 + 0.5) / 10000 if math.isfinite(value) else None
