# T44d — the native Calls surface (S33)

Card: `t_a2ff267a`. Engine underneath: T44c (`CallsEngine`, `CallsSignallingPort`).
Behaviour reference: `mattermost/mattermost-mobile` @ `162f2560d0e1df073220f7701d5a67cc17c8abeb`
(`app/products/calls/*`), Apache-2.0, reimplemented in SwiftUI — no upstream source copied
(`docs/THIRD_PARTY_NOTICES.md` §22).

## 1. What this card ships

| Piece | File |
|---|---|
| Pure decisions: tile rows, ordering, phases, duration, control set, camera capability | `Mattermost/UI/Native/Calls/CallsSurfaceModels.swift` |
| One live call, as the screen observes it (event folding + engine snapshot) | `Mattermost/UI/Native/Calls/CallsCallModel.swift` |
| App-scoped owner: "is there a call here", the one live call, socket bookkeeping | `Mattermost/UI/Native/Calls/CallsCoordinator.swift` |
| The screen: header state + timer, tile grid, mic banner, mute/hand/leave | `Mattermost/UI/Native/Calls/CallsSurfaceView.swift` |
| Channel-header entry point (`Start call` ⇄ `Join call`) | `Mattermost/UI/Native/Calls/CallsJoinEntry.swift` |
| REST: plugin version + active-call probe (plugin routes, **not** `/api/v4`) | `Mattermost/UI/Native/Calls/CallsAPI.swift` |
| Data seam + socket→`CallsEvent` bridge | `Mattermost/UI/Native/Calls/CallsSurfaceService.swift` |
| Wiring | `MattermostApp.swift`, `ChannelView.swift`, `TeamSidebarCoordinator.swift` |

Wiring is minimal and follows the existing screen-card pattern:

* `CallsCoordinator` is a `@StateObject` in `MattermostApp`, bound in `bindShellStores()`,
  fed from the rail's `onTeamEvent` fan-out, cleared by `authPhaseChanged`, and put in the
  environment.
* `TeamSidebarCoordinator.callsTransport(for:)` hands Calls **the rail's one socket** (never a
  second connection). `TeamEventSourcing` gained `transport(for:token:)` with a `nil` default, so
  every existing test fake still compiles.
* `ChannelView` renders `CallsJoinEntry` only when `resolver.resolvedMode(for: .calls) == .native`,
  i.e. exactly like every other header affordance: while `calls` renders web, the web client owns
  Calls and a second native button would be two answers to one tap.

`.calls` is **not** in `SurfaceDefaults.nativeApprovedSurfaces`; the surface ships dark until its
`-AV` card passes. Live suites turn it on with `-surfaceMode calls=native`.

## 2. Measured, not assumed

Every wire fact below was measured against the fixture (`127.0.0.1:8065`, Calls **0.29.8**, build
`936dd00`) with the probe ladder in `scripts/` + `t44d_probe_*.py`, not read off plugin source:

* `raised_hand` is a **unix-millisecond timestamp**, `0` = lowered — not a bool. `CallsSession`
  carries `raisedHandAt`, and `CallsSession.timestamp(from:)` still accepts the old bool shape.
* The hand events are **`user_raise_hand` / `user_unraise_hand`** (not `user_raised_hand`).
  `CallsProtocol.Event` uses the measured names and canonicalises the other spelling.
* Participation deltas carry a camel-case `channelID` and a snake-case `session_id`. `CallsEvent`
  keeps the channel so one client cannot fold another channel's call into the tiles it draws.
* `GET /plugins/com.mattermost.calls/version` → `{"build":…,"version":"0.29.8"}`;
  `GET …/calls/{id}/active` → `{"active":bool}`; `GET …/calls/{id}` → 404. The routes are at the
  **server root**, which is why `APIClient` gained `getPlugin(_:path:)` (no `/api/v4` prefix).
* `call_start` / `call_end` are **not** delivered to a plain authenticated member who has not
  `view`ed the channel, so the join button is driven by the REST probe (appearance + a 20 s poll),
  not by the socket. The socket still moves the button once a `call_state`/`call_end` arrives.

### 2.1 The mute round trip, measured twice

The card's Definition of Done asks for a live assertion that mute **round-trips through the
server**, so the oracle has to be the plugin's own broadcast, not the app's state. Measured with
two sockets of the same account on the fixture (`t44d_rework_mute_probe2.py`, `t44d_mute_step.py`):

```
B unmute  →  B and A both receive  custom_com.mattermost.calls_user_unmuted
             {"channelID":"wiky…","session_id":"g5i3…","userID":"jruq…"}
B mute    →  B and A both receive  custom_com.mattermost.calls_user_muted
             {"channelID":"wiky…","session_id":"g5i3…","userID":"jruq…"}
```

So: the names are `user_muted` / `user_unmuted` (not `user_mute`/`user_unmute`), and a **second
socket of the same account observes them** — which is what makes `MattermostUITests/T44DCallsUITests`
able to assert a server-side round trip on a device where it cannot read the app's memory
(`CallsSocketObserver`). Joining a call over the socket alone (no SDP, no ICE) is enough for the
plugin to create a session and emit these; the plugin drops such a session ~10 s later with
`user_disconnected` + `user_left`, because nothing ever connects media to it — which is why the
probe's session ends that way and the app's does not.

## 3. Rules the unit suite pins (40 T44d tests + 4 engine tests)

`MattermostTests/T44DCallsSurfaceTests.swift` (14), `…CoordinatorTests.swift` (17),
`…APITests.swift` (5), `T44DSocketBinarySendTests.swift` (3), plus 4 in
`MattermostTests/T44CCallsEngineTests.swift`.

* Participant ordering is upstream's: presenter first, then raised hands **oldest first**, then
  unmuted before muted, then name (case/diacritic-insensitive), then session id so the order is
  total. Two sessions of one account are two tiles.
* The header never renders a negative or 50-hour clock: `start_at <= 0` and a future start both
  read `00:00`.
* `Reconnecting…` needs a prior connection **and** a dropped transport — the engine keeps
  `.connected` while libwebrtc reports `disconnected`, so without this input a dead call would keep
  reading "In call".
* Mute and raise-hand need a live call *and* a granted microphone; leave is offered while joining;
  a denied mic still joins (the web client's behaviour) and explains itself in a banner.
* The camera control is **absent**, with the reason carried in `CallsControlSet
  .cameraUnavailableReason`: `CallsEngine.capturesVideo == false` and 0.29.8 has no `video_on`.
  It flips on by itself when both halves are ready — tested both ways.
* Screen share is **not modelled at all**: a native share needs the T44e ReplayKit broadcast
  extension and a recorded licence/App-Review position (a human decision). Another participant's
  share still marks their tile, because the call's audio still plays.
* The gate: `404` from the plugin route means "no Calls here" (remembered, button hidden, not
  re-asked); any other failure keeps the last known answer, so a blip cannot hide a live call.
* One call at a time; the same channel's button is idempotent; sign-out drops the call and every
  remembered fact about that server.
* `SocketClient.sendBinaryFrame` reaches a transport that implements `send(data:)`, throws
  `binaryFramesUnsupported` for one that does not, and `notConnected` before the socket opens (§4.1).
* The engine folds participation deltas into the call it publishes: a confirmed unmute survives the
  next snapshot, another channel's delta is ignored, `user_joined`/`user_left` move the sessions,
  and raise/lower plus a host change are folded (§4.1).

## 4. Evidence

* `xcodebuild build -scheme Mattermost -destination 'platform=macOS,variant=Mac Catalyst'` — clean.
* `xcodebuild test` on Catalyst, the T44c + T44d classes — **94 tests, 0 failures, 3 pre-existing
  peer-test skips** (`MM_CALLS_PEER_TESTS` not set).
* Live, `MattermostUITests/T44DCallsUITests` on `iPhone 16 Pro` (18.3.1) against the real fixture
  with the real Calls plugin: the app signs in, opens `#t44-calls`, the header offers Calls
  (`calls.joinButton`, value `idle`, label `Start call`), tapping it **mounts the surface**, the
  surface reaches **`In call`** with the reader's own tile (`Perf Probe (you)`, mute icon, host
  crown) and the control bar (`Unmute` / `Raise hand` / `Leave`) — `docs/t44d-shots/t44d-01-in-call.png`
  and `t44d-02-unmuted.png`, exported from the run's own attachments. The mute round trip reaches
  the server: the test's own second socket records `user_unmuted` for the call channel and the
  reader's user id.

### 4.1 The two defects the first cut had, and the fixes

**(a) `offer: binaryFramesUnsupported` — `send(data:)` was not a protocol requirement.**
`protocol SocketTransport` declared `events`, `resume()`, `send(text:)`, `close()`; `send(data:)`
existed **only** in an extension of the protocol, whose body throws. `SocketClient` holds its
transport as `SocketTransport?`, so `transport.send(data: frame)` was **statically dispatched** to
that default for every conformer — `WebSocketTransport`'s real implementation
(`URLSessionWebSocketTask.send(.data:)`) was never reached, and the Calls `sdp` action could not be
sent at all. Fix: `send(data:)` is now a requirement of `SocketTransport` (the throwing body stays
as the default, so a text-only fake still compiles) — `Mattermost/Core/MM/SocketEvent.swift`.

`T44DSocketBinarySendTests` pins both directions and was **run against the old declaration** to
prove it bites: with the requirement removed, `testBinaryFrameReachesTheTransportThatImplementsSendData`
fails with `caught error: "binaryFramesUnsupported"` — the live error, reproduced in a unit test —
and passes with it restored.

**(b) A confirmed mute was reverted by the next snapshot.**
`CallsEngine` deliberately ignored participation deltas ("a surface card renders them"), while
`CallsCallModel.applySnapshot` treats `snapshot.call` as the authority for the reader's own session.
The plugin sends the **delta** for a control and not always a fresh `call_state` with it (measured:
`user_unmuted` arrived alone), so the surface's correct optimistic unmute was overwritten with the
stale `muted` on the next poll — measured live as the control snapping back 3 s after the server had
confirmed the unmute. Fix: `CallsEngine.fold(_:)` folds `user_muted`/`user_unmuted`,
raise/unraise, `user_joined`/`user_left`, host change and screen-share into `snapshot.call`, ignoring
deltas that name another channel. `T44CCallsEngineTests` gained four tests for it.

### 4.2 The live run cannot finish on this host: an AudioToolbox abort

With the transport fixed the call comes up and signalling works, but **the process is killed ~5 s
later by Apple's audio stack**, which is what stops the last two live assertions (the reverse
`user_muted` direction, and `Leave` ending the call on the server). Captured with lldb attached to
the running app (`~/Library/Logs/mmios-t44d-lldb2.txt`), abridged:

```
* thread #16, name = 'worker_thread', stop reason = signal SIGABRT
  frame #2: libsystem_c.dylib`abort + 104
  frame #3: AudioToolboxCore`_ReportRPCTimeout(char const*, int) + 120
  frame #4: AudioToolboxCore`_CheckRPCError(...)
  frame #5: libEmbeddedSystemAUs.dylib`AURemoteIO::Initialize() + 1924
  frame #8: AudioToolboxCore`AudioUnitInitialize + 128
  frame #9..: WebRTC … (the audio device module starting its RemoteIO unit)

  thread #8  queue='com.apple.root.default-qos': UISoundNewRenderer → CA_UISoundClientBase
             → AQIONodeManager::_FindAQIONode → … HALC_ProxyObject::SetPropertyData (blocked)
  thread #10 queue='AudioControl': AURemoteIO_server → RemoteIOClient::ConnectToDevice
             → AQIONodeManager::_FindAQIONode (blocked on the same unfair lock)
```

i.e. a UI-sound client and the app's remote-IO unit deadlock on an Apple-internal lock
(`AQIONodeManager`), the audio-server RPC times out, and AudioToolbox **aborts the process by
design** (`_ReportRPCTimeout`). Nothing in that stack is this repository's code: our audio work is
`RTCAudioSession` category/mode/activation plus libwebrtc's own device module.

What was tried, and what it changed (all measured, none of it silent):

1. `useManualAudio = false` → `true`, so the app owns activation instead of the ADM activating on
   top of it (this is also what react-native-webrtc does). No change to the abort; kept, because it
   is the correct ownership model and removed a double activation.
2. Activation **before** enabling audio (`setCategory` → `setActive(true)` → `isAudioEnabled = true`),
   and `.allowBluetooth` without the mutually-exclusive `.allowBluetoothA2DP`. No change; kept, same
   reason (the pair is documented as exclusive, and starting the ADM against an inactive session is
   a second way into the same stall).
3. Teardown order: stop the audio unit (`isAudioEnabled = false` / track disabled) **before**
   releasing the peer connection and factory. No change to the abort; kept — deactivating a session
   whose audio-unit owner is already gone is wrong on its own terms.

The abort is identical in shape at leave and at unmute (both first touch the ADM's input unit), so
it is not a teardown bug and not a surface bug: it is this simulator/host's audio stack. The `-AV`
card must not rely on this host for the two surviving assertions; a device run, or a simulator on a
host without the audio-server contention, is where they have to be taken.

## 5. Deliberately not in this card

* Remote audio actually playing (T44b/T44c media path; the surface states what the engine reports) —
  and see §4.2 for why a live audio unit could not be exercised here at all.
* A second participant's tile **from the wire**: needs a second WebRTC peer offering SDP from the
  test process. Participant deltas are unit-tested from measured frames and folded by the engine;
  the peer oracle belongs to the `-AV` pass.
* Screen share and camera (reasons above).
* Host controls (mute-all, remove participant): the surface shows who the host is; the actions need
  the plugin's host-only actions and an `-AV` decision about who may use them.

## 6. Files

New: `Mattermost/UI/Native/Calls/{CallsSurfaceModels,CallsCallModel,CallsCoordinator,CallsSurfaceView,CallsJoinEntry,CallsAPI,CallsSurfaceService}.swift`,
`MattermostTests/T44DCalls{Surface,Coordinator,API}Tests.swift`,
`MattermostTests/T44DSocketBinarySendTests.swift`, `MattermostUITests/T44DCallsUITests.swift`,
`docs/t44d-shots/t44d-01-in-call.png`, `docs/t44d-shots/t44d-02-unmuted.png`.

Changed: `Mattermost/Core/MM/SocketEvent.swift` (`send(data:)` is a protocol requirement, §4.1),
`Mattermost/Core/Calls/CallsEngine.swift` (delta folding, §4.1; teardown order, §4.2),
`Mattermost/Core/Calls/CallsAudioSession.swift` (manual audio, activation order, §4.2),
`Mattermost/Core/Calls/CallsProtocol.swift` (event names → measured; canonical spelling),
`Mattermost/Core/Calls/CallsEvents.swift` (measured hand names; `channelID` on participation deltas),
`Mattermost/Core/Calls/CallsModels.swift` (`raisedHandAt`), `APIClient.swift` + `MMBaseURL.swift`
(`getPlugin`/plugin routes), `TeamSidebarCoordinator.swift` (`callsTransport`), `MattermostApp.swift`,
`ChannelView.swift`, `MattermostTests/T44CCallsEventTests.swift` (measured names + channel),
`MattermostTests/T44CCallsEngineTests.swift` (4 folding tests).
