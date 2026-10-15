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
