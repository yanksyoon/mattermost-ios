# t_559943f3 — the T44C teardown-queue red is the test charging the host's thread-wake latency

CI red on main `0ca64f8`: release run **40918129603**, job `test (ios-simulator)`
**123603869063**, failed 2026-10-29T17:31:27Z, `xcodebuild exit: 65`. `tag and publish` and
`package Mattermost.app` were skipped, so nothing shipped from that commit.

The annotation (t_f427b00b's fix, working) named it:

```
test (ios-simulator): T44CCallsMediaTeardownQueueTests.testOneHeldCloseDoesNotHoldUpTheNextCallsClose
```

## 1. What the job log actually says

Artifact `test-log-ios-simulator` of that run, lines 8531–8536, plus the two `MMCalls` lines the
test's log sink also forwards to the system log (`ios-simulator.log:8533-8534`):

```
17:27:27.012  Test Suite 'T44CCallsMediaTeardownQueueTests' started
17:27:27.012  Test Case '...testOneHeldCloseDoesNotHoldUpTheNextCallsClose]' started
17:27:41.771  [MMCalls] libwebrtc close() has not returned after 1s; ...
17:27:58.988  [MMCalls] libwebrtc close took 18.3s (off the engine; the call already ended)
              T44CCallsMediaTeardownQueueTests.swift:95: error: ... XCTAssertTrue failed -
              timed out after 10s waiting for the held close to finish once released
              Test Case '...testOneHeldCloseDoesNotHoldUpTheNextCallsClose]' failed (69.142 s)
```

Read those four timestamps instead of the summary and the picture is arithmetic:

* `close took 18.3s` is `Date()` at the end of the work minus `Date()` when `schedule` was called,
  so `schedule(first)` ran at **17:27:40.69** — **13.68 s after the case started**. The test body
  does no work between those two points, so the test *thread* was not scheduled for ~14 s.
* the 1 s deadline report landed at **41.77**, i.e. 1.08 s after `schedule` — the timer was fine.
  The test awaited it, then called `release.signal()` at ~**41.8**.
* the held close came back at **58.99** — **17.2 s after the release**. The await guarding it had a
  **10 s** detector, so it red at ~51.8 and the close then finished anyway, 7 s later.

Every other suite in the same leg shows the same host state: `T44CCallsEventTests` took 77.221 s and
`testSignalAnswerIsDoubleEncodedJSON` — a decode assertion — "passed (74.095 seconds)". The leg ran
1779 tests in 557.661 s where the green run 40906839823 (`627f842`) did the same leg in 86.247 s:
**6.5× slower**. The catalyst leg of the same run was green on this class
(1779 tests, 9 skipped, 0 failures, 89.520 s).

## 2. Product or test?

Product code is not implicated. `3b42099`'s only `CallsEngine.swift` change is making the report
deadline injectable (`static let warnAfter` → `let warnAfter` + `init(warnAfter:)`, `shared`
unchanged); the queue is byte-for-byte the same `attributes: .concurrent` dispatch queue. The two
`MMCalls` lines above are the production behaviour being *correct* on that host: the close was off the
engine (the engine was not blocked), and the wedge was reported once at its deadline.

The failure is the **test**, in two ways:

1. **It charged the host's wake latency to the queue.** `release.signal()` → the block returning is a
   dispatch thread wake. On a healthy host that is microseconds; on this one it was 17.2 s, and the
   await charging for it had a 10 s bound. Nothing about the queue can be concluded from that number.
2. **The hold could end by itself.** It was `release.wait(timeout: .now() + 15)`, and the work came
   back **18.3 s** after `schedule` — past its own bound. From that moment the test could no longer
   say whether the close had been ended by the release it sent or by the hold's own timeout, which is
   exactly the distinction "one held close does not hold up the next one" rests on.

## 3. The change (test-only; no product file touched)

`MattermostTests/T44CCallsMediaTeardownQueueTests.swift`:

* **The hold has no timeout.** `release.wait()`, released by the test. A `defer` releases it on every
  path out of the case, and a 120 s watchdog `Task` releases it if the *test thread itself* is stuck
  inside the hold — which is precisely the inline-`work()` mutation this test exists to catch. That
  keeps t_16e785f5's property that the mutation reports **red**, not a hung suite.
* **A new ordering assertion** right after the second close runs:
  `XCTAssertTrue(firstFinished.recorded.isEmpty, "the second close ran while the first one was still
  held")`. The release is still ahead of the test at that point, so "while the first one is still
  held" is a fact by construction rather than an inference from the host having been quick. The old
  test never proved this — it only assumed it.
* **Detectors become hang detectors, as `TestSignal` documents them.** The three ordering/report
  awaits use its 30 s default; the post-release await, the one place a *thread wake* is the signal,
  uses 60 s because that wake was measured at 17.2 s on CI. A wedge never delivers the signal at all,
  so both still red a real regression. **No CI timeout was widened**: the job timeout and
  `-default-test-execution-time-allowance 300` are untouched, and the class runs in ~1 s on a healthy
  host.
* The report assertions (`exactly once`, `after 1s`, `the engine is not blocked by it`) and both
  cases are unchanged in what they require.

## 4. Verification on this host (`iPhone Air`, `iOS-26-5`, UDID `C631B0FE-…`)

| check | run | result |
| --- | --- | --- |
| fixed class, 5 iterations (`-test-iterations 5`) | `t559-final-5x` | **10 run, 0 skipped, 0 failed**, 76 s |
| mutation: serial queue (`attributes: []`) | `t559-mut-serial` | **red, 1 failed / 2**, 30.060 s: `:115 timed out after 30s waiting for the second call's close while the first one is still held` |
| mutation: inline `schedule` (calls `work()`) | `t559-mut-inline` | **red, 7 failures / 2**, class 152.228 s, no hang: `:121 the second close ran while the first one was still held`, plus the missing report and `testScheduleReturns…`'s 2.00 s return |
| fixed class + `T44CCallsEngineTests` | `t559-classes` | **21 run, 3 skipped, 0 failed**, 78 s |
| whole `MattermostTests` target | `t559-units-full` | **1788 run, 8 skipped, 0 failed**, 216 s |

Both mutations are the two t_16e785f5 proved; they still red, and the inline one now reds on the new
ordering assertion (the old bound-comment promised a red there and a *hang* would have been worse than
either).

**What was tried and did not reproduce:** the old test, run with 20 CPU burners on top of a host
already at load average ~500 (`t559-old-load`) — **PASS**, 2 run, 0 failed. CPU oversubscription is
not the mechanism; a 17 s dispatch *wake* stall is, and this host did not produce one in that
window. The mechanism above is therefore established from the CI job log's own timestamps, not from
a local red.

## 5. Limits

* Three 30 s detectors and one 60 s detector mean a *legitimately* woken close gets 60 s to come back.
  A host stalling longer than that can still red this test. Nothing here can distinguish "the queue
  wedged" from "the host stopped scheduling us" beyond a bound that is far outside every observed
  stall; 300 s of allowance is what the leg actually has, and this class uses ~1 s of it.
* The watchdog is a liveness escape hatch, not a correctness bound: it fires at 120 s, beyond every
  detector, and can only ever release a hold the test has already failed to reason about.
