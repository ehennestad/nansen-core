"""Write small files in the formats the ophys module reads, and expected.json with what each must read as.

Run from the repository root: python conformance/files/ophys/make_formats.py (needs NumPy, SciPy, h5py, tifffile)

Python's test_formats.py and MATLAB's FormatsTest.m read every file with the module's adapters and compare
with expected.json, which is computed here from the values the files are made from, not with either
language's reader. ROI files read as the module's ROI document: imageSize, and rois of id (in file order,
from 1), area, center (0-based mean row and column, rounded to 2 decimals) and 0-based [row, column]
pixels in row-major order, with classification where the file has one. A stack's metadata (frameRate,
pixelSize, zStep) is computed from the header values the file is written with, each rounded to 6 decimals.
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


def round6(value):
    """A metadata value as the readers give it: rounded to 6 decimals, floor(v * 1e6 + 0.5) / 1e6."""
    return math.floor(value * 1e6 + 0.5) / 1e6


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
    rejected (2), and an unresolved (3) Mask ROI; plane 2 an unclassified Mask ROI. The ROI document has them all,
    each with its plane and channel."""
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
    plane2 = records([("p2a", "Mask", [(17, 20), (17, 21)], None)])
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
                            "rois": [dict(roi(1, accepted, "accepted"), plane=1, channel=1), dict(roi(2, kept, "rejected"), plane=1, channel=1),
                                     dict(roi(3, unresolved), plane=1, channel=1), dict(roi(4, [(17, 20), (17, 21)]), plane=2, channel=1)]}


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
                             "frame2row8": [int(v) for v in stack[8, :, 2]], "sum": int(stack.astype(np.int64).sum()), "metadata": {}}


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


def video(expected):
    """Videos as uncompressed AVI (raw BGR, which every decoder reads to the same bytes), written with imageio's ffmpeg:
    rgb.avi in colour, 12 x 16 x 4 frames, and gray.avi whose red, green and blue are equal, read as grayscale; 10 frames
    per second."""
    import imageio.v2 as iio
    rng = np.random.default_rng(18)
    folder = HERE / "video"
    folder.mkdir(exist_ok=True)
    colour = rng.integers(0, 256, (4, 12, 16, 3)).astype(np.uint8)   # frames x height x width x rgb
    gray = np.repeat(rng.integers(0, 256, (3, 12, 16, 1)).astype(np.uint8), 3, axis=3)
    for name, frames in (("rgb.avi", colour), ("gray.avi", gray)):
        writer = iio.get_writer(folder / name, format="ffmpeg", codec="rawvideo", pixelformat="bgr24", fps=10,
                                macro_block_size=1, output_params=["-f", "avi"])
        for frame in frames:
            writer.append_data(frame)
        writer.close()
    expected["video"] = {
        "rgb": {"size": [12, 16, 3, 4], "pixel": {"at": [5, 7, 2, 2], "value": int(colour[2, 5, 7, 2])},
                "sum": int(colour.astype(np.int64).sum()), "metadata": {"frameRate": 10.0}},
        "gray": {"size": [12, 16, 3], "pixel": {"at": [11, 15, 1], "value": int(gray[1, 11, 15, 0])},
                 "sum": int(gray[..., 0].astype(np.int64).sum()), "metadata": {"frameRate": 10.0}}}


def image_files(expected):
    """Image sequences, a file per frame: 3 grayscale 16-bit PNG files (written out of order so natural order
    matters: frame_10 after frame_2), and 2 colour BMP files."""
    import imageio.v2 as iio
    rng = np.random.default_rng(23)
    folder = HERE / "images"
    folder.mkdir(exist_ok=True)
    gray = rng.integers(0, 60000, (3, 7, 9)).astype(np.uint16)   # frames x height x width
    for t, name in enumerate(["frame_1.png", "frame_2.png", "frame_10.png"]):
        iio.imwrite(folder / name, gray[t])
    colour = rng.integers(0, 256, (2, 5, 6, 3)).astype(np.uint8)
    for t in range(2):
        iio.imwrite(folder / f"colour_{t + 1}.bmp", colour[t])
    expected["images"] = {
        "gray": {"size": [7, 9, 3], "pixel": {"at": [6, 8, 2], "value": int(gray[2, 6, 8])}, "sum": int(gray.astype(np.int64).sum())},
        "colour": {"size": [5, 6, 3, 2], "pixel": {"at": [4, 5, 1, 1], "value": int(colour[1, 4, 5, 1])},
                   "sum": int(colour.astype(np.int64).sum())}}


def norpix(expected):
    """Norpix StreamPix sequences: a 1024-byte header, then each frame trueImageSize bytes apart (the image, an
    8-byte timestamp and padding); 4 grayscale 8-bit frames of 6 x 8 at 25 fps, and 3 BGR frames of 4 x 5 at 12.5 fps,
    whose last is cut short by the end of the file (it is left out)."""
    rng = np.random.default_rng(29)

    def write(name, images, kind, depth, rate, cut=0):
        frames, height, width = images.shape[:3]
        size = images[0].nbytes
        true_size = size + 8 + 24   # timestamp and padding
        head = bytearray(1024)
        head[0:4] = (0xFEED).to_bytes(4, "little")
        head[4:24] = "Norpix seq".encode("utf-16-le")
        head[28:32] = (5).to_bytes(4, "little")
        head[32:36] = (1024).to_bytes(4, "little")
        values = [width, height, depth, depth, size, kind, frames, 0, true_size]
        head[548:584] = np.array(values, dtype="<u4").tobytes()
        head[584:592] = np.array([rate], dtype="<f8").tobytes()
        body = b"".join(image.tobytes() + bytes(true_size - size) for image in images)
        (HERE / name).write_bytes(bytes(head) + body[:len(body) - cut])

    gray = rng.integers(0, 256, (4, 6, 8)).astype(np.uint8)
    write("camera.seq", gray, 100, 8, 25.0)
    bgr = rng.integers(0, 256, (3, 4, 5, 3)).astype(np.uint8)
    write("camera_bgr.seq", bgr, 200, 24, 12.5, cut=40)
    rgb = bgr[:2, ..., ::-1]
    expected["norpix"] = {
        "gray": {"size": [6, 8, 4], "pixel": {"at": [5, 7, 3], "value": int(gray[3, 5, 7])},
                 "sum": int(gray.astype(np.int64).sum()), "metadata": {"frameRate": 25.0}},
        "bgr": {"size": [4, 5, 3, 2], "pixel": {"at": [3, 4, 0, 1], "value": int(rgb[1, 3, 4, 0])},
                "sum": int(rgb.astype(np.int64).sum()), "metadata": {"frameRate": 12.5}}}


def thorlabs(expected):
    """A ThorImage recording: a TIFF file per frame and channel, ChanA_001_001_001_0001.tif and so on; 2 channels
    of 3 frames, 6 x 5 uint16, written out of order so natural order matters (frame 10 after frame 2), and the
    Experiment.xml ThorImage writes beside them, whose LSM element has the frame rate and pixel size."""
    rng = np.random.default_rng(19)
    stack = rng.integers(0, 4000, (6, 5, 2, 3)).astype(np.uint16)   # height x width x channels x frames
    folder = HERE / "thorlabs"
    folder.mkdir(exist_ok=True)
    for old in folder.glob("*.tif"):
        old.unlink()
    for c, letter in enumerate("AB"):
        for t, number in enumerate((1, 2, 10)):
            tifffile.imwrite(folder / f"Chan{letter}_001_001_001_{number:04d}.tif", stack[:, :, c, t], photometric="minisblack")
    (folder / "Experiment.xml").write_text("\n".join([
        '<?xml version="1.0"?>', "<ThorImageExperiment>", '  <Name name="rec" />',
        '  <LSM name="ResonanceGalvo" pixelX="5" pixelY="6" fieldSize="120" widthUM="4" heightUM="4.8" pixelSizeUM="0.8" '
        'frameRate="29.98" averageMode="0" />',
        '  <ZStage name="ThorZPiezo" steps="1" stepSizeUM="2" />', '  <Streaming enable="1" frames="3" zFastEnable="0" />',
        "</ThorImageExperiment>", ""]), encoding="utf-8")
    expected["thorlabs"] = {"size": [6, 5, 2, 3], "pixel": {"at": [4, 3, 1, 2], "value": int(stack[4, 3, 1, 2])},
                            "sum": int(stack.astype(np.int64).sum()), "metadata": {"frameRate": 29.98, "pixelSize": [0.8, 0.8]}}


def tsm(expected):
    """A TSM file: a FITS-like header (80-character cards, padded to 2880 bytes), 4 int16 frames of 5 rows x 7
    columns, little-endian, columns fastest, then a dark frame; read with the dark frame subtracted, saturating
    (one pixel goes below int16's range)."""
    rng = np.random.default_rng(20)
    frames = rng.integers(-2000, 9000, (4, 5, 7)).astype(np.int16)   # frames x rows x columns
    frames[2, 1, 3] = -32700
    dark = rng.integers(100, 300, (5, 7)).astype(np.int16)
    cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    3",
             "NAXIS1  =                    7", "NAXIS2  =                    5", "NAXIS3  =                    4",
             "EXPOSURE=                 0.01 / seconds per frame", "END"]
    header = "".join(card.ljust(80) for card in cards).ljust(2880).encode("ascii")
    (HERE / "macroscope.tsm").write_bytes(header + frames.astype("<i2").tobytes() + dark.astype("<i2").tobytes())
    out = np.clip(frames.astype(np.int32) - dark, -32768, 32767)
    expected["tsm"] = {"size": [5, 7, 4], "pixel": {"at": [3, 6, 1], "value": int(out[1, 3, 6])},
                       "saturated": {"at": [1, 3, 2], "value": int(out[2, 1, 3])}, "sum": int(out.sum()),
                       "metadata": {"frameRate": round6(1 / 0.01)}}


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
    """A Bruker (Prairie View) T-series: an XML file listing a TIFF file per frame and channel, with the frame period
    and the microns per pixel in its PVStateShard."""
    folder = HERE / "tseries"
    folder.mkdir(exist_ok=True)
    rng = np.random.default_rng(5)
    frames = rng.integers(0, 4000, (HEIGHT, WIDTH, 2, 5)).astype(np.uint16)   # height x width x channels x frames
    lines = ['<?xml version="1.0" encoding="utf-8"?>', '<PVScan version="5.4.64.200" date="1/1/2026" notes="">',
             '  <PVStateShard>', '    <PVStateValue key="framePeriod" value="0.033" />',
             '    <PVStateValue key="micronsPerPixel">', '      <IndexedValue index="XAxis" value="1.25" />',
             '      <IndexedValue index="YAxis" value="1.5" />', '      <IndexedValue index="ZAxis" value="1" />',
             '    </PVStateValue>', '  </PVStateShard>',
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
                           "channel2frame3": frames[:, :, 1, 2].astype(int).tolist(),
                           "metadata": {"frameRate": round6(1 / 0.033), "pixelSize": [1.25, 1.5]}}


def hdf5_stack(expected):
    """An HDF5 stack: dataset data, frames x height x width as h5py shows it (C order)."""
    rng = np.random.default_rng(6)
    stack = rng.normal(100, 10, (HEIGHT, WIDTH, 7)).astype(np.float32)   # height x width x frames
    with h5py.File(HERE / "stack.h5", "w") as f:
        f["data"] = np.moveaxis(stack, 2, 0)
    expected["hdf5"] = {"size": [HEIGHT, WIDTH, 7], "pixel": {"at": [5, 9, 3], "value": float(stack[5, 9, 3])},
                        "frame6row2": [float(v) for v in stack[2, :, 6]], "metadata": {}}


def scanimage(expected):
    """Two ScanImage files: scanimage.tif, 3 frames of 8 x 10 with the frame rate (no volume rate, one plane) and the
    FOV in µm, its corners; and scanimage_planes.tif, 2 volumes of 2 planes of 6 x 8 with the volume rate, the z step
    and the FOV in degrees, times the objective's µm per degree. The metadata is in the Software tag."""
    rng = np.random.default_rng(21)
    frames = rng.integers(0, 4000, (3, 8, 10)).astype(np.uint16)   # pages
    software = "\n".join(["SI.VERSION_MAJOR = 2022", "SI.hChannels.channelSave = 1", "SI.hStackManager.numSlices = 1",
                          "SI.hStackManager.stackZStepSize = 1", "SI.hRoiManager.mroiEnable = false",
                          "SI.hRoiManager.scanFrameRate = 30.0446", "SI.hRoiManager.pixelsPerLine = 10",
                          "SI.hRoiManager.linesPerFrame = 8", "SI.hRoiManager.imagingFovDeg = [-1 -1;1 -1;1 1;-1 1]",
                          "SI.hRoiManager.imagingFovUm = [-200 -150;200 -150;200 150;-200 150]", "SI.objectiveResolution = 15", ""])
    tifffile.imwrite(HERE / "scanimage.tif", frames, photometric="minisblack", software=software, metadata=None)
    volumes = rng.integers(0, 4000, (4, 6, 8)).astype(np.uint16)   # pages: plane after plane, volume after volume
    software = "\n".join(["SI.VERSION_MAJOR = 2022", "SI.hChannels.channelSave = 1", "SI.hStackManager.numSlices = 2",
                          "SI.hStackManager.stackZStepSize = 3", "SI.hRoiManager.scanFrameRate = 25",
                          "SI.hRoiManager.scanVolumeRate = 12.5", "SI.hRoiManager.pixelsPerLine = 8",
                          "SI.hRoiManager.linesPerFrame = 6", "SI.hRoiManager.imagingFovDeg = [-2 -1.5;2 -1.5;2 1.5;-2 1.5]",
                          "SI.objectiveResolution = 20", ""])
    tifffile.imwrite(HERE / "scanimage_planes.tif", volumes, photometric="minisblack", software=software, metadata=None)
    expected["scanimage"] = {"size": [8, 10, 3], "sum": int(frames.astype(np.int64).sum()),
                             "metadata": {"frameRate": 30.0446, "pixelSize": [round6(400 / 10), round6(300 / 8)]}}
    expected["scanimagePlanes"] = {"size": [6, 8, 1, 2, 2], "sum": int(volumes.astype(np.int64).sum()),
                                   "metadata": {"frameRate": 12.5, "pixelSize": [round6(4 * 20 / 8), round6(3 * 20 / 6)], "zStep": 3.0}}


def sciscan(expected):
    """A SciScan z-stack (experiment.type XYTZ): 2 frames of 4 x 3, big-endian uint16, and its .ini with the frame rate
    (a decimal comma), the FOV in m (x.fov negative: its size is what counts) and the spacing of the planes."""
    rng = np.random.default_rng(22)
    stack = rng.integers(0, 4000, (4, 3, 2)).astype(np.uint16)
    folder = HERE / "sciscan"
    folder.mkdir(exist_ok=True)
    stack.transpose(2, 0, 1).astype(">u2").tofile(folder / "zstack.raw")
    (folder / "zstack.ini").write_text("\n".join(["[_]", "x.pixels = 3", "y.pixels = 4", "no.of.channels = 1",
                                                  "no.of.frames.acquired = 2", "file.format = 0", 'save.ch.1 = "TRUE"',
                                                  'experiment.type = "XYTZ"', "z.spacing = 2,5", 'frames.p.sec = "15,5"',
                                                  "x.fov = -3.0E-4", "y.fov = 0.0002", ""]), encoding="latin-1")
    expected["sciscan"] = {"size": [4, 3, 2], "sum": int(stack.astype(np.int64).sum()),
                           "metadata": {"frameRate": 15.5, "pixelSize": [round6(3.0e-4 * 1e6 / 3), round6(0.0002 * 1e6 / 4)], "zStep": 2.5}}


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
    video(expected)
    image_files(expected)
    norpix(expected)
    thorlabs(expected)
    tsm(expected)
    suite2p_rois(expected)
    caiman_rois(expected)
    extract_rois(expected)
    prairie(expected)
    hdf5_stack(expected)
    scanimage(expected)
    sciscan(expected)
    mat73(expected)
    (HERE / "expected.json").write_text(json.dumps(expected, indent=1) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
