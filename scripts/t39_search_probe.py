#!/usr/bin/env python3
"""T39 — measure the search / saved / pinned contract against the real server.

The card's platform asks for facts, not documentation: "verify current path against
api.mattermost.com — the saved-posts path has moved between server versions; record which server
version you verified against". So this probe asks the server, records the exact status codes it
answered with, and prints them. It is the source of the path table in
`docs/t39-search-build-note.md` §2.

What it measures:

  1. Server version (`GET /config/client` Version/BuildNumber).
  2. `POST /teams/{team_id}/posts/search` — the body (`terms`, `is_or_search`, `page`, `per_page`,
     `include_deleted_channels`, `time_zone_offset`) and the answer shape (`order`, `posts`,
     `matches`, `next_post_id`/`prev_post_id`).
  3. Which search modifiers the server parses server-side (`from:`, `in:`, `before:`, `after:`,
     `on:`, quoted phrases, wildcards) and what each narrows the result set to.
  4. What an **invalid** query answers (`before:notadate`, an unterminated quote, an unknown
     `x:` modifier) — the client has to show a readable error, so this is the case that decides
     whether the error comes from the server or has to be detected locally.
  5. The saved-posts path: every candidate the API docs or older servers have used, with its
     status code, so the client pins the one this server actually answers.
  6. The pinned-posts path (`GET /channels/{id}/pinned`) and the pin/unpin/flag/unflag writes.

Usage (throwaway local server; the credentials are the fixture account from `scripts/perf_seed.py`):

    python3 scripts/t39_search_probe.py
    python3 scripts/t39_search_probe.py --url http://127.0.0.1:8065 --login perfprobe --password ...

Exit code 0 = every fact the client depends on still holds.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request

OK = "PASS"
FAIL = "FAIL"


class Probe:
    def __init__(self, base_url: str, token: str):
        self.base = base_url.rstrip("/") + "/api/v4"
        self.token = token
        self.failures: list[str] = []

    # -- transport ---------------------------------------------------------

    def call(self, method: str, path: str, body=None):
        """(status, payload) — never raises on an HTTP error status."""
        data = None
        headers = {"Authorization": "Bearer " + self.token,
                   "X-Requested-With": "XMLHttpRequest"}
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base + path, method=method,
                                         data=data, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read()
                try:
                    return response.status, json.loads(raw)
                except json.JSONDecodeError:
                    return response.status, raw
        except urllib.error.HTTPError as error:  # noqa: PERF203 - one case per status
            raw = error.read()
            try:
                return error.code, json.loads(raw)
            except json.JSONDecodeError:
                return error.code, raw

    def expect(self, label: str, condition: bool, detail: str) -> None:
        print(f"[{OK if condition else FAIL}] {label}: {detail}")
        if not condition:
            self.failures.append(label)


def login(base_url: str, login_id: str, password: str) -> tuple[str, str]:
    """9.x answers the session token in the `Token:` response header, not the body."""
    request = urllib.request.Request(
        base_url.rstrip("/") + "/api/v4/users/login",
        method="POST",
        data=json.dumps({"login_id": login_id, "password": password}).encode(),
        headers={"Content-Type": "application/json",
                 "X-Requested-With": "XMLHttpRequest"})
    with urllib.request.urlopen(request, timeout=20) as response:
        token = response.headers.get("Token")
        body = json.loads(response.read())
    if not token:
        raise SystemExit("login returned no Token header")
    return token, body["id"]


def post_ids(payload) -> list[str]:
    if not isinstance(payload, dict):
        return []
    return [pid for pid in (payload.get("order") or []) if isinstance(pid, str)]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--login", default="perfprobe@example.invalid")
    parser.add_argument("--password", default="PerfProbe-Not-A-Real-Secret-1")
    parser.add_argument("--team", default="perf")
    parser.add_argument("--channel", default="t34-showcase")
    args = parser.parse_args()

    token, user_id = login(args.url, args.login, args.password)
    probe = Probe(args.url, token)

    # -- 1. version --------------------------------------------------------
    status, config = probe.call("GET", "/config/client?format=old")
    version = config.get("Version") if isinstance(config, dict) else None
    build = config.get("BuildNumber") if isinstance(config, dict) else None
    print(f"\n== server: Version={version} BuildNumber={build} (status {status})\n")
    probe.expect("config/client", status == 200 and bool(version), f"Version={version}")

    # -- 2. the team and channel the probe searches in ---------------------
    status, teams = probe.call("GET", "/users/me/teams")
    team = next((t for t in teams if t.get("name") == args.team), None) if isinstance(teams, list) else None
    if not team:
        print(f"[{FAIL}] team #{args.team} is missing — run scripts/perf_seed.py")
        return 1
    team_id = team["id"]

    status, channels = probe.call("GET", f"/users/me/teams/{team_id}/channels")
    channel = next((c for c in channels if c.get("name") == args.channel), None) if isinstance(channels, list) else None
    if not channel:
        print(f"[{FAIL}] channel #{args.channel} is missing — run scripts/t34_post_seed.py")
        return 1
    channel_id = channel["id"]

    # -- 3. the search endpoint and its answer shape -----------------------
    # `from:<my own username>` is the fixture's "many results" query: the seed account authored
    # every post this probe reads, so it gives a list worth paging through. A bare word would be
    # at the mercy of the full-text backend's stopword list (measured: "the" answers 0 ids on this
    # 9.11.19 database backend, while the same word inside a phrase matches 2).
    body = {"terms": f"from:{args.login.split('@')[0]}",
            "is_or_search": False,
            "page": 0,
            "per_page": 30,
            "include_deleted_channels": False,
            "time_zone_offset": 0}
    status, page0 = probe.call("POST", f"/teams/{team_id}/posts/search", body)
    probe.expect("POST /teams/{team}/posts/search", status == 200 and isinstance(page0, dict),
                 f"status={status} keys={sorted(page0) if isinstance(page0, dict) else page0}")
    order0 = post_ids(page0)
    probe.expect("search answer carries order/posts", len(order0) > 0 and bool(page0.get("posts")),
                 f"{len(order0)} ids, {len(page0.get('posts') or {})} posts, "
                 f"matches={len(page0.get('matches') or {})}, "
                 f"has_next={page0.get('has_next')!r}, next_post_id={page0.get('next_post_id')!r}")

    # Paging. Measured on 9.11.19 (database backend): **one capped window per query** — `page=1`
    # answers nothing and `has_next` is false. That is exactly the case the client's rule is built for
    # ("a short or empty page ends the window"), and it is why `SearchResultWindow` never offers a
    # Load more the server cannot answer. A switch to an Elasticsearch backend (where paging *is*
    # honoured) shows up here as a different shape, so this asserts the shape rather than "paging
    # works": it is a measurement of this server, not a wish.
    _, page1_payload = probe.call("POST", f"/teams/{team_id}/posts/search", {**body, "page": 1})
    page1 = page1_payload if isinstance(page1_payload, dict) else {}
    order1 = post_ids(page1)
    single_window = not order1 or page1.get("has_next") is False
    probe.expect("paging shape matches the client's rule (single capped window)",
                 single_window,
                 f"page1={len(order1)} ids, overlap={len(set(order0) & set(order1))}, "
                 f"has_next={page1.get('has_next')!r} — a single window means an empty page 1 with "
                 f"has_next false")

    # `per_page` is sent, and documented as Elasticsearch-only. The database backend caps the window
    # at 100 whatever is asked (measured), which is why the client trusts the *answer's* length and
    # says so on screen when it hit the cap.
    sizes = {}
    for size in (3, 10, 200, 500):
        status, payload = probe.call("POST", f"/teams/{team_id}/posts/search",
                                     {**body, "per_page": size})
        sizes[size] = (status, len(post_ids(payload)))
        print(f"    per_page={size:<4} status={status} ids={sizes[size][1]}")
    probe.expect("search per_page is not honoured by this backend (window cap 100)",
                 sizes[3][0] == 200 and sizes[500][1] <= 100,
                 f"per_page=3 -> {sizes[3][1]} ids, per_page=500 -> {sizes[500][1]} ids")

    # -- 4. the modifier grammar (server-side) ----------------------------
    probes = [
        ("baseline 'the'", {"terms": "the"}),
        ("from:perfprobe", {"terms": "from:perfprobe"}),
        ("in:<channel name>", {"terms": f"in:{args.channel}"}),
        ("after:<date>", {"terms": "after:2000-01-01"}),
        ("before:<date>", {"terms": "before:2999-01-01"}),
        ("on:<date>", {"terms": "on:2000-01-01"}),
        ("quoted phrase", {"terms": '"the quick"'}),
        ("wildcard", {"terms": "the*"}),
        ("OR search", {"terms": "the OR quick", "is_or_search": True}),
    ]
    results = {}
    for label, override in probes:
        status, payload = probe.call("POST", f"/teams/{team_id}/posts/search",
                                     {**body, **override})
        results[label] = (status, len(post_ids(payload)) if status == 200 else None)
        print(f"    modifier {label:<24} status={status} ids={results[label][1]}")
    probe.expect("every documented modifier is accepted (200)",
                 all(status == 200 for status, _ in results.values()),
                 f"{sum(1 for s, _ in results.values() if s == 200)}/{len(results)} answered 200")

    # -- 5. invalid queries: what the *server* does with them ---------------
    invalid = [
        ("bad date", {"terms": "before:notadate"}),
        ("unterminated quote", {"terms": '"the quick'}),
        ("unknown modifier", {"terms": "x:whatever"}),
        ("empty terms", {"terms": ""}),
        ("bad regex char", {"terms": "the("}),
    ]
    invalid_results = {}
    for label, override in invalid:
        status, payload = probe.call("POST", f"/teams/{team_id}/posts/search",
                                     {**body, **override})
        message = payload.get("message") if isinstance(payload, dict) else None
        invalid_results[label] = (status, message)
        print(f"    invalid {label:<20} status={status} message={message!r} "
              f"ids={len(post_ids(payload)) if status == 200 else '-'}")
    print("    ^ a 200 with 0 ids means the *client* owns the error copy for that case")

    # -- 6. saved posts: every candidate path ------------------------------
    saved_candidates = [
        ("GET", f"/users/me/teams/{team_id}/posts/saved?page=0&per_page=30"),
        ("GET", f"/users/me/posts/flagged?team_id={team_id}&page=0&per_page=30"),
        ("GET", f"/users/me/posts/flagged?page=0&per_page=30"),
        ("GET", f"/teams/{team_id}/posts/flagged?page=0&per_page=30"),
        ("GET", f"/users/{user_id}/posts/flagged?team_id={team_id}&page=0&per_page=30"),
    ]
    saved_status = {}
    for method, path in saved_candidates:
        status, payload = probe.call(method, path)
        ids = len(post_ids(payload)) if status == 200 else None
        saved_status[path] = status
        print(f"    saved {method} {path:<62} status={status} ids={ids if ids is not None else '-'}"
              f"{'  msg=' + repr(payload.get('message')) if status != 200 and isinstance(payload, dict) else ''}")
    working_saved = [p for p, s in saved_status.items() if s == 200]
    probe.expect("one saved-posts path answers", bool(working_saved),
                 f"working: {working_saved}")

    # -- 7. pinned posts ---------------------------------------------------
    status, pinned = probe.call("GET", f"/channels/{channel_id}/pinned")
    probe.expect("GET /channels/{id}/pinned", status == 200 and isinstance(pinned, dict),
                 f"status={status} keys={sorted(pinned) if isinstance(pinned, dict) else pinned}")

    # -- 8. the writes: pin / unpin, then the *save* path -------------------
    #
    # `POST /posts/{id}/flag` and `/unflag` are what the REST reference suggests, but they answer
    # **404** on 9.11.19: saving a post is a preference (`flagged_post` = post id), not a post write.
    # That is why `SearchAPI.savePost` PUTs `/users/{id}/preferences` and unsaves with
    # `/users/{id}/preferences/delete` — measured here, not assumed from the docs.
    target = order0[0] if order0 else None
    if target is None:
        print(f"[{FAIL}] no post to exercise the writes on")
        return 1
    for label, method, path in [
        ("pin", "POST", f"/posts/{target}/pin"),
        ("pinned-list sees it", "GET", f"/channels/{channel_id}/pinned"),
        ("unpin", "POST", f"/posts/{target}/unpin"),
    ]:
        status, payload = probe.call(method, path)
        extra = ""
        if label == "pinned-list sees it" and status == 200:
            extra = f" contains target={target in post_ids(payload)}"
        print(f"    write {label:<22} {method} {path:<50} status={status}{extra}")
        if label in {"pin", "unpin"}:
            probe.expect(f"write {label}", status == 200, f"status={status}")

    # The rows a result names: one batched lookup, the same request the search screen sends.
    status, channels = probe.call("POST", f"/teams/{team_id}/channels/ids", [channel_id])
    described = channels if isinstance(channels, list) else []
    probe.expect("POST /teams/{team}/channels/ids (result subtitles)",
                 status == 200 and any((c or {}).get("id") == channel_id for c in described),
                 f"status={status} channels={len(described)}")

    # The save path the client uses: preference in, flagged list sees it, preference delete, gone.
    preference = [{"user_id": user_id, "category": "flagged_post",
                   "name": target, "value": "true"}]
    status, _ = probe.call("PUT", f"/users/{user_id}/preferences", preference)
    probe.expect("save a post: PUT /users/{id}/preferences", status == 200, f"status={status}")
    status, flagged = probe.call("GET", f"/users/me/posts/flagged?team_id={team_id}&page=0&per_page=30")
    probe.expect("the saved list sees the preference", status == 200 and target in post_ids(flagged),
                 f"status={status} contains target={target in post_ids(flagged)}")
    status, _ = probe.call("POST", f"/users/{user_id}/preferences/delete", preference)
    probe.expect("unsave: POST /users/{id}/preferences/delete", status == 200, f"status={status}")
    status, flagged = probe.call("GET", f"/users/me/posts/flagged?team_id={team_id}&page=0&per_page=30")
    probe.expect("the saved list drops the unsaved post",
                 status == 200 and target not in post_ids(flagged),
                 f"status={status} still contains target={target in post_ids(flagged)}")

    # Recorded, not asserted: the documented-but-absent endpoints, so nobody "fixes" the client back
    # onto them without seeing why they are not used.
    for label, path in [("flag", f"/posts/{target}/flag"), ("unflag", f"/posts/{target}/unflag")]:
        status, _ = probe.call("POST", path)
        print(f"    absent {label:<20} POST {path:<50} status={status} (not used by the client)")

    print()
    if probe.failures:
        print(f"RESULT: FAIL ({len(probe.failures)}): {probe.failures}")
        return 1
    print(f"RESULT: PASS — measured on Mattermost {version} (BuildNumber {build})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
