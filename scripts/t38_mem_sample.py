#!/usr/bin/env python3
"""T38 memory probe: sample the running app's RSS (1 Hz) and physical footprint, into CSV.

This is the T27 harness's measurement, scoped to one process: `ps -o rss` every second, and
`footprint -p <pid>` every 20 s (`phys_footprint`, the number Instruments reports). It never touches
the app — the test drives the UI, this only watches.

    python3 scripts/t38_mem_sample.py 420 > build/logs/t38-mem-$(date +%H%M%S).csv

Columns: epoch,pid,rss_kb,footprint_bytes (empty when this sample was not a footprint sample).
Fold the CSV with `scripts/t38_mem_fold.py <csv> <start_epoch> <end_epoch>`.
"""
import re
import subprocess
import sys
import time

DURATION = float(sys.argv[1]) if len(sys.argv) > 1 else 420
FOOTPRINT_EVERY = 20.0


def app_pid():
    out = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        pid, _, comm = line.partition(" ")
        if comm.strip().endswith("Mattermost.app/Mattermost"):
            return int(pid)
    return None


def rss_kb(pid):
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout
    try:
        return int(out.strip())
    except ValueError:
        return None


def footprint_bytes(pid):
    try:
        out = subprocess.run(["footprint", "-p", str(pid), "-f", "bytes"],
                             capture_output=True, text=True, timeout=60).stdout
    except Exception:
        return None
    m = re.search(r"phys_footprint:\s*(\d+)", out)
    if m:
        return int(m.group(1))
    m = re.search(r"Physical footprint:\s*([\d.]+)([KMG]?B)", out)
    if not m:
        return None
    scale = {"B": 1, "KB": 1024, "MB": 1024 ** 2, "GB": 1024 ** 3}[m.group(2)]
    return int(float(m.group(1)) * scale)


def main():
    print("epoch,pid,rss_kb,footprint_bytes", flush=True)
    start = time.time()
    next_deep = 0.0
    while time.time() - start < DURATION:
        pid = app_pid()
        now = time.time()
        if pid is None:
            print("%.1f,none,,," % now, flush=True)
        else:
            fp = ""
            if now >= next_deep:
                value = footprint_bytes(pid)
                fp = "" if value is None else str(value)
                next_deep = now + FOOTPRINT_EVERY
            print("%.1f,%d,%s,%s" % (now, pid, rss_kb(pid), fp), flush=True)
        time.sleep(1)


if __name__ == "__main__":
    main()
