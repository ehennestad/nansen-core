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
