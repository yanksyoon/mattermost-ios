#!/usr/bin/env bash
# T28 evidence: a native REST call succeeds after the user trusts a self-signed certificate.
#
# What this does:
#   1. generates a throwaway self-signed certificate for 127.0.0.1 (never committed: build/);
#   2. starts an HTTPS fixture serving GET /api/v4/system/ping;
#   3. runs MattermostTests/SelfSignedTrustTests on Mac Catalyst against it;
#   4. stops the fixture and reports the test runner's own verdict.
#
# The test proves the two-step user flow: the first native call fails with the typed
# `.certificateUntrusted` error while the prompt is surfaced (what CertPromptSheet presents), and
# the retry after the decision is recorded in the shared CertTrust bag succeeds.
#
# Usage: bash scripts/t28-selfsigned-check.sh [port]
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
PORT="${1:-18443}"
OUT="build/t28-selfsigned"
LOG="docs/t28-selfsigned-$(date +%Y-%m-%d).log"
mkdir -p "$OUT"

echo "== T28 self-signed check (Catalyst, 127.0.0.1:$PORT) ==" | tee "$LOG"

if [ ! -f "$OUT/cert.pem" ] || [ ! -f "$OUT/key.pem" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$OUT/key.pem" -out "$OUT/cert.pem" \
    -days 2 -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" \
    >>"$LOG" 2>&1 || { echo "FAIL: openssl could not generate the fixture certificate"; exit 1; }
fi
openssl x509 -in "$OUT/cert.pem" -outform DER -out "$OUT/cert.der" >>"$LOG" 2>&1 || exit 1

python3 scripts/t28_selfsigned_fixture.py --port "$PORT" --cert "$OUT/cert.pem" --key "$OUT/key.pem" \
  >>"$LOG" 2>&1 &
FIXTURE_PID=$!
cleanup() { kill "$FIXTURE_PID" 2>/dev/null; wait "$FIXTURE_PID" 2>/dev/null; }
trap cleanup EXIT

# Wait for the fixture to accept TLS (bounded).
ready=0
for _ in $(seq 1 40); do
  if curl -sk --max-time 2 "https://127.0.0.1:$PORT/api/v4/system/ping" | grep -q t28-selfsigned; then
    ready=1
    break
  fi
  sleep 0.25
done
if [ "$ready" -ne 1 ]; then
  echo "FAIL: HTTPS fixture did not come up on 127.0.0.1:$PORT"
  tail -20 "$LOG"
  exit 1
fi
echo "fixture is up (self-signed 127.0.0.1:$PORT)" | tee -a "$LOG"

T28_SELF_SIGNED_PORT="$PORT" \
xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build/ddata-t28-tls \
  -only-testing:MattermostTests/SelfSignedTrustTests \
  DEBUG_INFORMATION_FORMAT=dwarf 2>&1 | tee -a "$LOG"

status=${PIPESTATUS[0]}
echo | tee -a "$LOG"
# `xcodebuild` exits 0 even when a test fails, so the runner's own verdict is what counts. The
# WebSocket case (T28-AV F8) runs here too: it skips itself when the fixture is absent, so a
# "0 failures" that skipped it would be a false pass — hence the explicit "did it run" check.
if [ "$status" -eq 0 ] \
   && grep -qE "Executed [0-9]+ tests?, with 0 failures" "$LOG" \
   && grep -q "testRealWebSocketTransportOpensOnlyAfterTheCertificateIsTrusted" "$LOG" \
   && ! grep -q "testRealWebSocketTransportOpensOnlyAfterTheCertificateIsTrusted.*skipped" "$LOG" \
   && grep -q "\*\* TEST SUCCEEDED \*\*" "$LOG"; then
  echo "RESULT: PASS — native TLS succeeds after the certificate decision is recorded in CertTrust" | tee -a "$LOG"
  exit 0
fi
echo "RESULT: FAIL (xcodebuild exit $status)" | tee -a "$LOG"
exit 1
