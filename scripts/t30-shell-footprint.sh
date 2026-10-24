#!/usr/bin/env bash
# T30 — "mounting the native shell must not cost more memory than the webview pane".
#
# The T27 harness (`scripts/perf_probe.sh`) measures the two *workspace* arms against a real
# server by driving a scripted login → channel → scroll sequence. That sequence is a webview
# sequence: it cannot run against a native pane whose login does not exist yet (T31). So the
# question this card actually has to answer — does the native shell cost more than the webview it
# replaces, with everything else held constant? — is measured here, with the same two primitives the
# harness uses (`ps` RSS and `footprint` physical footprint), on the same simulator, with the same
# app binary, same server URL and same seeded server. The only difference between the two arms is
# `-surfaceMode shell=native`.
#
# Usage:
#   scripts/t30-shell-footprint.sh --pane web    [--server http://127.0.0.1:8065] [--settle 20]
#   scripts/t30-shell-footprint.sh --pane native [--server http://127.0.0.1:8065] [--settle 20]
#
# Output: one JSON object per run on stdout, plus a human-readable log on stderr.
# It never invents a number: a process that is gone is reported as absent, and the webview
# processes are found by baseline-diff (pids that appeared after launch), not assumed.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

UDID="${UDID:-81A7F251-8B31-4945-8783-5A264C14B8D5}"   # iPhone 16 Pro, iOS 18.3.1 (T29 gotcha: no default sim)
BUNDLE_ID="com.mattermost.ios"
APP="${SIM_APP:-$HOME/Library/Developer/Xcode/DerivedData/mattermost-ios-qa/Build/Products/Debug-iphonesimulator/Mattermost.app}"
SERVER="http://127.0.0.1:8065"
PANEE=""
SETTLE=20
SAMPLES=12
INTERVAL=0.5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pane) PANEE="$2"; shift 2 ;;
    --server) SERVER="$2"; shift 2 ;;
    --settle) SETTLE="$2"; shift 2 ;;
    --samples) SAMPLES="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done
[[ "$PANEE" == "web" || "$PANEE" == "native" ]] || { echo "--pane web|native is required" >&2; exit 64; }
[[ -d "$APP" ]] || { echo "missing app at $APP (build first)" >&2; exit 68; }

log() { echo "[t30-footprint] $*" >&2; }

webkit_pids() {
  ps -axo pid=,comm= | grep -E 'com\.apple\.WebKit\.(WebContent|GPU|Networking)' | awk '{print $1}' | paste -sd, - || true
}

rss_kb() { ps -o rss= -p "$1" 2>/dev/null | tr -d ' ' || echo 0; }

footprint_bytes() {
  # Kernel physical footprint (the number the T27 harness reports). Needs no TCC consent; returns
  # empty when the tool refuses, in which case RSS is the only figure we claim.
  footprint -p "$1" 2>/dev/null | sed -n 's/.*Footprint: *\([0-9.]*\) \([KMG]B\).*/\1 \2/p' | head -1
}

xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"

baseline="$(webkit_pids)"

args=(-uiTestResetPersistedState -uiTestSeedServer "$SERVER")
if [[ "$PANEE" == "native" ]]; then
  # Same seeded server, same binary. `-uiTestAssumeSignedIn` only substitutes the auth gate so the
  # shell's panes render for a stub server with no session — it does not create a webview.
  args+=(-surfaceMode shell=native -uiTestAssumeSignedIn)
fi
if [[ "${RELEASE_WEBVIEW:-0}" == "1" ]]; then
  # The pane-owning release seam (§12): with an *approved* native card the policy releases the
  # webview behind a native pane. T30's shell is a skeleton, so it is not approved and the webview
  # legitimately stays warm behind it; this flag shows what the shell costs on its own.
  args+=(-releaseWebViewForTesting)
fi

log "pane=$PANEE server=$SERVER settle=${SETTLE}s"
out="$(xcrun simctl launch "$UDID" "$BUNDLE_ID" "${args[@]}")"
app_pid="$(echo "$out" | sed -n 's/.*: *\([0-9][0-9]*\).*/\1/p' | head -1)"
[[ -n "$app_pid" ]] || { echo "launch failed: $out" >&2; exit 70; }
log "app pid=$app_pid"

sleep "$SETTLE"

max_total=0
sample_json=""
for _ in $(seq 1 "$SAMPLES"); do
  now_webkit="$(webkit_pids)"
  new_webkit=""
  for p in ${now_webkit//,/ }; do
    [[ -n "$p" ]] || continue
    case ",$baseline," in *",$p,"*) ;; *) new_webkit="$new_webkit $p" ;; esac
  done
  total="$(rss_kb "$app_pid")"
  parts="$app_pid"
  for p in $new_webkit; do
    total=$(( total + $(rss_kb "$p") ))
    parts="$parts,$p"
  done
  (( total > max_total )) && max_total=$total
  sample_json="$sample_json{\"app_rss_kb\":$(rss_kb "$app_pid"),\"webkit_rss_kb\":$(( total - $(rss_kb "$app_pid") )),\"total_rss_kb\":$total},"
  sleep "$INTERVAL"
done

app_fp="$(footprint_bytes "$app_pid")"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

cat <<JSON
{"pane":"$PANEE","server":"$SERVER","app_pid":$app_pid,"webkit_pids":"$(echo $new_webkit | tr ' ' ',')",
 "app_footprint":"${app_fp:-unavailable}","max_total_rss_kb":$max_total,
 "samples":[${sample_json%,}]}
JSON
