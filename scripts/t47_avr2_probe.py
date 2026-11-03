#!/usr/bin/env python3
"""T47-AV-R2 probe — the two lists the DM picker reads, and the sibling add-people list.

Read-only. Answers, from the server's own records:

  1. which team `perfprobe` signs in to first, how many members it has, and which of them are
     deactivated (`delete_at != 0`) — the opening list the picker draws is
     `GET /users?in_team={tid}`, which returns them;
  2. what `POST /users/search` answers for the same people with `allow_inactive: false` — the typed
     list, which does not (the asymmetry T47-AV-R2's F3 repair had to resolve);
  3. `POST /users/status/ids` — the presence the picker draws (a missing row is "Unknown");
  4. `GET /users?in_team={tid}&not_in_channel={cid}` — the **add-people** picker's opening list,
     which has the same defect (filed as a separate card, not repaired by T47-AV-R2).

Usage (the fixture is `mm-perf` 9.11.19 on 127.0.0.1:8065; see `scripts/perf_seed.py`):

    python3 scripts/t47_avr2_probe.py
    python3 scripts/t47_avr2_probe.py --base http://127.0.0.1:8065/api/v4 --login perfprobe --password …
"""
import argparse
import json
import sys
import urllib.error
import urllib.request

DEFAULT_PASSWORD = "PerfProbe-Not-A-Real-Secret-1"


class Client:
    def __init__(self, base):
        self.base = base.rstrip("/")
        self.token = None

    def call(self, path, method="GET", body=None):
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(self.base + path, data=data, method=method)
        request.add_header("Content-Type", "application/json")
        if self.token:
            request.add_header("Authorization", "Bearer " + self.token)
        try:
            with urllib.request.urlopen(request, timeout=20) as answer:
                issued = answer.headers.get("Token")
                if issued:
                    self.token = issued
                return json.loads(answer.read().decode())
        except urllib.error.HTTPError as failure:
            return {"__status": failure.code,
                    "__body": failure.read().decode(errors="replace")[:200]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:8065/api/v4")
    parser.add_argument("--login", default="perfprobe")
    parser.add_argument("--password", default=DEFAULT_PASSWORD)
    args = parser.parse_args()

    client = Client(args.base)
    me = client.call("/users/login", "POST", {"login_id": args.login, "password": args.password})
    if "id" not in me:
        print(f"could not sign in as {args.login}: {me}", file=sys.stderr)
        return 2
    print(f"me: {me['id']} @{me['username']} roles={me.get('roles')}")

    teams = client.call("/users/me/teams")
    for index, team in enumerate(teams):
        print(f"\nteams[{index}] {team['id']} {team.get('display_name')} (name={team.get('name')})")
        users = client.call(f"/users?in_team={team['id']}&page=0&per_page=200")
        if not isinstance(users, list):
            print(f"  GET /users?in_team= -> {users}")
            continue
        gone = [u for u in users if (u.get("delete_at") or 0) > 0]
        print(f"  members={len(users)} active={len(users) - len(gone)} deactivated={len(gone)}")
        for user in gone:
            print(f"    deactivated: {user['id']} @{user['username']} "
                  f"delete_at={user.get('delete_at')}")
            term = user["username"][:5]
            search = client.call("/users/search", "POST",
                                 {"term": term, "team_id": team["id"], "page": 0,
                                  "per_page": 50, "allow_inactive": False})
            found = isinstance(search, list) and any(u.get("id") == user["id"] for u in search)
            print(f"    POST /users/search term={term!r} allow_inactive=false -> "
                  f"{'PRESENT (unexpected)' if found else 'absent (expected)'}")
        active_ids = [u["id"] for u in users if (u.get("delete_at") or 0) == 0][:20]
        if active_ids:
            statuses = client.call("/users/status/ids", "POST", active_ids)
            print("  statuses:", [(s.get("user_id", "")[-6:], s.get("status")) for s in statuses])
        channels = client.call(f"/users/me/teams/{team['id']}/channels")
        if isinstance(channels, list):
            open_channels = [c for c in channels
                             if c.get("type") in ("O", "P") and (c.get("delete_at") or 0) == 0]
            for channel in open_channels[:2]:
                rows = client.call(f"/users?in_team={team['id']}&not_in_channel={channel['id']}"
                                   f"&page=0&per_page=200")
                if not isinstance(rows, list):
                    continue
                inactive = [u['username'] for u in rows if (u.get("delete_at") or 0) > 0]
                print(f"  add-people list for {channel['name']}: rows={len(rows)} "
                      f"deactivated={len(inactive)}{' -> ' + str(inactive) if inactive else ''}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
