/* The data-location editor: the dataset config's locations, as forms (dev's DataLocationModel dialogs).
 *
 * It edits the config as DSM reads it (dataset.get), changing only the fields it shows, so anything else in the file
 * is kept: per location its name, category, access, the locations it is derived from, its roots, its folder levels
 * (with the files expected at each) and how names are read (metadata rules); and, for one that is written to, the
 * path template of new entities' folders. Test shows what a scan would find; Save hands the text to dataset.save,
 * which DSM checks first.
 */
(function () {
  "use strict";
  const N = window.N;
  const { h } = N;

  const CATEGORIES = ["raw", "processed", "derived", "imported", "reference", "temporary", "archive", "custom"];
  const METHODS = ["regex", "substring", "template", "fixed", "function"];

  /** Lower-case identifier from a name, unique among those taken. */
  function identifierOf(name, taken) {
    let base = String(name).toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "") || "location";
    if (!/^[a-z]/.test(base)) base = "location_" + base;
    let candidate = base;
    for (let n = 2; taken.includes(candidate); n++) candidate = `${base}_${n}`;
    return candidate;
  }

  /** A location for processed data derived from another, written to, with folders named from the entities' keys. */
  function processedFrom(config, source) {
    const ids = config.dataLocations.map((l) => l.identifier);
    const layout = ((source && source.filesystemSource && source.filesystemSource.entityLayout) || []).filter((level) => level.entityType);
    const levels = layout.map((level) => {
      const key = (config.entityTypes || []).find((t) => t.name === level.entityType);
      const field = key ? key.identifierRef : `${level.entityType}_id`;
      const prefix = level.entityType === "subject" ? "sub-" : level.entityType === "session" ? "ses-" : `${level.entityType}-`;
      return { name: level.name, entityType: level.entityType, pathComponentTemplate: `${prefix}{${field}}`, matchPattern: `^${prefix}.+$` };
    });
    const mapping = levels.map((level) => ({ metadataRef: level.pathComponentTemplate.slice(level.pathComponentTemplate.indexOf("{") + 1, -1),
      extraction: { method: "regex", pattern: `${level.matchPattern.slice(0, -4)}(.+)$`, entityLayoutLevel: level.name } }));
    return {
      identifier: identifierOf("processed", ids), displayName: "Processed data", dataCategory: "processed", access: "readwrite",
      sourceType: "filesystem", derivedFrom: source ? [source.identifier] : [],
      filesystemSource: { rootStoragePaths: [{ identifier: "local", path: "data/processed" }], entityLayout: levels, metadataMapping: mapping,
        pathTemplate: "{rootPath}/" + levels.map((l) => l.pathComponentTemplate).join("/") },
    };
  }

  N.views.dataLocations = async function (app) {
    let got;
    try { got = await app.client.request("dataset.get"); } catch (error) { N.showError(error, "Could not read the dataset config"); return; }
    let config;
    try { config = JSON.parse(got.text); } catch (error) { N.views.datasetJson(app); return; }   // only text can mend broken text
    config.dataLocations = config.dataLocations || [];
    const entityTypes = (config.entityTypes || []).map((t) => t.name);
    const fields = Object.keys(config.metadataDefinitions || {});
    let selected = 0;
    const list = h("ul.loc-list");
    const form = h("div.loc-form");
    const message = h("div.form-message.hidden");
    const found = h("div.loc-found.muted");

    const fs = (location) => (location.filesystemSource = location.filesystemSource || { rootStoragePaths: [], entityLayout: [] });
    const input = (value, change, attrs = {}) => h("input.input" + (attrs.mono ? ".mono" : ""), {
      value: value === undefined || value === null ? "" : String(value), placeholder: attrs.placeholder || "", name: attrs.name,
      on: { input: (event) => change(event.target.value) } });
    const select = (value, options, change, attrs = {}) => h("select.input", { name: attrs.name, on: { change: (event) => change(event.target.value) } },
      options.map((option) => { const [v, label] = Array.isArray(option) ? option : [option, option || "–"];
        return h("option", { value: v, selected: v === (value || "") }, label); }));
    const field = (label, control, hint) => h("div.field", h("label.name", label), control, hint ? h("div.hint.muted", hint) : null);
    const remove = (title, run) => h("button.btn.ghost.icon.small.loc-remove", { title, on: { click: () => { run(); render(); } } }, N.icon("trash", 13));
    const move = (array, index, by) => { const [item] = array.splice(index, 1); array.splice(index + by, 0, item); render(); };

    function renderList() {
      N.fill(list, config.dataLocations.map((location, index) => h("li" + (index === selected ? ".selected" : ""),
        { dataset: { location: location.identifier }, on: { click: () => { selected = index; render(); } } },
        h("div.grow", h("div", location.displayName || location.identifier), h("div.muted.mono", location.identifier)),
        h("span.pill." + (location.access === "readwrite" ? "accent" : "plain"), location.access === "readwrite" ? "written" : "read"))));
    }

    function renderForm() {
      const location = config.dataLocations[selected];
      if (!location) { N.fill(form, h("div.muted", "No data locations yet: add one.")); return; }
      const source = fs(location);
      const others = config.dataLocations.filter((l) => l !== location).map((l) => l.identifier);
      const levels = source.entityLayout = source.entityLayout || [];
      const roots = source.rootStoragePaths = source.rootStoragePaths || [];
      const rules = source.metadataMapping = source.metadataMapping || [];
      const levelNames = levels.map((l) => l.name);
      N.fill(form,
        h("div.loc-grid",
          field("Name", input(location.displayName, (v) => { location.displayName = v; renderList(); }, { name: "displayName" })),
          field("Identifier", input(location.identifier, (v) => { location.identifier = v; renderList(); }, { mono: true, name: "identifier" }),
            "Data variables refer to the location by it"),
          field("Category", select(location.dataCategory, CATEGORIES, (v) => { location.dataCategory = v; }, { name: "dataCategory" })),
          field("Access", select(location.access || "read", [["read", "read: the files are only read"], ["readwrite", "readwrite: methods write here"]],
            (v) => { location.access = v; render(); }, { name: "access" }))),
        others.length ? field("Derived from", h("div.loc-chips", others.map((id) => h("label.chip",
          h("input", { type: "checkbox", checked: (location.derivedFrom || []).includes(id), on: { change: (event) => {
            location.derivedFrom = (location.derivedFrom || []).filter((d) => d !== id).concat(event.target.checked ? [id] : []);
            if (!location.derivedFrom.length) delete location.derivedFrom;
          } } }), id)))) : null,

        h("h4", "Roots", h("span.muted", " where the location's folders are, on this machine or another")),
        h("table.simple.loc-roots", h("thead", h("tr", ["Identifier", "Path", "Environment", ""].map((t) => h("th", t)))),
          h("tbody", roots.map((root, i) => h("tr",
            h("td", input(root.identifier, (v) => { root.identifier = v; }, { mono: true, name: "rootIdentifier" })),
            h("td", input(root.path, (v) => { root.path = v; }, { mono: true, name: "rootPath", placeholder: "/data/raw, or relative to the project" })),
            h("td", input(root.environment, (v) => { if (v) root.environment = v; else delete root.environment; }, { name: "rootEnvironment", placeholder: "any" })),
            h("td", remove("Remove the root", () => roots.splice(i, 1))))))),
        h("button.btn.small.loc-add-root", { on: { click: () => { roots.push({ identifier: identifierOf("root", roots.map((r) => r.identifier)), path: "" }); render(); } } },
          N.icon("plus", 13), "Add root"),

        h("h4", "Folder levels", h("span.muted", " from the root down: which entity each level's folders are, and which names count")),
        h("div.loc-levels", levels.map((level, i) => h("div.loc-level", { dataset: { level: level.name } },
          h("div.loc-level-row",
            h("span.loc-depth.mono", String(i + 1)),
            field("Name", input(level.name, (v) => { level.name = v; }, { name: "levelName" })),
            field("Entity", select(level.entityType, [["", "– (a folder that is no entity)"], ...entityTypes.map((t) => [t, t])],
              (v) => { if (v) level.entityType = v; else delete level.entityType; }, { name: "levelEntity" })),
            field("Names that count (regex)", input(level.matchPattern, (v) => { if (v) level.matchPattern = v; else delete level.matchPattern; }, { mono: true, name: "levelPattern", placeholder: "any" })),
            location.access === "readwrite" ? field("New folder name", input(level.pathComponentTemplate, (v) => { if (v) level.pathComponentTemplate = v; else delete level.pathComponentTemplate; }, { mono: true, name: "levelTemplate", placeholder: "{session_id}" })) : null,
            h("div.loc-level-actions",
              h("button.btn.ghost.icon.small", { title: "Up", disabled: i === 0, on: { click: () => move(levels, i, -1) } }, N.icon("chevron-up", 13)),
              h("button.btn.ghost.icon.small", { title: "Down", disabled: i === levels.length - 1, on: { click: () => move(levels, i, 1) } }, N.icon("chevron-down", 13)),
              remove("Remove the level", () => levels.splice(i, 1)))),
          h("div.loc-files",
            (level.filePatterns || []).map((pattern, k) => h("div.loc-file",
              h("span.muted", "file"), input(pattern.name, (v) => { pattern.name = v; }, { name: "fileName", placeholder: "name" }),
              input(pattern.pattern, (v) => { pattern.pattern = v; }, { mono: true, name: "filePattern", placeholder: "\\.tif$" }),
              select(pattern.cardinality || "many", [["one", "one file"], ["many", "any number"]], (v) => { pattern.cardinality = v; }),
              remove("Remove the file pattern", () => { level.filePatterns.splice(k, 1); if (!level.filePatterns.length) delete level.filePatterns; }))),
            h("button.btn.ghost.small.loc-add-file", { on: { click: () => { (level.filePatterns = level.filePatterns || []).push({ name: "", pattern: "", cardinality: "one" }); render(); } } },
              N.icon("plus", 12), "File pattern"))))),
        h("button.btn.small.loc-add-level", { on: { click: () => { levels.push({ name: identifierOf("level", levelNames) }); render(); } } }, N.icon("plus", 13), "Add level"),

        h("h4", "Naming rules", h("span.muted", " how each field is read from the folder names")),
        h("table.simple.loc-rules", h("thead", h("tr", ["Field", "From level", "Method", "Pattern or value", "Format", ""].map((t) => h("th", t)))),
          h("tbody", rules.map((rule, i) => {
            const extraction = rule.extraction = rule.extraction || { method: "regex" };
            const valueKey = extraction.method === "fixed" ? "value" : extraction.method === "function" ? "functionName" : "pattern";
            return h("tr",
              h("td", select(rule.metadataRef, fields.includes(rule.metadataRef) ? fields : [rule.metadataRef, ...fields], (v) => { rule.metadataRef = v; }, { name: "ruleField" })),
              h("td", select(extraction.entityLayoutLevel, [["", "–"], ...levelNames.map((n) => [n, n])], (v) => { if (v) extraction.entityLayoutLevel = v; else delete extraction.entityLayoutLevel; }, { name: "ruleLevel" })),
              h("td", select(extraction.method, METHODS.includes(extraction.method) ? METHODS : [extraction.method, ...METHODS], (v) => { extraction.method = v; render(); }, { name: "ruleMethod" })),
              h("td", input(extraction[valueKey], (v) => { extraction[valueKey] = v; }, { mono: true, name: "rulePattern",
                placeholder: { regex: "^ses-(.+)$", substring: "0:8", template: "{session_date}_{subject_id}", fixed: "value", function: "extractor name" }[extraction.method] || "" })),
              h("td", input(extraction.valueFormat, (v) => { if (v) extraction.valueFormat = v; else delete extraction.valueFormat; }, { mono: true, name: "ruleFormat", placeholder: "yyyy_MM_dd" })),
              h("td", remove("Remove the rule", () => rules.splice(i, 1))));
          }))),
        fields.length ? h("button.btn.small.loc-add-rule", { on: { click: () => { rules.push({ metadataRef: fields[0], extraction: { method: "regex", pattern: "", entityLayoutLevel: levelNames[levelNames.length - 1] } }); render(); } } },
          N.icon("plus", 13), "Add rule") : null,

        location.access === "readwrite" ? h("div",
          h("h4", "New folders"),
          field("Path template", input(source.pathTemplate, (v) => { if (v) source.pathTemplate = v; else delete source.pathTemplate; }, { mono: true, name: "pathTemplate", placeholder: "{rootPath}/sub-{subject_id}/ses-{session_id}" }),
            "Where an entity's folder is made when a method writes for it and it has none here yet")) : null,
        h("div.loc-danger", h("button.btn.ghost.small.loc-remove-location", { on: { click: async () => {
          if (!(await N.confirm("Remove the location?", `${location.displayName || location.identifier} is left out of the config; its files stay where they are.`, "Remove", "danger"))) return;
          config.dataLocations.splice(selected, 1);
          selected = Math.max(0, selected - 1);
          render();
        } } }, N.icon("trash", 13), "Remove this location")));
    }

    function render() { renderList(); renderForm(); }
    const text = () => JSON.stringify(config, null, 2) + "\n";
    const showProblem = (error) => {
      message.textContent = (error.code ? `[${error.code}] ` : "") + (error.message || String(error));
      message.classList.remove("hidden");
    };

    const addMenu = (event) => N.menu(event.currentTarget, [
      { label: "Processed data, written by methods", icon: "plus", onClick: () => {
        const source = config.dataLocations.find((l) => l.dataCategory === "raw") || config.dataLocations[0];
        config.dataLocations.push(processedFrom(config, source));
        selected = config.dataLocations.length - 1;
        render();
      } },
      { label: "Another location", icon: "plus", onClick: () => {
        config.dataLocations.push({ identifier: identifierOf("location", config.dataLocations.map((l) => l.identifier)), displayName: "New location",
          dataCategory: "raw", access: "read", sourceType: "filesystem", filesystemSource: { rootStoragePaths: [], entityLayout: [] } });
        selected = config.dataLocations.length - 1;
        render();
      } },
    ]);

    render();
    N.dialog({
      title: "Data locations",
      content: h("div.loc-editor",
        h("div.loc-side", list, h("button.btn.small.loc-add", { on: { click: addMenu } }, N.icon("plus", 13), "Add location")),
        h("div.loc-main", form, found, message)),
      buttons: [
        { label: "Edit as JSON", icon: "code", onClick: (close) => { close(); N.views.datasetJson(app, text()); } },
        { label: "Test", icon: "search", onClick: async () => {
          message.classList.add("hidden");
          try {
            const result = await app.client.request("dataset.test", { text: text() });
            N.fill(found, "A scan would find ", Object.entries(result.records).map(([type, count]) => `${count} ${type}`).join(", ") || "nothing",
              result.unmatched ? `, and ${result.unmatched} folder(s) it cannot place` : "", ".");
          } catch (error) { showProblem(error); }
        } },
        { label: "Cancel" },
        { label: "Save", kind: "primary", onClick: async (close) => {
          try {
            app.project = await app.client.request("dataset.save", { text: text() });
            close();
            await app.reloadProject();
            app.render();
            N.toast("Data locations saved", "Scan the stores to see what they find", "success");
          } catch (error) { showProblem(error); }
        } },
      ],
    }).el.classList.add("loc-dialog");
  };
})();
