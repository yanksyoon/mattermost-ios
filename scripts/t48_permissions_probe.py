"""Measure the four calls `SessionPostOptionsService.permissions` makes on the pinned 9.11.19 server.

Why: T48's live UI test measured Pin *withheld* on a plain root post, which the derivation only does
when the permission lookup answered nothing (or threw). This script answers which of the four calls
fails, so the fix is aimed at the call rather than at the gate.

    python3 scripts/t48_permissions_probe.py            # password from MM_PROBE_PASSWORD
"""

import json
import os
import sys
import urllib.error
import urllib.request

SERVER = os.environ.get("MM_PROBE_SERVER", "http://127.0.0.1:8065")
LOGIN = os.environ.get("MM_PROBE_LOGIN", "perfprobe")
PASSWORD = os.environ.get("MM_PROBE_PASSWORD", "")
TEAM = os.environ.get("MM_PROBE_TEAM", "perf")
CHANNEL = os.environ.get("MM_PROBE_CHANNEL", "t36-threads")


def call(method, path, token=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(SERVER + "/api/v4" + path, data=data, method=method)
    request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return response.status, json.loads(response.read() or b"null"), dict(response.headers)
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode(errors="replace")[:300], {}


def main():
    if not PASSWORD:
        sys.exit("MM_PROBE_PASSWORD is not set")
    status, session, headers = call("POST", "/users/login",
                                    body={"login_id": LOGIN, "password": PASSWORD})
    if status != 200:
        sys.exit(f"login answered {status}: {session}")
    token = session.get("token") or headers.get("Token")
    user_id = session["id"]
    print(f"login 200 user={user_id} token={'body' if session.get('token') else 'header'}")

    status, me, _ = call("GET", "/users/me", token=token)
    print(f"GET /users/me                     -> {status} roles={me.get('roles') if status == 200 else me}")

    status, teams, _ = call("GET", "/users/me/teams", token=token)
    team = next((t for t in teams if t.get("name") == TEAM), None) if status == 200 else None
    print(f"GET /users/me/teams               -> {status} #{TEAM}={team and team.get('id')}")
    if not team:
        sys.exit("no fixture team")
    team_id = team["id"]

    status, channel, _ = call("GET", f"/teams/{team_id}/channels/name/{CHANNEL}", token=token)
    print(f"GET /teams/{{t}}/channels/name/{{c}} -> {status} id={channel.get('id') if status == 200 else channel}")
    if status != 200:
        sys.exit("no fixture channel")
    channel_id = channel["id"]

    status, team_member, _ = call("GET", f"/teams/{team_id}/members/{user_id}", token=token)
    print(f"GET /teams/{{t}}/members/{{u}}        -> {status} roles={team_member.get('roles') if status == 200 else team_member}")

    status, channel_member, _ = call("GET", f"/channels/{channel_id}/members/{user_id}", token=token)
    print(f"GET /channels/{{c}}/members/{{u}}     -> {status} roles={channel_member.get('roles') if status == 200 else channel_member}")

    names = sorted({name for row in (me.get("roles"), (team_member or {}).get("roles"),
                                     (channel_member or {}).get("roles"))
                    if isinstance(row, str) for name in row.split()})
    print(f"names={names}")
    status, roles, _ = call("POST", "/roles/names", token=token, body=names)
    print(f"POST /roles/names                 -> {status}")
    if status != 200:
        print(roles)
        return
    union = sorted({pid for role in roles for pid in (role.get("permissions") or [])})
    print(f"permission ids ({len(union)}): create_post={'create_post' in union} "
          f"pin_post={'pin_post' in union} unpin_post={'unpin_post' in union}")
    print("read_channel" in union, "manage_system" in union)


if __name__ == "__main__":
    main()
