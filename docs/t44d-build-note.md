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

## 3. Rules the unit suite pins (39 T44d tests + 4 engine tests)

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
  peer-test skips** (`MM_CALLS_PEER_TESTS` not set); this closing pass changed no product code (only
  the live suite's own assertion/attachment and these docs), so that result stands. The whole
  `MattermostTests` suite at the pushed SHA (`41e0e06`) was 1596 run / 7 skipped / 0 failed in this
  card's rework run.
* Live: `MattermostUITests/T44DCallsUITests` on `iPhone 16 Pro` (iOS 18.3) against the real fixture
  (`127.0.0.1:8065`, Calls plugin **0.29.8** build `936dd00`), channel `#t44-calls`, launched with
  `-surfaceMode calls=native`. **Two consecutive full-suite runs, both green:**

  | run | log | started | result |
  |---|---|---|---|
  | 3 | `build/logs/t44d-run3.log` | 2026-10-27 09:53:23 | `Executed 2 tests, with 0 failures (0 unexpected)` in 82.350 s |
  | 5 | `build/logs/t44d-run5.log` | 2026-10-27 09:57:32 | `Executed 2 tests, with 0 failures (0 unexpected)` in 81.250 s |

  What they assert, end to end: the channel header offers `calls.joinButton` (value `idle`, label
  `Start call`) → tapping it mounts `callsSurface` → the reader's own tile `calls.tile.<userID>` reads
  `Perf Probe (you)` with the mute icon and the host crown → the state line reaches **`In call`** →
  `GET …/calls/{id}/active` answers `{"active":true}` → **`Leave`** dismisses the surface **and** the
  plugin reports `{"active":false}`. The mute test additionally drives `calls.muteButton`
  (`muted` → `unmuted` → `muted`) and requires a **second socket of the same account** to see
  `user_unmuted` **and then** `user_muted` for that channel and user id, and the control to still read
  `muted` 3 s later, so the engine's next snapshot cannot revert a server-confirmed mute.
* Screenshots from those runs, in `docs/t44d-shots/`: `t44d-01-in-call.png` and `t44d-02-unmuted.png`
  (earlier run, same fixture), `t44d-03-in-call-green-run.png` (run 5: header `t44-calls`,
  `In call 00:02`, own tile with the mute icon and the host crown, `Unmute` / `Raise hand` / `Leave`)
  and **`t44d-04-muted-after-roundtrip.png`** (run 5, taken after the server confirmed `user_muted`:
  the same call at `00:05`, tile mic crossed out, the control reading `Unmute`). All four are exports
  of the runs' own `XCTAttachment`s against the fixture — no fixture-free mock-ups.
* The audio path really ran in both green runs: the simulator's own log shows its audio device up and
  reconfiguring around join and leave for **all four** app processes —
  `Mattermost[<pid>] (AudioToolbox) iOSSimulatorAudioDevice-<pid>-1: Abandoning I/O cycle because
  reconfig pending`, at 09:53:59 / 09:54:05 (pid 54421), 09:54:42 / 09:54:45 (54964),
  09:58:07 / 09:58:12 (57429), 09:58:48 / 09:58:51 (57899). Neither run wrote a crash report.

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

### 4.2 The AudioToolbox abort: a host-contention failure mode, recognised and no longer open

Between 05:50 and 06:46 on 2026-10-27 the live suite was killed four times by Apple's audio stack
before its last two assertions could be taken. That history is kept here because it is a real failure
mode of *this host*, and the `-AV` card must recognise it instead of chasing it as a mute bug.

Signature (crash report `~/Library/Logs/DiagnosticReports/Mattermost-2026-10-27-064552.ips`, lldb
`~/Library/Logs/mmios-t44d-lldb2.txt`):

```
thread #16 worker_thread   AURemoteIO::Initialize → _ReportRPCTimeout → abort      libwebrtc's ADM
                                                                                  starting the unit
thread #10 'AudioControl'  AURemoteIO_server → RemoteIOClient::ConnectToDevice
                           → AQIONodeManager::_FindAQIONode                       blocked on its lock
thread #8  default-qos     AQIONodeManager::StartImmortalDeviceRunner → UISoundNewRenderer
                           → CA_UISoundClientBase → HALC_ProxyObject::SetPropertyData
                           → mach_msg                                             simulator audio HAL
```

i.e. **a UIKit UI-sound device runner was inside an audio-HAL call that never returned**, so the audio
server could not find a node for libwebrtc's remote-IO unit, its 10 s RPC check expired, and
AudioToolbox **aborted the process by design** (`_ReportRPCTimeout`). Nothing in that stack is this
repository's code: our audio work is `RTCAudioSession` category/mode/activation plus libwebrtc's own
device module.

What was tried while it was failing — kept where each is right on its own terms, none of them the cure:
manual audio (`useManualAudio = true`, the react-native-webrtc ownership model), activation before
`isAudioEnabled = true`, `[.allowBluetooth]` without the mutually exclusive `.allowBluetoothA2DP`,
teardown order (unit stopped before the peer connection is released), UI-sound defaults disabled on
host and simulator, and shutting down the second booted simulator.

What actually differed in the green runs: **the host was otherwise idle and only one simulator was
booted.** All four aborts happened at host load 60–92 with T34's UI suite running and two simulators
holding audio clients; both green runs happened after T34 released the host (load ≈ 4.5, one booted
device — `vm.swapusage` was ≈ 7.5 GB used in *both* states, so swap alone is not the discriminator).
**No product code changed between the last abort and the first green run**: the difference is
`build/logs/t44d-final.log` (failing) against `t44d-run3.log` / `t44d-run5.log` (green) at the same
commit, which is why this is recorded as host contention rather than a Calls defect.

For the `-AV` card: run this suite **alone** on a quiet host (T34 finished, one simulator booted), and
read a vanished process as this signature, not as a mute failure — the suite now says so itself:

```swift
XCTAssertEqual(app.state, .runningForeground,
               "the app must still be running after the mute round trip — a dead process here is "
               + "the AudioToolbox abort in docs/t44d-build-note.md §4.2, not a mute failure")
```

If it does abort again, the useful ladder is, cheapest first: (1) keep `RTCAudioSession` active across
the call instead of deactivating at teardown, so no UI-sound or AudioQueue client can grab the
`AQIONode` mid-call; (2) identify the in-process client that owns the `AQMEIO` renderer (a live
WKWebView UI-sound renderer is the prime suspect while a webview surface is still mounted) and stop it
for the call's duration; (3) only then host level (a reboot to clear a wedged HAL). Recorded so the
next attempt starts from evidence instead of from zero.

## 5. Deliberately not in this card

* Remote audio *heard by a human* (the T44b/T44c media path is measured at the packet level, and §4
  above shows the app's audio device running; what this card does not do is listen to it).
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
`docs/t44d-shots/{t44d-01-in-call,t44d-02-unmuted,t44d-03-in-call-green-run,t44d-04-muted-after-roundtrip}.png`

Changed: `Mattermost/Core/MM/SocketEvent.swift` (`send(data:)` is a protocol requirement, §4.1),
`Mattermost/Core/Calls/CallsEngine.swift` (delta folding, §4.1; teardown order, §4.2),
`Mattermost/Core/Calls/CallsAudioSession.swift` (manual audio, activation order, §4.2),
`Mattermost/Core/Calls/CallsProtocol.swift` (event names → measured; canonical spelling),
`Mattermost/Core/Calls/CallsEvents.swift` (measured hand names; `channelID` on participation deltas),
`Mattermost/Core/Calls/CallsModels.swift` (`raisedHandAt`), `APIClient.swift` + `MMBaseURL.swift`
(`getPlugin`/plugin routes), `TeamSidebarCoordinator.swift` (`callsTransport`), `MattermostApp.swift`,
`ChannelView.swift`, `MattermostTests/T44CCallsEventTests.swift` (measured names + channel),
`MattermostTests/T44CCallsEngineTests.swift` (4 folding tests).

## 7. T44d-AV — the adversarial pass (`t_466e8e90`, 2026-10-27)

Re-derived from `origin/main` `a96bde02` in a **detached worktree** (the shared checkout had another
worker's uncommitted `ChannelView`/`ScrollRestoreRunner` edits), with a **never-built** derived-data
path (`~/Library/Developer/Xcode/DerivedData/mmios-t44d-av-units`; the GRDB submodule cannot be
fetched offline, so `SourcePackages/` was copied from the existing cache — build products were not
reused). Verdict: **PASS-WITH-FINDINGS**. Findings, and what the pass added, are below.

### 7.1 Unit suite (Mac Catalyst), copied from the runner's own output

```
Executed 1596 tests, with 7 tests skipped and 0 failures (0 unexpected) in 45.480 (55.456) seconds
** TEST SUCCEEDED **
  T44DCallsSurfaceTests      14 run, 0 failed
  T44DCallsCoordinatorTests  17 run, 0 failed
  T44DCallsAPITests           5 run, 0 failed
  T44DSocketBinarySendTests   3 run, 0 failed
  T44CCallsEngineTests       18 run, 3 skipped (peer-negotiation, MM_CALLS_PEER_TESTS unset), 0 failed
```

Log: `build/logs/t44d-av-units.log`. The 39 T44d tests listed in §3 are 14+17+5+3 — the earlier
"40" in this note and in `docs/parity.md` was arithmetic, corrected here.

### 7.2 The two fixes bite (mutation-tested, not taken on trust)

* **`send(data:)` as a protocol requirement.** Removed the requirement from
  `SocketTransport` (`Mattermost/Core/MM/SocketEvent.swift`), re-ran the class:
  `tests: 3 run, 0 skipped, 1 failed` — `testBinaryFrameReachesTheTransportThatImplementsSendData`
  fails with `caught error: "binaryFramesUnsupported"` (the live error, reproduced). Restored the
  line and re-ran: `3 run, 0 skipped, 0 failed`. Logs: `build/logs/t44d-av-mutationA.log`,
  `t44d-av-mutationA-restored.log`.
* **`CallsEngine.fold(_:)`.** Neutered the fold body (`return` before the switch) and re-ran the
  engine class: `18 run, 3 skipped, 3 failed` — `testAConfirmedUnmuteSurvivesTheNextSnapshot`
  (`user_unmuted` never reaches `snapshot.call`), `testUserJoinedAndLeftMoveTheSessions`,
  `testRaisedHandAndHostChangeAreFolded`. Restored: `18 run, 3 skipped, 0 failed`
  (`build/logs/t44d-av-mutationB.log`, `t44d-av-mutationB-restored.log`).
  Note, for the next reader: the fourth case, `testADeltaForAnotherChannelIsNotFolded`, passes under
  a full fold removal by construction (it asserts a delta is *not* applied), so it is a guard against
  the wrong thing being folded, not evidence that folding happens. Three of the four bite.

### 7.3 Live suite, re-run independently (the §4.2 abort did not recur)

```
python3 scripts/qa-test.py --platform ios --sim id=81A7F251-… --only-testing MattermostUITests/T44DCallsUITests \
  --derived-data ~/Library/Developer/Xcode/DerivedData/mmios-t44d-av-units   (TEST_RUNNER_MM_AUTH_* set, perfprobe)
Executed 2 tests, with 0 failures (0 unexpected) in 88.762 (88.765) seconds
** TEST SUCCEEDED **
  testMuteSurvivesTheSnapshotAndLeaveEndsTheCall  passed (47.814 s)
  testStartCallCreatesTheCallOnTheServerAndLeaveEndsIt passed (40.948 s)
```

Log: `build/logs/t44d-av-live1.log` (attachments `01-header-start`, `02-surface-joining`,
`03-surface-In-call`, `04-after-leave`, `05-unmuted`, `06-muted-after-roundtrip`; no new Mattermost
crash report). Host at start: load 119/158/120, one simulator booted, another worker's
`xcodebuild test` started during the run — so this pass does **not** reproduce the "quiet host only"
story from §4.2; the abort did not recur, and the suite's own assertions (both `user_unmuted` **and**
`user_muted` on a second socket, `app.state == .runningForeground`, `Leave` dismissing the surface)
all ran, because a skipped test prints `skipped`, not `passed`. Independent server-side check after
the run (`GET /plugins/com.mattermost.calls/calls/{channel}/active`): `{"active": false}` — the
UI-driven Leave ended the call on the plugin.

### 7.4 Registry flip (separate commit, `t_466e8e90`)

`.calls` is now in `SurfaceDefaults.nativeApprovedSurfaces`. The flip is **not** a one-line diff: four
assertions in two test files encode the registry's contents and the "canonical unapproved surface"
(`ViewStoreTests.testEmptyRegistriesMakeReleaseUnreachable`; `SurfaceModeResolverTests`
`testOnlyTheApprovedRegistryDefaultsToNative`, and two cases that used `.calls` as the example of a
surface falling through to the compile-time default — those now use `.threads`, which is still
unapproved). Measured, by running the **pre-flip** test files against the flipped registry (`git
checkout a96bde0 -- MattermostTests/ViewStoreTests.swift MattermostTests/SurfaceModeResolverTests.swift`,
run, revert): all four fail and name the reason — `("[Mattermost.Surface.auth, Mattermost.Surface.calls]")
is not equal to ("[Mattermost.Surface.auth]") — T31-AV approved `.auth` and nothing else`, plus
`("native") is not equal to ("web")` twice (`build/logs/t44d-av-flip-red-oldtests.log`: 46 run,
4 failed). With the four updated the whole suite is green: **1603 run, 7 skipped, 0 failed, `** TEST
SUCCEEDED **`** (`build/logs/t44d-av-units-rebased.log` — the commit as pushed, rebased onto
`389516d`; re-run on the remote tip after T34's `f02467f` landed: **1614 run, 7 skipped, 0 failed**,
`build/logs/t44d-av-units-tip.log`). The first post-flip attempt had fixed only the two registry lists and not the two
`.calls`-as-example cases, and showed exactly those two failures
(`build/logs/t44d-av-units-postflip.log`: 1596 run, 2 failed). **Reachability caveat**, measured in source:
the entry point (`CallsJoinEntry`) is drawn by `NativeChannelPaneView`, so it only appears when the
pane host `SurfaceDefaults.paneHostSurface` (`.channelView`) resolves `native` — and that surface is
**not** approved, so a shipping build still renders the web app and the web client's Calls. The flip
is the correct registry state; it is not a user-visible change until the pane is approved, and screen
share stays web-only until T44e.

Proof of the flip, as the card asks — a run with **no `-surfaceMode calls=native` flag**
(`build/logs/t44d-av-flip-proof.log`; the proof test itself is not committed):

```
xcodebuild test … -only-testing MattermostUITests/T44DAVFlipProofUITests   (shell=native, no calls flag)
Executed 1 test, with 0 failures (0 unexpected) in 18.963 seconds
** TEST SUCCEEDED **
  calls.joinButton exists, value "idle"   (attachment `flip-proof-calls-entry`)
```

`scripts/verify-dual-render-gates.sh --allow-approved-registry` → `RESULT: PASS — dual-render debug
affordances cannot reach a Release build` (`nativeApprovedSurfaces` reads `[.auth, .calls]`).

### 7.5 Findings that stay open (each with the command that reproduces it)

1. **Camera control absent** although the card's scope line names it. Deliberate and documented
   (§5, `CallsControlSet.showsCamera == false`, `CallsVideoCapability.unsupported`): 0.29.8 has no
   `video_on`/`video_off` and the engine captures no video, so a button would be inert. Not a defect;
   it is a scope deviation a reader of the card text must be told about.
2. **Reachability** (§7.4) — `.calls` native-by-default has no user-visible effect until
   `.channelView` is approved; recorded in `docs/parity.md` and `docs/dual-render.md` §4 now.
3. **Test-count arithmetic**: 39, not 40 (corrected).
4. **`testADeltaForAnotherChannelIsNotFolded` is vacuous under fold removal** (§7.2).
5. **A second participant's tile from a real peer** and **remote audio arriving** are still not
   rendered from the wire: §5 lists both; the live oracle here is the reader's own tile plus the
   plugin's broadcasts.
