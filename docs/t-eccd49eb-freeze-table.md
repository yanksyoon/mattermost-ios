# t_eccd49eb — the rest of `MattermostTests`: what a host freeze actually reds, and the one file it reds

Written 2026-10-27 in `.worktrees/t_eccd49eb`. Every measurement below was taken on a tree based on
`origin/main 5a75513` (t_19ab2cbc's tip). `main` then moved to `20b7cc8` (native-UI work), the branch
was rebased onto it cleanly, and the class run plus the two acceptance suite runs were repeated on
the rebased tree — those repeats are the committed acceptance evidence (§9), the rest of the tables
are the `5a75513`-based runs. Evidence files are committed next to this one; every table row is a
line in one of them.

* `docs/t-eccd49eb-freeze-runs-2026-10-27.log` — the parsed rows quoted below, one per run, with
  the log path for every run.
* `docs/t-eccd49eb-mutations-2026-10-27.log` — the mutation table of §6 with the failure text each
  mutant produced.
* `docs/t-eccd49eb-full-units-1-2026-10-27.log`, `…-2-…log` — the two acceptance suite runs.
* Harness: `scripts/qa-freeze-measure.py` (new; both modes and the log-proof rule in its docstring).

## 1. How the freeze is aimed, and what counts as proof it landed

`SIGSTOP` on the test host for `--freeze` seconds. The harness has two modes because a *class* is
often shorter than xcodebuild's log flush lag, while a *suite* is not:

* **suite mode** — wait for `Test Suite 'MattermostTests.xctest' started` in the log, sleep the
  offset, stop the freshly launched host. The suite is ~37 s, so offsets 0…28 s cover it.
* **class mode** — run the class N times (`-test-iterations`), wait for its first test-case line,
  sleep the lag, stop. N is chosen so the window is ~5 s; the lag is swept when a run does not land.

A run is only used when the log proves the freeze landed **inside**: XCTest times every test on the
wall clock, so the frozen test's own reported duration is ≥ the freeze while every other test is
milliseconds. Every row below names that test (`frozen=`), and `freeze=` is the measured length of
the stop itself. This is the same rule t_19ab2cbc's `qa-freeze-host-window.py` uses, generalised to
a whole suite; the log-flush lag measured here (stop time minus the requested offset) was 0.17–0.35 s
per run — not the ~12 s that card's window saw — so plain offsets were honest.

## 2. Baseline (no freeze)

Whole `MattermostTests`, fresh derived data outside TCC-protected folders:

```
Executed 1631 tests, with 6 tests skipped and 0 failures — 36.609 s   (build/logs/t-eccd49eb-baseline.log)
```
On the rebased tree (`20b7cc8` + this change): **1640 tests, 8 skipped, 0 failures, 37.3 s twice**
(§9; the nine extra tests are the native-UI work that landed on `main` meanwhile).

## 3. Table A — whole suite frozen for 4.5 s, eight offsets (before)

| run | offset | freeze | test the log proves was frozen (its own duration) | red |
|---|---|---|---|---|
| off0 | 0 s | 4.54 s | `AuthSessionTests.testAdoptingAWebSessionEndToEndThroughThePerServerCookieStore` (4.60 s) | none |
| off4 | 4 s | 4.52 s | `MMStoreConcurrencyTests.testEvictionDuringConcurrentInsertsKeepsTheBudget` (5.18 s) | none |
| off8 | 8 s | 4.57 s | `MMStoreSizeTests.testHundredChannelsAtTheShippingWindow` (8.47 s) | none from the freeze — but the run itself ended `** TEST FAILED **` (host restart, §3.2) |
| off12 | 12 s | 4.52 s | `MMStoreSizeTests.testRetentionPolicyBoundsDiskForABusyServer` (7.79 s) | none |
| off16 | 16 s | 4.50 s | `MMStoreTests.testStoreSizeReportsPagesAndFileBytes` (4.60 s) | none |
| off20 | 20 s | 4.53 s | `T31AuthCoordinatorTests.testSignOutClearsTheVaultBeforeTheLogoutCallCompletes` (4.86 s) | none |
| off24 | 24 s | 4.57 s | `T34ChannelViewRestoreWiringTests.testASecondRequestRestoresAgainAfterTheFirstWasConsumed` (8.32 s) | none |
| off28 | 28 s | 4.54 s | `T34ChannelViewRestoreWiringTests.testTheListTurnsAPendingAnchorIntoARestoreAndConsumesIt` (6.93 s) | none |

Two findings from Table A, both of them about the *measurement*, not about a pass:

1. **A whole-suite freeze samples one test per run, and the suite is dominated by the slow ones.**
   Six of the eight landings are the perf/size tests (`MMStore*`), which is where the suite spends
   its wall clock; the two `T34ChannelViewRestoreWiring` landings survive because that class's poll
   budget is 10 s, not because it has no clock (Table C). So a green whole-suite sweep is **not**
   evidence that the 156 sites are safe — it is evidence about eight tests.
2. **`off8` lost the second half of the suite to a test-host restart**, 35 s *after* the freeze was
   released: `Restarting after unexpected exit, crash, or test timeout` at
   `MMStoreTests.testStoreSizeReportsPagesAndFileBytes.started` (line 2002 of the log), then again
   at `T44CCallsEngineTests.testStartAsksForTheMicThenJoinsAndOffers` (line 4979), and
   `Failing tests: MMStoreTests.testStoreSizeReportsPagesAndFileBytes(),
   T44CCallsEngineTests.testStartAsksForTheMicThenJoinsAndOffers()` — two tests that never printed a
   result. The frozen test itself passed (8.47 s). `off16` froze the same `MMStoreTests` test and
   the run stayed whole and green, so this is **not** reproducible by the freeze in one sample and is
   reported as an open observation (see §8), not as a freeze red.

## 4. Table B — every file that carries a `waitUntil`, frozen for 4.5 s (before)

`-iterations` is the window multiplier (`-test-iterations`); `lag` is the sweep value that landed.
This is the acceptance question ("green under a 4.5 s freeze") answered per file instead of per
suite sample.

| file (class) | sites | iterations | freeze | proven frozen test (duration) | red |
|---|---|---|---|---|---|
| `SocketClientTests` | 53 | 13 | 4.52 s | `testHeartbeatTimeoutRecyclesTheConnectionAndResyncsOnceAfterTheReconnect` (25.06 s), `testALongLivedSessionResetsAnAlreadyClimbedLadder` (8.00 s), `testPongClearsTheMissedPongCount` (5.03 s) | **2** — `testHeartbeatTimeout…` (`timed out waiting for ping sent`, then five cascading timeouts), `testPongClearsTheMissedPongCount` (`timed out waiting for second ping`, then `closeCount 1 ≠ 0`) |
| `T35ComposerViewModelTests` | 20 | 7 | 4.55 s | `testASecondSendIsRefusedWhileTheFirstIsInFlight` (4.63 s) | none |
| `T34SocketStallWatchdogTests` | 19 | 5 | 4.50 s | `testAClientWithoutAVisibilityPredicateNeverStartsWithAWatchdog` (4.60 s) | none |
| `T44CCallsEngineTests` | 15 | 3 | 4.54 s | `testAConfirmedUnmuteSurvivesTheNextSnapshot` (4.94 s) | none |
| `T34SocketResyncTests` | 12 | 22 | 4.51 s | `testAFirstConnectDoesNotRefetchTheWindowAndTheSocketStillDelivers` (4.59 s) | none |
| `T43RSocketLivenessTests` | 10 | 42 | 4.56 s | `testAFinishedPumpWithdrawsLiveness` (4.69 s) | none |
| `T32TeamSidebarTests` | 9 | 10 | 4.57 s | `testAfterASwitchThePreviousTeamsEventsAreRefused` (4.64 s) | none |
| `T37SocketReactionRoutingTests` | 5 | 50 | 4.56 s | `testAnUnattributableReactionIsAcceptedAndEachPaneFiltersByPost` (4.57 s) | none |
| `T34ChannelViewRestoreWiringTests` | 4 | 2 | 4.58 s | `testASecondRequestRestoresAgainAfterTheFirstWasConsumed` (7.57 s) | none |
| `TokenLoggingTests` | 3 | 100 | 4.50 s | `testLoginFlowNeverLogsTheSessionToken` (4.50 s) | none |
| `T44DSocketBinarySendTests` | 2 | 100 | 4.50 s | `testBinaryFrameReachesTheTransportThatImplementsSendData` (4.51 s) | none |
| `T31AuthCoordinatorTests` | 2 | 3 | 4.52 s | `testSignOutClearsTheVaultBeforeTheLogoutCallCompletes` (4.54 s) | none |

(`T28TestSupport.swift` and `T44DCallsCoordinatorTests.swift` carry no call site: a helper
definition and a comment respectively.)

**The 4.5 s criterion reds exactly one file.** That is not because the other eleven are signal-based:
their budgets are 5 s (shared helper and most private copies) or 10 s (`T34SocketResyncTests`,
`T34SocketStallWatchdogTests`, `T34ChannelViewRestoreWiringTests`), so a 4.5 s stop cannot exhaust
them. §5 measures that directly, because "it survives 4.5 s" and "it has no clock" are different
claims and the card is about the clock.

## 5. Table C — frozen for *longer than the budget* (the clock-poll probe)

Same harness, freeze = the file's largest wait budget + 2 s. The rule "a bigger budget only moves
the flake" cuts both ways: if the file is green here it is not a clock-poll, and if it reds it was
only ever protected by its budget.

| file (class) | freeze (largest budget) | proven frozen test (duration) | red |
|---|---|---|---|
| `T34SocketResyncTests` | 11.51 s (10 s) | `testAFirstConnectDoesNotRefetchTheWindowAndTheSocketStillDelivers` (12.04 s) | **1** — same test, `timed out after 10s waiting for …` |
| `T34SocketStallWatchdogTests` | 11.54 s (10 s) | `testAClientWithoutAVisibilityPredicateNeverStartsWithAWatchdog` (11.74 s) | **1** — same test, `timed out after 10s waiting for …` |
| `T43RSocketLivenessTests` | 6.51 s (5 s) | `testAFinishedPumpWithdrawsLiveness` (6.63 s) | **1** — same test |
| `T44DSocketBinarySendTests` | 6.57 s (5 s) — landed on the 0.5 s lag | `testBinaryFrameReachesTheTransportThatImplementsSendData` (6.63 s) | **1** — same test |
| `T35ComposerViewModelTests` | 6.51 s (5 s) | `testAStaleAutocompleteAnswerIsDropped` (6.73 s) | none (this landing sat between waits) |
| `T44CCallsEngineTests` | 6.58 s (5 s) | `testADeltaForAnotherChannelIsNotFolded` (6.74 s) | none (this landing sat between waits) |
| `T37SocketReactionRoutingTests` | 6.56 s (5 s) | `testASocketReactionReachesTheOpenPanesRowThroughTheRail` (6.65 s) | none (this landing sat between waits) |
| `T32TeamSidebarTests` | 6.57 s (5 s) | `testAFailedCounterRefreshKeepsTheLastNumbersAndSaysTheyAreStale` (6.67 s) | none (this landing sat between waits) |
| `T31AuthCoordinatorTests` | 6.53 s (3 s) | `testBeginSignOutIsSynchronousAndStillRevokesWithTheDiscardedToken` (6.55 s) | none (this landing sat between waits) |
| `TokenLoggingTests` | 6.51 s (5 s) | `testLoginFlowNeverLogsTheSessionToken` (6.54 s) | none (this landing sat between waits) |
| `T34ChannelViewRestoreWiringTests` | 11.56 s (10 s) | `testASecondRequestRestoresAgainAfterTheFirstWasConsumed` (14.53 s) | none (the stop landed in the test's scripted delays, not inside a wait) |
| `SocketClientTests` | 6.57 s (5 s), before §6 | `testSequenceGateDropsAReplayOnTheSameConnection` (6.59 s) | none **at this landing** — and yet the same file redded 2 tests at a 4.5 s freeze in Table B |

**Four of the twelve files red their own frozen test** — that is direct proof that the value they wait
for is produced by a task the test drives and observed by a clock: the frozen test is the test that
fails, with its own budget's message. **The green rows are not a clean bill of health**: a wait can
only red when the stop straddles its deadline, so one landing that missed every deadline says
nothing. The `SocketClientTests` row is the proof of that — green here at a *longer* freeze, red at
4.5 s in Table B, because the two runs froze different tests.

## 6. What was converted: `SocketClientTests` (53 of the 156 sites, 19 tests)

This is the file the 4.5 s criterion reds, it is the largest single exposure (34 % of all sites),
and both reds are pure clock-polls: `transport.sent`, `transport.closeCount`, `factory.created` and
`box.count` are all produced by tasks the test drives through its own fakes.

Before / after:

| | before | after |
|---|---|---|
| `waitUntil` call sites | 53 | **0** |
| class duration | 0.400 s (sum of test durations) | **0.156 s** |
| red under a 4.5 s freeze | 2 tests (`testHeartbeatTimeout…` 25.06 s, `testPongClears…` 5.03 s) | **0 in 6 landings** (frozen 4.50–4.62 s each) |
| red under a 6.5 s freeze (no budget left) | not measured (file not converted) | **0 in 4 landings** (see §6.2) |

### 6.1 What replaced each kind of poll

The fakes now record signals instead of the test polling their state (`TestSignal` in
`MattermostTests/T28TestSupport.swift`):

| was | is now |
|---|---|
| `waitUntil { factory.created.count == 1 }` | `factory.createdSignal` — fires with the running count, so `until: { $0 == 2 }` is "the second connection" |
| `waitUntil { transport.sent.contains { … } }` / `{ transport.sent.count == 2 }` | `transport.sentSignal` (the frame) and `sentCountSignal` (the count) |
| `waitUntil { transport.closeCount == 1 }` | `transport.closeSignal` |
| `waitUntil { box.count == 12 }` / `{ box.streamFinished }` | `box.appendedSignal` (count) and `box.finishedSignal` |
| `waitUntil { await client.state == .open }` | the **auth challenge frame** on that transport: `handleOpen()` sets `state = .open` *before* it sends, so the frame proves the open was handled. No poll of the actor's state |
| `waitUntil { clock.requestedDelays… }` / `{ await client.retryDelays.count == n }` | `clock.sleepSignal` (running count) and `clock.delaySignal` (the delay) |
| `waitUntil { resyncReasons.count == 1 }` | `ResyncLog.signal` |
| `clock.release()` then poll for its effect | `clock.releaseWhenParked()` — waits for the sleep to be *parked* (`parkedSignal`), then releases it. The old pair had a real race: `release()` on an unparked clock is a no-op and the poll then burned its whole budget |
| `waitUntil("second ping") { sent.count == 3 }` after pushing a pong | a **fence**: the client folds a pong inside its actor and publishes nothing, so a `hello` frame is pushed after the pong and its delivery is awaited; the client's frame loop is FIFO over one transport stream, so the hello proves the pong was folded before the next tick is released |

Every wait is `awaitSignal(…)`, whose timeout is a **30 s hang detector** (default in
`TestSignal.wait`), not a latency budget: it returns the instant a matching value is recorded, and
only a pipeline that produces nothing reaches 30 s. `assertForOverFulfill`-style double-fire is
impossible by construction (a waiter is removed under the lock before it is resumed, and the timer
only resumes a waiter it could still remove).

One wait in the class is deliberately **not** a signal — see pile (b) in §7.

### 6.2 Freeze check on the converted file

`scripts/qa-freeze-measure.py --only-testing MattermostTests/SocketClientTests --iterations 32`:

| freeze | landings | proven frozen test (duration) | red |
|---|---|---|---|
| 4.5 s | 6 (`lag` 0, 0.5, 1, 1.5, 2, 3) | `testALongLivedSessionThenADropStartsTheLadderAtBase` (4.58), `testOnlyReplayableIdentitiesCarryADedupeKey` (4.58), `testSequenceGateDropsAReplayOnTheSameConnection` (4.52 / 4.62 / 4.56), `testStopFinishesSubscriberStreams` (4.50) | **none** |
| 6.5 s | 4 (`lag` 0, 0.5, 1.5, 3) | `testAReAddedReactionIsDelivered` (6.55), `testOnlyReplayableIdentitiesCarryADedupeKey` (6.57), `testOpenSendsAuthenticationChallengeAndDeliversHello` (6.53), `testTwoChannelViewedEventsOnOneConnectionAreBothDelivered` (6.50) | **none** |
| 4.5 s and 6.5 s, re-run on the **final** tree (after the reconnect fence of §6.3) | 1 landing each (`lag` 0) | `testAReAddedReactionIsDelivered` (4.56), `testALongLivedSessionThenADropStartsTheLadderAtBase` (6.51) | **none** |

The 6.5 s rows are the ones that matter for the card's thesis: the old red (`testPongClears…`) was a
5 s budget, so a stop longer than 5 s reds a poll — the converted class has no budget left to
exceed.

### 6.3 Mutations — every converted test can still go red

Table + failure text: `docs/t-eccd49eb-mutations-2026-10-27.log`. Harness:
`build/mutants/run_mutants.py` (one mutant at a time) and `build/mutants/run_batches.py` (one build
per group of non-conflicting mutants, added after the first three showed a product-file edit costs
a 2–5 minute rebuild). Product edits are applied, the class run, and the files reverted with
`git checkout`.

M1–M3 were run **one at a time**, so for those the red list is also the isolation list; M4–M16 were
run in four batches of non-conflicting mutants, so a target redding is proven but "no other test
reds" is *not* claimed for them (the card asks for the former). Batch reds are the union of the
batch; the table below names, per mutant, the targets that redded.

| batch | mutant | targets that redded |
|---|---|---|
| A | M4 reaction keyed | `testAReAddedReactionIsDelivered` (*timed out after 30s waiting for all three reaction events*), `testOnlyReplayableIdentitiesCarryADedupeKey` (*XCTAssertNil failed: "reaction_added"*) |
| A | M5 sequence gate off | `testSequenceGateDropsAReplayOnTheSameConnection` (*XCTAssertEqual failed: "2" is not equal to "1" — seq 4 arrived after seq 5*) |
| A | M7 constant backoff | `testRepeatedOpenThenInstantCloseEscalatesTheBackoffLadder` (*[1,1,1,1] ≠ [1,2,4,8]*), `testALongLivedSessionThenADropStartsTheLadderAtBase` (*[1,1] ≠ [1,2]*), `testALongLivedSessionResetsAnAlreadyClimbedLadder` (*[1,1,1] ≠ [1,1,2]*) |
| A | M10 no stream finish | `testStopFinishesSubscriberStreams` (*timed out after 30s waiting for the subscriber stream to finish*) |
| B | M9 pong not folded | `testPongClearsTheMissedPongCount` (*timed out after 30s waiting for the second ping*) |
| B | M12 challenge without token | `testOpenSendsAuthenticationChallengeAndDeliversHello` (*the token travels in the challenge frame*) |
| B | M14 ws not wss | `testSocketURLIsWSSWithReliableParameters` (*Optional("ws") ≠ Optional("wss")*) |
| B | M16 preferences unmapped | `testTypedEventMatrix` (*failed - expected preferences_changed*) |
| C | M6 no resync | `testReconnectProducesOneBackoffSequenceAndOneResync` (*timed out after 30s waiting for the resync*), `testHeartbeatTimeout…` (*timed out after 30s waiting for the ping*) |
| C | M8 no ping | `testHeartbeatTimeout…` (*timed out after 30s waiting for the ping*), `testPongClears…` (*timed out after 30s waiting for the first ping*) |
| C | M15 anonymous bearer | `testHandshakeHeadersOmitAuthorizationWithoutAToken` (*XCTAssertNil failed: "Bearer "*) |
| D | M11 no bearer header | `testHandshakeHeadersCarryTheBearerTokenWhenOneIsConfigured` (*nil ≠ Optional("Bearer tok-header-1")*) |
| D | M13 always resync | `testFirstConnectDoesNotResync` (*1 ≠ 0 — the first connect is not a resync*) — **its second target stayed green: a test defect, see below** |
| D2 | M13 always resync (re-run after the fence) | `testFirstConnectDoesNotResync`, **and now** `testReconnectProducesOneBackoffSequenceAndOneResync` |

**A measurement finding that cost this card an hour:** `xcodebuild test` defaults to
`-collect-test-diagnostics on-failure`, so every mutant build (all of them red on purpose) paid a
post-run sysdiagnose — measured at **5 minutes of teardown per failing run** here, with the verdict
already printed. The mutation harness now passes `-collect-test-diagnostics never`, which brings a
failing class run back to ~35 s. Any suite that is *expected* to fail (`qa-test.py` used as a
red-team instrument) should pass it; `scripts/qa-test.py` does not add it by default.

**The mutation that found a test defect — and the fix.** M13 (`isReconnect = true`, so every open
resyncs) redded `testFirstConnectDoesNotResync` as expected, but
`testReconnectProducesOneBackoffSequenceAndOneResync` **stayed green**, i.e. that test could not see
"resync on every open". Cause: it read `resyncCount` and `resyncReasons.reasons` the instant the
first `.reconnected` signal arrived — before the second (duplicate) resync could land. It asserted a
snapshot, not "exactly one". Fixed inside the conversion, with the same discipline: after the resync
signal, push a `typing` frame on the recovered transport and await its delivery. The client's frame
loop is inside `handleOpen()` until that open's resync has run, so the delivered frame orders
strictly after it and the count read next is the whole story. Re-run as batch `D2`: M13 now reds the
test (row `D2` in the table above), and the class without the mutation is green (19 tests, 0
failures, 0.477 s — `build/logs/t-eccd49eb-socket-final.log`). This is why the mutated-but-green row
is kept in the table instead of being deleted.

| mutation | product edit | must red |
|---|---|---|
| M1 dedupe off | `if recentKeys.contains(key), false` | `testReplayedEventsAfterReconnectAreNotDeliveredTwice` |
| M2 typing keyed | `dedupeKey` returns a key for `.typing` | `testTypingIsNeverDeduplicated`, `testOnlyReplayableIdentitiesCarryADedupeKey` |
| M3 channel_viewed keyed | … for `.channelViewed` | `testTwoChannelViewedEventsOnOneConnectionAreBothDelivered`, `testOnlyReplayableIdentitiesCarryADedupeKey` |
| M4 reaction keyed | … for `.reactionAdded` | `testAReAddedReactionIsDelivered`, `testOnlyReplayableIdentitiesCarryADedupeKey` |
| M5 sequence gate off | `if seq <= serverSequence, false` | `testSequenceGateDropsAReplayOnTheSameConnection` |
| M6 no resync | `await resync?(.reconnected)` removed | `testReconnectProducesOneBackoffSequenceAndOneResync`, `testHeartbeatTimeout…` |
| M7 constant backoff | `delay = configuration.backoff.base` | `testRepeatedOpenThenInstantClose…`, `testALongLivedSessionThenADrop…`, `testALongLivedSessionResets…` |
| M8 no ping | the heartbeat's `send(action: "ping")` removed | `testHeartbeatTimeout…`, `testPongClearsTheMissedPongCount` |
| M9 pong not folded | `missedPongs = 0` removed from the pong branch | `testPongClearsTheMissedPongCount` |
| M10 no stream finish | `continuation.finish()` removed from `stop()` | `testStopFinishesSubscriberStreams` |
| M11 no bearer header | the upgrade's `Authorization` header removed | `testHandshakeHeadersCarryTheBearerTokenWhenOneIsConfigured` |
| M12 challenge without token | `["token": ""]` | `testOpenSendsAuthenticationChallengeAndDeliversHello` |
| M13 always resync | `isReconnect = true` | `testFirstConnectDoesNotResync`, `testReconnectProducesOneBackoffSequenceAndOneResync` |
| M14 ws not wss | `components.scheme = "ws"` | `testSocketURLIsWSSWithReliableParameters` |
| M15 anonymous bearer | header written even without a token | `testHandshakeHeadersOmitAuthorizationWithoutAToken` |
| M16 preferences unmapped | `case "preferences_changed_unused"` | `testTypedEventMatrix` |

## 7. Triage: pile (a), pile (b), and what is not a wait at all

* **Pile (a) — polling a clock (converted):** all 53 sites in `SocketClientTests`. Pile (a) — *not
  converted*: the 94 call sites in the other eleven files, whose values are also produced by tasks
  the test drives (`T35ComposerViewModelTests`' `model.phase`/attachments, `T34SocketResyncTests`'
  pane model after a scripted socket frame, `T43RSocketLivenessTests`' pump counters, …). Four of
  those files are *proven* clock-polls by Table C (the frozen test reds with its own budget's
  message); the other seven are unproven either way, because a stop must straddle a wait to red and
  the landings taken did not. Converting them blind is what this card forbids, so they are left for
  the follow-up card with their budgets.
* **Pile (b) — a wait with no signal available (kept, 30 s hang detector, not a budget):**
  * `SocketClientTests.testSequenceGateDropsAReplayOnTheSameConnection` keeps a 50 ms settle before
    `XCTAssertEqual(box.count, 1)`. It asserts an **absence**; there is no event to wait for. The
    delay is a fixed window, not a budget for a value to arrive in, and the comment in the test says
    so.
  * `SocketClientTests.testPongClearsTheMissedPongCount`'s ordering point is the `hello` **fence** of
    §6.1, not a poll: the pong is folded inside the client actor and the client publishes no
    completion signal for it. (A 5 s poll of `pongCount` would have re-introduced exactly the clock
    this card removes; the fence is a signal.)
* **Not a wait at all (reported so nobody mistakes them for candidates):** the `MMStoreSizeTests`
  and `MMStoreConcurrencyTests` budgets that Table A lands on are `measure`-style performance
  assertions. They measure the host by design; a freeze inflates them but they do not poll a task
  the test drove, and no conversion applies. The `T34ChannelViewRestoreWiringTests` fake's
  `Task.sleep(seconds)` is a scripted *server* delay inside a double, not a wait in the test body.

## 8. Deliberately left alone, and the open items

1. **94 clock-poll call sites in eleven files** remain (Table B/C). They are measured, not fixed
   here: converting them is a multi-file change that needs the same per-test mutation work this card
   did for one file, and doing it blind is what the card forbids. Filed as a follow-up card
   (see the kanban thread) with this table attached, one line per file with its budget.
2. **The clock question for seven of the eleven files is open, not answered.** All twelve files were
   probed at budget+2 s (Table C): four redded their own frozen test and are *proven* clock-polls
   (`T34SocketResyncTests`, `T34SocketStallWatchdogTests`, `T43RSocketLivenessTests`,
   `T44DSocketBinarySendTests`); the other seven stayed green at the landing taken, which is not
   proof of anything — a stop has to straddle a wait to red, and `SocketClientTests` itself went
   green at a 6.5 s freeze while two of its tests redded at 4.5 s. Repeating the probe with more
   landings per file is the cheap way to settle it; that is in the follow-up card.
3. **The `off8` host restart** (§3.2): `MMStoreTests.testStoreSizeReportsPagesAndFileBytes` and
   `T44CCallsEngineTests.testStartAsksForTheMicThenJoinsAndOffers` printed `started` and never a
   result; the run restarted twice and lost 1479 of 1631 test results. `off16` froze the same test
   and the suite stayed whole, and two whole-suite runs on the converted tree were green, so there
   is no reproduction here — but the card that owns those two tests should know they appeared as
   "failing" in a freeze run they were not frozen in.

## 9. Acceptance

* `SocketClientTests`: **19 run, 0 failed** plain (`build/logs/t-eccd49eb-socket-final.log`,
  0.477 s); **0 red** in 6 × 4.5 s landings and 4 × 6.5 s landings, each with the freeze proven by a
  test duration ≥ the stop (§6.2), plus one landing of each on the final tree after the reconnect
  fence.
* Mutations: every converted test reds under at least one product mutation (§6.3); 15 of the 16
  mutants red every target in a single run, and the sixteenth (M13) reds its second target only
  after the fence the mutation itself exposed — with the re-check (`D2`) in the log.
* Whole `MattermostTests`, twice in a row on the pushed tree (`20b7cc8` + this change):
  **1640 run, 8 skipped, 0 failed** — 37.338 s and 37.319 s,
  `docs/t-eccd49eb-full-units-1-2026-10-27.log` and `…-2-…log` (the full logs, with their sha256,
  are named at the top of those extracts). Before the rebase the same pair was **1631 run, 6
  skipped, 0 failed** (39.145 s, 37.294 s) on the `5a75513` tree; the class ran 19/0 in 0.477 s
  there and 19/0 in 0.124 s after the rebase.
