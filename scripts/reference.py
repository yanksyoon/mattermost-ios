#!/usr/bin/env python3
"""scripts/reference.py — the hand-authored expected-output table (NOT generated from generate.py).

Provenance and rule: docs/parity-map-design.md §3.2 ("the status ladder (derived, never typed)").

The key of STATUS_TABLE is the fact tuple, in this order and no other:

    claim  path  test  ancestor  clean  evidence  approved

meaning exactly what the design says:

    claim       a claim row (or a `// parity:` comment) exists for the key
    path        at least one of the claim's native paths exists on disk
    test        at least one `<File>::<case>` test ref resolves to a real func
    ancestor    a verdict entry exists AND its commit is an ancestor of HEAD
    clean       no commit after the verdict commit touched the claimed files
    evidence    every verdict evidence[] ref resolves (a test ref must name a case)
    approved    the key's surface is in SurfaceDefaults.nativeApprovedSurfaces

evaluated in this order:

    not (claim and path)                     -> absent
    not (ancestor and clean and evidence)    -> tested if test else claimed
    otherwise                                -> native if approved else validated

The table itself was typed out from that paragraph, one row per world, 128 rows. It is deliberately
NOT derived from parity/generate.py: regenerating goldens from the implementation would make the
differential a tautology. Any diff to this file needs a second reviewer and a changelog line here.

CHANGELOG
  2026-11-05  initial table, authored from docs/parity-map-design.md §3.2 (t_e56d2589)
  2026-11-05  two rows corrected after scripts/differential.py disagreed: worlds
              `1 1 0 1 1 1 1` and `1 1 1 1 1 1 0`. The ladder is monotone (validated requires
              tested), so the first is `claimed` (a verdict cannot lift a key no test names) and the
              second is `validated`. Found by the differential, NOT by copying generate.py; the
              decision is recorded as Delta 5 of the design appendix. Still needs a second reviewer
              before the next edit.
"""

TABLE_ORDER = ("claim", "path", "test", "ancestor", "clean", "evidence", "approved")

# fmt: off
_STATUS_ROWS = [
    # claim=0 — no claim row and no co-located comment: absent, whatever else is true.
    (0, 0, 0, 0, 0, 0, 0, "absent"),
    (0, 0, 0, 0, 0, 0, 1, "absent"),
    (0, 0, 0, 0, 0, 1, 0, "absent"),
    (0, 0, 0, 0, 0, 1, 1, "absent"),
    (0, 0, 0, 0, 1, 0, 0, "absent"),
    (0, 0, 0, 0, 1, 0, 1, "absent"),
    (0, 0, 0, 0, 1, 1, 0, "absent"),
    (0, 0, 0, 0, 1, 1, 1, "absent"),
    (0, 0, 0, 1, 0, 0, 0, "absent"),
    (0, 0, 0, 1, 0, 0, 1, "absent"),
    (0, 0, 0, 1, 0, 1, 0, "absent"),
    (0, 0, 0, 1, 0, 1, 1, "absent"),
    (0, 0, 0, 1, 1, 0, 0, "absent"),
    (0, 0, 0, 1, 1, 0, 1, "absent"),
    (0, 0, 0, 1, 1, 1, 0, "absent"),
    (0, 0, 0, 1, 1, 1, 1, "absent"),
    (0, 0, 1, 0, 0, 0, 0, "absent"),
    (0, 0, 1, 0, 0, 0, 1, "absent"),
    (0, 0, 1, 0, 0, 1, 0, "absent"),
    (0, 0, 1, 0, 0, 1, 1, "absent"),
    (0, 0, 1, 0, 1, 0, 0, "absent"),
    (0, 0, 1, 0, 1, 0, 1, "absent"),
    (0, 0, 1, 0, 1, 1, 0, "absent"),
    (0, 0, 1, 0, 1, 1, 1, "absent"),
    (0, 0, 1, 1, 0, 0, 0, "absent"),
    (0, 0, 1, 1, 0, 0, 1, "absent"),
    (0, 0, 1, 1, 0, 1, 0, "absent"),
    (0, 0, 1, 1, 0, 1, 1, "absent"),
    (0, 0, 1, 1, 1, 0, 0, "absent"),
    (0, 0, 1, 1, 1, 0, 1, "absent"),
    (0, 0, 1, 1, 1, 1, 0, "absent"),
    (0, 0, 1, 1, 1, 1, 1, "absent"),
    (0, 1, 0, 0, 0, 0, 0, "absent"),
    (0, 1, 0, 0, 0, 0, 1, "absent"),
    (0, 1, 0, 0, 0, 1, 0, "absent"),
    (0, 1, 0, 0, 0, 1, 1, "absent"),
    (0, 1, 0, 0, 1, 0, 0, "absent"),
    (0, 1, 0, 0, 1, 0, 1, "absent"),
    (0, 1, 0, 0, 1, 1, 0, "absent"),
    (0, 1, 0, 0, 1, 1, 1, "absent"),
    (0, 1, 0, 1, 0, 0, 0, "absent"),
    (0, 1, 0, 1, 0, 0, 1, "absent"),
    (0, 1, 0, 1, 0, 1, 0, "absent"),
    (0, 1, 0, 1, 0, 1, 1, "absent"),
    (0, 1, 0, 1, 1, 0, 0, "absent"),
    (0, 1, 0, 1, 1, 0, 1, "absent"),
    (0, 1, 0, 1, 1, 1, 0, "absent"),
    (0, 1, 0, 1, 1, 1, 1, "absent"),
    (0, 1, 1, 0, 0, 0, 0, "absent"),
    (0, 1, 1, 0, 0, 0, 1, "absent"),
    (0, 1, 1, 0, 0, 1, 0, "absent"),
    (0, 1, 1, 0, 0, 1, 1, "absent"),
    (0, 1, 1, 0, 1, 0, 0, "absent"),
    (0, 1, 1, 0, 1, 0, 1, "absent"),
    (0, 1, 1, 0, 1, 1, 0, "absent"),
    (0, 1, 1, 0, 1, 1, 1, "absent"),
    (0, 1, 1, 1, 0, 0, 0, "absent"),
    (0, 1, 1, 1, 0, 0, 1, "absent"),
    (0, 1, 1, 1, 0, 1, 0, "absent"),
    (0, 1, 1, 1, 0, 1, 1, "absent"),
    (0, 1, 1, 1, 1, 0, 0, "absent"),
    (0, 1, 1, 1, 1, 0, 1, "absent"),
    (0, 1, 1, 1, 1, 1, 0, "absent"),
    (0, 1, 1, 1, 1, 1, 1, "absent"),

    # claim=1, path=0 — a claim that names nothing that exists: absent (and STALE when a path is
    # named-but-missing; "path" is false in both cases, the detector is find_row_findings' job).
    (1, 0, 0, 0, 0, 0, 0, "absent"),
    (1, 0, 0, 0, 0, 0, 1, "absent"),
    (1, 0, 0, 0, 0, 1, 0, "absent"),
    (1, 0, 0, 0, 0, 1, 1, "absent"),
    (1, 0, 0, 0, 1, 0, 0, "absent"),
    (1, 0, 0, 0, 1, 0, 1, "absent"),
    (1, 0, 0, 0, 1, 1, 0, "absent"),
    (1, 0, 0, 0, 1, 1, 1, "absent"),
    (1, 0, 0, 1, 0, 0, 0, "absent"),
    (1, 0, 0, 1, 0, 0, 1, "absent"),
    (1, 0, 0, 1, 0, 1, 0, "absent"),
    (1, 0, 0, 1, 0, 1, 1, "absent"),
    (1, 0, 0, 1, 1, 0, 0, "absent"),
    (1, 0, 0, 1, 1, 0, 1, "absent"),
    (1, 0, 0, 1, 1, 1, 0, "absent"),
    (1, 0, 0, 1, 1, 1, 1, "absent"),
    (1, 0, 1, 0, 0, 0, 0, "absent"),
    (1, 0, 1, 0, 0, 0, 1, "absent"),
    (1, 0, 1, 0, 0, 1, 0, "absent"),
    (1, 0, 1, 0, 0, 1, 1, "absent"),
    (1, 0, 1, 0, 1, 0, 0, "absent"),
    (1, 0, 1, 0, 1, 0, 1, "absent"),
    (1, 0, 1, 0, 1, 1, 0, "absent"),
    (1, 0, 1, 0, 1, 1, 1, "absent"),
    (1, 0, 1, 1, 0, 0, 0, "absent"),
    (1, 0, 1, 1, 0, 0, 1, "absent"),
    (1, 0, 1, 1, 0, 1, 0, "absent"),
    (1, 0, 1, 1, 0, 1, 1, "absent"),
    (1, 0, 1, 1, 1, 0, 0, "absent"),
    (1, 0, 1, 1, 1, 0, 1, "absent"),
    (1, 0, 1, 1, 1, 1, 0, "absent"),
    (1, 0, 1, 1, 1, 1, 1, "absent"),

    # claim=1, path=1 — the ladder proper. A verdict that is not (ancestor AND clean AND
    # evidence-resolving) cannot advance past tested/claimed.
    (1, 1, 0, 0, 0, 0, 0, "claimed"),
    (1, 1, 0, 0, 0, 0, 1, "claimed"),
    (1, 1, 0, 0, 0, 1, 0, "claimed"),
    (1, 1, 0, 0, 0, 1, 1, "claimed"),
    (1, 1, 0, 0, 1, 0, 0, "claimed"),
    (1, 1, 0, 0, 1, 0, 1, "claimed"),
    (1, 1, 0, 0, 1, 1, 0, "claimed"),
    (1, 1, 0, 0, 1, 1, 1, "claimed"),
    (1, 1, 0, 1, 0, 0, 0, "claimed"),
    (1, 1, 0, 1, 0, 0, 1, "claimed"),
    (1, 1, 0, 1, 0, 1, 0, "claimed"),
    (1, 1, 0, 1, 0, 1, 1, "claimed"),
    (1, 1, 0, 1, 1, 0, 0, "claimed"),
    (1, 1, 0, 1, 1, 0, 1, "claimed"),
    (1, 1, 0, 1, 1, 1, 0, "claimed"),
    (1, 1, 0, 1, 1, 1, 1, "claimed"),
    (1, 1, 1, 0, 0, 0, 0, "tested"),
    (1, 1, 1, 0, 0, 0, 1, "tested"),
    (1, 1, 1, 0, 0, 1, 0, "tested"),
    (1, 1, 1, 0, 0, 1, 1, "tested"),
    (1, 1, 1, 0, 1, 0, 0, "tested"),
    (1, 1, 1, 0, 1, 0, 1, "tested"),
    (1, 1, 1, 0, 1, 1, 0, "tested"),
    (1, 1, 1, 0, 1, 1, 1, "tested"),
    (1, 1, 1, 1, 0, 0, 0, "tested"),
    (1, 1, 1, 1, 0, 0, 1, "tested"),
    (1, 1, 1, 1, 0, 1, 0, "tested"),
    (1, 1, 1, 1, 0, 1, 1, "tested"),
    (1, 1, 1, 1, 1, 0, 0, "tested"),
    (1, 1, 1, 1, 1, 0, 1, "tested"),
    (1, 1, 1, 1, 1, 1, 0, "validated"),
    (1, 1, 1, 1, 1, 1, 1, "native"),
]
# fmt: on

STATUS_TABLE = {row[:7]: row[7] for row in _STATUS_ROWS}

# Named worlds for find_row_findings. Exhaustive status derivation is the table above; findings
# are compared on a covering set (a finding depends on the same booleans plus has_verdict, and the
# named worlds below cover every detector and the clean case).
# key: (claim, path, test, ancestor, clean, evidence, approved, has_verdict, paths_state)
FINDINGS_WORLDS = {
    "absent-no-claim": ((0, 0, 0, 0, 0, 0, 0, 0, "none"), []),
    "clean-native": ((1, 1, 1, 1, 1, 1, 1, 1, "present"), []),
    "clean-tested": ((1, 1, 1, 0, 0, 0, 1, 0, "present"), []),
    "clean-claimed": ((1, 1, 0, 0, 0, 0, 0, 0, "present"), []),
    "gap-no-paths": ((1, 0, 0, 0, 0, 0, 0, 0, "none"), ["GAP"]),
    "stale-missing-path": ((1, 0, 0, 0, 0, 0, 0, 0, "missing"), ["STALE"]),
    "verdict-not-ancestor": ((1, 1, 1, 0, 0, 1, 1, 1, "present"), ["STALE-VERDICT"]),
    "verdict-touched-files": ((1, 1, 1, 1, 0, 1, 1, 1, "present"), ["STALE-VERDICT"]),
    "verdict-evidence-missing": ((1, 1, 1, 1, 1, 0, 1, 1, "present"), ["STALE-EVIDENCE"]),
    "validated-not-approved": ((1, 1, 1, 1, 1, 1, 0, 1, "present"), ["VALIDATED-BUT-NOT-APPROVED"]),
}

if __name__ == "__main__":
    print("status worlds: %d" % len(STATUS_TABLE))
    print("finding worlds: %d" % len(FINDINGS_WORLDS))
    for key, status in sorted(STATUS_TABLE.items()):
        print("%s -> %s" % (" ".join(str(x) for x in key), status))
