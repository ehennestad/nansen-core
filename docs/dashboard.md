# The dashboard against a modern web UI

This page holds the dashboard (`ui/`, and the ophys module's pages in `modules/ophys/dashboard/`) to a stated standard of a modern web interface, and says how it measures up. Each result is a measurement or a pointer into the code, not an impression. The screenshots at the end were taken with Playwright and Chromium from the demo project (`nansen demo`) and, for the viewer pages, from the ophys conformance project after motion correction, ROI detection, signal extraction and session alignment, in the light and the dark theme.

## The standard and the results

| # | Criterion | Standard | Result |
|---|---|---|---|
| 1 | Responsive layout | No sideways scrolling of the page at 1024 px and at a phone's 390 px; the navigation stays reachable | **Pass** |
| 2 | Themes | Light and dark, following the system's setting, with a manual override | **Pass** |
| 3 | Contrast | WCAG 2.1 AA: 4.5:1 for text, 3:1 for large text, in both themes | **Pass** after the fixes below (was **fail**) |
| 4 | Keyboard | Every control reachable with Tab and its focus visible; dialogs and menus closed with Esc; shortcuts for the main pages | **Pass** after the fixes below (was **partial**) |
| 5 | Navigation | No full page loads between pages (hash routing); Back and Forward work | **Pass** |
| 6 | Live updates | The backend pushes changes; the page does not poll | **Partial** |
| 7 | Components | One set of buttons, dialogs, menus, toasts and a drawer, used everywhere | **Pass** |
| 8 | States | Loading, empty and error states that say what is going on and what to do | **Partial** |
| 9 | Large tables | 5,000 rows usable: a virtualized grid, first rows within about a second, sorting and searching without a stall | **Pass** |
| 10 | Offline | Nothing loaded from a CDN or another host at run time, no web fonts | **Pass** |

Besides these: no page logged a console error in either theme (`console-errors` was empty for all 14 views), every button without text has a name (its `title`), and the same page runs in MATLAB's `uihtml` (`test_dashboard_talks_through_the_matlab_bridge` plays MATLAB's part).

## How it was measured

A Playwright script (Chromium 1194, headless, 1280 × 800 unless said otherwise) served the demo project and the ophys project with `nansen.server.serve`, opened each view and measured it in the page:

- **Contrast**: every element with its own visible text in the viewport; its colour and its effective background (the background colours of its ancestors, composited, with the element's opacity applied to the text); the WCAG relative luminance ratio; the threshold 3:1 when the text is 24 px or 18.66 px bold, else 4.5:1. Disabled controls are left out, as WCAG allows. Text drawn on canvases (the image, the traces) is not text to the page and is not measured.
- **Responsive**: `document.documentElement.scrollWidth - innerWidth` on each page, at 1024 × 768 and at 390 × 844 (a phone, with touch).
- **Keyboard**: 40 presses of Tab on the session table, recording the focused element and whether it shows an outline or a focus shadow; Esc on a dialog, the drawer and a menu; a menu opened with Enter; Tab inside a dialog.
- **Navigation**: a value set on `window`, then seven clicks in the sidebar; the value must survive and `performance.getEntriesByType('navigation')` must stay at one document load.
- **Live updates**: the requests the Tasks page makes over 10 s with nothing happening, and how long a task queued from outside the page (by the backend directly) takes to appear.
- **Large tables**: projects of 5,000 and 20,000 sessions made with `Project.create`; the time of `entities.list`, the time from navigating to the table to its first rows, the rows in the DOM, the time to draw after a jump of the scroll position (20 jumps, each measured over two animation frames), sorting a numeric column and searching.
- **Offline**: every request to another host than the app's own aborted and recorded, on five pages.

The two checks that found failures are now Playwright tests in `python/tests/test_ui.py`: `test_text_has_enough_contrast_in_either_theme` (light and dark) and `test_menus_and_dialogs_work_from_the_keyboard`.

## 1. Responsive layout: pass

| Width | Pages | Page wider than the window | Sidebar |
|---|---|---|---|
| 1024 px | overview, table, drawer, run dialog, tasks, pipelines, data, notes, settings, projects | 0 px on every page | shown |
| 390 px | the same 10 | 0 px on every page | behind the menu button |

Below 860 px the sidebar slides in over the page from a menu button in the top bar (`ui/css/app.css` `@media (max-width: 860px)`, `ui/js/app.js` `menu-button`; `test_a_narrow_window_has_the_sidebar_behind_a_menu`). Two-column cards fall to one column below 1100 px, forms below 600 to 760 px. The entity table keeps its columns and scrolls sideways inside its own frame, as a spreadsheet does; the page itself does not move. The image viewer and the FOV map are usable on a tablet but cramped on a phone, which is not a target for them.

![The overview at 390 px](images/dashboard-overview-phone.webp) ![The table at 390 px](images/dashboard-table-phone.webp) ![The drawer at 390 px](images/dashboard-drawer-phone.webp)

## 2. Themes: pass

The colours are tokens on `:root` (`ui/css/app.css`), redefined under `@media (prefers-color-scheme: dark)` and again under `:root[data-theme="dark"]`, with `color-scheme` set, so form controls and scrollbars follow. Emulating the system's scheme gave a body background of `rgb(246, 247, 249)` in light and `rgb(11, 16, 32)` in dark with no `data-theme` set. Settings has a theme choice (Follow the system, Light, Dark) kept per browser (`ui/js/app.js` `applyTheme`; `test_settings_page` checks the dark choice). The module pages use the same tokens. Every view below is shown in both.

## 3. Contrast: pass after fixing

The first measurement found text below AA in both themes, the same few styles on every page (32 distinct failing styles in light, 34 in dark):

| Where | Light | Dark |
|---|---|---|
| The sidebar's muted text: section names, counts, the footer, "Project" | 3.07–3.75 | 3.61–4.13 |
| Muted text on a selected row or on a chip (keys of ignored rows, counts, units) | 4.42–4.48 | 4.11–4.33 |
| Green status pills ("complete", "completed", "available") | 3.55 | pass |
| White text on primary buttons ("Run method", "Add to queue", "Open") | pass | 3.31 |

The fix changes tokens only (`ui/css/app.css`): `--sidebar-muted` `#64748b` → `#8b9ab0`; `--text-3` `#667085` → `#5f6b7e` (light) and `#7c889b` → `#8a95a8` (dark); `--good` `#079455` → `#067647` and `--bad` `#d92d20` → `#c4271b` (light; its red pill computes to 4.44, though none was on screen); and a new `--on-accent` for text on accent backgrounds, white in light and `#0b1020` in dark, used by primary buttons and the active tool buttons of the viewer, the signal plot and the FOV map. The look is unchanged apart from slightly stronger secondary text.

After it: **0 failures among 1,403 text elements per theme**, on 14 views (overview, table, drawer, run dialog, tasks, pipelines, data, notes, settings, projects, viewer, signals, FOV map, ROI review). The lowest ratio left is 4.8.

## 4. Keyboard: pass after fixing

What worked: all 40 Tab stops on the table page showed a focus ring (the browser's, or the inputs' accent shadow); Esc closed dialogs and the drawer and left the search box; `?` lists the shortcuts, `/` searches, `g` then a letter or a number goes to a page or a table (`ui/js/app.js` `bindShortcuts`; `test_lock_editing_and_keyboard_shortcuts`). The viewer has imviewer's and roimanager's keys (`ui/js/viewer.js` `viewerKey`, `roiKey`).

What did not:

- A column's menu button was `visibility: hidden` until the header was hovered, so Tab never reached it: no column menu (sort, filter, hide, reset, remove) from the keyboard.
- Menu items were plain `div`s: not focusable, no arrow keys, and Esc did not close a menu.
- A dialog took no focus and did not keep it: Tab went on into the page behind it. It had no `role="dialog"`.
- An entity's drawer opened only with a click on its row.
- Toasts were not announced to screen readers.

The fix (`ui/js/components.js`, `ui/js/entitygrid.js`, `ui/css/app.css`, `ui/index.html`): the column menu button is transparent instead of hidden, so it is reachable and shows when focused; a menu (`role="menu"`) focuses its first item, the arrows, Home and End move, Enter or Space picks, Esc or Tab close it and give the focus back to its button, and Esc closes only the menu, not a dialog under it; a dialog has `role="dialog"`, `aria-modal` and `aria-labelledby`, takes the focus when it opens (itself, so a viewer's keys keep working), keeps Tab and Shift+Tab inside it, and gives the focus back when it closes; Enter on a row's key cell opens its drawer; the toasts are a polite live region. Measured again: menus open from the keyboard with the focus inside, Esc closes them, the focus stays in a dialog through 30 presses of Tab, and the full Playwright suite still passes.

Gaps left: a cell is edited after a click, not from the keyboard; drawing an ROI on the image is done with the pointer, as in dev (selecting, classifying, moving, growing, merging and deleting ROIs have keys).

## 5. Navigation: pass

Pages are `#/…` routes rendered in place (`ui/js/app.js`: a `hashchange` listener and `render`). After seven clicks in the sidebar the value set on `window` was still there, the document had been loaded once, and Back went to the previous page. A view whose data arrives after the user has moved on does not draw over the new page (`app.js` `render`).

## 6. Live updates: partial

The backend pushes events: rows, notes, views, pipelines, scans, task changes and task log lines (`docs/reference/protocol.md`, Events). Python sends them as server-sent events (`/events`, `ui/js/transport.js` `EventSource`), MATLAB as `uihtml` events. With nothing running, the Tasks page made **no requests in 10 s**, and a task queued from outside the page appeared **20–60 ms** later (four runs). The table, the notes, the drawer and the task log follow events in the same way.

While a task is queued or running, the Tasks page also reads `tasks.list` and `queue.status` every 1.5 s (14 requests in 6 s; `ui/js/views.js` `app.viewTimer`). This is deliberate: the task files are the truth, and a worker of the other language or another process writes them without sending this app any event. Removing the poll needs the backend to watch the tasks folder, which is not a small fix.

## 7. Components: pass

One set, in `ui/js/components.js` and `ui/css/app.css`: `N.toast`, `N.showError`, `N.dialog` (with `N.confirm` and `N.prompt`), `N.menu`, `N.drawer`, `N.statusPill`, and the classes `.btn` (`.primary`, `.ghost`, `.small`, `.icon`, `.danger`), `.chip`, `.pill`, `.card`, `.input`, `.switch`; icons are inline SVG (`N.icon`); options forms are drawn from the methods' JSON Schema (`ui/js/schemaform.js`). The module pages use the same `N` functions and tokens; the FOV map and the explorers add a few rules of their own for their layouts.

## 8. States: partial

- **Loading**: "Connecting…" before the backend answers, and "Cannot reach the NANSEN core" with the reason if it does not (`ui/js/app.js`); "Loading…" in the viewer, the signal plot and the add-on list.
- **Empty**: each list says what is missing and what to do: no tasks ("Select entities in a table and run a method"), no pipelines, no notes, no projects, a table with no rows ("No entities yet. Scan the stores, then sync."), a search with no match ("No rows match the filter."), an unknown table ("No entity type nosuchtype").
- **Errors**: a toast with the title of what failed, the protocol's error code and its message (`N.showError`), for every request a page makes.

The gap: a page waits for its data before it draws, and the previous page stays until then. That is quick for most pages, but opening a table of 20,000 rows takes 2.4 to 3 s with no sign that it is loading.

![An empty state](images/dashboard-empty-state.webp) ![An error toast](images/dashboard-error-toast.webp)

## 9. Large tables: pass

The grid draws only the rows in view and ten above and below, with spacer rows for the rest (`ui/js/entitygrid.js` `renderBody`).

| Rows | `entities.list` | Navigation to first rows | Rows in the DOM | Draw after a scroll jump (median; max) | Sort | Search |
|---|---|---|---|---|---|---|
| 5,000 | 0.26–0.31 s | 0.91–0.92 s | 28 | 33 ms; 39–50 ms | 0.06–0.07 s | 0.14 s |
| 20,000 | 1.09–1.18 s | 2.4–3.0 s | 28 | 33–46 ms; 39–68 ms | 0.06–0.09 s | 0.14–0.15 s |

The ranges are over four runs on the same machine. A draw is measured over two animation frames, so 33 ms is the floor at 60 Hz: at 5,000 rows scrolling costs nothing beyond the frame. Most of the time to the first rows is the backend listing the rows and the JSON between them; the [architecture](architecture.md#open-questions) notes paging `entities.list` for hundreds of thousands of entities.

## 10. Offline: pass

With every request to another host aborted, the overview, the table, tasks, data and settings loaded and worked, and **no request to another host was attempted**. There are no web fonts (the stylesheet uses the system's fonts) and no CDN: `ui/index.html` loads the app's own scripts in order, with no build step, so the same files work from MATLAB's `uihtml`. The only addresses outside the app are the Help menu's pages, which open in the system's browser (`app.openUrl`).

## Screenshots

Light on the left, dark on the right.

**Overview**

![Overview, light](images/dashboard-overview-light.webp) ![Overview, dark](images/dashboard-overview-dark.webp)

**An entity table** (sessions)

![Table, light](images/dashboard-table-light.webp) ![Table, dark](images/dashboard-table-dark.webp)

**An entity's drawer**: values, locations, files, data variables, pipeline, notes

![Drawer, light](images/dashboard-drawer-light.webp) ![Drawer, dark](images/dashboard-drawer-dark.webp)

**The run dialog**: methods by category, presets, options from the method's schema, preview, run now or queue

![Run dialog, light](images/dashboard-run-dialog-light.webp) ![Run dialog, dark](images/dashboard-run-dialog-dark.webp)

**Tasks**: the queue, a task's details and log

![Tasks, light](images/dashboard-tasks-light.webp) ![Tasks, dark](images/dashboard-tasks-dark.webp)

**Pipelines**

![Pipelines, light](images/dashboard-pipelines-light.webp) ![Pipelines, dark](images/dashboard-pipelines-dark.webp)

**Data**: locations, data variables, fragments, methods

![Data, light](images/dashboard-data-light.webp) ![Data, dark](images/dashboard-data-dark.webp)

**Notes**

![Notes, light](images/dashboard-notes-light.webp) ![Notes, dark](images/dashboard-notes-dark.webp)

**Settings**

![Settings, light](images/dashboard-settings-light.webp) ![Settings, dark](images/dashboard-settings-dark.webp)

**Projects**

![Projects, light](images/dashboard-projects-light.webp) ![Projects, dark](images/dashboard-projects-dark.webp)

**The stack viewer with ROIs**: the mean image, the ROI list and tools, the selected ROI's ΔF/F

![Viewer, light](images/dashboard-viewer-light.webp) ![Viewer, dark](images/dashboard-viewer-dark.webp)

**The signal plot**

![Signals, light](images/dashboard-traces-light.webp) ![Signals, dark](images/dashboard-traces-dark.webp)

**The FOV map** (ophys module): the atlas, a FOV with its average image and ROIs

![FOV map, light](images/dashboard-fovmap-light.webp) ![FOV map, dark](images/dashboard-fovmap-dark.webp)

**ROI review** (ophys module): each ROI in every aligned session

![ROI review, light](images/dashboard-roireview-light.webp) ![ROI review, dark](images/dashboard-roireview-dark.webp)
