# T44d flake — `testCallEndedEndsTheSurfaceAndReleasesTheCoordinator` (kanban t_21828c93)

Written 2026-10-27 on `origin/main 6119179` (the tree the red was measured on). Evidence: every
excerpt quoted here is also collected, with line numbers, in
`docs/t44d-flake-evidence-2026-10-27.log`; the two acceptance runs are committed whole as
`docs/t44d-flake-full-units-1-2026-10-27.log` and `…-2-…log`.

## 1. The symptom, and what it is not

The card reports the test red in every whole-suite run and green alone, with `timed out waiting
for ended` after 3 s. Reproduced here, but **not** by running the suite harder on an idle tree:

| run | conditions | result |
|---|---|---|
| `t44d-flake-repro` | pristine `6119179`, whole `MattermostTests`, idle host, fresh derived data | 1626 run, 6 skipped, **0 failed**; the test passed in 0.012 s |
| `t44d-flake-repro-load` | same tree, host at ~2.4× CPU oversubscription (14 spinners on 10 cores) | 1626 run, 6 skipped, **0 failed**; 0.012 s |
| `t44d-samedev-b` | **two whole-suite runs at once against the same simulator** | 876 run, **1 failed** — this test, 3.688 s, `timed out waiting for ended` |
| `t44d-samedev-a` | the other half of that pair | host aborted mid-run (18 run); its failing-test list names the same test, plus `SocketClientTests.testPongClearsTheMissedPongCount` |
| `t44d-freeze2` | pristine tree, test host `SIGSTOP`ed for 4.5 s at 13:49:30.196 → 13:49:34.769 | **1 failed**: `testDeniedMicrophoneStillJoinsAndExplainsItself`, `timed out waiting for connected without a mic`, 5.075 s |
| `t44d-freeze4` | the fixed tree, same 4.5 s freeze (`scripts/qa-freeze-host.sh`): it landed on a test that still polls | the three converted tests pass (0.002 / 0.006 / 0.013 s); `testDeniedMicrophoneStillJoinsAndExplainsItself` still reds (5.125 s) — the remaining exposure is tracked as t_19ab2cbc |

Two conclusions from that table:

* The budget is a host measure, not a code measure: freezing the process for 4.5 s reds an
  *unrelated* 3 s poll in the same class, and the one whole-suite red that reproduced came with a
  second suite sharing the simulator (which is exactly the condition the dispatcher created earlier
  by putting two workers in one tree — see the steward comments on this card).
* Something worse than latency is also in play: the red does not only happen when the frame is
  late, it happens when the frame is **folded and then undone**. See §2.

## 2. Root cause: a terminal phase could be re-opened

While converting the test to a completion signal, the new wire test failed *after its signal had
fired*:

```
T44DCallsCoordinatorTests.swift:407: error: testCallEndFromTheSocketReachesTheModelAndReleasesTheCoordinator
  : XCTAssertEqual failed: ("joining") is not equal to ("ended")
```

`CallsCallModel.phase` has two independent inputs: the engine snapshot (polled every 0.4 s by
`enginePump`) and the socket frames (folded by `eventPump`). `foldPhase` replaced the phase with
whatever came last, so a snapshot that was **already in flight** when `call_end` folded landed one
main-actor turn later and set `phase` back to `.joining`. In the old test that is fatal in a
specific way: its first poll iteration runs *after* both queued main-actor jobs, so it never
observes `.ended` at all and burns the whole 3 s — the reported message, `timed out waiting for
ended`, is the timeout and never a wrong state.

Deterministic proof, no load and no clock — `MUTATION M3` (the new rule removed):

```
testASnapshotTakenBeforeTheEndCannotReopenTheCall : XCTAssertEqual failed: ("joining") is not equal to ("ended")
testATerminalPhaseIsFinal                        : 5 assertions red
testCallEndFromTheSocketReachesTheModelAndReleasesTheCoordinator : ("joining") is not equal to ("ended"), 0.031 s
```

Healthy-path timing for reference (instrumented whole-suite run `t44d-diag-d`): frame pushed at
0.078 ms, bridge yielded at 2.871 ms, model folded `.ended` at 2.938 ms — ~10 ms end to end, i.e.
the budget that failed was ~300× the work it was measuring.

## 3. What changed

Product (a real defect, not a test accommodation — the call screen could read "Joining…" after the
plugin had ended the call):

* `Mattermost/UI/Native/Calls/CallsSurfaceModels.swift` — new
  `CallsSurfacePhase.fold(_:_:)`: a terminal phase (`.ended`, `.failed`) is final; anything else
  moves as before. Unit-pinned in `T44DCallsSurfaceTests.testATerminalPhaseIsFinal`.
* `Mattermost/UI/Native/Calls/CallsCallModel.swift` — `foldPhase` goes through that rule;
  `handle(_:)` and `applySnapshot()` are no longer `private` (they are the model's two inputs and
  the test target drives them directly, the same shape `GlobalThreadsViewModel.handle` and
  `MentionsViewModel.handle` already have).

Tests (the card's point 2: no wall clock in the assertion):

* `testCallEndedEndsTheSurfaceAndReleasesTheCoordinator` — folds `.callEnded` through
  `CallsCallModel.handle` (what the pump calls per frame) and asserts **synchronously**: phase,
  `coordinator.surface == nil`, duration. Nothing to be late against.
* `testCallEndFromTheSocketReachesTheModelAndReleasesTheCoordinator` — keeps the whole wire
  (fake socket → `CallsEventBridge` → pump → model → coordinator) but waits on the model's own
  completion signal (`onEnded`, chained so the coordinator still gets it) instead of polling. The
  30 s is stated as a hang detector (~3000× the measured latency): a stuck pipeline reds, a merely
  late one does not.
* `testASnapshotTakenBeforeTheEndCannotReopenTheCall` — both inputs driven directly, in the order a
  loaded process produces them; pins the §2 defect.
* `T44DCallsSurfaceTests.testATerminalPhaseIsFinal` — the rule as a pure function, next to the
  existing `derive` tests.

## 4. Red cases (mutations), and the acceptance runs

| mutation | expected | measured |
|---|---|---|
| M1 — `case .callEnded` fold removed in `handle` | the two clock-free rules red; the wire test reds at its hang detector | `testCallEnded…` red in **0.002 s** (`("joining") is not equal to ("ended")`), `testCallEndFromTheSocket…` red at 30 s (unfulfilled expectation), `testASnapshot…` red |
| M2 — `events:` in `startCall` replaced with a finished stream (no bridge) | only the wire test reds | `testCallEndFromTheSocket…` red at 30.1 s; `testCallEnded…` **green** (0.001 s); `testCallState…`/`testParticipantDeltas…` red, as they need the bridge too |
| M3 — `CallsSurfacePhase.fold` returns `next` (terminal rule removed) | the resurrection is reproduced deterministically | `testATerminalPhaseIsFinal` red (5 assertions), `testASnapshot…` red, `testCallEndFromTheSocket…` red in 0.031 s with `("joining")` |

Acceptance on the fixed tree (the tree that is committed — the last change before these runs was a
comment in the test's doc block):

* `MattermostTests/T44DCallsCoordinatorTests` + `T44DCallsSurfaceTests`: **34 run, 0 failed**
  (`t44d-fix-final-class`).
* Whole `MattermostTests`, twice in a row, on the same tree:
  **1629 run, 6 skipped, 0 failed** (`t44d-fix-final-1`, 37.7 s) and
  **1629 run, 6 skipped, 0 failed** (`t44d-fix-final-2`, 40.6 s). Logs committed to `docs/`.

Reproduce:

```
python3 scripts/qa-test.py --platform ios --sim id=81A7F251-8B31-4945-8783-5A264C14B8D5 \
  --only-testing MattermostTests --label <label> \
  --derived-data ~/Library/Developer/Xcode/DerivedData/mmios-t44d-flake
```

The symptom needs contention, so: launch two of those at once against the same simulator (each
with its own derived-data path), or freeze the host — the harness used here is committed as
`scripts/qa-freeze-host.sh`:

```
python3 scripts/qa-test.py --only-testing MattermostTests/T44DCallsCoordinatorTests \
  --sim id=81A7F251-8B31-4945-8783-5A264C14B8D5 --label freeze-target ... &
scripts/qa-freeze-host.sh build/logs/freeze-target.log \
  "testCallEndedEndsTheSurfaceAndReleasesTheCoordinator]' started." 4.5
```

(Note the log lag: xcodebuild flushes the test-case lines a few seconds late, so the freeze
usually lands one or two tests after the marker — which is why both freeze runs hit
`testDeniedMicrophone…`.)

## 5. What this does not fix

* The class still contains three-second `waitUntil` polls that measure the host the same way
  (`testDeniedMicrophoneStillJoinsAndExplainsItself`, `testMuteIsOptimistic…`,
  `testRaiseHandReachesTheEngine…`, `testCallStateDrawsTheTiles…`, `testParticipantDeltas…`): on the
  fixed tree `t44d-freeze4` reds `testDeniedMicrophone…` at 5.1 s while the three converted tests
  pass, so the exposure is unchanged for those. Converting them needs signals from the *engine*
  side (they wait for snapshot-driven values), which is a larger change than this card. Filed as
  its own card so it is not lost: **t_19ab2cbc** (with the full list of the remaining waits and
  `scripts/qa-freeze-host.sh` to check them against).
* No live/UI run was needed: the change is unit-visible only (the model's phase rule), and the
  surface's rendered states are pinned by `T44DCallsSurfaceTests`.
