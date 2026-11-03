#!/usr/bin/env python3
"""T52 probe (part 2) — channel files, shared-channel rows, and a GM's common_teams.

Extension of `scripts/t52_channel_probe.py` for the two questions that need a *populated* channel:
how "the channel's files, paged" is actually answered by the pinned server (there is **no**
`GET /channels/{id}/files` — 404, measured by part 1), and `GET /channels/{id}/common_teams` on a
group message (the only channel type the route accepts — an open channel answers 400
`app.channel.get_common_teams.incorrect_channel_type`).

Read-only. If the fixture has no GM it creates one; a GM cannot be deleted, so it is only listed.
"""

from __future__ import annotations

import argparse
import json
import sys

from t52_channel_probe import Client, fixture_password, show


def file_ids_in_channel(client: Client, channel_id: str) -> list[str]:
    """Every `file_id` in the channel's posts, read from the post rows themselves.

    `GET /channels/{id}/posts` is not right for every server (it answers the default page), so this
    walks `GET /channels/{id}/posts?page=&per_page=` until a short page.
    """
    ids: list[str] = []
    page = 0
    while True:
        status, answer = client.call("GET", f"/channels/{channel_id}/posts",
                                     query={"page": page, "per_page": 60})
        if status != 200 or not isinstance(answer, dict):
            print(f"    GET posts page {page} -> {status}")
            break
        posts = answer.get("posts") or {}
        order = answer.get("order") or []
        for post_id in order:
            metadata = (posts.get(post_id) or {}).get("metadata") or {}
            for file_id in metadata.get("files") or []:
                if file_id.get("id"):
                    ids.append(file_id["id"])
        if len(order) < 60:
            break
        page += 1
    return ids


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--login", default="perfprobe")
    parser.add_argument("--password", default="")
    args = parser.parse_args()

    password = args.password or fixture_password()
    client = Client(args.url)
    me = client.login(args.login, password)
    print(f"signed in as {me['username']} ({me['id']})\n")

    status, teams = client.call("GET", "/users/me/teams")
    team = next(row for row in teams if row.get("name") == "perf")
    team_id = team["id"]
    status, channels = client.call("GET", f"/users/me/teams/{team_id}/channels")

    print("1. which channels carry files (GET /channels/{id}/stats)")
    with_files = []
    for channel in channels:
        status, stats = client.call("GET", f"/channels/{channel['id']}/stats")
        if isinstance(stats, dict) and stats.get("files_count", 0) > 0:
            with_files.append((channel, stats))
            print(f"  {channel['name']:28s} {channel['type']} files={stats['files_count']} pins={stats['pinnedpost_count']}")
    if not with_files:
        print("  none has a file")
        return 1

    channel, stats = with_files[0]
    channel_id = channel["id"]
    print(f"\n2. channel-file paging on {channel['name']} ({channel_id}), server says {stats['files_count']}")

    for terms in (f"channel_id:{channel_id}", f"in:{channel['name']}", ""):
        body = {"terms": terms, "is_or_search": False, "time_zone_offset": 0,
                "page": 0, "per_page": 20}
        status, answer = client.call("POST", f"/teams/{team_id}/files/search", body)
        infos = answer.get("file_infos") if isinstance(answer, dict) else None
        info_count = len(infos) if isinstance(infos, (dict, list)) else 0
        order = (answer or {}).get("order") if isinstance(answer, dict) else None
        print(f"  terms={terms!r:32s} -> {status} keys={sorted((answer or {}).keys()) if isinstance(answer, dict) else '-'}"
              f" infos={info_count} order={len(order or [])}")
        if isinstance(infos, dict) and infos:
            first = next(iter(infos.values()))
            show("  first file_info", 200, first)

    body = {"terms": f"in:{channel['name']}", "is_or_search": False, "page": 0, "per_page": 2}
    status, page1 = client.call("POST", f"/teams/{team_id}/files/search", body)
    body["page"] = 1
    status, page2 = client.call("POST", f"/teams/{team_id}/files/search", body)
    def count(answer):
        infos = (answer or {}).get("file_infos") if isinstance(answer, dict) else None
        return len(infos) if isinstance(infos, (dict, list)) else 0
    print(f"  paging per_page=2: page0={count(page1)} page1={count(page2)}")

    print("\n3. the same channel's files from the posts themselves (the deterministic read)")
    ids = file_ids_in_channel(client, channel_id)
    print(f"  posts carry {len(ids)} file ids; stats says {stats['files_count']}")
    if ids:
        status, infos = client.call("POST", "/files/ids", ids)
        print(f"  POST /files/ids -> {status} {len(infos) if isinstance(infos, list) else infos}")
        if isinstance(infos, list) and infos:
            show("  first info", 200, infos[0])

    print("\n4. common_teams on every channel type")
    for row in channels:
        status, answer = client.call("GET", f"/channels/{row['id']}/common_teams")
        print(f"  {row['name'][:24]:24s} type={row['type']} -> {status} {json.dumps(answer)[:120]}")

    print("\n5. a group message (G) for common_teams, if the fixture has none")
    group = next((row for row in channels if row["type"] == "G"), None)
    if group is None:
        status, members = client.call("GET", f"/teams/{team_id}/members", query={"page": 0, "per_page": 3})
        ids = [row["user_id"] for row in (members or []) if row["user_id"] != me["id"]][:2]
        status, created = client.call("POST", "/channels/group", ids)
        show("POST /channels/group", status, created)
        group = created if isinstance(created, dict) else None
    if group is not None:
        show("GET /channels/{G}/common_teams", *client.call("GET", f"/channels/{group['id']}/common_teams"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
