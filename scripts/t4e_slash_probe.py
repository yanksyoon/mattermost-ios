#!/usr/bin/env python3
"""Probe (T4e): the slash-command endpoints and the socket frame their answers arrive on.

Measured on the dev fixture (9.11.19, 127.0.0.1:8065). What it establishes, for the card and for
`docs/t4e-build-note.md`:

  1. `GET /commands?team_id=` answers a **bare array** (not an envelope) with `auto_complete`,
     `auto_complete_hint`, `auto_complete_desc`;
  2. `GET /commands?team_id=` with an empty team is a **400** (`api.context.invalid_body_param`),
     which is why the client never asks without one;
  3. `/help` answers `200 {"response_type":"ephemeral","text":…}` and stores **no post**;
  4. the same answer is pushed on the websocket as `ephemeral_message` — **not** `posted` — with
     `data.post` a JSON string whose `type` is `system_ephemeral`;
  5. an unknown trigger is a **404 whose body carries the reader's sentence**
     ("Command with a trigger of 'x' not found…").

The websocket client here is deliberately minimal (RFC 6455 text frames) because this host has no
`websocket-client` and the security policy refuses to install one for an unattended run.

Usage:  python3 scripts/t4e_slash_probe.py [--server URL] [--login USER] [--password PASS]
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import socket
import struct
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


class WS:
    """Just enough RFC 6455 for a text-frame read loop (server→client frames are unmasked)."""

    def __init__(self, host: str, port: int, path: str):
        self.sock = socket.create_connection((host, port), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        request = (
            f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(request.encode())
        handshake = b""
        while b"\r\n\r\n" not in handshake:
            handshake += self.sock.recv(1)
        self.handshake = handshake.decode(errors="replace").splitlines()[0]

    def _exact(self, count: int) -> bytes:
        out = b""
        while len(out) < count:
            chunk = self.sock.recv(count - len(out))
            if not chunk:
                raise EOFError
            out += chunk
        return out

    def frame(self):
        first, second = self._exact(2)
        opcode = first & 0x0F
        masked = second & 0x80
        length = second & 0x7F
        if length == 126:
            length = struct.unpack(">H", self._exact(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self._exact(8))[0]
        mask = self._exact(4) if masked else b""
        payload = self._exact(length) if length else b""
        if masked:
            payload = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
        return opcode, payload

    def send_text(self, text: str):
        data = text.encode()
        header = bytearray([0x81])
        count = len(data)
        if count < 126:
            header.append(0x80 | count)
        elif count < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", count)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", count)
        mask = os.urandom(4)
        header += mask
        self.sock.sendall(bytes(header) + bytes(c ^ mask[i % 4] for i, c in enumerate(data)))

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", default="http://127.0.0.1:8065")
    parser.add_argument("--login", default="perfprobe")
    parser.add_argument("--password", default="PerfProbe-Not-A-Real-Secret-1")
    parser.add_argument("--channel", default="t35-composer")
    args = parser.parse_args()

    base = args.server.rstrip("/")
    api = base + "/api/v4"

    def call(method: str, path: str, token: str | None = None, body=None):
        data = json.dumps(body).encode() if body is not None else None
        headers = {"Content-Type": "application/json", "X-Requested-With": "XMLHttpRequest"}
        if token:
            headers["Authorization"] = "Bearer " + token
        request = urllib.request.Request(api + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = response.read()
                return (response.status,
                        json.loads(payload) if payload.strip() else None,
                        dict(response.headers))
        except urllib.error.HTTPError as error:
            return error.code, error.read().decode(errors="replace"), dict(error.headers)

    status, _, headers = call("POST", "/users/login",
                              body={"login_id": args.login, "password": args.password})
    token = headers.get("Token") or headers.get("token")
    if status != 200 or not token:
        print("login failed:", status)
        return 1
    status, me, _ = call("GET", "/users/me", token=token)
    print("login", status, "user", me["username"])

    _, teams, _ = call("GET", "/users/me/teams", token=token)
    team = next(t for t in teams if t["name"] == "perf")
    _, channels, _ = call("GET", f"/users/me/teams/{team['id']}/channels", token=token)
    channel = next(c for c in channels if c["name"] == args.channel)
    print("team", team["id"], "channel", channel["id"], channel["name"])

    # 1. The list.
    status, commands, _ = call("GET", f"/commands?team_id={team['id']}", token=token)
    print(f"\n1. GET /commands?team_id= -> {status}, {len(commands)} records, "
          f"type={type(commands).__name__}")
    for command in commands[:6]:
        print("   ", json.dumps({key: command.get(key) for key in
                                 ("trigger", "auto_complete", "auto_complete_hint",
                                  "auto_complete_desc", "display_name")}))
    print("   triggers:", ", ".join(sorted({c["trigger"] for c in commands})))

    # 2. No team: refused, so the client must never ask without one.
    status, body, _ = call("GET", "/commands?team_id=", token=token)
    print("\n2. GET /commands?team_id= (empty) ->", status,
          (json.loads(body)["message"] if isinstance(body, str) and body.startswith("{") else body))

    # 3+4. Execute /help while listening on the socket.
    host = urllib.parse.urlparse(base).hostname
    port = urllib.parse.urlparse(base).port or 80
    websocket = WS(host, port, "/api/v4/websocket")
    print("\n3. websocket:", websocket.handshake)
    websocket.send_text(json.dumps({"seq": 1, "action": "authentication_challenge",
                                    "data": {"token": token}}))
    events: list[dict] = []
    stop = False

    def reader():
        while not stop:
            try:
                opcode, payload = websocket.frame()
            except Exception:
                return
            if opcode == 0x1:
                try:
                    events.append(json.loads(payload.decode()))
                except ValueError:
                    pass

    threading.Thread(target=reader, daemon=True).start()
    time.sleep(1.5)

    status, answer, _ = call("POST", "/commands/execute", token=token,
                             body={"command": "/help", "channel_id": channel["id"],
                                   "team_id": team["id"]})
    print("   POST /commands/execute /help ->", status,
          "response_type=", answer.get("response_type"), "text_len=", len(answer.get("text", "")))
    print("   text:", repr(answer.get("text", "")[:160]))

    _, page, _ = call("GET", f"/channels/{channel['id']}/posts?per_page=5", token=token)
    stored = [page["posts"][pid]["message"][:40] for pid in page["order"]]
    print("   stored posts (newest first):", stored,
          "-> the answer is NOT stored" if not any("/help" in m for m in stored) else "")
    time.sleep(3)
    names = [event.get("event") for event in events]
    print("   socket events:", names)
    for event in events:
        if event.get("event") == "ephemeral_message":
            post = json.loads(event["data"]["post"])
            print("   ephemeral post: type=", post["type"], "channel=", post["channel_id"],
                  "user=", post["user_id"], "root=", repr(post["root_id"]))
            print("   message:", repr(post["message"][:160]))
            print("   broadcast.user_id:", event.get("broadcast", {}).get("user_id"))

    # 5. An unknown trigger: the 404 body is the sentence the reader must see.
    status, body, _ = call("POST", "/commands/execute", token=token,
                           body={"command": "/nosuchcommand", "channel_id": channel["id"],
                                 "team_id": team["id"]})
    message = json.loads(body).get("message") if isinstance(body, str) and body.startswith("{") else body
    print("\n5. POST /commands/execute /nosuchcommand ->", status)
    print("   message:", message)

    stop = True
    websocket.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
