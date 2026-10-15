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
  function paint(canvas, frame, rois, showRois, selected = new Set(), hideRejected = false, colormap = "gray", outlines = false) {
    canvas.width = frame.width;
    canvas.height = frame.height;
    const ctx = canvas.getContext("2d");
    const image = ctx.createImageData(frame.width, frame.height);
    const table = lut(colormap);
    if (frame.layers) image.data.set(composeLayers(frame, table));   // channels in colour, planes side by side or projected
    const bytes = frame.layers ? "" : atob(frame.pixels);
    const bright = frame.brightness ? atob(frame.brightness) : null;   // peakTime: the hue is when, the brightness the peak
    for (let i = 0; i < bytes.length; i++) {
      if (bright) {
        const [r, g, b] = hsv(240 * (1 - bytes.charCodeAt(i) / 255), bright.charCodeAt(i) / 255);   // blue early, red late
        image.data[4 * i] = r; image.data[4 * i + 1] = g; image.data[4 * i + 2] = b; image.data[4 * i + 3] = 255;
        continue;
      }
      const v = 3 * bytes.charCodeAt(i);
      image.data[4 * i] = table[v]; image.data[4 * i + 1] = table[v + 1]; image.data[4 * i + 2] = table[v + 2]; image.data[4 * i + 3] = 255;
    }
    if (showRois && rois) {
      rois.forEach((roi, n) => {
        const rejected = roi.classification === "rejected";
        if (rejected && hideRejected) return;
        const [r, g, b] = rejected ? [200, 60, 60] : roiColor(n);
        const share = selected.has(roi.id) ? 1 : rejected ? 0.25 : outlines ? 0.9 : 0.5;
        (outlines ? edge(roi) : roi.pixels).forEach(([y, x]) => {
          if (y < 0 || y >= frame.height || x < 0 || x >= frame.width) return;
          const i = 4 * (y * frame.width + x);
          image.data[i] += (r - image.data[i]) * share; image.data[i + 1] += (g - image.data[i + 1]) * share; image.data[i + 2] += (b - image.data[i + 2]) * share;
        });
      });
    }
    ctx.putImageData(image, 0, 0);
  }

  /** Red, green and blue (0..255) of a hue (degrees) at full saturation and a value of 0..1. */
  function hsv(hue, value) {
    const c = value, x = c * (1 - Math.abs(((hue / 60) % 2) - 1));
    const [r, g, b] = hue < 60 ? [c, x, 0] : hue < 120 ? [x, c, 0] : hue < 180 ? [0, c, x] : hue < 240 ? [0, x, c] : hue < 300 ? [x, 0, c] : [c, 0, x];
    return [r, g, b].map((v) => Math.round(v * 255));
  }

  /* imviewer's channel colours: channels shown together, each in its colour and added up (dev's setChColors), with dev's
   * defaults for 2, 3 and 4 channels (getDefaultSettings' DefaultChannelColors_) and hsv(n) for other counts */
  const CHANNEL_COLORS = { 2: [[255, 0, 0], [0, 255, 255]], 3: [[255, 0, 0], [0, 255, 0], [0, 0, 255]],
    4: [[255, 0, 0], [128, 255, 0], [0, 255, 255], [128, 0, 255]] };
  N.channelColors = (count) => (CHANNEL_COLORS[count] || range(count).map((i) => hsv(360 * i / count, 1))).map((rgb) => rgb.slice());
  const range = (count) => Array.from({ length: count }, (_, i) => i);
  const hex = (rgb) => "#" + rgb.map((v) => v.toString(16).padStart(2, "0")).join("");
  const rgbOf = (text) => [1, 3, 5].map((i) => parseInt(text.slice(i, i + 2), 16));

  /** The grid of imviewer's plane montage: as near square as the planes allow, filled row by row, tiles pad pixels apart. */
  N.montageLayout = function (count, height, width, pad = 10) {
    const columns = Math.ceil(Math.sqrt(count)), rows = Math.ceil(count / columns);
    return { rows, columns, height: rows * height + (rows - 1) * pad, width: columns * width + (columns - 1) * pad,
      tiles: range(count).map((p) => ({ plane: p, y: Math.floor(p / columns) * (height + pad), x: (p % columns) * (width + pad), height, width })) };
  };

  function bytesOf(base64) {
    const text = atob(base64), out = new Uint8Array(text.length);
    for (let i = 0; i < text.length; i++) out[i] = text.charCodeAt(i);
    return out;
  }
  /** data.frame's bytes, scaled from low to high, scaled again from to[0] to to[1] (as data.frame rounds): planes on one scale. */
  function rescale(bytes, low, high, to) {
    if (low === to[0] && high === to[1]) return bytes;
    const out = new Uint8Array(bytes.length), span = to[1] - to[0];
    for (let i = 0; i < bytes.length; i++) {
      const value = low + bytes[i] / 255 * (high - low);
      out[i] = span > 0 ? Math.min(255, Math.max(0, Math.floor((value - to[0]) / span * 255 + 0.5))) : 0;
    }
    return out;
  }
  /** RGBA of a composed view's layers: one layer without a colour in the colormap, or each layer times its colour, added up. */
  function composeLayers(frame, table) {
    const count = frame.width * frame.height, out = new Uint8ClampedArray(4 * count);
    const layers = frame.layers;
    if (layers.length === 1 && !layers[0].color) {
      const bytes = layers[0].bytes;
      for (let i = 0; i < count; i++) {
        const v = 3 * bytes[i];
        out[4 * i] = table[v]; out[4 * i + 1] = table[v + 1]; out[4 * i + 2] = table[v + 2]; out[4 * i + 3] = 255;
      }
      return out;
    }
    for (let i = 0; i < count; i++) {
      let r = 0, g = 0, b = 0;
      for (const layer of layers) {
        const v = layer.bytes[i] / 255;
        r += v * layer.color[0]; g += v * layer.color[1]; b += v * layer.color[2];
      }
      out[4 * i] = r; out[4 * i + 1] = g; out[4 * i + 2] = b; out[4 * i + 3] = 255;   // clamped at 255
    }
    return out;
  }
  /** Each plane's number at the top left of its tile; coordinates times scale, in a font of size px. */
  function labelTiles(ctx, tiles, scale, size) {
    ctx.save();
    ctx.font = `${size}px system-ui, sans-serif`;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    ctx.fillStyle = "rgba(255, 255, 255, 0.95)";
    ctx.strokeStyle = "rgba(0, 0, 0, 0.8)";
    ctx.lineWidth = size / 5;
    tiles.forEach((t) => {
      const x = t.x * scale + size / 4, y = t.y * scale + size / 4;
      ctx.strokeText(`Plane ${t.plane + 1}`, x, y);
      ctx.fillText(`Plane ${t.plane + 1}`, x, y);
    });
    ctx.restore();
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

  /** The largest of 1, 2 or 5 times a power of ten that is at most value (a positive number): a scalebar's length. */
  N.roundLength = function (value) {
    const power = 10 ** Math.floor(Math.log10(value));
    return Number(([5, 2, 1].map((m) => m * power).find((v) => v <= value) || power).toPrecision(1));
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
   * options.file is a file of no entity (files.frame); options.viewable ({id, name, rois}) something `nansen view` or
   * nansen.view was given, with no project (view.frame): its ROIs, when it has some, are shown read only.
   */
  N.views.stackViewer = function (app, entityType, key, variable, roiVariables = [], signalVariables = [], options = {}) {
    let initial = options.select ?? null;
    const viewable = options.viewable || null;
    if (viewable) roiVariables = viewable.rois ? ["ROIs"] : [];
    const readOnly = Boolean(viewable);   // no project to save ROIs into
    // what the stack is called in file names and titles
    const title = viewable ? viewable.name : options.file ? options.file.path.split("/").pop() : `${variable} · ${N.fmt.key(key)}`;
    const stem = viewable ? viewable.name : options.file ? options.file.path.split("/").pop() : `${N.fmt.key(key)}_${variable}`;
    const state = { frame: 0, frames: 1, mode: "frame", auto: true, low: 0, high: 1, rois: null, roiVariable: roiVariables[0] || "", showRois: roiVariables.length > 0,
      playing: false, busy: false, pending: false, selected: null, selection: new Set(), tool: null, radius: 3, hideRejected: false, channel: 0, plane: 0,
      zoom: 1, drag: null, colormap: "gray", polygon: [], undo: [], redo: [], scalebar: false, labels: false, outlines: false, grid: false, links: false,
      // imviewer's channel colours and volume display: channels counted, shown together (null: not decided yet, on for a
      // stack with channels), which are shown in which colour, each one's contrast; planes one, side by side, or projected
      channels: 1, composite: null, shown: [], colors: [], channelLimits: [], planes: 1, volume: "single" };
    const canvas = h("canvas.viewer-canvas");
    const overlay = h("canvas.viewer-overlay");
    const holder = h("div.viewer-holder", canvas, overlay);
    const stage = h("div.viewer-stage", holder);
    const slider = h("input.viewer-slider", { type: "range", min: 0, max: 0, value: 0, on: { input: () => { state.frame = Number(slider.value); show(); } } });
    const frameLabel = h("span.viewer-frame.mono", "");
    const playButton = h("button.btn.ghost.icon.small.viewer-play", { title: "Play", on: { click: () => toggle() } }, N.icon("play", 14));
    const mode = h("select.input.viewer-mode", { on: { change: () => { state.mode = mode.value; show(); } } },
      h("option", { value: "frame" }, "Frames"), h("option", { value: "mean" }, "Average"), h("option", { value: "max" }, "Maximum"),
      h("option", { value: "min" }, "Minimum"), h("option", { value: "std" }, "Standard deviation"), h("option", { value: "correlation" }, "Local correlation"),
      h("option", { value: "globalCorrelation" }, "Global correlation"),
      h("option", { value: "peakTime" }, "Time of peak (colour)"));
    // imviewer's binning (Shift+B): the mean or max of the frames around the one shown, as it browses noisy frames
    const binPick = h("select.input.viewer-bin", { title: "Binning: the mean or maximum of the frames around this one (Shift+B)",
      on: { change: () => { state.bin = binPick.value; show(); } } },
      h("option", { value: "" }, "No binning"), [5, 10, 20, 50].map((n) => [h("option", { value: `mean:${n}` }, `Mean of ${n}`), h("option", { value: `max:${n}` }, `Max of ${n}`)]));
    // imviewer's 2-D filters, applied to the frame or projection shown
    const filterPick = h("select.input.viewer-filter", { title: "Filter", on: { change: () => { state.filter = filterPick.value; show(); } } },
      h("option", { value: "" }, "No filter"), h("option", { value: "smooth" }, "Smooth"), h("option", { value: "gradient" }, "Gradient"));
    const colormapPick = h("select.input.viewer-colormap", { title: "Colormap", on: { change: () => { state.colormap = colormapPick.value; redraw(); } } },
      N.colormaps.map((name) => h("option", { value: name }, name)));
    const low = h("input.input.viewer-low", { type: "number", step: "any", on: { change: () => { state.auto = false; auto.checked = false; state.low = Number(low.value); show(); } } });
    const high = h("input.input.viewer-high", { type: "number", step: "any", on: { change: () => { state.auto = false; auto.checked = false; state.high = Number(high.value); show(); } } });
    const auto = h("input", { type: "checkbox", checked: true, on: { change: () => { state.auto = auto.checked; show(); } } });
    const roiToggle = h("input.viewer-rois", { type: "checkbox", checked: state.showRois, on: { change: () => { state.showRois = roiToggle.checked; show(); } } });
    const roiPick = roiVariables.length > 1 ? h("select.input", { on: { change: () => { state.roiVariable = roiPick.value; state.rois = null; select(null); show(); } } },
      roiVariables.map((v) => h("option", { value: v }, v))) : null;
    // channel and plane pickers, shown once the stack turns out to have more than one
    // ROIs with places belong to a plane and channel: another place has its own, read again, and its own undo
    const toPlace = (change) => { change(); state.rois = null; state.undo = []; state.redo = []; select(null); show(); };
    const channelPick = h("select.input.viewer-channel", { style: { display: "none" }, on: { change: () => toPlace(() => pickChannel(Number(channelPick.value))) } });
    const planePick = h("select.input.viewer-plane", { style: { display: "none" }, on: { change: () => toPlace(() => { state.plane = Number(planePick.value); }) } });
    // imviewer's channel colours: the channels together, each in its colour (a box each to show it, and its colour); the
    // channel picked above is the one whose ROIs and contrast limits are at hand
    const composite = () => Boolean(state.composite) && state.channels > 1;
    const compositeToggle = h("input.viewer-composite", { type: "checkbox", on: { change: () => { state.composite = compositeToggle.checked; showChannels(); show(); } } });
    const compositeLabel = h("label.viewer-composite-label", { title: "Show the channels together, each in its colour; the contrast limits are the picked channel's",
      style: { display: "none" } }, compositeToggle, "Colour");
    const channelStrip = h("span.viewer-channel-strip", { style: { display: "none" } });
    function showChannels() {
      const on = composite();
      compositeLabel.style.display = state.channels > 1 ? "" : "none";
      compositeToggle.checked = on;
      channelStrip.style.display = on ? "" : "none";
      colormapPick.disabled = on;
      if (channelStrip.children.length !== state.channels) {
        N.fill(channelStrip, range(state.channels).map((c) => h("label.viewer-channel-toggle", { dataset: { channel: c }, title: `Channel ${c + 1}: show it, and its colour` },
          h("input.viewer-channel-shown", { type: "checkbox", checked: state.shown[c], on: { change: (event) => { state.shown[c] = event.target.checked; show(); } } }),
          h("input.viewer-channel-color", { type: "color", value: hex(state.colors[c]), on: { input: (event) => recolor(c, rgbOf(event.target.value)) } }),
          String(c + 1))));
      }
    }
    /** The stack's channels, counted anew: dev's colours, all shown, and the colours on for a stack that has several. */
    function setChannels(count) {
      state.channels = count;
      state.colors = N.channelColors(count);
      state.shown = state.colors.map(() => true);
      state.channelLimits = [];
      if (state.composite === null && count > 1) state.composite = true;
      N.fill(channelStrip);
      showChannels();
    }
    function recolor(channel, rgb) {
      state.colors[channel] = rgb;
      if (last && last.layers) last.layers.forEach((layer) => { if (layer.channel === channel) layer.color = rgb; });
      redraw();
    }
    /** Pick the channel at hand; with the channels in colour, each keeps its own contrast limits. */
    function pickChannel(channel) {
      if (composite() && channel !== state.channel) {
        state.channelLimits[state.channel] = { auto: state.auto, low: state.low, high: state.high };
        const own = state.channelLimits[channel] || { auto: true, low: state.low, high: state.high };
        Object.assign(state, { auto: own.auto, low: own.low, high: own.high });
        auto.checked = own.auto;
        low.value = String(own.low);
        high.value = String(own.high);
      }
      state.channel = channel;
    }
    // imviewer's volume display: one plane, the planes side by side (labelled), or their maximum or mean, the planes on
    // one scale; ROIs belong to a plane, so they are shown and edited with one plane only
    const volumePick = h("select.input.viewer-volume", { title: "Planes: one, side by side, or projected (imviewer's volume display)", style: { display: "none" },
      on: { change: () => { state.volume = volumePick.value; setTool(null); planePick.disabled = state.volume !== "single"; show(); } } },
      h("option", { value: "single" }, "One plane"), h("option", { value: "montage" }, "Plane montage"),
      h("option", { value: "max" }, "Maximum over planes"), h("option", { value: "mean" }, "Mean over planes"));
    const roisOn = () => state.showRois && state.volume === "single";
    const fillPick = (select, count, label, value) => {
      if (select.options.length !== count) N.fill(select, Array.from({ length: count }, (_, i) => h("option", { value: i, selected: i === value }, `${label} ${i + 1}`)));
      select.style.display = count > 1 ? "" : "none";
    };
    // the ruler: drag across the image to measure a distance, as dev's imviewer measurement tool
    const measureButton = h("button.btn.ghost.icon.small.viewer-measure", { title: "Measure a distance: drag across the image", on: { click: () => setTool(state.tool === "measure" ? null : "measure") } }, N.icon("ruler", 14));
    const measurement = h("span.viewer-measurement.mono", "");
    const gridButton = h("button.btn.ghost.icon.small.viewer-grid", { title: "Show a grid", on: { click: () => {
      state.grid = !state.grid;
      gridButton.classList.toggle("active", state.grid);
      drawOverlay();
    } } }, N.icon("crosshair", 14));
    // the scalebar, as imviewer's Show Scalebar: a round length of µm at the bottom left, when the files give the pixel size
    const scaleButton = h("button.btn.ghost.icon.small.viewer-scalebar-toggle", { title: "Show scalebar", style: { display: "none" },
      on: { click: () => { state.scalebar = !state.scalebar; drawScalebar(); } } }, N.icon("scalebar", 14));
    const scaleLine = h("div.viewer-scalebar-line");
    const scaleLabel = h("span.viewer-scalebar-label", "");
    const scalebar = h("div.viewer-scalebar", { style: { display: "none" } }, scaleLine, scaleLabel);
    holder.appendChild(scalebar);
    const timeLabel = h("span.viewer-time.mono", "");
    // which file adapter reads a file opened on its own, when more than one could
    const adapterPick = h("select.input.viewer-adapter", { title: "Read the file as", style: { display: "none" },
      on: { change: () => { state.adapter = adapterPick.value; state.frame = 0; slider.value = "0"; show(); } } });
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
    const roiAt = (y, x) => roisOn() && state.rois ?visible().find((r) => r.pixels.some(([py, px]) => py === y && px === x)) || null : null;

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
      drawScalebar();
    }
    /** The scalebar: about a fifth of the image's width, rounded down to 1, 2 or 5 times a power of ten µm. */
    function drawScalebar() {
      const size = last && last.metadata && last.metadata.pixelSize;
      scaleButton.style.display = size ? "" : "none";
      scaleButton.classList.toggle("active", state.scalebar);
      scalebar.style.display = size && state.scalebar ? "" : "none";
      if (!size || !state.scalebar) return;
      const um = N.roundLength(size[0] * last.width / 5);
      scaleLine.style.width = `${um / size[0] * holder.clientWidth / last.width}px`;
      scaleLabel.textContent = `${um} µm`;
    }
    /** The time of the frame shown, when the files give the frame rate. */
    function showTime() {
      const rate = last && last.metadata && last.metadata.frameRate;
      timeLabel.textContent = rate && state.mode === "frame" ? `${(state.frame / rate).toFixed(2)} s` : "";
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
      if (drag && drag.kind === "box") {   // the rectangle being dragged out to select ROIs
        ctx.strokeStyle = "rgba(90, 170, 255, 0.95)";
        ctx.fillStyle = "rgba(90, 170, 255, 0.15)";
        ctx.lineWidth = 1.5 * last.width / width;
        const [x0, y0] = drag.from, [x1, y1] = drag.to;
        ctx.fillRect(Math.min(x0, x1), Math.min(y0, y1), Math.abs(x1 - x0), Math.abs(y1 - y0));
        ctx.strokeRect(Math.min(x0, x1), Math.min(y0, y1), Math.abs(x1 - x0), Math.abs(y1 - y0));
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
      if (state.grid) {   // imviewer's grid: eight squares across the shorter side
        const step = Math.max(1, Math.min(last.width, last.height) / 8);
        ctx.strokeStyle = "rgba(255, 255, 255, 0.35)";
        ctx.lineWidth = last.width / width;
        ctx.beginPath();
        for (let x = step; x < last.width; x += step) { ctx.moveTo(x, 0); ctx.lineTo(x, last.height); }
        for (let y = step; y < last.height; y += step) { ctx.moveTo(0, y); ctx.lineTo(last.width, y); }
        ctx.stroke();
      }
      if (state.links && roisOn() && state.rois) {   // roimanager's ROI relations: a line between linked ROIs
        const centre = (roi) => [roi.pixels.reduce((t, p) => t + p[1], 0) / roi.pixels.length + 0.5, roi.pixels.reduce((t, p) => t + p[0], 0) / roi.pixels.length + 0.5];
        const byId = new Map(visible().map((r) => [r.id, r]));
        ctx.strokeStyle = "rgba(255, 220, 80, 0.9)";
        ctx.lineWidth = 1.5 * last.width / width;
        let drawn = 0;
        ctx.beginPath();
        byId.forEach((roi) => (roi.links || []).forEach((other) => {
          if (other <= roi.id || !byId.has(other) || !roi.pixels.length || !byId.get(other).pixels.length) return;
          const [x1, y1] = centre(roi), [x2, y2] = centre(byId.get(other));
          ctx.moveTo(x1, y1); ctx.lineTo(x2, y2);
          drawn++;
        }));
        ctx.stroke();
        canvas.dataset.links = String(drawn);
      }
      if (state.labels && roisOn() && state.rois) {
        ctx.font = `${Math.max(6, 11 * last.width / width)}px system-ui, sans-serif`;
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        ctx.fillStyle = "rgba(255, 255, 255, 0.95)";
        ctx.strokeStyle = "rgba(0, 0, 0, 0.7)";
        ctx.lineWidth = 2 * last.width / width;
        visible().forEach((roi) => {
          if (!roi.pixels.length) return;
          const y = roi.pixels.reduce((t, p) => t + p[0], 0) / roi.pixels.length + 0.5, x = roi.pixels.reduce((t, p) => t + p[1], 0) / roi.pixels.length + 0.5;
          ctx.strokeText(String(roi.id), x, y);
          ctx.fillText(String(roi.id), x, y);
        });
        canvas.dataset.labels = String(visible().length);
      }
      if (state.selection.size > 1 && roisOn() && state.rois) {
        ctx.fillStyle = "rgba(255, 255, 255, 0.45)";
        state.rois.filter((r) => state.selection.has(r.id)).forEach((roi) => edge(roi).forEach(([y, x]) => ctx.fillRect(x, y, 1, 1)));
      }
      if (last.tiles) labelTiles(ctx, last.tiles, 1, Math.max(4, 12 * last.width / width));   // the plane montage
      canvas.dataset.tiles = last.tiles ? String(last.tiles.length) : "";
    }

    // --- the mouse: tools, selection, moving an ROI and panning -----------------------------------------------------
    canvas.addEventListener("mousemove", (event) => {
      if (!last) return;
      const [y, x] = pixelAt(event);
      const roi = roiAt(y, x);
      const tile = last.tiles && last.tiles.find((t) => y >= t.y && y < t.y + t.height && x >= t.x && x < t.x + t.width);
      where.textContent = tile ? `plane ${tile.plane + 1}, row ${y - tile.y}, column ${x - tile.x}`
        : `row ${y}, column ${x}` + (roi ? ` · ROI ${roi.id}` : "");
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
      } else if (event.shiftKey && state.rois) {   // roimanager's multi-select: the ROIs inside a rectangle dragged out
        state.drag = { kind: "box", from: [px, py], to: [px, py], add: event.ctrlKey || event.metaKey };
      } else if (roi && roi.id === state.selected && !several(event) && !readOnly) {
        state.drag = { kind: "move", roi, from: [Math.floor(py), Math.floor(px)], dy: 0, dx: 0 };
      } else {
        state.drag = { kind: "pan", from: [event.clientX, event.clientY], scroll: [stage.scrollLeft, stage.scrollTop], moved: false };
      }
      event.preventDefault();
    });
    const onMove = (event) => {
      const drag = state.drag;
      if (!drag || !last) return;
      if (drag.kind === "draw" || drag.kind === "measure" || drag.kind === "box") {
        const [py, px] = pointAt(event);
        const point = [Math.min(last.width, Math.max(0, px)), Math.min(last.height, Math.max(0, py))];
        if (drag.kind === "draw") drag.points.push(point);
        else if (drag.kind === "box") drag.to = point;
        else { drag.to = point; showMeasurement(drag); }
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
      if (drag.kind === "box" && (Math.abs(drag.to[0] - drag.from[0]) >= 1 || Math.abs(drag.to[1] - drag.from[1]) >= 1)) {
        // every ROI shown whose centre is inside, added to the selection with Ctrl too
        const [x0, x1] = [Math.min(drag.from[0], drag.to[0]), Math.max(drag.from[0], drag.to[0])];
        const [y0, y1] = [Math.min(drag.from[1], drag.to[1]), Math.max(drag.from[1], drag.to[1])];
        const inside = visible().filter((r) => {
          if (!r.pixels.length) return false;
          const cy = r.pixels.reduce((t, p) => t + p[0], 0) / r.pixels.length + 0.5, cx = r.pixels.reduce((t, p) => t + p[1], 0) / r.pixels.length + 0.5;
          return cx >= x0 && cx <= x1 && cy >= y0 && cy <= y1;
        }).map((r) => r.id);
        state.selection = new Set([...(drag.add ? state.selection : []), ...inside]);
        state.selected = inside.length ? inside[0] : (state.selection.size ? [...state.selection][0] : null);
        redraw();
        renderList();
        showSignal();
        status.textContent = `${inside.length} ROI${inside.length === 1 ? "" : "s"} in the rectangle`;
      } else if (drag.kind === "box") {
        const [y, x] = pixelAt(event);
        const roi = roiAt(y, x);
        select(roi ? roi.id : null, true);   // a Shift-click without a drag adds to the selection, as before
      } else if (drag.kind === "measure") {
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
      const size = last && last.metadata && last.metadata.pixelSize;
      measurement.textContent = `${Math.hypot(dx, dy).toFixed(1)} px` + (size ? ` · ${Math.hypot(dx * size[0], dy * size[1]).toFixed(1)} µm` : "") + ` · ${angle}°`;
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
      ["unresolve", "alert", "Unresolved (q): not sure yet, as roiclassifier's", () => classify("unresolved")],
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
          const values = form.getValue();
          // into the variable on screen, which has ROIs: found into one of their own, then added to them as asked (dev's roimanager)
          const into = values.output && values.output === state.roiVariable && (await roisOnScreen()).length ? values.output : null;
          if (into) values.output = `${into}_Found`;
          N.toast("Finding ROIs", `${method.title}…`);
          try {
            const run = await app.client.request("methods.run", { methodId: method.id, entityType, keys: [key], options: values });
            if (into) {
              const found = run.results && run.results[0] && typeof run.results[0].rois === "number" ? `${run.results[0].rois} ROIs` : "ROIs";
              const mode = await askImportMode(`${method.title} found ${found}. ${into} has ${state.rois.length} here: should those found replace them, ` +
                "be appended, or be appended where they do not overlap one of them?");
              if (!mode) { N.toast("ROIs kept apart", `What ${method.title} found is in ${values.output}`); return; }
              await edit({ import: { variable: values.output, mode } });
              N.toast("ROIs found", `${method.title}, added to ${into} (Ctrl+Z undoes it)`, "success");
              return;
            }
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
    // Add ROIs to those on screen (dev's roimanager loadRois): those of another ROI variable, replacing them, appended, or
    // appended where they do not overlap one of them (rois.update's import); Ctrl+Z puts back the ROIs there were
    const IMPORT_MODES = [["replace", "Replace"], ["append", "Append"], ["appendNonOverlapping", "Append non-overlapping"]];
    /** Ask how ROIs join those on screen (roimanager's uiGetModeForAddingRois): resolves to a mode, or null. */
    function askImportMode(message) {
      return new Promise((resolve) => {
        N.dialog({
          title: "Add ROIs", narrow: true, content: h("div.viewer-import-mode", { style: { padding: "18px 20px" } }, message),
          buttons: [{ label: "Cancel", onClick: (close) => { resolve(null); close(); } }].concat(IMPORT_MODES.map(([mode, label]) => ({
            label, kind: mode === "append" ? "primary" : "", onClick: (close) => { resolve(mode); close(); } }))),
          onClose: () => resolve(null),
        });
      });
    }
    /** The ROIs of the variable on screen, read first when they are not shown. */
    async function roisOnScreen() {
      if (!state.rois && state.roiVariable) {
        state.showRois = true;
        roiToggle.checked = true;
        await show();
      }
      return state.rois || [];
    }
    const addFromButton = h("button.btn.ghost.icon.small.viewer-add-rois-from", { title: "Add ROIs from another ROI variable",
      on: { click: () => addRoisFrom() } }, N.icon("layers", 13));
    function addRoisFrom() {
      const others = roiVariables.filter((v) => v !== state.roiVariable);
      if (!others.length) { N.toast("No other ROI variables", "The project has no other ROI variable to add ROIs from", "error"); return; }
      N.menu(addFromButton, [{ heading: "Add ROIs from" }].concat(others.map((name) => ({ label: name, onClick: () => addFrom(name) }))));
    }
    async function addFrom(name) {
      const count = (await roisOnScreen()).length;
      const mode = count ? await askImportMode(`${state.roiVariable} has ${count} ROIs here: should those of ${name} replace them, be appended, ` +
        "or be appended where they do not overlap one of them?") : "append";
      if (!mode) return;
      await edit({ import: { variable: name, mode } });
    }
    const radius = h("input.input.viewer-radius", { type: "number", min: 1, max: 50, value: state.radius, title: "Radius of a round ROI (px); Detect looks twice as far",
      on: { change: () => { state.radius = Math.max(1, Math.round(Number(radius.value) || 1)); } } });
    const hide = h("input", { type: "checkbox", on: { change: () => { state.hideRejected = hide.checked; redraw(); renderList(); } } });
    // roimanager's display options: the ROIs' numbers on the image, and outlines in place of filled ROIs
    const labelToggle = h("input.viewer-roi-labels", { type: "checkbox", on: { change: () => { state.labels = labelToggle.checked; drawOverlay(); } } });
    const linkToggle = h("input.viewer-roi-links", { type: "checkbox", on: { change: () => { state.links = linkToggle.checked; drawOverlay(); } } });
    const outlineToggle = h("input.viewer-roi-outlines", { type: "checkbox", on: { change: () => { state.outlines = outlineToggle.checked; redraw(); } } });
    const roiList = h("ul.viewer-roi-list");
    // ROIs read only (no project to save them into): seen, selected and gone through in the gallery, not changed
    const roiPanel = h("div.viewer-roi-panel",
      readOnly ? h("div.viewer-roi-actions", h("span.muted.viewer-read-only-note", "Read only"), h("div.spacer"), galleryButton)
        : h("div.viewer-roi-actions", actions, mergeButton, growButton, shrinkButton, h("div.spacer"), undoButton, redoButton, galleryButton),
      readOnly ? null : h("div.viewer-roi-actions.viewer-roi-tools", tools, findButton, addFromButton, h("div.spacer"), radius),
      h("div.viewer-roi-display", h("label.viewer-hide", hide, "Hide rejected"), h("label.viewer-display-option", labelToggle, "Numbers"),
        h("label.viewer-display-option", outlineToggle, "Outlines"), h("label.viewer-display-option", linkToggle, "Links")),
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
          let map = N.roiColumns(state.rois, signal.counts[signal.variable]);
          if (!map && state.roiVariable) {
            // signals of every plane in one run (plane 0) have a column for each ROI of the file, whatever its plane,
            // while the image shows the ROIs of one plane: the columns follow the file's order of them all
            try {
              const all = await app.client.request("data.traces", { entityType, key, variables: [signal.variable], columns: [], rois: state.roiVariable });
              map = N.roiColumns(all.rois, signal.counts[signal.variable]);
            } catch (error) { map = null; }   // no ROI file yet: the live signal
          }
          column = map ? map.get(selected) : undefined;
          live = column === undefined;   // added since the signals were extracted
        }
        const range = signal.range[0] !== null ? { start: signal.range[0], stop: signal.range[1] } : {};
        let result;
        if (live) {
          const roi = state.rois.find((r) => r.id === selected);
          if (!roi) return;
          const where = viewable ? { viewable: viewable.id, ...(state.adapter ? { adapter: state.adapter } : {}) } : { entityType, key, variable };
          result = await app.client.request(viewable ? "view.signal" : "rois.signal", { ...where, pixels: roi.pixels, channel: state.channel, plane: state.plane, maxPoints: 1200, ...range });
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
        h("span.grow", `ROI ${roi.id}`, roi.cellType ? h("span.muted.roi-cell-type", ` · ${roi.cellType}`) : null,
          roi.links && roi.links.length ? h("span.muted.roi-links", { title: `Linked with ${roi.links.map((i) => "ROI " + i).join(", ")}` }, ` ↔ ${roi.links.join(", ")}`) : null),
        h("span.muted", `${roi.pixels.length} px`),
        roi.classification ? h("span.pill." + ({ accepted: "good", rejected: "bad" }[roi.classification] || "warn"), roi.classification) : null)));
      actions.forEach((b) => { b.disabled = state.selection.size === 0; });
      mergeButton.disabled = state.selection.size < 2;
      growButton.disabled = shrinkButton.disabled = state.selection.size !== 1;
      undoButton.disabled = !state.undo.length;
      redoButton.disabled = !state.redo.length;
      galleryButton.disabled = !state.rois || !state.rois.length;
      roiPanel.style.display = state.rois && roisOn() ? "" : "none";
    }
    function redraw() { if (last) paint(canvas, last, state.rois, roisOn(),state.selection, state.hideRejected, state.colormap, state.outlines); drawOverlay(); }
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
    const snapshot = () => (state.rois || []).map((r) => ({ id: r.id, pixels: r.pixels, classification: r.classification || null,
      cellType: r.cellType || null, links: r.links || null, ...(r.uid ? { uid: r.uid } : {}) }));
    // Edits run one after the other, so an undo or redo acts on what the edits before it left
    let queue = Promise.resolve();
    const enqueue = (task) => (queue = queue.then(task, task));
    function edit(change, history = "record") { return enqueue(() => apply(change, history)); }
    async function apply(change, history) {
      if (readOnly) { status.textContent = "These ROIs are read only: open them in a project to change them"; return; }
      const before = snapshot();
      try {
        const result = await app.client.request("rois.update", { entityType, key, variable: state.roiVariable, channel: state.channel, plane: state.plane,
          ...(last ? { imageSize: [last.height, last.width] } : {}), ...change });   // the size, for a variable's first ROIs
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
    // roimanager's cell types (Shift+E, I, X; again to clear) and links between ROIs (Shift+C: the selected one with the others)
    function setCellType(type) {
      if (!state.selection.size) return;
      const ids = selectedIds();
      const same = ids.every((id) => (state.rois.find((r) => r.id === id) || {}).cellType === type);
      edit({ cellType: ids.map((id) => ({ id, cellType: same ? null : type })) });
    }
    function linkRois() {
      if (state.selection.size < 2) return;
      const first = state.selection.has(state.selected) ? state.selected : selectedIds()[0];
      edit({ link: [[first, ...selectedIds().filter((id) => id !== first)]] });
    }
    function merge() {
      if (state.selection.size < 2) return;
      const ids = selectedIds();
      state.selection = new Set([ids[0]]);   // the merged ROI keeps the first id
      state.selected = ids[0];
      edit({ merge: [ids] });
    }
    function onKey(event) {
      if (event.key === "B" && !event.ctrlKey && !event.metaKey && state.mode === "frame" && document.body.contains(canvas)
          && !["INPUT", "SELECT", "TEXTAREA"].includes(event.target.tagName)) {   // imviewer's binning toggle
        state.binLast = state.bin || state.binLast || "mean:10";
        state.bin = state.bin ? "" : state.binLast;
        binPick.value = state.bin;
        show();
        return;
      }
      if (event.target.tagName === "INPUT" || event.target.tagName === "SELECT" || !state.rois || !document.body.contains(canvas)) return;
      if (state.volume !== "single") return;   // the ROIs are of one plane
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
      else if (event.key === "q") classify("unresolved");
      else if (event.key === "u") classify(null);
      else if (event.key === "m") merge();
      else if (event.key === "E") setCellType("excitatory");
      else if (event.key === "I") setCellType("inhibitory");
      else if (event.key === "X") setCellType("axon");
      else if (event.key === "C") linkRois();
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
      if (last.tiles) labelTiles(ctx, last.tiles, scale, tileFont(scale));
      const planes = last.layers && state.volume !== "single" ? `_planes${state.volume === "montage" ? "" : state.volume}` : "";
      const name = `${stem}_${state.mode === "frame" ? `frame${state.frame + 1}` : state.mode}${planes}.png`.replace(/[^\w.-]+/g, "_");
      const link = h("a", { href: out.toDataURL("image/png"), download: name });
      document.body.appendChild(link);
      link.click();
      link.remove();
      N.toast("Image saved", name, "success", 2500);
    }

    /**
     * The frames as a WebM video, as imviewer's ROI signal video: each frame as shown (contrast, colormap, filter, ROIs), and
     * under it the selected ROI's trace with the frame marked; frames first..last at a chosen rate. Recorded in the browser.
     */
    async function saveVideo() {
      const values = await new Promise((resolve) => {
        const form = N.schemaForm({ type: "object", properties: {
          first: { type: "integer", title: "First frame", minimum: 1 },
          last: { type: "integer", title: "Last frame", minimum: 1 },
          fps: { type: "number", title: "Frames per second", minimum: 1, maximum: 60 },
        } }, { first: 1, last: Math.min(state.frames, 300), fps: Math.min(60, (last && last.metadata && last.metadata.frameRate) || 20) });
        const d = N.dialog({ title: "Save a video", narrow: true, content: h("div.viewer-video-form", { style: { padding: "12px 16px" } }, form.el),
          buttons: [{ label: "Cancel", onClick: (close) => { resolve(null); close(); } },
            { label: "Record", kind: "primary", onClick: (close) => { resolve(form.getValue()); close(); } }],
          onClose: () => resolve(null) });
        d.el.classList.add("video-dialog");
      });
      if (!values || !last) return;
      const first = Math.max(1, Math.min(values.first, state.frames)) - 1, final = Math.max(first + 1, Math.min(values.last, state.frames)) - 1;
      const scale = Math.max(1, Math.floor(512 / Math.max(last.width, last.height)));
      const trace = tracePlot && tracePlot.el.style.visibility !== "hidden" ? tracePlot.canvas : null;
      const out = document.createElement("canvas");
      out.width = last.width * scale;
      out.height = last.height * scale + (trace ? Math.round(trace.height * out.width / trace.width) : 0);
      const ctx = out.getContext("2d");
      const stream = out.captureStream(0);
      const recorder = new MediaRecorder(stream, { mimeType: "video/webm" });
      const chunks = [];
      recorder.ondataavailable = (event) => { if (event.data.size) chunks.push(event.data); };
      const done = new Promise((resolve) => { recorder.onstop = resolve; });
      const frameCanvas = document.createElement("canvas");
      const was = { mode: state.mode, frame: state.frame, playing: state.playing };
      state.playing = false;
      recorder.start();
      N.toast("Recording", `frames ${first + 1}–${final + 1}…`);
      try {
        for (let f = first; f <= final; f++) {
          const frame = await fetchView({ frame: f }, false);   // as shown: channels in colour, planes side by side or projected
          paint(frameCanvas, frame, state.rois, roisOn(), state.selection, state.hideRejected, state.colormap, state.outlines);
          ctx.fillStyle = "#000";
          ctx.fillRect(0, 0, out.width, out.height);
          ctx.imageSmoothingEnabled = false;
          ctx.drawImage(frameCanvas, 0, 0, last.width * scale, last.height * scale);
          if (frame.tiles) labelTiles(ctx, frame.tiles, scale, tileFont(scale));
          if (trace) {
            tracePlot.cursor(f);
            ctx.fillStyle = "#fff";
            ctx.fillRect(0, last.height * scale, out.width, out.height - last.height * scale);
            ctx.drawImage(trace, 0, last.height * scale, out.width, out.height - last.height * scale);
          }
          stream.getVideoTracks()[0].requestFrame();
          await new Promise((resolve) => setTimeout(resolve, 1000 / values.fps));
        }
      } catch (error) { N.showError(error, "Could not record the video"); }
      recorder.stop();
      await done;
      if (tracePlot) tracePlot.cursor(was.mode === "frame" ? was.frame : null);
      const name = `${stem}_frames${first + 1}-${final + 1}.webm`.replace(/[^\w.-]+/g, "_");
      const link = h("a", { href: URL.createObjectURL(new Blob(chunks, { type: "video/webm" })), download: name });
      document.body.appendChild(link);
      link.click();
      link.remove();
      N.toast("Video saved", name, "success", 2500);
    }

    /** Export: the image as shown, as PNG, or frames of the stack as a TIFF file (ophys.export_tiff, when the project has it). */
    async function exportMenu() {
      let method = null;
      try {
        if (!options.file && !viewable) method = (await app.client.request("methods.list", { entityType })).find((m) => m.id === "ophys.export_tiff") || null;
      } catch (error) { /* the PNG is still there */ }
      const items = [{ label: "Image as PNG", icon: "download", onClick: () => saveImage() }];
      if (state.frames > 1 && window.MediaRecorder) items.push({ label: "Video with the ROI's signal…", icon: "play", onClick: () => saveVideo() });
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
      // dev's classifier images and statistics, when ophys.roi_images has saved them (RoiImages)
      let classifier = null;
      const imageOf = (roi, name) => {
        if (!classifier || name === "frame") return null;
        const at = classifier.ids.indexOf(roi.id);
        return at < 0 ? null : classifier.images[name][at];
      };
      const statOf = (roi, name) => {
        const at = classifier ? classifier.ids.indexOf(roi.id) : -1;
        const value = at < 0 ? null : classifier.stats[name][at];
        return value === null || value === undefined ? Infinity : -value;   // largest first; none last
      };
      const loadClassifier = (viewable ? Promise.reject(new Error("no project")) : app.client.request("data.value", { entityType, key, variable: "RoiImages" })).then(({ value }) => {
        const list = (v) => [].concat(v);   // one ROI's lists may come back as a single value
        classifier = { boxSize: value.boxSize, ids: list(value.ids), images: {}, stats: {} };
        for (const [name, images] of Object.entries(value.images || {})) classifier.images[name] = list(images).map(list);
        if (classifier.ids.length === 1) for (const name of Object.keys(classifier.images)) classifier.images[name] = [classifier.images[name].flat()];
        for (const [name, values] of Object.entries(value.stats || {})) classifier.stats[name] = list(values);
        for (const [name, label] of [["activityWeightedMean", "Activity-weighted mean"], ["top1Percent", "Top 1% ΔF/F frames"], ["localCorrelation", "Local correlation"]]) {
          if (classifier.images[name]) imagePick.appendChild(h("option", { value: name }, label));
        }
        for (const [name, label] of [["salience", "Most salient first"], ["meanSimilarity", "Most typical image first"], ["correlationSimilarity", "Most typical correlation first"]]) {
          if (classifier.stats[name]) sortPick.appendChild(h("option", { value: name }, label));
        }
        if (classifier.stats.peakDff) Object.assign(peaks, Object.fromEntries(classifier.ids.map((id, i) => [id, classifier.stats.peakDff[i] ?? -Infinity])));
        imagePick.disabled = false;
      }).catch(() => { /* not computed: the frame's crops and the basic sorts */ });
      let imageName = "frame";
      const imagePick = h("select.input.roi-gallery-image", { title: "The image of each tile", disabled: true, on: { change: () => { imageName = imagePick.value; render(); } } },
        h("option", { value: "frame" }, "Frame shown"));
      let showOnly = "all";
      const showPick = h("select.input.roi-gallery-show", { title: "Show", on: { change: () => { showOnly = showPick.value; render(); } } },
        h("option", { value: "all" }, "All ROIs"), h("option", { value: "accepted" }, "Accepted"), h("option", { value: "rejected" }, "Rejected"),
        h("option", { value: "unresolved" }, "Unresolved"), h("option", { value: "none" }, "Unclassified"));
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
      for (const name of ["salience", "meanSimilarity", "correlationSimilarity"]) sorts[name] = (r) => statOf(r, name);
      const shown = (r) => showOnly === "all" || (showOnly === "none" ? !r.classification : r.classification === showOnly);
      const ordered = () => visible().filter(shown).sort((a, b) => sorts[sortBy](a) - sorts[sortBy](b) || a.id - b.id);
      function tile(roi) {
        const own = imageOf(roi, imageName);   // a classifier image: a box around the ROI's center, 0..255
        const half = own ? (classifier.boxSize - 1) / 2 : 8, size = 2 * half + 1;
        const ys = roi.pixels.map((p) => p[0]), xs = roi.pixels.map((p) => p[1]);
        const center = own ? [roi.pixels.reduce((t, p) => t + p[0], 0) / roi.pixels.length, roi.pixels.reduce((t, p) => t + p[1], 0) / roi.pixels.length].map((v) => Math.floor(Math.floor(v * 100 + 0.5) / 100 + 0.5))   // as roi_images: the saved center (2 decimals), rounded half up
          : [Math.round((Math.min(...ys) + Math.max(...ys)) / 2), Math.round((Math.min(...xs) + Math.max(...xs)) / 2)];
        const top = center[0] - half, left = center[1] - half;
        const crop = h("canvas.roi-tile-image");
        crop.width = size;
        crop.height = size;
        const ctx = crop.getContext("2d");
        const image = ctx.createImageData(size, size);
        for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
          const v = own ? Math.round(own[y * size + x] ?? 0) : value(top + y, left + x), i = 4 * (y * size + x);
          image.data[i] = v; image.data[i + 1] = v; image.data[i + 2] = v; image.data[i + 3] = 255;
        }
        const [r, g, b] = roi.classification === "rejected" ? [230, 70, 70] : roi.classification === "accepted" ? [70, 200, 110]
          : roi.classification === "unresolved" ? [170, 110, 255] : [255, 196, 0];
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
        else if (event.key === "q") classify("unresolved");
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
      const view = N.dialog({ title: `ROIs · ${viewable ? viewable.name : N.fmt.key(key)}`, content: h("div.roi-gallery-body",
        h("div.roi-gallery-bar", imagePick, sortPick, showPick, h("span.muted", "Click a tile to select it; a, r, q and u accept, reject, mark unresolved and clear it; the arrow keys go through them.")), grid),
        onClose: () => { document.removeEventListener("keydown", keys, true); onSelect = null; } });
      view.el.classList.add("roi-gallery-dialog");
      render();
      loadClassifier.then(render);
    }

    // --- the frame --------------------------------------------------------------------------------------------------
    /**
     * The frame or projection at ({frame} or {projection}) as it is shown. One channel and plane is data.frame's (or
     * files.frame's) answer; channels in colour and planes side by side or projected are composed here from one answer
     * per channel and plane (imviewer's setChColors and plane montage and projection): each channel scaled by its own
     * limits, and every plane of a channel brought to one scale, from the lowest low to the highest high of them. The
     * composed view has the answer's fields, its size, layers ({channel, bytes, color}) and, for the montage, tiles.
     */
    async function fetchView(at, withRois) {
      // a file of no entity (options.file: as files.resolve takes it) is read by files.frame, as dev's imviewer opens any
      // file; what `nansen view` was given, by view.frame, with no project
      const base = viewable ? { viewable: viewable.id, ...at } : options.file ? { ...options.file, ...at } : { entityType, key, variable, ...at };
      if ((options.file || viewable) && state.adapter) base.adapter = state.adapter;
      if (state.filter) base.filter = state.filter;
      const method = viewable ? "view.frame" : options.file ? "files.frame" : "data.frame";
      const limitsOf = (c) => {
        if (c === state.channel) return state.auto ? null : [state.low, state.high];
        const own = state.channelLimits[c];
        return own && !own.auto ? [own.low, own.high] : null;
      };
      const ask = (c, p, more = {}) => app.client.request(method, { ...base, channel: c, plane: p, ...(limitsOf(c) ? { limits: limitsOf(c) } : {}), ...more });
      const rois = withRois && state.showRois && state.roiVariable && !state.rois ? { rois: viewable ? true : state.roiVariable } : {};
      const colour = composite() && at.projection !== "peakTime";   // the time of peak has its own colours
      const planes = state.volume !== "single" && state.planes > 1 && at.projection !== "peakTime" ? range(state.planes) : null;
      if (!colour && !planes) return ask(state.channel, state.plane, rois);
      // the channel at hand is read even when hidden: its ROIs and limits
      const channels = colour ? range(state.channels).filter((c) => state.shown[c] || c === state.channel) : [state.channel];
      const answers = await Promise.all(channels.map((c) => Promise.all((planes || [state.plane]).map((p) =>
        ask(c, p, !planes && c === state.channel ? rois : {})))));
      const first = answers[0][0], own = answers[channels.indexOf(state.channel)];
      const view = { ...first, pixels: planes ? undefined : own[0].pixels, rois: planes ? undefined : own[0].rois, brightness: undefined, layers: [] };
      const size = first.width * first.height;
      const layout = planes && state.volume === "montage" ? N.montageLayout(planes.length, first.height, first.width) : null;
      if (layout) Object.assign(view, { height: layout.height, width: layout.width, tiles: layout.tiles });
      channels.forEach((c, k) => {
        const low = Math.min(...answers[k].map((f) => f.low ?? 0)), high = Math.max(...answers[k].map((f) => f.high ?? 0));
        const each = answers[k].map((f) => rescale(bytesOf(f.pixels), f.low ?? 0, f.high ?? 0, [low, high]));
        let bytes = each[0];
        if (layout) {
          bytes = new Uint8Array(layout.width * layout.height);
          layout.tiles.forEach((t, p) => { for (let y = 0; y < t.height; y++) bytes.set(each[p].subarray(y * t.width, (y + 1) * t.width), (t.y + y) * layout.width + t.x); });
        } else if (planes) {
          bytes = new Uint8Array(size);
          for (let i = 0; i < size; i++) {
            let top = 0, sum = 0;
            for (const plane of each) { top = Math.max(top, plane[i]); sum += plane[i]; }
            bytes[i] = state.volume === "max" ? top : Math.floor(sum / each.length + 0.5);
          }
        }
        if (c === state.channel) Object.assign(view, { low, high });
        else if (!(state.channelLimits[c] && !state.channelLimits[c].auto)) state.channelLimits[c] = { auto: true, low, high };
        if (!colour || state.shown[c]) view.layers.push({ channel: c, bytes, color: colour ? state.colors[c] : null });
      });
      return view;
    }
    const tileFont = (scale) => Math.min(32, Math.max(12, Math.round(last.tiles[0].height * scale / 8)));

    async function show() {
      if (state.busy) { state.pending = true; return; }
      state.busy = true;
      try {
        const binning = state.mode === "frame" && state.bin ? { bin: { method: state.bin.split(":")[0], size: Number(state.bin.split(":")[1]) } } : {};
        const frame = await fetchView(state.mode === "frame" ? { frame: state.frame, ...binning } : { projection: state.mode }, true);
        if (frame.adapters && frame.adapters.length > 1 && adapterPick.options.length !== frame.adapters.length) {
          N.fill(adapterPick, frame.adapters.map((id) => h("option", { value: id }, id)));
          adapterPick.style.display = "";
        }
        if (frame.adapter) adapterPick.value = frame.adapter;
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
        if ((frame.channels || 1) !== state.colors.length) {   // a stack (or file adapter) of another number of channels
          setChannels(frame.channels || 1);
          if (composite()) state.pending = true;   // shown again with its channels in colour
        }
        state.planes = frame.planes || 1;
        volumePick.style.display = state.planes > 1 ? "" : "none";
        if (state.planes < 2 && state.volume !== "single") { state.volume = volumePick.value = "single"; planePick.disabled = false; }
        state.frames = frame.frames;
        slider.max = String(Math.max(0, frame.frames - 1));
        slider.disabled = state.mode !== "frame" || frame.frames < 2;
        playButton.disabled = slider.disabled;
        if (state.auto) { state.low = frame.low; state.high = frame.high; low.value = String(frame.low); high.value = String(frame.high); }
        frameLabel.textContent = state.mode === "frame" ? `${state.frame + 1} / ${frame.frames}` + (frame.binned ? ` (${frame.binned[0] + 1}–${frame.binned[1]})` : "")
          : `${frame.frames} frames`;
        binPick.disabled = state.mode !== "frame";
        showTime();
        paint(canvas, frame, state.rois, roisOn(), state.selection, state.hideRejected, state.colormap, state.outlines);
        if (resized) layout(); else { drawOverlay(); drawScalebar(); }
        renderList();
        if (tracePlot) tracePlot.cursor(state.mode === "frame" ? state.frame : null);
        const planes = frame.layers && state.volume !== "single" && state.planes > 1 && state.mode !== "peakTime"
          ? ({ montage: " · %d planes side by side", max: " · maximum of %d planes", mean: " · mean of %d planes" })[state.volume].replace("%d", state.planes) : "";
        const [height, width] = frame.tiles ? [frame.tiles[0].height, frame.tiles[0].width] : [frame.height, frame.width];
        status.textContent = `${height} × ${width}` + planes + (state.rois && roisOn() ? ` · ${state.rois.length} ROIs` : "");
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
        playButton, slider, frameLabel, timeLabel, mode, channelPick, compositeLabel, channelStrip, planePick, volumePick, adapterPick,
        h("label.viewer-contrast", auto, "Auto"), low, h("span.muted", "–"), high,
        binPick, filterPick, colormapPick, roiVariables.length ? h("label.viewer-roi-toggle", roiToggle, "ROIs") : null, roiPick, measurement, measureButton, scaleButton,
        exportButton),
      h("div.viewer-main", stage, roiVariables.length ? roiPanel : null),
      signalPanel,
      h("div.viewer-foot", status, h("div.spacer"), where, zoomLabel, gridButton));
    const dialog = N.dialog({ title, content, onClose: () => {
      if (options.onClose) options.onClose();
      state.playing = false;
      resizing.disconnect();
      document.removeEventListener("keydown", onKey, true);
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
    } });
    dialog.el.classList.add("viewer-dialog");
    if (readOnly) dialog.el.classList.add("viewer-read-only");
    if (options.mode) { state.mode = options.mode; mode.value = options.mode; }
    show();
    return dialog;
  };
})();
