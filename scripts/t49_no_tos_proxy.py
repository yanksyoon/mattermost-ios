#!/usr/bin/env python3
"""T49 fixture: a Mattermost server that publishes **no** custom terms of service.

The local `mm-perf` instance is Mattermost Team Edition, which has no license for the
custom-terms feature, so the document had to be inserted straight into Postgres
(`docs/t49-build-note.md` §2). The server caches that document in memory, so deleting the row
does not make it disappear from `GET /api/v4/terms_of_service` until the container restarts — and
this host's sandbox refuses container lifecycle commands.

This proxy is the honest stand-in for "a server with no custom terms": it forwards every request
to the real server unchanged and answers `404` for the one endpoint that would carry a document
(the same answer a server with the feature off gives). It also **logs every request** it proxies,
which is what makes the "no gate" run evidence: the app asking for `/api/v4/terms_of_service` and
being told there is nothing is visible in the log, rather than inferred from a missing screen.

    python3 scripts/t49_no_tos_proxy.py --listen 8066 --upstream http://127.0.0.1:8065

Nothing here inspects or rewrites bodies; it is a transport fixture, not a fake gate.
"""

import argparse
import json
import sys
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = "http://127.0.0.1:8065"
LOG_PATH = None
LOCK = threading.Lock()

# The one path that carries the document. `/users/{id}/terms_of_service` is answered by the real
# server (it 404s here anyway, because no `usertermsofservice` row exists) — the gate decides from
# the document endpoint, so that is the one that must say "nothing" for this run.
STUBBED = ("/api/v4/terms_of_service",)


def log(line):
    if not LOG_PATH:
        return
    with LOCK:
        with open(LOG_PATH, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):  # noqa: A002 — matches the base class signature
        pass

    def _handle(self, method):
        path = self.path.split("?", 1)[0]
        if method == "GET" and path in STUBBED:
            body = json.dumps({
                "id": "app.terms_of_service.get.no_rows.app_error",
                "message": "No terms of service found.",
                "status_code": 404,
            }).encode()
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            log(f"{method} {self.path} 404 (stubbed: no custom terms)")
            return

        length = int(self.headers.get("Content-Length") or 0)
        payload = self.rfile.read(length) if length else None
        headers = {key: value for key, value in self.headers.items()
                   if key.lower() not in ("host", "connection", "content-length", "accept-encoding")}
        request = urllib.request.Request(UPSTREAM + self.path,
                                         data=payload, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                status, body, response_headers = response.status, response.read(), response.headers
        except urllib.error.HTTPError as error:
            status, body, response_headers = error.code, error.read(), error.headers
        except Exception as error:  # noqa: BLE001 — a fixture: report and keep serving
            status, body, response_headers = 502, str(error).encode(), None

        self.send_response(status)
        if response_headers is not None:
            for key, value in response_headers.items():
                if key.lower() in ("content-length", "transfer-encoding", "connection"):
                    continue
                self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if method != "HEAD":
            self.wfile.write(body)
        log(f"{method} {self.path} {status}")

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def do_PUT(self):
        self._handle("PUT")

    def do_DELETE(self):
        self._handle("DELETE")


def main():
    global UPSTREAM, LOG_PATH
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", type=int, default=8066)
    parser.add_argument("--upstream", default="http://127.0.0.1:8065")
    parser.add_argument("--log", default="build/logs/t49-no-tos-proxy.log")
    args = parser.parse_args()
    UPSTREAM = args.upstream.rstrip("/")
    LOG_PATH = args.log
    open(LOG_PATH, "w", encoding="utf-8").close()
    server = ThreadingHTTPServer(("127.0.0.1", args.listen), Handler)
    server.daemon_threads = True
    print(f"T49 no-terms fixture on http://127.0.0.1:{args.listen} -> {UPSTREAM} (log {LOG_PATH})",
          flush=True)
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
