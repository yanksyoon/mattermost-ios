# T44c — native Calls signalling engine

Scope: decode the Calls plugin's websocket frames, speak the plugin's signalling protocol, run a
native libwebrtc peer connection, and wire it into the existing `SocketClient`/`SocketEvent`
architecture. WebRTC media *behaviour* (mute semantics, audio session, RTP) is T44b's subject; this
card is the client half of the protocol plus the engine that consumes it.

## 1. What was built

| File | What it is |
|---|---|
| `Mattermost/Core/Calls/CallsProtocol.swift` | wire vocabulary: plugin id, `custom_<id>_<event>` prefix, client actions (`server/client_message.go`), server events (`server/websocket.go`), `CallsPluginVersion` (0.29.8 vs 1.x gating) |
| `Mattermost/Core/Calls/CallsModels.swift` | `CallsCall` / `CallsSession` / `CallsStartedCall` / `CallsSessionDescription` / `CallsIceCandidate` — no WebRTC types, so the codec and its tests need no framework |
| `Mattermost/Core/Calls/CallsEvents.swift` | `CallsEvent(name:data:)`: every `wsEvent*` → a typed event, or `nil` for a malformed/foreign frame |
| `Mattermost/Core/Calls/CallsSignallingCodec.swift` | MessagePack writer + zlib (RFC 1950) SDP codec: the `sdp` action's frame |
| `Mattermost/Core/Calls/CallsSignallingPort.swift` | `CallsSignalling` seam + live port over `CallsSocketTransport`; the `connID` session filter |
| `Mattermost/Core/Calls/CallsPermissions.swift` | `AVCaptureDevice` microphone grant behind a protocol, with a timeout |
| `Mattermost/Core/Calls/CallsAudioSession.swift` | `RTCAudioSession` owner (`.playAndRecord` / `.voiceChat`) |
| `Mattermost/Core/Calls/CallsEngine.swift` | the engine: permission → join → offer → answer → re-offer → ICE, plus stats |
| `MattermostTests/T44CCalls{Codec,Event,SignallingPort,Engine}Tests.swift` | 63 tests |
| `scripts/t44c-pbxproj-add-webrtc.py` | deterministic project-file transform (link + embed + `Core/Calls` sync group) |
| `Mattermost/Vendor/WebRTC.xcframework` | the engine, committed by design (see §7) |

Core-socket changes (both additive):

* `SocketEvent.plugin(name:data:)` — a `custom_*` frame is now a first-class event carrying its raw
  payload, instead of `unhandled`. Five view models got one extra case in an ignore list.
* `SocketClient.sendBinaryFrame(_:)` / `sendTextFrame(_:)` — the Calls `sdp` action must go out as a
  MessagePack **binary** frame; a JSON text frame is dropped server-side.

## 2. The two corrections this card measured

**C1 — `sdp` is binary MessagePack, not JSON.** The plugin type-asserts `req.Data["data"]` to
`[]byte` and drops anything else ("invalid or missing sdp data"). The core JSON decoder can only
produce a `string`, so the frame must be MessagePack with `data.data` as a bin holding
`zlib(JSON({"type":…,"sdp":…}))`. `CallsSDPCodec.sdpFrame(seq:description:)` is that frame, and
`T44CCallsCodecTests` asserts the map's shape rather than opaque bytes (zlib output is not
byte-stable across builds) plus an interop fixture produced by CPython's `zlib.compress` — the same
stream format Go's `zlib.NewReader` reads.

**C2 — `connID` is on the event, not in the inner JSON, and the join ack cannot identify a session.**
`signal` is published with `WebSocketBroadcast{ConnectionID: us.connID}`, and `join` is broadcast
**per user** — so two sockets of one account both receive the ack. The port therefore learns its own
session from the first `answer` (`data.connID`) and drops every other `connID`'s signalling
(`droppedForeignSignals` counts them). A signal that arrives before any answer is dropped unless it
is an answer: adopting a stranger's connection is worse than waiting one round trip.

## 3. Ordering rules the engine enforces (each is a test)

1. **The client offers.** The SFU never offers first; a client that joins and waits is dropped at the
   plugin's 10 s signalling timeout.
2. **`join` before `sdp`.** The plugin has no RTC session to route an `sdp` to before the join. The
   ack can arrive while `join` is still in flight, so the offer is created from a single
   `offerTask` that both the ack handler and `start()` await — without that, `start()` returned
   `.offering` with no frame sent (measured failure, fixed).
3. **Candidates trickle only after the offer goes out**; anything gathered earlier is buffered.
4. **Remote candidates that arrive before the answer are queued**, then applied after it.
5. **The SFU's re-offer is answered** (`offer` → set remote → answer → send). Skipping it is exactly
   the T44b finding of zero inbound RTP.

## 4. Audio-session ownership

`SystemCallsAudioSession` takes the session for a call (`.playAndRecord`, `.voiceChat`, active,
`useManualAudio = false`, `isAudioEnabled = true`) and gives it back in `stop()`. A failure to
activate is **recorded, not fatal**: signalling can proceed and a device will still be silent-only.
The microphone grant is asked **before** the engine starts; a refusal is a visible state
(`.permissionDenied`), and `.joinWithoutMicrophone` is the web client's behaviour (you hear the call,
muted).

## 5. Vendored engine

`WebRTC.xcframework` (Google WebRTC via `stasel/WebRTC` 137.0.0, BSD-3-Clause) is committed at
`Mattermost/Vendor/WebRTC.xcframework` — **87 MB**. It is committed by design: SwiftPM's
`binaryTarget(url:)` artifact downloader hangs on this host (two measured attempts,
`docs/t44a-calls-spike.md` §3), while a vendored path target builds. Provenance, hashes, link/embed
phases and the update procedure are in `Mattermost/Vendor/README.md`; the licence entry is §21 of
`docs/THIRD_PARTY_NOTICES.md`.

Build proof (real output, this host): `xcodebuild build … -destination 'platform=macOS,variant=Mac Catalyst'`
→ **BUILD SUCCEEDED**; the bundle contains `Contents/Frameworks/WebRTC.framework` ad-hoc signed
(`Identifier=org.webrtc.WebRTC`, `flags=0x2(adhoc)`), and `Mattermost.debug.dylib` carries
`@rpath/WebRTC.framework/WebRTC` with `LC_RPATH=@loader_path/../Frameworks`. The built app launches
and stays up (dyld would refuse an unresolvable `@rpath` dependency).

## 6. Verification (what was actually run)

Run in an isolated snapshot of the working tree
(`~/.hermes/profiles/mmios-ios/cache/scratch/t44c-verify/repo`, rsync minus `build/`, `.git` and the
T44-AV-R worker's in-flight files) with its own derived data, because the shared checkout was being
built by another worker at the same time:

```
xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath …/t44c-verify/dd \
  -only-testing:MattermostTests/T44CCallsCodecTests \
  -only-testing:MattermostTests/T44CCallsEventTests \
  -only-testing:MattermostTests/T44CCallsSignallingPortTests \
  -only-testing:MattermostTests/T44CCallsEngineTests DEBUG_INFORMATION_FORMAT=dwarf
```

→ `Executed 63 tests, with 3 tests skipped and 0 failures (0 unexpected) in 2.107 s`,
`** TEST SUCCEEDED **` (log `…/t44c-verify/run8.log`). Per class: codec 9, events 23, signalling
port 17, engine 14 (3 skipped).

The 3 skips are the peer-negotiation tests (`testTheSFUsAnswerIsAppliedAndTheEngineConnects`,
`testAServerReOfferIsAnswered`, `testARemoteCandidateBeforeTheAnswerIsQueuedAndTheCallStillConnects`).
They build a **second** `RTCPeerConnectionFactory`, and in the xctest app host that blocks inside
CoreAudio: the run wedges while logging

```
HALC_ShellObject.mm:268  HALC_ShellObject::HasProperty: call to the proxy failed, Error: 2684
```

every 30 s (measured, twice: `run4.log`, `run6.log`). `coreaudiod` is running; the proxy is just not
reachable from the test process. They are opt-in (`MM_CALLS_PEER_TESTS=1`) rather than silently
skipped, so a host with audio can run them and nobody mistakes a skip for a pass.

libwebrtc itself is **not** broken here: a standalone probe (`…/t44c-verify/probe_factory.swift`,
linked against the vendored macOS slice) creates a factory, a peer connection, an audio source and
track, and produces a 1118-byte offer with `setLocalDescription` in **96 ms**, gathering state
`new` — `probe` output kept next to the log.

## 7. Not done (deliberately)

* No UI: no call surface, no participant list, no banner. The engine exposes a `CallsEngineSnapshot`
  for whoever renders it (T44d).
* No video: `video_on`/`video_off` are modelled and version-gated (`supportsVideo`) but nothing sends
  them, and the camera is still webview-only.
* No TURN/STUN: `iceServers = []`, matching the T44b harness. TURN credentials come from the plugin's
  `/turn-credentials` route — a later card.
* No APNs/voip-push wakeup for an incoming call: that is notification work, not signalling.
