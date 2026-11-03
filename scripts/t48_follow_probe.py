#!/usr/bin/env python3
"""T48-AV-R3 probe — where, if anywhere, does 9.11.19 publish "I follow this thread"?

The T48 build note (§F3) measured that no surface carries an ``is_following`` key. This script
measures the **only** server-side follow answer that exists, so the client's read can be grounded in
a line of output instead of a claim:

  A. create a root + one reply as the second fixture account (the root then has a thread);
  B. before anything is followed, ask every surface that could answer:
        GET /channels/{cid}/posts          root row keys
        GET /posts/{root}                  keys
        GET /users/me/teams/{tid}/threads/{root}     status + keys   <-- CRT endpoint
        GET /users/me/teams/{tid}/threads            membership
  C. follow it (PUT …/threads/{root}/following → 200) and ask again;
  D. unfollow it (DELETE …/threads/{root}/following → 200) and ask again.

The answer this probe is looking for: the CRT endpoint answers **200 while followed and 404 once
not**, and the team threads list contains the thread only while followed. The client's
``PostOptionsServing.isFollowing`` is built on exactly that (200 ⇒ following).

Prints one line per measurement and a JSON block at the end. No password is printed.

    python3 scripts/t48_follow_probe.py
"""
from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request

BASE = os.environ.get("MM_PROBE_SERVER", "http://127.0.0.1:8065")
LOGIN = os.environ.get("MM_PROBE_LOGIN", "perfprobe")
PASSWORD = os.environ.get("MM_PROBE_PASSWORD", "PerfProbe-Not-A-Real-Secret-1")
SECOND_LOGIN = os.environ.get("MM_PROBE_SECOND_LOGIN", "t36reply")
SECOND_PASSWORD = os.environ.get("MM_PROBE_SECOND_PASSWORD", "T36Reply-Not-A-Real-Secret-1")
TEAM = "perf"
CHANNEL = "t36-threads"

results: dict[str, object] = {}


def call(method: str, path: str, token: str | None = None, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + "/api/v4" + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read()
            answer = json.loads(raw) if raw else None
            if path == "/users/login":
                return r.status, answer, r.headers.get("Token", "")
            return r.status, answer, ""
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            parsed = json.loads(raw)
        except Exception:  # noqa: BLE001
            parsed = raw.decode(errors="replace")
        return e.code, parsed, ""


def login(login_id: str, password: str) -> tuple[str, str]:
    status, answer, header_token = call("POST", "/users/login",
                                        body={"login_id": login_id, "password": password})
    token = answer.get("token") or header_token
    print(f"[login] {login_id}: HTTP {status}")
    if status != 200 or not token:
        raise SystemExit(f"cannot sign in as {login_id}")
    return token, answer["id"]


def record(name: str, value) -> None:
    results[name] = value
    print(f"[{name}] {json.dumps(value, sort_keys=True)}")


def surfaces(token: str, tid: str, cid: str, root_id: str) -> dict:
    """Every surface that could carry a follow answer, read without following anything."""
    out: dict[str, object] = {}

    _, page, _ = call("GET", f"/channels/{cid}/posts?page=0&per_page=60", token)
    row = ((page or {}).get("posts") or {}).get(root_id, {})
    out["channel_page_root"] = {"has_is_following": "is_following" in row,
                                "keys": sorted(row.keys())}

    _, post, _ = call("GET", f"/posts/{root_id}", token)
    out["get_post"] = {"has_is_following": isinstance(post, dict) and "is_following" in post}

    status, thread, _ = call("GET", f"/users/me/teams/{tid}/threads/{root_id}", token)
    out["thread_endpoint"] = {"http": status,
                              "has_is_following": isinstance(thread, dict)
                              and "is_following" in thread,
                              "keys": sorted(thread.keys()) if isinstance(thread, dict) else []}

    status, listing, _ = call("GET", f"/users/me/teams/{tid}/threads"
                                     "?page=0&per_page=60&extended=true", token)
    ids = [t.get("id") for t in (listing or {}).get("threads") or []]
    out["threads_list"] = {"http": status, "found": root_id in ids, "total": len(ids)}
    return out


def main() -> int:
    token, uid = login(LOGIN, PASSWORD)
    token2, _uid2 = login(SECOND_LOGIN, SECOND_PASSWORD)

    _, teams, _ = call("GET", "/users/me/teams", token)
    team = next(t for t in teams if t["name"] == TEAM)
    tid = team["id"]
    _, channel, _ = call("GET", f"/teams/{tid}/channels/name/{CHANNEL}", token)
    cid = channel["id"]

    stamp = int(time.time())
    _, root, _ = call("POST", "/posts", token2,
                      {"channel_id": cid, "message": f"t48r3 follow root {stamp}"})
    root_id = root["id"]
    call("POST", "/posts", token2,
         {"channel_id": cid, "root_id": root_id, "message": f"t48r3 follow reply {stamp}"})
    record("fixture", {"team": TEAM, "team_id": tid, "channel": CHANNEL, "channel_id": cid,
                       "viewer": LOGIN, "viewer_id": uid, "root": root_id})

    # A. never followed
    for label in ("never_followed",):
        record(label, surfaces(token, tid, cid, root_id))

    # B. follow — and ask again
    status, answer, _ = call("PUT", f"/users/me/teams/{tid}/threads/{root_id}/following",
                             token, {"state": True})
    record("follow_write", {"http": status, "answer": answer})
    after_follow = surfaces(token, tid, cid, root_id)
    record("after_follow", after_follow)

    # C. unfollow — the same read must go back
    status, answer, _ = call("DELETE", f"/users/me/teams/{tid}/threads/{root_id}/following", token)
    record("unfollow_write", {"http": status, "answer": answer})
    after_unfollow = surfaces(token, tid, cid, root_id)
    record("after_unfollow", after_unfollow)

    # D. the second account (the root's author, a real "another client") looks at the same thread
    record("other_account_after_unfollow", surfaces(token2, tid, cid, root_id))

    verdict = {
        "thread_endpoint_answers": {
            "never_followed": results["never_followed"]["thread_endpoint"]["http"],
            "after_follow": after_follow["thread_endpoint"]["http"],
            "after_unfollow": after_unfollow["thread_endpoint"]["http"]},
        "threads_list_membership": {
            "never_followed": results["never_followed"]["threads_list"]["found"],
            "after_follow": after_follow["threads_list"]["found"],
            "after_unfollow": after_unfollow["threads_list"]["found"]},
        "is_following_key_anywhere": any(
            results[label]["channel_page_root"]["has_is_following"]
            or results[label]["get_post"]["has_is_following"]
            or results[label]["thread_endpoint"]["has_is_following"]
            for label in ("never_followed", "after_follow", "after_unfollow")),
    }
    record("verdict", verdict)
    print(json.dumps(results, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
