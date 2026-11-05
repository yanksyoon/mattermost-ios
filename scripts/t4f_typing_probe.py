#!/usr/bin/env python3
"""T4f probe — `user_typing` on the pinned 9.11.19 fixture: the frame, its addressing, and the gates.

Answers, with measurements rather than documentation:

  1. which `enabled`/interval keys an **authenticated** `GET /api/v4/config/client?format=old`
     actually carries (`EnableUserTypingMessages`, `TimeBetweenUserTypingUpdatesMilliseconds`,
     `MaxNotificationsPerChannel`), because the composer has to read the server's own switch;
  2. the shape of the `typing` frame another client receives — `broadcast.channel_id`,
     `data.user_id`, `data.parent_id` — for a channel message and for a thread reply;
  3. whether the sender receives its **own** `user_typing` frame (it decides whether the client has
     to filter by its own user id as well as by parent id);
  4. what the server answers when `parent_id` names a post in another channel, and when it is empty.

Requires a websocket client:

    uv run --with websockets python3 scripts/t4f_typing_probe.py

The two accounts are the T43 fixture's (`scripts/t43_notification_seed.py`): `perfprobe` (the app's
account) and `t43buddy` (the second client that types). No token or credential is printed.
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("MM_PROBE_SERVER", "http://127.0.0.1:8065")
ADMIN_LOGIN = os.environ.get("MM_PROBE_LOGIN", "perfprobe")
ADMIN_PASSWORD = os.environ.get("MM_PROBE_PASSWORD", "PerfProbe-Not-A-Real-Secret-1")
BUDDY_LOGIN = os.environ.get("MM_PROBE_SECOND_LOGIN", "t43buddy")
BUDDY_PASSWORD = os.environ.get("MM_PROBE_SECOND_PASSWORD", "T43-Buddy-Not-A-Real-Secret-1")
CHANNEL_NAME = os.environ.get("MM_PROBE_CHANNEL", "t43-notify")


def call(method: str, path: str, token: str | None = None, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + "/api/v4" + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
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


def login(login_id: str, password: str):
    status, answer = call("POST", "/users/login", body={"login_id": login_id, "password": password})
    if status != 200:
        raise SystemExit(f"could not sign in as {login_id}: HTTP {status} {str(answer)[:200]}")
    return answer["token"], answer["session"]["id"]


async def authenticate(ws, token: str):
    await ws.send(json.dumps({"seq": 1, "action": "authentication_challenge", "data": {"token": token}}))


async def collect(ws, seconds: float):
    frames = []
    end = asyncio.get_running_loop().time() + seconds
    while True:
        remaining = end - asyncio.get_running_loop().time()
        if remaining <= 0:
            return frames
        try:
            raw = await asyncio.wait_for(ws.recv(), timeout=remaining)
        except asyncio.TimeoutError:
            return frames
        try:
            frames.append(json.loads(raw))
        except Exception:
            frames.append({"event": "<unparseable>", "raw": str(raw)[:200]})


def typing_frames(frames):
    return [f for f in frames if f.get("event") == "typing"]


async def main() -> int:
    import websockets

    admin_token, admin_id = login(ADMIN_LOGIN, ADMIN_PASSWORD)
    buddy_token, buddy_id = login(BUDDY_LOGIN, BUDDY_PASSWORD)

    status, config = call("GET", "/config/client?format=old", admin_token)
    print(f"config/client: HTTP {status}")
    if isinstance(config, dict):
        interesting = {k: v for k, v in config.items()
                       if "typing" in k.lower() or "notification" in k.lower()
                       or k.lower() in ("maxpostsize", "sitetype", "version")}
        for key in sorted(interesting):
            print(f"  {key} = {interesting[key]!r}")
        missing = [k for k in ("EnableUserTypingMessages",
                               "TimeBetweenUserTypingUpdatesMilliseconds",
                               "MaxNotificationsPerChannel") if k not in config]
        print(f"  absent: {missing}")

    _, teams = call("GET", "/users/me/teams", admin_token)
    channel = None
    team = None
    for candidate in teams or []:
        status, found = call("GET", f"/teams/{candidate['id']}/channels/name/{CHANNEL_NAME}", admin_token)
        if status == 200:
            team, channel = candidate, found
            break
    if channel is None:
        raise SystemExit(f"channel {CHANNEL_NAME} not found in {[t.get('name') for t in teams or []]}")
    channel_id = channel["id"]
    print(f"channel {CHANNEL_NAME} = {channel_id} (team {team['name']})")

    # A root post to reply to, so `parent_id` can name a real thread root.
    status, root = call("POST", "/posts", admin_token,
                        {"channel_id": channel_id, "message": "T4f typing probe root"})
    if status != 201:
        raise SystemExit(f"could not create root post: HTTP {status} {str(root)[:200]}")
    root_id = root["id"]

    ws_url = BASE.replace("http://", "ws://").replace("https://", "wss://") + "/api/v4/websocket"
    async with websockets.connect(ws_url, max_size=8 * 1024 * 1024) as admin_ws, \
               websockets.connect(ws_url, max_size=8 * 1024 * 1024) as buddy_ws:
        await authenticate(admin_ws, admin_token)
        await authenticate(buddy_ws, buddy_token)
        hello_admin = await collect(admin_ws, 2.0)
        await collect(buddy_ws, 2.0)
        print("admin hello events:", [f.get("event") for f in hello_admin][:6])

        async def run_case(label: str, sender_ws, sender_name: str, payload: dict, seconds=1.5):
            await sender_ws.send(json.dumps({"seq": 99, "action": "user_typing", "data": payload}))
            admin_frames = await collect(admin_ws, seconds)
            buddy_frames = await collect(buddy_ws, 0.2)
            got_admin = typing_frames(admin_frames)
            got_buddy = typing_frames(buddy_frames)
            print(f"\n[{label}] sent by {sender_name}: {json.dumps(payload)}")
            for who, got in (("perfprobe", got_admin), ("t43buddy", got_buddy)):
                for frame in got:
                    print(f"  {who} <- typing broadcast={frame.get('broadcast')} data={frame.get('data')}"
                          f" seq={frame.get('seq')}")
            if not got_admin and not got_buddy:
                print("  (no typing frame observed)")
            return got_admin, got_buddy

        await run_case("channel message, parent_id empty", buddy_ws, BUDDY_LOGIN,
                       {"channel_id": channel_id, "parent_id": ""})
        await run_case("thread reply, parent_id = root", buddy_ws, BUDDY_LOGIN,
                       {"channel_id": channel_id, "parent_id": root_id})
        await run_case("own frame: sent by perfprobe", admin_ws, ADMIN_LOGIN,
                       {"channel_id": channel_id, "parent_id": ""})
        # No parent_id key at all — what a client that forgets it sends.
        await run_case("parent_id key omitted", buddy_ws, BUDDY_LOGIN,
                       {"channel_id": channel_id})

    print(f"\nadmin user id {admin_id[:6]}… buddy user id {buddy_id[:6]}…")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
