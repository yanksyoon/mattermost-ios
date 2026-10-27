# Installing the Mac app

Every release attaches **`Mattermost-macOS-<tag>.zip`**, which contains `Mattermost.app`
and a `README.txt`. Unzip, drag the app to `/Applications`, run it.

## What the artifact is

A **Mac Catalyst Release build** of `Mattermost.xcodeproj`, signed **ad-hoc**
(`CODE_SIGN_IDENTITY=-`) and **not notarized**.

- Ad-hoc signing is what keeps the app's entitlements intact without a certificate, so
  the Keychain works and entitlements survive the download. It needs no Apple Developer
  account.
- Not notarization because that requires a paid Apple Developer Program membership
  (board card **H1**). Until that is in place, macOS cannot verify the download and
  will refuse the first launch.

## First launch

macOS shows *"Apple could not verify ... is free of malware"*. That is expected for an
unsigned, un-notarized download.

```
Right-click Mattermost.app -> Open -> Open
```

Or in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/Mattermost.app
open /Applications/Mattermost.app
```

Once. After the first approval macOS remembers it for that copy.

## Details worth knowing

- **Universal (arm64 + x86_64).** `ONLY_ACTIVE_ARCH=NO` on the Catalyst destination
  produced both slices; the `package` job prints `lipo -archs` every release so this is
  verifiable rather than assumed. Runs on Intel Macs too.
- **Minimum macOS 14.0** — the resolved `LSMinimumSystemVersion` is printed in the build
  log, so the doc can't drift from the binary.
- **The bundle version is stamped from the tag** before signing: `CFBundleShortVersionString`
  becomes the release number (e.g. `0.6.0`) and `CFBundleVersion` the workflow run
  number. Without that the app reported a hard-coded `0.1.4` from its static
  `Info.plist` and every download looked identical in About.
- **The signature is verified in CI** with `codesign --verify --deep --strict` before
  the zip is made. A broken bundle fails the job rather than failing on the way in.

## The bundle id: `com.mattermost.ios` (decided, with the cost stated)

The Mac build carries the **iOS** bundle id. That is the Catalyst convention, not an
oversight: `Mattermost.xcodeproj` sets `PRODUCT_BUNDLE_IDENTIFIER = com.mattermost.ios`
for both platforms, and the release log prints it twice per run
(`bundle id: com.mattermost.ios`, `Identifier=com.mattermost.ios`).

What it actually changes on a Mac, measured on a host that has run this app:

| What | Where | Named after the bundle id? |
|---|---|---|
| Preferences: server list, active server, surface modes, split-view state | `~/Library/Preferences/com.mattermost.ios.plist` | **yes** — the defaults domain *is* the bundle id |
| Keychain items (team-signed builds) | login keychain, services `com.mattermost.ios.vault.<server>` and `com.mattermost.ios.certtrust.<origin>` | **yes** |
| Secrets on the ad-hoc download | `~/Library/Application Support/Mattermost/vault-secrets.json.enc` (+ `.key`) | **no** — an ad-hoc Catalyst process is refused every Keychain write (`-34018`), so `SecureVault` seals them into an AES-GCM file under Application Support |
| Sandbox container | none — the Mac build is **not** sandboxed (`ENABLE_APP_SANDBOX = NO`) | n/a |

So the risk is narrower than "it shares a namespace with the iOS app": there is no
sandbox container, and the iOS app's preferences and Keychain live on the phone or in the
simulator, where this Mac's files are not visible. What the shared id really means:

1. **On one Mac, two builds of this repo are one app.** A Debug build and the release
   download share the preferences domain, the secret store and the `mattermost://` scheme
   owner; LaunchServices treats them as the same bundle. That is usually convenient (a
   Debug run can see the release's server list) and occasionally surprising (the two
   overwrite each other's window state).
2. **At submission time (board card H1) the id is load-bearing.** A Mac Catalyst listing
   *keeps* the iOS bundle id: one App Store Connect record, one purchase, one TestFlight
   build. Giving the Mac build its own id would create a second app record and split
   exactly what a universal app exists to unify.

**Decision: keep `com.mattermost.ios`.** The migration cost is stated here so a future
card does not discover it by editing a build setting:

- Renaming the id renames the **preferences domain**: every existing install comes back
  with no servers and no saved surface state. It needs a one-time migration that reads
  the old domain, copies it forward and removes it.
- It renames the **Keychain service prefix**, orphaning stored sessions and every trusted
  self-signed certificate: users re-login and re-accept the certificate prompt.
  (The ad-hoc download's Application Support secrets are *not* affected — they are not
  namespaced by the id at all.)
- A second App Store Connect record, and two apps claiming `mattermost://` on macOS, with
  LaunchServices deciding by installation order which one a link opens.
- Other people's Macs can only be migrated by a build that still knows the old id, so the
  rename is a **two-release operation**: the predecessor ships the migrator, the successor
  changes the id.

If a separate Mac identity is ever genuinely wanted, the cheap shape is a per-configuration
`PRODUCT_BUNDLE_IDENTIFIER` override plus that two-release migration — not a
find-and-replace in the project file.

You can check the consequence on your own Mac:

```bash
plutil -p ~/Library/Preferences/com.mattermost.ios.plist | head
ls -l ~/Library/Application\ Support/Mattermost/
plutil -extract CFBundleIdentifier raw -o - /Applications/Mattermost.app/Contents/Info.plist
```

The official Mattermost Desktop app is `Mattermost.Desktop` (verify with the last command
against `/Applications/Mattermost.app` if that is the desktop build): a different bundle
id, so both can be installed and neither sees the other's data.

## Why `ditto` and not `zip`

`ditto -c -k --sequesterRsrc --keepParent` preserves the code signature, extended
attributes and symlinks that a `.app` depends on. `zip -r` corrupts all three, and the
resulting app either will not launch or silently loses entitlements.

The `README.txt` sits **next to** the bundle in the archive, never inside it — adding
any file under `Mattermost.app` after signing invalidates the signature.

## Why not an iOS build too

An iOS `.app`/`.ipa` is useless as a direct download: installing one needs a signing
identity tied to a registered device (or a sideloading tool with a free Apple ID), which
is the same Apple Developer gate. The Mac Catalyst build is the only artifact someone
can actually double-click today.
