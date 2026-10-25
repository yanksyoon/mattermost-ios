#!/usr/bin/env python3
"""Gate: the work must be published, not just committed.

A card is not done when `git commit` succeeds. Local-only history is one disk
failure away from being no history at all, and an `-AV` that audits local `main`
is auditing something no one else can see. This script answers "is it on the
remote?" — and it is the assertion cards must paste before closing.

Checks
  1. LOCAL == REMOTE   local HEAD must equal what the remote reports for the ref.
  2. NO WORKTREES      `.worktrees/` must never be tracked; a checkout inside the
                       repo would be swept into the next `git add -A`.
  3. NO SECRETS        signing material and credential files must not be tracked.

Usage
  python3 scripts/verify-pushed.py                 # gate the current repo
  python3 scripts/verify-pushed.py --ref main      # gate a different branch
  python3 scripts/verify-pushed.py --origin <url>  # gate against another origin
  python3 scripts/verify-pushed.py --self-test     # prove each check can fail

Exit: 0 PASS, 1 FAIL. Never 0 on a check that did not run.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile

SECRET_PATTERNS = (".p8", ".p12", ".key", ".pem", "auth.json")
SECRET_EXACT = ("secrets.json", "credentials.json")


def git(*args: str, cwd: str = ".", check: bool = True) -> str:
    r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {r.stderr.strip()}")
    return r.stdout.strip()


def local_head(cwd: str, ref: str) -> str | None:
    r = subprocess.run(["git", "rev-parse", "--verify", ref], cwd=cwd,
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def remote_head(origin: str, ref: str, cwd: str) -> str | None:
    """Ask the remote directly: never trust a stale remote-tracking ref."""
    r = subprocess.run(["git", "ls-remote", origin, f"refs/heads/{ref}"],
                       cwd=cwd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"ls-remote failed: {r.stderr.strip()}")
    for line in r.stdout.splitlines():
        sha, _, name = line.partition("\t")
        if name.strip() == f"refs/heads/{ref}":
            return sha.strip()
    return None


def tracked_paths(cwd: str) -> list[str]:
    return [p for p in git("ls-files", cwd=cwd).splitlines() if p.strip()]


def check(cwd: str, origin: str, ref: str) -> list[tuple[str, bool, str]]:
    results: list[tuple[str, bool, str]] = []

    # 1. local == remote
    try:
        loc = local_head(cwd, ref)
        rem = remote_head(origin, ref, cwd)
        if loc is None:
            results.append(("LOCAL==REMOTE", False, f"local ref '{ref}' does not exist"))
        elif rem is None:
            results.append(("LOCAL==REMOTE", False,
                            f"remote has no refs/heads/{ref} — never pushed"))
        elif loc != rem:
            ahead = git("rev-list", "--count", f"{rem}..{loc}", cwd=cwd, check=False)
            results.append(("LOCAL==REMOTE", False,
                            f"unpushed: local {loc[:8]} != remote {rem[:8]} ({ahead} ahead)"))
        else:
            results.append(("LOCAL==REMOTE", True, f"{loc[:8]} on both"))
    except RuntimeError as exc:
        results.append(("LOCAL==REMOTE", False, str(exc)))

    # 2. no worktree checkouts tracked
    try:
        bad = [p for p in tracked_paths(cwd) if p.startswith(".worktrees/")]
        results.append(("NO WORKTREES", not bad,
                        "none tracked" if not bad else f"{len(bad)} tracked: {bad[:3]}"))
    except RuntimeError as exc:
        results.append(("NO WORKTREES", False, str(exc)))

    # 3. no secrets tracked
    try:
        hits = [p for p in tracked_paths(cwd)
                if p.lower().endswith(SECRET_PATTERNS) or os.path.basename(p).lower() in SECRET_EXACT]
        results.append(("NO SECRETS", not hits,
                        "none tracked" if not hits else f"{len(hits)} tracked: {hits[:3]}"))
    except RuntimeError as exc:
        results.append(("NO SECRETS", False, str(exc)))

    return results


def emit(results: list[tuple[str, bool, str]], origin: str, ref: str) -> int:
    print(f"verify-pushed: origin={origin} ref={ref}")
    failed = 0
    for name, ok, detail in results:
        print(f"  [{'PASS' if ok else 'FAIL'}] {name:<14} {detail}")
        if not ok:
            failed += 1
    if failed:
        print(f"\nRESULT: FAIL ({failed} check(s)) — do not close the card.")
        return 1
    print("\nRESULT: PASS — the work is published.")
    return 0


def self_test() -> int:
    """Prove every check can fail. A gate that only ever passes is a defect."""
    print("self-test: three fixtures against a throwaway bare remote\n")
    failures = 0
    with tempfile.TemporaryDirectory() as tmp:
        bare = os.path.join(tmp, "origin.git")
        work = os.path.join(tmp, "work")
        git("init", "--bare", "-q", bare, cwd=tmp)
        git("init", "-q", "-b", "main", work, cwd=tmp)
        for k, v in (("user.email", "t@example.com"), ("user.name", "t")):
            git("config", k, v, cwd=work)
        with open(os.path.join(work, "a.txt"), "w") as fh:
            fh.write("one\n")
        git("add", "-A", cwd=work)
        git("commit", "-qm", "init", cwd=work)
        git("remote", "add", "origin", bare, cwd=work)

        def run():
            return emit(check(work, "origin", "main"), "origin", "main")

        # fixture 1: never pushed -> LOCAL==REMOTE must FAIL
        print("--- fixture 1: committed but never pushed (expect FAIL) ---")
        if run() == 0:
            print("  !! DEFECT: passed an unpushed repo"); failures += 1

        # fixture 2: pushed clean -> must PASS
        print("\n--- fixture 2: pushed clean (expect PASS) ---")
        git("push", "-q", "origin", "main", cwd=work)
        if run() != 0:
            print("  !! DEFECT: failed a pushed clean repo"); failures += 1

        # fixture 3: a worktree path gets tracked -> NO WORKTREES must FAIL
        print("\n--- fixture 3: .worktrees/ tracked (expect FAIL) ---")
        os.makedirs(os.path.join(work, ".worktrees", "t1"), exist_ok=True)
        with open(os.path.join(work, ".worktrees", "t1", "x.txt"), "w") as fh:
            fh.write("x\n")
        git("add", "-A", "-f", cwd=work)
        git("commit", "-qm", "accidental worktree", cwd=work)
        git("push", "-q", "origin", "main", cwd=work)
        if run() == 0:
            print("  !! DEFECT: passed a tracked worktree"); failures += 1

        # fixture 4: a .p8 gets tracked -> NO SECRETS must FAIL
        print("\n--- fixture 4: signing key tracked (expect FAIL) ---")
        with open(os.path.join(work, "AuthKey.p8"), "w") as fh:
            fh.write("placeholder\n")
        git("add", "-A", "-f", cwd=work)
        git("commit", "-qm", "accidental key", cwd=work)
        git("push", "-q", "origin", "main", cwd=work)
        if run() == 0:
            print("  !! DEFECT: passed a tracked signing key"); failures += 1

    print("\n" + ("SELF-TEST: PASS — each check fails when its condition is violated."
                  if failures == 0 else
                  f"SELF-TEST: FAIL — {failures} check(s) are vacuous."))
    return 0 if failures == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--origin", default="origin")
    ap.add_argument("--ref", default="main")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    try:
        return emit(check(".", args.origin, args.ref), args.origin, args.ref)
    except RuntimeError as exc:
        print(f"RESULT: FAIL — {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
