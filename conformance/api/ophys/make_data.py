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
    path.parent.mkdir(parents=True, exist_ok=True)
    stack.transpose(2, 0, 1).astype(">u2").tofile(path)  # frame after frame, line after line, big-endian
    path.with_suffix(".ini").write_text(
        f'[_]\nx.pixels = {WIDTH}\ny.pixels = {HEIGHT}\nno.of.channels = 1\nno.of.frames.acquired = {FRAMES}\n'
        f'file.format = 0\nsave.ch.1 = "TRUE"\nframes.p.sec = "30,9"\n', encoding="latin-1")


def ring(disk, others, gap, width):
    """Pixels whose square distance to the disk is gap+1 .. gap+width, in no disk."""
    ys, xs = np.nonzero(disk)
    out = np.zeros_like(disk)
    for y in range(HEIGHT):
        for x in range(WIDTH):
            distance = np.max(np.abs(np.stack([ys - y, xs - x])), axis=0).min()
            out[y, x] = gap < distance <= gap + width and not others[y, x]
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
    2 planes, 3 volumes; returns the stack as the reader gives it (16 x 64 x channels x planes x volumes)."""
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
    software = "SI.VERSION_MAJOR = 2020\nSI.hChannels.channelSave = [1;2]\nSI.hStackManager.numSlices = 2\nSI.hRoiManager.mroiEnable = true\n"
    artist = json.dumps({"RoiGroups": {"imagingRoiGroup": {"rois": [
        {"name": "A", "scanfields": {"pixelResolutionXY": [32, 16]}},
        {"name": "B", "scanfields": {"pixelResolutionXY": [32, 16]}}]}}})
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


def preview_expected(first):
    stats = lambda image: {"size": list(image.shape), "min": round_to(image.min(), 4), "max": round_to(image.max(), 4), "mean": round_to(image.mean(), 4)}
    average, maximum = first.astype(float).mean(axis=2), first.max(axis=2).astype(float)
    return {"frames": 5, "results": [{"n_frames": 5, "height": HEIGHT, "width": WIDTH, "mean_intensity": round_to(first.astype(float).mean(), 4),
                                      "max_intensity": float(first.max())}],
            "outputs": [dict(name="FovAverageProjection", kind="array", **stats(average)), dict(name="FovMaximumProjection", kind="array", **stats(maximum))]}


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
    expected["frame3"] = {"frame": 3, **frame_bytes(aligned[:, :, 3], (0, 1000))}
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
    expected["scanimage"] = {"height": 16, "width": 64, "frames": 3, "frame": 2,
                             **frame_bytes(scanimage[:, :, 1, 1, 2].astype(float))}
    print(json.dumps(expected, indent=1))


if __name__ == "__main__":
    main()
