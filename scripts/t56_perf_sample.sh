#!/usr/bin/env bash
# T56 perf sampler — RSS of the app under test while `T56PerfProbeUITests` scrolls 200 posts.
#
#   scripts/t56_perf_sample.sh <csv> [seconds]
#
# Writes `epoch,rss_kb,pid` every 0.5 s. On the Simulator the app under test is a host process named
# `Mattermost`; when a previous run's process is still around the newest one is sampled. Empty rows
# mean the app was not running yet (launch/build window) — the fold ignores them.
set -uo pipefail
OUT=${1:?usage: t56_perf_sample.sh <csv> [seconds]}
DURATION=${2:-300}
: > "$OUT"
end=$((SECONDS + DURATION))
while [ "$SECONDS" -lt "$end" ]; do
  pid=$(pgrep -x Mattermost 2>/dev/null | tail -1 || true)
  if [ -n "${pid:-}" ]; then
    rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || true)
    if [ -n "${rss:-}" ]; then
      printf '%s,%s,%s\n' "$(date +%s.%N)" "$rss" "$pid" >> "$OUT"
    fi
  fi
  sleep 0.5
done
