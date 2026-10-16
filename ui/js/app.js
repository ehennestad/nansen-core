/* The app shell: sidebar, top bar, routing, and live updates from core events. */
(function () {
  "use strict";
  const N = window.N;
  const { h } = N;
  const REPOSITORY = "https://github.com/ehennestad/nansen-core";   // the help pages and the issue tracker

  const app = {
    client: null,
    info: null,
    project: null,
    fragments: [],
    methods: [],
    route: null,
    runningTasks: 0,
    viewables: [],   // what `nansen view` or nansen.view was given to view without a project (view.list)
    reloadEntities: null,
    onTaskEvent: null,
    onTaskRemoved: null,
    onLogEvent: null,
    onNotesEvent: null,
    onDrawerNotesEvent: null,

    go(hash) { if (location.hash === hash) this.render(); else location.hash = hash; },
    replace(hash) { history.replaceState(null, "", hash); },
    typeTitle(name) {
      const type = this.project && this.project.entityTypes.find((t) => t.name === name);
      return (type && type.title) || N.titleCase(name);
    },
    methodTitle(id) {
      const method = this.methods.find((m) => m.id === id);
      return method ? method.title : id;
    },

    async start() {
      applyTheme(loadTheme());
      N.tableSize.apply(N.tableSize.load());
      N.clear(document.getElementById("app")).appendChild(h("div.empty", { style: { paddingTop: "30vh" } }, "Connecting…"));
      const transport = await N.connect();
      this.client = new N.Client(transport);
      this.transport = transport;
      transport.onStatus((ok) => { this.connected = ok; this.renderFooter(); });
      try {
        this.info = await this.client.request("app.info");
      } catch (error) {
        N.clear(document.getElementById("app")).appendChild(h("div.empty", { style: { paddingTop: "30vh" } },
          h("h3", "Cannot reach the NANSEN core"), String(error.message || error)));
        return;
      }
      await N.loadTableDefaults(this.client);
      this.client.on("task", (task) => this.taskEvent(task));
      this.client.on("removed", (data) => { if (this.onTaskRemoved) this.onTaskRemoved(data); this.refreshTaskCount(); });
      this.client.on("log", (event) => this.onLogEvent && this.onLogEvent(event));
      this.client.on("entities", (data) => this.entitiesEvent(data));
      this.client.on("pipelines", () => this.onPipelinesEvent && this.onPipelinesEvent());
      this.client.on("views", (data) => this.onViewsEvent && this.onViewsEvent(data));
      this.client.on("notes", (data) => {   // the page and an entity's drawer can both show notes
        if (this.onNotesEvent) this.onNotesEvent(data);
        if (this.onDrawerNotesEvent) this.onDrawerNotesEvent(data);
        if (data && data.entityType) this.entitiesEvent({ entityTypes: [data.entityType] });   // the table's note counts
      });
      this.client.on("scan", () => this.reloadProject());
      this.client.on("project", () => this.reloadProject().then(() => this.render()));
      try { this.viewables = await this.client.request("view.list"); } catch (error) { this.viewables = []; }
      await this.reloadProject();
      this.renderShell();
      window.addEventListener("hashchange", () => this.render());
      // opened to view files or arrays (nansen view): straight into the viewer
      if (!location.hash) location.hash = this.viewables.length ? `#/view/${this.viewables[0].id}` : this.project ? "#/overview" : "#/projects";
      else this.render();
    },

    async reloadProject() {
      try {
        this.project = await this.client.request("project.info");
        [this.fragments, this.methods] = await Promise.all([
          this.client.request("fragments.list"), this.client.request("methods.list")]);
        await this.loadPlugins();
      } catch (error) {
        if (error.code !== "no-project") N.showError(error);
        this.project = null;
        N.pages = {};
        this.pluginSignature = null;
      }
      this.renderNav();
      await this.refreshTaskCount();
    },

    /** Run the dashboard scripts of the project's modules (again only when they changed); they add pages. */
    async loadPlugins() {
      let plugins = [];
      try { plugins = await this.client.request("app.plugins"); } catch (error) { plugins = []; }
      const signature = JSON.stringify(plugins);
      if (signature === this.pluginSignature) return;
      this.pluginSignature = signature;
      N.pages = {};
      for (const plugin of plugins) {
        try {
          new Function("N", "module", plugin.code)(N, plugin.module);  // eslint-disable-line no-new-func
        } catch (error) { N.showError(error, `The ${plugin.module} module's ${plugin.path} failed`); }
      }
    },

    async refreshTaskCount() {
      if (!this.project) return;
      try {
        const status = await this.client.request("queue.status");
        this.runningTasks = (status.counts.running || 0) + (status.counts.queued || 0);
      } catch (error) { this.runningTasks = 0; }
      this.renderNav();
    },

    taskEvent(task) {
      if (this.onTaskEvent) this.onTaskEvent(task);
      if (task.status === "completed" || task.status === "failed") {
        const entityType = task.entities[0].entityType;
        if (this.route && this.route.name === "entities" && this.route.arg === entityType && this.reloadEntities) this.reloadEntities();
        if (task.status === "failed") N.toast("Task failed", `${this.methodTitle(task.method.id)}: ${task.error ? task.error.message : ""}`, "error");
        else N.toast("Task completed", this.methodTitle(task.method.id), "success", 3000);
      }
      this.refreshTaskCount();
    },

    entitiesEvent(data) {
      if (this.route && this.route.name === "entities" && this.reloadEntities &&
          (!data.entityTypes || data.entityTypes.includes(this.route.arg))) {
        clearTimeout(this.entitiesTimer);
        this.entitiesTimer = setTimeout(() => { if (this.reloadEntities) this.reloadEntities(); }, 150);   // the table may be gone by then
      }
    },

    async openProject(path) {
      if (!path) return;
      this.project = await this.client.request("project.open", { path });
      await this.reloadProject();
      this.go("#/overview");
    },

    async scan() {
      try {
        N.toast("Scanning the stores…");
        const result = await this.client.request("project.scan");
        const counts = Object.entries(result.records).map(([type, n]) => `${n} ${type}`).join(", ");
        N.toast("Scan finished", counts || "no entities found", "success");
        await this.reloadProject();
        this.render();
      } catch (error) { N.showError(error, "Scan failed"); }
    },

    async sync(entityType) {
      try {
        const params = entityType ? { entityType } : {};
        const result = await this.client.request("project.sync", params);
        const added = Object.values(result.added).reduce((n, keys) => n + keys.length, 0);
        N.toast("Tables synced", added ? `${added} new row(s) added` : "Nothing new", "success");
        await this.reloadProject();
        this.render();
      } catch (error) { N.showError(error, "Sync failed"); }
    },

    /* ---------------- shell ---------------- */
    renderShell() {
      const root = N.clear(document.getElementById("app"));
      this.navEl = h("nav.nav");
      this.footEl = h("div.sidebar-foot");
      this.switchEl = h("button.project-switch", { on: { click: () => this.go("#/projects") } });
      this.crumbsEl = h("div.crumbs");
      this.contentEl = h("div.content");
      this.loadingEl = h("div.page-loading", { role: "progressbar", "aria-label": "Loading the page", "aria-hidden": "true" });
      const themeButton = h("button.btn.ghost.icon", { title: "Light or dark", on: { click: () => {
        const next = { auto: "dark", dark: "light", light: "auto" }[loadTheme()];
        saveTheme(next);
        applyTheme(next);
        N.toast("Theme", next === "auto" ? "Follow the system" : next);
      } } }, N.icon("moon"));
      this.topActions = h("div", { style: { display: "flex", gap: "8px" } });
      // the Help menu, as dev's: the shortcuts, the guides, and where to report a problem (pages open in the system's browser)
      const page = (url) => () => this.client.request("app.openUrl", { url }).catch((error) => N.showError(error, "Could not open the page"));
      const helpButton = h("button.btn.ghost.icon.shortcuts-button.help-button", { title: "Help", on: { click: () => N.menu(helpButton, [
        { label: "Keyboard shortcuts (?)", icon: "keyboard", onClick: () => N.showShortcuts() },
        { label: "Getting started", icon: "compass", onClick: page(`${REPOSITORY}/blob/main/docs/getting-started.md`) },
        { label: "Documentation", icon: "note", onClick: page(`${REPOSITORY}/tree/main/docs`) },
        { label: "Report a problem…", icon: "alert", onClick: page(`${REPOSITORY}/issues/new`) },
      ]) } }, N.icon("keyboard"));
      // below 860 px the sidebar slides in over the page, from this button
      const menuButton = h("button.btn.ghost.icon.menu-button", { title: "Menu", on: { click: () => this.shellEl.classList.toggle("nav-open") } }, N.icon("menu"));
      root.appendChild(this.shellEl = h("div.shell",
        h("div.nav-backdrop", { on: { click: () => this.shellEl.classList.remove("nav-open") } }),
        h("aside.sidebar",
          h("div.brand", h("div.brand-mark", N.icon("compass", 18)), h("div", h("div.brand-name", "NANSEN"), h("div.brand-sub", "neuroscience data"))),
          this.switchEl, this.navEl, this.footEl),
        h("main.main", h("header.topbar", menuButton, this.crumbsEl, h("div.spacer"), this.topActions, helpButton, themeButton), this.loadingEl, this.contentEl)));
      this.bindShortcuts();
      this.renderNav();
      this.renderFooter();
    },

    bindShortcuts() {
      if (this.shortcutsBound) return;
      this.shortcutsBound = true;
      let pending = null;   // "g", waiting for the second key
      const pages = { o: "#/overview", t: "#/tasks", d: "#/data", p: "#/pipelines", n: "#/notes", j: "#/projects", s: "#/settings" };
      document.addEventListener("keydown", (event) => {
        const target = event.target;
        // typing in a box; a row's tick box (just clicked) takes no text, so the keys still work there
        const typing = target && (target.isContentEditable || ["TEXTAREA", "SELECT"].includes(target.tagName) ||
          (target.tagName === "INPUT" && !["checkbox", "radio", "button"].includes(target.type)));
        if (typing && event.key === "Escape" && target.closest(".toolbar .search") && !document.querySelector(".backdrop")) {
          target.blur();   // leave the search box, so the shortcuts work again
          return;
        }
        if (typing || event.ctrlKey || event.metaKey || event.altKey || document.querySelector(".backdrop")) return;
        if (pending === "g") {
          pending = null;
          const types = (this.project && this.project.entityTypes) || [];
          const index = Number(event.key) - 1;
          const hash = pages[event.key] || (Number.isInteger(index) && types[index] ? `#/entities/${types[index].name}` : null);
          if (hash && (this.project || hash === "#/projects" || hash === "#/settings")) { event.preventDefault(); this.go(hash); }
          return;
        }
        if (event.key === "g") { pending = "g"; setTimeout(() => { pending = null; }, 1500); return; }
        if (event.key === "?") { event.preventDefault(); N.showShortcuts(); return; }
        if (event.key === "/") {
          const search = document.querySelector(".content .toolbar .search input, .content input[type=search]");
          if (search) { event.preventDefault(); search.focus(); search.select(); }
          return;
        }
        if (event.key === "w" && this.onWorkspaceKey) { event.preventDefault(); this.onWorkspaceKey(); return; }   // dev's w: to the workspace
        if (event.key === "Escape" && N.drawer.isOpen()) { N.drawer.close(); return; }
      });
    },

    renderNav() {
      if (!this.navEl) return;
      const project = this.project;
      N.fill(this.switchEl, h("div.label", "Project"), h("div.name", project ? project.title : "Open a project…"));
      const active = (hash) => (location.hash.startsWith(hash) ? ".active" : "");
      const link = (hash, icon, label, count) => h("a" + active(hash), { href: hash }, N.icon(icon), label,
        count !== undefined && count !== null ? h("span.count", String(count)) : null);
      N.clear(this.navEl);
      const viewables = this.viewables && this.viewables.length ? [h("div.nav-section", "Viewer"),
        this.viewables.map((v) => link(`#/view/${v.id}`, v.kind === "signals" ? "activity" : "image", v.name))] : null;
      if (!project) {
        N.append(this.navEl, [viewables, viewables ? h("div.nav-section", "App") : null,
          link("#/projects", "folder", "Projects"), link("#/settings", "settings", "Settings")]);
        return;
      }
      N.append(this.navEl, [
        link("#/overview", "home", "Overview"),
        h("div.nav-section", "Entities"),
        project.entityTypes.length ? project.entityTypes.map((t) => link(`#/entities/${t.name}`, "table", t.title || N.titleCase(t.name), t.rows))
          : h("div.nav-empty", "None yet"),
        h("div.nav-section", "Work"),
        link("#/tasks", "tasks", "Tasks", this.runningTasks || null),
        link("#/data", "database", "Data"),
        link("#/pipelines", "layers", "Pipelines"),
        link("#/notes", "note", "Notes"),
        Object.keys(N.pages).length ? [h("div.nav-section", "Modules"),
          Object.values(N.pages).map((page) => link(`#/page/${page.id}`, page.icon || "puzzle", page.title))] : null,
        viewables,
        h("div.nav-section", "App"),
        link("#/projects", "folder", "Projects"),
        link("#/settings", "settings", "Settings")]);
    },

    /** The loading bar under the top bar, and the page shown marked busy (aria-busy), while a page loads. */
    showLoading(on) {
      if (!this.loadingEl) return;
      this.loadingEl.classList.toggle("on", on);
      this.loadingEl.setAttribute("aria-hidden", on ? "false" : "true");
      if (on) this.contentEl.setAttribute("aria-busy", "true");
      else this.contentEl.removeAttribute("aria-busy");
    },

    renderFooter() {
      if (!this.footEl) return;
      const ok = this.connected !== false;
      N.fill(this.footEl, h("span.conn-dot." + (ok ? "ok" : "bad")),
        ok ? `Connected · ${this.info ? this.info.language : ""}` : "Disconnected",
        h("span", { style: { marginLeft: "auto" } }, this.info ? "v" + this.info.version : ""));
    },

    async render() {
      if (!this.contentEl) return;
      const [, name, ...rest] = (location.hash || "#/overview").split("/");
      const arg = rest.join("/") || null;
      // A table being edited is drawn anew once the edit ends, unless the page changes
      const grid = this.currentGrid;
      if (grid && grid.editing && document.body.contains(grid.el) && this.route &&
          this.route.name === (name || "overview") && this.route.arg === arg) {
        grid.onEditEnd = () => this.render();
        return;
      }
      this.route = { name: name || "overview", arg };
      this.reloadEntities = null;
      clearTimeout(this.entitiesTimer);
      if (this.shellEl) this.shellEl.classList.remove("nav-open");
      this.onTaskEvent = null;
      this.onTaskRemoved = null;
      this.onLogEvent = null;
      this.onNotesEvent = null;
      this.onPipelinesEvent = null;
      this.onViewsEvent = null;
      this.onWorkspaceKey = null;
      this.currentGrid = null;
      N.drawer.close();
      this.renderNav();
      N.clear(this.topActions);
      const crumbs = { overview: "Overview", tasks: "Tasks", data: "Data", notes: "Notes", pipelines: "Pipelines", projects: "Projects", settings: "Settings", view: "Viewer", viewer: "Viewer" };
      const title = this.route.name === "entities" ? this.typeTitle(arg)
        : this.route.name === "page" ? (N.pages[arg] ? N.pages[arg].title : "") : crumbs[this.route.name] || "";
      N.fill(this.crumbsEl, this.project ? h("span.sub", this.project.title) : null, this.project ? h("span.sep", "/") : null, h("span", title));
      if (!this.project && !["projects", "settings", "view"].includes(this.route.name)) { this.go("#/projects"); return; }
      const page = this.route.name === "page" && N.pages[arg] ? (app, el) => N.pages[arg].render(app, el) : null;
      const view = page || { overview: N.views.overview, entities: N.views.entities, tasks: N.views.tasks, data: N.views.data, notes: N.views.notes, pipelines: N.views.pipelines, projects: N.views.projects, settings: N.views.settings, view: N.views.viewables, viewer: N.views.entityViewer }[this.route.name];
      if (!view) { this.go("#/overview"); return; }
      // Each render draws into a new container, shown when it is done, unless a later render has started:
      // views load their data first, and one that finishes late must not draw over the page now shown.
      const token = (this.renderToken = (this.renderToken || 0) + 1);
      const target = h("div.content");
      // A page that takes a moment to load its data says so: a bar under the top bar, and the page shown until then
      // marked busy and dimmed; only after 150 ms, so a quick page does not flicker
      const slow = setTimeout(() => { if (token === this.renderToken) this.showLoading(true); }, 150);
      try {
        await view(this, target, arg);
      } catch (error) {
        N.showError(error);
      }
      clearTimeout(slow);
      if (token !== this.renderToken) return;
      this.showLoading(false);
      this.contentEl.replaceWith(target);
      this.contentEl = target;
      const focus = target.querySelector("[autofocus]");
      if (focus) focus.focus();
    },
  };

  function loadTheme() {
    try { return localStorage.getItem("nansen.theme") || "auto"; } catch (e) { return "auto"; }
  }
  function saveTheme(theme) {
    try { localStorage.setItem("nansen.theme", theme); } catch (e) { /* not stored; fine */ }
  }
  function applyTheme(theme) {
    if (theme === "auto") document.documentElement.removeAttribute("data-theme");
    else document.documentElement.setAttribute("data-theme", theme);
  }

  N.theme = { load: loadTheme, save: saveTheme, apply: applyTheme };
  // The tables' defaults, from the user's settings (tables.textSize, tables.locked: dev's TableFontSize and
  // AllowTableEdits, which the legacy import brings), for a browser that has not chosen its own
  N.tableDefaults = { textSize: "normal", locked: false };
  N.loadTableDefaults = async function (client) {
    try {
      const tables = (await client.request("settings.get")).tables || {};
      N.tableDefaults = { textSize: tables.textSize || "normal", locked: tables.locked === true };
    } catch (error) { /* no catalog: the built-in defaults */ }
    N.tableSize.apply(N.tableSize.load());
  };
  // The tables' text size: compact, normal or large (dev's table font size), kept in this browser, else the user's default
  N.tableSize = {
    load() {
      try { return localStorage.getItem("nansen.tableSize") || N.tableDefaults.textSize; } catch (e) { return N.tableDefaults.textSize; }
    },
    apply(size) {
      if (size === "normal") document.documentElement.removeAttribute("data-table-size");
      else document.documentElement.setAttribute("data-table-size", size);
    },
    save(size) {
      try { localStorage.setItem("nansen.tableSize", size); } catch (e) { /* not stored; fine */ }
      N.tableSize.apply(size);
    },
  };
  N.app = app;
  window.addEventListener("DOMContentLoaded", () => app.start());
})();
