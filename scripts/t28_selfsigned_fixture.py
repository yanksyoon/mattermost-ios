#!/usr/bin/env python3
"""T28 self-signed TLS fixture: a minimal HTTPS Mattermost-ish server on 127.0.0.1.

Serves just enough of the v4 API for `SelfSignedTrustTests`:

    GET /api/v4/system/ping  ->  {"status":"OK","version":"t28-selfsigned"}

Run through `scripts/t28-selfsigned-check.sh`, which generates the throwaway certificate.
Exit code 0 after the server stops (SIGTERM from the harness).
"""
import argparse
import http.server
import json
import ssl
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "t28-fixture/1.0"

    def do_GET(self):  # noqa: N802 (http.server API)
        if self.path.split("?")[0] == "/api/v4/system/ping":
            body = json.dumps({"status": "OK", "version": "t28-selfsigned"}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()

    def log_message(self, format, *args):  # noqa: A002 (http.server API signature)
        sys.stderr.write("fixture: " + format % args + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    args = parser.parse_args()

    httpd = http.server.HTTPServer(("127.0.0.1", args.port), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.cert, args.key)
    httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
    sys.stderr.write("fixture: listening on https://127.0.0.1:%d\n" % args.port)
    sys.stderr.flush()
    httpd.serve_forever()


if __name__ == "__main__":
    main()
