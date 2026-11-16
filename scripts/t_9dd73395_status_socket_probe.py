#!/usr/bin/env python3
"""Does a status I set reach my own socket — i.e. the sidebar's DM rows? (t_9dd73395 requirement 3)

The account menu writes `PUT /users/{id}/status`. Requirement 3 asks that the new status "takes
effect immediately in … the sidebar's DM rows". That store (`SidebarPresenceStore`) is fed two ways
on this build: a batched `POST /users/status/ids` read, and the socket's `status_change` frame
applied in place by `ChannelSidebarService.handle(_:myUserID:)` when the account is one the list
tracks (`directParticipants`). A DM with yourself lists you as a participant, so "my own row follows
my own write" depends entirely on whether the server echoes the change back to the session that
made it.

Two sessions are opened, because a client's own echo and a broadcast to other accounts are different
questions:

  A  session 1 (the "reader") puts `dnd` with an end time     → does session 2 see `status_change`?
  B  session 2 puts `online`                                  → does session 1 see `status_change`?
  C  session 1 puts `away`                                    → does session 1 (itself) see it?

Case C is the one the sidebar needs; A/B are the controls that separate "the server never broadcasts
this" from "the server does not echo to the writer".

Run against the throwaway 9.11.19 fixture, which needs a websocket client:

    uv run --with websockets python3 scripts/t_9dd73395_status_socket_probe.py

Credential from `MM_PROBE_PASSWORD` (dev-only fixture, as in the other probes).
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ.get("MM_PROBE_SERVER", "http://127.0.0.1:8065")
LOGIN = os.environ.get("MM_PROBE_LOGIN", "perfprobe")
PASSWORD = os.environ.get("MM_PROBE_PASSWORD", "PerfProbe-Not-A-Real-Secret-1")


def call(method, path, token=None, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + "/api/v4" + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            raw = resp.read()
            if path == "/users/login":
                return resp.status, {"session": json.loads(raw), "token": resp.headers.get("Token", "")}
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read() or b"null")


def login():
    status, answer = call("POST", "/users/login", body={"login_id": LOGIN, "password": PASSWORD})
    if status != 200:
        raise SystemExit(f"login failed: HTTP {status}")
    return answer["token"], answer["session"]["id"]


async def open_socket(token):
    import websockets
    url = BASE.replace("http://", "ws://").replace("https://", "wss://") + "/api/v4/websocket"
    ws = await websockets.connect(url, max_size=8 * 1024 * 1024)
    await ws.send(json.dumps({"seq": 1, "action": "authentication_challenge",
                              "data": {"token": token}}))
    return ws


async def drain(ws, seconds):
    frames = []
    try:
        async with asyncio.timeout(seconds):
            while True:
                frame = json.loads(await ws.recv())
                if frame.get("event") == "status_change":
                    data = frame.get("data") or {}
                    if isinstance(data, str):
                        data = json.loads(data)
                    frames.append((data.get("user_id"), data.get("status")))
    except (asyncio.TimeoutError, TimeoutError):
        pass
    return frames


async def main() -> int:
    token1, uid = login()
    token2, _ = login()
    ws1, ws2 = await open_socket(token1), await open_socket(token2)
    await asyncio.sleep(0.7)
    await drain(ws1, 0.2)
    await drain(ws2, 0.2)

    now = int(time.time())

    async def case(label, ws_watch, method, body_list):
        frames = await drain(ws_watch, 0.01)  # clear
        del frames
        for body in body_list:
            print(f"  PUT {body}", call("PUT", f"/users/{uid}/status", token1, body)[0])
        got = await drain(ws_watch, 2.0)
        mine = [f for f in got if f[0] == uid]
        print(f"{label:<52} status_change frames: {got}  (mine: {len(mine)})")
        return mine

    print(f"user {uid}\n")

    mine2 = await case("A  session2 watches, session1 writes dnd+1h",
                       ws2, "PUT", [{"user_id": uid, "status": "dnd",
                                     "dnd_end_time": now + 3600}])
    mine1 = await case("B  session1 watches, session1 writes online",
                       ws1, "PUT", [{"user_id": uid, "status": "online"}])
    mine1b = await case("C  session1 watches again, session1 writes away",
                        ws1, "PUT", [{"user_id": uid, "status": "away"}])

    print()
    print("A (another session sees my change):", "yes" if mine2 else "NO")
    print("B (my own session sees my change):  ", "yes" if mine1 else "NO")
    print("C (repeat, to be sure):             ", "yes" if mine1b else "NO")

    await ws1.close()
    await ws2.close()
    call("PUT", f"/users/{uid}/status", token1, {"user_id": uid, "status": "online"})
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
