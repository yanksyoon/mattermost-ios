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

## 5. What this card left open (closed by §6)

* The class still contained three-second `waitUntil` polls that measured the host the same way
  (`testDeniedMicrophoneStillJoinsAndExplainsItself`, `testMuteIsOptimistic…`,
  `testRaiseHandReachesTheEngine…`, `testCallStateDrawsTheTiles…`, `testParticipantDeltas…`): on the
  fixed tree `t44d-freeze4` reds `testDeniedMicrophone…` at 5.1 s while the three converted tests
  pass. Filed as its own card, **t_19ab2cbc**, and converted there — see §6.
* No live/UI run was needed: the change is unit-visible only (the model's phase rule), and the
  surface's rendered states are pinned by `T44DCallsSurfaceTests`.

## 6. t_19ab2cbc — the remaining polls, converted (2026-10-27)

Every `waitUntil` in `T44DCallsCoordinatorTests` is gone; the class has no wall clock in it at all
and runs in **0.13 s** instead of ~15 s. What replaced each wait, by kind:

| test | was | is now |
|---|---|---|
| `testCallStateDrawsTheTilesAndResolvesNames` | `waitUntil("two tiles")` | frame decoded with `CallsEvent(name:data:)` (what the bridge calls) and folded by `CallsCallModel.handle` (what the pump calls); assertions synchronous. A **second** `call_state` for already-cached profiles is folded too, so dropping the fold's own `rebuildParticipants()` reds it — the profile fetch's rebuild would otherwise hide that |
| `testParticipantDeltasUpdateTheTiles` | five polls (tile, unmute, join, speaking, leave) | the same five frames through `handle`, each asserted before the next arrives |
| `testMuteIsOptimisticAndReachesTheEngine` | `waitUntil("connected with a microphone")` | `await model.applySnapshot()` once, then `phase`/`microphone`/`controls` asserted synchronously |
| `testRaiseHandReachesTheEngineAndMarksTheTile` | same | same |
| `testDeniedMicrophoneStillJoinsAndExplainsItself` | same, `.denied` | same |
| `testLeavingStopsTheEngineOnce` | `waitUntil("released")` | nothing: `leave()` is awaited and calls `onEnded` synchronously, so `coordinator.surface == nil` is true on the next line |
| `testAuthPhaseChangedDropsTheCallAndRememberedFacts` | `waitUntil("engine stopped")` | the model's own `onEnded` signal (chained so the coordinator still gets it), fired *after* `engine.stop()`; 30 s hang detector |

Two end-to-end tests keep the whole wire (fake socket → `CallsEventBridge` → pump → model) and wait
on the model's own signals — `@Published` values for the deltas and `onEnded` for the end — with the
same 30 s hang detector. That is where the pump/bridge wiring stays pinned:

* `testParticipantDeltasFromTheSocketReachTheTiles` (new) — the five deltas of the synchronous test
  through the socket, waiting on `$participants` / `$isMuted`.
* `testEngineSnapshotReachesThePhaseAndMicrophoneWithoutAPoll` (new) — nothing drives
  `applySnapshot`; the engine pump does, and the test waits on `$phase`. This is the only test that
  reds when `startEnginePump()` is removed, so the three synchronous snapshot tests stay cheap
  without leaving the pump unpinned.

Two supporting changes in the fixture:

* `FakeCallsEngine.connect(microphone:)` — one actor hop for "connected, with a microphone answer".
  `setState` then `setSnapshot` are two `await`s, and the model's engine pump (0.4 s) can tick
  between them and read a connected state with the *previous* microphone answer, which the real
  engine never reports (it asks for the microphone before it connects). That race is what the first
  version of the new E2E test hit; `setSnapshot` is otherwise unused now and is gone.
* `import Combine`, for the `@Published` subscriptions above.

### Red cases (mutations)

Each mutation was applied to the product files, the class run, and the files reverted
(`build/mutants/run_mutants.py`, evidence in `docs/t19ab2cbc-mutations-2026-10-27.log`):

| mutation | red |
|---|---|
| M1 `.callState` rebuild dropped + `isMuted` fold in `.muteChanged` dropped | `testCallStateDrawsTheTilesAndResolvesNames` (0.26 s), `testParticipantDeltasUpdateTheTiles` (0.004 s) |
| M2 `await engine.setMuted/setHandRaised` dropped | `testMuteIsOptimistic…`, `testRaiseHandReachesTheEngine…` |
| M3 `microphone = snapshot.microphonePermission` dropped | `testDeniedMicrophone…`, `testMuteIsOptimistic…`, `testRaiseHand…`, `testEngineSnapshot…` |
| M4 `onEnded?()` dropped from `leave()` | `testLeavingStopsTheEngineOnce`, `testAuthPhaseChanged…` |
| M5 sign-out's detached `live.leave()` dropped | `testAuthPhaseChanged…` only |
| M6 `startEnginePump()` dropped from `start()` | `testEngineSnapshotReachesThePhaseAndMicrophoneWithoutAPoll` only |
| M7 the bridge yields no frames | `testParticipantDeltasFromTheSocketReachTheTiles` (120 s = 4 × its hang detector), `testCallEndFromTheSocket…` (30 s) |

Every mutation reds the intended test **and no other test reds by accident**: the two "only" rows
(M5, M6) are the isolation pins, and the synchronous tests red in milliseconds because there is no
budget left to burn.

### The freeze check, and why `qa-freeze-host.sh` needed a sibling

The committed marker-triggered harness cannot prove anything about this class any more, and that is
measurable rather than theoretical: with the marker
`"testASnapshotTakenBeforeTheEndCannotReopenTheCall]' started."`, `scripts/qa-freeze-host.sh` waited
**12.1 s** for the line to be flushed, then found the host already gone (`kill: (7072) - No such
process`) — the class had finished in 0.13 s. The freeze landed on nothing.

`scripts/qa-freeze-host-window.py` makes the check honest again in two ways (see its docstring):
`-test-iterations N` widens the class's window to N × 0.13 s, and a run only counts when the log
proves the freeze landed inside the class — some test's own reported duration ≥ the freeze, because
a stopped process cannot finish a test while it is stopped.

Measured (this tree, `t19ab2-…`):

```
Executed 2100 tests, with 0 failures   # the class × 100 iterations
frozen: testASnapshotTakenBeforeTheEndCannotReopenTheCall (4.64 s)
```

That is the acceptance in §1's terms: the host was stopped for 4.5 s **while a test was running**,
and the class was green. Before this card the same freeze redded `testDeniedMicrophone…` at 5.1 s.

### Acceptance on the committed tree

Whole `MattermostTests`, twice in a row, same simulator and derived data
(`docs/t19ab2cbc-full-units-1-2026-10-27.log`, `…-2-…log`):

* **1631 run, 6 skipped, 0 failed** — 37.6 s
* **1631 run, 6 skipped, 0 failed** — 38.0 s

(1631 = the parent's 1629 + the two new end-to-end tests.) The calls class alone: **21 tests, 0
failures, 0.078 s**.

