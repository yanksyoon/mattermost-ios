# T12a — Build & run the REAL Mattermost Push Proxy locally (no public hosting)

**Status: LOCAL PROXY RUNNING / APNs DELIVERY UNPROVEN.** This card replaces the T12
simulacrum with the real upstream proxy, built from source on this host and running on
loopback only. It deliberately stops at the APNs boundary: no `.p8`, no device token,
no hosting decision exists (all gated on H1). Nothing was hosted publicly and no public
URL is claimed.

## 0. Verified provenance (hard handle)

- Source: `https://github.com/mattermost/mattermost-push-proxy`
- License: **Apache-2.0** (root `LICENSE.txt`)
- Pinned ref: **tag `v6.6.0`** (latest release; equals `origin/master`)
- Pinned SHA (git `rev-parse HEAD` after checkout):
  `20f2a046fef76a7ab1c121cd01bc2b06206979be`
  ("Rework logging: gate levels, add throughput heartbeat, standardize fields (#170)")
- Build host: macOS 26.3.1 / arm64, Go 1.26.3 (module builds with the repo's own
  `go.mod`). `go build ./...` and `go build -o bin/mattermost-push-proxy .` both exit 0.
  `go vet ./...` clean.
- Built binary: `PushProxy/upstream/bin/mattermost-push-proxy` (51 MB, on disk).
- `mattermost-push-proxy -version` reports `GitVersion devel` / `version unknown+unknown`
  because the build was not stamped via the Makefile ldflags; the pinned SHA in the
  manifest is the authoritative build identity.

> The vendored tree under `PushProxy/upstream/` is **gitignored** (nested `.git` + 51 MB
> binary). Provenance lives in `PushProxy/upstream_manifest.json` (committed).

## 1. Config (loopback-only, placeholder key — no secret committed)

`PushProxy/upstream/mattermost-push-proxy.json` (runtime config, gitignored; derived
from the repo's `config/mattermost-push-proxy.sample.json`):

- `ListenAddress`: **`127.0.0.1:8066`** (loopback only — no public endpoint, no tunnel,
  no reverse proxy).
- `ApplePushSettings[0]`: `Type: apple`, `ApplePushTopic: com.mattermost.ios`
  (the bundle id), `ApplePushUseDevelopment: false` (prod APNs), and the APNs auth-key
  fields are **placeholders** to trigger the `.p8` credential path:
  - `AppleAuthKeyFile: /abs/does/not/exist/REPLACE_WITH_APNS_AUTH_KEY.p8`
  - `AppleAuthKeyID: REPLACE_WITH_APNS_KEY_ID`
  - `AppleTeamID: REPLACE_WITH_APPLE_TEAM_ID`
- `AndroidPushSettings: []` (out of scope).
- `EnableConsoleLog: true`, `EnableFileLog: false`.

**No real secret, no private key, no real workspace URL is committed.** The `.p8` does
not exist and must not be fabricated (H1 gate).

## 2. Run it (localhost)

```sh
cd PushProxy/upstream
./bin/mattermost-push-proxy -config mattermost-push-proxy.json
# binds 127.0.0.1:8066 (verified: lsof shows 127.0.0.1:8066 LISTEN)
```

Startup log (pasted; the exact missing-`.p8` error is what this card proves):

```
info  Loading .../upstream/mattermost-push-proxy.json
info  Push proxy server is initializing...
error Failed to initialize client error="failed to initialize apple notification
      service with AuthKey file err=open /abs/does/not/exist/REPLACE_WITH_APNS_AUTH_KEY.p8:
      no such file or directory "
info  Server is listening on 127.0.0.1:8066
```

That is the deliberate stopping point: the Apple target **fails `Initialize()` because the
`.p8` file is absent**, and it is then dropped, so the proxy keeps serving the HTTP surface
without an APNs client.

## 3. Proofs on localhost (pasted real output)

### 3a. Status/health endpoints answer

```
$ curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8066/     -> 200
$ curl -sS http://127.0.0.1:8066/version
{"hash":"unknown","version":"unknown+unknown"}
```

### 3b. `send_push` request-validation gate (the real router's checks)

The upstream router (`server/server.go` `handleSendNotification`) validates only
**presence** of `server_id`, `device_id`, and `platform`; each failing case returns a real
`FAIL` JSON with an exact reason:

```
POST /api/v1/send_push  {"message":"Test push","badge":2,"platform":"apple",
  "server_id":"commtest","device_id":"apple:0123...","type":"message"}
  -> {"error":"Did not send message because of missing platform property type=apple serverId=commtest","status":"FAIL"}
     (the Apple target is NOT registered because its .p8 Initialize() failed at startup)

POST /api/v1/send_push  {"message":"no server","platform":"apple","device_id":"apple:abc"}
  -> {"error":"Failed because of missing server Id","status":"FAIL"}

POST /api/v1/send_push  {"message":"no device","platform":"apple","server_id":"commtest"}
  -> {"error":"Failed because of missing device Id serverId=commtest","status":"FAIL"}

POST /api/v1/ack  {"id":"ack123","type":"message","platform":"apple","received_at":173,"is_id_loaded":true}
  -> {"status":"OK"}
```

`PushProxy/t12a_hmac_probe.py` sends a correctly HMAC-SHA256-signed body, a tampered
signature (wrong key), and a tampered body; all three reach the same router on localhost:

```
[A] correctly HMAC-SHA256-signed body              HTTP 200 -> {"error":"Did not send message because of missing
                                                              platform property type=apple ...","status":"FAIL"}
[B] TAMPERED signature (correct body, WRONG key)   HTTP 200 -> same FAIL (missing platform, i.e. no .p8 target)
[C] TAMPERED body (message changed)                HTTP 200 -> same FAIL
[D] missing server_id (even with valid HMAC)       HTTP 200 -> {"error":"Failed because of missing server Id","status":"FAIL"}
```

## 4. IMPORTANT CORRECTION to the earlier design's HMAC premise

The old `docs/t12-push-proxy.md` and the simulacrum claimed the proxy authenticates each
`send_push` by verifying an HMAC `Push-Notification-Signature` header keyed with a
`Servers[].Secret` / `PushNotificationServerSecret` pair, and that a *tampered* signature
would be rejected. **That is not true of the real upstream proxy, in any historical
version.** Verified against the source:

- `server/config_push_proxy.go` `ConfigPushProxy` has **no** `Servers`, `ServerID`, or
  `Secret` field. The current config schema (`ApplePushSettings`, `AndroidPushSettings`,
  throttling, logging) contains nothing for per-server credentials.
- `git log -S 'ServerSecret'` / `-S 'Push-Notification-Signature'` / `-S 'hmac'` over the
  whole history return nothing; `server/server.go` `handleSendNotification` never reads a
  signature header — it only checks `server_id`/`device_id`/`platform` presence before
  routing.
- The `signature` field in `model.PushNotification` is **passthrough**: the Mattermost
  *server* sets it (an ES256 JWT over `ack_id`+`device_id`, `app/notification_push.go`
  lines ~221-238) and the proxy copies it verbatim into the APNs payload
  (`apple_notification_server.go` line ~293) for the *app* to verify on delivery; the
  proxy itself does not authenticate the caller with it. Header auth (`X-Mattermost-Auth`,
  `X-Mattermost-ServerID`) is optional and only sent by the server when its `PushProxy`
  client object is populated (hosted-proxy path), and the proxy does not validate those
  headers either.

**Consequences (acceptance-criteria honesty):**

- "Signed request accepted" — true at the HTTP/validation level: a well-formed body is
  accepted; the tampered and signed cases are **indistinguishable** to this proxy because
  there is no signature check. We do NOT claim a "(correct) signature is required".
- "Tampered request rejected" — **NOT supported by the upstream proxy.** This is the key
  honest correction: the self-hosted proxy trusts any caller that presents a
  `server_id`+`device_id`+`platform`. Access control is expected to be enforced around the
  proxy (hosting decision: firewall / TLS client cert / reverse-proxy auth), not by the
  proxy itself. If the team wants a server-secret HMAC gate, that is a feature to add to
  the deployment (a small auth reverse-proxy in front of 127.0.0.1), not something the
  stock upstream provides today.
- The APNs attempt stage is NOT reached with the placeholder `.p8`: the Apple target is
  dropped at startup because `Initialize()` fails on the missing file (exact error in §2),
  so the nearest provable event is "request reached the router" (§3b), which is what we
  report.

## 5. What is provably PROVEN vs what is provably NOT

**Proven (on this host, all real output above):**
- The official upstream proxy builds from source; pinned tag + SHA recorded.
- It runs bound to `127.0.0.1:8066` only.
- Status/health endpoints (`/`, `/version`) answer.
- The router enforces `server_id`/`device_id`/`platform` presence with exact FAIL reasons;
  valid `ack` returns OK.
- The missing-`.p8` startup error is exactly as pasted in §2 (`no such file or directory`).

**Provably NOT proven (must not be claimed):**
- **No APNs delivery.** No Apple-issued `.p8`, so the Apple target never initializes; no
  notification ever leaves for Apple.
- **No device receipt.** No device token, no `/api/v1/ack` from a real client, no
  "Received by device" signal.
- **No HMAC request authentication.** The upstream proxy does not implement it (§4).
- **No hosting.** The proxy runs on loopback only; no reverse proxy, no tunnel, no public
  URL exists. Nothing was hosted publicly.

## 6. One-line run-out (when a `.p8` + hosting decision exist)

Replace the three `REPLACE_WITH_*` placeholders in `PushProxy/upstream/
mattermost-push-proxy.json` with the real APNs key path / key id / team id, put the proxy
behind the chosen host (public `https://` endpoint or authenticated reverse-proxy that ALSO
enforces the server-secret gate we lack — see §4), point Mattermost's System Console >
Notifications > Mobile Push: **Push Notification Server** = `https://<host>/api/v1/send_push`,
**Type** = `mattermost`, **Push Notification Server Secret** = shared with that gate; then
T13 registers device tokens and a device-soak test verifies delivery. Re-run
`PushProxy/mmpush_check.py --proxy-url <host>` to re-prove each gate.

## 7. Readiness probe (one command)

```sh
python3 PushProxy/mmpush_check.py     # while the proxy runs on 127.0.0.1:8066
```

Current output (this host): binary/sha PASS, loopback bind PASS, socket PASS, `/version`
PASS, `send_push` exercised PASS (reaches router); `.p8` BLOCKER, real ack-receipt NOT
PROVEN. `mmpush_proxy.py` is retained as a **contract fixture only** (labelled in its
docstring) and is no longer presented as delivery evidence.

Last verified: 2026-10-24 by T12a (mmios-ops), on `MacBook-Pro-5.local`.