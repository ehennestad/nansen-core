"""Python implementations of the ophys module's methods.

Stacks are height x width x frames, in both languages: stack[y, x, t] here is stack(y+1, x+1, t+1) in
MATLAB, and .npy files keep that indexing. The MATLAB implementations in matlab/+ophys compute the
same values the same way; numbers that are returned are rounded with round_to, as there.
"""

import json
import math
import re
from pathlib import Path

import numpy as np

from nansen.errors import NansenError
from nansen.stacks import as_stack

SMOOTHING = 1.15  # pixels: the phase correlation is smoothed by a Gaussian of this width, as suite2p does
CHUNK = 100       # frames handled at a time
UPSAMPLE = 20     # subpixel shifts are found to 1/UPSAMPLE of a pixel


def round_to(value, digits):
    """value rounded to digits decimals, half away from zero in the scaled value; None for NaN or infinity."""
    value = float(value)
    if not math.isfinite(value):
        return None
    scale = 10.0 ** digits
    return math.floor(value * scale + 0.5) / scale


def image_stats(entity, options, context):
    """Size and intensity of the stack; saves its average and maximum projections, and each frame's mean, minimum,
    maximum and standard deviation (frames x 4, as dev's per-frame image stats, for plotting). Reads a chunk at a time.
    With plane 0, of every plane: the intensity of them all and of each, the projections as height x width x 1 x
    planes x 1 (a stack of one frame per plane) and the frame statistics of the planes joined (frames x 4 planes)."""
    _, stacks, every = _plane_stacks(entity, options["stack"], context, options)
    height, width, frames = stacks[0].shape
    found = [_image_stats(stack) for stack in stacks]   # (average, maximum, frame statistics, total) of each plane
    _save_planes(entity, options["averageOutput"], [f[0] for f in found], every, context)
    _save_planes(entity, options["maximumOutput"], [f[1] for f in found], every, context)
    _save(entity, options.get("frameStatsOutput", ""), np.concatenate([f[2] for f in found], axis=1), context)
    context.log(f"{_name(entity)}: {frames} frames of {height} x {width}" + (f" in {len(stacks)} planes" if every else ""))
    size = height * width * frames
    result = {"n_frames": frames, "height": height, "width": width,
              "mean_intensity": round_to(sum(f[3] for f in found) / (size * len(found)), 4),
              "max_intensity": max(float(f[1].max()) for f in found)}
    if every:
        result["planes"] = [{"plane": n + 1, "mean_intensity": round_to(f[3] / size, 4), "max_intensity": float(f[1].max())}
                            for n, f in enumerate(found)]
    return result


def _image_stats(stack):
    """The average and maximum projections of a height x width x frames stack, each frame's mean, minimum, maximum
    and standard deviation, and the sum of its values, read a chunk at a time."""
    height, width, frames = stack.shape
    maximum = None
    average = np.zeros((height, width))
    per_frame = np.zeros((frames, 4))
    for start in range(0, frames, CHUNK):
        chunk = stack[:, :, start:start + CHUNK]
        flat = chunk.reshape(height * width, -1).astype(np.float64)
        per_frame[start:start + flat.shape[1]] = np.stack([flat.mean(axis=0), flat.min(axis=0), flat.max(axis=0), flat.std(axis=0)], axis=1)
        average += chunk.astype(np.float64).sum(axis=2)
        peak = chunk.max(axis=2)
        maximum = peak if maximum is None else np.maximum(maximum, peak)
    total = float(average.sum())
    return average / frames, maximum, per_frame, total


def motion_correction(entity, options, context):
    """Align each frame to a reference by the shift of largest (smoothed) phase correlation.

    Rigid by default, in whole pixels. With subpixel, the peak is refined by a parabola through it and its
    neighbours along each axis, and frames are moved by bilinear interpolation. With patches > 1, the frame is
    also cut into patches x patches patches, each of which finds its own shift within maxDeviation of the
    frame's whole-pixel shift; the shift of each pixel is interpolated bilinearly between the patch centres
    (piecewise rigid, as NoRMCorre). The stack is read a chunk at a time and the aligned stack written the
    same way, so a recording need not fit in memory. Each iteration but the last makes the next reference:
    the average of the frames aligned. In a stack with channels, the shifts are found in the options' channel
    and every channel is aligned by them; in one with planes, the options' plane is aligned (height x width x
    channels x frames), or with plane 0 every plane, each by its own reference and shifts, one plane after the
    other in each chunk (height x width x channels x planes x frames; the planes' shifts joined along their last
    axis). Only the frames firstFrame..lastFrame are aligned and written.
    """
    whole, stacks, every = _plane_stacks(entity, options["stack"], context, options)
    height, width, frames = stacks[0].shape
    flyback = int(options.get("numFlybackLines", 0))
    if flyback >= height - 1:
        raise NansenError("invalid-options", f"{flyback} flyback lines leave too little of a frame of {height} rows")
    plan, zoom = None, None
    if options.get("stretchCorrection", "none") == "sciscan":
        zoom = float(options.get("zoomFactor", 0)) or whole.metadata.get("zoomFactor")
        if not zoom:
            raise NansenError("invalid-options", "the recording does not give its zoom factor: set zoomFactor for the stretch correction")
        displacement, zoom = stretch_profile(width, zoom)
        plan = destretch_plan(displacement)
        width = len(plan[0])
    elif options.get("stretchCorrection", "none") != "none":
        raise NansenError("invalid-options", f"stretchCorrection is none or sciscan, not {options['stretchCorrection']!r}")
    mode = options.get("bidirectionalCorrection", "none")
    preparations = [scan_preparation(stack, flyback, mode, int(options.get("maxBidirectionalOffset", 10)), plan) for stack in stacks]
    height -= flyback
    subpixel = bool(options.get("subpixel", False))
    patches = int(options.get("patches", 1))
    deviation = int(options.get("maxDeviation", 3))
    if patches > 1 and (height // patches < 4 or width // patches < 4):
        raise NansenError("invalid-options", f"{patches} x {patches} patches of a {height} x {width} frame are smaller than 4 pixels")
    row_edges, column_edges = patch_edges(height, patches), patch_edges(width, patches)
    weights = (_axis_weights(row_edges, height), _axis_weights(column_edges, width))
    tapered = subpixel or patches > 1   # whole-pixel rigid alignment works on the frames as they are
    count = min(options["referenceFrames"], frames)
    output_type = options.get("outputType", "same")
    planes = []   # each plane aligned: its stack, the frames written (with every channel), preparation and reference
    for number, (stack, (prepare, offsets)) in enumerate(zip(stacks, preparations)):
        if whole.ndim == 5:
            target = whole.select(slice(None), slice(None), slice(None), number if every else options.get("plane", 1) - 1)
        else:
            target = whole if whole.ndim == 4 else stack
        planes.append({"stack": stack, "target": target, "prepare": prepare, "offsets": offsets,
                       "reference": prepare(stack.frames(0, count), 0).astype(np.float64).mean(axis=2),
                       "recast": _recaster(prepare(stack.frames(0, min(CHUNK, frames)), 0), output_type, float(options.get("saturation", 0.5)))})
    target = planes[0]["target"]
    shape = (height, width) + tuple(target.shape[2:-1]) + ((len(planes),) if every else ()) + (frames,)
    dtype = target.dtype if output_type == "same" else np.dtype(output_type)
    iterations = options["iterations"]
    for iteration in range(iterations):
        last = iteration == iterations - 1
        for plane in planes:
            reference = plane["reference"]
            plane["shifts"] = np.zeros((frames, 2, patches, patches))
            plane["reference_fft"] = _reference_fft(reference, tapered)
            plane["patch_ffts"] = [[_reference_fft(reference[r0:r1, c0:c1], True) for c0, c1 in zip(column_edges, column_edges[1:])]
                                   for r0, r1 in zip(row_edges, row_edges[1:])]
            plane["total"] = np.zeros((height, width))
        with (context.project.stack_writer(entity, options["output"], shape, dtype) if last else _NoWriter()) as out:
            for start in range(0, frames, CHUNK):
                context.check_cancelled()
                stop = min(start + CHUNK, frames)
                aligned = []
                for plane in planes:
                    shifts, prepare = plane["shifts"], plane["prepare"]
                    chunk = prepare(plane["stack"].frames(start, stop), start)
                    if patches == 1:
                        shifts[start:stop, :, 0, 0] = estimate_shifts(chunk, plane["reference_fft"], options["maxShift"], subpixel, tapered)
                    else:
                        rigid = estimate_shifts(chunk, plane["reference_fft"], options["maxShift"], tapered=True)
                        shifts[start:stop] = estimate_patch_shifts(chunk, plane["patch_ffts"], row_edges, column_edges, rigid,
                                                                   options["maxShift"], deviation, subpixel)
                    here = shifts[start:stop]
                    if not last:
                        plane["total"] += align_frames(chunk, here, weights, subpixel).astype(np.float64).sum(axis=2)
                    elif plane["target"] is plane["stack"]:
                        aligned.append(plane["recast"](align_frames(chunk, here, weights, subpixel)))
                    else:
                        channels = prepare(plane["target"].frames(start, stop), start)
                        aligned.append(plane["recast"](np.stack([align_frames(channels[:, :, c, :], here, weights, subpixel)
                                                                 for c in range(channels.shape[2])], axis=2)))
                if last:
                    out.write(start, np.stack(aligned, axis=-2) if every else aligned[0])
                context.progress((iteration * frames + stop) / (iterations * frames), f"iteration {iteration + 1}: frame {stop}/{frames}")
        for plane in planes:
            plane["reference"] = plane["total"] / frames
    saved, found = [], []
    for plane in planes:
        shifts = plane["shifts"]
        kept = shifts[:, :, 0, 0] if patches == 1 else shifts.reshape(frames, 2, patches * patches)   # patch (i, j) is i * patches + j
        saved.append(kept if subpixel else kept.astype(np.int32))
        found.append(_shift_summary(shifts, subpixel))
        if mode != "none":
            found[-1]["bidirectionalOffset"] = plane["offsets"][0]
    _save(entity, options["shiftsOutput"], np.concatenate(saved, axis=-1) if every else saved[0], context)
    if every:
        result = dict(frames=frames, **_shift_summary(np.stack([plane["shifts"] for plane in planes]), subpixel),
                      planes=[dict(plane=n + 1, **summary) for n, summary in enumerate(found)])
    else:
        result = dict(frames=frames, **found[0])
    context.log(f"{_name(entity)}: largest shift {result['maxShift']} px")
    if plan is not None:
        result["stretchZoom"] = zoom
    return result


def _shift_summary(shifts, subpixel):
    """The largest shift and the mean distance moved of shifts (... x 2 x patches x patches: rows and columns on the
    axis before the patches'), rounded as motion_correction returns them."""
    distance = np.sqrt(shifts[..., 0, :, :] ** 2 + shifts[..., 1, :, :] ** 2)
    largest = float(np.abs(shifts).max(initial=0))
    if subpixel:   # found to 1/UPSAMPLE of a pixel, and good to about a tenth
        return {"maxShift": round_to(largest, 1), "meanShift": round_to(distance.mean(), 1)}
    return {"maxShift": int(largest), "meanShift": round_to(distance.mean(), 4)}


STRETCH = Path(__file__).resolve().parents[1] / "calibration" / "sciscan_stretch.json"


def stretch_profile(width, zoom):
    """dev's displacement of each column of a SciScan line of width pixels at the zoom factor (its resonant scanner's
    stretch, measured on a microgrid): that zoom's profile, or else the nearest zoom's (of two, the smaller), and its zoom."""
    with open(STRETCH, encoding="utf-8") as f:
        profiles = json.load(f)["profiles"]
    fits = [p for p in profiles if p["width"] == width]
    if not fits:
        widths = sorted({p["width"] for p in profiles})
        raise NansenError("invalid-options", f"there is no stretch profile for lines of {width} pixels, only of {widths}")
    best = min(fits, key=lambda p: (abs(p["zoom"] - zoom), p["zoom"]))
    return np.array(best["displacement"], dtype=np.float64), float(best["zoom"])


def destretch_plan(displacement):
    """For each column of the corrected line, the raw column left of where it comes from (from 0) and the weight of the
    one right of it. Raw column c lands at c - displacement[c]; the corrected line is the whole positions from the
    first raw column's to the last's, each read from the raw line by linear interpolation at the inverse of that map."""
    width = len(displacement)
    position = np.arange(width, dtype=np.float64) - displacement
    if not np.all(np.diff(position) > 0):
        raise NansenError("invalid-data", "the stretch profile does not keep the columns in order")
    targets = np.arange(math.ceil(position[0]), math.floor(position[-1]) + 1, dtype=np.float64)
    c = np.clip(np.searchsorted(position, targets, side="right") - 1, 0, width - 2)   # position[c] <= target
    source = c + (targets - position[c]) / (position[c + 1] - position[c])
    left = np.clip(np.floor(source).astype(np.int64), 0, width - 2)
    return left, source - left


def destretch(chunk, plan):
    """The frames' lines (axis 1) as the plan reads them: (1 - w) of the left column and w of the right one, integers
    rounded half up, in the frames' type."""
    left, weight = plan
    shape = (1, len(weight)) + (1,) * (chunk.ndim - 2)
    w = weight.reshape(shape)
    out = chunk[:, left].astype(np.float64) * (1 - w) + chunk[:, left + 1].astype(np.float64) * w
    if np.issubdtype(chunk.dtype, np.integer):
        out = np.floor(out + 0.5)
    return out.astype(chunk.dtype)


def scan_preparation(stack, flyback, mode, most, plan=None):
    """What is done to each chunk of frames (starting at frame start) before it is aligned: the first flyback
    rows are left out, the lines are destretched by the plan (destretch_plan) when there is one, and the lines
    scanned back (rows 1, 3, ...) are moved by the column offset between them and the lines scanned forth, as
    resonant scanners need. With mode "constant" the offset is found once, in the first chunk; with "continuous"
    in each chunk. Returns the function and the offsets found, by chunk."""
    offsets = {}

    def cut(chunk):
        chunk = chunk[flyback:]
        return chunk if plan is None else destretch(chunk, plan)

    def offset_for(start):
        key = 0 if mode == "constant" else start
        if key not in offsets:
            first = cut(stack.frames(key, min(key + CHUNK, stack.shape[-1])))
            offsets[key] = bidirectional_offset(first.astype(np.float64).reshape(first.shape[0], first.shape[1], -1).mean(axis=2), most)
        return offsets[key]

    def prepare(chunk, start):
        chunk = cut(chunk)
        if mode == "none":
            return chunk
        return shift_alternate_rows(chunk, offset_for(start))

    if mode not in ("none", "constant", "continuous"):
        raise NansenError("invalid-options", f"bidirectionalCorrection is none, constant or continuous, not {mode!r}")
    return prepare, offsets


def bidirectional_offset(image, most):
    """The column offset k of the lines scanned back (rows 1, 3, ...) from those scanned forth (rows 0, 2, ...):
    the k within most whose shift makes the two sets of lines correlate best (Pearson, over the columns both
    cover); of equal ones, the smallest, then the negative."""
    forth, back = image[0::2], image[1::2]
    rows = min(forth.shape[0], back.shape[0])
    forth, back = forth[:rows], back[:rows]
    width = image.shape[1]
    best, offset = -np.inf, 0
    for k in sorted(range(-most, most + 1), key=lambda k: (abs(k), k)):
        first, stop = max(0, -k), min(width, width - k)
        if stop - first < 2:
            continue
        score = _pearson(forth[:, first:stop], back[:, first + k:stop + k])
        if score > best:
            best, offset = score, k
    return offset


def shift_alternate_rows(chunk, k):
    """Rows 1, 3, ... moved by -k columns: out[r, c] = chunk[r, c + k] on those rows, 0 outside the frame."""
    if not k:
        return chunk
    out = np.array(chunk, copy=True)
    width = chunk.shape[1]
    out[1::2] = 0
    first, stop = max(0, -k), min(width, width - k)
    out[1::2, first:stop] = chunk[1::2, first + k:stop + k]
    return out


def _recaster(sample, output_type, saturation):
    """The aligned frames as output_type: the same, or uint8 or uint16 scaled from the saturation and 100 -
    saturation percentiles of a sample of frames to the type's full range, rounded half up."""
    if output_type == "same":
        return lambda frames: frames
    if output_type not in ("uint8", "uint16"):
        raise NansenError("invalid-options", f"outputType is same, uint8 or uint16, not {output_type!r}")
    values = sample.astype(np.float64).reshape(-1, 1)
    low, high = float(_percentile(values, saturation)[0]), float(_percentile(values, 100 - saturation)[0])
    top = float(np.iinfo(output_type).max)

    def recast(frames):
        if not high > low:
            return np.zeros(frames.shape, dtype=output_type)
        scaled = np.floor((frames.astype(np.float64) - low) / (high - low) * top + 0.5)
        return np.clip(scaled, 0, top).astype(output_type)
    return recast


class _NoWriter:
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def estimate_shifts(frames, reference_fft, max_shift, subpixel=False, tapered=False):
    """(rows, columns) each frame of a height x width x n stack is displaced from the reference: n x 2.

    reference_fft is the conjugate of the reference's 2-D FFT times the smoothing. The peak is looked for
    within max_shift (and less than half the frame); of equal peaks, the one of smallest row shift, then
    column shift, wins. With subpixel, the peak is refined (see _peak). With tapered, the frames are taken
    less their mean and weighted by the taper, as the reference must have been.
    """
    height, width = frames.shape[:2]
    if tapered:
        frames = _tapered(frames)
    correlation, product = _correlation(frames, reference_fft)
    rows = _shift_range(0, max_shift, max_shift, (height - 1) // 2)
    columns = _shift_range(0, max_shift, max_shift, (width - 1) // 2)
    peaks = [_peak(correlation[:, :, t], product[:, :, t], rows, columns, subpixel) for t in range(frames.shape[2])]
    return np.array(peaks, dtype=np.float64 if subpixel else np.int64).reshape(-1, 2)


def estimate_patch_shifts(frames, patch_ffts, row_edges, column_edges, rigid, max_shift, deviation, subpixel):
    """The shift of each patch of each frame: n x 2 x patches x patches. A patch's peak is looked for within
    deviation of the frame's whole-pixel shift (rigid, n x 2), within max_shift and less than half the patch;
    where that leaves nothing, the patch takes the frame's shift."""
    n = frames.shape[2]
    patches = len(row_edges) - 1
    shifts = np.zeros((n, 2, patches, patches))
    for i, (r0, r1) in enumerate(zip(row_edges, row_edges[1:])):
        for j, (c0, c1) in enumerate(zip(column_edges, column_edges[1:])):
            correlation, product = _correlation(_tapered(frames[r0:r1, c0:c1, :]), patch_ffts[i][j])
            for t in range(n):
                rows = _shift_range(int(rigid[t, 0]), deviation, max_shift, (r1 - r0 - 1) // 2)
                columns = _shift_range(int(rigid[t, 1]), deviation, max_shift, (c1 - c0 - 1) // 2)
                if rows.size and columns.size:
                    shifts[t, :, i, j] = _peak(correlation[:, :, t], product[:, :, t], rows, columns, subpixel)
                else:
                    shifts[t, :, i, j] = rigid[t]
    return shifts


def _correlation(frames, reference_fft):
    """The (whitened, smoothed) phase correlation of each frame of a stack with the reference, and the
    cross-power spectrum it is the inverse FFT of."""
    product = np.fft.fft2(frames.astype(np.float64), axes=(0, 1)) * reference_fft[:, :, None]
    product /= np.maximum(np.abs(product), 1e-12)
    return np.real(np.fft.ifft2(product, axes=(0, 1))), product


def _shift_range(centre, deviation, max_shift, half):
    """The whole-pixel shifts within deviation of centre, max_shift of 0 and half the size of the frame."""
    limit = min(max_shift, half)
    return np.arange(max(centre - deviation, -limit), min(centre + deviation, limit) + 1)


def _peak(correlation, product, rows, columns, subpixel):
    """(dy, dx) of the largest correlation among the shifts rows x columns (the first in row-major order of
    equal ones). With subpixel, refined as NoRMCorre does: the correlation is computed on a grid of
    1/UPSAMPLE pixel within a pixel of that peak, from the cross-power spectrum (product), and its largest
    value taken (the first in row-major order of equal ones)."""
    height, width = correlation.shape
    window = correlation[np.ix_(rows % height, columns % width)]
    best = int(window.argmax())
    dy, dx = int(rows[best // columns.size]), int(columns[best % columns.size])
    if not subpixel:
        return dy, dx
    offsets = np.arange(-UPSAMPLE, UPSAMPLE + 1) / UPSAMPLE
    down = np.exp(2j * np.pi * np.outer(dy + offsets, np.fft.fftfreq(height)))
    across = np.exp(2j * np.pi * np.outer(np.fft.fftfreq(width), dx + offsets))
    values = np.real(down @ product @ across)
    best = int(values.argmax())
    return dy + offsets[best // offsets.size], dx + offsets[best % offsets.size]


def apply_shifts(stack, shifts):
    """Each frame moved back by its shift: out[y, x] = frame[y + dy, x + dx], and 0 outside the frame."""
    height, width = stack.shape[:2]
    aligned = np.zeros_like(stack)
    for t, (dy, dx) in enumerate(shifts):
        dy, dx = int(dy), int(dx)
        aligned[max(0, -dy):min(height, height - dy), max(0, -dx):min(width, width - dx), t] = \
            stack[max(0, dy):min(height, height + dy), max(0, dx):min(width, width + dx), t]
    return aligned


def align_frames(frames, shifts, weights, subpixel):
    """Frames moved back by their shifts (n x 2 x patches x patches): by whole pixels when they are rigid and
    whole, otherwise each pixel by its shift, interpolated between the patch centres, and bilinearly."""
    n = frames.shape[2]
    if shifts.shape[2] == 1 and not subpixel:
        return apply_shifts(frames, shifts[:, :, 0, 0].astype(int))
    if shifts.shape[2] == 1:
        return warp(frames, shifts[:, 0, 0, 0].reshape(n, 1, 1), shifts[:, 1, 0, 0].reshape(n, 1, 1))
    rows, columns = weights
    return warp(frames, np.stack([shift_field(shifts[t, 0], rows, columns) for t in range(n)]),
                np.stack([shift_field(shifts[t, 1], rows, columns) for t in range(n)]))


WARP_TOLERANCE = 1e-6


def warp(frames, dy, dx):
    """out[y, x, t] = frames[y + dy, x + dx, t], interpolated bilinearly, and 0 where that is outside the frame
    (by more than a millionth of a pixel). dy and dx are n x height x width, or n x 1 x 1. Integer stacks are
    rounded half up."""
    height, width, n = frames.shape
    rows, columns = np.mgrid[0:height, 0:width].astype(np.float64)
    out = np.zeros(frames.shape)
    for t in range(n):
        y = rows + dy[t]
        x = columns + dx[t]
        inside = (y > -WARP_TOLERANCE) & (y < height - 1 + WARP_TOLERANCE) & (x > -WARP_TOLERANCE) & (x < width - 1 + WARP_TOLERANCE)
        y = np.clip(y, 0, height - 1)
        x = np.clip(x, 0, width - 1)
        y0, x0 = np.floor(y).astype(int), np.floor(x).astype(int)
        fy, fx = y - y0, x - x0
        y1, x1 = np.minimum(y0 + 1, height - 1), np.minimum(x0 + 1, width - 1)
        f = frames[:, :, t].astype(np.float64)
        value = (1 - fy) * ((1 - fx) * f[y0, x0] + fx * f[y0, x1]) + fy * ((1 - fx) * f[y1, x0] + fx * f[y1, x1])
        out[:, :, t] = np.where(inside, value, 0.0)
    return _like(out, frames.dtype)


def _like(values, dtype):
    """values in dtype: rounded half up, and clipped, for integers."""
    if np.issubdtype(dtype, np.integer):
        info = np.iinfo(dtype)
        return np.clip(np.floor(values + 0.5), info.min, info.max).astype(dtype)
    return values.astype(dtype)


def _tapered(frames):
    """Frames (height x width x n) less their means, weighted by the taper."""
    frames = frames.astype(np.float64)
    return (frames - frames.mean(axis=(0, 1))) * taper(*frames.shape[:2])[:, :, None]


def _reference_fft(reference, tapered):
    """The conjugate FFT of a reference image (tapered, less its mean, when asked), times the smoothing."""
    if tapered:
        reference = _tapered(reference[:, :, None])[:, :, 0]
    return np.conj(np.fft.fft2(reference)) * _smoothing(*reference.shape)


def taper(height, width):
    """A patch's weights before its FFT, so its edges do not count: a Hann window (sin^2) along each axis."""
    return np.outer(np.sin(np.pi * (np.arange(height) + 0.5) / height) ** 2, np.sin(np.pi * (np.arange(width) + 0.5) / width) ** 2)


def patch_edges(size, count):
    """Where count patches of a size start and end: patch i is edges[i]:edges[i + 1]."""
    return [(i * size) // count for i in range(count + 1)]


def _axis_weights(edges, size):
    """For each pixel along an axis: the patches whose centres it lies between, and how far from the first (0..1).
    Pixels before the first centre or after the last take that patch's shift."""
    centres = [(a + b - 1) / 2 for a, b in zip(edges, edges[1:])]
    first, second, share = np.zeros(size, int), np.zeros(size, int), np.zeros(size)
    for y in range(size):
        if y <= centres[0]:
            continue
        if y >= centres[-1]:
            first[y] = second[y] = len(centres) - 1
            continue
        k = max(i for i, c in enumerate(centres) if c <= y)
        first[y], second[y], share[y] = k, k + 1, (y - centres[k]) / (centres[k + 1] - centres[k])
    return first, second, share


def shift_field(patch_shifts, rows, columns):
    """One component of the patches' shifts (patches x patches), interpolated bilinearly to every pixel."""
    r0, r1, fy = rows
    c0, c1, fx = columns
    fy, fx = fy[:, None], fx[None, :]
    s = patch_shifts
    return (1 - fy) * ((1 - fx) * s[np.ix_(r0, c0)] + fx * s[np.ix_(r0, c1)]) + fy * ((1 - fx) * s[np.ix_(r1, c0)] + fx * s[np.ix_(r1, c1)])


def _smoothing(height, width):
    fy = np.fft.fftfreq(height)[:, None]
    fx = np.fft.fftfreq(width)[None, :]
    return np.exp(-2 * np.pi ** 2 * SMOOTHING ** 2 * (fy ** 2 + fx ** 2))


def detect_rois(entity, options, context):
    """ROIs as 4-connected areas of pixels whose average correlation with their 8 neighbours reaches the threshold.
    Reads the stack a chunk at a time (three times). With plane 0, the ROIs of every plane, in one file: each with its
    plane and channel (from 1), the first plane's first, numbered on from one plane to the next."""
    _, stacks, every = _plane_stacks(entity, options["stack"], context, options)
    height, width, _ = stacks[0].shape
    border = options["border"]
    found = []
    for stack in stacks:
        image = correlation_image(stack)
        image[:border] = image[height - border:] = -np.inf
        image[:, :border] = image[:, width - border:] = -np.inf
        found.append([pixels for pixels in components(image >= options["threshold"])
                      if options["minSize"] <= len(pixels) <= options["maxSize"]])
    rois = _placed_rois(found, every, options)
    _save(entity, options["output"], {"imageSize": [height, width], "rois": rois}, context)
    context.log(f"{_name(entity)}: {len(rois)} ROIs")
    result = {"rois": len(rois), "areas": [roi["area"] for roi in rois]}
    if every:
        result["planes"] = [{"plane": n + 1, "rois": len(pixels)} for n, pixels in enumerate(found)]
    return result


def _placed_rois(found, every, options):
    """The ROIs of each plane's pixel lists, numbered from 1 across the planes; with every plane, each ROI with its
    place (its plane, from 1, and the options' channel), as nansen.frames.rois_at reads them."""
    rois = []
    for number, areas in enumerate(found):
        for pixels in areas:
            roi = _roi(len(rois) + 1, pixels)
            if every:
                roi["plane"], roi["channel"] = number + 1, int(options.get("channel", 1))
            rois.append(roi)
    return rois


def correlation_image(stack):
    """Each pixel's average Pearson correlation with its in-frame 8 neighbours over time, read a chunk of frames at a
    time (nansen.frames.local_correlation, the viewer's correlation projection)."""
    from nansen.frames import local_correlation
    return local_correlation(stack)


NEIGHBOURS = {4: ((-1, 0), (1, 0), (0, -1), (0, 1)),
              8: ((-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1))}


def components(mask, connectivity=4):
    """The 4- (or 8-) connected areas of a boolean image, each as its (row, column) pixels in row-major order.

    Areas come in the row-major order of their first pixel.
    """
    height, width = mask.shape
    seen = np.zeros_like(mask, dtype=bool)
    found = []
    steps = NEIGHBOURS[connectivity]
    for seed in np.flatnonzero(mask):
        y, x = divmod(int(seed), width)
        if seen[y, x]:
            continue
        seen[y, x] = True
        pixels, queue = [], [(y, x)]
        while queue:
            y, x = queue.pop()
            pixels.append((y, x))
            for ny, nx in ((y + dy, x + dx) for dy, dx in steps):
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


def quicky(entity, options, context):
    """dev's Quicky (flufinder) ROI detection: cells as places where thresholded activity recurs.

    Frames are binned by their maximum, the smooth background (a circular Gaussian) and the slow
    background (a moving mean over 20 bins) are taken out, and each bin is thresholded at a percentile of
    all values and cleaned with disk-shaped morphology. Connected areas that come back at the same place in
    several bins make an ROI: the most observed pixel picks the areas around it, their centroids within
    3 px of the median, and the ROI is the largest area of their overlap image above the mid-point of its
    50th and 95th percentile, holes filled. ROIs overlapping an earlier one by 75 % or more are left out.
    With plane 0, each plane's ROIs are found on their own (maxRois in each) and saved in one file with their
    places, as detect_rois does.
    """
    _, stacks, every = _plane_stacks(entity, options["stack"], context, options)
    height, width, _ = stacks[0].shape
    found, shaped, areas, bins = [], 0, 0, 0
    for stack in stacks:
        rois, shapes, count, binned = _quicky(stack, options, context)
        found.append(rois)
        shaped += min(shapes, len(rois))
        areas += count
        bins += binned
    rois = _placed_rois(found, every, options)
    _save(entity, options["output"], {"imageSize": [height, width], "rois": rois}, context)
    context.log(f"{_name(entity)}: {len(rois)} ROIs from {areas} areas in {bins} bins")
    result = {"rois": len(rois), "areas": [roi["area"] for roi in rois]}
    if options.get("useShapeDetection", False):
        result["shapeRois"] = shaped
    if every:
        result["planes"] = [{"plane": n + 1, "rois": len(pixels)} for n, pixels in enumerate(found)]
    return result


def _quicky(stack, options, context):
    """Quicky's ROIs of a height x width x frames stack (their pixels), the number of them found by their shape, the
    areas they were made from and the bins."""
    height, width, frames = stack.shape
    diameter = options["roiDiameter"]
    shape_wanted = options.get("useShapeDetection", False)
    binned, average = binned_max(stack, options["binSize"], shape_wanted)
    context.progress(0.1, "removing background")
    data = binned - gaussian_circular(binned, options["smoothingSigma"])
    data = data - moving_mean(data, 20)
    data = (data - data.min()) / max(data.max() - data.min(), np.finfo(float).tiny)
    threshold = float(_percentile(data.reshape(-1, 1), options["binarizationPercentile"])[0])
    small, large = disk(_half_up(diameter / 6)), disk(_half_up(diameter / 3))
    areas = []
    for b in range(data.shape[2]):
        context.check_cancelled()
        bw = fill_holes(data[:, :, b] > threshold)
        bw = dilate_by(erode_by(bw, small), small)
        bw = dilate_by(bw, large)
        bw = clear_border(bw)
        bw = erode_by(bw, large)
        bw = dilate_by(erode_by(bw, large), large)
        areas += components(bw, 8)
        context.progress(0.1 + 0.6 * (b + 1) / data.shape[2], f"bin {b + 1}/{data.shape[2]}")
    if areas:
        sizes = np.array([len(a) for a in areas], dtype=np.float64)
        largest = float(_percentile(sizes.reshape(-1, 1), 99)[0])
        areas = [a for a in areas if len(a) <= largest]
    rois = unique_rois(areas, height, width, diameter, options["observationsRequired"], options["maxRois"])
    shaped = []
    if shape_wanted:   # somata seen by their shape in the mean image, first
        context.progress(0.8, "shape detection")
        shaped = shape_rois(average, int(options.get("innerRadius", 3)), int(options.get("outerRadius", 5)))
        rois = (shaped + [r for r in rois if not any(overlap(r, s) > 0.75 for s in shaped)])[:options["maxRois"]]
    return rois, len(shaped), len(areas), data.shape[2]


SHAPE_ANGLES = 48      # directions a soma's edge is looked for in
SHAPE_STEP = 0.25      # px between samples along each direction
SHAPE_SAMPLES = 40     # samples along each direction after the centre: 10 px
SHAPE_MARGIN = 15      # px a soma's centre is from the edge at least


def shape_rois(image, inner, outer):
    """Somata found by their shape in an image, as flufinder's shapeDetection: (row, column) pixels per ROI.

    The image, scaled to 0..1, is correlated (Pearson, in a window the size of the template, the image 0
    outside) with a ring template: a nucleus of radius inner at the image's 5th percentile, a ring to radius
    outer at its 99th and the rest at its 50th, blurred by a Gaussian of 1 px. Where the correlation is above
    sqrt(0.2) of its largest, areas (8-connected) of 5 pixels or more are candidates, at their centroid,
    rounded half up, SHAPE_MARGIN px from the edge or more. Candidates whose 21 x 21 patch correlates with
    the candidates' mean patch by 0.1 or less are left out. Each one's mask is found from the centre
    outwards (soma_mask) and kept when the ring is brighter than both its edges in more than 60 % of
    directions and it does not overlap a soma kept before it by more than 75 %.
    """
    im = np.asarray(image, dtype=np.float64)
    im = im - im.min()
    top = im.max()
    if not top > 0:
        return []
    im = im / top
    score = template_correlation(im, ring_kernel(im, inner, outer))
    finite = score[np.isfinite(score)]
    if not finite.size or not finite.max() > 0:
        return []
    with np.errstate(invalid="ignore"):
        selected = np.nan_to_num(score / finite.max(), nan=0.0) > math.sqrt(0.2)
    height, width = im.shape
    centres = []
    for area in components(selected, 8):
        if len(area) < 5:
            continue
        cy = int(math.floor(sum(p[0] for p in area) / len(area) + 0.5))
        cx = int(math.floor(sum(p[1] for p in area) / len(area) + 0.5))
        if SHAPE_MARGIN <= cy <= height - 1 - SHAPE_MARGIN and SHAPE_MARGIN <= cx <= width - 1 - SHAPE_MARGIN:
            centres.append((cy, cx))
    if not centres:
        return []
    patches = [im[cy - 10:cy + 11, cx - 10:cx + 11] for cy, cx in centres]
    mean_patch = sum(patches) / len(patches)
    centres = [c for c, patch in zip(centres, patches) if _pearson(mean_patch, patch) > 0.1]
    rois = []
    for cy, cx in centres:
        pixels, ridge = soma_mask(im, cy, cx)
        if ridge > 0.6 and pixels and not any(overlap(pixels, r) > 0.75 for r in rois):
            rois.append(pixels)
    return rois


def ring_kernel(im, inner, outer, sigma=1):
    """The ring template: a square of 2 * outer + 2 * ceil(2 * sigma) + 1 px (see shape_rois)."""
    size = 2 * outer + 2 * int(math.ceil(2 * sigma)) + 1
    centre = (size - 1) / 2
    rows, columns = np.mgrid[0:size, 0:size]
    distance = (rows - centre) ** 2 + (columns - centre) ** 2
    nucleus, background, ring = (float(_percentile(im.reshape(-1, 1), p)[0]) for p in (5, 50, 99))
    kernel = np.where(distance <= inner ** 2, nucleus, np.where(distance <= outer ** 2, ring, background))
    return _blur(_blur(kernel, 0), 1)


def _blur(values, axis, circular=False):
    """A Gaussian blur of 1 sample along an axis: 5 taps, edges repeated (or wrapped around, circular)."""
    weights = np.exp(-np.arange(-2, 3) ** 2 / 2.0)
    weights = weights / weights.sum()
    size = values.shape[axis]
    out = np.zeros(values.shape)
    for k, weight in zip(range(-2, 3), weights):
        index = np.arange(size) + k
        index = index % size if circular else np.clip(index, 0, size - 1)
        out = out + weight * np.take(values, index, axis=axis)
    return out


def template_correlation(im, kernel):
    """The Pearson correlation of the template with the window around each pixel (the image 0 outside); NaN
    where the window is uniform."""
    size = kernel.shape[0]
    half = (size - 1) // 2
    height, width = im.shape
    padded = np.zeros((height + 2 * half, width + 2 * half))
    padded[half:half + height, half:half + width] = im
    centred = kernel - kernel.mean()
    total, squares, product = np.zeros(im.shape), np.zeros(im.shape), np.zeros(im.shape)
    for dy in range(size):
        for dx in range(size):
            window = padded[dy:dy + height, dx:dx + width]
            total += window
            squares += window * window
            product += centred[dy, dx] * window
    spread = squares - total * total / (size * size)
    with np.errstate(invalid="ignore", divide="ignore"):
        score = product / np.sqrt(spread * (centred * centred).sum())
    score[spread <= 1e-12] = np.nan
    return score


def _pearson(a, b):
    a = a - a.mean()
    b = b - b.mean()
    scale = math.sqrt(float((a * a).sum() * (b * b).sum()))
    return float((a * b).sum()) / scale if scale > 0 else float("nan")


def _circular_mean(values, window):
    """A moving mean over a window of samples, wrapping around."""
    half = window // 2
    n = len(values)
    return np.array([sum(values[(j + k) % n] for k in range(-half, half + 1)) / window for j in range(n)])


def soma_mask(im, cy, cx):
    """A soma's pixels around (cy, cx), from where the image rises (the nucleus's edge) and then falls (the
    soma's edge) along SHAPE_ANGLES directions, as flufinder's findSomaMaskByEdgeDetection; and the share of
    directions in which the ring between them is brighter than both edges.

    The image is sampled bilinearly every SHAPE_STEP px out to SHAPE_SAMPLES samples and blurred (1 sample,
    along each direction and across directions). The nucleus's edge is the largest rise in each direction,
    smoothed over 5 directions; it counts when the mean of those rises is more than 1.5 times their spread
    (standard deviation), and is the centre otherwise. The soma's edge is the largest fall beyond it, within
    1.2 times the nucleus's mean radius, smoothed the same way. The mask is the pixels whose centre is inside
    the polygon of the soma's edge, half a pixel further out.
    """
    count = SHAPE_SAMPLES
    angles = 2 * math.pi * np.arange(SHAPE_ANGLES) / SHAPE_ANGLES
    radii = SHAPE_STEP * np.arange(count + 1)
    y = cy + np.outer(radii, np.sin(angles))
    x = cx + np.outer(radii, np.cos(angles))
    y0, x0 = np.floor(y).astype(int), np.floor(x).astype(int)
    fy, fx = y - y0, x - x0
    profile = (1 - fy) * ((1 - fx) * im[y0, x0] + fx * im[y0, x0 + 1]) + fy * ((1 - fx) * im[y0 + 1, x0] + fx * im[y0 + 1, x0 + 1])
    profile = _blur(_blur(profile, 0), 1, circular=True)
    rise = np.diff(profile, axis=0)   # rise[i] is between samples i and i + 1
    first = rise.argmax(axis=0)
    strength = rise[first, np.arange(SHAPE_ANGLES)]
    spread = float(np.std(strength, ddof=1))
    significant = strength.mean() / spread > 1.5 if spread > 0 else strength.mean() > 0
    if significant:
        nucleus = _circular_mean(first, 5)
        start = np.floor(nucleus + 0.5).astype(int)
        depth = min(count - int(math.floor(nucleus.min())), int(math.ceil(nucleus.mean() * 1.2)))
    else:
        nucleus = np.zeros(SHAPE_ANGLES)
        start = np.zeros(SHAPE_ANGLES, dtype=int)
        depth = count
    beyond = np.zeros(SHAPE_ANGLES)
    for j in range(SHAPE_ANGLES):
        stop = min(start[j] + max(depth, 1), count)
        beyond[j] = int(rise[start[j]:stop, j].argmin()) if stop > start[j] else 0
    edge = np.clip(_circular_mean(beyond, 5) + nucleus, 0, count - 1)
    middle = np.floor((nucleus + edge + 1) / 2 + 0.5).astype(int)
    columns = np.arange(SHAPE_ANGLES)
    ring = profile[middle, columns]
    ridge = float(np.mean((ring > profile[np.floor(nucleus + 0.5).astype(int), columns]) &
                          (ring > profile[np.minimum(np.floor(edge + 0.5).astype(int) + 1, count), columns])))
    radius = (edge + 0.5) * SHAPE_STEP + 0.5
    polygon = np.stack([cx + radius * np.cos(angles), cy + radius * np.sin(angles)], axis=1)   # (x, y)
    reach = int(math.ceil(radius.max()))
    pixels = [(r, c) for r in range(cy - reach, cy + reach + 1) for c in range(cx - reach, cx + reach + 1)
              if 0 <= r < im.shape[0] and 0 <= c < im.shape[1] and _inside(polygon, c, r)]
    return pixels, ridge


def _inside(points, px, py):
    """Even-odd rule: is (px, py) inside the polygon of points (x, y)?"""
    inside = False
    j = len(points) - 1
    for i in range(len(points)):
        xi, yi = points[i]
        xj, yj = points[j]
        if (yi > py) != (yj > py) and px < (xj - xi) * (py - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside


def _half_up(value):
    """value rounded to a whole number, half away from zero (as MATLAB's round, for positive values)."""
    return int(math.floor(value + 0.5))


def binned_max(stack, size, average=False):
    """bin_max of a stack read a chunk of whole bins at a time; and, when asked, the mean of every frame."""
    height, width, frames = stack.shape
    size = frames if frames < size else size
    count = max(1, frames // size)
    binned = np.zeros((height, width, count))
    total = np.zeros((height, width)) if average else None
    step = size * max(1, CHUNK // size)
    for start in range(0, frames if average else count * size, step):
        chunk = stack.frames(start, min(start + step, frames)).astype(np.float64)
        whole = min(chunk.shape[2], count * size - start) // size * size if start < count * size else 0
        if whole:
            binned[:, :, start // size:start // size + whole // size] = chunk[:, :, :whole].reshape(height, width, whole // size, size).max(axis=3)
        if average:
            total += chunk.sum(axis=2)
    return binned, (total / frames if average else None)


def bin_max(stack, size):
    """The maximum of each run of size frames (one bin of all frames when there are fewer)."""
    count = max(1, stack.shape[2] // size)
    size = stack.shape[2] if stack.shape[2] < size else size
    return stack[:, :, :count * size].reshape(stack.shape[0], stack.shape[1], count, size).max(axis=3)


def gaussian_circular(stack, sigma):
    """Each frame smoothed by a Gaussian of sigma pixels, wrapping around the edges (by FFT)."""
    height, width = stack.shape[:2]
    gy = np.exp(-2 * np.pi ** 2 * sigma ** 2 * np.fft.fftfreq(height) ** 2)
    gx = np.exp(-2 * np.pi ** 2 * sigma ** 2 * np.fft.fftfreq(width) ** 2)
    return np.real(np.fft.ifft2(np.fft.fft2(stack, axes=(0, 1)) * (gy[:, None] * gx[None, :])[:, :, None], axes=(0, 1)))


def moving_mean(stack, window):
    """The mean over a window of frames around each frame, as MATLAB's movmean: window // 2 before and
    window - window // 2 - 1 after, cut at the ends."""
    frames = stack.shape[2]
    sums = np.concatenate([np.zeros(stack.shape[:2] + (1,)), np.cumsum(stack, axis=2)], axis=2)
    out = np.empty_like(stack)
    for t in range(frames):
        first, last = max(0, t - window // 2), min(frames, t + window - window // 2)
        out[:, :, t] = (sums[:, :, last] - sums[:, :, first]) / (last - first)
    return out


def disk(radius):
    """The offsets of a disk: dy^2 + dx^2 <= radius^2."""
    return [(dy, dx) for dy in range(-radius, radius + 1) for dx in range(-radius, radius + 1) if dy * dy + dx * dx <= radius * radius]


def _shifted(mask, dy, dx, fill):
    """mask moved so that out[y, x] = mask[y + dy, x + dx], fill outside."""
    height, width = mask.shape
    out = np.full_like(mask, fill)
    out[max(0, -dy):min(height, height - dy), max(0, -dx):min(width, width - dx)] = \
        mask[max(0, dy):min(height, height + dy), max(0, dx):min(width, width + dx)]
    return out


def dilate_by(mask, offsets):
    out = np.zeros_like(mask)
    for dy, dx in offsets:
        out |= _shifted(mask, dy, dx, False)
    return out


def erode_by(mask, offsets):
    """Erosion that treats the outside of the image as foreground, as MATLAB's imerode does."""
    out = np.ones_like(mask)
    for dy, dx in offsets:
        out &= _shifted(mask, dy, dx, True)
    return out


def fill_holes(mask):
    """Background not 4-connected to the image border becomes foreground."""
    outside = np.zeros_like(mask)
    queue = [(y, x) for y in range(mask.shape[0]) for x in (0, mask.shape[1] - 1)] + \
            [(y, x) for x in range(mask.shape[1]) for y in (0, mask.shape[0] - 1)]
    for y, x in queue:
        if not mask[y, x]:
            outside[y, x] = True
    queue = [(y, x) for y, x in queue if outside[y, x]]
    while queue:
        y, x = queue.pop()
        for dy, dx in NEIGHBOURS[4]:
            ny, nx = y + dy, x + dx
            if 0 <= ny < mask.shape[0] and 0 <= nx < mask.shape[1] and not mask[ny, nx] and not outside[ny, nx]:
                outside[ny, nx] = True
                queue.append((ny, nx))
    return ~outside


def clear_border(mask):
    """Foreground areas (8-connected) that touch the border removed."""
    out = mask.copy()
    for area in components(mask, 8):
        if any(y in (0, mask.shape[0] - 1) or x in (0, mask.shape[1] - 1) for y, x in area):
            for y, x in area:
                out[y, x] = False
    return out


def unique_rois(areas, height, width, diameter, required, most):
    """ROIs where areas recur, as flufinder's findUniqueRoisFromComponents, deterministically."""
    counts = np.zeros((height, width))
    for area in areas:
        for y, x in area:
            counts[y, x] += 1
    members = {}
    for index, area in enumerate(areas):
        for p in area:
            members.setdefault(p, []).append(index)
    centroids = np.array([[np.mean([p[0] for p in a]), np.mean([p[1] for p in a])] for a in areas]) if areas else np.zeros((0, 2))
    remaining = np.ones(len(areas), dtype=bool)
    rois = []
    while len(rois) < most and remaining.any() and counts.max() > 0:
        peak = int(np.argmax(counts))   # the first largest, in row-major order
        py, px = divmod(peak, width)
        near = [i for i in members.get((py, px), []) if remaining[i]]
        if not near:
            counts[py, px] = 0
            continue
        center = np.array([_median(centroids[near, 0]), _median(centroids[near, 1])])
        kept = [i for i in near if (np.abs(centroids[i] - center) < 3).all()]
        if not kept:   # no area near the median: the largest group of areas within 3 px of one of them
            groups = [[j for j in near if (np.abs(centroids[j] - centroids[i]) < 3).all()] for i in near]
            kept = max(groups, key=len)
        if len(kept) < required:
            break
        image = np.zeros((height, width))
        for i in kept:
            for y, x in areas[i]:
                image[y, x] += 1
        mask = roi_mask(image, center, diameter)
        counts -= image
        counts[mask] = 0
        remaining[kept] = False
        pixels = [tuple(map(int, p)) for p in np.argwhere(mask)]
        if pixels and not any(overlap(pixels, r) >= 0.75 for r in rois):
            rois.append(pixels)
    return rois


def roi_mask(image, center, diameter):
    """The ROI in a window of +-15 px around the center: above the mid-point of the window's 50th and 95th
    percentile, without bits under a tenth of a cell's area, holes filled, the largest area."""
    height, width = image.shape
    cy, cx = int(math.floor(center[0] + 0.5)), int(math.floor(center[1] + 0.5))
    w = min(15, cy, height - 1 - cy, cx, width - 1 - cx)
    window = image[cy - w:cy + w + 1, cx - w:cx + w + 1]
    low = float(_percentile(window.reshape(-1, 1), 50)[0])
    high = float(_percentile(window.reshape(-1, 1), 95)[0])
    bw = window > low + (high - low) / 2
    smallest = _half_up(math.pi * (diameter / 2) ** 2 / 10)
    pieces = [a for a in components(bw, 8) if len(a) >= smallest]
    bw = np.zeros_like(bw)
    for a in pieces:
        for y, x in a:
            bw[y, x] = True
    bw = fill_holes(bw)
    pieces = components(bw, 8)
    mask = np.zeros((height, width), dtype=bool)
    if pieces:
        for y, x in max(pieces, key=len):   # the first of the largest
            mask[cy - w + y, cx - w + x] = True
    return mask


def overlap(a, b):
    """The share of the smaller of two pixel lists that the other covers."""
    common = len(set(a) & set(b))
    return common / min(len(a), len(b))


def extract_signals(entity, options, context):
    """Average of each ROI's pixels per frame, and of neuropil around it outside every ROI. Reads the stack a chunk
    at a time.

    With excludeOverlaps (dev's excludeRoiOverlaps), pixels in more than one ROI are left out of the ROIs' signals.
    The neuropil is a ring (neuropilGap pixels from the ROI, neuropilWidth wide), or with neuropilMethod "expansion"
    dev's: grown from the ROI until it covers neuropilExpansionFactor times the ROI's area outside every ROI (and
    neuropilSeparation pixels around them), by dilations that alternate between the four sides and the four
    diagonals, as FISSA does. With plane 0, each ROI's signal is read from its own plane (its place; the ROIs of the
    other channels are left out), and the ROIs of a plane are those every ROI and neuropil is reckoned with: the
    columns are the ROIs in the file's order, whatever their planes, as data.traces and the viewer read them."""
    from nansen.frames import rois_at
    _, stacks, every = _plane_stacks(entity, options["stack"], context, options)
    height, width, frames = stacks[0].shape
    channel = int(options.get("channel", 1))
    value = context.project.load(entity, options["rois"])
    if every:   # the ROIs of the channel used, each on its plane
        document = dict(value, rois=[roi for roi in value.get("rois", []) if roi.get("channel", channel) == channel])
    else:   # the ROIs of the plane and channel used, when they have places (dev's RoiGroup of several)
        document = rois_at(value, options.get("plane", 1), channel)
    kept = [roi for roi in document.get("rois", []) if options["includeRejected"] or roi.get("classification") != "rejected"]
    places = [_roi_plane(roi, len(stacks), options["rois"]) if every else 1 for roi in kept]
    signals = np.full((frames, len(kept)), np.nan)
    neuropil = np.full((frames, len(kept)), np.nan)
    counts = []
    for number, stack in enumerate(stacks):
        columns = [i for i, place in enumerate(places) if place == number + 1]
        counts.append(len(columns))
        progress = lambda stop: context.progress((number + stop / frames) / len(stacks), f"frame {stop}/{frames}")
        signals[:, columns], neuropil[:, columns] = _signals(stack, dict(document, rois=[kept[i] for i in columns]), options, context, progress)
    _save(entity, options["output"], signals, context)
    _save(entity, options["neuropilOutput"], neuropil, context)
    context.log(f"{_name(entity)}: signals of {len(kept)} ROIs in {frames} frames")
    result = {"rois": len(kept), "frames": frames, "ids": [roi.get("id", n + 1) for n, roi in enumerate(kept)],
              "meanSignal": [round_to(v, 4) for v in signals.mean(axis=0)],
              "meanNeuropil": [round_to(v, 4) for v in neuropil.mean(axis=0)]}
    if every:
        result["planes"] = [{"plane": n + 1, "rois": count} for n, count in enumerate(counts)]
    return result


def _roi_plane(roi, planes, name):
    """The plane (from 1) of an ROI extracted with every plane: its place, or the one plane of a stack of one."""
    plane = roi.get("plane")
    if plane is None and planes == 1:
        return 1
    if plane is None:
        raise NansenError("invalid-data", f"ROI {roi.get('id')} of {name} has no plane, so it is of every plane: extract its signals one plane at a time")
    if not 1 <= int(plane) <= planes:
        raise NansenError("invalid-data", f"ROI {roi.get('id')} of {name} is of plane {plane}; the stack has {planes}")
    return int(plane)


def _signals(stack, document, options, context, progress):
    """The signals and neuropil (frames x ROIs) of the ROIs of an ROI file in a height x width x frames stack."""
    height, width, frames = stack.shape
    masks = roi_masks(document, height, width)
    signals = np.full((frames, len(masks)), np.nan)
    neuropil = np.full((frames, len(masks)), np.nan)
    union = np.zeros((height, width), dtype=bool)
    covered = np.zeros((height, width), dtype=np.int64)
    for mask in masks:
        union |= mask
        covered += mask
    own = [mask & (covered == 1) for mask in masks] if options.get("excludeOverlaps", False) else masks
    inside = [np.flatnonzero(mask) for mask in own]
    if options.get("neuropilMethod", "ring") == "expansion":
        around = expansion_neuropil(masks, union, options.get("neuropilExpansionFactor", 4), options.get("neuropilSeparation", 0))
    else:
        around = [neuropil_ring(mask, union, options["neuropilGap"], options["neuropilWidth"]) for mask in masks]
    rings = [np.flatnonzero(ring) for ring in around]
    for start in range(0, frames, CHUNK):
        context.check_cancelled()
        stop = min(start + CHUNK, frames)
        flat = stack[:, :, start:stop].reshape(height * width, stop - start)
        for i in range(len(masks)):
            if inside[i].size:
                signals[start:stop, i] = flat[inside[i]].astype(np.float64).mean(axis=0)
            if rings[i].size:
                neuropil[start:stop, i] = flat[rings[i]].astype(np.float64).mean(axis=0)
        progress(stop)
    return signals, neuropil


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


def expansion_neuropil(masks, union, factor, separation):
    """dev's neuropil masks (estimateNeuropilMasks): each ROI's mask dilated, alternately by its four sides (even
    steps) and its four diagonals (odd steps), less the ROI, until the part outside the ignored pixels covers
    factor times the ROI's area (at most the rest of the image), or after 101 steps; the ignored pixels (every ROI,
    dilated separation times, from a diagonal step) are then taken out."""
    ignored = union.copy()
    for step in range(1, separation + 1):
        ignored = _dilate_odd_even(ignored, step)
    out = []
    for mask in masks:
        area = int(mask.sum())
        target = min(mask.size - area, factor * area)
        grown, covered, step = mask.copy(), 0, 0
        while covered < target and step <= 100:
            grown = _dilate_odd_even(grown, step)
            grown &= ~mask
            covered = int((grown & ~ignored).sum())
            step += 1
        out.append(grown & ~ignored)
    return out


def _dilate_odd_even(mask, step):
    """One dilation by the four sides (step even) or the four diagonals (step odd), nothing past the edges."""
    out = mask.copy()
    offsets = [(1, 0), (-1, 0), (0, 1), (0, -1)] if step % 2 == 0 else [(1, 1), (1, -1), (-1, 1), (-1, -1)]
    height, width = mask.shape
    for dy, dx in offsets:
        out[max(dy, 0):height + min(dy, 0), max(dx, 0):width + min(dx, 0)] |= \
            mask[max(-dy, 0):height + min(-dy, 0), max(-dx, 0):width + min(-dx, 0)]
    return out


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
    """ΔF/F of each ROI, by one of dev's methods, with F0 a running or overall percentile:

    subtract: F = signal - k neuropil, ΔF/F = (F - F0) / F0. chen2013 (Chen et al. 2013, as dev's dffChenEtAl2013): the
    neuropil's own baseline added back, F = signal - k neuropil + N0. dffMinusNeuropil (dev's dffRoiMinusDffNpil, without
    its smoothing): the signal's ΔF/F less k times the neuropil's. A correctionWindow > 0 then subtracts a running
    correctionPercentile of ΔF/F over that many frames, as dev's correctBaseline."""
    signals = _as_traces(context.project.load(entity, options["signals"]))
    method = options.get("method", "subtract")
    k, p, window = options["neuropilFactor"], options["baselinePercentile"], options["baselineWindow"]
    neuropil = None
    if options["neuropil"]:
        neuropil = _as_traces(context.project.load(entity, options["neuropil"]))
        if neuropil.shape != signals.shape:
            raise NansenError("invalid-data", f"the neuropil signals are {neuropil.shape}, the signals {signals.shape}")
        neuropil = np.nan_to_num(neuropil, nan=0.0)
    elif method == "dffMinusNeuropil":
        raise NansenError("invalid-options", "dffMinusNeuropil needs the neuropil signals")
    with np.errstate(divide="ignore", invalid="ignore"):
        if method == "dffMinusNeuropil":
            baseline = moving_percentile(signals, p, window)
            neuropil_baseline = moving_percentile(neuropil, p, window)
            dff = (signals - baseline) / baseline - k * (neuropil - neuropil_baseline) / neuropil_baseline
        else:
            if neuropil is not None:
                signals = signals - k * neuropil
                if method == "chen2013":
                    signals = signals + moving_percentile(neuropil, p, window)
            baseline = moving_percentile(signals, p, window)
            dff = (signals - baseline) / baseline
    if options.get("correctionWindow", 0) > 0:
        dff = dff - moving_percentile(dff, options.get("correctionPercentile", 25), options["correctionWindow"])
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
    """Bin the stack: mean (single precision) or maximum of each bin of frames and of pixels. Reads a chunk at a time."""
    stack = _open_stack(entity, options["stack"], context, options)
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


def flowreg(entity, options, context):
    """Non-rigid motion correction by optical flow with pyflowreg, Flow-Registration's Python port, as ophys.flowreg
    runs the MATLAB toolbox: the reference is the average of the first referenceFrames frames, alpha the
    smoothness and quality the toolbox's setting. The stack is read whole; the aligned one keeps its type."""
    try:
        from pyflowreg.motion_correction import compensate_arr
        from pyflowreg.motion_correction.OF_options import OFOptions
        from pyflowreg.motion_correction.compensate_recording import RegistrationConfig
    except ImportError as error:
        raise NansenError("dependency-missing", f"ophys.flowreg needs pyflowreg ({error}): pip install pyflowreg") from None
    stack = _open_stack(entity, options["stack"], context, options)
    frames = stack.shape[2]
    video = np.moveaxis(np.asarray(stack[:, :, 0:frames], dtype=np.float64), 2, 0)   # frames x rows x columns
    reference = video[:min(int(options["referenceFrames"]), frames)].mean(axis=0)
    settings = OFOptions(alpha=float(options["alpha"]), quality_setting=str(options["quality"]))
    context.log(f"{_name(entity)}: running Flow-Registration (pyflowreg) on {frames} frames")
    registered, _ = compensate_arr(video, reference, settings, registration_config=RegistrationConfig(parallelization="sequential"))
    aligned = np.moveaxis(np.asarray(registered).reshape(video.shape), 0, 2)
    if np.issubdtype(stack.dtype, np.integer):
        limits = np.iinfo(stack.dtype)
        aligned = np.clip(np.floor(aligned + 0.5), limits.min, limits.max)
    _save(entity, options["output"], aligned.astype(stack.dtype), context)
    return {"frames": frames}


def cnmf(entity, options, context):
    """Cells found by CaImAn's CNMF (greedy initialisation, spatial and temporal updates, merging) on the whole stack,
    saved as ROIs (the 8-connected pixels around each footprint's peak above threshold times it), their traces
    (C + YrA) as signals and their denoised calcium (C)."""
    try:
        from caiman.source_extraction.cnmf import cnmf as caiman_cnmf
        from caiman.source_extraction.cnmf import params as caiman_params
    except ImportError as error:
        raise NansenError("dependency-missing", f"ophys.cnmf needs CaImAn ({error}): see https://github.com/flatironinstitute/CaImAn") from None
    from nansen.adapters import load_object
    adapters = Path(__file__).resolve().parent
    weights_pixels = load_object("ophys_adapters:weights_pixels", adapters)
    roi_document = load_object("ophys_adapters:roi_document", adapters)
    stack = _open_stack(entity, options["stack"], context, options)
    height, width, frames = stack.shape
    rate = float(options.get("frameRate") or entity.get("frame_rate") or 30)
    images = np.ascontiguousarray(np.moveaxis(np.asarray(stack[:, :, 0:frames], dtype=np.float32), 2, 0))   # frames x rows x columns
    radius = int(options["cellRadius"])
    parameters = caiman_params.CNMFParams(params_dict={
        "fr": rate, "decay_time": 0.4, "p": 1, "nb": 1, "rf": None, "K": int(options["components"]),
        "gSig": [radius, radius], "merge_thr": float(options["mergeThreshold"]), "method_init": "greedy_roi",
        "ssub": 1, "tsub": 1})
    context.log(f"{_name(entity)}: running CNMF on {frames} frames")
    model = caiman_cnmf.CNMF(n_processes=1, params=parameters, dview=None)
    model.fit(images)   # returns the model in some versions of CaImAn, None in others
    estimates = model.estimates
    footprints = estimates.A.tocsc()
    rois, kept = [], []
    for k in range(footprints.shape[1]):
        weights = np.asarray(footprints[:, k].todense()).reshape((height, width), order="F")   # CaImAn's pixels in Fortran order
        pixels = weights_pixels(weights, options["threshold"])
        if pixels:
            rois.append((sorted(pixels), None))
            kept.append(k)
    context.project.save(entity, options["rois"], roi_document([height, width], rois))
    calcium = np.asarray(estimates.C)[kept].T
    _save(entity, options.get("output", ""), calcium + np.asarray(estimates.YrA)[kept].T, context)
    _save(entity, options.get("denoisedOutput", ""), calcium, context)
    context.log(f"{_name(entity)}: CNMF kept {len(rois)} cells")
    return {"rois": len(rois), "frames": frames}


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
    stack = _load_stack(entity, options["stack"], context, options)
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

def export_tiff(entity, options, context):
    """Frames firstFrame..lastFrame (from 1; lastFrame 0 for the last) of the stack written to a TIFF file, a chunk at
    a time, as dev's imviewer exports a stack. A relative path is in the project's folder; {field} tokens are the
    entity's values."""
    return export_stack(entity, dict(options, format="tiff"), context)


EXPORT_FORMATS = ("tiff", "binary", "npy", "video")


def export_stack(entity, options, context):
    """Frames firstFrame..lastFrame of the stack written to a file a chunk at a time, as dev's imviewer exports one:
    tiff (a page per frame), binary (dev's .raw beside its .ini), npy, or video (Motion JPEG AVI of 8-bit frames,
    the values from low to high scaled to 0..255; both 0 for the 0.5th and 99.5th percentiles of the first frames)."""
    stack = _open_stack(entity, options["stack"], context, options)   # frames firstFrame..lastFrame
    height, width, frames = stack.shape
    first = int(options.get("firstFrame", 1))
    last = first + frames - 1
    form = options.get("format", "tiff")
    if form not in EXPORT_FORMATS:
        raise NansenError("invalid-options", f"format is one of {', '.join(EXPORT_FORMATS)}")
    path = Path(_fill(str(options["path"]), entity))
    if not path.is_absolute():
        path = Path(context.project.folder) / path
    path.parent.mkdir(parents=True, exist_ok=True)
    shape = (height, width, frames)
    from nansen.adapters import load_object
    adapters = Path(__file__).resolve().parent
    scale = None
    if form == "tiff":
        out = load_object("ophys_adapters:TiffPageWriter", adapters)(path, shape, stack.dtype)
    elif form == "binary":
        out = load_object("ophys_adapters:BinaryStack", adapters)().create(path, shape, stack.dtype)
    elif form == "npy":
        out = context.project.adapters.get("npy").create(path, shape, stack.dtype)
    else:
        low, high = float(options.get("low", 0)), float(options.get("high", 0))
        if low == 0 and high == 0:
            sample = np.asarray(stack.frames(0, CHUNK), dtype=np.float64).reshape(-1, 1)
            low, high = float(_percentile(sample, 0.5)[0]), float(_percentile(sample, 99.5)[0])
        if high <= low:
            high = low + 1
        scale = (low, high)
        out = VideoWriter(path, shape)
    with out:
        for start in range(0, frames, CHUNK):
            context.check_cancelled()
            stop = min(start + CHUNK, frames)
            chunk = stack.frames(start, stop)
            if scale is not None:
                chunk = to_uint8(chunk, *scale)
            out.write(start, chunk)
            context.progress(stop / frames, f"frame {first + stop - 1}/{last}")
    context.log(f"{_name(entity)}: frames {first} to {last} written to {path}")
    return {"frames": frames, "path": str(path), "format": form}


def to_uint8(chunk, low, high):
    """Values from low to high as 0..255, rounded half up and cut at both ends, as data.frame scales an image."""
    scaled = np.floor((np.asarray(chunk, dtype=np.float64) - low) / (high - low) * 255 + 0.5)
    return np.clip(scaled, 0, 255).astype(np.uint8)


class VideoWriter:
    """Motion JPEG AVI frames, a chunk at a time, with imageio's ffmpeg (the video extra), as MATLAB's VideoWriter
    writes them; write(start, chunk) with 8-bit height x width x n chunks in order."""

    def __init__(self, path, shape):
        try:
            import imageio.v2 as iio
            import imageio_ffmpeg  # noqa: F401
        except ImportError:
            raise NansenError("dependency-missing", 'video export needs imageio and imageio-ffmpeg: pip install "nansen-core[video]"') from None
        self.shape, self.written = tuple(int(n) for n in shape), 0
        self.path = Path(path)
        self._writer = iio.get_writer(str(path), format="ffmpeg", codec="mjpeg", fps=30, quality=None,
                                      pixelformat="yuvj420p", output_params=["-q:v", "2", "-f", "avi"], macro_block_size=1)

    def write(self, start, chunk):
        chunk = np.asarray(chunk)
        if int(start) != self.written:
            raise NansenError("invalid-params", f"frames come in order: {self.written} were written, not {start}")
        for t in range(chunk.shape[2]):
            self._writer.append_data(np.repeat(chunk[:, :, t, None], 3, axis=2))
        self.written += chunk.shape[2]

    def close(self):
        if self._writer is not None:
            self._writer.close()
            self._writer = None
            if self.written and (not self.path.is_file() or self.path.stat().st_size == 0):   # ffmpeg says so only on stderr
                raise NansenError("internal-error", f"ffmpeg wrote no video to {self.path}")

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def export_nwb(entity, options, context):
    """The recording, its ROIs and their signals in an NWB file (pynwb), as dev's NWBExporter wrote the stack.

    The stack is a TwoPhotonSeries in acquisition, written a chunk at a time, data (frames, x, y) with x the
    column; the ROIs a PlaneSegmentation of pixel masks (x, y, weight 1) with their ids and classification; the
    signals RoiResponseSeries in Fluorescence and DfOverF, linked to the ROIs their columns are. An empty name, or
    a variable with no file, is left out. A relative path is in the project's folder; {field} tokens are the
    entity's values. MATLAB's ophys.exportNwb writes the same with matnwb."""
    try:
        from hdmf.data_utils import DataChunkIterator
        from pynwb import NWBHDF5IO, NWBFile
        from pynwb.file import Subject
        from pynwb.ophys import (DfOverF, Fluorescence, ImageSegmentation, OpticalChannel, RoiResponseSeries,
                                 TwoPhotonSeries)
    except ImportError:
        raise NansenError("dependency-missing", "exporting to NWB needs pynwb: pip install pynwb") from None
    rate = float(options.get("frameRate") or entity.get("frame_rate") or 0)
    if rate <= 0:
        raise NansenError("invalid-options", "give frameRate, or fill in the entity's frame_rate")
    path = Path(_fill(str(options["path"]), entity))
    if not path.is_absolute():
        path = Path(context.project.folder) / path
    path.parent.mkdir(parents=True, exist_ok=True)

    def read(name, reader):
        """What reader gives for the variable, or None when the name is empty or the entity has no file of it."""
        if not name:
            return None
        try:
            return reader(name)
        except NansenError as error:
            if error.code == "data-not-found":
                return None
            raise

    values = {**getattr(entity, "values", {}), **entity.key}
    start = _session_start(values)
    nwb = NWBFile(session_description=options.get("sessionDescription") or _name(entity),
                  identifier="_".join(str(v) for v in entity.key.values()), session_start_time=start,
                  session_id=str(values.get("session_id", "")) or None)
    if values.get("subject_id"):
        nwb.subject = Subject(subject_id=str(values["subject_id"]))
    device = nwb.create_device(name="Microscope", description="two-photon microscope")
    channel = OpticalChannel(name="OpticalChannel", description="channel %d" % options.get("channel", 1), emission_lambda=float("nan"))
    plane = nwb.create_imaging_plane(name="ImagingPlane", optical_channel=channel, description="imaging plane",
                                     device=device, excitation_lambda=float("nan"), imaging_rate=rate,
                                     indicator=str(values.get("indicator") or "unknown"), location="unknown")
    result = {"frames": 0, "rois": 0, "signals": []}
    stack = read(options["stack"], lambda name: _open_stack(entity, name, context, options))
    if stack is not None:
        height, width, frames = stack.shape

        def frames_in_chunks():
            for first in range(0, frames, CHUNK):
                context.check_cancelled()
                last = min(first + CHUNK, frames)
                chunk = np.asarray(stack.frames(first, last))
                for t in range(last - first):
                    yield chunk[:, :, t].T   # (x, y): x the column
                context.progress(last / frames * 0.9, f"frame {last}/{frames}")

        data = DataChunkIterator(data=frames_in_chunks(), maxshape=(frames, width, height), dtype=np.dtype(stack.dtype),
                                 buffer_size=CHUNK)
        nwb.add_acquisition(TwoPhotonSeries(name="TwoPhotonSeries", data=data, imaging_plane=plane, rate=rate,
                                            starting_time=0.0, unit="n.a."))
        result["frames"] = frames
    document = read(options["rois"], lambda name: context.project.load(entity, name))
    if document is not None:
        rois = document.get("rois", [])
        module = nwb.create_processing_module(name="ophys", description="ROIs and their signals")
        segmentation = ImageSegmentation(name="ImageSegmentation")
        module.add(segmentation)
        table = segmentation.create_plane_segmentation(name="PlaneSegmentation", description="ROIs", imaging_plane=plane)
        table.add_column(name="classification", description="accepted, rejected, or empty when not classified")
        for n, roi in enumerate(rois):
            table.add_roi(id=int(roi.get("id", n + 1)), classification=str(roi.get("classification") or ""),
                          pixel_mask=[(int(x), int(y), 1.0) for y, x in roi["pixels"]])
        result["rois"] = len(rois)
        kept = [n for n, roi in enumerate(rois) if roi.get("classification") != "rejected"]
        containers = {}
        for key, container_type, name in (("signals", Fluorescence, "RoiResponseSeries"), ("dff", DfOverF, "Dff")):
            signals = read(options.get(key, ""), lambda name: _as_traces(context.project.load(entity, name)))
            if signals is None:
                continue
            columns = list(range(len(rois))) if signals.shape[1] == len(rois) else kept if signals.shape[1] == len(kept) else None
            if columns is None:
                raise NansenError("invalid-data", f"{options[key]} has {signals.shape[1]} columns for {len(rois)} ROIs")
            if container_type not in containers:   # in the file before its series, so they can link to the ROIs
                containers[container_type] = container_type(name=container_type.__name__)
                module.add(containers[container_type])
            region = table.create_roi_table_region(region=columns, description="the ROIs of the columns")
            containers[container_type].add_roi_response_series(
                RoiResponseSeries(name=name, data=signals, rois=region, unit="n.a.", rate=rate, starting_time=0.0))
            result["signals"].append(options[key])
    with NWBHDF5IO(str(path), "w") as io:
        io.write(nwb)
    context.log(f"{_name(entity)}: {result['frames']} frames, {result['rois']} ROIs and {len(result['signals'])} signals written to {path}")
    return dict(result, path=str(path))


def _session_start(values):
    """The session's start: its session_date (and session_time), else now; in UTC when no time zone is given."""
    import datetime as dt
    text = str(values.get("session_date") or "")
    try:
        start = dt.datetime.fromisoformat(text[:10] + ("T" + str(values["session_time"]) if values.get("session_time") else ""))
    except (ValueError, TypeError):
        start = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    return start if start.tzinfo else start.replace(tzinfo=dt.timezone.utc)


def _fill(template, entity):
    """A path with {field} tokens filled from the entity's key and values."""
    values = {**getattr(entity, "values", {}), **entity.key}
    return re.sub(r"\{([A-Za-z_][A-Za-z0-9_]*)\}", lambda m: str(values.get(m.group(1), m.group(0))), template)


def deinterleave(entity, options, context):
    """Frames of several channels and planes, interleaved in one height x width x frames stack, put in a
    height x width x channels (x planes) x frames stack: channel fastest, then plane (as ScanImage saves them).
    Frames after the last whole volume are left out. Reads and writes a chunk at a time. firstFrame..lastFrame count
    the frames put together (volumes): frame k is the stack's frames (k - 1) x channels x planes + 1 to k x channels x
    planes."""
    channels, planes = options["channels"], options["planes"]
    per = channels * planes
    stack = _pick(_open_whole(entity, options["stack"], context, options, per), options["stack"], 1, 1)
    height, width, total = stack.shape
    frames = total // per
    if frames == 0:
        raise NansenError("invalid-options", f"{options['stack']} has {total} frames, fewer than {channels} channels x {planes} planes")
    shape = (height, width) + ((channels, planes) if planes > 1 else (channels,) if channels > 1 else ()) + (frames,)
    step = max(1, CHUNK // per)
    with context.project.stack_writer(entity, options["output"], shape, stack.dtype) as out:
        for start in range(0, frames, step):
            context.check_cancelled()
            stop = min(start + step, frames)
            chunk = stack[:, :, start * per:stop * per].reshape(height, width, stop - start, planes, channels)
            out.write(start, chunk.transpose(0, 1, 4, 3, 2).reshape(shape[:-1] + (stop - start,)))
            context.progress(stop / frames, f"frame {stop}/{frames}")
    context.log(f"{_name(entity)}: {frames} frames of {channels} channel(s) and {planes} plane(s)")
    return {"frames": frames, "channels": channels, "planes": planes}


def denoise(entity, options, context):
    """Gaussian smoothing in space and in time, with the weights renormalised at the edges.

    Read and written a chunk at a time: each part with 3 temporal sigmas of frames on either side, so every
    frame gets the weights it would get were the stack smoothed whole.
    """
    stack = _open_stack(entity, options["stack"], context, options)
    height, width, frames = stack.shape
    temporal = options["temporalSigma"]
    halo = int(math.ceil(3 * temporal)) if temporal > 0 else 0
    total = 0.0
    step = max(1, CHUNK - 2 * halo)   # each read, halo included, is a chunk at most
    with context.project.stack_writer(entity, options["output"], (height, width, frames), np.float32) as out:
        for start in range(0, frames, step):
            context.check_cancelled()
            stop = min(start + step, frames)
            first, last = max(0, start - halo), min(frames, stop + halo)
            block = stack.frames(first, last).astype(np.float64)
            for axis, sigma in ((0, options["spatialSigma"]), (1, options["spatialSigma"]), (2, temporal)):
                block = gaussian_along(block, axis, sigma)
            piece = block[:, :, start - first:stop - first].astype(np.float32)
            out.write(start, piece)
            total += float(piece.astype(np.float64).sum())
            context.progress(stop / frames, f"frame {stop}/{frames}")
    context.log(f"{_name(entity)}: smoothed {frames} frames")
    return {"frames": frames, "height": height, "width": width, "meanIntensity": round_to(total / (height * width * frames), 4)}


def find_plane(entity, options, context):
    """The plane of a z-stack the recording's field of view is, as dev's zStackPlaneFinder: the recording's mean image
    is compared with each plane at the shift the phase correlation finds (within maxShift, as motion correction
    finds one), by the Pearson correlation of the pixels both cover. The best plane (from 1), its shift and the
    correlation of each plane (4 decimals)."""
    stack = _open_stack(entity, options["stack"], context, options)
    height, width, frames = stack.shape
    total = np.zeros((height, width))
    for start in range(0, frames, CHUNK):
        context.check_cancelled()
        total += np.asarray(stack.frames(start, min(start + CHUNK, frames)), dtype=np.float64).sum(axis=2)
    fov = total / frames
    planes = np.asarray(_open_stack(entity, options["zstack"], context)[:, :, :], dtype=np.float64)
    if planes.shape[:2] != (height, width):
        raise NansenError("invalid-data", f"the z-stack's planes are {planes.shape[0]} x {planes.shape[1]}, the recording's frames {height} x {width}")
    shifts = estimate_shifts(planes, _reference_fft(fov, True), int(options["maxShift"]), tapered=True)
    correlations = []
    for p in range(planes.shape[2]):
        moved = apply_shifts(planes[:, :, p:p + 1], shifts[p:p + 1])[:, :, 0]
        covered = apply_shifts(np.ones((height, width, 1)), shifts[p:p + 1])[:, :, 0] > 0
        correlations.append(round_to(_pearson(fov[covered], moved[covered]), 4))
    best = int(np.nanargmax(np.array(correlations, dtype=float)))
    context.log(f"{_name(entity)}: plane {best + 1} of {planes.shape[2]} (r = {correlations[best]})")
    return {"plane": best + 1, "shift": [int(v) for v in shifts[best]], "correlation": correlations[best], "correlations": correlations}


def crop(entity, options, context):
    """Rows firstRow..lastRow, columns firstColumn..lastColumn and frames firstFrame..lastFrame of the stack (from 1;
    0 for the last), saved as a new stack, as dev's StackCropper. Read and written a chunk at a time."""
    stack = _open_stack(entity, options["stack"], context, options)   # frames firstFrame..lastFrame
    height, width, frames = stack.shape
    def span(first, last, size, what):
        first, last = int(first), int(last) or size
        if not 1 <= first <= last <= size:
            raise NansenError("invalid-options", f"{what} {first} to {last} are not within the stack's {size}")
        return first - 1, last
    top, bottom = span(options["firstRow"], options["lastRow"], height, "rows")
    left, right = span(options["firstColumn"], options["lastColumn"], width, "columns")
    shape = (bottom - top, right - left, frames)
    with context.project.stack_writer(entity, options["output"], shape, stack.dtype) as out:
        for start in range(0, frames, CHUNK):
            context.check_cancelled()
            stop = min(start + CHUNK, frames)
            out.write(start, stack.frames(start, stop)[top:bottom, left:right])
            context.progress(stop / frames, f"frame {stop}/{frames}")
    context.log(f"{_name(entity)}: {shape[0]} x {shape[1]} x {shape[2]} kept")
    return {"height": shape[0], "width": shape[1], "frames": shape[2]}


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
    """Align each entity's FOV image to the first entity's, and copy the first entity's ROIs, moved, to the others.

    With maxRotation, each image is also turned back by each angle from -maxRotation to maxRotation in steps of
    rotationStep (about the image centre, bilinearly, the image's mean outside it), and the angle of largest
    correlation (the smallest, then the negative, of equal ones) is taken. An ROI pixel p of the first entity
    goes to rotation(angle) * (p - centre + shift) + centre, rounded half up.
    """
    if not entities:
        raise NansenError("no-entities", "no entities to align")
    reference_image = _image(context.project.load(entities[0], options["image"]))
    height, width = reference_image.shape
    most, step = float(options.get("maxRotation", 0)), float(options.get("rotationStep", 0.5))
    if most > 0 and step <= 0:
        raise NansenError("invalid-options", "rotationStep is more than 0")
    count = int(math.floor(most / step + 1e-9)) if most > 0 else 0
    angles = sorted({k * step for k in range(-count, count + 1)}, key=lambda a: (abs(a), a))
    tapered = most > 0
    reference_fft = _reference_fft(reference_image, tapered)
    document = context.project.load(entities[0], options["rois"])
    rois = [roi for roi in document.get("rois", []) if roi.get("classification") != "rejected"]
    shifts, migrated = [], 0
    for number, entity in enumerate(entities):
        context.check_cancelled()
        image = _image(context.project.load(entity, options["image"]))
        if image.shape != (height, width):
            raise NansenError("invalid-data", f"{_name(entity)}: the image is {image.shape}, the reference {(height, width)}")
        best = None
        for angle in angles:
            turned = rotate_image(image, angle) if angle else image
            frames = _tapered(turned[:, :, None]) if tapered else turned[:, :, None]
            correlation, _ = _correlation(frames, reference_fft)
            rows = _shift_range(0, options["maxShift"], options["maxShift"], (height - 1) // 2)
            columns = _shift_range(0, options["maxShift"], options["maxShift"], (width - 1) // 2)
            dy, dx = _peak(correlation[:, :, 0], None, rows, columns, False)
            value = correlation[dy % height, dx % width, 0]
            if best is None or value > best[0]:
                best = (value, angle, dy, dx)
        _, angle, dy, dx = best
        shifts.append({"key": entity.key, "shift": [dy, dx], "rotation": angle})
        if number > 0:
            moved = []
            for roi in rois:
                pixels = rotate_points(np.asarray(roi["pixels"], dtype=np.float64).reshape(-1, 2) + [dy, dx], angle, height, width)
                pixels = sorted({(int(y), int(x)) for y, x in pixels if 0 <= y < height and 0 <= x < width})
                if pixels:
                    moved.append(_roi(roi.get("id", len(moved) + 1), pixels))
            context.project.save(entity, options["output"], {"imageSize": [height, width], "rois": moved})
            migrated += 1
        context.progress((number + 1) / len(entities), _name(entity))
    context.log(f"aligned {len(entities)} entities to {_name(entities[0])}")
    return {"reference": entities[0].key, "shifts": shifts, "migrated": migrated, "rois": len(rois)}


def _turn(angle):
    """The rotation by angle degrees of (row, column) vectors: [[cos, -sin], [sin, cos]]."""
    radians = math.radians(angle)
    return math.cos(radians), math.sin(radians)


def rotate_points(points, angle, height, width):
    """(row, column) points (n x 2) turned by angle degrees about the image centre and rounded half up."""
    if not angle:
        return np.floor(points + 0.5)
    cos, sin = _turn(angle)
    cy, cx = (height - 1) / 2, (width - 1) / 2
    y, x = points[:, 0] - cy, points[:, 1] - cx
    return np.floor(np.stack([cos * y - sin * x + cy, sin * y + cos * x + cx], axis=1) + 0.5)


def rotate_image(image, angle):
    """The image turned back by angle degrees about its centre: out[p] = image at rotation(angle) * (p - centre)
    + centre, bilinearly, and the image's mean where that is outside it."""
    height, width = image.shape
    cos, sin = _turn(angle)
    cy, cx = (height - 1) / 2, (width - 1) / 2
    rows, columns = np.mgrid[0:height, 0:width].astype(np.float64)
    y, x = rows - cy, columns - cx
    dy = cos * y - sin * x + cy - rows
    dx = sin * y + cos * x + cx - columns
    out = warp(image[:, :, None].astype(np.float64), dy[None], dx[None])[:, :, 0]
    inside = warp(np.ones((height, width, 1)), dy[None], dx[None])[:, :, 0] > 0.5
    return np.where(inside, out, image.mean())


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


METADATA_COLUMNS = [("frameRate", "frame_rate"), ("pixelSize", "pixel_size_um"), ("zStep", "z_step_um")]


def read_metadata(entity, options, context):
    """The frame rate, pixel size (its width) and z step the recording's files give (the stack's metadata), written into
    the entity's frame_rate, pixel_size_um and z_step_um columns, those its table has. Returns them by column."""
    metadata = context.project.open_stack(entity, options["stack"]).metadata
    values = {column: metadata[key][0] if key == "pixelSize" else metadata[key]
              for key, column in METADATA_COLUMNS if key in metadata}
    written = context.project.update_values(entity, values)
    context.log(f"{_name(entity)}: " + (", ".join(f"{n} {values[n]:g}" for n in written) or "nothing to write") +
                "".join(f"; no column {n}" for n in values if n not in written))
    return values


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
    ("MotionCorrectionShifts", "Motion correction shifts", "motion_correction_shifts.npy", "npy", "TimeSeries"),
    ("FrameStats", "Frame statistics", "frame_stats.npy", "npy", "TimeSeries"),
    ("FovAverageProjection", "Average projection", "fov_average_projection.npy", "npy", "Image"),
    ("FovMaximumProjection", "Maximum projection", "fov_maximum_projection.npy", "npy", "Image"),
    ("RoiArray", "ROIs", "roi_array.json", "json", "RoiArray"),
    ("RoiSignals_MeanF", "ROI signals", "roi_signals_mean_f.npy", "npy", "RoiSignals"),
    ("RoiSignals_NeuropilF", "Neuropil signals", "roi_signals_neuropil_f.npy", "npy", "RoiSignals"),
    ("RoiSignals_Dff", "ROI ΔF/F", "roi_signals_dff.npy", "npy", "RoiSignals"),
    ("RoiSignals_Deconvolved", "Deconvolved spikes", "roi_signals_deconvolved.npy", "npy", "RoiSignals"),
    ("RoiSignals_Denoised", "Denoised calcium", "roi_signals_denoised.npy", "npy", "RoiSignals"),
    ("RoiImages", "ROI images and statistics", "roi_images.json", "json", "RoiImages"),
    ("TwoPhotonSeries_Denoised", "Denoised stack", "two_photon_series_denoised.npy", "npy", "ImageStack"),
    ("TwoPhotonSeries_Deinterleaved", "Deinterleaved stack", "two_photon_series_deinterleaved.npy", "npy", "ImageStack"),
    ("TwoPhotonSeries_Cropped", "Cropped stack", "two_photon_series_cropped.npy", "npy", "ImageStack"),
]

COLUMN_NAMES = {"MotionCorrectionShifts": ["rows", "columns"], "FrameStats": ["mean", "min", "max", "std"]}


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
        if name in COLUMN_NAMES:
            document["columnNames"] = COLUMN_NAMES[name]
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
        wanted = [(entity_type, f) for f in ("ophys.imaging", "ophys.scan", "ophys.image_stats", "ophys.fov_position", "ophys.fov_region")]
        if options["subjectType"] in project.entity_types:
            wanted.append((options["subjectType"], "ophys.cranial_window"))
        for owner, fragment_id in wanted:
            if fragment_id not in project.entity_type(owner).get("fragments", []):
                project.attach_fragment(owner, fragment_id)
                columns.append(fragment_id)
    context.log(f"added {len(created)} data variables to {entity_type}")
    return {"created": created, "existing": existing, "fragments": columns}


def suite2p(entity, options, context):
    """Run suite2p on the stack and keep its cells as ROIs, with their signals and spikes.

    Works with suite2p 1.x (default_settings / default_db, torch on the GPU when there is one) and 0.x
    (default_ops). Registration blocks are made to fit small frames. The options go to suite2p's settings (ops in
    0.x): tau, do_registration, nonrigid, sparse_mode (1.x: detection algorithm sparsery, else sourcery),
    threshold_scaling, max_iterations (1.x: sourcery's), spatial_scale, denoise, neucoeff (1.x: neuropil_coefficient),
    inner_neuropil_radius and min_neuropil_pixels.
    """
    try:
        import suite2p as s2p
        import tifffile
    except ImportError as error:
        raise NansenError("dependency-missing",
                          f"ophys.suite2p needs suite2p and tifffile ({error}): pip install suite2p tifffile") from None
    stack = _load_stack(entity, options["stack"], context, options)
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
        settings["tau"] = float(options["tau"])
        settings["diameter"] = [float(options["cellDiameter"])] * 2
        settings["run"]["do_registration"] = int(bool(options["registration"]))
        registration = settings["registration"]
        registration["nonrigid"] = bool(options["nonrigid"])
        registration["block_size"] = (block, block)
        registration["nimg_init"] = min(registration["nimg_init"], frames)
        detection = settings["detection"]
        detection["algorithm"] = "sparsery" if options["sparseMode"] else "sourcery"
        detection["block_size"] = (min(64, block), min(64, block))
        detection["threshold_scaling"] = float(options["thresholdScaling"])
        detection["denoise"] = bool(options["denoise"])
        detection["sparsery_settings"]["spatial_scale"] = int(options["spatialScale"])
        detection["sourcery_settings"]["max_iterations"] = int(options["maxIterations"])
        extraction = settings["extraction"]
        extraction["neuropil_coefficient"] = float(options["neuropilCoefficient"])
        extraction["inner_neuropil_radius"] = int(options["innerNeuropilRadius"])
        extraction["min_neuropil_pixels"] = int(options["minNeuropilPixels"])
        db = s2p.default_db()
        db.update(data_path=[str(folder)], file_list=["input.tif"], save_path0=str(folder))
        s2p.run_s2p(db=db, settings=settings)
    else:  # suite2p 0.x
        ops = s2p.default_ops()
        ops.update({"fs": options["framesPerSecond"], "diameter": options["cellDiameter"], "nchannels": 1, "nplanes": 1,
                    "block_size": [block, block], "nimg_init": min(ops.get("nimg_init", 200), frames),
                    "tau": float(options["tau"]), "do_registration": bool(options["registration"]),
                    "nonrigid": bool(options["nonrigid"]), "sparse_mode": bool(options["sparseMode"]),
                    "threshold_scaling": float(options["thresholdScaling"]), "max_iterations": int(options["maxIterations"]),
                    "spatial_scale": int(options["spatialScale"]), "denoise": bool(options["denoise"]),
                    "neucoeff": float(options["neuropilCoefficient"]),
                    "inner_neuropil_radius": int(options["innerNeuropilRadius"]),
                    "min_neuropil_pixels": int(options["minNeuropilPixels"])})
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

def _open_stack(entity, name, context, options=None):
    """The variable as a height x width x frames stack read a chunk at a time (an image is one frame).

    A stack with channels (height x width x channels x frames) or planes too (x channels x planes x frames)
    gives the options' channel and plane (1-based; the first when there is no such option). Only the options'
    frames firstFrame..lastFrame are given (_open_whole).
    """
    options = options or {}
    return _pick(_open_whole(entity, name, context, options), name, options.get("channel", 1), options.get("plane", 1))


def _open_whole(entity, name, context, options=None, per=1):
    """The variable as a stack of all its axes, height x width (x channels (x planes)) x frames (an image is one
    frame), read a chunk at a time: of the options' frames firstFrame..lastFrame only (from 1; lastFrame 0 for the
    last), per frames of the variable to each of them (deinterleave's channels x planes). A range that is empty or
    not within the stack is invalid-options. In a preview, the range is cut to its first frames."""
    from nansen.stacks import from_array
    options = options or {}
    first, last = int(options.get("firstFrame", 1)), int(options.get("lastFrame", 0))
    if first < 1 or last < 0 or 0 < last < first:
        raise NansenError("invalid-options", f"frames {first} to {last} are no frames: firstFrame is from 1, and lastFrame 0 (the last) or from firstFrame")
    stack = context.project.open_stack(entity, name)
    if stack.ndim == 2:
        limit, stack.max_frames = stack.max_frames, None   # an image's columns are not frames
        stack = from_array(np.asarray(stack)[:, :, None])
        stack.max_frames = limit
        if first > 1 or last > 1:
            raise NansenError("invalid-options", f"{name} is an image, one frame; frames {first} to {last} are not frames of it")
        return stack
    if first == 1 and last == 0:
        return stack
    try:
        return context.project.open_stack(entity, name, ((first - 1) * per, last * per if last else None))
    except NansenError as error:
        if error.code != "invalid-params":
            raise
        raise NansenError("invalid-options", f"{name}: {error.message}") from None


def _plane_stacks(entity, name, context, options):
    """The stack of all its axes (_open_whole), the height x width x frames stacks of the options' channel in the planes
    to take, and whether they are every plane: with plane 0, every plane of a stack with planes (height x width x
    channels x planes x frames), one after the other; else the options' plane (a stack without planes is one plane)."""
    whole = _open_whole(entity, name, context, options)
    channel, plane = options.get("channel", 1), options.get("plane", 1)
    if plane == 0 and whole.ndim == 5:
        return whole, [_pick(whole, name, channel, p) for p in range(1, whole.shape[3] + 1)], True
    return whole, [_pick(whole, name, channel, plane or 1)], False


def _save_planes(entity, name, images, every, context):
    """Images (height x width) of one plane, or with every plane, of each, saved as height x width x 1 x planes x 1: a
    stack of one channel and one frame, its planes on their own axis, as data.frame's plane picks them."""
    if name:
        context.project.save(entity, name, np.stack(images, axis=2)[:, :, None, :, None] if every else images[0])


def _pick(stack, name, channel, plane):
    """One channel and plane of a 3-, 4- or 5-dimensional stack, as height x width x frames (still lazy)."""
    channels = stack.shape[2] if stack.ndim >= 4 else 1
    planes = stack.shape[3] if stack.ndim == 5 else 1
    if stack.ndim > 5:
        raise NansenError("invalid-data", f"{name} is {stack.shape}; a stack is height x width (x channels (x planes)) x frames")
    if not 1 <= channel <= channels:
        raise NansenError("invalid-options", f"{name} has {channels} channel{'s' if channels > 1 else ''}; channel {channel} is not one")
    if not 1 <= plane <= planes:
        raise NansenError("invalid-options", f"{name} has {planes} plane{'s' if planes > 1 else ''}; plane {plane} is not one")
    if stack.ndim == 5:
        return stack.select(slice(None), slice(None), channel - 1, plane - 1)
    if stack.ndim == 4:
        return stack.select(slice(None), slice(None), channel - 1)
    return stack


def _load_stack(entity, name, context, options=None):
    """The variable as a height x width x frames array, read whole (for methods that need every frame at once)."""
    return np.asarray(_open_stack(entity, name, context, options))


def roi_images(entity, options, context):
    """dev's ROI classifier images and statistics (computeRoiImages, imageprops, dffprops), for the gallery.

    Around each ROI's center (rounded half up) a box of boxSize pixels (odd) is cut from three images: the mean of the
    frames weighted by the ROI's ΔF/F (normalised to 0..1, then 1 / (1 + exp(-10 (x - 0.5)))), the mean of the frames
    of its top 1% ΔF/F (at least 50, or all frames when there are fewer; ties in frame order), both less the box's
    mean over every frame, and the FOV's local correlation image, each scaled to 0..255 (dev's AutoAdjust). Outside the
    image the box is 0. The statistics are
    the peak ΔF/F, the salience ((ROI - surround + 1) / (surround + 1) of the top 1% image, its mean inside and
    outside the ROI in the box) and the Pearson correlation of each weighted-mean and correlation image with their
    mean over the ROIs (dev's templateSimilarity). Signal columns are the ROIs', or those not rejected when there
    are fewer, as extract_signals saves them. Values are rounded to 4 decimals; null where undefined."""
    from nansen.frames import local_correlation, rois_at
    stack = _open_stack(entity, options["stack"], context, options)
    height, width, frames = stack.shape
    document = rois_at(context.project.load(entity, options["rois"]), options.get("plane", 1), options.get("channel", 1))
    rois = document.get("rois", [])
    dff = _as_traces(context.project.load(entity, options["signals"]))
    if dff.shape[0] != frames:
        raise NansenError("invalid-data", f"{options['signals']} has {dff.shape[0]} frames; the stack has {frames}")
    if len(rois) != dff.shape[1]:
        rois = [roi for roi in rois if roi.get("classification") != "rejected"]
        if len(rois) != dff.shape[1]:
            raise NansenError("invalid-data", f"{options['signals']} has {dff.shape[1]} columns, not one per ROI")
    size = int(options["boxSize"]) | 1   # odd, so the center is a pixel
    half = size // 2
    top_count = int(np.floor(frames * 0.01 + 0.5))
    if top_count < 50:
        top_count = min(50, frames)
    boxes, weights, tops = [], [], []
    for k, roi in enumerate(rois):
        r0, c0 = (int(np.floor(v + 0.5)) for v in roi["center"])
        rows, columns = np.arange(r0 - half, r0 + half + 1), np.arange(c0 - half, c0 + half + 1)
        boxes.append((rows, columns, (rows >= 0) & (rows < height), (columns >= 0) & (columns < width)))
        d = dff[:, k]
        span = d.max() - d.min()
        normalised = (d - d.min()) / span if span > 0 else np.zeros(frames)
        weights.append(1 / (1 + np.exp(-10 * (normalised - 0.5))))
        top = np.zeros(frames, dtype=bool)
        top[np.argsort(-d, kind="stable")[:top_count]] = True
        tops.append(top)
    total = np.zeros(len(rois))
    weighted = np.zeros((len(rois), size, size))
    topped = np.zeros((len(rois), size, size))
    for start in range(0, frames, CHUNK):
        chunk = stack.frames(start, start + CHUNK).astype(np.float64)
        for k, (rows, columns, in_rows, in_columns) in enumerate(boxes):
            patch = np.zeros((size, size, chunk.shape[2]))
            patch[np.ix_(in_rows, in_columns)] = chunk[np.ix_(rows[in_rows], columns[in_columns])]
            total[k] += patch.sum()
            weighted[k] += patch @ weights[k][start:start + chunk.shape[2]]
            topped[k] += patch[:, :, tops[k][start:start + chunk.shape[2]]].sum(axis=2)
    correlation = local_correlation(stack)
    images = {"activityWeightedMean": [], "top1Percent": [], "localCorrelation": []}
    stats = {"peakDff": [], "salience": [], "meanSimilarity": [], "correlationSimilarity": []}
    for k, (roi, (rows, columns, in_rows, in_columns)) in enumerate(zip(rois, boxes)):
        valid = np.outer(in_rows, in_columns)
        mean = total[k] / (valid.sum() * frames)
        mean_image = np.where(valid, weighted[k] / frames - mean * weights[k].sum() / frames, 0.0)
        top_image = np.where(valid, topped[k] / top_count - mean, 0.0)
        correlation_image = np.zeros((size, size))
        correlation_image[np.ix_(in_rows, in_columns)] = correlation[np.ix_(rows[in_rows], columns[in_columns])]
        mean_image, top_image, correlation_image = (_autoadjust(image, valid) for image in (mean_image, top_image, correlation_image))
        images["activityWeightedMean"].append(mean_image)
        images["top1Percent"].append(top_image)
        images["localCorrelation"].append(correlation_image)
        inside = np.zeros((size, size), dtype=bool)
        for r, c in roi.get("pixels", []):
            if rows[0] <= r <= rows[-1] and columns[0] <= c <= columns[-1]:
                inside[r - rows[0], c - columns[0]] = True
        outside = valid & ~inside
        roi_mean = top_image[inside].mean() if inside.any() else np.nan
        surround = top_image[outside].mean() if outside.any() else np.nan
        stats["peakDff"].append(dff[:, k].max())
        stats["salience"].append((roi_mean - surround + 1) / (surround + 1))
    for name, key in (("activityWeightedMean", "meanSimilarity"), ("localCorrelation", "correlationSimilarity")):
        template = np.mean(images[name], axis=0) if images[name] else None
        stats[key] = [_pearson(template.ravel(), image.ravel()) for image in images[name]]
    rounded = lambda v: None if v is None or not np.isfinite(v) else float(np.floor(v * 1e4 + 0.5) / 1e4)
    output = {"boxSize": size, "ids": [roi.get("id", k + 1) for k, roi in enumerate(rois)],
              "images": {name: [[rounded(v) for v in image.ravel()] for image in values] for name, values in images.items()},
              "stats": {name: [rounded(v) for v in values] for name, values in stats.items()}}
    _save(entity, options["output"], output, context)
    context.log(f"{_name(entity)}: images and statistics of {len(rois)} ROIs")
    return {"rois": len(rois), "boxSize": size, "stats": output["stats"]}


def _autoadjust(image, valid):
    """An ROI image scaled to 0..255 over the box's pixels inside the image, as dev's AutoAdjust (kept as floats); 0
    outside, and everywhere when the image is flat."""
    low, high = image[valid].min(), image[valid].max()
    if not high > low:
        return np.zeros_like(image)
    return np.where(valid, (image - low) / (high - low) * 255, 0.0)


def _as_traces(data):
    traces = np.asarray(data, dtype=np.float64)
    return traces[:, None] if traces.ndim == 1 else traces


def _save(entity, name, data, context):
    if name:
        context.project.save(entity, name, data)


def _name(entity):
    return " / ".join(map(str, entity.key.values()))
