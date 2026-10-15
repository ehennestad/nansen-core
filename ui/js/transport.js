/* Transports carry protocol messages (docs/reference/protocol.md) to the core and events back.
   HTTP when served by Python (POST /api, GET /events); uihtml when shown by MATLAB. */
(function () {
  "use strict";
  const N = (window.N = window.N || {});

  class HttpTransport {
    constructor(base = "") {
      this.base = base;
      const meta = document.querySelector('meta[name="nansen-token"]');
      this.token = meta ? meta.content : "";   // the server answers only the page it served (with this token)
      this.kind = "http";
      this.listeners = [];
      this.statusListeners = [];
      this.source = null;
    }
    async send(request) {
      const response = await fetch(this.base + "/api", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Nansen-Token": this.token },
        body: JSON.stringify(request),
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      return response.json();
    }
    listen(listener) {
      this.listeners.push(listener);
      if (!this.source) this.open();
    }
    onStatus(listener) {
      this.statusListeners.push(listener);
    }
    open() {
      this.source = new EventSource(this.base + "/events?token=" + encodeURIComponent(this.token));
      this.source.onopen = () => this.statusListeners.forEach((l) => l(true));
      this.source.onerror = () => this.statusListeners.forEach((l) => l(false));
      this.source.onmessage = (message) => {
        let event;
        try { event = JSON.parse(message.data); } catch (e) { return; }
        this.listeners.forEach((l) => l(event));
      };
    }
  }

  class MatlabTransport {
    constructor(htmlComponent) {
      this.kind = "matlab";
      this.component = htmlComponent;
      this.pending = new Map();
      this.listeners = [];
      htmlComponent.addEventListener("response", (event) => {
        const response = typeof event.Data === "string" ? JSON.parse(event.Data) : event.Data;
        const waiting = this.pending.get(response.id);
        if (waiting) {
          this.pending.delete(response.id);
          waiting(response);
        }
      });
      htmlComponent.addEventListener("event", (event) => {
        const message = typeof event.Data === "string" ? JSON.parse(event.Data) : event.Data;
        this.listeners.forEach((l) => l(message));
      });
    }
    send(request) {
      return new Promise((resolve) => {
        this.pending.set(request.id, resolve);
        this.component.sendEventToMATLAB("request", JSON.stringify(request));
      });
    }
    listen(listener) {
      this.listeners.push(listener);
    }
    onStatus(listener) {
      listener(true);
    }
  }

  N.HttpTransport = HttpTransport;
  N.MatlabTransport = MatlabTransport;

  /* Resolve with a transport: MATLAB calls window.setup(htmlComponent) when it shows the page in a
     uihtml (inside an iframe); a page served by Python is the top window and talks HTTP. */
  // Defined as soon as this script runs: MATLAB may call setup before the app starts, and the call is kept.
  let matlabComponent = null;
  let onSetup = null;
  const earlyProblems = [];
  const report = (text) => {
    if (matlabComponent) matlabComponent.sendEventToMATLAB("page", text);
    else earlyProblems.push(text);
  };
  // Errors on the page reach MATLAB (nansen.App shows them), where there is no developer console.
  window.addEventListener("error", (event) => report(`error: ${event.message} (${event.filename || ""}:${event.lineno || ""})`));
  window.addEventListener("unhandledrejection", (event) => report(`unhandled: ${event.reason && event.reason.message || event.reason}`));
  window.setup = (htmlComponent) => {
    matlabComponent = htmlComponent;
    report(`hello: ${navigator.userAgent}`);
    earlyProblems.splice(0).forEach(report);
    if (onSetup) onSetup(htmlComponent);
  };

  N.connect = function () {
    return new Promise((resolve) => {
      let done = false;
      const finish = (transport) => {
        if (!done) {
          done = true;
          resolve(transport);
        }
      };
      if (matlabComponent) {
        finish(new MatlabTransport(matlabComponent));
        return;
      }
      onSetup = (htmlComponent) => finish(new MatlabTransport(htmlComponent));
      const embedded = window.parent !== window;
      setTimeout(() => finish(new HttpTransport("")), embedded ? 4000 : 0);
    });
  };
})();
