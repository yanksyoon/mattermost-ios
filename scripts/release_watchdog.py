#!/usr/bin/env python3
"""Report "nothing was released in 24 h" - as a report, never as a pause.

The defect this exists for (card t_6904c92b): `main` received no push for five days while
44 commits sat on a QA branch, so the release pipeline had nothing to run and nobody
noticed. The rule that prevents the drift lives in the worker's own skill; this is the
check that notices when it happens anyway.

It is a *report*: a scheduled workflow that writes a summary line and an annotation, and
exits 1 only when there is something to act on. It does not pause dispatch, cancel runs or
touch any scheduler - `hermes pause` halts the very scheduler that would have resumed the
work, which is how a three-day outage happened once already.

What it asks, read-only, through the GitHub API:
  * when was the last release published, and how old is it?
  * does `main` carry commits that are not in that release?

Verdicts:
  OK       a release was published within the window
  QUIET    nothing released in the window, but `main` has not moved - nothing to release.
           Printed, not failed: a quiet repository is not a broken pipeline.
  STALE    nothing released in the window AND `main` has moved - the exact shape of the
           five-day gap. This exits 1: the report is the alarm.

Usage
  scripts/release_watchdog.py --repo owner/name
  scripts/release_watchdog.py --repo owner/name --max-age-hours 24 --summary "$GITHUB_STEP_SUMMARY"
  scripts/release_watchdog.py --self-test

Exit: 0 ok/quiet, 1 stale, 2 cannot tell (API failure - never silently "ok").
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone


def gh_api(path: str) -> dict:
    """One read-only API call through `gh`, which carries the token in CI."""
    r = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"gh api {path} failed ({r.returncode}): {r.stderr.strip()[:300]}")
    return json.loads(r.stdout)


def parse_time(value: str) -> datetime:
    return datetime.strptime(value.replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S%z")


def verdict(release: dict | None, main_sha: str | None, now: datetime,
            max_age_hours: float) -> tuple[str, str]:
    """('OK'|'QUIET'|'STALE', one sentence). Pure, so the self-test can prove each case."""
    if not release:
        return "STALE", "no release exists at all"
    published = release.get("published_at") or release.get("created_at")
    if not published:
        return "STALE", f"release {release.get('tag_name')} has no published_at timestamp"
    age_h = (now - parse_time(published)).total_seconds() / 3600.0
    tag = release.get("tag_name", "?")
    if age_h <= max_age_hours:
        return "OK", f"last release {tag} was published {age_h:.1f} h ago (window {max_age_hours:g} h)"
    if main_sha and release.get("target_sha") and main_sha != release["target_sha"]:
        return "STALE", (f"no release in {age_h:.1f} h (last: {tag}) and main has moved since "
                         f"it (main {main_sha[:8]}, released {release['target_sha'][:8]}) - "
                         f"pushes are not reaching main, or the pipeline is not publishing")
    return "QUIET", (f"no release in {age_h:.1f} h (last: {tag}), but main has not moved "
                     f"since it - nothing to release, not a broken pipeline")


def summary_markdown(verdict_word: str, sentence: str, release: dict | None,
                     main_sha: str | None) -> str:
    rows = ["### release watchdog", "", f"- verdict: **{verdict_word}**", f"- {sentence}"]
    if release:
        rows.append(f"- last release: `{release.get('tag_name')}` "
                    f"({release.get('published_at')}) -> {release.get('html_url', '')}")
    if main_sha:
        rows.append(f"- main: `{main_sha[:8]}`")
    rows.append("- This is a scheduled report. It does not pause dispatch or cancel runs.")
    return "\n".join(rows) + "\n"


def self_test() -> int:
    now = parse_time("2026-11-09T12:00:00Z")
    cases = [
        ({"tag_name": "v0.71.0", "published_at": "2026-11-09T06:00:00Z",
          "target_sha": "a" * 40}, "a" * 40, "OK", "6 h old release"),
        ({"tag_name": "v0.71.0", "published_at": "2026-11-09T06:00:00Z",
          "target_sha": "a" * 40}, "b" * 40, "OK", "recent release, main moved after it"),
        ({"tag_name": "v0.70.0", "published_at": "2026-11-04T04:37:54Z",
          "target_sha": "a" * 40}, "b" * 40, "STALE", "5 days stale + main moved (the real gap)"),
        ({"tag_name": "v0.70.0", "published_at": "2026-11-04T04:37:54Z",
          "target_sha": "a" * 40}, "a" * 40, "QUIET", "stale but main has not moved"),
        (None, "b" * 40, "STALE", "no release at all"),
        ({"tag_name": "v0.71.0"}, "b" * 40, "STALE", "release without a timestamp"),
    ]
    fails = 0
    for release, main_sha, want, why in cases:
        got, sentence = verdict(release, main_sha, now, 24)
        ok = got == want
        print(f"  [{'PASS' if ok else 'FAIL'}] {why:<42} -> {got}"
              + ("" if ok else f" (want {want})") + f" | {sentence[:80]}")
        if not ok:
            fails += 1
    print(("SELF-TEST: PASS" if fails == 0 else f"SELF-TEST: FAIL {fails}"))
    return 0 if fails == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", help="owner/name")
    ap.add_argument("--max-age-hours", type=float, default=24.0)
    ap.add_argument("--summary", help="append the report here (usually $GITHUB_STEP_SUMMARY)")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()
    if not args.repo:
        print("::error::release_watchdog needs --repo", file=sys.stderr)
        return 2

    try:
        release = gh_api(f"repos/{args.repo}/releases/latest")
        tag_sha = None
        try:
            ref = gh_api(f"repos/{args.repo}/git/ref/tags/{release['tag_name']}")
            tag_sha = ref.get("object", {}).get("sha")
        except RuntimeError:
            tag_sha = None
        if tag_sha:
            release["target_sha"] = tag_sha
        main_sha = gh_api(f"repos/{args.repo}/commits/main").get("sha")
    except (RuntimeError, json.JSONDecodeError, KeyError) as exc:
        print(f"::error::release_watchdog cannot tell: {exc}", file=sys.stderr)
        return 2

    word, sentence = verdict(release, main_sha, datetime.now(timezone.utc), args.max_age_hours)
    line = f"release watchdog: {word} - {sentence}"
    if word == "OK":
        print(f"::notice::{line}")
    elif word == "QUIET":
        print(f"::warning::{line}")
    else:
        print(f"::error::{line}")
    print(line)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as fh:
            fh.write(summary_markdown(word, sentence, release, main_sha))
    return 1 if word == "STALE" else 0


if __name__ == "__main__":
    sys.exit(main())
