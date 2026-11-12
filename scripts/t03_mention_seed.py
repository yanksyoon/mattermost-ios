#!/usr/bin/env python3
"""t03_mention_seed.py - the fixture for the composer's `@` list (kanban t_03f2dbfd).

What the card needs on a live server, and what this script makes true (idempotently):

  1. an account in the team that is **not** a member of the channel being read -> it must come back
     in `out_of_channel`, and the composer must offer it under "Not in channel";
  2. a **bot account** in the same position. Bots are the harder half: the only bots a reader can
     mention are the ones that share a team, and `POST /bots` is disabled on this fixture
     (`api.bot.create_disabled`), so the seed adds a bot that already exists to the team instead of
     inventing one.

It does not create a channel or post anything: `t35-composer` (team `perf`) is already the live
suite's channel, and the point is what is *outside* it.

Run:

    python3 scripts/t03_mention_seed.py            # seed, then print the measured answers
    python3 scripts/t03_mention_seed.py --check    # read-only: print, change nothing

Credentials are `scripts/perf_seed.py`'s (the same account every live suite signs in as).
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

BASE = "http://127.0.0.1:8065"
ADMIN_LOGIN = "perfprobe"
ADMIN_PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
TEAM_NAME = "perf"
CHANNEL_NAME = "t35-composer"
# `feedbackbot` is a real bot record on this server (`GET /bots`), created by the feedback plugin.
BOT_USERNAME = "feedbackbot"
# A human in the team, not in the composer's channel.
HUMAN_USERNAME = "t43buddy"


def call(method: str, path: str, body: Any = None,
         token: str | None = None) -> tuple[int, Any, dict[str, str]]:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(BASE + "/api/v4" + path, data=data, method=method)
    request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = response.read()
            headers = {k.lower(): v for k, v in response.getheaders()}
            return response.status, (json.loads(raw) if raw else None), headers
    except urllib.error.HTTPError as error:
        raw = error.read()
        headers = {k.lower(): v for k, v in (error.headers or {}).items()}
        try:
            return error.code, json.loads(raw), headers
        except Exception:
            return error.code, raw.decode("utf-8", "replace"), headers


def login() -> str:
    status, body, headers = call("POST", "/users/login",
                                 {"login_id": ADMIN_LOGIN, "password": ADMIN_PASSWORD})
    if status != 200:
        sys.exit("login failed: %s %s" % (status, body))
    return headers.get("token") or body["token"]


def user_by_name(token: str, username: str) -> dict[str, Any] | None:
    status, body, _ = call("GET", "/users/username/" + urllib.parse.quote(username), token=token)
    return body if status == 200 else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="read-only; change nothing")
    args = parser.parse_args()

    token = login()
    status, teams, _ = call("GET", "/users/me/teams", token=token)
    team = next((t for t in teams if t["name"] == TEAM_NAME), None)
    if team is None:
        sys.exit("team %r is missing - run scripts/perf_seed.py" % TEAM_NAME)
    status, channel, _ = call("GET", "/teams/%s/channels/name/%s" % (team["id"], CHANNEL_NAME),
                              token=token)
    if status != 200:
        sys.exit("channel %r is missing - run scripts/t35_composer_seed.py" % CHANNEL_NAME)
    print("team %s (%s), channel #%s (%s)" % (team["name"], team["id"], channel["name"], channel["id"]))

    for username in (BOT_USERNAME, HUMAN_USERNAME):
        user = user_by_name(token, username)
        if user is None:
            sys.exit("user %r is missing - run scripts/perf_seed.py / scripts/t43_notification_seed.py"
                     % username)
        status, member, _ = call("GET", "/teams/%s/members/%s" % (team["id"], user["id"]), token=token)
        if status == 200:
            print("  %-13s already in the team" % username)
        elif status in (403, 404):
            if args.check:
                print("  %-13s NOT in the team (would be added)" % username)
            else:
                status, _, _ = call("POST", "/teams/%s/members" % team["id"],
                                    {"team_id": team["id"], "user_id": user["id"]}, token=token)
                print("  %-13s added to the team: HTTP %s" % (username, status))
        else:
            sys.exit("team membership check for %r: HTTP %s %s" % (username, status, member))

    print("\nMeasured `GET /users/autocomplete` (the query the composer now sends):")
    for term in ("", "feed", "t43", "bot"):
        query = urllib.parse.urlencode({"name": term, "limit": 20,
                                        "in_team": team["id"], "in_channel": channel["id"]})
        status, body, _ = call("GET", "/users/autocomplete?" + query, token=token)
        if status != 200:
            print("  name=%-5r -> HTTP %s %s" % (term, status, body))
            continue
        print("  name=%-5r users=%s out_of_channel=%s"
              % (term,
                 [u["username"] for u in body.get("users", [])],
                 [u["username"] for u in body.get("out_of_channel", [])]))

    status, bots, _ = call("GET", "/bots?per_page=200", token=token)
    if status == 200:
        print("\nGET /bots: %s" % [b["username"] for b in bots])
    return 0


if __name__ == "__main__":
    sys.exit(main())
