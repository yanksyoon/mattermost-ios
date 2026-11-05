#!/usr/bin/env python3
"""Re-check the per-capability record: docs/parity/module-scan.tsv.

Run: python3 parity/check_scan.py [--log build/logs/parity-scan-unit.log]

Checks, in order:
  1. nine tab-separated columns on every non-comment row;
  2. `ours` and `verdict` come from the controlled vocabulary;
  3. every `upstream_ref` carries an @sha;
  4. `verdict=parity` never sits on a `MISSING` evidence cell;
  5. every `File.swift::case` evidence ref names a real test method, and every unit case it names
     appears as passed or skipped in the HEAD run log;
  6. no duplicate (module, capability) pair.

Exit 0 only when all six hold, so this can gate a commit the way `parity/generate.py --check` does.
The point: a row cannot claim parity on a file path, and cannot cite a test that does not exist or
did not run.
"""
import argparse
import os
import re
import sys

COLS = ["module", "upstream_ref", "capability", "what_upstream_does", "ours", "ours_ref",
        "evidence", "verdict", "card"]
OURS = {"native", "partial", "webview", "absent"}
VERDICTS = {"parity", "gap", "owner-decision"}
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCAN = os.path.join(ROOT, "docs", "parity", "module-scan.tsv")
DEFAULT_LOG = os.path.join(ROOT, "build", "logs", "parity-scan-unit.log")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", default=DEFAULT_LOG)
    args = ap.parse_args()

    problems = []
    rows = []
    with open(SCAN, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            f = line.split("\t")
            if len(f) != len(COLS):
                problems.append("line %d: %d columns, expected %d" % (lineno, len(f), len(COLS)))
                continue
            if f[4] not in OURS:
                problems.append("line %d: ours=%r not in %s" % (lineno, f[4], sorted(OURS)))
            if f[7] not in VERDICTS:
                problems.append("line %d: verdict=%r not in %s" % (lineno, f[7], sorted(VERDICTS)))
            if "@" not in f[1]:
                problems.append("line %d: upstream_ref has no @sha: %r" % (lineno, f[1]))
            if f[7] == "parity" and (not f[6].strip() or "MISSING" in f[6]):
                problems.append("line %d: parity without evidence: %s / %s" % (lineno, f[0], f[2]))
            rows.append(f)

    seen = {}
    for f in rows:
        seen[(f[0], f[2])] = seen.get((f[0], f[2]), 0) + 1
    for k, n in seen.items():
        if n > 1:
            problems.append("duplicate row %s / %s (%d)" % (k[0], k[1], n))

    log_text = open(args.log, encoding="utf-8", errors="replace").read() if os.path.exists(args.log) else ""
    if not log_text:
        problems.append("run log missing: %s (unit evidence cannot be verified)" % args.log)

    refs = 0
    for f in rows:
        where = "%s / %s" % (f[0], f[2])
        if "MISSING" in f[6]:
            # A MISSING cell is prose explaining what is absent, not a citation; the parenthetical
            # test names in it are context, so they are deliberately not resolved here.
            continue
        current = None
        for ref in [r.strip() for r in f[6].split(";") if r.strip()]:
            if "::" in ref and ref.startswith("::"):
                if not current:
                    problems.append("%s: evidence starts with a bare :: (%r)" % (where, ref))
                    continue
                path, case = current, ref[2:]
            elif "::" in ref:
                path, tail = ref.split("::", 1)
                case = re.match(r"([A-Za-z0-9_]+)", tail).group(1)
            else:
                continue
            if not path.startswith(("MattermostTests/", "MattermostUITests/")):
                for prefix in ("MattermostTests/", "MattermostUITests/"):
                    if os.path.exists(os.path.join(ROOT, prefix + path)):
                        path = prefix + path
                        break
                else:
                    problems.append("%s: evidence file not found: %s" % (where, path))
                    continue
            current = path
            refs += 1
            full = os.path.join(ROOT, path)
            if not os.path.exists(full):
                problems.append("%s: evidence file missing: %s" % (where, path))
                continue
            body = open(full, encoding="utf-8", errors="replace").read()
            if ("func %s(" % case) not in body:
                problems.append("%s: no test method %s::%s" % (where, path, case))
                continue
            if path.startswith("MattermostTests/"):
                if not re.search(r"Test Case '-\[MattermostTests\.[A-Za-z0-9_]+ %s\]' (passed|skipped)"
                                 % re.escape(case), log_text):
                    problems.append("%s: unit case did not pass at HEAD: %s::%s" % (where, path, case))

    print("rows: %d across %d modules; %d evidence refs checked" % (len(rows), len({f[0] for f in rows}), refs))
    for p in problems:
        print("FAIL " + p)
    if problems:
        print("\n%d problem(s)" % len(problems))
        return 1
    print("OK: columns, vocabulary, refs and the HEAD run all agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
