#!/usr/bin/env python3
"""Freeze the unit-test host and record *what the freeze reds*, suite-wide or per class.

Two modes, one measurement format:

  suite (default) — run the whole `MattermostTests` target, wait for `Test Suite '<suite>'
    started`, sleep `--offset` seconds, `SIGSTOP` the freshly launched host for `--freeze`
    seconds. Use this to sample the suite: one run freezes exactly one test.

  class (`--iterations N`) — run one class N times (`-test-iterations`), wait for its first
    test-case line, sleep `--lag`, freeze. Needed because a single class is often shorter than
    xcodebuild's multi-second log flush lag, so a marker-triggered freeze aimed at it would
    land after it (measured for a 0.1 s class in t_19ab2cbc: 12.1 s lag).

In both modes the log proves where the freeze landed without being told: XCTest times each test
on the wall clock, so the frozen test's own reported duration is >= the freeze while every other
test is milliseconds. The `frozen=` column is that proof; the `red=` column is the measurement.

Usage:
  # sample the whole suite at eight offsets
  python3 scripts/qa-freeze-measure.py --sim "id=81A7F251-…" \\
    --derived-data ~/Library/Developer/Xcode/DerivedData/t-eccd49eb \\
    --offsets 0,4,8,12,16,20,24,28 --label-prefix suite-freeze

  # measure one class, sweeping the flush lag until the freeze provably lands inside it
  python3 scripts/qa-freeze-measure.py --only-testing MattermostTests/T35ComposerViewModelTests \\
    --iterations 40 --lags 0,0.4,0.8,1.2,1.6,2.0,2.4,3.0 --stop-on-frozen
"""
from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_DERIVED = Path.home() / "Library/Developer/Xcode/DerivedData/t-eccd49eb"
HOST_MATCH = "Mattermost.app/Mattermost"
LAGS = ["0.0", "0.4", "0.8", "1.2", "1.6", "2.0", "2.4", "3.0"]


def host_pids() -> set[str]:
    out = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    found = set()
    for line in out.splitlines():
        if HOST_MATCH in line and "Runner" not in line:
            found.add(line.split()[0])
    return found


def new_host_pid(before: set[str]) -> str | None:
    for pid in host_pids() - before:
        return pid
    return None


TEST_LINE = re.compile(
    r"Test Case '-\[([\w.]+) (\w+)\]' (passed|failed) \(([0-9.]+) seconds\)")
EXECUTED = re.compile(r"Executed (\d+) tests?, with (\d+) tests? skipped and (\d+) failures?")
FAILURE = re.compile(r"^(\S+\.swift:\d+): error: -\[([\w.]+) (\w+)\] : (.*)$", re.M)


def run_one(args, trigger: float, index: int) -> dict:
    kind = "lag" if args.iterations else "off"
    label = f"{args.label_prefix}-{kind}{trigger:g}"
    log = REPO / "build/logs" / f"{label}.log"
    if log.exists():
        log.unlink()
    before = host_pids()
    cmd = [sys.executable, "scripts/qa-test.py", "--platform", "ios", "--sim", args.sim,
           "--only-testing", args.only_testing, "--label", label,
           "--derived-data", args.derived_data, "--timeout", str(args.timeout),
           "--stall-timeout", "300"]
    # `-collect-test-diagnostics never`: the xcodebuild default is `on-failure`, and a frozen test
    # that reds is exactly the case here — the sysdiagnose it then collects added 5 minutes to
    # every red run of this harness (measured 2026-10-27). The verdict is in the log already.
    extras = ["-collect-test-diagnostics", "never"]
    if args.iterations:
        extras += ["-test-iterations", str(args.iterations)]
    cmd += ["--", *extras]
    proc = subprocess.Popen(cmd, cwd=REPO, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    class_name = args.only_testing.split("/")[-1]
    if args.iterations:
        marker = f"{class_name} test"
    else:
        # The target's suite line is `Test Suite '<target>.xctest' started` — a bundle name, not the
        # bare target name. (t_eccd49eb: the first sweep run waited 180 s on the wrong marker.)
        marker = f"Test Suite '{class_name}.xctest' started"
    deadline = time.time() + args.start_timeout
    while time.time() < deadline:
        try:
            if marker in log.read_text(errors="replace"):
                break
        except FileNotFoundError:
            pass
        if proc.poll() is not None:
            break
        time.sleep(0.05)

    stopped = released = None
    frozen_for = 0.0
    stop_epoch = None
    if proc.poll() is None:
        time.sleep(trigger)
        pid = new_host_pid(before)
        if pid:
            try:
                stopped = time.strftime("%H:%M:%S")
                stop_epoch = time.time()
                os.kill(int(pid), signal.SIGSTOP)
                t0 = time.time()
                time.sleep(args.freeze)
                frozen_for = time.time() - t0
                os.kill(int(pid), signal.SIGCONT)
                released = time.strftime("%H:%M:%S")
            except ProcessLookupError:
                stopped = released = None
    try:
        proc.wait(timeout=float(args.timeout))
    except subprocess.TimeoutExpired:
        proc.kill()

    text = log.read_text(errors="replace") if log.exists() else ""
    # Marker flush lag: the suite line carries its own start timestamp; `stopped` is wall clock now.
    marker_lag = None
    started_match = re.search(r"Test Suite '[^']*\.xctest' started at (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)", text)
    if started_match is None:
        started_match = re.search(r"Test Suite '[\w.]+' started at (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)", text)
    if started_match is not None and stop_epoch is not None:
        from datetime import datetime
        try:
            marker_lag = round(stop_epoch - datetime.strptime(started_match.group(1), "%Y-%m-%d %H:%M:%S.%f").timestamp(), 2)
        except ValueError:
            marker_lag = None
    durations: dict[str, tuple[str, float]] = {}
    for m in TEST_LINE.finditer(text):
        cls, name, state, secs = m.group(1), m.group(2), m.group(3), float(m.group(4))
        key = f"{cls.split('.')[-1]}.{name}"
        if key not in durations or secs > durations[key][1]:
            durations[key] = (state, secs)
    all_executed = EXECUTED.findall(text)
    # The log prints one `Executed` line per suite plus one for the whole run; the whole-run line has
    # the most tests. `search` would pick whichever suite happened to finish first.
    summary = None
    if all_executed:
        best = max(all_executed, key=lambda t: int(t[0]))
        summary = (f"Executed {best[0]} tests, with {best[1]} tests skipped and {best[2]} failures")
    red = sorted(n for n, (s, _) in durations.items() if s == "failed")
    frozen = sorted(((d, n) for n, (_, d) in durations.items() if d >= args.freeze), reverse=True)
    failures = [f"{m.group(2).split('.')[-1]}.{m.group(3)}: {m.group(4)}" for m in FAILURE.finditer(text)]
    row = {
        "label": label, "only_testing": args.only_testing, "trigger": trigger, "kind": kind,
        "freeze_requested": args.freeze, "freeze_applied": round(frozen_for, 2),
        "stop": stopped, "cont": released, "marker_lag": marker_lag,
        "summary": summary,
        "red": red, "frozen": [f"{n} ({d:.2f}s)" for d, n in frozen],
        "failures": failures, "log": str(log), "rc": proc.returncode,
    }
    print(f"[{label}] {kind}={trigger:g}s freeze={row['freeze_applied']}s lag={marker_lag} "
          f"rc={proc.returncode} {row['summary'] or 'not executed'}\n"
          f"    frozen={row['frozen']}\n    red={red}", flush=True)
    for f in failures:
        print(f"    FAIL {f}", flush=True)
    return row


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sim", default="iPhone 16 Pro")
    ap.add_argument("--only-testing", default="MattermostTests")
    ap.add_argument("--derived-data", default=str(DEFAULT_DERIVED))
    ap.add_argument("--offsets", default="0,4,8,12,16,20,24,28")
    ap.add_argument("--lags", default=",".join(LAGS))
    ap.add_argument("--iterations", type=int, default=0,
                    help=">0 switches to per-class mode with -test-iterations N")
    ap.add_argument("--freeze", type=float, default=4.5)
    ap.add_argument("--label-prefix", default="suite-freeze")
    ap.add_argument("--timeout", default="900")
    ap.add_argument("--start-timeout", type=float, default=180)
    ap.add_argument("--stop-on-frozen", action="store_true",
                    help="stop after the first run whose log proves the freeze landed inside")
    args = ap.parse_args()

    triggers = [float(x) for x in (args.lags if args.iterations else args.offsets).split(",") if x.strip()]
    rows = []
    out = REPO / "build/logs" / f"{args.label_prefix}-measure.json"
    for i, t in enumerate(triggers, start=1):
        row = run_one(args, t, i)
        rows.append(row)
        out.write_text(json.dumps(rows, indent=2))
        if args.stop_on_frozen and row["frozen"]:
            print(f"\nfreeze landed inside {args.only_testing}: {row['frozen']}", flush=True)
            break
    union = {}
    for r in rows:
        for n in r["red"]:
            union.setdefault(n, []).append(r["label"])
    print("\n== union of reds ==")
    for n, where in sorted(union.items()):
        print(f"  {n}  ({len(where)}x: {', '.join(where)})")
    print(f"\nwrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
