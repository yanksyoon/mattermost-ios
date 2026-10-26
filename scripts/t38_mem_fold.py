#!/usr/bin/env python3
"""Fold `scripts/t38_mem_sample.py`'s CSV into the bounded-load verdict.

    python3 scripts/t38_mem_fold.py build/logs/t38-mem.csv 1793010000 1793010300 [pass_epoch ...]

Prints per-window RSS / physical-footprint summary and the growth between the first and last thirds
of the window — the same fold the card's criterion is stated in. Numbers come only from the samples;
nothing here is estimated.
"""
import sys

if len(sys.argv) < 4:
    raise SystemExit(__doc__)
path, start, end = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
passes = [float(x) for x in sys.argv[4:]]

rows = []
for line in open(path):
    parts = line.strip().split(",")
    if len(parts) < 3 or parts[1] in ("pid", "none"):
        continue
    try:
        rows.append((float(parts[0]), int(parts[1]), int(parts[2]),
                     int(parts[3]) if len(parts) > 3 and parts[3] else None))
    except ValueError:
        continue

window = [r for r in rows if start <= r[0] <= end]
print(f"csv      : {path}")
print(f"window   : {start:.0f}..{end:.0f}  ({end - start:.0f} s)")
print(f"samples  : {len(window)}")
print(f"pids     : {sorted({r[1] for r in window})}")
if not window:
    raise SystemExit("no samples in the window")

for pid in sorted({r[1] for r in window}):
    series = [r for r in window if r[1] == pid]
    rss = [r[2] / 1024 for r in series]
    fp = [r[3] / 1048576 for r in series if r[3]]
    third = max(1, len(rss) // 3)
    t1 = sum(rss[:third]) / third
    t3 = sum(rss[-third:]) / third
    print(f"\npid {pid}: n={len(series)}")
    print(f"  rss MB      : first={rss[0]:.1f} last={rss[-1]:.1f} min={min(rss):.1f} "
          f"max={max(rss):.1f} mean={sum(rss) / len(rss):.1f}")
    print(f"  rss thirds  : t1={t1:.1f} t3={t3:.1f} delta={t3 - t1:+.1f} MB over "
          f"{series[0][0]:.0f}..{series[-1][0]:.0f}")
    if fp:
        print(f"  footprint MB: first={fp[0]:.1f} last={fp[-1]:.1f} min={min(fp):.1f} "
              f"max={max(fp):.1f} n={len(fp)}")
    for i, p in enumerate(passes, 1):
        prev = start if i == 1 else passes[i - 2]
        seg = [r[2] / 1024 for r in series if prev <= r[0] <= p]
        if seg:
            print(f"  pass {i}: peak={max(seg):.1f} min={min(seg):.1f} MB (n={len(seg)})")
