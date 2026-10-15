"""Serve the app: the HTML/JS frontend, POST /api for requests, GET /events for a Server-Sent Events stream.

The server listens on this machine only, and answers only the page it served: each server has a random token,
which it writes into the index.html it serves (meta nansen-token). POST /api needs it in the X-Nansen-Token
header and GET /events as ?token=; a web page from anywhere else can neither read it nor send that header
without a CORS preflight, which this server never answers, so it cannot drive the app (cross-site requests).
Requests whose Host is not this machine (DNS rebinding) or whose Origin is another site are refused too.
"""

from __future__ import annotations

import json
import mimetypes
import hmac
import queue
import secrets
import threading
import webbrowser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Optional

from .api import Api

_PACKAGE_DIR = Path(__file__).resolve().parent
_UI_CANDIDATES = [_PACKAGE_DIR / "ui", _PACKAGE_DIR.parent.parent.parent / "ui"]


def ui_dir() -> Path:
    for candidate in _UI_CANDIDATES:
        if (candidate / "index.html").is_file():
            return candidate
    raise FileNotFoundError("the NANSEN frontend (ui/index.html) was not found")


class AppServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, api: Api, address=("127.0.0.1", 0), ui: Optional[Path] = None):
        self.api = api
        self.ui = Path(ui) if ui is not None else ui_dir()
        self.closing = threading.Event()
        self.token = secrets.token_urlsafe(24)
        super().__init__(address, _Handler)

    @property
    def url(self) -> str:
        host, port = self.server_address[:2]
        return f"http://{host}:{port}/"

    def shutdown(self) -> None:
        self.closing.set()
        super().shutdown()

    def handle_error(self, request, client_address) -> None:
        import sys

        if isinstance(sys.exc_info()[1], (BrokenPipeError, ConnectionResetError)):
            return  # a browser tab closed mid-request
        super().handle_error(request, client_address)


class _Handler(BaseHTTPRequestHandler):
    server: AppServer
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):  # keep the console quiet
        pass

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        try:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass  # the page went away before the answer; nothing to do

    LOCAL_HOSTS = ("127.0.0.1", "localhost", "[::1]")

    def _local(self) -> bool:
        """Whether the request names this machine as its Host, and comes from no other site (Origin)."""
        port = self.server.server_address[1]
        host = (self.headers.get("Host") or "").strip().lower()
        if host not in {f"{h}:{port}" for h in self.LOCAL_HOSTS} | set(self.LOCAL_HOSTS):
            return False
        origin = self.headers.get("Origin")
        return origin is None or origin.lower() in {f"http://{h}:{port}" for h in self.LOCAL_HOSTS}

    def _authorised(self, token: Optional[str]) -> bool:
        return self._local() and token is not None and hmac.compare_digest(token, self.server.token)

    def do_POST(self):
        if self.path != "/api":
            self._send(HTTPStatus.NOT_FOUND, b"not found", "text/plain")
            return
        if not self._authorised(self.headers.get("X-Nansen-Token")):
            self._send(HTTPStatus.FORBIDDEN, b"forbidden: this app answers only the page it served", "text/plain")
            return
        length = int(self.headers.get("Content-Length", 0))
        try:
            request = json.loads(self.rfile.read(length) or b"null")
        except json.JSONDecodeError:
            request = None
        response = self.server.api.handle(request)
        self._send(HTTPStatus.OK, json.dumps(response, default=str).encode("utf-8"), "application/json")

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if not self._local():
            self._send(HTTPStatus.FORBIDDEN, b"forbidden", "text/plain")
            return
        if path == "/events":
            from urllib.parse import parse_qs
            if not self._authorised(parse_qs(query).get("token", [None])[0]):
                self._send(HTTPStatus.FORBIDDEN, b"forbidden", "text/plain")
                return
            self._stream_events()
            return
        if path == "/":
            path = "/index.html"
        target = (self.server.ui / path.lstrip("/")).resolve()
        if self.server.ui.resolve() not in target.parents or not target.is_file():
            self._send(HTTPStatus.NOT_FOUND, b"not found", "text/plain")
            return
        content_type = mimetypes.guess_type(str(target))[0] or "application/octet-stream"
        if content_type.startswith("text/") or content_type == "application/javascript":
            content_type += "; charset=utf-8"
        body = target.read_bytes()
        if target.name == "index.html":   # the page gets the token it answers with
            body = body.replace(b'<meta charset="utf-8">',
                                b'<meta charset="utf-8">\n  <meta name="nansen-token" content="' + self.server.token.encode() + b'">', 1)
        self._send(HTTPStatus.OK, body, content_type)

    def _stream_events(self):
        events: "queue.Queue[dict]" = queue.Queue()
        unsubscribe = self.server.api.subscribe(events.put)
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        try:
            self.wfile.write(b": connected\n\n")
            self.wfile.flush()
            while not self.server.closing.is_set():
                try:
                    event = events.get(timeout=10)
                    payload = "data: " + json.dumps(event, default=str) + "\n\n"
                except queue.Empty:
                    payload = ": ping\n\n"
                self.wfile.write(payload.encode("utf-8"))
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            unsubscribe()


def serve(api: Api, host: str = "127.0.0.1", port: int = 0) -> AppServer:
    """Start serving in a background thread; returns the server (call shutdown() to stop)."""
    server = AppServer(api, (host, port))
    threading.Thread(target=server.serve_forever, name="nansen-app-server", daemon=True).start()
    return server


def open_app(project=None, namespace: Optional[dict] = None, catalog=None, port: int = 0,
             open_browser: bool = True) -> AppServer:
    """Open the dashboard from Python, for example in a notebook, without blocking it.

    With namespace (such as globals()), "Send to workspace" in the dashboard puts the selected entities
    there. Returns the server; call shutdown() on it to stop.
    """
    from .catalog import Catalog, default_catalog_path
    from .project import Project

    if project is not None and not isinstance(project, Project):
        project = Project.open(project)
    catalog = catalog if catalog is not None else Catalog(default_catalog_path())
    api = Api(catalog=catalog, project=project, start_queue=catalog.settings()["queue"]["autoStart"])
    api.workspace = namespace
    server = serve(api, port=port)
    if open_browser:
        webbrowser.open(server.url)
    return server


def run_app(api: Api, host: str = "127.0.0.1", port: int = 8765, open_browser: bool = True) -> None:
    """Serve until interrupted."""
    server = AppServer(api, (host, port))
    print(f"NANSEN is running at {server.url} (Ctrl+C to stop)")
    if open_browser:
        webbrowser.open(server.url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
        api.close()
