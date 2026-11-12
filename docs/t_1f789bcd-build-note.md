# t_1f789bcd — the catalyst leg's teardown assertion, measured instead of inherited

The release ladder has been stuck at **v0.75.0** because release run **202** (`1c28200`) closed red
on the catalyst leg, in the *Platform-service tests* step, on one assertion:

```
MattermostTests/T46WebFallbackTests.swift:360: error: -[MattermostTests.T46WebFallbackTests
testTwentyFallbacksLeaveNoWebViewAlive] : XCTAssertTrue failed - 1 of 20 fallback webviews are
still alive after teardown (cycles [19]; a leaked webview defeats the memory goal)
```

Job `131241176409`, step timestamp `2026-11-12T14:25:56Z`. The run's own annotation is right that an
assertion is a product statement and must not be re-filed as runner noise — so this card explains
the assertion, then removes its cause. Measured on `MacBook-Pro-6.local`, 2026-11-12 23:00–23:40 HKT,
plus the two CI runs that bracket it.

## 1. What the assertion saw

Not twenty survivors, and not a random one: **exactly one, and always the last cycle**.

```
1 of 20 fallback webviews are still alive after teardown (cycles [19])
```

The model half of the same test — twenty `WebFallbackModel`s — was already zero. So the product had
let go of everything it owns; only the `WKWebView` was still on the heap.

The failing run also tells us how the host behaved. The test took **4.176 s** for its twenty cycles,
and the log is full of WebKit's helper services being refused:

```
WebContent[17008] failed to resolve server port
WebContent[17008] send_message_with_reply_sync(): XPC_ERROR_CONNECTION_INVALID
WebContent process (0x12b17eec0) took 2.607580 seconds to launch
```

## 2. Why it saw it

A `WKWebView` is **not deallocated by its last release**. WebKit holds the view while its
`WebContent` process winds down, and that hand-off completes on the run loop. The test always knew
this — it ends every cycle with `RunLoop.current.run(until: now + 0.01)` for exactly that reason.

But the window it gave the *last* webview was not the window it gave the other nineteen:

| cycle | what happened after its `tearDown()` before the assertion |
| --- | --- |
| 0 … 18 | the remaining cycles: ~19 × 200 ms of creation, teardown and run-loop turns |
| 19 | the loop's final 10 ms spin, then the assertion |

On a host where a webview's hand-off finishes in a few milliseconds (this Mac: measured below at
**0 ms**) the asymmetry is invisible. On the hosted runner, where each cycle cost ~200 ms because
WebKit's helper services are refused and a failed WebContent launch takes seconds, the hand-off for
cycle 19 was still in flight 10 ms after it started. Nineteen of twenty passed for a reason that had
nothing to do with the product, and the twentieth failed for the same reason.

**The flake is load-dependent, and the neighbouring run proves it.** Run **203** (`a12c107`) is the
very next commit on the same code path and its catalyst leg passed — the same test, the same host
class, the same WebKit refusals in the log (70 refusal lines vs 76), in **2.146 s** instead of
4.176 s. Per cycle that is 107 ms instead of 209 ms: half the handing-over time, and 10 ms was
enough. Nothing about the product changed between those two runs; only how fast the runner was.

What is **not** the explanation, checked rather than assumed:

- **not a product leak of the model or the store** — the test's own weak handles for all twenty
  `WebFallbackModel`s were nil at the assertion (the failure names webviews only), and §5 adds a
  store handle that is asserted with no waiting at all;
- **not the loop's earlier cycles** — they had 200 ms and all twenty of them, minus the last, were
  gone;
- **not the CPU count on its own** — 14 spinning processes on this Mac (10 cores) did not move the
  drain off 0 ms, so contention is not the mechanism; WebKit's refused hand-off is.

## 3. The fix

`MattermostTests/T46WebFallbackTests.swift` now measures the two claims it had been merging:

1. **The product's references, synchronously.** Twenty `WebFallbackModel`s *and* twenty
   `WebViewStore`s must be gone the moment each cycle's autorelease pool drains. This part is
   asserted immediately, before any waiting: a model or store that outlives its dismissal is a real
   leak and must never be given a window to hide in.
2. **WebKit's hand-off, asynchronously.** The run loop is drained until the last weak webview handle
   is nil, with a **15 s hang detector** (`drainUntil`, the same contract as
   `TestSignal.wait(until:)`: it returns the moment the condition holds). The measured time is
   printed:

   ```
   T46 teardown: 20 of 20 fallback webviews deallocated; the last teardown needed N ms of run-loop drain
   ```

The claim is unchanged — **twenty of twenty, never one less** — and the drain ends the asymmetry
rather than papering over it: every cycle is now measured with the same explicit rule, instead of the
first nineteen getting whatever the loop happened to leave and the twentieth getting the crumbs.

### Why this is not a relaxed assertion, and not a retry

- **Not relaxed**: the required count is still 20 of 20. Nothing was moved out of scope, no cycle
  was dropped, the budget is not "wait until it looks fine" — it is a bound that the failure hits
  with the same message it always had (`N of 20 … still alive after <elapsed> ms of run-loop drain`).
- **Not a retry**: no product call is repeated. `tearDown()` runs exactly once per cycle, as the
  sheet's `onDisappear` does; the drain only lets the run loop deliver callbacks that were already
  scheduled. A retry would re-run the operation under test and could hide a genuine failure to
  tear down; this cannot, because it never asks the product to tear down twice.
- **Not out-waiting a leak**: the new positive control
  `testTheTeardownProbeStillSeesAWebViewThatIsActuallyRetained` keeps one deliberately retained
  webview, drains for its whole 2 s budget, and requires the probe to still name that one — so an
  instrument that launders leaks fails its own test.

House precedent: `docs/releasing.md` records the same fix shape for the same class of problem
(`T41ProfileTests`, run `42623940630` — a 220 ms sleep that red a leg; it now waits for the
condition with a 10 s hang detector and stops as soon as it lands, "the fix belongs in the test, not
in the split"). This card is that rule applied to the twentieth webview.

## 4. Commands and what they returned

All local runs are Mac Catalyst through `scripts/qa-test.py` (DerivedData outside `~/Documents`,
which would hit TCC).

```
$ python3 scripts/qa-test.py --platform mac --only-testing MattermostTests/T46WebFallbackTests \
    --label t1f-repro-class2
outcome    : finished (xcodebuild rc=0, 16s)
tests      : 34 run, 0 skipped, 0 failed          # the old test passes on this Mac
```

```
# Instrumented copy of the same twenty cycles (temporary, removed before the commit):
$ python3 scripts/qa-test.py --platform mac \
    --only-testing 'MattermostTests/T46WebFallbackTests/testZZDiagnosticLastCycleRetention'
DIAG loop-wall=471.3ms alive=[]
DIAG +=1ms alive=[] models-alive=[]
DIAG +=5ms alive=[] ... +=10ms ... +=20ms ... +=50ms ... +=100ms ... +=250ms ... +=500ms
DIAG +=1000ms alive=[] ... +=2000ms alive=[]
DIAG after-21st alive=[]          # creating one more webview frees nothing that was held
DIAG retained alive=true kept=true # a deliberately retained webview stays alive: not blind
```

```
# The hosted runner's 3-vCPU condition, approximated with 14 spinners on this 10-core Mac:
spinners: 14
tests      : 1 run, 0 skipped, 0 failed
T46 teardown: 20 of 20 fallback webviews deallocated; the last teardown needed 0 ms of run-loop drain
```

```
# The same four classes CI's platform step runs, in the same order:
$ python3 scripts/qa-test.py --platform mac \
    --only-testing MattermostTests/T31HarvestCookieInstallTests \
    --only-testing MattermostTests/T35PasteTests \
    --only-testing MattermostTests/T46WebFallbackTests \
    --only-testing MattermostTests/T56SelectionTests --label t1f-platform
Executed 6 tests,  with 0 failures (0 unexpected) in 0.225
Executed 15 tests, with 0 failures (0 unexpected) in 0.510
Executed 35 tests, with 0 failures (0 unexpected) in 3.231
Executed 14 tests, with 0 failures (0 unexpected) in 0.058
Executed 70 tests, with 0 failures (0 unexpected) in 4.024
T46 teardown: 20 of 20 fallback webviews deallocated; the last teardown needed 0 ms of run-loop drain
** TEST SUCCEEDED **
```

The drain costs a passing run **nothing** here (0 ms), so the change cannot slow the platform pass
down; it only changes what happens when a host is slow enough that WebKit has not finished.

## 5. CI

Pushed as `03e6ee9`; release run **43244408931**, job `131276927558` (`test (catalyst)`). Every step
of that job is green, including the one that closed run 202 red:

```
Unit tests: success
Timing-sensitive tests (own process, required): success
Platform-service tests (reported, not certified here): success
```

and the step's own log carries the measurement this fix added:

```
T46 teardown: 20 of 20 fallback webviews deallocated; the last teardown needed 0 ms of run-loop drain
Test Case '-[MattermostTests.T46WebFallbackTests testTwentyFallbacksLeaveNoWebViewAlive]' passed (1.550 seconds).
Test Case '-[MattermostTests.T46WebFallbackTests testTheTeardownProbeStillSeesAWebViewThatIsActuallyRetained]' passed (2.719 seconds).
** TEST SUCCEEDED **
```

Being precise about what this run does and does not show: it was a **fast** run — twenty cycles in
1.550 s (77 ms/cycle), faster than either of the earlier ones (209 ms/cycle when it failed, 107 ms
when run 203 passed) — so the drain measured **0 ms** and the run would have been green on the old
code too. The fix is therefore not "proven by this green", and this note does not claim that. What
is proven is the mechanism (run 202 vs run 203: same code, same host class, half the per-cycle time,
different verdict) and what the fix changes: the twentieth cycle's hand-off is now measured by the
same explicit rule as the other nineteen, so a run as slow as 202's can no longer fail on an
accident of loop order. The two branches of that rule are covered by tests: the immediate case by
this test (drain returns at 0 ms) and the "never happens" case by the retained control (drain spends
its whole budget and still reports the survivor).

The leg that remains to be confirmed for the release itself is the **simulator** one, which run 203
failed for an unrelated reason — `T31SSOViewModelTests.testClearingTheAuthCookieRemovesOnlyThisServersSessionCookie`
hit the 5-minute execution-time allowance (a hang on a host whose WebKit is refused), not an
assertion. That is a different class of failure from this card's and is not touched here.


## 6. The ladder

Run **43244408931** is green on both legs — `test (catalyst)` and `test (ios-simulator)` — and
`tag and publish` ran:

```
$ git ls-remote --tags origin | grep -E "refs/tags/v0\.7[5-9]"
fc84c3821de62031d4a6317dc78e5e69908f7a66  refs/tags/v0.75.0
03e6ee90606dba5a3fb4c562213cbc5a34d31483  refs/tags/v0.76.0     # this card's commit

$ gh release list --limit 3
v0.76.0  Latest  2026-11-12T15:38:14Z
v0.75.0          2026-11-12T13:34:30Z
v0.74.0          2026-11-12T12:03:38Z
```

`v0.76.0` sits on `03e6ee9`, the commit that carries this fix — the first tag published since
`v0.75.0`, on the content `t_43277d0a` installed locally as `0.76.0 (400)`. The ladder is moving
again.

