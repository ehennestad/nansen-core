/* The ophys module's deconvolution explorer (dev's CaimanDeconvolution signal viewer plugin): one ROI's ΔF/F with its
 * denoised calcium and spikes as the settings of ophys.deconvolve change.
 *
 * The page computes nothing itself: the ΔF/F column comes from data.traces, and the denoised and spike traces from
 * methods.preview with a column, which runs the method in the backend (in whichever language serves the app) on that
 * one column of the traces, writing nothing, and gives its outputs of one column thinned as data.traces thins the
 * ΔF/F. The settings are then run as ophys.deconvolve on this session or all of them (tasks.submit).
 */
"use strict";
const { h } = N;

const METHOD = "ophys.deconvolve";
const MAX_POINTS = 2000;

if (!document.getElementById("ophys-deconvolutionexplorer-style")) {
  const style = document.createElement("style");
  style.id = "ophys-deconvolutionexplorer-style";
  style.textContent = `
    .cx-layout { display: grid; grid-template-columns: 280px 1fr; gap: 16px; align-items: start; }
    .cx-side { display: flex; flex-direction: column; gap: 10px; padding: 14px; }
    .cx-side label { display: flex; flex-direction: column; gap: 4px; font-size: 12px; color: var(--muted); }
    .cx-side label .cx-value { color: var(--text); font-variant-numeric: tabular-nums; }
    .cx-main { padding: 14px; min-width: 0; }
    .cx-stats { display: flex; gap: 18px; flex-wrap: wrap; margin-bottom: 8px; font-size: 13px; }
    .cx-legend { display: flex; gap: 14px; font-size: 12px; color: var(--muted); margin-bottom: 4px; }
    .cx-legend i { display: inline-block; width: 14px; height: 3px; border-radius: 2px; margin-right: 5px; vertical-align: middle; }
    .cx-actions { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 4px; }
    @media (max-width: 760px) { .cx-layout { grid-template-columns: 1fr; } }
  `;
  document.head.appendChild(style);
}

const NAMES = ["ΔF/F", "Denoised", "Spikes"];

N.registerPage({
  id: "ophys.deconvolutionexplorer", title: "Deconvolution explorer", icon: "activity",
  async render(app, el) {
    const variables = await app.client.request("dataVariables.list", {});
    const signalVariables = variables.filter((v) => v.dataType === "RoiSignals");
    const method = (await app.client.request("methods.list", {})).find((m) => m.id === METHOD);
    if (!signalVariables.length || !method) {
      N.fill(el, h("div.empty", h("h3", "No ROI signals yet"),
        h("p.muted", "Run the tool Set up two-photon variables (ophys.setup_variables), then detect ROIs, extract their signals and compute their ΔF/F in a session.")));
      return;
    }
    const schema = method.options.properties;
    const options = Object.fromEntries(Object.entries(schema).map(([name, p]) => [name, p.default]));
    const names = signalVariables.map((v) => v.name);
    if (!names.includes(options.signals)) options.signals = names[0];
    const entityType = signalVariables.find((v) => v.name === options.signals).entityType;
    const rows = (await app.client.request("entities.list", { entityType })).rows;
    const state = { key: rows.length ? rows[0].key : null, column: 0, count: 0, traces: null, rois: null, previewing: 0 };

    const status = h("span.muted.cx-status", "");
    const stats = h("div.cx-stats");
    const legend = h("div.cx-legend", NAMES.map((name, k) => h("span", h("i", { style: { background: N.traceColor(k) } }), name)));
    const plot = N.tracePlot({ height: 220 });
    const sessionPick = h("select.input.cx-session", { on: { change: () => { state.key = rows[Number(sessionPick.value)].key; state.column = 0; load(); } } },
      rows.map((r, i) => h("option", { value: i }, N.fmt.key(r.key))));
    const roiPick = h("select.input.cx-roi", { on: { change: () => { state.column = Number(roiPick.value); load(); } } });
    const signalsPick = h("select.input.cx-signals", { on: { change: () => { options.signals = signalsPick.value; state.column = 0; load(); } } },
      names.map((n) => h("option", { value: n, selected: n === options.signals }, n)));
    // A setting as a slider, or a number for the frame rate, with its value beside its name
    const setting = (name, { step, max = null }) => {
      const p = schema[name];
      const value = h("span.cx-value", String(options[name]));
      const input = h("input" + (max === null ? ".input" : ""), { type: max === null ? "number" : "range", min: p.minimum ?? p.exclusiveMinimum ?? 0,
        max: max ?? undefined, step, value: options[name], on: { input: () => {
          const v = Number(input.value);
          if (!Number.isFinite(v) || v < (p.minimum ?? 0) || (p.exclusiveMinimum !== undefined && v <= p.exclusiveMinimum)) return;
          options[name] = v;
          value.textContent = String(v);
          later();
        } } });
      input.classList.add("cx-" + name);
      return h("label", h("span", p.title || name, " ", value), input, p.description ? h("span.muted", p.description) : null);
    };

    /** The plot of what the last preview and traces gave. */
    function draw(preview) {
      const frames = state.traces.frames;
      const outputOf = (name) => (preview.outputs.find((o) => o.name === name) || {}).trace;
      const denoised = outputOf(options.denoisedOutput), spikes = outputOf(options.output);
      const columns = [{ column: 0, values: state.traces.values }];
      if (denoised) columns.push({ column: 1, values: denoised.values });
      if (spikes) columns.push({ column: 2, values: spikes.values });
      plot.draw({ frames, start: 0, step: state.traces.step, points: state.traces.values.length, frameRate: state.traces.frameRate,
        traces: [{ variable: roiPick.selectedOptions[0] ? roiPick.selectedOptions[0].textContent : "", count: columns.length, columns }] }, NAMES);
      const result = preview.results[0] || {};
      const first = (list) => (Array.isArray(list) ? list[0] : list);
      const noise = first(result.noise), spikeSum = first(result.spikeSum);
      const rate = options.frameRate || state.traces.frameRate;
      const decay = rate ? Math.exp(-1 / (options.tauDecay * rate)) : null;
      stats.dataset.spikeSum = Number.isFinite(spikeSum) ? String(spikeSum) : "";
      N.fill(stats, h("span", "Spikes (sum) ", h("b.cx-spikes", Number.isFinite(spikeSum) ? N.fmt.number(spikeSum) : "—")),
        h("span", "Noise σ ", h("b.cx-noise", Number.isFinite(noise) ? N.fmt.number(noise) : "—")),
        h("span", "Decay per frame ", h("b", decay ? decay.toFixed(4) : "—")),
        h("span.muted", `${frames} frames` + (state.traces.frameRate ? ` at ${N.fmt.number(state.traces.frameRate)} Hz` : "")));
    }

    /** Run the method on the ROI's column with the settings (methods.preview), and draw what it gives. */
    async function preview() {
      if (!state.traces) return;
      const ticket = ++state.previewing;
      status.textContent = "Deconvolving…";
      try {
        const result = await app.client.request("methods.preview", { methodId: METHOD, entityType, key: state.key, options: { ...options },
          column: state.column, maxPoints: MAX_POINTS });
        if (ticket !== state.previewing) return;   // the settings changed since
        draw(result);
        status.textContent = "";
      } catch (error) {
        if (ticket !== state.previewing) return;
        N.fill(stats);
        status.textContent = (error.code ? `[${error.code}] ` : "") + (error.message || String(error));
      }
    }
    let timer = null;
    const later = () => { clearTimeout(timer); timer = setTimeout(preview, 150); };

    async function load() {
      if (!state.key) return;
      status.textContent = "Loading…";
      try {
        const first = await app.client.request("data.traces", { entityType, key: state.key, variables: [options.signals], columns: [0], maxPoints: 1,
          ...(variables.some((v) => v.name === "RoiArray" && v.entityType === entityType) ? { rois: "RoiArray" } : {}) });
        state.count = first.traces[0].count;
        state.rois = first.rois || null;
        state.column = Math.min(state.column, state.count - 1);
        const result = await app.client.request("data.traces", { entityType, key: state.key, variables: [options.signals], columns: [state.column],
          maxPoints: MAX_POINTS });
        state.traces = { frames: result.frames, step: result.step, values: result.traces[0].columns[0].values, frameRate: result.frameRate };
        const columns = N.roiColumns(state.rois, state.count);
        const label = (c) => { if (columns) for (const [id, at] of columns) if (at === c) return `ROI ${id}`; return `Column ${c + 1}`; };
        N.fill(roiPick, Array.from({ length: state.count }, (_, c) => h("option", { value: c, selected: c === state.column }, label(c))));
        await preview();
      } catch (error) {
        state.traces = null;
        plot.draw(null);
        N.fill(stats);
        status.textContent = (error.code ? `[${error.code}] ` : "") + (error.message || String(error));
      }
    }

    async function queue(keys) {
      try {
        await app.client.request("tasks.submit", { methodId: METHOD, entityType, keys, options: { ...options } });
        N.toast("Deconvolution queued", `${keys.length} ${keys.length === 1 ? N.titleCase(entityType).toLowerCase() : "entities"} with these settings: see the task queue`);
      } catch (error) { N.showError(error, "Could not queue it"); }
    }

    const onKey = (event) => {
      if (!el.isConnected) { document.removeEventListener("keydown", onKey); return; }
      if (["INPUT", "SELECT", "TEXTAREA"].includes(event.target.tagName) || !state.count) return;
      if (event.key === "ArrowDown" || event.key === "j") state.column = Math.min(state.count - 1, state.column + 1);
      else if (event.key === "ArrowUp" || event.key === "k") state.column = Math.max(0, state.column - 1);
      else return;
      event.preventDefault();
      roiPick.value = String(state.column);
      load();
    };
    document.addEventListener("keydown", onKey);
    window.addEventListener("resize", plot.redraw);

    N.fill(el,
      h("div.page-head", h("div", h("h1", "Deconvolution explorer"),
        h("p", `One ROI's ΔF/F with its denoised calcium and spikes as the settings change, as dev's deconvolution viewer: ${method.title} (${METHOD}) runs on that ROI in the backend, writing nothing. ↑ and ↓ go through the ROIs; the settings are then run on the sessions.`))),
      rows.length ? h("div.cx-layout",
        h("div.card.cx-side",
          h("label", "Session", sessionPick), h("label", "ROI", roiPick),
          h("label", schema.signals.title || "Traces", signalsPick),
          setting("frameRate", { step: "any" }), setting("tauDecay", { step: 0.01, max: 3 }), setting("sparsity", { step: 0.05, max: 5 }),
          h("div.cx-actions",
            h("button.btn.primary.small.cx-queue-one", { on: { click: () => queue([state.key]) } }, "Run on this session"),
            h("button.btn.small.cx-queue-all", { on: { click: () => queue(rows.map((r) => r.key)) } }, `Run on all ${rows.length}`))),
        h("div.card.cx-main", stats, legend, plot.el, status))
        : h("div.empty", h("h3", `No ${N.titleCase(entityType).toLowerCase()} entities`)));
    await load();
  },
});
