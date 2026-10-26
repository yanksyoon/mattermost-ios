#!/usr/bin/env python3
"""Seed the channel the T35 composer UI suite writes into.

Why a separate channel: the T35 suite *posts* (that is the surface under test), so it needs a
channel the T34 fixtures do not read. `t34-showcase` and `perf-feed` are read-only oracles for
other cards; writing into them would make their assertions depend on run order.

What it creates (idempotent, re-running is a no-op):

    team     perf                    (reused if the probe seed already made it)
    user     perfprobe               (the local throwaway probe account, reused)
    channel  t35-composer            (type O)
    post     one fixture line        so the channel is not empty when the suite opens it

Nothing here touches a real workspace: the server is the local throwaway at 127.0.0.1:8065 and the
credentials are the ones `scripts/perf_seed.py` already publishes in this repo.

Usage:
    python3 scripts/t35_composer_seed.py --url http://127.0.0.1:8065
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request

USERNAME = "perfprobe"
EMAIL = "perfprobe@example.invalid"
PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
TEAM_NAME = "perf"
TEAM_DISPLAY = "Perf"
CHANNEL_NAME = "t35-composer"
CHANNEL_DISPLAY = "T35 Composer"
FIXTURE_MESSAGE = "T35 composer fixture — the native composer writes into this channel."
# A second team, so the draft test can prove a draft survives a **team** switch and not merely a
# channel switch (the card names both).
SECOND_TEAM_NAME = "t35-second"
SECOND_TEAM_DISPLAY = "T35 Second"
SECOND_CHANNEL_NAME = "t35-second-chat"
SECOND_CHANNEL_DISPLAY = "T35 Second Chat"


class APIError(RuntimeError):
    pass


class Client:
    def __init__(self, base: str, token: str | None = None):
        self.base = base.rstrip("/")
        self.token = token

    def call(self, method: str, path: str, body: dict | None = None):
        url = f"{self.base}/api/v4{path}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Content-Type", "application/json")
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
            return exc.code, payload, {k.lower(): v for k, v in exc.headers.items()}

    def must(self, method: str, path: str, body: dict | None = None):
        status, payload, _ = self.call(method, path, body)
        if status >= 300:
            raise APIError(f"{method} {path} -> {status}: {json.dumps(payload)[:400]}")
        return payload


def login(base: str) -> tuple[str, str]:
    anon = Client(base)
    status, payload, headers = anon.call("POST", "/users/login",
                                         {"login_id": EMAIL, "password": PASSWORD})
    if status != 200 or not headers.get("token"):
        raise APIError(f"could not sign in as {USERNAME}: {status} {payload}\n"
                       "run scripts/perf_seed.py first (it creates the probe account)")
    # `GET /users/me` is the only way to learn the id from a token alone.
    me = Client(base, headers["token"]).must("GET", "/users/me")
    return headers["token"], me["id"]


def ensure_team(client: Client, name: str = TEAM_NAME, display: str = TEAM_DISPLAY) -> str:
    teams = client.must("GET", "/users/me/teams") or []
    for team in teams:
        if team.get("name") == name:
            return team["id"]
    team = client.must("POST", "/teams", {"name": name, "display_name": display, "type": "O"})
    return team["id"]


def ensure_channel(client: Client, team_id: str, name: str = CHANNEL_NAME,
                   display: str = CHANNEL_DISPLAY) -> dict:
    status, payload, _ = client.call("GET", f"/teams/{team_id}/channels/name/{name}")
    if status == 200 and isinstance(payload, dict):
        return payload
    return client.must("POST", "/channels", {
        "team_id": team_id,
        "name": name,
        "display_name": display,
        "type": "O",
        "purpose": "T35 composer surface: the suite sends, edits, deletes and drafts here.",
        "header": "T35 — native composer",
    })


def ensure_fixture_post(client: Client, channel_id: str) -> None:
    page = client.must("GET", f"/channels/{channel_id}/posts?per_page=60&collapsedThreads=true")
    for post in (page.get("posts") or {}).values():
        if post.get("message") == FIXTURE_MESSAGE and not post.get("delete_at"):
            return
    client.must("POST", "/posts", {"channel_id": channel_id, "message": FIXTURE_MESSAGE})


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    args = parser.parse_args()

    token, user_id = login(args.url)
    client = Client(args.url, token)
    team_id = ensure_team(client)
    channel = ensure_channel(client, team_id)
    ensure_fixture_post(client, channel["id"])

    second_team_id = ensure_team(client, SECOND_TEAM_NAME, SECOND_TEAM_DISPLAY)
    second_channel = ensure_channel(client, second_team_id, SECOND_CHANNEL_NAME,
                                    SECOND_CHANNEL_DISPLAY)
    print(json.dumps({
        "server": args.url,
        "username": USERNAME,
        "user_id": user_id,
        "team_id": team_id,
        "channel_id": channel["id"],
        "channel_name": channel["name"],
        "second_team_id": second_team_id,
        "second_channel_id": second_channel["id"],
        "second_channel_name": second_channel["name"],
    }, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
