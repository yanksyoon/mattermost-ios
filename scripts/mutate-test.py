#!/usr/bin/env python3
"""scripts/mutate-test.py — mutation certification for the parity checker.

The six detectors in parity/generate.py are mutated as DATA (scripts/mutants/*.diff), each applied to
a throwaway copy in isolation. A mutant must make its own planted fault stop firing, and must leave
the other five working — that is the *sensitivity* property a self-authored assert cannot supply
(design appendix, "verification design", item 3).

    python3 scripts/mutate-test.py            # all mutants
    python3 scripts/mutate-test.py stale      # one, by name

Exit 1 if any mutant survives (the self-test still passes) or fails the wrong way. No network.
"""

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MUTANT_DIR = os.path.join(HERE, "mutants")

# diff name -> the fault the mutation is supposed to blind
EXPECTED = {
    "stale.diff": "STALE",
    "orphan.diff": "ORPHAN",
    "unmapped.diff": "UNMAPPED",
    "stale_verdict.diff": "STALE-VERDICT",
    "stale_evidence.diff": "STALE-EVIDENCE",
    "approved_without_verdict.diff": "APPROVED-WITHOUT-VERDICT",
}


def run_mutant(diff_path, fault):
    work = tempfile.mkdtemp(prefix="parity-mutant-")
    try:
        os.makedirs(os.path.join(work, "parity"))
        shutil.copy(os.path.join(ROOT, "parity/generate.py"), os.path.join(work, "parity/generate.py"))
        applied = subprocess.run(["patch", "-p1", "-s", "-i", diff_path], cwd=work,
                                 capture_output=True, text=True)
        if applied.returncode != 0:
            return False, "patch did not apply: %s" % (applied.stderr.strip() or applied.stdout.strip())
        proc = subprocess.run([sys.executable, os.path.join(work, "parity/generate.py"), "--self-test"],
                              cwd=work, capture_output=True, text=True)
        out = proc.stdout + proc.stderr
        blind = [line for line in out.splitlines() if "did not fire" in line]
        if proc.returncode == 0:
            return False, "SURVIVED — the mutated self-test still passes"
        if not blind:
            return False, "failed for the wrong reason (no 'did not fire' line): %s" % (out.strip().splitlines() or [""])[-1]
        if len(blind) != 1:
            return False, "killed more than one detector: %s" % "; ".join(blind)
        if ("fault %s did not fire" % fault) not in blind[0]:
            return False, "killed the wrong detector: %s" % blind[0]
        return True, "killed: %s" % blind[0].strip()
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main(argv):
    if not os.path.isdir(MUTANT_DIR):
        print("[FAIL] no mutants directory at %s" % MUTANT_DIR)
        return 1
    wanted = set(argv)
    names = sorted(n for n in os.listdir(MUTANT_DIR) if n.endswith(".diff"))
    if wanted:
        names = [n for n in names if n in wanted]
    if not names:
        print("[FAIL] no mutant matched %r" % argv)
        return 1
    failures = []
    for name in names:
        fault = EXPECTED.get(name)
        if not fault:
            failures.append("%s: no expected fault declared" % name)
            continue
        ok, why = run_mutant(os.path.join(MUTANT_DIR, name), fault)
        print("%-32s %-26s %s %s" % (name, fault, "PASS" if ok else "FAIL", why))
        if not ok:
            failures.append("%s: %s" % (name, why))
    if failures:
        for line in failures:
            print("[FAIL] mutate-test: %s" % line)
        return 1
    print("mutate-test: PASS — %d/%d detectors are individually load-bearing" % (len(names), len(names)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
