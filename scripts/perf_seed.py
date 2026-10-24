#!/usr/bin/env python3
"""Seed a throwaway Mattermost server for the T27 performance probe.

Why this exists: the T27 baseline has to measure the *real* Mattermost web app inside the
shell's WKWebView, because that is where the memory claim comes from. A synthetic page would
measure the synthetic page. So the probe runs against a local Mattermost server
(`scripts/perf_probe.sh --server-start` starts one via Docker) and this script creates the
fixed workspace the scripted sequence walks through:

    user     perf-probe (a throwaway account created on the local server)
    team     perf
    channel  town-square  (type O, ~N seeded posts)
    thread   the root post of the channel gets M replies, so "open a thread" has something
             real to open

Everything is idempotent: re-running against the same server reuses the user/team/channel and
only tops the post count back up to the requested number. Credentials are written to a
0600 file *outside* the repository tree (default: the probe run directory) and are never
committed — they exist only on a local throwaway server.

Usage:
    python3 scripts/perf_seed.py --url http://127.0.0.1:8065 --posts 180 --replies 24 \
        --creds-out build/perf/creds.json
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sys
import urllib.error
import urllib.request

USERNAME = "perfprobe"
EMAIL = "perfprobe@example.invalid"
PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
TEAM_NAME = "perf"
TEAM_DISPLAY = "Perf"
# A dedicated channel, NOT the team default (town-square): the probe's scripted sequence must
# *open* a channel from the one the app lands on, so the measured "open channel" step is a real
# channel switch rather than a no-op. town-square stays empty on purpose.
CHANNEL_NAME = "perf-feed"
CHANNEL_DISPLAY = "Perf Feed"


class APIError(RuntimeError):
    pass


class Client:
    def __init__(self, base: str, token: str | None = None):
        self.base = base.rstrip("/")
        self.token = token

    def call(self, method: str, path: str, body: dict | None = None
             ) -> tuple[int, dict | list | None, dict[str, str]]:
        url = f"{self.base}/api/v4{path}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Content-Type", "application/json")
        # Without this header Mattermost refuses the JSON error/response path it uses for API
        # clients (it answers with an HTML/redirect flow instead).
        req.add_header("X-Requested-With", "XMLHttpRequest")
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
                headers = {k.lower(): v for k, v in resp.headers.items()}
                return resp.status, (json.loads(raw) if raw.strip() else None), headers
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            try:
                payload = json.loads(raw)
            except Exception:
                payload = {"raw": raw.decode(errors="replace")}
            headers = {k.lower(): v for k, v in exc.headers.items()}
            return exc.code, payload, headers

    def must(self, method: str, path: str, body: dict | None = None) -> dict | list:
        status, payload, _ = self.call(method, path, body)
        if status >= 300:
            raise APIError(f"{method} {path} -> {status}: {json.dumps(payload)[:400]}")
        return payload  # type: ignore[return-value]


def login_or_signup(base: str) -> str:
    """Log in (creating the throwaway account on a fresh server) and return its session token.

    Mattermost 9.x returns the session token in the `Token:` response header, not in the body
    (the body carries the user object); the cookie jar is what the web app uses. Measured on
    server 9.11.19.
    """
    anon = Client(base)
    status, payload, headers = anon.call("POST", "/users/login",
                                         {"login_id": EMAIL, "password": PASSWORD})
    if status == 200 and headers.get("token"):
        return headers["token"]
    # Fresh server (or the account was dropped): create it. The first user is system admin,
    # which is what lets this script create a team on a server with open signup disabled.
    anon.call("POST", "/users", {
        "email": EMAIL, "username": USERNAME, "password": PASSWORD,
        "first_name": "Perf", "last_name": "Probe",
    })
    status, payload, headers = anon.call("POST", "/users/login",
                                         {"login_id": EMAIL, "password": PASSWORD})
    if status != 200 or not headers.get("token"):
        raise APIError(f"login failed after signup: {status} {payload}")
    return headers["token"]


def ensure_team(c: Client, user_id: str) -> str:
    status, payload, _ = c.call("GET", f"/users/{user_id}/teams")
    if status == 200 and isinstance(payload, list):
        for team in payload:
            if team.get("name") == TEAM_NAME:
                return team["id"]
    team = c.must("POST", "/teams", {"name": TEAM_NAME, "display_name": TEAM_DISPLAY,
                                     "type": "O"})
    return team["id"]  # type: ignore[index]


def ensure_channel(c: Client, team_id: str) -> str:
    status, payload, _ = c.call("GET", f"/teams/{team_id}/channels/name/{CHANNEL_NAME}")
    if status == 200 and isinstance(payload, dict):
        return payload["id"]
    ch = c.must("POST", "/channels", {"team_id": team_id, "name": CHANNEL_NAME,
                                      "display_name": CHANNEL_DISPLAY, "type": "O"})
    return ch["id"]  # type: ignore[index]


def post_count(c: Client, channel_id: str) -> int:
    """Count the channel's posts by walking pages.

    `GET /channels/{id}/posts` has no `total_count` on server 9.11.19 (measured — it returns
    `order`/`posts`/`has_next` only), so count by paging until `has_next` is false.
    """
    total = 0
    page = 0
    while True:
        status, payload, _ = c.call(
            "GET", f"/channels/{channel_id}/posts?page={page}&per_page=200")
        if status != 200 or not isinstance(payload, dict):
            return total
        total += len(payload.get("order") or [])
        if not payload.get("has_next"):
            return total
        page += 1
        if page > 200:  # defensive: never loop forever on a broken server
            return total


LINES = [
    "standup notes: nothing blocking, still on the transport layer",
    "the release is cut, changelog is in the doc",
    "can you take a look at the flaky test when you get a minute?",
    "pushed a fix for the reconnect backoff, it retried 12 times in a row before",
    "reminder: design review moved to 15:30",
    "```\nfunc backoff(attempt: Int) -> TimeInterval { min(30, pow(2, Double(attempt))) }\n```",
    "**text-only** posts are deliberately seeded here — no attachments, no images",
    "the webview memory number is the whole reason this channel exists",
    "anyone else seeing the scroll jump when new posts arrive?",
    "quoting the API doc: `page`/`per_page` and `before`/`after` both need to round-trip",
    "ack, on it",
    "noticed the sidebar re-renders on every keystroke in the composer, worth a look",
    "deploy is green, health check passing",
    "**thread reply** traffic goes through `/api/v4/posts` with a `root_id`",
    "who owns the certificate prompt path? need a second pair of eyes on the trust bag",
]


def seed_posts(c: Client, channel_id: str, user_id: str, want: int, replies: int,
               rng: random.Random, known_root: str | None = None) -> dict:
    """Create `want` posts; the **newest** post is the thread root carrying `replies` replies.

    Ordering matters for the probe: the web app virtualises the post list, so only posts near the
    viewport are in the DOM. Making the thread root the newest post puts its "N replies"
    affordance on screen at the bottom of the channel, which is where the scripted "open a thread"
    step looks after scrolling. (Earlier the root was created first — oldest — and was never
    rendered, which is exactly the failure the first harness run hit.)
    """
    existing = post_count(c, channel_id)
    made = 0
    root_id = None
    if known_root:
        status, post, _ = c.call("GET", f"/posts/{known_root}")
        if status == 200 and isinstance(post, dict) and not post.get("delete_at"):
            root_id = known_root
    while existing + made < want:
        post = c.must("POST", "/posts", {
            "channel_id": channel_id,
            "message": f"{rng.choice(LINES)}  _(seed #{existing + made + 1})_",
        })
        made += 1
    if root_id is None:
        post = c.must("POST", "/posts", {
            "channel_id": channel_id,
            "message": "**thread root** — this post carries the replies the perf probe opens",
        })
        root_id = post["id"]  # type: ignore[index]
        made += 1
    # Replies on the thread root (idempotent: top up to `replies`).
    status, thread, _ = c.call("GET", f"/posts/{root_id}/thread")
    have = 0
    if status == 200 and isinstance(thread, dict):
        have = max(0, len(thread.get("order") or []) - 1)
    while have < replies:
        c.must("POST", "/posts", {"channel_id": channel_id, "root_id": root_id,
                                  "message": f"thread reply {have + 1}: {rng.choice(LINES)}"})
        have += 1
    return {"channel_total_posts": post_count(c, channel_id),
            "created": made, "root_post_id": root_id, "thread_replies": have}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8065")
    ap.add_argument("--posts", type=int, default=180)
    ap.add_argument("--replies", type=int, default=24)
    ap.add_argument("--seed", type=int, default=27)
    ap.add_argument("--creds-out", required=True,
                    help="where to write the throwaway credentials (never inside docs/)")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    token = login_or_signup(args.url)
    c = Client(args.url, token)
    me = c.must("GET", "/users/me")
    user_id = me["id"]  # type: ignore[index]
    team_id = ensure_team(c, user_id)
    channel_id = ensure_channel(c, team_id)
    # Join the channel explicitly (creator is already a member; harmless if so).
    c.call("POST", f"/channels/{channel_id}/members", {"user_id": user_id})
    # Reuse the thread root recorded by a previous seeding run of the same server, so a re-run
    # extends one thread instead of stacking a second root at the bottom of the channel.
    known_root = None
    creds_path = os.path.abspath(os.path.expanduser(args.creds_out))
    if os.path.exists(creds_path):
        try:
            with open(creds_path) as fh:
                known_root = json.load(fh).get("root_post_id")
        except (json.JSONDecodeError, OSError):
            known_root = None
    stats = seed_posts(c, channel_id, user_id, args.posts, args.replies, rng, known_root)

    creds = {
        "url": args.url,
        "login_id": EMAIL,
        "password": PASSWORD,
        "team_name": TEAM_NAME,
        "channel_name": CHANNEL_NAME,
        "user_id": user_id,
        "team_id": team_id,
        "channel_id": channel_id,
        **stats,
    }
    out = os.path.abspath(os.path.expanduser(args.creds_out))
    os.makedirs(os.path.dirname(out), exist_ok=True)
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        json.dump(creds, fh, indent=2)
    # Machine-readable one-liner for the shell wrapper.
    print(json.dumps(creds))
    return 0


if __name__ == "__main__":
    sys.exit(main())
