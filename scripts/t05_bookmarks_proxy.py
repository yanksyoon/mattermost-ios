#!/usr/bin/env python3
"""t_05caa678 fixture: a transport proxy that answers the channel-bookmarks route.

Why this exists: the pinned 9.11.19 Team Edition fixture has **no** bookmarks route — every
`/api/v4/channels/{id}/bookmarks` call is a 404 `api.context.404.app_error` (measured for T52 with
`scripts/t52_channel_probe.py`, re-measured for this card). That makes "a 404 draws no bar" a fact
the real server can state, and leaves "a 200 draws the bar in the server's order" unprovable there.

This proxy is a **transport** fixture, not a fake server: every request is forwarded to the real
fixture untouched except

  * `GET /api/v4/channels/{id}/bookmarks` → `200` with the three-bookmark list below, whose
    `sort_order` values are deliberately **not** alphabetical and **not** id order, so the screen
    can only pass by drawing the server's order;
  * `GET /__fixture/bookmarks` → the same list, as JSON, so the live test's oracle reads the fixture
    rather than carrying a copy of it;
  * `GET /__fixture/status` → counters (`bookmarks_requests`), so "one fetch per pane appearance" is
    measured instead of assumed.

The list's ids are stable, so a test can address the chips by identifier.

    python3 scripts/t05_bookmarks_proxy.py --listen 8078
    curl -s http://127.0.0.1:8078/__fixture/bookmarks | python3 -m json.tool
    curl -s http://127.0.0.1:8078/__fixture/status

Then point the app at `http://127.0.0.1:8078` (`MM_BOOKMARKS_SERVER`) and run
`MattermostUITests/T05ChannelHeaderUITests/testDABookmarks200DrawsTheBarInServerOrder`.

The WebSocket upgrade is not proxied (the app's socket falls back, the same as against any
unreachable socket); the pane's REST reads are what this fixture is for.
"""

import argparse
import json
import re
import sys
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = "http://127.0.0.1:8065"
LOG_PATH = None
LOCK = threading.Lock()

BOOKMARKS_PATH = re.compile(r"^/api/v4/channels/(?P<channel>[^/]+)/bookmarks/?$")

# Deliberately: sort_order 30 / 10 / 20, ids b-…/a-…/c-…, names "Zebra" / "Apple" / "Mango".
# Drawing anything but sort_order order (ids, names, arrival order) cannot match this.
BOOKMARKS = [
    {
        "id": "t05bookmark0000000000000003",
        "channel_id": "fixture",
        "create_at": 0,
        "update_at": 0,
        "delete_at": 0,
        "owner_id": "fixture",
        "display_name": "Zebra",
        "type": "link",
        "link_url": "https://example.com/zebra",
        "image_url": "",
        "emoji": "",
        "file_id": "",
        "sort_order": 30,
    },
    {
        "id": "t05bookmark0000000000000001",
        "channel_id": "fixture",
        "create_at": 0,
        "update_at": 0,
        "delete_at": 0,
        "owner_id": "fixture",
        "display_name": "Apple",
        "type": "link",
        "link_url": "https://example.com/apple",
        "image_url": "",
        "emoji": "",
        "file_id": "",
        "sort_order": 10,
    },
    {
        "id": "t05bookmark0000000000000002",
        "channel_id": "fixture",
        "create_at": 0,
        "update_at": 0,
        "delete_at": 0,
        "owner_id": "fixture",
        "display_name": "Mango",
        "type": "link",
        "link_url": "https://example.com/mango",
        "image_url": "",
        "emoji": "",
        "file_id": "",
        "sort_order": 20,
    },
]

STATE = {
    "total_requests": 0,
    "bookmarks_requests": 0,
    # Per channel, because "one fetch" is a fact about one channel's bar: the shell opens a channel
    # of its own on launch, and that bar asking for its own bookmarks is not this pane asking twice.
    "bookmarks_requests_by_channel": {},
}


def log(line):
    if not LOG_PATH:
        return
    with open(LOG_PATH, "a", encoding="utf-8") as handle:
        handle.write(line + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):  # noqa: A002 — matches the base class signature
        return

    def _json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle(self, method):
        path = self.path.split("?", 1)[0]
        if method == "GET" and path == "/__fixture/status":
            with LOCK:
                self._json(200, dict(STATE))
            return
        if method == "GET" and path == "/__fixture/bookmarks":
            self._json(200, BOOKMARKS)
            return

        with LOCK:
            STATE["total_requests"] += 1

        bookmarks = BOOKMARKS_PATH.match(path)
        if bookmarks and method == "GET":
            channel_id = bookmarks.group("channel")
            with LOCK:
                STATE["bookmarks_requests"] += 1
                per_channel = STATE["bookmarks_requests_by_channel"]
                per_channel[channel_id] = per_channel.get(channel_id, 0) + 1
            self._json(200, BOOKMARKS)
            log(f"GET {path} 200 (fixture: {len(BOOKMARKS)} bookmarks)")
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
        self._guarded("GET")

    def do_POST(self):
        self._guarded("POST")

    def do_PUT(self):
        self._guarded("PUT")

    def do_DELETE(self):
        self._guarded("DELETE")

    def _guarded(self, method):
        """A fixture bug must look like a fixture bug (500 + a log line), not like a dead socket.

        The first version of this proxy crashed inside the handler on a regex group that did not
        exist; the client saw a dropped connection and the bar silently drew nothing, which read on
        screen like an app defect.
        """
        try:
            self._handle(method)
        except Exception as error:  # noqa: BLE001 — the whole point is to survive anything
            log(f"{method} {self.path} EXCEPTION {error!r}")
            try:
                self._json(500, {"error": f"fixture exception: {error!r}"})
            except Exception:  # noqa: BLE001 — headers may already be sent
                pass


def main():
    global UPSTREAM, LOG_PATH
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", type=int, default=8078)
    parser.add_argument("--upstream", default="http://127.0.0.1:8065")
    parser.add_argument("--log", default="build/logs/t05-bookmarks-proxy.log")
    args = parser.parse_args()
    UPSTREAM = args.upstream.rstrip("/")
    LOG_PATH = args.log
    open(LOG_PATH, "w", encoding="utf-8").close()
    server = ThreadingHTTPServer(("127.0.0.1", args.listen), Handler)
    server.daemon_threads = True
    print(f"T05 bookmarks fixture proxy on http://127.0.0.1:{args.listen} -> {UPSTREAM}"
          f" (log {LOG_PATH})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
