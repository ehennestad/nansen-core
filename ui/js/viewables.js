/* The Viewer page (#/view/<id>): what `nansen view` (Python) or nansen.view (MATLAB) was given, with no project, as
 * dev's imviewer(array), imviewer(file), signalviewer and roimanager opened from the command line.
 *
 * view.list names them; an image stack opens in the stack viewer (view.frame; ROIs drawn and edited on it are saved to
 * its ROI file, view.updateRois) and signals in the trace plot (view.traces). Run… runs a built-in method on a stack
 * (view.run), as dev's imviewer runs Align Images: what it saves is written beside the stack, and the stacks and ROIs
 * among it are listed here too. The page lists them all, and opens the one its address names.
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

  /** The methods a stack runs (view.methods), by category, for a menu under the button. */
  async function runMenu(app, button, viewable, done) {
    let methods = [];
    try { methods = await app.client.request("view.methods"); } catch (error) { N.showError(error, "Could not list the methods"); return; }
    if (!methods.length) { N.toast("No methods", "No built-in module has a method for image stacks in this language", "error"); return; }
    const categories = [...new Set(methods.map((m) => m.category || "Other"))].sort();
    N.menu(button, categories.flatMap((category) => [{ heading: category.split("/").pop() }].concat(methods
      .filter((m) => (m.category || "Other") === category).sort((a, b) => a.title.localeCompare(b.title))
      .map((m) => ({ label: m.title, onClick: () => runWith(app, viewable, m, done) })))));
  }

  /** The method's options (its stack option left out: the viewable is its stack), then the run and what it saved. */
  function runWith(app, viewable, method, done) {
    const schema = method.options || { type: "object", properties: {} };
    const properties = { ...(schema.properties || {}) };
    delete properties.stack;
    const form = N.schemaForm({ ...schema, properties }, {});
    N.dialog({
      title: `${method.title} · ${viewable.name}`, narrow: true,
      content: h("div.view-run-form", h("p.muted", method.description || ""),
        h("p.muted", viewable.path ? "What it saves is written beside the file, and the stacks and ROIs among it are listed here."
          : "What it saves is kept while the app is open, and the stacks and ROIs among it are listed here."), form.el),
      buttons: [{ label: "Cancel" }, { label: "Run", kind: "primary", icon: "play", onClick: async (close) => {
        const problems = form.validate();
        if (problems.length) { N.toast("Check the options", problems.join("; "), "error"); return; }
        close();
        N.toast("Running", `${method.title} on ${viewable.name}…`);
        try {
          const result = await app.client.request("view.run", { viewable: viewable.id, methodId: method.id, options: form.getValue() });
          await done();
          showOutputs(app, viewable, method, result);
        } catch (error) { N.showError(error, `${method.title} failed`); }
      } }],
    });
  }

  /** What a run saved: each variable, where it was written, and Open for those that are viewable. */
  function showOutputs(app, viewable, method, result) {
    const listed = new Map((app.viewables || []).map((v) => [v.id, v]));
    const row = (output) => h("li", { dataset: { variable: output.variable } },
      h("div.grow", h("div", h("strong", output.variable), " ", h("span.pill.plain", output.kind === "rois" ? "ROIs" : output.kind === "stack" ? "Image stack" : "Data")),
        h("div.muted.mono", output.path || "kept in memory")),
      output.viewable && listed.has(output.viewable) ? h("button.btn.small.open-output", { on: { click: () => {
        dialog.close();
        app.replace(`#/view/${output.viewable}`);
        N.openViewable(app, listed.get(output.viewable));
      } } }, N.icon("eye", 14), "Open") : null);
    const dialog = N.dialog({
      title: `${method.title} · ${viewable.name}`, narrow: true,
      content: h("div.view-run-result", { style: { padding: "14px 18px" } },
        result.outputs.length ? h("ul.list.view-run-outputs", result.outputs.map(row)) : h("p.muted", "It saved nothing."),
        result.log && result.log.length ? h("pre.view-run-log.mono", result.log.join("\n")) : null),
      buttons: [{ label: "Close" }],
    });
  }

  N.views.viewables = async function (app, content, id) {
    let viewables = [];
    try { viewables = await app.client.request("view.list"); } catch (error) { N.showError(error); }
    app.viewables = viewables;
    const open = (v) => { app.replace(`#/view/${v.id}`); N.openViewable(app, v); };
    const refresh = async () => {   // after a run: what it made, listed here and in the sidebar
      await N.views.viewables(app, content, null);
      app.renderNav();
    };
    const item = (v) => h("li.viewable", { dataset: { viewable: v.id } },
      N.icon(v.kind === "signals" ? "activity" : "image"),
      h("div.grow", h("div", h("strong", v.name)), h("div.muted.mono", v.path || (v.kind === "signals" ? "signals (an array)" : "an array"))),
      v.rois ? h("span.pill.plain", { title: v.roiFile ? `Saved to ${v.roiFile}` : "Kept while the app is open" }, "ROIs") : null,
      h("span.pill.plain", v.kind === "signals" ? "Signals" : "Image stack"),
      v.kind === "stack" ? h("button.btn.small.run-viewable", { title: "Run a method on the stack: motion correction, ROI detection, ...",
        on: { click: (event) => runMenu(app, event.currentTarget, v, refresh) } }, N.icon("zap", 14), "Run…") : null,
      h("button.btn.small.open-viewable", { on: { click: () => open(v) } }, N.icon("eye", 14), "Open"));
    N.fill(content,
      h("div.hero", h("div", h("h1", "Viewer"),
        h("p", "What this app was opened to view, without a project: image stacks in the stack viewer (projections, binning, " +
          "colour channels, export), where ROIs are drawn, found and saved beside the file, methods such as motion correction " +
          "run on them, and signals in the trace plot."))),
      viewables.length ? h("ul.list.card.viewable-list", viewables.map(item))
        : h("div.card", h("div.empty", N.icon("image", 36), h("h3", "Nothing to view"),
          h("div", "Open files or arrays with nansen view <file> (Python) or nansen.view(data) (MATLAB)."))));
    const chosen = viewables.find((v) => v.id === id);
    if (chosen) setTimeout(() => N.openViewable(app, chosen), 0);   // once the page is shown
  };
})();
