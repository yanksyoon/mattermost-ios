# T44a — Calls feasibility spike: WebRTC engine + Calls signalling

**VERDICT: `NATIVE VIABLE`** — for **audio/video calls**. A native Calls client can be built on
`stasel/WebRTC` 137.0.0 (it resolves, slices exist for iOS, iOS-Simulator and Mac Catalyst, and it
builds for both destinations this app ships), the signalling needs no web-app glue beyond one
protocol-shaped module the client must reimplement, and a measured engine floor of
**11.6…15.2 MB RSS** sits two orders of magnitude below the webview it replaces (460.7 MB simulator /
562.1 MB Catalyst, T27).

**Screen share is carved out of that verdict**, not included in it: it requires a ReplayKit
Broadcast Upload Extension (`RPSystemBroadcastPickerView`), i.e. a second app-extension target with
its own bundle id, provisioning, App Group and review path — priced in §6 and scoped as its own card.

This card flips nothing. `SurfaceDefaults.nativeApprovedSurfaces` is untouched and `calls` stays
`web` (`Mattermost/Core/RenderMode.swift:84`) until the gate probes in §8 pass.

> **Amended 2026-10-27 by T44 (`t_a3383222`):** see **§10**. It corrects three protocol statements in
> §4.2/§4.4 (the `sdp` action needs MessagePack, not JSON; the client is the offerer; the pinned
> protocol source is plugin `v1.12.6` while the fixture runs `v0.29.8`) and records the P1 result:
> signalling interoperates (8/8), media cannot be established on this host (0/3 SFU candidates
> reachable). Read §10 before implementing anything from §4.

- Task: `t_0845e828` (T44a), 2026-10-24, isolated worktree `wt/t_0845e828`
- Host: `MacBook-Pro-5.local` (MacBookPro18,3), macOS 26.3.1 (25D771280a), **Xcode 26.6 (17F113)**,
  Swift 6.3.3, SDKs: iOS 26.5 / iOS-Simulator 26.5 / macOS 26.5
- Scope: **docs only**. No app target file is touched by this card. All probes live outside the
  repo in `~/.hermes/profiles/mmios-architect/cache/scratch/t44a/`.

---

## 1. Question 1 — which WebRTC client library can be vendored?

| candidate | pinned | SwiftPM resolve on this host | builds iOS Simulator | builds Mac Catalyst | usable for Mattermost Calls? |
|---|---|---|---|---|---|
| `stasel/WebRTC` (Google WebRTC binary) | `137.0.0` = `b85669f32ffb3f48ce3a8f18ad828c6f559a8a0c` | pin written, **artifact download hangs** (§3) | **BUILD SUCCEEDED** | **BUILD SUCCEEDED** (`--platform ios --environment macabi`) | **yes** — plain WebRTC engine, bring-your-own signalling |
| `livekit/client-sdk-swift` | `2.18.0` = `93a7251057bdb6a80a7b1f6d11464d578ebdc09b` | git fetch OK, **artifact download hangs** (§3) | n/a — not built (signalling is LiveKit's own) | n/a | **no** — speaks LiveKit SFU signalling, not Calls' |
| `livekit/webrtc-xcframework` (the engine under it) | `150.7871.03` = `a41df9e9bcc7ab1d62131fda75c123ea391e5188` | artifact only, hangs (§3) | **BUILD SUCCEEDED** | **BUILD SUCCEEDED** | as an engine only — but `LK`-prefixed and strictly worse than stasel (§2) |
| `mattermost-plugin-calls` + `calls-common` | calls `6b65e3b5066c18ec732173b934e4341ca593d02c`; calls-common `59e41e8f8f2211490a36fed3a9f8e7b7d2140e20` | not a Swift package | n/a | n/a | **not a library** — it is the protocol reference (§4) |

**Decision: vendor `stasel/WebRTC` 137.0.0.** It is the same Google WebRTC engine the browser client
runs, so SDP/ICE interop with the Calls server is the default expectation rather than a porting
exercise; it has no signalling opinions to unlearn; its licence is the WebRTC BSD-3 (`LICENSE` in
the xcframework: *"Copyright (c) 2011, The WebRTC project authors … Redistribution and use in source
and binary forms … permitted"*).

Apple's own `WebRTC.framework` is not on this host (checked: absent from all platform SDKs), so a
vendor drop is mandatory, not a preference.

### 1.1 Binary slices (verified by `plutil -p …/Info.plist` on the extracted xcframework)

`stasel/WebRTC` 137.0.0 — 4 slices, `WebRTC.framework` per slice:

| slice | supported arch | framework size |
|---|---|---|
| `ios-arm64` | arm64 | 11 MB |
| `ios-x86_64_arm64-simulator` | arm64, x86_64 | 26 MB |
| `ios-x86_64_arm64-maccatalyst` | arm64, x86_64 (`SupportedPlatform ios`, `Variant maccatalyst`) | 25 MB |
| `macos-x86_64_arm64` | arm64, x86_64 | 25 MB |

`livekit/webrtc-xcframework` 150.7871.03 — `ios-arm64` 12 MB, `ios sim` 28 MB, `maccatalyst` 28 MB,
plus `macos`, `tvos`, `xros` slices. Symbols are prefixed (`RTCMacros.h:43 #define RTC_OBJC_TYPE_PREFIX LK`),
so the classes a Calls client needs are `LKRTCPeerConnectionFactory`, `LKRTCVideoTrack`, … — not a
drop-in for stasel's names.

---

## 2. What "builds" was actually proven

Three probe packages, each a real SwiftPM package whose target imports the framework and touches the
entry points a Calls client needs (`RTCPeerConnectionFactory` / `RTCCameraVideoCapturer` /
`RTCVideoTrack` for stasel; `LKRTCPeerConnectionFactory` / `LKRTCVideoTrack` / `LKRTCVideoSource`
for LiveKit — its `LKRTCCameraVideoCapturer` did **not** resolve in Swift even though the symbol is
in the binary per `nm -gU LiveKitWebRTC` and the header ships, which is one more reason not to build
on the LK-prefixed framework):

| probe | dependency | iOS Simulator | Mac Catalyst | log |
|---|---|---|---|---|
| `probe-vendored` | stasel/WebRTC 137.0.0, `binaryTarget(path:)` | `** BUILD SUCCEEDED **` | `** BUILD SUCCEEDED **` | `docs/t44a-ios-simulator-build.log`, `docs/t44a-catalyst-build.log` |
| `probe-lkwrtc` | livekit/webrtc-xcframework 150.7871.03, `binaryTarget(path:)` | `** BUILD SUCCEEDED **` | `** BUILD SUCCEEDED **` | `docs/t44a-livekit-webrtc-ios-simulator-build.log`, `docs/t44a-livekit-webrtc-catalyst-build.log` |
| `probe-replaykit` | system ReplayKit (`RPSystemBroadcastPickerView`) | `** BUILD SUCCEEDED **` | `** BUILD SUCCEEDED **` | `docs/t44a-replaykit-ios-simulator-build.log`, `docs/t44a-replaykit-catalyst-build.log` |

The Catalyst build is genuinely the Catalyst slice, not a macOS rerun — from
`docs/t44a-catalyst-build.log`:

```
ProcessXCFramework …/Vendor/WebRTC.xcframework …/Debug-maccatalyst/WebRTC.framework ios macabi
    builtin-process-xcframework --xcframework …/Vendor/WebRTC.xcframework --platform ios --environment macabi
```

Commands (reproduce):

```sh
xcodebuild -scheme ProbeVendored -destination 'generic/platform=iOS Simulator' -derivedDataPath ./dd-ios build
xcodebuild -scheme ProbeVendored -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath ./dd-catalyst build
```

Note on linkage: the package emits a static object for the Swift target and processes the
xcframework as a **dynamic** `WebRTC.framework`. Integration into `Mattermost.xcodeproj` (which is a
hand-written pbxproj with no SPM) therefore means adding/linking/embedding the framework in the app
target — the same shape as the existing `PushProxy` target, and an ~11 MB device / ~25 MB
simulator-Catalyst payload (§5).

---

## 3. The one thing that did not work: `binaryTarget(url:)` artifact downloads

This is an answer, recorded as such, not a blocker.

**Symptom.** For the two candidates whose manifest declares a remote `binaryTarget(url:)`:

- `stasel/WebRTC` (`Package.swift` of 137.0.0 → `WebRTC-M137.xcframework.zip`,
  checksum `9b45c5c5…c3edd`): `swift package resolve` writes `Package.resolved` with the pin
  `137.0.0 / b85669f…` and then **never terminates**. Two attempts: the first ran **≥7 min** until the
  tool cap killed it, the second was killed at **96 s**. `.build/artifacts/webrtc/WebRTC/` stays
  **empty**, and `lsof -p <pid>` shows **no open sockets** — it is not downloading, it is stuck before
  the first byte.
- `livekit/client-sdk-swift` 2.18.0: git fetch completed (`Package.resolved` holds all three pins,
  43 MB of checkouts in `.build/`), then the same hang at the artifact step — **killed at 333 s
  (5.5 min)**, with both `artifacts/livekit-uniffi-xcframework/` and `artifacts/webrtc-xcframework/`
  still **0 bytes**.

**Control probe — it is not the network and it is not git.**
`probe-source-only` (a source dependency on `apple/swift-collections`) resolves end-to-end in
**6.2 s**:

```
Fetching https://github.com/apple/swift-collections.git
[1/29301] Fetching swift-collections
Fetched https://github.com/apple/swift-collections.git from cache (4.65s)
Computed https://github.com/apple/swift-collections.git at 1.7.4 (6.23s)
Working copy of https://github.com/apple/swift-collections.git resolved at 1.7.4
```

And the exact artifact SwiftPM refuses to fetch downloads fine by hand:
`curl -sL …/WebRTC-M137.xcframework.zip` → **41,307,432 bytes in 12.8 s**,
`shasum -a 256` = `9b45c5c5ecae392403758bb7262f408aa3cff705d41e862dd766856b610c3edd`, which is
byte-for-byte the checksum in stasel's manifest. Unzips to an 87 MB xcframework with all four slices.

**Consequence for T44.** Do not design around SwiftPM. Commit the xcframework to the repo (or an
internal mirror) and wire it into the pbxproj as a vendored framework, pinned by that SHA-256. Repo
cost: 39 MB as the release zip, 87 MB extracted — pick one and say so in the card that does it.

**Correction to a recorded assumption.** `docs/parity.md` (Diagnostics / T19a paragraph) records
"SwiftPM cannot fetch github.com on this host (git transport breaks on the `~/.gitconfig` PAT
rewrite)". That is not what happens today: git transport works (both candidates fetched their
repos; the control probe resolved a source package in seconds). What breaks is specifically
SwiftPM's **binary-artifact downloader**. The T19a conclusion (Sentry stays a no-op stub) is
unaffected in practice — the Sentry product is also artifact-based — but the *reason* on file is
wrong and should be corrected by whoever owns that paragraph.

---

## 4. Question 2 — is Calls' signalling documented well enough to interoperate from a non-web client?

Short answer: **the transport and message set are documented by the source and are usable; the
client-side RTC glue is not a protocol, it is one class you must reimplement.** Everything below is
pinned to a commit you can diff.

### 4.1 Transport: the *core* Mattermost WebSocket, not a plugin socket

`mattermost-plugin-calls` never opens its own WebSocket. It hooks the core one:

- `server/api_router.go:16` builds an HTTP-only `mux` router; there is no `/ws` route anywhere in it.
- Client→server signalling arrives through the plugin hook
  `func (p *Plugin) WebSocketMessageHasBeenPosted(connID, userID string, req *model.WebSocketRequest)`
  (`server/websocket.go:1200`) — i.e. the core server dispatches plugin-prefixed frames to the plugin.
- The prefix is compiled in: `wsActionPrefix = "custom_" + manifest.Id + "_"` (`build/manifest/main.go:40`),
  so client actions are `custom_com.mattermost.calls_<type>` (`server/websocket.go:1205-1209`).
- Core dispatch: prefixed actions bypass the core router and are pushed to plugins —
  `mattermost/mattermost` `server/channels/app/platform/web_conn.go:492-511`
  (*"Messages which actions are prefixed with the plugin prefix should only be dispatched to the
  plugins"*, then `wc.pluginPosted <- pluginWSPostedHook{wc.GetConnectionID(), wc.UserId, clonedReq}`)
  at `c2f2eff3b2684e1be94a24bbc48848bb437389dd` (master on 2026-10-24).
- Server→client: plugin events are published with the same prefix through `p.publishWebSocketEvent`
  (`server/websocket.go:121`); the SDP/ICE carrier is `wsEventSignal = "signal"`
  (`server/websocket.go:27`, published at `:688`) with payload `{data: <sdp|ice JSON string>, connID}`.

### 4.2 Framing: a native client may use plain JSON

The core socket accepts **either** JSON text frames **or** msgpack binary frames —
`web_conn.go:479-483` at `c2f2eff3`:

```go
if msgType == websocket.TextMessage {
    decoder = json.NewDecoder(rd)
} else {
    decoder = msgpack.NewDecoder(rd)
}
```

The web client uses msgpack (`calls/webapp/src/websocket.ts:4,63`, `@msgpack/msgpack`), but that is
an optimisation, not a requirement. **This app already has the other half**: T28's
`Mattermost/Core/MM/SocketClient.swift` speaks JSON text frames to `<server>/api/v4/websocket` and
already handles the cookie/token auth path (`SocketClient.swift:7,173,397`). A native Calls client
reuses it rather than growing a second socket.

### 4.3 Auth path

Nothing Calls-specific. The plugin's WS session is the core session:
`clonedReq.Session.Id = session.Id` (`web_conn.go:502-504`), consumed by `handleJoin(userID, connID,
authSessionID, joinData)` (`server/websocket.go:734`), with a 10-second server-side re-check
(`sessionAuthCheckInterval = 10 * time.Second`, `server/websocket.go:571+`, `p.API.GetSession` at
`:600`) that force-closes RTC sessions whose session was revoked or expired. Plus the ordinary REST
surface a client needs, from `server/api_router.go`: `GET /version` (:21), `GET /config` (:84),
`GET /calls/{channel_id}/active` (:109), `POST /calls/{channel_id}/decline` (:106),
`GET /turn-credentials` (:156), all under `/plugins/com.mattermost.calls/`.

### 4.4 Message set (client→server), `server/client_message.go:13-33 @ 6b65e3b5`

`join`, `leave`, `reconnect`, `sdp`, `ice`, `mute`, `unmute`, `voice_on`, `voice_off`, `screen_on`,
`screen_off`, `video_on`, `video_off`, `raise_hand`, `unraise_hand`, `react`, `caption`, `metric`,
`call_state`, `ping`. Server→client events are the `wsEvent*` constants at `server/websocket.go:27-56`
(`signal`, `join`, `user_joined`, `user_left`, `user_muted`, …, `call_state`, `call_end`, `caption`,
host-control events).

### 4.5 What the client must reimplement — and it is not the web app

The browser glue lives in `@mattermost/calls-common`, pinned by the plugin at
`github:mattermost/calls-common#59e41e8f8f2211490a36fed3a9f8e7b7d2140e20`
(`calls/webapp/package.json:24`). Read at that exact commit:

- `src/rtc_peer.ts` (**616 lines**) — owns `new RTCPeerConnection(config)`, the `calls-dc` data
  channel (ping/RTT, and an optional SDP-over-data-channel path selected by the `dcSignaling` join
  flag), ICE candidates, the signalling lock, simultaneous-offer handling (`makingOffer`), simulcast
  screen encodings (`DefaultSimulcastScreenEncodings`), and a `mediaMap` handshake that maps incoming
  track ids to sessions. **This is the module a native client must reimplement in Swift**; the
  server has no say in it, so it is porting work, not reverse engineering.
- `src/dc_msg.ts` (**49 lines**) — data-channel framing: flat msgpack + zlib for SDP payloads.
- `src/rtc_stats.ts` (155), `src/utils.ts` (87), `src/rtc_monitor.ts` — stats/quality plumbing,
  optional for a first version.

Web-app-side call logic (`calls/webapp/src/client.ts` 1,284 lines, `websocket_handlers.ts` 691
lines) is mostly call-state and UI (expanded view, host controls, toasts). Only a fraction is
protocol; the rest is UI this project would build in SwiftUI anyway, and most of it is out of scope
for a first native Calls surface (join/leave, mute/unmute, video, hand raise, participants).

### 4.6 Licence — report, do not assume

`mattermost-plugin-calls` `LICENSE.txt` (also `calls-common/LICENSE`):

- Mattermost-compiled binaries are **MIT** (see the referenced `MIT-COMPILED-LICENSE.md` in
  compiled versions).
- **Source** is either **AGPL v3** (with the stated exceptions) or a **commercial licence**.
  `LICENSE.enterprise` is the Mattermost **Source Available** licence (production use requires an
  E20 subscription).
- `webapp/i18n/` and configuration files are Apache-2.0 (per `LICENSE.txt`).
- GitHub's own metadata reports this repo as `NOASSERTION`; the licence files above are what apply.

Reading the protocol to write an independent client does not copy source. What would cross the line:
porting `rtc_peer.ts` line-by-line, or vendoring `calls-common`'s compiled `lib/` into the app. The
card's recommendation is protocol reimplementation from the server message contract + `rtc_peer.ts`
*as a specification*, with a recorded legal sign-off before native Calls ships. Flagging it now
rather than at review time.

### 4.7 Precedent: Mattermost already ships a native Calls client — and it is Apache-2.0

The strongest evidence that this is a reimplementation job and not a reverse-engineering one:
`mattermost/mattermost-mobile` **v2.45.0** (checked 2026-10-24) is a React-Native client with a
complete native Calls product:

- `package.json:25-26,107` — `"@mattermost/calls-native": "file:./libraries/@mattermost/calls-native"`,
  `"@mattermost/calls": "github:mattermost/calls-common#bf5c7a25d43478b7949a45d4cbbdacac17705b59"`,
  **`"react-native-webrtc": "124.0.7"`** — i.e. the same Google WebRTC engine family this spike
  vendors, plus Mattermost's own native glue.
- `libraries/@mattermost/calls-native/` — podspec + `ios/Source/MMCallsNative.{h,mm}` + Swift
  (`CallsBridge+Events.swift`), `src/NativeMMCallsNative.ts`: the bridge between JS and the device
  audio/session layer.
- `app/products/calls/connection/websocket_client.ts`, `websocket_event_handlers.ts`,
  `app/products/calls/native_call.ts`, `native_call_mappings.ts` — a non-web signalling client (WS
  actions + event handlers) written against the same plugin contract this spike traced, in
  Apache-2.0 TypeScript.

So the protocol work in §4.5 has an Apache-2.0 sibling implementation that may be **reimplemented in
Swift without licence friction** — a far better reference for T44c than the AGPL `calls-common`
`rtc_peer.ts`, and consistent with this programme's existing rule (`docs/component-map.md`, T25b:
mattermost-mobile is the authority; AGPL webapp is observe-only).

The one thing the official client does **not** do is screen share: `ios/` has no broadcast-extension
target (`Mattermost`, `MattermostShare`, `NotificationService`, `ErrorReporting` only), and
`app/products/calls/screens/call_screen/` has no screen-share control. See §6.


---

## 5. Question 3 — memory: a native engine must not cost what the webview costs

**Measured, on this host** (`probe-memory`, macOS arm64 slice of the same xcframework; three runs;
`docs/t44a-memory-probe-2026-10-24.log`):

| stage | run 1 | run 2 | run 3 |
|---|---|---|---|
| 0. process start | 8.1 MB | 8.1 MB | 8.2 MB |
| 1. encoder/decoder factories + `RTCPeerConnectionFactory` | 14.0 MB | 14.0 MB | 14.0 MB |
| 2. + one `RTCPeerConnection` with a `calls-dc` data channel | 15.1 MB | 15.1 MB | 15.2 MB |
| 3. after 5 s settle | 15.1 MB | 11.6 MB | 15.2 MB |

So: **the engine baseline is ≈6 MB and one non-connected peer connection lands at ≈12-15 MB
resident** — the entire WebRTC engine costs less than the SwiftUI shell's own floor (30.0 MB Catalyst
shell, T27), and ~30-40× less than one loaded webview.

**What is NOT measured, stated plainly:** media. No audio encoding (Opus), no video
encode/decode, no remote streams, no rendering, no camera pipeline — this host has no Calls server to
connect to. No vendor publishes a per-active-call RSS number for WebRTC on iOS, and this spike will
not invent one. A realistic single-video-call cost is the measured floor plus codec and frame-buffer
memory; that must be probed on a device (§8, P2).

**The bar, per T27** (`docs/perf/README.md`, measured 2026-10-24 16:46-16:48 by
`scripts/perf_probe.sh`, macOS 26.3.1 / Xcode 26.6, 9.11.19 server):

| target | app-only floor (`shell`) | what one loaded webview costs | Path A steady |
|---|---:|---:|---:|
| catalyst | 30.0 MB | **562.1 MB** | 592.1 MB |
| simulator | 28.6 MB | **460.7 MB** | 489.3 MB |

The native `calls` surface beats the 460-562 MB webview by two orders of magnitude at the engine
level; even a 10× under-estimate of media cost keeps it under the bar. Memory is **not** the reason
to stay on the webview.

---

## 6. Question 4 — screen share

**Yes, it needs a Broadcast Upload Extension on iOS, and that is a new target, not a code path.**

Corroboration first: **the official Mattermost mobile client does not ship screen share at all** —
its `ios/` project has no broadcast-extension target and its call screen has no screen-share control
(§4.7). Whatever we do here is beyond even the platform's own native client, which is why it is
carved out of the verdict rather than included in it.

- The web client captures with `navigator.mediaDevices.getDisplayMedia(...)`
  (`calls/webapp/src/utils.ts:298-300`) — a whole-screen/window capture API. iOS has no equivalent;
  an app can only capture *other* apps' content through ReplayKit's system broadcast flow.
- The entry point is `RPSystemBroadcastPickerView`, and the platform constraint is in the SDK
  header itself (`iPhoneOS26.5.sdk/.../ReplayKit.framework/Headers/RPBroadcast.h:176-186`):

  ```objc
  #if !TARGET_OS_OSX
  /*! @class RPSystemBroadcastPickerView
   @abstract View that presents the user with a button for starting iOS system broadcast using preferred broadcast service. */
  API_AVAILABLE(ios(12.0)) API_UNAVAILABLE(tvos, macos)
  @interface RPSystemBroadcastPickerView : UIView <NSCoding>
  @property (nonatomic, strong, nullable) NSString *preferredExtension;
  @property (nonatomic, assign) BOOL showsMicrophoneButton;
  ```
- It **compiles on both destinations the app ships** (probe `probe-replaykit`: BUILD SUCCEEDED for
  iOS Simulator *and* Catalyst, §2), because Catalyst is not `TARGET_OS_OSX` and the picker is not
  `API_UNAVAILABLE(maccatalyst)`. Whether a *system broadcast service* is present to drive on
  Catalyst at runtime is **unverified here** — that is a named probe (P3), not an assumption.

**What it costs** (this is the T16 question, answered):

1. A second target: the Broadcast Upload Extension (`RPBroadcastSampleHandler` subclass), its own
   bundle id, its own provisioning profile, its own App Store review submission — the extension is
   what App Review sees as "screen recording".
2. An App Group + shared container so the extension can hand frames (and audio) to the app (or run
   its own WebRTC stack, which doubles the engine memory).
3. Extension memory limits are far tighter than the app's; ReplayKit sample buffers at screen
   resolution must be converted to `RTCVideoFrame` and encoded inside that budget.
4. Signalling: still `screen_on`/`screen_off` on the same WS, with the screen stream added as a
   second video track — that part is cheap; the capture plumbing is the expensive part.
5. Catalyst needs its own answer (ScreenCaptureKit is not reachable from a Catalyst target), so the
   feature would be iOS-complete / Catalyst-not, until P3 says otherwise.

In-app-only capture (rendering our own SwiftUI hierarchy into frames) is possible without ReplayKit
but is **not parity**: it cannot show other apps or the desktop, which is what users expect from
Calls screen share.

---

## 7. Question 5 — capture permissions

`Mattermost/Info.plist:71,73` already carries `NSCameraUsageDescription` /
`NSMicrophoneUsageDescription` (added for the webview's `getUserMedia`). Nothing else in the *strings*
is required for a native engine. What is required beyond the strings:

| requirement | status today | what a native engine adds |
|---|---|---|
| Runtime prompt | happens inside WebKit for the webview | the app must call `AVCaptureDevice.requestAccess(for: .video/.audio)` **before** the engine starts; WebRTC does not prompt for you, and a denied grant must map to a visible "no camera/mic" state instead of a silent black tile |
| `AVAudioSession` | WebKit owns it | the engine owns it: category `.playAndRecord`, mode `.voiceChat`, plus route handling (speaker/receiver/Bluetooth) — `RTCAudioSession` exists for exactly this |
| `UIBackgroundModes` | `["fetch"]` only (`Info.plist`) | **`audio` must be added**, or a call drops the moment the app backgrounds — a real parity gap to plan for, not an optional nicety |
| Entitlements (iOS) | none | none needed for camera/mic |
| Entitlements (Catalyst) | App Sandbox deliberately off (T20, `Mattermost/Mattermost.entitlements`) | nothing today; **App Store distribution** of the Catalyst build would need `com.apple.security.device.camera` + `com.apple.security.device.audio-input` |
| Privacy manifest | `Mattermost/PrivacyInfo.xcprivacy` declares Audio Data / Photos or Videos as "web-app Calls only" | the wording and the declared collection must be updated when the engine is native |
| Review narrative | `docs/app-store-review-notes.md` explains webview-mediated capture | must be rewritten: the app now captures directly, and (if screen share ships) ships a broadcast extension |

---

## 8. Recommendation

1. **Accept `NATIVE VIABLE` for audio/video and keep `calls` on `web` until the gates below pass.**
   No `SurfaceMode` change in this card; `nativeApprovedSurfaces` stays empty.
2. **Vendor `stasel/WebRTC` 137.0.0** into the repo as a binary framework (zip or extracted
   xcframework — decide in T44b), pinned to SHA-256
   `9b45c5c5ecae392403758bb7262f408aa3cff705d41e862dd766856b610c3edd`, wired into the pbxproj app
   target with link+embed. Do not spend more time on `swift package resolve` for it; the artifact
   downloader on this host is broken for every `binaryTarget(url:)` (§3).
3. **Split T44** into gated cards rather than one:
   - **T44b engine shell** — vendored framework, `RTCPeerConnectionFactory` lifecycle, audio session,
     capture permissions, no UI. Must not disturb the webview path.
   - **T44c signalling port** — `custom_com.mattermost.calls_*` actions and `signal` events on the
     existing `SocketClient`, plus the Swift port of the signalling/peer semantics. Mirror
     `mattermost-mobile` v2.45.0 `app/products/calls/connection/` (Apache-2.0) and treat
     `calls-common/src/rtc_peer.ts` as the specification behind it. This is the card where the
     interop gate lives.
   - **T44d call surface** — SwiftUI expanded view / participants / mute / video / hand raise,
     the actual `calls` surface card.
   - **T44e screen share** — ReplayKit broadcast extension, only after P3 answers the Catalyst
     question. Do not let it gate T44b-d.
4. **Named next probes** (each closes a risk this spike could not):
   - **P1 — SDP/ICE interop** (the only real protocol risk): stand up a local Mattermost with the
     Calls plugin, join from the web client and from a native probe peer, confirm bidirectional audio
     and the `signal`/`sdp` exchange shape. Gate for T44c.
   - **P2 — memory per active call on device**: 1:1 audio, 1:1 audio+video, 1:9 video, screen-share
     on, measured with `footprint` on a physical device. Gate for T44d's memory claim.
   - **P3 — broadcast extension + Catalyst**: build a throwaway broadcast extension, measure
     `RPSystemBroadcastPickerView` behaviour on Catalyst, and the extension's memory ceiling. Gate for
     T44e.
5. **Get the licence position recorded before T44c merges**: independent protocol implementation,
   no `calls-common` code or compiled `lib/` vendored into the app; AGPL/source-available boundary
   spelled out in the ADR.

---

## 9. Appendix — probe artifacts (not committed)

All outside the repo, under `~/.hermes/profiles/mmios-architect/cache/scratch/t44a/`:
`probe-vendored`, `probe-lkwrtc`, `probe-replaykit`, `probe-memory`, `probe-source-only`,
`probe-stasel` (the hanging resolve), plus `WebRTC-M137.xcframework.zip`, `LiveKitWebRTC.zip`,
`xcf/`, `lkxcf/`, `calls/` and `calls-common/` checkouts.

Committed with this doc: the six build logs and the memory-probe log listed in §2 and §5.

---

## 10. T44 follow-up measurements (2026-10-27) — three corrections and the media gate

This section was appended by **T44** (`t_a3383222`) when it landed this note on `main` (the note and
its logs were written on `wt/t_0845e828` and had not been merged). It does not change §1's verdict for
the *library* questions; it corrects three protocol statements and records the one gate §8 named that
this card could close — and the one it could not.

Measured with `scripts/t44_calls_probe.py` against the programme fixture's live plugin
(`com.mattermost.calls` **0.29.8**, build `936dd00d3e456c843b846740aa76601d07e6a25a`, which is
`mattermost-plugin-calls` tag `v0.29.8` = commit `936dd00` — a checkout of the *installed* build, not
HEAD). Full output: `docs/t44-calls-probe-2026-10-27.log`; media-path evidence:
`docs/t44-calls-media-path-2026-10-27.log`.

**C1 — §4.2's "a native client may use plain JSON" holds for `join`/`ice`/call-state reads, but is
wrong for `sdp`, and that is the one action a call cannot work without.** The plugin type-asserts the
SDP payload to `[]byte` (`server/websocket.go`, `msgData, ok := req.Data["data"].([]byte)` —
`websocket.go:1226` at `936dd00`, `:1350` at `6b65e3b`, i.e. **both** versions), and the core server's
JSON decoder produces a `string`, so the frame is dropped server-side with
`{"level":"error","msg":"invalid or missing sdp data","origin":"…WebSocketMessageHasBeenPosted websocket.go:1226"}`
and the session is torn down at the 10 s signalling timeout. Measured as probe checks 5 (JSON offer,
no `signal` ever arrives) and 6 (the same offer as a MessagePack binary frame is answered in ~60 ms).
Consequence for T44c: `SocketClient` needs a **binary** send (`URLSessionWebSocketTask.send(.data:)`)
plus a MessagePack encoder for this frame and **zlib** framing of the SDP JSON
(`server/utils.go unpackSDPData` → `zlib.NewReader`). `ice` is a JSON *string* and stays on the text
path.

**C2 — the client is the offerer.** §4.4 lists the message set but not the direction. The SFU never
offers: `calls-common`'s `RTCPeer` emits a local offer from `onNegotiationNeeded`
(`src/rtc_peer.ts:136-142` at the plugin's pinned `e463e78cc76302d1bdbd085d9e1846c456f48d45`) as soon
as the first local track is added, and only then answers the client
(`:196-198`). A client that joins and waits is disconnected after ~10 s — measured, probe check 8.

**C3 — the pinned protocol source and the deployed plugin were different versions.** This note read
`mattermost-plugin-calls` at `6b65e3b` (= `v1.12.6-2`). The plugin shipping in the tested image is
`v0.29.8`: it has **no** `video_on`/`video_off` (`server/client_message.go`) and no `/rtc` REST route
(`server/api_router.go`). A client must be written against the behaviour both share — `join`, `leave`,
`reconnect`, `sdp`, `ice`, `mute`/`unmute`, `voice_on`/`voice_off`, `screen_on`/`screen_off`,
`raise_hand`/`unraise_hand`, `react`, `call_state` — and version-gate the rest. Also worth carrying
into any implementation: the join payload key is `channelID` (not `channel_id`), the `join` ack is
followed by `call_state` carrying `call` as a **JSON string**, and the plugin is an **SFU** (§4.1's
"plugin hooks the core socket" is right, but media terminates on `rtc.NewServer` in the plugin
process — it is not a relay between participants).

**P1, partially closed.** §8's P1 asked for "SDP/ICE interop against a real Calls plugin". The
signalling half is now measured end to end (join → call_state → offer → answer → 5 ICE candidates,
8/8 probe checks green). The media half **cannot be closed on this host**: the SFU's ICE port is
published nowhere. The container `mm-perf` publishes only `8065/tcp`; the ICE listener is bound at
`172.19.0.3:8443` inside `mm-perf-net`; and all three UDP candidates the SFU advertised
(`127.0.0.1:8443`, `64.251.85.226:8443`, `209.35.187.178:53080`) time out to a STUN binding request
from the host while a control STUN server answers. 0/3 reachable → no client can connect. The remedy
(UDP relay sidecar on `mm-perf-net` + `ICEHostOverride`) is written in
`docs/t44-calls-media-path-2026-10-27.log` §5 and is T44b's job, not this card's.

**What that means for this note's recommendation:** §8's split stands (T44b/T44c/T44d/T44e), with one
addition — **T44b must come first and must prove RTP**, because until the fixture's SFU is reachable no
"bidirectional audio" criterion can be measured by anybody, and `SurfaceDefaults.nativeApprovedSurfaces`
must not gain `calls` on the strength of a signalling test alone.
