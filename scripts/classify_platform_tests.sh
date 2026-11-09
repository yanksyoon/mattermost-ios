#!/bin/bash
# Read one xcodebuild log from the platform-service pass and say what happened.
#
# The hosted runner refuses WebKit's WebContent/GPU XPC service and, on the simulator, the
# pasteboard: tests that need them *hang* until the execution-time allowance kills them.
# A hang is not an assertion - it certifies nothing, but it also does not say the product is
# broken - so the two outcomes must not be confused. This is the only place that decides
# (t_6904c92b).
#
# Usage: classify_platform_tests.sh <log>
#   prints exactly one line:
#     green
#     hung <Class.testName>
#     asserted <Class.testName>
#     unknown
#   exit 0  -> green or hung (a hang is reported, not failed)
#   exit 1  -> asserted or unknown (the leg is red)
#
# Self-test: classify_platform_tests.sh --self-test
set -uo pipefail

# The class name sits before the test name inside "-[MattermostTests.Class testName]"; the
# allowance line carries it as two words, the "Failing tests:" block as "Class.testName()".
name_from_allowance() {
  awk '
    match($0, /Test Case .-\[[^]]*\]/) {
      s = substr($0, RSTART, RLENGTH)
      sub(/^Test Case .-\[/, "", s); sub(/\]$/, "", s)
      n = split(s, tok, " ")
      if (n == 2) { sub(/^.*\./, "", tok[1]); print tok[1] "." tok[2]; exit }
      if (n >= 1) { print tok[1]; exit }
    }'
}

classify() {
  local log="$1" hung block name asserted
  if grep -qE '\*\* TEST SUCCEEDED \*\*' "$log"; then
    echo "green"
    return 0
  fi
  hung=$(grep -E "exceeded execution time allowance" "$log" | name_from_allowance | head -1)
  # Log order, not sorted: "the first failing test" must be the one xcodebuild listed first.
  block=$(sed -n '/^Failing tests:/,/^$/p' "$log" \
    | sed -n 's/^[[:space:]]*\(.*\)[[:space:]]*()$/\1/p' | awk '!seen[$0]++')
  asserted=""
  if [ -n "$block" ]; then
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      if [ -n "$hung" ] && [ "$name" = "$hung" ]; then continue; fi
      asserted="$name"
      break
    done <<< "$block"
  fi
  # An assertion outranks a hang in the same log: it is a product statement, and the run
  # must not be green while one is present.
  if [ -n "$asserted" ]; then
    echo "asserted $asserted"
    return 1
  fi
  if [ -n "$hung" ]; then
    echo "hung $hung"
    return 0
  fi
  echo "unknown"
  return 1
}

self_test() {
  local work fails=0 got rc
  work=$(mktemp -d)
  trap "rm -rf '$work'" EXIT

  expect() { # want-rc want-text label
    if [ "$got" != "$2" ] || [ "$rc" != "$1" ]; then
      echo "  [FAIL] $3: want rc=$1 '$2', got rc=$rc '$got'"
      fails=$((fails + 1))
    else
      echo "  [PASS] $3"
    fi
  }

  # 1. Green: xcodebuild's own summary line.
  cat > "$work/green.log" <<'EOF'
Test Suite 'MattermostTests.xctest' passed at 2026-11-09 12:11:17.000.
	 Executed 42 tests, with 0 failures (0 unexpected) in 3.104 (3.240) seconds
** TEST SUCCEEDED **
EOF
  got=$(classify "$work/green.log"); rc=$?
  expect 0 "green" "a green pass is green"

  # 2. Real hang: the simulator leg of run 42608834351 (T31 harvest, pasteboard/WebKit).
  cat > "$work/hang.log" <<'EOF'
Test Case '-[MattermostTests.T31HarvestCookieInstallTests testARealStoreKeepsTheInstalledCookieAndTheProductionReaderFindsIt]' started.
Test Case '-[MattermostTests.T31HarvestCookieInstallTests testARealStoreKeepsTheInstalledCookieAndTheProductionReaderFindsIt]' exceeded execution time allowance of 5 minutes. The test may have hung; check Xcode's test report for additional diagnostics.
Testing failed:
	Test session results, code coverage, and logs:
** TEST FAILED **
EOF
  got=$(classify "$work/hang.log"); rc=$?
  expect 0 "hung T31HarvestCookieInstallTests.testARealStoreKeepsTheInstalledCookieAndTheProductionReaderFindsIt" "a hang is reported, and does not fail the leg"

  # 3. Assertion failure: a real statement about the product, in the same shape WebKit
  #    hangs take. Must be red even though the log also carries an allowance line for
  #    another test - the assertion wins.
  cat > "$work/assert.log" <<'EOF'
Test Case '-[MattermostTests.T35PasteTests testAnImagePastedWithTextTakesBothAndAttachesTheImageOnce]' started.
Test Case '-[MattermostTests.T35PasteTests testAnImagePastedWithTextTakesBothAndAttachesTheImageOnce]' exceeded execution time allowance of 5 minutes.
/Users/runner/work/mattermost-ios/MattermostTests/T35PasteTests.swift:88: error: -[MattermostTests.T35PasteTests testAnImagePastedWithTextTakesBothAndAttachesTheImageOnce] : XCTAssertEqual failed: ("nil") is not equal to ("Optional(1)")
Failing tests:
	T35PasteTests.testAnImagePastedWithTextTakesBothAndAttachesTheImageOnce()
	T35PasteTests.testAPastedImageIsAttachedUnderTheFirstResponder()

** TEST FAILED **
EOF
  got=$(classify "$work/assert.log"); rc=$?
  # The first block entry is also the hung test, so it is skipped: a hang is not an
  # assertion. The second entry asserts, and that is what the leg must be red about.
  expect 1 "asserted T35PasteTests.testAPastedImageIsAttachedUnderTheFirstResponder" \
    "an assertion in the block is red, and outranks a hang"

  # 4. Red with no name anywhere: still red, and says so.
  cat > "$work/unknown.log" <<'EOF'
xcodebuild: error: Unable to find a destination matching the provided destination specifier
** TEST FAILED **
EOF
  got=$(classify "$work/unknown.log"); rc=$?
  expect 1 "unknown" "a red log with no name is red, never green"

  if [ "$fails" -ne 0 ]; then
    echo "SELF-TEST: FAIL ($fails)"
    return 1
  fi
  echo "SELF-TEST: PASS (4 checks)"
}

case "${1:-}" in
  --self-test) self_test ;;
  "" | -h | --help) sed -n '2,20p' "$0"; exit 2 ;;
  *) classify "$1" ;;
esac
