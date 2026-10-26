# Mattermost Desktop → iOS Parity Checklist

Single source of truth for the module→native mapping. Updated at each phase boundary.
Legend: `native` = implemented, `-` = not started / deferred to a later card/phase.

Design of record: `~/.hermes/plans/2026-10-08_mattermost-desktop-ios-migration.md`; the desktop
package is `mattermost/desktop` (v6.4.0-era). Status last refreshed at T31 (Path B start: transport,
local store, the native shell; native auth + session screens behind the dual-render flag — see
"Path B native cards" below).

> ## 🅱️ Path B — native client decision (T24)
> **The programme has chosen Path B (T24, `docs/path-b-adr.md`): the primary surface is becoming
> native SwiftUI driven by the Mattermost REST API v4 + WebSocket v4, not the web app.**
> The webview is retained as a first-class **per-surface escape hatch** (T46: native / webview /
> dropped per screen) behind the T26 dual-render switch until each screen is ported. The columns
> below therefore describe *reconstruction targets / statement of work* for the native data path,
> not merely the current shell health.
> - Licence boundary (recorded in the ADR): `mattermost-mobile` = Apache-2.0 (reimplement
>   patterns safely); `mattermost-webapp` = AGPL-3.0 (observe behaviour, never copy source);
>   every surface is a reimplementation against the public `https://api.mattermost.com` contract.
> - Memory premise is measured, not folklore: cited to **T27** (`docs/` memory/performance
>   baseline) once it reports.
> - Data model: REST/WS v4 pinned per server; older-server features gated explicitly, never
>   silently degraded.
> - Build order + out-of-scope list (Calls/Boards/Playbooks/plugins/System Console → webview):
>   see the ADR §2.
> This banner is the single-link anchor from the parity table to the Path B ADR.

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
| Mention polling while backgrounded (Option A, no APNs) | `Core/BackgroundRefreshScheduler.swift` + `Core/MentionPoller.swift`: `BGAppRefreshTask` (`com.mattermost.ios.refresh`, plain Info.plist keys only) registered in `AppDelegate`, submitted on `scenePhase == .background`; REST drill-down (`/users/me/teams/unread` → `/users/me/teams/{team_id}/channels/unread` → `/channels/{channel_id}/posts?since=`) gated per-server by a persisted high-water mark (`watermarkTs`/`watermarkPostID`) + 500-id dedupe ring in `AppPreferences`; first run seeds only (no history replay); new mentions flow through the same `NotificationWorker.presentMention` (identical payload/sound/threading) and the app-icon badge refreshes via `SessionStore`; expiration cancels in-flight URLSession work; Catalyst compiles to a no-op | native ✅ (T14) |
| Certificate store / trust | `Core/CertTrust.swift` (Keychain-first-persisted trust bag keyed by origin via `SecretPersisting`; `ComparableCertificate{data,issuerName,dontTrust}`; `isTrusted`/`isExplicitlyUntrusted`; wired into `WebViewContainer` `didReceive` server-trust challenge → auto-accept when already trusted, hard-reject when explicitly untrusted, default-handling for unseen. T22: ad-hoc Catalyst falls back to the same AES-GCM sealed file) | native ✅ (T9, T22 fallback) |
| DownloadsManager | `Core/DownloadWorker.swift` — `URLSessionDownloadTask` into `Documents/Downloads`, `WKDownloadDelegate` for webview files, persistent journal (`DownloadRecord`/`DownloadHistory`), Share-to-Files export via `UIDocumentPicker(initForExportingURLs)` | native ✅ (T7) |

## `src/renderer/` → SwiftUI views

| React screen | Native view | Status |
|---|---|---|
| MainPage / shell chrome | `RootView` + toolbar switcher | native ✅ |
| **Per-surface native ↔ webview switch (Path A/B)** | `Core/RenderMode.swift` (`Surface` ×12, `SurfaceRenderMode`, `SurfaceDefaults.nativeApprovedSurfaces` = the -AV approval registry) + `Core/SurfaceModeResolver.swift` (order: `-surfaceMode` launch flag → persisted override in `AppPreferences` `mm.surfaceModes` → injected remote/config default → compile default; tolerant of unknown names) + `UI/SurfaceHost.swift` (one `some View`, re-attaches the owned `WKWebView`, never recreates it) + `UI/Native/NativeShellView.swift` (the pane surface's native branch since T30) + `UI/SurfaceInspector.swift` (DEBUG-only per-surface toggle). Contract: `docs/dual-render.md` (the generic `UnportedSurfaceView` stand-in was deleted in T30-R — dead code once the shell took its only call site) | native ✅ (T26, branch T30) |
| New/Edit/Remove Server | `ServerFormView` + `.confirmationDialog` remove | native ✅ |
| LoadingScreen | `ProgressView` linear skeleton in `ContentView` | native ✅ |
| ConnectionError/Error | `ErrorStateView` + `IncompatibleErrorStateView` + `RetryButton` (ports `ErrorView`/`ConnectionErrorView`/`IncompatibleErrorView`: full desktop copy + clear-cache-and-reload + verify-URL links + contact-admin + tech info) | native ✅ (T11) |
| Welcome/onboarding | `UI/WelcomeView.swift` (TabView pager + dots/chevrons + `WelcomePagerModel` wrap/auto-advance; parity of `WelcomeScreen`/`Carousel`/`WelcomeScreenSlide`/`CarouselButton`/`CarouselPaginationIndicator`); first-run gate in `RootView.onboardingOrEmptyState` | native ✅ (T10) |
| Settings | `SettingsView` (Form with Toggle/Picker/Stepper — `CheckSetting`/`SelectSetting`/`NumberSetting` ports; theme syncing, unread badge, app language, log level, download-history cap, servers list) + `Core/AppSettings` (LocalConfiguration store) | native ✅ (T11) |
| Downloads dropdown | `DownloadsView` (List + `DownloadRowView` with `ProgressView`), port of `DownloadsDropdown`/`DownloadsDropdownItemFile`/`FileSizeAndStatus`/`ProgressBar`; formatting ports `pretty-bytes` + renderer/utils | native ✅ (T11) |
| Certificate modal | `CertPromptSheet` + `CertificateInfoSheet` (ports `modals/certificate` + `showCertificateModal`); challenge → published prompt → trust bag decision | native ✅ (T11) |

## Path B native cards — REST/WS v4 transport, local store, native shell

These rows have no single desktop module to replace: they are the **native data path** the Path B ADR
(T24) requires, and each is a prerequisite for the screens in `docs/component-map.md`. Status is
"landed", not "approved": a card's surface may flip to native only after its `-AV` card passes
(`SurfaceDefaults.nativeApprovedSurfaces` is still empty).

| Card | Native replacement | Status |
|---|---|---|
| **T28** transport (REST v4 + WebSocket v4) | `Core/MM/`: `APITransport`/`URLSessionTransport` + `APIClient` (bearer from `SecureVault`, ETag/304 replay, retry with backoff + jitter honouring a **clamped** `Retry-After`, `401 → onUnauthorized`), `AuthSession` (login/MFA/restore/logout + SSO cookie adoption through **that server's** `WKWebsiteDataStore(forIdentifier:)`), `SocketClient` (actor, hello + in-band auth challenge, ping/pong, backoff that resets only after a stable session, one resync per dropout), `ServerTrustPolicy` shared by HTTP **and** `wss`, `MMLog` token redaction. Pinned by 88 tests + `scripts/t28-token-grep.sh` + the self-signed `wss` fixture. | native ✅ (T28, repaired T28-R) |
| **T29** local store | `Core/Store/`: one SQLite file per server via GRDB 7.11.1 (pinned in `Package.resolved`), schema v1 + additive v2/v3 through a named migration chain with a downgrade guard, single writer + read snapshot, `PostRepository`/`ChannelRepository`/`DraftRepository`/`SyncCursorRepository`/`PreferenceRepository`/`UserRepository`, eviction that cascades a thread's replies with its root, and `InMemoryStore` as the contract-tested double. | native ✅ (T29, repaired T29-R) |
| **T30** native shell (navigation) | `Core/Native/NativeNavigation.swift` (one funnel: `NativeLocation` + deep-link grammar + per-server last location + auth gate + `NativeChannelDirectory` seam), `UI/Native/NativeShellView.swift` (compact = TabView with the channel view pushed; regular = `NavigationSplitView`), `UI/Native/NativePanePlaceholders.swift` (every unported region is a named placeholder, plus the auth surface and the stale-route error state). Wired through `RootView` (push stack + chrome on pushed panes) and the existing `DeepLinkRouter`/`NotificationWorker` seams. | native ✅ (T30, repaired T30-R). Limits that stay: **no channel directory yet**, so a deep link and a tapped mention converge on server + pane but not on channel identity (S08/T32-T33 installs the directory); every pane is a placeholder (T32-T36); native login is T31 (landed — the row above). |
| **T31** native auth & session surface | `UI/Native/Auth/`: `AuthCoordinator` (one `AuthSession` per server; phases unresolved → signedIn / signedOut / expired; the gate answers from the vault before the network, so a relaunch never flashes a login form; `restoreAll` at launch; a 401 from **any** native call — including the background `MentionPoller`, which reports through `reportUnauthorized` — flips the gate to one re-auth path; **an expiry and a sign-out both clear the vault entry and the webview's `MMAUTHTOKEN`**, and the local clear happens before the `/users/logout` round-trip so a kill cannot leave a usable token), `LoginViewModel`/`MFAViewModel` (mobile `login/form.tsx` + `mfa/index.tsx` rules: trimmed + lowercased id, submit enabled only with both fields, the server's own rejection sentence inline, a second-factor step that keeps its own error and clears the rejected digits), `SSOViewModel`/`SSOView` (SSO deliberately stays a webview: the IdP runs in the existing `WebViewContainer`, the sheet polls that server's `WKWebsiteDataStore`, adopts the session, then lands on the native shell), `LoginView`/`MFAView` (S01/S02) + `SessionExpiredBanner` (S03), and Settings' **Session** section (sign-out with a confirmation; *removing* a server signs it out synchronously, so no credential outlives its server). Hosted by `SurfaceHost(.auth)`; **native by default since T31-R** (T31-AV approved the surface), with the T30 stand-in still reachable as the `-surfaceMode auth=web` escape hatch. Evidence: `docs/t31-build-note.md`, `docs/t31r-patch-note.md` (the T31-AV repairs), screenshots in `docs/t31-shots/` (the sign-in, rejection and restore shots are a real `mattermost` server at `127.0.0.1:8065`) plus the light/dark/AX3/iPad captures in `docs/t31r-shots/`. | native ✅ (T31, repaired T31-R). Limits that stay: the SSO **sheet** is unit-tested but not UI-tested end to end (needs a live IdP — the shipped `testSSOReachesIdentityProviderWithoutCertificatePrompt` still guards the webview path), a session established **in the webview** is adopted only when the native shell asks it to (SSO sheet / next native sign-in) rather than continuously, and the webview's own `HttpOnly` `MMAUTHTOKEN` cookie is a second, non-`SecureVault` store that lives in WebKit's cookie database (cleared on sign-out and expiry, never written by the native path). |
| **T32** native team sidebar (S07 team selection / S08 team rail) | `UI/Native/Sidebar/`: `TeamSwitchViewModel` + `TeamSidebarDerivation` (one place for every rule — `teams_order` ordering, membership filtering with soft-delete/other-user guards, badge precedence mentions → dot → none with the selected team drawing none, `99+` cap with the true number in the accessibility value, grapheme-safe initials, and the 0/1/2+ content states), `TeamSidebarCoordinator` (**one socket per server**, not per team: ten rapid switches leave one subscription; the switch itself goes through `NativeNavigation.openChannel`, so the previous team's channel and push stack cannot survive), `TeamSocketScope` (an event reaches the screen only if it belongs to the selected team — the socket half of "no stale data"), `TeamSidebarView` (rail, icon button with a white plate so the selection ring reads on an uploaded icon, badges, empty + failure states). Selection is read from `NativeNavigation.location`, never duplicated. Transport: `GET /users/me/teams` (ETag), `/users/me/teams/members` (ETag), `/users/me/teams/unread` (**no** ETag — a replayed 304 would pin the badges), `GET /teams/{id}/image?_=<stamp>` through `APIClient` so a 401 reaches re-auth. Fixture: `scripts/t32_team_seed.py` (second team + real mention counts + uploaded icon + `teams_order`). Gated by `-surfaceMode sidebar=native` (default web = the T30 placeholder, unchanged). Evidence: `docs/t32-build-note.md`, 42 unit tests + 1 live UI test + 6 stub-backed identifier UI tests, `docs/t32-shots/` (real server at `127.0.0.1:8065`). Identifiers (repaired in T32-R, build note §14.1): `nativeSidebar` (the pane — now its anchor row, so it resolves in **every** content state, flag on or off) and `nativeTeamSidebar` (the team region, every state with the flag on); the state screens are addressed by `teamSidebar.rail` / `teamSidebar.team.<id>`, `teamSidebar.empty` + `teamSidebar.retry`, `teamSidebar.error` + `teamSidebar.retry` — the `teamSidebar.emptyState` / `teamSidebar.errorState` container identifiers never reached the accessibility tree and were removed. | native ✅ (T32, repaired T32-R). Limits that stay: the rail fronts T30's placeholder channel list — S08's channel list/categories are T33, so a switch lands on "no channel selected" rather than that team's first channel; the team *list* is not refreshed on `team_*` socket events (only counters are, coalesced); `teams_order` is read, not written; reactions are refused by the scope until the channel view resolves a post to its channel (T34); the icon cache is memory-only. |
| **T33** native channel sidebar (S08 channel list, categories, ordering, unread, mute, favourites, quick switcher) | `UI/Native/Sidebar/`: `ChannelSidebarModels.swift` (the derivation, no I/O — category/channel tree from **the server's categories**, not from a client-side guess; one drawn place per channel; unlisted channels appended to the default category for their kind; empty categories hidden except favourites; archived `delete_at != 0` hidden except the channel on screen; sort `manual` = the server's `channel_ids`, `recent` = `last_post_at`→`create_at`, `alpha` = name with **muted last**; `unread = max(total_msg_count − msg_count, 0)`; muted = `notify_props.mark_unread == "mention"`, which suppresses the message count/emphasis but **not** a mention; favourites = the `favorites` category, legacy `favorite_channel` preference only as a fallback; fuzzy search terms + ranking exact → prefix → word-start → substring → subsequence), `ChannelSidebarService.swift` (loads `/users/me/teams/{tid}/channels`, `/users/me/channel_members`, the categories endpoint; **optimistic** category writes — mutate, `PUT` the **bare categories array** (that endpoint's request *and* answer shape, measured on 9.11.19: the GET's keyed `{order, categories}` body is rejected 400 and the answer is an array, T33-R/F1), rebase on the categories the server answers with, roll back on failure; a collapse is the same write and is no longer `try?`-discarded; a **generation** guard drops a stale load after a team switch; `load(ifNeeded:)` answers from `loadedTeamID` so a re-mount does not refetch but a team switch always does), `ChannelSidebarCoordinator.swift` (one model per **server**, **reuses T32's single socket** via `TeamSocketScope` and feeds it the channel→team map; coalesces socket-driven refreshes at 1500 ms (the rail's own debounce; the build note's earlier "300 ms" was wrong — T33-AV F7); `deactivate` on sign-out/expiry so no list or map outlives the credential), `ChannelSidebarAPI.swift`, `ChannelSidebarView.swift` (sections with collapse, rows, aggregate footer, stale-counts marker, action-error banner, loading/error/retry/empty states, context menu reorder + favourite + mute), `QuickSwitcherView.swift`. App-level `@StateObject` in `MattermostApp`. Transport: `GET /users/me/teams/{tid}/channels`, `GET /users/me/channel_members`, `GET|PUT /users/{uid}/teams/{tid}/channels/categories`, `PUT /channels/{cid}/members/{uid}/notify_props`, `/users/me/preferences` (favourites fallback only). Socket: `posted`/`post_edited`/`post_deleted`/`preferences_changed` → coalesced counter refresh; `channel_viewed` for me → that row clears; `multiple_channels_viewed` for me (the **view** call's event, `POST /channels/members/{uid}/view`, `data.channel_times`) → every row the frame names that this list holds clears, so a channel read in another client of the same user stops reading "Unread" without a relaunch (T33-AV2 F1); `post_unread` for me → the server's own counters applied to that row (the **mark-unread** event, `POST /users/{uid}/posts/{pid}/set_unread` — the view call does not send it); `channel_member_updated` for me → the whole membership row (a mute set in another client) applied; `sidebar_category_updated` → the layout the server stored applied to the open list (that is what makes an external reorder/collapse/favourite visible without a relaunch); `channel_created` → coalesced **full** reload; `channel_deleted` → coalesced counter refresh (the channel read drops it); `channel_viewed`/`typing` scoped as before. Fixture: `scripts/t33_channel_seed.py` (also creates the perfprobe↔opsbot DM the DM search test needs, idempotently). Gated by `-surfaceMode sidebar=native` (default web = the T30 placeholder, unchanged; asserted both ways). Evidence: `docs/t33-build-note.md`, `docs/t33r-build-note.md` (the T33-AV repairs), `docs/t33r2-build-note.md` (the T33-AV2 docs/coverage repairs), 73 unit tests + 8 live UI tests + 5 stub-backed UI tests, `docs/t33-shots/` (real server at `127.0.0.1:8065`; `t33-01`…`t33-13`). Identifiers: `channelSidebar.category.<type>`, `channelSidebar.channel.<id>` (`label` = the server's `display_name` — for a DM, the resolved other person, as desktop shows — `value` = "Selected, Muted, 2 mentions, Unread" sentence), `channelSidebar.quickSwitcher` + `.field` + `.result.<id>`, `channelSidebar.totals`, plus `channelSidebar.loading` / `channelSidebar.error` + `channelSidebar.retry` / `channelSidebar.empty` / `channelSidebar.staleCounts` / `channelSidebar.actionError`. | native ✅ (T33). On the pinned server (v9.11.19) the sidebar layout is **not** a `Preferences` row — a probe of `/users/{id}/preferences` has no sidebar category at all; the authority is `/users/{uid}/teams/{tid}/channels/categories`, which is what the web app itself reads and writes, so "matches `sidebar_preferences`" is implemented as "matches the server's category list". Limits that stay: reorder is the context menu's Move up/Move down (same `PUT` a drag writes) — **no drag-and-drop**; no category create/rename/delete and no create-channel (S10); favourites are the category, not a preference row; the quick switcher searches the **loaded** team's channels + DMs only (no user/message search — S09); only the selected team's list is loaded (a switch costs one request); no offline list from T29 (socket + reload only); approximate counting (`channel_approximate_view_time`) not implemented. Totals are **desktop-exact**: a muted channel contributes nothing to the footer aggregate — neither its messages nor its mentions — because `getTeamsUnreadStatuses` skips a muted channel before either count is added. The T32 rail above the footer badges the server's `teams/unread`, which is **not** mute-aware (a separate read-out, not the footer's source); the two can therefore differ by one muted mention, and the footer follows desktop rather than the rail (T33-R/F2). |
| **T34** native channel view and post list (the read surface: list, markdown, reactions, attachments, paging) | `UI/Native/Channel/`: `Markdown/MarkdownModel.swift` + `MarkdownParser.swift` (one parser for both drawing and sanitising, so what is rendered and what is trusted cannot disagree: fenced code with its language, ATX/setext headings, blockquotes, ordered/unordered lists, GFM tables, emphasis including `***` nesting, code spans, links/autolinks through a scheme allow-list with a control-character guard, `@mention` / `~channel` / `:emoji:` / emoticons / entities. **Post text is never interpreted as HTML**: `<script|style|iframe|object|embed|svg|math>` bodies are dropped and any other tag is shown as text — a plugin message is untrusted input), `Markdown/CodeHighlighter.swift` (profile tokeniser; colour only, so it is lossless — the author's bytes are drawn unchanged), `Markdown/MarkdownView.swift` (AttributedString body, horizontally scrollable code blocks, `Grid` tables, quotes, lists, the built-in emoji table, and **the server's custom emoji as images**), `EmojiCatalogue.swift` (`GET /emoji` paged 200 at a time, lower-cased name→id, `delete_at` filtered, image bytes fetched once per name by `GET /emoji/{id}/image`; the **name list and the image table are published**, so a paragraph drawn before `/emoji` answered repaints instead of keeping the literal `:name:` — T34-R3, the live suite caught exactly that), `PostListModels.swift` (`PostListDerivation`, no I/O: newest-first ordering, 5-minute author grouping, day separators Today/Yesterday/weekday/date, the `last_viewed_at` "New messages" divider, edited/deleted/system flags, reaction grouping + ordering, attachment rows with the server's own file name and size, and the fold rule — including **inside** a block, so a single 5,000-line fence or a 40 K-character paragraph is bounded and "Show more" is never a no-op), `ChannelViewModel.swift` (first page, `loadEarlier()` with a `before` cursor whose merge drops ids already held — the cursor is the **page's** oldest id, not the last row kept, so a page that carries replies cannot stall it — socket `posted`/`post_edited`/`post_deleted` patching in place — a replayed `posted` replaces, never appends — a generation guard that drops a superseded load, and the scroll anchor; the timeline's membership rule is stated once, `isTimelineRow`, and used by **both** the page merge and the socket handler — T34-AV-F1/R5), `ChannelService.swift`/`ChannelAPI.swift` (`/channels/{id}/posts` first page **without** ETag so a replay can never leave a cold start empty, and **with `collapsedThreads=true`** so the server answers top-level posts only; `/users/ids`, `/channels/{id}/members/me` for `last_viewed_at`, `/emoji`, file bytes), `ChannelPaneCoordinator.swift` (LRU of six panes per server, one image cache per server), `ChannelView.swift` + `PostRowView.swift` (list + load-earlier sentinel, and a scroll restore applied through the scroll view's **point offset**, measured from each row's own `UIView` against the viewport — `ScrollRestorePlan` + `RowAnchorProbe` — so a reader half-way through a post is not moved by up to a row height, and a correction cannot be applied twice: T34-R4 replaced the SwiftUI-preference measurement that made the anchored post jump 585 pt), plus the app wiring (`NativeChannelPaneView` → `ChannelPaneContent`, the rail's single socket fanned in, teardown on auth loss). Fixture: `scripts/t34_post_seed.py` (one post per state in `t34-showcase`, a 503-post `perf-feed`, the single-block `t34-fold`, and a real custom emoji), `scripts/t34_capture_fixture.py` (the capture the pager test replays through the real `loadEarlier()` — taken with `collapsedThreads=true`, i.e. the request the app makes: `perf-feed`'s 215 roots, not its 503 posts), `scripts/t34_emoji_probe.py`. Gated by `-surfaceMode shell=native`. Evidence: `docs/t34-build-note.md` (§7 the live runs, §8 this round's repairs), **131 T34 unit tests** (`MattermostTests/T34*.swift`), the live suite `MattermostUITests/T34ChannelPostListUITests` **6/6 green twice** (`build/logs/t34r4-suite1.log`, `t34r4-suite2.log`, real server at `127.0.0.1:8065`), and `docs/t34-shots/` (nine screenshots exported from those runs' attachments, including the byte-identical before/after pair that proves a page insert does not move the anchored post). Identifiers: `channelPostList`, `channelPostList.loadEarlier` (+ `.loading`, `.error`, `.retry`, `.empty`), `post.<id>` with `.author` / `.edited` / `.system` / `.deleted` / `.reaction.<name>` / `.attachment.<fileID>` / `.foldSummary` / `.showMore`, `channelNewMessages`, `channelDateSeparator.<dayKey>`, `nativeChannelTitle`, `nativeChannelThreadsButton`, and `channelPostList.forceLoadEarlier` (a `-uiTestExposeLoadEarlier` launch-argument seam that also publishes "<n> posts loaded" as its accessibility value, so a page insert is observable instead of inferred). | native ✅ (T34, repaired T34-R3). Limits that stay: the composer is a placeholder (S14/T35), so the pane is read-only; **the centre timeline holds top-level posts only** — the page asks the server for `collapsedThreads=true` and any reply (`root_id != ""`) that still arrives is dropped by the same rule the socket uses (`ChannelViewModel.isTimelineRow`), so a reply is a row or not for exactly the same reason however it arrived (T34-AV-F1: before the repair 288 of `perf-feed`'s 503 rows were replies drawn as top-level messages, while a reply posted from another device never appeared at all); replies themselves are the thread pane's (S11/T36) and the Threads button still opens T30's placeholder, and a reply arriving over the socket does not refresh its root's `reply_count` until the pane is reopened (that count is T36's to draw); reactions are drawn but not tappable, and there is no react / edit / delete / flag / permalink UI; an attachment draws a thumbnail or a file row with **no** download-and-share hand-off yet (T7's `DownloadWorker` is not wired into a row); an image in a post **body** (`![alt](url)`) is drawn as its alt text plus a link and is **never fetched** — only attachment files are (`Markdown/MarkdownView.swift` states this at the image segment); `@mention` / `~channel` are styled text rather than navigation; tables scroll sideways instead of wrapping; a page is the server's 60 and the old end stops at "This is the beginning of the channel" (no jump-to-date); the pane reads REST + socket live and does not use the T29 store, so nothing is available offline; and the fold summary counts blocks/lines with this client's own thresholds rather than copying upstream's exact numbers. |
| **T35** native composer + autocomplete (S14 + S15: input, markdown toolbar/preview, `@`/`#`/`:` completion, uploads with progress and cancel, send/edit/delete, drafts) | `UI/Native/Composer/`: `ComposerModels.swift` (pure logic, no I/O — `ComposerTriggerParser` with a word-boundary rule so an email address is not a mention and a URL fragment is not a channel; `ComposerMarkdownEditing` (bold/italic/strike/code/code-block/link/quote/list applied to a selection, caret preserved, `messageForSending`); `ComposerMembership.filter` — the `@` list is checked against the channel's member list **by user id**, because the member list is ids while the value that gets typed is a username (comparing names dropped everyone: found by the live suite); `ComposerRowPermissions` — who may edit/delete a row, as one rule (an empty post author or an unresolved session user is *not* "mine"); `ComposerSuggestionRanking`; `ComposerErrorCopy`), `ComposerAPI.swift` (`POST /posts` with `pending_post_id`, `PUT /posts/{id}`, `DELETE /posts/{id}`, `POST /files` multipart, `GET /users/autocomplete` — **its answer is an object `{"users":[…]}`**, not a bare array; `POST /teams/{id}/channels/search` with a `{"term","limit"}` body — **the GET form of that path is a 404 `api.context.404.app_error` on 9.11.19**, both measured, both pinned by unit tests; `GET /channels/{id}/members`), `ComposerService.swift`, `ComposerDraftStore.swift` (GRDB; one SQLite file per **server** at `Application Support/MattermostStores/<server uuid>.sqlite`, one row per `(channel, thread root)` in T29's `draft` table, empty draft ⇒ row deleted — the composer's rule, not the store's), `ComposerViewModel.swift` (send = optimistic row with a `pending:<uuid>` id ⇒ the REST answer replaces it by `pending_post_id` ⇒ the socket echo replaces **the same** row (either order, never a second row); a retry re-sends **the same** client id; a failed send keeps the text and writes the draft immediately; one upload at a time per file with progress from the transport's byte count, cancel really cancels (`URLError.cancelled` → `MMError.cancelled`), **no automatic retry** — a replayed upload can duplicate an attachment; edit/delete go through the same tombstone path as the socket, so a message deleted here and one deleted elsewhere converge; autocomplete is generation-guarded so a late answer cannot overwrite a newer one; `memberListIfNeeded` treats a failed member fetch as *unknown* (no filtering) rather than *empty* (which would hide every name)), `ComposerView.swift` (input, markdown toolbar + preview, suggestion list, attachment tray whose `accessibilityValue` is the upload's real state, banners, send). Channel side: `ChannelViewModel.insertPendingPost` / `confirmPendingPost` / `removePendingPost` / `reconcile`, pending rows fed through `PostListDerivation` so an optimistic row sorts, groups by author and separates by day exactly like a committed one, and `ChannelView`'s row actions: an overflow button per row (`post.<id>.menu`) opening one `PostOptionsSheet` for the window, with the entries decided by `ComposerRowPermissions` and the offer limited to rows a reader can act on (no menu on a system line, a tombstone or an optimistic row) — a `.contextMenu` long press is unreachable on iOS 26, where the press opens the *text* menu instead (`docs/t35-build-note.md` §7.1). Fixture: `scripts/t35_composer_seed.py` (channel `t35-composer` in team `perf`, `t35-second-chat` in a second team `t35-second` so a **team** switch is testable). Gated by `-surfaceMode composer=native` **and** `shell=native`; the default stays web until T35-AV approves. Evidence: `docs/t35-build-note.md`, **105 T35 unit tests** (`MattermostTests/T35*.swift`), the live suite `MattermostUITests/T35ComposerUITests` **7/7 green** (real server at `127.0.0.1:8065`, `build/logs/t35r2-live3.log`; the earlier 5/7 run and what it exposed are `build/logs/t35-live5.log` + build note §7) and re-derived in T35-R together with the membership **negative** case (7/7, 322 s, `docs/t35r-f4-live-2026-10-25.log` — and the same test fails by name when the filter is deleted, `docs/t35r-f4-mutation-2026-10-25.log`, build note §8.1), `docs/t35-shots/` (15 screenshots exported from that run, including the delete tombstone and the draft restored after a relaunch). Identifiers: `channelComposer` (container — it carries `.accessibilityElement(children: .contain)`, without which every child reported `channelComposer` and nothing inside the write surface could be addressed), `channelComposer.input` / `.send` / `.attach` / `.menu` / `.format.<action>` / `.preview` (toolbar toggle) / `.previewPane` / `.attachments` / `.attachment.<filename>` (value `queued` \| `uploading <n>%` \| `uploaded <file id>` \| `failed <reason>`) / `.status` / `.failure` + `.retry` / `.error` / `.editingBanner` / `.replyBanner` / `.cancelMode`, `composerSuggestions` + `composerSuggestion.<kind>-<value>`, `post.<id>.menu` (the row's actions button) with the sheet it opens at `postOptions.reply` / `.edit` / `.delete` / `.cancel`, and `post.pending:<uuid>` for a row the server has not answered yet. | native ✅ (T35) behind the flag. Limits that stay: the input is a `UITextView` bridge — no rich text and no inline styling while typing (the preview is the block-level `MarkdownView` from T34); no emoji **picker** (S17/T37) and the `:` list completes the built-in names plus T34's server catalogue only; no slash commands and no `@channel/@here/@all` confirmation (they are inserted as text); channels are the only `#` source (no user search); a reply is sent but **not** inserted optimistically, because a reply is not a row of this timeline (T34-R5) — the thread pane is S13/T36, and a reply's send shows as a status line instead of a row; scheduled posts (S40) are not implemented; **no global drafts list** — drafts are per `(channel, thread root)` and there is no S14 `GlobalDraftsView`, so the webapp's drafts screen has no native counterpart and the screen is unowned on the board; the tray accepts whatever the pickers hand over with **no size check, no image downscale and no camera capture** (the server's own upload limit is the only bound); an edit can change the message but not its attachments; the composer never touches the T29 store, so a draft is the only offline artefact (it is written through on every change — no debounce window a killed process can outlive, `docs/t35-build-note.md` §7.3); **the "one message, not two" guarantee is process-local** — the client id and the failed phase live in `ComposerViewModel`'s memory (`pendingCommand`, `phase`) while the draft store keeps only the text, so a send that landed but whose answer was lost, followed by a process death, comes back as a plain draft and the next Send mints a new `pending:<uuid>` that the server's idempotency cannot match (`docs/t35-build-note.md` §2.5 — a documented limit, not measured end-to-end on this host); a delete is confirmed by the server's own answer, which on 9.11.19 is a **404** to `GET /posts/{id}` rather than a `delete_at` field (`scripts/t35_softdelete_oracle.py`, §7.2); the list is not marked read by a send beyond the `channel_viewed` the shell already sends; and uploads are sequential per file (no parallel queue, no background continuation). |

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
- Phase 5 (perf/dual-render, T26/T27): T26 DONE (`SurfaceHost`/`SurfaceModeResolver`/inspector,
  `docs/dual-render.md`) and repaired in T26-R/T26-R4; T27 DONE (memory/perf baseline,
  `docs/t27-build-note.md`).
- Phase 6 (app store readiness/release gate): T18 done; T19a (diagnostics/Sentry) done;
  T20 (Mac Catalyst build) done — `docs/t18-build-note.md`, `docs/t19a-build-note.md`,
  `docs/t20-build-note.md`.
- **Path B — native data path (started):** T28 DONE (REST v4 + WebSocket v4 transport, SSO cookie
  adoption, shared TLS trust policy; repaired in T28-R), T29 DONE (per-server SQLite store with
  migrations, repositories, eviction; repaired in T29-R), T30 DONE (native shell + navigation
  skeleton behind the dual-render flag; repaired in T30-R — see `docs/t30-build-note.md` §12),
  T31 DONE (native auth + session surface: sign-in, MFA, session restore/expiry, sign-out and the
  webview SSO hand-off; **`.auth` is native by default** since the T31-AV approval landed in T31-R —
  see `docs/t31-build-note.md` and `docs/t31r-patch-note.md`).
  The remaining screens follow (`docs/component-map.md`). `auth` is the only surface in
  `nativeApprovedSurfaces`; every other surface still renders the webview, and no surface owns a
  pane (`paneOwningSurfaces` is empty), so the release path stays inert.

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