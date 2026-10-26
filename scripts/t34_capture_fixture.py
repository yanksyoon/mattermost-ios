#!/usr/bin/env python3
"""Capture T34 fixtures (real server data) into the unit-test bundle.

Two artefacts, both plain JSON, both captured from a running Mattermost server through its own API:

  * `t34-perf-feed-posts.json` — the long channel's posts, captured by paging **backwards with the
    same cursor the client uses** (`before=<oldest id of the page>`), so the file itself carries real
    page boundaries. The unit test asserts the merged client window equals this capture's id sequence
    exactly: no drops, no duplicates. It also records the page sizes it saw, so the test knows which
    boundaries it is crossing.
  * `t34-showcase-posts.json` — one post per rendering case (markdown, fenced code, table, blockquote,
    emoticons, custom emoji, mention, channel link, raw HTML, an attachment, reactions, an edit, a
    long post) plus the channel's system messages.

**The capture is the request the app makes** (T34-R5 / finding T34-AV-F1): since that repair the
client asks for a thread-collapsed page (`collapsedThreads=true`), so the capture does too and
records `"collapsedThreads": true`. A capture without it would hand the pager test a page of 100
entries that the app never receives — 25 roots + 75 replies on perf-feed — which is exactly how the
old fixture "entrenched" replies-as-rows instead of catching them. (Measured on the pinned 9.11.19
server: with the parameter a 100-post page is 100 roots and the walk ends at 215 roots in 3 pages;
without it, 503 entries in 6 pages and 288 of them replies.)

No URL, no token, no credential is written: the capture stores only the post payloads the server
returned plus the channel's display metadata. (The post payloads are the bodies of the local
throwaway server's own messages — see `scripts/t34_post_seed.py`.)

Usage:
    python3 scripts/t34_capture_fixture.py --url http://127.0.0.1:8065
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

USERNAME = "perfprobe"
PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
TEAM_NAME = "perf"
LONG_CHANNEL_NAME = "perf-feed"
SHOWCASE_CHANNEL_NAME = "t34-showcase"
PER_PAGE = 100
#: The query parameter the app sends with every channel page (`ChannelAPI.channelPosts`): the
#: server's own thread-collapsed view, i.e. top-level posts only.
COLLAPSED_THREADS = True
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(REPO, "MattermostTests", "Fixtures")


def call(base, method, path, body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{base.rstrip('/')}/api/v4{path}", data=data, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("X-Requested-With", "XMLHttpRequest")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw.strip() else None), dict(resp.headers)
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            return exc.code, json.loads(raw), dict(exc.headers)
        except Exception:
            return exc.code, raw.decode(errors="replace"), dict(exc.headers)


def capture_channel(base, token, team_id, name, page_size):
    status, channel, _ = call(base, "GET", f"/teams/{team_id}/channels/name/{name}", token=token)
    if status != 200:
        raise SystemExit(f"channel {name} not found (run scripts/t34_post_seed.py first)")
    order: list[str] = []
    posts: dict[str, dict] = {}
    page_sizes: list[int] = []
    cursor = None
    pages = 0
    while True:
        query = f"/channels/{channel['id']}/posts?per_page={page_size}"
        if COLLAPSED_THREADS:
            query += "&collapsedThreads=true"
        if cursor:
            query += f"&before={cursor}"
        status, page, _ = call(base, "GET", query, token=token)
        if status != 200:
            raise SystemExit(f"{query} -> {status}: {page}")
        ids = page.get("order") or []
        pages += 1
        if not ids:
            break
        page_sizes.append(len(ids))
        for post_id in ids:
            if post_id in posts:
                continue          # defensive: a server-side overlap must not inflate the capture
            order.append(post_id)
            posts[post_id] = page["posts"][post_id]
        cursor = ids[-1]
        if pages > 50:
            raise SystemExit("pagination did not terminate")
    replies = sum(1 for post in posts.values() if post.get("root_id"))
    return {
        "captured_from": f"local throwaway Mattermost, team {TEAM_NAME}, channel {name}",
        "channel": {"id": channel["id"], "name": channel["name"],
                    "displayName": channel.get("display_name") or channel["name"],
                    "type": channel.get("type") or "O",
                    "totalMsgCount": channel.get("total_msg_count")},
        "perPage": page_size,
        "collapsedThreads": COLLAPSED_THREADS,
        "pageSizes": page_sizes,
        "order": order,
        "posts": posts,
    }, pages, replies


def attach_users(base, token, fixture):
    """Add the author profiles the client would fetch with `POST /users/ids`.

    The capture stores them so a unit test can assert the *author resolution* rules (display name,
    initials) against real profiles instead of invented ones. Ids only — the profile payload carries
    no credential (it is the server's own user object, minus nothing secret: username/name/email of a
    throwaway local user).
    """
    ids = sorted({post["user_id"] for post in fixture["posts"].values() if post.get("user_id")})
    status, users, _ = call(base, "POST", "/users/ids", ids, token=token)
    if status != 200 or not isinstance(users, list):
        raise SystemExit(f"/users/ids -> {status}")
    fixture["users"] = {user["id"]: user for user in users}
    return fixture


def attach_emoji(base, token, fixture):
    """Add the server's custom emoji list (`GET /emoji`), name → id, as the client fetches it.

    The showcase post carries a `:t34parrot:` shortcode, so the captured fixture has to carry the
    server's own answer for it: the unit test then proves the *real* name resolves to a *real* id,
    rather than asserting a table the test itself invented.
    """
    status, listed, _ = call(base, "GET", "/emoji?page=0&per_page=200&sort=", token=token)
    if status != 200 or not isinstance(listed, list):
        raise SystemExit(f"/emoji -> {status}")
    fixture["emoji"] = [{"id": emoji.get("id"), "name": emoji.get("name"),
                         "delete_at": emoji.get("delete_at", 0)}
                        for emoji in listed if not emoji.get("delete_at")]
    return fixture


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--url", default="http://127.0.0.1:8065")
    args = ap.parse_args()

    status, _, headers = call(args.url, "POST", "/users/login",
                              {"login_id": USERNAME, "password": PASSWORD})
    token = headers.get("token") or headers.get("Token")
    if status != 200 or not token:
        raise SystemExit(f"login failed: {status}")
    status, team, _ = call(args.url, "GET", f"/teams/name/{TEAM_NAME}", token=token)
    if status != 200:
        raise SystemExit(f"team {TEAM_NAME} not found; run scripts/perf_seed.py first")

    os.makedirs(OUT_DIR, exist_ok=True)
    long_fixture, long_pages, long_replies = capture_channel(args.url, token, team["id"],
                                                             LONG_CHANNEL_NAME, PER_PAGE)
    showcase, showcase_pages, showcase_replies = capture_channel(args.url, token, team["id"],
                                                                 SHOWCASE_CHANNEL_NAME, PER_PAGE)
    attach_users(args.url, token, long_fixture)
    attach_users(args.url, token, showcase)
    attach_emoji(args.url, token, showcase)

    for name, fixture in (("t34-perf-feed-posts.json", long_fixture),
                          ("t34-showcase-posts.json", showcase)):
        path = os.path.join(OUT_DIR, name)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(fixture, handle, indent=1, sort_keys=True)
            handle.write("\n")
        print(f"{name}: {len(fixture['order'])} posts, pages {fixture['pageSizes']}, "
              f"{os.path.getsize(path)} bytes")

    if long_replies or showcase_replies:
        print(f"WARNING: the capture still holds replies "
              f"(long {long_replies}, showcase {showcase_replies}) — collapsedThreads="
              f"{COLLAPSED_THREADS} did not filter them", file=sys.stderr)
        return 1

    print(f"long channel: {long_pages} pages, showcase: {showcase_pages} pages")
    print(f"long channel ids: newest {long_fixture['order'][0]} oldest {long_fixture['order'][-1]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
