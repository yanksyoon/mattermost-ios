#!/usr/bin/env bash
# Re-shoot the README demo (T74).
#
# One take per appearance: boot the simulator, seed the throwaway workspace, start the
# simulator's own framebuffer recorder, run the capture UI test against it, stop the
# recorder, and cut the take into docs/media/demo/.
#
# Why `simctl io recordVideo` and not the Mac Catalyst app: the Catalyst window is the
# better-looking product, but recording it needs Screen Recording TCC, which this host
# denies to a non-interactive shell (`screencapture -v` -> "could not create image from
# display"). The simulator framebuffer needs no TCC, is deterministic, and records the
# real native app. See docs/media/demo/README.md for the full comparison.
#
# Requirements: the throwaway Mattermost server on 127.0.0.1:8065 (docker compose in
# scripts/perf_probe.sh), Xcode, ffmpeg/ffprobe, and the iPhone 16 Pro simulator (iOS 18.3)
# this repo's live suites already use.
#
# Usage:
#   scripts/demo_capture.sh                  # light + dark takes
#   DEMO_VARIANTS=light scripts/demo_capture.sh
#   DEMO_KEEP_FIXTURE=1 scripts/demo_capture.sh   # keep the seeded conversation
#
# Every run rewrites the conversation (scripts/demo_seed.py --keep-existing off), so the
# GIF is byte-for-byte the same story each time apart from timestamps and the reply id.
set -euo pipefail

cd "$(dirname "$0")/.."

UDID="${DEMO_SIM_UDID:-81A7F251-8B31-4945-8783-5A264C14B8D5}"
SERVER="${DEMO_SERVER:-http://127.0.0.1:8065}"
OUT_DIR="${DEMO_OUT_DIR:-docs/media/demo}"
VARIANTS="${DEMO_VARIANTS:-light dark}"
LABEL="${DEMO_LABEL:-demo-capture}"
SPEED="${DEMO_SPEED:-1.3}"
DERIVED="${DEMO_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/mattermost-ios-qa}"
FIXTURE_DIR="build/demo"
FIXTURE="$FIXTURE_DIR/fixture.json"
FIXTURE_ENV="$FIXTURE.env"
RAW="$FIXTURE_DIR/raw.mov"

say() { printf '\n[demo] %s\n' "$*"; }

say "checking the throwaway server at $SERVER"
if ! curl -sf -m 5 "$SERVER/api/v4/system/ping" >/dev/null; then
  echo "[demo] no Mattermost server on $SERVER — start it with scripts/perf_probe.sh --server-start" >&2
  exit 2
fi
for tool in xcrun ffmpeg ffprobe python3; do
  command -v "$tool" >/dev/null || { echo "[demo] missing $tool" >&2; exit 2; }
done

say "booting simulator $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
# T38: XCUITest's accessibility serialiser logs into the simulator's tracing layer, and a
# quarantined process dies on the next snapshot (SIGSEGV). Per boot, per host.
xcrun simctl spawn "$UDID" log config --subsystem com.apple.dt.xctest --mode level:off 2>/dev/null || true

mkdir -p "$FIXTURE_DIR" "$OUT_DIR"

if [ "${DEMO_KEEP_FIXTURE:-0}" = "1" ] && [ ! -f "$FIXTURE_ENV" ]; then
  echo "[demo] DEMO_KEEP_FIXTURE=1 but $FIXTURE_ENV is missing; run without it once" >&2
  exit 2
fi

for variant in $VARIANTS; do
  # Seed per take, not once per script: the take writes a reply into the fixture, and a
  # light and a dark recording of the same story must start from the same conversation.
  if [ "${DEMO_KEEP_FIXTURE:-0}" = "1" ]; then
    say "keeping the existing fixture conversation"
  else
    say "seeding the demo workspace (team demo / Northwind Studio)"
    python3 scripts/demo_seed.py --url "$SERVER" --creds-out "$FIXTURE" --env-out "$FIXTURE_ENV"
  fi
  # shellcheck disable=SC1090
  set -a; . "$FIXTURE_ENV"; set +a

  case "$variant" in
    light) slug="native-demo";      poster="poster.png" ;;
    dark)  slug="native-demo-dark"; poster="poster-dark.png" ;;
    *) echo "[demo] unknown variant '$variant' (light|dark)" >&2; exit 2 ;;
  esac

  say "appearance: $variant"
  xcrun simctl ui "$UDID" appearance "$variant"
  sleep 1

  say "recording the $variant take"
  rm -f "$RAW"
  xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$RAW" >"$FIXTURE_DIR/record-$variant.log" 2>&1 &
  RECORDER=$!
  # Give the recorder a moment to open the file before the test starts the app.
  sleep 1
  START=$(python3 -c 'import time; print(f"{time.time():.3f}")')

  # qa-test.py runs xcodebuild from the TCC-safe derived-data path and writes
  # build/logs/<label>.log; the capture test prints the DEMO-BEAT lines render.py cuts on.
  set +e
  python3 scripts/qa-test.py --platform ios --sim "id=$UDID" --derived-data "$DERIVED" \
      --only-testing MattermostUITests/TDemoCaptureUITests --label "$LABEL-$variant"
  RESULT=$?
  set -e

  # SIGINT is how simctl finalises the .mov; wait for it to finish writing.
  kill -INT "$RECORDER" 2>/dev/null || true
  wait "$RECORDER" 2>/dev/null || true

  if [ "$RESULT" -ne 0 ]; then
    echo "[demo] the $variant take failed (qa-test rc=$RESULT) — not publishing it." >&2
    echo "[demo] log: build/logs/$LABEL-$variant.log" >&2
    tail -n 30 "build/logs/$LABEL-$variant.log" >&2 || true
    exit 1
  fi

  say "cutting the $variant take"
  python3 scripts/demo_render.py \
      --mov "$RAW" \
      --log "build/logs/$LABEL-$variant.log" \
      --record-start "$START" \
      --out-dir "$OUT_DIR" \
      --slug "$slug" \
      --poster-name "$poster" \
      --speed "$SPEED"
done

# The dark take and the light take are cut from the same story; restore the simulator to
# light so a later run (or a person) does not inherit a dark device.
xcrun simctl ui "$UDID" appearance light 2>/dev/null || true

say "artefacts"
ls -lh "$OUT_DIR"/*.gif "$OUT_DIR"/*.mp4 "$OUT_DIR"/*.png 2>/dev/null || true

echo
echo "[demo] done. Assets live in $OUT_DIR; re-run this script after any UI change."
