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
  3. **at rest, while the app is still alive**, the attributed WebContent count must be 0.

Rule 3 is the repair of T46-AV's F5, and the reason for it is worth keeping: the old script took
its "at rest" sample *after* `xcodebuild` exited, i.e. after XCTest had terminated the app. At that
moment a retained `WKWebView` and an ordinary app exit are the same observation — run 1 of the
audit counted one `WebContent` pid that was still alive twelve minutes later with no client app,
run 2 counted zero, and the probe could not tell which had happened (`docs/t46-av-verdict.md`
§F5). So the live suite now holds the app open and idle with nothing presented and prints a marker
pair:

    T46_AT_REST_BEGIN      … 20 s with the native shell on screen  …      T46_AT_REST_END

This script reads the suite's stdout **while it runs**, samples during that window, and judges the
run on those samples. The post-exit number is still printed and reported, but a pid that outlives
its app is reported as an orphan rather than as a leak of this card's webview — the app's own
process is gone, so nothing in the app can be holding a webview.

Every figure printed comes from `ps` (pid + RSS) or from the suite's own output. Nothing is
estimated, and a stage that did not happen is reported as `n/a` rather than as a zero.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import threading
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
    return app_pid_in(processes())

def app_pid_in(table: dict[int, str], name: str = "Mattermost") -> int | None:
    """The app's own process in an existing `ps` table (one scan, not two)."""
    for pid, comm in table.items():
        if comm.endswith("/" + name) or comm == name:
            return pid
    return None


def app_pids_in(table: dict[int, str], name: str = "Mattermost") -> set[int]:
    """Every process named like the app. More than one can exist on this host — a stale Catalyst
    build next to the simulator's app — so callers subtract a baseline instead of taking the first
    match (measured: the host carried a 1h41m-old Catalyst `Mattermost` during T46-AV, and it
    poisoned `app_pid()`'s "is the app alive" answers)."""
    return {pid for pid, comm in table.items()
            if comm.endswith("/" + name) or comm == name}


class Sampler:
    """Samples the attributed WebKit processes while something else runs."""

    def __init__(self, baseline: set[int], interval: float = 0.4,
                 baseline_app_pids: set[int] | None = None) -> None:
        self.baseline = baseline
        self.baseline_app_pids = baseline_app_pids or set()
        self.interval = interval
        self.samples: list[dict] = []
        self._stop = False

    def step(self, note: str) -> dict:
        table = processes()
        mine = {pid for pid in webcontent_pids(table) if pid not in self.baseline}
        rss = {pid: rss_kb(pid) for pid in mine}
        new_app_pids = app_pids_in(table) - self.baseline_app_pids
        sample = {
            "t": round(time.time(), 3),
            "note": note,
            "webcontent": len(mine),
            "webcontent_pids": sorted(mine),
            "webcontent_rss_kb": {str(p): v for p, v in rss.items() if v},
            # The app **under test** — a Mattermost process that was not running before the suite
            # started. Recorded on every sample, not only while attached: the at-rest verdict asks
            # whether the app was still alive at the moment the count was zero.
            "app_pid": min(new_app_pids) if new_app_pids else None,
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
    if payload.get("at_rest_window_seen"):
        print(f"  at rest WC     : {payload['at_rest_webcontent']} while the app was alive and "
              f"idle ({payload['at_rest_samples']} samples)")
        if payload.get("at_rest_orphan_pids"):
            print(f"  orphan WC      : {payload['at_rest_orphan_pids']} seen inside the window "
                  "but still alive after the app exited - excluded (a webview the app retained "
                  "cannot outlive the app)")
    else:
        print("  at rest WC     : n/a (the suite printed no T46_AT_REST_BEGIN window)")
    app_alive = payload.get("final_app_alive")
    final = payload["final_webcontent"]
    if final == 0:
        print(f"  final WC       : 0 after {payload['settle_s']:.0f}s idle")
    elif app_alive:
        print(f"  final WC       : {final} after {payload['settle_s']:.0f}s idle, app still "
              "running - that is a retained process, not an orphan")
    else:
        print(f"  final WC       : {final} after {payload['settle_s']:.0f}s idle, but the app is "
              "gone - reported as orphan(s), not as a retained webview")
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
    if payload.get("at_rest_window_seen"):
        if payload["at_rest_webcontent"] != 0:
            problems.append(f"{payload['at_rest_webcontent']} WebContent process(es) alive while "
                            "the app was idle with no sheet presented")
    elif final != 0 and app_alive:
        # No window was driven by this suite (e.g. `--attach`), and the app is still running: the
        # post-exit count is then a real at-rest count, because the app is there to hold a webview.
        problems.append(f"{final} WebContent process(es) still alive at rest")
    elif final != 0:
        # Nothing is attributed any more: the app is gone, and these pids outlived it. That is an
        # unattributable sample, so it must not PASS — the window in (3) is what makes a PASS mean
        # something (T46-AV F5).
        problems.append(f"{final} WebContent process(es) outlived the app and no at-rest window "
                        "was driven, so the count cannot be attributed to a retained webview")

    print()
    if problems:
        print("RESULT: FAIL - " + "; ".join(problems))
        return 1
    print("RESULT: PASS - no WebContent process outlived the sheet while the app was alive, and "
          "the peak stayed within one presentation")
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


AT_REST_BEGIN = "T46_AT_REST_BEGIN"
AT_REST_END = "T46_AT_REST_END"


class SuiteOutput:
    """Reads the spawned suite's output **as it runs**.

    The at-rest window exists only inside the test (T46_R: the live suite holds the app open and
    idle for 20 s), so the sampler has to know when it is open *while* the suite is running.

    Two sources, because `scripts/qa-test.py` does not echo `xcodebuild` to its own stdout — it
    writes the run to `build/logs/<label>.log`. The test's `print` markers are therefore in that
    file, not in the pipe:

      * the pipe gives the runner's own summary lines (kept for the tail printed at the end);
      * the log file is tailed while it is being written, and its lines carry the markers.

    Measured, not assumed: the first version of this reader watched only the pipe and reported
    "the suite printed no T46_AT_REST_BEGIN window" for a run whose log contained it.
    """

    def __init__(self, stream, log_path: Path | None = None) -> None:
        self._stream = stream
        self._log_path = log_path
        self.lines: list[str] = []
        self.log_lines: list[str] = []
        self.window_open = False
        self.window_seen = False
        self._stop = threading.Event()
        self._threads: list[threading.Thread] = []
        self._offset = 0

    def start(self) -> "SuiteOutput":
        readers = [self._pump_stdout]
        if self._log_path is not None:
            readers.append(self._tail_log)
        for reader in readers:
            thread = threading.Thread(target=reader, daemon=True)
            thread.start()
            self._threads.append(thread)
        return self

    def stop(self) -> None:
        """Stop tailing; drains what is already in the log."""
        self._stop.set()
        for thread in self._threads:
            thread.join(timeout=5)
        self._drain_log()

    def _consider(self, text: str) -> None:
        if AT_REST_BEGIN in text:
            self.window_open = True
            self.window_seen = True
            print(f"[t46] suite printed {AT_REST_BEGIN} - at-rest sampling starts now "
                  "(the app is alive and idle)", flush=True)
        elif AT_REST_END in text:
            self.window_open = False
            print(f"[t46] suite printed {AT_REST_END} - at-rest sampling ends", flush=True)

    def _pump_stdout(self) -> None:
        for line in self._stream:
            text = line.rstrip("\n")
            self.lines.append(text)
            self._consider(text)

    def _drain_log(self) -> None:
        if self._log_path is None or not self._log_path.exists():
            return
        with open(self._log_path, "r", errors="replace") as handle:
            handle.seek(self._offset)
            data = handle.read()
            self._offset += len(data)
        for line in data.splitlines():
            self.log_lines.append(line)
            self._consider(line)
        if len(self.log_lines) > 4000:
            del self.log_lines[:-4000]

    def _tail_log(self) -> None:
        while not self._stop.is_set():
            self._drain_log()
            time.sleep(0.2)
        self._drain_log()

    def tail(self, count: int = 15) -> str:
        for thread in self._threads:
            thread.join(timeout=5)
        return "\n".join(self.lines[-count:] or self.log_lines[-count:])


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
    baseline_table = processes()
    baseline = webcontent_pids(baseline_table)
    baseline_app = app_pids_in(baseline_table)
    started = time.time()
    sampler = Sampler(baseline, interval=args.interval, baseline_app_pids=baseline_app)
    payload: dict = {
        "label": label,
        "mode": "run-test" if args.run_test else "attach",
        "started_at": datetime.now(timezone.utc).isoformat(),
        "baseline_webcontent": len(baseline),
        "baseline_app_pids": sorted(baseline_app),
        "max_peak": args.max_peak,
        "settle_s": args.settle,
        "interval_s": args.interval,
        "samples": [],
        "suite_exit": None,
    }
    print(f"[t46] baseline: {len(baseline)} WebKit WebContent process(es) already running "
          "(excluded from attribution)", flush=True)
    if baseline_app:
        print(f"[t46] baseline: {len(baseline_app)} Mattermost app process(es) already running "
              f"{sorted(baseline_app)} - not the app this run measures", flush=True)

    def note(sample: dict, note_text: str) -> None:
        print(f"[t46] t+{sample['t'] - started:6.1f}s  WebContent(this run)={sample['webcontent']}  "
              f"{note_text}", flush=True)

    proc: subprocess.Popen | None = None
    output: SuiteOutput | None = None
    at_rest: list[dict] = []
    if args.run_test:
        proc = spawn_suite(args.only_testing or [DEFAULT_TEST], label,
                           platform=args.platform, sim=args.sim)
        output = SuiteOutput(proc.stdout,
                             log_path=REPO / "build" / "logs" / f"{label}.log").start() \
            if proc.stdout else None
        while proc.poll() is None:
            in_window = bool(output and output.window_open)
            sample = sampler.step("at-rest (app alive)" if in_window else "run")
            if in_window:
                at_rest.append(sample)
            if not args.quiet:
                note(sample, "at-rest: app alive, nothing presented" if in_window
                     else "suite running")
            time.sleep(args.interval)
        if output:
            output.stop()
        tail = output.tail() if output else ""
        payload["suite_exit"] = proc.returncode
        payload["suite_tail"] = tail
        for line in tail.splitlines():
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

    # Post-exit sample first, because the at-rest verdict needs it: a WebContent process that
    # outlives the app cannot be a webview the app retained (the app's death tears its webviews
    # down), so it is attributed to WebKit as an orphan and excluded from the at-rest count. That
    # is T46-AV §F5's run-1 pid 90703 — alive twelve minutes after its app was gone.
    print(f"[t46] settling {args.settle:.0f}s before the post-exit count", flush=True)
    time.sleep(args.settle)
    final = sampler.step("settle")
    if not args.quiet:
        note(final, "post-exit")
    final_app = app_pids_in(processes()) - baseline_app
    payload["final_app_alive"] = bool(final_app)
    payload["final_webcontent"] = final["webcontent"]
    payload["final_webcontent_pids"] = final["webcontent_pids"]
    orphans: set[int] = set()
    if final["webcontent"] and not final_app:
        orphans = set(final["webcontent_pids"])
        print(f"[t46] {final['webcontent']} WebContent process(es) outlived the app "
              f"({final['webcontent_pids']}): orphan(s) of the app's exit - excluded from the "
              "at-rest attribution", flush=True)

    # The at-rest verdict: the worst count seen while the app was alive, idle and presenting
    # nothing. This is the sample T46-AV could not take (§F5).
    #
    # Primary source is the suite's own window (`T46_AT_REST_BEGIN` … `END`): the test holds the app
    # open with nothing presented for 20 s. If that window was not observed (a runner that buffers
    # its log, a suite that does not drive one), fall back to the external shape of the same fact:
    # the **trailing run** of samples taken after the last presentation came back to zero while the
    # app was still running.
    payload["at_rest_window_seen"] = bool(output and output.window_seen)
    payload["at_rest_orphan_pids"] = sorted(orphans)
    payload["at_rest_samples"] = len(at_rest)
    if at_rest:
        payload["at_rest_mode"] = "suite-window"
        attributed = [len(set(s["webcontent_pids"]) - orphans) for s in at_rest]
        payload["at_rest_webcontent"] = max(attributed)
        payload["at_rest_webcontent_pids"] = sorted({pid for s in at_rest
                                                    for pid in s["webcontent_pids"]
                                                    if pid not in orphans})
        worst = max(at_rest, key=lambda s: len(set(s["webcontent_pids"]) - orphans))
        print(f"[t46] at-rest worst sample: {max(attributed)} attributed WebContent process(es) "
              f"at t+{worst['t'] - started:.1f}s "
              f"(raw pids {worst['webcontent_pids']}, orphans excluded {sorted(orphans)})",
              flush=True)
    else:
        tail_run: list[dict] = []
        for sample in reversed(sampler.samples):
            if sample["webcontent"] != 0:
                break
            tail_run.append(sample)
        tail_run.reverse()
        alive = [s for s in tail_run if s.get("app_pid") is not None]
        payload["at_rest_mode"] = "trailing-zero-run"
        payload["at_rest_webcontent"] = 0 if alive else None
        payload["at_rest_webcontent_pids"] = []
        payload["at_rest_samples"] = len(alive)
        print(f"[t46] no suite window; trailing zero-WebContent run: {len(tail_run)} sample(s), "
              f"{len(alive)} of them with the app process alive"
              f" -> at-rest {'0' if alive else 'n/a'}", flush=True)

    payload["peak_webcontent"] = sampler.peak()
    peak_rss = 0
    for sample in sampler.samples:
        total = sum(v for v in sample["webcontent_rss_kb"].values() if v)
        peak_rss = max(peak_rss, total)
    payload["peak_webcontent_rss_mb"] = round(peak_rss / 1024, 1) if peak_rss else None
    last_app = next((s["app_pid"] for s in reversed(sampler.samples) if s.get("app_pid")), None)
    app_rss = rss_kb(last_app) if last_app is not None else None
    payload["app_rss_mb"] = round(app_rss / 1024, 1) if app_rss else None
    payload["duration_s"] = round(time.time() - started, 1)
    payload["samples"] = sampler.samples
    path = write_report(payload, label)
    print(f"[t46] report: {path}", flush=True)
    return summarise(payload)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
