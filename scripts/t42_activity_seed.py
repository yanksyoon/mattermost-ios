#!/usr/bin/env python3
"""Put the T42 fixture in the state the probe and the live UI test need, and print the ids.

What it guarantees, idempotently:

  * the fixture accounts exist — `perfprobe` (the admin the app signs in as) and `t42buddy`
    (a second account, the only way to produce a mention *of me* from another client);
  * a public channel `t42-activity` in the admin's own team, with both accounts as members;
  * **fresh** mention posts by the buddy, so a run always starts with unread mentions even though the
    previous run marked the channel read:
      - three root posts that name the admin (`@perfprobe`),
      - one thread reply that names the admin inside a thread (the row whose read state can only come
        from the thread endpoint),
      - one post that names nobody (the control the probe asserts is *not* in the window);
  * the channel is left **unread** for the admin (the seed never marks it read), which is what makes
    `mention_count > 0` on the admin's member row the oracle for "there are unread mentions".

Passwords are throwaway local values, identical to `scripts/t42_activity_probe.py`'s. No credential is
printed and the token only ever reaches a request header.

    python3 scripts/t42_activity_seed.py --url http://127.0.0.1:8065
    python3 scripts/t42_activity_seed.py --url http://127.0.0.1:8065 --json   # machine-readable
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from typing import Any

ADMIN_LOGIN = "perfprobe"
ADMIN_PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
BUDDY_LOGIN = "t42buddy"
BUDDY_PASSWORD = "T42-Buddy-Not-A-Real-Secret-1"
BUDDY_EMAIL = "t42buddy@example.invalid"
BUDDY_FIRST = "Terry"
BUDDY_LAST = "Buddy"
CHANNEL_NAME = "t42-activity"
CHANNEL_DISPLAY = "T42 activity"
TEAM_NAME = "t42-activity-team"
TEAM_DISPLAY = "T42 activity team"


def call(url: str, method: str, path: str, body: Any = None, token: str | None = None,
         raw: bytes | None = None) -> tuple[int, Any, dict[str, str]]:
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    request = urllib.request.Request(url.rstrip("/") + "/api/v4" + path, data=data, method=method)
    request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = response.read()
            return response.status, _parse(payload), {k.lower(): v for k, v in response.getheaders()}
    except urllib.error.HTTPError as error:
        payload = error.read()
        headers = {k.lower(): v for k, v in error.headers.items()} if error.headers else {}
        return error.code, _parse(payload), headers


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
        # Keep the display name the tests quote in their assertions.
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
    if status != 200 or not isinstance(teams, list):
        raise SystemExit(f"could not list my teams (HTTP {status})")
    for team in teams:
        if team.get("name") == TEAM_NAME:
            return team
    if teams:
        return teams[0]
    status, created, _ = call(url, "POST", "/teams", {
        "name": TEAM_NAME, "display_name": TEAM_DISPLAY, "type": "O",
    }, token=admin_token)
    if status != 201 or not isinstance(created, dict) or not created.get("id"):
        raise SystemExit(f"could not create a team (HTTP {status}, {str(created)[:200]})")
    return created


def ensure_channel(url: str, admin_token: str, team_id: str) -> dict[str, Any]:
    status, channel, _ = call(url, "GET", f"/teams/{team_id}/channels/name/{CHANNEL_NAME}",
                              token=admin_token)
    if status == 200 and isinstance(channel, dict) and channel.get("id"):
        return channel
    status, created, _ = call(url, "POST", "/channels", {
        "team_id": team_id, "name": CHANNEL_NAME, "display_name": CHANNEL_DISPLAY, "type": "O",
    }, token=admin_token)
    if status != 201 or not isinstance(created, dict) or not created.get("id"):
        raise SystemExit(f"could not create #{CHANNEL_NAME} (HTTP {status}, {str(created)[:200]})")
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
        raise SystemExit(f"could not add {user_id} to #{CHANNEL_NAME} (HTTP {status})")


def post(url: str, token: str, channel_id: str, message: str,
         root_id: str = "") -> dict[str, Any]:
    body: dict[str, Any] = {"channel_id": channel_id, "message": message}
    if root_id:
        body["root_id"] = root_id
    status, created, _ = call(url, "POST", "/posts", body, token=token)
    if status != 201 or not isinstance(created, dict) or not created.get("id"):
        raise SystemExit(f"could not post to #{CHANNEL_NAME} (HTTP {status}, {str(created)[:200]})")
    return created


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--json", action="store_true", help="print only the fixture ids as JSON")
    args = parser.parse_args()

    admin_token, admin = login(args.url, ADMIN_LOGIN, ADMIN_PASSWORD)
    buddy = ensure_buddy(args.url, admin_token)
    team = ensure_team(args.url, admin_token)
    channel = ensure_channel(args.url, admin_token, team["id"])
    ensure_membership(args.url, admin_token, team["id"], channel["id"], buddy["id"])
    ensure_membership(args.url, admin_token, team["id"], channel["id"], admin["id"])

    buddy_token, _ = login(args.url, BUDDY_LOGIN, BUDDY_PASSWORD)
    stamp = int(time.time() * 1000)
    admin_handle = "@" + admin["username"]

    # A thread root by the buddy, then a reply that names the admin: the reply's read state lives on the
    # thread endpoint, not the channel cursor (measured by the probe).
    root = post(args.url, buddy_token, channel["id"], f"T42 seed {stamp}: thread root")
    reply = post(args.url, buddy_token, channel["id"],
                 f"T42 seed {stamp}: {admin_handle} this reply names you", root_id=root["id"])

    roots = [post(args.url, buddy_token, channel["id"],
                  f"T42 seed {stamp}: {admin_handle} mention {n}") for n in (1, 2, 3)]
    control = post(args.url, buddy_token, channel["id"],
                   f"T42 seed {stamp}: nobody is named here")

    fixture = {
        "url": args.url,
        "admin_id": admin["id"],
        "admin_username": admin["username"],
        "buddy_id": buddy["id"],
        "buddy_username": BUDDY_LOGIN,
        "team_id": team["id"],
        "channel_id": channel["id"],
        "channel_name": CHANNEL_NAME,
        "stamp": stamp,
        "mention_post_ids": [reply["id"]] + [p["id"] for p in roots],
        "root_id": root["id"],
        "control_post_id": control["id"],
    }
    if args.json:
        print(json.dumps(fixture, indent=2))
    else:
        print(f"# T42 fixture ready on {args.url}")
        print(f"  admin    @{admin['username']} ({admin['id']})")
        print(f"  buddy    @{BUDDY_LOGIN} ({buddy['id']})")
        print(f"  team     {team.get('name')} ({team['id']})")
        print(f"  channel  #{CHANNEL_NAME} ({channel['id']})")
        print(f"  mentions {', '.join(fixture['mention_post_ids'])}")
        print(f"  control  {control['id']} (names nobody)")
        print("  the channel is left unread for the admin on purpose")
    return 0


if __name__ == "__main__":
    sys.exit(main())
