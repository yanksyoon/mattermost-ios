# T3 — Multi-server store + server switcher + per-server data store (Phase 1)

Build note for kanban task `t_9ed2e259`. Design doc §5:
`ServerManager`/`ViewManager` → `ServerStore`/`ViewStore`, per-server isolated `WKWebsiteDataStore`.

Tracked in `docs/parity.md` (single source of truth). This note records what T3 built and how
it was verified on macOS (Xcode 26.6, iPhone 16 Pro / iOS 18.5 simulator,
`id=BC680916-3B8A-4B9F-9417-88DC86CAC79A`).

## What was built

Shell (native SwiftUI) + per-server `WKWebView` hosting the Mattermost web app. No chat client
re-implemented.

### Core stores (parity: `src/common/`)
- `ServerConfig` (`Core/ServerConfig.swift`) — `Codable, Identifiable, Hashable`: uuid, name,
  url, order, lastActiveAt, hasSession. Plus `ServerURL.normalize` (scheme default→https,
  trailing-slash strip, trim, validation) — parity `utils/url.ts` + `Validator.ts`.
- `ServerStore` (`Core/ServerStore.swift`) — `ObservableObject`, `@Published [ServerConfig]`
  + `activeServerID`; CRUD `add/update/remove/switchTo`; emits `Event` (`added/removed/updated/
  switched`) mirroring desktop `SERVER_*` IPC events; duplicate-host guard; last-active-first
  `initialServer`; persistence via `AppPreferences`/UserDefaults; `hasEverConfiguredServers`
  so a genuinely-emptied list is never re-seeded on launch. Parity `ServerManager.ts`.
- `ViewStore` (`Core/ViewStore.swift`) — `@MainActor ObservableObject` mapping server uuid →
  live `WebViewStore` (its own `WKWebView`), primary-view tracking, tear-down `remove(serverID:)`
  that also purges the server's isolated on-disk data store. Parity `ViewManager.ts`.
- `WebViewStore` (`Core/WebViewStore.swift`) — `ObservableObject` owning one `WKWebView`;
  per-server isolation via `WKWebsiteDataStore(forIdentifier: serverUuid)` (named persistent,
  never `nonPersistent()` so the login survives relaunch); desktop/Electron UA pinned;
  KVO→Combine progress/loading/title/url. Parity `BaseWindow`/`MattermostWebContentsView`.
- `AppPreferences` (`Core/AppPreferences.swift`) — generic Codable atomic store over
  UserDefaults. Parity `JsonFileManager.ts`.

### Shell UI (parity: `src/app` + `src/renderer`)
- `RootView` (`UI/RootView.swift`) — multi-server root: mounts one scene per configured server
  (inactive scenes stay mounted but hidden so their webview/session survives a switch), nav-bar
  server switcher `Menu` (mirrors `ServerDropdownButton`), add-server `+`, remove via
  confirmation dialog, first-run community seed, phase-aware stopLoading on background.
  Parity `MainWindow` + `TabManager` + `ServerDropdownButton`.
- `ContentView` (`UI/ContentView.swift`) — per-server scene: `WebViewContainer` + native linear
  `ProgressView` (from `estimatedProgress`) + `ErrorStateView`/Retry on navigation failure.
  Parity `ConnectionErrorView` + `LoadingScreen`.
- `ServerFormView` (`UI/ServerFormView.swift`) — add/edit server sheet with
  `ServerURL.normalize` + duplicate-host rejection. Parity `NewServerModal` (full `/api/v4`
  validation is the follow-up T5).
- `WebViewContainer` (`UI/WebViewContainer.swift`) — `UIViewRepresentable`; Coordinator is the
  `WKNavigationDelegate`/`WKUIDelegate` policy surface: TLS challenge hook (default handling for
  public chain; `CertTrust` plugs in here in Phase 2), JS `alert/confirm/prompt` suppressed
  (mirrors desktop navigation guards — security boundary). Parity `BaseWindow` +
  `communication.ts` guards.
- `MattermostApp` (`MattermostApp.swift`) — `@StateObject ServerStore` + `ViewStore`, hosting
  `RootView`, so all webviews/data stores live for the app's lifetime.

## Verification (real output)

- `xcodebuild build` → `** BUILD SUCCEEDED **` (24 test files/build targets wired into
  `Mattermost.xcodeproj`).
- `xcodebuild test` → `** TEST SUCCEEDED **`, `Executed 24 tests, with 0 failures`:
  - `ServerURLTests` (6): scheme defaulting, trailing-slash, explicit http+port, trim, empty/
    invalid throws.
  - `ServerStoreTests` (7): order/unique-id, duplicate-host rejection (incl. `:443` == default
    port collapse), persistence round-trip + active-id restore, remove re-assigns active, last-
    active-first initial, empty-but-touched not re-seeded.
  - `ViewStoreTests` (7): one webview per server (identity reused), isolated per-server data
    store (never the shared default), stable uuid key across store recreation, primary tracking,
    remove drops store + clears primary, mounted order, and **`testAuthCookiesDoNotLeakBetweenServers`**
    — writes an `MMAUTHTOKEN` cookie into one server's jar and asserts a second server's jar
    does not receive it (the real session-isolation proof).
  - `WebViewStoreTests` (5): inline playback + no media types requiring user action, single
    reusable webview, load clears error, initial empty state, desktop UA pinned.
- Simulator: app installed + launched (`com.mattermost.ios`). Screenshot OCR of
  `build/shots/t3-01-root.png` confirms the multi-server shell: nav-bar switcher
  (`<active server> V` + chevron when >1 server), `+` add-server button, and the Mattermost web
  app login page rendered in the webview. The persisted registry already held two servers
  (`Community (work)`, `Community (personal)`); the relaunch re-selected the last-active one
  (`mm.servers.active` = second server's uuid), demonstrating switch persistence + last-active
  re-selection on launch.

## Change made during this run

`ServerStore.identityKey` treated the default HTTPS port 443 as significant, so
`https://a.example` and `https://a.example:443` were seen as different hosts — the desktop
`ServerManager` keys by host regardless of default port, and the existing test
`testAddRejectsDuplicateHost` exercised exactly this. Fix: collapse default ports (https:443,
http:80) before host comparison. This was the one test failing at handoff; all 24 now green.

## Files touched this run
- `Mattermost/Core/ServerStore.swift` (identityKey default-port collapse fix)
- `docs/t3-build-note.md` (this note)
- `build/shots/t3-01-root.png` (simulator proof)

## Parity status (T3 scope)
ServerManager→ServerStore, ViewManager→ViewStore, JsonFileManager→AppPreferences all native
and tested. Remaining Phase-1/3 items are separate cards: Bridge (`communication.ts`), `/api/v4`
server-info validation in the add form (T5), deep links (`DeepLinkRouter`).