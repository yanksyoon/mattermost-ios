#!/usr/bin/env python3
"""Two-subject performance harness: the native Catalyst client vs the official Electron client.

Subjects (fixed by the owner's ask, not by this script):

    native    /Applications/Mattermost(ios).app    Mac Catalyst, ad-hoc signed
    electron  /Applications/Mattermost.app         official Mattermost Desktop (Electron)

Reuse, not replacement: the process table, the WebKit-helper attribution rule and the kernel
`footprint` call come from ``scripts/perf_collect.py`` (imported below). What is new here is the
two-subject orchestration on top of that sampler:

  * process-tree attribution    — RSS is summed over the app's whole tree (Electron spawns
    Renderer/GPU/Utility helpers; Catalyst's WebKit helpers are *not* children, so they are
    attributed with perf_collect's "pid absent from the pre-launch baseline" rule and deduped),
  * windowed CPU                — Δ(cumulative CPU time from `ps -o time=`) per sample, so the
    mean and p95 are measured over the window instead of read off `ps`'s lifetime average,
  * launch timing               — launch → process visible (pgrep) and launch → first window
    (System Events window count), three runs, median. "To process alive" is honest; "to
    interactive" is not measurable from outside the app and is not claimed,
  * energy                      — `top -stats power` summed over the tree, or an explicit
    "not available" row,
  * steady-state growth         — RSS after a long idle window, so a leak that a two-minute
    window hides becomes visible,
  * the fairness preflight      — same workspace, signed in, same channel asserted, screen
    unlocked, both clients quit before the session starts. A run that cannot satisfy these is
    BLOCKED and says so, in the artefacts, instead of measuring a login screen.

Nothing in the emitted table is typed in: every number comes from the raw CSV this script writes,
and the ratios are computed from it. `report` re-renders the markdown from an existing CSV without
re-measuring.

Usage
-----
    scripts/perf_compare.py preflight                      # checks only, exit 66 if not measurable
    scripts/perf_compare.py run                           # full session (≈35 min), writes artefacts
    scripts/perf_compare.py run --idle 30 --active 15 --steady 60   # short smoke of the pipeline
    scripts/perf_compare.py selftest                       # exercises the sampler on a dummy tree
    scripts/perf_compare.py report --csv ... --md ...      # re-render from raw numbers

Exit codes: 0 measured, 64 bad arguments, 65 a metric could not be taken, 66 run blocked
(subjects not signed in to the same workspace / screen locked / channel not asserted).
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import plistlib
import re
import shutil
import sqlite3
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass, field
from urllib.parse import urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import perf_collect  # noqa: E402  — the existing sampler this harness builds on

DEFAULT_CSV = os.path.join(REPO, "docs", "perf", "2026-11-05.csv")
DEFAULT_MD = os.path.join(REPO, "docs", "perf", "2026-11-05-native-vs-electron.md")
RUNS_ROOT = os.path.join(REPO, "docs", "perf", "runs")
README_PATH = os.path.join(REPO, "README.md")

SUBJECTS = {
    "native": {
        "label": "native (Catalyst)",
        "bundle": "/Applications/Mattermost(ios).app",
        "bundle_id": "com.mattermost.ios",
    },
    "electron": {
        "label": "electron (official desktop)",
        "bundle": "/Applications/Mattermost.app",
        "bundle_id": "Mattermost.Desktop",
    },
}
ORDER = ["native", "electron"]              # fixed order for both subjects, same window each

# Electron profile discovery: the shipped build is sandboxed, so its config lives in the
# container; a non-sandboxed build keeps the same files under ~/Library/Application Support.
ELECTRON_PROFILES = [
    os.path.expanduser(
        "~/Library/Containers/Mattermost.Desktop/Data/Library/Application Support/Mattermost"),
    os.path.expanduser("~/Library/Application Support/Mattermost"),
]

CPU_TIME_RE = re.compile(r"^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)$")
START_MARKER = "<!-- perf-compare:start -->"
END_MARKER = "<!-- perf-compare:end -->"


# ------------------------------------------------------------------------------------- helpers

def log(msg: str) -> None:
    print(f"[perf-compare {time.strftime('%H:%M:%S')}] {msg}", flush=True)


def run(cmd: list[str], timeout: float = 60) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def norm_url(url: str) -> str:
    """Compare workspaces without caring about trailing slash, scheme case or a path slash."""
    if not url:
        return ""
    parts = urlsplit(url.strip())
    scheme = (parts.scheme or "https").lower()
    host = (parts.hostname or "").lower()
    port = f":{parts.port}" if parts.port else ""
    path = parts.path.rstrip("/")
    return f"{scheme}://{host}{port}{path}"


def median(values: list) -> float | None:
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def p95(values: list) -> float | None:
    """Nearest-rank p95 over the sampled values (no interpolation, no invented smoothness)."""
    values = sorted(v for v in values if v is not None)
    if not values:
        return None
    idx = min(len(values) - 1, int(round(0.95 * (len(values) - 1))))
    return values[idx]


def mb(value: float | None) -> str:
    return "—" if value is None else f"{value / 1e6:.1f} MB"


def parse_cpu_time(text: str) -> float | None:
    """`ps -o time=` → seconds. Formats: `ss.cc`, `mm:ss.cc`, `hh:mm:ss.cc`, `dd-hh:mm:ss.cc`."""
    text = text.strip()
    if not text:
        return None
    days = 0
    if "-" in text:
        day_part, text = text.split("-", 1)
        days = int(day_part)
    m = CPU_TIME_RE.match(text)
    if not m:
        return None
    d, h, mi, s = m.groups()
    return (int(d or days) * 86400) + int(h or 0) * 3600 + int(mi) * 60 + float(s)


def cpu_times(pids: list[int]) -> dict[int, float]:
    """Cumulative CPU seconds per pid, from one `ps` call."""
    if not pids:
        return {}
    out = run(["ps", "-o", "pid=,time=", "-p", ",".join(str(p) for p in pids)]).stdout
    result: dict[int, float] = {}
    for line in out.splitlines():
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        try:
            pid = int(parts[0])
        except ValueError:
            continue
        seconds = parse_cpu_time(parts[1])
        if seconds is not None:
            result[pid] = seconds
    return result


def thread_counts(pids: list[int]) -> int | None:
    """Threads summed over the pids. `ps -M` prints one line per thread, the pid repeated on
    each; the header is dropped and lines are counted by the pid in the first two columns."""
    if not pids:
        return None
    out = run(["ps", "-M", "-p", ",".join(str(p) for p in pids)]).stdout.splitlines()
    want = {str(p) for p in pids}
    total = 0
    for line in out[1:]:
        tokens = line.split()
        if not tokens:
            continue
        if any(tok in want for tok in tokens[:2]):
            total += 1
    return total


def open_fds(pids: list[int]) -> int | None:
    """Open file descriptors summed over the pids (`lsof -p a,b,c`, header subtracted)."""
    if not pids:
        return None
    out = run(["lsof", "-w", "-p", ",".join(str(p) for p in pids)], timeout=120).stdout
    lines = [line for line in out.splitlines() if line.strip()]
    return max(0, len(lines) - 1)


def power_watts(pids: list[int]) -> float | None:
    """`top -stats power` (macOS exposes it without root on this host). None when unavailable."""
    if not pids:
        return None
    cmd = ["top", "-l", "1", "-stats", "pid,power"]
    for pid in pids:
        cmd += ["-pid", str(pid)]
    proc = run(cmd, timeout=60)
    if proc.returncode != 0 or "POWER" not in proc.stdout:
        return None
    total = 0.0
    seen = False
    for line in proc.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit():
            try:
                total += float(parts[1])
                seen = True
            except ValueError:
                continue
    return round(total, 2) if seen else None


def descendants(root: int, procs: dict[int, dict]) -> set[int]:
    children: dict[int, list[int]] = {}
    for pid, info in procs.items():
        children.setdefault(info["ppid"], []).append(pid)
    out: set[int] = set()
    stack = [root]
    while stack:
        for child in children.get(stack.pop(), []):
            if child not in out:
                out.add(child)
                stack.append(child)
    return out


def screen_locked() -> bool | None:
    """Honest signal from the window server: a locked session cannot show a frontmost window.

    macOS publishes `CGSSessionScreenIsLocked` only while the screen is locked. `IOConsoleLocked`
    is the older key and is read as a fallback; when neither is present the session is unlocked.
    """
    proc = run(["ioreg", "-n", "Root", "-d1", "-a"], timeout=30)
    if proc.returncode != 0 or not proc.stdout:
        return None
    try:
        data = plistlib.loads(proc.stdout.encode())
    except Exception:
        return None
    found: dict[str, bool] = {}

    def walk(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key in ("CGSSessionScreenIsLocked", "IOConsoleLocked"):
                    found[key] = bool(value)
                walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(data)
    if "CGSSessionScreenIsLocked" in found:
        return found["CGSSessionScreenIsLocked"]
    if "IOConsoleLocked" in found:
        return found["IOConsoleLocked"]
    return False


def power_source() -> str:
    out = run(["pmset", "-g", "ps"], timeout=15).stdout
    for line in out.splitlines():
        if "drawing from" in line:
            return line.strip()
    return "unknown"


def subject_pids(subject: dict) -> list[int]:
    """Pids whose executable is this bundle's binary. Matched on the literal path: a pgrep
    pattern would treat the parentheses in `Mattermost(ios).app` as a regex group."""
    executable = subject["bundle"] + "/Contents/MacOS/"
    pids = []
    for line in run(["ps", "-axo", "pid=,command="]).stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1].startswith(executable):
            try:
                pids.append(int(parts[0]))
            except ValueError:
                continue
    return sorted(pids)


def quit_subject(subject: dict, timeout: float = 20) -> bool:
    """Terminate every process of this subject; never touches any other app."""
    pids = subject_pids(subject)
    if not pids:
        return True
    for pid in pids:
        try:
            os.kill(pid, 15)
        except OSError:
            pass
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not subject_pids(subject):
            return True
        time.sleep(0.25)
    for pid in subject_pids(subject):
        try:
            os.kill(pid, 9)
        except OSError:
            pass
    time.sleep(0.5)
    return not subject_pids(subject)


def window_count(pid: int) -> int | None:
    script = (f'tell application "System Events" to count windows of '
              f'(first process whose unix id is {pid})')
    proc = run(["osascript", "-e", script], timeout=30)
    try:
        return int(proc.stdout.strip())
    except (TypeError, ValueError):
        return None


def window_bounds(pid: int) -> dict | None:
    """Size of the app's front window, so both subjects can be driven in the same window."""
    script = (f'tell application "System Events" to tell (first process whose unix id is {pid}) '
              f'to get {{position, size}} of window 1')
    proc = run(["osascript", "-e", script], timeout=30)
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    try:
        left, top, width, height = [int(v) for v in proc.stdout.strip().split(", ")]
    except ValueError:
        return None
    return {"x": left, "y": top, "width": width, "height": height}


def set_window_bounds(pid: int, width: int, height: int) -> bool:
    script = (f'tell application "System Events" to tell (first process whose unix id is {pid}) '
              f'to set size of window 1 to {{{width}, {height}}}')
    return run(["osascript", "-e", script], timeout=30).returncode == 0


def bring_frontmost(pid: int) -> bool:
    script = (f'tell application "System Events" to set frontmost of '
              f'(first process whose unix id is {pid}) to true')
    return run(["osascript", "-e", script], timeout=30).returncode == 0


def bundle_version(bundle: str) -> tuple[str, str] | tuple[None, None]:
    info = os.path.join(bundle, "Contents", "Info.plist")
    if not os.path.exists(info):
        return None, None
    proc = run(["plutil", "-p", info], timeout=30)
    if proc.returncode != 0:
        return None, None
    version = build = None
    for line in proc.stdout.splitlines():
        if '"CFBundleShortVersionString"' in line:
            version = line.split("=>", 1)[1].strip().strip('"')
        elif '"CFBundleVersion"' in line:
            build = line.split("=>", 1)[1].strip().strip('"')
    return version, build


# ------------------------------------------------------------------------ subject configuration

def native_servers() -> list[dict]:
    """The native app's persisted server list (`defaults mm.servers`, JSON inside a data blob)."""
    proc = run(["defaults", "export", "com.mattermost.ios", "-"], timeout=30)
    if proc.returncode != 0 or not proc.stdout:
        return []
    try:
        prefs = plistlib.loads(proc.stdout.encode())
    except Exception:
        return []
    blob = prefs.get("mm.servers")
    if isinstance(blob, bytes):
        try:
            return json.loads(blob.decode())
        except Exception:
            return []
    if isinstance(blob, list):
        return blob
    return []


def native_active_server() -> dict | None:
    servers = native_servers()
    if not servers:
        return None
    active = None
    proc = run(["defaults", "export", "com.mattermost.ios", "-"], timeout=30)
    if proc.returncode == 0 and proc.stdout:
        try:
            prefs = plistlib.loads(proc.stdout.encode())
            blob = prefs.get("mm.servers.active")
            if isinstance(blob, bytes):
                active = json.loads(blob.decode())
        except Exception:
            active = None
    if active:
        for server in servers:
            if server.get("id") == active:
                return server
    return max(servers, key=lambda s: s.get("lastActiveAt") or 0)


def electron_profile() -> str | None:
    candidates = [p for p in ELECTRON_PROFILES if os.path.exists(os.path.join(p, "config.json"))]
    if not candidates:
        return None
    return max(candidates, key=lambda p: os.path.getmtime(os.path.join(p, "config.json")))


def electron_config() -> dict:
    profile = electron_profile()
    if not profile:
        return {}
    try:
        with open(os.path.join(profile, "config.json")) as fh:
            return json.load(fh)
    except Exception:
        return {}


def electron_cookie_state(host: str) -> dict:
    """Presence and expiry of the session cookies for a host. Values are never read or printed."""
    profile = electron_profile()
    state = {"cookie_db": None, "MMAUTHTOKEN": None, "MMUSERID": None}
    if not profile:
        return state
    for name in ("Cookies", os.path.join("Network", "Cookies")):
        path = os.path.join(profile, name)
        if os.path.exists(path):
            state["cookie_db"] = path
            try:
                con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
                for cookie_name in ("MMAUTHTOKEN", "MMUSERID"):
                    row = con.execute(
                        "select expires_utc from cookies where name=? and "
                        "(host_key=? or host_key=?)",
                        (cookie_name, host, "." + host)).fetchone()
                    if row:
                        expires = row[0]
                        state[cookie_name] = {
                            "session_cookie": expires == 0,
                            "expires_epoch": None if expires == 0
                            else round(expires / 1e6 - 11644473600, 0),
                        }
                con.close()
            except Exception as exc:  # a locked DB is a finding, not a crash
                state["error"] = str(exc)
            break
    return state


# ------------------------------------------------------------------------------------ preflight

@dataclass
class Check:
    name: str
    ok: bool
    blocking: bool
    detail: str


@dataclass
class Preflight:
    host: dict = field(default_factory=dict)
    subjects: dict = field(default_factory=dict)
    checks: list[Check] = field(default_factory=list)
    workspace: str = ""
    channel: str = ""

    @property
    def blocked(self) -> bool:
        return any(c.blocking and not c.ok for c in self.checks)

    def add(self, name: str, ok: bool, detail: str, blocking: bool = True) -> None:
        self.checks.append(Check(name, ok, blocking, detail))

    def blockers(self) -> list[Check]:
        return [c for c in self.checks if c.blocking and not c.ok]

    def as_dict(self) -> dict:
        return {
            "workspace": self.workspace,
            "channel": self.channel,
            "host": self.host,
            "subjects": self.subjects,
            "checks": [c.__dict__ for c in self.checks],
            "blocked": self.blocked,
        }


def preflight(args: argparse.Namespace, require_channel: bool) -> Preflight:
    pf = Preflight(channel=getattr(args, "channel", "") or "")
    pf.host = {
        "model": run(["sysctl", "-n", "hw.model"]).stdout.strip(),
        "os": run(["sw_vers", "-productVersion"]).stdout.strip(),
        "arch": os.uname().machine,
        "cpu_count": os.cpu_count(),
        "power_source": power_source(),
        "measured_at": time.strftime("%Y-%m-%d %H:%M:%S %z"),
    }
    locked = screen_locked()
    pf.add("screen_unlocked", locked is False,
           f"CGSSessionScreenIsLocked={locked}; a locked session cannot show a frontmost window "
           f"and window/first-paint detection returns 0 for every app", blocking=True)

    for key in ORDER:
        subject = SUBJECTS[key]
        info: dict = {"label": subject["label"], "bundle": subject["bundle"],
                      "running_pids": subject_pids(subject)}
        version, build = bundle_version(subject["bundle"])
        info["version"] = version
        info["build"] = build
        pf.add(f"{key}_bundle_present", os.path.isdir(subject["bundle"]),
               f"{subject['bundle']} version={version} build={build}")
        pf.subjects[key] = info

    # --- the native subject's workspace and session
    active = native_active_server()
    if active:
        pf.subjects["native"]["workspace"] = active.get("url")
        pf.subjects["native"]["has_session"] = active.get("hasSession")
        pf.subjects["native"]["server_name"] = active.get("name")
    else:
        pf.subjects["native"]["workspace"] = None
        pf.subjects["native"]["has_session"] = None
    pf.add("native_signed_in", bool(active and active.get("hasSession")),
           "mm.servers hasSession=%r for %r" % (
               pf.subjects["native"].get("has_session"),
               pf.subjects["native"].get("workspace")))

    # --- the electron subject's workspace and session
    config = electron_config()
    electron_servers = [norm_url(s.get("url", "")) for s in config.get("servers", [])]
    pf.subjects["electron"]["workspace"] = None
    pf.subjects["electron"]["servers_configured"] = electron_servers
    workspace = norm_url(getattr(args, "workspace", "") or "")
    if workspace and workspace in electron_servers:
        pf.subjects["electron"]["workspace"] = workspace
    elif electron_servers:
        pf.subjects["electron"]["workspace"] = electron_servers[0]
    cookie_host = urlsplit(workspace or (electron_servers[0] if electron_servers else "")).hostname
    cookie = electron_cookie_state(cookie_host) if cookie_host else {}
    pf.subjects["electron"]["session_cookies"] = cookie
    pf.subjects["electron"]["cookie_db"] = cookie.get("cookie_db")
    token = cookie.get("MMAUTHTOKEN")
    pf.add("electron_signed_in", bool(token),
           f"MMAUTHTOKEN for {cookie_host!r}: "
           + ("absent from the cookie store" if not token
              else f"present (session_cookie={token['session_cookie']}, "
                   f"expires_epoch={token['expires_epoch']})"))

    # --- the shared workspace
    if not workspace:
        workspace = norm_url(pf.subjects["native"].get("workspace") or "")
    pf.workspace = workspace
    native_ws = norm_url(pf.subjects["native"].get("workspace") or "")
    pf.add("same_workspace", bool(workspace) and native_ws == workspace
           and workspace in electron_servers,
           f"native={native_ws or '(none)'} electron={electron_servers or '(none)'} "
           f"requested={workspace or '(none)'}")

    # --- the channel is an operator assertion: neither client exposes "which channel is open"
    #     to an external process without reading its UI. It is recorded, never guessed.
    if require_channel:
        pf.add("channel_asserted", bool(pf.channel),
               f"--channel={pf.channel!r}: the operator asserts both clients sit on it")
    else:
        pf.add("channel_asserted", True, "--channel not required for `preflight`", blocking=False)

    # --- both clients must start the session closed (fresh launch, same minute)
    running = {k: pf.subjects[k]["running_pids"] for k in ORDER if pf.subjects[k]["running_pids"]}
    pf.add("both_quit_before_launch", not running,
           "running now: " + (", ".join(f"{k}={v}" for k, v in running.items()) or "none"),
           blocking=False)
    return pf


# ------------------------------------------------------------------------------------- sampling

class Sampler:
    """Samples one subject's process tree. Attribution is documented in the module docstring."""

    def __init__(self, subject: dict, root_pid: int, baseline_webkit: set[int]):
        self.subject = subject
        self.root_pid = root_pid
        self.baseline_webkit = baseline_webkit
        self.helpers: set[int] = set()
        self.tracked: set[int] = set()
        self.prev_cpu: dict[int, float] = {}
        self.prev_t = None

    def _refresh(self) -> dict[int, dict]:
        procs = perf_collect.list_processes()
        if self.root_pid not in procs:
            return {}
        self.tracked = {self.root_pid} | descendants(self.root_pid, procs)
        for pid, info in procs.items():
            if pid in self.baseline_webkit:
                continue
            if perf_collect.webkit_family(info["comm"]) and pid not in self.tracked:
                self.helpers.add(pid)
        self.helpers = {p for p in self.helpers if p in procs}
        return procs

    def sample(self, want_slow: bool) -> dict:
        procs = self._refresh()
        if not procs:
            return {"alive": False}
        pids = sorted(p for p in (self.tracked | self.helpers) if p in procs)
        rss_app = sum(procs[p]["rss_bytes"] for p in self.tracked if p in procs)
        rss_helpers = sum(procs[p]["rss_bytes"] for p in self.helpers if p in procs)
        t = time.time()
        cpu = cpu_times(pids)
        cpu_total = sum(cpu.values())
        cpu_pct = None
        if self.prev_t is not None and cpu_total >= sum(self.prev_cpu.values()):
            dt = t - self.prev_t
            if dt > 0:
                cpu_pct = round((cpu_total - sum(self.prev_cpu.values())) / dt * 100, 2)
        self.prev_cpu, self.prev_t = cpu, t
        record = {
            "alive": True,
            "t_wall": round(t, 3),
            "pids": pids,
            "rss_total_bytes": rss_app + rss_helpers,
            "rss_app_bytes": rss_app,
            "rss_helpers_bytes": rss_helpers,
            "cpu_pct": cpu_pct,
            "children": max(0, len(self.tracked) - 1),
            "threads": thread_counts(pids),
            "fds": None,
            "power_w": None,
        }
        if want_slow:
            record["fds"] = open_fds(pids)
            record["power_w"] = power_watts(pids)
        return record


def sample_window(sampler: Sampler, seconds: float, interval: float, phase: str,
                  slow_every: int = 10) -> list[dict]:
    rows: list[dict] = []
    started = time.time()
    i = 0
    while time.time() - started < seconds:
        record = sampler.sample(want_slow=(i % slow_every == 0))
        if not record.get("alive"):
            rows.append({"phase": phase, "alive": False, "t_wall": round(time.time(), 3)})
            break
        record["phase"] = phase
        record["sample"] = i
        rows.append(record)
        i += 1
        time.sleep(interval)
    return rows


# ---------------------------------------------------------------------------------- launch phase

def measure_launch(subject: dict, runs: int, timeout: float = 90) -> list[dict]:
    """Launch → process visible, launch → first window. Three runs; medians are computed later.

    Timed with the same stopwatch for both subjects: the clock starts immediately before `open`
    (LaunchServices, i.e. how a user launches it) and stops on the first `pgrep` hit / the first
    non-zero System Events window count.
    """
    results: list[dict] = []
    for index in range(1, runs + 1):
        quit_subject(subject)
        time.sleep(3)                      # let the previous instance's helpers exit
        t0 = time.time()
        proc = run(["open", "-n", subject["bundle"]], timeout=30)
        record = {"phase": "launch", "run": index, "open_rc": proc.returncode,
                  "to_process_ms": None, "to_window_ms": None}
        pid = None
        while time.time() - t0 < timeout:
            pids = subject_pids(subject)
            if pids:
                pid = pids[0]
                record["to_process_ms"] = round((time.time() - t0) * 1000, 0)
                break
            time.sleep(0.02)
        if pid is not None:
            while time.time() - t0 < timeout:
                count = window_count(pid)
                if count:
                    record["to_window_ms"] = round((time.time() - t0) * 1000, 0)
                    break
                time.sleep(0.1)
        record["pid"] = pid
        results.append(record)
        log(f"{subject['label']}: launch #{index} process={record['to_process_ms']} ms "
            f"window={record['to_window_ms']} ms")
    return results


# --------------------------------------------------------------------------------- scroll driver

def build_scroll_helper(run_dir: str) -> str | None:
    """Compile the Quartz scroll driver once per session (same synthetic path for both apps)."""
    source = os.path.join(HERE, "perf_scroll.swift")
    if not os.path.exists(source):
        return None
    out = os.path.join(run_dir, "perf_scroll")
    proc = run(["xcrun", "swiftc", "-O", source, "-o", out], timeout=180)
    return out if proc.returncode == 0 else None


def drive_scroll(helper: str | None, pid: int, seconds: float, interval_ms: int = 120,
                 delta: int = -40) -> dict:
    """Post wheel events to the app's pid for `seconds`. Returns what was actually sent."""
    if not helper:
        return {"events": 0, "delivered": False, "why": "scroll helper missing"}
    events = max(1, int(seconds * 1000 / interval_ms))
    proc = run([helper, str(pid), str(events), str(delta), str(interval_ms)],
               timeout=seconds + 60)
    return {"events": events, "delivered": proc.returncode == 0,
            "stdout": proc.stdout.strip(), "stderr": proc.stderr.strip()[-300:],
            "why": "" if proc.returncode == 0 else f"exit {proc.returncode}"}


# -------------------------------------------------------------------------------------- selftest

def cmd_selftest(args: argparse.Namespace) -> int:
    """Exercise the sampler against a synthetic four-process tree (no GUI, no server needed).

    This proves the parsers and the attribution arithmetic on this host, which a blocked run
    cannot: `sleep` children give a known tree shape, `ps`/`top`/`lsof` give real numbers.
    """
    log("selftest: spawning a synthetic process tree (shell + 3 sleep children)")
    parent = subprocess.Popen(["sh", "-c", "sleep 60 & sleep 60 & sleep 60 & wait"],
                              start_new_session=True)
    try:
        time.sleep(0.6)
        procs = perf_collect.list_processes()
        found = descendants(parent.pid, procs)
        sleeps = {pid for pid, info in procs.items()
                  if info["ppid"] == parent.pid and info["comm"].strip().endswith("sleep")}
        assert len(sleeps) == 3, f"expected 3 sleep children, saw {len(sleeps)}"
        assert sleeps <= found, f"tree walk missed children: {sleeps - found}"
        sampler = Sampler({"label": "selftest", "bundle": "", "bundle_id": ""},
                          parent.pid, set())
        time.sleep(0.5)
        rows = sample_window(sampler, seconds=4, interval=0.5, phase="selftest", slow_every=2)
        live = [r for r in rows if r.get("alive")]
        assert live, "no live samples"
        first, last = live[0], live[-1]
        print(json.dumps({
            "samples": len(live),
            "tree_children_expected": 3, "tree_children_observed": first["children"],
            "rss_total_bytes": last["rss_total_bytes"],
            "threads": last["threads"],
            "fds": last["fds"],
            "power_w": last["power_w"],
            "cpu_pct_samples": [r["cpu_pct"] for r in live if r["cpu_pct"] is not None],
        }, indent=2))
        assert first["children"] >= 3, "children undercounted"
        assert last["rss_total_bytes"] > 0, "RSS not measured"
        assert last["threads"] and last["threads"] > 0, "thread count not measured"
        assert last["fds"] and last["fds"] > 0, "fd count not measured"
        assert any(r["cpu_pct"] is not None for r in live), "no CPU delta produced"
        # p95 / median are pure functions; assert their behaviour rather than trusting them.
        assert p95([1, 2, 3, 4, 5]) == 5
        assert median([1, 2, 3]) == 2
        assert parse_cpu_time("1:02.50") == 62.5
        assert parse_cpu_time("2:03:04.25") == 7384.25
        assert parse_cpu_time("1-02:03:04") == 93784
        if getattr(args, "launch", False):
            # Launch timing against a real, harmless GUI app: proves the `open` → pid → window
            # stopwatch works on this host, independent of the two subjects under test.
            probe = {"label": "textedit (launch probe)",
                     "bundle": "/System/Applications/TextEdit.app",
                     "bundle_id": "com.apple.TextEdit"}
            runs = measure_launch(probe, runs=2, timeout=30)
            quit_subject(probe)
            print(json.dumps({"launch_probe": runs}, indent=2))
            assert all(r["to_process_ms"] is not None for r in runs), \
                "launch stopwatch never saw the process"
        log("selftest PASS")
        return 0
    finally:
        try:
            os.killpg(os.getpgid(parent.pid), 15)
        except OSError:
            pass
        try:
            parent.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(parent.pid), 9)
            except OSError:
                pass


# ------------------------------------------------------------------------------------ run/report

def write_csv(path: str, preflight_data: dict, sessions: dict) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fields = ["subject", "phase", "run", "sample", "t_wall", "alive", "rss_total_bytes",
              "rss_app_bytes", "rss_helpers_bytes", "cpu_pct", "threads", "fds", "children",
              "power_w", "to_process_ms", "to_window_ms", "processes", "note"]
    with open(path, "w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fields)
        writer.writeheader()
        if not sessions:
            for check in preflight_data["checks"]:
                if check["blocking"] and not check["ok"]:
                    writer.writerow({"subject": "preflight", "phase": "blocked", "alive": "false",
                                     "note": f"{check['name']}: {check['detail']}"})
            if not any(c["blocking"] and not c["ok"] for c in preflight_data["checks"]):
                writer.writerow({"subject": "preflight", "phase": "blocked", "alive": "false",
                                 "note": "no session data"})
            return
        for key in ORDER:
            session = sessions.get(key) or {}
            for row in session.get("samples", []):
                writer.writerow({
                    "subject": key, "phase": row.get("phase"), "sample": row.get("sample"),
                    "t_wall": row.get("t_wall"), "alive": row.get("alive"),
                    "rss_total_bytes": row.get("rss_total_bytes"),
                    "rss_app_bytes": row.get("rss_app_bytes"),
                    "rss_helpers_bytes": row.get("rss_helpers_bytes"),
                    "cpu_pct": row.get("cpu_pct"), "threads": row.get("threads"),
                    "fds": row.get("fds"), "children": row.get("children"),
                    "power_w": row.get("power_w"),
                    "processes": len(row.get("pids") or []),
                })
            for row in session.get("launch", []):
                writer.writerow({
                    "subject": key, "phase": "launch", "run": row.get("run"),
                    "alive": row.get("pid") is not None,
                    "to_process_ms": row.get("to_process_ms"),
                    "to_window_ms": row.get("to_window_ms"),
                    "note": f"launch #{row.get('run')}",
                })


def summarise(session: dict) -> dict:
    """Fold one subject's raw samples into the numbers the table shows."""
    samples = [s for s in session.get("samples", []) if s.get("alive")]
    idle = [s for s in samples if s["phase"] == "idle"]
    active = [s for s in samples if s["phase"] == "active"]
    steady = [s for s in samples if s["phase"] == "steady"]

    def stats(rows: list[dict]) -> dict:
        return {
            "n": len(rows),
            "rss_mean": median([r.get("rss_total_bytes") for r in rows]) if rows else None,
            "rss_p95": p95([r.get("rss_total_bytes") for r in rows]) if rows else None,
            "cpu_mean": (round(statistics.fmean([r["cpu_pct"] for r in rows
                                                 if r.get("cpu_pct") is not None]), 2)
                         if any(r.get("cpu_pct") is not None for r in rows) else None),
            "cpu_p95": p95([r.get("cpu_pct") for r in rows]) if rows else None,
            "threads": median([r.get("threads") for r in rows]),
            "fds": median([r.get("fds") for r in rows]),
            "children": median([r.get("children") for r in rows]),
            "power_w": (round(statistics.fmean([r["power_w"] for r in rows
                                                if r.get("power_w") is not None]), 2)
                        if any(r.get("power_w") is not None for r in rows) else None),
        }

    launch = session.get("launch") or []
    idle_stats, active_stats, steady_stats = stats(idle), stats(active), stats(steady)
    growth = None
    if idle and steady:
        first = idle[-1].get("rss_total_bytes")
        last = steady[-1].get("rss_total_bytes")
        if first and last:
            growth = {"from_bytes": first, "to_bytes": last, "delta_bytes": last - first,
                      "delta_pct": round((last - first) / first * 100, 1)}
    return {
        "idle": idle_stats,
        "active": active_stats,
        "steady": steady_stats,
        "growth": growth,
        "frontmost": session.get("frontmost"),
        "window": session.get("window"),
        "launch_to_process_ms": median([r.get("to_process_ms") for r in launch]),
        "launch_to_window_ms": median([r.get("to_window_ms") for r in launch]),
        "launch_runs": launch,
        "scroll": session.get("scroll"),
        "total_samples": len(samples),
    }


def ratio(native: float | None, electron: float | None) -> float | None:
    if native is None or electron in (None, 0):
        return None
    return round(native / electron, 2)


def render_markdown(preflight_data: dict, summaries: dict, args: argparse.Namespace) -> str:
    host = preflight_data["host"]
    blocked = preflight_data["blocked"]
    lines: list[str] = []
    lines.append("# Native Catalyst client vs the official Electron client")
    lines.append("")
    lines.append(f"Session: {host.get('measured_at')} on {host.get('model')}, macOS "
                 f"{host.get('os')}, {host.get('cpu_count')} logical CPUs. Power: "
                 f"{host.get('power_source')}. Workspace: `{preflight_data['workspace']}`. "
                 f"Channel: `{preflight_data['channel'] or '(not asserted)'}`.")
    lines.append("")
    lines.append(f"**Status: {'BLOCKED — not measured' if blocked else 'measured'}.** "
                 f"Harness: `scripts/perf_compare.py` (sampling primitives reused from "
                 f"`scripts/perf_collect.py`).")
    lines.append("")
    if blocked:
        lines.append("## Result: BLOCKED — nothing was measured")
        lines.append("")
        lines.append("A performance comparison of a login screen is not a performance comparison. "
                     "The run stops in the preflight and reports why, per the card's rule:")
        lines.append("")
        for check in preflight_data["checks"]:
            if check["blocking"] and not check["ok"]:
                lines.append(f"- **{check['name']}** — {check['detail']}")
        lines.append("")
        lines.append("Observed state of each subject at preflight time:")
        lines.append("")
        native = preflight_data["subjects"].get("native", {})
        electron = preflight_data["subjects"].get("electron", {})
        lines.append(f"- native: version {native.get('version')} build {native.get('build')}, "
                     f"configured workspace `{native.get('workspace')}`, "
                     f"`hasSession={native.get('has_session')}`, "
                     f"running pids {native.get('running_pids')}")
        cookie = (electron.get("session_cookies") or {}).get("MMAUTHTOKEN")
        lines.append(f"- electron: version {electron.get('version')} build "
                     f"{electron.get('build')}, configured workspaces "
                     f"{electron.get('servers_configured')}, session cookie for the shared host: "
                     f"{'present' if cookie else 'ABSENT'} (MMUSERID present but no MMAUTHTOKEN is "
                     f"a stale session, not a signed-in one)")
        lines.append("")
        lines.append("To make the comparison measurable, sign both clients in to the same "
                     "workspace, open the same channel in both, and re-run "
                     "`scripts/perf_compare.py run --workspace <url> --channel <name>`.")
        lines.append("")
        lines.append("Either workspace works as long as both clients use it. The throwaway local "
                     "fixture this repository already uses for the webview baseline is the "
                     "cheapest reproducible option: bring up the docker server, seed it with "
                     "`scripts/perf_seed.py` (user `perfprobe`, team `perf`, channel `#perf-feed` "
                     "with 200 posts), sign both clients into it, then run with "
                     "`--workspace http://127.0.0.1:8065 --channel perf-feed`.")
        lines.append("")
        lines.append("The card names the native subject as *0.1.7 build 8*; the installed bundle "
                     "reports the version above, and the artefact records what is installed and "
                     "preflighted rather than what the card expected.")
        lines.append("")
        lines.append("No win or loss is named here: no RSS, CPU, launch or energy number was taken "
                     "for either subject, so any sentence about which client is faster would be "
                     "invention. The table below keeps every row and says why it is empty.")
        lines.append("")

    lines.append("## Method (the harness; it did not run this session)"
                 if blocked else "## How the numbers were taken")
    lines.append("")
    if blocked:
        lines.append("Recorded so the next run is reproducible and auditable:")
        lines.append("")
    lines.append("- **RSS** — `ps -axo rss` sampled every 0.5 s over the app's whole process "
                 "tree (descendants by ppid) plus the WebKit helper processes attributed to "
                 "the app with `scripts/perf_collect.py`'s rule (pids absent from the "
                 "pre-launch baseline). Electron's Renderer/GPU/Utility helpers are children "
                 "and are summed; Catalyst's WebContent/GPU/Networking helpers are not "
                 "children and are attributed explicitly.")
    lines.append("- **CPU** — Δ(cumulative CPU time from `ps -o time=`) over each 0.5 s "
                 "interval, so mean and p95 are windowed; `ps`'s own %CPU column is a lifetime "
                 "average and is not used. 100 % = one core.")
    lines.append("- **Threads / fds / children** — `ps -M` thread lines, `lsof -p` descriptor "
                 "count (header removed), and the number of descendant processes, all summed "
                 "over the same pid set.")
    lines.append("- **Energy** — `top -stats power` summed over the tree, sampled every 5 s.")
    lines.append("- **Launch** — from `open -n <bundle>` to the first pid match (to process "
                 "alive) and to the first non-zero System Events window count (to first "
                 "window), three runs, median. *Not* \"to interactive\": the app's own first "
                 "paint is not observable from outside it.")
    lines.append("- **Steady state** — RSS at the end of a 10-minute idle window, against the "
                 "end of the first idle window, to expose growth a 2-minute sample hides.")
    lines.append("- **Active window** — 60 s of wheel events posted with Core Graphics straight "
                 "to the app's pid (`scripts/perf_scroll.swift`), so both clients receive the "
                 "same synthetic input path rather than two different automation stacks. The "
                 "event count is recorded; the number of posts actually rendered is not "
                 "claimed.")
    lines.append("")

    def cell(value, fmt="{}"):
        if blocked:
            return "not measured"
        if value is None:
            return "not available"
        return fmt(value) if callable(fmt) else fmt.format(value)

    def add_row(metric: str, native, electron, note: str, fmt="{}"):
        r = None if blocked else ratio(native, electron) if isinstance(native, (int, float)) \
            and isinstance(electron, (int, float)) else None
        lines.append(f"| {metric} | {cell(native, fmt)} | {cell(electron, fmt)} | "
                     f"{'—' if r is None else r} | {note} |")

    lines.append("")
    lines.append("| metric | native | electron | ratio (native/electron) | notes |")
    lines.append("|---|---:|---:|---:|---|")

    if not blocked:
        lines.append(f"| version | {preflight_data['subjects']['native'].get('version')} "
                     f"| {preflight_data['subjects']['electron'].get('version')} "
                     f"| — | app bundle versions |")
    n, e = summaries.get("native", {}), summaries.get("electron", {})
    n_idle, e_idle = n.get("idle", {}), e.get("idle", {})
    add_row("idle 120 s — RSS median", n_idle.get("rss_mean"), e_idle.get("rss_mean"),
            "over the process tree", mb)
    add_row("idle 120 s — RSS p95", n_idle.get("rss_p95"), e_idle.get("rss_p95"),
            "same tree, 95th percentile sample", mb)
    add_row("idle 120 s — CPU mean %", n_idle.get("cpu_mean"), e_idle.get("cpu_mean"),
            "windowed Δcpu; 100 % = one core")
    add_row("idle 120 s — CPU p95 %", n_idle.get("cpu_p95"), e_idle.get("cpu_p95"),
            "per-sample distribution")
    add_row("threads", n_idle.get("threads"), e_idle.get("threads"), "median over the tree")
    add_row("open fds", n_idle.get("fds"), e_idle.get("fds"), "`lsof -p`, median")
    add_row("child processes", n_idle.get("children"), e_idle.get("children"),
            "descendants of the main process, median")
    add_row("power (top -stats power)", n_idle.get("power_w"), e_idle.get("power_w"),
            "sum over the tree; not available without root on hosts where top omits it")
    n_act, e_act = n.get("active", {}), e.get("active", {})
    add_row("active 60 s — RSS median", n_act.get("rss_mean"), e_act.get("rss_mean"),
            "scrolling through 200 posts", mb)
    add_row("active 60 s — CPU mean %", n_act.get("cpu_mean"), e_act.get("cpu_mean"),
            "same scroll path for both")
    add_row("launch → process alive (median)", n.get("launch_to_process_ms"),
            e.get("launch_to_process_ms"), "3 runs", "{} ms")
    add_row("launch → first window (median)", n.get("launch_to_window_ms"),
            e.get("launch_to_window_ms"), "3 runs", "{} ms")
    n_g, e_g = n.get("growth") or {}, e.get("growth") or {}
    add_row("steady state — RSS delta after 10 min idle", n_g.get("delta_bytes"),
            e_g.get("delta_bytes"), "positive = growth since the first idle window", mb)

    lines.append("")
    lines.append("## Conditions")
    lines.append("")
    for check in preflight_data["checks"]:
        status = "PASS" if check["ok"] else ("BLOCK" if check["blocking"] else "NOTE")
        lines.append(f"- `{status}` **{check['name']}** — {check['detail']}")
    if not blocked:
        sizes = []
        for key in ORDER:
            summary = summaries.get(key, {})
            window = summary.get("window") or {}
            achieved = window.get("achieved")
            sizes.append(achieved)
            lines.append(f"- `NOTE` **window ({key})** — requested {window.get('requested')}, "
                         f"achieved {achieved}, frontmost={summary.get('frontmost')}")
        if all(sizes):
            distinct = {(s["width"], s["height"]) for s in sizes}
            if len(distinct) == 1:
                lines.append(f"- `PASS` **same_window_size** — both windows "
                             f"{sizes[0]['width']}×{sizes[0]['height']}")
            else:
                lines.append("- `FAIL` **same_window_size** — "
                             + " vs ".join(f"{k}={s['width']}×{s['height']}"
                                           for k, s in zip(ORDER, sizes)))
        else:
            lines.append("- `FAIL` **same_window_size** — window bounds could not be read for "
                         "both subjects")
        lines.append("- `NOTE` **unread parity** — the number of unread items each client holds "
                     "is not machine-verifiable from outside; both were on the same channel with "
                     "the same history, and this is an operator condition, not a measured one.")
    lines.append("")

    lines.append("## Biggest win and biggest loss")
    lines.append("")
    if blocked:
        lines.append("Not nameable: nothing was measured, so there is no win and no loss to "
                     "report. Naming one would be an opinion, which is what this card forbids.")
    else:
        candidates = []
        for label, nv, ev, fmt in [
            ("idle RSS median", n_idle.get("rss_mean"), e_idle.get("rss_mean"), mb),
            ("idle CPU mean", n_idle.get("cpu_mean"), e_idle.get("cpu_mean"),
             lambda v: f"{v:.2f} %"),
            ("launch to process", n.get("launch_to_process_ms"),
             e.get("launch_to_process_ms"), lambda v: f"{v:.0f} ms"),
            ("launch to first window", n.get("launch_to_window_ms"),
             e.get("launch_to_window_ms"), lambda v: f"{v:.0f} ms"),
            ("active RSS median", n_act.get("rss_mean"), e_act.get("rss_mean"), mb),
            ("active CPU mean", n_act.get("cpu_mean"), e_act.get("cpu_mean"),
             lambda v: f"{v:.2f} %"),
        ]:
            r = ratio(nv, ev)
            if r is not None:
                candidates.append((label, r, fmt(nv), fmt(ev)))
        wins = [c for c in candidates if c[1] < 1]
        losses = [c for c in candidates if c[1] > 1]
        if wins:
            label, r, nv, ev = min(wins, key=lambda c: c[1])
            lines.append(f"- **Biggest win:** {label} — native {nv} vs electron {ev} "
                         f"(ratio {r}).")
        else:
            lines.append("- **Biggest win:** none — no comparable metric came out below the "
                         "Electron client.")
        if losses:
            label, r, nv, ev = max(losses, key=lambda c: c[1])
            lines.append(f"- **Biggest loss:** {label} — native {nv} vs electron {ev} "
                         f"(ratio {r}).")
        else:
            lines.append("- **Biggest loss:** none — no comparable metric came out above the "
                         "Electron client.")
    lines.append("")
    lines.append("## What this does not measure")
    lines.append("")
    lines.append("- **Interactive latency.** Neither client exposes time-to-first-paint or "
                 "input-to-photon to an external sampler; \"launch → first window\" is a window "
                 "count, not a rendered frame, and is labelled that way.")
    lines.append("- **Memory pressure or swap.** RSS and ps' resident size are not the kernel's "
                 "footprint under pressure; the existing `docs/perf/README.md` covers `footprint` "
                 "for the Catalyst/webview question.")
    lines.append("- **GPU and energy on battery.** `top -stats power` is sampled, not "
                 "`powermetrics` (root); the power-source line in Conditions says whether the "
                 "host was on AC.")
    lines.append("- **Server-bound differences.** Both clients talk to the same workspace and "
                 "the same channel, so network and server work are common-mode, but a server "
                 "slow enough to dominate a window would hide client-side differences.")
    lines.append("- **Long sessions.** One 10-minute steady-state window; multi-hour drift, "
                 "notifications arriving and reconnects are out of scope.")
    lines.append("")
    lines.append("## Harness verification")
    lines.append("")
    lines.append("The harness is exercised independently of the two subjects, so a failure in a "
                 "later run is a finding about the clients and not about an unproven tool:")
    lines.append("")
    lines.append("- `python3 scripts/perf_compare.py selftest` — assertions on a synthetic "
                 "four-process tree: tree walk finds the children, RSS/threads/fds are "
                 "non-zero, the CPU delta and the `ps -o time=` parser are checked.")
    lines.append("- `python3 scripts/perf_compare.py selftest --launch` — additionally times "
                 "TextEdit's real launch with the same stopwatch used for both subjects "
                 "(process visibility and first window), and asserts the process stopwatch "
                 "fired.")
    lines.append("- `scripts/perf_scroll.swift` — compiled with `xcrun swiftc` during `run`; the "
                 "wheel events are posted with Core Graphics (`CGEvent.postToPid`) and the "
                 "helper reports whether Accessibility allowed it rather than silently "
                 "delivering nothing.")
    lines.append("- Output of the self-test on this host: `docs/perf/selftest-2026-11-05.log`.")
    lines.append("")
    lines.append("## Reproduce")
    lines.append("")
    lines.append("```")
    lines.append("scripts/perf_compare.py preflight --workspace <url> --channel <name>")
    lines.append("scripts/perf_compare.py run --workspace <url> --channel <name>")
    lines.append("scripts/perf_compare.py report            # re-render from the last run dir")
    lines.append("scripts/perf_compare.py selftest --launch")
    lines.append("```")
    lines.append("")
    lines.append("| flag | meaning | default |")
    lines.append("|---|---|---|")
    lines.append("| `--workspace URL` | workspace both clients must have configured; defaults to the "
                 "native app's active server | native's active server |")
    lines.append("| `--channel NAME` | the channel both clients must be sitting on; recorded as an "
                 "operator assertion (neither client exposes it to an external process) | none "
                 "(a run without it blocks) |")
    lines.append("| `--idle SECONDS` | idle window per subject | 120 |")
    lines.append("| `--active SECONDS` | scripted-scroll window per subject | 60 |")
    lines.append("| `--steady SECONDS` | long idle window for steady-state growth | 600 |")
    lines.append("| `--launch-runs N` | launch repetitions, median reported | 3 |")
    lines.append("| `--interval SECONDS` | RSS/CPU sample interval | 0.5 |")
    lines.append("| `--window-size WxH` | both clients are resized to the same window before "
                 "measuring | 1440x900 |")
    lines.append("| `--scroll-delta PIXELS` | wheel distance per event in the active window | -8 |")
    lines.append("| `--csv PATH`, `--md PATH` | artefact destinations | "
                 "`docs/perf/2026-11-05.csv`, `docs/perf/2026-11-05-native-vs-electron.md` |")
    lines.append("")
    lines.append("Exit codes: 0 measured, 66 blocked in the preflight (the artefacts are still "
                 "written, with the reason), 65 a metric could not be taken, 64 bad arguments.")
    lines.append("")
    lines.append("Raw per-sample numbers: `docs/perf/2026-11-05.csv`.")
    lines.append("")
    return "\n".join(lines)


def update_readme(path: str, markdown_path: str, blocked: bool) -> None:
    """Keep a short, generated pointer in the README; never a typed-in result."""
    rel = os.path.relpath(markdown_path, os.path.dirname(path))
    if blocked:
        body = (f"{START_MARKER}\n"
                f"### Performance vs the official desktop client\n\n"
                f"Not measured yet. Comparing the two clients requires both to be signed in to the "
                f"same workspace and sitting on the same channel; the blocked run and the reasons "
                f"are recorded in [`{rel}`]({rel}). The harness "
                f"(`scripts/perf_compare.py`) refuses to measure a login screen.\n"
                f"{END_MARKER}")
    else:
        body = (f"{START_MARKER}\n"
                f"### Performance vs the official desktop client\n\n"
                f"Measured numbers, conditions and \"what this does not measure\": "
                f"[`{rel}`]({rel}). Raw per-sample data: `docs/perf/2026-11-05.csv`.\n"
                f"{END_MARKER}")
    with open(path) as fh:
        text = fh.read()
    if START_MARKER in text and END_MARKER in text:
        head, rest = text.split(START_MARKER, 1)
        _, tail = rest.split(END_MARKER, 1)
        text = head + body + tail
    else:
        marker = "## Tests"
        text = (text + "\n\n" + body + "\n") if marker not in text \
            else text.replace(marker, body + "\n\n" + marker, 1)
    with open(path, "w") as fh:
        fh.write(text)


def cmd_report(args: argparse.Namespace) -> int:
    run_dir = args.run_dir
    if not run_dir:
        runs = sorted(d for d in os.listdir(RUNS_ROOT)
                      if os.path.isdir(os.path.join(RUNS_ROOT, d))) if os.path.isdir(RUNS_ROOT) else []
        if not runs:
            print(f"no run directories under {RUNS_ROOT}", file=sys.stderr)
            return 65
        run_dir = os.path.join(RUNS_ROOT, runs[-1])
    preflight_path = os.path.join(run_dir, "preflight.json")
    if not os.path.exists(preflight_path):
        print(f"no preflight.json under {run_dir}", file=sys.stderr)
        return 65
    with open(preflight_path) as fh:
        preflight_data = json.load(fh)
    sessions = {}
    if os.path.exists(os.path.join(run_dir, "sessions.json")):
        with open(os.path.join(run_dir, "sessions.json")) as fh:
            sessions = json.load(fh)
    summaries = {k: summarise(v) for k, v in sessions.items()}
    write_csv(args.csv, preflight_data, sessions)
    os.makedirs(os.path.dirname(args.md), exist_ok=True)
    with open(args.md, "w") as fh:
        fh.write(render_markdown(preflight_data, summaries, args))
    if not args.no_readme:
        update_readme(README_PATH, args.md, preflight_data["blocked"])
    print(json.dumps({"wrote": [args.csv, args.md], "blocked": preflight_data["blocked"]}))
    return 66 if preflight_data["blocked"] else 0


def cmd_run(args: argparse.Namespace) -> int:
    try:
        width_text, height_text = args.window_size.lower().split("x", 1)
        args.window_width, args.window_height = int(width_text), int(height_text)
    except (AttributeError, ValueError):
        print(f"--window-size must be WxH (e.g. 1440x900), got {getattr(args, 'window_size', '')!r}",
              file=sys.stderr)
        return 64
    pf = preflight(args, require_channel=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    run_dir = os.path.join(RUNS_ROOT, stamp)
    os.makedirs(run_dir, exist_ok=True)
    with open(os.path.join(run_dir, "preflight.json"), "w") as fh:
        json.dump(pf.as_dict(), fh, indent=2)
    for check in pf.checks:
        log(f"{'ok  ' if check.ok else 'FAIL'} {check.name}: {check.detail}")
    if pf.blocked:
        log("BLOCKED — not measuring a login screen. Artefacts record the reasons.")
        for check in pf.blockers():
            log(f"  blocker: {check.name} — {check.detail}")
        args.run_dir = run_dir
        cmd_report(args)
        return 66

    baseline_webkit = set()
    for pid, info in perf_collect.list_processes().items():
        if perf_collect.webkit_family(info["comm"]):
            baseline_webkit.add(pid)
    helper = build_scroll_helper(run_dir)
    sessions: dict = {}
    for key in ORDER:
        subject = SUBJECTS[key]
        log(f"=== {key}: {subject['bundle']}")
        quit_subject(subject)
        time.sleep(3)
        launch = measure_launch(subject, runs=args.launch_runs)
        pids = subject_pids(subject)
        if not pids:
            log(f"{key}: not running after launch; session aborted")
            return 65
        pid = pids[0]
        frontmost = bring_frontmost(pid)
        if not frontmost:
            log(f"{key}: could not bring the app frontmost; recording as a deviation")
        requested = {"width": args.window_width, "height": args.window_height}
        size_set = set_window_bounds(pid, args.window_width, args.window_height)
        bounds = window_bounds(pid)
        log(f"{key}: frontmost={frontmost} window requested={requested} "
            f"achieved={bounds} set_ok={size_set}")
        sampler = Sampler(subject, pid, baseline_webkit)
        idle_rows = sample_window(sampler, args.idle, args.interval, "idle")
        scroll = drive_scroll(helper, pid, args.active, delta=args.scroll_delta)
        active_rows = sample_window(sampler, args.active, args.interval, "active")
        steady_rows = sample_window(sampler, args.steady, max(args.interval, 5.0), "steady",
                                    slow_every=1)
        sessions[key] = {
            "label": subject["label"],
            "pid": pid,
            "frontmost": frontmost,
            "window": {"requested": requested, "achieved": bounds, "set_ok": size_set},
            "launch": launch,
            "scroll": scroll,
            "samples": idle_rows + active_rows + steady_rows,
        }
        log(f"{key}: {len(idle_rows) + len(active_rows) + len(steady_rows)} samples; "
            f"scroll {scroll}")
        quit_subject(subject)
        time.sleep(2)
    with open(os.path.join(run_dir, "sessions.json"), "w") as fh:
        json.dump(sessions, fh)
    args.run_dir = run_dir
    cmd_report(args)
    return 0


def cmd_preflight(args: argparse.Namespace) -> int:
    pf = preflight(args, require_channel=bool(args.channel))
    print(json.dumps(pf.as_dict(), indent=2))
    return 66 if pf.blocked else 0


def add_subject_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--workspace", default="",
                        help="workspace URL both clients must share (default: native's active)")
    parser.add_argument("--channel", default="",
                        help="channel both clients must sit on; recorded, never guessed")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("preflight", help="check the fairness preconditions, measure nothing")
    add_subject_args(p)
    p.set_defaults(func=cmd_preflight)

    r = sub.add_parser("run", help="measure both subjects and write the artefacts")
    add_subject_args(r)
    r.add_argument("--idle", type=float, default=120.0)
    r.add_argument("--active", type=float, default=60.0)
    r.add_argument("--steady", type=float, default=600.0)
    r.add_argument("--launch-runs", type=int, default=3)
    r.add_argument("--interval", type=float, default=0.5)
    r.add_argument("--scroll-delta", type=int, default=-8,
                   help="pixels per wheel event; negative scrolls down")
    r.add_argument("--window-size", default="1440x900",
                   help="WxH both clients are resized to before measuring (default 1440x900)")
    r.add_argument("--csv", default=DEFAULT_CSV)
    r.add_argument("--md", default=DEFAULT_MD)
    r.add_argument("--no-readme", action="store_true")
    r.set_defaults(func=cmd_run)

    q = sub.add_parser("report", help="re-render the artefacts from an existing run directory")
    q.add_argument("--run-dir", default="")
    q.add_argument("--csv", default=DEFAULT_CSV)
    q.add_argument("--md", default=DEFAULT_MD)
    q.add_argument("--no-readme", action="store_true")
    q.set_defaults(func=cmd_report)

    s = sub.add_parser("selftest", help="exercise the sampler on a synthetic process tree")
    s.add_argument("--launch", action="store_true",
                   help="also time TextEdit's launch (proves the launch stopwatch on this host)")
    s.set_defaults(func=cmd_selftest)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
