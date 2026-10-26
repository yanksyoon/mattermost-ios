#!/usr/bin/env python3
"""Probe the reaction write contract on the pinned local Mattermost (9.11.19).

Why this exists: T37 sends reactions over REST and reconciles them against socket events, so the
exact shapes matter — the endpoints (which are **not** under `/posts/{id}/reactions`, see below), the
body an add accepts, whether a duplicate add is an error or a no-op, and what a remove needs to
identify *whose* reaction goes away. Guessing any of them would put a wrong assumption into the
client and a wrong oracle into the live suite.

Measured contract (this script is the measurement):

    POST   /api/v4/reactions                                  201 {id, user_id, post_id, emoji_name, create_at}
    GET    /api/v4/posts/{post_id}/reactions                  read-back list
    DELETE /api/v4/users/{user_id}/posts/{post_id}/reactions/{emoji_name}
    GET    /api/v4/posts/{post_id}                            `metadata.reactions` (the list the app derives from)

`POST /posts/{id}/reactions` answers **404 api.context.404.app_error** — that is the shape T37's card
wording ("`/api/v4/reactions`") is about, and the first version of this probe discovered it by trying.

It also seeds the `t37-reactions` channel the live UI test uses, idempotently.

Usage:
    python3 scripts/t37_reaction_probe.py --url http://127.0.0.1:8065
"""

from __future__ import annotations

import argparse
import json
import urllib.error
import urllib.request

USERNAME = "perfprobe"
PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
TEAM_NAME = "perf"
CHANNEL_NAME = "t37-reactions"
CHANNEL_DISPLAY = "T37 Reactions"


class Client:
    def __init__(self, base: str, token: str | None = None):
        self.base = base.rstrip("/")
        self.token = token
        # The most recent response's `Token` header (login answers the token there, not in the body).
        self.last_token: str | None = None

    def call(self, method: str, path: str, body=None):
        url = f"{self.base}/api/v4{path}"
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, method=method)
        request.add_header("Content-Type", "application/json")
        # `POST /users/login` answers a **token header** only when the call looks like an XHR;
        # otherwise it sets MMAUTHTOKEN cookies instead (measured on 9.11.19 during T36-R).
        request.add_header("X-Requested-With", "XMLHttpRequest")
        if self.token:
            request.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                self.last_token = response.headers.get("Token")
                raw = response.read()
                return response.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as error:
            raw = error.read()
            try:
                payload = json.loads(raw) if raw else None
            except ValueError:
                payload = raw.decode(errors="replace")
            return error.code, payload


def login(client: Client, login_id: str, password: str) -> Client:
    status, payload = client.call("POST", "/users/login",
                                 {"login_id": login_id, "password": password})
    if status != 200:
        raise SystemExit(f"login failed: {status} {payload}")
    token = client.last_token
    if not token:
        raise SystemExit("login answered 200 without a Token header")
    return Client(client.base, token)


def ensure_channel(client: Client) -> tuple[str, str]:
    status, teams = client.call("GET", "/users/me/teams")
    if status != 200:
        raise SystemExit(f"teams failed: {status} {teams}")
    team = next((t for t in teams if t["name"] == TEAM_NAME), None)
    if team is None:
        raise SystemExit(f"team #{TEAM_NAME} missing — run scripts/perf_seed.py")
    team_id = team["id"]
    status, payload = client.call("GET", f"/teams/{team_id}/channels/name/{CHANNEL_NAME}")
    if status == 200:
        return team_id, payload["id"]
    status, payload = client.call("POST", "/channels", {
        "team_id": team_id,
        "name": CHANNEL_NAME,
        "display_name": CHANNEL_DISPLAY,
        "type": "O",
    })
    if status not in (200, 201):
        raise SystemExit(f"create channel failed: {status} {payload}")
    return team_id, payload["id"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    args = parser.parse_args()

    client = login(Client(args.url), USERNAME, PASSWORD)
    status, me = client.call("GET", "/users/me")
    print(f"me: {status} {me['id']} {me['username']}")
    team_id, channel_id = ensure_channel(client)
    print(f"channel t37-reactions: {channel_id} (team {team_id})")

    # A post of our own to react to. A fresh one each run keeps the probe independent of history.
    status, post = client.call("POST", "/posts", {
        "channel_id": channel_id,
        "message": "T37 reaction probe",
    })
    if status not in (200, 201):
        raise SystemExit(f"post failed: {status} {post}")
    post_id = post["id"]
    print(f"post: {post_id}")

    def add(name: str):
        return client.call("POST", "/reactions",
                           {"user_id": me["id"], "post_id": post_id, "emoji_name": name})

    def remove(name: str):
        return client.call("DELETE", f"/users/{me['id']}/posts/{post_id}/reactions/{name}")

    def metadata():
        code, fresh = client.call("GET", f"/posts/{post_id}")
        return code, ((fresh or {}).get("metadata") or {}).get("reactions")

    def names():
        return [r["emoji_name"] for r in (metadata()[1] or [])]

    print("\n-- the path T37's card names, which does not exist --")
    code, payload = client.call("POST", f"/posts/{post_id}/reactions",
                                {"user_id": me["id"], "post_id": post_id, "emoji_name": "tada"})
    print(f"POST /posts/{{id}}/reactions -> {code} {(payload or {}).get('id')}")

    print("\n-- add: POST /reactions {user_id, post_id, emoji_name} --")
    code, payload = add("tada")
    print(f"status {code} body {payload}")
    print(f"post metadata.reactions -> {json.dumps(metadata()[1])}")

    print("\n-- duplicate add (same user, same emoji) --")
    code, payload = add("tada")
    print(f"status {code} body {payload}")
    print(f"metadata -> {json.dumps(metadata()[1])}")

    print("\n-- remove: DELETE /users/{uid}/posts/{pid}/reactions/{emoji} --")
    code, payload = remove("tada")
    print(f"status {code} body {payload}")
    print(f"metadata -> {names()}")

    print("\n-- remove a reaction that is not there --")
    code, payload = remove("tada")
    print(f"status {code} body {(payload or {}).get('id') if isinstance(payload, dict) else payload}")

    print("\n-- alias canonicalisation: add 'thumbsup', then '+1' --")
    add("thumbsup")
    print(f"after thumbsup -> {names()}")
    code, payload = add("+1")
    print(f"add +1 -> {code}")
    print(f"after +1 -> {names()}  (one reaction or two is the question)")
    # `+` is not a path-safe character: the app sends `%2B1`. Measured here so the client's
    # percent-encoding rule is not a guess.
    code, payload = remove("%2B1")
    print(f"DELETE .../reactions/%2B1 -> {code} {payload}")
    print(f"after deleting %2B1 -> {names()}  (did the alias go?)")
    remove("thumbsup")
    print(f"after deleting thumbsup -> {names()}")

    print("\n-- unknown shortcode --")
    code, payload = add("definitely_not_an_emoji_xyz")
    print(f"status {code} body {(payload or {}).get('id') if isinstance(payload, dict) else payload}")

    print("\n-- the custom emoji the fixture creates --")
    code, payload = client.call("GET", "/emoji?per_page=200")
    custom = [e["name"] for e in (payload or []) if e.get("delete_at", 0) == 0]
    print(f"custom emoji ({len(custom)}): {custom[:12]}")
    if custom:
        name = custom[0]
        code, payload = add(name)
        print(f"add :{name}: -> {code}")
        print(f"metadata -> {names()}")
        code, payload = client.call("GET", "/posts/" + post_id + "/reactions")
        rows = [(r["emoji_name"], r["user_id"][:6]) for r in (payload or [])]
        print(f"GET /posts/{{id}}/reactions -> {code} {rows}")

    print(f"\nPOST_ID={post_id}\nCHANNEL_ID={channel_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
