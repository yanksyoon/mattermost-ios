#!/usr/bin/env python3
"""T44b: read and write the Calls plugin's settings on the fixture, and revert them.

Why this exists: on Mattermost 9.11.19 the plugin's own config endpoint
`PUT /api/v4/plugins/com.mattermost.calls/config` is a 404 (`api.context.404.app_error`), so plugin
settings live in the **core** config at
`PluginSettings.Plugins["com.mattermost.calls"]`, keyed exactly as the plugin manifest's
`settings_schema` keys (`ICEHostOverride`, `ICEHostPortOverride`, …). This script reads that object,
writes one key through `PUT /api/v4/config` (which needs the whole config document back), and can
clear it again — the fixture change this card makes must be reversible with one command.

    python3 scripts/t44b_calls_config.py show
    python3 scripts/t44b_calls_config.py set ICEHostOverride 127.0.0.1
    python3 scripts/t44b_calls_config.py clear ICEHostOverride      # revert to the plugin default
    python3 scripts/t44b_calls_config.py show --json

The session token is never printed. Each write prints the server's own answer, including an error
body verbatim if it refuses (a 4xx is not worked around here).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import t44_calls_probe as probe  # noqa: E402

PLUGIN_ID = "com.mattermost.calls"


def plugin_settings(config: dict[str, Any]) -> dict[str, Any]:
    plugins = (config.get("PluginSettings") or {}).get("Plugins") or {}
    return plugins.get(PLUGIN_ID) or {}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["show", "set", "clear"])
    parser.add_argument("key", nargs="?", help="plugin setting key, e.g. ICEHostOverride")
    parser.add_argument("value", nargs="?", help="value for `set`")
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    token, me = probe.login(args.url, probe.ADMIN_LOGIN, probe.ADMIN_PASSWORD)
    roles = me.get("roles", "")
    status, config, _ = probe.call(args.url, "GET", "/api/v4/config", token=token)
    if status != 200 or not isinstance(config, dict):
        print(f"FAIL  GET /api/v4/config -> HTTP {status} {config}")
        return 2
    current = plugin_settings(config)

    if args.command == "show":
        print(f"fixture {args.url} — signed in as {me.get('username')} (system_admin="
              f"{'system_admin' in roles})")
        print(f"PluginSettings.Plugins[{PLUGIN_ID!r}] = "
              f"{json.dumps(current, sort_keys=True) if current else '{} (absent: plugin defaults)'}")
        if args.json:
            print(json.dumps({"plugin_settings": current, "roles": roles}, indent=2))
        return 0

    if not args.key:
        print("FAIL  `set`/`clear` need a key, e.g. ICEHostOverride")
        return 2
    if args.command == "set" and args.value is None:
        print("FAIL  `set` needs a value")
        return 2

    plugins = (config.setdefault("PluginSettings", {})).setdefault("Plugins", {})
    entry = dict(plugins.get(PLUGIN_ID) or {})
    if args.command == "set":
        entry[args.key] = args.value
    else:
        entry.pop(args.key, None)
    if entry:
        plugins[PLUGIN_ID] = entry
    else:
        plugins.pop(PLUGIN_ID, None)

    status, body, _ = probe.call(args.url, "PUT", "/api/v4/config", body=config, token=token)
    if status != 200:
        print(f"FAIL  PUT /api/v4/config -> HTTP {status}\n{json.dumps(body, indent=2)}")
        return 1

    # Read back — the fixture has to be verified, not assumed.
    status, after, _ = probe.call(args.url, "GET", "/api/v4/config", token=token)
    written = plugin_settings(after) if isinstance(after, dict) else {}
    ok = written == (plugins.get(PLUGIN_ID) or {})
    print(f"{'OK   ' if ok else 'FAIL '} PluginSettings.Plugins[{PLUGIN_ID!r}] is now "
          f"{json.dumps(written, sort_keys=True) if written else '{} (absent)'}")
    _, live, _ = probe.call(args.url, "GET", probe.PLUGIN + "/config", token=token)
    if isinstance(live, dict):
        print(f"      plugin reports ICEHostOverride={live.get('ICEHostOverride')!r} "
              f"ICEHostPortOverride={live.get('ICEHostPortOverride')!r} "
              f"AllowEnableCalls={live.get('AllowEnableCalls')}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
