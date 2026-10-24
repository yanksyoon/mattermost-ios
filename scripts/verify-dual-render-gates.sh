#!/usr/bin/env bash
# verify-dual-render-gates.sh — mechanical gate for the T26 dual-render debug affordances (T26-R R2/R3).
#
# The `-AV` gate in docs/dual-render.md §5 is only real if the *other* routes to a native decision
# cannot exist in a Release build. This script checks, in source, that they cannot:
#
#   1. `setOverride` / `clearOverride` / `clearAllOverrides` — the only APIs that can write an
#      arbitrary render mode — are declared inside `#if DEBUG` and are never *called* from a call
#      site that is not inside `#if DEBUG` (that is: never from Release-compilable code).
#   2. The resolver's single read path gates tiers 1 and 2 behind `debugAffordancesEnabled`, a
#      `#if DEBUG` constant, and the only initialiser that accepts the flag is `private`.
#   3. `SurfaceInspector.swift` — the one view that calls those setters — is entirely `#if DEBUG`.
#   4. No production code wires `remoteDefault` (tier 3): it is an unproduced seam until a card
#      passes `-AV` and documents the source of truth.
#   5. `SurfaceDefaults.nativeApprovedSurfaces` is still the empty registry (a non-empty one is a
#      deliberate, separately-reviewed `-AV` change — pass `--allow-approved-registry` to skip).
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

leaks = []
for path in swift_files():
    region, lines = debug_region_map(path)
    for i, line in enumerate(lines, 1):
        for writer in DEBUG_WRITERS:
            if re.search(rf'(?<![\w.]){writer}\s*\(', line) and not re.search(rf'\bfunc {writer}\b', line):
                if not region[i]:
                    leaks.append(f'{path}:{i}: {line.strip()}')
if leaks:
    bad('non-DEBUG call site(s) of a debug-only writer:')
    for leak in leaks:
        print('        ' + leak)
else:
    ok('every call site of setOverride/clearOverride/clearAllOverrides is inside #if DEBUG')

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
producers = []
for path in swift_files():
    for i, line in enumerate(open(path, encoding='utf-8').read().splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith('//'):
            continue
        # `self.remoteDefault = remoteDefault` is the initialiser storing its own parameter.
        if re.search(r'(?<!self)remoteDefault\s*=[^=]', stripped) and 'self.remoteDefault = remoteDefault' not in stripped:
            producers.append(f'{path}:{i}: {stripped}')
if producers:
    bad('remoteDefault is assigned in production code (tier 3 must stay an unproduced seam):')
    for p in producers:
        print('        ' + p)
else:
    ok('no production assignment to remoteDefault (tier 3 stays a seam)')

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

print()
if failures:
    print(f'RESULT: FAIL — {len(failures)} dual-render gate violation(s).')
    sys.exit(1)
print('RESULT: PASS — dual-render debug affordances cannot reach a Release build.')
PY
