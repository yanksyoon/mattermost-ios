#!/usr/bin/env python3
"""t_97162159 attack 4: build a REAL deactivated-account fixture for #t429-tap and measure what the
9.11.19 server does with it, so the action matrix's deactivated row can be checked against the server
instead of only against a pure function.

Steps (idempotent, additive — it never touches another card's channel):
  1. ensure the account `t429gone` exists and is a member of team `perf` and channel `t429-tap`;
  2. post a fixture message as `t429gone` (so the row is newest and authored by a now-deactivated user);
  3. deactivate it (DELETE /users/{id});
  4. measure: GET /users/{id} delete_at, POST /users/ids still resolves the account, and what
     POST /channels/direct answers for a deactivated account (the premise of `DMShortcut.canMessage`);
  5. print the post id for the UI probe.

Usage: python3 t429_deactivated_fixture.py [--reactivate]
"""
import json
import sys
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8065"
ADMIN_LOGIN = "perfprobe"
ADMIN_PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
GONE_LOGIN = "t429gone"
GONE_PASSWORD = "T429-Gone-Not-A-Real-Secret-1"
GONE_EMAIL = "t429gone@example.invalid"


def req(path, method="GET", body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method)
    r.add_header("Content-Type", "application/json")
    if token:
        r.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(r) as resp:
            return resp.status, resp.headers, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read()


def login(login_id, password):
    s, h, b = req("/api/v4/users/login", "POST", {"login_id": login_id, "password": password})
    if s != 200:
        raise SystemExit(f"login {login_id} -> {s} {b[:200]}")
    return h.get("Token"), json.loads(b)


tok, admin = login(ADMIN_LOGIN, ADMIN_PASSWORD)
print("admin", admin["id"], admin["username"])

# 1. the account
s, _, b = req("/api/v4/users/username/" + GONE_LOGIN, token=tok)
if s == 200:
    gone = json.loads(b)
    print("user exists", gone["id"], "delete_at", gone["delete_at"])
else:
    s, _, b = req("/api/v4/users", "POST", {"email": GONE_EMAIL, "username": GONE_LOGIN,
                                            "password": GONE_PASSWORD}, tok)
    if s not in (200, 201):
        raise SystemExit(f"create -> {s} {b[:300]}")
    gone = json.loads(b)
    print("user created", gone["id"])

teams = json.loads(req("/api/v4/users/me/teams", token=tok)[2])
perf = [t for t in teams if t["name"] == "perf"][0]
team_id = perf["id"]

# team membership (needed before a channel membership for an open channel)
s, _, b = req(f"/api/v4/teams/{team_id}/members/{gone['id']}", token=tok)
if s != 200:
    s, _, b = req(f"/api/v4/teams/{team_id}/members", "POST",
                  {"team_id": team_id, "user_id": gone["id"]}, tok)
    print("team member add ->", s, b[:120])
else:
    print("already a team member")

s, _, b = req(f"/api/v4/teams/{team_id}/channels/name/t429-tap", token=tok)
channel = json.loads(b)
channel_id = channel["id"]
s, _, b = req(f"/api/v4/channels/{channel_id}/members/{gone['id']}", token=tok)
if s != 200:
    s, _, b = req(f"/api/v4/channels/{channel_id}/members", "POST",
                  {"user_id": gone["id"]}, tok)
    print("channel member add ->", s, b[:120])
else:
    print("already a channel member")

# 2. reactivate if a previous run deactivated it, then post as them
s, _, b = req(f"/api/v4/users/{gone['id']}/active", "PUT", {"active": True}, tok)
print("ensure active ->", s)
gone_tok, gone_me = login(GONE_LOGIN, GONE_PASSWORD)
s, _, b = req("/api/v4/posts", "POST",
              {"channel_id": channel_id, "message": "t_42968927 deactivated fixture (author is t429gone)"},
              gone_tok)
if s not in (200, 201):
    raise SystemExit(f"post -> {s} {b[:300]}")
post = json.loads(b)
print("fixture post", post["id"], "by", post["user_id"], "create_at", post["create_at"])

# 3. deactivate
s, _, b = req(f"/api/v4/users/{gone['id']}", "DELETE", token=tok)
print("deactivate ->", s, b[:120])

# 4. measure what the server says about a deactivated account
s, _, b = req(f"/api/v4/users/{gone['id']}", token=tok)
u = json.loads(b) if s == 200 else {}
print("GET /users/{id} ->", s, "delete_at", u.get("delete_at"), "username", u.get("username"))

s, _, b = req("/api/v4/users/ids", "POST", [gone["id"]], tok)
ids = json.loads(b) if s == 200 else []
print("POST /users/ids ->", s, "returned", [x.get("id") for x in ids],
      "delete_at", [x.get("delete_at") for x in ids])

s, _, b = req("/api/v4/channels/direct", "POST", [admin["id"], gone["id"]], tok)
print("POST /channels/direct with a deactivated half ->", s, b[:220].decode(errors="replace"))

print("PROBE-RESULT post_id=%s user_id=%s channel_id=%s" % (post["id"], gone["id"], channel_id))

if "--reactivate" in sys.argv:
    s, _, b = req(f"/api/v4/users/{gone['id']}/active", "PUT", {"active": True}, tok)
    print("reactivate ->", s, b[:120])
