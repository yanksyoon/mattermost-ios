#!/usr/bin/env python3
"""t19828e14_category_probe.py - the category-management contract, measured on the pinned server.

Why this exists: the native sidebar now creates, renames, reorders and deletes sidebar categories,
and moves channels between them. Every one of those is a claim about what the **server** does, and
three of the claims were wrong on the first reading of the docs:

  1. `POST /users/{uid}/teams/{tid}/channels/categories` **ignores the id in the request** and
     generates its own (a valid 26-character id came back as a different one). So a create cannot be
     completed locally: the answer's id is the category, and a client that keeps its own id would
     write a category the server does not have.
  2. The whole-array `PUT` cannot create: a category the server does not know answers 500
     `app.channel.sidebar_categories.app_error` ("Failed to insert record to database"). A create has
     to be its own request.
  3. The whole-array `PUT` cannot **reorder** either: it keeps each category's `sort_order`, so new
     positions only arrive through `POST …/channels/categories/order`. (This is why the app renders a
     reorder from the order route's answer and not from the PUT's.)

It also proves the promise the delete confirmation makes: deleting a category does not delete its
channels — the server moves them into `channels` / `direct_messages` for their kind.

Usage:
  docker start mm-perf-db mm-perf            # the seeded dev server (127.0.0.1:8065)
  python3 scripts/t19828e14_category_probe.py
  python3 scripts/t19828e14_category_probe.py --json

Fixture accounts come from `scripts/t33_channel_seed.py` (perfprobe) and `scripts/t43_notification_seed.py`
(t43buddy); these are throwaway local passwords, not secrets.

Exit codes: 0 every claim held, 1 a claim did not hold, 2 could not reach the server.
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request

API = "http://127.0.0.1:8065/api/v4"
ADMIN_LOGIN = "perfprobe"
ADMIN_PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
BUDDY_LOGIN = "t43buddy"
BUDDY_PASSWORD = "T43-Buddy-Not-A-Real-Secret-1"
CATEGORY_ID_LENGTH = 26


class Call:
    def __init__(self) -> None:
        self.token: str | None = None
        self.server_version = ""
        self.failures: list[str] = []

    def __call__(self, method: str, path: str, body=None, token: str | None = None):
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(API + path, data=data, method=method)
        request.add_header("Content-Type", "application/json")
        if token or self.token:
            request.add_header("Authorization", "Bearer " + (token or self.token))
        try:
            with urllib.request.urlopen(request, timeout=30) as answer:
                raw = answer.read()
                return answer.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as error:
            raw = error.read()
            try:
                parsed = json.loads(raw)
            except Exception:
                parsed = raw.decode(errors="replace")
            return error.code, parsed

    def check(self, what: str, held: bool, detail: str = "") -> bool:
        mark = "ok  " if held else "FAIL"
        print(f"  [{mark}] {what}" + (f" — {detail}" if detail else ""))
        if not held:
            self.failures.append(what)
        return held


def short(ids) -> str:
    """A channel-id list for a log line: the count, and the head of it."""
    ids = list(ids or [])
    if len(ids) <= 4:
        return str(ids)
    return f"{len(ids)} ids: {', '.join(ids[:3])}…"


def login(call: Call, username: str, password: str) -> tuple[str, dict]:
    """Sign in and hand back the session token.

    The token is the **`Token` response header**, not a field in the body: Mattermost 9.11.19 moved it
    out of the user object (the body is the user, and `token` is absent — the first version of this
    probe assumed the old shape and crashed with `KeyError: 'token'`).
    """
    request = urllib.request.Request(
        API + "/users/login",
        data=json.dumps({"login_id": username, "password": password}).encode(),
        method="POST",
    )
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=30) as answer:
            token = answer.headers.get("Token") or answer.headers.get("token")
            body = json.loads(answer.read())
            version = answer.headers.get("X-Version-Id", "")
    except urllib.error.HTTPError as error:
        raise SystemExit(f"cannot sign in as {username}: {error.code} {error.read()[:300]}")
    if not token:
        raise SystemExit(f"cannot sign in as {username}: no Token header in the answer")
    call.server_version = version
    return token, body


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="machine-readable summary")
    args = parser.parse_args()

    call = Call()
    try:
        token, me = login(call, ADMIN_LOGIN, ADMIN_PASSWORD)
    except SystemExit as error:
        print(error, file=sys.stderr)
        return 2
    call.token = token
    me_id = me["id"]

    status, teams = call("GET", "/users/me/teams")
    if status != 200 or not teams:
        print(f"cannot read teams: {status} {teams}", file=sys.stderr)
        return 2
    team = teams[0]
    team_id = team["id"]
    base = f"/users/{me_id}/teams/{team_id}/channels/categories"
    print(f"server {call.server_version or '9.11.19'} · team {team['display_name']} ({team_id}) · user {ADMIN_LOGIN}")

    status, layout = call("GET", base)
    if status != 200:
        print(f"cannot read categories: {status} {layout}", file=sys.stderr)
        return 2
    before = layout["categories"]
    print(f"\n1. the layout as it stands: {len(before)} categories, "
          f"types {[c['type'] for c in before]}")
    for category in before:
        print(f"     {category['type']:<16} {category['id']:<28} {len(category.get('channel_ids', []))} channels")

    # A channel of each kind, for the delete promise: one public channel, one DM.
    status, channels = call("GET", f"/users/me/teams/{team_id}/channels")
    channel = next((c for c in channels or [] if c["type"] == "O"), None)
    status, all_my = call("GET", "/users/me/channels")
    dm = next((c for c in all_my or [] if c["type"] == "D"), None)
    if channel is None:
        print("no public channel for this account; run scripts/t33_channel_seed.py", file=sys.stderr)
        return 2

    # 2. create: the server generates the id.
    print("\n2. create a category — does the server keep the id we send?")
    wanted = "t19828e14" + "0" * (CATEGORY_ID_LENGTH - len("t19828e14"))
    status, created = call("POST", base, {
        "id": wanted,
        "user_id": me_id,
        "team_id": team_id,
        "display_name": "t19828e14 probe",
        "type": "custom",
        "sorting": "manual",
        "sort_order": 10,
        "channel_ids": [],
    })
    call.check("POST …/channels/categories answers 2xx", 200 <= status < 300, f"status {status}")
    if not (200 <= status < 300):
        print(json.dumps(created, indent=2)[:800], file=sys.stderr)
        return 1
    category_id = created["id"]
    print(f"     requested id {wanted}")
    print(f"     server id    {category_id}")
    call.check("the server assigned its own id (the request's is ignored)",
               category_id != wanted, f"{category_id[:8]}…")
    call.check("the id is 26 characters", len(category_id) == CATEGORY_ID_LENGTH, str(len(category_id)))
    call.check("the new category is empty", created.get("channel_ids") in (None, []), str(created.get("channel_ids")))

    # 3. the whole-array PUT cannot create a category the server does not know.
    print("\n3. the whole-array PUT with an unknown category — can it create one?")
    ghost = dict(created, id="ghost" + "0" * (CATEGORY_ID_LENGTH - 5), display_name="ghost")
    status, answer = call("PUT", base, before + [ghost])
    call.check("the PUT is refused (500 app_error) — a create must be its own request",
               status >= 500, f"status {status}")

    # 4. move a channel in: both lists change, in one write.
    print(f"\n4. move #{channel['name']} into the new category with one whole-array PUT")
    status, layout = call("GET", base)
    categories = layout["categories"]
    source = next((c for c in categories if channel["id"] in (c.get("channel_ids") or [])), None)
    moved = []
    for category in categories:
        ids = list(category.get("channel_ids") or [])
        if category["id"] == category_id:
            ids.append(channel["id"])
        elif channel["id"] in ids:
            ids.remove(channel["id"])
        moved.append(dict(category, channel_ids=ids))
    status, answer = call("PUT", base, moved)
    call.check("the move answers 200", status == 200, f"status {status}")
    status, layout = call("GET", base)
    after = {c["id"]: c for c in layout["categories"]}
    call.check("the target lists the channel", channel["id"] in (after[category_id].get("channel_ids") or []),
               str(after[category_id].get("channel_ids")))
    if source:
        call.check("and the category it left does not",
                   channel["id"] not in (after[source["id"]].get("channel_ids") or []),
                   f"{source['type']}: {short(after[source['id']].get('channel_ids'))}")

    # 5. reorder: sort_order inside the PUT is ignored, the order route is what reorders.
    print("\n5. reorder — do the two routes agree?")
    order_before = layout["order"]
    bumped = [dict(c, sort_order=(len(categories) - index) * 10) for index, c in enumerate(layout["categories"])]
    status, _ = call("PUT", base, bumped)
    status, layout = call("GET", base)
    call.check("sort_order alone does not reorder (the PUT keeps the server's order)",
               layout["order"] == order_before, f"{len(order_before)} categories, unchanged")
    target_order = list(order_before)
    if len(target_order) >= 2:
        target_order.insert(0, target_order.pop())          # last category to the front
    status, answer = call("PUT", base + "/order", target_order)
    call.check("PUT …/categories/order answers 200", status == 200, f"status {status}")
    status, layout = call("GET", base)
    call.check("and the server's order is the one we wrote",
               layout["order"] == target_order,
               f"{[c[:6] for c in layout['order'][:4]]}…")

    # 6. delete: the channels are not deleted, they go back to their defaults.
    print("\n6. delete the category — what happens to the channels in it?")
    status, _ = call("DELETE", base + "/" + category_id)
    call.check("DELETE answers 200", status == 200, f"status {status}")
    status, layout = call("GET", base)
    gone = all(c["id"] != category_id for c in layout["categories"])
    call.check("the category is gone from the layout", gone)
    call.check("its order entry is gone too", category_id not in layout["order"])
    status, still_there = call("GET", f"/channels/{channel['id']}")
    call.check("the channel itself was NOT deleted", status == 200 and still_there.get("delete_at", 0) == 0,
               f"status {status}")
    channels_default = next((c for c in layout["categories"] if c["type"] == "channels"), None)
    call.check("the channel is back in `channels`",
               channels_default is not None and channel["id"] in (channels_default.get("channel_ids") or []),
               short(channels_default.get("channel_ids") if channels_default else None))

    if dm is not None:
        print("\n7. the same for a direct message")
        status, created_dm = call("POST", base, {
            "user_id": me_id, "team_id": team_id, "display_name": "t19828e14 dm probe",
            "type": "custom", "sorting": "manual", "sort_order": 10, "channel_ids": [dm["id"]],
        })
        call.check("a category can be created holding a DM", 200 <= status < 300, f"status {status}")
        dm_category = created_dm["id"]
        status, layout = call("GET", base)
        call.check("the DM is in it",
                   any(c["id"] == dm_category and dm["id"] in (c.get("channel_ids") or [])
                       for c in layout["categories"]))
        status, _ = call("DELETE", base + "/" + dm_category)
        status, layout = call("GET", base)
        dm_default = next((c for c in layout["categories"] if c["type"] == "direct_messages"), None)
        call.check("the DM is back in `direct_messages`",
                   dm_default is not None and dm["id"] in (dm_default.get("channel_ids") or []),
                   short(dm_default.get("channel_ids") if dm_default else None))

    # 8. put the layout back the way we found it.
    print("\n8. restore the layout we started from")
    status, layout = call("GET", base)
    original = {c["id"]: c for c in before}
    restored = []
    for category in layout["categories"]:
        if category["id"] in original:
            restored.append(dict(category, channel_ids=list(original[category["id"]].get("channel_ids") or [])))
    if restored:
        call("PUT", base, restored)
        call("PUT", base + "/order", [c["id"] for c in before])
    status, restored_layout = call("GET", base)
    call.check("the original channel lists are back",
               all(set(c.get("channel_ids") or []) == set(original[c["id"]].get("channel_ids") or [])
                   for c in restored_layout["categories"] if c["id"] in original))

    print()
    if args.json:
        print(json.dumps({"failures": call.failures, "category_id": category_id}, indent=2))
    if call.failures:
        print(f"FAIL — {len(call.failures)} claim(s) did not hold: {call.failures}")
        return 1
    print("PASS — every category-management claim held against the pinned server")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
