#!/usr/bin/env python3
"""T47-AV probe — the server-side oracle for the T47 *adversarial* questions.

`scripts/t47_create_channel_probe.py` measured the happy path. This one measures the answers T47's own
build note left as claims, so each AV verdict can quote the server rather than the app:

  1. **permissions** — who carries `create_public_channel` / `create_private_channel`, and what a
     dedicated account whose team role has been reduced to `team_admin` gets from `POST /channels`;
  2. **direct messages** — `POST /channels/direct` create-or-find (same id twice), self-DM, a
     deactivated account, and somebody on no shared team;
  3. **who the picker can see** — does `GET /users?in_team=` (the picker's opening list) include a
     deactivated account, while `POST /users/search` with `allow_inactive: false` does not;
  4. **the wrong-kind answers** — `type=D` / `type=X` / `type=G` on `POST /channels`;
  5. **the fixture after the suites** — live channels named like the suites' own creations, and the DM
     the DM test opens, so "tearDown archives everything" can be checked against the server.

The restricted account is `t47av-restricted`, a normal team member. On this fixture the role
create/patch routes are not registered (`POST /roles` → 404, `PUT /roles/{id}/patch` → 404 — Team
Edition), so the only way to remove a create id from an account is to take `team_user` away from its
team membership — which also removes `list_team_channels`, so the sidebar itself answers 403. The live
AV suite therefore *starts* the account on `team_user` and revokes it while the create form is open;
that is the only reachable shape of "the server's answer is the authority".

    MM_PROBE_PASSWORD=… python3 scripts/t47_av_probe.py --setup
    … run the live suites …
    MM_PROBE_PASSWORD=… python3 scripts/t47_av_probe.py --audit-only
    MM_PROBE_PASSWORD=… python3 scripts/t47_av_probe.py --teardown

`--setup` is idempotent. `--teardown` restores the account's team roles, deactivates it, and archives
the probe's own channels — it does **not** archive the live suites' channels: their absence is what the
audit measures.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

ADMIN_LOGIN = "perfprobe"
RESTRICTED_USERNAME = "t47av-restricted"
RESTRICTED_EMAIL = "t47av-restricted@example.invalid"
RESTRICTED_PASSWORD = "T47-AV-Restricted-Not-A-Real-Secret-1"

CREATE_IDS = ("create_public_channel", "create_private_channel")
DM_ID = "create_direct_channel"
LIST_ID = "list_team_channels"

RUN = f"t47av{int(time.time())}"


class Client:
    def __init__(self, base: str, token: str | None = None) -> None:
        self.base = base.rstrip("/")
        self.token = token

    def call(self, method: str, path: str, body=None, query: str = ""):
        url = f"{self.base}/api/v4{path}{query}"
        headers = {"Content-Type": "application/json", "X-Requested-With": "XMLHttpRequest"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read()
                try:
                    payload = json.loads(raw) if raw.strip() else None
                except ValueError:
                    payload = raw.decode(errors="replace")
                return response.status, payload, dict(response.headers)
        except urllib.error.HTTPError as error:
            raw = error.read()
            try:
                payload = json.loads(raw or b"null")
            except ValueError:
                payload = raw.decode(errors="replace")
            return error.code, payload, dict(error.headers)

    def login(self, login: str, password: str) -> tuple[int, dict, str | None]:
        status, body, headers = self.call("POST", "/users/login",
                                          {"login_id": login, "password": password})
        if status == 200:
            self.token = headers.get("Token")
        return status, body if isinstance(body, dict) else {}, self.token


def show(label: str, answer, limit: int = 240) -> None:
    status, payload = answer[0], answer[1]
    text = json.dumps(payload)[:limit] if isinstance(payload, (dict, list)) else str(payload)[:limit]
    print(f"  {label:56s} -> {status} {text}")


def permissions(client: Client, team_id: str) -> tuple[list[str], list[str]]:
    _, user, _ = client.call("GET", "/users/me")
    _, member, _ = client.call("GET", f"/teams/{team_id}/members/{user['id']}")
    system_roles = (user.get("roles") or "").split()
    team_roles = (member.get("roles") or "").split() if isinstance(member, dict) else []
    names = sorted(set(system_roles + team_roles))
    _, roles, _ = client.call("POST", "/roles/names", names)
    ids = sorted({p for role in roles for p in role.get("permissions", [])}) if isinstance(roles, list) else []
    return names, ids


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--password", default=os.environ.get("MM_PROBE_PASSWORD", ""))
    parser.add_argument("--setup", action="store_true", help="create the restricted account and measure")
    parser.add_argument("--teardown", action="store_true", help="restore the fixture and archive probes")
    parser.add_argument("--audit-only", action="store_true", help="only the post-suite fixture audit")
    args = parser.parse_args()
    if not args.password:
        print("set MM_PROBE_PASSWORD (or pass --password) — see scripts/perf_seed.py", file=sys.stderr)
        return 2
    if not (args.setup or args.teardown or args.audit_only):
        parser.error("choose --setup, --teardown or --audit-only")

    admin = Client(args.url)
    status, me, _ = admin.login(ADMIN_LOGIN, args.password)
    if status != 200 or not admin.token:
        print(f"admin login failed: {status}", file=sys.stderr)
        return 1
    _, teams, _ = admin.call("GET", "/users/me/teams")
    perf = next(t for t in teams if t["name"] == "perf")
    team_id = perf["id"]
    print(f"fixture {args.url}  team perf={team_id}  admin={me['id']}  run={RUN}")

    _, everyone, _ = admin.call("GET", f"/users?in_team={team_id}&page=0&per_page=200")
    everyone = everyone if isinstance(everyone, list) else []
    deactivated = [u for u in everyone if int(u.get("delete_at") or 0) > 0]
    bots = [u for u in everyone if u.get("is_bot") is True]

    if args.setup:
        print("\n1. who carries the create ids")
        for label, login, password in (("admin", ADMIN_LOGIN, args.password),
                                       ("member t40member", "t40member", "T40-Member-Not-A-Real-Secret-1")):
            client = Client(args.url)
            status, _, _ = client.login(login, password)
            if status != 200:
                print(f"  {label}: login {status}")
                continue
            names, ids = permissions(client, team_id)
            print(f"  {label} union ({', '.join(names)}): {len(ids)} ids")
            for gate in CREATE_IDS + (DM_ID, LIST_ID):
                print(f"    {gate:26s} {'yes' if gate in ids else 'no'}")

        print("\n2. the restricted account (a normal member, not a guest)")
        status, _, _ = admin.call("GET", f"/users/username/{RESTRICTED_USERNAME}")
        if status == 404:
            status, created, _ = admin.call("POST", "/users", {
                "email": RESTRICTED_EMAIL, "username": RESTRICTED_USERNAME,
                "password": RESTRICTED_PASSWORD})
            show(f"POST /users username={RESTRICTED_USERNAME}", (status, created, {}))
            restricted_id = created.get("id") if isinstance(created, dict) else None
        else:
            _, existing, _ = admin.call("GET", f"/users/username/{RESTRICTED_USERNAME}")
            restricted_id = existing.get("id") if isinstance(existing, dict) else None
            print(f"  reused {RESTRICTED_USERNAME} ({restricted_id})")
        if not restricted_id:
            print("  cannot continue without the restricted account", file=sys.stderr)
            return 1
        status, membership, _ = admin.call("POST", f"/teams/{team_id}/members",
                                           {"team_id": team_id, "user_id": restricted_id})
        show("POST /teams/{tid}/members", (status, membership, {}))
        show("PUT membership roles=team_user",
             admin.call("PUT", f"/teams/{team_id}/members/{restricted_id}/roles",
                        {"roles": "team_user"}))
        restricted = Client(args.url)
        status, _, _ = restricted.login(RESTRICTED_USERNAME, RESTRICTED_PASSWORD)
        print(f"  restricted login -> {status} token={'yes' if restricted.token else 'no'}")
        if status == 200:
            r_names, r_ids = permissions(restricted, team_id)
            print(f"  restricted union ({', '.join(r_names)}): {len(r_ids)} ids")
            for gate in CREATE_IDS + (DM_ID, LIST_ID):
                print(f"    {gate:26s} {'yes' if gate in r_ids else 'no'}")
            print("  the same session, after the team role is taken away (the live AV race):")
            show("PUT membership roles=team_admin",
                 admin.call("PUT", f"/teams/{team_id}/members/{restricted_id}/roles",
                            {"roles": "team_admin"}))
            show("restricted POST /channels (revoked session)",
                 restricted.call("POST", "/channels", {
                     "team_id": team_id, "name": f"{RUN}-revoked", "display_name": "T47 AV revoked",
                     "type": "O", "purpose": "", "header": ""}))
            show("restricted GET /users/me/teams/{tid}/channels (revoked)",
                 restricted.call("GET", f"/users/me/teams/{team_id}/channels"))
            show("PUT membership roles=team_user (restore)",
                 admin.call("PUT", f"/teams/{team_id}/members/{restricted_id}/roles",
                            {"roles": "team_user"}))
            print("  role routes on this server (Team Edition):")
            show("POST /roles", admin.call("POST", "/roles", {
                "name": "t47av_probe_role", "display_name": "probe",
                "permissions": ["list_team_channels"]}))
            show("PUT /roles/team_user/patch",
                 admin.call("PUT", "/roles/team_user/patch", {"permissions": ["list_team_channels"]}))

        print("\n3. the direct-message call: create-or-find, and who it refuses")
        partner = next((u for u in everyone
                        if u["id"] != me["id"] and u.get("is_bot") is not True
                        and int(u.get("delete_at") or 0) == 0), None)
        if partner:
            first = admin.call("POST", "/channels/direct", [me["id"], partner["id"]])
            second = admin.call("POST", "/channels/direct", [me["id"], partner["id"]])
            show(f"first  POST /channels/direct with {partner['username']}", first)
            show("second POST /channels/direct (create-or-find)", second)
            one = first[1].get("id") if isinstance(first[1], dict) else None
            two = second[1].get("id") if isinstance(second[1], dict) else None
            print(f"  same channel id on both calls: {one == two and bool(one)}  ({one})")
            if one:
                _, members, _ = admin.call("GET", f"/channels/{one}/members")
                ids = sorted(m.get("user_id") for m in members) if isinstance(members, list) else []
                print(f"  members of {one}: {ids}")
        show("self-DM POST /channels/direct [me, me]",
             admin.call("POST", "/channels/direct", [me["id"], me["id"]]))
        if deactivated:
            show(f"DM with deactivated {deactivated[0]['username']}",
                 admin.call("POST", "/channels/direct", [me["id"], deactivated[0]["id"]]))
        else:
            print("  no deactivated account on the fixture")
        others = [t for t in teams if t["id"] != team_id]
        outsider = None
        for team in others:
            _, members, _ = admin.call("GET", f"/teams/{team['id']}/members?page=0&per_page=200")
            for member in members if isinstance(members, list) else []:
                if member.get("user_id") not in {u["id"] for u in everyone}:
                    outsider = member["user_id"]
                    break
            if outsider:
                break
        if outsider:
            show("DM with somebody on no shared team",
                 admin.call("POST", "/channels/direct", [me["id"], outsider]))
        else:
            print("  no user outside team perf found to test a no-shared-team DM")

        print("\n4. who the picker's two reads return")
        print(f"  GET /users?in_team={team_id}: {len(everyone)} rows; "
              f"deactivated={[u['username'] for u in deactivated]}; bots={[u['username'] for u in bots]}")
        if deactivated:
            term = deactivated[0]["username"][:5]
            show(f"POST /users/search term={term} allow_inactive=false",
                 admin.call("POST", "/users/search", {
                     "term": term, "team_id": team_id, "page": 0, "per_page": 50,
                     "allow_inactive": False}))
            show(f"POST /users/search term={term} allow_inactive=true",
                 admin.call("POST", "/users/search", {
                     "term": term, "team_id": team_id, "page": 0, "per_page": 50,
                     "allow_inactive": True}))

        print("\n5. the wrong-kind answers on POST /channels")
        for kind in ("D", "X", "G"):
            show(f"POST /channels type={kind}",
                 admin.call("POST", "/channels", {
                     "team_id": team_id, "name": f"{RUN}-type{kind.lower()}",
                     "display_name": f"T47 AV type {kind}", "type": kind,
                     "purpose": "", "header": ""}))

    if args.audit_only or args.teardown:
        print("\n6. the fixture after the suites")
        status, channels, _ = admin.call("GET", f"/users/me/teams/{team_id}/channels?page=0&per_page=200")
        live = [c for c in channels if int(c.get("delete_at") or 0) == 0] if isinstance(channels, list) else []
        named = [c for c in live if (c.get("name") or "").startswith(("t47-ui-", "t47probe", "t47av"))]
        print(f"  GET /users/me/teams/{{tid}}/channels: {len(live)} live, "
              f"{len(named)} named like a suite/probe run")
        for channel in named:
            print(f"    LIVE {channel['id']} {channel['name']} type={channel.get('type')} "
                  f"creator={channel.get('creator_id', '(absent)')} delete_at={channel.get('delete_at')}")
        status, archived, _ = admin.call("GET", f"/teams/{team_id}/channels/deleted?page=0&per_page=200")
        archived_named = [c for c in archived if (c.get("name") or "").startswith("t47")
                          and isinstance(c, dict)] if isinstance(archived, list) else []
        print(f"  archived channels named like a run (the tearDown's evidence): {len(archived_named)}")
        for channel in archived_named[:8]:
            print(f"    archived {channel['id']} {channel['name']} delete_at={channel.get('delete_at')}")
        partner = next((u for u in everyone
                        if u["id"] != me["id"] and u.get("is_bot") is not True
                        and int(u.get("delete_at") or 0) == 0), None)
        if partner:
            show(f"DM with {partner['username']} (the DM test's own pair)",
                 admin.call("POST", "/channels/direct", [me["id"], partner["id"]]))

    if args.teardown:
        print("\n7. restore the fixture and archive the probe's own channels")
        status, existing, _ = admin.call("GET", f"/users/username/{RESTRICTED_USERNAME}")
        if status == 200 and isinstance(existing, dict):
            uid = existing.get("id")
            show("PUT membership roles=team_user",
                 admin.call("PUT", f"/teams/{team_id}/members/{uid}/roles", {"roles": "team_user"}))
            # The account stays (a normal member): the live AV suite re-runs against it, and a
            # deactivated account cannot sign in. Nothing about it is privileged.
            print(f"  kept {RESTRICTED_USERNAME} ({uid}) as a plain team member")
        status, channels, _ = admin.call("GET", f"/users/me/teams/{team_id}/channels?page=0&per_page=200")
        for channel in channels if isinstance(channels, list) else []:
            name = channel.get("name") or ""
            if name.startswith("t47av") and int(channel.get("delete_at") or 0) == 0:
                show(f"archive probe channel {name}",
                     admin.call("DELETE", f"/channels/{channel['id']}"))
        # DMs are not team channels: the probe's own self-DM and its no-shared-team DM were created
        # after RUN's start; the fixture's older DM with the deactivated account is not ours to touch.
        status, mine, _ = admin.call("GET", "/users/me/channels")
        started = int(RUN.removeprefix("t47av")) * 1000
        for channel in mine if isinstance(mine, list) else []:
            name = channel.get("name") or ""
            if (channel.get("type") == "D" and int(channel.get("create_at") or 0) >= started
                    and me["id"] in name):
                show(f"archive probe DM {name}",
                     admin.call("DELETE", f"/channels/{channel['id']}"))

    print(f"\ndone at {time.strftime('%Y-%m-%d %H:%M:%S')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
