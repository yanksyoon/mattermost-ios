#!/bin/bash
# T635-A criterion 3 — verify a restored channel pane **without XCTest in the loop**.
#
# Installs a build over the simulator's existing data container and keychain (so the signed-in server and
# the saved last channel survive), relaunches it five times, and reads the pane's own measurement back
# out of the app container (`Documents/t635-scroll-geometry.log`, written only under
# `-uiTestExposeScrollGeometry`).
#
# Usage:
#   scripts/t635a-restore-verify.sh <path/to/Mattermost.app> [launches] [screenshotSeconds]
#
# Device state required (documented in docs/t635a-build-note.md):
#   * a signed-in server at $MM_SERVER (keychain), and
#   * `mm.native.lastChannel` saved for it (open the channel once in the app).
# The launch deliberately does NOT pass `-uiTestResetPersistedState`: the launch has to restore.
set -u
APP="${1:?usage: t635a-restore-verify.sh <Mattermost.app> [launches] [shotSeconds]}"
N="${2:-5}"
SHOT="${3:-12}"
UDID="${T635_UDID:-81AD82E4-B711-45B7-A539-33D9E861A7A5}"
MM_SERVER="${MM_SERVER:-http://127.0.0.1:8065}"
OUT="${T635_OUT:-$(mktemp -d)/t635a-restore}"
mkdir -p "$OUT"
echo "app:    $APP"
echo "device: $UDID"
echo "out:    $OUT"

xcrun simctl install "$UDID" "$APP" || exit 1
for i in $(seq 1 "$N"); do
  xcrun simctl terminate "$UDID" com.mattermost.ios 2>/dev/null
  sleep 1
  xcrun simctl launch "$UDID" com.mattermost.ios \
    -uiTestSeedServer "$MM_SERVER" -uiTestSeedServerName "Local Mattermost" \
    -uiTestExposeScrollGeometry \
    -surfaceMode shell=native -surfaceMode auth=native -surfaceMode sidebar=native \
    -surfaceMode composer=native -AppleLanguages "(en)" -AppleLocale en_US \
    > "$OUT/launch-$i.txt" 2>&1
  sleep "$SHOT"
  xcrun simctl io "$UDID" screenshot "$OUT/launch-$i-${SHOT}s.png" >/dev/null 2>&1
  CONTAINER=$(xcrun simctl get_app_container "$UDID" com.mattermost.ios data)
  LOG="$CONTAINER/Documents/t635-scroll-geometry.log"
  if [ ! -f "$LOG" ]; then
    echo "launch $i: NO GEOMETRY LOG (is this build carrying -uiTestExposeScrollGeometry?)"
    continue
  fi
  # The log is append-only across launches; the last session marker starts this launch's slice. The
  # summary prints the last reading of that slice — the pane's state at the end of the wait.
  SESSION=$(grep -n "^== session" "$LOG" | tail -1 | cut -d: -f1)
  SLICE=$(tail -n "+${SESSION}" "$LOG")
  printf '%s\n' "$SLICE" > "$OUT/launch-$i-geometry.log"
  echo "launch $i: $(printf '%s\n' "$SLICE" | grep -E '^t=' | tail -1)"
done
echo
echo "Screenshots and per-launch geometry slices: $OUT"
