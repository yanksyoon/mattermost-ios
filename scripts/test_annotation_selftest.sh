#!/bin/bash
# test_annotation_selftest.sh — prove the red test leg's check-run annotation names the test.
#
# The unit-test step decides success with `grep -qE "** TEST SUCCEEDED **"` and, when the log
# says otherwise, emits one `::error::` line that GitHub turns into the check-run annotation —
# the sentence a human reads first. That line used to be fixed text ("TEST SUCCEEDED not found
# in the catalyst log"), which is how a 5-minute test hang (run 40899137785, job 123537375304)
# came to be filed with the failing test's name only ~80 lines further down the step log
# (t_f427b00b; finding 3 of t_5bf7a812).
#
# This script replays the step body **as shipped** — extracted from
# .github/workflows/release.yml at run time, never a copy that can drift — against log fixtures
# cut down from the real logs of that run plus the green run 40906839823, and asserts the exact
# annotation text for:
#
#   1. a timeout red: xcodebuild's "Failing tests:" block *and* the execution-allowance line
#      -> the annotation names the test and says it blew the allowance
#   2. an assertion red: "Failing tests:" block, no timeout line
#      -> the annotation names the test, no invented reason
#   3. a timeout red with no "Failing tests:" block (xcodebuild never printed one)
#      -> the name is recovered from the timeout line itself
#   4. a red with no test name anywhere (a destination/build failure)
#      -> the old generic sentence, as the fallback
#   5. the green log: unchanged behaviour, exit 0, no annotation, "Executed N tests" summary
#
# Plus the negative control: the pre-fix body (the fixed generic sentence) is replayed against
# fixture 1 and must *not* name the test. If that control stops reproducing the defect, this
# script fails, because a harness that cannot show the bug proves nothing.
#
# Requirements: bash (the macOS leg runs this under bash 3.2, so no bash-4 constructs) and sed
# and grep. Nothing here touches the network, gh or a build: fixtures only.
#
# Usage: bash scripts/test_annotation_selftest.sh
#        KEEP=1 bash scripts/test_annotation_selftest.sh   # keep the fixtures and outputs
# Exit:  0 when every check holds (prints "SELF-TEST: PASS"), 1 otherwise.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/.." && pwd)
WORKFLOW="$REPO_ROOT/.github/workflows/release.yml"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-annotation-selftest.XXXXXX") || {
  echo "cannot create a temporary directory" >&2
  exit 1
}
BODY="$WORK/block.sh"
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

# --- the block, as shipped --------------------------------------------------------
# From `if ! grep -qE "** TEST SUCCEEDED **"` to the end of the step body: the failure branch
# AND the success branch that follows it (the `fi`, the "--- result summary ---" echo and the
# two summary greps), so the green replay proves the unchanged path too. The body ends at the
# first line that is not indented into the `run: |` block (blank lines stay). Dedented by the
# step's 10 spaces.
awk '
  inside == 0 && index($0, "if ! grep -qE") > 0 && index($0, "TEST SUCCEEDED") > 0 { inside = 1 }
  inside == 1 {
    if ($0 != "" && $0 !~ /^          /) { exit }
    print
  }
' "$WORKFLOW" > "$WORK/block_raw.sh"

sed 's/^          //' "$WORK/block_raw.sh" > "$BODY"

if [ ! -s "$BODY" ]; then
  say "SELF-TEST: FAIL — could not extract the failure block from $WORKFLOW"
  say "the extractor and the workflow have drifted apart; nothing was verified"
  exit 1
fi
if ! grep -q 'if ! grep -qE' "$BODY" || ! grep -q 'exit 1$' "$BODY" \
   || ! grep -q 'result summary' "$BODY" || ! grep -q 'Executed \[0-9\]+ tests' "$BODY"; then
  say "SELF-TEST: FAIL — the extracted block is not the whole tail of the unit-test step:"
  sed 's/^/  | /' "$BODY"
  exit 1
fi
if grep -q 'xcodebuild test' "$BODY" || grep -q '\-destination' "$BODY"; then
  say "SELF-TEST: FAIL — the extracted block runs xcodebuild; the extractor over-reached"
  exit 1
fi

run_case() { # name leg log [body]
  local name=$1 leg=$2 log=$3 body=${4:-$BODY}
  mkdir -p "$WORK/$name"
  # ${{ matrix.name }} is a GitHub expression; the runner substitutes the leg name before
  # bash ever sees the script, so the replay does the same.
  sed "s/\${{ matrix.name }}/$leg/g" "$body" > "$WORK/$name/body.sh"
  LOG="$log" bash -e "$WORK/$name/body.sh" > "$WORK/$name/out.log" 2>&1
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

# Real: the local replay of the pre-fix product shape (an assertion failure, no timeout).
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

# Real: the green catalyst leg of run 40906839823 (the suite's own summary line).
cat > "$WORK/green.log" <<'EOF'
Test Suite 'MattermostTests.xctest' passed at 2026-10-29 16:57:00.000.
	 Executed 1777 tests, with 9 tests skipped and 0 failures (0 unexpected) in 79.432 (83.631) seconds
	 Executed 1777 tests, with 9 tests skipped and 0 failures (0 unexpected) in 79.432 (83.639) seconds
** TEST SUCCEEDED **
EOF

say "== 1. timeout red: the annotation names the test and the allowance it blew =="
run_case red-timeout catalyst "$WORK/red-timeout.log"
expect "exits 1" rc_is red-timeout 1
expect "one annotation, naming the test and the allowance" annotation_is red-timeout \
  '::error::test (catalyst): T44CCallsEngineTests.testAConfirmedUnmuteSurvivesTheNextSnapshot (exceeded execution time allowance of 5 minutes)'
expect "detail greps still run (Failing tests block in the step log)" out_has red-timeout 'T44CCallsEngineTests.testAConfirmedUnmuteSurvivesTheNextSnapshot'

say "== 2. assertion red: names the test, invents no reason =="
run_case red-assertion ios-simulator "$WORK/red-assertion.log"
expect "exits 1" rc_is red-assertion 1
expect "one annotation, naming the test only" annotation_is red-assertion \
  '::error::test (ios-simulator): T44CCallsEngineTests.testStopFinishesWhileLibwebrtcCloseIsHeldOpen'
expect "the assertion itself stays in the step log" out_has red-assertion 'XCTAssertEqual failed'

say "== 3. timeout line only, no \"Failing tests:\" block =="
run_case red-timeout-only catalyst "$WORK/red-timeout-only.log"
expect "exits 1" rc_is red-timeout-only 1
expect "name recovered from the timeout line" annotation_is red-timeout-only \
  '::error::test (catalyst): T44CCallsEngineTests.testAConfirmedUnmuteSurvivesTheNextSnapshot (exceeded execution time allowance of 5 minutes)'

say "== 4. no test name anywhere: the old generic sentence survives as the fallback =="
run_case red-unnamed catalyst "$WORK/red-unnamed.log"
expect "exits 1" rc_is red-unnamed 1
expect "falls back to the generic annotation" annotation_is red-unnamed \
  '::error::TEST SUCCEEDED not found in the catalyst log'

say "== 5. green log: unchanged, no annotation, suite summary printed =="
run_case green catalyst "$WORK/green.log"
expect "exits 0" rc_is green 0
expect "emits no annotation" annotation_count_is green 0
expect "prints the runner's own summary" out_has green 'Executed 1777 tests, with 9 tests skipped and 0 failures'
expect "prints the verdict" out_has green '** TEST SUCCEEDED **'

say "== 6. negative control: the pre-fix body must NOT name the test =="
# The defect this card fixed: a fixed "::error::" sentence. Rebuild it and replay it against
# fixture 1. If it names the test, the checks above are green by construction.
sed 's|^\( *\)echo "::error::test .*$|\1echo "::error::TEST SUCCEEDED not found in the ${{ matrix.name }} log"|' \
  "$BODY" > "$WORK/old_body.sh"
if ! grep -q 'echo "::error::TEST SUCCEEDED not found' "$WORK/old_body.sh"; then
  say "  [FAIL] could not rebuild the pre-fix body (the naming echo moved or changed shape)"
  FAILS=$((FAILS + 1))
else
  CHECKS=$((CHECKS + 1))
  run_case negative-control catalyst "$WORK/red-timeout.log" "$WORK/old_body.sh"
  if rc_is negative-control 1 && annotation_is negative-control \
      '::error::TEST SUCCEEDED not found in the catalyst log'; then
    say "  [PASS] the pre-fix body reproduces the generic annotation (so checks 1-3 have teeth)"
  else
    say "  [FAIL] the pre-fix body no longer reproduces the defect:"
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
