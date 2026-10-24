# T19a build note — Sentry Cocoa init + DiagnosticsService port (shareable report)

- Task: `t_d0d858f6` (split from T19 `t_d43d3180`; parent T18 `t_1d3b7605` complete)
- Date: 2026-10-23 (HKT)
- Host: macOS 26.3.1, Xcode 26.5 (`iPhoneSimulator26.5.sdk`), Swift 5 mode target
- App target: `Mattermost` (hand-written pbxproj, no SPM), deployment target iOS 17.0

## 1. Step-count reconciliation (required explicitly by acceptance)

The T19 title said "all 19 steps"; the design doc §4c said desktop diagnostics has 23 steps.
I read the actual desktop sources from `mattermost/desktop` master
(`src/main/diagnostics/`, fetched via GitHub REST/raw — see `/tmp/mmdiag2/`):

- `index.ts`, `DiagnosticStep.ts`, `types_diagnostics.ts`, `step.template.ts`
- `internal/`: `utils.ts`, `obfuscators.ts`, `loggerHooks.ts`
- `steps/`: `step0.logLevel.ts` … `step11.auth.ts` — **twelve numbered steps, no more**

**Reconciled count: 12 concrete steps** (step0–step11). Neither "19" nor "23" matches the
source of record. All 12 are ported 1:1, ids/names/order preserved:

| id | name (ported) | desktop source |
|----|---------------|----------------|
| 0  | logConfig      | step0.logLevel.ts |
| 1  | internetConnection | step1.internetConnection.ts |
| 2  | configValidation | step2.configValidation.ts |
| 3  | serverConnectivity | step3.serverConnectivity.ts |
| 4  | sessionDataValidation | step4.sessionDataValidation.ts |
| 5  | BrowserWindowsChecks | step5.browserWindows.ts |
| 6  | PermissionsCheck | step6.permissions.ts |
| 7  | PerformanceAndMemory | step7.performance.ts |
| 8  | LogHeuristics | step8.logHeuristics.ts |
| 9  | Config | step9.config.ts |
| 10 | CrashReports | step10.crashReports.ts |
| 11 | AuthSSO | step11.auth.ts |

### Desktop-parity notes
- Steps 0, 2, 3, 6, 7, 8 use the app's own equivalents for the desktop Electron/Chromium
  surfaces: logging (`Logger.swift` + a per-report capture buffer), `AppPreferences` +
  `ServerConfig` (desktop `app.getPath('userData')`/`config.json`), `URLSession` + server
  ping (`/api/v4/system/ping` on each configured server; step 1 pings the desktop
  `IS_ONLINE_ENDPOINT`, injectable via `DiagnosticsContext.onlineEndpoint` for tests),
  `UIDevice`/`AVCaptureDevice`/`UNUserNotificationCenter` permission snapshots (injectable
  `DiagnosticsSystemStatusProviding`), `WebViewStore` webview statuses for step 5.
- Step 4 sessionDataValidation and step 11 AuthSSO mirror the desktop **cookie** check
  (MMUSERID / MMCSRF / MMAUTHTOKEN) against each server's isolated `WKWebsiteDataStore`
  via an injectable `DiagnosticsSessionProviding` (`WebKitCookieSessionProvider` real
  impl; presence booleans only — values never logged).
- Step 9 config dump: values only, secrets omitted; step 11 lists cookie *names* not values.
- Report writer emits `.txt` (human) + `.json` (machine) into a temp dir, then
  `SettingsView` offers two `ShareLink`s (desktop Help → "Run diagnostics" parity).
- Obfuscation (`DiagnosticsObfuscator`, port of `internal/obfuscators.ts`): masks emails,
  URLs, IPv4/IPv6, user paths, passwords, and truncates long tokens before the report is
  written/shared.

## 2. Sentry handler — decision and evidence

Requirement: `SentrySDK.start` + `NSSetUncaughtExceptionHandler` + breadcrumbs, DSN-gated;
no invented verification against a real service. **A real DSN does not exist on this host.**

- Shipped: `Mattermost/Core/SentryService.swift` (start guard on DSN, breadcrumb buffer,
  crash-file writer + uncaught handler, `startHook`/`breadcrumbHook` test seams) +
  `Mattermost/Core/SentrySDKLink.swift` (the **only** file that touches the real `Sentry`
  module; compiles to a no-op today via `#if canImport(Sentry)`).
- `AppDelegate.didFinishLaunchingWithOptions` calls `SentryService.start(...)` (empty
  `SentryDSN` in Info.plist → no-op path) and `SentryService.shared.installUncaughtExceptionHandler()`;
  `Bridge.swift` injects breadcrumbs around bridge events (parity row §4c).
- **SDK fetch is blocked on this host, source compile is verified:**
  - `swift package resolve`/`git ls-remote https://github.com/getsentry/sentry-cocoa.git`
    → `fatal: unable to access ... Could not resolve host: github.com` while curl/dig work.
    Root cause: the user's `~/.gitconfig` rewrites github.com URLs with a PAT; SwiftPM's
    git transport fails even with `-c url.https://github.com/.insteadOf=`.
  - The `Sentry` product uses **binary artifacts**; SwiftPM downloads those at plan time
    for every target, so even `swift build --target SentryObjCInternal` on the vendored
    tarball fails at planning (`required by binary target 'Sentry-...'`).
  - Workaround probe: vendored `sentry-cocoa` 9.31.0 source (`/tmp/sentry-cocoa-9.31.0`),
    a **stripped manifest** containing only the source targets
    (`SentryHeaders`, `_SentryCrashV9Headers`, `_SentryPrivate`, `SentrySwift`,
    `SentryCrashV9Swift`, `SentryCrashV9`, `SentryObjCInternal`, product `SentrySPM`):
    `swift build --product SentrySPM` **exit 0** (concurrency-safety warnings only).
  - **Conclusion shipped:** DSN-gated stub + no-op test coverage; the real SDK is not
    linked into the app target. Wire-up checklist is in `SentrySDKLink.swift`; the
    vendored-source path above is proven for a future integration. This satisfies the
    acceptance clause "if Sentry Cocoa can't be fetched/compiled locally, document that
    and ship the DSN-gated stub + tests".

## 3. Privacy manifest (T18 deferral)

`Mattermost/PrivacyInfo.xcprivacy` now declares, in addition to the T18 baseline:

- `NSPrivacyCollectedDataTypeCrashData` (App Functionality, not linked)
- `NSPrivacyCollectedDataTypePerformanceData` (App Functionality, not linked)
- `NSPrivacyCollectedDataTypeOtherDiagnosticData` (App Functionality, not linked)
- **FileTimestamp NOT declared**: the report uses `Date()` for timestamps
  (`DiagnosticsDate.logLineDate()`), never file-mtime APIs. Enforced by a new gate check
  (`scripts/verify-release-gate.sh` section 5b) that greps the source for
  `contentModificationDate|creationDate|attributesOfItem|modificationDate` and asserts
  `NSPrivacyAccessedAPICategoryFileTimestamp` absent.
- Manifest header comment updated to say the diagnostics/Sentry entries landed.

## 4. Verification performed this session (exact commands + exit codes)

CoreSimulatorService is unreachable from this worker (see §5), so **xcodebuild builds and
test runs could not execute here**; the code was verified at compiler level:

```
# app target typecheck (all files incl. new Diagnostics/Sentry files)
swiftc -typecheck -sdk $(xcrun --sdk iphonesimulator --show-sdk-path) \
  -target arm64-apple-ios17.0-simulator -swift-version 5 \
  Mattermost/MattermostApp.swift Mattermost/AppDelegate.swift \
  Mattermost/Core/*.swift Mattermost/UI/*.swift
  -> exit 0

# testable module emit (what the tests @testable-import)
swiftc ... -enable-testing -module-name Mattermost -emit-module \
  -emit-module-path /tmp/mmmod/Mattermost.swiftmodule -parse-as-library Mattermost/...
  -> exit 0 (module emitted, 662 KB)

# unit tests: all 21 files (incl. new DiagnosticsTests.swift, SentryServiceTests.swift)
swiftc -typecheck ... -enable-testing -I /tmp/mmmod \
  -I <iPhoneSimulator.platform>/Developer/usr/lib \      # XCTest Swift overlay
  -F <iPhoneSimulator.platform>/Developer/Library/Frameworks \
  MattermostTests/*.swift
  -> exit 0

# UI tests: 6 files
swiftc -typecheck ... MattermostUITests/*.swift
  -> exit 0

# release gate
bash scripts/verify-release-gate.sh
  -> RESULT: PASS — release gate satisfied.

# plists / project file
for f in Mattermost.xcodeproj/project.pbxproj Mattermost/Info.plist Mattermost/PrivacyInfo.xcprivacy; do plutil -lint "$f"; done
  -> OK
```

New unit tests added (2 files):
- `MattermostTests/DiagnosticsTests.swift` (15 tests): step enumeration = desktop 12-step
  set with order; connectivity step against an injectable localhost endpoint (MockURLProtocol)
  including the offline-failure path; full report assembly (12 entries, ordered, JSON
  round-trip); markdown report shape; report file writing (txt + json in temp dir);
  config validation failure on empty server name; crash-file step with a real tmp crash
  file; obfuscator masking (email/URL/IPv4/path/password/truncation); log-counter level
  counts; permissions step via fake system-status provider; browser-windows step with
  mounted/unmounted webviews; server-connectivity step all-success and all-failure;
  session-data step via fake cookie-session provider (all cookies → success, missing →
  failure).
- `MattermostTests/SentryServiceTests.swift` (4 tests): no-op path when DSN absent/empty
  (startHook NOT called, isStarted false); no-op path + crash-file recording when handler
  invoked before start (crash file created with the exception reason); DSN-present path
  (startHook called with parsed options; `environment` honored in prod-style DSN);
  uncaught-exception-handler install flag + install idempotency.

These exercise the acceptance-listed behaviors: step enumeration, connectivity against
localhost, report assembly, Sentry no-op, SDK-start guard.

## 5. Verification — COMPLETED 2026-10-24 (was blocked 2026-10-23)

On 2026-10-23 the CoreSimulator bootstrap was unreachable from the sandboxed worker
(full error transcript below), so `xcodebuild` build/test could not execute here. That
was an environment wall, not code, and it has since cleared. On 2026-10-24 a
non-sandboxed session at Xcode 26.6 (17F113) ran the real xcodebuild build + tests.
**`BUILD SUCCEEDED` and `TEST SUCCEEDED` are now claimed with evidence below.**

### 2026-10-23 environment wall (historical — resolved)
- `xcrun simctl list devices booted` → `Unable to lookup
  com.apple.CoreSimulator.CoreSimulatorService (1051.55) ... Connection refused ...
  This can happen if running with a sandbox profile.`
- `xcodebuild ... build` → `Abort trap: 6` (exit 134); crash report
  `/Library/Logs/DiagnosticReports/xcodebuild-2026-10-23-151954.ips` (xpc_add_bundle
  during DVT CoreSimulator locator plugin load).
- `launchctl print gui/501` → `141: Reentrancy avoided`.

### 2026-10-24 verification run (exact commands + real counts)
Host: Xcode 26.6 (17F113). Repo root: `/Users/yangsooyoon/Documents/yanks/code/mattermost-ios`.
Private derived-data path `build/ddata-t19a` (no clobber of any concurrent build). iPad
simulator `81A7F251-8B31-4945-8783-5A264C14B8D5` (T18 device id) was Booted.

Unit tests, Mac Catalyst destination:

```
xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build/ddata-t19a -only-testing:MattermostTests
  -> ** TEST SUCCEEDED ** (exit 0)
```

Log: `build/ddata-t19a-test.log`; xcresult:
`build/ddata-t19a/Logs/Test/Test-Mattermost-2026.10.24_11-27-14-+0800.xcresult`.

UI tests, iOS Simulator (requires the local stub servers, see below):

```
xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=iOS Simulator,id=81A7F251-8B31-4945-8783-5A264C14B8D5' \
  -derivedDataPath build/ddata-t19a -only-testing:MattermostUITests
  -> ** TEST SUCCEEDED ** (exit 0)
```

Log: `build/ddata-t19a-uitest.log`; xcresult:
`build/ddata-t19a/Logs/Test/Test-Mattermost-2026.10.24_11-28-25-+0800.xcresult`.

### Real test counts (differ from the 239/6 expectation — reported, not assumed)
The note originally expected **239 unit / 6 UI** (T17/T18 baseline 220 unit / 6 UI,
+15 diagnostics, +4 Sentry). The actual tree at HEAD `c54e594` (T14 landed since, plus
the T19a files) has more tests than that expectation; the real counts are:

| bundle | suite | executed | skipped | failed |
|--------|-------|----------|---------|--------|
| MattermostTests (unit) | all | **312** | 1 | 0 |
|  — includes DiagnosticsTests | | 25 | 0 | 0 |
|  — includes SentryServiceTests | | 11 | 0 | 0 |
| MattermostUITests (UI) | all tests | **7** | 1 | 0 |

- Unit: `Executed 312 tests, with 1 test skipped and 0 failures ... ** TEST SUCCEEDED **`.
- The 1 skipped unit test is the live mention-poll test
  (`MentionPollerTests.testLiveMentionsFetch_optIn`; needs
  `TEST_RUNNER_MM_LIVE_URL`/`TEST_RUNNER_MM_LIVE_TOKEN` — network-gated by design).
- UI: `Executed 7 tests, with 1 test skipped and 0 failures ... ** TEST SUCCEEDED **`.
  The 1 skipped is the network-gated live-SSO test
  (`testSSOReachesIdentityProviderWithoutCertificatePrompt`; needs
  `TEST_RUNNER_MM_LIVE_SSO_URL`).
- **The Diagnostics/Sentry ported suites specifically:** DiagnosticsTests executed 25
  tests, SentryServiceTests 11 (36 total, 0 failures) — these exceed the note's earlier
  "15 + 4" figure because the committed test files grew to 25 and 11 test funcs
  respectively (verified by `grep -cE 'func test'` on both files at HEAD `c54e594`).

### UI-test stub server prerequisite (must be running, or UI fails)
The UI suite's determinism depends on two local stub Mattermost servers
(`build/uitest-server/mm_stub.py`). If they are not listening, flows that validate a URL
("Save enables only after the stub validates the URL") time out — first UI attempt here
that ran without the stubs produced **5 failures** for exactly that reason. Start them,
then re-run (the run above was done with both up):

```
python3 build/uitest-server/mm_stub.py --port 8111 --name "Local Mattermost Test"   # http 127.0.0.1:8111
python3 build/uitest-server/mm_stub.py --port 8443 --tls cert.pem,key.pem --name "Self Signed Test"  # https 127.0.0.1:8443
```

Release gate:

```
bash scripts/verify-release-gate.sh   -> two calls: RESULT: PASS — release gate satisfied.
```

Built product confirmed present:
`build/ddata-t19a/Build/Products/Debug-maccatalyst/Mattermost.app`.

## 6. Unverified / out of scope (stated, never asserted)

- Live Sentry event send: no DSN exists on this host; no network claim made (the no-op
  path is what ships and is unit-verified).
- APNs / push proxy: out of scope for T19a (desktop→iOS push migration is the separate
  push-proxy track; nothing here touches it).
- App Store publishing: parent T19 is parked by user decision 2026-10-23 (private use,
  no App Store Connect/TestFlight actions). The privacy-manifest work here keeps the
  personal-use release gate green.

## 7. Changed files

- `Mattermost/Core/Diagnostics.swift` (new — port, ~870 lines)
- `Mattermost/Core/SentryService.swift` (new)
- `Mattermost/Core/SentrySDKLink.swift` (new)
- `Mattermost/AppDelegate.swift` (Sentry startup wiring)
- `Mattermost/Core/Bridge.swift` (breadcrumb wiring)
- `Mattermost/UI/SettingsView.swift` (diagnostics section + share links)
- `Mattermost/Info.plist` (`SentryDSN` empty key)
- `Mattermost/PrivacyInfo.xcprivacy` (3 collected-data entries)
- `MattermostTests/DiagnosticsTests.swift` (new)
- `MattermostTests/SentryServiceTests.swift` (new)
- `Mattermost.xcodeproj/project.pbxproj` (5 file refs + 5 build-phase entries)
- `scripts/verify-release-gate.sh` (T19a privacy checks)
- `docs/parity.md`, `docs/app-store-review-notes.md` (this change set)
