/* Signal traces: a plot of frames x ROIs signal variables (data.traces), one panel per variable.
 *
 * N.tracePlot draws traces on a canvas: one panel per variable, the time along the bottom (seconds when data.traces
 * gives the frame rate, the entity's frame_rate), the value under the pointer at the top. Dragging across a panel
 * zooms to those frames; a double click goes back to all.
 * N.views.traces is the dialog the drawer opens for a signal variable: pick ROIs (columns) and variables.
 * The stack viewer shows the selected ROI's trace under the image with the same plot.
 */
(function () {
  "use strict";
  const N = window.N;
  const { h } = N;

  const COLORS = ["#3d5afe", "#e8590c", "#2f9e44", "#c2255c", "#7048e8", "#0c8599", "#f08c00", "#495057"];
  N.traceColor = (n) => COLORS[n % COLORS.length];

  /** Signal variables: arrays of frames x ROIs. */
  N.isSignalVariable = (d) => d.dataType === "RoiSignals" && d.files && d.files.length > 0;
  /** Time series: other frames x N arrays (motion shifts, per-frame image stats), their columns named by the variable. */
  N.isSeriesVariable = (d) => d.dataType === "TimeSeries" && d.files && d.files.length > 0;

  /** The column of each ROI, when the signals are the ROIs' in order (all of them, or those not rejected). */
  N.roiColumns = function (rois, count) {
    if (!rois) return null;
    if (rois.length === count) return new Map(rois.map((r, i) => [r.id, i]));
    const kept = rois.filter((r) => r.classification !== "rejected");
    return kept.length === count ? new Map(kept.map((r, i) => [r.id, i])) : null;
  };

  /**
   * A trace plot. plot.draw(data, labels) draws a data.traces result; onRange(start, stop) is called when frames
   * are dragged across (null, null on a double click), onPick(frame) on a click, and plot.cursor(frame) marks a frame.
   */
  N.tracePlot = function ({ height = 120, onRange = null, onPick = null, onMark = null } = {}) {
    const canvas = h("canvas.trace-canvas");
    const readout = h("div.trace-readout.mono", "");
    const el = h("div.trace-plot", readout, canvas);
    let data = null;
    let labels = [];
    let cursorFrame = null;
    let drag = null;
    let hover = null;
    let events = [];   // [{start, stop, label}]: drawn as patches over every panel (dev's signal viewer's events)
    let marking = false;   // a drag marks an event (onMark) instead of zooming
    let stacked = false;   // dev's signal viewer's Stack Signals Vertically: each column in a band of its own, on its own scale
    let legend = false;    // and its Show Legend: each column's colour and name
    const pad = { left: 56, right: 12, top: 8, bottom: 22 };
    canvas.style.height = `${height + pad.bottom}px`;   // one panel's room before the first draw, so nothing moves when it comes

    const css = (name, fallback) => getComputedStyle(document.documentElement).getPropertyValue(name).trim() || fallback;
    const panels = () => (data ? data.traces.length : 0);
    const frameOf = (i) => data.start + i * data.step;
    const lastFrame = () => frameOf(Math.max(0, data.points - 1));

    function geometry() {
      const width = canvas.clientWidth || 600;
      const panelHeight = height;
      return { width, panelHeight, total: panels() * panelHeight + pad.bottom };
    }
    function xOf(frame, width) {
      const first = data.start, last = lastFrame();
      return pad.left + (last > first ? (frame - first) / (last - first) : 0.5) * (width - pad.left - pad.right);
    }
    function frameAt(x, width) {
      const first = data.start, last = lastFrame();
      const share = Math.min(1, Math.max(0, (x - pad.left) / (width - pad.left - pad.right)));
      return Math.round(first + share * (last - first));
    }

    function draw() {
      if (!data) return;
      const { width, panelHeight, total } = geometry();
      const ratio = window.devicePixelRatio || 1;
      canvas.width = Math.round(width * ratio);
      canvas.height = Math.round(total * ratio);
      canvas.style.height = `${total}px`;
      const ctx = canvas.getContext("2d");
      ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
      ctx.clearRect(0, 0, width, total);
      const text = css("--text-3", "#667085"), grid = css("--border", "#e4e7ec");
      ctx.font = "11px system-ui, sans-serif";
      data.traces.forEach((trace, p) => {
        const top = p * panelHeight + pad.top, bottom = (p + 1) * panelHeight - 4;
        let low = Infinity, high = -Infinity;
        trace.columns.forEach((c) => c.values.forEach((v) => { if (v !== null) { low = Math.min(low, v); high = Math.max(high, v); } }));
        if (!Number.isFinite(low)) { low = 0; high = 1; }
        if (high === low) { high += 1; low -= 1; }
        let yOf = (v) => bottom - (v - low) / (high - low) * (bottom - top);
        const bands = stacked && trace.columns.length > 1 ? trace.columns.length : 1;
        ctx.strokeStyle = grid;
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(pad.left, top); ctx.lineTo(pad.left, bottom); ctx.lineTo(width - pad.right, bottom);
        ctx.stroke();
        ctx.fillStyle = text;
        ctx.textAlign = "right";
        if (bands === 1) {
          ctx.fillText(N.fmt.number(high), pad.left - 6, top + 9);
          ctx.fillText(N.fmt.number(low), pad.left - 6, bottom);
        }
        ctx.textAlign = "left";
        ctx.fillText(trace.variable, pad.left + 6, top + 10);
        trace.columns.forEach((c, k) => {
          if (bands > 1) {   // this column's band, scaled to its own range, its name on the left
            const band = (bottom - top - 12) / bands, bandTop = top + 12 + k * band, bandBottom = bandTop + band - 2;
            let lo = Infinity, hi = -Infinity;
            c.values.forEach((v) => { if (v !== null) { lo = Math.min(lo, v); hi = Math.max(hi, v); } });
            if (!Number.isFinite(lo)) { lo = 0; hi = 1; }
            if (hi === lo) { hi += 1; lo -= 1; }
            yOf = (v) => bandBottom - (v - lo) / (hi - lo) * (bandBottom - bandTop);
            ctx.fillStyle = N.traceColor(k);
            ctx.textAlign = "right";
            ctx.fillText(labels[k] || `${c.column + 1}`, pad.left - 6, (bandTop + bandBottom) / 2 + 4);
          }
          ctx.strokeStyle = N.traceColor(k);
          ctx.lineWidth = 1.25;
          ctx.beginPath();
          let pen = false;
          c.values.forEach((v, i) => {
            if (v === null) { pen = false; return; }
            const x = xOf(frameOf(i), width), y = yOf(v);
            if (pen) ctx.lineTo(x, y); else ctx.moveTo(x, y);
            pen = true;
          });
          ctx.stroke();
        });
        if (legend && trace.columns.length) {   // the columns' colours and names, at the top right
          ctx.textAlign = "left";
          const names = trace.columns.map((c, k) => labels[k] || `column ${c.column + 1}`);
          const widest = Math.max(...names.map((n) => ctx.measureText(n).width));
          const x = width - pad.right - widest - 24;
          names.forEach((name, k) => {
            const y = top + 8 + k * 14;
            ctx.fillStyle = css("--surface", "#ffffff");
            ctx.globalAlpha = 0.85;
            ctx.fillRect(x - 4, y - 9, widest + 28, 14);
            ctx.globalAlpha = 1;
            ctx.strokeStyle = N.traceColor(k);
            ctx.lineWidth = 2;
            ctx.beginPath(); ctx.moveTo(x, y - 3); ctx.lineTo(x + 14, y - 3); ctx.stroke();
            ctx.fillStyle = css("--text-2", "#475467");
            ctx.fillText(name, x + 18, y);
          });
        }
      });
      canvas.dataset.stacked = String(stacked);
      canvas.dataset.legend = String(legend);
      // the time axis: seconds when the frame rate is known, else frames
      ctx.fillStyle = text;
      ctx.textAlign = "center";
      const ticks = 6;
      for (let t = 0; t <= ticks; t++) {
        const frame = Math.round(data.start + t / ticks * (lastFrame() - data.start));
        ctx.textAlign = t === 0 ? "left" : t === ticks ? "right" : "center";   // the ends inside the plot
        ctx.fillText(timeLabel(frame), xOf(frame, width) + (t === 0 ? -2 : t === ticks ? 2 : 0), total - 6);
      }
      for (const e of events) {
        if (e.stop < data.start || e.start > lastFrame()) continue;
        const a = xOf(Math.max(e.start, data.start), width), b = xOf(Math.min(e.stop, lastFrame()), width);
        ctx.fillStyle = "rgba(255, 170, 0, 0.18)";
        ctx.fillRect(a, 0, Math.max(2, b - a), total - pad.bottom);
        if (e.label) { ctx.fillStyle = css("--text-2", "#475467"); ctx.textAlign = "left"; ctx.fillText(e.label, a + 3, total - pad.bottom - 4); }
      }
      if (drag && drag.to !== null) {
        ctx.fillStyle = marking ? "rgba(255, 170, 0, 0.3)" : "rgba(61, 90, 254, 0.12)";
        const a = Math.min(drag.from, drag.to), b = Math.max(drag.from, drag.to);
        ctx.fillRect(a, 0, b - a, total - pad.bottom);
      }
      if (keyMark !== null && hover !== null) {   // an event being marked from the keyboard
        ctx.fillStyle = "rgba(255, 170, 0, 0.3)";
        const a = xOf(Math.min(keyMark, hover), width), b = xOf(Math.max(keyMark, hover), width);
        ctx.fillRect(a, 0, Math.max(2, b - a), total - pad.bottom);
      }
      for (const [frame, color] of [[cursorFrame, "rgba(220, 60, 60, 0.8)"], [hover, "rgba(120, 120, 120, 0.6)"]]) {
        if (frame === null || frame < data.start || frame > lastFrame()) continue;
        ctx.strokeStyle = color;
        ctx.beginPath();
        ctx.moveTo(xOf(frame, width), 0); ctx.lineTo(xOf(frame, width), total - pad.bottom);
        ctx.stroke();
      }
    }

    /** A frame as the axis shows it: its time in seconds (frame 0 at 0 s), with as many decimals as the span shown needs. */
    function timeLabel(frame) {
      if (!data.frameRate) return String(frame);
      const span = (lastFrame() - data.start) / data.frameRate;
      return `${(frame / data.frameRate).toFixed(span < 2 ? 2 : span < 20 ? 1 : 0)} s`;
    }

    function read(frame) {
      if (!data) return "";
      const i = Math.round((frame - data.start) / data.step);
      if (i < 0 || i >= data.points) return "";
      const parts = [];
      data.traces.forEach((trace) => trace.columns.forEach((c, k) => {
        const v = c.values[i];
        parts.push(`${labels[k] || "column " + c.column} ${trace.variable}: ${v === null ? "—" : N.fmt.number(v)}`);
      }));
      const at = frameOf(i);
      return (data.frameRate ? `${N.fmt.number(at / data.frameRate)} s (frame ${at}) · ` : `frame ${at} · `) + parts.join(" · ");
    }

    canvas.addEventListener("mousedown", (event) => {
      if (!data) return;
      const x = event.offsetX;
      drag = { from: x, to: null };
    });
    canvas.addEventListener("mousemove", (event) => {
      if (!data) return;
      const { width } = geometry();
      hover = frameAt(event.offsetX, width);
      readout.textContent = read(hover);
      if (drag) drag.to = event.offsetX;
      draw();
    });
    canvas.addEventListener("mouseleave", () => { hover = null; readout.textContent = ""; draw(); });
    window.addEventListener("mouseup", (event) => {
      if (!drag || !data) return;
      const { width } = geometry();
      const moved = drag.to !== null && Math.abs(drag.to - drag.from) > 4;
      const from = drag.from, to = drag.to;
      drag = null;
      if (moved && marking && onMark) {
        const a = frameAt(Math.min(from, to), width), b = frameAt(Math.max(from, to), width);
        if (b >= a) onMark(a, b);
      } else if (moved && onRange) {
        const a = frameAt(Math.min(from, to), width), b = frameAt(Math.max(from, to), width);
        if (b > a) onRange(a, b + 1);
      } else if (event.target === canvas && onPick) {
        onPick(frameAt(from, width));
      }
      draw();
    });
    canvas.addEventListener("dblclick", () => { if (onRange) onRange(null, null); });

    // The keyboard (WCAG 2.1.1): the plot takes the focus; ← → move a cursor over the frames (Shift: a tenth of those
    // shown; Home, End), Enter goes to its frame (as a click), + and - zoom in and out around it (as a drag across), 0
    // shows every frame (as a double click); while marking events, Space marks where one starts, then where it ends.
    let keyMark = null;
    canvas.tabIndex = 0;
    canvas.setAttribute("role", "application");
    canvas.setAttribute("aria-roledescription", "plot");
    canvas.setAttribute("aria-label", "Signal plot. Left and right arrows move a cursor over the frames, Enter goes to its frame, " +
      "plus and minus zoom around it, 0 shows every frame; while marking, Space marks an event's start and end");
    canvas.addEventListener("keydown", (event) => {
      if (!data || event.altKey || event.ctrlKey || event.metaKey) return;
      const first = data.start, end = lastFrame(), span = Math.max(1, end - first);
      const at = hover !== null ? hover : cursorFrame !== null && cursorFrame >= first && cursorFrame <= end ? cursorFrame : first;
      const total = data.frames || end + 1;
      const key = event.key;
      const show = (frame) => { hover = frame; readout.textContent = read(frame); canvas.dataset.hover = String(frame); };
      if (key === "ArrowLeft" || key === "ArrowRight") {
        const step = event.shiftKey ? Math.max(1, Math.round(span / 10)) : Math.max(1, data.step);
        show(Math.min(end, Math.max(first, at + (key === "ArrowLeft" ? -step : step))));
      } else if (key === "Home" || key === "End") show(key === "Home" ? first : end);
      else if (key === "Enter" && onPick) onPick(at);
      else if ((key === "+" || key === "=") && onRange) {
        const half = Math.max(2, Math.round(span / 4));
        const a = Math.max(0, Math.min(at - half, total - 2 * half)), b = Math.min(total - 1, a + 2 * half);
        if (b > a) onRange(a, b + 1);
      } else if (key === "-" && onRange) {
        const a = Math.max(0, at - span), b = Math.min(total - 1, at + span);
        if (a === 0 && b === total - 1) onRange(null, null); else onRange(a, b + 1);
      } else if (key === "0" && onRange) onRange(null, null);
      else if (key === " " && marking && onMark) {
        if (keyMark === null) { keyMark = at; show(at); }
        else { const a = Math.min(keyMark, at), b = Math.max(keyMark, at); keyMark = null; onMark(a, b); }
      } else return;
      event.preventDefault();
      event.stopPropagation();
      draw();
    });
    canvas.addEventListener("focus", () => { if (data && hover === null) { hover = cursorFrame !== null ? cursorFrame : data.start; readout.textContent = read(hover); draw(); } });
    canvas.addEventListener("blur", () => { keyMark = null; hover = null; readout.textContent = ""; draw(); });

    return {
      el, canvas,
      draw(result, names = []) { data = result; labels = names; draw(); },
      cursor(frame) { cursorFrame = frame; draw(); },
      events(list) { events = list || []; draw(); },
      mark(on) { marking = on; canvas.classList.toggle("marking", on); },
      stack(on) { stacked = on; draw(); },
      showLegend(on) { legend = on; draw(); },
      redraw: draw,
    };
  };

  /** The traces dialog: ROIs (columns) of one entity's signal variables; or, with viewable ({id, name}), signals
   * `nansen view` or nansen.view was given, with no project (view.traces), as dev's signalviewer. */
  N.views.traces = async function (app, entityType, key, signalVariables, { variable = null, roiVariable = null, column = 0, viewable = null } = {}) {
    if (viewable) signalVariables = [viewable.name];
    const state = { variables: variable ? [variable] : signalVariables.slice(0, 1), columns: [column], range: [null, null], count: 0, rois: null };
    // per-frame image statistics (ophys.image_stats' FrameStats) open as dev's plotImageStats drew them: the mean between
    // the minimum and maximum and between the 0.05 and 99.95 percentiles
    let firstLoad = column === 0;
    const IMAGE_STATS = ["mean", "min", "max", "p0.05", "p99.95"];
    const status = h("div.muted.trace-status", "Loading…");
    const plot = N.tracePlot({
      height: 150,
      onRange: (start, stop) => { state.range = [start, stop]; load(); },
      onMark: (start, stop) => markEvent(start, stop),
    });
    // Events marked on the traces, as dev's signal viewer's event annotator: frames start..stop of an ROI (a column of
    // the signals), with a label, kept in the project (module data "trace_events" of ophys, or core, or the first module) with
    // the entity they are of
    const modules = ((app.project && app.project.modules) || []).map((m) => m.id);
    const module = ["ophys", "core"].find((m) => modules.includes(m)) || modules[0] || null;
    let stored = { events: [] }, revision = 0;
    const sameKey = (a, b) => Object.keys(a).length === Object.keys(b).length && Object.keys(a).every((k) => a[k] === b[k]);
    const mine = (e) => e.entityType === entityType && sameKey(e.key, key);
    const markButton = h("button.btn.small.trace-mark", { title: "Drag across a plot to mark an event of the ROI", on: { click: () => {
      const on = !markButton.classList.contains("active");
      markButton.classList.toggle("active", on);
      plot.mark(on);
    } }, disabled: !module }, N.icon("edit", 13), "Mark events");
    const eventList = h("ul.trace-events");
    async function loadEvents() {
      try {
        if (!module) return;
        const data = await app.client.request("modules.data", { module, name: "trace_events" });
        stored = JSON.parse(data.text) || { events: [] };
        stored.events = stored.events || [];
        revision = data.revision;
      } catch (error) { stored = { events: [] }; }
      showEvents();
    }
    async function changeEvents(change) {
      for (let attempt = 0; attempt < 2; attempt++) {
        change(stored.events);
        try {
          revision = (await app.client.request("modules.saveData", { module, name: "trace_events", text: JSON.stringify(stored), revision })).revision;
          break;
        } catch (error) {
          if (error.code !== "revision-conflict" || attempt) { N.showError(error, "Could not save the events"); break; }
          await loadEvents();
        }
      }
      showEvents();
    }
    function showEvents() {
      const shown = stored.events.filter((e) => mine(e) && state.columns.includes(e.column));
      plot.events(shown);
      N.fill(eventList, shown.map((e) => h("li", { dataset: { start: e.start } },
        h("span.swatch", { style: { background: "rgba(255, 170, 0, 0.7)" } }),
        h("span.grow", `${labelOf(e.column)}: frames ${e.start}–${e.stop}` + (e.label ? ` · ${e.label}` : "")),
        h("button.btn.ghost.icon.small.remove-event", { title: "Remove", on: { click: () => changeEvents((all) => {
          const at = all.indexOf(e);
          if (at >= 0) all.splice(at, 1);
        }) } }, N.icon("trash", 12)))));
    }
    async function markEvent(start, stop) {
      const column = state.columns[state.columns.length - 1];
      const label = await N.prompt(`Event of ${labelOf(column)}`, `Frames ${start}–${stop}: a label (optional)`, "");
      if (label === null) return;
      const roi = (N.roiColumns(state.rois, state.count) ? [...N.roiColumns(state.rois, state.count)].find(([, c]) => c === column) : null);
      await changeEvents((all) => all.push(Object.assign({ entityType, key, column, start, stop, label: label.trim() },
        roi ? { roi: roi[0] } : {}, state.variables.length === 1 ? { variable: state.variables[0] } : {})));
    }
    const list = N.listbox(h("ul.trace-roi-list"), "Columns shown", true);
    const pickers = signalVariables.map((name) => {
      const box = h("input", { type: "checkbox", checked: state.variables.includes(name), on: { change: () => {
        state.variables = signalVariables.filter((n, i) => pickers[i].querySelector("input").checked);
        if (!state.variables.length) { box.checked = true; state.variables = [name]; }
        load();
      } } });
      return h("label.trace-variable", box, name);
    });

    function labelOf(column) {
      if (state.names && state.names[column]) return state.names[column];
      const map = N.roiColumns(state.rois, state.count);
      if (map) for (const [id, c] of map) if (c === column) return `ROI ${id}`;
      return `Column ${column + 1}`;
    }
    function renderList() {
      N.listbox.fill(list, Array.from({ length: state.count }, (_, c) => N.option(h("li" + (state.columns.includes(c) ? ".selected" : ""), {
        dataset: { column: c },
        on: { click: (event) => pick(c, event.ctrlKey || event.metaKey || event.shiftKey) } },
        state.columns.includes(c) ? h("span.swatch", { style: { background: N.traceColor(state.columns.indexOf(c)) } }) : h("span.swatch.unpicked"),
        labelOf(c)), state.columns.includes(c))));
    }
    function pick(c, add) {
      if (add) {
        state.columns = state.columns.includes(c) ? state.columns.filter((x) => x !== c) : state.columns.concat([c]).slice(-COLORS.length);
        if (!state.columns.length) state.columns = [c];
      } else state.columns = [c];
      load();
      const item = list.querySelector(`li[data-column="${c}"]`);
      if (item) item.scrollIntoView({ block: "nearest" });
    }
    async function load() {
      const [start, stop] = state.range;
      const params = viewable ? { viewable: viewable.id, columns: state.columns, maxPoints: 1500 }
        : { entityType, key, variables: state.variables, columns: state.columns, maxPoints: 1500 };
      if (start !== null) { params.start = start; params.stop = stop; }
      if (roiVariable && !state.rois) params.rois = roiVariable;
      try {
        const result = await app.client.request(viewable ? "view.traces" : "data.traces", params);
        if (result.rois) state.rois = result.rois;
        state.names = (result.traces.find((t) => t.columnNames) || {}).columnNames || null;
        state.count = Math.min(...result.traces.map((t) => t.count));
        if (firstLoad && state.names && state.names[0] === "mean" && IMAGE_STATS.every((n) => state.names.includes(n))) {
          firstLoad = false;
          state.columns = IMAGE_STATS.map((n) => state.names.indexOf(n));
          return load();
        }
        firstLoad = false;
        plot.draw(result, state.columns.map(labelOf));
        showEvents();
        status.textContent = `${result.frames} frames` + (result.frameRate ? ` at ${N.fmt.number(result.frameRate)} Hz` : "") + (start !== null ? ` · showing ${result.start}–${result.start + (result.points - 1) * result.step} (double-click for all)` : " · drag across a plot to zoom") +
          (result.step > 1 ? ` · every ${result.step}th frame` : "");
        renderList();
      } catch (error) { status.textContent = (error.code ? `[${error.code}] ` : "") + (error.message || String(error)); }
    }
    const onKey = (event) => {
      if (["INPUT", "SELECT", "TEXTAREA"].includes(event.target.tagName)) return;
      const at = state.columns[state.columns.length - 1];
      if (event.key === "ArrowDown" || event.key === "j") pick(Math.min(state.count - 1, at + 1), false);
      else if (event.key === "ArrowUp" || event.key === "k") pick(Math.max(0, at - 1), false);
      else return;
      event.preventDefault();
    };
    document.addEventListener("keydown", onKey);
    const content = h("div.traces",
      h("div.trace-bar", h("span.muted", "Signals"), pickers, h("div.spacer"),
        h("label.trace-option", h("input.trace-stack", { type: "checkbox", on: { change: (e) => plot.stack(e.target.checked) } }), "Stack"),
        h("label.trace-option", h("input.trace-legend", { type: "checkbox", on: { change: (e) => plot.showLegend(e.target.checked) } }), "Legend"),
        markButton, status),
      h("div.trace-main", h("div.trace-side", h("div.trace-hint.muted", "Click an ROI; Ctrl-click (Ctrl + Space) adds more. ↑ and ↓ move, Shift + ↓ adds the next."), list),
        h("div.trace-stage", plot.el, eventList)));
    const dialog = N.dialog({ title: viewable ? `Signals · ${viewable.name}` : `Signals · ${N.fmt.key(key)}`, content, onClose: () => document.removeEventListener("keydown", onKey) });
    dialog.el.classList.add("traces-dialog");
    window.addEventListener("resize", plot.redraw);
    await loadEvents();
    await load();
    return dialog;
  };
})();
