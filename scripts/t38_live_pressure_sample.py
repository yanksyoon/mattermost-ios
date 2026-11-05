#!/usr/bin/env python3
"""Sample (1 Hz) the simulator app process, the UI-test runner, and host pressure.

Columns: epoch,app_pid,app_rss_mb,runner_pid,runner_rss_mb,load1,free_pct
Nothing but observation: ps / memory_pressure / sysctl only.
"""
import subprocess
import sys
import time

DURATION = float(sys.argv[1]) if len(sys.argv) > 1 else 420


def pids():
    out = subprocess.run(["ps", "-axo", "pid=,rss=,comm="], capture_output=True, text=True).stdout
    app = runner = None
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        pid, rss, comm = parts
        comm = comm.strip()
        if comm.endswith("Mattermost.app/Mattermost"):
            app = (int(pid), int(rss))
        elif comm.endswith("MattermostUITests-Runner.app/MattermostUITests-Runner"):
            runner = (int(pid), int(rss))
    return app, runner


def load1():
    return float(subprocess.run(["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True)
                 .stdout.split()[1])


def free_pct():
    out = subprocess.run(["memory_pressure"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "free percentage" in line:
            return int(line.rsplit(":", 1)[1].strip().rstrip("%"))
    return None


print("epoch,app_pid,app_rss_mb,runner_pid,runner_rss_mb,load1,free_pct", flush=True)
start = time.time()
while time.time() - start < DURATION:
    t = time.time()
    a, r = pids()
    print("%.1f,%s,%s,%s,%s,%.2f,%s" % (
        t,
        a[0] if a else "", round(a[1] / 1024, 1) if a else "",
        r[0] if r else "", round(r[1] / 1024, 1) if r else "",
        load1(), free_pct()), flush=True)
    time.sleep(max(0.0, 1.0 - (time.time() - t)))
