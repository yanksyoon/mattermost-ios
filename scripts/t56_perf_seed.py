#!/usr/bin/env python3
"""T56 perf fixture — a 200-post channel the scroll probe can drive.

The A/B the card asks for (T6) is *old renderer vs new surface in the same build*: the
`-uiTestLegacyBlockBody` launch flag restores the per-block `Text` body, so one binary can measure
both arms on the same 200 posts, same device, same build. This script only creates the fixture.

    MM_PERF_LOGIN=… MM_PERF_PASSWORD=… python3 scripts/t56_perf_seed.py --posts 200

Idempotent: posts carry `props.t56_perf_key`, and a re-run tops the channel up to `--posts`.
Prints JSON with the channel id and the count, never the credentials.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

CHANNEL_NAME = "t56-perf"


def call(base: str, method: str, path: str, token: str | None = None,
         body: dict | None = None) -> tuple[int, dict | list | None, dict[str, str]]:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(base.rstrip("/") + "/api/v4" + path, data=data, method=method)
    request.add_header("Content-Type", "application/json")
    request.add_header("X-Requested-With", "XMLHttpRequest")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = response.read()
            return response.status, (json.loads(payload) if payload else None), dict(response.headers)
    except urllib.error.HTTPError as error:
        payload = error.read()
        try:
            parsed = json.loads(payload) if payload else None
        except json.JSONDecodeError:
            parsed = None
        return error.code, parsed, dict(error.headers)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--login", default=os.environ.get("MM_PERF_LOGIN", ""))
    parser.add_argument("--password", default=os.environ.get("MM_PERF_PASSWORD", ""))
    parser.add_argument("--posts", type=int, default=200)
    args = parser.parse_args()
    if not args.login or not args.password:
        print("set MM_PERF_LOGIN / MM_PERF_PASSWORD", file=sys.stderr)
        return 2

    status, _, headers = call(args.url, "POST", "/users/login",
                              body={"login_id": args.login, "password": args.password})
    token = headers.get("Token") or headers.get("token")
    if status != 200 or not token:
        print(f"login failed: HTTP {status}", file=sys.stderr)
        return 1

    _, teams, _ = call(args.url, "GET", "/users/me/teams", token)
    if not teams:
        print("the account has no team", file=sys.stderr)
        return 1
    team_id = teams[0]["id"]

    status, channel, _ = call(args.url, "GET", f"/teams/{team_id}/channels/name/{CHANNEL_NAME}", token)
    if status == 404:
        status, channel, _ = call(args.url, "POST", "/channels", token, {
            "team_id": team_id, "name": CHANNEL_NAME, "display_name": "T56 Perf",
            "type": "O", "purpose": "T56 scroll A/B fixture",
        })
    if status != 201 and status != 200:
        print(f"channel: HTTP {status} {channel}", file=sys.stderr)
        return 1
    channel_id = channel["id"]

    _, page, _ = call(args.url, "GET", f"/channels/{channel_id}/posts?per_page=200", token)
    existing = [post for post in (page or {}).get("posts", {}).values()
                if (post.get("props") or {}).get("t56_perf_key")]

    made = 0
    stamp = int(time.time())
    while len(existing) + made < args.posts:
        index = len(existing) + made
        status, _, _ = call(args.url, "POST", "/posts", token, {
            "channel_id": channel_id,
            "message": f"T56 perf post {index + 1:03d} ({stamp}): the quick brown fox jumps over the lazy dog.",
            "props": {"t56_perf_key": f"{stamp}-{index}"},
        })
        if status != 201:
            print(f"post {index} failed: HTTP {status}", file=sys.stderr)
            return 1
        made += 1

    print(json.dumps({"channel_id": channel_id, "channel_name": CHANNEL_NAME,
                      "team_id": team_id, "existing": len(existing), "created": made,
                      "total": len(existing) + made}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
