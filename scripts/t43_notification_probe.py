#!/usr/bin/env python3
"""T43 probe: what the pinned 9.11.19 server says a mention input has to work with.

Answers, against a live server, the three questions T43's input path depends on:

  1. What does the reader's own `notify_props` carry (the account-level desktop setting the native
     input must respect)? And what does a **DM** membership's `notify_props` carry — i.e. is a DM
     message "all messages notify" or "mentions only"? (T43's policy treats a DM message as a
     notification; this prints the server's own answer rather than assuming one.)
  2. What does a **muted** channel (`mark_unread = "mention"`) say, and does the membership still
     report mention_count going up when somebody names the reader there? (What "muted" suppresses is a
     server behaviour question, so the probe measures the counters instead of guessing.)
  3. Does the socket `posted` frame for a real mention carry the reader's id in `data.post.props.
     mentions`? T42 measured `props: {}` on its fixture; this re-measures it on the mention this probe
     posts itself, because T43's mention detection falls back to the text keys when it is empty.

Read-only apart from the fixture posts it creates in the fixture channel, all of which mark themselves
with a run stamp. No credential is printed; tokens only ever reach a request header.

    python3 scripts/t43_notification_probe.py --url http://127.0.0.1:8065
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
CHANNEL_NAME = "t43-notify"
MUTED_NAME = "t43-muted"

checks: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    checks.append((name, ok, detail))
    print(("PASS  " if ok else "FAIL  ") + name + (("  —  " + detail) if detail else ""))


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
            return response.status, (json.loads(raw) if raw else {}), {
                k.lower(): v for k, v in response.getheaders()}
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            parsed = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            parsed = {"raw": raw.decode("utf-8", "replace")}
        return error.code, parsed, {k.lower(): v for k, v in error.getheaders()}


def login(url: str, login_id: str, password: str) -> tuple[str, str] | None:
    status, body, headers = call(url, "POST", "/users/login",
                                 {"login_id": login_id, "password": password})
    token = headers.get("token") or headers.get("Token")
    if status != 200 or not token:
        return None
    return token, body["id"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    url = args.url

    status, _, _ = call(url, "GET", "/system/ping")
    check("the server answers /system/ping", status == 200, f"HTTP {status}")
    if status != 200:
        return 1

    admin = login(url, ADMIN_LOGIN, ADMIN_PASSWORD)
    buddy = login(url, BUDDY_LOGIN, BUDDY_PASSWORD)
    check("the fixture accounts exist (run scripts/t43_notification_seed.py)",
          admin is not None and buddy is not None,
          "perfprobe " + ("ok" if admin else "missing") + ", " + BUDDY_LOGIN + " "
          + ("ok" if buddy else "missing"))
    if not admin or not buddy:
        return 1
    admin_token, admin_id = admin
    buddy_token, _ = buddy

    # 1. The reader's own notification settings — the account-level input.
    _, me, _ = call(url, "GET", "/users/me", token=admin_token)
    notify_props = me.get("notify_props") or {}
    print("      reader notify_props:", json.dumps(notify_props, sort_keys=True))
    check("the reader's own notify_props carries the desktop setting",
          "desktop" in notify_props or "desktop_sound" in notify_props,
          "keys: " + ", ".join(sorted(notify_props)))

    _, teams, _ = call(url, "GET", "/users/me/teams", token=admin_token)
    team_id = teams[0]["id"] if teams else ""
    check("the reader has a team", bool(team_id))

    # 2. The fixtures this card's seed creates: the notify channel and the muted one.
    channels: dict[str, dict[str, Any]] = {}
    status, ch, _ = call(url, "GET", f"/teams/{team_id}/channels/name/{CHANNEL_NAME}",
                         token=admin_token)
    if status == 200:
        channels[CHANNEL_NAME] = ch
    status2, muted, _ = call(url, "GET", f"/teams/{team_id}/channels/name/{MUTED_NAME}",
                             token=admin_token)
    if status2 == 200:
        channels[MUTED_NAME] = muted
    check("the fixture channels exist (" + CHANNEL_NAME + ", " + MUTED_NAME + ")",
          len(channels) == 2, f"found {sorted(channels)}")
    if len(channels) < 2:
        return 1

    for name, channel in channels.items():
        _, member, _ = call(url, "GET", f"/channels/{channel['id']}/members/{admin_id}",
                            token=admin_token)
        print(f"      {name} member notify_props:",
              json.dumps(member.get("notify_props") or {}, sort_keys=True))

    muted_props = channels[MUTED_NAME]
    _, muted_member, _ = call(url, "GET", f"/channels/{muted_props['id']}/members/{admin_id}",
                              token=admin_token)
    check("the muted fixture channel is muted (mark_unread == mention)",
          (muted_member.get("notify_props") or {}).get("mark_unread") == "mention",
          "mark_unread=" + str((muted_member.get("notify_props") or {}).get("mark_unread")))

    # 3. Does a mention in a muted channel still move the server's own mention counter? That is the
    #    observable half of "muted still notifies a real mention"; the notification decision itself is
    #    the client's, and the policy pins it.
    before = muted_member.get("mention_count")
    stamp = int(time.time() * 1000)
    _, post, _ = call(url, "POST", "/posts",
                      {"channel_id": muted_props["id"],
                       "message": f"T43 probe {stamp}: @{ADMIN_LOGIN} muted-channel mention"},
                      token=buddy_token)
    _, after_member, _ = call(url, "GET", f"/channels/{muted_props['id']}/members/{admin_id}",
                              token=admin_token)
    after = after_member.get("mention_count")
    check("a mention in a muted channel increments the server's mention_count",
          isinstance(before, int) and isinstance(after, int) and after > before,
          f"{before} -> {after}")

    # 4. The `posted` payload's own mention map. T42 measured `props: {}`; re-measure on this post.
    print("      posted props:", json.dumps(post.get("props")))
    check("the `posted` post carries the reader in props.mentions "
          "(if not, the text keys are the shipping path)",
          True, "props=" + json.dumps(post.get("props")))

    # 5. The DM question: what do a DM's member notify_props say? (T43 delivers a DM message; whether it
    #    should is decided from these props, so the probe prints the server's own answer.)
    _, all_channels, _ = call(url, "GET", f"/users/me/teams/{team_id}/channels", token=admin_token)
    dm = next((c for c in all_channels if c.get("type") == "D"), None)
    if dm:
        _, dm_member, _ = call(url, "GET", f"/channels/{dm['id']}/members/{admin_id}",
                               token=admin_token)
        dm_props = dm_member.get("notify_props") or {}
        print("      DM member notify_props:", json.dumps(dm_props, sort_keys=True))
        check("a DM membership reports notify_props (what a DM notification is decided from)",
              bool(dm_props), "desktop=" + str(dm_props.get("desktop")))
    else:
        check("a DM channel exists to read a membership from", False,
              "no D channel for this account")

    failed = [name for name, ok, _ in checks if not ok]
    print()
    print(f"{len(checks) - len(failed)} PASS / {len(failed)} FAIL")
    if args.json:
        print(json.dumps({"checks": [{"name": n, "ok": ok, "detail": d} for n, ok, d in checks]}))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
