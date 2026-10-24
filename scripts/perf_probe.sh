#!/usr/bin/env bash
# T27 — memory/performance baseline harness for the Mattermost iOS shell.
#
# Measures the claim the whole Path B programme rests on: "the web engine is too heavy". It
# launches the shell's two real builds (Mac Catalyst and the iOS Simulator) against a real
# Mattermost server, drives one fixed sequence — launch -> workspace render -> log in -> open a
# channel -> scroll N post-list steps -> open a thread — and records, per process, the kernel's
# physical footprint and a sampled RSS timeline for
#
#   * the app process,
#   * the WebKit WebContent process(es) the shell's WKWebView spawns,
#   * the WebKit GPU and Networking helpers (they cost real memory too),
#   * and their total.
#
# The scripted sequence lives inside the app (`Mattermost/Core/PerfProbe.swift`, compiled only
# with `PERF_PROBE`); this script builds, launches, samples and reports. It never invents a
# number: every figure in the emitted JSON comes from `footprint`, `ps`, or the app's own
# `os_signpost` intervals, and a stage the app could not complete is reported as failed.
#
# Usage:
#   scripts/perf_probe.sh --server-start                    # full run, fresh server, both targets
#   scripts/perf_probe.sh --skip-build --modes web          # re-run against the existing build
#   scripts/perf_probe.sh --skip-build --modes web --repeat 3   # run-to-run spread
#
# `--repeat N` runs every arm N times (the 2nd..Nth land in `<target>-<mode>-r2…`), because a
# single arm is one machine state: the report keeps every repeat so a reader can see the spread
# instead of trusting one number.
#
# Emits build/perf/<timestamp>/{runs}/*/run.json, then
#   docs/perf/baseline-<date>.json  +  docs/perf/README.md
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# ---------------------------------------------------------------- defaults / argument parsing
TARGETS="catalyst,simulator"
MODES="web,shell"
SERVER_URL="http://127.0.0.1:8065"
SERVER_START=0
SERVER_IMAGE="mattermost/mattermost-team-edition:release-9"
SERVER_CONTAINER="mm-perf"
SERVER_DB_CONTAINER="mm-perf-db"
SERVER_NETWORK="mm-perf-net"
POSTS=180
REPLIES=24
SCROLL_STEPS=12
SAMPLE_INTERVAL=0.5
STEADY_SECONDS=4
SKIP_BUILD=0
OUT_ROOT="build/perf"
WRITE_BASELINE=1
PROBE_BUDGET=300
REPEAT=1
SIM_UDID=""
SIM_BUNDLE_ID="com.mattermost.ios"
PROBE_SERVER_VERSION="9.11.19"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --targets) TARGETS="$2"; shift 2 ;;
    --modes) MODES="$2"; shift 2 ;;
    --server-url) SERVER_URL="$2"; shift 2 ;;
    --server-start) SERVER_START=1; shift ;;
    --posts) POSTS="$2"; shift 2 ;;
    --replies) REPLIES="$2"; shift 2 ;;
    --scroll-steps) SCROLL_STEPS="$2"; shift 2 ;;
    --sample-interval) SAMPLE_INTERVAL="$2"; shift 2 ;;
    --steady-seconds) STEADY_SECONDS="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --repeat) REPEAT="$2"; shift 2 ;;
    --out-root) OUT_ROOT="$2"; shift 2 ;;
    --no-baseline) WRITE_BASELINE=0; shift ;;
    --sim-udid) SIM_UDID="$2"; shift 2 ;;
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

STAMP="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
mkdir -p "$OUT_ROOT"
# Absolute from here on: the app under measurement does **not** inherit this shell's working
# directory (a Simulator app's CWD is inside the simulator, not the repo), so a relative
# `-perfProbe <dir>` would make the app write its journal somewhere nobody is watching — the
# probe then looks like it "never ran". T27 found this the hard way.
OUT_ROOT="$(cd "$OUT_ROOT" && pwd)"
RUN_ROOT="$OUT_ROOT/$STAMP"
mkdir -p "$RUN_ROOT"
RUN_ROOT="$(cd "$RUN_ROOT" && pwd)"
CREDS="$RUN_ROOT/creds.json"          # 0600, outside docs/, never committed

log() { printf '[perf %s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# ------------------------------------------------------------------------------- the server
ensure_server() {
  if curl -sf -m 3 "$SERVER_URL/api/v4/system/ping" >/dev/null 2>&1; then
    local version
    version="$(curl -sf -m 3 "$SERVER_URL/api/v4/config/client?format=old" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Version",""))' 2>/dev/null || true)"
    [[ -n "$version" ]] && PROBE_SERVER_VERSION="$version"
    log "server already up at $SERVER_URL (version ${PROBE_SERVER_VERSION:-unknown})"
    return 0
  fi
  [[ "$SERVER_START" == 1 ]] || {
    echo "no Mattermost server at $SERVER_URL and --server-start was not given." >&2
    echo "Start one with --server-start (docker, needs the Docker daemon) or point --server-url at" >&2
    echo "a throwaway server you own." >&2
    exit 65
  }
  command -v docker >/dev/null || { echo "docker missing; cannot start a server" >&2; exit 65; }

  log "starting a throwaway Mattermost server (docker, image $SERVER_IMAGE)"
  docker network create "$SERVER_NETWORK" >/dev/null 2>&1 || true
  docker rm -f -v "$SERVER_CONTAINER" >/dev/null 2>&1 || true
  docker rm -f -v "$SERVER_DB_CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$SERVER_DB_CONTAINER" --network "$SERVER_NETWORK" \
    -e POSTGRES_USER=mmuser -e POSTGRES_PASSWORD=mmuser_password -e POSTGRES_DB=mattermost \
    postgres:16-alpine >/dev/null
  for _ in $(seq 1 60); do
    docker exec "$SERVER_DB_CONTAINER" pg_isready -U mmuser >/dev/null 2>&1 && break
    sleep 1
  done
  docker run -d --name "$SERVER_CONTAINER" --platform linux/amd64 --network "$SERVER_NETWORK" \
    -p 8065:8065 \
    -e MM_SQLSETTINGS_DRIVERNAME=postgres \
    -e MM_SQLSETTINGS_DATASOURCE='postgres://mmuser:mmuser_password@mm-perf-db:5432/mattermost?sslmode=disable&connect_timeout=10' \
    -e MM_SERVICESETTINGS_SITEURL="$SERVER_URL" \
    -e MM_EMAILSETTINGS_REQUIREEMAILVERIFICATION=false \
    -e MM_TEAMSETTINGS_ENABLEOPENSERVER=true \
    "$SERVER_IMAGE" >/dev/null
  log "waiting for the server to answer /api/v4/system/ping"
  for _ in $(seq 1 180); do
    if curl -sf -m 3 "$SERVER_URL/api/v4/system/ping" >/dev/null 2>&1; then
      log "server is up"
      PROBE_SERVER_VERSION="$(curl -sf -m 5 "$SERVER_URL/api/v4/config/client?format=old" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Version",""))' 2>/dev/null || true)"
      return 0
    fi
    sleep 1
  done
  echo "server did not come up within 180s; docker logs $SERVER_CONTAINER:" >&2
  docker logs --tail 40 "$SERVER_CONTAINER" >&2 || true
  exit 66
}

seed_server() {
  log "seeding workspace: $POSTS posts + one thread with $REPLIES replies"
  python3 scripts/perf_seed.py --url "$SERVER_URL" --posts "$POSTS" --replies "$REPLIES" \
    --creds-out "$CREDS" >/dev/null
  chmod 600 "$CREDS"
  log "seeded $(jq -r '.channel_total_posts' "$CREDS") posts in #$(jq -r '.channel_name' "$CREDS")"
}

# -------------------------------------------------------------------------------- the builds
build_targets() {
  local flags="SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) PERF_PROBE"
  if [[ "$SKIP_BUILD" == 1 ]]; then
    log "skipping build (--skip-build)"
    return 0
  fi
  if [[ "$TARGETS" == *catalyst* ]]; then
    log "building Mac Catalyst (Release + PERF_PROBE)"
    xcodebuild build -project Mattermost.xcodeproj -scheme Mattermost \
      -configuration Release -destination 'platform=macOS,variant=Mac Catalyst' \
      -derivedDataPath build/perf-catalyst "$flags" >"$RUN_ROOT/build-catalyst.log" 2>&1 \
      || { echo "Catalyst build failed; see $RUN_ROOT/build-catalyst.log" >&2; exit 67; }
    grep -q '\*\* BUILD SUCCEEDED \*\*' "$RUN_ROOT/build-catalyst.log" || {
      echo "Catalyst build did not report BUILD SUCCEEDED" >&2; exit 67; }
  fi
  if [[ "$TARGETS" == *simulator* ]]; then
    local udid
    udid="$(resolve_simulator)"
    log "building iOS Simulator (Release + PERF_PROBE) for $udid"
    xcodebuild build -project Mattermost.xcodeproj -scheme Mattermost \
      -configuration Release -destination "platform=iOS Simulator,id=$udid" \
      -derivedDataPath build/perf-sim "$flags" >"$RUN_ROOT/build-simulator.log" 2>&1 \
      || { echo "Simulator build failed; see $RUN_ROOT/build-simulator.log" >&2; exit 67; }
    grep -q '\*\* BUILD SUCCEEDED \*\*' "$RUN_ROOT/build-simulator.log" || {
      echo "Simulator build did not report BUILD SUCCEEDED" >&2; exit 67; }
  fi
  log "builds OK"
}

resolve_simulator() {
  if [[ -n "$SIM_UDID" ]]; then echo "$SIM_UDID"; return; fi
  xcrun simctl list devices available -j \
    | python3 -c '
import json, sys
data = json.load(sys.stdin)["devices"]
for runtime in sorted(data, reverse=True):
    if "iOS" not in runtime:
        continue
    for d in data[runtime]:
        if d.get("isAvailable") and "iPhone" in d["name"]:
            print(d["udid"]); raise SystemExit
raise SystemExit("no available iPhone simulator")
'
}

# ------------------------------------------------------------------------------- launching
CATALYST_APP="build/perf-catalyst/Build/Products/Release-maccatalyst/Mattermost.app"
SIM_APP="build/perf-sim/Build/Products/Release-iphonesimulator/Mattermost.app"

baseline_webkit_pids() {
  ps -axo pid=,comm= \
    | grep -E 'com\.apple\.WebKit\.(WebContent|GPU|Networking)' \
    | awk '{print $1}' | paste -sd, - || true
}

run_one() {
  local target="$1" mode="$2" repeat_index="${3:-1}"
  local suffix=""
  (( repeat_index > 1 )) && suffix="-r$repeat_index"
  local dir="$RUN_ROOT/$target-$mode$suffix"
  mkdir -p "$dir"
  local login pass channel
  login="$(jq -r '.login_id' "$CREDS" 2>/dev/null || echo "")"
  pass="$(jq -r '.password' "$CREDS" 2>/dev/null || echo "")"
  channel="$(jq -r '.channel_name' "$CREDS" 2>/dev/null || echo "perf-feed")"

  local common_args=(
    -uiTestResetPersistedState
    -perfProbe "$dir"
    -perfProbeMode "$mode"
    -perfProbeChannel "$channel"
    -perfProbeScrollSteps "$SCROLL_STEPS"
    -perfProbeBudget "$PROBE_BUDGET"
  )
  if [[ "$mode" != "shell" ]]; then
    common_args+=(-perfProbeServer "$SERVER_URL")
  fi
  if [[ "$mode" == "native" ]]; then
    common_args+=(-surfaceMode "channelView=native")
  fi

  local baseline app_pid launch_cmd
  baseline="$(baseline_webkit_pids)"

  log "run $target/$mode -> $dir"
  if [[ "$target" == catalyst ]]; then
    [[ -d "$CATALYST_APP" ]] || { echo "missing $CATALYST_APP" >&2; exit 68; }
    launch_cmd="MM_PERF_LOGIN=*** MM_PERF_PASSWORD=*** $CATALYST_APP/Contents/MacOS/Mattermost ${common_args[*]}"
    env MM_PERF_LOGIN="$login" MM_PERF_PASSWORD="$pass" \
      "$CATALYST_APP/Contents/MacOS/Mattermost" "${common_args[@]}" \
      >"$dir/app-stdout.log" 2>&1 &
    app_pid=$!
  else
    local udid
    udid="$(resolve_simulator)"
    [[ -d "$SIM_APP" ]] || { echo "missing $SIM_APP" >&2; exit 68; }
    xcrun simctl boot "$udid" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
    # A stale install would keep the previous app's persisted servers; always reinstall.
    xcrun simctl terminate "$udid" "$SIM_BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl uninstall "$udid" "$SIM_BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl install "$udid" "$SIM_APP"
    launch_cmd="SIMCTL_CHILD_MM_PERF_LOGIN=*** SIMCTL_CHILD_MM_PERF_PASSWORD=*** xcrun simctl launch $udid $SIM_BUNDLE_ID ${common_args[*]}"
    local out
    out="$(SIMCTL_CHILD_MM_PERF_LOGIN="$login" SIMCTL_CHILD_MM_PERF_PASSWORD="$pass" \
      xcrun simctl launch "$udid" "$SIM_BUNDLE_ID" "${common_args[@]}")"
    app_pid="$(echo "$out" | sed -n 's/.*: *\([0-9][0-9]*\).*/\1/p' | head -1)"
    [[ -n "$app_pid" ]] || { echo "could not read the app pid from simctl launch: $out" >&2; exit 69; }
  fi
  log "app pid $app_pid; sampling every ${SAMPLE_INTERVAL}s"

  python3 scripts/perf_collect.py sample \
    --app-pid "$app_pid" --run-dir "$dir" --target "$target" --mode "$mode" \
    --repeat-index "$repeat_index" \
    --interval "$SAMPLE_INTERVAL" --duration "$PROBE_BUDGET" --steady-seconds "$STEADY_SECONDS" \
    --baseline-webkit "$baseline" --launch-command "$launch_cmd" \
    >"$dir/sampler.log" 2>&1 &
  local sampler_pid=$!

  # Preflight: the app writes its journal the instant the probe starts. If that file never shows
  # up, the seam never ran — a bad `-perfProbe` path (a Simulator app has its own CWD), a build
  # without the PERF_PROBE condition, or a crash before launch finished. Fail fast instead of
  # burning the whole budget and calling it a measurement.
  local journal="$dir/probe-journal.jsonl" waited_for_journal=0
  while [[ ! -f "$journal" ]]; do
    if (( waited_for_journal >= 25 )); then
      log "probe never started for $target/$mode: no $(basename "$journal") 25s after launch"
      kill "$app_pid" >/dev/null 2>&1 || true
      kill "$sampler_pid" >/dev/null 2>&1 || true
      return 1
    fi
    if ! kill -0 "$app_pid" 2>/dev/null; then
      log "app exited before the probe started (crash?) for $target/$mode"
      kill "$sampler_pid" >/dev/null 2>&1 || true
      return 1
    fi
    sleep 1
    waited_for_journal=$((waited_for_journal + 1))
  done

  # Wait for the app's own completion marker (bounded).
  local waited=0
  while [[ ! -f "$dir/probe.done" ]]; do
    if (( waited >= PROBE_BUDGET + 30 )); then
      log "TIMEOUT: $target/$mode did not finish within $((PROBE_BUDGET + 30))s"
      break
    fi
    sleep 1
    waited=$((waited + 1))
    if ! kill -0 "$app_pid" 2>/dev/null; then
      log "app exited before writing probe.done (crash?) — see $dir/app-stdout.log"
      break
    fi
  done

  wait "$sampler_pid" || log "sampler exited non-zero (see $dir/sampler.log)"
  cat "$dir/sampler.log" || true

  if [[ "$target" == catalyst ]]; then
    kill -TERM "$app_pid" >/dev/null 2>&1 || true
  else
    xcrun simctl terminate "$(resolve_simulator)" "$SIM_BUNDLE_ID" >/dev/null 2>&1 || true
  fi
  sleep 1

  [[ -f "$dir/probe-result.json" ]] || {
    echo "no probe-result.json for $target/$mode: the sequence did not run" >&2
    return 1
  }
  jq -r '"stages: \(.completed_stages | join(",")) | failed: \(.failed_stages | join(",")) | total \(.total_s)s"' \
    "$dir/probe-result.json"
}

# ------------------------------------------------------------------------------------ report
write_report() {
  [[ "$WRITE_BASELINE" == 1 ]] || { log "skipping docs/perf baseline (--no-baseline)"; return; }
  mkdir -p docs/perf
  log "writing docs/perf/baseline-$DATE.json and docs/perf/README.md"
  python3 scripts/perf_collect.py report \
    --runs-dir "$RUN_ROOT" \
    --out-json "docs/perf/baseline-$DATE.json" \
    --out-md docs/perf/README.md \
    --creds "$CREDS" \
    --server-url "$SERVER_URL" \
    --server-version "$PROBE_SERVER_VERSION" \
    --server-image "$SERVER_IMAGE" \
    --probe-command "scripts/perf_probe.sh --server-start --targets $TARGETS --modes $MODES --posts $POSTS --replies $REPLIES --scroll-steps $SCROLL_STEPS --repeat $REPEAT" \
    --seed-command "python3 scripts/perf_seed.py --url $SERVER_URL --posts $POSTS --replies $REPLIES --creds-out <run-dir>/creds.json"
}

# -------------------------------------------------------------------------------------- main
log "run root: $RUN_ROOT"
ensure_server
if [[ "$TARGETS" == *catalyst* || "$TARGETS" == *simulator* ]]; then
  seed_server
fi
build_targets

IFS=',' read -r -a target_list <<<"$TARGETS"
IFS=',' read -r -a mode_list <<<"$MODES"
failures=0
for target in "${target_list[@]}"; do
  for mode in "${mode_list[@]}"; do
    [[ -z "$mode" ]] && continue
    for repeat_index in $(seq 1 "$REPEAT"); do
      if ! run_one "$target" "$mode" "$repeat_index"; then
        failures=$((failures + 1))
      fi
    done
  done
done

write_report
log "done: $RUN_ROOT (failed runs: $failures)"
exit $(( failures > 0 ? 1 : 0 ))
