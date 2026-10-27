#!/usr/bin/env python3
"""Class-level freeze sweep for the eleven files this card converted, at each file's old budget + 2 s.

t_00fb623c acceptance 1/3: after conversion a class must stay green while the *test host* is
SIGSTOPped for longer than the budget its waits used to carry. The budget+2 s probe is the only
instrument that distinguishes "protected by a signal" from "protected by a clock": a longer freeze
than any old budget can no longer be absorbed by waiting.

Two passes, because four of the classes are too *short* for the default instrument:

  pass 1 (all eleven)  `-test-iterations 6`, lags 0/1/3 s. Works whenever the class is long enough
                       for xcodebuild's log flush to still be followed by a test in flight.
  pass 2 (the short four) `-test-iterations 900-3000`, so the host spends tens of seconds inside the
                       class and a stop lands inside one of its tests. Nothing is asserted from the
                       driver alone: `scripts/qa-freeze-measure.py` still requires the frozen test's
                       own reported XCTest duration to be >= the measured stop, and prints `frozen=`.

Rows are appended to build/logs/freeze-rows.txt (pass 1) and freeze-rows-short.txt (pass 2).
"""
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SIM = "81A7F251-8B31-4945-8783-5A264C14B8D5"
DERIVED = "~/Library/Developer/Xcode/DerivedData/t-00fb623c"

# class -> freeze seconds (that file's largest former wait budget + 2)
CLASSES = [
    ("T34SocketResyncTests", 12),
    ("T34SocketStallWatchdogTests", 12),
    ("T43RSocketLivenessTests", 7),
    ("T44DSocketBinarySendTests", 7),
    ("T37SocketReactionRoutingTests", 7),
    ("T32TeamSidebarTests", 7),
    ("T31AuthCoordinatorTests", 5),
    ("TokenLoggingTests", 7),
    ("T34ChannelViewRestoreWiringTests", 12),
    ("T35ComposerViewModelTests", 7),
    ("T44CCallsEngineTests", 7),
]

# class -> (freeze seconds, -test-iterations, lags)
SHORT = [
    ("T43RSocketLivenessTests", 7, 1200, "0,0.5"),
    ("T44DSocketBinarySendTests", 7, 3000, "0,0.5"),
    ("T37SocketReactionRoutingTests", 7, 900, "0,0.5"),
    ("TokenLoggingTests", 7, 1200, "0,0.5"),
]


def run(cls, freeze, iterations, lags, rows, label_prefix):
    label = f"{label_prefix}-{cls}"
    cmd = [sys.executable, str(REPO / "scripts/qa-freeze-measure.py"),
           "--sim", f"id={SIM}", "--derived-data", DERIVED,
           "--only-testing", f"MattermostTests/{cls}",
           "--iterations", str(iterations), "--lags", lags,
           "--freeze", str(freeze), "--stop-on-frozen", "--label-prefix", label]
    print(f"\n=== {cls} @ {freeze}s  iterations={iterations}", flush=True)
    proc = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
    out = proc.stdout + proc.stderr
    print(out[-1800:], flush=True)
    with rows.open("a") as fh:
        fh.write(f"\n### {cls} freeze={freeze}s iterations={iterations} rc={proc.returncode}\n")
        fh.write(out[-6000:])


def main() -> int:
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    logs = REPO / "build" / "logs"
    if which in ("all", "long"):
        for cls, freeze in CLASSES:
            run(cls, freeze, 6, "0,1.0,3.0", logs / "freeze-rows.txt", "freeze")
    if which in ("all", "short"):
        for cls, freeze, iters, lags in SHORT:
            run(cls, freeze, iters, lags, logs / "freeze-rows-short.txt", "freeze2")
    print("done")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
