#!/usr/bin/env python3
"""Register (or archive) the four stub slash commands that `scripts/t88_slash_stub.py` answers.

The card's reproduction asks for a live witness of the *plugin* command path; the fixture's own
plugin commands (`/call`, `/playbook`) cover that. They do not, however, return `goto_location`,
two `extra_responses`, or an open dialog, so these four custom integrations stand in for those
response shapes — that is what "prove it with a stub" means here.

  POST /api/v4/commands  (the documented endpoint)         — tried first
  docker exec mm-perf mmctl --local command create …       — fallback (the REST call is 403 for
                                                             some team states; measured)

Usage:
  python3 scripts/t88_slash_register.py                 # create/refresh the four commands
  python3 scripts/t88_slash_register.py --archive       # archive them
  python3 scripts/t88_slash_register.py --list          # just list what the team has
"""
from __future__ import annotations

import argparse
import json
import subprocess
import urllib.error
import urllib.parse
import urllib.request

BASE = "http://127.0.0.1:8065"
API = BASE + "/api/v4"
LOGIN = ("perfprobe", "PerfProbe-Not-A-Real-Secret-1")
CONTAINER = "mm-perf"
TEAM = "perf"
CALLBACK = "http://host.docker.internal:8099/cmd"

COMMANDS = [
    ("t88echo", "stub: posts its answer in the channel", "'text'"),
    ("t88multi", "stub: one ephemeral answer plus two extra_responses", "'text'"),
    ("t88goto", "stub: answers with goto_location", "'text'"),
    ("t88dialog", "stub: answers with trigger_id and opens a dialog", "'text'"),
]


def call(method: str, path: str, token: str | None = None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json", "X-Requested-With": "XMLHttpRequest"}
    if token:
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request(API + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = response.read()
            return response.status, (json.loads(payload) if payload.strip() else None)
    except urllib.error.HTTPError as error:
        raw = error.read().decode(errors="replace")
        try:
            return error.code, json.loads(raw)
        except ValueError:
            return error.code, raw


def login() -> str:
    request = urllib.request.Request(
        API + "/users/login",
        data=json.dumps({"login_id": LOGIN[0], "password": LOGIN[1]}).encode(),
        headers={"Content-Type": "application/json", "X-Requested-With": "XMLHttpRequest"},
        method="POST")
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.headers.get("Token", "")


def mmctl(*args: str) -> tuple[int, str]:
    result = subprocess.run(
        ["docker", "exec", CONTAINER, "/mattermost/bin/mmctl", "--local", *args],
        capture_output=True, text=True, timeout=120)
    return result.returncode, (result.stdout + result.stderr).strip()


def team_id(token: str) -> str:
    _, teams = call("GET", "/users/me/teams", token)
    return next(t["id"] for t in teams if t["name"] == TEAM)


def list_commands(token: str) -> list[dict]:
    _, commands = call("GET", "/commands?team_id=" + team_id(token), token)
    return commands or []


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", action="store_true")
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()
    token = login()

    existing = {c["trigger"]: c for c in list_commands(token)
                if c["trigger"].startswith("t88")}
    if args.list:
        for trigger, command in sorted(existing.items()):
            print(trigger, "| id", command.get("id"), "| autoc",
                  command.get("auto_complete"), "|", command.get("auto_complete_desc"))
        if not existing:
            print("no t88 commands on team", TEAM)
        return 0

    if args.archive:
        for trigger, command in sorted(existing.items()):
            if command.get("id"):
                code, out = mmctl("command", "archive", TEAM, command["id"])
                print("archive", trigger, "->", code, out)
        return 0

    for trigger, description, hint in COMMANDS:
        if trigger in existing:
            print("have", trigger, "id", existing[trigger].get("id"), "- skipped")
            continue
        # The documented endpoint first: one request, no container round trip.
        status, body = call("POST", "/commands", token, {
            "team_id": team_id(token),
            "trigger": trigger,
            "method": "P",
            "url": CALLBACK,
            "auto_complete": True,
            "auto_complete_desc": description,
            "auto_complete_hint": hint,
            "display_name": trigger,
            "description": description,
            "creator_id": "",
        })
        print("REST create", trigger, "->", status,
              json.dumps(body)[:160] if not isinstance(body, str) else body[:160])
        if status != 201:
            code, out = mmctl("command", "create", TEAM,
                              "--creator", LOGIN[0],
                              "--trigger-word", trigger,
                              "--title", trigger,
                              "--description", description,
                              "--url", CALLBACK,
                              "--post",
                              "--autocomplete",
                              "--autocompleteDesc", description,
                              "--autocompleteHint", hint)
            print("mmctl create", trigger, "->", code, out[-300:])
    print()
    for command in sorted(list_commands(token), key=lambda c: c["trigger"]):
        if command["trigger"].startswith("t88"):
            print("registered:", json.dumps({k: command.get(k) for k in
                                             ("id", "trigger", "url", "method",
                                              "auto_complete", "auto_complete_desc")}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
