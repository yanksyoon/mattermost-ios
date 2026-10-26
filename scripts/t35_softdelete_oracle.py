#!/usr/bin/env python3
"""What does the server answer *after* a soft delete? (T35 — the live test's delete oracle.)

The T35 live test proves "the server marked the post deleted" by reading `GET /posts/{id}` and
expecting `delete_at > 0`. That is what the API documentation implies, and it is what a plausible
implementation would assert — but against a real Mattermost 9.11.19 the answer is **404**, the post
leaves the channel window, and a `PUT` is refused with 403. This script does that exact sequence
with **no app involved**, so the oracle itself is testable and the reading in
`MattermostUITests/T35-ComposerUITests.swift` (`postIsGone`) is grounded in a measurement.

    create -> read -> DELETE -> read -> channel window -> PUT

Usage:
    python3 scripts/t35_softdelete_oracle.py --url http://127.0.0.1:8065

Credentials are the throwaway probe account `scripts/t35_composer_seed.py` already publishes, and the
channel is whatever that seed script created (`--channel`, default `t35-composer`). Nothing here
touches a real workspace.
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request

USERNAME = "perfprobe"
PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
TEAM_NAME = "perf"


def call(base: str, method: str, path: str, body: dict | None = None,
         token: str | None = None) -> tuple[int, object]:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(f"{base.rstrip('/')}/api/v4{path}", data=data, method=method)
    request.add_header("Content-Type", "application/json")
    request.add_header("X-Requested-With", "XMLHttpRequest")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            raw = response.read()
            return response.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            return error.code, json.loads(raw)
        except ValueError:
            return error.code, raw[:200].decode("utf-8", "replace")


def login(base: str) -> str:
    request = urllib.request.Request(f"{base.rstrip('/')}/api/v4/users/login",
                                     data=json.dumps({"login_id": USERNAME,
                                                      "password": PASSWORD}).encode(),
                                     method="POST")
    request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request, timeout=10) as response:
        token = response.headers.get("Token")
    if not token:
        raise SystemExit("login succeeded but returned no Token header")
    return token


def resolve_channel_id(base: str, token: str, name: str) -> str:
    status, team = call(base, "GET", f"/teams/name/{TEAM_NAME}", token=token)
    if status != 200 or not isinstance(team, dict):
        raise SystemExit(f"team #{TEAM_NAME} is missing ({status}) — run scripts/t35_composer_seed.py")
    status, channel = call(base, "GET", f"/teams/{team['id']}/channels/name/{name}", token=token)
    if status != 200 or not isinstance(channel, dict):
        raise SystemExit(f"channel #{name} is missing ({status}) — run scripts/t35_composer_seed.py")
    return channel["id"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--channel", default="t35-composer")
    args = parser.parse_args()

    token = login(args.url)
    channel_id = resolve_channel_id(args.url, token, args.channel)
    print(f"server  : {args.url}  channel {args.channel} ({channel_id})")

    status, post = call(args.url, "POST", "/posts",
                        {"channel_id": channel_id,
                         "message": "t35 oracle probe — safe to delete"}, token=token)
    if status != 201 or not isinstance(post, dict):
        print(f"could not create the probe post ({status}): {post}")
        return 2
    post_id = post["id"]

    status, body = call(args.url, "GET", f"/posts/{post_id}", token=token)
    print(f"read before delete : {status} delete_at="
          f"{body.get('delete_at') if isinstance(body, dict) else body}")
    status, body = call(args.url, "DELETE", f"/posts/{post_id}", token=token)
    print(f"DELETE             : {status}")
    status, body = call(args.url, "GET", f"/posts/{post_id}", token=token)
    print(f"read after delete  : {status} "
          f"delete_at={body.get('delete_at') if isinstance(body, dict) else body}")
    status, page = call(args.url, "GET", f"/channels/{channel_id}/posts?per_page=30", token=token)
    order = page.get("order", []) if isinstance(page, dict) else []
    print(f"in channel window  : {post_id in order}")
    status, body = call(args.url, "PUT", f"/posts/{post_id}",
                        {"id": post_id, "message": "edited after delete"}, token=token)
    print(f"PUT after delete   : {status} "
          f"{body.get('message') if isinstance(body, dict) else body}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
