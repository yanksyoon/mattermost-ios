#!/usr/bin/env bash
# T32-R — run the sidebar-identifier UI tests (F2/F3) against deterministic local stubs.
#
# The states these tests cover *are* the fixtures, and each one is a separate stub instance:
#   8111  one team      → the F2 regression (a one-team account must keep `nativeSidebar`)
#   8114  zero teams    → the empty state, and the identifiers that actually resolve (F3)
#   8115  teams slow    → the loading state (the pane must never be blanked)
#   8116  teams 500     → the failure state
#   8117  two teams     → the rail (control: T32's behaviour did not change)
#
# Everything runs on the iOS simulator: the UI-test target's deployment target is newer than this
# host's macOS, so Catalyst cannot run UI tests (see docs/t32r-repair-note.md).
#
# Usage:
#   bash scripts/t32r-sidebar-identifiers.sh [simulator-udid]
#
# Derived data stays outside ~/Documents (T14b: a failing test whose derived data sits in the
# TCC-protected tree wedges in XCTest's in-process symbolication).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="${1:-DC3E9FB7-E4A0-4B24-8DBB-7960A059EC7A}"
DERIVED="${T32R_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/t32r-ui-ids}"
PIDS=()

cleanup() {
  for pid in "${PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT

start_stub() {
  local port="$1"; shift
  python3 "$REPO/build/uitest-server/mm_stub.py" --port "$port" "$@" >/tmp/t32r-stub-"$port".log 2>&1 &
  PIDS+=("$!")
}

start_stub 8111
start_stub 8116 --teams 0
start_stub 8118 --teams-delay 8
start_stub 8119 --teams-fail
start_stub 8117 --teams 2

for port in 8111 8116 8117 8118 8119; do
  for _ in $(seq 1 40); do
    if curl -fsS -m 1 "http://127.0.0.1:$port/api/v4/system/ping" >/dev/null 2>&1; then break; fi
    sleep 0.25
  done
done

cd "$REPO"
xcodebuild test \
  -project Mattermost.xcodeproj \
  -scheme Mattermost \
  -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath "$DERIVED" \
  -only-testing:MattermostUITests/T32SidebarIdentifiersTests
