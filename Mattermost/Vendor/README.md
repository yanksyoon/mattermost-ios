# Vendored binaries

Everything in this directory is a **committed binary**, not a package-manager artifact. The reason is
in `docs/t44a-calls-spike.md` §3: SwiftPM's `binaryTarget(url:)` artifact downloader **hangs on this
host** (measured twice, >5 min each, both from stasel and from livekit), while `binaryTarget(path:)`
over a vendored copy builds on iOS Simulator and on Mac Catalyst. A build that cannot fetch its
engine is not a build, so the engine is vendored.

## WebRTC.xcframework

| | |
|---|---|
| Upstream | [`stasel/WebRTC`](https://github.com/stasel/WebRTC) — binary releases of **Google WebRTC** |
| Version | `137.0.0` (prebuilt `WebRTC-M137.xcframework.zip`) |
| Pinned commit | `b85669f32ffb3f48ce3a8f18ad828c6f559a8a0c` |
| Archive SHA-256 | `9b45c5c5ecae392403758bb7262f408aa3cff705d41e862dd766856b610c3edd` (41,307,432 bytes) — byte-for-byte the checksum in stasel's own `Package.swift` manifest, verified by `shasum -a 256` on 2026-10-27 (`docs/t44a-calls-spike.md` §2) |
| Licence | **BSD-3-Clause** — `Copyright (c) 2011, The WebRTC project authors`. The full text ships inside the xcframework as `LICENSE`; the repo-level entry is §21 of `docs/THIRD_PARTY_NOTICES.md`. |
| Slices | `ios-arm64` 11 MB, `ios-x86_64_arm64-simulator` 26 MB, `ios-x86_64_arm64-maccatalyst` 25 MB, `macos-x86_64_arm64` 25 MB (**87 MB** total, extracted) |
| Binary SHA-256 (macOS slice) | `41c40825398c299ea3bf18b66a664ef063e76a47fa749531a73b43f0c491009e` |

Why this engine and not another: it is the same Google WebRTC the Mattermost **web** client runs in
the browser, so the SDP/ICE behaviour of our native peer matches what the Calls SFU is written
against, and it keeps the plain `RTC*` API names (the livekit variant is `LK`-prefixed and strictly
worse for this purpose — `docs/t44a-calls-spike.md` §2).

### How it is wired into `Mattermost.xcodeproj`

Registered by `scripts/t44c-pbxproj-add-webrtc.py` (a brace-scanner rewrite, not a hand edit):

* one `PBXFileReference` (`wrapper.xcframework`) under a `Vendor` group;
* **linked** into `Mattermost` and `MattermostTests` (the tests `import WebRTC` and run in the app
  host, so they need the module and the dylib);
* **embedded** by a `PBXCopyFilesBuildPhase` (`dstSubfolderSpec = 10` → `Contents/Frameworks`,
  `CodeSignOnCopy`) in the app target. The archive ships **unsigned**; `CodeSignOnCopy` signs the
  embedded copy with the app's identity (ad-hoc `-` on this repo's default configuration).

Verified after the build: `Contents/Frameworks/WebRTC.framework` is present and ad-hoc signed
(`Identifier=org.webrtc.WebRTC`, `flags=0x2(adhoc)`), and `Mattermost.debug.dylib` carries
`@rpath/WebRTC.framework/WebRTC` with an `LC_RPATH` of `@loader_path/../Frameworks`.

### Privacy manifest

The framework carries its own `PrivacyInfo.xcprivacy` declaring two **required-reason** API
categories (`NSPrivacyAccessedAPICategorySystemBootTime`, `…FileTimestamp`) and no collected data.
Xcode merges an embedded framework's manifest into the app's privacy report automatically; our own
`Mattermost/PrivacyInfo.xcprivacy` does not need to duplicate those reasons.

### Updating the engine

1. Download `WebRTC-M<version>.xcframework.zip` from `stasel/WebRTC` releases and verify its SHA-256
   against the manifest in that tag's `Package.swift`.
2. Replace `Mattermost/Vendor/WebRTC.xcframework` wholesale (never merge two versions' slices).
3. Update this table (version, commit, archive hash, binary hash).
4. `xcodebuild build` for Mac Catalyst **and** `platform=iOS Simulator` — a slice that fails to
   process is the usual symptom of a half-replaced archive.
5. Re-run `MattermostTests/T44CCallsEngineTests` — the two-peer negotiation test is the fastest way
   to notice a `RTCPeerConnectionDelegate` signature change.
