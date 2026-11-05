#!/usr/bin/env python3
"""t_c407645a: reproduce (or rule out) the 403 the live UI test hit on `convert_to_channel`.

The UI test signs in as the fixture account, then converts the conversation **from its own REST
session** while the app is signed in as the same account. Its POST answered HTTP 403
`api.context.permissions.app_error`, while the websocket probe's identical call answered 200. This
script isolates the difference with two sequential attempts on throwaway conversations:

  A. a fresh login token, converting a GM created in the same session (what the probe does);
  B. a *second* login for the same account while A's token is still unused, converting with A's token
     (what the UI test does: the app signs in after the test's token was minted).

It creates and deletes only conversations it makes itself.

Usage: scripts/tc407_convert_403_probe.py
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request

SERVER = "http://127.0.0.1:8065"
LOGIN = "perfprobe"
PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
TEAM = "ocz148uck3r88dcjikj497bosh"


def call(method: str, path: str, token: str | None = None, body=None):
    payload = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(SERVER + path, data=payload, method=method)
    if token:
        request.add_header("Authorization", "Bearer " + token)
    if payload:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=20) as answer:
            raw = answer.read()
            return answer.status, (json.loads(raw) if raw else None), answer.headers.get("Token")
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()[:300], None


def login() -> tuple[str, str]:
    status, user, token = call("POST", "/api/v4/users/login",
                               body={"login_id": LOGIN, "password": PASSWORD})
    if status != 200 or not token:
        raise SystemExit("login failed: %s %s" % (status, user))
    return token, user["id"]


def make_gm(token: str, me: str) -> str:
    status, users, _ = call("GET", f"/api/v4/users?in_team={TEAM}&per_page=50", token)
    others = [u["id"] for u in users if u["id"] != me and not u.get("delete_at")][:2]
    status, channel, _ = call("POST", "/api/v4/channels/group", token, body=[me] + others)
    print("  created GM:", status, channel.get("id") if isinstance(channel, dict) else channel)
    return channel["id"]


def convert(token: str, channel_id: str, tag: str) -> None:
    name = f"tc407{tag}{int(__import__('time').time())}"
    status, answer, _ = call("POST",
                             f"/api/v4/channels/{channel_id}/convert_to_channel?team-id={TEAM}",
                             token,
                             body={"display_name": "TC407 " + tag, "name": name})
    print("  convert ->", status, answer if status != 200 else
          {k: answer.get(k) for k in ("id", "type", "team_id", "name")})


def main() -> int:
    print("A: one session (the probe's shape)")
    token_a, me = login()
    channel = make_gm(token_a, me)
    convert(token_a, channel, "a")
    call("DELETE", f"/api/v4/channels/{channel}", token_a)

    print("B: two sessions, converting with the first (the UI test's shape)")
    token_b, _ = login()
    channel = make_gm(token_b, me)
    second, _ = login()  # what the app does when it signs in
    print("  second login while the first token is live: ok")
    convert(token_b, channel, "b")
    call("DELETE", f"/api/v4/channels/{channel}", token_b)

    print("C: converting with the *newest* token (is it the token, or the account?)")
    channel = make_gm(second, me)
    convert(second, channel, "c")
    call("DELETE", f"/api/v4/channels/{channel}", second)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
