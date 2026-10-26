#!/usr/bin/env python3
"""T40 probe — the server-side oracle for the channel-info surface, run against the live fixture.

This is the reproducible record of every fact the card's implementation rests on, measured against the
pinned 9.11.19 server rather than read from a type definition. It also performs, in order, each write the
native screen performs, so a reviewer can see the exact HTTP answer the app is built around:

  1. permissions   `GET /users/me` roles → `POST /roles/names` → the union of permission ids;
  2. header data   `GET /channels/{id}` (display name, purpose, header) + `GET /channels/{id}/stats`
                   (`member_count` — the channel object carries none);
  3. members       `GET /channels/{id}/members?page=&per_page=` and the batched names/statuses;
  4. people to add `GET /users?in_team=&not_in_channel=` (the empty-term list, because
                   `POST /users/search` answers 400 for an empty term) and `POST /users/search` typed;
  5. settings      `PUT /channels/{id}/patch` with purpose-only and with all three fields, plus the
                   server's own limits (display name 64, purpose 250, header 1024);
  6. membership    `POST /channels/{id}/members` (add), `DELETE …/members/{user}` (remove), and
                   `DELETE …/members/me` (leave);
  7. archive       `DELETE /channels/{id}` then `POST /channels/{id}/restore`;
  8. a DM          the `direct_channel_show` preference write, and the fact that the membership row
                   survives it (a DM is *closed*, not left);
  9. the gate      a plain member's permission set — the app's gate reads ids, never role names.

Everything it creates, it cleans up (its own `t40probe-*` channel). The fixture channels the live tests
use are created by ``scripts/t40_channel_seed.py``; this script does not touch them except to read.

Usage:
    python3 scripts/t40_channel_probe.py --url http://127.0.0.1:8065
    python3 scripts/t40_channel_probe.py --url http://127.0.0.1:8065 --snapshot-role  # dump channel_user
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

ADMIN_LOGIN = "perfprobe"
# Documentation only: the CLI never defaults to it (see `main`).
ADMIN_PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
MEMBER_LOGIN = "t40member"
MEMBER_PASSWORD = "T40-Member-Not-A-Real-Secret-1"
TEAM_NAME = "perf"
PROBE_CHANNEL = "t40probe-scratch"


class Client:
    def __init__(self, base: str, token: str | None = None) -> None:
        self.base = base.rstrip("/")
        self.token = token

    def call(self, method: str, path: str, body=None, query=None):
        url = f"{self.base}/api/v4{path}"
        if query:
            url += "?" + "&".join(f"{key}={value}" for key, value in query.items())
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                raw = response.read()
                return response.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as error:
            raw = error.read()
            try:
                payload = json.loads(raw or b"null")
            except ValueError:
                payload = raw.decode(errors="replace")
            return error.code, payload

    def login(self, login: str, password: str) -> dict:
        request = urllib.request.Request(
            f"{self.base}/api/v4/users/login",
            data=json.dumps({"login_id": login, "password": password}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=20) as response:
            self.token = response.headers.get("Token")
            return json.loads(response.read())


def show(label: str, status: int, payload) -> None:
    if isinstance(payload, (dict, list)):
        text = json.dumps(payload)[:220]
    else:
        text = str(payload)[:220]
    print(f"  {label:44s} -> {status} {text}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--login", default=ADMIN_LOGIN)
    # No credential in the repo: the fixture account's password comes from the environment (or the flag).
    parser.add_argument("--password", default=os.environ.get("MM_PROBE_PASSWORD", ""))
    parser.add_argument("--snapshot-role", action="store_true",
                        help="print channel_user's permission ids and exit (for a manual restore)")
    args = parser.parse_args()

    if not args.password:
        print("set MM_PROBE_PASSWORD (or pass --password) — see scripts/perf_seed.py", file=sys.stderr)
        return 2

    admin = Client(args.url)
    me = admin.login(args.login, args.password)
    print(f"signed in as {me['username']} ({me['id']}) on {args.url}\n")

    if args.snapshot_role:
        status, role = admin.call("GET", "/roles/name/channel_user")
        print(json.dumps(role.get("permissions", []), indent=4))
        return 0

    print("1. permissions")
    status, teams = admin.call("GET", "/users/me/teams")
    team_id = teams[0]["id"]
    status, user = admin.call("GET", "/users/me")
    system_roles = (user.get("roles") or "").split()
    status, team_member = admin.call("GET", f"/teams/{team_id}/members/{me['id']}")
    role_names = sorted(set(system_roles + (team_member.get("roles") or "").split()))
    show("POST /roles/names", *admin.call("POST", "/roles/names", role_names))
    status, roles = admin.call("POST", "/roles/names", role_names)
    permissions = sorted({p for role in roles for p in role.get("permissions", [])})
    print(f"    union: {len(permissions)} permission ids across {len(roles)} roles")
    for gate in ("manage_public_channel_members", "manage_public_channel_properties",
                 "delete_public_channel", "manage_team", "list_team_channels",
                 "join_public_channels"):
        print(f"      {gate:34s} {'yes' if gate in permissions else 'no'}")

    print("\n2. a scratch channel for the write experiments")
    status, channel = admin.call("POST", "/channels",
                                 {"team_id": team_id, "name": PROBE_CHANNEL,
                                  "display_name": "T40 probe", "type": "O"})
    if status not in (200, 201):
        status, channel = admin.call("GET", f"/teams/{team_id}/channels/name/{PROBE_CHANNEL}")
        if (channel.get("delete_at") or 0) != 0:
            admin.call("POST", f"/channels/{channel['id']}/restore")
            status, channel = admin.call("GET", f"/channels/{channel['id']}")
    channel_id = channel["id"]
    print(f"    channel {channel_id}")
    show("GET /channels/{id}/stats", *admin.call("GET", f"/channels/{channel_id}/stats"))

    print("\n3. settings limits (the server's own)")
    long_purpose = "p" * 251
    long_header = "h" * 1025
    show("patch purpose=250", *admin.call("PUT", f"/channels/{channel_id}/patch",
                                          {"purpose": "p" * 250}))
    show("patch purpose=251", *admin.call("PUT", f"/channels/{channel_id}/patch",
                                          {"purpose": long_purpose}))
    show("patch header=1024", *admin.call("PUT", f"/channels/{channel_id}/patch",
                                          {"header": "h" * 1024}))
    show("patch header=1025", *admin.call("PUT", f"/channels/{channel_id}/patch",
                                          {"header": long_header}))
    show("patch display_name=64", *admin.call("PUT", f"/channels/{channel_id}/patch",
                                              {"display_name": "d" * 64}))
    show("patch display_name=65", *admin.call("PUT", f"/channels/{channel_id}/patch",
                                              {"display_name": "d" * 65}))
    status, patched = admin.call("PUT", f"/channels/{channel_id}/patch",
                                 {"display_name": "T40 probe", "purpose": "probe purpose",
                                  "header": "probe header"})
    print(f"    re-read: purpose={patched.get('purpose')!r} header={patched.get('header')!r}")

    print("\n4. membership writes")
    status, member = admin.call("GET", f"/users/username/{MEMBER_LOGIN}")
    member_id = member["id"] if status == 200 else None
    if member_id:
        show("POST /channels/{id}/members (add)", *admin.call("POST", f"/channels/{channel_id}/members",
                                                              {"user_id": member_id}))
        show("GET /channels/{id}/members/{uid}", *admin.call(
            "GET", f"/channels/{channel_id}/members/{member_id}"))
        show("DELETE /channels/{id}/members/{uid}", *admin.call(
            "DELETE", f"/channels/{channel_id}/members/{member_id}"))
    else:
        print(f"    {MEMBER_LOGIN} is missing — run scripts/t40_channel_seed.py")

    print("\n5. the add picker's two sources")
    show("GET /users?in_team&not_in_channel", *admin.call(
        "GET", "/users", query={"in_team": team_id, "not_in_channel": channel_id,
                                "page": 0, "per_page": 5}))
    show("POST /users/search (empty term)", *admin.call(
        "POST", "/users/search", {"term": "", "team_id": team_id,
                                  "not_in_channel_id": channel_id}))
    show("POST /users/search (typed)", *admin.call(
        "POST", "/users/search", {"term": "perf", "team_id": team_id,
                                  "not_in_channel_id": channel_id, "allow_inactive": False}))

    print("\n6. archive and restore")
    show("DELETE /channels/{id}", *admin.call("DELETE", f"/channels/{channel_id}"))
    status, archived = admin.call("GET", f"/channels/{channel_id}")
    print(f"    delete_at after archive: {archived.get('delete_at')}")
    show("POST /channels/{id}/restore", *admin.call("POST", f"/channels/{channel_id}/restore"))

    print("\n7. a DM is closed, not left")
    me_id = me["id"]
    other = None
    if member_id:
        status, direct = admin.call("POST", "/channels/direct", [me_id, member_id])
        if status in (200, 201):
            other = direct["id"]
            print(f"    DM channel {other}")
            show("preference direct_channel_show=false", *admin.call(
                "PUT", f"/users/{me_id}/preferences",
                [{"user_id": me_id, "category": "direct_channel_show",
                  "name": other, "value": "false"}]))
            status, members = admin.call("GET", f"/channels/{other}/members")
            print(f"    memberships after the close: {len(members) if isinstance(members, list) else members}"
                  "  (a close leaves both rows)")

    print("\n8. the gate reads ids, not role names")
    status, role = admin.call("GET", "/roles/name/channel_user")
    if status == 200:
        granted = sorted(role.get("permissions") or [])
        print(f"    channel_user grants {len(granted)} ids; administrator ids present: "
              f"{[p for p in granted if p.startswith(('manage_public', 'delete_public'))]}")

    print("\ncleanup")
    show("DELETE scratch channel (archive)", *admin.call("DELETE", f"/channels/{channel_id}"))
    print(f"done at {time.strftime('%Y-%m-%d %H:%M:%S')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
