#!/usr/bin/env python3
"""T48 probe — measure the endpoints the post-options menu needs, on the pinned 9.11.19 server.

No credentials in this file: password from MM_PROBE_PASSWORD (the throwaway dev account).
Writes docs/t48-probe.log via tee when used as `python3 scripts/t48_post_options_probe.py | tee ...`.
"""
import json
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("MM_PROBE_SERVER", "http://127.0.0.1:8065")
LOGIN = os.environ.get("MM_PROBE_LOGIN", "perfprobe")
PASSWORD = os.environ.get("MM_PROBE_PASSWORD", "")


def call(method, path, token=None, body=None):
    """Returns (status, decoded body). The auth token of a login lives in the `Token` header."""
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


def main():
    if not PASSWORD:
        print("set MM_PROBE_PASSWORD", file=sys.stderr)
        return 2
    status, session = call("POST", "/users/login", body={"login_id": LOGIN, "password": PASSWORD})
    print("login", status)
    token, uid = session["token"], session["session"]["id"]

    status, teams = call("GET", "/users/me/teams", token)
    perf = next(t for t in teams if t["name"] == "perf")
    print("team perf", perf["id"], perf["name"])
    for name in ("t36-threads", "t40-browse-t", "town-square"):
        status, ch = call("GET", f"/teams/{perf['id']}/channels/name/{name}", token)
        print("channel", name, status, ch.get("id") if isinstance(ch, dict) else ch)

    ch = call("GET", f"/teams/{perf['id']}/channels/name/t36-threads", token)[1]
    cid = ch["id"]

    status, me = call("GET", "/users/me", token)
    print("principal", status, me.get("roles"))
    tmem = call("GET", f"/teams/{perf['id']}/members/{uid}", token)[1]
    cmem = call("GET", f"/channels/{cid}/members/{uid}", token)[1]
    print("team roles", tmem.get("roles"), "channel roles", cmem.get("roles"))
    names = sorted({r for r in (me.get("roles", "") + " " + tmem.get("roles", "") + " " + cmem.get("roles", "")).split() if r})
    status, roles = call("POST", "/roles/names", token, names)
    perms = set()
    for r in roles:
        perms.update(r.get("permissions", []))
    print("roles answered", status, len(roles), "permissions", len(perms))
    for pid in ("pin_post", "unpin_post", "create_post", "edit_post", "delete_post"):
        print("permission", pid, pid in perms)

    # A post of my own plus one from another account, for the menu rows.
    status, post = call("POST", "/posts", token, {"channel_id": cid, "message": "t48 probe target"})
    pid = post["id"]
    print("post", status, pid, "is_pinned", post.get("is_pinned"), "root", post.get("root_id"))

    # set_unread: what it answers and what it changes.
    before = call("GET", f"/channels/{cid}/members/me", token)[1]
    print("membership before", {k: before.get(k) for k in ("msg_count", "mention_count", "last_viewed_at")})
    ch_before = call("GET", f"/channels/{cid}", token)[1]
    print("channel counters before", {k: ch_before.get(k) for k in ("total_msg_count", "total_msg_count_root")})
    status, answer = call("POST", f"/users/{uid}/posts/{pid}/set_unread", token,
                          {"collapsed_threads_supported": True})
    print("set_unread", status, answer if not isinstance(answer, dict) or len(str(answer)) < 400 else "...")
    if isinstance(answer, dict):
        print("set_unread keys", sorted(answer.keys()))
    after = call("GET", f"/channels/{cid}/members/me", token)[1]
    print("membership after", {k: after.get(k) for k in ("msg_count", "mention_count", "last_viewed_at")})

    # pin/unpin and what the post looks like after.
    status, ok = call("POST", f"/posts/{pid}/pin", token)
    print("pin", status, ok)
    pinned = call("GET", f"/posts/{pid}", token)[1]
    print("post after pin", pinned.get("is_pinned"), "update_at", pinned.get("update_at"))
    status, ok = call("POST", f"/posts/{pid}/unpin", token)
    print("unpin", status, ok)
    unpinned = call("GET", f"/posts/{pid}", token)[1]
    print("post after unpin", unpinned.get("is_pinned"))

    # save/unsave as the preference, and where the saved list reads from.
    status, ok = call("PUT", f"/users/{uid}/preferences", token,
                      [{"user_id": uid, "category": "flagged_post", "name": pid, "value": "true"}])
    print("save preference", status, ok)
    status, prefs = call("GET", f"/users/me/preferences", token)
    flagged = [p for p in prefs if p.get("category") == "flagged_post" and p.get("name") == pid]
    print("preferences", status, "flagged rows for this post", flagged)
    status, list_ = call("GET", f"/users/me/posts/flagged?team_id={perf['id']}&per_page=60", token)
    order = list_.get("order", []) if isinstance(list_, dict) else []
    print("flagged list", status, "contains", pid in order)
    status, ok = call("POST", f"/users/{uid}/preferences/delete", token,
                      [{"user_id": uid, "category": "flagged_post", "name": pid, "value": "true"}])
    print("unsave preference", status, ok)

    # follow state read + write for a root post's thread id.
    status, thread = call("GET", f"/users/me/teams/{perf['id']}/threads/{pid}", token)
    print("followedThread before", status, thread if status != 200 else thread.get("id"))
    status, ok = call("PUT", f"/users/me/teams/{perf['id']}/threads/{pid}/following", token, {})
    print("follow", status, ok)
    status, thread = call("GET", f"/users/me/teams/{perf['id']}/threads/{pid}", token)
    print("followedThread after", status, thread.get("id") if isinstance(thread, dict) else thread)
    status, ok = call("DELETE", f"/users/me/teams/{perf['id']}/threads/{pid}/following", token)
    print("unfollow", status, ok)

    # Permalink the server actually serves.
    for path in (f"/perf/pl/{pid}", f"/{perf['id']}/pl/{pid}"):
        req = urllib.request.Request(BASE + path, method="GET")
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                print("permalink", path, r.status, r.headers.get("Content-Type"), len(r.read()))
        except urllib.error.HTTPError as e:
            print("permalink", path, e.code)
    return 0


if __name__ == "__main__":
    sys.exit(main())
