/* The entity table: virtual scrolling, sorting, search, status filters, selection, inline editing. */
(function () {
  "use strict";
  const N = window.N;
  const { h } = N;
  const ROW = 36;

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

  class EntityGrid {
    constructor({ onOpen, onEdit, onSelection }) {
      this.onOpen = onOpen;
      this.onEdit = onEdit;
      this.onSelection = onSelection;
      this.data = null;
      this.view = [];
      this.selected = new Set();
      this.sort = null;
      this.search = "";
      this.status = "all";
      this.hidden = new Set();
      this.lastClicked = null;
      this.el = h("div.grid-wrap", { on: { scroll: () => this.renderBody() } });
      this.table = h("table.grid-table");
      this.thead = h("thead");
      this.tbody = h("tbody");
      this.table.append(this.thead, this.tbody);
      this.el.appendChild(this.table);
      new ResizeObserver(() => this.renderBody()).observe(this.el);
    }

    setData(data) {
      const sameType = this.data && this.data.entityType === data.entityType;
      this.data = data;
      this.byId = new Map(data.rows.map((r) => [N.keyId(r.key), r]));
      if (!sameType) {
        this.selected.clear();
        this.sort = null;
        this.hidden = new Set(store(`nansen.hidden.${data.entityType}`) || []);
      } else {
        for (const id of [...this.selected]) if (!this.byId.has(id)) this.selected.delete(id);
      }
      this.refresh();
      this.emitSelection();
    }

    get columns() {
      return this.data ? this.data.columns.filter((c) => !this.hidden.has(c.name)) : [];
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

    toggleColumn(name) {
      if (this.hidden.has(name)) this.hidden.delete(name); else this.hidden.add(name);
      store(`nansen.hidden.${this.data.entityType}`, [...this.hidden]);
      this.refresh();
    }

    refresh() {
      if (!this.data) return;
      let rows = this.data.rows;
      if (this.status !== "all") rows = rows.filter((r) => statusOf(r) === this.status);
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
      const check = h("input", { type: "checkbox", checked: all, on: { click: (e) => { e.stopPropagation(); this.selectAll(e.target.checked); } } });
      N.clear(this.thead).appendChild(h("tr",
        h("th.sel", check),
        h("th.status", ""),
        this.columns.map((c) => {
          const sorted = this.sort && this.sort.name === c.name;
          return h("th.src-" + c.source, {
            title: `${c.name} · ${c.dataType}${c.fragment ? " · " + c.fragment : ""}${c.source === "attribute" ? " · read from the stores" : ""}`,
            on: { click: () => this.toggleSort(c.name) },
          }, c.source === "table" && !c.editable ? h("span.fx", "fx") : null, c.title || c.name,
          c.unit ? h("span.unit", ` (${c.unit})`) : null,
          sorted ? h("span.sort", this.sort.dir > 0 ? "▲" : "▼") : null);
        })));
    }

    toggleSort(name) {
      if (!this.sort || this.sort.name !== name) this.sort = { name, dir: 1 };
      else if (this.sort.dir === 1) this.sort.dir = -1;
      else this.sort = null;
      this.refresh();
    }

    renderBody(force = false) {
      if (!this.data) return;
      const height = this.el.clientHeight || 600;
      const top = this.el.scrollTop;
      const first = Math.max(0, Math.floor(top / ROW) - 10);
      const last = Math.min(this.view.length, Math.ceil((top + height) / ROW) + 10);
      if (!force && this.rendered && this.rendered[0] === first && this.rendered[1] === last) return;
      this.rendered = [first, last];
      const span = this.columns.length + 2;
      const rows = [];
      if (first > 0) rows.push(h("tr", h("td", { colSpan: span, style: { height: first * ROW + "px", padding: 0, border: 0 } })));
      for (let i = first; i < last; i++) rows.push(this.renderRow(this.view[i]));
      if (last < this.view.length) rows.push(h("tr", h("td", { colSpan: span, style: { height: (this.view.length - last) * ROW + "px", padding: 0, border: 0 } })));
      N.clear(this.tbody).append(...rows);
      if (!this.view.length) {
        this.tbody.appendChild(h("tr", h("td", { colSpan: span, style: { height: "160px", textAlign: "center", color: "var(--text-3)" } },
          this.data.rows.length ? "No rows match the filter." : "No entities yet. Scan the stores, then sync.")));
      }
    }

    renderRow(row) {
      const id = N.keyId(row.key);
      const status = statusOf(row);
      const tr = h("tr", { dataset: { id } });
      if (this.selected.has(id)) tr.classList.add("selected");
      if (row.values.ignore === true) tr.classList.add("ignored");
      tr.appendChild(h("td.sel", h("input", { type: "checkbox", checked: this.selected.has(id),
        on: { click: (e) => { e.stopPropagation(); this.toggleRow(row, e.shiftKey); } } })));
      tr.appendChild(h("td.status", { title: STATUS_TITLE[status] }, h("span.status-mark." + status)));
      for (const column of this.columns) tr.appendChild(this.renderCell(row, column));
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
      const editable = column.editable && row.inTable;
      if (editable && column.dataType !== "boolean") classes.push("editable");
      const td = h(classes.join("."));
      if (column.dataType === "boolean") {
        const box = h("input", { type: "checkbox", checked: value === true, disabled: !editable,
          on: { click: (e) => { e.stopPropagation(); this.commit(row, column, e.target.checked, td); } } });
        td.appendChild(box);
        return td;
      }
      if (value === null || value === undefined || value === "") {
        td.classList.add("missing");
        td.textContent = "—";
      } else if (column.dataType === "number" || column.dataType === "integer") {
        td.textContent = N.fmt.number(value);
      } else {
        td.textContent = String(value);
        td.title = String(value);
      }
      if (editable) td.addEventListener("click", (e) => { e.stopPropagation(); this.edit(row, column, td); });
      return td;
    }

    edit(row, column, td) {
      if (td.classList.contains("editing")) return;
      const value = row.values[column.name];
      const type = { integer: "number", number: "number", date: "date" }[column.dataType] || "text";
      const input = h("input", { type, value: value === null || value === undefined ? "" : String(value) });
      if (column.dataType === "datetime") input.placeholder = "YYYY-MM-DDTHH:MM:SS";
      N.clear(td);
      td.classList.add("editing");
      td.appendChild(input);
      input.focus();
      input.select && input.select();
      let finished = false;
      const finish = (save) => {
        if (finished) return;
        finished = true;
        if (!save) { this.renderBody(true); return; }
        let next = input.value;
        if (next === "") next = null;
        else if (column.dataType === "integer" || column.dataType === "number") next = Number(next);
        if (next === value || (next === null && (value === null || value === undefined))) { this.renderBody(true); return; }
        this.commit(row, column, next, td);
      };
      input.addEventListener("keydown", (e) => {
        if (e.key === "Enter") finish(true);
        if (e.key === "Escape") finish(false);
        e.stopPropagation();
      });
      input.addEventListener("blur", () => finish(true));
    }

    async commit(row, column, value, td) {
      const previous = row.values[column.name];
      row.values[column.name] = value;
      try {
        const updated = await this.onEdit(row, column, value);
        if (updated) Object.assign(row, updated);
      } catch (error) {
        row.values[column.name] = previous;
        N.showError(error, `Could not save ${column.title || column.name}`);
      }
      this.renderBody(true);
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
