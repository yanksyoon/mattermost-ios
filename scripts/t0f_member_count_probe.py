"""t_0f8e0eb2 probe: what does a real 9.11.19 server answer for the header's count?

Measured, not assumed:
  * GET /channels/{id}/stats -> member_count for a fresh public channel (1, the creator);
  * the same after a second account is added (2);
  * the same for a direct message (2), which upstream deliberately does NOT read
    (app/screens/channel/header/index.ts: `dm ? undefined : ci?.memberCount`);
  * GET /channels/{id} itself carries no member_count (so the count has to be asked for).

Creates and deletes its own channel; leaves nothing behind.
"""
import json
import urllib.error
import urllib.request
import uuid
from pathlib import Path

BASE = "http://127.0.0.1:8065/api/v4"
SEED = str(Path(__file__).with_name("t43_notification_seed.py"))

ns = {}
exec(compile(open(SEED).read().split("def main(")[0], SEED, "exec"), ns)
ADMIN = ns["ADMIN_LOGIN"]
PASSWORD = ns["ADMIN_PASSWORD"]


def call(method, path, token=None, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()[:200]


login = urllib.request.Request(
    BASE + "/users/login",
    data=json.dumps({"login_id": ADMIN, "password": PASSWORD}).encode(),
    headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(login, timeout=10) as r:
    token = r.headers.get("Token")

_, me = call("GET", "/users/me", token)
_, buddy = call("GET", "/users/username/t43buddy", token)
_, teams = call("GET", "/users/me/teams", token)
team_id = teams[0]["id"]

name = "0-t0f-probe-" + uuid.uuid4().hex[:8]
status, channel = call("POST", "/channels", token, {"team_id": team_id, "name": name,
                                                  "display_name": "0 T0F probe", "type": "O"})
cid = channel["id"]
print("create channel:", status, cid)
print("GET /channels/{id} has member_count?:", "member_count" in channel,
      "| keys:", ",".join(sorted(channel.keys())))

_, stats = call("GET", "/channels/%s/stats" % cid, token)
print("stats after create:", {k: stats[k] for k in ("member_count", "guest_count")})

status, _ = call("POST", "/channels/%s/members" % cid, token, {"user_id": buddy["id"]})
print("add t43buddy:", status)
_, stats = call("GET", "/channels/%s/stats" % cid, token)
print("stats after add:", {k: stats[k] for k in ("member_count",)})

status, dm = call("POST", "/channels/direct", token, [me["id"], buddy["id"]])
print("dm create/lookup:", status, dm.get("type") if dm else dm)
if dm and dm.get("type") == "D":
    _, dmstats = call("GET", "/channels/%s/stats" % dm["id"], token)
    print("DM stats:", {k: dmstats[k] for k in ("member_count",)},
          "-> upstream still draws 'View info' for it")

print("delete probe channel:", call("DELETE", "/channels/%s" % cid, token)[0])
