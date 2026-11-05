#!/usr/bin/env python3
"""t8525_ignore_mentions_probe.py — measure the pinned server's `ignore_channel_mentions` contract.

Why a probe and not a reading of the docs: the parity card for this work claims the field carries
`"all"` / `"default"`. The pinned client (mattermost-mobile v2.45.0
`app/screens/channel_info/options/ignore_mentions/ignore_mentions.tsx`) writes `"on"` / `"off"`, and
the pinned server's own mention-key derivation only knows `"on"`:

    server/channels/app/mention_keywords.go:74 (release-9.11 / 9.11.19)
      ignoreChannelMentions := channelNotifyProps[...IgnoreChannelMentionsNotifyProp] == "on" ||
        (channelNotifyProps[...MarkUnreadNotifyProp] == "mention" &&
         channelNotifyProps[...IgnoreChannelMentionsNotifyProp] == "default")
      if profile.NotifyProps["channel"] == "true" && !ignoreChannelMentions { k["@channel"]; k["@all"]; }

So the *behavioural* question is answerable on the wire: does a `@channel` post move the reader's
`mention_count`? That counter is computed from the same mention keywords, which is why it is the
observable this probe uses. It also measures the muted-channel clause above, which nothing in this
repo's policy had modelled.

Usage:
    python3 scripts/t8525_ignore_mentions_probe.py [--url http://127.0.0.1:8065]

Exit codes: 0 every check held, 1 a check contradicted the contract, 2 the fixture was unreachable.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from typing import Any

ADMIN_LOGIN = "perfprobe"
ADMIN_PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
BUDDY_LOGIN = "t43buddy"
BUDDY_PASSWORD = "T43-Buddy-Not-A-Real-Secret-1"
CHANNEL_NAME = "t8525-ignore"
CHANNEL_DISPLAY = "T8525 ignore mentions"
KEY = "ignore_channel_mentions"
STORE_CANDIDATES = ["on", "off", "default", "all"]


def call(url: str, method: str, path: str, body: Any = None,
         token: str | None = None) -> tuple[int, Any, dict[str, str]]:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url.rstrip("/") + "/api/v4" + path, data=data, method=method)
    request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = response.read()
            return response.status, _parse(raw), {k.lower(): v for k, v in response.getheaders()}
    except urllib.error.HTTPError as error:
        headers = {k.lower(): v for k, v in error.headers.items()} if error.headers else {}
        return error.code, _parse(error.read()), headers


def _parse(payload: bytes) -> Any:
    if not payload:
        return None
    try:
        return json.loads(payload)
    except json.JSONDecodeError:
        return payload.decode("utf-8", "replace")[:400]


def login(url: str, user: str, password: str) -> tuple[str, dict[str, Any]]:
    status, body, headers = call(url, "POST", "/users/login",
                                 {"login_id": user, "password": password})
    if status != 200 or not headers.get("token"):
        raise SystemExit(f"could not sign in as {user} (HTTP {status}, {str(body)[:200]})")
    return headers["token"], body


def ensure_channel(url: str, token: str, team_id: str) -> dict[str, Any]:
    status, channel, _ = call(url, "GET", f"/teams/{team_id}/channels/name/{CHANNEL_NAME}",
                              token=token)
    if status == 200 and isinstance(channel, dict) and channel.get("id"):
        return channel
    status, created, _ = call(url, "POST", "/channels",
                              {"team_id": team_id, "name": CHANNEL_NAME,
                               "display_name": CHANNEL_DISPLAY, "type": "O"},
                              token=token)
    if status not in (201, 200) or not isinstance(created, dict) or not created.get("id"):
        raise SystemExit(f"could not create #{CHANNEL_NAME} (HTTP {status}, {str(created)[:200]})")
    return created


def notify_props(url: str, token: str, channel_id: str, user_id: str) -> dict[str, str]:
    status, member, _ = call(url, "GET", f"/channels/{channel_id}/members/{user_id}", token=token)
    if status != 200 or not isinstance(member, dict):
        raise SystemExit(f"could not read the membership (HTTP {status})")
    return member.get("notify_props") or {}


def member_row(url: str, token: str, channel_id: str, user_id: str) -> dict[str, Any]:
    status, member, _ = call(url, "GET", f"/channels/{channel_id}/members/{user_id}", token=token)
    if status != 200 or not isinstance(member, dict):
        raise SystemExit(f"could not read the membership (HTTP {status})")
    return member


def set_props(url: str, token: str, channel_id: str, user_id: str,
              props: dict[str, str]) -> int:
    status, _, _ = call(url, "PUT", f"/channels/{channel_id}/members/{user_id}/notify_props",
                        props, token=token)
    return status


def mention_delta_after(url: str, admin_token: str, buddy_token: str, channel_id: str,
                        reader_id: str, message: str) -> tuple[int, int]:
    """Mark the channel read, have the buddy post, and answer the mention counter's **delta**.

    The counter is cumulative and `POST /channels/{id}/view` is not guaranteed to clear it before the
    next read (measured: it did not), so the probe reports what one post moved — `after - before`,
    which is 1 when the post is a mention of the reader and 0 when the server's keywords dropped it.
    """
    call(url, "POST", f"/channels/{channel_id}/view", {}, token=admin_token)
    time.sleep(0.3)
    before = int(member_row(url, admin_token, channel_id, reader_id).get("mention_count") or 0)
    status, post, _ = call(url, "POST", "/posts", {"channel_id": channel_id, "message": message},
                           token=buddy_token)
    if status not in (200, 201) or not isinstance(post, dict) or not post.get("id"):
        raise SystemExit(f"could not post as the buddy (HTTP {status}, {str(post)[:200]})")
    after = before
    for _ in range(10):
        time.sleep(0.2)
        after = int(member_row(url, admin_token, channel_id, reader_id).get("mention_count") or 0)
        if after != before:
            break
    return before, after


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    args = parser.parse_args()

    admin_token, me = login(args.url, ADMIN_LOGIN, ADMIN_PASSWORD)
    buddy_token, buddy = login(args.url, BUDDY_LOGIN, BUDDY_PASSWORD)
    checks: list[tuple[str, bool, str]] = []

    status, teams, _ = call(args.url, "GET", "/users/me/teams", token=admin_token)
    if status != 200 or not isinstance(teams, list) or not teams:
        print(f"FATAL could not list the account's teams (HTTP {status})")
        return 2
    team = teams[0]
    channel = ensure_channel(args.url, admin_token, team["id"])
    channel_id, user_id = channel["id"], me["id"]
    call(args.url, "POST", f"/channels/{channel_id}/members",
         {"user_id": buddy["id"]}, token=admin_token)

    print(f"account notify_props.channel       = {(me.get('notify_props') or {}).get('channel')!r}")
    baseline = notify_props(args.url, admin_token, channel_id, user_id)
    original = baseline.get(KEY, "default")
    print(f"membership notify_props (baseline)  = {json.dumps(baseline, sort_keys=True)}")
    print()

    # ---- 1. What the write accepts and stores ------------------------------------------------
    stored: dict[str, str] = {}
    for value in STORE_CANDIDATES:
        status = set_props(args.url, admin_token, channel_id, user_id, {KEY: value})
        stored[value] = notify_props(args.url, admin_token, channel_id, user_id).get(KEY) or ""
        print(f"PUT {KEY}={value!r:10} -> HTTP {status:3}  stored={stored[value]!r}")

    print()
    # ---- 2. What the server honours: a @channel post and the reader's mention_count ----------
    deltas: dict[str, int] = {}
    for value in ["off", "on", "all"]:
        set_props(args.url, admin_token, channel_id, user_id, {KEY: value})
        before, after = mention_delta_after(
            args.url, admin_token, buddy_token, channel_id, user_id,
            f"@channel t8525 probe {value} {(time.time())!r}")
        deltas[f"@channel/{value}"] = after - before

    # The muted-channel clause: `mark_unread == mention` with `ignore_channel_mentions == default`
    # ignores @channel exactly like "on" does. `off` is the control that proves muting alone does not.
    set_props(args.url, admin_token, channel_id, user_id,
              {KEY: "default", "mark_unread": "mention"})
    before, after = mention_delta_after(
        args.url, admin_token, buddy_token, channel_id, user_id,
        f"@channel t8525 probe muted {(time.time())!r}")
    deltas["@channel/muted+default"] = after - before
    set_props(args.url, admin_token, channel_id, user_id, {KEY: "off", "mark_unread": "mention"})
    before, after = mention_delta_after(
        args.url, admin_token, buddy_token, channel_id, user_id,
        f"@channel t8525 probe muted-off {(time.time())!r}")
    deltas["@channel/muted+off"] = after - before

    # A direct mention is still a mention under "on" — that is the distinction the policy needs.
    set_props(args.url, admin_token, channel_id, user_id, {"mark_unread": "all", KEY: "on"})
    before, after = mention_delta_after(
        args.url, admin_token, buddy_token, channel_id, user_id,
        f"@perfprobe t8525 probe direct {(time.time())!r}")
    deltas["@perfprobe/on"] = after - before

    for label, delta in deltas.items():
        print(f"mention_count delta after {label:28} = {delta:+d}")
    print()

    checks.append(("'on' is accepted and stored", stored["on"] == "on", stored["on"]))
    checks.append(("'off' is accepted and stored", stored["off"] == "off", stored["off"]))
    checks.append(("'default' is accepted and stored", stored["default"] == "default",
                   stored["default"]))
    checks.append(("'all' is stored verbatim (this route does not validate)",
                   stored["all"] == "all", stored["all"]))
    checks.append(("'on' drops a @channel mention", deltas["@channel/on"] == 0,
                   f"delta={deltas['@channel/on']:+d}"))
    checks.append(("'off' keeps a @channel mention", deltas["@channel/off"] >= 1,
                   f"delta={deltas['@channel/off']:+d}"))
    checks.append(("'all' behaves like 'off' (stored, not honoured)",
                   deltas["@channel/all"] >= 1, f"delta={deltas['@channel/all']:+d}"))
    checks.append(("muted + default drops a @channel mention",
                   deltas["@channel/muted+default"] == 0,
                   f"delta={deltas['@channel/muted+default']:+d}"))
    checks.append(("muted + off keeps a @channel mention", deltas["@channel/muted+off"] >= 1,
                   f"delta={deltas['@channel/muted+off']:+d}"))
    checks.append(("a direct @username mention survives 'on'", deltas["@perfprobe/on"] >= 1,
                   f"delta={deltas['@perfprobe/on']:+d}"))

    # Restore the member the probe borrowed.
    restore_status = set_props(args.url, admin_token, channel_id, user_id,
                              {KEY: original, "mark_unread": baseline.get("mark_unread", "all")})
    restored = notify_props(args.url, admin_token, channel_id, user_id).get(KEY)
    checks.append((f"the fixture is restored to {original!r}", restored == original,
                   f"HTTP {restore_status} -> stored {restored!r}"))
    call(args.url, "DELETE", f"/channels/{channel_id}/members/{buddy['id']}", token=admin_token)

    print()
    failures = 0
    for index, (label, ok, detail) in enumerate(checks, start=1):
        print(f"{index}. {'PASS' if ok else 'FAIL'} {label}  [{detail}]")
        if not ok:
            failures += 1
    print(f"\n{len(checks)} checks, {failures} failure(s)")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
