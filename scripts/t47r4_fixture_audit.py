"""T47-AV-R4 fixture audit: every `t47-ui-*` channel on the fixture, and whether it is live.

The card's F8 says the red run left `t47-ui-1793648428` live. This script answers, from the server's own
records, whether the repaired suite leaves anything live: it lists every channel whose name starts
`t47-ui-` in every team the fixture account is in, with `delete_at` (0 = live) and the team it is in.

Run against the live fixture:

    python3 scripts/t47r4_fixture_audit.py
"""
import json
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8065/api/v4"
LOGIN = "perfprobe"
PASSWORD = "PerfProbe-Not-A-Real-Secret-1"


def call(method, path, body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as err:
        return err.code, err.read()


def main():
    status, headers_body = None, None
    req = urllib.request.Request(BASE + "/users/login",
                                 data=json.dumps({"login_id": LOGIN, "password": PASSWORD}).encode(),
                                 method="POST")
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=20) as resp:
        token = resp.headers.get("Token")
        me = json.loads(resp.read())
    print("signed in as", me["username"], me["id"])

    status, body = call("GET", "/users/me/teams", token=token)
    teams = json.loads(body)
    print("teams:", [(t["name"], t["display_name"], t["id"]) for t in teams])

    live = []
    archived = []
    for team in teams:
        # `include_deleted=true` matters: without it the server hides archived channels and the audit
        # would report "0 archived" for a fixture that has them (measured against the T47-AV archive).
        status, body = call("GET", f"/users/me/teams/{team['id']}/channels?page=0&per_page=200"
                                   "&include_deleted=true", token=token)
        if status != 200:
            print("  team", team["name"], "-> HTTP", status)
            continue
        channels = json.loads(body)
        # /channels is paged; walk the pages until short.
        page = 0
        while len(channels) == 200:
            page += 1
            status, body = call("GET", f"/users/me/teams/{team['id']}/channels?page={page}"
                                       "&per_page=200", token=token)
            if status != 200:
                break
            more = json.loads(body)
            channels += more
            if len(more) < 200:
                break
        for channel in channels:
            name = channel.get("name", "")
            if not name.startswith("t47-ui-"):
                continue
            entry = (team["name"], name, channel["id"], channel.get("delete_at", 0),
                     channel.get("create_at"))
            (live if not channel.get("delete_at") else archived).append(entry)
        print(f"  {team['name']}: {len(channels)} channels read")

    print(f"\nLIVE t47-ui-* channels: {len(live)}")
    for entry in live:
        print("   LIVE", entry)
    print(f"archived t47-ui-* channels: {len(archived)}")
    for entry in archived:
        print("   archived", entry)


main()
