#!/usr/bin/env python3
"""AV probe (T35-AV): does the *server* dedupe a replayed `pending_post_id`?

T35's build note claims (docs/t35-build-note.md §2.5) that a send whose answer was lost
"cannot become two messages" because a retry re-sends the same `pending_post_id`.
That claim is only true if the server treats `pending_post_id` as an idempotency key.
This probe measures the server's actual answer with no app involved:
create a post with pending_post_id P, then create another with the same P, then count
what the channel holds.

Usage: python3 scripts/av_t35_pending_id_replay.py [--url http://127.0.0.1:8065]
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request

USERNAME = "perfprobe"
PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
CHANNEL = "t35-composer"
TEAM = "perf"


class Client:
    def __init__(self, base: str, token: str | None = None):
        self.base = base.rstrip("/")
        self.token = token

    def call(self, method: str, path: str, body: dict | None = None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(f"{self.base}/api/v4{path}", data=data, method=method)
        req.add_header("Content-Type", "application/json")
        req.add_header("X-Requested-With", "XMLHttpRequest")
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
                return resp.status, (json.loads(raw) if raw.strip() else None), resp.headers
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            try:
                payload = json.loads(raw)
            except Exception:
                payload = {"raw": raw.decode(errors="replace")}
            return exc.code, payload, exc.headers

    def must(self, method: str, path: str, body: dict | None = None):
        status, payload, headers = self.call(method, path, body)
        if status >= 300:
            raise SystemExit(f"{method} {path} -> {status}: {json.dumps(payload)[:400]}")
        return payload, headers


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8065")
    args = ap.parse_args()

    anon = Client(args.url)
    status, payload, headers = anon.call("POST", "/users/login",
                                         {"login_id": USERNAME, "password": PASSWORD})
    if status != 200:
        raise SystemExit(f"login failed {status}: {json.dumps(payload)[:300]}")
    token = headers.get("Token")
    c = Client(args.url, token)

    teams, _ = c.must("GET", "/users/me/teams")
    team = next((t for t in teams if t["name"] == TEAM), None)
    if not team:
        raise SystemExit(f"team #{TEAM} missing")
    channel, _ = c.must("GET", f"/teams/{team['id']}/channels/name/{CHANNEL}")

    stamp = int(time.time() * 1000)
    message = f"av replay probe {stamp}"
    pending = f"pending:av-replay-{stamp}"

    first, _ = c.must("POST", "/posts", {"channel_id": channel["id"],
                                         "message": message,
                                         "pending_post_id": pending})
    second_status, second, _ = c.call("POST", "/posts", {"channel_id": channel["id"],
                                                         "message": message,
                                                         "pending_post_id": pending})

    page, _ = c.must("GET", f"/channels/{channel['id']}/posts?per_page=200&collapsedThreads=true")
    order = page.get("order") or []
    posts = page.get("posts") or {}
    matches = [posts[i] for i in order if posts.get(i, {}).get("message") == message]

    print(json.dumps({
        "pending_post_id": pending,
        "first_create": {"status": 201, "id": first.get("id"),
                         "pending_post_id": first.get("pending_post_id")},
        "replay_status": second_status,
        "replay_id": (second or {}).get("id"),
        "same_id_returned": (second or {}).get("id") == first.get("id"),
        "posts_in_channel_with_this_message": len(matches),
        "ids": [p.get("id") for p in matches],
        "deduped_by_server": len(matches) == 1,
    }, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
