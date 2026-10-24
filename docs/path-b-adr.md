# ADR: Path B — Native SwiftUI client over REST v4 + WebSocket v4

- **Status:** Accepted (T24)
- **Date:** 2026-10-24
- **Repos in scope:** This repo (`mattermost-ios`), a personal Mattermost client.
- **Related decisions:** design of record
  `~/.hermes/plans/2026-10-08_mattermost-desktop-ios-migration.md` (§1 fork, §4 module map);
  `docs/parity.md` (module→native mapping); native inventory T25 (`docs/native-inventory.md`,
  the screen-by-screen disposition this ADR carves up).
- **Downstream that depends on this decision:** T25 (native inventory), T26 (dual-render
  harness), T27 (memory baseline), T28 (transport), T29 (local store), T30 (native shell),
  and every T31–T45 screen card.

---

## 1. Decision

**Adopt Path B: replace the WKWebView workspace with native SwiftUI screens driven by the
Mattermost REST API v4 and WebSocket v4.** The web app is no longer the primary surface.

Path A (the SwiftUI shell + one WKWebView per server that exists today) is *not* discarded whole.
Its WKWebView rendering survives, but only as a **per-surface escape hatch** for screens that are
not native yet or that are declared out-of-scope (see §2.3 and §4). The mechanism is the
T46/`docs/parity.md` escape-hatch surface and the T26 dual-render switch: at any moment a screen
renders native *or* falls back to a webview, decided per surface, not per app.

**Rationale.** The stated reason for this iOS migration is that the web engine costs too much
memory. That reason is incompatible with the webview being the primary rendering path. This is
not a preference question — the premise that motivated Path A is instrumented as falsifiable in
T27 (§4) and, once measured, drives how aggressively we push surfaces to native. Continuing to
build on WKWebView as the main surface would keep the memory cost that the project exists to
remove.

### Scope motivator

This is a decision *document*, the record of choosing the fork that §1 of the design of record
already flagged as "only if native feel/performance is a hard non-negotiable." The user has now
made that call. The cost of it is real and must stay visible (§2.1).

---

## 2. Cost, stated honestly

### 2.1 What a full native Mattermost client actually costs

The official Mattermost React Native client (`mattermost/mattermost-mobile`, Apache-2.0) is a
**multi-year, multi-hundred-thousand-line** codebase: channel/board CRM UI, a markdown + GFM
renderer, emoji, thread + DM/GM plumbing, message drafts, autocomplete, reactions, attachments
and file preview, search/saved/pinned, notifications, websocket event reconciliation, offline
caching, and a SQLite store. A Swift rewrite of that entire feature surface **is not a weekend
port.** Any plan that treats it as such is wrong and will silently slip.

This repo deploys **none** of that today. The current native shell (`ServerStore`, `ViewStore`,
`SecureVault`, `DownloadWorker`, `SessionStore`, `SettingsView`, `WelcomeView`, `Diagnostics`)
is the desktop-shell reconstruction, not a chat client. Path B therefore starts from a clean
sheet for the chat layer; the existing shell components remain as the host.

### 2.2 Sequencing — which screens deliver 80% of daily use

Native surfaces are built in the order below so the daily-use path is native first and the
webview escape hatch recedes progressively. This order is owned by this ADR until T25
(finishes the inventory and may refine it per surface with evidence + difficulty ratings).

| # | Surface group | Cards | Cumulative daily-use justification |
|---|---|---|---|
| 0 | Native plumbing that everything sits on | T28 transport (AuthSession + REST v4 + WS v4), T29 local store (SQLite/migrations/repository), T30 native app shell behind the dual-render flag | Auth + transport + store are prerequisites; no screen materialises without them. |
| 1 | Team + channel sidebar | T32, T33 | This is how a user gets anywhere; unread/mention/mute live here. |
| 2 | Channel view + post list | T34 | The reading surface; the bulk of time in-app. |
| 3 | Composer | T35 | Sending is the second daily action (send/edit/draft/autocomplete/upload). |
| 4 | Threads + replies | T36 | Followed threads are a heavy daily read path for most users. |
| 5 | Reactions + emoji | T37 | Cheap, high-frequency. |
| 6 | Attachments + image/file viewer | T38 | Files/images are common but can fall to webview briefly. |
| 7 | Search + saved + pinned | T39 | Heavy when used; not every day. |
| 8 | Channel info + membership | T40 | Popover-level, lower frequency. |
| 9 | Profile / presence / custom status | T41 | Frequent but tiny; cheap to port. |
| 10 | Activity / mentions inbox | T42 | Feedback loop surface; moderate. |
| 11 | Notification integration | T43 | The push path that makes the client usable in background. |
| 12 | Accessibility + Dynamic Type | T45 | Cross-cutting, not a screen; must gate release. |
| 13 | Auth & session surface | T31 | Login/MFA/SSO is front-loaded in the *flow* but depends on transport; ordered by dependency. |

Anything finalising after T43, or not owned by a T-number, is out-of-scope unless re-entered by a
new card. Memory pressure from T27 can pull a surface up the order; capability risk can push it
down (§4).

### 2.3 Explicit "will never ship" native list

These stay webview-escape-hatch (T46) or shared/dropped. Keeping this list written stops scope
from creeping silently:

- **Calls (VoIP/WebRTC).** Highest risk of any feature. Live by P2P WebRTC, mic/screen-share via
  `getUserMedia` + `RPSystemBroadcastPickerView`. Reimplementing native Calls = a VoIP client. This
  is **webview-only** (T15/T16), and even that ships last / may be cut for v1.
- **Boards.** Standalone kanban product surface; webapp plugin. **Webview-only** via T46.
- **Playbooks.** Webapp plugin with its own state machine and templates. **Webview-only** via T46.
- **Plugin screens generally.** Mattermost is extensible via server plugins that ship their own
  web UI. A native client cannot render unknown plugins; they belong in the webview escape hatch
  for all of T38+ plugin surfaces. Plugin *system-channels* data (e.g. a plugin posting to a
  channel) still renders through the normal native channel view since it is just posts.
- **System Console.** Admin-only server-configuration surface, entirely server-side. **Webview-only**
  via T46 (always), never native.

**No completion date is claimed** for the full surface. This ADR commits to the *order* and the
out-of-scope boundary, not to a calendar date. Only the current phase's surfaces have a committed
definition of done. Claiming otherwise would be indefensible.

---

## 3. Licence boundary — what "clean reimplementation" means here

> **Correction (T25b, 2026-10-24) — a previous factual error, fixed here.**
> This section used to claim the Mattermost webapp source was AGPL-3.0 ("observation only,
> never copied"). That was wrong, on two counts, and the licence decision in
> `docs/native-inventory.md` §7 already flagged the first:
> 1. The **current** webapp UI lives in the `mattermost/mattermost` monorepo under
>    `webapp/` — its `LICENSE.txt` line 15 licenses `webapp/` and all subdirectories
>    (including `webapp/channels/src/`) under **Apache-2.0** (verified 2026-10-24 by reading the
>    file at the pinned tag).
> 2. The **legacy** standalone repo `mattermost/mattermost-webapp` carries an **Apache-2.0**
>    `LICENSE.txt` today (verified 2026-10-24: `gh api repos/mattermost/mattermost-webapp/license`
>    → Apache-2.0, and the file head at `master` is the Apache License 2.0).
>
> **Consequence:** translating the Mattermost webapp UI (mobile client and webapp components) into
> SwiftUI **is permitted with attribution** — see `docs/THIRD_PARTY_NOTICES.md` for the pinned
> tags, SHAs, and per-file header to carry. What remains AGPL-3.0 / commercial and is **never**
> ported is the **server** source (`mattermost/mattermost` `server/`, `enterprise/`, and any other
> AGPL/CC tree). The client only ever talks to the server through the public REST v4 + WS v4 API.

Sources of truth, and their verified legal positions (verified 2026-10-24 via
`gh api repos/<org>/<repo>/license` plus reading `LICENSE.txt` heads; see
`docs/THIRD_PARTY_NOTICES.md` for SHAs):

| Source | Licence | How we use it |
|---|---|---|
| `mattermost/mattermost-mobile` (RN client, `app/` + Gekidou iOS layer) | Apache-2.0 | **Translate with attribution.** Screen inventory, rendering components, REST/WS clients, and the 50 Gekidou Swift files are all Apache-2.0 and may be ported. |
| `mattermost/mattermost` monorepo — `webapp/` (live web app UI) | Apache-2.0 (`LICENSE.txt` line 15: "Admin Tools and Configuration Files (… `webapp/` and all subdirectories thereof)") | **Translate with attribution** for the webapp-only surfaces we cross-check (markdown semantics, combined system messages, admin-free components). |
| `mattermost/mattermost-webapp` (legacy standalone repo) | Apache-2.0 (LICENSE.txt head; previously believed AGPL — see correction above) | **Translate with attribution** if ever needed; current work uses the monorepo tree. |
| `mattermost/mattermost` monorepo — `server/`, `enterprise/` (Go server) | AGPL-3.0 / commercial | **Never copied, transpiled, or ported.** Out of scope for every card in this program. |
| `mattermost/mattermost-webapp`-era AGPL trees elsewhere | AGPL-3.0 | **Observation only.** Do not cite paths from AGPL trees in inventory docs (`docs/native-inventory.md` §7). |
| Server API | public, documented at `https://api.mattermost.com` (REST v4 + WS v4) | The contract. A native client is a **reimplementation against this public contract**, not a reverse-engineering of the UI. |

**What "clean reimplementation from the public API" means:**

1. Every protocol interaction is written against the **documented** endpoint + event contract, not
   against observed payload shapes lifted from code paths (nothing needs lifting — the Apache-2.0
   trees are open for reading).
2. Swift types (models, payloads, WS events) are our own `Codable` definitions derived from the
   documented schema; where they must match a webapp field name for interop (e.g. a post `type`,
   a reaction `emoji`), we write the field name and cite the API doc / mobile reference.
3. Behavioural parity (e.g. "recalculating the unread badge") is achieved by reading the API's
   documented semantics, the mobile reference, or the Apache-2.0 webapp components — always with
   attribution per §3 of `docs/component-map.md` and `docs/THIRD_PARTY_NOTICES.md`.

**How a reviewer checks it (checklist, mirrors T25-AV):**

- Diff a candidate PR for comment blocks / string literals / struct shape that match a **server**
  source tree → reject. AGPL/commercial server text must not appear.
- Verbatim material copied from an Apache-2.0 client/webapp file is **allowed only with** the
  per-file header naming the upstream file + licence and a matching row in
  `docs/THIRD_PARTY_NOTICES.md` (component-map §3 rule). Unattributed copies are rejected.
- A file must be attributable to a **public API doc URL**, a path in the Apache-2.0 mobile
  reference, or an Apache-2.0 webapp component path. If a payload struct can be tied to none of
  these, flag it.
- The `.md` inventory (`docs/native-inventory.md`) carries, per row, the evidence string — a
  `https://api.mattermost.com/...` endpoint, a captured request, or a mobile reference path.
- CI/tooling intended to detect AGPL leakage is not required for this ADR; the human review +
  inventory evidence trail is the enforcement mechanism for now.

**Naming asymmetry to keep straight:** "https://api.mattermost.com" (the API contract, fine to
build against) and the Apache-2.0 client/webapp trees (fine to translate **with attribution**)
are *not* the AGPL server source in `mattermost/mattermost` (`server/`, `enterprise/`; never
copied). A reviewer may quiz any PR on which of the four a given line relies on.

---

## 4. Memory premise — measured, not folklore

"Do not assert 'the webview is heavy' as folklore." The premise that motivates Path B is
falsifiable and is being measured in **T27 (`docs/` memory/performance baseline harness —
webview vs native, measured)**. This ADR cites that card as the justification and **must be
updated to that card's numbers once it lands** — it has landed (§4.1 below).

**Hypothesis under test (T27):** per-server WKWebView process memory (web renderer + JS heap for
the web app) dominates this app's footprint at rest and scales with number of configured servers;
a native route (URLSession + SQLite + SwiftUI) is materially smaller for the same daily activity.

### 4.1 Measured (T27, 2026-10-24) — the hypothesis holds on this host

With the harness in `scripts/perf_probe.sh` (Mac Catalyst and iOS Simulator, Release + `PERF_PROBE`,
seeded Mattermost 9.11.19, identical scripted sequence per arm):

| target | shell floor (no webview) | Path A steady | loaded webview costs | of that, WebContent | Path A peak RSS |
|---|---:|---:|---:|---:|---:|
| Mac Catalyst | 30.0 MB | 592.1 MB | **562.1 MB** | 90 % | 942.9 MB |
| iOS Simulator | 28.6 MB | 489.3 MB | **460.7 MB** | 90 % | 1329.2 MB |

So the webview *is* the dominant cost, as §4 hypothesised, and it lives almost entirely in the
WebContent process the app does not own. The `native` arm at HEAD still carries a live WebContent
process (252.6 MB / 146.4 MB steady) — swapping the renderer without releasing the webview reclaims
none of it, which is why the release policy (§12 of `docs/dual-render.md`) is the change that has to
move this number. Full tables, per-run values, the run-to-run spread and the **limits** (these are
Catalyst/Simulator measurements on a Mac, not device measurements) are in `docs/perf/README.md`;
method and defects found while landing the harness: `docs/t27-build-note.md`.

**Consequences regardless of the measurement's magnitude:**

- T27 is a **release gate** for candidate 1 of the sequencing in §2.2 — we do not declare the
  native path "lighter" in a store note or a README until T27 has produced numbers.
- If T27 shows the webview is *not* the dominant cost (i.e. the premise weakens), we still keep
  Path B (native feel is now a stated requirement) but the priority re-balances toward shipping
  the escape-hatch surfaces faster and spending less on squeezing the final native-only screens.
- T27 feeds T26's decisions about which surfaces default native vs webview under memory pressure.

T27 has reported (§4.1), with its limits stated there and in `docs/perf/README.md`: the measured
numbers are Catalyst/Simulator values on this host, and a device run is still outstanding. The
conditional consequences above are therefore live, not hypothetical — the premise held, so nothing
re-balances.

---

## 5. Data model decision — version pinning and feature gating

**Pin a minimum server API version.** The client targets REST v4 + WebSocket v4. On connect
(after auth, via `GET /api/v4/system/ping` and capability probes carried by T28), the client
**pins the server's effective API version** for the session:

- **Feature gate, never silent failure.** Every native surface that depends on a newer server
  capability (e.g. a WS event type, an endpoint, a query parameter) is gated on the pinned
  version *and* the advertised capability. When the server is older than the client expects for a
  given feature, the feature is **disabled explicitly**: the UI shows the native view's reduced
  form or, where the fallback is better, routes to the webview escape hatch (T46). A visible
  "update your server for X" hint is shown in diagnostics — the client never quietly renders
  zeros where the server would have had data.
- **No silent degradation of correctness.** If the pinned version cannot support the current
  surface's contract, the client does not guess; it falls back (T46) rather than fabricating a
  payload.
- **Store the contract in the schema.** T29's SQLite layer records the server version it was
  written against per model (a `server_api_version` column on the migration table), so a later
  version sees how data was produced and migrates, not snap-mutates.

**Why:** Mattermost servers are self-hosted and patch their own cadence; the client cannot assume
it runs ahead of every server. Version pinning + feature gating is how we keep a native client
honest against an older backend without a corpse-path of half-supported fields.

---

## 6. Non-negotiables carried over from Path A

These were already hard constraints on the shell and remain so across the Path B transition:

1. **No real workspace values in the repo.** No real workspace URL, hostname, or token is
   committed. Docs and fixtures use `example.com` and generic ids (same rule as T25's acceptance).
   Verified by the existing release-gate/secret-scan posture.
2. **Tokens live in the Keychain.** Auth tokens are stored via `SecureVault`
   (kSecClassGenericPassword, per-server service). Never in UserDefaults or plaintext. The ad-hoc
   Mac/Keychain gap is already resolved in T22 (Keychain-first with an AES-GCM sealed-file
   fallback when the Keychain is refused at -34018); team-signed builds are Keychain-exclusive.
3. **Certificate trust is per origin.** `CertTrust` keyed by origin, user-confirmed, persisted in
   the Keychain (see T22 fallback); "don't trust again" is a hard reject. The native transport
   (T28) must wire the same trust decision into `URLSession`/`NWConnection` challenges as the
   webview path does for server-trust.
4. **`mattermost://` deep links keep working.** `DeepLinkRouter` + `onOpenURL` +
   `CFBundleURLTypes` resolve a link (server, channel, post) to the correct server and surface.
   This is preserved across the webview→native transition; the native screens register to receive
   the same routes the SPA used to.
5. **Settings screens stay native.** They already are (`SettingsView`, `AppSettings`); the native
   data path (T29) persists them. No settings surface regresses to the webview.
6. **The webview escape hatch is real and first-class.** Every screen row in `docs/native-inventory.md`
   has a fallback: `native`, `webview` (T46), or `dropped`. Until a surface ships native, its
   webview rendering is the live implementation of §2.2's order — the app is never left with a
   blank hole where a temporary nativeness gap hides a missing feature.

---

## 7. Phases and their order (acceptance)

1. **T24 (this ADR)** — decision, boundary, cost. *Enabled by completion of this card.*
2. **T25** — native screen + API inventory (the evidence the screen cards build from).
3. **T27** — memory/performance baseline (webview vs native, measured).
4. **T26** — dual-render harness / per-surface switch that T46 and the T30 shell hang off.
5. **T28** — transport (AuthSession + REST v4 + WS v4). **T29** — local store (SQLite).
6. **T30** — native app shell behind the dual-render flag, then T31–T43 surface groups in the
   §2.2 order, each gated by its own and its `-AV` card, with T46 the standing fallback.
7. **T44** Calls (webview-only, may cut) and **T16** broadcast extension — last, optional.
8. **T45** accessibility; then release.

Cannot be re-ordered: T25 before screen cards, T26/T28/T29 before T30–T43, T27 before the
"lighter" claim is made.

---

## 8. Status of this ADR

Accepted. Supersedes design-doc §1's Path A recommendation for the primary surface. The webview
is retained, but subordinate, as the per-surface escape hatch per T46. This ADR will be revised
when T27 reports numbers (§4) and when T25 settles the per-surface disposition (§2.2).