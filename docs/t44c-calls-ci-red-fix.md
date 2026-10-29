# t_01f65f1d — the T44C red is libwebrtc's `close()` wedged on the engine, and the fix

Acts on `docs/t44cc-calls-ci-red.md` (t_d398053f). That note could not name the blocked frame; it
asked for `-collect-test-diagnostics on-failure` and the `.xcresult` the workflow threw away. Both
landed first (`ci(diag)` on `main`), the next red was captured, and this is what the stack says.

## 1. The frame, measured

Both legs of run **40899137785** (commit 8204735) hung identically, and run **40895827104** (b0a339a,
the push before it) had already done so on catalyst. With the diagnostics flag on, xcodebuild
attaches a spindump of the still-running process to the failing test's result bundle
(`xcresulttool export attachments` → `Spindump_0_*.txt`).

catalyst (`Mattermost[7402]`, 495 samples at 10 ms, 2026-10-29 15:24:36Z):

```
DispatchQueue "com.apple.root.user-initiated-qos.cooperative"(18)   1006 samples
  495   CallsEngine.stop() + 784            (CallsEngine.swift:276,9)
    495   CallsEngine.teardownMediaEngine() + 332 (CallsEngine.swift:670,25)
      495   ??? (WebRTC + 1602992)
        495   ??? (WebRTC + 2665012)
          495   __psynch_cvwait + 8 (libsystem_kernel.dylib)
```

ios-simulator (487 samples, same frames, plus the test frame):

```
  487   T44CCallsEngineTests.testAConfirmedUnmuteSurvivesTheNextSnapshot() (…swift:356)
    487   CallsEngine.stop() + 784            (CallsEngine.swift:276,9)
      487   CallsEngine.teardownMediaEngine() + 332 (CallsEngine.swift:670,25)
        487   ??? (WebRTC + 1602992) → ??? (WebRTC + 2665360) → __psynch_cvwait
```

So `CallsEngine.swift:670` — `peerConnection?.close()` — never returns. libwebrtc's own threads are
not running either: `signaling_thread` and `worker_thread` are both parked in the same condition
variable (`WebRTC + 2665012` / `+2665360`), and `network_thread` idles in `poll`. The engine is an
actor, and the close ran **on its executor**, so the wedge took the whole engine with it:

* `await engine.stop()` never returned (the test's `awaitSignal` waits had already passed);
* the snapshot never became `.ended`;
* `signalling.stop()` never ran;
* the audio session was handed back only because `deactivate()` is called *before* teardown;
* `ICE state: closed` (libwebrtc's callback for the close) was never logged — the signal t_d398053f
  used to place the stop is this same fact, now with the frame that produces it.

That is a **product** defect, not a test artifact: on such a host a user's hang-up leaves the engine
wedged forever in a call the server has already ended, and the app cannot start another call.

## 2. The fix

`teardownMediaEngine()` no longer awaits libwebrtc's blocking half:

* `audioTrack.isEnabled = false` stays on the actor — the ordering `stop()` documents (stop the
  audio unit while its factory is alive) depends on it, and the spindump samples it at zero: the
  wedge is `close()` alone.
* `RTCPeerConnection.close()` (and the factory release that follows it) runs on
  `CallsMediaTeardownQueue`, a **concurrent** queue — so one close that never returns cannot queue
  every later call's teardown behind it — and is not awaited. The engine finishes `stop()` with the
  snapshot `.ended`, the socket stopped and the audio session returned.
* A close still running after 10 s (≈30× the measured 3–14 ms on a healthy host) is **reported**, not
  hidden: `libwebrtc close() has not returned after 10s; the engine is not blocked by it`.
* `CallsMediaTeardownScheduling` is a one-method seam so a test can hold the close open. Production
  default is `CallsMediaTeardownQueue.shared`; no call site changed.

Nothing else moved: no timeout was raised (still `-default-test-execution-time-allowance 300`), the
assertion is untouched (`ordinal > base` and `unmuted == true`), and the test is not skipped.

## 3. The regression, and that it discriminates

`testStopFinishesWhileLibwebrtcCloseIsHeldOpen` starts a real engine, hands the close to a scheduler
that accepts it and never runs it, and requires `stop()` to finish inside 10 s with the socket left,
the socket stopped, the audio session returned and the snapshot `.ended`.

Mutation (the pre-fix shape — `close()` awaited on the actor) run locally on Mac Catalyst:

```
run        : t01f65-mutation
outcome    : finished (xcodebuild rc=65, 31s)
tests      : 1 run, 0 skipped, 1 failed
failed     : testStopFinishesWhileLibwebrtcCloseIsHeldOpen
  T44CCallsEngineTests.swift:489: error: XCTAssertEqual failed: ("0") is not equal to ("1")
  - the blocking close is handed to the teardown scheduler
```

On a host where the close blocks, the same mutation hangs instead and the wait reports after 10 s.

## 4. Verification

| what | result |
|---|---|
| class, Mac Catalyst (pre-fix mutation) | **1 failed** — the mutation above |
| class, Mac Catalyst | **PASS** 19 run / 3 skipped / 0 failed (27 s) |
| class, iPhone 16 Pro / iOS 18.3 | **PASS** 19 run / 3 skipped / 0 failed (38 s) |
| full `MattermostTests`, iOS 18.3 | **PASS** 1777 run / 8 skipped / 0 failed (76 s) |
| CI, both legs | recorded on the card (t_01f65f1d) once the run finishes |

Logs: `build/logs/t01f65-*.log`, results under
`~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa/TestResults/`.

## 5. The scheduler itself (t_16e785f5)

§3 pins the *seam*: `stop()` finishes when the close it hands over never returns. It said nothing
about the object production uses, and the adversarial pass proved it — making
`CallsMediaTeardownQueue.schedule` run `work()` **inline** (the pre-fix shape, in shipped code) left
the whole engine class green (t_5bf7a812, finding 1).

`MattermostTests/T44CCallsMediaTeardownQueueTests.swift` covers the three properties that actually
un-wedge a call, with no clock polling — the deadline is injectable
(`CallsMediaTeardownQueue(warnAfter:)`, 10 s for `shared`) and every event, the report included, is a
`TestSignal` the test awaits:

| test | property | mutation that reds it |
|---|---|---|
| `testScheduleReturnsBeforeTheCloseItWasHandedFinishes` | `schedule` returns while a 2 s close is still running (and the close does run, then finish) | `work()` inline |
| `testOneHeldCloseDoesNotHoldUpTheNextCallsClose` | a close held past the 1 s deadline does not stop the next call's close; the wedge is *reported* once, as `MMCalls: libwebrtc close() has not returned after 1s … the engine is not blocked by it` | `attributes: []` (serial) |

Mutation evidence, iPhone 16 Pro / iOS 18.3, `-only-testing:MattermostTests/T44CCallsMediaTeardownQueueTests`:

```
inline work()          : 2 run / 6 failures
  :45 XCTAssertLessThan failed: ("2.01") is not less than ("1.0")
      - `schedule` returned after 2.01s: the close ran on the caller's thread …
  :91 timed out after 10s waiting for the "has not returned" report for the held close
serial queue           : 2 run / 2 failures
  :87 timed out after 10s waiting for the second call's close while the first one is still held
both mutations reverted: 2 run / 0 failures
```

Green, with the engine class alongside it:

```
iOS      : Executed 2 tests, with 0 failures … / Executed 21 tests, with 3 tests skipped and 0 failures
Catalyst : Executed 2 tests, with 0 failures … / Executed 21 tests, with 3 tests skipped and 0 failures
T44D (blast radius, iOS): 21 run, 0 skipped, 0 failed
```

## 6. What is still open

* **Why** the close wedges on the runner is not proven. The evidence fits the CoreAudio proxy being
  unreachable in the test host (`docs/t44c-calls-engine.md` §6 already records this target wedging in
  CoreAudio, and the runner is a VM with three CPUs and no audio device), but the fix does not depend
  on the answer: whatever wedges it, a hang-up must not wait for `close()`.
* A wedged close leaks one thread and one factory per occurrence. libwebrtc offers no cancellation, so
  the honest options are "don't await it" and "report it"; the report is the 10 s log line above.
* The workflow's failure branch now names the failing test **in the check-run annotation**
  (`::error::test (catalyst): T44CCallsEngineTests.testAConfirmedUnmuteSurvivesTheNextSnapshot
  (exceeded execution time allowance of 5 minutes)`), not only in the step log, and the
  `Failing tests:` / execution-allowance greps still print under it
  (`docs/t44cc-calls-ci-red.md` §7, `docs/releasing.md` stage 1, card `t_f427b00b`). The earlier
  wording of this bullet claimed the annotation itself when only the step log did that; the claim
  was the defect the validator found, and `scripts/test_annotation_selftest.sh` now pins the
  annotation text against real-log fixtures on every push.
