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
    })) : h("div.card-body.muted", "This project has no dataset (DSM config), so entities come only from its tables.");

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
        h("div", h("h1", project.title), project.description ? h("p", project.description) : null, h("div.path", project.folder)),
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
      N.menu(columnsButton, items);
    });
    const computed = (app.fragments || []).filter((f) => f.computed && type.fragments.includes(f.id));
    const toolbar = h("div.toolbar",
      h("div.search", N.icon("search", 14), search), chips, h("div.spacer"),
      computed.length ? h("button.btn", { on: { click: (e) => updateMenu(e.currentTarget) } }, N.icon("zap"), "Update") : null,
      columnsButton,
      app.project.dataset ? h("button.btn", { on: { click: () => app.sync(entityType) } }, N.icon("sync"), "Sync") : null,
      h("button.btn.primary", { on: { click: () => N.views.methodDialog(app, entityType, grid.selectedRows()) } }, N.icon("play"), "Run method"));

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
        h("button.btn.small", { on: { click: () => grid.clearSelection() } }, "Clear"));
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
      return h("div.loc",
        h("div.loc-head", N.icon("folder", 14), loc.dataLocationIdentifier, h("span.muted", { style: { fontWeight: 400 } }, "· " + loc.rootStoragePathIdentifier),
          loc.isComplete === false ? h("span.pill.warn", "incomplete") : null),
        h("ul.path-list", (loc.paths || []).map((p) => h("li", p))),
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
    N.drawer.open(N.fmt.key(detail.key), (app.typeTitle(entityType)).replace(/s$/, ""),
      h("div",
        h("div", { style: { margin: "12px 0" } }, statusPill),
        h("div.section-title", "Values"), props,
        h("div.section-title", "Locations"), locations.length ? locations : h("div.muted", "Not found in any data location."),
        data.length ? [h("div.section-title", "Data"), h("ul.list.card", data)] : null,
        issues.length ? [h("div.section-title", "Issues"), h("ul.list.card", issues)] : null),
      actions);
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
      N.fill(detail, 
        h("h3", method.title),
        h("div.muted", method.description || ""),
        h("div.meta",
          h("span.pill.plain", method.id + " " + method.version),
          h("span.pill.accent", method.batchMode === "batch" ? "once for all" : "once per entity"),
          method.languages.map((l) => h("span.pill.plain", l)),
          method.module ? h("span.pill.plain", "module " + method.module) : null),
        h("div.preset-row", h("label.name", { style: { fontWeight: 600 } }, "Preset"), presetSelect, save),
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
          dataset ? h("table.simple", h("thead", h("tr", ["Location", "Category", "Access", "Root", ""].map((t) => h("th", t)))),
            h("tbody", dataset.roots.map((root) => {
              const loc = dataset.locations.find((l) => l.id === root.dataLocation) || {};
              return h("tr", h("td", h("b", loc.title || root.dataLocation), h("div.muted.mono", root.dataLocation)), h("td", loc.category),
                h("td", loc.access), h("td.mono", root.path), h("td", h("span.pill." + (root.available ? "good" : "bad"), root.available ? "available" : "offline")));
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
