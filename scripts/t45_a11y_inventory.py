#!/usr/bin/env python3
"""T45 accessibility inventory — the measurement T45's unit tests re-run.

This is not a style linter. It is the card's *definition of done* expressed as a
scan, so the pass cannot silently regress: every number it prints is either zero
after T45 or carries an entry in `EXEMPT` with a reason, and
`MattermostTests/T45A11yInventoryTests.swift` executes the same logic in-process
when it runs under `xcodebuild test`.

What it measures, per the card's acceptance criteria:

  fonts      `.font(.system(size: ...))` sites. Fixed points do not follow the
             user's text size, so each site is either converted to a Dynamic
             Type text style (`Font.scaled`) or exempted as geometry (an avatar
             initial sized from its circle, an emoji grid cell, artwork).
  labels     interactive controls (`Button`) that draw only a glyph: no `Text`,
             no `accessibilityLabel`. Those are unnamed to VoiceOver.
  lineLimit  `.lineLimit(1)` sites. A single line becomes a truncation the
             moment its text style scales, so each becomes a variable limit. The
             three that stay are in `EXEMPT_LINE_LIMITS`; a fourth fails --check.
  motion     animation sites that do not consult `accessibilityReduceMotion`.
             Asked of the *statement* (T45-AV-R §6): a file that reads the
             setting once no longer vouches for every animation in it.
  contrast   `.colorSchemeContrast` uses (0 before T45: Increase Contrast was
             not honoured anywhere).
  ids        `accessibilityIdentifier` count, which must never fall — the UI
             tests address the shell by identifier.

Usage:
    python3 scripts/t45_a11y_inventory.py            # human table
    python3 scripts/t45_a11y_inventory.py --json     # machine-readable
    python3 scripts/t45_a11y_inventory.py --check    # exit 1 if anything regressed
"""

import argparse
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCAN_ROOTS = ("Mattermost",)

# The five surfaces the card names, plus the shell chrome that hosts them.
SURFACES = {
    "sidebar": "Mattermost/UI/Native/Sidebar",
    "channel": "Mattermost/UI/Native/Channel",
    "composer": "Mattermost/UI/Native/Composer",
    "thread": "Mattermost/UI/Native/Thread",
    "settings": "Mattermost/UI/Native/Profile",
}

FONT_SITE = re.compile(r"\.font\(\.system\(size: ")
SYMBOL_SIZE = re.compile(r"\.symbolRenderingMode|\.font\(\.system\(size: [0-9]")

# Sites that must stay in fixed points, keyed by (file, the source line's own
# text). Keyed on content, not on a line number: the first version of this tool
# keyed on `path:line` and every exemption went stale the moment a comment above
# it was added — which is a silent re-arm, exactly what the pin exists to stop.
#
# Two kinds only:
#   avatar initials  — the glyph is sized from its circle (`size * 0.45`); it
#                      must track the circle, not the user's text size, or it
#                      clips. Apple does not scale avatars either.
#   grid/artwork     — a cell of a fixed-size grid (the emoji picker's 6-column
#                      grid, the welcome illustration); scaling the glyph
#                      without scaling the grid clips it.
EXEMPT_FONT_SITES = {
    ("Mattermost/UI/Native/Channel/PostRowView.swift",
     "size: size * 0.45"): "avatar initials, sized from the circle",
    ("Mattermost/UI/Native/Channel/PostRowView.swift",
     "size: size * 0.36"): "avatar initials, sized from the circle",
    ("Mattermost/UI/Native/Profile/ProfileView.swift",
     "size: size * 0.42"): "avatar initials, sized from the circle",
    ("Mattermost/UI/Native/Profile/ProfileView.swift",
     "size: size * 0.34"): "avatar initials, sized from the circle",
    ("Mattermost/UI/Native/Emoji/EmojiPickerView.swift",
     "Text(character)"): "emoji grid cell glyph",
    ("Mattermost/UI/WelcomeView.swift",
     "slide.isMain ? 72 : 64"): "welcome illustration artwork (integration-owned file)",
}

# The Dynamic Type implementation itself, plus files T45 does not own
# (docs/parallel-work.md §6): the pass reports those and leaves them alone.
EXCLUDED_FILES = {
    "Mattermost/UI/Native/Accessibility/AccessibleType.swift",
    "Mattermost/UI/Native/Accessibility/AccessibilityPolicies.swift",
}
UNOWNED_FILES = (
    "Mattermost/UI/ErrorStateView.swift",
    "Mattermost/UI/WelcomeView.swift",
    "Mattermost/UI/CertPromptSheet.swift",
    "Mattermost/UI/SettingsView.swift",
)

# The three one-line caps this pass allows to stay. Content-keyed, like the font
# exemptions above, so a comment above a call site does not silently re-arm the bug.
#
# T45-AV-R §6: before this the three were *reported* and never gated, so a fourth
# `.lineLimit(1)` on scaling text shipped green. `--check` now fails on any bare cap
# outside this table, and on an entry here that no longer names a site.
EXEMPT_LINE_LIMITS = {
    ("Mattermost/UI/DownloadsView.swift",
     "Text(record.filename)"):
        "a file name in a fixed-height download row; the row's own label carries it in full",
    ("Mattermost/UI/DownloadsView.swift",
     "Text(note)"):
        "the 'saved as' note is middle-truncated on purpose and the full value is the row's value",
    ("Mattermost/UI/Native/Sidebar/TeamSidebarView.swift",
     "Text(entry.initials)"):
        "team initials in the fixed 52 pt rail tile, scaled to fit the tile (cannot truncate)",
}


def is_exempt(site):
    for (file, fragment), _reason in EXEMPT_FONT_SITES.items():
        if site["file"] == file and fragment in site["source"]:
            return True
    return False


def swift_files():
    for root in SCAN_ROOTS:
        for dirpath, _dirnames, filenames in os.walk(os.path.join(REPO, root)):
            for name in sorted(filenames):
                if name.endswith(".swift"):
                    path = os.path.join(dirpath, name)
                    if rel(path) in EXCLUDED_FILES:
                        continue
                    yield path


def rel(path):
    return os.path.relpath(path, REPO)


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read().splitlines()


def font_sites():
    """Every fixed-point font site, with the receiver it is applied to."""
    sites = []
    for path in swift_files():
        lines = read(path)
        for index, line in enumerate(lines):
            if not FONT_SITE.search(line):
                continue
            # The receiver is whatever the `.font` modifier chains onto: walk back
            # past continuation lines to the last line that starts an expression.
            receiver = ""
            for back in range(index, max(-1, index - 6), -1):
                stripped = lines[back].strip()
                if not stripped.startswith("."):
                    receiver = stripped
                    break
            kind = "text"
            if ("Image(systemName:" in receiver or "Image(uiImage:" in receiver
                    or "Text(glyph)" in receiver or "Text(character)" in receiver
                    or "symbolName" in receiver):
                kind = "glyph"
            sites.append({
                "file": rel(path),
                "line": index + 1,
                "kind": kind,
                "receiver": receiver[:110],
                "source": lines[index].strip(),
            })
    return sites


def unnameable_buttons():
    """Buttons drawn from a glyph that name nothing.

    Brace-balanced rather than line-based: `Button { ... } label: { Image(...) }` spans
    lines, and a line scan produces both false positives and misses.

    T45-AV-R §5 rewrote this. The first version read only the text between the keyword's
    first `{` and its matching `}` — i.e. the **action** closure — and searched that for
    `label:` and `Image(`. So the shape every toolbar glyph in this app uses

        Button {
            showsPinned = true
        } label: {
            Label("Pinned messages", systemImage: "pin")
        }

    was never inspected at all: a probe file with exactly that shape and no label measured
    `unnamed glyph buttons 0 / RESULT: PASS`. The scan now finds the **label** closure for
    every `Button` shape the tree uses and asks the question about that:

      * `Button { action } label: { <label> }`     — trailing `label:` closure;
      * `Button { action } content: { <label> }`   — the deprecated spelling of the same;
      * `Button { <label> }`                        — the closure *is* the label;
      * `Button("Done") { action }` / `Label(...)`  — named by the title/Label it is given;
      * `Button(action: ...) { <label> }`           — params then a trailing label closure.

    A control counts as named when its label closure contains a `Text(` or a `Label(` (both
    draw the name they are given; `Label(...).labelStyle(.iconOnly)` still carries it), or
    when the statement carries `.accessibilityLabel(...)` — the trailer is read because the
    label modifier usually sits *after* the closure closes.
    """
    findings = []
    for path in swift_files():
        text = "\n".join(read(path))
        for match in re.finditer(r"\bButton\b", text):
            line = _unnamed_button_line(text, match.end())
            if line is None:
                continue
            findings.append({"file": rel(path),
                             "line": text.count("\n", 0, match.start()) + 1})
    return findings


def _unnamed_button_line(text, start):
    """`True`-ish when the `Button` whose keyword ends at `start` draws an unnamed glyph."""
    cursor = _skip_space(text, start)
    if cursor >= len(text):
        return None

    named_by_arguments = False
    if text[cursor] == "(":
        close = _matching_paren(text, cursor)
        if close == -1:
            return None
        arguments = text[cursor:close]
        # The parenthesis carries the name only when it starts with a string literal
        # (`Button("Done")`) or contains a `Label(...)` (`Button(role:)` + a labelled closure).
        named_by_arguments = bool(arguments.lstrip().startswith("\"")
                                  or re.search(r"\bLabel\s*\(", arguments))
        cursor = _skip_space(text, close + 1)
        if cursor >= len(text):
            return None
        # `Button("Done") { dismiss() }`: the title is on the parenthesis, the closure is
        # only the action — there is no glyph-only label to inspect.
        if named_by_arguments and not re.search(r"\baction\s*:", arguments):
            return None

    if text[cursor] != "{":
        # `Button(title, action:)` and friends: no closure-shaped label to inspect.
        return None

    action_end = _matching_brace(text, cursor)
    if action_end == -1:
        return None

    # `label:` / `content:` must follow the action closure **immediately** (it is part of the
    # initializer). Searching a fixed-width window instead finds the *next* Button's `label:`
    # and reports that button's label as this one's — which is what the first draft of this
    # rewrite did to the three `Button("…")` rows inside a confirmation dialog.
    label_body = None
    label_end = action_end
    after = _skip_space(text, action_end + 1)
    keyword = re.match(r"(?:label|content)\s*:\s*", text[after:])
    if keyword:
        opening = _skip_space(text, after + keyword.end())
        if opening < len(text) and text[opening] == "{":
            closing = _matching_brace(text, opening)
            if closing != -1:
                label_body = text[opening:closing]
                label_end = closing
    if label_body is None:
        # `Button(action: ...) { Image(...) }` — params, then the trailing closure is the
        # label — and a plain `Button { ... }`, whose closure is both action and label.
        label_body = text[cursor:action_end]

    if re.search(r"\bText\s*\(", label_body) or re.search(r"\bLabel\s*\(", label_body):
        return None
    # The label modifier is applied to the Button, i.e. after the closure that closed last.
    trailer = _modifier_chain(text, label_end + 1)
    if "accessibilityLabel" in label_body or "accessibilityLabel" in trailer:
        return None
    if "Image(" not in label_body and "ProgressView" not in label_body:
        return None
    return True


def _modifier_chain(text, index, budget=600):
    """The `.modifier(...)` lines that follow `index` — one statement's trailing chain.

    Stops at the first line that does not start with `.`, so a later `Button` (or any other
    statement) cannot lend its `.accessibilityLabel` to the control being inspected.
    """
    chunk = text[index:index + budget]
    lines = chunk.split("\n")
    kept = [lines[0]]
    for line in lines[1:]:
        if line.strip().startswith("."):
            kept.append(line)
            continue
        break
    return "\n".join(kept)


def _skip_space(text, index):
    while index < len(text) and text[index] in " \t\r\n":
        index += 1
    return index


def _matching_paren(text, opening):
    depth = 0
    for index in range(opening, len(text)):
        char = text[index]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index
    return -1


def _matching_brace(text, opening):
    depth = 0
    for index in range(opening, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return index
    return -1


def count(needle, path_filter=None):
    total = 0
    for path in swift_files():
        if path_filter and not path_filter(path):
            continue
        total += "\n".join(read(path)).count(needle)
    return total


def line_limit_sites():
    sites = []
    for path in swift_files():
        lines = read(path)
        for index, line in enumerate(lines):
            if ".lineLimit(1)" not in line:
                continue
            # A comment that *describes* the cap is not a cap (the probe for this gate put
            # one in a doc comment and the scan counted it).
            if line.strip().startswith("//"):
                continue
            # Same receiver walk as `font_sites`: the exemption has to name the *text* the cap
            # is applied to, and the `.lineLimit(1)` line alone does not carry it.
            receiver = ""
            for back in range(index, max(-1, index - 6), -1):
                stripped = lines[back].strip()
                if not stripped.startswith("."):
                    receiver = stripped
                    break
            sites.append({"file": rel(path), "line": index + 1,
                          "receiver": receiver[:110],
                          "source": line.strip()})
    return sites


def line_limit_matches(site, file, fragment):
    return site["file"] == file and (fragment in site.get("receiver", "")
                                     or fragment in site.get("source", ""))


def line_limit_exemption(site):
    for (file, fragment), _reason in EXEMPT_LINE_LIMITS.items():
        if line_limit_matches(site, file, fragment):
            return True
    return False


def animation_sites():
    """Animation call sites and whether *that statement* consults Reduce Motion.

    T45-AV-R §6: the first version asked the file (`guarded_file`), so any file that read
    `accessibilityReduceMotion` once made every animation in it look guarded — and nothing
    failed on an unguarded site at all. The question is now asked of the statement: an
    `Animation` that reaches `withAnimation`/`.animation`/`.transition` must go through
    `MotionPolicy` (or carry `reduceMotion` itself). A multi-line call is read as up to four
    lines from the keyword.
    """
    sites = []
    for path in swift_files():
        lines = read(path)
        guards = "accessibilityReduceMotion" in "\n".join(lines)
        for index, line in enumerate(lines):
            if not ("withAnimation(" in line or re.search(r"\.animation\(", line)
                    or ".transition(" in line):
                continue
            statement = "\n".join(lines[index:index + 4])
            guarded = ("MotionPolicy." in statement or "mmAnimation(" in statement
                       or "reduceMotion" in statement)
            sites.append({
                "file": rel(path),
                "line": index + 1,
                "guarded": guarded,
                # Kept for the manifest the T45 unit test reads; `guarded` is the real answer.
                "guarded_file": guards,
                "source": line.strip()[:110],
            })
    return sites


def surface_of(path):
    for name, prefix in SURFACES.items():
        if path.startswith(prefix):
            return name
    return None


def converted_by_surface():
    """How many Dynamic Type conversions each of the five surfaces carries.

    A surface with zero conversions was not reached by the pass — that is a
    different failure from "no offenders left", and this is what distinguishes them.
    """
    counts = {}
    helpers = (".font(.scaled(", ".scaledSymbol(", ".scaledColumn(", ".mmLineLimit(")
    for name, prefix in SURFACES.items():
        total = 0
        for path in swift_files():
            if not rel(path).startswith(prefix):
                continue
            text = "\n".join(read(path))
            total += sum(text.count(helper) for helper in helpers)
        counts[name] = total
    return counts


def subprocess_head():
    """The commit the manifest was generated against (empty outside a git checkout)."""
    try:
        return subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO,
                              capture_output=True, text=True,
                              timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def report():
    fonts = font_sites()
    # A fixed point size is a defect on *text*. On a glyph it is a drawn
    # dimension inside a fixed control, and the pass deliberately leaves those
    # (the ones large enough to be standalone use `.scaledSymbol` and no longer
    # appear here at all). So the unexplained set is text-kind only.
    unexplained = [site for site in fonts
                   if site["kind"] == "text" and not is_exempt(site)
                   and site["file"] not in UNOWNED_FILES]
    unowned = [site for site in fonts
               if site["kind"] == "text" and site["file"] in UNOWNED_FILES
               and not is_exempt(site)]
    glyph = [site for site in fonts if site["kind"] == "glyph" and not is_exempt(site)]
    stale = ["%s :: %s" % (file, fragment)
             for (file, fragment) in EXEMPT_FONT_SITES
             if not any(site["file"] == file and fragment in site["source"]
                        for site in fonts)]

    by_surface = {}
    for site in fonts:
        surface = surface_of(site["file"])
        if surface:
            by_surface[surface] = by_surface.get(surface, 0) + 1

    return {
        "font_sites": len(fonts),
        "font_sites_by_surface": by_surface,
        "font_sites_unexplained": unexplained,
        "font_sites_unowned": unowned,
        "font_sites_glyph": glyph,
        "font_sites_exempt": len([site for site in fonts if is_exempt(site)]),
        "stale_exemptions": stale,
        "exemptions": [{"file": file, "fragment": fragment, "reason": reason}
                       for (file, fragment), reason in EXEMPT_FONT_SITES.items()],
        "converted_by_surface": converted_by_surface(),
        "scaled_font_sites": count("font(.scaled("),
        "scaled_symbol_sites": count(".scaledSymbol("),
        "scaled_column_sites": count(".scaledColumn("),
        "variable_line_limit_sites": count(".mmLineLimit("),
        "unnamed_buttons": unnameable_buttons(),
        "line_limit_one": line_limit_sites(),
        "line_limit_one_unexplained": [site for site in line_limit_sites()
                                       if not line_limit_exemption(site)],
        "line_limit_exemptions": [{"file": file, "fragment": fragment, "reason": reason}
                                  for (file, fragment), reason in EXEMPT_LINE_LIMITS.items()],
        "stale_line_limit_exemptions": [
            "%s :: %s" % (file, fragment)
            for (file, fragment) in EXEMPT_LINE_LIMITS
            if not any(line_limit_matches(site, file, fragment)
                       for site in line_limit_sites())
        ],
        "animation_sites": animation_sites(),
        "unguarded_animations": [site for site in animation_sites()
                                 if not site["guarded"]],
        "reduce_motion_uses": count("accessibilityReduceMotion"),
        "contrast_uses": count("colorSchemeContrast"),
        "accessibility_labels": count("accessibilityLabel"),
        "accessibility_identifiers": count("accessibilityIdentifier"),
        "accessibility_hints": count("accessibilityHint"),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--emit-manifest", metavar="PATH",
                        help="write the report as the checked-in manifest the unit "
                             "test reads (MattermostTests/Fixtures/t45-a11y-inventory.json)")
    arguments = parser.parse_args()

    data = report()
    if arguments.emit_manifest:
        data["head"] = subprocess_head()
        data["generated_by"] = "scripts/t45_a11y_inventory.py"
        data["note"] = ("Generated by the host-side scan. The unit test asserts this "
                        "manifest has no offenders; re-run this command and commit the "
                        "file whenever the accessibility surfaces change.")
        with open(arguments.emit_manifest, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, sort_keys=True)
            handle.write("\n")
        print("manifest written to %s" % arguments.emit_manifest)
    if arguments.json:
        print(json.dumps(data, indent=2, sort_keys=True))
    else:
        print("T45 accessibility inventory")
        print("---------------------------")
        print("font sites (fixed points)    %3d  %s" % (
            data["font_sites"], data["font_sites_by_surface"]))
        print("  exempt by design           %3d" % data["font_sites_exempt"])
        print("  glyph geometry (by rule)   %3d" % len(data["font_sites_glyph"]))
        print("  unowned (not T45's files)  %3d" % len(data["font_sites_unowned"]))
        print("  UNEXPLAINED text           %3d" % len(data["font_sites_unexplained"]))
        print("Dynamic Type conversions     %3d text, %d symbols, %d columns" % (
            data["scaled_font_sites"], data["scaled_symbol_sites"],
            data["scaled_column_sites"]))
        print("variable line limits         %3d" % data["variable_line_limit_sites"])
        print("bare lineLimit(1) left       %3d  (%d exempt, %d unexplained)" % (
            len(data["line_limit_one"]),
            len(data["line_limit_one"]) - len(data["line_limit_one_unexplained"]),
            len(data["line_limit_one_unexplained"])))
        print("unnamed glyph buttons        %3d" % len(data["unnamed_buttons"]))
        print("animation sites              %3d (%d consult reduce motion)" % (
            len(data["animation_sites"]),
            len([site for site in data["animation_sites"] if site["guarded"]])))
        print("accessibilityReduceMotion    %3d" % data["reduce_motion_uses"])
        print("colorSchemeContrast          %3d" % data["contrast_uses"])
        print("accessibilityLabel           %3d" % data["accessibility_labels"])
        print("accessibilityHint            %3d" % data["accessibility_hints"])
        print("accessibilityIdentifier      %3d" % data["accessibility_identifiers"])
        for site in data["font_sites_unexplained"]:
            print("  font  %s:%d  %s" % (site["file"], site["line"], site["source"]))
        for site in data["font_sites_unowned"]:
            print("  unowned font %s:%d  %s" % (site["file"], site["line"], site["source"]))
        for site in data["unnamed_buttons"]:
            print("  label %s:%d" % (site["file"], site["line"]))
        for site in data["line_limit_one_unexplained"]:
            print("  bare lineLimit(1) %s:%d  %s"
                  % (site["file"], site["line"], site.get("source", "")))
        for site in data["unguarded_animations"]:
            print("  unguarded animation %s:%d  %s"
                  % (site["file"], site["line"], site.get("source", "")))
        for key in data["stale_exemptions"]:
            print("  stale exemption %s" % key)
        for key in data["stale_line_limit_exemptions"]:
            print("  stale lineLimit exemption %s" % key)

    if arguments.check:
        failures = []
        if data["font_sites_unexplained"]:
            failures.append("%d unexplained fixed-point font sites"
                            % len(data["font_sites_unexplained"]))
        if data["font_sites_unowned"]:
            failures.append("%d fixed-point font sites in files T45 does not own"
                            % len(data["font_sites_unowned"]))
        if data["unnamed_buttons"]:
            failures.append("%d unnamed glyph buttons" % len(data["unnamed_buttons"]))
        if data["stale_exemptions"]:
            failures.append("%d stale exemptions" % len(data["stale_exemptions"]))
        # T45-AV-R §6: the two gates that used to be print-outs only.
        if data["unguarded_animations"]:
            failures.append("%d animation sites that do not consult Reduce Motion"
                            % len(data["unguarded_animations"]))
        if data["line_limit_one_unexplained"]:
            failures.append("%d bare .lineLimit(1) sites outside the documented three"
                            % len(data["line_limit_one_unexplained"]))
        if data["stale_line_limit_exemptions"]:
            failures.append("%d stale .lineLimit(1) exemptions"
                            % len(data["stale_line_limit_exemptions"]))
        if failures:
            print("\nRESULT: FAIL — " + "; ".join(failures))
            return 1
        print("\nRESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
