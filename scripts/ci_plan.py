#!/usr/bin/env python3
"""Decide, in seconds, whether a push is worth macOS minutes.

The release pipeline used to discover "somebody pushed after me" only in the *release*
job — after two full test legs and the package build had already run. Run 40339556034
burned ~8 macOS minutes on a commit that was already superseded, and the operator
cancelled it by hand; a cancelled run renders red, which is why a working pipeline
looked broken. See docs/releasing.md ("Stage 0 — guard").

This script is the decision, separated from the workflow so it can be tested. The
workflow's guard job feeds it three facts (HEAD, the current tip of main, and the list
of paths the push touched) and gates every macOS job on the answer.

Policy, decided and recorded in docs/releasing.md:

  * not the tip of main          -> run nothing (the tip run cuts the release)
  * the tip, documentation only  -> skip the test legs, still release and still package
  * the tip, anything else       -> test everything, then release, then package

"Documentation only" means every changed path is under `docs/` or ends in `.md`. A
change to `.github/workflows/` or `scripts/` is never documentation even when the file
is prose, because those files *are* the pipeline.

Refusing to guess is part of the contract: an unreadable/absent SHA, or a changed-file
list nobody supplied, is an error (exit 2) or a conservative "test everything" — never a
silent "nothing to do". That is the F2 lesson from run 40332873749, where a retry loop
turned a hard failure into a green run with nothing published.

Usage
  python3 scripts/ci_plan.py --head <sha> --tip <sha> --changed-files <file> --format json
  python3 scripts/ci_plan.py --head <sha> --tip <sha> --changed-files - --format github-env
  python3 scripts/ci_plan.py --self-test

Exit: 0 decided, 2 cannot tell (the caller must fail, not proceed).
"""

from __future__ import annotations

import argparse
import json
import re
import sys

SHA_RE = re.compile(r"^[0-9a-f]{40}$")
DOC_PREFIX = "docs/"
DOC_SUFFIX = ".md"


class CannotTell(Exception):
    """The inputs do not support a decision. Never downgrade this to "run nothing"."""


def is_documentation(path: str) -> bool:
    p = path.strip()
    if not p:
        return False
    return p.startswith(DOC_PREFIX) or p.lower().endswith(DOC_SUFFIX)


def decide(head: str, tip: str, changed: list[str]) -> dict[str, object]:
    head = (head or "").strip().lower()
    tip = (tip or "").strip().lower()
    if not SHA_RE.match(head):
        raise CannotTell(f"HEAD is not a 40-hex commit sha: {head!r}")
    if not SHA_RE.match(tip):
        raise CannotTell(f"the tip of main is not a 40-hex commit sha: {tip!r}")

    paths = [p for p in (s.strip() for s in changed) if p]
    is_tip = head == tip

    if not is_tip:
        return {
            "is_tip": False,
            "docs_only": bool(paths) and all(is_documentation(p) for p in paths),
            "run_tests": False,
            "reason": f"superseded: {head[:8]} is not the tip of main ({tip[:8]})",
        }

    if not paths:
        # No diff range (first push, force-push, dispatch). Conservative: test.
        return {
            "is_tip": True,
            "docs_only": False,
            "run_tests": True,
            "reason": "tip of main; changed files unknown, testing everything",
        }

    docs_only = all(is_documentation(p) for p in paths)
    if docs_only:
        reason = (f"tip of main; documentation only ({len(paths)} file(s)), "
                  f"test legs skipped, release still cut")
    else:
        source = [p for p in paths if not is_documentation(p)]
        reason = (f"tip of main; {len(paths)} file(s) changed, "
                  f"{len(source)} of them not documentation")
    return {"is_tip": True, "docs_only": docs_only, "run_tests": not docs_only,
            "reason": reason}


def render(plan: dict[str, object], fmt: str) -> str:
    if fmt == "json":
        return json.dumps(plan, indent=2, sort_keys=True)
    if fmt in ("env", "github-env"):
        lines = []
        for key, value in plan.items():
            name = key if fmt == "github-env" else key.upper()
            lines.append(f"{name}={'true' if value is True else 'false' if value is False else value}")
        return "\n".join(lines)
    raise CannotTell(f"unknown format {fmt!r}")


def summary_markdown(plan: dict[str, object], head: str, tip: str) -> str:
    verdict = "run the full pipeline" if plan["run_tests"] else "no macOS work"
    rows = [
        "### release guard",
        "",
        f"- HEAD: `{head[:8]}`",
        f"- tip of main: `{tip[:8]}`",
        f"- decision: **{verdict}** — {plan['reason']}",
    ]
    if plan["is_tip"] and not plan["run_tests"]:
        rows.append("- the test legs are skipped by policy; the release and the package "
                    "job still run, so a docs-only push is tagged and downloadable.")
    if not plan["is_tip"]:
        rows.append("- nothing runs here; the tip run is the one that releases.")
    return "\n".join(rows) + "\n"


def read_changed(source: str) -> list[str]:
    if source == "-":
        return sys.stdin.read().splitlines()
    try:
        with open(source, "r", encoding="utf-8") as fh:
            return fh.read().splitlines()
    except OSError as exc:
        raise CannotTell(f"cannot read the changed-file list {source!r}: {exc}") from exc


# ---------------------------------------------------------------------------------
# self-test
# ---------------------------------------------------------------------------------
A = "a" * 40
B = "b" * 40


def self_test() -> int:
    failures = 0
    checks = 0

    def expect(desc: str, got, want) -> None:
        nonlocal failures, checks
        checks += 1
        if got == want:
            print(f"  [PASS] {desc}")
        else:
            failures += 1
            print(f"  [FAIL] {desc}\n         got  {got!r}\n         want {want!r}")

    print("ci_plan self-test\n")

    print("== T1 not the tip: nothing runs ==")
    p = decide(A, B, ["Mattermost/App.swift"])
    expect("T1 is_tip is False", p["is_tip"], False)
    expect("T1 run_tests is False", p["run_tests"], False)
    expect("T1 says why", "not the tip of main" in str(p["reason"]), True)

    print("\n== T2 not the tip, docs only: still nothing ==")
    p = decide(A, B, ["docs/releasing.md"])
    expect("T2 run_tests is False", p["run_tests"], False)

    print("\n== T3 tip, source change: full pipeline ==")
    p = decide(A, A, ["Mattermost/Core/SecretStore.swift", "docs/x.md"])
    expect("T3 is_tip is True", p["is_tip"], True)
    expect("T3 run_tests is True", p["run_tests"], True)
    expect("T3 docs_only is False", p["docs_only"], False)

    print("\n== T4 tip, documentation only: skip tests ==")
    p = decide(A, A, ["docs/releasing.md", "docs/installing.md", "README.md"])
    expect("T4 run_tests is False", p["run_tests"], False)
    expect("T4 docs_only is True", p["docs_only"], True)
    expect("T4 still the tip (so it may release)", p["is_tip"], True)
    expect("T4 reason mentions the skip", "test legs skipped" in str(p["reason"]), True)

    print("\n== T5 docs/ with a non-markdown payload is still documentation ==")
    p = decide(A, A, ["docs/t40-channel-probe-2026-10-26.log", "docs/shots/a.png"])
    expect("T5 run_tests is False", p["run_tests"], False)

    print("\n== T6 a prose change to the pipeline is NOT documentation ==")
    for path in (".github/workflows/release.yml", "scripts/release_publish_selftest.sh"):
        p = decide(A, A, ["docs/a.md", path])
        expect(f"T6 run_tests is True when {path} changed", p["run_tests"], True)

    print("\n== T7 a markdown file outside docs/ is documentation ==")
    p = decide(A, A, ["CONTRIBUTING.md"])
    expect("T7 run_tests is False", p["run_tests"], False)

    print("\n== T8 no diff at all: test everything, never 'nothing to do' ==")
    p = decide(A, A, [])
    expect("T8 run_tests is True", p["run_tests"], True)
    expect("T8 docs_only is False", p["docs_only"], False)
    expect("T8 says why", "changed files unknown" in str(p["reason"]), True)

    print("\n== T9 blank lines do not make a push 'documentation only' ==")
    p = decide(A, A, ["", "Mattermost/App.swift"])
    expect("T9 run_tests is True", p["run_tests"], True)

    print("\n== T10 cannot tell: refuse instead of guessing ==")
    for desc, args in (("short HEAD", ("abc123", A, ["docs/a.md"])),
                       ("empty tip", (A, "", ["docs/a.md"])),
                       ("non-hex tip", (A, "z" * 40, ["docs/a.md"]))):
        checks += 1
        try:
            decide(*args)
            failures += 1
            print(f"  [FAIL] T10 {desc}: decided instead of refusing")
        except CannotTell as exc:
            print(f"  [PASS] T10 {desc}: refused ({exc})")

    print("\n== T11 the emitted env is what the workflow reads ==")
    p = decide(A, B, ["docs/a.md"])
    env = render(p, "github-env")
    expect("T11 emits is_tip=false", "is_tip=false" in env, True)
    expect("T11 emits run_tests=false", "run_tests=false" in env, True)
    p = decide(A, A, ["docs/a.md"])
    expect("T11 emits run_tests=false for docs-only", "run_tests=false" in render(p, "github-env"), True)
    expect("T11 json round-trips", json.loads(render(p, "json"))["docs_only"], True)

    print("\n== T12 the summary names the decision ==")
    md = summary_markdown(decide(A, B, ["docs/a.md"]), A, B)
    expect("T12 summary mentions 'no macOS work'", "no macOS work" in md, True)
    md = summary_markdown(decide(A, A, ["docs/a.md"]), A, A)
    expect("T12 docs-only summary promises the release", "still run" in md, True)

    print("\n== T13 a missing changed-file list is an error, not an assumption ==")
    checks += 1
    try:
        read_changed("/nonexistent/changed.txt")
        failures += 1
        print("  [FAIL] T13 read it anyway")
    except CannotTell:
        print("  [PASS] T13 refused a missing list")

    print("\n" + (f"SELF-TEST: PASS ({checks} checks, 13 cases)"
                  if failures == 0 else f"SELF-TEST: FAIL {failures} of {checks} checks"))
    return 0 if failures == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--head")
    ap.add_argument("--tip")
    ap.add_argument("--changed-files", help="file with one path per line, or - for stdin")
    ap.add_argument("--format", default="env", choices=("env", "github-env", "json"))
    ap.add_argument("--summary-file", help="append a markdown summary here ($GITHUB_STEP_SUMMARY)")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    if not args.head or not args.tip:
        print("::error::ci_plan needs --head and --tip (refusing to guess)", file=sys.stderr)
        return 2
    try:
        changed = read_changed(args.changed_files) if args.changed_files else []
        plan = decide(args.head, args.tip, changed)
        out = render(plan, args.format)
    except CannotTell as exc:
        print(f"::error::ci_plan cannot tell: {exc}", file=sys.stderr)
        return 2

    print(out)
    if args.summary_file:
        with open(args.summary_file, "a", encoding="utf-8") as fh:
            fh.write(summary_markdown(plan, args.head, args.tip))
    return 0


if __name__ == "__main__":
    sys.exit(main())
