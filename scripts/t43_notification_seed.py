#!/usr/bin/env python3
"""Put the T43 fixture in the state the probe and the live UI test need, and print the ids.

What it guarantees, idempotently:

  * the fixture accounts exist — `perfprobe` (the admin the app signs in as) and `t43buddy` (a second
    account: the only way to produce a mention *of me* from another client, which is exactly what the
    socket `posted` event has to be exercised with);
  * a public channel `t43-notify` in the admin's own team, with both accounts as members — the channel
    the live test's mention arrives in;
  * a second public channel `t43-muted`, **muted for the admin** (`notify_props.mark_unread =
    "mention"`, the same rule T33's sidebar uses to draw "muted"), so the probe can measure that a
    mention there still moves the server's own `mention_count`;
  * NO mention is posted by the seed. The mention the test observes is posted *while the app is running*
    (that is the whole point of a socket test), so seeding one would make the passing run ambiguous.

Passwords are throwaway local values, identical to `scripts/t43_notification_probe.py`'s. No credential
is printed and the token only ever reaches a request header.

    python3 scripts/t43_notification_seed.py --url http://127.0.0.1:8065
    python3 scripts/t43_notification_seed.py --url http://127.0.0.1:8065 --json   # machine-readable
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
BUDDY_LOGIN = "t43buddy"
BUDDY_PASSWORD = "T43-Buddy-Not-A-Real-Secret-1"
BUDDY_EMAIL = "t43buddy@example.invalid"
BUDDY_FIRST = "Terry"
BUDDY_LAST = "Buddy"
CHANNEL_NAME = "t43-notify"
CHANNEL_DISPLAY = "T43 notify"
MUTED_NAME = "t43-muted"
MUTED_DISPLAY = "T43 muted"
TEAM_NAME = "t42-activity-team"
TEAM_DISPLAY = "T42 activity team"


def call(url: str, method: str, path: str, body: Any = None,
         token: str | None = None) -> tuple[int, Any, dict[str, str]]:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url.rstrip("/") + "/api/v4" + path, data=data, method=method)
    request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = response.read()
            return response.status, _parse(raw), {k.lower(): v for k, v in response.getheaders()}
    except urllib.error.HTTPError as error:
        headers = {k.lower(): v for k, v in error.headers.items()} if error.headers else {}
        return error.code, _parse(error.read()), headers


def _parse(payload: bytes) -> Any:
    if not payload:
        return None
    try:
        return json.loads(payload)
    except json.JSONDecodeError:
        return payload.decode("utf-8", "replace")[:400]


def login(url: str, user: str, password: str) -> tuple[str, dict[str, Any]]:
    status, body, headers = call(url, "POST", "/users/login",
                                 {"login_id": user, "password": password})
    if status != 200 or not headers.get("token"):
        raise SystemExit(f"could not sign in as {user} (HTTP {status}, {str(body)[:200]})")
    return headers["token"], body


def ensure_buddy(url: str, admin_token: str) -> dict[str, Any]:
    status, user, _ = call(url, "GET", "/users/username/" + BUDDY_LOGIN, token=admin_token)
    if status == 200 and isinstance(user, dict) and user.get("id"):
        if user.get("first_name") != BUDDY_FIRST or user.get("last_name") != BUDDY_LAST:
            call(url, "PUT", "/users/" + user["id"] + "/patch",
                 {"first_name": BUDDY_FIRST, "last_name": BUDDY_LAST}, token=admin_token)
        return user
    status, created, _ = call(url, "POST", "/users", {
        "email": BUDDY_EMAIL, "username": BUDDY_LOGIN, "password": BUDDY_PASSWORD,
        "first_name": BUDDY_FIRST, "last_name": BUDDY_LAST,
    }, token=admin_token)
    if status != 201 or not isinstance(created, dict) or not created.get("id"):
        raise SystemExit(f"could not create @{BUDDY_LOGIN} (HTTP {status}, {str(created)[:200]})")
    return created


def ensure_team(url: str, admin_token: str) -> dict[str, Any]:
    status, teams, _ = call(url, "GET", "/users/me/teams", token=admin_token)
    if status != 200 or not isinstance(teams, list) or not teams:
        raise SystemExit(f"could not list my teams (HTTP {status})")
    for team in teams:
        if team.get("name") == TEAM_NAME:
            return team
    return teams[0]


def ensure_channel(url: str, admin_token: str, team_id: str,
                   name: str, display: str) -> dict[str, Any]:
    status, channel, _ = call(url, "GET", f"/teams/{team_id}/channels/name/{name}",
                              token=admin_token)
    if status == 200 and isinstance(channel, dict) and channel.get("id"):
        return channel
    status, created, _ = call(url, "POST", "/channels", {
        "team_id": team_id, "name": name, "display_name": display, "type": "O",
    }, token=admin_token)
    if status != 201 or not isinstance(created, dict) or not created.get("id"):
        raise SystemExit(f"could not create #{name} (HTTP {status}, {str(created)[:200]})")
    return created


def ensure_membership(url: str, admin_token: str, team_id: str, channel_id: str,
                      user_id: str) -> None:
    status, _, _ = call(url, "POST", f"/teams/{team_id}/members",
                        {"team_id": team_id, "user_id": user_id}, token=admin_token)
    if status not in (200, 201, 400):  # 400 = already a member on some versions
        raise SystemExit(f"could not add {user_id} to the team (HTTP {status})")
    status, _, _ = call(url, "POST", f"/channels/{channel_id}/members",
                        {"user_id": user_id}, token=admin_token)
    if status not in (200, 201, 400):
        raise SystemExit(f"could not add {user_id} to {channel_id} (HTTP {status})")


def mute_for_me(url: str, admin_token: str, admin_id: str, channel_id: str) -> None:
    """`mark_unread = "mention"` is the server's own "muted" (T33 reads the same prop)."""
    status, _, _ = call(url, "PUT", f"/channels/{channel_id}/members/{admin_id}/notify_props",
                        {"mark_unread": "mention"}, token=admin_token)
    if status not in (200, 201):
        raise SystemExit(f"could not mute {channel_id} (HTTP {status})")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--json", action="store_true", help="print only the fixture ids as JSON")
    args = parser.parse_args()

    admin_token, admin = login(args.url, ADMIN_LOGIN, ADMIN_PASSWORD)
    buddy = ensure_buddy(args.url, admin_token)
    team = ensure_team(args.url, admin_token)
    channel = ensure_channel(args.url, admin_token, team["id"], CHANNEL_NAME, CHANNEL_DISPLAY)
    muted = ensure_channel(args.url, admin_token, team["id"], MUTED_NAME, MUTED_DISPLAY)
    for target in (channel, muted):
        ensure_membership(args.url, admin_token, team["id"], target["id"], buddy["id"])
        ensure_membership(args.url, admin_token, team["id"], target["id"], admin["id"])
    mute_for_me(args.url, admin_token, admin["id"], muted["id"])

    fixture = {
        "url": args.url,
        "admin_id": admin["id"],
        "admin_username": admin["username"],
        "buddy_id": buddy["id"],
        "buddy_username": BUDDY_LOGIN,
        "team_id": team["id"],
        "channel_id": channel["id"],
        "channel_name": CHANNEL_NAME,
        "channel_display_name": channel.get("display_name", CHANNEL_DISPLAY),
        "muted_channel_id": muted["id"],
        "muted_channel_name": MUTED_NAME,
    }
    if args.json:
        print(json.dumps(fixture, indent=2))
    else:
        print(f"# T43 fixture ready on {args.url}")
        print(f"  admin    @{admin['username']} ({admin['id']})")
        print(f"  buddy    @{BUDDY_LOGIN} ({buddy['id']})")
        print(f"  team     {team.get('name')} ({team['id']})")
        print(f"  channel  #{CHANNEL_NAME} ({channel['id']}) — left without a new mention on purpose")
        print(f"  muted    #{MUTED_NAME} ({muted['id']}) — mark_unread=mention for the admin")
    return 0


if __name__ == "__main__":
    sys.exit(main())
