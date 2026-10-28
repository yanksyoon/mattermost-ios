#!/bin/bash
# build-for-testing on the merged main tree: compiles app + MattermostTests + MattermostUITests.
set -u
cd /Users/yangsooyoon/Documents/yanks/code/mattermost-ios || exit 1
DD="$HOME/Library/Developer/Xcode/DerivedData/mmios-integrate"
LOG="build/logs/integrate/build-for-testing.log"
echo "=== build-for-testing on merged main $(git rev-parse --short HEAD) $(date -Iseconds)" > "$LOG"
xcodebuild build-for-testing \
  -project Mattermost.xcodeproj \
  -scheme Mattermost \
  -destination "platform=iOS Simulator,id=81A7F251-8B31-4945-8783-5A264C14B8D5" \
  -derivedDataPath "$DD" \
  -clonedSourcePackagesDirPath "$HOME/Library/Developer/Xcode/DerivedData/mmios-t95b/SourcePackages" \
  >> "$LOG" 2>&1
echo "XCODEBUILD_EXIT=$?" >> "$LOG"
