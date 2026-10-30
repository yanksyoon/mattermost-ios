#!/usr/bin/env bash
# verify-dual-render-gates.sh — mechanical gate for the T26 dual-render debug affordances (T26-R R2/R3).
#
# The `-AV` gate in docs/dual-render.md §5 is only real if the *other* routes to a native decision
# cannot exist in a Release build. This script checks, in source, that they cannot:
#
#   1. `setOverride` / `clearOverride` / `clearAllOverrides` — the only APIs that can write an
#      arbitrary render mode — are declared inside `#if DEBUG` and are never *called* from a call
#      site that is not inside `#if DEBUG` (that is: never from Release-compilable code).
#      The call-site scan matches the qualified spelling the app actually uses
#      (`resolver.setOverride(…)`, T26-R review G1), and ignores declarations (`func setOverride`).
#   2. The resolver's single read path gates tiers 1 and 2 behind `debugAffordancesEnabled`, a
#      `#if DEBUG` (or `#if DEBUG || PERF_PROBE`) constant, and the only initialiser that accepts
#      the flag is `private`.
#   3. `SurfaceInspector.swift` — the one view that calls those setters — is entirely `#if DEBUG`.
#   4. No production code *supplies* a `remoteDefault` provider (tier 3): it is an unproduced seam
#      until a card passes `-AV` and documents the source of truth. Both wiring shapes are checked
#      — a labelled argument (`SurfaceModeResolver(remoteDefault: { … })`) and an assignment
#      (`self.remoteDefault = …`) (T26-R review G2).
#   5. `SurfaceDefaults.nativeApprovedSurfaces` is still the empty registry (a non-empty one is a
#      deliberate, separately-reviewed `-AV` change — pass `--allow-approved-registry` to skip).
#   6. `paneOwningSurfaces ⊆ nativeApprovedSurfaces` (T26-R R4, docs/dual-render.md §12.1): a surface
#      may not be declared pane-owning — and therefore able to release the per-server webview —
#      before it has been approved. Both `Set<Surface>` literals are parsed and compared as sets.
#   7. The webview release policy's one sanctioned bypass (`allowUnapproved: true`, §12.5) appears
#      only inside `#if DEBUG` / `#if DEBUG || PERF_PROBE`, so a Release build has no route from a
#      debug/measurement flag to a released pane. Same call-site + `debug_region_map` machinery as
#      gate 1; like gate 1 it fails when it finds no call site at all, because a scan that cannot
#      see the sanctioned seam is not proving anything.
#   8. The native UI tree is still a *synchronized folder* (T30b): `Mattermost/UI/Native`, and the
#      two test trees, are `PBXFileSystemSynchronizedRootGroup`s registered on their targets, every
#      file on disk under them is still tracked by git, and no `.swift` file in a synchronized tree
#      also carries a hand-written `PBXFileReference`/`PBXBuildFile` (that double registration is a
#      duplicate-compile, i.e. the failure mode of "revert the folder, keep the file").
#   9. `project.pbxproj` defines every object id exactly once (the duplicate-id defect that two
#      concurrent editors of that file produced twice on this board), and every id a group's
#      `children` list names is defined.
#  10. A diff may not introduce a new `PBXFileReference` for a source file (T30b): screen cards add
#      `.swift` files to a synchronized folder, where no project-file entry exists or is needed. The
#      one allowance is the non-source resources that stay outside the synchronized trees
#      (`Info.plist`, `Mattermost.entitlements`, `PrivacyInfo.xcprivacy`, `Assets.xcassets`), and
#      even those are a hard failure unless `--allow-pbxproj-resource-entry` is passed, so adding
#      one is a deliberate, reviewable act. The diff is `git diff <base>...HEAD` plus the working
#      tree; `--base`/`PBXPROJ_BASE` choose the base (default: the merge-base with `main` when on a
#      branch, `HEAD` on `main` — a run with no diff to audit says so and audits nothing).
#  11. Every `Surface` case is **consulted** by the app target — `resolvedMode(for: .<case>)`,
#      `SurfaceHost(.<case` or `defaultMode(for: .<case>)` in `Mattermost/` outside
#      `Core/RenderMode.swift` — or is `SurfaceDefaults.paneHostSurface`'s value (`.channelView`,
#      reached through that one constant), or is declared in `SurfaceDefaults.unhostedSurfaces`
#      ("a name a future card can key on, with no host and no switch today"). That literal is pinned
#      to `[.settings, .plugins]`; changing it needs `--allow-unhosted-change` (gate 5's shape), so
#      an inert key cannot be added or tolerated with a one-line edit. The gate measures
#      *references*, not effect: `.profile` passes while `ProfilePopoverPolicy` discards the value
#      (that limit is stated in the section itself).
#
# Scope and honest limits: this is a regex gate over the *app target* (`Mattermost/`, i.e. what
# ships), not over the test targets (tests may inject a provider), it skips comment lines, and it
# looks for direct calls and literal wiring shapes. The structural backstop is the Release build
# itself: the debug writers do not exist there, so a Release call site cannot compile at all.
#
# Usage: scripts/verify-dual-render-gates.sh [--allow-approved-registry]
#                                          [--base <git ref>] [--allow-pbxproj-resource-entry]
#                                          [--allow-unhosted-change]
# Exit: 0 = every gate holds; 1 = at least one violation (printed as "FAIL ...").
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

python3 - "$@" <<'PY'
import os, re, subprocess, sys

ALLOW_APPROVED = '--allow-approved-registry' in sys.argv
ALLOW_RESOURCE_ENTRY = '--allow-pbxproj-resource-entry' in sys.argv
ALLOW_UNHOSTED = '--allow-unhosted-change' in sys.argv
BASE_ARG = None
if '--base' in sys.argv:
    BASE_ARG = sys.argv[sys.argv.index('--base') + 1] if sys.argv.index('--base') + 1 < len(sys.argv) else None
BASE_ARG = BASE_ARG or os.environ.get('PBXPROJ_BASE')

SRC_DIRS = ['Mattermost']
DEBUG_WRITERS = ('setOverride', 'clearOverride', 'clearAllOverrides')
RESOLVER = 'Mattermost/Core/SurfaceModeResolver.swift'
INSPECTOR = 'Mattermost/UI/SurfaceInspector.swift'
RENDER_MODE = 'Mattermost/Core/RenderMode.swift'

failures = []
def ok(msg): print(f'  ok    {msg}')
def bad(msg):
    print(f'  FAIL  {msg}')
    failures.append(msg)

def swift_files():
    for d in SRC_DIRS:
        for root, _, files in os.walk(d):
            for f in files:
                if f.endswith('.swift'):
                    yield os.path.join(root, f)

def debug_region_map(path):
    """For each 1-based line number, True when the line is inside an active `#if DEBUG` region.

    Handles nested `#if` / `#elseif` / `#else` / `#endif` the way the compiler does for a Debug
    build, and treats `#if DEBUG` (and `#if os(...) && DEBUG`) as the debug switch. `#if !DEBUG`
    bodies are NOT debug regions.
    """
    lines = open(path, encoding='utf-8').read().splitlines()
    stack = []  # each entry: [is_debug_condition, in_else_branch]
    out = {}
    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.startswith('#if '):
            cond = stripped[4:].strip()
            is_debug = bool(re.search(r'(?<!!)\bDEBUG\b', cond))
            stack.append([is_debug, False])
            out[i] = any(entry[0] and not entry[1] for entry in stack[:-1])
            continue
        if stripped.startswith('#elseif '):
            if stack:
                cond = stripped[len('#elseif '):].strip()
                stack[-1][0] = bool(re.search(r'(?<!!)\bDEBUG\b', cond))
                stack[-1][1] = False
            out[i] = any(entry[0] and not entry[1] for entry in stack[:-1])
            continue
        if stripped.startswith('#else'):
            if stack:
                stack[-1][1] = True
            out[i] = any(entry[0] and not entry[1] for entry in stack[:-1])
            continue
        if stripped.startswith('#endif'):
            if stack:
                stack.pop()
            out[i] = any(entry[0] and not entry[1] for entry in stack)
            continue
        out[i] = any(entry[0] and not entry[1] for entry in stack)
    return out, lines

print('== 1. arbitrary-mode writers are declared and called only inside #if DEBUG ==')
resolver_region, resolver_lines = debug_region_map(RESOLVER)
for i, line in enumerate(resolver_lines, 1):
    if re.search(r'\bfunc (setOverride|clearOverride|clearAllOverrides)\b', line):
        name = re.search(r'\bfunc (\w+)', line).group(1)
        if resolver_region[i]:
            ok(f'{name} declared inside #if DEBUG ({RESOLVER}:{i})')
        else:
            bad(f'{name} declared OUTSIDE #if DEBUG ({RESOLVER}:{i})')

# The call-site scan. `\b(writer)\s*\(` — NOT `(?<![\w.])(writer)` — because every real call site in
# this tree is qualified (`resolver.setOverride(…)`), and a receiver-dot exclusion made the check
# blind to exactly the spelling the product uses (T26-R review G1). Declarations (`func writer(`)
# and comment lines are the only things skipped; both are excluded for a stated reason: a
# declaration is not a call, and a commented-out call cannot steer a surface.
CALL_SITE = re.compile(r'\b(' + '|'.join(DEBUG_WRITERS) + r')\s*\(')
DECLARATION = re.compile(r'\bfunc\s+(' + '|'.join(DEBUG_WRITERS) + r')\b')
leaks = []
scanned_calls = 0
for path in swift_files():
    region, lines = debug_region_map(path)
    for i, line in enumerate(lines, 1):
        if line.strip().startswith('//'):
            continue
        m = CALL_SITE.search(line)
        if not m or DECLARATION.search(line):
            continue
        scanned_calls += 1
        if not region[i]:
            leaks.append(f'{path}:{i}: {line.strip()}')
if leaks:
    bad('non-DEBUG call site(s) of a debug-only writer:')
    for leak in leaks:
        print('        ' + leak)
elif scanned_calls == 0:
    bad('found no call site of any debug-only writer at all — the scan is not seeing the code '
        '(expected the DEBUG inspector to call them); treat this as a gate failure, not a pass')
else:
    ok(f'all {scanned_calls} call site(s) of setOverride/clearOverride/clearAllOverrides '
       f'(incl. qualified `resolver.setOverride(…)`) are inside #if DEBUG')

print('== 2. tiers 1 and 2 are gated behind the compile-time debugAffordancesEnabled ==')
resolver_src = '\n'.join(resolver_lines)
# The condition may be `DEBUG` or `DEBUG || PERF_PROBE`. PERF_PROBE is the non-shipping perf-harness
# condition (T27) that `scripts/perf_probe.sh` passes on the xcodebuild command line so an optimised
# Release binary can still be launched with `-surfaceMode`; it is never in the project's own build
# settings, which check 2b proves. Nothing else may appear here.
if re.search(r'public static let debugAffordancesEnabled: Bool = \{\s*#if (?:DEBUG|DEBUG \|\| PERF_PROBE)'
             r'\s*return true\s*#else\s*return false\s*#endif', resolver_src):
    ok('debugAffordancesEnabled is a compile-time DEBUG (or DEBUG || PERF_PROBE) true/false constant')
else:
    bad('debugAffordancesEnabled is not the expected compile-time DEBUG constant')
if re.search(r'guard debugAffordances else \{[^}]*self\.overrides = \[:\][^}]*self\.launchOverrides = \[:\]', resolver_src, re.S):
    ok('read path (init) decodes no override when debug affordances are off')
else:
    bad('read path (init) has no "empty tiers when debug affordances are off" branch')
if re.search(r'private init\(preferences', resolver_src):
    ok('the one initialiser that takes the flag is private')
else:
    bad('the initialiser taking debugAffordances is not private (Release code could opt in)')
if re.search(r'guard Self\.debugAffordancesEnabled else \{ return \}', resolver_src):
    ok('persist() writes nothing when debug affordances are off')
else:
    bad('persist() has no debug-affordance gate')

print('== 2b. PERF_PROBE (the only other way to enable the debug tiers) is not in the project ==')
# PERF_PROBE must arrive from the harness command line only. If it ever lands in the project's build
# settings, every Release build would carry the debug tiers — exactly what this gate exists to stop.
probe_hits = []
for root, _dirs, files in os.walk('.'):
    if root.startswith(('./build', './.git', './.build')):
        continue
    for name in files:
        if name.endswith(('.pbxproj', '.xcconfig')) or name == 'project.yml':
            path = os.path.join(root, name)
            try:
                text = open(path, encoding='utf-8', errors='replace').read()
            except OSError:
                continue
            for i, line in enumerate(text.splitlines(), 1):
                if 'PERF_PROBE' in line:
                    probe_hits.append(f'{path}:{i}: {line.strip()}')
if probe_hits:
    bad('PERF_PROBE is defined in project build settings (release builds would carry the debug tiers):')
    for hit in probe_hits:
        print('        ' + hit)
else:
    ok('PERF_PROBE appears in no .pbxproj/.xcconfig/project.yml — command line only')

print('== 3. the inspector view is entirely #if DEBUG ==')
inspector_lines = open(INSPECTOR, encoding='utf-8').read().splitlines()
code_lines = [l.strip() for l in inspector_lines if l.strip() and not l.strip().startswith('//')]
if code_lines[:2] == ['import SwiftUI', '#if DEBUG'] and code_lines[-1] == '#endif':
    ok(f'{INSPECTOR} is wrapped in a single #if DEBUG ... #endif')
else:
    bad(f'{INSPECTOR} is not fully wrapped in #if DEBUG (first lines: {code_lines[:3]}, last: {code_lines[-1] if code_lines else None})')

print('== 4. no production producer for the remote (tier 3) default ==')
# A *producer* is any app-target code that supplies a provider, in either shape section 5 names:
#   (a) a labelled argument — `SurfaceModeResolver(remoteDefault: { … })`. This is how §5 describes
#       tier 3 ("an injected provider"), and it is the shape the previous check missed because it
#       only matched assignments (T26-R review G2).
#   (b) an assignment — `X.remoteDefault = …`, e.g. a future `self.remoteDefault = provider`.
# Three argument shapes are not producers, each for a stated reason:
#   `remoteDefault: ((Surface) -> SurfaceRenderMode?)?`  the parameter/property *type* annotation
#   `remoteDefault: remoteDefault`                       the convenience init forwarding its own parameter
#   `remoteDefault: nil`                                 an explicitly absent provider
# And one assignment is not a producer: `self.remoteDefault = remoteDefault`, the private
# initialiser storing the very parameter it was handed — identical by construction to what the
# public initialiser received, so it cannot introduce a provider of its own (any other right-hand
# side, e.g. `self.remoteDefault = { … }`, is reported).
TYPE_ARG = re.compile(r'^(\(\(Surface\)|\(Surface\))')
producers = []
for path in swift_files():
    for i, line in enumerate(open(path, encoding='utf-8').read().splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith('//'):
            continue
        hit = False
        for m in re.finditer(r'\bremoteDefault\s*:\s*', stripped):
            arg = stripped[m.end():]
            if TYPE_ARG.match(arg) or re.match(r'remoteDefault\b', arg) or re.match(r'nil\b', arg):
                continue
            producers.append(f'{path}:{i}: {stripped}')
            hit = True
            break
        if hit:
            continue
        for m in re.finditer(r'\bremoteDefault\s*=(?!=)\s*(.*)$', stripped):
            rhs = m.group(1).strip().rstrip(';')
            if re.fullmatch(r'remoteDefault', rhs):
                continue
            if re.fullmatch(r'nil', rhs):
                continue
            producers.append(f'{path}:{i}: {stripped}')
            break
if producers:
    bad('remoteDefault is supplied in production code (tier 3 must stay an unproduced seam):')
    for p in producers:
        print('        ' + p)
else:
    ok('no production producer for remoteDefault — neither a `remoteDefault:` argument nor an '
       'assignment (tier 3 stays a seam)')

print('== 5. the -AV approval registry ==')
render_src = open(RENDER_MODE, encoding='utf-8').read()
approved = re.search(r'nativeApprovedSurfaces: Set<Surface> = (\[[^\]]*\])', render_src)
if not approved:
    bad('nativeApprovedSurfaces could not be read')
elif approved.group(1).strip() == '[]':
    ok('nativeApprovedSurfaces is empty (no surface is native-by-default)')
elif ALLOW_APPROVED:
    ok(f'nativeApprovedSurfaces is non-empty ({approved.group(1).strip()}) — allowed by flag')
else:
    bad(f'nativeApprovedSurfaces is non-empty ({approved.group(1).strip()}) without -AV evidence '
        'in this run; pass --allow-approved-registry when the approval commit is the subject')

print('== 6. pane ownership is a subset of the -AV approval registry ==')
# §12.1: `paneOwningSurfaces ⊆ nativeApprovedSurfaces`. A pane-owning surface is the *only* thing
# that can release a per-server webview, so declaring one before its `-AV` has passed would put the
# eviction power behind an unvalidated card. Both literals are parsed as `Set<Surface>` text; the
# surface cases are compared, not the formatting, so `.channelView` and a reordered literal read the
# same (this gate cares about the claim, not the spelling).
def surface_set(literal):
    return set(re.findall(r'\.([A-Za-z_][A-Za-z0-9_]*)', literal or ''))

pane_owning = re.search(r'paneOwningSurfaces: Set<Surface> = (\[[^\]]*\])', render_src)
if not pane_owning:
    bad('paneOwningSurfaces could not be read from '
        f'{RENDER_MODE} (expected `paneOwningSurfaces: Set<Surface> = [ … ]`)')
else:
    pane_set = surface_set(pane_owning.group(1))
    approved_set = surface_set(approved.group(1)) if approved else set()
    unknown = sorted(s for s in pane_set | approved_set
                     if s not in {c for c in re.findall(r'case (\w+)', render_src)})
    if unknown:
        bad(f'registry literal(s) name something that is not a Surface case: {unknown}')
    elif not pane_set:
        ok('paneOwningSurfaces is empty (no card owns the pane) — trivially a subset of '
           f'nativeApprovedSurfaces {sorted(approved_set)}')
    elif pane_set <= approved_set:
        ok(f'paneOwningSurfaces {sorted(pane_set)} is a subset of nativeApprovedSurfaces '
           f'{sorted(approved_set)}')
    else:
        bad(f'paneOwningSurfaces {sorted(pane_set)} is NOT a subset of nativeApprovedSurfaces '
            f'{sorted(approved_set)} — unapproved: {sorted(pane_set - approved_set)} '
            '(pane ownership is an -AV claim, docs/dual-render.md §12.1)')

print('== 7. the release-policy bypass (allowUnapproved: true) compiles only in a debug region ==')
# §12.5: `allowUnapproved: true` exists for measurement (the `nativeEvicted` perf arm and the DEBUG
# UI-test launch flag), never for shipping. Same shape as gate 1's call-site scan: comment lines and
# the declaration (`allowUnapproved: Bool = false`) cannot match, and a scan that finds nothing is a
# failure rather than a pass — the sanctioned DEBUG seam must be visible.
BYPASS_CALL = re.compile(r'\ballowUnapproved\s*:\s*true\b')
bypass_sites = []
for path in swift_files():
    region, lines = debug_region_map(path)
    for i, line in enumerate(lines, 1):
        if line.strip().startswith('//'):
            continue
        if not BYPASS_CALL.search(line):
            continue
        bypass_sites.append((path, i, line.strip(), region[i]))
bypass_leaks = [f'{p}:{i}: {text}' for (p, i, text, is_debug) in bypass_sites if not is_debug]
if bypass_leaks:
    bad('call site(s) outside #if DEBUG / #if DEBUG || PERF_PROBE pass allowUnapproved: true:')
    for leak in bypass_leaks:
        print('        ' + leak)
elif not bypass_sites:
    bad('found no call site passing allowUnapproved: true at all — the sanctioned DEBUG seam is '
        'invisible to this scan (expected `WebViewReleasePolicy.shouldRelease` to make one); treat '
        'this as a gate failure, not a pass')
else:
    where = ', '.join(f'{p}:{i}' for (p, i, _t, _d) in bypass_sites)
    ok(f'all {len(bypass_sites)} call site(s) passing allowUnapproved: true are inside a debug '
       f'region ({where}); a Release build cannot reach it')

print('== 8. the native UI tree is still a synchronized folder (T30b) ==')
# Why this gate exists: the per-file PBXFileReference/PBXBuildFile pairs are what two workers editing
# project.pbxproj collide on. The synchronized folder is the fix, and it is invisible in a build
# log — reverting it (Xcode's "Convert to group", or someone re-adding one file by hand) restores the
# collision silently. So the claim is asserted, per tree, together with the two ways it breaks:
# a group that no target registers (files build but nothing compiles them) and a folder git does not
# carry (an empty folder on a fresh clone).
PBXPROJ = 'Mattermost.xcodeproj/project.pbxproj'
pbx = open(PBXPROJ, encoding='utf-8').read()

def pbx_objects(text):
    """(id, isa or None, body) for every `\\t\\t<id> /* comment */ = { ... };` object.

    A regex cannot delimit these objects: a comment may run across lines, and `};` inside a nested
    list is not the end of the object (the first version of this gate matched one object from line 10
    to line 189 for exactly that reason). So the braces are counted, with quoted strings skipped so a
    brace inside a string cannot unbalance the scan.
    """
    for m in re.finditer(r'^[ \t]*([0-9A-F]{24})(?: /\*[^\n]*?\*/)? = \{', text, re.M):
        start = text.index('{', m.start())
        depth, i, in_str, escaped = 0, start, False, False
        while i < len(text):
            ch = text[i]
            if in_str:
                if escaped:
                    escaped = False
                elif ch == '\\':
                    escaped = True
                elif ch == '"':
                    in_str = False
            elif ch == '"':
                in_str = True
            elif ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    body = text[start:i + 1]
                    isa = re.search(r'^\s*isa = (\w+);', body, re.M)
                    yield m.group(1), (isa.group(1) if isa else None), body
                    break
            i += 1


objects = list(pbx_objects(pbx))
synchronized = {oid: body for oid, isa, body in objects if isa == 'PBXFileSystemSynchronizedRootGroup'}
groups_by_path = {}
for oid, body in synchronized.items():
    path = re.search(r'path = ([^;]+);', body)
    if path:
        groups_by_path[path.group(1).strip().strip('"')] = oid

SYNC_TREES = {
    'Mattermost/UI/Native': 'F50000000000000000000001',   # the native screen tree (this card's unlock)
    'MattermostTests': 'F50000000000000000000002',        # a screen card ships its unit tests too
    'MattermostUITests': 'F50000000000000000000003',
}
SEED_FILE = 'Mattermost/UI/Native/SheetHost.swift'        # component-map §1: the shared sheet host
targets = {oid: body for oid, isa, body in objects if isa == 'PBXNativeTarget'}
synced_basenames = set()
for tree, target in SYNC_TREES.items():
    gid = groups_by_path.get(tree)
    if not gid:
        bad(f'{tree} is NOT a PBXFileSystemSynchronizedRootGroup — the tree was reverted to '
            f'hand-registered files, which is the collision this card removed (docs/parallel-work.md §3)')
        continue
    listed = re.search(r'fileSystemSynchronizedGroups = \((.*?)\);', targets.get(target, ''), re.S)
    if not listed or gid not in listed.group(1):
        bad(f'{tree} is a synchronized group ({gid}) but target {target} does not list it in '
            f'fileSystemSynchronizedGroups — its files would not be built at all')
    else:
        ok(f'{tree} is a synchronized group ({gid}) registered on target {target}')
    tracked = subprocess.run(['git', 'ls-files', '--', tree], capture_output=True, text=True).stdout.split()
    if not tracked:
        bad(f'{tree} has no git-tracked files — a synchronized folder git does not carry is an empty '
            f'directory on every fresh clone, and the group then matches nothing')
    else:
        ok(f'{tree}: {len(tracked)} git-tracked file(s)')
    if tree == 'Mattermost/UI/Native' and SEED_FILE not in tracked:
        bad(f'{SEED_FILE} is missing from the synchronized UI tree (component-map §1 designates it as '
            f'the shared file the folder is seeded with)')
    synced_basenames |= {os.path.basename(f) for f in tracked if f.endswith('.swift')}

# Double registration: a file in a synchronized tree must have no hand-written entry. The pair
# (`PBXFileReference` + `in Sources`) is what Xcode writes for a manually added file; both halves are
# checked because either one alone makes the build compile the file twice.
double = []
for name in sorted(synced_basenames):
    if re.search(r'/\* ' + re.escape(name) + r' in (?:Sources|Resources) \*/', pbx):
        double.append(name)
if double:
    bad('synchronized-tree file(s) also registered in the project file (duplicate compile): '
        + ', '.join(double))
else:
    ok(f'none of the {len(synced_basenames)} source file(s) in the synchronized trees has a '
       f'hand-written project-file entry')

print('== 9. project.pbxproj defines every object id exactly once ==')
# The defect this card repaired: two workers each picked an unused-looking object id for their new
# file, and the file ended up with the same id defined twice. Xcode tolerates it by picking one and
# dropping the other, so the build stays green while a file silently stops being compiled.
definitions = re.findall(r'^\t{2,4}([0-9A-F]{24})(?: /\*.*?\*/)? = \{', pbx, re.M)
duplicates = sorted({d for d in definitions if definitions.count(d) > 1})
if duplicates:
    bad(f'{PBXPROJ} defines the same object id more than once: {duplicates} '
        f'(two workers wrote the same id; one of the two entries is silently dropped)')
else:
    ok(f'all {len(set(definitions))} object ids are defined exactly once '
       f'({len(definitions)} definitions)')
defined_ids = set(definitions)
dangling = []
for oid, isa, body in objects:
    if isa != 'PBXGroup':
        continue
    for child in re.findall(r'^[ \t]+([0-9A-F]{24})(?: /\*[^\n]*?\*/)?,', body, re.M):
        if child not in defined_ids:
            dangling.append(f'{oid} -> {child}')
if dangling:
    bad(f'group(s) name object ids that are not defined: {dangling}')
else:
    ok('every id named by a group\'s children list is defined')

print('== 10. this diff adds no PBXFileReference outside the allowance (T30b) ==')
# Acceptance: "adding a new file to the tree requires no pbxproj edit". A card that adds a .swift
# file therefore must not appear here at all — the synchronized folder picks it up. The single
# allowance is the four non-source items that stay outside the synchronized trees (the card's own
# list: the folder "mixes sources with Info.plist, Mattermost.entitlements, PrivacyInfo.xcprivacy and
# Assets.xcassets, and those must keep their current handling"), and even those are only accepted with
# an explicit flag, so a resource registration is a deliberate act rather than a default.
def git(*args):
    return subprocess.run(['git', *args], capture_output=True, text=True).stdout

base = BASE_ARG
if not base:
    branch = git('rev-parse', '--abbrev-ref', 'HEAD').strip()
    if branch and branch != 'main' and git('rev-parse', '--verify', '--quiet', 'main').strip():
        base = git('merge-base', 'main', 'HEAD').strip() or 'HEAD'
    else:
        base = 'HEAD'
diff = git('diff', f'{base}...HEAD', '--', PBXPROJ) + git('diff', 'HEAD', '--', PBXPROJ)
added_lines = [line[1:] for line in diff.splitlines() if line.startswith('+') and not line.startswith('+++')]
DIFF_FILE_REF = re.compile(
    r'^\s*([0-9A-F]{24})\s*/\*(.*?)\*/\s*= \{isa = PBXFileReference;.*?path = ([^;]+);')
ALLOWED_RESOURCES = {'Info.plist', 'Mattermost.entitlements', 'PrivacyInfo.xcprivacy', 'Assets.xcassets'}
offending = []
for line in added_lines:
    m = DIFF_FILE_REF.match(line)
    if not m:
        continue
    _id, name, path = m.group(1), m.group(2).strip(), m.group(3).strip().strip('"')
    if path.endswith('.swift'):
        offending.append(f'{name}: a .swift file belongs in a synchronized folder, not in {PBXPROJ}')
    elif path not in ALLOWED_RESOURCES:
        offending.append(f'{name}: "{path}" is not one of the allowed non-source resources '
                         f'{sorted(ALLOWED_RESOURCES)}')
    elif not ALLOW_RESOURCE_ENTRY:
        offending.append(f'{name}: resource entry needs --allow-pbxproj-resource-entry (this is the '
                         f'one allowance, and it is deliberate)')
if offending:
    bad(f'new PBXFileReference(s) introduced against {base} outside the allowance:')
    for item in offending:
        print('        ' + item)
elif added_lines:
    ok(f'{PBXPROJ} changed against {base} but added no PBXFileReference — new files ride the '
       f'synchronized folders')
else:
    print(f'  note  no change to {PBXPROJ} against {base} — nothing to audit here. Run a card branch '
          f'with --base main to audit its diff.')

print('== 11. every Surface case is consulted, or declared unhosted ==')
# Why this gate exists: a catalogue key nobody reads is a decoration, and nothing used to check for
# one. `Surface.threads` was consulted nowhere for several review rounds (F1 of
# `docs/t_8f9f5449-profile-popover-parity.md`, retired by `t_7ffa9e76`) precisely because no card's
# acceptance list asked "does this card consult its surface?" — the class is bigger than that case,
# which is why this gate is general.
#
# A case is CONSULTED when the app target reads it in one of the three documented shapes outside
# `Core/RenderMode.swift`:
#     resolvedMode(for: .<case>)  |  SurfaceHost(.<case  |  defaultMode(for: .<case>)
# or when the case IS `SurfaceDefaults.paneHostSurface`'s value (`.channelView`): the constant is what
# `ContentView`, `RootView` and `NativeNavigation` read, so the pane host has three production call
# sites while the literal `.channelView` never appears in their gate expressions. A case that is
# none of those must be DECLARED in `SurfaceDefaults.unhostedSurfaces` — "a name a future card can
# key on, with no host and no switch today" — and that literal is pinned to `[.settings, .plugins]`.
# Changing the pin (including emptying it) requires --allow-unhosted-change: a deliberate act that
# shows in the diff, the same shape as gate 5's --allow-approved-registry.
#
# HONEST LIMIT, stated here so nobody discovers it later: this gate measures *references*, not
# *effect*. `.profile` passes — `ChannelView` passes it to `ProfilePopoverPolicy`, which discards the
# value — so a case that is read and ignored is invisible to a regex. Proving "the value changes what
# is drawn" would need a running UI, i.e. the -AV programme, not this script; the read-and-discarded
# class is card `t_9d0b0e11`'s subject.
surface_body = render_src[render_src.index('public enum Surface:'):render_src.index('public var id: String')]
surface_cases = re.findall(r'^\s*case (\w+)$', surface_body, re.M)
pane_host = re.search(r'paneHostSurface: Surface = \.(\w+)', render_src)
pane_host_case = pane_host.group(1) if pane_host else None
unhosted_literal = re.search(r'unhostedSurfaces: Set<Surface> = (\[[^\]]*\])', render_src)

if not surface_cases:
    bad(f'could not read a single `case` from the Surface enum in {RENDER_MODE}')
if not pane_host_case:
    bad(f'could not read `paneHostSurface: Surface = .<case>` from {RENDER_MODE}')

UNHOSTED_PIN = {'settings', 'plugins'}
if not unhosted_literal:
    bad(f'unhostedSurfaces could not be read from {RENDER_MODE} (expected '
        f'`unhostedSurfaces: Set<Surface> = [ … ]` next to the other catalogue declarations)')
    unhosted_set = set()
else:
    unhosted_set = surface_set(unhosted_literal.group(1))
    unhosted_text = unhosted_literal.group(1).strip()
    non_cases = sorted(unhosted_set - set(surface_cases))
    if non_cases:
        bad(f'unhostedSurfaces names something that is not a Surface case: {non_cases}')
    if unhosted_set == UNHOSTED_PIN:
        ok(f'unhostedSurfaces is exactly {unhosted_text} — the pinned declaration')
    elif ALLOW_UNHOSTED:
        ok(f'unhostedSurfaces is {unhosted_text} — allowed by --allow-unhosted-change '
           f'(pinned set is {sorted(UNHOSTED_PIN)})')
    else:
        bad(f'unhostedSurfaces is {unhosted_text}, not the pinned '
            f'[{", ".join(sorted(UNHOSTED_PIN))}] — a catalogue key may only be declared inert by a '
            f'card that records why; pass --allow-unhosted-change when that card is the subject')

CONSULT_SHAPES = (
    'resolvedMode\\(for:\\s*\\.%s\\b',
    'SurfaceHost\\(\\s*\\.%s\\b',
    'defaultMode\\(for:\\s*\\.%s\\b',
)
# Comment lines are skipped for the same reason gate 1 skips them: a doc comment saying "nothing
# reads resolvedMode(for: .threads) any more" must not count as a read.
def consulted_in(case):
    pats = [re.compile(shape % re.escape(case)) for shape in CONSULT_SHAPES]
    for path in sorted(swift_files()):
        if path == RENDER_MODE:
            continue
        for i, line in enumerate(open(path, encoding='utf-8').read().splitlines(), 1):
            if line.strip().startswith('//'):
                continue
            if any(p.search(line) for p in pats):
                return f'{path}:{i}'
    return None

unconsulted = []
for case in surface_cases:
    if case == pane_host_case:
        ok(f'.{case:<12} consulted at SurfaceDefaults.paneHostSurface '
           f'({RENDER_MODE}; three call sites read the constant)')
        continue
    where = consulted_in(case)
    if where:
        ok(f'.{case:<12} consulted at {where}')
    elif case in unhosted_set:
        ok(f'.{case:<12} declared unhosted')
    else:
        bad(f'.{case:<12} neither consulted nor declared unhosted — a catalogue key with no effect '
            f'(consult it, retire it, or declare it in SurfaceDefaults.unhostedSurfaces)')
        unconsulted.append(case)
if not unconsulted and surface_cases:
    ok(f'all {len(surface_cases)} Surface case(s) are consulted, or declared unhosted')

print()
if failures:
    print(f'RESULT: FAIL — {len(failures)} dual-render gate violation(s).')
    sys.exit(1)
print('RESULT: PASS — dual-render debug affordances cannot reach a Release build.')
PY
