#!/usr/bin/env python3
"""T28 self-signed TLS fixture: a minimal HTTPS + WSS Mattermost-ish server on 127.0.0.1.

Serves just enough of the v4 API for `SelfSignedTrustTests`:

    GET /api/v4/system/ping   ->  {"status":"OK","version":"t28-selfsigned"}
    GET /api/v4/websocket     ->  101 Switching Protocols (a WebSocket that sends one `hello`
                                  frame and then closes)

The WebSocket endpoint exists so the *real* `WebSocketTransport` (`URLSessionWebSocketTask` plus
the shared `TransportSessionDelegate`) can be exercised over TLS, not just the HTTPS path
(T28-AV finding F8). It speaks no more of the protocol than the handshake and one unmasked text
frame: it is a witness that the wss trust path works, not a Mattermost server.

Run through `scripts/t28-selfsigned-check.sh`, which generates the throwaway certificate.
Exit code 0 after the server stops (SIGTERM from the harness).
"""
import argparse
import base64
import hashlib
import http.server
import json
import ssl
import sys
import time

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "t28-fixture/1.0"
    # 101 Switching Protocols needs a 1.1 status line; the HTTPS responses keep Content-Length.
    protocol_version = "HTTP/1.1"

    def do_GET(self):  # noqa: N802 (http.server API)
        path = self.path.split("?")[0]
        if path == "/api/v4/websocket":
            self._serve_websocket()
            return
        if path == "/api/v4/system/ping":
            body = json.dumps({"status": "OK", "version": "t28-selfsigned"}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    # -- WebSocket ---------------------------------------------------------------

    def _serve_websocket(self):
        if self.headers.get("Upgrade", "").lower() != "websocket":
            self.send_response(400)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        key = self.headers.get("Sec-WebSocket-Key", "")
        digest = hashlib.sha1((key + WS_GUID).encode()).digest()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", base64.b64encode(digest).decode())
        self.end_headers()
        self.log_message("wss: upgrade accepted for %s", self.path)

        hello = json.dumps({
            "event": "hello",
            "seq": 1,
            "broadcast": {},
            "data": {"connection_id": "t28-fixture", "server_version": "t28-selfsigned"},
        }).encode()
        self._write_frame(0x1, hello)
        # Give the client a moment to receive the frame and send its authentication challenge,
        # then close cleanly (opcode 0x8, no payload). Client frames are not read: this fixture
        # proves the handshake and one server frame, nothing more.
        time.sleep(0.5)
        self._write_frame(0x8, b"")
        self.close_connection = True

    def _write_frame(self, opcode, payload):
        header = bytes([0x80 | opcode])
        length = len(payload)
        if length < 126:
            header += bytes([length])
        elif length < 65536:
            header += bytes([126]) + length.to_bytes(2, "big")
        else:
            header += bytes([127]) + length.to_bytes(8, "big")
        self.wfile.write(header + payload)
        self.wfile.flush()

    def log_message(self, format, *args):  # noqa: A002 (http.server API signature)
        sys.stderr.write("fixture: " + format % args + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    args = parser.parse_args()

    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    httpd.daemon_threads = True
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.cert, args.key)
    httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
    sys.stderr.write("fixture: listening on https://127.0.0.1:%d (https + wss)\n" % args.port)
    sys.stderr.flush()
    httpd.serve_forever()


if __name__ == "__main__":
    main()
