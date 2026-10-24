#!/usr/bin/env python3
"""Seed the local throwaway Mattermost server for T33 (native channel sidebar).

Why this exists: T33's live UI tests (`MattermostUITests/T33ChannelSidebarUITests.swift`) need a
server on which

  * the `perf` team — the team the shell opens on — has a **second user who can post into it**, so
    unread/mention state can be produced through the real socket path rather than by writing rows;
  * the probe account has every channel of that team **read**, so "this row is not bold" is a fact
    rather than a leftover from the previous run;
  * no channel is left muted, so the mute test can mute exactly one channel itself;
  * the sidebar categories endpoint answers with the server's own `channels`/`direct_messages`
    categories (that is what the client groups by).

`scripts/t32_team_seed.py` grows `ops` (the team the *rail* switches to) and `scripts/perf_seed.py`
owns the single-team perf fixture; neither adds the bot to `perf`. This one is additive and
idempotent, and it only touches this machine's throwaway server, whose probe credentials are already
committed in `scripts/perf_seed.py` / `scripts/t32_team_seed.py`.

What it guarantees (re-running is a no-op):

    team      perf         perfprobe = system admin, opsbot = member
    channels  town-square, off-topic, perf-feed   opsbot is a member of every one
    reads     perfprobe has viewed every channel of `perf` (no unread, no mentions)
    mute      every channel of `perf` is unmuted for perfprobe (`mark_unread: all`)
    prefs     a `channel_order`-free baseline: the server's category list is left untouched

It then prints the authoritative per-channel numbers and the server's category list, so a UI test
can compare what it sees on screen with what the server returns *without* trusting this script.

Usage:
    python3 scripts/t33_channel_seed.py --url http://127.0.0.1:8065
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request

USERNAME = "perfprobe"
PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
BOT_USERNAME = "opsbot"
BOT_PASSWORD = "OpsBot-Not-A-Real-Secret-1"
TEAM_NAME = "perf"


class APIError(RuntimeError):
    pass


class Client:
    def __init__(self, base: str, token: str | None = None):
        self.base = base.rstrip("/")
        self.token = token

    def call(self, method: str, path: str, body: dict | list | None = None
             ) -> tuple[int, dict | list | None, dict[str, str]]:
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(f"{self.base}/api/v4{path}", data=data, method=method)
        req.add_header("Content-Type", "application/json")
        req.add_header("X-Requested-With", "XMLHttpRequest")
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
                return (resp.status, (json.loads(raw) if raw.strip() else None),
                        {k.lower(): v for k, v in resp.headers.items()})
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            try:
                payload = json.loads(raw)
            except Exception:
                payload = {"raw": raw.decode(errors="replace")}
            return exc.code, payload, {k.lower(): v for k, v in exc.headers.items()}

    def must(self, method: str, path: str, body: dict | list | None = None):
        status, payload, _ = self.call(method, path, body)
        if status >= 300:
            raise APIError(f"{method} {path} -> {status}: {payload}")
        return payload


def login(base: str, login_id: str, password: str) -> Client:
    status, payload, headers = Client(base).call("POST", "/users/login",
                                                 {"login_id": login_id, "password": password})
    if status != 200 or not headers.get("token"):
        raise APIError(f"login as {login_id} failed: {status} {payload}")
    return Client(base, headers["token"])


def ensure_team_member(admin: Client, team_id: str, user_id: str) -> None:
    status, _, _ = admin.call("POST", f"/teams/{team_id}/members",
                              {"team_id": team_id, "user_id": user_id})
    if status >= 300 and status != 400:   # 400 = already a member (the idempotent path)
        raise APIError(f"add {user_id} to team {team_id} -> {status}")


def ensure_channel_member(admin: Client, channel_id: str, user_id: str) -> None:
    status, _, _ = admin.call("POST", f"/channels/{channel_id}/members", {"user_id": user_id})
    if status >= 300 and status != 400:
        raise APIError(f"add {user_id} to channel {channel_id} -> {status}")


def mark_read(c: Client, user_id: str, channel_id: str) -> None:
    c.must("POST", f"/channels/members/{user_id}/view", {"channel_id": channel_id})


def unmute(c: Client, channel_id: str, user_id: str) -> None:
    c.must("PUT", f"/channels/{channel_id}/members/{user_id}/notify_props",
           {"mark_unread": "all"})


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--url", default="http://127.0.0.1:8065")
    args = ap.parse_args()

    probe = login(args.url, USERNAME, PASSWORD)
    bot = login(args.url, BOT_USERNAME, BOT_PASSWORD)
    me = probe.must("GET", "/users/me")
    me_id = me["id"]
    bot_me = bot.must("GET", "/users/me")

    status, team, _ = probe.call("GET", f"/teams/name/{TEAM_NAME}")
    if status != 200:
        print(f"the {TEAM_NAME} team does not exist on {args.url}; run scripts/perf_seed.py first",
              file=sys.stderr)
        return 1
    team_id = team["id"]

    ensure_team_member(probe, team_id, bot_me["id"])
    channels = probe.must("GET", f"/users/me/teams/{team_id}/channels") or []
    for channel in channels:
        if channel.get("type") != "O":
            continue        # a DM/private channel needs an explicit invite; the fixture is public
        ensure_channel_member(probe, channel["id"], bot_me["id"])

    for channel in channels:
        unmute(probe, channel["id"], me_id)
        mark_read(probe, me_id, channel["id"])

    # The numbers the UI test is allowed to compare against.
    print(f"team {TEAM_NAME} {team_id}")
    members = {row["channel_id"]: row
               for row in (probe.must("GET", "/users/me/channel_members") or [])}
    for channel in sorted(channels, key=lambda c: c["name"]):
        row = members.get(channel["id"], {})
        unread = max(int(channel.get("total_msg_count") or 0) - int(row.get("msg_count") or 0), 0)
        print(f"  channel {channel['name']:<12} id={channel['id']} "
              f"type={channel['type']} total={channel.get('total_msg_count')} "
              f"msg_count={row.get('msg_count')} mentions={row.get('mention_count')} "
              f"mark_unread={row.get('notify_props', {}).get('mark_unread')} unread={unread}")

    categories = probe.must("GET", f"/users/{me_id}/teams/{team_id}/channels/categories") or {}
    print(f"  categories order={categories.get('order')}")
    for category in categories.get("categories") or []:
        print(f"    {category['type']:<16} id={category['id']} sorting={category.get('sorting')} "
              f"channels={len(category.get('channel_ids') or [])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
