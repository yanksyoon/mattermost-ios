#!/usr/bin/env python3
"""Probe: does the key grammar actually reject a sha inside the join key (F5)?

`assert 1` in `parity/generate.py --self-test` used to print "a sha in the key is rejected" while
its only check was `not key_is_well_formed("S13")` — a malformed *namespace*. Since t_93d9cafb the
grammar refuses the F5 *shape* beside the namespace syntax (`key_carries_content_sha`: an M: key
whose last `@`-segment is 7–40 lowercase hex), and assert 1 asserts `M:app/screens/thread@9f3a8c1`.

This probe is the independent measurement: it prints the grammar's verdict per key and exits 1 if
any expectation moves, so the assert and this file cannot drift apart silently.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "parity"))
import generate as g  # noqa: E402

# key -> must the grammar accept it?
cases = [
    ("M:app/screens/thread", True),
    ("M:app/screens/share@2x", True),          # `@` is legitimate in an upstream path
    ("M:app/screens/thread@9f3a8c1", False),   # F5: a 7-char sha inside the key
    ("M:app/screens/thread@deadbeef", False),  # F5: an 8-char sha inside the key
    ("X:notification-input@deadbeef", False),  # no namespace admits `@` in the suffix
    ("S13", False),                            # a malformed namespace, as before
]

failures = []
for key, want in cases:
    got = g.key_is_well_formed(key)
    print("%-38r well_formed=%-5s expected=%s%s" % (key, got, want, "" if got == want else "  <-- MOVED"))
    if got != want:
        failures.append(key)

if failures:
    print("[FAIL] probe_key_grammar: %d key(s) moved: %s" % (len(failures), failures))
    sys.exit(1)
print("probe_key_grammar: PASS — %d/%d keys as expected (a sha-suffixed M: key is rejected)"
      % (len(cases), len(cases)))
