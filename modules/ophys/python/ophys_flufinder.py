"""ophys.flufinder in Python: dev's flufinder (NANSEN dev's +flufinder, runAutoSegmentation) written out step by step.

MATLAB's ophys.flufinder runs the toolbox itself; this follows its pipeline with the same steps, constants and order:

1. preprocessImages: the frames binned by their maximum (stack.process.framebin.max, 5 frames a bin), each bin less a
   Gaussian blur of SmoothingSigma 20 px with circular edges (removeBackground: imgaussfilt's 2 ceil(2 sigma) + 1 taps),
   less a moving mean over 20 bins (removeDynamicBackground: movmean, 10 before and 9 after), scaled to 0..1.
2. binarizeSomaStack: every bin thresholded at the 93rd percentile of all their values (prctile), holes filled, opened
   by strel('disk', round(d / 6)), dilated by strel('disk', round(d / 3)), cleared of areas touching the border, eroded
   and opened by that disk; d is roiDiameter. strel's disks are MATLAB's: of radius 3 and more approximated by
   periodic lines (strel_disk).
3. getBwComponentStats: the 8-connected areas of every bin but the last (dev's loop stops one short), the largest 1 %
   (above the 99th percentile of their areas) left out.
4. findUniqueRoisFromComponents, with its own defaults (runAutoSegmentation passes none: a 12 px soma, 2 observations,
   at most 1000 ROIs): the pixel most areas cover picks the areas around it (centroids within 3 px of their median),
   whose overlap image, cut to 31 x 31 around their centre, gives the ROI (getRoiMaskFromImage: above halfway from its
   50th to its 95th percentile, areas under a tenth of a cell's left out, holes filled, the largest area); an ROI that a
   kept one with its centre less than 10 px away (and not at the same place) overlaps by more than 75 % is left out.
   Then ROIs that overlap one another by more than 80 % are replaced by their intersection (mergeOverlappingRois).
5. shapeDetection on the mean of the preprocessed bins, scaled to 0..1: the Pearson correlation of each 15 x 15 window
   (0 outside the image) with makeRingKernel's ring (the image's 5th, 99th and 50th percentiles in strel('disk', 3),
   strel('disk', 5) less it, and the rest, blurred by sigma 1); its 8-connected areas above sqrt(0.2) of its largest,
   of 5 pixels or more, more than 15 px from the edge, give candidates at their rounded centroids; their 21 x 21 boxes,
   4 times larger (imresize) and cut to 0..1, that correlate with the mean of them by more than 0.1 are kept, each
   one's mask found by findSomaMaskByEdgeDetection (nansen.autodetect.soma_edges), and those whose ridge fraction is
   above 0.6 are ROIs, merged as above at 75 %.
6. combineRoiArrays: the activity ROIs, then the shape ROIs that none of them overlaps by more than 75 %.

Where it differs from the toolbox: arithmetic is in double precision (flufinder works in single); a recording of fewer
than 5 frames is one bin (framebin.max makes none); when no area is near the median centroid, the areas are clustered
by their centroids here (centroid linkage, cut at 3 px) as MATLAB's linkage and cluster do, and the largest cluster
taken (ties: the one with the earliest area), where MATLAB's cluster numbering decides; an ROI whose mask comes out
empty is left out (dev makes an empty RoI of it); and dev's loop that would never end when the busiest pixel belongs to
no area left, or its merge that fails when an overlap is not mutual, stop or skip here. Results are close to the
toolbox's, not bit-identical: OphysTest and test_ophys run both on recordings with cells at known places.
"""

import math
from pathlib import Path

import numpy as np

from nansen.adapters import load_object
from nansen.autodetect import gauss_blur, imresize, prctile, soma_edges

HERE = Path(__file__).resolve().parent

# dev's flufinder.getDefaultOptions, and the defaults of the functions runAutoSegmentation calls without them
BIN_SIZE = 5                 # BinningSize
SMOOTHING_SIGMA = 20         # SmoothingSigma
DYNAMIC_WINDOW = 20          # removeDynamicBackground's binSize
BINARIZATION_PERCENTILE = 93
UNIQUE_DIAMETER = 12         # findUniqueRoisFromComponents' RoiDiameter
OBSERVATIONS = 2             # NumObservationsRequired
MOST_ROIS = 1000             # findUniqueRoisFromComponents' MaxNumRois
MERGE_ACTIVITY = 0.80        # findUniqueRoisFromComponents' PercentOverlapForMerge
MERGE_SHAPES = 0.75          # PercentOverlapForMerge (shapeDetection, combineRoiArrays)
INNER_RADIUS, OUTER_RADIUS = 3, 5
BOX = 21                     # shapeDetection's boxSize
MARGIN = 15                  # px from the edge a shape candidate's centroid must be (strictly)


def _helper(name):
    return load_object(f"ophys_methods:{name}", HERE)


def flufinder(entity, options, context):
    """dev's flufinder (runAutoSegmentation with RoiDiameter roiDiameter) on the stack, its ROIs saved as ophys's ROI
    files (as MATLAB's ophys.flufinder saves the toolbox's)."""
    stack = _helper("_open_stack")(entity, options["stack"], context, options)
    height, width, frames = stack.shape
    context.log(f"{_helper('_name')(entity)}: running flufinder on {frames} frames")
    rois = auto_segmentation(stack, float(options["roiDiameter"]), context)
    make_roi = _helper("_roi")
    found = [make_roi(number + 1, roi.pixels()) for number, roi in enumerate(rois)]
    _helper("_save")(entity, options["output"], {"imageSize": [height, width], "rois": found}, context)
    context.log(f"{_helper('_name')(entity)}: flufinder found {len(found)} ROIs")
    return {"rois": len(found), "frames": frames}


class Roi:
    """A RoI of a mask: its pixels as 0-based column-major indices (MATLAB's linear indices less 1), its area and its
    centre (x, y), the mean of its pixels' 1-based coordinates, as dev's RoI('Mask', mask) has them."""

    def __init__(self, indices, height):
        self.indices = np.unique(np.asarray(indices, dtype=np.int64))
        self.height = height
        self.set = frozenset(int(i) for i in self.indices)
        self.area = len(self.indices)
        columns, rows = np.divmod(self.indices, height)
        self.center = (float(np.mean(columns + 1)), float(np.mean(rows + 1)))

    def pixels(self):
        """[row, column] pixels, 0-based, in row-major order."""
        columns, rows = np.divmod(self.indices, self.height)
        return sorted(zip(rows.tolist(), columns.tolist()))


def auto_segmentation(stack, diameter, context=None):
    """flufinder's runAutoSegmentation of a height x width x frames stack (read a chunk at a time): the Roi list."""
    height, width, _ = stack.shape
    binned = _helper("binned_max")(stack, BIN_SIZE)[0]   # framebin.max (one bin when there are fewer frames)
    _progress(context, 0.2, "removing background")
    data = preprocess(binned)
    _progress(context, 0.3, "binarizing")
    areas = component_stats(binarize(data, diameter, context), context)
    _progress(context, 0.7, "finding unique ROIs")
    rois = unique_rois(areas, height, width)
    _progress(context, 0.8, "searching for ring-shaped cells")
    shaped = shape_detection(data.mean(axis=2))
    return combine(rois, shaped)


def _progress(context, fraction, message):
    if context is not None:
        context.check_cancelled()
        context.progress(fraction, message)


# --- preprocessing and binarization -----------------------------------------------------------------------------------

def preprocess(binned):
    """preprocessImages after the binning: removeBackground, then removeDynamicBackground."""
    data = binned - gaussian_circular(binned, SMOOTHING_SIGMA)
    data = data - _helper("moving_mean")(data, DYNAMIC_WINDOW)
    data = data - data.min()
    top = data.max()
    return data / top if top > 0 else data


def gaussian_circular(data, sigma):
    """imgaussfilt of each frame with Padding circular: 2 ceil(2 sigma) + 1 taps of exp(-k^2 / (2 sigma^2)), normalised
    to sum 1, along both axes, the image wrapped around its edges (a circular convolution, done by FFT a chunk of
    frames at a time)."""
    half = int(math.ceil(2 * sigma))
    taps = np.exp(-np.arange(-half, half + 1, dtype=np.float64) ** 2 / (2 * sigma * sigma))
    taps = taps / taps.sum()
    data = np.asarray(data, dtype=np.float64)
    height, width, frames = data.shape

    def wrapped(size):   # the taps laid around a circle of size samples (several on one when the image is smaller)
        kernel = np.zeros(size)
        for k, weight in zip(range(-half, half + 1), taps):
            kernel[k % size] += weight
        return np.fft.fft(kernel)

    gain = (wrapped(height)[:, None] * wrapped(width)[None, :])[:, :, None]
    out = np.empty(data.shape)
    for start in range(0, frames, 50):
        chunk = data[:, :, start:start + 50]
        out[:, :, start:start + 50] = np.real(np.fft.ifft2(np.fft.fft2(chunk, axes=(0, 1)) * gain, axes=(0, 1)))
    return out


def strel_disk(radius):
    """The (row, column) offsets of MATLAB's strel('disk', radius) with its default of 4 periodic lines: below a radius
    of 3 the pixels within the radius; else the lines along (1, 0), (1, 1), (0, 1) and (-1, 1) of floor(k / |v|) steps
    either way, k = 2 r / (cot(pi / 8) + 1 / sin(pi / 8)) (Adams' radial decomposition), dilated together, and when
    that falls short of the radius by 2 or more, a horizontal and a vertical line of 2 (shortfall - 1) + 1 pixels
    added."""
    r = int(radius)
    if r < 3:
        return [(dy, dx) for dy in range(-r, r + 1) for dx in range(-r, r + 1) if dy * dy + dx * dx <= r * r]
    theta = math.pi / 8
    k = 2 * r / (1 / math.tan(theta) + 1 / math.sin(theta))
    shape = {(0, 0)}
    for vector in ((1, 0), (1, 1), (0, 1), (-1, 1)):
        steps = int(math.floor(k / math.hypot(*vector)))
        shape = {(y + p * vector[0], x + p * vector[1]) for y, x in shape for p in range(-steps, steps + 1)}
    shortfall = r - max(y for y, _ in shape)
    length = 2 * (shortfall - 1) + 1
    if length >= 3:
        half = (length - 1) // 2
        shape = {(y, x + p) for y, x in shape for p in range(-half, half + 1)}
        shape = {(y + p, x) for y, x in shape for p in range(-half, half + 1)}
    return sorted(shape)


def binarize(data, diameter, context=None):
    """binarizeSomaStack: each bin thresholded at the 93rd percentile of every value, holes filled (imfill), opened
    (imopen) by the small disk, dilated by the large one, cleared of what touches the border (imclearborder, 8-connected),
    eroded by the large disk and opened by it; outside the image counts as foreground when eroding, as imerode has it."""
    fill_holes, clear_border = _helper("fill_holes"), _helper("clear_border")
    dilate_by, erode_by = _helper("dilate_by"), _helper("erode_by")
    small = strel_disk(_half_away(diameter / 6))
    large = strel_disk(_half_away(diameter / 3))
    threshold = prctile(data, BINARIZATION_PERCENTILE)
    out = np.zeros(data.shape, dtype=bool)
    for b in range(data.shape[2]):
        if context is not None:
            context.check_cancelled()
        bw = fill_holes(data[:, :, b] > threshold)
        bw = dilate_by(erode_by(bw, small), small)
        bw = dilate_by(bw, large)
        bw = clear_border(bw)
        bw = erode_by(bw, large)
        out[:, :, b] = dilate_by(erode_by(bw, large), large)
    return out


def _half_away(value):
    """MATLAB's round: half away from zero."""
    return int(math.floor(abs(value) + 0.5)) * (1 if value >= 0 else -1)


# --- the areas and the ROIs found from them ---------------------------------------------------------------------------

def conncomp(mask):
    """bwconncomp's 8-connected areas, in MATLAB's order (by their first pixel, column after column), each as its
    0-based column-major indices, sorted."""
    height = mask.shape[0]
    areas = _helper("components")(np.ascontiguousarray(mask.T), 8)   # row-major in the transpose: column-major here
    return [np.array(sorted(x * height + y for x, y in area), dtype=np.int64) for area in areas]


def component_stats(bw, context=None):
    """getBwComponentStats: [(indices, area, centroid (x, y))] of the areas of every bin but the last, without those
    larger than the 99th percentile of their areas."""
    height = bw.shape[0]
    areas = []
    for b in range(bw.shape[2] - 1):   # dev's `for i = 1:numFrames-1`
        if context is not None:
            context.check_cancelled()
        for indices in conncomp(bw[:, :, b]):
            columns, rows = np.divmod(indices, height)
            areas.append((indices, len(indices), (float(np.mean(columns + 1)), float(np.mean(rows + 1)))))
    if not areas:
        return []
    largest = prctile(np.array([a[1] for a in areas], dtype=np.float64), 99)
    return [a for a in areas if not a[1] > largest]


def unique_rois(areas, height, width):
    """findUniqueRoisFromComponents with its defaults (see the module's description), then mergeOverlappingRois at 80 %."""
    if not areas:
        return []
    every = np.concatenate([a[0] for a in areas])
    owner = np.concatenate([np.full(len(a[0]), n) for n, a in enumerate(areas)])
    centroids = np.array([a[2] for a in areas])
    remaining = np.ones(len(areas), dtype=bool)
    image = _component_image(every, height * width)
    rois = []
    finished = False
    while not finished:
        peak = int(np.argmax(image))   # the first largest, column after column
        near = np.intersect1d(owner[every == peak], np.flatnonzero(remaining))
        if near.size == 0:
            image[peak] = 0
            if not image.max() > 0:   # dev's loop would not end here
                break
            continue
        center = np.array([_median(centroids[near, 0]), _median(centroids[near, 1])])
        close = np.all(np.abs(centroids[near] - center) < 3, axis=1)
        near = near[close] if close.any() else near[_largest_cluster(centroids[near], 3)]
        if near.size < OBSERVATIONS:
            finished = True
        current = np.zeros(height * width)
        for n in near:
            current[areas[n][0]] += 1
        x, y = _half_away(center[0]), _half_away(center[1])
        w = min(15, x - 1, width - x, y - 1, height - y)
        small = current.reshape((height, width), order="F")[y - 1 - w:y + w, x - 1 - w:x + w]
        mask = np.zeros((height, width), dtype=bool)
        mask[y - 1 - w:y + w, x - 1 - w:x + w] = roi_mask_from_image(small, UNIQUE_DIAMETER)
        indices = np.flatnonzero(mask.ravel(order="F"))
        image -= current
        image[indices] = 0
        if indices.size:
            roi = Roi(indices, height)
            if not any(_overlapping(kept, roi, 0.75) for kept in rois):
                rois.append(roi)
        remaining[near] = False
        if not remaining.any() or (image.reshape((height, width), order="F").sum(axis=0) <= 0).all():
            finished = True
        if len(rois) >= MOST_ROIS:
            finished = True
    return merge_overlapping(rois, MERGE_ACTIVITY, height)


def _component_image(every, size):
    """The count of areas at each pixel, as dev's histcounts over the unique pixels makes it: its last bin holds the
    last two of them, so the last pixel counts for the one before and is 0 itself."""
    counts = np.bincount(every, minlength=size).astype(np.float64)
    unique = np.unique(every)
    image = np.zeros(size)
    if unique.size >= 2:
        image[unique[:-1]] = counts[unique[:-1]]
        image[unique[-2]] += counts[unique[-1]]
    return image


def _median(values):
    """MATLAB's median."""
    x = np.sort(np.asarray(values, dtype=np.float64))
    n = x.size
    return float(x[n // 2]) if n % 2 else float(x[n // 2 - 1] + (x[n // 2] - x[n // 2 - 1]) / 2)


def _largest_cluster(points, cutoff):
    """The members (a boolean per point) of the largest cluster of points by centroid linkage cut at cutoff (clusters
    joined while the centroids of the two closest are less than cutoff apart); of equal ones, the earliest."""
    clusters = [[i] for i in range(len(points))]
    while len(clusters) > 1:
        centres = [points[c].mean(axis=0) for c in clusters]
        best, pair = None, None
        for i in range(len(clusters)):
            for j in range(i + 1, len(clusters)):
                distance = float(np.hypot(*(centres[i] - centres[j])))
                if best is None or distance < best:
                    best, pair = distance, (i, j)
        if not best < cutoff:
            break
        i, j = pair
        clusters[i] = sorted(clusters[i] + clusters[j])
        del clusters[j]
    biggest = max(clusters, key=lambda c: (len(c), -c[0]))
    keep = np.zeros(len(points), dtype=bool)
    keep[biggest] = True
    return keep


def roi_mask_from_image(image, diameter):
    """getRoiMaskFromImage for a soma: above halfway from the image's 50th to its 95th percentile (imbinarize), less
    8-connected areas under round(pi (diameter / 2)^2 / 10) pixels (bwareaopen), holes filled, the largest area (the
    first of equal ones, in bwconncomp's order)."""
    low, high = prctile(image, 50), prctile(image, 95)
    bw = image > low + (high - low) / 2
    smallest = _half_away(math.pi * (diameter / 2) ** 2 / 10)
    for indices in conncomp(bw):
        if len(indices) < smallest:
            bw[indices % bw.shape[0], indices // bw.shape[0]] = False
    bw = _helper("fill_holes")(bw)
    pieces = conncomp(bw)
    out = np.zeros(bw.shape, dtype=bool)
    if pieces:
        sizes = [len(p) for p in pieces]
        largest = pieces[sizes.index(max(sizes))]
        out[largest % bw.shape[0], largest // bw.shape[0]] = True
    return out


def _overlapping(a, b, threshold):
    """dev's findOverlappingRois of two ROIs: centres less than 10 px apart but not at the same place, and the share of
    the smaller one the other covers (RoI.calculateOverlap) above threshold."""
    distance = math.hypot(a.center[0] - b.center[0], a.center[1] - b.center[1])
    if not (distance < 10 and distance != 0):
        return False
    return len(a.set & b.set) / min(a.area, b.area) > threshold


def merge_overlapping(rois, threshold, height):
    """mergeOverlappingRois (intersect): each pair of ROIs that overlap (in roimanager's findOverlappingRois' order: by
    the first, then the second) becomes their intersection, the pair the other way round dropped as dev drops it, and
    the ROIs of the pairs are replaced by the intersections, put last."""
    pairs = [(i, j) for i in range(len(rois)) for j in range(len(rois)) if _overlapping(rois[i], rois[j], threshold)]
    gone = {i for i, _ in pairs}
    merged = []
    while pairs:
        i, j = pairs.pop(0)
        merged.append(Roi(sorted(rois[i].set & rois[j].set), height))
        # dev's find(IND == [ib, ia]): the rows whose first is ib, then those whose second is ia; the first of them
        rows = [n for n, (a, _) in enumerate(pairs) if a == j] + [n for n, (_, b) in enumerate(pairs) if b == i]
        if rows:
            del pairs[rows[0]]
    return [roi for n, roi in enumerate(rois) if n not in gone] + merged


# --- shape detection --------------------------------------------------------------------------------------------------

def ring_kernel(im, inner=INNER_RADIUS, outer=OUTER_RADIUS, sigma=1):
    """makeRingKernel: a square of 2 outer + 2 ceil(2 sigma) + 1 px, strel('disk', inner) at the image's 5th percentile,
    strel('disk', outer) less it at its 99th and the rest at its 50th (each disk centred: imexpand), blurred by
    imgaussfilt with sigma 1 (5 taps, edges repeated)."""
    size = 2 * outer + 2 * int(math.ceil(2 * sigma)) + 1
    centre = (size - 1) // 2
    nucleus, ring = np.zeros((size, size), dtype=bool), np.zeros((size, size), dtype=bool)
    for dy, dx in strel_disk(inner):
        nucleus[centre + dy, centre + dx] = True
    for dy, dx in strel_disk(outer):
        ring[centre + dy, centre + dx] = True
    background = ~ring
    ring &= ~nucleus
    values = [prctile(im, p) for p in (5, 50, 99)]
    kernel = background * values[1] + nucleus * values[0] + ring * values[2]
    return gauss_blur(kernel, rounded=False)


def _corr2(a, b):
    """MATLAB's corr2: NaN when either is flat."""
    a = a - a.mean()
    b = b - b.mean()
    scale = math.sqrt(float((a * a).sum()) * float((b * b).sum()))
    return float((a * b).sum()) / scale if scale > 0 else float("nan")


def shape_detection(image):
    """shapeDetection of an image (the mean of the preprocessed bins): Roi list, merged at 75 %."""
    im = np.asarray(image, dtype=np.float64)
    im = im - im.min()
    top = im.max()
    if not top > 0:
        return []
    im = im / top
    height, width = im.shape
    score = _helper("template_correlation")(im, ring_kernel(im))   # nlfilter of corr2, NaN where a window is flat
    finite = score[np.isfinite(score)]
    if not finite.size or not finite.max() > 0:
        return []
    with np.errstate(invalid="ignore"):
        bw = np.nan_to_num(score / finite.max(), nan=0.0) > math.sqrt(0.2)
    centres = []
    for indices in conncomp(bw):
        if len(indices) < 5:   # bwareaopen(BW, 5)
            continue
        columns, rows = np.divmod(indices, height)
        cx, cy = float(np.mean(columns + 1)), float(np.mean(rows + 1))
        if cx > MARGIN and cy > MARGIN and cx < width - MARGIN and cy < height - MARGIN:
            centres.append((_half_away(cx), _half_away(cy)))
    if not centres:
        return []
    half = BOX // 2
    boxes = np.stack([im[cy - 1 - half:cy + half, cx - 1 - half:cx + half] for cx, cy in centres], axis=2)
    upsampled = imresize(imresize(boxes, 0, 4 * BOX, False), 1, 4 * BOX, False)
    upsampled = np.clip(upsampled, 0, 1)
    mean = upsampled.mean(axis=2)
    rois = []
    for n, (cx, cy) in enumerate(centres):
        if not _corr2(mean, upsampled[:, :, n]) > 0.1:
            continue
        mask, ridge = soma_edges(boxes[:, :, n], rounded=False)
        if not ridge > 0.6:
            continue
        placed = np.zeros((height, width), dtype=bool)
        placed[cy - 1 - half:cy + half, cx - 1 - half:cx + half] = mask   # placeLocalRoiMaskInFovMask
        indices = np.flatnonzero(placed.ravel(order="F"))
        if indices.size:
            rois.append(Roi(indices, height))
    return merge_overlapping(rois, MERGE_SHAPES, height)


def combine(activity, shaped):
    """combineRoiArrays: the activity ROIs, then the shape ROIs none of them overlaps by more than 75 %."""
    if not activity or not shaped:
        return activity or shaped
    return activity + [s for s in shaped if not any(_overlapping(a, s, MERGE_SHAPES) for a in activity)]
