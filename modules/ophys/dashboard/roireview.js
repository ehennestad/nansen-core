/* The ophys module's ROI review: one ROI across sessions, side by side, classified in all of them at once.
 *
 * As dev's classifyMultiSessionRois (with roiclassifier): ophys.align_sessions copies a reference session's
 * ROIs to the others with the same ids, and this page shows each id's crop of every session's FOV image,
 * so an ROI that drifted or vanished is rejected everywhere with one key. A double-click on a crop opens that session
 * in the viewer with the ROI selected, to move, reshape or redraw it there (dev's multi-session editRois).
 */
"use strict";
const { h } = N;

if (!document.getElementById("ophys-roireview-style")) {
  const style = document.createElement("style");
  style.id = "ophys-roireview-style";
  style.textContent = `
    .rr-bar { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; margin-bottom: 14px; }
    .rr-bar label { display: inline-flex; align-items: center; gap: 6px; font-size: 13px; }
    .rr-table { border-collapse: separate; border-spacing: 0; }
    .rr-table th { font-size: 12px; font-weight: 600; color: var(--muted); padding: 6px 8px; text-align: center; position: sticky; top: 0; background: var(--surface); }
    .rr-table td { padding: 4px 6px; text-align: center; border-top: 1px solid var(--border); }
    .rr-table tr.selected td { background: var(--accent-soft); }
    .rr-table tr { cursor: pointer; }
    .rr-table td.rr-id { text-align: left; font-size: 13px; white-space: nowrap; }
    .rr-crop { width: 64px; height: 64px; image-rendering: pixelated; border-radius: 6px; display: block; margin: auto; }
    .rr-missing { width: 64px; height: 64px; border-radius: 6px; border: 1px dashed var(--border); display: grid; place-items: center; font-size: 11px; color: var(--muted); margin: auto; }
    .rr-wrap { overflow: auto; max-height: 70vh; }
  `;
  document.head.appendChild(style);
}

const keyText = (key) => Object.values(key).join(" / ");
const COLORS = { accepted: [60, 180, 90], rejected: [220, 70, 70] };

/** A crop of a session's image around an ROI, with the ROI's pixels outlined. */
function crop(frame, roi, half) {
  const canvas = document.createElement("canvas");
  canvas.className = "rr-crop";
  const size = 2 * half + 1;
  canvas.width = size;
  canvas.height = size;
  const ys = roi.pixels.map((p) => p[0]), xs = roi.pixels.map((p) => p[1]);
  const cy = Math.round((Math.min(...ys) + Math.max(...ys)) / 2), cx = Math.round((Math.min(...xs) + Math.max(...xs)) / 2);
  const bytes = atob(frame.pixels);
  const ctx = canvas.getContext("2d");
  const image = ctx.createImageData(size, size);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const sy = cy - half + y, sx = cx - half + x;
      const v = sy >= 0 && sy < frame.height && sx >= 0 && sx < frame.width ? bytes.charCodeAt(sy * frame.width + sx) : 0;
      const i = 4 * (y * size + x);
      image.data[i] = v; image.data[i + 1] = v; image.data[i + 2] = v; image.data[i + 3] = 255;
    }
  }
  const inside = new Set(roi.pixels.map(([y, x]) => `${y},${x}`));
  const [r, g, b] = COLORS[roi.classification] || [255, 196, 0];
  roi.pixels.forEach(([y, x]) => {
    const edge = [[1, 0], [-1, 0], [0, 1], [0, -1]].some(([dy, dx]) => !inside.has(`${y + dy},${x + dx}`));
    const py = y - (cy - half), px = x - (cx - half);
    if (!edge || py < 0 || py >= size || px < 0 || px >= size) return;
    const i = 4 * (py * size + px);
    image.data[i] = r; image.data[i + 1] = g; image.data[i + 2] = b;
  });
  ctx.putImageData(image, 0, 0);
  return canvas;
}

N.registerPage({
  id: "ophys.roireview", title: "ROI review", icon: "layers",
  async render(app, el) {
    const variables = await app.client.request("dataVariables.list", {});
    const roiVariables = variables.filter((v) => v.dataType === "RoiArray");
    const imageVariables = variables.filter((v) => v.dataType === "Image" || v.dataType === "ImageStack");
    if (!roiVariables.length || !imageVariables.length) {
      N.fill(el, h("div.empty", h("h3", "No ROIs to review"),
        h("p.muted", "Run the tool Set up two-photon variables (ophys.setup_variables), detect ROIs in a session and copy them to others with Align sessions and copy ROIs (ophys.align_sessions).")));
      return;
    }
    const state = { roiVariable: roiVariables[0].name, imageVariable: (imageVariables.find((v) => v.name === "FovAverageProjection") || imageVariables[0]).name,
      sessions: [], selected: null };
    const pick = (list, value, onChange) => {
      const select = h("select.input", { on: { change: () => onChange(select.value) } }, list.map((v) => h("option", { value: v.name, selected: v.name === value }, v.name)));
      return select;
    };
    const status = h("span.muted", "");
    const table = h("div.rr-wrap");

    async function load() {
      status.textContent = "Loading…";
      const entityType = roiVariables.find((v) => v.name === state.roiVariable).entityType;
      const listing = await app.client.request("entities.list", { entityType });
      const sessions = [];
      for (const row of listing.rows) {
        try {
          const frame = await app.client.request("data.frame", { entityType, key: row.key, variable: state.imageVariable, projection: "mean", rois: state.roiVariable });
          sessions.push({ entityType, key: row.key, frame, rois: frame.rois });
        } catch (error) { /* this session has no image or ROIs yet */ }
      }
      state.sessions = sessions;
      draw();
    }

    function ids() {
      const all = new Set();
      state.sessions.forEach((s) => s.rois.forEach((r) => all.add(r.id)));
      return [...all].sort((a, b) => a - b);
    }

    function draw() {
      const list = ids();
      const everywhere = list.filter((id) => state.sessions.every((s) => s.rois.some((r) => r.id === id))).length;
      status.textContent = `${list.length} ROIs in ${state.sessions.length} sessions; ${everywhere} in all of them`;
      N.fill(table, state.sessions.length ? h("table.rr-table",
        h("thead", h("tr", h("th", "ROI"), state.sessions.map((s) => h("th", keyText(s.key))))),
        h("tbody", list.map((id) => h("tr" + (id === state.selected ? ".selected" : ""), { dataset: { roi: id }, on: { click: () => select(id) } },
          h("td.rr-id", `ROI ${id}`, classificationOf(id) ? [" ", h("span.pill." + ({ accepted: "good", rejected: "bad" }[classificationOf(id)] || "warn"), classificationOf(id))] : null),
          state.sessions.map((s) => {
            const roi = s.rois.find((r) => r.id === id);
            // a double-click edits the ROI in that session's viewer (dev's multi-session editRois); the review reads
            // the sessions again when the viewer closes
            return h("td", { title: roi ? "Double-click to edit it in this session" : "", on: { dblclick: () => editIn(s, id) } },
              roi ? crop(s.frame, roi, 8) : h("div.rr-missing", "none"));
          })))))
        : h("div.empty", h("p.muted", "No session has both variables yet.")));
    }

    function editIn(session, id) {
      N.views.stackViewer(app, session.entityType, session.key, state.imageVariable, [state.roiVariable], [],
        { select: id, mode: "mean", onClose: () => load() });
    }

    // An ROI's classification: the one all sessions agree on, or none
    function classificationOf(id) {
      const labels = state.sessions.map((s) => (s.rois.find((r) => r.id === id) || {}).classification).filter((c) => c !== undefined);
      return labels.length && labels.every((c) => c === labels[0]) ? labels[0] : null;
    }

    function select(id) {
      state.selected = id;
      table.querySelectorAll("tr.selected").forEach((tr) => tr.classList.remove("selected"));
      const row = table.querySelector(`tr[data-roi="${id}"]`);
      if (row) { row.classList.add("selected"); row.scrollIntoView({ block: "nearest" }); }
    }

    async function classify(label) {
      if (state.selected === null) return;
      try {
        for (const s of state.sessions) {
          if (!s.rois.some((r) => r.id === state.selected)) continue;
          const result = await app.client.request("rois.update", { entityType: s.entityType, key: s.key, variable: state.roiVariable,
            classify: [{ id: state.selected, classification: label }] });
          s.rois = result.rois;
        }
        const keep = state.selected;
        draw();
        select(keep);
      } catch (error) { N.showError(error, "Could not classify the ROI"); }
    }

    const onKey = (event) => {
      if (!document.body.contains(table)) { document.removeEventListener("keydown", onKey); return; }
      if (["INPUT", "SELECT", "TEXTAREA"].includes(event.target.tagName) || document.querySelector(".backdrop")) return;
      const list = ids();
      const at = list.indexOf(state.selected);
      if (event.key === "a") classify("accepted");
      else if (event.key === "r") classify("rejected");
      else if (event.key === "q") classify("unresolved");
      else if (event.key === "u") classify(null);
      else if (event.key === "ArrowDown" || event.key === "j") select(list[Math.min(list.length - 1, at + 1)]);
      else if (event.key === "ArrowUp" || event.key === "k") select(list[Math.max(0, at - 1)]);
      else return;
      event.preventDefault();
    };
    document.addEventListener("keydown", onKey);

    N.fill(el,
      h("div.hero", h("div", h("h1", "ROI review"),
        h("p", "Each ROI in every session that has it, cropped from the session's FOV image. Accept (a) or reject (r) an ROI in all sessions at once; u clears it, ↑ and ↓ move."))),
      h("div.card", { style: { padding: "14px" } },
        h("div.rr-bar",
          h("label", "ROIs", pick(roiVariables, state.roiVariable, (v) => { state.roiVariable = v; load(); })),
          h("label", "Image", pick(imageVariables, state.imageVariable, (v) => { state.imageVariable = v; load(); })),
          h("button.btn.small.rr-accept", { on: { click: () => classify("accepted") } }, N.icon("check", 13), "Accept"),
          h("button.btn.small.rr-reject", { on: { click: () => classify("rejected") } }, N.icon("x", 13), "Reject"),
          h("div", { style: { flex: 1 } }), status),
        table));
    await load();
  },
});
