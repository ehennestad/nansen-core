"""dev's roimanager autodetection of an ROI around a point (roiMap.autodetectRoi2 and autodetectRoi), its five modes.

The viewer's Detect tool picks a mode with keys 1-5, as roimanager's autoDetect pointer tool does. r is the radius of
the tool's circle (dev's default 6), and the point is a pixel: x = column + 1, y = row + 1 in dev's 1-based terms.

1. dev's default (autodetectRoi2): a box of 2 (r + 5) + 1 pixels around the point (0 outside the image); the ROI's
   signal, the mean of the box's pixels within r of the point (dy^2 + dx^2 < r^2), over every frame; its dF/F
   (dffClassic: less its 20th percentile, divided by it), normalised to 0..1 and weighted 1 / (1 + exp(-10 (x - 0.5)));
   the box less its mean, weighted by those weights and averaged over the frames (computeRoiImages' Activity Weighted
   Mean), scaled to 0..255 and rounded (AutoAdjust, uint8); then flufinder's findSomaMaskByEdgeDetection, the mask
   centred on the point.
2. the box of r + 5 around the point, cut at the image's edges; the maximum over the frames where the ROI's signal is
   above its 5th percentile, widened by 2 frames on either side (findActiveSamplePoints); then flufinder's
   findSomaMaskByThresholding with an outer diameter of 2 r.
3. the image's box of r + 5 as 8 bits (stack.makeuint8), then findSomaMaskByThresholding.
4. as 3, in a box of r + the extended radius (dev's default 11).
5. the image's box of r + 5, then findSomaMaskByEdgeDetection.

dev's modes 3-5 work on the image shown in imviewer; here that is the image the caller gives (rois.detect: the viewer's
frame or projection, as data.frame takes it; the stack's mean when none is given).
Mode 0 is not dev's: the threshold of nansen.frames.detect_roi, which looks within r of the point.
MATLAB's nansen.internal.autodetectRoi finds the same: every step is written out in the same order in both, with no
toolbox function (imresize, imgaussfilt, poly2mask, medfilt2, bwareaopen, imfill and prctile are written here).
"""

from __future__ import annotations

import math
from typing import Any, List, Optional

from .errors import NansenError

PAD = 5              # dev's pad around the circle (autodetectRoi2)
EXTENDED = 11        # dev's extendedRadius (6 + 5), the extra padding of mode 4
CHUNK = 100          # frames read at a time
MODES = (1, 2, 3, 4, 5)


def autodetect_roi(stack: Any, point: Any, radius: Any = 6, mode: Any = 1, image: Optional[Any] = None,
                   extended: int = EXTENDED) -> List[List[int]]:
    """The 0-based [row, column] pixels (row-major order) of the ROI found around a point of a height x width x frames
    stack in a mode: dev's autodetection modes 1-5, or 0, the threshold nansen.frames.detect_roi applies (radius is then
    how far it looks). image is what modes 0 and 3-5 work on (the stack's mean, by default)."""
    import numpy as np
    from .frames import _mean, detect_roi
    if isinstance(mode, bool) or mode not in (0,) + MODES:
        raise NansenError("invalid-params", f"mode is 0, 1, 2, 3, 4 or 5, not {mode!r}")
    mode = int(mode)
    if not isinstance(point, list) or len(point) != 2:
        raise NansenError("invalid-params", "point is [row, column]")
    height, width, frames = stack.shape
    row, column = int(point[0]), int(point[1])
    if not (0 <= row < height and 0 <= column < width):
        raise NansenError("invalid-params", f"the point {point} is not in the {height} x {width} image")
    if mode == 0:
        return detect_roi(_mean(stack) if image is None else image, [row, column], int(radius))
    r = max(1, int(radius))
    x, y = column + 1, row + 1   # dev's 1-based pixel coordinates
    if mode == 1:
        size = 2 * (r + PAD) + 1
        top, left = y - (r + PAD), x - (r + PAD)   # getImageSubsetBounds, boundaryMethod none: not cut at the edges
        signal, sums = _box_signal(stack, top, left, size, size, r + PAD + 1, r + PAD + 1, r)
        weights = _sigmoid_weights(signal)
        offset = sums / (size * size * frames)   # the box's mean over every frame (SubtractBaseline)
        weighted = np.zeros((size, size))
        for start in range(0, frames, CHUNK):
            chunk = _box(stack.frames(start, start + CHUNK), top, left, size, size)
            for t in range(chunk.shape[2]):
                weighted = weighted + (chunk[:, :, t] - offset) * weights[start + t]
        roi_image = _uint8(_normalise(weighted / frames) * 255)
        mask = soma_mask_by_edges(roi_image, rounded=True)
        out = np.zeros((height, width), dtype=bool)
        half = (size + 1) // 2   # placeLocalRoiMaskInFovMask: ceil(size / 2)
        for i in range(size):
            for j in range(size):
                yy, xx = i + 1 - half + y, j + 1 - half + x
                if mask[i, j] and 1 <= yy <= height and 1 <= xx <= width:
                    out[yy - 1, xx - 1] = True
        return [[int(a), int(b)] for a, b in zip(*np.nonzero(out))]
    pad = extended if mode == 4 else PAD
    top, bottom = max(y - (r + pad), 1), min(y + (r + pad), height)   # getImageSubsetBounds, cut at the edges
    left, right = max(x - (r + pad), 1), min(x + (r + pad), width)
    rows, columns = bottom - top + 1, right - left + 1
    if mode == 2:
        signal, _ = _box_signal(stack, top, left, rows, columns, y - top + 1, x - left + 1, r)
        active = active_samples(signal)
        chunk_image = None
        for start in range(0, frames, CHUNK):
            chunk = _box(stack.frames(start, start + CHUNK), top, left, rows, columns)
            for t in range(chunk.shape[2]):
                if active[start + t]:
                    chunk_image = chunk[:, :, t].copy() if chunk_image is None else np.fmax(chunk_image, chunk[:, :, t])
        mask = soma_mask_by_threshold(chunk_image, 2 * r)
    else:
        if image is None:
            image = _mean(stack)
        part = np.asarray(image, dtype=np.float64)[top - 1:bottom, left - 1:right]
        if mode == 5:
            mask = soma_mask_by_edges(part, rounded=False)
        else:
            mask = soma_mask_by_threshold(makeuint8(part), 2 * r)
    out = np.zeros((height, width), dtype=bool)
    out[top - 1:bottom, left - 1:right] = mask
    return [[int(a), int(b)] for a, b in zip(*np.nonzero(out))]


# --- the ROI's signal and its weights ---------------------------------------------------------------------------------

def _box(chunk: Any, top: int, left: int, rows: int, columns: int) -> Any:
    """getPixelChunk: rows x columns pixels from (top, left) (1-based) of a height x width x frames chunk, 0 outside."""
    import numpy as np
    chunk = np.asarray(chunk)
    height, width = chunk.shape[:2]
    out = np.zeros((rows, columns, chunk.shape[2]))
    r0, r1 = max(top, 1), min(top + rows - 1, height)
    c0, c1 = max(left, 1), min(left + columns - 1, width)
    if r0 <= r1 and c0 <= c1:
        out[r0 - top:r1 - top + 1, c0 - left:c1 - left + 1] = chunk[r0 - 1:r1, c0 - 1:c1].astype(np.float64)
    return out


def _box_signal(stack: Any, top: int, left: int, rows: int, columns: int, cy: int, cx: int, r: int):
    """The mean over the box's pixels within r of (cy, cx) (1-based in the box; dy^2 + dx^2 < r^2, getCircularMask),
    added in column-major order, in each frame (extractSingleRoi); and the sum of the box over every frame."""
    import numpy as np
    inside = [(i, j) for j in range(columns) for i in range(rows) if (i + 1 - cy) ** 2 + (j + 1 - cx) ** 2 < r * r]
    weight = 1 / len(inside) if inside else 0.0
    height, width, frames = stack.shape
    signal = np.zeros(frames)
    total = 0.0
    for start in range(0, frames, CHUNK):
        chunk = _box(stack.frames(start, start + CHUNK), top, left, rows, columns)
        part, sums = np.zeros(chunk.shape[2]), np.zeros(chunk.shape[2])
        for i, j in inside:
            part = part + weight * chunk[i, j, :]
        for j in range(columns):   # each frame's sum, column after column
            for i in range(rows):
                sums = sums + chunk[i, j, :]
        signal[start:start + chunk.shape[2]] = part
        for value in sums:
            total += float(value)
    return signal, total


def _sigmoid_weights(signal: Any) -> Any:
    """computeRoiImages' weights: the signal's dF/F (dffClassic: (f - f0) / f0, f0 its 20th percentile), normalised to
    0..1 (0 when it is flat or not finite), as 1 / (1 + exp(-10 (x - 0.5)))."""
    import numpy as np
    f0 = prctile(signal, 20)
    with np.errstate(divide="ignore", invalid="ignore"):
        dff = (signal - f0) / f0
    return 1 / (1 + np.exp(-10 * (_normalise(dff) - 0.5)))


def _normalise(values: Any) -> Any:
    """(x - min) / (max - min); 0 when the values are flat or not all finite."""
    import numpy as np
    values = np.asarray(values, dtype=np.float64)
    if values.size == 0 or not np.isfinite(values).all():
        return np.zeros(values.shape)
    low, high = values.min(), values.max()
    if not high > low:
        return np.zeros(values.shape)
    return (values - low) / (high - low)


def _uint8(values: Any) -> Any:
    """Cast to 8 bits as MATLAB's uint8: rounded half away from zero, cut at 0 and 255, NaN as 0 (kept as floats)."""
    import numpy as np
    values = np.asarray(values, dtype=np.float64)
    with np.errstate(invalid="ignore"):
        out = np.clip(np.floor(values + 0.5), 0, 255)
    return np.nan_to_num(out, nan=0.0)


def prctile(values: Any, p: float) -> float:
    """MATLAB's prctile of a vector (NaN left out): the sorted values sit at percentiles 100 (i - 0.5) / n, linear
    between them, the first and last below and above."""
    import numpy as np
    x = np.sort(np.asarray(values, dtype=np.float64).ravel())
    x = x[~np.isnan(x)]
    n = x.size
    if n == 0:
        return float("nan")
    r = (p / 100) * n
    k = math.floor(r + 0.5)
    kp1 = min(k + 1, n)
    r = r - k
    k = max(k, 1)
    if r == -0.5 or x[k - 1] == x[kp1 - 1]:
        return float(x[k - 1])
    return float((0.5 + r) * x[kp1 - 1] + (0.5 - r) * x[k - 1])


def active_samples(signal: Any) -> Any:
    """findActiveSamplePoints: the frames where the signal is above p50 - (p50 - p5) (its 5th and 50th percentiles),
    and the 2 on either side of each (imdilate with ones(1, 5)); the first of its largest when there are none."""
    import numpy as np
    p5, p50 = prctile(signal, 5), prctile(signal, 50)
    above = np.asarray(signal) > p50 - (p50 - p5)
    active = np.zeros(above.size, dtype=bool)
    for t in np.flatnonzero(above):
        active[max(0, t - 2):t + 3] = True
    if not active.any():
        active[int(np.argmax(signal))] = True
    return active


def makeuint8(image: Any) -> Any:
    """stack.makeuint8 of an image, in single precision: scaled from its 0.05th to its 99.95th percentile (the sorted
    values at round(n 0.0005), at least the first, and round(n 0.9995), at most the last; NaN left out) to 0..255 and
    rounded as uint8 (kept as floats)."""
    import numpy as np
    data = np.asarray(image, dtype=np.float64).astype(np.float32)
    ordered = np.sort(data.T.ravel())
    ordered = ordered[~np.isnan(ordered)]
    n = ordered.size
    if n == 0:
        return np.zeros(data.shape)
    low = ordered[max(_round(n * 0.0005), 1) - 1]
    high = ordered[min(_round(n * (1 - 0.0005)), n) - 1]
    with np.errstate(divide="ignore", invalid="ignore", over="ignore"):
        scaled = ((data - low) / (high - low)) * np.float32(255)
    scaled = scaled.astype(np.float64)
    scaled[np.isposinf(scaled)] = 255
    scaled[np.isneginf(scaled)] = 0
    return _uint8(scaled)


def _round(value: float) -> int:
    """MATLAB's round: half away from zero."""
    return int(math.floor(abs(value) + 0.5)) * (1 if value >= 0 else -1)


# --- flufinder's findSomaMaskByThresholding ----------------------------------------------------------------------------

def soma_mask_by_threshold(image: Any, outer_diameter: float) -> Any:
    """flufinder's findSomaMaskByThresholding with InnerDiameter 0 (as dev's autodetection calls it).

    0s are left out (NaN). The threshold is halfway from the median of the pixels outside the circle of radius
    outer_diameter / 2 around the image's centre (size / 2, 1-based; squared distance < radius^2) to the median of those
    inside. The image is median filtered over 5 x 5 pixels (0 outside, NaN sorted last: the 13th of the 25); the mask is
    the pixels above the threshold, less 8-connected areas smaller than round(pi radius^2 / 2) pixels (bwareaopen),
    with holes (4-connected areas of the rest that do not reach the edge) filled."""
    import numpy as np
    im = np.asarray(image, dtype=np.float64).copy()
    im[im == 0] = np.nan
    height, width = im.shape
    r2 = outer_diameter / 2
    min_area = _round(math.pi * (r2 ** 2) / 2)
    yy = (np.arange(1, height + 1) - height / 2)[:, None]
    xx = (np.arange(1, width + 1) - width / 2)[None, :]
    soma = (xx ** 2 + yy ** 2) < r2 ** 2
    high, low = _nanmedian(im[soma]), _nanmedian(im[~soma])
    threshold = low + (high - low) / 2
    padded = np.zeros((height + 4, width + 4))
    padded[2:2 + height, 2:2 + width] = im
    filtered = np.zeros((height, width))
    for i in range(height):
        for j in range(width):
            filtered[i, j] = np.sort(padded[i:i + 5, j:j + 5].ravel())[12]
    with np.errstate(invalid="ignore"):
        mask = filtered > threshold
    mask = _area_open(mask, min_area)
    return _fill_holes(mask)


def _nanmedian(values: Any) -> float:
    """The median of the values that are not NaN (as MATLAB's median: the mean of the middle two, a + (b - a) / 2, or
    (a + b) / 2 when their signs differ); NaN when there are none."""
    import numpy as np
    x = np.sort(np.asarray(values, dtype=np.float64).ravel())
    x = x[~np.isnan(x)]
    return _median_sorted(x)


def _median_sorted(x: Any) -> float:
    n = len(x)
    if n == 0:
        return float("nan")
    if n % 2:
        return float(x[n // 2])
    a, b = float(x[n // 2 - 1]), float(x[n // 2])
    if (a > 0) != (b > 0) or (a < 0) != (b < 0) or math.isinf(a) or math.isinf(b):
        return (a + b) / 2
    return a + (b - a) / 2


def _components(mask: Any, steps: Any) -> List[List[Any]]:
    """The connected areas of a mask, each a list of (row, column)."""
    seen = set()
    areas = []
    height, width = mask.shape
    for i in range(height):
        for j in range(width):
            if not mask[i, j] or (i, j) in seen:
                continue
            seen.add((i, j))
            area, todo = [(i, j)], [(i, j)]
            while todo:
                a, b = todo.pop()
                for da, db in steps:
                    n = (a + da, b + db)
                    if 0 <= n[0] < height and 0 <= n[1] < width and mask[n] and n not in seen:
                        seen.add(n)
                        area.append(n)
                        todo.append(n)
            areas.append(area)
    return areas


EIGHT = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]
FOUR = [(-1, 0), (1, 0), (0, -1), (0, 1)]


def _area_open(mask: Any, size: int) -> Any:
    """bwareaopen: the mask less its 8-connected areas of fewer than size pixels."""
    out = mask.copy()
    for area in _components(mask, EIGHT):
        if len(area) < size:
            for p in area:
                out[p] = False
    return out


def _fill_holes(mask: Any) -> Any:
    """imfill holes: the mask with the 4-connected areas of the rest that do not reach the edge filled."""
    out = mask.copy()
    height, width = mask.shape
    for area in _components(~mask, FOUR):
        if not any(a in (0, height - 1) or b in (0, width - 1) for a, b in area):
            for p in area:
                out[p] = True
    return out


# --- flufinder's findSomaMaskByEdgeDetection ---------------------------------------------------------------------------

UPSAMPLING = 4


def soma_mask_by_edges(image: Any, rounded: bool) -> Any:
    """flufinder's findSomaMaskByEdgeDetection of an image (rounded: 8-bit values, which every step rounds to again).

    The image is made 4 times larger (imresize, bicubic), unrolled into rings around its centre (imunroll: radius by
    angle), blurred (imgaussfilt, sigma 1), and differentiated along the radius. In each direction the nucleus's edge
    is the largest rise (findEdge, its jumps of 5 or more mended) smoothed over 9 directions (circularsmooth); when
    its rises are significant (their mean over their standard deviation above 1.5) the soma's edge is sought from it
    out to 1.2 times its mean radius, otherwise from the centre. The soma's edge is the largest fall, mended and
    smoothed the same way; the mask is the pixels whose centre is inside the polygon of that edge, scaled back and 2/4
    pixel further out (poly2mask: inside by the even-odd rule)."""
    import numpy as np
    im = np.asarray(image, dtype=np.float64)
    height, width = im.shape
    mask = np.zeros((height, width), dtype=bool)
    big = imresize(imresize(im, 0, UPSAMPLING * height, rounded), 1, UPSAMPLING * width, rounded)
    unrolled = imunroll(big, rounded)
    rings, angles = unrolled.shape
    if rings < 3:
        return mask
    unrolled = gauss_blur(unrolled, rounded)
    grad = unrolled[1:, :] - unrolled[:-1, :]
    inner, inner_values = find_edge(grad, rise=True)
    inner_smooth = circular_smooth(inner, 2 * UPSAMPLING + 1)
    if _ratio(_mean(inner_values), _std(inner_values)) > 1.5:   # isSignificantBoundary (EdgeValue2)
        search = _crop_gradient(grad, inner_smooth)
    else:
        search = grad
        inner_smooth = [1.0] * angles
    outer, _ = find_edge(search, rise=False)
    outer_smooth = circular_smooth(outer, 2 * UPSAMPLING + 1)
    limit = grad.shape[0]
    xs, ys = [], []
    for k in range(angles):
        edge = min(max(outer_smooth[k] + inner_smooth[k], 1), limit)
        radius = edge / UPSAMPLING + 2 / UPSAMPLING
        theta = (math.pi / 180) * (k * (360 / angles))
        xs.append(width / 2 + radius * math.cos(theta) + 0.5)
        ys.append(height / 2 - radius * math.sin(theta) + 0.5)
    for i in range(height):
        for j in range(width):
            mask[i, j] = _inside(xs, ys, j + 1, i + 1)
    return mask


def _cubic(x: float) -> float:
    """imresize's bicubic kernel (a = -0.5)."""
    a = abs(x)
    a2 = a * a
    a3 = a2 * a
    return (1.5 * a3 - 2.5 * a2 + 1) * (a <= 1) + (-0.5 * a3 + 2.5 * a2 - 4 * a + 2) * ((1 < a) and (a <= 2))


def imresize(data: Any, axis: int, length: int, rounded: bool) -> Any:
    """imresize along an axis to length samples, bicubic, antialiased when it shrinks (MATLAB's contributions: the
    weights at u = x / scale + (1 - 1 / scale) / 2 normalised to sum 1, edges mirrored, all-zero columns dropped);
    the products are added in order of the weights; rounded: then rounded and cut to 0..255 (uint8)."""
    import numpy as np
    data = np.moveaxis(np.asarray(data, dtype=np.float64), axis, 0)
    size = data.shape[0]
    scale = length / size
    width = 4.0
    shrink = scale < 1
    if shrink:
        width = width / scale
    count = math.ceil(width) + 2
    weights, indices = [], []
    for x in range(1, length + 1):
        u = x / scale + 0.5 * (1 - 1 / scale)
        left = math.floor(u - width / 2)
        row = [scale * _cubic(scale * (u - (left + p))) if shrink else _cubic(u - (left + p)) for p in range(count)]
        total = 0.0
        for w in row:
            total += w
        weights.append([w / total for w in row])
        indices.append([left + p for p in range(count)])
    mirror = list(range(1, size + 1)) + list(range(size, 0, -1))
    kept = [p for p in range(count) if any(weights[x][p] != 0 for x in range(length))]
    out = np.zeros((length,) + data.shape[1:])
    for x in range(length):
        value = np.zeros(data.shape[1:])
        for p in kept:
            value = value + weights[x][p] * data[mirror[(indices[x][p] - 1) % len(mirror)] - 1]
        out[x] = value
    if rounded:
        out = np.clip(np.floor(out + 0.5), 0, 255)
    return np.moveaxis(out, 0, axis)


def imunroll(image: Any, rounded: bool) -> Any:
    """imunroll: row r (1..R, R the rounded smaller half size) holds the pixels at rounded distance r from the image's
    centre in order of their angle (0..360, counterclockwise from the right; ties in column-major order), resized to
    the image's width (imresize)."""
    import numpy as np
    height, width = image.shape
    cy, cx = (height + 1) / 2, (width + 1) / 2
    rings = _round(min(width - cx, (height - cy)))
    rho, theta = {}, {}
    entries = []
    for j in range(width):              # column-major, as MATLAB's find
        for i in range(height):
            xx, yy = (j + 1) - cx, -((i + 1) - cy)   # y up (flipud)
            distance = _round(math.hypot(xx, yy))
            angle = math.atan2(yy, xx) * (180 / math.pi)
            if angle < 0:
                angle = 180 + (180 - abs(angle))
            entries.append((distance, angle, i, j))
    out = np.zeros((max(rings, 0), width))
    for r in range(1, rings + 1):
        ring = sorted((e for e in entries if e[0] == r), key=lambda e: e[1])   # stable: ties keep column-major order
        values = np.array([image[i, j] for _, _, i, j in ring])
        out[r - 1] = imresize(values, 0, width, rounded)
    return out


def gauss_blur(image: Any, rounded: bool) -> Any:
    """imgaussfilt with sigma 1: a 5-sample Gaussian (exp(-k^2 / 2), normalised to sum 1) along the columns, then the
    rows, edges repeated; rounded to 8 bits at the end when the image is."""
    import numpy as np
    kernel = [math.exp(-(k * k) / 2) for k in range(-2, 3)]
    total = 0.0
    for w in kernel:
        total += w
    kernel = [w / total for w in kernel]
    out = np.asarray(image, dtype=np.float64)
    for axis in (0, 1):
        n = out.shape[axis]
        padded = np.concatenate([np.take(out, [0, 0], axis=axis), out, np.take(out, [n - 1, n - 1], axis=axis)], axis=axis)
        value = np.zeros(out.shape)
        for k in range(5):
            value = value + kernel[k] * np.take(padded, range(k, k + n), axis=axis)
        out = value
    if rounded:
        out = np.clip(np.floor(out + 0.5), 0, 255)
    return out


def _peak(values: Any, rise: bool):
    """max (rise) or min of the values that are not NaN, and the 1-based index of the first; (NaN, 1) when none."""
    best, at = float("nan"), 1
    for k, v in enumerate(values):
        v = float(v)
        if math.isnan(v):
            continue
        if math.isnan(best) or (v > best if rise else v < best):
            best, at = v, k + 1
    return best, at


def find_edge(grad: Any, rise: bool):
    """flufinder's findEdge: the 1-based row of each column's largest rise (or fall), then while two neighbouring
    columns (circularly) jump by 5 or more, the column after the largest jump is sought again: above the median plus
    the standard deviation, in the rows above it less 2; below the median less the standard deviation, in the rows
    from it plus 2; otherwise it, or the column before when that is stronger, is set halfway between the two. At most
    as many times as there are columns. Returns the rows and their values."""
    rows, columns = grad.shape
    coords, values = [], []
    for c in range(columns):
        v, k = _peak(grad[:, c], rise)
        values.append(v)
        coords.append(float(k))
    middle, spread = _median(coords), _std(coords)
    count = 0
    while coords:
        jumps = [coords[k] - coords[k - 1] for k in range(columns)]   # k = 0: from the last
        if all(d < 5 for d in jumps):
            break
        at = 0
        for k in range(1, columns):
            if jumps[k] > jumps[at]:
                at = k
        if coords[at] > middle + spread:
            bound = _round(max(1, coords[at] - 2))
            values[at], k = _peak(grad[:bound, at], rise)
            coords[at] = float(k)
        elif coords[at] < middle - spread:
            bound = _round(min(coords[at] + 2, rows))
            values[at], k = _peak(grad[bound - 1:, at], rise)
            coords[at] = float(k + bound - 1)
        else:
            before = columns - 1 if at == 0 else at - 1
            halfway = (coords[before] + coords[at]) / 2
            if values[before] > values[at]:
                coords[before] = halfway
                values[before] = float(grad[_round(halfway) - 1, before])
            else:
                coords[at] = halfway
                values[at] = float(grad[_round(halfway) - 1, at])
        count += 1
        if count > columns:
            break
        middle, spread = _median(coords), _std(coords)
    return coords, values


def _crop_gradient(grad: Any, boundary: List[float]) -> Any:
    """updateGradientImage: each column from its row round(boundary) on, moved to the top (NaN below; a column one longer
    than the rest adds a row of 0s, as MATLAB grows an array), cut at ceil(1.2 mean(boundary)) rows."""
    import numpy as np
    rows, columns = grad.shape
    lower = math.floor(min(boundary))
    out = np.full((rows - lower, columns), np.nan)
    for j in range(columns):
        values = grad[_round(boundary[j]) - 1:, j]
        if values.size > out.shape[0]:
            out = np.concatenate([out, np.zeros((values.size - out.shape[0], columns))], axis=0)
        out[:values.size, j] = values
    upper = math.ceil(_mean(boundary) * 1.2)
    return out[:min(out.shape[0], upper), :]


def circular_smooth(values: List[float], window: int) -> List[float]:
    """circularsmooth: the mean of the window values around each (window // 2 on either side, wrapping around), added
    in order."""
    n = len(values)
    half = window // 2
    out = []
    for i in range(n):
        total = 0.0
        for k in range(-half, half + 1):
            total += values[(i + k) % n]
        out.append(total / window)
    return out


def _mean(values: Any) -> float:
    total = 0.0
    for v in values:
        total += float(v)
    return total / len(values)


def _std(values: Any) -> float:
    """The standard deviation (n - 1), added in order."""
    n = len(values)
    if n < 2:
        return 0.0
    mean = _mean(values)
    total = 0.0
    for v in values:
        total += (float(v) - mean) * (float(v) - mean)
    return math.sqrt(total / (n - 1))


def _ratio(a: float, b: float) -> float:
    """a / b as MATLAB divides: +-Inf for a nonzero a over 0, NaN for 0 / 0."""
    if b == 0:
        return float("nan") if a == 0 or math.isnan(a) else math.copysign(float("inf"), a)
    return a / b


def _median(values: List[float]) -> float:
    return _median_sorted(sorted(values))


def _inside(xs: List[float], ys: List[float], px: float, py: float) -> bool:
    """Even-odd rule: is (px, py) inside the polygon of the points (xs, ys)?"""
    inside = False
    j = len(xs) - 1
    for i in range(len(xs)):
        if (ys[i] > py) != (ys[j] > py) and px < (xs[j] - xs[i]) * (py - ys[i]) / (ys[j] - ys[i]) + xs[i]:
            inside = not inside
        j = i
    return inside
