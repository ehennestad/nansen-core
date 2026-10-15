/* The Viewer page (#/view/<id>): what `nansen view` (Python) or nansen.view (MATLAB) was given, with no project, as
 * dev's imviewer(array), imviewer(file), signalviewer and roimanager opened from the command line.
 *
 * view.list names them; an image stack opens in the stack viewer (view.frame, its ROIs read only) and signals in the
 * trace plot (view.traces). The page lists them all, and opens the one its address names.
 */
(function () {
  "use strict";
  const N = window.N;
  const { h } = N;

  /** Open a viewable: a stack in the stack viewer, signals in the trace plot. */
  N.openViewable = function (app, viewable) {
    if (viewable.kind === "signals") return N.views.traces(app, null, null, [], { viewable });
    return N.views.stackViewer(app, null, null, viewable.name, [], [], { viewable });
  };

  N.views.viewables = async function (app, content, id) {
    let viewables = [];
    try { viewables = await app.client.request("view.list"); } catch (error) { N.showError(error); }
    app.viewables = viewables;
    const open = (v) => { app.replace(`#/view/${v.id}`); N.openViewable(app, v); };
    const item = (v) => h("li.viewable", { dataset: { viewable: v.id } },
      N.icon(v.kind === "signals" ? "activity" : "image"),
      h("div.grow", h("div", h("strong", v.name)), h("div.muted.mono", v.path || (v.kind === "signals" ? "signals (an array)" : "an array"))),
      v.rois ? h("span.pill.plain", "ROIs, read only") : null,
      h("span.pill.plain", v.kind === "signals" ? "Signals" : "Image stack"),
      h("button.btn.small.open-viewable", { on: { click: () => open(v) } }, N.icon("eye", 14), "Open"));
    N.fill(content,
      h("div.hero", h("div", h("h1", "Viewer"),
        h("p", "What this app was opened to view, without a project: image stacks in the stack viewer (projections, binning, " +
          "colour channels, export), with their ROIs read only, and signals in the trace plot."))),
      viewables.length ? h("ul.list.card.viewable-list", viewables.map(item))
        : h("div.card", h("div.empty", N.icon("image", 36), h("h3", "Nothing to view"),
          h("div", "Open files or arrays with nansen view <file> (Python) or nansen.view(data) (MATLAB)."))));
    const chosen = viewables.find((v) => v.id === id);
    if (chosen) setTimeout(() => N.openViewable(app, chosen), 0);   // once the page is shown
  };
})();
