#!/usr/bin/env python3
"""T52 probe (part 3) — how many files `files/search in:<channel>` reports, page by page.

Part 2 showed `in:t34-showcase` returning 1 while `GET /channels/{id}/stats` says 3. This measures a
channel with tens of files to decide whether the search is a usable paging source for the list, and
whether the post metadata agrees with the search or with `stats.files_count`.
"""

from __future__ import annotations

import argparse
import sys

from t52_channel_probe import Client, fixture_password
from t52_channel_files_probe import file_ids_in_channel


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--channel", default="t38-files")
    parser.add_argument("--per-page", type=int, default=20)
    args = parser.parse_args()

    client = Client(args.url)
    client.login("perfprobe", fixture_password())
    status, teams = client.call("GET", "/users/me/teams")
    team_id = next(row for row in teams if row.get("name") == "perf")["id"]
    status, channels = client.call("GET", f"/users/me/teams/{team_id}/channels")
    channel = next(row for row in channels if row["name"] == args.channel)

    status, stats = client.call("GET", f"/channels/{channel['id']}/stats")
    print(f"{channel['name']} ({channel['id']}): stats files_count={stats.get('files_count')}")

    seen: list[str] = []
    page = 0
    while True:
        body = {"terms": f"in:{channel['name']}", "is_or_search": False,
                "page": page, "per_page": args.per_page}
        status, answer = client.call("POST", f"/teams/{team_id}/files/search", body)
        infos = (answer or {}).get("file_infos") or {}
        if isinstance(infos, list):
            ids = [info["id"] for info in infos]
        else:
            ids = list(infos.keys())
        print(f"  page {page}: {status} {len(ids)} infos next={ (answer or {}).get('next_file_info_id') }")
        if not ids:
            break
        seen.extend(ids)
        page += 1
        if page > 10:
            break
    print(f"  search total={len(seen)} distinct={len(set(seen))}")

    post_ids = file_ids_in_channel(client, channel["id"])
    print(f"  post metadata total={len(post_ids)} distinct={len(set(post_ids))}")
    print(f"  search-only={sorted(set(seen) - set(post_ids))[:5]}")
    print(f"  posts-only={sorted(set(post_ids) - set(seen))[:5]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
