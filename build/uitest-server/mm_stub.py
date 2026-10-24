#!/usr/bin/env python3
"""Deterministic local Mattermost stub for XCUITest.

Simulator shares the host network stack, so 127.0.0.1 on this host is reachable from
the app under test. The stub answers the two endpoints ServerURLValidator probes so the
app's add-server form can validate offline/deterministically:
  GET /api/v4/system/ping           -> {"status":"OK"}
  GET /api/v4/config/client         -> {"SiteName": <name>, "Version":"6.4.0"}
Plus a trivial HTML page for the webview (login-through-webview smoke), and a
webview-downloadable file so the Downloads flow has a real landed file.

Run (HTTP):    python3 mm_stub.py --port 8065
Run (TLS):     python3 mm_stub.py --port 8443 --tls cert.pem key.pem
Run (slow):    python3 mm_stub.py --port 8112 --stall-image 45

`--stall-image SECONDS` serves `GET /` as a normal page (delivered whole, so WKWebView commits it)
whose `<img src="/slow.png">` is trickled across SECONDS, and gates a `Sign in` button on that
image's `onload`. The load therefore stays in flight after the document commits — the state the
T26-R R6 repro needs: a surface toggle that dismantles the web branch interrupts a real, unfinished
navigation, and the button only ever appears if that navigation is resumed and completes.
"""
import argparse
import json
import ssl
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer, HTTPServer

SITE_NAME = "Local Mattermost Test"

# T31: the model `GET /api/v4/users/me` and both login routes answer with. Only the fields the
# native client decodes are present; `MMUser` defaults the rest, as it must for real servers.
USER = {
    "id": "stubuser00000000000000001",
    "username": "stub-user",
    "email": "stub@example.com",
    "first_name": "Stub",
    "last_name": "User",
    "nickname": "stub",
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # silence request logging
        pass

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _stalled_html(self):
        """Page whose main document commits fast but whose `<img>` never finishes (R6 fixture).

        The document is delivered whole, so WKWebView commits it (`url != nil`) and fires
        `didCommit`; the load is still in flight because `GET /slow.png` trickles. The `Sign in`
        button is `hidden` until the image's `onload` runs, so "the button exists" means "the page
        actually finished loading" — which, after a surface toggle interrupted it, can only happen
        if the shell resumed the navigation.
        """
        html = (
            "<html><head><title>Local MM Sign in</title></head><body>"
            "<h1>Local MM Sign in</h1>"
            "<img id='slow' src='/slow.png' style='width:4px;height:4px' "
            "onload=\"document.getElementById('loginButton').hidden=false\">"
            "<button id='loginButton' hidden>Sign in</button>"
            "</body></html>"
        )
        print("stalled-page served (slow subresource makes the load in flight)", flush=True)
        return self._send(200, html, "text/html")

    def _slow_image(self):
        """1x1 GIF trickled across `stall_image` seconds: the image (and the page load) hangs."""
        gif = (b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff!\xf9\x04\x01"
               b"\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;")
        delay = getattr(self.server, "stall_image", 0.0)
        print(f"slow.png requested: first {len(gif) // 2} bytes now, rest in {delay}s", flush=True)
        self.send_response(200)
        self.send_header("Content-Type", "image/gif")
        self.send_header("Content-Length", str(len(gif)))
        self.send_header("Connection", "close")
        self.end_headers()
        half = len(gif) // 2
        self.wfile.write(gif[:half])
        self.wfile.flush()
        time.sleep(delay)
        self.wfile.write(gif[half:])
        self.wfile.flush()

    def do_POST(self):
        """T31 auth fixtures: the two login routes, plus logout.

        `POST /api/v4/users/login`
          login_id `mfa@example.com`      -> 401 `api.context.mfa_required` (drives the MFA step)
          password `wrong-password`       -> 401 `api.user.login.invalid_credentials_email_username`
          anything else                   -> 200 + `Token:` header (drives a completed sign-in)
        `POST /api/v4/users/login/mfa`
          token `123456`                  -> 200 + `Token:` header
          any other token                 -> 401 `api.user.login.invalid_mfa`
        """
        path = self.path.split("?")[0]
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw or b"{}")
        except Exception:
            body = {}
        if not isinstance(body, dict):
            body = {}
        if path == "/api/v4/users/login":
            if body.get("login_id") == "mfa@example.com":
                return self._send(401, json.dumps({
                    "id": "api.context.mfa_required",
                    "message": "MFA required",
                    "status_code": 401,
                }))
            if body.get("password") == "wrong-password":
                return self._send(401, json.dumps({
                    "id": "api.user.login.invalid_credentials_email_username",
                    "message": "Enter a valid email or username and/or password.",
                    "status_code": 401,
                }))
            data = json.dumps(USER).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Token", "stub-token-native")
            self.end_headers()
            self.wfile.write(data)
            return
        if path == "/api/v4/users/login/mfa":
            if body.get("token") == "123456":
                data = json.dumps(USER).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Token", "stub-token-mfa")
                self.end_headers()
                self.wfile.write(data)
                return
            return self._send(401, json.dumps({
                "id": "api.user.login.invalid_mfa",
                "message": "Invalid MFA token",
                "status_code": 401,
            }))
        if path == "/api/v4/users/logout":
            return self._send(200, json.dumps({"status": "OK"}))
        return self._send(404, json.dumps({"error": "not found"}))

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/slow.png":
            return self._slow_image()
        if path == "/api/v4/users/me":
            # T31 fixture: the identity call `AuthSession.restore()` validates a stored token with.
            # `--session-invalid` makes it answer the way a server answers an expired session, which
            # is how the "session expired" re-auth banner is exercised end to end.
            if getattr(self.server, "session_invalid", False):
                return self._send(401, json.dumps({
                    "id": "api.context.session_expired.app_error",
                    "message": "Session expired",
                    "status_code": 401,
                }))
            return self._send(200, json.dumps(USER))
        if path == "/__session-fixture":
            # Capability probe for the T26-R R4a release/reopen test: tells the test whether this
            # stub instance was started with the cookie-session page, and how long it stalls the
            # authenticated response (so the app's "Reopening web view…" state is observable).
            return self._send(200, json.dumps({
                "session": getattr(self.server, "cookie_session", 0.0) > 0,
                "delay_s": getattr(self.server, "cookie_session", 0.0),
            }))
        if path == "/api/v4/system/ping":
            return self._send(200, json.dumps({"status": "OK"}))
        if path == "/api/v4/config/client":
            return self._send(200, json.dumps({
                "Version": "6.4.0",
                "SiteURL": f"http://127.0.0.1:{self.server.server_port}",
                "SiteName": SITE_NAME,
                "HelpLink": "https://docs.mattermost.com/guides/user.html",
                "ReportAProblemLink": "https://mattermost.com/support",
            }))
        if path in ("/", "/index.html"):
            if getattr(self.server, "stall_image", 0.0) > 0:
                return self._stalled_html()
            delay = getattr(self.server, "cookie_session", 0.0)
            if delay > 0:
                return self._cookie_session_page(delay)
            # A fake but real web-login-ish page for the login-through-webview smoke.
            return self._send(
                200,
                "<html><head><title>Local MM Sign in</title></head><body>"
                "<input id='loginId' placeholder='Email'>"
                "<input id='loginPassword' type='password' placeholder='Password'>"
                "<button id='loginButton'>Sign in</button></body></html>",
                "text/html",
            )
        if path == "/downloads/hello.txt":
            return self._send(200, "hello from stub\n", "text/plain")
        return self._send(404, json.dumps({"error": "not found"}))

    def _cookie_session_page(self, delay):
        """Session-survives-a-release fixture (T26-R R4a).

        First visit (no `MMAUTHTOKEN` cookie): plant the cookie and serve the sign-in page. Every
        later visit carrying that cookie: stall `delay` seconds, then serve the signed-in
        workspace page — which has **no** login form. The cookie lives in the app's persistent
        per-server `WKWebsiteDataStore`, so "the reopened pane shows the workspace, not a sign-in
        form" can only be true if releasing the webview kept the session.
        """
        cookie = self.headers.get("Cookie") or ""
        if "MMAUTHTOKEN=" not in cookie:
            print("session page: sign-in (cookie planted)", flush=True)
            body = (
                "<html><head><title>Local MM Sign in</title></head><body>"
                "<h1>Local MM Sign in</h1>"
                "<input id='loginId' placeholder='Email'>"
                "<input id='loginPassword' type='password' placeholder='Password'>"
                "<button id='loginButton'>Sign in</button></body></html>"
            )
            data = body.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(data)))
            # `Max-Age` matters: a session cookie dies with the web process, which is exactly what a
            # release destroys. Mattermost's own `MMAUTHTOKEN` is persistent, and so is this one.
            self.send_header("Set-Cookie", "MMAUTHTOKEN=stub-session; Path=/; Max-Age=86400")
            self.end_headers()
            self.wfile.write(data)
            return
        time.sleep(delay)
        print(f"session page: workspace after {delay}s (cookie present)", flush=True)
        body = (
            "<html><head><title>Local MM Workspace</title></head><body>"
            "<div class='sidebar--left'>sidebar</div>"
            "<h1>Workspace</h1>"
            "<div class='post-list'><div id='post_1'>seeded post</div></div>"
            "</body></html>"
        )
        self._send(200, body, "text/html")


class StubStallServer(ThreadingHTTPServer):
    """Threaded stub for the fixtures whose responses stall, so a stalled page load stays in
    flight (R6) or the authenticated page arrives late (T26-R R4a) without blocking validation."""
    stall_image = 0.0
    cookie_session = 0.0
    session_invalid = False


class StubServer(HTTPServer):
    """The plain stub. Carries the T31 `--session-invalid` switch as a real attribute."""
    session_invalid = False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8065)
    ap.add_argument("--tls")
    ap.add_argument("--name", default="Local Mattermost Test")
    ap.add_argument("--stall-image", type=float, default=0.0,
                    help="trickle /slow.png over this many seconds so a page load stays in flight "
                         "(R6 repro fixture; also switches GET / to the onload-gated page)")
    ap.add_argument("--cookie-session", type=float, default=0.0,
                    help="serve a cookie-gated page: the first GET / plants MMAUTHTOKEN and shows "
                         "the sign-in form, later requests stall this many seconds then show a "
                         "signed-in workspace page (T26-R R4a release/reopen fixture)")
    ap.add_argument("--session-invalid", action="store_true",
                    help="answer GET /api/v4/users/me with 401 api.context.session_expired "
                         "(T31 re-auth banner fixture)")
    args = ap.parse_args()
    global SITE_NAME
    SITE_NAME = args.name
    # A trickled or stalled response must not block the validation endpoints, so both fixtures run
    # threaded.
    if args.stall_image > 0:
        srv = StubStallServer(("127.0.0.1", args.port), Handler)
        srv.stall_image = args.stall_image
    elif args.cookie_session > 0:
        srv = StubStallServer(("127.0.0.1", args.port), Handler)
        srv.cookie_session = args.cookie_session
    else:
        srv = StubServer(("127.0.0.1", args.port), Handler)
    srv.session_invalid = bool(args.session_invalid)
    if args.tls:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        certfile, keyfile = args.tls.split(",")
        ctx.load_cert_chain(certfile, keyfile)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    proto = "https" if args.tls else "http"
    print(f"stub listening {proto}://127.0.0.1:{args.port}", flush=True)
    sys.stdout.flush()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()