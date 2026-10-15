"""Write this case's files (data/) and its steps (session.json), with the values the steps expect.

Run from the repository root: python conformance/api/view/make_data.py

The case views files with no project, as `nansen view` does: the runners register session.json's viewables (copied
from data/ into the scratch folder first) before the steps. Every expected value comes from the ground truth the
recording is made from, computed here directly, not with either reader's code:

- movie.npy: 40 x 40 x 12, uint16. A smooth periodic scene of whole numbers with three round cells (radius 2: 13
  pixels each) whose brightness changes from frame to frame, each frame moved by known whole pixels (circularly, so
  motion correction finds them exactly and the aligned scene does not change). Motion correction finds those moves.
  In the aligned stack a cell's pixels change together and the scene's not at all, so a pixel's average correlation
  with its 8 neighbours is the share of them in its cell: ROI detection at threshold 0.45 finds, in each cell, the
  pixels with 4 or more of their neighbours in it. Detect finds the whole cell around a click.
- curated.json: two ROIs given with a second view of the same file, saved back to that file when they change.
- dff.npy: signals (frames x 2), which have no ROIs and run no methods.
"""

import json
import math
import shutil
from pathlib import Path

import numpy as np

HERE = Path(__file__).parent
DATA = HERE / "data"
SIZE, FRAMES, RADIUS = 40, 12, 2
CELLS = [(14, 14), (14, 26), (26, 20)]
SHIFTS = [(0, 0), (1, 0), (0, -1), (2, 1), (-1, 2), (0, 0), (-2, -1), (1, -2), (0, 1), (2, 2), (-1, 0), (1, 1)]
SCRATCH = "${scratch}/data"


def round_to(value, digits):
    return math.floor(float(value) * 10 ** digits + 0.5) / 10 ** digits


def disc(centre):
    cy, cx = centre
    return [[y, x] for y in range(cy - RADIUS, cy + RADIUS + 1) for x in range(cx - RADIUS, cx + RADIUS + 1)
            if (y - cy) ** 2 + (x - cx) ** 2 <= RADIUS * RADIUS]


def movie():
    rng = np.random.default_rng(21)
    fy, fx = np.fft.fftfreq(SIZE)[:, None], np.fft.fftfreq(SIZE)[None, :]
    smooth = np.real(np.fft.ifft2(np.fft.fft2(rng.normal(0, 1, (SIZE, SIZE))) * np.exp(-(fy ** 2 + fx ** 2) * 200)))
    scene = np.round(400 + 60 * smooth / np.abs(smooth).max())
    stack = np.zeros((SIZE, SIZE, FRAMES))
    for t, (dy, dx) in enumerate(SHIFTS):
        frame = scene.copy()
        for centre in CELLS:
            brightness = 200 + int(rng.integers(0, 600))   # the cell's activity in this frame
            for y, x in disc(centre):
                frame[y, x] += brightness
        # the frame shows the scene moved by (-dy, -dx), circularly: motion correction finds the move and undoes it
        stack[:, :, t] = np.roll(frame, (-dy, -dx), axis=(0, 1))
    return stack.astype(np.uint16)


def found_in(cell):
    """The pixels of a cell that ROI detection finds: those with 4 or more of their 8 neighbours in the cell, whose
    average correlation with them (1 with each of those, 0 with the others) reaches 0.45."""
    inside = {tuple(p) for p in disc(cell)}
    count = lambda y, x: sum((y + dy, x + dx) in inside for dy in (-1, 0, 1) for dx in (-1, 0, 1) if dy or dx)
    return [p for p in disc(cell) if count(*p) >= 4]


def main():
    if DATA.exists():
        shutil.rmtree(DATA)
    DATA.mkdir()
    np.save(DATA / "movie.npy", np.asfortranarray(movie()))
    np.save(DATA / "dff.npy", np.column_stack([np.linspace(0, 1, FRAMES), np.linspace(1, 0, FRAMES)]))
    curated = {"imageSize": [SIZE, SIZE], "rois": [
        {"id": 1, "pixels": disc(CELLS[0]), "classification": "accepted"},
        {"id": 2, "pixels": [[3, 3], [3, 4]], "classification": "rejected"}]}
    (DATA / "curated.json").write_text(json.dumps(curated, indent=2) + "\n")

    lengths = [math.hypot(dy, dx) for dy, dx in SHIFTS]
    motion = {"frames": FRAMES, "maxShift": max(max(abs(dy), abs(dx)) for dy, dx in SHIFTS),
              "meanShift": round_to(sum(lengths) / len(lengths), 4)}
    found = sorted(found_in(c) for c in CELLS)   # ROIs come in the row-major order of their first pixel
    square = [[5, 5], [5, 6], [6, 5], [6, 6]]
    movie_path, curated_path = f"{SCRATCH}/movie.npy", f"{SCRATCH}/curated.json"
    corrected = f"{SCRATCH}/movie_TwoPhotonSeries_Corrected.npy"
    found_path = f"{SCRATCH}/movie_TwoPhotonSeries_Corrected_RoiArray.json"

    steps = []

    def step(method, params, expect, keep=None):
        entry = {"request": {"method": method, "id": len(steps) + 1, "params": params}, "expect": expect}
        if keep:
            entry["keep"] = keep
        steps.append(entry)

    def ok(result):
        return {"result": result}

    def error(code):
        return {"error": code}

    first = {"id": "v1", "kind": "stack", "name": "movie.npy", "path": movie_path, "rois": False,
             "roiFile": f"{SCRATCH}/movie_rois.json"}
    second = {"id": "v2", "kind": "stack", "name": "curated", "path": movie_path, "rois": True, "roiFile": curated_path}
    third = {"id": "v3", "kind": "signals", "name": "dff", "path": f"{SCRATCH}/dff.npy", "rois": False, "roiFile": ""}
    step("view.list", {}, ok([first, second, third]))
    # only what was registered is read, with no project open
    step("view.frame", {"viewable": "v9"}, error("unknown-viewable"))
    step("view.signal", {"viewable": "v9", "pixels": [[0, 0]]}, error("unknown-viewable"))
    step("view.traces", {"viewable": "v9", "columns": [0]}, error("unknown-viewable"))
    step("view.detect", {"viewable": "v9", "point": [0, 0]}, error("unknown-viewable"))
    step("view.run", {"viewable": "v9", "methodId": "ophys.motion_correction"}, error("unknown-viewable"))
    step("view.frame", {}, error("invalid-params"))
    step("files.frame", {"path": "recording.tif"}, error("no-project"))   # a file is read by files.frame only in a project
    # ROIs drawn on a file given none: saved to <stem>_rois.json beside it
    step("view.frame", {"viewable": "v1", "rois": True}, ok({"height": SIZE, "width": SIZE, "frames": FRAMES, "rois": []}))
    step("view.updateRois", {"viewable": "v1", "imageSize": [SIZE, SIZE], "add": [{"pixels": square}]},
         ok({"rois": [{"id": 1, "pixels": square, "classification": None}], "added": [1], "file": f"{SCRATCH}/movie_rois.json"}))
    step("view.updateRois", {"viewable": "v1", "classify": [{"id": 1, "classification": "accepted"}]},
         ok({"rois": [{"id": 1, "classification": "accepted"}], "added": []}))
    step("view.updateRois", {"viewable": "v1", "move": [{"id": 1, "rows": 1, "columns": 2}]},
         ok({"rois": [{"id": 1, "pixels": [[6, 7], [6, 8], [7, 7], [7, 8]]}], "added": []}))
    step("view.updateRois", {"viewable": "v1", "restore": [{"id": 1, "pixels": square, "classification": "accepted"}]},
         ok({"rois": [{"id": 1, "pixels": square, "classification": "accepted"}], "added": []}))   # undo
    step("view.list", {}, ok([dict(first, rois=True), second, third]))
    step("view.frame", {"viewable": "v1", "rois": True}, ok({"rois": [{"id": 1, "classification": "accepted"}]}))
    # the ROIs given with the second view: saved back to their file; imported into the first, where they do not overlap
    step("view.updateRois", {"viewable": "v2", "classify": [{"id": 2, "classification": None}]},
         ok({"rois": [{"id": 1, "classification": "accepted"}, {"id": 2, "classification": None}], "added": [], "file": curated_path}))
    step("view.updateRois", {"viewable": "v1", "import": {"viewable": "v2", "mode": "appendNonOverlapping"}},
         ok({"rois": [{"id": 1}, {"id": 2, "pixels": disc(CELLS[0])}, {"id": 3, "pixels": [[3, 3], [3, 4]]}], "added": [2, 3]}))
    step("view.updateRois", {"viewable": "v1", "remove": [2, 3]}, ok({"rois": [{"id": 1}], "added": []}))
    step("view.updateRois", {"viewable": "v1", "mirror": True}, error("invalid-params"))
    step("view.updateRois", {"viewable": "v1", "import": {"variable": "RoiArray"}}, error("invalid-params"))
    step("view.updateRois", {"viewable": "v1", "import": {"viewable": "v9"}}, error("unknown-viewable"))
    step("view.updateRois", {"viewable": "v1", "remove": [7]}, error("invalid-params"))
    step("view.updateRois", {"viewable": "v3", "add": [{"pixels": square}]}, error("invalid-params"))
    step("view.updateRois", {"viewable": "v9", "add": [{"pixels": square}]}, error("unknown-viewable"))
    # methods of the built-in modules, run on a stack: what they save is written beside it and viewable
    step("view.run", {"viewable": "v1", "methodId": "ophys.nothing"}, error("unknown-method"))
    step("view.run", {"viewable": "v1", "methodId": "ophys.setup_variables"}, error("wrong-entity-type"))
    step("view.run", {"viewable": "v1", "methodId": "ophys.compute_dff"}, error("invalid-params"))   # it reads no stack
    step("view.run", {"viewable": "v3", "methodId": "ophys.motion_correction"}, error("invalid-params"))   # signals
    step("view.run", {"viewable": "v1", "methodId": "ophys.motion_correction", "options": {"maxShift": -1}}, error("invalid-options"))
    step("view.run", {"viewable": "v1", "methodId": "ophys.motion_correction", "preset": "nothing"}, error("unknown-preset"))
    corrected_entry = {"variable": "TwoPhotonSeries_Corrected", "path": corrected, "kind": "stack", "viewable": "v4"}
    shifts_entry = {"variable": "MotionCorrectionShifts", "path": f"{SCRATCH}/movie_MotionCorrectionShifts.npy", "kind": "data", "viewable": ""}
    step("view.run", {"viewable": "v1", "methodId": "ophys.motion_correction", "options": {"maxShift": 4, "referenceFrames": 1}},
         ok({"result": motion, "outputs": [corrected_entry, shifts_entry]}))
    fourth = {"id": "v4", "kind": "stack", "name": "movie.npy · TwoPhotonSeries_Corrected", "path": corrected, "rois": False,
              "roiFile": f"{SCRATCH}/movie_TwoPhotonSeries_Corrected_rois.json"}
    step("view.list", {}, ok([dict(first, rois=True), second, third, fourth]))
    step("view.frame", {"viewable": "v4", "projection": "mean"}, ok({"height": SIZE, "width": SIZE, "frames": FRAMES,
                                                                     "adapter": "npy", "adapters": ["npy"]}))
    # Detect, around a click on a cell of the aligned stack's mean
    step("view.detect", {"viewable": "v4", "point": list(CELLS[2]), "radius": 4}, ok({"pixels": disc(CELLS[2])}))
    step("view.detect", {"viewable": "v4", "point": [SIZE, 0]}, error("invalid-params"))
    step("view.detect", {"viewable": "v3", "point": [0, 0]}, error("invalid-params"))
    # roimanager's autosegmentation: ROIs found in the aligned stack, viewable over it, and added to its own ROIs
    found_entry = {"variable": "RoiArray", "path": found_path, "kind": "rois", "viewable": "v5"}
    step("view.run", {"viewable": "v4", "methodId": "ophys.detect_rois", "options": {"border": 5, "threshold": 0.45}},
         ok({"result": {"rois": 3, "areas": [len(p) for p in found]}, "outputs": [found_entry]}))
    step("view.frame", {"viewable": "v5", "rois": True}, ok({"rois": [{"id": n + 1, "pixels": p} for n, p in enumerate(found)]}))
    step("view.updateRois", {"viewable": "v4", "import": {"viewable": "v5", "mode": "replace"}},
         ok({"rois": [{"id": n + 1, "pixels": p} for n, p in enumerate(found)], "added": [1, 2, 3],
             "file": f"{SCRATCH}/movie_TwoPhotonSeries_Corrected_rois.json"}))
    # run again: the same variables are viewed under the same ids
    step("view.run", {"viewable": "v4", "methodId": "ophys.detect_rois", "options": {"border": 5, "threshold": 0.45}},
         ok({"outputs": [found_entry]}))
    step("view.list", {}, ok([dict(first, rois=True), second, third, dict(fourth, rois=True),
                              {"id": "v5", "kind": "stack", "name": "movie.npy · TwoPhotonSeries_Corrected · RoiArray",
                               "path": corrected, "rois": True, "roiFile": found_path}]))

    viewables = [{"stack": movie_path}, {"stack": movie_path, "rois": curated_path, "name": "curated"},
                 {"signals": f"{SCRATCH}/dff.npy"}]
    (HERE / "session.json").write_text(json.dumps({"viewables": viewables, "steps": steps}, indent=2) + "\n")
    expected = json.loads((HERE / "expected.json").read_text())
    expected["steps"] = len(steps)
    (HERE / "expected.json").write_text(json.dumps(expected, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
