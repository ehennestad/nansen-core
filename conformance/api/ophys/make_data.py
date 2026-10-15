"""Write this case's recordings, and print the values the steps expect.

Run from the repository root: python conformance/api/ophys/make_data.py

The expected values come from the ground truth the recordings are made from (the shifts, the cells'
disks, the scene before it was moved), computed here directly, not with either reader's ophys code.
The recordings are 32 x 32 pixels and 40 frames: three disk-shaped cells of radius 2 with their own
activity on a static textured background, with noise, each frame displaced by a known whole-pixel shift.
"""

import json
import math
from pathlib import Path

import numpy as np

HERE = Path(__file__).parent
HEIGHT, WIDTH, FRAMES, PAD = 32, 32, 40, 4
CELLS = [(10, 12), (14, 23), (22, 9)]  # (row, column) centres, in the aligned frame


def round_to(value, digits):
    value = float(value)
    return None if not math.isfinite(value) else math.floor(value * 10 ** digits + 0.5) / 10 ** digits


def scene(seed):
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:HEIGHT + 2 * PAD, 0:WIDTH + 2 * PAD]
    texture = rng.normal(0, 1, yy.shape)
    texture = sum(np.roll(np.roll(texture, dy, axis=0), dx, axis=1) for dy in (-1, 0, 1) for dx in (-1, 0, 1)) / 3
    movie = np.repeat((200 + 20 * np.sin(yy / 3.0) + 40 * texture)[:, :, None], FRAMES, axis=2)
    disks = []
    for cy, cx in CELLS:
        disk = (yy - cy - PAD) ** 2 + (xx - cx - PAD) ** 2 <= 4
        movie[disk] += rng.random(FRAMES) ** 2 * 600
        disks.append(disk[PAD:PAD + HEIGHT, PAD:PAD + WIDTH])
    movie += rng.normal(0, 3, movie.shape)
    movie = np.clip(np.round(movie), 0, 65535)
    shifts = rng.integers(-3, 4, size=(FRAMES, 2))
    shifts[0] = 0
    recording = np.zeros((HEIGHT, WIDTH, FRAMES))
    aligned = np.zeros((HEIGHT, WIDTH, FRAMES))
    for t, (dy, dx) in enumerate(shifts):
        recording[:, :, t] = movie[PAD - dy:PAD - dy + HEIGHT, PAD - dx:PAD - dx + WIDTH, t]  # displaced by (dy, dx)
        aligned[:, :, t] = movie[PAD:PAD + HEIGHT, PAD:PAD + WIDTH, t]
        # moving the frame back leaves rows and columns it does not cover at 0
        aligned[:max(0, -dy), :, t] = 0
        aligned[HEIGHT - max(0, dy):, :, t] = 0
        aligned[:, :max(0, -dx), t] = 0
        aligned[:, WIDTH - max(0, dx):, t] = 0
    return recording.astype(np.uint16), aligned, shifts, disks, movie


def write_sciscan(path, stack):
    """SciScan's .raw and .ini: 30.9 frames per second, and a FOV of 512 x 384 µm (16 x 12 µm pixels)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    stack.transpose(2, 0, 1).astype(">u2").tofile(path)  # frame after frame, line after line, big-endian
    path.with_suffix(".ini").write_text(
        f'[_]\nx.pixels = {WIDTH}\ny.pixels = {HEIGHT}\nno.of.channels = 1\nno.of.frames.acquired = {FRAMES}\n'
        f'file.format = 0\nsave.ch.1 = "TRUE"\nframes.p.sec = "30,9"\nx.fov = 5.12E-4\ny.fov = 3.84E-4\n', encoding="latin-1")


def ring(disk, others, gap, width):
    """Pixels whose square distance to the disk is gap+1 .. gap+width, in no disk."""
    ys, xs = np.nonzero(disk)
    out = np.zeros_like(disk)
    for y in range(HEIGHT):
        for x in range(WIDTH):
            distance = np.max(np.abs(np.stack([ys - y, xs - x])), axis=0).min()
            out[y, x] = gap < distance <= gap + width and not others[y, x]
    return out


def neuropil_slices(neuropil, disk, count):
    """dev's splitNeuropilMasks (FISSA's split_npil), with numpy's histogram and percentile: the angle of each
    neuropil pixel from the disk's centroid, turned so it starts in the middle of the least populated of 20 bins,
    cut at its count quantiles."""
    ys, xs = np.nonzero(disk)
    rows, columns = np.nonzero(neuropil)
    theta = np.arctan2(rows - ys.mean(), columns - xs.mean())
    counts, edges = np.histogram(theta, bins=np.linspace(-np.pi, np.pi, 21))
    theta = (theta - (edges[np.argmin(counts)] + np.pi / 20)) % (2 * np.pi) - np.pi
    bounds = [-np.inf] + [np.percentile(theta, 100.0 * (k + 1) / count) for k in range(count)]
    out = []
    for k in range(count):
        part = np.zeros_like(neuropil)
        chosen = (theta > bounds[k]) & (theta <= bounds[k + 1])
        part[rows[chosen], columns[chosen]] = True
        out.append(part)
    return out


def frame_bytes(image, limits=None):
    """The viewer's 8-bit frame, as the protocol describes it: base64 of the bytes, row after row."""
    import base64
    low, high = (image.min(), image.max()) if limits is None else limits
    scaled = np.clip(np.floor((image - low) / (high - low) * 255 + 0.5), 0, 255).astype(np.uint8)
    return {"low": float(low), "high": float(high), "pixels": base64.b64encode(scaled.tobytes()).decode("ascii")}


def deconvolution_truth(trace, g, lam):
    """The deconvolution's optimum, found by a general bounded optimiser (not OASIS)."""
    from scipy.optimize import minimize
    T = len(trace)
    K = np.array([[g ** (t - k) if t >= k else 0.0 for k in range(T)] for t in range(T)])
    objective = lambda s: 0.5 * np.sum((K @ s - trace) ** 2) + lam * np.sum(s)
    gradient = lambda s: K.T @ (K @ s - trace) + lam
    result = minimize(objective, np.full(T, 0.1), jac=gradient, bounds=[(0, None)] * T, method="L-BFGS-B",
                      options={"ftol": 1e-16, "gtol": 1e-12, "maxiter": 50000, "maxfun": 50000})
    return K @ result.x, result.x


def deconvolution_ar2_truth(trace, d, r, lam):
    """OASIS for an AR(2) model, g1 = d + r and g2 = -d r (Friedrich et al. 2017), written out plainly from its
    definition (not either reader's code). It is greedy, so not the optimum a general optimiser finds: frames are taken
    one at a time as pools of their own; each pool's first value is fitted by least squares to y less the penalty's
    weight on each frame, with the pools before it fixed (the first pool decays by d, the others follow the AR(2)
    recursion from the last value of the one before), and a pool whose first value is below what the pool before it
    would continue to is merged with it. With lam 0 it gives what CaImAn's OASIS class (with g2) gives."""
    T = len(trace)
    g1, g2 = d + r, -d * r
    D = np.zeros((T, T))   # s = D c: s_0 = c_0, s_1 = c_1 - d c_0, s_t = c_t - g1 c_t-1 - g2 c_t-2
    for t in range(T):
        D[t, t] = 1
        if t == 1:
            D[t, 0] = -d
        elif t >= 2:
            D[t, t - 1], D[t, t - 2] = -g1, -g2
    target = trace - lam * D.sum(axis=0)

    def run(start, length, value, before):
        c = [value]
        for k in range(1, length):
            c.append(d * c[-1] if before is None else g1 * c[-1] + g2 * (c[-2] if k > 1 else before))
        return np.array(c)

    def fitted(pools):
        values, c = [], np.zeros(T)
        for i, (start, length) in enumerate(pools):
            before = None if i == 0 else c[start - 1]
            base, unit = run(start, length, 0.0, before), run(start, length, 1.0, before) - run(start, length, 0.0, before)
            value = unit @ (target[start:start + length] - base) / (unit @ unit)
            value = max(value, 0.0) if i == 0 else value
            values.append(value)
            c[start:start + length] = run(start, length, value, before)
        return values, c

    pools = []
    for t in range(T):
        pools.append((t, 1))
        while len(pools) > 1:
            values, c = fitted(pools)
            start = pools[-1][0]
            continued = d * c[start - 1] if len(pools) == 2 else g1 * c[start - 1] + g2 * c[start - 2]
            if values[-1] >= continued:
                break
            pools[-2:] = [(pools[-2][0], pools[-2][1] + pools[-1][1])]
    calcium = fitted(pools)[1]
    return calcium, D @ calcium


def smooth_naive(data, axis, sigma):
    """Gaussian smoothing along an axis, weights renormalised where the window leaves the data, one sample at a time."""
    radius = int(math.ceil(3 * sigma))
    moved = np.moveaxis(data, axis, -1)
    out = np.zeros_like(moved)
    n = moved.shape[-1]
    for i in range(n):
        offsets = [k for k in range(-radius, radius + 1) if 0 <= i + k < n]
        weights = np.array([math.exp(-k * k / (2 * sigma * sigma)) for k in offsets])
        out[..., i] = sum(w * moved[..., i + k] for w, k in zip(weights, offsets)) / weights.sum()
    return np.moveaxis(out, -1, axis)


def write_scanimage(path, rng):
    """A multi-ROI ScanImage file: 2 ROIs of 16 x 32 one above the other with 4 flyback lines, 2 channels,
    2 planes, 3 volumes; returns the stack as the reader gives it (16 x 64 x channels x planes x volumes). 7.5 volumes
    per second, planes 4 µm apart (actualStackZStepSize, not stackZStepSize), and ROIs of 3.2 x 1.6 degrees at 15 µm per
    degree: 1.5 µm pixels."""
    import tifffile
    strips = rng.integers(0, 4000, size=(2, 16, 32, 2, 2, 3)).astype(np.uint16)  # roi, y, x, channel, plane, volume
    pages = []
    for volume in range(3):
        for plane in range(2):
            for channel in range(2):
                page = np.full((36, 32), 9999, dtype=np.uint16)  # flyback lines
                page[:16] = strips[0, :, :, channel, plane, volume]
                page[20:] = strips[1, :, :, channel, plane, volume]
                pages.append(page)
    software = ("SI.VERSION_MAJOR = 2020\nSI.hChannels.channelSave = [1;2]\nSI.hStackManager.numSlices = 2\nSI.hRoiManager.mroiEnable = true\n"
                "SI.hRoiManager.scanFrameRate = 30\nSI.hRoiManager.scanVolumeRate = 7.5\nSI.hStackManager.actualStackZStepSize = 4\n"
                "SI.hStackManager.stackZStepSize = 5\nSI.objectiveResolution = 15\n")
    artist = json.dumps({"RoiGroups": {"imagingRoiGroup": {"rois": [
        {"name": "A", "scanfields": {"pixelResolutionXY": [32, 16], "sizeXY": [3.2, 1.6]}},
        {"name": "B", "scanfields": {"pixelResolutionXY": [32, 16], "sizeXY": [3.2, 1.6]}}]}}})
    path.parent.mkdir(parents=True, exist_ok=True)
    # two files, as ScanImage splits a recording: the second volume begins in the first file and ends in the
    # second. The tags go on each file's first page, which is where the readers look
    for part, chunk in enumerate([pages[:7], pages[7:]], start=1):
        tifffile.imwrite(path.with_name(f"rec_{part:05d}.tif"), np.stack(chunk), photometric="minisblack", software=software,
                         extratags=[(315, "s", 0, artist, False)], metadata=None)
    return np.concatenate([strips[0], strips[1]], axis=1)


def percentile(values, p):
    ordered = np.sort(values)
    position = (len(ordered) - 1) * p / 100
    low = int(math.floor(position))
    high = min(low + 1, len(ordered) - 1)
    return ordered[low] + (position - low) * (ordered[high] - ordered[low])


def scaled_bytes(image, low, high):
    """data.frame's pixels: values from low to high scaled to 0..255, rounded half up, cut at both ends, row after row."""
    import base64
    scaled = np.clip(np.floor((image - low) / (high - low) * 255 + 0.5), 0, 255).astype(np.uint8)
    return base64.b64encode(scaled.tobytes()).decode("ascii")


def projections_expected(aligned):
    """The viewer's std and correlation projections of the aligned recording, from their definitions: each pixel's
    standard deviation over time, and its average Pearson correlation over time with its in-frame 8 neighbours."""
    std = aligned.std(axis=2)
    z = np.divide(aligned - aligned.mean(axis=2, keepdims=True), std[:, :, None], out=np.zeros_like(aligned), where=std[:, :, None] > 0)
    total, count = np.zeros(std.shape), np.zeros(std.shape)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dy or dx:
                for y in range(HEIGHT):
                    for x in range(WIDTH):
                        if 0 <= y + dy < HEIGHT and 0 <= x + dx < WIDTH:
                            total[y, x] += (z[y, x] * z[y + dy, x + dx]).mean()
                            count[y, x] += 1
    correlation = total / count
    return {"std": scaled_bytes(std, 0, 200), "correlation": scaled_bytes(correlation, -1, 1)}


def mean_clahe_expected(stack):
    """The viewer's Mean CLAHE projection (dev's meanclahe: MATLAB's adapthisteq with 32 x 32 tiles, clip limit 0.015,
    256 bins and a Rayleigh distribution of alpha 0.4, of the mean normalised to 0..1, scaled back and rounded as the
    stack's uint16), worked out pixel by pixel: the 32 x 32 image is mirrored out to 64 x 64 (16 on every side), so the
    tiles are 2 x 2 pixels; each tile's histogram (bin floor(v 255 + 0.5)) is clipped at 1 + round(0.015 (4 - 1)) = 1
    and the excess handed back as adapthisteq does; a pixel's value mixes the mappings of the tiles whose centres are
    around it, by its distance from them (one or two tiles in the outer half tiles)."""
    average = stack.astype(float).mean(axis=2)
    low, high = average.min(), average.max()
    normal = (average - low) / (high - low)
    tiles, pad = 32, 16
    padded = np.pad(normal, pad, mode="symmetric")
    size = padded.shape[0] // tiles   # 2
    count = size * size
    least = -(-count // 256)
    limit = least + math.floor(0.015 * (count - least) + 0.5)
    bins = np.floor(padded * 255 + 0.5).astype(int)
    hconst = 2 * 0.4 ** 2
    vmax = 1 - math.exp(-1 / hconst)
    maps = {}
    for ty in range(tiles):
        for tx in range(tiles):
            histogram = list(np.bincount(bins[ty * size:(ty + 1) * size, tx * size:(tx + 1) * size].ravel(), minlength=256))
            excess = sum(max(v - limit, 0) for v in histogram)
            share = excess // 256
            for b in range(256):   # the excess handed back evenly, then one at a time
                if histogram[b] > limit:
                    histogram[b] = limit
                elif histogram[b] > limit - share:
                    excess -= limit - histogram[b]
                    histogram[b] = limit
                else:
                    excess -= share
                    histogram[b] += share
            start = 0
            while excess:
                for b in range(start, 256, max(256 // excess, 1)):
                    if histogram[b] < limit:
                        histogram[b] += 1
                        excess -= 1
                        if not excess:
                            break
                start = (start + 1) % 256
            value = vmax * (np.cumsum(histogram).astype(float) / count)
            value[value >= 1] = 1 - np.finfo(float).eps
            maps[ty, tx] = np.minimum(np.sqrt(-hconst * np.log(1 - value)), 1)
    half = size // 2

    def around(p):
        """(the two tiles, the block's length, the pixel's place in it) along one axis of the padded image"""
        if p < half:
            return (0, 0), half, p
        if p >= half + (tiles - 1) * size:
            return (tiles - 1, tiles - 1), half, p - half - (tiles - 1) * size
        k = (p - half) // size
        return (k, k + 1), size, (p - half) % size

    out = np.zeros(padded.shape)
    for y in range(padded.shape[0]):
        (t0, t1), ny, a = around(y)
        for x in range(padded.shape[1]):
            (s0, s1), nx, b = around(x)
            v = bins[y, x]
            out[y, x] = ((ny - a) * ((nx - b) * maps[t0, s0][v] + b * maps[t0, s1][v])
                         + a * ((nx - b) * maps[t1, s0][v] + b * maps[t1, s1][v])) / (ny * nx)
    image = out[pad:pad + HEIGHT, pad:pad + WIDTH] * (high - low) + low
    image = np.clip(np.floor(image + 0.5), 0, 65535)   # uint16
    return frame_bytes(image)["pixels"]


def preview_expected(first):
    stats = lambda image: {"size": list(image.shape), "min": round_to(image.min(), 4), "max": round_to(image.max(), 4), "mean": round_to(image.mean(), 4)}
    average, maximum = first.astype(float).mean(axis=2), first.max(axis=2).astype(float)
    return {"frames": 5, "results": [{"n_frames": 5, "height": HEIGHT, "width": WIDTH, "mean_intensity": round_to(first.astype(float).mean(), 4),
                                      "max_intensity": float(first.max())}],
            "outputs": [dict(name="FovAverageProjection", kind="array", **stats(average)), dict(name="FovMaximumProjection", kind="array", **stats(maximum)),
                        dict(name="FrameStats", kind="array", **stats(frame_stats(first)))]}


def frame_stats(stack):
    """image_stats' per-frame stats: each frame's mean, minimum, maximum and (population) standard deviation."""
    flat = stack.astype(float).reshape(-1, stack.shape[2])
    return np.stack([flat.mean(axis=0), flat.min(axis=0), flat.max(axis=0), flat.std(axis=0)], axis=1)


def moved_back(frame, dy, dx):
    """A frame displaced by (dy, dx) moved back: out[y, x] = frame[y + dy, x + dx], 0 outside."""
    out = np.zeros((HEIGHT, WIDTH))
    for y in range(HEIGHT):
        for x in range(WIDTH):
            if 0 <= y + dy < HEIGHT and 0 <= x + dx < WIDTH:
                out[y, x] = frame[y + dy, x + dx]
    return out


def ranges_and_planes_expected(recording, aligned, shifts, disks, scanimage):
    """What the steps of frame ranges (firstFrame..lastFrame) and of every plane in one run (plane 0) expect.

    Session 1's recording deinterleaved as 2 planes is the recording of two planes: the even frames (from 0) are
    plane 1, the odd ones plane 2. Each plane is aligned to its own first frame: plane 1 to frame 0 (no shift), so its
    shifts are the true ones; plane 2 to frame 1, so its shifts are the true ones less frame 1's, and its cells are
    the disks displaced by frame 1's shift."""
    four = lambda v: math.floor(v * 10000 + 0.5) / 10000
    motion = lambda found: {"maxShift": int(np.abs(found).max()), "meanShift": round_to(np.sqrt((found ** 2).sum(axis=1)).mean(), 4)}
    pixels = lambda mask: [[int(y), int(x)] for y, x in zip(*np.nonzero(mask))]
    union = np.any(disks, axis=0)
    signals = np.stack([aligned[d].mean(axis=0) for d in disks], axis=1)
    neuropil = np.stack([aligned[ring(d, union, 1, 3)].mean(axis=0) for d in disks], axis=1)
    expected = {}
    # frames 11..30 (from 1) of the raw recording
    part = recording[:, :, 10:30].astype(float)
    expected["rangeStats"] = {"n_frames": 20, "height": HEIGHT, "width": WIDTH, "mean_intensity": round_to(part.mean(), 4), "max_intensity": float(part.max())}
    # motion correction of frames 1..25: the reference is frame 1, at no shift, so the shifts are the true ones
    expected["rangeMotion"] = dict(frames=25, **motion(shifts[:25]))
    expected["rangeFrame"] = {"frames": 25, "frame": 3, **frame_bytes(aligned[:, :, 3], (0, 1000))}
    # of frames 11..30: the reference is frame 11, so each frame's shift is its own less frame 11's
    expected["rangeMotionLater"] = dict(frames=20, **motion(shifts[10:30] - shifts[10]))
    # ROIs and signals of frames 6..25 of the aligned frames 1..25: aligned frames 6..25
    expected["rangeRois"] = {"rois": len(disks), "areas": [int(d.sum()) for d in disks]}
    expected["rangeSignals"] = {"rois": len(disks), "frames": 20, "ids": [1, 2, 3],
                                "meanSignal": [round_to(v, 4) for v in signals[5:25].mean(axis=0)],
                                "meanNeuropil": [round_to(v, 4) for v in neuropil[5:25].mean(axis=0)]}
    expected["rangeSignalTraces"] = {"frames": 20, "traces": [{"variable": "RoiSignals_Range", "count": 3}]}
    # a preview of frames 11..30 on its first 5 frames: frames 11..15
    first = recording[:, :, 10:15].astype(float)
    expected["rangePreview"] = {"frames": 5, "results": [{"n_frames": 5, "mean_intensity": round_to(first.mean(), 4), "max_intensity": float(first.max())}],
                                "outputs": [{"name": "FovAverageProjection", "size": [32, 32]}, {"name": "FovMaximumProjection", "size": [32, 32]},
                                            {"name": "FrameStats", "size": [5, 4]}]}
    # deinterleaved as 2 channels, pairs 3..6 (from 1): channel 2 (from 0: 1) of pair 3 is frame 6 (from 1)
    expected["rangeDeinterleave"] = {"frames": 4, "channels": 2, "planes": 1}
    expected["rangePairsFrame"] = {"height": HEIGHT, "width": WIDTH, "frames": 4, "channels": 2, "planes": 1, "frame": 0,
                                   **frame_bytes(recording[:, :, 5].astype(float))}

    even, odd = shifts[0::2], shifts[1::2]
    relative = odd - shifts[1]
    one = np.stack([moved_back(recording[:, :, 2 * k].astype(float), *even[k]) for k in range(FRAMES // 2)], axis=2)
    two = np.stack([moved_back(recording[:, :, 2 * k + 1].astype(float), *relative[k]) for k in range(FRAMES // 2)], axis=2)
    both = np.stack([one, two])
    picked = list(range(0, 20, 4))
    expected["planesDeinterleave"] = {"frames": 20, "channels": 1, "planes": 2}
    expected["planesFrame"] = {"frames": 20, "channels": 1, "planes": 2, "frame": 2, **frame_bytes(recording[:, :, 5].astype(float))}
    expected["planesMotion"] = dict(frames=20, **motion(np.concatenate([even, relative])),
                                    planes=[dict(plane=1, **motion(even)), dict(plane=2, **motion(relative))])
    expected["planesCorrectedFrame1"] = {"frames": 20, "channels": 1, "planes": 2, "frame": 1, **frame_bytes(one[:, :, 1], (0, 1000))}
    expected["planesCorrectedFrame2"] = {"frames": 20, "channels": 1, "planes": 2, "frame": 2, **frame_bytes(two[:, :, 2], (0, 1000))}
    # the shifts of the planes side by side: plane 1's rows and columns, then plane 2's
    expected["planesShiftTraces"] = {"frames": 20, "start": 0, "step": 4, "points": 5, "traces": [{"variable": "PlaneShifts", "count": 4, "columns": [
        {"column": 0, "values": [float(even[t, 0]) for t in picked]}, {"column": 3, "values": [float(relative[t, 1]) for t in picked]}]}]}
    expected["planesStats"] = {"n_frames": 20, "height": HEIGHT, "width": WIDTH, "mean_intensity": round_to(both.mean(), 4), "max_intensity": float(both.max()),
                               "planes": [{"plane": p + 1, "mean_intensity": round_to(s.mean(), 4), "max_intensity": float(s.max())} for p, s in enumerate(both)]}
    # the average projections as a stack of one frame per plane; plane 2's
    expected["planesAverage"] = {"frames": 1, "channels": 1, "planes": 2, "frame": 0, **frame_bytes(two.mean(axis=2), (0, 1000))}
    expected["planesFrameStats"] = {"frames": 20, "traces": [{"variable": "PlaneFrameStats", "count": 8, "columns": [
        {"column": 0, "values": [four(one[:, :, t].mean()) for t in picked]}, {"column": 4, "values": [four(two[:, :, t].mean()) for t in picked]}]}]}
    # ROIs of both planes in one file, with their places: three in each (on 20 frames, plane 1's second cell is found
    # a pixel too large, so only plane 2's are checked pixel by pixel; the pixels of plane 1's are then set to the disks)
    dy, dx = shifts[1]
    moved = [np.roll(d, (dy, dx), axis=(0, 1)) for d in disks]
    expected["planesRois"] = {"rois": 6, "planes": [{"plane": 1, "rois": 3}, {"plane": 2, "rois": 3}]}
    expected["planesRoisFirst"] = {"rois": [{"id": 1}, {"id": 2}, {"id": 3}]}
    expected["planesRoisSecond"] = {"rois": [{"id": n + 4, "pixels": pixels(d)} for n, d in enumerate(moved)]}
    expected["diskPixels"] = [{"id": n + 1, "pixels": pixels(d)} for n, d in enumerate(disks)]
    expected["planesRoisCurated"] = {"added": [], "rois": expected["diskPixels"]}
    # signals of each ROI from its own plane, the columns in the file's order; the neuropil around the ROIs of its plane
    moved_union = np.any(moved, axis=0)
    plane_signals = np.concatenate([np.stack([one[d].mean(axis=0) for d in disks], axis=1),
                                    np.stack([two[d].mean(axis=0) for d in moved], axis=1)], axis=1)
    plane_neuropil = np.concatenate([np.stack([one[ring(d, union, 1, 3)].mean(axis=0) for d in disks], axis=1),
                                     np.stack([two[ring(d, moved_union, 1, 3)].mean(axis=0) for d in moved], axis=1)], axis=1)
    expected["planesSignals"] = {"rois": 6, "frames": 20, "ids": [1, 2, 3, 4, 5, 6],
                                 "meanSignal": [round_to(v, 4) for v in plane_signals.mean(axis=0)],
                                 "meanNeuropil": [round_to(v, 4) for v in plane_neuropil.mean(axis=0)],
                                 "planes": [{"plane": 1, "rois": 3}, {"plane": 2, "rois": 3}]}
    expected["planesSignalTraces"] = {"frames": 20, "start": 0, "step": 4, "points": 5, "traces": [{"variable": "RoiSignals_Planes", "count": 6, "columns": [
        {"column": c, "values": [four(plane_signals[t, c]) for t in picked]} for c in (0, 3)]}], "rois": [{"id": n} for n in range(1, 7)]}
    f = plane_signals - 0.7 * plane_neuropil
    f0 = np.array([percentile(f[:, i], 20) for i in range(6)])
    dff = (f - f0) / f0
    expected["planesDff"] = {"rois": 6, "frames": 20, "baseline": [round_to(v, 4) for v in f0], "maxDff": [round_to(v, 4) for v in dff.max(axis=0)]}
    head = both[:, :, :, :4]
    expected["planesPreview"] = {"frames": 4, "results": [{"n_frames": 4, "mean_intensity": round_to(head.mean(), 4), "max_intensity": float(head.max()),
                                                           "planes": [{"plane": p + 1, "mean_intensity": round_to(head[p].mean(), 4)} for p in range(2)]}],
                                 "outputs": [{"name": "FrameStats", "size": [4, 8]}]}
    # ScanImage's channel 2 in both planes
    second = scanimage[:, :, 1].astype(float)
    expected["scanimagePlanes"] = {"n_frames": 3, "height": 16, "width": 64, "mean_intensity": round_to(second.mean(), 4), "max_intensity": float(second.max()),
                                   "planes": [{"plane": p + 1, "mean_intensity": round_to(second[:, :, p].mean(), 4), "max_intensity": float(second[:, :, p].max())}
                                              for p in range(2)]}
    return expected


def autodetect_expected(aligned):
    """The viewer's Detect tool in dev's autodetection modes (rois.detect mode), with the tool's radius 3, on the aligned
    stack (found here with NumPy and SciPy, not with either reader's code).

    Modes 1 and 5 (flufinder's edge detection: on the activity-weighted mean of the cell's box, or on the average) put
    the cell's edge where its brightness falls: halfway between its last pixels (at 2 from its centre) and the
    background (at 3), so the ROI is the pixels within 2.5 of the centre, the disk and the 8 pixels at sqrt(5) around it.
    Modes 2-4 (flufinder's findSomaMaskByThresholding, outer diameter 6) threshold an image of the box of 3 + 5 around
    the cell (3 + 11 in mode 4), cut at the image's edges: halfway from the median of the pixels outside the circle of 3
    around the box's centre (size / 2, 1-based) to the median of those inside, 0s left out, on the image median filtered
    over 5 x 5 (0 outside, NaN last); 8-connected areas of fewer than round(9 pi / 2) pixels removed, holes filled. The
    image is in mode 2 the maximum over the frames where the cell's mean (its pixels within 3 of the point) is above
    its 5th percentile (MATLAB's prctile: NumPy's hazen), and 2 frames either side; in modes 3 and 4 the average as 8
    bits in single precision, from its sorted values at round(n 0.0005) and round(n 0.9995)."""
    from scipy import ndimage
    r = 3
    within = lambda centre, distance: [[y, x] for y in range(HEIGHT) for x in range(WIDTH)
                                       if (y - centre[0]) ** 2 + (x - centre[1]) ** 2 <= distance ** 2]

    def box(centre, pad):
        top, bottom = max(centre[0] - r - pad, 0), min(centre[0] + r + pad, HEIGHT - 1)
        left, right = max(centre[1] - r - pad, 0), min(centre[1] + r + pad, WIDTH - 1)
        return top, bottom + 1, left, right + 1

    def threshold(image):
        im = image.astype(float).copy()
        im[im == 0] = np.nan
        h, w = im.shape
        yy, xx = np.mgrid[1:h + 1, 1:w + 1]
        soma = (xx - w / 2) ** 2 + (yy - h / 2) ** 2 < r * r
        low, high = np.nanmedian(im[~soma]), np.nanmedian(im[soma])
        level = low + (high - low) / 2
        filtered = ndimage.generic_filter(im, lambda v: np.sort(v)[12], size=5, mode="constant", cval=0.0)
        labels, count = ndimage.label(filtered > level, structure=np.ones((3, 3)))
        keep = [k for k in range(1, count + 1) if (labels == k).sum() >= math.floor(math.pi * r * r / 2 + 0.5)]
        return ndimage.binary_fill_holes(np.isin(labels, keep))

    def placed(mask, bounds):
        out = np.zeros((HEIGHT, WIDTH), dtype=bool)
        out[bounds[0]:bounds[1], bounds[2]:bounds[3]] = mask
        return [[int(y), int(x)] for y, x in zip(*np.nonzero(out))]

    def eight_bits(image):
        data = image.astype(np.float32)
        ordered = np.sort(data.ravel())
        n = ordered.size
        low = ordered[max(math.floor(n * 0.0005 + 0.5), 1) - 1]
        high = ordered[min(math.floor(n * (1 - 0.0005) + 0.5), n) - 1]
        return np.clip(np.floor((((data - low) / (high - low)) * np.float32(255)).astype(float) + 0.5), 0, 255)

    average = aligned.astype(float).mean(axis=2)
    first, third = CELLS[0], CELLS[2]
    out = {"1": within(first, 2.5), "5": within(third, 2.5)}
    bounds = box(first, 5)
    part = aligned[bounds[0]:bounds[1], bounds[2]:bounds[3], :].astype(float)
    rows, columns = np.mgrid[bounds[0]:bounds[1], bounds[2]:bounds[3]]
    signal = part[(rows - first[0]) ** 2 + (columns - first[1]) ** 2 < r * r].mean(axis=0)
    p5, p50 = np.percentile(signal, [5, 50], method="hazen")
    active = ndimage.binary_dilation(signal > p50 - (p50 - p5), structure=np.ones(5, dtype=bool))
    out["2"] = placed(threshold(part[:, :, active].max(axis=2)), bounds)
    out["3"] = placed(threshold(eight_bits(average[bounds[0]:bounds[1], bounds[2]:bounds[3]])), bounds)
    bounds = box(third, 11)
    out["4"] = placed(threshold(eight_bits(average[bounds[0]:bounds[1], bounds[2]:bounds[3]])), bounds)
    return out


def main():
    recording, aligned, shifts, disks, movie = scene(1)
    write_sciscan(HERE / "project/data/raw/sub-m1/ses-s1/rec.raw", recording)
    second = scene(2)[0]
    import tifffile
    # session 2: a TIFF recording in two files, part2 before part10 in natural order
    folder = HERE / "project/data/raw/sub-m1/ses-s2"
    folder.mkdir(parents=True, exist_ok=True)
    for old in folder.glob("*.tif"):
        old.unlink()
    tifffile.imwrite(folder / "rec_part2.tif", np.moveaxis(second[:, :, :15], 2, 0), photometric="minisblack")
    tifffile.imwrite(folder / "rec_part10.tif", np.moveaxis(second[:, :, 15:], 2, 0), photometric="minisblack")

    # session 3: the scene of session 1, displaced as a whole by (2, -3), without motion within the recording
    whole = movie[PAD - 2:PAD - 2 + HEIGHT, PAD + 3:PAD + 3 + WIDTH, :]
    write_sciscan(HERE / "project/data/raw/sub-m1/ses-s3/rec.raw", whole.astype(np.uint16))
    scanimage = write_scanimage(HERE / "project/data/raw/sub-m1/ses-s4/rec_00001.tif", np.random.default_rng(4))

    union = np.any(disks, axis=0)
    signals = np.stack([aligned[d].mean(axis=0) for d in disks], axis=1)
    neuropil = np.stack([aligned[ring(d, union, 1, 3)].mean(axis=0) for d in disks], axis=1)
    f = signals - 0.7 * neuropil
    f0 = np.array([percentile(f[:, i], 20) for i in range(len(disks))])
    dff = (f - f0) / f0
    binned = aligned[:, :, :FRAMES // 4 * 4].reshape(HEIGHT // 2, 2, WIDTH // 2, 2, FRAMES // 4, 4).mean(axis=(1, 3, 5))
    expected = {
        "raw": {"n_frames": FRAMES, "height": HEIGHT, "width": WIDTH,
                "mean_intensity": round_to(recording.astype(float).mean(), 4), "max_intensity": float(recording.max())},
        "tiff": {"n_frames": FRAMES, "height": HEIGHT, "width": WIDTH,
                 "mean_intensity": round_to(second.astype(float).mean(), 4), "max_intensity": float(second.max())},
        "motion": {"frames": FRAMES, "maxShift": int(np.abs(shifts).max()),
                   "meanShift": round_to(np.sqrt((shifts ** 2).sum(axis=1)).mean(), 4)},
        "corrected": {"mean_intensity": round_to(aligned.mean(), 4), "max_intensity": float(aligned.max())},
        # methods.preview of image_stats on the first 5 frames: the stats of those, and the projections kept in memory
        "preview": preview_expected(recording[:, :, :5]),
        "projections": projections_expected(aligned.astype(np.float64)),
        "meanClahe": mean_clahe_expected(aligned),
        "rois": {"rois": len(disks), "areas": [int(d.sum()) for d in disks]},
        "signals": {"rois": len(disks), "frames": FRAMES,
                    "meanSignal": [round_to(v, 4) for v in signals.mean(axis=0)],
                    "meanNeuropil": [round_to(v, 4) for v in neuropil.mean(axis=0)]},
        "dff": {"rois": len(disks), "frames": FRAMES, "baseline": [round_to(v, 4) for v in f0],
                "maxDff": [round_to(v, 4) for v in dff.max(axis=0)]},
        "downsample": {"frames": FRAMES // 4, "height": HEIGHT // 2, "width": WIDTH // 2,
                       "meanIntensity": round_to(binned.astype(np.float32).astype(float).mean(), 4)},
    }
    picked = list(range(5, 20, 4))   # data.traces: frames 5..19, at most 4 points, so every 4th
    four = lambda v: math.floor(v * 10000 + 0.5) / 10000
    expected["traces"] = {"frames": FRAMES, "start": 5, "step": 4, "points": 4, "traces": [
        {"variable": "RoiSignals_MeanF", "count": len(disks), "columns": [{"column": c, "values": [four(signals[t, c]) for t in picked]} for c in (0, 2)]},
        {"variable": "RoiSignals_Dff", "count": len(disks), "columns": [{"column": c, "values": [four(dff[t, c]) for t in picked]} for c in (0, 2)]}]}
    expected["frame0"] = {"height": HEIGHT, "width": WIDTH, "frames": FRAMES, "frame": 0, **frame_bytes(aligned[:, :, 0])}
    # compute_dff's other methods. chen2013: the neuropil's 20th percentile added back to F
    columns = range(len(disks))
    whole = lambda a, q: np.array([percentile(a[:, i], q) for i in columns])
    fc = signals - 0.7 * neuropil + whole(neuropil, 20)
    fc0 = whole(fc, 20)
    chen = (fc - fc0) / fc0
    expected["dffChen"] = {"rois": len(disks), "frames": FRAMES, "baseline": [round_to(v, 4) for v in fc0],
                           "maxDff": [round_to(v, 4) for v in chen.max(axis=0)]}
    # dffMinusNeuropil, then a running 25th percentile over 10 frames (rows t - 5 to t + 4) subtracted
    s0, n0 = whole(signals, 20), whole(neuropil, 20)
    minus = (signals - s0) / s0 - 0.7 * (neuropil - n0) / n0
    drift = np.array([[percentile(minus[max(0, t - 5):min(FRAMES, t + 5), i], 25) for i in columns] for t in range(FRAMES)])
    corrected = minus - drift
    expected["dffMinusNeuropil"] = {"rois": len(disks), "frames": FRAMES, "baseline": [round_to(v, 4) for v in s0],
                                    "maxDff": [round_to(v, 4) for v in corrected.max(axis=0)]}
    # extract_signals with dev's neuropil (neuropilMethod expansion, factor 4, separation 1), from its definition with
    # SciPy's dilation: grown by the four sides and the four diagonals in turn, less the ROI, until it covers 4 times
    # the ROI's area outside every ROI dilated once by the diagonals
    from scipy import ndimage as nd
    sides, diagonals = nd.generate_binary_structure(2, 1), np.array([[1, 0, 1], [0, 1, 0], [1, 0, 1]], bool)
    ignored = nd.binary_dilation(union, diagonals)
    expanded = []
    for d in disks:
        grown, covered, step, target = d.copy(), 0, 0, min(d.size - d.sum(), 4 * d.sum())
        while covered < target and step <= 100:
            grown = nd.binary_dilation(grown, sides if step % 2 == 0 else diagonals) & ~d
            covered = (grown & ~ignored).sum()
            step += 1
        expanded.append(aligned[grown & ~ignored].mean(axis=0))
    expected["signalsExpansion"] = {"rois": len(disks), "frames": FRAMES,
                                    "meanSignal": [round_to(v, 4) for v in signals.mean(axis=0)],
                                    "meanNeuropil": [round_to(v, 4) for v in np.stack(expanded, axis=1).mean(axis=0)]}
    # the ring in 5 slices around each ROI (dev's numNeuropilSlices; pixels at the same angle make them differ in size):
    # the neuropil signal is the mean of the slices' means
    sliced = [np.mean([aligned[part].mean(axis=0) for part in neuropil_slices(ring(d, union, 1, 3), d, 5)], axis=0) for d in disks]
    expected["signalsSlices"] = {"rois": len(disks), "frames": FRAMES,
                                 "meanSignal": [round_to(v, 4) for v in signals.mean(axis=0)],
                                 "meanNeuropil": [round_to(v, 4) for v in np.stack(sliced, axis=1).mean(axis=0)]}
    # dev's neuropil grown 2 steps at most (maxNeuropilRadius 2): by the four sides, then by the four diagonals
    short = []
    for d in disks:
        grown = nd.binary_dilation(nd.binary_dilation(d, sides) & ~d, diagonals) & ~d
        short.append(aligned[grown & ~ignored].mean(axis=0))
    expected["signalsShortExpansion"] = dict(expected["signalsExpansion"], meanNeuropil=[round_to(v, 4) for v in np.stack(short, axis=1).mean(axis=0)])
    # rois.signal: ROI 1's pixels read from the aligned stack now, frames 5..19 every 4th, as data.traces gives them
    expected["liveSignal"] = {"frames": FRAMES, "start": 5, "step": 4, "points": 4, "traces": [
        {"variable": "TwoPhotonSeries_Corrected", "count": 1, "columns": [{"column": 0, "values": [four(signals[t, 0]) for t in picked]}]}]}
    expected["liveSignalPixels"] = [[int(y), int(x)] for y, x in zip(*np.nonzero(disks[0]))]
    # data.traces of image_stats' FrameStats (of the aligned recording): mean and std at frames 0, 10, 20, 30
    stats = frame_stats(aligned)
    expected["frameStatsTraces"] = {"frames": FRAMES, "start": 0, "step": 10, "points": 4, "traces": [
        {"variable": "FrameStats", "count": 4, "columnNames": ["mean", "min", "max", "std"],
         "columns": [{"column": c, "values": [four(stats[t, c]) for t in range(0, FRAMES, 10)]} for c in (0, 3)]}]}
    expected["frame3"] = {"frame": 3, **frame_bytes(aligned[:, :, 3], (0, 1000))}
    # find_plane: a z-stack of 5 planes, the third the recording's mean image moved by (2, -1), the others other
    # scenes; the third's Pearson correlation with the mean image over the pixels both cover, from its definition
    fov = aligned.astype(np.float64).mean(axis=2)
    planes = [scene(seed)[1].astype(np.float64).mean(axis=2) for seed in (11, 12, 13, 14)]
    planes.insert(2, np.roll(fov, (2, -1), axis=(0, 1)))
    zstack = np.stack([np.round(p) for p in planes], axis=2).astype(np.uint16)
    tifffile.imwrite(HERE / "project/data/raw/sub-m1/ses-s1/zstack.tiff", np.moveaxis(zstack, 2, 0), photometric="minisblack")
    back = zstack[2:, :WIDTH - 1, 2].astype(np.float64)   # plane[y + 2, x - 1] is fov[y, x], for y < HEIGHT - 2, x >= 1
    seen = fov[:HEIGHT - 2, 1:]
    a, b = seen - seen.mean(), back - back.mean()
    expected["findPlane"] = {"plane": 3, "shift": [2, -1], "correlation": round_to(float((a * b).sum() / math.sqrt((a * a).sum() * (b * b).sum())), 4)}
    # crop of rows 3..20, columns 5..30 and frames 2..10 (from 1): its frame 0 is frame 1 (from 0) cut
    expected["cropped"] = {"height": 18, "width": 26, "frames": 9, "frame": 0, **frame_bytes(aligned[2:20, 4:30, 1], (0, 1000))}
    # export_tiff of frames 3..7 (from 1), read back through a data variable: its frame 2 (from 0) is frame 4 (from 0)
    expected["exported"] = {"height": HEIGHT, "width": WIDTH, "frames": 5, "frame": 2, **frame_bytes(aligned[:, :, 4], (0, 1000))}
    expected["maxProjection"] = {"frame": None, **frame_bytes(aligned.max(axis=2)),
                                 "rois": [{"id": n + 1, "pixels": [[int(y), int(x)] for y, x in zip(*np.nonzero(d))]}
                                          for n, d in enumerate(disks)]}
    g = math.exp(-1.0 / (0.5 * 30))
    noise, spike_sum, max_calcium = [], [], []
    for i in range(len(disks)):
        ordered = np.sort(np.abs(np.diff(dff[:, i])))
        n = len(ordered)
        sigma = (ordered[n // 2] if n % 2 else (ordered[n // 2 - 1] + ordered[n // 2]) / 2) / (0.6745 * math.sqrt(2))
        calcium, spikes = deconvolution_truth(dff[:, i], g, sigma)
        noise.append(round_to(sigma, 4))
        spike_sum.append(round_to(spikes.sum(), 3))
        max_calcium.append(round_to(calcium.max(), 3))
    expected["deconvolve"] = {"rois": len(disks), "frames": FRAMES, "noise": noise, "spikeSum": spike_sum, "maxCalcium": max_calcium}
    # order 2 (the default): dev's rise of 0.18 s with the decay of 0.5 s, at 30 Hz
    d, r = math.exp(-1.0 / (0.5 * 30)), math.exp(-1.0 / (0.18 * 30))
    spike_sum, max_calcium = [], []
    for i in range(len(disks)):
        ordered = np.sort(np.abs(np.diff(dff[:, i])))
        n = len(ordered)
        sigma = (ordered[n // 2] if n % 2 else (ordered[n // 2 - 1] + ordered[n // 2]) / 2) / (0.6745 * math.sqrt(2))
        calcium, spikes = deconvolution_ar2_truth(dff[:, i], d, r, sigma)
        spike_sum.append(round_to(spikes.sum(), 3))
        max_calcium.append(round_to(calcium.max(), 3))
    expected["deconvolveAr2"] = dict(expected["deconvolve"], spikeSum=spike_sum, maxCalcium=max_calcium)
    smoothed = aligned
    for axis in (0, 1, 2):
        smoothed = smooth_naive(smoothed, axis, 1.0)
    expected["denoise"] = {"frames": FRAMES, "height": HEIGHT, "width": WIDTH,
                           "meanIntensity": round_to(smoothed.astype(np.float32).astype(float).mean(), 4)}
    expected["migrated"] = [{"id": n + 1, "pixels": [[int(y) + 2, int(x) - 3] for y, x in zip(*np.nonzero(d))]}
                            for n, d in enumerate(disks)]
    expected["keptSignals"] = {"rois": 2, "ids": [1, 3], "meanSignal": [expected["signals"]["meanSignal"][i] for i in (0, 2)]}
    # channels and planes: ScanImage's channel 1 plane 1 and channel 2 plane 2, picked by image_stats
    for c, p in ((0, 0), (1, 1)):
        part = scanimage[:, :, c, p, :].astype(float)
        expected[f"scanimageStats{c + 1}{p + 1}"] = {"n_frames": 3, "height": 16, "width": 64,
                                                     "mean_intensity": round_to(part.mean(), 4), "max_intensity": float(part.max())}
    # session 1's recording deinterleaved as 2 channels: channel 1 is the even frames, channel 2 the odd ones.
    # Motion correction finds the shifts in channel 1 (the even frames' true shifts) and moves channel 2 by them.
    even = shifts[0::2]
    expected["deinterleave"] = {"frames": FRAMES // 2, "channels": 2, "planes": 1}
    expected["deinterleavedFrame"] = {"height": HEIGHT, "width": WIDTH, "frames": FRAMES // 2, "channels": 2, "planes": 1, "frame": 1,
                                      **frame_bytes(recording[:, :, 3].astype(float))}   # channel 2, frame 1: frame 3
    expected["motionByChannel"] = {"frames": FRAMES // 2, "maxShift": int(np.abs(even).max()),
                                   "meanShift": round_to(np.sqrt((even ** 2).sum(axis=1)).mean(), 4)}
    second_channel = np.zeros((HEIGHT, WIDTH, FRAMES // 2))
    for k, (dy, dx) in enumerate(even):
        frame = recording[:, :, 2 * k + 1].astype(float)
        for y in range(HEIGHT):
            for x in range(WIDTH):
                if 0 <= y + dy < HEIGHT and 0 <= x + dx < WIDTH:
                    second_channel[y, x, k] = frame[y + dy, x + dx]   # moved back by the shift; 0 outside
    expected["secondChannelStats"] = {"n_frames": FRAMES // 2, "height": HEIGHT, "width": WIDTH,
                                      "mean_intensity": round_to(second_channel.mean(), 4), "max_intensity": float(second_channel.max())}
    # every channel in one run (channel 0, dev's extractSignalsMultiChannel), with ROIs placed in either channel
    # (rois_channels.json): each ROI's signal from its own channel, its neuropil a ring outside the ROIs of its channel;
    # channel 1 is the even frames aligned, channel 2 the odd ones moved by the even frames' shifts
    placed = [(disks[0], 1), (disks[0], 2), (disks[1], 2), (disks[2], 1)]
    (HERE / "project/data/raw/sub-m1/ses-s1/rois_channels.json").write_text(json.dumps({"imageSize": [HEIGHT, WIDTH], "rois": [
        {"id": n + 1, "channel": c, "pixels": [[int(y), int(x)] for y, x in zip(*np.nonzero(d))]} for n, (d, c) in enumerate(placed)]}) + "\n",
        encoding="utf-8")
    stacks = {1: aligned[:, :, 0::2], 2: second_channel}
    together = {c: np.any([d for d, k in placed if k == c], axis=0) for c in (1, 2)}
    expected["channelsSignals"] = {"rois": 4, "frames": FRAMES // 2, "ids": [1, 2, 3, 4],
                                   "meanSignal": [round_to(stacks[c][d].mean(), 4) for d, c in placed],
                                   "meanNeuropil": [round_to(stacks[c][ring(d, together[c], 1, 3)].mean(), 4) for d, c in placed],
                                   "channels": [{"channel": 1, "rois": 2}, {"channel": 2, "rois": 2}]}
    # ROI curation at the end: ROI 3 moved by (1, -1), then merged into ROI 1
    pixels = lambda d: [[int(y), int(x)] for y, x in zip(*np.nonzero(d))]
    moved = sorted([y + 1, x - 1] for y, x in pixels(disks[2]))
    expected["movedRois"] = [{"id": 1, "pixels": pixels(disks[0])}, {"id": 2, "pixels": pixels(disks[1]), "classification": "rejected"},
                             {"id": 3, "pixels": moved}]
    expected["mergedRois"] = [{"id": 1, "pixels": sorted(pixels(disks[0]) + moved)}, {"id": 2, "pixels": pixels(disks[1]), "classification": "rejected"}]
    # the viewer's Detect tool on the average of the aligned stack, at (10, 13) with radius 4: in the square around
    # the point, half way from its 20th percentile to the brightest within the radius; the 4-connected area around the
    # brightest pixel within 2 of the point, holes filled (found here with SciPy, not with either reader's code)
    from scipy import ndimage
    average = aligned.astype(float).mean(axis=2)
    (py, px), r = (10, 13), 4
    rows, columns = np.mgrid[0:HEIGHT, 0:WIDTH]
    near = (rows - py) ** 2 + (columns - px) ** 2
    square = (abs(rows - py) <= r) & (abs(columns - px) <= r)
    low, high = np.percentile(average[square], 20), average[near <= r * r].max()
    mask = (near <= r * r) & (average >= low + 0.5 * (high - low))
    candidates = np.flatnonzero((near <= 4).ravel())
    seed = candidates[np.argmax(average.ravel()[candidates])]
    labels, _ = ndimage.label(mask)
    area = ndimage.binary_fill_holes(labels == labels.ravel()[seed])
    expected["detected"] = [[int(y), int(x)] for y, x in zip(*np.nonzero(area))]
    expected["autodetected"] = autodetect_expected(aligned)
    expected["scanimage"] = {"height": 16, "width": 64, "frames": 3, "frame": 2,
                             **frame_bytes(scanimage[:, :, 1, 1, 2].astype(float)),
                             "metadata": {"frameRate": 7.5, "pixelSize": [round_to(3.2 * 15 / 32, 6), round_to(1.6 * 15 / 16, 6)], "zStep": 4.0}}
    # the SciScan recording's metadata, and ophys.read_metadata writing it into session 1's columns
    expected["sciscanMetadata"] = {"frameRate": 30.9, "pixelSize": [round_to(5.12e-4 * 1e6 / WIDTH, 6), round_to(3.84e-4 * 1e6 / HEIGHT, 6)]}
    expected["readMetadata"] = {"frame_rate": 30.9, "pixel_size_um": expected["sciscanMetadata"]["pixelSize"][0]}
    expected.update(ranges_and_planes_expected(recording, aligned, shifts, disks, scanimage))
    print(json.dumps(expected, indent=1))


if __name__ == "__main__":
    main()
