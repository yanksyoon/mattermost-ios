# T17 build note — test plan: unit + UI + device parity soak

Status: **DONE.** The XCTest net for the 5 mandated unit areas was already in place from prior
phases and stays green; this task added the missing **XCUITest target** (6 UI flows), a full
test plan (`docs/test-plan.md`), and the parity.md T17 transition.

## What was done

1. **Unit (XCTest)** — verified, did not rewrite (all 5 mandated areas already covered):
   ServerStore CRUD, SecureVault round-trip/relaunch, SessionStore badge math,
   DeepLinkRouter routing, DownloadWorker dedup + journal. Full suite **220 run, 213 pass,
   7 fail** — the 7 failures are pre-existing T7 `DownloadHistoryTests`/`DownloadWorkerTests`
   over-escaped-fixture bugs (flagged for T7/T8 rework, not T17). T17 introduced **0** unit
   regressions (identical 220/7 before and after).

2. **UI (XCUITest)** — NEW target `MattermostUITests` wired into the project, products, group,
   build phase, target dependency, config list, and the shared scheme (pbxproj re-validated with
   `plutil -lint` + duplicate-object-ID scan; no collisions). Six flows all **PASS** on the iOS
   18.5 simulator:
   - onboarding pager → add-server form
   - add server → login-through-webview (webview loads the stub's login HTML)
   - server switch between two servers
   - settings download-history Stepper persists across reopen
   - downloads empty state
   - cert prompt (self-signed TLS stub → CertPromptSheet)

   Determinism: a DEBUG seam in `MattermostApp.init()` honours `-uiTestResetPersistedState`
   (wipes UserDefaults-backed shell stores → genuine fresh first-run each test) and
   `-uiTestSeedSelfSignedServer <url>` (pre-populate a self-signed server so the webview hits the
   trust challenge — the add-server form can't reach it because URLSession rejects self-signed TLS
   during validation). Keychain deliberately untouched. A local stub Mattermost server
   (`build/uitest-server/mm_stub.py`) serves `/api/v4/system/ping`, `/api/v4/config/client?format=old`,
   a login HTML page, and a downloadable file over the host loopback the simulator shares.

   App-side changes (all inert without the launch args): reset/seed seam in `MattermostApp`;
   `accessibilityIdentifier`s for `addServerToolbarButton`/`serverSwitcher` and dropped the
   hard-coded "Switch server" label so the switcher's a11y label reads the active server name;
   `NSAllowsLocalNetworking` (scoped ATS, design risk R2) so probes can reach the local http stub.

3. **Device parity soak** — cannot run on this host (real server accounts, APNs `.p8`/Push Proxy,
   physical device). Procedure recorded in `docs/test-plan.md` §3. Explicitly-validated-in-future
   items (remote push, real OAuth login, live download export) are recorded as UNVALIDATED, not
   passed, in `docs/test-plan.md` §4.

## Verification evidence

```
xcodebuild build-for-testing  ->  ** TEST BUILD SUCCEEDED **
xcodebuild test (MattermostTests)      -> 220 run, 213 pass, 7 pre-existing T7 failures (0 from T17)
xcodebuild test (MattermostUITests)    ->   6 run,   6 pass, 0 failures
```

### Re-verification 2026-10-23 (post-T17 rework of the 7 T7 failures)

The 7 failures above were real and are now fixed at the source, so the suite is fully green:

```
xcodebuild test (whole scheme)  ->  ** TEST SUCCEEDED **
  MattermostTests     220 run, 220 pass, 0 failures
  MattermostUITests     6 run,   6 pass, 0 failures (97s)
```

The failures were two distinct defects, neither of them "pre-existing noise":

1. **Over-escaped fixtures (6 failures).** `MattermostTests/DownloadWorkerTests.swift` carried
   `"…\\(…)"` (double backslash), which emits the literal text `\(…)` instead of interpolating.
   The per-test `UserDefaults` suite names were therefore identical across the class, so every
   `DownloadHistoryTests` case shared one polluted journal; `record(_:)` built every `source` as
   the same literal, defeating source-dedup. Unescaped — dedup/trim/order assertions now pass.
2. **Real code defect (1 failure).** `DownloadWorker.sanitizedFilename("////")` returned the
   separator-only string instead of the `download` fallback: `rawLastComponent` fell back to the
   *original* value when a path had no components, so `appendingPathComponent` would have been
   handed a slash-bearing name. `rawLastComponent` now returns `""` for a component-less value and
   the sanitizer re-trims before the fallback check.

The same over-escaping appeared in 10 production log statements (`Bridge`, `WebViewContainer`,
`DeepLinkRouter`) and in `BridgeTests`/`DeepLinkRouterTests` fixtures — those interpolations were
emitting literal `\(name)` placeholders into the log. All fixed; `grep` for the double-escaped
form now returns zero hits across `Mattermost/` and `MattermostTests/`.

## Changed / added files
- new: `MattermostUITests/` (target), `MattermostUITests/MattermostUITests.swift`
- new: `docs/test-plan.md`, `docs/parity.md` (T17 status section)
- new: `build/uitest-server/mm_stub.py` (test fixture + self-signed cert generation instructions)
- modified: `Mattermost/MattermostApp.swift` (store creation in init + reset/seed seam)
- modified: `Mattermost/UI/RootView.swift` (a11y identifiers / switcher label)
- modified: `Mattermost/Info.plist` (`NSAllowsLocalNetworking`)
- modified: `Mattermost.xcodeproj/project.pbxproj` (MattermostUITests target) + shared scheme
- hotspot note: pbxproj edited one careful pass; plutil OK + no duplicate object IDs.