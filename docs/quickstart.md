# Quickstart — build, sign, and use Mattermost for Mac & iOS

This is the guide for the person who owns the Mac and the phone. It tells you how to get the
app running on your own machine — nothing here requires App Store approval, an Apple
Developer Program membership, or a Mattermost account from us. Every shell command in this
file was run on the development host on 2026-10-23 and the output it produced is quoted
below; steps that physically require an iPhone (or an Apple ID you own) are marked
**UNVERIFIED** because they cannot be exercised on the build host.

Deep detail lives in two other documents:
- `docs/parity.md` — the module-by-module map of the desktop app to this native shell.
- `docs/test-plan.md` — the unit/UI test contract and the (not-run here) device soak plan.

---

## 1. What this app is (in five lines)

A native SwiftUI shell that hosts the **Mattermost web app** in a `WKWebView`: the chat UI and
sign-in page ship from *your* server — nothing about the chat client is re-implemented here.
The native part of the shell provides: **multi-server switching** (each server gets its own
isolated webview data store, so sessions never bleed), a **Keychain credential vault** (one
entry per server), **downloads with Files/Finder export**, **theme sync** (light/dark follows
the server and the OS), **self-signed / enterprise certificate trust** (a native prompt, per
origin), **local notifications** (mentions while the app is in the foreground), and
**mattermost:// deep links**. That's the whole story: shell + webview; the server does the rest.

---

## 2. Mac (the primary target) — build, sign, launch

You need only Xcode (tested on Xcode 26.6, macOS 26.3). No Apple account, no team, no
provisioning profile. The app target is signed **ad hoc** (`CODE_SIGN_IDENTITY = "-"`), which
is exactly right for running on your own Mac: the OS lets an ad-hoc app run locally even
though it is not notarised for distribution.

From the repo root:

```bash
xcodebuild -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build/ddata-mac build
```

This was run on this host (2026-10-23) and ended with:

```
** BUILD SUCCEEDED **
```

The app lands here:

```
build/ddata-mac/Build/Products/Debug-maccatalyst/Mattermost.app
```

Launch it:

```bash
open build/ddata-mac/Build/Products/Debug-maccatalyst/Mattermost.app
```

The `open` command ran on this host and the app process came up. The signature is verifiable
with `codesign`:

```
$ codesign -dv build/ddata-mac/Build/Products/Debug-maccatalyst/Mattermost.app 2>&1 | grep -E 'Signature|TeamIdentifier'
Signature=adhoc
TeamIdentifier=not set
```

First launch of an ad-hoc app: if Finder/Safari downloaded it, macOS may show "cannot verify
developer" — **right-click → Open** once, or clear the quarantine attribute:

```bash
xattr -dr com.apple.quarantine /Applications/Mattermost.app
```

(This is the standard macOS ad-hoc flow; the attribute only exists on files that arrived via
download, not on a locally built app.)

### Known Mac limitation (very real, affects you on day one)

The Mac build is ad hoc, so macOS refuses it the `application-identifier` entitlement and
**every Keychain call fails** (`errSecMissingEntitlement`, -34018). Measured on this host:
10 `SecureVault` + 5 `CertTrust` unit tests fail with exactly that error; a workaround shim
does not change it. What that means for you:

- Your **login still survives restarts** — the session lives in the webview's per-server
  cookie store, not in Keychain.
- The per-server **token vault** and the **self-signed-cert trust bag** cannot persist, so a
  self-signed server asks for trust again on each launch, and the diagnostics step that
  checks the Keychain reports that step failed (accurate, not a bug).
- Fix, in order of effort: (a) sign the app with any Apple ID — even a free Personal Team —
  in Xcode (Signing & Capabilities → choose your Team → Run), or (b) wait for the fallback
  store tracked as T22 on the board (in progress as of 2026-10-23).

---

## 3. iPhone — Xcode Personal Team signing

The `.ipa` in Releases is currently **unsigned**; there are no GitHub Releases yet (verified:
`GET /repos/yanksyoon/mattermost-ios/releases` returns `[]`), so today the only path is
building from source in Xcode.

Steps (mark the physical-device parts as **UNVERIFIED** — they need a real iPhone and your
Apple ID, which the build host does not have):

1. Open `Mattermost.xcodeproj` in Xcode.
2. Select the `Mattermost` target → **Signing & Capabilities** → check **Automatically manage
   signing** → select your **Personal Team** (your Apple ID, free).
3. Connect the iPhone, select it as the run destination, press **Run**.

**UNVERIFIED — free-tier facts, from Apple's published limits, not exercised here:**
- Free Personal Teams allow **3 apps per device** and **10 App IDs** per Apple ID.
- The free provisioning profile **expires every 7 days**, so you must rebuild/reinstall weekly;
  the symptom is the app failing to launch or "unable to verify" a few days after install
  (**UNVERIFIED** — this is the well-known free-tier expiry; no physical device here).
- iOS 17+ requires **Developer Mode** on the device: Settings → Privacy & Security →
  Developer Mode → on. First run over USB will also ask you to **trust the developer
  certificate**: Settings → General → VPN & Device Management → your profile → Trust.
  (**UNVERIFIED** — device-only, not exercisable on this host.)
- The **$99 Apple Developer Program** removes the weekly reinstall (year-long profiles) **and
  is the only way to get push notifications** (section 7).

---

## 4. First run

1. **Add a server.** On first launch you get the welcome pager → Add a server. Type the full
   URL, e.g. `https://community.mattermost.com` (or `http://devbox.local:8065` for a LAN
   instance — ATS permits plain http to local-network hosts only). The form **validates the
   URL live against `/api/v4/system/ping`** and then reads the site name from
   `/api/v4/config/client?format=old`, so a typo fails immediately with a message instead of
   producing a blank webview. Save is disabled until the probe succeeds. The probe endpoints
   were verified against the public community server from this host on 2026-10-23:

   ```
   $ curl -sS https://community.mattermost.com/api/v4/system/ping
   {"ActiveSearchBackend":"opensearch",...,"status":"OK"}
   ```

2. **Sign in** — through the web view, exactly as on a browser. Your credentials go to your
   server; the shell does not see your password. The shell stores only the server entry
   (name, URL) plus, where Keychain is available, the session token.

3. **Switch servers** — from the toolbar server switcher. Each server gets its own
   `WKWebsiteDataStore` (cookies, localStorage, IndexedDB), so two servers can be signed in
   as different users at the same time and their sessions never mix.

4. **Where credentials live:**
   - The **web session** (cookies) survives relaunch in each server's isolated webview data
     store — this is what keeps you logged in.
   - The **token vault** (`Core/SecureVault.swift`) stores per-server auth tokens in the
     **Keychain** (`kSecClassGenericPassword`, service scoped to the server's canonical URL,
     `AfterFirstUnlockThisDeviceOnly`); readable only via the vault, never in UserDefaults.
   - On the **ad-hoc Mac build this Keychain path is unavailable** (-34018, section 2); on a
     properly signed iOS build it works.

5. **Where downloads land.** Webview and shell-initiated downloads go to the app's Downloads
   directory (`Documents/Downloads` inside the sandbox; the exact path is shown in
   Settings → General → Download Location). Each download is journalled (name, progress,
   status, up to a cap you control in Settings) and can be **exported to Files / Finder**
   from the Downloads list via the share/document-picker.

---

## 5. Self-signed / enterprise server certificate

When your server presents a certificate that no public CA issued (self-signed, internal CA,
expired lab cert), the webview raises a native prompt (`CertPromptSheet`):

- It shows the **subject, issuer, serial number and SHA-256 fingerprint** of the presented
  certificate, with a "Certificate Information" detail sheet.
- **Trust** records the decision and reloads; the next TLS challenge on that origin auto-accepts.
- **Don't trust again** records an explicit refusal; future challenges on that origin are
  hard-rejected without prompting.

What persists is a **Keychain trust bag keyed by origin** (`scheme://host[:port]`, ignoring
path); the same decision also covers the `wss://` websocket origin for that host. Revocation
= removing the server from Settings (Servers → trash), which clears its session and data
store; on a properly signed build the trust record for that origin is removed from the
Keychain at the same time (`CertTrust.remove`). **On the ad-hoc Mac build none of this
persists** (-34018); the prompt simply re-appears each launch. Note: the App Store review
narrative (docs/app-store-review-notes.md) covers why this user-confirmed model is scoped —
the shell never silently bypasses TLS.

---

## 6. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Add-server form says the URL is invalid / not Mattermost | The live probe failed. Check reachability and that the server answers `/api/v4/system/ping` with `{"status":"OK"}`. Try `https://` explicitly; sub-paths are supported. |
| Plain-`http://` server won't validate or render | ATS: **only local-network hosts** (`.local`, unqualified names, private-range IPs) are allowed plain http (`NSAllowsLocalNetworking`). A public-internet `http://` server is refused by design; use https. `NSAllowsArbitraryLoadsInWebContent` relaxes ATS inside the webview only — the native probe layer stays strict https. Release-gate script: `bash scripts/verify-release-gate.sh` (PASS = scoped ATS + privacy manifest + usage descriptions present). |
| "Untrusted Developer" alert on iPhone (**UNVERIFIED**) | Trust your developer certificate: Settings → General → VPN & Device Management → profile → Trust. |
| iPhone app quits / won't open after ~7 days (**UNVERIFIED**) | Free Personal Team profile expired — rebuild and reinstall from Xcode. This is the free-tier weekly cycle. |
| Developer Mode off (**UNVERIFIED**) | iOS 17+: Settings → Privacy & Security → Developer Mode → enable, then reboot. |
| `Settings → Run diagnostics` shows Keychain failed on Mac | Expected on the ad-hoc Mac build (-34018); not an app defect. Gets fixed by signing with a team (section 2). |
| App won't launch on Mac, Gatekeeper message | Right-click → Open once, or `xattr -dr com.apple.quarantine /Applications/Mattermost.app` (quarantine only applies to downloaded copies). |

---

## 7. What does NOT work without a paid Apple Developer account

**Remote / background push notifications (T12/T13) are blocked as publishing-only** and are
the one feature that fundamentally requires the paid program:

- Mentions are delivered as **local notifications while the app is running** (you grant
  notification permission on the first mention; the badge reflects cross-server mention/unread
  totals).
- When the app is **backgrounded or terminated**, mentions will NOT arrive until this client
  has a **Mattermost Push Proxy + APNs key** wired up: a real proxy requires (a) an Apple
  **APNs auth key (.p8) + Team ID + Key ID** — only issued to an Apple Developer member — and
  (b) a hosting decision for the proxy (self-host or Mattermost's service). As of 2026-10-23
  the repo ships a runnable push-proxy *simulacrum* (`PushProxy/`) for testing the payload
  contract, but real delivery is blocked on that `.p8` key + a human-run proxy
  (docs/t12-push-proxy.md is the runbook and secret inventory).
- The **$99 program** is also what removes the weekly reinstall on iPhone (section 3).

Also not in yet: Calls / screen sharing (webview WebRTC camera/mic permission strings exist so
the web app can ask, but no native capture), and background refresh (T14). The current
feature inventory lives in `docs/parity.md`; the test contract in `docs/test-plan.md`.
