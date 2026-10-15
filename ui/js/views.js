/* The pages: overview, an entity table, tasks, data, projects; and the run-method dialog. */
(function () {
  "use strict";
  const N = window.N;
  const { h } = N;

  /* ------------------------------------------------------------------ overview */
  N.views = {};

  N.views.overview = async function (app, content) {
    const project = app.project;
    const [tasks, unmatched] = await Promise.all([
      app.client.request("tasks.list").catch(() => []),
      project.dataset ? app.client.request("scan.unmatched", { limit: 200 }).catch(() => null) : null]);
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

    const unmatchedCard = unmatched && unmatched.total ? (() => {
      const list = h("ul.list.unmatched-list");
      const draw = (all) => N.fill(list, (all ? unmatched.entries : unmatched.entries.slice(0, 6)).map((u) => h("li", { dataset: { path: u.path, location: u.dataLocation } },
        h("span.dot.warn"),
        h("div.grow", h("div.title.mono", { style: { fontSize: "12.5px" } }, u.path), h("div.sub", `${u.dataLocation} · ${u.detail || u.reason}`)),
        h("button.btn.ghost.icon.small", { title: "Show in the file browser", on: { click: () => app.client.request("files.reveal",
          { dataLocation: u.dataLocation, rootStoragePath: u.rootStoragePath, path: u.path }).catch((error) => N.showError(error, "Could not open the folder")) } }, N.icon("folder", 13)),
        h("button.btn.small.ignore-entry", { title: "Have scans skip this name at its level (an exclude pattern in the dataset config)", on: { click: async () => {
          try {
            const result = await app.client.request("dataset.exclude", { dataLocation: u.dataLocation, path: u.path });
            N.toast("Skipped in scans", `${result.pattern} at level ${result.level}`, "success");
            app.render();
          } catch (error) { N.showError(error, "Could not exclude it"); }
        } } }, "Ignore"))),
        !all && unmatched.entries.length > 6 ? h("li.more", h("button.btn.small.ghost", { on: { click: () => draw(true) } }, `Show all ${unmatched.entries.length}`)) : null);
      draw(false);
      return h("div.card.unmatched-card", h("div.card-head", N.icon("alert"), h("h3", "Not matched by the last scan"), h("div.spacer"),
        h("span.pill.warn", String(unmatched.total))),
        h("div.card-body.muted", { style: { paddingBottom: 0 } }, "Folders and files in the data locations that no subject or session accounts for. Fix the names, change the dataset config, or have scans ignore them."),
        list);
    })() : null;

    const tools = (app.methods || []).filter((m) => m.tool);
    const toolsCard = tools.length ? h("div.card.tools-card", h("div.card-head", N.icon("zap"), h("h3", "Tools")),
      h("ul.list", tools.map((m) => h("li", { dataset: { tool: m.id } },
        h("div.grow", h("div.title", m.title), h("div.sub", m.description || m.id)),
        h("button.btn.small.run-tool", { on: { click: () => toolDialog(app, m) } }, N.icon("play", 14), "Run"))))) : null;

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
          h("button.btn.ghost.icon.edit-project", { title: "Change the title, description and table names", on: { click: () => editProjectDialog(app) } }, N.icon("edit")),
          dataset ? h("button.btn", { on: { click: () => app.scan() } }, N.icon("scan"), "Scan stores") : null,
          dataset ? h("button.btn.primary", { on: { click: () => app.sync() } }, N.icon("sync"), "Sync tables") : null)),
      stats,
      h("div", { style: { height: "16px" } }),
      h("div.grid.two",
        h("div.grid",
          h("div.card", h("div.card-head", N.icon("database"), h("h3", "Data locations"), h("div.spacer"),
            h("span.muted", dataset ? `Last scan ${N.fmt.ago(project.lastScan)}` : "")), roots),
          unmatchedCard),
        h("div.grid",
          h("div.card", h("div.card-head", N.icon("tasks"), h("h3", "Recent tasks"), h("div.spacer"),
            h("a", { href: "#/tasks" }, "All tasks")), taskList),
          toolsCard,
          h("div.card.modules", h("div.card-head", N.icon("layers"), h("h3", "Modules"), h("div.spacer"),
            h("button.btn.small.manage-modules", { on: { click: () => modulesDialog(app) } }, N.icon("settings"), "Manage")), modules))));
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
    const search = h("input.input", { autofocus: true, placeholder: `Search ${type.title || entityType}…`, on: { input: N.debounce((e) => grid.setSearch(e.target.value), 120) } });
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
    const lockButton = h("button.btn.icon.lock-edits", { on: { click: () => {
      grid.setLocked(!grid.locked);
      showLock();
      N.toast(grid.locked ? "Editing locked" : "Editing unlocked", grid.locked ? "Values cannot be changed in the tables" : "");
    } } });
    function showLock() {
      lockButton.classList.toggle("on", grid.locked);
      lockButton.title = grid.locked ? "Editing is locked: click to allow changes" : "Lock editing, so values are not changed by accident";
      N.fill(lockButton, N.icon(grid.locked ? "lock" : "unlock"));
    }
    showLock();
    let views = [];
    let activeView = null;
    const viewStoreKey = `nansen.view.${app.project.folder}.${entityType}`;
    const viewsButton = h("button.btn", { on: { click: (e) => viewsMenu(e.currentTarget) } }, N.icon("eye"), h("span.view-name", "All rows"));
    const filterBar = h("div.filter-bar.hidden");
    async function loadViews() {
      views = await app.client.request("views.list", { entityType }).catch(() => []);
      if (activeView) activeView = views.find((v) => v.name === activeView.name) || null;
    }
    function showView(view) {
      activeView = view;
      try { localStorage.setItem(viewStoreKey, view ? view.name : ""); } catch (e) { /* fine */ }
      grid.applyView(view);
      search.value = view && view.search ? view.search : "";
      viewsButton.querySelector(".view-name").textContent = view ? view.name : "All rows";
      viewsButton.classList.toggle("on", !!view);
      renderFilters();
      renderChips();
      renderFooter();
    }
    function currentState() {
      const view = { filters: grid.filters.map((f) => Object.assign({}, f)), hiddenColumns: [...grid.hidden] };
      if (grid.search) view.search = search.value.trim();
      if (activeView && activeView.keys) view.keys = activeView.keys;
      if (!view.filters.length) delete view.filters;
      if (!view.hiddenColumns.length) delete view.hiddenColumns;
      return view;
    }
    async function saveView(view) {
      try {
        const saved = await app.client.request("views.save", { entityType, view });
        await loadViews();
        showView(views.find((v) => v.name === saved.name) || saved);
        N.toast("View saved", saved.name, "success");
      } catch (error) { N.showError(error, "Could not save the view"); }
    }
    function viewsMenu(anchor) {
      const items = [{ heading: "Views" },
        { label: "All rows", icon: activeView ? "dot" : "check", onClick: () => showView(null) }];
      for (const v of views) items.push({ label: v.name + (v.keys ? ` (${v.keys.length})` : ""), icon: activeView && activeView.name === v.name ? "check" : (v.keys ? "list" : "filter"), onClick: () => showView(v) });
      items.push({ heading: "Save" }, { label: "Save as a new view…", icon: "plus", onClick: async () => {
        const name = await N.prompt("Save as a view", "Name of the view", "");
        if (!name) return;
        if (views.some((v) => v.name === name) && !(await N.confirm("Replace the view?", `There is a view named ${name} already.`, "Replace", "danger"))) return;
        saveView(Object.assign({ name }, currentState()));
      } });
      if (activeView) {
        items.push({ label: `Update ${activeView.name}`, icon: "refresh", onClick: () => saveView(Object.assign({ name: activeView.name },
          activeView.description ? { description: activeView.description } : {}, currentState())) },
        { label: `Delete ${activeView.name}…`, icon: "trash", onClick: async () => {
          if (!(await N.confirm("Delete the view?", `The view ${activeView.name} is deleted. The rows in it stay in the table.`, "Delete", "danger"))) return;
          try {
            await app.client.request("views.delete", { entityType, name: activeView.name });
            await loadViews();
            showView(null);
          } catch (error) { N.showError(error, "Could not delete the view"); }
        } });
      }
      N.menu(anchor, items);
    }
    const describe = (f) => {
      const column = (grid.data.columns.find((c) => c.name === f.column) || { title: f.column });
      const label = column.title || f.column;
      const show = (v) => (v === null ? "none" : v === true ? "yes" : v === false ? "no" : String(v));
      switch (f.op) {
        case "in": return `${label}: ${f.values.map(show).join(", ")}`;
        case "range": return `${label}: ${f.min !== undefined && f.min !== null ? f.min : "…"} – ${f.max !== undefined && f.max !== null ? f.max : "…"}`;
        case "is": return `${label}: ${show(f.value)}`;
        case "contains": return `${label} contains “${f.text}”`;
        case "empty": return `${label}: empty`;
        default: return `${label}: has a value`;
      }
    };
    function renderFilters() {
      const any = grid.filters.length > 0 || (activeView && activeView.keys);
      filterBar.classList.toggle("hidden", !any);
      N.fill(filterBar,
        activeView && activeView.keys ? h("span.filter-chip.view", N.icon("list", 12), `${activeView.keys.length} row(s) of ${activeView.name}`) : null,
        grid.filters.map((f) => h("span.filter-chip", { dataset: { column: f.column } }, describe(f),
          h("button", { title: "Remove this filter", on: { click: () => { grid.clearFilter(f.column); renderFilters(); renderFooter(); } } }, "×"))),
        grid.filters.length ? h("button.btn.ghost.small", { on: { click: () => { grid.clearFilter(); renderFilters(); renderFooter(); } } }, "Clear filters") : null);
    }
    function filterDialog(column) {
      const current = grid.filters.find((f) => f.column === column.name);
      const label = column.title || column.name;
      const values = grid.data.rows.map((r) => r.values[column.name]);
      let body, read;
      if (column.dataType === "boolean") {
        const choice = h("select.input", ["yes", "no"].map((v) => h("option", { value: v, selected: current && current.op === "is" && (current.value ? "yes" : "no") === v }, v)));
        body = h("div.field", h("label.name", `Rows where ${label} is`), choice);
        read = () => ({ column: column.name, op: "is", value: choice.value === "yes" });
      } else if (["number", "integer", "date", "datetime"].includes(column.dataType)) {
        const type = { date: "date", number: "number", integer: "number" }[column.dataType] || "text";
        const min = h("input.input", { type, value: current && current.op === "range" && current.min !== undefined ? current.min : "" });
        const max = h("input.input", { type, value: current && current.op === "range" && current.max !== undefined ? current.max : "" });
        body = h("div", h("div.field", h("label.name", "From"), min), h("div.field", { style: { marginTop: "10px" } }, h("label.name", "To"), max),
          h("div.help", "Either can be left empty."));
        const value = (input) => (input.value === "" ? undefined : type === "number" ? Number(input.value) : input.value);
        read = () => {
          const f = { column: column.name, op: "range" };
          if (value(min) !== undefined) f.min = value(min);
          if (value(max) !== undefined) f.max = value(max);
          return f.min === undefined && f.max === undefined ? null : f;
        };
      } else {
        const distinct = [...new Set(values.map((v) => (v === undefined || v === "" ? null : v)))];
        const options = column.choices ? [...column.choices, null] : distinct.sort((a, b) => (a === null ? 1 : b === null ? -1 : String(a).localeCompare(String(b))));
        if (options.length <= 40) {
          const chosen = new Set(current && current.op === "in" ? current.values : []);
          const boxes = options.map((v) => h("label.item", h("input", { type: "checkbox", value: v === null ? "" : v, checked: chosen.has(v) }), v === null ? h("span.muted", "(none)") : String(v)));
          body = h("div", h("div.label-row", h("label.name", `Rows where ${label} is one of`)), h("div.filter-options", boxes));
          read = () => {
            const picked = boxes.map((b, i) => (b.querySelector("input").checked ? options[i] : undefined)).filter((v) => v !== undefined);
            return picked.length ? { column: column.name, op: "in", values: picked } : null;
          };
        } else {
          const text = h("input.input", { value: current && current.op === "contains" ? current.text : "", placeholder: "Text" });
          body = h("div.field", h("label.name", `Rows where ${label} contains`), text);
          read = () => (text.value.trim() ? { column: column.name, op: "contains", text: text.value.trim() } : null);
        }
      }
      const presence = h("select.input", [["", "Any"], ["notEmpty", "Has a value"], ["empty", "Is empty"]].map(([v, t]) =>
        h("option", { value: v, selected: current && current.op === v }, t)));
      N.dialog({
        title: `Filter: ${label}`, narrow: true,
        content: h("div", { style: { padding: "18px 20px", display: "grid", gap: "12px" } }, body,
          h("div.field", h("label.name", "Or only rows where it"), presence)),
        buttons: [
          { label: "Remove filter", onClick: (close) => { grid.clearFilter(column.name); renderFilters(); renderFooter(); close(); } },
          { label: "Apply", kind: "primary", onClick: (close) => {
            const filter = presence.value ? { column: column.name, op: presence.value } : read();
            if (filter) grid.setFilter(filter); else grid.clearFilter(column.name);
            renderFilters();
            renderFooter();
            close();
          } }],
      });
    }
    const computed = (app.fragments || []).filter((f) => f.computed && type.fragments.includes(f.id));
    const toolbar = h("div.toolbar",
      h("div.search", N.icon("search", 14), search), chips, h("div.spacer"),
      computed.length ? h("button.btn", { on: { click: (e) => updateMenu(e.currentTarget) } }, N.icon("zap"), "Update") : null,
      viewsButton,
      type.fragments.includes("core.notes") ? hideIgnored : null,
      columnsButton,
      lockButton,
      app.project.dataset ? h("button.btn", { on: { click: () => app.sync(entityType) } }, N.icon("sync"), "Sync") : null,
      h("button.btn.primary", { on: { click: () => N.views.methodDialog(app, entityType, grid.selectedRows()) } }, N.icon("play"), "Run method"));

    function columnMenu(column, anchor) {
      const items = [{ heading: column.title || column.name },
        { label: "Sort A → Z", icon: "sort-asc", onClick: () => grid.sortBy(column.name, 1) },
        { label: "Sort Z → A", icon: "sort-desc", onClick: () => grid.sortBy(column.name, -1) },
        { label: "Hide column", icon: "eye-off", onClick: () => grid.toggleColumn(column.name) },
        { label: "Filter…", icon: "filter", onClick: () => filterDialog(column) }];
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
        h("button.btn.small", { on: { click: (e) => pipelineMenu(e.currentTarget, grid.selectedRows()) } }, N.icon("layers", 14), "Pipeline"),
        h("button.btn.small", { on: { click: (e) => addToViewMenu(e.currentTarget, grid.selectedRows()) } }, N.icon("list", 14), "View"),
        app.info && app.info.workspace ? h("button.btn.small.send-workspace", {
          title: app.info.language === "matlab" ? "Put the selected entities in MATLAB's workspace" : "Put the selected entities in the Python session the app was opened from",
          on: { click: () => sendToWorkspace(grid.selectedRows()) } }, N.icon("download", 14), "To workspace") : null,
        h("button.btn.small", { on: { click: () => removeRows(grid.selectedRows()) } }, N.icon("trash", 14), "Remove from table"),
        h("button.btn.small", { on: { click: () => grid.clearSelection() } }, "Clear"));
    }
    async function sendToWorkspace(rows) {
      const name = await N.prompt("Send to the workspace", "Variable name", "entities");
      if (!name) return;
      try {
        const result = await app.client.request("workspace.send", { entityType, keys: rows.map((r) => r.key), name });
        N.toast("Sent to the workspace", `${result.count} ${entityType}(s) in ${result.name}`, "success");
      } catch (error) { N.showError(error, "Could not send them"); }
    }
    function addToViewMenu(anchor, rows) {
      const keys = rows.map((r) => r.key);
      const ids = new Set(keys.map((k) => N.keyId(k)));
      const items = [{ heading: `${rows.length} selected row(s)` }, { label: "New view with these rows…", icon: "plus", onClick: async () => {
        const name = await N.prompt("New view", "Name of the view", "");
        if (name) saveView({ name, keys });
      } }];
      const listed = views.filter((v) => v.keys);
      if (listed.length) items.push({ heading: "Add to" });
      for (const v of listed) {
        items.push({ label: v.name, icon: "list", onClick: () => {
          const merged = v.keys.concat(keys.filter((k) => !v.keys.some((x) => N.keyId(x) === N.keyId(k))));
          saveView(Object.assign({}, v, { keys: merged }));
        } });
      }
      if (activeView && activeView.keys) {
        items.push({ heading: activeView.name }, { label: `Remove from ${activeView.name}`, icon: "x", onClick: () =>
          saveView(Object.assign({}, activeView, { keys: activeView.keys.filter((k) => !ids.has(N.keyId(k))) })) });
      }
      N.menu(anchor, items);
    }
    async function pipelineMenu(anchor, rows) {
      const inTable = rows.filter((r) => r.inTable);
      const pipelines = await app.client.request("pipelines.list", { entityType }).catch((error) => { N.showError(error); return null; });
      if (!pipelines) return;
      const assign = async (pipeline) => {
        try {
          const result = await app.client.request("pipelines.assign", { entityType, keys: inTable.map((r) => r.key), pipelineId: pipeline ? pipeline.id : null });
          N.toast(pipeline ? "Pipeline assigned" : "Pipeline taken away", `${pipeline ? pipeline.title || pipeline.id : "None"}: ${result.assigned} row(s)`, "success");
          await app.reloadProject();
          app.reloadEntities();
        } catch (error) { N.showError(error, "Could not assign the pipeline"); }
      };
      const items = [{ heading: `Assign to ${inTable.length} row(s)` }];
      if (!inTable.length) items.push({ node: h("div.item.muted", "Only rows in the table get a pipeline") });
      else {
        for (const p of pipelines) items.push({ label: p.title || p.id, icon: "layers", onClick: () => assign(p) });
        items.push({ label: "No pipeline", icon: "x", onClick: () => assign(null) });
      }
      items.push({ heading: "Run" }, { label: "Queue the next steps", icon: "play", onClick: () => N.views.queueNext(app, entityType, rows.map((r) => r.key)) },
        { label: "Run the next step now", icon: "zap", onClick: () => N.views.runNextStep(app, entityType, rows.map((r) => r.key)) });
      N.menu(anchor, items);
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
    N.fill(content, toolbar, filterBar, body, footer);

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
    app.onViewsEvent = (data) => { if (data.entityType === entityType) loadViews(); };
    await Promise.all([app.reloadEntities(), loadViews()]);
    let remembered = "";
    try { remembered = localStorage.getItem(viewStoreKey) || ""; } catch (e) { /* fine */ }
    const view = views.find((v) => v.name === remembered);
    if (view) showView(view);
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
      // A folder's contents, read when it is opened; folders open in place
      const tree = (p) => {
        const el = h("ul.file-tree", h("li.muted", "Reading…"));
        app.client.request("files.list", where(p)).then((listing) => {
          N.fill(el, listing.entries.length ? listing.entries.map((entry) => {
            const child = p ? `${p}/${entry.name}` : entry.name;
            if (!entry.isFolder) {
              return h("li.file-entry", { dataset: { name: entry.name } }, N.icon("file", 13), h("span.name", entry.name),
                h("span.muted.size", N.fmt.bytes(entry.size)),
                h("button.btn.ghost.icon.small.open-file", { title: "Open in its app", on: { click: () => app.client.request("files.open", where(child))
                  .catch((error) => N.showError(error, "Could not open the file")) } }, N.icon("eye", 13)),
                pathActions(child));
            }
            let open = null;
            const row = h("li.folder-entry", { dataset: { name: entry.name } },
              h("button.tree-toggle", { title: "Open", on: { click: () => {
                if (open) { open.remove(); open = null; row.classList.remove("open"); return; }
                open = tree(child);
                row.after(open);
                row.classList.add("open");
              } } }, N.icon("chevron", 13), N.icon("folder", 13), h("span.name", entry.name)), pathActions(child));
            return row;
          }) : h("li.muted", "Empty folder"), listing.truncated ? h("li.muted", `Only the first ${listing.entries.length} are shown`) : null);
        }).catch((error) => N.fill(el, h("li.muted", error.code === "file-not-found" ? "Not there on this computer" : (error.message || String(error)))));
        return el;
      };
      const browse = (p, li) => h("button.btn.ghost.icon.small.browse", { title: "Show the files", on: { click: () => {
        const shown = li().nextElementSibling;
        if (shown && shown.classList.contains("file-tree")) { shown.remove(); return; }
        li().after(tree(p));
      } } }, N.icon("list", 13));
      return h("div.loc",
        h("div.loc-head", N.icon("folder", 14), loc.dataLocationIdentifier, h("span.muted", { style: { fontWeight: 400 } }, "· " + loc.rootStoragePathIdentifier),
          loc.isComplete === false ? h("span.pill.warn", "incomplete") : null),
        h("ul.path-list", (loc.paths || []).map((p) => {
          let li = null;
          li = h("li", h("span.path-text", p), browse(p, () => li), pathActions(p));
          return li;
        })),
        files.length ? h("dl.props", { style: { marginTop: "8px" } }, files.map(([name, paths]) => [h("dt", name),
          h("dd", paths.length ? paths.map((p) => h("div.mono", { style: { fontSize: "12px" } }, p.split("/").pop())) : h("span.muted", "none"))])) : null);
    });
    const data = (detail.data || []).map((d) => h("li", { dataset: { variable: d.name } }, h("span.dot." + (d.files.length ? "good" : "warn")),
      h("div.grow", h("div.title", d.name), h("div.sub", `${d.dataLocation} · ${d.fileAdapter}`)),
      h("span.pill.plain", d.files.length ? `${d.files.length} file(s)` : "not written"),
      d.files.length && app.info && app.info.workspace ? h("button.btn.ghost.icon.small.send-data", {
        title: "Load it into the workspace", on: { click: async () => {
          const name = await N.prompt(`Load ${d.name} into the workspace`, "Variable name", d.name);
          if (!name) return;
          try {
            const result = await app.client.request("data.send", { entityType, key: detail.key, variable: d.name, name });
            N.toast("Loaded into the workspace", result.name, "success");
          } catch (error) { N.showError(error, "Could not load it"); }
        } } }, N.icon("download", 13)) : null));
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
    const pipeline = detail.pipeline ? [h("div.section-title", "Pipeline"),
      h("div.card.pipeline-card",
        h("div.card-head", N.icon("layers", 15), h("h3", detail.pipeline.title), h("div.spacer"),
          h("span.pill" + (detail.pipeline.done === detail.pipeline.total ? ".good" : ".plain"), `${detail.pipeline.done}/${detail.pipeline.total}`)),
        h("ol.steps", detail.pipeline.steps.map((s) => h("li" + (s.done ? ".done" : ""),
          h("span.step-mark", s.done ? N.icon("check", 12) : null), h("div.grow", h("div.title", s.title), h("div.sub", s.method + (s.queueable === false ? " · run by hand" : ""))),
          s.done ? h("span.muted", N.fmt.ago(s.finishedAt)) : null))),
        detail.pipeline.done < detail.pipeline.total ? (() => {
          const next = detail.pipeline.steps.find((s) => !s.done);
          const runNow = h("button.btn.small" + (next.queueable === false ? ".primary" : "") + ".run-step", { on: { click: async () => {
            await N.views.runNextStep(app, entityType, [detail.key]);
            N.views.entityDrawer(app, entityType, detail.key);
          } } }, N.icon("zap", 14), `Run ${next.title} now`);
          return h("div.card-foot", next.queueable === false ? null :
            h("button.btn.small.primary", { on: { click: () => N.views.queueNext(app, entityType, [detail.key]) } }, N.icon("play", 14), "Queue the next steps"), runNow);
        })() : null)] : null;
    N.drawer.open(N.fmt.key(detail.key), (app.typeTitle(entityType)).replace(/s$/, ""),
      h("div",
        h("div", { style: { margin: "12px 0" } }, statusPill),
        h("div.section-title", "Values"), props,
        h("div.section-title", "Locations"), locations.length ? locations : h("div.muted", "Not found in any data location."),
        data.length ? [h("div.section-title", "Data"), h("ul.list.card", data)] : null,
        issues.length ? [h("div.section-title", "Issues"), h("ul.list.card", issues)] : null,
        pipeline,
        h("div.section-title", "Notes"), notesEl),
      actions);
    N.views.entityNotes(app, notesEl, entityType, detail.key);
  };

  /* ------------------------------------------------------------------ pipelines */
  N.views.queueNext = async function (app, entityType, keys) {
    try {
      const result = await app.client.request("pipelines.queueNext", { entityType, keys });
      const manual = result.manual || [];
      const manualNote = manual.length ? `${manual.length} wait for a step to run by hand (${[...new Set(manual.map((m) => m.title))].join(", ")}): use Run the next step now` : "";
      if (!result.tasks.length) {
        N.toast(manual.length ? "A step to run by hand comes next" : "Nothing to queue", manualNote ||
          `${result.skipped.length} entit${result.skipped.length === 1 ? "y has" : "ies have"} no pipeline, are done, or have steps queued already`, "info", 7000);
        return;
      }
      N.toast("Steps queued", `${result.tasks.length} task(s)` + (result.skipped.length ? `; ${result.skipped.length} skipped` : "") + (manualNote ? `; ${manualNote}` : ""), "success", manual.length ? 7000 : 4500);
      app.go("#/tasks");
    } catch (error) { N.showError(error, "Could not queue the steps"); }
  };

  /* Run each entity's next pipeline step now, in the foreground: for steps to run by hand, or to not wait for the queue. */
  N.views.runNextStep = async function (app, entityType, keys) {
    try {
      N.toast("Running", "the next step…");
      const result = await app.client.request("pipelines.runNext", { entityType, keys });
      if (!result.ran.length) {
        N.toast("Nothing to run", "No pipeline, all steps done, or steps waiting in the queue");
        return;
      }
      N.toast("Step done", `${[...new Set(result.ran.map((r) => r.method))].join(", ")} on ${result.ran.length} entit${result.ran.length === 1 ? "y" : "ies"}`, "success");
      if (app.reloadEntities) app.reloadEntities();
    } catch (error) { N.showError(error, "The step failed"); }
  };

  N.views.pipelines = async function (app, content) {
    app.onPipelinesEvent = () => { if (content.isConnected) app.render(); };
    let pipelines = [];
    try { pipelines = await app.client.request("pipelines.list"); } catch (error) { N.showError(error); }
    const typeTitle = (t) => (t === "*" ? "Any entity" : app.typeTitle(t));
    const card = (p) => h("div.card.pipeline", { dataset: { id: p.id } },
      h("div.card-head", N.icon("layers", 16), h("div.grow", h("h3", p.title || p.id), h("div.sub", `${p.id} · ${typeTitle(p.entityType)}`)),
        h("span.pill." + (p.source === "project" ? "accent" : "plain"), p.source === "project" ? "project" : "module"),
        h("button.btn.small", { on: { click: () => pipelineEditor(app, p) } }, N.icon(p.source === "project" ? "edit" : "copy", 14), p.source === "project" ? "Edit" : "Customize"),
        p.source === "project" ? h("button.btn.ghost.icon.small", { title: "Delete this pipeline", on: { click: async () => {
          if (!(await N.confirm("Delete the pipeline?", `${p.title || p.id} is deleted from the project.` +
            " Entities assigned to it keep the id; a module pipeline of the same id, if there is one, is used again.", "Delete", "danger"))) return;
          try { await app.client.request("pipelines.delete", { pipelineId: p.id }); N.toast("Pipeline deleted", p.title || p.id, "success"); app.render(); }
          catch (error) { N.showError(error, "Could not delete the pipeline"); }
        } } }, N.icon("trash", 14)) : null),
      p.description ? h("div.card-body.muted", p.description) : null,
      h("ol.steps", p.steps.map((s, i) => h("li", h("span.step-mark.n", String(i + 1)),
        h("div.grow", h("div.title", s.title), h("div.sub", s.method + (s.preset ? ` · preset ${s.preset}` : "")))))));
    N.fill(content,
      h("div.hero", h("div", h("h1", "Pipelines"), h("p", "Steps to take each entity through. Assign a pipeline to rows of a table, follow their progress there, and queue the steps that are left.")),
        h("div.spacer"), h("div.actions", h("button.btn.primary", { on: { click: () => pipelineEditor(app, null) } }, N.icon("plus"), "New pipeline"))),
      pipelines.length ? h("div.grid.two", pipelines.map(card))
        : h("div.empty", N.icon("layers", 40), h("h3", "No pipelines yet"), h("div", "Make one from the methods of the project's modules.")));
  };

  /** Make or change a project pipeline: an id, a title, the entity type, and its steps (method, title, preset). */
  async function pipelineEditor(app, existing) {
    const methods = app.methods || [];
    const types = ["*", ...app.project.entityTypes.map((t) => t.name)];
    const doc = existing ? JSON.parse(JSON.stringify(existing)) : { id: "", title: "", entityType: types[1] || "*", steps: [] };
    let steps = doc.steps.map((s) => ({ method: s.method, title: s.title || "", preset: s.preset || "", options: s.options }));
    const id = h("input.input", { value: doc.id, placeholder: "e.g. preprocess", disabled: !!existing && existing.source === "project" });
    const title = h("input.input", { value: doc.title || "" });
    const description = h("input.input", { value: doc.description || "" });
    const entityType = h("select.input", types.map((t) => h("option", { value: t, selected: t === doc.entityType }, t === "*" ? "Any entity" : app.typeTitle(t))));
    const stepsEl = h("ol.step-editor");
    const message = h("div.form-message.hidden");
    const fits = (m) => entityType.value === "*" ? m.entityType === "*" : (m.entityType === "*" || m.entityType === entityType.value);
    async function presetOptions(methodId) {
      if (!methodId) return [];
      const presets = await app.client.request("presets.list", { methodId }).catch(() => []);
      return presets.filter((p) => p.name !== "default").map((p) => p.name);
    }
    async function renderSteps() {
      const rows = await Promise.all(steps.map(async (step, i) => {
        const method = h("select.input", { on: { change: (e) => { step.method = e.target.value; step.preset = ""; renderSteps(); } } },
          h("option", { value: "" }, "Choose a method…"),
          methods.filter(fits).map((m) => h("option", { value: m.id, selected: m.id === step.method }, `${m.title} (${m.id})`)));
        const presets = await presetOptions(step.method);
        const preset = h("select.input", { disabled: !presets.length, on: { change: (e) => { step.preset = e.target.value; } } },
          h("option", { value: "" }, presets.length ? "Defaults" : "No presets"), presets.map((p) => h("option", { value: p, selected: p === step.preset }, p)));
        const stepTitle = h("input.input", { value: step.title, placeholder: "Title (the method's)", on: { input: (e) => { step.title = e.target.value; } } });
        const move = (d) => { const j = i + d; if (j < 0 || j >= steps.length) return; [steps[i], steps[j]] = [steps[j], steps[i]]; renderSteps(); };
        return h("li", h("span.step-mark.n", String(i + 1)), h("div.step-fields", method, stepTitle, preset),
          h("div.step-buttons",
            h("button.btn.ghost.icon.small", { type: "button", title: "Up", disabled: i === 0, on: { click: () => move(-1) } }, "↑"),
            h("button.btn.ghost.icon.small", { type: "button", title: "Down", disabled: i === steps.length - 1, on: { click: () => move(1) } }, "↓"),
            h("button.btn.ghost.icon.small", { type: "button", title: "Remove this step", on: { click: () => { steps.splice(i, 1); renderSteps(); } } }, N.icon("x", 13))));
      }));
      N.fill(stepsEl, rows, h("li.add", h("button.btn.small", { type: "button", on: { click: () => { steps.push({ method: "", title: "", preset: "" }); renderSteps(); } } }, N.icon("plus", 14), "Add a step")));
    }
    entityType.addEventListener("change", renderSteps);
    await renderSteps();
    const say = (text) => { message.textContent = text; message.classList.toggle("hidden", !text); };
    const field = (label, input, help) => h("div.field", h("label.name", label), input, help ? h("div.help", help) : null);
    N.dialog({
      title: existing ? (existing.source === "project" ? `Edit ${existing.title || existing.id}` : `Customize ${existing.title || existing.id}`) : "New pipeline",
      content: h("div.form-body", { style: { padding: "18px 20px", display: "grid", gap: "12px" } },
        existing && existing.source !== "project" ? h("div.muted", "The project gets its own copy, used instead of the module's.") : null,
        field("Id", id, "Lower case letters, digits, _ and dots"), field("Title", title), field("Description", description),
        field("Entity type", entityType), h("div.field", h("label.name", "Steps"), stepsEl), message),
      buttons: [{ label: "Cancel", onClick: (close) => close() }, { label: "Save pipeline", kind: "primary", onClick: async (close) => {
        const chosen = steps.filter((s) => s.method);
        if (!id.value.trim()) return say("Give the pipeline an id");
        if (!chosen.length) return say("Add at least one step with a method");
        const document = { schemaType: "nansen.pipeline", schemaVersion: "0.1.0", id: id.value.trim(),
          version: (existing && existing.version) || "1.0.0", entityType: entityType.value,
          steps: chosen.map((s) => Object.assign({ method: s.method }, s.title ? { title: s.title } : {}, s.preset ? { preset: s.preset } : {}, s.options ? { options: s.options } : {})) };
        if (title.value.trim()) document.title = title.value.trim();
        if (description.value.trim()) document.description = description.value.trim();
        try {
          await app.client.request("pipelines.save", { document });
          close();
          N.toast("Pipeline saved", document.title || document.id, "success");
          app.render();
        } catch (error) { say(error.message || String(error)); }
      } }],
    });
  }

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
        presets.map((p) => h("option", { value: p.name, selected: preset && p.name === preset.name },
          p.source === "module" ? `${p.name} (from ${p.module})` : p.name)));
      const save = h("button.btn", { on: { click: async () => {
        const name = await N.prompt("Save preset", "Preset name", "");
        if (!name) return;
        try {
          await app.client.request("presets.save", { methodId: method.id, name, values: form.getValue() });
          N.toast("Preset saved", name, "success");
          select(method, name);
        } catch (error) { N.showError(error, "Could not save the preset"); }
      } } }, "Save as…");
      const remove = preset && preset.source === "project" ? h("button.btn.ghost", { title: "Delete this preset", on: { click: async () => {
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
          method.module ? h("span.pill.plain", "module " + method.module) : null,
          method.module === "project" ? h("button.btn.small.ghost.edit-code", { title: "Open the method's code in an editor", on: { click: () =>
            app.client.request("methods.edit", { methodId: method.id }).then((r) => N.toast("Opened", r.path), (error) => N.showError(error, "Could not open the code")) } },
            N.icon("edit", 13), "Edit code") : null),
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
    // Queued tasks start in queue order: those given an order (by reordering) first, lowest first, then by creation
    const queuePosition = (t) => [t.order === undefined ? 1 : 0, t.order || 0, t.createdAt, t.id];
    const byQueuePosition = (a, b) => {
      const x = queuePosition(a), y = queuePosition(b);
      for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) return x[i] < y[i] ? -1 : 1;
      return 0;
    };
    function render() {
      renderControls();
      const queued = tasks.filter((t) => t.status === "queued").sort(byQueuePosition);
      const others = tasks.filter((t) => t.status !== "queued").reverse();
      N.fill(listEl, tasks.length ? [
        queued.length ? h("div.task-group", h("span", "Queue"), h("span.muted", `${queued.length} waiting · runs top to bottom`)) : null,
        queued.map((task, i) => renderTask(task, queued, i)),
        queued.length && others.length ? h("div.task-group", h("span", "Started and finished")) : null,
        others.map((task) => renderTask(task)),
      ] : h("div.empty", N.icon("tasks", 40), h("h3", "No tasks"), h("div", "Select entities in a table and run a method in the background.")));
      if (selectedId) showDetail(selectedId);
    }
    async function move(queued, index, by) {
      const ids = queued.map((t) => t.id);
      const [moved] = ids.splice(index, 1);
      ids.splice(index + by, 0, moved);
      try { await app.client.request("tasks.reorder", { ids }); } catch (error) { N.showError(error, "Could not move the task"); }
      load();
    }
    function editOptions(task) {
      const method = (app.methods || []).find((m) => m.id === task.method.id);
      if (!method) { N.toast("Unknown method", task.method.id, "error"); return; }
      const form = N.schemaForm(method.options || {}, task.options.values || {});
      const message = h("div.form-message.hidden");
      N.dialog({
        title: `Options of ${method.title}`,
        content: h("div", { style: { padding: "16px 20px" } },
          h("p.muted", { style: { marginTop: 0 } }, `For the queued task on ${task.entities.length} ${task.entities[0].entityType}(s). It runs with these when it starts.`),
          form.el, message),
        buttons: [
          { label: "Cancel" },
          { label: "Save", kind: "primary", onClick: async (close) => {
            const problems = form.validate();
            if (problems.length) { message.textContent = problems.join(" · "); message.classList.remove("hidden"); return; }
            try {
              await app.client.request("tasks.update", { id: task.id, options: form.getValue() });
              close();
              N.toast("Options changed", method.title, "success");
              load();
            } catch (error) {
              message.textContent = (error.code ? `[${error.code}] ` : "") + (error.message || String(error));
              message.classList.remove("hidden");
            }
          } },
        ],
      });
    }
    function renderTask(task, queued, index) {
      const pct = Math.round((task.progress || 0) * 100);
      const stop = (fn) => (e) => { e.stopPropagation(); fn(); };
      const queueActions = queued ? [
        h("button.btn.small.ghost.icon.move-up", { title: "Move up", disabled: index === 0, on: { click: stop(() => move(queued, index, -1)) } }, N.icon("arrow-up", 14)),
        h("button.btn.small.ghost.icon.move-down", { title: "Move down", disabled: index === queued.length - 1, on: { click: stop(() => move(queued, index, 1)) } }, N.icon("arrow-down", 14)),
        h("button.btn.small.ghost.icon.edit-options", { title: "Change the options", on: { click: stop(() => editOptions(task)) } }, N.icon("edit", 14)),
        h("button.btn.small" + (task.onHold ? ".release" : ".hold"), { title: task.onHold ? "Let it start" : "Keep it from starting; it keeps its place",
          on: { click: stop(async () => {
            try { await app.client.request("tasks.hold", { id: task.id, hold: !task.onHold }); } catch (error) { N.showError(error); }
            load();
          }) } }, N.icon(task.onHold ? "play" : "pause", 14), task.onHold ? "Release" : "Hold"),
      ] : null;
      const progressClass = task.status === "completed" ? ".done" : task.status === "failed" ? ".failed" : "";
      const el = h("div.task" + (task.id === selectedId ? ".selected" : ""), { dataset: { id: task.id }, on: { click: () => { selectedId = task.id; app.replace("#/tasks/" + task.id); render(); } } },
        h("div",
          h("div.title", N.statusPill(task.status), task.onHold && task.status === "queued" ? h("span.pill.warn", "on hold") : null,
            task.pipeline ? [h("span.pill.accent.plain", `${task.pipeline.id} ${task.pipeline.step + 1}/${task.pipeline.steps}`), task.pipeline.title || app.methodTitle(task.method.id)] : app.methodTitle(task.method.id),
            h("span.muted", { style: { fontWeight: 400 } }, `· ${task.entities.length} ${task.entities[0].entityType}(s)`)),
          h("div.sub", [
            `queued ${N.fmt.time(task.createdAt)}`,
            task.startedAt ? `ran ${N.fmt.duration(task.startedAt, task.finishedAt)}` : null,
            task.message && task.status === "running" ? task.message : null,
            task.error ? task.error.message : null,
          ].filter(Boolean).join(" · "))),
        h("div.actions", queueActions,
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
        h("div.card.data-locations", h("div.card-head", N.icon("database"), h("h3", "Data locations"), h("div.spacer"),
          dataset ? h("span.muted", `environment: ${dataset.environment || "default"}`) : null,
          dataset ? h("button.btn.small.edit-config", { title: "Edit the dataset config: locations, folder levels, file patterns, naming rules",
            on: { click: () => datasetConfigDialog(app) } }, N.icon("edit", 14), "Edit config") : null),
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
        h("div.card.data-variables", h("div.card-head", N.icon("file"), h("h3", "Data variables"), h("div.spacer"),
          dataset && project.entityTypes.length ? h("button.btn.small.add-variable", { on: { click: () => dataVariableDialog(app) } }, N.icon("plus"), "Add data variable") : null),
          variables.length ? h("table.simple", h("thead", h("tr", ["Name", "Entity", "Location", "File", "Adapter", ""].map((t) => h("th", t)))),
            h("tbody", variables.map((v) => h("tr", { dataset: { variable: v.name } }, h("td", h("b", v.title || v.name), v.title ? h("div.muted.mono", v.name) : null),
              h("td", v.entityType), h("td", v.dataLocation),
              h("td.mono", [v.subfolder ? v.subfolder + "/" : "", v.fileName || `pattern ${v.filePattern}`].join(""),
                v.fileName && v.filePattern ? h("div.muted", `found by pattern ${v.filePattern}`) : null),
              h("td", v.fileAdapter),
              h("td.row-actions",
                h("button.btn.ghost.icon.small.edit-variable", { title: "Edit", on: { click: () => dataVariableDialog(app, v) } }, N.icon("edit", 14)),
                h("button.btn.ghost.icon.small.delete-variable", { title: "Delete", on: { click: async () => {
                  if (!await N.confirm("Delete the data variable?", `${v.name} is taken out of the project. Its files are not touched.`, "Delete", "danger")) return;
                  try {
                    await app.client.request("dataVariables.delete", { name: v.name });
                    app.render();
                    N.toast("Data variable deleted", v.name, "success");
                  } catch (error) { N.showError(error, "Could not delete the data variable"); }
                } } }, N.icon("trash", 14))))))) :
            h("div.card-body.muted", dataset ? "No data variables. A data variable names a file of each entity, so methods can load and save it." : "No data variables.")),
        h("div.grid.two",
          h("div.card", h("div.card-head", N.icon("columns"), h("h3", "Fragments")),
            h("ul.list", fragments.map((f) => h("li", h("div.grow", h("div.title", f.title, f.computed ? h("span.pill.accent", { style: { marginLeft: "8px" } }, "computed") : null),
              h("div.sub", `${f.id} ${f.version} · ${f.columns.map((c) => c.name).join(", ")}`)))))),
          h("div.card.methods-card", h("div.card-head", N.icon("zap"), h("h3", "Methods"), h("div.spacer"),
            h("button.btn.small.new-method", { on: { click: () => newMethodDialog(app) } }, N.icon("plus", 14), "New method")),
            h("ul.list", methods.map((m) => h("li", h("div.grow", h("div.title", m.title), h("div.sub", `${m.id} · ${m.tool ? "project tool" : m.entityType === "*" ? "any entity" : m.entityType} · ${m.languages.join(", ")}`)))))))));
  };

  /* ------------------------------------------------------------------ settings */
  N.views.settings = async function (app, content) {
    let settings = await app.client.request("settings.get").catch(() => ({ queue: { autoStart: true } }));
    const save = async (changes) => {
      try {
        settings = await app.client.request("settings.save", { settings: changes });
        N.toast("Setting saved", "", "success", 2000);
      } catch (error) { N.showError(error, "Could not save the setting"); }
    };
    const toggle = (cls, checked, onChange) => {
      const input = h("input", { type: "checkbox", checked, on: { change: () => onChange(input.checked) } });
      return h("label.switch." + cls, input, h("span"));
    };
    const row = (title, sub, control) => h("li", h("div.grow", h("div.title", title), h("div.sub", sub)), control);
    const theme = h("select.input.theme-select", { style: { width: "180px" }, on: { change: () => { N.theme.save(theme.value); N.theme.apply(theme.value); } } },
      [["auto", "Follow the system"], ["light", "Light"], ["dark", "Dark"]].map(([v, label]) => h("option", { value: v, selected: N.theme.load() === v }, label)));
    let locked = false;
    try { locked = JSON.parse(localStorage.getItem("nansen.locked") || "false") === true; } catch (e) { /* fine */ }
    N.fill(content,
      h("div.hero", h("div", h("h1", "Settings"), h("p", "How the app behaves for you. Worker settings are kept with your project list; how the dashboard looks is kept in this browser."))),
      h("div.grid",
        h("div.card", h("div.card-head", N.icon("tasks"), h("h3", "Tasks")),
          h("ul.list", row("Start the worker when a project opens", "Queued tasks then run on their own; otherwise start it on the Tasks page. Takes effect the next time the app starts.",
            toggle("auto-start", settings.queue.autoStart, (on) => save({ queue: { autoStart: on } }))))),
        h("div.card", h("div.card-head", N.icon("eye"), h("h3", "Dashboard")),
          h("ul.list",
            row("Theme", "Light, dark, or as the system is set", theme),
            row("Lock editing", "Values cannot be changed in the tables until this is off (also the lock in each table's toolbar)",
              toggle("lock-setting", locked, (on) => { try { localStorage.setItem("nansen.locked", JSON.stringify(on)); } catch (e) { /* fine */ } })),
            row("Keyboard shortcuts", "Press ? anywhere, or the keyboard button at the top", h("button.btn.small", { on: { click: () => N.showShortcuts() } }, N.icon("keyboard", 14), "Show"))))));
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

  /* Add or edit a data variable: which file of each entity it is, and the file adapter that reads it. */
  function dataVariableDialog(app, existing) {
    const v = existing || {};
    const types = app.project.entityTypes.map((t) => t.name);
    const select = (name, options, value) => h(`select.input.${name}`, options.map(([id, label]) =>
      h("option", { value: id, selected: id === value }, label)));
    const field = (label, input, help) => h("div.field", h("label.name", label), input, help ? h("div.help", help) : null);
    const name = h("input.input.variable-name", { value: v.name || "", disabled: !!existing, placeholder: "roi_signals" });
    const title = h("input.input.variable-title", { value: v.title || "" });
    const entityType = select("variable-entity", types.map((t) => [t, t]), v.entityType || types[types.length - 1]);   // the innermost type usually has the files
    const location = h("select.input.variable-location");
    const pattern = h("select.input.variable-pattern");
    const subfolder = h("input.input.variable-subfolder", { value: v.subfolder || "", placeholder: "for example roi" });
    const fileName = h("input.input.variable-file", { value: v.fileName || "", placeholder: "{session_id}_roi_signals.mat" });
    const adapter = h("select.input.variable-adapter");
    const description = h("input.input.variable-description", { value: v.description || "" });
    const message = h("div.form-message.hidden");
    let options = { locations: [], fileAdapters: [] };

    const fillPatterns = (chosen) => {
      const loc = options.locations.find((l) => l.id === location.value);
      const names = loc ? loc.filePatterns : [];
      N.fill(pattern, h("option", { value: "" }, names.length ? "(none: use the file name)" : "(this level has no file patterns)"),
        names.map((p) => h("option", { value: p, selected: p === chosen }, p)));
    };
    const loadOptions = async (keep) => {
      try {
        options = await app.client.request("dataVariables.options", { entityType: entityType.value });
      } catch (error) { N.showError(error, "Could not read the data locations"); return; }
      const wanted = keep ? v.dataLocation : location.value;
      N.fill(location, options.locations.map((l) => h("option", { value: l.id, selected: l.id === wanted },
        `${l.title}${l.access === "readwrite" ? "" : " (read only)"}`)));
      fillPatterns(keep ? v.filePattern : pattern.value);
      const adapterWanted = keep ? v.fileAdapter : adapter.value;
      N.fill(adapter, options.fileAdapters.map((a) => h("option", { value: a, selected: a === adapterWanted }, a)));
    };
    entityType.addEventListener("change", () => loadOptions(false));
    location.addEventListener("change", () => fillPatterns(""));

    N.dialog({
      title: existing ? `Edit ${v.name}` : "Add a data variable",
      content: h("div.variable-form", { style: { padding: "16px 20px" } },
        h("p.muted", { style: { marginTop: 0 } }, "A data variable is one file of each entity. It is found by a file pattern of the dataset, or at the file name below in the entity's folder; saving writes it at the file name."),
        field("Name", name, "A letter, then letters, digits or _"), field("Title", title),
        h("div.field-row", field("Entity type", entityType), field("Data location", location)),
        field("File pattern", pattern, "A pattern of the dataset at the entity type's level; reading uses the files the scan matched to it"),
        h("div.field-row", field("Subfolder", subfolder), field("File name", fileName, "{field} is filled from the entity's values")),
        field("File adapter", adapter, "Reads and writes the file"), field("Description", description), message),
      buttons: [
        { label: "Cancel" },
        { label: existing ? "Save" : "Add data variable", kind: "primary", onClick: async (close) => {
          const document = { schemaType: "nansen.dataVariable", schemaVersion: "0.1.0", name: name.value.trim(),
            entityType: entityType.value, dataLocation: location.value, fileAdapter: adapter.value };
          for (const [key, input] of [["title", title], ["filePattern", pattern], ["subfolder", subfolder], ["fileName", fileName], ["description", description]]) {
            if (input.value.trim()) document[key] = input.value.trim();
          }
          if (existing && v.dataType) document.dataType = v.dataType;
          const problems = [];
          if (!/^[A-Za-z][A-Za-z0-9_]*$/.test(document.name)) problems.push("Name: a letter, then letters, digits or _");
          if (!document.filePattern && !document.fileName) problems.push("Give a file pattern or a file name");
          if (!document.dataLocation) problems.push("Choose a data location");
          if (problems.length) {
            message.textContent = problems.join(" · ");
            message.classList.remove("hidden");
            return;
          }
          try {
            await app.client.request("dataVariables.save", { document });
            close();
            app.render();
            N.toast(existing ? "Data variable saved" : "Data variable added", document.name, "success");
          } catch (error) {
            message.textContent = (error.code ? `[${error.code}] ` : "") + (error.message || String(error));
            message.classList.remove("hidden");
          }
        } },
      ],
    });
    loadOptions(true);
  }

  /* The project's title and description, and what its tables are called. */
  function editProjectDialog(app) {
    const project = app.project;
    const properties = {
      title: { type: "string", title: "Title", description: `Empty for the name, ${project.name}` },
      description: { type: "string", title: "Description" },
    };
    const values = { title: project.title === project.name ? "" : project.title, description: project.description || "" };
    for (const type of project.entityTypes) {
      properties["type_" + type.name] = { type: "string", title: `Name of the ${type.name} table`, description: "Empty for the default" };
      values["type_" + type.name] = type.title && type.title !== type.name ? type.title : "";
    }
    const form = N.schemaForm({ type: "object", properties }, values);
    const message = h("div.form-message.hidden");
    N.dialog({
      title: "Project details",
      content: h("div", { style: { padding: "16px 20px" } }, form.el, message),
      buttons: [
        { label: "Cancel" },
        { label: "Save", kind: "primary", onClick: async (close) => {
          const entered = form.getValue();
          const entityTypeTitles = {};
          for (const type of project.entityTypes) entityTypeTitles[type.name] = entered["type_" + type.name] || "";
          try {
            app.project = await app.client.request("project.update", { title: entered.title || "", description: entered.description || "", entityTypeTitles });
            close();
            await app.reloadProject();
            app.render();
            N.toast("Project details saved", app.project.title, "success");
          } catch (error) {
            message.textContent = (error.code ? `[${error.code}] ` : "") + (error.message || String(error));
            message.classList.remove("hidden");
          }
        } },
      ],
    });
  }

  /* Run a project tool: its options, then what it returned and logged. */
  function toolDialog(app, method) {
    const form = N.schemaForm(method.options || {}, {});
    const output = h("div.tool-output.hidden");
    let running = false;
    const d = N.dialog({
      title: method.title,
      content: h("div", { style: { padding: "16px 20px" } },
        method.description ? h("p.muted", { style: { marginTop: 0 } }, method.description) : null,
        Object.keys((method.options || {}).properties || {}).length ? form.el : h("p.muted", "It has no options."), output),
      buttons: [
        { label: "Close" },
        { label: "Run", kind: "primary", icon: "play", onClick: async () => {
          if (running) return;
          const problems = form.validate();
          if (problems.length) { N.toast("Check the options", problems.join("; "), "error"); return; }
          running = true;
          N.fill(output, h("div.muted", "Running…"));
          output.classList.remove("hidden");
          try {
            const answer = await app.client.request("tools.run", { methodId: method.id, options: form.getValue() });
            N.fill(output,
              h("div.section-title", "Result"), h("pre.log.tool-result", JSON.stringify(answer.result, null, 2)),
              h("div.section-title", "Log"), h("pre.log", answer.log.length ? answer.log.join("\n") : "(nothing logged)"));
            if (app.reloadEntities) app.reloadEntities();
          } catch (error) {
            N.fill(output, h("div.form-message", (error.code ? `[${error.code}] ` : "") + (error.message || String(error))));
          } finally { running = false; }
        } },
      ],
    });
    return d;
  }

  /* Start a project method: its document and a file per language to fill in. */
  function newMethodDialog(app) {
    const types = app.project.entityTypes.map((t) => t.name);
    formDialog({
      title: "New method",
      intro: "NANSEN writes the method's document into methods/ and an empty function for each language, in the project's python/ and matlab/ folders. Fill in the function, and add options to the document; the method is then in the run dialog.",
      label: "Create",
      required: ["id"],
      schema: { type: "object", properties: {
        id: { type: "string", title: "Id", description: "A lower-case letter, then letters, digits or _; also the file and function name", pattern: "^[a-z][a-z0-9_]*$" },
        title: { type: "string", title: "Title" },
        entityType: { type: "string", title: "Runs on", enum: ["*", ...types, "@project"], default: types[types.length - 1] || "*",
          description: "An entity type, * for any, or @project for a tool that runs once on the project" },
        batchMode: { type: "string", title: "Runs", enum: ["serial", "batch"], default: "serial", description: "serial: once per entity; batch: once with all of them" },
        python: { type: "boolean", title: "Python", default: true },
        matlab: { type: "boolean", title: "MATLAB", default: true },
        description: { type: "string", title: "Description" },
      } },
      submit: async (values) => {
        const languages = ["python", "matlab"].filter((l) => values[l]);
        if (!languages.length) throw new Error("Choose Python, MATLAB or both");
        const result = await app.client.request("methods.create", { id: values.id, title: values.title || "",
          entityType: values.entityType, batchMode: values.batchMode, description: values.description || "", languages });
        await app.reloadProject();
        app.render();
        N.toast("Method created", result.files.join(" · "), "success", 7000);
      },
    });
  }

  /* The DSM config as text. DSM checks it before it is written, so a config it refuses is never kept. */
  async function datasetConfigDialog(app) {
    let got;
    try { got = await app.client.request("dataset.get"); } catch (error) { N.showError(error, "Could not read the dataset config"); return; }
    const editor = h("textarea.input.mono.config-text", { spellcheck: false, style: { width: "100%", height: "52vh", resize: "vertical", fontSize: "12.5px", lineHeight: "1.45", tabSize: "2" } });
    editor.value = got.text;
    const message = h("div.form-message.hidden");
    const status = h("span.muted.config-status");
    const check = () => {
      try { JSON.parse(editor.value); status.textContent = "Valid JSON"; status.className = "muted config-status"; }
      catch (error) { status.textContent = "Not valid JSON: " + error.message; status.className = "config-status bad-text"; }
    };
    editor.addEventListener("input", check);
    editor.addEventListener("keydown", (event) => {   // Tab indents instead of leaving the editor
      if (event.key !== "Tab") return;
      event.preventDefault();
      const start = editor.selectionStart;
      editor.setRangeText("  ", start, editor.selectionEnd, "end");
      check();
    });
    check();
    N.dialog({
      title: "Dataset config",
      content: h("div", { style: { padding: "14px 20px" } },
        h("p.muted", { style: { marginTop: 0 } }, "The project's ", h("span.mono", got.path),
          ": data locations, their roots, folder levels, file patterns and how names are read. DSM checks it before it is saved, and the tables' keys must still match the identity it gives; otherwise nothing changes. The same file is read by DSM's own tools."),
        editor, h("div", { style: { marginTop: "6px" } }, status), message),
      buttons: [
        { label: "Cancel" },
        { label: "Save", kind: "primary", onClick: async (close) => {
          try {
            app.project = await app.client.request("dataset.save", { text: editor.value });
            close();
            await app.reloadProject();
            app.render();
            N.toast("Dataset config saved", "Scan the stores to see what it finds", "success");
          } catch (error) {
            message.textContent = (error.code ? `[${error.code}] ` : "") + (error.message || String(error));
            message.classList.remove("hidden");
          }
        } },
      ],
    });
    editor.focus();
  }

  /* The modules the project can list: those in its modules folder and the built-in ones. */
  async function modulesDialog(app) {
    const body = h("div.modules-list", { style: { padding: "8px 0" } });
    const draw = async () => {
      let modules;
      try { modules = await app.client.request("modules.list"); } catch (error) { N.showError(error, "Could not list the modules"); return; }
      N.fill(body, modules.length ? h("ul.list", modules.map((m) => h("li", { dataset: { module: m.id } }, N.icon("puzzle"),
        h("div.grow", h("div.title", m.title || m.id, h("span.muted.mono", { style: { marginLeft: "8px" } }, `${m.id} ${m.version}`)),
          h("div.sub", m.description || "")),
        m.listed ? h("button.btn.small.remove-module", { on: { click: async () => {
          try {
            app.project = await app.client.request("modules.remove", { id: m.id });
            await app.reloadProject();
            N.toast("Module removed", m.title || m.id, "success");
            draw();
          } catch (error) { N.showError(error, "Could not remove the module"); }
        } } }, "Remove") : h("button.btn.small.primary.add-module", { on: { click: async () => {
          try {
            app.project = await app.client.request("modules.add", { id: m.id });
            await app.reloadProject();
            N.toast("Module added", m.title || m.id, "success");
            draw();
          } catch (error) { N.showError(error, "Could not add the module"); }
        } } }, "Add")))) : h("div.card-body.muted", "No modules found."));
    };
    N.dialog({
      title: "Modules",
      content: h("div", h("p.muted", { style: { margin: "14px 20px 0" } },
        "A module brings fragments, methods, file adapters and pipelines. Modules are found in the project's ",
        h("span.mono", "modules"), " folder and among those that come with NANSEN. A module cannot be removed while the project uses what it provides."), body),
      buttons: [{ label: "Close", onClick: (close) => { close(); app.render(); } }],
      onClose: () => app.render(),
    });
    draw();
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
