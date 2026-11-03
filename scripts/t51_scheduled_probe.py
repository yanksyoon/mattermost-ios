#!/usr/bin/env python3
"""Measure the scheduled-post contract on the pinned Mattermost 9.11.19 fixture (T51/S40).

The card says to measure before modelling. This probe answers one question for each route the
scheduled-post half needs:

    POST   /posts/schedule
    GET    /posts/scheduled/team/{team_id}
    GET    /posts/scheduled/{id}
    PUT    /posts/schedule/{id}
    DELETE /posts/schedule/{id}

and, if scheduling is available at all, what `create_at` shape it takes (epoch seconds or
milliseconds) and whether a recurrence can be expressed. On this fixture **every route answers
404 `api.context.404.app_error`** ("There doesn't appear to be an api call for the url=…"), i.e.
the feature is not registered on a Team Edition build — so T51 ships the drafts half only and
the scheduled half is a named follow-up (docs/t51-build-note.md §6).

    python3 scripts/t51_scheduled_probe.py

The probe creates (or reuses) `t51probe` by open sign-up and a team only if the account has none;
it stores no credential in the repository. Exit code 0 means "measured" (whatever the answer);
exit 2 means the server could not be reached or the account could not be created.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

SERVER = os.environ.get("MM_PROBE_SERVER", "http://127.0.0.1:8065")
LOGIN = os.environ.get("MM_PROBE_LOGIN", "t51probe")
PASSWORD = os.environ.get("MM_PROBE_PASSWORD", "T51probe!pass")
EMAIL = LOGIN + "@example.com"


def call(method, path, token=None, body=None):
    url = SERVER + "/api/v4" + path
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def show(label, status, payload):
    text = payload.decode(errors="replace")
    try:
        parsed = json.loads(text)
        # Only the error identity matters to the build note; the message is the server's own.
        text = json.dumps({k: parsed.get(k) for k in ("id", "message", "status_code") if k in parsed})
    except Exception:
        text = text[:200]
    print(f"{label}: {status} {text}")


def main():
    status, payload = call("POST", "/users", body={"email": EMAIL, "username": LOGIN,
                                                   "password": PASSWORD})
    if status not in (200, 201):
        status, payload = call("POST", "/users/login", body={"login_id": LOGIN, "password": PASSWORD})
        if status != 200:
            print(f"account setup failed: {status} {payload[:200].decode(errors='replace')}")
            return 2
    status, payload = call("POST", "/users/login", body={"login_id": LOGIN, "password": PASSWORD})
    if status != 200:
        print(f"login failed: {status} {payload[:200].decode(errors='replace')}")
        return 2
    # The `Token` header is where v4 delivers the session token.
    token = None
    request = urllib.request.Request(SERVER + "/api/v4/users/login",
                                     data=json.dumps({"login_id": LOGIN, "password": PASSWORD}).encode(),
                                     method="POST")
    request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request, timeout=20) as response:
        token = response.headers.get("Token")
        me = json.loads(response.read())
    print(f"user {me['id']} {me['username']}")

    status, payload = call("GET", "/users/me/teams", token=token)
    teams = json.loads(payload) if status == 200 else []
    if not teams:
        status, payload = call("POST", "/teams", token=token,
                               body={"name": "t51probe-team", "display_name": "T51 Probe",
                                     "type": "O"})
        show("create team", status, payload)
        if status not in (200, 201):
            return 2
        teams = [json.loads(payload)]
    team = teams[0]
    print(f"team {team['id']} {team['name']}")

    status, payload = call("GET", f"/users/{me['id']}/teams/{team['id']}/channels", token=token)
    channels = json.loads(payload) if status == 200 else []
    if channels:
        channel = channels[0]
    else:
        status, payload = call("POST", "/channels", token=token,
                               body={"team_id": team["id"], "name": "t51-probe",
                                     "display_name": "T51 probe", "type": "O"})
        show("create channel", status, payload)
        if status not in (200, 201):
            return 2
        channel = json.loads(payload)
    print(f"channel {channel['id']} {channel['name']}")

    when = int(time.time()) + 120

    # 1. The list, before anything exists.
    status, payload = call("GET", f"/posts/scheduled/team/{team['id']}", token=token)
    show("GET  /posts/scheduled/team/{team_id}", status, payload)

    # 2. Create, in both documented `create_at` shapes. Recurrence is only modelled if the create
    #    route exists at all; on a server without the feature the field cannot be measured.
    status, payload = call("POST", "/posts/schedule", token=token,
                           body={"channel_id": channel["id"], "message": "t51 probe",
                                 "create_at": when * 1000})
    show("POST /posts/schedule (create_at ms)", status, payload)
    created = None
    if status in (200, 201):
        created = json.loads(payload)
    else:
        status, payload = call("POST", "/posts/schedule", token=token,
                               body={"channel_id": channel["id"], "message": "t51 probe",
                                     "create_at": when})
        show("POST /posts/schedule (create_at s)", status, payload)
        if status in (200, 201):
            created = json.loads(payload)

    if not created:
        print("\nMEASURED: this server has no scheduled-post API. The four remaining routes are "
              "reported below for the record; no request of this shape may ship untested.")
        status, payload = call("GET", f"/posts/scheduled/{'x' * 26}", token=token)
        show("GET  /posts/scheduled/{id}", status, payload)
        status, payload = call("PUT", f"/posts/schedule/{'x' * 26}", token=token,
                               body={"id": "x" * 26, "channel_id": channel["id"],
                                     "message": "t51 probe", "create_at": when * 1000})
        show("PUT  /posts/schedule/{id}", status, payload)
        status, payload = call("DELETE", f"/posts/schedule/{'x' * 26}", token=token)
        show("DELETE /posts/schedule/{id}", status, payload)
        return 0

    # 3. A server that does answer: exercise the whole lifecycle and clean up.
    sid = created.get("id")
    print(f"created {sid} create_at={created.get('create_at')}")
    status, payload = call("GET", f"/posts/scheduled/team/{team['id']}", token=token)
    show("GET  /posts/scheduled/team/{team_id} after create", status, payload)

    status, payload = call("PUT", f"/posts/schedule/{sid}", token=token,
                           body={"id": sid, "channel_id": channel["id"],
                                 "message": "t51 probe rescheduled", "create_at": (when + 180) * 1000})
    show("PUT  /posts/schedule/{id}", status, payload)

    status, payload = call("DELETE", f"/posts/schedule/{sid}", token=token)
    show("DELETE /posts/schedule/{id}", status, payload)
    status, payload = call("GET", f"/posts/scheduled/team/{team['id']}", token=token)
    show("GET  /posts/scheduled/team/{team_id} after delete", status, payload)

    # 4. The two refusals the client's derivation must mirror.
    status, payload = call("POST", "/posts/schedule", token=token,
                           body={"channel_id": channel["id"], "message": "",
                                 "create_at": (when + 120) * 1000})
    show("POST /posts/schedule empty message", status, payload)
    status, payload = call("POST", "/posts/schedule", token=token,
                           body={"channel_id": channel["id"], "message": "past",
                                 "create_at": (int(time.time()) - 600) * 1000})
    show("POST /posts/schedule in the past", status, payload)
    if status in (200, 201):
        call("DELETE", f"/posts/schedule/{json.loads(payload)['id']}", token=token)
    return 0


if __name__ == "__main__":
    sys.exit(main())
