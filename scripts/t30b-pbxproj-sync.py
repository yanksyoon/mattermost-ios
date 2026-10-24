#!/usr/bin/env python3
"""T30b — migrate this project from hand-registered files to synchronized folders.

One deterministic transform of `Mattermost.xcodeproj/project.pbxproj`, run once:

  1. `Mattermost/UI/Native/`    -> PBXFileSystemSynchronizedRootGroup on the Mattermost target
  2. `MattermostTests/`         -> ... on the MattermostTests target
  3. `MattermostUITests/`       -> ... on the MattermostUITests target

Three trees, because a screen card ships a screen *and* its tests: synchronizing only the
app tree would leave every card editing project.pbxproj for its test file, which is the exact
collision this card exists to remove (docs/parallel-work.md §3).

Everything is brace-scanner based (no greedy regexes over `};`), and the script asserts the
project is structurally intact before it writes:

  * every object id is defined exactly once (the duplicate-id defect this card repairs),
  * every id referenced from a group's `children` is defined,
  * the three native targets and their products still exist,
  * plutil still parses the file (run as a separate step).

It is a **one-shot migration**: it asserts the pre-migration shape (`46` test build files,
the two hand-registered `UI/Native` files), so re-running it on an already-migrated project
fails its first assertion instead of silently doing something else. Kept in the repo as the
provenance of the transform — the diff it produced is the record of what changed.

Usage: scripts/t30b-pbxproj-sync.py [--write]
"""
import re
import sys

PATH = "/Users/yangsooyoon/Documents/yanks/code/mattermost-ios/Mattermost.xcodeproj/project.pbxproj"
SYNC = [
    # (object id, display name, path, target object id, target name)
    ("C00000000000000000000001", "Native", "Mattermost/UI/Native", "F50000000000000000000001", "Mattermost"),
    ("C00000000000000000000002", "MattermostTests", "MattermostTests", "F50000000000000000000002", "MattermostTests"),
    ("C00000000000000000000003", "MattermostUITests", "MattermostUITests", "F50000000000000000000003", "MattermostUITests"),
]
# hand-maintained group nodes that the synchronized groups replace
OLD_GROUPS = ["F000000000000000000000B1", "F00000000000000000000007", "F00000000000000000000008"]
TEST_PHASES = ["F60000000000000000000004", "F60000000000000000000007"]  # unit-test and UI-test Sources


def find_object(text, uid):
    """Return (start, end) of the `\\t\\t<uid> ... = { ... };` object, brace-balanced, quotes ignored."""
    m = re.search(r"^[ \t]*" + uid + r"(?: /\*.*?\*/)? = \{", text, re.M)
    assert m, f"object {uid} not found"
    i = text.index("{", m.start())
    depth, j, in_str = 0, i, False
    while j < len(text):
        c = text[j]
        if in_str:
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                end = text.index(";", j) + 1
                if text[end:end + 1] == "\n":
                    end += 1
                return m.start(), end
        j += 1
    raise AssertionError(f"object {uid} unterminated")


def drop_object(text, uid):
    start, end = find_object(text, uid)
    return text[:start] + text[end:]


src = open(PATH, encoding="utf-8").read()
original_len = len(src)

# ---- 1. every PBXBuildFile with an F4 id belongs to the two test targets -----
bf_re = re.compile(
    r"^\s*(F40000000000000000000[0-9A-F]{3})\s*/\*.*?\*/\s*=\s*\{isa = PBXBuildFile; "
    r"fileRef = (F20000000000000000000[0-9A-F]{3})\s*/\*", re.M)
pairs = bf_re.findall(src)
bf_ids = {b for b, _ in pairs}
fr_ids = {f for _, f in pairs}
assert len(bf_ids) == 46 and len(fr_ids) == 46, (len(bf_ids), len(fr_ids))

# The two files that already live in Mattermost/UI/Native/ keep their place on disk and lose
# their registration: the synchronized group supplies them now, and a second registration would
# build them twice.
UI_NATIVE_BUILD_FILES = {"F300000000000000000000B1", "F300000000000000000000B2"}
UI_NATIVE_FILE_REFS = {"F200000000000000000000B1", "F200000000000000000000B2"}
APP_SOURCES_PHASE = "F60000000000000000000001"
for uid in UI_NATIVE_BUILD_FILES | UI_NATIVE_FILE_REFS:
    assert re.search(r"^\s*" + uid + r" /\*", src, re.M), f"{uid} not found"

start, end = find_object(src, APP_SOURCES_PHASE)
block = src[start:end]
for uid in UI_NATIVE_BUILD_FILES:
    line = re.search(r"^[ \t]*" + uid + r" /\*.*in Sources \*/,\n", block, re.M)
    assert line, f"{uid} not in the app Sources phase"
    block = block[:line.start()] + block[line.end():]
src = src[:start] + block + src[end:]
TEST_BF_IDS = set(bf_ids)
bf_ids |= UI_NATIVE_BUILD_FILES
fr_ids |= UI_NATIVE_FILE_REFS

# ---- 2. empty the two test Sources phases (their only entries were those files) ----
def empty_files_list(text, uid):
    start, end = find_object(text, uid)
    block = text[start:end]
    m = re.search(r"(\t\t\tfiles = \(\n)(.*?)(\t\t\t\);)", block, re.S)
    assert m, f"{uid} has no files list"
    ids = re.findall(r"(F40000000000000000000[0-9A-F]{3})", m.group(2))
    new_block = block[:m.start(2)] + block[m.end(2):]
    return text[:start] + new_block + text[end:], set(ids)


seen = set()
for phase in TEST_PHASES:
    src, ids = empty_files_list(src, phase)
    seen |= ids
assert seen == TEST_BF_IDS, f"phase/definition mismatch: {sorted(TEST_BF_IDS ^ seen)}"

# ---- 3. delete the build files and the file references they pointed at ----
out, removed_bf, removed_fr = [], 0, 0
for line in src.split("\n"):
    m = re.match(r"^\s*([0-9A-F]{24})\s+/\*.*?\*/\s*=\s*\{isa = PBXBuildFile;", line)
    if m and m.group(1) in bf_ids:
        removed_bf += 1
        continue
    m = re.match(r"^\s*([0-9A-F]{24})\s+/\*.*?\*/\s*=\s*\{isa = PBXFileReference;", line)
    if m and m.group(1) in fr_ids:
        removed_fr += 1
        continue
    out.append(line)
src = "\n".join(out)
assert removed_bf == 48, removed_bf
assert removed_fr == 48, removed_fr   # definitions only; the group children die with their groups

# ---- 4. remove the three hand-maintained group nodes ----
for uid in OLD_GROUPS:
    src = drop_object(src, uid)

# ---- 5. mainGroup: old group children out, synchronized groups in ----
for uid in ("F000000000000000000000B1", "F00000000000000000000007", "F00000000000000000000008"):
    child = re.search(r"^\t\t\t\t" + uid + r" /\*.*?\*/,\n", src, re.M)
    assert child, f"mainGroup child {uid} not found"
    src = src[:child.start()] + src[child.end():]

main_group_start, main_group_end = find_object(src, "F00000000000000000000002")
main_group = src[main_group_start:main_group_end]
anchor = "\t\t\t\tF00000000000000000000003 /* Products */,\n"
assert main_group.count(anchor) == 1
addition = "".join(f"\t\t\t\t{uid} /* {name} */,\n" for uid, name, _p, _t, _n in SYNC)
main_group = main_group.replace(anchor, anchor + addition)
src = src[:main_group_start] + main_group + src[main_group_end:]

# ---- 6. the synchronized root groups ----
section = "/* Begin PBXFileSystemSynchronizedRootGroup section */\n"
for uid, name, path, _t, _n in SYNC:
    section += (f"\t\t{uid} /* {name} */ = {{\n"
                f"\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n"
                f"\t\t\tpath = {path};\n"
                f"\t\t\tsourceTree = \"<group>\";\n"
                f"\t\t}};\n")
section += "/* End PBXFileSystemSynchronizedRootGroup section */\n"
anchor = "/* End PBXFileReference section */\n"
assert src.count(anchor) == 1
src = src.replace(anchor, anchor + section)

# ---- 7. target membership ----
for uid, name, _p, target, _n in SYNC:
    start, end = find_object(src, target)
    block = src[start:end]
    deps = re.search(r"(\t\t\tdependencies = \(\n(?:\t\t\t\t.*\n)*?\t\t\t\);\n)", block)
    assert deps, f"{target} has no dependencies list"
    insert = f"\t\t\tfileSystemSynchronizedGroups = (\n\t\t\t\t{uid} /* {name} */,\n\t\t\t);\n"
    block = block[:deps.end()] + insert + block[deps.end():]
    src = src[:start] + block + src[end:]

# ---- 8. integrity assertions -------------------------------------------------
defs = re.findall(r"^\t{2,4}([0-9A-F]{24})(?: /\*.*?\*/)? = \{", src, re.M)
dupes = sorted({d for d in defs if defs.count(d) > 1})
assert not dupes, f"duplicate object ids: {dupes}"
defined = set(defs)
for uid, *_ in SYNC:
    assert uid in defined, uid
for target in ("F50000000000000000000001", "F50000000000000000000002", "F50000000000000000000003"):
    assert target in defined, target
assert src.count("isa = PBXNativeTarget;") == 3
assert src.count("isa = PBXFileSystemSynchronizedRootGroup;") == 3
assert "product-type.application" in src and "bundle.ui-testing" in src
# every child id of every group must be defined
for uid in set(re.findall(r"^[ \t]*([0-9A-F]{24})(?: /\*.*?\*/)? = \{\n[ \t]*isa = PBXGroup;", src, re.M)):
    start, end = find_object(src, uid)
    block = src[start:end]
    kids = re.findall(r"^\t\t\t\t([0-9A-F]{24})", block, re.M)
    missing = [k for k in kids if k not in defined]
    assert not missing, f"group {uid} references undefined {missing}"
assert len(src) < original_len
assert src.count("{") == src.count("}")

if "--write" in sys.argv:
    open(PATH, "w", encoding="utf-8").write(src)
    print(f"written: {original_len} -> {len(src)} bytes, {len(defined)} objects; "
          f"{removed_bf} build files and {removed_fr} file references folded into "
          f"{len(SYNC)} synchronized groups")
else:
    print("dry run only — assertions passed")
