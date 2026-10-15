"""Write this case's recordings and its steps (session.json), with the values the steps expect.

Run from the repository root: python conformance/api/ophys-motion/make_data.py

Motion correction finer than the ophys case's: subpixel shifts, piecewise rigid (patches), and sessions
aligned with a rotation. Every expected value comes from the ground truth the recordings are made from,
computed here directly, not with either reader's ophys code:

- s1: a periodic random texture moved by half pixels along one axis (as the Fourier shift theorem moves
  it, so the move is exact). Subpixel results are given to a tenth of a pixel, and the shifts are chosen so
  that the true values are far from where that rounding changes.
- s2: a texture whose four quadrants move by whole pixels: in each frame by a shift of the frame and one
  of the quadrant's own, of a pixel at most; 2 x 2 patches find each quadrant's shift.
- s3, s4: a smooth scene, and the same scene turned by 3 degrees about the image centre after a move of
  (2, -1), drawn from its formula. Aligning s4 to s3 finds both, and moves s3's ROIs there.
- s5: four ring-shaped somata (a dark nucleus in a bright ring) that are never active, on a background
  with fixed noise; Quicky finds them by their shape alone, each with its centre where it was drawn.
"""

import json
import math
import shutil
from pathlib import Path

import numpy as np

HERE = Path(__file__).parent
RAW = HERE / "project" / "data" / "raw" / "sub-m1"
S1 = {"subject_id": "m1", "session_id": "s1"}
S2 = {"subject_id": "m1", "session_id": "s2"}
S3 = {"subject_id": "m1", "session_id": "s3"}
S4 = {"subject_id": "m1", "session_id": "s4"}
S5 = {"subject_id": "m1", "session_id": "s5"}


def round_to(value, digits):
    value = float(value)
    return None if not math.isfinite(value) else math.floor(value * 10 ** digits + 0.5) / 10 ** digits


def save(session, stack):
    folder = RAW / f"ses-{session}"
    folder.mkdir(parents=True, exist_ok=True)
    np.save(folder / "rec.npy", np.asfortranarray(stack))


def subpixel():
    """s1: 32 x 32 x 12, float64; half-pixel moves along one axis, so each frame's move is a multiple of 0.5 long."""
    size = 32
    rng = np.random.default_rng(11)
    spectrum = np.fft.fft2(rng.normal(100, 20, (size, size)))
    fy, fx = np.fft.fftfreq(size)[:, None], np.fft.fftfreq(size)[None, :]
    shifts = [(0, 0), (0.5, 0), (0, -1), (1.5, 0), (0, 2), (-0.5, 0), (0, 1), (-1.5, 0), (0, -2), (0.5, 0), (0, -1), (0, 0.5)]
    frames = [np.real(np.fft.ifft2(spectrum * np.exp(-2j * np.pi * (fy * dy + fx * dx)))) for dy, dx in shifts]
    save("s1", np.stack(frames, axis=2))
    lengths = [math.hypot(dy, dx) for dy, dx in shifts]
    mean, largest = sum(lengths) / len(lengths), max(max(abs(dy), abs(dx)) for dy, dx in shifts)
    assert abs(mean * 10 - round(mean * 10)) < 0.01, mean   # at a tenth: far from where rounding changes
    return {"frames": len(shifts), "maxShift": round_to(largest, 1), "meanShift": round_to(mean, 1)}


def piecewise():
    """s2: 48 x 48 x 8, uint16; quadrant (i, j) of frame t shows the texture moved by its own whole-pixel shift."""
    size, pad, frames, half = 48, 6, 8, 24
    rng = np.random.default_rng(12)
    texture = rng.normal(0, 1, (size + 2 * pad, size + 2 * pad))
    texture = texture + np.roll(texture, 1, 0) + np.roll(texture, 1, 1)   # some correlation between neighbours
    texture = np.round(1000 + 120 * texture)
    shifts = np.zeros((frames, 2, 2, 2), dtype=int)   # frame, (rows, columns), patch row, patch column
    # each frame moves as a whole by up to 2 pixels, and each quadrant by up to 1 more of its own
    shifts[1:] = rng.integers(-2, 3, size=(frames - 1, 2, 1, 1)) + rng.integers(-1, 2, size=(frames - 1, 2, 2, 2))
    stack = np.zeros((size, size, frames))
    for t in range(frames):
        for i in range(2):
            for j in range(2):
                dy, dx = shifts[t, :, i, j]
                rows, columns = slice(i * half, (i + 1) * half), slice(j * half, (j + 1) * half)
                stack[rows, columns, t] = texture[pad - dy + i * half:pad - dy + (i + 1) * half, pad - dx + j * half:pad - dx + (j + 1) * half]
    stack += rng.normal(0, 4, stack.shape)
    save("s2", np.clip(np.round(stack), 0, 65535).astype(np.uint16))
    lengths = np.sqrt(shifts[:, 0] ** 2 + shifts[:, 1] ** 2)
    return {"frames": frames, "maxShift": int(np.abs(shifts).max()), "meanShift": round_to(lengths.mean(), 4)}


SOMATA = [(20, 20), (22, 42), (42, 24), (44, 44)]


def somata():
    """s5: 64 x 64 x 10, uint16, the same frame ten times: rings of radius 4 around SOMATA, and fixed noise."""
    rng = np.random.default_rng(14)
    rows, columns = np.mgrid[0:64, 0:64].astype(float)
    image = np.full((64, 64), 1000.0)
    for cy, cx in SOMATA:
        image += 1200 * np.exp(-((np.hypot(rows - cy, columns - cx) - 4.0) ** 2) / 2)
    image = np.round(image + rng.normal(0, 30, image.shape))
    save("s5", np.repeat(image[:, :, None], 10, axis=2).astype(np.uint16))
    return {"rois": len(SOMATA), "shapeRois": len(SOMATA)}


ANGLE, MOVE = 3.0, (2, -1)


def rotated():
    """s3 and s4: 48 x 48 x 2. s4 at pixel q shows the scene at turn(-ANGLE) * (q - centre) + centre - MOVE, so
    the scene's point p is at turn(ANGLE) * (p - centre + MOVE) + centre in s4."""
    size = 48
    rng = np.random.default_rng(13)
    blobs = [(rng.uniform(-4, size + 4), rng.uniform(-4, size + 4), rng.uniform(40, 160), rng.uniform(0.9, 2.2)) for _ in range(500)]

    def scene(y, x):
        value = np.full(y.shape, 100.0)
        for cy, cx, amplitude, sigma in blobs:
            value += amplitude * np.exp(-((y - cy) ** 2 + (x - cx) ** 2) / (2 * sigma ** 2))
        return value

    centre = (size - 1) / 2
    rows, columns = np.mgrid[0:size, 0:size].astype(float)
    radians = math.radians(-ANGLE)
    y, x = rows - centre, columns - centre
    there = (math.cos(radians) * y - math.sin(radians) * x + centre - MOVE[0], math.sin(radians) * y + math.cos(radians) * x + centre - MOVE[1])
    reference, moved = scene(rows, columns), scene(*there)
    save("s3", np.stack([reference + rng.normal(0, 2, reference.shape) for _ in range(2)], axis=2))
    save("s4", np.stack([moved + rng.normal(0, 2, moved.shape) for _ in range(2)], axis=2))

    # ROIs of s3: disks at bright blobs well inside; where their pixels land in s4
    rois = []
    for number, (cy, cx) in enumerate([(14, 15), (30, 33), (20, 34)], start=1):
        pixels = [(r, c) for r in range(size) for c in range(size) if (r - cy) ** 2 + (c - cx) ** 2 <= 5]
        rois.append({"id": number, "pixels": pixels})
    cos, sin = math.cos(math.radians(ANGLE)), math.sin(math.radians(ANGLE))
    moved_rois = []
    for roi in rois:
        landed = set()
        for r, c in roi["pixels"]:
            y, x = r + MOVE[0] - centre, c + MOVE[1] - centre
            ty, tx = cos * y - sin * x + centre, sin * y + cos * x + centre
            for v in (ty, tx):
                assert abs(v - math.floor(v) - 0.5) > 1e-6, v   # no pixel lands where rounding is a toss-up
            landed.add((math.floor(ty + 0.5), math.floor(tx + 0.5)))
        moved_rois.append({"id": roi["id"], "pixels": [list(p) for p in sorted(landed)]})
    return rois, moved_rois


def main():
    if (HERE / "project" / "data").exists():
        shutil.rmtree(HERE / "project" / "data")
    first, second = subpixel(), piecewise()
    rois, moved = rotated()
    shaped = somata()
    # s3's ROIs, as the ophys methods write them (ophys/roi_array.json in the processed data)
    folder = HERE / "project" / "data" / "processed" / "sub-m1" / "ses-s3" / "ophys"
    folder.mkdir(parents=True)
    document = {"imageSize": [48, 48], "rois": [{"id": roi["id"], "area": len(roi["pixels"]), "pixels": [list(p) for p in roi["pixels"]]} for roi in rois]}
    (folder / "roi_array.json").write_text(json.dumps(document) + "\n", encoding="utf-8")
    run = lambda number, method, keys, options: {"request": {"method": "methods.run", "id": number, "params": {
        "methodId": method, "entityType": "session", "keys": keys, "options": options}}}
    steps = [
        {"request": {"method": "project.open", "id": 1, "params": {"path": "${project}"}}, "expect": {"result": {"name": "OphysMotion"}}},
        {"request": {"method": "project.scan", "id": 2, "params": {}}, "expect": {"result": {"records": {"subject": 1, "session": 5}, "unmatched": 0}}},
        {"request": {"method": "project.sync", "id": 3, "params": {}}, "expect": {"result": {"added": {"session": [S1, S2, S3, S4, S5]}}}},
        {"request": {"method": "tools.run", "id": 4, "params": {"methodId": "ophys.setup_variables", "options": {
            "rawFilePattern": "recording", "rawFileAdapter": "npy", "addColumns": False}}},
         "expect": {"result": {"result": {"existing": []}}}},
        # whole-pixel patches need the patches to be at least 4 pixels
        {**run(5, "ophys.motion_correction", [S2], {"patches": 20}), "expect": {"error": "invalid-options"}},
        {**run(6, "ophys.motion_correction", [S1], {"subpixel": True, "referenceFrames": 1, "maxShift": 4}),
         "expect": {"result": {"results": [first]}}},
        {**run(7, "ophys.motion_correction", [S2], {"patches": 2, "maxDeviation": 3, "referenceFrames": 1, "maxShift": 5, "iterations": 1}),
         "expect": {"result": {"results": [second]}}},
        {**run(9, "ophys.align_sessions", [S3, S4], {"image": "TwoPhotonSeries_Original", "maxRotation": 5, "rotationStep": 0.5, "maxShift": 6}),
         "expect": {"result": {"results": [{"reference": S3, "shifts": [{"key": S3, "shift": [0, 0], "rotation": 0}, {"key": S4, "shift": list(MOVE), "rotation": ANGLE}],
                                            "migrated": 1, "rois": 3}]}}},
        {"request": {"method": "data.frame", "id": 10, "params": {"entityType": "session", "key": S4, "variable": "TwoPhotonSeries_Original",
                                                                  "frame": 0, "rois": "RoiArray"}},
         "expect": {"result": {"width": 48, "height": 48, "rois": moved}}},
        # somata that are never active are found by their shape; the activity part finds nothing in a still recording
        {**run(11, "ophys.quicky", [S5], {"stack": "TwoPhotonSeries_Original", "roiDiameter": 10}), "expect": {"result": {"results": [shaped]}}},
        {**run(12, "ophys.quicky", [S5], {"stack": "TwoPhotonSeries_Original", "roiDiameter": 10, "useShapeDetection": False}),
         "expect": {"result": {"results": [{"rois": 0, "areas": []}]}}},
    ]
    (HERE / "session.json").write_text(json.dumps({"steps": steps}, indent=2) + "\n", encoding="utf-8")
    expected = {"description": "Motion correction finer than whole pixels: subpixel shifts on a texture moved by half pixels, piecewise rigid "
                               "correction (patches) of a texture whose quadrants move apart, and sessions aligned with a rotation, whose ROIs "
                               "land where the ground truth puts them; and Quicky's shape detection finding somata that are never active. make_data.py writes the recordings and the steps from the ground truth.",
                "steps": len(steps)}
    (HERE / "expected.json").write_text(json.dumps(expected, indent=2) + "\n", encoding="utf-8")
    print(json.dumps([first, second]))


if __name__ == "__main__":
    main()
