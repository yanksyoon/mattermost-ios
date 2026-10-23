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
xcodebuild -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'id=C36282C3-F865-4270-9164-28220818CFCE' \
  -derivedDataPath build/ddata -only-testing:MattermostTests test-without-building
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
  -derivedDataPath build/ddata -only-testing:MattermostUITests test
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