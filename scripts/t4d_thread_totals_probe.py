#!/usr/bin/env python3
"""Probe: what does this server report for unread threads (teams/threads totals)?"""
import json, urllib.request, urllib.error

BASE = "http://127.0.0.1:8065/api/v4"


def call(path, data=None, token=None):
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(data).encode() if data is not None else None,
        headers={"Content-Type": "application/json", "X-Requested-With": "XMLHttpRequest",
                 **({"Authorization": "Bearer " + token} if token else {})},
        method="POST" if data is not None else "GET")
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, json.loads(r.read() or b"{}"), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:300], dict(e.headers)


st, me, h = call("/users/login", {"login_id": "perfprobe",
                                 "password": "PerfProbe-Not-A-Real-Secret-1"})
print("login", st, me.get("username") if isinstance(me, dict) else me)
tok = h.get("Token")
st, teams, _ = call("/users/me/teams", token=tok)
print("teams", [(t["name"], t["id"]) for t in teams])
team = [t for t in teams if t["name"] == "perf"][0]["id"]
st, page, _ = call(f"/users/me/teams/{team}/threads?per_page=60&extended=true", token=tok)
print("all page", st, "threads", len(page.get("threads", [])),
      {k: v for k, v in page.items() if k != "threads"})
st, unread, _ = call(f"/users/me/teams/{team}/threads?per_page=60&unread=true", token=tok)
print("unread page", st, "threads", len(unread.get("threads", [])),
      {k: v for k, v in unread.items() if k != "threads"})
if unread.get("threads"):
    t = unread["threads"][0]
    print("unread[0]", {k: t.get(k) for k in ("id", "reply_count", "unread_replies",
                                              "unread_mentions", "last_reply_at")})
