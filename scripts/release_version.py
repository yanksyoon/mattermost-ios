#!/usr/bin/env python3
"""Compute the next release version for this repo.

Policy (owner's instruction, 2026-10-26): every push to `main` publishes a release,
and the version increments at the **minor** position — `v0.1.4` -> `v0.2.0` -> `v0.3.0`.
The patch number is reset to 0. This differs from the hand-cut v0.1.x personal builds
(which bumped the patch), so the tag ladder is the only source of truth: this script
reads tags, never a file, so it cannot drift from what was actually released.

No release is ever cut twice for the same commit: if HEAD already carries a `v*` tag
the answer is `SKIP`, which makes a re-run of the workflow a no-op instead of a
duplicate release.

Usage
  scripts/release_version.py                  # print the next tag, e.g. v0.2.0
  scripts/release_version.py --format json    # {"current": "v0.1.4", "next": "v0.2.0"}
  scripts/release_version.py --dry-run        # explain the decision on stderr
  scripts/release_version.py --self-test      # prove the bump rules (used by CI)

Exit: 0 success, 1 malformed input, 2 not a git repository.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys

TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")


def parse_tag(tag: str) -> tuple[int, int, int] | None:
    """`v1.2.3` -> (1, 2, 3). Pre-release/build suffixes are dropped; junk is ignored."""
    m = re.match(r"^v(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$", tag.strip())
    if not m:
        return None
    return int(m.group(1)), int(m.group(2)), int(m.group(3))


def next_version(tags: list[str], head_tags: list[str] | None = None) -> str:
    """Next minor-bumped tag, or SKIP when HEAD is already released."""
    head_tags = head_tags or []
    if any(parse_tag(t) for t in head_tags):
        return "SKIP"
    parsed = [p for p in (parse_tag(t) for t in tags) if p]
    if not parsed:
        return "v0.1.0"  # first release
    major, minor, _patch = max(parsed)
    return f"v{major}.{minor + 1}.0"


def latest(tags: list[str]) -> str | None:
    parsed = [(parse_tag(t), t) for t in tags if parse_tag(t)]
    if not parsed:
        return None
    return max(parsed)[1]


def git(*args: str) -> tuple[int, str]:
    r = subprocess.run(["git", *args], capture_output=True, text=True)
    return r.returncode, r.stdout.strip()


def self_test() -> int:
    cases = [
        ([], [], "v0.1.0", "no tags at all -> first release"),
        (["v0.1.4"], [], "v0.2.0", "minor bump, patch reset"),
        (["v0.1.0", "v0.1.1", "v0.1.4"], [], "v0.2.0", "highest wins, not lexical"),
        (["v0.1.4", "v0.2.0"], [], "v0.3.0", "already bumped once"),
        (["v1.9.9"], [], "v1.10.0", "minor passes 9 without touching major"),
        (["v0.1.4", "garbage", "1.2.3", "v0.1.x", "release-7"], [], "v0.2.0", "junk ignored"),
        (["v0.1.4", "v0.2.0-rc1"], [], "v0.3.0", "pre-release suffix dropped"),
        (["v0.1.4"], ["v0.1.4"], "SKIP", "HEAD already released -> no duplicate"),
        (["v0.1.4"], ["nope"], "v0.2.0", "non-release tag on HEAD does not skip"),
        (["v0.10.0"], [], "v0.11.0", "numeric not lexical (0.10 > 0.9)"),
    ]
    fails = 0
    for tags, head, want, why in cases:
        got = next_version(tags, head)
        ok = got == want
        print(f"  [{'PASS' if ok else 'FAIL'}] {why:<38} {tags or '[]'} -> {got}"
              + ("" if ok else f" (want {want})"))
        if not ok:
            fails += 1
    print(("SELF-TEST: PASS" if fails == 0 else f"SELF-TEST: FAIL {fails}"))
    return 0 if fails == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--format", choices=("tag", "json"), default="tag")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    rc, _ = git("rev-parse", "--git-dir")
    if rc != 0:
        print("not a git repository", file=sys.stderr)
        return 2

    _, out = git("tag", "-l")
    tags = [t for t in out.splitlines() if t.strip()]
    _, head_out = git("tag", "--points-at", "HEAD")
    head_tags = [t for t in head_out.splitlines() if t.strip()]

    nxt = next_version(tags, head_tags)
    cur = latest(tags)

    if args.dry_run:
        print(f"current={cur or '(none)'} head_tags={head_tags or '[]'} next={nxt}", file=sys.stderr)

    if args.format == "json":
        print(json.dumps({"current": cur, "next": None if nxt == "SKIP" else nxt,
                          "skip": nxt == "SKIP", "head_tags": head_tags}))
    else:
        print(nxt)
    return 0


if __name__ == "__main__":
    sys.exit(main())
