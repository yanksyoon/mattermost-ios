#!/bin/bash
# Unit run on the merged main tree (integration card t_d11b4073).
set -u
cd /Users/yangsooyoon/Documents/yanks/code/mattermost-ios || exit 1
DD="$HOME/Library/Developer/Xcode/DerivedData/mmios-integrate"
mkdir -p "$DD/TestResults"
LOG="build/logs/integrate/units.log"
echo "=== unit run on merged main $(git rev-parse --short HEAD) $(date -Iseconds)" > "$LOG"
echo "cmd: xcodebuild test -scheme Mattermost -destination id=81A7F251-8B31-4945-8783-5A264C14B8D5 -only-testing:MattermostTests" >> "$LOG"
xcodebuild test \
  -project Mattermost.xcodeproj \
  -scheme Mattermost \
  -destination "platform=iOS Simulator,id=81A7F251-8B31-4945-8783-5A264C14B8D5" \
  -derivedDataPath "$DD" \
  -resultBundlePath "$DD/TestResults/integrate-units.xcresult" \
  -only-testing:MattermostTests \
  -clonedSourcePackagesDirPath "$HOME/Library/Developer/Xcode/DerivedData/mmios-t95b/SourcePackages" \
  >> "$LOG" 2>&1
echo "XCODEBUILD_EXIT=$?" >> "$LOG"
