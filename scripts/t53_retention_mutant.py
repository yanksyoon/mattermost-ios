#!/usr/bin/env python3
"""t53_retention_mutant.py — the falsifier for `T53MediaFootprintTests`.

`MattermostTests/T53MediaFootprintTests.testAStagedPayloadIsWrittenToDiskRatherThanHeldInMemory`
exists to fail when the playback cache (or the transport under it) keeps a staged payload in
memory. A guard that cannot see the regression it names is decoration, so this script installs a
"buffering transport" into `MediaFileCache` and lets the case be run against it.

Variants (all of them retain the finished payload across the measured window):

  read   — `Data(contentsOf: location)` kept in a static. This is the mutant that measured
           3.1 MB on iOS / 0 MB on Catalyst against a 32 MB bound (kanban t_822c89af): Darwin's
           `Data(contentsOf:)` maps the file, so the pages it holds are file-backed (clean) and
           never enter `phys_footprint` at all.
  heap   — a byte copy of that payload (`reserveCapacity` + `append`) kept in a static: real
           dirty heap, the regression a `Data`-accumulating transport would produce.

Usage:
  scripts/t53_retention_mutant.py apply read|heap
  scripts/t53_retention_mutant.py revert
  scripts/t53_retention_mutant.py status

The mutation is applied to the working tree (never committed); `revert` is
`git checkout -- Mattermost/UI/Native/Files/MediaPlayback.swift`.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TARGET = REPO / "Mattermost/UI/Native/Files/MediaPlayback.swift"
MARKER = "// MUTANT t_822c89af"

ANCHOR = """        guard let entry = entries[downloadTask.taskIdentifier] else {
            lock.unlock()
            return
        }
        lock.unlock()
"""

STATIC_STORAGE = """
    // MUTANT t_822c89af — the falsifier's storage; absent from the product. It grows: every
    // finished payload is retained, so a measured window after a warm-up still shows one copy.
    static var t53Retained: [Data] = []
"""

VARIANTS = {
    "read": """
        // MUTANT t_822c89af (read): keep the finished payload, as read, across the window.
        if let held = try? Data(contentsOf: location) { Self.t53Retained.append(held) }
        print("MUTANT read held=\\(Self.t53Retained.map(\\.count).reduce(0, +))")
""",
    "mapped": """
        // MUTANT t_822c89af (mapped): keep the finished payload as a file mapping across the window.
        if let held = try? Data(contentsOf: location, options: .mappedIfSafe) {
            Self.t53Retained.append(held)
        }
        print("MUTANT mapped held=\\(Self.t53Retained.map(\\.count).reduce(0, +))")
""",
    "heap": """
        // MUTANT t_822c89af (heap): keep a byte copy of the finished payload across the window.
        if let raw = try? Data(contentsOf: location) {
            var copy = Data(capacity: raw.count)
            copy.append(raw)
            Self.t53Retained.append(copy)
        }
        print("MUTANT heap held=\\(Self.t53Retained.map(\\.count).reduce(0, +))")
""",
}


def git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], cwd=REPO, capture_output=True, text=True)


def current_variant(source: str) -> str:
    for name in VARIANTS:
        if f"{MARKER} ({name})" in source:
            return name
    return "none"


def revert() -> int:
    if git("diff", "--quiet", "--", str(TARGET.relative_to(REPO))).returncode == 0:
        print("[t53-mutant] clean: no mutation in the tree")
        return 0
    if MARKER not in TARGET.read_text():
        print("[t53-mutant] refusing: MediaPlayback.swift is dirty but not by this script")
        return 2
    git("checkout", "--", str(TARGET.relative_to(REPO)))
    print("[t53-mutant] reverted")
    return 0


def apply(variant: str) -> int:
    source = TARGET.read_text()
    if MARKER in source:
        print(f"[t53-mutant] already mutated ({current_variant(source)}); revert first")
        return 2
    if ANCHOR not in source:
        print("[t53-mutant] anchor not found — the delegate changed shape; update this script")
        return 2
    class_anchor = "final class MediaFileCache: NSObject, MediaFileStaging, @unchecked Sendable {\n"
    if class_anchor not in source:
        print("[t53-mutant] class anchor not found")
        return 2
    patched = source.replace(class_anchor, class_anchor + STATIC_STORAGE, 1)
    patched = patched.replace(ANCHOR, ANCHOR + VARIANTS[variant], 1)
    TARGET.write_text(patched)
    print(f"[t53-mutant] applied variant '{variant}' to {TARGET.relative_to(REPO)}")
    return 0


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] not in {"apply", "revert", "status"}:
        print(__doc__)
        return 2
    if sys.argv[1] == "status":
        print(f"[t53-mutant] {current_variant(TARGET.read_text())}")
        return 0
    if sys.argv[1] == "revert":
        return revert()
    if len(sys.argv) != 3 or sys.argv[2] not in VARIANTS:
        print(f"variants: {', '.join(VARIANTS)}")
        return 2
    return apply(sys.argv[2])


if __name__ == "__main__":
    sys.exit(main())
