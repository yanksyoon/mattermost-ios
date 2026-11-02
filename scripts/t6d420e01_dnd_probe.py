#!/usr/bin/env python3
"""How does `PUT /users/me/status` treat `dnd_end_time`? (t_6d420e01 diagnostic)

T41ProfileUITests' DND test chooses "Do not disturb" through the app, which writes a
`dnd_end_time` about 20 minutes out. Its cleanup then writes `online` *without* the field,
and the next test (alphabetically) asserts the presence row reads exactly "Do not disturb".
This script asks the server whether that cleanup leaves the end time behind, and whether an
explicit `dnd_end_time: 0` clears it — i.e. which cleanup the test can honestly use.

Throwaway; not imported by anything.
"""
import json
import time
import urllib.request

BASE = "http://127.0.0.1:8065"


def call(path, data=None, token=None, method=None, want_token=False):
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(BASE + path, data=body, method=method or ("POST" if body else "GET"))
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req) as resp:
        raw = resp.read()
        header = resp.headers.get("Token")
    payload = json.loads(raw) if raw else None
    return (payload, header) if want_token else payload


me, token = call("/api/v4/users/login",
                 {"login_id": "perfprobe", "password": "PerfProbe-Not-A-Real-Secret-1"},
                 want_token=True)
uid = me["id"]


def status():
    s = call(f"/api/v4/users/{uid}/status", token=token)
    return s["status"], s.get("dnd_end_time"), s.get("manual")


def put(fields):
    call(f"/api/v4/users/{uid}/status", dict({"user_id": uid}, **fields), token=token,
         method="PUT")
    time.sleep(0.6)
    return status()


print("start                              :", status())
future = int((time.time() + 20 * 60) * 1000)
print("dnd + end=+20min                   :", put({"status": "dnd", "dnd_end_time": future}))
print("online, field omitted (today's fix):", put({"status": "online"}))
print("online, end=0 (candidate cleanup)  :", put({"status": "online", "dnd_end_time": 0}))
print("online, end=null                   :", put({"status": "online", "dnd_end_time": None}))
print("final                              :", status())
