#!/usr/bin/env python3
"""Seed the local throwaway Mattermost server for T40 (native channel info / members / settings).

Why this exists: T40's acceptance criteria are statements about a **real** server's data, and three of
them need a server state that a fresh fixture does not have:

  * ``t40-standup`` — a public channel with a purpose and a header, which the info screen must *render*
    (not echo back from this script's expectations) and which the settings form must be able to change;
  * ``t40-browse-me`` — a public channel the signed-in account is **not** a member of, because "joining
    a public channel from the browser navigates straight into it" needs a channel that is joinable;
  * ``t40-goodbye`` — a public channel the account *is* in, because "leaving a channel removes it" needs
    a membership that exists;
  * ``t40member`` — a **non-admin** account, because the card's security assertion ("a non-admin cannot
    reach an admin-only action by any path") cannot be tested with the fixture's own system-admin probe
    account.

Idempotent: re-running reuses what exists, restores an archived channel, and re-establishes the
memberships the tests assume. Nothing is deleted that another card's fixtures use.

The non-admin account's password is a **fixture value for a throwaway local server**, exactly like
``scripts/perf_seed.py``'s ``PerfProbe-Not-A-Real-Secret-1``; it is not a secret and must never be
reused anywhere real. ``scripts/t40_channel_probe.py`` verifies the writes the UI performs, and is the
"oracle" the live test reads back through.

Usage:
    python3 scripts/t40_channel_seed.py --url http://127.0.0.1:8065
    python3 scripts/t40_channel_seed.py --url http://127.0.0.1:8065 --reset-roles
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

ADMIN_LOGIN = "perfprobe"
ADMIN_PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
MEMBER_LOGIN = "t40member"
MEMBER_PASSWORD = "T40-Member-Not-A-Real-Secret-1"
MEMBER_EMAIL = "t40member@example.invalid"
TEAM_NAME = "perf"

STANDUP = ("t40-standup", "T40 Standup", "Daily standup notes", "Standup at 09:15")
BROWSE = ("t40-browse-me", "T40 Browse Me", "A public channel nobody has joined yet", "")
GOODBYE = ("t40-goodbye", "T40 Goodbye", "A channel the leave test may leave", "")

# The permission ids this fixture's `channel_user` role carries, measured from the server on
# 2026-10-26. Not Mattermost's stock set: the local fixture grants the channel-administrator ids to
# ordinary members, which is why the app must gate on the *permissions array* rather than on role names
# (a role called `channel_user` that grants `delete_public_channel` would otherwise hide actions the
# server allows). Used only to undo a permission strip left by a crashed live test.
FIXTURE_CHANNEL_USER_PERMISSIONS = [
    "add_bookmark_private_channel",
    "add_bookmark_public_channel",
    "add_reaction",
    "create_post",
    "delete_bookmark_private_channel",
    "delete_bookmark_public_channel",
    "delete_post",
    "delete_private_channel",
    "delete_public_channel",
    "edit_bookmark_private_channel",
    "edit_bookmark_public_channel",
    "edit_post",
    "get_public_link",
    "manage_private_channel_members",
    "manage_private_channel_properties",
    "manage_public_channel_members",
    "manage_public_channel_properties",
    "order_bookmark_private_channel",
    "order_bookmark_public_channel",
    "read_channel",
    "read_channel_content",
    "read_private_channel_groups",
    "read_public_channel_groups",
    "remove_reaction",
    "upload_file",
    "use_channel_mentions",
    "use_group_mentions",
]


class Client:
    def __init__(self, base: str, token: str | None = None) -> None:
        self.base = base.rstrip("/")
        self.token = token

    def call(self, method: str, path: str, body=None, query=None, allow=(200, 201)):
        url = f"{self.base}/api/v4{path}"
        if query:
            url += "?" + "&".join(f"{k}={v}" for k, v in query.items())
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                raw = response.read()
                return response.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as error:
            raw = error.read()
            try:
                payload = json.loads(raw or b"null")
            except ValueError:
                payload = raw.decode(errors="replace")
            if error.code in allow:
                return error.code, payload
            raise SystemExit(f"{method} {path} -> {error.code} {payload}") from None

    def login(self, login: str, password: str) -> dict:
        """Sign in once and keep the `Token` header — the body is the user row."""
        request = urllib.request.Request(
            f"{self.base}/api/v4/users/login",
            data=json.dumps({"login_id": login, "password": password}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=20) as response:
            self.token = response.headers.get("Token")
            return json.loads(response.read())


def ensure_member_account(admin: Client, team_id: str) -> dict:
    """Create `t40member` (a plain `system_user`) if it is missing; return its user row."""
    status, user = admin.call("GET", f"/users/username/{MEMBER_LOGIN}", allow=(200, 404))
    if status == 404:
        status, user = admin.call(
            "POST",
            "/users",
            {
                "email": MEMBER_EMAIL,
                "username": MEMBER_LOGIN,
                "password": MEMBER_PASSWORD,
                "first_name": "T40",
                "last_name": "Member",
            },
        )
        print(f"  created user {MEMBER_LOGIN} ({user.get('id')})")
    else:
        print(f"  user {MEMBER_LOGIN} already exists ({user.get('id')})")
    # A team membership, so the account can open the workspace at all.
    admin.call("POST", f"/teams/{team_id}/members", {"team_id": team_id, "user_id": user["id"]},
               allow=(201, 400, 403))
    user = admin.call("GET", f"/users/username/{MEMBER_LOGIN}")[1]
    return user


def ensure_channel(admin: Client, team_id: str, spec: tuple[str, str, str, str]) -> dict:
    name, display, purpose, header = spec
    status, row = admin.call("GET", f"/teams/{team_id}/channels/name/{name}", allow=(200, 404))
    if status == 200 and (row.get("delete_at") or 0) != 0:
        admin.call("POST", f"/channels/{row['id']}/restore", allow=(200, 400, 403))
        row = admin.call("GET", f"/channels/{row['id']}")[1]
        print(f"  restored channel #{name}")
    elif status == 404:
        _, row = admin.call("POST", "/channels",
                            {"team_id": team_id, "name": name, "display_name": display,
                             "type": "O", "purpose": purpose, "header": header})
        print(f"  created channel #{name} ({row['id']})")
    else:
        print(f"  channel #{name} already exists ({row['id']})")
    patch = {}
    if row.get("display_name") != display:
        patch["display_name"] = display
    if row.get("purpose") != purpose:
        patch["purpose"] = purpose
    if row.get("header") != header:
        patch["header"] = header
    if patch:
        _, row = admin.call("PUT", f"/channels/{row['id']}/patch", patch)
        print(f"  patched #{name}: {sorted(patch)}")
    return row


def ensure_membership(admin: Client, channel_id: str, user_id: str, member: bool) -> None:
    status, _ = admin.call("GET", f"/channels/{channel_id}/members/{user_id}", allow=(200, 404))
    if member and status == 404:
        admin.call("POST", f"/channels/{channel_id}/members", {"user_id": user_id}, allow=(201, 400))
        print(f"  joined {user_id} to {channel_id}")
    elif not member and status == 200:
        admin.call("DELETE", f"/channels/{channel_id}/members/{user_id}", allow=(200, 400))
        print(f"  removed {user_id} from {channel_id}")


def restore_role_defaults(admin: Client) -> None:
    """Undo a permission strip left behind by a crashed live-test run.

    The permission set written back is the one this **fixture** is configured with, measured from the
    server on 2026-10-26 and recorded here verbatim (27 ids). It is deliberately *not* Mattermost's stock
    `channel_user` set: this throwaway server's role really does carry the channel-administrator ids, and
    restoring "the stock set" would quietly change the fixture every other card's live tests run against.
    """
    status, role = admin.call("GET", "/roles/name/channel_user", allow=(200, 404))
    if status != 200:
        print("  channel_user role not visible; nothing to restore")
        return
    fixture = sorted(FIXTURE_CHANNEL_USER_PERMISSIONS)
    current = sorted(role.get("permissions") or [])
    if current == fixture:
        print(f"  channel_user already carries the fixture's {len(fixture)} permissions")
        return
    admin.call("PUT", f"/roles/{role['id']}/patch", {"permissions": fixture})
    print(f"  restored channel_user to the fixture's {len(fixture)} permissions "
          f"(was {len(current)})")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--login", default=ADMIN_LOGIN)
    # As with the probe: the fixture account's password is never a repo default.
    parser.add_argument("--password", default=os.environ.get("MM_PROBE_PASSWORD", ""))
    parser.add_argument("--team", default=TEAM_NAME)
    parser.add_argument("--reset-roles", action="store_true",
                        help="restore channel_user's stock permission set (after a crashed strip)")
    args = parser.parse_args()

    admin = Client(args.url)
    admin_user = admin.login(args.login, args.password)
    print(f"signed in as {admin_user['username']} on {args.url}")

    status, team = admin.call("GET", f"/teams/name/{args.team}", allow=(200, 404))
    if status != 200:
        raise SystemExit(f"team #{args.team} is missing — run scripts/perf_seed.py first")
    team_id = team["id"]
    print(f"team #{args.team} = {team_id}")

    if args.reset_roles:
        restore_role_defaults(admin)

    member = ensure_member_account(admin, team_id)
    standup = ensure_channel(admin, team_id, STANDUP)
    browse = ensure_channel(admin, team_id, BROWSE)
    goodbye = ensure_channel(admin, team_id, GOODBYE)

    ensure_membership(admin, standup["id"], admin_user["id"], member=True)
    ensure_membership(admin, goodbye["id"], admin_user["id"], member=True)
    # The browse channel must be joinable *by the signed-in account*, so it is not a member of it…
    ensure_membership(admin, browse["id"], admin_user["id"], member=False)
    # …and the non-admin account needs one channel it can inspect (the non-admin test opens #t40-standup).
    ensure_membership(admin, standup["id"], member["id"], member=True)

    print("\nfixture summary")
    for label, channel in (("standup", standup), ("browse", browse), ("goodbye", goodbye)):
        members = admin.call("GET", f"/channels/{channel['id']}/members", query={"per_page": 200})[1]
        print(f"  {label:8s} #{channel['name']:16s} id={channel['id']} members={len(members)}")
    print(f"  non-admin account: {MEMBER_LOGIN} / {MEMBER_PASSWORD} (user id {member['id']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
