# T18 build note — App Store readiness: ATS, privacy manifest, review-notes

Status: **DONE.** Release gate (design §6 task 33 / risk §8) now mechanically verified; full
suite green after the changes.

## What was done

1. **ATS — scoped exceptions, no kill-switch** (`Mattermost/Info.plist`).
   `NSAppTransportSecurity` now carries exactly two relaxations:
   - `NSAllowsArbitraryLoadsInWebContent = true` — relaxes ATS **only inside WKWebView web
     content** (Apple's sanctioned key for webview-host apps; their ATS docs direct webview
     apps to use this instead of `NSAllowsArbitraryLoads`). The native `URLSession` shell
     layer (server probes, downloads, diagnostics) stays strict https.
   - `NSAllowsLocalNetworking = true` (kept) — plain-http to local-network hosts (`.local`,
     unqualified, private-range IPs) for LAN/self-hosted instances and the UI-test stubs.
   - `NSAllowsArbitraryLoads` is **absent everywhere** (asserted by the gate script); the
     webview surface is additionally runtime-scoped because `RootView.activate` only ever
     loads a `ServerConfig.url` that the user explicitly added, and `ServerURLValidator`
     defaults addresses to https.
   Self-signed TLS handling is unchanged and stays user-confirmed per origin (`CertTrust` +
   `CertPromptSheet`, Keychain-persisted, hard-reject option).

2. **Privacy manifest** — `Mattermost/PrivacyInfo.xcprivacy` (new), wired into the app
   target's Resources phase of the hand-written pbxproj (new PBXFileReference
   `…37` + PBXBuildFile `…22` + group child + Resources membership; `plutil -lint` OK,
   no duplicate object-ID definitions). Declares: `NSPrivacyTracking=false`, empty tracking
   domains; collected data = **User ID** (session identity, App Functionality, not linked),
   **Audio Data** + **Photos or Videos** (web-app Calls only, App Functionality); required-
   reason API = **UserDefaults / CA92.1**. Grep-verified: no file-timestamp, disk-space,
   system-boot-time, or active-keyboard APIs anywhere in `Mattermost/`, so those reason
   categories are correctly omitted. T19 (Sentry/diagnostics) MUST extend the manifest with
   crash/diagnostic collected-data entries and any new reason APIs before release — noted in
   the manifest header, review notes, and parity.md.

3. **Info.plist usage descriptions + export compliance** — `NSCameraUsageDescription`,
   `NSMicrophoneUsageDescription` (required by WKWebView `getUserMedia` for the web app's
   Calls; no native capture exists), `NSLocalNetworkUsageDescription` (LAN servers), and
   `ITSAppUsesNonExemptEncryption=false` (HTTPS/TLS only).

4. **Review-notes narrative** — `docs/app-store-review-notes.md`: product description,
   ATS scope table, self-signed/enterprise-cert story, usage-description rationale, privacy-
   manifest summary, data lifecycle, and a paste-ready "Notes to Review" block for App Store
   Connect justifying arbitrary/self-signed server loading.

5. **Release-gate checker** — `scripts/verify-release-gate.sh` (source-level) with an
   optional built-`.app` argument (bundle-level). Fails the gate if the global ATS key ever
   reappears, if usage/export keys vanish, or if the manifest is dropped from the target.

## Verification evidence

```
plutil -lint  Info.plist / PrivacyInfo.xcprivacy / project.pbxproj / entitlements   -> OK
duplicate-ID definition scan (definitions only)                                     -> none
scripts/verify-release-gate.sh                                                      -> RESULT: PASS
xcodebuild build (Debug, iPhone 16 Pro sim)                                          -> ** BUILD SUCCEEDED **
built bundle: PrivacyInfo.xcprivacy present; compiled Info.plist keys verified
scripts/verify-release-gate.sh <Mattermost.app>                                     -> RESULT: PASS
xcodebuild test (whole scheme)                                                      -> ** TEST SUCCEEDED **
  MattermostTests     220 run, 220 pass, 0 failures   (0.682s)
  MattermostUITests     6 run,   6 pass, 0 failures   (81.9s; incl. cert-prompt flow
                                                       against the self-signed TLS stub)
```

No regression from the ATS/plist changes: the UI suite's `testCertPromptShownForSelfSignedServer`
still sees the trust challenge under `NSAllowsArbitraryLoadsInWebContent` (challenge handling
is separate from ATS level checks) and passes. Test command used the booted simulator
(`id=81A7F251-8B31-4945-8783-5A264C14B8D5`) — the old destination UUID in `docs/test-plan.md`
no longer exists on this host; noted for the next run.

## Changed / added files
- modified: `Mattermost/Info.plist` (ATS web-content relaxation + usage descriptions +
  export-compliance key, scoped comments)
- new: `Mattermost/PrivacyInfo.xcprivacy`
- modified: `Mattermost.xcodeproj/project.pbxproj` (manifest file ref + build file + group +
  app-target Resources phase; plutil OK, no dup IDs)
- new: `docs/app-store-review-notes.md` (review narrative + paste-ready notes)
- new: `scripts/verify-release-gate.sh` (source + bundle release-gate checker)
- new: `docs/t18-full-suite-2026-10-23.log` (full suite evidence)
- modified: `docs/parity.md` (T18 status section)

## Handoff notes
- T19 must update `PrivacyInfo.xcprivacy` (Sentry/diagnostics collected data + reason APIs)
  before the release build — flagged in manifest header, review notes, parity.
- `docs/test-plan.md` references a stale simulator destination UUID; the current booted device
  id is `81A7F251-8B31-4945-8783-5A264C14B8D5`.
- Gate script is the single source of truth for "did ATS/privacy regress": run it in CI or
  before any export.
