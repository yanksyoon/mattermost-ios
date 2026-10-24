# T31-R — repair of the T31-AV findings + the approved native flip

Card: **T31-R** (`t_8a64ef96`), assigned by T31-AV (`t_c57a7551`). Repairs the findings of the
T31-AV verdict (`PASS-WITH-FINDINGS` on T31 @ `4b89e42`) and lands the approval commit that verdict
authorised (its F8). Nothing in the findings list was deferred.

Read this with `docs/t31-build-note.md` (what T31 shipped) and `docs/dual-render.md` §5 (the
approval rule). Every number below comes from a command in §9; the logs are committed beside this
note.

---

## 0. The one-line version

Three behaviour findings (F1–F3), one criterion-accuracy finding (F4), the approved flip (F5), two
documentation/coverage findings (F6–F7), plus one defect found while producing F7's evidence (F8: the
auth surface did not mount on a launch the router had not routed — pre-existing, reproduced on the
T31 tree). Each behaviour fix has a regression test that **fails against the pre-fix code and passes
after it**; both directions were executed, not asserted (§9.2).

## 1. F1 — an expiry now clears the webview's `MMAUTHTOKEN` too

**Before.** `AuthSession.clearStoredCredentials()` deleted only `.authToken`, and nothing on the
expiry path called `SessionCookieClearing`. Sign-out cleared both copies, expiry cleared one — so
after "Your session expired" the pane escape hatch ("Use the web view instead") could still be signed
in on the same server: one login, two states.

**After.** `AuthCoordinator.requireReauth(_:)` is the single expiry transition and it writes in the
order that makes the payload true: clear the webview cookie, *then* move the phase to `.expired`, so
anything that observes `.expired` (the shell, a test) can rely on the device holding no credential at
all. Both entry points use it — the `needsReauth` sink (a 401 from any call on the session's client)
and `restore()`'s rejection branch. It is idempotent **and awaitable**: a concurrent 401 shares the
in-flight transition (`expiring: [UUID: Task<Void, Never>]`), so `await requireReauth(server)` means
"the device holds no credential and the shell has been told", never "somebody else is doing that".

The first version returned early on a concurrent call, and the full-suite run caught the resulting
flake: the Combine sink could win the race, and `restore()` then resumed before the phase moved
(`testA401OnALiveSessionTurnsTheGateToReauthWithoutAnyScreenInvolved` failed with the phase still
`signedIn`). Sharing the task fixed it; §9.1's focused run and a 3× repeat of the two suites cover it.

Files: `Mattermost/UI/Native/Auth/AuthCoordinator.swift` (`requireReauth`, the sink, `restore`).
Tests (shipped): `T31AuthCoordinatorTests.testASessionExpiryClearsTheWebviewCookieAsWellAsTheVault`,
`testA401FromANonRestoreCallClearsBothCopiesBeforeTheBanner`.

## 2. F2 — sign-out clears the vault **before** the network, synchronously

**Before.** `AuthCoordinator.signOut` awaited `session.logout()` (3 attempts, 0.5 s → 1 s backoff, up
to a 30 s request timeout) and only then deleted the Keychain entries; `SettingsView` fired it as a
detached `Task` and removed the server immediately. A kill inside that window left a usable token for
a server the user had just removed — the defect T31 claimed to have closed.

**After.** The sign-out is split at the point where the risk is:

* `AuthCoordinator.beginSignOut(_:)` is **synchronous**: `AuthSession.beginSignOut()` deletes the
  vault token + userID, clears the ETag cache and sets `.signedOut`, and returns the token it
  discarded. `SettingsView`'s remove action calls it **on its own turn**, before `serverStore.remove`,
  so the credential is gone at the instant the server row disappears — a detached `Task` has not run
  a line by then.
* `AuthCoordinator.finishSignOut(_:)` is the async half: clear the webview cookie, then attempt
  `POST /users/logout` **with the discarded token** (`APIClient.revokeSession(token:)`, the one
  narrowly-scoped explicit-bearer entry point in the client), so clearing first does not silently
  turn revocation into an unauthenticated call. `signOut(_:)` composes the two.

The ordering is the security property, so it is stated where it is implemented (the `beginSignOut`
doc comment) and in the build note §3. The cookie clear stays async because `WKWebsiteDataStore` is
async; the copy a kill would leave *usable* — the Keychain token — is the one deleted first.

Files: `AuthCoordinator.swift`, `Mattermost/Core/MM/AuthSession.swift` (`beginSignOut`,
`revokeSession`, `logout`), `Mattermost/Core/MM/APIClient.swift` (`revokeSession(token:)`),
`Mattermost/UI/SettingsView.swift` (remove path).
Tests: `testSignOutClearsTheVaultBeforeTheLogoutCallCompletes` (a transport whose `/users/logout`
stalls 2 s: 0.4 s in, the vault is already empty),
`testBeginSignOutIsSynchronousAndStillRevokesWithTheDiscardedToken` (no `await` between the call and
the assertions; the revocation still carries `Bearer tok-live`).

## 3. F3 — a 401 from a call path that does not use the session's client now reaches re-auth

**Before.** The 401 → re-auth wiring was `AuthSession.init`'s `client.onUnauthorized`, observed by
`AuthCoordinator`. `MentionPoller` (T14 background polling, enabled in the shipping configuration)
builds its own `URLSession` + `Bearer` header and could not reach it, so a revoked token left the
poller failing silently while the shell still believed it was signed in.

**Decision.** Option (b) from the card — an explicit report — because the poller cannot adopt the
session's client: it runs from a `BGAppRefreshTask` with no scene, and it owns an *ephemeral* session
it can `invalidateAndCancel()` on task expiration (`cancelInFlight`), a lifecycle the `AuthSession`
client does not have. Concretely:

* `MentionPoller.unauthorizedReporter: ((ServerConfig) async -> Void)?`, wired in
  `MattermostApp.bindShellStores()` to `AuthCoordinator.reportUnauthorized(_:)`.
* `PollError.isSessionExpiry` marks a `401`; the per-team and per-channel tolerance `catch` blocks
  **rethrow** it (otherwise the drill-down logs the expiry as a channel hiccup and the poll
  "succeeds"), and the top-level `catch` reports the server once, logs, and returns
  `.failed("session expired")` without touching the watermark.
* `AuthCoordinator.reportUnauthorized(_:)` produces the identical transition a client-side 401 does
  (vault copy dropped, cookie cleared, phase `.expired`, one `onChange`), and refuses to raise the
  banner for a server the shell already treats as signed out.

Files: `Mattermost/Core/MentionPoller.swift`, `AuthCoordinator.swift`, `AuthSession.swift`
(`reportUnauthorized()`), `Mattermost/MattermostApp.swift`, `MattermostTests/MentionPollerTests.swift`.
Tests: `testA401AbortsThePollAndReportsReAuthOnce`,
`testA401OnANestedUnreadFetchIsNotSwallowedByThePerTeamTolerance`,
`testThePollersReportReachesTheAuthCoordinator` (a real coordinator: the poll expires the shell's
session), plus `testAReportedUnauthorizedExpiresTheSessionAndClearsBothCopies` and
`testAStale401ReportForASignedOutServerRaisesNoBanner`.

### 3.1 The rule T32+ screens must follow

> **Do not construct an `APIClient` or a `URLSession` for authenticated server calls. Take the
> server's `AuthSession` client** (`AuthCoordinator.session(for:).client`) **so a 401 lands in
> `onUnauthorized` and therefore in the one re-auth path for free.**

`grep -rn "APIClient(" Mattermost/` must keep returning only `AuthSession.swift`; a second
construction site is the F3 defect coming back. The one sanctioned exception is a call path that
cannot own a scene (today: `MentionPoller`), and it must report through
`AuthCoordinator.reportUnauthorized(_:)` — nothing else. This is also stated in the code
(`AuthCoordinator.reportUnauthorized`'s doc comment), not only here.

## 4. F4 — the "no credential outside `SecureVault`" criterion is scoped to the native path

A session established in the webview keeps its `HttpOnly` `MMAUTHTOKEN` cookie in
`Library/WebKit/…/WebsiteDataStore/<id>/Cookies/Cookies.binarycookies` (plaintext in WebKit's cookie
database). That is pre-existing T26 webview behaviour, it is why the cookie is treated as "the second
copy" everywhere in the code, and the native path never writes it. The *criterion* was absolute and
marked PASS, which is the actual defect.

Fixed in `docs/t31-build-note.md` §6 (the row now reads "No credential logged, and none written
outside `SecureVault` **on the native path**", with the cookie named, explained and cross-referenced
to the sign-out/expiry clears) and in `docs/parity.md`'s T31 row (limits paragraph). No code change:
the behaviour is deliberately two-store; only the claim was wrong.

## 5. F5 — the approved native flip (its own commit)

`Mattermost/Core/RenderMode.swift`: `nativeApprovedSurfaces = [.auth]` (was `[]`),
`paneOwningSurfaces` stays `[]`. The set now carries an **approval ledger** in its doc comment —
which surface, which `-AV` card, which evidence — so a future entry cannot be added without saying
who approved it. `docs/dual-render.md` §5 documents the ledger (with the same table) and explains
gate 5's `--allow-approved-registry` flag as the *audit* of an approval commit; `docs/parity.md` says
`.auth` is native by default and is the only approved surface.

Tests that encoded "the registry is empty" were updated, not deleted:
`SurfaceModeResolverTests.testOnlyTheApprovedRegistryDefaultsToNative` (registry pinned to exactly
`[.auth]`; every surface resolves to its compile-time default), `testNativeByDefaultRequiresApproval`
(now also asserts `.auth` → native and `.channelView` → web), the launch/remote/release assertions
that used `.auth` as "an unapproved surface" now use `.threads`/`.calls`, and
`ViewStoreTests.testEmptyRegistriesMakeReleaseUnreachable` pins the new registry while still proving
release is unreachable (approval ≠ pane ownership).

UI: `testSignedOutServerShowsTheIdentifiableAuthSurface` now asserts the **native form** renders with
no `-surfaceMode` flag at all, and `testTheAuthStandInIsStillReachableThroughTheSurfaceFlag` proves
`-surfaceMode auth=web` still renders the T30 stand-in with its escape hatch — the flip removes no
fallback. The captures in §9.4 are the shipping configuration: `auth-surface-light.png` is a launch
with **no** surface flag, and it is the native form.

## 6. F6 — the build note's per-suite counts, corrected

`docs/t31-build-note.md` §9 said Login 13 / SSO 8 / Coordinator 14. The runner executes
**12 / 7 / 16** (+ MFA 2 = 37). §9 now prints the corrected split, says the total was always right
and the split was not, and lists the T31-R additions. `T31-AuthTests.swift` is 47 tests after this
card (12 + 2 + 7 + 16 + 4 new `T31LoginErrorCopyTests` + 6 new coordinator regressions).

## 7. F7 — the coverage gaps

* **`LoginErrorCopy` branches.** New `T31LoginErrorCopyTests` (4 tests) pins every branch the finding
  named — `rateLimited` (with and without `Retry-After`), `forbidden`, `notFound`, `server`, `client`,
  `malformedResponse`, `notSignedIn`, `invalidURL`, `cancelled` — plus the two "the server's own
  sentence wins" branches, a non-`MMError` fallback, and one row driven through `LoginViewModel.submit`
  so the copy is proven wired to the screen, not only to the helper.
* **Captures.** `-authSurfaceSnapshot <dir>` (DEBUG, mirrors T30's `-nativeShellSnapshot`: four window
  PNGs written by the app with `drawHierarchy`, no Screen Recording consent needed) produced the eight
  images in `docs/t31r-shots/` (§9.4).
* **Still not validated, and said so** (build note §11): SSO end to end (no identity provider on this
  host — the AV's own UI probe covers the sheet, §9.2), MFA against a real server (no MFA-enrolled
  account), and no Catalyst capture (the probe photographs a `UIWindow`; the views and the unit suite
  do run on Catalyst).

## 8. F8 — found while producing F7's evidence: the auth surface did not mount

**Symptom.** Every `launchNativeAuth` UI test failed with "the native auth surface must mount", and a
seeded, signed-out server rendered the **workspace skeleton** instead of the sign-in screen.

**Cause.** `NativeNavigation.open(_:)` needs `serverStore`/`viewStore` to resolve a route, and they
were bound only from `MattermostApp`'s `.task`. `RootView`'s `.onAppear` (→ `startUp()` → `activate`
→ route) can run first; when it did, the route answered `.unsupported("no server store is bound to
the native navigation model")`, **no location was ever written**, and `NativeShellView`'s
`showsAuthSurface` (which requires `location.serverID == server.id`) stayed false for the rest of the
run. The 401/expiry work in this card was fine; the surface never got the chance to render.

**Pre-existing, proved.** Reverting the whole tree to T31 (`4b89e42`, `git stash`) and re-running two
of the tests on an **erased** simulator reproduces it (`testNativeSignInSurfaceIsAFormNotAWebview`
fails at the same assertion, same "no native auth surface" tree). Not vault residue, not a stale
cookie, not this card.

**Fix.** `NativeNavigation.bind(serverStore:viewStore:)` (idempotent) called from `RootView`'s
`.onAppear` immediately before `startUp()`, so the first route cannot lose the race. The app's
`.task` binding stays (it also wires the router, the notification worker and the gate).

## 9. Not this card — the clipped server title

T31-AV's observation (the post-sign-in shell's server title cut off behind the iOS 26 floating
toolbar) is `RootView`'s `serverSwitcher` chrome, not the auth surface. Left to the shell queue; no
change here.

## 10. Evidence

macOS 26.3.1, Xcode 26.6 (17F113), Catalyst 26.5, iPhone 17 Pro / iOS 26.5
(`023B9070-CAD0-409B-BFD0-78FF5CA5EACC`, erased before the UI run), iPad Pro 11-inch (M5) / iOS 26.5
(`DC3E9FB7-E4A0-4B24-8DBB-7960A059EC7A`).

### 10.1 Suites on the final tree

| Run | Command (short) | Result |
|---|---|---|
| Catalyst unit, `MattermostTests` (clean path `mmios-t31r-cat4`) | `scripts/qa-test.py --platform mac --label t31r-catalyst-final-full` | **655 run, 4 skipped, 0 failed** — `RESULT: PASS` (`docs/t31r-catalyst-full-2026-10-25.log`) |
| iOS UI, `MattermostUITests` (stubs 8111/8112/8113/8114/8115/8443) | `scripts/qa-test.py --platform ios --sim id=023B9070… --only-testing MattermostUITests` | **24 run, 3 skipped, 0 failed** — `RESULT: PASS` (`docs/t31r-ios-ui-2026-10-25.log`) |
| Focused (auth + poller) | `--only-testing T31AuthCoordinatorTests --only-testing T31LoginErrorCopyTests --only-testing MentionPollerTests --only-testing AuthSessionTests --only-testing APIClientTests` | **94 run, 1 skipped, 0 failed** (`docs/t31r-catalyst-focused-2026-10-25.log`) |

The 4 Catalyst skips are the pre-existing opt-in live tests; the 3 UI skips are the live-SSO and
real-server tests (no IdP on this host). After the earlier flake was fixed, the two auth suites were
run three more times back to back: `42 run, 1 skipped, 0 failed` each time.

### 10.2 The repaired tests fail against the pre-fix behaviour (executed, not asserted)

Three behaviours temporarily reverted from the *final* tree (expiry without the cookie clear, restore
without the shared transition, poller 401 swallowed), tests untouched:

```
→ 42 run, 1 skipped, 10 failures across 6 tests
   testASessionExpiryClearsTheWebviewCookieAsWellAsTheVault
     XCTAssertEqual failed: ("[]") is not equal to ("[B14BB736-…]") — an expiry must drop the
     webview's MMAUTHTOKEN too …
   testA401FromANonRestoreCallClearsBothCopiesBeforeTheBanner
     XCTAssertEqual failed: ("[]") is not equal to ("[52161A0C-…]") — one 401 → one cookie clear
   testA401AbortsThePollAndReportsReAuthOnce
     XCTAssertEqual failed: ("failed("HTTP 401")") is not equal to ("failed("session expired")")
   testA401OnANestedUnreadFetchIsNotSwallowedByThePerTeamTolerance
     XCTAssertEqual failed: ("[]") is not equal to ("[5B8986A5-…]") — the nested 401 must reach …
   testThePollersReportReachesTheAuthCoordinator
     XCTAssertEqual failed: ("signedIn(username: "ada", …)") is not equal to ("expired")
   testAReportedUnauthorizedExpiresTheSessionAndClearsBothCopies
     XCTAssertEqual failed: ("[]") is not equal to ("[918FCB5A-…]")
```
Log: `docs/t31r-catalyst-prefix-probe-2026-10-25.log`. The reverted files were restored **byte for
byte** (sha256 `7b543df0…` coordinator, `b7698231…` poller) and the suites re-ran green (`42 run,
1 skipped, 0 failed`, `docs/t31r-catalyst-restored-2026-10-25.log`).

The T31-AV's own probes, which pin the *defective* behaviour, now fail at their own FINDING
assertions on the fixed tree (`docs/t31r-av-probes-2026-10-25.log`):

```
→ 5 run, 1 skipped, 2 failed
   testAVR2A401ExpiryLeavesTheWebviewCookieUntouched
     XCTAssertEqual failed: ("1") is not equal to ("0") — FINDING: an expired session clears the
     vault token but leaves the webview's MMAUTHTOKEN cookie in place
   testAVR5TheSignOutVaultClearWaitsForTheNetworkCall
     XCTAssertNotNil failed — FINDING: 0.7 s after sign-out/remove began, the vault still holds the
     token
```

The AV's **UI** probe — the gap that flipping the surface could have widened — passes on the flipped
tree (`docs/t31r-av-uiprobe-2026-10-25.log`, `1 run, 0 failed`):
`testAVU1TheSSOSheetMountsTheExistingWebviewAndCancelsBackToTheForm` mounts the SSO sheet on the
shell's existing webview, raises no certificate prompt for the plain-HTTP stub, and cancels back to
the native form. Both probe files were copied in, run and removed; neither is committed.

### 10.3 Gates

```
scripts/verify-dual-render-gates.sh                        → RESULT: FAIL — 1 violation (gate 5 only:
                                                             "nativeApprovedSurfaces is non-empty
                                                             ([.auth]) without -AV evidence in this
                                                             run; pass --allow-approved-registry…")
scripts/verify-dual-render-gates.sh --allow-approved-registry
                                                           → RESULT: PASS — every gate ok (23 checks)
```
Log: `docs/t31r-gates-2026-10-25.log` (both runs, in order). The plain run's failure is the point:
the gate is live, and the only thing it objects to is the approval itself.

### 10.4 Captures (`docs/t31r-shots/`)

Shipping configuration — no `-surfaceMode auth=…` anywhere, just `shell=native`, a seeded server and
`-uiTestForgetSession`:

| File | Shows |
|---|---|
| `auth-surface-light.png` | iPhone: native form — "Sign in to Matternelle", both fields, Log In disabled until both are filled, "or / Sign in with SSO", "Use the web view instead" |
| `auth-surface-dark.png` | the same in dark mode |
| `auth-surface-light-ax3.png`, `auth-surface-dark-ax3.png` | the same at `accessibility3`: the heading wraps to two lines instead of clipping, fields and buttons grow, everything scrolls (at AX3 the escape hatch sits below the fold and scrolls into view — reachable, not cut off) |
| `auth-surface-ipad-light.png`, `…-dark.png` | iPad Pro 11-inch (M5): the form stays centred at its 480 pt max width; nothing stretches to the full sheet |
| `auth-surface-ipad-light-ax3.png`, `…-dark-ax3.png` | the same at AX3 |

Command (iPhone; the iPad run is identical with `DC3E9FB7…` and its own output dir):

```
xcrun simctl launch 023B9070… com.mattermost.ios \
  -uiTestResetPersistedState -uiTestSeedServer https://mm.example \
  -uiTestSeedServerName "Matternelle" -uiTestForgetSession https://mm.example \
  -surfaceMode shell=native -authSurfaceSnapshot "$PWD/build/shots/t31r-iphone"
```

Not captured, and why: Catalyst (the probe photographs a `UIWindow`; Catalyst renders the same views
and runs the whole unit suite), and the MFA step / expired banner under a non-default appearance
(those are fixture states needing a scripted transition; `docs/t31-shots/` shows them in the default
appearance).

## 11. Files touched

`Mattermost/Core/RenderMode.swift` (F5) · `Mattermost/Core/SurfaceModeResolver.swift` (doc, F5) ·
`Mattermost/Core/MM/AuthSession.swift` (F1/F2/F3) · `Mattermost/Core/MM/APIClient.swift` (F2) ·
`Mattermost/UI/Native/Auth/AuthCoordinator.swift` (F1/F2/F3) · `Mattermost/Core/MentionPoller.swift`
(F3) · `Mattermost/UI/SettingsView.swift` (F2) · `Mattermost/MattermostApp.swift` (F3 wiring, capture
probe) · `Mattermost/Core/Native/NativeNavigation.swift` + `Mattermost/UI/RootView.swift` (F8) ·
`MattermostTests/T31-AuthTests.swift`, `MattermostTests/MentionPollerTests.swift`,
`MattermostTests/SurfaceModeResolverTests.swift`, `MattermostTests/ViewStoreTests.swift` ·
`MattermostUITests/MattermostUITests.swift` (F5, F8) · `docs/t31-build-note.md`, `docs/parity.md`,
`docs/dual-render.md`, this note, `docs/t31r-shots/*`, `docs/t31r-*.log`.
