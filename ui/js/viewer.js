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

  /** Decode a data.frame result onto a canvas of its own size, gray, with ROIs filled over it. */
  function paint(canvas, frame, rois, showRois) {
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
        const [r, g, b] = roiColor(n);
        roi.pixels.forEach(([y, x]) => {
          if (y < 0 || y >= frame.height || x < 0 || x >= frame.width) return;
          const i = 4 * (y * frame.width + x);
          image.data[i] = (image.data[i] + r) >> 1; image.data[i + 1] = (image.data[i + 1] + g) >> 1; image.data[i + 2] = (image.data[i + 2] + b) >> 1;
        });
      });
    }
    ctx.putImageData(image, 0, 0);
  }

  function roiColor(n) {
    const hue = (n * 137.508) % 360;
    const c = 0.9, x = c * (1 - Math.abs(((hue / 60) % 2) - 1));
    const [r, g, b] = hue < 60 ? [c, x, 0] : hue < 120 ? [x, c, 0] : hue < 180 ? [0, c, x] : hue < 240 ? [0, x, c] : hue < 300 ? [x, 0, c] : [c, 0, x];
    return [r, g, b].map((v) => Math.round(v * 255));
  }

  /**
   * Open the viewer on a variable of an entity. roiVariables are the entity's variables that hold ROIs.
   */
  N.views.stackViewer = function (app, entityType, key, variable, roiVariables = []) {
    const state = { frame: 0, frames: 1, mode: "frame", auto: true, low: 0, high: 1, rois: null, roiVariable: roiVariables[0] || "", showRois: roiVariables.length > 0, playing: false, busy: false, pending: false };
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

    canvas.addEventListener("mousemove", (event) => {
      if (!last) return;
      const rect = canvas.getBoundingClientRect();
      const x = Math.floor((event.clientX - rect.left) / rect.width * last.width);
      const y = Math.floor((event.clientY - rect.top) / rect.height * last.height);
      const roi = state.showRois && state.rois ? state.rois.find((r) => r.pixels.some(([py, px]) => py === y && px === x)) : null;
      where.textContent = `row ${y}, column ${x}` + (roi ? ` · ROI ${roi.id}` : "");
    });
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
        paint(canvas, frame, state.rois, state.showRois);
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
      h("div.viewer-stage", canvas),
      h("div.viewer-foot", status, h("div.spacer"), where));
    const dialog = N.dialog({ title: `${variable} · ${N.fmt.key(key)}`, content, onClose: () => { state.playing = false; } });
    dialog.el.classList.add("viewer-dialog");
    show();
    return dialog;
  };
})();
