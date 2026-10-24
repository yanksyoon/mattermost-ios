# T30 build note — native app shell: team/channel navigation skeleton behind the dual-render flag

Card: `t_e860ef43` (T30). Upstream reference: `mattermost/mattermost-mobile` @
`162f2560d0e1df073220f7701d5a67cc17c8abeb` (v2.45.0). Attribution: `docs/THIRD_PARTY_NOTICES.md` §7.

Every new file carries a `Behaviour reference:` header naming the upstream files it was written
against. Nothing was transpiled: the RN sources are TypeScript, the ports are Swift written to the
REST/URL contract.

---

## 1. What shipped

New (3 files + 1 test file + 1 script):

| File | Lines | What it is |
|---|---|---|
| `Mattermost/Core/Native/NativeNavigation.swift` | 634 | the navigation model: `NativeLocation`, `NativeTarget`, deep-link path parsing, the single routing funnel, per-server last location, the auth gate seam (T30-R added `opensADestination`, `activateIfRouting`) |
| `Mattermost/UI/Native/NativeShellView.swift` | 154 | the shell: phone composition (TabView: Channels / Threads, channel view = push) and regular-width composition (NavigationSplitView: sidebar beside the detail); the signed-out state is its own top-level branch with its own identifier (T30-R, F2) |
| `Mattermost/UI/Native/NativePanePlaceholders.swift` | 404 | every not-yet-ported region as an honest placeholder plus the empty destination, the stale-route error state and the auth surface |
| `MattermostTests/NativeNavigationTests.swift` | 663 | 33 unit tests (parsing table, the funnel's two convergence shapes, channel-less destinations, the appearance gate, multi-server, auth gate, both routing seams) |
| `scripts/t30-shell-footprint.sh` | 116 | the "does the shell cost more than the webview it replaces" measurement (§8.4) |

Modified (surgical):

| File | Change |
|---|---|
| `Mattermost/UI/RootView.swift` | `NavigationStack(path:)` bound to `NativeNavigation.path` (compact only), `navigationDestination`, chrome re-declared on pushed panes (`shellToolbarItems`), `.web` transition pops the native stack, `activate(_:)` follows the switcher, `startUp()` no longer overrides a route that already landed |
| `Mattermost/MattermostApp.swift` | owns `NativeNavigation`; `bindShellStores()` (the fix for defect §9.1); `-uiTestSeedServer`, `-uiTestAssumeSignedIn`, `-uiTestOpenDeepLink`, `-nativeShellSnapshot` seams; snapshot environment modifier |
| `Mattermost/Core/DeepLinkRouter.swift` | while the pane is native, the *same parsed* `DeepLink` goes through `NativeNavigation` instead of the SPA push |
| `Mattermost/Core/NotificationWorker.swift` | `routeToChannel` (a tapped mention) diverts into the native funnel when the pane is native |
| `Mattermost/Core/RenderMode.swift` | `SurfaceDefaults.paneHostSurface` documented as the surface whose native branch replaces the webview |
| `Mattermost/Core/SurfaceModeResolver.swift` | `shell` alias → `paneHostSurface`; malformed `-surfaceMode` specs rejected instead of half-applied |
| `Mattermost/UI/ErrorStateView.swift` | optional `title`/`detail` overrides (defaults unchanged) so the native pane can reuse the app's one error screen with honest copy |
| `Mattermost/UI/ContentView.swift` | passes the native-navigation handle through the pane host |
| `MattermostTests/SurfaceModeResolverTests.swift` | +1 test: the `shell` alias resolves to the pane surface, and an unknown surface name stays `.web` |
| `MattermostUITests/MattermostUITests.swift` | the 5 T26 assertions that named `unportedSurface.channelView` now name `nativeShell` (the pane's native card changed); +2 T30 UI tests |
| `Mattermost.xcodeproj/project.pbxproj` | 4 file references, 4 build files, 2 groups (the project has no synchronized folders — new files must be registered by hand) |

---

## 2. The decision the card asked for: drawer, tab, or push (phone)

Scope §1 asked for a `NavigationSplitView`/`TabView` hybrid and an explicit decision for a phone.
Decision, taken from upstream's own phone composition (`channel_list.tsx` + `tab_bar/index.tsx`):

* **phone (compact width): the sidebar is a *tab*, the channel view is a *push*.**
  Upstream's phone client has a bottom tab bar whose first tab is the channel list; opening a channel
  pushes a screen whose Back returns to the list. A drawer would be a second, invented navigation
  language in an app that is otherwise UIKit-standard, and it would fight the system edge-swipe that
  the shell already relies on for webview history.
* **regular width: `NavigationSplitView`** — sidebar beside the detail column, no push. Same
  `NativeLocation` drives both, so rotating from compact to regular pops the push but keeps the
  selection (`docs/dual-render.md` §3 on state surviving a layout change).

Consequence, and the reason `apply(_:)` exists: a route must be able to land as a *push* on a phone
and as a *detail* on iPad without the caller knowing which. That is why the model owns `path` and why
`RootView` binds the stack to `$navigation.path` on compact width only (`.constant([])` on regular).

Tabs: `NativeTab.channels` / `.threads` — upstream's `tab_bar/index.tsx` order, minus the tabs whose
screens do not exist yet (no empty tabs are shown; a placeholder tab is worse than no tab).

---

## 3. Routing: one funnel, three entry points

`NativeNavigation` has exactly one writer of `location`/`path` — the private `apply(_:)`. Deep links,
notification taps and manual taps all funnel through `open(_ target:)` → `apply`. `apply` deliberately
does **not** touch `tab`: a tab is a user destination, not a routing result, so a deep link that lands
on a channel must not move the tab bar under the user's finger.

Entry points, and what changed in each:

1. **Deep link** `mattermost://<server>/<team>/channels/<name>` — `DeepLinkRouter.route` parses once
   (unchanged) and, while `NativeNavigation.acceptsNativeRouting` (i.e. the pane host surface resolves
   `.native` *right now*), hands the same `DeepLink` to `NativeNavigation.handle`. The web path is
   untouched: flip the pane back to `web` and the SPA push resumes with no stale flag, because the
   check is made at call time.
2. **Notification tap** — `NotificationWorker.routeToChannel` (desktop `NotificationManager` parity)
   does the same diversion for a tapped mention.
3. **Manual** — the sidebar/placeholder rows call `openChannel` / `openThreads` directly.

Path grammar (`NativeNavigation.target(forPath:)`) is upstream's (`app/utils/deep_link/index.ts`):
`/{team}/channels/{name|id}[/{post}]`, `/{team}/messages/@{user}`, `/{team}/pl/{post}`,
`/{team}/threads/…`, `/{team}`, `/`. A 26-char `[a-z0-9]` segment is an *id*, anything else is a
channel *name* (`isValidID`, upstream's `isValidChannelId` rule). Anything else returns `nil` and the
router reports `.ignored` instead of guessing — a native shell that silently mis-routes is worse than
one that says "I cannot show this yet".

**Convergence — what is true, exactly** (corrected in T30-R, finding F1): the three entry points go
through **one funnel** (`open` → `apply`, the only writer of `location`/`path`), and they agree on the
**server and the pane**. They do *not* agree on the channel's identity in the configuration that
ships today, and this note used to claim otherwise:

* in the shipping configuration `NativeNavigation.directory` is `nil` (it is installed by the channel
  list, S08/T32-T33), so a deep link (`/acme/channels/general` — a team *name* and a channel *name*,
  no ids) and a tapped mention (`channelID: c1`, `teamID: t1`, no names) produce locations that are
  equal in `serverID`/`serverName`/`pane` and different in `teamID`/`teamName`/`channelID`/
  `channelName`. The former claim "they agree on server, team and pane" was wrong about the team;
* convergence **to one identical `NativeLocation`** is a property of the funnel *once a directory
  resolves both name→id and id→name* — `NativeNavigationTests.
  testConvergenceHoldsOnceADirectoryResolvesNamesAndIDs` proves it with an injected directory, which
  is exactly why the earlier note could not be checked against the shipping app;
* the honest shipping-configuration assertion is
  `testDeepLinkAndMentionAgreeOnServerAndPaneWithoutADirectory`: same server, same pane, different
  channel/team keys, and `XCTAssertNotEqual` on the locations so that the day a directory lands the
  test fails and the claim is upgraded rather than the gap quietly forgotten.

The card's acceptance criterion "a deep link and a tapped mention land on the right server + channel
in the native stack" is therefore met **at server + pane level** today and at full-location level only
with a directory. T30-R rewrote the claim in the code docs, this note and `docs/parity.md` instead of
leaving a test whose green depended on a test double.

### 3.1 Auth gate (scope §2)

`NativeNavigation.authGate` is `VaultAuthGate`: `SecureVault.getSecret(.authToken)` for that server
means signed in; a server with no stored session shows `NativeAuthPlaceholderView` instead of panes.
That surface is not a fake login form: native login/MFA/SSO is S01–S03 (**T31**), so it explains the
gap and offers the way to a real session (the escape hatch, §6).

**Known consequence, stated rather than hidden:** a server that is signed in *in the webview* (Path A
today) has no `AuthSession` token, so a debug `shell=native` run shows the auth surface for it. That
is correct against the model T30 binds to — and it is a real gap for a mixed-mode future, which is
why `-uiTestAssumeSignedIn` exists as a DEBUG seam and why adopting a webview session into
`AuthSession` is written up as follow-up work (T31), not silently papered over.

---

## 4. Empty / loading / error (scope §4)

* **Loading** — `NativeChannelPaneView` shows `ProgressView` for the permalink state (a URL that
  names a post but not its channel: resolving it is S12/T36), instead of guessing a channel.
* **Empty** — `NativeEmptyDestinationView`: icon + headline + one explanation, the same shape as
  `RootView.noServersState`.
* **Error** — `NativeStaleRouteView` renders the app's existing **`ErrorStateView`** (a route can
  outlive its server: the user removes the server while its channel pane is open). Reusing the one
  error screen instead of inventing a second one is why `ErrorStateView` gained optional `title` /
  `detail` overrides — the default connection-failure copy is unchanged, which the
  connection-refused UI test (`testConnectionRefusedShowsErrorState`) still proves.
* No pane is ever a blank rectangle: every unported region carries a `NativePaneNote` naming the card
  that will ship it (S08/T32, S13/T36, S11/T34 …).

---

## 5. The shell beats: layout, chrome, escape hatch

* **Chrome survives a push.** A pushed destination gets its own navigation bar, which in the first
  implementation *hid* the server switcher, Settings and Add-server behind the pushed pane — a user
  sitting in a native channel could not switch servers, which the webview pane never takes away. The
  trailing chrome was extracted to `shellToolbarItems` and re-declared on the destination
  (`RootView`), and the UI test taps Settings **from the pushed pane** to prove the sheet still
  presents there.
* **Escape hatch.** T26's guarantee — a pane that resolves native can always be returned to the
  webview without relaunching — used to live on a generic `UnportedSurfaceView` stand-in (deleted in
  T30-R as dead code, F6). Now that the shell *is* the pane's native card, the shell carries it: a
  "Use web view" row in the sidebar and the same action on the auth surface, both with the identifier
  `revertToWebchannelView` so the T26 escape-hatch contract (and the two T26 UI tests that tap it)
  keep working.

---

## 6. Debug affordances (all inert without their argument; `#if DEBUG` where they can leak)

| Argument | What it does |
|---|---|
| `-surfaceMode shell=native` | put the pane host surface in the native renderer (existing T26 flag; `shell` is the new alias for `paneHostSurface`) |
| `-nativeShellSnapshot <dir>` | write four window PNGs of the shell: light, dark, and each again at `accessibility3` — needs no Screen Recording consent |
| `-uiTestSeedServer <url>` | add a server without driving the add-server form |
| `-uiTestAssumeSignedIn` | substitute the **auth gate** only, so panes render against a stub server with no session |
| `-uiTestOpenDeepLink <url>` | substitute the **delivery** of a URL (XCUITest cannot send a system open on this toolchain); handling is the production `DeepLinkRouter` → `NativeNavigation` path |

No probe changes the user's own appearance or Dynamic Type: the snapshot modifier applies
`preferredColorScheme`/`dynamicTypeSize` only while a probe actually set them.

---

## 7. Reproducing the evidence

```bash
# 1. unit + UI suites (Catalyst, then the iPhone 16 Pro simulator — the default --sim cannot resolve on this host)
scripts/qa-test.py --platform mac  --label t30-cat-final
scripts/qa-test.py --platform ios --sim id=81A7F251-8B31-4945-8783-5A264C14B8D5 --label t30-ios-final

# 2. the two T30 UI tests on their own
scripts/qa-test.py --platform ios --sim id=81A7F251-8B31-4945-8783-5A264C14B8D5 \
  --only-testing MattermostUITests/MattermostUITests/testNativeShellDeepLinkLandsOnTheChannelInTheNativeStack \
  --only-testing MattermostUITests/MattermostUITests/testWebPaneIsUnchangedWithoutTheSurfaceFlag --label t30-ui

# 3. screenshots (light/dark, normal + accessibility3)
xcrun simctl launch booted com.mattermost.ios -uiTestResetPersistedState \
  -surfaceMode shell=native -uiTestSeedServer https://mm.example -uiTestAssumeSignedIn \
  -nativeShellSnapshot "$PWD/build/shots/t30"

# 4. memory (same binary, same server; only the pane differs)
scripts/t30-shell-footprint.sh --pane web
scripts/t30-shell-footprint.sh --pane native
RELEASE_WEBVIEW=1 scripts/t30-shell-footprint.sh --pane native   # webview released behind the shell
```

---

## 8. Verification — real runs on this host

### 8.1 Mac Catalyst, unit suite (whole `MattermostTests`)

```
run        : t30-cat-final
outcome    : finished (xcodebuild rc=0, 30s)
tests      : 584 run, 4 skipped, 0 failed
RESULT: PASS
```

(`Executed 584 tests, with 4 tests skipped and 0 failures` in the runner's own words; log
`build/logs/t30-cat-final.log`.)

### 8.2 iOS Simulator, whole scheme (unit + UI)

```
run        : t30-ios-final
outcome    : finished (xcodebuild rc=0, 367s)
tests      : 15 run, 1 skipped, 0 failed      # MattermostUITests
RESULT: PASS
```

with the unit phase of the same run reporting `Executed 584 tests, with 3 tests skipped and 0
failures`. Log: `build/logs/t30-ios-final.log` → `docs/t30-full-ios-2026-10-24.log`.

The 1 skipped UI test is `testSSOReachesIdentityProviderWithoutCertificatePrompt` — the env-gated live
SSO check, which skips unless `TEST_RUNNER_MM_LIVE_SSO_URL` is set (corrected in T30-R, finding F5;
the note previously named the 8443 certificate flow, which in fact **passed** against a live
self-signed stub in this same run: `testCertificateTrustOnFirstLaunchRendersThePage`,
`testCertPromptShownForSelfSignedServer` and `testExplicitlyUntrustedCertificateHardRejectsWithoutPrompt`).
It skips with its own `XCTSkipUnless` reason, not silently:

```
grep "skipped" docs/t30-full-ios-2026-10-24.log
→ MattermostUITests.swift:826: -[MattermostUITests.MattermostUITests
    testSSOReachesIdentityProviderWithoutCertificatePrompt] : Test skipped - Live SSO test: set
    TEST_RUNNER_MM_LIVE_SSO_URL to run
```

### 8.3 The two T30 UI tests

```
run        : t30-ui5
outcome    : finished (xcodebuild rc=0, 26s)
tests      : 2 run, 0 skipped, 0 failed
RESULT: PASS
```

* `testNativeShellDeepLinkLandsOnTheChannelInTheNativeStack` — `-surfaceMode shell=native` +
  `mattermost://mm.example/acme/channels/general`: the channel pane is **pushed**, its title is
  `general`, no webview is mounted, the server switcher is present, Settings opens and closes **from
  the pushed pane**, and Back returns to the shell's sidebar.
* `testWebPaneIsUnchangedWithoutTheSurfaceFlag` — with no flag the webview pane mounts and neither
  `nativeShell` nor the auth surface is constructed.

The screenshots this test attaches (`t30-native-shell-deeplink`) plus the four probe PNGs in §8.4 are
the visual evidence.

### 8.4 Screenshots (dark mode and Dynamic Type are evidence, not claims)

`docs/t30-native-shell-light.png`, `-dark.png`, `-light-ax3.png`, `-dark-ax3.png` — written by the
`-nativeShellSnapshot` probe on the iPhone 16 Pro simulator with the shell mounted. At
`accessibility3` the list rows reflow to two/three lines, the tab labels stay intact, nothing is
clipped horizontally; long explanatory text continues below the fold inside the scrollable list.

### 8.5 Memory: the shell mounted, measured

Same binary, same simulator, same seeded server (`http://127.0.0.1:8065`), only the pane differs.
RSS summed over the app process plus the WebKit processes that appeared after launch (the kernel
physical footprint of the app process is quoted alongside):

| Arm | app RSS | WebKit RSS | total RSS | app `footprint` | WebKit pids |
|---|---|---|---|---|---|
| webview pane (today) | 189.6 MB | 625.9 MB | **815.5 MB** | 28 MB | 3 |
| native shell (webview warm behind it) | 200.6 MB | 620.2 MB | **820.8 MB** | 32 MB | 3 |
| native shell, webview released | 173.2 MB | 0 | **173.2 MB** | 27 MB | 0 |

Read this honestly:

* Mounting the shell costs **+11.0 MB of app RSS, +4 MB of physical footprint, +0.65 % of the total**
  — no memory regression, which is what the acceptance criterion asks for. The shell itself is the
  placeholders, the model and the SwiftUI containers.
* The webview is still there in arm 2 **by design**: the T26 release policy only releases a pane's
  webview when an *approved* native card owns that pane, and T30's shell is a skeleton with
  placeholders — approving it would let the app drop the only renderer that can actually show posts.
  Arm 3 uses the same DEBUG release seam the T26 tests use and shows what the shell costs alone:
  **79 % less than the webview pane**, with zero WebKit processes.
* The T27 harness (`scripts/perf_probe.sh`) cannot produce these numbers for a native pane: its
  scripted sequence logs in and scrolls *through the webview*, and native login does not exist until
  T31. `scripts/t30-shell-footprint.sh` is the deliberate, documented substitute for that arm (same
  primitives: `ps` RSS + `footprint`), not a replacement for T27's web baseline. JSON: `docs/perf/t30-footprint-*.json`.

---

## 9. Defects found and fixed during this card (honest list)

### 9.1 The native deep link silently fell through to the webview

The first implementation wired the routers in `MattermostApp.init`
(`_deepLinkRouter.wrappedValue.nativeNavigation = navigation`). The app log showed the link being
parsed and routed — `uiTest deep link … -> routed` — but no native route was set, because the routing
had taken the *web* branch: by the time the views ran, `deepLinkRouter.nativeNavigation` was nil.

State the fact and stop there: reading a `@StateObject`'s `wrappedValue` before installation is
documented by SwiftUI as creating a fresh instance, but the same `init` also seeds a server through
`_serverStore.wrappedValue` and that *does* reach the installed store — so the exact mechanism is not
"init-time reads are always throwaway", and no one should rely on either behaviour. The fix removes the
question: `bindShellStores()` binds every seam (deep-link router, notification worker, navigator) from
the scene's `.task` **and** from `onOpenURL`, both of which run after installation, and re-binding is
idempotent. The UI test pins the outcome: the deep link now pushes the native pane, and the web branch
is untouched when the pane resolves `web`.

The failure mode is worth recording because every unit test passed while it was broken: the unit tests
inject the seam themselves (`navigation.serverStore = store`), so only an end-to-end launch could see
that the app-level wiring never arrived.

### 9.2 A late appearance wiped the routed channel

`RootView.startUp()` → `activate(initial)` reset the location to the workspace root whenever the shell
had no remembered location *for the current server*. On a cold launch where the deep link landed
first, the appearance pass then popped the channel the user had just opened. Fixed twice over:
`activate(serverID:)` is a no-op when that server is already current, and `startUp()` returns early if
routing already picked a server. Both are pinned by `testActivatingTheAlreadyCurrentServerKeepsTheLocation`
and by the UI test.

### 9.3 The pushed pane hid the shell chrome

See §5. The first implementation lost the server switcher, Settings and Add-server for every covered
pane.

### 9.4 `ColorScheme` was ambiguous in the app module

The snapshot probe writes `preferredColorScheme`; the app has its own `ColorScheme` type
(`ThemeSync.swift`), so the compiler resolved `Mattermost.ColorScheme`. Fixed by qualifying
`SwiftUI.ColorScheme` in the probe.

---

## 10. Limitations, and what T30 deliberately did not do

1. **Placeholders are real placeholders.** Channel list, post list, threads list, draft box and
   composer do not exist. The shell proves the navigation model; it does not render a workspace.
2. **Native login does not exist** (T31). A server without an `AuthSession` token shows the auth
   surface and must go through the webview.
3. **A webview-signed-in server looks signed-out natively** (§3.1). Adopting the webview session is
   follow-up work, not part of this card.
4. **The shell is not an approved pane-owning card**, so the release policy keeps the webview warm
   behind it (§8.5). Approving it is the decision of whichever card completes the pane.
5. **iPad/regular width is implemented but was not UI-tested in T30** — closed by T30-AV, which ran
   the regular-width split view (sidebar + detail + routed selection across a rotation) on an iPad Pro
   11-inch simulator, and re-run green in T30-R (`docs/t30-build-note.md` §12). A Catalyst *window
   resize* is still only partially covered: the layout is verified by the app's own window capture,
   but the drag-resize interaction needs Accessibility consent this host does not grant.
6. **No live server was used for the shell.** The UI tests drive a stub (`https://mm.example`) with a
   substituted auth gate; the footprint runs used `http://127.0.0.1:8065` but only to have a real
   webview in the web arm. Nothing in T30 talks to REST v4 — that is T31 onward.
7. **Threads are a placeholder with a push route only.** `/{team}/threads/{...}` parses and pushes;
   the list itself is S13 (T36).

---

## 11. Commit

`feat(native): native app shell with team/channel navigation behind the dual-render flag (T30)`

T30-R repair: `fix(native): repair T30 native shell against T30-AV F1-F6 (T30-R)` — the commit
immediately before the docs/evidence commit that carries this section.

---

## 12. T30-R repair — the T30-AV findings (F1–F6)

Card `t_c62dbcaa`. The verdict being repaired is `T30-AV-verdict.md` on `t_3e6ddccf`, which audited
`d831814` from a detached worktree. Every actionable finding is closed in this tree — none deferred,
none re-labelled as "documentation only". F7 (the footprint *method* is not apples-to-apples) is
informational in that verdict, not a defect in this tree; its numbers stand as measured.

### 12.1 What each finding was, and what changed

| # | Finding | Repair |
|---|---|---|
| **F2** | `nativeAuthSurface` never reached the accessibility tree: `NativeShellView` wrapped **both** branches in a `Group` with `.accessibilityElement(children: .contain)` + `nativeShell`, so SwiftUI applied that container to the auth child and the child's own identifier was shadowed. The shipped `XCTAssertFalse(element(app, "nativeAuthSurface").exists)` could never fail. | The signed-out state is its own top-level branch (`NativeShellView.body`); `nativeShell` wraps only the workspace shell it names. New shipped UI test `testSignedOutServerShowsTheIdentifiableAuthSurface` asserts the identifier **exists** in the native + signed-out configuration, and the flag-off test now also asserts the auth surface's control by label — an element that test proves is really there, so the negative assertion can fail. |
| **F1** | Convergence was claimed for the shipping configuration, where `NativeNavigation.directory` is `nil`: a deep link (names) and a tapped mention (ids) agree on server and pane but not on channel/team identity. The shipped test was green only because its `FakeDirectory` resolved both directions. | Claim **downgraded and made checkable** (this note §3, `NativeLocation`/`NativeNavigation` docs, `docs/parity.md`): "same server and pane; channel identity once S08/T32-T33 installs the directory". `testDeepLinkAndMentionAgreeOnServerAndPaneWithoutADirectory` asserts the weaker truth, including `XCTAssertNotEqual` on the two locations so the day a directory lands it fails; the old test is renamed `testConvergenceHoldsOnceADirectoryResolvesNamesAndIDs` so it says what it needs. |
| **F3** | `apply` set `path` only when the location `hasChannel`, so `/pl/<post>` and `/{team}/threads` changed the model and left a phone on the shell root — the "Resolving this permalink…" pane was unreachable on compact width. | `NativeLocation.opensADestination` (channel **or** permalink **or** threads pane) gates the push, and `popToRoot` uses it too. A channel-less thread no longer stacks onto whatever conversation was open. Three unit tests pin it (`testPermalinkDeepLinkPushesThePermalinkPane`, `testThreadsDeepLinkWithoutAChannelPushesTheThreadsPane`, `testPopToRootFromAChannelLessDestinationReturnsToTheShell`). |
| **F4** | Flag-off was not literally the pre-T30 path: `RootView.activate` called `navigation.activate` in every render mode, so the model was populated in web mode and `startUp()`'s new "already routed" guard became one-shot. | The appearance pass goes through `NativeNavigation.activateIfRouting(serverID:)`, which is a no-op unless `acceptsNativeRouting`; a runtime flip to native activates from the mode change (guarded on the model still being empty, so a route that landed first is not reset). `activate(serverID:)` still accepts direct activation — it is the *appearance pass* that must not touch a pane it does not own. Two tests: `testAppearanceInWebModeNeverPopulatesTheModel`, `testAppearanceInNativeModePopulatesTheModel`. |
| **F5** | §8.2 named the wrong skipped UI test. | Corrected in §8.2 with the runner's own line: `testSSOReachesIdentityProviderWithoutCertificatePrompt` (env-gated live SSO). The 8443 certificate tests passed in that same run. |
| **F6** | `UnportedSurfaceView` was dead code (no call site) while `docs/dual-render.md` still named it, and `docs/parity.md` had no T28/T29/T30 row and still said "Status last refreshed at T8". | The view is deleted together with its four pbxproj entries; `docs/dual-render.md` §2/§7/§8/§12 now name `NativeShellView` and the shell's `revertToWeb…` escape hatch, and the code comments that referenced the type are rewritten. `docs/parity.md` gains a **Path B native cards** table (T28 transport, T29 store, T30 shell) with their honest limits, a refreshed status line, and Phase 5/6/Path-B phase rows. |

### 12.2 The AV probes, per probe, after the repair

The probe sources are `mmios-qa`'s patch (`t30av-probes.patch`, applied to a throwaway worktree of
this commit, never committed). Re-running it is the cheapest revalidation, but **five of the seven
unit probes now fail on purpose** — they encode the pre-repair state, so a failure is the evidence:

| Probe | Encodes | Post-repair result | Why |
|---|---|---|---|
| AV-P1 | deep link `==` mention tap with no directory | **fails** | F1: the equality claim was downgraded, not the code faked. `NativeLocation` still differs on channel/team keys; `testDeepLinkAndMentionAgreeOnServerAndPaneWithoutADirectory` is the shipped, passing assertion of what does hold. |
| AV-P2 | id link and mention agree on `teamID` | **fails** | same as AV-P1 (the URL grammar carries no team id). |
| AV-P3 | a name-only directory still converges | **fails** | deliberately: bidirectional resolution is required for full equality; that is now stated in `NativeChannelDirectory`'s contract and the build note instead of being implied. |
| AV-P4 | manual selection with ids `==` mention | passes | unchanged (control). |
| AV-P5 | permalink pushes nothing (`path.isEmpty`) | **fails** | **F3 is fixed**: the permalink now pushes, so the probe's assertion of the old bug is false. Shipped inverse: `testPermalinkDeepLinkPushesThePermalinkPane`. |
| AV-P6 | web mode still populates the model | passes | unchanged: the model API still accepts a direct activation; it is `RootView`'s call site that is gated (F4), pinned by the two `testAppearance…` tests. |
| AV-P7 | channel-less threads pushes nothing | **fails** | **F3 is fixed** (same as AV-P5). Shipped inverse: `testThreadsDeepLinkWithoutAChannelPushesTheThreadsPane`. |
| AV-U3 | `nativeAuthSurface` is in the accessibility tree | **passes on both sims** | **F2 is fixed** — this is the probe that failed on every device before. |

A revalidation that wants "7 run / 0 failed" should flip AV-P1/P2/P3 to the server+pane assertion and
AV-P5/P7 to the pushed-destination assertion; the shipped suite already carries exactly those four
assertions, so the probes are now duplicates of product tests rather than new information.

### 12.3 Verification — real runs on this host (T30-R)

All numbers below are from the tree **merged with T30b** (`a25b7eb`, the synchronized-folder
migration) — i.e. what lands on `main`, not the pre-merge branch tip. That matters: T30b moved
`Mattermost/UI/Native/` and both test targets to `PBXFileSystemSynchronizedRootGroup`, so this
repair's new UI test and its touched test files are included by the folder, not by hand-written
project entries.

```
# 1. Catalyst, whole MattermostTests (the required unit gate)
run        : t30r-cat-merged
outcome    : finished (xcodebuild rc=0, 53s)
tests      : 605 run, 4 skipped, 0 failed
RESULT: PASS                                   # ** TEST SUCCEEDED ** in the log
```

```
# 2. iOS, whole scheme (unit + UI), iPhone 16 Pro Max / iOS 18.3
run        : t30r-ios-merged
outcome    : finished (xcodebuild rc=0, 401s)
unit       : Executed 605 tests, with 3 tests skipped and 0 failures
UI         : Executed 16 tests, with 1 test skipped and 0 failures
RESULT: PASS                                   # ** TEST SUCCEEDED ** in the log
```

The unit skips are the pre-existing fixture-gated ones (live mention poll, the two
self-signed-transport tests that need `scripts/t28-selfsigned-check.sh`); the UI skip is the
env-gated live SSO test. The two UI tests this repair touches both ran and passed:
`testSignedOutServerShowsTheIdentifiableAuthSurface` (5.1 s — the identifier F2 said could never be
found) and `testWebPaneIsUnchangedWithoutTheSurfaceFlag` (5.0 s — with the `:8111` stub live, so no
skip, and with an assertion that can now fail). `testNativeShellDeepLinkLandsOnTheChannelInTheNativeStack`
still passes (12.6 s), so F3/F4 changed nothing about the routed-pane path.

```
# 3. AV probes (patch applied to a throwaway state of this tree, then reverted)
unit   : 7 run, 0 skipped, 5 failed            (AV-P1/P2/P3 claim + AV-P5/P7 fixed-defect, §12.2)
AV-U3  : 1 run, 0 skipped, 0 failed            iPhone 16 Pro Max (iOS 18.3) -> PASS  (was FAIL on every sim)
layout : 3 run, 0 skipped, 0 failed            iPad Pro 11-inch M5 (iOS 26.5) -> PASS (AV-U1/U2/U3)
```

Logs: `docs/t30r-catalyst-unit-2026-10-25.log`, `docs/t30r-full-ios-2026-10-25.log`,
`docs/t30r-probes-unit-2026-10-25.log`, `docs/t30r-probe-avu3-iphone-2026-10-25.log`,
`docs/t30r-probe-layout-ipad-2026-10-25.log`.

The gates are green on this tree too: `scripts/verify-dual-render-gates.sh` (including T30b's
synchronized-group, single-object-id and pbxproj-diff checks) and `scripts/t28-token-grep.sh`
(no credential-shaped value in the 46 committed logs, this repair's five included).

**One honest note on the iOS run.** An earlier full-scheme attempt on the pre-merge branch
(`build/logs/t30r-ios-final.log`, kept out of `docs/`) failed with `Mach error -308 (server died)`
plus five unrelated failures (three certificate UI tests, one surface-toggle UI test, one store size
test). The cause was not the tree: the sibling T30b card was driving the **same** iPhone 16 Pro
simulator with its own `xcodebuild` at the same time, and CoreSimulator's
`backboardd`/`testmanagerd` died under the doubled load (crash reports at 00:00:12, swap at 6.5 GB
of 8 GB). Both suites here therefore ran on a second iPhone device — same scheme, same OS
generation, no shared device with a concurrent worker.

### 12.4 What T30-R still does not claim

* **Convergence is server + pane, not channel identity** (F1). Closing that is S08/T32-T33 (channel
  list → `NativeChannelDirectory`), and the test named above is designed to fail on the day it lands.
* **Catalyst window resize** remains a human check (Accessibility consent is refused on this host),
  and **a real APNs tap** remains unproducible here; both are T30-AV's original caveats, unchanged.
* **F7** (warm-arm footprint comparison) is untouched: it is a measurement critique, and the note's
  §8.5 numbers are still the ones this tree produces. The comparison should be re-run on
  same-content warmth when a card actually needs the delta.

