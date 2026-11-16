#!/usr/bin/env python3
"""Which body shape does `PUT /users/{id}/status/custom` accept on 9.11.19? (t_9dd73395)

`ProfileAPI.swift`'s header claims the custom status goes **flat** and that wrapping it in
`custom_status` answers 400. The name in the server's error (`SetInvalidParamWithErr("custom_status")`)
made that look wrong, so this probe asks the pinned server both ways, and pins the one rule the app
must satisfy: a `duration` without a future `expires_at` is refused
(`model.CustomStatus.AreDurationAndExpirationTimeValid`, release-9.11 `server/public/model/custom_status.go`).

  A  flat, emoji only, no duration                → the menu's emoji-only status
  B  flat, text only, no duration                 → the menu's text-only status
  C  flat, duration "one_hour" + expires_at        → what the editor writes when a duration is chosen
  D  flat, duration "one_hour" with **no** expiry → the 400 the editor must not send
  E  wrapped in {"custom_status": {...}}          → the header's claim (expected 400)
  F  DELETE, then read back                       → the menu's clear

Reads go through `user.props.customStatus`, which is where the app reads a status back
(`GET …/status/custom` does not exist on 9.11.19 — 404).

Usage: python3 scripts/t_9dd73395_custom_status_probe.py [--url http://127.0.0.1:8065]
Dev-only credential, as in the other probes here; this is the throwaway `mm-perf` container.
"""
import argparse
import json
import time
import urllib.error
import urllib.request

LOGIN = "perfprobe"
PASSWORD = "PerfProbe-Not-A-Real-Secret-1"


def call(base, path, data=None, token=None, method=None):
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(base + path, data=body, method=method or ("POST" if body else "GET"))
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None), resp.headers.get("Token")
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            parsed = json.loads(raw) if raw else None
        except ValueError:
            parsed = raw.decode("utf-8", "replace")[:200]
        return exc.code, parsed, None


def props(base, uid, token):
    _, me, _ = call(base, f"/users/{uid}", token=token)
    return (me or {}).get("props", {}).get("customStatus", "<absent>")


def shorten(status, body):
    if isinstance(body, dict):
        body = {k: body[k] for k in ("id", "message", "status") if k in body}
    return f"HTTP {status}  {json.dumps(body)}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    args = parser.parse_args()
    base = args.url.rstrip("/") + "/api/v4"

    status, me, token = call(base, "/users/login", {"login_id": LOGIN, "password": PASSWORD})
    if status != 200 or not token:
        raise SystemExit(f"login failed: HTTP {status} {me}")
    uid = me["id"]
    print(f"user {uid}\n")

    expiry = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 3600))
    # The app's encoder writes milliseconds (`.000Z`); Go's time.Time parses the fraction, but the
    # body shape is a rule the server owns, so it is measured rather than assumed.
    fractional = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() + 3600))
    cases = [
        ("A emoji only, no duration", {"emoji": "coffee"}),
        ("B text only, no duration", {"text": "Text only"}),
        ("C duration + expires_at", {"emoji": "coffee", "text": "For an hour",
                                     "duration": "one_hour", "expires_at": expiry}),
        ("C2 ... with .000Z (the app's shape)", {"emoji": "coffee", "text": "For an hour",
                                                 "duration": "one_hour", "expires_at": fractional}),
        ("D duration, no expires_at", {"emoji": "coffee", "text": "For an hour",
                                       "duration": "one_hour"}),
        ("E wrapped in custom_status", {"custom_status": {"emoji": "coffee", "text": "Wrapped"}}),
    ]
    for label, body in cases:
        code, answer, _ = call(base, f"/users/{uid}/status/custom", body, token=token, method="PUT")
        print(f"{label:<28} {shorten(code, answer)}")
        print(f"{'':<28} props.customStatus = {props(base, uid, token)}")

    print(f"\nF DELETE                     {shorten(*call(base, f'/users/{uid}/status/custom', token=token, method='DELETE')[:2])}")
    print(f"{'':<28} props.customStatus = {props(base, uid, token)}")


if __name__ == "__main__":
    main()
