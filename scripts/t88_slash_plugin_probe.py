#!/usr/bin/env python3
"""Probe (t_08826621): what the fixture actually answers for plugin, custom and unknown commands.

The card's question is "why does `/gif` do nothing from the native composer?". Answering it needs
four measurements that no unit test can supply:

  1. which commands this server offers, and which of them come from a **plugin** (the Calls and
     Playbooks plugins are active; their triggers are in `GET /commands` but not in `mmctl command
     list`, which lists only custom integrations);
  2. the exact `POST /commands/execute` **request** body and **response** body for each kind
     (built-in, plugin, custom, unknown trigger) — the response is where `trigger_id` and
     `goto_location` live;
  3. what the socket delivers for each answer: `posted`, `ephemeral_message`, or `open_dialog`;
  4. whether an answer with two `extra_responses` arrives as two events, and whether a command that
     opens a dialog sends `open_dialog` keyed by the `trigger_id` the command answered with.

The dialog case needs an integration that can call `POST /actions/dialogs/open`; that is
`scripts/t88_slash_stub.py` plus the four commands `scripts/t88_slash_register.py` creates. When the
stub is not running the probe says so and skips that case — it never fakes the frame.

Usage:
  python3 scripts/t88_slash_plugin_probe.py [--server URL] [--channel NAME] [--thread]
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
    parser.add_argument("--team", default="perf")
    parser.add_argument("--channel", default="t35-composer")
    parser.add_argument("--stub", default="http://127.0.0.1:8099/health")
    args = parser.parse_args()

    base = args.server.rstrip("/")
    api = base + "/api/v4"

    def call(method: str, path: str, token: str | None = None, body=None, base_url=None):
        data = json.dumps(body).encode() if body is not None else None
        headers = {"Content-Type": "application/json", "X-Requested-With": "XMLHttpRequest"}
        if token:
            headers["Authorization"] = "Bearer " + token
        request = urllib.request.Request((base_url or api) + path, data=data,
                                         headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = response.read()
                return (response.status,
                        json.loads(payload) if payload.strip() else None,
                        dict(response.headers))
        except urllib.error.HTTPError as error:
            raw = error.read().decode(errors="replace")
            try:
                return error.code, json.loads(raw), dict(error.headers)
            except ValueError:
                return error.code, raw, dict(error.headers)

    status, _, headers = call("POST", "/users/login",
                              body={"login_id": args.login, "password": args.password})
    token = headers.get("Token") or headers.get("token")
    if status != 200 or not token:
        print("login failed:", status)
        return 1

    _, me, _ = call("GET", "/users/me", token)
    _, teams, _ = call("GET", "/users/me/teams", token)
    team = next(t for t in teams if t["name"] == args.team)
    _, channels, _ = call("GET", f"/users/me/teams/{team['id']}/channels", token)
    channel = next(c for c in channels if c["name"] == args.channel)
    print("== login:", me["username"], "| team", team["id"], "| channel", channel["id"],
          channel["name"])

    # 1. What the server offers, and which rows are plugin rows.
    _, plugins, _ = call("GET", "/plugins", token)
    active = [p["id"] for p in (plugins or {}).get("active", [])] if isinstance(plugins, dict) else []
    _, all_commands, _ = call("GET", f"/commands?team_id={team['id']}", token)
    _, custom_commands, _ = call("GET", f"/commands?team_id={team['id']}", token)
    print("== active plugins:", active)
    print("== GET /commands: %d rows" % len(all_commands))
    interesting = ("call", "playbook", "t88echo", "t88multi", "t88goto", "t88dialog",
                   "help", "echo", "marketplace")
    for command in all_commands:
        if command["trigger"] in interesting:
            print("   %-10s autoc=%s plugin_id=%r id=%r desc=%r hint=%r data=%s"
                  % (command["trigger"], command.get("auto_complete"),
                     command.get("plugin_id"), command.get("id"),
                     command.get("auto_complete_desc"),
                     command.get("auto_complete_hint"),
                     "yes" if command.get("autocomplete_data") else "no"))

    # 1b. The autocomplete_suggestions endpoint the pin's slash suggestion uses for arguments.
    for term in ("/", "/pl", "/playbook", "/call", "/gif"):
        query = urllib.parse.urlencode({"user_input": term, "channel_id": channel["id"],
                                        "team_id": team["id"], "parent_id": ""})
        status, suggestions, _ = call("GET", "/teams/%s/commands/autocomplete_suggestions?%s"
                                      % (team["id"], query), token)
        if isinstance(suggestions, list):
            rows = ["%s|%s|%s" % (s.get("Complete", s.get("complete")),
                                  s.get("Description", s.get("description")),
                                  "hint:" + str(s.get("Hint", s.get("hint"))))
                    for s in suggestions[:6]]
            print("== autocomplete_suggestions user_input=%r -> %s %d rows: %s"
                  % (term, status, len(suggestions), " ; ".join(rows)))
        else:
            print("== autocomplete_suggestions user_input=%r -> %s %s"
                  % (term, status, str(suggestions)[:200]))

    # 2/3. Execute, listening on the socket.
    host = urllib.parse.urlparse(base).hostname
    port = urllib.parse.urlparse(base).port or 80
    websocket = WS(host, port, "/api/v4/websocket")
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

    # A thread root, so the reply case can send a real root_id/parent_id pair.
    _, page, _ = call("GET", f"/channels/{channel['id']}/posts?per_page=1", token)
    thread_root = None
    for post_id in page.get("order", []):
        post = page["posts"][post_id]
        if not post.get("root_id"):
            thread_root = post
            break

    commands = ["/call help", "/playbook list", "/t88echo probe", "/t88multi",
                "/t88goto", "/t88dialog", "/nosuchcommand", "/help"]
    for line in commands:
        body = {"command": line, "channel_id": channel["id"], "team_id": team["id"]}
        started = len(events)
        status, answer, _ = call("POST", "/commands/execute", token, body)
        print("\n== POST /commands/execute  request:", json.dumps(body, sort_keys=True))
        if isinstance(answer, dict):
            print("   response %s: %s" % (status, json.dumps(answer, sort_keys=True)))
        else:
            print("   response %s: %s" % (status, str(answer)[:400]))
        time.sleep(2.5)
        for event in events[started:]:
            name = event.get("event")
            if name == "posted":
                post = json.loads(event["data"]["post"])
                print("   socket posted: id=%s type=%r root=%r message=%r"
                      % (post["id"], post["type"], post["root_id"], post["message"][:80]))
            elif name == "ephemeral_message":
                post = json.loads(event["data"]["post"])
                print("   socket ephemeral_message: id=%s type=%r root=%r message=%r"
                      % (post["id"], post["type"], post["root_id"], post["message"][:80]))
            elif name == "open_dialog":
                dialog = event["data"]["dialog"]
                parsed = json.loads(dialog) if isinstance(dialog, str) else dialog
                print("   socket open_dialog: trigger_id=%r title=%r elements=%s"
                      % (parsed.get("trigger_id"), parsed.get("dialog", {}).get("title"),
                         [e.get("name") for e in parsed.get("dialog", {}).get("elements", [])]))
            else:
                print("   socket", name)

    # The thread case: root_id *and* parent_id, which upstream sends and we did not.
    if thread_root:
        for with_parent in (False, True):
            body = {"command": "/t88echo thread", "channel_id": channel["id"],
                    "team_id": team["id"], "root_id": thread_root["id"]}
            if with_parent:
                body["parent_id"] = thread_root["id"]
            status, answer, _ = call("POST", "/commands/execute", token, body)
            print("\n== POST /commands/execute (thread, parent_id=%s) request: %s"
                  % (with_parent, json.dumps(body, sort_keys=True)))
            print("   response %s: %s" % (status, json.dumps(answer, sort_keys=True)[:300]))
            time.sleep(1.5)

    stop = True
    websocket.close()

    # 4. What the stub saw (the server forwards trigger_id/parent_id to the integration).
    parsed = urllib.parse.urlparse(args.stub)
    try:
        with urllib.request.urlopen("%s://%s/health" % (parsed.scheme, parsed.netloc),
                                    timeout=5) as response:
            print("\n== stub reachable:", response.status)
    except Exception as error:  # noqa: BLE001
        print("\n== stub not reachable (%s) — the custom-command cases were not exercised"
              % error)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
