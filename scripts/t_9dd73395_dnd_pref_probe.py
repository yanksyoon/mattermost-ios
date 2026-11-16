#!/usr/bin/env python3
"""What unit is `dnd_end_time` in, and does `auto_reset_manual_status` round-trip? (t_9dd73395)

Two facts the account menu cannot guess, both asked of the pinned 9.11.19 server:

  Case 1  `PUT /users/{id}/status {"status":"dnd","dnd_end_time": now+3600}`     — the value the
          webapp's DND sub-menu sends (`endTime.utc().unix()`, **seconds**). What comes back?
  Case 2  the same with `(now+3600)*1000`                                        — T41 read the field
          as milliseconds; this is what a milliseconds write looks like to a server that reads
          seconds (a dot that stays red until the year 58,000), which is why the Swift type is
          `dndEndTimeSeconds` and not `...Millis`.
  Case 3  `PUT {"status":"away"}` with no `dnd_end_time`                         — does a plain
          status clear the field, or does it persist?
  Case 4  `GET /users/{id}/status` after each                                   — what a reader sees.
  Case 5  `PUT /users/{id}/preferences` with `auto_reset_manual_status`          — the row upstream's
          `reset_status_modal` writes (`name` = user id, `value` = 'true' / 'false'), then GET it
          back, then delete it. `''` (no row) is upstream's third state, "ask me".

The menu's confirmation rule is `autoResetPref === '' && status == OUT_OF_OFFICE`, so Case 5's three
states are exactly the three panels of `testLeavingOutOfOfficeAsksOnlyWhileThePreferenceIsUnset`.

Usage: python3 scripts/t_9dd73395_dnd_pref_probe.py [--url http://127.0.0.1:8065]
Dev-only credential, as in the other probes here; this is the throwaway `mm-perf` container.
"""
import argparse
import json
import time
import urllib.error
import urllib.request

LOGIN = "perfprobe"
PASSWORD = "PerfProbe-Not-A-Real-Secret-1"


def call(base, path, data=None, token=None, method=None):
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(base + path, data=body, method=method or ("POST" if body else "GET"))
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None), resp.headers.get("Token")
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            parsed = json.loads(raw) if raw else None
        except ValueError:
            parsed = raw.decode("utf-8", "replace")[:200]
        return exc.code, parsed, None


def status_line(base, uid, token):
    s, body, _ = call(base, f"/users/{uid}/status", token=token)
    body = body or {}
    return s, body.get("status"), body.get("dnd_end_time"), body.get("manual")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    args = parser.parse_args()
    base = args.url.rstrip("/") + "/api/v4"

    status, me, token = call(base, "/users/login", {"login_id": LOGIN, "password": PASSWORD})
    if status != 200 or not token:
        raise SystemExit(f"login failed: HTTP {status} {me}")
    uid = me["id"]

    now = int(time.time())
    print(f"now = {now} s ({time.strftime('%Y-%m-%d %H:%M:%SZ', time.gmtime(now))})\n")

    print("-- Case 1: seconds (what the webapp's sub-menu sends)")
    want = now + 3600
    s, body, _ = call(base, f"/users/{uid}/status",
                      {"user_id": uid, "status": "dnd", "dnd_end_time": want},
                      token=token, method="PUT")
    print(f"  PUT dnd_end_time={want} -> HTTP {s} echo={body.get('dnd_end_time') if body else None}")
    s, st, end, manual = status_line(base, uid, token)
    print(f"  GET                   -> HTTP {s} status={st} dnd_end_time={end} manual={manual}")
    print(f"  in force? {'yes — ' + str(end - now) + ' s from now' if end and end > now and end < now + 86400 else 'NO'}")

    print("\n-- Case 2: milliseconds (T41's assumption)")
    millis = (now + 3600) * 1000
    s, body, _ = call(base, f"/users/{uid}/status",
                      {"user_id": uid, "status": "dnd", "dnd_end_time": millis},
                      token=token, method="PUT")
    print(f"  PUT dnd_end_time={millis} -> HTTP {s} echo={body.get('dnd_end_time') if body else None}")
    s, st, end, manual = status_line(base, uid, token)
    years = (end - now) / 86400 / 365 if end else 0
    print(f"  GET                   -> HTTP {s} status={st} dnd_end_time={end} manual={manual}")
    print(f"  read as a date: {time.strftime('%Y', time.gmtime(end)) if end else '?'}"
          f"  (~{years:.0f} years out)" if end else "")

    print("\n-- Case 3: a plain status write, no end time")
    s, body, _ = call(base, f"/users/{uid}/status", {"user_id": uid, "status": "away"},
                      token=token, method="PUT")
    s, st, end, manual = status_line(base, uid, token)
    print(f"  PUT away (no dnd_end_time) -> HTTP {s}; GET status={st} dnd_end_time={end} "
          f"manual={manual}")
    print(f"  ^ the stale end time {'SURVIVED' if end else 'was cleared'}: omitting the field is "
          f"not a clear")

    print("\n-- Case 3b: an explicit `dnd_end_time: 0`")
    s, body, _ = call(base, f"/users/{uid}/status",
                      {"user_id": uid, "status": "online", "dnd_end_time": 0},
                      token=token, method="PUT")
    s, st, end, manual = status_line(base, uid, token)
    print(f"  PUT online dnd_end_time=0 -> HTTP {s}; GET status={st} dnd_end_time={end} "
          f"manual={manual}")

    print("\n-- Case 3c: `dnd` with no end time while a stale one is stored")
    call(base, f"/users/{uid}/status", {"user_id": uid, "status": "dnd", "dnd_end_time": 0},
         token=token, method="PUT")
    stale = int(time.time()) + 7200
    call(base, f"/users/{uid}/status", {"user_id": uid, "status": "dnd", "dnd_end_time": stale},
         token=token, method="PUT")
    call(base, f"/users/{uid}/status", {"user_id": uid, "status": "dnd"}, token=token, method="PUT")
    s, st, end, _ = status_line(base, uid, token)
    print(f"  after PUT dnd with no field -> status={st} dnd_end_time={end} "
          f"(stale {stale} {'kept' if end == stale else 'replaced'})")
    print("  ^ so \"Don't clear\" must send 0, or it keeps whatever was there")

    print("\n-- Case 5: auto_reset_manual_status, all three states")
    cat, pref_url = "auto_reset_manual_status", f"/users/{uid}/preferences"
    for value in ("true", "false"):
        row = {"user_id": uid, "category": cat, "name": uid, "value": value}
        put = call(base, pref_url, [row], token=token, method="PUT")
        s, prefs, _ = call(base, pref_url, token=token)
        rows = [p for p in (prefs or []) if p.get("category") == cat]
        print(f"  value={value!r}: PUT HTTP {put[0]}; read back {json.dumps(rows)}")
    delete = call(base, f"{pref_url}/delete",
                  [{"user_id": uid, "category": cat, "name": uid}], token=token, method="POST")
    s, prefs, _ = call(base, pref_url, token=token)
    rows = [p for p in (prefs or []) if p.get("category") == cat]
    print(f"  deleted: PUT HTTP {delete[0]}; read back {json.dumps(rows)}  "
          f"(no row = upstream's '' = ask before leaving OOO)")

    # Leave the container the way it was found.
    call(base, f"/users/{uid}/status", {"user_id": uid, "status": "online"}, token=token, method="PUT")
    s, st, end, _ = status_line(base, uid, token)
    print(f"\nrestored: status={st} dnd_end_time={end}")


if __name__ == "__main__":
    main()
