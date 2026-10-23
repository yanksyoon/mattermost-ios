#!/usr/bin/env bash
# verify-release-gate.sh — App Store readiness gate for the Mattermost iOS shell (T18).
#
# Checks, mechanically, the release-gate items:
#   1. ATS is scoped: NSAllowsArbitraryLoads is ABSENT everywhere; the only relaxations are
#      NSAllowsArbitraryLoadsInWebContent (WKWebView web content only) and
#      NSAllowsLocalNetworking (local-network hosts).
#   2. Privacy manifest exists, is referenced by the app target's Resources phase, and
#      carries the declared collected-data types + required-reason APIs.
#   3. Usage descriptions (camera/mic/local network) are present and non-empty.
#   4. ITSAppUsesNonExemptEncryption=false (HTTPS-only, export exempt).
#   5. project.pbxproj lints and has no duplicate object-ID definitions.
#
# Usage: scripts/verify-release-gate.sh [path-to-built-Mattermost.app]
#   With a built .app path, also verifies PrivacyInfo.xcprivacy was copied into the bundle
#   and the compiled Info.plist carries the ATS keys.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

FAIL=0
ok()   { printf '  ok    %s\n' "$1"; }
warn() { printf '  warn  %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=1; }
note() { printf '\n== %s ==\n' "$1"; }

INFO="Mattermost/Info.plist"
PRIV="Mattermost/PrivacyInfo.xcprivacy"
PBX="Mattermost.xcodeproj/project.pbxproj"

note "1. plist sanity"
for f in "$INFO" "$PRIV" "$PBX" "Mattermost/Mattermost.entitlements"; do
  if plutil -lint "$f" >/dev/null 2>&1; then ok "plutil -lint $f"; else bad "plutil -lint $f"; fi
done

note "2. ATS scoping (assert: no global NSAllowsArbitraryLoads; scoped keys present)"
python3 - "$INFO" <<'PY'
import plistlib, sys, re
p = plistlib.load(open(sys.argv[1], 'rb'))
ats = p.get('NSAppTransportSecurity', {})
checks = [
    ('NSAllowsArbitraryLoadsInWebContent is true', ats.get('NSAllowsArbitraryLoadsInWebContent') is True),
    ('NSAllowsLocalNetworking is true', ats.get('NSAllowsLocalNetworking') is True),
    ('NSAllowsArbitraryLoads is NOT present', 'NSAllowsArbitraryLoads' not in ats),
]
for name, passed in checks:
    print(('  ok    ' if passed else '  FAIL  ') + name)
    if not passed:
        raise SystemExit(1)
PY
[ $? -eq 0 ] || FAIL=1

# Grep the source tree: the exact key NSAllowsArbitraryLoads (as a plist key) must not
# appear outside the *InWebContent* suffix, in any plist/entitlements under Mattermost/.
note "3. no global ATS kill-switch anywhere in Mattermost/"
HITS=$(grep -rn --include='*.plist' --include='*.entitlements' --include='*.xcprivacy' \
        -E '<key>NSAllowsArbitraryLoads</key>' Mattermost/ 2>/dev/null || true)
if [ -z "$HITS" ]; then ok "no <key>NSAllowsArbitraryLoads</key> in Mattermost/"; else bad "global ATS key found:"; echo "$HITS"; fi

note "4. usage descriptions + export compliance"
python3 - "$INFO" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], 'rb'))
req = {
  'NSCameraUsageDescription': 'must describe camera use by the web app (Calls)',
  'NSMicrophoneUsageDescription': 'must describe mic use by the web app (Calls)',
  'NSLocalNetworkUsageDescription': 'must describe LAN server connectivity',
}
allok = True
for k, why in req.items():
    v = p.get(k, '')
    ok = bool(v and len(v) >= 10)
    print(('  ok    ' if ok else '  FAIL  ') + f"{k} present and non-empty ({why})" if ok else f"{k} MISSING/EMPTY ({why})")
    allok = allok and ok
ok2 = p.get('ITSAppUsesNonExemptEncryption') is False
print(('  ok    ' if ok2 else '  FAIL  ') + 'ITSAppUsesNonExemptEncryption == false (HTTPS-only, export exempt)')
allok = allok and ok2
raise SystemExit(0 if allok else 1)
PY
[ $? -eq 0 ] || FAIL=1

note "5. privacy manifest content"
python3 - "$PRIV" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], 'rb'))
checks = [
    ('NSPrivacyTracking == false', p.get('NSPrivacyTracking') is False),
    ('NSPrivacyTrackingDomains empty', p.get('NSPrivacyTrackingDomains') == []),
    ('UserDefaults accessed-API declared', any(d.get('NSPrivacyAccessedAPIType') == 'NSPrivacyAccessedAPICategoryUserDefaults' for d in p.get('NSPrivacyAccessedAPITypes', []))),
    ('CA92.1 reason present', any('CA92.1' in d.get('NSPrivacyAccessedAPITypeReasons', []) for d in p.get('NSPrivacyAccessedAPITypes', []))),
]
types = {d.get('NSPrivacyCollectedDataType') for d in p.get('NSPrivacyCollectedDataTypes', [])}
for want in ['NSPrivacyCollectedDataTypeUserID', 'NSPrivacyCollectedDataTypeAudioData', 'NSPrivacyCollectedDataTypePhotosorVideos']:
    checks.append((f'{want} declared', want in types))
# T19a: Sentry/diagnostics collected data must be declared; FileTimestamp reason API must NOT
# be declared (the diagnostics report reads file CONTENTS, never timestamps — verified by grep
# in the source step below).
for want in ['NSPrivacyCollectedDataTypeCrashData', 'NSPrivacyCollectedDataTypePerformanceData', 'NSPrivacyCollectedDataTypeOtherDiagnosticData']:
    checks.append((f'{want} declared (T19a Sentry/diagnostics)', want in types))
filets = next((d for d in p.get('NSPrivacyAccessedAPITypes', []) if d.get('NSPrivacyAccessedAPIType') == 'NSPrivacyAccessedAPICategoryFileTimestamp'), None)
checks.append(('FileTimestamp reason API NOT declared (report reads contents, not dates)', filets is None))
allok = True
for name, passed in checks:
    print(('  ok    ' if passed else '  FAIL  ') + name)
    allok = allok and passed
raise SystemExit(0 if allok else 1)
PY
[ $? -eq 0 ] || FAIL=1

note "5b. no file-timestamp APIs used in source (T19a: FileTimestamp reason category)"
HITS=$(grep -rn -E 'contentModificationDate|creationDate|attributesOfItem|modificationDateKey|creationDateKey' \
        --include='*.swift' Mattermost/ 2>/dev/null || true)
if [ -z "$HITS" ]; then
  ok "no file-timestamp API calls in Mattermost/*.swift (report reads contents, not dates)"
else
  bad "file-timestamp API calls found:"; echo "$HITS"
fi

note "6. pbxproj wiring for PrivacyInfo.xcprivacy"
# file ref + build file + group member + app-target Resources phase membership
grep -q 'F20000000000000000000037 /\* PrivacyInfo.xcprivacy \*/ = {isa = PBXFileReference' "$PBX" \
  && ok "PBXFileReference defined" || bad "PBXFileReference missing"
grep -q 'F30000000000000000000022 /\* PrivacyInfo.xcprivacy in Resources \*/ = {isa = PBXBuildFile' "$PBX" \
  && ok "PBXBuildFile defined" || bad "PBXBuildFile missing"
grep -q 'F20000000000000000000037 /\* PrivacyInfo.xcprivacy \*/,' "$PBX" \
  && ok "group child present" || bad "group child missing"
RESCNT=$(awk '/\/\* Begin PBXResourcesBuildPhase section \*\//{found=1} found && /PrivacyInfo.xcprivacy in Resources/{print; exit}' "$PBX")
[ -n "$RESCNT" ] && ok "present in app target Resources phase" || bad "NOT in Resources phase"
# duplicate object-ID definitions
DUPES=$(grep -oE '^\s*[0-9A-F]{24} /\*.*\*/ = \{isa = [A-Za-z]+' "$PBX" | sed -E 's/^\s*([0-9A-F]{24}).*/\1/' | sort | uniq -d)
[ -z "$DUPES" ] && ok "no duplicate object-ID definitions" || { bad "duplicate object IDs:"; echo "$DUPES"; }

# optional: built .app bundle check
if [ $# -ge 1 ]; then
  APP="$1"
  note "7. built .app bundle ($APP)"
  if [ -d "$APP" ]; then
    [ -f "$APP/PrivacyInfo.xcprivacy" ] && ok "PrivacyInfo.xcprivacy in bundle" || bad "PrivacyInfo.xcprivacy NOT in bundle"
    if [ -f "$APP/Info.plist" ]; then
      python3 - "$APP/Info.plist" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], 'rb'))
ats = p.get('NSAppTransportSecurity', {})
print(('  ok    ' if ats.get('NSAllowsArbitraryLoadsInWebContent') is True else '  FAIL  ') + 'compiled Info.plist: NSAllowsArbitraryLoadsInWebContent == true')
print(('  ok    ' if ats.get('NSAllowsLocalNetworking') is True else '  FAIL  ') + 'compiled Info.plist: NSAllowsLocalNetworking == true')
print(('  ok    ' if 'NSAllowsArbitraryLoads' not in ats else '  FAIL  ') + 'compiled Info.plist: no global NSAllowsArbitraryLoads')
raise SystemExit(0 if ats.get('NSAllowsArbitraryLoadsInWebContent') is True and ats.get('NSAllowsLocalNetworking') is True and 'NSAllowsArbitraryLoads' not in ats else 1)
PY
      [ $? -eq 0 ] || FAIL=1
    else
      bad "no compiled Info.plist in bundle"
    fi
  else
    bad "bundle path not a directory: $APP"
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "RESULT: PASS — release gate satisfied."
  exit 0
else
  echo "RESULT: FAIL — release gate NOT satisfied."
  exit 1
fi
