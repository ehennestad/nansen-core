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
  N.tracePlot = function ({ height = 120, onRange = null, onPick = null } = {}) {
    const canvas = h("canvas.trace-canvas");
    const readout = h("div.trace-readout.mono", "");
    const el = h("div.trace-plot", readout, canvas);
    let data = null;
    let labels = [];
    let cursorFrame = null;
    let drag = null;
    let hover = null;
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
        const yOf = (v) => bottom - (v - low) / (high - low) * (bottom - top);
        ctx.strokeStyle = grid;
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(pad.left, top); ctx.lineTo(pad.left, bottom); ctx.lineTo(width - pad.right, bottom);
        ctx.stroke();
        ctx.fillStyle = text;
        ctx.textAlign = "right";
        ctx.fillText(N.fmt.number(high), pad.left - 6, top + 9);
        ctx.fillText(N.fmt.number(low), pad.left - 6, bottom);
        ctx.textAlign = "left";
        ctx.fillText(trace.variable, pad.left + 6, top + 10);
        trace.columns.forEach((c, k) => {
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
      });
      // the time axis: seconds when the frame rate is known, else frames
      ctx.fillStyle = text;
      ctx.textAlign = "center";
      const ticks = 6;
      for (let t = 0; t <= ticks; t++) {
        const frame = Math.round(data.start + t / ticks * (lastFrame() - data.start));
        ctx.fillText(timeLabel(frame), xOf(frame, width), total - 6);
      }
      if (drag && drag.to !== null) {
        ctx.fillStyle = "rgba(61, 90, 254, 0.12)";
        const a = Math.min(drag.from, drag.to), b = Math.max(drag.from, drag.to);
        ctx.fillRect(a, 0, b - a, total - pad.bottom);
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
      if (moved && onRange) {
        const a = frameAt(Math.min(from, to), width), b = frameAt(Math.max(from, to), width);
        if (b > a) onRange(a, b + 1);
      } else if (event.target === canvas && onPick) {
        onPick(frameAt(from, width));
      }
      draw();
    });
    canvas.addEventListener("dblclick", () => { if (onRange) onRange(null, null); });

    return {
      el, canvas,
      draw(result, names = []) { data = result; labels = names; draw(); },
      cursor(frame) { cursorFrame = frame; draw(); },
      redraw: draw,
    };
  };

  /** The traces dialog: ROIs (columns) of one entity's signal variables. */
  N.views.traces = async function (app, entityType, key, signalVariables, { variable = null, roiVariable = null, column = 0 } = {}) {
    const state = { variables: variable ? [variable] : signalVariables.slice(0, 1), columns: [column], range: [null, null], count: 0, rois: null };
    const status = h("div.muted.trace-status", "Loading…");
    const plot = N.tracePlot({
      height: 150,
      onRange: (start, stop) => { state.range = [start, stop]; load(); },
    });
    const list = h("ul.trace-roi-list");
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
      N.fill(list, Array.from({ length: state.count }, (_, c) => h("li" + (state.columns.includes(c) ? ".selected" : ""), {
        dataset: { column: c },
        on: { click: (event) => pick(c, event.ctrlKey || event.metaKey || event.shiftKey) } },
        state.columns.includes(c) ? h("span.swatch", { style: { background: N.traceColor(state.columns.indexOf(c)) } }) : h("span.swatch.unpicked"),
        labelOf(c))));
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
      const params = { entityType, key, variables: state.variables, columns: state.columns, maxPoints: 1500 };
      if (start !== null) { params.start = start; params.stop = stop; }
      if (roiVariable && !state.rois) params.rois = roiVariable;
      try {
        const result = await app.client.request("data.traces", params);
        if (result.rois) state.rois = result.rois;
        state.names = (result.traces.find((t) => t.columnNames) || {}).columnNames || null;
        state.count = Math.min(...result.traces.map((t) => t.count));
        plot.draw(result, state.columns.map(labelOf));
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
      h("div.trace-bar", h("span.muted", "Signals"), pickers, h("div.spacer"), status),
      h("div.trace-main", h("div.trace-side", h("div.trace-hint.muted", "Click an ROI; Ctrl-click to add more. ↑ and ↓ move."), list), h("div.trace-stage", plot.el)));
    const dialog = N.dialog({ title: `Signals · ${N.fmt.key(key)}`, content, onClose: () => document.removeEventListener("keydown", onKey) });
    dialog.el.classList.add("traces-dialog");
    window.addEventListener("resize", plot.redraw);
    await load();
    return dialog;
  };
})();
