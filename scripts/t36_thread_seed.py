#!/usr/bin/env python3
"""Seed the channel the T36 thread suite reads and writes in.

Why its own channel: the thread suite *replies* (that is the surface under test), so it needs a
channel no other card's assertions depend on. `t34-showcase`, `perf-feed` and `t35-composer` stay
untouched.

What it creates (idempotent — re-running only fills in what is missing):

    team     perf                  (reused; `scripts/perf_seed.py` makes it)
    user     perfprobe             (the local throwaway probe account, reused)
    user     t36reply              (a second author, so a participant stack has two people and an
                                    unread reply is possible at all)
    channel  t36-threads           (type O, both users are members)
    post     the main chain        root (t36reply) + 3 replies (perfprobe, t36reply, perfprobe)
    post     65 paged threads      root (t36reply) + 1 reply (perfprobe) each, so
                                   `/users/me/teams/{team}/threads` has more than one 60-row page.
                                   Only the *reply* author follows a thread: that is why the reply is
                                   perfprobe's, not the root's.

The unread thread the suite asserts on is created by the test run itself (a fresh reply from
`t36reply` after the app last read), so a re-run does not inherit a read state.

Nothing here touches a real workspace: the server is the local throwaway at 127.0.0.1:8065 and the
credentials are the ones this repo already publishes for it.

Usage:
    python3 scripts/t36_thread_seed.py --url http://127.0.0.1:8065
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request

USERNAME = "perfprobe"
EMAIL = "perfprobe@example.invalid"
PASSWORD = "PerfProbe-Not-A-Real-Secret-1"

SECOND_USERNAME = "t36reply"
SECOND_EMAIL = "t36reply@example.invalid"
SECOND_PASSWORD = "T36Reply-Not-A-Real-Secret-1"

TEAM_NAME = "perf"
CHANNEL_NAME = "t36-threads"
CHANNEL_DISPLAY = "T36 Threads"

MAIN_ROOT = "T36 main thread — the root of the chain."
MAIN_REPLIES = [
    "T36 main reply 1 — the first answer, by the probe account.",
    "T36 main reply 2 — the second answer, by the other author (the avatar stack's second face).",
    "T36 main reply 3 — the newest answer, so the chain has an order to check.",
]
PAGED_COUNT = 65
PAGED_ROOT = "T36 paged thread {index:02d} — one of many followed threads."
PAGED_REPLY = "T36 paged reply {index:02d} — the reply that makes this thread followed."


class APIError(RuntimeError):
    pass


class Client:
    def __init__(self, base: str, token: str | None = None):
        self.base = base.rstrip("/")
        self.token = token

    def call(self, method: str, path: str, body: dict | None = None):
        url = f"{self.base}/api/v4{path}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Content-Type", "application/json")
        req.add_header("X-Requested-With", "XMLHttpRequest")
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
                headers = {k.lower(): v for k, v in resp.headers.items()}
                return resp.status, (json.loads(raw) if raw.strip() else None), headers
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            try:
                payload = json.loads(raw)
            except Exception:
                payload = {"raw": raw.decode(errors="replace")}
            return exc.code, payload, {k.lower(): v for k, v in exc.headers.items()}

    def must(self, method: str, path: str, body: dict | None = None):
        status, payload, _ = self.call(method, path, body)
        if status >= 300:
            raise APIError(f"{method} {path} -> {status}: {json.dumps(payload)[:400]}")
        return payload


def login(base: str, email: str, password: str) -> tuple[str, str]:
    anon = Client(base)
    status, payload, headers = anon.call("POST", "/users/login",
                                         {"login_id": email, "password": password})
    if status != 200 or not headers.get("token"):
        raise APIError(f"could not sign in as {email}: {status} {payload}\n"
                       "run scripts/perf_seed.py first (it creates the probe account)")
    me = Client(base, headers["token"]).must("GET", "/users/me")
    return headers["token"], me["id"]


def ensure_second_user(admin: Client, team_id: str) -> str:
    status, payload, _ = admin.call("GET", f"/users/username/{SECOND_USERNAME}")
    if status == 200 and isinstance(payload, dict):
        return payload["id"]
    created = admin.must("POST", "/users", {
        "email": SECOND_EMAIL,
        "username": SECOND_USERNAME,
        "password": SECOND_PASSWORD,
        "first_name": "T36",
        "last_name": "Reply",
    })
    try:
        admin.must("POST", f"/teams/{team_id}/members", {"team_id": team_id,
                                                         "user_id": created["id"]})
    except APIError:
        pass  # already a member
    return created["id"]


def ensure_team(client: Client) -> str:
    teams = client.must("GET", "/users/me/teams") or []
    for team in teams:
        if team.get("name") == TEAM_NAME:
            return team["id"]
    team = client.must("POST", "/teams", {"name": TEAM_NAME, "display_name": "Perf", "type": "O"})
    return team["id"]


def ensure_channel(client: Client, team_id: str) -> dict:
    status, payload, _ = client.call("GET", f"/teams/{team_id}/channels/name/{CHANNEL_NAME}")
    if status == 200 and isinstance(payload, dict):
        return payload
    return client.must("POST", "/channels", {
        "team_id": team_id,
        "name": CHANNEL_NAME,
        "display_name": CHANNEL_DISPLAY,
        "type": "O",
        "purpose": "T36 thread surface: the suite opens threads, replies, follows and reads unread.",
        "header": "T36 — native threads",
    })


def add_member(admin: Client, channel_id: str, user_id: str) -> None:
    status, _, _ = admin.call("POST", f"/channels/{channel_id}/members",
                              {"user_id": user_id})
    if status >= 300:
        raise APIError(f"could not add {user_id} to {channel_id}: {status}")


def existing_messages(admin: Client, channel_id: str) -> set[str]:
    """Every message already in the channel, one page of roots (the fixture is roots-only)."""
    page = admin.must("GET", f"/channels/{channel_id}/posts?per_page=200&collapsedThreads=true")
    posts = (page or {}).get("posts") or {}
    return {post.get("message", "") for post in posts.values() if not post.get("delete_at")}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    args = parser.parse_args()

    admin_token, admin_id = login(args.url, EMAIL, PASSWORD)
    admin = Client(args.url, admin_token)
    if not _user_exists(admin):
        ensure_second_user(admin, ensure_team(admin))
    second_token, second_id = login(args.url, SECOND_EMAIL, SECOND_PASSWORD)
    author = Client(args.url, second_token)

    team_id = ensure_team(admin)
    channel = ensure_channel(admin, team_id)
    channel_id = channel["id"]
    add_member(admin, channel_id, admin_id)
    add_member(admin, channel_id, second_id)

    present = existing_messages(admin, channel_id)

    def post(client: Client, message: str, root_id: str | None = None) -> str:
        body = {"channel_id": channel_id, "message": message}
        if root_id:
            body["root_id"] = root_id
        return client.must("POST", "/posts", body)["id"]

    created: dict[str, str] = {}
    paged_created = 0
    for index in range(1, PAGED_COUNT + 1):
        message = PAGED_ROOT.format(index=index)
        if message in present:
            continue
        paged_root = post(author, message)
        post(admin, PAGED_REPLY.format(index=index), paged_root)
        paged_created += 1

    # The main chain is created **last** on purpose: the channel page is newest-first and a reader
    # (or the suite) finds the chain without paging past the 65 paged roots.
    if MAIN_ROOT not in present:
        root_id = post(author, MAIN_ROOT)
        created["main_root"] = root_id
        # Alternating authors: the fixture's participant stack has two people and the thread has a
        # reply the app did not make.
        for index, message in enumerate(MAIN_REPLIES):
            client = admin if index % 2 == 0 else author
            post(client, message, root_id)
    else:
        root_id = _root_id_for(admin, channel_id, MAIN_ROOT)
        created["main_root"] = root_id

    threads = admin.must("GET", f"/users/me/teams/{team_id}/threads?per_page=200&extended=true")
    print(json.dumps({
        "server": args.url,
        "username": USERNAME,
        "user_id": admin_id,
        "second_user": SECOND_USERNAME,
        "second_user_id": second_id,
        "team_id": team_id,
        "channel_id": channel_id,
        "channel_name": channel["name"],
        "main_root_id": root_id,
        "main_root_created": "main_root" in created,
        "paged_threads_created": paged_created,
        "followed_threads": len((threads or {}).get("threads") or []),
    }, indent=2))
    return 0


def _user_exists(admin: Client) -> bool:
    status, _, _ = admin.call("GET", f"/users/username/{SECOND_USERNAME}")
    return status == 200


def _root_id_for(admin: Client, channel_id: str, message: str) -> str:
    page = admin.must("GET", f"/channels/{channel_id}/posts?per_page=200&collapsedThreads=true")
    for post in ((page or {}).get("posts") or {}).values():
        if post.get("message") == message and not post.get("delete_at"):
            return post["id"]
    raise APIError("the root post vanished between the check and the lookup")


if __name__ == "__main__":
    sys.exit(main())
