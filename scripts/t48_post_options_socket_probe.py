#!/usr/bin/env python3
"""T48 probe #3 — which socket frames each post-options write publishes.

Runs against the throwaway 9.11.19 fixture. Needs a websocket client:

    uv run --with websockets python3 scripts/t48_post_options_socket_probe.py

Prints the frame name and the `data` keys for each write, so the Swift socket patches are grounded in
this server's behaviour rather than in the documentation. No token or credential is printed.
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("MM_PROBE_SERVER", "http://127.0.0.1:8065")
LOGIN = os.environ.get("MM_PROBE_LOGIN", "perfprobe")
PASSWORD = os.environ.get("MM_PROBE_PASSWORD", "")
SECOND_LOGIN = os.environ.get("MM_PROBE_SECOND_LOGIN", "t36reply")
SECOND_PASSWORD = os.environ.get("MM_PROBE_SECOND_PASSWORD", "T36Reply-Not-A-Real-Secret-1")


def call(method, path, token=None, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + "/api/v4" + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            raw = r.read()
            if path == "/users/login":
                return r.status, {"session": json.loads(raw), "token": r.headers.get("Token", "")}
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            parsed = json.loads(raw)
        except Exception:
            parsed = raw.decode(errors="replace")
        return e.code, parsed


def login(login_id, password):
    status, answer = call("POST", "/users/login", body={"login_id": login_id, "password": password})
    return status, answer["token"], answer["session"]["id"]


async def main() -> int:
    if not PASSWORD:
        print("set MM_PROBE_PASSWORD", file=sys.stderr)
        return 2
    import websockets

    _, token, uid = login(LOGIN, PASSWORD)
    _, tok2, uid2 = login(SECOND_LOGIN, SECOND_PASSWORD)
    _, teams = call("GET", "/users/me/teams", token)
    perf = next(t for t in teams if t["name"] == "perf")
    tid = perf["id"]
    _, ch = call("GET", f"/teams/{tid}/channels/name/t36-threads", token)
    cid = ch["id"]

    ws_url = BASE.replace("http://", "ws://").replace("https://", "wss://") + "/api/v4/websocket"
    frames: list[dict] = []

    async with websockets.connect(ws_url, max_size=8 * 1024 * 1024) as ws:
        await ws.send(json.dumps({"seq": 1, "action": "authentication_challenge",
                                  "data": {"token": token}}))

        async def collect(seconds: float) -> list[dict]:
            got = []
            try:
                async with asyncio.timeout(seconds):
                    while True:
                        raw = await ws.recv()
                        frame = json.loads(raw)
                        if frame.get("event") in ("hello", "status_change", "typing"):
                            continue
                        got.append(frame)
            except (asyncio.TimeoutError, TimeoutError):
                pass
            return got

        await asyncio.sleep(0.5)

        # One real root with one reply (a thread row exists only once it has replies).
        _, root = call("POST", "/posts", token, {"channel_id": cid, "message": "t48 socket root"})
        rid = root["id"]
        _, reply = call("POST", "/posts", tok2, {"channel_id": cid, "message": "t48 socket reply",
                                                 "root_id": rid})
        await collect(1.0)

        async def probe(label: str, func, seconds: float = 2.5):
            before = len(frames)
            func()
            got = await collect(seconds)
            print(f"\n== {label}: {len(got)} frame(s)")
            for frame in got:
                data = frame.get("data") or {}
                if isinstance(data, str):
                    try:
                        data = json.loads(data)
                    except Exception:
                        pass
                keys = sorted(data.keys()) if isinstance(data, dict) else type(data).__name__
                print("  ", frame.get("event"), "| broadcast:", frame.get("broadcast"), "| data keys:", keys)
                if frame.get("event") == "post_edited" and isinstance(data, dict):
                    raw_post = data.get("post") or data.get("post_json")
                    if isinstance(raw_post, str):
                        try:
                            p = json.loads(raw_post)
                            print("      post.is_pinned =", p.get("is_pinned"), "update_at =", p.get("update_at"))
                        except Exception:
                            pass
            frames.extend(got)

        await probe("pin", lambda: call("POST", f"/posts/{rid}/pin", token))
        await probe("unpin", lambda: call("POST", f"/posts/{rid}/unpin", token))
        await probe("save (flagged_post preference)", lambda: call(
            "PUT", f"/users/{uid}/preferences", token,
            [{"user_id": uid, "category": "flagged_post", "name": rid, "value": "true"}]))
        await probe("unsave", lambda: call(
            "POST", f"/users/{uid}/preferences/delete", token,
            [{"user_id": uid, "category": "flagged_post", "name": rid, "value": "true"}]))
        await probe("mark unread (post route)", lambda: call(
            "POST", f"/users/{uid}/posts/{rid}/set_unread", token,
            {"collapsed_threads_supported": True}))
        await probe("follow thread", lambda: call(
            "PUT", f"/users/me/teams/{tid}/threads/{rid}/following", token, {}))
        await probe("unfollow thread", lambda: call(
            "DELETE", f"/users/me/teams/{tid}/threads/{rid}/following", token))
    print("\n(read state afterwards:", call("GET", f"/channels/{cid}/members/me", token)[1].get("last_viewed_at"), ")")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
