# T7 — DownloadWorker: URLSession downloads, history, Share/Files export (Phase 2)

Build note for kanban task `t_2d60d231`. Design doc §4c (`DownloadsManager` →
`DownloadWorker`: `URLSessionDownloadTask` into app `Documents/Downloads`, `WKDownloadDelegate`
for webview-initiated files, persistent download journal, Share-to-Files export via
`UIDocumentPicker`) and §5 items 12–13. Verified on macOS/Xcode via `xcodebuild`.

## What was built

### `Core/DownloadRecord.swift` (new)
- `DownloadState : Int, CaseIterable, Codable` — `downloading / done / cancelled /
  waitToRetry / error`, mirroring the desktop `downloadsManager.ts` `DownloadItem.state`.
- `DownloadRecord : Codable, Equatable, Hashable` — persisted one-row model: id (`UUID`),
  filename, source URL string, destination `file://` string, state, `totalBytes` /
  `receivedBytes`, `startedAt`, optional `finishedAt`; plus a `targetURL: URL?` convenience for
  the export path. Round-trips through `AppPreferences`/`UserDefaults` (desktop `JsonFileManager`).

### `Core/DownloadHistory.swift` (new)
- `DownloadHistory : ObservableObject` — the journal (`@Published [DownloadRecord]`,
  newest-first) that the DownloadsView binds to. Add/update/remove/`clearFinished`, hard cap at
  `maxRecords = 50` (oldest dropped), and **source-dedup** (re-downloading a URL replaces the
  prior in-flight entry — the design's "download dedup"). Persists to
  `AppPreferences.Keys.downloadsHistory` (`mm.downloads.history`).

### `Core/DownloadWorker.swift` (new)
- `DownloadWorker : @MainActor ObservableObject` — app-wide `@StateObject` (desktop
  `downloadsManager`). Public API: `download(url:)`, `cancel(id:)`, `retry(record:)`,
  `exportPicker(for:, asCopy:)`, `remove(id:)`, `clearFinished()`; pure, unit-tested filename /
  destination helpers (`sanitizedFilename`, `uniqueFilename`, `resolveDestination`).
- Nested `DownloadFlow : NSObject, URLSessionDownloadDelegate, WKDownloadDelegate` — the
  transfer engine. **Layering note:** Combine's `ObservableObject` can't also satisfy an
  `NSObjectProtocol`, so the two OS delegate protocols live on this nested `NSObject` (same
  trick `WebViewContainer.Coordinator` uses for `WKNavigationDelegate`/`WKUIDelegate`).
  - **Shell downloads:** a dedicated `URLSession.sessionWithConfiguration(...)` rides with this
    flow as the session download delegate; `URLSessionDownloadTask` reports
    `didFinishDownloadingTo` / `didWriteData` (progress) / `didResumeAtOffset`.
  - **Webview downloads:** the flow *is* `WKDownloadDelegate`; `decideDestinationUsing` bumps a
    `file://` URL in `URL.downloadsDirectory` (journal-deduped so repeats become "file (2).ext"),
    records it, and `downloadDidFinish`/`didFailWithError` (→ `error` vs `waitToRetry` on resume
    data) close the ticket.
  - **Share / Files export:** `exportPicker` builds a `UIDocumentPickerViewController`
    (`initForExportingURLs`, `asCopy: false` = MOVE) rooted at Downloads — the desktop popout
    "Share"/"Open in Files" action, surfaced to the DownloadsView.

### Wiring
- `DownloadWorker` mounted once in `MattermostApp` as an `@StateObject` and injected app-wide
  via `.environmentObject(downloadWorker)` (alongside `deepLinkRouter`) so `RootView` /
  `DownloadsView` (T11) and the webview coordinator can reach it without a long constructor
  chain. **Deliberately kept out of `WebViewContainer.swift`**, which a sibling task (Phase 2-b
  ThemeSync/CertTrust) is editing concurrently — that file is a flagged hotspot.

## Verification (real output)
- Compilation: **all T7 files compile with zero errors** — `DownloadRecord.swift`,
  `DownloadHistory.swift`, `DownloadWorker.swift`, `MattermostApp.swift`, and the test file
  `DownloadWorkerTests.swift` (which compiled clean under the MattermostTests target against
  the T7 API). Verified across incremental `xcodebuild` compiles during this run.
- The full test suite could NOT be green-run at hand-off: the app module currently fails to
  emit solely because of the concurrent Phase 2-b sibling's in-flight `Core/ThemeSync.swift`
  (one visibility error at line 49 — `public var appearance: ThemeAppearance` where
  `ThemeAppearance` is internal), which also briefly touched `WebViewContainer.swift` during
  this run. That sibling was editing the file within the last minute, so I intentionally did
  not touch it (hotspot protocol). Once it lands, `xcodebuild -scheme Mattermost ... test`
  should execute the 29 new `DownloadWorkerTests` alongside the existing 100+.
- Unit tests authored in `DownloadWorkerTests.swift` (not yet executed for the reason above):
  `DownloadRecord` Codable round-trip (all fields / null optionals) + `targetURL`;
  `DownloadHistory` CRUD, newest-first ordering, source-dedup, `clearFinished`, trim-to-50,
  and a **fresh-instance relaunch persistence check** (same `UserDefaults` domain);
  `DownloadWorker` safe-filename derivation (traversal collapse, backslash, empty fallback),
  `uniqueFilename` dedup (single/multi-dot, no-extension), `resolveDestination`, and
  `exportPicker` (nil when nothing landed; move-by-default for a landed file). Live
  `URLSessionDownloadTask`/`WKDownload` transfers are simulator/runtime concerns and are not
  exercisable in XCTest (no HTTP server / interactive webview), so the journal/dedup/
  resolution/export logic that *is* testable is what the suite pins.

## Files written this run
- Mattermost/Core/DownloadRecord.swift (new)
- Mattermost/Core/DownloadHistory.swift (new)
- Mattermost/Core/DownloadWorker.swift (new)
- MattermostTests/DownloadWorkerTests.swift (new; 29 tests)
- Mattermost/MattermostApp.swift (mount DownloadWorker + environment)
- Mattermost/Core/AppPreferences.swift (add `Keys.downloadsHistory`)
- Mattermost.xcodeproj/project.pbxproj (registered 3 Core + 1 test file; IDs F2…26-29 /
  F3…19-1B / F4…0D; plutil-validated)
- docs/parity.md, docs/t7-build-note.md (this file)

## Collision-hotspot flag (PROTOCOL)
`Mattermost.xcodeproj/project.pbxproj` remains the shared-writer hotspot — I re-read it fresh
before adding my registrations (sibling had just landed ThemeSync/CertTrust: F2…22-25 /
F3…17-18 / F4…0B-0C); plutil-valid, no duplicate object ids, and my file-set compiles. The
remaining red on the full build is `Mattermost/UI/WebViewContainer.swift` (the Phase 2-b
sibling's ThemeSync/CertTrust integration), which I deliberately did NOT touch; T7 code itself
is green.