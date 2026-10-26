#!/usr/bin/env python3
"""Pick an available iPhone simulator UDID for CI.

Runner images rename simulators between OS releases, so a hard-coded
`-destination 'platform=iOS Simulator,name=iPhone 16'` rots. This resolves the
destination from whatever the image actually provides.

Usage
  scripts/ci_simulator.py                      # newest available iPhone UDID
  scripts/ci_simulator.py --runtime 26         # prefer a runtime matching "26"
  scripts/ci_simulator.py --from-file f.json   # parse saved simctl output
  scripts/ci_simulator.py --self-test

Exit: 0 with the UDID on stdout, 1 when no device qualifies.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys


def phones(payload: dict, runtime_hint: str | None = None) -> list[tuple[str, str, str]]:
    """Return [(udid, name, runtime)] for available iPhones, newest runtime first."""
    out: list[tuple[str, str, str]] = []
    for runtime, devices in (payload.get("devices") or {}).items():
        if runtime_hint and runtime_hint not in runtime:
            continue
        for d in devices or []:
            if not d.get("isAvailable"):
                continue
            name = d.get("name") or ""
            if "iPhone" not in name:
                continue
            udid = d.get("udid") or ""
            if udid:
                out.append((udid, name, runtime))

    def runtime_key(item: tuple[str, str, str]) -> tuple:
        # "com.apple.CoreSimulator.SimRuntime.iOS-26-6" -> (26, 6) so 26.6 > 26.10 > 18.3
        nums = [int(n) for n in re.findall(r"\d+", item[2].split("iOS")[-1] or "")]
        return (tuple(nums), item[1])

    out.sort(key=runtime_key, reverse=True)
    return out


def self_test() -> int:
    payload = {
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-3": [
                {"name": "iPhone 16 Pro", "udid": "OLD-PRO", "isAvailable": True},
                {"name": "iPhone 16", "udid": "OLD-16", "isAvailable": False},
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-6": [
                {"name": "iPhone 17 Pro", "udid": "NEW-PRO", "isAvailable": True},
                {"name": "iPad Pro 11-inch (M5)", "udid": "IPAD", "isAvailable": True},
                {"name": "iPhone 17", "udid": "NEW-17", "isAvailable": True},
                {"name": "iPhone 17 mini", "udid": "GONE", "isAvailable": False},
            ],
        }
    }
    fails = 0

    got = phones(payload)
    want_udids = {"NEW-PRO", "NEW-17", "OLD-PRO"}
    if {g[0] for g in got} != want_udids:
        print(f"  [FAIL] filtering: got {[g[0] for g in got]}"); fails += 1
    else:
        print("  [PASS] iPads and unavailable devices excluded")

    if got[0][2].startswith("com.apple.CoreSimulator.SimRuntime.iOS-26-6") is False:
        print("  [FAIL] newest runtime not first"); fails += 1
    else:
        print("  [PASS] newest runtime first (26.6 before 18.3)")

    if any(g[0] == "IPAD" for g in got):
        print("  [FAIL] iPad leaked into iPhone selection"); fails += 1
    else:
        print("  [PASS] iPhone-only")

    hinted = phones(payload, runtime_hint="18")
    if [h[0] for h in hinted] != ["OLD-PRO"]:
        print(f"  [FAIL] runtime hint: got {[h[0] for h in hinted]}"); fails += 1
    else:
        print("  [PASS] --runtime 18 filters to 18.x")

    if phones({"devices": {}}):
        print("  [FAIL] empty payload returned a device"); fails += 1
    else:
        print("  [PASS] empty payload yields nothing")

    print("SELF-TEST: PASS" if fails == 0 else f"SELF-TEST: FAIL {fails}")
    return 0 if fails == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--runtime", default=None)
    ap.add_argument("--from-file", default=None)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    if args.from_file:
        with open(args.from_file) as fh:
            payload = json.load(fh)
    else:
        r = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "--json"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(f"simctl failed: {r.stderr.strip()}", file=sys.stderr)
            return 1
        payload = json.loads(r.stdout)

    found = phones(payload, args.runtime)
    if not found:
        print("no available iPhone simulator", file=sys.stderr)
        return 1
    print(found[0][0])
    print(f"# {found[0][1]} on {found[0][2]}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
