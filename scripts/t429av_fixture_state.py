#!/usr/bin/env python3
"""Fixture-hygiene probe for t_97162159: #t429-tap identity, message count and membership, so a
suite run can be shown to reuse the channel (not create another) and not re-add membership."""
import json
import sys
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8065"


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


s, h, b = req("/api/v4/users/login", "POST",
              {"login_id": "perfprobe", "password": "PerfProbe-Not-A-Real-Secret-1"})
tok = h.get("Token")
me = json.loads(b)
teams = json.loads(req("/api/v4/users/me/teams", token=tok)[2])
perf = [t for t in teams if t["name"] == "perf"][0]

for name in ["t429-tap", "t41-profile"]:
    s, _, b = req(f"/api/v4/teams/{perf['id']}/channels/name/{name}", token=tok)
    if s != 200:
        print(f"{name}: ABSENT ({s})")
        continue
    c = json.loads(b)
    s2, _, b2 = req(f"/api/v4/channels/{c['id']}/members?per_page=200", token=tok)
    members = sorted(m["user_id"] for m in json.loads(b2)) if s2 == 200 else []
    s3, _, b3 = req(f"/api/v4/channels/{c['id']}/posts?per_page=1", token=tok)
    page = json.loads(b3) if s3 == 200 else {}
    print(f"{name}: id={c['id']} total_msg_count={c.get('total_msg_count')} "
          f"members={len(members)} newest={(page.get('order') or ['-'])[0]}")
    if name == "t429-tap":
        print("  member ids:", ",".join(members))
print("label:", sys.argv[1] if len(sys.argv) > 1 else "")
