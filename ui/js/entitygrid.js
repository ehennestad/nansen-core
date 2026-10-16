/* The entity table: virtual scrolling, sorting, search, status filters, selection, inline editing. */
(function () {
  "use strict";
  const N = window.N;
  const { h } = N;
  // A row's height: the stylesheet's --row, which the table text size setting changes
  const rowHeight = () => parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--row")) || 36;

  function statusOf(row) {
    if (row.inStore && row.inTable) return "both";
    return row.inStore ? "new" : "missing";
  }
  const STATUS_TITLE = { both: "In the stores and the table", new: "Found in the stores, not in the table yet", missing: "In the table, not found in the stores" };

  function store(key, value) {
    try {
      if (value === undefined) return JSON.parse(localStorage.getItem(key) || "null");
      localStorage.setItem(key, JSON.stringify(value));
    } catch (e) { return null; }
    return null;
  }

  /** Whether a row's value passes a filter ({column, op, ...} as in nansen.views). */
  function passes(value, filter) {
    const none = value === null || value === undefined || value === "";
    switch (filter.op) {
      case "in": return (filter.values || []).some((v) => (v === null ? none : v === value));
      case "range": return !none && (filter.min === undefined || filter.min === null || value >= filter.min) &&
        (filter.max === undefined || filter.max === null || value <= filter.max);
      case "is": return value === filter.value;
      case "contains": return !none && String(value).toLowerCase().includes(String(filter.text || "").toLowerCase());
      case "empty": return none;
      case "notEmpty": return !none;
      default: return true;
    }
  }
  N.filterPasses = passes;

  class EntityGrid {
    constructor({ onOpen, onEdit, onSelection, onColumnMenu, onAction }) {
      this.onOpen = onOpen;
      this.onAction = onAction;   // (row, column): a column's action, on double-click
      this.onColumnMenu = onColumnMenu;
      this.onEdit = onEdit;
      this.onSelection = onSelection;
      this.data = null;
      this.view = [];
      this.selected = new Set();
      this.sort = null;
      this.search = "";
      this.status = "all";
      this.hidden = new Set();
      this.hideIgnored = false;
      // editing is off in every table until unlocked: as this browser was left, else the user's default (tables.locked)
      const locked = store("nansen.locked");
      this.locked = locked === null ? Boolean(N.tableDefaults && N.tableDefaults.locked) : locked === true;
      this.filters = [];       // [{column, op, ...}]: every one must pass
      this.viewKeys = null;    // a Set of key ids when a view with keys is shown
      this.lastClicked = null;
      this.el = h("div.grid-wrap", { on: { scroll: () => this.renderBody() } });
      // A grid, as WAI-ARIA's grid pattern: one cell in the page's Tab order (the keyboard's), the arrows move between
      // cells, Enter or F2 edits one, Space selects its row (cellKey)
      this.table = h("table.grid-table", { role: "grid" });
      this.thead = h("thead");
      this.tbody = h("tbody");
      this.table.append(this.thead, this.tbody);
      this.el.appendChild(this.table);
      this.active = null;      // the keyboard's cell: {id, column}, the column "__sel" for the tick boxes
      this.tbody.addEventListener("keydown", (event) => this.cellKey(event));
      this.tbody.addEventListener("focusin", (event) => { const td = event.target.closest("td[data-col]"); if (td) this.activate(td); });
      new ResizeObserver(() => this.renderBody()).observe(this.el);
    }

    setData(data) {
      // A reload while a cell is being edited (a task finished, a scan) waits for the edit to end, so it is not lost
      if (this.editing && this.data && this.data.entityType === data.entityType) { this.pendingData = data; return; }
      this.pendingData = null;
      const sameType = this.data && this.data.entityType === data.entityType;
      // dev's Notebook column: how many notes each entity has, and of which kinds (sorted by how many)
      if (data.rows.some((r) => r.notes) && !data.columns.some((c) => c.source === "notes")) {
        data.columns = data.columns.concat([{ name: "__notes", dataType: "integer", title: "Notes", unit: null, source: "notes", editable: false }]);
        data.rows.forEach((r) => { r.values.__notes = r.notes ? r.notes.count : 0; });
      }
      this.data = data;
      this.byId = new Map(data.rows.map((r) => [N.keyId(r.key), r]));
      if (!sameType) {
        this.selected.clear();
        this.sort = null;
        this.hidden = new Set(store(`nansen.hidden.${data.entityType}`) || []);
        this.hideIgnored = store(`nansen.hideIgnored.${data.entityType}`) === true;
        this.order = store(`nansen.order.${data.entityType}`) || null;   // column names, as dragged; others after
        this.widths = store(`nansen.widths.${data.entityType}`) || {};  // column name -> pixels, as resized
      } else {
        for (const id of [...this.selected]) if (!this.byId.has(id)) this.selected.delete(id);
      }
      this.refresh();
      this.emitSelection();
    }

    get columns() {
      if (!this.data) return [];
      const shown = this.data.columns.filter((c) => !this.hidden.has(c.name));
      if (!this.order) return shown;
      const at = (c) => { const i = this.order.indexOf(c.name); return i < 0 ? this.order.length + shown.indexOf(c) : i; };
      return [...shown].sort((a, b) => at(a) - at(b));
    }

    /** Put a column before another (or last), keeping the order for this entity type. */
    moveColumn(name, before) {
      const names = this.columns.map((c) => c.name).filter((n) => n !== name);
      const at = before ? names.indexOf(before) : -1;
      names.splice(at < 0 ? names.length : at, 0, name);
      const hidden = (this.order || this.data.columns.map((c) => c.name)).filter((n) => this.hidden.has(n));
      this.order = names.concat(hidden);
      store(`nansen.order.${this.data.entityType}`, this.order);
      this.refresh();
    }

    setWidth(name, width) {
      if (width) this.widths[name] = Math.max(48, Math.round(width)); else delete this.widths[name];
      store(`nansen.widths.${this.data.entityType}`, this.widths);
      this.refresh();
    }

    /** A column a place to the left (-1) or right (1): dragging its header, from the keyboard (its menu). */
    moveColumnBy(name, by) {
      const names = this.columns.map((c) => c.name);
      const at = names.indexOf(name) + by;
      if (at < 0 || at >= names.length) return;
      this.moveColumn(name, by < 0 ? names[at] : names[at + 1] || null);
    }

    /** A column wider or narrower by some pixels: dragging its edge, from the keyboard (its menu). */
    sizeColumnBy(name, pixels) {
      const th = this.thead.querySelector(`th[data-column="${CSS.escape(name)}"]`);
      this.setWidth(name, (this.widths[name] || (th ? th.getBoundingClientRect().width : 120)) + pixels);
    }

    resetLayout() {
      this.order = null;
      this.widths = {};
      store(`nansen.order.${this.data.entityType}`, null);
      store(`nansen.widths.${this.data.entityType}`, {});
      this.refresh();
    }

    sizeStyle(name) {
      const w = this.widths[name];
      return w ? { width: w + "px", minWidth: w + "px", maxWidth: w + "px" } : null;
    }

    counts() {
      const counts = { all: 0, both: 0, new: 0, missing: 0 };
      for (const row of (this.data ? this.data.rows : [])) {
        counts.all++;
        counts[statusOf(row)]++;
      }
      return counts;
    }

    setSearch(text) { this.search = text.trim().toLowerCase(); this.refresh(); }
    setStatus(status) { this.status = status; this.refresh(); }
    setLocked(locked) {
      this.locked = locked;
      store("nansen.locked", locked);
      this.refresh();
    }

    setHideIgnored(hide) {
      this.hideIgnored = hide;
      store(`nansen.hideIgnored.${this.data.entityType}`, hide);
      this.refresh();
    }

    toggleColumn(name) {
      if (this.hidden.has(name)) this.hidden.delete(name); else this.hidden.add(name);
      store(`nansen.hidden.${this.data.entityType}`, [...this.hidden]);
      this.refresh();
    }

    refresh() {
      if (!this.data) return;
      let rows = this.data.rows;
      if (this.status !== "all") rows = rows.filter((r) => statusOf(r) === this.status);
      if (this.hideIgnored) rows = rows.filter((r) => r.values.ignore !== true);
      if (this.viewKeys) rows = rows.filter((r) => this.viewKeys.has(N.keyId(r.key)));
      for (const filter of this.filters) rows = rows.filter((r) => passes(r.values[filter.column], filter));
      if (this.search) {
        rows = rows.filter((r) => Object.values(r.values).some((v) => v !== null && v !== undefined && String(v).toLowerCase().includes(this.search)));
      }
      if (this.sort) {
        const { name, dir } = this.sort;
        rows = [...rows].sort((a, b) => {
          const x = a.values[name], y = b.values[name];
          if (x === y) return 0;
          if (x === null || x === undefined) return 1;
          if (y === null || y === undefined) return -1;
          return (x < y ? -1 : 1) * dir;
        });
      }
      this.view = rows;
      this.renderHead();
      this.renderBody(true);
    }

    renderHead() {
      const all = this.view.length > 0 && this.view.every((r) => this.selected.has(N.keyId(r.key)));
      const check = h("input", { type: "checkbox", checked: all, "aria-label": "Select all rows shown", on: { click: (e) => { e.stopPropagation(); this.selectAll(e.target.checked); } } });
      N.clear(this.thead).appendChild(h("tr",
        h("th.sel", check),
        h("th.status", ""),
        this.columns.map((c) => {
          const sorted = this.sort && this.sort.name === c.name;
          const th = h("th.src-" + c.source, {
            title: `${c.name} · ${c.dataType}${c.fragment ? " · " + c.fragment : ""}${c.source === "attribute" ? " · read from the stores" : ""} · drag to move, drag the edge to size`,
            draggable: "true", style: this.sizeStyle(c.name), dataset: { column: c.name },
            on: {
              click: () => { if (!this.resizing) this.toggleSort(c.name); },
              dragstart: (e) => { e.dataTransfer.setData("text/x-nansen-column", c.name); e.dataTransfer.effectAllowed = "move"; },
              dragover: (e) => { if ([...e.dataTransfer.types].includes("text/x-nansen-column")) { e.preventDefault(); th.classList.add("drop"); } },
              dragleave: () => th.classList.remove("drop"),
              drop: (e) => {
                e.preventDefault();
                th.classList.remove("drop");
                const moved = e.dataTransfer.getData("text/x-nansen-column");
                if (moved && moved !== c.name) this.moveColumn(moved, c.name);
              },
            },
          }, c.source === "table" && !c.editable ? h("span.fx", "fx") : null, c.title || c.name,
          c.unit ? h("span.unit", ` (${c.unit})`) : null,
          sorted ? h("span.sort", this.sort.dir > 0 ? "▲" : "▼") : null,
          this.onColumnMenu ? h("button.col-menu", { title: "Column menu", "aria-label": `Menu of ${c.title || c.name}`,
            on: { click: (e) => { e.stopPropagation(); this.onColumnMenu(c, e.currentTarget); } } }, "⋮") : null,
          h("span.col-resize", { title: "Drag to size; double-click to fit", on: {
            click: (e) => e.stopPropagation(),
            dblclick: (e) => { e.stopPropagation(); this.setWidth(c.name, null); },
            mousedown: (e) => {
              e.preventDefault();
              e.stopPropagation();
              const start = e.clientX;
              const from = th.getBoundingClientRect().width;
              this.resizing = true;
              const move = (m) => { const w = Math.max(48, from + m.clientX - start); Object.assign(th.style, { width: w + "px", minWidth: w + "px", maxWidth: w + "px" }); };
              const up = (m) => {
                document.removeEventListener("mousemove", move);
                document.removeEventListener("mouseup", up);
                this.setWidth(c.name, from + m.clientX - start);
                setTimeout(() => { this.resizing = false; }, 0);
              };
              document.addEventListener("mousemove", move);
              document.addEventListener("mouseup", up);
            },
          } }));
          return th;
        })));
    }

    setFilter(filter) {
      this.filters = this.filters.filter((f) => f.column !== filter.column).concat([filter]);
      this.refresh();
    }
    clearFilter(column) {
      this.filters = column ? this.filters.filter((f) => f.column !== column) : [];
      this.refresh();
    }
    /** Show a saved view: its rows (keys), filters, hidden columns and search; null shows everything. */
    applyView(view) {
      this.viewKeys = view && view.keys ? new Set(view.keys.map((k) => N.keyId(k))) : null;
      this.filters = view && view.filters ? view.filters.map((f) => Object.assign({}, f)) : [];
      if (view && view.hiddenColumns) this.hidden = new Set(view.hiddenColumns);
      else this.hidden = new Set(store(`nansen.hidden.${this.data.entityType}`) || []);
      if (view && view.columnOrder) this.order = [...view.columnOrder];
      else this.order = store(`nansen.order.${this.data.entityType}`) || null;
      if (view && view.columnWidths) this.widths = Object.assign({}, view.columnWidths);
      else this.widths = store(`nansen.widths.${this.data.entityType}`) || {};
      this.search = view && view.search ? view.search.toLowerCase() : "";
      this.refresh();
    }

    sortBy(name, dir) { this.sort = dir ? { name, dir } : null; this.refresh(); }

    toggleSort(name) {
      if (!this.sort || this.sort.name !== name) this.sort = { name, dir: 1 };
      else if (this.sort.dir === 1) this.sort.dir = -1;
      else this.sort = null;
      this.refresh();
    }

    renderBody(force = false) {
      if (!this.data) return;
      if (this.editing) return;   // the edit's own end renders the rows again
      const height = this.el.clientHeight || 600;
      const top = this.el.scrollTop;
      const ROW = rowHeight();
      const first = Math.max(0, Math.floor(top / ROW) - 10);
      const last = Math.min(this.view.length, Math.ceil((top + height) / ROW) + 10);
      if (!force && this.rendered && this.rendered[0] === first && this.rendered[1] === last) return;
      this.rendered = [first, last];
      const focused = this.tbody.contains(document.activeElement) || this.refocus;   // the keyboard stays on its cell
      this.refocus = false;
      const span = this.columns.length + 2;
      const rows = [];
      const spacer = (height) => h("tr", { "aria-hidden": "true" }, h("td", { colSpan: span, style: { height: height + "px", padding: 0, border: 0 } }));
      if (first > 0) rows.push(spacer(first * ROW));
      for (let i = first; i < last; i++) rows.push(this.renderRow(this.view[i], i));
      if (last < this.view.length) rows.push(spacer((this.view.length - last) * ROW));
      N.clear(this.tbody).append(...rows);
      this.table.setAttribute("aria-rowcount", String(this.view.length + 1));
      if (!this.view.length) {
        this.tbody.appendChild(h("tr", h("td", { colSpan: span, style: { height: "160px", textAlign: "center", color: "var(--text-3)" } },
          this.data.rows.length ? "No rows match the filter." : "No entities yet. Scan the stores, then sync.")));
      }
      this.rove(focused);
    }

    /** The cell of a row (by key id) and column drawn now, or null. */
    cellOf(id, column) {
      return this.tbody.querySelector(`tr[data-id="${CSS.escape(id)}"] > td[data-col="${CSS.escape(column)}"]`);
    }

    /** One cell of the rows drawn is in the page's Tab order: the keyboard's, or the first row's key when that is not
     *  drawn. With focus, the keyboard's cell takes the focus (it stays on its cell as the rows are drawn anew). */
    rove(focus = false) {
      const active = this.active && this.cellOf(this.active.id, this.active.column);
      const target = active || this.tbody.querySelector("tr[data-id] > td.key") || this.tbody.querySelector("td[data-col]");
      this.tbody.querySelectorAll("td[data-col]").forEach((td) => { td.tabIndex = td === target ? 0 : -1; });
      if (focus && active) active.focus({ preventScroll: true });
    }

    activate(td) {
      this.active = { id: td.parentElement.dataset.id, column: td.dataset.col };
      this.tbody.querySelectorAll("td[tabindex='0']").forEach((other) => { if (other !== td) other.tabIndex = -1; });
      td.tabIndex = 0;
    }

    /** Put the keyboard on a cell (a row of the view, a column), scrolling it into sight and drawing its row. */
    focusCell(index, column) {
      const row = this.view[index];
      if (!row) return;
      this.active = { id: N.keyId(row.key), column };
      const ROW = rowHeight();
      const room = this.el.clientHeight - this.thead.offsetHeight;
      if (index * ROW < this.el.scrollTop) this.el.scrollTop = index * ROW;
      else if ((index + 1) * ROW > this.el.scrollTop + room) this.el.scrollTop = (index + 1) * ROW - room;
      this.refocus = true;
      this.renderBody(true);
      const td = this.cellOf(this.active.id, column);
      if (!td) return;
      if (td.offsetLeft < this.el.scrollLeft) this.el.scrollLeft = td.offsetLeft;
      else if (td.offsetLeft + td.offsetWidth > this.el.scrollLeft + this.el.clientWidth) this.el.scrollLeft = td.offsetLeft + td.offsetWidth - this.el.clientWidth;
    }

    editable(row, column) { return Boolean(column && column.editable && row.inTable && !this.locked); }

    /** The keyboard on a cell (WCAG 2.1.1: what the pointer does, the keys do): the arrows, Home, End, Page Up and Page Down
     *  move (with Ctrl, Home and End go to the first and last row); Enter or F2 edits the cell, and Enter on a cell that
     *  cannot be edited runs its column's action, follows its link or opens the row's drawer; Space ticks a yes/no cell or
     *  selects the row (Shift + Space a range, as Shift + click). Editing: see edit. */
    cellKey(event) {
      const td = event.target.closest("td[data-col]");
      if (!td || this.editing || event.altKey || event.metaKey || (event.target !== td && event.target.type !== "checkbox")) return;
      const row = this.byId.get(td.parentElement.dataset.id);
      if (!row) return;
      const names = ["__sel"].concat(this.columns.map((c) => c.name));
      const column = this.columns.find((c) => c.name === td.dataset.col);
      const index = this.view.indexOf(row), at = names.indexOf(td.dataset.col);
      const page = Math.max(1, Math.floor((this.el.clientHeight - this.thead.offsetHeight) / rowHeight()) - 1);
      const go = (to, column) => this.focusCell(Math.max(0, Math.min(this.view.length - 1, to)), names[Math.max(0, Math.min(names.length - 1, column))]);
      const key = event.key;
      const tick = column && column.dataType === "boolean" && this.editable(row, column);
      if (key === "ArrowDown") go(index + 1, at);
      else if (key === "ArrowUp") go(index - 1, at);
      else if (key === "ArrowRight") go(index, at + 1);
      else if (key === "ArrowLeft") go(index, at - 1);
      else if (key === "PageDown") go(index + page, at);
      else if (key === "PageUp") go(index - page, at);
      else if (key === "Home") go(event.ctrlKey ? 0 : index, event.ctrlKey ? at : 0);
      else if (key === "End") go(event.ctrlKey ? this.view.length - 1 : index, event.ctrlKey ? at : names.length - 1);
      else if (event.ctrlKey) return;
      else if ((key === "Enter" || key === "F2") && this.editable(row, column) && !tick) this.edit(row, column, td);
      else if ((key === " " || key === "Enter") && tick) {
        this.refocus = true;
        this.commit(row, column, row.values[column.name] !== true, td);
      }
      else if (key === " ") this.toggleRow(row, event.shiftKey);
      else if (key === "Enter" && column && column.action && this.onAction) this.onAction(row, column);
      else if (key === "Enter" && td.querySelector("a[href]")) td.querySelector("a[href]").click();
      else if (key === "Enter") this.onOpen(row, { keyboard: true });
      else return;
      event.preventDefault();
    }

    renderRow(row, index) {
      const id = N.keyId(row.key);
      const status = statusOf(row);
      const tr = h("tr", { dataset: { id }, "aria-rowindex": String(index + 2), "aria-selected": String(this.selected.has(id)) });
      if (this.selected.has(id)) tr.classList.add("selected");
      if (row.values.ignore === true) tr.classList.add("ignored");
      tr.appendChild(h("td.sel", { dataset: { col: "__sel" } }, h("input", { type: "checkbox", checked: this.selected.has(id), tabindex: "-1",
        "aria-label": `Select ${N.fmt.key(row.key)}`, on: { click: (e) => { e.stopPropagation(); this.toggleRow(row, e.shiftKey); } } })));
      tr.appendChild(h("td.status", { title: STATUS_TITLE[status] }, h("span.status-mark." + status)));
      for (const column of this.columns) {
        const td = this.renderCell(row, column);
        td.dataset.col = column.name;
        td.querySelectorAll("input, a").forEach((control) => { control.tabIndex = -1; });   // the cell takes the keys
        tr.appendChild(td);
      }
      tr.addEventListener("click", (e) => {
        if (e.target.closest("td.editable") && row.inTable) return;
        this.onOpen(row);
      });
      return tr;
    }

    renderCell(row, column) {
      const value = row.values[column.name];
      const classes = ["td"];
      if (column.source === "key") classes.push("key");
      if (column.source === "attribute") classes.push("attribute");
      if (column.dataType === "number" || column.dataType === "integer") classes.push("num");
      const editable = column.editable && row.inTable && !this.locked;
      if (editable && column.dataType !== "boolean") classes.push("editable");
      const td = h(classes.join("."), { style: this.sizeStyle(column.name) });
      if (column.source === "notes") {
        const notes = row.notes;
        if (!notes) { td.classList.add("missing"); td.textContent = "—"; return td; }
        const kinds = [["important", "Important", "warn"], ["todo", "To do", "info"], ["question", "Question", "accent"]].filter(([k]) => notes[k]);
        td.title = `${notes.count} note${notes.count === 1 ? "" : "s"}` + kinds.map(([k, label]) => ` · ${notes[k]} ${label.toLowerCase()}`).join("");
        td.appendChild(h("span.notes-cell", `${notes.count} note${notes.count === 1 ? "" : "s"}`,
          kinds.map(([k, label, kind]) => h(`span.pill.${kind}.note-kind`, { title: label }, `${notes[k]} ${label.toLowerCase()}`))));
        return td;
      }
      if (column.source === "progress") {
        const state = row.progress;
        if (!state) { td.classList.add("missing"); td.textContent = "—"; return td; }
        td.title = `${state.title}: ${state.done} of ${state.total} steps done`;
        td.appendChild(h("div.progress-cell",
          h("div.progress-track", h("span" + (state.done === state.total ? ".done" : ""), { style: { width: `${(100 * state.done) / state.total}%` } })),
          h("span.progress-text", `${state.done}/${state.total}`)));
        return td;
      }
      if (column.dataType === "boolean") {
        const box = h("input", { type: "checkbox", checked: value === true, disabled: !editable, "aria-label": `${column.title || column.name} of ${N.fmt.key(row.key)}`,
          on: { click: (e) => { e.stopPropagation(); this.commit(row, column, e.target.checked, td); } } });
        td.appendChild(box);
        return td;
      }
      if (column.action && this.onAction) {
        td.classList.add("has-action");
        td.title = `Double-click to run ${column.action}`;
        td.addEventListener("dblclick", (e) => { e.stopPropagation(); this.onAction(row, column); });
      }
      const display = column.display && column.display.as;
      if (value === null || value === undefined || value === "") {
        td.classList.add("missing");
        td.textContent = "—";
      } else if (display === "progress" && typeof value === "number") {
        const fraction = Math.max(0, Math.min(1, value));
        td.title = `${Math.round(fraction * 100)}%`;
        td.appendChild(h("div.progress-cell", h("div.progress-track", h("span" + (fraction >= 1 ? ".done" : ""), { style: { width: `${fraction * 100}%` } })),
          h("span.progress-text", `${Math.round(fraction * 100)}%`)));
      } else if (display === "badge") {
        const color = (column.display.colors || {})[String(value)] || "plain";
        td.appendChild(h(`span.pill.${["good", "warn", "bad", "info", "accent", "plain"].includes(color) ? color : "plain"}`, String(value)));
      } else if (display === "link" && /^https?:\/\//i.test(String(value))) {
        td.appendChild(h("a", { href: String(value), target: "_blank", rel: "noopener noreferrer", on: { click: (e) => e.stopPropagation() } }, String(value)));
      } else if (column.dataType === "number" || column.dataType === "integer") {
        td.textContent = N.fmt.number(value);
      } else {
        td.textContent = String(value);
        td.title = String(value);
      }
      if (editable) td.addEventListener("click", (e) => { e.stopPropagation(); this.edit(row, column, td); });
      return td;
    }

    /** Edit a cell in place, after a click, or Enter or F2 on it. Enter saves and Escape cancels, the keyboard back on
     *  the cell; Tab and Shift + Tab save and go to the next or previous cell of the row; leaving the box saves. */
    edit(row, column, td) {
      if (td.classList.contains("editing")) return;
      const value = row.values[column.name];
      const type = { integer: "number", number: "number", date: "date" }[column.dataType] || "text";
      const label = `${column.title || column.name} of ${N.fmt.key(row.key)}`;
      const input = column.choices
        ? h("select", { "aria-label": label }, [h("option", { value: "" }, "—"), column.choices.map((c) => h("option", { value: c, selected: c === value }, c))])
        : h("input", { type, "aria-label": label, value: value === null || value === undefined ? "" : String(value) });
      // a choice picked with the pointer is saved at once; the arrow keys change it in place until Enter
      let keyed = false;
      if (column.choices) input.addEventListener("change", () => { if (!keyed) input.blur(); });
      if (column.dataType === "datetime") input.placeholder = "YYYY-MM-DDTHH:MM:SS";
      N.clear(td);
      td.classList.add("editing");
      this.editing = true;
      td.appendChild(input);
      input.focus();
      input.select && input.select();
      let finished = false;
      const finish = (save) => {
        if (finished) return;
        finished = true;
        this.editing = false;
        let next = input.value;
        if (next === "") next = null;
        else if (column.dataType === "integer" || column.dataType === "number") next = Number(next);
        if (!save || next === value || (next === null && (value === null || value === undefined))) { this.afterEdit(); return; }
        this.commit(row, column, next, td);
      };
      input.addEventListener("keydown", (e) => {
        e.stopPropagation();
        keyed = true;
        if (e.key === "Tab") {   // on to the next cell of the row (Shift: the previous)
          const names = ["__sel"].concat(this.columns.map((c) => c.name));
          const to = names[Math.max(0, Math.min(names.length - 1, names.indexOf(column.name) + (e.shiftKey ? -1 : 1)))];
          this.active = { id: N.keyId(row.key), column: to };
        }
        if (!["Enter", "Escape", "Tab"].includes(e.key)) return;
        e.preventDefault();
        this.refocus = true;
        finish(e.key !== "Escape");
      });
      input.addEventListener("blur", () => finish(true));
    }

    async commit(row, column, value, td) {
      const previous = row.values[column.name];
      row.values[column.name] = value;
      try {
        const updated = await this.onEdit(row, column, value);
        if (updated) Object.assign(row, updated);
        const pending = this.pendingData && this.pendingData.rows.find((r) => N.keyId(r.key) === N.keyId(row.key));
        if (pending) Object.assign(pending, updated || { values: { ...pending.values, [column.name]: value } });   // read before the edit
      } catch (error) {
        row.values[column.name] = previous;
        N.showError(error, `Could not save ${column.title || column.name}`);
      }
      this.afterEdit();
    }

    /** After an edit: the data a reload brought meanwhile, or the rows as they are. */
    afterEdit() {
      if (this.onEditEnd) { const next = this.onEditEnd; this.onEditEnd = null; this.pendingData = null; next(); return; }   // the page is drawn anew
      if (this.pendingData) this.setData(this.pendingData);
      else this.renderBody(true);
    }

    toggleRow(row, range) {
      const id = N.keyId(row.key);
      if (range && this.lastClicked !== null) {
        const a = this.view.findIndex((r) => N.keyId(r.key) === this.lastClicked);
        const b = this.view.indexOf(row);
        if (a >= 0 && b >= 0) {
          const on = !this.selected.has(id);
          for (let i = Math.min(a, b); i <= Math.max(a, b); i++) {
            const rid = N.keyId(this.view[i].key);
            if (on) this.selected.add(rid); else this.selected.delete(rid);
          }
        }
      } else if (this.selected.has(id)) this.selected.delete(id);
      else this.selected.add(id);
      this.lastClicked = id;
      this.renderHead();
      this.renderBody(true);
      this.emitSelection();
    }

    selectAll(on) {
      for (const row of this.view) {
        const id = N.keyId(row.key);
        if (on) this.selected.add(id); else this.selected.delete(id);
      }
      this.renderHead();
      this.renderBody(true);
      this.emitSelection();
    }

    clearSelection() { this.selectAll(false); this.selected.clear(); this.emitSelection(); this.renderBody(true); }

    selectedRows() {
      return [...this.selected].map((id) => this.byId.get(id)).filter(Boolean);
    }

    emitSelection() { if (this.onSelection) this.onSelection(this.selectedRows()); }
  }

  N.EntityGrid = EntityGrid;
  N.statusOf = statusOf;
})();
