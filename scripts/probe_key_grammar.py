#!/usr/bin/env python3
"""Probe: does the key grammar actually reject a sha inside the key?

assert 1 in `parity/generate.py --self-test` prints
  "assert 1 ok - key grammar (identity is the path; a sha in the key is rejected)"
but its only check is `not key_is_well_formed("S13")`, i.e. a malformed *namespace*. This probe asks
the grammar directly about a sha-in-key key, which is the F5 shape.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "parity"))
import generate as g  # noqa: E402

cases = [
    "M:app/screens/thread",
    "M:app/screens/thread@9f3a8c1",
    "X:notification-input@deadbeef",
    "S13",
]
for k in cases:
    print("%-38r well_formed=%s" % (k, g.key_is_well_formed(k)))
