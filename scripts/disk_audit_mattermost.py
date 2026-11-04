#!/usr/bin/env python3
"""Disk audit for the Mattermost iOS migration host.

The owner's rule for this machine: exactly ONE official client and ONE native
build on disk, nothing else.  This script is read-only; it never deletes
anything.  It walks the roots the cleanup card names, prints one line per
artifact

    path | size | kind | verdict

and exits non-zero while anything other than the two kept bundles is present,
so a green run is a claim that can be re-checked at any time.

Kinds are the card's: app, deriveddata, worktree, archive, sim-app, process,
plus ``fixture`` for the /tmp defaults snapshots and stubs the card lists under
"leftovers from test fixtures" (kept separate rather than mislabelled).

Exit codes
    0  clean: two apps in /Applications, named as expected, nothing else found
    1  findings: at least one delete/unknown row, or the two kept apps are not
       both present as expected
    2  a root could not be read (TCC or otherwise) -- "I could not check" is
       never reported as clean

Usage: python3 scripts/disk_audit_mattermost.py [--repo PATH] [--quiet]
"""

from __future__ import annotations

import argparse
import os
import plistlib
import re
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
APPS_DIR = "/Applications"
TMP_DIR = "/tmp"
DERIVED = os.path.join(HOME, "Library/Developer/Xcode/DerivedData")
ARCHIVES = os.path.join(HOME, "Library/Developer/Xcode/Archives")

# The two bundles that are allowed to exist, and nothing else.
KEEP_APPS = {
    "/Applications/Mattermost.app": "official Mattermost client",
    "/Applications/Mattermost(ios).app": "native build installed by t_e8c5ee86",
}
KEEP_BINARIES = {
    os.path.join(p, "Contents/MacOS/Mattermost") for p in KEEP_APPS
}

DERIVED_OWNED = re.compile(r"(mattermost|mmios|proof)", re.IGNORECASE)
DERIVED_OWNED_PREFIX = re.compile(r"^t[_-]", re.IGNORECASE)

TMP_DIR_SUFFIXES = ("-dd",)
TMP_DIR_CONTAINS = ("proof",)
TMP_DIR_PREFIXES = ("mm-rel-", "mm-old-", "t_", "t3b2f313a-")
# Fixture leftovers in /tmp that are files, never evidence logs: the defaults
# snapshots, the stub's temp output, and the upstream files fetched for parity.
TMP_FILE_PATTERN = re.compile(r"^mm.*\.(plist|tsx|json)$", re.IGNORECASE)

# Paths the audit already owns; the home walk skips them so a 26 GB build
# directory is measured once, not twice.
COVERED: list[str] = []


class Report:
    def __init__(self, repo: str):
        self.repo = repo
        self.rows: list[dict] = []
        self.denied: list[tuple[str, str]] = []
        self.unreadable: list[tuple[str, str]] = []

    def add(self, path: str, size: int, kind: str, verdict: str, note: str = ""):
        self.rows.append(
            {"path": path, "size": size, "kind": kind, "verdict": verdict, "note": note}
        )

    def has_class(self, kind: str, verdict: str) -> bool:
        return any(r["kind"] == kind and r["verdict"] == verdict for r in self.rows)


# --------------------------------------------------------------------------
# helpers


def human(n: int) -> str:
    units = ["B", "K", "M", "G", "T"]
    v = float(n)
    for u in units:
        if v < 1024 or u == units[-1]:
            return f"{v:.0f}{u}" if u == "B" else f"{v:.1f}{u}"
        v /= 1024
    return f"{v:.1f}T"


def disk_size(path: str, report: Report) -> int:
    """Allocated bytes of path, like du -sk.  Never follows symlinks."""
    try:
        st = os.lstat(path)
    except OSError as exc:
        report.unreadable.append((path, str(exc)))
        return 0
    if not os.path.isdir(path) or os.path.islink(path):
        return st.st_blocks * 512 or st.st_size
    total = 0
    stack = [path]
    while stack:
        cur = stack.pop()
        try:
            with os.scandir(cur) as it:
                for entry in it:
                    try:
                        est = entry.stat(follow_symlinks=False)
                    except OSError as exc:
                        report.unreadable.append((entry.path, str(exc)))
                        continue
                    if entry.is_dir(follow_symlinks=False):
                        stack.append(entry.path)
                    else:
                        total += est.st_blocks * 512 or est.st_size
        except PermissionError as exc:
            report.unreadable.append((cur, str(exc)))
        except OSError as exc:
            report.unreadable.append((cur, str(exc)))
    return total


def covered_by_any(path: str) -> bool:
    for root in COVERED:
        if path == root or path.startswith(root + os.sep):
            return True
    return False


def walk(root: str, report: Report, skip_names=(".git", "node_modules"), max_depth=None):
    """Yield (root, dirs, files) pruning the heavy directories.  Read errors
    are collected, never swallowed."""
    base_depth = root.rstrip(os.sep).count(os.sep)

    def onerror(exc: OSError):
        report.unreadable.append((getattr(exc, "filename", root) or root, str(exc)))

    for cur, dirs, files in os.walk(root, onerror=onerror):
        if max_depth is not None and cur.count(os.sep) - base_depth >= max_depth:
            dirs[:] = []
        dirs[:] = [d for d in dirs if d not in skip_names and not os.path.islink(os.path.join(cur, d))]
        yield cur, dirs, files


def find_apps(root: str, report: Report, only_mattermost=True, skip=()):
    """Yield .app bundle paths; prune inside bundles and in ``skip`` roots."""
    found = []
    for cur, dirs, _files in walk(root, report):
        keep = []
        for d in dirs:
            full = os.path.join(cur, d)
            if any(full == s or full.startswith(s + os.sep) for s in skip):
                continue
            if covered_by_any(full):
                continue
            if d.endswith(".app"):
                if not only_mattermost or d.lower().startswith("mattermost"):
                    found.append(full)
                continue  # never descend into a bundle
            keep.append(d)
        dirs[:] = keep
    return found


def run(cmd: list[str]) -> tuple[int, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except FileNotFoundError as exc:
        return 127, str(exc)


def read_version(app: str) -> str:
    info = os.path.join(app, "Contents/Info.plist")
    try:
        with open(info, "rb") as fh:
            data = plistlib.load(fh)
        return f"{data.get('CFBundleShortVersionString', '?')} ({data.get('CFBundleVersion', '?')})"
    except Exception as exc:  # noqa: BLE001 - report, do not crash
        return f"unreadable: {exc}"


# --------------------------------------------------------------------------
# scans


def scan_kept_apps(report: Report):
    for path, why in KEEP_APPS.items():
        if os.path.isdir(path):
            report.add(path, disk_size(path, report), "app", "keep", why)
            COVERED.append(path)
        else:
            report.add(path, 0, "app", "unknown", f"missing: {why}")


def scan_applications(report: Report):
    try:
        with os.scandir(APPS_DIR) as it:
            names = sorted(e.name for e in it)
    except OSError as exc:
        report.denied.append((APPS_DIR, str(exc)))
        return
    for name in names:
        if not name.lower().startswith("mattermost"):
            continue
        path = os.path.join(APPS_DIR, name)
        if path in KEEP_APPS:
            continue
        report.add(path, disk_size(path, report), "app", "delete",
                   "not one of the two kept bundles")


def scan_derived_data(report: Report):
    if not os.path.isdir(DERIVED):
        report.denied.append((DERIVED, "missing"))
        return
    try:
        with os.scandir(DERIVED) as it:
            names = sorted(e.name for e in it)
    except OSError as exc:
        report.denied.append((DERIVED, str(exc)))
        return
    for name in names:
        full = os.path.join(DERIVED, name)
        if not os.path.isdir(full):
            continue
        if DERIVED_OWNED.search(name) or DERIVED_OWNED_PREFIX.match(name):
            report.add(full, disk_size(full, report), "deriveddata", "delete",
                       "Mattermost-owned DerivedData")
            COVERED.append(full)


def scan_tmp(report: Report):
    try:
        with os.scandir(TMP_DIR) as it:
            entries = list(it)
    except OSError as exc:
        report.denied.append((TMP_DIR, str(exc)))
        return
    for entry in entries:
        name = entry.name
        low = name.lower()
        is_dir = entry.is_dir(follow_symlinks=False)
        hit = (
            (is_dir and name.endswith(TMP_DIR_SUFFIXES))
            or (is_dir and any(s in low for s in TMP_DIR_CONTAINS))
            or (is_dir and name.startswith(TMP_DIR_PREFIXES))
            or (not is_dir and TMP_FILE_PATTERN.match(name))
        )
        if not hit:
            continue
        path = os.path.join(TMP_DIR, name)
        kind = "deriveddata" if is_dir else "fixture"
        report.add(path, disk_size(path, report), kind, "delete",
                   "throwaway build dir / fixture leftover in /tmp")
        COVERED.append(path)


def scan_repo_build_output(report: Report, repo: str):
    """build/, .build/, *.xcresult and *.app inside the shared checkout.

    ``build/`` also holds one tracked fixture (``build/uitest-server/mm_stub.py``,
    the stub the card's process rule is about).  A build directory whose only
    contents are tracked files is source, not output, and is reported keep.
    """
    for name in ("build", ".build"):
        p = os.path.join(repo, name)
        if not os.path.isdir(p):
            continue
        rc, out = run(["git", "-C", repo, "status", "--porcelain", "--", name])
        untracked = [ln for ln in out.splitlines() if ln.startswith("??")]
        if rc == 0 and not untracked:
            report.add(p, disk_size(p, report), "deriveddata", "keep",
                       "tracked test fixture only (mm_stub.py); no build output")
            COVERED.append(p)
            continue
        report.add(p, disk_size(p, report), "deriveddata", "delete",
                   "build output in the checkout")
        COVERED.append(p)
    for cur, dirs, _files in walk(repo, report):
        if covered_by_any(cur):
            dirs[:] = []
            continue
        xc = [d for d in dirs if d.endswith(".xcresult")]
        dirs[:] = [d for d in dirs if not d.endswith(".xcresult")]
        for d in xc:
            full = os.path.join(cur, d)
            report.add(full, disk_size(full, report), "archive", "delete",
                       "xcresult bundle")
            COVERED.append(full)
    for app in find_apps(repo, report, skip=(os.path.join(repo, ".git"),)):
        report.add(app, disk_size(app, report), "app", "delete",
                   "Mattermost.app bundle outside /Applications")
        COVERED.append(app)


def scan_worktrees(report: Report, repo: str):
    rc, out = run(["git", "-C", repo, "worktree", "list", "--porcelain"])
    if rc != 0:
        report.denied.append((repo, f"git worktree list failed: {out.strip()[:200]}"))
        return
    paths = [ln[len("worktree "):] for ln in out.splitlines() if ln.startswith("worktree ")]
    for path in paths:
        if os.path.realpath(path) == os.path.realpath(repo):
            continue
        if not os.path.isdir(path):
            report.add(path, 0, "worktree", "delete",
                       "stale registration: directory is gone (git worktree prune)")
            continue
        report.add(path, disk_size(path, report), "worktree", "keep",
                   "registered dispatcher checkout (source, kept)")
        COVERED.append(path)
        # Build output inside that checkout is not a checkout: it goes.
        for name in ("build", ".build"):
            p = os.path.join(path, name)
            if os.path.isdir(p) and not covered_by_any(p):
                report.add(p, disk_size(p, report), "deriveddata", "delete",
                           "build output inside a registered worktree")
                COVERED.append(p)
        for cur, dirs, _files in walk(path, report):
            if cur != path and covered_by_any(cur):
                dirs[:] = []
                continue
            xc = [d for d in dirs if d.endswith(".xcresult")]
            dirs[:] = [d for d in dirs if not d.endswith(".xcresult")]
            for d in xc:
                full = os.path.join(cur, d)
                report.add(full, disk_size(full, report), "archive", "delete",
                           "xcresult bundle inside a worktree")
                COVERED.append(full)
        for app in find_apps(path, report, skip=(os.path.join(path, ".git"),)):
            report.add(app, disk_size(app, report), "app", "delete",
                       "Mattermost.app bundle inside a worktree")
            COVERED.append(app)


def scan_repo_root_leftovers(report: Report, repo: str):
    """Directories under repo/.worktrees that git does not know about."""
    wt_dir = os.path.join(repo, ".worktrees")
    if not os.path.isdir(wt_dir):
        return
    try:
        with os.scandir(wt_dir) as it:
            entries = [e for e in it if e.is_dir(follow_symlinks=False)]
    except OSError as exc:
        report.denied.append((wt_dir, str(exc)))
        return
    for e in entries:
        if not covered_by_any(e.path):
            report.add(e.path, disk_size(e.path, report), "worktree", "delete",
                       "checkout under .worktrees/ not registered with git")


def scan_archives(report: Report):
    if not os.path.isdir(ARCHIVES):
        return
    for cur, dirs, _files in walk(ARCHIVES, report):
        for d in list(dirs):
            if d.endswith(".xcarchive"):
                full = os.path.join(cur, d)
                dirs.remove(d)
                if not d.lower().startswith("mattermost"):
                    continue  # another project's archive is not ours to touch
                report.add(full, disk_size(full, report), "archive", "delete",
                           "Mattermost Xcode archive")
                COVERED.append(full)


def scan_home(report: Report):
    """Mattermost .app bundles, archives and .bak copies anywhere in $HOME that
    the targeted scans above did not already classify."""
    skip_top = {
        os.path.join(HOME, "Library"),
        os.path.join(HOME, "node_modules"),
    }
    for cur, dirs, files in walk(HOME, report, skip_names=(".git", "node_modules")):
        if covered_by_any(cur):
            dirs[:] = []
            continue
        dirs[:] = [d for d in dirs if os.path.join(cur, d) not in skip_top]
        keep = []
        for d in dirs:
            full = os.path.join(cur, d)
            if covered_by_any(full):
                continue
            if d.endswith(".xcarchive"):
                if not d.lower().startswith("mattermost"):
                    continue
                report.add(full, disk_size(full, report), "archive", "delete",
                           "Mattermost Xcode archive outside ~/Library")
                COVERED.append(full)
                continue
            if d.lower().startswith("mattermost") and d.endswith(".app"):
                report.add(full, disk_size(full, report), "app", "delete",
                           "Mattermost.app bundle outside /Applications")
                COVERED.append(full)
                continue
            if d.endswith(".app"):
                continue
            keep.append(d)
        dirs[:] = keep
        for f in files:
            full = os.path.join(cur, f)
            if covered_by_any(full):
                continue
            low = f.lower()
            if low.startswith("mattermost") and low.endswith((".zip", ".dmg", ".ipa")):
                try:
                    size = os.lstat(full).st_blocks * 512
                except OSError as exc:
                    report.unreadable.append((full, str(exc)))
                    size = 0
                report.add(full, size, "archive", "delete", "Mattermost download")
                COVERED.append(full)
            elif low.endswith(".bak") and "mattermost" in full.lower():
                try:
                    size = os.lstat(full).st_blocks * 512
                except OSError as exc:
                    report.unreadable.append((full, str(exc)))
                    size = 0
                report.add(full, size, "fixture", "delete", "old .bak copy")
                COVERED.append(full)


def scan_processes(report: Report):
    rc, out = run(["ps", "-axo", "pid=,command="])
    if rc != 0:
        report.denied.append(("ps", out.strip()[:200]))
        return
    me = {os.getpid(), os.getppid()}
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        pid_s, _, cmd = line.partition(" ")
        try:
            pid = int(pid_s)
        except ValueError:
            continue
        if pid in me:
            continue
        low = cmd.lower()
        if "mattermost" not in low and "mm_stub" not in low:
            continue
        exe = cmd.split(" ")[0]
        # Only app binaries and the fixture stub count; an xcodebuild verb that
        # merely mentions Mattermost.xcodeproj is build activity, not a stray app.
        is_app_exe = ".app/contents/macos/" in exe.lower()
        is_stub = "mm_stub" in low
        if not (is_app_exe or is_stub):
            continue
        if exe in KEEP_BINARIES:
            continue
        kind = "process"
        report.add(f"pid {pid}: {exe}", 0, kind, "delete",
                   "Mattermost process not launched from the two kept bundles")


def scan_simulators(report: Report):
    rc, out = run(["xcrun", "simctl", "list", "devices", "--json"])
    if rc != 0:
        report.denied.append(("xcrun simctl", out.strip()[:300]))
        return
    import json as _json

    try:
        devices = _json.loads(out).get("devices", {})
    except ValueError as exc:
        report.denied.append(("xcrun simctl list", f"unparsable: {exc}"))
        return

    seen = set()

    def add_sim_app(udid, name, bundle_id, path):
        key = (udid, bundle_id)
        if key in seen:
            return
        seen.add(key)
        report.add(f"simulator {name} ({udid}): {bundle_id}", 0, "sim-app", "delete",
                   f"Mattermost app installed in a simulator ({path})")

    for runtime, devs in devices.items():
        for dev in devs:
            if not dev.get("isAvailable", False):
                continue
            udid = dev["udid"]
            name = dev.get("name", "?")
            # A booted simulator answers simctl; a shutdown one cannot be asked
            # (CoreSimulator error 405), so its bundle container is inspected on
            # disk instead.  Neither path deletes a runtime.
            if dev.get("state") == "Booted":
                rc2, out2 = run(["xcrun", "simctl", "listapps", udid])
                if rc2 == 0:
                    for line in out2.splitlines():
                        m = re.match(r'\s*"([^"]*[Mm]attermost[^"]*)"\s*=\s*\{', line)
                        if m:
                            add_sim_app(udid, name, m.group(1), "via simctl")
                else:
                    report.denied.append((f"simulator {udid} (booted)", out2.strip()[:200]))
            data = dev.get("dataPath")
            if not data:
                continue
            appdir = os.path.join(data, "Containers/Bundle/Application")
            try:
                with os.scandir(appdir) as it:
                    containers = [c for c in it if c.is_dir(follow_symlinks=False)]
            except OSError:
                continue  # device never booted / no containers yet
            for container in containers:
                try:
                    with os.scandir(container.path) as it2:
                        bundles = list(it2)
                except OSError as exc:
                    report.unreadable.append((container.path, str(exc)))
                    continue
                for bundle in bundles:
                    if not (bundle.name.lower().startswith("mattermost") and bundle.name.endswith(".app")):
                        continue
                    bundle_id = "com.mattermost.ios"
                    try:
                        with open(os.path.join(bundle.path, "Info.plist"), "rb") as fh:
                            bundle_id = plistlib.load(fh).get("CFBundleIdentifier", bundle_id)
                    except Exception:  # noqa: BLE001
                        pass
                    add_sim_app(udid, name, bundle_id, bundle.path)


# --------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--quiet", action="store_true", help="only the table")
    args = ap.parse_args()
    repo = os.path.abspath(args.repo)

    report = Report(repo)
    started = time.strftime("%Y-%m-%d %H:%M:%S %Z")

    scan_kept_apps(report)
    scan_applications(report)
    scan_derived_data(report)
    scan_tmp(report)
    scan_repo_build_output(report, repo)
    scan_worktrees(report, repo)
    scan_repo_root_leftovers(report, repo)
    scan_archives(report)
    scan_home(report)
    scan_processes(report)
    scan_simulators(report)

    # ---- report
    print(f"# disk audit: Mattermost artifacts")
    print(f"# host: {os.uname().nodename}   started: {started}")
    print(f"# repo: {repo}")
    print(f"# rule: keep exactly {', '.join(sorted(KEEP_APPS))}")
    print()
    print("path | size | kind | verdict")
    rows = sorted(report.rows, key=lambda r: (r["verdict"] == "keep", -r["size"], r["path"]))
    for r in rows:
        print(f"{r['path']} | {human(r['size']) if r['size'] else '-'} | {r['kind']} | {r['verdict']}")
    print()

    deletes = [r for r in report.rows if r["verdict"] == "delete"]
    unknowns = [r for r in report.rows if r["verdict"] == "unknown"]
    app_rows = [r for r in report.rows if r["kind"] == "app"]
    kept_apps = [r for r in app_rows if r["verdict"] == "keep"]
    delete_bytes = sum(r["size"] for r in deletes)

    print("## summary")
    print(f"delete rows: {len(deletes)}   reclaimable: {human(delete_bytes)}")
    print(f"unknown rows: {len(unknowns)}")
    print(f"app bundles found: {len(app_rows)} (expected 2, both in /Applications)")
    for path, why in KEEP_APPS.items():
        print(f"  kept: {path}  version={read_version(path) if os.path.isdir(path) else 'MISSING'}  ({why})")
    rc, dfout = run(["df", "-h", "/"])
    if rc == 0 and dfout.strip():
        print(f"free space: {dfout.strip().splitlines()[-1]}")

    if report.denied:
        print()
        print("## ROOTS THAT COULD NOT BE CHECKED")
        for path, why in report.denied:
            print(f"DENIED {path}: {why}")
    if report.unreadable:
        seen = set()
        print()
        print("## UNREADABLE SUBPATHS")
        for path, why in report.unreadable:
            key = (path, why)
            if key in seen:
                continue
            seen.add(key)
            print(f"UNKNOWN {path}: {why}")

    problems = []
    if report.denied:
        problems.append(f"{len(report.denied)} root(s) could not be checked")
    if deletes:
        problems.append(f"{len(deletes)} artifact(s) still present")
    if unknowns:
        problems.append(f"{len(unknowns)} unknown row(s)")
    if len(app_rows) != 2 or len(kept_apps) != 2:
        problems.append(f"{len(app_rows)} app bundle(s) found, expected exactly 2")

    print()
    if report.denied:
        print(f"RESULT: UNVERIFIABLE -- {'; '.join(problems)}")
        return 2
    if problems:
        print(f"RESULT: DIRTY -- {'; '.join(problems)}")
        return 1
    print("RESULT: CLEAN -- two apps in /Applications, nothing else")
    return 0


if __name__ == "__main__":
    sys.exit(main())
