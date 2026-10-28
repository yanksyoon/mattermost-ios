#!/usr/bin/env python3
"""Seed the fixture that T39's `time_zone_offset` test anchors on.

Why this exists (T39-R2, card `t_c3957991`): the shipped live test
`T39JumpUITests.testOnDateModifierSendsTheTimezoneOffsetInSeconds` asked the server the same `on:`
question twice — once with the reader's offset in **seconds** (the unit the API reads) and once in
**minutes** (the unit T39 shipped) — on *the newest post's day*, and required the two answers to
differ. That anchor was a property of the wall clock and of whatever else had been posted into
`#t34-showcase` that day, so as the fixture grew the day stopped separating the encodings:
T55-AV-R measured `in:t34-showcase on:2026-10-27` answering **2 posts at −25200 s and 2 at −420**
(`build/logs/t55/t55-tz-separation.log`, note §3.4 F-5). The test then `XCTSkip`s on its own
premise, which reads as "not measured", and a green run can mean nothing at all.

So the anchor becomes a property of *this fixture*:

  * a dedicated channel, `#t39-anchor`, holding exactly the posts this script writes;
  * a fixed day, `ANCHOR_DAY`, written into each post's `create_at` — the server honors a
    client-supplied `create_at` on `POST /posts` for a `system_admin` account (measured on
    9.11.19: asked 1793423400000, read back 1793423400000), so the day no longer moves;
  * the posts are placed where the two encodings **must** disagree: inside the reader's local day
    *and* outside the window a client sending `offset / 60` would ask for. For a whole-hour offset
    O, that band is `|O − O/60|` seconds wide and sits just after midnight UTC for an eastern
    offset and in the evening for a western one; this script computes it rather than assuming.

`MattermostUITests/T39JumpUITests.swift` holds the same two constants (`offsetAnchorChannel`,
`offsetAnchorDay`); change them together. Run it before the suite, idempotently:

    python3 scripts/t39_offset_anchor_seed.py --url http://127.0.0.1:8065
    python3 scripts/t39_offset_anchor_seed.py --url http://127.0.0.1:8065 --tz-offset-seconds -18000

The default offset is this host's current one; pass the runner's explicitly if they differ. The
script prints the two counts the test will assert on and exits non-zero if the fixture does not
separate them.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
import urllib.error
import urllib.request

USERNAME = "perfprobe"
PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
TEAM_NAME = "perf"

# Must match `offsetAnchorChannel` / `offsetAnchorDay` in MattermostUITests/T39JumpUITests.swift.
CHANNEL_NAME = "t39-anchor"
ANCHOR_DAY = "2026-10-26"

# Three posts, so a count of 3 vs 0 cannot be a coincidence of one row moving.
SLOT_FRACTIONS = (0.25, 0.5, 0.75)


class APIError(RuntimeError):
    pass


class Client:
    def __init__(self, base: str, token: str | None = None):
        self.base = base.rstrip("/")
        self.token = token

    def call(self, method: str, path: str, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(f"{self.base}/api/v4{path}", data=data, method=method)
        req.add_header("Content-Type", "application/json")
        req.add_header("X-Requested-With", "XMLHttpRequest")
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                payload = resp.read()
                return resp.status, (json.loads(payload) if payload.strip() else None), \
                    {k.lower(): v for k, v in resp.headers.items()}
        except urllib.error.HTTPError as exc:
            payload = exc.read()
            try:
                decoded = json.loads(payload)
            except Exception:
                decoded = payload.decode(errors="replace")
            return exc.code, decoded, {k.lower(): v for k, v in exc.headers.items()}

    def must(self, method: str, path: str, body=None):
        status, payload, headers = self.call(method, path, body)
        if status >= 300:
            raise APIError(f"{method} {path} -> {status}: {payload}")
        return payload, headers


def login(base: str, login_id: str, password: str) -> Client:
    status, payload, headers = Client(base).call("POST", "/users/login",
                                                 {"login_id": login_id, "password": password})
    if status != 200 or not headers.get("token"):
        raise APIError(f"login as {login_id} failed: {status} {payload}")
    return Client(base, headers["token"])


def day_start_ms(day: str) -> int:
    """Epoch milliseconds of `day` 00:00:00 **UTC**."""
    parsed = dt.datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=dt.timezone.utc)
    return int(parsed.timestamp() * 1000)


def separating_band_ms(day: str, offset_seconds: int) -> tuple[int, int]:
    """The `[lo, hi)` epoch-ms window that is inside the reader's local day and outside the day a
    client sending `offset_seconds / 60` would ask for.

    The server turns `on:<day>` plus `time_zone_offset` into `[start, start + 24h)` where
    `start = day 00:00 UTC − time_zone_offset`. With the offset in seconds the window is
    `[S, S + 24h)`; with the same number read as minutes it is `[M, M + 24h)`. The part of the
    seconds window the minutes window misses is therefore `[S, M)` when S < M (an eastern offset,
    just after local midnight) and `[M + 24h, S + 24h)` when S > M (a western offset, late in the
    local evening). Both are `|S − M| = |O − O/60|` wide — hours, for a real time zone.
    """
    start_of_day = day_start_ms(day)
    seconds_window = start_of_day - offset_seconds * 1000
    minutes_window = start_of_day - (offset_seconds // 60) * 1000
    daily = 24 * 60 * 60 * 1000
    if seconds_window < minutes_window:
        return seconds_window, minutes_window
    return minutes_window + daily, seconds_window + daily


def ensure_channel(client: Client, team_id: str) -> dict:
    status, payload, _ = client.call("GET", f"/teams/{team_id}/channels/name/{CHANNEL_NAME}")
    if status == 200:
        return payload
    payload, _ = client.must("POST", "/channels", {
        "team_id": team_id, "name": CHANNEL_NAME, "display_name": "T39 offset anchor",
        "type": "O",
        "purpose": ("Fixture for T39's time_zone_offset test: posts on a fixed day, inside the "
                    "reader's local day and outside the UTC-day reading of it. See "
                    "scripts/t39_offset_anchor_seed.py."),
        "header": ""})
    print(f"created channel #{CHANNEL_NAME} ({payload['id']})")
    return payload


def channel_posts(client: Client, channel_id: str) -> list[dict]:
    payload, _ = client.must("GET", f"/channels/{channel_id}/posts?per_page=200")
    posts = payload.get("posts") or {}
    return [posts[pid] for pid in payload.get("order", []) if pid in posts]


def search_count(client: Client, team_id: str, terms: str, offset: int) -> int:
    payload, _ = client.must("POST", f"/teams/{team_id}/posts/search", {
        "terms": terms, "is_or_search": False, "time_zone_offset": offset,
        "page": 0, "per_page": 60, "include_deleted_channels": True})
    return len(payload.get("order") or [])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--login", default=USERNAME)
    parser.add_argument("--password", default=PASSWORD)
    parser.add_argument("--tz-offset-seconds", type=int, default=None,
                        help="the test runner's offset east of UTC in seconds (default: this host's)")
    args = parser.parse_args()

    host_offset = int((dt.datetime.now().astimezone().utcoffset() or dt.timedelta()).total_seconds())
    offset = host_offset if args.tz_offset_seconds is None else args.tz_offset_seconds
    print(f"anchor day {ANCHOR_DAY}, reader offset {offset}s "
          f"(minutes encoding would be {offset // 60})")
    if offset == 0 or offset % 3600 != 0:
        print("  note: a UTC or non-whole-hour offset cannot separate the two encodings; the test "
              "skips for that reason, not this fixture's.")

    client = login(args.url, args.login, args.password)
    me, _ = client.must("GET", "/users/me")
    teams, _ = client.must("GET", "/users/me/teams")
    team = next((t for t in teams or [] if t["name"] == TEAM_NAME), (teams or [None])[0])
    if not team:
        raise APIError(f"{args.login} is in no team")
    print(f"account {me.get('username')} (roles: {me.get('roles')}), team {team['name']}")

    channel = ensure_channel(client, team["id"])
    lo, hi = separating_band_ms(ANCHOR_DAY, offset)
    existing = channel_posts(client, channel["id"])
    by_key = {(p.get("props") or {}).get("t39_anchor_key"): p for p in existing}

    seeded = 0
    for index, fraction in enumerate(SLOT_FRACTIONS, start=1):
        wanted = int(lo + (hi - lo) * fraction)
        key = f"anchor-{index}"
        have = by_key.get(key)
        if have is not None and have.get("create_at") == wanted:
            print(f"  {key}: reused post {have['id']} at {wanted}")
            continue
        if have is not None:
            # The band moved (a different offset, or DST): replace rather than stack duplicates.
            client.call("DELETE", f"/posts/{have['id']}")
            print(f"  {key}: removed stale post {have['id']} (create_at {have.get('create_at')})")
        post, _ = client.must("POST", "/posts", {
            "channel_id": channel["id"],
            "message": f"t39 offset anchor {index} — on the reader's day {ANCHOR_DAY}",
            "create_at": wanted,
            "props": {"t39_anchor_key": key, "t39_anchor_day": ANCHOR_DAY,
                      "t39_seed": "t39_offset_anchor_seed.py"}})
        if post.get("create_at") != wanted:
            raise APIError(f"the server did not honor create_at: asked {wanted}, "
                           f"got {post.get('create_at')} — the anchor cannot be a fixture day")
        seeded += 1
        print(f"  {key}: created post {post['id']} at {wanted}")

    terms = f"in:{CHANNEL_NAME} on:{ANCHOR_DAY}"
    seconds = search_count(client, team["id"], terms, offset)
    minutes = search_count(client, team["id"], terms, offset // 60)
    print(f"\n{terms}: seconds {seconds}, minutes {minutes}, created {seeded}, "
          f"reused {len(SLOT_FRACTIONS) - seeded}")
    if seconds == minutes:
        print("FAIL: the fixture does not separate the two encodings — the test would skip on its "
              "own premise. Re-run with the runner's real --tz-offset-seconds.")
        return 1
    if seconds != len(SLOT_FRACTIONS):
        print(f"FAIL: expected {len(SLOT_FRACTIONS)} posts on the reader's day, the server answers "
              f"{seconds} — something else is posting into #{CHANNEL_NAME}.")
        return 1
    print("OK: the anchor day separates the encodings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
