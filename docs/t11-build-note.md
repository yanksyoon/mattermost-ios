# T11 — SwiftUI Settings + Downloads + Error/cert sheets (Phase 3)

Build note for kanban task `t_1f7d359d`. Design doc §§4d (`SettingsModal`/`DownloadsDropdown`/
`ConnectionError`/`IncompatibleError`/`Error` + certificate modals → SwiftUI) and §5 items
20–23. Verified on macOS/Xcode via `xcodebuild` (iPhone 16e / iOS 18.5 simulator).

## What was built

Four shell screens ported from the desktop renderer (design §4d table rows):

### `UI/SettingsView.swift` + `Core/AppSettings.swift` (SettingModal port)
- `SettingsView` is a `Form` — the exact control repertoire of the desktop `SettingsModal`
  (`definition.tsx`), category-sections mirroring the desktop sidebar (General / Notifications
  / Language / Servers / Advanced):
  - **Toggle** — the `CheckSetting` port: "Synchronize app theme with server" (`themeSyncing`)
    and "Show red badge on app icon to indicate unread messages" (`showUnreadBadge`, bound
    straight into `SessionStore` — the desktop `showUnreadBadge` source of truth).
  - **Picker** — the `SelectSetting`/`RadioSetting` port: App Language (system-default +
    locales, `localeTranslations`-style list) and Advanced Logging level (desktop's six
    `error/warn/info/verbose/debug/silly` levels with their `defaultMessage` labels).
  - **Stepper** — the `NumberSetting` port: "Keep up to N downloads in history", wired to
    `DownloadHistory.setMaxRecords`.
  - **ServerSetting** — inline servers list with Add / Edit (opens `ServerFormView`) /
    Remove (`.confirmationDialog`).
  - **DownloadSetting** — read-only Download Location row (iOS sandbox pins to the app
    Downloads dir; renderer folder-picker has no meaning).
- `Core/AppSettings.swift` — `@MainActor ObservableObject`, the `LocalConfiguration` store
  (desktop reads config over IPC; this binds the Form). Persists via `AppPreferences`
  (`themeSyncing` default true, `logLevel` default `'info'` — desktop `defaultPreferences`
  parity). Wires `Logger.setMinimumLevel` on change; `MattermostApp` subscribes
  `$downloadHistoryLimit` → `DownloadHistory.setMaxRecords` so the Stepper re-trims the live
  journal.

### `UI/DownloadsView.swift` (DownloadsDropdown port)
- `DownloadsView` `NavigationStack` + `List` with "Clear All" (clearFinished) + empty
  `ContentUnavailableView`, over the T7 `DownloadWorker.history` journal.
- `DownloadRowView` — port of `DownloadsDropdownItemFile`: SF-Symbol file-type thumbnail
  (getIconClassName), filename, `FileSizeAndStatus` line, `ProgressView` while `downloading`,
  and a three-dot `Menu` for the desktop popout actions: **Open in Files** (`UIDocumentPicker`
  via `DownloadWorker.exportPicker`), **Share** (`UIActivityViewController`), **Retry**,
  **Cancel**, **Delete**.
- `DownloadFormatting` — pure ports of `renderer/utils.ts` + `pretty-bytes`:
  `prettyBytes`, `fileSizeOrBytesProgress`, `fileStatus`, `fileSizeAndStatus`, `progress`,
  `iconName`. Unit-tested.
- `DownloadRecord: Identifiable` added (additive, one-line).

### `UI/ErrorStateView.swift` (ErrorView / ConnectionError / Incompatible / RetryButton)
- Expanded the lean stub into the full desktop error cluster: `ErrorStateView` (ConnectionError
  copy: "Couldn't connect to this server" + bullets + contact-admin + tech info), the
  `IncompatibleErrorStateView` ("Incompatible server version"), and a `RetryButton`. Desktop
  "clear the cache and reload" link → `WebViewStore.clearCacheAndReload` (real
  `WKWebsiteDataStore` cache wipe + reload); "Try opening {url} in a browser" → `UIApplication
  .open` (no Electron browser window on iOS). `ContentView` still uses the same
  `ErrorStateView(error:onRetry:)` entry point.

### `UI/CertPromptSheet.swift` + `Core/CertTrust.swift` additions (certificate prompt sheets)
- `CertPromptSheet` — desktop `modals/certificate` port: shows the untrusted server/cert,
  with **Trust**, **Cancel**, **Don't Trust and Don't Ask Again**, and a
  **Certificate Information** detail push.
- `CertificateInfoSheet` — `showCertificateModal` port: Subject Name / Issuer Name / Serial /
  validity / SHA-256 fingerprint.
- `Core/CertTrust.swift` additions: `CertificateInfo` + `CertificatePrompt` models and
  `CertTrust.info(from:)` (subject/issuer/serial/fingerprint from the live `SecCertificate`)
  + a `Data.sha256Digest()` helper.
- **Wiring** (`WebViewStore` + `WebViewContainer` + `ContentView`): the server-trust
  challenge's "unseen certificate" branch (previously default-handle + log) now publishes
  `store.pendingCertificatePrompt`; `ContentView` presents `CertPromptSheet` off it;
  `resolveCertificateDecision` records `certTrust.add(...)` (or the `dontTrust` refusal) and
  reloads — the desktop confirm → `certificateStore.add` → reload flow. Guarded: only the
  native challenge handler reaches the trust bag; page JS cannot (bridge surface closed).

## Divergences (documented)
- `viewLimit` (max tabs/windows per server) has **no iOS analog** — iOS keeps one webview per
  server, so the desktop NumberSetting maps to the real shell number `downloadHistoryLimit`
  instead (`AppSettings` doc-comment + this note).
- Window/tray chrome, `autoCheckForUpdates`, metrics/Sentry, session attributes, hardware
  acceleration, spell-checker and dock/taskbar notification settings are omitted (no iOS
  analog; enumerated in `AppSettings`).
- `CertificateInfo` validity dates are `nil` — the iOS Security SDK does not expose the X.509
  validity OIDs through public headers (`SecCertificateCopyValidityDates` is macOS-only), so
  the info sheet shows subject/issuer/serial/fingerprint rather than guessing OID strings.
- Desktop `prettyETA` ("X sec remaining") is replaced by a stable status label in the row
  (bandwidth math needs the item's addAt-relative timing; the status text is the durable
  surface). `prettyBytes` uses SI units exactly like the desktop's `pretty-bytes` dependency.

## Verification (real output)
- `xcodebuild build` → **BUILD SUCCEEDED**.
- `xcodebuild test` (T11 suites) → 41/41 green: `AppSettingsTests` (10), `CertPromptTests`
  (9), `DownloadFormattingTests` (16), `DownloadHistoryCapTests` (6).
- `xcodebuild test` (full) → **220 tests, 7 failures — all pre-existing T7
  `DownloadWorkerTests`** (over-escaped fixture interpolations + exportPicker-needs-file,
  flagged at T7/T8 handoff for orchestrator rework). **0 failures from T11.** The 7 previously
  failing `CertTrustTests` now pass (the concurrent T9 sibling's `CertTrustDebugTests` work
  touched that area).
- Simulator launch: app boots to the Welcome pager (`build/shots/t11-01-launch.png`), process
  alive after 4 s — no runtime crash from the new RootView environment objects or sheets.

## Files written this run
- Mattermost/UI/SettingsView.swift (new)
- Mattermost/UI/DownloadsView.swift (new)
- Mattermost/UI/ErrorStateView.swift (rewritten: full error cluster)
- Mattermost/UI/CertPromptSheet.swift (new)
- Mattermost/Core/AppSettings.swift (new)
- Mattermost/Core/CertTrust.swift (CertificateInfo/Prompt models + info(from:) + sha256Digest)
- Mattermost/Core/WebViewStore.swift (pendingCertificatePrompt + resolve + clearCacheAndReload)
- Mattermost/Core/DownloadHistory.swift (instance maxRecords + setMaxRecords)
- Mattermost/Core/DownloadRecord.swift (Identifiable conformance)
- Mattermost/Core/Logger.swift (setMinimumLevel gate)
- Mattermost/UI/WebViewContainer.swift (cert prompt publish + decision handler)
- Mattermost/UI/ContentView.swift (cert sheet + full error init)
- Mattermost/UI/RootView.swift (Settings + Downloads toolbar buttons + sheets)
- Mattermost/MattermostApp.swift (AppSettings mount + history-cap pipeline)
- MattermostTests/SettingsViewTests.swift, DownloadsViewTests.swift, CertPromptTests.swift (new)
- Mattermost.xcodeproj/project.pbxproj (registered 7 new files; re-read fresh after the T9
  sibling's concurrent CertTrustDebugTests landed colliding IDs F2…31/F4…10 — renumbered mine
  to F2…2E/2F/30/32/33/34/35 + F3…1E..21 + F4…11/12/13; plutil-valid, no duplicate ids)
- docs/parity.md, docs/t11-build-note.md (this file)

## Collision-hotspot flag (PROTOCOL)
`Mattermost.xcodeproj/project.pbxproj` collided in this very run: the T9 sibling registered
`CertTrustDebugTests.swift` (F2…31/F4…10) between my baseline read and my registration, and my
first fuzzy patch clobbered the F4…0F `NotificationWorkerTests` line. I re-read the file
fresh, repaired the clobber, renumbered all seven of my registrations clear of the sibling's
IDs, and plutil-validated with a duplicate-object-id scan (clean). This is the third
consecutive phase-3 run to hit this file — the orchestrator should decompose/version
`project.pbxproj` before the next UI registration cards (T15/T17 downstream of this card).