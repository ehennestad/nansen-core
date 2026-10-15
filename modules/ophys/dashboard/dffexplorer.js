/* The ophys module's ΔF/F explorer (dev's DffExplorer): one ROI's signal, its baseline and its ΔF/F as the settings change.
 *
 * The page reads the ROI's signal and neuropil columns (data.traces, every frame) and computes ΔF/F here as
 * ophys.compute_dff does (the same methods, percentiles and windows), so a setting shows at once. The settings
 * are then run as ophys.compute_dff on this session or all of them (tasks.submit), in whichever language runs them.
 */
"use strict";
const { h } = N;

if (!document.getElementById("ophys-dffexplorer-style")) {
  const style = document.createElement("style");
  style.id = "ophys-dffexplorer-style";
  style.textContent = `
    .dx-layout { display: grid; grid-template-columns: 280px 1fr; gap: 16px; align-items: start; }
    .dx-side { display: flex; flex-direction: column; gap: 10px; padding: 14px; }
    .dx-side label { display: flex; flex-direction: column; gap: 4px; font-size: 12px; color: var(--muted); }
    .dx-side label .dx-value { color: var(--text); font-variant-numeric: tabular-nums; }
    .dx-side .dx-row { display: flex; gap: 8px; align-items: center; }
    .dx-main { padding: 14px; min-width: 0; }
    .dx-stats { display: flex; gap: 18px; margin-bottom: 8px; font-size: 13px; }
    .dx-actions { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 4px; }
    @media (max-width: 760px) { .dx-layout { grid-template-columns: 1fr; } }
  `;
  document.head.appendChild(style);
}

/** The percentile of values (NaN for none, or if any is NaN), interpolating linearly at (n - 1) * p / 100, as NumPy and _percentile. */
function percentile(values, p) {
  if (!values.length || values.some(Number.isNaN)) return NaN;
  const ordered = Float64Array.from(values).sort();
  const position = (ordered.length - 1) * p / 100;
  const low = Math.floor(position), high = Math.min(low + 1, ordered.length - 1);
  return ordered[low] + (position - low) * (ordered[high] - ordered[low]);
}

/** As ophys' moving_percentile for one column: over all frames (window 0), or the window frames centred on each, cut at the ends. */
function movingPercentile(trace, p, window) {
  const frames = trace.length;
  if (window === 0 || window >= 2 * frames) return new Array(frames).fill(percentile(trace, p));
  const out = new Array(frames);
  for (let t = 0; t < frames; t++) {
    const start = Math.max(0, t - Math.floor(window / 2));
    out[t] = percentile(trace.slice(start, Math.min(frames, t - Math.floor(window / 2) + window)), p);
  }
  return out;
}

/** ΔF/F of one ROI as ophys.compute_dff computes it: {f, baseline, dff}. */
function dffOf(signal, neuropil, o) {
  const k = o.neuropilFactor, p = o.baselinePercentile, w = o.baselineWindow;
  let f = signal, baseline, dff;
  if (o.method === "dffMinusNeuropil") {
    baseline = movingPercentile(signal, p, w);
    const n0 = movingPercentile(neuropil, p, w);
    dff = signal.map((v, t) => (v - baseline[t]) / baseline[t] - k * (neuropil[t] - n0[t]) / n0[t]);
  } else {
    if (neuropil) {
      f = signal.map((v, t) => v - k * neuropil[t]);
      if (o.method === "chen2013") {
        const n0 = movingPercentile(neuropil, p, w);
        f = f.map((v, t) => v + n0[t]);
      }
    }
    baseline = movingPercentile(f, p, w);
    dff = f.map((v, t) => (v - baseline[t]) / baseline[t]);
  }
  if (o.correctionWindow > 0) {
    const drift = movingPercentile(dff, o.correctionPercentile, o.correctionWindow);
    dff = dff.map((v, t) => v - drift[t]);
  }
  return { f, baseline, dff };
}

const finiteOrNull = (v) => (Number.isFinite(v) ? Math.floor(v * 10000 + 0.5) / 10000 : null);

N.registerPage({
  id: "ophys.dffexplorer", title: "ΔF/F explorer", icon: "activity",
  async render(app, el) {
    const variables = await app.client.request("dataVariables.list", {});
    const signalVariables = variables.filter((v) => v.dataType === "RoiSignals");
    const method = (await app.client.request("methods.list", {})).find((m) => m.id === "ophys.compute_dff");
    if (!signalVariables.length || !method) {
      N.fill(el, h("div.empty", h("h3", "No ROI signals yet"),
        h("p.muted", "Run the tool Set up two-photon variables (ophys.setup_variables), then detect ROIs and extract their signals in a session.")));
      return;
    }
    const schema = method.options.properties;
    const options = Object.fromEntries(Object.entries(schema).map(([name, p]) => [name, p.default]));
    const names = signalVariables.map((v) => v.name);
    if (!names.includes(options.signals)) options.signals = names[0];
    if (options.neuropil && !names.includes(options.neuropil)) options.neuropil = "";
    const entityType = signalVariables.find((v) => v.name === options.signals).entityType;
    const rows = (await app.client.request("entities.list", { entityType })).rows;
    const state = { key: rows.length ? rows[0].key : null, column: 0, count: 0, signal: null, neuropil: null, frameRate: null, rois: null };

    const status = h("span.muted.dx-status", "");
    const stats = h("div.dx-stats");
    const plot = N.tracePlot({ height: 150 });
    const sessionPick = h("select.input.dx-session", { on: { change: () => { state.key = rows[Number(sessionPick.value)].key; state.column = 0; load(); } } },
      rows.map((r, i) => h("option", { value: i }, N.fmt.key(r.key))));
    const roiPick = h("select.input.dx-roi", { on: { change: () => { state.column = Number(roiPick.value); load(); } } });
    const variablePick = (name, allowNone) => h("select.input.dx-" + name, { on: { change: (event) => { options[name] = event.target.value; load(); } } },
      (allowNone ? [h("option", { value: "", selected: !options[name] }, "None")] : []).concat(names.map((n) => h("option", { value: n, selected: n === options[name] }, n))));
    const methodPick = h("select.input.dx-method", { on: { change: () => { options.method = methodPick.value; show(); } } },
      schema.method.enum.map((m) => h("option", { value: m, selected: m === options.method }, m)));
    // A setting as a slider (or a number for windows of frames), with its value beside its name
    const setting = (name, { step = 1, max = null } = {}) => {
      const p = schema[name];
      const value = h("span.dx-value", String(options[name]));
      const input = h("input" + (max === null ? ".input" : ""), { type: max === null ? "number" : "range", min: p.minimum ?? 0, max: max ?? p.maximum ?? undefined, step,
        value: options[name], on: { input: () => {
          const v = Number(input.value);
          if (!Number.isFinite(v) || v < (p.minimum ?? 0)) return;
          options[name] = p.type === "integer" ? Math.round(v) : v;
          value.textContent = String(options[name]);
          show();
        } } });
      input.classList.add("dx-" + name);
      return h("label", h("span", p.title || name, " ", value), input);
    };

    function show() {
      if (!state.signal) return;
      if (options.method === "dffMinusNeuropil" && !state.neuropil) {
        status.textContent = "dffMinusNeuropil needs the neuropil signals";
        return;
      }
      const { f, baseline, dff } = dffOf(state.signal, state.neuropil, options);
      const frames = f.length;
      plot.draw({ frames, start: 0, step: 1, points: frames, frameRate: state.frameRate, traces: [
        { variable: "F and F0", count: 2, columns: [{ column: 0, values: f.map(finiteOrNull) }, { column: 1, values: baseline.map(finiteOrNull) }] },
        { variable: "ΔF/F", count: 1, columns: [{ column: 0, values: dff.map(finiteOrNull) }] }] }, ["F", "F0"]);
      const finite = dff.filter(Number.isFinite);
      const peak = finite.length ? Math.max(...finite) : NaN;
      const meanBaseline = baseline.reduce((t, v) => t + v, 0) / frames;
      stats.dataset.peak = Number.isFinite(peak) ? String(peak) : "";
      N.fill(stats, h("span", "Peak ΔF/F ", h("b.dx-peak", Number.isFinite(peak) ? peak.toFixed(3) : "—")),
        h("span", "Mean F0 ", h("b", Number.isFinite(meanBaseline) ? N.fmt.number(meanBaseline) : "—")),
        h("span.muted", `${frames} frames` + (state.frameRate ? ` at ${N.fmt.number(state.frameRate)} Hz` : "")));
      status.textContent = "";
    }

    async function load() {
      if (!state.key) return;
      status.textContent = "Loading…";
      try {
        const first = await app.client.request("data.traces", { entityType, key: state.key, variables: [options.signals], columns: [0], maxPoints: 1,
          ...(variables.some((v) => v.name === "RoiArray" && v.entityType === entityType) ? { rois: "RoiArray" } : {}) });
        state.count = first.traces[0].count;
        state.rois = first.rois || null;
        state.column = Math.min(state.column, state.count - 1);
        const read = [options.signals].concat(options.neuropil ? [options.neuropil] : []);
        const result = await app.client.request("data.traces", { entityType, key: state.key, variables: read, columns: [state.column], maxPoints: first.frames });
        const values = (trace) => trace.columns[0].values.map((v) => (v === null ? NaN : v));
        state.signal = values(result.traces[0]);
        state.neuropil = options.neuropil ? values(result.traces[1]).map((v) => (Number.isNaN(v) ? 0 : v)) : null;   // NaN as 0, as compute_dff
        state.frameRate = result.frameRate;
        const columns = N.roiColumns(state.rois, state.count);
        const label = (c) => { if (columns) for (const [id, at] of columns) if (at === c) return `ROI ${id}`; return `Column ${c + 1}`; };
        N.fill(roiPick, Array.from({ length: state.count }, (_, c) => h("option", { value: c, selected: c === state.column }, label(c))));
        show();
      } catch (error) {
        state.signal = null;
        plot.draw(null);
        N.fill(stats);
        status.textContent = (error.code ? `[${error.code}] ` : "") + (error.message || String(error));
      }
    }

    async function queue(keys) {
      try {
        await app.client.request("tasks.submit", { methodId: "ophys.compute_dff", entityType, keys, options: { ...options } });
        N.toast("ΔF/F queued", `${keys.length} ${keys.length === 1 ? N.titleCase(entityType).toLowerCase() : "entities"} with these settings: see the task queue`);
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
      h("div.page-head", h("div", h("h1", "ΔF/F explorer"),
        h("p", "One ROI's signal, baseline (F0) and ΔF/F as the settings change, as dev's DffExplorer. ↑ and ↓ go through the ROIs; the settings are then run as Compute ΔF/F (ophys.compute_dff)."))),
      rows.length ? h("div.dx-layout",
        h("div.card.dx-side",
          h("label", "Session", sessionPick), h("label", "ROI", roiPick),
          h("label", schema.signals.title || "Signals", variablePick("signals", false)),
          h("label", schema.neuropil.title || "Neuropil", variablePick("neuropil", true)),
          h("label", schema.method.title || "Method", methodPick),
          setting("neuropilFactor", { step: 0.05 }), setting("baselinePercentile", { step: 1 }), setting("baselineWindow"),
          setting("correctionWindow"), setting("correctionPercentile", { step: 1 }),
          h("div.dx-actions",
            h("button.btn.primary.small.dx-queue-one", { on: { click: () => queue([state.key]) } }, "Run on this session"),
            h("button.btn.small.dx-queue-all", { on: { click: () => queue(rows.map((r) => r.key)) } }, `Run on all ${rows.length}`))),
        h("div.card.dx-main", stats, plot.el, status))
        : h("div.empty", h("h3", `No ${N.titleCase(entityType).toLowerCase()} entities`)));
    await load();
  },
});
