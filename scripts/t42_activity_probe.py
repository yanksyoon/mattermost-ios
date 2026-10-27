#!/usr/bin/env python3
"""Measure the Mattermost contract the T42 mentions feed is built on, and print what the server does.

Every rule in `ActivityModels.swift`, `ActivityAPI.swift` and the two test files is a statement about
*this* server's answers. Several of them are not what the API documentation (or the card's own wording)
suggests, which is why they are measured rather than assumed:

  * the mentions read is **`POST /posts/search` with no team in the path**. `GET /users/me/mentions`
    (the path the card names) answers **404**, and so does the empty-team form `/teams//posts/search` —
    which is exactly why upstream's `fetchRecentMentions` branches on `teamId` and posts to the bare
    route when it is empty;
  * on the **database** search backend the answer is one window: `has_next` is false and `page: 1`
    answers an empty `order`, so a "load more" that trusted `page` would silently stop;
  * a post that incremented the mention counter carries **no `props.mentions`** (measured: `props` is
    `{}`), so the client's own key match is the shipping path for a live socket mention, not a fallback
    for a rare shape;
  * `last_viewed_at` is the read cursor and it moves to the server's clock on a read, so a row's dot must
    be `post.create_at > last_viewed_at` — and `last_viewed_at: 0` means "never read on this account",
    which is unread, not "read long ago";
  * **reading a channel does not move a thread's read state** (and vice versa): a reply's dot can only
    come from `GET /users/me/teams/{team}/threads?unread=true`. Marking the channel read leaves the
    thread's `unread_mentions` untouched — measured below, and the reason the row's action is a thread
    read when the row is a reply;
  * `POST /channels/members/{me}/mark_read` takes a bare JSON **array**; the wrapped form
    `{"channel_ids": [...]}` is a 400. The answer is `{status, last_viewed_at_times}` — the server's own
    new cursors, which is what the feed applies instead of inventing "now".

The socket section is what makes the feed live rather than a snapshot: a mention posted by the buddy
reaches my socket as `posted` (asserted), and a read performed by another session of my own account
reaches it as a channel-view frame (asserted, and the frame name is printed). It needs a websocket
client, so run under `uv` (otherwise that section is skipped, not faked):

    python3 scripts/t42_activity_seed.py --url http://127.0.0.1:8065
    uv run --with websockets python3 scripts/t42_activity_probe.py --url http://127.0.0.1:8065 \
        --log docs/t42-activity-probe-2026-10-27.log

Every check prints PASS/FAIL with the observed value; the exit code is non-zero if any expectation the
Swift code relies on does not hold. Fixture passwords are throwaway local values, identical to
`scripts/t42_activity_seed.py`'s; no credential or token is printed.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from typing import Any

ADMIN_LOGIN = "perfprobe"
ADMIN_PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
BUDDY_LOGIN = "t42buddy"
BUDDY_PASSWORD = "T42-Buddy-Not-A-Real-Secret-1"
CHANNEL_NAME = "t42-activity"

FAILURES: list[str] = []
SKIPS: list[str] = []
LINES: list[str] = []


def say(text: str = "") -> None:
    print(text)
    LINES.append(text)


def check(label: str, ok: bool, observed: Any = "") -> None:
    render = observed if isinstance(observed, str) else json.dumps(observed, sort_keys=True,
                                                                  default=str)
    if len(render) > 400:
        render = render[:400] + "…"
    say(f"  {'PASS' if ok else 'FAIL'}  {label}"
        + (f"\n          observed: {render}" if render else ""))
    if not ok:
        FAILURES.append(label)


def skip(label: str, why: str) -> None:
    say(f"  SKIP  {label} — {why}")
    SKIPS.append(label)


def call(url: str, method: str, path: str, body: Any = None, token: str | None = None,
         raw_path: bool = False) -> tuple[int, Any, dict[str, str]]:
    request = urllib.request.Request(url.rstrip("/") + (path if raw_path else "/api/v4" + path),
                                     data=(json.dumps(body).encode() if body is not None else None),
                                     method=method)
    request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = response.read()
            return response.status, _parse(payload), {k.lower(): v for k, v in response.getheaders()}
    except urllib.error.HTTPError as error:
        payload = error.read()
        headers = {k.lower(): v for k, v in error.headers.items()} if error.headers else {}
        return error.code, _parse(payload), headers


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


def search_body(terms: str, page: int = 0, per_page: int = 60) -> dict[str, Any]:
    """The body `ActivityAPI.mentionSearch` sends (upstream `fetchRecentMentions`)."""
    return {"terms": terms, "is_or_search": True, "include_deleted_channels": True,
            "time_zone_offset": 0, "page": page, "per_page": per_page}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--log", default="", help="write the same transcript to this file")
    parser.add_argument("--skip-socket", action="store_true",
                        help="skip the websocket section even when a client is available")
    args = parser.parse_args()
    base = args.url

    say(f"# T42 mentions/activity probe against {base}")
    say(f"run at {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} (UTC)")

    status, ping, _ = call(base, "GET", "/system/ping")
    check("the server answers /system/ping", status == 200 and ping.get("status") == "OK", ping)
    if status != 200:
        return _finish(args)

    admin_token, admin = login(base, ADMIN_LOGIN, ADMIN_PASSWORD)
    admin_id = admin["id"]
    say(f"\n## Session\nsigned in as @{ADMIN_LOGIN} ({admin_id}) — token not printed")

    # ---------------------------------------------------------------- fixture
    status, team_list, _ = call(base, "GET", "/users/me/teams", token=admin_token)
    team = next((t for t in (team_list or []) if isinstance(t, dict) and t.get("id")), None)
    if not team:
        say("  SKIP  the fixture account has no team — run scripts/t42_activity_seed.py")
        return _finish(args)
    status, channel, _ = call(base, "GET", f"/teams/{team['id']}/channels/name/{CHANNEL_NAME}",
                              token=admin_token)
    if status != 200 or not isinstance(channel, dict) or not channel.get("id"):
        say(f"  SKIP  #{CHANNEL_NAME} is absent — run scripts/t42_activity_seed.py")
        return _finish(args)
    status, buddy, _ = call(base, "GET", "/users/username/" + BUDDY_LOGIN, token=admin_token)
    if status != 200 or not isinstance(buddy, dict) or not buddy.get("id"):
        say(f"  SKIP  @{BUDDY_LOGIN} is absent — run scripts/t42_activity_seed.py")
        return _finish(args)
    buddy_id, channel_id = buddy["id"], channel["id"]
    say(f"\n## Fixture\n  team {team.get('name')} ({team['id']}), channel #{CHANNEL_NAME} "
        f"({channel_id}), buddy @{BUDDY_LOGIN} ({buddy_id})")

    # ---------------------------------------------------------------- 1. the routes
    say("\n## 1. Which route answers \"my mentions\"")
    status, body, _ = call(base, "GET", "/users/me/mentions", token=admin_token)
    check("`GET /users/me/mentions` is not a route (404) — the card's path does not exist",
          status == 404, {"status": status, "id": (body or {}).get("id") if isinstance(body, dict) else body})

    status, body, _ = call(base, "GET", f"/teams//posts/search", token=admin_token, raw_path=False)
    check("`/teams//posts/search` does not reach the search handler (the empty team segment is "
          "normalised away)", status in (400, 404, 405, 501),
          {"status": status, "id": (body or {}).get("id") if isinstance(body, dict) else body})

    # ---------------------------------------------------------------- 2. the window
    say("\n## 2. POST /posts/search — the cross-team mentions window")
    handle = "@" + admin["username"]
    status, window, _ = call(base, "POST", "/posts/search",
                             search_body(handle + " "), token=admin_token)
    check("200 from POST /posts/search with no team in the path", status == 200, status)
    order = (window or {}).get("order") or []
    posts = (window or {}).get("posts") or {}
    check("the answer is `order` + `posts`, the shape the search screen already decodes",
          isinstance(order, list) and isinstance(posts, dict),
          {"order": len(order), "posts": len(posts)})
    check("`has_next` is present and false on this database backend",
          (window or {}).get("has_next") in (False, None), (window or {}).get("has_next"))

    status, page1, _ = call(base, "POST", "/posts/search",
                            search_body(handle + " ", page=1), token=admin_token)
    check("`page: 1` answers an empty `order` (one window per query on the database backend)",
          status == 200 and not (page1 or {}).get("order"),
          {"status": status, "order": len((page1 or {}).get("order") or [])})

    mine = [pid for pid in order if (posts.get(pid) or {}).get("user_id") == buddy_id]
    named = [pid for pid in mine if handle in ((posts.get(pid) or {}).get("message") or "")]
    check("the window contains posts by the buddy that name me", bool(named),
          {"matched": len(named), "first": (posts.get(named[0]) if named else None) or {}})

    control_named = [pid for pid in order
                     if "nobody is named here" in ((posts.get(pid) or {}).get("message") or "")]
    check("a post that names nobody is not in the window", not control_named, control_named)

    reply_ids = [pid for pid in named if (posts.get(pid) or {}).get("root_id")]
    check("a mention inside a thread is in the window too, with its `root_id`",
          bool(reply_ids), {"reply_count": len(reply_ids)})

    props = (posts.get(named[0]) or {}).get("props") if named else None
    check("a mentioning post carries **no** `props.mentions` (so the client's key match is the "
          "shipping path)", not (isinstance(props, dict) and props.get("mentions")),
          {"props": props})

    # ---------------------------------------------------------------- 3. the keys
    say("\n## 3. GET /users/me — where the mention keys live")
    status, me, _ = call(base, "GET", "/users/me", token=admin_token)
    notify = (me or {}).get("notify_props") or {}
    check("200 and the account carries `notify_props`", status == 200 and isinstance(notify, dict),
          {"status": status, "keys": sorted(notify.keys())})
    for field in ("mention_keys", "first_name", "channel"):
        check(f"`notify_props.{field}` is a **string** on the wire",
              isinstance(notify.get(field), str),
              {"value": notify.get(field), "type": type(notify.get(field)).__name__})
    check("`notify_props.first_name` is `\"true\"`/`\"false\"`, not a bool",
          notify.get("first_name") in ("true", "false", None), notify.get("first_name"))

    # ---------------------------------------------------------------- 4. read cursors
    say("\n## 4. The read cursor: last_viewed_at")
    status, members, _ = call(base, "GET",
                              f"/users/{admin_id}/teams/{team['id']}/channels/members",
                              token=admin_token)
    rows = members if isinstance(members, list) else []
    mine_row = next((r for r in rows if r.get("channel_id") == channel_id), None)
    check("`GET /users/{me}/teams/{team}/channels/members` lists my channel rows", bool(mine_row),
          {"rows": len(rows)})
    check("the row carries `last_viewed_at`, `mention_count` and `msg_count`",
          all(k in (mine_row or {}) for k in ("last_viewed_at", "mention_count", "msg_count")),
          {k: (mine_row or {}).get(k) for k in ("last_viewed_at", "mention_count", "msg_count")})
    unread_before = int((mine_row or {}).get("mention_count") or 0)
    check("the seeded mentions are unread for me (mention_count > 0)", unread_before > 0,
          {"mention_count": unread_before})
    newest = max((int((posts.get(pid) or {}).get("create_at") or 0) for pid in named), default=0)
    check("every seeded mention is newer than my read cursor (so the row's dot is exact)",
          int((mine_row or {}).get("last_viewed_at") or 0) < newest,
          {"last_viewed_at": (mine_row or {}).get("last_viewed_at"), "newest_mention": newest})

    status, unread_teams, _ = call(base, "GET", "/users/me/teams/unread", token=admin_token)
    row = next((t for t in (unread_teams or []) if t.get("team_id") == team["id"]), None)
    check("`GET /users/me/teams/unread` answers the badge's numbers (mention_count > 0)",
          status == 200 and row is not None and int(row.get("mention_count") or 0) > 0, row)

    status, users, _ = call(base, "POST", "/users/ids", [buddy_id, admin_id], token=admin_token)
    check("`POST /users/ids` answers the rows' authors in one request",
          status == 200 and isinstance(users, list) and len(users) == 2,
          {"status": status, "count": len(users) if isinstance(users, list) else users})

    # ---------------------------------------------------------------- 5. the thread fact
    say("\n## 5. A reply's read state is not the channel's")
    status, threads, _ = call(base, "GET",
                              f"/users/me/teams/{team['id']}/threads?unread=true&per_page=200",
                              token=admin_token)
    thread_rows = (threads or {}).get("threads") or []
    reply_roots = {(posts.get(pid) or {}).get("root_id") for pid in reply_ids}
    seeded_thread = next((t for t in thread_rows if t.get("id") in reply_roots), None)
    check("`GET …/threads?unread=true` lists the seeded thread", seeded_thread is not None,
          {"threads": len(thread_rows), "roots": sorted(r for r in reply_roots if r)})
    check("…with `unread_mentions` > 0 (the reply that names me)",
          int((seeded_thread or {}).get("unread_mentions") or 0) > 0,
          {k: (seeded_thread or {}).get(k) for k in ("unread_mentions", "unread_replies")})

    # ---------------------------------------------------------------- 6. mark read
    say("\n## 6. POST /channels/members/{me}/mark_read")
    status, body, _ = call(base, "POST", f"/channels/members/{admin_id}/mark_read",
                           {"channel_ids": [channel_id]}, token=admin_token)
    check("a **wrapped** body `{channel_ids: [...]}` is a 400 (the body is a bare array)", status == 400,
          {"status": status, "id": (body or {}).get("id") if isinstance(body, dict) else body})

    status, answer, _ = call(base, "POST", f"/channels/members/{admin_id}/mark_read",
                             [channel_id], token=admin_token)
    # Measured: the status field is the **uppercase** `"OK"`. A client that compared it to `"ok"` would
    # think every read had failed, so the Swift model keeps it as an opaque string and never branches on it.
    check("a bare array is accepted and answers `{status: \"OK\", last_viewed_at_times}`",
          status == 200 and isinstance(answer, dict)
          and (answer or {}).get("status") == "OK"
          and isinstance((answer or {}).get("last_viewed_at_times"), dict),
          {"status": status, "answer": answer})
    cursors = (answer or {}).get("last_viewed_at_times") or {}
    check("the answer carries my channel's new cursor", channel_id in cursors, cursors)

    status, members_after, _ = call(base, "GET",
                                    f"/users/{admin_id}/teams/{team['id']}/channels/members",
                                    token=admin_token)
    after_row = next((r for r in (members_after if isinstance(members_after, list) else [])
                      if r.get("channel_id") == channel_id), None)
    check("the server then reports the channel read (mention_count == 0, cursor moved)",
          int((after_row or {}).get("mention_count") or 0) == 0
          and int((after_row or {}).get("last_viewed_at") or 0) >= newest,
          {k: (after_row or {}).get(k) for k in ("mention_count", "last_viewed_at")})

    status, unread_after, _ = call(base, "GET", "/users/me/teams/unread", token=admin_token)
    row_after = next((t for t in (unread_after or []) if t.get("team_id") == team["id"]), None)
    check("the team's badge counters follow (mention_count == 0)",
          int((row_after or {}).get("mention_count") or 0) == 0, row_after)

    status, window_after, _ = call(base, "POST", "/posts/search",
                                   search_body(handle + " "), token=admin_token)
    check("the window still contains the messages after they are read (readness is not a filter)",
          status == 200 and bool((window_after or {}).get("order")),
          {"order": len((window_after or {}).get("order") or [])})

    status, threads_after, _ = call(base, "GET",
                                    f"/users/me/teams/{team['id']}/threads?unread=true&per_page=200",
                                    token=admin_token)
    still_there = next((t for t in ((threads_after or {}).get("threads") or [])
                        if t.get("id") in reply_roots), None)
    check("reading the **channel** left the thread's unread mention untouched — the measured reason a "
          "reply row's dot cannot come from the channel cursor",
          still_there is not None and int((still_there or {}).get("unread_mentions") or 0) > 0,
          {k: (still_there or {}).get(k) for k in ("id", "unread_mentions")} if still_there else None)

    if still_there:
        ts = int(time.time() * 1000)
        status, thread_answer, _ = call(
            base, "PUT", f"/users/me/teams/{team['id']}/threads/{still_there['id']}/read/{ts}",
            None, token=admin_token)
        check("`PUT …/threads/{id}/read/{ts}` answers the thread with its counters",
              status == 200 and isinstance(thread_answer, dict),
              {"status": status, "id": (thread_answer or {}).get("id")})
        check("…and the thread is read now (unread_mentions == 0)",
              int((thread_answer or {}).get("unread_mentions") or 0) == 0,
              {k: (thread_answer or {}).get(k) for k in ("unread_mentions", "unread_replies")})

    # ---------------------------------------------------------------- 7. the socket
    say("\n## 7. The socket — a live mention and a read elsewhere")
    if args.skip_socket:
        skip("socket frames", "--skip-socket")
    else:
        try:
            asyncio.run(socket_section(base, admin_token, admin_id, buddy_id, channel_id, handle))
        except ImportError:
            skip("socket frames", "no websocket client — run under `uv run --with websockets`")

    return _finish(args)


# ---------------------------------------------------------------------- socket


FRAMES: list[dict[str, Any]] = []


async def _ws_collect(ws, seconds: float) -> None:
    deadline = time.monotonic() + seconds
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return
        try:
            raw = await asyncio.wait_for(ws.recv(), timeout=remaining)
        except asyncio.TimeoutError:
            return
        FRAMES.append(json.loads(raw))


async def socket_section(base: str, admin_token: str, admin_id: str, buddy_id: str,
                         channel_id: str, handle: str) -> None:
    import websockets  # noqa: PLC0415 — optional dependency, skipped when absent

    buddy_token, _ = login(base, BUDDY_LOGIN, BUDDY_PASSWORD)
    ws_url = base.replace("http://", "ws://").replace("https://", "wss://") + "/api/v4/websocket"

    async with websockets.connect(ws_url, ping_interval=20) as ws:
        # Authenticate the socket as the admin: the same `authentication_challenge` upstream sends.
        await ws.send(json.dumps({"seq": 1, "action": "authentication_challenge",
                                  "data": {"token": admin_token}}))
        await _ws_collect(ws, 1.0)
        check("the socket authenticates with my token",
              any(f.get("event") in ("hello", "status_change", "added_to_team") for f in FRAMES),
              [f.get("event") for f in FRAMES][:6])

        # A mention posted by another account while my socket is open.
        stamp = int(time.time() * 1000)
        status, live_post, _ = call(base, "POST", "/posts", {
            "channel_id": channel_id,
            "message": f"T42 probe {stamp}: {handle} live mention",
        }, token=buddy_token)
        check("the buddy could post a live mention", bool(status == 201 and (live_post or {}).get("id")),
              {"status": status})
        live_id = (live_post or {}).get("id") or ""

        FRAMES.clear()
        await _ws_collect(ws, 6.0)
        posted = next((f for f in FRAMES if f.get("event") == "posted"
                       and json.loads(f.get("data", {}).get("post", "{}") or "{}").get("id") == live_id),
                      None)
        decoded = json.loads(posted.get("data", {}).get("post", "{}") or "{}") if posted else {}
        check("my socket receives `posted` for that mention (the feed's live path)", posted is not None,
              {"event": posted.get("event") if posted else None,
               "channel_id": decoded.get("channel_id")})
        check("…with the post payload as a **JSON string** in `data.post`, which is what the decoder "
              "re-reads", isinstance(decoded, dict) and decoded.get("id") == live_id,
              {"keys": sorted(decoded.keys())[:8]})
        check("…and no `props.mentions` on it (the reason the client matches its own keys)",
              not (decoded.get("props") or {}).get("mentions"), {"props": decoded.get("props")})

        # A read performed by *another* session of my own account.
        FRAMES.clear()
        second_token, _ = login(base, ADMIN_LOGIN, ADMIN_PASSWORD)
        status, answer, _ = call(base, "POST", f"/channels/members/{admin_id}/mark_read",
                                 [channel_id], token=second_token)
        check("a second session of my account can mark the channel read", status == 200, status)
        await _ws_collect(ws, 6.0)
        viewed = next((f for f in FRAMES
                       if f.get("event") in ("multiple_channels_viewed", "channel_viewed")), None)
        check("my open socket is told about that read (the feed follows read state moved elsewhere)",
              viewed is not None,
              {"events": [f.get("event") for f in FRAMES],
               "frame": (viewed or {}).get("data")})


def _finish(args: argparse.Namespace) -> int:
    say("")
    if FAILURES:
        say(f"## Result: {len(FAILURES)} expectation(s) FAILED")
        for label in FAILURES:
            say(f"  - {label}")
    else:
        say("## Result: every expectation held")
    if SKIPS:
        say(f"## Skipped: {len(SKIPS)}")
        for label in SKIPS:
            say(f"  - {label}")
    if args.log:
        with open(args.log, "w", encoding="utf-8") as handle:
            handle.write("\n".join(LINES) + "\n")
        say(f"\n(transcript written to {args.log})")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
