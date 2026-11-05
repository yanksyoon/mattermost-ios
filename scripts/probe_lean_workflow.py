#!/usr/bin/env python3
"""Structural check of .github/workflows/parity-lean.yml before it is pushed.

Not a substitute for the Actions parser: it asserts the things I would be embarrassed to get wrong
(the job that must be named `lean`, the condition that makes it skippable, the path patterns).
"""
import sys

import yaml

path = ".github/workflows/parity-lean.yml"
with open(path, "r", encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)

jobs = doc["jobs"]
assert list(jobs) == ["changes", "lean"], jobs
assert jobs["lean"]["name"] == "lean", jobs["lean"]["name"]
needs = jobs["lean"]["needs"]
assert needs == "changes" or needs == ["changes"], needs
assert jobs["lean"]["if"] == "needs.changes.outputs.relevant == 'true'", jobs["lean"]["if"]
assert jobs["changes"]["outputs"]["relevant"]

# `on` is parsed as the boolean True by PyYAML 1.1 rules.
on = doc[True] if True in doc else doc["on"]
assert "pull_request" in on, on
assert on["push"]["branches"] == ["main"]

steps = [s.get("name") or s.get("uses") for s in jobs["lean"]["steps"]]
print("jobs:", list(jobs))
print("lean steps:", steps)
print("triggers:", list(on))
print("OK")
sys.exit(0)
