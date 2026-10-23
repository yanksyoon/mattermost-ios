# App Store review notes — Mattermost iOS (T18 release gate)

Design of record: `~/.hermes/plans/2026-10-08_mattermost-desktop-ios-migration.md` §6 task 33
(and Risk §8: "App Store + arbitrary/self-signed servers"). This document is the
review-supporting narrative for the App Store Connect submission AND the engineering
rationale for reviewers on this board. The last section is the paste-ready text for
App Store Connect → App Information → "Notes to Review".

Status: **DONE for this pass (2026-10-23).** Items explicitly deferred (Sentry, diagnostics,
Calls native capture) are flagged below — do not ship the next release without re-checking them.

---

## 1. What the app is (for the reviewer)

Mattermost iOS is a **native SwiftUI shell** that hosts the open-source Mattermost web app in
a `WKWebView` — the iOS counterpart of Mattermost's desktop app, which is an Electron shell
around the same web app. The user's chat UI, login flows, and server content are rendered and
executed by the Mattermost web app inside the web view; the native shell provides the server
list/switcher, settings, downloads, deep links, notifications, badge state, and certificate
trust prompts.

The defining property relevant to review: **the signed-in chat experience is a web app the
user points at a server of their choosing.** Mattermost is self-hostable software; individuals
and companies run their own instances on their own domains — often on internal hosts, LANs, or
with enterprise/self-signed TLS certificates that public CAs do not issue for. Supporting the
product therefore means supporting (a) arbitrary user-configured server domains and (b)
transport security decided by the server operator, not by the app.

## 2. App Transport Security (ATS) — scoped, not disabled

`Mattermost/Info.plist` → `NSAppTransportSecurity` contains exactly two keys:

| Key | Value | Effect |
|---|---|---|
| `NSAllowsArbitraryLoadsInWebContent` | `true` | Relaxes ATS **only for web content loaded inside `WKWebView`** — the Apple-sanctioned key for webview-host apps. Does **not** relax ATS for the app's own `URLSession` networking. |
| `NSAllowsLocalNetworking` | `true` | Permits plain-`http` connections to **local-network** hosts (`.local`, unqualified hostnames, private-range IPs) — e.g. a self-hosted Mattermost instance on a LAN, or the local stub servers the in-app test suite drives. Public-internet connections still require https. |

Explicitly **not** set anywhere: `NSAllowsArbitraryLoads` (the global kill switch). `grep`
for it returns nothing in `Info.plist`; the release-gate script (`scripts/verify-release-gate.sh`)
fails if it ever appears. There are also no static `NSExceptionDomains`: the app has no
hard-coded server hostnames because servers are user-configured, so per-domain exceptions
would be meaningless. Apple's ATS guidance for web-view-based apps is to use
`NSAllowsArbitraryLoadsInWebContent` rather than `NSAllowsArbitraryLoads`, which is exactly
what this app does.

Why the web-content relaxation exists: a self-hosted Mattermost server may intentionally serve
the web app over plain http on a trusted/private network. With strict ATS, `WKWebView` would
refuse to load the page even after the user deliberately configured that server address.

What remains strict (this is the scope boundary):
- The **native shell layer's own connections** (`ServerAPI` ping/probe, `DownloadWorker`,
  future push-token registration) run under full ATS — https required, TLS validated. We
  verified `ServerURLValidator` normalizes user-entered addresses to `https` unless the user
  explicitly types `http://`.
- **TLS trust is never silently bypassed.** A self-signed/enterprise-valid certificate on a
  configured `https` server triggers `WKWebView`'s server-trust challenge; the native
  `CertTrust` flow shows a certificate prompt (`CertPromptSheet`) and only after the user
  explicitly confirms "Trust" for that server origin records the decision in the **Keychain**
  and reloads. The user can also choose "Don't trust again", which hard-rejects future
  challenges for that origin. Publicly-validated chains never hit this path.

## 3. Usage descriptions in Info.plist

| Key | Text | Why required |
|---|---|---|
| `NSCameraUsageDescription` | "Mattermost needs camera access for video calls you start in the Mattermost web app." | `WKWebView`'s `getUserMedia` requires the host app to declare camera use. The native app performs no camera capture; this covers the web app's Calls feature when the user starts a video call. |
| `NSMicrophoneUsageDescription` | "Mattermost needs microphone access for voice and video calls you start in the Mattermost web app." | Same mechanism for audio in Calls. |
| `NSLocalNetworkUsageDescription` | "Mattermost connects to Mattermost servers on your local network, for example a self-hosted development server on your LAN." | iOS 14+ local-network permission covers connecting to LAN self-hosted servers. |

The system prompt is only shown to the user when the web app first calls `getUserMedia`
(i.e. the user starts a call) or when the app first connects to a local-network server; the
shell requests neither on launch.

## 4. Privacy manifest — `Mattermost/PrivacyInfo.xcprivacy`

Shipped in the app bundle (added to the project's Resources phase, verified present in the
built `.app`).

- `NSPrivacyTracking` = `false`; `NSPrivacyTrackingDomains` = empty. No tracking, no ads,
  no third-party SDKs, no data sale.
- `NSPrivacyCollectedDataTypes` (all with purpose **App Functionality**, `Linked` = false —
  the shell stores no profile of the user):
  - **User ID** — session identity for the user-configured Mattermost server(s): per-server
    auth tokens live in the **Keychain** (`SecureVault`, `kSecClassGenericPassword`,
    `ThisDeviceOnly`), and a per-server `hasSession` flag drives the badge/expired states.
    The shell itself reads none of the chat content.
  - **Audio Data** — microphone input only when the user starts a voice/video call in the
    hosted web app.
  - **Photos or Videos** — camera input only when the user starts a video call in the hosted
    web app.
- `NSPrivacyAccessedAPITypes`:
  - `NSPrivacyAccessedAPICategoryUserDefaults` — reason **CA92.1** (the app reads/writes only
    keys it creates itself: `AppPreferences.Keys` — servers, settings, download journal,
    notification state; `MattermostApp` first-run reset clears only those domains).
  - No other required-reason API categories are used: verified by grep over `Mattermost/`
    for file-timestamp (`contentModificationDate`/`creationDate`/`attributesOfItem`), disk
    space, system-boot-time, and active-keyboard APIs — zero hits.

**T19a update (2026-10-23):** the deferred Sentry/diagnostics entries have landed.
`PrivacyInfo.xcprivacy` now also declares **Crash Data**, **Performance Data**, and
**Other Diagnostic Data** (each App Functionality, not linked). The diagnostics report
timestamps come from the current date (`Date()`), so **no file-timestamp required-reason
API is needed** — the release gate asserts `NSPrivacyAccessedAPICategoryFileTimestamp`
stays absent and that no file-mtime API appears in the source. The Sentry handler is
DSN-gated and, with no DSN configured in this build, does not initialize or transmit
anything; the manifest declares the crash/diagnostic types anyway so that enabling Sentry
later (by setting `SentryDSN`) requires no privacy change.

## 5. Data lifecycle (what lives where)

- **Server list & settings** — `UserDefaults` (app-created keys only), cleared by "Reset" and
  by removing each server from the switcher. Server removal also deletes that server's
  `WKWebsiteDataStore` (cookies/localStorage session).
- **Auth tokens** — Keychain, per-server, `ThisDeviceOnly` (not backed up to iCloud).
- **Certificate trust decisions** — Keychain, per-origin (`CertTrust`).
- **Downloads** — app `Documents/Downloads` container; the user moves/opens them via
  Share/Open-in-Files. Journal in `UserDefaults`, bounded by a settings-controlled history
  limit.
- **Chat content** — rendered only inside the web view; the native shell does not read,
  store, or transmit message content beyond the mention/badge counts the web app hands the
  bridge (used for local notifications and the app-icon badge, matching the desktop app).

## 6. Review-justification of arbitrary/self-signed server loading (the risk R2 story)

1. **Arbitrary domains = the product.** Mattermost is server software; users run it on their
   own domains. The desktop app (already on the Mac App Store) opens user-configured servers
   the same way. A review that requires a fixed host allowlist would make the app unable to
   do its core function.
2. **The relaxation is scoped to web content, not to native networking.** Nothing the native
   shell does on the network is ATS-exempt.
3. **TLS trust requires explicit, per-origin user consent.** There is no code path that
   accepts an untrusted certificate without the user confirming it for that server, and
   decisions are persisted in the Keychain, revocable by removing the server.
4. **The user configures every URL by hand** through the Add Server form; no server is
   contacted until the user enters its address, and addresses default to https.
5. **No tracking, no advertising, no third-party SDKs.**

## 7. Paste-ready text for App Store Connect → "Notes to Review"

> Mattermost iOS is a native SwiftUI shell that hosts the open-source Mattermost web app
> (chat UI) in a WKWebView. The product lets each user add one or more Mattermost servers of
> their choosing — including self-hosted instances on private domains, LAN hosts, and
> servers using enterprise or self-signed TLS certificates — and the chat experience is the
> server's own web app rendered in the web view.
>
> Because servers are user-configured and can be self-hosted, App Transport Security is
> relaxed in two narrow, scoped ways (there is no global NSAllowsArbitraryLoads):
> (1) NSAllowsArbitraryLoadsInWebContent permits the WKWebView to load the web content the
> user deliberately configured, including plain-http LAN/private-network servers, while the
> app's own native URLSession networking still requires HTTPS; (2) NSAllowsLocalNetworking
> permits plain-http connections to local-network hosts such as a LAN development server.
> The shell itself never loads a server the user has not explicitly added.
>
> Self-signed and enterprise certificates are never silently trusted. When a configured
> HTTPS server presents an untrusted certificate, the app shows a certificate prompt with
> the certificate details; the connection proceeds only after the user explicitly confirms
> trust for that server, and the decision is stored in the device Keychain and can be revoked
> by removing the server.
>
> The app requires camera and microphone access only for Calls (voice/video) that the user
> starts inside the Mattermost web app; the native shell performs no capture. Local-network
> access is used to reach self-hosted Mattermost servers on the user's LAN.
>
> The app does not track users, does not show ads, and contains no third-party analytics or
> advertising SDKs. A privacy manifest (PrivacyInfo.xcprivacy) is included. Secrets and
> session tokens are stored in the Keychain; preferences in app-scoped UserDefaults.
> Networking is HTTPS/TLS only; the app declares ITSAppUsesNonExemptEncryption = false.

## 8. Verification performed (this pass)

- `plutil -lint` passes on `Info.plist`, `PrivacyInfo.xcprivacy`, `project.pbxproj`,
  entitlements.
- `.xcprivacy` is referenced in the pbxproj (file ref + `Resources` build phase, Mattermost
  target) and present in the built `.app` bundle (`PrivacyInfo.xcprivacy` copied; compiled
  `Info.plist` inspected with PlistBuddy).
- Release-gate script `scripts/verify-release-gate.sh` passes (see its output in
  `docs/t18-build-note.md`).
- Full suite re-run: 220/220 unit + 6/6 UI on the iPhone 16 Pro simulator — no regression
  from the ATS/plist changes (the UI suite includes the self-signed-TLS cert-prompt flow,
  which exercises the unchanged challenge handling).
- **T19a (2026-10-23):** the added diagnostics/Sentry code and their privacy checks were
  verified at compiler level (simulator SDK 26.5): app target typecheck exit 0; testable
  module emit exit 0; all 21 unit-test files typecheck exit 0 (incl. 15 new
  `DiagnosticsTests`, 4 new `SentryServiceTests`); 6 UI-test files typecheck exit 0;
  `scripts/verify-release-gate.sh` → PASS. xcodebuild `BUILD SUCCEEDED` and the simulator
  test run could not be executed in that pass because CoreSimulatorService became
  unreachable mid-session (sandboxed worker; crash report evidence in
  `docs/t19a-build-note.md` §5) — those must be re-run from a GUI session before any
  release claim. No Sentry send was ever asserted; no DSN is configured.
