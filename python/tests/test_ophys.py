"""The ophys module's numerics and file adapters, apart from the conformance case that runs them through the API."""

import json
from pathlib import Path

import pytest

np = pytest.importorskip("numpy")

from nansen.adapters import load_object  # noqa: E402
from nansen.errors import NansenError  # noqa: E402

PYTHON = Path(__file__).resolve().parents[2] / "modules" / "ophys" / "python"
ophys = load_object("ophys_methods:round_to", PYTHON).__globals__


def adapter(name):
    return load_object(f"ophys_adapters:{name}", PYTHON)()


def test_round_to_rounds_half_away_from_zero_in_the_scaled_value():
    assert ophys["round_to"](2.5, 0) == 3
    assert ophys["round_to"](0.12345, 4) == 0.1235
    assert ophys["round_to"](float("nan"), 2) is None


def test_shifts_are_found_exactly_on_a_textured_scene():
    rng = np.random.default_rng(3)
    scene = rng.normal(0, 1, (40, 44))
    scene = sum(np.roll(np.roll(scene, a, 0), b, 1) for a in (-1, 0, 1) for b in (-1, 0, 1))
    truth = np.array([[0, 0], [2, -3], [-4, 1], [5, 5], [-1, -2]])
    frames = np.stack([np.roll(np.roll(scene, dy, 0), dx, 1) for dy, dx in truth], axis=2)
    reference = np.conj(np.fft.fft2(scene)) * ophys["_smoothing"](40, 44)
    assert (ophys["estimate_shifts"](frames, reference, 6) == truth).all()
    # a shift beyond maxShift is not found
    assert not (ophys["estimate_shifts"](frames, reference, 4) == truth).all()


def test_apply_shifts_moves_frames_back_and_fills_with_zero():
    stack = np.arange(1, 17, dtype=np.uint16).reshape(4, 4, 1)
    out = ophys["apply_shifts"](stack, np.array([[1, -1]]))
    assert out.dtype == np.uint16
    assert out[:, :, 0].tolist() == [[0, 5, 6, 7], [0, 9, 10, 11], [0, 13, 14, 15], [0, 0, 0, 0]]


def test_components_are_4_connected_and_in_row_major_order():
    mask = np.array([[0, 0, 1, 1],
                     [1, 0, 0, 1],
                     [1, 1, 0, 0],
                     [0, 0, 1, 0]], dtype=bool)
    assert ophys["components"](mask) == [[(0, 2), (0, 3), (1, 3)], [(1, 0), (2, 0), (2, 1)], [(3, 2)]]


def test_dilate_by_square_distance_and_the_neuropil_ring():
    mask = np.zeros((7, 7), dtype=bool)
    mask[3, 3] = True
    assert ophys["dilate"](mask, 2).sum() == 25
    union = mask.copy()
    union[3, 5] = True  # another ROI in the ring
    ring = ophys["neuropil_ring"](mask, union, 1, 1)
    assert ring.sum() == 16 - 1 and not ring[3, 5] and not ring[3, 4]


def test_percentiles_match_numpy_and_the_window_is_centred():
    rng = np.random.default_rng(0)
    values = rng.normal(size=(31, 3))
    for p in (0, 12.5, 20, 50, 100):
        assert np.allclose(ophys["_percentile"](values, p), np.percentile(values, p, axis=0))
    moving = ophys["moving_percentile"](values, 50, 5)
    assert np.allclose(moving[0], np.percentile(values[0:3], 50, axis=0))
    assert np.allclose(moving[10], np.percentile(values[8:13], 50, axis=0))
    assert np.allclose(moving[30], np.percentile(values[28:31], 50, axis=0))
    with_nan = values.copy()
    with_nan[4, 1] = np.nan
    assert np.isnan(ophys["_percentile"](with_nan, 20)[1])


def test_sciscan_raw_round_trips_and_reads_channels(tmp_path):
    raw = adapter("SciScanRaw")
    stack = np.arange(3 * 5 * 4, dtype=np.uint16).reshape(3, 5, 4)
    raw.write(tmp_path / "rec.raw", stack)
    assert "x.pixels = 5" in (tmp_path / "rec.ini").read_text()
    back = raw.read(tmp_path / "rec.raw")
    assert back.dtype == np.uint16 and (back == stack).all()
    # x varies fastest in the file, big-endian
    assert np.fromfile(tmp_path / "rec.raw", dtype=">u2")[:5].tolist() == stack[0, :, 0].tolist()
    two = np.arange(3 * 5 * 2 * 4, dtype=np.float32).reshape(3, 5, 2, 4)
    raw.write(tmp_path / "two.raw", two)
    assert (raw.read(tmp_path / "two.raw") == two).all()
    with pytest.raises(NansenError) as error:
        raw.write(tmp_path / "bad.raw", stack.astype(np.int32))
    assert error.value.code == "invalid-params"


def test_sciscan_counts_frames_from_the_file_and_reads_decimal_commas(tmp_path):
    raw = adapter("SciScanRaw")
    (np.arange(2 * 2 * 3) + 1).astype(">u2").tofile(tmp_path / "rec.raw")
    (tmp_path / "rec.ini").write_text('[_]\nx.pixels = "2"\ny.pixels = 2,0\nfile.format = 0\nno.of.frames.acquired = 9\n')
    assert raw.read(tmp_path / "rec.raw").shape == (2, 2, 3)
    (tmp_path / "rec.ini").unlink()
    with pytest.raises(NansenError) as error:
        raw.read(tmp_path / "rec.raw")
    assert error.value.code == "invalid-data"


def test_tiff_stack_round_trips(tmp_path):
    pytest.importorskip("tifffile")
    tiff = adapter("TiffStack")
    stack = np.arange(3 * 4 * 5, dtype=np.uint16).reshape(3, 4, 5)
    tiff.write(tmp_path / "s.tif", stack)
    back = tiff.read(tmp_path / "s.tif")
    assert back.shape == (3, 4, 5) and (back == stack).all()
    tiff.write(tmp_path / "one.tif", stack[:, :, 0])
    assert tiff.read(tmp_path / "one.tif").shape == (3, 4, 1)


def test_roi_files_written_by_either_language_are_read(tmp_path):
    # MATLAB's jsondecode makes one-pixel lists and single ROIs look different; the file is the same either way
    document = json.loads('{"imageSize": [4, 5], "rois": [{"id": 1, "area": 1, "center": [2, 3], "pixels": [[2, 3]]}]}')
    masks = ophys["roi_masks"](document, 4, 5)
    assert len(masks) == 1 and masks[0][2, 3] and masks[0].sum() == 1
    with pytest.raises(NansenError) as error:
        ophys["roi_masks"](document, 5, 5)
    assert error.value.code == "invalid-data"


def test_suite2p_says_what_is_missing():
    try:
        import suite2p  # noqa: F401
        pytest.skip("suite2p is installed")
    except ImportError:
        pass
    with pytest.raises(NansenError) as error:
        ophys["suite2p"](None, {}, None)
    assert error.value.code == "dependency-missing"
