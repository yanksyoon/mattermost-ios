#!/usr/bin/env python3
"""T48 probe #4 — the exact thread object fields, and the follow flag's home."""
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
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw.decode(errors="replace")


def login(login_id, password):
    _, answer = call("POST", "/users/login", body={"login_id": login_id, "password": password})
    return answer["token"], answer["session"]["id"]


def main():
    if not PASSWORD:
        print("set MM_PROBE_PASSWORD", file=sys.stderr)
        return 2
    token, uid = login(LOGIN, PASSWORD)
    tok2, _ = login(SECOND_LOGIN, SECOND_PASSWORD)
    _, teams = call("GET", "/users/me/teams", token)
    perf = next(t for t in teams if t["name"] == "perf")
    tid = perf["id"]
    _, ch = call("GET", f"/teams/{tid}/channels/name/t36-threads", token)
    cid = ch["id"]
    _, root = call("POST", "/posts", token, {"channel_id": cid, "message": "t48 probe4 root"})
    rid = root["id"]
    call("POST", "/posts", tok2, {"channel_id": cid, "message": "t48 probe4 reply", "root_id": rid})

    def show(label):
        st, th = call("GET", f"/users/me/teams/{tid}/threads/{rid}", token)
        if st == 200:
            keys = sorted(th.keys())
            print(label, st, "top keys:", keys)
            print("  is_following?", th.get("is_following"), "| post keys has is_following:",
                  "is_following" in th.get("post", {}), "=", th.get("post", {}).get("is_following"))
            print("  reply_count", th.get("reply_count"), "unread_replies", th.get("unread_replies"))
        else:
            print(label, st, th)

    show("before follow")
    call("PUT", f"/users/me/teams/{tid}/threads/{rid}/following", token, {})
    show("after follow")
    st, page = call("GET", f"/channels/{cid}/posts?per_page=5&collapsedThreads=true", token)
    row = page["posts"].get(rid, {})
    print("channel page row for root: is_following =", row.get("is_following"), "| reply_count =", row.get("reply_count"))
    st, single = call("GET", f"/posts/{rid}", token)
    print("single post: is_following =", single.get("is_following"))
    call("DELETE", f"/users/me/teams/{tid}/threads/{rid}/following", token)
    return 0


if __name__ == "__main__":
    sys.exit(main())
