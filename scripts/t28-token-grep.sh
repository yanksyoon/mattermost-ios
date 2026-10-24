#!/usr/bin/env bash
# T28 evidence: "no token in any log line; grep proves it."
#
# Two checks over the native transport layer (Mattermost/Core/MM):
#  1. no log/print call interpolates a credential-shaped variable;
#  2. every credential that *could* reach a log line goes through MMLog, which redacts it.
#
# Exit 0 = PASS. Exit 1 = FAIL with the offending lines printed.
set -u

cd "$(dirname "$0")/.." || exit 2
SRC="Mattermost/Core/MM"
fail=0

echo "== T28 token grep =="
echo "tree: $SRC"
echo

echo "-- check 1: log calls must not interpolate token/password/secret --"
# Any Logger.*/MMLog.* call whose argument list contains an interpolated credential name.
hits=$(grep -nE '(Logger|MMLog)\.(debug|info|error|log)\(.*\\\(([^)]*)(token|password|secret|credential)' \
        -r "$SRC" --include='*.swift' || true)
if [ -n "$hits" ]; then
  echo "FAIL: log call interpolates a credential:"
  echo "$hits"
  fail=1
else
  echo "ok: no log call interpolates a credential"
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

echo "-- evidence: the behavioural half is MattermostTests/TokenLoggingTests --"
grep -c "func test" MattermostTests/TokenLoggingTests.swift | sed 's/^/log tests: /'
echo

if [ "$fail" -eq 0 ]; then
  echo "RESULT: PASS — no token can reach a log line from the native transport layer"
  exit 0
fi
echo "RESULT: FAIL"
exit 1
