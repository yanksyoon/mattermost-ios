#!/usr/bin/env bash
# Gate an install on one OS fact: does Notification Center hold a row for this app?
#
# Why this exists (card t_e4d5a252): the Mac build is signed ad-hoc and re-signed on every install,
# which changes the code identity. macOS then drops the bundle's notification-registration row
# while `UNUserNotificationCenter.add()` still accepts every request — so the app reports
# "scheduled" and nothing ever appears. The app cannot ask "am I registered?" through any public
# API, but the OS writes the answer in `~/Library/Preferences/com.apple.ncprefs.plist` under
# `apps[*].bundle-id`. This script reads that table and fails loudly when the row is missing.
#
# Run it as the LAST step of every install; a build is not delivered until it exits 0.
#
# Usage:
#   scripts/verify-notification-registration.sh
#   scripts/verify-notification-registration.sh --bundle-id com.mattermost.ios --plist PATH
#   scripts/verify-notification-registration.sh --self-test     # proves its own verdicts
#
# Exit codes: 0 registered, 1 not registered, 2 cannot read the table / bad usage.
set -uo pipefail

BUNDLE_ID="com.mattermost.ios"
PLIST="$HOME/Library/Preferences/com.apple.ncprefs.plist"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

check() {
  local plist="$1" bundle="$2"
  if [ ! -r "$plist" ]; then
    echo "FAIL: cannot read $plist - is this a Mac with Notification Center?" >&2
    return 2
  fi
  if plutil -p "$plist" 2>/dev/null | grep -Fq "\"bundle-id\" => \"$bundle\""; then
    echo "OK: $bundle is registered with Notification Center ($plist)"
    return 0
  fi
  echo "FAIL: $bundle has no Notification Center registration in $plist - open the app > Settings > Notifications > Enable notifications > Allow (or System Settings > Notifications > Mattermost), then re-run this check." >&2
  return 1
}

write_fixture() { # path, bundle id (or empty)
  local path="$1" bundle="${2:-}"
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0">'
    printf '%s\n' '<dict>'
    printf '%s\n' '  <key>apps</key>'
    printf '%s\n' '  <array>'
    printf '%s\n' '    <dict><key>bundle-id</key><string>Mattermost.Desktop</string></dict>'
    if [ -n "$bundle" ]; then
      printf '    <dict><key>bundle-id</key><string>%s</string></dict>\n' "$bundle"
    fi
    printf '%s\n' '  </array>'
    printf '%s\n' '</dict>'
    printf '%s\n' '</plist>'
  } > "$path"
}

self_test() {
  local tmp with without missing rc failures=0

  if ! tmp="$(mktemp -d "${TMPDIR:-/tmp}/t-e4d5a252.XXXXXX")"; then
    echo "FAIL: mktemp could not create a fixture directory" >&2
    return 1
  fi
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  with="$tmp/with.plist"
  without="$tmp/without.plist"
  missing="$tmp/missing.plist"
  write_fixture "$with" "$BUNDLE_ID"
  write_fixture "$without"

  "$0" --plist "$with" --bundle-id "$BUNDLE_ID" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: self-test expected 0 for a table that names the bundle, got $rc" >&2
    failures=$((failures + 1))
  fi

  "$0" --plist "$without" --bundle-id "$BUNDLE_ID" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 1 ]; then
    echo "FAIL: self-test expected 1 for a table without the bundle, got $rc" >&2
    failures=$((failures + 1))
  fi

  "$0" --plist "$missing" --bundle-id "$BUNDLE_ID" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 2 ]; then
    echo "FAIL: self-test expected 2 for an unreadable table, got $rc" >&2
    failures=$((failures + 1))
  fi

  if [ "$failures" -ne 0 ]; then
    return 1
  fi
  echo "OK: self-test passed (registered -> 0, absent -> 1, unreadable -> 2)"
  return 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --bundle-id) BUNDLE_ID="${2:-}"; shift 2 ;;
    --plist) PLIST="${2:-}"; shift 2 ;;
    --self-test) self_test; exit $? ;;
    -h|--help) usage; exit 0 ;;
    *) echo "FAIL: unknown argument $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$BUNDLE_ID" ]; then
  echo "FAIL: --bundle-id must not be empty" >&2
  exit 2
fi
if [ -z "$PLIST" ]; then
  echo "FAIL: --plist must not be empty" >&2
  exit 2
fi

check "$PLIST" "$BUNDLE_ID"
exit $?
