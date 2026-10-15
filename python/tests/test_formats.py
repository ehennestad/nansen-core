"""The ophys module's readers of other tools' files, on the files conformance/files/ophys/make_formats.py writes:
each must read as expected.json says, as MATLAB's FormatsTest.m checks for the MATLAB readers."""

import json
from pathlib import Path

import pytest

np = pytest.importorskip("numpy")
pytest.importorskip("tifffile")
pytest.importorskip("scipy")

from nansen.adapters import MatAdapter, load_object  # noqa: E402
from nansen.errors import NansenError  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
FILES = ROOT / "conformance" / "files" / "ophys"
EXPECTED = json.loads((FILES / "expected.json").read_text(encoding="utf-8"))


def adapter(name):
    return load_object(f"ophys_adapters:{name}", ROOT / "modules" / "ophys" / "python")()


@pytest.mark.parametrize("name, file, key", [
    ("NansenRoiArray", "rois_nansen.mat", "nansen"),     # Mask, Circle and Polygon ROIs of dev's roimanager
    ("NansenRoiArray", "rois_group.mat", "roiGroup"),    # dev's RoiGroup of two planes: classified, an IMask, each ROI with its plane
    ("Suite2pRois", "Fall.mat", "suite2p"),               # suite2p's cells, those it left out rejected
    ("CaimanRois", "caiman.hdf5", "caiman"),              # CaImAn's sparse spatial components
    ("ExtractRois", "extract.mat", "extract"),            # EXTRACT's spatial weights
])
def test_roi_files_read_as_the_roi_document(name, file, key):
    if key == "caiman":
        pytest.importorskip("h5py")
    assert adapter(name).read(FILES / file) == EXPECTED[key]


def test_a_prairie_view_t_series_is_read_a_frame_at_a_time():
    stack = adapter("PrairieTSeries").open([FILES / "tseries" / "TSeries-001.xml"])
    expected = EXPECTED["prairie"]
    assert list(stack.shape) == expected["size"]
    y, x, c, t = expected["pixel"]["at"]
    assert stack[y, x, c, t] == expected["pixel"]["value"]
    assert stack[:, :, 1, 2].tolist() == expected["channel2frame3"]
    assert int(np.asarray(stack).astype(np.int64).sum()) == expected["sum"]


def test_an_hdf5_stack_reads_and_writes(tmp_path):
    pytest.importorskip("h5py")
    stack = adapter("Hdf5Stack").open([FILES / "stack.h5"])
    expected = EXPECTED["hdf5"]
    assert list(stack.shape) == expected["size"]
    y, x, t = expected["pixel"]["at"]
    assert float(stack[y, x, t]) == expected["pixel"]["value"]
    assert [float(v) for v in stack[2, :, 6]] == expected["frame6row2"]
    data = np.arange(3 * 4 * 5, dtype=np.uint16).reshape(3, 4, 5)
    adapter("Hdf5Stack").write(tmp_path / "out.h5", data)
    assert (adapter("Hdf5Stack").read(tmp_path / "out.h5") == data).all()


def test_mat_files_of_version_7_3_are_read():
    pytest.importorskip("h5py")
    data = MatAdapter().read(FILES / "v73.mat")
    expected = EXPECTED["mat73"]
    assert data["matrix"].tolist() == expected["matrix"]
    assert data["name"] == expected["name"]
    assert data["flags"].tolist() == expected["flags"]
    assert data["info"]["rate"] == expected["rate"]


def test_other_files_are_refused():
    for name, file in [("Suite2pRois", "extract.mat"), ("ExtractRois", "Fall.mat"), ("NansenRoiArray", "Fall.mat")]:
        with pytest.raises(NansenError) as error:
            adapter(name).read(FILES / file)
        assert error.value.code == "invalid-data"
    with pytest.raises(NansenError):
        adapter("PrairieTSeries").read(FILES / "expected.json")


def test_dev_rois_are_written_as_dev_reads_them(tmp_path):
    document = EXPECTED["roiGroup"]
    adapter("NansenRoiArray").write(tmp_path / "rois.mat", document)
    saved = MatAdapter().read(tmp_path / "rois.mat")
    assert set(saved) >= {"roiArray", "roiClassification", "roiImages", "roiStats"}
    assert [r.shape for r in saved["roiArray"][0]] == ["Mask"] * 3 and list(saved["roiClassification"][0]) == [1, 2, 0]
    assert saved["roiArray"][1].shape == "Mask" and list(saved["PlaneNumber"]) == [1, 2]   # cells of planes x channels
    assert adapter("NansenRoiArray").read(tmp_path / "rois.mat") == document
    one_plane = {"imageSize": document["imageSize"], "rois": [{k: v for k, v in r.items() if k not in ("plane", "channel")}
                                                              for r in document["rois"][:3]]}
    adapter("NansenRoiArray").write(tmp_path / "one.mat", one_plane)   # ROIs without places: one roiArray
    assert [r["shape"] for r in MatAdapter().read(tmp_path / "one.mat")["roiArray"]] == ["Mask"] * 3
    assert adapter("NansenRoiArray").read(tmp_path / "one.mat") == one_plane


def test_a_suite2p_binary_reads_with_the_size_from_ops(tmp_path):
    import pickle
    path = FILES / "suite2p" / "plane0" / "data.bin"
    stack = adapter("Suite2pBinary").open([path])
    expected = EXPECTED["suite2pBinary"]
    assert list(stack.shape) == expected["size"] and stack.dtype == np.int16
    data = np.asarray(stack)
    assert int(data[tuple(expected["pixel"]["at"])]) == expected["pixel"]["value"]
    assert stack.frames(2, 3)[8, :, 0].tolist() == expected["frame2row8"] and int(data.astype(np.int64).sum()) == expected["sum"]
    # ops pickled by other protocols, with large and negative values; nothing is unpickled
    read_int = load_object("ophys_adapters:_pickled_int", ROOT / "modules" / "ophys" / "python")
    for protocol in (2, 3, 4, 5):
        data = pickle.dumps({"Ly": 512, "Lx": 70000, "neg": -3, "huge": 2 ** 40, "name": "x"}, protocol=protocol)
        assert [read_int(data, k, "ops") for k in ("Ly", "Lx", "neg", "huge")] == [512, 70000, -3, 2 ** 40]
    with pytest.raises(NansenError):
        read_int(data, "name", "ops")
    with pytest.raises(NansenError):
        read_int(data, "missing", "ops")
    (tmp_path / "data.bin").write_bytes(b"\0" * 10)
    with pytest.raises(NansenError) as error:
        adapter("Suite2pBinary").open([tmp_path / "data.bin"])
    assert error.value.code == "invalid-data"


def test_videos_read_in_colour_or_gray():
    pytest.importorskip("imageio")
    pytest.importorskip("imageio_ffmpeg")
    for name in ("rgb", "gray"):
        expected = EXPECTED["video"][name]
        stack = adapter("VideoFile").open([FILES / "video" / f"{name}.avi"])
        assert list(stack.shape) == expected["size"] and stack.dtype == np.uint8, name
        data = np.asarray(stack)
        assert int(data[tuple(expected["pixel"]["at"])]) == expected["pixel"]["value"], name
        assert int(data.astype(np.int64).sum()) == expected["sum"], name
        assert (stack.frames(1, 3) == data[..., 1:3]).all(), name   # a chunk reads the same


def test_thorimage_frames_read_as_channels():
    paths = sorted((FILES / "thorlabs").glob("*.tif"), reverse=True)   # any order: natural order inside
    expected = EXPECTED["thorlabs"]
    stack = adapter("ThorLabsTiffs").open(paths)
    assert list(stack.shape) == expected["size"] and stack.dtype == np.uint16
    data = np.asarray(stack)
    assert int(data[tuple(expected["pixel"]["at"])]) == expected["pixel"]["value"]
    assert int(data.astype(np.int64).sum()) == expected["sum"]
    assert (stack.frames(1, 3) == data[..., 1:3]).all()
    one = adapter("ThorLabsTiffs").open([p for p in paths if p.name.startswith("ChanA")])
    assert list(one.shape) == [6, 5, 3] and (np.asarray(one) == data[:, :, 0, :]).all()
    with pytest.raises(NansenError):
        adapter("ThorLabsTiffs").open([FILES / "binary" / "stack.raw"])


def test_tsm_files_read_less_their_dark_frame(tmp_path):
    expected = EXPECTED["tsm"]
    stack = adapter("TsmStack").open([FILES / "macroscope.tsm"])
    assert list(stack.shape) == expected["size"] and stack.dtype == np.int16
    data = np.asarray(stack)
    for name in ("pixel", "saturated"):
        assert int(data[tuple(expected[name]["at"])]) == expected[name]["value"], name
    assert int(data.astype(np.int64).sum()) == expected["sum"]
    assert (stack.frames(1, 3) == data[..., 1:3]).all()
    (tmp_path / "cut.tsm").write_bytes((FILES / "macroscope.tsm").read_bytes()[:3000])
    with pytest.raises(NansenError):
        adapter("TsmStack").open([tmp_path / "cut.tsm"])


def test_a_dev_binary_stack_reads_and_writes(tmp_path):
    stack = adapter("BinaryStack").open([FILES / "binary" / "stack.raw"])
    expected = EXPECTED["devBinary"]
    assert list(stack.shape) == expected["size"] and stack.dtype == np.uint16
    data = np.asarray(stack)
    assert int(data[tuple(expected["pixel"]["at"])]) == expected["pixel"]["value"]
    assert stack.frames(2, 3)[8, :, 0].tolist() == expected["frame2row8"] and int(data.astype(np.int64).sum()) == expected["sum"]
    adapter("BinaryStack").write(tmp_path / "out.raw", data)
    assert (tmp_path / "out.ini").read_text().splitlines() == ["Size = 9  7  5", "Class = uint16"]
    assert (tmp_path / "out.raw").read_bytes() == (FILES / "binary" / "stack.raw").read_bytes()   # as dev wrote it
    with adapter("BinaryStack").create(tmp_path / "made.raw", (9, 7, 5), np.uint16) as writer:
        writer.write(0, data[:, :, :2])
        writer.write(2, data[:, :, 2:])
    assert (tmp_path / "made.raw").read_bytes() == (FILES / "binary" / "stack.raw").read_bytes()
