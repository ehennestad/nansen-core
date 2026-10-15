"""Frames of image data for the dashboard's viewer: one frame or a projection, scaled to 8 bits.

MATLAB's nansen.internal.imageFrame computes the same bytes from the same array, so both backends draw
the same picture.
"""

from __future__ import annotations

import base64
import math
from typing import Any, Dict, List, Optional, Tuple

from .errors import NansenError


def shown_image(stack: Any, frame: int = 0, projection: Optional[str] = None, limits: Optional[List[float]] = None,
                bin: Optional[Dict[str, Any]] = None):
    """The image the viewer shows of one channel and plane of a stack, as floats: a frame, a frame binned with those
    around it, or a projection. Also the frame (None for a projection), the limits (peakTime's own when none are
    given), the frames binned ([first, stop)) and peakTime's peaks."""
    import numpy as np

    frames = stack.shape[2]
    binned = peak = None
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
    elif projection == "meanClahe":
        image, frame = mean_clahe(stack), None
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
        raise NansenError("invalid-params", f"projection is mean, max, min, std, correlation, globalCorrelation, meanClahe or peakTime, not {projection!r}")
    return image, frame, limits, binned, peak


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
    image, frame, limits, binned, peak = shown_image(stack, frame, projection, limits, bin)
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


def mean_clahe(stack) -> Any:
    """dev's Mean CLAHE projection (stack.zproject.meanclahe): the mean over the frames, normalised to 0..1 (from its
    smallest to its largest finite value), contrast-limited adaptive histogram equalisation (clahe: dev's adapthisteq
    with 32 x 32 tiles, clip limit 0.015 and a Rayleigh distribution), scaled back to the mean's range and, for a
    stack of whole numbers, rounded as its type (half away from zero, cut at the type's range). An image smaller than
    32 pixels either way is the normalised mean, as dev's; a flat one, the mean. MATLAB's nansen.internal.meanClahe
    gives the same values."""
    import numpy as np
    from .stacks import as_stack
    stack = as_stack(stack)
    mean = _mean(stack)
    finite = mean[np.isfinite(mean)]
    if finite.size == 0 or not finite.max() > finite.min():
        return mean
    low, high = float(finite.min()), float(finite.max())
    normal = (mean - low) / (high - low)
    if mean.shape[0] < 32 or mean.shape[1] < 32:
        return normal
    out = clahe(normal) * (high - low) + low
    if stack.dtype.kind in "iu":
        info = np.iinfo(stack.dtype)
        out = np.clip(np.sign(out) * np.floor(np.abs(out) + 0.5), info.min, info.max)
    return out


CLAHE_TILES, CLAHE_CLIP, CLAHE_BINS, CLAHE_ALPHA = 32, 0.015, 256, 0.4


def clahe(image: Any) -> Any:
    """Contrast-limited adaptive histogram equalisation of an image of values in 0..1, as MATLAB's adapthisteq with
    NumTiles [32 32], ClipLimit 0.015, NBins 256, Distribution rayleigh (Alpha 0.4) and Range original (0..1 here),
    written out (no toolbox):

    the image is padded by mirroring (edge pixel repeated, half before and half after, the odd one after) to a whole
    number of tiles of an even number of rows and columns; each tile's histogram of 256 bins (bin floor(v 255 + 0.5),
    NaN in bin 0) is clipped at ceil(n / 256) + round(0.015 (n - ceil(n / 256))) (n the tile's pixels) and the excess
    handed back as adapthisteq does; its mapping is sqrt(-2 alpha^2 log(1 - (1 - exp(-1 / (2 alpha^2))) cumsum / n)),
    at most 1. Each pixel's value is the bilinear mix of the mappings of the four tiles around it (one or two at the
    edges), as adapthisteq's makeClaheImage adds them; the padding is cut off again."""
    import numpy as np
    image = np.asarray(image, dtype=np.float64)
    height, width = image.shape
    tiles, bins = CLAHE_TILES, CLAHE_BINS
    pads = []
    for size in (height, width):
        tile = size // tiles + 1 if size % tiles else size // tiles
        pad = tile * tiles - size
        if tile % 2:
            pad += tiles
        pads.append((pad // 2, pad - pad // 2))
    padded = np.pad(image, pads, mode="symmetric")
    rows, columns = padded.shape[0] // tiles, padded.shape[1] // tiles
    count = rows * columns
    least = -(-count // bins)
    limit = least + _half_away(CLAHE_CLIP * (count - least))
    with np.errstate(invalid="ignore"):
        binned = np.clip(np.floor(padded * (bins - 1) + 0.5), 0, bins - 1)
    binned = np.nan_to_num(binned, nan=0.0).astype(np.int64)
    hconst = 2 * CLAHE_ALPHA ** 2
    vmax = 1 - math.exp(-1 / hconst)
    maps = np.zeros((tiles, tiles, bins))
    for c in range(tiles):
        for r in range(tiles):
            tile = binned[r * rows:(r + 1) * rows, c * columns:(c + 1) * columns]
            histogram = _clip_histogram([int(v) for v in np.bincount(tile.ravel(), minlength=bins)], limit, bins)
            total, cumulative = 0, []
            for v in histogram:
                total += v
                cumulative.append(total)
            value = vmax * (np.array(cumulative, dtype=np.float64) / count)
            value[value >= 1] = 1 - np.finfo(float).eps
            maps[r, c] = np.minimum(0 + np.sqrt(-hconst * np.log(1 - value)) * 1, 1)
    out = np.zeros(padded.shape)
    top = 0
    for k in range(tiles + 1):
        height_k, (upper, lower) = (rows // 2, (0, 0)) if k == 0 else (rows // 2, (tiles - 1, tiles - 1)) if k == tiles else (rows, (k - 1, k))
        left = 0
        for m in range(tiles + 1):
            width_m, (before, after) = (columns // 2, (0, 0)) if m == 0 else (columns // 2, (tiles - 1, tiles - 1)) if m == tiles else (columns, (m - 1, m))
            index = binned[top:top + height_k, left:left + width_m]
            row_w = np.arange(height_k, dtype=np.float64)[:, None]
            row_rev = np.arange(height_k, 0, -1, dtype=np.float64)[:, None]
            column_w = np.arange(width_m, dtype=np.float64)[None, :]
            column_rev = np.arange(width_m, 0, -1, dtype=np.float64)[None, :]
            out[top:top + height_k, left:left + width_m] = (
                row_rev * (column_rev * maps[upper, before][index] + column_w * maps[upper, after][index])
                + row_w * (column_rev * maps[lower, before][index] + column_w * maps[lower, after][index])) / (height_k * width_m)
            left += width_m
        top += height_k
    return out[pads[0][0]:pads[0][0] + height, pads[1][0]:pads[1][0] + width]


def _half_away(value: float) -> int:
    """MATLAB's round: half away from zero."""
    return int(math.copysign(math.floor(abs(value) + 0.5), value))


def _clip_histogram(histogram: List[int], limit: int, bins: int) -> List[int]:
    """adapthisteq's clipHistogram: counts above limit cut to it, and the excess handed back, first evenly (each bin
    its share, those near the limit only up to it), then one at a time, spread out, from bin 1, 2, ... in turn."""
    excess = sum(max(v - limit, 0) for v in histogram)
    share = excess // bins
    upper = limit - share
    out = list(histogram)
    for k in range(bins):
        if out[k] > limit:
            out[k] = limit
        elif out[k] > upper:
            excess -= limit - out[k]
            out[k] = limit
        else:
            excess -= share
            out[k] += share
    start = 0
    while excess != 0:
        step = max(bins // excess, 1)
        for m in range(start, bins, step):
            if out[m] < limit:
                out[m] += 1
                excess -= 1
                if excess == 0:
                    break
        start += 1
        if start >= bins:
            start = 0
    return out


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
                link: Optional[list] = None, first_id: int = 1) -> Any:
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

    Added ROIs get ids from first_id on at least (rois.update's mirror: ids free in every aligned entity).
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
    next_id = max([int(i) for i in by_id] + [0, int(first_id) - 1]) + 1
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


IMPORT_MODES = ("replace", "append", "appendNonOverlapping")   # roimanager's Replace, Append and Append non-overlapping


def rois_overlap(a: List[Any], b: List[Any]) -> bool:
    """Whether two ROIs (lists of [row, column] pixels, each pixel once) overlap as dev's findOverlappingRois finds
    them: their centres (the mean of their pixels) are less than 10 pixels apart, and they share more than 0.75 of
    the smaller one's pixels (dev's RoI.calculateOverlap). Unlike dev, ROIs whose centres coincide exactly count too:
    dev leaves those out to skip an ROI matching itself when a set is compared with itself. MATLAB's
    nansen.internal.roisOverlap finds the same (the comparisons are made so they come out alike in both)."""
    if not a or not b:
        return False
    dy = sum(p[0] for p in a) / len(a) - sum(p[0] for p in b) / len(b)
    dx = sum(p[1] for p in a) / len(a) - sum(p[1] for p in b) / len(b)
    if dy * dy + dx * dx >= 100:
        return False
    shared = len({(int(p[0]), int(p[1])) for p in a} & {(int(p[0]), int(p[1])) for p in b})
    return 4 * shared > 3 * min(len(a), len(b))


def import_rois_at(value: Any, plane: int, channel: int, source: Any, mode: str = "append", first_id: int = 1) -> Any:
    """Combine the ROIs of another ROI file into a file's ROIs at a plane and channel (from 1), as roimanager adds
    loaded ROIs to those it has. Returns (document, ids of the imported ROIs).

    The source's ROIs at that place (all of them when it has no places) are taken, with their pixels outside the
    file's imageSize (or the source's, when the file has none) left out, and those with none inside left out
    altogether. mode is replace (the place's ROIs are removed first), append, or appendNonOverlapping (a source ROI
    that overlaps one of the place's ROIs, as rois_overlap finds, is left out). The place's ROIs that stay keep
    everything; the imported ones get the next free ids, in the source's order, as update_rois adds ROIs, and keep
    their classification, cell type, tags, uid (unless an ROI of the file has it already) and their links among
    themselves. MATLAB's nansen.internal.importRoisAt does the same.
    """
    if mode not in IMPORT_MODES:
        raise NansenError("invalid-params", f"an import's mode is replace, append or appendNonOverlapping, not {mode!r}")
    roi_outlines(source)   # checks the shape
    if "imageSize" not in value and source.get("imageSize"):
        value = dict(value, imageSize=list(source["imageSize"]))
    size = value.get("imageSize")
    inside = lambda p: size is None or (0 <= p[0] < size[0] and 0 <= p[1] < size[1])
    numbered = [dict(roi, id=roi.get("id", number)) for number, roi in enumerate(source.get("rois", []), start=1)]
    incoming = []
    for roi in rois_at(dict(source, rois=numbered), plane, channel)["rois"]:
        pixels = sorted({(int(p[0]), int(p[1])) for p in roi_outlines({"rois": [roi]})[0]["pixels"] if inside(p)})
        if pixels:
            incoming.append((roi, [list(p) for p in pixels]))
    here = roi_outlines(rois_at(value, plane, channel))
    remove = [roi["id"] for roi in here] if mode == "replace" else []
    if mode == "appendNonOverlapping":
        incoming = [(roi, pixels) for roi, pixels in incoming if not any(rois_overlap(pixels, other["pixels"]) for other in here)]
    document, added = update_rois_at(value, plane, channel, remove=remove, add=[{"pixels": pixels} for _, pixels in incoming], first_id=first_id)
    new_id = {roi["id"]: added[i] for i, (roi, _) in enumerate(incoming)}
    by_id = {roi["id"]: roi for roi in document["rois"]}
    taken = {roi.get("uid") for roi in document["rois"] if roi["id"] not in added and roi.get("uid")}
    for roi, _ in incoming:
        target = by_id[new_id[roi["id"]]]
        if roi.get("classification") in CLASSES:
            target["classification"] = roi["classification"]
        for name in ("cellType", "tags"):
            if roi.get(name):
                target[name] = roi[name]
        if roi.get("uid") and roi["uid"] not in taken:
            target["uid"] = roi["uid"]
            taken.add(roi["uid"])
        links = sorted(new_id[i] for i in (roi.get("links") or []) if i in new_id)
        if links:
            target["links"] = links
    return document, added


# ROIs carried between entities whose images were aligned (ophys.align_sessions, and rois.update's mirror). An ROI file's
# "alignment" is {reference, imageSize, entities: [{key, variable, shift, rotation, patches?, rowShifts?, columnShifts?}]}:
# for each entity aligned with the reference (the reference among them), where a point p of the reference's image is in
# its own: q = turn(rotation) * (p + d(p) + shift - centre) + centre, d the displacement field its patches' shifts give
# (rowShifts and columnShifts, patch (i, j) at i * patches + j; none without patches). MATLAB's nansen.internal.alignedPoints,
# referencePoints and mirrorRoisAt compute the same.

INVERSE_STEPS = 20   # fixed-point steps that undo a displacement field (it changes by much less than a pixel per pixel)


def _patch_place(coordinates: Any, size: int, count: int):
    """For coordinates along an axis (any real values): the patches (count of them along size) whose centres each lies
    between, and how far it is from the first (0..1), as the motion correction interpolates its patches' shifts; before
    the first centre or after the last, that patch's alone."""
    import numpy as np
    edges = [(i * size) // count for i in range(count + 1)]
    centres = np.array([(a + b - 1) / 2 for a, b in zip(edges, edges[1:])])
    coordinates = np.asarray(coordinates, dtype=np.float64)
    first = np.zeros(coordinates.shape, dtype=int)
    second = np.zeros(coordinates.shape, dtype=int)
    share = np.zeros(coordinates.shape)
    for n, y in enumerate(coordinates):
        if y <= centres[0]:
            continue
        if y >= centres[-1]:
            first[n] = second[n] = count - 1
            continue
        k = int(np.sum(centres <= y)) - 1
        first[n], second[n], share[n] = k, k + 1, (y - centres[k]) / (centres[k + 1] - centres[k])
    return first, second, share


def _displacement(points: Any, entry: dict, height: int, width: int) -> Any:
    """The displacement field of an aligned entity's patches at points (n x 2: rows, columns), interpolated bilinearly
    between the patch centres: n x 2; zero without patches."""
    import numpy as np
    count = int(entry.get("patches") or 1)
    out = np.zeros(points.shape)
    if count < 2:
        return out
    r0, r1, fy = _patch_place(points[:, 0], height, count)
    c0, c1, fx = _patch_place(points[:, 1], width, count)
    for axis, name in enumerate(("rowShifts", "columnShifts")):
        s = np.asarray(entry[name], dtype=np.float64).reshape(count, count)
        out[:, axis] = (1 - fy) * ((1 - fx) * s[r0, c0] + fx * s[r0, c1]) + fy * ((1 - fx) * s[r1, c0] + fx * s[r1, c1])
    return out


def _turned(points: Any, angle: float, height: int, width: int) -> Any:
    """Points (n x 2: rows, columns) turned by angle degrees about the image centre: [[cos, -sin], [sin, cos]]."""
    import numpy as np
    if not angle:
        return points
    radians = math.radians(angle)
    cos, sin = math.cos(radians), math.sin(radians)
    cy, cx = (height - 1) / 2, (width - 1) / 2
    y, x = points[:, 0] - cy, points[:, 1] - cx
    return np.stack([cos * y - sin * x + cy, sin * y + cos * x + cx], axis=1)


def aligned_points(points: Any, entry: dict, height: int, width: int) -> Any:
    """Where points of the reference's image (n x 2: rows, columns) are in an aligned entity's (its alignment entry), not
    rounded: the displacement field and the shift added, then turned by the rotation."""
    import numpy as np
    points = np.asarray(points, dtype=np.float64).reshape(-1, 2)
    moved = points + _displacement(points, entry, height, width) + np.asarray(entry.get("shift", [0, 0]), dtype=np.float64)
    return _turned(moved, float(entry.get("rotation", 0)), height, width)


def reference_points(points: Any, entry: dict, height: int, width: int) -> Any:
    """Where points of an aligned entity's image (n x 2) are in the reference's, as aligned_points has them, not rounded:
    turned back, less the shift, and the displacement field undone by INVERSE_STEPS steps of p = u - d(p) from p = u."""
    import numpy as np
    points = np.asarray(points, dtype=np.float64).reshape(-1, 2)
    target = _turned(points, -float(entry.get("rotation", 0)), height, width) - np.asarray(entry.get("shift", [0, 0]), dtype=np.float64)
    found = target
    if int(entry.get("patches") or 1) >= 2:
        for _ in range(INVERSE_STEPS):
            found = target - _displacement(found, entry, height, width)
    return found


def carried_pixels(pixels: Any, source: dict, target: dict, height: int, width: int) -> List[List[int]]:
    """An ROI's pixels in one aligned entity's image (source, its alignment entry) where they are in another's (target):
    through the reference's image, rounded half up, each once, in row-major order, and those outside the image left out."""
    import numpy as np
    if not len(pixels):
        return []
    points = np.floor(aligned_points(reference_points(pixels, source, height, width), target, height, width) + 0.5)
    kept = {(int(y), int(x)) for y, x in points if 0 <= y < height and 0 <= x < width}
    return [list(p) for p in sorted(kept)]


def alignment_entry(alignment: Any, key: Dict[str, Any]) -> Optional[dict]:
    """The entry of an ROI file's alignment for an entity's key (its key fields as the entry has them), or None."""
    if not isinstance(alignment, dict) or not isinstance(alignment.get("entities"), list):
        return None
    for entry in alignment["entities"]:
        if isinstance(entry, dict) and isinstance(entry.get("key"), dict) and all(key.get(k) == v for k, v in entry["key"].items()):
            return entry
    return None


def mirror_rois_at(value: Any, plane: int, channel: int, before: list, after: list, source: dict, target: dict,
                   size: List[int]) -> Any:
    """The ROI file of an aligned entity (target, its alignment entry) with an edit of another's ROIs (source) made to it
    too, at the same plane and channel (from 1), as dev's synchEntries mirrors: rois.update's mirror. before and after are
    the edited entity's ROIs there (roi_outlines) before and after the edit; size the aligned images' [height, width].
    Returns (document, {added, changed, removed}).

    An ROI the edit removed is removed here. An ROI it added or whose pixels it changed gets its pixels carried here
    (carried_pixels): an ROI of that id here takes them (and is removed when none land inside the image); otherwise it is
    added with that id, its classification and cell type, unless no pixel lands inside or an ROI of another plane or
    channel has the id. A classification or cell type the edit changed is set here too. Other ROIs here stay as they are.
    """
    old = {roi["id"]: roi for roi in before}
    new = {roi["id"]: roi for roi in after}
    shape = lambda roi: sorted((int(p[0]), int(p[1])) for p in roi["pixels"])
    reshaped = sorted(i for i in new if i not in old or shape(new[i]) != shape(old[i]))
    height, width = int(size[0]), int(size[1])
    here = {roi["id"] for roi in roi_outlines(rois_at(value, plane, channel))}
    everywhere = {roi["id"] for roi in roi_outlines(value)}
    remove = [i for i in sorted(old) if i not in new and i in here]
    reshape, add, wanted = [], [], []
    for roi_id in reshaped:
        pixels = carried_pixels(new[roi_id]["pixels"], source, target, height, width)
        if roi_id in here:
            if pixels:
                reshape.append({"id": roi_id, "pixels": pixels})
            else:
                remove.append(roi_id)
        elif pixels and roi_id not in everywhere:
            add.append({"pixels": pixels})
            wanted.append(roi_id)
    stays = lambda i: i in old and i in here and i not in remove
    classify = [{"id": i, "classification": new[i].get("classification")} for i in sorted(new)
                if stays(i) and new[i].get("classification") != old[i].get("classification")]
    cell_type = [{"id": i, "cellType": new[i].get("cellType")} for i in sorted(new)
                 if stays(i) and new[i].get("cellType") != old[i].get("cellType")]
    document, got = update_rois_at(value, plane, channel, classify=classify, cell_type=cell_type, pixels=reshape,
                                   remove=sorted(remove), add=add)
    names = dict(zip(got, wanted))
    for roi in document["rois"]:
        if roi["id"] in names:   # an added ROI takes the id it has in the entity edited, and its classification and cell type
            roi["id"] = names.pop(roi["id"])
            if new[roi["id"]].get("classification") in CLASSES:
                roi["classification"] = new[roi["id"]]["classification"]
            if new[roi["id"]].get("cellType"):
                roi["cellType"] = new[roi["id"]]["cellType"]
    changed = sorted({c["id"] for c in reshape} | {c["id"] for c in classify} | {c["id"] for c in cell_type})
    return document, {"added": sorted(wanted), "changed": changed, "removed": sorted(remove)}


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


# the neuropil's options and their defaults, as ophys.extract_signals has them
NEUROPIL_DEFAULTS = {"neuropilMethod": "ring", "neuropilGap": 1, "neuropilWidth": 3, "neuropilExpansionFactor": 4,
                     "neuropilSeparation": 0, "maxNeuropilRadius": 50, "numNeuropilSlices": 1, "includeRejected": False}


def neuropil_masks(masks: List[Any], options: Dict[str, Any], which: Optional[List[int]] = None) -> List[Any]:
    """The neuropil around ROIs, outside every ROI: masks (height x width, boolean) for the ROIs at which (indices
    into masks, all by default), with every ROI of masks reckoned with. ophys.extract_signals's neuropil, and
    rois.neuropil's; MATLAB's nansen.internal.neuropilMasks makes the same.

    neuropilMethod ring: the pixels at square distance neuropilGap+1 .. neuropilGap+neuropilWidth from the ROI.
    expansion, dev's (estimateNeuropilMasks): the ROI's mask dilated, alternately by its four sides (even steps) and
    its four diagonals (odd steps), less the ROI, until the part outside the ignored pixels covers
    neuropilExpansionFactor times the ROI's area (at most the rest of the image), or after maxNeuropilRadius steps
    (each one reaches a pixel further out; dev's maxNeuropilRadius, which its estimateNeuropilMasks meant to stop at
    instead of after 101 steps); the ignored pixels (every ROI, dilated neuropilSeparation times, from a diagonal
    step) are then taken out. neuropil_slices splits a neuropil in numNeuropilSlices.
    """
    import numpy as np
    options = dict(NEUROPIL_DEFAULTS, **options)
    which = range(len(masks)) if which is None else which
    if not masks:
        return []
    union = np.zeros(masks[0].shape, dtype=bool)
    for mask in masks:
        union |= mask
    if options["neuropilMethod"] != "expansion":
        gap, width = int(options["neuropilGap"]), int(options["neuropilWidth"])
        return [_dilate_square(masks[i], gap + width) & ~_dilate_square(masks[i], gap) & ~union for i in which]
    factor, radius = options["neuropilExpansionFactor"], int(options["maxNeuropilRadius"])
    ignored = union.copy()
    for step in range(1, int(options["neuropilSeparation"]) + 1):
        ignored = _dilate_odd_even(ignored, step)
    out = []
    for i in which:
        mask = masks[i]
        area = int(mask.sum())
        target = min(mask.size - area, factor * area)
        grown, covered, step = mask.copy(), 0, 0
        while covered < target and step < radius:
            grown = _dilate_odd_even(grown, step)
            grown &= ~mask
            covered = int((grown & ~ignored).sum())
            step += 1
        out.append(grown & ~ignored)
    return out


def _dilate_square(mask: Any, distance: int) -> Any:
    """Pixels within square (Chebyshev) distance of the mask."""
    out = mask.copy()
    for axis in (0, 1):
        grown = out.copy()
        size = out.shape[axis]
        for step in range(1, distance + 1):
            if step >= size:
                break
            lead = [slice(None), slice(None)]
            trail = [slice(None), slice(None)]
            lead[axis], trail[axis] = slice(step, None), slice(None, -step)
            grown[tuple(lead)] |= out[tuple(trail)]
            grown[tuple(trail)] |= out[tuple(lead)]
        out = grown
    return out


def _dilate_odd_even(mask: Any, step: int) -> Any:
    """One dilation by the four sides (step even) or the four diagonals (step odd), nothing past the edges."""
    out = mask.copy()
    offsets = [(1, 0), (-1, 0), (0, 1), (0, -1)] if step % 2 == 0 else [(1, 1), (1, -1), (-1, 1), (-1, -1)]
    height, width = mask.shape
    for dy, dx in offsets:
        out[max(dy, 0):height + min(dy, 0), max(dx, 0):width + min(dx, 0)] |= \
            mask[max(-dy, 0):height + min(-dy, 0), max(-dx, 0):width + min(-dx, 0)]
    return out


def neuropil_slices(neuropil: Any, mask: Any, count: int) -> List[Any]:
    """A neuropil (height x width, boolean) split in count slices of about equal area around its ROI's mask, as dev's
    splitNeuropilMasks (FISSA's split_npil): the angle of each neuropil pixel seen from the ROI's centroid, measured
    from the middle of the least populated of 20 equal bins of angle (the first of them, if several), so a slice does
    not run across the neuropil's narrowest part; slice k (from 1) is the pixels at or below the k / count quantile
    of those angles (linear interpolation, as numpy.percentile) and above the one before. dev's port leaves out
    FISSA's turn of the angles to that zero, which this keeps. MATLAB's nansen.internal.neuropilSlices does the same."""
    import numpy as np
    count = max(1, int(count))
    if count == 1:
        return [neuropil.copy()]
    out = [np.zeros(neuropil.shape, dtype=bool) for _ in range(count)]
    rows, columns = np.nonzero(neuropil)
    inside = np.nonzero(mask)
    if not rows.size or not inside[0].size:
        return out
    cy, cx = float(inside[0].sum()) / inside[0].size, float(inside[1].sum()) / inside[1].size   # whole numbers: exact
    theta = np.arctan2(rows - cy, columns - cx)
    edges = [-math.pi + k * (2 * math.pi / 20) for k in range(21)]
    bins = sum((theta >= edge).astype(int) for edge in edges[1:20])   # bin k holds edges[k] <= theta < edges[k + 1]
    least = int(np.argmin(np.bincount(bins, minlength=20)))
    turned = theta - (edges[least] + math.pi / 20)
    turned = np.where(turned < 0, turned + 2 * math.pi, turned) - math.pi
    ordered = np.sort(turned)
    bounds = []
    for k in range(1, count + 1):
        position = (ordered.size - 1) * k / count
        low = int(math.floor(position))
        high = min(low + 1, ordered.size - 1)
        bounds.append(ordered[low] + (position - low) * (ordered[high] - ordered[low]))
    for k in range(count):
        chosen = (turned <= bounds[k]) if k == 0 else (turned > bounds[k - 1]) & (turned <= bounds[k])
        out[k][rows[chosen], columns[chosen]] = True
    return out


def roi_neuropil(value: Any, roi: Any, options: Dict[str, Any], height: int, width: int) -> Tuple[List[List[int]], List[int]]:
    """The neuropil pixels ([row, column], 0-based, row-major) of the ROI of id roi in an ROI file, as
    ophys.extract_signals takes them (neuropil_masks): among the file's ROIs, less those rejected unless
    includeRejected, and the ROI itself always. Pixels outside the height x width image are left out. With them,
    the slice (from 1) each pixel is in (neuropil_slices, numNeuropilSlices; all 1 with one slice)."""
    import numpy as np
    rois = roi_outlines(value)
    at = next((i for i, r in enumerate(rois) if r["id"] == roi), None)
    if at is None:
        raise NansenError("invalid-params", f"there is no ROI {roi}")
    options = dict(NEUROPIL_DEFAULTS, **options)
    kept = [i for i, r in enumerate(rois) if i == at or options["includeRejected"] or r.get("classification") != "rejected"]
    masks = []
    for i in kept:
        mask = np.zeros((height, width), dtype=bool)
        for y, x in rois[i]["pixels"]:
            if 0 <= y < height and 0 <= x < width:
                mask[y, x] = True
        masks.append(mask)
    neuropil = neuropil_masks(masks, options, [kept.index(at)])[0]
    labels = np.zeros((height, width), dtype=int)
    for k, part in enumerate(neuropil_slices(neuropil, masks[kept.index(at)], options["numNeuropilSlices"]), start=1):
        labels[part] = k
    rows, columns = np.nonzero(neuropil)
    return [[int(r), int(c)] for r, c in zip(rows, columns)], [int(v) for v in labels[rows, columns]]


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
