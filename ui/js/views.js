/* The pages: overview, an entity table, tasks, data, projects; and the run-method dialog. */
(function () {
  "use strict";
  const N = window.N;
  const { h } = N;

  /* ------------------------------------------------------------------ overview */
  N.views = {};

  N.views.overview = async function (app, content) {
    const project = app.project;
    const tasks = await app.client.request("tasks.list").catch(() => []);
    const counts = {};
    await Promise.all(project.entityTypes.map(async (type) => {
      const data = await app.client.request("entities.list", { entityType: type.name }).catch(() => null);
      if (!data) return;
      const c = { all: data.rows.length, both: 0, new: 0, missing: 0 };
      for (const row of data.rows) c[N.statusOf(row)]++;
      counts[type.name] = c;
    }));

    const stats = h("div.grid.stats", project.entityTypes.map((type) => {
      const c = counts[type.name] || { all: 0, both: 0, new: 0, missing: 0 };
      const pct = (n) => (c.all ? (100 * n) / c.all : 0) + "%";
      return h("div.card.stat", { on: { click: () => app.go(`#/entities/${type.name}`) } },
        h("div.label", type.title || type.name),
        h("div.value", c.all.toLocaleString()),
        h("div.stat-chips",
          h("span.pill.good", `${c.both} complete`),
          c.new ? h("span.pill.info", `${c.new} new`) : null,
          c.missing ? h("span.pill.warn", `${c.missing} not found`) : null),
        h("div.bar", h("span.b-both", { style: { width: pct(c.both) } }), h("span.b-new", { style: { width: pct(c.new) } }),
          h("span.b-missing", { style: { width: pct(c.missing) } })));
    }));

    const dataset = project.dataset;
    const roots = dataset ? h("ul.list", dataset.roots.map((root) => {
      const location = dataset.locations.find((l) => l.id === root.dataLocation) || { title: root.dataLocation };
      return h("li", h("span.dot." + (root.available ? "good" : "bad")),
        h("div.grow", h("div.title", location.title), h("div.sub.mono", root.path)),
        h("span.pill.plain", location.access === "readwrite" ? "read/write" : "read only"));
    })) : h("div.card-body.setup",
      h("p", "This project has no dataset yet. A dataset config (", h("span.mono", "dataset.dsm.json"),
        ") says where the data is and how subjects and sessions are named, so NANSEN can find them."),
      h("button.btn.primary", { on: { click: () => datasetDialog(app) } }, N.icon("plus"), "Set up the dataset"));

    const recent = tasks.slice(-6).reverse();
    const taskList = recent.length ? h("ul.list", recent.map((task) => h("li", { style: { cursor: "pointer" }, on: { click: () => app.go("#/tasks") } },
      N.statusPill(task.status),
      h("div.grow", h("div.title", app.methodTitle(task.method.id)),
        h("div.sub", `${task.entities.length} ${task.entities[0].entityType}(s) · ${N.fmt.ago(task.createdAt)}`))))) :
      h("div.card-body.muted", "No tasks yet. Select entities and run a method.");

    const modules = project.modules.length ? h("ul.list", project.modules.map((m) => h("li", N.icon("puzzle"),
      h("div.grow", h("div.title", m.title || m.id), h("div.sub", m.description || m.id)), h("span.pill.plain", "v" + m.version)))) :
      h("div.card-body.muted", "No modules.");

    N.fill(content, 
      h("div.hero",
        h("div", h("h1", project.title), project.description ? h("p", project.description) : null,
          h("div.path", project.folder, h("button.btn.ghost.icon.small", { title: "Show the project folder in the file browser",
            on: { click: () => app.client.request("files.reveal", { path: "" }).catch((error) => N.showError(error, "Could not open the folder")) } },
            N.icon("folder", 13)))),
        h("div.spacer"),
        h("div.actions",
          dataset ? h("button.btn", { on: { click: () => app.scan() } }, N.icon("scan"), "Scan stores") : null,
          dataset ? h("button.btn.primary", { on: { click: () => app.sync() } }, N.icon("sync"), "Sync tables") : null)),
      stats,
      h("div", { style: { height: "16px" } }),
      h("div.grid.two",
        h("div.card", h("div.card-head", N.icon("database"), h("h3", "Data locations"), h("div.spacer"),
          h("span.muted", dataset ? `Last scan ${N.fmt.ago(project.lastScan)}` : "")), roots),
        h("div.grid",
          h("div.card", h("div.card-head", N.icon("tasks"), h("h3", "Recent tasks"), h("div.spacer"),
            h("a", { href: "#/tasks" }, "All tasks")), taskList),
          h("div.card", h("div.card-head", N.icon("layers"), h("h3", "Modules")), modules))));
  };

  /* ------------------------------------------------------------------ entities */
  N.views.entities = async function (app, content, entityType) {
    const type = app.project.entityTypes.find((t) => t.name === entityType);
    if (!type) {
      N.clear(content).appendChild(h("div.empty", h("h3", `No entity type ${entityType}`)));
      return;
    }
    content.classList.add("flush");
    const grid = new N.EntityGrid({
      onOpen: (row) => N.views.entityDrawer(app, entityType, row.key),
      onEdit: (row, column, value) => app.client.request("entities.update",
        { entityType, key: row.key, values: { [column.name]: value } }),
      onSelection: (rows) => renderSelection(rows),
      onColumnMenu: (column, anchor) => columnMenu(column, anchor),
    });
    app.currentGrid = grid;

    const chips = h("div.chips");
    const renderChips = () => {
      const counts = grid.counts();
      N.fill(chips, ...[["all", "All"], ["both", "Complete"], ["new", "New"], ["missing", "Not found"]].map(([id, label]) =>
        h("button.chip" + (grid.status === id ? ".on" : ""), { on: { click: () => { grid.setStatus(id); renderChips(); } } },
          label, h("span.n", counts[id]))));
    };
    const search = h("input.input", { placeholder: `Search ${type.title || entityType}…`, on: { input: N.debounce((e) => grid.setSearch(e.target.value), 120) } });
    const columnsButton = h("button.btn", N.icon("columns"), "Columns");
    columnsButton.addEventListener("click", () => {
      const items = [{ heading: "Show columns" }].concat(grid.data.columns.map((c) => ({
        node: h("label.item", h("input", { type: "checkbox", checked: !grid.hidden.has(c.name),
          on: { change: () => grid.toggleColumn(c.name) } }), c.title || c.name, h("span.muted", { style: { marginLeft: "auto", fontSize: "11px" } }, c.source)),
      })));
      const available = (app.fragments || []).filter((f) => !type.fragments.includes(f.id) && !f.computed);
      items.push({ heading: "Add" }, { label: "Add a column…", icon: "plus", onClick: () => addColumnDialog(app, entityType) });
      for (const f of available) {
        items.push({ label: `${f.title} (${f.columns.map((c) => c.name).join(", ")})`, icon: "layers", onClick: async () => {
          try {
            await app.client.request("fragments.attach", { entityType, fragmentId: f.id });
            await app.reloadProject();
            app.render();
            N.toast("Columns added", f.title, "success");
          } catch (error) { N.showError(error, "Could not add the columns"); }
        } });
      }
      N.menu(columnsButton, items);
    });
    const hideIgnored = h("button.btn", { title: "Hide the rows marked as ignored", on: { click: () => {
      grid.setHideIgnored(!grid.hideIgnored);
      hideIgnored.classList.toggle("on", grid.hideIgnored);
    } } }, N.icon("eye-off"), "Hide ignored");
    const computed = (app.fragments || []).filter((f) => f.computed && type.fragments.includes(f.id));
    const toolbar = h("div.toolbar",
      h("div.search", N.icon("search", 14), search), chips, h("div.spacer"),
      computed.length ? h("button.btn", { on: { click: (e) => updateMenu(e.currentTarget) } }, N.icon("zap"), "Update") : null,
      type.fragments.includes("core.notes") ? hideIgnored : null,
      columnsButton,
      app.project.dataset ? h("button.btn", { on: { click: () => app.sync(entityType) } }, N.icon("sync"), "Sync") : null,
      h("button.btn.primary", { on: { click: () => N.views.methodDialog(app, entityType, grid.selectedRows()) } }, N.icon("play"), "Run method"));

    function columnMenu(column, anchor) {
      const items = [{ heading: column.title || column.name },
        { label: "Sort A → Z", icon: "sort-asc", onClick: () => grid.sortBy(column.name, 1) },
        { label: "Sort Z → A", icon: "sort-desc", onClick: () => grid.sortBy(column.name, -1) },
        { label: "Hide column", icon: "eye-off", onClick: () => grid.toggleColumn(column.name) }];
      if (column.source === "table") {
        const selected = grid.selectedRows().filter((r) => r.inTable);
        const reset = async (rows) => {
          const which = rows ? `${rows.length} selected row(s)` : "every row";
          if (!(await N.confirm("Reset the column?", `${column.title || column.name} goes back to its default in ${which}.`, "Reset", "danger"))) return;
          const params = { entityType, column: column.name };
          if (rows) params.keys = rows.map((r) => r.key);
          try {
            const result = await app.client.request("columns.reset", params);
            N.toast("Column reset", `${result.reset} row(s)`, "success");
            app.reloadEntities();
          } catch (error) { N.showError(error, "Could not reset the column"); }
        };
        items.push({ heading: "Values" });
        if (selected.length) items.push({ label: `Reset in ${selected.length} selected row(s)`, icon: "refresh", onClick: () => reset(selected) });
        items.push({ label: "Reset in every row", icon: "refresh", onClick: () => reset(null) });
        if (column.fragment) {
          const fragment = (app.fragments || []).find((f) => f.id === column.fragment) || { id: column.fragment, title: column.fragment, columns: [column] };
          const names = fragment.columns.map((c) => c.title || c.name).join(", ");
          items.push({ heading: "Columns" }, { label: `Remove ${fragment.title}…`, icon: "trash", onClick: async () => {
            const message = `The column(s) ${names} and every value in them are removed from the ${type.title || entityType} table. ` +
              "The fragment can be added again from the Columns menu, with its defaults.";
            if (!(await N.confirm(`Remove ${fragment.title}?`, message, "Remove", "danger"))) return;
            try {
              await app.client.request("fragments.detach", { entityType, fragmentId: fragment.id });
              await app.reloadProject();
              app.render();
              N.toast("Columns removed", fragment.title, "success");
            } catch (error) { N.showError(error, "Could not remove the columns"); }
          } });
        }
      }
      N.menu(anchor, items);
    }

    function updateMenu(anchor) {
      N.menu(anchor, [{ heading: "Recompute" }].concat(computed.map((f) => ({
        label: f.title, icon: "zap", onClick: async () => {
          const rows = grid.selectedRows();
          const params = { entityType, fragmentId: f.id };
          if (rows.length) params.keys = rows.map((r) => r.key);
          try {
            const result = await app.client.request("fragments.update", params);
            N.toast(`Updated ${f.title}`, `${result.updated} row(s)` + (result.failed.length ? `, ${result.failed.length} failed` : ""), result.failed.length ? "error" : "success");
          } catch (error) { N.showError(error); }
        },
      }))));
    }

    const footer = h("div.grid-foot");
    const selectionBar = h("div.selection-bar.hidden");
    function renderSelection(rows) {
      selectionBar.classList.toggle("hidden", rows.length === 0);
      N.fill(selectionBar, 
        h("span", `${rows.length} selected`),
        h("button.btn.small.primary", { on: { click: () => N.views.methodDialog(app, entityType, grid.selectedRows()) } }, N.icon("play", 14), "Run method"),
        h("button.btn.small", { title: "Copy the keys as tab-separated text", on: { click: () => {
          const selected = grid.selectedRows();
          const names = grid.data.key;
          const text = [names.join("\t"), ...selected.map((r) => names.map((n) => r.key[n]).join("\t"))].join("\n");
          N.copyText(text).then(() => N.toast("Copied", `${selected.length} key(s)`, "success"), (error) => N.showError(error, "Could not copy"));
        } } }, N.icon("copy", 14), "Copy keys"),
        h("button.btn.small", { on: { click: () => removeRows(grid.selectedRows()) } }, N.icon("trash", 14), "Remove from table"),
        h("button.btn.small", { on: { click: () => grid.clearSelection() } }, "Clear"));
    }
    async function removeRows(rows) {
      const inTable = rows.filter((r) => r.inTable);
      if (!inTable.length) { N.toast("Nothing to remove", "None of the selected rows is in the table"); return; }
      const message = `${inTable.length} row(s) and what was typed in them are removed from the ${type.title || entityType} table. ` +
        "The data on disk is not touched; entities still in the stores come back as new rows after a sync.";
      if (!(await N.confirm("Remove from the table?", message, "Remove", "danger"))) return;
      let removed = 0;
      for (const row of inTable) {
        try { await app.client.request("entities.remove", { entityType, key: row.key }); removed++; } catch (error) { N.showError(error); break; }
      }
      N.toast("Removed", `${removed} row(s)`, "success");
      grid.clearSelection();
      await app.reloadProject();
      app.reloadEntities();
    }
    function renderFooter() {
      const c = grid.counts();
      N.fill(footer, 
        h("span", `${grid.view.length} of ${c.all} ${type.title || entityType}`.toLowerCase()),
        h("span.legend", h("span.status-mark.both"), "complete"),
        h("span.legend", h("span.status-mark.new"), "new in the stores"),
        h("span.legend", h("span.status-mark.missing"), "not found in the stores"));
    }

    const body = h("div", { style: { position: "relative", flex: "1", display: "flex", flexDirection: "column", minHeight: 0 } }, grid.el, selectionBar);
    N.fill(content, toolbar, body, footer);

    app.reloadEntities = async () => {
      try {
        const data = await app.client.request("entities.list", { entityType });
        grid.setData(data);
        hideIgnored.classList.toggle("on", grid.hideIgnored);
        renderChips();
        renderFooter();
      } catch (error) { N.showError(error, `Could not load ${entityType}`); }
    };
    const origRefresh = grid.refresh.bind(grid);
    grid.refresh = () => { origRefresh(); renderFooter(); };
    await app.reloadEntities();
    search.focus();
  };

  N.views.entityDrawer = async function (app, entityType, key) {
    let detail;
    try {
      detail = await app.client.request("entities.get", { entityType, key });
    } catch (error) { N.showError(error); return; }
    const status = N.statusOf(detail);
    const statusPill = { both: h("span.pill.good", "complete"), new: h("span.pill.info", "new — not in the table"), missing: h("span.pill.warn", "not found in the stores") }[status];
    const values = Object.entries(detail.values).filter(([k]) => !(k in detail.key));
    const columns = new Map(((app.currentGrid && app.currentGrid.data && app.currentGrid.data.columns) || []).map((c) => [c.name, c]));
    const label = (name) => { const c = columns.get(name); return c ? (c.title || name) + (c.unit ? ` (${c.unit})` : "") : N.titleCase(name); };
    const show = (name, v) => {
      if (v === null || v === undefined || v === "") return h("span.muted", "—");
      if (v === true || v === false) return v ? "yes" : "no";
      const c = columns.get(name);
      return c && (c.dataType === "number" || c.dataType === "integer") ? N.fmt.number(v) : String(v);
    };
    const props = h("dl.props", values.map(([k, v]) => [h("dt", label(k)), h("dd", show(k, v))]));
    const locations = (detail.locations || []).map((loc) => {
      const files = Object.entries(loc.files || {});
      const where = (p) => ({ dataLocation: loc.dataLocationIdentifier, rootStoragePath: loc.rootStoragePathIdentifier, path: p });
      const pathActions = (p) => h("span.path-actions",
        h("button.btn.ghost.icon.small", { title: "Show in the file browser", on: { click: () => app.client.request("files.reveal", where(p))
          .catch((error) => N.showError(error, "Could not open the folder")) } }, N.icon("folder", 13)),
        h("button.btn.ghost.icon.small", { title: "Copy the full path", on: { click: async () => {
          try {
            const resolved = await app.client.request("files.resolve", where(p));
            await N.copyText(resolved.path);
            N.toast("Path copied", resolved.path, "success");
          } catch (error) { N.showError(error, "Could not copy the path"); }
        } } }, N.icon("copy", 13)));
      return h("div.loc",
        h("div.loc-head", N.icon("folder", 14), loc.dataLocationIdentifier, h("span.muted", { style: { fontWeight: 400 } }, "· " + loc.rootStoragePathIdentifier),
          loc.isComplete === false ? h("span.pill.warn", "incomplete") : null),
        h("ul.path-list", (loc.paths || []).map((p) => h("li", h("span.path-text", p), pathActions(p)))),
        files.length ? h("dl.props", { style: { marginTop: "8px" } }, files.map(([name, paths]) => [h("dt", name),
          h("dd", paths.length ? paths.map((p) => h("div.mono", { style: { fontSize: "12px" } }, p.split("/").pop())) : h("span.muted", "none"))])) : null);
    });
    const data = (detail.data || []).map((d) => h("li", h("span.dot." + (d.files.length ? "good" : "warn")),
      h("div.grow", h("div.title", d.name), h("div.sub", `${d.dataLocation} · ${d.fileAdapter}`)),
      h("span.pill.plain", d.files.length ? `${d.files.length} file(s)` : "not written")));
    const issues = (detail.issueDetails || []).map((i) => h("li", h("span.dot.warn"), h("div.grow", h("div.title", i.code), h("div.sub", i.message || ""))));
    const actions = [];
    if (!detail.inTable) {
      actions.push(h("button.btn.small.primary", { on: { click: async () => {
        try {
          await app.client.request("entities.add", { entityType, key: detail.key });
          N.toast("Added to the table", N.fmt.key(detail.key), "success");
          N.views.entityDrawer(app, entityType, key);
        } catch (error) { N.showError(error); }
      } } }, N.icon("plus", 14), "Add to table"));
    }
    actions.push(h("button.btn.small", { on: { click: () => N.views.methodDialog(app, entityType, [detail]) } }, N.icon("play", 14), "Run"));
    const notesEl = h("div.notes");
    N.drawer.open(N.fmt.key(detail.key), (app.typeTitle(entityType)).replace(/s$/, ""),
      h("div",
        h("div", { style: { margin: "12px 0" } }, statusPill),
        h("div.section-title", "Values"), props,
        h("div.section-title", "Locations"), locations.length ? locations : h("div.muted", "Not found in any data location."),
        data.length ? [h("div.section-title", "Data"), h("ul.list.card", data)] : null,
        issues.length ? [h("div.section-title", "Issues"), h("ul.list.card", issues)] : null,
        h("div.section-title", "Notes"), notesEl),
      actions);
    N.views.entityNotes(app, notesEl, entityType, detail.key);
  };

  /* ------------------------------------------------------------------ notes */
  const NOTE_TYPES = [["informal", "Note", "plain"], ["important", "Important", "warn"], ["todo", "To do", "info"], ["question", "Question", "accent"]];
  const noteType = (type) => NOTE_TYPES.find(([t]) => t === type) || [type, type, "plain"];

  /** One note: its type, title, who wrote it when, the text and its #tags; optionally the entity it is about. */
  N.views.noteItem = function (app, note, { showEntity = false, onRemove = null } = {}) {
    const [, typeTitle, pill] = noteType(note.type);
    const remove = onRemove ? h("button.btn.ghost.icon.small", { title: "Delete this note", on: { click: async () => {
      if (!(await N.confirm("Delete this note?", note.title || note.text.slice(0, 80), "Delete"))) return;
      try {
        await app.client.request("notes.remove", { entityType: note.entityType, id: note.id });
        onRemove(note);
      } catch (error) { N.showError(error); }
    } } }, N.icon("trash", 14)) : null;
    return h("li.note", { dataset: { id: String(note.id), type: note.type } },
      h("div.note-head", h("span.pill." + pill, typeTitle), note.title ? h("span.note-title", note.title) : null,
        h("span.spacer"), h("span.note-meta", [note.author, N.fmt.time(note.createdAt)].filter(Boolean).join(" · ")), remove),
      showEntity ? h("a.note-entity", { href: "#/entities/" + note.entityType, on: { click: (event) => {
        event.preventDefault();
        N.views.entityDrawer(app, note.entityType, note.key);
      } } }, N.icon("table", 13), `${app.typeTitle(note.entityType).replace(/s$/, "")} ${N.fmt.key(note.key)}`) : null,
      note.text ? h("div.note-text", note.text) : null,
      note.tags.length ? h("div.note-tags", note.tags.map((tag) => h("span.tag", "#" + tag))) : null);
  };

  /** The form that adds a note to an entity. */
  N.views.noteForm = function (app, entityType, key, onAdded) {
    let type = "informal";
    const chips = h("div.chips");
    const renderChips = () => N.fill(chips, NOTE_TYPES.map(([t, title]) =>
      h("button.chip" + (t === type ? ".on" : ""), { type: "button", dataset: { type: t }, on: { click: () => { type = t; renderChips(); } } }, title)));
    renderChips();
    const title = h("input.input", { placeholder: "Title (optional)", "aria-label": "Note title" });
    const text = h("textarea.input", { rows: 3, placeholder: "What did you notice? #tags are picked up", "aria-label": "Note text" });
    const message = h("div.form-message.hidden");
    const say = (text) => { message.textContent = text; message.classList.toggle("hidden", !text); };
    const add = h("button.btn.small.primary", { type: "submit" }, N.icon("plus", 14), "Add note");
    return h("form.note-form", { on: { submit: async (event) => {
      event.preventDefault();
      if (!text.value.trim() && !title.value.trim()) { say("Write a title or some text"); return; }
      add.disabled = true;
      try {
        const note = await app.client.request("notes.add", { entityType, key, type, title: title.value.trim(), text: text.value.trim() });
        title.value = ""; text.value = ""; say("");
        onAdded(note);
      } catch (error) { say(error.message || String(error)); }
      add.disabled = false;
    } } }, chips, title, text, h("div.note-form-foot", message, h("span.spacer"), add));
  };

  /** An entity's notes, newest first, with the form to add one; kept current by notes events. */
  N.views.entityNotes = async function (app, el, entityType, key) {
    const listEl = h("ul.list.card.note-list");
    async function load() {
      let notes;
      try { notes = await app.client.request("notes.list", { entityType, key }); } catch (error) { N.showError(error); return; }
      N.fill(listEl, notes.length ? notes.map((note) => N.views.noteItem(app, note, { onRemove: load }))
        : h("li.muted.note-none", "No notes yet."));
    }
    N.fill(el, N.views.noteForm(app, entityType, key, load), listEl);
    app.onDrawerNotesEvent = (data) => {
      if (!el.isConnected) return;
      if (data.entityType === entityType && (!data.key || N.keyId(data.key) === N.keyId(key))) load();
    };
    await load();
  };

  /** Every note in the project, newest first, filtered by type and by a search over text, tags and keys. */
  N.views.notes = async function (app, content) {
    let notes = [];
    let type = "all";
    let query = "";
    const chipsEl = h("div.chips");
    const listEl = h("ul.list.card.note-list");
    const search = h("input.input", { type: "search", placeholder: "Search notes, #tags or entities", style: { width: "280px" },
      on: { input: () => { query = search.value.trim().toLowerCase(); render(); } } });
    async function load() {
      try { notes = await app.client.request("notes.list"); } catch (error) { N.showError(error); return; }
      render();
    }
    const matches = (note) => !query || [note.title, note.text, note.author, N.fmt.key(note.key), ...note.tags.map((t) => "#" + t)]
      .some((text) => String(text || "").toLowerCase().includes(query));
    function render() {
      const count = (t) => notes.filter((n) => t === "all" || n.type === t).length;
      N.fill(chipsEl, [["all", "All"], ...NOTE_TYPES].map(([t, title]) =>
        h("button.chip" + (t === type ? ".on" : ""), { dataset: { type: t }, on: { click: () => { type = t; render(); } } }, title, h("span.n", String(count(t))))));
      const shown = notes.filter((n) => (type === "all" || n.type === type) && matches(n));
      N.fill(listEl, shown.length ? shown.map((note) => N.views.noteItem(app, note, { showEntity: true, onRemove: load }))
        : h("li.empty", N.icon("note", 36), h("h3", notes.length ? "No notes match" : "No notes yet"),
          h("div", notes.length ? "Try another type or search." : "Open an entity and write a note in its drawer.")));
    }
    N.fill(content,
      h("div.hero", h("div", h("h1", "Notes"), h("p", "What people noticed about sessions, subjects and other entities. Each entity type's notes are a file in the project's notes folder.")),
        h("div.spacer"), search),
      h("div.note-filters", chipsEl), listEl);
    app.onNotesEvent = () => { if (listEl.isConnected) load(); };
    await load();
  };

  /* ------------------------------------------------------------------ run a method */
  N.views.methodDialog = async function (app, entityType, rows) {
    let methods, pipelines;
    try {
      [methods, pipelines] = await Promise.all([
        app.client.request("methods.list", { entityType }),
        app.client.request("pipelines.list", { entityType }).catch(() => [])]);
    } catch (error) { N.showError(error); return; }
    if (!methods.length) { N.toast("No methods", `No method runs on ${entityType}. Add a module with methods.`); return; }
    const target = rows.length ? `${rows.length} selected` : `all ${app.typeTitle(entityType).toLowerCase()}`;
    let current = null;
    let form = null;
    let presets = [];
    const list = h("div.method-list");
    const detail = h("div.method-detail");
    const groups = new Map();
    for (const m of methods) {
      const group = m.category || "Methods";
      if (!groups.has(group)) groups.set(group, []);
      groups.get(group).push(m);
    }
    const items = new Map();
    for (const [group, members] of groups) {
      list.appendChild(h("div.group", group));
      for (const m of members) {
        const item = h("button.method-item", { on: { click: () => select(m) } }, h("div.t", m.title), h("div.d", m.description || m.id));
        items.set(m.id, item);
        list.appendChild(item);
      }
    }
    if (pipelines.length) {
      list.appendChild(h("div.group", "Pipelines"));
      for (const p of pipelines) {
        const item = h("button.method-item", { on: { click: () => selectPipeline(p) } },
          h("div.t", N.icon("layers", 13), " ", p.title || p.id), h("div.d", p.steps.map((s) => s.title).join(" → ")));
        items.set("pipeline:" + p.id, item);
        list.appendChild(item);
      }
    }
    let pipeline = null;
    function selectPipeline(p) {
      selection++;
      current = null;
      pipeline = p;
      items.forEach((el, id) => el.classList.toggle("on", id === "pipeline:" + p.id));
      N.fill(detail,
        h("h3", p.title || p.id),
        h("div.muted", p.description || ""),
        h("div.meta", h("span.pill.plain", p.id + " " + p.version), h("span.pill.accent", `${p.steps.length} steps per entity`)),
        h("ol", { style: { paddingLeft: "18px", lineHeight: "1.9" } }, p.steps.map((s) => h("li", h("b", s.title), h("span.muted", ` · ${s.method}` + (s.preset ? ` · preset ${s.preset}` : ""))))),
        h("div.muted", { style: { marginTop: "10px" } }, "Each selected entity gets its own chain of tasks; a step waits for the one before and is skipped if it fails."));
    }

    let selection = 0;
    async function select(method, presetName) {
      const token = ++selection;
      current = method;
      pipeline = null;
      items.forEach((el, id) => el.classList.toggle("on", id === method.id));
      const loaded = await app.client.request("presets.list", { methodId: method.id }).catch(() => []);
      if (token !== selection) return; // a later choice won while the presets loaded
      presets = loaded;
      const preset = presets.find((p) => p.name === (presetName || "default")) || presets[0];
      form = N.schemaForm(method.options || {}, preset ? preset.values : {});
      const presetSelect = h("select.input", { style: { width: "200px" }, on: { change: (e) => select(method, e.target.value) } },
        presets.map((p) => h("option", { value: p.name, selected: preset && p.name === preset.name }, p.name)));
      const save = h("button.btn", { on: { click: async () => {
        const name = await N.prompt("Save preset", "Preset name", "");
        if (!name) return;
        try {
          await app.client.request("presets.save", { methodId: method.id, name, values: form.getValue() });
          N.toast("Preset saved", name, "success");
          select(method, name);
        } catch (error) { N.showError(error, "Could not save the preset"); }
      } } }, "Save as…");
      const remove = preset && preset.name !== "default" ? h("button.btn.ghost", { title: "Delete this preset", on: { click: async () => {
        if (!(await N.confirm("Delete preset?", `The preset '${preset.name}' of ${method.title} is deleted.`, "Delete", "danger"))) return;
        try {
          await app.client.request("presets.delete", { methodId: method.id, name: preset.name });
          N.toast("Preset deleted", preset.name, "success");
          select(method);
        } catch (error) { N.showError(error, "Could not delete the preset"); }
      } } }, N.icon("trash", 14)) : null;
      N.fill(detail, 
        h("h3", method.title),
        h("div.muted", method.description || ""),
        h("div.meta",
          h("span.pill.plain", method.id + " " + method.version),
          h("span.pill.accent", method.batchMode === "batch" ? "once for all" : "once per entity"),
          method.languages.map((l) => h("span.pill.plain", l)),
          method.module ? h("span.pill.plain", "module " + method.module) : null),
        h("div.preset-row", h("label.name", { style: { fontWeight: 600 } }, "Preset"), presetSelect, save, remove),
        form.el);
    }

    const run = async (close, queued) => {
      if (pipeline) {
        const params = { pipelineId: pipeline.id, entityType };
        if (rows.length) params.keys = rows.map((r) => r.key);
        try {
          const tasks = await app.client.request("pipelines.submit", params);
          N.toast("Pipeline queued", `${pipeline.title || pipeline.id}: ${tasks.length} task(s)`, "success");
          close();
          app.go("#/tasks");
        } catch (error) { N.showError(error, "Could not queue the pipeline"); }
        return;
      }
      if (!current) return;
      const problems = form.validate();
      if (problems.length) { N.toast("Check the options", problems.join("; "), "error"); return; }
      const params = { methodId: current.id, entityType, options: form.getValue() };
      if (rows.length) params.keys = rows.map((r) => r.key);
      try {
        if (queued) {
          const task = await app.client.request("tasks.submit", params);
          N.toast("Queued", `${current.title} on ${target}`, "success");
          close();
          app.go("#/tasks/" + task.id);
        } else {
          close();
          N.toast("Running", `${current.title} on ${target}…`);
          await app.client.request("methods.run", params);
          N.toast("Done", `${current.title} finished`, "success");
          if (app.reloadEntities) app.reloadEntities();
        }
      } catch (error) { N.showError(error, `${current.title} failed`); }
    };
    N.dialog({
      title: `Run a method on ${target}`,
      content: h("div.method-layout", list, detail),
      buttons: [
        { label: "Cancel" },
        { label: "Run now", onClick: (close) => run(close, false) },
        { label: "Add to queue", kind: "primary", icon: "play", onClick: (close) => run(close, true) },
      ],
    });
    select(methods[0]);
  };

  /* ------------------------------------------------------------------ tasks */
  N.views.tasks = async function (app, content, selectedId) {
    let tasks = [];
    let status = { running: false, counts: {} };
    const listEl = h("div");
    const detailEl = h("div");
    const queueControls = h("div", { style: { display: "flex", gap: "8px", alignItems: "center" } });

    // A list or an event can be older than what the view already shows (a poll answered just before a task
    // finished), so a task only moves forward: queued, running, then finished, with progress only growing.
    const stage = (task) => ({ queued: 0, running: 1 }[task.status] ?? 2);
    function newer(incoming, shown) {
      if (!shown) return incoming;
      if (stage(incoming) !== stage(shown)) return stage(incoming) > stage(shown) ? incoming : shown;
      if (stage(incoming) === 2 && incoming.id === shown.id && incoming.finishedAt !== shown.finishedAt) return incoming;
      return (incoming.progress || 0) >= (shown.progress || 0) ? incoming : shown;
    }
    let loadToken = 0;
    async function load() {
      const token = ++loadToken;
      let listed;
      try {
        [listed, status] = await Promise.all([app.client.request("tasks.list"), app.client.request("queue.status")]);
      } catch (error) { N.showError(error); return; }
      if (token !== loadToken) return;
      const shown = new Map(tasks.map((task) => [task.id, task]));
      tasks = listed.map((task) => newer(task, shown.get(task.id)));
      render();
    }
    function renderControls() {
      N.fill(queueControls, 
        h("span.pill." + (status.running ? "good" : "plain"), status.running ? "Worker running" : "Worker stopped"),
        h("button.btn", { on: { click: async () => {
          status = await app.client.request(status.running ? "queue.stop" : "queue.start").catch(N.showError) || status;
          renderControls();
        } } }, N.icon(status.running ? "stop" : "play"), status.running ? "Stop worker" : "Start worker"),
        !status.running ? h("button.btn", { on: { click: async () => {
          try { await app.client.request("tasks.runNext"); load(); } catch (error) { N.showError(error); }
        } } }, "Run next") : null,
        h("button.btn", { on: { click: async () => {
          const result = await app.client.request("tasks.clear").catch(N.showError);
          if (result) N.toast("Cleared", `${result.removed} finished task(s)`);
          load();
        } } }, N.icon("trash"), "Clear finished"));
    }
    function render() {
      renderControls();
      const ordered = [...tasks].reverse();
      N.fill(listEl, ordered.length ? ordered.map(renderTask) :
        h("div.empty", N.icon("tasks", 40), h("h3", "No tasks"), h("div", "Select entities in a table and run a method in the background.")));
      if (selectedId) showDetail(selectedId);
    }
    function renderTask(task) {
      const pct = Math.round((task.progress || 0) * 100);
      const progressClass = task.status === "completed" ? ".done" : task.status === "failed" ? ".failed" : "";
      const el = h("div.task" + (task.id === selectedId ? ".selected" : ""), { dataset: { id: task.id }, on: { click: () => { selectedId = task.id; app.replace("#/tasks/" + task.id); render(); } } },
        h("div",
          h("div.title", N.statusPill(task.status),
            task.pipeline ? [h("span.pill.accent.plain", `${task.pipeline.id} ${task.pipeline.step + 1}/${task.pipeline.steps}`), task.pipeline.title || app.methodTitle(task.method.id)] : app.methodTitle(task.method.id),
            h("span.muted", { style: { fontWeight: 400 } }, `· ${task.entities.length} ${task.entities[0].entityType}(s)`)),
          h("div.sub", [
            `queued ${N.fmt.time(task.createdAt)}`,
            task.startedAt ? `ran ${N.fmt.duration(task.startedAt, task.finishedAt)}` : null,
            task.message && task.status === "running" ? task.message : null,
            task.error ? task.error.message : null,
          ].filter(Boolean).join(" · "))),
        h("div.actions",
          task.status === "queued" || task.status === "running" ? h("button.btn.small", { on: { click: (e) => { e.stopPropagation(); act("tasks.cancel", task); } } }, N.icon("stop", 14), "Cancel") : null,
          ["failed", "cancelled", "completed"].includes(task.status) ? h("button.btn.small", { on: { click: (e) => { e.stopPropagation(); act("tasks.retry", task); } } }, N.icon("retry", 14), "Retry") : null,
          task.status !== "running" ? h("button.btn.small.ghost.icon", { title: "Remove", on: { click: (e) => { e.stopPropagation(); act("tasks.remove", task); } } }, N.icon("trash", 14)) : null),
        task.status === "queued" ? null : h("div.progress" + progressClass, h("span", { style: { width: pct + "%" } })));
      return el;
    }
    async function act(method, task) {
      try {
        await app.client.request(method, { id: task.id });
        if (method === "tasks.remove" && selectedId === task.id) selectedId = null;
        load();
      } catch (error) { N.showError(error); }
    }
    let detailToken = 0;
    async function showDetail(id) {
      // Renders overlap; only the newest request may fill the panel, or an older answer hides newer log lines.
      const token = ++detailToken;
      let task;
      try { task = await app.client.request("tasks.get", { id }); } catch (error) { if (token === detailToken) N.clear(detailEl); return; }
      if (token !== detailToken) return;
      N.fill(detailEl, h("div.card",
        h("div.card-head", h("h3", app.methodTitle(task.method.id)), h("div.spacer"), N.statusPill(task.status)),
        h("div.card-body",
          h("dl.props",
            h("dt", "Task"), h("dd.mono", task.id),
            h("dt", "Method"), h("dd", `${task.method.id} ${task.method.version}`),
            h("dt", "Entities"), h("dd", task.entities.map((e) => h("div.mono", { style: { fontSize: "12px" } }, N.fmt.key(e.key)))),
            h("dt", "Options"), h("dd.mono", { style: { fontSize: "12px", whiteSpace: "pre-wrap" } }, JSON.stringify(task.options.values, null, 1)),
            h("dt", "Queued"), h("dd", N.fmt.time(task.createdAt)),
            task.startedAt ? [h("dt", "Started"), h("dd", N.fmt.time(task.startedAt))] : null,
            task.finishedAt ? [h("dt", "Finished"), h("dd", N.fmt.time(task.finishedAt))] : null,
            task.error ? [h("dt", "Error"), h("dd", { style: { color: "var(--bad)" } }, task.error.message)] : null),
          h("div.section-title", "Log"),
          h("pre.log", { id: "task-log" }, task.logText || "(nothing logged yet)"))));
    }

    N.fill(content, 
      h("div.hero", h("div", h("h1", "Tasks"), h("p", "Methods queued on entities. Each task is a file in the project's tasks folder, so the queue survives restarts and either language can run it.")),
        h("div.spacer"), queueControls),
      h("div.grid.two", h("div.card", listEl), detailEl));

    app.onTaskEvent = (task) => {
      const index = tasks.findIndex((t) => t.id === task.id);
      if (index >= 0) tasks[index] = newer(task, tasks[index]); else tasks.push(task);
      render();
    };
    // Events can pass while the view loads; the task files are the truth, so poll while tasks are active.
    app.viewTimer = setInterval(() => {
      if (tasks.some((t) => t.status === "queued" || t.status === "running")) load();
    }, 1500);
    app.onLogEvent = (event) => {
      if (event.id === selectedId) {
        const log = document.getElementById("task-log");
        if (log && !log.textContent.split("\n").includes(event.line)) {  // a refresh may have brought it already
          log.textContent = (log.textContent === "(nothing logged yet)" ? "" : log.textContent + "\n") + event.line;
          log.scrollTop = log.scrollHeight;
        }
      }
    };
    await load();
  };

  /* ------------------------------------------------------------------ data */
  N.views.data = async function (app, content) {
    const project = app.project;
    const [variables, fragments, methods] = await Promise.all([
      app.client.request("dataVariables.list").catch(() => []),
      app.client.request("fragments.list").catch(() => []),
      app.client.request("methods.list").catch(() => []),
    ]);
    const dataset = project.dataset;
    N.fill(content, 
      h("div.hero", h("div", h("h1", "Data"), h("p", "Where the data is, how it is named, and what the project adds to it."))),
      h("div.grid",
        h("div.card", h("div.card-head", N.icon("database"), h("h3", "Data locations"), h("div.spacer"),
          dataset ? h("span.muted", `environment: ${dataset.environment || "default"}`) : null),
          dataset ? h("table.simple", h("thead", h("tr", ["Location", "Category", "Access", "Root", "", ""].map((t) => h("th", t)))),
            h("tbody", dataset.roots.map((root) => {
              const loc = dataset.locations.find((l) => l.id === root.dataLocation) || {};
              return h("tr", h("td", h("b", loc.title || root.dataLocation), h("div.muted.mono", root.dataLocation)), h("td", loc.category),
                h("td", loc.access), h("td.mono", root.path, root.environment ? h("div.muted", `environment ${root.environment}`) : null),
                h("td", h("span.pill." + (root.available ? "good" : "bad"), root.available ? "available" : "offline")),
                h("td", h("button.btn.small", { title: "Where this data is on this computer", on: { click: async () => {
                  const path = await N.prompt(`Where is ${loc.title || root.dataLocation}?`, "Folder on this computer", root.path);
                  if (!path || path === root.path) return;
                  try {
                    app.project = await app.client.request("dataset.setRoot", { dataLocation: root.dataLocation, rootStoragePath: root.rootStoragePath, path });
                    await app.reloadProject();
                    app.render();
                    N.toast("Path changed", "Scan the stores to see what is there", "success");
                  } catch (error) { N.showError(error, "Could not change the path"); }
                } } }, "Change path")));
            }))) : h("div.card-body.muted", "No dataset.")),
        h("div.card", h("div.card-head", N.icon("file"), h("h3", "Data variables")),
          variables.length ? h("table.simple", h("thead", h("tr", ["Name", "Entity", "Location", "File", "Adapter"].map((t) => h("th", t)))),
            h("tbody", variables.map((v) => h("tr", h("td", h("b", v.name)), h("td", v.entityType), h("td", v.dataLocation),
              h("td.mono", [v.subfolder ? v.subfolder + "/" : "", v.fileName || `pattern ${v.filePattern}`].join("")), h("td", v.fileAdapter))))) :
            h("div.card-body.muted", "No data variables.")),
        h("div.grid.two",
          h("div.card", h("div.card-head", N.icon("columns"), h("h3", "Fragments")),
            h("ul.list", fragments.map((f) => h("li", h("div.grow", h("div.title", f.title, f.computed ? h("span.pill.accent", { style: { marginLeft: "8px" } }, "computed") : null),
              h("div.sub", `${f.id} ${f.version} · ${f.columns.map((c) => c.name).join(", ")}`)))))),
          h("div.card", h("div.card-head", N.icon("zap"), h("h3", "Methods")),
            h("ul.list", methods.map((m) => h("li", h("div.grow", h("div.title", m.title), h("div.sub", `${m.id} · ${m.entityType === "*" ? "any entity" : m.entityType} · ${m.languages.join(", ")}`)))))))));
  };

  /* ------------------------------------------------------------------ projects */
  N.views.projects = async function (app, content) {
    const projects = await app.client.request("catalog.list").catch(() => []);
    const path = h("input.input", { placeholder: "/path/to/project", style: { flex: "1" } });
    const open = async (folder) => {
      try {
        await app.openProject(folder);
      } catch (error) { N.showError(error, "Could not open the project"); }
    };
    const opened = async (info, message) => {
      app.project = info;
      await app.reloadProject();
      app.go("#/overview");
      if (message) N.toast(message, info.title, "success");
    };
    const action = (icon, title, text, onClick) => h("button.action-card", { on: { click: onClick } },
      h("div.action-icon", N.icon(icon, 20)), h("div", h("div.title", title), h("div.sub", text)));
    N.fill(content,
      h("div.welcome",
        h("h1", app.project ? "Projects" : "Welcome to NANSEN"),
        h("p.muted", "Open a project folder, start a new one, or bring one over from NANSEN. Projects you open are remembered here."),
        h("div.action-cards",
          action("plus", "New project", "In an empty folder, optionally from an existing dataset config", () => newProjectDialog(app, opened)),
          action("compass", "Create the demo", "A small two-photon dataset to try things on", () => demoDialog(app, opened)),
          action("download", "Import from NANSEN", "Convert a project made with the existing NANSEN", () => importDialog(app, opened))),
        h("div.card", { style: { margin: "18px 0" } }, h("div.card-body", { style: { display: "flex", gap: "8px" } }, path,
          h("button.btn.primary", { on: { click: () => open(path.value) } }, N.icon("folder"), "Open"))),
        h("div.card", projects.length ? h("ul.list", projects.map((p) => h("li",
          h("span.dot." + (p.available ? "good" : "bad")),
          h("div.grow", h("div.title", p.title || p.name), h("div.sub.mono", p.path)),
          h("span.muted", p.lastOpened ? N.fmt.ago(p.lastOpened) : ""),
          h("button.btn.small" + (p.available ? ".primary" : ""), { disabled: !p.available, on: { click: () => open(p.path) } }, "Open"),
          h("button.btn.small.ghost.icon", { title: "Forget", on: { click: async () => { await app.client.request("catalog.remove", { path: p.path }).catch(N.showError); N.views.projects(app, content); } } }, N.icon("x", 14))))) :
          h("div.empty", N.icon("folder", 40), h("h3", "No projects yet"), h("div", "Create one above, or open a project folder.")))));
    path.addEventListener("keydown", (e) => { if (e.key === "Enter") open(path.value); });
  };

  function addColumnDialog(app, entityType) {
    formDialog({
      title: "Add a column",
      intro: "The column is added to every row, with the default below. It is kept as a fragment of the project, so it has a type and a version.",
      label: "Add column",
      required: ["name"],
      schema: { type: "object", properties: {
        name: { type: "string", title: "Column name", description: "A letter, then letters, digits or _", pattern: "^[A-Za-z][A-Za-z0-9_]*$" },
        title: { type: "string", title: "Title" },
        dataType: { type: "string", title: "Type", enum: ["string", "number", "integer", "boolean", "date", "datetime"], default: "string" },
        default: { type: "string", title: "Default", description: "For existing and new rows; empty for none (yes/no columns: true or false, else false)" },
        choices: { type: "string", title: "Choices", description: "Text columns only: the values it may take, separated by commas; empty for any text" },
        description: { type: "string", title: "Description" },
      } },
      submit: async (values) => {
        const column = { name: values.name, dataType: values.dataType };
        if (values.title) column.title = values.title;
        if (values.description) column.description = values.description;
        const text = values.default;
        if (values.dataType === "boolean") column.default = text === "true";
        else if (text !== undefined && (values.dataType === "number" || values.dataType === "integer")) {
          const number = Number(text);
          if (!Number.isFinite(number) || (values.dataType === "integer" && !Number.isInteger(number))) throw new Error(`Default: ${text} is not a${values.dataType === "integer" ? "n integer" : " number"}`);
          column.default = number;
        } else if (text !== undefined) column.default = text;
        const choices = (values.choices || "").split(",").map((c) => c.trim()).filter(Boolean);
        if (choices.length) {
          if (values.dataType !== "string") throw new Error("Choices: only a text column can have choices");
          if (new Set(choices).size !== choices.length) throw new Error("Choices: a choice is listed twice");
          if (column.default !== undefined && !choices.includes(column.default)) throw new Error(`Default: ${column.default} is not one of the choices`);
          column.choices = choices;
        }
        const document = { schemaType: "nansen.fragment", schemaVersion: "0.1.0",
          id: `columns.${entityType.toLowerCase()}_${values.name.toLowerCase()}`, version: "1.0.0",
          title: values.title || values.name, columns: [column] };
        await app.client.request("fragments.create", { document, entityType });
        await app.reloadProject();
        app.render();
        N.toast("Column added", values.title || values.name, "success");
      },
    });
  }

  function datasetDialog(app) {
    const hasCore = app.project.modules.some((m) => m.id === "core");
    formDialog({
      title: "Set up the dataset",
      intro: "The config is copied into the project. Root paths in it that are relative are made absolute, so they still point to the data.",
      label: "Use this dataset",
      required: ["datasetSource"],
      schema: { type: "object", properties: {
        datasetSource: { type: "string", title: "Dataset config", description: "Path of an existing dataset.dsm.json" },
        entityTypes: { type: "boolean", default: true, title: "Add the dataset's entity types" },
        core: { type: "boolean", default: !hasCore, title: "Use the core module (notes, file statistics)" },
      } },
      submit: async (values) => {
        app.project = await app.client.request("project.setDataset", { datasetSource: values.datasetSource,
          entityTypes: values.entityTypes, modules: values.core ? ["core"] : [] });
        await app.reloadProject();
        app.render();
        N.toast("Dataset added", "Scan the stores to find the entities", "success");
      },
    });
  }

  /* A dialog with a form drawn from a schema; submit gets the values without empty text, and may throw. */
  function formDialog({ title, intro, schema, values, label, required, submit }) {
    const form = N.schemaForm(schema, values || {});
    const message = h("div.form-message.hidden");
    N.dialog({
      title,
      content: h("div", { style: { padding: "16px 20px" } }, intro ? h("p.muted", { style: { marginTop: 0 } }, intro) : null, form.el, message),
      buttons: [
        { label: "Cancel" },
        { label, kind: "primary", onClick: async (close) => {
          const entered = Object.fromEntries(Object.entries(form.getValue()).filter(([, v]) => v !== ""));
          const missing = (required || []).filter((name) => !entered[name]).map((name) => schema.properties[name].title || name);
          const problems = missing.length ? missing.map((name) => `${name} is required`) : form.validate();
          if (problems.length) {
            message.textContent = problems.join(" · ");
            message.classList.remove("hidden");
            return;
          }
          try {
            await submit(entered);
            close();
          } catch (error) {
            message.textContent = error.message || String(error);
            message.classList.remove("hidden");
          }
        } },
      ],
    });
  }

  function newProjectDialog(app, opened) {
    formDialog({
      title: "New project",
      intro: "The folder must be new or empty. With a dataset config, the project's entity types and data locations come from it.",
      label: "Create",
      required: ["path", "name"],
      schema: { type: "object", properties: {
        path: { type: "string", title: "Folder" },
        name: { type: "string", title: "Name", description: "A short identifier: a letter, then letters, digits or _", pattern: "^[A-Za-z][A-Za-z0-9_]*$" },
        title: { type: "string", title: "Title" },
        description: { type: "string", title: "Description" },
        datasetSource: { type: "string", title: "Dataset config", description: "An existing dataset.dsm.json to copy in (optional)" },
        entityTypes: { type: "boolean", default: true, title: "Add the dataset's entity types" },
        core: { type: "boolean", default: true, title: "Use the core module (notes, file statistics)" },
      } },
      submit: async (values) => {
        const params = { path: values.path, name: values.name, title: values.title, description: values.description,
          datasetSource: values.datasetSource, modules: values.core ? ["core"] : [], entityTypes: !!values.datasetSource && values.entityTypes };
        await opened(await app.client.request("project.create", params), "Project created");
      },
    });
  }

  function demoDialog(app, opened) {
    formDialog({
      title: "Create the demo",
      intro: "Writes a small two-photon dataset (raw and partly processed sessions of four mice) and a project over it.",
      label: "Create",
      required: ["path"],
      schema: { type: "object", properties: { path: { type: "string", title: "Folder", description: "A new or empty folder" } } },
      submit: async (values) => opened(await app.client.request("demo.create", values), "Demo created"),
    });
  }

  function importDialog(app, opened) {
    const python = app.info && app.info.language === "python";
    formDialog({
      title: "Import from NANSEN",
      intro: python
        ? "Python reads the export that MATLAB writes: run nansen.legacy.exportProject(folder, File=\"export.json\") in MATLAB, then give that file here."
        : "Give the folder of a project made with the existing NANSEN, or an export of one. The old project is not changed.",
      label: "Import",
      required: ["source", "path"],
      schema: { type: "object", properties: {
        source: { type: "string", title: python ? "Export file" : "NANSEN project folder or export file" },
        path: { type: "string", title: "New project folder", description: "A new or empty folder" },
      } },
      submit: async (values) => {
        const result = await app.client.request("legacy.import", values);
        await opened(result.project, "Project imported");
        if (result.warnings.length) {
          N.dialog({ title: "Not carried over", content: h("div", { style: { padding: "16px 20px" } },
            h("p.muted", { style: { marginTop: 0 } }, "The import left these out:"),
            h("ul.notes", result.warnings.map((w) => h("li", w)))), buttons: [{ label: "OK", kind: "primary" }] });
        }
      },
    });
  }
})();
