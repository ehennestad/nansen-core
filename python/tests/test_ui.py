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
    cell.click()
    page.select_option(".grid-table td.editing select", "poor")
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
    assert rows().count() == bleaching

    page.click(".toolbar button:has(.view-name)")
    page.click(".menu .item:has-text('Save as a new view')")
    page.fill(".dialog.narrow input", "Bleaching")
    page.click(".dialog.narrow .dialog-foot button:has-text('OK')")
    wait_until(lambda: [v["name"] for v in views()] == ["Bleaching"])
    assert views()[0]["filters"] == [{"column": "description", "op": "in", "values": ["Bleaching after 20 min"]}]

    page.click(".filter-bar .filter-chip button")
    assert rows().count() == 14
    page.click(".toolbar button:has(.view-name)")
    page.click(".menu .item:has-text('Bleaching')")
    assert rows().count() == bleaching
    page.click(".toolbar button:has(.view-name)")
    page.click(".menu .item:has-text('All rows')")
    assert rows().count() == 14

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


def test_add_edit_and_delete_a_data_variable(empty_app, page):
    api = empty_app["api"]
    api.handle({"id": 1, "method": "demo.create", "params": {"path": str(empty_app["folder"] / "demo")}})
    names = lambda: [v["name"] for v in api.handle({"id": 2, "method": "dataVariables.list"})["result"]]
    assert "config" not in names()
    page.goto(empty_app["server"].url + "#/data")
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

    page.click(".data-variables tr[data-variable='config'] .edit-variable")
    page.wait_for_selector(".dialog .variable-pattern option[value='acquisition_config']", state="attached")
    assert page.locator(".dialog .variable-name").is_disabled()
    assert page.locator(".dialog .variable-location").input_value() == "raw"
    page.fill(".dialog .variable-title", "Acquisition config")
    page.click(".dialog-foot button:has-text('Save')")
    page.wait_for_selector(".data-variables tr[data-variable='config']:has-text('Acquisition config')")

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
    page.wait_for_selector(".dialog .config-text")
    text = page.locator(".dialog .config-text").input_value()
    assert text == config.read_text()
    page.fill(".dialog .config-text", "{")
    assert page.locator(".dialog .config-status").inner_text().startswith("Not valid JSON")
    page.click(".dialog-foot button:has-text('Save')")
    page.wait_for_selector(".dialog .form-message:has-text('dataset-invalid')")
    assert config.read_text() == text
    page.fill(".dialog .config-text", text.replace('"displayName": "Processed"', '"displayName": "Processed data"'))
    page.click(".dialog-foot button:has-text('Save')")
    page.wait_for_selector(".data-locations td:has-text('Processed data')")
    assert '"displayName": "Processed data"' in config.read_text()


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
    page.locator(".auto-start span").click()
    wait_until(lambda: api.handle({"id": 1, "method": "settings.get"})["result"]["queue"]["autoStart"] is False)
    page.select_option(".theme-select", "dark")
    assert page.evaluate("document.documentElement.dataset.theme") == "dark"
    page.reload()
    page.wait_for_selector(".auto-start")
    assert not page.locator(".auto-start input").is_checked()


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
    page.click(".place-injection")
    page.mouse.click(*at(1.5, -1.5))
    wait_until(lambda: api.project.table("subject").get({"subject_id": "m1"}).get("injection_ml") is not None)


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
