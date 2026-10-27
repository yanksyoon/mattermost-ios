# Test plan — T17: unit (XCTest) + UI (XCUITest) + device parity soak

Design of record: `~/.hermes/plans/2026-10-08_mattermost-desktop-ios-migration.md` §7.
Scope: the native shell services (Core/) and shell chrome (UI/) the migration builds. The chat
UI itself lives in the Mattermost web app and is out of scope except as a webview smoke target.

Legend: **PASS** = executed on this host with real output; **BLOCKED@host** = cannot be
validated on this host (needs a real Mattermost server / APNs / physical device); **N/A** = no
iOS analog by design.

---

## 1. Unit tests (XCTest) — `MattermostTests`

Approach: deterministic, no live network. Stores take an injected `AppPreferences` over a
per-test `UserDefaults` suite; `SecureVault` forges a unique Keychain namespace per test;
badge math uses a recording `BadgeSettable` mock; download logic is pure and unit tested with
live transfers deliberately excluded (a `URLSessionDownloadTask`/`WKDownload` needs a reachable
server + interactive webview — runtime concerns, covered by UI/soak below).

Command:
```
scripts/qa-test.py --platform ios --only-testing MattermostTests
# or, raw xcodebuild (keep derived data OUTSIDE ~/Documents -- see §6):
xcodebuild -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'id=C36282C3-F865-4270-9164-28220818CFCE' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa \
  -only-testing:MattermostTests test-without-building
```

| Area (task) | File(s) | Status |
|---|---|---|
| ServerStore CRUD | `MattermostTests/ServerStoreTests.swift` | **PASS** 5/5 |
| Vault round-trip (relaunch persistence, per-server isolation) | `MattermostTests/SecureVaultTests.swift` | **PASS** 9/9 |
| Badge math (cross-server mentions/unread/expired + showUnreadBadge) | `MattermostTests/SessionStoreTests.swift` | **PASS** 14/14 |
| Deep-link routing (parse/route/queue/unmatched/add-offer) | `MattermostTests/DeepLinkRouterTests.swift` | **PASS** 12/12 |
| Download dedup + journal CRUD/trim + sanitize/unique filename | `MattermostTests/DownloadWorkerTests.swift` | **PASS** 20/20 (2026-10-23) |

Execution evidence (run 2026-10-23 14:41 +08): **220 tests run, 220 pass, 0 fail**
(`** TEST SUCCEEDED **` for the whole scheme; UI target 6/6 below).
The 7 failures seen on 2026-10-22 were fixed at their source on 2026-10-23, not filtered out:
- 6 came from over-escaped fixtures in `DownloadWorkerTests.swift` (`"…\\(…)"` instead of
  `"…\(…)"`), which made every `DownloadHistoryTests` case share one `UserDefaults` suite and
  every `record(_:)` source identical — dedup/trim/order assertions were comparing against
  literal `file-\(i).txt`. Unescaped; assertions now exercise real values.
- 1 was a genuine `DownloadWorker.sanitizedFilename` defect: a separator-only name (`"////"`)
  returned `"////"` instead of the `download` fallback, so a slash-bearing name could reach
  `appendingPathComponent`. `rawLastComponent` now yields `""` for a component-less value.
The same double-escaping was present in 10 production log statements and 3 other test fixtures;
all fixed (zero remaining hits for `\\(` in `Mattermost/` and `MattermostTests/`).

## 2. UI tests (XCUITest) — `MattermostUITests` (NEW target this task)

Approach: launch with `-uiTestResetPersistedState` (a DEBUG seam in `MattermostApp.init()` that
wipes UserDefaults-backed shell state so each test starts from a genuine fresh first-run;
Keychain is deliberately untouched) → deterministic, order-independent.
Offline determinism: a local stub Mattermost server (`build/uitest-server/mm_stub.py`) answers
`/api/v4/system/ping` + `/api/v4/config/client?format=old` + an HTML login page + a downloadable
file, served over the host loopback that the simulator shares. Add-server validation therefore
proceeds against the stub, not a flaky public server. `NSAllowsLocalNetworking` (ATS) was added
so the shell's `URLSession` probe can reach the plain-HTTP on-network stub while public-internet
traffic still requires HTTPS (scoped, per design risk R2).

Command (stubs first, see §5):
```
python3 build/uitest-server/mm_stub.py --port 8111 --name "Local Mattermost Test" &
python3 build/uitest-server/mm_stub.py --port 8443 --tls \
   build/uitest-server/cert.pem,build/uitest-server/key.pem --name "Self Signed Test" &
xcodebuild -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'id=C36282C3-F865-4270-9164-28220818CFCE' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa \
  -only-testing:MattermostUITests test
```

| Flow (task) | Test | Status |
|---|---|---|
| Onboarding → first-run pager | `testOnboardingPagerGetStartedOpensAddServerForm` | **PASS** |
| Add server → login-through-webview (stub login HTML) | `testAddServerThroughFormThenWebviewLoad` | **PASS** (webview loads stub login page) |
| Server switch (2 servers → switch) | `testServerSwitchBetweenTwoServers` | **PASS** |
| Settings persist (download-history Stepper across reopen) | `testSettingsDownloadHistoryLimitPersists` | **PASS** |
| Downloads list (empty-state over fresh journal) | `testDownloadsOpensToEmptyState` | **PASS** |
| Cert prompt (self-signed TLS stub → CertPromptSheet) | `testCertPromptShownForSelfSignedServer` | **PASS** |

Execution evidence (run 2026-10-22 04:33): **6/6 PASS, 0 failures.**

Testability changes made to the app (all sealed behind no-arg behavior / identifiers only):
- `MattermostApp.init()`: reordered store creation into `init()` so the reset/seed seam can run
  first; added `-uiTestResetPersistedState` (wipe shell stores) and
  `-uiTestSeedSelfSignedServer <url>` (pre-populate one self-signed server so the webview hits
  the trust challenge). Both inert without the argument.
- `RootView`: `accessibilityIdentifier`s for `addServerToolbarButton`, `serverSwitcher`;
  removed the hard-coded `accessibilityLabel("Switch server")` so the switcher's accessible
  label reads the active server name (better VoiceOver too).
- `Mattermost/Info.plist`: `NSAllowsLocalNetworking=true` (scoped ATS, design risk R2).

## 3. Real-device parity soak (candidate script)

Cannot run on this host: needs a real Mattermost server with real accounts, APNs entitlement
(no `.p8`), and a physical device for background/foreground / terminated-state notify delivery.
Record what the soak must cover so it's testable when infra lands:

- Add ≥2 servers (one the active community server; one a private/self-hosted instance).
- Sign in on both; verify cross-server **app-icon badge correctness** (mentions sum, unread
  dot, expired) — background via `simctl`/carrier, each server's mention count independent.
- **Push while terminated**: kill the app, deliver a silent/APNs payload via the Push Proxy,
  relaunch, assert the notification + badge reconcile with the server state.
- Calls screen-share quality (needs Broadcast Extension + WebRTC on device).
- Regression parity: run the same login / thread / settings flows weekly on desktop and iOS,
  log divergences (design §7 "Regression net").

## 4. What cannot be validated on this host (explicit, no fabricated pass)

- **APNs / remote push** — needs an Apple `.p8`, a configured Push Proxy + DiagnosticId, and the
  Push Notifications capability. Design risk R1. Covered partially by the Push Proxy simulacrum
  (T12) but real delivery is unverified.
- **Real login-through-webview** against a production Mattermost instance with a real account —
  the stub only proves the shell mounts a webview and loads *a* login HTML; full OAuth/SSO +
  session persistence on a real server is unverified here.
- **Real-download end-to-end** (webview-initiated file download landing in the journal) and
  Share-to-Files export on device — unit-tested logic + empty-state UI are verified; the live
  transfer path needs a logged-in server + device.
- **Real-device soak** (§3) — physical hardware only.

These are recorded as remaining validation, not passed.

## 5. Local stub server (committed fixture)

`build/uitest-server/mm_stub.py` + generated `cert.pem`/`key.pem` (self-signed for
cert-prompt). Simulator ↔ host loopback: iOS simulator shares the Mac's network stack, so
`127.0.0.1` from the app reaches the host stub. Regenerate the cert any time:
```
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -keyout build/uitest-server/key.pem -out build/uitest-server/cert.pem \
  -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1"
```

## 6. Harness: a *failing* unit test used to wedge the test host (T14b)

Symptom: `xcodebuild test` stalls forever at `Test Case '…' started.`, no failure line, no
`** TEST FAILED **`; only the caller's timeout ends it (`** BUILD INTERRUPTED **`). It happens
only when a test *fails*, so an intentionally-broken test is indistinguishable from a deadlock in
product code. Reproduced deterministically with `XCTAssertEqual(1, 2)` in `WebViewStoreTests` (log
and `sample` attached to the T14b board card: `t_14b5684e`).

Not a product bug. When an assertion fails, XCTest symbolizes the failure **in-process**; `sample`
of the wedged host puts the main thread at

```
-[XCTestCase recordIssue:] -> -[XCTSourceCodeFrame symbolInfoWithError:]
  -> -[XCTInProcessSymbolicationService …] -> CSSymbolOwnerGetSymbolWithAddress
  -> CSCppSymbolOwnerCache::create_symbol_owner_data -> extract_debug_map_data_from_header
  -> CSSymbolicatorCreateWithPathArchitectureFlagsAndNotification -> CSFileIsCoreFile
  -> fopen -> open$NOCANCEL                      (blocked, 0 % CPU)
```

(`build/logs/t14/sample-ios-sim-74129.txt` at the time of writing; also attached to the card),
line-for-line the stack in the ticket. CoreSymbolication
opens the object files named in the binary's debug map. When the build products sit inside a
**TCC-protected folder** — this repo lives in `~/Documents`, so every `-derivedDataPath build/…`
does — `sandboxd` asks `tccd` for access on behalf of `com.mattermost.ios` and the `open()` blocks
until the consent is answered. Nothing answers in a non-interactive run, so it blocks forever.
`tccd` shows the request at the same millisecond the failing case starts:

```
tccd[436] [com.apple.TCC:access] AUTHREQ_ATTRIBUTION … accessing={TCCDProcess:
  identifier=com.mattermost.ios, pid=74129 …, binary_path=…/CoreSimulator/Devices/…/Mattermost.app/Mattermost}
```

The Catalyst occurrence in `t_ca6db268` (pid 68124) shows the same request with
`service=kTCCServiceSystemPolicyAllFiles` and
`Failed to match existing code requirement for subject com.mattermost.ios` — an ad-hoc-signed host
gets a fresh TCC subject per build, so the consent would have to be re-granted on every rebuild.
Passing runs never symbolize, which is why the suite looked green: only the failing path reads the
protected folder.

**Fix — `scripts/qa-test.py` (guarded runner):**
- derives into `~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa` by default and *refuses* a
  derived-data path inside `~/Documents`, `~/Desktop`, `~/Downloads` unless
  `--allow-tcc-unsafe-derived-data` is given (that is the wedge trigger, not a style preference);
- watches the run: if tests have started and output stops for `--stall-timeout` (default 240 s), it
  samples the test host, kills the run, prints the `recordIssue -> CSSymbolOwner -> open` diagnosis
  plus the `tccd` lines, and exits **124** — a wedge can no longer look like "still running";
- writes a `.xcresult`, parses `** TEST SUCCEEDED **` / `** TEST FAILED **` and returns
  0 / 1 / 2 / 124 (`xcodebuild` returns 65 on a reported failure, but nothing at all on a hang);
- `--self-test` is the standing break-proof: it injects a deliberately failing test into
  `MattermostTests/WebViewStoreTests.swift`, runs it, asserts a source-located `error:` line,
  `** TEST FAILED **`, a non-zero exit and no wedge, then reverts the file (it refuses to run if
  that file is dirty).

Rule that follows: **never point a test run's derived data into `~/Documents`** — use
`scripts/qa-test.py`, or `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/…` for raw
`xcodebuild`. A `build/…` path is fine for plain `xcodebuild build`, but any run in which a test
may fail will hang there.

## 7. Harness: enumerating a long list one element at a time kills the UI-test host (T34-QA)

Second harness failure, different from §6 and unrelated to TCC. On a long post list the **app
process is lost** with `EXC_BAD_ACCESS (SIGSEGV, KERN_INVALID_ADDRESS at 0x0)` on its main thread:

```
-[XCTAccessibilityFramework attributesForElement:attributes:error:]
  -> -[XCElementSnapshot children] -> __XCTPerformOnMainRunLoop_block_invoke
```

Crash reports: `~/Library/Logs/DiagnosticReports/Mattermost-2026-10-25-210015.ips` and
`-210758.ips` (both `SIGSEGV`, signal/subtype checked in the file). It fired while the test was
snapshotting the post list after a page insert (120 rows), and every later test in the suite then
failed as a cascade — which reads like "three product failures" and is not.

Cause, measured rather than inferred: `query.count`, `element(boundBy:)` and
`allElementsBoundByIndex` each resolve **one element per accessibility round trip** — 0.29-0.32 s
each on this host (`build/logs/t34f-ipad-head.log`, indices 0-45 in one call;
`build/logs/t34q-run1.log`, 98 such queries in one 7-test run). The snapshot work is served on the
app's main thread, which is the thread the list's own layout/scroll-restore runs on.

Rule that follows: **ask the accessibility tree one question per snapshot, not one per element.**
`XCUIElement.snapshot()` returns the whole tree in a single round trip; walk it in the test
(`T34-ChannelPostListUITests.snapshotNodes`). Under that rule the same suite shows 0 per-element
queries (`grep -c 'Element at index' build/logs/t34q-final1.log` → 0) and two consecutive full-suite
runs without losing the process. When a run *does* lose the host, count it as one harness failure -
not as N test failures — and check the crash reports before believing the test names.
