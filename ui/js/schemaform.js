/* A form generated from a JSON Schema (the options schema of a method). The server validates too;
   the form only guides input. */
(function () {
  "use strict";
  const N = window.N;
  const { h } = N;

  function typeOf(schema) {
    if (Array.isArray(schema.type)) return schema.type.find((t) => t !== "null") || "string";
    if (schema.type) return schema.type;
    if (schema.properties) return "object";
    if (schema.enum) return typeof schema.enum[0] === "number" ? "number" : "string";
    return "string";
  }

  function field(name, schema, value) {
    const type = typeOf(schema);
    const label = schema.title || N.titleCase(name);
    const help = schema.description ? h("div.help", schema.description) : null;
    const error = h("div.error.hidden");

    if (type === "object") {
      const group = form(schema, value || {});
      const el = h("fieldset.group", h("legend", label), help, group.el);
      return { el, get: group.getValue, check: group.validate };
    }
    if (type === "boolean") {
      const input = h("input", { type: "checkbox", checked: !!value });
      const el = h("div.field.inline", h("label.switch", input, h("span")), h("label.name", label), help);
      return { el, get: () => input.checked, check: () => [] };
    }
    let input;
    let read;
    if (schema.enum) {
      const titles = schema.enumTitles || [];   // labels for the options, when the values are not for reading
      input = h("select.input", schema.enum.map((option, i) => h("option", { value: String(option), selected: option === value },
        String(titles[i] ?? option))));
      read = () => {
        const chosen = schema.enum.find((option) => String(option) === input.value);
        return chosen === undefined ? input.value : chosen;
      };
    } else if (type === "number" || type === "integer") {
      input = h("input.input", { type: "number", value: value === undefined || value === null ? "" : String(value),
        min: schema.minimum, max: schema.maximum, step: type === "integer" ? 1 : schema.multipleOf || "any" });
      read = () => (input.value === "" ? undefined : Number(input.value));
    } else if (type === "array") {
      input = h("input.input", { value: Array.isArray(value) ? value.join(", ") : "", placeholder: "comma-separated" });
      const itemType = typeOf(schema.items || {});
      read = () => input.value.split(",").map((s) => s.trim()).filter(Boolean)
        .map((s) => (itemType === "number" || itemType === "integer" ? Number(s) : s));
    } else if (schema.maxLength > 200 || schema.format === "textarea") {
      input = h("textarea.input", { rows: 4 }, value || "");
      read = () => input.value;
    } else {
      input = h("input.input", { value: value === undefined || value === null ? "" : String(value) });
      read = () => input.value;
    }
    const el = h("div.field", h("label.name", label), input, help, error);
    const check = () => {
      const problems = [];
      const v = read();
      if (type === "integer" && v !== undefined && !Number.isInteger(v)) problems.push("must be a whole number");
      if (schema.minimum !== undefined && v < schema.minimum) problems.push(`at least ${schema.minimum}`);
      if (schema.maximum !== undefined && v > schema.maximum) problems.push(`at most ${schema.maximum}`);
      if (schema.pattern && typeof v === "string" && !new RegExp(schema.pattern).test(v)) problems.push(`must match ${schema.pattern}`);
      el.classList.toggle("invalid", problems.length > 0);
      error.classList.toggle("hidden", problems.length === 0);
      error.textContent = problems.join("; ");
      return problems.map((p) => `${label}: ${p}`);
    };
    input.addEventListener("change", check);
    return { el, get: read, check };
  }

  function form(schema, values) {
    const properties = (schema && schema.properties) || {};
    const fields = Object.entries(properties).map(([name, sub]) => {
      const value = values && name in values ? values[name] : sub.default;
      return [name, field(name, sub, value)];
    });
    const el = h("div.form-grid", fields.map(([, f]) => f.el));
    if (!fields.length) el.appendChild(h("div.muted", "This method has no options."));
    return {
      el,
      getValue() {
        const out = {};
        for (const [name, f] of fields) {
          const v = f.get();
          if (v !== undefined) out[name] = v;
        }
        return out;
      },
      validate() {
        return fields.flatMap(([, f]) => f.check());
      },
    };
  }

  N.schemaForm = form;
})();
