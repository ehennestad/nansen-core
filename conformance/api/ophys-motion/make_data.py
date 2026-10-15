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
  (2, -1), drawn from its formula. Aligning s4 to s3 finds both, and moves s3's ROIs there; an ROI drawn in s4 is
  mirrored to s3, turned back.
- s8, s9: a smooth scene, and the same scene bent by a smooth field (each of 3 x 3 patches displaced by up to a pixel at
  its centre, linear between the centres) and moved by (-2, 3). Aligning s9 to s8 with 3 x 3 patches finds the move and
  each patch's displacement, and moves s8's ROIs where the field puts them; ROIs added, moved, removed and classified
  in one are mirrored to the other through the alignment, and aligning again keeps s9's curation unless told not to.
- s6: a resonant-scanner recording: two flyback rows of noise on top, and the lines scanned back (rows 1, 3,
  ... below them) 3 columns to the right of where they belong, in every frame, which moves by known whole
  pixels; motion correction leaves the flyback rows out, finds the offset and aligns the frames.
- s7: a resonant scanner's stretch: each raw line shows a scene that rises evenly along the line at the places dev's
  stretch profile (zoom 1.625, 512 pixels) puts its columns; motion correction with that profile (the nearest to the
  zoom 1.6 given) gives the scene at the whole places, from the first column's to the last's, which data.frame shows.
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
S6 = {"subject_id": "m1", "session_id": "s6"}
S7 = {"subject_id": "m1", "session_id": "s7"}
S8 = {"subject_id": "m1", "session_id": "s8"}
S9 = {"subject_id": "m1", "session_id": "s9"}


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


BIDIRECTIONAL, FLYBACK = 3, 2


def resonant():
    """s6: 42 x 48 x 30, uint16; rows 0-1 flyback noise, then a texture moved by whole pixels whose rows 1, 3, ...
    are drawn BIDIRECTIONAL columns to the right (0 where nothing is drawn)."""
    height, width, frames, pad = 40, 48, 30, 6
    rng = np.random.default_rng(15)
    texture = rng.normal(0, 1, (height + 2 * pad, width + 2 * pad))
    texture = np.round(1000 + 150 * (texture + np.roll(texture, 1, 0) + np.roll(texture, 1, 1)))
    shifts = rng.integers(-3, 4, (frames, 2))
    shifts[0] = 0
    stack = np.zeros((FLYBACK + height, width, frames))
    for t, (dy, dx) in enumerate(shifts):
        frame = texture[pad - dy:pad - dy + height, pad - dx:pad - dx + width].copy()
        frame[1::2, BIDIRECTIONAL:] = frame[1::2, :-BIDIRECTIONAL].copy()   # back lines land further right
        frame[1::2, :BIDIRECTIONAL] = 0
        stack[FLYBACK:, :, t] = frame
        stack[:FLYBACK, :, t] = rng.uniform(0, 4000, (FLYBACK, width))
    save("s6", np.clip(stack, 0, 65535).astype(np.uint16))
    lengths = np.sqrt((shifts ** 2).sum(axis=1))
    return {"frames": frames, "maxShift": int(np.abs(shifts).max()), "meanShift": round_to(lengths.mean(), 4), "bidirectionalOffset": BIDIRECTIONAL}


STRETCH_ZOOM, PROFILE_ZOOM = 1.6, 1.625


def stretched():
    """s7: 6 x 512 x 3, float64, still: raw column c of row y shows the scene 1000 + 40 y + 2 x at x = c - displacement[c]
    (dev's profile for zoom 1.625); corrected, column k is the scene at x = first + k, first the first whole place."""
    profiles = json.loads((HERE.parents[2] / "modules" / "ophys" / "calibration" / "sciscan_stretch.json").read_text(encoding="utf-8"))["profiles"]
    displacement = np.array(next(p for p in profiles if p["width"] == 512 and p["zoom"] == PROFILE_ZOOM)["displacement"])
    place = np.arange(512) - displacement
    scene = lambda y, x: 1000.0 + 40 * y + 2 * x
    rows = np.arange(6)[:, None]
    save("s7", np.repeat(scene(rows, place[None, :])[:, :, None], 3, axis=2))
    first, last = math.ceil(place[0]), math.floor(place[-1])
    corrected = scene(rows, np.arange(first, last + 1)[None, :])
    for pad in (0.25, 0.375, 0.125, 0.4375, 0.3125, 0.1875):   # limits a little past the values (dyadic: exact; not as
        low, high = scene(0, first) - pad, scene(5, last) + 2 * pad   # far at both ends, or the middle value scales to 128) ...
        scaled = (corrected - low) / (high - low) * 255 + 0.5
        if np.all(np.abs(scaled - np.round(scaled)) > 1e-6):   # ... where no value is near where rounding changes
            break
    else:
        raise AssertionError("no limits keep the values from where rounding changes")
    pixels = np.floor(scaled).astype(np.uint8)
    import base64
    return {"width": last - first + 1, "limits": [low, high], "pixels": base64.b64encode(pixels.tobytes()).decode("ascii")}


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


def disk(cy, cx, squared, size):
    return [(r, c) for r in range(size) for c in range(size) if (r - cy) ** 2 + (c - cx) ** 2 <= squared]


def half_up(points):
    """Points rounded half up, each once, in row-major order; asserting none is where rounding is a toss-up."""
    for v in np.ravel(points):
        assert abs(v - math.floor(v) - 0.5) > 1e-6, v
    return [list(p) for p in sorted({(math.floor(y + 0.5), math.floor(x + 0.5)) for y, x in points})]


def mirrored_to_s3(pixels):
    """Where pixels of s4 are in s3: the scene's point p is at turn(ANGLE) * (p - centre + MOVE) + centre in s4."""
    centre = (48 - 1) / 2
    cos, sin = math.cos(math.radians(ANGLE)), math.sin(math.radians(ANGLE))
    return half_up([(cos * (r - centre) + sin * (c - centre) + centre - MOVE[0], -sin * (r - centre) + cos * (c - centre) + centre - MOVE[1])
                    for r, c in pixels])


NR_SIZE, NR_PATCHES, NR_MOVE = 64, 3, (-2, 3)
NR_ROWS = [[0, 1, 0], [0, 0, -1], [1, 0, 0]]      # each patch's own displacement at its centre: rows,
NR_COLUMNS = [[1, 0, 0], [0, 0, 0], [0, -1, 1]]   # and columns (patch (i, j) at i * 3 + j)


def nr_field(y, x):
    """The smooth displacement of s9 from s8 at the scene's points (arrays): the patches' displacements, linear between
    the centres of 3 x 3 patches of the 64 x 64 image (as the motion correction cuts them) and constant beyond them."""
    edges = [(i * NR_SIZE) // NR_PATCHES for i in range(NR_PATCHES + 1)]
    centres = [(a + b - 1) / 2 for a, b in zip(edges, edges[1:])]
    hat = lambda v, i: np.interp(v, centres, np.eye(NR_PATCHES)[i])
    rows = sum(NR_ROWS[i][j] * hat(y, i) * hat(x, j) for i in range(NR_PATCHES) for j in range(NR_PATCHES))
    columns = sum(NR_COLUMNS[i][j] * hat(y, i) * hat(x, j) for i in range(NR_PATCHES) for j in range(NR_PATCHES))
    return rows, columns


def nr_there(y, x):
    """Where the scene's point (y, x) is in s9: moved by the field there, and by NR_MOVE."""
    dy, dx = nr_field(np.asarray(y, float), np.asarray(x, float))
    return y + dy + NR_MOVE[0], x + dx + NR_MOVE[1]


def nr_back(y, x):
    """The scene's point that s9 shows at (y, x): the field undone by many fixed-point steps (it bends by 1/20 px per px)."""
    ty, tx = np.asarray(y, float) - NR_MOVE[0], np.asarray(x, float) - NR_MOVE[1]
    py, px = ty, tx
    for _ in range(200):
        dy, dx = nr_field(py, px)
        py, px = ty - dy, tx - dx
    return py, px


def nonrigid():
    """s8 and s9: 64 x 64 x 2. s9 at pixel q shows the scene at the point p with nr_there(p) = q: the scene bent by a smooth
    field and moved by NR_MOVE. Aligning s9 to s8 with 3 x 3 patches finds the move and each patch's displacement, and
    moves s8's ROIs where the field and the move put them."""
    size = NR_SIZE
    rng = np.random.default_rng(16)
    blobs = [(rng.uniform(-4, size + 4), rng.uniform(-4, size + 4), rng.uniform(40, 160), rng.uniform(0.9, 2.2)) for _ in range(900)]

    def scene(y, x):
        value = np.full(np.shape(y), 100.0)
        for cy, cx, amplitude, sigma in blobs:
            value += amplitude * np.exp(-((y - cy) ** 2 + (x - cx) ** 2) / (2 * sigma ** 2))
        return value

    rows, columns = np.mgrid[0:size, 0:size].astype(float)
    reference, bent = scene(rows, columns), scene(*nr_back(rows, columns))
    save("s8", np.stack([reference + rng.normal(0, 2, reference.shape) for _ in range(2)], axis=2))
    save("s9", np.stack([bent + rng.normal(0, 2, bent.shape) for _ in range(2)], axis=2))
    rois = [{"id": number, "pixels": disk(cy, cx, 5, size)} for number, (cy, cx) in enumerate([(14, 16), (32, 44), (48, 22)], start=1)]
    landed = lambda pixels: half_up(np.stack(nr_there(*np.array(pixels, float).T), axis=1))
    return rois, [{"id": roi["id"], "pixels": landed(roi["pixels"])} for roi in rois], landed


def main():
    if (HERE / "project" / "data").exists():
        shutil.rmtree(HERE / "project" / "data")
    first, second = subpixel(), piecewise()
    rois, moved = rotated()
    shaped = somata()
    scanned = resonant()
    stretch = stretched()
    # s3's ROIs, as the ophys methods write them (ophys/roi_array.json in the processed data)
    folder = HERE / "project" / "data" / "processed" / "sub-m1" / "ses-s3" / "ophys"
    folder.mkdir(parents=True)
    document = {"imageSize": [48, 48], "rois": [{"id": roi["id"], "area": len(roi["pixels"]), "pixels": [list(p) for p in roi["pixels"]]} for roi in rois]}
    (folder / "roi_array.json").write_text(json.dumps(document) + "\n", encoding="utf-8")
    bent_rois, bent, landed = nonrigid()
    folder = HERE / "project" / "data" / "processed" / "sub-m1" / "ses-s8" / "ophys"
    folder.mkdir(parents=True)
    document = {"imageSize": [NR_SIZE, NR_SIZE], "rois": [{"id": roi["id"], "area": len(roi["pixels"]), "pixels": [list(p) for p in roi["pixels"]]} for roi in bent_rois]}
    (folder / "roi_array.json").write_text(json.dumps(document) + "\n", encoding="utf-8")
    # an ROI drawn in s9 and mirrored to s8: where the scene shows in s9 what it shows at those pixels
    drawn = disk(40, 40, 4, NR_SIZE)
    drawn_in_s8 = half_up(np.stack(nr_back(*np.array(drawn, float).T), axis=1))
    # ROI 1 of s8 moved a row down and a column left, mirrored to s9
    moved_in_s8 = [[r + 1, c - 1] for r, c in bent_rois[0]["pixels"]]
    # an ROI drawn in s4 and mirrored to s3, through the rotation
    drawn_s4 = disk(24, 30, 4, 48)
    frame = lambda number, key: {"request": {"method": "data.frame", "id": number, "params": {
        "entityType": "session", "key": key, "variable": "TwoPhotonSeries_Original", "frame": 0, "rois": "RoiArray"}}}
    update = lambda number, key, change: {"request": {"method": "rois.update", "id": number, "params": {
        "entityType": "session", "key": key, "variable": "RoiArray", **change}}}
    no_change = {"added": [], "changed": [], "removed": []}
    run = lambda number, method, keys, options: {"request": {"method": "methods.run", "id": number, "params": {
        "methodId": method, "entityType": "session", "keys": keys, "options": options}}}
    steps = [
        {"request": {"method": "project.open", "id": 1, "params": {"path": "${project}"}}, "expect": {"result": {"name": "OphysMotion"}}},
        {"request": {"method": "project.scan", "id": 2, "params": {}}, "expect": {"result": {"records": {"subject": 1, "session": 9}, "unmatched": 0}}},
        {"request": {"method": "project.sync", "id": 3, "params": {}}, "expect": {"result": {"added": {"session": [S1, S2, S3, S4, S5, S6, S7, S8, S9]}}}},
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
        # each candidate's edge found in its patch upsampled 4 times (the default, as flufinder), or at the image's own resolution
        {**run(1101, "ophys.quicky", [S5], {"stack": "TwoPhotonSeries_Original", "roiDiameter": 10, "upsampling": 1, "output": ""}),
         "expect": {"result": {"results": [shaped]}}},
        {**run(12, "ophys.quicky", [S5], {"stack": "TwoPhotonSeries_Original", "roiDiameter": 10, "useShapeDetection": False}),
         "expect": {"result": {"results": [{"rois": 0, "areas": []}]}}},
        # a resonant-scanner recording: flyback rows left out, the back lines' offset found once, the frames aligned,
        # and written as uint8; then with the offset found in every chunk
        {**run(13, "ophys.motion_correction", [S6], {"numFlybackLines": FLYBACK, "bidirectionalCorrection": "constant", "referenceFrames": 1,
                                                      "maxShift": 6, "iterations": 1, "outputType": "uint8"}), "expect": {"result": {"results": [scanned]}}},
        {"request": {"method": "data.frame", "id": 14, "params": {"entityType": "session", "key": S6, "variable": "TwoPhotonSeries_Corrected", "frame": 0}},
         "expect": {"result": {"height": 40, "width": 48, "frames": 30}}},
        {**run(15, "ophys.motion_correction", [S6], {"numFlybackLines": FLYBACK, "bidirectionalCorrection": "continuous", "referenceFrames": 1,
                                                      "maxShift": 6, "iterations": 1}), "expect": {"result": {"results": [scanned]}}},
        {**run(16, "ophys.motion_correction", [S6], {"bidirectionalCorrection": "sometimes"}), "expect": {"error": "invalid-options"}},
        # a resonant scanner's stretch undone by dev's profile of the nearest zoom: the scene at whole places
        {**run(17, "ophys.motion_correction", [S7], {"stretchCorrection": "sciscan", "zoomFactor": STRETCH_ZOOM, "referenceFrames": 1, "iterations": 1}),
         "expect": {"result": {"results": [{"frames": 3, "maxShift": 0, "meanShift": 0, "stretchZoom": PROFILE_ZOOM}]}}},
        {"request": {"method": "data.frame", "id": 18, "params": {"entityType": "session", "key": S7, "variable": "TwoPhotonSeries_Corrected",
                                                                  "frame": 2, "limits": stretch["limits"]}},
         "expect": {"result": {"height": 6, "width": stretch["width"], "frames": 3, "pixels": stretch["pixels"]}}},
        # no zoom given and none in the files (an .npy); no profile for lines of 32 pixels
        {**run(19, "ophys.motion_correction", [S7], {"stretchCorrection": "sciscan"}), "expect": {"error": "invalid-options"}},
        {**run(20, "ophys.motion_correction", [S1], {"stretchCorrection": "sciscan", "zoomFactor": 1}), "expect": {"error": "invalid-options"}},
        # with skipCompleted, the sessions it completed on whose outputs are there (s1, s2) are left out; s3 runs
        {"request": {"method": "methods.run", "id": 21, "params": {"methodId": "ophys.motion_correction", "entityType": "session",
                                                                   "keys": [S1, S2, S3], "options": {"referenceFrames": 1, "iterations": 1},
                                                                   "skipCompleted": True}},
         "expect": {"result": {"results": [{"frames": 2}], "skipped": [S1, S2]}}},
        {"request": {"method": "methods.run", "id": 22, "params": {"methodId": "ophys.motion_correction", "entityType": "session",
                                                                   "keys": [S3], "skipCompleted": True}},
         "expect": {"result": {"results": [], "skipped": [S3]}}},
        {"request": {"method": "methods.run", "id": 23, "params": {"methodId": "ophys.motion_correction", "entityType": "session",
                                                                   "keys": [S3], "skipCompleted": "yes"}},
         "expect": {"error": "invalid-params"}},
        # s9 is s8 bent by a smooth field and moved: rigid alignment finds the move, 3 x 3 patches each patch's displacement,
        # and s8's ROIs land where the field and the move put them
        {**run(24, "ophys.align_sessions", [S8, S9], {"image": "TwoPhotonSeries_Original", "maxShift": 6, "patches": 4 * NR_SIZE}),
         "expect": {"error": "invalid-options"}},
        {**run(25, "ophys.align_sessions", [S8, S9], {"image": "TwoPhotonSeries_Original", "maxShift": 6, "patches": NR_PATCHES, "maxDeviation": 2}),
         "expect": {"result": {"results": [{"reference": S8, "migrated": 1, "rois": 3, "kept": 0, "shifts": [
             {"key": S8, "shift": [0, 0], "rotation": 0, "patches": NR_PATCHES, "rowShifts": [0] * 9, "columnShifts": [0] * 9},
             {"key": S9, "shift": list(NR_MOVE), "rotation": 0, "patches": NR_PATCHES,
              "rowShifts": sum(NR_ROWS, []), "columnShifts": sum(NR_COLUMNS, [])}]}]}}},
        {**frame(26, S9), "expect": {"result": {"width": NR_SIZE, "height": NR_SIZE, "rois": bent}}},
        # an ROI drawn in s9 is added to s8 too, where the alignment puts it, with the same id
        {**update(27, S9, {"add": [{"pixels": drawn}], "mirror": True}),
         "expect": {"result": {"added": [4], "mirrored": [{"key": S8, "added": [4], "changed": [], "removed": []}]}}},
        {**frame(28, S8), "expect": {"result": {"rois": [{"id": 1}, {"id": 2}, {"id": 3}, {"id": 4, "pixels": drawn_in_s8}]}}},
        # an ROI of s8 moved, and one of s9 removed, in both
        {**update(29, S8, {"move": [{"id": 1, "rows": 1, "columns": -1}], "mirror": True}),
         "expect": {"result": {"added": [], "mirrored": [{"key": S9, "added": [], "changed": [1], "removed": []}]}}},
        {**update(30, S9, {"remove": [3], "mirror": True}),
         "expect": {"result": {"mirrored": [{"key": S8, **no_change, "removed": [3]}]}}},
        {**frame(31, S9), "expect": {"result": {"rois": [{"id": 1, "pixels": landed(moved_in_s8)}, {"id": 2}, {"id": 4, "pixels": drawn}]}}},
        {**frame(32, S8), "expect": {"result": {"rois": [{"id": 1, "pixels": moved_in_s8}, {"id": 2}, {"id": 4}]}}},
        # a classification mirrored; ROIs whose files have no alignment mirror nothing
        {**update(33, S8, {"classify": [{"id": 4, "classification": "unresolved"}], "mirror": True}),
         "expect": {"result": {"mirrored": [{"key": S9, **no_change, "changed": [4]}]}}},
        {**update(34, S1, {"add": [{"pixels": [[1, 1]]}], "mirror": True}), "expect": {"error": "invalid-params"}},
        {**update(35, S9, {"remove": [2], "mirror": "yes"}), "expect": {"error": "invalid-params"}},
        # s9's curation, and an ROI of its own, are kept when the sessions are aligned again; replaced when asked
        {**update(36, S9, {"classify": [{"id": 2, "classification": "accepted"}], "add": [{"pixels": [[5, 5], [5, 6]]}]}),
         "expect": {"result": {"added": [5]}}},
        {**run(37, "ophys.align_sessions", [S8, S9], {"image": "TwoPhotonSeries_Original", "maxShift": 6, "patches": NR_PATCHES, "maxDeviation": 2}),
         "expect": {"result": {"results": [{"migrated": 1, "rois": 3, "kept": 2}]}}},
        {**frame(38, S9), "expect": {"result": {"rois": [{"id": 1, "classification": None}, {"id": 2, "classification": "accepted"},
                                                         {"id": 4, "classification": "unresolved", "pixels": landed(drawn_in_s8)},
                                                         {"id": 5, "pixels": [[5, 5], [5, 6]]}]}}},
        {**run(39, "ophys.align_sessions", [S8, S9], {"image": "TwoPhotonSeries_Original", "maxShift": 6, "patches": NR_PATCHES,
                                                      "maxDeviation": 2, "existingRois": "replace"}),
         "expect": {"result": {"results": [{"migrated": 1, "rois": 3, "kept": 0}]}}},
        {**frame(40, S9), "expect": {"result": {"rois": [{"id": 1}, {"id": 2, "classification": None}, {"id": 4, "classification": None}]}}},
        # through a rotation: an ROI drawn in s4 is added to s3, turned back
        {**update(41, S4, {"add": [{"pixels": drawn_s4}], "mirror": True}),
         "expect": {"result": {"added": [4], "mirrored": [{"key": S3, "added": [4], "changed": [], "removed": []}]}}},
        {**frame(42, S3), "expect": {"result": {"rois": [{"id": 1}, {"id": 2}, {"id": 3}, {"id": 4, "pixels": mirrored_to_s3(drawn_s4)}]}}},
    ]
    (HERE / "session.json").write_text(json.dumps({"steps": steps}, indent=2) + "\n", encoding="utf-8")
    expected = {"description": "Motion correction finer than whole pixels: subpixel shifts on a texture moved by half pixels, piecewise rigid "
                               "correction (patches) of a texture whose quadrants move apart, and sessions aligned with a rotation and piecewise (a field that bends), whose ROIs "
                               "land where the ground truth puts them, and ROI edits mirrored between them through the alignment; and Quicky's shape detection finding somata that are never active, their patches upsampled as flufinder does or not; run again with skipCompleted, the sessions it already corrected are left out. make_data.py writes the recordings and the steps from the ground truth.",
                "steps": len(steps)}
    (HERE / "expected.json").write_text(json.dumps(expected, indent=2) + "\n", encoding="utf-8")
    print(json.dumps([first, second]))


if __name__ == "__main__":
    main()
