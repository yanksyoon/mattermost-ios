# Mattermost for Mac & iOS (personal build)

An unofficial, native shell around the **Mattermost web app**: a SwiftUI app that hosts your
Mattermost server in a `WKWebView`, so the chat UI, sign-in, and message rendering all come
from *your* server. Nothing about the chat client is re-implemented or proxied.

> Not affiliated with Mattermost, Inc. "Mattermost" is their trademark; this is a personal
> client that talks to Mattermost servers.

**Runs on:** macOS (Mac Catalyst) and iPhone/iPad. **Does not need:** the App Store, an Apple
Developer Program membership, or any review.

## Install on the Mac (prebuilt, 2 minutes)

1. Download `Mattermost-0.1.0-macos.zip` from [Releases](../../releases).
2. Unzip it and drag `Mattermost.app` into `/Applications`.
3. First launch: **right-click → Open** (the build is ad-hoc signed, not notarised). If macOS
   still refuses, clear the quarantine flag:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Mattermost.app
   ```
4. Add your server URL and sign in.

The official Electron Mattermost desktop app is also called `Mattermost.app`. If you have both,
rename this one (e.g. `Mattermost (personal).app`) or keep it somewhere other than
`/Applications` so Launchpad does not show two identical icons.

### Known limitation of the prebuilt Mac build

It is signed ad hoc, so macOS does not grant it the `application-identifier` entitlement and
**Keychain access is refused** (`errSecMissingEntitlement`, -34018). What that means in practice:

- your login still survives restarts (the session lives in the webview's cookie store);
- the per-server **token vault** and the **self-signed certificate trust** bag cannot persist, so
  a self-signed server asks for trust again on each launch;
- `Settings → Run diagnostics` reports the Keychain step as failed (that is accurate, not a bug).

Signing the app with your own Apple ID (even a free Personal Team) fixes it completely — see
*Build from source* below. A non-Keychain fallback store is tracked as T22 on the project board.

## Install on the iPhone

The `.ipa` in Releases is **unsigned** — iOS will not install it by itself. Two options:

- **Re-sign it with your own Apple ID** using AltStore or SideStore (free accounts: the app must
  be re-signed every 7 days), or
- **Build from source** (below) and run it straight from Xcode.

Either way, iOS 17+ requires **Developer Mode** on the device (Settings → Privacy & Security →
Developer Mode), and you must trust your developer certificate afterwards.

## Build from source

Mac (no Apple account needed):

```bash
xcodebuild -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build/ddata-mac build
open build/ddata-mac/Build/Products/Debug-maccatalyst/Mattermost.app
```

Mac with full Keychain support: open `Mattermost.xcodeproj`, select the `Mattermost` target →
*Signing & Capabilities* → choose your Personal Team → Run. (Free-team profiles expire after
7 days, same as on iOS.)

iPhone/iPad: open `Mattermost.xcodeproj`, select your Team in the same place, pick your device,
Run.

## Tests

```bash
# iPhone: 256 unit tests + 6 XCUITest flows
xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -derivedDataPath build/ddata

# Mac (Catalyst): 236 unit tests
xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build/ddata-mac -only-testing:MattermostTests
```

Status of this tree: **iOS 256/256 unit + 6/6 UI green**; **macOS 236/236 green** once the 20
Keychain-backed tests are excluded — those need a signing team, see the limitation above.

## First run

1. **Add a server** — full `https://` URL, optional sub-path. The form validates it against
   `/api/v4/system/ping` and reads the site name from `/api/v4/config/client?format=old` before
   saving, so a typo fails immediately instead of showing a blank webview.
2. **Sign in** inside the web view. Credentials go to your server; the app stores only the server
   entry plus (where Keychain is available) the session token.
3. **Add more servers** — each gets its own `WKWebsiteDataStore`, so sessions never bleed between
   servers. Switch from the toolbar menu.
4. **Self-signed / enterprise servers** — you get a native certificate prompt with the subject,
   issuer and fingerprints. "Trust" is remembered per origin (Keychain), "Don't trust" is
   remembered too, and you can revoke from Settings.
5. **Downloads** — webview downloads land in `Documents/Downloads`, are journalled in
   *Downloads* (with progress and a 50-entry history), and can be exported to Files/Finder.

## What works

Multi-server switching with isolated web data stores · URL validation before save · Keychain
credential vault (per server, survives relaunch) · downloads + history + export · theme sync
(light/dark follows the server theme and the OS appearance) · self-signed certificate trust with
a review sheet · `mattermost://` deep links (queued until the webview is ready) · local mention
notifications and app-icon badge · settings (theme syncing, unread badge, language, log level,
download-history cap) · onboarding pager · error/retry surfaces · diagnostics report you can
share as text/JSON.

## What is not there yet

- **Push notifications when the app is in the background** — needs a Mattermost Push Proxy plus
  an APNs key, i.e. a paid Apple Developer membership. Local notifications cover the
  foreground case only. (T12/T13 are parked as publishing-only.)
- **Calls** (WebRTC microphone/camera in the webview) and **screen sharing** — T15/T16.
- **Background refresh / presence re-delivery** — T14.

## Layout

```
Mattermost/            app target (SwiftUI + UIKit)
  Core/                server registry, vault, downloads, notifications, theme, cert trust,
                       deep links, diagnostics, background/refresh plumbing
  UI/                  shell chrome: root, server form, settings, downloads, welcome, cert sheets
MattermostTests/       256 unit tests
MattermostUITests/     6 XCUITest flows (local stub server, self-signed TLS stub)
PushProxy/             a local push-proxy simulacrum + config (no real APNs; see docs/)
docs/                  parity map, test plan, per-ticket build notes, review-notes draft
```

`docs/parity.md` maps every desktop module to its native replacement; `docs/test-plan.md` is the
test contract; the `docs/t*-build-note.md` files record what each ticket actually built and how
it was verified.

## License / provenance

Personal project. The Mattermost web app served by your instance remains Mattermost's code;
this shell is original Swift and is not distributed by Mattermost.
