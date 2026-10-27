# T31 (follow-up) — harvesting the webview's session for the native stack

Card: **t_ce572781** — "Native session after webview SSO: harvest the token so native surfaces see
the signed-in user".

## 1. The defect, stated as the user meets it

Path A ships the Mattermost SPA in a `WKWebView`, and the sign-in that ships with it runs **there**:
the SPA's own login form, or the SSO/SAML hand-off that the card scope deliberately keeps in the web
surface. Both authenticate by answering with an `HttpOnly` `MMAUTHTOKEN` cookie in *that server's*
isolated `WKWebsiteDataStore`.

Everything after that is native, and every native surface authenticates from the **vault**, through
`AuthSession.client`. Nothing joined the two:

* `AuthCoordinator.restore` asked the vault for a token, found none, and resolved the server
  `.signedOut`;
* `NativeShellView.showsAuthSurface` therefore rendered `AuthSurfaceView` — the native sign-in screen —
  for a user who was plainly signed in, in the very same process;
* and even when a native surface was forced on screen (`-surfaceMode sidebar=native`, the `-AV`
  harness), its requests were unauthenticated, so the rail and channel list sat on
  "Loading channels…".

So the app held two disagreeing answers for one login. The card's ask: harvest the cookie, or hand off.
This note is the harvest.

## 2. What changed

### 2.1 `Mattermost/UI/Native/Auth/AuthCoordinator.swift`

* **`restore(_:)` now has four explicit outcomes, in this order** (and the order is the contract):

  1. the vault's token is accepted → `.signedIn`;
  2. the vault's token was **rejected** → the one expiry transition (`requireReauth`);
  3. the vault held **no** token but the webview holds one → **adopt it**;
  4. neither → `.signedOut`.

  `adoptExistingWebSessionIfPresent` is the new step 3. It calls the existing
  `adoptWebSession(_:using:)` (T31), which reads the `MMAUTHTOKEN` through
  `SessionCookieReading`, verifies it with an authenticated `GET /api/v4/users/me`, persists it to the
  vault and sets the phase. Because the phase change goes through `setPhase`, the shell's `onChange`
  fan-out runs: `nativeNavigation.refreshAuthState()`, the rail/channel-list/pane `authPhaseChanged`,
  and the gate flips to `.signedIn` — which is what replaces the sign-in surface with the workspace.

* **Step 2 comes before step 3 on purpose.** Both copies of the credential are the same login, and
  the expiry transition clears the cookie copy (`T31-AV F1`). Adopting *after* a rejection would race
  that clear and could set the phase back to `.signedIn` on the token the server has just refused.
  The unit test for this uses a **token-aware** transport — the cookie's token *would* be accepted —
  so the test cannot pass by accident (§3, mutation B).

* **`restore` now returns the adopted session** when it adopted one. It used to return `nil` on that
  path (`restored` was the vault-restore result), which made "the sign-in on this path" invisible to
  a caller. `@discardableResult`, so no existing call site changed.

* **`cookieReader:` is an injected seam** (`(UUID) -> SessionCookieReading`), defaulting to
  `WebKitSessionCookieReader(serverID:)`. Two reasons: a webview's cookie store is
  container-scoped and cannot be populated from a test runner's process, and the *wiring* — "read
  **this server's** store, never WebKit's `.default()` one" — is itself a claim worth pinning
  (§3, mutation C). There is still no initializer without a store: `WebKitSessionCookieReader` keeps
  its no-default rule.

### 2.2 `Mattermost/MattermostApp.swift` (DEBUG only)

* `-uiTestSeedWebSessionCookie <token>`: plants an `MMAUTHTOKEN` in the **seeded** server's
  `WKWebsiteDataStore(forIdentifier: server.id)` — the store `ViewStore.ensureStore(for:)` gives that
  server's webview, i.e. the exact copy a webview sign-in leaves. It runs inside the root `.task`
  immediately **before** `authCoordinator.restoreAll(...)`, so the launch under test reads what a real
  webview login would have written, with no window in which the two disagree.
* Why a seam rather than typing into the SPA's login form from the test: the cookie store is
  container-scoped (a runner writing it writes a different container), and driving the web app's
  markup from the shell's test suite would make the evidence depend on the thing this shell does not
  own.
* Same shape and same DEBUG-only gating as `-uiTestSeedStoredToken`: it adds a credential the caller
  already holds, never logs the value, and does nothing unless both the argument and a seeded server
  are present.
* The pre-existing diagnostic-probe hunks from the earlier attempt on this card were kept: the
  `-shellSnapshot` probe now writes `path.window.png` and an `auth=<phase>:token=<bool>` line even
  when no webview committed, because a native pane has no committed webview and the old probe
  returned silently — which is exactly how this defect looked like "no evidence" for two rounds.

## 3. Unit tests — `MattermostTests/T31WebSessionHarvestTests.swift` (7 tests)

| Test | The claim |
|---|---|
| `testRestoreAdoptsAWebviewOnlySessionAndAuthenticatesTheNativeTransport` | empty vault + cookie → `.signedIn`, the token is in the vault, and the identity call itself carried `Authorization: Bearer <cookie token>` |
| `testTheHarvestSurvivesARelaunchWithNoWebviewSessionLeft` | after adoption the **vault** is the source of truth: a second coordinator with no cookie restores signed in |
| `testNoVaultTokenAndNoWebviewSessionResolvesSignedOutWithoutTouchingTheServer` | an anonymous launch fires **no** unauthenticated `/users/me` |
| `testARejectedWebviewCookieLeavesNoCredentialAndNoSession` | a refused cookie leaves no token and no session |
| `testARejectedVaultTokenExpiresEvenWhenAWebviewCookieWouldBeAccepted` | the ordering: rejection expires, the cookie store is never consulted |
| `testTheExpiryOfARejectedVaultTokenAlsoClearsTheWebviewCookie` | …and that expiry still drops the webview copy (T31-AV F1) |
| `testTheProductionReaderFindsTheSessionInTheServersOwnWebsiteDataStore` | with **no** `cookieReader:` argument (the app's construction) the reader finds a cookie planted in `WKWebsiteDataStore(forIdentifier: server.id)` |

### 3.1 Mutations (each run, each red)

| Mutation | Result |
|---|---|
| **A** — harvest branch removed from `restore` (`if false, let adopted = …`) | 3 tests red by name: the two adoption tests and the production-reader test (`build/logs/t31harvest-mutA.log`) |
| **B** — adoption moved *before* the `needsReauth` branch | exactly 1 test red: `testARejectedVaultTokenExpiresEvenWhenAWebviewCookieWouldBeAccepted` (`build/logs/t31harvest-mutB.log`) |
| **C** — production reader pointed at `WKWebsiteDataStore.default()` | exactly 1 test red: `testTheProductionReaderFindsTheSessionInTheServersOwnWebsiteDataStore` (`build/logs/t31harvest-mutC.log`) |

## 4. Live evidence — a real Mattermost server, no stubs

`MattermostUITests/T31WebSessionHarvestUITests.swift` (2 tests, env-gated like every live suite here).
The fixture is the local throwaway server (`http://127.0.0.1:8065`, account `perfprobe`); the token
comes from the server's own `POST /users/login`, and the channel ids the test expects to see are read
back from `/api/v4/users/me/teams/{id}/channels`.

Launch under test (one process, one launch):

```
-uiTestResetPersistedState -uiTestForgetSession <server>          # the vault holds nothing
-uiTestSeedServer <server>
-uiTestSeedWebSessionCookie <token minted by the server>          # the ONLY credential
-surfaceMode shell=native -surfaceMode auth=native -surfaceMode sidebar=native
-surfaceMode channelView=native -surfaceMode threads=native -surfaceMode composer=native
```

Assertions: `nativeShell` exists; `nativeAuthSurface` does **not**; no `loginIDField`; the rail
(`nativeTeamSidebar`) is loaded; the server's channel grouping is on screen; and at least one
rendered `channelSidebar.channel.<id>` is an id the server says this account belongs to.

```
run        : t31harvest-clean-live2
outcome    : finished (xcodebuild rc=0, 23s)
tests      : 2 run, 0 skipped, 0 failed
RESULT: PASS
```

(An earlier identical run on the shared checkout — `t31harvest-live7`, 2 run / 0 failed — produced the
two PNGs below; the run above is the canonical one, taken on an isolated worktree of this change set.)
Logs: `build/logs/t31harvest-live-clean.log`.

Evidence: `docs/t31harvest-native-workspace.png` (the native workspace: rail `PE`, team `Perf`,
channels `T35 Composer`, `T36 Threads`, …) and `docs/t31harvest-control-auth-surface.png` (the
control).

**The negative control** (`testWithoutAWebviewSessionTheSameLaunchStillAsksForSignIn`) is the same
launch *without* the cookie: it must show `nativeAuthSurface` and must not draw `nativeShell`. Without
it, the green above could not tell "the harvest worked" from "the gate never asked".

**The live red case**: mutation A re-run against the same live suite —

```
run        : t31harvest-live-mutA
failed     : testAWebviewOnlySessionRendersTheNativeWorkspaceWithoutSigningInAgain
             XCTAssertTrue failed - a webview-signed-in launch must render the native workspace
control    : testWithoutAWebviewSessionTheSameLaunchStillAsksForSignIn  → passed
log        : build/logs/t31harvest-live-mutA.log
```

so the live oracle really does isolate the harvest, and the control is insensitive to it.

## 5. Whole-suite runs

```
run        : t31harvest-clean-full-units     (worktree of 5ccbb5d + exactly this change set)
tests      : 1621 run, 6 skipped, 0 failed   → PASS
log        : build/logs/t31harvest-full-units-clean.log

run        : t31rebase-full-units            (rebased onto dd2f80b = origin/main tip)
tests      : 1626 run, 6 skipped, 1 failed   → testCallEndedEndsTheSurfaceAndReleasesTheCoordinator

run        : head-full-units                 (dd2f80b, **no** change from this card)
tests      : 1619 run, 6 skipped, 1 failed    → testCallEndedEndsTheSurfaceAndReleasesTheCoordinator
```

The one red in the last two runs is **pre-existing and not this card's**: the same test, with the same
message (`timed out waiting for ended`), fails in a whole-suite run of untouched `origin/main` and
passes when run alone. Details in §6. Durable copies of the runner output:
`docs/t31harvest-full-units-2026-10-27.log` (the 0-failed run) and
`docs/t31harvest-head-baseline-full-units-2026-10-27.log` (untouched tip, same single failure).

All three runs were taken in `git worktree` copies rather than the shared checkout, because the shared
checkout was being written by another card while this one ran (§6).

## 6. Two things seen while running this card

* **The shared checkout is not exclusive.** While this card's first full-suite run was in flight,
  `Mattermost/UI/Native/Composer/ComposerModels.swift`, `ComposerView.swift` and
  `MattermostTests/T35ComposerModelsTests.swift` changed under it (11:25), and a `git cherry-pick`
  was left in progress in the same worktree. Every number in §3–§5 therefore comes from an isolated
  worktree, and this card's commit stages only its own paths. Any card that edits this checkout
  concurrently can produce a build containing neither party's intent.
* **`T44DCallsCoordinatorTests.testCallEndedEndsTheSurfaceAndReleasesTheCoordinator` is flaky in a
  whole-suite run — on the untouched tip as well.** Measured this session: red in `t31harvest-clean-full-units`'s
  predecessor, red in `t31rebase-full-units`, red in `head-full-units` (no changes at all), green when
  the class or the single test runs alone, twice in a row. Its `waitUntil` budget is 3 s on a
  `call_end` event, so it is timing-sensitive under load. It is not caused by this card (the test
  never constructs an `AuthCoordinator`), but it currently makes "whole suite green" unreachable
  without ignoring it — it wants a longer budget or a fake clock, as its own card.

## 7. What this does *not* do (deliberately)

* **It does not flip any surface to native by default.** `SurfaceDefaults.nativeApprovedSurfaces` is
  still `[.auth, .calls]`; the runs above force the surfaces with `-surfaceMode`, which is DEBUG-only.
  Turning the workspace native for users is its own card (`t_c93b8337`), gated on its own `-AV`.
* **It does not observe a webview login that happens while the app is already running.** The two
  moments that matter are covered — launch/relaunch (`restore` → harvest) and the in-app SSO sheet
  (`SSOView` polls the same cookie and calls the same `adoptWebSession`) — but a sign-in performed in
  the *web pane* of a running process still waits for the next launch/restore. Adding a foreground
  re-attempt is cheap but changes when an unauthenticated `/users/me` is sent, so it belongs with a
  card that can argue about the request budget.
* **It does not change the socket or the panes.** They already resolve their client from
  `authCoordinator.session(for:)` per call (`SessionTeamSidebarService`), so once the phase is
  `.signedIn` they authenticate with the harvested token — which is what the live run shows.
