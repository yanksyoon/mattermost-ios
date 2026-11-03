#!/usr/bin/env python3
"""T52 probe — the server contract for the channel-info rows this card adds.

Everything here is measured against the pinned fixture (Mattermost 9.11.19 at 127.0.0.1:8065), not
read from a type definition:

  1. notification preferences  `PUT /channels/{id}/members/{me}/notify_props` with
     `desktop`, `mark_unread` and `ignore_channel_mentions`, then `GET …/members/{me}` to read the
     server's answer back. Also: what an **unknown** level answers, because the client must fail to
     "the server's current value" rather than a guess.
  2. channel bookmarks         `GET/POST/PATCH/DELETE /channels/{id}/bookmarks` — measured with the
     link shape the web client sends. A 404/403 here means the split the card allows (keep 1/2/4 and
     card the bookmarks half).
  3. shared channels           `GET /channels/{id}/common_teams` — 404/empty on a Team Edition
     fixture without Connected Workspaces, which is the "row only when non-empty" rule.
  4. channel files             `GET /channels/{id}/files` and `POST /teams/{tid}/files/search` — the
     two candidates for "the channel's uploaded files, paged".
  5. pinned                    `GET /channels/{id}/pinned` (what the existing pinned sheet may use)
     versus the search route it actually uses.

The script creates its own scratch channel and deletes it at the end; it never writes to a fixture
channel the live tests use. No credential is stored here: the fixture password comes from
`MM_PROBE_PASSWORD`, falling back to the documented fixture constant in `scripts/perf_seed.py`, so a
reviewer can re-run this on the pinned fixture.

Usage:
    python3 scripts/t52_channel_probe.py --url http://127.0.0.1:8065
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

ADMIN_LOGIN = "perfprobe"
TEAM_NAME = "perf"
PROBE_CHANNEL = f"t52probe-{int(time.time())}"


def fixture_password() -> str:
    """The fixture password: environment first, then the documented constant in perf_seed.py."""
    from_env = os.environ.get("MM_PROBE_PASSWORD", "")
    if from_env:
        return from_env
    here = os.path.dirname(os.path.abspath(__file__))
    seed = os.path.join(here, "perf_seed.py")
    if os.path.exists(seed):
        with open(seed, encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("PASSWORD = "):
                    return line.split("=", 1)[1].strip().strip('"')
    return ""


class Client:
    def __init__(self, base: str, token: str | None = None) -> None:
        self.base = base.rstrip("/")
        self.token = token

    def call(self, method: str, path: str, body=None, query=None):
        url = f"{self.base}/api/v4{path}"
        if query:
            url += "?" + "&".join(f"{key}={value}" for key, value in query.items())
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                raw = response.read()
                return response.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as error:
            raw = error.read()
            try:
                payload = json.loads(raw or b"null")
            except ValueError:
                payload = raw.decode(errors="replace")
            return error.code, payload

    def login(self, login: str, password: str) -> dict:
        request = urllib.request.Request(
            f"{self.base}/api/v4/users/login",
            data=json.dumps({"login_id": login, "password": password}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=20) as response:
            self.token = response.headers.get("Token")
            return json.loads(response.read())


def show(label: str, status: int, payload) -> None:
    if isinstance(payload, (dict, list)):
        text = json.dumps(payload)[:300]
    else:
        text = str(payload)[:300]
    print(f"  {label:52s} -> {status} {text}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--login", default=ADMIN_LOGIN)
    parser.add_argument("--password", default="")
    args = parser.parse_args()

    password = args.password or fixture_password()
    if not password:
        print("no fixture password: set MM_PROBE_PASSWORD", file=sys.stderr)
        return 2

    admin = Client(args.url)
    me = admin.login(args.login, password)
    print(f"signed in as {me['username']} ({me['id']}) on {args.url}\n")

    status, teams = admin.call("GET", "/users/me/teams")
    team = next((row for row in teams if row.get("name") == TEAM_NAME), teams[0])
    team_id = team["id"]
    print(f"team {team.get('name')} = {team_id}")

    status, channel = admin.call("POST", "/channels",
                                 {"team_id": team_id, "name": PROBE_CHANNEL,
                                  "display_name": "T52 probe", "type": "O"})
    show("POST /channels (scratch)", status, channel)
    if status not in (200, 201) or not channel.get("id"):
        print("    could not create the scratch channel; stopping")
        return 1
    channel_id = channel["id"]
    print(f"scratch channel {channel_id}\n")

    # 1. notification preferences -------------------------------------------------------------
    print("1. notification preferences")
    path = f"/channels/{channel_id}/members/{me['id']}/notify_props"
    status, before = admin.call("GET", f"/channels/{channel_id}/members/{me['id']}")
    show("GET member (before)", status, (before or {}).get("notify_props"))
    status, answer = admin.call("PUT", path, {"desktop": "mention", "mark_unread": "mention",
                                              "ignore_channel_mentions": "on"})
    show("PUT notify_props desktop=mention mark_unread=mention ignore=on", status, answer)
    status, after = admin.call("GET", f"/channels/{channel_id}/members/{me['id']}")
    show("GET member (after)", status, (after or {}).get("notify_props"))
    status, answer = admin.call("PUT", path, {"desktop": "all", "mark_unread": "all",
                                              "ignore_channel_mentions": "off"})
    show("PUT notify_props desktop=all mark_unread=all ignore=off", status, answer)
    status, after = admin.call("GET", f"/channels/{channel_id}/members/{me['id']}")
    show("GET member (restored)", status, (after or {}).get("notify_props"))
    status, answer = admin.call("PUT", path, {"desktop": "nonsense"})
    show("PUT notify_props desktop=nonsense (unknown level)", status, answer)
    status, after = admin.call("GET", f"/channels/{channel_id}/members/{me['id']}")
    show("GET member after unknown level", status, (after or {}).get("notify_props"))

    # 2. channel bookmarks --------------------------------------------------------------------
    print("\n2. channel bookmarks")
    status, listed = admin.call("GET", f"/channels/{channel_id}/bookmarks")
    show("GET /channels/{id}/bookmarks", status, listed)
    status, created = admin.call("POST", f"/channels/{channel_id}/bookmarks",
                                 {"display_name": "T52 probe bookmark",
                                  "link_url": "https://example.invalid/t52",
                                  "type": "link"})
    show("POST /channels/{id}/bookmarks (link)", status, created)
    bookmark_id = (created or {}).get("id") if isinstance(created, dict) else None
    status, listed = admin.call("GET", f"/channels/{channel_id}/bookmarks")
    show("GET bookmarks (after create)", status, listed)
    if bookmark_id:
        status, edited = admin.call("PATCH", f"/channels/{channel_id}/bookmarks/{bookmark_id}",
                                    {"display_name": "T52 probe bookmark (edited)"})
        show("PATCH /channels/{id}/bookmarks/{bid}", status, edited)
        status, reread = admin.call("GET", f"/channels/{channel_id}/bookmarks")
        show("GET bookmarks (after edit)", status, reread)
        status, deleted = admin.call("DELETE", f"/channels/{channel_id}/bookmarks/{bookmark_id}")
        show("DELETE /channels/{id}/bookmarks/{bid}", status, deleted)
        status, listed = admin.call("GET", f"/channels/{channel_id}/bookmarks")
        show("GET bookmarks (after delete)", status, listed)

    # 3. shared channels ----------------------------------------------------------------------
    print("\n3. common teams (shared channels)")
    status, common = admin.call("GET", f"/channels/{channel_id}/common_teams")
    show("GET /channels/{id}/common_teams", status, common)

    # 4. channel files ------------------------------------------------------------------------
    print("\n4. channel files")
    show("GET /channels/{id}/files", *admin.call("GET", f"/channels/{channel_id}/files",
                                                 query={"page": 0, "per_page": 20}))
    show("GET /channels/{id}/files (no paging)", *admin.call("GET", f"/channels/{channel_id}/files"))
    show("POST /teams/{tid}/files/search",
         *admin.call("POST", f"/teams/{team_id}/files/search",
                     {"terms": "", "is_or_search": False, "page": 0, "per_page": 20,
                      "channel_id": channel_id}))

    # 5. pinned -------------------------------------------------------------------------------
    print("\n5. pinned")
    show("GET /channels/{id}/pinned", *admin.call("GET", f"/channels/{channel_id}/pinned"))
    show("POST /teams/{tid}/posts/search is_pinned",
         *admin.call("POST", f"/teams/{team_id}/posts/search",
                     {"terms": "channel_id:" + channel_id + " is_pinned:true",
                      "is_or_search": False}))

    print("\ncleanup")
    show("DELETE /channels/{id} (scratch)", *admin.call("DELETE", f"/channels/{channel_id}"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
