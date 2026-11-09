#!/usr/bin/env python3
"""Seed the throwaway workspace the product-demo capture films (T74).

Why a dedicated fixture instead of `scripts/perf_seed.py`: the perf fixture is built to
stress the client (hundreds of channels, a 5 000 pt sidebar, 180 posts) and its
conversation is measurement prose. A README demo needs the opposite - a small, calm
workspace whose sidebar fits on one screen and whose conversation reads like a real
product team - plus an unread state, because the story's second beat is "the sidebar
with unread". Both live on the same throwaway server (`127.0.0.1:8065`); this script
never touches the `perf` team.

What it creates (idempotent; re-running rebuilds the conversation from scratch):

    user     robin          - the account the demo signs in as
    users    ava, jordan, riley - synthetic teammates, the conversation's authors
    team     demo / "Northwind Studio"
    channels Town Square (the team default), Announcements, Design review, Engineering
    posts    ~18 posts, one root with three replies in Design review, one @robin mention
             in Announcements; everything is synthetic and names no real person or server

Unread state: robin joins before anything is posted, then #Engineering is marked read for
him, so the sidebar opens with unread on #Announcements and #Design review and a quiet
#Engineering. The launch's town-square landing marks itself read. #Announcements sorts
above #Design review so both unread rows are above the sidebar's fold — the sidebar also
lists the workspace menu and the web app's product entries, and the two channels the take
needs have to be visible without scrolling.

Credentials are fixed throwaway strings on a local Docker server (the same convention as
`scripts/perf_seed.py`) and are written to a 0600 file outside the repository.

Usage:
    python3 scripts/demo_seed.py --url http://127.0.0.1:8065 \
        --creds-out build/demo/fixture.json [--keep-existing]

`--keep-existing` skips the post reset (which is what makes a re-shot video show the
same conversation instead of a pile-up of earlier replies).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

ADMIN_USERNAME = "perfprobe"
ADMIN_PASSWORD = "PerfProbe-Not-A-Real-Secret-1"

TEAM_NAME = "demo"
TEAM_DISPLAY = "Northwind Studio"

READER = {"username": "robin", "password": "Demo-Reader-Not-A-Real-Secret-1",
          "first_name": "Robin", "last_name": "Hale"}
AUTHORS = [
    {"username": "ava", "password": "Demo-Ava-Not-A-Real-Secret-1",
     "first_name": "Ava", "last_name": "Lindqvist"},
    {"username": "jordan", "password": "Demo-Jordan-Not-A-Real-Secret-1",
     "first_name": "Jordan", "last_name": "Okafor"},
    {"username": "riley", "password": "Demo-Riley-Not-A-Real-Secret-1",
     "first_name": "Riley", "last_name": "Tanaka"},
]
PEOPLE = [READER] + AUTHORS


def email_for(username: str) -> str:
    return f"{username}@example.invalid"


CHANNELS = [
    # (name, display name, seeded-if-missing)
    ("town-square", "Town Square", True),
    ("design-review", "Design review", True),
    ("announcements", "Announcements", True),
    ("engineering", "Engineering", True),
]

# The conversation, oldest first. `None` in the author slot means "the root's replies".
# Every line is synthetic; no real person, meeting, or server is named.
CONVERSATION = {
    "town-square": [
        ("ava", "Welcome to Northwind Studio."),
        ("jordan", "Design review notes live in #Design review."),
        ("riley", "Announcements live in #Announcements."),
    ],
    "design-review": [
        ("ava", "Design review is at 15:30 today. Notes are in the shared doc."),
        ("jordan", "Pushed the new spacing scale to the branch."),
        ("riley", "The dark palette feels much warmer now."),
        ("ava", "Let's keep the accent under ten percent of the screen."),
        ("jordan", "Agreed. The accent should only mark the active state."),
        ("riley", "Three-panel layout is in the spec now."),
        ("ava", "The sidebar spacing matches the rest of the app."),
        ("jordan", "One more pass on the type scale and we're done."),
    ],
    "announcements": [
        ("riley", "2.0 scope is frozen as of today."),
        ("jordan", "Build 42 is on the internal channel."),
    ],
    "engineering": [
        ("jordan", "CI is green on main."),
        ("ava", "Flaky test fixed: the reconnect backoff case."),
    ],
}

# Posted **after** the reader's read state has been advanced on every channel, so the unread
# state the sidebar opens with is exactly these messages and nothing else. The @robin line is
# the sidebar's one numeric badge; the other channel shows the plain unread dot.
TAIL = {
    "design-review": [
        ("ava", "The accent tokens are updated."),
        ("jordan", "Pushed the new icons to the branch."),
    ],
    "announcements": [
        ("ava", "@robin could you review the release notes before Friday?"),
    ],
}

# The thread the demo opens (in Design review) and the posts that follow it in the
# channel, so the "N replies" affordance sits near the bottom of the timeline where the
# pane opens.
THREAD = {
    "channel": "design-review",
    "root_author": "riley",
    "root": "**Accent colour for 2.0**: I'm leaning toward a warmer indigo. Thoughts?",
    "replies": [
        ("ava", "Warmer indigo reads better against the dark palette."),
        ("jordan", "It also matches the icon set we already ship."),
        ("riley", "Settled then: indigo for 2.0."),
    ],
    "after": [
        ("ava", "I'll update the design tokens this afternoon."),
        ("jordan", "Release notes are drafted. One line still open."),
    ],
}


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
        # Mattermost refuses JSON responses to API clients without this header.
        req.add_header("X-Requested-With", "XMLHttpRequest")
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
                return resp.status, (json.loads(raw) if raw.strip() else None), \
                    {k.lower(): v for k, v in resp.headers.items()}
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

    def optional(self, method: str, path: str, body: dict | None = None):
        """Call, returning (status, payload) for expected-to-fail probes (404, 400)."""
        status, payload, _ = self.call(method, path, body)
        return status, payload


def login(base: str, login_id: str, password: str) -> str:
    anon = Client(base)
    status, payload, headers = anon.call("POST", "/users/login",
                                         {"login_id": login_id, "password": password})
    if status != 200 or not headers.get("token"):
        raise APIError(f"login as {login_id} failed: {status} {payload}")
    return headers["token"]


def admin_token(base: str) -> str:
    try:
        return login(base, ADMIN_USERNAME, ADMIN_PASSWORD)
    except APIError as exc:
        raise SystemExit(f"{exc}\nthe throwaway server must have {ADMIN_USERNAME} "
                         f"(scripts/perf_seed.py creates it)") from exc


def ensure_user(c: Client, spec: dict) -> dict:
    status, payload = c.optional("GET", f"/users/username/{spec['username']}")
    if status == 200:
        user = payload
    else:
        # `POST /users` carries no password for an existing account, so a 400 here means
        # "exists, but the lookup above raced" - re-read rather than fail.
        status, payload = c.optional("POST", "/users", {
            "email": email_for(spec["username"]),
            "username": spec["username"],
            "password": spec["password"],
            "first_name": spec["first_name"],
            "last_name": spec["last_name"],
        })
        if status >= 300:
            status, payload = c.optional("GET", f"/users/username/{spec['username']}")
            if status != 200:
                raise APIError(f"cannot create or find {spec['username']}: {payload}")
        user = payload
    return user


def ensure_password(base: str, admin: Client, spec: dict, user: dict) -> None:
    """Make the fixed throwaway password true, resetting it through the admin API if not.

    A re-run on a server whose account survived an earlier experiment must not fail at
    the final `login as robin`; the reset is admin-only and never touches the `perf`
    account the other suites use.
    """
    try:
        login(base, spec["username"], spec["password"])
        return
    except APIError:
        pass
    status, payload = admin.optional("PUT", f"/users/{user['id']}/password",
                                      {"new_password": spec["password"]})
    if status >= 300:
        raise APIError(f"cannot reset password for {spec['username']}: {status} {payload}")
    login(base, spec["username"], spec["password"])


def ensure_team(c: Client, name: str, display: str) -> dict:
    status, payload = c.optional("GET", f"/teams/name/{name}")
    if status == 200:
        return payload
    return c.must("POST", "/teams", {"name": name, "display_name": display, "type": "O"})


def ensure_channel(c: Client, team_id: str, name: str, display: str) -> dict:
    status, payload = c.optional("GET", f"/teams/{team_id}/channels/name/{name}")
    if status == 200:
        return payload
    return c.must("POST", "/channels", {"team_id": team_id, "name": name,
                                        "display_name": display, "type": "O"})


def add_team_member(c: Client, team_id: str, user_id: str) -> None:
    status, payload = c.optional("POST", f"/teams/{team_id}/members",
                                 {"team_id": team_id, "user_id": user_id})
    if status >= 300 and "already" not in json.dumps(payload).lower():
        # A team join can also be refused because the user is deactivated; that is fatal.
        raise APIError(f"add team member {user_id} -> {status}: {payload}")


def add_channel_member(c: Client, channel_id: str, user_id: str) -> None:
    status, payload = c.optional("POST", f"/channels/{channel_id}/members",
                                 {"user_id": user_id})
    if status >= 300:
        # 400 with "already" is the idempotent case; anything else is a real failure.
        if "already" not in json.dumps(payload).lower():
            raise APIError(f"add channel member {user_id} -> {status}: {payload}")


def post_ids(c: Client, channel_id: str) -> list[str]:
    """Every post id in the channel, replies first (a root can be deleted before them)."""
    ids: list[str] = []
    page = 0
    while True:
        status, payload = c.optional(
            "GET", f"/channels/{channel_id}/posts?page={page}&per_page=200")
        if status != 200 or not isinstance(payload, dict):
            return ids
        order = payload.get("order") or []
        ids.extend(order)
        if not payload.get("has_next") or page > 20:
            return ids
        page += 1


def reset_posts(c: Client, channel_ids: dict[str, str]) -> int:
    """Delete every post in the demo channels, replies before roots.

    The channel page lists **roots only** (`/channels/{id}/posts` is the collapsed view),
    so a reply has to be reached through its root's thread; deleting just the page would
    leave the old reply chain behind and the re-shot video would show it again.
    """
    removed = 0
    for channel_id in channel_ids.values():
        roots = post_ids(c, channel_id)
        victims: list[str] = []
        for root in roots:
            status, thread = c.optional("GET", f"/posts/{root}/thread")
            if status == 200 and isinstance(thread, dict):
                order = thread.get("order") or []
                victims.extend(reversed(order))  # replies first, the root last
            else:
                victims.append(root)
        for post_id in victims:
            status, _ = c.optional("DELETE", f"/posts/{post_id}")
            if status < 300:
                removed += 1
    return removed


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8065")
    ap.add_argument("--creds-out", required=True)
    ap.add_argument("--env-out", default="",
                    help="write a shell-sourceable TEST_RUNNER_MM_* env file (default: <creds>.env)")
    ap.add_argument("--keep-existing", action="store_true",
                    help="do not delete the conversation before re-seeding")
    args = ap.parse_args()

    base = args.url.rstrip("/")
    admin = Client(base, admin_token(base))
    me = admin.must("GET", "/users/me")

    users = {spec["username"]: ensure_user(admin, spec) for spec in PEOPLE}
    for spec in PEOPLE:
        ensure_password(base, admin, spec, users[spec["username"]])
    team = ensure_team(admin, TEAM_NAME, TEAM_DISPLAY)
    team_id = team["id"]

    channels: dict[str, dict] = {}
    for name, display, _ in CHANNELS:
        channels[name] = ensure_channel(admin, team_id, name, display)

    # Prune anything else this script once created under an older name (e.g. a channel
    # renamed in the fixture), so a re-shot demo cannot show a stale conversation in the
    # sidebar. Only this script's own team is touched; the server's other teams are not.
    keep = {name for name, _, _ in CHANNELS} | {"off-topic"}
    status, team_channels = admin.optional("GET", f"/teams/{team_id}/channels?per_page=200")
    if status == 200 and isinstance(team_channels, list):
        for channel in team_channels:
            if channel.get("name") not in keep:
                pruned = admin.optional("DELETE", f"/channels/{channel['id']}")
                print(f"pruned channel #{channel.get('name')} -> {pruned[0]}")

    # Membership first: a post made before the reader joins is already "read", and an
    # unread state is what the sidebar beat needs.
    for spec in PEOPLE:
        add_team_member(admin, team_id, users[spec["username"]]["id"])
    for channel in channels.values():
        for spec in PEOPLE:
            add_channel_member(admin, channel["id"], users[spec["username"]]["id"])
    add_channel_member(admin, channels["town-square"]["id"], me["id"])

    channel_ids = {name: channel["id"] for name, channel in channels.items()}
    if not args.keep_existing:
        removed = reset_posts(admin, channel_ids)
        print(f"reset: deleted {removed} earlier post(s)")

    author_clients: dict[str, Client] = {}

    def say(channel_name: str, author: str, message: str, root_id: str | None = None) -> dict:
        body = {"channel_id": channel_ids[channel_name],
                "message": message}
        if root_id:
            body["root_id"] = root_id
        # Authors post as themselves so the timeline shows more than one face.
        if author not in author_clients:
            password = next(p["password"] for p in PEOPLE if p["username"] == author)
            author_clients[author] = Client(base, login(base, author, password))
        post = author_clients[author].must("POST", "/posts", body)
        return post

    for channel_name, lines in CONVERSATION.items():
        for author, message in lines:
            say(channel_name, author, message)

    thread_channel = THREAD["channel"]
    root = say(thread_channel, THREAD["root_author"], THREAD["root"])
    reply_ids = [say(thread_channel, author, message, root_id=root["id"])["id"]
                 for author, message in THREAD["replies"]]
    for author, message in THREAD["after"]:
        say(thread_channel, author, message)

    # Read state is a property of the **reader**, so it is advanced as him rather than poked
    # through the admin API: `POST /channels/members/{user_id}/view` with `{channel_id}` is
    # the endpoint that moves it (measured on 9.11.19; the `/channels/{id}/members/{uid}/view`
    # shape is a 404). Everything seeded above is therefore "read", and only the tail posts
    # below are unread when the capture launches.
    reader = Client(base, login(base, READER["username"], READER["password"]))
    # A server can require custom terms of service (this fixture does — T49's). A reader
    # accepts them once; the seed does the same, or the capture would open on the ToS gate
    # instead of the workspace. `termsOfServiceId` is camelCase here and the boolean is
    # `accepted` (both measured on 9.11.19).
    status, tos = reader.optional("GET", "/terms_of_service")
    if status == 200 and isinstance(tos, dict) and tos.get("id"):
        profile = reader.must("GET", "/users/me")
        if profile.get("terms_of_service_id") != tos["id"]:
            reader.must("POST", f"/users/{users['robin']['id']}/terms_of_service",
                        {"termsOfServiceId": tos["id"], "accepted": True})
    for channel_id in channel_ids.values():
        reader.optional("POST", f"/channels/members/{users['robin']['id']}/view",
                        {"channel_id": channel_id})

    for channel_name, lines in TAIL.items():
        for author, message in lines:
            say(channel_name, author, message)

    token = login(base, READER["username"], READER["password"])
    creds = {
        "url": base,
        "login_id": READER["username"],
        "password": READER["password"],
        "token": token,
        "user_id": users[READER["username"]]["id"],
        "team_id": team_id,
        "team_name": TEAM_NAME,
        "team_display": TEAM_DISPLAY,
        "channels": channel_ids,
        "thread_channel_id": channel_ids[thread_channel],
        "thread_root_id": root["id"],
        "thread_reply_ids": reply_ids,
        "author_usernames": [p["username"] for p in AUTHORS],
    }
    out = os.path.abspath(os.path.expanduser(args.creds_out))
    os.makedirs(os.path.dirname(out), exist_ok=True)
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        json.dump(creds, fh, indent=2)
    print(json.dumps({k: creds[k] for k in ("url", "team_id", "login_id",
                                            "thread_channel_id", "thread_root_id")}))

    # A shell-sourceable env file, because `scripts/qa-test.py` hands the test process every
    # `TEST_RUNNER_`-prefixed variable and xcodebuild strips the prefix inside the runner.
    # 0600 like the creds file: it carries the throwaway password.
    env_path = os.path.abspath(os.path.expanduser(
        args.env_out or (out + ".env")))
    env_lines = [
        f'TEST_RUNNER_MM_AUTH_SERVER={creds["url"]}',
        f'TEST_RUNNER_MM_AUTH_LOGIN={creds["login_id"]}',
        f'TEST_RUNNER_MM_AUTH_PASSWORD={creds["password"]}',
        f'TEST_RUNNER_MM_DEMO_CHANNEL_ID={creds["thread_channel_id"]}',
        f'TEST_RUNNER_MM_DEMO_ROOT_ID={creds["thread_root_id"]}',
    ]
    fd = os.open(env_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write("\n".join(env_lines) + "\n")
    print(env_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
