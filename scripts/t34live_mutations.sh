#!/usr/bin/env bash
# T34-R5b mutations, re-derived on the rebased tree (origin/main f0dc3d8 + the card's commit).
# Each mutation is applied alone, the card's test file is run, and the tree is restored with
# `git checkout --` before the next one. Never commits.
set -u
cd "$(dirname "$0")/.."

TVM=Mattermost/UI/Native/Thread/ThreadViewModel.swift
GTVM=Mattermost/UI/Native/Thread/GlobalThreadsViewModel.swift
TC=Mattermost/UI/Native/Thread/ThreadCoordinator.swift
AC=Mattermost/UI/Native/Activity/ActivityCoordinator.swift
NSV=Mattermost/Core/Native/NativeSurfaceVisibility.swift

run_one () {
  local label="$1"
  python3 scripts/qa-test.py --platform mac \
    --only-testing MattermostTests/T34LivePaneResyncTests \
    > "build/logs/t34live-rerun-${label}.log" 2>&1
  echo "EXIT=$?" >> "build/logs/t34live-rerun-${label}.log"
  echo "--- ${label}:"
  grep -E "^(tests|failed)" "build/logs/t34live-rerun-${label}.log" | head -8
}

restore () { git checkout -- "$1"; }

# --- A: the thread pane's merge is not called ---------------------------------
python3 - "$TC" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = """        for (_, model) in (models[serverID] ?? [:]).sorted(by: { $0.key < $1.key }) where model.phase == .loaded {
            _ = await model.resyncAfterGap()
            repaired += 1
        }"""
new = """        for (_, model) in (models[serverID] ?? [:]).sorted(by: { $0.key < $1.key }) where model.phase == .loaded {
            repaired += 1
        }"""
assert old in s, "A anchor missing"
p.write_text(s.replace(old, new, 1))
PY
run_one mutA
restore "$TC"

# --- B: the mentions feed's merge is not called --------------------------------
python3 - "$AC" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = "        _ = await model.resyncAfterGap()\n        resyncCount += 1"
new = "        resyncCount += 1"
assert old in s, "B anchor missing"
p.write_text(s.replace(old, new, 1))
PY
run_one mutB
restore "$AC"

# --- C: the gate assumes visibility ------------------------------------------
python3 - "$NSV" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = "        guard appIsActive(), acceptsNativeRouting() else { return false }\n"
new = "        guard appIsActive(), acceptsNativeRouting() else { return false }\n        return true\n"
assert old in s, "C anchor missing"
p.write_text(s.replace(old, new, 1))
PY
run_one mutC
restore "$NSV"

# --- D: the threads list is not swept ----------------------------------------
python3 - "$TC" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = """        for (_, list) in (globalModels[serverID] ?? [:]).sorted(by: { $0.key < $1.key }) where list.phase == .loaded {
            _ = await list.resyncAfterGap()
            repaired += 1
        }"""
new = """        for (_, list) in (globalModels[serverID] ?? [:]).sorted(by: { $0.key < $1.key }) where list.phase == .loaded {
            repaired += 1
        }"""
assert old in s, "D anchor missing"
p.write_text(s.replace(old, new, 1))
PY
run_one mutD
restore "$TC"

echo "=== tree after all mutations (must be empty):"
git status --short
