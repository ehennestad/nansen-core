/* Small DOM and formatting helpers. Everything hangs off window.N. */
(function () {
  "use strict";
  const N = (window.N = window.N || {});

  /** h("div.card#id", {attrs, on: {click}}, ...children) */
  N.h = function h(spec, props, ...children) {
    const match = /^([a-z0-9]+)?((?:[.#][\w-]+)*)$/i.exec(spec);
    const el = document.createElement((match && match[1]) || "div");
    if (match && match[2]) {
      for (const part of match[2].match(/[.#][\w-]+/g)) {
        if (part[0] === ".") el.classList.add(part.slice(1));
        else el.id = part.slice(1);
      }
    }
    if (props && (typeof props !== "object" || props instanceof Node || Array.isArray(props))) {
      children.unshift(props);
      props = null;
    }
    for (const [key, value] of Object.entries(props || {})) {
      if (value === undefined || value === null || value === false) continue;
      if (key === "on") for (const [event, fn] of Object.entries(value)) el.addEventListener(event, fn);
      else if (key === "style" && typeof value === "object") Object.assign(el.style, value);
      else if (key === "html") el.innerHTML = value;
      else if (key === "dataset") Object.assign(el.dataset, value);
      else if (key in el && key !== "list" && typeof value !== "string") el[key] = value;
      else el.setAttribute(key, value === true ? "" : value);
    }
    append(el, children);
    return el;
  };

  function append(el, children) {
    for (const child of children.flat(Infinity)) {
      if (child === null || child === undefined || child === false) continue;
      el.appendChild(child instanceof Node ? child : document.createTextNode(String(child)));
    }
  }
  N.append = append;

  /** Replace an element's children; arrays are flattened and null/false skipped. */
  N.fill = function (el, ...children) {
    N.clear(el);
    append(el, children);
    return el;
  };

  N.clear = function (el) {
    while (el.firstChild) el.removeChild(el.firstChild);
    return el;
  };

  N.icon = function (name, size = 16) {
    const paths = N.ICONS[name] || N.ICONS.dot;
    const span = document.createElement("span");
    span.style.display = "inline-flex";
    span.innerHTML = `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round">${paths}</svg>`;
    return span.firstChild;
  };

  N.ICONS = {
    dot: '<circle cx="12" cy="12" r="3"/>',
    home: '<path d="M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z"/>',
    table: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18M3 15h18M9 4v16"/>',
    tasks: '<path d="M9 6h11M9 12h11M9 18h11"/><path d="m3.5 6 1.5 1.5L7.5 5M3.5 12l1.5 1.5L7.5 11M3.5 18l1.5 1.5L7.5 17"/>',
    database: '<ellipse cx="12" cy="5.5" rx="8" ry="2.5"/><path d="M4 5.5v13c0 1.4 3.6 2.5 8 2.5s8-1.1 8-2.5v-13M4 12c0 1.4 3.6 2.5 8 2.5s8-1.1 8-2.5"/>',
    folder: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
    search: '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
    play: '<path d="M7 4.5v15l12-7.5z"/>',
    stop: '<rect x="6" y="6" width="12" height="12" rx="1.5"/>',
    pause: '<rect x="6.5" y="5" width="3.5" height="14" rx="1"/><rect x="14" y="5" width="3.5" height="14" rx="1"/>',
    "arrow-up": '<path d="M12 19V5M6 11l6-6 6 6"/>',
    "arrow-down": '<path d="M12 5v14M6 13l6 6 6-6"/>',
    refresh: '<path d="M20 11a8 8 0 0 0-14.6-4.6L4 8M4 4v4h4M4 13a8 8 0 0 0 14.6 4.6L20 16m0 4v-4h-4"/>',
    scan: '<path d="M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3M4 12h16"/>',
    sync: '<path d="M4 12a8 8 0 0 1 13.7-5.7L20 8.5M20 4v4.5h-4.5M20 12a8 8 0 0 1-13.7 5.7L4 15.5M4 20v-4.5h4.5"/>',
    x: '<path d="M6 6l12 12M18 6 6 18"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    eye: '<path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',
    filter: '<path d="M3 5h18l-7 8v6l-4 2v-8z"/>',
    list: '<path d="M8 6h13M8 12h13M8 18h13M3.5 6h.01M3.5 12h.01M3.5 18h.01"/>',
    edit: '<path d="M4 20h4L19 9l-4-4L4 16z"/><path d="m13.5 6.5 4 4"/>',
    check: '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
    alert: '<path d="M12 9v4M12 17h.01"/><path d="M10.3 3.9 2.4 18a2 2 0 0 0 1.7 3h15.8a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
    moon: '<path d="M20 14.5A8 8 0 0 1 9.5 4 8 8 0 1 0 20 14.5z"/>',
    "sort-asc": '<path d="M7 4v16M3 8l4-4 4 4M14 6h7M14 12h5M14 18h3"/>',
    "sort-desc": '<path d="M7 4v16M3 16l4 4 4-4M14 6h3M14 12h5M14 18h7"/>',
    copy: '<rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V5a1 1 0 0 1 1-1h10"/>',
    "eye-off": '<path d="M3 3l18 18M10.6 6.1A9.8 9.8 0 0 1 12 6c5 0 9 6 9 6a17 17 0 0 1-3.1 3.6M6.6 6.6C4.2 8.2 3 12 3 12s4 6 9 6a9 9 0 0 0 4.4-1.1"/><path d="M9.9 9.9a3 3 0 0 0 4.2 4.2"/>',
    columns: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16M15 4v16"/>',
    chevron: '<path d="m6 9 6 6 6-6"/>',
    file: '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/>',
    zap: '<path d="M13 2 4 14h7l-1 8 9-12h-7z"/>',
    note: '<path d="M6 3h9l4 4v14H6z"/><path d="M15 3v4h4M9 12h7M9 16h5"/>',
    trash: '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3"/>',
    retry: '<path d="M4 12a8 8 0 1 0 2.3-5.7L4 8.5M4 4v4.5h4.5"/>',
    layers: '<path d="m12 3 9 5-9 5-9-5z"/><path d="m3 13 9 5 9-5"/>',
    compass: '<circle cx="12" cy="12" r="9"/><path d="m15.5 8.5-2 5-5 2 2-5z"/>',
    settings: '<path d="M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M20 18h0"/><circle cx="16" cy="6" r="2"/><circle cx="10" cy="12" r="2"/><circle cx="18" cy="18" r="2"/>',
    puzzle: '<path d="M10 3a2 2 0 1 1 4 0v2h4a1 1 0 0 1 1 1v4h-2a2 2 0 1 0 0 4h2v4a1 1 0 0 1-1 1h-4v-2a2 2 0 1 0-4 0v2H6a1 1 0 0 1-1-1v-4h2a2 2 0 1 0 0-4H5V6a1 1 0 0 1 1-1h4z"/>',
    download: '<path d="M12 4v11M7 10l5 5 5-5M5 20h14"/>',
  };

  N.fmt = {
    bytes(n) {
      if (n === null || n === undefined) return "";
      const units = ["B", "KB", "MB", "GB", "TB"];
      let i = 0;
      while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
      return (i === 0 ? String(n) : n.toFixed(n < 10 ? 1 : 0)) + " " + units[i];
    },
    number(value, unit) {
      if (value === null || value === undefined || value === "") return "";
      const n = Number(value);
      let text = Math.abs(n) >= 1000 || Number.isInteger(n) ? n.toLocaleString(undefined, { maximumFractionDigits: 2 })
        : n.toLocaleString(undefined, { maximumSignificantDigits: 4 });
      return unit ? `${text} ${unit}` : text;
    },
    time(text) {
      if (!text) return "";
      const date = new Date(text);
      if (isNaN(date)) return text;
      return date.toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit" });
    },
    ago(text) {
      if (!text) return "never";
      const seconds = (Date.now() - new Date(text).getTime()) / 1000;
      if (isNaN(seconds)) return text;
      if (seconds < 45) return "just now";
      if (seconds < 3600) return `${Math.round(seconds / 60)} min ago`;
      if (seconds < 86400) return `${Math.round(seconds / 3600)} h ago`;
      return `${Math.round(seconds / 86400)} d ago`;
    },
    duration(start, end) {
      if (!start) return "";
      const ms = (end ? new Date(end) : new Date()) - new Date(start);
      if (isNaN(ms)) return "";
      if (ms < 1000) return `${ms} ms`;
      if (ms < 60000) return `${(ms / 1000).toFixed(1)} s`;
      return `${Math.floor(ms / 60000)} min ${Math.round((ms % 60000) / 1000)} s`;
    },
    key(key) {
      return Object.values(key || {}).join(" / ");
    },
  };

  /** Put text on the clipboard; the older way when the page may not use the Clipboard API (as in uihtml). */
  N.copyText = async function (text) {
    try {
      if (navigator.clipboard && window.isSecureContext) { await navigator.clipboard.writeText(text); return; }
    } catch (e) { /* fall back */ }
    const area = document.createElement("textarea");
    area.value = text;
    area.style.position = "fixed";
    area.style.opacity = "0";
    document.body.appendChild(area);
    area.select();
    const ok = document.execCommand("copy");
    area.remove();
    if (!ok) throw new Error("the browser did not allow copying");
  };

  N.keyId = function (key) {
    return JSON.stringify(Object.keys(key).sort().map((k) => [k, key[k]]));
  };

  N.debounce = function (fn, ms) {
    let timer = null;
    return function (...args) {
      clearTimeout(timer);
      timer = setTimeout(() => fn.apply(this, args), ms);
    };
  };

  N.titleCase = (text) => String(text || "").replace(/[_-]+/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
})();
