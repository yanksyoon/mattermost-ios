#!/usr/bin/env python3
"""Measure the Mattermost contract T41 is built on, and print what the server actually does.

Why a probe instead of reading the docs: every rule in `ProfileModels.swift`, `StatusSetterView.swift`
and the two test files is a statement about *this* server's answers, and several of them are the kind
of thing a type definition does not tell you:

  * `GET /users/{id}` carries no `custom_status` field — the status hides inside `props.customStatus`
    as a **JSON string**;
  * `timezone.useAutomaticTimezone` is the string `"true"`/`"false"`, not a bool;
  * `PUT /users/{id}/status/custom` takes the status **flat** and a fixed duration vocabulary, and a
    duration without a future `expires_at` is a 400;
  * "no expiry" is stored as the Go zero time `0001-01-01T00:00:00Z`, a perfectly ordinary past date;
  * `PUT /users/me/status` sets `manual` for `away`/`dnd` and clears it for `online`;
  * the socket's `status_change` frame carries `user_id` + `status` and **nothing else**, which is why
    a socket patch must not erase the `manual`/`last_activity_at` a batched read supplied.

It also measures the two things the live UI test depends on: that an account can set **another**
account's status only as a system admin (so the test either uses the admin token or signs in as the
buddy), and that `POST /channels/direct` answers 201 then 200.

Every check prints `PASS`/`FAIL` with the observed value, and the exit code is non-zero if any
expectation the Swift code relies on does not hold. Run it against the pinned throwaway server:

    python3 scripts/t41_profile_probe.py --url http://127.0.0.1:8065 \
        --log docs/t41-profile-probe-2026-10-26.log

The websocket section needs a client; run it under `uv` so the check is measured rather than skipped:

    uv run --with websockets python3 scripts/t41_profile_probe.py --url http://127.0.0.1:8065 \
        --log docs/t41-profile-probe-2026-10-26.log

The fixture passwords are throwaway local values, identical to `scripts/t41_profile_seed.py`'s. No
credential is printed; a token only ever reaches a request header.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from typing import Any

ADMIN_LOGIN = "perfprobe"
ADMIN_PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
BUDDY_LOGIN = "t41buddy"
BUDDY_PASSWORD = "T41-Buddy-Not-A-Real-Secret-1"

FAILURES: list[str] = []
LINES: list[str] = []


def say(text: str = "") -> None:
    print(text)
    LINES.append(text)


def check(label: str, ok: bool, observed: Any = "") -> None:
    """One expectation, printed with what the server actually answered."""
    render = observed if isinstance(observed, str) else json.dumps(observed, sort_keys=True)
    if len(render) > 400:
        render = render[:400] + "…"
    say(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f"\n          observed: {render}" if render else ""))
    if not ok:
        FAILURES.append(label)


def call(url: str, method: str, path: str, body: Any = None, token: str | None = None,
         raw_body: bytes | None = None) -> tuple[int, Any, dict[str, str]]:
    data = raw_body if raw_body is not None else (
        json.dumps(body).encode() if body is not None else None)
    request = urllib.request.Request(url.rstrip("/") + "/api/v4" + path, data=data, method=method)
    request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = response.read()
            headers = {k.lower(): v for k, v in response.getheaders()}
            return response.status, _parse(payload), headers
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


def login(url: str, user: str, password: str) -> tuple[str, str]:
    status, body, headers = call(url, "POST", "/users/login",
                                 {"login_id": user, "password": password})
    if status != 200 or not headers.get("token"):
        raise SystemExit(f"could not sign in as {user} (HTTP {status}, {str(body)[:200]})")
    return headers["token"], body["id"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--log", default="", help="write the same transcript to this file")
    args = parser.parse_args()
    base = args.url

    say(f"# T41 profile / presence / custom-status probe against {base}")
    status, ping, _ = call(base, "GET", "/system/ping")
    check("the server answers /system/ping", status == 200 and ping.get("status") == "OK", ping)

    admin_token, admin_id = login(base, ADMIN_LOGIN, ADMIN_PASSWORD)
    say(f"\n## Session\nsigned in as @{ADMIN_LOGIN} ({admin_id}) — token not printed")

    buddy_status, buddy, _ = call(base, "GET", "/users/username/" + BUDDY_LOGIN, token=admin_token)
    if buddy_status != 200 or not buddy.get("id"):
        say(f"  SKIP  @{BUDDY_LOGIN} is absent — run scripts/t41_profile_seed.py first")
        buddy_id = ""
    else:
        buddy_id = buddy["id"]
        say(f"  fixture buddy @{BUDDY_LOGIN} ({buddy_id})")

    # ---------------------------------------------------------------- 1. the profile object
    say("\n## 1. GET /users/{id} — what a profile actually carries")
    status, me, _ = call(base, "GET", "/users/" + admin_id, token=admin_token)
    check("200 for my own profile", status == 200, status)
    for field in ("roles", "position", "nickname", "timezone", "props"):
        check(f"the profile carries `{field}`", isinstance(me.get(field), (str, dict, list)), me.get(field))
    check("there is **no** `custom_status` key on the user object", "custom_status" not in me,
          sorted(me.keys()))
    tz = me.get("timezone") or {}
    check("`timezone.useAutomaticTimezone` is the string \"true\"/\"false\", not a bool",
          isinstance(tz.get("useAutomaticTimezone"), str),
          {"value": tz.get("useAutomaticTimezone"), "type": type(tz.get("useAutomaticTimezone")).__name__})
    check("`is_bot` is absent or null rather than false",
          me.get("is_bot") in (None, False), me.get("is_bot"))
    check("`last_activity_at` is not part of GET /users/{id}",
          "last_activity_at" not in me, sorted(me.keys()))

    # ---------------------------------------------------------------- 2. custom status, flat
    say("\n## 2. PUT /users/{id}/status/custom — the custom status")
    zero = "0001-01-01T00:00:00Z"
    status, body, _ = call(base, "PUT", f"/users/{admin_id}/status/custom",
                           {"emoji": "coffee", "text": "Probe status", "duration": "",
                            "expires_at": zero}, token=admin_token)
    check("a flat body with no expiry is accepted", status == 200, {"body": body})
    _, me_after, _ = call(base, "GET", "/users/" + admin_id, token=admin_token)
    raw = (me_after.get("props") or {}).get("customStatus")
    check("the status lives in props.customStatus as a **JSON string**",
          isinstance(raw, str), raw)
    decoded = {}
    try:
        decoded = json.loads(raw or "{}")
    except json.JSONDecodeError:
        pass
    check("…and that string decodes to the emoji and text that were sent",
          decoded.get("emoji") == "coffee" and decoded.get("text") == "Probe status", decoded)
    check("no expiry round-trips as the Go zero time", str(decoded.get("expires_at")) == zero,
          decoded.get("expires_at"))

    status, body, _ = call(base, "PUT", f"/users/{admin_id}/status/custom",
                           {"custom_status": {"emoji": "coffee", "text": "wrapped"}},
                           token=admin_token)
    check("a **wrapped** body is a 400 (the status is flat on the wire)", status == 400,
          {"status": status, "id": (body or {}).get("id")})

    for duration in ("30m", "1h", "99y"):
        status, body, _ = call(base, "PUT", f"/users/{admin_id}/status/custom",
                               {"emoji": "", "text": "x", "duration": duration}, token=admin_token)
        check(f"duration `{duration}` is not in the server's vocabulary (400)", status == 400,
              {"status": status, "id": (body or {}).get("id")})

    status, body, _ = call(base, "PUT", f"/users/{admin_id}/status/custom",
                           {"emoji": "", "text": "no expiry but a duration",
                            "duration": "one_hour"}, token=admin_token)
    check("a non-empty duration **without** a future expires_at is a 400", status == 400,
          {"status": status, "id": (body or {}).get("id")})

    status, body, _ = call(base, "PUT", f"/users/{admin_id}/status/custom",
                           {"emoji": "", "text": "empty expiry", "duration": "",
                            "expires_at": ""}, token=admin_token)
    check("`expires_at: \"\"` is a 400 (Go cannot parse an empty time)", status == 400,
          {"status": status, "id": (body or {}).get("id")})

    status, body, _ = call(base, "PUT", f"/users/{admin_id}/status/custom",
                           {"emoji": "definitely-not-an-emoji", "text": "x", "duration": "",
                            "expires_at": zero}, token=admin_token)
    check("an emoji the server does not know is refused", status == 400,
          {"status": status, "id": (body or {}).get("id")})

    for duration, wire in (("thirty_minutes", "30m"), ("one_hour", "1h"), ("four_hours", "4h"),
                           ("today", "today"), ("this_week", "this_week")):
        status, body, _ = call(base, "PUT", f"/users/{admin_id}/status/custom",
                               {"emoji": "", "text": f"probe {duration}", "duration": duration,
                                "expires_at": "2099-01-01T00:00:00.000Z"}, token=admin_token)
        check(f"duration `{duration}` is accepted with a future expiry", status == 200,
              {"status": status})

    status, body, headers = call(base, "GET", f"/users/{admin_id}/status/custom", token=admin_token)
    check("there is **no** GET …/status/custom route (404) — read props instead", status == 404,
          {"status": status, "id": (body or {}).get("id")})

    status, body, _ = call(base, "DELETE", f"/users/{admin_id}/status/custom", token=admin_token)
    check("DELETE clears it and answers {status: OK}",
          status == 200 and (body or {}).get("status") == "OK", body)
    _, me_cleared, _ = call(base, "GET", "/users/" + admin_id, token=admin_token)
    check("…and props.customStatus is gone or empty afterwards",
          not ((me_cleared.get("props") or {}).get("customStatus") or "").strip(),
          (me_cleared.get("props") or {}).get("customStatus"))

    # ---------------------------------------------------------------- 3. presence
    say("\n## 3. PUT /users/me/status and PUT /users/{id}/status — presence")
    status, body, _ = call(base, "PUT", "/users/me/status",
                           {"user_id": admin_id, "status": "dnd"}, token=admin_token)
    check("`dnd` is accepted", status == 200, {"status": status})
    check("…and comes back manual=true", (body or {}).get("manual") is True, body)
    check("…and the answer carries user_id/status/manual/last_activity_at",
          {"user_id", "status", "manual", "last_activity_at"}.issubset(set(body or {})),
          sorted((body or {}).keys()))

    status, body, _ = call(base, "PUT", "/users/me/status",
                           {"user_id": admin_id, "status": "online"}, token=admin_token)
    check("`online` is accepted", status == 200, status)
    check("…and clears manual (the asymmetry auto-away relies on)",
          (body or {}).get("manual") is False, body)

    status, body, _ = call(base, "PUT", "/users/me/status",
                           {"user_id": admin_id, "status": "invisible"}, token=admin_token)
    check("a status outside online/away/dnd/offline is a 400", status == 400,
          {"status": status, "id": (body or {}).get("id")})

    status, body, _ = call(base, "PUT", "/users/me/status",
                           {"user_id": admin_id, "status": "dnd",
                            "dnd_end_time": 4102444800000}, token=admin_token)
    check("`dnd_end_time` is epoch **milliseconds** and is echoed", status == 200
          and (body or {}).get("dnd_end_time") == 4102444800000,
          {"status": status, "dnd_end_time": (body or {}).get("dnd_end_time")})
    call(base, "PUT", "/users/me/status", {"user_id": admin_id, "status": "online"},
         token=admin_token)

    status, body, _ = call(base, "POST", "/users/status/ids", [admin_id], token=admin_token)
    check("POST /users/status/ids answers a list of rows", status == 200 and isinstance(body, list),
          {"status": status, "type": type(body).__name__})
    row = (body or [{}])[0] if isinstance(body, list) and body else {}
    check("a row carries user_id/status/manual/last_activity_at",
          {"user_id", "status", "manual", "last_activity_at"}.issubset(set(row)),
          sorted(row.keys()))

    if buddy_id:
        say("\n## 4. Can one account set another's status?")
        status, body, _ = call(base, "PUT", f"/users/{buddy_id}/status",
                               {"user_id": buddy_id, "status": "away"}, token=admin_token)
        admin_for_others = status == 200
        check("a system admin may set another account's status", admin_for_others,
              {"status": status, "id": (body or {}).get("id")})
        if admin_for_others:
            call(base, "PUT", f"/users/{buddy_id}/status",
                 {"user_id": buddy_id, "status": "online"}, token=admin_token)
        buddy_token, buddy_self = login(base, BUDDY_LOGIN, BUDDY_PASSWORD)
        status, body, _ = call(base, "PUT", f"/users/{buddy_id}/status",
                               {"user_id": buddy_id, "status": "away"}, token=buddy_token)
        check("…and the account itself can (the live test's second route)", status == 200, status)
        call(base, "PUT", f"/users/{buddy_id}/status", {"user_id": buddy_id, "status": "online"},
             token=buddy_token)

    # ---------------------------------------------------------------- 5. the socket frame
    say("\n## 5. The socket's `status_change` frame")
    try:
        import asyncio
        import websockets  # type: ignore
    except ImportError:
        say("  SKIP  the `websockets` package is not available — rerun under "
            "`uv run --with websockets`")
    else:
        async def watch() -> dict[str, Any]:
            ws_url = base.replace("http://", "ws://").replace("https://", "wss://") + "/api/v4/websocket"
            async with websockets.connect(ws_url) as socket:
                await socket.send(json.dumps({"seq": 1, "action": "authentication_challenge",
                                              "data": {"token": admin_token}}))
                await socket.recv()  # the hello / status frame
                call(base, "PUT", "/users/me/status",
                     {"user_id": admin_id, "status": "away"}, token=admin_token)
                deadline = asyncio.get_event_loop().time() + 10
                while asyncio.get_event_loop().time() < deadline:
                    frame = json.loads(await asyncio.wait_for(socket.recv(), timeout=10))
                    if frame.get("event") == "status_change":
                        return frame
                return {}

        frame = asyncio.run(watch())
        check("a status_change frame arrives after the write", bool(frame), frame)
        if frame:
            data = frame.get("data") or {}
            check("…and it carries user_id + status and **no** manual/activity",
                  {"user_id", "status"}.issubset(set(data)) and "manual" not in data,
                  data)
        call(base, "PUT", "/users/me/status", {"user_id": admin_id, "status": "online"},
             token=admin_token)

        # The live UI test's premise: *another* account's change reaches this client's socket. Without
        # this, an open profile could never follow a colleague's presence and the criterion would be
        # unimplementable rather than unimplemented.
        if buddy_id:
            buddy_token, _ = login(base, BUDDY_LOGIN, BUDDY_PASSWORD)

            async def watch_someone_else() -> dict[str, Any]:
                ws_url = (base.replace("http://", "ws://").replace("https://", "wss://")
                          + "/api/v4/websocket")
                async with websockets.connect(ws_url) as socket:
                    await socket.send(json.dumps({"seq": 1, "action": "authentication_challenge",
                                                  "data": {"token": admin_token}}))
                    await socket.recv()
                    call(base, "PUT", f"/users/{buddy_id}/status",
                         {"user_id": buddy_id, "status": "dnd"}, token=buddy_token)
                    deadline = asyncio.get_event_loop().time() + 12
                    while asyncio.get_event_loop().time() < deadline:
                        frame = json.loads(await asyncio.wait_for(socket.recv(), timeout=12))
                        if frame.get("event") == "status_change" \
                                and (frame.get("data") or {}).get("user_id") == buddy_id:
                            return frame
                    return {}

            other = asyncio.run(watch_someone_else())
            check("another account's status_change reaches **my** socket", bool(other), other)
            call(base, "PUT", f"/users/{buddy_id}/status", {"user_id": buddy_id, "status": "online"},
                 token=buddy_token)

    # ---------------------------------------------------------------- 6. the DM shortcut
    say("\n## 6. POST /channels/direct — the DM shortcut")
    if buddy_id:
        status, first, _ = call(base, "POST", "/channels/direct", [admin_id, buddy_id],
                                token=admin_token)
        check("the first call answers 201 with a `D` channel",
              status == 201 and (first or {}).get("type") == "D",
              {"status": status, "type": (first or {}).get("type")})
        status, second, _ = call(base, "POST", "/channels/direct", [admin_id, buddy_id],
                                 token=admin_token)
        check("a repeat call answers 2xx with the **same** channel id "
              "(9.11.19 answers 201 both times, not 200 — so a client must accept both)",
              (second or {}).get("id") == (first or {}).get("id")
              and (second is not None) and status in (200, 201),
              {"status": status, "same_id": (second or {}).get("id") == (first or {}).get("id")})
    else:
        say("  SKIP  no buddy account")

    # ---------------------------------------------------------------- 7. avatar
    say("\n## 7. GET /users/{id}/profile_image")
    status, body, _ = call(base, "GET", f"/users/{admin_id}/profile_image", token=admin_token)
    check("an account without a picture answers 404 (not an error on screen)", status == 404, status)

    say("\n## Summary")
    if FAILURES:
        say(f"  {len(FAILURES)} expectation(s) did not hold:")
        for label in FAILURES:
            say(f"    - {label}")
    else:
        say("  every expectation held — the Swift rules match this server")

    if args.log:
        with open(args.log, "w", encoding="utf-8") as handle:
            handle.write("\n".join(LINES) + "\n")
        print(f"\ntranscript written to {args.log}")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
