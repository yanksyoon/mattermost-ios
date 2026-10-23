# Mattermost Desktop → iOS Parity Checklist

Single source of truth for the module→native mapping. Updated at each phase boundary.
Legend: `native` = implemented, `-` = not started / deferred to a later card/phase.

Design of record: `~/.hermes/plans/2026-10-08_mattermost-desktop-ios-migration.md`; the desktop
package is `mattermost/desktop` (v6.4.0-era). Status last refreshed at T8 (Phase 2).

## `src/common/` → Swift services

| Desktop module | Desktop file | Native replacement | Status |
|---|---|---|---|
| ServerManager | `servers/serverManager.ts` | `Core/ServerStore.swift` (ObservableObject, CRUD, `SERVER_*` events) | native ✅ |
| ViewManager | `views/viewManager.ts` | `Core/ViewStore.swift` (server→WKWebView + primary view) | native ✅ |
| AppState (mention/unread/badge) | `appState.ts` | `Core/SessionStore.swift` (per-server mention/unread/expired, cross-server totals, badge math, `BadgeSettable`/`SystemBadge`) | native ✅ (T8) |
| Communication (IPC) | `communication.ts` | `Core/Bridge.swift` (`JsBridge` + single `mattermostBridge` WKScriptMessageHandler + desktoppreload shim) | native ✅ |
| Validator (Joi) | `Validator.ts` | Codable models + `ServerURL.normalize` | native ✅ |
| JsonFileManager | `JsonFileManager.ts` | `Core/AppPreferences.swift` (UserDefaults Codable store) | native ✅ |
| Log | `common/log.ts` | `Core/Logger.swift` (os.log) | native ✅ |
| Config & preferences | `common/config/*` | `AppConfig` in UserDefaults | - |
| MattermostServer model | `common/servers/` | `Core/ServerConfig.swift` | native ✅ |

## `src/app/` → iOS scene model

| Desktop module | Desktop file | Native replacement | Status |
|---|---|---|---|
| BaseWindow | `windows/baseWindow.ts` | `Core/WebViewStore.swift` + `UI/WebViewContainer.swift` | native ✅ |
| MainWindow | `mainWindow/mainWindow.ts` | `UI/RootView.swift` | native ✅ |
| TabManager | `tabs/tabManager.ts` | `RootView` mounted per-server scenes (switch on hide/show) | native ✅ |
| ServerDropdownButton | `renderer/.../ServerDropdownButton.tsx` | `RootView` nav-bar `Menu` switcher | native ✅ |
| ServerHub (add/edit server) | `serverHub.ts` | `UI/ServerFormView.swift` + `Core/ServerFormModel.swift` + `Core/ServerURLValidator.swift` (URL validation via `/api/v4/system/ping` + `/api/v4/config/client` name probe) | native ✅ (T5) |
| navigationManager (deep links) | `navigationManager.ts` | `Core/DeepLinkRouter.swift` + `onOpenURL` + `mattermost://` scheme (`Info.plist`) | native ✅ (T4) |
| TrayIcon + badge | `system/badge.ts`, `tray.ts` | `SessionStore` badge math -> `UNUserNotificationCenter.setBadgeCount` (mentions sum, unread-dot->1, expired->1; `showUnreadBadge` setting persisted) | native ✅ (T8) |

## `src/main/` → Foundation/UIKit

| Desktop module | Native replacement | Status |
|---|---|---|
| secureStorage (safeStorage) | `Core/SecureVault.swift` (Keychain-first per-server credential store via `SecretPersisting`; `kSecClassGenericPassword`, service per server; token survives relaunch, readable only via the vault — never in UserDefaults/plaintext. T22: ad-hoc Catalyst falls back to an AES-GCM sealed file) | native ✅ (T6, T22 fallback) |
| serverInfo / serverAPI | `Core/ServerAPI.swift` + `Core/ServerInfo.swift` + `Core/ServerURLValidator.swift` (URLSession GET, `/api/v4/system/ping` + `/api/v4/config/client?format=old`, validation engine) | native ✅ (T5) |
| ThemeManager | `Core/ThemeSync.swift` (`ColorScheme`: light/dark, decision from `ServerTheme` + OS appearance, `isLightColor` HSP port, CSS-var / `prefers-color-scheme` injection per webview; applied on `didCommit`) | native ✅ (T9) |
| Notifications (mentions) | `Core/NotificationWorker.swift` (+ `NotificationScheduling`/`UNNotificationCenterAdapter`): permission asked on first mention; `notify_mention` → `UNNotificationRequest` (title `"server: title"`, silent/sound mapping, `threadIdentifier`=channel, push-proxy `server_id/channel_id/team_id/url/type` userInfo); tap → switch server + SPA `/channels/<id>`; foreground-visible-server suppression, cold-start queue flushed on `react-app-initialized` | native ✅ (T8) |
| Certificate store / trust | `Core/CertTrust.swift` (Keychain-first-persisted trust bag keyed by origin via `SecretPersisting`; `ComparableCertificate{data,issuerName,dontTrust}`; `isTrusted`/`isExplicitlyUntrusted`; wired into `WebViewContainer` `didReceive` server-trust challenge → auto-accept when already trusted, hard-reject when explicitly untrusted, default-handling for unseen. T22: ad-hoc Catalyst falls back to the same AES-GCM sealed file) | native ✅ (T9, T22 fallback) |
| DownloadsManager | `Core/DownloadWorker.swift` — `URLSessionDownloadTask` into `Documents/Downloads`, `WKDownloadDelegate` for webview files, persistent journal (`DownloadRecord`/`DownloadHistory`), Share-to-Files export via `UIDocumentPicker(initForExportingURLs)` | native ✅ (T7) |

## `src/renderer/` → SwiftUI views

| React screen | Native view | Status |
|---|---|---|
| MainPage / shell chrome | `RootView` + toolbar switcher | native ✅ |
| New/Edit/Remove Server | `ServerFormView` + `.confirmationDialog` remove | native ✅ |
| LoadingScreen | `ProgressView` linear skeleton in `ContentView` | native ✅ |
| ConnectionError/Error | `ErrorStateView` + `IncompatibleErrorStateView` + `RetryButton` (ports `ErrorView`/`ConnectionErrorView`/`IncompatibleErrorView`: full desktop copy + clear-cache-and-reload + verify-URL links + contact-admin + tech info) | native ✅ (T11) |
| Welcome/onboarding | `UI/WelcomeView.swift` (TabView pager + dots/chevrons + `WelcomePagerModel` wrap/auto-advance; parity of `WelcomeScreen`/`Carousel`/`WelcomeScreenSlide`/`CarouselButton`/`CarouselPaginationIndicator`); first-run gate in `RootView.onboardingOrEmptyState` | native ✅ (T10) |
| Settings | `SettingsView` (Form with Toggle/Picker/Stepper — `CheckSetting`/`SelectSetting`/`NumberSetting` ports; theme syncing, unread badge, app language, log level, download-history cap, servers list) + `Core/AppSettings` (LocalConfiguration store) | native ✅ (T11) |
| Downloads dropdown | `DownloadsView` (List + `DownloadRowView` with `ProgressView`), port of `DownloadsDropdown`/`DownloadsDropdownItemFile`/`FileSizeAndStatus`/`ProgressBar`; formatting ports `pretty-bytes` + renderer/utils | native ✅ (T11) |
| Certificate modal | `CertPromptSheet` + `CertificateInfoSheet` (ports `modals/certificate` + `showCertificateModal`); challenge → published prompt → trust bag decision | native ✅ (T11) |

## Phase status

- Phase 0 (shell + one server in WKWebView): DONE — `docs/phase0-build-note.md`.
- Phase 1 (multi-server shell + state): T3 DONE (`ServerStore`, `ViewStore`, per-server
  `WKWebsiteDataStore`, `RootView` switcher, `ServerFormView`); T4 DONE (`Bridge` —
  `communication.ts`/preload port under one `mattermostBridge` handler, allowlist-gated;
  `DeepLinkRouter` — `onOpenURL` + `mattermost://` scheme, queues until ready, routes to
  matching server + SPA path); T5 DONE (`ServerAPI`/`ServerInfo`/`ServerURLValidator` +
  `ServerFormModel`; add-server URL validated against `/api/v4/system/ping` +
  `/api/v4/config/client?format=old` before save; 103/103 tests green).
  — `docs/t4-build-note.md`, `docs/t5-build-note.md`.
- Phase 2 (OS services): T6 DONE (`SecureVault` — Keychain per-server credential wrapper for
  `secureStorage`; 12 tests incl. relaunch-persistence via a fresh vault instance reading the
  same namespace; token never in UserDefaults). — `docs/t6-build-note.md`.
  T7 DONE (`DownloadWorker`). T8 DONE (`SessionStore` + `NotificationWorker` — local mention
  notifications + cross-server badge, 29 new tests). — `docs/t7-build-note.md`,
  `docs/t8-build-note.md`. Remote push (T12/T13) still pending (needs a Push Proxy + APNs).
- Phase 2-b (theme/cert, T9): DONE — `ThemeSync` + `CertTrust` landed and wired into
  `WebViewContainer` (note: its CertTrustTests currently fail on this simulator — see
  `docs/t8-build-note.md` §pre-existing).
- Phase 3 (shell UI screens, started): T10 DONE (`WelcomeView` first-run onboarding pager port of
  `WelcomeScreen`/`Carousel`; add/edit/remove server already wired via `ServerFormView` +
  per-server Edit entry + `.confirmationDialog` remove; webview reloads on URL edit; removed the
  first-run auto-seed of community.mattermost.com so the Welcome pager is the real entry point;
  12 new `WelcomePagerModelTests`; 103/103 tests green). — `docs/t10-build-note.md`.
  T11 DONE (Settings + Downloads + Error/cert sheets): `SettingsView` (Form with
  Toggle/Picker/Stepper) backed by `AppSettings`; `DownloadsView` List + `DownloadRowView`
  (ProgressView) over the T7 journal; `ErrorStateView`/`IncompatibleErrorStateView`/
  `RetryButton` (ErrorView/ConnectionErrorView/IncompatibleErrorView port); `CertPromptSheet` +
  `CertificateInfoSheet` wired into the webview server-trust challenge; 41 new tests; the
  previously-failing `CertTrustTests` now pass. — `docs/t11-build-note.md`.
- Phase 4 (push & background): **PARTIAL — T12** delivered runnable **simulacrum** of the
  Push Proxy + full runbook/secret inventory (`PushProxy/mmpush_proxy.py`,
  `PushProxy/mmpush_check.py`, `PushProxy/mmpush_proxy.json`, `docs/t12-push-proxy.md`).
  REAL push delivery is BLOCKED on (1) who-runs-the-proxy hosting decision (design risk R1),
  (2) an Apple APNs `.p8` auth key (human + Apple Developer account), (3) a configured MM
  server DiagnosticId. Push Notifications capability still absent from entitlements until a
  real proxy is up. — `docs/t12-push-proxy.md`.

## Test & validation status (T17)

- **Unit (XCTest) net**: `ServerStore` CRUD, `SecureVault` round-trip/relaunch, `SessionStore`
  badge math, `DeepLinkRouter` routing, `DownloadWorker` dedup + journal — all **native ✅** and
  unit-suite fully green (**220 run / 220 pass**, whole scheme `TEST SUCCEEDED`, 2026-10-23).
  The 7 `DownloadHistoryTests`/`DownloadWorkerTests` failures inherited from T7 were fixed rather
  than waived: 6 over-escaped fixtures (shared `UserDefaults` suite + non-interpolated sources) and
  1 real `sanitizedFilename` fallback defect for separator-only names. The same double-escaping
  was corrected in 10 production log statements (`Bridge`, `WebViewContainer`, `DeepLinkRouter`).
- **UI (XCUITest) net**: NEW `MattermostUITests` target (project + scheme). 6 flows run green on
  the iOS 18.5 simulator against a local stub Mattermost server
  (`build/uitest-server/mm_stub.py`): onboarding pager → add-server form, add-server →
  login-through-webview, two-server switch, settings Stepper persist, Downloads empty state,
  and cert prompt (self-signed TLS stub → `CertPromptSheet`). Deterministic via
  `-uiTestResetPersistedState` / `-uiTestSeedSelfSignedServer` DEBUG seams in `MattermostApp`.
- **Real-device parity soak**: NOT runnable on this host (needs real server accounts, APNs
  `.p8`/Push-Proxy, physical device). Candidate procedure recorded in `docs/test-plan.md` §3.
- **Explicitly unvalidated here** (recorded, not passed): remote push/APNs (risk R1), real
  OAuth login-through-webview, live webview-initiated download + device export. See
  `docs/test-plan.md` §4.
- Regression net: run the full unit + UI suites at each phase boundary; document divergences in
  build notes. UITest target lands 6 new UI tests; pbxproj re-validated (plutil + dup-ID scan).

## App Store readiness (T18, Phase 6 task 33) — release gate

- **ATS — scoped, no kill-switch.** `Info.plist` carries exactly two relaxations:
  `NSAllowsArbitraryLoadsInWebContent=true` (WKWebView web content only — the Apple-sanctioned
  key for webview-host apps) and `NSAllowsLocalNetworking=true` (LAN/private-range http hosts).
  `NSAllowsArbitraryLoads` is absent by assertion — `scripts/verify-release-gate.sh` fails if it
  ever appears. The shell only ever loads servers the user configured (`RootView.activate`),
  and `ServerURLValidator` defaults addresses to https.
- **Self-signed/enterprise TLS** — unchanged, user-confirmed per origin via `CertTrust` +
  `CertPromptSheet` (Keychain-persisted, revocable, "don't trust again" hard-reject).
- **Privacy manifest** — `Mattermost/PrivacyInfo.xcprivacy` added to the app target Resources
  phase and present in the built `.app`. Declares: no tracking, empty tracking domains; collected
  data = User ID (session identity, App Functionality), Audio Data + Photos or Videos (web-app
  Calls only); required-reason API = UserDefaults (CA92.1). No file-timestamp/disk-space/
  boot-time/keyboard APIs used (verified by grep). T19 must extend it when Sentry/diagnostics
  land (crash/diagnostic data + any new reason APIs).
- **Usage descriptions** — `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`
  (required by WKWebView `getUserMedia` for the web app's Calls), `NSLocalNetworkUsageDescription`
  (LAN servers).
- **Export compliance** — `ITSAppUsesNonExemptEncryption=false` (HTTPS/TLS only).
- **Review narrative** — `docs/app-store-review-notes.md` (incl. paste-ready App Store Connect
  notes justifying arbitrary/self-signed server loading, data lifecycle, verification record).
- **Gate script** — `scripts/verify-release-gate.sh` (source-level checks) and
  `scripts/verify-release-gate.sh <built.app>` (bundle-level checks). Verified PASS on the
  2026-10-23 Debug simulator build; full suite re-run after the plist changes:
  **220/220 unit + 6/6 UI, TEST SUCCEEDED** (cert-prompt flow still green under web-content ATS
  relaxation). — `docs/t18-build-note.md`, `docs/t18-full-suite-2026-10-23.log`.

## Diagnostics + Sentry parity (T19a)

- **Desktop Help → "Run diagnostics"** → `Mattermost/Core/Diagnostics.swift`
  (`DiagnosticsService`), ported 1:1 from `mattermost/desktop` `src/main/diagnostics/`
  (`index.ts`, `DiagnosticStep.ts`, `internal/{utils,obfuscators,loggerHooks}`,
  `steps/step0.logLevel.ts…step11.auth.ts`). **Reconciled step count: 12** — the desktop
  source of record has exactly twelve numbered steps (`diagnostic-Step-0`…`-11`);
  T19's "19" and the design doc's "23" both do not match the actual module (verified by
  reading every step file). All 12 ported with desktop ids/names/order.
- Settings → Diagnostics section (SettingsView) runs all steps (progress-spinner while
  running) and offers ShareLinks for the `.txt` and `.json` report files; the report is
  obfuscated (emails/URLs/IPs/paths/tokens) before sharing, mirroring desktop obfuscators.
- Step 1 endpoints and step 4/11 session checks are injectable
  (`DiagnosticsContext.onlineEndpoint`, `DiagnosticsSessionProviding` reading the
  per-server `WKWebsiteDataStore` cookies MMUSERID/MMCSRF/MMAUTHTOKEN — presence only),
  matching desktop `session.defaultSession.cookies`.
- Desktop `src/main/sentryHandler.ts` → `SentryService` + `SentrySDKLink`: DSN-gated
  (`SentryDSN` in Info.plist); no DSN → verifiable no-op (unit-tested); real SDK not
  linked yet because SwiftPM cannot fetch github.com on this host (git transport breaks on
  the `~/.gitconfig` PAT rewrite), and the `Sentry` product's binary artifacts are
  downloaded at plan time — documented in `docs/t19a-build-note.md` §2, with a proven
  vendored-source compile path for later wiring. That is the honest, tested state; there
  is no fake DSN/send.
- Privacy manifest extended: CrashData / PerformanceData / OtherDiagnosticData added;
  **no FileTimestamp** reason API — the report timestamps come from `Date()`, and the
  release gate now asserts that in both directions.

## macOS / Mac Catalyst (T20) — build & platform parity

Updated 2026-10-23. The user decision flipped this client to **private use on the user's own Mac
and iPhone** (no App Store, no Apple Developer Program); the Mac is the primary target. The same
`Mattermost` target builds and runs for **Mac Catalyst** with zero source forks.

| Concern | macOS/Catalyst state | iOS state | Parity |
|---|---|---|---|
| Build platform | `SUPPORTS_MACCATALYST = YES`, `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx"` (app target Debug+Release) | unchanged (`iphoneos iphonesimulator`) | shared |
| Signing | `CODE_SIGN_IDENTITY = "-"` (ad-hoc, no team) — needed to run without a Developer Program account | unchanged; simulator builds don't need signing | shared |
| App Sandbox | `ENABLE_APP_SANDBOX = NO` — deliberate: no review to satisfy; sandbox would block webview/URLSession network for a locally-run build | n/a (iOS sandbox is mandatory OS behavior) | Mac-only |
| Entitlements | `Mattermost/Mattermost.entitlements` emptied — ad-hoc signing rejects development-cert entitlements; `SecureVault`/`CertTrust` `kSecClassGenericPassword` items scoped by `kSecAttrService` need **no** keychain-access-group | unchanged | shared |
| WKWebView hosting (`UIViewRepresentable`) | Works unchanged; verified rendering `community.mattermost.com/login` in a live window | same code | shared |
| Toolbar / server switcher / Sheets / `.confirmationDialog` | Renders in the Mac window; not interactively exercised on macOS | fully tested (XCUITest) | shared code, macOS less exercised |
| UNUserNotificationCenter authorisation | `requestAuthorization` available on macOS 10.14+/26.x; `setBadgeCount` macOS 11+ | runtime prompt, tested (T8) | shared code |
| Keychain access groups | Resolved by T22: ad-hoc Catalyst has no `application-identifier`, so it cannot SecItem at all (-34018). `SecureVault`/`CertTrust` now route through `SecretPersisting` with a `FallbackSecretPersisting` composite — Keychain first, an AES-GCM sealed file (`EncryptedFileSecretPersisting`) only when the Keychain is refused (and a read-through so Catalyst's not-found-than-throw read quirk still reaches the file). Team-signed builds use the Keychain exclusively. **Measured post-T22: the full Catalyst suite is 290/290 green with no suites skipped** (previously 236 green only by skipping the 3 Keychain suites / 15 -34018 failures) | Keychain works normally (simulator/device); fallback file never created | macOS-only divergence, fixed |
| Document picker export (`UIDocumentPicker(forExporting:)`) | Compiles for Catalyst (macOS save panel); runtime export not exercised on macOS | tested via stub server flows (T7) | shared code |

Commands, decisions, screenshots: `docs/t20-build-note.md` (`docs/t20/*.png` show the real login
page inside the Catalyst window). Debug-only `-shellSnapshot` probe in `MattermostApp.swift`
(inert without the launch argument) provides headless render proof without Screen Recording TCC.
The iOS regression suite (220 unit + 6 XCUITest) was re-run after these changes — see the T20 note
and `docs/t20-full-suite-2026-10-23.log`.