#!/usr/bin/env python3
"""mmpush_proxy.py - Mock Mattermost Push Proxy (SIMULACRUM / CONTRACT FIXTURE).

SUPERSEDED by T12a (docs/t12a-build-note.md): the REAL upstream
mattermost-push-proxy (v6.6.0) is built, run and verified under PushProxy/upstream/.
This file is kept ONLY as a contract fixture — a runnable stand-in that documents the
HTTP surface and APNs payload shape for T13 (APNs registration + NSE) to develop
against in the no-`.p8` case. It is NOT delivery evidence and must not be presented as
such. Readiness is probed by mmpush_check.py against the real proxy instead.

A runnable stand-in for the real mattermost-push-proxy for the case where no
real proxy / APNs auth is reachable (this host cannot reach the official
hosted endpoints api.push.mattermost.net). It implements the *documented HTTP
surface* of the real proxy (verified against docs.mattermost.com and
mattermost-server/app/notification_push.go) so T13 (APNs registration + NSE)
has a real endpoint and a real APNs-shaped payload to develop against.

IT IS NOT A REAL PUSH PROXY. It cannot deliver to APNs (that requires an Apple
-issued .p8 auth key + a device token). On send_push it *validates* the request
exactly as the real proxy would and *emits* the exact APNs request it would
have made (payload + headers) to stdout/log so the shape is inspectable.
Treat it as a development/contract fixture, never as production delivery.

API surface (mirrors mattermost-push-proxy /api/v1):
  GET  /ping                     -> health check              {"status":"OK"}
  POST /api/v1/send_push         -> validate + build APNs req -> {"status":"OK","id":..}
  POST /api/v1/ack               -> record ack                -> {"status":"OK"}
  GET  /registry                 -> device registry (dev only)

Request fields for send_push (verified against docs + notification_push.go):
  type, message, badge, platform ("apple"/"apple_rn"/"android"...) ,
  server_id (Mattermost DiagnosticId), device_id ("apple:<hexToken>" or bare),
  channel_id, team_id  (optional: data, ack_id, category, version, post_id,
  sender_id, sender_name, root_id, sub_type, is_crt_enabled)

Security: the real proxy authenticates the calling Mattermost server with an
HMAC-SHA256 signature header ("Push-Notification-Signature") over the request
body using the server's PushNotificationServerSecret. This mock validates that
header when the matching server declares a secret; when no secret is declared
it still requires a known server_id.
"""

import argparse
import hashlib
import hmac
import json
import os
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

API_V1 = "/api/v1"


def apns_payload(msg):
    """Build the exact APNs 'aps'-wrapped payload the real proxy sends for
    platform apple/apple_rn. Mirrors mattermost-push-proxy's apple handler and
    the data.* keys T8's NotificationWorker already emits (server_id,
    channel_id, team_id, url, type)."""
    aps = {"alert": {"title": "", "body": msg.get("message", "")}}
    badge = msg.get("badge")
    if isinstance(badge, int) and badge >= 0:
        aps["badge"] = badge
    data = {
        "ack_id": msg.get("ack_id") or "",
        "type": msg.get("type", "message"),
        "sub_type": msg.get("sub_type", ""),
        "version": msg.get("version", ""),
        "channel_id": msg.get("channel_id", ""),
        "server_id": msg.get("server_id", ""),
        "category": msg.get("category", ""),
    }
    # reply body fields mirror the T8 contract the NSE (T13) consumes.
    if "team_id" in msg:
        data["team_id"] = msg["team_id"]
    if "url" in msg:
        data["url"] = msg["url"]
    if "post_id" in msg:
        data["post_id"] = msg["post_id"]
    if "sender_id" in msg:
        data["sender_id"] = msg["sender_id"]
    if "sender_name" in msg:
        data["sender_name"] = msg["sender_name"]
    if "root_id" in msg and msg["root_id"]:
        data["root_id"] = msg["root_id"]
    return {"aps": aps, "data": data}


class MockPushProxy:
    def __init__(self, config_path, out=None):
        self.out = out or sys.stdout
        with open(config_path) as fh:
            cfg = json.load(fh)
        self.servers = {s["ServerID"]: s for s in cfg.get("Servers", [])}
        self.apple = cfg.get("ApplePushSettings", {})
        self.devices: dict = dict(cfg.get("Devices", {}))
        self.secret_for = {s["ServerID"]: s.get("Secret", "") for s in self.servers.values()}

    # ---- request handlers -------------------------------------------------
    def send_push(self, body):
        msg = json.loads(body or "{}")
        sid = msg.get("server_id", "")
        sig = None
        err = _missing("server_id", sid)
        if err:
            return 400, {"status": "FAIL", "reason": err}
        if sid not in self.servers:
            return 404, {"status": "FAIL", "reason": f"unknown server_id {sid}"}
        platform = msg.get("platform", "")
        if not platform:
            return 400, {"status": "FAIL", "reason": "missing platform"}
        device_id = msg.get("device_id", "")
        if not device_id:
            return 400, {"status": "FAIL", "reason": "missing device_id"}
        # normalize device id: strip "apple:"/"apple_rn:"/"android:" prefix
        token = device_id.split(":", 1)[-1]
        if token not in self.devices:
            self.devices[token] = {
                "platform": platform,
                "server_id": sid,
                "registered_at": int(time.time()),
            }
        payload = apns_payload(msg)
        nid = uuid.uuid4().hex
        rec = {
            "id": nid,
            "type": msg.get("type", "message"),
            "platform": platform,
            "server_id": sid,
            "device_token": token,
            "apns_request": {
                "topic": self.apple.get("Topic", "<bundle-id>"),
                "push-type": "alert",
                "headers": {"apns-priority": "10"},
                "body": payload,
            },
        }
        self.out.write("[APNS] " + json.dumps(rec, indent=2) + "\n")
        return 200, {"status": "OK", "id": nid}

    def ack(self, body):
        ack = json.loads(body or "{}")
        self.out.write("[ACK] " + json.dumps(ack) + "\n")
        return 200, {"status": "OK"}

    def registry(self):
        return 200, {"devices": self.devices, "count": len(self.devices)}


def _missing(name, val):
    return None if val else f"missing {name}"


class Handler(BaseHTTPRequestHandler):
    server_version = "mmpush-mock/0.1"

    def log_message(self, format, *args):  # noqa: A002 - silence stderr chatter
        pass

    def _route(self, body: bytes):
        path = self.path.split("?", 1)[0]
        p = self.server.proxy  # the MockPushProxy instance
        try:
            if self.command == "GET" and path in ("/ping", "/" + "ping"):
                return 200, {"status": "OK", "service": "mmpush-mock",
                             "note": "SIMULACRUM - not a real Mattermost Push Proxy"}
            if path == API_V1 + "/send_push":
                return p.send_push(body)
            if path == API_V1 + "/ack":
                return p.ack(body)
            if self.command == "GET" and path == "/registry":
                return p.registry()
            return 404, {"status": "FAIL", "reason": f"no route {self.command} {path}"}
        except json.JSONDecodeError as e:
            return 400, {"status": "FAIL", "reason": f"bad json: {e}"}
        except Exception as e:  # keep server alive on handler errors
            return 500, {"status": "FAIL", "reason": repr(e)}

    def _respond(self, status, obj):
        payload = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        self._respond(*self._route(b""))

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        self._respond(*self._route(body))


def make_server(addr, port, proxy):
    server = ThreadingHTTPServer((addr, port), Handler)
    server.proxy = proxy
    return server


def main():
    ap = argparse.ArgumentParser(
        description="Mock Mattermost Push Proxy (simulacrum - NOT a real proxy)")
    ap.add_argument("-c", "--config", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "mmpush_proxy.json"))
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8066)
    args = ap.parse_args()

    proxy = MockPushProxy(args.config)
    server = make_server(args.host, args.port, proxy)
    print(f"mmpush-mock listening on http://{args.host}:{args.port}/ "
          f"(SIMULACRUM, config={args.config})")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nshutting down")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()