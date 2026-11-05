#!/usr/bin/env python3
"""t_03411e94 probe: does the *live* 9.11.19 fixture answer what the composer asks?

The composer's posting state is derived from two server facts (`ComposerPosting.swift`), and this
script asks the server for exactly them, through exactly the routes `SessionComposerPostingPolicy`
uses, so "the read works against a real server" is measured rather than assumed:

    GET  /channels/{id}                  -> delete_at, type, team_id
    GET  /users/me                       -> the system roles
    GET  /channels/{id}/members/me       -> the channel membership's roles
    GET  /users/me/teams/{tid}/members/{uid}  (i.e. GET /teams/{tid}/members/{uid})
                                         -> the team membership's roles
    POST /roles/names                    -> the union's permission ids

and then, to prove both directions of the derivation:

    DELETE /channels/{id}                -> archive  (delete_at != 0  => .archived)
    POST   /channels/{id}/restore        -> restore  (delete_at == 0)

Usage:
    python3 scripts/t4g_posting_probe.py --url http://127.0.0.1:8065

Exit 0 when every step answered as the client expects; non-zero with the failing step otherwise.
Nothing is left behind: the probe channel is archived and then restored to its live state, and it
carries a fresh name per run.
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
TEAM_NAME = "perf"


def call(base: str, method: str, path: str, token: str | None = None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(f"{base}/api/v4{path}", data=data, method=method)
    request.add_header("Content-Type", "application/json")
    request.add_header("X-Requested-With", "XMLHttpRequest")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = response.read()
            return response.status, json.loads(payload) if payload else None
    except urllib.error.HTTPError as error:
        payload = error.read()
        try:
            parsed = json.loads(payload) if payload else None
        except json.JSONDecodeError:
            parsed = payload.decode(errors="replace")
        return error.code, parsed


def login(base: str):
    """`POST /users/login` — the token is a response header, the profile is the body."""
    request = urllib.request.Request(f"{base}/api/v4/users/login",
                                     data=json.dumps({"login_id": USERNAME,
                                                      "password": PASSWORD}).encode(),
                                     method="POST")
    request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request, timeout=30) as response:
        token = response.headers.get("Token", "")
        user = json.loads(response.read())
    return token, user


def check(condition: bool, message: str) -> None:
    print(("  ok   " if condition else "  FAIL ") + message)
    if not condition:
        raise SystemExit(1)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    args = parser.parse_args()
    base = args.url.rstrip("/")

    status, _ = call(base, "GET", "/system/ping")
    check(status == 200, f"{base} answers /system/ping")

    status, user = call(base, "POST", "/users/login",
                        body={"login_id": USERNAME, "password": PASSWORD})
    check(status == 200 and isinstance(user, dict) and user.get("id"),
          f"{USERNAME} can sign in")
    # `POST /users/login` answers the user row in the body and the session token in a header, so the
    # probe logs in through the helper that reads both.
    token, user = login(base)
    check(bool(token), "the login answer carries a Token header")
    user_id = user["id"]
    print(f"  user id={user_id} system roles={user.get('roles', '')!r}")

    status, teams = call(base, "GET", "/users/me/teams", token=token)
    check(status == 200, "GET /users/me/teams answers")
    team = next((t for t in teams if t.get("name") == TEAM_NAME), None)
    check(team is not None, f"team #{TEAM_NAME} is one of this account's teams")
    team_id = team["id"]

    stamp = int(time.time())
    status, channel = call(base, "POST", "/channels", token=token,
                           body={"team_id": team_id,
                                 "name": f"t4g-probe-{stamp}",
                                 "display_name": f"t4g probe {stamp}",
                                 "type": "O"})
    check(status == 201 and channel.get("id"), "a probe channel can be created")
    channel_id = channel["id"]
    print(f"  channel id={channel_id} name={channel['name']}")

    # The four reads the policy fans in.
    status, row = call(base, "GET", f"/channels/{channel_id}", token=token)
    check(status == 200, "GET /channels/{id} answers")
    check(row.get("delete_at") == 0, "a fresh channel has delete_at == 0")
    print(f"  channel type={row.get('type')} team_id={row.get('team_id')} delete_at={row.get('delete_at')}")

    status, membership = call(base, "GET", f"/channels/{channel_id}/members/me", token=token)
    check(status == 200, "GET /channels/{id}/members/me answers")
    channel_roles = membership.get("roles", "")
    print(f"  channel roles={channel_roles!r} scheme_user={membership.get('scheme_user')}")

    status, team_membership = call(base, "GET", f"/teams/{team_id}/members/{user_id}", token=token)
    check(status == 200, "GET /teams/{tid}/members/{uid} answers")
    team_roles = team_membership.get("roles", "")
    print(f"  team roles={team_roles!r}")

    names: list[str] = []
    for source in (user.get("roles", ""), team_roles, channel_roles):
        for name in source.split(" "):
            if name and name not in names:
                names.append(name)
    print(f"  role names={names}")

    status, roles = call(base, "POST", "/roles/names", token=token, body=names)
    check(status == 200 and isinstance(roles, list), "POST /roles/names answers (a bare array of names)")
    permissions = {permission for role in roles for permission in role.get("permissions", [])}
    check("create_post" in permissions,
          "the union carries create_post for an ordinary member of a public channel "
          "(so the composer stays open here)")
    print(f"  {len(permissions)} permission ids in the union, create_post present")

    # Direction 1: archival. The composer's derivation says .archived from delete_at alone.
    status, _ = call(base, "DELETE", f"/channels/{channel_id}", token=token)
    check(status == 200, "DELETE /channels/{id} answers 200")
    status, row = call(base, "GET", f"/channels/{channel_id}", token=token)
    check(status == 200 and row.get("delete_at", 0) != 0,
          f"the server reports the channel archived (delete_at={row.get('delete_at')})")
    print("  => ComposerPostingState.derive(.archived) on delete_at != 0")

    # Direction 2: restore. `channel_restored` names only the id, which is why the client re-reads.
    status, _ = call(base, "POST", f"/channels/{channel_id}/restore", token=token, body={})
    check(status == 200, "POST /channels/{id}/restore answers 200")
    status, row = call(base, "GET", f"/channels/{channel_id}", token=token)
    check(status == 200 and row.get("delete_at", 0) == 0,
          "the restored channel reports delete_at == 0 again")
    print("  => ComposerPostingState.derive(.open) after the restore re-read")
    print("\nOK: the live server answers every fact the composer's state is derived from")
    return 0


if __name__ == "__main__":
    sys.exit(main())
