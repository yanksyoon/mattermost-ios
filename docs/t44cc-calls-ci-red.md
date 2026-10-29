# t_d398053f — why `T44CCallsEngineTests.testAConfirmedUnmuteSurvivesTheNextSnapshot` reds CI

Diagnosis only: no product code, no test edit, no timeout bump in this card.
Evidence: the two `test-log-*` artifacts of run 40770021762 (both legs) plus 20 further suite logs
pulled with `gh run download` (22 logs in §4), and the local runs in §5.
Verbatim excerpts: `docs/t44cc-calls-ci-red-excerpt.log`.

## 0. Verdict, up front

**The test does not fail an assertion. It hangs for five minutes and xcodebuild's execution
allowance kills it.** On both legs, in every run whose log I pulled (16 of the 20 ios-simulator logs, 2 of 2 catalyst
logs), the run stops immediately after the engine logs
`trickled N local candidate(s)` — the point where `start()` is finishing and the test body is about
to read/wait on the snapshot — and never reaches the `ICE state: closed` line that every passing
instance of the same class logs 3–14 ms later.

Because it is a hang and not a failed predicate, the card's hypotheses 1 (missed/coalesced
publication making `ordinal > base` unreachable) and 3 (a wait stretched past its deadline) cannot
be the cause of *this* failure: both would have produced an assertion report, and the 30 s
`awaitSignal` would have reported at 30 s, not at 300 s. The falsifier is in §3: the same hang
happened on a build of the **pre-1e87032 clock-polling** version of this test, whose every wait was
bounded at 2–5 s.

It is also **not a regression from the 29 commits** in the card's window: the "last green" run the
card anchors on (40671780556 @ a0f4364) never ran the tests at all — the guard skipped both test
legs (`docs_only=true`, `run_tests=false`) and cut the release anyway. See §4.

## 1. What CI actually reports (measured)

Run 40770021762 (5749cc2), ios-simulator leg, artifact `test-log-ios-simulator`:

```
Test Suite 'T44CCallsEngineTests' started at 2026-10-28 21:39:41.167.
Test Case '-[MattermostTests.T44CCallsEngineTests testAConfirmedUnmuteSurvivesTheNextSnapshot]' started.
21:39:41.275228 [MMCalls] media engine created (factory + audio track + peer connection)
21:39:41.561686 [MMCalls] offer sent (1366 chars, 2 candidate line(s) inline), waiting for the SFU's answer
21:39:41.562439 [MMCalls] trickled 1 local candidate(s)
   ... 300 s with no line belonging to this test ...
Test Case '-[MattermostTests.T44CCallsEngineTests testAConfirmedUnmuteSurvivesTheNextSnapshot]'
  exceeded execution time allowance of 5 minutes. The test may have hung; check Xcode's test report
  for additional diagnostics.
```

and, at the end of the same log:

```
Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.
...
Test Case '... testADeltaForAnotherChannelIsNotFolded' passed (0.310 seconds).   <- the class reruns
...
Failing tests:
	T44CCallsEngineTests.testAConfirmedUnmuteSurvivesTheNextSnapshot()

** TEST FAILED **
```

Catalyst leg, same run, `test-log-catalyst`:

```
21:17:37.165  Test Case '... testAConfirmedUnmuteSurvivesTheNextSnapshot]' started.
21:17:37.248  [MMCalls] media engine created (factory + audio track + peer connection)
21:17:37.375  [MMCalls] offer sent (1363 chars, 2 candidate line(s) inline), waiting for the SFU's answer
21:17:37.375  [MMCalls] trickled 2 local candidate(s)
   ... 300 s of WebKit/process noise, nothing from the test ...
21:22:37  exceeded execution time allowance of 5 minutes
```

Every passing instance of the same class, both legs (e.g. the rerun of `testADelta...`, and the
last real green run in §4):

```
[MMCalls] trickled 2 local candidate(s)
[MMCalls] ICE state: closed                       <- +3..14 ms
Test Case '...' passed (0.11–0.34 seconds)
```

Two corrections to the numbers the card quotes from the log:

* `Executed 242 tests, with 3 tests skipped and 0 failures` is the **summary of the second launch**
  (the restart), not of the suite. Across both launches the log contains 1756 `' passed ('` and 8
  `' skipped ('` lines. That is why "0 failures" and "Failing tests: <this test>" coexist in one
  log: the timeout belongs to launch 1, the clean summary to launch 2.
* **There is no assertion line for this test in either leg.** `grep "T44CCallsEngineTests.swift:"`
  over both artifacts returns only two compiler warnings (`NSLock.lock()` from an async context) and
  three `XCTSkipUnless` messages. Nothing else. A failing `XCTAssert` would have printed a
  `file:line: error: -[MattermostTests...] : XCTAssert...` line; none exists.

## 2. Where the process stops (what the log proves)

`ICE state: closed` is emitted by `CallsEngine.iceStateChanged`, which only runs when
`peerConnection.close()` is called inside `teardownMediaEngine()`
(`Mattermost/Core/Calls/CallsEngine.swift:668-676`, reached from `stop()` line 276). It is absent in
every hanging run and present, milliseconds after the same "trickled" line, in every passing run.

So the ordering is fixed:

```
start():  permission → audioSession (fake) → createMediaEngine (real libwebrtc factory)
        → join (fake) → offer → waitForGatheringComplete → sdp → flushPendingLocalCandidates
        → "trickled N local candidate(s)"                     <-- last line in a hanging run
test:     observe() → push(.callState) → awaitSignal(...) → stop()
stop():   leave (fake) → cancel eventTask/offerTask
        → audioTrack?.isEnabled = false            (CallsEngine.swift:274)
        → audioSession.deactivate()                (fake)
        → teardownMediaEngine(): audioTrack?.isEnabled = false  (:669)
                                 peerConnection?.close()        (:670)   <-- never logged
```

The engine is an actor, so any synchronous call that blocks inside it also blocks the following
`observe()`/`currentSnapshot()` hops; both a blocked `stop()` and a wedged actor produce exactly
this signature (no further `[MMCalls]` line, no 30 s `awaitSignal` report, no assertion text). What
the log **rules out** is a hang inside a bounded wait; what it **cannot** distinguish is
`stop()`'s libwebrtc calls from an actor wedged by a delegate callback, or from the whole test task
never being rescheduled at all (a starved cooperative pool would also produce exactly zero further
log lines, because the test could not reach `stop()`/`close()` either).

The library object involved is one the repo has already measured wedging in CoreAudio in this
target: `docs/t44c-calls-engine.md` §6 records that in the xctest app host a second
`RTCPeerConnectionFactory` blocks inside CoreAudio while logging
`HALC_ShellObject::HasProperty: call to the proxy failed, Error: 2684` every 30 s, which is why the
three peer-negotiation tests are gated behind `requirePeerTestHost()`. The other twelve tests in
this class — all the ones that timed out — create one factory each and have no such gate.

## 3. The falsifiers (why the card's hypotheses as written cannot be the cause)

1. **The wait helper is not where it hangs.** Build `f833459a` (run 40595089394, 2026-10-27T22:28Z)
   ran the *pre-1e87032* copy of this file — its `XCTSkipUnless` sits at line 482 and its
   `FakeCallsSignalling.lock` warning at line 608, the markers of the clock-polling version whose
   waits were `await waitUntil(timeout: 2)`. That run hung for 300 s on this test
   (`exceeded execution time allowance of 5 minutes`, same line). A missed publication under those
   waits fails an assertion in 2 s, not a timeout in 300 s.
   → 1e87032 (the `observe`/`ordinal` conversion) did not introduce the hang; it also did not fix
     it. Hypothesis 1 describes a real weakness in the harness but it is not this red.
2. **It is not load.** Every local run in §5 ran on this host at load average 66–85 on 10 cores
   (6.6–8.5× oversubscription) and passed. A CI runner is not more contended than that.
3. **It is not the join-ack/observer ordering the test's own comment worries about.** In the
   hanging runs the `offering without a join ack (timed out …)` line is absent, i.e. the join ack
   *was* folded before `waitForJoinAckThenOffer` polled — the "slow" branch the ordinal comment is
   defensive about never ran.
4. **It is not one platform.** Both legs hang at the same point in the same run (40770021762,
   40696791639 catalyst), and both legs' *passing* runs show the same 100–300 ms timings. Whatever
   this is, it is in the shared libwebrtc/CoreAudio path, not in a per-platform clock.

## 4. When it started — the card's window is wrong

`40671780556` @ `a0f4364` (2026-10-28 10:23Z), quoted in the card as the last green "release" run,
**skipped both test jobs**:

```
guard:  docs_only=true
guard:  run_tests=false
guard:  reason=tip of main; documentation only (1 file(s)), test legs skipped, release still cut
run jobs:  test (${{ matrix.name }}) ... in 0s      (skipped)
artifacts: mattermost-macos-app only                (no test-log-* for this run)
```

So "29 commits sit between a0f4364 and HEAD, none touching Calls" measures nothing: from a0f4364
onwards the test legs were not part of any green run. The last run in which the suite actually ran
and this test passed is **40527106619 @ a96bde02e, 2026-10-27T15:03Z** —
`testAConfirmedUnmuteSurvivesTheNextSnapshot]' passed (0.216 seconds)` on ios-simulator.

Timeline of every suite log I pulled (`gh run download … -n test-log-ios-simulator`, outcome of this
one test; "file" is the test file's line marker in that log: `608` = pre-1e87032, `636` = current):

| run | when (UTC) | commit | outcome | file |
|---|---|---|---|---|
| 40527106619 | 10-27 15:03 | a96bde02e | **passed 0.216 s** | 608 |
| 40530325414 | 10-27 15:22 | 389516d1f | passed (run red elsewhere) | 608 |
| 40595089394 | 10-27 22:28 | f833459ae | **hang 300 s** | 608 |
| 40601488113 | 10-27 23:20 | ad63fe46e | passed (run red: T35Composer) | 636 |
| 40614873581 | 10-28 01:24 | 445a1d969 | hang 300 s | 636 |
| 40615811596 | 10-28 01:34 | 00cd21790 | hang 300 s | 636 |
| 40620351020 | 10-28 02:20 | 3c9b052cc | hang 300 s | 636 |
| 40628006829 | 10-28 03:40 | bbe0aa1b3 | hang 300 s | 636 |
| 40630740078 | 10-28 04:09 | 9c74329a0 | hang 300 s | 636 |
| 40652364151 | 10-28 07:47 | c55e397b4 | passed (run red: a T37 timeout) | 636 |
| 40659209985 | 10-28 08:46 | 3811c57ef | hang 300 s | 636 |
| 40659539305 | 10-28 08:49 | bc937bb50 | hang 300 s | 636 |
| 40670362658 | 10-28 10:13 | 0aeb82acd | hang 300 s | 636 |
| 40708953602 | 10-28 14:44 | ee71f2360 | hang 300 s | 636 |
| 40719380902 | 10-28 15:46 | a14d508b7 | hang 300 s | 636 |
| 40729888345 | 10-28 16:50 | 9c74aa470 | hang 300 s | 636 |
| 40749581610 | 10-28 18:55 | 92a6b5da2 | hang 300 s | 636 |
| 40757397896 | 10-28 19:47 | d038bef2e | hang 300 s | 636 |
| 40757586148 | 10-28 19:48 | 87b719db7 | hang 300 s | 636 |
| 40770021762 (sim) | 10-28 21:12 | 5749cc207 | hang 300 s | 636 |
| 40770021762 (cat) | 10-28 21:12 | 5749cc207 | hang 300 s | 636 |
| 40696791639 (cat) | 10-28 13:28 | cb96dbbfc | hang 300 s | 636 |

Reading: **4 passed / 16 hung across the 20 ios-simulator suite logs, and 2/2 catalyst logs hung.**
The hang predates 1e87032; it has been continuous for the last 10 ios-simulator suite runs (since
40659209985, 08:46Z). It is a *high-rate intermittent* hang, not a clean "one commit broke it",
which is the strongest reason to believe it is an environmental/libwebrtc race rather than branch
logic.

## 5. Local reproduction matrix — **not reproduced**

All runs on this host, `scripts/qa-test.py` (derived data outside `~/Documents`, stall watchdog on),
repo at b0a339a, workspace clean:

| # | condition | command | result |
|---|---|---|---|
| 1 | single test, iPhone 16 Pro / iOS 18.3.1 | `--only-testing MattermostTests/T44CCallsEngineTests/testAConfirmedUnmuteSurvivesTheNextSnapshot` | PASS, 1 run / 0 failed (31 s wall incl. build) |
| 2 | whole class, iOS 18.3.1 | `--only-testing MattermostTests/T44CCallsEngineTests` | PASS, 18 run / 3 skipped / 0 failed (12 s) |
| 3 | whole suite, iOS 18.3.1, CI flags (`-test-timeouts-enabled YES -default-test-execution-time-allowance 300`, ad-hoc signing) | `--only-testing MattermostTests -- -test-timeouts-enabled YES …` | PASS, 1776 run / 8 skipped / 0 failed (49 s) |
| 4 | whole class, **iPhone Air / iOS 26.5** (the CI image's OS), CI flags | `--sim id=C631B0FE-…` | PASS, 18 / 3 skipped / 0 failed (97 s) |
| 5 | whole suite, **iOS 26.5**, CI flags | `--sim id=C631B0FE-… --only-testing MattermostTests` | PASS, 1776 / 8 skipped / 0 failed (97 s) |
| 6 | whole class, **Mac Catalyst** (the second CI leg), CI flags | `--platform mac` | PASS, 18 / 3 skipped / 0 failed (14 s) |
| 7 | 10 iterations of the class on iOS 26.5 (≈10 × 15 factory create/teardown cycles) | `-- -test-iterations 10 …` | PASS, 153 run / 3 skipped / 0 failed (66 s); the named test passed 10/10 |
| 8 | host load | `uptime` during 2–6 | load average 66–85 on 10 cores |
| 9 | `-parallel-testing-enabled YES` (control — the workflow does not use it, and this job's log shows one sequential process) | class, iOS 26.5, `-parallel-testing-enabled YES` | PASS: `Test case 'T44CCallsEngineTests.testAConfirmedUnmuteSurvivesTheNextSnapshot()' passed on 'Clone 1 of iPhone Air …' (0.138 seconds)` |

In the iOS 26.5 suite run the test's own sequence was, verbatim (`build/logs/red-t44c-suite-ios265.log`):

```
10:02:15.176  testAConfirmedUnmuteSurvivesTheNextSnapshot]' started.
10:02:15.176  [MMCalls] media engine created (factory + audio track + peer connection)
10:02:15.288  [MMCalls] offer sent (2386 chars, 10 candidate line(s) inline), waiting for the SFU's answer
10:02:15.288  [MMCalls] trickled 10 local candidate(s)
10:02:15.291  [MMCalls] ICE state: closed
10:02:15.291  testAConfirmedUnmuteSurvivesTheNextSnapshot]' passed (0.131 seconds).
```

One difference worth recording: locally the offer carries **10 inline candidate lines**, on the
runner **2** — fewer network interfaces on a CI VM. Not proven causal, but it is a real difference
in the ICE/network environment of the two hosts.

## 6. What is NOT proven, and the instrumentation that would prove it

I cannot name the blocking call from a log, and I will not guess it. Specifically unproven:

* **which** libwebrtc call blocks (`RTCAudioTrack.isEnabled`, `RTCPeerConnection.close()`, the
  `RTCPeerConnectionFactory` deallocation that owns the audio device module) — the three candidates
  in the window between the last log line and `close()` — **or** whether the test task is simply
  never rescheduled (a starved cooperative pool in a process that has already run ~1500 tests);
* **why** it is the first engine in the process in launch 1 and never in launch 2. The restart
  re-runs the class in a fresh process where the first factory/ADM cycle completes in 0.1–0.3 s;
  the only difference is the ~1500 tests that ran before it in launch 1. That asymmetry fits both
  "the audio device module wedges in a long-lived test host" and "the executor pool is starved by
  what those 1500 tests left behind"; a stack is the only way to tell them apart.
* whether the runner's audio environment is the trigger (a CI macOS VM has no audio output device;
  the repo's own §6 note shows this target wedges in CoreAudio when the audio proxy is unreachable).

The reason none of this is provable from CI today is a gap in the workflow, not in the test: after
the timeout xcodebuild itself prints

```
*** If you believe this error represents a bug, please attach the result bundle at
/Users/runner/work/_temp/dd/Logs/Test/Test-Mattermost-2026.10.28_21-16-17-+0000.xcresult
```

and the workflow uploads only `$RUNNER_TEMP/<leg>.log`. The hang's diagnostics (spindump/stack of
the wedged process) live in that `.xcresult` and are thrown away. For the fix card:

1. **Capture the stack (highest value, CI config only):** add
   `-collect-test-diagnostics on-failure` to the `Unit tests` step and upload
   `$RUNNER_TEMP/dd/Logs/Test/*.xcresult` (plus `.spindump`) as an artifact. The next red then
   names the blocked frame instead of "may have hung". Checked on this host: Xcode 26.6 accepts the
   flag (`xcodebuild -help`: "collects verbose diagnostics (like a sysdiagnose) when encountering a
   failure") and the class run stays green with it (`18 run / 3 skipped / 0 failed`, 43 s), so
   adding it cannot itself break the step.
2. Only then decide between bounding the teardown call, sharing one factory across the class, or
   gating the engine tests the way `requirePeerTestHost()` gates the peer tests. Do not widen
   `awaitSignal` and do not skip the test: per §3 the wait is not where it hangs.
3. If CI cannot be made to capture it, a *local* attempt with the same flag under the frozen-host
   harness (`scripts/qa-freeze-host.sh`) is the fallback, but I could not make this host hang at all
   (§5), so that experiment needs a host without an audio device to be worth running.

## 7. Why the workflow says "TEST SUCCEEDED not found" instead of naming the test

`.github/workflows/release.yml` decides success with `grep -qE "\*\* TEST SUCCEEDED \*\*"`, and its
failure branch prints only its own message — `::error::TEST SUCCEEDED not found in the <leg> log`
— then greps the log with `grep -E "error:|failed|FAIL" | head -40`, a pattern that matches neither
`Failing tests:` (capital-F "Fail", lowercase "ailing") nor `exceeded execution time allowance of 5
minutes`, so the annotation a reader sees on the run is the *absence of a success marker* and the
lines printed under it are unrelated noise ("Failed to delete history…", "failed to connect 127.0.0.1:18443"). The test's name and the real reason are in the step's `tail -60` and in the artifact;
neither reaches the annotation, and nothing in the step says the failure was a *timeout*.

## 8. Artifacts and commands used

* `docs/t44cc-calls-ci-red-excerpt.log` — verbatim excerpts quoted above (both legs, the restart,
  the green comparison, the guard output).
* `gh run view 40770021762 --job … --log` (step log), `gh run download <id> -n
  test-log-ios-simulator|test-log-catalyst` (artifact logs) for the 22 logs in §4.
* `gh api repos/yanksyoon/mattermost-ios/actions/runs/<id>/artifacts` to tell a run that *ran* the
  tests from one that skipped them (a green run with no `test-log-*` artifact never ran them).
* `python3 scripts/qa-test.py …` for every local run in §5; logs in `build/logs/red-t44c-*.log`,
  xcresults under `~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa/TestResults/`.

## 9. Follow-up

The stack this note asked for was captured on the next red (`-collect-test-diagnostics on-failure` +
the uploaded `.xcresult`) and names the blocked frame: `CallsEngine.stop()` → `teardownMediaEngine()`
on the engine's executor → `peerConnection.close()`, 495/495 samples in `__psynch_cvwait`. The fix and
its measurements are in `docs/t44c-calls-ci-red-fix.md` (card t_01f65f1d).
