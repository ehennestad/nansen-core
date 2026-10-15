"""Viewing without a project: `nansen view` and nansen.view register files and arrays (viewables), and view.frame,
view.signal and view.traces serve those only (dev's imviewer, signalviewer and roimanager from the command line)."""

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


def test_an_array_is_viewed_with_its_rois_read_only():
    viewables = Viewables()
    first = viewables.add_stack(stack(), name="movie", rois=ROIS, frame_rate=10)
    api = Api(viewables=viewables)
    assert call(api, "view.list") == [{"id": first, "kind": "stack", "name": "movie", "path": "", "rois": True}]
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
            # the viewer's tools: projections, binning, export; ROIs read only
            page.select_option(".viewer-mode", "max")
            page.wait_for_selector(".viewer-frame:has-text('6 frames')")
            page.select_option(".viewer-mode", "frame")
            page.select_option(".viewer-bin", "mean:5")
            page.wait_for_selector(".viewer-frame:has-text('(1–5)')")
            assert page.locator(".viewer-dialog .viewer-roi-tools").count() == 0
            assert page.locator(".viewer-dialog .roi-reject").count() == 0
            page.click(".viewer-roi-list li[data-roi='1']")   # its signal, live from the array
            page.wait_for_selector(".viewer-signal-hint:has-text('ROI 1 · live from the stack')")
            page.keyboard.press("r")   # read only: nothing changes
            page.wait_for_selector(".viewer-status:has-text('read only')")
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
