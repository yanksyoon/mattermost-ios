#!/bin/bash
# t295 — launch the installed native shell with the debug `-shellSnapshot` seam and keep the proof.
#
# Card t_295b0a32: "launch into last opened channel, or default to town hall". The seam writes
#   <path>.window.png   the window 5 s after launch (before the channel list has loaded)
#   <path>.late.png     the window after the native pane has settled (~13 s: 5 s + the 60x1 s
#                       wait for a webview that never commits on a native pane + 8 s)
#   <path>.txt          the shell diagnostics, including `sidebar=... launch=...` and `location=`
#   <path>.late.txt     the same diagnostics taken with the late image
#
# Usage:
#   scripts/t295_launch_snapshot.sh /Applications/Mattermost(ios).app /tmp/t295-snap [--clear-saved]
#
# `--clear-saved` removes `mm.native.lastChannel` first, i.e. the state a first launch is in (and the
# state the report on the card measured: `saved=-`). It touches no other default and no credential.
set -u

APP="${1:-/Applications/Mattermost(ios).app}"
SNAP="${2:-/tmp/t295-snap}"
CLEAR="${3:-}"

if [ ! -d "$APP" ]; then
  echo "no app at $APP" >&2
  exit 2
fi

if [ "$CLEAR" = "--clear-saved" ]; then
  defaults delete com.mattermost.ios mm.native.lastChannel 2>/dev/null || true
  echo "cleared mm.native.lastChannel (first-launch state)"
fi

rm -f "$SNAP" "$SNAP".txt "$SNAP".late.txt "$SNAP".window.png "$SNAP".late.png

# No launch arguments other than the snapshot path: the shell must reach its destination from its
# own policy, not from a `-surfaceMode` override or a `-uiTest*` seam.
open -na "$APP" --args -shellSnapshot "$SNAP"
sleep 2
echo "launched $APP (pid $(pgrep -f "$APP/Contents/MacOS/Mattermost" | head -1))"

# The seam writes .txt last in the native branch, then sleeps 8 s and writes .late.png/.late.txt.
for _ in $(seq 1 90); do
  if [ -f "$SNAP.txt" ] && [ -f "$SNAP.late.png" ]; then break; fi
  sleep 2
done

echo "--- files ---"
ls -l "$SNAP".txt "$SNAP".late.txt "$SNAP".window.png "$SNAP".late.png 2>&1
echo "--- diagnostics ($SNAP.txt) ---"
grep -E "^(url|debugAffordances|arguments|location|surfaces|sidebar|auth|channels)=" "$SNAP".txt 2>/dev/null
echo "--- late state ($SNAP.late.txt) ---"
grep -E "^(location|sidebar|channels)=" "$SNAP".late.txt 2>/dev/null
