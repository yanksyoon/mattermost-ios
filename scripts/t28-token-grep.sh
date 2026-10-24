#!/usr/bin/env bash
# T28 evidence: "no token in any log line".
#
# Scope, stated precisely (T28-AV F6): this is the **static half**. It reads source patterns and
# committed log files; it does not execute the app. The behavioural half — every transport flow
# driven with a known credential while Logger.testSink records every line that would reach
# os_log/style capture — is `MattermostTests/TokenLoggingTests.swift`. Run both: this script for
# "no call site can interpolate a credential and no committed log carries one", the test suite for
# "the flows that do run never emit one".
#
# Checks:
#  1. no log/print call interpolates a credential-shaped variable — single-line *and*
#     multi-line-aware (a call spread over several lines is reassembled before matching);
#  2. no direct print() in the transport layer;
#  3. no hard-coded credential literal in source;
#  4. no committed log file under docs/ carries a bearer token, an MMAUTHTOKEN cookie or a JSON
#     token value (placeholders such as `Bearer <redacted>` are fine, and are what the logs hold).
#
# Exit 0 = PASS. Exit 1 = FAIL with the offending lines printed.
set -u

cd "$(dirname "$0")/.." || exit 2
SRC="Mattermost/Core/MM"
fail=0

echo "== T28 token grep (static: source patterns + committed logs) =="
echo "tree: $SRC"
echo "note: the behavioural proof is MattermostTests/TokenLoggingTests.swift"
echo

echo "-- check 1: log calls must not interpolate token/password/secret (single line) --"
hits=$(grep -nE '(Logger|MMLog)\.(debug|info|error|log)\(.*\\\(([^)]*)(token|password|secret|credential)' \
        -r "$SRC" --include='*.swift' || true)
if [ -n "$hits" ]; then
  echo "FAIL: log call interpolates a credential (single line):"
  echo "$hits"
  fail=1
else
  echo "ok: no single-line log call interpolates a credential"
fi
echo

echo "-- check 1b: the same, for calls that span several lines --"
hits=$(find "$SRC" -name '*.swift' -print0 | xargs -0 awk '
  {
    line = $0
    if (buf == "") {
      if (line !~ /(Logger|MMLog)\.(debug|info|error|log)\(/) next
      start = FNR
      buf = line
    } else {
      buf = buf " " line
    }
    opens = gsub(/\(/, "(", buf)
    closes = gsub(/\)/, ")", buf)
    if (opens > closes) next
    if (buf ~ /\\\(([^)]*)(token|password|secret|credential)/) {
      printf "%s:%d: %s\n", FILENAME, start, buf
    }
    buf = ""
  }' 2>/dev/null || true)
if [ -n "$hits" ]; then
  echo "FAIL: log call interpolates a credential (multi-line):"
  echo "$hits"
  fail=1
else
  echo "ok: no multi-line log call interpolates a credential"
fi
echo

echo "-- check 2: no direct print() in the transport layer --"
hits=$(grep -nE '(^|[^a-zA-Z_.])print\(' -r "$SRC" --include='*.swift' || true)
if [ -n "$hits" ]; then
  echo "FAIL: direct print() bypasses MMLog redaction:"
  echo "$hits"
  fail=1
else
  echo "ok: no direct print()"
fi
echo

echo "-- check 3: credential-shaped literals in source must be redaction patterns, not values --"
# A hard-coded token-ish literal (20+ chars, mixed) would be a committed secret.
hits=$(grep -nE '"(tok|Bearer )[A-Za-z0-9_-]{20,}"' -r "$SRC" --include='*.swift' || true)
if [ -n "$hits" ]; then
  echo "FAIL: possible hard-coded credential:"
  echo "$hits"
  fail=1
else
  echo "ok: no hard-coded credential literals"
fi
echo

echo "-- check 4: committed log files under docs/ must not carry a live credential --"
LOGS=$(find docs -name '*.log' -type f 2>/dev/null || true)
if [ -z "$LOGS" ]; then
  echo "ok: no log files under docs/ to scan (nothing committed to leak from)"
else
  # Bearer <token>, MMAUTHTOKEN=<cookie>, and JSON "token": "<value>". Placeholders such as
  # `Bearer <redacted>` or `"token": "<redacted>"` do not match these character classes.
  hits=$(grep -nE '(Bearer [A-Za-z0-9._~+/=-]{16,}|MMAUTHTOKEN=[A-Za-z0-9._~+/=-]{8,}|"token"[[:space:]]*:[[:space:]]*"[A-Za-z0-9._~+/=-]{8,}")' \
          $LOGS 2>/dev/null | grep -v '<redacted>' || true)
  if [ -n "$hits" ]; then
    echo "FAIL: a committed log file carries a credential-shaped value:"
    echo "$hits" | head -20
    fail=1
  else
    echo "ok: $(echo "$LOGS" | wc -l | tr -d ' ') log file(s) scanned, no credential-shaped value"
  fi
fi
echo

echo "-- evidence: the behavioural half is MattermostTests/TokenLoggingTests --"
grep -c "func test" MattermostTests/TokenLoggingTests.swift | sed 's/^/log tests: /'
echo

if [ "$fail" -eq 0 ]; then
  echo "RESULT: PASS — no static path from the native transport layer to a logged credential"
  exit 0
fi
echo "RESULT: FAIL"
exit 1
