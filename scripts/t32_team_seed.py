#!/usr/bin/env python3
"""Seed the local throwaway Mattermost server with a *second* team for T32.

Why this exists: T32 (native team sidebar) has to be evidenced against a real server
that returns **more than one team** plus per-team unread mention counts. `scripts/perf_seed.py`
creates exactly one team (`perf`) because that is what the T27 memory probe needs; growing that
script would change the perf fixture. This one is additive and idempotent, and it only touches this
machine's throwaway server (`http://127.0.0.1:8065`), whose probe account and password are already
committed in `scripts/perf_seed.py`.

What it guarantees (re-running is a no-op):

    team      ops          display "Operations"  (perfprobe = team admin, opsbot = member)
    channel   ops-standup  in `ops`, with N posts that @-mention perfprobe, written by opsbot
                           so the server really reports unread mentions for the `ops` team
    icon      a generated 64x64 PNG uploaded through POST /teams/{id}/image, so the rail's real
              icon path (not the initials fallback) is exercised
    pref      teams_order = [perf, ops], so the rail is asked to show `perf` first instead of the
              alphabetical fallback — the ordering rule the mobile client implements

It then prints the authoritative per-team unread numbers, so a UI test can compare what it sees on
screen with what the server returns *without* trusting this script's arithmetic.

Usage:
    python3 scripts/t32_team_seed.py --url http://127.0.0.1:8065 --mentions 2
"""

from __future__ import annotations

import argparse
import json
import struct
import urllib.error
import urllib.request
import uuid
import zlib

USERNAME = "perfprobe"
PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
BOT_USERNAME = "opsbot"
BOT_EMAIL = "opsbot@example.invalid"
BOT_PASSWORD = "OpsBot-Not-A-Real-Secret-1"
TEAM_NAME = "ops"
TEAM_DISPLAY = "Operations"
CHANNEL_NAME = "ops-standup"
CHANNEL_DISPLAY = "Ops Standup"
PERF_TEAM_NAME = "perf"


class APIError(RuntimeError):
    pass


class Client:
    def __init__(self, base: str, token: str | None = None):
        self.base = base.rstrip("/")
        self.token = token

    def _request(self, method: str, path: str, data: bytes | None,
                 content_type: str) -> tuple[int, dict | list | None, dict[str, str]]:
        url = f"{self.base}/api/v4{path}"
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Content-Type", content_type)
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

    def call(self, method: str, path: str, body: dict | list | None = None
             ) -> tuple[int, dict | list | None, dict[str, str]]:
        data = json.dumps(body).encode() if body is not None else None
        return self._request(method, path, data, "application/json")

    def upload(self, path: str, field: str, filename: str, content: bytes, mime: str
               ) -> tuple[int, dict | list | None, dict[str, str]]:
        boundary = "----t32" + uuid.uuid4().hex
        parts = [
            f"--{boundary}\r\n".encode(),
            f'Content-Disposition: form-data; name="{field}"; filename="{filename}"\r\n'.encode(),
            f"Content-Type: {mime}\r\n\r\n".encode(),
            content,
            f"\r\n--{boundary}--\r\n".encode(),
        ]
        return self._request("POST", path, b"".join(parts),
                             f"multipart/form-data; boundary={boundary}")

    def must(self, method: str, path: str, body: dict | list | None = None):
        status, payload, _ = self.call(method, path, body)
        if status >= 300:
            raise APIError(f"{method} {path} -> {status}: {payload}")
        return payload


def login(base: str, login_id: str, password: str) -> Client:
    anon = Client(base)
    status, payload, headers = anon.call("POST", "/users/login",
                                         {"login_id": login_id, "password": password})
    if status != 200 or not headers.get("token"):
        raise APIError(f"login as {login_id} failed: {status} {payload}")
    return Client(base, headers["token"])


def ensure_user(base: str, admin: Client, username: str, email: str, password: str) -> str:
    status, payload, _ = admin.call("GET", f"/users/username/{username}")
    if status == 200 and isinstance(payload, dict):
        return payload["id"]
    user = admin.must("POST", "/users", {
        "username": username,
        "email": email,
        "password": password,
    })
    return user["id"]


def ensure_team(c: Client, name: str, display: str) -> str:
    status, payload, _ = c.call("GET", f"/teams/name/{name}")
    if status == 200 and isinstance(payload, dict):
        return payload["id"]
    team = c.must("POST", "/teams", {"name": name, "display_name": display, "type": "O"})
    return team["id"]


def ensure_member(admin: Client, team_id: str, user_id: str) -> None:
    status, _, _ = admin.call("POST", f"/teams/{team_id}/members", {"team_id": team_id,
                                                                   "user_id": user_id})
    # 400 "already a member" is the idempotent path.
    if status >= 300 and status != 400:
        raise APIError(f"add {user_id} to {team_id} -> {status}")


def ensure_channel(c: Client, team_id: str) -> str:
    status, payload, _ = c.call("GET", f"/teams/{team_id}/channels/name/{CHANNEL_NAME}")
    if status == 200 and isinstance(payload, dict):
        return payload["id"]
    channel = c.must("POST", "/channels", {
        "team_id": team_id,
        "name": CHANNEL_NAME,
        "display_name": CHANNEL_DISPLAY,
        "type": "O",
    })
    return channel["id"]


def ensure_channel_member(bot: Client, channel_id: str, user_id: str) -> None:
    """A mention only counts for a user who is a member of the channel (msg/mention_count are
    per-membership), so adding the team membership alone leaves the badge at zero."""
    status, _, _ = bot.call("POST", f"/channels/{channel_id}/members",
                            {"user_id": user_id})
    if status >= 300 and status != 400:
        raise APIError(f"add {user_id} to channel {channel_id} -> {status}")


def ensure_posts(bot: Client, channel_id: str, wanted: int) -> None:
    status, payload, _ = bot.call("GET", f"/channels/{channel_id}/posts?per_page=60")
    existing = 0
    if status == 200 and isinstance(payload, dict):
        existing = len(payload.get("order") or [])
    for i in range(existing, wanted):
        bot.must("POST", "/posts", {
            "channel_id": channel_id,
            "message": f"@{USERNAME} deploy check #{i + 1}: can you take a look?",
        })


def solid_png(size: int, rgb: tuple[int, int, int]) -> bytes:
    """A valid PNG without any imaging dependency (no PIL on this host)."""
    raw = b"".join(b"\x00" + bytes(rgb) * size for _ in range(size))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def ensure_icon(admin: Client, team_id: str) -> bool:
    status, team, _ = admin.call("GET", f"/teams/{team_id}")
    if status == 200 and isinstance(team, dict) and team.get("last_team_icon_update"):
        return False
    png = solid_png(64, (34, 102, 204))
    status, payload, _ = admin.upload(f"/teams/{team_id}/image", "image", "icon.png", png,
                                      "image/png")
    if status >= 300:
        raise APIError(f"team icon upload -> {status}: {payload}")
    return True


def ensure_teams_order(c: Client, user_id: str, ordered_ids: list[str]) -> None:
    # The API saves preferences with `PUT /users/{user_id}/preferences` (a POST is a 404), and it
    # wants the user id, not "me".
    c.must("PUT", f"/users/{user_id}/preferences", [{
        "user_id": user_id,
        "category": "teams_order",
        "name": "teams_order",
        "value": ",".join(ordered_ids),
    }])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--mentions", type=int, default=2,
                        help="posts in ops-standup that @-mention perfprobe")
    args = parser.parse_args()

    admin = login(args.url, USERNAME, PASSWORD)
    me = admin.must("GET", "/users/me")
    user_id = me["id"]

    bot_id = ensure_user(args.url, admin, BOT_USERNAME, BOT_EMAIL, BOT_PASSWORD)
    bot = login(args.url, BOT_USERNAME, BOT_PASSWORD)

    ops_id = ensure_team(admin, TEAM_NAME, TEAM_DISPLAY)
    ensure_member(admin, ops_id, user_id)
    ensure_member(admin, ops_id, bot_id)
    channel_id = ensure_channel(bot, ops_id)
    ensure_channel_member(bot, channel_id, user_id)
    ensure_posts(bot, channel_id, args.mentions)
    icon_uploaded = ensure_icon(admin, ops_id)

    status, teams, _ = admin.call("GET", "/users/me/teams")
    perf_id = next(t["id"] for t in teams if t["name"] == PERF_TEAM_NAME)
    ensure_teams_order(admin, user_id, [perf_id, ops_id])

    status, unread, _ = admin.call("GET", "/users/me/teams/unread")
    print(json.dumps({
        "user": USERNAME,
        "user_id": user_id,
        "teams": [{"id": t["id"], "name": t["name"], "display_name": t["display_name"],
                   "last_team_icon_update": t.get("last_team_icon_update")}
                  for t in sorted(teams, key=lambda t: t["name"])],
        "teams_order": [perf_id, ops_id],
        "icon_uploaded": icon_uploaded,
        "unread": unread,
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
