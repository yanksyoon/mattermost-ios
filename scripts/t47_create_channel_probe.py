#!/usr/bin/env python3
"""T47 probe — the server-side oracle for *creating* a channel, run against the live fixture.

The card's rules are not guesses: `POST /channels` and the server's own validation are measured here,
against the pinned 9.11.19 fixture, before any Swift is written. What is recorded:

  1. permissions   the union of system + team (+ channel) role ids, and whether
                   `create_public_channel` / `create_private_channel` are in it — for the admin
                   fixture account and for the plain member account;
  2. create        `POST /channels` with type `O` and with type `P`: status, the answer's shape, and
                   the membership the server adds for the creator (no second call);
  3. the name rule one request per candidate: lower-case letters/digits/hyphen/underscore accepted,
                   upper case / space / dot / leading hyphen / trailing hyphen / empty / 65 chars
                   refused, 64 chars accepted — with the server's exact error id and message;
  4. limits        display name 64/65, purpose 250/251, header 1024/1025 **on create** (T40 measured
                   them on PATCH; a create may enforce a different set);
  5. duplicates    a second `POST /channels` with the same name;
  6. bad input     a missing team, an unknown type;
  7. sidebar       `GET /users/me/teams/{tid}/channels` contains the created channel (the side effect
                   the client relies on instead of a second membership write).

Everything it creates is archived at the end (`DELETE /channels/{id}`), so the fixture is left as it was
found apart from archived probe channels, which is what the T40 probe already does.

Usage:
    python3 scripts/t47_create_channel_probe.py --url http://127.0.0.1:8065
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

# A per-run prefix: an archived channel keeps its name, so a fixed name would answer "exists".
RUN = f"t47probe{int(time.time())}"


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
        request = urllib.request.Request(
            f"{self.base}/api/v4/users/login",
            data=json.dumps({"login_id": login, "password": password}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=20) as response:
            self.token = response.headers.get("Token")
            return json.loads(response.read())


def show(label: str, status: int, payload) -> None:
    if isinstance(payload, (dict, list)):
        text = json.dumps(payload)[:260]
    else:
        text = str(payload)[:260]
    print(f"  {label:52s} -> {status} {text}")


def permissions_for(client: Client, user_id: str, team_id: str) -> tuple[list[str], list[str]]:
    _, user = client.call("GET", "/users/me")
    system_roles = (user.get("roles") or "").split()
    _, team_member = client.call("GET", f"/teams/{team_id}/members/{user_id}")
    team_roles = (team_member.get("roles") or "").split() if isinstance(team_member, dict) else []
    names = sorted(set(system_roles + team_roles))
    _, roles = client.call("POST", "/roles/names", names)
    ids = sorted({p for role in roles for p in role.get("permissions", [])}) if isinstance(roles, list) else []
    return names, ids


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--login", default=ADMIN_LOGIN)
    parser.add_argument("--password", default=os.environ.get("MM_PROBE_PASSWORD", ""))
    args = parser.parse_args()

    if not args.password:
        print("set MM_PROBE_PASSWORD (or pass --password) — see scripts/perf_seed.py", file=sys.stderr)
        return 2

    admin = Client(args.url)
    me = admin.login(args.login, args.password)
    print(f"signed in as {me['username']} ({me['id']}) on {args.url}\n")

    _, teams = admin.call("GET", "/users/me/teams")
    team_id = teams[0]["id"]
    team_name = teams[0]["name"]

    print("1. who may create what")
    names, ids = permissions_for(admin, me["id"], team_id)
    print(f"    admin role union ({', '.join(names)}): {len(ids)} ids")
    for gate in ("create_public_channel", "create_private_channel", "create_direct_channel",
                 "list_team_channels", "join_public_channels"):
        print(f"      {gate:30s} {'yes' if gate in ids else 'no'}")

    member_id = None
    status, member = admin.call("GET", f"/users/username/{MEMBER_LOGIN}")
    if status == 200:
        member_id = member["id"]
        member_client = Client(args.url)
        member_client.login(MEMBER_LOGIN, MEMBER_PASSWORD)
        m_names, m_ids = permissions_for(member_client, member_id, team_id)
        print(f"    member role union ({', '.join(m_names)}): {len(m_ids)} ids")
        for gate in ("create_public_channel", "create_private_channel", "create_direct_channel",
                     "list_team_channels"):
            print(f"      {gate:30s} {'yes' if gate in m_ids else 'no'}")
    else:
        print(f"    {MEMBER_LOGIN} missing — run scripts/t40_channel_seed.py (member gates not measured)")

    created: list[str] = []

    def create(label: str, name: str, display_name: str, kind: str = "O",
               purpose: str = "", header: str = "", team: str | None = None) -> dict | None:
        body = {"team_id": team if team is not None else team_id,
                "name": name, "display_name": display_name, "type": kind,
                "purpose": purpose, "header": header}
        status, payload = admin.call("POST", "/channels", body)
        show(label, status, payload)
        if status in (200, 201) and isinstance(payload, dict) and payload.get("id"):
            created.append(payload["id"])
            return payload
        return None

    print("\n2. create a public and a private channel")
    public = create("POST /channels type=O", f"{RUN}-public", "T47 Probe Public")
    if public:
        print(f"    id={public['id']} team_id={public.get('team_id')} type={public.get('type')} "
              f"creator={public.get('creator_id', '(absent)')}")
        show("GET /channels/{id}/stats (creator member?)",
             *admin.call("GET", f"/channels/{public['id']}/stats"))
        status, mine = admin.call("GET", f"/users/me/teams/{team_id}/channels")
        listed = any(c.get("id") == public["id"] for c in mine) if isinstance(mine, list) else False
        print(f"    in GET /users/me/teams/{{tid}}/channels: {listed}  "
              f"({len(mine) if isinstance(mine, list) else '?'} channels)")
    private = create("POST /channels type=P", f"{RUN}-private", "T47 Probe Private", kind="P")
    if private:
        print(f"    id={private['id']} type={private.get('type')}")

    print("\n3. the URL-name rule (each candidate is one create)")
    cases = [
        ("lower-case + hyphen + digits", f"{RUN}-ok-2"),
        ("underscore", f"{RUN}_ok"),
        ("upper case", f"{RUN}-UPPER"),
        ("space", f"{RUN} space"),
        ("dot", f"{RUN}.dot"),
        ("leading hyphen", f"-{RUN}lead"),
        ("trailing hyphen", f"{RUN}trail-"),
        ("leading underscore", f"_{RUN}lead"),
        ("empty", ""),
        ("64 chars", "a" * 54 + RUN[-10:] if len(RUN) >= 10 else "a" * 64),
        ("65 chars", "b" * 55 + RUN[-10:] if len(RUN) >= 10 else "b" * 65),
    ]
    for label, name in cases:
        print(f"  -- {label}: {name!r} (len {len(name)})")
        create(f"POST /channels name={label}", name, f"T47 {label}")

    print("\n4. the field limits on create")
    if created:
        base = created[0]
        show("purpose=250", *admin.call("PUT", f"/channels/{base}/patch", {"purpose": "p" * 250}))
        show("purpose=251", *admin.call("PUT", f"/channels/{base}/patch", {"purpose": "p" * 251}))
    create("create display_name=64", f"{RUN}-dn64", "d" * 64)
    create("create display_name=65", f"{RUN}-dn65", "d" * 65)
    create("create display_name empty", f"{RUN}-dnempty", "")
    create("create purpose=250", f"{RUN}-p250", "T47 p250", purpose="p" * 250)
    create("create purpose=251", f"{RUN}-p251", "T47 p251", purpose="p" * 251)
    create("create header=1024", f"{RUN}-h1024", "T47 h1024", header="h" * 1024)
    create("create header=1025", f"{RUN}-h1025", "T47 h1025", header="h" * 1025)

    print("\n5. duplicates")
    create("same name as the first channel", f"{RUN}-public", "T47 Probe Duplicate")

    print("\n6. bad input")
    create("unknown team", f"{RUN}-badtid", "T47 Bad Team", team="notateamid")
    create("unknown type X", f"{RUN}-typex", "T47 Bad Type", kind="X")
    create("type D (direct is not a create)", f"{RUN}-typed", "T47 Bad Type D", kind="D")

    print("\n7. cleanup (archive every probe channel)")
    for channel_id in created:
        status, _ = admin.call("DELETE", f"/channels/{channel_id}")
        print(f"  archive {channel_id} -> {status}")
    print(f"done at {time.strftime('%Y-%m-%d %H:%M:%S')} (team {team_name} {team_id})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
