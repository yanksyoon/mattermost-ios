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
| `Mattermost/Core/Native/NativeNavigation.swift` | 574 | the navigation model: `NativeLocation`, `NativeTarget`, deep-link path parsing, the single routing funnel, per-server last location, the auth gate seam |
| `Mattermost/UI/Native/NativeShellView.swift` | 134 | the shell: phone composition (TabView: Channels / Threads, channel view = push) and regular-width composition (NavigationSplitView: sidebar beside the detail) |
| `Mattermost/UI/Native/NativePanePlaceholders.swift` | 402 | every not-yet-ported region as an honest placeholder plus the empty destination, the stale-route error state and the auth surface |
| `MattermostTests/NativeNavigationTests.swift` | 523 | 27 unit tests (parsing table, funnel convergence, multi-server, auth gate, both routing seams) |
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
5. **iPad/regular width is implemented but not UI-tested.** `NavigationSplitView` + the shared
   `NativeLocation` are exercised by the same code the phone uses, and the compact/regular split is
   covered by unit tests over `panePath` semantics, but no UI test rotates to regular width.
6. **No live server was used for the shell.** The UI tests drive a stub (`https://mm.example`) with a
   substituted auth gate; the footprint runs used `http://127.0.0.1:8065` but only to have a real
   webview in the web arm. Nothing in T30 talks to REST v4 — that is T31 onward.
7. **Threads are a placeholder with a push route only.** `/{team}/threads/{...}` parses and pushes;
   the list itself is S13 (T36).

---

## 11. Commit

`feat(native): native app shell with team/channel navigation behind the dual-render flag (T30)`
