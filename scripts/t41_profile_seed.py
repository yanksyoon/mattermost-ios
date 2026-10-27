#!/usr/bin/env python3
"""Seed the local throwaway Mattermost server for T41 (native profile / presence / custom status).

Why this exists: three of T41's acceptance criteria are statements about a **real** server's data and
need a fixture state a fresh server does not have:

  * ``t41-profile`` — a public channel the signed-in probe account is in, so the native channel pane
    renders a post list to tap an author avatar in;
  * ``t41buddy`` — a **second** human account, because "the profile popover shows *that* account" and
    "Send message opens your existing DM with them" are untestable against a one-account server (the
    probe account's own profile must not offer a message shortcut at all);
  * a post by ``t41buddy`` in ``t41-profile`` — the surface the avatar tap hangs off.

It also **clears** the probe account's custom status and puts its presence back to ``online``, so a run
starts from a known state instead of inheriting the previous run's leftovers.

Idempotent: re-running reuses accounts and the channel, re-establishes memberships, and re-posts only
when the buddy's post is missing. Nothing is deleted that another card's fixtures use.

Both passwords here are **fixture values for a throwaway local server**, exactly like
``scripts/t40_channel_seed.py``'s; they are not secrets and must never be reused anywhere real.

Usage:
    python3 scripts/t41_profile_seed.py --url http://127.0.0.1:8065
    python3 scripts/t41_profile_seed.py --url http://127.0.0.1:8065 --verify   # read the oracle back
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from typing import Any

ADMIN_LOGIN = "perfprobe"
ADMIN_PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
BUDDY_LOGIN = "t41buddy"
BUDDY_PASSWORD = "T41-Buddy-Not-A-Real-Secret-1"
BUDDY_EMAIL = "t41buddy@example.invalid"
BUDDY_FIRST = "Buddy"
BUDDY_LAST = "Profile"
TEAM_NAME = "perf"
CHANNEL_NAME = "t41-profile"
CHANNEL_DISPLAY = "T41 Profile"
CHANNEL_PURPOSE = "The channel the profile popover is opened from"
BUDDY_POST = "Hello from t41buddy — tap my avatar."

ADMIN_HEADERS: dict[str, str] = {}


class ApiError(RuntimeError):
    def __init__(self, method: str, path: str, status: int, body: str) -> None:
        super().__init__(f"{method} {path} -> HTTP {status} {body[:300]}")
        self.status = status


def call(url: str, method: str, path: str, body=None, token: str | None = None,
         allow_failure: bool = False) -> tuple[Any, dict[str, str]]:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url.rstrip("/") + "/api/v4" + path, data=data, method=method)
    request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = response.read()
            headers = dict(response.getheaders())
            return (json.loads(raw) if raw else None), headers
    except urllib.error.HTTPError as error:
        raw = error.read().decode("utf-8", "replace")
        if allow_failure:
            return None, {"status": str(error.code), "body": raw}
        raise ApiError(method, path, error.code, raw) from None


def login(url: str, user: str, password: str) -> tuple[str, str]:
    """Return (token, user id). The token arrives in the response's `Token` header, not the body."""
    body, headers = call(url, "POST", "/users/login", {"login_id": user, "password": password})
    token = headers.get("Token")
    if not token:
        raise SystemExit(f"no Token header in the login answer for {user}")
    return token, body["id"]


def ensure_buddy(url: str) -> str:
    found, _ = call(url, "GET", "/users/username/" + BUDDY_LOGIN, token=ADMIN_HEADERS["token"],
                    allow_failure=True)
    if found and found.get("id"):
        buddy_id = found["id"]
    else:
        created, _ = call(url, "POST", "/users", {
            "email": BUDDY_EMAIL,
            "username": BUDDY_LOGIN,
            "password": BUDDY_PASSWORD,
            "first_name": BUDDY_FIRST,
            "last_name": BUDDY_LAST,
        })
        buddy_id = created["id"]
        print(f"  created @{BUDDY_LOGIN}")
    # The display name the popover must show is the server's first+last, so keep it honest.
    call(url, "PUT", "/users/" + buddy_id + "/patch", {
        "first_name": BUDDY_FIRST, "last_name": BUDDY_LAST, "nickname": "",
    }, token=ADMIN_HEADERS["token"])
    return buddy_id


def ensure_team(url: str) -> str:
    teams, _ = call(url, "GET", "/users/me/teams", token=ADMIN_HEADERS["token"])
    for team in teams:
        if team.get("name") == TEAM_NAME:
            return team["id"]
    if not teams:
        raise SystemExit("the fixture account has no team")
    return teams[0]["id"]


def ensure_member(url: str, team_id: str, user_id: str) -> None:
    call(url, "POST", f"/teams/{team_id}/members", {"team_id": team_id, "user_id": user_id},
         token=ADMIN_HEADERS["token"], allow_failure=True)


def ensure_channel(url: str, team_id: str) -> str:
    channel, _ = call(url, "GET", f"/teams/{team_id}/channels/name/{CHANNEL_NAME}",
                      token=ADMIN_HEADERS["token"], allow_failure=True)
    if channel and channel.get("id"):
        channel_id = channel["id"]
        if channel.get("delete_at"):
            call(url, "POST", f"/channels/{channel_id}/restore", token=ADMIN_HEADERS["token"])
            print(f"  restored #{CHANNEL_NAME}")
        call(url, "PUT", f"/channels/{channel_id}/patch", {
            "display_name": CHANNEL_DISPLAY, "purpose": CHANNEL_PURPOSE,
        }, token=ADMIN_HEADERS["token"])
        return channel_id
    created, _ = call(url, "POST", "/channels", {
        "team_id": team_id,
        "name": CHANNEL_NAME,
        "display_name": CHANNEL_DISPLAY,
        "purpose": CHANNEL_PURPOSE,
        "type": "O",
    }, token=ADMIN_HEADERS["token"])
    print(f"  created #{CHANNEL_NAME}")
    return created["id"]


def ensure_post(url: str, channel_id: str, buddy_id: str) -> None:
    buddy_token, _ = login(url, BUDDY_LOGIN, BUDDY_PASSWORD)
    posts, _ = call(url, "GET", f"/channels/{channel_id}/posts?per_page=60", token=buddy_token)
    for post in (posts or {}).get("posts", {}).values():
        if post.get("user_id") == buddy_id and BUDDY_POST in post.get("message", ""):
            return
    call(url, "POST", "/posts", {"channel_id": channel_id, "message": BUDDY_POST},
         token=buddy_token)
    print("  posted the buddy's message")


def reset_probe_state(url: str, admin_id: str) -> None:
    """A run starts from online + no custom status, not from the previous run's leftovers."""
    call(url, "DELETE", f"/users/{admin_id}/status/custom", token=ADMIN_HEADERS["token"],
         allow_failure=True)
    call(url, "PUT", f"/users/{admin_id}/status", {"user_id": admin_id, "status": "online"},
         token=ADMIN_HEADERS["token"], allow_failure=True)


def verify(url: str, admin_id: str, buddy_id: str, channel_id: str) -> None:
    """Read the oracle back through the same endpoints the live test uses."""
    for label, path in [
        ("my profile", f"/users/{admin_id}"),
        ("buddy profile", f"/users/{buddy_id}"),
        ("my status", f"/users/{admin_id}/status"),
        ("buddy status", f"/users/{buddy_id}/status"),
    ]:
        body, _ = call(url, "GET", path, token=ADMIN_HEADERS["token"])
        if label == "my profile":
            print(f"  {label}: props={body.get('props')!r}")
        else:
            print(f"  {label}: {json.dumps(body)[:200]}")
    stats, _ = call(url, "GET", f"/channels/{channel_id}/stats", token=ADMIN_HEADERS["token"])
    print(f"  channel stats: {json.dumps(stats)[:200]}")
    posts, _ = call(url, "GET", f"/channels/{channel_id}/posts?per_page=5",
                    token=ADMIN_HEADERS["token"])
    print(f"  posts in channel: {posts.get('order') if posts else None}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--verify", action="store_true", help="read the oracle back after seeding")
    args = parser.parse_args()

    print(f"seeding {args.url}")
    token, admin_id = login(args.url, ADMIN_LOGIN, ADMIN_PASSWORD)
    ADMIN_HEADERS["token"] = token
    print(f"  signed in as @{ADMIN_LOGIN} ({admin_id})")

    team_id = ensure_team(args.url)
    buddy_id = ensure_buddy(args.url)
    ensure_member(args.url, team_id, buddy_id)
    channel_id = ensure_channel(args.url, team_id)
    for member in (admin_id, buddy_id):
        call(args.url, "POST", f"/channels/{channel_id}/members",
             {"user_id": member}, token=ADMIN_HEADERS["token"], allow_failure=True)
    ensure_post(args.url, channel_id, buddy_id)
    reset_probe_state(args.url, admin_id)

    print(f"  team={team_id} channel={channel_id} buddy={buddy_id}")
    if args.verify:
        verify(args.url, admin_id, buddy_id, channel_id)
    print("seeded")
    return 0


if __name__ == "__main__":
    sys.exit(main())
