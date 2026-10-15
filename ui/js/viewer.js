/* The stack viewer: frames and projections of an image variable, with ROIs drawn over them (data.frame).
 *
 * ROIs are curated here, as in dev's roimanager: selected (Ctrl-click for several), classified (a, r, u), deleted,
 * moved by dragging, merged, and added: as a circle, drawn freehand, or detected around a click (rois.detect).
 * The wheel zooms and dragging the image pans it; the image can be saved as PNG, the stack exported as TIFF, and the
 * ROIs shown as a gallery.
 */
(function () {
  "use strict";
  const N = window.N;
  const { h } = N;

  const IMAGE_TYPES = ["Image", "ImageStack"];
  const ARRAY_ADAPTERS = ["npy", "mat", "ophys.tiff_stack", "ophys.sciscan_raw"];
  const SIDES = [[1, 0], [-1, 0], [0, 1], [0, -1]];

  /** Whether a data.status entry can be shown in the viewer. */
  N.isImageVariable = function (d) {
    if (!d.files || !d.files.length) return false;
    return d.dataType ? IMAGE_TYPES.includes(d.dataType) : ARRAY_ADAPTERS.includes(d.fileAdapter);
  };

  /* Colormaps: colours at even steps from the lowest value to the highest, interpolated to 256 */
  const COLORMAPS = {
    gray: [[0, 0, 0], [255, 255, 255]],
    viridis: [[68, 1, 84], [59, 82, 139], [33, 145, 140], [94, 201, 98], [253, 231, 37]],
    magma: [[0, 0, 4], [81, 18, 124], [183, 55, 121], [252, 137, 97], [252, 253, 191]],
    hot: [[0, 0, 0], [230, 0, 0], [255, 210, 0], [255, 255, 255]],
    green: [[0, 0, 0], [0, 255, 70]],
  };
  const tables = {};
  function lut(name) {
    if (tables[name]) return tables[name];
    const stops = COLORMAPS[name] || COLORMAPS.gray;
    const table = new Uint8ClampedArray(256 * 3);
    for (let v = 0; v < 256; v++) {
      const at = v / 255 * (stops.length - 1), i = Math.min(stops.length - 2, Math.floor(at)), f = at - i;
      for (let c = 0; c < 3; c++) table[3 * v + c] = Math.round(stops[i][c] + (stops[i + 1][c] - stops[i][c]) * f);
    }
    return (tables[name] = table);
  }
  N.colormaps = Object.keys(COLORMAPS);

  /** Decode a data.frame result onto a canvas of its own size, in a colormap, with ROIs filled over it.
   * Rejected ROIs are dimmed (or left out with hideRejected); selected ROIs are drawn in full color. */
  function paint(canvas, frame, rois, showRois, selected = new Set(), hideRejected = false, colormap = "gray") {
    canvas.width = frame.width;
    canvas.height = frame.height;
    const ctx = canvas.getContext("2d");
    const bytes = atob(frame.pixels);
    const image = ctx.createImageData(frame.width, frame.height);
    const table = lut(colormap);
    for (let i = 0; i < bytes.length; i++) {
      const v = 3 * bytes.charCodeAt(i);
      image.data[4 * i] = table[v]; image.data[4 * i + 1] = table[v + 1]; image.data[4 * i + 2] = table[v + 2]; image.data[4 * i + 3] = 255;
    }
    if (showRois && rois) {
      rois.forEach((roi, n) => {
        const rejected = roi.classification === "rejected";
        if (rejected && hideRejected) return;
        const [r, g, b] = rejected ? [200, 60, 60] : roiColor(n);
        const share = selected.has(roi.id) ? 1 : rejected ? 0.25 : 0.5;
        roi.pixels.forEach(([y, x]) => {
          if (y < 0 || y >= frame.height || x < 0 || x >= frame.width) return;
          const i = 4 * (y * frame.width + x);
          image.data[i] += (r - image.data[i]) * share; image.data[i + 1] += (g - image.data[i + 1]) * share; image.data[i + 2] += (b - image.data[i + 2]) * share;
        });
      });
    }
    ctx.putImageData(image, 0, 0);
  }

  function roiColor(n) {
    const hue = (n * 137.508 + 210) % 360;  // from blue: red is for rejected ROIs
    const c = 0.9, x = c * (1 - Math.abs(((hue / 60) % 2) - 1));
    const [r, g, b] = hue < 60 ? [c, x, 0] : hue < 120 ? [x, c, 0] : hue < 180 ? [0, c, x] : hue < 240 ? [0, x, c] : hue < 300 ? [x, 0, c] : [c, 0, x];
    return [r, g, b].map((v) => Math.round(v * 255));
  }
  N.roiColor = roiColor;

  /** Even-odd rule: is (px, py) inside the polygon of points [[x, y], ...]? */
  function inPolygon(points, px, py) {
    let inside = false;
    for (let i = 0, j = points.length - 1; i < points.length; j = i++) {
      const [xi, yi] = points[i], [xj, yj] = points[j];
      if ((yi > py) !== (yj > py) && px < (xj - xi) * (py - yi) / (yj - yi) + xi) inside = !inside;
    }
    return inside;
  }

  /** The pixels [row, column] whose centre is inside a polygon drawn in image coordinates (pixel [r, c] spans c..c+1, r..r+1). */
  N.polygonPixels = function (points, height, width) {
    if (points.length < 3) return [];
    const xs = points.map((p) => p[0]), ys = points.map((p) => p[1]);
    const pixels = [];
    for (let r = Math.max(0, Math.floor(Math.min(...ys))); r <= Math.min(height - 1, Math.ceil(Math.max(...ys))); r++) {
      for (let c = Math.max(0, Math.floor(Math.min(...xs))); c <= Math.min(width - 1, Math.ceil(Math.max(...xs))); c++) {
        if (inPolygon(points, c + 0.5, r + 0.5)) pixels.push([r, c]);
      }
    }
    return pixels;
  };

  /** The pixels of an ROI on its edge: those with a side not in the ROI. */
  function edge(roi) {
    const inside = new Set(roi.pixels.map(([y, x]) => `${y},${x}`));
    return roi.pixels.filter(([y, x]) => SIDES.some(([a, b]) => !inside.has(`${y + a},${x + b}`)));
  }

  /**
   * Open the viewer on a variable of an entity. roiVariables are the entity's variables that hold ROIs, and
   * signalVariables its signals, shown for the selected ROI. options.select is an ROI to select once the ROIs are
   * read, and options.mode the image to start on ("mean", ...); options.onClose is called when the viewer closes.
   */
  N.views.stackViewer = function (app, entityType, key, variable, roiVariables = [], signalVariables = [], options = {}) {
    let initial = options.select ?? null;
    const state = { frame: 0, frames: 1, mode: "frame", auto: true, low: 0, high: 1, rois: null, roiVariable: roiVariables[0] || "", showRois: roiVariables.length > 0,
      playing: false, busy: false, pending: false, selected: null, selection: new Set(), tool: null, radius: 3, hideRejected: false, channel: 0, plane: 0,
      zoom: 1, drag: null, colormap: "gray", polygon: [], undo: [], redo: [] };
    const canvas = h("canvas.viewer-canvas");
    const overlay = h("canvas.viewer-overlay");
    const holder = h("div.viewer-holder", canvas, overlay);
    const stage = h("div.viewer-stage", holder);
    const slider = h("input.viewer-slider", { type: "range", min: 0, max: 0, value: 0, on: { input: () => { state.frame = Number(slider.value); show(); } } });
    const frameLabel = h("span.viewer-frame.mono", "");
    const playButton = h("button.btn.ghost.icon.small.viewer-play", { title: "Play", on: { click: () => toggle() } }, N.icon("play", 14));
    const mode = h("select.input.viewer-mode", { on: { change: () => { state.mode = mode.value; show(); } } },
      h("option", { value: "frame" }, "Frames"), h("option", { value: "mean" }, "Average"), h("option", { value: "max" }, "Maximum"),
      h("option", { value: "std" }, "Standard deviation"), h("option", { value: "correlation" }, "Local correlation"));
    const colormapPick = h("select.input.viewer-colormap", { title: "Colormap", on: { change: () => { state.colormap = colormapPick.value; redraw(); } } },
      N.colormaps.map((name) => h("option", { value: name }, name)));
    const low = h("input.input.viewer-low", { type: "number", step: "any", on: { change: () => { state.auto = false; auto.checked = false; state.low = Number(low.value); show(); } } });
    const high = h("input.input.viewer-high", { type: "number", step: "any", on: { change: () => { state.auto = false; auto.checked = false; state.high = Number(high.value); show(); } } });
    const auto = h("input", { type: "checkbox", checked: true, on: { change: () => { state.auto = auto.checked; show(); } } });
    const roiToggle = h("input.viewer-rois", { type: "checkbox", checked: state.showRois, on: { change: () => { state.showRois = roiToggle.checked; show(); } } });
    const roiPick = roiVariables.length > 1 ? h("select.input", { on: { change: () => { state.roiVariable = roiPick.value; state.rois = null; select(null); show(); } } },
      roiVariables.map((v) => h("option", { value: v }, v))) : null;
    // channel and plane pickers, shown once the stack turns out to have more than one
    const channelPick = h("select.input.viewer-channel", { style: { display: "none" }, on: { change: () => { state.channel = Number(channelPick.value); show(); } } });
    const planePick = h("select.input.viewer-plane", { style: { display: "none" }, on: { change: () => { state.plane = Number(planePick.value); show(); } } });
    const fillPick = (select, count, label, value) => {
      if (select.options.length !== count) N.fill(select, Array.from({ length: count }, (_, i) => h("option", { value: i, selected: i === value }, `${label} ${i + 1}`)));
      select.style.display = count > 1 ? "" : "none";
    };
    // the ruler: drag across the image to measure a distance, as dev's imviewer measurement tool
    const measureButton = h("button.btn.ghost.icon.small.viewer-measure", { title: "Measure a distance: drag across the image", on: { click: () => setTool(state.tool === "measure" ? null : "measure") } }, N.icon("ruler", 14));
    const measurement = h("span.viewer-measurement.mono", "");
    const exportButton = h("button.btn.ghost.icon.small.viewer-export", { title: "Export", on: { click: () => exportMenu() } }, N.icon("download", 14));
    const zoomLabel = h("button.btn.ghost.small.viewer-zoom.mono", { title: "Fit the image (double-click it)", style: { display: "none" }, on: { click: () => zoomTo(1) } }, "");
    const status = h("div.viewer-status.muted", "Loading…");
    const where = h("span.viewer-where.mono.muted", "");
    let last = null;

    // --- where the pointer is: image coordinates (fractional) and pixels -------------------------------------------
    const pointAt = (event) => {
      const rect = canvas.getBoundingClientRect();
      return [(event.clientY - rect.top) / rect.height * last.height, (event.clientX - rect.left) / rect.width * last.width];
    };
    const pixelAt = (event) => pointAt(event).map(Math.floor);
    const visible = () => (state.rois || []).filter((r) => !(state.hideRejected && r.classification === "rejected"));
    const roiAt = (y, x) => state.showRois && state.rois ? visible().find((r) => r.pixels.some(([py, px]) => py === y && px === x)) || null : null;

    // --- size: the image fits the stage, times the zoom ---------------------------------------------------------------
    function layout() {
      if (!last) return;
      const room = Math.max(120, stage.clientWidth - 24);
      const tall = Math.max(120, window.innerHeight * (signalPanel ? 0.44 : 0.62) - 24);
      const fit = Math.min(room, 640, tall * last.width / last.height);
      const width = Math.round(fit * state.zoom), height = Math.round(fit * state.zoom * last.height / last.width);
      holder.style.width = `${width}px`;
      holder.style.height = `${height}px`;
      zoomLabel.textContent = `${Math.round(state.zoom * 100)}%`;
      zoomLabel.style.display = state.zoom > 1 ? "" : "none";
      stage.classList.toggle("zoomed", state.zoom > 1);
      drawOverlay();
    }
    /** Zoom to a factor (1 fits the image), keeping the image point under (clientX, clientY) where it is. */
    function zoomTo(zoom, clientX, clientY) {
      zoom = Math.min(16, Math.max(1, zoom));
      if (!last || zoom === state.zoom) return;
      const before = canvas.getBoundingClientRect();
      if (clientX === undefined) { clientX = before.left + before.width / 2; clientY = before.top + before.height / 2; }
      const fx = (clientX - before.left) / before.width, fy = (clientY - before.top) / before.height;
      state.zoom = zoom;
      layout();
      const after = canvas.getBoundingClientRect();
      stage.scrollLeft += after.left + fx * after.width - clientX;
      stage.scrollTop += after.top + fy * after.height - clientY;
    }
    stage.addEventListener("wheel", (event) => {
      if (!last) return;
      event.preventDefault();
      zoomTo(state.zoom * (event.deltaY < 0 ? 1.25 : 0.8), event.clientX, event.clientY);
    }, { passive: false });
    canvas.addEventListener("dblclick", (event) => { if (!state.tool) zoomTo(state.zoom > 1 ? 1 : 4, event.clientX, event.clientY); });
    const resizing = new ResizeObserver(() => layout());
    resizing.observe(stage);

    // --- the overlay: a line being drawn, an ROI being moved, the outlines of a selection ---------------------------
    function drawOverlay() {
      if (!last) return;
      const ratio = window.devicePixelRatio || 1;
      const width = overlay.clientWidth || 1, height = overlay.clientHeight || 1;
      overlay.width = Math.round(width * ratio);
      overlay.height = Math.round(height * ratio);
      const ctx = overlay.getContext("2d");
      ctx.setTransform(ratio * width / last.width, 0, 0, ratio * height / last.height, 0, 0);   // image coordinates
      ctx.clearRect(0, 0, last.width, last.height);
      const drag = state.drag;
      if (drag && drag.kind === "draw" && drag.points.length > 1) {
        ctx.strokeStyle = "rgba(255, 210, 60, 0.95)";
        ctx.lineWidth = 2 * last.width / width;
        ctx.beginPath();
        drag.points.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y)));
        ctx.stroke();
      }
      if (state.tool === "polygon" && state.polygon.length) {
        ctx.strokeStyle = "rgba(255, 210, 60, 0.95)";
        ctx.fillStyle = "rgba(255, 210, 60, 0.95)";
        ctx.lineWidth = 2 * last.width / width;
        ctx.beginPath();
        state.polygon.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y)));
        ctx.stroke();
        const dot = 3 * last.width / width;
        state.polygon.forEach(([x, y]) => ctx.fillRect(x - dot / 2, y - dot / 2, dot, dot));
      }
      if (drag && drag.kind === "move" && (drag.dy || drag.dx)) {
        ctx.fillStyle = "rgba(255, 210, 60, 0.55)";
        drag.roi.pixels.forEach(([y, x]) => ctx.fillRect(x + drag.dx, y + drag.dy, 1, 1));
      }
      const line = drag && drag.kind === "measure" ? drag : state.measure;
      if (line) {
        ctx.strokeStyle = "rgba(80, 220, 255, 0.95)";
        ctx.fillStyle = "rgba(80, 220, 255, 0.95)";
        ctx.lineWidth = 2 * last.width / width;
        ctx.beginPath();
        ctx.moveTo(line.from[0], line.from[1]);
        ctx.lineTo(line.to[0], line.to[1]);
        ctx.stroke();
        const dot = 4 * last.width / width;
        [line.from, line.to].forEach(([x, y]) => ctx.fillRect(x - dot / 2, y - dot / 2, dot, dot));
      }
      if (state.selection.size > 1 && state.showRois && state.rois) {
        ctx.fillStyle = "rgba(255, 255, 255, 0.45)";
        state.rois.filter((r) => state.selection.has(r.id)).forEach((roi) => edge(roi).forEach(([y, x]) => ctx.fillRect(x, y, 1, 1)));
      }
    }

    // --- the mouse: tools, selection, moving an ROI and panning -----------------------------------------------------
    canvas.addEventListener("mousemove", (event) => {
      if (!last) return;
      const [y, x] = pixelAt(event);
      const roi = roiAt(y, x);
      where.textContent = `row ${y}, column ${x}` + (roi ? ` · ROI ${roi.id}` : "");
      canvas.classList.toggle("over-selected", !state.tool && roi !== null && roi.id === state.selected);
    });
    canvas.addEventListener("mouseleave", () => { where.textContent = ""; });
    const several = (event) => event.ctrlKey || event.metaKey || event.shiftKey;
    canvas.addEventListener("mousedown", (event) => {
      if (!last || event.button !== 0) return;
      const [py, px] = pointAt(event);
      const roi = roiAt(Math.floor(py), Math.floor(px));
      if (state.tool === "draw") {
        if (state.rois) state.drag = { kind: "draw", points: [[px, py]] };
      } else if (state.tool === "measure") {
        state.drag = { kind: "measure", from: [px, py], to: [px, py] };
      } else if (state.tool) {
        return;   // circle and detect act on the click
      } else if (roi && roi.id === state.selected && !several(event)) {
        state.drag = { kind: "move", roi, from: [Math.floor(py), Math.floor(px)], dy: 0, dx: 0 };
      } else {
        state.drag = { kind: "pan", from: [event.clientX, event.clientY], scroll: [stage.scrollLeft, stage.scrollTop], moved: false };
      }
      event.preventDefault();
    });
    const onMove = (event) => {
      const drag = state.drag;
      if (!drag || !last) return;
      if (drag.kind === "draw" || drag.kind === "measure") {
        const [py, px] = pointAt(event);
        const point = [Math.min(last.width, Math.max(0, px)), Math.min(last.height, Math.max(0, py))];
        if (drag.kind === "draw") drag.points.push(point); else { drag.to = point; showMeasurement(drag); }
      } else if (drag.kind === "move") {
        const [y, x] = pixelAt(event);
        drag.dy = y - drag.from[0];
        drag.dx = x - drag.from[1];
      } else {
        const dx = event.clientX - drag.from[0], dy = event.clientY - drag.from[1];
        if (Math.abs(dx) + Math.abs(dy) > 3) drag.moved = true;
        stage.scrollLeft = drag.scroll[0] - dx;
        stage.scrollTop = drag.scroll[1] - dy;
        stage.classList.toggle("panning", drag.moved);
      }
      drawOverlay();
    };
    const onUp = (event) => {
      const drag = state.drag;
      if (!drag) return;
      state.drag = null;
      stage.classList.remove("panning");
      drawOverlay();
      if (drag.kind === "measure") {
        state.measure = { from: drag.from, to: drag.to };
        showMeasurement(state.measure);
        drawOverlay();
      } else if (drag.kind === "draw") {
        const pixels = N.polygonPixels(drag.points, last.height, last.width);
        if (pixels.length) edit({ add: [{ pixels }] });
        else status.textContent = "Draw around the cell: the ROI is the pixels inside the line";
      } else if (drag.kind === "move" && (drag.dy || drag.dx)) {
        edit({ move: [{ id: drag.roi.id, rows: drag.dy, columns: drag.dx }] });
      } else if (!(drag.kind === "pan" && drag.moved)) {
        const [y, x] = pixelAt(event);
        const roi = roiAt(y, x);
        select(roi ? roi.id : null, several(event));
      }
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
    /** The length of a measured line in pixels (image coordinates), and its angle from the rows. */
    function showMeasurement(line) {
      const dx = line.to[0] - line.from[0], dy = line.to[1] - line.from[1];
      const angle = Math.round(Math.atan2(-dy, dx) * 180 / Math.PI);
      measurement.textContent = `${Math.hypot(dx, dy).toFixed(1)} px · ${angle}°`;
      measurement.dataset.length = String(Math.hypot(dx, dy));
    }
    canvas.addEventListener("click", (event) => {
      if (!last || !state.rois || state.tool !== "polygon") return;
      const [py, px] = pointAt(event);
      const points = state.polygon;
      const first = points[0];
      const near = first && Math.hypot(first[0] - px, first[1] - py) < 1.5 && points.length >= 3;
      if (near) { finishPolygon(); return; }   // a click on the first corner closes it
      const previous = points[points.length - 1];
      if (!previous || previous[0] !== px || previous[1] !== py) points.push([px, py]);
      status.textContent = `${points.length} corner(s): click the first one or double-click to finish, Esc to start again`;
      drawOverlay();
    });
    canvas.addEventListener("dblclick", (event) => {
      if (state.tool !== "polygon") return;
      event.stopPropagation();
      finishPolygon();
    });
    function finishPolygon() {
      const points = state.polygon;
      state.polygon = [];
      drawOverlay();
      const pixels = points.length >= 3 ? N.polygonPixels(points, last.height, last.width) : [];
      if (pixels.length) edit({ add: [{ pixels }] });
      else status.textContent = "A polygon needs three corners or more around some pixels";
    }
    canvas.addEventListener("click", async (event) => {
      if (!last || !state.rois || (state.tool !== "circle" && state.tool !== "detect")) return;
      const [y, x] = pixelAt(event);
      if (state.tool === "circle") {
        const pixels = [];
        const r = state.radius;
        for (let dy = -r; dy <= r; dy++) for (let dx = -r; dx <= r; dx++) if (dy * dy + dx * dx <= r * r) pixels.push([y + dy, x + dx]);
        edit({ add: [{ pixels }] });
        return;
      }
      try {
        status.textContent = "Detecting…";
        const found = await app.client.request("rois.detect", { entityType, key, variable, point: [y, x], radius: Math.max(2 * state.radius, 4),
          channel: state.channel, plane: state.plane });
        if (found.pixels.length) edit({ add: [{ pixels: found.pixels }] });
        else status.textContent = "No cell found there: click on its bright middle, or draw it";
      } catch (error) { N.showError(error, "Could not detect an ROI"); }
    });

    // --- the ROI panel: actions, tools, the list --------------------------------------------------------------------
    const actions = [
      ["accept", "check", "Accept (a)", () => classify("accepted")],
      ["reject", "x", "Reject (r)", () => classify("rejected")],
      ["clear", "retry", "Clear (u)", () => classify(null)],
      ["delete", "trash", "Delete (Delete)", () => remove()],
    ].map(([name, icon, title, run]) => h(`button.btn.ghost.icon.small.roi-${name}`, { title, on: { click: run } }, N.icon(icon, 13)));
    const growButton = h("button.btn.ghost.icon.small.roi-grow", { title: "Grow the selected ROI by a pixel (+)", on: { click: () => reshape(1) } }, N.icon("plus", 13));
    const shrinkButton = h("button.btn.ghost.icon.small.roi-shrink", { title: "Shrink the selected ROI by a pixel (-)", on: { click: () => reshape(-1) } }, N.icon("minus", 13));
    const undoButton = h("button.btn.ghost.icon.small.roi-undo", { title: "Undo (Ctrl+Z)", on: { click: () => undo() } }, N.icon("undo", 13));
    const redoButton = h("button.btn.ghost.icon.small.roi-redo", { title: "Redo (Ctrl+Shift+Z)", on: { click: () => redo() } }, N.icon("redo", 13));
    const mergeButton = h("button.btn.ghost.icon.small.roi-merge", { title: "Merge the selected ROIs into one (m); Ctrl-click selects several", on: { click: () => merge() } }, N.icon("merge", 13));
    const galleryButton = h("button.btn.ghost.icon.small.viewer-gallery", { title: "Show the ROIs as a gallery", on: { click: () => gallery() } }, N.icon("grid", 13));
    const tools = [["circle", "circle", "Add a round ROI where you click", ".viewer-add"],
      ["draw", "freehand", "Draw an ROI: drag around the cell", ".viewer-draw"],
      ["polygon", "polygon", "Draw an ROI as a polygon: click its corners, then the first one again or double-click", ".viewer-polygon"],
      ["detect", "crosshair", "Detect the cell around where you click", ".viewer-detect"]].map(([name, icon, title, cls]) =>
      h(`button.btn.ghost.icon.small${cls}`, { title, dataset: { tool: name }, on: { click: () => setTool(state.tool === name ? null : name) } }, N.icon(icon, 13)));
    function setTool(name) {
      state.tool = name;
      state.polygon = [];
      drawOverlay();
      tools.forEach((b) => b.classList.toggle("active", b.dataset.tool === name));
      measureButton.classList.toggle("active", name === "measure");
      if (name !== "measure") { state.measure = null; measurement.textContent = ""; }
      canvas.classList.toggle("adding", name === "circle" || name === "detect");
      canvas.classList.toggle("drawing", name === "draw" || name === "polygon" || name === "measure");
    }
    // Find ROIs: run a segmentation method on this entity from here (dev's roimanager autosegmentation), then show its ROIs
    const findButton = h("button.btn.ghost.icon.small.viewer-find-rois", { title: "Find ROIs with a segmentation method", on: { click: () => findRois() } }, N.icon("zap", 13));
    async function findRois() {
      let methods = [];
      try { methods = await app.client.request("methods.list", { entityType }); } catch (error) { N.showError(error, "Could not list the methods"); return; }
      const language = app.info && app.info.language;
      const found = methods.filter((m) => /\/Segmentation$/.test(m.category || ""));
      if (!found.length) { N.toast("No segmentation methods", "The project's modules have none", "error"); return; }
      // a method only the other language has runs in a worker of that language (methods.run starts one)
      const elsewhere = (m) => language && m.languages && !m.languages.includes(language) ? ` (in ${m.languages[0] === "matlab" ? "MATLAB" : "Python"})` : "";
      N.menu(findButton, [{ heading: "Find ROIs with" }].concat(found.map((m) => ({ label: m.title + elsewhere(m), onClick: () => findWith(m) }))));
    }
    function findWith(method) {
      const properties = (method.options && method.options.properties) || {};
      const values = {};
      if ("stack" in properties) values.stack = variable;
      if ("output" in properties && (properties.output.default || "").startsWith("Roi") && !(properties.output.default || "").startsWith("RoiSignals")) values.output = state.roiVariable;
      if ("channel" in properties) values.channel = state.channel + 1;
      if ("plane" in properties) values.plane = state.plane + 1;
      const form = N.schemaForm(method.options || {}, values);
      N.dialog({
        title: method.title, narrow: true, content: h("div.viewer-find-form", h("p.muted", method.description || ""), form.el),
        buttons: [{ label: "Cancel" }, { label: "Find ROIs", kind: "primary", icon: "zap", onClick: async (close) => {
          const problems = form.validate();
          if (problems.length) { N.toast("Check the options", problems.join("; "), "error"); return; }
          close();
          N.toast("Finding ROIs", `${method.title}…`);
          try {
            await app.client.request("methods.run", { methodId: method.id, entityType, keys: [key], options: form.getValue() });
            state.rois = null;
            state.undo = [];
            state.redo = [];
            select(null);
            show();
            N.toast("ROIs found", method.title, "success");
          } catch (error) { N.showError(error, `${method.title} failed`); }
        } }],
      });
    }
    const radius = h("input.input.viewer-radius", { type: "number", min: 1, max: 50, value: state.radius, title: "Radius of a round ROI (px); Detect looks twice as far",
      on: { change: () => { state.radius = Math.max(1, Math.round(Number(radius.value) || 1)); } } });
    const hide = h("input", { type: "checkbox", on: { change: () => { state.hideRejected = hide.checked; redraw(); renderList(); } } });
    const roiList = h("ul.viewer-roi-list");
    const roiPanel = h("div.viewer-roi-panel",
      h("div.viewer-roi-actions", actions, mergeButton, growButton, shrinkButton, h("div.spacer"), undoButton, redoButton, galleryButton),
      h("div.viewer-roi-actions.viewer-roi-tools", tools, findButton, h("div.spacer"), radius),
      h("label.viewer-hide", hide, "Hide rejected"),
      roiList);

    // The selected ROI's signal under the image: the frame shown is marked, a click on the trace goes to that frame.
    // Saved signals come from a signal variable; "live" is the mean of the ROI's pixels read from the stack now
    // (rois.signal), for an ROI added or changed since the signals were extracted, which saved ones fall back to.
    const LIVE = "__live__";
    const signal = { variable: signalVariables.includes("RoiSignals_Dff") ? "RoiSignals_Dff" : signalVariables[0] || LIVE, counts: {}, range: [null, null] };
    const tracePlot = signalVariables.length || roiVariables.length ? N.tracePlot({
      height: 90,
      onPick: (frame) => { if (state.mode !== "frame") { state.mode = "frame"; mode.value = "frame"; } state.frame = frame; slider.value = String(frame); show(); },
      onRange: (start, stop) => { signal.range = [start, stop]; showSignal(); },
    }) : null;
    const signalPick = h("select.input.viewer-signal-pick", { on: { change: () => { signal.variable = signalPick.value; showSignal(); } } },
      signalVariables.map((v) => h("option", { value: v, selected: v === signal.variable }, v)),
      h("option", { value: LIVE, selected: signal.variable === LIVE }, "Live from the stack"));
    if (tracePlot) tracePlot.el.style.visibility = "hidden";   // its room kept, so the image does not move when it shows
    const signalHint = h("span.muted.viewer-signal-hint", "Select an ROI to see its signal");
    const signalPanel = tracePlot ? h("div.viewer-signal", h("div.viewer-signal-bar", signalPick, signalHint), tracePlot.el) : null;
    async function showSignal() {
      if (!tracePlot) return;
      if (state.selected === null || !state.rois) { signalHint.textContent = "Select an ROI to see its signal"; tracePlot.el.style.visibility = "hidden"; return; }
      const selected = state.selected;
      try {
        let column, live = signal.variable === LIVE;
        if (!live) {
          if (signal.counts[signal.variable] === undefined) {
            const probe = await app.client.request("data.traces", { entityType, key, variables: [signal.variable], columns: [] });
            signal.counts[signal.variable] = probe.traces[0].count;
          }
          const map = N.roiColumns(state.rois, signal.counts[signal.variable]);
          column = map ? map.get(selected) : undefined;
          live = column === undefined;   // added since the signals were extracted
        }
        const range = signal.range[0] !== null ? { start: signal.range[0], stop: signal.range[1] } : {};
        let result;
        if (live) {
          const roi = state.rois.find((r) => r.id === selected);
          if (!roi) return;
          result = await app.client.request("rois.signal", { entityType, key, variable, pixels: roi.pixels, channel: state.channel, plane: state.plane, maxPoints: 1200, ...range });
        } else {
          result = await app.client.request("data.traces", { entityType, key, variables: [signal.variable], columns: [column], maxPoints: 1200, ...range });
        }
        if (state.selected !== selected) return;   // another ROI was selected meanwhile
        tracePlot.el.style.visibility = "";
        tracePlot.draw(result, [`ROI ${selected}`]);
        tracePlot.cursor(state.mode === "frame" ? state.frame : null);
        signalHint.textContent = `ROI ${selected}` + (live ? " · live from the stack" : "") +
          (signal.range[0] !== null ? " · double-click for all frames" : " · drag to zoom, click to go to a frame");
      } catch (error) { signalHint.textContent = (error.code ? `[${error.code}] ` : "") + (error.message || String(error)); }
    }

    function renderList() {
      N.fill(roiList, visible().map((roi) => h("li" + (state.selection.has(roi.id) ? ".selected" : ""), { dataset: { roi: roi.id },
        on: { click: (event) => select(roi.id, several(event)) } },
        h("span.swatch", { style: { background: roi.classification === "rejected" ? "rgb(200,60,60)" : `rgb(${roiColor(state.rois.indexOf(roi)).join(",")})` } }),
        h("span.grow", `ROI ${roi.id}`), h("span.muted", `${roi.pixels.length} px`),
        roi.classification ? h("span.pill." + (roi.classification === "accepted" ? "good" : "bad"), roi.classification) : null)));
      actions.forEach((b) => { b.disabled = state.selection.size === 0; });
      mergeButton.disabled = state.selection.size < 2;
      growButton.disabled = shrinkButton.disabled = state.selection.size !== 1;
      undoButton.disabled = !state.undo.length;
      redoButton.disabled = !state.redo.length;
      galleryButton.disabled = !state.rois || !state.rois.length;
      roiPanel.style.display = state.rois && state.showRois ? "" : "none";
    }
    function redraw() { if (last) paint(canvas, last, state.rois, state.showRois, state.selection, state.hideRejected, state.colormap); drawOverlay(); }
    let onSelect = null;   // the gallery, while it is open
    /** Select an ROI (null for none); with add, add it to the selection, or take it out. */
    function select(id, add = false) {
      if (add && id !== null) {
        if (state.selection.has(id)) state.selection.delete(id); else state.selection.add(id);
        state.selected = state.selection.has(id) ? id : [...state.selection].pop() ?? null;
      } else {
        state.selection = new Set(id === null ? [] : [id]);
        state.selected = id;
      }
      redraw();
      renderList();
      showSignal();
      const item = roiList.querySelector(`li[data-roi="${state.selected}"]`);
      if (item) item.scrollIntoView({ block: "nearest" });
      if (onSelect) onSelect();
    }
    /** The ROIs as they are, to restore (undo and redo). */
    const snapshot = () => (state.rois || []).map((r) => ({ id: r.id, pixels: r.pixels, classification: r.classification || null }));
    // Edits run one after the other, so an undo or redo acts on what the edits before it left
    let queue = Promise.resolve();
    const enqueue = (task) => (queue = queue.then(task, task));
    function edit(change, history = "record") { return enqueue(() => apply(change, history)); }
    async function apply(change, history) {
      const before = snapshot();
      try {
        const result = await app.client.request("rois.update", { entityType, key, variable: state.roiVariable, channel: state.channel, plane: state.plane, ...change });
        if (history === "record") { state.undo.push(before); state.redo = []; }
        else if (history === "undo") state.redo.push(before);
        else if (history === "redo") state.undo.push(before);
        state.rois = result.rois;
        if (result.added.length) { state.selected = result.added[0]; state.selection = new Set([state.selected]); }
        state.selection = new Set([...state.selection].filter((id) => state.rois.some((r) => r.id === id)));
        if (!state.selection.has(state.selected)) state.selected = [...state.selection].pop() ?? null;
        redraw();
        renderList();
        showSignal();
        if (onSelect) onSelect();
        status.textContent = `${last.height} × ${last.width} · ${state.rois.length} ROIs`;
      } catch (error) { N.showError(error, "Could not change the ROIs"); }
    }
    const selectedIds = () => [...state.selection].sort((a, b) => a - b);
    function undo() { enqueue(() => (state.undo.length ? apply({ restore: state.undo.pop() }, "undo") : null)); }
    function redo() { enqueue(() => (state.redo.length ? apply({ restore: state.redo.pop() }, "redo") : null)); }
    /** Grow the selected ROI by its 4-neighbours inside the image (by 1), or keep only pixels whose 4-neighbours are all in it (by -1). */
    function reshape(by) {
      if (state.selection.size !== 1 || !last) return;
      const roi = state.rois.find((r) => r.id === state.selected);
      const has = new Set(roi.pixels.map(([y, x]) => `${y},${x}`));
      const sides = [[1, 0], [-1, 0], [0, 1], [0, -1]];
      let pixels;
      if (by > 0) {
        const out = new Map(roi.pixels.map(([y, x]) => [`${y},${x}`, [y, x]]));
        roi.pixels.forEach(([y, x]) => sides.forEach(([a, b]) => {
          const ny = y + a, nx = x + b;
          if (ny >= 0 && ny < last.height && nx >= 0 && nx < last.width) out.set(`${ny},${nx}`, [ny, nx]);
        }));
        pixels = [...out.values()];
      } else {
        pixels = roi.pixels.filter(([y, x]) => sides.every(([a, b]) => has.has(`${y + a},${x + b}`)));
        if (!pixels.length) { status.textContent = `ROI ${roi.id} is too small to shrink`; return; }
      }
      edit({ pixels: [{ id: roi.id, pixels }] });
    }
    function classify(label) { if (state.selection.size) edit({ classify: selectedIds().map((id) => ({ id, classification: label })) }); }
    function remove() { if (state.selection.size) edit({ remove: selectedIds() }); }
    function merge() {
      if (state.selection.size < 2) return;
      const ids = selectedIds();
      state.selection = new Set([ids[0]]);   // the merged ROI keeps the first id
      state.selected = ids[0];
      edit({ merge: [ids] });
    }
    function onKey(event) {
      if (event.target.tagName === "INPUT" || event.target.tagName === "SELECT" || !state.rois || !document.body.contains(canvas)) return;
      if (onSelect) return;   // the gallery has the keys
      const order = visible().map((r) => r.id);
      const at = order.indexOf(state.selected);
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "z") { if (event.shiftKey) redo(); else undo(); }
      else if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "y") redo();
      else if (event.key === "Escape" && state.tool === "polygon" && state.polygon.length) { state.polygon = []; drawOverlay(); event.stopPropagation(); }
      else if (event.key === "Escape" && state.tool) { setTool(null); event.stopPropagation(); }
      else if (event.ctrlKey || event.metaKey) return;
      else if (event.key === "+" || event.key === "=") reshape(1);
      else if (event.key === "-") reshape(-1);
      else if (event.key === "a") classify("accepted");
      else if (event.key === "r") classify("rejected");
      else if (event.key === "u") classify(null);
      else if (event.key === "m") merge();
      else if (event.key === "Delete" || event.key === "Backspace") remove();
      else if (event.altKey && event.key.startsWith("Arrow")) {   // move the selected ROI a pixel
        if (state.selected === null) return;
        const [rows, columns] = { ArrowUp: [-1, 0], ArrowDown: [1, 0], ArrowLeft: [0, -1], ArrowRight: [0, 1] }[event.key];
        edit({ move: [{ id: state.selected, rows, columns }] });
      } else if (event.key === "ArrowDown" || event.key === "j") select(order[Math.min(order.length - 1, at + 1)] ?? null);
      else if (event.key === "ArrowUp" || event.key === "k") select(order[Math.max(0, at - 1)] ?? null);
      else return;
      event.preventDefault();
    }
    document.addEventListener("keydown", onKey, true);

    // --- saving the image, and the gallery of ROIs ------------------------------------------------------------------
    function saveImage() {
      if (!last) return;
      const scale = Math.max(1, Math.floor(1024 / Math.max(last.width, last.height)));
      const out = document.createElement("canvas");
      out.width = last.width * scale;
      out.height = last.height * scale;
      const ctx = out.getContext("2d");
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(canvas, 0, 0, out.width, out.height);
      const name = `${N.fmt.key(key)}_${variable}_${state.mode === "frame" ? `frame${state.frame + 1}` : state.mode}.png`.replace(/[^\w.-]+/g, "_");
      const link = h("a", { href: out.toDataURL("image/png"), download: name });
      document.body.appendChild(link);
      link.click();
      link.remove();
      N.toast("Image saved", name, "success", 2500);
    }

    /** Export: the image as shown, as PNG, or frames of the stack as a TIFF file (ophys.export_tiff, when the project has it). */
    async function exportMenu() {
      let method = null;
      try {
        method = (await app.client.request("methods.list", { entityType })).find((m) => m.id === "ophys.export_tiff") || null;
      } catch (error) { /* the PNG is still there */ }
      const items = [{ label: "Image as PNG", icon: "download", onClick: () => saveImage() }];
      if (method && state.frames > 1) items.push({ label: "Stack as TIFF…", icon: "layers", onClick: () => exportTiff(method) });
      N.menu(exportButton, items);
    }

    function exportTiff(method) {
      const form = N.schemaForm(method.options || {}, { stack: variable, firstFrame: 1, lastFrame: state.frames,
        channel: state.channel + 1, plane: state.plane + 1 });
      N.dialog({
        title: `Export ${variable} as TIFF`, narrow: true,
        content: h("div.viewer-export-form", form.el),
        buttons: [
          { label: "Cancel" },
          { label: "Export", kind: "primary", icon: "download", onClick: async (close) => {
            const problems = form.validate();
            if (problems.length) { N.toast("Check the options", problems.join("; "), "error"); return; }
            close();
            N.toast("Exporting", `${variable} as TIFF…`);
            try {
              const result = await app.client.request("methods.run", { methodId: method.id, entityType, keys: [key], options: form.getValue() });
              const out = (result.results || [])[0] || {};
              N.toast("Exported", `${out.frames} frames to ${out.path}`, "success");
            } catch (error) { N.showError(error, "Could not export the stack"); }
          } },
        ],
      });
    }

    /** The ROIs as tiles of the image around each, for going through them by eye: sorted, selected, classified. */
    function gallery() {
      if (!last || !state.rois) return;
      const bytes = atob(last.pixels);
      const value = (y, x) => (y >= 0 && y < last.height && x >= 0 && x < last.width ? bytes.charCodeAt(y * last.width + x) : 0);
      const brightness = (roi) => roi.pixels.reduce((sum, [y, x]) => sum + value(y, x), 0) / Math.max(1, roi.pixels.length);
      const peaks = {};   // ROI id -> its largest ΔF/F, once asked for
      const sorts = { id: (r) => r.id, area: (r) => -r.pixels.length, brightness: (r) => -brightness(r),
        peak: (r) => (peaks[r.id] === undefined ? Infinity : -peaks[r.id]) };
      async function loadPeaks() {
        const count = (await app.client.request("data.traces", { entityType, key, variables: ["RoiSignals_Dff"], columns: [] })).traces[0].count;
        // ROIs added since the signals were extracted have higher ids and no column: the others are the first columns
        const kept = state.rois.filter((r) => r.classification !== "rejected");
        const map = N.roiColumns(state.rois, count) ||
          (kept.length > count ? new Map(kept.slice(0, count).map((r, i) => [r.id, i])) : null);
        if (!map) return;
        const ids = [...map.keys()];
        const result = await app.client.request("data.traces", { entityType, key, variables: ["RoiSignals_Dff"], columns: ids.map((id) => map.get(id)), maxPoints: 4000 });
        result.traces[0].columns.forEach((trace, i) => { peaks[ids[i]] = Math.max(...trace.values.filter((v) => v !== null)); });
      }
      let sortBy = "id";
      const grid = h("div.roi-gallery");
      const sortPick = h("select.input.roi-gallery-sort", { on: { change: async () => {
        sortBy = sortPick.value;
        if (sortBy === "peak" && !Object.keys(peaks).length) {
          try { await loadPeaks(); } catch (error) { N.showError(error, "Could not read the ΔF/F of the ROIs"); }
        }
        render();
      } } },
        h("option", { value: "id" }, "By id"), h("option", { value: "area" }, "Largest first"), h("option", { value: "brightness" }, "Brightest first"),
        signalVariables.includes("RoiSignals_Dff") ? h("option", { value: "peak" }, "Largest ΔF/F peak first") : null);
      const ordered = () => visible().slice().sort((a, b) => sorts[sortBy](a) - sorts[sortBy](b) || a.id - b.id);
      function tile(roi) {
        const half = 8, size = 2 * half + 1;
        const ys = roi.pixels.map((p) => p[0]), xs = roi.pixels.map((p) => p[1]);
        const top = Math.round((Math.min(...ys) + Math.max(...ys)) / 2) - half, left = Math.round((Math.min(...xs) + Math.max(...xs)) / 2) - half;
        const crop = h("canvas.roi-tile-image");
        crop.width = size;
        crop.height = size;
        const ctx = crop.getContext("2d");
        const image = ctx.createImageData(size, size);
        for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
          const v = value(top + y, left + x), i = 4 * (y * size + x);
          image.data[i] = v; image.data[i + 1] = v; image.data[i + 2] = v; image.data[i + 3] = 255;
        }
        const [r, g, b] = roi.classification === "rejected" ? [230, 70, 70] : roi.classification === "accepted" ? [70, 200, 110] : [255, 196, 0];
        edge(roi).forEach(([y, x]) => {
          if (y < top || y >= top + size || x < left || x >= left + size) return;
          const i = 4 * ((y - top) * size + x - left);
          image.data[i] = r; image.data[i + 1] = g; image.data[i + 2] = b;
        });
        ctx.putImageData(image, 0, 0);
        return h("button.roi-tile" + (state.selection.has(roi.id) ? ".selected" : "") + (roi.classification ? "." + roi.classification : ""),
          { dataset: { roi: roi.id }, title: `ROI ${roi.id}: ${roi.pixels.length} px`, on: { click: (event) => select(roi.id, several(event)) } },
          crop, h("span.roi-tile-label", `ROI ${roi.id}`));
      }
      function render() {
        N.fill(grid, ordered().map(tile));
        const chosen = grid.querySelector(`.roi-tile[data-roi="${state.selected}"]`);
        if (chosen) chosen.scrollIntoView({ block: "nearest" });
      }
      const keys = (event) => {
        if (event.target.tagName === "SELECT") return;
        const list = ordered().map((r) => r.id);
        const at = list.indexOf(state.selected);
        const perRow = Math.max(1, Math.round(grid.clientWidth / (grid.firstElementChild ? grid.firstElementChild.offsetWidth + 8 : 100)));
        const go = (i) => { if (list.length) select(list[Math.min(list.length - 1, Math.max(0, i))]); };
        if (event.key === "Escape") view.close();
        else if (event.key === "a") classify("accepted");
        else if (event.key === "r") classify("rejected");
        else if (event.key === "u") classify(null);
        else if (event.key === "ArrowRight") go(at + 1);
        else if (event.key === "ArrowLeft") go(at - 1);
        else if (event.key === "ArrowDown") go(at < 0 ? 0 : at + perRow);
        else if (event.key === "ArrowUp") go(at - perRow);
        else return;
        event.preventDefault();
        event.stopPropagation();
      };
      document.addEventListener("keydown", keys, true);
      onSelect = render;
      const view = N.dialog({ title: `ROIs · ${N.fmt.key(key)}`, content: h("div.roi-gallery-body",
        h("div.roi-gallery-bar", sortPick, h("span.muted", "Click a tile to select it; a, r and u classify it, the arrow keys go through them.")), grid),
        onClose: () => { document.removeEventListener("keydown", keys, true); onSelect = null; } });
      view.el.classList.add("roi-gallery-dialog");
      render();
    }

    // --- the frame --------------------------------------------------------------------------------------------------
    async function show() {
      if (state.busy) { state.pending = true; return; }
      state.busy = true;
      const params = { entityType, key, variable, channel: state.channel, plane: state.plane };
      if (state.mode === "frame") params.frame = state.frame; else params.projection = state.mode;
      if (!state.auto) params.limits = [state.low, state.high];
      if (state.showRois && state.roiVariable && !state.rois) params.rois = state.roiVariable;
      try {
        const frame = await app.client.request("data.frame", params);
        if (frame.rois) state.rois = frame.rois;
        if (initial !== null && state.rois && state.rois.some((r) => r.id === initial)) {
          const id = initial;
          initial = null;
          setTimeout(() => select(id), 0);
        }
        const resized = !last || last.width !== frame.width || last.height !== frame.height;
        last = frame;
        fillPick(channelPick, frame.channels || 1, "Channel", state.channel);
        fillPick(planePick, frame.planes || 1, "Plane", state.plane);
        state.frames = frame.frames;
        slider.max = String(Math.max(0, frame.frames - 1));
        slider.disabled = state.mode !== "frame" || frame.frames < 2;
        playButton.disabled = slider.disabled;
        if (state.auto) { state.low = frame.low; state.high = frame.high; low.value = String(frame.low); high.value = String(frame.high); }
        frameLabel.textContent = state.mode === "frame" ? `${state.frame + 1} / ${frame.frames}` : `${frame.frames} frames`;
        paint(canvas, frame, state.rois, state.showRois, state.selection, state.hideRejected, state.colormap);
        if (resized) layout(); else drawOverlay();
        renderList();
        if (tracePlot) tracePlot.cursor(state.mode === "frame" ? state.frame : null);
        status.textContent = `${frame.height} × ${frame.width}` + (state.rois && state.showRois ? ` · ${state.rois.length} ROIs` : "");
      } catch (error) {
        state.playing = false;
        status.textContent = (error.code ? `[${error.code}] ` : "") + (error.message || String(error));
      } finally {
        state.busy = false;
        if (state.pending) { state.pending = false; show(); }
        else if (state.playing) setTimeout(step, 80);
      }
    }

    function step() {
      if (!state.playing) return;
      state.frame = (state.frame + 1) % state.frames;
      slider.value = String(state.frame);
      show();
    }

    function toggle() {
      state.playing = !state.playing;
      N.fill(playButton, N.icon(state.playing ? "pause" : "play", 14));
      playButton.title = state.playing ? "Pause" : "Play";
      if (state.playing) step();
    }

    const content = h("div.viewer" + (signalPanel ? ".with-signal" : ""),
      h("div.viewer-bar",
        playButton, slider, frameLabel, mode, channelPick, planePick,
        h("label.viewer-contrast", auto, "Auto"), low, h("span.muted", "–"), high,
        colormapPick, roiVariables.length ? h("label.viewer-roi-toggle", roiToggle, "ROIs") : null, roiPick, measurement, measureButton, exportButton),
      h("div.viewer-main", stage, roiVariables.length ? roiPanel : null),
      signalPanel,
      h("div.viewer-foot", status, h("div.spacer"), where, zoomLabel));
    const dialog = N.dialog({ title: `${variable} · ${N.fmt.key(key)}`, content, onClose: () => {
      if (options.onClose) options.onClose();
      state.playing = false;
      resizing.disconnect();
      document.removeEventListener("keydown", onKey, true);
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
    } });
    dialog.el.classList.add("viewer-dialog");
    if (options.mode) { state.mode = options.mode; mode.value = options.mode; }
    show();
    return dialog;
  };
})();
