#!/usr/bin/env python3
"""Read the perfprobe account's permission union for one channel and ask whether the ids the
Edit/Delete gate now needs (edit_post / delete_post / delete_others_posts) are in it.

This is the measurement that decides whether the R4 gate hides Edit/Delete from the *live* UI
suites (T35's edit/delete test, T48-AV's own-post test), which sign in as this account.

    python3 scripts/t48av_r4_permission_probe.py
"""
import json
import ssl
import sys
import urllib.request

BASE = "http://127.0.0.1:8065"
LOGIN = ("perfprobe", "PerfProbe-Not-A-Real-Secret-1")


def call(path, token=None, body=None, method=None, want_headers=False):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, data=data, method=method or ("POST" if data else "GET"))
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=20) as r:
        payload = json.loads(r.read().decode() or "{}")
        return (payload, dict(r.headers)) if want_headers else payload


_, headers = call("/api/v4/users/login", body={"login_id": LOGIN[0], "password": LOGIN[1]},
                  want_headers=True)
token = headers.get("Token") or headers.get("token")
if not token:
    sys.exit(f"login answered without a Token header: {sorted(headers)}")
me = call("/api/v4/users/me", token)
print(f"me: {me['id']} roles={me.get('roles')!r}")

teams = call("/api/v4/users/me/teams", token)
team = teams[0]
print(f"team: {team['id']} {team['name']!r}")

channels = call(f"/api/v4/users/me/teams/{team['id']}/channels", token)
channel = channels[0]
print(f"channel: {channel['id']} {channel['name']!r} delete_at={channel.get('delete_at')}")

names = set(filter(None, (me.get("roles") or "").split()))
try:
    tm = call(f"/api/v4/teams/{team['id']}/members/{me['id']}", token)
    names |= set(filter(None, (tm.get("roles") or "").split()))
except Exception as e:  # noqa: BLE001
    print("team membership read failed:", e)
try:
    cm = call(f"/api/v4/channels/{channel['id']}/members/{me['id']}", token)
    names |= set(filter(None, (cm.get("roles") or "").split()))
except Exception as e:  # noqa: BLE001
    print("channel membership read failed:", e)

names = sorted(names)
roles = call("/api/v4/roles/names", token, body=names)
union = set()
for role in roles:
    perms = role.get("permissions") or []
    if isinstance(perms, str):
        perms = perms.split()
    union |= set(filter(None, perms))
print(f"role names: {names}")
print(f"union size: {len(union)}")
for pid in ("create_post", "edit_post", "delete_post", "delete_others_posts",
            "edit_others_posts", "pin_post", "unpin_post"):
    print(f"  {pid:22} {'YES' if pid in union else 'no'}")

# Also list ids that look related, so a missing id is not a spelling mistake on my side.
print("ids containing 'post':", sorted(p for p in union if "post" in p))

# The gate must not hide the rows from an *ordinary* member either: `edit_post`/`delete_post` are
# system_user grants on every release, so a plain account still sees Edit/Delete on its own post.
print()
base_roles = call("/api/v4/roles/names", token, body=["system_user", "channel_user", "team_user"])
for role in base_roles:
    perms = set(role.get("permissions") or [])
    hits = sorted(pid for pid in ("create_post", "edit_post", "delete_post",
                                  "delete_others_posts") if pid in perms)
    print(f"role {role.get('name'):14} {len(perms):3} ids  edit/delete ids present: {hits}")

