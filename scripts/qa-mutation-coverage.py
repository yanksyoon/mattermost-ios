#!/usr/bin/env python3
"""Coverage check: every test body this card touched must be redded by a product mutant.

A test the harness *touched* is any `test…` function enclosing a changed hunk between `--base` and
`HEAD`; coverage is the union of the `red:` lists of the PASS rows in the mutations log (a mutant
often reds more than its manifest names). `qa_mutants.MUTANTS` is imported rather than scraped, so
the check reads the same definitions the harness runs.

  python3 scripts/qa-mutation-coverage.py --base f833459
"""
import argparse
import importlib.util
import re
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]

ap = argparse.ArgumentParser()
ap.add_argument("--base", default="f833459", help="commit before this card's change")
ap.add_argument("--sim-log", default="docs/t_00fb623c-mutations-2026-10-27.log")
args = ap.parse_args()
repo = str(REPO)
diff = subprocess.run(["git", "diff", f"{args.base}..HEAD", "--unified=0"], cwd=repo,
                      capture_output=True, text=True).stdout

touched = {}
cur = None
for line in diff.splitlines():
    if line.startswith("+++ b/"):
        cur = line[6:]
        continue
    m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@", line)
    if m and cur and cur.startswith("MattermostTests/"):
        start = int(m.group(1))
        src = open(f"{repo}/{cur}").read().splitlines()
        name = None
        for i in range(min(start, len(src)) - 1, -1, -1):
            f = re.search(r"func (test\w+)\(", src[i])
            if f:
                name = f.group(1)
                break
        if name:
            touched.setdefault(cur, set()).add(name)

spec = importlib.util.spec_from_file_location("qa_mutants", f"{repo}/scripts/qa-mutants.py")
rm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rm)

must = {}
for mid, note, classes, must_red, edits in rm.MUTANTS:
    for n in must_red:
        must.setdefault(n, []).append(mid)

allt = set().union(*touched.values())
print(f"touched files: {len(touched)}   touched tests: {len(allt)}")
print(f"covered by a mutant must_red: {len(allt & set(must))}")

# Observed coverage: the later rows in the mutations log supersede earlier ones for the same id, so
# read every `PASS` row's `red:` list (a mutant redded more than its manifest names, e.g. ML1).
observed = {}
mid = None
for line in open(f"{repo}/{args.sim_log}"):
    line = line.rstrip("\n")
    if line.startswith("### "):
        parts = line[4:].split()
        mid = parts[0]
        verdict = parts[1] if len(parts) > 1 else "?"
        if verdict != "PASS":
            mid = None
        elif mid:
            observed[mid] = []
    elif mid and line.startswith("red: "):
        observed[mid] = [x.strip() for x in line[5:].split(",") if x.strip()]

reds = {n for v in observed.values() for n in v}
print(f"observed red coverage (union of PASS rows): {len(allt & reds)}")
print("\nUNCOVERED (touched test that no PASS mutant reds):")
for t in sorted(allt - reds):
    print("  ", t)
print(f"\nmutants: {len(rm.MUTANTS)}   PASS rows: {len(observed)}")
