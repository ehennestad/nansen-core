"""Viewing without a project: `nansen view` and nansen.view register files and arrays (viewables), and view.frame,
view.signal and view.traces serve those only (dev's imviewer, signalviewer and roimanager from the command line);
view.updateRois saves ROIs drawn on them, view.detect finds one around a click and view.run runs a method on them."""

import json

import pytest

np = pytest.importorskip("numpy")

from nansen.api import Api  # noqa: E402
from nansen.catalog import Catalog  # noqa: E402
from nansen.viewables import Viewables, register  # noqa: E402


def call(api, method, **params):
    response = api.handle({"id": 1, "method": method, "params": params})
    return response.get("result", response.get("error"))


def code(api, method, **params):
    response = api.handle({"id": 1, "method": method, "params": params})
    assert "error" in response, response
    return response["error"]["code"]


def stack():
    """24 x 32 pixels, 6 frames: frame t has value t everywhere, but a bright square in frames 2 and 3."""
    data = np.zeros((24, 32, 6), dtype=np.uint16)
    data += np.arange(6, dtype=np.uint16)
    data[4:8, 4:8, 2:4] = 100
    return data


ROIS = {"rois": [{"id": 1, "pixels": [[4, 4], [4, 5], [5, 4], [5, 5]], "classification": "accepted"},
                 {"id": 2, "pixels": [[10, 10]]}]}


def test_nothing_is_viewable_until_registered_and_no_project_is_needed():
    api = Api()
    assert api.project is None
    assert call(api, "view.list") == []
    assert code(api, "view.frame", viewable="v1") == "unknown-viewable"
    assert code(api, "view.traces", viewable="v1") == "unknown-viewable"
    assert code(api, "view.signal", viewable="v1", pixels=[[0, 0]]) == "unknown-viewable"
    assert code(api, "view.frame") == "invalid-params"
    assert code(api, "files.frame", path="anything.tif") == "no-project"   # files are still read only in a project


def test_an_array_is_viewed_with_its_rois():
    viewables = Viewables()
    first = viewables.add_stack(stack(), name="movie", rois=ROIS, frame_rate=10)
    api = Api(viewables=viewables)
    assert call(api, "view.list") == [{"id": first, "kind": "stack", "name": "movie", "path": "", "rois": True, "roiFile": ""}]
    frame = call(api, "view.frame", viewable=first, frame=2, rois=True)
    assert (frame["height"], frame["width"], frame["frames"], frame["frame"]) == (24, 32, 6, 2)
    assert (frame["low"], frame["high"]) == (2, 100)
    assert frame["metadata"] == {"frameRate": 10.0} and frame["name"] == "movie"
    assert frame["adapter"] == "" and frame["adapters"] == []
    assert [(r["id"], r["classification"]) for r in frame["rois"]] == [(1, "accepted"), (2, None)]
    assert "rois" not in call(api, "view.frame", viewable=first)
    assert call(api, "view.frame", viewable=first, projection="max")["high"] == 100
    assert call(api, "view.frame", viewable=first, bin={"size": 2, "method": "max"}, frame=0)["binned"] == [0, 2]
    signal = call(api, "view.signal", viewable=first, pixels=[[4, 4], [5, 5]])
    assert signal["traces"][0]["columns"][0]["values"] == [0, 1, 100, 100, 4, 5] and signal["frameRate"] == 10.0
    assert code(api, "view.traces", viewable=first) == "invalid-params"   # a stack, not signals
    assert code(api, "view.frame", viewable=first, adapter="ophys.tiff_stack") == "invalid-params"   # an array has no file to read


def test_signals_are_plotted_as_data_traces_gives_them():
    viewables = Viewables()
    signals = np.column_stack([np.arange(10.0), -np.arange(10.0)])
    sid = viewables.add_signals(signals, name="dff")
    api = Api(viewables=viewables)
    traces = call(api, "view.traces", viewable=sid, columns=[0, 1], maxPoints=5)
    assert traces["frames"] == 10 and traces["step"] == 2 and traces["frameRate"] is None
    assert traces["traces"] == [{"variable": "dff", "count": 2, "columns": [
        {"column": 0, "values": [0, 2, 4, 6, 8]}, {"column": 1, "values": [0, -2, -4, -6, -8]}]}]
    assert code(api, "view.traces", viewable=sid, columns=[2]) == "invalid-params"
    assert code(api, "view.frame", viewable=sid) == "invalid-params"   # signals, not a stack
    with pytest.raises(Exception) as error:
        viewables.add_signals(np.zeros((2, 2, 2)))
    assert getattr(error.value, "code", None) == "invalid-data"


def test_files_are_read_by_the_stack_adapters_of_the_built_in_modules(tmp_path):
    tifffile = pytest.importorskip("tifffile")
    tifffile.imwrite(tmp_path / "movie.tif", np.moveaxis(stack(), 2, 0))   # TIFF pages are the frames
    np.save(tmp_path / "movie.npy", stack())
    (tmp_path / "rois.json").write_text(json.dumps(ROIS))
    np.save(tmp_path / "dff.npy", np.ones((6, 3)))
    viewables = register(Viewables(), [tmp_path / "movie.tif", str(tmp_path / "movie.npy")], rois=tmp_path / "rois.json",
                         signals=tmp_path / "dff.npy")
    api = Api(viewables=viewables)
    listed = call(api, "view.list")
    assert [(v["id"], v["kind"], v["name"], v["rois"]) for v in listed] == [
        ("v1", "stack", "movie.tif", True), ("v2", "stack", "movie.npy", False), ("v3", "signals", "dff", False)]
    assert listed[0]["path"] == str((tmp_path / "movie.tif").resolve())
    tif = call(api, "view.frame", viewable="v1", frame=3, rois=True)
    assert (tif["height"], tif["width"], tif["frames"], tif["high"]) == (24, 32, 6, 100)
    assert tif["adapters"] == ["ophys.scanimage_tiff", "ophys.thorlabs_tiffs", "ophys.tiff_stack"] and len(tif["rois"]) == 2
    other = call(api, "view.frame", viewable="v1", adapter="ophys.tiff_stack")   # another of the file's candidates
    assert other["adapter"] == "ophys.tiff_stack" and other["frames"] == 6
    assert code(api, "view.frame", viewable="v1", adapter="npy") == "invalid-params"   # not one of its candidates
    npy = call(api, "view.frame", viewable="v2", projection="mean")
    assert (npy["adapter"], npy["frames"]) == ("npy", 6)
    assert call(api, "view.traces", viewable="v3")["traces"][0]["count"] == 3


def test_what_cannot_be_viewed_is_refused_when_registered(tmp_path):
    viewables = Viewables()
    for data, expected in [(tmp_path / "missing.tif", "file-not-found"), (np.zeros(5), "invalid-data"),
                           (np.array(["a", "b"]), "invalid-data")]:
        with pytest.raises(Exception) as error:
            viewables.add_stack(data)
        assert error.value.code == expected
    (tmp_path / "notes.txt").write_text("text")
    with pytest.raises(Exception) as error:
        viewables.add_stack(tmp_path / "notes.txt")
    assert error.value.code == "unsupported-file"
    with pytest.raises(Exception) as error:
        viewables.add_stack(stack(), rois={"rois": "not a list"})
    assert error.value.code == "invalid-data"
    with pytest.raises(Exception) as error:
        register(viewables)
    assert error.value.code == "invalid-params"
    assert len(viewables) == 0


def test_a_mat_file_names_the_signals_variable(tmp_path):
    pytest.importorskip("scipy")
    from scipy.io import savemat

    savemat(tmp_path / "signals.mat", {"dff": np.ones((8, 2)), "spikes": np.zeros((8, 2)), "note": "text"})
    viewables = Viewables()
    with pytest.raises(Exception) as error:
        viewables.add_signals(tmp_path / "signals.mat")   # two numeric arrays: which?
    assert error.value.code == "invalid-params" and "dff" in error.value.message
    sid = viewables.add_signals(tmp_path / "signals.mat", variable="spikes")
    assert viewables.get(sid).name == "signals.spikes"
    assert call(Api(viewables=viewables), "view.traces", viewable=sid)["traces"][0]["count"] == 2


SQUARE = [[4, 4], [4, 5], [5, 4], [5, 5]]


def test_rois_drawn_on_a_file_are_saved_beside_it_and_read_again(tmp_path):
    np.save(tmp_path / "movie.npy", stack())
    api = Api(viewables=register(Viewables(), tmp_path / "movie.npy"))
    beside = tmp_path / "movie_rois.json"
    assert call(api, "view.list")[0]["roiFile"] == str(beside) and not beside.exists()
    assert call(api, "view.frame", viewable="v1", rois=True)["rois"] == []   # none yet
    added = call(api, "view.updateRois", viewable="v1", imageSize=[24, 32], add=[{"pixels": SQUARE}])
    assert added["added"] == [1] and added["file"] == str(beside)
    changed = call(api, "view.updateRois", viewable="v1", classify=[{"id": 1, "classification": "accepted"}], cellType=[{"id": 1, "cellType": "axon"}])
    assert changed["rois"][0]["classification"] == "accepted" and changed["added"] == []
    saved = json.loads(beside.read_text())
    assert saved["imageSize"] == [24, 32] and [r["pixels"] for r in saved["rois"]] == [SQUARE]
    assert saved["rois"][0]["classification"] == "accepted" and saved["rois"][0]["cellType"] == "axon"
    assert call(api, "view.list")[0]["rois"] is True
    # undo (restore), and roimanager's other edits, as rois.update makes them
    restored = call(api, "view.updateRois", viewable="v1", restore=[])
    assert restored["rois"] == [] and json.loads(beside.read_text())["rois"] == []
    call(api, "view.updateRois", viewable="v1", restore=[{"id": 1, "pixels": SQUARE, "classification": "accepted"}])
    moved = call(api, "view.updateRois", viewable="v1", move=[{"id": 1, "rows": 2, "columns": 0}])
    assert moved["rois"][0]["pixels"] == [[6, 4], [6, 5], [7, 4], [7, 5]]
    assert code(api, "view.updateRois", viewable="v1", mirror=True) == "invalid-params"   # aligned with nothing
    assert code(api, "view.updateRois", viewable="v1", remove=[9]) == "invalid-params"
    # viewed again with no ROIs given: the ones saved beside it
    again = Api(viewables=register(Viewables(), tmp_path / "movie.npy"))
    assert [r["pixels"] for r in call(again, "view.frame", viewable="v1", rois=True)["rois"]] == [[[6, 4], [6, 5], [7, 4], [7, 5]]]


def test_rois_given_in_a_file_are_saved_back_to_it_and_an_arrays_kept_in_memory(tmp_path):
    np.save(tmp_path / "movie.npy", stack())
    (tmp_path / "curated.json").write_text(json.dumps(ROIS))
    viewables = Viewables()
    viewables.add_stack(tmp_path / "movie.npy", rois=tmp_path / "curated.json")
    viewables.add_stack(tmp_path / "movie.npy", rois=ROIS, name="document")   # a document: saved beside the stack
    viewables.add_stack(stack(), name="array")
    viewables.add_signals(np.ones((6, 2)), name="dff")
    api = Api(viewables=viewables)
    assert [v["roiFile"] for v in call(api, "view.list")] == [
        str(tmp_path / "curated.json"), str(tmp_path / "movie_rois.json"), "", ""]
    result = call(api, "view.updateRois", viewable="v1", remove=[2])
    assert result["file"] == str(tmp_path / "curated.json") and [r["id"] for r in json.loads((tmp_path / "curated.json").read_text())["rois"]] == [1]
    assert call(api, "view.updateRois", viewable="v2", remove=[1])["file"] == str(tmp_path / "movie_rois.json")
    # an array's ROIs are kept while the app runs; one viewable's ROIs are imported into another's
    imported = api.handle({"id": 1, "method": "view.updateRois", "params": {"viewable": "v3", "import": {"viewable": "v1", "mode": "append"}}})["result"]
    assert imported["file"] == "" and imported["added"] == [1]
    assert [r["pixels"] for r in call(api, "view.frame", viewable="v3", rois=True)["rois"]] == [ROIS["rois"][0]["pixels"]]
    assert sorted(p.name for p in tmp_path.iterdir()) == ["curated.json", "movie.npy", "movie_rois.json"]
    for wrong in ({"variable": "RoiArray"}, {"viewable": "v4"}, "v1"):
        assert api.handle({"id": 1, "method": "view.updateRois", "params": {"viewable": "v3", "import": wrong}})["error"]["code"] == "invalid-params"
    assert code(api, "view.updateRois", viewable="v4", add=[{"pixels": SQUARE}]) == "invalid-params"   # signals


def test_detect_finds_the_cell_around_a_click():
    viewables = Viewables()
    viewables.add_stack(stack())
    viewables.add_signals(np.ones((6, 2)))
    api = Api(viewables=viewables)
    found = call(api, "view.detect", viewable="v1", point=[5, 6], radius=4)
    assert found["pixels"] == [[4, 4], [4, 5], [4, 6], [4, 7], [5, 4], [5, 5], [5, 6], [5, 7], [6, 4], [6, 5], [6, 6], [6, 7],
                               [7, 4], [7, 5], [7, 6], [7, 7]]
    assert code(api, "view.detect", viewable="v1", point=[30, 0]) == "invalid-params"
    assert code(api, "view.detect", viewable="v1", point=5) == "invalid-params"
    assert code(api, "view.detect", viewable="v2", point=[0, 0]) == "invalid-params"   # signals


def moving():
    """32 x 32 x 8 float64: a periodic texture moved circularly by whole pixels, frame by frame."""
    rng = np.random.default_rng(3)
    texture = rng.normal(100, 20, (32, 32))
    shifts = [(0, 0), (1, 0), (0, -2), (2, 1), (-1, 1), (0, 0), (1, 2), (-2, 0)]
    return np.stack([np.roll(texture, (-dy, -dx), axis=(0, 1)) for dy, dx in shifts], axis=2)


def test_a_method_runs_on_a_file_and_what_it_saves_is_written_beside_it_and_viewable(tmp_path):
    np.save(tmp_path / "rec.npy", moving())
    viewables = Viewables()
    viewables.add_stack(tmp_path / "rec.npy", frame_rate=15)
    api = Api(viewables=viewables)
    listed = [m["id"] for m in call(api, "view.methods")]
    assert {"ophys.motion_correction", "ophys.detect_rois", "ophys.extract_signals"} <= set(listed)
    assert "ophys.setup_variables" not in listed and "ophys.compute_dff" not in listed   # a tool; no stack
    run = call(api, "view.run", viewable="v1", methodId="ophys.motion_correction", options={"maxShift": 4, "referenceFrames": 1})
    assert run["result"] == {"frames": 8, "maxShift": 2, "meanShift": 1.3608} and run["log"]
    assert run["outputs"] == [
        {"variable": "TwoPhotonSeries_Corrected", "path": str(tmp_path / "rec_TwoPhotonSeries_Corrected.npy"), "kind": "stack", "viewable": "v2"},
        {"variable": "MotionCorrectionShifts", "path": str(tmp_path / "rec_MotionCorrectionShifts.npy"), "kind": "data", "viewable": ""}]
    aligned = np.load(tmp_path / "rec_TwoPhotonSeries_Corrected.npy")
    assert np.allclose(aligned[4:-4, 4:-4, :], moving()[4:-4, 4:-4, :1])   # each frame back where the first is
    assert np.load(tmp_path / "rec_MotionCorrectionShifts.npy").tolist()[3] == [-2, -1]   # the scene moved by (-2, -1) in frame 3
    second = call(api, "view.list")[1]
    assert second == {"id": "v2", "kind": "stack", "name": "rec.npy · TwoPhotonSeries_Corrected", "rois": False,
                      "path": str(tmp_path / "rec_TwoPhotonSeries_Corrected.npy"), "roiFile": str(tmp_path / "rec_TwoPhotonSeries_Corrected_rois.json")}
    frame = call(api, "view.frame", viewable="v2", projection="std")
    assert frame["frames"] == 8 and frame["adapter"] == "npy" and frame["metadata"] == {"frameRate": 15.0}
    # run again: the aligned stack is read again, under the same id
    again = call(api, "view.run", viewable="v1", methodId="ophys.motion_correction", preset="default", options={"maxShift": 4})
    assert [o["viewable"] for o in again["outputs"]] == ["v2", ""] and len(call(api, "view.list")) == 2
    # ROI detection on the aligned stack: the ROIs found are viewable over it, and signals are extracted with its ROIs
    call(api, "view.updateRois", viewable="v2", imageSize=[32, 32], add=[{"pixels": [[10, 10], [10, 11], [11, 10], [11, 11]]}])
    found = call(api, "view.run", viewable="v2", methodId="ophys.detect_rois", options={"threshold": 0.99, "border": 4})
    assert found["outputs"][0]["kind"] == "rois" and found["outputs"][0]["viewable"] == "v3"
    third = call(api, "view.list")[2]
    assert third["path"] == second["path"] and third["roiFile"] == str(tmp_path / "rec_TwoPhotonSeries_Corrected_RoiArray.json")
    signals = call(api, "view.run", viewable="v2", methodId="ophys.extract_signals")
    saved = {o["variable"]: o for o in signals["outputs"]}
    assert saved["RoiSignals_MeanF"]["kind"] == "data" and np.load(saved["RoiSignals_MeanF"]["path"]).shape[0] == 8
    assert code(api, "view.run", viewable="v1", methodId="ophys.extract_signals") == "data-not-found"   # v1 has no ROIs
    # what cannot run on a viewable
    assert code(api, "view.run", viewable="v1", methodId="ophys.nothing") == "unknown-method"
    assert code(api, "view.run", viewable="v1", methodId="ophys.setup_variables") == "wrong-entity-type"
    assert code(api, "view.run", viewable="v1", methodId="ophys.compute_dff") == "invalid-params"
    assert code(api, "view.run", viewable="v1", methodId="ophys.motion_correction", options={"maxShift": -1}) == "invalid-options"
    assert code(api, "view.run", viewable="v1", methodId="ophys.motion_correction", preset="nothing") == "unknown-preset"
    assert code(api, "view.run", viewable="v1", methodId="ophys.motion_correction", options=[1]) == "invalid-params"


def test_a_method_run_on_an_array_keeps_what_it_saves_in_memory(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    viewables = Viewables()
    viewables.add_stack(moving(), name="movie")
    api = Api(viewables=viewables)
    run = call(api, "view.run", viewable="v1", methodId="ophys.motion_correction", options={"maxShift": 4, "referenceFrames": 1})
    assert [(o["path"], o["kind"], o["viewable"]) for o in run["outputs"]] == [("", "stack", "v2"), ("", "data", "")]
    assert call(api, "view.list")[1]["name"] == "movie · TwoPhotonSeries_Corrected"
    assert call(api, "view.frame", viewable="v2", frame=3)["frames"] == 8
    assert list(tmp_path.iterdir()) == []   # nothing written


def test_the_cli_registers_what_it_is_given_and_serves_it(tmp_path, monkeypatch):
    import nansen.server
    from nansen.cli import main

    served = []
    monkeypatch.setattr(nansen.server, "run_app", lambda api, **options: served.append((api, options)))
    np.save(tmp_path / "movie.npy", stack())
    np.save(tmp_path / "dff.npy", np.ones((6, 2)))
    (tmp_path / "rois.json").write_text(json.dumps(ROIS))
    catalog = str(tmp_path / "catalog.json")
    assert main(["view", str(tmp_path / "movie.npy"), "--rois", str(tmp_path / "rois.json"), "--signals", str(tmp_path / "dff.npy"),
                 "--frame-rate", "30", "--no-browser", "--catalog", catalog]) == 0
    api, options = served[0]
    assert options == {"port": 0, "open_browser": False, "page": "#/view/v1"}
    assert api.project is None and isinstance(api.catalog, Catalog)
    assert [(v["kind"], v["rois"]) for v in call(api, "view.list")] == [("stack", True), ("signals", False)]
    assert call(api, "view.frame", viewable="v1")["metadata"] == {"frameRate": 30.0}
    assert call(api, "view.traces", viewable="v2")["frameRate"] == 30.0

    assert main(["view", str(tmp_path / "missing.tif"), "--no-browser", "--catalog", catalog]) == 1   # nothing served
    assert len(served) == 1
    with pytest.raises(SystemExit) as stop:
        main(["view", "--no-browser"])   # nothing to view
    assert stop.value.code == 2
    with pytest.raises(SystemExit):
        main(["view", str(tmp_path / "movie.npy"), "--frame-rate", "fast"])


def test_nansen_view_serves_in_the_background(tmp_path):
    import urllib.request

    import nansen

    server = nansen.view(stack(), signals=np.ones((6, 2)), catalog=Catalog(tmp_path / "catalog.json"), open_browser=False)
    try:
        assert server.view_url == server.url + "#/view/v1"
        request = urllib.request.Request(server.url + "api", data=json.dumps({"id": 1, "method": "view.list"}).encode(),
                                         headers={"Content-Type": "application/json", "X-Nansen-Token": server.token})
        with urllib.request.urlopen(request, timeout=5) as response:
            assert [v["kind"] for v in json.loads(response.read())["result"]] == ["stack", "signals"]
    finally:
        server.shutdown()
        server.api.close()


def test_the_dashboard_opens_straight_into_the_viewer(tmp_path):
    playwright = pytest.importorskip("playwright.sync_api")
    from nansen.server import serve

    viewables = Viewables()
    viewables.add_stack(stack(), name="movie", rois=ROIS)
    viewables.add_signals(np.column_stack([np.arange(6.0), np.ones(6)]), name="dff")
    api = Api(catalog=Catalog(tmp_path / "catalog.json"), viewables=viewables, start_queue=False)
    server = serve(api)
    try:
        with playwright.sync_playwright() as p:
            try:
                browser = p.chromium.launch()
            except Exception as error:  # no browser installed
                pytest.skip(f"no Chromium: {error}")
            page = browser.new_page(viewport={"width": 1400, "height": 900})
            errors = []
            page.on("pageerror", lambda error: errors.append(str(error)))
            page.on("console", lambda message: errors.append(message.text) if message.type == "error" else None)
            page.goto(server.url)   # no address: the first thing to view
            page.wait_for_selector(".viewer-dialog .viewer-status:has-text('24 × 32 · 2 ROIs')")
            assert page.url.endswith("#/view/v1")
            assert page.locator(".viewer-dialog .dialog-head").inner_text().startswith("movie")
            assert page.locator(".nav a").all_inner_texts()[:2] == ["movie", "dff"]
            # the viewer's tools: projections, binning, export; ROIs edited as roimanager's, kept in memory for an array
            page.select_option(".viewer-mode", "max")
            page.wait_for_selector(".viewer-frame:has-text('6 frames')")
            page.select_option(".viewer-mode", "frame")
            page.select_option(".viewer-bin", "mean:5")
            page.wait_for_selector(".viewer-frame:has-text('(1–5)')")
            assert page.locator(".viewer-dialog .viewer-roi-tools").count() == 1
            assert page.locator(".viewer-dialog .viewer-roi-file").inner_text() == "Kept while the app is open (an array has no folder)"
            page.click(".viewer-roi-list li[data-roi='2']")   # its signal, live from the array
            page.wait_for_selector(".viewer-signal-hint:has-text('ROI 2 · live from the stack')")
            page.keyboard.press("r")   # rejected, in memory
            page.wait_for_selector(".viewer-roi-list li[data-roi='2'] .pill.bad")
            assert viewables.get("v1").rois["rois"][1]["classification"] == "rejected"
            page.click(".viewer-export")
            with page.expect_download() as download:
                page.click(".menu .item:has-text('Image as PNG')")
            assert download.value.suggested_filename == "movie_frame1.png"
            page.locator(".viewer-dialog .dialog-head button[title='Close']").click()
            # the signals, in the trace plot
            page.click(".nav a:has-text('dff')")
            page.wait_for_selector(".traces-dialog .trace-status:has-text('6 frames')")
            assert page.locator(".traces-dialog .dialog-head").inner_text().startswith("Signals · dff")
            page.click(".traces-dialog .trace-roi-list li[data-column='1']", modifiers=["Control"])
            page.wait_for_selector(".traces-dialog .trace-roi-list li.selected >> nth=1")
            page.locator(".traces-dialog .dialog-head button[title='Close']").click()
            assert page.locator(".viewable-list li").count() == 2
            browser.close()
            assert errors == []
    finally:
        server.shutdown()
        api.close()
