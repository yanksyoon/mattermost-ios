#!/usr/bin/env python3
"""T44 probe: the Mattermost Calls signalling contract, measured against a live plugin.

This is the conformance probe a native Calls client has to satisfy, and the one this card used
to decide whether the `calls` surface may leave the webview. It talks to the **core**
`/api/v4/websocket` exactly like the app does (the Calls plugin never opens a socket of its own —
`server/websocket.go` in mattermost-plugin-calls hooks `WebSocketMessageHasBeenPosted` and the core
server routes `custom_com.mattermost.calls_*` actions to it).

What it establishes, in order:

  1. the plugin is installed and what version/build it is (`GET /plugins/com.mattermost.calls/version`);
  2. what the plugin says its configuration is (`/config`: sku, AllowEnableCalls, DefaultEnabled,
     ICEServers) — a client cannot join a call the plugin refuses to enable;
  3. a **JSON text frame** can join: `join` -> `join` ack carrying `connID`, then `user_joined` and
     the full `call_state` (the payload a native calls UI renders);
  4. the `sdp` action is **not** a JSON-frame action: the plugin type-asserts the payload to `[]byte`
     (`server/websocket.go`, `msgData, ok := req.Data["data"].([]byte)`), and the core server's JSON
     decoder produces a `string` — so the server logs "invalid or missing sdp data" and never answers.
     That is measured here as a negative: no `signal` event arrives for a JSON-framed offer;
  5. the same offer sent as a **MessagePack binary frame** (the shape the web client uses,
     `webapp/src/websocket.ts` `encode(msg)`) is answered: the SFU (the plugin's own pion RTC server,
     `server/activate.go` `rtc.NewServer`) returns `{"type":"answer","sdp":...}` plus ICE candidates;
  6. the client is the **offerer**: nothing is sent until the client offers. Measured on its own
     connection — a session that joins and sends nothing receives **no** `signal` frame of its
     own and is torn down by the plugin at its signalling timeout (`wsReconnectionTimeout`,
     ~10 s), announced as `user_left` carrying `session_id` == that connection's `connID`.
     This is the only shape of the check that holds under load: the plugin publishes `signal`
     to the **user**, not to the connection (`p.publishWebSocketEvent(wsEventSignal, …,
     &WebSocketBroadcast{UserID: us.userID})`, `server/websocket.go:590-593` at v0.29.8), so
     every `signal` frame in the payload carries the `connID` of the session it belongs to and
     a frame for another live session of the same account must be **ignored** — counted, not
     believed. The same is true of the `join` ack itself (`websocket.go:830-832`, UserID
     broadcast). The one per-connection fact is the core server's `hello` event, whose payload
     carries this socket's `connection_id`; that — not the ack — is the probe's own `connID`
     (measured: `hello` said `iheruubwujdj7xaotpp6qobjhy` and the ack for our join repeated it).
     Without that scope a second session (another probe, a browser tab) lands its answer and
     candidates on the socket that is supposed to prove "an unanswered offer gets no answer",
     and the negative checks fail for a reason that has nothing to do with them;
  7. every UDP candidate the SFU advertises is probed **from this host, with ICE credentials**, by
     sending the same credentialed binding request a client's ICE agent would send, so "can media
     actually flow here" is a measurement and not an assumption. A bare, unauthenticated STUN
     binding request cannot answer that question: the SFU demultiplexes every session on one UDP
     port with a ufrag mux (`webrtc.NewICEUDPMux`), which routes a datagram to an ICE agent by the
     `USERNAME` attribute — no `USERNAME`, no agent, no reply, whether the port is open or shut.
     That is why the check below carries `USERNAME`/`MESSAGE-INTEGRITY`/`PRIORITY`, and why it is run
     while the session is still joined (the SFU tears the agent down on `leave`).

Exit code is 0 when every *contract* check holds (1-6). Reachability (7) is printed as a
measurement, because a closed port is a fact about the deployment, not a conformance failure — the
final line states which it was.

Nothing here writes to the server except joining a call in the probe channel (which the plugin
records as a call and a "call started" post, exactly like the web client does) and leaving it again.
The token is only ever sent in a request header / socket upgrade header and is never printed.

    python3 scripts/t44_calls_probe.py --url http://127.0.0.1:8065
    python3 scripts/t44_calls_probe.py --url http://127.0.0.1:8065 --json

Fixture: the account `perfprobe` must exist (password below, a throwaway local value used by every
probe script in this repo) and the Calls plugin must be installed. The probe creates the public
channel `t44-calls` on first use.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import hmac
import json
import os
import re
import socket
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zlib
from typing import Any

ADMIN_LOGIN = "perfprobe"
ADMIN_PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
CHANNEL_NAME = "t44-calls"
PLUGIN = "/plugins/com.mattermost.calls"

checks: list[tuple[str, bool, str]] = []
measures: list[tuple[str, str]] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    checks.append((name, ok, detail))
    print(("PASS  " if ok else "FAIL  ") + name + (("  —  " + detail) if detail else ""))


def measure(name: str, detail: str = "") -> None:
    measures.append((name, detail))
    print("DATA  " + name + (("  —  " + detail) if detail else ""))


# --------------------------------------------------------------------------------------------
# REST
# --------------------------------------------------------------------------------------------

def call(url: str, method: str, path: str, body: Any = None,
         token: str | None = None) -> tuple[int, Any, dict[str, str]]:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url.rstrip("/") + path, data=data, method=method)
    request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = response.read()
            return response.status, (json.loads(raw) if raw else {}), {
                k.lower(): v for k, v in response.getheaders()}
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            return error.code, json.loads(raw), {}
        except Exception:
            return error.code, raw.decode("utf-8", "replace"), {}


def login(url: str, login_id: str, password: str) -> tuple[str, dict[str, Any]]:
    status, body, headers = call(url, "POST", "/api/v4/users/login",
                                 {"login_id": login_id, "password": password})
    if status != 200 or not isinstance(body, dict):
        raise SystemExit(f"login failed for {login_id}: HTTP {status}")
    token = headers.get("token", "")
    if not token:
        raise SystemExit("login returned no Token header")
    return token, body


def plugin_prefix(url: str, token: str) -> tuple[str, dict[str, Any]]:
    """The plugin's compiled-in manifest id, which is the WS action/event prefix."""
    status, plugins, _ = call(url, "GET", "/api/v4/plugins", token=token)
    active = plugins.get("active") if isinstance(plugins, dict) else None
    for plugin in active or []:
        if plugin.get("id", "").startswith("com.mattermost.calls"):
            return "custom_" + plugin["id"] + "_", plugin
    return "custom_com.mattermost.calls_", {}


def ensure_channel(url: str, token: str, name: str) -> dict[str, Any]:
    _, teams, _ = call(url, "GET", "/api/v4/users/me/teams", token=token)
    if not teams:
        raise SystemExit("the account is in no team")
    team_id = teams[0]["id"]
    _, channels, _ = call(url, "GET", f"/api/v4/users/me/teams/{team_id}/channels", token=token)
    for channel in channels or []:
        if channel.get("name") == name:
            return channel
    status, created, _ = call(url, "POST", "/api/v4/channels",
                              {"team_id": team_id, "name": name, "display_name": name,
                               "type": "O"}, token=token)
    if status not in (200, 201):
        raise SystemExit(f"could not create the probe channel: HTTP {status} {created}")
    print(f"      created probe channel {name} ({created['id']})")
    return created


# --------------------------------------------------------------------------------------------
# Minimal RFC6455 client (text + binary frames). The app's socket is Swift; the probe needs the
# same wire protocol from outside the app, and the stdlib has no WebSocket client.
# --------------------------------------------------------------------------------------------

class WSClient:
    def __init__(self, url: str, token: str, timeout: float = 20.0,
                 query: str | None = None):
        parsed = urllib.parse.urlparse(url)
        secure = parsed.scheme == "https"
        self.host = parsed.hostname or "127.0.0.1"
        self.port = parsed.port or (443 if secure else 80)
        path = (parsed.path or "") + "/api/v4/websocket"
        if query:
            path += "?" + query
        self.sock = socket.create_connection((self.host, self.port), timeout=timeout)
        self.sock.settimeout(timeout)
        if secure:
            import ssl
            self.sock = ssl.create_default_context().wrap_socket(self.sock,
                                                                 server_hostname=self.host)
        key = base64.b64encode(os.urandom(16)).decode()
        origin = f"{parsed.scheme}://{parsed.netloc}"
        head = [
            f"GET {path} HTTP/1.1",
            f"Host: {parsed.netloc}",
            "Upgrade: websocket",
            "Connection: Upgrade",
            f"Sec-WebSocket-Key: {key}",
            "Sec-WebSocket-Version: 13",
            f"Origin: {origin}",
            "X-Requested-With: XMLHttpRequest",
            f"Authorization: Bearer {token}",
        ]
        self.sock.sendall(("\r\n".join(head) + "\r\n\r\n").encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RuntimeError("websocket handshake closed early")
            buf += chunk
        response, _, self.buf = buf.partition(b"\r\n\r\n")
        if b"101" not in response.split(b"\r\n")[0]:
            raise RuntimeError("websocket handshake failed: "
                               + response.decode("utf-8", "replace"))
        expected = base64.b64encode(hashlib.sha1(
            (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        if expected.lower().encode() not in response.lower():
            raise RuntimeError("bad Sec-WebSocket-Accept")

    def _frame(self, opcode: int, payload: bytes) -> None:
        header = bytearray([0x80 | opcode])
        length = len(payload)
        if length < 126:
            header.append(0x80 | length)
        elif length < 65536:
            header.append(0x80 | 126)
            header += struct.pack("!H", length)
        else:
            header.append(0x80 | 127)
            header += struct.pack("!Q", length)
        mask = os.urandom(4)
        header += mask
        self.sock.sendall(bytes(header) + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def send_text(self, text: str) -> None:
        self._frame(0x1, text.encode())

    def send_binary(self, data: bytes) -> None:
        self._frame(0x2, data)

    def _exact(self, n: int) -> bytes:
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("websocket closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def receive(self, deadline: float) -> dict[str, Any] | None:
        """Next JSON frame, or None at the deadline. Binary server frames are ignored."""
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                return None
            self.sock.settimeout(remaining)
            try:
                b0, b1 = self._exact(2)
            except (socket.timeout, TimeoutError):
                return None
            opcode = b0 & 0x0F
            length = b1 & 0x7F
            if length == 126:
                length = struct.unpack("!H", self._exact(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._exact(8))[0]
            mask = self._exact(4) if b1 & 0x80 else None
            payload = self._exact(length) if length else b""
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x9:
                self._frame(0xA, payload)
                continue
            if opcode in (0xA, 0x8):
                if opcode == 0x8:
                    return None
                continue
            try:
                return json.loads(payload)
            except Exception:
                continue

    def close(self) -> None:
        try:
            self._frame(0x8, b"")
            self.sock.close()
        except Exception:
            pass


# --------------------------------------------------------------------------------------------
# Minimal MessagePack encoder — enough for one socket frame: str, int, bin, map.
# --------------------------------------------------------------------------------------------

def mp_encode(value: Any) -> bytes:
    if isinstance(value, bytes):
        n = len(value)
        if n < 256:
            return b"\xc4" + bytes([n]) + value
        if n < 65536:
            return b"\xc5" + struct.pack("!H", n) + value
        return b"\xc6" + struct.pack("!I", n) + value
    if isinstance(value, str):
        data = value.encode()
        n = len(data)
        if n < 32:
            return bytes([0xA0 | n]) + data
        if n < 256:
            return b"\xd9" + bytes([n]) + data
        if n < 65536:
            return b"\xda" + struct.pack("!H", n) + data
        return b"\xdb" + struct.pack("!I", n) + data
    if isinstance(value, int):
        if 0 <= value < 128:
            return bytes([value])
        if 0 <= value < 65536:
            return b"\xcd" + struct.pack("!H", value)
        if 0 <= value < 2 ** 32:
            return b"\xce" + struct.pack("!I", value)
        return b"\xcf" + struct.pack("!Q", value)
    if isinstance(value, dict):
        n = len(value)
        out = bytearray([0x80 | n]) if n < 16 else bytearray(b"\xde" + struct.pack("!H", n))
        for k, v in value.items():
            out += mp_encode(k) + mp_encode(v)
        return bytes(out)
    raise TypeError(type(value))


# --------------------------------------------------------------------------------------------
# The SDP offer the probe sends. No media is captured: the point is the server's answer and its
# ICE candidates, which is what decides whether a real client could connect from here.
# --------------------------------------------------------------------------------------------

OFFER_SDP = "\r\n".join([
    "v=0",
    "o=- 4611731400430051336 2 IN IP4 127.0.0.1",
    "s=-",
    "t=0 0",
    "a=group:BUNDLE 0",
    "a=msid-semantic: WMS t44stream",
    "m=audio 9 UDP/TLS/RTP/SAVPF 111",
    "c=IN IP4 0.0.0.0",
    "a=rtcp:9 IN IP4 0.0.0.0",
    "a=ice-ufrag:t44a",
    "a=ice-pwd:t44aicepassword1234567890ab",
    "a=ice-options:trickle",
    "a=fingerprint:sha-256 "
    "2F:8C:1D:9E:7A:3B:5C:4D:6E:7F:80:91:A2:B3:C4:D5:"
    "E6:F7:08:19:2A:3B:4C:5D:6E:7F:80:91:A2:B3:C4:D5",
    "a=setup:actpass",
    "a=mid:0",
    "a=sendrecv",
    "a=rtcp-mux",
    "a=rtpmap:111 opus/48000/2",
    "a=fmtp:111 minptime=10;useinbandfec=1",
    "a=ssrc:11111111 cname:t44probe",
    "a=ssrc:11111111 msid:t44stream t44audio",
    "",
])

STUN_MAGIC = 0x2112A442


def stun_reachable(host: str, port: int, timeout: float = 2.0) -> str | None:
    """Bare binding request (no ICE attributes). Only a plain STUN server answers this."""
    txid = os.urandom(12)
    packet = struct.pack("!HHI", 0x0001, 0, STUN_MAGIC) + txid
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.sendto(packet, (host, port))
        data, _ = sock.recvfrom(2048)
    except (socket.timeout, TimeoutError, OSError):
        return None
    finally:
        sock.close()
    if len(data) < 20 or data[4:8] != struct.pack("!I", STUN_MAGIC) or data[8:20] != txid:
        return None
    return "reply"


# --- ICE connectivity check: the only binding request a ufrag mux can answer -------------------

BINDING_SUCCESS = 0x0101
BINDING_ERROR = 0x0111
ATTR_USERNAME = 0x0006
ATTR_MESSAGE_INTEGRITY = 0x0008
ATTR_ERROR_CODE = 0x0009
ATTR_XOR_MAPPED_ADDRESS = 0x0020
ATTR_PRIORITY = 0x0024
ATTR_FINGERPRINT = 0x8028
ATTR_ICE_CONTROLLING = 0x802A
FINGERPRINT_XOR = 0x5354554E


def _stun_attr(kind: int, value: bytes) -> bytes:
    pad = (4 - len(value) % 4) % 4
    return struct.pack("!HH", kind, len(value)) + value + b"\x00" * pad


def build_ice_binding_request(local_ufrag: str, remote_ufrag: str, remote_pwd: str,
                              priority: int = 1845501695) -> bytes:
    """A controlling-agent binding request (RFC 8445 §7.2.2, RFC 5389 §15.4)."""
    txid = os.urandom(12)
    tiebreaker = int.from_bytes(os.urandom(8), "big")
    attrs = b"".join([
        _stun_attr(ATTR_USERNAME, f"{remote_ufrag}:{local_ufrag}".encode()),
        _stun_attr(ATTR_PRIORITY, struct.pack("!I", priority)),
        _stun_attr(ATTR_ICE_CONTROLLING, struct.pack("!Q", tiebreaker)),
    ])
    # MESSAGE-INTEGRITY: HMAC-SHA1 keyed with the *receiving* peer's password, over the message with
    # the header length already counting the MESSAGE-INTEGRITY attribute (RFC 5389 §15.4).
    header = (struct.pack("!HH", 0x0001, len(attrs) + 24) + struct.pack("!I", STUN_MAGIC) + txid)
    mac = hmac.new(remote_pwd.encode(), header + attrs, hashlib.sha1).digest()
    attrs += _stun_attr(ATTR_MESSAGE_INTEGRITY, mac)
    header = (struct.pack("!HH", 0x0001, len(attrs) + 8) + struct.pack("!I", STUN_MAGIC) + txid)
    crc = (binascii.crc32(header + attrs) & 0xFFFFFFFF) ^ FINGERPRINT_XOR
    attrs += _stun_attr(ATTR_FINGERPRINT, struct.pack("!I", crc))
    return header + attrs


def parse_stun_reply(data: bytes, txid: bytes) -> dict[str, Any] | None:
    if len(data) < 20 or data[4:8] != struct.pack("!I", STUN_MAGIC) or data[8:20] != txid:
        return None
    parsed: dict[str, Any] = {"type": struct.unpack("!H", data[0:2])[0] & 0x3FFF, "attrs": []}
    offset = 20
    while offset + 4 <= len(data):
        atype, alen = struct.unpack("!HH", data[offset:offset + 4])
        value = data[offset + 4:offset + 4 + alen]
        parsed["attrs"].append(atype)
        if atype == ATTR_ERROR_CODE and alen >= 4:
            parsed["error"] = (value[2] & 0x07) * 100 + value[3]
        if atype == ATTR_XOR_MAPPED_ADDRESS and alen >= 8:
            port = struct.unpack("!H", value[2:4])[0] ^ (STUN_MAGIC >> 16)
            ip = bytes(b ^ c for b, c in zip(value[4:8], struct.pack("!I", STUN_MAGIC)))
            parsed["mapped"] = f"{socket.inet_ntoa(ip)}:{port}"
        offset += 4 + alen + ((4 - alen % 4) % 4)
    return parsed


def ice_check(host: str, port: int, local_ufrag: str, remote_ufrag: str, remote_pwd: str,
              timeout: float = 2.0) -> dict[str, Any]:
    """Credentialed binding request to a candidate. A reply means an ICE agent saw the packet."""
    packet = build_ice_binding_request(local_ufrag, remote_ufrag, remote_pwd)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    started = time.time()
    try:
        sock.sendto(packet, (host, port))
        data, _ = sock.recvfrom(2048)
    except (socket.timeout, TimeoutError, OSError) as exc:
        return {"target": f"{host}:{port}", "reply": False, "why": type(exc).__name__}
    finally:
        sock.close()
    elapsed = round((time.time() - started) * 1000)
    parsed = parse_stun_reply(data, packet[8:20])
    if parsed is None:
        return {"target": f"{host}:{port}", "reply": False,
                "why": f"{len(data)} bytes, not a STUN reply to our transaction"}
    kind = parsed["type"]
    return {
        "target": f"{host}:{port}",
        "reply": True,
        "stun_type": "binding success" if kind == BINDING_SUCCESS else
                     ("binding error" if kind == BINDING_ERROR else f"0x{kind:04x}"),
        "authenticated": ATTR_MESSAGE_INTEGRITY in parsed["attrs"],
        "mapped": parsed.get("mapped"),
        "error": parsed.get("error"),
        "ms": elapsed,
    }


def sdp_credentials(sdp: str) -> tuple[str | None, str | None]:
    """ICE short-term credentials out of an SDP (session or media level)."""
    ufrag = re.search(r"^a=ice-ufrag:(\S+)", sdp, re.MULTILINE)
    pwd = re.search(r"^a=ice-pwd:(\S+)", sdp, re.MULTILINE)
    return (ufrag.group(1) if ufrag else None, pwd.group(1) if pwd else None)


# --------------------------------------------------------------------------------------------
# One call session: connect, join, and collect what the plugin sends back.
# --------------------------------------------------------------------------------------------

def signal_kind(data: dict[str, Any]) -> str:
    """The inner `type` of a `signal` frame's `data` ("answer" / "candidate" / ...)."""
    payload = data.get("data")
    try:
        inner = json.loads(payload) if isinstance(payload, str) else payload
    except Exception:
        return "unparsable"
    return inner.get("type", "?") if isinstance(inner, dict) else "?"


def run_session(url: str, token: str, prefix: str, channel_id: str, mode: str,
                seconds: float = 6.0, hook: Any = None) -> dict[str, Any]:
    ws = WSClient(url, token)
    result: dict[str, Any] = {"ack": False, "conn_id": None, "call_state": None,
                              "answer": None, "candidates": [], "errors": [],
                              "raw_signal": [], "foreign_signal_ignored": [],
                              "foreign_acks": []}
    deadline = time.time() + seconds
    joined = False
    offered = False
    try:
        while time.time() < deadline:
            frame = ws.receive(deadline)
            if frame is None:
                break
            event = frame.get("event", "")
            data = frame.get("data") or {}
            if event == "hello":
                # The core server's per-connection greeting carries THIS socket's id, and the
                # plugin's join ack repeats it. It is the only frame that is ours alone: the
                # plugin broadcasts the ack itself to every session of the user.
                result["conn_id"] = data.get("connection_id") or None
                ws.send_text(json.dumps({"seq": 1, "action": prefix + "join",
                                         "data": {"channelID": channel_id}}))
                joined = True
                continue
            if event == prefix + "join":
                ack_id = data.get("connID") or None
                if result["conn_id"] and ack_id and ack_id != result["conn_id"]:
                    # Another live session of this account joined; its ack reached us because
                    # the broadcast targets the user. Not our join.
                    result["foreign_acks"].append(ack_id)
                    continue
                result["conn_id"] = result["conn_id"] or ack_id
                result["ack"] = bool(ack_id)
                if not offered:
                    body = json.dumps({"type": "offer", "sdp": OFFER_SDP}).encode()
                    packed = zlib.compress(body, 9)
                    if mode == "json":
                        ws.send_text(json.dumps({
                            "seq": 2, "action": prefix + "sdp",
                            "data": {"data": packed.decode("latin-1")}}))
                    else:
                        ws.send_binary(mp_encode({"seq": 2, "action": prefix + "sdp",
                                                  "data": {"data": packed}}))
                    offered = True
                    # An answer arrives in well under a second when the frame is accepted; give
                    # a JSON-framed offer a fair window of its own before calling it unanswered.
                    deadline = time.time() + (2.5 if mode == "json" else seconds)
                continue
            if event == prefix + "call_state":
                raw = data.get("call")
                try:
                    result["call_state"] = json.loads(raw) if isinstance(raw, str) else raw
                except Exception:
                    result["call_state"] = None
                continue
            if event == prefix + "signal":
                # The plugin publishes `signal` to the USER (websocket.go:590-593 at v0.29.8), so
                # a second live session of this account delivers its frames here too. Only the
                # frames whose connID is the one our join ack returned are ours to believe.
                conn = str(data.get("connID") or "")
                inner_kind = signal_kind(data)
                if not result["conn_id"] or conn != result["conn_id"]:
                    result["foreign_signal_ignored"].append({"connID": conn, "type": inner_kind})
                    continue
                result["raw_signal"].append(data)
                payload = data.get("data")
                try:
                    inner = json.loads(payload) if isinstance(payload, str) else payload
                except Exception:
                    inner = None
                if isinstance(inner, dict) and inner.get("type") == "answer":
                    result["answer"] = inner.get("sdp", "")
                elif isinstance(inner, dict) and inner.get("type") == "candidate":
                    candidate = inner.get("candidate") or {}
                    text = candidate.get("candidate", "") if isinstance(candidate, dict) else ""
                    result["candidates"].append(text)
                continue
            if event == prefix + "error":
                result["errors"].append(data)
        if hook is not None:
            # Run while the session is still joined: the SFU tears its ICE agent down on leave, so
            # anything that talks to the media port (an ICE connectivity check) has to happen here.
            hook(result)
        if joined:
            ws.send_text(json.dumps({"seq": 99, "action": prefix + "leave",
                                     "data": {"channelID": channel_id}}))
            time.sleep(0.3)
    finally:
        ws.close()
    return result


def run_no_offer_session(url: str, token: str, prefix: str, channel_id: str,
                         seconds: float = 16.0) -> dict[str, Any]:
    """Join, send nothing, and measure what the plugin does with a session that never offers.

    This is check 8, and it is deliberately **one connection's** story rather than a comparison
    between two runs of the same account:

      * every `signal` frame that arrives is attributed by its `connID`. Nothing is offered from
        this connection, so a frame carrying our `connID` would mean the SFU answered an offer
        that does not exist; a frame carrying anyone else's is another live session of the same
        account and is counted, not believed (`foreign_signal_ignored`).
      * the teardown is attributed by `session_id`: the plugin's `user_left` carries the
        `connID` of the session that left, so "our silent session was torn down at ~10 s" is a
        fact about this connection and cannot be borrowed from a neighbour either.
    """
    ws = WSClient(url, token)
    result: dict[str, Any] = {"ack": False, "conn_id": None, "own_signals": 0,
                              "foreign_signal_ignored": [], "teardown_seconds": None,
                              "user_disconnected_seconds": None, "events": [], "errors": [],
                              "foreign_acks": []}
    start = time.time()
    deadline = start + seconds
    joined = False
    try:
        while time.time() < deadline:
            frame = ws.receive(deadline)
            if frame is None:
                break
            elapsed = time.time() - start
            event = frame.get("event", "")
            data = frame.get("data") or {}
            if event == "hello":
                result["conn_id"] = data.get("connection_id") or None
                ws.send_text(json.dumps({"seq": 1, "action": prefix + "join",
                                         "data": {"channelID": channel_id}}))
                joined = True
                result["events"].append((round(elapsed, 2),
                                         f"hello connection_id {result['conn_id']} -> join sent"))
                continue
            if event == prefix + "join":
                ack_id = data.get("connID") or None
                if result["conn_id"] and ack_id and ack_id != result["conn_id"]:
                    result["foreign_acks"].append(ack_id)
                    result["events"].append((round(elapsed, 2),
                                             f"join ack {ack_id} (another session)"))
                    continue
                result["ack"] = bool(ack_id)
                result["events"].append((round(elapsed, 2), f"join ack {ack_id} (our connID)"))
                continue
            if event == prefix + "signal":
                conn = str(data.get("connID") or "")
                kind = signal_kind(data)
                if result["conn_id"] and conn == result["conn_id"]:
                    result["own_signals"] += 1
                else:
                    result["foreign_signal_ignored"].append({"connID": conn, "type": kind})
                continue
            if event == prefix + "error":
                result["errors"].append(data)
                result["events"].append((round(elapsed, 2), "error"))
                continue
            if event == prefix + "user_left":
                if data.get("session_id") == result["conn_id"]:
                    result["teardown_seconds"] = elapsed
                    result["events"].append((round(elapsed, 2), "user_left (our connID)"))
                    break
                result["events"].append((round(elapsed, 2), "user_left (another session)"))
                continue
            if event == prefix + "user_disconnected":
                if result["user_disconnected_seconds"] is None:
                    result["user_disconnected_seconds"] = elapsed
                result["events"].append((round(elapsed, 2), "user_disconnected"))
                continue
            result["events"].append((round(elapsed, 2), event))
        if joined and result["teardown_seconds"] is None:
            try:
                ws.send_text(json.dumps({"seq": 99, "action": prefix + "leave",
                                         "data": {"channelID": channel_id}}))
                time.sleep(0.2)
            except Exception:
                pass
    finally:
        ws.close()
    return result


def parse_candidate(text: str) -> tuple[str, int] | None:
    """`candidate:<foundation> <component> udp <priority> <ip> <port> typ host` -> (ip, port)."""
    parts = text.split()
    if len(parts) < 6:
        return None
    transport = parts[2]
    host, port = parts[4], parts[5]
    if transport != "udp":
        return None
    try:
        return host, int(port)
    except ValueError:
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--channel", default=CHANNEL_NAME,
                        help="probe channel name (created in the first team when missing)")
    parser.add_argument("--json", action="store_true", help="also print a machine-readable summary")
    args = parser.parse_args()

    print(f"T44 Calls probe against {args.url}")
    token, me = login(args.url, ADMIN_LOGIN, ADMIN_PASSWORD)
    print(f"      signed in as {me.get('username')} ({me.get('id')})")

    # 1. The plugin, and what it says it is.
    status, version, _ = call(args.url, "GET", PLUGIN + "/version", token=token)
    check("the Calls plugin answers /version", status == 200 and isinstance(version, dict),
          f"HTTP {status}")
    plugin_version = version.get("version") if isinstance(version, dict) else None
    plugin_build = version.get("build") if isinstance(version, dict) else None
    measure("plugin version", f"{plugin_version} (build {plugin_build})")
    prefix, manifest = plugin_prefix(args.url, token)
    measure("plugin websocket prefix", prefix)

    # 2. The plugin's own configuration — a call needs AllowEnableCalls.
    status, config, _ = call(args.url, "GET", PLUGIN + "/config", token=token)
    enabled = bool(config.get("AllowEnableCalls")) if isinstance(config, dict) else False
    check("the plugin allows calls to be enabled", status == 200 and enabled,
          f"HTTP {status}, AllowEnableCalls={enabled}")
    if isinstance(config, dict):
        measure("plugin sku / test mode", f"{config.get('sku_short_name')} / "
                f"DefaultEnabled={config.get('DefaultEnabled')} / "
                f"MaxCallParticipants={config.get('MaxCallParticipants')}")
        measure("ICE servers the plugin hands a client",
                json.dumps(config.get("ICEServersConfigs")))

    channel = ensure_channel(args.url, token, args.channel)
    channel_id = channel["id"]
    measure("probe channel", f"{channel.get('name')} ({channel_id})")

    # 3-4. JSON text frames: join works, sdp is not a JSON action.
    print("\n--- run A: join over JSON, offer over a JSON text frame ---")
    json_run = run_session(args.url, token, prefix, channel_id, "json")
    check("a JSON text frame joins the call (the join ack repeats this socket's connID)",
          json_run["ack"],
          f"connID {json_run['conn_id']}"
          + (f", {len(json_run['foreign_acks'])} foreign ack(s) ignored"
             if json_run["foreign_acks"] else ""))
    call_state = json_run["call_state"] or {}
    sessions = call_state.get("sessions") or []
    check("the join is followed by a full call_state (what a native calls UI renders)",
          bool(sessions) and any(s.get("user_id") == me.get("id") for s in sessions),
          f"{len(sessions)} session(s), call id {call_state.get('id')}")
    if sessions:
        measure("call_state session shape", json.dumps(sessions[0], sort_keys=True))
    check("a JSON-framed sdp is NOT answered (the plugin needs MessagePack for this action)",
          json_run["answer"] is None and not json_run["candidates"],
          f"{len(json_run['raw_signal'])} signal event(s) for connID {json_run['conn_id']}, "
          f"{len(json_run['foreign_signal_ignored'])} foreign frame(s) ignored")

    # 5-6. MessagePack: the same offer is answered by the SFU.
    print("\n--- run B: join over JSON, offer over a MessagePack binary frame ---")
    mp_run = run_session(args.url, token, prefix, channel_id, "msgpack")
    check("a MessagePack sdp frame is answered", bool(mp_run["answer"]),
          f"answer {len(mp_run['answer'] or '')} bytes for connID {mp_run['conn_id']}")
    check("the SFU trickles ICE candidates to the client", bool(mp_run["candidates"]),
          f"{len(mp_run['candidates'])} candidate(s), "
          f"{len(mp_run['foreign_signal_ignored'])} foreign frame(s) ignored")
    if mp_run["errors"]:
        measure("plugin error events", json.dumps(mp_run["errors"]))

    # 6 (check 8). The offerer property, measured on ONE connection: a session that joins and
    # sends nothing must receive no `signal` frame of its own, and the plugin must tear it down
    # at its signalling timeout. Both facts are attributed by this connection's own connID, so
    # the check survives another live session of the same account (see run_no_offer_session).
    print("\n--- run C: join and send nothing (the no-offer check) ---")
    no_offer = run_no_offer_session(args.url, token, prefix, channel_id)
    for elapsed, what in no_offer["events"]:
        measure(f"no-offer {elapsed:6.2f}s", what)
    check("a session that never offers receives no signal frame for its own connection",
          no_offer["own_signals"] == 0,
          f"0 own signal(s) for connID {no_offer['conn_id']}, "
          f"{len(no_offer['foreign_signal_ignored'])} foreign frame(s) ignored "
          f"(other live sessions of this account)")
    teardown = no_offer["teardown_seconds"]
    check("the plugin tears an unanswered session down at its ~10 s signalling timeout",
          teardown is not None and 5.0 <= teardown <= 15.0,
          (f"user_left session_id={no_offer['conn_id']} after {teardown:.2f} s"
           + (f" (user_disconnected at {no_offer['user_disconnected_seconds']:.2f} s)"
              if no_offer["user_disconnected_seconds"] is not None else ""))
          if teardown is not None else
          f"no user_left for connID {no_offer['conn_id']} within the window")
    if no_offer["foreign_signal_ignored"]:
        measure("foreign signal frames ignored during the no-offer session",
                json.dumps(no_offer["foreign_signal_ignored"][:8]))
    # A foreign frame anywhere in this run is the pointer to *why* the old check was unreliable;
    # it is not a failure, but it is worth surfacing on every run.
    measure("foreign signal frames ignored across runs A/B/C",
            str(len(json_run["foreign_signal_ignored"]) + len(mp_run["foreign_signal_ignored"])
                + len(no_offer["foreign_signal_ignored"])))

    # 7. Reachability of what the SFU just advertised — measured with ICE credentials, while the
    # session is still joined (the SFU drops the ICE agent on `leave`, so a check after run_session
    # returns would be measuring nothing but the mux's silence).
    print("\n--- reachability of the SFU's own candidates, from this host ---")
    advertised: list[tuple[str, int]] = []
    reach_results: list[dict[str, Any]] = []

    def probe_candidates(result: dict[str, Any]) -> None:
        answer = result.get("answer") or ""
        remote_ufrag, remote_pwd = sdp_credentials(answer)
        local_ufrag, _ = sdp_credentials(OFFER_SDP)
        local_ufrag = local_ufrag or "t44a"
        for text in result["candidates"]:
            parsed = parse_candidate(text)
            measure("candidate", text)
            if parsed and parsed not in advertised:
                advertised.append(parsed)
        if not remote_ufrag or not remote_pwd:
            measure("ICE credentials", "the answer carried none — cannot run a connectivity check")
            return
        measure("ICE credentials", f"server ufrag {remote_ufrag}, client ufrag {local_ufrag}")
        for host, port in advertised:
            if host.startswith("0.") or host in ("::", ""):
                continue
            outcome = ice_check(host, port, local_ufrag, remote_ufrag, remote_pwd)
            reach_results.append(outcome)
            if outcome["reply"]:
                measure(f"ice check to {host}:{port}",
                        f"{outcome['stun_type']} in {outcome['ms']} ms, "
                        f"message-integrity={outcome['authenticated']}, mapped={outcome['mapped']}")
            else:
                measure(f"ice check to {host}:{port}", f"no reply ({outcome['why']})")

    run_session(args.url, token, prefix, channel_id, "msgpack", seconds=5.0, hook=probe_candidates)
    reachable = sum(1 for r in reach_results if r["reply"])
    measure("control: a public STUN server answers a bare binding request from this host",
            "yes" if stun_reachable("stun.l.google.com", 19302) else "no")

    failed = [name for name, ok, _ in checks if not ok]
    print()
    print(f"{len(checks) - len(failed)} PASS / {len(failed)} FAIL")
    print(f"MEDIA PATH: {reachable}/{len(advertised)} advertised UDP candidate(s) reachable from "
          f"this host" + ("" if reachable else " — media cannot flow here (see the build note)"))
    if args.json:
        print(json.dumps({
            "url": args.url,
            "plugin": {"version": plugin_version, "build": plugin_build},
            "prefix": prefix,
            "channel_id": channel_id,
            "answer_bytes": len(mp_run["answer"] or ""),
            "candidates": [{"text": t, "parsed": parse_candidate(t)}
                           for t in mp_run["candidates"]],
            "candidates_reachable": reachable,
            "connections": {
                "run_a_json": {"connID": json_run["conn_id"],
                               "own_signal_frames": len(json_run["raw_signal"]),
                               "foreign_signal_ignored": json_run["foreign_signal_ignored"],
                               "foreign_join_acks_ignored": json_run["foreign_acks"]},
                "run_b_msgpack": {"connID": mp_run["conn_id"],
                                  "own_signal_frames": len(mp_run["raw_signal"]),
                                  "foreign_signal_ignored": mp_run["foreign_signal_ignored"],
                                  "foreign_join_acks_ignored": mp_run["foreign_acks"]},
                "run_c_no_offer": {"connID": no_offer["conn_id"],
                                   "own_signal_frames": no_offer["own_signals"],
                                   "foreign_signal_ignored": no_offer["foreign_signal_ignored"],
                                   "foreign_join_acks_ignored": no_offer["foreign_acks"],
                                   "teardown_seconds": no_offer["teardown_seconds"],
                                   "user_disconnected_seconds":
                                       no_offer["user_disconnected_seconds"]},
            },
            "checks": [{"name": n, "ok": ok, "detail": d} for n, ok, d in checks],
            "measures": [{"name": n, "detail": d} for n, d in measures],
        }))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
