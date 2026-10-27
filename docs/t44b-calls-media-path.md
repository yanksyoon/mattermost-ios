# T44b — open the Calls media path on the fixture, and prove RTP

**VERDICT: the gate passes.** A client on this host can now carry bidirectional Calls audio against
the fixture, and it is measured with the engine's own `getStats()` counters, not asserted:

```
peer A  outbound-rtp 405 pkts / 32,805 B   inbound-rtp 179 pkts / 14,499 B  +388,800 samples  opus
peer B  outbound-rtp 404 pkts / 32,724 B   inbound-rtp 213 pkts / 17,253 B  +388,800 samples  opus
selected pair: 127.0.0.1:8443/udp host, bytes both ways (41,560 / 33,524 and 33,784 / 37,062)
```

Both peers joined a real call on `mm-perf` (Calls 0.29.8 / `936dd00`), sent synthetic audio, and
**decoded** the other side's audio (`totalSamplesReceived` and `totalAudioEnergy` both grow). The
receive side is lossy (see §7) — that is measured and carried forward, not hidden.

- Card: `t_7b826839` (T44b), 2026-10-27, host `MacBook-Pro-5.local`, macOS 26.3.1
- Follows T44 (`t_a3383222`), whose record is `docs/t44-build-note.md` and
  `docs/t44-calls-media-path-2026-10-27.log` at `8dc7163`.
- This card flips nothing: `SurfaceDefaults.nativeApprovedSurfaces` still has no `.calls`.

---

## 1. Two things T44's measurement got wrong (both measured here)

T44 reported `MEDIA PATH: 0/3` and concluded "the SFU publishes no reachable ICE port". The port was
in fact unpublished — but the probe could not have seen the difference, for two independent reasons:

1. **A bare STUN binding request cannot be answered by this SFU at all.** The plugin demultiplexes
   every session on one UDP port with a ufrag mux (`rtc.NewServer` → `webrtc.NewICEUDPMux`,
   `server/activate.go`), and the mux routes a datagram to an ICE agent by the STUN `USERNAME`
   attribute. A binding request without `USERNAME`/`MESSAGE-INTEGRITY` matches no agent, so it is
   dropped — **whether the port is open or shut**. Proof, measured in this card: with the relay
   running (port published, ICE agent answering — see §4) the old check *still* printed
   `MEDIA PATH: 0/3`, every candidate "no reply":

   ```
   DATA  stun binding to 127.0.0.1:8443  —  no reply (2.0 s)      # port was open and answering
   DATA  stun binding to 64.251.85.226:8443  —  no reply (2.0 s)
   DATA  stun binding to 209.35.187.178:58740  —  no reply (2.0 s)
   DATA  control: a public STUN server answers from this host  —  yes
   MEDIA PATH: 0/3 advertised UDP candidate(s) reachable from this host — media cannot flow here
   ```

2. **The check ran after `leave`.** `run_session` sends `leave` at the end, and the SFU tears its ICE
   agent down on leave, so any datagram sent afterwards hits a mux with no session. A credentialed
   check issued after the session ends is silent for the same reason a closed port is.

`scripts/t44_calls_probe.py` now measures reachability the way a client's ICE agent does:

- it joins, takes the SFU's own answer SDP, and reads the server's `ice-ufrag` / `ice-pwd` from it;
- it sends `USERNAME=<server-ufrag>:<client-ufrag>`, `MESSAGE-INTEGRITY` (HMAC-SHA1 keyed with the
  server's `ice-pwd`), `PRIORITY`, `ICE-CONTROLLING`, `FINGERPRINT` — RFC 8445 §7.2.2 / RFC 5389 §15.4;
- it does that **inside** the session (`run_session(..., hook=...)`, before `leave`);
- it still reports `PASS`/`FAIL` for the 8 signalling checks and prints reachability as a measurement.

A *binding error* counts as a reply: an authenticated error means an ICE agent saw the packet, which
is the question.

## 2. The fixture change (reversible, one command each way)

The SFU's ICE port is unpublished because `mm-perf` was created with only `8065/tcp`, and a running
container cannot gain a port mapping. The media path is therefore opened **beside** it, on the same
docker network, and published on host loopback only:

```bash
docker run -d --name mm-calls-udp --network mm-perf-net \
  -p 127.0.0.1:8443:8443/udp alpine/socat:latest \
  UDP4-LISTEN:8443,fork,reuseaddr UDP4:mm-perf:8443
```

- image `alpine/socat:latest` (pulled during this card: digest
  `sha256:603174b77eebaba25ba8f8ebb15e1234d6600409554e95d6fb203fd106150287`)
- `mm-perf` resolves to `172.19.0.3` on `mm-perf-net`; the relay answered its own `getent hosts mm-perf`
  with `172.19.0.3`, so the upstream leg is a name, not a hard-coded IP.
- bound to `127.0.0.1` on the host on purpose: the fixture's SFU is not exposed on the LAN by this.
- `fork` gives each client source its own upstream socket, so the SFU sees one distinct
  `172.19.0.x:<port>` peer per client and its replies come back through the same child.

**Revert (removes the relay and with it the whole fixture change):**

```bash
docker rm -f mm-calls-udp
```

Nothing else about `mm-perf` was modified: no plugin config is left set, no file is left in the
container (see §3 and §9). State left behind by this card, verified at the end of the run:
`docker ps` shows `mm-calls-udp  Up  127.0.0.1:8443->8443/udp`,
`python3 scripts/t44b_calls_config.py show` prints
`PluginSettings.Plugins['com.mattermost.calls'] = {} (absent: plugin defaults)`, and
`curl -o /dev/null -w '%{http_code}' http://127.0.0.1:8065/static/t44b_rtp_spike.js` prints `404`
(the RTP harness was served from the fixture's static dir for the measurement and moved out again).

## 3. `ICEHostOverride` is *not* part of the fix on this build — it breaks it

The card (and T44's remedy note) proposed setting the plugin's `ICEHostOverride` to `127.0.0.1`. On
this plugin build that makes things **worse**, measured:

| plugin setting | candidates advertised | `ice check to 127.0.0.1:8443` |
|---|---|---|
| unset (plugin defaults) | `127.0.0.1:8443`, `64.251.85.226:8443`, srflx, 2× tcp | **binding success, message-integrity=true** |
| `ICEHostOverride=127.0.0.1` (after a plugin restart) | `127.0.0.1:8443`, srflx, 1× tcp | **no reply** (repeated, 3/3 runs) |

With the override cleared (and the plugin restarted) the reply comes back on every run: 5/5 repeats
plus the final captures. So the override is cleared on the fixture, is not needed, and is documented
here rather than left in place. Note the order of operations that matters: a core-config write is only
picked up by the plugin after it is re-activated (`POST /api/v4/plugins/com.mattermost.calls/disable`
then `/enable`) — before the restart the candidates were unchanged, which is how the first attempt was
misread.

Where the setting does live (correction to the card's step 2, already recorded in a card comment):
plugin settings are in the **core** config at `PluginSettings.Plugins["com.mattermost.calls"]`,
written with `PUT /api/v4/config` carrying the whole document. To be precise about the routes, since
this is easy to misread as "the plugin config cannot be read" — it can:

```
GET  /plugins/com.mattermost.calls/config        -> 200   (the plugin's view: sku,
                                                           AllowEnableCalls, ICEServersConfigs, …)
PUT  /plugins/com.mattermost.calls/config        -> 405   (that route is GET-only)
GET  /api/v4/plugins/com.mattermost.calls/config -> 404   (no core-namespaced plugin route)
PUT  /api/v4/plugins/com.mattermost.calls/config -> 404
GET  /api/v4/config                              -> 200   (core config, where the write goes)
```

`scripts/t44b_calls_config.py` does read/write/clear of one key and verifies by reading back:

```bash
python3 scripts/t44b_calls_config.py show
python3 scripts/t44b_calls_config.py set ICEHostOverride 127.0.0.1   # not used by this fixture
python3 scripts/t44b_calls_config.py clear ICEHostOverride
```

## 4. Probe output, before and after

Same probe, same fixture, the only difference being the relay. **Before** (relay removed with
`docker rm -f mm-calls-udp`):

```
$ python3 scripts/t44_calls_probe.py --url http://127.0.0.1:8065
...
--- reachability of the SFU's own candidates, from this host ---
DATA  candidate  —  candidate:2878742611 1 udp 2130706431 127.0.0.1 8443 typ host
DATA  candidate  —  candidate:408902208 1 udp 2130706431 209.35.187.178 8443 typ host
DATA  candidate  —  candidate:375738803 1 tcp 1671430143 127.0.0.1 8443 typ host tcptype passive
DATA  candidate  —  candidate:2779524000 1 tcp 1671430143 209.35.187.178 8443 typ host tcptype passive
DATA  candidate  —  candidate:1244823927 1 udp 1694498815 209.35.187.178 59429 typ srflx raddr 0.0.0.0 rport 58885
DATA  ICE credentials  —  server ufrag PZLGoKQRnBswBZJV, client ufrag t44a
DATA  ice check to 127.0.0.1:8443  —  no reply (timeout)
DATA  ice check to 209.35.187.178:8443  —  no reply (timeout)
DATA  ice check to 209.35.187.178:59429  —  no reply (timeout)
DATA  control: a public STUN server answers a bare binding request from this host  —  yes

8 PASS / 0 FAIL
MEDIA PATH: 0/3 advertised UDP candidate(s) reachable from this host — media cannot flow here
```

**After** (relay running, two seconds later):

```
$ docker run -d --name mm-calls-udp --network mm-perf-net -p 127.0.0.1:8443:8443/udp \
    alpine/socat:latest UDP4-LISTEN:8443,fork,reuseaddr UDP4:mm-perf:8443
$ python3 scripts/t44_calls_probe.py --url http://127.0.0.1:8065
...
--- reachability of the SFU's own candidates, from this host ---
DATA  candidate  —  candidate:2878742611 1 udp 2130706431 127.0.0.1 8443 typ host
DATA  candidate  —  candidate:408902208 1 udp 2130706431 209.35.187.178 8443 typ host
DATA  candidate  —  candidate:375738803 1 tcp 1671430143 127.0.0.1 8443 typ host tcptype passive
DATA  candidate  —  candidate:2779524000 1 tcp 1671430143 209.35.187.178 8443 typ host tcptype passive
DATA  candidate  —  candidate:1244823927 1 udp 1694498815 209.35.187.178 62582 typ srflx raddr 0.0.0.0 rport 52498
DATA  ICE credentials  —  server ufrag WMjovQzLyzrENxCB, client ufrag t44a
DATA  ice check to 127.0.0.1:8443  —  binding success in 13 ms, message-integrity=True, mapped=172.19.0.4:48035
DATA  ice check to 209.35.187.178:8443  —  no reply (timeout)
DATA  ice check to 209.35.187.178:62582  —  no reply (timeout)
DATA  control: a public STUN server answers a bare binding request from this host  —  yes

8 PASS / 0 FAIL
MEDIA PATH: 1/3 advertised UDP candidate(s) reachable from this host
```

`mapped=172.19.0.4:<port>` is the relay's own address on `mm-perf-net` — i.e. the datagram reached the
SFU's ICE agent *through* the sidecar, and the agent authenticated it. The `209.35.187.178` candidates
(`:8443` host and the srflx port) are the fixture's public-address view; they do not route back from
this host and are expected silent. One candidate is enough: ICE picks the pair that works.

`scripts/t44b_ice_check.py` is the same check as a standalone diagnostic, with `--also host:port` for
a port the SFU does not advertise:

```
$ python3 scripts/t44b_ice_check.py --url http://127.0.0.1:8065
REPLY  127.0.0.1:8443  —  binding success in 17 ms, message-integrity=True, mapped=172.19.0.4:56294
SILENT 209.35.187.178:8443  —  no reply (timeout)
SILENT 209.35.187.178:58470  —  no reply (timeout)
ICE PATH: 1/3 advertised candidate(s) answered a credentialed binding request
```

## 5. A real call's media, measured with `getStats()`

`scripts/t44b_rtp_spike.js` runs **in a browser page on the server's own origin** (so no CORS and no
credential plumbing outside the fixture), opens **two** Calls sessions of the fixture account
(`perfprobe`, multi-session per user is supported), and for each session:

1. authenticates on `/api/v4/websocket` (`authentication_challenge`), joins
   `custom_com.mattermost.calls_join`, sends its offer as a **MessagePack binary frame carrying
   zlib-compressed JSON** (the shape T44 measured: a JSON frame is dropped server-side);
2. attaches synthetic audio — an oscillator (440 Hz on peer A, 660 Hz on peer B) through a
   `MediaStreamAudioDestinationNode`, i.e. no capture device and no microphone permission;
3. applies the SFU's answer, trickles its candidates, **and answers the SFU's own post-connect
   renegotiation offer** — that offer is what announces the media the SFU forwards toward the client,
   and a client that ignores it receives nothing (this cost one debug cycle; it is a protocol fact
   T44c needs);
4. unmutes both sessions, attaches an `<audio>` sink to the inbound track (without a sink the engine
   keeps packets in its jitter buffer and reports `totalSamplesReceived = 0`), then samples
   `getStats()` twice and reports the deltas.

Result (`seconds: 8` window, one run, reproducible — the same run was repeated 3× with the same
shape):

| counter | peer A | peer B |
|---|---|---|
| `outbound-rtp.packetsSent` | +405 | +404 |
| `outbound-rtp.bytesSent` | +32,805 | +32,724 |
| `codec` (both directions) | `audio/opus` | `audio/opus` |
| `inbound-rtp.packetsReceived` | +179 | +213 |
| `inbound-rtp.bytesReceived` | +14,499 | +17,253 |
| `inbound-rtp.totalSamplesReceived` | +388,800 | +388,800 |
| `inbound-rtp.totalAudioEnergy` | +0.0880 | +0.1026 |
| `inbound-rtp.packetsLost` | 0 | 0 |
| `inbound-rtp.jitter` | 0.003 s | 0.003 s |
| selected pair | `127.0.0.1:8443/udp host` (nominated) | same |

Source and sink agree in both directions (`A out ≈ 33 KB` ↔ `B in 17 KB of RTP + SRTP/RTCP on the
pair`; `A in` mirrors `B out`), the selected pair is the relay's loopback publication, and 388,800
samples = 8.1 s of 48 kHz audio decoded in an 8 s window — the audio really is decoded, not merely
arrived.

## 6. What this means for the follow-ups

- **T44c (`t_d7b43d10`, engine + signalling) is no longer blocked on the fixture.** Its acceptance
  criterion "bidirectional audio" is measurable here now, with this harness or against the native
  engine.
- Two protocol facts to carry over: the `sdp` action is MessagePack + zlib (T44), and **the SFU
  re-offers after ICE connects** — the client must answer that offer or it will never receive audio.
- The session's default state is `unmuted: false`; a client that does not unmute still sends RTP (it
  is the client that decides), but the server-side session state says muted, so the counters alone do
  not prove the call "sounded" — see §7.

## 7. The one number that is not clean: ~50% of the forwarded RTP is missing

`inbound.packetsReceived` is about half of the other peer's `packetsSent` (179/405 and 213/404), the
receive side fills the gaps with concealment (`concealedSamples` ≈ 55% of `totalSamplesReceived`), and
yet `packetsLost` reports **0**. Two candidate explanations, neither proven here:

1. the `socat` UDP relay (one child per client, single-threaded) drops part of the burst in the
   SFU→client direction; or
2. the SFU itself does not forward every packet (pacing/congestion handling on this build), and the
   sequence numbers it does send are contiguous, which is what makes `packetsLost` read 0 while the
   decoder still sees timestamp gaps.

Next measurement for T44c, in order of cheapness: publish the same relay over **TCP** as well
(`127.0.0.1:8443/tcp` → `mm-perf:8443`) and force ICE-TCP, which removes the UDP relay from the
picture; then compare with a single peer and the browser web client as the other participant. Until
that is measured, treat "audio flows" as proven and "audio flows *cleanly*" as unproven.

## 8. Memory: not re-measured, and why

This card linked **no engine** — the measurement above runs in browser Chrome, not in the app — so
there is no new native memory number to report, and the comparison in
`docs/t44a-calls-spike.md` stands unchanged: engine floor **11.6…15.2 MB RSS** vs **460.7 MB**
(one loaded webview, iOS simulator) / **562.1 MB** (Catalyst). `scripts/perf_probe.sh`
(`docs/perf/README.md`) is the instrument T44c should use once `stasel/WebRTC` is in the app target;
measuring Chrome's RSS here would answer a question nobody asked.

## 9. Reproduce, exactly

```bash
# 0. the fixture: relay up (this is the only change to the shared container set)
docker run -d --name mm-calls-udp --network mm-perf-net \
  -p 127.0.0.1:8443:8443/udp alpine/socat:latest \
  UDP4-LISTEN:8443,fork,reuseaddr UDP4:mm-perf:8443

# 1. signalling + reachability
python3 scripts/t44_calls_probe.py --url http://127.0.0.1:8065     # 8 PASS / 0 FAIL, MEDIA PATH: 1/3
python3 scripts/t44b_ice_check.py --url http://127.0.0.1:8065     # ICE PATH: 1/3, REPLY 127.0.0.1:8443

# 2. RTP. The harness must run *on the server's own origin*, so serve it from the fixture's static
#    directory, open http://127.0.0.1:8065/ in a browser, click once (the AudioContext needs a user
#    gesture), then in that page's console:
docker cp scripts/t44b_rtp_spike.js mm-perf:/mattermost/client/t44b_rtp_spike.js
#   > const s=document.createElement('script'); s.src='/static/t44b_rtp_spike.js'; document.head.appendChild(s);
#   > await t44bRtp({password: '…'});            // => window.__t44b, counters in .delta
docker exec mm-perf rm /mattermost/client/t44b_rtp_spike.js   # leave no client artifact behind

# 3. revert the fixture change
docker rm -f mm-calls-udp
```

After the revert run `python3 scripts/t44_calls_probe.py` once more: it must print `MEDIA PATH: 0/3`
again, which is the "before" capture in §4.

## 10. Limits, stated

- The path that works is **loopback on this host** (`127.0.0.1:8443`). A device on the LAN needs the
  relay published on the host's LAN address and — for the SFU to advertise something a device can
  reach — a working `ICEHostOverride`, which this build does not deliver (§3). Native-Calls work on a
  physical device is unmeasured.
- The relay is a fixture crutch, not a deployment: a real deployment publishes the SFU port (or runs
  RTCD) and sets `ICEHostOverride` to the public address.
- No plugin licence decision is made or implied here; `calls` stays `web`
  (`SurfaceDefaults.nativeApprovedSurfaces` unchanged) and this card is measurement only.
- The `getStats()` numbers come from Chrome's libwebrtc — the same engine family `stasel/WebRTC`
  wraps — not from the app. They establish what the *server* can carry; they are not an app
  measurement.
