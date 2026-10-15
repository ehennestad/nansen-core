"""The ophys module's numerics and file adapters, apart from the conformance case that runs them through the API."""

import json
import shutil
import sys
import types
from pathlib import Path

import pytest

np = pytest.importorskip("numpy")

from nansen.adapters import load_object  # noqa: E402
from nansen.errors import NansenError  # noqa: E402
from nansen.frames import neuropil_masks, neuropil_slices  # noqa: E402
from nansen.modules import Module  # noqa: E402

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


def test_the_neuropil_ring_is_at_a_square_distance_outside_every_roi():
    # extraction's neuropil is the core's (nansen.frames.neuropil_masks, as rois.neuropil gives it)
    mask = np.zeros((7, 7), dtype=bool)
    mask[3, 3] = True
    assert neuropil_masks([mask], {"neuropilGap": 0, "neuropilWidth": 2})[0].sum() == 25 - 1
    other = np.zeros((7, 7), dtype=bool)
    other[3, 5] = True  # another ROI in the ring
    ring = neuropil_masks([mask, other], {"neuropilGap": 1, "neuropilWidth": 1}, [0])[0]
    assert ring.sum() == 16 - 1 and not ring[3, 5] and not ring[3, 4]


def test_dev_neuropil_grows_around_the_roi_outside_every_roi():
    # two 2 x 2 ROIs that share a pixel; neuropil twice their area, one pixel apart from every ROI (as OphysTest)
    a = np.zeros((9, 9), bool)
    a[2:4, 2:4] = True
    b = np.zeros((9, 9), bool)
    b[3:5, 3:5] = True
    pixels = lambda m: [[int(y), int(x)] for y, x in zip(*np.nonzero(m))]
    expansion = {"neuropilMethod": "expansion", "neuropilExpansionFactor": 2}
    first, second = neuropil_masks([a, b], dict(expansion, neuropilSeparation=1))
    assert pixels(first) == [[0, 1], [0, 2], [0, 3], [0, 4], [1, 0], [1, 5], [2, 0], [3, 0], [4, 0], [5, 1]]
    assert pixels(second) == [[1, 5], [2, 6], [3, 6], [4, 6], [5, 1], [5, 6], [6, 2], [6, 3], [6, 4], [6, 5]]
    first, = neuropil_masks([a, b], expansion, [0])
    assert len(pixels(first)) == 22 and not (first & (a | b)).any()
    # at most maxNeuropilRadius steps: one, by the four sides
    first, = neuropil_masks([a, b], dict(expansion, maxNeuropilRadius=1), [0])
    assert pixels(first) == [[1, 2], [1, 3], [2, 1], [2, 4], [3, 1], [4, 2]]


def test_the_neuropil_is_split_in_slices_around_its_roi():
    # dev's splitNeuropilMasks (FISSA): the ring 2 px around a pixel, less another ROI's pixel, in quarters by angle
    # (as the conformance case's rois.neuropil, worked out by hand); OphysTest checks MATLAB's on the same
    mask = np.zeros((10, 10), bool)
    mask[4, 4] = True
    other = np.zeros((10, 10), bool)
    other[2, 3] = True
    ring = neuropil_masks([mask, other], {"neuropilGap": 1, "neuropilWidth": 1}, [0])[0]
    parts = neuropil_slices(ring, mask, 4)
    labels = sum((k + 1) * part.astype(int) for k, part in enumerate(parts))
    assert [int(labels[y, x]) for y, x in zip(*np.nonzero(ring))] == [1, 1, 1, 2, 1, 2, 4, 2, 4, 2, 4, 4, 3, 3, 3]
    assert not any(parts[i].any() and (parts[i] & parts[j]).any() for i in range(4) for j in range(i))
    assert np.array_equal(neuropil_slices(ring, mask, 1)[0], ring)
    assert not any(part.any() for part in neuropil_slices(np.zeros((10, 10), bool), mask, 3))


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


def test_suite2p_and_deep_interpolation_have_matlab_wrappers_with_their_addons():
    """dev ran suite2p and DeepInterpolation from MATLAB: both methods have a MATLAB implementation, whose toolbox
    the module declares as a GitHub add-on (matlab/tests/OphysTest runs the wrappers with stubbed toolboxes)."""
    module = Module.read(PYTHON.parent)
    methods = {m.id: m for m in module.methods()}
    for method_id, function in [("ophys.suite2p", "suite2p"), ("ophys.deep_interpolation", "deepInterpolation")]:
        implementations = methods[method_id].document["implementations"]
        assert set(implementations) == {"python", "matlab"} and implementations["matlab"] == f"ophys.{function}"
        assert (module.matlab_root / "+ophys" / f"{function}.m").is_file()
    addons = {addon["id"]: addon for addon in module.document["addons"]}
    assert (addons["suite2p-matlab"]["language"], addons["suite2p-matlab"]["source"]) == ("matlab", {"github": "cortex-lab/Suite2P"})
    assert addons["suite2p-matlab"]["pathOrder"] == "end"
    assert addons["deepinterpolation-matlab"]["source"] == {"github": "MATLAB-Community-Toolboxes-at-INCF/DeepInterpolation-MATLAB"}
    assert addons["deepinterpolation-matlab"]["check"] == "deepinterp.Net"


def test_the_ophys_presets_are_options_of_their_methods():
    """dev's shipped presets (Quicky's Soma, Soma (Virus) and Axons, NoRMCorre's Nonrigid (4x4) and Rigid), and the
    module's own: each names options its method has, with values its schema takes."""
    module = Module.read(PYTHON.parent)
    methods = {m.id: m for m in module.methods()}
    presets = {(doc["method"]["id"], doc["name"]): doc for doc in module.preset_documents()}
    assert {("ophys.quicky", n) for n in ("soma", "soma_virus", "axon")} | {("ophys.normcorre", n) for n in ("nonrigid", "rigid")} <= set(presets)
    for (method_id, name), doc in presets.items():
        method = methods[method_id]
        assert name != "default" and doc["method"]["version"] == method.version, name
        assert set(doc["values"]) <= set(method.document["options"]["properties"]), name
        resolved = method.resolve_options(doc["values"])
        assert all(resolved[k] == v for k, v in doc["values"].items()), name
    quicky = {name: methods["ophys.quicky"].resolve_options(presets[("ophys.quicky", name)]["values"]) for name in ("soma", "soma_virus", "axon")}
    assert quicky["soma"]["useShapeDetection"] and not quicky["soma_virus"]["useShapeDetection"]
    assert (quicky["axon"]["roiDiameter"], quicky["axon"]["binarizationPercentile"], quicky["axon"]["maxRois"]) == (4, 95, 1000)
    assert presets[("ophys.normcorre", "nonrigid")]["values"]["patches"] == 4


def _fake_suite2p(tmp_path, monkeypatch, version):
    """A suite2p module with suite2p's own default settings (1.x) or ops (0.x) that records what it is run with and
    writes the files of one cell, so that the wrapper can be run without suite2p."""
    from nansen.stacks import from_array

    calls = {}
    fake = types.ModuleType("suite2p")

    def run_s2p(**kwargs):
        calls.update(kwargs)
        plane = Path(kwargs["db"]["save_path0"]) / "suite2p" / "plane0"
        plane.mkdir(parents=True)
        np.save(plane / "stat.npy", np.array([{"ypix": np.array([1, 1, 2]), "xpix": np.array([2, 3, 2])}], dtype=object), allow_pickle=True)
        np.save(plane / "iscell.npy", np.array([[1.0, 0.9]]))
        for name in ("F", "Fneu", "spks"):
            np.save(plane / f"{name}.npy", np.ones((1, 6), dtype=np.float32))

    if version == 1:
        fake.default_settings = lambda: {
            "tau": 1.0, "fs": 10.0, "diameter": [12.0, 12.0], "run": {"do_registration": 1},
            "registration": {"nimg_init": 400, "nonrigid": True, "block_size": (128, 128)},
            "detection": {"algorithm": "sparsery", "denoise": False, "block_size": (64, 64), "threshold_scaling": 1.0,
                          "sparsery_settings": {"spatial_scale": 0}, "sourcery_settings": {"max_iterations": 20}},
            "extraction": {"neuropil_coefficient": 0.7, "inner_neuropil_radius": 2, "min_neuropil_pixels": 350}}
        fake.default_db = lambda: {}
    else:
        fake.default_ops = lambda: {"tau": 1.0, "fs": 10.0, "do_registration": True, "nonrigid": True, "sparse_mode": True,
                                    "threshold_scaling": 1.0, "max_iterations": 20, "spatial_scale": 0, "denoise": False,
                                    "neucoeff": 0.7, "inner_neuropil_radius": 2, "min_neuropil_pixels": 350, "nimg_init": 200}
    fake.run_s2p = run_s2p
    monkeypatch.setitem(sys.modules, "suite2p", fake)

    saved = {}
    stack = np.zeros((8, 9, 2, 6), dtype=np.uint16)
    stack[:, :, 1, :] = 7

    class Project:
        def open_stack(self, entity, name):
            return from_array(stack)

        def write_path(self, entity, name):
            return tmp_path / "out" / f"{name}.json"

        def save(self, entity, name, value):
            saved[name] = value

    entity = types.SimpleNamespace(key={"session_id": "s1"})
    context = types.SimpleNamespace(project=Project(), log=lambda *args: None)
    return calls, saved, entity, context


@pytest.mark.parametrize("version", [1, 0])
def test_suite2p_gets_its_options_under_its_own_names(tmp_path, monkeypatch, version):
    tifffile = pytest.importorskip("tifffile")
    calls, saved, entity, context = _fake_suite2p(tmp_path, monkeypatch, version)
    method = {m.id: m for m in Module.read(PYTHON.parent).methods()}["ophys.suite2p"]
    options = method.resolve_options({"stack": "Stack", "tau": 0.7, "registration": False, "nonrigid": False, "sparseMode": False,
                                      "thresholdScaling": 2.5, "maxIterations": 7, "spatialScale": 2, "denoise": True,
                                      "neuropilCoefficient": 0.5, "innerNeuropilRadius": 3, "minNeuropilPixels": 200,
                                      "channel": 2, "framesPerSecond": 15, "cellDiameter": 6})
    result = ophys["suite2p"](entity, options, context)
    assert result == {"rois": 1, "frames": 6}
    written = tifffile.imread(Path(calls["db"]["save_path0"]) / "input.tif")
    assert written.shape == (6, 8, 9) and (written == 7).all()   # the second channel
    if version == 1:
        s = calls["settings"]
        assert (s["tau"], s["fs"], s["diameter"], s["run"]["do_registration"]) == (0.7, 15.0, [6.0, 6.0], 0)
        assert s["registration"]["nonrigid"] is False and s["registration"]["nimg_init"] == 6
        d = s["detection"]
        assert (d["algorithm"], d["threshold_scaling"], d["denoise"]) == ("sourcery", 2.5, True)
        assert (d["sparsery_settings"]["spatial_scale"], d["sourcery_settings"]["max_iterations"]) == (2, 7)
        assert s["extraction"] == {"neuropil_coefficient": 0.5, "inner_neuropil_radius": 3, "min_neuropil_pixels": 200}
    else:
        ops = calls["ops"]
        assert {k: ops[k] for k in ("tau", "fs", "diameter", "do_registration", "nonrigid", "sparse_mode", "threshold_scaling",
                                    "max_iterations", "spatial_scale", "denoise", "neucoeff", "inner_neuropil_radius",
                                    "min_neuropil_pixels", "nimg_init")} == {
            "tau": 0.7, "fs": 15, "diameter": 6, "do_registration": False, "nonrigid": False, "sparse_mode": False,
            "threshold_scaling": 2.5, "max_iterations": 7, "spatial_scale": 2, "denoise": True, "neucoeff": 0.5,
            "inner_neuropil_radius": 3, "min_neuropil_pixels": 200, "nimg_init": 6}
    assert saved["RoiArray"]["rois"][0]["pixels"] == [[1, 2], [1, 3], [2, 2]]
    assert saved["RoiSignals_MeanF"].shape == (6, 1)
    # with the defaults, suite2p's own defaults are what it gets
    calls.clear()
    shutil.rmtree(tmp_path / "out")
    ophys["suite2p"](entity, method.resolve_options({"stack": "Stack"}), context)
    if version == 1:
        s = calls["settings"]
        assert (s["tau"], s["run"]["do_registration"], s["registration"]["nonrigid"], s["detection"]["algorithm"]) == (1.0, 1, True, "sparsery")
        assert s["extraction"] == {"neuropil_coefficient": 0.7, "inner_neuropil_radius": 2, "min_neuropil_pixels": 350}
    else:
        assert (calls["ops"]["max_iterations"], calls["ops"]["neucoeff"], calls["ops"]["sparse_mode"]) == (20, 0.7, True)


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


def test_oasis_for_ar2_keeps_its_pools_and_gives_what_matlab_gives():
    # dev's AR(2) model, g1 = d + r and g2 = -d r (exp2ar); the same values as OphysTest's oasisAr2GivesWhatPythonGives
    y = np.array([0, 1, 0.5, 0.2, 2, 1, 0.4, -0.3])
    calcium, spikes = ophys["oasis_ar2"](y, 0.8, 0.3, 0.1)
    assert np.allclose(calcium, [0, 0.539852105748, 0.593837316322, 0.523656542575, 0.926660819067, 0.893649330756,
                                 0.760615667255, 0.622201394600], atol=1e-11)
    assert np.allclose(spikes, [0, 0.5398521057476, 0, 0, 0.4931595781520, 0, 0, 0], atol=1e-11)
    calcium, spikes = ophys["oasis_ar2"](np.array([0.6, 1, 0.5, 0.2, 2, 1, 0.4, -0.3]), 0.8, 0.8, 0.0)   # rise = decay
    assert np.allclose(spikes, [0.6, 0.0689688672996, 0, 0, 0.1526823386432, 0, 0, 0], atol=1e-11)
    rng = np.random.default_rng(4)
    d, r = np.exp(-1 / (0.55 * 30)), np.exp(-1 / (0.18 * 30))
    for lam in (0.0, 0.5):
        y = np.convolve((rng.random(200) < 0.05) * 2.0, [(d ** (k + 1) - r ** (k + 1)) / (d - r) for k in range(60)])[:200]
        y = y + rng.normal(0, 0.1, 200)
        calcium, spikes = ophys["oasis_ar2"](y, d, r, lam)
        assert (spikes >= -1e-12).all() and calcium[0] >= 0
        rebuilt = np.zeros(200)   # the calcium is the spikes through the AR(2) recursion, the first decaying by d
        for t in range(200):
            rebuilt[t] = spikes[t] + (d * rebuilt[0] if t == 1 else (d + r) * rebuilt[t - 1] - d * r * rebuilt[t - 2] if t > 1 else 0)
        assert np.abs(rebuilt - calcium).max() < 1e-9
        assert np.corrcoef(calcium, y)[0, 1] > 0.9
    try:   # with no penalty, what CaImAn's OASIS class gives (in single precision)
        from caiman.source_extraction.cnmf.oasis import OASIS
    except ImportError:
        return
    reference = OASIS(g=d + r, lam=0.0, s_min=0.0, g2=-d * r)
    reference.fit(y.astype(np.float32))
    assert np.abs(reference.c - ophys["oasis_ar2"](y, d, r, 0.0)[0]).max() < 1e-4


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
    # the volume rate, actualStackZStepSize over stackZStepSize, and the pixel size of the first ROI's scanfield
    assert stack.metadata == {"frameRate": 7.5, "pixelSize": [1.5, 1.5], "zStep": 4.0}
    with pytest.raises(NansenError) as error:
        adapter("ScanImageTiff").read(folder / "ses-s2" / "rec_part2.tif")
    assert error.value.code == "invalid-data"


def test_rois_with_places_are_edited_on_their_plane():
    from nansen.frames import rois_at, update_rois_at
    document = {"imageSize": [10, 10], "rois": [{"id": 1, "pixels": [[1, 1]], "plane": 1, "channel": 1},
                                                {"id": 2, "pixels": [[2, 2]], "plane": 2, "channel": 1},
                                                {"id": 3, "pixels": [[3, 3]], "plane": 2, "channel": 1}]}
    assert [r["id"] for r in rois_at(document, 2, 1)["rois"]] == [2, 3]
    assert rois_at(document, 1, 2)["rois"] == []
    plain = {"imageSize": [10, 10], "rois": [{"id": 1, "pixels": [[1, 1]]}]}
    assert rois_at(plain, 3, 2) is plain   # no places: all of them, on any plane
    changed, added = update_rois_at(document, 2, 1, add=[{"pixels": [[5, 5]]}], classify=[{"id": 1, "classification": "accepted"}])
    assert added == [4] and {r["id"]: r["plane"] for r in changed["rois"]} == {1: 1, 2: 2, 3: 2, 4: 2}
    assert changed["rois"][0]["classification"] == "accepted"
    # undo on plane 2 restores plane 2's ROIs only; plane 1's stay
    restored, _ = update_rois_at(changed, 2, 1, restore=[{"id": 2, "pixels": [[2, 2]]}])
    assert [(r["id"], r["plane"], r["channel"]) for r in restored["rois"]] == [(1, 1, 1), (2, 2, 1)]
    assert restored["rois"][0]["classification"] == "accepted" and restored["rois"][0]["pixels"] == [[1, 1]]


def test_rois_carry_cell_types_links_and_their_identity():
    from nansen.frames import roi_outlines, update_rois
    document = {"imageSize": [10, 10], "rois": [{"id": 1, "pixels": [[1, 1]], "uid": "a-1", "tags": ["bright"]},
                                                {"id": 2, "pixels": [[2, 2]]}, {"id": 3, "pixels": [[3, 3]]}]}
    changed, _ = update_rois(document, cell_type=[{"id": 1, "cellType": "inhibitory"}], link=[[1, 2, 3]])
    assert [r.get("links") for r in changed["rois"]] == [[2, 3], [1], [1]]
    assert roi_outlines(changed)[0]["cellType"] == "inhibitory" and roi_outlines(changed)[0]["links"] == [2, 3]
    gone, _ = update_rois(changed, remove=[3])   # a removed ROI is taken out of the links
    assert [r.get("links") for r in gone["rois"]] == [[2], [1]]
    # the viewer's undo restores outlines (id, pixels, classification): what else the ROIs had stays
    back, _ = update_rois(gone, restore=[{"id": 1, "pixels": [[1, 1]]}, {"id": 2, "pixels": [[2, 2]]}])
    assert back["rois"][0]["uid"] == "a-1" and back["rois"][0]["tags"] == ["bright"] and back["rois"][0]["cellType"] == "inhibitory"
    with pytest.raises(NansenError):
        update_rois(document, link=[[1, 1]])


def test_rois_overlap_as_dev_finds_overlapping_rois():
    from nansen.frames import rois_overlap
    square = [[r, c] for r in range(4) for c in range(4)]   # 16 pixels
    assert rois_overlap(square, square)   # the same ROI (dev skips coinciding centres, meant for a set against itself)
    assert rois_overlap(square, square[:13])   # 13 of the smaller's 13: more than 0.75
    shifted = [[r, c + 1] for r, c in square]   # 12 of 16 shared: exactly 0.75 is not more
    assert not rois_overlap(square, shifted)
    line = [[0, c] for c in range(21)]   # its centre is [0, 10]
    assert not rois_overlap(line, [[0, 0]])   # all of the smaller one inside, but the centres 10 apart
    assert rois_overlap(line, [[0, 1]])
    assert not rois_overlap([], square)


def test_rois_are_imported_replacing_appending_or_appending_those_that_do_not_overlap():
    from nansen.frames import import_rois_at
    document = {"imageSize": [10, 10], "rois": [{"id": 1, "pixels": [[1, 1], [1, 2], [2, 1], [2, 2]], "classification": "accepted",
                                                 "uid": "a", "links": [2]},
                                                {"id": 2, "pixels": [[6, 6]], "cellType": "axon", "links": [1]}]}
    source = {"imageSize": [20, 20], "rois": [
        {"id": 4, "pixels": [[1, 1], [1, 2], [2, 1], [2, 2]], "uid": "a"},   # on ROI 1
        {"id": 5, "pixels": [[8, 8], [8, 9], [12, 12]], "classification": "rejected", "uid": "b", "tags": ["x"], "links": [6, 9]},
        {"id": 6, "pixels": [[4, 4]], "cellType": "inhibitory", "links": [5]},
        {"id": 7, "pixels": [[15, 15]]}]}   # outside the file's image: left out
    appended, added = import_rois_at(document, 1, 1, source, "append")
    assert added == [3, 4, 5] and [r["id"] for r in appended["rois"]] == [1, 2, 3, 4, 5]
    assert appended["rois"][0] == document["rois"][0] and appended["rois"][1]["cellType"] == "axon"   # those it had stay as they were
    assert "uid" not in appended["rois"][2]   # the file has uid a already
    assert appended["rois"][3] == {"id": 4, "area": 2, "center": [8.0, 8.5], "pixels": [[8, 8], [8, 9]], "classification": "rejected",
                                   "uid": "b", "tags": ["x"], "links": [5]}   # links among those imported, to their new ids
    assert appended["rois"][4]["cellType"] == "inhibitory" and appended["rois"][4]["links"] == [4]
    fewer, added = import_rois_at(document, 1, 1, source, "appendNonOverlapping")
    assert added == [3, 4] and [r["pixels"] for r in fewer["rois"][2:]] == [[[8, 8], [8, 9]], [[4, 4]]]
    replaced, added = import_rois_at(document, 1, 1, source, "replace")
    assert added == [3, 4, 5] and [r["id"] for r in replaced["rois"]] == [3, 4, 5] and replaced["rois"][0]["uid"] == "a"
    assert import_rois_at({"rois": []}, 1, 1, source)[0]["imageSize"] == [20, 20]   # a new file takes the source's size
    with pytest.raises(NansenError) as error:
        import_rois_at(document, 1, 1, source, "merge")
    assert error.value.code == "invalid-params"


def test_rois_are_imported_at_their_place():
    from nansen.frames import import_rois_at
    document = {"rois": [{"id": 1, "pixels": [[1, 1]], "plane": 1, "channel": 1}, {"id": 2, "pixels": [[2, 2]], "plane": 2, "channel": 1}]}
    source = {"rois": [{"id": 1, "pixels": [[5, 5]], "plane": 1, "channel": 1}, {"id": 2, "pixels": [[6, 6]], "plane": 2, "channel": 1}]}
    changed, added = import_rois_at(document, 2, 1, source, "replace")   # plane 2's own ROIs replaced by the source's of plane 2
    assert added == [3] and [(r["id"], r["plane"], r["pixels"]) for r in changed["rois"]] == [(1, 1, [[1, 1]]), (3, 2, [[6, 6]])]


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


ALIGNED = {"key": {"session_id": "b"}, "shift": [2, -3], "rotation": 2.5, "patches": 3,
           "rowShifts": [0, 1, 0, -1, 0, 1, 2, 0, -1], "columnShifts": [1, 0, 0, 0, -1, 0, 0, 1, 1]}


def test_points_go_to_an_aligned_entity_and_back():
    from nansen.frames import _displacement, aligned_points, carried_pixels, reference_points
    rng = np.random.default_rng(4)
    points = rng.uniform(-2, 50, (200, 2))
    there = aligned_points(points, ALIGNED, 48, 50)
    assert np.abs(reference_points(there, ALIGNED, 48, 50) - points).max() < 1e-9
    # the displacement field is the motion correction's: the patches' shifts at their centres, bilinear between them
    rows, columns = np.mgrid[0:48, 0:50]
    grid = np.stack([rows.ravel(), columns.ravel()], axis=1).astype(float)
    field = _displacement(grid, ALIGNED, 48, 50)
    weights = (ophys["_axis_weights"](ophys["patch_edges"](48, 3), 48), ophys["_axis_weights"](ophys["patch_edges"](50, 3), 50))
    for axis, name in enumerate(("rowShifts", "columnShifts")):
        assert np.array_equal(field[:, axis].reshape(48, 50), ophys["shift_field"](np.reshape(ALIGNED[name], (3, 3)), *weights))
    # an ROI carried from an entity to itself stays; from the reference (no move at all) it goes where aligned_points puts it
    reference = {"key": {"session_id": "a"}, "shift": [0, 0], "rotation": 0}
    pixels = [[20, 20], [20, 21], [21, 20], [21, 21]]
    assert carried_pixels(pixels, ALIGNED, ALIGNED, 48, 50) == pixels
    expected = sorted({tuple(int(v) for v in p) for p in np.floor(aligned_points(pixels, ALIGNED, 48, 50) + 0.5)})
    assert carried_pixels(pixels, reference, ALIGNED, 48, 50) == [list(p) for p in expected]
    assert carried_pixels([[0, 0]], reference, {"shift": [-5, -5], "rotation": 0}, 48, 50) == []   # outside the image


def test_an_edit_is_mirrored_to_an_aligned_entity():
    from nansen.frames import mirror_rois_at, roi_outlines
    source, target = {"shift": [0, 0], "rotation": 0}, {"shift": [1, 2], "rotation": 0}
    before = roi_outlines({"rois": [{"id": 1, "pixels": [[3, 3]]}, {"id": 2, "pixels": [[5, 5]]}, {"id": 3, "pixels": [[7, 7]]},
                                    {"id": 4, "pixels": [[9, 9]]}]})
    after = roi_outlines({"rois": [{"id": 1, "pixels": [[3, 4]]}, {"id": 2, "pixels": [[5, 5]], "classification": "rejected"},
                                   {"id": 4, "pixels": [[19, 19]]}, {"id": 6, "pixels": [[1, 1], [1, 2]], "classification": "accepted"},
                                   {"id": 7, "pixels": [[2, 2]]}]})
    here = {"imageSize": [20, 20], "rois": [{"id": 1, "pixels": [[4, 5]], "cellType": "axon"}, {"id": 2, "pixels": [[6, 7]]},
                                            {"id": 3, "pixels": [[8, 9]]}, {"id": 4, "pixels": [[10, 11]]}, {"id": 5, "pixels": [[0, 0]]},
                                            {"id": 7, "pixels": [[0, 1]], "plane": 2}]}
    here["rois"][-1]["channel"] = 1
    for roi in here["rois"][:-1]:
        roi.update(plane=1, channel=1)
    document, summary = mirror_rois_at(here, 1, 1, before, after, source, target, [20, 20])
    # 1 moved (its cell type kept), 2 rejected, 3 removed, 4 moved out of the image (removed), 5 left, 6 added with its id,
    # 7 not added: another plane's ROI has the id
    assert summary == {"added": [6], "changed": [1, 2], "removed": [3, 4]}
    rois = {roi["id"]: roi for roi in document["rois"]}
    assert sorted(rois) == [1, 2, 5, 6, 7]
    assert rois[1]["pixels"] == [[4, 6]] and rois[1]["cellType"] == "axon"
    assert rois[2]["classification"] == "rejected" and rois[2]["pixels"] == [[6, 7]]
    assert rois[6] == dict(rois[6], pixels=[[2, 3], [2, 4]], classification="accepted", plane=1, channel=1)
    assert rois[7]["plane"] == 2 and rois[7]["pixels"] == [[0, 1]]


def _motion_api(tmp_path):
    """The ophys-motion conformance project, with its recordings as TwoPhotonSeries_Original."""
    from nansen.api import Api
    folder = tmp_path / "project"
    shutil.copytree(Path(__file__).resolve().parents[2] / "conformance" / "api" / "ophys-motion" / "project", folder)
    api = Api(start_queue=False)
    for method, params in [("project.open", {"path": str(folder)}), ("project.scan", {}), ("project.sync", {}),
                           ("tools.run", {"methodId": "ophys.setup_variables", "options": {"rawFilePattern": "recording", "rawFileAdapter": "npy", "addColumns": False}})]:
        assert "result" in api.handle({"id": 1, "method": method, "params": params}), method
    return api


def _call(api, method, **params):
    response = api.handle({"id": 2, "method": method, "params": params})
    if "error" in response:
        raise NansenError(response["error"]["code"], response["error"]["message"])
    return response["result"]


def test_rois_follow_a_field_of_view_that_bends_only_with_patches(tmp_path):
    import importlib.util
    spec = importlib.util.spec_from_file_location("make_data", Path(__file__).resolve().parents[2] / "conformance" / "api" / "ophys-motion" / "make_data.py")
    truth = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(truth)
    api = _motion_api(tmp_path)
    s8, s9 = {"subject_id": "m1", "session_id": "s8"}, {"subject_id": "m1", "session_id": "s9"}
    reference = api.project.load(api.project.entity("session", s8), "RoiArray")["rois"]
    landed = [truth.half_up(np.stack(truth.nr_there(*np.array(roi["pixels"], float).T), axis=1)) for roi in reference]
    rois = lambda: [roi["pixels"] for roi in api.project.load(api.project.entity("session", s9), "RoiArray", cached=False)["rois"]]
    try:
        align = lambda patches: _call(api, "methods.run", methodId="ophys.align_sessions", entityType="session", keys=[s8, s9],
                                      options={"image": "TwoPhotonSeries_Original", "maxShift": 6, "patches": patches, "maxDeviation": 2})
        align(1)
        assert rois() != landed   # moved as a whole only, some pixels are off by the field
        result = align(3)["results"][0]
        assert rois() == landed
        assert result["shifts"][1]["rowShifts"] == sum(truth.NR_ROWS, []) and result["shifts"][1]["shift"] == list(truth.NR_MOVE)
        alignment = api.project.load(api.project.entity("session", s8), "RoiArray", cached=False)["alignment"]
        assert alignment["reference"] == s8 and [e["variable"] for e in alignment["entities"]] == ["RoiArray", "RoiArray"]
        # an ROI added in s9 with mirror goes to s8; an undo (a restore of what there was) with mirror takes it out again
        before = _call(api, "rois.update", entityType="session", key=s9, variable="RoiArray")["rois"]
        added = _call(api, "rois.update", entityType="session", key=s9, variable="RoiArray", add=[{"pixels": [[40, 40], [40, 41]]}], mirror=True)
        assert added["added"] == [4] and added["mirrored"] == [{"key": s8, "added": [4], "changed": [], "removed": []}]
        undone = _call(api, "rois.update", entityType="session", key=s9, variable="RoiArray", restore=before, mirror=True)
        assert undone["mirrored"] == [{"key": s8, "added": [], "changed": [], "removed": [4]}]
        assert [r["id"] for r in api.project.load(api.project.entity("session", s8), "RoiArray", cached=False)["rois"]] == [1, 2, 3]
        # an id added in one session is free in the other too: s8 has an ROI 4 of its own now
        _call(api, "rois.update", entityType="session", key=s8, variable="RoiArray", add=[{"pixels": [[2, 2]]}])
        again = _call(api, "rois.update", entityType="session", key=s9, variable="RoiArray", add=[{"pixels": [[30, 30]]}], mirror=True)
        assert again["added"] == [5] and again["mirrored"][0]["added"] == [5]
    finally:
        api.close()


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
    # at the image's own resolution (upsampling 1) they are found too, the edge sampled a pixel apart and pushed out 2
    rois = ophys["shape_rois"](image + rng.normal(0, 3, image.shape), 3, 5, 1)
    assert len(rois) == 4 and all(abs(np.array(roi).mean(axis=0) - c).max() < 0.5 for roi, c in zip(rois, centres))


def test_candidates_are_upsampled_as_imresize_does():
    # bicubic (Keys, a = -0.5), the edges mirrored; the same values as OphysTest's upsamplesAsPythonDoes
    up = ophys["upsample_cubic"](np.array([[0.0, 1.0, 0.0], [2.0, 0.5, 1.0]]), 2)
    assert up.shape == (4, 6)
    assert np.allclose(up[0], [-0.30322265625, 0.0899658203125, 0.8763427734375, 0.9019775390625, 0.1668701171875, -0.20068359375], atol=1e-15)
    assert np.allclose(up[3], [2.35009765625, 1.8201904296875, 0.7603759765625, 0.4613037109375, 0.9229736328125, 1.15380859375], atol=1e-15)
    image = np.random.default_rng(1).random((5, 7))
    assert np.array_equal(ophys["upsample_cubic"](image, 1), image)   # once: the image itself
    assert np.allclose(ophys["upsample_cubic"](np.full((4, 4), 3.0), 4), 3.0)


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


def _ophys_api(tmp_path):
    """The ophys conformance project with its TIFF recordings as TwoPhotonSeries_Original (session s2: 32 x 32 x 40)."""
    from nansen.api import Api
    folder = tmp_path / "project"
    shutil.copytree(Path(__file__).resolve().parents[2] / "conformance" / "api" / "ophys" / "project", folder)
    api = Api(start_queue=False)
    for method, params in [("project.open", {"path": str(folder)}), ("project.scan", {}), ("project.sync", {}),
                           ("tools.run", {"methodId": "ophys.setup_variables", "options": {"rawFilePattern": "tiff", "rawFileAdapter": "ophys.tiff_stack"}})]:
        assert "result" in api.handle({"id": 1, "method": method, "params": params}), method
    return api


def _run(api, method, options, preview=None):
    key = {"subject_id": "m1", "session_id": "s2"}
    if preview:
        params = {"methodId": method, "entityType": "session", "key": key, "options": options, "frames": preview}
        response = api.handle({"id": 2, "method": "methods.preview", "params": params})
    else:
        params = {"methodId": method, "entityType": "session", "keys": [key], "options": options}
        response = api.handle({"id": 2, "method": "methods.run", "params": params})
    if "error" in response:
        raise NansenError(response["error"]["code"], response["error"]["message"])
    return response["result"] if preview else response["result"]["results"][0]


def test_a_stack_is_cut_to_a_range_of_frames():
    from nansen.stacks import from_array
    data = np.arange(2 * 3 * 10).reshape(2, 3, 10)
    stack = from_array(data)
    cut = stack.cut(3, 7)
    assert cut.shape == (2, 3, 4) and (np.asarray(cut) == data[:, :, 3:7]).all()
    assert (cut.frames(1, 3) == data[:, :, 4:6]).all() and (cut.cut(1).frames(0, 10) == data[:, :, 4:7]).all()
    for start, stop in ((7, 7), (-1, 3), (9, 11)):
        with pytest.raises(NansenError) as error:
            stack.cut(start, stop)
        assert error.value.code == "invalid-params"


def test_methods_work_on_a_range_of_frames(tmp_path):
    api = _ophys_api(tmp_path)
    round_to = ophys["round_to"]
    try:
        entity = api.project.entity("session", {"subject_id": "m1", "session_id": "s2"})
        raw = np.asarray(api.project.load(entity, "TwoPhotonSeries_Original"), dtype=np.float64)
        none = {"stack": "TwoPhotonSeries_Original", "averageOutput": "", "maximumOutput": "", "frameStatsOutput": ""}
        stats = _run(api, "ophys.image_stats", dict(none, firstFrame=5, lastFrame=24))
        part = raw[:, :, 4:24]
        assert stats["n_frames"] == 20 and stats["mean_intensity"] == round_to(part.mean(), 4) and stats["max_intensity"] == part.max()
        assert _run(api, "ophys.image_stats", dict(none, firstFrame=31))["n_frames"] == 10   # lastFrame 0: to the last
        for wrong in ({"firstFrame": 41}, {"lastFrame": 41}, {"firstFrame": 6, "lastFrame": 5}, {"firstFrame": 0}):
            with pytest.raises(NansenError) as error:
                _run(api, "ophys.image_stats", dict(none, **wrong))
            assert error.value.code == "invalid-options", wrong
        # the outputs have the frames processed
        options = {"stack": "TwoPhotonSeries_Original", "firstFrame": 11, "lastFrame": 30, "referenceFrames": 5}
        assert _run(api, "ophys.motion_correction", options)["frames"] == 20
        assert api.project.load(entity, "TwoPhotonSeries_Corrected", cached=False).shape == (32, 32, 20)
        assert api.project.load(entity, "MotionCorrectionShifts", cached=False).shape == (20, 2)
        api.project.save(entity, "RoiArray", {"imageSize": [32, 32], "rois": [{"id": 1, "pixels": [[10, 10], [10, 11], [11, 10]]}]})
        signals = _run(api, "ophys.extract_signals", {"stack": "TwoPhotonSeries_Original", "firstFrame": 3, "lastFrame": 9})
        assert signals["frames"] == 7 and api.project.load(entity, "RoiSignals_MeanF", cached=False).shape == (7, 1)
        assert signals["meanSignal"] == [round_to(raw[[10, 10, 11], [10, 11, 10], 2:9].mean(), 4)]
        smoothed = _run(api, "ophys.denoise", {"stack": "TwoPhotonSeries_Original", "firstFrame": 2, "lastFrame": 13})
        assert smoothed["frames"] == 12 and api.project.load(entity, "TwoPhotonSeries_Denoised", cached=False).shape == (32, 32, 12)
        assert _run(api, "ophys.downsample", {"stack": "TwoPhotonSeries_Original", "firstFrame": 9, "temporalFactor": 4})["frames"] == 8
        # deinterleaving counts the frames put together: pairs 3..6 are frames 5..12
        assert _run(api, "ophys.deinterleave", {"stack": "TwoPhotonSeries_Original", "channels": 2, "firstFrame": 3, "lastFrame": 6})["frames"] == 4
        both = api.project.load(entity, "TwoPhotonSeries_Deinterleaved", cached=False)
        assert both.shape == (32, 32, 2, 4) and (both[:, :, 1, 0] == raw[:, :, 5]).all()
        # crop and export, which had a range of their own, keep it
        assert _run(api, "ophys.crop", {"stack": "TwoPhotonSeries_Original", "firstFrame": 4, "lastFrame": 8})["frames"] == 5
        assert (api.project.load(entity, "TwoPhotonSeries_Cropped", cached=False) == raw[:, :, 3:8]).all()
        # a preview runs on the first frames of the range, and refuses a range outside the whole recording
        preview = _run(api, "ophys.image_stats", dict(none, firstFrame=21, lastFrame=40), preview=5)["results"][0]
        assert preview["n_frames"] == 5 and preview["mean_intensity"] == round_to(raw[:, :, 20:25].mean(), 4)
        assert _run(api, "ophys.image_stats", dict(none, firstFrame=39), preview=5)["results"][0]["n_frames"] == 2
        with pytest.raises(NansenError) as error:
            _run(api, "ophys.image_stats", dict(none, lastFrame=41), preview=5)
        assert error.value.code == "invalid-options"
        # an image is one frame
        _run(api, "ophys.image_stats", {"stack": "TwoPhotonSeries_Original"})
        assert _run(api, "ophys.image_stats", dict(none, stack="FovAverageProjection", lastFrame=1))["n_frames"] == 1
        with pytest.raises(NansenError):
            _run(api, "ophys.image_stats", dict(none, stack="FovAverageProjection", firstFrame=2))
    finally:
        api.close()


def test_a_preview_on_one_column_gives_what_the_whole_run_gives_for_it(tmp_path):
    api = _ophys_api(tmp_path)
    try:
        entity = api.project.entity("session", {"subject_id": "m1", "session_id": "s2"})
        rng = np.random.default_rng(4)
        traces = np.cumsum(rng.normal(0, 0.1, (300, 4)), axis=0) + rng.random((300, 4)) ** 8 * 5
        api.project.save(entity, "RoiSignals_Dff", traces)
        options = {"frameRate": 30, "tauDecay": 0.4, "sparsity": 0.5}
        whole = _run(api, "ophys.deconvolve", options)
        spikes, calcium = (np.asarray(api.project.load(entity, n, cached=False)) for n in ("RoiSignals_Deconvolved", "RoiSignals_Denoised"))
        params = {"methodId": "ophys.deconvolve", "entityType": "session", "key": {"subject_id": "m1", "session_id": "s2"},
                  "options": options, "column": 2, "maxPoints": 100}
        one = api.handle({"id": 1, "method": "methods.preview", "params": params})["result"]
        assert one["results"][0]["noise"] == [whole["noise"][2]] and one["results"][0]["spikeSum"] == [whole["spikeSum"][2]]
        outputs = {o["name"]: o for o in one["outputs"]}
        assert outputs["RoiSignals_Deconvolved"]["size"] == [300, 1]
        rounded = lambda column: [ophys["round_to"](v, 4) for v in column[::3]]   # every third frame: 300 frames in 100 points
        assert outputs["RoiSignals_Deconvolved"]["trace"] == {"frames": 300, "step": 3, "values": rounded(spikes[:, 2])}
        assert outputs["RoiSignals_Denoised"]["trace"]["values"] == rounded(calcium[:, 2])
        assert "trace" not in _run(api, "ophys.deconvolve", options, preview=5)["outputs"][0]   # only with a column
        params["column"] = 4
        assert api.handle({"id": 1, "method": "methods.preview", "params": params})["error"]["code"] == "invalid-params"
    finally:
        api.close()


def test_every_channel_is_extracted_in_one_run_as_each_would_be_alone(tmp_path):
    # dev's extractSignalsMultiChannel: channel 0 reads each ROI's signal from its own channel, as plane 0 does planes
    api = _ophys_api(tmp_path)
    try:
        entity = api.project.entity("session", {"subject_id": "m1", "session_id": "s2"})
        load = lambda name: api.project.load(entity, name, cached=False)
        raw = np.asarray(api.project.load(entity, "TwoPhotonSeries_Original")).astype(np.float64)
        channels = np.stack([raw, 2 * np.roll(raw, 5, axis=1) + 7], axis=2)   # 32 x 32 x 2 channels x 40
        api.project.save(entity, "Channels", np.stack([channels, np.roll(channels, 3, axis=3)], axis=3))   # x 2 planes
        square = lambda y, x: [[y + dy, x + dx] for dy in range(3) for dx in range(3)]
        places = [(1, 1), (2, 1), (2, 2), (1, 2), (2, 1)]
        api.project.save(entity, "Placed", {"imageSize": [32, 32], "rois": [
            dict({"id": n + 1, "channel": c, "plane": p, "pixels": square(4 + 5 * n, 6 + 4 * n)}, **({"classification": "rejected"} if n == 4 else {}))
            for n, (c, p) in enumerate(places)]})
        options = {"stack": "Channels", "rois": "Placed", "numNeuropilSlices": 3}
        every = _run(api, "ophys.extract_signals", dict(options, channel=0, plane=0, output="Every", neuropilOutput="EveryNeuropil"))
        assert every["ids"] == [1, 2, 3, 4]   # the rejected ROI left out
        assert every["channels"] == [{"channel": 1, "rois": 2}, {"channel": 2, "rois": 2}]
        assert every["planes"] == [{"plane": 1, "rois": 2}, {"plane": 2, "rois": 2}]
        for n, (c, p) in enumerate(places[:4]):
            one = _run(api, "ophys.extract_signals", dict(options, channel=c, plane=p, output="One", neuropilOutput="OneNeuropil"))
            assert one["ids"] == [n + 1]
            assert np.array_equal(load("Every")[:, n], load("One")[:, 0]) and np.array_equal(load("EveryNeuropil")[:, n], load("OneNeuropil")[:, 0])
        # every channel of one plane: that plane's ROIs only
        assert _run(api, "ophys.extract_signals", dict(options, channel=0, plane=2, output="", neuropilOutput=""))["ids"] == [3, 4]
        # the neuropil signal is the mean of its slices' means: ROI 1's, the one ROI of channel 1 in plane 1
        mask = np.zeros((32, 32), bool)
        mask[4:7, 6:9] = True
        neuropil = neuropil_masks([mask], {})[0]
        stack = np.asarray(api.project.load(entity, "Channels"))[:, :, 0, 0, :]
        expected = np.mean([stack[part].mean(axis=0) for part in neuropil_slices(neuropil, mask, 3)], axis=0)
        assert np.allclose(load("EveryNeuropil")[:, 0], expected, rtol=1e-12)
        # ROIs without a channel are of every channel: not one channel's to extract
        api.project.save(entity, "Unplaced", {"imageSize": [32, 32], "rois": [{"id": 1, "plane": 1, "pixels": [[3, 3]]}]})
        with pytest.raises(NansenError) as error:
            _run(api, "ophys.extract_signals", {"stack": "Channels", "channel": 0, "plane": 1, "rois": "Unplaced"})
        assert error.value.code == "invalid-data"
        # of a stack of one channel, channel 0 is its one channel
        assert _run(api, "ophys.extract_signals", {"channel": 0, "stack": "TwoPhotonSeries_Original", "rois": "Unplaced", "output": "",
                                                   "neuropilOutput": ""})["channels"] == [{"channel": 1, "rois": 1}]
    finally:
        api.close()


def test_every_plane_is_processed_in_one_run_as_each_would_be_alone(tmp_path):
    api = _ophys_api(tmp_path)
    try:
        entity = api.project.entity("session", {"subject_id": "m1", "session_id": "s2"})
        load = lambda name: api.project.load(entity, name, cached=False)
        raw = np.asarray(api.project.load(entity, "TwoPhotonSeries_Original"))
        planes = np.stack([raw, np.roll(raw[::-1], 3, axis=2)], axis=2)[:, :, None]   # 32 x 32 x 1 channel x 2 planes x 40
        api.project.save(entity, "Planes", planes)
        for name in ("Aligned", "Aligned1", "Aligned2"):   # the variables written a chunk at a time, as .npy
            api.project.save(entity, name, np.zeros((2, 2)))
        motion = {"stack": "Planes", "referenceFrames": 5, "patches": 2, "subpixel": True, "bidirectionalCorrection": "constant"}
        alone = [_run(api, "ophys.motion_correction", dict(motion, plane=p, output=f"Aligned{p}", shiftsOutput=f"Shifts{p}")) for p in (1, 2)]
        every = _run(api, "ophys.motion_correction", dict(motion, plane=0, output="Aligned", shiftsOutput="Shifts"))
        assert every["planes"] == [dict(plane=p, **{k: v for k, v in alone[p - 1].items() if k != "frames"}) for p in (1, 2)]
        assert every["maxShift"] == max(a["maxShift"] for a in alone)
        aligned = load("Aligned")
        assert aligned.shape == (32, 32, 1, 2, 40)   # as the recording: height x width x channels x planes x frames
        for p in (1, 2):
            assert np.array_equal(aligned[:, :, :, p - 1], load(f"Aligned{p}"))
        shifts = load("Shifts")
        assert shifts.shape == (40, 2, 8)   # the planes' shifts joined along their last axis: frames x 2 x (patches x planes)
        assert np.array_equal(shifts[:, :, 4:], load("Shifts2"))
        # image statistics: of them all and of each, the projections a frame per plane
        pick = lambda s: {k: s[k] for k in ("mean_intensity", "max_intensity")}
        each = [_run(api, "ophys.image_stats", {"stack": "Aligned", "plane": p, "averageOutput": f"Average{p}", "frameStatsOutput": f"Stats{p}",
                                                "maximumOutput": ""}) for p in (1, 2)]
        stats = _run(api, "ophys.image_stats", {"stack": "Aligned", "plane": 0, "averageOutput": "Average", "frameStatsOutput": "Stats",
                                                "maximumOutput": ""})
        assert [pick(s) for s in each] == [pick(s) for s in stats["planes"]]
        average = load("Average")
        assert average.shape == (32, 32, 1, 2, 1) and np.array_equal(average[:, :, 0, 1, 0], load("Average2"))
        assert np.array_equal(load("Stats")[:, 4:], load("Stats2"))
        frame = api.handle({"id": 3, "method": "data.frame", "params": {"entityType": "session", "key": entity.key, "variable": "Average", "plane": 1}})
        assert (frame["result"]["frames"], frame["result"]["planes"]) == (1, 2)
        # ROIs of every plane in one file, with their places; the signals of each from its own plane
        options = {"stack": "Aligned", "threshold": 0.3, "border": 3, "minSize": 4}
        found = []
        for p in (1, 2):
            _run(api, "ophys.detect_rois", dict(options, plane=p))
            found.append(load("RoiArray")["rois"])
        detected = _run(api, "ophys.detect_rois", dict(options, plane=0))
        rois = load("RoiArray")["rois"]
        assert detected["rois"] == len(found[0]) + len(found[1]) and len(found[0]) > 0 and len(found[1]) > 0
        assert [r["id"] for r in rois] == list(range(1, len(rois) + 1))
        assert [(r["plane"], r["channel"], r["pixels"]) for r in rois] == [(p, 1, r["pixels"]) for p in (1, 2) for r in found[p - 1]]
        signals = _run(api, "ophys.extract_signals", {"stack": "Aligned", "plane": 0})
        assert signals["planes"] == [{"plane": p, "rois": len(found[p - 1])} for p in (1, 2)]
        together = load("RoiSignals_MeanF")
        for p in (1, 2):
            one = _run(api, "ophys.extract_signals", {"stack": "Aligned", "plane": p, "output": f"Signals{p}", "neuropilOutput": ""})
            assert one["ids"] == [r["id"] for r in rois if r["plane"] == p]   # the ROIs of the plane, by their place
            columns = [n for n, r in enumerate(rois) if r["plane"] == p]
            assert np.array_equal(together[:, columns], load(f"Signals{p}"), equal_nan=True)
        quick = _run(api, "ophys.quicky", {"stack": "Aligned", "plane": 0, "roiDiameter": 4, "output": "Quick"})
        assert [p["plane"] for p in quick["planes"]] == [1, 2] and quick["rois"] == sum(p["rois"] for p in quick["planes"])
        # ROIs without places are of every plane: not one plane's to extract
        api.project.save(entity, "Unplaced", {"imageSize": [32, 32], "rois": [{"id": 1, "pixels": [[3, 3]]}]})
        with pytest.raises(NansenError) as error:
            _run(api, "ophys.extract_signals", {"stack": "Aligned", "plane": 0, "rois": "Unplaced"})
        assert error.value.code == "invalid-data"
        # of a stack without planes, plane 0 is its one plane
        assert _run(api, "ophys.image_stats", {"stack": "TwoPhotonSeries_Original", "plane": 0, "averageOutput": ""}) == \
            _run(api, "ophys.image_stats", {"stack": "TwoPhotonSeries_Original", "plane": 1, "averageOutput": ""})
        with pytest.raises(NansenError) as error:   # a method that takes one plane at a time
            _run(api, "ophys.denoise", {"stack": "Aligned", "plane": 0})
        assert error.value.code == "invalid-options"
    finally:
        api.close()
