#!/usr/bin/env python3
"""Print the `run:` body of one named step from a GitHub workflow, verbatim.

Used by scripts/release_publish_selftest.sh so the self-test always exercises the
*shipped* text of .github/workflows/release.yml - never a copy that can drift from it.

No PyYAML dependency: a workflow step's body is a block scalar under its `- name:`
line, so a line scan is enough and it runs on a bare runner with python3 and nothing
else.

Usage
  extract_step.py .github/workflows/release.yml "Publish the release"
  git show a4b6467:.github/workflows/release.yml | extract_step.py - "Tag and publish"

Exit: 0 the body was found and printed, 2 the step (or its `run:`) was not found.
"""

from __future__ import annotations

import sys
from typing import NoReturn


def die(msg: str) -> NoReturn:
    print(f"extract_step: {msg}", file=sys.stderr)
    sys.exit(2)


def main(argv: list) -> int:
    if len(argv) != 3:
        die("usage: extract_step.py <workflow.yml|-> \"<step name>\"")
    path, step_name = argv[1], argv[2]

    if path == "-":
        text = sys.stdin.read()
    else:
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except OSError as exc:
            die(f"cannot read {path}: {exc}")
    lines = text.splitlines()

    want = f"- name: {step_name}"
    for i, line in enumerate(lines):
        if line.strip() == want:
            start = i
            break
    else:
        die(f"step not found: {step_name}")

    # The `run:` key must belong to this step: stop at the next `- name:` line.
    j = start + 1
    while j < len(lines):
        stripped = lines[j].strip()
        if stripped == "- name:" or stripped.startswith("- name: "):
            die(f"no run: block under step {step_name!r}")
        if stripped.startswith("run:"):
            break
        j += 1
    else:
        die(f"no run: block under step {step_name!r}")

    inline = lines[j].strip()[len("run:"):].strip()
    if inline and inline != "|":
        # `run: <command>` on one line - that is the whole body.
        print(inline)
        return 0

    indent = len(lines[j]) - len(lines[j].lstrip())
    body = []
    for k in range(j + 1, len(lines)):
        raw = lines[k]
        if raw.strip() and (len(raw) - len(raw.lstrip())) <= indent:
            break
        body.append(raw[indent + 2:] if raw.strip() else "")
    if not body:
        die(f"empty run: block under step {step_name!r}")
    print("\n".join(body))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
