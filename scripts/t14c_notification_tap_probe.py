#!/usr/bin/env python3
"""Measure the server's answers for the *tap-through* cases a notification can land in.

The card these numbers exist for (t_14c96dfd) has to show the pinned client's fallback sentences
when a tapped notification's post or channel no longer resolves. Upstream decides that from REST
answers (`app/actions/remote/notifications.ts` `fetchNotificationData`, and
`app/actions/remote/entry/notification.ts`), so the mapping from HTTP status to sentence is only
honest if it is measured rather than assumed:

  * `GET /users/me/teams/{team_id}/channels/{channel_id}` — upstream `fetchMyChannel`. Measured for
    a channel I am in, a public channel I am not in, a private channel I am not in, a channel that
    does not exist, an archived channel, and a direct message.
  * `GET /channels/{channel_id}` — the `delete_at` probe that tells an archived channel apart from a
    live one.
  * `GET /posts/{post_id}` — measured for a live post, a soft-deleted post, a post in a channel I am
    not a member of, and an id that does not exist.

Nothing here is a credential: the fixture passwords are throwaway local values and a token only
ever reaches a request header. The probe is self-contained on the fixture server — the admin account
`perfprobe` is the one the app signs in as, and everything else it needs (a second account, a
public/private/archived channel the admin is not in, a direct message, a live and a deleted post) it
creates idempotently.

    python3 scripts/t14c_notification_tap_probe.py --url http://127.0.0.1:8065
    python3 scripts/t14c_notification_tap_probe.py --url http://127.0.0.1:8065 --json
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request

ADMIN_LOGIN = "perfprobe"
ADMIN_PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
BUDDY_LOGIN = "t14c-buddy"
BUDDY_PASSWORD = "T14c-Buddy-Not-A-Real-Secret-1"
BUDDY_EMAIL = "t14c-buddy@example.invalid"
ADMIN_ONLY_PUBLIC = "t14c-admin-only"
ADMIN_ONLY_PRIVATE = "t14c-admin-private"
PUBLIC_ABSENT = "t14c-public-absent"
PRIVATE_ABSENT = "t14c-private-absent"
ARCHIVED = "t14c-archived"
GHOST_ID = "aaaaaaaaaaaaaaaaaaaaaaaaaa"


def call(url: str, method: str, path: str, body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url.rstrip("/") + "/api/v4" + path, data=data, method=method)
    request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = response.read()
            return response.status, parse(raw), {k.lower(): v for k, v in response.getheaders()}
    except urllib.error.HTTPError as error:
        raw = error.read()
        return error.code, parse(raw), {k.lower(): v for k, v in error.headers.items()}


def parse(raw: bytes):
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {"raw": raw[:200].decode(errors="replace")}


def login(url: str, name: str, password: str):
    status, body, headers = call(url, "POST", "/users/login", {"login_id": name, "password": password})
    if status != 200:
        raise SystemExit(f"login {name} failed: {status} {body}")
    # Mattermost answers the session token in the `Token` response header, not in the body.
    token = headers.get("token")
    if not token:
        raise SystemExit(f"login {name} returned no Token header")
    body["token"] = token
    return body


def channel_id_by_name(url: str, team_id: str, name: str, token: str):
    # `include_deleted` so the *archived* channel the probe made last run is found instead of
    # re-created (the server answers 400 "already exists", and a 404 lookup would look like it is
    # gone for ever).
    status, body, _ = call(url, "GET", f"/teams/{team_id}/channels/name/{name}?include_deleted=true",
                           token=token)
    return body.get("id") if status == 200 else None


def ensure_channel(url, team_id, name, kind, token, display=None):
    existing = channel_id_by_name(url, team_id, name, token)
    if existing:
        return existing
    status, body, _ = call(url, "POST", "/channels", {
        "team_id": team_id, "name": name, "display_name": display or name, "type": kind,
    }, token=token)
    if status not in (200, 201):
        raise SystemExit(f"create {name} failed: {status} {body}")
    return body["id"]


def team_id_for(url, team_name, token):
    status, body, _ = call(url, "GET", f"/teams/name/{team_name}", token=token)
    if status != 200:
        raise SystemExit(f"team {team_name} missing: {status} {body}")
    return body["id"]


def ensure_buddy(url, admin_token):
    """The second account, created by the admin when it does not exist yet."""
    status, body, _ = call(url, "GET", f"/users/username/{BUDDY_LOGIN}", token=admin_token)
    if status == 200:
        return body, login(url, BUDDY_LOGIN, BUDDY_PASSWORD)["token"]
    status, body, _ = call(url, "POST", "/users", {
        "email": BUDDY_EMAIL, "username": BUDDY_LOGIN, "password": BUDDY_PASSWORD,
        "first_name": "T14C", "last_name": "Buddy",
    }, token=admin_token)
    if status not in (200, 201):
        raise SystemExit(f"create {BUDDY_LOGIN} failed: {status} {body}")
    return body, login(url, BUDDY_LOGIN, BUDDY_PASSWORD)["token"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    url = args.url

    admin = login(url, ADMIN_LOGIN, ADMIN_PASSWORD)
    admin_id, admin_token = admin["id"], admin["token"]
    buddy, buddy_token = ensure_buddy(url, admin_token)
    buddy_id = buddy["id"]

    status, teams, _ = call(url, "GET", "/users/me/teams", token=admin_token)
    if status != 200 or not teams:
        raise SystemExit(f"no teams for {ADMIN_LOGIN}: {status}")
    team_id = teams[0]["id"]

    # The channel both accounts are in. Read from the **buddy's** list, not the admin's: the admin is a
    # system admin and its list can hold a channel the buddy was never added to, and a post created
    # there answers 403 (that is the "not a member" case, measured separately below).
    status, buddy_channels, _ = call(url, "GET", f"/users/me/teams/{team_id}/channels", token=buddy_token)
    if status != 200:
        raise SystemExit(f"cannot list the buddy's channels: {status}")
    member_channel = next((c for c in buddy_channels if c["type"] == "O"), None)
    if not member_channel:
        raise SystemExit("the buddy account is in no public channel of its first team")
    member_id = member_channel["id"]

    # The second account has to be in the team to make channels in it (idempotent: a second add
    # answers 400 `store.sql_team.save_member.exists.app_error`, which is the state we want).
    call(url, "POST", f"/teams/{team_id}/members", {"team_id": team_id, "user_id": buddy_id},
         token=admin_token)

    public_absent = ensure_channel(url, team_id, PUBLIC_ABSENT, "O", buddy_token)
    private_absent = ensure_channel(url, team_id, PRIVATE_ABSENT, "P", buddy_token)
    archived = ensure_channel(url, team_id, ARCHIVED, "O", buddy_token)
    # Channels only the admin is in, so a *non-admin* can be measured on the "not a member" side
    # (the fixture admin is a system admin and reads channels it is not in).
    admin_only_public = ensure_channel(url, team_id, ADMIN_ONLY_PUBLIC, "O", admin_token)
    admin_only_private = ensure_channel(url, team_id, ADMIN_ONLY_PRIVATE, "P", admin_token)

    # Archive it (idempotent: archiving twice answers 200 either way).
    call(url, "DELETE", f"/channels/{archived}", token=buddy_token)

    # A direct message between the two accounts (one per pair, the server dedupes).
    status, direct, _ = call(url, "POST", "/channels/direct", [admin_id, buddy_id], token=admin_token)
    dm_id = direct.get("id") if status in (200, 201) else None

    # A live post and then a soft-deleted one, in the channel both accounts are in.
    status, live, _ = call(url, "POST", "/posts", {"channel_id": member_id, "message": "t14c probe live"}, token=buddy_token)
    live_post = live.get("id") if status == 201 else None
    status, doomed, _ = call(url, "POST", "/posts", {"channel_id": member_id, "message": "t14c probe doomed"}, token=buddy_token)
    doomed_post = doomed.get("id") if status == 201 else None
    if doomed_post:
        call(url, "DELETE", f"/posts/{doomed_post}", token=buddy_token)
    # A post in the public channel the admin is not a member of.
    status, foreign, _ = call(url, "POST", "/posts", {"channel_id": public_absent, "message": "t14c probe foreign"}, token=buddy_token)
    foreign_post = foreign.get("id") if status == 201 else None

    observations = []

    def record(name, method, path, status, body, token="admin"):
        observations.append({
            "case": name,
            "request": f"{method} {path}",
            "as": token,
            "status": status,
            "id": body.get("id"),
            "message": body.get("message"),
            "delete_at": body.get("delete_at"),
            "channel_id": body.get("channel_id"),
        })

    def membership(case, channel_id, token=None, who="admin"):
        token = token or admin_token
        status, body, _ = call(url, "GET", f"/channels/{channel_id}/members/me", token=token)
        record(case, "GET", f"/channels/{channel_id}/members/me", status, body, who)

    def channel_get(case, channel_id, token=None, who="admin"):
        token = token or admin_token
        status, body, _ = call(url, "GET", f"/channels/{channel_id}", token=token)
        record(case, "GET", f"/channels/{channel_id}", status, body, who)

    def post_get(case, post_id, token=None, who="admin"):
        token = token or admin_token
        status, body, _ = call(url, "GET", f"/posts/{post_id}", token=token)
        record(case, "GET", f"/posts/{post_id}", status, body, who)

    # The endpoint this probe first reached for does not exist on 9.11.19: every request comes back
    # with the router's own `api.context.404.app_error` ("we could not find the page"), including a
    # channel the account is in. Recorded so nobody re-introduces it.
    status, body, _ = call(url, "GET", f"/users/me/teams/{team_id}/channels/{member_id}", token=admin_token)
    record("membership: /users/me/teams/{t}/channels/{c} is not a route", "GET",
           "/users/me/teams/{team}/channels/{channel}", status, body)

    membership("membership: channel I am in", member_id)
    membership("membership: public channel I am not in", public_absent)
    membership("membership: private channel I am not in", private_absent)
    membership("membership: channel that does not exist", GHOST_ID)
    membership("membership: archived channel I was never in", archived)
    if dm_id:
        membership("membership: direct message", dm_id)

    # The same questions asked by a non-admin account (the fixture admin is a system admin, and a
    # system admin may read a channel it is not a member of — the tap fallback must not be written
    # against admin privileges).
    membership("membership: (non-admin) a channel it is in", public_absent, buddy_token, "buddy")
    membership("membership: (non-admin) a public channel it is not in", admin_only_public, buddy_token, "buddy")
    membership("membership: (non-admin) a private channel it is not in", admin_only_private, buddy_token, "buddy")
    membership("membership: (non-admin) archived channel it was in", archived, buddy_token, "buddy")
    membership("membership: (non-admin) a channel that does not exist", GHOST_ID, buddy_token, "buddy")
    channel_get("channel: (non-admin) a public channel it is not in", admin_only_public, buddy_token, "buddy")
    channel_get("channel: (non-admin) a private channel it is not in", admin_only_private, buddy_token, "buddy")
    channel_get("channel: (non-admin) archived channel it was in", archived, buddy_token, "buddy")

    channel_get("channel: channel I am in", member_id, admin_token)
    channel_get("channel: public channel I am not in", public_absent, admin_token)
    channel_get("channel: private channel I am not in", private_absent, admin_token)
    channel_get("channel: archived channel", archived, admin_token)
    channel_get("channel: channel that does not exist", GHOST_ID, admin_token)

    if live_post:
        post_get("post: live post", live_post, admin_token)
    if doomed_post:
        post_get("post: soft-deleted post", doomed_post, admin_token)
    if foreign_post:
        post_get("post: post in a public channel I am not in", foreign_post, admin_token)
    post_get("post: post that does not exist", GHOST_ID, admin_token)

    # A post in a private channel the admin is not in: the same 403/404 question as above.
    status, secret, _ = call(url, "POST", "/posts", {"channel_id": private_absent, "message": "t14c probe secret"}, token=buddy_token)
    if status == 201:
        post_get("post: post in a private channel I am not in", secret["id"], admin_token)

    # And the same question asked by the account that is not a member (the informative one).
    status, locked, _ = call(url, "POST", "/posts", {"channel_id": admin_only_private, "message": "t14c probe locked"}, token=admin_token)
    if status == 201:
        post_get("post: (non-admin) post in a private channel it is not in", locked["id"], buddy_token, "buddy")

    if args.json:
        print(json.dumps(observations, indent=2))
    else:
        for row in observations:
            print(f"{row['case']:52s} {row['status']:>4}  id={row['id']} delete_at={row['delete_at']} "
                  f"msg={str(row['message'])[:48]}")
    return 0


def _admin_token(url):
    return login(url, ADMIN_LOGIN, ADMIN_PASSWORD)["token"]


if __name__ == "__main__":
    sys.exit(main())
