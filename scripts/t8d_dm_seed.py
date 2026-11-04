#!/usr/bin/env python3
"""t8d_dm_seed.py - seed a throwaway Mattermost server with enough Direct messages that the
sidebar's page (20) and its "Load more" row exist.

Why this exists: `t_8d539b3f`'s live UI test needs a Direct messages group longer than one page.
The fixture server (`scripts/perf_seed.py`) is a throwaway one, and a DM is one channel per *pair*
of users - so N DMs means N other accounts. This script creates them (`t8duserNN`), opens the DM,
and posts one message per channel in **reverse** order, so the newest seeded DM is `t8duser01` and
the oldest is `t8duser<count>`; that gives the test a row it can prove was beyond the first page.

It writes the fixture it created - the server's own recency order, read back from `last_post_at` -
to a JSON file the UI test reads (`MM_DM_FIXTURE`):

    {"server": "http://127.0.0.1:8065", "count": 45, "newestFirst": [<channel id>, ...],
     "oldest": "<channel id>", "newest": "<channel id>"}

Usage (the local fixture server; see docs/quickstart.md):

    python3 scripts/t8d_dm_seed.py --count 45 --out build/logs/t8d-dm-fixture.json
    python3 scripts/t8d_dm_seed.py --cleanup          # remove every row this script made

Nothing here is a secret: the accounts exist only on a throwaway local server and the password is
this file's literal. Idempotent: re-running reuses the users and channels and only posts when a
channel is still empty, then rewrites the fixture from the server's own `last_post_at`.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request

DEFAULT_URL = "http://127.0.0.1:8065"
DEFAULT_LOGIN = "perfprobe"
DEFAULT_PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
SEED_PASSWORD = "T8dSeed-Not-A-Real-Secret-1"
USER_PREFIX = "t8duser"
DB_CONTAINER = "mm-perf-db"


class API:
    def __init__(self, base: str):
        self.base = base.rstrip("/")
        self.token: str | None = None
        self.user_id: str = ""

    def call(self, method: str, path: str, body=None):
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(f"{self.base}/api/v4{path}", data=data, method=method)
        request.add_header("Content-Type", "application/json")
        if self.token:
            request.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                raw = response.read()
                return response.status, (json.loads(raw) if raw else None), response.headers
        except urllib.error.HTTPError as error:
            raw = error.read()
            try:
                parsed = json.loads(raw) if raw else None
            except ValueError:
                parsed = raw.decode("utf-8", "replace")
            return error.code, parsed, error.headers

    def login(self, login: str, password: str) -> None:
        status, body, headers = self.call("POST", "/users/login",
                                          {"login_id": login, "password": password})
        if status != 200:
            raise SystemExit(f"login failed ({status}): {body}")
        self.token = headers.get("Token") or headers.get("token")
        self.user_id = body["id"]


def user_ids_by_username(api: API) -> dict[str, str]:
    """Every seeded account on the server, `username -> id`."""
    found: dict[str, str] = {}
    page = 0
    while True:
        status, users, _ = api.call("GET", f"/users?page={page}&per_page=200")
        if status != 200 or not users:
            break
        for user in users:
            if str(user.get("username", "")).startswith(USER_PREFIX):
                found[user["username"]] = user["id"]
        if len(users) < 200:
            break
        page += 1
    return found


def ensure_user(api: API, index: int) -> str:
    username = f"{USER_PREFIX}{index:02d}"
    status, found, _ = api.call("GET", f"/users/username/{username}")
    if status == 200 and isinstance(found, dict):
        return found["id"]
    status, created, _ = api.call("POST", "/users", {
        "email": f"{username}@example.invalid",
        "username": username,
        "password": SEED_PASSWORD,
        "first_name": "T8d",
        "last_name": f"User {index:02d}",
    })
    if status not in (200, 201) or not isinstance(created, dict):
        raise SystemExit(f"creating {username} failed ({status}): {created}")
    return created["id"]


def cleanup(api: API) -> None:
    """Delete every row this script made: its channels, posts, memberships, sessions and users.

    Deliberately scoped to `username LIKE 't8duser%'`: it cannot touch the fixture's own accounts
    or channels, and the DM channel's `name` is `<my id>__<their id>`, which is how a seeded DM is
    recognised.
    """
    match = ("u.username LIKE '" + USER_PREFIX + "%'")
    statements = [
        f"DELETE FROM posts WHERE channelid IN (SELECT c.id FROM channels c JOIN users u ON c.type = 'D' "
        f"AND c.name LIKE '%' || u.id || '%' WHERE {match})",
        f"DELETE FROM posts WHERE userid IN (SELECT id FROM users WHERE {match})",
        f"DELETE FROM channelmembers WHERE channelid IN (SELECT c.id FROM channels c JOIN users u ON c.type = 'D' "
        f"AND c.name LIKE '%' || u.id || '%' WHERE {match})",
        f"DELETE FROM channelmembers WHERE userid IN (SELECT id FROM users WHERE {match})",
        f"DELETE FROM channels WHERE id IN (SELECT c.id FROM channels c JOIN users u ON c.type = 'D' "
        f"AND c.name LIKE '%' || u.id || '%' WHERE {match})",
        f"DELETE FROM sessions WHERE userid IN (SELECT id FROM users WHERE {match})",
        f"DELETE FROM status WHERE userid IN (SELECT id FROM users WHERE {match})",
        f"DELETE FROM preferences WHERE userid IN (SELECT id FROM users WHERE {match})",
        f"DELETE FROM users WHERE {match}",
    ]
    sql = ";\n".join(statements) + ";"
    result = subprocess.run(
        ["docker", "exec", "-i", DB_CONTAINER, "psql", "-U", "mmuser", "-d", "mattermost", "-v",
         "ON_ERROR_STOP=1", "-c", sql],
        capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"cleanup failed:\n{result.stderr}")
    print(f"cleanup: {result.stdout.strip()}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default=DEFAULT_URL)
    parser.add_argument("--login", default=DEFAULT_LOGIN)
    parser.add_argument("--password", default=DEFAULT_PASSWORD)
    parser.add_argument("--count", type=int, default=45, help="how many DMs to guarantee")
    parser.add_argument("--out", default="build/logs/t8d-dm-fixture.json")
    parser.add_argument("--env-out", default="build/logs/t8d-dm-fixture.env",
                        help="shell snippet exporting TEST_RUNNER_MM_DM_COUNT / _OLDEST for "
                             "scripts/qa-test.py (a simulator test cannot read a host file path)")
    parser.add_argument("--pause", type=float, default=0.2,
                        help="seconds between posts, so recency order is distinct timestamps")
    parser.add_argument("--cleanup", action="store_true",
                        help="delete everything this script created and exit")
    args = parser.parse_args()

    api = API(args.url)
    api.login(args.login, args.password)
    if args.cleanup:
        cleanup(api)
        return 0

    # Oldest first: user N gets the oldest post, user 1 the newest.
    seeded: list[tuple[int, str, str]] = []  # (index, channel id, user id)
    for index in range(args.count, 0, -1):
        other = ensure_user(api, index)
        status, channel, _ = api.call("POST", "/channels/direct", [api.user_id, other])
        if status not in (200, 201) or not isinstance(channel, dict):
            raise SystemExit(f"opening the DM with {USER_PREFIX}{index:02d} failed ({status}): {channel}")
        seeded.append((index, channel["id"], other))

    for index, channel_id, _ in seeded:
        status, channel, _ = api.call("GET", f"/channels/{channel_id}")
        if status != 200 or not isinstance(channel, dict):
            raise SystemExit(f"reading channel {channel_id} failed ({status}): {channel}")
        if channel.get("total_msg_count", 0) > 0:
            continue
        status, post, _ = api.call("POST", "/posts", {
            "channel_id": channel_id,
            "message": f"t8d seed {index:02d}",
        })
        if status not in (200, 201):
            raise SystemExit(f"posting into {channel_id} failed ({status}): {post}")
        time.sleep(args.pause)

    # The fixture is the **server's** order, read back rather than assumed: the sidebar sorts by
    # `max(last_post_at, create_at)`, so this is the order the app will draw.
    channels = []
    for index, channel_id, _ in seeded:
        status, channel, _ = api.call("GET", f"/channels/{channel_id}")
        if status != 200 or not isinstance(channel, dict):
            raise SystemExit(f"reading channel {channel_id} failed ({status}): {channel}")
        channels.append((int(channel.get("last_post_at", 0)), channel_id))
    channels.sort(reverse=True)
    newest_first = [channel_id for _, channel_id in channels]

    fixture = {
        "server": args.url,
        "count": args.count,
        "newestFirst": newest_first,
        "newest": newest_first[0] if newest_first else None,
        "oldest": newest_first[-1] if newest_first else None,
    }
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(fixture, handle, indent=2)
        handle.write("\n")
    # The live UI test runs **inside the simulator**, which cannot read a host path: the two facts it
    # needs travel as environment variables (xcodebuild strips `TEST_RUNNER_` for the test process),
    # so this snippet is sourced before `scripts/qa-test.py`.
    with open(args.env_out, "w", encoding="utf-8") as handle:
        handle.write("export TEST_RUNNER_MM_DM_COUNT=%d\n" % args.count)
        handle.write("export TEST_RUNNER_MM_DM_OLDEST=%s\n" % (fixture["oldest"] or ""))
        handle.write("export TEST_RUNNER_MM_DM_NEWEST=%s\n" % (fixture["newest"] or ""))
    print(f"seeded {args.count} DM(s) for {args.login} on {args.url}")
    print(f"fixture: {args.out}")
    print(f"env:     {args.env_out}  (source it before scripts/qa-test.py)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
