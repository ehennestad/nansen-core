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
    page.console_errors = errors  # a test that makes an error on purpose takes it out
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
    page.wait_for_selector(".grid-table tbody tr[data-id] .notes-cell:has-text('1 note') .note-kind:has-text('1 to do')")   # dev's Notebook column

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
    page.wait_for_selector(".method-detail:has(h3:text-is('Wait')) .preset-row")
    page.fill(".field:has-text('Seconds') input", "0")
    page.click(".dialog-foot button:has-text('Add to queue')")
    # The page opens the new task; other tests' tasks may be listed too, so watch the selected one
    page.wait_for_selector(".task.selected:has-text('completed')", timeout=15000)
    page.wait_for_function("() => (document.getElementById('task-log') || {}).textContent?.includes('done waiting')",
                           timeout=10000)
    page.fill(".task-comment", "slow disk today")   # dev's Comment column, in the history
    page.locator(".task-comment").press("Enter")
    page.wait_for_selector(".task.selected .task-comment-text:has-text('slow disk today')")


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
        const token = frame.contentDocument.querySelector('meta[name="nansen-token"]').content;   // the page this server served
        const response = await fetch("api", { method: "POST", headers: { "Content-Type": "application/json", "X-Nansen-Token": token }, body: data });
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


def test_create_the_two_photon_quickstart_and_view_a_recording(empty_app, page):
    pytest.importorskip("numpy")
    page.goto(empty_app["server"].url)
    page.click(".action-card:has-text('Create the demo')")
    assert page.locator(".dialog select option").all_inner_texts() == ["Sessions demo", "Two-photon quickstart"]
    page.select_option(".dialog select", "two-photon")
    page.fill(".dialog .field:has-text('Folder') input", str(empty_app["folder"] / "tutorial"))
    page.click(".dialog-foot button:has-text('Create')")
    page.wait_for_selector(".stat")
    assert page.locator(".stat .value").all_inner_texts() == ["2", "4"]
    assert empty_app["api"].project.name == "TwoPhotonQuickstart"

    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    page.locator(".grid-table tbody tr[data-id]").first.locator("td.key").first.click()
    page.click(".drawer.open li[data-variable='TwoPhotonSeries_Original'] .view-data")
    page.wait_for_selector(".viewer-dialog .viewer-status:has-text('64 × 64')")
    assert page.locator(".viewer-frame").inner_text() == "1 / 300"
    page.locator(".viewer-slider").fill("149")
    page.wait_for_selector(".viewer-frame:text-is('150 / 300')")


def test_a_project_without_a_dataset_offers_to_set_one_up(empty_app, page):
    from nansen.demo import demo_dir

    api = empty_app["api"]
    api.handle({"id": 1, "method": "project.create", "params": {"path": str(empty_app["folder"] / "plain"), "name": "Plain"}})
    page.goto(empty_app["server"].url + "#/overview")
    page.wait_for_selector(".nav-empty:has-text('None yet')")
    page.click("button:has-text('Use an existing dataset config')")
    page.fill(".dialog .field:has-text('Dataset config') input", str(demo_dir() / "dataset.dsm.json"))
    page.click(".dialog-foot button:has-text('Use this dataset')")
    page.wait_for_selector(".nav a:has-text('Sessions')")
    info = api.handle({"id": 2, "method": "project.info"})["result"]
    assert [(e["name"], e["fragments"]) for e in info["entityTypes"]] == [("subject", ["core.notes", "core.subject"]), ("session", ["core.notes"])]


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
    # The dialog opens on the first method; its preset row must not be taken for Wait's
    page.wait_for_selector(".method-detail:has(h3:text-is('Wait')) .preset-row")
    assert page.locator(".preset-row button[title='Delete this preset']").count() == 0  # not the default
    page.click(".preset-row button:has-text('Save as')")
    page.fill(".dialog.narrow input", "quick")
    page.click(".dialog.narrow .dialog-foot button:has-text('OK')")
    page.wait_for_selector(".preset-row select option[value='quick']", state="attached")  # the dialog shows it first
    wait_until(lambda: presets() == ["default", "quick"])
    page.wait_for_selector(".preset-row button[title='Delete this preset']")
    page.click(".preset-row button[title='Delete this preset']")
    page.click(".dialog.narrow .dialog-foot button:has-text('Delete')")
    wait_until(lambda: presets() == ["default"])
    page.wait_for_function("() => !document.querySelector(\".preset-row button[title='Delete this preset']\")")


def test_a_column_with_choices_reset_and_removed(empty_app, page):
    api = empty_app["api"]
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    listed = lambda: api.handle({"id": 2, "method": "entities.list", "params": {"entityType": "session"}})["result"]
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    page.click(".toolbar button:has-text('Columns')")
    page.click(".menu .item:has-text('Add a column')")
    page.fill(".dialog .field:has-text('Column name') input", "quality")
    page.fill(".dialog .field:has-text('Default') input", "unknown")
    page.fill(".dialog .field:has-text('Choices') input", "good, poor")
    page.click(".dialog-foot button:has-text('Add column')")
    assert "not one of the choices" in page.locator(".dialog .form-message").inner_text()
    page.fill(".dialog .field:has-text('Choices') input", "good, poor, unknown")
    page.click(".dialog-foot button:has-text('Add column')")
    page.wait_for_selector(".grid-table th:has-text('quality')")
    column = next(c for c in listed()["columns"] if c["name"] == "quality")
    assert column["choices"] == ["good", "poor", "unknown"]

    index = [c["name"] for c in listed()["columns"]].index("quality")
    cell = page.locator(".grid-table tbody tr[data-id]").first.locator("td").nth(index + 2)  # after select and status
    wait_until(lambda: cell.inner_text() == "unknown")   # the table reloaded with the new column's default
    def choose(value):
        # a render begun just before the click may still replace the table: click again until the choice is made
        try:
            cell.click()
            page.select_option(".grid-table td.editing select", value, timeout=2000)
            return True
        except Exception:
            return False
    wait_until(lambda: choose("poor"))
    wait_until(lambda: listed()["rows"][0]["values"]["quality"] == "poor")

    page.hover(".grid-table th:has-text('quality')")
    page.click(".grid-table th:has-text('quality') .col-menu")
    page.click(".menu .item:has-text('Reset in every row')")
    page.click(".dialog-foot button:has-text('Reset')")
    wait_until(lambda: all(r["values"]["quality"] == "unknown" for r in listed()["rows"]))

    page.hover(".grid-table th:has-text('quality')")
    page.click(".grid-table th:has-text('quality') .col-menu")
    page.click(".menu .item:has-text('Remove')")
    page.click(".dialog-foot button:has-text('Remove')")
    wait_until(lambda: "quality" not in [c["name"] for c in listed()["columns"]])
    page.wait_for_function("() => ![...document.querySelectorAll('.grid-table th')].some((th) => th.textContent.includes('quality'))")


def test_pipelines_page_assign_and_progress(empty_app, page):
    api = empty_app["api"]
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    call = lambda method, **params: api.handle({"id": 2, "method": method, "params": params})["result"]
    page.goto(empty_app["server"].url + "#/pipelines")
    page.wait_for_selector(".card.pipeline[data-id='core.inspect']")
    page.click(".hero button:has-text('New pipeline')")
    page.fill(".dialog .field:has-text('Id') input", "count_only")
    page.fill(".dialog .field:has-text('Title') input", "Count only")
    page.select_option(".dialog .field:has-text('Entity type') select", "session")
    page.click(".dialog .step-editor button:has-text('Add a step')")
    page.select_option(".dialog .step-editor li:first-child select", "core.file_stats")
    page.click(".dialog-foot button:has-text('Save pipeline')")
    page.wait_for_selector(".card.pipeline[data-id='count_only'] .pill:has-text('project')")
    assert [p["id"] for p in call("pipelines.list", entityType="session")] == ["count_only", "core.inspect"]

    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    rows = page.locator(".grid-table tbody tr[data-id]")
    rows.nth(0).locator("td.sel input").check()
    rows.nth(1).locator("td.sel input").check()
    page.click(".selection-bar button:has-text('Pipeline')")
    page.click(".menu .item:has-text('Inspect')")
    page.wait_for_selector(".grid-table th:has-text('Progress')")
    page.wait_for_selector(".grid-table .progress-text:has-text('0/2')")
    page.click(".selection-bar button:has-text('Pipeline')")
    page.click(".menu .item:has-text('Queue the next steps')")
    page.wait_for_url("**#/tasks")
    for _ in range(4):
        call("tasks.runNext")
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table .progress-text:has-text('2/2')")
    assert page.locator(".grid-table .progress-text:has-text('2/2')").count() == 2
    page.locator(".grid-table tbody tr[data-id]").first.locator("td.key").first.click()
    page.wait_for_selector(".drawer.open .pipeline-card .steps li.done")
    assert page.locator(".drawer .pipeline-card .steps li.done").count() == 2


def test_filters_and_saved_views(empty_app, page):
    api = empty_app["api"]
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    views = lambda: api.handle({"id": 2, "method": "views.list", "params": {"entityType": "session"}})["result"]
    listed = api.handle({"id": 3, "method": "entities.list", "params": {"entityType": "session"}})["result"]["rows"]
    bleaching = sum(1 for r in listed if r["values"].get("description") == "Bleaching after 20 min")
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    rows = lambda: page.locator(".grid-table tbody tr[data-id]")

    page.hover(".grid-table th:has-text('Description')")
    page.click(".grid-table th:has-text('Description') .col-menu")
    page.click(".menu .item:has-text('Filter')")
    page.check(".dialog .filter-options label:has-text('Bleaching after 20 min') input")
    page.click(".dialog-foot button:has-text('Apply')")
    page.wait_for_selector(".filter-bar .filter-chip[data-column='description']")
    wait_until(lambda: rows().count() == bleaching)

    page.click(".toolbar button:has(.view-name)")
    page.click(".menu .item:has-text('Save as a new view')")
    page.fill(".dialog.narrow input", "Bleaching")
    page.click(".dialog.narrow .dialog-foot button:has-text('OK')")
    wait_until(lambda: [v["name"] for v in views()] == ["Bleaching"])
    assert views()[0]["filters"] == [{"column": "description", "op": "in", "values": ["Bleaching after 20 min"]}]

    page.click(".filter-bar .filter-chip button")
    wait_until(lambda: rows().count() == 14)
    page.click(".toolbar button:has(.view-name)")
    page.click(".menu .item:has-text('Bleaching')")
    wait_until(lambda: rows().count() == bleaching)
    page.click(".toolbar button:has(.view-name)")
    page.click(".menu .item:has-text('All rows')")
    wait_until(lambda: rows().count() == 14)

    rows().nth(0).locator("td.sel input").check()
    rows().nth(1).locator("td.sel input").check()
    page.click(".selection-bar button:has-text('View')")
    page.click(".menu .item:has-text('New view with these rows')")
    page.fill(".dialog.narrow input", "Pair")
    page.click(".dialog.narrow .dialog-foot button:has-text('OK')")
    wait_until(lambda: any(v["name"] == "Pair" and len(v.get("keys", [])) == 2 for v in views()))
    page.wait_for_function("() => document.querySelectorAll('.grid-table tbody tr[data-id]').length === 2")
    page.reload()  # the view shown last is shown again
    page.wait_for_selector(".grid-table tbody td.key")
    page.wait_for_function("() => document.querySelectorAll('.grid-table tbody tr[data-id]').length === 2")
    # dev's default metatable: the view a table opens with, here or on another computer (nothing remembered yet)
    page.click(".toolbar button:has(.view-name)")
    page.click(".menu .item:has-text('Open the table with Pair')")
    wait_until(lambda: [v["name"] for v in views() if v.get("default")] == ["Pair"])
    page.evaluate("() => localStorage.clear()")
    page.reload()
    page.wait_for_function("() => document.querySelectorAll('.grid-table tbody tr[data-id]').length === 2")
    assert page.locator(".toolbar .view-name").inner_text() == "Pair"


def test_add_edit_and_delete_a_data_variable(empty_app, page):
    api = empty_app["api"]
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    names = lambda: [v["name"] for v in api.handle({"id": 2, "method": "dataVariables.list"})["result"]]
    assert "config" not in names()
    project = api.project
    project.data_cache.get_or_load("x", 1, lambda: b"12345678")
    page.goto(empty_app["server"].url + "#/data")
    page.wait_for_selector(".cache-info:has-text('In memory: 1 file, 8 B')")   # the data cache, emptied from here
    page.click(".data-variables .clear-cache")
    page.wait_for_selector(".cache-info:has-text('In memory: 0 files')")
    assert project.data_cache.stats()["entries"] == 0
    page.click(".data-variables .add-variable")
    page.wait_for_selector(".dialog .variable-location option", state="attached")
    page.click(".dialog-foot button:has-text('Add data variable')")  # no name, no file: refused
    assert "Give a file pattern or a file name" in page.locator(".dialog .form-message").inner_text()
    page.fill(".dialog .variable-name", "config")
    page.select_option(".dialog .variable-entity", "session")
    page.wait_for_selector(".dialog .variable-pattern option[value='two_photon_movie']", state="attached")
    page.select_option(".dialog .variable-location", "raw")
    assert page.locator(".dialog .variable-pattern option").all_inner_texts()[1:] == ["acquisition_config", "two_photon_movie"]
    page.select_option(".dialog .variable-pattern", "acquisition_config")
    page.select_option(".dialog .variable-adapter", "json")
    page.click(".dialog-foot button:has-text('Add data variable')")
    page.wait_for_selector(".data-variables tr[data-variable='config']")
    variable = next(v for v in api.handle({"id": 3, "method": "dataVariables.list"})["result"] if v["name"] == "config")
    assert (variable["dataLocation"], variable["filePattern"], variable["fileAdapter"]) == ("raw", "acquisition_config", "json")

    saved = api.handle({"id": 4, "method": "dataVariables.save", "params": {"document": dict(variable, columnNames=["rate"])}})
    assert "result" in saved, saved
    page.goto(empty_app["server"].url + "#/")   # and back, so the page has the variable as it is now
    page.goto(empty_app["server"].url + "#/data")
    page.wait_for_selector(".data-variables tr[data-variable='config'] .edit-variable")
    page.click(".data-variables tr[data-variable='config'] .edit-variable")
    page.wait_for_selector(".dialog .variable-pattern option[value='acquisition_config']", state="attached")
    assert page.locator(".dialog .variable-name").is_disabled()
    assert page.locator(".dialog .variable-location").input_value() == "raw"
    page.fill(".dialog .variable-title", "Acquisition config")
    page.fill(".dialog .variable-in-file", "settings")   # one variable of a file of several
    page.click(".dialog-foot button:has-text('Save')")
    page.wait_for_selector(".data-variables tr[data-variable='config']:has-text('Acquisition config')")
    variable = next(v for v in api.handle({"id": 5, "method": "dataVariables.list"})["result"] if v["name"] == "config")
    assert variable["variableInFile"] == "settings" and variable["columnNames"] == ["rate"]   # what the form does not show is kept

    page.click(".data-variables tr[data-variable='config'] .delete-variable")
    page.click(".dialog-foot button:has-text('Delete')")
    page.wait_for_selector(".data-variables tr[data-variable='config']", state="detached")
    assert "config" not in names()


def test_add_and_remove_modules(empty_app, page):
    import json
    api = empty_app["api"]
    folder = empty_app["folder"] / "demo"
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(folder)}})
    (folder / "modules" / "lab").mkdir(parents=True)
    (folder / "modules" / "lab" / "module.nansen.json").write_text(json.dumps({
        "schemaType": "nansen.module", "schemaVersion": "0.1.0", "id": "lab", "version": "1.0.0", "title": "Lab tools"}))
    listed = lambda: [m["id"] for m in api.handle({"id": 2, "method": "project.info"})["result"]["modules"]]
    page.goto(empty_app["server"].url + "#/overview")
    page.click(".modules .manage-modules")
    page.wait_for_selector(".dialog li[data-module='lab'] .add-module")
    page.click(".dialog li[data-module='core'] .remove-module")  # the demo uses core's fragments
    page.wait_for_selector(".toast:has-text('module-in-use')")
    page.console_errors[:] = [e for e in page.console_errors if "module-in-use" not in e and "is used by" not in e]
    page.click(".dialog li[data-module='lab'] .add-module")
    page.wait_for_selector(".dialog li[data-module='lab'] .remove-module")
    assert listed() == ["core", "lab"]
    page.click(".dialog li[data-module='lab'] .remove-module")
    page.wait_for_selector(".dialog li[data-module='lab'] .add-module")
    assert listed() == ["core"]
    page.click(".dialog-foot button:has-text('Close')")
    page.wait_for_selector(".modules li:has-text('NANSEN core')")


def test_edit_the_dataset_config(empty_app, page):
    api = empty_app["api"]
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    config = empty_app["folder"] / "demo" / "dataset.dsm.json"
    page.goto(empty_app["server"].url + "#/data")
    page.click(".data-locations .edit-config")
    page.wait_for_selector(".loc-dialog .loc-list li")
    page.click(".loc-dialog .dialog-foot button:has-text('Edit as JSON')")   # what the forms do not show
    page.wait_for_selector(".dialog .config-text")
    text = page.locator(".dialog .config-text").input_value()
    import json
    assert json.loads(text) == json.loads(config.read_text())
    page.fill(".dialog .config-text", "{")
    assert page.locator(".dialog .config-status").inner_text().startswith("Not valid JSON")
    page.click(".dialog-foot button:has-text('Save')")
    page.wait_for_selector(".dialog .form-message:has-text('dataset-invalid')")
    assert config.read_text() == text
    page.fill(".dialog .config-text", text.replace('"displayName": "Processed"', '"displayName": "Processed data"'))
    page.click(".dialog-foot button:has-text('Save')")
    page.wait_for_selector(".data-locations td:has-text('Processed data')")
    assert '"displayName": "Processed data"' in config.read_text()


def test_edit_data_locations_in_forms(empty_app, page):
    import json
    api = empty_app["api"]
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    config_file = empty_app["folder"] / "demo" / "dataset.dsm.json"
    before = json.loads(config_file.read_text())
    page.goto(empty_app["server"].url + "#/data")
    page.click(".data-locations .edit-config")
    page.wait_for_selector(".loc-dialog .loc-list li")
    assert page.locator(".loc-list li").count() == len(before["dataLocations"])
    first = before["dataLocations"][0]
    assert page.locator(".loc-form input[name=displayName]").input_value() == first["displayName"]
    assert page.locator(".loc-level").count() == len(first["filesystemSource"]["entityLayout"])

    # a location of processed data, written by methods, with folders named from the keys of the raw one's levels
    page.click(".loc-add")
    page.click(".menu .item:has-text('Processed data, written by methods')")
    page.wait_for_selector(".loc-list li.selected:has-text('Processed data')")
    page.fill(".loc-form input[name=displayName]", "Analysis")
    page.locator(".loc-roots input[name=rootPath]").fill("data/analysis")
    page.click(".loc-dialog .dialog-foot button:has-text('Test')")
    page.wait_for_selector(".loc-found:has-text('A scan would find')")
    # and a file pattern on the raw location's last level
    page.click(".loc-list li >> nth=0")
    page.locator(".loc-level").last.locator(".loc-add-file").click()
    page.locator(".loc-level").last.locator("input[name=fileName]").last.fill("notes")
    page.locator(".loc-level").last.locator("input[name=filePattern]").last.fill("\\.txt$")
    page.click(".loc-dialog .dialog-foot button:has-text('Save')")
    page.wait_for_selector(".data-locations td:has-text('Analysis')")
    after = json.loads(config_file.read_text())
    added = after["dataLocations"][-1]
    assert added["displayName"] == "Analysis" and added["access"] == "readwrite" and added["dataCategory"] == "processed"
    assert added["derivedFrom"] == [first["identifier"]] and added["filesystemSource"]["rootStoragePaths"][0]["path"] == "data/analysis"
    assert added["filesystemSource"]["pathTemplate"].startswith("{rootPath}/")
    assert [lvl["entityType"] for lvl in added["filesystemSource"]["entityLayout"]] == \
        [lvl["entityType"] for lvl in first["filesystemSource"]["entityLayout"] if lvl.get("entityType")]
    assert after["dataLocations"][0]["filesystemSource"]["entityLayout"][-1]["filePatterns"][-1] == {"name": "notes", "pattern": "\\.txt$", "cardinality": "one"}
    unchanged = {k: v for k, v in after.items() if k != "dataLocations"}
    assert unchanged == {k: v for k, v in before.items() if k != "dataLocations"}   # the rest of the config is kept

    # what DSM refuses is not saved
    page.click(".data-locations .edit-config")
    page.wait_for_selector(".loc-dialog .loc-list li")
    page.fill(".loc-form input[name=identifier]", "")
    page.click(".loc-dialog .dialog-foot button:has-text('Save')")
    page.wait_for_selector(".loc-dialog .form-message:not(.hidden)")
    assert json.loads(config_file.read_text()) == after


def test_hold_reorder_and_change_queued_tasks(empty_app, page):
    api = empty_app["api"]
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    rows = api.handle({"id": 2, "method": "entities.list", "params": {"entityType": "session"}})["result"]["rows"]
    submit = lambda i: api.handle({"id": 3, "method": "tasks.submit", "params": {
        "methodId": "core.wait", "entityType": "session", "keys": [rows[i]["key"]],
        "options": {"seconds": 0, "message": f"task {i}"}}})["result"]["id"]
    ids = [submit(i) for i in range(3)]
    queued = lambda: [t["id"] for t in sorted(api.handle({"id": 4, "method": "tasks.list", "params": {"status": "queued"}})["result"],
                                              key=lambda t: (t.get("order") is None, t.get("order") or 0, t["createdAt"], t["id"]))]
    page.goto(empty_app["server"].url + "#/tasks")
    page.wait_for_selector(".task-group:has-text('Queue')")
    listed = lambda: page.eval_on_selector_all(".task[data-id]", "els => els.map(e => e.dataset.id)")[:3]
    assert listed() == ids

    page.click(f".task[data-id='{ids[2]}'] .move-up")
    wait_until(lambda: queued() == [ids[0], ids[2], ids[1]])
    wait_until(lambda: listed() == [ids[0], ids[2], ids[1]])
    assert page.locator(f".task[data-id='{ids[0]}'] .move-up").is_disabled()

    page.click(f".task[data-id='{ids[0]}'] .hold")
    page.wait_for_selector(f".task[data-id='{ids[0]}']:has-text('on hold')")
    assert api.handle({"id": 5, "method": "tasks.get", "params": {"id": ids[0]}})["result"]["onHold"] is True

    page.click(f".task[data-id='{ids[1]}'] .edit-options")
    page.fill(".dialog .field:has-text('Message') input", "changed")
    page.click(".dialog-foot button:has-text('Save')")
    wait_until(lambda: api.handle({"id": 6, "method": "tasks.get", "params": {"id": ids[1]}})["result"]["options"]["values"]["message"] == "changed")

    page.click(".hero button:has-text('Run next')")  # the held task is passed over
    wait_until(lambda: api.handle({"id": 7, "method": "tasks.get", "params": {"id": ids[2]}})["result"]["status"] == "completed")
    page.click(f".task[data-id='{ids[0]}'] .release")
    page.wait_for_selector(f".task[data-id='{ids[0]}'] .hold")


def test_browse_an_entitys_files(empty_app, page):
    api = empty_app["api"]
    from pathlib import Path

    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    first = api.handle({"id": 2, "method": "entities.list", "params": {"entityType": "session"}})["result"]["rows"][0]
    detail = api.handle({"id": 3, "method": "entities.get", "params": {"entityType": "session", "key": first["key"]}})["result"]
    processed = next(loc for loc in detail["locations"] if loc["dataLocationIdentifier"] == "processed")
    folder = Path(api.handle({"id": 4, "method": "files.resolve", "params": {
        "dataLocation": "processed", "path": processed["paths"][0]}})["result"]["path"])
    (folder / "roi").mkdir()
    (folder / "roi" / "masks.json").write_text("[]")
    import shutil
    nwb = Path(__file__).resolve().parents[2] / "conformance/api/files/project/data/recording.nwb"
    shutil.copy(nwb, folder / "roi" / "recording.nwb")
    (folder / "roi" / "old.mat").write_bytes(b"MATLAB 5.0 MAT-file" + bytes(200))

    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    page.locator(".grid-table tbody tr[data-id]").first.locator("td.key").first.click()
    page.wait_for_selector(".drawer.open .path-list .browse")
    tree = ".drawer .loc:has(.loc-head:has-text('processed'))"
    page.locator(f"{tree} .path-list .browse").first.click()
    page.wait_for_selector(f"{tree} ul.file-tree > li[data-name]")
    names = page.eval_on_selector_all(f"{tree} .path-list > ul.file-tree > li[data-name]", "els => els.map(e => e.dataset.name)")
    assert names[0] == "roi" and len(names) > 1  # folders first
    page.click(f"{tree} li.folder-entry[data-name='roi'] .tree-toggle")
    page.wait_for_selector(f"{tree} li.folder-entry.open + ul.file-tree > li[data-name='masks.json']")
    assert "2 B" in page.locator(f"{tree} li[data-name='masks.json'] .size").inner_text()
    # dev's file viewer: preview a file, make a folder, make a data variable of a file
    page.click(f"{tree} li[data-name='masks.json'] .preview-file")
    page.wait_for_selector(".preview-dialog pre:text-is('[]')")
    page.locator(".preview-dialog .dialog-foot button:has-text('Close')").click()
    page.click(f"{tree} li.folder-entry[data-name='roi'] .new-folder")
    page.fill(".dialog.narrow input", "extra")
    page.click(".dialog.narrow .dialog-foot button:has-text('OK')")
    page.wait_for_selector(f"{tree} li.folder-entry[data-name='extra']")
    assert (folder / "roi" / "extra").is_dir()
    page.click(f"{tree} li[data-name='masks.json'] .make-variable")
    page.wait_for_selector(".variable-form .variable-adapter option[value='json']", state="attached")
    assert page.locator(".variable-form .variable-file").input_value() == "masks.json"
    assert page.locator(".variable-form .variable-subfolder").input_value() == "roi"
    assert page.locator(".variable-form .variable-location").input_value() == "processed"
    assert page.locator(".variable-form .variable-adapter").input_value() == "json"
    page.locator(".dialog .dialog-foot button:has-text('Cancel')").click()
    # an NWB file shows its groups and datasets in place
    page.click(f"{tree} li[data-name='recording.nwb'] .inspect-file")
    page.wait_for_selector(f"{tree} .hdf5-summary:has-text('NWBFile 2.7.0')")
    page.click(f"{tree} li.hdf5-group[data-path='/acquisition'] .tree-toggle")
    page.wait_for_selector(f"{tree} li.hdf5-group[data-path='/acquisition/TwoPhotonSeries'] .pill:has-text('TwoPhotonSeries')")
    page.click(f"{tree} li.hdf5-group[data-path='/acquisition/TwoPhotonSeries'] .tree-toggle")
    assert page.locator(f"{tree} li.hdf5-dataset[data-path='/acquisition/TwoPhotonSeries/data'] .size").inner_text() == "4 × 3 × 5 · uint16"
    assert "ImagingPlane" in page.locator(f"{tree} li.hdf5-link[data-path='/acquisition/TwoPhotonSeries/imaging_plane']").inner_text()
    assert page.locator(f"{tree} li.hdf5-dataset[data-path='/session_description'] .size").inner_text() == "Two-photon imaging"
    page.click(f"{tree} li[data-name='recording.nwb'] .inspect-file")  # closes it
    page.wait_for_selector(f"{tree} .hdf5-tree", state="detached")
    page.click(f"{tree} li[data-name='old.mat'] .inspect-file")
    page.wait_for_selector(f"{tree} .hdf5-tree li:has-text('Not an HDF5 file')")
    page.locator(f"{tree} .path-list .browse").first.click()  # closes it again
    page.wait_for_selector(f"{tree} ul.file-tree", state="detached")


def test_send_the_selection_to_the_workspace(empty_app, page):
    api = empty_app["api"]
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    namespace = {}
    api.workspace = namespace
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    rows = page.locator(".grid-table tbody tr[data-id]")
    rows.nth(0).locator("td.sel input").check()
    rows.nth(2).locator("td.sel input").check()
    page.click(".selection-bar .send-workspace")
    page.fill(".dialog.narrow input", "chosen")
    page.click(".dialog.narrow .dialog-foot button:has-text('OK')")
    page.wait_for_selector(".toast:has-text('2 session(s) in chosen')")
    assert len(namespace["chosen"]) == 2


def test_start_a_method_from_the_data_page(empty_app, page):
    api = empty_app["api"]
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    page.goto(empty_app["server"].url + "#/data")
    page.click(".methods-card .new-method")
    page.fill(".dialog .field:has-text('Id') input", "count_frames")
    page.fill(".dialog .field:has-text('Title') input", "Count frames")
    page.click(".dialog-foot button:has-text('Create')")
    page.wait_for_selector(".methods-card li:has-text('Count frames')")
    assert (empty_app["folder"] / "demo" / "python" / "count_frames.py").is_file()
    assert (empty_app["folder"] / "demo" / "matlab" / "count_frames.m").is_file()
    method = next(m for m in api.handle({"id": 2, "method": "methods.list"})["result"] if m["id"] == "count_frames")
    assert method["entityType"] == "session"


def test_lock_editing_and_keyboard_shortcuts(empty_app, page):
    api = empty_app["api"]
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    assert page.locator(".grid-table tbody td.editable").count() > 0
    page.click(".toolbar .lock-edits")
    page.wait_for_selector(".toolbar .lock-edits.on")
    assert page.locator(".grid-table tbody td.editable").count() == 0
    assert page.locator(".grid-table tbody input[type=checkbox]:not([disabled])").count() == page.locator(".grid-table tbody td.sel input").count()
    page.reload()  # remembered
    page.wait_for_selector(".toolbar .lock-edits.on")
    page.click(".toolbar .lock-edits")
    page.wait_for_selector(".grid-table tbody td.editable")

    page.evaluate("document.activeElement.blur()")
    page.keyboard.press("/")
    assert page.evaluate("document.activeElement.closest('.search') !== null")
    page.keyboard.press("Escape")
    assert page.evaluate("document.activeElement.closest('.search') === null")
    page.keyboard.press("g")
    page.keyboard.press("t")
    page.wait_for_selector(".hero h1:has-text('Tasks')")
    page.keyboard.press("g")
    page.keyboard.press("1")
    page.wait_for_selector(".grid-table tbody td.key")
    assert page.url.endswith("#/entities/subject")
    page.keyboard.press("Escape")  # out of the search box, which has the focus
    page.keyboard.press("?")
    page.wait_for_selector(".dialog .shortcuts")
    page.keyboard.press("Escape")
    opened = []
    empty_app["api"].open_url = opened.append   # the Help menu's pages open in the system's browser
    page.click(".help-button")
    page.click(".menu .item:has-text('Report a problem')")
    wait_until(lambda: opened == ["https://github.com/ehennestad/nansen-core/issues/new"])
    page.click(".help-button")
    page.click(".menu .item:has-text('Keyboard shortcuts')")
    page.wait_for_selector(".dialog .shortcuts")
    assert empty_app["api"].handle({"id": 1, "method": "app.openUrl", "params": {"url": "file:///etc/passwd"}})["error"]["code"] == "invalid-params"


def test_run_a_project_tool_from_the_overview(empty_app, page):
    api = empty_app["api"]
    folder = empty_app["folder"] / "demo"
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(folder)}})
    api.handle({"id": 2, "method": "methods.create", "params": {"id": "tally", "title": "Tally sessions", "entityType": "@project"}})
    code = folder / "python" / "tally.py"
    code.write_text(code.read_text().replace("return {}", "return {'sessions': len(project.entities('session'))}"))
    page.goto(empty_app["server"].url + "#/overview")
    page.click(".tools-card li[data-tool='tally'] .run-tool")
    page.click(".dialog-foot button:has-text('Run')")
    page.wait_for_selector(".dialog .tool-result")
    assert '"sessions": 14' in page.locator(".dialog .tool-result").inner_text()
    assert "Tally sessions" in page.locator(".dialog .tool-output").inner_text()


def test_edit_the_project_details(empty_app, page):
    api = empty_app["api"]
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    page.goto(empty_app["server"].url + "#/overview")
    page.click(".hero .edit-project")
    page.fill(".dialog .field:has-text('Title') input", "Visual cortex study")
    page.fill(".dialog .field:has-text('Name of the session table') input", "Imaging sessions")
    page.click(".dialog-foot button:has-text('Save')")
    page.wait_for_selector(".hero h1:has-text('Visual cortex study')")
    page.wait_for_selector(".nav a:has-text('Imaging sessions')")
    info = api.handle({"id": 2, "method": "project.info"})["result"]
    assert info["title"] == "Visual cortex study"
    assert [t.get("title") for t in info["entityTypes"] if t["name"] == "session"] == ["Imaging sessions"]
    assert [p["title"] for p in api.handle({"id": 3, "method": "catalog.list"})["result"]] == ["Visual cortex study"]


def test_review_and_ignore_what_a_scan_did_not_match(empty_app, page):
    from pathlib import Path

    api = empty_app["api"]
    folder = empty_app["folder"] / "demo"
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(folder)}})
    raw = Path(api.handle({"id": 2, "method": "files.resolve", "params": {"dataLocation": "raw", "path": ""}})["result"]["path"])
    (raw / "junk_folder").mkdir()
    api.handle({"id": 3, "method": "project.scan"})
    page.goto(empty_app["server"].url + "#/overview")
    page.wait_for_selector(".unmatched-card li[data-path='junk_folder/']")
    page.click(".unmatched-card li[data-path='junk_folder/'] .ignore-entry")
    page.wait_for_selector(".toast:has-text('^junk_folder$')")
    page.wait_for_selector(".unmatched-card li[data-path='junk_folder/']", state="detached")
    assert "^junk_folder$" in (folder / "dataset.dsm.json").read_text()
    assert api.handle({"id": 4, "method": "project.scan"})["result"]["unmatched"] == 0


def test_assign_a_folder_a_scan_did_not_match_to_a_session_and_undo_it(empty_app, page):
    from pathlib import Path

    api = empty_app["api"]
    folder = empty_app["folder"] / "demo"
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(folder)}})
    processed = Path(api.handle({"id": 2, "method": "files.resolve", "params": {"dataLocation": "processed", "path": ""}})["result"]["path"])
    (processed / "subject-m110" / "redo").mkdir(parents=True)
    api.handle({"id": 3, "method": "project.scan"})
    page.goto(empty_app["server"].url + "#/overview")
    entry = ".unmatched-card li[data-path='subject-m110/redo/']"
    page.wait_for_selector(entry)
    page.click(entry + " .assign-entry")
    page.wait_for_selector(".dialog .pick-entity")
    # filled in from the names: the subject from its folder, the session left to say
    assert page.input_value(".dialog input[data-column='subject_id']") == "m110"
    assert page.input_value(".dialog input[data-column='session_id']") == ""
    page.click(".dialog-foot button:has-text('Assign')")   # no session: refused, and the dialog stays
    page.wait_for_selector(".dialog .form-message:has-text('invalid-params')")
    page.select_option(".dialog .pick-entity", label="m110 / m110-20250523-002")
    assert page.input_value(".dialog input[data-column='session_id']") == "m110-20250523-002"
    page.click(".dialog-foot button:has-text('Assign')")
    page.wait_for_selector(".assigned-card li[data-path='subject-m110/redo/']")
    page.wait_for_selector(entry, state="detached")
    detail = api.handle({"id": 4, "method": "entities.get", "params": {
        "entityType": "session", "key": {"subject_id": "m110", "session_id": "m110-20250523-002"}}})["result"]
    paths = {loc["dataLocationIdentifier"]: loc["paths"] for loc in detail["locations"]}
    assert "subject-m110/redo/" in paths["processed"]
    assert (folder / "dataset.assignments.nansen.json").is_file()

    page.click(".assigned-card li[data-path='subject-m110/redo/'] .unassign-entry")
    page.wait_for_selector(".assigned-card", state="detached")
    page.wait_for_selector(entry)
    assert api.handle({"id": 5, "method": "dataset.assignments"})["result"] == []


def test_keep_one_of_two_folders_of_a_session(empty_app, page):
    import shutil
    from pathlib import Path

    api = empty_app["api"]
    folder = empty_app["folder"] / "demo"
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(folder)}})
    raw = Path(api.handle({"id": 2, "method": "files.resolve", "params": {"dataLocation": "raw", "path": ""}})["result"]["path"])
    original = raw / "2025_06_11" / "2025_06_11_17_28_00_m112-20250611-001"
    shutil.copytree(original, original.with_name("2025_06_11_18_00_00_m112-20250611-001"))   # a copy: the same session twice
    api.handle({"id": 3, "method": "project.scan"})
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    page.locator(".grid-table tbody tr[data-id]", has_text="m112-20250611-001").locator("td.key").first.click()
    page.wait_for_selector(".drawer.open .loc-head .pill:has-text('2 folders')")
    page.locator(".drawer.open .path-list li", has_text="18_00_00").locator(".exclude-folder").click()
    page.click(".dialog .btn.primary:has-text('Leave it out')")
    page.wait_for_selector(".toast:has-text('Left out')")
    page.wait_for_selector(".drawer.open .loc-head .pill:has-text('2 folders')", state="detached")
    assert page.locator(".drawer.open .path-list li").count() == 1
    assert "18_00_00" in (folder / "dataset.dsm.json").read_text()
    entity = api.handle({"id": 4, "method": "entities.get", "params": {"entityType": "session",
                                                                       "key": {"subject_id": "m112", "session_id": "m112-20250611-001"}}})["result"]
    assert "duplicate-entity" not in [i["code"] for i in entity["issueDetails"]]


def test_open_files_send_data_and_edit_code_from_the_app(empty_app, page):
    api = empty_app["api"]
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    api.handle({"id": 2, "method": "methods.create", "params": {"id": "count_frames", "title": "Count frames", "entityType": "session"}})
    opened, edited, namespace = [], [], {}
    api.open_file, api.edit_file, api.workspace = opened.append, edited.append, namespace
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    page.locator(".grid-table tbody tr[data-id]").nth(1).locator("td.key").first.click()
    page.wait_for_selector(".drawer.open li[data-variable='motion_corrected'] .send-data")
    page.click(".drawer li[data-variable='motion_corrected'] .send-data")
    page.click(".dialog.narrow .dialog-foot button:has-text('OK')")
    page.wait_for_selector(".toast:has-text('Loaded into the workspace')")
    assert "motion_corrected" in namespace

    tree = ".drawer .loc:has(.loc-head:has-text('raw'))"
    page.locator(f"{tree} .path-list .browse").first.click()
    page.locator(f"{tree} li.file-entry .open-file").first.click()
    wait_until(lambda: len(opened) == 1)
    assert opened[0].is_file()
    page.locator(".drawer-head button[title='Close']").click()

    page.click(".toolbar button:has-text('Run method')")
    page.click(".method-item:has-text('Count frames')")
    page.click(".method-detail .edit-code")
    wait_until(lambda: len(edited) == 1)
    assert edited[0].name == "count_frames.py"


def test_settings_page(empty_app, page):
    api = empty_app["api"]
    page.goto(empty_app["server"].url + "#/settings")
    page.wait_for_selector(".hero h1:has-text('Settings')")
    assert page.locator(".auto-start input").is_checked()
    saved = lambda response: "/api" in response.url and "settings.save" in (response.request.post_data or "")
    with page.expect_response(saved) as answer:   # each answered before the next, and before the page reloads
        page.locator(".auto-start span").click()
    answer.value.finished()
    assert api.handle({"id": 1, "method": "settings.get"})["result"]["queue"]["autoStart"] is False
    with page.expect_response(saved) as answer:
        page.select_option(".worker-select", "process")
    answer.value.finished()
    assert api.handle({"id": 1, "method": "settings.get"})["result"]["queue"]["worker"] == "process"
    page.select_option(".theme-select", "dark")
    assert page.evaluate("document.documentElement.dataset.theme") == "dark"
    page.reload()
    page.wait_for_selector(".auto-start")
    assert not page.locator(".auto-start input").is_checked()


def test_a_preset_made_the_methods_default(empty_app, page):   # dev's preferred options
    api = empty_app["api"]
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    api.handle({"id": 2, "method": "presets.save", "params": {"methodId": "core.wait", "name": "quick", "values": {"seconds": 0}}})
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody tr[data-id]")
    rows(page).nth(0).locator("td.sel input").click()
    page.click(".selection-bar button:has-text('Run method')")
    page.click(".method-item:has-text('Wait')")
    page.wait_for_selector(".method-detail:has(h3:text-is('Wait')) .preset-row")
    page.locator(".method-detail .preset-row select").select_option("quick")
    page.click(".method-detail .preset-default")
    page.wait_for_selector(".method-detail .preset-default.active")
    assert api.handle({"id": 3, "method": "presets.list", "params": {"methodId": "core.wait"}})["result"][1].get("preferred") is True
    page.click(".dialog-head button[title='Close']")
    page.click(".selection-bar button:has-text('Run method')")
    page.click(".method-item:has-text('Wait')")
    page.wait_for_selector(".method-detail:has(h3:text-is('Wait')) .preset-default.active")   # opens on it
    assert page.locator(".method-detail .preset-row select").input_value() == "quick"


def test_options_for_each_entity(empty_app, page):   # dev's per-session options: each entity's own, edited before it runs
    api = empty_app["api"]
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody tr[data-id]")
    rows(page).nth(0).locator("td.sel input").click()
    rows(page).nth(1).locator("td.sel input").click()
    page.click(".selection-bar button:has-text('Run method')")
    page.click(".method-item:has-text('Wait')")
    page.wait_for_selector(".method-detail:has(h3:text-is('Wait')) .preset-row")
    page.fill(".method-detail .field:has-text('Seconds') input", "0")
    page.check(".each-entity input")
    page.click(".dialog-foot button:has-text('Add to queue')")
    page.wait_for_selector(".dialog-head h2:has-text('(1 of 2)')")
    assert page.locator(".entity-options .field:has-text('Seconds') input").input_value() == "0"   # from the form
    page.click(".dialog-foot button:has-text('Next')")
    page.wait_for_selector(".dialog-head h2:has-text('(2 of 2)')")
    page.fill(".entity-options .field:has-text('Seconds') input", "1")
    page.click(".dialog-foot button:has-text('Done')")
    page.wait_for_url("**#/tasks")
    tasks = api.handle({"id": 2, "method": "tasks.list", "params": {}})["result"]
    assert [(len(t["entities"]), t["options"]["values"]["seconds"]) for t in tasks] == [(1, 0), (1, 1)]
    assert tasks[0]["entities"][0]["key"] != tasks[1]["entities"][0]["key"]


def test_skip_entities_where_it_already_ran(empty_app, page):   # dev's RedoIfCompleted off
    api = empty_app["api"]
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody tr[data-id]")
    first = api.project.entities("session")[0]
    api.handle({"id": 2, "method": "methods.run", "params": {"methodId": "core.wait", "entityType": "session", "keys": [first.key],
                                                              "options": {"seconds": 0}}})
    for n in range(2):
        rows(page).nth(n).locator("td.sel input").click()
    page.click(".selection-bar button:has-text('Run method')")
    page.click(".method-item:has-text('Wait')")
    page.wait_for_selector(".method-detail:has(h3:text-is('Wait')) .preset-row")
    page.fill(".method-detail .field:has-text('Seconds') input", "0")
    page.check(".skip-completed input")
    page.click(".dialog-foot button:has-text('Add to queue')")
    page.wait_for_url("**#/tasks/*")
    task = api.handle({"id": 3, "method": "tasks.list", "params": {}})["result"][-1]
    assert task["skipCompleted"] is True and len(task["entities"]) == 2
    page.wait_for_selector(".task-skipped")   # the task's detail says which it leaves out
    ran = api.handle({"id": 4, "method": "tasks.runNext", "params": {}})["result"]
    assert ran["skipped"] == ([dict(first.key)] if dict(first.key) in [e["key"] for e in task["entities"]] else [])


def test_table_text_size(empty_app, page):   # dev's table font size, kept in this browser
    empty_app["api"].handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody tr[data-id]")
    height = lambda: page.locator(".grid-table tbody tr[data-id] td").first.bounding_box()["height"]
    assert height() == 36
    page.goto(empty_app["server"].url + "#/settings")
    page.select_option(".table-size-select", "large")
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody tr[data-id]")
    assert page.evaluate("document.documentElement.dataset.tableSize") == "large" and height() == 44
    page.reload()
    page.wait_for_selector(".grid-table tbody tr[data-id]")
    assert height() == 44


def test_a_pipeline_step_run_by_hand(empty_app, page):
    api = empty_app["api"]
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    call = lambda method, **params: api.handle({"id": 2, "method": method, "params": params})
    call("methods.create", id="curate", title="Curate", entityType="session", queueable=False)
    call("pipelines.save", document={"schemaType": "nansen.pipeline", "schemaVersion": "0.1.0", "id": "review", "version": "1.0.0",
                                     "title": "Review", "entityType": "session", "steps": [{"method": "curate", "title": "Curate by hand"}]})
    rows = call("entities.list", entityType="session")["result"]["rows"]
    call("pipelines.assign", entityType="session", keys=[rows[0]["key"]], pipelineId="review")
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table .progress-text:has-text('0/1')")
    page.locator(".grid-table tbody tr[data-id]").first.locator("td.key").first.click()
    page.wait_for_selector(".drawer.open .pipeline-card .run-step:has-text('Run Curate by hand now')")
    assert page.locator(".drawer .pipeline-card button:has-text('Queue the next steps')").count() == 0
    page.click(".drawer .pipeline-card .run-step")
    page.wait_for_selector(".drawer.open .pipeline-card .steps li.done")
    assert call("entities.get", entityType="session", key=rows[0]["key"])["result"]["pipeline"]["done"] == 1
    page.click(".drawer .pipeline-card .steps li[data-step='0'] .step-mark")   # dev's pipeline viewer: untick it by hand ...
    page.wait_for_selector(".drawer.open .pipeline-card .steps li:not(.done)[data-step='0']")
    assert call("entities.get", entityType="session", key=rows[0]["key"])["result"]["pipeline"]["done"] == 0
    page.click(".drawer .pipeline-card .steps li[data-step='0'] .step-mark")   # ... tick it again
    page.wait_for_selector(".drawer.open .pipeline-card .steps li.done[data-step='0']")
    page.click(".drawer .pipeline-card .steps li[data-step='0'] .run-this-step")   # and run a step that is done again
    page.wait_for_selector(".toast:has-text('Curate by hand finished')")


def test_leaving_the_table_while_it_is_due_to_reload(app, page):
    # an entities event schedules a reload of the table; leaving it before that runs is no error
    open_sessions(app, page)
    page.evaluate("N.app.entitiesEvent({}); location.hash = '#/overview'")
    page.wait_for_selector(".stat")
    time.sleep(0.4)  # past the reload's delay; the page fixture fails on any page error


def test_a_narrow_window_has_the_sidebar_behind_a_menu(app, page):
    page.goto(app["server"].url + "#/overview")
    page.wait_for_selector(".stat")
    assert not page.locator(".menu-button").is_visible()   # wide: the sidebar is always there
    page.set_viewport_size({"width": 390, "height": 844})
    assert page.locator(".menu-button").is_visible()
    wait_until(lambda: page.evaluate("document.querySelector('.sidebar').getBoundingClientRect().right") <= 0)  # slid away
    assert page.evaluate("document.documentElement.scrollWidth") <= 390   # nothing wider than the window
    page.click(".menu-button")
    wait_until(lambda: page.evaluate("document.querySelector('.sidebar').getBoundingClientRect().left") >= 0)
    page.click(".nav a:has-text('Sessions')")
    page.wait_for_selector(".grid-table tbody td.key")
    assert not page.locator(".shell.nav-open").count()   # going somewhere closes it


def test_an_edit_survives_a_reload_of_the_table(app, page):
    open_sessions(app, page)
    index = page.evaluate("Array.from(document.querySelectorAll('.grid-table thead th')).findIndex((th) => th.textContent.trim().startsWith('Description'))")
    cell = page.locator(".grid-table tbody tr[data-id]").nth(1).locator("td").nth(index)
    cell.click()
    page.wait_for_selector(".grid-table td.editing input")
    page.keyboard.type("typed while the table reloads")
    app["api"].handle({"id": 1, "method": "project.sync", "params": {}})   # an entities event: the table reloads
    page.evaluate("N.app.render()")   # and a page render, as a project event makes
    time.sleep(0.5)
    assert page.locator(".grid-table td.editing input").input_value() == "typed while the table reloads"
    page.keyboard.press("Enter")
    wait_until(lambda: "typed while the table reloads" in page.locator(".grid-table tbody").inner_text())
    rows = app["api"].handle({"id": 2, "method": "entities.list", "params": {"entityType": "session"}})["result"]["rows"]
    assert sum(r["values"].get("description") == "typed while the table reloads" for r in rows) == 1


def test_edit_a_column(empty_app, page):
    api = empty_app["api"]
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    call = lambda method, **params: api.handle({"id": 2, "method": method, "params": params})
    call("fragments.create", entityType="session", document={
        "schemaType": "nansen.fragment", "schemaVersion": "0.1.0", "id": "qc", "version": "1.0.0",
        "columns": [{"name": "quality", "dataType": "string", "choices": ["good", "poor"]}]})
    key = call("entities.list", entityType="session")["result"]["rows"][0]["key"]
    call("entities.update", entityType="session", key=key, values={"quality": "poor"})
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table th:has-text('quality')")
    page.hover(".grid-table th:has-text('quality')")
    page.click(".grid-table th:has-text('quality') .col-menu")
    page.click(".menu .item:has-text('Edit column')")
    page.fill(".dialog .field:has-text('Choices') input", "good")
    page.click(".dialog-foot button:has-text('Save')")
    page.wait_for_selector(".dialog .form-message:has-text('which the choices leave out')")
    page.fill(".dialog .field:has-text('Title') input", "Quality")
    page.fill(".dialog .field:has-text('Choices') input", "good, poor, unsure")
    page.click(".dialog-foot button:has-text('Save')")
    page.wait_for_selector(".grid-table th:has-text('Quality')")
    fragment = next(f for f in call("fragments.list")["result"] if f["id"] == "qc")
    assert fragment["version"] == "1.0.1" and fragment["columns"][0]["choices"] == ["good", "poor", "unsure"]
    assert call("entities.get", entityType="session", key=key)["result"]["values"]["quality"] == "poor"


def test_add_a_computed_column(empty_app, page):
    api = empty_app["api"]
    folder = empty_app["folder"] / "demo"
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(folder)}})
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    page.click(".toolbar button:has-text('Columns')")
    page.click(".menu .item:has-text('Add a computed column')")
    page.fill(".dialog .field:has-text('Column name') input", "n_frames")
    page.fill(".dialog .field:has-text('Title') input", "Frames")
    page.select_option(".dialog .field:has-text('Type') select", "integer")
    page.click(".dialog-foot button:has-text('Create')")
    page.wait_for_selector(".grid-table th:has-text('Frames')")
    page.wait_for_selector(".toast:has-text('Computed column added')")  # the toolbar is drawn again by then
    code = folder / "python" / "n_frames.py"
    code.write_text(code.read_text().replace('"n_frames": None', '"n_frames": 42'))
    page.click(".toolbar button:has-text('Update')")
    page.click(".menu .item:has-text('Frames')")
    wait_until(lambda: all(r["values"].get("n_frames") == 42 for r in
                           api.handle({"id": 2, "method": "entities.list", "params": {"entityType": "session"}})["result"]["rows"] if r["inTable"]))


def test_describe_the_data_folders(empty_app, page):
    api = empty_app["api"]
    data = empty_app["folder"] / "data"
    for path in ["sub-m1/ses-1/rec.raw", "sub-m1/ses-2/rec.raw", "sub-m2/ses-1/rec.raw"]:
        (data / path).parent.mkdir(parents=True, exist_ok=True)
        (data / path).write_text("x")
    (data / "notes").mkdir()
    api.handle({"id": 1, "method": "project.create", "params": {"path": str(empty_app["folder"] / "study"), "name": "Study"}})
    page.goto(empty_app["server"].url + "#/overview")
    page.click(".setup .describe-data")
    page.fill(".dialog .wizard-root", str(data))
    page.click(".dialog-foot button:has-text('Next')")
    page.wait_for_selector(".dialog .level-card[data-level='2']")
    assert page.locator(".dialog .level-card[data-level='1'] .level-type").input_value() == "subject"
    page.fill(".dialog .level-card[data-level='1'] .level-template", "sub-{subject_id}")
    page.fill(".dialog .level-card[data-level='2'] .level-template", "ses-{session_id}")
    page.wait_for_selector(".dialog .level-card[data-level='2'] .level-check:has-text('2 of the 2 examples match')")
    page.click(".dialog-foot button:has-text('Next')")
    page.wait_for_selector(".dialog .stat:has-text('session')")
    stats = page.locator(".dialog .stat .value").all_inner_texts()
    assert stats == ["2", "3"]  # subjects, sessions
    assert "notes/" in page.locator(".dialog").inner_text()  # not matched
    page.click(".dialog-foot button:has-text('Use this dataset')")
    page.wait_for_selector(".toast:has-text('Dataset set up')")
    info = api.handle({"id": 2, "method": "project.info"})["result"]
    assert [t["name"] for t in info["entityTypes"]] == ["subject", "session"]
    assert info["dataset"]["locations"][0]["id"] == "raw"
    scan = api.handle({"id": 3, "method": "project.scan"})["result"]
    assert scan["records"] == {"subject": 2, "session": 3}


def test_start_a_file_adapter(empty_app, page):
    api = empty_app["api"]
    folder = empty_app["folder"] / "demo"
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(folder)}})
    page.goto(empty_app["server"].url + "#/data")
    page.click(".data-variables .new-adapter")
    page.fill(".dialog .field:has-text('Id') input", "tiff_stack")
    page.fill(".dialog .field:has-text('File extensions') input", "tif, .tiff")
    page.click(".dialog-foot button:has-text('Create')")
    page.wait_for_selector(".toast:has-text('File adapter created')")
    assert (folder / "python" / "tiff_stack_adapter.py").is_file() and (folder / "matlab" / "TiffStackAdapter.m").is_file()
    options = api.handle({"id": 2, "method": "dataVariables.options", "params": {"entityType": "session"}})["result"]
    assert "tiff_stack" in options["fileAdapters"]


def test_a_pipeline_rule_for_new_rows(empty_app, page):
    api = empty_app["api"]
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    page.goto(empty_app["server"].url + "#/pipelines")
    page.click(".hero button:has-text('New pipeline')")
    page.fill(".dialog .field:has-text('Id') input", "m110_only")
    page.select_option(".dialog .field:has-text('Entity type') select", "session")
    page.click(".dialog .step-editor button:has-text('Add a step')")
    page.select_option(".dialog .step-editor li:first-child select", "core.file_stats")
    page.click(".dialog .add-rule")
    page.fill(".dialog .rule-column", "subject_id")
    page.fill(".dialog .rule-text", "m110, m111")
    page.click(".dialog-foot button:has-text('Save pipeline')")
    page.wait_for_selector(".card.pipeline[data-id='m110_only']")
    saved = next(p for p in api.handle({"id": 2, "method": "pipelines.list", "params": {"entityType": "session"}})["result"] if p["id"] == "m110_only")
    assert saved["assignWhen"] == [{"column": "subject_id", "op": "in", "values": ["m110", "m111"]}]


def test_move_and_size_columns(empty_app, page):
    api = empty_app["api"]
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    headers = lambda: page.eval_on_selector_all(".grid-table thead th[data-column]", "els => els.map(e => e.dataset.column)")
    before = headers()
    assert before[:2] == ["subject_id", "session_id"]
    page.drag_and_drop(".grid-table thead th[data-column='session_id']", ".grid-table thead th[data-column='subject_id']")
    wait_until(lambda: headers()[:2] == ["session_id", "subject_id"])
    handle = page.locator(".grid-table thead th[data-column='session_id'] .col-resize")
    box = handle.bounding_box()
    page.mouse.move(box["x"] + 3, box["y"] + 5)
    page.mouse.down()
    page.mouse.move(box["x"] + 103, box["y"] + 5, steps=5)
    page.mouse.up()
    width = page.eval_on_selector(".grid-table thead th[data-column='session_id']", "e => e.style.width")
    assert width.endswith("px") and int(float(width[:-2])) > 100
    page.reload()  # remembered
    page.wait_for_selector(".grid-table tbody td.key")
    assert headers()[:2] == ["session_id", "subject_id"]
    page.click(".toolbar button:has-text('Columns')")
    page.click(".menu .item:has-text('Reset the column order and widths')")
    wait_until(lambda: headers() == before)


def test_a_column_drawn_as_a_badge_with_an_action(empty_app, page):
    api = empty_app["api"]
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    call = lambda method, **params: api.handle({"id": 2, "method": method, "params": params})
    call("fragments.create", entityType="session", document={
        "schemaType": "nansen.fragment", "schemaVersion": "0.1.0", "id": "qc", "version": "1.0.0",
        "columns": [{"name": "quality", "dataType": "string", "choices": ["good", "poor"],
                     "display": {"as": "badge", "colors": {"good": "good", "poor": "bad"}}, "action": "core.file_stats"}]})
    rows = call("entities.list", entityType="session")["result"]["rows"]
    call("entities.update", entityType="session", key=rows[0]["key"], values={"quality": "poor"})
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table td .pill.bad:has-text('poor')")
    page.locator(".grid-table td.has-action").first.dblclick()
    page.wait_for_selector(".toast:has-text('Done')")


def ophys_project(empty_app, steps=()):
    """The ophys conformance project, opened and set up, with the given further requests made."""
    pytest.importorskip("numpy")
    pytest.importorskip("tifffile")
    import shutil
    from pathlib import Path

    api = empty_app["api"]
    folder = empty_app["folder"] / "ophys"
    shutil.copytree(Path(__file__).resolve().parents[2] / "conformance" / "api" / "ophys" / "project", folder)
    for number, (method, params) in enumerate([
            ("project.open", {"path": str(folder)}), ("project.scan", {}), ("project.sync", {}),
            ("tools.run", {"methodId": "ophys.setup_variables", "options": {"rawFilePattern": "recording"}}), *steps]):
        response = api.handle({"id": number, "method": method, "params": params})
        assert "result" in response, (method, response)
    return api


def test_view_a_stack_with_its_rois(empty_app, page):
    s1 = [{"subject_id": "m1", "session_id": "s1"}]
    api = ophys_project(empty_app, [
        ("methods.run", {"methodId": "ophys.motion_correction", "entityType": "session", "keys": s1, "options": {"referenceFrames": 1}}),
        ("methods.run", {"methodId": "ophys.detect_rois", "entityType": "session", "keys": s1, "options": {"threshold": 0.25, "border": 4}})])
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    page.locator(".grid-table tbody tr[data-id]").first.locator("td.key").first.click()
    page.wait_for_selector(".drawer.open li[data-variable='TwoPhotonSeries_Original'] .view-data")
    assert page.locator(".drawer li[data-variable='RoiArray'] .view-data").count() == 0
    page.click(".drawer li[data-variable='TwoPhotonSeries_Corrected'] .view-data")
    page.wait_for_selector(".viewer-dialog .viewer-status:has-text('32 × 32 · 3 ROIs')")
    assert page.evaluate("document.querySelector('.viewer-canvas').width") == 32
    assert page.locator(".viewer-frame").inner_text() == "1 / 40"
    page.locator(".viewer-slider").fill("9")
    page.wait_for_selector(".viewer-frame:text-is('10 / 40')")
    page.select_option(".viewer-mode", "max")
    page.wait_for_selector(".viewer-frame:text-is('40 frames')")
    assert page.locator(".viewer-slider").is_disabled()
    page.locator(".viewer-high").fill("300")
    page.locator(".viewer-high").press("Enter")
    wait_until(lambda: not page.locator(".viewer-bar input[type=checkbox]").first.is_checked())
    page.locator(".viewer-canvas").hover()
    page.select_option(".viewer-mode", "frame")
    page.click(".viewer-play")
    wait_until(lambda: page.locator(".viewer-frame").inner_text() not in ("10 / 40", "11 / 40"))
    page.click(".viewer-play")

    # curate: reject ROI 2 with its key, add one by clicking, delete it again
    page.click(".viewer-roi-list li[data-roi='2']")
    page.keyboard.press("r")
    page.wait_for_selector(".viewer-roi-list li[data-roi='2'] .pill:has-text('rejected')")
    page.click(".viewer-add")
    box = page.locator(".viewer-canvas").bounding_box()
    page.mouse.click(box["x"] + box["width"] * 5.5 / 32, box["y"] + box["height"] * 26.5 / 32)
    page.wait_for_selector(".viewer-roi-list li[data-roi='4'].selected")
    page.click(".viewer-add")
    page.click(".roi-delete")
    wait_until(lambda: page.locator(".viewer-roi-list li").count() == 3)
    page.locator(".viewer-hide input").check()
    wait_until(lambda: page.locator(".viewer-roi-list li").count() == 2)
    page.locator(".viewer-dialog .dialog-head button[title='Close']").click()
    document = api.project.load(api.project.entity("session", s1[0]), "RoiArray", cached=False)
    assert [(r["id"], r.get("classification")) for r in document["rois"]] == [(1, None), (2, "rejected"), (3, None)]


def test_rois_drawn_on_a_stack_that_has_none(empty_app, page):   # roimanager on any stack: the first ROI makes the file
    s1 = {"subject_id": "m1", "session_id": "s1"}
    api = ophys_project(empty_app)
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    page.locator(".grid-table tbody tr[data-id]").first.locator("td.key").first.click()
    page.click(".drawer.open li[data-variable='TwoPhotonSeries_Original'] .view-data")
    page.wait_for_selector(".viewer-dialog .viewer-status:has-text('0 ROIs')")
    page.click(".viewer-add")
    box = page.locator(".viewer-canvas").bounding_box()
    page.mouse.click(box["x"] + box["width"] * 10.5 / 32, box["y"] + box["height"] * 12.5 / 32)
    page.wait_for_selector(".viewer-roi-list li[data-roi='1']")
    document = api.project.load(api.project.entity("session", s1), "RoiArray", cached=False)
    assert document["imageSize"] == [32, 32] and [r["id"] for r in document["rois"]] == [1]


def test_draw_detect_merge_and_move_rois_in_the_viewer(empty_app, page):
    s1 = [{"subject_id": "m1", "session_id": "s1"}]
    api = ophys_project(empty_app, [
        ("methods.run", {"methodId": "ophys.motion_correction", "entityType": "session", "keys": s1, "options": {"referenceFrames": 1}}),
        ("methods.run", {"methodId": "ophys.detect_rois", "entityType": "session", "keys": s1, "options": {"threshold": 0.25, "border": 4}})])

    def rois():   # the file, once the server has finished writing it
        for _ in range(50):
            try:
                return api.project.load(api.project.entity("session", s1[0]), "RoiArray", cached=False)["rois"]
            except ValueError:
                time.sleep(0.05)
        raise AssertionError("the ROI file stays unreadable")
    pixels = lambda roi: sorted(tuple(p) for p in roi["pixels"])
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    page.locator(".grid-table tbody tr[data-id]").first.locator("td.key").first.click()
    page.click(".drawer.open li[data-variable='TwoPhotonSeries_Corrected'] .view-data")
    page.wait_for_selector(".viewer-dialog .viewer-status:has-text('32 × 32 · 3 ROIs')")
    page.select_option(".viewer-mode", "mean")
    page.wait_for_selector(".viewer-frame:text-is('40 frames')")
    box = page.locator(".viewer-canvas").bounding_box()
    at = lambda row, column: (box["x"] + box["width"] * column / 32, box["y"] + box["height"] * row / 32)

    # draw: a square from (25, 2) to (30, 7) around pixel centres takes rows and columns 25..29 in
    page.click(".viewer-draw")
    page.mouse.move(*at(25, 2))
    page.mouse.down()
    for row, column in [(25, 7), (30, 7), (30, 2), (25, 2)]:
        page.mouse.move(*at(row, column), steps=4)
    page.mouse.up()
    page.wait_for_selector(".viewer-roi-list li[data-roi='4'].selected")
    assert pixels(rois()[3]) == [(r, c) for r in range(25, 30) for c in range(2, 7)]
    page.click(".viewer-draw")

    # detect: a click on the third cell finds the same pixels as rois.detect does
    page.click(".viewer-detect")
    page.mouse.click(*at(22.5, 9.5))
    page.wait_for_selector(".viewer-roi-list li[data-roi='5'].selected")
    found = api.handle({"id": 9, "method": "rois.detect", "params": {"entityType": "session", "key": s1[0], "variable": "TwoPhotonSeries_Corrected",
                                                                       "point": [22, 9], "radius": 6}})["result"]
    assert pixels(rois()[4]) == sorted(tuple(p) for p in found["pixels"]) and len(found["pixels"]) > 4
    page.keyboard.press("Escape")   # leaves the tool, not the viewer
    assert page.locator(".viewer-dialog").count() == 1
    assert page.locator(".viewer-detect.active").count() == 0

    # merge ROIs 4 and 5 (Ctrl-click selects several); the merged ROI keeps id 4
    page.click(".viewer-roi-list li[data-roi='4']")
    page.click(".viewer-roi-list li[data-roi='5']", modifiers=["Control"])
    assert page.locator(".viewer-roi-list li.selected").count() == 2
    expected = sorted(set(pixels(rois()[3])) | set(pixels(rois()[4])))
    page.click(".roi-merge")
    wait_until(lambda: page.locator(".viewer-roi-list li").count() == 4)
    assert [r["id"] for r in rois()] == [1, 2, 3, 4] and pixels(rois()[3]) == expected

    # move ROI 1 by dragging it: two rows down, one column left
    page.click(".viewer-roi-list li[data-roi='1']")
    before = pixels(rois()[0])
    row, column = before[len(before) // 2]
    page.mouse.move(*at(row + 0.5, column + 0.5))
    page.mouse.down()
    page.mouse.move(*at(row + 2.5, column - 0.5), steps=6)
    page.mouse.up()
    wait_until(lambda: pixels(rois()[0]) == [(r + 2, c - 1) for r, c in before])
    page.keyboard.press("Alt+ArrowUp")   # and back up a row with the keys
    wait_until(lambda: pixels(rois()[0]) == [(r + 1, c - 1) for r, c in before])

    # zoom with the wheel and back with a double-click; save the image
    page.mouse.move(*at(16, 16))
    page.mouse.wheel(0, -300)
    page.wait_for_selector(".viewer-zoom:visible")
    assert page.locator(".viewer-canvas").bounding_box()["width"] > box["width"] * 1.2
    page.locator(".viewer-canvas").dblclick()
    wait_until(lambda: abs(page.locator(".viewer-canvas").bounding_box()["width"] - box["width"]) < 2)
    with page.expect_download() as download:
        page.click(".viewer-export")
        page.click(".menu .item:has-text('Image as PNG')")
    assert download.value.suggested_filename.endswith("_TwoPhotonSeries_Corrected_mean.png")
    # frames 3..7 of the stack as TIFF, through ophys.export_tiff
    from pathlib import Path
    import numpy as np
    tifffile = pytest.importorskip("tifffile")
    page.click(".viewer-export")
    page.click(".menu .item:has-text('Stack as TIFF')")
    page.fill(".dialog .field:has-text('File') input", "exports/viewer.tif")
    page.fill(".dialog .field:has-text('First frame') input", "3")
    page.fill(".dialog .field:has-text('Last frame') input", "7")
    page.click(".dialog .btn.primary:has-text('Export')")
    page.wait_for_selector(".toast:has-text('Exported')")
    exported = tifffile.imread(Path(api.project.folder) / "exports" / "viewer.tif")
    corrected = np.asarray(api.project.load(api.project.entity("session", s1[0]), "TwoPhotonSeries_Corrected", cached=False))
    assert exported.shape == (5, 32, 32) and (np.moveaxis(exported, 0, 2) == corrected[:, :, 2:7]).all()

    # the gallery: a tile per ROI, sorted largest first; keys classify the selected one
    page.click(".viewer-gallery")
    page.wait_for_selector(".roi-gallery-dialog .roi-tile")
    assert page.locator(".roi-tile").count() == 4
    page.select_option(".roi-gallery-sort", "area")
    sizes = sorted(((len(r["pixels"]), -r["id"]) for r in rois()), reverse=True)
    wait_until(lambda: page.eval_on_selector_all(".roi-tile", "els => els.map(e => Number(e.dataset.roi))") == [-i for _, i in sizes])
    first, second = [-i for _, i in sizes[:2]]
    page.click(f".roi-tile[data-roi='{first}']")
    page.keyboard.press("a")
    page.wait_for_selector(f".roi-tile[data-roi='{first}'].accepted")
    page.keyboard.press("ArrowRight")
    page.keyboard.press("r")
    page.wait_for_selector(f".roi-tile[data-roi='{second}'].rejected")
    page.keyboard.press("Escape")   # closes the gallery only
    wait_until(lambda: page.locator(".roi-gallery-dialog").count() == 0)
    assert page.locator(".viewer-dialog").count() == 1
    classes = {r["id"]: r.get("classification") for r in rois()}
    assert classes[first] == "accepted" and classes[second] == "rejected"


def test_plot_signals_and_follow_an_roi_from_the_viewer(empty_app, page):
    s1 = [{"subject_id": "m1", "session_id": "s1"}]
    run = lambda method, options=None: ("methods.run", {"methodId": method, "entityType": "session", "keys": s1, "options": options or {}})
    ophys_project(empty_app, [run("ophys.motion_correction", {"referenceFrames": 1}), run("ophys.detect_rois", {"threshold": 0.25, "border": 4}),
                              run("ophys.extract_signals"), run("ophys.compute_dff"), run("ophys.image_stats"),
                              ("entities.update", {"entityType": "session", "key": s1[0], "values": {"frame_rate": 20}})])
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    page.locator(".grid-table tbody tr[data-id]").first.locator("td.key").first.click()
    page.wait_for_selector(".drawer.open li[data-variable='RoiSignals_Dff'] .plot-data")
    assert page.locator(".drawer li[data-variable='TwoPhotonSeries_Corrected'] .plot-data").count() == 0
    page.click(".drawer li[data-variable='RoiSignals_Dff'] .plot-data")
    page.wait_for_selector(".traces-dialog .trace-roi-list li:has-text('ROI 3')")   # columns named by the ROIs
    assert page.locator(".trace-roi-list li").all_inner_texts() == ["ROI 1", "ROI 2", "ROI 3"]
    assert "40 frames at 20 Hz" in page.locator(".trace-status").inner_text()   # the session's frame_rate: seconds along the bottom
    page.click(".trace-roi-list li[data-column='2']", modifiers=["Control"])   # two ROIs at once
    wait_until(lambda: page.locator(".trace-roi-list li.selected").count() == 2)
    page.click(".trace-variable:has-text('RoiSignals_MeanF') input")   # a second panel
    wait_until(lambda: page.evaluate("document.querySelector('.traces-dialog .trace-canvas').style.height") == f"{2 * 150 + 22}px")
    page.click(".trace-roi-list li[data-column='0']")   # one ROI again; then the arrow keys move
    wait_until(lambda: page.locator(".trace-roi-list li.selected").all_inner_texts() == ["ROI 1"])
    page.keyboard.press("ArrowDown")
    wait_until(lambda: page.locator(".trace-roi-list li.selected").all_inner_texts() == ["ROI 2"])
    box = page.locator(".traces-dialog .trace-canvas").bounding_box()
    page.mouse.move(box["x"] + 100, box["y"] + 60)   # drag across to zoom
    wait_until(lambda: " s (frame " in page.locator(".traces-dialog .trace-readout").inner_text())
    page.mouse.down()
    page.mouse.move(box["x"] + 300, box["y"] + 60, steps=5)
    page.mouse.up()
    page.wait_for_selector(".trace-status:has-text('double-click for all')")
    # the signal viewer's event annotator: a drag marks an event of the ROI, kept with the session
    page.click(".trace-mark")
    page.mouse.move(box["x"] + 150, box["y"] + 60)
    page.mouse.down()
    page.mouse.move(box["x"] + 250, box["y"] + 60, steps=5)
    page.mouse.up()
    page.fill(".dialog.narrow input", "burst")
    page.click(".dialog.narrow .dialog-foot button:has-text('OK')")
    page.wait_for_selector(".trace-events li:has-text('ROI 2'):has-text('burst')")
    import json
    events = lambda: json.loads(empty_app["api"].handle({"id": 7, "method": "modules.data", "params": {"module": "ophys", "name": "trace_events"}})["result"]["text"])["events"]
    marked = events()[0]
    assert (marked["entityType"], marked["column"], marked["roi"], marked["label"]) == ("session", 1, 2, "burst") and marked["stop"] > marked["start"]
    page.click(".trace-roi-list li[data-column='0']")   # another ROI's events only
    wait_until(lambda: page.locator(".trace-events li").count() == 0)
    page.click(".trace-roi-list li[data-column='1']")
    page.wait_for_selector(".trace-events li:has-text('burst')")
    page.click(".trace-events li .remove-event")
    wait_until(lambda: events() == [])
    page.locator(".traces-dialog .dialog-head button[title='Close']").click()

    # time series: the per-frame image stats and the motion shifts, their columns named
    page.click(".drawer li[data-variable='FrameStats'] .plot-data")
    page.wait_for_selector(".traces-dialog .trace-roi-list li:has-text('std')")
    assert page.locator(".trace-roi-list li").all_inner_texts() == ["mean", "min", "max", "std"]
    assert page.locator(".traces-dialog .trace-variable").all_inner_texts() == ["FrameStats", "MotionCorrectionShifts"]
    page.locator(".traces-dialog .dialog-head button[title='Close']").click()

    page.click(".drawer li[data-variable='TwoPhotonSeries_Corrected'] .view-data")
    page.wait_for_selector(".viewer-dialog .viewer-status:has-text('3 ROIs')")
    page.wait_for_selector(".viewer-signal-hint:has-text('Select an ROI')")
    page.click(".viewer-roi-list li[data-roi='2']")
    page.wait_for_selector(".viewer-signal-hint:has-text('ROI 2')")
    box = page.locator(".viewer-signal .trace-canvas").bounding_box()
    page.mouse.click(box["x"] + box["width"] - 13, box["y"] + 40)   # the end of the trace: the last frame
    page.wait_for_selector(".viewer-frame:text-is('40 / 40')")
    # live: the ROI's pixels read from the stack now (rois.signal); an ROI added since extraction falls back to it
    page.select_option(".viewer-signal-pick", "__live__")
    page.wait_for_selector(".viewer-signal-hint:has-text('ROI 2 · live from the stack')")
    page.select_option(".viewer-signal-pick", "RoiSignals_Dff")
    page.click(".viewer-add")
    image = page.locator(".viewer-canvas").bounding_box()
    page.mouse.click(image["x"] + image["width"] * 28.5 / 32, image["y"] + image["height"] * 28.5 / 32)
    page.wait_for_selector(".viewer-status:has-text('4 ROIs')")
    page.wait_for_selector(".viewer-signal-hint:has-text('ROI 4 · live from the stack')")
    # find ROIs with a segmentation method from the viewer: the ROIs are read again
    page.click(".viewer-find-rois")
    page.click(".menu .item:has-text('Detect ROIs')")
    page.fill(".dialog .field:has-text('Correlation threshold') input", "0.25")
    page.fill(".dialog .field:has-text('Border left out') input", "4")
    page.click(".dialog .btn.primary:has-text('Find ROIs')")
    page.wait_for_selector(".toast:has-text('ROIs found')")
    page.wait_for_selector(".viewer-status:has-text('3 ROIs')")
    page.locator(".viewer-dialog .dialog-head button[title='Close']").click()


def test_view_a_stack_with_channels_and_planes(empty_app, page):
    api = ophys_project(empty_app, [("dataVariables.save", {"document": {
        "schemaType": "nansen.dataVariable", "schemaVersion": "0.1.0", "name": "TwoPhotonSeries_ScanImage", "entityType": "session",
        "dataLocation": "raw", "filePattern": "scanimage", "fileAdapter": "ophys.scanimage_tiff", "dataType": "ImageStack"}})])
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    page.locator(".grid-table tbody tr[data-id]").nth(3).locator("td.key").first.click()   # s4: 2 channels x 2 planes
    page.wait_for_selector(".drawer.open li[data-variable='TwoPhotonSeries_ScanImage'] .view-data")
    page.click(".drawer li[data-variable='TwoPhotonSeries_ScanImage'] .view-data")
    page.wait_for_selector(".viewer-dialog .viewer-status:has-text('16 × 64')")
    assert page.locator(".viewer-channel").is_visible() and page.locator(".viewer-plane").is_visible()
    assert page.locator(".viewer-channel option").all_inner_texts() == ["Channel 1", "Channel 2"]
    first = page.evaluate("Array.from(document.querySelector('.viewer-canvas').getContext('2d').getImageData(0, 0, 64, 16).data).join()")
    page.select_option(".viewer-channel", "1")
    page.select_option(".viewer-plane", "1")
    wait_until(lambda: page.evaluate("Array.from(document.querySelector('.viewer-canvas').getContext('2d').getImageData(0, 0, 64, 16).data).join()") != first)
    page.locator(".viewer-dialog .dialog-head button[title='Close']").click()


CANVAS_RGB = """(() => {
    const c = document.querySelector('.viewer-canvas'), d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data, rgb = [];
    for (let i = 0; i < d.length; i += 4) rgb.push([d[i], d[i + 1], d[i + 2]]);
    return {width: c.width, height: c.height, rgb};
})()"""


def png_size(path):
    with open(path, "rb") as file:
        head = file.read(24)
    return int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")


def test_channels_in_colour_and_planes_side_by_side(empty_app, page):   # imviewer's channel colours and volume display
    ophys_project(empty_app, [("dataVariables.save", {"document": {
        "schemaType": "nansen.dataVariable", "schemaVersion": "0.1.0", "name": "TwoPhotonSeries_ScanImage", "entityType": "session",
        "dataLocation": "raw", "filePattern": "scanimage", "fileAdapter": "ophys.scanimage_tiff", "dataType": "ImageStack"}})])
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    page.locator(".grid-table tbody tr[data-id]").nth(3).locator("td.key").first.click()   # s4: 2 channels x 2 planes of 16 x 64
    page.wait_for_selector(".drawer.open li[data-variable='TwoPhotonSeries_ScanImage'] .view-data")
    page.click(".drawer li[data-variable='TwoPhotonSeries_ScanImage'] .view-data")
    page.wait_for_selector(".viewer-dialog .viewer-status:has-text('16 × 64')")
    rgb = lambda: page.evaluate(CANVAS_RGB)

    # a stack with channels opens with them together, in dev's colours for two: red and cyan
    page.wait_for_selector(".viewer-composite:checked")
    assert page.locator(".viewer-channel-toggle").count() == 2
    assert page.locator(".viewer-channel-color").evaluate_all("els => els.map((e) => e.value)") == ["#ff0000", "#00ffff"]
    wait_until(lambda: any(r != g for r, g, b in rgb()["rgb"]))
    assert all(g == b for r, g, b in rgb()["rgb"])
    page.uncheck(".viewer-channel-toggle[data-channel='1'] .viewer-channel-shown")   # channel 2 hidden: red only
    wait_until(lambda: all(g == 0 and b == 0 for r, g, b in rgb()["rgb"]))
    assert any(r > 0 for r, g, b in rgb()["rgb"])
    page.locator(".viewer-channel-toggle[data-channel='0'] .viewer-channel-color").fill("#00ff00")   # channel 1 in green
    wait_until(lambda: all(r == 0 and b == 0 for r, g, b in rgb()["rgb"]) and any(g > 0 for r, g, b in rgb()["rgb"]))
    page.uncheck(".viewer-composite")   # one channel again, in the colormap
    wait_until(lambda: all(r == g == b for r, g, b in rgb()["rgb"]))
    assert not page.locator(".viewer-channel-strip").is_visible()

    # the planes side by side, labelled, 10 pixels apart; their maximum and mean are on the montage's one scale
    page.select_option(".viewer-volume", "montage")
    page.wait_for_selector(".viewer-status:has-text('16 × 64 · 2 planes side by side')")
    montage = rgb()
    assert (montage["width"], montage["height"]) == (2 * 64 + 10, 16)
    assert page.evaluate("document.querySelector('.viewer-canvas').dataset.tiles") == "2"
    assert page.locator(".viewer-plane").is_disabled()
    values = [row[0] for row in montage["rgb"]]
    one = [values[y * 138 + x] for y in range(16) for x in range(64)]
    two = [values[y * 138 + 74 + x] for y in range(16) for x in range(64)]
    assert all(values[y * 138 + x] == 0 for y in range(16) for x in range(64, 74))
    page.select_option(".viewer-volume", "max")
    page.wait_for_selector(".viewer-status:has-text('maximum of 2 planes')")
    assert [row[0] for row in rgb()["rgb"]] == [max(a, b) for a, b in zip(one, two)]
    page.select_option(".viewer-volume", "mean")
    page.wait_for_selector(".viewer-status:has-text('mean of 2 planes')")
    assert [row[0] for row in rgb()["rgb"]] == [int((a + b) / 2 + 0.5) for a, b in zip(one, two)]

    # the channels in colour on the montage too, and the PNG is what is shown
    page.select_option(".viewer-volume", "montage")
    page.check(".viewer-composite")
    wait_until(lambda: rgb()["width"] == 138 and any(r != g or g != b for r, g, b in rgb()["rgb"]))
    with page.expect_download() as download:
        page.click(".viewer-export")
        page.click(".menu .item:has-text('Image as PNG')")
    assert download.value.suggested_filename.endswith("_TwoPhotonSeries_ScanImage_frame1_planes.png")
    assert png_size(download.value.path()) == (138 * 7, 16 * 7)
    page.click(".viewer-export")   # and the video's frames
    page.click(".menu .item:has-text('Video')")
    page.fill(".video-dialog .field:has-text('Last frame') input", "3")
    with page.expect_download() as download:
        page.click(".video-dialog .dialog-foot button:has-text('Record')")
    assert download.value.suggested_filename.endswith("_frames1-3.webm")
    page.select_option(".viewer-volume", "single")   # one plane again, the plane picker back
    page.wait_for_selector(".viewer-status:not(:has-text('planes'))")
    assert rgb()["width"] == 64 and not page.locator(".viewer-plane").is_disabled()
    page.locator(".viewer-dialog .dialog-head button[title='Close']").click()


def test_rois_are_shown_and_edited_with_one_plane_only(empty_app, page):
    s1 = {"subject_id": "m1", "session_id": "s1"}
    ophys_project(empty_app, [
        ("dataVariables.save", {"document": {"schemaType": "nansen.dataVariable", "schemaVersion": "0.1.0", "name": "TwoPhotonSeries_Planes",
                                             "entityType": "session", "dataLocation": "processed", "subfolder": "ophys",
                                             "fileName": "TwoPhotonSeries_Planes.npy", "fileAdapter": "npy", "dataType": "ImageStack"}}),
        ("methods.run", {"methodId": "ophys.deinterleave", "entityType": "session", "keys": [s1],
                         "options": {"channels": 1, "planes": 2, "output": "TwoPhotonSeries_Planes"}}),
        ("rois.update", {"entityType": "session", "key": s1, "variable": "RoiArray", "plane": 0, "imageSize": [32, 32],
                         "add": [{"pixels": [[10, 10], [10, 11], [11, 10], [11, 11]]}]})])
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    page.locator(".grid-table tbody tr[data-id]").first.locator("td.key").first.click()
    page.wait_for_selector(".drawer.open li[data-variable='TwoPhotonSeries_Planes'] .view-data")
    page.click(".drawer li[data-variable='TwoPhotonSeries_Planes'] .view-data")
    page.wait_for_selector(".viewer-dialog .viewer-status:has-text('32 × 32 · 1 ROIs')")
    assert not page.locator(".viewer-composite-label").is_visible()   # one channel: no colours to choose
    page.click(".viewer-add")
    page.select_option(".viewer-volume", "montage")   # the ROIs are of plane 1: hidden, and the tools put away
    page.wait_for_selector(".viewer-status:text-is('32 × 32 · 2 planes side by side')")
    assert not page.locator(".viewer-roi-panel").is_visible()
    assert page.locator(".viewer-add.active").count() == 0
    box = page.locator(".viewer-canvas").bounding_box()
    page.mouse.click(box["x"] + box["width"] * 0.8, box["y"] + box["height"] / 2)   # a click adds nothing
    page.mouse.move(box["x"] + box["width"] * 0.8, box["y"] + box["height"] / 2)
    page.wait_for_selector(".viewer-where:has-text('plane 2')")
    page.select_option(".viewer-volume", "single")
    page.wait_for_selector(".viewer-status:text-is('32 × 32 · 1 ROIs')")
    assert page.locator(".viewer-roi-list li").count() == 1
    page.locator(".viewer-dialog .dialog-head button[title='Close']").click()


def test_signals_of_every_plane_follow_the_roi_on_its_plane(empty_app, page):
    # every plane in one run (plane 0): one ROI file with places, and a signal column per ROI in the file's order
    s1 = [{"subject_id": "m1", "session_id": "s1"}]
    run = lambda method, **options: ("methods.run", {"methodId": method, "entityType": "session", "keys": s1, "options": options})
    variable = lambda name: ("dataVariables.save", {"document": {"schemaType": "nansen.dataVariable", "schemaVersion": "0.1.0", "name": name,
                                                                 "entityType": "session", "dataLocation": "processed", "subfolder": "ophys",
                                                                 "fileName": name + ".npy", "fileAdapter": "npy", "dataType": "ImageStack"}})
    ophys_project(empty_app, [variable("TwoPhotonSeries_Planes"), variable("TwoPhotonSeries_PlanesCorrected"),
                              run("ophys.deinterleave", channels=1, planes=2, output="TwoPhotonSeries_Planes"),
                              run("ophys.motion_correction", stack="TwoPhotonSeries_Planes", plane=0, referenceFrames=1, maxShift=8,
                                  output="TwoPhotonSeries_PlanesCorrected", shiftsOutput=""),
                              run("ophys.detect_rois", stack="TwoPhotonSeries_PlanesCorrected", plane=0, threshold=0.25, border=5, minSize=10),
                              run("ophys.extract_signals", stack="TwoPhotonSeries_PlanesCorrected", plane=0), run("ophys.compute_dff")])
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    page.locator(".grid-table tbody tr[data-id]").first.locator("td.key").first.click()
    page.wait_for_selector(".drawer.open li[data-variable='TwoPhotonSeries_PlanesCorrected'] .view-data")
    page.click(".drawer li[data-variable='TwoPhotonSeries_PlanesCorrected'] .view-data")
    page.wait_for_selector(".viewer-dialog .viewer-status:has-text('3 ROIs')")
    page.select_option(".viewer-plane", "1")   # the second plane: its own ROIs, 4 to 6
    page.wait_for_selector(".viewer-roi-list li[data-roi='5']")
    page.click(".viewer-roi-list li[data-roi='5']")
    page.wait_for_selector(".viewer-signal-hint:has-text('ROI 5')")
    assert "live" not in page.locator(".viewer-signal-hint").inner_text()   # its saved signal: column 5 of all six
    page.locator(".viewer-dialog .dialog-head button[title='Close']").click()


def test_the_roi_gallery_shows_the_classifier_images_and_statistics(empty_app, page):
    s1 = [{"subject_id": "m1", "session_id": "s1"}]
    run = lambda method, **options: ("methods.run", {"methodId": method, "entityType": "session", "keys": s1, "options": options})
    api = ophys_project(empty_app, [run("ophys.motion_correction", referenceFrames=1), run("ophys.detect_rois", threshold=0.25, border=4),
                                    run("ophys.extract_signals"), run("ophys.compute_dff"), run("ophys.roi_images", boxSize=9),
                                    ("rois.update", {"entityType": "session", "key": s1[0], "variable": "RoiArray",
                                                     "classify": [{"id": 2, "classification": "rejected"}]})])
    value = api.handle({"id": 1, "method": "data.value", "params": {"entityType": "session", "key": s1[0], "variable": "RoiImages"}})["result"]["value"]
    salient = [i for _, i in sorted(zip(value["stats"]["salience"], value["ids"]), key=lambda pair: -pair[0])]
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    page.locator(".grid-table tbody tr[data-id]").first.locator("td.key").first.click()
    page.wait_for_selector(".drawer.open li[data-variable='TwoPhotonSeries_Corrected'] .view-data")
    page.click(".drawer li[data-variable='TwoPhotonSeries_Corrected'] .view-data")
    page.wait_for_selector(".viewer-dialog .viewer-status:has-text('3 ROIs')")
    page.click(".viewer-gallery")
    page.wait_for_selector(".roi-gallery-image:not([disabled])")
    assert page.locator(".roi-gallery-image option").all_inner_texts() == ["Frame shown", "Activity-weighted mean", "Top 1% ΔF/F frames", "Local correlation"]
    assert page.evaluate("document.querySelector('.roi-tile-image').width") == 17   # the frame's crops
    page.select_option(".roi-gallery-image", "localCorrelation")
    wait_until(lambda: page.evaluate("document.querySelector('.roi-tile-image').width") == 9)   # the saved box
    page.select_option(".roi-gallery-sort", "salience")
    wait_until(lambda: [int(t) for t in page.eval_on_selector_all(".roi-tile", "els => els.map(e => e.dataset.roi)")] == salient)
    page.select_option(".roi-gallery-show", "rejected")   # dev's Show: one class
    wait_until(lambda: page.eval_on_selector_all(".roi-tile", "els => els.map(e => e.dataset.roi)") == ["2"])
    page.select_option(".roi-gallery-show", "none")
    wait_until(lambda: sorted(page.eval_on_selector_all(".roi-tile", "els => els.map(e => e.dataset.roi)")) == ["1", "3"])
    page.keyboard.press("Escape")


def test_viewer_projections_and_roi_display_options(empty_app, page):
    s1 = [{"subject_id": "m1", "session_id": "s1"}]
    ophys_project(empty_app, [
        ("methods.run", {"methodId": "ophys.motion_correction", "entityType": "session", "keys": s1, "options": {"referenceFrames": 1}}),
        ("methods.run", {"methodId": "ophys.detect_rois", "entityType": "session", "keys": s1, "options": {"threshold": 0.25, "border": 4}})])
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    page.locator(".grid-table tbody tr[data-id]").first.locator("td.key").first.click()
    page.wait_for_selector(".drawer.open li[data-variable='TwoPhotonSeries_Corrected'] .view-data")
    page.click(".drawer li[data-variable='TwoPhotonSeries_Corrected'] .view-data")
    page.wait_for_selector(".viewer-dialog .viewer-status:has-text('3 ROIs')")
    page.uncheck(".viewer-rois")
    page.select_option(".viewer-mode", "peakTime")   # imviewer's temporal colour code: hue is the time of the peak
    colourful = """() => { const d = document.querySelector('.viewer-canvas').getContext('2d').getImageData(0, 0, 32, 32).data;
        let n = 0; for (let i = 0; i < d.length; i += 4) if (Math.max(d[i], d[i + 1], d[i + 2]) - Math.min(d[i], d[i + 1], d[i + 2]) > 40) n++; return n; }"""
    wait_until(lambda: page.evaluate(colourful) > 100)
    page.select_option(".viewer-mode", "min")
    wait_until(lambda: page.evaluate(colourful) == 0)
    pixels = "Array.from(document.querySelector('.viewer-canvas').getContext('2d').getImageData(0, 0, 32, 32).data).join()"
    plain = page.evaluate(pixels)
    page.select_option(".viewer-filter", "gradient")   # imviewer's 2-D filters
    wait_until(lambda: page.evaluate(pixels) != plain)
    page.select_option(".viewer-filter", "")
    wait_until(lambda: page.evaluate(pixels) == plain)
    page.check(".viewer-rois")
    page.check(".viewer-roi-labels")   # roimanager's numbers on the ROIs
    page.wait_for_selector(".viewer-canvas[data-labels='3']")
    filled = page.evaluate(colourful)
    page.check(".viewer-roi-outlines")
    wait_until(lambda: 0 < page.evaluate(colourful) < filled)
    page.click(".viewer-grid")
    assert "active" in page.get_attribute(".viewer-grid", "class")
    page.click(".viewer-roi-list li[data-roi='1']")   # roimanager's cell types (Shift+E) and links (Shift+C)
    page.keyboard.press("Shift+E")
    page.wait_for_selector(".viewer-roi-list li[data-roi='1'] .roi-cell-type:has-text('excitatory')")
    page.click(".viewer-roi-list li[data-roi='3']", modifiers=["Control"])
    page.keyboard.press("Shift+C")
    page.wait_for_selector(".viewer-roi-list li[data-roi='3'] .roi-links:has-text('1')")
    page.check(".viewer-roi-links")
    page.wait_for_selector(".viewer-canvas[data-links='1']")
    page.click(".viewer-roi-list li[data-roi='1']")
    page.keyboard.press("Control+Z")   # undo takes the link away again, the cell type stays
    page.wait_for_selector(".viewer-roi-list li[data-roi='3']:not(:has(.roi-links))")
    assert page.locator(".viewer-roi-list li[data-roi='1'] .roi-cell-type").count() == 1
    page.select_option(".viewer-mode", "frame")
    page.click(".viewer-roi-list li[data-roi='1']")   # its signal goes under the frames
    page.click(".viewer-export")
    page.click(".menu .item:has-text('Video')")   # imviewer's ROI signal video
    page.fill(".video-dialog .field:has-text('Last frame') input", "6")
    page.fill(".video-dialog .field:has-text('Frames per second') input", "30")
    with page.expect_download() as download:
        page.click(".video-dialog .dialog-foot button:has-text('Record')")
    assert download.value.suggested_filename.endswith("_frames1-6.webm")
    import os
    assert os.path.getsize(download.value.path()) > 500
    page.locator(".viewer-dialog .dialog-head button[title='Close']").click()


def test_view_any_stack_file_from_the_file_tree(empty_app, page):
    ophys_project(empty_app)
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    page.locator(".grid-table tbody tr[data-id]").nth(3).locator("td.key").first.click()   # s4: ScanImage files
    tree = ".drawer .loc:has(.loc-head:has-text('raw'))"
    page.wait_for_selector(f"{tree} .path-list .browse")
    page.locator(f"{tree} .path-list .browse").first.click()
    page.click(f"{tree} li[data-name='rec_00001.tif'] .view-file")   # no data variable: as imviewer opens a file
    page.wait_for_selector(".viewer-dialog .viewer-status:has-text('16 × 64')")
    assert page.locator(".viewer-dialog .dialog-head").inner_text().startswith("rec_00001.tif")
    assert page.locator(".viewer-adapter option").all_inner_texts() == ["ophys.scanimage_tiff", "ophys.thorlabs_tiffs", "ophys.tiff_stack"]
    assert page.locator(".viewer-adapter").input_value() == "ophys.scanimage_tiff"
    assert page.locator(".viewer-channel").is_visible()
    page.select_option(".viewer-adapter", "ophys.tiff_stack")   # its pages, one after the other
    page.wait_for_selector(".viewer-dialog .viewer-status:has-text('36 × 32')")
    page.locator(".viewer-dialog .dialog-head button[title='Close']").click()


def test_the_viewer_shows_a_scalebar_and_the_time_the_files_give(empty_app, page):
    ophys_project(empty_app)   # session 1's SciScan recording: 30.9 frames per second, 16 µm pixels
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    page.locator(".grid-table tbody tr[data-id]").first.locator("td.key").first.click()
    page.wait_for_selector(".drawer.open li[data-variable='TwoPhotonSeries_Original'] .view-data")
    page.click(".drawer li[data-variable='TwoPhotonSeries_Original'] .view-data")
    page.wait_for_selector(".viewer-dialog .viewer-status:has-text('32 × 32')")
    assert page.locator(".viewer-frame").inner_text() == "1 / 40" and page.locator(".viewer-time").inner_text() == "0.00 s"
    page.locator(".viewer-slider").fill("9")
    page.wait_for_selector(".viewer-time:text-is('0.29 s')")   # frame 9 at 30.9 per second
    assert not page.locator(".viewer-scalebar").is_visible()
    page.click(".viewer-scalebar-toggle")
    page.wait_for_selector(".viewer-scalebar", state="visible")
    assert page.locator(".viewer-scalebar-label").inner_text() == "100 µm"   # a fifth of 512 µm, rounded down
    line = page.evaluate("document.querySelector('.viewer-scalebar-line').getBoundingClientRect().width")
    image = page.evaluate("document.querySelector('.viewer-canvas').getBoundingClientRect().width")
    assert abs(line - image * 100 / 16 / 32) < 1
    page.click(".viewer-scalebar-toggle")
    page.wait_for_selector(".viewer-scalebar", state="hidden")
    page.select_option(".viewer-mode", "mean")
    page.wait_for_selector(".viewer-frame:text-is('40 frames')")
    assert page.locator(".viewer-time").inner_text() == ""
    page.locator(".viewer-dialog .dialog-head button[title='Close']").click()


def test_fov_map_images_photos_undo_and_svg(empty_app, page):
    import json
    imageio = pytest.importorskip("imageio.v2")
    import numpy as np
    s1 = {"subject_id": "m1", "session_id": "s1"}
    run = lambda method, **options: ("methods.run", {"methodId": method, "entityType": "session", "keys": [s1], "options": options})
    api = ophys_project(empty_app, [run("ophys.motion_correction", referenceFrames=1), run("ophys.image_stats"),
                                    run("ophys.detect_rois", threshold=0.25, border=4),
                                    ("entities.update", {"entityType": "session", "key": s1, "values": {"fov_ml": 2.3, "fov_ap": -3.6}}),
                                    ("entities.update", {"entityType": "subject", "key": {"subject_id": "m1"}, "values": {"window_ml": 2, "window_ap": -2}})])
    (empty_app["folder"] / "ophys" / "images").mkdir()
    colour = np.zeros((10, 10, 3), dtype=np.uint8)
    colour[:, :, 0] = 200
    imageio.imwrite(empty_app["folder"] / "ophys" / "images" / "window.png", colour)
    page.goto(empty_app["server"].url + "#/page/ophys.fovmap")
    page.wait_for_selector(".fov-canvas")
    assert page.locator(".fov-image-variable").input_value() == "FovAverageProjection"
    page.check(".fov-images")   # each FOV's average image in its place
    page.wait_for_selector(".fov-canvas[data-images='1']")
    page.check(".fov-rois")   # fovmanager's Show ROIs: its ROIs over it
    page.wait_for_selector(".fov-canvas[data-rois='3']")
    page.click(".fov-list li[data-subject='m1']")
    page.click(".add-photo")
    page.fill(".photo-dialog input[name=path]", "images/window.png")
    page.fill(".photo-dialog input[name=width]", "4")
    page.click(".photo-dialog .dialog-foot button:has-text('OK')")
    page.wait_for_selector(".fov-canvas[data-photos='1']")
    stored = lambda: json.loads(api.handle({"id": 9, "method": "modules.data", "params": {"module": "ophys", "name": "fovmap"}})["result"]["text"])
    assert stored()["photos"][0] | {"id": None} == {"id": None, "subject": {"subject_id": "m1"}, "path": "images/window.png",
                                                     "dataLocation": None, "width": 4, "opacity": 0.7}
    # the photo is red where the window is, under the FOV marks
    red = page.evaluate("""() => { const c = document.querySelector('.fov-canvas'); const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
        let n = 0; for (let i = 0; i < d.length; i += 4) if (d[i] > 120 && d[i + 1] < 90 && d[i + 2] < 90) n++; return n; }""")
    assert red > 100
    page.click(".fov-undo")
    page.wait_for_selector(".fov-canvas[data-photos='0']")
    assert stored()["photos"] == []
    page.click(".fov-redo")
    page.wait_for_selector(".fov-canvas[data-photos='1']")
    assert len(stored()["photos"]) == 1
    page.click(".fov-list li[data-session='m1 / s1']")   # a placement is undone too: the values it had come back
    page.click(".place-fov")
    box = page.locator(".fov-canvas").bounding_box()
    page.mouse.click(box["x"] + box["width"] * (1 + 6) / 12, box["y"] + box["height"] * (7 + 1) / 16)
    wait_until(lambda: abs(api.project.table("session").get(s1)["fov_ml"] - 1) < 0.05)
    wait_until(lambda: "ML 2.3" not in page.inner_text(".fov-list li[data-session='m1 / s1']"))   # placed, and on the map
    page.keyboard.press("Control+z")
    wait_until(lambda: api.project.table("session").get(s1)["fov_ml"] == 2.3)
    with page.expect_download() as download:   # vectors for figures, as fovmanager's EPS
        page.click(".fov-export-svg")
    assert download.value.suggested_filename == "fov_map_m1.svg"
    text = open(download.value.path()).read()
    assert text.startswith("<svg") and text.count("<image") == 4 and "<path" in text and "<rect" in text   # atlas, photo, FOV image, its ROIs


def test_place_fovs_and_windows_on_the_fov_map(empty_app, page):
    api = ophys_project(empty_app)
    page.goto(empty_app["server"].url + "#/overview")
    page.wait_for_selector(".sidebar a[href='#/page/ophys.fovmap']")
    page.click(".sidebar a[href='#/page/ophys.fovmap']")
    page.wait_for_selector(".fov-canvas")
    assert page.locator(".fov-side").nth(1).locator("li").count() == 4
    box = page.locator(".fov-canvas").bounding_box()
    at = lambda ml, ap: (box["x"] + box["width"] * (ml + 6) / 12, box["y"] + box["height"] * (7 - ap) / 16)
    page.mouse.move(*at(2.31, -3.61))
    page.wait_for_selector(".fov-where:has-text('V1')")
    page.click(".fov-list li[data-session='m1 / s1']")
    page.click(".place-fov")
    page.mouse.click(*at(2.305, -3.605))
    page.wait_for_selector(".fov-list li[data-session='m1 / s1'] .sub:has-text('V1')")
    row = api.project.table("session").get({"subject_id": "m1", "session_id": "s1"})
    assert abs(row["fov_ml"] - 2.3) < 0.03 and abs(row["fov_ap"] + 3.6) < 0.03
    page.click(".fov-list li[data-subject='m1']")
    page.click(".place-window")
    page.mouse.click(*at(2, -2))
    wait_until(lambda: api.project.table("subject").get({"subject_id": "m1"}).get("window_ml") is not None)
    page.wait_for_selector(".fov-list li[data-subject='m1'] .pill")
    for material, depth, colour, where in (("AAV-GCaMP8m", "300", "green", (1.5, -1.5)), ("AAV-jRGECO1a", "", "magenta", (2.5, -2.5))):
        page.click(".place-injection")
        page.mouse.click(*at(*where))
        page.fill(".mark-dialog input[name=material]", material)
        page.fill(".mark-dialog input[name=depth]", depth)
        page.fill(".mark-dialog input[name=spread]", "400")
        page.select_option(".mark-dialog select[name=colour]", colour)
        page.click(".mark-dialog .dialog-foot button:has-text('OK')")
        page.wait_for_selector(f".fov-marks li:has-text('{material}')")
    assert page.locator(".fov-marks li[data-mark='injections-1']").inner_text().startswith("AAV-GCaMP8m · 300 µm deep")
    page.click(".place-note")
    page.mouse.click(*at(2, -3))
    page.fill(".mark-dialog input[name=text]", "blood vessel")
    page.click(".mark-dialog .dialog-foot button:has-text('OK')")
    page.wait_for_selector(".fov-marks li:has-text('blood vessel')")
    stored = api.handle({"id": 9, "method": "modules.data", "params": {"module": "ophys", "name": "fovmap"}})["result"]
    import json
    marks = json.loads(stored["text"])
    assert stored["revision"] == 3 and [m["material"] for m in marks["injections"]] == ["AAV-GCaMP8m", "AAV-jRGECO1a"]
    first = marks["injections"][0]
    assert (first["depth"], first["volume"], first["spread"], first["colour"]) == (300, None, 400, "green")
    assert marks["notes"][0]["text"] == "blood vessel" and marks["notes"][0]["subject"] == {"subject_id": "m1"}

    # edit an injection from the list; drag the note to another place; save the map
    page.click(".fov-marks li[data-mark='injections-2']")
    page.fill(".mark-dialog input[name=volume]", "50")
    page.click(".mark-dialog .dialog-foot button:has-text('OK')")
    page.wait_for_selector(".fov-marks li[data-mark='injections-2']:has-text('50 nL')")
    page.mouse.move(*at(2, -3))
    page.mouse.down()
    page.mouse.move(*at(1, -2), steps=6)
    page.mouse.up()
    stored_marks = lambda: json.loads(api.handle({"id": 10, "method": "modules.data", "params": {"module": "ophys", "name": "fovmap"}})["result"]["text"])
    wait_until(lambda: abs(stored_marks()["notes"][0]["ml"] - 1) < 0.05)
    marks = stored_marks()
    assert abs(marks["notes"][0]["ml"] - 1) < 0.05 and abs(marks["notes"][0]["ap"] + 2) < 0.05 and marks["injections"][1]["volume"] == 50
    with page.expect_download() as download:
        page.click(".fov-export")
    assert download.value.suggested_filename == "fov_map_m1.png"
    page.click(".fov-marks li[data-mark='injections-1'] .remove-mark")
    page.wait_for_selector(".fov-marks li[data-mark='injections-1']", state="detached")


def test_review_rois_across_sessions(empty_app, page):
    s1, s3 = {"subject_id": "m1", "session_id": "s1"}, {"subject_id": "m1", "session_id": "s3"}
    run = lambda method_id, keys, options=None: ("methods.run", {"methodId": method_id, "entityType": "session", "keys": keys, "options": options or {}})
    api = ophys_project(empty_app, [
        run("ophys.motion_correction", [s1, s3], {"referenceFrames": 1}),
        run("ophys.image_stats", [s1, s3]),
        run("ophys.detect_rois", [s1], {"threshold": 0.25, "border": 4}),
        run("ophys.align_sessions", [s1, s3])])
    page.goto(empty_app["server"].url + "#/page/ophys.roireview")
    page.wait_for_selector(".rr-table tbody tr")
    assert page.locator(".rr-table tbody tr").count() == 3
    assert page.locator(".rr-table thead th").count() == 3  # ROI, s1, s3
    assert page.locator(".rr-table tbody tr").first.locator("canvas.rr-crop").count() == 2
    page.click(".rr-table tbody tr[data-roi='2']")
    page.keyboard.press("r")
    page.wait_for_selector(".rr-table tr[data-roi='2'] .pill:has-text('rejected')")
    for key in (s1, s3):
        document = api.project.load(api.project.entity("session", key), "RoiArray", cached=False)
        assert [r.get("classification") for r in document["rois"]] == [None, "rejected", None]
    # edit one session's ROI from the review: its viewer opens with the ROI selected
    load = lambda key: api.project.load(api.project.entity("session", key), "RoiArray", cached=False)["rois"]
    before = {tuple(k.values()): sorted(map(tuple, load(k)[0]["pixels"])) for k in (s1, s3)}
    page.locator(".rr-table tr[data-roi='1'] td").nth(2).dblclick()   # ROI 1 in s3
    page.wait_for_selector(".viewer-dialog .viewer-roi-list li[data-roi='1'].selected")
    page.keyboard.press("Alt+ArrowDown")
    def moved():
        try:
            return sorted(map(tuple, load(s3)[0]["pixels"])) == [(r + 1, c) for r, c in before[("m1", "s3")]]
        except ValueError:   # a JSON file read while the app writes it
            return False
    wait_until(moved)
    page.locator(".viewer-dialog .dialog-head button[title='Close']").click()
    page.wait_for_selector(".rr-table tbody tr")
    assert sorted(map(tuple, load(s1)[0]["pixels"])) == before[("m1", "s1")]   # the other session's is as it was


def test_install_and_remove_add_ons_from_the_settings_page(empty_app, page, monkeypatch):
    import io
    import zipfile

    from nansen import addons

    data = io.BytesIO()
    with zipfile.ZipFile(data, "w") as z:
        z.writestr("NoRMCorre-master/normcorre.m", "function M = normcorre(Y, o)\nM = Y;\nend\n")
    monkeypatch.setattr(addons, "_download", lambda url: data.getvalue())
    api = empty_app["api"]
    folder = empty_app["folder"] / "addons"
    api.handle({"id": 1, "method": "settings.save", "params": {"settings": {"addons": {"folder": str(folder)}}}})
    page.goto(empty_app["server"].url + "#/settings")
    page.wait_for_selector(".addon-list li[data-addon='normcorre']")
    assert page.locator(".addon-list li[data-addon='caiman'] .install-addon").count() == 0   # conda: install it yourself
    page.click(".addon-list li[data-addon='normcorre'] .install-addon")
    page.wait_for_selector(".addon-list li[data-addon='normcorre'] .remove-addon")
    assert (folder / "normcorre" / "normcorre.m").is_file()
    page.click(".addon-list li[data-addon='normcorre'] .remove-addon")
    page.click(".dialog-foot button:has-text('Remove')")
    page.wait_for_selector(".addon-list li[data-addon='normcorre'] .install-addon")
    assert not (folder / "normcorre").exists()


def test_preview_a_method_on_the_first_frames(empty_app, page):
    s1 = {"subject_id": "m1", "session_id": "s1"}
    api = ophys_project(empty_app)
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    page.locator(".grid-table tbody tr[data-id]").first.locator("td.sel input").click()
    page.click(".selection-bar button:has-text('Run method')")
    page.locator(".method-item").filter(has=page.locator(".t:text-is('Correct motion')")).click()
    page.wait_for_selector(".method-detail:has(h3:text-is('Correct motion')) .preset-row")
    page.fill(".field:has-text('Frames in the first reference') input", "1")
    page.click(".dialog-foot button:has-text('Preview')")
    page.wait_for_selector(".preview-output[data-name='TwoPhotonSeries_Corrected'] canvas.preview-image")
    assert '"frames": 20' in page.locator(".preview-result").inner_text()
    assert "32 × 32 × 20" in page.locator(".preview-output[data-name='TwoPhotonSeries_Corrected']").inner_text()
    page.fill(".preview-frames", "5")
    page.click(".preview-again")
    page.wait_for_selector(".preview-output[data-name='MotionCorrectionShifts']:has-text('5 × 2')")
    status = api.handle({"id": 9, "method": "data.status", "params": {"entityType": "session", "key": s1}})["result"]
    assert [d["files"] for d in status if d["name"] in ("TwoPhotonSeries_Corrected", "MotionCorrectionShifts")] == [[], []]
    # tuning: a change of an option in the preview runs it again, and the options go back to the run dialog
    previewed = lambda response: "/api" in response.url and "methods.preview" in (response.request.post_data or "")
    with page.expect_response(previewed) as answer:
        page.fill(".preview-options .field:has-text('Largest shift') input", "8")
    assert '"maxShift": 8' in answer.value.request.post_data.replace('"maxShift":8', '"maxShift": 8')
    page.wait_for_selector(".preview-output[data-name='MotionCorrectionShifts']:has-text('5 × 2')")
    page.locator(".preview-dialog .dialog-foot button:has-text('Use these options')").click()
    assert page.locator(".dialog-foot button:has-text('Run now')").count() == 1   # back in the run dialog
    assert page.locator(".method-detail .field:has-text('Largest shift') input").input_value() == "8"
    assert page.locator(".method-detail .field:has-text('Frames in the first reference') input").input_value() == "1"


def test_polygons_grow_shrink_undo_and_projections_in_the_viewer(empty_app, page):
    s1 = [{"subject_id": "m1", "session_id": "s1"}]
    run = lambda method, options=None: ("methods.run", {"methodId": method, "entityType": "session", "keys": s1, "options": options or {}})
    api = ophys_project(empty_app, [run("ophys.motion_correction", {"referenceFrames": 1}),
                                    run("ophys.detect_rois", {"threshold": 0.25, "border": 4}),
                                    run("ophys.extract_signals"), run("ophys.compute_dff")])
    import time as clock

    def rois():
        for _ in range(50):
            try:
                return api.project.load(api.project.entity("session", s1[0]), "RoiArray", cached=False)["rois"]
            except ValueError:
                clock.sleep(0.05)
    pixels = lambda roi: sorted(tuple(p) for p in roi["pixels"])
    page.goto(empty_app["server"].url + "#/entities/session")
    page.wait_for_selector(".grid-table tbody td.key")
    page.locator(".grid-table tbody tr[data-id]").first.locator("td.key").first.click()
    page.click(".drawer.open li[data-variable='TwoPhotonSeries_Corrected'] .view-data")
    page.wait_for_selector(".viewer-dialog .viewer-status:has-text('3 ROIs')")

    # the std and correlation projections, in a colormap
    page.select_option(".viewer-mode", "std")
    page.wait_for_selector(".viewer-frame:text-is('40 frames')")
    page.select_option(".viewer-mode", "correlation")
    page.select_option(".viewer-colormap", "viridis")
    wait_until(lambda: page.evaluate("(() => { const d = document.querySelector('.viewer-canvas').getContext('2d').getImageData(0, 0, 32, 32).data;"
                                     " for (let i = 0; i < d.length; i += 4) if (d[i] !== d[i + 1] || d[i + 1] !== d[i + 2]) return true; return false; })()"))
    box = page.locator(".viewer-canvas").bounding_box()
    at = lambda row, column: (box["x"] + box["width"] * column / 32, box["y"] + box["height"] * row / 32)

    # the ruler: a line dragged across the image, its length in pixels and angle
    page.click(".viewer-measure")
    page.mouse.move(*at(4, 2))
    page.mouse.down()
    page.mouse.move(*at(4, 12), steps=4)
    page.mouse.up()
    wait_until(lambda: abs(float(page.locator(".viewer-measurement").get_attribute("data-length") or 0) - 10) < 0.2)
    assert page.locator(".viewer-measurement").inner_text().endswith(" px · 0°")
    page.click(".viewer-measure")   # off: the line goes
    wait_until(lambda: page.locator(".viewer-measurement").inner_text() == "")

    # a polygon: three corners, closed by clicking the first again
    page.click(".viewer-polygon")
    for corner in [(26, 2), (26, 8), (31, 5), (26, 2)]:
        page.mouse.click(*at(*corner))
    page.wait_for_selector(".viewer-roi-list li[data-roi='4'].selected")
    triangle = pixels(rois()[3])
    assert (26, 4) in triangle and (28, 5) in triangle and all(26 <= r <= 30 and 2 <= c <= 7 for r, c in triangle)   # pixels whose centre is inside
    page.keyboard.press("Escape")

    # grow it, shrink it back, undo, redo
    page.click(".roi-grow")
    wait_until(lambda: len(rois()[3]["pixels"]) > len(triangle))
    grown = pixels(rois()[3])
    assert set(triangle) < set(grown)
    page.click(".roi-shrink")
    wait_until(lambda: len(rois()[3]["pixels"]) < len(grown))
    page.keyboard.press("Control+z")
    wait_until(lambda: pixels(rois()[3]) == grown)
    page.keyboard.press("Control+z")
    wait_until(lambda: pixels(rois()[3]) == triangle)
    page.click(".roi-redo")
    wait_until(lambda: pixels(rois()[3]) == grown)
    page.click(".roi-delete")
    wait_until(lambda: len(rois()) == 3)
    page.click(".roi-undo")   # the deleted ROI comes back with its id
    wait_until(lambda: [r["id"] for r in rois()] == [1, 2, 3, 4] and pixels(rois()[3]) == grown)

    # the gallery sorted by the ROIs' largest ΔF/F
    page.click(".viewer-gallery")
    page.wait_for_selector(".roi-gallery-dialog .roi-tile")
    page.select_option(".roi-gallery-sort", "peak")
    dff = api.project.load(api.project.entity("session", s1[0]), "RoiSignals_Dff", cached=False)
    import numpy as np
    order = [i + 1 for i in np.argsort(-np.asarray(dff).max(axis=0), kind="stable")]
    wait_until(lambda: page.eval_on_selector_all(".roi-tile", "els => els.map(e => Number(e.dataset.roi))")[:3] == order)


def test_install_a_shared_project_from_git(empty_app, page):
    import shutil
    import subprocess
    if shutil.which("git") is None:
        pytest.skip("git is not installed")
    from nansen import Project
    shared = empty_app["folder"] / "shared"
    Project.create(shared, "Shared")
    for args in (["init", "-q"], ["add", "."], ["commit", "-q", "-m", "a project"]):
        subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], cwd=shared, check=True, capture_output=True)
    page.goto(empty_app["server"].url + "#/projects")
    page.click(".action-card:has-text('Install a shared project')")
    page.fill(".install-url", str(shared))
    page.fill(".install-folder", str(empty_app["folder"] / "mine"))
    page.click(".dialog .btn.primary:has-text('Install')")
    page.wait_for_selector(".toast:has-text('Installed')")
    page.wait_for_selector(".card li:has-text('Shared')")
    assert (empty_app["folder"] / "mine" / "project.nansen.json").is_file()


def test_dff_explorer_matches_compute_dff_and_queues_its_settings(empty_app, page):
    s1 = {"subject_id": "m1", "session_id": "s1"}
    run = lambda method, **options: ("methods.run", {"methodId": method, "entityType": "session", "keys": [s1], "options": options})
    api = ophys_project(empty_app, [run("ophys.motion_correction", referenceFrames=1), run("ophys.detect_rois", threshold=0.25, border=4),
                                    run("ophys.extract_signals")])
    computed = lambda **options: api.handle({"id": 1, "method": "methods.run", "params": {"methodId": "ophys.compute_dff", "entityType": "session",
                                                                                         "keys": [s1], "options": options}})["result"]
    peak = lambda: float(page.locator(".dx-stats").get_attribute("data-peak"))
    page.goto(empty_app["server"].url + "#/page/ophys.dffexplorer")
    page.wait_for_selector(".dx-peak")
    assert page.locator(".dx-roi option").all_inner_texts() == ["ROI 1", "ROI 2", "ROI 3"]
    expected = computed()["results"][0]["maxDff"]   # the page computes ΔF/F as compute_dff does (from 4-decimal signals)
    assert abs(peak() - expected[0]) < 1e-3 * max(1, abs(expected[0]))
    page.select_option(".dx-roi", "2")
    wait_until(lambda: abs(peak() - expected[2]) < 1e-3 * max(1, abs(expected[2])))
    page.locator("input.dx-baselineWindow").fill("10")   # a running baseline, and the chen2013 method
    page.select_option(".dx-method", "chen2013")
    expected = computed(baselineWindow=10, method="chen2013")["results"][0]["maxDff"]
    wait_until(lambda: abs(peak() - expected[2]) < 1e-3 * max(1, abs(expected[2])))
    page.click(".dx-queue-one")   # the settings, run as compute_dff
    wait_until(lambda: len(api.handle({"id": 2, "method": "tasks.list", "params": {}})["result"]) == 1)
    task = api.handle({"id": 3, "method": "tasks.list", "params": {}})["result"][0]
    assert task["method"]["id"] == "ophys.compute_dff" and task["options"]["values"]["baselineWindow"] == 10 and task["options"]["values"]["method"] == "chen2013"
