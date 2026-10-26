#!/usr/bin/env python3
"""Export a live UI run's screenshot attachments into a `docs/` folder.

The card's definition of done asks for screenshots that prove the *running app* renders real server
data, and the only honest source for those bytes is the run's own `xcresult` — an `XCUIScreen`
capture taken by the test at the moment it asserted against the server. This script does the
mechanical part: `xcresulttool` exports them under opaque UUID names plus a manifest, and the
manifest is what carries the name the test gave each shot (`t37-01-pill-added`, …).

Usage:
    python3 scripts/t37_export_shots.py <path.xcresult> docs/t37-shots

Exit codes: 0 exported, 2 usage/export problem.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def run(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__)
        return 2
    bundle = Path(argv[1]).expanduser().resolve()
    out = Path(argv[2])
    if not out.is_absolute():
        out = (REPO / out).resolve()
    if not bundle.exists():
        print(f"no such xcresult: {bundle}", file=sys.stderr)
        return 2

    staging = out / ".export"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True, exist_ok=True)

    result = run(["xcrun", "xcresulttool", "export", "attachments",
                  "--path", str(bundle), "--output-path", str(staging)])
    if result.returncode != 0:
        print(result.stdout, result.stderr, file=sys.stderr)
        return 2

    manifest_path = staging / "manifest.json"
    if not manifest_path.exists():
        print("xcresulttool wrote no manifest; nothing to rename", file=sys.stderr)
        return 2
    manifest = json.loads(manifest_path.read_text())

    exported: list[str] = []
    for test in manifest:
        for attachment in test.get("attachments", []):
            # `suggestedHumanReadableName` is "t37-01-pill-added_0_<uuid>.png"; the part before `_0_`
            # is the name the test passed to `XCTAttachment.name`.
            suggested = attachment.get("suggestedHumanReadableName") or ""
            stored = attachment.get("exportedFileName") or ""
            if not stored:
                continue
            stem = suggested.split("_0_")[0].strip() or Path(stored).stem
            suffix = Path(suggested or stored).suffix or ".png"
            target = out / f"{stem}{suffix}"
            shutil.copy2(staging / stored, target)
            exported.append(target.name)

    shutil.rmtree(staging)
    for name in sorted(exported):
        print(name)
    print(f"exported {len(exported)} screenshot(s) into {out}")
    return 0 if exported else 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
