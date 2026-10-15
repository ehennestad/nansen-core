"""The ophys module's wrappers run against the real tools, each skipped where its tool is not installed.

CI installs them in the "External tools" jobs (suite2p and DeepInterpolation with pip, CaImAn from conda-forge)
and sets NANSEN_REQUIRE_TOOLS there, so a tool that cannot be imported fails its test instead of skipping it.
Each test runs the wrapper through the API on a synthetic recording with cells at known places.
"""

import importlib
import os
import shutil
from pathlib import Path

import pytest

np = pytest.importorskip("numpy")
tifffile = pytest.importorskip("tifffile")

from nansen.api import Api  # noqa: E402

CASE = Path(__file__).resolve().parents[2] / "conformance" / "api" / "ophys" / "project"
SESSION = {"subject_id": "m1", "session_id": "s2"}
SIZE, FRAMES = 128, 400


def recording(seed=0):
    """128 x 128 x 400 frames: 15 round cells (radius 4) with calcium transients on a textured background."""
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:SIZE, 0:SIZE]
    movie = np.repeat((300 + 40 * rng.normal(size=(SIZE, SIZE)))[:, :, None], FRAMES, axis=2)
    centers = rng.integers(15, SIZE - 15, size=(15, 2))
    for cy, cx in centers:
        spikes = (rng.random(FRAMES) < 0.03) * 800
        movie[(yy - cy) ** 2 + (xx - cx) ** 2 <= 16] += np.convolve(spikes, np.exp(-np.arange(30) / 8))[:FRAMES]
    movie += rng.normal(0, 10, movie.shape)
    return np.clip(movie, 0, 65535).astype(np.uint16), centers


def need(module):
    """The tool's module; the test is skipped without it, unless NANSEN_REQUIRE_TOOLS names it (CI's tools jobs)."""
    try:
        return importlib.import_module(module)
    except ImportError as error:
        if module in os.environ.get("NANSEN_REQUIRE_TOOLS", "").split(","):
            pytest.fail(f"{module} is required here but cannot be imported: {error}")
        pytest.skip(f"{module} is not installed")


@pytest.fixture
def api(tmp_path):
    """The ophys case's project with a larger recording in session s2, read as TwoPhotonSeries_Original."""
    folder = tmp_path / "project"
    shutil.copytree(CASE, folder)
    stack, centers = recording()
    session = folder / "data" / "raw" / "sub-m1" / "ses-s2"
    for part in session.glob("*.tif"):   # the case's recording, in two files: replaced by this one
        part.unlink()
    tifffile.imwrite(session / "rec.tif", np.moveaxis(stack, 2, 0), photometric="minisblack")
    api = Api(start_queue=False)
    api.centers = centers
    api.stack = stack
    for method, params in [("project.open", {"path": str(folder)}), ("project.scan", {}), ("project.sync", {}),
                           ("tools.run", {"methodId": "ophys.setup_variables",
                                          "options": {"rawFilePattern": "tiff", "rawFileAdapter": "ophys.tiff_stack"}})]:
        assert "result" in api.handle({"id": 1, "method": method, "params": params}), method
    yield api
    api.close()


def run(api, method_id, options):
    response = api.handle({"id": 2, "method": "methods.run", "params": {
        "methodId": method_id, "entityType": "session", "keys": [SESSION], "options": options}})
    assert "result" in response, response
    return response["result"]["results"][0]


def load(api, name):
    project = api.project
    return project.load(project.entity("session", SESSION), name, cached=False)



def test_suite2p(api):
    need("suite2p")
    result = run(api, "ophys.suite2p", {"stack": "TwoPhotonSeries_Original", "framesPerSecond": 30, "cellDiameter": 8, "onlyCells": False})
    assert result["frames"] == FRAMES and result["rois"] >= 10
    rois = load(api, "RoiArray")["rois"]
    assert len(rois) == result["rois"]
    # most cells are found: an ROI's centre within 4 px of a true centre
    found = sum(any(np.hypot(*(np.array(r["center"]) - c)) <= 4 for r in rois) for c in api.centers)
    assert found >= 10, found
    assert load(api, "RoiSignals_MeanF").shape == (FRAMES, len(rois))
    assert load(api, "RoiSignals_Deconvolved").shape == (FRAMES, len(rois))


def test_deep_interpolation(api, tmp_path):
    need("deepinterpolation")
    keras = need("tensorflow").keras
    before, after = 3, 3
    model = keras.Sequential([keras.Input(shape=(SIZE, SIZE, before + after)), keras.layers.Conv2D(1, 3, padding="same")])
    model.compile(loss="mean_squared_error")
    path = tmp_path / "model.h5"
    model.save(path)
    result = run(api, "ophys.deep_interpolation", {"stack": "TwoPhotonSeries_Original", "modelPath": str(path),
                                                   "preFrames": before, "postFrames": after})
    assert result["frames"] == FRAMES and 0 < result["predicted"] <= FRAMES - before - after
    out = load(api, "TwoPhotonSeries_Denoised")
    assert out.shape == (SIZE, SIZE, FRAMES) and out.dtype == np.float32
    assert (out[:, :, :before] == api.stack[:, :, :before]).all()          # too close to the start: kept
    assert not np.allclose(out[:, :, before], api.stack[:, :, before])    # predicted by the network


def test_caiman_deconvolution(api):
    need("caiman")
    rng = np.random.default_rng(1)
    spikes = (rng.random((FRAMES, 3)) < 0.03) * 1.0
    calcium = np.zeros_like(spikes)
    for t in range(FRAMES):
        calcium[t] = (0.95 * calcium[t - 1] if t else 0) + spikes[t]
    api.project.save(api.project.entity("session", SESSION), "RoiSignals_Dff", calcium + rng.normal(0, 0.05, calcium.shape))
    result = run(api, "ophys.caiman_deconvolution", {})
    assert result == {"rois": 3, "frames": FRAMES}
    found = load(api, "RoiSignals_Deconvolved")
    assert found.shape == (FRAMES, 3)
    for i in range(3):  # the inferred spikes follow the true ones
        assert np.corrcoef(found[:, i], spikes[:, i])[0, 1] > 0.5


def test_caiman_cnmf(api):
    need("caiman")
    result = run(api, "ophys.cnmf", {"stack": "TwoPhotonSeries_Original", "components": 20, "cellRadius": 4, "frameRate": 30})
    assert result["frames"] == FRAMES and result["rois"] >= 10
    rois = load(api, "RoiArray")["rois"]
    found = sum(any(np.hypot(*(np.array(r["center"]) - c)) <= 4 for r in rois) for c in api.centers)
    assert found >= 10, found   # most cells: an ROI's centre within 4 px of a true centre
    assert load(api, "RoiSignals_MeanF").shape == (FRAMES, len(rois))
    assert load(api, "RoiSignals_Denoised").shape == (FRAMES, len(rois))


def test_export_nwb(api, tmp_path):
    pynwb = need("pynwb")
    run(api, "ophys.motion_correction", {"stack": "TwoPhotonSeries_Original", "referenceFrames": 20})
    run(api, "ophys.detect_rois", {})
    rois = load(api, "RoiArray")["rois"]
    api.handle({"id": 3, "method": "rois.update", "params": {"entityType": "session", "key": SESSION, "variable": "RoiArray",
                                                             "classify": [{"id": rois[0]["id"], "classification": "rejected"}]}})
    run(api, "ophys.extract_signals", {})   # the rejected ROI left out of the signals
    run(api, "ophys.compute_dff", {})
    path = tmp_path / "out.nwb"
    result = run(api, "ophys.export_nwb", {"path": str(path), "frameRate": 30, "sessionDescription": "test"})
    assert result["frames"] == FRAMES and result["rois"] == len(rois)
    assert result["signals"] == ["RoiSignals_MeanF", "RoiSignals_Dff"]
    corrected, signals = load(api, "TwoPhotonSeries_Corrected"), load(api, "RoiSignals_MeanF")
    with pynwb.NWBHDF5IO(str(path), "r") as io:   # as MATLAB's ophys.exportNwb writes it, which OphysNwbTest reads
        nwb = io.read()
        series = nwb.acquisition["TwoPhotonSeries"]
        assert series.data.shape == (FRAMES, SIZE, SIZE) and series.rate == 30
        assert (series.data[7] == corrected[:, :, 7].T).all()   # frames x columns x rows
        table = nwb.processing["ophys"]["ImageSegmentation"]["PlaneSegmentation"]
        assert list(table.id[:]) == [r["id"] for r in rois]
        assert list(table["classification"][:])[:2] == ["rejected", ""]
        assert sorted((int(y), int(x)) for x, y, _ in table["pixel_mask"][1]) == sorted(map(tuple, rois[1]["pixels"]))
        fluorescence = nwb.processing["ophys"]["Fluorescence"]["RoiResponseSeries"]
        assert np.allclose(fluorescence.data[:], signals) and list(fluorescence.rois.data[:]) == list(range(1, len(rois)))
        assert nwb.processing["ophys"]["DfOverF"]["Dff"].data.shape == signals.shape
        assert nwb.subject.subject_id == "m1" and nwb.session_description == "test"
