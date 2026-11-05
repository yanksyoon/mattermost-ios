#!/usr/bin/env python3
"""scripts/cap.py — every command in docs/capability-workflow-design.md keeps working.

It forwards to the one tool; the record lives in parity/ (design of record:
docs/parity-map-design.md). `gen` regenerates the artifacts, `ci-check` is the report-mode gate.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "parity"))
import generate  # noqa: E402

ALIASES = {"gen": [], "ci-check": ["--check", "--report"]}
args = sys.argv[1:]
verb = args[0] if args else ""
if verb == "query":
    args = ["--query"] + args[1:]
elif verb in ALIASES:
    args = ALIASES[verb] + args[1:]
sys.exit(generate.main(args))
