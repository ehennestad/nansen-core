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


def test_dev_neuropil_grows_around_the_roi_outside_every_roi():
    # two 2 x 2 ROIs that share a pixel; neuropil twice their area, one pixel apart from every ROI (as OphysTest)
    a = np.zeros((9, 9), bool)
    a[2:4, 2:4] = True
    b = np.zeros((9, 9), bool)
    b[3:5, 3:5] = True
    pixels = lambda m: [[int(y), int(x)] for y, x in zip(*np.nonzero(m))]
    first, second = ophys["expansion_neuropil"]([a, b], a | b, 2, 1)
    assert pixels(first) == [[0, 1], [0, 2], [0, 3], [0, 4], [1, 0], [1, 5], [2, 0], [3, 0], [4, 0], [5, 1]]
    assert pixels(second) == [[1, 5], [2, 6], [3, 6], [4, 6], [5, 1], [5, 6], [6, 2], [6, 3], [6, 4], [6, 5]]
    first, _ = ophys["expansion_neuropil"]([a, b], a | b, 2, 0)
    assert len(pixels(first)) == 22 and not (first & (a | b)).any()


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


def test_tiff_stack_is_written_a_chunk_at_a_time(tmp_path):
    pytest.importorskip("tifffile")
    tiff = adapter("TiffStack")
    stack = np.arange(3 * 4 * 5, dtype=np.int16).reshape(3, 4, 5)
    with tiff.create(tmp_path / "c.tif", stack.shape, stack.dtype) as writer:
        writer.write(0, stack[:, :, :2])
        writer.write(2, stack[:, :, 2])
        with pytest.raises(NansenError):
            writer.write(4, stack[:, :, 4:])   # frame 3 was skipped
        writer.write(3, stack[:, :, 3:])
    back = tiff.read(tmp_path / "c.tif")
    assert back.dtype == np.int16 and (back == stack).all()


def test_roi_files_written_by_either_language_are_read(tmp_path):
    # MATLAB's jsondecode makes one-pixel lists and single ROIs look different; the file is the same either way
    document = json.loads('{"imageSize": [4, 5], "rois": [{"id": 1, "area": 1, "center": [2, 3], "pixels": [[2, 3]]}]}')
    masks = ophys["roi_masks"](document, 4, 5)
    assert len(masks) == 1 and masks[0][2, 3] and masks[0].sum() == 1
    with pytest.raises(NansenError) as error:
        ophys["roi_masks"](document, 5, 5)
    assert error.value.code == "invalid-data"


def test_deep_interpolation_says_what_is_missing():
    try:
        import deepinterpolation  # noqa: F401
        pytest.skip("deepinterpolation is installed")
    except ImportError:
        pass
    with pytest.raises(NansenError) as error:
        ophys["deep_interpolation"](None, {}, None)
    assert error.value.code == "dependency-missing"


def test_export_nwb_says_what_is_missing():
    try:
        import pynwb  # noqa: F401
        pytest.skip("pynwb is installed")
    except ImportError:
        pass
    with pytest.raises(NansenError) as error:
        ophys["export_nwb"](None, {}, None)
    assert error.value.code == "dependency-missing"


def test_cnmf_says_what_is_missing():
    try:
        import caiman  # noqa: F401
        pytest.skip("caiman is installed")
    except ImportError:
        pass
    with pytest.raises(NansenError) as error:
        ophys["cnmf"](None, {}, None)
    assert error.value.code == "dependency-missing"


def test_suite2p_says_what_is_missing():
    try:
        import suite2p  # noqa: F401
        pytest.skip("suite2p is installed")
    except ImportError:
        pass
    with pytest.raises(NansenError) as error:
        ophys["suite2p"](None, {}, None)
    assert error.value.code == "dependency-missing"


def test_oasis_reaches_the_optimum_of_the_deconvolution_problem():
    optimize = pytest.importorskip("scipy.optimize")
    rng = np.random.default_rng(5)
    g, frames = 0.9, 50
    K = np.array([[g ** (t - k) if t >= k else 0.0 for k in range(frames)] for t in range(frames)])
    for lam in (0.0, 0.2):
        y = K @ ((rng.random(frames) < 0.1) * rng.random(frames) * 2) + rng.normal(0, 0.2, frames) - 0.2
        calcium, spikes = ophys["oasis_ar1"](y, g, lam)
        assert (spikes >= -1e-12).all() and calcium[0] >= 0
        objective = lambda s: 0.5 * np.sum((K @ s - y) ** 2) + lam * np.sum(s)
        best = optimize.minimize(objective, np.full(frames, 0.1), jac=lambda s: K.T @ (K @ s - y) + lam,
                                 bounds=[(0, None)] * frames, method="L-BFGS-B", options={"ftol": 1e-16, "gtol": 1e-12})
        assert objective(spikes) <= best.fun + 1e-9
        assert np.abs(K @ best.x - calcium).max() < 1e-5


def test_noise_level_and_median():
    assert ophys["_median"](np.array([3.0, 1.0, 2.0])) == 2.0
    assert ophys["_median"](np.array([4.0, 1.0, 2.0, 3.0])) == 2.5
    assert np.isnan(ophys["noise_level"](np.array([1.0, np.nan, 2.0])))


def test_gaussian_smoothing_renormalises_at_the_edges():
    flat = np.full((4, 5, 6), 7.0)
    assert np.allclose(ophys["gaussian_along"](flat, 2, 1.5), 7.0)  # a constant stays constant, edges too
    step = np.zeros((1, 1, 9))
    step[0, 0, 4] = 1.0
    smoothed = ophys["gaussian_along"](step, 2, 1.0)[0, 0]
    assert smoothed[4] == smoothed.max() and np.isclose(smoothed[3], smoothed[5]) and smoothed[0] == 0


def test_scanimage_metadata_numbers():
    numbers = load_object("ophys_adapters:si_numbers", PYTHON)
    text = "SI.hChannels.channelSave = [1;2]\nscanimage.SI.hStackManager.numSlices = 3\nSI.hRoiManager.mroiEnable = true"
    assert numbers(text, "hChannels.channelSave") == [1, 2]
    assert numbers(text, "hStackManager.numSlices") == [3]
    assert numbers(text, "hRoiManager.mroiEnable") == [1]
    assert numbers(text, "hFastZ.enable") == []


def test_scanimage_reads_channels_planes_and_rois():
    folder = Path(__file__).resolve().parents[2] / "conformance" / "api" / "ophys" / "project" / "data" / "raw" / "sub-m1"
    files = [folder / "ses-s4" / "rec_00002.tif", folder / "ses-s4" / "rec_00001.tif"]
    stack = adapter("ScanImageTiff").open(files)   # joined in natural order, whatever order they come in
    data = np.asarray(stack)
    assert data.shape == (16, 64, 2, 2, 3) and not (data == 9999).any()  # no flyback lines
    first = adapter("ScanImageTiff").read(files[1])   # 7 pages: one whole volume of 2 channels x 2 planes
    assert first.shape == (16, 64, 2, 2, 1) and (first == data[..., :1]).all()
    assert (stack[:, :, :, :, 1:2] == data[..., 1:2]).all()   # the volume that begins in one file and ends in the next
    with pytest.raises(NansenError) as error:
        adapter("ScanImageTiff").read(folder / "ses-s2" / "rec_part2.tif")
    assert error.value.code == "invalid-data"


def test_update_rois_classifies_removes_and_adds():
    from nansen.frames import update_rois
    document = {"imageSize": [10, 10], "rois": [{"id": 1, "pixels": [[1, 1]]}, {"id": 5, "pixels": [[2, 2], [2, 3]]}]}
    changed, added = update_rois(document, classify=[{"id": 5, "classification": "rejected"}], remove=[1],
                                 add=[{"pixels": [[3, 3], [3, 4], [11, 0]]}])
    assert added == [6]
    assert [r["id"] for r in changed["rois"]] == [5, 6]
    assert changed["rois"][0]["classification"] == "rejected"
    assert changed["rois"][1] == {"id": 6, "area": 2, "center": [3.0, 3.5], "pixels": [[3, 3], [3, 4]]}
    assert document["rois"][1].get("classification") is None  # the original is left alone
    for bad in ({"classify": [{"id": 2, "classification": "rejected"}]}, {"remove": [7]},
                {"classify": [{"id": 1, "classification": "maybe"}]}, {"add": [{"pixels": [[20, 20]]}]}):
        with pytest.raises(NansenError) as error:
            update_rois(document, **bad)
        assert error.value.code == "invalid-params"


def test_morphology_for_quicky():
    ring = np.zeros((7, 7), dtype=bool)
    ring[1:6, 1:6] = True
    ring[2:5, 2:5] = False
    ring[3, 3] = True
    filled = ophys["fill_holes"](ring)
    assert filled[1:6, 1:6].all() and filled.sum() == 25
    touching = np.zeros((6, 6), dtype=bool)
    touching[0:2, 0:2] = True
    touching[3:5, 3:5] = True
    assert ophys["clear_border"](touching).sum() == 4
    dot = np.zeros((9, 9), dtype=bool)
    dot[4, 4] = True
    grown = ophys["dilate_by"](dot, ophys["disk"](2))
    assert grown.sum() == 13 and (ophys["erode_by"](grown, ophys["disk"](2)) == dot).all()
    edge = np.ones((5, 5), dtype=bool)
    assert ophys["erode_by"](edge, ophys["disk"](1)).all()   # the outside counts as foreground
    assert ophys["_half_up"](2.5) == 3 and ophys["_half_up"](1.5) == 2


def test_binning_and_moving_mean():
    stack = np.arange(2 * 2 * 7, dtype=np.float64).reshape(2, 2, 7)
    binned = ophys["bin_max"](stack, 3)
    assert binned.shape == (2, 2, 2) and (binned[0, 0] == [2, 5]).all()
    assert ophys["bin_max"](stack, 10).shape == (2, 2, 1)
    trace = np.arange(6, dtype=np.float64).reshape(1, 1, 6)
    # window 4: 2 before and 1 after, as MATLAB's movmean(x, 4)
    assert np.allclose(ophys["moving_mean"](trace, 4)[0, 0], [0.5, 1, 1.5, 2.5, 3.5, 4])


def _blob_scene(rng, size, count=700):
    """A function (rows, columns) -> image of many small bright blobs, to draw moved by any amount."""
    blobs = [(rng.uniform(0, size), rng.uniform(0, size), rng.uniform(50, 200), rng.uniform(0.8, 2)) for _ in range(count)]

    def draw(rows, columns):
        value = np.full(rows.shape, 50.0)
        for cy, cx, amplitude, sigma in blobs:
            value += amplitude * np.exp(-((rows - cy) ** 2 + (columns - cx) ** 2) / (2 * sigma ** 2))
        return value
    return draw


def test_subpixel_shifts_are_found_to_a_twentieth_of_a_pixel():
    rng = np.random.default_rng(1)
    rows, columns = np.mgrid[0:64, 0:64].astype(float)
    draw = _blob_scene(rng, 64)
    true = rng.uniform(-3, 3, (10, 2))
    true[0] = 0
    frames = np.stack([draw(rows - dy, columns - dx) for dy, dx in true], axis=2) + rng.normal(0, 0.5, (64, 64, 10))
    reference = ophys["_reference_fft"](draw(rows, columns), True)
    whole = ophys["estimate_shifts"](frames, reference, 8)
    finer = ophys["estimate_shifts"](frames, reference, 8, True, True)
    assert np.abs(whole - true).max() > 0.3
    assert np.abs(finer - true).max() <= 0.06


def test_piecewise_rigid_correction_follows_a_frame_that_bends():
    rng = np.random.default_rng(2)
    rows, columns = np.mgrid[0:64, 0:64].astype(float)
    draw = _blob_scene(rng, 64)
    across = np.clip((columns - 20) / 24, 0, 1)   # the left side moves (2, 0), the right side (-1, 1)
    frame = (draw(rows - (2 - 3 * across), columns - across) + rng.normal(0, 2, (64, 64)))[:, :, None]
    reference = draw(rows, columns)
    rigid = ophys["estimate_shifts"](frame, ophys["_reference_fft"](reference, True), 8, tapered=True)
    edges = ophys["patch_edges"](64, 4)
    patch_ffts = [[ophys["_reference_fft"](reference[a:b, c:d], True) for c, d in zip(edges, edges[1:])] for a, b in zip(edges, edges[1:])]
    patches = ophys["estimate_patch_shifts"](frame, patch_ffts, edges, edges, rigid, 8, 4, True)
    assert np.abs(patches[0, :, :, 0] - [[2], [0]]).max() <= 0.35      # the left column of 16 x 16 patches
    assert np.abs(patches[0, :, :, 3] - [[-1], [1]]).max() <= 0.35     # and the right one
    weights = (ophys["_axis_weights"](edges, 64), ophys["_axis_weights"](edges, 64))
    as_rigid = ophys["align_frames"](frame, rigid.reshape(1, 2, 1, 1).astype(float), weights, False)
    as_patches = ophys["align_frames"](frame, patches, weights, True)
    inner = (slice(6, -6), slice(6, -6))
    error = lambda aligned: np.abs(aligned[:, :, 0] - reference)[inner].mean()
    assert error(as_patches) < 0.5 * error(as_rigid)


def test_a_turned_image_is_turned_back():
    rng = np.random.default_rng(3)
    image = rng.normal(100, 10, (40, 40))
    there_and_back = ophys["rotate_image"](ophys["rotate_image"](image, 5.0), -5.0)
    assert np.allclose(ophys["rotate_image"](image, 0.0), image)
    centre = (slice(12, 28), slice(12, 28))
    assert np.corrcoef(there_and_back[centre].ravel(), image[centre].ravel())[0, 1] > 0.6
    points = np.array([[19.5 + 10, 19.5]])
    assert ophys["rotate_points"](points, 90, 40, 40).tolist() == [[20.0, 30.0]]   # 10 rows below the centre, a quarter turn on


def test_shape_detection_finds_ring_shaped_somata_where_they_are():
    rng = np.random.default_rng(5)
    rows, columns = np.mgrid[0:64, 0:64].astype(float)
    centres = [(20, 20), (22, 42), (42, 24), (44, 44)]
    image = np.full((64, 64), 100.0)
    for cy, cx in centres:
        image += 120 * np.exp(-((np.hypot(rows - cy, columns - cx) - 4.0) ** 2) / 2)
    rois = ophys["shape_rois"](image + rng.normal(0, 3, image.shape), 3, 5)
    assert len(rois) == 4
    for roi, (cy, cx) in zip(rois, centres):
        found = np.array(roi).mean(axis=0)
        assert abs(found[0] - cy) < 0.5 and abs(found[1] - cx) < 0.5
        assert 80 <= len(roi) <= 115   # the ring's outer edge, about 5.5 px out
    assert ophys["shape_rois"](np.full((64, 64), 7.0), 3, 5) == []


def test_a_stack_is_exported_as_video(tmp_path):
    pytest.importorskip("imageio")
    pytest.importorskip("imageio_ffmpeg")
    import shutil
    from nansen.api import Api
    folder = tmp_path / "project"
    shutil.copytree(Path(__file__).resolve().parents[2] / "conformance" / "api" / "ophys" / "project", folder)
    api = Api(start_queue=False)
    call = lambda method, **params: api.handle({"id": 1, "method": method, "params": params})
    try:
        for method, params in [("project.open", {"path": str(folder)}), ("project.scan", {}), ("project.sync", {}),
                               ("tools.run", {"methodId": "ophys.setup_variables", "options": {"rawFilePattern": "tiff", "rawFileAdapter": "ophys.tiff_stack"}})]:
            assert "result" in call(method, **params), method
        key = {"subject_id": "m1", "session_id": "s2"}   # as StackTest does in MATLAB
        path = folder / "exports" / "s2.avi"
        result = call("methods.run", methodId="ophys.export_stack", entityType="session", keys=[key],
                      options={"stack": "TwoPhotonSeries_Original", "format": "video", "path": str(path), "firstFrame": 3, "lastFrame": 12})
        assert result["result"]["results"][0]["frames"] == 10, result
        video = adapter("VideoFile").open([path])
        assert video.shape == (32, 32, 10)
        raw = np.asarray(api.project.load(api.project.entity("session", key), "TwoPhotonSeries_Original"), dtype=float)
        frame = np.asarray(video.frames(3, 4), dtype=float)[:, :, 0]
        assert np.corrcoef(frame.ravel(), raw[:, :, 5].ravel())[0, 1] > 0.95   # JPEG is lossy: the same picture
    finally:
        api.close()
