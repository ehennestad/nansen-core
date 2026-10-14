/* The client side of the protocol: request(method, params) returns a promise of the result. */
(function () {
  "use strict";
  const N = (window.N = window.N || {});

  class ApiError extends Error {
    constructor(code, message) {
      super(message || code);
      this.code = code;
    }
  }

  class Client {
    constructor(transport) {
      this.transport = transport;
      this.nextId = 1;
      this.handlers = new Map();
      transport.listen((event) => this.dispatch(event));
    }
    async request(method, params = {}) {
      const response = await this.transport.send({ id: this.nextId++, method, params });
      if (response.error) throw new ApiError(response.error.code, response.error.message);
      return response.result;
    }
    on(event, handler) {
      if (!this.handlers.has(event)) this.handlers.set(event, new Set());
      this.handlers.get(event).add(handler);
      return () => this.handlers.get(event).delete(handler);
    }
    dispatch(message) {
      for (const handler of this.handlers.get(message.event) || []) handler(message.data);
      for (const handler of this.handlers.get("*") || []) handler(message);
    }
  }

  N.ApiError = ApiError;
  N.Client = Client;
})();
