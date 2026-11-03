#!/usr/bin/env python3
"""T47-AV-R1 fixture: a transport proxy that stalls or fails exactly one endpoint.

The two claims this card repairs are about *ordering* and *failure*, and neither can be produced with
the real fixture server:

  * **F1a — the create menu must not wait behind the threads read.** The sidebar asked
    `GET /api/v4/users/me/teams/{id}/threads` and only then resolved the create model, so a slow
    threads read left the whole session without a `+` (measured in the T47-AV run: 30 s after
    sign-in, no `nativeSidebarCreateMenu`). To reproduce a slow read without touching the server this
    proxy delays that one path and forwards everything else unchanged;
  * **F1b — a failed permission read must be distinguishable from "no permission".** A `500` on
    `POST /api/v4/roles/names` (and on `GET /api/v4/teams/{id}/members/me`, the other half of the
    union) is a read that did not happen; `--fail-permission-reads N` answers `500` to the first `N`
    requests of each, then forwards, so a retry that *actually re-runs* `load()` is observable: the
    second attempt succeeds and the ordinary menu appears.

It is a transport fixture, not a fake server: bodies and headers are passed through untouched, and
everything it does is logged, so the run's evidence is in the log rather than inferred from a missing
screen. It also serves `GET /__fixture/status` — the counters the live test asserts against (a threads
request still in flight when the `+` appeared; how many permission reads it refused).

    python3 scripts/t47_r1_fixture_proxy.py --listen 8076 --threads-delay 60
    python3 scripts/t47_r1_fixture_proxy.py --listen 8077 --fail-permission-reads 1

    curl -s http://127.0.0.1:8076/__fixture/status

Then point the app (and the suite's `MM_AV_STALL_SERVER` / `MM_AV_PERMISSION_SERVER`) at the proxy's
base URL. The WebSocket upgrade is not proxied — this fixture exists for one read's timing, and the
app's socket falls back like it does against any unreachable socket.
"""

import argparse
import json
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = "http://127.0.0.1:8065"
LOG_PATH = None
LOCK = threading.Lock()

# The two paths this fixture can bend. Matching is on the request path only (no query string).
THREADS = re.compile(r"^/api/v4/users/me/teams/[^/]+/threads/?$")
TEAM_MEMBERSHIP = re.compile(r"^/api/v4/teams/[^/]+/members/me/?$")
ROLE_NAMES = "/api/v4/roles/names"

STATE = {
    "threads_requests": 0,
    "threads_in_flight": 0,
    "threads_delayed": 0,
    "permission_requests": 0,
    "permission_failures_served": 0,
    "permission_failure_budget": 0,
    "total_requests": 0,
}

DELAY_SECONDS = 0.0


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

    # -- the fixture's own surface -----------------------------------------

    def _status(self):
        with LOCK:
            body = json.dumps(dict(STATE)).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _refuse(self, path, budget_key):
        with LOCK:
            if STATE[budget_key] <= 0:
                return False
            STATE[budget_key] -= 1
            STATE["permission_failures_served"] += 1
        body = json.dumps({
            "id": "app.t47r1.fixture.permission_read_failed",
            "message": "The fixture proxy refused this read on purpose (T47-AV-R1).",
            "status_code": 500,
        }).encode()
        self.send_response(500)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        log(f"{self.command} {path} 500 (fixture: permission read refused)")
        return True

    # -- the proxy ---------------------------------------------------------

    def _handle(self, method):
        path = self.path.split("?", 1)[0]
        if method == "GET" and path == "/__fixture/status":
            self._status()
            return

        with LOCK:
            STATE["total_requests"] += 1

        if method == "GET" and THREADS.match(path):
            with LOCK:
                STATE["threads_requests"] += 1
                STATE["threads_in_flight"] += 1
                if DELAY_SECONDS > 0:
                    STATE["threads_delayed"] += 1
            try:
                if DELAY_SECONDS > 0:
                    log(f"GET {path} (fixture: delaying {DELAY_SECONDS:g}s)")
                    time.sleep(DELAY_SECONDS)
                self._forward(method, path)
            finally:
                with LOCK:
                    STATE["threads_in_flight"] -= 1
            return

        permission_read = (method == "POST" and path == ROLE_NAMES) \
            or (method == "GET" and TEAM_MEMBERSHIP.match(path))
        if permission_read:
            with LOCK:
                STATE["permission_requests"] += 1
            if self._refuse(path, "permission_failure_budget"):
                return

        self._forward(method, path)

    def _forward(self, method, path):
        length = int(self.headers.get("Content-Length") or 0)
        payload = self.rfile.read(length) if length else None
        headers = {key: value for key, value in self.headers.items()
                   if key.lower() not in ("host", "connection", "content-length", "accept-encoding")}
        request = urllib.request.Request(UPSTREAM + self.path,
                                         data=payload, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
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
        log(f"{method} {path} {status}")

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def do_PUT(self):
        self._handle("PUT")

    def do_DELETE(self):
        self._handle("DELETE")


def main():
    global UPSTREAM, LOG_PATH, DELAY_SECONDS
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", type=int, default=8076)
    parser.add_argument("--upstream", default="http://127.0.0.1:8065")
    parser.add_argument("--threads-delay", type=float, default=0.0,
                        help="seconds to hold every GET /users/me/teams/{id}/threads (0 = forward)")
    parser.add_argument("--fail-permission-reads", type=int, default=0,
                        help="answer 500 to the first N POST /roles/names and N GET …/members/me")
    parser.add_argument("--log", default="build/logs/t47-r1-fixture-proxy.log")
    args = parser.parse_args()
    UPSTREAM = args.upstream.rstrip("/")
    LOG_PATH = args.log
    DELAY_SECONDS = args.threads_delay
    STATE["permission_failure_budget"] = args.fail_permission_reads
    open(LOG_PATH, "w", encoding="utf-8").close()
    server = ThreadingHTTPServer(("127.0.0.1", args.listen), Handler)
    server.daemon_threads = True
    print(f"T47-R1 fixture proxy on http://127.0.0.1:{args.listen} -> {UPSTREAM}"
          f" (threads delay {DELAY_SECONDS:g}s, {args.fail_permission_reads} refused permission read(s),"
          f" log {LOG_PATH})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
