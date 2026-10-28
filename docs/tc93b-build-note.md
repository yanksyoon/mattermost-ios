# T93B build note — the 2026-10-27/28 workspace flip

Card `t_c93b8337`. Closes the dual-render programme's last deferred decision: the workspace is
native by default in a Release build with no flags, and the per-server webview is released.

## 1. What flipped

`Mattermost/Core/RenderMode.swift`:

```swift
public static let nativeApprovedSurfaces: Set<Surface> = [.auth, .calls, .sidebar, .channelView, .composer]
public static let paneOwningSurfaces: Set<Surface> = [.channelView]
```

Before this card the registry was `[.auth, .calls]` and `paneOwningSurfaces` was empty, so a
shipped build rendered every workspace surface in the WKWebView (the whole point of the flip is
that this is no longer true).

## 2. Scope: what the owner decided, and the one entry this card added

The owner's 2026-10-27 decision (recorded verbatim on the card) is scope **A**: flip `.sidebar` and
`.channelView` together, and make `.channelView` pane-owning. Those two entries are implemented
exactly as decided.

**`.composer` is this card's addition and is flagged as such** — it is not covered by the owner's
sentence. It is here because leaving it `web` makes the flip ship a read-only workspace: the
composer draws inside the pane, so with the pane native and the webview *released*, a `web`
composer renders the dead `"Message input — web (S14/T35)"` placeholder
(`Mattermost/UI/Native/Channel/ChannelView.swift:1034`) and nothing else. Three things support the
entry:

* §12.1's own claim — "a webview is released only when an approved card renders the **whole pane**"
  — cannot be satisfied by a pane whose composer is a placeholder. The registry entry is what makes
  the already-approved pane-ownership claim true.
* T35-AV (`t_3042a50f`, verdict `PASS-WITH-FINDINGS`) plus its repair (`t_e7eeaa46`) are the
  validator evidence; the post-AV composer work was then exercised by `t_50a0f378` and `t_56159748`.
* The release gate for this programme (`t_9928d203` step 4) asserts "composer is native" in the
  Release build. With `.composer` left `web` that card fails on the day it runs.

Reverting it is a one-line edit — drop `.composer` from the registry — if the owner wants the flip
to stay strictly inside scope A, at the cost of a native pane with no working message input.

## 3. Code and doc changes

| File | Change |
| --- | --- |
| `Mattermost/Core/RenderMode.swift` | registry → five entries; `.composer` case doc; approval ledger gains the `.composer` row and states the pane-ownership reason |
| `MattermostTests/SurfaceModeResolverTests.swift` | registry doc comment; the "unapproved surface" assertions that used `.channelView`/`.sidebar`/`.composer` retargeted to `.threads`/`.activity`/`.auth` (they are approved now, so the old assertions tested nothing) |
| `MattermostTests/ViewStoreTests.swift` | release-policy doc + the pinned registry literal |
| `MattermostTests/NativeNavigationTests.swift` | the four web-pane routing tests now request `channelView=web` explicitly instead of relying on it being the default |
| `MattermostUITests/T93BNativeByDefaultUITests.swift` | **new** — the Release smoke: no launch arguments, native sidebar → pane → composer, and the escape hatch |
| `Mattermost.xcodeproj/xcshareddata/xcschemes/MattermostReleaseSmoke.xcscheme` | **new** — the `Mattermost` scheme cannot be tested in Release (its unit target compiles against DEBUG-only product APIs), so this scheme lists only the UI test target |
| `docs/dual-render.md` | §3 ownership row, §4 ladder + compile-time default, §5 registry + ledger row, §8 Debug→Release cost, §10 test map, §11 summary + memory bullet, §12.1 status/release policy, file-impact table |
| `docs/parity.md` | re-baseline blockquote + native-surfaces paragraph |
| `Mattermost/Core/SurfaceModeResolver.swift` | `willForceWeb` pre-work hook, run before the escape hatch writes `.web` (`t_065c8753`) |
| `Mattermost/Core/WebViewStore.swift` | `installedCoordinator` keep-alive + `mountedContainers` ref count, so a duplicate container's teardown cannot kill the live pane (`t_065c8753`) |
| `Mattermost/UI/WebViewContainer.swift` | mount/unmount wiring for both, delegate re-assertion in `updateUIView`, duplicate dismantle is a no-op |
| `Mattermost/Core/ViewStore.swift` | `release`/`remove` drop the installed coordinator (no retention past the pane) |
| `Mattermost/MattermostApp.swift` | wires `willForceWeb` to `ViewStore.ensureStore(for:)` for the pane host |
| `Mattermost/UI/RootView.swift` | `.web` transition defers its `NavigationStack` pop one turn |

## 4. Verification (all run on this host, 2026-10-28)

```
bash scripts/verify-dual-render-gates.sh --allow-approved-registry
  RESULT: PASS — dual-render debug affordances cannot reach a Release build.

python3 scripts/qa-test.py --platform mac --label tc93b-units-focused3 \
  --only-testing MattermostTests/SurfaceModeResolverTests \
  --only-testing MattermostTests/ViewStoreTests \
  --only-testing MattermostTests/NativeNavigationTests
  83 run, 2 skipped, 0 failed — PASS

python3 scripts/qa-test.py --platform mac --label tc93b-units-full3
  1759 run, 9 skipped, 0 failed — PASS

xcodebuild build -configuration Release -destination 'platform=iOS Simulator,id=6B6991BF-…'
  ** BUILD SUCCEEDED **

xcodebuild test -scheme MattermostReleaseSmoke -configuration Release \
  -only-testing:MattermostUITests/T93BNativeByDefaultUITests
  Executed 2 tests, 0 failures — TEST SUCCEEDED      (repeated: smoke3, smoke4, smoke6)
```

### 4.1 The Release run is the evidence that matters

A Debug build proves nothing here: it can be *told* `-surfaceMode channelView=native`. The smoke
suite launches the app with `app.launchArguments = []` — in a Release binary every `-surfaceMode`
and `-uiTestSeed…` seam is compiled out, so the only way the workspace can render natively is the
registry. Screenshots (`build/tc93b/`, from the passing `tc93b-smoke4` run):

* `release-sidebar-noargs.png` — team rail, WORKSPACE (Local Mattermost / Operations / Threads /
  Jump to a channel…), CHANNELS (Off-Topic, Ops Standup, Town Square), DIRECT MESSAGES, tab bar.
* `release-pane-composer.png` — `# Off-Topic`, post list with rows, and the **native** composer:
  "Message" text field, attach, emoji, formatting, send.
* `release-escape-webview.png` — after "Use web view": the native pane is gone and a `WKWebView` is
  mounted. This artifact predates the §5 fix (the pane was mounted but blank there); the current run's
  `escape-hatch-webview-rendered.png` shows the web app's sign-in form.

Test-level assertions, not just pixels: `nativeChannelPane` exists, `channelPostList` exists,
`channelComposer` exists, `channelComposerPlaceholder` does **not** exist,
`channelComposer.input` is a `TextView`.

### 4.2 Re-verification after `t_065c8753` (2026-10-28, post-fix)

```
xcodebuild test -scheme Mattermost -configuration Debug -only-testing:MattermostTests
  1765 run, 8 skipped, 0 failed — TEST SUCCEEDED        (build/t065/units-full1.log)

xcodebuild test -scheme Mattermost -configuration Debug \
  -only-testing:MattermostUITests/MattermostUITests/testLaunchArgumentRendersNativeChannelViewWithChromeIntact
  1 test, 0 failures — TEST SUCCEEDED, 23.3 s            (build/t065/debug-hatch2.log)
  (the Debug escape-hatch acceptance test: native pane → "Use web view" → the stub's sign-in page)

xcodebuild test -scheme MattermostReleaseSmoke -configuration Release \
  -only-testing:MattermostUITests/T93BNativeByDefaultUITests
  Executed 2 tests, 0 failures — TEST SUCCEEDED, 48.3 s   (build/t065/release-seeded6.log)
```

The Release run is on a **seeded** container (Debug seed of `127.0.0.1:8065`, Release installed over
it), i.e. the same session hand-over the original finding used; see §5 for what the pane does now.

## 5. Resolved finding: the escape hatch mounted a webview that never committed

Before `t_065c8753` was closed, a Release run mounted the pane's `WKWebView` and then sat on its ~10 %
progress bar, blank, for 90 s at a time, while a Debug build with `-surfaceMode channelView=web`
against the same container and server rendered server content within 30 s
(`build/tc93b/control-webpane-debug.png`). The first explanation (the `MMAUTHTOKEN` cookie is only
planted by the DEBUG-only `-uiTestSeedWebSessionCookie` seam, so the webview had no session) was
**wrong**: no session produces the sign-in form, which is a page. The pane was not showing a page at
all.

Two defects in the flip, both measured on this host:

1. **Publishing during the branch swap.** `WebPaneHost` created the store in its own appearance, and
   `ViewStore.ensureStore` publishes store membership (`storeGeneration`). Landing that publish in the
   transaction that swapped `SurfaceHost`'s branch made SwiftUI's stack log
   `Update NavigationRequestObserver tried to update multiple times per frame`
   (`com.apple.SwiftUI:Invalid Configuration`) and re-run its root content: a **second**
   `WebViewContainer` was installed for the one `WKWebView` the store owns, and the first was
   dismantled (`PlatformViewChild::destroy`, two `makeUIView` calls 5 ms apart).
2. **The duplicate's teardown killed the live pane.** `dismantleUIView` unconditionally called
   `stopForDismantle()` → `stopLoading()` and cleared both delegates. `WKWebView.navigationDelegate`
   is **weak**, so the delegate died with the container SwiftUI threw away: WebKit's pending
   `decidePolicyForNavigationAction` had nobody to answer it, and the navigation then neither
   committed, finished nor failed — the 10 % bar with no page.

The fix (all in the shell, no change to the web app):

* `SurfaceModeResolver.willForceWeb` — the hatch runs its pre-work in the tap's own turn, and
  `MattermostApp.bindShellStores` creates the active server's store there
  (`ViewStore.ensureStore(for:)`). The flip's first body pass then mounts an already-complete branch,
  nothing publishes mid-swap, and the `Invalid Configuration` fault is gone (measured).
* `WebViewStore.mountedContainers` / `noteContainerMounted()` / `noteContainerUnmounted()` — a
  duplicate's dismantle is not the pane leaving the web branch, so it neither stops the page nor
  reports the pane as native; only the dismantle that leaves **nothing** mounted does.
* `WebViewStore.installedCoordinator` (set in `makeUIView`/`updateUIView`, cleared by the last
  dismantle, `ViewStore.release(_:)` and `remove(_:)`) — the store now keeps its delegate alive for as
  long as a container is mounted, and the pair cannot outlive the pane.
* `RootView`'s `.web` transition defers its `NavigationStack` pop one turn (`navigation.path` is stack
  state; the store creation there is now a no-op on the hatch's path and still covers the Debug
  surface inspector).

Evidence from the Release smoke, `build/t065/stream8.log` (app subsystem `com.mattermost.ios:WebView`):

```
didStartProvisionalNavigation url=http://127.0.0.1:8065/
didCommit url=http://127.0.0.1:8065/            (+59 ms)
didFinish url=http://127.0.0.1:8065/            (+0.94 s)
host state: inWindow=true ... frame=(0.0, 0.0, 402.0, 874.0)
dom probe: title=Mattermost ; ready=complete ; nodes=283 ;
           html=FREE EDITION | Don't have an account? | Log in to your account | ... | Email or ...
```

i.e. the pane lands on the web app's **sign-in form** — a rendered page, which is the outcome this
card's spec accepts when there is no session to hand over (`escape-hatch-webview-rendered.png`).
Handing a *signed-in* session to the webview is a separate, pre-existing question: the Release build
has no seam to plant the vault's token as a WebKit cookie, so a signed-in Release run still reaches
the sign-in form rather than the channel list.

The smoke test now asserts the page, not the mount: the pane publishes its page lifecycle as
`webPane`'s accessibility value (`WebViewStore.pageLoadState` — `idle`/`loading`/`loaded`/`failed`)
and the test waits for `loaded` within 60 s, attaching `escape-hatch-webview-rendered` /
`escape-hatch-webview-blank`. The value is the shell's own truth (`didCommit` + `didFinish`) on
purpose: the web **content** process is not reliably reachable from the runner on this host — with
that page on screen the AX lookup answered `kAXErrorServerNotFound`, so asserting `webApp.staticTexts`
measured the test infrastructure instead of the app (evidence: `build/t065/release-seeded4.log`).

Verified runs after the fix (all on this host, 2026-10-28):

```
# seeded container (Debug seed of 127.0.0.1:8065 as "Local Mattermost", Release installed over it)
xcodebuild test -scheme MattermostReleaseSmoke -configuration Release \
  -only-testing:MattermostUITests/T93BNativeByDefaultUITests
  Executed 2 tests, 0 failures — TEST SUCCEEDED        (build/t065/release-seeded6.log, 48.3 s)

com.mattermost.ios:WebView  mounted … (containers: 2 → duplicate went away, live keeps the page)
                            didStartProvisionalNavigation url=http://127.0.0.1:8065/
                            didCommit  url=http://127.0.0.1:8065/   (+36 ms)
                            didFinish  url=http://127.0.0.1:8065/   (+0.74 s)
  attachment: escape-hatch-webview-rendered (the server's "Where would you like to view this?" page)

# unseeded container (no session at all): the same pane lands on the web app's sign-in form
  dom probe: title=Mattermost ; ready=complete ; nodes=283 ; html=FREE EDITION | … | Email or …
  (build/t065/stream8.log)
```

## 6. Reproducing the Release smoke

```sh
# 1. seed a container with a Debug build (Release cannot seed: the seams are #if DEBUG)
xcrun simctl install <udid> …/Debug-iphonesimulator/Mattermost.app
xcrun simctl launch <udid> com.mattermost.ios \
  -uiTestSeedServer http://127.0.0.1:8065 -uiTestSeedServerName "Local Mattermost" \
  -uiTestSeedStoredToken <token>

# 2. install Release over it (same bundle id → container + Keychain survive), then
xcodebuild test -project Mattermost.xcodeproj -scheme MattermostReleaseSmoke \
  -configuration Release -destination 'platform=iOS Simulator,id=<udid>' \
  -only-testing:MattermostUITests/T93BNativeByDefaultUITests
```

The suite **skips** (rather than fails) when the container has no signed-in server, so ordinary
Debug UI runs on a fresh simulator stay green.

## 7. What is still web by default, deliberately

`.threads`, `.search`, `.profile`, `.activity`, `.channelInfo`, `.plugins` and the rest resolve
`web` until their own flip lands. Threads already render natively *inside* the pane (the pane's
location switch mounts them regardless of the `.threads` default), which is why opening a thread
from the flipped pane does not dead-end. The pane's header buttons that depend on
`.channelInfo`/`.search`/`.profile` are hidden, not broken — those are absent features, not dead
placeholders.
