#!/usr/bin/env python3
"""T48-AV probe — each post-options row, against the server's own record.

What it measures (9.11.19 fixture, `mm-perf` on 127.0.0.1:8065):

  1. follow      the flag lives on the **channel page's root row**, not on the thread object
  2. unread      `POST /users/{uid}/posts/{pid}/set_unread` answers the membership row
  3. save        `PUT /users/{uid}/preferences` publishes `preferences_changed`
  4. unsave      `POST /users/{uid}/preferences/delete` publishes `preferences_deleted`
  5. pin         `pin_post`/`unpin_post` are not permission ids here; `create_post` is; the endpoint
                 refuses an account whose channel roles carry no post-write id
  6. edit        `PUT /posts/{pid}/patch`
  7. delete      `DELETE /posts/{pid}`, and what a pin on the deleted post then answers (the forced
                 refusal the UI test uses)
  8. permalink   `/perf/pl/<post>` and `/ops/pl/<post>` — the server answers both, so the client's
                 string is the only thing that can be right or wrong

Prints one line per measurement and a JSON block at the end. No password is printed.

    uv run --with websockets python3 scripts/t48_av_probe.py
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ.get("MM_PROBE_SERVER", "http://127.0.0.1:8065")
LOGIN = os.environ.get("MM_PROBE_LOGIN", "perfprobe")
PASSWORD = os.environ.get("MM_PROBE_PASSWORD", "PerfProbe-Not-A-Real-Secret-1")
SECOND_LOGIN = os.environ.get("MM_PROBE_SECOND_LOGIN", "t36reply")
SECOND_PASSWORD = os.environ.get("MM_PROBE_SECOND_PASSWORD", "T36Reply-Not-A-Real-Secret-1")
TEAM = "perf"
CHANNEL = "t36-threads"

results: dict[str, object] = {}


def call(method: str, path: str, token: str | None = None, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + "/api/v4" + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read()
            answer = json.loads(raw) if raw else None
            if path == "/users/login":
                return r.status, answer, r.headers.get("Token", "")
            return r.status, answer, ""
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            parsed = json.loads(raw)
        except Exception:  # noqa: BLE001
            parsed = raw.decode(errors="replace")
        return e.code, parsed, ""


def login(login_id: str, password: str) -> tuple[str, str]:
    status, answer, header_token = call("POST", "/users/login",
                                        body={"login_id": login_id, "password": password})
    token = answer.get("token") or header_token
    print(f"[login] {login_id}: HTTP {status}, token via "
          f"{'body' if answer.get('token') else 'Token header'}")
    if status != 200 or not token:
        raise SystemExit(f"cannot sign in as {login_id}")
    return token, answer["id"]


def record(name: str, value) -> None:
    results[name] = value
    print(f"[{name}] {json.dumps(value, sort_keys=True)}")


def channel_page(token: str, channel_id: str, per_page: int = 60):
    return call("GET", f"/channels/{channel_id}/posts?page=0&per_page={per_page}", token)


def pref_rows(frame: dict) -> list:
    raw = (frame.get("data") or {}).get("preferences")
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except Exception:  # noqa: BLE001
            return [f"<unparsable string: {raw[:80]}>"]
    rows = []
    for item in raw or []:
        if isinstance(item, dict):
            rows.append((item.get("category"), item.get("name"), item.get("value")))
        else:
            rows.append(f"<{type(item).__name__}: {str(item)[:60]}>")
    return rows


def summarise(frames: list[dict]) -> list[dict]:
    return [{"event": f.get("event"),
             "preferences_type": type((f.get("data") or {}).get("preferences")).__name__,
             "raw_sample": str((f.get("data") or {}).get("preferences"))[:220],
             "rows": pref_rows(f)} for f in frames
            if str(f.get("event", "")).startswith("preferences_")]


async def socket_frames(token: str, actions) -> list[dict]:
    """Run `actions()` while listening; return the frames the server published to this session."""
    import websockets

    ws_url = BASE.replace("http://", "ws://").replace("https://", "wss://") + "/api/v4/websocket"
    frames: list[dict] = []
    async with websockets.connect(ws_url, max_size=8 * 1024 * 1024) as ws:
        await ws.send(json.dumps({"seq": 1, "action": "authentication_challenge",
                                  "data": {"token": token}}))
        # drain the hello / status burst
        try:
            async with asyncio.timeout(2):
                while True:
                    frame = json.loads(await ws.recv())
                    if frame.get("event") == "hello":
                        break
        except TimeoutError:
            pass
        result = actions()
        if asyncio.iscoroutine(result):
            await result
        try:
            async with asyncio.timeout(6):
                while True:
                    frames.append(json.loads(await ws.recv()))
        except TimeoutError:
            pass
    return frames


async def main() -> int:
    token, uid = login(LOGIN, PASSWORD)
    token2, uid2 = login(SECOND_LOGIN, SECOND_PASSWORD)

    _, teams, _ = call("GET", "/users/me/teams", token)
    team = next(t for t in teams if t["name"] == TEAM)
    tid = team["id"]
    _, channel, _ = call("GET", f"/teams/{tid}/channels/name/{CHANNEL}", token)
    cid = channel["id"]
    record("fixture", {"team": TEAM, "team_id": tid, "channel": CHANNEL, "channel_id": cid,
                       "viewer": LOGIN, "second": SECOND_LOGIN})

    stamp = int(time.time())
    _, root, _ = call("POST", "/posts", token2,
                      {"channel_id": cid, "message": f"t48-av root {stamp}"})
    root_id = root["id"]
    _, reply, _ = call("POST", "/posts", token2,
                       {"channel_id": cid, "root_id": root_id, "message": f"t48-av reply {stamp}"})
    reply_id = reply["id"]
    record("created", {"root": root_id, "reply": reply_id})

    # 1. follow — where does the server publish the flag?
    def follow_view(label: str) -> dict:
        out: dict[str, object] = {}
        _, page, _ = channel_page(token, cid)
        row_keys = (page.get("posts") or {}).get(root_id, {})
        out["channel_page"] = {"has_key": "is_following" in row_keys,
                               "value": row_keys.get("is_following")}
        _, post, _ = call("GET", f"/posts/{root_id}", token)
        out["get_post"] = {"has_key": isinstance(post, dict) and "is_following" in post,
                           "value": (post or {}).get("is_following")
                           if isinstance(post, dict) else None}
        _, thread, _ = call("GET", f"/users/me/teams/{tid}/threads/{root_id}", token)
        out["thread_endpoint"] = {"has_key": isinstance(thread, dict) and "is_following" in thread,
                                  "value": (thread or {}).get("is_following")
                                  if isinstance(thread, dict) else None}
        _, team_threads, _ = call("GET", f"/users/me/teams/{tid}/threads"
                                         "?page=0&per_page=60&extended=true", token)
        match = next((t for t in (team_threads or {}).get("threads", [])
                      if t.get("id") == root_id), None)
        out["threads_list"] = {"found": match is not None,
                               "has_key": bool(match) and "is_following" in match,
                               "value": (match or {}).get("is_following"),
                               "keys": sorted(match.keys()) if match else []}
        record(f"follow_view_{label}", out)
        return out

    before = follow_view("before")
    status_follow, _, _ = call("PUT", f"/users/me/teams/{tid}/threads/{root_id}/following",
                               token, {"state": True})
    after = follow_view("after_follow")
    status_unfollow, _, _ = call("DELETE", f"/users/me/teams/{tid}/threads/{root_id}/following",
                                 token)
    off = follow_view("after_unfollow")
    record("follow_write", {"put_following_http": status_follow,
                            "delete_following_http": status_unfollow,
                            "flag_visible_anywhere_after_follow": any(
                                (after[k].get("value") is True) for k in after),
                            "flag_visible_anywhere_before": any(
                                (before[k].get("value") is True) for k in before),
                            "flag_after_unfollow": {k: off[k].get("value") for k in off}})

    # 2. mark unread — the answer is the membership row
    _, before, _ = call("GET", f"/channels/{cid}/members/{uid}", token)
    status, membership, _ = call("POST", f"/users/{uid}/posts/{reply_id}/set_unread", token,
                                 {"collapsed_threads_supported": True})
    _, after, _ = call("GET", f"/channels/{cid}/members/{uid}", token)
    _, reply_read, _ = call("GET", f"/posts/{reply_id}", token)
    record("mark_unread", {"http": status,
                           "answered_keys": sorted(membership.keys())
                           if isinstance(membership, dict) else str(membership)[:160],
                           "answered_msg_count": (membership or {}).get("msg_count")
                           if isinstance(membership, dict) else None,
                           "answered_last_viewed_at": (membership or {}).get("last_viewed_at")
                           if isinstance(membership, dict) else None,
                           "membership_before_last_viewed_at": before.get("last_viewed_at"),
                           "membership_after_msg_count": after.get("msg_count"),
                           "membership_after_last_viewed_at": after.get("last_viewed_at"),
                           "post_create_at": reply_read.get("create_at"),
                           "unread": (after.get("last_viewed_at", 0)
                                      < reply_read.get("create_at", 0))})

    # 3/4. save + unsave, and the frames the server publishes
    def save() -> None:
        call("PUT", f"/users/{uid}/preferences", token,
             [{"user_id": uid, "category": "flagged_post", "name": root_id, "value": "true"}])

    def unsave() -> None:
        call("POST", f"/users/{uid}/preferences/delete", token,
             [{"user_id": uid, "category": "flagged_post", "name": root_id, "value": "true"}])

    frames = await socket_frames(token, save)
    save_frames = summarise(frames)
    _, prefs, _ = call("GET", f"/users/{uid}/preferences/flagged_post", token)
    saved_now = any(p.get("name") == root_id for p in (prefs or []))
    record("save", {"server_holds_flag": saved_now, "frames": save_frames})

    frames = await socket_frames(token, unsave)
    delete_frames = summarise(frames)
    _, prefs, _ = call("GET", f"/users/{uid}/preferences/flagged_post", token)
    record("unsave", {"server_holds_flag": any(p.get("name") == root_id for p in (prefs or [])),
                      "frames": delete_frames})

    # 5. pin — permission ids, the write, and a refusal
    _, me, _ = call("GET", "/users/me", token)
    _, team_member, _ = call("GET", f"/teams/{tid}/members/{uid}", token)
    _, channel_member, _ = call("GET", f"/channels/{cid}/members/{uid}", token)
    names = sorted(set(filter(None, (me.get("roles", "") + " " + team_member.get("roles", "") + " "
                                    + channel_member.get("roles", "")).split())))
    _, roles, _ = call("POST", "/roles/names", token, names)
    ids: set[str] = set()
    for role in roles or []:
        ids.update(role.get("permissions") or [])
    record("permissions", {"roles": names, "count": len(ids),
                           "pin_post": "pin_post" in ids,
                           "unpin_post": "unpin_post" in ids,
                           "create_post": "create_post" in ids,
                           "any_id_containing_pin": sorted(i for i in ids if "pin" in i)})

    status_pin, pin_answer, _ = call("POST", f"/posts/{root_id}/pin", token2)
    _, pinned_post, _ = call("GET", f"/posts/{root_id}", token2)
    status_unpin, _, _ = call("POST", f"/posts/{root_id}/unpin", token2)
    record("pin", {"pin_as_second_author_http": status_pin,
                   "is_pinned_after": pinned_post.get("is_pinned"),
                   "unpin_http": status_unpin,
                   "pin_error": pin_answer if status_pin >= 300 else None})

    # 5b. the refusal the three-way gate claims: an account with no post-write id in this channel
    restricted = "t48av-restricted"
    restricted_password = "T48AV-Restricted-Not-A-Secret-1"
    refusal: dict[str, object] = {"account": restricted}
    status_u, user, _ = call("GET", f"/users/username/{restricted}", token)
    if status_u != 200:
        status_c, created_user, _ = call("POST", "/users", token,
                                         {"email": f"{restricted}@example.invalid",
                                          "username": restricted,
                                          "password": restricted_password})
        refusal["created_http"] = status_c
        r_uid = (created_user or {}).get("id") if isinstance(created_user, dict) else None
    else:
        r_uid = (user or {}).get("id")
    refusal["user_id_present"] = bool(r_uid)
    if r_uid:
        r_token, r_login_uid = login(restricted, restricted_password)
        status_team, _, _ = call("POST", f"/teams/{tid}/members", token, {"team_id": tid, "user_id": r_uid})
        status_chan, _, _ = call("POST", f"/channels/{cid}/members", token, {"user_id": r_uid})
        refusal["team_member_http"] = status_team
        refusal["channel_member_http"] = status_chan
        status_set, _, _ = call("PUT", f"/channels/{cid}/members/{r_uid}/roles", token, {"roles": ""})
        refusal["set_no_roles_http"] = status_set
        _, r_member, _ = call("GET", f"/channels/{cid}/members/{r_uid}", token)
        refusal["member_roles_after"] = (r_member or {}).get("roles") if isinstance(r_member, dict) else None
        # The server's permission lookup caches a membership for ~a second: an immediate call can
        # still be authorised by the old roles (measured — the first probe version got 200 here and
        # the same call 30 s later got 403). Settle, then ask twice.
        time.sleep(3)
        status_refuse, body_refuse, _ = call("POST", f"/posts/{root_id}/unpin", r_token)
        if status_refuse == 200:
            call("POST", f"/posts/{root_id}/pin", token2)
            time.sleep(4)
            status_refuse, body_refuse, _ = call("POST", f"/posts/{root_id}/unpin", r_token)
        refusal["pin_without_write_role_http"] = status_refuse
        refusal["pin_without_write_role_body"] = (body_refuse.get("message")
                                                  if isinstance(body_refuse, dict) else body_refuse)
        call("PUT", f"/channels/{cid}/members/{r_uid}/roles", token, {"roles": "channel_user"})
        refusal["roles_restored"] = True
    record("pin_refusal", refusal)

    # 6. edit
    status, edited, _ = call("PUT", f"/posts/{reply_id}/patch", token2,
                             {"message": f"t48-av reply {stamp} (edited)"})
    _, fetched, _ = call("GET", f"/posts/{reply_id}", token)
    record("edit", {"http": status, "edit_at_set": (fetched or {}).get("edit_at"),
                    "message": fetched.get("message")})

    # 7. delete, and the pin on a deleted post (the forced refusal the UI test uses)
    status_del, deleted, _ = call("DELETE", f"/posts/{root_id}", token2)
    status_get, gone, _ = call("GET", f"/posts/{root_id}", token)
    status_pin_gone, body_pin_gone, _ = call("POST", f"/posts/{root_id}/pin", token)
    record("delete", {"delete_http": status_del,
                      "get_after_delete_http": status_get,
                      "delete_at": (gone or {}).get("delete_at") if isinstance(gone, dict) else None,
                      "pin_after_delete_http": status_pin_gone,
                      "pin_after_delete_body": (body_pin_gone or {}).get("message")
                      if isinstance(body_pin_gone, dict) else body_pin_gone})

    # 8. permalink — both team segments answer, so only the client's string can be wrong
    links = {}
    for segment in ("perf", "ops"):
        req = urllib.request.Request(BASE + f"/{segment}/pl/{reply_id}")
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                links[segment] = {"status": r.status,
                                  "content_type": r.headers.get("Content-Type"),
                                  "bytes": len(r.read())}
        except urllib.error.HTTPError as e:
            links[segment] = {"status": e.code}
    record("permalink", links)

    print()
    print("=== T48-AV JSON ===")
    print(json.dumps(results, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
