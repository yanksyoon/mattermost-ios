# The cold cookie write on the runner: 13.991 s, 38.330 s, or never — and the 15 s window could not tell them apart (card `t_efd0a2ad`)

What the card asks, and where each half is answered here:

| # | Requirement | Where |
|---|---|---|
| 1 | quote the **runner-side distribution** of the first cold cookie write from real logs | §2 (method), §3 (numbers), §4 (what the modes are) |
| 2 | choose one of the two windows, with the reasoning | §5 (chosen: widen the cold-store call to 60 s, ambient stays 15 s) |
| 3 | `docs/releasing.md` matches the choice | §6, and the "Two windows, after a measurement" section it points at |
| 4 | a control for whatever window is chosen, in `TA5321d5eBoundedWaitTests` | §7 (four controls) |
| 5 | a green `test (ios-simulator)` leg on a real push, and the gate log still names the call on any skip | §8 |
| 6 | do not move these classes between passes | §9 (nothing moved) |

Hosts: the hosted `macos-26` 3-vCPU runner for every number that matters, and this Mac (Apple silicon,
macOS 27.2.1) only for the local comparison in §4. Local runs went through `scripts/qa-test.py
--platform mac` (Catalyst), because this host's developer mode was reset by the macOS 27 upgrade and
every simulator run dies with `DTServiceHubClient failed to bless service hub` — the same substitution
the parent card documented.

---

## 1. The question, stated so a measurement can answer it

Run `43304994377` (green, `aed87f4`) contained both of these:

| case | time |
|---|---|
| `T31WebSessionHarvestTests.testTheProductionReaderFindsTheSessionInTheServersOwnWebsiteDataStore` | **13.991 s** (passed, 1.0 s under the 15 s window) |
| `T31SSOViewModelTests.testClearingTheAuthCookieRemovesOnlyThisServersSessionCookie` | **skipped at 15.012 s**, naming `httpCookieStore.setCookie(MMAUTHTOKEN)` |

One call 1.0 s from the window and another produced by the window. `docs/releasing.md` and
`T28TestSupport` both say the window is a **hang detector, not a latency budget** — but a budget is
exactly what it becomes if the next cold-start run skips a case that would have passed. The unknown was
whether the second sample was the same slow-but-alive call, or a genuinely dead one. A case total cannot
say: it includes the seed write *and* the restore read, and nothing in the log separated them.

## 2. The method: one line per call, with a detector far from the cost

Commit `3c9ad17` (temporary; deleted by `b0a1a18`) did two things and nothing else:

* `withWebKitAnswer` logs **one line per bound call** —
  `WEBKITBOUND <answered|silent> <call> after <elapsed> s (window <w> s)` — so the number is the call's
  own, not inferred from the case line;
* the window for every call was raised to **120 s** for that push, far from the 13.991 s the healthy call
  costs, so a late answer is *measured* instead of being reported as silence at 15 s.

It also added `ZEFD0a2adColdStoreProbeTests`, a probe that writes two cookies into four fresh
`WKWebsiteDataStore(forIdentifier:)` stores (each: first write, second write, read back, wipe) through the
same helper. It is named `Z…` on purpose: XCTest runs classes in name order, so it runs *after* every real
class and cannot pay the process's first WebKit cost on their behalf. It measures the cost of a *fresh
store once WebKit is already up* — and, over four stores, whether that cost is per process or per store.

The probe commit's own gate leg went **red**, and that is part of the evidence, not a defect in the
measurement: §3 shows the probe's first three calls each burning their full 120 s, which exceeded
XCTest's 300 s execution allowance for that case (`ZEFD0a2adColdStoreProbeTests
.testWhatAFreshStoresFirstCookieWriteCosts()`, "exceeded execution time allowance of 5 minutes"). The 300 s
allowance is per case, and the probe was deliberately allowed to wait 3 × 120 s.

## 3. The distribution (run `43315247724`, `test (ios-simulator)`, job `131530576678`)

Every number below is `WEBKITBOUND` output from that run's `ios-simulator.log`; the artifact is the run's
`test-log-ios-simulator`.

Cold writes — the first WebKit call in a case, into a fresh per-server store:

| case | call | elapsed | outcome |
|---|---|---|---|
| `T249bc296…testSignOutCookieClearingRemovesOnlyTheAuthCookieFromANonisolatedCaller` | `WebSessionCookieInstaller.install(MMAUTHTOKEN,MMCSRF)` | silent past **120 s** | case skipped (120.246 s), naming the call |
| `T249bc296…testTheDiagnosticsSessionProviderReadsTheServersStoreFromANonisolatedCaller` (the **very next** case) | `WebSessionCookieInstaller.install(MMUSERID,MMCSRF,MMAUTHTOKEN)` | **38.330 s** | case **passed** at 40.231 s |
| `AuthSessionTests.testProductionReaderReadsTheServersOwnStoreAndNoOther` | `setCookie(MMAUTHTOKEN)` | 1.501 s | passed |
| `AuthSessionTests.testAdoptingAWebSessionEndToEndThroughThePerServerCookieStore` | `setCookie(MMAUTHTOKEN)` | 1.398 s | passed |
| `T31WebSessionHarvestTests.testTheProductionReaderFindsTheSessionInTheServersOwnWebsiteDataStore` | seed `setCookie(MMAUTHTOKEN)` | 0.008 s | passed |
| `T31SSOViewModelTests.testClearingTheAuthCookieRemovesOnlyThisServersSessionCookie` | `setCookie(MMAUTHTOKEN)` | 0.107 s | passed |
| `ViewStoreTests.testAuthCookiesDoNotLeakBetweenServers` | `setCookie(MMAUTHTOKEN)` | 0.818 s | passed |

Calls after the store is up (same run): `authToken` 0.002–0.036 s, `sessionData` 1.672 s (immediately after
the 38.330 s write), `allCookies` 0.030 s, `clearAuthCookie` 1.238 s, the second `setCookie(MMCSRF)` 0.625 s,
`install(MMCSRF)` 0.015–0.021 s. **0.001–1.672 s**, i.e. the ambient mode really is cheap.

The four-store probe (same leg, ran last):

| store | first write | second write | read | wipe |
|---|---|---|---|---|
| #1 | silent past 120.298 s | silent past 120.021 s | silent past 120.012 s | 0.715 s |
| #2 | 0.088 s | 0.067 s | 0.050 s | 0.530 s |
| #3 | 0.015 s | 0.007 s | 0.005 s | 0.202 s |
| #4 | 0.035 s | 0.018 s | 0.007 s | 0.508 s |

That is the shape of the failure mode: a store whose WebKit Networking service never starts does not
answer **any** cookie call (three silences in a row), and then a *different* call on the same store
(`removeData`) answers in 0.715 s — after which every following store is milliseconds. The silence is not
the runner running out of CPU; it is one store's WebKit service boot.

For contrast, the **same run's Catalyst leg** (same 3-vCPU runner, same commit): every cold write answered,
slowest **0.240 s** (`AuthSessionTests`), harvest seed 0.008 s, `T249bc296` installer 0.007–0.011 s, the
four-store probe 0.025–0.052 s. The slow mode is specific to the simulator's WebKit service, not to the
runner's CPU.

And on this Mac (Catalyst, `build/logs/t-efd0a2ad-probe-local.log`, same probe): fresh-store first writes
0.005–0.134 s, every second write ≤ 0.006 s. The parent card's `t_a5321d5e` probe measured the very first
cold write of a process at 306 ms here.

## 4. What the distribution means

Three modes, not one:

| mode | measured | what it is |
|---|---|---|
| fast | 0.001–1.672 s | WebKit's service for that store is up |
| **slow but alive** | **4.092 s, 13.991 s, 38.330 s** | the service starts, slowly, and the call answers |
| never | silent past 120 s | the service does not start for that store; the case can never be measured |

A 15 s window sits **inside** the slow-but-alive mode. Run `43315247724` proves what that costs: the case
that answered at **38.330 s passed**, and the identical call in the case immediately before it never came
back. Under the 15 s window both would have been skipped — one of them a case that passes. That is coverage
silently traded for a bounded wait, on an ordinary green run, and it is exactly the failure the card named.

Keeping 15 s and "saying plainly that a ~14 s healthy call will sometimes skip" would therefore be an
under-statement: the healthy tail measured **38.330 s**, not ~15 s. The card's first option does not survive
the measurement.

## 5. The choice: two windows — ambient 15 s, cold-store 60 s

| window | where | value | why |
|---|---|---|---|
| `WebKitAnswerWindow.ambient` | every call after that store's WebKit service is up | **15 s** (unchanged) | measured 0.001–1.672 s; widening it would buy nothing and turn a detector into a budget |
| `WebKitAnswerWindow.coldStore` | the one call that starts the service for a fresh per-server store — the **first write** in each real-store case | **60 s** | the slowest **answered** cold write measured is 38.330 s; 60 s is 1.57× that and 4.3× the 13.991 s case |

Why not 120 s (the measurement window): the dead mode is already proven dead past 120 s, so waiting 120 s
buys no coverage — it only doubles what a silent host costs the leg. Why not 45 s: 45 leaves 6.7 s over the
slowest answered call, which is thinner than the spread the three alive samples already show. 60 s keeps
21.7 s of absolute headroom, is the card's own proposal, and is still **5× better than the 300 s allowance**
it replaces. A call that never comes back skips either way, now naming itself after 60 s instead of 15.

The residual risk is stated rather than hidden: if the alive mode ever exceeds 60 s, a healthy case will
skip again. That is why every slow or silent call now writes a `WEBKITBOUND` line to the gate log — the
next reader gets the number from the run instead of having to re-instrument the suite, and the skip says
which window fired.

## 6. The change

`MattermostTests/T28TestSupport.swift`:

* `enum WebKitAnswerWindow { static let ambient: TimeInterval = 15; static let coldStore: TimeInterval = 60 }`
  with the measurement table above in its doc comment, so the number and its evidence live with the code;
* `withWebKitAnswer`, `requireWebKitAnswer` and `requireWebKitAnswerOrThrow` default to
  `WebKitAnswerWindow.ambient` — **no call site's default changed behaviour**;
* one `WEBKITBOUND` line per call that took ≥ 1 s or never answered (a fast call stays quiet, so a normal
  gate log gains nothing);
* `webKitSilenceSkip` now quotes the window that actually fired and says plainly that the number is that
  call's hang detector, not a latency budget. The skip still names the `await` in backticks
  (`docs/releasing.md`, "Two windows, after a measurement").

The cold call sites — one per real-store case, the first write in each — pass
`timeout: WebKitAnswerWindow.coldStore`:

| file | call |
|---|---|
| `T249bc296WebKitCookieIsolationTests.swift` (`seed(_:in:)`) | `WebSessionCookieInstaller.install(…)` |
| `AuthSessionTests.swift` ×2 | `httpCookieStore.setCookie(MMAUTHTOKEN)` |
| `T31WebSessionHarvestTests.swift` | seed `httpCookieStore.setCookie(MMAUTHTOKEN)` |
| `T31-AuthTests.swift` | `httpCookieStore.setCookie(MMAUTHTOKEN)` |
| `ViewStoreTests.swift` | `httpCookieStore.setCookie(MMAUTHTOKEN)` |

Every read, every second write and every best-effort wipe keeps the 15 s ambient window — the widening is
where the cold cost is, not "the WebKit tests are slow now". No assertion changed, no case was added to or
removed from a pass, and the temporary `ZEFD0a2adColdStoreProbeTests` and its 120 s window are deleted.
`docs/releasing.md` gains "Two windows, after a measurement" and its SSO paragraph now quotes 60 s for that
write.

## 7. The controls (`MattermostTests/TA5321d5eBoundedWaitTests.swift`)

A window is only a decision if something fails when it drifts, so four controls pin it — and they cost
nothing on a healthy host (1.0 s, 2.0 s, and two arithmetic assertions):

| control | pins |
|---|---|
| `testTheAmbientWindowStaysAFifteenSecondDetector` | ambient is still 15 s — the widening is not a general loosening |
| `testTheColdStoreWindowCoversTheSlowestAnsweredColdWriteAndStaysFiveTimesUnderTheAllowance` | cold is 60 s, **> 38.330 s** (the slowest answered call), **≤ 300/5** (5× better than the allowance) |
| `testAColdCallThatAnswersIsReturnedAtItsOwnCostNotAtTheColdWindow` | a 1 s answer inside the 60 s window comes back in ~1 s, not at the window: it is still a detector |
| `testASilentColdCallSkipsNamingTheCallAndItsOwnWindow` | a silent call still **skips**, names `httpCookieStore.setCookie(MMAUTHTOKEN)`, quotes the window that fired (2 s here, 60 s in production) and says "hang detector, not a latency budget" |

Local run (Catalyst, `build/logs/t-efd0a2ad-final-classes.log`): the six affected classes —
`TA5321d5eBoundedWaitTests`, `T249bc296WebKitCookieIsolationTests`, `AuthSessionTests`,
`T31WebSessionHarvestTests`, `T31SSOViewModelTests`, `ViewStoreTests` — **64 tests, 0 skipped, 0 failed**.

## 8. The gate leg on a real push

Run **`43325147617`** on `b0a1a18` (the commit above; tag `v0.76.8` published from it):

| leg | job | result |
|---|---|---|
| `test (ios-simulator)` | `131555703484` | **2577 tests, 16 skipped, 0 failed, 416.074 s, `** TEST SUCCEEDED **`** |
| `test (catalyst)` | `131555703555` | 2577 tests, 15 skipped, 0 failed, 141.499 s, `** TEST SUCCEEDED **` |

Two WebKit calls were silent on that simulator run, and both skips name the call and quote the window that
fired — which is the contract this card had to keep:

```
WEBKITBOUND silent httpCookieStore.setCookie(MMAUTHTOKEN) after 60.142 s (window 60 s)
T28TestSupport.swift:698: -[…T31SSOViewModelTests testClearingTheAuthCookieRemovesOnlyThisServersSessionCookie] :
  Test skipped - WebKit did not answer this test host: `httpCookieStore.setCookie(MMAUTHTOKEN)` never
  completed in 60s, so this case could not be measured on this run …
Test Case '…testClearingTheAuthCookieRemovesOnlyThisServersSessionCookie]' skipped (60.381 seconds).

WEBKITBOUND silent httpCookieStore.setCookie(MMAUTHTOKEN) after 60.010 s (window 60 s)
T28TestSupport.swift:698: -[…T31WebSessionHarvestTests testTheProductionReaderFindsTheSessionInTheServersOwnWebsiteDataStore] :
  Test skipped - WebKit did not answer this test host: `httpCookieStore.setCookie(MMAUTHTOKEN)` never
  completed in 60s …
Test Case '…testTheProductionReaderFindsTheSessionInTheServersOwnWebsiteDataStore]' skipped (60.049 seconds).
```

The same run also shows the alive mode paying the window's cost honestly, with WebKit naming its own
mechanism:

```
2026-11-12 23:08:08.790584 Mattermost[7051:26147] Networking process (0x1240a0190) took 1.137112 seconds to launch
2026-11-12 23:08:08.823588 Mattermost[7051:26147] WEBKITBOUND answered httpCookieStore.setCookie(MMAUTHTOKEN) after 1.170 s (window 60 s)
Test Case '…AuthSessionTests testProductionReaderReadsTheServersOwnStoreAndNoOther]' passed (1.257 seconds).
```

So on a 60 s window the cold write either answers as soon as its Networking process is up (1.170 s here,
38.330 s on the measurement run) or the case skips at 60 s **naming the call** — never a 300 s red leg, and
never a skip at a window that a healthy call has already exceeded. `T249bc296WebKitCookieIsolationTests`
(all four cases 0.044–0.663 s) and `AuthSessionTests` passed on the same host and the same run, so the
skips are per-store WebKit silence, exactly as §3/§4 describe; nothing about them is a product failure and
the `16 skipped` count is one higher than the 15 in run `43304994377` because two WebKit cases were
silenced instead of one.

Catalyst, the same commit: every WebKit call answered, and only the four controls wrote a `WEBKITBOUND`
line (a 1 s answer inside the 60 s window, three deliberate silences at 1–2 s) — so the logging is quiet on
a healthy host, which is what it was for.

## 9. What did not change

* **Pass membership**: nothing moved into the timing or platform pass. The rule from `T41ProfileTests` —
  "the fix belongs in the test, not in the split" — is the reason the answer is a window and not a move.
* **Assertions**: no `XCTAssert` was added, removed or relaxed in any of the five real-store classes; the
  harvest case still asserts the adoption, the token, the phase; the SSO case still asserts all four claims.
* **The skip path**: a silent host still produces an `XCTSkip` naming the call, still counted as skipped
  rather than passed.
