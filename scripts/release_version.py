#!/usr/bin/env python3
"""Compute the next release version for this repo, from commit history.

Policy (decided on card t_6904c92b, 2026-11-09): every push to `main` publishes a
release, and the **position** it moves is derived from the commits in that push, using
Conventional Commits:

    feat: ...            -> MINOR   v0.70.0 -> v0.71.0   (new user-facing capability)
    <type>!: ...         -> MINOR   v0.70.0 -> v0.71.0   (breaking; 0.x has no stable
    ...\nBREAKING CHANGE:    contract, so this repo treats a break as a feature)
    fix: ...             -> PATCH   v0.70.0 -> v0.70.1
    docs|test|build|ci|chore|Merge|anything else
                         -> PATCH   v0.70.0 -> v0.70.1   (still a release, still a tag)

Why not the old rule (minor on every push): it cut 74 releases in 17 days, so `v0.71`
and `v0.72` named two pushes an hour apart and the number carried no information about
what changed. The trade-off, stated in docs/releasing.md: this rule is only as honest as
the commit subjects, so a fix typed as `docs:` reaches users as a patch bump. It never
skips a release, and the ladder stays monotonic because every answer is strictly greater
than the highest tag.

The tag ladder is the only source of truth: this script reads tags and commit subjects,
never a version file, so the number cannot drift from what was released.

No release is ever cut twice for the same commit: if HEAD already carries a `v*` tag
the answer is `SKIP`, which makes a re-run of the workflow - or a duplicate push
delivery - a no-op instead of a duplicate release.

Usage
  scripts/release_version.py                  # print the next tag, e.g. v0.71.0
  scripts/release_version.py --format json    # {"current":..., "next":..., "bump":...}
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

# `feat: x`, `feat(scope): x`, `feat!: x`, `feat(scope)!: x` - the type is what counts.
SUBJECT_RE = re.compile(r"^(?P<type>[A-Za-z][A-Za-z0-9_-]*)(?:\([^)]*\))?(?P<bang>!)?:")
BREAKING_LINE_RE = re.compile(r"^BREAKING[ -]CHANGE:", re.MULTILINE)


def parse_tag(tag: str) -> tuple[int, int, int] | None:
    """`v1.2.3` -> (1, 2, 3). Pre-release/build suffixes are dropped; junk is ignored."""
    m = re.match(r"^v(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$", tag.strip())
    if not m:
        return None
    return int(m.group(1)), int(m.group(2)), int(m.group(3))


def bump_from_commits(commits: list[tuple[str, str]]) -> str:
    """'minor' or 'patch', from the commits in the range being released.

    `commits` is [(subject, body)]. A breaking marker or a `feat` anywhere in the range
    wins, because the version has to describe everything between the two tags: a push of
    three commits where one is a feat is one minor release, not three releases.
    """
    bump = "patch"
    for subject, body in commits:
        m = SUBJECT_RE.match(subject.strip())
        if m and m.group("bang"):
            return "minor"
        if BREAKING_LINE_RE.search(body or ""):
            return "minor"
        if m and m.group("type").lower() == "feat":
            bump = "minor"
    return bump


def next_version(tags: list[str], head_tags: list[str] | None = None,
                 commits: list[tuple[str, str]] | None = None) -> str:
    """Next tag for HEAD - SKIP when HEAD is already released."""
    head_tags = head_tags or []
    commits = commits or []
    if any(parse_tag(t) for t in head_tags):
        return "SKIP"
    parsed = [p for p in (parse_tag(t) for t in tags) if p]
    if not parsed:
        return "v0.1.0"  # first release
    major, minor, patch = max(parsed)
    if bump_from_commits(commits) == "minor":
        return f"v{major}.{minor + 1}.0"
    return f"v{major}.{minor}.{patch + 1}"


def latest(tags: list[str]) -> str | None:
    parsed = [(parse_tag(t), t) for t in tags if parse_tag(t)]
    if not parsed:
        return None
    return max(parsed)[1]


def git(*args: str) -> tuple[int, str]:
    r = subprocess.run(["git", *args], capture_output=True, text=True)
    return r.returncode, r.stdout.strip()


def range_commits(base: str | None) -> list[tuple[str, str]]:
    """[(subject, body)] for `base..HEAD`, or all of HEAD when there is no base tag."""
    sep = "\x1e"
    args = ["log", "--format=%s%x1f%b" + sep]
    args.append(f"{base}..HEAD" if base else "HEAD")
    rc, out = git(*args)
    if rc != 0:
        return []
    commits = []
    for record in out.split(sep):
        record = record.strip("\n")
        if not record:
            continue
        subject, _, body = record.partition("\x1f")
        commits.append((subject.strip(), body.strip()))
    return commits


def self_test() -> int:
    cases = [
        ([], [], [], "v0.1.0", "no tags at all -> first release"),
        (["v0.1.4"], [], [("feat: a thing", "")], "v0.2.0", "feat -> minor, patch reset"),
        (["v0.1.4"], [], [("fix: a thing", "")], "v0.1.5", "fix -> patch"),
        (["v0.1.4"], [], [("docs: a thing", "")], "v0.1.5", "docs -> patch (still a release)"),
        (["v0.1.4"], [], [("chore(deps): bump", "")], "v0.1.5", "scoped chore -> patch"),
        (["v0.1.4"], [], [("docs: a", ""), ("fix: b", ""), ("feat: c", "")],
         "v0.2.0", "any feat in the range -> minor"),
        (["v0.1.4"], [], [("fix!: drop the old API", "")], "v0.2.0", "breaking ! -> minor on 0.x"),
        (["v0.1.4"], [], [("feat(calls)!: new engine", "")], "v0.2.0", "scoped breaking feat"),
        (["v0.1.4"], [], [("fix: a", "BREAKING CHANGE: gone")],
         "v0.2.0", "BREAKING CHANGE trailer -> minor"),
        (["v0.1.4"], [], [("Merge branch 'x'", "")], "v0.1.5", "merge commit -> patch"),
        (["v0.1.4"], [], [("untyped subject", "")], "v0.1.5", "untyped -> patch, never a skip"),
        (["v1.9.9"], [], [("feat: x", "")], "v1.10.0", "minor passes 9 without touching major"),
        (["v0.1.4", "garbage", "1.2.3", "release-7"], [], [("fix: x", "")],
         "v0.1.5", "junk tags ignored"),
        (["v0.1.4", "v0.2.0-rc1"], [], [("feat: x", "")], "v0.3.0",
         "pre-release suffix dropped from the ladder"),
        (["v0.1.4"], ["v0.1.4"], [("feat: x", "")], "SKIP", "HEAD already released"),
        (["v0.1.4"], ["nope"], [("fix: x", "")], "v0.1.5",
         "non-release tag on HEAD does not skip"),
        (["v0.10.0"], [], [("fix: x", "")], "v0.10.1", "numeric not lexical (0.10 > 0.9)"),
        (["v0.70.9"], [], [("docs: x", "")], "v0.70.10", "patch passes 9 within the minor"),
        (["v0.70.9"], [], [("feat: x", "")], "v0.71.0", "minor always clears the patch"),
    ]
    fails = 0
    for tags, head, commits, want, why in cases:
        got = next_version(tags, head, commits)
        ok = got == want
        subjects = [c[0].splitlines()[0] for c in commits]
        print(f"  [{'PASS' if ok else 'FAIL'}] {why:<44} {tags or '[]'} + {subjects or '[]'}"
              f" -> {got}" + ("" if ok else f" (want {want})"))
        if not ok:
            fails += 1
    # Monotonic by construction: for every case that is not SKIP, the answer is strictly
    # greater than the highest tag given. Assert it rather than assume it.
    for tags, head, commits, want, _why in cases:
        if want == "SKIP" or not tags:
            continue
        highest = max(p for p in (parse_tag(t) for t in tags) if p)
        got = parse_tag(next_version(tags, head, commits))
        if got is None or got <= highest:
            print(f"  [FAIL] not monotonic: {tags} -> {got} (highest {highest})")
            fails += 1
    print(f"  [{'PASS' if fails == 0 else 'FAIL'}] monotonic: every answer is above the highest tag")
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

    base = latest(tags)
    commits = range_commits(base)
    nxt = next_version(tags, head_tags, commits)
    bump = bump_from_commits(commits) if nxt != "SKIP" else "skip"

    if args.dry_run:
        print(f"current={base or '(none)'} head_tags={head_tags or '[]'} "
              f"bump={bump} commits={len(commits)} next={nxt}", file=sys.stderr)

    if args.format == "json":
        print(json.dumps({"current": base, "next": None if nxt == "SKIP" else nxt,
                          "skip": nxt == "SKIP", "bump": bump,
                          "commits": len(commits), "head_tags": head_tags}))
    else:
        print(nxt)
    return 0


if __name__ == "__main__":
    sys.exit(main())
