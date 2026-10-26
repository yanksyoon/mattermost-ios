# Installing the Mac app

Every release attaches **`Mattermost-macOS-arm64-<tag>.zip`**, which contains
`Mattermost.app` and a `README.txt`. Unzip, drag the app to `/Applications`, run it.

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

- **Apple Silicon only.** The build is `arm64`; there is no Intel slice. The runner is
  arm64 and so is the machine this is used on, so a universal build would double the
  build time for a slice nothing runs.
- **Minimum macOS** is whatever the Catalyst target declares (13.0 today); the build
  log prints the resolved `LSMinimumSystemVersion`.
- **Bundle metadata** (id, short version, build number) is printed in the `package` job
  log on every release, so a stale or malformed bundle is visible without downloading.
- **The signature is verified in CI** with `codesign --verify --deep --strict` before
  the zip is made. A broken bundle fails the job rather than failing on the way in.

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
