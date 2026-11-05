#!/usr/bin/env python3
"""T56 perf fold — turn the RSS samples and the probe's pass stamps into one comparison block.

    python3 scripts/t56_perf_fold.py build/logs/t56-rss-legacy.csv build/logs/t56-rss-native.csv \
        [--legacy-log …] [--native-log …]

Prints, per arm: samples, median RSS, p95 RSS, peak RSS (all MB; RSS is what `ps` reports, not
`phys_footprint`), and — when the probe logs are given — the wall time of each scroll pass. The
first 20 s of samples are dropped so the launch spike is not counted as the scroll cost.
"""

from __future__ import annotations

import argparse
import os
import re
import statistics


def load(path: str, start: float | None = None, end: float | None = None) -> list[float]:
    by_pid: dict[str, list[float]] = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            parts = line.strip().split(",")
            if len(parts) != 3:
                continue
            try:
                stamp = float(parts[0])
                rss = float(parts[1]) / 1024.0  # KB -> MB
            except ValueError:
                continue
            if start is not None and stamp < start:
                continue
            if end is not None and stamp > end:
                continue
            by_pid.setdefault(parts[2], []).append(rss)
    if not by_pid:
        return []
    # A run can see more than one `Mattermost` process (a previous launch still winding down, or a
    # relaunch): keep the pid that owns the most samples, so two processes' RSS are never averaged.
    return max(by_pid.values(), key=len)


def window(path: str) -> tuple[float | None, float | None]:
    start = end = None
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if "PROBE-START" in line:
                start = float(line.split()[-1])
            elif "PROBE-END" in line:
                end = float(line.split()[-1])
    return start, end


def passes(path: str) -> list[float]:
    seconds: list[float] = []
    pattern = re.compile(r"PROBE-PASS-\d+ .*seconds=([0-9.]+)")
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            match = pattern.search(line)
            if match:
                seconds.append(float(match.group(1)))
    return seconds


def summary(path: str, log: str | None, skip: int = 40) -> None:
    if log is None:
        guess = os.path.join(os.path.dirname(path),
                             os.path.basename(path).replace("t56-rss-", "t56-perf-").replace(".csv", ".log"))
        if os.path.exists(guess):
            log = guess
    if log:
        start, end = window(log)
        rows = load(path, start, end)
        basis = "scroll window (PROBE-START..PROBE-END)"
    else:
        rows = load(path)[skip:]
        basis = f"whole run minus first {skip} samples"
    print(f"arm            {path}")
    print(f"  basis        {basis}")
    if not rows:
        print("  no samples (the app never appeared under the sampled name)")
        return
    rows.sort()
    p95 = rows[min(len(rows) - 1, int(len(rows) * 0.95))]
    print(f"  samples      {len(rows)}")
    print(f"  median RSS   {statistics.median(rows):.1f} MB")
    print(f"  p95 RSS      {p95:.1f} MB")
    print(f"  peak RSS     {rows[-1]:.1f} MB")
    if log:
        values = passes(log)
        if values:
            print(f"  passes       {', '.join(f'{value:.2f}s' for value in values)}")
            print(f"  median pass  {statistics.median(values):.2f} s")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("csvs", nargs="+")
    parser.add_argument("--legacy-log")
    parser.add_argument("--native-log")
    args = parser.parse_args()
    logs = {"legacy": args.legacy_log, "native": args.native_log}
    for path in args.csvs:
        arm = "legacy" if "legacy" in path else "native" if "native" in path else ""
        summary(path, logs.get(arm))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
