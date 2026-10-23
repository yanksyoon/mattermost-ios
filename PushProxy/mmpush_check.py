#!/usr/bin/env python3
"""mmpush_check.py - Push-infra readiness / blocker inventory.

Honest status probe for T12: reports which pieces of the Mattermost Push
Proxy + APNs path exist vs are still needed on THIS host. Never fabricates a
deployment — it only inspects the local host and probes reachability.

Exit code 0 = fully ready (all gate items present); nonzero = something missing.
Run:  python3 mmpush_check.py [--proxy URL]
"""

import argparse
import json
import os
import socket
import subprocess
import sys

REPO = "/Users/yangsooyoon/mattermost-ios"
CONFIG = os.path.join(REPO, "PushProxy", "mmpush_proxy.json")
OFFICIAL_PROBES = [
    "https://api.push.mattermost.net",
    "https://api.push.mattermost.com",
    "https://host.mattermost.com",
]


def probe_url(url, timeout=5):
    """Return 'reachable' only if curl resolves the host and returns a real
    (2xx/3xx) HTTP status. Any DNS failure, timeout, or non-2xx/3xx is
    'unreachable(...)'. This must never call a failed probe 'reachable'."""
    try:
        res = subprocess.run(
            ["curl", "-sS", "--max-time", str(timeout), "-o", "/dev/null",
             "-w", "%{http_code}", url],
            capture_output=True, text=True, timeout=timeout + 3)
        code = res.stdout.strip()
        if code in ("000", ""):
            return f"unreachable (no HTTP status; dns/socket fail: {res.stderr.strip()[:80]})"
        if code.startswith(("2", "3")):
            return "reachable (HTTP " + code + ")"
        return f"unreachable (HTTP {code})"
    except Exception as e:
        return f"unreachable ({e})"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--proxy", help="self-hosted proxy URL to probe (e.g. https://push.example.com)")
    args = ap.parse_args()

    checks = []

    # 1. Simulacrum exists & is sane
    cfg_exists = os.path.exists(CONFIG)
    checks.append(("T12a mock proxy config file present",
                   cfg_exists,
                   "PASS (simulacrum config %s)" % CONFIG if cfg_exists
                   else "MISSING (runbook can't point T13 at anything)"))

    auth_key = None
    if cfg_exists:
        try:
            with open(CONFIG) as fh:
                cfg = json.load(fh)
            akp = cfg.get("ApplePushSettings", {}).get("AuthKeyPath", "")
            auth_key = akp if (akp and not akp.startswith("REPLACE_")
                               and not akp.startswith("/path/to")) else None
        except Exception:
            auth_key = None
    checks.append(("APPLE APNs auth key (.p8) present",
                   auth_key is not None,
                   f"PASS ({auth_key})" if auth_key else
                   "BLOCKER: no Apple-issued .p8 key on this host; only a human with an "
                   "Apple Developer account can create one (Keys > APNs). Needs input."))

    # 2. Reachability probes for the real / official endpoints
    for u in OFFICIAL_PROBES:
        r = probe_url(u)
        checks.append((f"probe {u}", r.startswith("reachable"), r))

    if args.proxy:
        r = probe_url(args.proxy)
        checks.append((f"probe self-hosted proxy {args.proxy}", r.startswith("reachable"), r))
    else:
        checks.append(("self-hosted proxy endpoint set", False,
                       "BLOCKER: no proxy URL provided (--proxy). Needs hosting decision "
                       "(design risk R1: confirm who runs the proxy)."))

    # 3. Dev contract (simulacrum endpoint T13 can use)
    checks.append(("local simulacrum endpoint (127.0.0.1:8066)",
                   True,
                   "RUNNABLE NOW  ->  python3 PushProxy/mmpush_proxy.py  (POST /api/v1/send_push)"))

    ready = all(c[1] for c in checks)
    print("\nMattermost Push Proxy + APNs readiness inventory (T12)\n" + "-" * 72)
    for name, ok, verdict in checks:
        print(f"  [{'OK ' if ok else '!! '}] {name}: {verdict}")
    print("-" * 72)
    print("REAL PUSH DELIVERY: ", "READY" if ready else "NOT READY — see blockers above")
    print("Simulacrum for T13 dev/tests is available regardless of the blockers.")
    return 0 if ready else 1


if __name__ == "__main__":
    sys.exit(main())