#!/usr/bin/env bash
# Gate an install on one OS fact: does the system hold a notification-registration row for this app?
#
# Why this exists (card t_e4d5a252): the Mac build is signed ad-hoc and re-signed on every install,
# which changes the code identity and re-registers the bundle. The app cannot ask "am I registered?"
# through any public API, but the system keeps the answer in two plists. This script reads them and
# fails loudly when the bundle is in neither.
#
# Which table (measured 2026-11-05, corrected 2026-11-09 by t_54798d27):
#   * live:   ~/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/
#             group.com.apple.usernoted.plist  (written on every register)
#   * legacy: ~/Library/Preferences/com.apple.ncprefs.plist
#             (last written 2026-02-25 on this host and missing every app installed since —
#              Firefox 2026-09-17, this bundle 2026-11-05 — so it is a fallback, not the truth)
# The live table wins. A bundle found in either one counts as registered.
#
# An unreadable table is NOT an absent row. This script normally runs in a Terminal, which can read
# the live table; an app bundle launched by LaunchServices cannot (EPERM on the whole
# group.com.apple.usernoted container — t_54798d27 measured this). So when the live table exists but
# cannot be read, a missing legacy row is reported as "cannot read" (exit 2), never as "not
# registered" (exit 1): absence from the table we could read does not prove absence from the OS.
#
# Run it as the LAST step of every install; a build is not delivered until it exits 0.
#
# Usage:
#   scripts/verify-notification-registration.sh
#   scripts/verify-notification-registration.sh --bundle-id com.mattermost.ios \
#       --live-plist PATH --legacy-plist PATH
#   scripts/verify-notification-registration.sh --self-test     # proves its own verdicts
#
# Exit codes: 0 registered, 1 not registered, 2 no table readable / bad usage.
set -uo pipefail

BUNDLE_ID="com.mattermost.ios"
LIVE_PLIST="$HOME/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist"
LEGACY_PLIST="$HOME/Library/Preferences/com.apple.ncprefs.plist"

usage() {
  awk 'NR > 1 && /^set -uo/ { exit } NR > 1 { print }' "$0" | sed 's/^# \{0,1\}//'
}

# 0 = the table names the bundle, 1 = it does not, 2 = it cannot be read.
table_verdict() {
  local plist="$1" bundle="$2"
  if [ ! -r "$plist" ]; then
    return 2
  fi
  if plutil -p "$plist" 2>/dev/null | grep -Fq "\"bundle-id\" => \"$bundle\""; then
    return 0
  fi
  return 1
}

check() {
  local live="$1" legacy="$2" bundle="$3"
  local live_rc=2 legacy_rc=2

  table_verdict "$live" "$bundle"; live_rc=$?
  if [ "$live_rc" -eq 0 ]; then
    echo "OK: $bundle is registered with the system notification table (live: $live)"
    echo "note: the app itself cannot read this table on macOS 26 (a LaunchServices app gets EPERM);"
    echo "      its diagnostics will say registration=settingsRowAbsent with tables=usernoted:unreadable."
    return 0
  fi
  table_verdict "$legacy" "$bundle"; legacy_rc=$?
  if [ "$legacy_rc" -eq 0 ]; then
    echo "OK: $bundle is registered with the system notification table (legacy: $legacy)"
    return 0
  fi

  # A table that is there but unreadable is not a table that lacks the row (t_54798d27).
  if [ "$live_rc" -eq 2 ] && [ -e "$live" ]; then
    echo "FAIL: the live notification table exists but this process cannot read it ($live), and the legacy table does not name $bundle. That is not evidence the app is unregistered - run this check from a Terminal (not from inside an app sandbox)." >&2
    return 2
  fi
  if [ "$live_rc" -eq 2 ] && [ "$legacy_rc" -eq 2 ]; then
    echo "FAIL: cannot read any notification table (live: $live; legacy: $legacy) - is this a Mac?" >&2
    return 2
  fi
  echo "FAIL: $bundle has no notification-registration row in the live table ($live) or the legacy one ($legacy) - open the app > Settings > Notifications > Enable notifications > Allow (or System Settings > Notifications > Mattermost), then re-run this check." >&2
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
  local tmp live_with legacy_with legacy_only absent missing failures=0

  if ! tmp="$(mktemp -d "${TMPDIR:-/tmp}/t-e4d5a252.XXXXXX")"; then
    echo "FAIL: mktemp could not create a fixture directory" >&2
    return 1
  fi
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  live_with="$tmp/live-with.plist"
  legacy_with="$tmp/legacy-with.plist"
  legacy_only="$tmp/legacy-only.plist"
  absent="$tmp/absent.plist"
  missing="$tmp/missing.plist"
  unreadable="$tmp/unreadable.plist"
  write_fixture "$live_with" "$BUNDLE_ID"
  write_fixture "$legacy_with" "$BUNDLE_ID"
  write_fixture "$legacy_only" "$BUNDLE_ID"
  write_fixture "$absent"
  write_fixture "$unreadable"
  chmod 000 "$unreadable"

  run_case() { # expected, label, live, legacy
    local expected="$1" label="$2" live="$3" legacy="$4" got
    "$0" --live-plist "$live" --legacy-plist "$legacy" --bundle-id "$BUNDLE_ID" >/dev/null 2>&1
    got=$?
    if [ "$got" -ne "$expected" ]; then
      echo "FAIL: self-test expected $expected for $label, got $got" >&2
      failures=$((failures + 1))
    fi
  }

  run_case 0 "a live table that names the bundle" "$live_with" "$absent"
  run_case 0 "a legacy table that names the bundle" "$absent" "$legacy_only"
  run_case 0 "both tables naming the bundle" "$live_with" "$legacy_with"
  run_case 1 "both readable tables without the bundle" "$absent" "$absent"
  run_case 2 "no readable table" "$missing" "$missing"
  run_case 2 "an unreadable live table with an absent legacy one (not a registration verdict)" \
    "$unreadable" "$absent"

  if [ "$failures" -ne 0 ]; then
    return 1
  fi
  echo "OK: self-test passed (live or legacy row -> 0, absent from both readable tables -> 1," \
       "unreadable -> 2, existing-but-unreadable live table -> 2)"
  return 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --bundle-id) BUNDLE_ID="${2:-}"; shift 2 ;;
    --live-plist) LIVE_PLIST="${2:-}"; shift 2 ;;
    --legacy-plist|--plist) LEGACY_PLIST="${2:-}"; shift 2 ;;
    --self-test) self_test; exit $? ;;
    -h|--help) usage; exit 0 ;;
    *) echo "FAIL: unknown argument $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$BUNDLE_ID" ]; then
  echo "FAIL: --bundle-id must not be empty" >&2
  exit 2
fi
if [ -z "$LIVE_PLIST" ] && [ -z "$LEGACY_PLIST" ]; then
  echo "FAIL: at least one table path must be given" >&2
  exit 2
fi

check "$LIVE_PLIST" "$LEGACY_PLIST" "$BUNDLE_ID"
exit $?
