#!/usr/bin/env python3
"""scripts/differential.py — enumerate the whole input space, diff generate.py against reference.py.

Blocking in CI. Stdlib only, no network.

  * statuses:  the full 2^7 cross-product of the seven facts, every world, byte-compared with the
               hand-authored table in scripts/reference.py;
  * findings:  a covering set of named worlds, compared with the expected finding kinds;
  * decoupling: every status is re-derived with has_verdict flipped, and must not move — the report
               flag may never leak into the ladder (the card's F5 property, in the small).

Exit 1 on any difference. A failure means one of the two readings of design §3.2 is wrong; fix the
reading, never the other side.
"""

import importlib.util
import itertools
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses resolve annotations through sys.modules (py3.9)
    spec.loader.exec_module(module)
    return module


generate = load("parity_generate", os.path.join(ROOT, "parity/generate.py"))
reference = load("parity_reference", os.path.join(HERE, "reference.py"))


def main():
    failures = []

    # 1. statuses — the full cross-product
    worlds = 0
    for combo in itertools.product((False, True), repeat=7):
        facts = generate.Facts(*combo)
        want = reference.STATUS_TABLE[combo]
        got = generate.derive_status(facts)
        worlds += 1
        if got != want:
            failures.append("status %s: generate=%r reference=%r"
                            % (" ".join("1" if x else "0" for x in combo), got, want))
        # the report bit must not move the ladder (F5, in the small)
        flipped = generate.derive_status(generate.Facts(*combo, has_verdict=True))
        if flipped != got:
            failures.append("has_verdict changed the status for %s: %r -> %r"
                            % (combo, got, flipped))

    # 2. findings — the covering worlds
    for name, (facts_tuple, want) in sorted(reference.FINDINGS_WORLDS.items()):
        claim, path, test, ancestor, clean, evidence, approved, has_verdict, paths_state = facts_tuple
        facts = generate.Facts(claim, path, test, ancestor, clean, evidence, approved, has_verdict)
        got = generate.find_row_findings(facts, paths_state)
        if got != want:
            failures.append("findings %s: generate=%r reference=%r" % (name, got, want))

    # 3. the table is complete — no world is missing or duplicated
    if len(reference.STATUS_TABLE) != worlds:
        failures.append("reference table covers %d worlds, the cross-product is %d"
                        % (len(reference.STATUS_TABLE), worlds))

    if failures:
        for line in failures:
            print("[FAIL] differential: %s" % line)
        return 1
    print("differential: PASS — %d status worlds, %d finding worlds, %d table rows"
          % (worlds, len(reference.FINDINGS_WORLDS), len(reference.STATUS_TABLE)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
