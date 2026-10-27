#!/usr/bin/env python3
"""Freeze the iOS unit-test host *inside* a test class, and prove that it landed there.

Why this exists next to `scripts/qa-freeze-host.sh` (t_19ab2cbc): that harness waits for a line in
the xcodebuild log and then `SIGSTOP`s the host. It worked while the class it was aimed at contained
3 s polls — the class took ~15 s to run, so a marker that surfaced seconds late still landed inside
it. A class with no wall-clock waits runs in ~0.1 s: by the time the marker is flushed the class is
over and the host is gone, so a marker-triggered freeze silently proves nothing.

Two things make the check honest for a fast class, both internal to this file:

  * `-test-iterations N` runs the class N times back to back, so it occupies a window of ~N x its
    own duration instead of one blink;
  * the freeze is triggered on the first test-case line in the log and the trigger lag is swept,
    because the flush lag is seconds and varies.

A run only counts when the log itself proves the freeze landed inside the class: some test's own
reported duration is >= the freeze (XCTest times each test on the wall clock, and a stopped process
cannot finish a test while it is stopped). Exit 0 on the first such run with zero failures.

Usage:
  python3 scripts/qa-freeze-host-window.py --sim "id=81A7F251-…" \
    --only-testing MattermostTests/T44DCallsCoordinatorTests
  # …optionally --iterations 100 --freeze 4.5 --derived-data ~/Library/.../SomeDdata
"""
from __future__ import annotations

import argparse
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_DERIVED = Path.home() / "Library/Developer/Xcode/DerivedData/mattermost-ios-qa"
LAGS = ["0.0", "0.4", "0.8", "1.2", "1.6", "2.0", "2.4", "3.0"]
HOST_MATCH = "Mattermost.app/Mattermost"


def host_pid() -> str | None:
    out = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if HOST_MATCH in line and "Runner" not in line:
            return line.split()[0]
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sim", default="iPhone 16 Pro")
    ap.add_argument("--only-testing", required=True)
    ap.add_argument("--derived-data", default=str(DEFAULT_DERIVED))
    ap.add_argument("--iterations", default="100")
    ap.add_argument("--freeze", type=float, default=4.5)
    ap.add_argument("--lags", nargs="*", default=LAGS)
    ap.add_argument("--timeout", default="900")
    args = ap.parse_args()

    # The class name as it appears in the log (`MattermostTests.T44DCallsCoordinatorTests`).
    class_name = args.only_testing.split("/")[-1]
    test_line = re.compile(
        rf"Test Case '-\[\S+\.{re.escape(class_name)} (\w+)\]' (passed|failed) \(([0-9.]+) seconds\)")
    executed = re.compile(r"Executed (\d+) tests, with (\d+) failures")

    for index, lag in enumerate(args.lags, start=1):
        lag = float(lag)
        label = f"freeze-window-{index}"
        log = REPO / "build/logs" / f"{label}.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        if log.exists():
            log.unlink()
        proc = subprocess.Popen(
            [sys.executable, "scripts/qa-test.py", "--platform", "ios", "--sim", args.sim,
             "--only-testing", args.only_testing, "--label", label,
             "--derived-data", args.derived_data,
             "--timeout", args.timeout, "--stall-timeout", "300",
             "--", "-test-iterations", str(args.iterations)],
            cwd=REPO, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        deadline = time.time() + 300
        while time.time() < deadline:
            if log.exists() and f"{class_name} test" in log.read_text(errors="replace"):
                break
            if proc.poll() is not None:
                break
            time.sleep(0.02)

        stopped = released = None
        if proc.poll() is None:
            time.sleep(lag)
            pid = host_pid()
            if pid:
                try:
                    stopped = time.strftime("%H:%M:%S")
                    os.kill(int(pid), signal.SIGSTOP)
                    time.sleep(args.freeze)
                    os.kill(int(pid), signal.SIGCONT)
                    released = time.strftime("%H:%M:%S")
                except ProcessLookupError:
                    stopped = released = None
        try:
            proc.wait(timeout=float(args.timeout))
        except subprocess.TimeoutExpired:
            proc.kill()

        text = log.read_text(errors="replace") if log.exists() else ""
        durations: dict[str, tuple[str, float]] = {}
        for m in test_line.finditer(text):
            name, state, secs = m.group(1), m.group(2), float(m.group(3))
            if name not in durations or secs > durations[name][1]:
                durations[name] = (state, secs)   # the slowest iteration is the frozen one
        summary = executed.search(text)
        red = sorted(n for n, (s, _) in durations.items() if s == "failed")
        frozen = sorted(((d, n) for n, (_, d) in durations.items() if d >= args.freeze), reverse=True)
        print(f"[{label}] lag={lag:.2f}s stop={stopped} cont={released} "
              f"{summary.group(0) if summary else 'not executed'} red={red} "
              f"frozen={[f'{n} ({d:.2f}s)' for d, n in frozen]}", flush=True)
        if frozen and not red:
            print(f"\nACCEPT: green with the host stopped for {args.freeze}s inside the class — "
                  f"{label}: {[f'{n} ({d:.2f}s)' for d, n in frozen]}")
            return 0
    print("\nNO RUN PROVED THE FREEZE LANDED INSIDE THE CLASS")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
