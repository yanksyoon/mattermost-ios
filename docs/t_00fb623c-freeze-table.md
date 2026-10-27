# t_00fb623c — the last 94 clock-poll waits, converted and proven able to fail

The eleven files t_eccd49eb left measured-not-converted (`docs/t-eccd49eb-freeze-table.md` §5) no
longer poll a clock. `waitUntil` is **gone from `MattermostTests`** (two mentions survive as
comments in `T44DCallsCoordinatorTests`, another card's file — no call sites): every await is now a
value a fake, transport, coordinator callback or Combine publisher mirror recorded, and
`awaitSignal` keeps only its 30 s hang detector. Whole target: **1658 run / 8 skipped / 0 failed**.

| commit | what it carries |
|---|---|
| `1e87032` | the eleven files' conversion + `CallsEngine.observeSnapshots` |
| `ad63fe4` | the fences and coverage the mutation pass exposed |
| `HEAD` | tracked harnesses (`scripts/qa-*.py`), this document, the two extra mutants below |

(`HEAD` is the commit that adds this file; the two rows above it are its ancestors on `t_00fb623c`.)

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
| T34ChannelViewRestoreWiringTests | 3 | `mirrorPublished(model.$lastScrollRestore)` / `$pendingScrollRestore` |

**Waits kept as fixed settles on purpose** (pile b — they assert an *absence* or a UI layout state,
and there is no event to await): the autocomplete superseded-answer window, the loopback ICE
gathering window, two "does not refetch" fences, and the two 1 s `mount()` layout settles in
`T34ChannelViewRestoreWiringTests` (rows have to lay out before a restore can be *requested*; the
values the tests assert are still the publisher mirrors).

**Other clock reads in these files that this card did not touch, and why:** `T31-AuthTests`'
`StallingLogoutTransport` sleeps 2 s to keep `/users/logout` in flight, and
`testSignOutClearsTheVaultBeforeTheLogoutCallCompletes` sleeps 0.4 s to observe the vault *during*
that call — a deliberate bounded observation of an intermediate state, not a wait for a value the
test drives. The `T34ChannelViewModelTests` / `T34ScrollRestorePathTests` sleeps are other cards'
files.

## 2. Mutations — every converted test can fail

`scripts/qa-mutants.py` (42 product mutants, one at a time: edit → class run → `git checkout` in a
`finally`; a `find` that is not unique aborts the run instead of mutating something else).
`scripts/qa-mutation-coverage.py` checks the result against the tests this card touched. Raw
evidence: `docs/t_00fb623c-mutations-2026-10-27.log` (a later row for an id supersedes an earlier
one — the first pass found real defects that were then fixed and re-run).

**42 of 42 PASS. 47 of the 51 converted test bodies are redded by a PASS mutant.** The 4 that are
not are the recorded exemptions below.

Defects the mutants exposed in the *tests* (all fixed in `ad63fe4`):

| mutant | what it proved | fix |
|---|---|---|
| MS5 watchdog-starts-without-visibility | `testAClientWithoutAVisibilityPredicateNeverStartsWithAWatchdog` asserted a park count before the watchdog Task could run — a race, not a test | documented pile-(b) settle before the assertion |
| MS7 watchdog-window-not-restarted | `testAReconnectDoesNotDoubleFire…` never advanced virtual time between the first open and the drop, so "the open restarted the window" was untestable | `now.advance(watchdog.threshold - 5)` before `first.close()` |
| MCP6 custom-emoji-dropped | `testEmojiComeFromTheBuiltInTableAndTheServersCatalogue` only asserted the built-in table | test stubs an `EmojiCatalogue` page and asserts the custom shortcode |
| MCP8 draft-row-survives-a-send | the draft row is cleared by **two** paths (the success path's `Task { drafts.delete }` *and* the debounced empty-draft write), so mutating either one alone left the test green | mutant now removes both (one defect: "a send leaves its draft behind") and reds `testASuccessfulSendClearsTheDraftRow` |

Mutants added for tests the first pass never redded (all PASS):

| mutant | defect | reds |
|---|---|---|
| MR1 first-connect-refetches | a first connect is treated as a gap | `testAFirstConnectDoesNotRefetchTheWindowAndTheSocketStillDelivers` |
| MR2 late-resync-handler-ignored | the resync handler is captured when the client is built | `testAHandlerInstalledAfterTheConnectionStillReceivesTheReconnect` |
| MW1 pong-does-not-answer-the-ping | a pong is not folded into the heartbeat counter | `testASilentButPingableSocketRefetchesTheOpenWindow` |
| MT7 switch-leaves-the-old-scope | a rail tap moves the destination but not the socket scope | `testTenRapidSwitches…` (+3 more in T32) |

**Exempt (cannot red on this host, by construction, not by luck):** `testTheSFUsAnswerIsApplied…`,
`testAServerReOfferIsAnswered` and `testARemoteCandidateBeforeTheAnswerIsQueued…` are gated behind
`MM_CALLS_PEER_TESTS=1` with `XCTSkip` (a second `RTCPeerConnectionFactory` blocks in CoreAudio on
this host); `testLocalCandidatesAreSentOnlyAfterTheOffer` is a bounded observation window on
loopback ICE gathering; `testStatisticsReadTheEngineWithoutCrashing` is a no-crash smoke test.

## 3. Freeze runs — before red, after green

Method: `scripts/qa-freeze-measure.py` SIGSTOPs the **test host** for that file's largest former wait
budget + 2 s (`scripts/qa-freeze-sweep.py` drives the eleven). A row only counts when a test's own
reported XCTest duration is ≥ the measured stop (`frozen=`), so the log proves where the stop
landed; `-- -collect-test-diagnostics never` keeps a deliberately-red run from spending minutes on a
sysdiagnose.

**Before** (pre-conversion tree `.worktrees/t_eccd49eb`, `docs/t-eccd49eb-freeze-runs-2026-10-27.log`)
→ **after** (this tree, `build/logs/freeze-rows.txt`):

| file (class) | before: freeze, frozen test, verdict | after: freeze, frozen test, verdict |
|---|---|---|
| T34SocketResyncTests | 11.51 s, `testAFirstConnectDoesNotRefetch…` 12.04 s, **red** (`timed out after 10s waiting for the delivered post`) | 12.05 s, `testAResyncMergesTheNewestPage…` 12.05 s, **green** |
| T34SocketStallWatchdogTests | 11.54 s, `testAClientWithoutAVisibilityPredicate…` 11.74 s, **red** (`timed out … authentication challenge`) | 12.15 s, same test 12.27 s, **green** |
| T32TeamSidebarTests | 6.57 s, landing green | 7.05 s, `testASecondAppearanceDoesNotRefetchTheRail` 7.05 s, **green** |
| T31AuthCoordinatorTests | 6.53 s, green | 5.03 s, `testMFAChallengeThenSuccess` 5.04 s, **green** |
| T34ChannelViewRestoreWiringTests | 11.56 s, green | 12.15 s, `testASecondRequestRestoresAgain…` 14.98 s, **green** |
| T35ComposerViewModelTests | 6.51 s, green | 7.01 s, `testAStaleAutocompleteAnswerIsDropped` 7.14 s, **green** |
| T44CCallsEngineTests | 6.58 s, green | 7.15 s, `testAConfirmedUnmuteSurvivesTheNextSnapshot` 7.25 s, **green** |
| T43RSocketLivenessTests | 6.51 s, `testAFinishedPumpWithdrawsLiveness` 6.63 s, **red** | **no landing** |
| T44DSocketBinarySendTests | 6.57 s, `testBinaryFrameReaches…` 6.63 s, **red** | **no landing** |
| T37SocketReactionRoutingTests | 6.56 s, landing green | **no landing** |
| TokenLoggingTests | 6.51 s, landing green | **no landing** |

Seven classes are proven green with the host frozen **for longer than any wait they used to carry**.
Two of the four proven clock-polls (T34R, T34S) are proven green the same way after conversion.

**The other two proven clock-polls (T43R, T44D) and two already-green classes are "no landing", not
"green".** After conversion those classes finish their whole class in ~0.04–0.16 s (six iterations),
shorter than xcodebuild's log-flush lag, so a class-level SIGSTOP cannot be made to land inside a
test: the sweep's first pass never froze them, and a second pass that repeats the class
(`-test-iterations` 900–3000, so the host spends ~30 s inside it) applied a 7 s stop that no test
absorbed — consistent with the stop landing in an inter-test gap, and a sibling worker's test host
was live on a second simulator during that window, which the pid-matching instrument cannot tell
apart from ours. Recorded as unmeasured rather than retried. Their conversion rests on §2 (each of
their converted tests reds under a product mutant) and on the full-target run, both measured; and
the *before* rows show what the clock wait looked like when it existed.

## 4. Whole target

| run | tree | result |
|---|---|---|
| `build/logs/t_00fb623c-full-rebased.log` (18:14) | `ad63fe4` | 1658 run / 8 skipped / 0 failed |
| `build/logs/t_00fb623c-full-3.log` (18:39) | `ad63fe4` + docs/scripts only | 1658 run / 8 skipped / 0 failed |

Two consecutive green full-target runs on the same Swift tree.

## 5. What this card does not prove

- A freeze can still inflate a *test that measures the host by design* (`MMStoreSize` byte
  measurements, the audio/ICE peer tests). Those are not clock polls and are out of scope here.
- The four "no landing" classes above: their awaits rest on mutation evidence, not on a frozen host.
- The exemptions in §2 still cannot fail on this host at all; a host with a working audio device
  (`MM_CALLS_PEER_TESTS=1`) should red the three gated peer tests under a signalling defect.
- MCP8's redundancy: `testASuccessfulSendClearsTheDraftRow` now reds only when *both* clear paths
  are broken. That is the product's real behaviour (defence in depth), but it means the test cannot
  tell you that either single path is gone.
