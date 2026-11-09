#!/bin/bash
# test_verdict.sh — decide one test pass from its log, and say why in one sentence.
#
# Three passes run per leg (see docs/releasing.md, "The gate"), and every one of them
# needs the same two things from a red log: the NAME of the failing test, and a sentence
# that does not blame the wrong thing. This script is that decision, in one place, so the
# gate, the timing pass and the platform pass cannot drift apart.
#
# Why it exists (card t_6904c92b): the old inline body claimed "WebKit cannot start in
# this test host — Environment, not product" whenever the log contained a WebKit refusal
# line. Every full-suite log contains those lines (33 on the catalyst gate pass of run
# 42617348657), so a genuine assertion failure would have been filed as runner noise —
# the text equivalent of letting a red leg publish. The environment claim is now made
# only when the named test actually HUNG and WebKit was refused; an assertion is always
# named and quoted as a product failure.
#
# Usage: bash scripts/test_verdict.sh --log FILE --leg <catalyst|ios-simulator> [--pass <gate|timing|platform>]
# Exit:  0 green (log says TEST SUCCEEDED), 1 red. Prints exactly one ::error:: on red,
#        and appends a "### ..." block to $GITHUB_STEP_SUMMARY when it is set.
#
# bash 3.2 only (the macOS leg runs this under bash 3.2): no associative arrays, no ${x,,}.

set -uo pipefail

LOG=""
LEG=""
PASS="gate"

while [ $# -gt 0 ]; do
  case "$1" in
    --log) LOG=${2:-}; shift 2 ;;
    --leg) LEG=${2:-}; shift 2 ;;
    --pass) PASS=${2:-}; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$LOG" ] || [ ! -f "$LOG" ]; then
  echo "::error::test_verdict.sh: no log at '${LOG}' - cannot decide the pass"
  exit 2
fi
if [ -z "$LEG" ]; then
  echo "::error::test_verdict.sh: --leg is required"
  exit 2
fi

# The check-run annotation prefix. The gate pass keeps the historical "test (<leg>):"
# shape a reader (and scripts/test_annotation_selftest.sh) already knows; the other
# passes say which pass they are, because the same leg now runs three of them.
case "$PASS" in
  gate) PREFIX="test ($LEG)" ;;
  *)    PREFIX="test ($LEG) $PASS" ;;
esac

SUMMARY_FILE=${GITHUB_STEP_SUMMARY:-/dev/null}

summary() { # line...
  { echo ""; printf '%s\n' "$@"; } >> "$SUMMARY_FILE"
}

# --- the two facts a red log gives us ------------------------------------------------
# 1. xcodebuild's own "Failing tests:" block (present once the run has finished).
FAILING_TESTS=$(sed -n '/^Failing tests:/,/^$/p' "$LOG" | head -20 || true)
# 2. The execution-time-allowance line, which is the only place a *hung* test is named:
#    a test that times out writes no assertion and no "failed" line of its own.
TIMEOUT_LINES=$(grep -E "exceeded execution time allowance" "$LOG" | head -5 || true)

NAMED=$(printf '%s\n' "$FAILING_TESTS" \
  | sed -n 's/^[[:space:]]*\(.*\)[[:space:]]*()$/\1/p' | head -1 || true)

if [ -z "$NAMED" ]; then
  NAMED=$(printf '%s\n' "$TIMEOUT_LINES" | awk '
    match($0, /Test Case .-\[[^]]*\]/) {
      s = substr($0, RSTART, RLENGTH)
      sub(/^Test Case .-\[/, "", s); sub(/\]$/, "", s)
      n = split(s, tok, " ")
      if (n == 2) { sub(/^.*\./, "", tok[1]); print tok[1] "." tok[2]; exit }
      if (n >= 1) { print tok[1]; exit }
    }' || true)
fi

# 3. Last resort: the test's own `error:` line, which is how an assertion names itself
#    even when xcodebuild printed no "Failing tests:" block (a killed session).
if [ -z "$NAMED" ]; then
  NAMED=$(grep -E ": error: -\[[^]]*\]" "$LOG" | head -1 \
    | sed -n 's/^.*: error: -\[\([^]]*\)\].*/\1/p' || true)
fi

BARENAME=${NAMED##*.}

# --- what KIND of red is it ----------------------------------------------------------
HUNG=""
if [ -n "$BARENAME" ]; then
  if printf '%s\n' "$TIMEOUT_LINES" | grep -qF -- "$BARENAME"; then
    HUNG=$(printf '%s\n' "$TIMEOUT_LINES" \
      | grep -m1 -o -E "exceeded execution time allowance of [^.]*" || true)
  else
    # A test that waits on a signal can also report the timeout itself, without
    # xcodebuild's allowance line ("timed out after 30s waiting for the first close").
    HANG_LINE=$(grep -F -- "$BARENAME" "$LOG" \
      | grep -E "timed out after [0-9.]+s" | head -1 || true)
    if [ -n "$HANG_LINE" ]; then
      HUNG=$(printf '%s' "$HANG_LINE" | sed -n 's/^.*\(timed out after [0-9.]*s.*\)$/\1/p' || true)
      HUNG=$(printf '%s' "$HUNG" | sed 's/[[:space:]"]*$//')
    fi
  fi
fi

ASSERTION=""
if [ -n "$NAMED" ]; then
  ASSERTION=$(grep -F -- "$BARENAME" "$LOG" \
    | grep -F ": error: " \
    | grep -v -F "timed out after" \
    | head -1 \
    | sed 's/^.*: error: -\[[^]]*\] *: *//' || true)
fi

# The environment claim needs BOTH facts: the test hung, AND WebKit was refused. One
# without the other is a test failure, and saying otherwise is how a product bug gets
# filed as runner noise (the defect this script replaces).
WEBKIT_REFUSED=""
if grep -q "Could not signal service com.apple.WebKit" "$LOG" \
   || grep -q "Failed to load a display context" "$LOG"; then
  WEBKIT_REFUSED="yes"
fi

green() {
  # Print xcodebuild's own summary line rather than a hand-rolled count: a counter built
  # on a grep pattern can match its own echoed command line in the log (t_5bf7a812).
  grep -E "Executed [0-9]+ tests" "$LOG" | tail -1 || true
  grep -E "^\*\* TEST" "$LOG" | tail -1 || true
  summary "### $PASS pass ($LEG): green" \
          "- $(grep -E "Executed [0-9]+ tests" "$LOG" | tail -1 || echo 'no suite count in the log')"
  exit 0
}

if grep -qE "\*\* TEST SUCCEEDED \*\*" "$LOG"; then
  green
fi

# --- red: name it, classify it, say it -----------------------------------------------
DETAIL=""
if [ -n "$HUNG" ]; then
  DETAIL="($HUNG)"
fi

if [ -n "$NAMED" ] && [ -n "$HUNG" ] && [ -n "$WEBKIT_REFUSED" ]; then
  echo "::error::${PREFIX}: WebKit cannot start in this test host - $NAMED hung ${HUNG:+($HUNG)} while WebContent/GPU launches were refused (\"Could not signal service com.apple.WebKit.WebContent: 113\" / \"Failed to load a display context\"). Environment, not product: see docs/releasing.md, \"WebKit in the test host\"."
  summary "### $PASS pass ($LEG): RED" \
          "- first failing test: \`$NAMED\`" \
          "- **WebKit cannot start in this test host**: WebKit refused its WebContent/GPU launches and \`$NAMED\` hung rather than asserting. Environment, not product."
elif [ -n "$NAMED" ] && [ -n "$ASSERTION" ]; then
  # A product assertion, even on a log full of WebKit noise. Quote the assertion: the
  # reader should not have to open the job to learn what broke.
  echo "::error::${PREFIX}: $NAMED failed its assertions, not a hang - ${ASSERTION}"
  summary "### $PASS pass ($LEG): RED" \
          "- first failing test: \`$NAMED\`" \
          "- assertion: \`${ASSERTION}\`" \
          "- **A product failure, not the runner.** The run says so even when the log also carries WebKit refusal lines."
elif [ -n "$NAMED" ]; then
  echo "::error::${PREFIX}: $NAMED${DETAIL:+ $DETAIL}"
  summary "### $PASS pass ($LEG): RED" \
          "- first failing test: \`$NAMED\`" \
          "- the log has no assertion line and no allowance line for it; detail in the step log."
else
  if [ -n "$WEBKIT_REFUSED" ]; then
    echo "::error::${PREFIX}: WebKit cannot start in this test host and no test name is in the log - every WebContent/GPU launch was refused (\"Could not signal service com.apple.WebKit.WebContent: 113\"). Environment, not product."
    summary "### $PASS pass ($LEG): RED" \
            "- **WebKit cannot start in this test host** and xcodebuild named no test."
  else
    if [ "$PASS" = "gate" ]; then
      echo "::error::TEST SUCCEEDED not found in the $LEG log"
    else
      echo "::error::${PREFIX}: TEST SUCCEEDED not found in the $LEG log"
    fi
    summary "### $PASS pass ($LEG): RED" \
            "- xcodebuild printed no \"TEST SUCCEEDED\" and named no test: a build or destination failure, not a test result."
  fi
fi

# The detail stays in the step log, where GitHub truncates nothing.
if [ -n "$FAILING_TESTS" ]; then printf '%s\n' "$FAILING_TESTS"; fi
if [ -n "$TIMEOUT_LINES" ]; then printf '%s\n' "$TIMEOUT_LINES"; fi
grep -E "error:|failed|FAIL" "$LOG" | head -40 || true
exit 1
