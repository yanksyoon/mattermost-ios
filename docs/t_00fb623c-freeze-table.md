# t_00fb623c — the last 94 clock-poll waits, converted and proven able to fail

The eleven files t_eccd49eb left measured-not-converted (`docs/t-eccd49eb-freeze-table.md` §5) no
longer poll a clock. `waitUntil` is **deleted from `MattermostTests`**: every await is now a value a
fake, transport, coordinator callback or Combine publisher mirror recorded, and `awaitSignal` keeps
only its 30 s hang detector.

Commit: `ca7f97d` on `t_00fb623c` (worktree `.worktrees/t_00fb623c`), whole `MattermostTests`
1640 run / 8 skipped / 0 failed (`build/logs/t_00fb623c-full.log`).

## 1. What each file's waits became

| file | sites | signal the test now awaits |
|---|---|---|
| T34SocketResyncTests | 11 | `factory.createdSignal`, transport `sentSignal`/`closeSignal`, resync recorder |
| T34SocketStallWatchdogTests | 18 | steppable clock `parkSignal(Park(seconds:ordinal:))`, transport signals, rail `resynced` |
| T43RSocketLivenessTests | 9 | rail `onSocketStateChange` (the report itself, not `liveSocketCount`) |
| T44DSocketBinarySendTests | 2 | transport `textSignal`/`sentSignal` |
| T35ComposerViewModelTests | 20 | draft-store `writeSignal`, mirrored `$suggestions`/`$attachments`/`$phase`, service `userTermSignal`/`channelTermSignal` |
| T44CCallsEngineTests | 14 | `CallsEngine.observeSnapshots` (an actor has no publisher), signalling `descriptionSignal`/`candidateSentSignal` |
| T37SocketReactionRoutingTests | 4 | event-source `subscribedSignal`, delivery counts |
| T32TeamSidebarTests | 9 | service `loadSignal`/`unreadSignal`/icon signal, source `subscribedSignal` |
| T31AuthCoordinatorTests | 1 | `AuthCoordinator.onChange` → `TestSignal<UUID>` phase changes |
| TokenLoggingTests | 2 | factory `createdSignal`, transport `sentSignal` |
| T34ChannelViewRestoreWiringTests | 3 | `mirrorPublished(model.$lastScrollRestore)` |

Three waits stay fixed settles **on purpose** (pile b — they assert an *absence*, and an absence has
no event to await): the autocomplete superseded-answer window, the loopback ICE gathering window, and
two "does not refetch" fences. Each carries a comment naming it as such.

## 2. Mutations — every converted test must be able to fail

`build/mutants/run_mutants.py`: 39 product mutants, one at a time (`edit → class run → git checkout`
per mutant, anchor-checked so a `find` that is not unique aborts instead of mutating something else).
Raw evidence: `docs/t_00fb623c-mutations-2026-10-27.log` (a later row for an id supersedes an earlier
one — the first pass found real defects that were then fixed and re-run).

**38 of 39 PASS** (the mutant reds every test it names). Four mutants exposed test defects that are
now fixed in this commit:

| mutant | what the first pass proved | fix |
|---|---|---|
| MS5 watchdog-starts-without-visibility | `testAClientWithoutAVisibilityPredicateNeverStartsWithAWatchdog` asserted a park count before the watchdog Task could run — a race, not a test | documented pile-(b) settle before the assertion |
| MS7 watchdog-window-not-restarted | `testAReconnectDoesNotDoubleFire…` never advanced virtual time between the first open and the drop, so "the open restarted the window" was untestable | `now.advance(watchdog.threshold - 5)` before `first.close()` |
| MCP6 custom-emoji-dropped | `testEmojiComeFromTheBuiltInTableAndTheServersCatalogue` only asserted the built-in table | test now stubs an `EmojiCatalogue` page and asserts the custom shortcode |
| MS3 frame-logged-with-token → socket-never-authenticates | a `debug`-level leak never reaches the test sink, so that mutant was unobservable | mutant now removes the challenge frame (the token test reds on its first assertion) |

**MCP8 (draft row survives a send) SURVIVED**: the deletion path mutated in `writeDraftSnapshot()`
is not the one this test observes, and the test stayed green. Recorded as an open finding, not as
coverage — the draft-clear-after-send assertion is weaker than its name.

**Exempt (cannot red on this host, by construction not by luck):** the three calls peer-negotiation
tests are `XCTSkip`ped (a second `RTCPeerConnectionFactory` blocks in CoreAudio),
`testLocalCandidatesAreSentOnlyAfterTheOffer` is a bounded observation window on loopback ICE
gathering, and `testStatisticsReadTheEngineWithoutCrashing` is a no-crash smoke test.

## 3. Freeze runs (class level, each file's largest former budget + 2 s)

Method: `scripts/qa-freeze-measure.py --only-testing MattermostTests/<Class> --iterations 6
--lags 0,1.0,3.0 --freeze <budget+2> --stop-on-frozen`; a landing only counts when a test's own
reported XCTest duration is ≥ the measured SIGSTOP (`frozen=`), so the log proves where the stop
landed. Driver: `build/mutants/freeze_sweep.py`, rows in `build/logs/freeze-rows.txt`.

| file (class) | freeze | proven frozen test (its own duration) | red |
|---|---|---|---|
| T34SocketResyncTests | 12 s | `testAResyncMergesTheNewestPageAndKeepsTheOlderPagesTheReaderLoaded` (12.05 s) | **none** |
| T34SocketStallWatchdogTests | 12 s | `testAClientWithoutAVisibilityPredicateNeverStartsWithAWatchdog` (12.27 s) | **none** |
| T32TeamSidebarTests | 7 s | `testASecondAppearanceDoesNotRefetchTheRail` (7.05 s) | **none** |
| T31AuthCoordinatorTests | 5 s | `testMFAChallengeThenSuccess` (5.04 s) | **none** |
| T34ChannelViewRestoreWiringTests | 12 s | `testASecondRequestRestoresAgainAfterTheFirstWasConsumed` (14.98 s) | **none** |
| T35ComposerViewModelTests | 7 s | `testAStaleAutocompleteAnswerIsDropped` (7.14 s) | **none** |
| T44CCallsEngineTests | 7 s | `testAConfirmedUnmuteSurvivesTheNextSnapshot` (7.25 s) | **none** |
| T43RSocketLivenessTests, T44DSocketBinarySendTests, T37SocketReactionRoutingTests, TokenLoggingTests | 7 s | **no landing** — 6 iterations × 3 lags never had the stop land inside the class (it is shorter than xcodebuild's log-flush lag), so these rows are not evidence | not measured |

Seven of eleven files are proven green with the host frozen for longer than any wait they used to
carry. The remaining four are *unproven, not failed*: their classes are too short for a class-level
SIGSTOP to land inside them with this harness, and the honest statement is "no landing", not "green".
Their conversion rests on §2 (each converted test reds under a product mutant) and on the whole-suite
run, both of which are measured.


## 4. What this card does not prove

- A freeze can still inflate a *test that measures the host by design* (the `MMStoreSize` byte
  measurements, the audio/ICE peer tests). Those are not clock polls and were out of scope here.
- MCP8's survivor above: the draft-clear assertion should be re-bound to the actual clear path
  before it is trusted as coverage.
