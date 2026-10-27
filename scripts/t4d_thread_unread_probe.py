#!/usr/bin/env python3
"""Probe: how does a fresh thread become unread for its root's author on this server?

Measures, in order:
 1. root by me -> unread_replies?
 2. reply by another account -> unread_replies?
 3. PUT .../following -> unread_replies?
 4. the team's totals for /threads (total_unread_threads)
"""
import json, time, urllib.request, urllib.error

BASE = "http://127.0.0.1:8065/api/v4"
ME = ("perfprobe", "PerfProbe-Not-A-Real-Secret-1")
OTHER = ("t36reply", "T36Reply-Not-A-Real-Secret-1")


def call(path, data=None, token=None, method=None, cookie_free=True):
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(data).encode() if data is not None else None,
        headers={"Content-Type": "application/json", "X-Requested-With": "XMLHttpRequest",
                 **({"Authorization": "Bearer " + token} if token else {})},
        method=method or ("POST" if data is not None else "GET"))
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.loads(r.read() or b"{}"), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:300], dict(e.headers)


def login(u, p):
    st, me, h = call("/users/login", {"login_id": u, "password": p})
    assert st == 200, (st, me)
    return h["Token"], me["id"]


tok, me_id = login(*ME)
other_tok, other_id = login(*OTHER)
st, teams, _ = call("/users/me/teams", token=tok)
team = [t for t in teams if t["name"] == "perf"][0]["id"]
st, chans, _ = call(f"/users/me/teams/{team}/channels", token=tok)
chans = [c for c in chans if c["type"] in ("O", "P")]
print("channels", [(c["name"], c["id"]) for c in chans][:6])
ch = chans[0]["id"]

st, totals, _ = call(f"/users/me/teams/{team}/threads?per_page=1&totalsOnly=true", token=tok)
print("totals before", st, totals)

st, root, _ = call("/posts", {"channel_id": ch, "message": f"probe root {time.time()}"}, token=tok)
print("root", st, root["id"], "user", root["user_id"] == me_id)
rid = root["id"]


def show(label):
    st, th, _ = call(f"/users/me/teams/{team}/threads/{rid}", token=tok)
    if not isinstance(th, dict):
        print(f"{label}: status={st} body={th}")
        return
    print(f"{label}: status={st} unread_replies={th.get('unread_replies')} "
          f"unread_mentions={th.get('unread_mentions')} last_viewed_at={th.get('last_viewed_at')} "
          f"last_reply_at={th.get('last_reply_at')}")


show("after root")
time.sleep(1.0)
show("after root +1s")

st, rep, _ = call("/posts", {"channel_id": ch, "message": f"probe reply {time.time()}", "root_id": rid},
                  token=other_tok)
print("reply", st, rep["id"], "user is other", rep["user_id"] == other_id)
show("after reply")
time.sleep(1.0)
show("after reply +1s")

st, f, _ = call(f"/users/me/teams/{team}/threads/{rid}/following", {}, token=tok, method="PUT")
print("follow", st, f)
show("after follow")
st, totals, _ = call(f"/users/me/teams/{team}/threads?per_page=1&totalsOnly=true", token=tok)
print("totals after", st, totals)
st, unread, _ = call(f"/users/me/teams/{team}/threads?per_page=60&unread=true", token=tok)
print("unread page carries ours:", any(t.get("id") == rid for t in unread.get("threads", [])),
      "rows", len(unread.get("threads", [])))
