/* The app shell: sidebar, top bar, routing, and live updates from core events. */
(function () {
  "use strict";
  const N = window.N;
  const { h } = N;

  const app = {
    client: null,
    info: null,
    project: null,
    fragments: [],
    methods: [],
    route: null,
    runningTasks: 0,
    reloadEntities: null,
    onTaskEvent: null,
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
      this.client.on("task", (task) => this.taskEvent(task));
      this.client.on("removed", () => this.refreshTaskCount());
      this.client.on("log", (event) => this.onLogEvent && this.onLogEvent(event));
      this.client.on("entities", (data) => this.entitiesEvent(data));
      this.client.on("pipelines", () => this.onPipelinesEvent && this.onPipelinesEvent());
      this.client.on("views", (data) => this.onViewsEvent && this.onViewsEvent(data));
      this.client.on("notes", (data) => {   // the page and an entity's drawer can both show notes
        if (this.onNotesEvent) this.onNotesEvent(data);
        if (this.onDrawerNotesEvent) this.onDrawerNotesEvent(data);
      });
      this.client.on("scan", () => this.reloadProject());
      this.client.on("project", () => this.reloadProject().then(() => this.render()));
      await this.reloadProject();
      this.renderShell();
      window.addEventListener("hashchange", () => this.render());
      if (!location.hash) location.hash = this.project ? "#/overview" : "#/projects";
      else this.render();
    },

    async reloadProject() {
      try {
        this.project = await this.client.request("project.info");
        [this.fragments, this.methods] = await Promise.all([
          this.client.request("fragments.list"), this.client.request("methods.list")]);
      } catch (error) {
        if (error.code !== "no-project") N.showError(error);
        this.project = null;
      }
      this.renderNav();
      await this.refreshTaskCount();
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
        this.entitiesTimer = setTimeout(() => this.reloadEntities(), 150);
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
      const themeButton = h("button.btn.ghost.icon", { title: "Light or dark", on: { click: () => {
        const next = { auto: "dark", dark: "light", light: "auto" }[loadTheme()];
        saveTheme(next);
        applyTheme(next);
        N.toast("Theme", next === "auto" ? "Follow the system" : next);
      } } }, N.icon("moon"));
      this.topActions = h("div", { style: { display: "flex", gap: "8px" } });
      const helpButton = h("button.btn.ghost.icon.shortcuts-button", { title: "Keyboard shortcuts (?)", on: { click: () => N.showShortcuts() } }, N.icon("keyboard"));
      root.appendChild(h("div.shell",
        h("aside.sidebar",
          h("div.brand", h("div.brand-mark", N.icon("compass", 18)), h("div", h("div.brand-name", "NANSEN"), h("div.brand-sub", "neuroscience data"))),
          this.switchEl, this.navEl, this.footEl),
        h("main.main", h("header.topbar", this.crumbsEl, h("div.spacer"), this.topActions, helpButton, themeButton), this.contentEl)));
      this.bindShortcuts();
      this.renderNav();
      this.renderFooter();
    },

    bindShortcuts() {
      if (this.shortcutsBound) return;
      this.shortcutsBound = true;
      let pending = null;   // "g", waiting for the second key
      const pages = { o: "#/overview", t: "#/tasks", d: "#/data", p: "#/pipelines", n: "#/notes", j: "#/projects" };
      document.addEventListener("keydown", (event) => {
        const target = event.target;
        const typing = target && (target.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName));
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
          if (hash && (this.project || hash === "#/projects")) { event.preventDefault(); this.go(hash); }
          return;
        }
        if (event.key === "g") { pending = "g"; setTimeout(() => { pending = null; }, 1500); return; }
        if (event.key === "?") { event.preventDefault(); N.showShortcuts(); return; }
        if (event.key === "/") {
          const search = document.querySelector(".content .toolbar .search input, .content input[type=search]");
          if (search) { event.preventDefault(); search.focus(); search.select(); }
          return;
        }
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
      if (!project) {
        this.navEl.appendChild(link("#/projects", "folder", "Projects"));
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
        h("div.nav-section", "App"),
        link("#/projects", "folder", "Projects")]);
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
      this.route = { name: name || "overview", arg };
      this.reloadEntities = null;
      clearInterval(this.viewTimer);
      this.viewTimer = null;
      this.onTaskEvent = null;
      this.onLogEvent = null;
      this.onNotesEvent = null;
      this.onPipelinesEvent = null;
      this.onViewsEvent = null;
      this.currentGrid = null;
      N.drawer.close();
      this.renderNav();
      N.clear(this.topActions);
      const crumbs = { overview: "Overview", tasks: "Tasks", data: "Data", notes: "Notes", pipelines: "Pipelines", projects: "Projects" };
      const title = this.route.name === "entities" ? this.typeTitle(arg) : crumbs[this.route.name] || "";
      N.fill(this.crumbsEl, this.project ? h("span.sub", this.project.title) : null, this.project ? h("span.sep", "/") : null, h("span", title));
      if (!this.project && this.route.name !== "projects") { this.go("#/projects"); return; }
      const view = { overview: N.views.overview, entities: N.views.entities, tasks: N.views.tasks, data: N.views.data, notes: N.views.notes, pipelines: N.views.pipelines, projects: N.views.projects }[this.route.name];
      if (!view) { this.go("#/overview"); return; }
      // Each render draws into a new container, shown when it is done, unless a later render has started:
      // views load their data first, and one that finishes late must not draw over the page now shown.
      const token = (this.renderToken = (this.renderToken || 0) + 1);
      const target = h("div.content");
      try {
        await view(this, target, arg);
      } catch (error) {
        N.showError(error);
      }
      if (token !== this.renderToken) return;
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

  N.app = app;
  window.addEventListener("DOMContentLoaded", () => app.start());
})();
