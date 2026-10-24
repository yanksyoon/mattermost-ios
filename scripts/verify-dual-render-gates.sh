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
#
# Scope and honest limits: this is a regex gate over the *app target* (`Mattermost/`, i.e. what
# ships), not over the test targets (tests may inject a provider), it skips comment lines, and it
# looks for direct calls and literal wiring shapes. The structural backstop is the Release build
# itself: the debug writers do not exist there, so a Release call site cannot compile at all.
#
# Usage: scripts/verify-dual-render-gates.sh [--allow-approved-registry]
# Exit: 0 = every gate holds; 1 = at least one violation (printed as "FAIL ...").
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

python3 - "$@" <<'PY'
import os, re, sys

ALLOW_APPROVED = '--allow-approved-registry' in sys.argv

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

print()
if failures:
    print(f'RESULT: FAIL — {len(failures)} dual-render gate violation(s).')
    sys.exit(1)
print('RESULT: PASS — dual-render debug affordances cannot reach a Release build.')
PY
