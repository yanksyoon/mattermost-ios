#!/usr/bin/env python3
"""T45 — the one-time font migration, kept so the diff is auditable.

Rule (see `Mattermost/UI/Native/Accessibility/AccessibleType.swift`):

  text   `.font(.system(size: N, weight: W, design: D))`
         -> `.font(.scaled(N, weight: W, design: D))`
         A designed point size becomes the nearest Dynamic Type text style.

  glyph  `.font(.system(size: N, weight: W))` on an `Image(systemName:)`, N >= 22
         -> `.scaledSymbol(N, weight: W)`
         Standalone glyphs keep their designed size at the default setting and
         scale from there. Small glyphs (< 22) are control geometry and stay put.

  skip   avatar initials (`size * 0.45`), emoji grid cells, artwork, and the
         files T45 does not own.

The call is rewritten by a balanced-paren scan, not by regex: the argument list
itself contains calls (`size: MarkdownMetrics.headingSize(level)`), and a regex
that stops at the first `)` both truncates the argument and miscounts the
closers — which is exactly the bug that made the first run of this migration
produce 74 lines that would not compile.

Idempotent: it only matches `.font(.system(size:`, so re-running it after the
pass is a no-op. `--dry-run` prints the rewrites instead of writing them.
"""

import argparse
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGET = os.path.join(REPO, "Mattermost", "UI", "Native")

SKIP = {
    "Accessibility/AccessibleType.swift",
    "Accessibility/AccessibilityPolicies.swift",
}
# Sites the pass leaves alone, with the reason (mirrored in the inventory tool).
SKIP_LINES = {
    ("Channel/PostRowView.swift", 126): "avatar initials sized from the circle",
    ("Channel/PostRowView.swift", 130): "avatar initials sized from the circle",
    ("Profile/ProfileView.swift", 574): "avatar initials sized from the circle",
    ("Profile/ProfileView.swift", 578): "avatar initials sized from the circle",
    ("Emoji/EmojiPickerView.swift", 199): "emoji grid cell glyph",
}

START = ".font(.system(size: "
GLYPH_SCALE_THRESHOLD = 22.0


def matching_paren(line, opening):
    depth = 0
    for index in range(opening, len(line)):
        char = line[index]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index
    return -1


def classify(lines, index):
    """'text' or 'glyph', by the expression the modifier chains onto."""
    for back in range(index, max(-1, index - 6), -1):
        stripped = lines[back].strip()
        if stripped.startswith("."):
            continue
        if ("Image(systemName:" in stripped or "Image(uiImage:" in stripped
                or "Text(glyph)" in stripped or "Text(character)" in stripped
                or "symbolName" in stripped):
            return "glyph"
        return "text"
    return "text"


def migrate(dry_run, verbose):
    rewrites = []
    for dirpath, _dirnames, filenames in os.walk(TARGET):
        for name in sorted(filenames):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(dirpath, name)
            relative = os.path.relpath(path, TARGET)
            if relative in SKIP:
                continue
            with open(path, encoding="utf-8") as handle:
                original = handle.read()
            lines = original.splitlines(keepends=True)
            plain = [entry.rstrip("\n") for entry in lines]
            changed = False
            for index, line in enumerate(lines):
                position = line.find(START)
                if position == -1:
                    continue
                if (relative, index + 1) in SKIP_LINES:
                    continue
                font_open = position + len(".font")
                font_close = matching_paren(line, font_open)
                if font_close == -1:
                    continue
                system_open = position + len(".font(")
                system_close = matching_paren(line, system_open)
                if system_close == -1:
                    continue
                arguments = line[system_open + len(".system("):system_close]
                head, _separator, rest = arguments.partition(",")
                size = head.replace("size:", "").strip()
                trailing = ["," + rest] if rest.strip() else []
                try:
                    numeric = float(size)
                except ValueError:
                    kind = "text"
                else:
                    kind = classify(plain, index)
                    if kind == "glyph" and numeric < GLYPH_SCALE_THRESHOLD:
                        continue
                tail = "".join(trailing).rstrip()
                if kind == "glyph":
                    replacement = ".scaledSymbol(%s%s)" % (size, tail)
                else:
                    replacement = ".font(.scaled(%s%s))" % (size, tail)
                new_line = line[:position] + replacement + line[font_close + 1:]
                if new_line == line:
                    continue
                rewrites.append((relative, index + 1, line.strip(), new_line.strip()))
                lines[index] = new_line
                plain[index] = new_line.rstrip("\n")
                changed = True
            if changed and not dry_run:
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write("".join(lines))
    if verbose:
        for relative, line_number, before, after in rewrites:
            print("%s:%d\n  - %s\n  + %s" % (relative, line_number, before, after))
    return rewrites


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    arguments = parser.parse_args()
    rewrites = migrate(arguments.dry_run, arguments.verbose or args_dry(arguments))
    print("\n%d site(s) %s" % (len(rewrites),
                               "would be rewritten" if arguments.dry_run else "rewritten"))
    return 0


def args_dry(arguments):
    return arguments.dry_run


if __name__ == "__main__":
    sys.exit(main())
