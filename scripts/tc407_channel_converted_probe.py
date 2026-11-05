#!/usr/bin/env python3
"""t_c407645a probe — what the pinned 9.11.19 server actually emits when a conversation is converted.

The card (socket: a conversion on another client leaves the sidebar and pane stale) asks for the
event to be **measured before it is decoded**, and names `channel_converted`. This probe measures
the wire with live socket sessions, so the decode and the routing are written against what the
server sends rather than against the node client's handler:

  Case A — **a group message converted to a private channel** (the card's scenario)
      `t43buddy` (a second member of the conversation) and the actor both hold a WebSocket; the
      actor POSTs `/channels/{id}/convert_to_channel?team-id=…`; every frame either socket receives
      is dumped with its `event`, `data` keys, `broadcast` and arrival time relative to the answer.

  Case B — **a channel's privacy converted, public → private**
      A fresh public channel with buddy as a member; the actor PUTs `/channels/{id}/privacy`
      (`{"privacy": "P"}`) and the same dump is taken. This is the write that emits
      `channel_converted` on the server releases that have it (the event name upstream's
      `CHANNEL_CONVERTED` handler consumes), so the payload the decode must accept is measured
      here even when Case A does not produce that frame.

Both cases also answer whether the channel id survives (it does — t_d088f075 measured the REST
side), whether the converted channel is listed by the target team's `/users/me/teams/{t}/channels`
(the sidebar's read), and whether a conversion makes the sidebar's category layout move (the
`sidebar_category_updated` frame).

    uv run --with websockets python3 scripts/tc407_channel_converted_probe.py --url http://127.0.0.1:8065

Everything it creates is archived at the end. No token or credential is printed.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import time
import urllib.error
import urllib.request

ADMIN_LOGIN = "perfprobe"
ADMIN_PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
BUDDY_LOGIN = "t43buddy"
BUDDY_PASSWORD = "T43-Buddy-Not-A-Real-Secret-1"
# The third fixture member's password (scripts/t40_channel_seed.py), used only when that account is
# picked for the outsider socket.
MEMBER_LOGIN = "t40member"
MEMBER_PASSWORD = "T40-Member-Not-A-Real-Secret-1"

RUN = f"tc407{int(time.time())}"
# Frames this probe prints in full. Everything else is only counted ("N other frames").
DETAILED = {"channel_converted", "channel_updated", "channel_created", "channel_deleted"}
COMPACT = {"sidebar_category_updated", "channel_member_updated", "posted"}


class Client:
    def __init__(self, base: str) -> None:
        self.base = base.rstrip("/")
        self.token: str | None = None

    def call(self, method: str, path: str, body=None, query=None):
        url = f"{self.base}/api/v4{path}"
        if query:
            url += "?" + "&".join(f"{key}={value}" for key, value in query.items())
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                raw = response.read()
                return response.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as error:
            raw = error.read()
            try:
                payload = json.loads(raw or b"null")
            except ValueError:
                payload = raw.decode(errors="replace")
            return error.code, payload

    def login(self, login: str, password: str) -> dict:
        """Sign in and keep the `Token` header (9.11.19 answers the user; the token is a header)."""
        request = urllib.request.Request(
            f"{self.base}/api/v4/users/login",
            data=json.dumps({"login_id": login, "password": password}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                self.token = response.headers.get("Token")
                return json.loads(response.read())
        except urllib.error.HTTPError as error:
            raise SystemExit(f"login as {login} failed: HTTP {error.code} "
                             f"{error.read()[:200].decode(errors='replace')}")

    @property
    def ws_url(self) -> str:
        scheme = "wss" if self.base.startswith("https") else "ws"
        return self.base.replace("http://", scheme + "://") + "/api/v4/websocket"


async def authenticate(ws, token: str) -> None:
    await ws.send(json.dumps({"seq": 1, "action": "authentication_challenge",
                              "data": {"token": token}}))


async def collect(ws, seconds: float, started: float) -> list[dict]:
    """Every frame this socket delivers in the window, stamped with its arrival time."""
    frames: list[dict] = []
    loop = asyncio.get_running_loop()
    end = loop.time() + seconds
    while True:
        remaining = end - loop.time()
        if remaining <= 0:
            return frames
        try:
            raw = await asyncio.wait_for(ws.recv(), timeout=remaining)
        except asyncio.TimeoutError:
            return frames
        except Exception as error:  # a closed socket is an answer too
            frames.append({"event": "<socket-error>", "error": str(error)[:200],
                           "_t": round(loop.time() - started, 3)})
            return frames
        try:
            frame = json.loads(raw)
        except ValueError:
            frames.append({"event": "<unparseable>", "raw": str(raw)[:200],
                           "_t": round(loop.time() - started, 3)})
            continue
        frame["_t"] = round(loop.time() - started, 3)
        frames.append(frame)


def show_frame(who: str, frame: dict) -> None:
    event = frame.get("event", "?")
    when = frame.get("_t")
    if event in DETAILED:
        print(f"  {who} <- {event}   at +{when}s   broadcast={json.dumps(frame.get('broadcast'))}")
        data = frame.get("data")
        if isinstance(data, dict):
            print(f"     data keys: {sorted(data.keys())}")
            for key in sorted(data.keys()):
                value = data[key]
                text = json.dumps(value, ensure_ascii=False)
                print(f"     data[{key!r}] = {text}")
        else:
            print(f"     data = {json.dumps(data, ensure_ascii=False)}")
    elif event in COMPACT:
        data = frame.get("data")
        summary = json.dumps(data, ensure_ascii=False)
        if len(summary) > 220:
            summary = summary[:220] + f"… ({len(summary)} chars)"
        print(f"  {who} <- {event}   at +{when}s   data={summary}")
    else:
        print(f"  {who} <- {event} (not a channel frame; counted only)")


def default_port(base: str) -> int:
    return 443 if base.startswith("https") else 80


def list_channels(client: Client, teams: list[dict], channel_id: str) -> None:
    for candidate in teams:
        status, channels = client.call("GET", f"/users/me/teams/{candidate['id']}/channels")
        present = next((c for c in channels or [] if c["id"] == channel_id), None)
        print(f"    team {candidate['name']:<22} lists it: {present is not None}"
              f"{'  type=' + present['type'] if present else ''}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default=os.environ.get("MM_URL", "http://127.0.0.1:8065"))
    parser.add_argument("--buddy-password", default=BUDDY_PASSWORD)
    args = parser.parse_args()

    import websockets  # noqa: F401 — imported here so `--help` works without uv

    admin = Client(args.url)
    me = admin.login(ADMIN_LOGIN, ADMIN_PASSWORD)
    print(f"actor  {me['username']}  {me['id']}")
    buddy = Client(args.url)
    buddy_user = buddy.login(BUDDY_LOGIN, args.buddy_password)
    print(f"buddy  {buddy_user['username']}  {buddy_user['id']}")

    status, teams = admin.call("GET", "/users/me/teams")
    if status != 200 or not teams:
        raise SystemExit(f"no teams for the fixture account: HTTP {status} {teams}")
    team = teams[0]
    print(f"team   {team['name']}  {team['id']}")

    status, people = admin.call("GET", "/users", query={"in_team": team["id"], "per_page": 200})
    others = [p for p in (people or []) if p["id"] not in (me["id"], buddy_user["id"])]
    third = others[0]
    print(f"third  {third['username']}  {third['id']}")

    # An account that is in the team but will not be in the conversation: does the frame leak?
    outsider = None
    for candidate in others[1:]:
        if candidate["username"] == MEMBER_LOGIN:
            outsider = candidate
            break

    # ---------------------------------------------------------------- Case A: GM → private
    status, group = admin.call("POST", "/channels/group",
                               body=[buddy_user["id"], third["id"]])
    if status not in (200, 201):
        raise SystemExit(f"could not create the group message: HTTP {status} {group}")
    gm_id = group["id"]
    print(f"\n=== Case A: group message {gm_id} (type {group.get('type')}) converted to a channel")
    print("before:")
    list_channels(admin, teams, gm_id)

    async def case_a() -> None:
        import websockets

        async with websockets.connect(admin.ws_url, max_size=8 * 1024 * 1024) as actor_ws, \
                   websockets.connect(admin.ws_url, max_size=8 * 1024 * 1024) as buddy_ws:
            await authenticate(actor_ws, admin.token or "")
            await authenticate(buddy_ws, buddy.token or "")
            await collect(actor_ws, 2.0, 0.0)      # hello
            await collect(buddy_ws, 2.0, 0.0)

            stamp = int(time.time())
            name = f"{RUN}gm"
            display = f"TC407 GM {stamp}"
            print(f"\n  POST /channels/{gm_id}/convert_to_channel?team-id={team['id']}"
                  f"  name={name} display_name={display!r}")
            started = asyncio.get_running_loop().time()
            status, converted = await asyncio.to_thread(
                admin.call, "POST", f"/channels/{gm_id}/convert_to_channel",
                {"channel_id": gm_id, "team_id": team["id"],
                 "display_name": display, "name": name},
                {"team-id": team["id"]})
            answered = asyncio.get_running_loop().time() - started
            print(f"  answer HTTP {status} at +{answered:.3f}s  type={converted.get('type')} "
                  f"id={converted.get('id')} team_id={converted.get('team_id')} "
                  f"name={converted.get('name')}")
            if status != 200:
                print(f"  body: {json.dumps(converted)[:400]}")
                return

            for who, ws in (("actor", actor_ws), ("buddy", buddy_ws)):
                frames = await collect(ws, 2.0, started)
                print(f"\n  [{who}] {len(frames)} frames")
                for frame in frames:
                    if frame.get("event") != "hello":
                        show_frame(who, frame)
                seen = sorted({f.get("event") for f in frames if f.get("event") in DETAILED})
                print(f"  {who} saw channel frames: {seen or 'none'}")
            print(f"  (HTTP answer arrived at +{answered:.3f}s)")

    asyncio.run(case_a())

    status, fetched = admin.call("GET", f"/channels/{gm_id}")
    if isinstance(fetched, dict):
        print(f"\nafter: GET /channels/{gm_id} -> HTTP {status} type={fetched.get('type')} "
              f"team_id={fetched.get('team_id')} name={fetched.get('name')} "
              f"display_name={fetched.get('display_name')}")
    list_channels(admin, teams, gm_id)

    # ---------------------------------------------------------------- Case B: privacy O → P
    print(f"\n=== Case B: a public channel's privacy converted to private (channel_converted)")
    stamp = int(time.time())
    status, public = admin.call("POST", "/channels",
                                {"team_id": team["id"], "name": f"{RUN}priv",
                                 "display_name": f"TC407 privacy {stamp}", "type": "O"})
    if status not in (200, 201):
        print(f"  could not create a public channel: HTTP {status} {json.dumps(public)[:300]}")
        public_id = None
    else:
        public_id = public["id"]
        print(f"  channel {public_id} created (type {public.get('type')})")
        admin.call("POST", f"/channels/{public_id}/members",
                   {"user_id": buddy_user["id"]})

        async def case_b() -> None:
            import websockets

            async with websockets.connect(admin.ws_url, max_size=8 * 1024 * 1024) as actor_ws, \
                       websockets.connect(admin.ws_url, max_size=8 * 1024 * 1024) as buddy_ws:
                await authenticate(actor_ws, admin.token or "")
                await authenticate(buddy_ws, buddy.token or "")
                await collect(actor_ws, 2.0, 0.0)
                await collect(buddy_ws, 2.0, 0.0)

                print(f"\n  PUT /channels/{public_id}/privacy {{\"privacy\": \"P\"}}")
                started = asyncio.get_running_loop().time()
                status, answer = await asyncio.to_thread(
                    admin.call, "PUT", f"/channels/{public_id}/privacy", {"privacy": "P"})
                answered = asyncio.get_running_loop().time() - started
                print(f"  answer HTTP {status} at +{answered:.3f}s  type={answer.get('type') if isinstance(answer, dict) else answer}")
                for who, ws in (("actor", actor_ws), ("buddy", buddy_ws)):
                    frames = await collect(ws, 2.0, started)
                    print(f"\n  [{who}] {len(frames)} frames")
                    for frame in frames:
                        if frame.get("event") != "hello":
                            show_frame(who, frame)
                    seen = sorted({f.get("event") for f in frames if f.get("event") in DETAILED})
                    print(f"  {who} saw channel frames: {seen or 'none'}")

        asyncio.run(case_b())

        status, fetched = admin.call("GET", f"/channels/{public_id}")
        print(f"\nafter: GET /channels/{public_id} -> HTTP {status} "
              f"type={fetched.get('type') if isinstance(fetched, dict) else '?'}")
        status, _ = admin.call("DELETE", f"/channels/{public_id}")
        print(f"cleanup DELETE /channels/{public_id} -> HTTP {status}")

    # ---------------------------------------------------------------- Case C: non-member
    if outsider is not None:
        print(f"\n=== Case C: is the frame delivered to a team member who is NOT in the conversation?")
        outsider_client = Client(args.url)
        try:
            outsider_user = outsider_client.login(outsider["username"], MEMBER_PASSWORD)
        except SystemExit:
            print(f"  {outsider['username']} could not sign in with the fixture password — skipped")
            outsider_client = None
        if outsider_client is not None:
            print(f"  outsider {outsider_user['username']} {outsider_user['id']}")

            async def case_c() -> None:
                import websockets

                async with websockets.connect(admin.ws_url, max_size=8 * 1024 * 1024) as actor_ws, \
                           websockets.connect(admin.ws_url, max_size=8 * 1024 * 1024) as outsider_ws:
                    await authenticate(actor_ws, admin.token or "")
                    await authenticate(outsider_ws, outsider_client.token or "")
                    await collect(actor_ws, 2.0, 0.0)
                    await collect(outsider_ws, 2.0, 0.0)
                    # A conversation the outsider is not in, converted by the actor.
                    status, fresh = admin.call("POST", "/channels/group",
                                               body=[buddy_user["id"], third["id"]])
                    if status not in (200, 201):
                        print(f"  could not create the group: HTTP {status}")
                        return
                    fresh_id = fresh["id"]
                    started = asyncio.get_running_loop().time()
                    status, _ = await asyncio.to_thread(
                        admin.call, "POST", f"/channels/{fresh_id}/convert_to_channel",
                        {"channel_id": fresh_id, "team_id": team["id"],
                         "display_name": f"TC407 outsider {stamp}", "name": f"{RUN}out"},
                        {"team-id": team["id"]})
                    print(f"  conversion HTTP {status}")
                    for who, ws in (("actor", actor_ws), ("outsider", outsider_ws)):
                        frames = await collect(ws, 2.0, started)
                        seen = sorted({f.get("event") for f in frames if f.get("event") in DETAILED})
                        print(f"  {who} saw channel frames: {seen or 'none'} ({len(frames)} frames)")
                    admin.call("DELETE", f"/channels/{fresh_id}")

            asyncio.run(case_c())
    else:
        print("\n=== Case C skipped: no non-member fixture account with a known password")

    status, _ = admin.call("DELETE", f"/channels/{gm_id}")
    print(f"\ncleanup DELETE /channels/{gm_id} -> HTTP {status}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
