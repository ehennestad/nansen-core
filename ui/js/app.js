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
      root.appendChild(h("div.shell",
        h("aside.sidebar",
          h("div.brand", h("div.brand-mark", N.icon("compass", 18)), h("div", h("div.brand-name", "NANSEN"), h("div.brand-sub", "neuroscience data"))),
          this.switchEl, this.navEl, this.footEl),
        h("main.main", h("header.topbar", this.crumbsEl, h("div.spacer"), this.topActions, themeButton), this.contentEl)));
      this.renderNav();
      this.renderFooter();
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
        project.entityTypes.map((t) => link(`#/entities/${t.name}`, "table", t.title || N.titleCase(t.name), t.rows)),
        h("div.nav-section", "Work"),
        link("#/tasks", "tasks", "Tasks", this.runningTasks || null),
        link("#/data", "database", "Data"),
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
      this.currentGrid = null;
      N.drawer.close();
      this.contentEl.className = "content";
      this.renderNav();
      N.clear(this.topActions);
      const crumbs = { overview: "Overview", tasks: "Tasks", data: "Data", projects: "Projects" };
      const title = this.route.name === "entities" ? this.typeTitle(arg) : crumbs[this.route.name] || "";
      N.fill(this.crumbsEl, this.project ? h("span.sub", this.project.title) : null, this.project ? h("span.sep", "/") : null, h("span", title));
      if (!this.project && this.route.name !== "projects") { this.go("#/projects"); return; }
      const view = { overview: N.views.overview, entities: N.views.entities, tasks: N.views.tasks, data: N.views.data, projects: N.views.projects }[this.route.name];
      if (!view) { this.go("#/overview"); return; }
      try {
        await view(this, this.contentEl, arg);
      } catch (error) {
        N.showError(error);
      }
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
