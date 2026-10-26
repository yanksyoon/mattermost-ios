#!/usr/bin/env python3
"""Build release notes from the commits since the previous tag.

GitHub's own `--generate-notes` produced only a compare link for this repo, because
every commit is a direct push with no pull requests attached. That is a release note
that tells nobody anything. This script groups the real commit subjects by their
Conventional Commit type instead, which is how this repo already writes them.

Usage
  scripts/release_notes.py --from v0.1.4 --to HEAD   # markdown to stdout
  scripts/release_notes.py                        # previous tag -> HEAD, auto-detected
  scripts/release_notes.py --self-test            # prove the grouping

Exit: 0 ok, 1 no commits / bad range, 2 not a git repo.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys

# Conventional Commit type -> (heading, order). Anything unrecognised goes to Other.
GROUPS = {
    "feat": ("Features", 1),
    "fix": ("Fixes", 2),
    "perf": ("Performance", 3),
    "refactor": ("Refactoring", 4),
    "build": ("Build and release", 5),
    "test": ("Tests", 6),
    "docs": ("Documentation", 7),
    "ci": ("CI", 8),
    "chore": ("Chores", 9),
}
OTHER = ("Other", 99)

SUBJECT_RE = re.compile(r"^(?P<type>[a-z]+)(?:\((?P<scope>[^)]*)\))?(?P<bang>!)?:\s*(?P<rest>.+)$")


def classify(subject: str) -> tuple[str, str]:
    """Return (heading, line) for one commit subject."""
    m = SUBJECT_RE.match(subject.strip())
    if not m:
        return OTHER[0], subject.strip()
    typ = m.group("type")
    scope = m.group("scope")
    bang = "!" if m.group("bang") else ""
    rest = m.group("rest").strip()
    if scope:
        line = f"**{scope}{bang}:** {rest}"
    else:
        line = f"{bang}{rest}".lstrip(": ").strip()
        if bang:
            line = f"**breaking:** {rest}"
    heading = GROUPS.get(typ, OTHER)[0]
    return heading, line


def render(subjects: list[str], prev: str | None, to: str, repo: str | None = None) -> str:
    if not subjects:
        return (f"No commits between {prev or 'the start'} and {to}.\n")
    buckets: dict[str, list[str]] = {}
    prs: list[tuple[str, str]] = []
    for s in subjects:
        heading, line = classify(s)
        buckets.setdefault(heading, []).append(line)
        for num in dict.fromkeys(re.findall(r"#(\d+)", s)):
            title = re.sub(r"\s*\(#\d+\)\s*$", "", s).strip()
            prs.append((num, title))

    order = {name: rank for name, rank in GROUPS.values()}
    headings = sorted(buckets, key=lambda h: (order.get(h, OTHER[1]), h))

    out = []
    total = len(subjects)
    for h in headings:
        out.append(f"### {h}\n")
        out.extend(f"- {line}" for line in buckets[h])
        out.append("")
    if prs:
        out.append("### Pull requests\n")
        for num, title in prs:
            if repo:
                out.append(f"- [#{num}](https://github.com/{repo}/pull/{num}) — {title}")
            else:
                out.append(f"- #{num} — {title}")
        out.append("")
    if prev:
        out.append(f"**{total} commit{'s' if total != 1 else ''}** since `{prev}`.")
    else:
        out.append(f"**{total} commit{'s' if total != 1 else ''}** to `{to}`.")
    return "\n".join(out).rstrip() + "\n"


def git(*args: str) -> tuple[int, str]:
    r = subprocess.run(["git", *args], capture_output=True, text=True)
    return r.returncode, r.stdout.strip()


def subjects_between(prev: str | None, to: str) -> list[str]:
    rng = f"{prev}..{to}" if prev else to
    rc, out = git("log", "--no-merges", "--pretty=%s", rng)
    if rc != 0:
        return []
    return [line for line in out.splitlines() if line.strip()]


def self_test() -> int:
    cases = [
        (["feat(native): channel sidebar", "fix: cookie outranks header"],
         ["### Features", "**native:** channel sidebar", "### Fixes", "- cookie outranks header"],
         "types grouped, scope bolded"),
        (["build(release): cut a release on push"],
         ["### Build and release", "**release:** cut a release on push"],
         "build is not Other"),
        (["random subject with no prefix"],
         ["### Other", "- random subject with no prefix"],
         "unprefixed lands in Other"),
        (["feat!: drop the webview"],
         ["### Features", "**breaking:** drop the webview"],
         "breaking marker survives"),
        (["docs: typo", "feat: real feature"],
         ["### Features", "### Documentation"],
         "Features sorts above Documentation"),
        ([], ["No commits"], "empty range says so, does not print nothing"),
        (["feat(search): saved posts (#42)"],
         ["### Pull requests", "[#42](https://github.com/o/r/pull/42)", "**search:** saved posts"],
         "PR reference becomes a linked entry"),
        (["fix: no pr here"],
         ["### Fixes"], "no Pull requests section without a PR reference",
         ["### Pull requests"]),
    ]
    fails = 0
    for case in cases:
        subs, expect, why = case[0], case[1], case[2]
        absent = case[3] if len(case) > 3 else []
        got = render(subs, "v0.1.0", "HEAD", repo="o/r")
        missing = [e for e in expect if e not in got]
        found = [a for a in absent if a in got]
        if missing or found:
            fails += 1
            print(f"  [FAIL] {why}: missing={missing} unexpected={found}")
        else:
            if why.startswith("Features sorts") and got.index("### Features") > got.index("### Documentation"):
                fails += 1
                print(f"  [FAIL] {why}: wrong order")
            else:
                print(f"  [PASS] {why}")
    print("SELF-TEST: PASS" if fails == 0 else f"SELF-TEST: FAIL {fails}")
    return 0 if fails == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--from", dest="prev", default=None)
    ap.add_argument("--to", dest="to", default="HEAD")
    ap.add_argument("--repo", default=None,
                    help="owner/name, so a PR reference (#123) becomes a link")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    rc, _ = git("rev-parse", "--git-dir")
    if rc != 0:
        print("not a git repository", file=sys.stderr)
        return 2

    prev = args.prev
    if prev is None:
        rc, out = git("describe", "--tags", "--abbrev=0", f"{args.to}^")
        prev = out if rc == 0 and out else None

    if prev:
        rc, _ = git("rev-parse", "--verify", prev)
        if rc != 0:
            print(f"unknown tag {prev}", file=sys.stderr)
            return 1

    subs = subjects_between(prev, args.to)
    sys.stdout.write(render(subs, prev, args.to, repo=args.repo))
    return 0 if subs else 1


if __name__ == "__main__":
    sys.exit(main())
