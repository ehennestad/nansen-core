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
    return recording.astype(np.uint16), aligned, shifts, disks


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


def percentile(values, p):
    ordered = np.sort(values)
    position = (len(ordered) - 1) * p / 100
    low = int(math.floor(position))
    high = min(low + 1, len(ordered) - 1)
    return ordered[low] + (position - low) * (ordered[high] - ordered[low])


def main():
    recording, aligned, shifts, disks = scene(1)
    write_sciscan(HERE / "project/data/raw/sub-m1/ses-s1/rec.raw", recording)
    second, _, _, _ = scene(2)
    import tifffile
    tif = HERE / "project/data/raw/sub-m1/ses-s2/rec.tif"
    tif.parent.mkdir(parents=True, exist_ok=True)
    tifffile.imwrite(tif, np.moveaxis(second, 2, 0), photometric="minisblack")

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
        "rois": {"rois": len(disks), "areas": [int(d.sum()) for d in disks]},
        "signals": {"rois": len(disks), "frames": FRAMES,
                    "meanSignal": [round_to(v, 4) for v in signals.mean(axis=0)],
                    "meanNeuropil": [round_to(v, 4) for v in neuropil.mean(axis=0)]},
        "dff": {"rois": len(disks), "frames": FRAMES, "baseline": [round_to(v, 4) for v in f0],
                "maxDff": [round_to(v, 4) for v in dff.max(axis=0)]},
        "downsample": {"frames": FRAMES // 4, "height": HEIGHT // 2, "width": WIDTH // 2,
                       "meanIntensity": round_to(binned.astype(np.float32).astype(float).mean(), 4)},
    }
    print(json.dumps(expected, indent=1))


if __name__ == "__main__":
    main()
