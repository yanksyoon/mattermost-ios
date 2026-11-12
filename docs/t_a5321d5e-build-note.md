# T31's cookie case: a 5-minute unclassified hang becomes a named measurement (card `t_a5321d5e`)

What the card asks for, and where each half is answered here:

| # | Requirement | Where |
|---|---|---|
| 1 | run this one case alone on a simulator and record the wall time; say plainly whether the runner half can be reproduced here | §2 |
| 2 | read the failing run's log and quote the last line before the allowance fired, and say which `await` it was in | §3 |
| 3 | pick one of the two outcomes *after* the measurement, keep the claim intact | §4, §5 |
| 4 | the simulator gate leg's *Unit tests* step green on a real push, failure explained here | §7 |
| 5 | if the pass membership changes, update `docs/releasing.md`; the classifier self-tests still pass | §6 (no move was made), §8 |

Hosts: this Mac (Apple silicon, macOS 26.3.1, iPhone 16 Pro / `81A7F251-8B31-4945-8783-5A264C14B8D5`)
for the measurement, and the hosted `macos-26` 3-vCPU runner for the failure. Suite run through
`scripts/qa-test.py` (derived data under `~/Library/Developer/Xcode/DerivedData`, not the TCC-protected
checkout).

---

## 1. What was red

Release run **203**, `a12c107`, leg `test (ios-simulator)`, job `131259733278`, step *Unit tests* — the
required gate pass:

```
Test Case '-[MattermostTests.T31SSOViewModelTests testClearingTheAuthCookieRemovesOnlyThisServersSessionCookie]' started.
...
Test Case '…testClearingTheAuthCookieRemovesOnlyThisServersSessionCookie]'
  exceeded execution time allowance of 5 minutes. The test may have hung.
...
Failing tests:
	T31SSOViewModelTests.testClearingTheAuthCookieRemovesOnlyThisServersSessionCookie()
** TEST FAILED **
```

The catalyst leg of the same run was green, and run 202's simulator leg was green, so this is
intermittent — not "the suite is broken". A hang in the gate pass has **no classification**: unlike
the platform-service pass, nothing reports "did not complete on this runner", so the leg simply reds
and the reader gets no name, no call, no excuse.

## 2. Measurement 1 — the case alone, here

`scripts/qa-test.py --platform ios --sim "id=81A7F251-…" --only-testing
MattermostTests/T31SSOViewModelTests/testClearingTheAuthCookieRemovesOnlyThisServersSessionCookie`
(before any change), log `build/logs/ta53/t-a5321d5e-isolated.log`:

```
Test Case '-[…testClearingTheAuthCookieRemovesOnlyThisServersSessionCookie]' started.
2026-11-12 23:52:57.624692+0800 Mattermost[86140:4363955] [default] Failed to resolve host network app id
  to config: bundleID: com.apple.WebKit.Networking instance ID: Optional([…])
Test Case '-[…testClearingTheAuthCookieRemovesOnlyThisServersSessionCookie]' passed (0.385 seconds).
```

* **0.385 s** for the case; **88 s wall** for the invocation, almost all of it the build.
* So on this Mac the case is a third of a second, not a five-minute hang, and the four assertions it
  makes are true here.

**Said plainly: the runner half cannot be reproduced on this host.** The hang needs a simulator whose
WebKit helper services are refused, and this Mac's WebKit services start normally for the same case
(the `Failed to resolve host network app id` line above is the proof that the Networking service was
resolved 38 ms in). Everything below about the runner is read from its log, not re-run here.

## 3. Measurement 2 — the failing log, and what it cannot say

Log: `build/logs/t1f/ci-run-43240373846-ios-simulator-FAILED-hang.log` (the run's
`test-log-ios-simulator` artifact), lines 8081–8083:

```
8081  Test Case '-[MattermostTests.T31SSOViewModelTests testClearingTheAuthCookieRemovesOnlyThisServersSessionCookie]' started.
8082  2026-11-12 14:55:32.771873+0000 Mattermost[7283:27117] [general] Failed to terminate process:
        Error Domain=com.apple.extensionKit.errorDomain Code=18 "(null)" … "No such process found"
8083  Test Case '…testClearingTheAuthCookieRemovesOnlyThisServersSessionCookie]' exceeded execution time allowance of 5 minutes.
```

The last line before the allowance fired is **not** an `await` marker: it is the app failing to
terminate a WebKit extension process that was already gone, at **+86 s** into a 300 s window. It says
a WebKit child process disappeared; it does not say which `await` the test was in.

Two things narrow it down instead:

1. **The gate run's result bundle is not in the artifacts.** The run carries
   `test-xcresult-ios-simulator` (1.6 MB) and `test-xcresult-catalyst` (7.0 MB); the iOS one contains
   only the *timing* and *platform* pass bundles (`Test-Mattermost-2026.11.12_15-07-30` and
   `…_15-10-37`), not the gate bundle the log names
   (`/Users/runner/work/_temp/dd/Logs/Test/Test-Mattermost-2026.11.12_14-47-40-+0000.xcresult`, which
   `-collect-test-diagnostics on-failure` had populated). XCTest's hang sample — the stack that would
   name the frame — was therefore not recoverable. That is a gap in the run, filed as a follow-up
   (see §9), not a guess made here.
2. **The case never got WebKit's Networking service up.** Every WebKit cookie call that starts or
   resolves the app's Networking process logs one line — and both the neighbouring case in the same
   process (`T249bc296WebKitCookieIsolationTests`, 14:53:56.520, **7 ms** in) and this case on this Mac
   (§2, 38 ms in) log it. Between 14:54:06.968 (`T31SSOViewModelTests` suite starts) and the allowance,
   the failing run logs **no such line at all**.

A probe run here (`ZTA5321d5eProbeTests`, deleted after the measurement —
`build/logs/ta53/t-a5321d5e-probe.log`) shows exactly which call that line belongs to, and what each
call costs:

| call | wall time | notes |
|---|---|---|
| `WKWebsiteDataStore(forIdentifier:)` | 13.9 ms | synchronous registry lookup; **no** Networking line |
| `.httpCookieStore` accessor | 0.4 ms | |
| `setCookie(MMAUTHTOKEN)` — **first** | **306.0 ms** | the `Failed to resolve host network app id … com.apple.WebKit.Networking` line appears inside this call |
| `setCookie(MMCSRF)` | 1.2 ms | |
| `WebKitSessionCookieClearing.clearAuthCookie` | 1.9 ms | |
| `WebKitSessionCookieReader.authToken` | 0.5 ms | |
| `allCookies` | 0.8 ms | |
| `removeData` | 8.2 ms | |

So the case has exactly one call that crosses WebKit's service boundary at cold start — the **first
`httpCookieStore.setCookie`**, 306 ms of the case's 341 ms — and that is the call whose progress line
the failing run never printed. **The stall was in the first cookie-store round trip; the log cannot
name the frame inside WebKit** (`setCookie` → `HTTPCookieStore::setCookies` → Networking-process
launch), and this note does not pretend otherwise. Every call in §3's table is now bounded, so the
next occurrence names itself (see §5).

## 4. The choice, after the measurement

The card offers two outcomes. **Chosen: keep the case in the gate pass and bound every WebKit
`await`.** Why not the platform pass:

* the platform pass exists for classes that *need* a service the runner refuses (the four WebKit /
  pasteboard / selection classes). This case usually gets the service: it was green on run 202 and
  green on both legs in the `42617348657` probes. Moving it out would trade a per-run environment
  skip for **permanently uncertified coverage** of a security claim ("sign-out clears only this
  server's `MMAUTHTOKEN`") that runs fine almost everywhere.
* `docs/releasing.md` already states the rule for this family, from `T41ProfileTests` (run
  `42623940630`): *"the fix belongs in the test, not in the split."* This is the same shape — a host
  measurement, not a product property.

The two are not exclusive forever: if the silence ever becomes the norm rather than the exception,
moving the case to the platform pass is the documented escalation, and §5's named skip is the
evidence that would justify it.

## 5. The fix

`MattermostTests/T28TestSupport.swift` gains two helpers next to `TestSignal` (same contract):

* `withWebKitAnswer(_:timeout:_:)` — awaits one WebKit call with a **15 s hang detector** and returns
  `.answered(value)` or `.silent(after:)`. The answer and the detector race once under a lock, so
  exactly one resume is provable; the work runs on the main actor (where WebKit's store API must be
  entered), the detector on a detached task so a busy main actor cannot suppress it. The timeout is a
  **hang detector, not a latency budget**: an answer that arrives is returned at its own cost
  (measured: 0.204 s for a 0.2 s call, §7), and nothing is retried. A suspended XPC call cannot be
  cancelled, so it is left to the host's teardown — only the *wait* is bounded.
* `requireWebKitAnswer(_:timeout:_:)` — the same, for a call the claim depends on: on silence it
  throws `XCTSkip("WebKit did not answer this test host: `<call>` never completed in 15s …")`.

`MattermostTests/T31-AuthTests.swift` now awaits all six WebKit calls through those helpers, naming
each one (`setCookie(MMAUTHTOKEN)`, `setCookie(MMCSRF)`, `clearAuthCookie`, `authToken`,
`allCookies`, `authToken(other server)`); the trailing `removeData` wipe is best-effort, because every
assertion has already run by then.

**Why this is a measurement fix, not a removed assertion:**

* Nothing is deleted, weakened or moved. The case still writes `MMAUTHTOKEN` + `MMCSRF` into a
  per-server store, clears the auth cookie through the production `WebKitSessionCookieClearing`, and
  still asserts all four claims: the token is gone, `MMCSRF` survives, the other server's store was
  never touched, and the reader agrees.
* A **skip** — not a pass — is what a silent host produces. `XCTSkip` is this repo's established
  answer to a missing host service (`CertTrustTests`: no Keychain entitlement on an ad-hoc Catalyst
  host; `T53MediaTransportTests`: no seeded fixture), and it is visibly counted as *skipped*, not
  passed, in the run summary.
* The window is a detector, not a budget: the case takes 0.371 s with the bound in place (§7) versus
  0.385 s without it. The cost of the change on a healthy host is **14 ms of noise**.

What it buys: the worst case for this case drops from **300 s and a red required leg with no
classification** to **15 s and a green leg carrying the exact call that did not answer**, e.g.

```
WebKit did not answer this test host: `httpCookieStore.setCookie(MMAUTHTOKEN)` never completed in 15s,
so this case could not be measured on this run (not a product failure, and not a claim about the product).
```

## 6. Pass membership

**Unchanged.** The case stays in `T31SSOViewModelTests` and in the gate pass, so
`docs/releasing.md`'s pass table and `.github/workflows/release.yml`'s `-skip-testing` list stay as
they are; the rule is recorded in `docs/releasing.md` instead (§, "Three passes"). No change to
`scripts/classify_platform_tests.sh` or `scripts/test_verdict.sh`.

## 7. Controls (what proves the bound works)

`MattermostTests/TA5321d5eBoundedWaitTests.swift` (4 cases, no WebKit — a never-returning closure is
the shape of a stalled XPC `await`):

| case | what it pins | measured |
|---|---|---|
| `testAnAnswerThatArrivesIsReturnedAtItsOwnCostNotAtTheDetector` | a 0.2 s answer with a 15 s window returns at 0.2 s | 0.204 s |
| `testACallThatNeverComesBackIsReportedAfterTheWindowInsteadOfHanging` | silence returns `.silent(after: 1.0)` after 1 s, does not hang | 1.012 s |
| `testARequiredCallThatNeverAnswersSkipsTheCaseAndNamesTheCall` | a silent required call throws `XCTSkip` whose message names the call | 1.047 s |
| `testARequiredCallThatAnswersIsNotSkipped` | the skip cannot become the normal path | 0.002 s |

Run on the iPhone 16 Pro simulator together with the T31 case
(`build/logs/ta53/t-a5321d5e-bounded.log`):

```
Test Case '…T31SSOViewModelTests testClearingTheAuthCookieRemovesOnlyThisServersSessionCookie]' passed (0.371 seconds).
Test Case '…TA5321d5eBoundedWaitTests testACallThatNeverComesBackIsReportedAfterTheWindowInsteadOfHanging]' passed (1.012 seconds).
Test Case '…TA5321d5eBoundedWaitTests testAnAnswerThatArrivesIsReturnedAtItsOwnCostNotAtTheDetector]' passed (0.204 seconds).
Test Case '…TA5321d5eBoundedWaitTests testARequiredCallThatAnswersIsNotSkipped]' passed (0.002 seconds).
Test Case '…TA5321d5eBoundedWaitTests testARequiredCallThatNeverAnswersSkipsTheCaseAndNamesTheCall]' passed (1.047 seconds).
	 Executed 5 tests, with 0 failures (0 unexpected) in 2.635 (2.640) seconds
** TEST SUCCEEDED **
```

The gate scripts' self-tests, unchanged but re-run here: `classify_platform_tests.sh --self-test`
→ `PASS (4 checks)`; `test_annotation_selftest.sh` → `PASS (27 checks)`.

The whole unit scope with the change, on the same simulator
(`build/logs/ta53/t-a5321d5e-fullsuite.log`): **2641 tests run, 14 skipped, 0 failed, 232 s**
(`scripts/qa-test.py --only-testing MattermostTests`; the 14 skips are the suite's pre-existing
fixture/entitlement skips, none of them this case).

## 8. Files

| File | Change |
|---|---|
| `MattermostTests/T28TestSupport.swift` | `BoundedAnswer`, `withWebKitAnswer`, `requireWebKitAnswer` (hang detector, skip with the call named) |
| `MattermostTests/T31-AuthTests.swift` | the cookie case awaits every WebKit call through them; claim and assertions unchanged |
| `MattermostTests/TA5321d5eBoundedWaitTests.swift` | 4 controls for the bound (fast answer, silence, skip, skip-negative) |
| `docs/releasing.md` | the rule, next to the `T41ProfileTests` paragraph: the case stays in the gate, its WebKit waits are bounded, a silent host skips with the call named |

## 9. Follow-ups, not done here

* **The gate pass's `.xcresult` is not in the run's artifacts.** The upload step globs
  `${{ runner.temp }}/dd/Logs/Test/*.xcresult`, and only the timing- and platform-pass bundles
  survived to upload — so a gate hang today cannot be diagnosed from its hang sample. Filed as a card
  rather than folded in here: it changes `.github/workflows/release.yml` on every push and deserves
  its own run.
* The product call the case exercises (`WebKitSessionCookieClearing.clearAuthCookie`) is an unbounded
  `await` in the app too. It is not on the sign-out's critical path (sign-out proceeds either way) and
  the caller is async, so it is not a UI hang; unchanged here.

## 10. The real push

This note lands with the fix; the run the push triggers is the evidence for the last requirement
(the simulator leg's *Unit tests* step green on a real push). Its run id and step results are added
in the follow-up docs commit that records them — this note does not claim a green leg before the leg
has run.
