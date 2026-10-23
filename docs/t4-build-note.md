# T4 — Native JS bridge + mattermost:// deep-link routing (Phase 1)

Build note for kanban task `t_4e9ddee0`. Design doc §5: `Communication` -> `Bridge`
(`communication.ts` + preload ported to a single native WKScriptMessageHandler), and
`navigationManager` -> `DeepLinkRouter` (`onOpenURL` + `mattermost://` URL scheme).

Tracked in `docs/parity.md`. Verified on macOS (Xcode 26.6, iPhone 16 Pro / iOS 18.5
simulator `id=81A7F251-8B31-4945-8783-5A264C14B8D5`).

## What was built

### Bridge (`Mattermost/Core/Bridge.swift`) — parity `communication.ts` + both preloads
- `BridgeMessage`: message-name registry with the exact desktop strings
  (`notify_mention`, `unreads-and-mentions`, `session_expired`, `react-app-initialized`,
  `browser-history-push`, `request-browser-history-status`, `history`, `get-app-info`). Parity
  `src/common/communication.ts`.
- `JsBridge` protocol: the single native page↔shell contract — inbound page→native events
  (`handleNotifyMention`, `handleUnreadsAndMentions`, `handleSessionExpired`,
  `handleReactAppInitialized`, `handleRequestBrowserHistoryStatus`) + native→page sends
  (`pushBrowserHistory`, `navigateHistory`). Safe send helpers (`sendRawChannel`).
- `Bridge: WKScriptMessageHandler` under ONE handler name `mattermostBridge`: security-boundary
  pipeline = (1) only our handler name, (2) only main-frame, (3) only the allowlisted name set;
  malformed frames dropped; per-name payload validation. This is the desktop navigation-guard
  mirror — arbitrary page JS can never reach unreported shell capability.
- `Bridge.preloadJavascript`: injected at document-start; exposes only `window.desktop` with the
  allowlisted `post` methods; never bakes in `evaluateJavaScript`/Keychain/credentials/FS.
- `WebViewStore` registers the handler + preload on each webview's `WKUserContentController`;
  `WebViewContainer.Coordinator` adopts `JsBridge` and becomes the page-event sink (Mention/
  unreads are Phase-2 NotificationWorker/SessionStore inputs; wired to native logging now).

### DeepLinkRouter (`Mattermost/Core/DeepLinkRouter.swift`) — parity `navigationManager.ts`
- `DeepLinkParsing`: parses `mattermost://`, `mattermost-beta://` and direct http(s) links into
  `DeepLink{serverURL, path}`; guards oversized / NUL / unknown-scheme inputs (mirrors desktop
  `parseURL` + `getDeeplinkingURL`).
- `DeepLinkRouter (ObservableObject)`: `handle(_:)` entry point; queues the link until `ready()`
  then flushes; matches the link host to a configured server, switches the shell to it, and
  pushes the SPA path via the bridge (`pushBrowserHistory` — desktop `BROWSER_HISTORY_PUSH`;
  magic-link URLs load directly, mirroring navigationManager). Unmatched host / empty servers →
  `.needsServerAdd` so the shell can offer to add that URL (desktop `ServerHub`).
- App wiring: `mattermost://` + `mattermost-beta://` registered in `Mattermost/Info.plist`
  (`INFOPLIST_FILE` merged on top of the generated plist); `MattermostApp.onOpenURL` wires the
  router and calls `ready()`. Verified the built app's `Info.plist` carries both schemes.

## Verification (real output)
- `xcodebuild build` -> `** BUILD SUCCEEDED **`.
- `xcodebuild test -only-testing:BridgeTests -only-testing:DeepLinkRouterTests` ->
  `** TEST SUCCEEDED **` (25 tests, 0 failures):
  - BridgeTests (12): message-name parity, single handler name, preload exposes only
    `window.desktop`, drops non-main-frame / unknown-handler / non-allowlisted / malformed frames,
    routes `notify_mention` + `unreads-and-mentions`, WebViewStore installs one script + a
    per-server bridge.
  - DeepLinkRouterTests (13): parse mattermost/beta/http, preserve port, reject bad schemes /
    oversized / NUL; route to matching server + set primary, root path no channel, unmatched host
    and no-servers offer add, queue-until-ready flush, pre-ready unrooted ignored.
- Full project test run: 79 tests / 3 failures — all 3 failures are in T5's in-flight files
  (`ServerInfoTests`/`ServerURLValidatorTests`, the concurrent server-validation card), NOT in
  T4 scope.

## Cross-task cleanup (T5 concurrent work)
T5 (`t_093dabb4`) runs concurrently in this same shared workspace. Its source files
(`ServerAPI`, `ServerInfo`, `ServerURLValidator`, `ServerFormModel`) + a rewritten
`ServerFormView` were on disk but (a) never registered in `project.pbxproj` and (b) had compile
errors. Because `ServerFormView` (from T3) references `ServerFormModel`, the project could not
build without them. I registered them (rebuilding a pbxproj that had been corrupted by an ID
collision between my new files and T5's), and applied minimal mechanical compile fixes so the
whole project builds:
- `ServerInfo.swift`: `config.reportProblemLink` -> `config.reportAProblemLink` (member name).
- `ServerURLValidator.swift`: removed a duplicate `ServerAPI.ErrorReason` convenience init that
  made `ServerAPI.ErrorReason(...)` calls ambiguous; reordered `URLValidationResult(...)`
  memberwise args to declaration order.
- `ServerFormView.swift`: hoisted the throwing `ServerURL.normalize` out of the `??` expression.
The 3 remaining test failures in T5's test files are T5's own in-flight scope; I did not fix
them (would collide with the running T5 worker). A corrupt-pbxproj backup is at
`~/.hermes/profiles/mmios-ios/cache/scratch/project.pbxproj.conflicted`.

## Files touched this run
- `Mattermost/Core/Bridge.swift` (new)
- `Mattermost/Core/DeepLinkRouter.swift` (new)
- `Mattermost/Core/WebViewStore.swift` (register bridge handler + preload; expose `bridge`)
- `Mattermost/UI/WebViewContainer.swift` (Coordinator adopts `JsBridge`; page-event sink)
- `Mattermost/MattermostApp.swift` (`onOpenURL` -> `DeepLinkRouter`)
- `Mattermost/Info.plist` (new; declares `mattermost` + `mattermost-beta` URL schemes)
- `MattermostTests/BridgeTests.swift` (new)
- `MattermostTests/DeepLinkRouterTests.swift` (new)
- `Mattermost.xcodeproj/project.pbxproj` (rebuilt clean: 19 app sources + 7 test sources + plist)
- Ministry inspects: `ServerInfo.swift`, `ServerURLValidator.swift`, `ServerFormView.swift`
  (mechanical compile fixes to unblock the shared build)
- `docs/parity.md`, `docs/t4-build-note.md`