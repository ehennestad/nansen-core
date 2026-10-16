/* The ophys module's FOV map: cranial windows and fields of view on the mouse dorsal cortex, as dev's fovmanager.
 *
 * Run by the dashboard with N (its toolkit) and module (this module's id). Positions are columns of the
 * ophys.cranial_window and ophys.fov_position fragments, so they are edited, filtered and exported like any other
 * column; this page draws them on the atlas and places them with a click. Injection sites (any number per subject)
 * and notes on the map are the module's data (modules.data, modules.saveData), in the project's module-data folder:
 * an injection has what was injected, its depth (µm), volume (nL), spread (µm, drawn as a circle) and a colour. Marks
 * are edited by clicking them (on the map or in the list) and moved by dragging them; the map can be saved as PNG.
 * fovmanager's Copy and Paste (Ctrl+C, Ctrl+V): the FOV, window or mark picked last is copied, and pasted as the selected
 * session's FOV, the selected subject's window, or a new mark of the selected subject at the same place; its Show Fine
 * Grid draws a line every 0.2 mm, stronger at whole millimetres.
 *
 * The module's data (fovmap) is {injections, notes, photos, outlines, headbars}, each a list of marks with an id:
 * - injections: {id, subject?, ml, ap, material?, depth? (µm), volume? (nL), spread? (µm), colour?};
 * - notes: {id, subject?, ml, ap, text};
 * - photos: {id, subject?, path, dataLocation?, width (mm), opacity, height? (mm; else as the image's sides),
 *   offset? ([ml, ap] mm of its centre from the window's)}: a photo of the subject's window, centred on it, turned with
 *   it and cut to its outline; or, with session (a key), an image of that session's FOV, shown in its FOV;
 * - outlines: {id, subject, ellipse: [rx, ry]} or {id, subject, polygon: [[x, y], ...]} (mm from the window's centre,
 *   before its rotation): a window's outline that is none of the fixed shapes, as fovmanager kept them;
 * - headbars: {id, subject, label}: a subject's headbar label, as fovmanager's.
 * Import dev FOV inventory (legacy.importFovInventory) brings an inventory of dev's fovmanager (.mat) onto the map.
 */
"use strict";
const { h } = N;
let atlasCache = null;

const SHAPES = {   // half sizes in mm: [half width (ML), half height (AP)], round or not, a trapezoid's half width in front
  "round 2.5 mm": [1.25, 1.25, true], "round 3 mm": [1.5, 1.5, true], "round 4 mm": [2, 2, true],
  "round 5 mm": [2.5, 2.5, true], "trapezoid 3 x 5 mm": [2.5, 2.5, false, 1.5],   // dev's: 3 mm wide in front, 5 behind, 5 long
};
const MARK_KINDS = ["injections", "notes", "photos", "outlines", "headbars"];

async function loadAtlas(app) {
  if (!atlasCache) {
    const resource = await app.client.request("modules.resource", { module, path: "atlas/dorsal_cortex.json" });
    const atlas = JSON.parse(resource.text);
    atlas.index = new Uint8Array(atlas.width * atlas.height);
    atlas.rows.forEach((runs, row) => {
      let column = 0;
      for (let k = 0; k < runs.length; k += 2) {
        atlas.index.fill(runs[k], row * atlas.width + column, row * atlas.width + column + runs[k + 1]);
        column += runs[k + 1];
      }
    });
    atlas.byIndex = {};
    atlas.regions.forEach((r) => { atlas.byIndex[r.index] = r; });
    atlasCache = atlas;
  }
  return atlasCache;
}

/** The atlas drawn once at its own size: region colors, darker where regions meet; anterior up. */
function atlasImage(atlas) {
  if (atlas.image) return atlas.image;
  const canvas = document.createElement("canvas");
  canvas.width = atlas.width;
  canvas.height = atlas.height;
  const ctx = canvas.getContext("2d");
  const image = ctx.createImageData(atlas.width, atlas.height);
  const rgb = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
  for (let row = 0; row < atlas.height; row++) {
    for (let column = 0; column < atlas.width; column++) {
      const value = atlas.index[row * atlas.width + column];
      const i = 4 * ((atlas.height - 1 - row) * atlas.width + column);
      if (!value) { image.data[i + 3] = 0; continue; }
      const edge = column + 1 < atlas.width && atlas.index[row * atlas.width + column + 1] !== value ||
        row + 1 < atlas.height && atlas.index[(row + 1) * atlas.width + column] !== value;
      const [r, g, b] = rgb(atlas.byIndex[value] ? atlas.byIndex[value].color : "#cccccc");
      const f = edge ? 0.55 : 1;
      image.data[i] = r * f; image.data[i + 1] = g * f; image.data[i + 2] = b * f; image.data[i + 3] = 255;
    }
  }
  ctx.putImageData(image, 0, 0);
  atlas.image = canvas;
  return canvas;
}

function regionAt(atlas, ml, ap) {
  const column = Math.floor((ml - atlas.origin[0]) * atlas.pixelsPerMm);
  const row = Math.floor((ap - atlas.origin[1]) * atlas.pixelsPerMm);
  if (row < 0 || row >= atlas.height || column < 0 || column >= atlas.width) return null;
  const region = atlas.byIndex[atlas.index[row * atlas.width + column]];
  return region ? region.label : null;
}

// The page's look, added once to the document
if (!document.getElementById("ophys-fovmap-style")) {
  const style = document.createElement("style");
  style.id = "ophys-fovmap-style";
  style.textContent = `
    .fov-layout { display: grid; grid-template-columns: 220px minmax(0, 1fr) 280px; gap: 16px; align-items: start; }
    .fov-side { overflow: hidden; }
    .fov-side-column { display: flex; flex-direction: column; gap: 16px; }
    .fov-marks .btn { margin-left: auto; }
    .fov-list { list-style: none; margin: 0; padding: 6px; max-height: 70vh; overflow: auto; }
    .fov-list li { display: flex; align-items: center; gap: 8px; padding: 7px 9px; border-radius: 8px; cursor: pointer; font-size: 13px; }
    .fov-list li:hover { background: var(--surface-2); }
    .fov-list li.selected { background: var(--accent-soft); }
    .fov-list .grow { flex: 1; min-width: 0; }
    .fov-list .sub { font-size: 12px; }
    .fov-map { padding: 0; overflow: hidden; }
    .fov-bar { display: flex; align-items: center; gap: 8px; padding: 10px 12px; border-bottom: 1px solid var(--border); flex-wrap: wrap; }
    .fov-bar .fov-image-variable { width: auto; min-width: 9em; max-width: 16em; flex: 0 1 auto; }
    .fov-bar .fov-opacity { width: 90px; }
    .fov-bar .spacer { flex: 1; }
    .fov-bar .btn.active { background: var(--accent); color: var(--on-accent); border-color: var(--accent); }
    .fov-labels { display: inline-flex; align-items: center; gap: 6px; font-size: 13px; white-space: nowrap; }
    .fov-canvas { display: block; width: 100%; max-width: 600px; margin: 12px auto; aspect-ratio: 3 / 4; cursor: crosshair; }
    .fov-canvas.placing { cursor: copy; }
    .fov-where { padding: 0 14px 12px; font-size: 12px; min-height: 18px; }
    .fov-canvas.over-mark { cursor: grab; }
    .fov-canvas.dragging { cursor: grabbing; }
    .fov-marks .swatch { width: 10px; height: 10px; border-radius: 50%; flex: none; }
    .mark-form { padding: 16px 20px; display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
    .mark-form .field:first-child { grid-column: 1 / -1; }
    .mark-form .input { width: 100%; }
    @media (max-width: 1100px) { .fov-layout { grid-template-columns: 1fr; } }
  `;
  document.head.appendChild(style);
}

/**
 * A drawing context with the calls draw() makes, that writes SVG: the map saved as vectors (dev's fovmanager saved EPS).
 * Images (the atlas, photos, FOV images) are embedded as PNG.
 */
function svgContext(width, height) {
  const parts = [];
  const stack = [];
  let state = { transform: [], dash: [], fillStyle: "#000", strokeStyle: "#000", lineWidth: 1, globalAlpha: 1, font: "11px sans-serif", textAlign: "start" };
  let path = "";
  let clips = 0;
  const escape = (text) => String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  const n = (v) => Math.round(v * 100) / 100;
  const attrs = () => (state.transform.length ? ` transform="${state.transform.join(" ")}"` : "") + (state.globalAlpha < 1 ? ` opacity="${state.globalAlpha}"` : "") +
    (state.clip ? ` clip-path="url(#${state.clip})"` : "");
  const strokeAttrs = () => ` stroke="${state.strokeStyle}" stroke-width="${state.lineWidth}"` + (state.dash.length ? ` stroke-dasharray="${state.dash.join(" ")}"` : "");
  const ctx = {
    get fillStyle() { return state.fillStyle; }, set fillStyle(v) { state.fillStyle = v; },
    get strokeStyle() { return state.strokeStyle; }, set strokeStyle(v) { state.strokeStyle = v; },
    get lineWidth() { return state.lineWidth; }, set lineWidth(v) { state.lineWidth = v; },
    get globalAlpha() { return state.globalAlpha; }, set globalAlpha(v) { state.globalAlpha = v; },
    get font() { return state.font; }, set font(v) { state.font = v; },
    get textAlign() { return state.textAlign; }, set textAlign(v) { state.textAlign = v; },
    imageSmoothingEnabled: false,
    clearRect() {},
    save() { stack.push({ ...state, transform: state.transform.slice(), dash: state.dash.slice() }); },
    restore() { if (stack.length) state = stack.pop(); },
    clip() {   // what is drawn after it is cut to the path, until restore (in the same user space as what is drawn)
      state.clip = `clip${++clips}`;
      parts.push(`<clipPath id="${state.clip}"><path d="${path}"/></clipPath>`);
    },
    translate(x, y) { state.transform.push(`translate(${n(x)} ${n(y)})`); },
    rotate(a) { state.transform.push(`rotate(${n(a * 180 / Math.PI)})`); },
    setLineDash(d) { state.dash = d.slice(); },
    beginPath() { path = ""; },
    moveTo(x, y) { path += `M${n(x)} ${n(y)}`; },
    lineTo(x, y) { path += `L${n(x)} ${n(y)}`; },
    closePath() { path += "Z"; },
    ellipse(x, y, rx, ry) { path += `M${n(x - rx)} ${n(y)}a${n(rx)} ${n(ry)} 0 1 0 ${n(2 * rx)} 0a${n(rx)} ${n(ry)} 0 1 0 ${n(-2 * rx)} 0`; },
    arc(x, y, r) { ctx.ellipse(x, y, r, r); },
    stroke() { parts.push(`<path d="${path}" fill="none"${strokeAttrs()}${attrs()}/>`); },
    fill() { parts.push(`<path d="${path}" fill="${state.fillStyle}"${attrs()}/>`); },
    fillRect(x, y, w, h) { parts.push(`<rect x="${n(x)}" y="${n(y)}" width="${n(w)}" height="${n(h)}" fill="${state.fillStyle}"${attrs()}/>`); },
    strokeRect(x, y, w, h) { parts.push(`<rect x="${n(x)}" y="${n(y)}" width="${n(w)}" height="${n(h)}" fill="none"${strokeAttrs()}${attrs()}/>`); },
    fillText(text, x, y) {
      const anchor = state.textAlign === "center" ? "middle" : state.textAlign === "right" || state.textAlign === "end" ? "end" : "start";
      const size = (state.font.match(/(\d+)px/) || [0, 11])[1];
      parts.push(`<text x="${n(x)}" y="${n(y)}" font-size="${size}" font-family="sans-serif" text-anchor="${anchor}" fill="${state.fillStyle}"${attrs()}>${escape(text)}</text>`);
    },
    drawImage(image, x, y, w, h) {
      parts.push(`<image x="${n(x)}" y="${n(y)}" width="${n(w)}" height="${n(h)}" preserveAspectRatio="none" style="image-rendering:pixelated" href="${image.toDataURL("image/png")}"${attrs()}/>`);
    },
    svg: () => `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">\n${parts.join("\n")}\n</svg>\n`,
  };
  return ctx;
}

/** A data.frame or files.frame result as a canvas: its 8-bit pixels in gray, or channels [r, g, b] of three results in colour. */
function frameCanvas(frames) {
  const [first] = frames;
  const canvas = document.createElement("canvas");
  canvas.width = first.width;
  canvas.height = first.height;
  const ctx = canvas.getContext("2d");
  const image = ctx.createImageData(first.width, first.height);
  const bytes = frames.map((f) => atob(f.pixels));
  for (let i = 0; i < first.width * first.height; i++) {
    for (let c = 0; c < 3; c++) image.data[4 * i + c] = bytes[bytes.length === 3 ? c : 0].charCodeAt(i);
    image.data[4 * i + 3] = 255;
  }
  ctx.putImageData(image, 0, 0);
  return canvas;
}

/** A photo's fields (a file in the project folder or a data location, its width on the map, how opaque); null when cancelled. */
function photoForm(locations, photo = {}) {
  return new Promise((resolve) => {
    const path = h("input.input", { name: "path", value: photo.path || "", placeholder: "images/window.png" });
    const where = h("select.input", { name: "dataLocation" }, h("option", { value: "" }, "Project folder"),
      locations.map((id) => h("option", { value: id, selected: id === photo.dataLocation }, id)));
    const width = h("input.input", { name: "width", type: "number", step: "any", min: 0.1, value: String(photo.width ?? 3) });
    const opacity = h("input.input", { name: "opacity", type: "number", step: "0.05", min: 0, max: 1, value: String(photo.opacity ?? 0.7) });
    const finish = (close) => {
      const values = { path: path.value.trim(), dataLocation: where.value || null, width: Number(width.value), opacity: Number(opacity.value) };
      if (!values.path || !(values.width > 0) || !(values.opacity >= 0 && values.opacity <= 1)) {
        N.toast("Check the fields", "A file, a width above 0 mm and an opacity from 0 to 1", "error");
        return;
      }
      resolve(values);
      close();
    };
    const d = N.dialog({
      title: photo.id ? "Edit photo" : "Photo of the window", narrow: true,
      content: h("div.mark-form",
        h("div.field", h("label.name", "Image file (PNG, JPEG, TIFF, ...), as the window was seen"), path),
        h("div.field", h("label.name", "In"), where), h("div.field", h("label.name", "Width on the map (mm)"), width),
        h("div.field", h("label.name", "Opacity (0 to 1)"), opacity)),
      buttons: [{ label: "Cancel", onClick: (close) => { resolve(null); close(); } }, { label: "OK", kind: "primary", onClick: finish }],
      onClose: () => resolve(null),
    });
    d.el.classList.add("photo-dialog");
    setTimeout(() => path.focus(), 0);
  });
}

/**
 * A window's outline (an ellipse, its width and height, or a polygon, its corners: "x, y" a line, mm from the window's
 * centre before its rotation, x to the right, y to the front), as fovmanager's windows of other shapes; null when
 * cancelled.
 */
function outlineForm(outline = {}) {
  return new Promise((resolve) => {
    const kind = h("select.input", { name: "kind" }, ["ellipse", "polygon"].map((k) =>
      h("option", { value: k, selected: k === (outline.polygon ? "polygon" : "ellipse") }, k)));
    const [rx, ry] = outline.ellipse || [1.5, 1.5];
    const width = h("input.input", { name: "width", type: "number", step: "any", min: 0, value: String(2 * rx) });
    const height = h("input.input", { name: "height", type: "number", step: "any", min: 0, value: String(2 * ry) });
    const points = h("textarea.input.mono", { name: "points", rows: 5,
      placeholder: "-1.5, 2.5\n-2.5, -2.5\n2.5, -2.5\n1.5, 2.5" }, (outline.polygon || []).map((p) => p.join(", ")).join("\n"));
    const finish = (close) => {
      let values;
      if (kind.value === "ellipse") {
        values = { ellipse: [Number(width.value) / 2, Number(height.value) / 2] };
        if (!values.ellipse.every((v) => v > 0)) { N.toast("Check the fields", "A width and a height above 0 mm", "error"); return; }
      } else {
        const corners = points.value.split("\n").map((line) => line.trim()).filter(Boolean).map((line) => line.split(/[\s,;]+/).map(Number));
        if (corners.length < 3 || !corners.every((p) => p.length === 2 && p.every((v) => isFinite(v)))) {
          N.toast("Check the corners", "Three or more lines of x, y (mm)", "error");
          return;
        }
        values = { polygon: corners };
      }
      resolve(values);
      close();
    };
    const d = N.dialog({
      title: "Window outline", narrow: true,
      content: h("div.mark-form",
        h("div.field", h("label.name", "An ellipse, or the corners of a polygon (mm from the window's centre, before its rotation)"), kind),
        h("div.field", h("label.name", "Width (mm)"), width), h("div.field", h("label.name", "Height (mm)"), height),
        h("div.field.outline-points", h("label.name", "Corners: x, y a line"), points)),
      buttons: [{ label: "Cancel", onClick: (close) => { resolve(null); close(); } }, { label: "OK", kind: "primary", onClick: finish }],
      onClose: () => resolve(null),
    });
    d.el.classList.add("outline-dialog");
  });
}

/** A text asked for in a small dialog (a headbar label, an inventory's file); null when cancelled. */
function textForm(title, label, value = "", className = "text-dialog", placeholder = "") {
  return new Promise((resolve) => {
    const input = h("input.input", { name: "text", value, placeholder });
    const finish = (close) => {
      if (!input.value.trim()) { N.toast("Check the field", `${label} is empty`, "error"); return; }
      resolve(input.value.trim());
      close();
    };
    const d = N.dialog({
      title, narrow: true, content: h("div.mark-form", h("div.field", h("label.name", label), input)),
      buttons: [{ label: "Cancel", onClick: (close) => { resolve(null); close(); } }, { label: "OK", kind: "primary", onClick: finish }],
      onClose: () => resolve(null),
    });
    d.el.classList.add(className);
    input.addEventListener("keydown", (e) => { if (e.key === "Enter") finish(d.close); });
    setTimeout(() => input.focus(), 0);
  });
}

const keyText = (key) => Object.values(key).join(" / ");
const sameKey = (a, b) => Object.keys(a).every((k) => a[k] === b[k]);
const number = (v) => (typeof v === "number" && isFinite(v) ? v : null);
const COLOURS = { magenta: "#d81b60", green: "#2e7d32", red: "#c62828", blue: "#1565c0", orange: "#ef6c00", purple: "#6a1b9a",
  cyan: "#00838f", yellow: "#f9a825" };   // cyan and yellow: dev's other colours of injections
const colourOf = (mark) => COLOURS[mark.colour] || COLOURS.magenta;

/** A dialog with the fields of an injection or a note; resolves to the values, or null when cancelled. */
function markForm(kind, mark = {}) {
  return new Promise((resolve) => {
    const fields = (kind === "injections"
      ? [["material", "What was injected (virus or tracer)", "text"], ["depth", "Depth (µm)", "number"], ["volume", "Volume (nL)", "number"],
        ["spread", "Spread (µm, radius)", "number"], ["colour", "Colour", "colour"]]
      : [["text", "Note", "text"]])
      // a mark on the map is moved by dragging it, or here by its place: what the drag does, from the keyboard
      .concat(mark.id !== undefined ? [["ap", "AP (mm from bregma)", "place"], ["ml", "ML (mm from the midline)", "place"]] : []);
    const inputs = {};
    const rows = fields.map(([name, label, type]) => {
      const value = mark[name] === undefined || mark[name] === null ? "" : String(mark[name]);
      inputs[name] = type === "colour"
        ? h("select.input", { name }, Object.keys(COLOURS).map((c) => h("option", { value: c, selected: c === (mark.colour || "magenta") }, c)))
        : h("input.input", { name, type: type === "text" ? "text" : "number", value, step: type === "text" ? undefined : "any", min: type === "number" ? 0 : undefined });
      return h("div.field", h("label.name", label), inputs[name]);
    });
    const read = () => {
      const values = {};
      for (const [name, , type] of fields) {
        const raw = inputs[name].value.trim();
        values[name] = type === "number" || type === "place" ? (raw === "" ? null : Number(raw)) : raw;
      }
      return values;
    };
    const valid = () => {
      const values = read();
      return fields.every(([name, , type]) => type !== "number" || values[name] === null || (isFinite(values[name]) && values[name] >= 0)) &&
        fields.every(([name, , type]) => type !== "place" || (values[name] !== null && isFinite(values[name]))) &&
        (kind !== "notes" || values.text);
    };
    const finish = (close) => { if (!valid()) { N.toast("Check the fields", "Numbers are 0 or more, a place is AP and ML in mm, and a note has text", "error"); return; } resolve(read()); close(); };
    const d = N.dialog({
      title: (mark.id ? "Edit " : "New ") + (kind === "injections" ? "injection site" : "note"), narrow: true,
      content: h("div.mark-form", rows),
      buttons: [{ label: "Cancel", onClick: (close) => { resolve(null); close(); } }, { label: "OK", kind: "primary", onClick: finish }],
      onClose: () => resolve(null),
    });
    d.el.classList.add("mark-dialog");
    // Enter is OK; prevented, so it does not also press the button the focus goes back to as the dialog closes
    Object.values(inputs).forEach((input) => input.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); finish(d.close); } }));
    setTimeout(() => inputs[fields[0][0]].focus(), 0);
  });
}

/** What the list and the map say about an injection: what, how deep, how much. */
function injectionText(m) {
  return [m.material || "Injection", number(m.depth) !== null ? `${m.depth} µm deep` : null, number(m.volume) !== null ? `${m.volume} nL` : null]
    .filter(Boolean).join(" · ");
}

N.registerPage({
  id: "ophys.fovmap", title: "FOV map", icon: "compass",
  async render(app, el) {
    const types = app.project.entityTypes;
    const fovType = types.find((t) => (t.fragments || []).includes("ophys.fov_position"));
    const windowType = types.find((t) => (t.fragments || []).includes("ophys.cranial_window"));
    if (!fovType) {
      N.fill(el, h("div.empty", h("h3", "No FOV positions yet"),
        h("p.muted", "Run the tool Set up two-photon variables (ophys.setup_variables) from the overview: it adds the FOV and cranial window columns.")));
      return;
    }
    const atlas = await loadAtlas(app);
    const state = { subject: null, session: null, placing: null, labels: true, hover: null, images: false, imageVariable: "", opacity: 0.8, rois: false, roiVariable: "",
      fineGrid: false, picked: null, copied: null };   // picked: what Copy copies ({kind, key} or {kind, mark}); copied: {kind, values}
    const imageCache = new Map();   // FOV images and window photos, by what they were read from: a canvas, or null when unreadable
    const history = [], future = [];   // undo and redo: {undo, redo} of changes to the marks and to placements
    let sessions = [];
    let subjects = [];
    // the module's data: injection sites, notes, photos (of windows and FOVs), window outlines and headbar labels
    let marks = Object.fromEntries(MARK_KINDS.map((kind) => [kind, []]));
    let revision = 0;

    async function loadMarks() {
      const stored = await app.client.request("modules.data", { module, name: "fovmap" });
      const value = JSON.parse(stored.text) || {};
      marks = Object.fromEntries(MARK_KINDS.map((kind) => [kind, Array.isArray(value[kind]) ? value[kind] : []]));
      revision = stored.revision;
    }
    const ofOwner = (list, s) => list.find((m) => m.subject && sameKey(m.subject, s.key));   // a subject's outline or headbar
    const windowPhotos = () => marks.photos.filter((p) => !p.session);
    const fovPhoto = (session) => marks.photos.find((p) => p.session && sameKey(p.session, session.key));
    // Change the marks and save them; if another window saved first, start again from what it saved. Undoable.
    async function changeMarks(change, undoable = true) {
      const before = JSON.stringify(marks);
      await saveMarks(change);
      if (!undoable) return;
      const after = JSON.stringify(marks);
      remember(() => saveMarks((all) => Object.assign(all, JSON.parse(before))), () => saveMarks((all) => Object.assign(all, JSON.parse(after))));
    }
    function remember(undo, redo) {
      history.push({ undo, redo });
      future.length = 0;
      updateHistory();
    }
    async function step(from, to, which) {
      const entry = from.pop();
      if (!entry) return;
      try {
        await entry[which]();
        to.push(entry);
        await load();
        refresh();
      } catch (error) { N.showError(error, which === "undo" ? "Could not undo it" : "Could not redo it"); }
      updateHistory();
    }
    // Place an FOV or a window (entity columns), undoably: the values it had are put back
    async function place(entityType, key, values, region) {
      const row = (entityType === fovType.name ? sessions : subjects).find((r) => sameKey(r.key, key));
      const old = Object.fromEntries(Object.keys(values).map((k) => [k, row ? row.values[k] ?? null : null]));
      const set = async (v) => {
        await app.client.request("entities.update", { entityType, key, values: v });
        if (region) await app.client.request("fragments.update", { entityType, fragmentId: "ophys.fov_region", keys: [key] });
      };
      await set(values);
      remember(() => set(old), () => set(values));
    }
    async function saveMarks(change) {
      for (let attempt = 0; attempt < 2; attempt++) {
        change(marks);
        try {
          const saved = await app.client.request("modules.saveData", { module, name: "fovmap", text: JSON.stringify(marks), revision });
          revision = saved.revision;
          return;
        } catch (error) {
          if (error.code !== "revision-conflict" || attempt) throw error;
          await loadMarks();
        }
      }
    }
    const nextId = (list) => list.reduce((m, x) => Math.max(m, x.id), 0) + 1;
    const ofSubject = (mark) => !state.subject || (mark.subject && sameKey(mark.subject, state.subject));

    async function load() {
      const [fovs, owners] = await Promise.all([
        app.client.request("entities.list", { entityType: fovType.name }),
        windowType ? app.client.request("entities.list", { entityType: windowType.name }) : Promise.resolve({ rows: [] })]);
      sessions = fovs.rows;
      subjects = owners.rows;
      await loadMarks();
    }
    async function loadChoices() {
      try {
        const all = (await app.client.request("dataVariables.list", {})).filter((v) => v.entityType === fovType.name);
        imageVariables = all.filter((v) => ["Image", "ImageStack"].includes(v.dataType));
        roiVariables = all.filter((v) => v.dataType === "RoiArray");
      } catch (error) { imageVariables = []; roiVariables = []; }
      try {
        const dataset = await app.client.request("dataset.get", {});
        locations = (JSON.parse(dataset.text).dataLocations || []).map((l) => l.identifier);
      } catch (error) { locations = []; }
      state.imageVariable = (imageVariables.find((v) => v.name === "FovAverageProjection") || imageVariables[0] || {}).name || "";
      state.roiVariable = (roiVariables.find((v) => v.name === "RoiArray") || roiVariables[0] || {}).name || "";
      roiToggle.disabled = !state.roiVariable || !imageVariables.length;
      N.fill(imagePick, imageVariables.map((v) => h("option", { value: v.name, selected: v.name === state.imageVariable }, v.title || v.name)));
      imageToggle.disabled = !imageVariables.length;
    }
    // An image read once and kept: an FOV's image variable (data.frame), or a window photo (files.frame, in colour)
    function cachedImage(id, read) {
      if (imageCache.has(id)) return imageCache.get(id);
      imageCache.set(id, null);
      read().then((canvas) => { imageCache.set(id, canvas); draw(); }, () => imageCache.set(id, null));
      return null;
    }
    const fovImage = (session) => cachedImage(`fov|${state.imageVariable}|${keyText(session.key)}`, async () => {
      const variable = imageVariables.find((v) => v.name === state.imageVariable);
      const frame = await app.client.request("data.frame", { entityType: fovType.name, key: session.key, variable: state.imageVariable,
        ...(variable && variable.dataType === "ImageStack" ? { projection: "mean" } : {}) });
      return frameCanvas([frame]);
    });
    const photoImage = (photo) => cachedImage(`photo|${photo.dataLocation || ""}|${photo.path}`, async () => {
      const where = { path: photo.path, ...(photo.dataLocation ? { dataLocation: photo.dataLocation } : {}) };
      const first = await app.client.request("files.frame", where);
      if (first.channels !== 3) return frameCanvas([first]);
      const colours = await Promise.all([0, 1, 2].map((channel) => app.client.request("files.frame", { ...where, channel, limits: [0, 255] })));
      return frameCanvas(colours);
    });
    // An FOV's ROIs (fovmanager's Show ROIs), as data.frame gives them with its image: drawn once on a canvas of the image's size
    const fovRois = (session) => cachedImage(`rois|${state.roiVariable}|${state.imageVariable}|${keyText(session.key)}`, async () => {
      const variable = imageVariables.find((v) => v.name === state.imageVariable);
      const frame = await app.client.request("data.frame", { entityType: fovType.name, key: session.key, variable: state.imageVariable,
        rois: state.roiVariable, ...(variable && variable.dataType === "ImageStack" ? { projection: "mean" } : {}) });
      const layer = document.createElement("canvas");
      layer.width = frame.width;
      layer.height = frame.height;
      const ctx = layer.getContext("2d");
      const colours = { accepted: "rgba(60, 200, 90, 0.85)", rejected: "rgba(220, 60, 60, 0.6)" };
      (frame.rois || []).forEach((roi) => {
        ctx.fillStyle = colours[roi.classification] || "rgba(0, 210, 255, 0.85)";
        roi.pixels.forEach(([row, column]) => ctx.fillRect(column, row, 1, 1));
      });
      layer.dataset.count = String((frame.rois || []).length);
      return layer;
    });
    let imageVariables = [];
    let roiVariables = [];
    let locations = [];

    // A session belongs to the subject whose key values it carries
    const subjectOf = (session) => subjects.find((s) => Object.keys(s.key).every((k) => session.values[k] === s.key[k])) || null;
    const shown = () => sessions.filter((s) => !state.subject || (subjectOf(s) && sameKey(subjectOf(s).key, state.subject)));

    const canvas = h("canvas.fov-canvas", { width: 600, height: 800, tabindex: "0", role: "application", "aria-roledescription": "map",
      "aria-label": "The map. The arrow keys move a cursor (Shift: 0.5 mm), Enter or Space places, selects or edits there, as a click does" });
    const where = h("div.fov-where.mono.muted", "");
    const subjectList = N.listbox(h("ul.fov-list"), "Subjects");
    const sessionList = N.listbox(h("ul.fov-list"), "Fields of view");
    const placeFov = h("button.btn.small.place-fov", { on: { click: () => setPlacing("fov") } }, N.icon("plus", 13), "Place FOV");
    const placeWindow = h("button.btn.small.place-window", { on: { click: () => setPlacing("window") } }, N.icon("plus", 13), "Place window");
    const placeInjection = h("button.btn.small.place-injection", { on: { click: () => setPlacing("injection") } }, N.icon("plus", 13), "Add injection");
    const placeNote = h("button.btn.small.place-note", { on: { click: () => setPlacing("note") } }, N.icon("note", 13), "Add note");
    const markList = h("ul.fov-list.fov-marks");
    const labels = h("input", { type: "checkbox", checked: true, on: { change: () => { state.labels = labels.checked; draw(); } } });
    const fineGrid = h("input.fov-fine-grid", { type: "checkbox", on: { change: () => { state.fineGrid = fineGrid.checked; draw(); } } });
    const copyButton = h("button.btn.ghost.icon.small.fov-copy", { title: "Copy the FOV, window or mark picked last (Ctrl+C)", on: { click: () => copy() } }, N.icon("copy", 14));
    const pasteButton = h("button.btn.ghost.small.fov-paste", { title: "Paste: the selected session's FOV, the selected subject's window, or a new mark of the selected subject (Ctrl+V)",
      disabled: true, on: { click: () => paste() } }, "Paste");
    const exportButton = h("button.btn.ghost.icon.small.fov-export", { title: "Save the map as PNG", on: { click: () => saveMap() } }, N.icon("download", 14));
    const svgButton = h("button.btn.ghost.small.fov-export-svg", { title: "Save the map as SVG (vectors, for figures)", on: { click: () => saveSvg() } }, "SVG");
    const undoButton = h("button.btn.ghost.icon.small.fov-undo", { title: "Undo (Ctrl+Z)", on: { click: () => step(history, future, "undo") } }, N.icon("undo", 14));
    const redoButton = h("button.btn.ghost.icon.small.fov-redo", { title: "Redo (Ctrl+Shift+Z)", on: { click: () => step(future, history, "redo") } }, N.icon("redo", 14));
    const updateHistory = () => { undoButton.disabled = !history.length; redoButton.disabled = !future.length; };
    const imageToggle = h("input.fov-images", { type: "checkbox", on: { change: () => { state.images = imageToggle.checked; draw(); } } });
    const imagePick = h("select.input.fov-image-variable", { title: "The FOVs' image", on: { change: () => { state.imageVariable = imagePick.value; draw(); } } });
    const roiToggle = h("input.fov-rois", { type: "checkbox", disabled: true, on: { change: () => { state.rois = roiToggle.checked; draw(); } } });
    const opacityPick = h("input.fov-opacity", { type: "range", min: 0, max: 1, step: 0.05, value: state.opacity, title: "Opacity of the FOV images",
      on: { input: () => { state.opacity = Number(opacityPick.value); draw(); } } });
    const addPhoto = h("button.btn.small.add-photo", { title: "Show a photo of the subject's window on the map", on: { click: async () => {
      const values = await photoForm(locations);
      if (!values) return;
      try {
        await changeMarks((all) => { all.photos.push({ id: nextId(all.photos), subject: state.subject, ...values }); });
        refresh();
      } catch (error) { N.showError(error, "Could not add the photo"); }
    } } }, N.icon("image", 13), "Photo");
    // a subject's window outline or headbar label: one each, set in place of the one it had
    const setOwn = (kind, values) => changeMarks((all) => {
      all[kind] = all[kind].filter((m) => !(m.subject && sameKey(m.subject, state.subject)));
      all[kind].push({ id: nextId(all[kind]), subject: state.subject, ...values });
    });
    const setOutline = h("button.btn.small.set-outline", { title: "Give the subject's window an outline of its own: an ellipse, or a polygon (fovmanager's windows of other shapes)",
      on: { click: async () => {
        const values = await outlineForm(ofOwner(marks.outlines, { key: state.subject }));
        if (!values) return;
        try { await setOwn("outlines", values); refresh(); } catch (error) { N.showError(error, "Could not set the outline"); }
      } } }, N.icon("polygon", 13), "Outline");
    const setHeadbar = h("button.btn.small.set-headbar", { title: "The subject's headbar label, as fovmanager's", on: { click: async () => {
      const current = ofOwner(marks.headbars, { key: state.subject });
      const label = await textForm("Headbar label", "Label", current ? current.label : "", "headbar-dialog");
      if (!label) return;
      try { await setOwn("headbars", { label }); refresh(); } catch (error) { N.showError(error, "Could not set the label"); }
    } } }, "Headbar");
    // fovmanager's Load Fov Inventory: dev's inventory (.mat) onto this map, read by the backend
    const importButton = h("button.btn.ghost.small.import-inventory", { title: "Bring an inventory of NANSEN dev's fovmanager (its Save Fov Inventory .mat file) onto this map: windows, FOVs, images, injections, notes, headbar labels",
      on: { click: () => importInventory() } }, N.icon("file", 13), "Import dev FOV inventory…");
    async function importInventory() {
      const path = await textForm("Import dev FOV inventory",
        "The .mat file of fovmanager's Save Fov Inventory, or its JSON export (nansen.legacy.exportFovInventory); a full path, or relative to the project folder",
        "", "inventory-dialog", "fov_inventory.mat");
      if (!path) return;
      try {
        const report = await app.client.request("legacy.importFovInventory", { path });
        imageCache.clear();   // its images may be new files of the same names
        await load();
        refresh();
        N.toast("Imported from dev's fovmanager", [`${report.sessions.length} FOV(s)`, `${report.subjects.length} window(s)`,
          `${report.injections} injection(s)`, `${report.notes} note(s)`, `${report.photos} image(s)`].join(" · "), "success", 7000);
        if (report.warnings.length) {
          const d = N.dialog({ title: "Not carried over", content: h("div", { style: { padding: "16px 20px" } },
            h("p.muted", { style: { marginTop: 0 } }, "The import left these out:"),
            h("ul.notes", report.warnings.map((w) => h("li", w)))), buttons: [{ label: "OK", kind: "primary" }] });
          d.el.classList.add("inventory-warnings");
        }
      } catch (error) { N.showError(error, "Could not import the inventory"); }
    }

    const scale = () => canvas.width / (atlas.width / atlas.pixelsPerMm);   // px per mm
    const toCanvas = (ml, ap) => [(ml - atlas.origin[0]) * scale(), (atlas.origin[1] + atlas.height / atlas.pixelsPerMm - ap) * scale()];
    const toMm = (x, y) => [atlas.origin[0] + x / scale(), atlas.origin[1] + atlas.height / atlas.pixelsPerMm - y / scale()];

    function setPlacing(what) {
      state.placing = state.placing === what ? null : what;
      placeFov.classList.toggle("active", state.placing === "fov");
      placeWindow.classList.toggle("active", state.placing === "window");
      placeInjection.classList.toggle("active", state.placing === "injection");
      placeNote.classList.toggle("active", state.placing === "note");
      canvas.classList.toggle("placing", Boolean(state.placing));
    }

    function draw(ctx = canvas.getContext("2d")) {
      let drawnImages = 0, drawnPhotos = 0, drawnRois = 0;
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(atlasImage(atlas), 0, 0, canvas.width, canvas.height);
      let gridLines = 0;
      if (state.fineGrid) {   // fovmanager's Show Fine Grid: a line every 0.2 mm, stronger at whole millimetres
        const [left, top] = toMm(0, 0), [right, bottom] = toMm(canvas.width, canvas.height);
        ctx.lineWidth = 1;
        ctx.setLineDash([]);
        for (const across of [true, false]) {
          const [low, high] = across ? [left, right] : [bottom, top];
          for (let k = Math.ceil(low * 5); k <= Math.floor(high * 5); k++) {
            ctx.strokeStyle = k % 5 === 0 ? "rgba(20, 24, 33, 0.35)" : "rgba(20, 24, 33, 0.12)";
            ctx.beginPath();
            if (across) { const [x] = toCanvas(k / 5, 0); ctx.moveTo(x, 0); ctx.lineTo(x, canvas.height); }
            else { const [, y] = toCanvas(0, k / 5); ctx.moveTo(0, y); ctx.lineTo(canvas.width, y); }
            ctx.stroke();
            gridLines++;
          }
        }
      }
      ctx.font = "11px system-ui, sans-serif";
      ctx.textAlign = "center";
      if (state.labels) {
        ctx.fillStyle = "rgba(20, 24, 33, 0.7)";
        atlas.regions.forEach((r) => { const [x, y] = toCanvas(r.center[0], r.center[1]); ctx.fillText(r.label, x, y + 4); });
      }
      const [bx, by] = toCanvas(0, 0);   // bregma
      ctx.strokeStyle = "rgba(20, 24, 33, 0.8)";
      ctx.beginPath(); ctx.moveTo(bx - 6, by); ctx.lineTo(bx + 6, by); ctx.moveTo(bx, by - 6); ctx.lineTo(bx, by + 6); ctx.stroke();
      // a window's outline as a path, in its own frame (x right, y to the front, mm): its outline in the module's data
      // (fovmanager's windows fitted to a photo, or of other sizes), else its shape
      const windowPath = (s) => {
        const outline = ofOwner(marks.outlines, s);
        const k = scale();
        ctx.beginPath();
        if (outline && Array.isArray(outline.polygon) && outline.polygon.length > 2) {
          outline.polygon.forEach(([px, py], i) => (i ? ctx.lineTo(px * k, -py * k) : ctx.moveTo(px * k, -py * k)));
          ctx.closePath();
        } else if (outline && Array.isArray(outline.ellipse)) {
          ctx.ellipse(0, 0, outline.ellipse[0] * k, outline.ellipse[1] * k, 0, 0, 2 * Math.PI);
        } else {
          const [hw, hh, round, front] = SHAPES[s.values.window_shape] || SHAPES["round 3 mm"];
          if (round) ctx.ellipse(0, 0, hw * k, hh * k, 0, 0, 2 * Math.PI);
          else { ctx.moveTo(-front * k, -hh * k); ctx.lineTo(front * k, -hh * k); ctx.lineTo(hw * k, hh * k); ctx.lineTo(-hw * k, hh * k); ctx.closePath(); }
        }
      };
      const atWindow = (s) => {   // the window's frame: at its centre, turned with it; false when it is not placed
        const ml = number(s.values.window_ml), ap = number(s.values.window_ap);
        if (ml === null || ap === null) return false;
        const [x, y] = toCanvas(ml, ap);
        ctx.translate(x, y);
        ctx.rotate(-(number(s.values.window_rotation) || 0) * Math.PI / 180);
        return true;
      };
      windowPhotos().filter(ofSubject).forEach((photo) => {   // a photo of the window, on it, turned with it, cut to it
        const s = subjects.find((x) => photo.subject && sameKey(x.key, photo.subject));
        const image = photoImage(photo);
        if (!s || !image) return;
        ctx.save();
        if (!atWindow(s)) { ctx.restore(); return; }
        const w = photo.width * scale(), hgt = (number(photo.height) || photo.width * image.height / image.width) * scale();
        const [dx, dy] = Array.isArray(photo.offset) ? photo.offset.map((v) => v * scale()) : [0, 0];
        windowPath(s);
        ctx.clip();
        ctx.globalAlpha = photo.opacity;
        ctx.drawImage(image, dx - w / 2, -dy - hgt / 2, w, hgt);
        ctx.restore();
        drawnPhotos++;
      });
      let outlines = 0;
      subjects.forEach((s) => {
        const selected = state.subject && sameKey(s.key, state.subject);
        ctx.save();
        if (!atWindow(s)) { ctx.restore(); return; }
        ctx.lineWidth = selected ? 3 : 1.5;
        ctx.strokeStyle = selected ? "#3d5afe" : "rgba(20, 24, 33, 0.55)";
        ctx.setLineDash(selected ? [] : [5, 4]);
        windowPath(s);
        ctx.stroke();
        ctx.restore();
        if (ofOwner(marks.outlines, s)) outlines++;
      });
      marks.injections.filter(ofSubject).forEach((m) => {   // injection sites: the spread, a dot, and what was injected
        const [x, y] = position(m);
        const colour = colourOf(m);
        if (number(m.spread)) {
          ctx.fillStyle = colour + "33";
          ctx.strokeStyle = colour + "aa";
          ctx.lineWidth = 1;
          ctx.setLineDash([]);
          ctx.beginPath(); ctx.arc(x, y, m.spread / 1000 * scale(), 0, 2 * Math.PI); ctx.fill(); ctx.stroke();
        }
        ctx.fillStyle = colour;
        ctx.beginPath(); ctx.arc(x, y, 5, 0, 2 * Math.PI); ctx.fill();
        ctx.strokeStyle = "white"; ctx.lineWidth = 1.5; ctx.stroke();
        if (m.material) {
          ctx.fillStyle = "rgba(20, 24, 33, 0.85)";
          ctx.fillText(m.material + (number(m.depth) !== null ? ` · ${m.depth} µm` : ""), x, y - 9);
        }
      });
      marks.notes.filter(ofSubject).forEach((m) => {   // notes: a small flag and the text
        const [x, y] = position(m);
        ctx.fillStyle = "#1e3a8a";
        ctx.fillRect(x - 3, y - 3, 6, 6);
        ctx.textAlign = "left";
        ctx.fillText(m.text, x + 6, y + 4);
        ctx.textAlign = "center";
      });
      shown().forEach((s) => {
        const ml = number(s.values.fov_ml), ap = number(s.values.fov_ap);
        if (ml === null || ap === null) return;
        const w = (number(s.values.fov_width_um) || 500) / 1000 * scale(), hgt = (number(s.values.fov_height_um) || number(s.values.fov_width_um) || 500) / 1000 * scale();
        const [x, y] = toCanvas(ml, ap);
        const selected = state.session && sameKey(s.key, state.session);
        // the FOV's own image in its place, as fovmanager's FOV images: its image variable's, else the one fovmanager kept
        const photo = state.images ? fovPhoto(s) : null;
        const image = (state.images && state.imageVariable ? fovImage(s) : null) || (photo ? photoImage(photo) : null);
        if (image) {
          ctx.save();
          ctx.globalAlpha = state.opacity;
          ctx.drawImage(image, x - w / 2, y - hgt / 2, w, hgt);
          ctx.restore();
          drawnImages++;
        } else {
          ctx.fillStyle = selected ? "rgba(61, 90, 254, 0.45)" : "rgba(255, 170, 0, 0.35)";
          ctx.fillRect(x - w / 2, y - hgt / 2, w, hgt);
        }
        const rois = state.rois && state.roiVariable && state.imageVariable ? fovRois(s) : null;
        if (rois) {   // its ROIs over it, row and column scaled into the FOV
          ctx.save();
          ctx.imageSmoothingEnabled = false;
          ctx.drawImage(rois, x - w / 2, y - hgt / 2, w, hgt);
          ctx.restore();
          drawnRois += Number(rois.dataset.count);
        }
        ctx.strokeStyle = selected ? "#3d5afe" : "#b26a00";
        ctx.lineWidth = selected ? 2.5 : 1.5;
        ctx.setLineDash([]);
        ctx.strokeRect(x - w / 2, y - hgt / 2, w, hgt);
      });
      if (ctx === canvas.getContext("2d") && state.cursor) {   // the keyboard's cursor (not in the saved map)
        const [x, y] = toCanvas(...state.cursor);
        ctx.setLineDash([]);
        for (const [colour, width] of [["rgba(255, 255, 255, 0.95)", 4], ["#111827", 1.5]]) {
          ctx.strokeStyle = colour;
          ctx.lineWidth = width;
          ctx.beginPath();
          ctx.moveTo(x - 9, y); ctx.lineTo(x + 9, y); ctx.moveTo(x, y - 9); ctx.lineTo(x, y + 9);
          ctx.stroke();
        }
      }
      if (ctx === canvas.getContext("2d")) {
        canvas.dataset.images = String(drawnImages); canvas.dataset.photos = String(drawnPhotos); canvas.dataset.rois = String(drawnRois);
        canvas.dataset.gridLines = String(gridLines);
        canvas.dataset.outlines = String(outlines);
      }
    }

    function renderLists() {
      N.listbox.fill(subjectList, N.option(h("li" + (!state.subject ? ".selected" : ""), { on: { click: () => { state.subject = null; refresh(); } } },
        h("span.grow", "All"), h("span.muted", String(sessions.length))), !state.subject),
      subjects.map((s) => N.option(h("li" + (state.subject && sameKey(s.key, state.subject) ? ".selected" : ""), { dataset: { subject: keyText(s.key) },
        on: { click: () => { state.subject = s.key; state.session = null; state.picked = { kind: "window", key: s.key }; refresh(); } } },
        h("span.grow", keyText(s.key), ofOwner(marks.headbars, s) ? h("span.muted.headbar", ` · ${ofOwner(marks.headbars, s).label}`) : null),
        number(s.values.window_ml) === null ? h("span.muted", "no window")
          : h("span.pill.plain", ofOwner(marks.outlines, s) ? "outline" : s.values.window_shape || "window")),
        Boolean(state.subject && sameKey(s.key, state.subject)))));
      N.listbox.fill(sessionList, shown().map((s) => {
        const placed = number(s.values.fov_ml) !== null && number(s.values.fov_ap) !== null;
        return N.option(h("li" + (state.session && sameKey(s.key, state.session) ? ".selected" : ""), { dataset: { session: keyText(s.key) },
          on: { click: () => { state.session = s.key; state.picked = { kind: "fov", key: s.key }; refresh(); } } },
          h("span.dot." + (placed ? "good" : "warn")),
          h("div.grow", h("div", keyText(s.key)), h("div.sub.muted", placed ? `${s.values.brain_region || "–"} · AP ${s.values.fov_ap}, ML ${s.values.fov_ml}` : "not placed"))),
          Boolean(state.session && sameKey(s.key, state.session)));
      }));
      placeFov.disabled = !state.session;
      placeWindow.disabled = !state.subject || !windowType;
      placeInjection.disabled = !state.subject;
      const subjectRow = state.subject && subjects.find((x) => sameKey(x.key, state.subject));
      addPhoto.disabled = setOutline.disabled = !subjectRow || number(subjectRow.values.window_ml) === null;
      setHeadbar.disabled = !subjectRow;
      imageToggle.disabled = !imageVariables.length && !marks.photos.some((p) => p.session);
      const owner = (m) => (m.subject ? ` · ${keyText(m.subject)}` : "");
      const outlineText = (m) => (Array.isArray(m.ellipse) ? `ellipse ${round2(2 * m.ellipse[0])} × ${round2(2 * m.ellipse[1])} mm`
        : `polygon of ${(m.polygon || []).length} corners`);
      const listed = [...marks.injections.filter(ofSubject).map((m) => ["injections", m, injectionText(m)]),
        ...marks.notes.filter(ofSubject).map((m) => ["notes", m, m.text]),
        ...marks.photos.filter(ofSubject).map((m) => ["photos", m, `${m.session ? "FOV image" : "Photo"}: ${m.path.split("/").pop()}`]),
        ...marks.outlines.filter(ofSubject).map((m) => ["outlines", m, `Window outline: ${outlineText(m)}`]),
        ...marks.headbars.filter(ofSubject).map((m) => ["headbars", m, `Headbar: ${m.label}`])];
      const detail = (kind, m) => (kind === "photos" ? (m.session ? keyText(m.session) : `${m.width} mm wide · opacity ${m.opacity}${owner(m)}`)
        : kind === "outlines" || kind === "headbars" ? owner(m).slice(3)
          : `AP ${m.ap}, ML ${m.ml}` + (number(m.spread) ? ` · spread ${m.spread} µm` : "") + owner(m));
      N.fill(markList, listed.length ? listed.map(([kind, m, label]) => h("li", { dataset: { mark: `${kind}-${m.id}` }, title: "Edit",
        on: { click: () => { state.picked = { kind, mark: m }; edit(kind, m); } } },
        kind === "injections" ? h("span.swatch", { style: { background: colourOf(m) } }) : kind === "photos" ? N.icon("image", 12) : h("span.dot.plain"),
        // its name is a button: the keyboard's way to edit it (the pointer clicks anywhere on the item, or on the map)
        h("div.grow", h("button.mark-edit", { title: "Edit (also its place: AP and ML)" }, label), h("div.sub.muted", detail(kind, m))),
        kind === "photos" && m.session ? null : h("button.btn.ghost.icon.small.copy-mark", { title: "Copy (paste it for another subject)", on: { click: (event) => {
          event.stopPropagation();
          state.picked = { kind, mark: m };
          copy();
        } } }, N.icon("copy", 12)),
        h("button.btn.ghost.icon.small.remove-mark", { title: "Remove", on: { click: async (event) => {
          event.stopPropagation();
          try { await changeMarks((all) => { all[kind] = all[kind].filter((x) => x.id !== m.id); }); refresh(); }
          catch (error) { N.showError(error, "Could not remove it"); }
        } } }, N.icon("trash", 12)))) : h("li.muted", "No injections, notes, photos or outlines"));
    }

    function refresh() { renderLists(); draw(); }

    // fovmanager's Copy and Paste: what is copied is kept as values, pasted onto what is selected then, undoably
    const PLACEMENT = { fov: ["fov_ml", "fov_ap", "fov_width_um", "fov_height_um"], window: ["window_ml", "window_ap", "window_shape", "window_rotation"] };
    function copy() {
      const picked = state.picked;
      if (!picked) { N.toast("Nothing to copy", "Pick an FOV, a window or a mark first"); return; }
      let values = null, label = "";
      if (picked.kind === "fov" || picked.kind === "window") {
        const row = (picked.kind === "fov" ? sessions : subjects).find((r) => sameKey(r.key, picked.key));
        values = row && Object.fromEntries(PLACEMENT[picked.kind].filter((c) => row.values[c] !== undefined && row.values[c] !== null).map((c) => [c, row.values[c]]));
        if (!values || number(values[`${picked.kind}_ml`]) === null) { N.toast("Not placed", `${keyText(picked.key)} has no ${picked.kind === "fov" ? "FOV" : "window"} on the map`, "error"); return; }
        label = `${picked.kind === "fov" ? "FOV" : "Window"} of ${keyText(picked.key)}`;
      } else {
        const { id, subject, ...rest } = picked.mark;   // eslint-disable-line no-unused-vars
        values = JSON.parse(JSON.stringify(rest));
        label = picked.kind === "injections" ? injectionText(picked.mark) : picked.kind === "outlines" ? "Window outline"
          : picked.kind === "headbars" ? `Headbar ${picked.mark.label}` : picked.kind === "photos" ? picked.mark.path : picked.mark.text;
      }
      state.copied = { kind: picked.kind, values, label };
      pasteButton.disabled = false;
      N.toast("Copied", label, "success", 2000);
    }
    async function paste() {
      const copied = state.copied;
      if (!copied) return;
      try {
        if (copied.kind === "fov") {
          if (!state.session) { N.toast("Select a session", "The copied FOV is pasted as the selected session's", "error"); return; }
          await place(fovType.name, state.session, copied.values, (fovType.fragments || []).includes("ophys.fov_region"));
        } else if (copied.kind === "window") {
          if (!state.subject || !windowType) { N.toast("Select a subject", "The copied window is pasted as the selected subject's", "error"); return; }
          await place(windowType.name, state.subject, copied.values, false);
        } else {
          const own = copied.kind === "outlines" || copied.kind === "headbars";   // one of each per subject
          if ((copied.kind === "injections" || own) && !state.subject) { N.toast("Select a subject", "What was copied is pasted for the selected subject", "error"); return; }
          if (own) await setOwn(copied.kind, JSON.parse(JSON.stringify(copied.values)));
          else await changeMarks((all) => { all[copied.kind].push({ id: nextId(all[copied.kind]), subject: state.subject, ...JSON.parse(JSON.stringify(copied.values)) }); });
        }
        await load();
        refresh();
        N.toast("Pasted", copied.label, "success", 2000);
      } catch (error) { N.showError(error, "Could not paste it"); }
    }

    // Marks: where one is drawn (while it is dragged, where it is dragged to), which is under the pointer
    let drag = null;
    const position = (m) => (drag && drag.mark === m && drag.moved ? drag.at : toCanvas(m.ml, m.ap));
    const pointer = (event) => {
      const rect = canvas.getBoundingClientRect();
      return [(event.clientX - rect.left) / rect.width * canvas.width, (event.clientY - rect.top) / rect.height * canvas.height];
    };
    const markAt = ([x, y]) => {
      for (const kind of ["notes", "injections"]) {
        const hit = marks[kind].filter(ofSubject).reverse().find((m) => { const [mx, my] = toCanvas(m.ml, m.ap); return Math.hypot(mx - x, my - y) <= 8; });
        if (hit) return [kind, hit];
      }
      return null;
    };
    const round2 = (v) => Math.round(v * 100) / 100;
    async function edit(kind, mark) {
      const values = kind === "photos" ? await photoForm(locations, mark) : kind === "outlines" ? await outlineForm(mark)
        : kind === "headbars" ? await textForm("Headbar label", "Label", mark.label, "headbar-dialog").then((label) => label && { label })
          : await markForm(kind, mark);
      if (!values) return;
      try {
        await changeMarks((all) => {
          const m = all[kind].find((x) => x.id === mark.id);
          if (m && kind === "outlines") { delete m.ellipse; delete m.polygon; }   // an ellipse or a polygon, not both
          if (m) Object.assign(m, values);
        });
        refresh();
      } catch (error) { N.showError(error, "Could not change it"); }
    }
    function saveMap() {
      const out = document.createElement("canvas");
      out.width = canvas.width * 2;
      out.height = canvas.height * 2;
      const ctx = out.getContext("2d");
      ctx.fillStyle = "white";
      ctx.fillRect(0, 0, out.width, out.height);
      ctx.drawImage(canvas, 0, 0, out.width, out.height);
      const name = `fov_map${state.subject ? "_" + keyText(state.subject).replace(/[^\w.-]+/g, "_") : ""}.png`;
      const link = h("a", { href: out.toDataURL("image/png"), download: name });
      document.body.appendChild(link);
      link.click();
      link.remove();
      N.toast("Map saved", name, "success", 2500);
    }

    function saveSvg() {
      const ctx = svgContext(canvas.width, canvas.height);
      draw(ctx);
      const name = `fov_map${state.subject ? "_" + keyText(state.subject).replace(/[^\w.-]+/g, "_") : ""}.svg`;
      const link = h("a", { href: URL.createObjectURL(new Blob([ctx.svg()], { type: "image/svg+xml" })), download: name });
      document.body.appendChild(link);
      link.click();
      link.remove();
      N.toast("Map saved", name, "success", 2500);
    }

    canvas.addEventListener("mousemove", (event) => {
      const [ml, ap] = toMm(...pointer(event));
      where.textContent = `ML ${ml.toFixed(2)} mm, AP ${ap.toFixed(2)} mm` + (regionAt(atlas, ml, ap) ? ` · ${regionAt(atlas, ml, ap)}` : "");
      canvas.classList.toggle("over-mark", !state.placing && markAt(pointer(event)) !== null);
    });
    canvas.addEventListener("mousedown", (event) => {
      if (state.placing || event.button !== 0) return;
      const hit = markAt(pointer(event));
      if (!hit) return;
      drag = { kind: hit[0], mark: hit[1], from: pointer(event), at: pointer(event), moved: false };
      event.preventDefault();
    });
    const gone = () => {   // the page was left: stop listening
      if (document.body.contains(canvas)) return false;
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
      document.removeEventListener("keydown", onKey);
      return true;
    };
    const onKey = (event) => {
      const key = event.key.toLowerCase();
      if (gone() || !(event.ctrlKey || event.metaKey) || !["z", "c", "v"].includes(key) || document.querySelector(".dialog")) return;
      if (["INPUT", "SELECT", "TEXTAREA"].includes(event.target.tagName)) return;
      if (key === "c" && String(window.getSelection() || "")) return;   // text selected: copied as text
      event.preventDefault();
      if (key === "c") copy();
      else if (key === "v") paste();
      else if (event.shiftKey) step(future, history, "redo"); else step(history, future, "undo");
    };
    document.addEventListener("keydown", onKey);
    const onMove = (event) => {
      if (gone() || !drag) return;
      drag.at = pointer(event);
      if (Math.hypot(drag.at[0] - drag.from[0], drag.at[1] - drag.from[1]) > 3) drag.moved = true;
      canvas.classList.toggle("dragging", drag.moved);
      if (drag.moved) draw();
    };
    const onUp = async () => {
      const done = drag;
      if (gone() || !done) return;
      canvas.classList.remove("dragging");
      if (!done.moved) { drag = null; state.picked = { kind: done.kind, mark: done.mark }; edit(done.kind, done.mark); return; }
      const [ml, ap] = toMm(...done.at);
      try {
        await changeMarks((all) => { const m = all[done.kind].find((x) => x.id === done.mark.id); if (m) { m.ml = round2(ml); m.ap = round2(ap); } });
      } catch (error) { N.showError(error, "Could not move it"); }
      drag = null;
      refresh();
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
    canvas.addEventListener("click", async (event) => {
      if (!state.placing && markAt(pointer(event))) return;   // a mark: edited or moved on mouseup
      clickAt(pointer(event));
    });
    // The keyboard (WCAG 2.1.1): with the map focused, the arrow keys move a cursor (0.1 mm; Shift: 0.5 mm) and Enter or
    // Space does what a click there does: place what is being placed, select the FOV there, or edit the mark there (and
    // move it: its AP and ML)
    canvas.addEventListener("keydown", (event) => {
      const arrows = { ArrowUp: [0, 1], ArrowDown: [0, -1], ArrowLeft: [-1, 0], ArrowRight: [1, 0] };
      if (event.altKey || event.ctrlKey || event.metaKey) return;
      if (arrows[event.key]) {
        const step = event.shiftKey ? 0.5 : 0.1;
        const [ml, ap] = state.cursor || toMm(canvas.width / 2, canvas.height / 2);
        state.cursor = [round2(ml + arrows[event.key][0] * step), round2(ap + arrows[event.key][1] * step)];
        canvas.dataset.cursor = state.cursor.join(",");
        where.textContent = `ML ${state.cursor[0].toFixed(2)} mm, AP ${state.cursor[1].toFixed(2)} mm` +
          (regionAt(atlas, ...state.cursor) ? ` · ${regionAt(atlas, ...state.cursor)}` : "");
        draw();
      } else if ((event.key === "Enter" || event.key === " ") && state.cursor) {
        const at = toCanvas(...state.cursor);
        const hit = !state.placing && markAt(at);
        if (hit) { state.picked = { kind: hit[0], mark: hit[1] }; edit(hit[0], hit[1]); }
        else clickAt(at);
      } else return;
      event.preventDefault();
    });
    async function clickAt(point) {
      const [ml, ap] = toMm(...point);
      try {
        if (state.placing === "fov" && state.session) {
          await place(fovType.name, state.session, { fov_ml: round2(ml), fov_ap: round2(ap) }, (fovType.fragments || []).includes("ophys.fov_region"));
        } else if (state.placing === "window" && state.subject) {
          await place(windowType.name, state.subject, { window_ml: round2(ml), window_ap: round2(ap) }, false);
        } else if (state.placing === "injection" && state.subject) {
          const values = await markForm("injections");
          if (values === null) return;
          await changeMarks((all) => { all.injections.push({ id: nextId(all.injections), subject: state.subject, ml: round2(ml), ap: round2(ap), ...values }); });
        } else if (state.placing === "note") {
          const values = await markForm("notes");
          if (!values) return;
          await changeMarks((all) => { all.notes.push({ id: nextId(all.notes), subject: state.subject, ml: round2(ml), ap: round2(ap), ...values }); });
        } else {
          // select the FOV under the cursor
          const hit = shown().find((s) => {
            const w = (number(s.values.fov_width_um) || 500) / 2000, hh = (number(s.values.fov_height_um) || number(s.values.fov_width_um) || 500) / 2000;
            return number(s.values.fov_ml) !== null && Math.abs(ml - s.values.fov_ml) <= w && Math.abs(ap - s.values.fov_ap) <= hh;
          });
          if (hit) { state.session = hit.key; refresh(); }
          return;
        }
        setPlacing(null);
        await load();
        refresh();
      } catch (error) { N.showError(error, "Could not place it"); }
    }

    await load();
    await loadChoices();
    updateHistory();
    N.fill(el,
      h("div.hero", h("div", h("h1", "FOV map"),
        h("p", `Cranial windows (${windowType ? N.titleCase(windowType.name) : "no entity type has them"}) and fields of view (${N.titleCase(fovType.name)}) on ${atlas.name}, in mm from bregma.`))),
      h("div.fov-layout",
        h("div.card.fov-side", h("div.card-head", h("h2", windowType ? N.titleCase(windowType.name) : "Subjects")), subjectList),
        h("div.card.fov-map",
          h("div.fov-bar", placeFov, placeWindow, placeInjection, placeNote, addPhoto, setOutline, setHeadbar, h("div.spacer"), copyButton, pasteButton, undoButton, redoButton),
          h("div.fov-bar.fov-view-bar", h("label.fov-labels", labels, "Region labels"), h("label.fov-labels", fineGrid, "Fine grid"), h("label.fov-labels", imageToggle, "FOV images"), imagePick, opacityPick,
            h("label.fov-labels", { title: "Each FOV's ROIs in its place: accepted green, rejected red" }, roiToggle, "ROIs"),
            h("div.spacer"), importButton, exportButton, svgButton),
          canvas, where),
        h("div.fov-side-column",
          h("div.card.fov-side", h("div.card-head", h("h2", N.titleCase(fovType.name))), sessionList),
          h("div.card.fov-side", h("div.card-head", h("h2", "Injections, notes and images")), markList))));
    refresh();
  },
});
