# T12 — Mattermost Push Proxy + APNs: architecture, runbook, and honest status

**Status: PARTIAL — real push delivery NOT deployed.** This card owns the single
biggest architectural gap vs desktop: desktop shows local notifications because it is
always on; an iOS app must go through a **Mattermost Push Proxy -> APNs** when the app is
backgrounded. A real proxy cannot be deployed from this host today: the official hosted
endpoints are unreachable from here and no Apple-issued APNs auth key exists (a human +
Apple Developer account is required). What IS delivered here is a **verified, runnable
simulacrum** of the push proxy plus the complete runbook/secret inventory, so that the
moment infra is unblocked (see §5) deployment is a config exercise, and so T13
(APNs registration + NotificationServiceExtension) has a real endpoint and a real,
inspectable APNs payload contract to build against.

All network findings on this host (verified by probes, no fabrication):

| Endpoint | Result |
|---|---|
| `https://community.mattermost.com/api/v1/system/ping` | HTTP 200 `{"status":"OK"}` |
| `https://api.push.mattermost.net` (official hosted proxy) | DNS failure — unreachable |
| `https://api.push.mattermost.com` (official hosted proxy) | DNS failure — unreachable |
| `https://host.mattermost.com` | DNS failure — unreachable |
| local simulacrum `http://127.0.0.1:8066` | runnable now (verified) |

---

## 1. Architecture (what a real setup looks like)

```
 MMATTERMOST SERVER (self-hosted, reachable by devices)
    |  POST {PushNotificationServer}/api/v1/send_push
    |  HMAC-SHA256 signature: Push-Notification-Signature header over the body,
    |  keyed with PushNotificationServerSecret
    v
 MATTERMOST PUSH PROXY (hosted/owned: see §5 ownership)
    |  builds APNs request (aps + data.* keys), signs with Apple .p8 auth key
    v
 APPLE PUSH NOTIFICATION SERVICE (api.push.apple.com / api.sandbox.push.apple.com)
    |  topic = app bundle id
    v
 iOS DEVICE  -> NotificationServiceExtension (T13) rewrites body/thread/badge
```

Request surface implemented by the proxy (verified against docs.mattermost.com and
`mattermost-server/app/notification_push.go`, model `API_URL_SUFFIX_V1` = `/api/v1`):

- `POST /api/v1/send_push` — body fields: `type`, `message`, `badge`, `platform`
  (`apple` / `apple_rn` / `android` …), `server_id` (Mattermost **DiagnosticId**),
  `device_id` (`apple:<hexToken>`; strip the prefix before handing to APNs),
  `channel_id`, `team_id`, plus optional `data`, `ack_id`, `category`, `version`,
  `post_id`, `sender_id`, `sender_name`, `root_id`, `sub_type`, `is_crt_enabled`.
- `POST /api/v1/ack` — client ACK payload echoed back to the Mattermost server
  (`SendAckToPushProxy` in notification_push.go).
- `/ping` — health probe.

The APNs `data.*` keys the app's NotificationWorker already emits (T8) are exactly the
keys the NSE + click-routing (T13) consume: `server_id`, `channel_id`, `team_id`, `url`,
`type`. This card's simulacrum reproduces that shape so T13's contract matches the real
proxy. In code: `Mattermost/Core/NotificationWorker.swift` lines ~146-152.

---

## 2. Deliverables in this card (all verified on this host)

`PushProxy/` (repo root; design doc §6 "PushProxy (deployment config, NOT app code)"):

- **`PushProxy/mmpush_proxy.py`** — runnable mock Push Proxy (stdlib Python). Implements
  the documented `/ping`, `/api/v1/send_push`, `/api/v1/ack`, `/registry` surface,
  validates `server_id`/`platform`/`device_id`, and on a valid `send_push` **emits the
  exact APNs request** (topic, push-type alert, `aps`+`data` body) it would have sent to
  APNs, so the payload contract is inspectable. NOT a real proxy; it cannot reach APNs
  (no `.p8`). Run it:

  ```
  python3 PushProxy/mmpush_proxy.py --port 8066
  # verified calls:
  curl http://127.0.0.1:8066/ping                          -> {"status":"OK", ...}
  curl -X POST http://127.0.0.1:8066/api/v1/send_push -H "Content-Type: application/json" \
    -d '{"type":"message","message":"Test","badge":2,"platform":"apple",
         "server_id":"REPLACE_WITH_MATTERMOST_DIAGNOSTIC_ID","device_id":"apple:<hexToken>",
         "channel_id":"<chan>","team_id":"<team>","url":"https://...","post_id":"<p>",
         "sender_id":"<s>","sender_name":"Alice"}'          -> {"status":"OK","id":...}
  curl -X POST http://127.0.0.1:8066/api/v1/ack -H "Content-Type: application/json" \
    -d '{"id":"abc","type":"mention","client_platform":"apple","client_received_at":173}' -> {"status":"OK"}
  ```

- **`PushProxy/mmpush_proxy.json`** — config template whose keys mirror the real
  `mattermost-push-proxy.json` (`Servers[].ServerID/Secret`,
  `ApplePushSettings{Type,TeamID,KeyID,AuthKeyPath,Topic,BundleID}`) so a move to a real
  proxy is a config swap. Placeholders begin `REPLACE_` (the checker flags them).

- **`PushProxy/mmpush_check.py`** — honest readiness/blocker inventory (exit 0 = all
  release-gate items present). Run: `python3 PushProxy/mmpush_check.py [--proxy URL]`.
  Current output (this host): simulacrum RUNNABLE; every real piece BLOCKED (see §5).

---

## 3. Secrets / credentials inventory — WHO provides what

These are the exact real-world dependencies. No agent can conjure the Apple ones; a
human with the right accounts must supply them. Store via the team's secrets manager
(Keychain already the app side; infra secrets go to the platform vault), never in git.

| # | Secret / value | Source (who provides) | Used by |
|---|---|---|---|
| 1 | **APNs auth key `.p8`** | Apple Developer `Certificates, IDs & Profiles > Keys` (+ an APNs Key). This is **Apple-side, human-only**, tied to your team id. | Push proxy (signs APNs JWT) |
| 2 | Apple **Team ID** (`TeamID`) | Apple Developer membership | proxy `ApplePushSettings` |
| 3 | APNs **Key ID** (`KeyID`) | the `.p8` creation row | proxy `ApplePushSettings` |
| 4 | **App bundle id / APNs topic** | this Xcode project (e.g. `com.<org>.mattermost.ios`) | proxy `Topic` + APNs routing |
| 5 | **Push server key / secret** (`PushNotificationServerSecret`) | you, when you set up the proxy. POINTS TO a `PushProxy` server you host. | HMAC signature + proxy `Servers[].Secret` |
| 6 | **Mattermost server DiagnosticId** (`server_id`) | `SELECT * FROM Systems WHERE Name='DiagnosticId';` on the configured MM server | proxy `Servers[].ServerID` |
| 7 | Device APNs **tokens** | app registers via T13 (`registerForRemoteNotifications`) and forwards to the MM server; proxy records them. | proxy device registry |

### Mattermost SERVER-side config (System Console > Notifications > Mobile Push) — values you must set once a real proxy is live

- **Send Push Notifications**: enable. **Push Notification Server**:
  `https://<your-proxy-host>/api/v1/send_push` (the design doc references
  `host.mattermost.com` self-host option). **Push Notification Server Type**:
  `mattermost` (uses the `/api/v1/send_push` contract). **Push Notification Contents**:
  choose per data-privacy policy (Full message snippet vs ID-only). **Push Notification
  Server Secret**: match proxy `Servers[].Secret`.

---

## 4. Design-decisions / divergences relevant to downstream (T13)

- The push-proxy request/response contract and the app's `data.*` keys are already
  aligned (T8), so T13 should build directly against §1's shape; the simulacrum at
  `PushProxy/mmpush_proxy.py` is the reference for the APNs payload T13's
  NotificationServiceExtension will parse.
- The iOS app must strip the `apple:`/`apple_rn:` prefix from `device_id` before handing
  the hex token to APNs — T13 registers tokens; the proxy receives them prefixed.
- Push Notifications capability is intentionally still ABSENT from
  `Mattermost/Mattermost.entitlements` (it requires a real proxy + APNs registration,
  design doc risk R1/Phase 4). T13 enables it and registers the token.
- App Store compliance (design §33: ATS exceptions scoped to configured servers, privacy
  manifest) remains a release gate on Phase 6 — not this card.

---

## 5. What is still needed to make real push delivery work (BLOCKERS)

These are the honest gaps. The simulacrum + runbook remove the design/contract risk; the
remaining blockers are pure ownership + credentials:

1. **WHO RUNS THE PROXY (design risk R1 — "Confirm who runs it").** A hosting decision is
   required from the operator/human: (a) self-host `mattermost/mattermost-push-proxy` on
   infra you own and provide a public `https://` endpoint, or (b) use Mattermost's hosted
   push service (unreachable from this host — needs a human to confirm their org can reach
   it). Until an endpoint URL exists, nothing can be deployed.
2. **Apple APNs auth key (.p8) + Team ID + Key ID.** Human with an Apple Developer account
   must create/copy these. Cannot be generated by any agent or this host.
3. **Mattermost server account** with the DiagnosticId and the ability to change
   System Console>Notifications>Mobile Push (a live configured server whose
   `PushNotificationServer` points at whichever proxy is chosen).

Until (1)-(3) are satisfied, `PushProxy/mmpush_check.py` returns NOT READY and real push
cannot be verified end-to-end. When they are, the run-out is: stand up proxy with §2/§3
config -> point the MM server's Push Notification Server at it -> T13 registers the token
-> device-soak test. Re-run `mmpush_check.py --proxy https://<host>` and every gate goes
green.

Last verified: 2026-10-22 by T12 (mmios-ops).