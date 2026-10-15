"""Write small files in the formats the ophys module reads, and expected.json with what each must read as.

Run from the repository root: python conformance/files/ophys/make_formats.py (needs NumPy, SciPy, h5py, tifffile)

Python's test_formats.py and MATLAB's FormatsTest.m read every file with the module's adapters and compare
with expected.json, which is computed here from the values the files are made from, not with either
language's reader. ROI files read as the module's ROI document: imageSize, and rois of id (in file order,
from 1), area, center (0-based mean row and column, rounded to 2 decimals) and 0-based [row, column]
pixels in row-major order, with classification where the file has one.
"""

import json
import math
from pathlib import Path

import h5py
import numpy as np
import scipy.io
import tifffile

HERE = Path(__file__).parent
HEIGHT, WIDTH = 20, 24


def roi(number, pixels, classification=None):
    pixels = sorted({(int(r), int(c)) for r, c in pixels if 0 <= r < HEIGHT and 0 <= c < WIDTH})
    out = {"id": number, "area": len(pixels),
           "center": [math.floor(np.mean([p[0] for p in pixels]) * 100 + 0.5) / 100, math.floor(np.mean([p[1] for p in pixels]) * 100 + 0.5) / 100],
           "pixels": [list(p) for p in pixels]}
    if classification:
        out["classification"] = classification
    return out


def in_polygon(xs, ys, px, py):
    """Even-odd rule: is the point inside the polygon of vertices (xs, ys)?"""
    inside = False
    j = len(xs) - 1
    for i in range(len(xs)):
        if (ys[i] > py) != (ys[j] > py) and px < (xs[j] - xs[i]) * (py - ys[i]) / (ys[j] - ys[i]) + xs[i]:
            inside = not inside
        j = i
    return inside


def nansen_rois(expected):
    """dev's roiArray: a struct array of RoI properties. Coordinates are 1-based x (column) and y (row)."""
    mask = [(3, 4), (3, 5), (4, 4), (4, 5), (5, 5)]                         # (row, column), 0-based
    circle = (15.0, 6.0, 3.0)                                                  # x, y (1-based) and radius
    polygon = np.array([[10.5, 12.5], [16.5, 12.5], [16.5, 17.5], [10.5, 17.5], [13.5, 15.0]])   # x, y; a notch
    fields = ["uid", "shape", "coordinates", "imagesize", "area", "center", "celltype"]
    rows = [
        ("a1", "Mask", np.array([[c + 1, r + 1] for r, c in mask], dtype=float), [HEIGHT, WIDTH], 5.0, [5.0, 4.0], "neuron"),
        ("a2", "Circle", np.array([circle]), [HEIGHT, WIDTH], 28.0, [15.0, 6.0], ""),
        ("a3", "Polygon", polygon, [HEIGHT, WIDTH], 30.0, [13.0, 15.0], ""),
    ]
    records = np.empty((1, len(rows)), dtype=[(f, "O") for f in fields])
    for k, row in enumerate(rows):
        records[0, k] = tuple(np.asarray(v, dtype=float) if isinstance(v, list) else v for v in row)
    scipy.io.savemat(HERE / "rois_nansen.mat", {"roiArray": records})
    x, y, r = circle
    disk = [(y - 1 + dr, x - 1 + dc) for dr in range(-3, 4) for dc in range(-3, 4) if dr * dr + dc * dc < r * r]
    inside = [(row, col) for row in range(HEIGHT) for col in range(WIDTH) if in_polygon(polygon[:, 0], polygon[:, 1], col + 1, row + 1)]
    expected["nansen"] = {"imageSize": [HEIGHT, WIDTH], "rois": [roi(1, mask), roi(2, disk), roi(3, inside)]}


def roi_group(expected):
    """dev's RoiGroup file of two planes, as its RoiSegmentation and roimanager save them: roiArray and
    roiClassification are cells, one per plane (planes x channels), with ChannelNumber and PlaneNumber. Plane 1
    has a Mask ROI classified accepted (1), an IMask ROI with a pixel of weight 0 (not part of it) classified
    rejected (2), and an unresolved (3) Mask ROI; the ROI document is plane 1's."""
    fields = ["uid", "shape", "coordinates", "pixelweights", "imagesize", "boundary", "area", "center", "connectedrois",
              "group", "celltype", "structure", "layer", "tags", "enhancedImage"]

    def records(rows):
        out = np.empty((1, len(rows)), dtype=[(f, "O") for f in fields])
        for k, (uid, shape, pixels, weights) in enumerate(rows):
            coordinates = np.array([[c + 1, r + 1] for r, c in pixels], dtype=float)   # 1-based x, y
            boundary = np.empty((1, 1), dtype=object)
            boundary[0, 0] = np.array([[np.nan, np.nan]])
            out[0, k] = (uid, shape, coordinates, np.array(weights, dtype=float).reshape(-1, 1) if weights else np.zeros((0, 0)),
                         np.array([HEIGHT, WIDTH], dtype=float), boundary, float(len(pixels)),
                         coordinates.mean(axis=0), np.empty((0, 0), dtype=object), np.zeros((0, 0)), "", "na", "",
                         np.empty((0, 1), dtype=object), np.zeros((0, 0)))
        return out
    accepted = [(2, 2), (2, 3), (3, 2), (3, 3)]
    weighted = [(8, 10), (8, 11), (9, 10), (9, 11), (10, 10)]
    weights = [0.5, 1.0, 0.8, 0.0, 0.3]                                     # (9, 11) has weight 0: not part of it
    unresolved = [(14, 4), (14, 5), (15, 4)]
    plane1 = records([("p1a", "Mask", accepted, None), ("p1b", "IMask", weighted, weights), ("p1c", "Mask", unresolved, None)])
    plane2 = records([("p2a", "Mask", [(20, 20), (20, 21)], None)])
    rois = np.empty((2, 1), dtype=object)
    rois[0, 0], rois[1, 0] = plane1, plane2
    classes = np.empty((2, 1), dtype=object)
    classes[0, 0], classes[1, 0] = np.array([[1.0], [2.0], [3.0]]), np.array([[0.0]])
    planes = np.empty((2, 1), dtype=object)
    planes[0, 0], planes[1, 0] = 1.0, 2.0
    channels = np.empty((2, 1), dtype=object)
    channels[0, 0], channels[1, 0] = 1.0, 1.0
    scipy.io.savemat(HERE / "rois_group.mat", {"roiArray": rois, "roiClassification": classes, "roiImages": np.zeros((0, 0)),
                                               "roiStats": np.zeros((0, 0)), "PlaneNumber": planes, "ChannelNumber": channels})
    kept = [p for p, w in zip(weighted, weights) if w > 0]
    expected["roiGroup"] = {"imageSize": [HEIGHT, WIDTH],
                            "rois": [roi(1, accepted, "accepted"), roi(2, kept, "rejected"), roi(3, unresolved)]}


def dev_binary(expected):
    """dev's binary stack: a headerless .raw in MATLAB's column-major order, little-endian, and an .ini with its
    Size (written by MATLAB's num2str, several spaces apart) and Class. 9 x 7 x 5 uint16, so rows and columns
    cannot be swapped unnoticed."""
    rng = np.random.default_rng(16)
    stack = rng.integers(0, 4000, (9, 7, 5)).astype(np.uint16)
    folder = HERE / "binary"
    folder.mkdir(exist_ok=True)
    stack.astype("<u2").ravel(order="F").tofile(folder / "stack.raw")
    (folder / "stack.ini").write_text("Size = 9    7    5\nClass = uint16\n")
    expected["devBinary"] = {"size": [9, 7, 5], "pixel": {"at": [4, 6, 3], "value": int(stack[4, 6, 3])},
                             "frame2row8": [int(v) for v in stack[8, :, 2]], "sum": int(stack.astype(np.int64).sum())}


def suite2p_binary(expected):
    """suite2p's data.bin: int16 frames of Ly x Lx in C order, after one another, and an ops.npy (a pickled dict, as
    suite2p saves it) with Ly and Lx among other entries. 9 x 7 x 5, values below 0 too."""
    rng = np.random.default_rng(17)
    stack = rng.integers(-500, 4000, (9, 7, 5)).astype(np.int16)
    folder = HERE / "suite2p" / "plane0"
    folder.mkdir(parents=True, exist_ok=True)
    np.moveaxis(stack, 2, 0).astype("<i2").tofile(folder / "data.bin")   # frames x Ly x Lx, C order
    np.save(folder / "ops.npy", {"nframes": 5, "Ly": 9, "Lx": 7, "fs": 30.0, "meanImg": stack.mean(axis=2).astype(np.float32),
                                 "save_path": "plane0", "nchannels": 1})
    expected["suite2pBinary"] = {"size": [9, 7, 5], "pixel": {"at": [4, 6, 3], "value": int(stack[4, 6, 3])},
                                 "frame2row8": [int(v) for v in stack[8, :, 2]], "sum": int(stack.astype(np.int64).sum())}


def suite2p_rois(expected):
    """suite2p's Fall.mat: stat (a cell array of structs with 0-based ypix, xpix), iscell and ops (Ly, Lx)."""
    cells = [([2, 2, 3, 3], [7, 8, 7, 8], 1), ([10, 11, 11, 12, 12, 12], [3, 3, 4, 3, 4, 5], 0), ([17, 18], [20, 21], 1)]
    stat = np.empty((1, len(cells)), dtype=object)
    for k, (ys, xs, _) in enumerate(cells):
        stat[0, k] = {"ypix": np.array(ys, dtype=np.int32), "xpix": np.array(xs, dtype=np.int32), "npix": len(ys),
                      "lam": np.ones(len(ys), dtype=np.float32)}
    iscell = np.array([[c, 0.9 if c else 0.1] for *_, c in cells], dtype=float)
    scipy.io.savemat(HERE / "Fall.mat", {"stat": stat, "iscell": iscell, "ops": {"Ly": HEIGHT, "Lx": WIDTH}})
    expected["suite2p"] = {"imageSize": [HEIGHT, WIDTH],
                           "rois": [roi(k + 1, zip(ys, xs), None if c else "rejected") for k, (ys, xs, c) in enumerate(cells)]}


def weights_roi(number, weights, threshold=0.2):
    """The 8-connected area around the peak of pixels whose weight is at least threshold times the peak's."""
    peak = np.unravel_index(np.argmax(weights), weights.shape)
    above = weights >= threshold * weights[peak]
    area, todo = {peak}, [peak]
    while todo:
        r, c = todo.pop()
        for dr in (-1, 0, 1):
            for dc in (-1, 0, 1):
                n = (r + dr, c + dc)
                if 0 <= n[0] < HEIGHT and 0 <= n[1] < WIDTH and above[n] and n not in area:
                    area.add(n)
                    todo.append(n)
    return roi(number, area)


def footprints():
    """Two spatial weight images: a blob, and a blob with a faint patch elsewhere (left out: not connected)."""
    yy, xx = np.mgrid[0:HEIGHT, 0:WIDTH]
    one = np.exp(-((yy - 6) ** 2 + (xx - 15) ** 2) / 4.0)
    two = np.exp(-((yy - 14) ** 2 + (xx - 6) ** 2) / 6.0)
    two[2, 2] = 0.5   # above 0.2 x the peak, but apart from it
    for w in (one, two):
        w[w < 0.05] = 0
    return [one, two]


def caiman_rois(expected):
    """CaImAn's HDF5 results: estimates/A, the spatial components as a sparse (pixels x components) CSC matrix,
    pixels in Fortran order (row + column x height), and dims."""
    weights = footprints()
    dense = np.stack([w.flatten(order="F") for w in weights], axis=1)
    data, indices, indptr = [], [], [0]
    for k in range(dense.shape[1]):
        rows = np.flatnonzero(dense[:, k])
        data.extend(dense[rows, k])
        indices.extend(rows)
        indptr.append(len(indices))
    with h5py.File(HERE / "caiman.hdf5", "w") as f:
        f["dims"] = np.array([HEIGHT, WIDTH])
        group = f.create_group("estimates/A")
        group["data"] = np.array(data)
        group["indices"] = np.array(indices, dtype=np.int32)
        group["indptr"] = np.array(indptr, dtype=np.int32)
        group["shape"] = np.array(dense.shape)
    expected["caiman"] = {"imageSize": [HEIGHT, WIDTH], "rois": [weights_roi(k + 1, w) for k, w in enumerate(weights)]}


def extract_rois(expected):
    """EXTRACT's output, saved as a .mat file: output.spatial_weights, height x width x cells."""
    weights = footprints()
    scipy.io.savemat(HERE / "extract.mat", {"output": {"spatial_weights": np.stack(weights, axis=2),
                                                       "temporal_weights": np.zeros((5, 2))}})
    expected["extract"] = {"imageSize": [HEIGHT, WIDTH], "rois": [weights_roi(k + 1, w) for k, w in enumerate(weights)]}


def prairie(expected):
    """A Bruker (Prairie View) T-series: an XML file listing a TIFF file per frame and channel."""
    folder = HERE / "tseries"
    folder.mkdir(exist_ok=True)
    rng = np.random.default_rng(5)
    frames = rng.integers(0, 4000, (HEIGHT, WIDTH, 2, 5)).astype(np.uint16)   # height x width x channels x frames
    lines = ['<?xml version="1.0" encoding="utf-8"?>', '<PVScan version="5.4.64.200" date="1/1/2026" notes="">',
             '  <Sequence type="TSeries Timed Element" cycle="1" time="10:00:00.000">']
    for t in range(5):
        lines.append(f'    <Frame relativeTime="{t * 0.033:.3f}" index="{t + 1}" parameterSet="CurrentSettings">')
        for c in range(2):
            name = f"TSeries-001_Cycle00001_Ch{c + 1}_{t + 1:06d}.ome.tif"
            tifffile.imwrite(folder / name, frames[:, :, c, t], photometric="minisblack")
            lines.append(f'      <File channel="{c + 1}" channelName="Ch{c + 1}" page="1" filename="{name}" />')
        lines.append("    </Frame>")
    lines += ["  </Sequence>", "</PVScan>", ""]
    (folder / "TSeries-001.xml").write_text("\n".join(lines), encoding="utf-8")
    expected["prairie"] = {"size": [HEIGHT, WIDTH, 2, 5], "sum": int(frames.astype(np.int64).sum()),
                           "pixel": {"at": [3, 7, 1, 4], "value": int(frames[3, 7, 1, 4])},
                           "channel2frame3": frames[:, :, 1, 2].astype(int).tolist()}


def hdf5_stack(expected):
    """An HDF5 stack: dataset data, frames x height x width as h5py shows it (C order)."""
    rng = np.random.default_rng(6)
    stack = rng.normal(100, 10, (HEIGHT, WIDTH, 7)).astype(np.float32)   # height x width x frames
    with h5py.File(HERE / "stack.h5", "w") as f:
        f["data"] = np.moveaxis(stack, 2, 0)
    expected["hdf5"] = {"size": [HEIGHT, WIDTH, 7], "pixel": {"at": [5, 9, 3], "value": float(stack[5, 9, 3])},
                        "frame6row2": [float(v) for v in stack[2, :, 6]]}


def mat73(expected):
    """A MATLAB v7.3 .mat file (HDF5 with MATLAB's 512-byte header), made as MATLAB makes them: arrays with their
    dimensions reversed and a MATLAB_class attribute, text as uint16, a struct as a group. MATLAB's load reads it,
    and Python's mat adapter falls back to h5py for it."""
    path = HERE / "v73.mat"
    with h5py.File(path, "w", userblock_size=512) as f:
        def put(name, data, kind, where=f):
            where[name] = data
            where[name].attrs["MATLAB_class"] = np.bytes_(kind)
            return where[name]
        put("matrix", np.array([[1.0, 2, 3], [4, 5, 6]]).T, "double")                      # MATLAB: 2 x 3
        put("name", np.array([[ord(c) for c in "roi"]], dtype=np.uint16).T, "char").attrs["MATLAB_int_decode"] = np.int32(2)
        put("flags", np.array([[1, 0, 1]], dtype=np.uint8).T, "logical").attrs["MATLAB_int_decode"] = np.int32(1)   # MATLAB: 1 x 3
        info = f.create_group("info")
        info.attrs["MATLAB_class"] = np.bytes_("struct")
        put("rate", np.array([[30.0]]), "double", info)
    text = "MATLAB 7.3 MAT-file, Platform: GLNXA64, Created on: Thu Oct 15 00:00:00 2026 HDF5 schema 1.00 ."
    header = (text + " " * (116 - len(text))).encode("ascii") + b"\x00" * 8 + b"\x00\x02" + b"IM"
    with open(path, "r+b") as f:
        f.write(header)
    expected["mat73"] = {"matrix": [[1, 2, 3], [4, 5, 6]], "name": "roi", "flags": [True, False, True], "rate": 30}


def main():
    expected = {}
    nansen_rois(expected)
    roi_group(expected)
    dev_binary(expected)
    suite2p_binary(expected)
    suite2p_rois(expected)
    caiman_rois(expected)
    extract_rois(expected)
    prairie(expected)
    hdf5_stack(expected)
    mat73(expected)
    (HERE / "expected.json").write_text(json.dumps(expected, indent=1) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
