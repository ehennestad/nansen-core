/* Reusable pieces: toasts, dialogs, the side drawer, popup menus. */
(function () {
  "use strict";
  const N = window.N;
  const { h } = N;

  N.toast = function (title, message = "", kind = "info", ms = 4500) {
    const box = document.getElementById("toasts");
    const el = h("div.toast." + kind,
      N.icon(kind === "error" ? "alert" : kind === "success" ? "check" : "dot", 18),
      h("div", h("div.t", title), message ? h("div.m", message) : null));
    box.appendChild(el);
    setTimeout(() => el.remove(), ms);
  };

  N.showError = function (error, title = "Something went wrong") {
    console.error(error);
    const code = error && error.code ? `[${error.code}] ` : "";
    N.toast(title, code + (error && error.message ? error.message : String(error)), "error", 7000);
  };

  /** Open a modal dialog. Returns {close, el}. content: Node; buttons: [{label, kind, onClick}] */
  N.dialog = function ({ title, content, buttons = [], narrow = false, onClose }) {
    const close = () => {
      backdrop.remove();
      document.removeEventListener("keydown", onKey);
      if (onClose) onClose();
    };
    const onKey = (event) => { if (event.key === "Escape") close(); };
    const foot = h("div.dialog-foot", h("div.spacer"),
      buttons.map((b) => h("button.btn" + (b.kind ? "." + b.kind : ""), {
        on: { click: () => b.onClick ? b.onClick(close) : close() }, disabled: b.disabled }, b.icon ? N.icon(b.icon) : null, b.label)));
    const dialog = h("div.dialog" + (narrow ? ".narrow" : ""),
      h("div.dialog-head", h("h2", title), h("div.spacer"),
        h("button.btn.ghost.icon", { on: { click: close }, title: "Close" }, N.icon("x"))),
      h("div.dialog-body", content),
      buttons.length ? foot : null);
    const backdrop = h("div.backdrop", { on: { mousedown: (e) => { if (e.target === backdrop) close(); } } }, dialog);
    document.body.appendChild(backdrop);
    document.addEventListener("keydown", onKey);
    return { close, el: dialog, foot };
  };

  /** The keyboard shortcuts, in a dialog. */
  N.showShortcuts = function () {
    const rows = [
      ["/", "Search the table"], ["?", "These shortcuts"], ["Esc", "Close the drawer or a dialog, or leave the search box"],
      ["g then o", "Overview"], ["g then 1…9", "The first, second, … entity table"], ["g then t", "Tasks"],
      ["g then d", "Data"], ["g then p", "Pipelines"], ["g then n", "Notes"], ["g then j", "Projects"], ["g then s", "Settings"],
      ["Shift + click", "Select a range of rows"],
      // the stack viewer's keys: imviewer's and roimanager's
      ["In the viewer"],
      ["← →", "A frame back or on (with Shift, 5 frames)"], ["z", "Zoom in"], ["Shift + Z", "Zoom out"], ["Shift + B", "Binning on or off"],
      ["a r q u", "Accept, reject, unresolved or clear the selected ROIs"], ["Delete", "Delete the selected ROIs"],
      ["m", "Merge the selected ROIs"], ["+ -", "Grow or shrink the selected ROI by a pixel"], ["i", "Improve the selected ROIs"],
      ["↑ ↓", "The ROI before or after (also j and k)"], ["Alt + arrows", "Move the selected ROI a pixel"],
      ["Shift + E", "Excitatory (Shift + I inhibitory, Shift + X axon)"], ["Shift + C", "Link the selected ROIs"], ["Shift + N", "The selected ROI's neuropil"],
      ["Ctrl + Z", "Undo (Ctrl + Shift + Z redo)"], ["Shift + drag", "Select the ROIs in a rectangle"], ["Esc", "Leave the drawing tool"],
    ];
    const keysOf = (keys) => (keys.includes(" ") && !["← →", "a r q u", "+ -", "↑ ↓"].includes(keys) ? keys.split(" ") : [keys])
      .map((k) => (["then", "+"].includes(k) ? h("span.muted", ` ${k} `) : h("kbd", k)));
    N.dialog({
      title: "Keyboard shortcuts", narrow: true,
      content: h("table.simple.shortcuts", h("tbody", rows.map(([keys, what]) => (what === undefined
        ? h("tr.shortcut-section", h("th", { colSpan: 2 }, keys))
        : h("tr", h("td", keysOf(keys)), h("td", what)))))),
    });
  };

  N.confirm = function (title, message, label = "Confirm", kind = "primary") {
    return new Promise((resolve) => {
      N.dialog({
        title, narrow: true,
        content: h("div", { style: { padding: "18px 20px" } }, message),
        // Resolve before closing: closing runs onClose, and a promise keeps the first value it gets
        buttons: [
          { label: "Cancel", onClick: (close) => { resolve(false); close(); } },
          { label, kind, onClick: (close) => { resolve(true); close(); } },
        ],
        onClose: () => resolve(false),
      });
    });
  };

  N.prompt = function (title, label, value = "") {
    return new Promise((resolve) => {
      const input = h("input.input", { value, style: { width: "100%" } });
      const d = N.dialog({
        title, narrow: true,
        content: h("div.field", { style: { padding: "18px 20px" } }, h("label.name", label), input),
        buttons: [
          { label: "Cancel", onClick: (close) => { resolve(null); close(); } },
          { label: "OK", kind: "primary", onClick: (close) => { resolve(input.value); close(); } },
        ],
        onClose: () => resolve(null),   // Escape or the close button
      });
      input.addEventListener("keydown", (e) => { if (e.key === "Enter") { resolve(input.value); d.close(); } });
      setTimeout(() => input.focus(), 0);
    });
  };

  /** Popup menu next to an anchor element. items: [{label, icon, onClick} | {heading} | {node}] */
  N.menu = function (anchor, items) {
    document.querySelectorAll(".menu").forEach((m) => m.remove());
    const menu = h("div.menu");
    for (const item of items) {
      if (item.heading) menu.appendChild(h("div.heading", item.heading));
      else if (item.node) menu.appendChild(item.node);
      else menu.appendChild(h("div.item", { on: { click: () => { if (!item.keepOpen) close(); item.onClick(); } } },
        item.icon ? N.icon(item.icon) : null, item.label));
    }
    document.body.appendChild(menu);
    const rect = anchor.getBoundingClientRect();
    const left = Math.min(rect.left, window.innerWidth - menu.offsetWidth - 8);
    menu.style.left = Math.max(8, left) + "px";
    menu.style.top = Math.min(rect.bottom + 4, window.innerHeight - menu.offsetHeight - 8) + "px";
    const close = () => { menu.remove(); document.removeEventListener("mousedown", outside, true); };
    const outside = (e) => { if (!menu.contains(e.target) && !anchor.contains(e.target)) close(); };
    setTimeout(() => document.addEventListener("mousedown", outside, true), 0);
    return { close, el: menu };
  };

  /** The side drawer: one at a time. */
  N.drawer = (function () {
    let el = null;
    return {
      open(title, subtitle, body, actions = []) {
        if (!el) {
          el = h("div.drawer");
          document.body.appendChild(el);
        }
        N.clear(el);
        el.appendChild(h("div.drawer-head",
          h("div", { style: { minWidth: 0 } }, subtitle ? h("div.muted", { style: { fontSize: "12px", marginBottom: "2px" } }, subtitle) : null, h("h2", title)),
          h("div.spacer"), actions,
          h("button.btn.ghost.icon", { on: { click: () => this.close() }, title: "Close" }, N.icon("x"))));
        el.appendChild(h("div.drawer-body", body));
        requestAnimationFrame(() => el.classList.add("open"));
      },
      close() { if (el) el.classList.remove("open"); },
      isOpen() { return !!el && el.classList.contains("open"); },
    };
  })();

  N.statusPill = function (status) {
    const kinds = { queued: "plain", running: "accent", completed: "good", failed: "bad", cancelled: "warn" };
    const pill = h("span.pill." + (kinds[status] || "plain"), status);
    if (status === "running") {
      pill.classList.add("plain");
      const spinner = N.icon("refresh", 12);
      spinner.classList.add("spin");
      pill.prepend(spinner);
    }
    return pill;
  };
})();
