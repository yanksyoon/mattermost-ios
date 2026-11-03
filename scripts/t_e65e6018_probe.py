#!/usr/bin/env python3
"""Read-only probe for t_e65e6018: the add-people picker's two reads.

Measures, on the live 9.11.19 fixture:
  * `GET /users?in_team={tid}&not_in_channel={cid}` (the picker's opening list, per_page=50 as the
    app sends it) — how many rows, and which of them have delete_at != 0;
  * `POST /users/search` with `not_in_channel_id` and `allow_inactive:false` (the typed search) — does
    the same account appear?

Also prints the id of the last *active* row in the opening list, in the server's own order — the app
draws that order unchanged (AddMembersViewModel.absorb does not sort), so a UI sweep that reaches that
row has traversed the whole list.
"""
import json
import sys
import urllib.request

BASE = "http://127.0.0.1:8065/api/v4"
LOGIN = "perfprobe"
PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
PER_PAGE = 50  # ChannelInfoServing.pickerPageSize


def call(path, method="GET", body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(BASE + path, data=data, method=method)
    request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(request, timeout=30) as answer:
        return answer.headers.get("Token"), json.loads(answer.read().decode())


token, me = call("/users/login", "POST", {"login_id": LOGIN, "password": PASSWORD})
_, teams = call("/users/me/teams", token=token)
team = teams[0]
print(f"team {team['display_name']} ({team['id']})")
_, all_channels = call(f"/users/me/teams/{team['id']}/channels", token=token)
by_name = {c["name"]: c for c in all_channels}
print(f"channels visible to {LOGIN}: {len(all_channels)}; t40-standup present: {'t40-standup' in by_name}")

targets = [c for name in ("t40-standup", "perf-feed") if (c := by_name.get(name))]
if not targets:
    print("neither t40-standup nor perf-feed exists — cannot probe")
    sys.exit(1)

for channel in targets:
    cid = channel["id"]
    _, users = call(f"/users?in_team={team['id']}&not_in_channel={cid}&page=0&per_page={PER_PAGE}",
                    token=token)
    gone = [u for u in users if (u.get("delete_at") or 0) > 0]
    active = [u for u in users if (u.get("delete_at") or 0) == 0]
    print(f"\n#{channel['name']} ({cid})")
    print(f"  opening list rows={len(users)} active={len(active)} deactivated={len(gone)}"
          + (f" -> {[(u['username'], u['id'], u['delete_at']) for u in gone]}" if gone else ""))
    print(f"  order (usernames): {[u['username'] for u in users]}")
    print(f"  last active row in server order: {active[-1]['username'] if active else None} "
          f"{active[-1]['id'] if active else ''}")
    for u in gone:
        term = u["username"][:5]
        _, hits = call("/users/search", "POST",
                       {"term": term, "team_id": team["id"], "not_in_channel_id": cid,
                        "page": 0, "per_page": PER_PAGE, "allow_inactive": False},
                       token=token)
        print(f"  search term {term!r}: rows={len(hits)} contains deactivated={any(h['id'] == u['id'] for h in hits)}")
