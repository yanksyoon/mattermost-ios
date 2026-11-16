#!/usr/bin/env python3
"""Can a client set Out of office, and what does the menu have to do instead? (t_9dd73395)

The card (`t_9dd73395` requirement 5) asks for Out of office to be **settable** from the account
menu. The account menu is built from the webapp's `user_account_menu.tsx:46-136`, whose OOO item is
`UserAccountOutOfOfficeMenuItem`; that component's click handler *leaves* OOO, and the client never
offers OOO as a choice of its own. This script asks the pinned 9.11.19 server whether that is a
deliberate server rule or a webapp omission, and records the exact refusal so the code and the card
can quote it:

  Case A  `PUT /users/{id}/status {"status": "ooo"}`             → what status code, what error id?
  Case B  `PUT /users/{id}/status {"status": "out_of_office"}`   → same question (the two spellings
                                                                   that appear in `model.Status`)
  Case C  `PUT /users/{id}/status {"status": "dnd"}`             → the control: a client-set status
                                                                   the server accepts
  Case D  `GET /users/{id}/status` after A/B/C                   → what the server actually holds
  Case E  `PUT /users/{id}/status/custom` + GET                  → the custom-status wire shape the
                                                                   menu's editor writes
  Case F  `DELETE /users/{id}/status/custom` + GET               → and the clear

Every refusal the app relies on is printed with its `id`, so `AccountMenuModels.swift`'s claim
("the server refuses a client-set ooo — measured 400") is this run's output, not a guess.

Usage: python3 scripts/t_9dd73395_ooo_probe.py [--url http://127.0.0.1:8065]
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


def show(label, result):
    status, body, _ = result
    if isinstance(body, dict):
        if "props" in body:
            body = dict(body)
            body["props.customStatus"] = body["props"].get("customStatus", "<absent>")
            body.pop("props")
        body = {k: body[k] for k in ("id", "message", "status", "user_id", "manual",
                                     "dnd_end_time", "emoji", "text", "duration", "expires_at",
                                     "props.customStatus")
                if k in body}
    print(f"{label:<34} HTTP {status}  {json.dumps(body)}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    args = parser.parse_args()
    base = args.url.rstrip("/") + "/api/v4"

    status, me, token = call(base, "/users/login", {"login_id": LOGIN, "password": PASSWORD})
    if status != 200 or not token:
        raise SystemExit(f"login failed: HTTP {status} {me}")
    uid = me["id"]
    ping_status, client_config, _ = call(base, "/config/client")
    version = (client_config or {}).get("Version", "?") if ping_status == 200 else "?"
    print(f"server {args.url}  user {uid}  server_version {version}\n")

    print("-- the question: is Out of office client-settable?")
    show("A PUT status=ooo", call(base, f"/users/{uid}/status",
                                  {"user_id": uid, "status": "ooo"}, token=token, method="PUT"))
    show("B PUT status=out_of_office", call(base, f"/users/{uid}/status",
                                            {"user_id": uid, "status": "out_of_office"},
                                            token=token, method="PUT"))
    show("C PUT status=dnd (control)", call(base, f"/users/{uid}/status",
                                            {"user_id": uid, "status": "dnd"}, token=token, method="PUT"))
    show("D GET status", call(base, f"/users/{uid}/status", token=token))

    print("\n-- custom status: the wire shape the editor writes (see the custom_status probe)")
    expiry = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 3600))
    show("E PUT status/custom", call(base, f"/users/{uid}/status/custom",
                                     {"emoji": "coffee", "text": "Probe vacation",
                                      "duration": "one_hour", "expires_at": expiry},
                                     token=token, method="PUT"))
    show("E GET me (customStatus)", call(base, f"/users/{uid}", token=token))
    show("F DELETE status/custom", call(base, f"/users/{uid}/status/custom",
                                        token=token, method="DELETE"))
    show("F GET me (customStatus)", call(base, f"/users/{uid}", token=token))

    # Leave the container the way it was found.
    show("restore online", call(base, f"/users/{uid}/status",
                                {"user_id": uid, "status": "online"}, token=token, method="PUT"))


if __name__ == "__main__":
    main()
