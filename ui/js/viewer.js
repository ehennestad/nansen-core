/* The stack viewer: frames and projections of an image variable, with ROIs drawn over them (data.frame). */
(function () {
  "use strict";
  const N = window.N;
  const { h } = N;

  const IMAGE_TYPES = ["Image", "ImageStack"];
  const ARRAY_ADAPTERS = ["npy", "mat", "ophys.tiff_stack", "ophys.sciscan_raw"];

  /** Whether a data.status entry can be shown in the viewer. */
  N.isImageVariable = function (d) {
    if (!d.files || !d.files.length) return false;
    return d.dataType ? IMAGE_TYPES.includes(d.dataType) : ARRAY_ADAPTERS.includes(d.fileAdapter);
  };

  /** Decode a data.frame result onto a canvas of its own size, gray, with ROIs filled over it.
   * Rejected ROIs are dimmed (or left out with hideRejected); the selected ROI is drawn in full color. */
  function paint(canvas, frame, rois, showRois, selected = null, hideRejected = false) {
    canvas.width = frame.width;
    canvas.height = frame.height;
    const ctx = canvas.getContext("2d");
    const bytes = atob(frame.pixels);
    const image = ctx.createImageData(frame.width, frame.height);
    for (let i = 0; i < bytes.length; i++) {
      const v = bytes.charCodeAt(i);
      image.data[4 * i] = v; image.data[4 * i + 1] = v; image.data[4 * i + 2] = v; image.data[4 * i + 3] = 255;
    }
    if (showRois && rois) {
      rois.forEach((roi, n) => {
        const rejected = roi.classification === "rejected";
        if (rejected && hideRejected) return;
        const [r, g, b] = rejected ? [200, 60, 60] : roiColor(n);
        const share = roi.id === selected ? 1 : rejected ? 0.25 : 0.5;
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

  /**
   * Open the viewer on a variable of an entity. roiVariables are the entity's variables that hold ROIs.
   */
  N.views.stackViewer = function (app, entityType, key, variable, roiVariables = []) {
    const state = { frame: 0, frames: 1, mode: "frame", auto: true, low: 0, high: 1, rois: null, roiVariable: roiVariables[0] || "", showRois: roiVariables.length > 0,
      playing: false, busy: false, pending: false, selected: null, adding: false, radius: 3, hideRejected: false };
    const canvas = h("canvas.viewer-canvas");
    const slider = h("input.viewer-slider", { type: "range", min: 0, max: 0, value: 0, on: { input: () => { state.frame = Number(slider.value); show(); } } });
    const frameLabel = h("span.viewer-frame.mono", "");
    const playButton = h("button.btn.ghost.icon.small.viewer-play", { title: "Play", on: { click: () => toggle() } }, N.icon("play", 14));
    const mode = h("select.input.viewer-mode", { on: { change: () => { state.mode = mode.value; show(); } } },
      h("option", { value: "frame" }, "Frames"), h("option", { value: "mean" }, "Average"), h("option", { value: "max" }, "Maximum"));
    const low = h("input.input.viewer-low", { type: "number", step: "any", on: { change: () => { state.auto = false; auto.checked = false; state.low = Number(low.value); show(); } } });
    const high = h("input.input.viewer-high", { type: "number", step: "any", on: { change: () => { state.auto = false; auto.checked = false; state.high = Number(high.value); show(); } } });
    const auto = h("input", { type: "checkbox", checked: true, on: { change: () => { state.auto = auto.checked; show(); } } });
    const roiToggle = h("input.viewer-rois", { type: "checkbox", checked: state.showRois, on: { change: () => { state.showRois = roiToggle.checked; show(); } } });
    const roiPick = roiVariables.length > 1 ? h("select.input", { on: { change: () => { state.roiVariable = roiPick.value; state.rois = null; show(); } } },
      roiVariables.map((v) => h("option", { value: v }, v))) : null;
    const status = h("div.viewer-status.muted", "Loading…");
    const where = h("span.viewer-where.mono.muted", "");
    let last = null;

    const pixelAt = (event) => {
      const rect = canvas.getBoundingClientRect();
      return [Math.floor((event.clientY - rect.top) / rect.height * last.height), Math.floor((event.clientX - rect.left) / rect.width * last.width)];
    };
    const roiAt = (y, x) => state.showRois && state.rois ? state.rois.find((r) => !(state.hideRejected && r.classification === "rejected") &&
      r.pixels.some(([py, px]) => py === y && px === x)) : null;
    canvas.addEventListener("mousemove", (event) => {
      if (!last) return;
      const [y, x] = pixelAt(event);
      const roi = roiAt(y, x);
      where.textContent = `row ${y}, column ${x}` + (roi ? ` · ROI ${roi.id}` : "");
    });
    canvas.addEventListener("click", (event) => {
      if (!last || !state.rois) return;
      const [y, x] = pixelAt(event);
      if (state.adding) {
        const pixels = [];
        const r = state.radius;
        for (let dy = -r; dy <= r; dy++) for (let dx = -r; dx <= r; dx++) if (dy * dy + dx * dx <= r * r) pixels.push([y + dy, x + dx]);
        edit({ add: [{ pixels }] });
        return;
      }
      const roi = roiAt(y, x);
      select(roi ? roi.id : null);
    });

    // ROI curation: the list, its buttons and keys
    const roiList = h("ul.viewer-roi-list");
    const addButton = h("button.btn.small.viewer-add", { title: "Click on the image to add a round ROI", on: { click: () => {
      state.adding = !state.adding;
      addButton.classList.toggle("active", state.adding);
      canvas.classList.toggle("adding", state.adding);
    } } }, N.icon("plus", 13), "Add ROI");
    const radius = h("input.input.viewer-radius", { type: "number", min: 1, max: 50, value: state.radius, title: "Radius of an added ROI (px)",
      on: { change: () => { state.radius = Math.max(1, Math.round(Number(radius.value) || 1)); } } });
    const hide = h("input", { type: "checkbox", on: { change: () => { state.hideRejected = hide.checked; redraw(); renderList(); } } });
    const actions = [
      ["accept", "check", "Accept (a)", () => classify("accepted")],
      ["reject", "x", "Reject (r)", () => classify("rejected")],
      ["clear", "retry", "Clear (u)", () => classify(null)],
      ["delete", "trash", "Delete (Delete)", () => remove()],
    ].map(([name, icon, title, run]) => h(`button.btn.ghost.icon.small.roi-${name}`, { title, on: { click: run } }, N.icon(icon, 13)));
    const roiPanel = h("div.viewer-roi-panel",
      h("div.viewer-roi-actions", actions, h("div.spacer"), addButton, radius),
      h("label.viewer-hide", hide, "Hide rejected"),
      roiList);

    function renderList() {
      const rois = (state.rois || []).filter((r) => !(state.hideRejected && r.classification === "rejected"));
      N.fill(roiList, rois.map((roi) => h("li" + (roi.id === state.selected ? ".selected" : ""), { dataset: { roi: roi.id },
        on: { click: () => select(roi.id) } },
        h("span.swatch", { style: { background: roi.classification === "rejected" ? "rgb(200,60,60)" : `rgb(${roiColor(state.rois.indexOf(roi)).join(",")})` } }),
        h("span.grow", `ROI ${roi.id}`), h("span.muted", `${roi.pixels.length} px`),
        roi.classification ? h("span.pill." + (roi.classification === "accepted" ? "good" : "bad"), roi.classification) : null)));
      actions.forEach((b) => { b.disabled = state.selected === null; });
      roiPanel.style.display = state.rois && state.showRois ? "" : "none";
    }
    function redraw() { if (last) paint(canvas, last, state.rois, state.showRois, state.selected, state.hideRejected); }
    function select(id) {
      state.selected = id;
      redraw();
      renderList();
      const item = roiList.querySelector(`li[data-roi="${id}"]`);
      if (item) item.scrollIntoView({ block: "nearest" });
    }
    async function edit(change) {
      try {
        const result = await app.client.request("rois.update", { entityType, key, variable: state.roiVariable, ...change });
        state.rois = result.rois;
        if (result.added.length) state.selected = result.added[0];
        if (!state.rois.some((r) => r.id === state.selected)) state.selected = null;
        redraw();
        renderList();
      } catch (error) { N.showError(error, "Could not change the ROIs"); }
    }
    function classify(label) { if (state.selected !== null) edit({ classify: [{ id: state.selected, classification: label }] }); }
    function remove() { if (state.selected !== null) edit({ remove: [state.selected] }); }
    function onKey(event) {
      if (event.target.tagName === "INPUT" || event.target.tagName === "SELECT" || !state.rois) return;
      const order = state.rois.filter((r) => !(state.hideRejected && r.classification === "rejected")).map((r) => r.id);
      const at = order.indexOf(state.selected);
      if (event.key === "a") classify("accepted");
      else if (event.key === "r") classify("rejected");
      else if (event.key === "u") classify(null);
      else if (event.key === "Delete" || event.key === "Backspace") remove();
      else if (event.key === "ArrowDown" || event.key === "j") select(order[Math.min(order.length - 1, at + 1)] ?? null);
      else if (event.key === "ArrowUp" || event.key === "k") select(order[Math.max(0, at - 1)] ?? null);
      else return;
      event.preventDefault();
    }
    document.addEventListener("keydown", onKey);
    canvas.addEventListener("mouseleave", () => { where.textContent = ""; });

    async function show() {
      if (state.busy) { state.pending = true; return; }
      state.busy = true;
      const params = { entityType, key, variable };
      if (state.mode === "frame") params.frame = state.frame; else params.projection = state.mode;
      if (!state.auto) params.limits = [state.low, state.high];
      if (state.showRois && state.roiVariable && !state.rois) params.rois = state.roiVariable;
      try {
        const frame = await app.client.request("data.frame", params);
        if (frame.rois) state.rois = frame.rois;
        last = frame;
        state.frames = frame.frames;
        slider.max = String(Math.max(0, frame.frames - 1));
        slider.disabled = state.mode !== "frame" || frame.frames < 2;
        playButton.disabled = slider.disabled;
        if (state.auto) { state.low = frame.low; state.high = frame.high; low.value = String(frame.low); high.value = String(frame.high); }
        frameLabel.textContent = state.mode === "frame" ? `${state.frame + 1} / ${frame.frames}` : `${frame.frames} frames`;
        paint(canvas, frame, state.rois, state.showRois, state.selected, state.hideRejected);
        renderList();
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

    const content = h("div.viewer",
      h("div.viewer-bar",
        playButton, slider, frameLabel, mode,
        h("label.viewer-contrast", auto, "Auto"), low, h("span.muted", "–"), high,
        roiVariables.length ? h("label.viewer-roi-toggle", roiToggle, "ROIs") : null, roiPick),
      h("div.viewer-main", h("div.viewer-stage", canvas), roiVariables.length ? roiPanel : null),
      h("div.viewer-foot", status, h("div.spacer"), where));
    const dialog = N.dialog({ title: `${variable} · ${N.fmt.key(key)}`, content, onClose: () => { state.playing = false; document.removeEventListener("keydown", onKey); } });
    dialog.el.classList.add("viewer-dialog");
    show();
    return dialog;
  };
})();
