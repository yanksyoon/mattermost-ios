#!/usr/bin/env python3
"""What channel does T45AvatarUITests pick, and how deep is it in the sidebar? (t_6d420e01)

The live T45 test walks the native sidebar for a bounded number of swipes. On this fixture the
probe account is in hundreds of channels (other cards' throwaway fixtures), so "fewest posts" can
land on a row the bounded walk never reaches. This prints the pick, its display name, and the
account's channel count so the failure can be described (and the fixture, not the test, blamed)
with numbers.
"""
import json
import urllib.request

BASE = "http://127.0.0.1:8065"


def call(path, token=None):
    req = urllib.request.Request(BASE + path)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else None


login = urllib.request.Request(
    BASE + "/api/v4/users/login",
    data=json.dumps({"login_id": "perfprobe",
                     "password": "PerfProbe-Not-A-Real-Secret-1"}).encode(),
    method="POST")
login.add_header("Content-Type", "application/json")
with urllib.request.urlopen(login) as resp:
    me = json.loads(resp.read())
    token = resp.headers.get("Token")
uid = me["id"]

teams = call("/api/v4/users/me/teams", token)
team = teams[0]
channels = call(f"/api/v4/users/me/teams/{team['id']}/channels", token)
print("team      :", team["display_name"], team["id"])
print("channels  :", len(channels))

PICK = "46rf536iki8pfqqyc7i11ff8er"
pick = call(f"/api/v4/channels/{PICK}", token)
print("picked    :", pick["display_name"], "/", pick["name"], "id", pick["id"])
names = sorted(c["display_name"] for c in channels)
rank = names.index(pick["display_name"]) if pick["display_name"] in names else -1
print("alpha rank:", rank, "of", len(names), "(0 = first row of the list)")

# How many of this account's channels are single-post throwaways from other cards?
one_post = 0
for c in channels:
    if c["type"] != "O":
        continue
    posts = call(f"/api/v4/channels/{c['id']}/posts?per_page=2", token)
    if len(posts.get("order", [])) <= 1:
        one_post += 1
print("open chans with <=1 post:", one_post)
