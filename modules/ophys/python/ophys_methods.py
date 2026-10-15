"""Python implementations of the ophys module's methods.

Stacks are height x width x frames, in both languages: stack[y, x, t] here is stack(y+1, x+1, t+1) in
MATLAB, and .npy files keep that indexing. The MATLAB implementations in matlab/+ophys compute the
same values the same way; numbers that are returned are rounded with round_to, as there.
"""

import json
import math
from pathlib import Path

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
    document = context.project.load(entity, options["rois"])
    kept = [roi for roi in document.get("rois", []) if options["includeRejected"] or roi.get("classification") != "rejected"]
    masks = roi_masks(dict(document, rois=kept), height, width)
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
    return {"rois": len(masks), "frames": frames, "ids": [roi.get("id", n + 1) for n, roi in enumerate(kept)],
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


def deconvolve(entity, options, context):
    """Spikes and denoised calcium of each trace by OASIS for an AR(1) model (Friedrich et al. 2017)."""
    traces = _as_traces(context.project.load(entity, options["signals"]))
    rate = options["frameRate"] or entity.get("frame_rate")
    if not rate:
        raise NansenError("invalid-options", "give frameRate, or fill in the entity's frame_rate")
    g = math.exp(-1.0 / (options["tauDecay"] * float(rate)))
    frames, rois = traces.shape
    spikes = np.full(traces.shape, np.nan)
    calcium = np.full(traces.shape, np.nan)
    noise = []
    for i in range(rois):
        context.check_cancelled()
        trace = traces[:, i]
        sigma = noise_level(trace)
        noise.append(sigma)
        if frames and not np.isnan(trace).any():
            calcium[:, i], spikes[:, i] = oasis_ar1(trace, g, options["sparsity"] * sigma)
        context.progress((i + 1) / max(rois, 1), f"ROI {i + 1}/{rois}")
    _save(entity, options["output"], spikes, context)
    _save(entity, options["denoisedOutput"], calcium, context)
    context.log(f"{_name(entity)}: deconvolved {rois} traces, decay factor {g:.4f} per frame")
    return {"rois": rois, "frames": frames, "noise": [round_to(v, 4) for v in noise],
            "spikeSum": [round_to(np.sum(spikes[:, i]), 3) for i in range(rois)],
            "maxCalcium": [round_to(np.max(calcium[:, i]) if frames else np.nan, 3) for i in range(rois)]}


def noise_level(trace):
    """The noise of a trace from its frame-to-frame differences: median(|diff|) / (0.6745 * sqrt(2)); NaN if any value is."""
    if len(trace) < 2 or np.isnan(trace).any():
        return float("nan")
    return _median(np.abs(np.diff(trace))) / (0.6745 * math.sqrt(2))


def _median(values):
    ordered = np.sort(values)
    n = len(ordered)
    return float(ordered[n // 2]) if n % 2 else float((ordered[n // 2 - 1] + ordered[n // 2]) / 2)


def oasis_ar1(y, g, lam):
    """Denoised calcium c and spikes s minimising 1/2 |c - y|^2 + lam * sum(s), s_t = c_t - g c_(t-1) >= 0, c_0 = s_0 >= 0.

    Pools of frames share one exponential decay; a pool whose start would need a negative spike is merged
    with the one before (pool adjacent violators). Powers of g are products, as MATLAB computes them.
    """
    frames = len(y)
    powers = np.cumprod(np.concatenate([[1.0], np.full(2 * frames, g)]))
    target = np.asarray(y, dtype=np.float64) - lam * (1 - g)
    target[-1] = y[-1] - lam
    values, weights, starts, lengths = [], [], [], []
    for t in range(frames):
        values.append(float(target[t]))
        weights.append(1.0)
        starts.append(t)
        lengths.append(1)
        while len(values) > 1:
            previous = values[-2] if len(values) > 2 else max(values[-2], 0.0)  # c_0 >= 0
            if values[-1] >= powers[lengths[-2]] * previous:
                break
            span = lengths[-2]
            weight = weights[-2] + weights[-1] * powers[2 * span]
            values[-2] = (values[-2] * weights[-2] + values[-1] * weights[-1] * powers[span]) / weight
            weights[-2] = weight
            lengths[-2] = span + lengths[-1]
            del values[-1], weights[-1], starts[-1], lengths[-1]
    calcium = np.zeros(frames)
    for value, start, length in zip(values, starts, lengths):
        calcium[start:start + length] = max(value, 0.0) * powers[:length]
    spikes = calcium.copy()
    spikes[1:] = calcium[1:] - g * calcium[:-1]
    return calcium, spikes


def caiman_deconvolution(entity, options, context):
    """Spikes and denoised calcium of each trace by CaImAn's constrained foopsi."""
    try:
        from caiman.source_extraction.cnmf.deconvolution import constrained_foopsi
    except ImportError as error:
        raise NansenError("dependency-missing", f"ophys.caiman_deconvolution needs CaImAn ({error}): see https://github.com/flatironinstitute/CaImAn") from None
    traces = _as_traces(context.project.load(entity, options["signals"]))
    frames, rois = traces.shape
    spikes = np.full(traces.shape, np.nan)
    calcium = np.full(traces.shape, np.nan)
    for i in range(rois):
        context.check_cancelled()
        if not np.isnan(traces[:, i]).any():
            c, _, _, _, _, s, _ = constrained_foopsi(traces[:, i], p=options["order"])
            calcium[:, i], spikes[:, i] = c, s
        context.progress((i + 1) / max(rois, 1), f"ROI {i + 1}/{rois}")
    _save(entity, options["output"], spikes, context)
    _save(entity, options["denoisedOutput"], calcium, context)
    return {"rois": rois, "frames": frames}


def deep_interpolation(entity, options, context):
    """Denoise the stack with DeepInterpolation and a trained model.

    Each frame is predicted from preFrames before and postFrames after it (leaving omittedFrames out next to
    it); frames too close to the start or end to be predicted are kept as they were. Uses DeepInterpolation's
    generator and inference classes (0.2) or its command line inference (0.1).
    """
    try:
        import h5py
        import deepinterpolation  # noqa: F401
    except ImportError as error:
        raise NansenError("dependency-missing",
                          f"ophys.deep_interpolation needs deepinterpolation and h5py ({error}): see https://github.com/AllenInstitute/deepinterpolation") from None
    model = Path(options["modelPath"]).expanduser()
    if not model.is_file():
        raise NansenError("invalid-options", f"there is no model file {model}")
    import tempfile
    stack = _load_stack(entity, options["stack"], context)
    frames = stack.shape[2]
    before = options["preFrames"] + options["omittedFrames"]
    after = options["postFrames"] + options["omittedFrames"]
    if frames <= before + after:
        raise NansenError("invalid-data", f"{frames} frames are too few for {before + after} frames around each predicted one")
    with tempfile.TemporaryDirectory() as folder:
        source, target = Path(folder) / "input.h5", Path(folder) / "output.h5"
        with h5py.File(source, "w") as f:
            f.create_dataset("data", data=np.moveaxis(np.asarray(stack), 2, 0).astype(np.float32))
        generator = {"movie_path": str(source), "train_path": str(source), "batch_size": 8, "steps_per_epoch": -1,  # <= 0: batches in order, not advanced per epoch
                     "pre_frame": options["preFrames"], "post_frame": options["postFrames"],
                     "pre_post_omission": options["omittedFrames"], "start_frame": 0, "end_frame": -1, "randomize": False}
        context.log(f"{_name(entity)}: running DeepInterpolation on {frames} frames")
        try:
            from deepinterpolation.generator_collection import OphysGenerator
            from deepinterpolation.inference_collection import core_inference
            core_inference({"model_path": str(model), "output_file": str(target), "output_padding": True},
                           OphysGenerator(generator)).run()
        except ImportError:
            from deepinterpolation.cli.inference import Inference
            Inference(input_data={"inference_params": {"model_source": {"local_path": str(model)}, "output_file": str(target)},
                                  "generator_params": dict(generator, data_path=str(source), name="OphysGenerator"),
                                  "run_uid": "nansen", "output_full_args": False}, args=[]).run()
        with h5py.File(target, "r") as f:
            predicted = np.asarray(f["data"], dtype=np.float32)
    out = np.asarray(stack, dtype=np.float32).copy()
    count = min(predicted.shape[0], frames) - before
    out[:, :, before:before + count] = np.moveaxis(predicted[before:before + count], 0, 2)
    _save(entity, options["output"], out, context)
    return {"frames": frames, "height": out.shape[0], "width": out.shape[1], "predicted": int(count)}

def denoise(entity, options, context):
    """Gaussian smoothing in space and in time, with the weights renormalised at the edges."""
    stack = _load_stack(entity, options["stack"], context)
    out = stack.astype(np.float64)
    for axis, sigma in ((0, options["spatialSigma"]), (1, options["spatialSigma"]), (2, options["temporalSigma"])):
        context.check_cancelled()
        out = gaussian_along(out, axis, sigma)
    out = out.astype(np.float32)
    _save(entity, options["output"], out, context)
    height, width, frames = out.shape
    context.log(f"{_name(entity)}: smoothed {frames} frames")
    return {"frames": frames, "height": height, "width": width, "meanIntensity": round_to(out.astype(np.float64).mean(), 4)}


def gaussian_along(data, axis, sigma):
    """data smoothed along one axis by a Gaussian of sigma samples, cut at 3 sigma; at the ends the weights that
    fall inside are renormalised. Offsets are added from -radius to radius, as in MATLAB."""
    if sigma <= 0 or data.shape[axis] < 2:
        return data
    radius = int(math.ceil(3 * sigma))
    size = data.shape[axis]
    total = np.zeros_like(data)
    norm = np.zeros(size)
    for offset in range(-radius, radius + 1):
        weight = math.exp(-offset * offset / (2 * sigma * sigma))
        here = slice(max(0, -offset), min(size, size - offset))
        there = slice(max(0, offset), min(size, size + offset))
        index_here = [slice(None)] * data.ndim
        index_there = [slice(None)] * data.ndim
        index_here[axis], index_there[axis] = here, there
        total[tuple(index_here)] += weight * data[tuple(index_there)]
        norm[here] += weight
    shape = [1] * data.ndim
    shape[axis] = size
    return total / norm.reshape(shape)


def align_sessions(entities, options, context):
    """Align each entity's FOV image to the first entity's, and copy the first entity's ROIs, moved, to the others."""
    if not entities:
        raise NansenError("no-entities", "no entities to align")
    reference_image = _image(context.project.load(entities[0], options["image"]))
    height, width = reference_image.shape
    reference_fft = np.conj(np.fft.fft2(reference_image)) * _smoothing(height, width)
    document = context.project.load(entities[0], options["rois"])
    rois = [roi for roi in document.get("rois", []) if roi.get("classification") != "rejected"]
    shifts, migrated = [], 0
    for number, entity in enumerate(entities):
        context.check_cancelled()
        image = _image(context.project.load(entity, options["image"]))
        if image.shape != (height, width):
            raise NansenError("invalid-data", f"{_name(entity)}: the image is {image.shape}, the reference {(height, width)}")
        dy, dx = (int(v) for v in estimate_shifts(image[:, :, None], reference_fft, options["maxShift"])[0])
        shifts.append({"key": entity.key, "shift": [dy, dx]})
        if number > 0:
            moved = []
            for roi in rois:
                pixels = [(int(y) + dy, int(x) + dx) for y, x in np.asarray(roi["pixels"]).reshape(-1, 2)]
                pixels = sorted(p for p in pixels if 0 <= p[0] < height and 0 <= p[1] < width)
                if pixels:
                    moved.append(_roi(roi.get("id", len(moved) + 1), pixels))
            context.project.save(entity, options["output"], {"imageSize": [height, width], "rois": moved})
            migrated += 1
        context.progress((number + 1) / len(entities), _name(entity))
    context.log(f"aligned {len(entities)} entities to {_name(entities[0])}")
    return {"reference": entities[0].key, "shifts": shifts, "migrated": migrated, "rois": len(rois)}


def _image(data):
    image = np.asarray(data, dtype=np.float64)
    if image.ndim == 3:
        image = image.mean(axis=2)
    if image.ndim != 2:
        raise NansenError("invalid-data", f"an image is height x width (or a stack to average), not {image.shape}")
    return image


ATLAS = Path(__file__).resolve().parents[1] / "atlas" / "dorsal_cortex.json"


def fov_region(entity, options, context):
    """The atlas region at the entity's FOV position (fov_ml, fov_ap)."""
    ml, ap = entity.get("fov_ml"), entity.get("fov_ap")
    if ml is None or ap is None:
        return {"brain_region": None}
    with open(ATLAS, encoding="utf-8") as f:
        atlas = json.load(f)
    return {"brain_region": atlas_region(atlas, float(ml), float(ap))}


def atlas_region(atlas, ml, ap):
    """The label of the region at (ml, ap) mm, or None outside every region."""
    column = math.floor((ml - atlas["origin"][0]) * atlas["pixelsPerMm"])
    row = math.floor((ap - atlas["origin"][1]) * atlas["pixelsPerMm"])
    if not (0 <= row < atlas["height"] and 0 <= column < atlas["width"]):
        return None
    runs = atlas["rows"][row]
    end = 0
    for k in range(0, len(runs), 2):
        end += runs[k + 1]
        if column < end:
            labels = {region["index"]: region["label"] for region in atlas["regions"]}
            return labels.get(runs[k])
    return None


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
    ("RoiSignals_Deconvolved", "Deconvolved spikes", "roi_signals_deconvolved.npy", "npy", "RoiSignals"),
    ("RoiSignals_Denoised", "Denoised calcium", "roi_signals_denoised.npy", "npy", "RoiSignals"),
    ("TwoPhotonSeries_Denoised", "Denoised stack", "two_photon_series_denoised.npy", "npy", "ImageStack"),
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
        wanted = [(entity_type, f) for f in ("ophys.imaging", "ophys.image_stats", "ophys.fov_position", "ophys.fov_region")]
        if options["subjectType"] in project.entity_types:
            wanted += [(options["subjectType"], "ophys.cranial_window"), (options["subjectType"], "ophys.injection")]
        for owner, fragment_id in wanted:
            if fragment_id not in project.entity_type(owner).get("fragments", []):
                project.attach_fragment(owner, fragment_id)
                columns.append(fragment_id)
    context.log(f"added {len(created)} data variables to {entity_type}")
    return {"created": created, "existing": existing, "fragments": columns}


def suite2p(entity, options, context):
    """Run suite2p on the stack and keep its cells as ROIs, with their signals and spikes.

    Works with suite2p 1.x (default_settings / default_db, torch on the GPU when there is one) and 0.x
    (default_ops). Registration blocks are made to fit small frames.
    """
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
    side = min(height, width)
    block = max(16, min(128, 2 ** int(math.floor(math.log2(max(side // 2, 1))))))  # a block must be smaller than the frame
    context.log(f"{_name(entity)}: running suite2p in {folder}")
    if hasattr(s2p, "default_settings"):  # suite2p 1.x
        settings = s2p.default_settings()
        try:
            import torch
            settings["torch_device"] = "cuda" if torch.cuda.is_available() else "cpu"
        except ImportError:
            settings["torch_device"] = "cpu"
        settings["fs"] = float(options["framesPerSecond"])
        settings["diameter"] = [float(options["cellDiameter"])] * 2
        settings["registration"]["block_size"] = (block, block)
        settings["registration"]["nimg_init"] = min(settings["registration"]["nimg_init"], frames)
        settings["detection"]["block_size"] = (min(64, block), min(64, block))
        db = s2p.default_db()
        db.update(data_path=[str(folder)], file_list=["input.tif"], save_path0=str(folder))
        s2p.run_s2p(db=db, settings=settings)
    else:  # suite2p 0.x
        ops = s2p.default_ops()
        ops.update({"fs": options["framesPerSecond"], "diameter": options["cellDiameter"], "nchannels": 1, "nplanes": 1,
                    "block_size": [block, block], "nimg_init": min(ops.get("nimg_init", 200), frames)})
        s2p.run_s2p(ops=ops, db={"data_path": [str(folder)], "tiff_list": ["input.tif"], "save_path0": str(folder)})
    plane = folder / "suite2p" / "plane0"
    stat = np.load(plane / "stat.npy", allow_pickle=True)
    keep = np.load(plane / "iscell.npy")[:, 0] > 0 if options["onlyCells"] else np.ones(len(stat), dtype=bool)
    rois = [_roi(n + 1, sorted(zip(cell["ypix"].tolist(), cell["xpix"].tolist())))
            for n, cell in enumerate(c for c, k in zip(stat, keep) if k)]
    context.project.save(entity, options["rois"], {"imageSize": [height, width], "rois": rois})
    _save(entity, options["output"], np.load(plane / "F.npy")[keep].T.astype(np.float64), context)
    _save(entity, options["neuropilOutput"], np.load(plane / "Fneu.npy")[keep].T.astype(np.float64), context)
    _save(entity, options["spikesOutput"], np.load(plane / "spks.npy")[keep].T.astype(np.float64), context)
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
