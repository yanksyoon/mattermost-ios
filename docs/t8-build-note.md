# T8 — Local notifications + mention/unread tracking + app-icon badge (Phase 2)

Build note for kanban task `t_0fb06daf`. Design doc §2 (`SessionStore` ≈ `AppState`,
`NotificationWorker` ≈ `main/notifications`) and §4a/§4b parity rows:
`AppState -> SessionStore`, `TrayIcon + badge -> applicationIconBadgeNumber`.
Parity baseline: `mattermost/desktop` v6.4.0-rc.2 (fetched `src/common/appState.ts`,
`src/app/system/badge.ts`, `src/main/notifications/index.ts`, `src/main/notifications/Mention.ts`,
`src/renderer/notificationSounds.ts`, `src/common/config/defaultPreferences.ts` at that tag and
mirrored their semantics).

## What was built

### `Mattermost/Core/SessionStore.swift` (new — desktop `AppState` + `badge.ts`)
- Per-server `ServerState { mentionCount, isUnread, isExpired }` keyed by server UUID (desktop's
  three maps folded into one; iOS has exactly one webview per server so the desktop per-view
  maps collapse).
- Bridge events → desktop AppState methods: `updateMentions(serverID:mentionCount:isUnread:)`
  (`unreads-and-mentions` → `updateUnreadsAndMentionsPerServer`), `updateExpired(...)`
  (`session_expired` → `updateExpired`), `clear` (session logged out → `clearServer`),
  `remove` (`SERVER_REMOVED`) plus `observeServerRemovals(from:)` so the store subscribes to
  ServerStore events exactly like desktop AppState subscribes to ServerManager.
- `recomputeTotals()` publishes the desktop `UPDATE_APPSTATE_TOTALS` triple (totalMentions,
  hasUnread, anyExpired) and the badge number; the app icon is updated through an injectable
  `BadgeSettable` (default `SystemBadge` → `UNUserNotificationCenter.setBadgeCount`, the
  supported iOS-17 path; `applicationIconBadgeNumber` is deprecated).
- Badge math is a pure `nonisolated static badgeNumber(...)`, decision order = desktop
  `showBadgeOSX`: mentions > 0 → the count; else unread-dot (gated on the "Show unread badge"
  setting, desktop `defaultPreferences.showUnreadBadge` = true, persisted); else expired-mark;
  else 0. iOS integers map the dot and the ! to 1 (documented divergence).

### `Mattermost/Core/NotificationWorker.swift` (new — desktop `main/notifications`)
- Permission on first mention (task spec): asks `UNUserNotificationCenter` once per install,
  and only when the OS status is `.notDetermined` (never re-prompts a granted/denied state);
  the asked-once flag persists in `AppPreferences`.
- `presentMention(_:fromServerID:) async` mirrors `displayMention`:
  - resolves the server by UUID (missing → `.missingServer`);
  - primary-view gate adapted for a phone: suppressed when the app is foreground **and** the
    mention's server is the visible scene (`.viewShouldNotNotify`); backgrounded → deliver;
  - builds `UNNotificationRequest`: title `"<server name>: <title>"` (desktop default title
    "Someone mentioned you" when empty), body, sound per desktop `Mention.ts`
    (`silent`/`None` → silent; named sounds → system default), `threadIdentifier` = channel id
    (native per-channel grouping — iOS analogue of the desktop's Windows per-channel dedup);
  - `userInfo` keys deliberately mirror the Mattermost push proxy's APNs `data.*` fields
    (`server_id`, `channel_id`, `team_id`, `url`, `type`="mention") so T13's Notification
    Service Extension and click-routing reuse the same contract.
- Tap routing (desktop NOTIFICATION_CLICKED): switches to the mention's server, pushes SPA
  path `/channels/<channelID>` when the SPA is ready, or queues it and flushes on the bridge's
  `react-app-initialized` (cold-launch case).
- `UNUserNotificationCenterDelegate` (willPresent → foreground banners like desktop;
  didReceive → tap routing) with the real center isolated behind `NotificationScheduling` +
  `UNNotificationCenterAdapter` so all logic is unit-testable without the framework singleton.

### Wiring
- `Mattermost/UI/WebViewContainer.swift` — Coordinator now carries `serverID`, `SessionStore`,
  `NotificationWorker`; the JsBridge placeholders became real: `handleNotifyMention` → worker,
  `handleUnreadsAndMentions`/`handleSessionExpired` → SessionStore, `handleReactAppInitialized`
  → flush queued tap navigation.
- `Mattermost/UI/ContentView.swift` passes `server.id` into `WebViewContainer`.
- `Mattermost/MattermostApp.swift` creates `SessionStore` + `NotificationWorker` as
  `@StateObject`s, injects them via environment, and in `.task` binds the worker's
  serverStore/viewStore, activates it, and subscribes SessionStore to server removals.
- `Mattermost/Core/AppPreferences.swift` — two new keys:
  `mm.settings.showUnreadBadge`, `mm.notifications.permissionRequested`.

### Tests (29 new; both suites green)
- `MattermostTests/SessionStoreTests.swift` (12): badge math matrix, cross-server totals,
  clamp/clear/remove, persisted "show unread badge" setting round-trip, server-removal
  subscription.
- `MattermostTests/NotificationWorkerTests.swift` (17): sound mapping, title composition,
  first-mention permission (asked exactly once, persisted across worker instances), denied /
  not-determined path, missing-server, foreground-visible suppression vs backgrounded
  delivery, scheduled payload (title/thread/userInfo/sound/silence), tap routing warm + cold
  (queue → flush on SPA-ready), non-mention taps ignored, and two Coordinator integration
  tests (mention → worker; unreads/expired → SessionStore).

## Verification (real output)

- `plutil -lint Mattermost.xcodeproj/project.pbxproj` → OK.
- `xcodebuild -project Mattermost.xcodeproj -scheme Mattermost
  -destination 'platform=iOS Simulator,name=iPhone 16e,OS=18.5' build` → **BUILD SUCCEEDED**.
- `xcodebuild ... test -only-testing:MattermostTests/SessionStoreTests
  -only-testing:MattermostTests/NotificationWorkerTests` → **TEST SUCCEEDED — Executed 29
  tests, 0 failures**.
- Full suite: `Executed 178 tests, with 14 failures` — every failure is pre-existing (see
  below); the 29 T8 tests and all prior green suites (ServerStore, Bridge, SecureVault,
  ThemeSync, Welcome, …) pass.
- Simulator smoke test (iPhone 16e, iOS 18.5): installed + launched `com.mattermost.ios`
  (PID alive after 6 s), screenshot `build/shots/t8-01-launch.png`, OCR shows the Welcome
  onboarding pager — no runtime crash from the new environment objects / worker bootstrap.

## Decisions & documented divergences

- **Badge glyphs**: iOS has no string dock badge; desktop's unread dot `•` and expired `!` map
  to badge value `1` (mentions still show the exact count). Order of precedence unchanged.
- **"Primary view" gate**: desktop code literally skips when the mention's view is NOT the
  primary one (background-tab mentions get no banner). On a phone with one visible scene the
  meaningful gate is the inverse: suppress only when the user is *looking at* the mention's
  server; deliver when backgrounded or the visible server is different. Documented in
  `NotificationWorker`.
- **Named sounds** (Ding/Bing/Crackle/Down/Hello/Ripple/Upstairs) are desktop renderer assets;
  iOS maps them to the system default alert rather than bundling server assets. `silent` /
  `"None"` stay silent.
- **DnD / Focus**: desktop polls the OS Do-Not-Disturb state; on iOS the system owns Focus
  suppression, so the shell schedules and the OS decides presentation.
- **No dock bounce / flash-frame**: desktop-only platform effects.
- **First-ask UX**: the mention that triggers the permission prompt cannot itself be shown
  (`.authorizationNotDetermined`); subsequent mentions appear once the user answers.
- **AppPreferences Codable-Bool caveat found + worked around**: `set(false, ...)` stores JSON
  `Data`, which the raw `bool(forKey:)` reader cannot see; both new persisted Bools therefore
  round-trip through `preferences.get(Bool.self, ...)` (added a comment at each site).
- **userInfo keys** match the Mattermost push proxy's APNs payload so T13's NSE and
  click-routing reuse the exact same contract.

## Pre-existing suite failures (NOT from T8 — files untouched by this task)

Full suite = 178 tests, **14 failures, all in sibling tasks' never-green suites**:

1. `CertTrustTests` (7) — Keychain operations throw non-success `OSStatus` on this simulator
   (SecureVaultTests pass in the same host, so the Keychain itself works; the module is T9's
   `Core/CertTrust.swift`, untouched here). The thrown error's description also hides the real
   status value. Needs T9/review rework.
2. `DownloadHistoryTests` (5) + `DownloadWorkerTests` (2) — T7's suite was *authored but never
   executed* (per `docs/t7-build-note.md`). Root causes found:
   - over-escaped string interpolations in the test fixtures (`"file-\\(i).txt"`,
     `"https://s.example/\\(name)"` are literal strings, not interpolations) — every fixture
     shares one source, so source-dedup collapses them (count 1 ≠ 50, 1 ≠ 2, 2 ≠ 1);
   - `testExportPickerBuiltForLandedFileAndMovesByDefault` builds a `UIDocumentPicker` for a
     path that does not exist (crash: `must be called with a URL pointing to an existing file`).

Recommendation: the orchestrator re-opens/reviews T7's test file and T9's CertTrust module to
green the suite. T8 deliberately did not modify either (scope + collision protocol).

## Files written/edited this run
- Mattermost/Core/SessionStore.swift (new)
- Mattermost/Core/NotificationWorker.swift (new)
- Mattermost/UI/WebViewContainer.swift (Coordinator wiring: serverID + env stores + real handlers)
- Mattermost/UI/ContentView.swift (pass server.id)
- Mattermost/MattermostApp.swift (create/inject SessionStore + NotificationWorker, .task bindings)
- Mattermost/Core/AppPreferences.swift (2 new keys)
- MattermostTests/SessionStoreTests.swift (new, 12 tests)
- MattermostTests/NotificationWorkerTests.swift (new, 17 tests)
- Mattermost.xcodeproj/project.pbxproj (4 file registrations: F2…2A-2D, F3…1C-1D, F4…0E-0F; plutil-valid)
- docs/parity.md (AppState, badge, notifications rows + phase status)
- docs/t8-build-note.md (this file)
- build/shots/t8-01-launch.png (simulator launch screenshot)

## Collision-hotspot notes (PROTOCOL)
- `Mattermost/UI/WebViewContainer.swift` was previously flagged by T7 as the concurrent-edit
  hotspot; T8 required editing it (the phase-2 bridge handlers live there). No sibling was
  mid-edit this run; the file now carries the phase-2 wiring and should be stable.
- `Mattermost.xcodeproj/project.pbxproj` was re-read fresh before adding 4 registrations
  (T7 landed its IDs just before this run); plutil-valid, no duplicate object ids.
- `docs/parity.md` was concurrently updated by T7/T9 while this run started; re-read before
  writing.

## What is NOT covered here (honest gaps)
- Live mention delivery end-to-end requires a real Mattermost server + signed-in session +
  the OS permission prompt; exercised at unit/integration level and by launch smoke test only.
- Remote push (app backgrounded/killed) is T12/T13's scope (Push Proxy + APNs + NSE) — this
  task is the foreground/local half of desktop's notifications.
