"""Python implementations of the ophys module's methods.

Stacks are height x width x frames, in both languages: stack[y, x, t] here is stack(y+1, x+1, t+1) in
MATLAB, and .npy files keep that indexing. The MATLAB implementations in matlab/+ophys compute the
same values the same way; numbers that are returned are rounded with round_to, as there.
"""

import math

import numpy as np

from nansen.errors import NansenError

SMOOTHING = 1.15  # pixels: the phase correlation is smoothed by a Gaussian of this width, as suite2p does
CHUNK = 100       # frames handled at a time


def round_to(value, digits):
    """value rounded to digits decimals, half away from zero in the scaled value; None for NaN or infinity."""
    value = float(value)
    if not math.isfinite(value):
        return None
    scale = 10.0 ** digits
    return math.floor(value * scale + 0.5) / scale


def image_stats(entity, options, context):
    """Size and intensity of the stack; saves its average and maximum projections."""
    stack = _load_stack(entity, options["stack"], context)
    height, width, frames = stack.shape
    total = 0.0
    maximum = None
    average = np.zeros((height, width))
    for start in range(0, frames, CHUNK):
        chunk = stack[:, :, start:start + CHUNK]
        average += chunk.astype(np.float64).sum(axis=2)
        peak = chunk.max(axis=2)
        maximum = peak if maximum is None else np.maximum(maximum, peak)
    total = float(average.sum())
    average /= frames
    _save(entity, options["averageOutput"], average, context)
    _save(entity, options["maximumOutput"], maximum, context)
    context.log(f"{_name(entity)}: {frames} frames of {height} x {width}")
    return {"n_frames": frames, "height": height, "width": width,
            "mean_intensity": round_to(total / stack.size, 4), "max_intensity": float(maximum.max())}


def motion_correction(entity, options, context):
    """Align each frame to a reference by the whole-pixel shift of largest (smoothed) phase correlation."""
    stack = _load_stack(entity, options["stack"], context)
    height, width, frames = stack.shape
    count = min(options["referenceFrames"], frames)
    reference = stack[:, :, :count].astype(np.float64).mean(axis=2)
    iterations = options["iterations"]
    for iteration in range(iterations):
        shifts = np.zeros((frames, 2), dtype=np.int32)
        reference_fft = np.conj(np.fft.fft2(reference)) * _smoothing(height, width)
        for start in range(0, frames, CHUNK):
            context.check_cancelled()
            stop = min(start + CHUNK, frames)
            shifts[start:stop] = estimate_shifts(stack[:, :, start:stop], reference_fft, options["maxShift"])
            context.progress((iteration * frames + stop) / (iterations * frames), f"iteration {iteration + 1}: frame {stop}/{frames}")
        aligned = apply_shifts(stack, shifts)
        reference = aligned.astype(np.float64).mean(axis=2)
    _save(entity, options["output"], aligned, context)
    _save(entity, options["shiftsOutput"], shifts, context)
    distance = np.sqrt((shifts.astype(np.float64) ** 2).sum(axis=1))
    context.log(f"{_name(entity)}: largest shift {int(np.abs(shifts).max(initial=0))} px")
    return {"frames": frames, "maxShift": int(np.abs(shifts).max(initial=0)), "meanShift": round_to(distance.mean(), 4)}


def estimate_shifts(frames, reference_fft, max_shift):
    """(rows, columns) each frame of a height x width x n stack is displaced from the reference.

    reference_fft is the conjugate of the reference's 2-D FFT times the smoothing. The peak is looked for
    within max_shift (and less than half the frame); of equal peaks, the one of smallest row shift, then
    column shift, wins.
    """
    height, width = frames.shape[:2]
    product = np.fft.fft2(frames.astype(np.float64), axes=(0, 1)) * reference_fft[:, :, None]
    product /= np.maximum(np.abs(product), 1e-12)
    correlation = np.real(np.fft.ifft2(product, axes=(0, 1)))
    rows = np.arange(-min(max_shift, (height - 1) // 2), min(max_shift, (height - 1) // 2) + 1)
    columns = np.arange(-min(max_shift, (width - 1) // 2), min(max_shift, (width - 1) // 2) + 1)
    window = correlation[np.ix_(rows % height, columns % width)].reshape(rows.size * columns.size, -1)
    best = window.argmax(axis=0)
    return np.stack([rows[best // columns.size], columns[best % columns.size]], axis=1)


def apply_shifts(stack, shifts):
    """Each frame moved back by its shift: out[y, x] = frame[y + dy, x + dx], and 0 outside the frame."""
    height, width = stack.shape[:2]
    aligned = np.zeros_like(stack)
    for t, (dy, dx) in enumerate(shifts):
        dy, dx = int(dy), int(dx)
        aligned[max(0, -dy):min(height, height - dy), max(0, -dx):min(width, width - dx), t] = \
            stack[max(0, dy):min(height, height + dy), max(0, dx):min(width, width + dx), t]
    return aligned


def _smoothing(height, width):
    fy = np.fft.fftfreq(height)[:, None]
    fx = np.fft.fftfreq(width)[None, :]
    return np.exp(-2 * np.pi ** 2 * SMOOTHING ** 2 * (fy ** 2 + fx ** 2))


def detect_rois(entity, options, context):
    """ROIs as 4-connected areas of pixels whose average correlation with their 8 neighbours reaches the threshold."""
    stack = _load_stack(entity, options["stack"], context)
    height, width, frames = stack.shape
    image = correlation_image(stack)
    border = options["border"]
    image[:border] = image[height - border:] = -np.inf
    image[:, :border] = image[:, width - border:] = -np.inf
    rois = []
    for pixels in components(image >= options["threshold"]):
        if options["minSize"] <= len(pixels) <= options["maxSize"]:
            rois.append(_roi(len(rois) + 1, pixels))
    _save(entity, options["output"], {"imageSize": [height, width], "rois": rois}, context)
    context.log(f"{_name(entity)}: {len(rois)} ROIs")
    return {"rois": len(rois), "areas": [roi["area"] for roi in rois]}


def correlation_image(stack):
    """Each pixel's average Pearson correlation with its in-frame 8 neighbours over time."""
    height, width = stack.shape[:2]
    data = stack.astype(np.float64)
    data -= data.mean(axis=2, keepdims=True)
    spread = np.sqrt((data ** 2).mean(axis=2, keepdims=True))
    data = np.divide(data, spread, out=np.zeros_like(data), where=spread > 0)
    total = np.zeros((height, width))
    count = np.zeros((height, width))
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dy == 0 and dx == 0:
                continue
            here = (slice(max(0, -dy), min(height, height - dy)), slice(max(0, -dx), min(width, width - dx)))
            there = (slice(max(0, dy), min(height, height + dy)), slice(max(0, dx), min(width, width + dx)))
            total[here] += (data[here] * data[there]).mean(axis=2)
            count[here] += 1
    return np.divide(total, count, out=np.zeros_like(total), where=count > 0)


def components(mask):
    """The 4-connected areas of a boolean image, each as its (row, column) pixels in row-major order.

    Areas come in the row-major order of their first pixel.
    """
    height, width = mask.shape
    seen = np.zeros_like(mask, dtype=bool)
    found = []
    for seed in np.flatnonzero(mask):
        y, x = divmod(int(seed), width)
        if seen[y, x]:
            continue
        seen[y, x] = True
        pixels, queue = [], [(y, x)]
        while queue:
            y, x = queue.pop()
            pixels.append((y, x))
            for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= ny < height and 0 <= nx < width and mask[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    queue.append((ny, nx))
        found.append(sorted(pixels))
    return found


def _roi(number, pixels):
    rows = np.array([p[0] for p in pixels], dtype=np.float64)
    columns = np.array([p[1] for p in pixels], dtype=np.float64)
    return {"id": number, "area": len(pixels), "center": [round_to(rows.mean(), 2), round_to(columns.mean(), 2)],
            "pixels": [[int(y), int(x)] for y, x in pixels]}


def extract_signals(entity, options, context):
    """Average of each ROI's pixels per frame, and of a ring of neuropil around it outside every ROI."""
    stack = _load_stack(entity, options["stack"], context)
    height, width, frames = stack.shape
    masks = roi_masks(context.project.load(entity, options["rois"]), height, width)
    flat = stack.reshape(height * width, frames)
    signals = np.full((frames, len(masks)), np.nan)
    neuropil = np.full((frames, len(masks)), np.nan)
    union = np.zeros((height, width), dtype=bool)
    for mask in masks:
        union |= mask
    for i, mask in enumerate(masks):
        context.check_cancelled()
        signals[:, i] = flat[np.flatnonzero(mask)].astype(np.float64).mean(axis=0)
        ring = neuropil_ring(mask, union, options["neuropilGap"], options["neuropilWidth"])
        if ring.any():
            neuropil[:, i] = flat[np.flatnonzero(ring)].astype(np.float64).mean(axis=0)
        context.progress((i + 1) / len(masks), f"ROI {i + 1}/{len(masks)}")
    _save(entity, options["output"], signals, context)
    _save(entity, options["neuropilOutput"], neuropil, context)
    context.log(f"{_name(entity)}: signals of {len(masks)} ROIs in {frames} frames")
    return {"rois": len(masks), "frames": frames,
            "meanSignal": [round_to(v, 4) for v in signals.mean(axis=0)],
            "meanNeuropil": [round_to(v, 4) for v in neuropil.mean(axis=0)]}


def roi_masks(document, height, width):
    """Boolean height x width masks of the ROIs of an ROI file."""
    size = [int(v) for v in document.get("imageSize", [height, width])]
    if size != [height, width]:
        raise NansenError("invalid-data", f"the ROIs are for {size[0]} x {size[1]} images, the stack is {height} x {width}")
    masks = []
    for roi in document.get("rois", []):
        pixels = np.asarray(roi["pixels"], dtype=np.int64).reshape(-1, 2)
        mask = np.zeros((height, width), dtype=bool)
        mask[pixels[:, 0], pixels[:, 1]] = True
        masks.append(mask)
    return masks


def neuropil_ring(mask, union, gap, width):
    """Pixels at square distance gap+1 .. gap+width from the ROI that are in no ROI."""
    return dilate(mask, gap + width) & ~dilate(mask, gap) & ~union


def dilate(mask, distance):
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


def compute_dff(entity, options, context):
    """(F - F0) / F0, with F the signal less a share of the neuropil and F0 a running or overall percentile."""
    signals = _as_traces(context.project.load(entity, options["signals"]))
    if options["neuropil"]:
        neuropil = _as_traces(context.project.load(entity, options["neuropil"]))
        if neuropil.shape != signals.shape:
            raise NansenError("invalid-data", f"the neuropil signals are {neuropil.shape}, the signals {signals.shape}")
        signals = signals - options["neuropilFactor"] * np.nan_to_num(neuropil, nan=0.0)
    baseline = moving_percentile(signals, options["baselinePercentile"], options["baselineWindow"])
    with np.errstate(divide="ignore", invalid="ignore"):
        dff = (signals - baseline) / baseline
    _save(entity, options["output"], dff, context)
    frames, rois = signals.shape
    context.log(f"{_name(entity)}: ΔF/F of {rois} ROIs")
    peaks = []
    for i in range(rois):
        finite = dff[~np.isnan(dff[:, i]), i]  # NaN left out, as MATLAB's max does
        peaks.append(finite.max() if finite.size else np.nan)
    return {"rois": rois, "frames": frames,
            "baseline": [round_to(v, 4) for v in baseline.mean(axis=0)] if frames else [None] * rois,
            "maxDff": [round_to(v, 4) for v in peaks]}


def moving_percentile(traces, percentile, window):
    """The percentile of each column, over all rows (window 0) or over the window rows centred on each row.

    The window of row t is rows t - window // 2 up to, not including, t - window // 2 + window, cut at the ends.
    """
    frames = traces.shape[0]
    if window == 0 or window >= 2 * frames:
        return np.repeat(_percentile(traces, percentile)[None, :], frames, axis=0)
    out = np.empty_like(traces)
    for t in range(frames):
        start = max(0, t - window // 2)
        out[t] = _percentile(traces[start:min(frames, t - window // 2 + window)], percentile)
    return out


def _percentile(values, percentile):
    """Linear interpolation between the sorted values of each column, at (n - 1) * percentile / 100; NaN if any is NaN."""
    ordered = np.sort(values, axis=0)
    position = (ordered.shape[0] - 1) * percentile / 100
    low = int(math.floor(position))
    high = min(low + 1, ordered.shape[0] - 1)
    result = ordered[low] + (position - low) * (ordered[high] - ordered[low])
    result[np.isnan(values).any(axis=0)] = np.nan
    return result


def downsample(entity, options, context):
    """Bin the stack: mean (single precision) or maximum of each bin of frames and of pixels."""
    stack = _load_stack(entity, options["stack"], context)
    factor, side = options["temporalFactor"], options["spatialFactor"]
    height, width = stack.shape[0] // side, stack.shape[1] // side
    frames = stack.shape[2] // factor
    if frames == 0 or height == 0 or width == 0:
        raise NansenError("invalid-options", f"the stack {stack.shape} is smaller than one bin")
    out = np.empty((height, width, frames), dtype=np.float32 if options["binMethod"] == "mean" else stack.dtype)
    step = max(1, CHUNK // factor)
    for start in range(0, frames, step):
        context.check_cancelled()
        stop = min(start + step, frames)
        bins = stack[:height * side, :width * side, start * factor:stop * factor]
        bins = bins.reshape(height, side, width, side, stop - start, factor)
        if options["binMethod"] == "mean":
            out[:, :, start:stop] = bins.astype(np.float64).mean(axis=(1, 3, 5))
        else:
            out[:, :, start:stop] = bins.max(axis=(1, 3, 5))
        context.progress(stop / frames, f"frame {stop}/{frames}")
    _save(entity, options["output"], out, context)
    context.log(f"{_name(entity)}: {frames} frames of {height} x {width}")
    return {"frames": frames, "height": height, "width": width,
            "meanIntensity": round_to(out.astype(np.float64).mean(), 4)}


VARIABLES = [
    ("TwoPhotonSeries_Corrected", "Motion-corrected stack", "two_photon_series_corrected.npy", "npy", "ImageStack"),
    ("TwoPhotonSeries_Downsampled", "Downsampled stack", "two_photon_series_downsampled.npy", "npy", "ImageStack"),
    ("MotionCorrectionShifts", "Motion correction shifts", "motion_correction_shifts.npy", "npy", "Array"),
    ("FovAverageProjection", "Average projection", "fov_average_projection.npy", "npy", "Image"),
    ("FovMaximumProjection", "Maximum projection", "fov_maximum_projection.npy", "npy", "Image"),
    ("RoiArray", "ROIs", "roi_array.json", "json", "RoiArray"),
    ("RoiSignals_MeanF", "ROI signals", "roi_signals_mean_f.npy", "npy", "RoiSignals"),
    ("RoiSignals_NeuropilF", "Neuropil signals", "roi_signals_neuropil_f.npy", "npy", "RoiSignals"),
    ("RoiSignals_Dff", "ROI ΔF/F", "roi_signals_dff.npy", "npy", "RoiSignals"),
]


def setup_variables(project, options, context):
    """Add the data variables the ophys methods use, and the imaging and image statistics columns."""
    entity_type = options["entityType"]
    project.entity_type(entity_type)
    have = {variable.name for variable in project.data_variables()}
    documents = []
    if options["rawFilePattern"]:
        documents.append({"schemaType": "nansen.dataVariable", "schemaVersion": "0.1.0",
                          "name": "TwoPhotonSeries_Original", "title": "Raw recording", "entityType": entity_type,
                          "dataLocation": options["rawDataLocation"], "filePattern": options["rawFilePattern"],
                          "fileAdapter": options["rawFileAdapter"], "dataType": "ImageStack"})
    for name, title, file_name, adapter, data_type in VARIABLES:
        document = {"schemaType": "nansen.dataVariable", "schemaVersion": "0.1.0", "name": name, "title": title,
                    "entityType": entity_type, "dataLocation": options["dataLocation"]}
        if options["subfolder"]:
            document["subfolder"] = options["subfolder"]
        document.update({"fileName": file_name, "fileAdapter": adapter, "dataType": data_type})
        documents.append(document)
    created, existing = [], []
    for document in documents:
        if document["name"] in have:
            existing.append(document["name"])
        else:
            project.add_data_variable(document)
            created.append(document["name"])
    columns = []
    if options["addColumns"]:
        for fragment_id in ("ophys.imaging", "ophys.image_stats"):
            if fragment_id not in project.entity_type(entity_type).get("fragments", []):
                project.attach_fragment(entity_type, fragment_id)
                columns.append(fragment_id)
    context.log(f"added {len(created)} data variables to {entity_type}")
    return {"created": created, "existing": existing, "fragments": columns}


def suite2p(entity, options, context):
    """Run suite2p on the stack and keep its cells as ROIs, with their signals."""
    try:
        import suite2p as s2p
        import tifffile
    except ImportError as error:
        raise NansenError("dependency-missing",
                          f"ophys.suite2p needs suite2p and tifffile ({error}): pip install suite2p tifffile") from None
    stack = _load_stack(entity, options["stack"], context)
    height, width, frames = stack.shape
    folder = context.project.write_path(entity, options["rois"]).parent / "suite2p"
    folder.mkdir(parents=True, exist_ok=True)
    tifffile.imwrite(folder / "input.tif", np.moveaxis(np.asarray(stack), 2, 0))
    ops = s2p.default_ops()
    ops.update({"fs": options["framesPerSecond"], "diameter": options["cellDiameter"], "nchannels": 1, "nplanes": 1})
    db = {"data_path": [str(folder)], "tiff_list": ["input.tif"], "save_path0": str(folder)}
    context.log(f"{_name(entity)}: running suite2p in {folder}")
    s2p.run_s2p(ops=ops, db=db)
    plane = folder / "suite2p" / "plane0"
    stat = np.load(plane / "stat.npy", allow_pickle=True)
    keep = np.load(plane / "iscell.npy")[:, 0] > 0 if options["onlyCells"] else np.ones(len(stat), dtype=bool)
    rois = [_roi(n + 1, sorted(zip(cell["ypix"].tolist(), cell["xpix"].tolist())))
            for n, cell in enumerate(c for c, k in zip(stat, keep) if k)]
    context.project.save(entity, options["rois"], {"imageSize": [height, width], "rois": rois})
    _save(entity, options["output"], np.load(plane / "F.npy")[keep].T.astype(np.float64), context)
    _save(entity, options["neuropilOutput"], np.load(plane / "Fneu.npy")[keep].T.astype(np.float64), context)
    return {"rois": len(rois), "frames": frames}


def _load_stack(entity, name, context):
    stack = np.asarray(context.project.load(entity, name))
    if stack.ndim == 2:
        stack = stack[:, :, None]
    if stack.ndim != 3:
        raise NansenError("invalid-data", f"{name} is {stack.shape}; ophys methods take one channel, height x width x frames")
    return stack


def _as_traces(data):
    traces = np.asarray(data, dtype=np.float64)
    return traces[:, None] if traces.ndim == 1 else traces


def _save(entity, name, data, context):
    if name:
        context.project.save(entity, name, data)


def _name(entity):
    return " / ".join(map(str, entity.key.values()))
