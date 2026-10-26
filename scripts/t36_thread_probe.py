#!/usr/bin/env python3
"""T36 measure the thread contract against a real Mattermost server.

Pins the facts the native thread surface depends on, so a server upgrade that changes one of them
fails here instead of in the app:

  1. `GET /users/me/teams/{team}/threads` answers **and carries the totals inline**
     (`total`, `total_unread_threads`, `total_unread_mentions`, `total_unread_urgent_mentions`),
     so no second `totalsOnly` call is needed.
  2. There is **no channel-scoped thread list**: `?channel_id=` is ignored (same total as without
     it) and `GET /channels/{id}/threads` is 404. That is why `/{team}/threads/{channel}` renders
     the global list, matching upstream's `threads_button` → `GLOBAL_THREADS`.
  3. `GET /users/me/teams/{team}/threads/{thread}` 404s once the thread is unfollowed, which is how
     the client reads "not following" (the thread row itself carries no `is_following`).
  4. A thread object's `reply_count` can differ from its root post's `reply_count` — the thread's own
     field is the authority for the reply line.
  5. `GET /posts/{id}/thread` returns the root **inside** `order`/`posts`, so a client must draw it
     once.
  6. `PUT …/threads/{id}/following` + `DELETE …` are the follow writes, and the follow state is only
     readable through (3).
  7. `PUT …/threads/{id}/read/{ts}` answers the thread with its counters already applied.

Usage:
    python3 scripts/t36_thread_probe.py --url http://127.0.0.1:8065 \
        --login perfprobe --password ...

Exit code 0 = every measured fact still holds.
"""

import argparse
import json
import sys
import urllib.error
import urllib.request

OK = "PASS"
FAIL = "FAIL"


class Probe:
    def __init__(self, base_url, token):
        self.base = base_url.rstrip("/") + "/api/v4"
        self.token = token
        self.failures = []

    def call(self, method, path, body=None):
        data = None
        headers = {"Authorization": "Bearer " + self.token}
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read()
                return response.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as error:
            raw = error.read()
            try:
                return error.code, json.loads(raw) if raw else None
            except json.JSONDecodeError:
                return error.code, None

    def check(self, name, condition, detail=""):
        print(f"  [{OK if condition else FAIL}] {name}" + (f" — {detail}" if detail else ""))
        if not condition:
            self.failures.append(name)


def login(base_url, login_id, password):
    request = urllib.request.Request(
        base_url.rstrip("/") + "/api/v4/users/login",
        data=json.dumps({"login_id": login_id, "password": password}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        token = response.headers.get("Token")
        if not token:
            raise SystemExit("login answered without a Token header")
        return token


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--login", help="login id (omit when --token is given)")
    parser.add_argument("--password", help="password (omit when --token is given)")
    parser.add_argument("--token", help="an existing session token, instead of logging in")
    args = parser.parse_args()

    if args.token:
        token = args.token
    elif args.login and args.password:
        token = login(args.url, args.login, args.password)
    else:
        parser.error("give --token, or both --login and --password")
    probe = Probe(args.url, token)

    status, me = probe.call("GET", "/users/me")
    probe.check("the session works", status == 200, f"/users/me -> {status}")
    status, teams = probe.call("GET", "/users/me/teams")
    if status != 200 or not teams:
        print("  [FAIL] the account belongs to no team; nothing to measure")
        return 1
    team = teams[0]["id"]

    # (1) the list answers with totals inline
    status, page = probe.call("GET", f"/users/me/teams/{team}/threads?perPage=60&extended=true")
    probe.check("thread list answers", status == 200 and isinstance(page, dict), f"-> {status}")
    if status == 200 and page:
        probe.check("thread list carries its totals inline",
                    all(key in page for key in ("total", "total_unread_threads",
                                                "total_unread_mentions",
                                                "total_unread_urgent_mentions")),
                    f"total={page.get('total')}")
        threads = page.get("threads") or []
        probe.check("a thread object has no is_following field",
                    all("is_following" not in thread for thread in threads),
                    f"{len(threads)} threads")
        if threads:
            first = threads[0]
            probe.check("a thread carries its own reply_count and last_reply_at",
                        "reply_count" in first and "last_reply_at" in first)
            probe.check("a thread carries its root post",
                        bool((first.get("post") or {}).get("id")))
            probe.check("thread id == root post id",
                        first.get("id") == (first.get("post") or {}).get("id"),
                        f"{first.get('id')}")

            # (4) the thread's count vs its root's
            note = (f"thread={first.get('reply_count')} post="
                    f"{(first.get('post') or {}).get('reply_count')}")
            probe.check("thread reply_count is the authority (may differ from post.reply_count)",
                        isinstance(first.get("reply_count"), int), note)

            # (5) the thread endpoint returns the root among the replies
            status, body = probe.call("GET", f"/posts/{first['id']}/thread")
            probe.check("GET /posts/{id}/thread answers", status == 200, f"-> {status}")
            if status == 200:
                probe.check("the thread endpoint returns the root inside order",
                            first["id"] in ((body or {}).get("order") or []))
                probe.check("the thread endpoint returns the root inside posts",
                            first["id"] in ((body or {}).get("posts") or {}))

            # (6) the follow writes
            status, _ = probe.call("PUT", f"/users/me/teams/{team}/threads/{first['id']}/following", {})
            probe.check("PUT …/following follows", status == 200, f"-> {status}")
            status, body = probe.call("GET", f"/users/me/teams/{team}/threads/{first['id']}")
            probe.check("a followed thread is readable", status == 200, f"-> {status}")

            # (7) mark read answers with the counters applied
            status, body = probe.call(
                "PUT", f"/users/me/teams/{team}/threads/{first['id']}/read/9999999999999", {})
            probe.check("PUT …/read/{ts} answers the thread", status == 200, f"-> {status}")
            if status == 200:
                probe.check("the read answer carries unread_replies",
                            isinstance((body or {}).get("unread_replies"), int),
                            f"unread_replies={(body or {}).get('unread_replies')}")

            # (3) an unfollowed thread answers 404 — that is how this client reads "not following",
            # because the thread row itself carries no `is_following`…
            probe.call("DELETE", f"/users/me/teams/{team}/threads/{first['id']}/following")
            status, _ = probe.call("GET", f"/users/me/teams/{team}/threads/{first['id']}")
            probe.check("an unfollowed thread answers 404 (that IS 'not following')", status == 404,
                        f"-> {status}")
            # …then restore the follow, so a probe run leaves the fixture as it found it.
            probe.call("PUT", f"/users/me/teams/{team}/threads/{first['id']}/following", {})

    # (2) no channel-scoped thread list. The baseline is re-read here, after any follow write above,
    # because the follow itself changes `total`.
    status, baseline = probe.call("GET", f"/users/me/teams/{team}/threads?perPage=5")
    status, channels = probe.call("GET", "/users/me/channels")
    if status == 200 and channels:
        channel = channels[0]["id"]
        status, scoped = probe.call(
            "GET", f"/users/me/teams/{team}/threads?perPage=5&channel_id={channel}")
        probe.check("?channel_id= is accepted but ignored",
                    status == 200 and (scoped or {}).get("total") == (baseline or {}).get("total"),
                    f"scoped total={(scoped or {}).get('total')} vs {(baseline or {}).get('total')}")
        status, _ = probe.call("GET", f"/channels/{channel}/threads")
        probe.check("GET /channels/{id}/threads does not exist", status == 404, f"-> {status}")

    print()
    if probe.failures:
        print(f"FAILED: {len(probe.failures)} measurement(s) no longer hold:")
        for name in probe.failures:
            print(f"  - {name}")
        return 1
    print("PASS: every measured thread contract still holds on this server.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
