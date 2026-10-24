# T31 — native auth & session surface (build note)

Card: `T31: Native auth & session surface` (t_02270388). Design of record:
`~/.hermes/plans/2026-10-08_mattermost-desktop-ios-migration.md` (§1 Path B, §4 module map);
screen inventory and API usage: `docs/component-map.md` (S01/S02/S03) and
`mattermost/mattermost-mobile` @ `162f2560d0e1df073220f7701d5a67cc17c8abeb` (Apache-2.0, attribution
in `docs/THIRD_PARTY_NOTICES.md` §8).

This note is deliberately written so its claims can be re-run: every number below comes from a
command in §13, and the two "real server" screenshots come from a live `mattermost` server rather
than a fixture (§7).

> **T31-R (the T31-AV repair) changed three behaviours and shipped the surface.** The expiry path now
> clears the webview cookie as well, sign-out clears the vault *before* the network call, and a 401
> seen by the background mention poller reaches the re-auth path; `.auth` is native by default. The
> finding-by-finding record, with the fails-before/fails-after runs, is
> `docs/t31r-patch-note.md`.

---

## 1. What shipped

| Piece | File | Purpose |
|---|---|---|
| App-level auth owner | `Mattermost/UI/Native/Auth/AuthCoordinator.swift` | one live `AuthSession` per server; the shell's `NativeAuthGate`; restore at launch; 401 → one re-auth path; sign-in / SSO adoption / sign-out; certificate decisions for the **native** transport |
| Sign-in machine | `Mattermost/UI/Native/Auth/LoginViewModel.swift` | mobile `login/form.tsx` rules: trimmed + lowercased login id, submit enabled only when both fields carry input, the server's rejection sentence inline, MFA hand-off, redacted diagnostics |
| Second factor | `Mattermost/UI/Native/Auth/MFAViewModel.swift` | the token step: its own error, rejected digits cleared, no resend of a code that was already refused |
| SSO hand-off | `Mattermost/UI/Native/Auth/SSOViewModel.swift`, `SSOView.swift` | keeps the webview: hosts the existing `WebViewContainer`, polls that server's `WKWebsiteDataStore` for `MMAUTHTOKEN`, adopts the session, lands on the native shell; `WebKitSessionCookieReader`/`WebKitSessionCookieClearing` live here |
| Screens | `Mattermost/UI/Native/Auth/LoginView.swift`, `MFAView.swift` | `AuthSurfaceView` (the `.auth` card: native branch + the T30 stand-in as its web branch), `LoginView`, `MFAView`, `SessionExpiredBanner` |
| Shell wiring | `Mattermost/MattermostApp.swift`, `Mattermost/UI/Native/NativeShellView.swift` | `AuthCoordinator` created, injected, bound as the shell's gate, `restoreAll` at launch, DEBUG seams (§10.3) |
| Logout | `Mattermost/UI/SettingsView.swift` | Settings → **Session**: sign-out row per signed-in server, confirmation dialog; *removing* a server signs it out first |
| Tests | `MattermostTests/T31-AuthTests.swift` (37 unit tests), `MattermostUITests/MattermostUITests.swift` (+7 UI tests) | §9 |

No file outside these was rewritten, and no `WKWebView` was introduced: the SSO sheet *is* the
app's existing webview.

## 2. How it is gated (dual-render, and what "off" means)

`AuthSurfaceView` is a normal screen card:

```swift
SurfaceHost(.auth) {
    nativeSignIn          // §4
} web: {
    NativeAuthPlaceholderView(server: server, resolver: resolver)   // untouched T30 stand-in
}
```

* `Surface.auth` was **not** in `SurfaceDefaults.nativeApprovedSurfaces` when T31 landed, so the
  shipping configuration rendered the T30 stand-in; that was deliberate, because flipping the
  surface is `T31-AV`'s decision, not the card's. **T31-R changed this**: T31-AV approved the
  surface (verdict §F8) and the flip landed in its own commit — `.auth` is now in the registry
  (`RenderMode.swift`), so the native sign-in form renders by default and the T30 stand-in is
  reachable only with `-surfaceMode auth=web` (UI test
  `testTheAuthStandInIsStillReachableThroughTheSurfaceFlag`). See `docs/t31r-patch-note.md` §5.
* The T30-R regression test (`testSignedOutServerShowsTheIdentifiableAuthSurface`) still runs and
  still proves the identifier reaches the tree — it now asserts the native form is what renders in
  that launch; the flag-off test (`testWebPaneIsUnchangedWithoutTheSurfaceFlag`) is untouched and
  still asserts the webview pane path.
* The last bullet above is now only half true: since T31-R the shipping default *is* native, and
  `-surfaceMode auth=native` is a no-op override kept in the T31 UI tests to say so explicitly.
  `-surfaceMode auth=web` is the escape hatch, and it renders the stand-in.

## 3. The state machine

`AuthCoordinator.Phase`: `unresolved → signedIn(username, userID) | signedOut | expired`.

* **Optimistic launch window.** `AuthSession.state` is `.signedOut` until `restore()` round-trips.
  Rendering that would flash a login form on every launch — the exact behaviour the card forbids —
  so an *unresolved* server answers the gate from the vault (`hasStoredToken`), which is what
  `VaultAuthGate` did before this card. Only the server resolves it: an accepted token →
  `.signedIn`; a rejected one → `.expired` (banner + form, never a silent bare form).
* **Offline is not an expiry.** A transport failure leaves the phase `unresolved` and keeps the
  stored session (unit: `testAnUnreachableServerKeepsTheStoredSessionAtLaunch`).
* **One re-auth path — and an expiry drops *both* credential copies.** Each live
  `AuthSession.@Published needsReauth` is observed once; any 401 on any authenticated call flips
  that server to `.expired`, `onChange` re-asks the shell, and the auth surface shows the banner. No
  screen has to notice a 401 (unit:
  `testA401OnALiveSessionTurnsTheGateToReauthWithoutAnyScreenInvolved`). Since T31-R the vault token
  **and** the webview's `MMAUTHTOKEN` are cleared before the phase moves
  (`AuthCoordinator.requireReauth`, unit `testASessionExpiryClearsTheWebviewCookieAsWellAsTheVault`),
  and a 401 seen by a call path that does not use the session's client — today the background
  `MentionPoller` — reports through `AuthCoordinator.reportUnauthorized(_:)` into the same
  transition (unit `testA401AbortsThePollAndReportsReAuthOnce`,
  `testThePollersReportReachesTheAuthCoordinator`).
* **Sign-out clears both copies of the credential, before the network call.** The vault
  token/userID *and* the webview's `MMAUTHTOKEN` cookie are removed even when the `/users/logout`
  call fails (unit: `testSignOutClearsTheCredentialEvenWhenTheServerCallFails`,
  `testSignOutWithoutALiveSessionStillClearsTheStoredCredential`, plus a real
  `WKWebsiteDataStore` test that the removal touches only that server's store). Since T31-R the
  local clear is **synchronous and first** (`beginSignOut`), the revocation after it
  (`finishSignOut`) authenticates with the token that was just discarded: a kill during the
  3-attempt/30 s logout window can no longer leave a usable Keychain token for a removed server
  (unit `testSignOutClearsTheVaultBeforeTheLogoutCallCompletes`,
  `testBeginSignOutIsSynchronousAndStillRevokesWithTheDiscardedToken`).
* **`restoreAll` is idempotent** — a resolved server is not re-validated every time the server list
  changes (unit: `testRestoreAllIsIdempotentAndSkipsResolvedServers`).

## 4. The screens (upstream parity)

| Our screen | Upstream | Behaviour kept |
|---|---|---|
| `AuthSurfaceView` header | `login/index.tsx` | server name as the heading, host underneath (so the reader can tell two servers apart) |
| `LoginView` | `login/form.tsx` | Email-or-username + Password, `Log In` disabled until both are non-empty, ``login_id.toLowerCase()` + trim before the request, the **server's own** sentence under the fields, no navigation on failure |
| `MFAView` | `mfa/index.tsx`, `mfa/shield.tsx` | shield glyph, "Enter MFA Token", the explanation, one numeric field (`oneTimeCode`), `Proceed`, "use a different account" |
| `SessionExpiredBanner` | mobile session-expiry copy | "Your session expired" + "Sign in again to <server> to continue." — the re-auth path, not a dead screen |
| Settings → **Session** | web/desktop account menu → Log out | per-server sign-out with a confirmation ("This clears the session… it does not affect messages on the server") |

`SSO` sits under the form as a second route to the same session (`login/sso_options.tsx`), and
"Use the web view instead" is the shell's documented escape hatch (`docs/dual-render.md` §8) — sign-in
is the one flow a user must never be locked out of.

## 5. The SSO hand-off (the webview stays)

`SSOView` is a sheet that hosts the app's **existing** `WebViewContainer` for that server (created by
`ViewStore.ensureStore`, already loaded by `RootView`), so the identity provider, its redirects, its
certificate and its cookie policy are handled exactly as before — `CertTrust` and the certificate
sheet are untouched.

The hand-off itself is one poll loop (`SSOViewModel.observe`): every second, ask that server's
`WKWebsiteDataStore` for `MMAUTHTOKEN` (through `SessionCookiePolicy`, T28); when a token appears,
call `AuthSession.adoptWebSession(using:)` **once**, which resolves the identity with `GET
/users/me` and stores the token in the vault. Poll budget is bounded (default 2 min) and the failure
is shown with the reason instead of spinning forever.

Covered by: `testTheCookieIsPolledUntilTheSessionAppearsAndThenAdoptedOnce`,
`testAnAlreadySignedInWebviewIsAdoptedOnTheFirstPoll`,
`testARejectedCookieFailsWithTheReasonInsteadOfSpinning`,
`testTheHandOffGivesUpAfterThePollBudget`, `testRestartRearmsTheHandOff`, and
`testAdoptingTheWebviewSessionSignsTheServerIn` at the coordinator level. **Not** covered: the sheet
against a real identity provider (§11).

## 6. Acceptance criteria → evidence

| Criterion | Evidence |
|---|---|
| Login works | `testSignInStoresTheSessionAndFlipsTheGate` (unit) + `testRealServerSignInThenRelaunchRestoresTheSession` (live server, screenshot `t31-21`) |
| Wrong password | inline server sentence: unit `testWrongPasswordKeepsTheUserOnTheFormWithTheServersSentence`, `testWrongPasswordWithoutAServerSentenceFallsBackToTheMobileCopy`; UI `testRejectedPasswordIsAnInlineErrorOnTheNativeForm`; **live** `testRealServerRejectsAWrongPasswordWithItsOwnSentence` (screenshot `t31-20`) |
| MFA required / MFA wrong code | unit `testMFARequiredMovesToTheSecondStepAndVerifiesWithTheSameCredential`, `testWrongMFACodeStaysOnTheSecondStepWithItsOwnMessage`, `testMFAChallengeThenSuccess`; UI `testMFAChallengeThenAcceptedCodeSignsIn` (screenshots `t31-03`, `t31-04`) |
| Network failure | unit `testNetworkFailuresProduceTheirOwnCopy` (offline / timeout / transport / untrusted certificate) and `testAnUnreachableServerKeepsTheStoredSessionAtLaunch` |
| No credential logged, and none written outside `SecureVault` **on the native path** | `testAWholeSignInAttemptWritesNoCredentialToALogLine` (captures every `os_log` line of a full sign-in and asserts neither the password nor the token appears), `testPasswordNeverAppearsInTheModelsOwnDescription`; the token is read back from the vault; `scripts/t28-token-grep.sh` still applies to the tree. **Scoped wording (T31-AV F4):** a session established *in the webview* (SSO, or the pane's own login) keeps WebKit's `HttpOnly` `MMAUTHTOKEN` cookie in `Library/WebKit/…/WebsiteDataStore/<id>/Cookies/Cookies.binarycookies`. That is a second, deliberately separate store — the webview is the IdP's own session and page JS cannot read the cookie — and the native path never writes it. Both copies are cleared on sign-out, and since T31-R on expiry as well (see §3). No credential is ever written to `UserDefaults`, a log line, or the app container by native code (T31-AV re-verified: 0 hits for the fixture password/`stub-token-native`/`stub-token-mfa` in the container, the plists, 5 crash files, the simulator log or the host log). |
| Relaunch restores without a login prompt | unit `testRestoreResolvesASignedInSessionWithOneIdentityCall`; UI `testRealServerSignInThenRelaunchRestoresTheSession` (relaunch with no reset, screenshot `t31-22`); revoked case `testRevokedStoredSessionShowsTheSessionExpiredBanner` (screenshot `t31-05`) |
| A 401 surfaces one re-auth path | unit `testA401OnALiveSessionTurnsTheGateToReauthWithoutAnyScreenInvolved`, `testARejectedStoredTokenExpiresTheSessionAndClearsTheCredential`; UI `testRevokedStoredSessionShowsTheSessionExpiredBanner` |
| SSO does not regress | the shipped `testSSOReachesIdentityProviderWithoutCertificatePrompt` and the 8443 certificate tests run unchanged in the full UI suite (§13); the SSO sheet reuses the same `WebViewContainer`/`CertTrust` code |
| Screens render real server data | `docs/t31-shots/t31-20`, `t31-21`, `t31-22` (§7) |

## 7. Evidence run against a real server

A throwaway local `mattermost` server (`http://127.0.0.1:8065`) seeded by `scripts/perf_seed.py`
(the probe account it creates is `perfprobe`, whose password is already committed in that script —
no real workspace URL or secret was used):

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<from scripts/perf_seed.py> \
TEST_RUNNER_MM_AUTH_SHOT_DIR=$PWD/docs/t31-shots \
xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
  -destination "platform=iOS Simulator,id=<iPhone 17 Pro / iOS 26.5>" \
  -only-testing:MattermostUITests/MattermostUITests/testRealServerRejectsAWrongPasswordWithItsOwnSentence \
  -only-testing:MattermostUITests/MattermostUITests/testRealServerSignInThenRelaunchRestoresTheSession
```

Result: `** TEST SUCCEEDED **`, 2 tests, 0 failures (11.6 s and 22.2 s).

| Screenshot | What it proves |
|---|---|
| `docs/t31-shots/t31-20-real-server-rejection.png` | the form posts to the real server and prints **its** sentence ("Enter a valid email or username and/or password.") for a user that does not exist — not a local check |
| `docs/t31-shots/t31-21-real-server-signed-in.png` | a real password sign-in lands on the native shell, titled with the real server name |
| `docs/t31-shots/t31-22-real-server-restored.png` | after `terminate()` + relaunch with **no** reset and no seeded token, the shell comes up signed in; the test then waits 6 s and re-asserts that no login form and no expiry banner appeared, i.e. the restore call really was accepted |

Fixture screenshots (stub server, labelled as such because a real server on this host has no MFA
enrolled and no revoked session to show): `t31-01` sign-in, `t31-02` rejection, `t31-03`/`t31-04`
MFA rejected/accepted, `t31-05` expired banner, `t31-06`/`t31-07`/`t31-08` Settings session row,
confirmation, signed-out result.

## 8. Defects found while verifying (and what fixes them)

1. **A rejected MFA code wiped its own error message.** `MFAViewModel` clears the code after a
   refusal (so it cannot be resent), and the field's `.onChange` called `clearError()` — so the
   error vanished in the same render pass. The unit test could not see it (no view); the UI test
   did. Fixed by clearing the error only on *typing* (`if !newValue.isEmpty`), in both forms, and
   the UI test now asserts the message **and** that the field is empty.
2. **The heading was drawn under the shell's floating navigation bar** (`t31-20` was the screenshot
   that showed it: the server title and the app glyph sat behind the toolbar pill). A `ScrollView`
   under `SurfaceHost` is not the navigation stack's primary scroll view, so it receives no content
   inset, and the scene is laid out edge to edge. Fixed structurally: the sign-in screen hides the
   navigation bar (upstream's login screen has no switcher/settings chrome either) and reserves the
   status-bar inset read from the window (`statusBarInset`), so no bar height is hard-coded.
3. **The server heading was repeated above the MFA step**, pushing the numeric keypad into it.
   Now the token form is the whole screen, as upstream's `mfa/index.tsx` is.

## 9. Tests added

`MattermostTests/T31-AuthTests.swift` — **37 tests when T31 landed** (counts as the runner executed
them; the earlier version of this note said 13/8/14, which was wrong — T31-AV F6):

* `T31LoginViewModelTests` (**12**): field rules, lowercased id, server sentence vs. fallback copy,
  MFA hand-off, MFA retry, offline/timeout/transport/certificate copy, empty submit, error clearing,
  back-from-MFA, redacted description, and the whole-flow log capture.
* `T31MFAViewModelTests` (**2**): local empty-code refusal, accepted code reports the session.
* `T31SSOViewModelTests` (**7**): poll-until-token, already-signed-in, rejected cookie, poll budget,
  restart, status-line navigation, and a real `WKWebsiteDataStore` cookie-clearing test.
* `T31AuthCoordinatorTests` (**16**): optimistic gate, restore success/rejection/offline, idempotent
  `restoreAll`, fresh server, sign-in, failed login is not an expiry, MFA challenge, 401 on a live
  session, webview adoption, sign-out (live / failed network / no session), certificate decisions.

Total **37**, which is the number the T31 card declared (the per-class split above is the corrected
one).

T31-R (the AV repair) added **13** more in the same file, now 50:

* `T31AuthCoordinatorTests` (+6): expiry clears the webview cookie (`…ExpiryClearsTheWebviewCookie…`),
  a 401 on a non-restore call clears both copies, sign-out clears the vault before the logout call
  returns, `beginSignOut` is synchronous and still revokes with the discarded token, a reported
  (non-client) 401 expires the session, a stale 401 report raises no banner.
* `T31LoginErrorCopyTests` (+4): every `LoginErrorCopy` branch the AV finding named
  (`rateLimited`/`forbidden`/`notFound`/`server`/`client`/`malformedResponse`/`notSignedIn`/
  `invalidURL`/`cancelled`), the server-sentence-wins branches, a non-`MMError` fallback, and one
  table row proven through the form.
* `MattermostTests/MentionPollerTests` (+3): a 401 aborts the poll and reports once, a nested
  401 is not swallowed by the per-team tolerance, and the poller's report reaches
  `AuthCoordinator.reportUnauthorized` (the wiring `MattermostApp` installs).
* `SurfaceModeResolverTests`/`ViewStoreTests`: updated where they encoded "the registry is empty"
  (`testOnlyTheApprovedRegistryDefaultsToNative`, the release-unreachable loop), plus the UI
  fallback test `testTheAuthStandInIsStillReachableThroughTheSurfaceFlag`.

`MattermostUITests/MattermostUITests.swift` — 7 tests: 5 against the auth stub
(`build/uitest-server/mm_stub.py --port 8114`, `--session-invalid` on `:8115`) and 2 network-gated
against a real server.

## 10. Deliberate decisions

1. **`SurfaceHost(.auth)`'s web branch is the existing T30 stand-in**, not a webview. The surface
   that "resolves web" for auth is the placeholder that names the card and offers the pane escape
   hatch, so the flag-off path is byte-for-byte T30-R and its assertions keep their meaning.
2. **`.toolbar(.hidden, for: .navigationBar)` on the native branch only** (§8.2). The shipping
   branch keeps the chrome; the native branch has none, matching upstream's login screen.
3. **DEBUG seams** (`MattermostApp`, `#if DEBUG` only): `-uiTestSeedServerName <name>`,
   `-uiTestSeedStoredToken <token>`, and `-uiTestForgetSession <url>` (added here: without it a
   suite that signs in once starts every later test signed in, because the gate trusts the vault
   before the network — which is the behaviour we want and an inconvenient one for tests).
4. **Removing a server signs it out.** `ServerStore.remove` never touched the vault, so a removed
   server's token stayed in the Keychain and a later re-add of the same URL would silently inherit
   it. Settings' remove action now calls `signOut` first (best effort over the network, guaranteed
   locally).
5. **Error copy = the server's sentence when it sends one**, else a Mattermost sentence written in
   our own file (`LoginErrorCopy`), so an operator who customises server messages sees their own
   words (mobile does the same).

## 11. Limits — not claimed

* The **SSO sheet is not UI-tested end to end**: it needs a live identity provider. Its machine is
  unit-tested (7 tests), it reuses the webview path that the shipped SSO UI test still guards, and
  the shipped certificate/SSO tests are unchanged and green — but nobody has driven the sheet
  through a browser yet. (T31-R re-stated this; nothing on this host can close it — the local server
  reports `EnableSaml:false` and every OAuth provider false.)
* The MFA and expired-banner screenshots are fixture runs (§7); the local server used here has no
  MFA enrolled and no revocable stored token for a screenshot.
* A session established **in the webview** (e.g. the user signs in through the pane's webview) is
  adopted on demand — via the SSO sheet or the next native sign-in — not continuously. Continuous
  adoption would mean polling another screen's cookie store for the app's lifetime; that is the
  pane-mode question T31-AV should decide with the surface approval.
* Only one server is exercised by the UI tests (the seeding seam adds one); multi-server sign-out is
  covered at the coordinator/unit level.
* **No Catalyst screenshot of the auth surface.** The views and the whole unit suite run on Catalyst,
  but the `-authSurfaceSnapshot` probe photographs a `UIWindow`, so the captures in `docs/t31r-shots/`
  are iOS (iPhone + iPad) only. Recorded rather than implied.
* **Dynamic Type AX3 / dark mode / iPad regular width are captured for the sign-in screen only**
  (`docs/t31r-shots/auth-surface-*.png`), not for the MFA step or the expired banner: those states
  need a scripted transition the capture probe does not drive, and the fixture screenshots in
  `docs/t31-shots/` still show them in the default appearance.
* `AuthCoordinator` keeps one `AuthSession` per server for the app lifetime; removing a server does
  not evict the object (it is left `.signedOut`). Harmless today, worth revisiting when the
  coordinator grows foreground-refresh work.

## 12. Files touched, and what is shared

New (this card): `Mattermost/UI/Native/Auth/{AuthCoordinator,LoginViewModel,MFAViewModel,MFAView,LoginView,SSOView,SSOViewModel}.swift`,
`MattermostTests/T31-AuthTests.swift`, `docs/t31-build-note.md`, `docs/t31-shots/*.png` (11),
`docs/parity.md` (T31 row + status), `docs/THIRD_PARTY_NOTICES.md` (§8),
`build/uitest-server/mm_stub.py` (auth fixtures for `:8114`/`:8115`).

Shared files edited (small, surgical — flagged for merge order per `docs/parallel-work.md`):

| File | Edit |
|---|---|
| `Mattermost/MattermostApp.swift` | `AuthCoordinator` state object, two `environmentObject`s, gate binding in `bindShellStores`, `restoreAll` in the launch task, three DEBUG seams |
| `Mattermost/UI/Native/NativeShellView.swift` | one call site: the auth branch renders `AuthSurfaceView(server:coordinator:)`; one `@EnvironmentObject` |
| `Mattermost/UI/SettingsView.swift` | Session section, sign-out confirmation, remove-signs-out |
| `MattermostUITests/MattermostUITests.swift` | 7 tests appended (+1 assertion helper) |

`Mattermost.xcodeproj/project.pbxproj` was **not** touched: the native UI and test trees are
synchronized folders since T30b, and `scripts/verify-dual-render-gates.sh` still passes (§13).

One repo-hygiene change, recorded because it is a deliberate exception: `build/` is gitignored, and
`build/uitest-server/mm_stub.py` — the stub **every** UI test in this repo runs against, including
shipped T26/T30 tests — had never been tracked, so a clean checkout (and a validator's detached
worktree) could not run them at all. This card's UI tests depend on the auth fixtures added to that
file (§13), so it is committed with `git add -f build/uitest-server/mm_stub.py`. Nothing else under
`build/` is tracked; future edits to the stub need the same `-f`.

## 13. Reproduce

```bash
# auth stubs (two ports: accepted sessions, and sessions the server rejects)
python3 build/uitest-server/mm_stub.py --port 8114 --name "Auth Test Server" &
python3 build/uitest-server/mm_stub.py --port 8115 --name "Auth Test Server" --session-invalid &

# unit suite (Catalyst) — includes the 37 T31 tests
scripts/qa-test.py --platform mac --label t31-unit

# the 5 auth UI tests (fixture)
xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
  -destination "platform=iOS Simulator,id=<sim>" \
  -only-testing:MattermostUITests/MattermostUITests/testNativeSignInSurfaceIsAFormNotAWebview \
  -only-testing:MattermostUITests/MattermostUITests/testRejectedPasswordIsAnInlineErrorOnTheNativeForm \
  -only-testing:MattermostUITests/MattermostUITests/testMFAChallengeThenAcceptedCodeSignsIn \
  -only-testing:MattermostUITests/MattermostUITests/testRevokedStoredSessionShowsTheSessionExpiredBanner \
  -only-testing:MattermostUITests/MattermostUITests/testSignOutFromSettingsReturnsToTheSignInSurface

# the real-server pair: see §7 (env-gated; skipped without TEST_RUNNER_MM_AUTH_*)

# gates
scripts/verify-dual-render-gates.sh
```

Final sweep on this host (iPhone 17 Pro / iOS 26.5 simulator, Catalyst 26.5):

| Run | Result |
|---|---|
| `scripts/qa-test.py --platform mac` (whole `MattermostTests`) | **642 run, 4 skipped, 0 failed** — `RESULT: PASS` (T31; **655** after T31-R) |
| `scripts/qa-test.py --platform ios --only-testing MattermostUITests` | **23 run, 3 skipped, 0 failed** — `RESULT: PASS` (T31; **24** after T31-R's new stand-in test) |
| real-server pair (§7) | **2 run, 0 failed** — `** TEST SUCCEEDED **` |
| `scripts/verify-dual-render-gates.sh` | **RESULT: PASS** (gates 1–10) — as of T31-R the plain run fails gate 5 *because* the surface is approved; `--allow-approved-registry` is the approval audit (`docs/t31r-patch-note.md` §10.3) |
