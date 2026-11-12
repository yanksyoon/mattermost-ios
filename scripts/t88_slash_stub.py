#!/usr/bin/env python3
"""A stub slash-command integration for the dev fixture — the card's "prove it with a stub" harness.

Why it exists: the fixture's plugin commands (`/call`, `/playbook`) answer ephemeral text and an
empty body, but neither of them opens an interactive dialog, returns `goto_location`, or returns two
`extra_responses`. Those four response shapes are what the native composer has to draw, so an
integration registered over `POST /commands` points its callback URL here and answers on demand.

Each request the server makes is appended to `--log` as one JSON object: the *whole* form body the
server sent (including `trigger_id`, `channel_id`, `team_id`, `root_id`, `parent_id`) and the body
this stub answered with. That file is the card's wire evidence.

Behaviour, by trigger of the command line the server forwards:

  /t88echo   <text>   -> `in_channel`: the server posts the message itself (socket `posted`)
  /t88multi  <text>   -> `ephemeral` plus two `extra_responses` (ephemeral + in_channel)
  /t88goto   <text>   -> `ephemeral` with `goto_location` set
  /t88dialog <text>   -> `ephemeral`; the stub first opens an interactive dialog for the trigger id
                         the server handed it (`POST /api/v4/actions/dialogs/open`)
  anything else       -> `ephemeral` describing what it saw (a probe)

Register the commands with:

  docker exec mm-perf /mattermost/bin/mmctl --local command create perf \
      --creator perfprobe --title t88 --trigger-word t88echo \
      --url http://host.docker.internal:8099/cmd --post --autocomplete \
      --autocompleteDesc "stub: posts its answer in the channel" --autocompleteHint "'text'"

(`scripts/t88_slash_register.py` does all four and can archive them again.)

Usage: python3 scripts/t88_slash_stub.py [--port 8099] [--log /tmp/t88_stub.jsonl] \
                                        [--server http://127.0.0.1:8065] [--token TOKEN]
The token is only needed for the dialog's `POST /actions/dialogs/open`; without it the stub still
answers, and says in the log that it could not open a dialog.
"""
from __future__ import annotations

import argparse
import json
import os
import threading
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG_LOCK = threading.Lock()
CONFIG = {"log": None, "server": "http://127.0.0.1:8065", "token": "", "login": ""}
TOKEN: dict[str, str] = {}


def auth_token() -> str:
    """The stub's own session: `--token` if given, else perfprobe's password login."""
    if CONFIG["token"]:
        return CONFIG["token"]
    if TOKEN.get("value"):
        return TOKEN["value"]
    request = urllib.request.Request(
        CONFIG["server"].rstrip("/") + "/api/v4/users/login",
        data=json.dumps({"login_id": "perfprobe",
                         "password": "PerfProbe-Not-A-Real-Secret-1"}).encode(),
        headers={"Content-Type": "application/json", "X-Requested-With": "XMLHttpRequest"},
        method="POST")
    with urllib.request.urlopen(request, timeout=15) as response:
        TOKEN["value"] = response.headers.get("Token", "")
    return TOKEN["value"]


def log_record(record: dict) -> None:
    path = CONFIG["log"]
    if not path:
        return
    with LOG_LOCK, open(path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True) + "\n")


def open_dialog(trigger_id: str, channel_id: str) -> dict:
    """Ask the server to push `open_dialog` for this trigger id, exactly as a plugin does."""
    body = {
        "trigger_id": trigger_id,
        "url": "http://host.docker.internal:8099/dialog-submit",
        "dialog": {
            "callback_id": "t88dialog_callback",
            "title": "T88 stub dialog",
            "introduction_text": "Opened by a stub slash command, not a plugin.",
            "elements": [
                {"display_name": "Name", "name": "name", "type": "text", "placeholder": "who",
                 "optional": False, "min_length": 2, "max_length": 40},
                {"display_name": "Notify", "name": "notify", "type": "bool", "default": "false"},
            ],
            "submit_label": "Send",
            "notify_on_cancel": False,
            "state": "t88",
        },
    }
    request = urllib.request.Request(
        CONFIG["server"].rstrip("/") + "/api/v4/actions/dialogs/open",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json",
                 "X-Requested-With": "XMLHttpRequest",
                 "Authorization": "Bearer " + auth_token()},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return {"status": response.status, "body": response.read().decode(errors="replace")}
    except Exception as error:  # noqa: BLE001 - the log is the report
        detail = ""
        if hasattr(error, "read"):
            detail = error.read().decode(errors="replace")
        return {"status": getattr(error, "code", 0), "body": detail or str(error)}


def answer(fields: dict) -> dict:
    command = fields.get("command", "")
    trigger = command.split(" ")[0].lower()
    text = command[len(trigger):].strip()
    if trigger == "/t88echo":
        return {"response_type": "in_channel", "text": "stub echo: " + text}
    if trigger == "/t88multi":
        return {
            "response_type": "ephemeral",
            "text": "t88 multi: first (ephemeral)",
            "extra_responses": [
                {"response_type": "ephemeral", "text": "t88 multi: second (ephemeral)"},
                {"response_type": "in_channel", "text": "t88 multi: third (in channel)"},
            ],
        }
    if trigger == "/t88goto":
        return {
            "response_type": "ephemeral",
            "text": "t88 goto: taking you to town-square",
            "goto_location": CONFIG["server"].rstrip("/") + "/perf/channels/town-square",
        }
    if trigger == "/t88dialog":
        opened = open_dialog(fields.get("trigger_id", ""), fields.get("channel_id", ""))
        return {"response_type": "ephemeral",
                "text": "t88 dialog: asked the server to open one (HTTP %s)" % opened["status"],
                "_dialog_open": opened}
    return {"response_type": "ephemeral",
            "text": "t88 probe saw: " + json.dumps({k: fields.get(k) for k in
                                                    ("command", "channel_id", "team_id",
                                                     "root_id", "parent_id", "trigger_id")},
                                                   sort_keys=True)}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # keep the console quiet; --log is the record
        pass

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/health"):
            self._send(200, b"ok", "text/plain")
            return
        self._send(404, b"no", "text/plain")

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode(errors="replace")
        if self.path.startswith("/dialog-submit"):
            log_record({"kind": "dialog_submit", "body": raw})
            self._send(200, b'{"type":"ok","text":"stub accepts the submission"}',
                       "application/json")
            return
        fields = {key: values[0] for key, values in
                  urllib.parse.parse_qs(raw, keep_blank_values=True).items()}
        response = answer(fields)
        log_record({"kind": "command", "request": fields, "response": response})
        payload = json.dumps({k: v for k, v in response.items() if not k.startswith("_")}).encode()
        self._send(200, payload, "application/json")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8099)
    parser.add_argument("--log", default=os.path.join(os.environ.get("TMPDIR", "/tmp"),
                                                      "t88_slash_stub.jsonl"))
    parser.add_argument("--server", default="http://127.0.0.1:8065")
    parser.add_argument("--token", default=os.environ.get("T88_TOKEN", ""))
    args = parser.parse_args()
    CONFIG["log"] = args.log
    CONFIG["server"] = args.server
    CONFIG["token"] = args.token
    server = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    print("t88 stub listening on 0.0.0.0:%d, log %s" % (args.port, args.log), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
