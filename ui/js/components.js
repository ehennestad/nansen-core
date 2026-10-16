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
    // a body with nothing to focus (a table of shortcuts, a message) is focusable itself, so it scrolls from the keyboard
    const body = dialog.querySelector(".dialog-body");
    const reachable = () => { if (!focusables(body).length) body.tabIndex = 0; else body.removeAttribute("tabindex"); };
    reachable();
    requestAnimationFrame(reachable);
    dialog.focus({ preventScroll: true });   // the dialog itself: its keys (a viewer's) still work, and Tab goes to its first control
    return { close, el: dialog, foot };
  };

  /** The keyboard shortcuts, in a dialog. */
  N.showShortcuts = function () {
    const rows = [
      ["/", "Search the table"], ["?", "These shortcuts"], ["Esc", "Close the drawer or a dialog, or leave the search box"],
      ["g then o", "Overview"], ["g then 1…9", "The first, second, … entity table"], ["g then t", "Tasks"],
      ["g then d", "Data"], ["g then p", "Pipelines"], ["g then n", "Notes"], ["g then j", "Projects"], ["g then s", "Settings"],
      ["Shift + click", "Select a range of rows (Shift + Space)"], ["w", "Send the selected rows to the workspace"],
      // the table as a grid: every function of the pointer from the keyboard
      ["In a table"],
      ["arrows", "Move between cells (Home, End, Page Up, Page Down; Ctrl + Home the first row)"],
      ["Enter", "Edit the cell (also F2); on a cell that cannot be edited, open the row (or run its column's action)"],
      ["Esc", "While editing: leave the cell as it was; Enter or Tab saves (Tab goes on to the next cell)"],
      ["Space", "Select the row, or tick a yes/no cell"], ["⋮", "A column's menu: sort, filter, hide, move, wider or narrower"],
      ["In lists"], ["↑ ↓", "The ROIs, sessions and columns of a list: move and pick; Ctrl + Space adds to the selection"],
      // the stack viewer's keys: imviewer's and roimanager's
      ["In the viewer"],
      ["← →", "A frame back or on (with Shift, 5 frames); the wheel steps through the frames"],
      ["z", "Zoom in (also +); Shift + Z or - zoom out; Shift and the wheel zoom"], ["Shift + 1", "A quarter of the image (1 to 4); Shift + 0 all of it"],
      ["Alt + arrows", "Pan"], ["p", "Play or stop; ` slower, ~ faster"], ["n m b", "The mean, the maximum, Mean CLAHE"],
      ["Shift + N", "Moving average on or off (Shift + M moving maximum)"], ["c", "Brightness: the histogram and its limits"],
      ["Shift + P", "Thumbnails of the projections (Shift + F of the filters; a tab for the binnings)"],
      ["r", "Turn a quarter clockwise, with no ROI selected (Shift + R back; Alt + R a degree, as imviewer's Ctrl + R, which the browser keeps for reloading)"], ["0 1 2", "All channels in colour, or one channel"],
      ["1 2 3", "Accept, reject or unresolved the selected ROIs (0 clears; also a r q u)"], ["Delete", "Delete the selected ROIs"],
      ["arrows", "Move the selected ROIs a pixel (5 with Shift)"], ["g h", "Grow or shrink the selected ROI by a pixel"],
      ["m", "Merge the selected ROIs (two or more)"], ["i", "Improve the selected ROIs"], ["j k", "The ROI before or after"],
      ["Shift + E", "Excitatory (Shift + I inhibitory, Shift + X axon)"], ["Shift + C", "Link the selected ROIs"], ["Shift + O", "The selected ROI's neuropil"],
      ["1 … 5", "With the Detect tool: dev's detection mode"],
      ["Ctrl + Z", "Undo (Ctrl + Shift + Z redo)"], ["Shift + drag", "Select the ROIs in a rectangle (Ctrl + A: all of them)"],
      ["Shift + J", "Add the next ROI to the selection (Shift + K the one before)"],
      ["Tool + arrows", "With a tool on: move its cursor over the image (Shift: 5 pixels)"],
      ["Space", "With a tool on: a round or detected ROI, a corner, or an end of a measurement at the cursor; Enter closes an outline"],
      ["Esc", "Leave the drawing tool"],
      ["In a signal plot"], ["← →", "Move its cursor (Shift: a tenth); Enter goes to that frame"], ["+ - 0", "Zoom in, out, or show every frame"],
      ["On the FOV map"], ["arrows", "Move its cursor (Shift: 0.5 mm); Enter or Space places, selects or edits there"],
    ];
    const keysOf = (keys) => (keys.includes(" ") && !["← →", "n m b", "0 1 2", "1 2 3", "g h", "j k", "1 … 5", "↑ ↓", "+ - 0", "Tool + arrows"].includes(keys) ? keys.split(" ") : [keys])
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
      // Enter answers; prevented, so it does not also press the button the focus goes back to as the dialog closes
      input.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); resolve(input.value); d.close(); } });
      setTimeout(() => input.focus(), 0);
    });
  };

  /** Something clicked that is not a button (a card, an item of a list): the keyboard reaches it, and Enter or Space
   *  clicks it with Ctrl and Shift as they are held, so Ctrl + Space adds to a selection as Ctrl + click does (WCAG
   *  2.1.1). role says what it is to assistive technology (button, link, option); tabIndex -1 leaves it out of the Tab
   *  order, for a list whose items the keyboard moves between in another way. */
  N.clickable = function (el, role = "button", tabIndex = 0) {
    el.tabIndex = tabIndex;
    if (role) el.setAttribute("role", role);
    el.addEventListener("keydown", (event) => {
      if ((event.key !== "Enter" && event.key !== " ") || event.target !== el || event.altKey) return;
      event.preventDefault();
      event.stopPropagation();
      el.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, ctrlKey: event.ctrlKey, shiftKey: event.shiftKey, metaKey: event.metaKey }));
    });
    return el;
  };

  /** A list whose items are picked by a click (ROIs, sessions, data locations) as a listbox: call N.listbox(ul, label)
   *  once, and N.listbox.fill(ul, items) to draw its items, each N.option(li, selected). One item is
   *  in the Tab order (the selected one); the arrows, Home and End move between the items and pick the one they reach
   *  (with Ctrl they only move); Enter or Space picks the item, Ctrl + Space adds it to the selection (as Ctrl + click).
   *  The keyboard stays in the list as it is drawn anew. */
  N.listbox = function (ul, label, multiple = false, clickFocus = null) {
    ul.setAttribute("role", "listbox");
    ul.setAttribute("aria-label", label);
    if (multiple) ul.setAttribute("aria-multiselectable", "true");
    // with clickFocus (an element), a click picks an item and puts the focus there instead (where its keys work)
    if (clickFocus) {
      ul.addEventListener("mousedown", (event) => {
        if (!event.target.closest("[role=option]")) return;
        event.preventDefault();
        clickFocus.focus({ preventScroll: true });
      });
    }
    ul.addEventListener("keydown", (event) => {
      const items = [...ul.querySelectorAll("[role=option]")];
      const at = items.indexOf(event.target);
      const to = { ArrowDown: at + 1, ArrowUp: at - 1, Home: 0, End: items.length - 1 }[event.key];
      if (at < 0 || to === undefined || event.altKey) return;
      event.preventDefault();
      event.stopPropagation();
      if (to < 0 || to >= items.length) return;
      items.forEach((item) => { item.tabIndex = -1; });
      items[to].tabIndex = 0;
      items[to].focus();
      if (!event.ctrlKey && !event.metaKey) items[to].dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, shiftKey: event.shiftKey }));
    });
    return ul;
  };
  /** Draw a listbox's items anew (as N.fill), the keyboard staying in it: on the selected item, or the one it was on. */
  N.listbox.fill = function (ul, ...children) {
    const was = ul.contains(document.activeElement) ? [...ul.querySelectorAll("[role=option]")].indexOf(document.activeElement) : null;
    N.fill(ul, ...children);
    const items = [...ul.querySelectorAll("[role=option]")];
    const selected = items.filter((item) => item.getAttribute("aria-selected") === "true");
    const stop = (was !== null && selected.length !== 1 && items[was]) || selected[0] || items[0];
    items.forEach((item) => { item.tabIndex = item === stop ? 0 : -1; });
    if (stop && was !== null) stop.focus({ preventScroll: true });
    return ul;
  };
  N.option = function (li, selected) {
    N.clickable(li, "option", -1);
    li.setAttribute("aria-selected", String(Boolean(selected)));
    return li;
  };

  /** A box among a menu's items (a label.item with a checkbox: show a column, a group of ROIs) is a menu item that is
   *  checked or not (menuitemcheckbox): the item takes the focus and the keys, and is the only control (a box inside an
   *  item would be a control in a control), so the box is hidden, still ticked by a click on its label, and a mark drawn in
   *  its place shows it. Other nodes stay as they are. */
  function checkItem(node) {
    const box = node.matches("label.item") && node.querySelector("input[type=checkbox]");
    if (!box) return node;
    node.setAttribute("role", "menuitemcheckbox");
    node.tabIndex = -1;
    const mark = h("span.menu-check", { "aria-hidden": "true" });
    box.hidden = true;
    box.after(mark);
    const sync = () => { node.setAttribute("aria-checked", String(box.checked)); mark.classList.toggle("on", box.checked); };
    sync();
    box.addEventListener("change", sync);
    return node;
  }

  /** Popup menu next to an anchor element. items: [{label, icon, onClick, disabled?, title?} | {heading} | {node}]; a
   * disabled item is shown greyed (dev's menus' Enable off) and cannot be picked. */
  N.menu = function (anchor, items) {
    document.querySelectorAll(".menu").forEach((m) => m.remove());
    const menu = h("div.menu", { role: "menu" });
    for (const item of items) {
      if (item.heading) menu.appendChild(h("div.heading", item.heading));
      else if (item.node) menu.appendChild(checkItem(item.node));
      else if (item.disabled) menu.appendChild(h("div.item.disabled", { role: "menuitem", tabindex: "-1", "aria-disabled": "true", title: item.title || "" },
        item.icon ? N.icon(item.icon) : null, item.label));
      else menu.appendChild(h("div.item", { role: "menuitem", tabindex: "-1", title: item.title || null, on: { click: () => { if (!item.keepOpen) close(); item.onClick(); } } },
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
    const entries = () => [...menu.querySelectorAll(".item[role=menuitem], .item[role=menuitemcheckbox]")];
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
    let before = null;   // where the keyboard was when the drawer took the focus
    return {
      open(title, subtitle, body, actions = []) {
        if (!el) {
          // a panel beside the page, not modal: named by its title; hidden while closed (the stylesheet)
          el = h("div.drawer", { role: "dialog", "aria-modal": "false", "aria-labelledby": "drawer-title", tabindex: "-1" });
          document.body.appendChild(el);
        }
        N.clear(el);
        el.appendChild(h("div.drawer-head",
          h("div", { style: { minWidth: 0 } }, subtitle ? h("div.muted", { style: { fontSize: "12px", marginBottom: "2px" } }, subtitle) : null, h("h2#drawer-title", title)),
          h("div.spacer"), actions,
          h("button.btn.ghost.icon", { on: { click: () => this.close() }, title: "Close" }, N.icon("x"))));
        el.appendChild(h("div.drawer-body", body));
        requestAnimationFrame(() => el.classList.add("open"));
      },
      /** The keyboard into the drawer (opened from the keyboard); it goes back when the drawer closes. */
      focus() {
        if (!el) return;
        if (!el.contains(document.activeElement)) before = document.activeElement;
        el.classList.add("open");
        el.focus({ preventScroll: true });
      },
      close() {
        if (!el) return;
        const had = el.contains(document.activeElement);
        el.classList.remove("open");
        if (had && before && document.body.contains(before)) before.focus({ preventScroll: true });
        before = null;
      },
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
