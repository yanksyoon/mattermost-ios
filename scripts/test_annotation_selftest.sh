#!/bin/bash
# test_annotation_selftest.sh — prove the red test leg's annotation names the test AND the cause.
#
# Every test pass in .github/workflows/release.yml (gate, timing, platform) decides red/green
# through scripts/test_verdict.sh, which emits the one `::error::` line GitHub turns into the
# check-run annotation — the sentence a human reads first.
#
# Two defects are pinned here, because both shipped:
#
#   1. The line used to be fixed text ("TEST SUCCEEDED not found in the catalyst log"), which
#      is how a 5-minute test hang (run 40899137785, job 123537375304) was filed with the
#      failing test's name only ~80 lines further down the step log (t_f427b00b).
#   2. It then over-corrected: whenever the log carried a WebKit refusal line it said
#      "Environment, not product". Every full-suite log carries those lines (33 of them in run
#      42617348657), so a genuine assertion would have been filed as runner noise — the text
#      equivalent of letting a red leg publish (t_6904c92b).
#
# This script runs the *shipped* decision script (no copy that can drift) against log fixtures
# cut from real runs, and asserts the exact annotation for: a timeout red, an assertion red, a
# timeout with no "Failing tests:" block, a red with no name at all, a green log, a hang with
# WebKit refused (environment), and — the new case — an assertion in a log that also carries
# WebKit refusals (must NOT blame the environment).
#
# It also keeps the negative control: a mutated copy of the shipped script with the old
# "WebKit line seen -> environment" rule must WRONGLY blame the environment for the same
# assertion fixture. If that control stops reproducing the defect, this script fails, because
# a harness that cannot show the bug proves nothing.
#
# Requirements: bash 3.2 (the macOS leg runs this under bash 3.2), sed and grep. Nothing here
# touches the network, gh or a build: fixtures only.
#
# Usage: bash scripts/test_annotation_selftest.sh
#        KEEP=1 bash scripts/test_annotation_selftest.sh   # keep the fixtures and outputs
# Exit:  0 when every check holds (prints "SELF-TEST: PASS"), 1 otherwise.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/.." && pwd)
VERDICT="$REPO_ROOT/scripts/test_verdict.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-annotation-selftest.XXXXXX") || {
  echo "cannot create a temporary directory" >&2
  exit 1
}
FAILS=0
CHECKS=0

say() { printf '%s\n' "$*"; }

cleanup() {
  if [ "${KEEP:-0}" = "1" ]; then
    say "artifacts: $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

# --- assertions -------------------------------------------------------------------
expect() { # description command...
  local desc=$1
  shift
  CHECKS=$((CHECKS + 1))
  if "$@" >/dev/null 2>&1; then
    say "  [PASS] $desc"
  else
    say "  [FAIL] $desc"
    FAILS=$((FAILS + 1))
  fi
}

expect_absent() { # description command... (passes when the command fails)
  local desc=$1
  shift
  CHECKS=$((CHECKS + 1))
  if "$@" >/dev/null 2>&1; then
    say "  [FAIL] $desc"
    FAILS=$((FAILS + 1))
  else
    say "  [PASS] $desc"
  fi
}

rc_is() { [ "$(cat "$WORK/$1/rc" 2>/dev/null)" = "$2" ]; }
annotation_is() { # case expected
  [ "$(grep -m1 '^::error::' "$WORK/$1/out.log" 2>/dev/null)" = "$2" ]
}
annotation_count_is() { # case n
  [ "$(grep -c '^::error::' "$WORK/$1/out.log" 2>/dev/null)" = "$2" ]
}
out_has() { grep -q -F -e "$2" "$WORK/$1/out.log" 2>/dev/null; }
out_lacks() { ! grep -q -F -e "$2" "$WORK/$1/out.log" 2>/dev/null; }

# --- the decision, as shipped -----------------------------------------------------
if [ ! -f "$VERDICT" ]; then
  say "SELF-TEST: FAIL — $VERDICT is missing; nothing was verified"
  exit 1
fi
# The shipped script must still make the environment claim depend on a *hang*: if that
# condition is gone, the checks below are testing something else.
if ! grep -q 'n "\$HUNG"' "$VERDICT" || ! grep -q 'n "\$WEBKIT_REFUSED"' "$VERDICT"; then
  say "SELF-TEST: FAIL — scripts/test_verdict.sh no longer classifies by hang + WebKit; the"
  say "self-test's premise (a product assertion must not be blamed on the environment) is gone."
  exit 1
fi

run_case() { # name leg pass log [script]
  local name=$1 leg=$2 pass=$3 log=$4 script=${5:-$VERDICT}
  mkdir -p "$WORK/$name"
  GITHUB_STEP_SUMMARY="$WORK/$name/summary.md" \
    bash "$script" --log "$log" --leg "$leg" --pass "$pass" \
    > "$WORK/$name/out.log" 2>&1
  echo "$?" > "$WORK/$name/rc"
}

# --- fixtures (trimmed from the real logs, prefixes/striping preserved) ------------
# Real: run 40899137785 job 123537375304, artifact test-log-catalyst.log.
cat > "$WORK/red-timeout.log" <<'EOF'
Test Case '-[MattermostTests.T44CCallsEngineTests testAConfirmedUnmuteSurvivesTheNextSnapshot]' started.
Test Case '-[MattermostTests.T44CCallsEngineTests testAConfirmedUnmuteSurvivesTheNextSnapshot]' exceeded execution time allowance of 5 minutes. The test may have hung; check Xcode's test report for additional diagnostics. If the test requires additional time, use -[XCTestCase executionTimeAllowance] or one of xcodebuild's command-line overrides.
Test Suite 'T44CCallsEngineTests' failed at 2026-10-29 15:25:24.102.
Failing tests:
	T44CCallsEngineTests.testAConfirmedUnmuteSurvivesTheNextSnapshot()

** TEST FAILED **

Testing started
EOF

# Real: a local replay of the pre-fix product shape (an assertion failure, no timeout).
cat > "$WORK/red-assertion.log" <<'EOF'
/path/MattermostTests/T44CCallsEngineTests.swift:489: error: -[MattermostTests.T44CCallsEngineTests testStopFinishesWhileLibwebrtcCloseIsHeldOpen] : XCTAssertEqual failed: ("0") is not equal to ("1") - the blocking close is handed to the teardown scheduler
Test Case '-[MattermostTests.T44CCallsEngineTests testStopFinishesWhileLibwebrtcCloseIsHeldOpen]' failed (0.862 seconds).
Failing tests:
	T44CCallsEngineTests.testStopFinishesWhileLibwebrtcCloseIsHeldOpen()

** TEST FAILED **

Testing started
EOF

cat > "$WORK/red-timeout-only.log" <<'EOF'
Test Case '-[MattermostTests.T44CCallsEngineTests testAConfirmedUnmuteSurvivesTheNextSnapshot]' exceeded execution time allowance of 5 minutes. The test may have hung; check Xcode's test report for additional diagnostics.
** TEST FAILED **
EOF

cat > "$WORK/red-unnamed.log" <<'EOF'
xcodebuild: error: Unable to find a destination matching the provided destination specifier:
		{ platform:macOS, variant:Mac Catalyst }
** TEST FAILED **
EOF

# Real: run 42608725459, job test (catalyst), 2026-11-09T11:30:44-11:35:20. WebKit's
# WebContent process cannot launch; the test that waits on a signal it never delivers hangs,
# and the log carries no product assertion at all. That is a different sentence from "a test
# failed", and it is the only case that may claim the environment (t_6904c92b).
cat > "$WORK/red-no-display.log" <<'EOF'
Test Case '-[MattermostTests.T44CCallsMediaTeardownQueueTests testOneHeldCloseDoesNotHoldUpTheNextCallsClose]' started.
2026-11-09 11:30:44.465126+0000 Mattermost[13460:41359] [DisplayConfigurationFetch] WebContent[13750] Failed to load a display context, even though we are not a headless app.
2026-11-09 11:30:44.471433+0000 Mattermost[13460:41359] WebContent[13749] Server root port lookup error - bootstrap: not privileged
2026-11-09 11:30:56.102311+0000 Mattermost[13460:41359] Could not signal service com.apple.WebKit.WebContent: 113: Could not find specified service
/Users/runner/work/mattermost-ios/mattermost-ios/MattermostTests/T44CCallsMediaTeardownQueueTests.swift:111: error: -[MattermostTests.T44CCallsMediaTeardownQueueTests testOneHeldCloseDoesNotHoldUpTheNextCallsClose] : XCTAssertTrue failed - timed out after 30s waiting for the first close to start
Test Case '-[MattermostTests.T44CCallsMediaTeardownQueueTests testOneHeldCloseDoesNotHoldUpTheNextCallsClose]' failed (150.231 seconds).
Failing tests:
	T44CCallsMediaTeardownQueueTests.testOneHeldCloseDoesNotHoldUpTheNextCallsClose()

** TEST FAILED **

Testing started
EOF

# Real: run 42617348657, job probe (catalyst / logic), 2026-11-09. An ASSERTION failure in a
# log that also carries WebKit refusals — the case the old rule mis-filed as the environment.
cat > "$WORK/red-assertion-webkit.log" <<'EOF'
Test Suite 'T49LoggerConcurrencyTests' started at 2026-11-09 12:36:59.671.
Test Case '-[MattermostTests.T49LoggerConcurrencyTests testConcurrentLoggingFromManyThreadsDoesNotCorruptTheCategoryCache]' started.
2026-11-09 12:37:00.220317+0000 Mattermost[5014:20960] Could not signal service com.apple.WebKit.WebContent: 113: Could not find specified service
2026-11-09 12:37:02.723606+0000 Mattermost[5014:20960] Could not signal service com.apple.WebKit.GPU: 113: Could not find specified service
/Users/runner/work/mattermost-ios/mattermost-ios/MattermostTests/T49TermsOfServiceTests.swift:746: error: -[MattermostTests.T49LoggerConcurrencyTests testConcurrentLoggingFromManyThreadsDoesNotCorruptTheCategoryCache] : XCTAssertEqual failed: ("timedOut") is not equal to ("success")
Test Case '-[MattermostTests.T49LoggerConcurrencyTests testConcurrentLoggingFromManyThreadsDoesNotCorruptTheCategoryCache]' failed (60.139 seconds).
Test Suite 'T49LoggerConcurrencyTests' failed at 2026-11-09 12:37:59.810.
Failing tests:
	T49LoggerConcurrencyTests.testConcurrentLoggingFromManyThreadsDoesNotCorruptTheCategoryCache()

** TEST FAILED **

Testing started
EOF

# Real: the green catalyst leg of run 40906839823 (the suite's own summary line).
cat > "$WORK/green.log" <<'EOF'
Test Suite 'MattermostTests.xctest' passed at 2026-10-29 16:57:00.000.
	 Executed 1777 tests, with 9 tests skipped and 0 failures (0 unexpected) in 79.432 (83.631) seconds
	 Executed 1777 tests, with 9 tests skipped and 0 failures (0 unexpected) in 79.432 (83.639) seconds
** TEST SUCCEEDED **
EOF

say "== 1. timeout red: the annotation names the test and the allowance it blew =="
run_case red-timeout catalyst gate "$WORK/red-timeout.log"
expect "exits 1" rc_is red-timeout 1
expect "one annotation, naming the test and the allowance" annotation_is red-timeout \
  '::error::test (catalyst): T44CCallsEngineTests.testAConfirmedUnmuteSurvivesTheNextSnapshot (exceeded execution time allowance of 5 minutes)'
expect "detail greps still run (Failing tests block in the step log)" out_has red-timeout \
  'T44CCallsEngineTests.testAConfirmedUnmuteSurvivesTheNextSnapshot'

say "== 2. assertion red: names the test and quotes the assertion =="
run_case red-assertion ios-simulator gate "$WORK/red-assertion.log"
expect "exits 1" rc_is red-assertion 1
expect "one annotation, naming the test and the assertion" annotation_is red-assertion \
  '::error::test (ios-simulator): T44CCallsEngineTests.testStopFinishesWhileLibwebrtcCloseIsHeldOpen failed its assertions, not a hang - XCTAssertEqual failed: ("0") is not equal to ("1") - the blocking close is handed to the teardown scheduler'
expect "it does not blame the environment" out_lacks red-assertion 'Environment, not product'

say "== 3. timeout line only, no \"Failing tests:\" block =="
run_case red-timeout-only catalyst gate "$WORK/red-timeout-only.log"
expect "exits 1" rc_is red-timeout-only 1
expect "name recovered from the timeout line" annotation_is red-timeout-only \
  '::error::test (catalyst): T44CCallsEngineTests.testAConfirmedUnmuteSurvivesTheNextSnapshot (exceeded execution time allowance of 5 minutes)'

say "== 4. no test name anywhere: the old generic sentence survives as the fallback =="
run_case red-unnamed catalyst gate "$WORK/red-unnamed.log"
expect "exits 1" rc_is red-unnamed 1
expect "falls back to the generic annotation" annotation_is red-unnamed \
  '::error::TEST SUCCEEDED not found in the catalyst log'

say "== 5. green log: no annotation, suite summary printed =="
run_case green catalyst gate "$WORK/green.log"
expect "exits 0" rc_is green 0
expect "emits no annotation" annotation_count_is green 0
expect "prints the runner's own summary" out_has green \
  'Executed 1777 tests, with 9 tests skipped and 0 failures'
expect "prints the verdict" out_has green '** TEST SUCCEEDED **'

say "== 6. hang with WebKit refused: the annotation names the environment, not a product bug =="
run_case red-no-display catalyst gate "$WORK/red-no-display.log"
expect "exits 1" rc_is red-no-display 1
expect "one annotation" annotation_count_is red-no-display 1
expect "it says WebKit cannot start and names the test" out_has red-no-display \
  'WebKit cannot start in this test host - T44CCallsMediaTeardownQueueTests.testOneHeldCloseDoesNotHoldUpTheNextCallsClose hung'
expect "it says environment, not product" out_has red-no-display 'Environment, not product'
expect_absent "it is not the generic sentence" annotation_is red-no-display \
  '::error::TEST SUCCEEDED not found in the catalyst log'

say "== 7. assertion in a log full of WebKit refusals: still a PRODUCT failure =="
run_case red-assertion-webkit catalyst gate "$WORK/red-assertion-webkit.log"
expect "exits 1" rc_is red-assertion-webkit 1
expect "one annotation" annotation_count_is red-assertion-webkit 1
expect "it names the test and quotes the assertion" annotation_is red-assertion-webkit \
  '::error::test (catalyst): T49LoggerConcurrencyTests.testConcurrentLoggingFromManyThreadsDoesNotCorruptTheCategoryCache failed its assertions, not a hang - XCTAssertEqual failed: ("timedOut") is not equal to ("success")'
expect "it does NOT blame the environment" out_lacks red-assertion-webkit 'Environment, not product'
expect "it does NOT say WebKit cannot start" out_lacks red-assertion-webkit 'WebKit cannot start'

say "== 8. the timing pass says which pass it was =="
run_case timing catalyst timing "$WORK/red-assertion-webkit.log"
expect "exits 1" rc_is timing 1
expect "the prefix names the pass" out_has timing \
  '::error::test (catalyst) timing: T49LoggerConcurrencyTests.testConcurrentLoggingFromManyThreadsDoesNotCorruptTheCategoryCache'

say "== 9. negative control: the pre-fix rule must mis-file case 7 as the environment =="
# Restore the old condition (WebKit line seen -> environment, no hang required) in a copy.
sed 's/if \[ -n "\$NAMED" \] && \[ -n "\$HUNG" \] && \[ -n "\$WEBKIT_REFUSED" \]/if [ -n "$NAMED" ] \&\& [ -n "$WEBKIT_REFUSED" ]/' \
  "$VERDICT" > "$WORK/old_verdict.sh"
if ! grep -q 'if \[ -n "\$NAMED" \] && \[ -n "\$WEBKIT_REFUSED" \]' "$WORK/old_verdict.sh"; then
  say "  [FAIL] could not rebuild the pre-fix rule (the condition moved or changed shape)"
  FAILS=$((FAILS + 1))
else
  CHECKS=$((CHECKS + 1))
  run_case negative-control catalyst gate "$WORK/red-assertion-webkit.log" "$WORK/old_verdict.sh"
  if [ "$(cat "$WORK/negative-control/rc" 2>/dev/null)" = "1" ] \
     && grep -q -F 'Environment, not product' "$WORK/negative-control/out.log" 2>/dev/null \
     && ! grep -q -F 'assertions, not a hang' "$WORK/negative-control/out.log" 2>/dev/null; then
    say "  [PASS] the pre-fix rule reproduces the mis-filing (so check 7 has teeth)"
  else
    say "  [FAIL] the pre-fix rule no longer reproduces the defect:"
    sed 's/^/    | /' "$WORK/negative-control/out.log"
    FAILS=$((FAILS + 1))
  fi
fi

say ""
if [ "$FAILS" -eq 0 ]; then
  say "SELF-TEST: PASS ($CHECKS checks)"
  exit 0
fi
say "SELF-TEST: FAIL ($FAILS of $CHECKS checks failed)"
exit 1
