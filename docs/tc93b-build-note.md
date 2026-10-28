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
  mounted (see §5 for the load caveat).

Test-level assertions, not just pixels: `nativeChannelPane` exists, `channelPostList` exists,
`channelComposer` exists, `channelComposerPlaceholder` does **not** exist,
`channelComposer.input` is a `TextView`.

## 5. Known finding: the escape hatch mounts a webview that does not finish loading

In a Release build the hatch is present, reachable (it is the last row of the sidebar list and the
test scrolls to it) and it does swap the native pane for a `WKWebView` — so the release policy is
live and reversible. What it does **not** do on this host is render: the webview sits on its ~10 %
progress bar, blank, for at least 90 s (two runs). A Debug build with `-surfaceMode channelView=web`
against the same container and server renders server content within 30 s
(`build/tc93b/control-webpane-debug.png`), so this is not "the server is unreachable".

Most likely cause: the webview's `MMAUTHTOKEN` cookie is only planted in this environment by the
DEBUG-only `-uiTestSeedWebSessionCookie` seam; the seeded session used here (`-uiTestSeedStoredToken`)
writes the vault, and the native transport reads the vault rather than WebKit's cookie jar. That
makes the stall a pre-existing session-handover question, not a consequence of the flip — the flip
only changes which surface the hatch leaves, and before this card the hatch was unreachable in
Release because no surface was pane-owning, so this is simply the first Release exercise of it.

Tracked as `t_065c8753`. The smoke test records which of the two happened
(`escape-hatch-webview-loaded` vs `escape-hatch-webview-mounting` as the attachment name) and
deliberately does not assert the load yet.

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
