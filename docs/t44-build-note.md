# T44 — native Calls (WebRTC): the P1 gate, measured, and why `calls` stays on the webview

Card: **T44** (`t_a3383222`). Spike of record: `docs/t44a-calls-spike.md` (T44a, `t_0845e828` —
landed on `main` by this card, see §7). Parity row: `docs/parity.md` (T44). Pin: `docs/dual-render.md`
§4 (`calls` → `web`, reason). Date: 2026-10-27. Host: MacBook-Pro-5.local, macOS 26.3.1, Xcode 26.6.
Server: the programme fixture, `mattermost/mattermost-team-edition:release-9` (9.11.19),
**Calls plugin 0.29.8, build `936dd00d3e456c843b846740aa76601d07e6a25a`**, container `mm-perf`.

## 1. Verdict

**`calls` stays `web`. No native Calls code ships in this card.** `SurfaceDefaults.nativeApprovedSurfaces`
is unchanged (`[.auth]`), so the surface resolves `web` exactly as before.

That is not "we could not be bothered": §4 proves the signalling contract end to end against a real
plugin (join, call state, SDP offer/answer, ICE trickle) and §4.6 measures that **the media leg
cannot be established by any client on this fixture** because the SFU's ICE port is published
nowhere on the host. §6 lists the four things a native `calls` surface would still owe that this
programme has not got: a bidirectional-audio measurement it can actually run, a screen-share
extension target, a recorded licence position for the AGPL/source-available plugin, and a surface
card that owns its own `-AV` gate. The engine is *not* the blocker — the spike's memory measurement
stands (§3).

The card's own escape hatch applies: **"If any answer is no, close this card as 'stays on webview'
with the evidence — that is a legitimate outcome, not a failure."** The answer that is "no" is not
"can a library be vendored" (yes) and not "is signalling documented" (yes — measured); it is "can a
native client's media path be verified in this programme today" (no) — and, independently, that a
native surface without screen share is a parity regression (§3.2).

## 2. What the card asked for, and what already existed

The card's *mandatory first step* was a spike note with real build output, answering three
questions: which WebRTC library can be vendored, does it build for Catalyst + iOS on this machine,
and is Calls' signalling documented well enough to interoperate. T44a (`t_0845e828`) answered all
three and its note has been **carried onto `main` by this card** (it was written on
`wt/t_0845e828` and never merged, so until now the evidence this card's acceptance criteria point
at was not in the tree the validators audit — §7).

T44a's answers, still standing:

| question | answer | where it was proven |
|---|---|---|
| vendorable engine? | `stasel/WebRTC` 137.0.0, binary xcframework, SHA-256 `9b45c5c5…c3edd`; SwiftPM `binaryTarget(url:)` hangs on this host, so it must be a committed vendor drop | spike §1, §3 |
| builds for both destinations? | iOS Simulator `** BUILD SUCCEEDED **`, Mac Catalyst `** BUILD SUCCEEDED **` (`--platform ios --environment macabi`) | spike §2, `docs/t44a-*.log` |
| signalling interoperable? | core `/api/v4/websocket`, `custom_com.mattermost.calls_*`; **this card closes the last gap in that answer** (§4) | spike §4 + §4 here |
| memory | engine floor 11.6–15.2 MB RSS vs 460.7/562.1 MB for one loaded webview (T27) | spike §5 |

## 3. The two obligations folded in from the retired T15/T16

The board asked for these to be answered here rather than in new cards.

### 3.1 Capture permissions — the `Info.plist` strings are necessary, not sufficient

`Mattermost/Info.plist` already carries `NSCameraUsageDescription`/`NSMicrophoneUsageDescription`
(added for the webview's `getUserMedia`). A native engine additionally needs, and today does not
have:

* a **runtime** `AVCaptureDevice.requestAccess(for: .audio/.video)` before the engine starts — WebRTC
  does not prompt for you, and a denied grant has to become a visible "no mic/camera" state instead of
  a black tile;
* **ownership of `AVAudioSession`** (`.playAndRecord` / `.voiceChat`, route changes), which WebKit
  owns today. `RTCAudioSession` exists for exactly this;
* **`audio` in `UIBackgroundModes`** — `Info.plist` currently has `["fetch"]` (verified: `PlistBuddy
  -c "Print :UIBackgroundModes"` → `fetch`). Without it a call drops the moment the app backgrounds;
* a **Catalyst entitlement** answer for App Store distribution (`com.apple.security.device.camera`,
  `…audio-input`) — the Catalyst build runs with the sandbox off (T20), so nothing is needed today;
* a rewrite of `Mattermost/PrivacyInfo.xcprivacy` ("Audio Data / Photos or Videos: web-app Calls
  only") and of `docs/app-store-review-notes.md`, neither of which is true any more once the app
  captures directly.

So: **strings sufficient for the webview's `getUserMedia`; not sufficient for a native engine.**

### 3.2 Screen share — yes, it needs a Broadcast Upload Extension, so it rides the webview

iOS has no `getDisplayMedia`. Capturing *other apps* is ReplayKit's system-broadcast flow, which
means `RPSystemBroadcastPickerView` plus a **second target** — an `RPBroadcastSampleHandler`
app-extension with its own bundle id, provisioning profile, App Group, extension memory ceiling and
its own App Review submission. It compiles on both destinations this app ships (T44a probe
`probe-replaykit`: `** BUILD SUCCEEDED **` for iOS Simulator *and* Catalyst — the picker is not
`API_UNAVAILABLE(maccatalyst)`), but whether any broadcast service exists to drive on Catalyst is
unverified.

The official mobile client does not ship screen share at all (T44a §4.7: no broadcast-extension
target in `mattermost-mobile`'s `ios/`, no control in its call screen). Since this card's scope is
"join/leave, participant tiles, mute/camera/**screen-share** controls", a native surface without the
extension is a **parity regression against the webview**, not a port of it. **While `calls` renders
`web`, screen share works exactly as it works today — inside the webview** (the web app's own
`getDisplayMedia` path). That is the answer the retired T16 asked for.

### 3.3 What the pin does not break: the webview's Calls UI still loads

`calls` renders the webview, so what matters is that the server's web app still gets the Calls
plugin's browser bundle. Measured on the fixture:

```
GET /api/v4/plugins/webapp
  -> com.mattermost.calls 0.29.8,
     bundle_path "/static/com.mattermost.calls/com.mattermost.calls_cb1190574ced076e_bundle.js"
GET /static/plugins/com.mattermost.calls/com.mattermost.calls_cb1190574ced076e_bundle.js
  -> 200, 3,889,462 bytes
```

(the manifest's path is relative: the server serves the bundle a segment deeper, at
`/static/plugins/<plugin id>/<file>`, which is what the web app requests). The plugin also ships its
standalone bundles (`standalone/dist/widget.…js`, `…recording.…js`). So the webview keeps the
channel-header call button, the expanded call view and screen share — unchanged by this card. **And
its media leg is broken on this fixture for the same reason a native one would be** (§4.2): the pin
is not a regression, and "Calls works in the webview" on this server is a statement about the UI only.

## 4. What was measured today: the P1 gate, against the live plugin

`scripts/t44_calls_probe.py` is new, committed, and re-runnable. It speaks the core
`/api/v4/websocket` from outside the app (the app's socket is Swift; the stdlib has no WebSocket
client, so the probe carries a 120-line RFC6455 client and a 40-line MessagePack encoder), joins a
real call, offers, and then probes every ICE candidate the server advertises.

```
python3 scripts/t44_calls_probe.py --url http://127.0.0.1:8065
```

Full output: `docs/t44-calls-probe-2026-10-27.log`. **8 PASS / 0 FAIL**:

| # | check | result |
|---|---|---|
| 1 | the plugin answers `/version` | PASS — 0.29.8, build `936dd00…` |
| 2 | the plugin allows calls to be enabled | PASS — `AllowEnableCalls=true`, sku `starter`, test mode off, `MaxCallParticipants=0` |
| 3 | a **JSON text frame** joins the call | PASS — `join` ack carries `connID` |
| 4 | the join is followed by a full `call_state` | PASS — session `{session_id, user_id, unmuted, raised_hand}` |
| 5 | a JSON-framed `sdp` is **not** answered | PASS (negative) — 0 `signal` events |
| 6 | a **MessagePack** `sdp` frame is answered | PASS — 481-byte answer from the SFU |
| 7 | the SFU trickles ICE candidates | PASS — 5 candidates |
| 8 | the client is the offerer | PASS — no offer, no answer |

and then the part that decides the card:

```
DATA  stun binding to 127.0.0.1:8443  —  no reply (2.0 s)
DATA  stun binding to 64.251.85.226:8443  —  no reply (2.0 s)
DATA  stun binding to 209.35.187.178:53080  —  no reply (2.0 s)
DATA  control: a public STUN server answers from this host  —  yes
MEDIA PATH: 0/3 advertised UDP candidate(s) reachable from this host — media cannot flow here
```

### 4.1 What the exchange actually looks like

Server events, in order, for one join (`docs/t44-calls-probe-2026-10-27.log` and the earlier raw
capture): `call_host_changed` → `call_start` `{id, post_id, thread_id, start_at, owner_id, host_id}`
→ `join {connID}` → `user_connected` → `user_joined {user_id, session_id}` → `call_state
{channel_id, call: <JSON **string**>}`. The call state is exactly the model a native calls UI needs
(`sessions[]` with `session_id/user_id/unmuted/raised_hand`, `screen_sharing_session_id`, `owner_id`,
`host_id`, `thread_id`, `post_id`).

Client actions: `join {channelID, title?, threadID?, jobID?}` (note the key is `channelID`, not
`channel_id`), `leave`, `reconnect`, `sdp {data: <zlib'd JSON description>}`, `ice {data: <JSON
candidate>}`, `mute`/`unmute`, `voice_on`/`voice_off`, `screen_on`/`screen_off`, `raise_hand`/
`unraise_hand`, `react`, `caption`, `metric`, `call_state`. v1.x adds `video_on`/`video_off`; the
installed 0.29.8 does not have them (`server/client_message.go` at `936dd00` vs `6b65e3b`).

### 4.2 Why media cannot flow on this fixture (and what would change it)

The plugin is an **SFU**: `activate.go` starts `rtc.NewServer(...)` with `ICEPortUDP =
*cfg.UDPServerPort`, `websocket.go` sends every client SDP/ICE to it, and the SFU's own candidates
come back as `signal` events. That server is the plugin process, inside the `mm-perf` container on
`mm-perf-net` (172.19.0.3), and the container publishes **only 8065/tcp**. `/proc/net/udp` inside the
container shows the ICE listener bound on `172.19.0.3:8443`; from the host, all three advertised UDP
candidates time out while the control STUN server answers. Full evidence, including the remedy
(UDP relay sidecar + `ICEHostOverride`), is in `docs/t44-calls-media-path-2026-10-27.log`.

Stated plainly: **no client — native or web, on this host or on a device — can carry Calls media
against this fixture.** Signalling completes, ICE never connects. A "bidirectional audio" acceptance
criterion is therefore not measurable here by anyone, in any implementation, and an unmeasurable
criterion cannot be approved.

> **Amended 2026-10-27 by T44b (`t_7b826839`) — see `docs/t44b-calls-media-path.md`.** Two of the
> statements above are wrong, and the third is now fixed on the fixture:
>
> 1. The reachability measurement could not have answered the question. The SFU demultiplexes every
>    session with a ufrag mux (`webrtc.NewICEUDPMux`) that routes by the STUN `USERNAME` attribute, so
>    a **bare** binding request is dropped whether the port is open or shut — with the port published
>    and the agent answering, the old check still printed `0/3`. And it ran *after* `leave`, when the
>    SFU has already torn the ICE agent down. `scripts/t44_calls_probe.py` now sends a credentialed
>    binding request (`USERNAME`, `MESSAGE-INTEGRITY`, `PRIORITY`, `ICE-CONTROLLING`, `FINGERPRINT`)
>    from inside the live session — the way a real ICE agent does — and a binding *error* counts as a
>    reply, because it means an agent saw the packet.
> 2. The port is published now: `docker run -d --name mm-calls-udp --network mm-perf-net -p
>    127.0.0.1:8443:8443/udp alpine/socat:latest UDP4-LISTEN:8443,fork,reuseaddr UDP4:mm-perf:8443`
>    (revert: `docker rm -f mm-calls-udp`). Probe with the relay: `MEDIA PATH: 1/3`, with
>    `binding success … message-integrity=True mapped=172.19.0.4:<port>`; without it, `0/3`.
> 3. `ICEHostOverride=127.0.0.1` is **not** part of the fix on this build — with it set (and the
>    plugin restarted) the SFU stops answering the relayed path entirely. It is cleared on the
>    fixture and documented there.
>
> And the criterion is now measured, not just unblocked: `scripts/t44b_rtp_spike.js` drives two
> sessions of the fixture account in a browser on the server's origin, each sending synthetic opus;
> `getStats()` shows `outbound-rtp` +405/+404 packets and `inbound-rtp` +179/+213 packets with
> **+388,800 decoded samples** and non-zero `totalAudioEnergy` on **both** sides, over the selected
> pair `127.0.0.1:8443/udp`. Bidirectional audio is measurable on this host as of T44b. The receive
> side is lossy (~50% of the forwarded packets, `packetsLost=0` while ~55% of samples are
> concealment) — carried into T44c as an open question, with the isolation experiment named there.

## 5. Three corrections to the T44a spike (each measured, none of them cosmetic)

1. **"A native client may use plain JSON" is wrong for the `sdp` action.** The spike (§4.2) read the
   core server's ability to accept JSON text frames and concluded the T28 `SocketClient` could be
   reused as-is. It cannot: the plugin type-asserts the SDP payload to `[]byte`
   (`server/websocket.go:1226` at `936dd00`, `:1350` at `6b65e3b` — both versions), and the core
   server's JSON decoder produces a `string`, so the frame is dropped with the server-side log
   `{"level":"error","msg":"invalid or missing sdp data","origin":"…WebSocketMessageHasBeenPosted
   websocket.go:1226"}` and the session dies at the 10 s signalling timeout. Measured as probe checks
   5 and 6. Consequence for a future implementation: the socket needs a **binary** send path and a
   MessagePack encoder for this one frame, plus **zlib** framing of the SDP
   (`unpackSDPData` → `zlib.NewReader`). ICE, by contrast, *is* a JSON string and works over a text
   frame.
2. **The client is the offerer.** The spike's §4.4 message list implies a server-driven SDP exchange.
   In the real plugin the SFU never offers: `calls-common`'s `RTCPeer` emits a local offer from
   `onNegotiationNeeded` (when the first track is added) and the SFU answers
   (`rtc_peer.ts:136-142`, `:196-198` at the plugin's pinned `e463e78`). A client that never offers
   is torn down after ~10 s. Measured: probe check 8.
3. **The spike's protocol was read from `v1.12.6`; the server this programme actually tests against
   runs `0.29.8`.** They differ where it matters for a client (no `video_on`/`video_off` in 0.29.8;
   the 1.x REST surface has routes 0.29.8 does not). A client implementation must be written against
   the behaviour both versions share — join/leave/sdp/ice/mute/unmute/raise-hand/screen/call_state,
   which is what §4.1 lists — and version-gate the additions.

The spike's *memory* and *library* conclusions are unaffected by any of this.

## 6. The decision, and what it rests on

`calls` stays `web` (`Mattermost/Core/RenderMode.swift:92`, `nativeApprovedSurfaces = [.auth]`; the
resolver defaults every unapproved surface to `web`). The reason is now written where the validator
looks for it (`docs/dual-render.md` §4) and is these four facts, in order of weight:

1. **Screen share would regress** (§3.2). The webview gives ReplayKit-free screen share today for
   free; a native surface needs a second app-extension target that this programme has not built.
2. **The media path cannot be verified here** (§4.2), so the card's own "bidirectional audio on a
   real server" criterion is unmeetable as things stand — for this card and for any successor
   card until the fixture publishes the SFU's ICE port. *(T44b has since published it and measured
   bidirectional opus — `docs/t44b-calls-media-path.md` — so this reason no longer holds; the pin
   keeps the remaining three.)*
3. **The licence position is not recorded.** The Calls plugin's source is AGPL-3.0-or-commercial
   (plus a source-available enterprise licence); `mattermost-mobile` (Apache-2.0) is the clean
   reference, and the spike already says a native client must be an independent implementation of
   the protocol with a recorded sign-off before it ships. That sign-off does not exist.
4. **It is a surface card's worth of UI with no owner yet** — participant tiles, mute/camera/hand,
   host controls, ringing, the `-AV` pair. Doing it in this card would have been the "one giant
   card" the T44a spike explicitly recommended splitting.

What is **not** claimed: that native Calls is impossible or that memory makes it pointless. The
engine is cheap (11.6–15.2 MB against a 460–562 MB webview) and the signalling is now
conformance-tested. The blocker is verification and parity, not feasibility.

## 7. What changed in the tree

* `docs/t44a-calls-spike.md` + its seven logs: **brought onto `main`** (cherry-picked from
  `wt/t_0845e828`, commits `e3620b8`/`f27a9d7`, docs only), plus a dated §10 appended recording §5's
  three corrections and §4's gate result. Before this card the note this card's acceptance criteria
  cite existed only on a side branch.
* `scripts/t44_calls_probe.py` — new. The conformance probe: 8 contract checks + candidate
  reachability, `--json` for machines, exit 0 iff the contract holds.
* `docs/t44-calls-probe-2026-10-27.log`, `docs/t44-calls-media-path-2026-10-27.log` — its output and
  the container/STUN evidence.
* `docs/dual-render.md` §4 — the `calls` row now carries the pin and the reason.
* `docs/parity.md` — the T44 row (S33 Calls stays `webview`; what was learned; what a native card
  would owe).
* `docs/component-map.md` §S33 — a pointer to the pin decision so a future card does not start from
  "port S33" without reading §6's four facts.

No Swift app file is touched. `SurfaceMode` is unchanged, so the app builds and its surfaces resolve
exactly as before; the Catalyst suite is re-run below to prove it.

### 7.1 The suite, re-run (nothing regressed)

```
xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/t44-catalyst \
  -only-testing:MattermostTests
...
 Executed 1489 tests, with 4 tests skipped and 0 failures (0 unexpected) in 61.830 (62.698) seconds
** TEST SUCCEEDED **
```

`build/logs/t44-catalyst-units.log` — 1489 run / 4 skipped / 0 failed, the same counts T43-R reported
at `e6f5637`, which is the expected result for a docs-and-scripts commit. The 4 skips are the
pre-existing ones (no APNs on this host).

## 8. Limits that stay (stated, not hidden)

* The fixture cannot carry Calls media (§4.2). Nothing in this card fixes that; the remedy is
  written down and is a change to a **shared** container, not to the app.
* The probe verifies **signalling**, not media. There is no bidirectional-audio measurement in this
  card, and none is claimed.
* Everything about capture permissions (§3.1) is a *requirement list*, not a measurement: no native
  engine was started, so nothing here proves what a denied mic grant looks like.
* Screen share on Catalyst is unverified (T44a P3), and a native screen-share path would need its own
  card even after the extension exists.
* The probe's call sessions create a "started a call" post in `t44-calls` every run, exactly as the
  web client does. It is a fixture channel; it is not cleaned up.
* The probe is Python 3.12+, stdlib only, and was run on this host against 9.11.19 + Calls 0.29.8. It
  does not test a 1.x plugin, and it does not test a server behind TLS (the code path exists — the
  client upgrades over `ssl` when `--url` is `https://` — but it was not exercised).

## 9. Reproduce

```sh
# signalling contract + candidate reachability, against the fixture
python3 scripts/t44_calls_probe.py --url http://127.0.0.1:8065

# the media-path evidence, by hand
docker port mm-perf
docker exec mm-perf sh -c 'cat /proc/net/udp | head -8'
docker inspect mm-perf --format '{{.HostConfig.NetworkMode}}'
```

## 10. Follow-ups (cards created by this one)

* **T44b — open the media path and measure a real call's media** (`t_7b826839`, gate for anything
  else): publish the SFU's ICE port through a UDP relay sidecar on `mm-perf-net` and set
  `ICEHostOverride`, then measure `inbound-rtp`/`outbound-rtp` on a real peer connection and the
  per-call memory with the T27 probe. Until this passes, no native Calls claim can be approved.
* **T44c — engine shell + the signalling port in Swift** (`t_d7b43d10`, gated on T44b): vendored
  `stasel/WebRTC` 137.0.0, `RTCPeerConnectionFactory` lifecycle, `AVAudioSession` + background audio
  mode + runtime permissions, and the MessagePack/zlib socket path §5.1 discovered, on top of T28's
  `SocketClient`.
* **T44d — native call surface** (`t_a2ff267a`, gated on T44c): participant tiles, mute/camera/hand,
  host controls, its own `-AV`; flips `calls` only after that `-AV` passes.
* **T44e — screen share is deliberately *not* created.** It needs a second app target (ReplayKit
  Broadcast Upload Extension) *and* a recorded licence/App-Review position, which is a human decision,
  not a worker's. §3.2 above is the specification; whoever takes that decision can open the card.
