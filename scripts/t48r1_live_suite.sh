#!/bin/bash
# T48-AV-R1 — run the shipped-configuration (Release, `app.launchArguments = []`) lookup-row suite on
# one simulator profile.
#
# The credentials are read out of scripts/perf_seed.py at run time and handed to the test runner
# through the `TEST_RUNNER_MM_AUTH_*` contract every live suite in this repo uses. They are never
# printed and never written to a file.
#
# usage: scripts/t48r1_live_suite.sh <device-udid> <label> [test name ...]
#   with no test names it runs the five rows this repair touches.
set -uo pipefail
cd "$(dirname "$0")/.."

DEVICE="$1"
LABEL="$2"
shift 2

if [ "$#" -eq 0 ]; then
    set -- \
        testThePostOptionsMenuOpensOnASearchResultRow \
        testThePostOptionsMenuOpensOnAMentionRow \
        testThePostOptionsMenuOpensOnASavedRowAndUnsaveLandsOnTheServer \
        testThePostOptionsMenuOpensOnAPinnedRowAndUnpinLandsOnTheServer \
        testARefusedPinFromASearchResultSheetStaysOpenWithTheReason
fi

PW=$(python3 -c 'import re;s=open("scripts/perf_seed.py").read();m=re.search(r"^PASSWORD\s*=\s*(\S+)",s,re.M);print(m.group(1).strip("\x27\";"))')
LOGIN=$(python3 -c 'import re;s=open("scripts/perf_seed.py").read();m=re.search(r"^USERNAME\s*=\s*(\S+)",s,re.M);print(m.group(1).strip("\x27\";"))')
if [ -z "$PW" ] || [ -z "$LOGIN" ]; then
    echo "could not read the fixture credentials out of scripts/perf_seed.py" >&2
    exit 2
fi

mkdir -p build/logs build/results
rm -rf "build/results/$LABEL.xcresult"

ARGS=()
for t in "$@"; do
    ARGS+=("-only-testing:MattermostUITests/T93BNativeByDefaultUITests/$t")
done

TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN="$LOGIN" \
TEST_RUNNER_MM_AUTH_PASSWORD="$PW" \
xcodebuild test-without-building \
    -project Mattermost.xcodeproj \
    -scheme MattermostReleaseSmoke \
    -configuration Release \
    -destination "platform=iOS Simulator,id=$DEVICE" \
    -derivedDataPath /Users/yangsooyoon/Library/Developer/Xcode/DerivedData/mmios-t48r1-release \
    -resultBundlePath "build/results/$LABEL.xcresult" \
    "${ARGS[@]}" > "build/logs/$LABEL.log" 2>&1
STATUS=$?
echo "EXIT=$STATUS" >> "build/logs/$LABEL.log"
exit $STATUS
