# Four more gate-pass classes: every real-store `await` is bounded and named (card `t_e687bad5`)

What the card asks for, and where each half is answered here:

| # | Requirement | Where |
|---|---|---|
| 1 | every real-store `await` in the four files is bounded **and named**; the assertion set is byte-for-byte the same claims | §1, §2, §4 |
| 2 | a positive control proves the skip path for at least one of the newly bounded files | §5 |
| 3 | local full-suite run on the iPhone 16 Pro simulator green | §6 — **blocked on this host**, see §7 for the measurement and the exact reason; the required simulator evidence is the CI leg in §10 |
| 4 | the simulator leg's *Unit tests* step green on a real push | §10 |
| 5 | build note with the per-file call names and the measured times | this file |

Host: this Mac, now **macOS 27.2.1 (26B131)**, Xcode 26.6 (17F113), 10 cores. Checkout
`/Users/yangsooyoon/worktrees/t_e687bad5` (a worktree of `origin/main` at `7f5ad2b`), suite run through
`scripts/qa-test.py`, derived data under `~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa`.

---

## 1. What was unbounded, per file

Line numbers are the file at `7f5ad2b` (before this change). "Call name" is what the case now reports
in a skip, i.e. what a reader of a silent run sees in the log.

### `MattermostTests/T249bc296WebKitCookieIsolationTests.swift` (4 cases, nonisolated)

| before | call | now |
|---|---|---|
| `seed(_:in:)` L49 — `WebSessionCookieInstaller(dataStore:).install(cookies)` (its `setCookie`/`allCookies` rounds) | `WebSessionCookieInstaller.install(MMUSERID,MMCSRF,MMAUTHTOKEN)` | `requireWebKitAnswer` |
| `names(in:)` L55 — `store.httpCookieStore.allCookies()` | `httpCookieStore.allCookies` | `requireWebKitAnswer` |
| `wipe(_:)` L61 — `removeData(ofTypes:modifiedSince:)` | `removeData(allWebsiteDataTypes)` | `withWebKitAnswer`, result ignored |
| L79, L97 — `WebKitCookieSessionProvider().sessionData(for:)` | `WebKitCookieSessionProvider.sessionData` | `requireWebKitAnswer` |
| L120 — `WebKitSessionCookieClearing().clearAuthCookie(for:serverID:)` | `WebKitSessionCookieClearing.clearAuthCookie` | `requireWebKitAnswer` |
| L122, L144 — `WebKitSessionCookieReader(serverID:).authToken(for:)` | `WebKitSessionCookieReader.authToken` | `requireWebKitAnswer` |

`WKWebsiteDataStore(forIdentifier:)` (`makeStore`) is **not** wrapped: it is a synchronous registry
lookup (13.9 ms, probe in `docs/t_a5321d5e-build-note.md` §3), not an XPC round trip, so there is no
wait to bound. The `WebKitSessionCookieReader` construction stays in each case body for the same class
of reason — see §3.

### `MattermostTests/AuthSessionTests.swift` (2 cases, `@MainActor`)

| before | call | now |
|---|---|---|
| L311 — `storeA.httpCookieStore.setCookie(cookie)` | `httpCookieStore.setCookie(MMAUTHTOKEN)` | `requireWebKitAnswer` |
| L313 — `WebKitSessionCookieReader(serverID: serverA).authToken` | `WebKitSessionCookieReader.authToken(serverA)` | `requireWebKitAnswer` |
| L317 — same for `serverB` | `WebKitSessionCookieReader.authToken(serverB)` | `requireWebKitAnswer` |
| L320 — `WebKitSessionCookieReader(dataStore: .default()).authToken` | `WebKitSessionCookieReader.authToken(.default store)` | `requireWebKitAnswer` |
| L325 — `storeA.removeData(...)` | `removeData(allWebsiteDataTypes)` | `withWebKitAnswer`, ignored |
| L339 — `store.httpCookieStore.setCookie(cookie)` | `httpCookieStore.setCookie(MMAUTHTOKEN)` | `requireWebKitAnswer` |
| L341 — `auth.adoptWebSession(using: WebKitSessionCookieReader(serverID:))` (reads the store inside) | `AuthSession.adoptWebSession(WebKitSessionCookieReader)` | `requireWebKitAnswerOrThrow` |
| L348 — `store.removeData(...)` | `removeData(allWebsiteDataTypes)` | `withWebKitAnswer`, ignored |

### `MattermostTests/T31WebSessionHarvestTests.swift` (1 case, `@MainActor`)

| before | call | now |
|---|---|---|
| L299 — `dataStore.httpCookieStore.setCookie(auth)` | `httpCookieStore.setCookie(MMAUTHTOKEN)` | `requireWebKitAnswer` |
| L302 — `removeData` inside the `defer`'s `Task` | `removeData(allWebsiteDataTypes)` | `withWebKitAnswer`, ignored |
| L324 — `coordinator.restore(seeded)` (its production reader reads the store) | `AuthCoordinator.restore(WebKitSessionCookieReader)` | `requireWebKitAnswerOrThrow` |

### `MattermostTests/ViewStoreTests.swift` (1 case, `@MainActor`)

| before | call | now |
|---|---|---|
| L119 — `workStore.setCookie(cookie)` | `httpCookieStore.setCookie(MMAUTHTOKEN)` | `requireWebKitAnswer` |
| L121 — `cookies(of: workStore)` (`getAllCookies` continuation) | `httpCookieStore.getAllCookies(work)` | `requireWebKitAnswer` |
| L122 — `cookies(of: personalStore)` | `httpCookieStore.getAllCookies(personal)` | `requireWebKitAnswer` |

`T46WebFallbackTests` and `T31HarvestCookieInstallTests` are untouched, as the card says: they are in
the platform pass, where a hang is already reported by name.

Two calls that look like real-store calls and are deliberately **not** wrapped, because they never
touch one: `AuthSessionTests`' `adoptWebSession(using: StubCookieReader(…))` (L261, L274, L288) and
`T31WebSessionHarvestTests`' `coordinator.restore(server)` cases that build the coordinator with a
`RecordingCookieReader` (L140, L196, L214, L231, L257, L275). Those readers are in-memory fakes
(`SessionCookieReading`), so there is no XPC boundary and no wait to bound; wrapping them would only
add a detector around a function that cannot stall.

## 2. The fix

Every call above is awaited through the helper `t_a5321d5e` added to `MattermostTests/T28TestSupport.swift`
(`withWebKitAnswer`, `requireWebKitAnswer`, 15 s hang detector, `XCTSkip` naming the call). Two
additions were needed to keep the claims intact:

* **`requireWebKitAnswerOrThrow`** — `AuthSession.adoptWebSession` and `AuthCoordinator.restore` read
  the real store *and then* make a request, so they can throw after WebKit answered
  (`MMError.unauthorized`, `MMError.notSignedIn`). `requireWebKitAnswer`'s closure is non-throwing, so
  at those two call sites the only options were "bound the wait and lose the error" or "keep the error
  and hang for 300 s". The sibling runs the work into a `Result`, rethrows the call's own error
  unchanged, and skips only when the call never came back. Nothing about what the case then asserts
  changed: `try` in the test body fails the case exactly as before.
* **One wording for the skip** — the message moved into `private func webKitSilenceSkip(_:after:)`, so
  the plain and throwing requirements cannot drift. Its closing reference now names the section that
  exists (`docs/releasing.md`, "Three passes, and why they are three"; the previous wording pointed at
  a heading titled "WebKit in the test host", which is not in that document). The sentence a CI
  annotation or a log reader greps for — `WebKit did not answer this test host: \`<call>\` never
  completed in 15s` — is unchanged.

Cleanup wipes are `withWebKitAnswer` with the result ignored, per the card: every assertion has already
run by then, so a host that will not answer the wipe must not turn the case red after the fact.

## 3. Why the wrapper does not move the subject

`T249bc296WebKitCookieIsolationTests` may not be `@MainActor` ("the caller's executor is the subject"),
so it is fair to ask whether wrapping its calls in the `@MainActor` helper defeats the class. It does
not, and the reason was measured rather than assumed:

* The methods the wrapper awaits are **nonisolated** async functions (`sessionData(for:)`,
  `clearAuthCookie(for:serverID:)`, `authToken(for:)`, `install(_:)`). A nonisolated async function
  does not inherit the calling actor's executor (SE-0338), so it still runs on the cooperative pool
  even when awaited from the main actor. Probe on this host (`swiftc -swift-version 5`, `@main`):

  ```
  caller on main: true
  callee from MainActor context, on main: false
  callee inside Task{@MainActor}, on main: false
  ```

  So the production body is entered from the same executor it was entered from before; the wrapper
  only decides how long the case waits for it.
* What *would* have moved the subject is a synchronous WebKit call inside the wrapped closure. Two
  exist, and both stay outside it: `WKWebsiteDataStore(forIdentifier:)` (a registry lookup) and the
  `WebKitSessionCookieReader` initializer — the exact call site t_249bc296's crash was reproduced at
  ("store resolution must not happen in a nonisolated initializer"). Each case builds its reader on
  its own executor, then wraps only the `await` after it, which is also how `T31-AuthTests` does it.

## 4. The assertion set is byte-for-byte the same

* `git diff` between `7f5ad2b` and `aed87f4` removes **no** `XCTAssert*` line in any of the four files
  (`git diff -U0 … | grep '^-.*XCTAssert'` → empty).
* `T249bc296` was rewritten in place (its helpers gained `throws`); the assertion lines extracted from
  the old and new file (`grep -E 'XCTAssert' | diff`) are identical: `ASSERTIONS IDENTICAL`.
* No case was added to or removed from any pass; §8.

## 5. Controls

`MattermostTests/TA5321d5eBoundedWaitTests.swift` keeps its four original cases and gains three for the
throwing requirement, driven by the **exact call names the newly bounded files use**:

| case | what it pins | measured (Catalyst) |
|---|---|---|
| `testAnAnswerThatArrivesIsReturnedAtItsOwnCostNotAtTheDetector` (existing) | a 0.2 s answer with a 15 s window returns at 0.2 s | 0.241 s |
| `testACallThatNeverComesBackIsReportedAfterTheWindowInsteadOfHanging` (existing) | silence is `.silent(after:)`, not a hang | 1.050 s |
| `testARequiredCallThatNeverAnswersSkipsTheCaseAndNamesTheCall` (existing) | silent required call → `XCTSkip` naming the call | 1.002 s |
| `testARequiredCallThatAnswersIsNotSkipped` (existing) | the skip cannot become the normal path | 0.004 s |
| `testAThrowingCallThatNeverAnswersSkipsTheCaseAndNamesTheCall` (**new**) | `requireWebKitAnswerOrThrow` skips naming `AuthSession.adoptWebSession(WebKitSessionCookieReader)` — a call name from a newly bounded file — and really waits its window | 1.052 s |
| `testAThrowingCallThatAnswersPropagatesItsOwnError` (**new**) | an answered call's own error (`MMError.unauthorized`) reaches the test; it is never converted into a skip | 0.002 s |
| `testAThrowingCallThatAnswersReturnsItsValue` (**new**) | an answered value returns at its own cost | 0.002 s |

Reuse is stated rather than duplicated: the plain `requireWebKitAnswer` skip path (which the other
three newly bounded files' calls use) is the existing `testARequiredCallThatNeverAnswersSkipsTheCaseAndNamesTheCall`
control — same function, same `webKitSilenceSkip` wording, and the data race/window machinery is shared.
The only new code path in this diff is the throwing sibling, and it has its own three controls above.

## 6. Measurements

Five classes together, on this host:

```
scripts/qa-test.py --platform mac --label te68-mac-classes \
  --only-testing MattermostTests/T249bc296WebKitCookieIsolationTests \
  --only-testing MattermostTests/AuthSessionTests \
  --only-testing MattermostTests/T31WebSessionHarvestTests \
  --only-testing MattermostTests/ViewStoreTests \
  --only-testing MattermostTests/TA5321d5eBoundedWaitTests
→ 53 tests run, 0 skipped, 0 failed, 4.543 s   (build/logs/te68-mac-classes.log)
```

`0 skipped` is the point: on a host whose WebKit answers, the detector never fires and every assertion
above ran. Per case (from the same log):

| case | time |
|---|---|
| `ViewStoreTests.testAuthCookiesDoNotLeakBetweenServers` | 0.075 s |
| `T31WebSessionHarvestTests.testTheProductionReaderFindsTheSessionInTheServersOwnWebsiteDataStore` | 0.010 s |
| `T249bc296…testTheDiagnosticsSessionProviderReadsTheServersStoreFromANonisolatedCaller` | 0.016 s |
| `T249bc296…testTheDiagnosticsSessionProviderReportsAbsentCookiesFromANonisolatedCaller` | 0.014 s |
| `T249bc296…testSignOutCookieClearingRemovesOnlyTheAuthCookieFromANonisolatedCaller` | 0.144 s |
| `T249bc296…testTheSessionCookieReaderIsConstructibleAndUsableFromANonisolatedCaller` | 0.012 s |
| `AuthSessionTests.testProductionReaderReadsTheServersOwnStoreAndNoOther` | 0.191 s |
| `AuthSessionTests.testAdoptingAWebSessionEndToEndThroughThePerServerCookieStore` | 0.229 s |

The bound costs nothing worth naming: the heaviest of these is 0.229 s against a 15 s window, and the
window is a hang detector, not a latency budget (the case that answers is returned as soon as it
answers — `testAnAnswerThatArrivesIsReturnedAtItsOwnCostNotAtTheDetector` above).

Full local suite, same host, same command shape as the gate
(`scripts/qa-test.py --platform mac --only-testing MattermostTests`, log
`build/logs/te68-mac-full.log`): **2646 tests run, 15 skipped, 0 failed, 104 s, TEST SUCCEEDED**. The
15 skips are the suite's pre-existing fixture/entitlement skips (`CertTrustTests`,
`MentionPollerTests`, `SelfSignedTrustTests`, `T44CCallsEngineTests`, `T53MediaTransportTests`,
`T88LiveSlashTests`) plus `TGateHangFixtureTests`, which is env-gated and never armed on a local run —
**none of them is one of this card's four classes**, i.e. every real-store case above actually
asserted its claim on this run.

That is the Catalyst leg, because the simulator leg cannot run on this host — §7. The card's required
simulator evidence is the CI leg in §10.

## 7. Blocked: this host cannot pair a simulator test runner any more

The card's local half asks for `scripts/qa-test.py --only-testing MattermostTests` on the iPhone 16 Pro
simulator (`81A7F251-8B31-4945-8783-5A264C14B8D5`, iOS 18.3.1). **It cannot run on this host right
now**, and this is a host measurement, not a test failure:

```
$ xcodebuild test … -destination platform=iOS Simulator,id=81A7F251-… 
Mattermost (14184) encountered an error (The test runner hung before establishing connection.)
** TEST FAILED **                          (rc=65 after 391 s; build was green)
```

Before that line, three of these appear per attempt:

```
iOSSimulator: 📱<DVTiPhoneSimulator … iPhone 16 Pro, 18.3.1 (22D8075)>
  unable to connect to "com.apple.instruments.deviceservice.lockdown"
  (DVTiPhoneSimulatorErrorDomain Code=-1 "DTServiceHubClient failed to bless service hub for
   simulator iPhone 16 Pro (81A7F251-…)" …)
```

The two facts that explain it:

```
$ /usr/sbin/DevToolsSecurity -status
Developer mode is currently disabled.
$ xcodebuild -checkFirstLaunchStatus ; echo $?
69
```

This Mac was upgraded to **macOS 27.2.1** and rebooted at ~01:35 (before this card started; the
`t_a5321d5e` measurements above were taken on the previous OS). The upgrade reset the host's developer
security mode, so `xcodebuild`'s `DTServiceHub` can no longer bless the simulator's test service and no
test runner can pair. Enabling it needs root, which this headless worker does not have —
`xcodebuild -runFirstLaunch` hangs waiting for an authorization prompt when run without a TTY (300 s,
killed), and `sudo` requires a password.

**To unblock (one command, any human shell on this Mac):**

```
sudo DevToolsSecurity -enable && sudo xcodebuild -runFirstLaunch
```

What was ruled out before blaming the host:

| attempt | result |
|---|---|
| reboot the simulator (`simctl shutdown` → `boot` → `bootstatus`) | same error |
| a **new** iPhone 16 Pro device on the same iOS 18.3.1 runtime (`9C594D37-…`) | same error |
| an iOS **26.0.1** iPhone 17 (`F0D6CDC1-…`) — i.e. a runtime matching the new host | same error |
| Mac Catalyst, same derived data, same project (`--platform mac`) | **works**: 53/53 then the full suite, §6/§10 |

So it is not the classes, the code, the runtime, or the device state: it is the host's developer mode.
The required simulator evidence for this card is therefore taken from CI in §10, where the leg runs on a
hosted `macos-26` runner with its own developer mode intact — and where the stall this card is about
actually happens.

## 8. Pass membership

**Unchanged.** No class moved between the gate, timing and platform passes,
`.github/workflows/release.yml`'s `-skip-testing` list is untouched, and
`scripts/classify_platform_tests.sh` / `scripts/test_verdict.sh` are untouched. The rule stays
`docs/releasing.md` "Three passes, and why they are three": *the fix belongs in the test, not in the
split*.

## 9. Files

| File | Change |
|---|---|
| `MattermostTests/T28TestSupport.swift` | `requireWebKitAnswerOrThrow` (new); skip wording in one private `webKitSilenceSkip` |
| `MattermostTests/T249bc296WebKitCookieIsolationTests.swift` | all real-store awaits bounded and named; helpers gained `throws`; assertions identical |
| `MattermostTests/AuthSessionTests.swift` | both store cases bounded; `adoptWebSession` through the throwing requirement |
| `MattermostTests/T31WebSessionHarvestTests.swift` | seed, `restore` and the deferred wipe bounded |
| `MattermostTests/ViewStoreTests.swift` | `setCookie` and both `getAllCookies` bounded |
| `MattermostTests/TA5321d5eBoundedWaitTests.swift` | 3 controls for the throwing requirement |
| `docs/releasing.md` | one paragraph: the same bound now covers these four classes |
| `docs/t_e687bad5-build-note.md` | this file |

## 10. The real push

Commit **`aed87f4`** (`test(t_e687bad5): …`) pushed straight to `origin/main`; run
**`43304994377`**, tagged **`v0.76.6`** on that commit.

| leg | job | steps |
|---|---|---|
| `test (ios-simulator)` | `131485925018` | *Toolchain* ✓, *Prove the gate scripts* ✓, *Resolve packages* ✓, **Unit tests ✓** (21:01:39 → 21:30:58), *Timing-sensitive tests* ✓, *Platform-service tests* ✓, *Upload log* ✓, *Upload test diagnostics* ✓ |
| `test (catalyst)` | `131485925073` | green (*Unit tests* 20:56:28 → 21:02:32) |
| `parity record (report mode)` | `131485793017` | green |
| `tag and publish` | — | success, `v0.76.6` |

Gate pass, from the run's `ios-simulator.log` artifact (line 12521 / 12536):

```
   Executed 2573 tests, with 15 tests skipped and 0 failures (0 unexpected) in 695.330 (1056.300) seconds
** TEST SUCCEEDED **
```

**All eight real-store cases passed on the runner** — none of the four classes skipped. Their times
there, against the 15 s window:

| case | runner | here (§6) |
|---|---|---|
| `ViewStoreTests.testAuthCookiesDoNotLeakBetweenServers` | **4.092 s** | 0.075 s |
| `T31WebSessionHarvestTests.testTheProductionReaderFindsTheSessionInTheServersOwnWebsiteDataStore` | **13.991 s** | 0.010 s |
| `AuthSessionTests.testProductionReaderReadsTheServersOwnStoreAndNoOther` | 0.760 s | 0.191 s |
| `AuthSessionTests.testAdoptingAWebSessionEndToEndThroughThePerServerCookieStore` | 1.396 s | 0.229 s |
| `T249bc296…testSignOutCookieClearingRemovesOnlyTheAuthCookieFromANonisolatedCaller` | 0.912 s | 0.144 s |
| `T249bc296…testTheDiagnosticsSessionProviderReadsTheServersStoreFromANonisolatedCaller` | 0.035 s | 0.016 s |
| `T249bc296…testTheDiagnosticsSessionProviderReportsAbsentCookiesFromANonisolatedCaller` | 0.057 s | 0.014 s |
| `T249bc296…testTheSessionCookieReaderIsConstructibleAndUsableFromANonisolatedCaller` | 0.028 s | 0.012 s |
| `TA5321d5eBoundedWaitTests` (7 cases) | 0.002–1.711 s | 0.002–1.050 s |

The 15 skips in the gate log are 13 pre-existing fixture/entitlement skips
(`MentionPollerTests`, `SelfSignedTrustTests` ×2, `T44CCallsEngineTests` ×3, `T53MediaTransportTests` ×2,
`T88LiveSlashTests` ×5), `TGateHangFixtureTests` (env-gated, never armed on a push), and **one more
that matters here**: the sibling card's `T31SSOViewModelTests.testClearingTheAuthCookieRemovesOnlyThisServersSessionCookie`
skipped at **15.012 s**, with the message now coming from the shared
`webKitSilenceSkip` (`T28TestSupport.swift:647`) and naming the call:

```
Test skipped - WebKit did not answer this test host: `httpCookieStore.setCookie(MMAUTHTOKEN)` never
completed in 15s, so this case could not be measured on this run …
```

So on this very push the bound did both of the things it exists for: it turned a would-be 300 s
unclassified hang into a 15 s skip that names the call, and it certified the eight cases that
WebKit *did* answer.

## 11. The one number to watch: 13.991 s under a 15 s window

`T31WebSessionHarvestTests.testTheProductionReaderFindsTheSessionInTheServersOwnWebsiteDataStore`
measured **13.991 s** on the runner — 1.0 s of margin under the 15 s detector, and the same push
skipped the sibling case at the identical boundary (`httpCookieStore.setCookie(MMAUTHTOKEN)`, 15.012 s).
The log shows where it goes: the case started at 21:14:20.280 and the adoption only logged
`adopted the webview session` at 21:14:34.270; the two wrapped calls in between are the seed
`setCookie` and the `restore` whose production reader reads the store. So the runner's *first* cookie
write into a fresh per-server store — 306 ms on this Mac (`docs/t_a5321d5e-build-note.md` §3) — costs
13–15 s there, right at the window.

Nothing was widened here: 15 s is the sibling card's documented window and this card's spec. But 15 s is
no longer comfortably a *hang detector* for these cold-store calls (it is a latency budget with ~1 s of
headroom), and widening it is a decision with its own measurement (does that write answer at 20 s or
30 s, or is it the same "never" the sibling case saw?). Filed as
`t_efd0a2ad` — *the gate pass's cold cookie write measured 13.991 s: decide whether the 15 s window is
still a detector* — rather than changed in this diff. Until then the failure mode is visible and
labelled, not a red leg: the case skips and says which call it was waiting on.
