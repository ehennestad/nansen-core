"""The dashboard in a real browser, against the demo project. Skipped without Playwright and Chromium."""

import time

import pytest

playwright = pytest.importorskip("playwright.sync_api")

from nansen.api import Api  # noqa: E402
from nansen.catalog import Catalog  # noqa: E402
from nansen.demo import create_demo  # noqa: E402
from nansen.server import serve  # noqa: E402


@pytest.fixture(scope="module")
def app(tmp_path_factory):
    work = tmp_path_factory.mktemp("ui")
    project = create_demo(work / "demo")
    api = Api(catalog=Catalog(work / "catalog.json"), project=project)
    server = serve(api)
    with playwright.sync_playwright() as p:
        try:
            browser = p.chromium.launch()
        except Exception as error:  # no browser installed
            pytest.skip(f"no Chromium: {error}")
        yield {"server": server, "api": api, "project": project, "browser": browser}
        browser.close()
    server.shutdown()
    api.close()


@pytest.fixture
def page(app):
    page = app["browser"].new_page(viewport={"width": 1400, "height": 900})
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.on("console", lambda message: errors.append(message.text) if message.type == "error" else None)
    yield page
    page.close()
    assert errors == []


def rows(page):
    return page.locator(".grid-table tbody tr[data-id]")


def open_sessions(app, page):
    page.goto(app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")


def test_overview_counts_entities(app, page):
    page.goto(app["server"].url + "#/overview")
    page.wait_for_selector(".stat")
    values = page.locator(".stat .value").all_inner_texts()
    assert values == ["4", "14"]
    assert "Raw two-photon data" in page.locator(".content").inner_text()


def test_table_search_sort_and_filter(app, page):
    open_sessions(app, page)
    assert rows(page).count() == 14
    page.fill(".toolbar .search input", "m113")
    page.wait_for_function("document.querySelectorAll('.grid-table tbody tr[data-id]').length === 2")
    page.fill(".toolbar .search input", "")
    page.wait_for_function("document.querySelectorAll('.grid-table tbody tr[data-id]').length === 14")
    page.click(".grid-table thead th:has-text('Date')")
    page.click(".grid-table thead th:has-text('Date')")
    first = rows(page).first.locator("td.key").nth(1).inner_text()
    assert first == "m112-20250611-001"
    page.click(".chip:has-text('New')")
    assert page.locator(".grid-table tbody").inner_text().strip().startswith("No rows match")


def test_inline_edit_persists(app, page):
    open_sessions(app, page)
    row = rows(page).nth(1)
    description = row.locator("td.editable").first
    description.click()
    page.keyboard.press("Control+A")
    page.keyboard.type("edited in the browser")
    page.keyboard.press("Enter")
    page.wait_for_timeout(300)
    key = app["project"].entities("session")[1].key
    assert app["project"].entity("session", key).row["description"] == "edited in the browser"
    row.locator("td input[type=checkbox]").nth(1).click()
    page.wait_for_timeout(300)
    assert app["project"].entity("session", key).row["ignore"] is True


def test_drawer_shows_locations_and_data(app, page):
    open_sessions(app, page)
    rows(page).first.locator("td.key").first.click()
    page.wait_for_selector(".drawer.open")
    text = page.locator(".drawer").inner_text()
    assert "raw" in text and "two_photon_movie" in text and "motion_corrected" in text


def test_write_find_and_delete_a_note(app, page):
    open_sessions(app, page)
    rows(page).first.locator("td.key").first.click()
    page.wait_for_selector(".drawer.open .note-form")
    page.wait_for_selector(".drawer .note-none")
    page.click(".drawer .note-form .chip[data-type='todo']")
    page.fill(".drawer .note-form input", "Check #motion")
    page.fill(".drawer .note-form textarea", "Drift in the last third, see #zdrift")
    page.click(".drawer .note-form button[type='submit']")
    page.wait_for_selector(".drawer li.note[data-type='todo']")
    note = page.locator(".drawer li.note").first
    assert "To do" in note.inner_text() and "Check #motion" in note.inner_text()
    assert note.locator(".tag").all_inner_texts() == ["#motion", "#zdrift"]

    page.goto(app["server"].url + "#/notes")
    page.wait_for_selector(".content li.note")
    assert page.locator(".content li.note").count() == 1
    page.click(".note-filters .chip[data-type='important']")
    assert "No notes match" in page.locator(".content .note-list").inner_text()
    page.click(".note-filters .chip[data-type='all']")
    page.fill(".hero input[type='search']", "#zdrift")
    assert page.locator(".content li.note").count() == 1
    page.fill(".hero input[type='search']", "#nothing")
    assert page.locator(".content li.note").count() == 0
    page.fill(".hero input[type='search']", "")
    page.click(".content li.note .note-entity")
    page.wait_for_selector(".drawer.open li.note")

    page.click(".drawer li.note button[title='Delete this note']")  # the page behind follows the notes event
    page.click(".dialog-foot button:has-text('Delete')")
    page.wait_for_selector(".drawer .note-none")
    page.wait_for_selector(".content .note-list .empty")
    assert app["api"].handle({"id": 1, "method": "notes.list"})["result"] == []


def test_run_method_in_the_queue(app, page):
    open_sessions(app, page)
    rows(page).nth(0).locator("td.sel input").click()
    rows(page).nth(1).locator("td.sel input").click()
    page.click(".selection-bar button:has-text('Run method')")
    page.click(".method-item:has-text('Wait')")
    page.fill(".field:has-text('Seconds') input", "0")
    page.click(".dialog-foot button:has-text('Add to queue')")
    page.wait_for_selector(".task")
    deadline = time.time() + 15
    while time.time() < deadline and "completed" not in page.locator(".task").first.inner_text():
        time.sleep(0.1)
    assert "completed" in page.locator(".task").first.inner_text()
    page.wait_for_selector("#task-log")
    assert "done waiting" in page.locator("#task-log").inner_text()


def test_projects_page_lists_the_catalog(app, page):
    page.goto(app["server"].url + "#/projects")
    page.wait_for_selector(".welcome")
    assert "Two-photon demo" in page.locator(".welcome").inner_text()


def test_queue_a_pipeline(app, page):
    open_sessions(app, page)
    rows(page).nth(2).locator("td.sel input").click()
    page.click(".selection-bar button:has-text('Run method')")
    page.click(".method-item:has-text('Inspect')")
    assert "Count files" in page.locator(".method-detail").inner_text()
    page.click(".dialog-foot button:has-text('Add to queue')")
    page.wait_for_selector(".task .pill:has-text('core.inspect 2/2')")
    deadline = time.time() + 15
    while time.time() < deadline:
        texts = page.locator(".task").all_inner_texts()
        if sum("completed" in t and "core.inspect" in t for t in texts) == 2:
            break
        time.sleep(0.1)
    assert sum("completed" in t and "core.inspect" in t for t in page.locator(".task").all_inner_texts()) == 2


HOST_PAGE = """<!doctype html><html><body style="margin:0">
<iframe src="index.html" style="width:1400px;height:880px;border:0"></iframe>
<script>
  // Plays MATLAB's part: uihtml shows the page in an iframe and calls setup(htmlComponent) once it has loaded.
  window.sent = [];
  window.pageLog = [];
  const frame = document.querySelector("iframe");
  frame.addEventListener("load", () => {
    const listeners = {};
    const component = {
      addEventListener: (name, listener) => (listeners[name] = listeners[name] || []).push(listener),
      sendEventToMATLAB: async (name, data) => {
        if (name === "page") { window.pageLog.push(data); return; }
        window.sent.push(JSON.parse(data).method);
        const response = await fetch("api", { method: "POST", headers: { "Content-Type": "application/json" }, body: data });
        const text = await response.text();
        (listeners.response || []).forEach((listener) => listener({ Data: text }));
      },
    };
    frame.contentWindow.setup(component);
  });
</script></body></html>"""


def test_dashboard_talks_through_the_matlab_bridge(app, page):
    host = app["server"].url + "matlab-host.html"
    page.route(host, lambda route: route.fulfill(status=200, content_type="text/html", body=HOST_PAGE))
    page.goto(host)
    frame = page.frame_locator("iframe")
    frame.locator(".stat").first.wait_for()
    assert frame.locator(".stat .value").all_inner_texts() == ["4", "14"]
    sent = page.evaluate("window.sent")
    assert {"app.info", "project.info", "fragments.list", "methods.list"} <= set(sent)
    assert frame.locator(".sidebar-foot").inner_text().startswith("Connected")
    log = page.evaluate("window.pageLog")
    assert len(log) == 1 and log[0].startswith("hello: ")  # and no errors


@pytest.fixture
def empty_app(app, tmp_path):
    """An app with no project open, on its own server; the browser is shared."""
    api = Api(catalog=Catalog(tmp_path / "catalog.json"), start_queue=False)
    server = serve(api)
    yield {"server": server, "api": api, "folder": tmp_path}
    server.shutdown()
    api.close()


def test_create_the_demo_and_a_project_from_the_projects_page(empty_app, page):
    page.goto(empty_app["server"].url)
    page.wait_for_selector(".welcome h1:has-text('Welcome to NANSEN')")
    page.click(".action-card:has-text('Create the demo')")
    page.fill(".dialog .field:has-text('Folder') input", str(empty_app["folder"] / "demo"))
    page.click(".dialog-foot button:has-text('Create')")
    page.wait_for_selector(".stat")
    assert page.locator(".stat .value").all_inner_texts() == ["4", "14"]

    page.goto(empty_app["server"].url + "#/projects")
    page.click(".action-card:has-text('New project')")
    page.click(".dialog-foot button:has-text('Create')")  # nothing filled in: refused
    assert page.locator(".dialog .form-message").inner_text() == "Folder is required · Name is required"
    page.fill(".dialog .field:has-text('Folder') input", str(empty_app["folder"] / "study"))
    page.fill(".dialog .field:has-text('Name') input", "Study")
    page.fill(".dialog .field:has-text('Dataset config') input", str(empty_app["folder"] / "demo" / "dataset.dsm.json"))
    page.click(".dialog-foot button:has-text('Create')")
    page.wait_for_selector(".project-switch:has-text('Study')")
    assert page.locator(".nav a:has-text('Sessions') .count").inner_text() == "0"  # the demo's entity types, no rows yet
    assert [p["name"] for p in empty_app["api"].handle({"id": 1, "method": "catalog.list"})["result"]] == ["Study", "TwoPhotonDemo"]


def test_a_project_without_a_dataset_offers_to_set_one_up(empty_app, page):
    from nansen.demo import demo_dir

    api = empty_app["api"]
    api.handle({"id": 1, "method": "project.create", "params": {"path": str(empty_app["folder"] / "plain"), "name": "Plain"}})
    page.goto(empty_app["server"].url + "#/overview")
    page.wait_for_selector(".nav-empty:has-text('None yet')")
    page.click("button:has-text('Set up the dataset')")
    page.fill(".dialog .field:has-text('Dataset config') input", str(demo_dir() / "dataset.dsm.json"))
    page.click(".dialog-foot button:has-text('Use this dataset')")
    page.wait_for_selector(".nav a:has-text('Sessions')")
    info = api.handle({"id": 2, "method": "project.info"})["result"]
    assert [(e["name"], e["fragments"]) for e in info["entityTypes"]] == [("subject", ["core.notes"]), ("session", ["core.notes"])]


def test_add_a_column_to_a_table_with_rows(empty_app, page):
    api = empty_app["api"]
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    page.click(".toolbar button:has-text('Columns')")
    page.click(".menu .item:has-text('Add a column')")
    page.fill(".dialog .field:has-text('Column name') input", "depth_um")
    page.select_option(".dialog .field:has-text('Type') select", "number")
    page.fill(".dialog .field:has-text('Default') input", "150")
    page.click(".dialog-foot button:has-text('Add column')")
    page.wait_for_selector(".grid-table th:has-text('depth_um')")
    rows = api.handle({"id": 2, "method": "entities.list", "params": {"entityType": "session"}})["result"]["rows"]
    assert len(rows) == 14 and all(row["values"]["depth_um"] == 150 for row in rows)


def test_change_where_a_data_location_is(empty_app, page):
    api = empty_app["api"]
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    moved = empty_app["folder"] / "moved-raw"
    moved.mkdir()
    page.goto(empty_app["server"].url + "#/data")
    page.click("table.simple tbody tr:first-child button:has-text('Change path')")
    page.fill(".dialog input", str(moved))
    page.click(".dialog-foot button:has-text('OK')")
    page.wait_for_selector(f"table.simple td.mono:has-text('{moved}')")
    roots = api.handle({"id": 2, "method": "project.info"})["result"]["dataset"]["roots"]
    assert roots[0]["path"] == str(moved) and roots[0]["available"] is True


def wait_until(condition, timeout=10.0):
    import time
    end = time.time() + timeout
    while not condition():
        assert time.time() < end, "timed out"
        time.sleep(0.05)


def test_row_and_folder_actions(empty_app, page):
    api = empty_app["api"]
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    opened = []
    api.open_folder = opened.append
    listed = lambda: api.handle({"id": 2, "method": "entities.list", "params": {"entityType": "session"}})["result"]["rows"]
    ignored = sum(1 for r in listed() if r["values"].get("ignore") is True)
    assert ignored > 0
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    rows = lambda: page.locator(".grid-table tbody tr[data-id]")
    assert rows().count() == 14

    page.click(".toolbar button:has-text('Hide ignored')")
    assert rows().count() == 14 - ignored
    page.click(".toolbar button:has-text('Hide ignored')")
    assert rows().count() == 14

    rows().first.locator("td.key").first.click()
    page.wait_for_selector(".drawer.open .path-actions")
    page.locator(".drawer .path-actions button[title='Show in the file browser']").first.click()
    wait_until(lambda: len(opened) == 1)
    assert opened[0].is_dir()
    page.locator(".drawer-head button[title='Close']").click()

    rows().nth(0).locator("td.sel input").check()
    rows().nth(1).locator("td.sel input").check()
    page.click(".selection-bar button:has-text('Remove from table')")
    page.click(".dialog-foot button:has-text('Remove')")
    wait_until(lambda: sum(1 for r in listed() if not r["inTable"]) == 2)  # still in the stores: new rows now


def test_save_and_delete_a_preset(empty_app, page):
    api = empty_app["api"]
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    presets = lambda: [p["name"] for p in api.handle({"id": 2, "method": "presets.list", "params": {"methodId": "core.wait"}})["result"]]
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    page.click(".toolbar button:has-text('Run method')")
    page.click(".method-item:has-text('Wait')")
    page.wait_for_selector(".preset-row")
    assert page.locator(".preset-row button[title='Delete this preset']").count() == 0  # not the default
    page.click(".preset-row button:has-text('Save as')")
    page.fill(".dialog.narrow input", "quick")
    page.click(".dialog.narrow .dialog-foot button:has-text('OK')")
    wait_until(lambda: presets() == ["default", "quick"])
    page.wait_for_selector(".preset-row button[title='Delete this preset']")
    page.click(".preset-row button[title='Delete this preset']")
    page.click(".dialog.narrow .dialog-foot button:has-text('Delete')")
    wait_until(lambda: presets() == ["default"])
    page.wait_for_function("() => !document.querySelector(\".preset-row button[title='Delete this preset']\")")
