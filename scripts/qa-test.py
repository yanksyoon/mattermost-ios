#!/usr/bin/env python3
"""qa-test.py - the guarded test runner for this repo.

Why this exists (T14b): `xcodebuild test` against the app-hosted unit target used to *hang
forever* whenever a test failed. The failure is recorded by XCTest, XCTest then symbolizes the
failure source location **in-process**, CoreSymbolication opens the object files listed in the
binary's debug map -- and when the build products live inside a TCC-protected folder
(~/Documents, which is where this repo lives), sandboxd asks tccd for file access on behalf of
`com.mattermost.ios`; the open() blocks until that consent is answered, which never happens in a
non-interactive run. The log stops at `Test Case '...' started.` and looks exactly like a
deadlock in product code.

Two things this runner does about it:

  1. It puts derived data *outside* the TCC-protected folders by default
     (~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa) and refuses to run when pointed at
     one, so a failing test reports instead of wedging.
  2. It watches the run: if output stops for --stall-timeout seconds while tests are running it
     samples the test host, kills the run and exits non-zero with the diagnostic -- a wedge can
     never again look like "still running".

Usage:
  scripts/qa-test.py                        # whole scheme on the iOS simulator, all tests
  scripts/qa-test.py --only-testing MattermostTests/WebViewStoreTests
  scripts/qa-test.py --platform mac         # Mac Catalyst (also -only-testing:MattermostTests)
  scripts/qa-test.py --self-test            # break-proof: prove a failing test reports

Exit codes: 0 PASS, 1 test failure, 2 build/usage error, 124 wedged (stall/total timeout).
"""
from __future__ import annotations

import argparse
import datetime as _dt
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_DERIVED = Path.home() / "Library/Developer/Xcode/DerivedData/mattermost-ios-qa"
DEFAULT_SIM = "iPhone 16 Pro"
TCC_PROTECTED = [Path.home() / "Documents", Path.home() / "Desktop", Path.home() / "Downloads"]


def log(msg: str) -> None:
    print(f"[qa-test] {msg}", flush=True)


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def tcc_guard(derived: Path, allow: bool) -> None:
    """Refuse a derived-data path inside a TCC-protected folder (that is the wedge trigger)."""
    resolved = derived.expanduser().resolve()
    for protected in TCC_PROTECTED:
        try:
            resolved.relative_to(protected)
        except ValueError:
            continue
        msg = (
            f"derived data {resolved} is inside {protected}, which macOS TCC protects.\n"
            "  On a *failing* test XCTest symbolizes the failure in-process and opens the debug-map\n"
            "  object files; sandboxd then asks tccd for Documents access on behalf of com.mattermost.ios\n"
            "  and the open() blocks with no prompt in a non-interactive run -> the run looks hung at\n"
            "  'Test Case ... started.' forever.\n"
            f"  Use the default ({DEFAULT_DERIVED}) or another path outside Documents/Desktop/Downloads,\n"
            "  or pass --allow-tcc-unsafe-derived-data if you really mean it."
        )
        if not allow:
            log("REFUSING TO RUN")
            print(msg, file=sys.stderr)
            sys.exit(2)
        log("WARNING: TCC-unsafe derived data requested; a failing test may wedge")
        print(msg, file=sys.stderr)


def find_host(pattern: str) -> list[str]:
    out = run(["pgrep", "-f", pattern]).stdout.split()
    return out


HOST_PATTERNS = {
    # only processes we could have launched: installed sim apps, or our own Catalyst product
    "ios": r"CoreSimulator/Devices/.*/Mattermost\.app/Mattermost$",
    "mac": r"Mattermost\.app/Contents/MacOS/Mattermost$",
}


def app_pids(kind: str) -> list[str]:
    pids = find_host(HOST_PATTERNS[kind])
    keep = []
    for pid in pids:
        try:
            cmd = run(["ps", "-o", "command=", "-p", pid]).stdout
        except Exception:  # noqa: BLE001
            continue
        if "/Applications/Mattermost.app" in cmd:  # the user's desktop app, never ours
            continue
        if kind == "mac" and "Debug-maccatalyst" not in cmd:
            continue
        keep.append(pid)
    return keep


def sample_host(kind: str, outdir: Path, before: set[str]) -> list[Path]:
    """sample() the wedged test host (only pids that appeared with this run)."""
    written = []
    for pid in app_pids(kind):
        if pid in before:
            continue
        target = outdir / f"sample-host-{pid}.txt"
        try:
            subprocess.run(["sample", pid, "2", "-file", str(target)], timeout=90,
                           capture_output=True, text=True)
            written.append(target)
            log(f"sampled wedged test host pid={pid} -> {target}")
        except Exception as exc:  # noqa: BLE001
            log(f"could not sample pid={pid}: {exc}")
    return written


def tcc_evidence(since: _dt.datetime) -> str:
    """Pull the tccd lines for this app around the run, the signature of the wedge."""
    start = since.astimezone().strftime("%Y-%m-%d %H:%M:%S")
    try:
        proc = run(["log", "show", "--start", start, "--predicate",
                    'subsystem == "com.apple.TCC"', "--style", "compact"], timeout=180)
    except Exception:  # noqa: BLE001
        return ""
    hits = [ln for ln in proc.stdout.splitlines() if "mattermost.ios" in ln.lower()]
    return "\n".join(hits[:8])


class Runner:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.derived = Path(args.derived_data).expanduser()
        self.log_dir = (REPO / args.log_dir) if not Path(args.log_dir).is_absolute() else Path(args.log_dir)
        self.log_dir.mkdir(parents=True, exist_ok=True)
        stamp = _dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        self.label = args.label or f"{args.platform}-{stamp}"
        self.log = self.log_dir / f"{self.label}.log"
        self.xcresult = self.derived / "TestResults" / f"{self.label}-{uuid.uuid4().hex[:6]}.xcresult"

    # -- command -----------------------------------------------------------
    def destination(self) -> str:
        if self.args.platform == "mac":
            return "platform=macOS,variant=Mac Catalyst"
        return f"platform=iOS Simulator,{self.args.sim}"

    def command(self, only_testing: list[str] | None = None) -> list[str]:
        cmd = ["xcodebuild", "test", "-project", "Mattermost.xcodeproj", "-scheme", "Mattermost",
               "-destination", self.destination(), "-derivedDataPath", str(self.derived),
               "-resultBundlePath", str(self.xcresult)]
        for spec in (only_testing if only_testing is not None else self.args.only_testing or []):
            cmd += ["-only-testing", spec]
        if self.args.platform == "mac" and not (only_testing or self.args.only_testing):
            cmd += ["-only-testing", "MattermostTests"]
        cmd += self.args.extra
        return cmd

    # -- execution ---------------------------------------------------------
    def execute(self, label_suffix: str = "") -> dict:
        cmd = self.command()
        log("run: " + " ".join(cmd))
        started = _dt.datetime.now()
        t0 = time.time()
        before = set(app_pids(self.args.platform))
        with open(self.log, "wb") as fh:
            proc = subprocess.Popen(cmd, cwd=REPO, stdout=fh, stderr=subprocess.STDOUT,
                                    start_new_session=True)
            result = self._watch(proc, t0, before)
        result.update(self._summarize(started, result["status"]))
        result["log"] = str(self.log)
        result["xcresult"] = str(self.xcresult)
        result["label"] = self.label + label_suffix
        return result

    def _watch(self, proc: subprocess.Popen, t0: float, before: set[str]) -> dict:
        last_size = -1
        last_growth = time.time()
        tests_started = False
        finished_marker = False
        scan_from = 0
        while True:
            rc = proc.poll()
            if rc is not None:
                return {"status": "finished", "rc": rc, "elapsed": time.time() - t0}
            time.sleep(2.0)
            elapsed = time.time() - t0
            try:
                size = self.log.stat().st_size
            except FileNotFoundError:
                size = 0
            if size != last_size:
                last_size, last_growth = size, time.time()
            # incremental scan for the phase markers (never re-reads the whole log)
            try:
                with open(self.log, "rb") as fh:
                    fh.seek(scan_from)
                    chunk = fh.read(4_000_000)
                    scan_from = max(0, fh.tell() - 64)  # 64-byte overlap: markers can straddle reads
            except FileNotFoundError:
                chunk = b""
            if chunk:
                if b"Test Case '" in chunk or b"Test Suite 'All tests'" in chunk:
                    tests_started = True
                if b"** TEST FAILED **" in chunk or b"** TEST SUCCEEDED **" in chunk:
                    finished_marker = True
            if elapsed > self.args.timeout:
                return self._kill(proc, t0, f"total timeout {self.args.timeout}s", before)
            # only call it a wedge while tests are running and the verdict is not in yet:
            # xcodebuild can sit silently for a while assembling the .xcresult afterwards
            if (tests_started and not finished_marker
                    and time.time() - last_growth > self.args.stall_timeout):
                return self._kill(proc, t0, f"no output for {self.args.stall_timeout}s while testing", before)

    def _kill(self, proc: subprocess.Popen, t0: float, why: str, before: set[str]) -> dict:
        log(f"WEDGED: {why}; sampling the test host before killing")
        samples = sample_host(self.args.platform, self.log_dir, before)
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
        # a killed xcodebuild leaves the host running; make sure we clean up our own host only
        for pid in app_pids(self.args.platform):
            if pid in before:
                continue
            try:
                os.kill(int(pid), signal.SIGKILL)
            except (ProcessLookupError, ValueError):
                pass
        return {"status": "wedged", "rc": 124, "elapsed": time.time() - t0, "why": why,
                "samples": [str(s) for s in samples]}

    def _summarize(self, started: _dt.datetime, status: str = "finished") -> dict:
        text = self.log.read_text(errors="replace") if self.log.exists() else ""
        failed = re.findall(r"^\S+\.swift:\d+: error: .*$", text, re.M)
        cases_failed = re.findall(r"Test Case '-\[[\w.]+ ([\w]+)\]' failed", text)
        executed = re.findall(r"Executed (\d+) tests?, with (\d+) tests? skipped and (\d+) failures?", text)
        if executed:
            run_counts = executed[-1]
        else:
            # "Executed 1 test, with 1 failure (0 unexpected) in 0.099 (0.100) seconds"
            short = re.findall(r"Executed (\d+) tests?, with (\d+) failures? \(", text)
            run_counts = (short[-1][0], "0", short[-1][1]) if short else None
        success = "** TEST SUCCEEDED **" in text
        failed_marker = "** TEST FAILED **" in text
        out = {
            "success": success and not failed_marker,
            "failed_marker": failed_marker,
            "failed_cases": cases_failed,
            "failure_lines": failed[:20],
            "executed": run_counts,
        }
        if status == "wedged":
            out["tcc"] = tcc_evidence(started)
            out["diagnosis"] = self._diagnose()
        return out

    def _diagnose(self) -> str:
        hint = (
            "The run produced no output while a test was executing. Most likely XCTest is stuck "
            "symbolizing the failure in-process (XCTestCase recordIssue -> XCTSourceCodeFrame -> "
            "CSSymbolOwnerCache -> open). If the sampled stack shows CSSymbolOwner / open, check the "
            "derived-data path: build products under ~/Documents make the test host's open() block on "
            "a TCC consent that never arrives."
        )
        for path in self.log_dir.glob("sample-host-*.txt"):
            try:
                body = path.read_text(errors="replace")
            except OSError:
                continue
            if "CSSymbolOwner" in body or "CoreSymbolication" in body:
                return hint + f" (confirmed in {path.name}: CoreSymbolication frames present)"
        return hint


def report(res: dict) -> None:
    print()
    print("=" * 72)
    print(f"run        : {res['label']}")
    print(f"outcome    : {res['status']} (xcodebuild rc={res['rc']}, {res['elapsed']:.0f}s)")
    if res.get("executed"):
        total, skipped, failures = res["executed"]
        print(f"tests      : {total} run, {skipped} skipped, {failures} failed")
    if res.get("failed_cases"):
        print(f"failed     : {', '.join(sorted(set(res['failed_cases'])))}")
    for line in res.get("failure_lines", []):
        print(f"  {line}")
    if res.get("why"):
        print(f"wedge      : {res['why']}")
    if res.get("samples"):
        print(f"samples    : {', '.join(res['samples'])}")
    if res.get("diagnosis"):
        print(f"diagnosis  : {res['diagnosis']}")
    if res.get("tcc"):
        print("tcc        : access request attributed to com.mattermost.ios during the run:")
        for line in res["tcc"].splitlines()[:4]:
            print(f"  {line[:200]}")
    print(f"log        : {res['log']}")
    print(f"xcresult   : {res['xcresult']}")
    if res["status"] == "wedged":
        print("RESULT: WEDGED")
    elif res["success"] and res["rc"] == 0:
        print("RESULT: PASS")
    elif res["failed_marker"] or res["failed_cases"] or res["rc"] != 0:
        print("RESULT: FAIL")
    else:
        print("RESULT: ERROR")


# -- self test -------------------------------------------------------------
CANARY = """
    /// Deliberate failure injected by `scripts/qa-test.py --self-test`; always reverted.
    func testQAHarnessDeliberateFailure() {
        XCTAssertEqual(1, 2, "qa-test self-test: this failure must be reported, not hang")
    }
"""
CANARY_FILE = REPO / "MattermostTests/WebViewStoreTests.swift"


def inject_canary() -> str:
    original = CANARY_FILE.read_text()
    if "testQAHarnessDeliberateFailure" in original:
        sys.exit("self-test: canary already present in the file; aborting")
    idx = original.rstrip().rfind("\n}")
    if idx == -1:
        sys.exit("self-test: could not find the class' closing brace")
    patched = original[:idx] + "\n" + CANARY + original[idx:]
    CANARY_FILE.write_text(patched)
    return original


def self_test(args: argparse.Namespace) -> int:
    dirty = run(["git", "diff", "--quiet", "--", str(CANARY_FILE.relative_to(REPO))], cwd=REPO).returncode
    if dirty != 0:
        log(f"self-test: {CANARY_FILE.name} has uncommitted changes; refusing to touch it")
        return 2
    original = inject_canary()
    try:
        log("self-test: injected a deliberately failing test")
        runner = Runner(args)
        runner.args.only_testing = []  # replaced below
        runner.args.label = f"{runner.label}-selftest"
        runner.log = runner.log_dir / f"{runner.args.label}.log"
        cmd = runner.command(only_testing=["MattermostTests/WebViewStoreTests/testQAHarnessDeliberateFailure"])
        log("run: " + " ".join(cmd))
        started = _dt.datetime.now()
        t0 = time.time()
        before = set(app_pids(runner.args.platform))
        with open(runner.log, "wb") as fh:
            proc = subprocess.Popen(cmd, cwd=REPO, stdout=fh, stderr=subprocess.STDOUT,
                                    start_new_session=True)
            result = runner._watch(proc, t0, before)
        result.update(runner._summarize(started, result["status"]))
        result["log"], result["xcresult"], result["label"] = str(runner.log), str(runner.xcresult), runner.args.label
        report(result)

        checks = {
            "reported a source-located failure": any(".swift:" in ln and "error:" in ln
                                                    for ln in result["failure_lines"]),
            "printed ** TEST FAILED **": result["failed_marker"],
            "exited non-zero": result["rc"] != 0,
            "did not wedge": result["status"] == "finished",
        }
        print()
        for name, ok in checks.items():
            print(f"  [{'PASS' if ok else 'FAIL'}] {name}")
        good = all(checks.values())
        print("SELF-TEST: " + ("PASS - a failing test reports and fails the build" if good else "FAIL"))
        return 0 if good else 1
    finally:
        CANARY_FILE.write_text(original)
        log("self-test: reverted the injected canary")


def main() -> int:
    ap = argparse.ArgumentParser(description="Guarded xcodebuild test runner (see module docstring).")
    ap.add_argument("--platform", choices=["ios", "mac"], default="ios")
    ap.add_argument("--sim", default=DEFAULT_SIM, help='iOS simulator spec, e.g. "id=81A7..." or "name=iPhone 16 Pro"')
    ap.add_argument("--only-testing", action="append", default=[], metavar="SPEC")
    ap.add_argument("--derived-data", default=str(DEFAULT_DERIVED))
    ap.add_argument("--log-dir", default="build/logs")
    ap.add_argument("--label", default="")
    ap.add_argument("--timeout", type=int, default=2400, help="hard wall clock limit (s)")
    ap.add_argument("--stall-timeout", type=int, default=240, help="kill when test output stops for this long (s)")
    ap.add_argument("--allow-tcc-unsafe-derived-data", action="store_true")
    ap.add_argument("--self-test", action="store_true", help="break-proof: prove a failing test reports")
    ap.add_argument("extra", nargs="*", help="extra xcodebuild args (after --)")
    args = ap.parse_args()

    if "=" not in args.sim:
        args.sim = f"id={args.sim}" if re.fullmatch(r"[0-9A-Fa-f-]{36}", args.sim) else f"name={args.sim}"
    tcc_guard(Path(args.derived_data), args.allow_tcc_unsafe_derived_data)
    if shutil.which("xcodebuild") is None:
        log("xcodebuild not found")
        return 2
    if args.self_test:
        return self_test(args)
    res = Runner(args).execute()
    report(res)
    if res["status"] == "wedged":
        return 124
    return 0 if (res["success"] and res["rc"] == 0) else 1


if __name__ == "__main__":
    sys.exit(main())
