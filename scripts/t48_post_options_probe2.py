#!/usr/bin/env python3
"""T48 probe #2 — pin permissions, thread follow on a real thread, mark-unread counters.

Password from MM_PROBE_PASSWORD (throwaway dev account). Run:
  MM_PROBE_PASSWORD=… python3 scripts/t48_post_options_probe2.py
"""
import json
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("MM_PROBE_SERVER", "http://127.0.0.1:8065")
LOGIN = os.environ.get("MM_PROBE_LOGIN", "perfprobe")
PASSWORD = os.environ.get("MM_PROBE_PASSWORD", "")
SECOND_LOGIN = os.environ.get("MM_PROBE_SECOND_LOGIN", "t36reply")
SECOND_PASSWORD = os.environ.get("MM_PROBE_SECOND_PASSWORD", "T36Reply-Not-A-Real-Secret-1")


def call(method, path, token=None, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + "/api/v4" + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            raw = r.read()
            if path == "/users/login":
                return r.status, {"session": json.loads(raw), "token": r.headers.get("Token", "")}
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            parsed = json.loads(raw)
        except Exception:
            parsed = raw.decode(errors="replace")
        return e.code, parsed


def login(login_id, password):
    status, answer = call("POST", "/users/login", body={"login_id": login_id, "password": password})
    return status, answer["token"], answer["session"]["id"], answer["session"]


def main():
    if not PASSWORD:
        print("set MM_PROBE_PASSWORD", file=sys.stderr)
        return 2
    _, token, uid, session = login(LOGIN, PASSWORD)
    print("me", session["username"], uid)
    _, teams = call("GET", "/users/me/teams", token)
    perf = next(t for t in teams if t["name"] == "perf")
    tid = perf["id"]
    _, ch = call("GET", f"/teams/{tid}/channels/name/t36-threads", token)
    cid = ch["id"]

    # 1. Which permission ids mention pin at all?
    _, me = call("GET", "/users/me", token)
    tmem = call("GET", f"/teams/{tid}/members/{uid}", token)[1]
    cmem = call("GET", f"/channels/{cid}/members/{uid}", token)[1]
    names = sorted({r for r in (me["roles"] + " " + tmem["roles"] + " " + cmem["roles"]).split() if r})
    _, roles = call("POST", "/roles/names", token, names)
    perms = set()
    for r in roles:
        perms.update(r.get("permissions", []))
    print("permissions naming pin:", sorted(p for p in perms if "pin" in p))
    print("permissions naming post:", sorted(p for p in perms if "post" in p))

    # 2. Does another (non-admin) account get 403 on pin?
    s2, tok2, uid2, ses2 = login(SECOND_LOGIN, SECOND_PASSWORD)
    print("second", s2, ses2["username"], ses2["roles"])
    tm2 = call("GET", f"/teams/{tid}/members/{uid2}", tok2)[1]
    cm2 = call("GET", f"/channels/{cid}/members/{uid2}", tok2)[1]
    names2 = sorted({r for r in (ses2["roles"] + " " + tm2.get("roles", "") + " " + cm2.get("roles", "")).split() if r})
    _, roles2 = call("POST", "/roles/names", tok2, names2)
    perms2 = set()
    for r in roles2:
        perms2.update(r.get("permissions", []))
    print("second permissions naming pin:", sorted(p for p in perms2 if "pin" in p), "total", len(perms2))
    _, post2 = call("POST", "/posts", tok2, {"channel_id": cid, "message": "t48 probe2 pin by member"})
    pid2 = post2["id"]
    st, ans = call("POST", f"/posts/{pid2}/pin", tok2)
    print("member pin", st, ans if not isinstance(ans, dict) or len(str(ans)) < 200 else "...")
    st, ans = call("POST", f"/posts/{pid2}/unpin", tok2)
    print("member unpin", st, ans if not isinstance(ans, dict) or len(str(ans)) < 200 else "...")

    # 3. Follow, on a root that really has a reply.
    _, root = call("POST", "/posts", token, {"channel_id": cid, "message": "t48 probe2 root"})
    rid = root["id"]
    _, reply = call("POST", "/posts", tok2, {"channel_id": cid, "message": "t48 probe2 reply",
                                             "root_id": rid})
    print("root", rid, "reply", reply["id"], "reply root", reply.get("root_id"))
    st, th = call("GET", f"/users/me/teams/{tid}/threads/{rid}", token)
    print("followedThread before", st, th.get("id") if isinstance(th, dict) else th)
    st, ans = call("PUT", f"/users/me/teams/{tid}/threads/{rid}/following", token, {})
    print("follow", st, ans)
    st, th = call("GET", f"/users/me/teams/{tid}/threads/{rid}", token)
    print("followedThread after", st, th.get("id") if isinstance(th, dict) else th,
          "following" if isinstance(th, dict) and th.get("id") else "")
    # mark unread through the *post* route for a reply, then the thread route.
    before = call("GET", f"/channels/{cid}/members/me", token)[1]
    st, ans = call("POST", f"/users/{uid}/posts/{reply['id']}/set_unread", token,
                   {"collapsed_threads_supported": True})
    after = call("GET", f"/channels/{cid}/members/me", token)[1]
    print("post set_unread on a reply", st)
    print("  membership before", {k: before.get(k) for k in ("msg_count", "msg_count_root", "last_viewed_at")})
    print("  membership after ", {k: after.get(k) for k in ("msg_count", "msg_count_root", "last_viewed_at")})
    st, ans = call("POST", f"/users/me/teams/{tid}/threads/{rid}/set_unread/{reply['id']}", token, {})
    print("thread set_unread", st, {k: ans.get(k) for k in ("id", "unread_replies", "unread_mentions")} if isinstance(ans, dict) else ans)
    st, ans = call("DELETE", f"/users/me/teams/{tid}/threads/{rid}/following", token)
    print("unfollow", st, ans)

    # 4. Does the created root show up in the channel page with is_pinned after a pin?
    call("POST", f"/posts/{rid}/pin", token)
    _, page = call("GET", f"/channels/{cid}/posts?per_page=5&collapsedThreads=true", token)
    row = page["posts"].get(rid, {})
    print("page row after pin: is_pinned", row.get("is_pinned"), "update_at", row.get("update_at"))
    _, single = call("GET", f"/posts/{rid}", token)
    print("single post after pin: is_pinned", single.get("is_pinned"))
    call("POST", f"/posts/{rid}/unpin", token)
    return 0


if __name__ == "__main__":
    sys.exit(main())
