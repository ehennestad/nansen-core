/* The stack viewer: frames and projections of an image variable, with ROIs drawn over them (data.frame).
 *
 * ROIs are curated here, as in dev's roimanager: selected (Ctrl-click for several), classified (a, r, u), deleted,
 * moved by dragging, merged, and added: as a circle, drawn freehand, or detected around a click (rois.detect).
 * The wheel zooms and dragging the image pans it; the image can be saved as PNG, the stack exported as TIFF, and the
 * ROIs shown as a gallery. The selected ROI's neuropil can be shown over it (rois.neuropil), and another stack of the
 * entity, or of another one, beside it with the frame, zoom and pan in step (imviewer's Link to Another Viewer).
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
    // the rest of imviewer's colormaps (its settings' colorMap_): MATLAB's, ColorBrewer's and cmocean's, as colour stops
    copper: [[0, 0, 0], [255, 159, 101], [255, 199, 127]],
    bone: [[0, 0, 0], [84, 84, 116], [166, 198, 198], [255, 255, 255]],
    nissl: [[253, 252, 247], [244, 236, 224], [230, 211, 191], [218, 188, 158], [198, 150, 140], [177, 107, 140], [157, 65, 136], [124, 15, 129], [75, 0, 77]],
    bupu: [[247, 252, 253], [224, 236, 244], [191, 211, 230], [158, 188, 218], [140, 150, 198], [140, 107, 177], [136, 65, 157], [129, 15, 124], [77, 0, 75]],
    gnbu: [[247, 252, 240], [224, 243, 219], [204, 235, 197], [168, 221, 181], [123, 204, 196], [78, 179, 211], [43, 140, 190], [8, 104, 172], [8, 64, 129]],
    greens: [[247, 252, 245], [229, 245, 224], [199, 233, 192], [161, 217, 155], [116, 196, 118], [65, 171, 93], [35, 139, 69], [0, 109, 44], [0, 68, 27]],
    pubugn: [[1, 70, 54], [1, 108, 89], [2, 129, 138], [54, 144, 192], [103, 169, 207], [166, 189, 219], [208, 209, 230], [236, 226, 240], [255, 247, 251]],
    ylorrd: [[255, 255, 204], [255, 237, 160], [254, 217, 118], [254, 178, 76], [253, 141, 60], [252, 78, 42], [227, 26, 28], [189, 0, 38], [128, 0, 38]],
    thermal: [[4, 35, 51], [23, 51, 122], [85, 59, 157], [129, 79, 143], [175, 95, 130], [222, 112, 100], [249, 147, 65], [249, 197, 51], [232, 250, 91]],
    haline: [[41, 24, 107], [42, 62, 170], [15, 107, 150], [44, 135, 135], [67, 163, 124], [103, 190, 103], [165, 212, 90], [253, 238, 153]],
    solar: [[51, 20, 24], [96, 30, 34], [139, 48, 22], [173, 79, 10], [199, 117, 7], [219, 160, 25], [232, 206, 57], [224, 253, 74]],
    ice: [[4, 6, 19], [34, 33, 72], [56, 58, 128], [62, 90, 175], [63, 128, 197], [85, 166, 210], [137, 201, 222], [234, 253, 253]],
    deep: [[253, 254, 204], [180, 226, 175], [110, 196, 165], [64, 160, 167], [57, 120, 159], [61, 81, 147], [60, 48, 103], [40, 26, 44]],
    dense: [[230, 241, 241], [175, 210, 226], [132, 174, 224], [118, 133, 224], [121, 91, 206], [118, 52, 163], [99, 23, 105], [54, 14, 36]],
    algae: [[215, 249, 208], [167, 219, 155], [112, 190, 107], [56, 159, 73], [16, 125, 62], [11, 92, 52], [16, 61, 35], [17, 36, 20]],
    matter: [[254, 237, 176], [248, 191, 130], [238, 145, 98], [218, 99, 90], [180, 64, 96], [136, 40, 96], [89, 23, 80], [47, 15, 61]],
    turbid: [[233, 246, 171], [211, 207, 137], [193, 168, 104], [172, 130, 82], [145, 98, 67], [110, 72, 56], [73, 51, 42], [34, 30, 21]],
    speed: [[255, 253, 205], [221, 215, 128], [167, 189, 64], [105, 163, 30], [44, 131, 40], [14, 96, 46], [23, 61, 33], [23, 35, 18]],
    amp: [[241, 236, 236], [230, 201, 187], [221, 165, 138], [211, 128, 91], [197, 88, 57], [176, 48, 36], [136, 17, 35], [60, 9, 18]],
    tempo: [[255, 246, 244], [213, 224, 206], [159, 203, 165], [100, 181, 137], [46, 155, 124], [15, 121, 111], [23, 86, 93], [21, 29, 68]],
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
  function paint(canvas, frame, rois, showRois, selected = new Set(), hideRejected = false, colormap = "gray", outlines = false, colorBy = "roi", groups = null) {
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
    if (showRois && groups) {   // roimanager's showRoiGroups: the other groups' outlines, each group in a colour of its own
      groups.forEach((group, k) => {
        const [r, g, b] = GROUP_COLORS[k % GROUP_COLORS.length];
        group.rois.forEach((roi) => edge(roi).forEach(([y, x]) => {
          if (y < 0 || y >= frame.height || x < 0 || x >= frame.width) return;
          const i = 4 * (y * frame.width + x);
          image.data[i] += (r - image.data[i]) * 0.8; image.data[i + 1] += (g - image.data[i + 1]) * 0.8; image.data[i + 2] += (b - image.data[i + 2]) * 0.8;
        }));
      });
    }
    if (showRois && rois) {
      rois.forEach((roi, n) => {
        const rejected = roi.classification === "rejected";
        if (rejected && hideRejected) return;
        const [r, g, b] = colorOf(roi, n, colorBy);
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

  // roimanager's roiColorScheme: each ROI its own colour (rejected ones red), or by classification or by cell type in dev's colours
  const CLASSIFICATION_COLORS = { accepted: [44, 178, 125], rejected: [235, 86, 96], unresolved: [45, 95, 232] };
  const CELL_TYPE_COLORS = { excitatory: [255, 0, 0], inhibitory: [0, 255, 0], axon: [245, 166, 7] };
  const GROUP_COLORS = [[0, 220, 255], [255, 150, 0], [220, 80, 255], [255, 255, 80], [80, 255, 160]];
  const ROI_COLOR_SCHEMES = [["roi", "A colour each"], ["classification", "By classification"], ["cellType", "By cell type"], ["none", "One colour"]];
  function colorOf(roi, n, colorBy = "roi") {
    if (colorBy === "classification") return CLASSIFICATION_COLORS[roi.classification] || [204, 204, 204];
    if (colorBy === "cellType") return CELL_TYPE_COLORS[roi.cellType] || [77, 175, 74];
    if (colorBy === "none") return [204, 204, 204];
    return roi.classification === "rejected" ? [200, 60, 60] : roiColor(n);
  }

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
   * A path typed or pasted, as files.resolve takes it: an absolute path in the project folder or a data location's root
   * (the deepest that holds it), or one relative to the folder of current (a file as files.resolve takes it). null for an
   * absolute path in none of them.
   */
  N.fileWhere = function (app, text, current) {
    const path = String(text).trim().replace(/^["']|["']$/g, "").replace(/\\/g, "/");
    if (!path) return null;
    if (!/^(\/|[A-Za-z]:\/)/.test(path)) {
      const folder = current.path.split("/").slice(0, -1).join("/");
      return { ...current, path: folder ? `${folder}/${path}` : path };
    }
    const project = app.project || {};
    const bases = [{ base: project.folder, where: {} }].concat(((project.dataset && project.dataset.roots) || [])
      .map((r) => ({ base: r.path, where: { dataLocation: r.dataLocation, rootStoragePath: r.rootStoragePath } })));
    let best = null;
    for (const b of bases) {
      const base = (b.base || "").replace(/\\/g, "/").replace(/\/+$/, "");
      if (base && (path === base || path.startsWith(base + "/")) && (!best || base.length > best.base.length)) best = { base, where: b.where };
    }
    return best ? { ...best.where, path: path.slice(best.base.length).replace(/^\/+/, "") } : null;
  };

  /**
   * Open the viewer on a variable of an entity. roiVariables are the entity's variables that hold ROIs, and
   * signalVariables its signals, shown for the selected ROI. options.select is an ROI to select once the ROIs are
   * read, and options.mode the image to start on ("mean", ...); options.onClose is called when the viewer closes.
   * options.file is a file of no entity (files.frame); options.viewable ({id, name, roiFile}) something `nansen view` or
   * nansen.view was given, with no project (view.frame), as dev's command-line roimanager: ROIs drawn and edited on it
   * are saved to its ROI file (view.updateRois; kept in memory for an array), and Detect and Find ROIs work on it
   * (view.detect, view.run).
   * With options.mirror (true or false), the viewer offers "All aligned sessions": each ROI edit is also made, through the
   * alignment, to the sessions ophys.align_sessions aligned this one with (rois.update's mirror: dev's synchEntries Mirror).
   */
  N.views.stackViewer = function (app, entityType, key, variable, roiVariables = [], signalVariables = [], options = {}) {
    let initial = options.select ?? null;
    const viewable = options.viewable || null;
    if (viewable) roiVariables = ["ROIs"];   // the stack's own, none at first: drawn, found and saved to its ROI file
    // what the stack is called in file names and titles
    let title = viewable ? viewable.name : options.file ? options.file.path.split("/").pop() : `${variable} · ${N.fmt.key(key)}`;
    let stem = viewable ? viewable.name : options.file ? options.file.path.split("/").pop() : `${N.fmt.key(key)}_${variable}`;
    const state = { frame: 0, frames: 1, mode: "frame", auto: true, low: 0, high: 1, rois: null, roiVariable: roiVariables[0] || "", showRois: roiVariables.length > 0,
      playing: false, busy: false, pending: false, selected: null, selection: new Set(), tool: null, radius: 3, detectMode: 1, hideRejected: false, channel: 0, plane: 0,
      zoom: 1, drag: null, colormap: "gray", polygon: [], undo: [], redo: [], scalebar: false, labels: false, outlines: false, grid: false, links: false, neuropil: false,
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
    // imviewer's playback speed: ` halves it, ~ doubles it
    const speedLabel = h("button.btn.ghost.small.viewer-speed", { title: "Playback speed: ` slower, ~ faster; click for normal speed", style: { display: "none" },
      on: { click: () => setSpeed(1) } }, "");
    function setSpeed(speed) {
      state.speed = Math.min(16, Math.max(1 / 16, speed));
      speedLabel.textContent = `×${state.speed >= 1 ? state.speed : `1/${1 / state.speed}`}`;
      speedLabel.style.display = state.speed === 1 ? "none" : "";
    }
    // imviewer's brightness slider (c) and Show Histogram: the image's values between the limits, and the limits to drag
    const histogram = h("canvas.viewer-histogram", { width: 256, height: 48 });
    const lowSlider = h("input.viewer-brightness-low", { type: "range", min: 0, max: 1000, value: 0, on: { input: () => fromSliders() } });
    const highSlider = h("input.viewer-brightness-high", { type: "range", min: 0, max: 1000, value: 1000, on: { input: () => fromSliders() } });
    const brightness = h("div.viewer-brightness.hidden", histogram,
      h("div.viewer-brightness-sliders", h("label", "Low", lowSlider), h("label", "High", highSlider)));
    const brightnessButton = h("button.btn.ghost.icon.small.viewer-brightness-toggle", { title: "Brightness and histogram (c)",
      on: { click: () => showBrightness(brightness.classList.contains("hidden")) } }, N.icon("sun", 14));
    function showBrightness(on) {
      brightness.classList.toggle("hidden", !on);
      brightnessButton.classList.toggle("active", on);
      if (on) drawHistogram();
    }
    /** The sliders run over the values of the image shown with automatic limits (its smallest to its largest). */
    function fromSliders() {
      const [bottom, top] = state.range || [state.low, state.high];
      const at = (slider) => bottom + (top - bottom) * Number(slider.value) / 1000;
      state.auto = false;
      auto.checked = false;
      state.low = Math.min(at(lowSlider), at(highSlider));
      state.high = Math.max(at(lowSlider), at(highSlider));
      low.value = String(state.low);
      high.value = String(state.high);
      show();
    }
    function drawHistogram() {
      if (!last || brightness.classList.contains("hidden")) return;
      const [bottom, top] = state.range || [last.low, last.high];
      const place = (value) => String(Math.round(top > bottom ? (value - bottom) / (top - bottom) * 1000 : 0));
      lowSlider.value = place(state.low);
      highSlider.value = place(state.high);
      const counts = new Array(64).fill(0);
      const bytes = last.pixels ? atob(last.pixels) : "";
      for (let i = 0; i < bytes.length; i++) counts[bytes.charCodeAt(i) >> 2]++;
      const ctx = histogram.getContext("2d");
      ctx.clearRect(0, 0, histogram.width, histogram.height);
      const most = Math.max(1, ...counts);
      ctx.fillStyle = getComputedStyle(histogram).color || "#888";
      counts.forEach((n, k) => { const tall = Math.round(Math.sqrt(n / most) * histogram.height); ctx.fillRect(k * 4, histogram.height - tall, 3, tall); });
      histogram.dataset.pixels = String(bytes.length);
    }
    const mode = h("select.input.viewer-mode", { on: { change: () => { state.mode = mode.value; show(); } } },
      h("option", { value: "frame" }, "Frames"), h("option", { value: "mean" }, "Average"), h("option", { value: "meanClahe" }, "Mean CLAHE"),
      h("option", { value: "max" }, "Maximum"),
      h("option", { value: "min" }, "Minimum"), h("option", { value: "std" }, "Standard deviation"), h("option", { value: "correlation" }, "Local correlation"),
      h("option", { value: "globalCorrelation" }, "Global correlation"),
      h("option", { value: "peakTime" }, "Time of peak (colour)"));
    // imviewer's binning (Shift+B): the mean or max of the frames around the one shown, as it browses noisy frames
    const binPick = h("select.input.viewer-bin", { title: "Binning: the mean or maximum of the frames around this one (Shift+B)",
      on: { change: () => { state.bin = binPick.value; show(); } } },
      h("option", { value: "" }, "No binning"), [5, 10, 20, 50].map((n) => [h("option", { value: `mean:${n}` }, `Mean of ${n}`), h("option", { value: `max:${n}` }, `Max of ${n}`)]));
    // imviewer's 2-D filters (its Filter Images menu: dev's stack.process.filter2), applied to the frame or projection shown
    const filterPick = h("select.input.viewer-filter", { title: "Filter", on: { change: () => { state.filter = filterPick.value; show(); } } },
      [["", "No filter"], ["smooth", "Smooth"], ["gauss2d", "Gauss 2D (σ 0.5)"], ["gaussian", "Gauss 2D (σ 1)"], ["gradient", "Gradient"],
        ["absGradient", "Absolute gradient"], ["clahe", "CLAHE"]].map(([value, label]) => h("option", { value }, label)));
    const colormapPick = h("select.input.viewer-colormap", { title: "Colormap", on: { change: () => { state.colormap = colormapPick.value; redraw(); } } },
      N.colormaps.map((name) => h("option", { value: name }, name)));
    const low = h("input.input.viewer-low", { type: "number", step: "any", on: { change: () => { state.auto = false; auto.checked = false; state.low = Number(low.value); show(); } } });
    const high = h("input.input.viewer-high", { type: "number", step: "any", on: { change: () => { state.auto = false; auto.checked = false; state.high = Number(high.value); show(); } } });
    const auto = h("input", { type: "checkbox", checked: true, on: { change: () => { state.auto = auto.checked; show(); } } });
    const roiToggle = h("input.viewer-rois", { type: "checkbox", checked: state.showRois, on: { change: () => { state.showRois = roiToggle.checked; show(); } } });
    const roiPick = roiVariables.length > 1 ? h("select.input.viewer-roi-variable", { on: { change: () => { state.roiVariable = roiPick.value; state.rois = null; state.groupRois = null; select(null); show(); } } },
      roiVariables.map((v) => h("option", { value: v }, v))) : null;
    // roimanager's showRoiGroups: other ROI variables shown with the one edited, as outlines in colours of their own
    state.groups = new Set();
    state.groupRois = null;
    const shownGroups = () => (state.groups.size && state.groupRois ? state.groupRois : null);
    const groupsButton = roiVariables.length > 1 && !viewable ? h("button.btn.ghost.small.viewer-roi-groups", { title: "Show other ROI groups too",
      on: { click: () => {
        const others = roiVariables.filter((v) => v !== state.roiVariable);
        N.menu(groupsButton, [{ heading: "Also show" }].concat(others.map((v) => {
          const k = [...state.groups].filter((g) => g !== state.roiVariable).indexOf(v);
          const box = h("input", { type: "checkbox", checked: state.groups.has(v), on: { change: () => {
            if (box.checked) state.groups.add(v); else state.groups.delete(v);
            state.groupRois = null;
            groupsButton.lastChild.textContent = state.groups.size ? ` ${state.groups.size}` : "";
            show();
          } } });
          return { node: h("label.item.viewer-roi-group", { dataset: { variable: v } }, box, " ", v,
            k >= 0 ? h("span.swatch", { style: { background: `rgb(${GROUP_COLORS[k % GROUP_COLORS.length].join(",")})`, marginLeft: "6px" } }) : null) };
        })));
      } } }, N.icon("layers", 13), h("span", "")) : null;
    // roimanager's roiColorScheme: the ROIs' colours, in the image and the list
    const roiColorPick = h("select.input.viewer-roi-colors", { title: "Colour of the ROIs", on: { change: () => { state.colorBy = roiColorPick.value; redraw(); renderList(); } } },
      ROI_COLOR_SCHEMES.map(([value, label]) => h("option", { value }, label)));
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
      for (const shown of [last, pane && pane.last]) {
        if (shown && shown.layers) shown.layers.forEach((layer) => { if (layer.channel === channel) layer.color = rgb; });
      }
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
    // imviewer's Open File and its pasted paths (Ctrl+V): another file, in this viewer
    const openButton = options.file ? h("button.btn.ghost.icon.small.viewer-open-file", { title: "Open another file (or paste its path: Ctrl+V)",
      on: { click: async () => {
        const text = await N.prompt("Open a file", "Its path: in the project folder or a data location, or beside this file", options.file.path.split("/").pop());
        if (text) openPath(text);
      } } }, N.icon("folder", 14)) : null;
    // imviewer's Edit Stack Properties: the recording's frame rate, pixel size and z step, in the entity's columns
    const propertiesButton = entityType && key && !options.file && !viewable ? h("button.btn.ghost.icon.small.viewer-properties",
      { title: "Stack properties: frame rate, pixel size and z step", on: { click: () => editProperties() } }, N.icon("ruler", 14)) : null;
    const zoomLabel = h("button.btn.ghost.small.viewer-zoom.mono", { title: "Fit the image (double-click it)", style: { display: "none" }, on: { click: () => zoomTo(1) } }, "");
    const status = h("div.viewer-status.muted", "Loading…");
    // dev's MultiSessionRoiCollection 'Mirror': edits made in the aligned sessions too (rois.update's mirror)
    state.mirror = Boolean(options.mirror);
    const mirrorToggle = h("input.viewer-mirror", { type: "checkbox", checked: state.mirror, on: { change: () => { state.mirror = mirrorToggle.checked; } } });
    const mirrorLabel = options.mirror === undefined ? null : h("label.viewer-mirror-label", {
      title: "Add, move, reshape, delete and classify ROIs in every session aligned with this one too (through each session's alignment)" },
      mirrorToggle, "All aligned sessions");
    const where = h("span.viewer-where.mono.muted", "");
    let last = null;
    let pane = null;   // the linked stack, while one is shown (see showLinked)

    // --- where the pointer is: image coordinates (fractional) and pixels -------------------------------------------
    const pointAt = (event) => {
      const rect = canvas.getBoundingClientRect();
      if (!state.rotation) return [(event.clientY - rect.top) / rect.height * last.height, (event.clientX - rect.left) / rect.width * last.width];
      // the image turned (imviewer's r): the pointer turned back about the image's middle, on the image's own size
      const width = canvas.offsetWidth, height = canvas.offsetHeight, turn = -state.rotation * Math.PI / 180;
      const dx = event.clientX - (rect.left + rect.width / 2), dy = event.clientY - (rect.top + rect.height / 2);
      const x = dx * Math.cos(turn) - dy * Math.sin(turn), y = dx * Math.sin(turn) + dy * Math.cos(turn);
      return [(y + height / 2) / height * last.height, (x + width / 2) / width * last.width];
    };
    const pixelAt = (event) => pointAt(event).map(Math.floor);
    const visible = () => (state.rois || []).filter((r) => !(state.hideRejected && r.classification === "rejected"));
    const roiAt = (y, x) => roisOn() && state.rois ?visible().find((r) => r.pixels.some(([py, px]) => py === y && px === x)) || null : null;

    // --- size: the image fits the stage, times the zoom ---------------------------------------------------------------
    /** Size a holder for a frame: the frame fitted to its stage (at most 640 px wide), times the zoom. */
    function fit(into, frame, zoom) {
      const room = Math.max(120, into.clientWidth - 24);
      const tall = Math.max(120, window.innerHeight * (signalPanel ? 0.44 : 0.62) - 24);
      const size = Math.min(room, 640, tall * frame.width / frame.height);
      into.firstElementChild.style.width = `${Math.round(size * zoom)}px`;
      into.firstElementChild.style.height = `${Math.round(size * zoom * frame.height / frame.width)}px`;
      into.classList.toggle("zoomed", zoom > 1);
    }
    function layout() {
      if (!last) return;
      fit(stage, last, state.zoom);
      zoomLabel.textContent = `${Math.round(state.zoom * 100)}%`;
      zoomLabel.style.display = state.zoom > 1 ? "" : "none";
      drawOverlay();
      drawScalebar();
      layoutLinked();
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
    // imviewer's mouse: the wheel steps through the frames; with Shift (or a pinch, which comes with Ctrl) it zooms, and a
    // projection or a single image only zooms
    stage.addEventListener("wheel", (event) => {
      if (!last) return;
      event.preventDefault();
      const delta = event.deltaY || event.deltaX;
      if (!delta) return;
      if (event.shiftKey || event.ctrlKey || state.mode !== "frame" || state.frames < 2) zoomTo(state.zoom * (delta < 0 ? 1.25 : 0.8), event.clientX, event.clientY);
      else stepFrames(delta < 0 ? -1 : 1);
    }, { passive: false });
    function stepFrames(by) {
      state.frame = Math.min(state.frames - 1, Math.max(0, state.frame + by));
      slider.value = String(state.frame);
      show();
    }
    /** Turn the image clockwise by degrees (imviewer's r: 90 at a time, back with Shift; 1 at a time with Alt). */
    function rotate(by) {
      state.rotation = ((state.rotation || 0) + by) % 360;
      holder.style.transform = state.rotation ? `rotate(${state.rotation}deg)` : "";
      canvas.dataset.rotation = String(state.rotation);
      drawOverlay();
    }
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
      const around = neuropilShown();
      if (around) {   // roimanager's neuropil mask: the selected ROI's, under everything else drawn here
        ctx.fillStyle = "rgba(255, 150, 40, 0.5)";
        around.pixels.forEach(([y, x]) => ctx.fillRect(x, y, 1, 1));
      }
      canvas.dataset.neuropil = around ? String(around.pixels.length) : "";
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
      } else {   // a pan, of this stack or (drag.stage) the linked one
        const dx = event.clientX - drag.from[0], dy = event.clientY - drag.from[1];
        const panned = drag.stage || stage;
        if (Math.abs(dx) + Math.abs(dy) > 3) drag.moved = true;
        panned.scrollLeft = drag.scroll[0] - dx;
        panned.scrollTop = drag.scroll[1] - dy;
        panned.classList.toggle("panning", drag.moved);
      }
      drawOverlay();
    };
    const onUp = (event) => {
      const drag = state.drag;
      if (!drag) return;
      state.drag = null;
      (drag.stage || stage).classList.remove("panning");
      drawOverlay();
      if (drag.stage) return;   // the linked stack was panned
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
        const where = viewable ? { viewable: viewable.id, ...(state.adapter ? { adapter: state.adapter } : {}) } : { entityType, key, variable };
        // dev's autodetection in the mode picked with keys 1-5, in the tool's circle (the round ROI's radius)
        const found = await app.client.request(viewable ? "view.detect" : "rois.detect", { ...where, ...shownImage(), point: [y, x], radius: state.radius,
          mode: state.detectMode, channel: state.channel, plane: state.plane });
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
    const growButton = h("button.btn.ghost.icon.small.roi-grow", { title: "Grow the selected ROI by a pixel (g)", on: { click: () => reshape(1) } }, N.icon("plus", 13));
    const improveButton = h("button.btn.ghost.icon.small.roi-improve", { title: "Improve the selected ROIs (i): find each again around its middle, as the Detect tool does, keeping its id and class", on: { click: () => improve() } }, N.icon("crosshair", 13));
    const shrinkButton = h("button.btn.ghost.icon.small.roi-shrink", { title: "Shrink the selected ROI by a pixel (h)", on: { click: () => reshape(-1) } }, N.icon("minus", 13));
    const undoButton = h("button.btn.ghost.icon.small.roi-undo", { title: "Undo (Ctrl+Z)", on: { click: () => undo() } }, N.icon("undo", 13));
    const redoButton = h("button.btn.ghost.icon.small.roi-redo", { title: "Redo (Ctrl+Shift+Z)", on: { click: () => redo() } }, N.icon("redo", 13));
    const mergeButton = h("button.btn.ghost.icon.small.roi-merge", { title: "Merge the selected ROIs into one (m); Ctrl-click selects several", on: { click: () => merge() } }, N.icon("merge", 13));
    const galleryButton = h("button.btn.ghost.icon.small.viewer-gallery", { title: "Show the ROIs as a gallery", on: { click: () => gallery() } }, N.icon("grid", 13));
    const tools = [["circle", "circle", "Add a round ROI where you click", ".viewer-add"],
      ["draw", "freehand", "Draw an ROI: drag around the cell", ".viewer-draw"],
      ["polygon", "polygon", "Draw an ROI as a polygon: click its corners, then the first one again or double-click", ".viewer-polygon"],
      ["detect", "crosshair", "Detect the cell around where you click; keys 1-5 pick dev's detection mode", ".viewer-detect"]].map(([name, icon, title, cls]) =>
      h(`button.btn.ghost.icon.small${cls}`, { title, dataset: { tool: name }, on: { click: () => setTool(state.tool === name ? null : name) } }, N.icon(icon, 13)));
    // roimanager's autoDetect modes, picked with keys 1-5 while the Detect tool is on (rois.detect mode)
    const DETECT_MODES = { 1: "the activity-weighted mean of the cell's box, its edge (dev's default)", 2: "the box's peak activity, thresholded",
      3: "the average, thresholded", 4: "the average in a wider box, thresholded", 5: "the average, its edge" };
    const detectModeLabel = h("span.viewer-detect-mode", { hidden: true });
    function setDetectMode(mode) {
      state.detectMode = mode;
      detectModeLabel.textContent = `Mode ${mode}`;
      detectModeLabel.dataset.mode = String(mode);
      detectModeLabel.title = `Detect mode ${mode}: ${DETECT_MODES[mode]}. Keys 1-5 pick another`;
      if (state.tool === "detect") status.textContent = `Detect mode ${mode}: ${DETECT_MODES[mode]}`;
    }
    setDetectMode(state.detectMode);
    function setTool(name) {
      state.tool = name;
      detectModeLabel.hidden = name !== "detect";
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
      // a stack viewed without a project runs the built-in modules' methods (view.methods), in this language only
      try { methods = await (viewable ? app.client.request("view.methods") : app.client.request("methods.list", { entityType })); }
      catch (error) { N.showError(error, "Could not list the methods"); return; }
      const language = app.info && app.info.language;
      const found = methods.filter((m) => /\/Segmentation$/.test(m.category || "") && !m.hidden);
      if (!found.length) { N.toast("No segmentation methods", viewable ? "No built-in module has one in this language" : "The project's modules have none", "error"); return; }
      // a method only the other language has runs in a worker of that language (methods.run starts one)
      const elsewhere = (m) => language && m.languages && !m.languages.includes(language) ? ` (in ${m.languages[0] === "matlab" ? "MATLAB" : "Python"})` : "";
      N.menu(findButton, [{ heading: "Find ROIs with" }].concat(found.map((m) => ({ label: m.title + elsewhere(m), onClick: () => findWith(m) }))));
    }
    function findWith(method) {
      const properties = (method.options && method.options.properties) || {};
      const values = {};
      if ("stack" in properties && !viewable) values.stack = variable;   // a viewable is its method's stack, whatever it is called
      if ("output" in properties && !viewable && (properties.output.default || "").startsWith("Roi") && !(properties.output.default || "").startsWith("RoiSignals")) values.output = state.roiVariable;
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
          if (viewable) { findInViewable(method, values); return; }
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
    /** dev's roimanager autosegmentation on a stack viewed without a project: the method runs on it (view.run), what it
     * finds is written beside the stack and viewable on its own, and is added to the ROIs on screen as asked. */
    async function findInViewable(method, values) {
      N.toast("Finding ROIs", `${method.title}…`);
      try {
        const run = await app.client.request("view.run", { viewable: viewable.id, methodId: method.id, options: values });
        const output = (run.outputs || []).find((o) => o.kind === "rois");
        if (!output) { N.toast("No ROIs found", `${method.title} saved no ROIs`, "error"); return; }
        app.viewables = await app.client.request("view.list");
        app.renderNav();
        const count = (await roisOnScreen()).length;
        const found = run.result && typeof run.result.rois === "number" ? `${run.result.rois} ROIs` : "ROIs";
        const mode = count ? await askImportMode(`${method.title} found ${found}. There are ${count} here: should those found replace them, ` +
          "be appended, or be appended where they do not overlap one of them?") : "append";
        if (!mode) { N.toast("ROIs kept apart", `What ${method.title} found is in ${output.path || "the viewer's list"}`); return; }
        await edit({ import: { viewable: output.viewable, mode } });
        N.toast("ROIs found", `${method.title}, added to these ROIs (Ctrl+Z undoes it)`, "success");
      } catch (error) { N.showError(error, `${method.title} failed`); }
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
    async function addRoisFrom() {
      if (viewable) {   // the ROIs of another stack viewed, such as those a run found
        let listed = [];
        try { listed = await app.client.request("view.list"); } catch (error) { N.showError(error); return; }
        const others = listed.filter((v) => v.kind === "stack" && v.rois && v.id !== viewable.id);
        if (!others.length) { N.toast("No other ROIs", "Nothing else viewed here has ROIs to add", "error"); return; }
        N.menu(addFromButton, [{ heading: "Add ROIs from" }].concat(others.map((v) => ({ label: v.name, onClick: () => addFrom(v.name, { viewable: v.id }) }))));
        return;
      }
      const others = roiVariables.filter((v) => v !== state.roiVariable);
      if (!others.length) { N.toast("No other ROI variables", "The project has no other ROI variable to add ROIs from", "error"); return; }
      N.menu(addFromButton, [{ heading: "Add ROIs from" }].concat(others.map((name) => ({ label: name, onClick: () => addFrom(name, { variable: name }) }))));
    }
    async function addFrom(name, source) {
      const count = (await roisOnScreen()).length;
      const mode = count ? await askImportMode(`${state.roiVariable} has ${count} ROIs here: should those of ${name} replace them, be appended, ` +
        "or be appended where they do not overlap one of them?") : "append";
      if (!mode) return;
      await edit({ import: { ...source, mode } });
    }
    const radius = h("input.input.viewer-radius", { type: "number", min: 1, max: 50, value: state.radius, title: "Radius of a round ROI and of the Detect tool's circle (px)",
      on: { change: () => { state.radius = Math.max(1, Math.round(Number(radius.value) || 1)); } } });
    const hide = h("input", { type: "checkbox", on: { change: () => { state.hideRejected = hide.checked; redraw(); renderList(); } } });
    // roimanager's display options: the ROIs' numbers on the image, and outlines in place of filled ROIs
    const labelToggle = h("input.viewer-roi-labels", { type: "checkbox", on: { change: () => { state.labels = labelToggle.checked; drawOverlay(); } } });
    const linkToggle = h("input.viewer-roi-links", { type: "checkbox", on: { change: () => { state.links = linkToggle.checked; drawOverlay(); } } });
    const outlineToggle = h("input.viewer-roi-outlines", { type: "checkbox", on: { change: () => { state.outlines = outlineToggle.checked; redraw(); } } });
    // dev's ROI table: classifying an ROI with a key went on to the next ROI not classified yet
    const advanceToggle = h("input.viewer-roi-advance", { type: "checkbox", on: { change: () => { state.advance = advanceToggle.checked; } } });
    // roimanager's showNeuropilMask (Shift+N): the selected ROI's neuropil as signal extraction takes it (rois.neuropil),
    // with ophys.extract_signals's preferred preset when the project has the method; read again when the ROIs change
    const neuropilToggle = h("input.viewer-roi-neuropil", { type: "checkbox", on: { change: () => setNeuropil(neuropilToggle.checked) } });
    const neuropilLabel = h("label.viewer-display-option", { title: "The selected ROI's neuropil, as signal extraction takes it (Shift+N)" }, neuropilToggle, "Neuropil");
    let neuropil = null;   // {roi, rois, pixels, options}: the neuropil read for the selected ROI of these ROIs
    let neuropilAsked = null;   // {roi, rois} of the request on its way
    let neuropilMethod;    // the method whose options the neuropil takes: undefined until looked up, null for none
    const neuropilShown = () => (state.neuropil && neuropil && roisOn() && neuropil.roi === state.selected && neuropil.rois === state.rois ? neuropil : null);
    function setNeuropil(on) {
      state.neuropil = on;
      neuropilToggle.checked = on;
      showNeuropil();
    }
    async function showNeuropil() {
      if (!state.neuropil || viewable || state.selected === null || !state.rois || !roisOn() || !last || neuropilShown()) { drawOverlay(); return; }
      const roi = state.selected, rois = state.rois;
      if (neuropilAsked && neuropilAsked.roi === roi && neuropilAsked.rois === rois) return;   // on its way
      neuropilAsked = { roi, rois };
      try {
        if (neuropilMethod === undefined) {
          const methods = await app.client.request("methods.list", { entityType }).catch(() => []);
          neuropilMethod = methods.some((m) => m.id === "ophys.extract_signals") ? "ophys.extract_signals" : null;
        }
        const result = await app.client.request("rois.neuropil", { entityType, key, variable: state.roiVariable, roi, channel: state.channel, plane: state.plane,
          imageSize: [last.height, last.width], ...(neuropilMethod ? { methodId: neuropilMethod } : {}) });
        if (state.selected !== roi || state.rois !== rois) return;   // another ROI, or changed ROIs, meanwhile
        neuropil = { roi, rois, pixels: result.pixels, options: result.options };
        const o = result.options;
        neuropilLabel.title = `ROI ${roi}'s neuropil: ${result.pixels.length} px, ` + (o.neuropilMethod === "expansion"
          ? `${o.neuropilExpansionFactor} × its area, ${o.neuropilSeparation} px from every ROI` : `a ring ${o.neuropilGap + 1}–${o.neuropilGap + o.neuropilWidth} px out`) + " (Shift+N)";
        drawOverlay();
      } catch (error) {
        status.textContent = (error.code ? `[${error.code}] ` : "") + (error.message || String(error));
      } finally {
        if (neuropilAsked && neuropilAsked.roi === roi && neuropilAsked.rois === rois) neuropilAsked = null;
      }
    }
    const roiList = h("ul.viewer-roi-list");
    // where a viewable's ROIs are saved (dev's roimanager saves them beside the file): its ROI file, or memory for an array
    const roiFileNote = viewable ? h("div.muted.viewer-roi-file", { title: viewable.roiFile || "" },
      viewable.roiFile ? `Saved to ${viewable.roiFile.split(/[\\/]/).pop()}` : "Kept while the app is open (an array has no folder)") : null;
    const roiPanel = h("div.viewer-roi-panel",
      h("div.viewer-roi-actions", actions, mergeButton, growButton, shrinkButton, improveButton, h("div.spacer"), undoButton, redoButton, galleryButton),
      h("div.viewer-roi-actions.viewer-roi-tools", tools, detectModeLabel, findButton, addFromButton, h("div.spacer"), radius),
      roiFileNote,
      h("div.viewer-roi-display", h("label.viewer-hide", hide, "Hide rejected"), h("label.viewer-display-option", labelToggle, "Numbers"),
        h("label.viewer-display-option", outlineToggle, "Outlines"), h("label.viewer-display-option", linkToggle, "Links"), viewable ? null : neuropilLabel,
        h("label.viewer-display-option", { title: "After a key classifies the selected ROI, select the next one not classified yet (as dev's ROI table)" }, advanceToggle, "Then the next")),
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
        h("span.swatch", { style: { background: `rgb(${colorOf(roi, state.rois.indexOf(roi), state.colorBy).join(",")})` } }),
        h("span.grow", `ROI ${roi.id}`, roi.cellType ? h("span.muted.roi-cell-type", ` · ${roi.cellType}`) : null,
          roi.links && roi.links.length ? h("span.muted.roi-links", { title: `Linked with ${roi.links.map((i) => "ROI " + i).join(", ")}` }, ` ↔ ${roi.links.join(", ")}`) : null),
        h("span.muted", `${roi.pixels.length} px`),
        roi.classification ? h("span.pill." + ({ accepted: "good", rejected: "bad" }[roi.classification] || "warn"), roi.classification) : null)));
      actions.forEach((b) => { b.disabled = state.selection.size === 0; });
      mergeButton.disabled = state.selection.size < 2;
      growButton.disabled = shrinkButton.disabled = state.selection.size !== 1;
      improveButton.disabled = !state.selection.size;
      undoButton.disabled = !state.undo.length;
      redoButton.disabled = !state.redo.length;
      galleryButton.disabled = !state.rois || !state.rois.length;
      roiPanel.style.display = state.rois && roisOn() ? "" : "none";
    }
    function redraw() {
      if (last) paint(canvas, last, state.rois, roisOn(), state.selection, state.hideRejected, state.colormap, state.outlines, state.colorBy, shownGroups());
      if (pane && pane.last) paint(paneCanvas, pane.last, null, false, new Set(), false, state.colormap, false);
      drawOverlay();
      showNeuropil();
    }
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
      const before = snapshot();
      try {
        // a viewable's ROIs are saved to its ROI file (view.updateRois), an entity's to its ROI variable
        const where = viewable ? { viewable: viewable.id } : { entityType, key, variable: state.roiVariable, ...(state.mirror ? { mirror: true } : {}) };
        const result = await app.client.request(viewable ? "view.updateRois" : "rois.update", { ...where, channel: state.channel, plane: state.plane,
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
        const others = (result.mirrored || []).filter((m) => m.added.length || m.changed.length || m.removed.length).length;
        status.textContent = `${last.height} × ${last.width} · ${state.rois.length} ROIs` + (result.mirrored ? ` · also in ${others} aligned session${others === 1 ? "" : "s"}` : "");
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
    /** dev's improveRois (i): each selected ROI found again around its middle (rois.detect, as the Detect tool, in its mode, with the
     * radius of a circle of its area), the shape replaced and its id, class and links kept; one undo puts them all back. */
    /** What the viewer shows (a frame, binned or not, or a projection, and its filter): the image dev's modes 0 and 3-5
     * detect on, as in imviewer; the time of peak is a colour code, so the stack's mean is taken for it. */
    function shownImage() {
      const filter = state.filter ? { filter: state.filter } : {};
      if (state.mode === "frame") {
        const bin = state.bin ? { bin: { method: state.bin.split(":")[0], size: Number(state.bin.split(":")[1]) } } : {};
        return { frame: state.frame, ...bin, ...filter };
      }
      return state.mode === "peakTime" ? {} : { projection: state.mode, ...filter };
    }
    async function improve() {
      if (!state.selection.size || !last) return;
      const where = viewable ? { viewable: viewable.id, ...(state.adapter ? { adapter: state.adapter } : {}) } : { entityType, key, variable };
      const changed = [];
      status.textContent = "Improving…";
      try {
        for (const id of selectedIds()) {
          const roi = state.rois.find((r) => r.id === id);
          if (!roi || !roi.pixels.length) continue;
          const middle = [0, 1].map((i) => Math.round(roi.pixels.reduce((sum, p) => sum + p[i], 0) / roi.pixels.length));
          const radius = Math.max(1, Math.round(Math.sqrt(roi.pixels.length / Math.PI)));
          const found = await app.client.request(viewable ? "view.detect" : "rois.detect", { ...where, ...shownImage(), point: middle, radius, mode: state.detectMode,
            channel: state.channel, plane: state.plane });
          if (found.pixels.length) changed.push({ id, pixels: found.pixels });
        }
      } catch (error) { N.showError(error, "Could not improve the ROIs"); return; }
      if (changed.length) edit({ pixels: changed });
      else status.textContent = "No cell found in the selected ROIs: draw them instead";
    }
    function classify(label) { if (state.selection.size) edit({ classify: selectedIds().map((id) => ({ id, classification: label })) }); }
    /** classify by a key; with Then the next (dev's ROI table), the next ROI in the list not classified yet is selected after it. */
    function classifyByKey(label) {
      const one = state.selection.size === 1 ? state.selected : null;
      classify(label);
      if (!state.advance || one === null || label === null) return;
      enqueue(() => {
        const order = visible();
        const next = order.slice(order.findIndex((r) => r.id === one) + 1).find((r) => !r.classification);
        if (next) select(next.id);
      });
    }
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
      if (["INPUT", "SELECT", "TEXTAREA"].includes(event.target.tagName) || !document.body.contains(canvas) || onSelect) return;
      const rois = Boolean(state.rois) && state.volume === "single";   // the ROIs are of one plane
      if (event.ctrlKey || event.metaKey) {
        if (!rois) return;
        if (event.key.toLowerCase() === "z") { if (event.shiftKey) redo(); else undo(); }
        else if (event.key.toLowerCase() === "y") redo();
        else return;
        event.preventDefault();
        return;
      }
      if (event.key === "Escape" && state.tool === "polygon" && state.polygon.length) { state.polygon = []; drawOverlay(); event.stopPropagation(); return; }
      if (event.key === "Escape" && state.tool) { setTool(null); event.stopPropagation(); return; }
      if ((rois && roiKey(event)) || viewerKey(event)) event.preventDefault();
    }
    /** roimanager's keys (its RoiDisplayInputHandler, with the selected ROIs; and the rebuild's): true when one was used. */
    function roiKey(event) {
      const key = event.key, some = state.selection.size > 0;
      const order = visible().map((r) => r.id);
      const at = order.indexOf(state.selected);
      const arrows = { ArrowUp: [-1, 0], ArrowDown: [1, 0], ArrowLeft: [0, -1], ArrowRight: [0, 1] };
      if (state.tool === "detect" && /^[1-5]$/.test(key) && !event.altKey) setDetectMode(Number(key));
      else if (some && !event.altKey && /^Digit[0-3]$/.test(event.code) && !event.shiftKey)   // dev's classes: 1 accepted, 2 rejected, 3 unresolved; 0 none
        classifyByKey([null, "accepted", "rejected", "unresolved"][Number(event.code.slice(5))]);
      else if (some && !event.altKey && arrows[key]) {   // move the selected ROIs a pixel (5 with Shift)
        const [rows, columns] = arrows[key].map((v) => v * (event.shiftKey ? 5 : 1));
        edit({ move: selectedIds().map((id) => ({ id, rows, columns })) });
      }
      else if (event.altKey) return false;
      else if (some && (key === "g" || key === "h")) reshape(key === "g" ? 1 : -1);
      else if (some && key === "a") classifyByKey("accepted");
      else if (some && key === "r") classifyByKey("rejected");
      else if (some && key === "q") classifyByKey("unresolved");
      else if (some && key === "u") classifyByKey(null);
      else if (state.selection.size > 1 && key === "m") merge();
      else if (some && key === "i") improve();
      else if (some && key === "E") setCellType("excitatory");
      else if (some && key === "I") setCellType("inhibitory");
      else if (some && key === "X") setCellType("axon");
      else if (some && key === "C") linkRois();
      else if (key === "O" && !viewable) setNeuropil(!state.neuropil);
      else if (some && (key === "Delete" || key === "Backspace")) remove();
      else if (key === "j" || (!some && key === "ArrowDown" && order.length)) select(order[Math.min(order.length - 1, at + 1)] ?? null);
      else if (key === "k" || (!some && key === "ArrowUp" && order.length)) select(order[Math.max(0, at - 1)] ?? null);
      else return false;
      return true;
    }
    /** imviewer's keys (its App's onKeyPressed): true when one was used. */
    function viewerKey(event) {
      const key = event.key;
      const setMode = (value) => { mode.value = value; state.mode = value; show(); };
      const toggleBin = (method) => {   // dev's moving average (Shift+N) or maximum (Shift+M), on and off
        if (state.mode !== "frame") return;
        state.bin = state.bin && state.bin.startsWith(method) ? "" : `${method}:${(state.binLast || "mean:10").split(":")[1]}`;
        if (state.bin) state.binLast = state.bin;
        binPick.value = state.bin;
        show();
      };
      if (event.altKey && key.startsWith("Arrow")) {   // pan
        const [down, right] = { ArrowUp: [-1, 0], ArrowDown: [1, 0], ArrowLeft: [0, -1], ArrowRight: [0, 1] }[key];
        stage.scrollTop += down * stage.clientHeight / 10;
        stage.scrollLeft += right * stage.clientWidth / 10;
      } else if (/^Digit[0-4]$/.test(event.code)) {
        const k = Number(event.code.slice(5));
        if (event.shiftKey) {   // a quadrant (1-4), or all of it (0)
          if (!k) { zoomTo(1); return true; }
          zoomTo(2);
          stage.scrollLeft = k === 2 || k === 4 ? stage.scrollWidth : 0;
          stage.scrollTop = k > 2 ? stage.scrollHeight : 0;
        } else if (state.channels < 2) return false;
        else if (!k) { state.composite = true; state.shown = state.shown.map(() => true); N.fill(channelStrip); showChannels(); show(); }
        else if (k > state.channels) return false;
        else if (event.altKey && composite()) { state.shown[k - 1] = !state.shown[k - 1]; N.fill(channelStrip); showChannels(); show(); }
        else { state.composite = false; showChannels(); toPlace(() => pickChannel(k - 1)); channelPick.value = String(k - 1); }
      }
      else if (event.altKey && (key === "r" || key === "R" || key === "®")) rotate(event.shiftKey ? -1 : 1);
      else if (event.altKey) return false;
      else if ((key === "ArrowLeft" || key === "ArrowRight") && state.mode === "frame" && state.frames > 1) stepFrames((key === "ArrowLeft" ? -1 : 1) * (event.shiftKey ? 5 : 1));
      else if (key === "z" || key === "+" || key === "=") zoomTo(state.zoom * 1.25);
      else if (key === "Z" || key === "-") zoomTo(state.zoom * 0.8);
      else if (key === "p") toggle();
      else if (key === "n") setMode("mean");
      else if (key === "m") setMode("max");
      else if (key === "b") setMode("meanClahe");
      else if (key === "N") toggleBin("mean");
      else if (key === "M") toggleBin("max");
      else if (key === "B" && state.mode === "frame") {   // binning off, or on again as it was last
        if (state.bin) state.binLast = state.bin;
        state.bin = state.bin ? "" : state.binLast || "mean:10";
        binPick.value = state.bin;
        show();
      }
      else if (key === "c") showBrightness(brightness.classList.contains("hidden"));
      else if (key === "r" || key === "R") rotate(key === "r" ? 90 : -90);
      else if (key === "`" || key === "~") setSpeed((state.speed || 1) * (key === "~" ? 2 : 0.5));
      else return false;
      return true;
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
          paint(frameCanvas, frame, state.rois, roisOn(), state.selection, state.hideRejected, state.colormap, state.outlines, state.colorBy, shownGroups());
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

    // --- a linked stack, side by side: imviewer's Link to Another Viewer --------------------------------------------
    // Another image variable of this entity (raw beside motion-corrected, say) or of another entity of its type, shown
    // beside this one through fetchView, as this one is shown (mode, filter, binning, channel and plane) but on its own
    // contrast. While Linked is on, the two keep the same frame, zoom and pan, either way (dev's linkprop of the
    // frame number and of the axes' limits); off, the linked stack is browsed, zoomed and panned on its own.
    const paneCanvas = h("canvas.viewer-linked-canvas");
    const paneStage = h("div.viewer-linked-stage", h("div.viewer-holder", paneCanvas));
    const paneTitle = h("span.viewer-linked-title.mono", "");
    const paneFrame = h("span.viewer-linked-frame.mono.muted", "");
    const paneSlider = h("input.viewer-linked-slider", { type: "range", min: 0, max: 0, value: 0, on: { input: () => goLinked(Number(paneSlider.value)) } });
    const paneToggle = h("input.viewer-linked-toggle", { type: "checkbox", checked: true, on: { change: () => setLinked(paneToggle.checked) } });
    const linkedPanel = h("div.viewer-linked", { style: { display: "none" } }, paneStage,
      h("div.viewer-linked-bar", paneSlider, paneFrame),
      h("div.viewer-linked-bar", paneTitle, h("div.spacer"),
        h("label.viewer-linked-label", { title: "Keep the frame, zoom and pan in step with the stack on the left" }, paneToggle, "Linked"),
        h("button.btn.ghost.icon.small.viewer-linked-close", { title: "Close the linked stack", on: { click: () => closeLinked() } }, N.icon("x", 13))));
    const linkButton = options.file || viewable ? null : h("button.btn.ghost.icon.small.viewer-link", {
      title: "Link to another stack: shown beside this one, with the frame, zoom and pan in step", on: { click: () => linkMenu() } }, N.icon("link", 14));
    async function linkMenu() {
      let data = [];
      try { data = await app.client.request("data.status", { entityType, key }); } catch (error) { N.showError(error, "Could not list the data variables"); return; }
      const others = data.filter((d) => N.isImageVariable(d) && d.name !== variable);
      N.menu(linkButton, [{ heading: "Show beside this one" }].concat(others.map((d) => ({ label: d.name, onClick: () => openLinked(key, d.name) })),
        [{ label: `A stack of another ${entityType}…`, onClick: () => pickLinked() }],
        pane ? [{ label: "Close the linked stack", icon: "x", onClick: () => closeLinked() }] : []));
    }
    /** Pick an entity of this type, then one of its image variables. */
    async function pickLinked() {
      let rows = [];
      try { rows = (await app.client.request("entities.list", { entityType })).rows.filter((r) => r.inStore); } catch (error) { N.showError(error, "Could not list them"); return; }
      const self = N.fmt.key(key);
      const first = Math.max(0, rows.findIndex((r) => N.fmt.key(r.key) !== self));
      const entityPick = h("select.input.viewer-linked-entity", { on: { change: () => fillVariables() } },
        rows.map((r, i) => h("option", { value: i, selected: i === first }, N.fmt.key(r.key))));
      const variablePick = h("select.input.viewer-linked-variable");
      async function fillVariables() {
        const row = rows[Number(entityPick.value)];
        N.fill(variablePick);
        if (!row) return;
        try {
          const data = await app.client.request("data.status", { entityType, key: row.key });
          if (rows[Number(entityPick.value)] !== row) return;   // another one picked meanwhile
          N.fill(variablePick, data.filter(N.isImageVariable).map((d) => h("option", { value: d.name, selected: d.name === variable }, d.name)));
        } catch (error) { N.showError(error, "Could not list its data variables"); }
      }
      N.dialog({
        title: "Link to another stack", narrow: true,
        content: h("div.viewer-linked-form", { style: { padding: "12px 20px" } },
          h("div.field", h("label.name", entityType), entityPick), h("div.field", h("label.name", "Stack"), variablePick)),
        buttons: [{ label: "Cancel" }, { label: "Show", kind: "primary", icon: "link", onClick: (close) => {
          const row = rows[Number(entityPick.value)];
          if (!row || !variablePick.value) { N.toast("Pick a stack", `The ${entityType} has no stack to show`, "error"); return; }
          close();
          openLinked(row.key, variablePick.value);
        } }],
      });
      fillVariables();
    }
    function openLinked(other, name) {
      pane = { entityType, key: other, variable: name, linked: true, frame: state.frame, frames: null, channels: 1, planes: 1, zoom: state.zoom,
        last: null, busy: false, pending: false };
      paneToggle.checked = true;
      paneTitle.textContent = N.fmt.key(other) === N.fmt.key(key) ? name : `${name} · ${N.fmt.key(other)}`;
      paneFrame.textContent = "Loading…";
      linkedPanel.style.display = "";
      linkButton.classList.add("active");
      layout();   // this stack has half the room now
      showLinked();
    }
    function closeLinked() {
      pane = null;
      linkedPanel.style.display = "none";
      linkButton.classList.remove("active");
      layout();
    }
    function setLinked(on) {
      if (!pane) return;
      pane.linked = on;
      if (!on) return;
      pane.zoom = state.zoom;   // in step again: this stack's frame, zoom and pan
      layoutLinked();
      follow(stage, paneStage);
      showLinked();
    }
    /** The linked stack's slider: both stacks' frame while linked, else its own. */
    function goLinked(frame) {
      if (!pane) return;
      pane.frame = frame;
      if (!pane.linked) { showLinked(); return; }
      state.frame = Math.min(frame, state.frames - 1);
      slider.value = String(state.frame);
      show();
    }
    /** Show the linked stack's frame (this stack's while linked) or projection. */
    async function showLinked() {
      const own = pane;
      if (!own) return;
      if (own.busy) { own.pending = true; return; }
      own.busy = true;
      try {
        if (own.linked) own.frame = state.frame;
        if (own.frames !== null) own.frame = Math.min(own.frame, own.frames - 1);
        const binning = state.mode === "frame" && state.bin ? { bin: { method: state.bin.split(":")[0], size: Number(state.bin.split(":")[1]) } } : {};
        // its first frame first, to count its frames, channels and planes
        const at = own.frames === null ? { frame: 0 } : state.mode === "frame" ? { frame: own.frame, ...binning } : { projection: state.mode };
        const frame = await fetchView(at, false, own);
        if (pane !== own) return;   // closed, or another one linked, meanwhile
        const counted = { frames: frame.frames, channels: frame.channels || 1, planes: frame.planes || 1 };
        if (own.frames === null || counted.channels !== own.channels || counted.planes !== own.planes) own.pending = true;   // again, now they are known
        const resized = !own.last || own.last.width !== frame.width || own.last.height !== frame.height;
        Object.assign(own, counted, { last: frame });
        paint(paneCanvas, frame, null, false, new Set(), false, state.colormap, false);
        paneSlider.max = String(Math.max(0, frame.frames - 1));
        paneSlider.value = String(own.frame);
        paneSlider.disabled = state.mode !== "frame" || frame.frames < 2;
        paneFrame.textContent = state.mode === "frame" ? `${own.frame + 1} / ${frame.frames}` : `${frame.frames} frames`;
        if (resized) layoutLinked();
      } catch (error) {
        paneFrame.textContent = (error.code ? `[${error.code}] ` : "") + (error.message || String(error));
      } finally {
        own.busy = false;
        if (own.pending && pane === own) { own.pending = false; showLinked(); }
      }
    }
    /** The linked stack's size: fitted to its stage as this one is, times this one's zoom while linked, else its own. */
    function layoutLinked() {
      if (!pane || !pane.last) return;
      if (pane.linked) pane.zoom = state.zoom;
      fit(paneStage, pane.last, pane.zoom);
      follow(stage, paneStage);
    }
    // the pan, in step: the same share of the room to scroll, either way while linked
    const echoes = new Map();   // stage -> the scroll follow gave it, whose scroll event is not followed back
    function follow(from, to) {
      if (!pane || !pane.linked) return;
      const share = (size, room, at) => (size > room ? at / (size - room) : 0);
      const left = share(from.scrollWidth, from.clientWidth, from.scrollLeft) * Math.max(0, to.scrollWidth - to.clientWidth);
      const top = share(from.scrollHeight, from.clientHeight, from.scrollTop) * Math.max(0, to.scrollHeight - to.clientHeight);
      if (Math.abs(to.scrollLeft - left) < 1 && Math.abs(to.scrollTop - top) < 1) return;
      to.scrollLeft = left;
      to.scrollTop = top;
      echoes.set(to, [to.scrollLeft, to.scrollTop]);
    }
    function scrolled(from, to) {
      const echo = echoes.get(from);
      echoes.delete(from);
      if (echo && Math.abs(from.scrollLeft - echo[0]) < 1 && Math.abs(from.scrollTop - echo[1]) < 1) return;   // follow's own
      follow(from, to);
    }
    stage.addEventListener("scroll", () => scrolled(stage, paneStage));
    paneStage.addEventListener("scroll", () => scrolled(paneStage, stage));
    /** The place on this stack's canvas of the same point of the image as (clientX, clientY) on the linked one. */
    function across(clientX, clientY) {
      const from = paneCanvas.getBoundingClientRect(), to = canvas.getBoundingClientRect();
      return [to.left + (clientX - from.left) / from.width * to.width, to.top + (clientY - from.top) / from.height * to.height];
    }
    /** Zoom the linked stack: both while linked (as zoomTo), else it alone, keeping the point under (clientX, clientY). */
    function zoomLinked(zoom, clientX, clientY) {
      if (pane.linked) { zoomTo(zoom, ...across(clientX, clientY)); return; }
      zoom = Math.min(16, Math.max(1, zoom));
      if (zoom === pane.zoom) return;
      const before = paneCanvas.getBoundingClientRect();
      const fx = (clientX - before.left) / before.width, fy = (clientY - before.top) / before.height;
      pane.zoom = zoom;
      fit(paneStage, pane.last, zoom);
      const after = paneCanvas.getBoundingClientRect();
      paneStage.scrollLeft += after.left + fx * after.width - clientX;
      paneStage.scrollTop += after.top + fy * after.height - clientY;
    }
    paneStage.addEventListener("wheel", (event) => {
      if (!pane || !pane.last) return;
      event.preventDefault();
      zoomLinked((pane.linked ? state.zoom : pane.zoom) * ((event.deltaY || event.deltaX) < 0 ? 1.25 : 0.8), event.clientX, event.clientY);
    }, { passive: false });
    paneCanvas.addEventListener("dblclick", (event) => {
      if (pane && pane.last) zoomLinked((pane.linked ? state.zoom : pane.zoom) > 1 ? 1 : 4, event.clientX, event.clientY);
    });
    paneCanvas.addEventListener("mousedown", (event) => {
      if (!pane || event.button !== 0) return;
      state.drag = { kind: "pan", stage: paneStage, from: [event.clientX, event.clientY], scroll: [paneStage.scrollLeft, paneStage.scrollTop], moved: false };
      event.preventDefault();
    });
    paneCanvas.addEventListener("mousemove", (event) => {
      if (!pane || !pane.last) return;
      const rect = paneCanvas.getBoundingClientRect();
      where.textContent = `row ${Math.floor((event.clientY - rect.top) / rect.height * pane.last.height)}, column ${Math.floor((event.clientX - rect.left) / rect.width * pane.last.width)}`;
    });
    paneCanvas.addEventListener("mouseleave", () => { where.textContent = ""; });
    resizing.observe(paneStage);

    // --- another file (imviewer's Open File) and the stack's properties (Edit Stack Properties) --------------------------
    /** Open a file by its path, typed or pasted: absolute, in the project folder or a data location's root, or relative to
     * the folder of the file shown. */
    function openPath(text) {
      const where = N.fileWhere(app, text, options.file);
      if (!where) { N.showError(new Error(`${text.trim()} is not in the project folder or a data location`), "Could not open the file"); return; }
      openFile(where);
    }
    async function openFile(where) {
      try {
        const resolved = await app.client.request("files.resolve", where);
        if (!resolved.exists || resolved.isFolder) {
          throw Object.assign(new Error(`${resolved.path} is ${resolved.exists ? "a folder" : "not there"}`), { code: resolved.exists ? "invalid-params" : "file-not-found" });
        }
      } catch (error) { N.showError(error, "Could not open the file"); return; }
      options.file = where;
      title = stem = where.path.split("/").pop();
      dialog.el.querySelector(".dialog-head h2").textContent = title;
      Object.assign(state, { frame: 0, adapter: null, rois: null, selected: null, selection: new Set(), channel: 0, plane: 0 });
      slider.value = "0";
      N.clear(adapterPick);
      adapterPick.style.display = "none";
      show();
    }
    function onPaste(event) {
      const target = event.target;
      if (!options.file || (target && (target.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName)))) return;
      const line = ((event.clipboardData && event.clipboardData.getData("text")) || "").split(/\r?\n/).find((l) => l.trim());
      if (!line) return;   // dev opened every path pasted; here the first
      event.preventDefault();
      openPath(line);
    }
    if (options.file) document.addEventListener("paste", onPaste);

    /** The entity's frame rate, pixel size and z step, in its columns (frame_rate, pixel_size_um, z_step_um), which the
     * stack's metadata takes over what its files give, as dev's Edit Stack Properties set the stack's metadata. */
    async function editProperties() {
      let detail;
      try { detail = await app.client.request("entities.get", { entityType, key }); } catch (error) { N.showError(error); return; }
      const fields = [["frame_rate", "frameRate", "Frame rate", "frames per second"], ["pixel_size_um", "pixelSize", "Pixel size", "µm per pixel"],
        ["z_step_um", "zStep", "Z step", "µm between planes"]].filter(([column]) => column in (detail.values || {}));
      if (!fields.length) {
        N.toast("No columns for them", `The ${entityType} table has no frame_rate, pixel_size_um or z_step_um column: attach the ophys module's Imaging and Scan fragments`, "error");
        return;
      }
      const metadata = (last && last.metadata) || {};
      const inputs = {};
      const rows = fields.map(([column, meta, label, unit]) => {
        const value = detail.values[column];
        inputs[column] = h("input.input", { type: "number", step: "any", min: "0", value: value === null || value === undefined ? "" : String(value), dataset: { column } });
        const given = Array.isArray(metadata[meta]) ? metadata[meta][0] : metadata[meta];
        const note = given !== undefined && Number(given) !== Number(value) ? `The files say ${given}; a value here is used instead` : unit;
        return h("label.field", h("span", label), inputs[column], h("span.muted", { style: { fontSize: "12px" } }, note));
      });
      N.dialog({
        title: "Stack properties", narrow: true,
        content: h("div.viewer-properties-form", { style: { padding: "12px 16px", display: "grid", gap: "10px" } },
          h("p.muted", { style: { margin: 0 } }, `Kept in the ${entityType}'s columns, which the stack's metadata takes over what its files give (empty: the files' value).`), rows),
        buttons: [{ label: "Cancel" }, { label: "Save", kind: "primary", onClick: async (close) => {
          const values = {};
          for (const [column] of fields) {
            const text = inputs[column].value.trim();
            if (text !== "" && !(Number(text) > 0)) { N.toast("Check the values", `${column} is a positive number, or empty`, "error"); return; }
            values[column] = text === "" ? null : Number(text);
          }
          try {
            await app.client.request("entities.update", { entityType, key, values });
          } catch (error) { N.showError(error, "Could not save them"); return; }
          close();
          N.toast("Stack properties saved", fields.map(([column]) => `${column} ${values[column] ?? "—"}`).join(", "), "success");
          show();
        } }],
      });
    }

    // --- the frame --------------------------------------------------------------------------------------------------
    /**
     * The frame or projection at ({frame} or {projection}) as it is shown. One channel and plane is data.frame's (or
     * files.frame's) answer; channels in colour and planes side by side or projected are composed here from one answer
     * per channel and plane (imviewer's setChColors and plane montage and projection): each channel scaled by its own
     * limits, and every plane of a channel brought to one scale, from the lowest low to the highest high of them. The
     * composed view has the answer's fields, its size, layers ({channel, bytes, color}) and, for the montage, tiles.
     * With linked (the linked stack: {entityType, key, variable, channels, planes}), that stack's, by data.frame, as this
     * one is shown, on its own contrast: at the channel and plane at hand when it has them, its channels in colour when
     * it has as many as this one.
     */
    async function fetchView(at, withRois, linked = null) {
      // a file of no entity (options.file: as files.resolve takes it) is read by files.frame, as dev's imviewer opens any
      // file; what `nansen view` was given, by view.frame, with no project
      const base = linked ? { entityType: linked.entityType, key: linked.key, variable: linked.variable, ...at }
        : viewable ? { viewable: viewable.id, ...at } : options.file ? { ...options.file, ...at } : { entityType, key, variable, ...at };
      if (!linked && (options.file || viewable) && state.adapter) base.adapter = state.adapter;
      if (state.filter) base.filter = state.filter;
      const method = linked ? "data.frame" : viewable ? "view.frame" : options.file ? "files.frame" : "data.frame";
      const limitsOf = (c) => {
        if (linked) return null;
        if (c === state.channel) return state.auto ? null : [state.low, state.high];
        const own = state.channelLimits[c];
        return own && !own.auto ? [own.low, own.high] : null;
      };
      const ask = (c, p, more = {}) => app.client.request(method, { ...base, channel: c, plane: p, ...(limitsOf(c) ? { limits: limitsOf(c) } : {}), ...more });
      const groups = [...state.groups].filter((g) => g !== state.roiVariable);
      const rois = !linked && withRois && state.showRois && state.roiVariable && !state.rois ? { rois: viewable ? true : state.roiVariable } : {};
      if (!linked && withRois && state.showRois && groups.length && (!state.rois || !state.groupRois)) rois.alsoRois = groups;
      const [channel, plane] = linked ? [Math.min(state.channel, linked.channels - 1), Math.min(state.plane, linked.planes - 1)] : [state.channel, state.plane];
      const planeCount = linked ? linked.planes : state.planes;
      const colour = composite() && (!linked || linked.channels === state.channels) && at.projection !== "peakTime";   // the time of peak has its own colours
      const planes = state.volume !== "single" && planeCount > 1 && at.projection !== "peakTime" ? range(planeCount) : null;
      if (!colour && !planes) return ask(channel, plane, rois);
      // the channel at hand is read even when hidden: its ROIs and limits
      const channels = colour ? range(state.channels).filter((c) => state.shown[c] || c === channel) : [channel];
      const answers = await Promise.all(channels.map((c) => Promise.all((planes || [plane]).map((p) =>
        ask(c, p, !planes && c === channel ? rois : {})))));
      const first = answers[0][0], own = answers[channels.indexOf(channel)];
      const view = { ...first, pixels: planes ? undefined : own[0].pixels, rois: planes ? undefined : own[0].rois, roiGroups: planes ? undefined : own[0].roiGroups,
        brightness: undefined, layers: [] };
      const size = first.width * first.height;
      const layout = planes && state.volume === "montage" ? N.montageLayout(planes.length, first.height, first.width) : null;
      if (layout) Object.assign(view, { height: layout.height, width: layout.width, tiles: layout.tiles });
      if (planes) view.volume = state.volume;   // how its planes were put together, as asked (the status says so)
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
        if (c === channel) Object.assign(view, { low, high });
        else if (!linked && !(state.channelLimits[c] && !state.channelLimits[c].auto)) state.channelLimits[c] = { auto: true, low, high };
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
        if (frame.roiGroups) state.groupRois = frame.roiGroups;
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
        if (state.auto) { state.low = frame.low; state.high = frame.high; low.value = String(frame.low); high.value = String(frame.high); state.range = [frame.low, frame.high]; }
        frameLabel.textContent = state.mode === "frame" ? `${state.frame + 1} / ${frame.frames}` + (frame.binned ? ` (${frame.binned[0] + 1}–${frame.binned[1]})` : "")
          : `${frame.frames} frames`;
        binPick.disabled = state.mode !== "frame";
        showTime();
        paint(canvas, frame, state.rois, roisOn(), state.selection, state.hideRejected, state.colormap, state.outlines, state.colorBy, shownGroups());
        if (resized) layout(); else { drawOverlay(); drawScalebar(); }
        showNeuropil();
        showLinked();
        drawHistogram();
        renderList();
        if (tracePlot) tracePlot.cursor(state.mode === "frame" ? state.frame : null);
        const planes = frame.volume   // as the image shown was asked for, not as the picker says now (a later one is on its way then)
          ? ({ montage: " · %d planes side by side", max: " · maximum of %d planes", mean: " · mean of %d planes" })[frame.volume].replace("%d", state.planes) : "";
        const [height, width] = frame.tiles ? [frame.tiles[0].height, frame.tiles[0].width] : [frame.height, frame.width];
        status.textContent = `${height} × ${width}` + planes + (state.rois && roisOn() ? ` · ${state.rois.length} ROIs` : "");
      } catch (error) {
        state.playing = false;
        status.textContent = (error.code ? `[${error.code}] ` : "") + (error.message || String(error));
      } finally {
        state.busy = false;
        if (state.pending) { state.pending = false; show(); }
        else if (state.playing) setTimeout(step, 80 / (state.speed || 1));
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
        playButton, speedLabel, slider, frameLabel, timeLabel, mode, channelPick, compositeLabel, channelStrip, planePick, volumePick, adapterPick,
        h("label.viewer-contrast", auto, "Auto"), low, h("span.muted", "–"), high, brightnessButton,
        binPick, filterPick, colormapPick, roiVariables.length ? h("label.viewer-roi-toggle", roiToggle, "ROIs") : null, roiPick, groupsButton, roiVariables.length ? roiColorPick : null, mirrorLabel, measurement, measureButton, scaleButton,
        linkButton, propertiesButton, openButton, exportButton),
      brightness,
      h("div.viewer-main", stage, linkedPanel, roiVariables.length ? roiPanel : null),
      signalPanel,
      h("div.viewer-foot", status, h("div.spacer"), where, zoomLabel, gridButton));
    const dialog = N.dialog({ title, content, onClose: () => {
      if (options.onClose) options.onClose();
      state.playing = false;
      pane = null;
      resizing.disconnect();
      document.removeEventListener("keydown", onKey, true);
      document.removeEventListener("paste", onPaste);
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
    } });
    dialog.el.classList.add("viewer-dialog");
    if (options.mode) { state.mode = options.mode; mode.value = options.mode; }
    show();
    return dialog;
  };
})();
