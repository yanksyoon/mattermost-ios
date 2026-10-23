# T20 — Run the client on the Mac (Mac Catalyst destination + ad-hoc signing)

Date: 2026-10-23 · Host: macOS 26.3.1 (25D771280a), Xcode 26.6 (17F113) at `/Applications/Xcode.app`,
iOS 26.5 SDK. User decision: **private use on the user's own Mac and iPhone** — no App Store, no
Apple Developer Program. The Mac is the primary target.

## Decision record

1. **Catalyst, not a native macOS target.** The requirement allowed a separate native macOS target
   only if Catalyst proved unworkable. It did not: the same `Mattermost` target now builds and runs
   as a Mac app through the Mac Catalyst destination, with zero source forks. No native target was
   created and no direction change was needed.

2. **Ad-hoc signing.** `CODE_SIGN_IDENTITY = "-"` on the app target's Debug and Release configs,
   no team, `CODE_SIGN_STYLE = Automatic`. This is correct for a personal locally-run build: the
   `.app` runs unmodified on this Mac (`codesign -dv` shows `Signature=adhoc`). No provisioning
   profile exists or is needed; `get-task-allow` is dropped because it requires a development
   certificate and is meaningless under ad-hoc signing.

3. **App Sandbox: OFF (`ENABLE_APP_SANDBOX = NO`), deliberately.** There is no App Store review to
   satisfy, and the sandbox exists precisely to constrain App Store apps. A sandboxed Catalyst app
   would need `com.apple.security.network.client` (or the full entitlement set) merely to load
   `community.mattermost.com` in the webview and let `URLSession` downloads talk to the network;
   with nothing to protect the user from their own locally-run client, the sandbox would only add
   failure modes. This is a personal-use choice, documented here and in
   `Mattermost/Mattermost.entitlements`.

4. **Entitlements file is intentionally empty.** The previous content
   (`get-task-allow`, `keychain-access-groups = [$(AppIdentifierPrefix)$(CFBundleIdentifier)]`)
   made the Catalyst build fail under ad-hoc signing ("entitlements that require signing with a
   development certificate"). `SecureVault`/`CertTrust` store per-server tokens as
   `kSecClassGenericPassword` items scoped by `kSecAttrService` (server canonical URL).

   **Correction (2026-10-23, measured): the "no entitlement needed" assumption was wrong on
   Catalyst.** On macOS every `SecItem*` call in this app fails with `errSecMissingEntitlement`
   (-34018), because a Catalyst process always uses the data-protection keychain, which requires
   the `application-identifier` entitlement that only a signing team can issue. 20 tests across
   `SecureVaultTests` / `CertTrustTests` / `CertTrustDebugTests` fail for exactly this reason, and
   `KeychainPlatform.apply(to:)` (sets `kSecUseDataProtectionKeychain = false` under Catalyst)
   does not change it — Catalyst still routes to the data-protection keychain. Consequences and
   the fix path are recorded in the README ("Known limitation of the prebuilt Mac build") and
   tracked as T22.

## What changed in the project (all shared, none Mac-only)

`Mattermost.xcodeproj/project.pbxproj`, app target (`Mattermost`) Debug + Release configs only:

- `SUPPORTS_MACCATALYST = YES`
- `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx"`
- `CODE_SIGN_IDENTITY = "-"`
- `ENABLE_APP_SANDBOX = NO`
- `MACOSX_DEPLOYMENT_TARGET = 13.0`

Test targets (`MattermostTests`, `MattermostUITests`) were initially left untouched, which turned
out to be wrong for Catalyst: they inherited the SDK's `MACOSX_DEPLOYMENT_TARGET = 26.5` and could
not run on a 26.3 host, and they demanded a development team. They now carry
`MACOSX_DEPLOYMENT_TARGET = 13.0`, `CODE_SIGN_IDENTITY = "-"`, `CODE_SIGN_STYLE = Manual` so
`xcodebuild test -destination 'platform=macOS,variant=Mac Catalyst'` needs no team. The iOS
destination (`platform=iOS Simulator`) still resolves through the same `SUPPORTED_PLATFORMS` list.

## Commands (all run from `/Users/yangsooyoon/mattermost-ios`)

```sh
# 1. Catalyst build (the task's proof command)
xcodebuild -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build/ddata-mac build
# → ** BUILD SUCCEEDED ** (exit 0)

# 2. Launch + render proof
open -n build/ddata-mac/Build/Products/Debug-maccatalyst/Mattermost.app --args \
  -uiTestSeedSelfSignedServer https://community.mattermost.com \
  -shellSnapshot /Users/yangsooyoon/mattermost-ios/build/ddata-mac/t20-shot.png
```

`-uiTestSeedSelfSignedServer <url>` is the existing DEBUG seam that pre-populates the shell with a
server and switches to it (used by the XCUITest cert-prompt flow; inert in normal use). The
`-shellSnapshot <path>` argument is a NEW small debug-only probe (documented below).

## Launch result — the shell renders a real server login page

App launched (Catalyst, ad-hoc signed), window presented, webview navigated to
`https://community.mattermost.com` → `https://community.mattermost.com/login`, title
`Log in - Mattermost` (page-diagnostics dump in `docs/t20/catalyst-page-diagnostics.txt`).
The web-content snapshot OCRs the actual login UI (Mattermost logo, "Log in to your account",
Email or Username, Password, Forgot your password?, Sign in with Microsoft); the window snapshot
shows the native toolbar chrome (server switcher reading "Self-signed" + Downloads/Settings/Add
toolbar buttons) around the same rendered page.

Screenshots (attached to the card and in `docs/t20/`):

| File | What it proves |
|---|---|
| `docs/t20/catalyst-login-webview.png` | WKWebView web content: the real Mattermost login page rendered |
| `docs/t20/catalyst-window.png` | Whole Catalyst window: native toolbar + server switcher + the same page |
| `docs/t20/catalyst-page-diagnostics.txt` | URL / title / DOM text length + sample (text-level proof) |

### The debug-only `-shellSnapshot` seam (`Mattermost/MattermostApp.swift`)

Headless agents cannot use `screencapture` (Screen Recording TCC → `-10827`). Instead the app can
prove its own render: launched with `-shellSnapshot <path>`, a gated `Task` waits until the primary
server's webview has committed a URL, finished the network load, **and** the DOM has real text
(polls `document.body.innerText` — plain `isLoading == false` fires before the SPA paints, which
was the first failed attempt), then writes `<path>` (via `WKWebView.takeSnapshot`, which works on
Catalyst), `<path>.window.png` (via window `drawHierarchy`), and `<path>.txt` (DOM diagnostics).
The argument is absent in normal use; the code is inert and behind `@MainActor`. Two tiny helpers
(`snapshotImage()` continuation bridge, `evaluateJSObject()` page probe) are fileprivate.

## Catalyst-specific behaviour found and disposition (req. 3)

| Area | Finding on Catalyst | Disposition |
|---|---|---|
| WKWebView / UIViewRepresentable | Works unchanged; renders the full web app with the pinned desktop Electron UA | Verified by screenshot + OCR |
| Window sizing / toolbar / servers switcher | Toolbar with server switcher + Downloads/Settings/Add buttons renders in the Mac window titlebar area | Verified in `catalyst-window.png` |
| `.confirmationDialog` / Sheets | Compile and present on Catalyst (popover/Sheet); not interactively exercised here | Noted; XCUITest flows cover them on iOS |
| UNUserNotificationCenter authorisation | `requestAuthorization(options: [.alert,.sound,.badge])` is available on macOS (system prompt); badge math (`setBadgeCount`) macOS 11+ | Not exercised (needs a live mention event); code path shared, no Catalyst guard added |
| Keychain access groups | `SecureVault`/`CertTrust` use `kSecClassGenericPassword` scoped by service — no access-group entitlement needed on macOS | No code change; entitlements file emptied (see decision 4) |
| UIDocumentPickerViewController export | `init(forExporting:)` API available on Catalyst (presents the macOS save panel) | Compiles against the Catalyst SDK; runtime export not exercised (needs a live downloaded file + click) |
| Network client sandbox | Blocked by sandbox when enabled | `ENABLE_APP_SANDBOX = NO` (decision 3) |

Nothing needed a `#if targetEnvironment(macCatalyst)` fork; no "stub" was introduced. Anything not
exercised interactively is called out as such rather than claimed.

## iOS regression (req. 6)

Full suite re-run after the pbxproj/entitlements/MattermostApp changes:

```sh
xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=iOS Simulator,id=81A7F251-8B31-4945-8783-5A264C14B8D5' \
  -derivedDataPath build/ddata
```

Result (2026-10-23 15:33–15:34, full log `docs/t20-full-suite-2026-10-23.log`):

- **Unit: 256 tests, 0 failures (0 unexpected) — `MattermostTests.xctest` passed**
- **UI: 6 tests, 0 failures (0 unexpected) — `MattermostUITests` passed**
- `** TEST SUCCEEDED **`

Count note: the T18 baseline was 220 unit / 6 UI; the tree grew to 256 unit because T19a's
`DiagnosticsTests`/`SentryServiceTests` (and other post-T18 additions) landed after T18. The t19a
build note's "239 unit" was a pre-implementation estimate; 256 is the actual current count. This
run adds no tests and none changed — the Catalyst/entitlements/probe changes are build-level and
debug-gated, and the UI tests (which launch the real app through `-uiTestResetPersistedState` /
`-uiTestSeedSelfSignedServer`) still pass 6/6, i.e. no iOS regression.

**Measured 2026-10-23:** `256 unit tests + 6 XCUITest flows, 0 failures` — `** TEST SUCCEEDED **`.
The 11 failures present when the worker was reclaimed (DiagnosticsTests / SentryServiceTests, both
inherited from the T19a code that landed unreviewed) were fixed at source before this run:
`DiagValue` gained a real single-value Codable, `DiagnosticsService.jsonDecoder()` matches the
ISO-8601 encoder, the obfuscator masks URL before path (and matches any TLD), and
`SentryService.resetForTests()` stops singleton state leaking between tests.

Catalyst suite, measured on the same host:

```sh
xcodebuild test ... -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:MattermostTests
# 256 run, 15 failures — all errSecMissingEntitlement (-34018), see decision 4

# same run excluding the three Keychain-backed suites:
xcodebuild test ... -only-testing:MattermostTests \
  -skip-testing:MattermostTests/SecureVaultTests \
  -skip-testing:MattermostTests/CertTrustTests \
  -skip-testing:MattermostTests/CertTrustDebugTests
# → 236 run, 0 failures, ** TEST SUCCEEDED **
```

## Deliverables

- Working Catalyst build: `build/ddata-mac/Build/Products/Debug-maccatalyst/Mattermost.app`
- This note · `docs/parity.md` T20 section · screenshots `docs/t20/` · suite log
  `docs/t20-full-suite-2026-10-23.log`
