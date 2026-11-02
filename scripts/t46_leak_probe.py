#!/usr/bin/env python3
"""T46 — the perf probe for the permanent-web fallback: does closing it give the memory back?

The card's third acceptance criterion is "the fallback can be torn down and recreated without
leaking a webview (verify with the perf probe; a leaked webview defeats the memory goal)". The unit
suite (`T46WebFallbackTests.testTwentyFallbacksLeaveNoWebViewAlive`) proves the **object** lifetime:
twenty created-and-closed fallbacks leave twenty deallocated `WKWebView`s. This probe measures the
thing the memory goal is actually about — the **processes**: every webview a WKWebView mounts lives
in a WebKit WebContent process, and a leaked webview keeps one alive, which is where the hundreds of
megabytes of Path A came from (`docs/perf/README.md`).

Attribution rule (the one judgement this script makes, same rule as `scripts/perf_collect.py`): a
WebKit process belongs to this run iff its pid was not present in the snapshot taken just before the
app launched. Anything already running belongs to another app (Safari, a previous run) and is
excluded rather than silently attributed.

Two modes:

    # the card's own measurement: run the live twenty-cycle test and sample the app's WebKit children
    TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \\
    TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \\
    TEST_RUNNER_MM_AUTH_PASSWORD=... \\
    python3 scripts/t46_leak_probe.py --run-test --sim id=<simulator udid>

The live suite is a **UI** suite, so it runs on the iOS simulator (`--platform ios`, the default);
Mac Catalyst cannot host `MattermostUITests` (its deployment target is newer than this host's macOS,
measured in `build/logs/t46-leak.log`). `--sim` is forwarded to `scripts/qa-test.py` unchanged.

    # sample an app you launched yourself (e.g. by hand, for a screenshot) for N seconds
    python3 scripts/t46_leak_probe.py --attach --seconds 120

Exit codes: 0 PASS, 1 FAIL (leak or run failure), 2 usage/environment problem.

The verdict, stated up front so a reader can disagree with it:

  1. the spawned suite must go green (only when `--run-test`);
  2. **peak** attributed WebContent processes must stay at or below `--max-peak` (default 4). Not
     zero: WebKit runs a process pool, so a fresh presentation can overlap the previous one's exit.
     What must not happen is growth with the cycle count — a leak of one process per cycle reaches
     20, and this number is printed on every sample line so growth is visible, not inferred;
  3. **final** attributed WebContent processes must be 0 once the app is idle for `--settle`
     seconds. That is the leak test: WebKit releases a process when its last webview is gone.

Every figure printed comes from `ps` (pid + RSS) or from the suite's own output. Nothing is
estimated, and a stage that did not happen is reported as `n/a` rather than as a zero.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WEBCONTENT = "com.apple.WebKit.WebContent"
DEFAULT_TEST = "MattermostUITests/T46WebFallbackUITests/testTwentyOpenCloseCyclesEachRender"


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def processes() -> dict[int, str]:
    """pid -> executable path, from the kernel's own table."""
    out = run(["ps", "-axo", "pid=,comm="]).stdout
    table: dict[int, str] = {}
    for line in out.splitlines():
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        try:
            table[int(parts[0])] = parts[1].strip()
        except ValueError:
            continue
    return table


def webcontent_pids(table: dict[int, str] | None = None) -> set[int]:
    table = table if table is not None else processes()
    return {pid for pid, comm in table.items() if WEBCONTENT in comm}


def rss_kb(pid: int) -> int | None:
    """Resident set size in KiB, or None when the pid is already gone."""
    out = run(["ps", "-o", "rss=", "-p", str(pid)]).stdout.strip()
    if not out:
        return None
    try:
        return int(out)
    except ValueError:
        return None


def app_pid(name: str = "Mattermost") -> int | None:
    for pid, comm in processes().items():
        if comm.endswith("/" + name) or comm == name:
            return pid
    return None


class Sampler:
    """Samples the attributed WebKit processes while something else runs."""

    def __init__(self, baseline: set[int], interval: float = 0.4) -> None:
        self.baseline = baseline
        self.interval = interval
        self.samples: list[dict] = []
        self._stop = False

    def step(self, note: str) -> dict:
        table = processes()
        mine = {pid for pid in webcontent_pids(table) if pid not in self.baseline}
        rss = {pid: rss_kb(pid) for pid in mine}
        sample = {
            "t": round(time.time(), 3),
            "note": note,
            "webcontent": len(mine),
            "webcontent_pids": sorted(mine),
            "webcontent_rss_kb": {str(p): v for p, v in rss.items() if v},
            "app_pid": app_pid() if note == "attach" else None,
        }
        self.samples.append(sample)
        return sample

    def peak(self) -> int:
        return max((s["webcontent"] for s in self.samples), default=0)


def write_report(payload: dict, label: str) -> Path:
    out = REPO / "build/t46-leak"
    out.mkdir(parents=True, exist_ok=True)
    path = out / f"{label}.json"
    path.write_text(json.dumps(payload, indent=2))
    return path


def summarise(payload: dict) -> int:
    """Print the verdict and return the exit code."""
    print()
    print("T46 web-fallback leak probe")
    print(f"  run            : {payload.get('label')} ({payload.get('mode')})")
    if payload.get("suite_exit") is not None:
        print(f"  suite exit     : {payload['suite_exit']}")
    print(f"  samples        : {len(payload['samples'])} over {payload['duration_s']:.1f}s")
    print(f"  baseline WC    : {payload['baseline_webcontent']} WebKit WebContent process(es) "
          "before launch (excluded)")
    print(f"  peak WC        : {payload['peak_webcontent']} "
          f"(limit {payload['max_peak']})")
    print(f"  final WC       : {payload['final_webcontent']} after {payload['settle_s']:.0f}s idle")
    if payload.get("peak_webcontent_rss_mb") is not None:
        print(f"  peak WC RSS    : {payload['peak_webcontent_rss_mb']} MB (sum of this run's "
              "WebContent processes)")
    if payload.get("app_rss_mb") is not None:
        print(f"  app RSS        : {payload['app_rss_mb']} MB (last sample)")
    # The growth check: a leak of one process per presentation is what this exists to catch.
    counts = [s["webcontent"] for s in payload["samples"]]
    if counts:
        print(f"  WC timeline    : {counts[0]} -> {max(counts)} -> {counts[-1]} "
              f"(min {min(counts)}, max {max(counts)})")

    problems = []
    if payload.get("suite_exit") not in (None, 0):
        problems.append(f"the live suite exited {payload['suite_exit']}")
    if payload["peak_webcontent"] > payload["max_peak"]:
        problems.append(f"peak WebContent {payload['peak_webcontent']} > {payload['max_peak']}")
    if payload["final_webcontent"] != 0:
        problems.append(f"{payload['final_webcontent']} WebContent process(es) still alive at rest")

    print()
    if problems:
        print("RESULT: FAIL - " + "; ".join(problems))
        return 1
    print("RESULT: PASS - every fallback webview's WebContent process is gone once the sheet "
          "closed, and the peak stayed within one presentation")
    return 0


def spawn_suite(only_testing: list[str], label: str, platform: str = "ios",
                sim: str | None = None) -> subprocess.Popen:
    cmd = [sys.executable, str(REPO / "scripts/qa-test.py"),
           "--platform", platform]
    if sim:
        cmd += ["--sim", sim]
    cmd += ["--label", label, "--log-dir", "build/logs"]
    for spec in only_testing:
        cmd += ["--only-testing", spec]
    print(f"[t46] {' '.join(cmd)}", flush=True)
    return subprocess.Popen(cmd, cwd=str(REPO), env=os.environ.copy(),
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--run-test", action="store_true",
                    help="spawn scripts/qa-test.py and sample alongside it")
    ap.add_argument("--attach", action="store_true",
                    help="sample a running app for --seconds (no test is spawned)")
    ap.add_argument("--only-testing", action="append", default=[],
                    help=f"suite to run (default {DEFAULT_TEST})")
    ap.add_argument("--platform", choices=["ios", "mac"], default="ios",
                    help="xcodebuild destination (default ios: the live suite is a UI suite and "
                         "cannot run on Mac Catalyst)")
    ap.add_argument("--sim", default=None,
                    help='iOS simulator spec passed to qa-test.py, e.g. "id=81A7F251-…"')
    ap.add_argument("--seconds", type=float, default=120.0, help="--attach sampling window")
    ap.add_argument("--interval", type=float, default=0.4, help="sample period (s)")
    ap.add_argument("--settle", type=float, default=15.0,
                    help="idle window after the run before the final count (s)")
    ap.add_argument("--max-peak", type=int, default=4,
                    help="ceiling for concurrently attributed WebContent processes")
    ap.add_argument("--label", default="", help="report label (default: utc timestamp)")
    ap.add_argument("--quiet", action="store_true", help="no per-sample lines")
    args = ap.parse_args(argv)

    if not (args.run_test or args.attach):
        print(__doc__)
        return 2

    label = args.label or datetime.now(timezone.utc).strftime("t46-leak-%Y%m%dT%H%M%SZ")
    baseline = webcontent_pids()
    started = time.time()
    sampler = Sampler(baseline, interval=args.interval)
    payload: dict = {
        "label": label,
        "mode": "run-test" if args.run_test else "attach",
        "started_at": datetime.now(timezone.utc).isoformat(),
        "baseline_webcontent": len(baseline),
        "max_peak": args.max_peak,
        "settle_s": args.settle,
        "interval_s": args.interval,
        "samples": [],
        "suite_exit": None,
    }
    print(f"[t46] baseline: {len(baseline)} WebKit WebContent process(es) already running "
          "(excluded from attribution)", flush=True)

    def note(sample: dict, note_text: str) -> None:
        print(f"[t46] t+{sample['t'] - started:6.1f}s  WebContent(this run)={sample['webcontent']}  "
              f"{note_text}", flush=True)

    proc: subprocess.Popen | None = None
    if args.run_test:
        proc = spawn_suite(args.only_testing or [DEFAULT_TEST], label,
                           platform=args.platform, sim=args.sim)
        while proc.poll() is None:
            sample = sampler.step("run")
            if not args.quiet:
                note(sample, "suite running")
            time.sleep(args.interval)
        output = proc.stdout.read() if proc.stdout else ""
        payload["suite_exit"] = proc.returncode
        payload["suite_tail"] = "\n".join(output.strip().splitlines()[-15:])
        for line in payload["suite_tail"].splitlines():
            print(f"[suite] {line}", flush=True)
        if proc.returncode != 0:
            print(f"[t46] suite exited {proc.returncode}; the leak verdict is reported anyway, "
                  "but a red suite cannot PASS the card", flush=True)
    else:
        deadline = started + args.seconds
        while time.time() < deadline:
            sample = sampler.step("attach")
            if not args.quiet:
                note(sample, "attached")
            time.sleep(args.interval)

    # The decisive sample: nothing is being driven any more, so anything still alive is retained.
    print(f"[t46] settling {args.settle:.0f}s before the final count", flush=True)
    time.sleep(args.settle)
    final = sampler.step("settle")
    if not args.quiet:
        note(final, "at rest")
    payload["final_webcontent"] = final["webcontent"]
    payload["final_webcontent_pids"] = final["webcontent_pids"]
    payload["peak_webcontent"] = sampler.peak()
    peak_rss = 0
    for sample in sampler.samples:
        total = sum(v for v in sample["webcontent_rss_kb"].values() if v)
        peak_rss = max(peak_rss, total)
    payload["peak_webcontent_rss_mb"] = round(peak_rss / 1024, 1) if peak_rss else None
    pid = app_pid()
    app_rss = rss_kb(pid) if pid is not None else None
    payload["app_rss_mb"] = round(app_rss / 1024, 1) if app_rss else None
    payload["duration_s"] = round(time.time() - started, 1)
    payload["samples"] = sampler.samples
    path = write_report(payload, label)
    print(f"[t46] report: {path}", flush=True)
    return summarise(payload)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
