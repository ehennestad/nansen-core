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

  // What the keyboard can reach in an element, in order
  const FOCUSABLE = "button:not([disabled]), [href], input:not([disabled]):not([type=hidden]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex='-1'])";
  const focusables = (el) => [...el.querySelectorAll(FOCUSABLE)].filter((e) => e.offsetParent !== null || e === document.activeElement);

  /** Open a modal dialog. Returns {close, el}. content: Node; buttons: [{label, kind, onClick}]
   *  The keyboard stays in it (Tab goes round), and goes back where it was when the dialog closes. */
  N.dialog = function ({ title, content, buttons = [], narrow = false, onClose }) {
    const before = document.activeElement;
    const close = () => {
      backdrop.remove();
      document.removeEventListener("keydown", onKey);
      if (before && before !== document.body && document.body.contains(before) && !document.querySelector(".backdrop")) before.focus({ preventScroll: true });
      if (onClose) onClose();
    };
    const onKey = (event) => { if (event.key === "Escape") close(); };
    const foot = h("div.dialog-foot", h("div.spacer"),
      buttons.map((b) => h("button.btn" + (b.kind ? "." + b.kind : ""), {
        on: { click: () => b.onClick ? b.onClick(close) : close() }, disabled: b.disabled }, b.icon ? N.icon(b.icon) : null, b.label)));
    const heading = h("h2", title);
    heading.id = "dialog-title-" + Math.random().toString(36).slice(2, 10);
    const dialog = h("div.dialog" + (narrow ? ".narrow" : ""), { tabindex: "-1" },
      h("div.dialog-head", heading, h("div.spacer"),
        h("button.btn.ghost.icon", { on: { click: close }, title: "Close" }, N.icon("x"))),
      h("div.dialog-body", content),
      buttons.length ? foot : null);
    dialog.setAttribute("role", "dialog");
    dialog.setAttribute("aria-modal", "true");
    dialog.setAttribute("aria-labelledby", heading.id);
    const backdrop = h("div.backdrop", { on: { mousedown: (e) => { if (e.target === backdrop) close(); },
      keydown: (event) => {   // Tab and Shift+Tab go round the dialog's controls
        if (event.key !== "Tab") return;
        const items = focusables(dialog);
        if (!items.length) { event.preventDefault(); return; }
        const at = items.indexOf(document.activeElement);
        if (event.shiftKey && at <= 0) { event.preventDefault(); items[items.length - 1].focus(); }
        else if (!event.shiftKey && (at === -1 || at === items.length - 1)) { event.preventDefault(); items[0].focus(); }
      } } }, dialog);
    document.body.appendChild(backdrop);
    document.addEventListener("keydown", onKey);
    dialog.focus({ preventScroll: true });   // the dialog itself: its keys (a viewer's) still work, and Tab goes to its first control
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
      ["← →", "A frame back or on (with Shift, 5 frames); the wheel steps through the frames"],
      ["z", "Zoom in (also +); Shift + Z or - zoom out; Shift and the wheel zoom"], ["Shift + 1", "A quarter of the image (1 to 4); Shift + 0 all of it"],
      ["Alt + arrows", "Pan"], ["p", "Play or stop; ` slower, ~ faster"], ["n m b", "The mean, the maximum, Mean CLAHE"],
      ["Shift + N", "Moving average on or off (Shift + M moving maximum)"], ["c", "Brightness: the histogram and its limits"],
      ["r", "Turn a quarter clockwise, with no ROI selected (Shift + R back; Alt for a degree)"], ["0 1 2", "All channels in colour, or one channel"],
      ["1 2 3", "Accept, reject or unresolved the selected ROIs (0 clears; also a r q u)"], ["Delete", "Delete the selected ROIs"],
      ["arrows", "Move the selected ROIs a pixel (5 with Shift)"], ["g h", "Grow or shrink the selected ROI by a pixel"],
      ["m", "Merge the selected ROIs (two or more)"], ["i", "Improve the selected ROIs"], ["j k", "The ROI before or after"],
      ["Shift + E", "Excitatory (Shift + I inhibitory, Shift + X axon)"], ["Shift + C", "Link the selected ROIs"], ["Shift + O", "The selected ROI's neuropil"],
      ["1 … 5", "With the Detect tool: dev's detection mode"],
      ["Ctrl + Z", "Undo (Ctrl + Shift + Z redo)"], ["Shift + drag", "Select the ROIs in a rectangle"], ["Esc", "Leave the drawing tool"],
    ];
    const keysOf = (keys) => (keys.includes(" ") && !["← →", "n m b", "0 1 2", "1 2 3", "g h", "j k", "1 … 5"].includes(keys) ? keys.split(" ") : [keys])
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
    const menu = h("div.menu", { role: "menu" });
    for (const item of items) {
      if (item.heading) menu.appendChild(h("div.heading", item.heading));
      else if (item.node) menu.appendChild(item.node);
      else menu.appendChild(h("div.item", { role: "menuitem", tabindex: "-1", on: { click: () => { if (!item.keepOpen) close(); item.onClick(); } } },
        item.icon ? N.icon(item.icon) : null, item.label));
    }
    document.body.appendChild(menu);
    const rect = anchor.getBoundingClientRect();
    const left = Math.min(rect.left, window.innerWidth - menu.offsetWidth - 8);
    menu.style.left = Math.max(8, left) + "px";
    menu.style.top = Math.min(rect.bottom + 4, window.innerHeight - menu.offsetHeight - 8) + "px";
    const close = (refocus = true) => {
      const had = menu.contains(document.activeElement);
      menu.remove();
      document.removeEventListener("mousedown", outside, true);
      window.removeEventListener("keydown", onKey, true);
      if (refocus && had && document.body.contains(anchor)) anchor.focus({ preventScroll: true });
    };
    const outside = (e) => { if (!menu.contains(e.target) && !anchor.contains(e.target)) close(false); };
    // The keyboard: arrows move between the items, Enter or Space picks one, Escape and Tab close the menu. Taken
    // before the page's own keys (a viewer's arrows), and Escape closes only the menu, not a dialog under it.
    const entries = () => [...menu.querySelectorAll(".item[role=menuitem], .item input")];   // items, and the boxes of items that are
    const onKey = (event) => {
      if (!document.body.contains(menu)) { window.removeEventListener("keydown", onKey, true); return; }
      const list = entries();
      const at = list.indexOf(document.activeElement);
      const inside = at >= 0;
      const move = (to) => { if (list.length) list[(to + list.length) % list.length].focus(); };
      if (event.key === "Escape") close();
      else if (event.key === "Tab") { close(); return; }
      else if (event.key === "ArrowDown") move(inside ? at + 1 : 0);
      else if (event.key === "ArrowUp") move(inside ? at - 1 : list.length - 1);
      else if (event.key === "Home" && inside) move(0);
      else if (event.key === "End" && inside) move(list.length - 1);
      else if ((event.key === "Enter" || event.key === " ") && inside) list[at].click();
      else return;
      event.preventDefault();
      event.stopImmediatePropagation();
    };
    window.addEventListener("keydown", onKey, true);
    setTimeout(() => document.addEventListener("mousedown", outside, true), 0);
    const first = entries()[0];
    if (first) first.focus({ preventScroll: true });
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
