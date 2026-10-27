#!/bin/bash
# Freeze the iOS unit-test host for N seconds while a suite is running.
#
# Why: a test that asserts against wall clock ("wait up to 3 s for X") measures the host's
# scheduler, not the code under test. Running the suite harder on an idle machine often does not
# reproduce that (t_21828c93 needed 2 suites on one simulator); stopping the host for longer than
# the budget does, every time, and it is the same failure mode a starved device produces.
#
# Usage:
#   scripts/qa-test.py --only-testing MattermostTests --label freeze-target ... &
#   scripts/qa-freeze-host.sh build/logs/freeze-target.log \
#       "testAuthPhaseChangedDropsTheCallAndRememberedFacts]' passed" 4.5
#
# The marker is a line to wait for in the xcodebuild log (the test that precedes the one you want
# frozen). The script prints STOP/CONT timestamps so the freeze window can be lined up with the log.
# Exits 1 if no host process is found within ~5 s of the marker.
set -u
LOG="${1:?usage: qa-freeze-host.sh <xcodebuild-log> <marker-line> [seconds]}"
MARKER="${2:?usage: qa-freeze-host.sh <xcodebuild-log> <marker-line> [seconds]}"
SECS="${3:-4.5}"

stamp() { date +%H:%M:%S.%N; }

echo "$(stamp) waiting for: $MARKER"
for _ in $(seq 1 6000); do
  if grep -qF "$MARKER" "$LOG" 2>/dev/null; then break; fi
  sleep 0.01
done

PID=""
for _ in $(seq 1 500); do
  PID=$(ps -axo pid=,command= | grep -F 'Mattermost.app/Mattermost' | grep -v 'Runner' \
        | awk '{print $1}' | head -1)
  [ -n "${PID:-}" ] && break
  sleep 0.01
done
if [ -z "${PID:-}" ]; then echo "$(stamp) no Mattermost test host found"; exit 1; fi

echo "$(stamp) STOP pid=$PID"
kill -STOP "$PID"
trap 'kill -CONT "$PID" 2>/dev/null' EXIT
sleep "$SECS"
kill -CONT "$PID"
trap - EXIT
echo "$(stamp) CONT pid=$PID after ${SECS}s"
