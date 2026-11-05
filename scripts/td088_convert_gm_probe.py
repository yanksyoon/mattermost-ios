#!/usr/bin/env python3
"""t_d088f075 probe — the server-side oracle for **converting a group message to a channel**.

The screen's rules are measured here, against the pinned 9.11.19 fixture, before any Swift is
written. Upstream (mattermost-mobile @ v2.45.0, `app/client/rest/channels.ts`) sends

    POST /channels/{channel_id}/convert_to_channel?team-id={team_id}
    {"channel_id": …, "team_id": …, "display_name": …, "name": …}

and the card names the route as `/channels/{id}/convert`. The probe answers which is real, plus:

  1. the answer's shape and status, and whether the **channel id survives** the conversion;
  2. `GET /channels/{id}` afterwards: `type`, `name`, `display_name`, `team_id`, `delete_at`;
  3. the URL-name rule on this route: accepted lower-case/hyphen/underscore, refused upper case,
     space, leading hyphen, 65 chars, empty — with the server's exact error id and message;
  4. a duplicate name (the error the form shows against the name field);
  5. a wrong / missing `team-id` query, and a team the members do not share;
  6. permission: a plain member (not the GM's creator) converting a GM they are in, and a guest;
  7. `POST /channels/{id}/convert` — the card's spelling — to record that it is not the route;
  8. a non-GM (public channel) through the same route, so the client's "only a GM" gate has a
     measured server answer behind it too.

Everything it creates is archived at the end.

Usage:
    python3 scripts/td088_convert_gm_probe.py --url http://127.0.0.1:8065
    python3 scripts/td088_convert_gm_probe.py --url http://127.0.0.1:8065 --password '…'
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
# Documentation only; the CLI never defaults to it (see `main`).
ADMIN_PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
MEMBER_LOGIN = "t40member"
MEMBER_PASSWORD = "T40-Member-Not-A-Real-Secret-1"

# An archived channel keeps its name, so every run uses fresh names.
RUN = f"td088probe{int(time.time())}"


class Client:
    def __init__(self, base: str, token: str | None = None) -> None:
        self.base = base.rstrip("/")
        self.token = token

    def call(self, method: str, path: str, body=None, query=None):
        url = f"{self.base}/api/v4{path}"
        if query:
            url += "?" + "&".join(f"{key}={value}" for key, value in query.items())
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
            return error.code, payload

    def login(self, login: str, password: str) -> dict:
        status, user = self.call("POST", "/users/login",
                                 body={"login_id": login, "password": password})
        if status != 200:
            raise SystemExit(f"login as {login} failed: HTTP {status} {user}")
        # The login answer carries no token in 9.11.19's body — it is the `Token` header. Re-login
        # through a request that reads headers.
        request = urllib.request.Request(
            f"{self.base}/api/v4/users/login",
            data=json.dumps({"login_id": login, "password": password}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=20) as response:
            self.token = response.headers.get("Token")
        return user


def show(label: str, status: int, payload) -> None:
    text = json.dumps(payload, ensure_ascii=False)
    if len(text) > 900:
        text = text[:900] + f"… ({len(text)} chars)"
    print(f"  {label:<44} {status}  {text}")


def can_convert_candidate(client: Client, team: str, users: list[str]) -> dict | None:
    """Create a fresh GM with `users` and answer it. Archives nothing (the caller does)."""
    status, channel = client.call("POST", "/channels/group", body=users)
    if status not in (200, 201):
        print(f"  could not create a group message: {status} {channel}")
        return None
    return channel


def convert(client: Client, channel_id: str, team: str, name: str,
            display_name: str | None = None, path: str | None = None):
    body = {"channel_id": channel_id, "team_id": team,
            "display_name": display_name or name.replace("-", " ").title(), "name": name}
    return client.call("POST", path or f"/channels/{channel_id}/convert_to_channel",
                       body=body, query={"team-id": team})


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default=os.environ.get("MM_URL", "http://127.0.0.1:8065"))
    parser.add_argument("--password", default=os.environ.get("MM_PASSWORD", ADMIN_PASSWORD))
    parser.add_argument("--member-password", default=os.environ.get("MM_MEMBER_PASSWORD", MEMBER_PASSWORD))
    args = parser.parse_args()

    admin = Client(args.url)
    me = admin.login(ADMIN_LOGIN, args.password)
    print(f"admin  {me['username']}  {me['id']}")

    teams = admin.call("GET", "/users/me/teams")[1]
    if not teams:
        raise SystemExit("the fixture account has no team")
    team = teams[0]["id"]
    print(f"team   {teams[0]['display_name']}  {team}")

    status, people = admin.call("GET", "/users", query={"in_team": team, "per_page": 200})
    others = [p for p in people if p["id"] != me["id"] and p.get("delete_at", 0) == 0]
    print(f"people {len(others)} others, e.g. {[p['username'] for p in others[:4]]}")
    if len(others) < 2:
        raise SystemExit("a group message needs three accounts")
    a, b = others[0]["id"], others[1]["id"]

    print("\n== 1. create a group message and read its common teams ==")
    gm = can_convert_candidate(admin, team, [me["id"], a, b])
    if gm is None:
        return 1
    gm_id = gm["id"]
    print(f"  gm {gm_id} type={gm.get('type')} name={gm.get('name')} team={gm.get('team_id')!r}")
    show("GET /channels/{id}/common_teams",
          *admin.call("GET", f"/channels/{gm_id}/common_teams"))
    admin.call("POST", "/posts", body={"channel_id": gm_id, "message": f"probe {RUN}"})

    print("\n== 2. the conversion itself ==")
    name = f"{RUN}-a"
    status, converted = convert(admin, gm_id, team, name, display_name="Probe Convert A")
    show("POST …/convert_to_channel?team-id=", status, converted)
    if status in (200, 201) and isinstance(converted, dict):
        after = admin.call("GET", f"/channels/{gm_id}")[1]
        print(f"  id survives: {after['id'] == gm_id}  type={after.get('type')}"
              f"  name={after.get('name')}  display_name={after.get('display_name')}"
              f"  team_id={after.get('team_id')}  delete_at={after.get('delete_at')}")
        show("GET /teams/{t}/channels/name/{name}",
             *admin.call("GET", f"/teams/{team}/channels/name/{name}"))
        show("GET /users/me/teams/{t}/channels (has it)",
             200, any(c["id"] == gm_id
                      for c in admin.call("GET", f"/users/me/teams/{team}/channels")[1]))

    print("\n== 3. the card's spelling: POST /channels/{id}/convert ==")
    gm2 = can_convert_candidate(admin, team, [me["id"], a, b])
    if gm2:
        show("POST /channels/{id}/convert",
             *convert(admin, gm2["id"], team, f"{RUN}-convert", path=f"/channels/{gm2['id']}/convert"))
        admin.call("DELETE", f"/channels/{gm2['id']}")

    print("\n== 4. the URL-name rule, one request per candidate ==")
    candidates = [f"{RUN}-ok", f"{RUN}-under_score", f"{RUN}-Under_Score", f"{RUN}-with space",
                  f"-{RUN}-leading", f"{RUN}-dot.name", "a" * 64, "a" * 65, ""]
    for index, candidate in enumerate(candidates):
        fresh = can_convert_candidate(admin, team, [me["id"], a, b])
        if not fresh:
            continue
        status, payload = convert(admin, fresh["id"], team, candidate,
                                  display_name="Name Rule Probe")
        error = payload.get("id") if isinstance(payload, dict) else None
        message = payload.get("message") if isinstance(payload, dict) else None
        print(f"  name={candidate[:40]!r:<44} {status}  {error or ''} {message or ''}")
        if status not in (200, 201):
            admin.call("DELETE", f"/channels/{fresh['id']}")
        else:
            admin.call("DELETE", f"/channels/{fresh['id']}")

    print("\n== 5. a duplicate name ==")
    taken = f"{RUN}-dup"
    status, channel = admin.call("POST", "/channels",
                                 body={"team_id": team, "name": taken, "display_name": "Dup",
                                       "type": "P"})
    print(f"  the name is taken by {channel.get('id') if isinstance(channel, dict) else channel}"
          f" ({status})")
    fresh = can_convert_candidate(admin, team, [me["id"], a, b])
    if fresh:
        show("convert onto an existing name", *convert(admin, fresh["id"], team, taken))
        admin.call("DELETE", f"/channels/{fresh['id']}")
    if isinstance(channel, dict) and channel.get("id"):
        admin.call("DELETE", f"/channels/{channel['id']}")

    print("\n== 6. a wrong or missing team-id ==")
    fresh = can_convert_candidate(admin, team, [me["id"], a, b])
    if fresh:
        body = {"channel_id": fresh["id"], "team_id": "team0000000000000000000000",
                "display_name": "Wrong team", "name": f"{RUN}-wrongteam"}
        show("team-id = an unknown team",
             *admin.call("POST", f"/channels/{fresh['id']}/convert_to_channel",
                         body=body, query={"team-id": "team0000000000000000000000"}))
        show("no team-id query at all",
             *admin.call("POST", f"/channels/{fresh['id']}/convert_to_channel",
                         body={"channel_id": fresh["id"], "team_id": team,
                               "display_name": "No query", "name": f"{RUN}-noquery"}))
        admin.call("DELETE", f"/channels/{fresh['id']}")

    print("\n== 7. a non-group channel through the same route ==")
    status, public = admin.call("POST", "/channels",
                                body={"team_id": team, "name": f"{RUN}-public",
                                      "display_name": "Public probe", "type": "O"})
    if isinstance(public, dict) and public.get("id"):
        show("convert a public channel",
             *convert(admin, public["id"], team, f"{RUN}-public2"))
        admin.call("DELETE", f"/channels/{public['id']}")

    print("\n== 8. a plain member converting a GM they are in ==")
    member = Client(args.url)
    try:
        member_user = member.login(MEMBER_LOGIN, args.member_password)
    except SystemExit as error:
        print(f"  skipped: {error}")
        member_user = None
    if member_user:
        status, member_team = member.call("GET", f"/teams/{team}/members/{member_user['id']}")
        print(f"  member is on the team: {status == 200} (roles={member_team.get('roles') if status == 200 else None})")
        gm3 = can_convert_candidate(admin, team, [me["id"], member_user["id"], a])
        if gm3:
            show("member converts the GM they are in",
                 *convert(member, gm3["id"], team, f"{RUN}-bymember"))
            admin.call("DELETE", f"/channels/{gm3['id']}")

    print("\n== cleanup ==")
    # Any GM this run converted is a channel now; archive the ones we still hold ids for.
    for cid in (gm_id,):
        print(f"  DELETE /channels/{cid} -> {admin.call('DELETE', f'/channels/{cid}')[0]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
