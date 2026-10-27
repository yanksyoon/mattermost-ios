#!/usr/bin/env python3
"""T44c — wire the vendored WebRTC.xcframework into Mattermost.xcodeproj, and register the new
`Mattermost/Core/Calls` source tree as a synchronized group.

One deterministic transform of `Mattermost.xcodeproj/project.pbxproj`, run once and kept as the
provenance of the edit (the same pattern as `scripts/t30b-pbxproj-sync.py`). It is brace-scanner
based, asserts the pre-edit shape, asserts the post-edit shape, and writes only when `--write` is
given.

What it adds:

  * one PBXFileReference for `Mattermost/Vendor/WebRTC.xcframework` (a committed vendor drop —
    SwiftPM's `binaryTarget(url:)` artifact downloader hangs on this host, docs/t44a-calls-spike.md §3);
  * a `Vendor` group under the `Mattermost` group, so the framework is visible in the project tree;
  * **link** (Frameworks build phase) + **embed** (a new PBXCopyFilesBuildPhase,
    dstSubfolderSpec = 10 → `Contents/Frameworks`, `CodeSignOnCopy`) for the app target, and link
    for the unit-test target (the tests `import WebRTC` and run inside the app host);
  * a `PBXFileSystemSynchronizedRootGroup` for `Mattermost/Core/Calls`, attached to the app target —
    the same shape the app already uses for `Mattermost/UI/Native`, so a Calls source file does not
    need a pbxproj edit.

Usage: scripts/t44c-pbxproj-add-webrtc.py [--write]
"""
import re
import sys

PATH = "Mattermost.xcodeproj/project.pbxproj"

FRAMEWORK_REF = "D00000000000000000000001"
LINK_APP = "D00000000000000000000002"
EMBED_BUILD_FILE = "D00000000000000000000003"
EMBED_PHASE = "D00000000000000000000004"
VENDOR_GROUP = "D00000000000000000000005"
LINK_TESTS = "D00000000000000000000006"
CALLS_GROUP = "D00000000000000000000007"

APP_TARGET = "F50000000000000000000001"
APP_FRAMEWORKS = "F60000000000000000000002"
TEST_FRAMEWORKS = "F60000000000000000000005"
MATTERMOST_GROUP = "F00000000000000000000004"
MAIN_GROUP = "F00000000000000000000002"

NEW_IDS = [FRAMEWORK_REF, LINK_APP, EMBED_BUILD_FILE, EMBED_PHASE, VENDOR_GROUP, LINK_TESTS,
           CALLS_GROUP]


def find_object(text, uid):
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
                return m.start(), end
        j += 1
    raise AssertionError(f"object {uid} unterminated")


def insert_before_section_end(src, section, addition):
    anchor = f"/* End {section} section */"
    assert src.count(anchor) == 1, anchor
    return src.replace(anchor, addition + anchor)


def add_to_list(src, uid, entry, list_name="files"):
    start, end = find_object(src, uid)
    block = src[start:end]
    pattern = re.compile(r"(\t\t\t" + list_name + r" = \(\n)(.*?)(\t\t\t\);)", re.S)
    m = pattern.search(block)
    assert m, f"{uid} has no {list_name} list"
    body = m.group(2)
    assert entry.strip().split(" /*")[0] not in body, f"{entry} already in {uid}"
    new_block = block[:m.end(2)] + "\t\t\t\t" + entry + "\n" + block[m.end(2):]
    return src[:start] + new_block + src[end:]


src = open(PATH, encoding="utf-8").read()
original_len = len(src)

# ---------------------------------------------------------------- pre-edit shape
for uid in NEW_IDS:
    assert not re.search(r"^[ \t]*" + uid, src, re.M), f"{uid} already present — already migrated?"
assert "WebRTC.xcframework" not in src, "the framework is already registered"
assert src.count("isa = PBXNativeTarget;") == 3
assert src.count("isa = PBXFileSystemSynchronizedRootGroup;") == 3
assert src.count("isa = PBXCopyFilesBuildPhase;") == 0

# ---------------------------------------------------------------- 1. file reference
ref_line = (f"\t\t{FRAMEWORK_REF} /* WebRTC.xcframework */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = wrapper.xcframework; path = WebRTC.xcframework; "
            f"sourceTree = \"<group>\"; }};\n")
src = insert_before_section_end(src, "PBXFileReference", ref_line)

# ---------------------------------------------------------------- 2. build files
build_lines = (
    f"\t\t{LINK_APP} /* WebRTC.xcframework in Frameworks */ = {{isa = PBXBuildFile; "
    f"fileRef = {FRAMEWORK_REF} /* WebRTC.xcframework */; }};\n"
    f"\t\t{LINK_TESTS} /* WebRTC.xcframework in Frameworks (tests) */ = {{isa = PBXBuildFile; "
    f"fileRef = {FRAMEWORK_REF} /* WebRTC.xcframework */; }};\n"
    f"\t\t{EMBED_BUILD_FILE} /* WebRTC.xcframework in Embed Frameworks */ = {{isa = PBXBuildFile; "
    f"fileRef = {FRAMEWORK_REF} /* WebRTC.xcframework */; "
    f"settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }};\n")
src = insert_before_section_end(src, "PBXBuildFile", build_lines)

# ---------------------------------------------------------------- 3. the embed phase
embed_phase = (f"\t\t{EMBED_PHASE} /* Embed Frameworks */ = {{\n"
               f"\t\t\tisa = PBXCopyFilesBuildPhase;\n"
               f"\t\t\tbuildActionMask = 2147483647;\n"
               f"\t\t\tdstPath = \"\";\n"
               f"\t\t\tdstSubfolderSpec = 10;\n"
               f"\t\t\tfiles = (\n"
               f"\t\t\t\t{EMBED_BUILD_FILE} /* WebRTC.xcframework in Embed Frameworks */,\n"
               f"\t\t\t);\n"
               f"\t\t\tname = \"Embed Frameworks\";\n"
               f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
               f"\t\t}};\n")
anchor = "/* End PBXContainerItemProxy section */\n"
assert src.count(anchor) == 1
src = src.replace(anchor, anchor + "\n/* Begin PBXCopyFilesBuildPhase section */\n" + embed_phase
                  + "/* End PBXCopyFilesBuildPhase section */\n")

# ---------------------------------------------------------------- 4. the Calls sync group
calls_group = (f"\t\t{CALLS_GROUP} /* Calls */ = {{\n"
               f"\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n"
               f"\t\t\tpath = Mattermost/Core/Calls;\n"
               f"\t\t\tsourceTree = \"<group>\";\n"
               f"\t\t}};\n")
src = insert_before_section_end(src, "PBXFileSystemSynchronizedRootGroup", calls_group)

# ---------------------------------------------------------------- 5. vendor group
vendor_group = (f"\t\t{VENDOR_GROUP} /* Vendor */ = {{\n"
                f"\t\t\tisa = PBXGroup;\n"
                f"\t\t\tchildren = (\n"
                f"\t\t\t\t{FRAMEWORK_REF} /* WebRTC.xcframework */,\n"
                f"\t\t\t);\n"
                f"\t\t\tpath = Vendor;\n"
                f"\t\t\tsourceTree = \"<group>\";\n"
                f"\t\t}};\n")
src = insert_before_section_end(src, "PBXGroup", vendor_group)

# the Vendor group hangs off the Mattermost group (whose path is `Mattermost`)
start, end = find_object(src, MATTERMOST_GROUP)
block = src[start:end]
anchor = "\t\t\t\tF200000000000000000000C1 /* emoji.json */,\n"
assert block.count(anchor) == 1
block = block.replace(anchor, anchor + f"\t\t\t\t{VENDOR_GROUP} /* Vendor */,\n")
src = src[:start] + block + src[end:]

# the synchronized Calls group sits at the main group, like the other three
start, end = find_object(src, MAIN_GROUP)
block = src[start:end]
anchor = "\t\t\t\tC00000000000000000000003 /* MattermostUITests */,\n"
assert block.count(anchor) == 1
block = block.replace(anchor, anchor + f"\t\t\t\t{CALLS_GROUP} /* Calls */,\n")
src = src[:start] + block + src[end:]

# ---------------------------------------------------------------- 6. link + attach to the app
src = add_to_list(src, APP_FRAMEWORKS,
                  f"{LINK_APP} /* WebRTC.xcframework in Frameworks */,")
src = add_to_list(src, TEST_FRAMEWORKS,
                  f"{LINK_TESTS} /* WebRTC.xcframework in Frameworks (tests) */,")

start, end = find_object(src, APP_TARGET)
block = src[start:end]
phases = re.search(r"(\t\t\tbuildPhases = \(\n)(.*?)(\t\t\t\);)", block, re.S)
assert phases, "app target has no buildPhases"
phase_body = phases.group(2)
anchor = f"\t\t\t\t{APP_FRAMEWORKS} /* Frameworks */,\n"
assert phase_body.count(anchor) == 1
new_phases = phase_body.replace(anchor, anchor + f"\t\t\t\t{EMBED_PHASE} /* Embed Frameworks */,\n")
block = block[:phases.start(2)] + new_phases + block[phases.end(2):]

groups = re.search(r"(\t\t\tfileSystemSynchronizedGroups = \(\n)(.*?)(\t\t\t\);)", block, re.S)
assert groups, "app target has no fileSystemSynchronizedGroups"
anchor = "\t\t\t\tC00000000000000000000001 /* Native */,\n"
assert groups.group(2).count(anchor) == 1
new_groups = groups.group(2).replace(anchor, anchor + f"\t\t\t\t{CALLS_GROUP} /* Calls */,\n")
block = block[:groups.start(2)] + new_groups + block[groups.end(2):]
src = src[:start] + block + src[end:]

# ---------------------------------------------------------------- post-edit shape
defs = re.findall(r"^\t{2,4}([0-9A-F]{24})(?: /\*.*?\*/)? = \{", src, re.M)
dupes = sorted({d for d in defs if defs.count(d) > 1})
assert not dupes, f"duplicate object ids: {dupes}"
defined = set(defs)
for uid in NEW_IDS:
    assert uid in defined, uid
assert src.count("isa = PBXNativeTarget;") == 3
assert src.count("isa = PBXFileSystemSynchronizedRootGroup;") == 4
assert src.count("isa = PBXCopyFilesBuildPhase;") == 1
assert src.count("WebRTC.xcframework") == 12, src.count("WebRTC.xcframework")
assert src.count("{") == src.count("}"), "unbalanced braces"
for uid in (APP_FRAMEWORKS, TEST_FRAMEWORKS, APP_TARGET, MATTERMOST_GROUP, MAIN_GROUP):
    assert uid in defined, uid

if "--write" in sys.argv:
    open(PATH, "w", encoding="utf-8").write(src)
    print(f"written: {original_len} -> {len(src)} bytes, {len(defined)} objects")
else:
    print("dry run only — assertions passed")
