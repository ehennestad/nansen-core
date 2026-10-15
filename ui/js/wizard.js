/* The dataset wizard: describe a data folder's levels, see what a scan would find, and make the
   project's DSM config from it, as dev's setup wizard does for data locations. The config is made
   here; the backends sample the folder (dataset.sample), try the config (dataset.test) and keep it
   (project.setDataset with datasetText). */
(function () {
  "use strict";
  const N = window.N;
  const { h } = N;

  const escapeRegex = (text) => text.replace(/[\\^$.*+?()[\]{}|]/g, "\\$&");
  const tokensOf = (template) => [...template.matchAll(/\{([A-Za-z][A-Za-z0-9_]*)\}/g)].map((m) => m[1]);

  /** A pattern for names like these: from the first, digits and letters as classes; looser if the others differ. */
  function patternFor(names) {
    if (!names.length) return "^.+$";
    const shape = (name, counted) => "^" + (name.match(/\d+|[A-Za-z]+|[^\dA-Za-z]+/g) || []).map((run) => {
      if (/^\d/.test(run)) return counted ? `\\d{${run.length}}` : "\\d+";
      if (/^[A-Za-z]/.test(run)) return "[A-Za-z]+";
      return escapeRegex(run);
    }).join("") + "$";
    for (const counted of [true, false]) {
      const pattern = shape(names[0], counted);
      if (names.every((n) => new RegExp(pattern).test(n))) return pattern;
    }
    return "^.+$";
  }

  /** A name template's regex: each {token} matches some text; one of them, as a group, when target is given. */
  function templateRegex(template, target) {
    let out = "^";
    let at = 0;
    for (const m of template.matchAll(/\{([A-Za-z][A-Za-z0-9_]*)\}/g)) {
      out += escapeRegex(template.slice(at, m.index)) + (m[1] === target ? "(.+?)" : ".+?");
      at = m.index + m[0].length;
    }
    return out + escapeRegex(template.slice(at)) + "$";
  }

  /** The DSM config for one data location described level by level. Throws with a message for the user. */
  N.makeDatasetConfig = function ({ id, title, access, root, levels }) {
    if (!/^[A-Za-z][A-Za-z0-9_-]*$/.test(id || "")) throw new Error("The location's name: a letter, then letters, digits, - or _");
    if (!root) throw new Error("Choose the folder the data is in");
    const cut = levels.findIndex((l) => l.role === "stop");
    const layoutLevels = cut < 0 ? levels : levels.slice(0, cut);
    const entityLevels = layoutLevels.filter((l) => l.role === "entity");
    if (!entityLevels.length) throw new Error("Make at least one level an entity, such as subject or session");
    const types = [];
    const definitions = {};
    const mapping = [];
    const layout = layoutLevels.map((level, index) => {
      if (level.role !== "entity") {
        if (!level.pattern) throw new Error(`Level ${index + 1}: give a pattern for its names`);
        try { new RegExp(level.pattern); } catch (e) { throw new Error(`Level ${index + 1}: ${e.message}`); }
        return { name: `level_${index + 1}`, matchPattern: level.pattern };
      }
      const type = level.entityType;
      if (!/^[A-Za-z][A-Za-z0-9_]*$/.test(type || "")) throw new Error(`Level ${index + 1}: an entity type is a letter, then letters, digits or _`);
      if (types.includes(type)) throw new Error(`Level ${index + 1}: ${type} is already a level above`);
      const tokens = tokensOf(level.template || "");
      if (!tokens.length) throw new Error(`Level ${index + 1}: write the name with {${type}_id} where the id is, for example sub-{${type}_id}`);
      const identity = tokens.includes(`${type}_id`) ? `${type}_id` : tokens[0];
      for (const token of tokens) {
        if (definitions[token]) throw new Error(`Level ${index + 1}: {${token}} is read at another level too`);
        definitions[token] = { name: token, title: N.titleCase(token), dataType: "string", ofEntity: type };
        mapping.push({ metadataRef: token, extraction: { method: "regex", pattern: templateRegex(level.template, token), entityLayoutLevel: index } });
      }
      types.push(type);
      return { name: `${type}s`, entityType: type, matchPattern: templateRegex(level.template, null), _identity: identity };
    });
    const entityTypes = types.map((type, i) => {
      const entry = { name: type, identifierRef: layout.find((l) => l.entityType === type)._identity };
      if (i === 0) entry.isPrimary = true;
      return entry;
    });
    layout.forEach((l) => delete l._identity);
    const relationships = types.slice(1).map((type, i) => ({ sourceEntity: types[i], targetEntity: type, relationType: "oneToMany",
      relationName: `has${type[0].toUpperCase()}${type.slice(1)}s` }));
    const config = {
      schemaVersion: "0.1.0",
      entityTypes,
      metadataDefinitions: definitions,
      dataLocations: [{
        identifier: id, displayName: title || id, dataCategory: access === "readwrite" ? "processed" : "raw", access: access || "read",
        sourceType: "filesystem",
        filesystemSource: { rootStoragePaths: [{ identifier: "local", path: root }], entityLayout: layout, metadataMapping: mapping },
      }],
    };
    if (relationships.length) config.entityRelationships = relationships;
    return JSON.stringify(config, null, 2) + "\n";
  };

  /** The wizard, for a project without a dataset. */
  N.datasetWizard = function (app) {
    const state = { id: "raw", title: "Raw data", access: "read", root: "", sample: null, levels: [] };
    const body = h("div.wizard", { style: { padding: "16px 20px" } });
    const message = h("div.form-message.hidden");
    const say = (text) => { message.textContent = text; message.classList.toggle("hidden", !text); };
    let step = "where";
    let tested = null;
    const field = (label, input, help) => h("div.field", { style: { marginBottom: "12px" } }, h("label.name", label), input, help ? h("div.help", help) : null);

    function drawWhere() {
      const id = h("input.input.wizard-id", { value: state.id });
      const title = h("input.input.wizard-title", { value: state.title });
      const root = h("input.input.wizard-root", { value: state.root, placeholder: "/path/to/the/data" });
      const access = h("select.input.wizard-access", [["read", "Read only: data as recorded"], ["readwrite", "Read and write: processed data"]]
        .map(([v, label]) => h("option", { value: v, selected: v === state.access }, label)));
      N.fill(body, h("p.muted", { style: { marginTop: 0 } }, "Describe how the data is organized: first where it is, then what each level of folders holds. NANSEN makes a dataset config (DSM) from it, which you can change later."),
        field("Folder", root, "The top folder of the data on this computer"),
        h("div.field-row", field("Name of the location", id, "Short, such as raw or processed"), field("Title", title)),
        field("Access", access), message);
      return async () => {
        Object.assign(state, { id: id.value.trim(), title: title.value.trim(), root: root.value.trim(), access: access.value });
        if (!state.root) throw new Error("Give the folder the data is in");
        state.sample = await app.client.request("dataset.sample", { path: state.root, depth: 5, limit: 8 });
        state.root = state.sample.path;
        if (!state.sample.levels.length) throw new Error("The folder is empty");
        if (state.levels.length !== state.sample.levels.length) {
          // A first guess: subjects, then sessions (or only sessions); deeper levels are inside a session
          const guess = state.sample.levels.length > 1 ? ["subject", "session"] : ["session"];
          state.levels = state.sample.levels.map((level, i) => ({
            role: i < guess.length ? "entity" : "stop", entityType: guess[i] || "session",
            template: `{${guess[i] || "session"}_id}`, pattern: patternFor(level.folders),
          }));
        }
        return "levels";
      };
    }

    function drawLevels() {
      const rows = state.sample.levels.map((level, i) => {
        const current = state.levels[i];
        const role = h("select.input.level-role", [["entity", "An entity"], ["folder", "A grouping folder, not an entity"], ["stop", "Not part of the layout (and below)"]]
          .map(([v, label]) => h("option", { value: v, selected: current.role === v }, label)));
        const type = h("input.input.level-type", { value: current.entityType, placeholder: "session" });
        const template = h("input.input.mono.level-template", { value: current.template });
        const pattern = h("input.input.mono.level-pattern", { value: current.pattern });
        const check = h("div.help.level-check");
        const update = () => {
          Object.assign(current, { role: role.value, entityType: type.value.trim(), template: template.value.trim(), pattern: pattern.value.trim() });
          entityPart.style.display = current.role === "entity" ? "" : "none";
          folderPart.style.display = current.role === "folder" ? "" : "none";
          let regex = null;
          try { regex = new RegExp(current.role === "entity" ? templateRegex(current.template, null) : current.pattern); } catch (e) { check.textContent = e.message; return; }
          const matching = level.folders.filter((n) => regex.test(n)).length;
          check.textContent = current.role === "stop" ? "" : `${matching} of the ${level.folders.length} examples match`;
          check.classList.toggle("bad-text", current.role !== "stop" && matching < level.folders.length);
        };
        type.addEventListener("input", () => {
          if (/^\{[A-Za-z0-9_]*_id\}$/.test(template.value)) template.value = `{${type.value.trim()}_id}`;
          update();
        });
        for (const el of [role, template, pattern]) el.addEventListener("input", update);
        role.addEventListener("change", update);
        const entityPart = h("div.field-row", field("Entity type", type), field("Name", template, `{${current.entityType || "session"}_id} for the id; other {fields} are read too, e.g. {date}_{session_id}`));
        const folderPart = field("Names like", pattern, "A regular expression");
        setTimeout(update, 0);
        return h("div.card.level-card", { dataset: { level: i + 1 }, style: { padding: "12px 14px", marginBottom: "10px" } },
          h("div", { style: { display: "flex", gap: "10px", alignItems: "baseline", marginBottom: "8px" } }, h("b", `Level ${i + 1}`),
            h("span.muted.mono", { style: { fontSize: "12px", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" } },
              level.folders.slice(0, 4).join("   ") + (level.moreFolders || level.folders.length > 4 ? "   …" : "")),
            level.files ? h("span.muted", `${level.files} file(s)`) : null),
          field("This level is", role), entityPart, folderPart, check);
      });
      N.fill(body, h("p.muted", { style: { marginTop: 0 } }, `Examples of the folders at each level under ${state.root}. Say what each level holds.`), rows, message);
      return async () => {
        const text = N.makeDatasetConfig({ id: state.id, title: state.title, access: state.access, root: state.root, levels: state.levels });
        tested = { text, result: await app.client.request("dataset.test", { text }) };
        return "check";
      };
    }

    function drawCheck() {
      const r = tested.result;
      const counts = Object.entries(r.records);
      N.fill(body,
        h("p.muted", { style: { marginTop: 0 } }, "What a scan with this layout finds now. Go back to change the levels, or use it; the config can be edited later on the Data page."),
        counts.length ? h("div.grid.stats", counts.map(([type, n]) => h("div.card.stat", h("div.label", type), h("div.value", String(n)),
          h("div.sub.mono", { style: { fontSize: "11.5px", marginTop: "6px", whiteSpace: "pre-line" } }, (r.examples[type] || []).map((k) => N.fmt.key(k)).join("\n"))))) :
          h("div.empty", h("h3", "Nothing found"), h("div", "No folder matches the layout. Go back and check the levels.")),
        r.unmatched ? h("div.card", { style: { marginTop: "12px" } }, h("div.card-head", N.icon("alert"), h("h3", `${r.unmatched} not matched`)),
          h("ul.list", r.unmatchedExamples.map((u) => h("li", h("div.grow", h("div.title.mono", { style: { fontSize: "12.5px" } }, u.path), h("div.sub", u.reason)))))) : null,
        h("details", { style: { marginTop: "12px" } }, h("summary.muted", "The dataset config"), h("pre.log", { style: { maxHeight: "240px" } }, tested.text)),
        message);
      return async () => {
        const hasCore = app.project.modules.some((m) => m.id === "core");
        app.project = await app.client.request("project.setDataset", { datasetText: tested.text, entityTypes: true, modules: hasCore ? [] : ["core"] });
        await app.reloadProject();
        return "done";
      };
    }

    const draws = { where: drawWhere, levels: drawLevels, check: drawCheck };
    const titles = { where: "Where the data is", levels: "What each level holds", check: "What a scan finds" };
    const order = ["where", "levels", "check"];
    let next = null;
    const dialog = N.dialog({
      title: "Describe the data",
      content: body,
      buttons: [
        { label: "Back", onClick: () => { if (order.indexOf(step) > 0) go(order[order.indexOf(step) - 1]); } },
        { label: "Next", kind: "primary", onClick: async (close) => {
          say("");
          try {
            const target = await next();
            if (target === "done") {
              close();
              app.render();
              N.toast("Dataset set up", "Scan the stores to find the entities", "success");
              return;
            }
            go(target);
          } catch (error) { say((error.code ? `[${error.code}] ` : "") + (error.message || String(error))); }
        } },
      ],
    });
    const heading = dialog.el.querySelector(".dialog-head h2");
    const nextButton = dialog.foot.querySelector(".btn.primary");
    function go(target) {
      step = target;
      next = draws[step]();
      heading.textContent = `Describe the data · ${order.indexOf(step) + 1}/3 · ${titles[step]}`;
      nextButton.lastChild.textContent = step === "check" ? "Use this dataset" : "Next";
    }
    go("where");
  };
})();
