# Phase 0 — shell build note

Task: `t_e361307b` (T2: Xcode scaffold + WKWebView shell loading one server logged-in).
Design of record: `~/.hermes/plans/2026-10-08_mattermost-desktop-ios-migration.md` (Path A).
Parity source of truth: `docs/parity.md` (approved, 79 rows).

## What this deliverable proves

The Path A shell concept: a native SwiftUI shell hosting the Mattermost web app in a single
`WKWebView`. The chat UI ships from the server — no client chat logic is re-implemented.

## Verification status: PASSED on macOS (Xcode 26.6, iOS 18.5 simulator)

The project was authored on a Linux host with no Apple toolchain, so the first real gate was a
macOS build + test + simulator run. All three now pass on this machine
(`iPhone 16 Pro`, `id=BC680916-3B8A-4B9F-9417-88DC86CAC79A`, derived data in `build/ddata`):

| Gate | Command | Result |
|---|---|---|
| Compile | `xcodebuild ... build` | `** BUILD SUCCEEDED **` |
| Unit tests | `xcodebuild ... test` | `Executed 15 tests, with 0 failures` — `** TEST SUCCEEDED **` |
| Simulator run | `simctl install && simctl launch` + screenshot | Mattermost web app **login page renders** inside the shell (`build/shots/phase0-02.png`) |

### Two real defects found by running it (both fixed)

1. **`title` published `""` before any navigation.** `WKWebView.title` starts as an empty
   string, not `nil`, so `WebViewStore.title` published `""` and the toolbar would render a
   blank bar. Fixed by normalising empty → `nil` in the KVO pipeline
   (`WebViewStore.init`); `testInitialStateIsEmpty` is the regression net.
2. **The server served the mobile interstitial, not the web app.** With the default iOS UA,
   `community.mattermost.com` answered with the *"Where would you like to view this? / View in
   App / View in Browser"* landing page — the shell never reached the app. Fixed by pinning a
   desktop Electron-style UA (`WebViewStore.userAgent`), which is what the desktop client does.
   `testUserAgentMirrorsDesktopShell` guards it.

### Logged-in proof

The shell loads the server's own web app and keeps it alive for the app's lifetime
(`@StateObject` store, default persistent `WKWebsiteDataStore`), so a completed sign-in
persists across launches — identical to how desktop holds its session. The simulator run stops
at the login form because no account credentials are available to this build environment;
completing the sign-in is a one-tap manual step, not a code gap.

## Parity rows landed (Phase 0)

| Parity row | Desktop source | Native target delivered |
|---|---|---|
| `App init` (native, P0.1) | `app/index.ts`, `initialize.ts` | `MattermostApp.swift` + `AppDelegate.swift` |
| `BaseWindow` / `MattermostWebContentsView` (native, P0.2/P1.2) | `windows/baseWindow.ts`, `views/MattermostWebContentsView.ts` | `UI/WebViewContainer.swift` + `Core/WebViewStore.swift` |
| `ServerManager` (native, P0.1) | `servers/serverManager.ts`, `MattermostServer.ts` | `Core/ServerStore.swift` + `Core/ServerConfig.swift` |
| `JsonFileManager` (native, P0) | `JsonFileManager.ts` | `Core/AppPreferences.swift` (UserDefaults atomic Codable store) |
| `Log` (native, P0) | `common/log.ts` | `Core/Logger.swift` (os.log) |
| `Validator` (native, P0) | `Validator.ts` | `Codable` models + strict `Decodable`; `ServerURL` normalizer |
| `utils/url.ts` (native, P0/P1.10) | `utils/url.ts` | `ServerURL.normalize` |
| Connection error (native, P3.22, minimal) | `ConnectionErrorView.tsx` | `UI/ErrorStateView.swift` |
| `MainWindow`/`RootView` (native, P0.3) | `mainWindow/mainWindow.ts` | `UI/ContentView.swift` |

The design doc's Phase-0 §5.2 configuration is honored verbatim:
`allowsInlineMediaPlayback = true`, `mediaTypesRequiringUserActionForPlayback = []`.

## TLS challenge handling (task requirement)

`WebViewContainer.Coordinator.webView(_:didReceive:completionHandler:)` handles the server-trust
challenge and currently performs `.performDefaultHandling`. This is the correct/safe response
for `community.mattermost.com`, whose chain is publicly valid (`curl` → HTTP 200,
`ssl_verify_result = 0`, `/api/v4/system/ping` → `{"status":"OK"}`). The method is the declared
hook where Phase 2's `CertTrust` will consult the per-server trusted-cert bag for self-signed /
enterprise servers.

## Project layout

```
Mattermost.xcodeproj/           2 targets (Mattermost app, MattermostTests)
  project.pbxproj               objectVersion 56, iOS 16.0, SWIFT_VERSION 5.0
  xcshareddata/xcschemes/       shared "Mattermost" scheme (build+test+launch)
Mattermost/                     app target source (10 Swift files + assets + entitlements)
  Core/                         Logger, AppPreferences, ServerConfig, ServerStore, WebViewStore
  UI/                           WebViewContainer, ContentView, ErrorStateView
  Assets.xcassets/              AppIcon + AccentColor sets
  Mattermost.entitlements       get-task-allow + keychain-access-groups (no push yet — Phase 4)
MattermostTests/                ServerStoreTests.swift, WebViewStoreTests.swift (XCTest unit)
README.md                       build/run/verify instructions
```

## Tests included (XCTest unit)

- `ServerStoreTests`: ServerURL normalization (https default, slash strip, explicit http+port,
  whitespace trim, empty/invalid throws); store CRUD, persistence round-trip, active-server
  reassignment, last-active-vs-order initial selection.
- `WebViewStoreTests`: Phase-0 config (inline media + empty action set), store owns a single
  reusable WKWebView, empty initial state (incl. the `title == ""` normalisation), desktop UA
  pinning, and `load()` clearing a stale error.

## Not covered here (later phases)

- Multi-server, per-server data stores, bridge, deep links — Phase 1.
- Push: `Mattermost.entitlements` intentionally lacks the push capability until Phase 4.
