#!/usr/bin/env bash
# Re-shoot the README demo (T74 / t_47958206).
#
# The delivered asset is ONE GIF with two segments: the Mac Catalyst window first (the
# product a macOS reader can install), then the existing iPhone take. This script captures
# either or both surfaces against the throwaway server and then composes the two segments.
#
#   --surface desktop   Mac Catalyst window. The app films its own window as a PNG sequence
#                       (`-demoFrameCapture`; `drawHierarchy` needs no Screen Recording TCC,
#                       which this host denies to an unattended shell) while
#                       TDemoCaptureUITests drives the story. Cut on the DEMO-BEAT lines.
#   --surface ios       iPhone framebuffer, `xcrun simctl io recordVideo` — unchanged T74 path.
#   --surface both      both, then compose. (default)
#
# Each surface writes its raw segment to build/demo/ (phone-<variant>.mp4,
# desktop-<variant>.mp4) and the compose step needs BOTH raw segments for the requested
# variants; it fails with the missing path instead of publishing a one-segment hero.
#
# Requirements: the throwaway Mattermost server on 127.0.0.1:8065, Xcode, ffmpeg with
# libx264 (`/opt/homebrew/bin/ffmpeg` on this host; `/usr/local/bin/ffmpeg` is a 2022 build
# with no libx264), the iPhone 16 Pro simulator (iOS 18.3) for the phone take, and Docker
# for the server.
#
# Usage:
#   scripts/demo_capture.sh                       # both surfaces, light + dark
#   scripts/demo_capture.sh --surface desktop     # desktop segment only, then compose
#   scripts/demo_capture.sh --surface ios         # phone segment only, then compose
#   DEMO_VARIANTS=light scripts/demo_capture.sh   # one appearance
#   DEMO_KEEP_FIXTURE=1 scripts/demo_capture.sh   # keep the seeded conversation
#
# Every run rewrites the conversation (scripts/demo_seed.py --keep-existing off), so the
# GIF is the same story each time apart from timestamps and the reply id.
set -euo pipefail

cd "$(dirname "$0")/.."

UDID="${DEMO_SIM_UDID:-81A7F251-8B31-4945-8783-5A264C14B8D5}"
SERVER="${DEMO_SERVER:-http://127.0.0.1:8065}"
OUT_DIR="${DEMO_OUT_DIR:-docs/media/demo}"
VARIANTS="${DEMO_VARIANTS:-light dark}"
LABEL="${DEMO_LABEL:-demo-capture}"
SPEED="${DEMO_SPEED:-1.3}"
DERIVED="${DEMO_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/mattermost-ios-qa}"
# The Catalyst build is separate from the simulator one: it is built and signed for this
# host, and the demo test needs the Debug-only launch seams.
DESKTOP_DERIVED="${DEMO_DESKTOP_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/mm-demo-dd}"
DESKTOP_PRODUCTS="$DESKTOP_DERIVED/Build/Products/Debug-maccatalyst"
# Source cadence of the app's own frame loop. 0.2 s ≈ 5 fps requested; the measured rate is
# ~4 fps once PNG encoding is counted — 2-4 fps is exactly what the card allows, so motion
# is checked by eye before a take is accepted (docs/media/demo/README.md).
FRAME_INTERVAL="${DEMO_FRAME_INTERVAL:-0.2}"
FRAME_SECONDS="${DEMO_FRAME_SECONDS:-180}"
# The desktop cut runs faster than real time: the card asks for the sidebar, opening a
# channel, typing and a reply in ~10 s, and the XCTest waits make that story ~29 s of
# source. 2.6x keeps every beat readable (checked by eye on the extracted frames).
DESKTOP_SPEED="${DEMO_DESKTOP_SPEED:-2.6}"
DESKTOP_START_BEAT="${DEMO_DESKTOP_START_BEAT:-sidebar}"
DESKTOP_END_BEAT="${DEMO_DESKTOP_END_BEAT:-reply}"
FIXTURE_DIR="build/demo"
FIXTURE="$FIXTURE_DIR/fixture.json"
FIXTURE_ENV="$FIXTURE_DIR/fixture.env"
RAW="$FIXTURE_DIR/raw.mov"

SURFACE="both"
while [ $# -gt 0 ]; do
  case "$1" in
    --surface) SURFACE="${2:-}"; shift 2 ;;
    --surface=*) SURFACE="${1#*=}"; shift ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "[demo] unknown argument '$1'" >&2; exit 2 ;;
  esac
done
case "$SURFACE" in
  desktop|ios|both) ;;
  *) echo "[demo] --surface must be desktop, ios or both (got '$SURFACE')" >&2; exit 2 ;;
esac

say() { printf '\n[demo] %s\n' "$*"; }

say "surface: $SURFACE, appearances: $VARIANTS"
say "checking the throwaway server at $SERVER"
if ! curl -sf -m 5 "$SERVER/api/v4/system/ping" >/dev/null; then
  echo "[demo] no Mattermost server on $SERVER — start it with scripts/perf_probe.sh --server-start" >&2
  exit 2
fi
for tool in xcrun ffmpeg ffprobe python3; do
  command -v "$tool" >/dev/null || { echo "[demo] missing $tool" >&2; exit 2; }
done
if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264; then
  # demo_render/demo_compose pick the encoder themselves; this is the early, named failure.
  if [ ! -x /opt/homebrew/bin/ffmpeg ]; then
    echo "[demo] the ffmpeg on PATH has no libx264 and /opt/homebrew/bin/ffmpeg is missing" >&2
    exit 2
  fi
fi

mkdir -p "$FIXTURE_DIR" "$OUT_DIR"

if [ "${DEMO_KEEP_FIXTURE:-0}" = "1" ] && [ ! -f "$FIXTURE_ENV" ]; then
  echo "[demo] DEMO_KEEP_FIXTURE=1 but $FIXTURE_ENV is missing; run without it once" >&2
  exit 2
fi

seed() {
  if [ "${DEMO_KEEP_FIXTURE:-0}" = "1" ]; then
    say "keeping the existing fixture conversation"
  else
    say "seeding the demo workspace (team demo / Northwind Studio)"
    python3 scripts/demo_seed.py --url "$SERVER" --creds-out "$FIXTURE" --env-out "$FIXTURE_ENV"
  fi
}

# --------------------------------------------------------------------------- the desktop take
build_desktop() {
  if [ "${DEMO_SKIP_BUILD:-0}" = "1" ]; then
    say "skipping the Catalyst build (DEMO_SKIP_BUILD=1)"
    [ -d "$DESKTOP_PRODUCTS/Mattermost.app" ] || {
      echo "[demo] no Catalyst app at $DESKTOP_PRODUCTS/Mattermost.app" >&2; exit 2; }
    [ -d "$DESKTOP_PRODUCTS/MattermostUITests-Runner.app" ] || {
      echo "[demo] no UI-test runner at $DESKTOP_PRODUCTS/MattermostUITests-Runner.app" >&2; exit 2; }
  else
    # Two host overrides, both load-bearing (measured 2026-11-09/10):
    #  - the UITest target declares a macOS 26.5 deployment target and this host is 26.3.1,
    #    so xcodebuild refuses to run it; override down to 13.0 (the app's own target).
    #  - an ad-hoc signed app/test bundle cannot be launched by an ad-hoc signed runner, so
    #    the products are built unsigned and both bundles are re-signed below.
    say "building Mac Catalyst (Debug, no signing)"
    xcodebuild build-for-testing -project Mattermost.xcodeproj -scheme Mattermost \
      -destination 'platform=macOS,variant=Mac Catalyst' \
      -derivedDataPath "$DESKTOP_DERIVED" \
      -clonedSourcePackagesDirPath "$HOME/Library/Developer/Xcode/DerivedData/mattermost-ios-qa/SourcePackages" \
      MACOSX_DEPLOYMENT_TARGET=13.0 CODE_SIGNING_ALLOWED=NO \
      >"$FIXTURE_DIR/build-catalyst.log" 2>&1 \
      || { echo "[demo] Catalyst build failed; see $FIXTURE_DIR/build-catalyst.log" >&2; exit 1; }
    grep -q 'TEST BUILD SUCCEEDED' "$FIXTURE_DIR/build-catalyst.log" \
      || { echo "[demo] the Catalyst build did not report TEST BUILD SUCCEEDED" >&2; exit 1; }
  fi
  say "ad-hoc signing the app and the UI-test runner"
  codesign --force --deep -s - "$DESKTOP_PRODUCTS/Mattermost.app"
  codesign --force --deep -s - "$DESKTOP_PRODUCTS/MattermostUITests-Runner.app"
}

capture_desktop() {
  build_desktop
  for variant in $VARIANTS; do
    seed
    # shellcheck disable=SC1090
    set -a; . "$FIXTURE_ENV"; set +a
    local frames="$FIXTURE_DIR/frames-desktop-$variant"
    local log="$FIXTURE_DIR/desktop-$variant.log"
    mkdir -p "$frames"
    say "recording the desktop $variant take (app films its own window)"
    # TEST_RUNNER_ is stripped by xcodebuild before the test process sees the variable;
    # the test forwards these to the app as -demoFrameCapture/-demoFrameScheme.
    TEST_RUNNER_MM_DEMO_FRAME_DIR="$PWD/$frames" \
    TEST_RUNNER_MM_DEMO_FRAME_SCHEME="$variant" \
    TEST_RUNNER_MM_DEMO_FRAME_INTERVAL="$FRAME_INTERVAL" \
    TEST_RUNNER_MM_DEMO_FRAME_SECONDS="$FRAME_SECONDS" \
    xcodebuild test-without-building -project Mattermost.xcodeproj -scheme Mattermost \
      -destination 'platform=macOS,variant=Mac Catalyst' \
      -derivedDataPath "$DESKTOP_DERIVED" MACOSX_DEPLOYMENT_TARGET=13.0 \
      -only-testing:MattermostUITests/TDemoCaptureUITests >"$log" 2>&1 || {
        echo "[demo] the desktop $variant take failed (rc=$?); not publishing it." >&2
        echo "[demo] log: $log" >&2
        tail -n 20 "$log" >&2 || true
        exit 1
      }
    grep -q 'TEST EXECUTE SUCCEEDED' "$log" || {
      echo "[demo] the desktop $variant run did not report TEST EXECUTE SUCCEEDED; see $log" >&2
      exit 1
    }
    say "cutting the desktop $variant take"
    python3 scripts/demo_compose.py desktop \
      --frames "$frames" --log "$log" \
      --out "$FIXTURE_DIR/desktop-$variant.mp4" \
      --poster-out "$FIXTURE_DIR/poster-$variant.png" \
      --start-beat "$DESKTOP_START_BEAT" --end-beat "$DESKTOP_END_BEAT" \
      --speed "$DESKTOP_SPEED"
  done
}

# ----------------------------------------------------------------------------- the phone take
capture_phone() {
  say "booting simulator $UDID"
  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null
  # T38: XCUITest's accessibility serialiser logs into the simulator's tracing layer, and a
  # quarantined process dies on the next snapshot (SIGSEGV). Per boot, per host.
  xcrun simctl spawn "$UDID" log config --subsystem com.apple.dt.xctest --mode level:off 2>/dev/null || true

  for variant in $VARIANTS; do
    # Seed per take: the take writes a reply into the fixture, and a light and a dark
    # recording of the same story must start from the same conversation.
    seed
    # shellcheck disable=SC1090
    set -a; . "$FIXTURE_ENV"; set +a

    say "appearance: $variant"
    xcrun simctl ui "$UDID" appearance "$variant"
    sleep 1

    say "recording the $variant phone take"
    rm -f "$RAW"
    xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$RAW" >"$FIXTURE_DIR/record-$variant.log" 2>&1 &
    local recorder=$!
    sleep 1
    local start
    start=$(python3 -c 'import time; print(f"{time.time():.3f}")')

    set +e
    python3 scripts/qa-test.py --platform ios --sim "id=$UDID" --derived-data "$DERIVED" \
        --only-testing MattermostUITests/TDemoCaptureUITests --label "$LABEL-$variant"
    local result=$?
    set -e

    # SIGINT is how simctl finalises the .mov; wait for it to finish writing.
    kill -INT "$recorder" 2>/dev/null || true
    wait "$recorder" 2>/dev/null || true

    if [ "$result" -ne 0 ]; then
      echo "[demo] the $variant phone take failed (qa-test rc=$result) — not publishing it." >&2
      echo "[demo] log: build/logs/$LABEL-$variant.log" >&2
      tail -n 30 "build/logs/$LABEL-$variant.log" >&2 || true
      exit 1
    fi

    say "cutting the $variant phone take"
    python3 scripts/demo_render.py \
        --mov "$RAW" \
        --log "build/logs/$LABEL-$variant.log" \
        --record-start "$start" \
        --out-dir "$FIXTURE_DIR" \
        --slug "phone-$variant" \
        --poster-name "" \
        --speed "$SPEED"
  done
  # The dark take and the light take are cut from the same story; restore the simulator to
  # light so a later run (or a person) does not inherit a dark device.
  xcrun simctl ui "$UDID" appearance light 2>/dev/null || true
}

# --------------------------------------------------------------------------------- compose
compose() {
  for variant in $VARIANTS; do
    local desktop="$FIXTURE_DIR/desktop-$variant.mp4"
    local phone="$FIXTURE_DIR/phone-$variant.mp4"
    local slug poster appearance
    case "$variant" in
      light) slug="native-demo";      poster="poster.png";      appearance="light" ;;
      dark)  slug="native-demo-dark"; poster="poster-dark.png"; appearance="dark" ;;
      *) echo "[demo] unknown variant '$variant' (light|dark)" >&2; exit 2 ;;
    esac
    [ -f "$desktop" ] || { echo "[demo] no desktop segment at $desktop — run --surface desktop" >&2; exit 1; }
    [ -f "$phone" ] || { echo "[demo] no phone take at $phone — run --surface ios" >&2; exit 1; }
    say "composing $slug ($appearance): desktop then phone"
    python3 scripts/demo_compose.py combine \
      --desktop "$desktop" --phone "$phone" \
      --out-dir "$OUT_DIR" --slug "$slug" --appearance "$appearance"
    cp "$FIXTURE_DIR/poster-$variant.png" "$OUT_DIR/$poster"
  done
}

# The phone take is the shipped T74 recording; when only the desktop is re-shot, use the
# take already on disk rather than silently publishing a one-segment hero.
if [ "$SURFACE" = "ios" ] || [ "$SURFACE" = "both" ]; then
  capture_phone
fi
if [ "$SURFACE" = "desktop" ] || [ "$SURFACE" = "both" ]; then
  capture_desktop
fi

compose

say "artefacts"
ls -lh "$OUT_DIR"/*.gif "$OUT_DIR"/*.mp4 "$OUT_DIR"/*.png 2>/dev/null || true

echo
echo "[demo] done. Assets live in $OUT_DIR; re-run this script after any UI change."
