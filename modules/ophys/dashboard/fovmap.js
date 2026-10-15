/* The ophys module's FOV map: cranial windows and fields of view on the mouse dorsal cortex, as dev's fovmanager.
 *
 * Run by the dashboard with N (its toolkit) and module (this module's id). Positions are columns of the
 * ophys.cranial_window, ophys.injection and ophys.fov_position fragments, so they are edited, filtered and exported like any
 * other column; this page draws them on the atlas and places them with a click.
 */
"use strict";
const { h } = N;
let atlasCache = null;

const SHAPES = {   // half sizes in mm: [half width (ML), half height (AP)], round or not
  "round 2.5 mm": [1.25, 1.25, true], "round 3 mm": [1.5, 1.5, true], "round 4 mm": [2, 2, true],
  "round 5 mm": [2.5, 2.5, true], "trapezoid 3 x 5 mm": [1.5, 2.5, false],
};

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
    .fov-list { list-style: none; margin: 0; padding: 6px; max-height: 70vh; overflow: auto; }
    .fov-list li { display: flex; align-items: center; gap: 8px; padding: 7px 9px; border-radius: 8px; cursor: pointer; font-size: 13px; }
    .fov-list li:hover { background: var(--surface-2); }
    .fov-list li.selected { background: var(--accent-soft); }
    .fov-list .grow { flex: 1; min-width: 0; }
    .fov-list .sub { font-size: 12px; }
    .fov-map { padding: 0; overflow: hidden; }
    .fov-bar { display: flex; align-items: center; gap: 8px; padding: 10px 12px; border-bottom: 1px solid var(--border); }
    .fov-bar .spacer { flex: 1; }
    .fov-bar .btn.active { background: var(--accent); color: white; border-color: var(--accent); }
    .fov-labels { display: inline-flex; align-items: center; gap: 6px; font-size: 13px; }
    .fov-canvas { display: block; width: 100%; max-width: 600px; margin: 12px auto; aspect-ratio: 3 / 4; cursor: crosshair; }
    .fov-canvas.placing { cursor: copy; }
    .fov-where { padding: 0 14px 12px; font-size: 12px; min-height: 18px; }
    @media (max-width: 1100px) { .fov-layout { grid-template-columns: 1fr; } }
  `;
  document.head.appendChild(style);
}

const keyText = (key) => Object.values(key).join(" / ");
const sameKey = (a, b) => Object.keys(a).every((k) => a[k] === b[k]);
const number = (v) => (typeof v === "number" && isFinite(v) ? v : null);

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
    const state = { subject: null, session: null, placing: null, labels: true, hover: null };
    let sessions = [];
    let subjects = [];

    async function load() {
      const [fovs, owners] = await Promise.all([
        app.client.request("entities.list", { entityType: fovType.name }),
        windowType ? app.client.request("entities.list", { entityType: windowType.name }) : Promise.resolve({ rows: [] })]);
      sessions = fovs.rows;
      subjects = owners.rows;
    }
    // A session belongs to the subject whose key values it carries
    const subjectOf = (session) => subjects.find((s) => Object.keys(s.key).every((k) => session.values[k] === s.key[k])) || null;
    const shown = () => sessions.filter((s) => !state.subject || (subjectOf(s) && sameKey(subjectOf(s).key, state.subject)));

    const canvas = h("canvas.fov-canvas", { width: 600, height: 800 });
    const where = h("div.fov-where.mono.muted", "");
    const subjectList = h("ul.fov-list");
    const sessionList = h("ul.fov-list");
    const placeFov = h("button.btn.small.place-fov", { on: { click: () => setPlacing("fov") } }, N.icon("plus", 13), "Place FOV");
    const placeWindow = h("button.btn.small.place-window", { on: { click: () => setPlacing("window") } }, N.icon("plus", 13), "Place window");
    const placeInjection = h("button.btn.small.place-injection", { on: { click: () => setPlacing("injection") } }, N.icon("plus", 13), "Place injection");
    const labels = h("input", { type: "checkbox", checked: true, on: { change: () => { state.labels = labels.checked; draw(); } } });

    const scale = () => canvas.width / (atlas.width / atlas.pixelsPerMm);   // px per mm
    const toCanvas = (ml, ap) => [(ml - atlas.origin[0]) * scale(), (atlas.origin[1] + atlas.height / atlas.pixelsPerMm - ap) * scale()];
    const toMm = (x, y) => [atlas.origin[0] + x / scale(), atlas.origin[1] + atlas.height / atlas.pixelsPerMm - y / scale()];

    function setPlacing(what) {
      state.placing = state.placing === what ? null : what;
      placeFov.classList.toggle("active", state.placing === "fov");
      placeWindow.classList.toggle("active", state.placing === "window");
      placeInjection.classList.toggle("active", state.placing === "injection");
      canvas.classList.toggle("placing", Boolean(state.placing));
    }

    function draw() {
      const ctx = canvas.getContext("2d");
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(atlasImage(atlas), 0, 0, canvas.width, canvas.height);
      ctx.font = "11px system-ui, sans-serif";
      ctx.textAlign = "center";
      if (state.labels) {
        ctx.fillStyle = "rgba(20, 24, 33, 0.7)";
        atlas.regions.forEach((r) => { const [x, y] = toCanvas(r.center[0], r.center[1]); ctx.fillText(r.label, x, y + 4); });
      }
      const [bx, by] = toCanvas(0, 0);   // bregma
      ctx.strokeStyle = "rgba(20, 24, 33, 0.8)";
      ctx.beginPath(); ctx.moveTo(bx - 6, by); ctx.lineTo(bx + 6, by); ctx.moveTo(bx, by - 6); ctx.lineTo(bx, by + 6); ctx.stroke();
      subjects.forEach((s) => {
        const ml = number(s.values.window_ml), ap = number(s.values.window_ap);
        if (ml === null || ap === null) return;
        const [hw, hh, round] = SHAPES[s.values.window_shape] || SHAPES["round 3 mm"];
        const selected = state.subject && sameKey(s.key, state.subject);
        const [x, y] = toCanvas(ml, ap);
        ctx.save();
        ctx.translate(x, y);
        ctx.rotate(-(number(s.values.window_rotation) || 0) * Math.PI / 180);
        ctx.lineWidth = selected ? 3 : 1.5;
        ctx.strokeStyle = selected ? "#3d5afe" : "rgba(20, 24, 33, 0.55)";
        ctx.setLineDash(selected ? [] : [5, 4]);
        ctx.beginPath();
        if (round) ctx.ellipse(0, 0, hw * scale(), hh * scale(), 0, 0, 2 * Math.PI);
        else { ctx.moveTo(-hw * 0.7 * scale(), -hh * scale()); ctx.lineTo(hw * 0.7 * scale(), -hh * scale()); ctx.lineTo(hw * scale(), hh * scale()); ctx.lineTo(-hw * scale(), hh * scale()); ctx.closePath(); }
        ctx.stroke();
        ctx.restore();
      });
      subjects.forEach((s) => {   // injection sites: a dot, and what was injected
        const ml = number(s.values.injection_ml), ap = number(s.values.injection_ap);
        if (ml === null || ap === null) return;
        const [x, y] = toCanvas(ml, ap);
        const selected = state.subject && sameKey(s.key, state.subject);
        ctx.fillStyle = selected ? "#d81b60" : "rgba(216, 27, 96, 0.6)";
        ctx.beginPath(); ctx.arc(x, y, selected ? 6 : 4.5, 0, 2 * Math.PI); ctx.fill();
        if (s.values.injection_material) { ctx.fillStyle = "#880e4f"; ctx.fillText(s.values.injection_material, x, y - 9); }
      });
      shown().forEach((s) => {
        const ml = number(s.values.fov_ml), ap = number(s.values.fov_ap);
        if (ml === null || ap === null) return;
        const w = (number(s.values.fov_width_um) || 500) / 1000 * scale(), hgt = (number(s.values.fov_height_um) || number(s.values.fov_width_um) || 500) / 1000 * scale();
        const [x, y] = toCanvas(ml, ap);
        const selected = state.session && sameKey(s.key, state.session);
        ctx.fillStyle = selected ? "rgba(61, 90, 254, 0.45)" : "rgba(255, 170, 0, 0.35)";
        ctx.strokeStyle = selected ? "#3d5afe" : "#b26a00";
        ctx.lineWidth = selected ? 2.5 : 1.5;
        ctx.setLineDash([]);
        ctx.fillRect(x - w / 2, y - hgt / 2, w, hgt);
        ctx.strokeRect(x - w / 2, y - hgt / 2, w, hgt);
      });
    }

    function renderLists() {
      N.fill(subjectList, h("li" + (!state.subject ? ".selected" : ""), { on: { click: () => { state.subject = null; refresh(); } } },
        h("span.grow", "All"), h("span.muted", String(sessions.length))),
      subjects.map((s) => h("li" + (state.subject && sameKey(s.key, state.subject) ? ".selected" : ""), { dataset: { subject: keyText(s.key) },
        on: { click: () => { state.subject = s.key; state.session = null; refresh(); } } },
        h("span.grow", keyText(s.key)),
        number(s.values.window_ml) === null ? h("span.muted", "no window") : h("span.pill.plain", s.values.window_shape || "window"))));
      N.fill(sessionList, shown().map((s) => {
        const placed = number(s.values.fov_ml) !== null && number(s.values.fov_ap) !== null;
        return h("li" + (state.session && sameKey(s.key, state.session) ? ".selected" : ""), { dataset: { session: keyText(s.key) },
          on: { click: () => { state.session = s.key; refresh(); } } },
          h("span.dot." + (placed ? "good" : "warn")),
          h("div.grow", h("div", keyText(s.key)), h("div.sub.muted", placed ? `${s.values.brain_region || "–"} · AP ${s.values.fov_ap}, ML ${s.values.fov_ml}` : "not placed")));
      }));
      placeFov.disabled = !state.session;
      placeWindow.disabled = !state.subject || !windowType;
      placeInjection.disabled = !state.subject || !windowType || !(windowType.fragments || []).includes("ophys.injection");
    }

    function refresh() { renderLists(); draw(); }

    canvas.addEventListener("mousemove", (event) => {
      const rect = canvas.getBoundingClientRect();
      const [ml, ap] = toMm((event.clientX - rect.left) / rect.width * canvas.width, (event.clientY - rect.top) / rect.height * canvas.height);
      where.textContent = `ML ${ml.toFixed(2)} mm, AP ${ap.toFixed(2)} mm` + (regionAt(atlas, ml, ap) ? ` · ${regionAt(atlas, ml, ap)}` : "");
    });
    canvas.addEventListener("click", async (event) => {
      const rect = canvas.getBoundingClientRect();
      const [ml, ap] = toMm((event.clientX - rect.left) / rect.width * canvas.width, (event.clientY - rect.top) / rect.height * canvas.height);
      const round2 = (v) => Math.round(v * 100) / 100;
      try {
        if (state.placing === "fov" && state.session) {
          await app.client.request("entities.update", { entityType: fovType.name, key: state.session, values: { fov_ml: round2(ml), fov_ap: round2(ap) } });
          if ((fovType.fragments || []).includes("ophys.fov_region")) {
            await app.client.request("fragments.update", { entityType: fovType.name, fragmentId: "ophys.fov_region", keys: [state.session] });
          }
        } else if (state.placing === "window" && state.subject) {
          await app.client.request("entities.update", { entityType: windowType.name, key: state.subject, values: { window_ml: round2(ml), window_ap: round2(ap) } });
        } else if (state.placing === "injection" && state.subject) {
          await app.client.request("entities.update", { entityType: windowType.name, key: state.subject, values: { injection_ml: round2(ml), injection_ap: round2(ap) } });
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
    });

    await load();
    N.fill(el,
      h("div.hero", h("div", h("h1", "FOV map"),
        h("p", `Cranial windows (${windowType ? N.titleCase(windowType.name) : "no entity type has them"}) and fields of view (${N.titleCase(fovType.name)}) on ${atlas.name}, in mm from bregma.`))),
      h("div.fov-layout",
        h("div.card.fov-side", h("div.card-head", h("h3", windowType ? N.titleCase(windowType.name) : "Subjects")), subjectList),
        h("div.card.fov-map",
          h("div.fov-bar", placeFov, placeWindow, placeInjection, h("div.spacer"), h("label.fov-labels", labels, "Region labels")),
          canvas, where),
        h("div.card.fov-side", h("div.card-head", h("h3", N.titleCase(fovType.name))), sessionList)));
    refresh();
  },
});
