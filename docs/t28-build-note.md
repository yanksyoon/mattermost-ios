# T28 build note — native transport: AuthSession + REST v4 client + WebSocket v4 client

- **Status:** delivered 2026-10-24. Handed to **T28-AV** (adversarial validation).
- **Repair round:** **T28-R**, 2026-10-24 — every T28-AV finding (F1–F9) fixed or answered with
  evidence; see §7b. Suite: 451 tests, 3 skipped, 0 failures on Mac Catalyst **and** iPhone 16 Pro
  (iOS 18.3) simulator; `t28-token-grep.sh` PASS; `t28-selfsigned-check.sh` PASS (now including the
  real `wss` transport).
- **Card:** T28 (native transport — AuthSession + REST v4 client + WebSocket v4 client).
- **Program anchor:** `docs/path-b-adr.md` §4 stage 0 ("auth + transport + store are
  prerequisites; no screen materialises without them"), `docs/native-inventory.md` §"pagination and
  cursor conventions", `docs/component-map.md` §2 (Gekidou "take as-is" list).
- **Consumers:** every screen card T30–T45 sits on `APIClient` / `SocketClient`; **T29** (local
  store) consumes `MMTypes` + the pagination cursors.

## 1. What was built (files, all new unless noted)

| File | Lines | What it is |
|---|---|---|
| `Mattermost/Core/MM/MMLog.swift` | 78 | Token-safe logging boundary: `redact(_:)` strips `Bearer …`, `token=…`, `MMAUTHTOKEN=…`, `password=…`, `preauth_secret=…` before anything reaches `Logger`. |
| `Mattermost/Core/MM/MMJSON.swift` | 170 | `JSONValue` + `MMRawJSON`: loss-free JSON for `post.props`/`metadata` and the untyped WebSocket `data` object, with a deterministic `canonicalString()` used for dedupe keys. |
| `Mattermost/Core/MM/MMTypes.swift` | 431 | Typed models (`MMPost`, `MMPostList`, `MMUser`, `MMChannel`, `MMPreference`, `MMReaction`, `MMStatus`, `MMPing`, `MMServerErrorPayload`) with upstream-tolerant decoding. |
| `Mattermost/Core/MM/MMBaseURL.swift` | 80 | Per-server URL resolution: `/api/v4` under a sub-path install, explicit ports, `https→wss` / `http→ws`, reliable-WebSocket query parameters. |
| `Mattermost/Core/MM/MMPagination.swift` | 86 | `MMPostPage` cursors (`page`/`per_page`, `before`, `after`, `since`) + `nextOlderPage(from:)` / `nextNewerPage(from:)` derived from the server's `order`/`has_next`. |
| `Mattermost/Core/MM/MMError.swift` | 92 | Typed errors: `unauthorized`, `forbidden`, `notFound`, `rateLimited(retryAfter:)`, `server(status:message:)`, `client`, `mfaRequired`, `invalidMFA`, `timeout`, `offline`, `certificateUntrusted(origin:)`, `cancelled`, `malformedResponse`, `transport`, `invalidURL`, `notSignedIn`. Plus `APITransportError` (pre-HTTP transport failures). |
| `Mattermost/Core/MM/APITransport.swift` | 253 | `APITransport` protocol (the test seam), `APIRequest`/`APIResponse`, `URLSessionTransport`, and `TransportSessionDelegate` — one delegate that serves TLS server trust for HTTP **and** `wss`, consulting the webview's `CertTrust` bag. |
| `Mattermost/Core/MM/APIClient.swift` | 376 | async/await REST v4 client: bearer auth from the vault, typed decode, ETag/`If-None-Match` + 304 replay, retry with exponential backoff + jitter honouring `Retry-After` (**clamped to `maxDelay`**, §7b F4), `401 → onUnauthorized`. |
| `Mattermost/Core/MM/MMEndpoints.swift` | 92 | Typed endpoint wrappers used by this card and inherited by screens: `ping`, `currentUser`, `posts(channelID:page:)`, `thread(rootPostID:)`, `post(id:)`, `channel(id:)`, `users(ids:)`, `preferences`, `statuses`. |
| `Mattermost/Core/MM/AuthSession.swift` | 238 | Login, MFA, session restore, logout, SSO adoption (cookie-store reader only — the take-a-token entry point was removed in §7b F9), 401 → re-auth surfacing. Credentials in the **existing** `SecureVault` (`authToken` + `userID`). |
| `Mattermost/Core/MM/WebSessionAdoption.swift` | 86 | Reads the `HttpOnly` `MMAUTHTOKEN` cookie the webview already holds via **that server's** `WKWebsiteDataStore(forIdentifier:)` (§7b F1) + pure `SessionCookiePolicy` matching. |
| `Mattermost/Core/MM/ServerTrustPolicy.swift` | 105 | The pure TLS decision matrix (third party / public chain / recorded accept / recorded refusal / prompt) shared by HTTP and `wss`. |
| `Mattermost/Core/MM/SocketEvent.swift` | 243 | `MMSocketFrame` + the typed `SocketEvent` matrix (hello, posted, post_edited, post_deleted, channel_viewed, typing, status_change, preferences_changed, user_updated, reaction_added/removed, `unhandled(name:)`) with **narrow** replay keys — post/user revisions and hello only (§7b F3). |
| `Mattermost/Core/MM/SocketClient.swift` | 475 | Actor-based WebSocket v4 client: bearer upgrade header **and** in-band authentication challenge, hello, 30 s ping with missed-pong timeout, exponential backoff with jitter that only resets after a *stable* session (§7b F2), one resync per dropout (§7b F5), narrow cross-reconnect replay suppression, multi-subscriber typed stream. `WebSocketTransport` is the `URLSessionWebSocketTask` implementation sharing the same trust delegate. |
| `Mattermost/Core/Logger.swift` *(modified, +11)* | — | `#if DEBUG` `Logger.testSink` so tests can prove what would be logged. Cannot exist in a Release binary. |
| `MattermostTests/{APIClientTests,AuthSessionTests,SocketClientTests,ServerTrustPolicyTests,TokenLoggingTests,SelfSignedTrustTests,T28TestSupport}.swift` | 2 311 | 88 tests (85 green + 3 fixture/gated skips in the ordinary offline run; the TLS fixture run executes the 2 self-signed ones too). |
| `scripts/t28-token-grep.sh` | 122 | The static half of the grep the card asks for, as a runnable check (exit 0/1): source patterns **multi-line-aware** plus a scan of every committed `docs/**/*.log` (§7b F6). |
| `scripts/t28-selfsigned-check.sh`, `scripts/t28_selfsigned_fixture.py` | 76 + 117 | Generates a throwaway self-signed cert for 127.0.0.1, serves `/api/v4/system/ping` over HTTPS **and a WebSocket upgrade on `/api/v4/websocket`**, runs `SelfSignedTrustTests`, prints `RESULT: PASS/FAIL` — and refuses to pass if the wss test skipped. |

## 2. Library evaluation (card item 5: "prefer an existing tested library")

A maintained Swift Mattermost SDK exists and was evaluated, not dismissed:

- **`randomsnowflake/MattermostSwift`** (unofficial, pre-1.0.0, Swift Package Index score 90,
  REST + WebSocket + SwiftData cache). Read in this run: `Package.swift`,
  `Sourcecode/MattermostSwift/MattermostClient.swift`.
- **Blocking facts, verified from the files:** `Package.swift` declares
  `.iOS(.v18), .macOS(.v15)` and `swiftLanguageModes: [.v6]`; this app targets
  `IPHONEOS_DEPLOYMENT_TARGET = 17.0` / `MACOSX_DEPLOYMENT_TARGET = 13.0` in Swift 5 language mode
  (`Mattermost.xcodeproj/project.pbxproj`). Adopting it raises the app's deployment target and
  ships a second, opinionated state layer (SwiftData cache) that collides with T29's SQLite store.
  It has no hook for this repo's per-origin `CertTrust` bag (it does accept an injected
  `URLSession`/delegate, so a fork could be made to work — another reason not to pin to it), and it
  owns token handling end to end, which conflicts with the card's "reuse `SecureVault`" rule.
- **Also reviewed:** `mattermost/react-native-network-client@1.11.4` (Apache-2.0, the mobile app's
  native networking/WebSocket layer). It is the authority for the URLSession + WebSocket design and
  is cited in `docs/THIRD_PARTY_NOTICES.md`; it is an RN bridge module, not importable from Swift.

**Decision: hand-roll on top of Apple's frameworks, porting the upstream *shapes*.** Recorded here
as the card requires. The alternative (a pre-1.0 third-party SDK that forces a platform bump and a
competing cache) is a bigger risk than 1 700 lines of tested, per-server transport code.

## 3. Source of truth: what was ported, what was only read

Read before writing (all Apache-2.0, pinned mobile `v2.45.0` = `162f2560…`):

`ios/Gekidou/Sources/Gekidou/Networking/{Network,Network+Posts,Network+Channel,Network+Team,
Network+Thread,Network+Users,Network+Category,Network+Error,Network+Delegate}.swift`,
`ios/Gekidou/Sources/Gekidou/SessionAttributes/SessionAttributesOutboundHeader.swift`,
`ios/Gekidou/Sources/Gekidou/DataTypes/{Post,PostResponse,User}.swift`,
`app/client/websocket/index.ts`, `app/client/rest/error.ts`.

**Ported (structure/behaviour, with a header naming the upstream file):**
`/api/v4` prefixing and bearer + `X-Requested-With` headers (Network.swift), the endpoint paths and
query shapes (Network+Posts/Channel/Users), tolerant model decoding (DataTypes), the WebSocket
protocol behaviour — `authentication_challenge`, hello, ping/pong every 30 s with a missed-pong
timeout, sequence tracking, reconnect loop (app/client/websocket/index.ts), and the typed error
vocabulary (rest/error.ts).

**Not ported, deliberately:**
- Gekidou's bundled **certificate pinning** list (`loadPinnedCertificates` + `Network+Delegate`'s
  hard-cancel on pin mismatch). This app's trust model is the user-confirmed per-origin `CertTrust`
  bag the webview already uses; a pinning list would fail every server that is not in it.
- Gekidou's `Keychain`/`Database` singletons — `SecureVault` (existing) and T29's store own those.
- `SessionAttributesOutboundHeader` (the `X-MM-Session-Attributes` header). The hook is designed
  for the RN bridge's session bookkeeping; there is no native session-attribute producer yet, so
  adding a header with no source would be a lie on the wire. Recorded as follow-up: when T30's
  native shell has session state, extend `APIClient.perform` with the header.

## 4. Acceptance criteria → evidence

| Criterion | Test(s) | Result |
|---|---|---|
| success | `APIClientTests.testSuccessDecodesTypedResponseAndSkipsAuthForPing`, `testAuthenticatedRequestCarriesBearerAndRequestedWith`, `testPostEncodesBodyWithJSONContentType` | pass |
| 401 | `testUnauthorizedSurfacesReauthAndThrowsTypedError`, `AuthSessionTests.testRestoreDropsARevokedTokenAndSurfacesReauth`, `testUnauthorizedDuringASessionMarksNeedsReauthAndClearsTheVault`, `testWrongPasswordIsUnauthorizedAndDoesNotRaiseReauth` | pass |
| 403 | `testForbiddenIsTyped` | pass |
| 429 with `Retry-After` | `testRateLimitedHonoursRetryAfterThenSucceeds`, `testRateLimitedExhaustionSurfacesRetryAfter`, `testRetryAfterHTTPDateIsParsed` | pass |
| timeout | `testTimeoutIsRetriedThenSurfacesTypedTimeout`, `testOfflineIsRetriedAndSurfacedAsTypedOffline` | pass |
| malformed JSON | `testMalformedJSONIsTypedWithoutLeakingTheBody`, `testPostWithNonDecodableBodyThrowsMalformedResponse`, `AuthSessionTests.testLoginWithoutAnyTokenIsMalformedRatherThanASilentSession` | pass |
| 5xx | `testServerErrorIsRetriedWithExponentialBackoffThenSucceeds`, `testServerErrorAfterExhaustionIsTyped` | pass |
| pagination cursors round-trip | `testPageCursorRoundTripsIntoBeforeAfterQueries`, `testPaginationStopsWhenServerSaysNoMore`, `testPageCursorClampsPerPageToTheServerMaximum`, `testSinceCursorIsMilliseconds` | pass |
| socket reconnect: one backoff sequence, resync fires, no duplicate events | `SocketClientTests.testReconnectProducesOneBackoffSequenceAndOneResync` (asserts `retryDelays == [1, 2]` and exactly one resync), `testReplayedEventsAfterReconnectAreNotDeliveredTwice` (replayed `hello`/`posted` suppressed, `p2` delivered, `duplicateEventCount == 2`), `testTypingIsNeverDeduplicated`, `testSequenceGateDropsAReplayOnTheSameConnection` | pass |
| no token in any log line | `TokenLoggingTests` (7): behavioural capture through `Logger.testSink` for login, 401 and the socket authentication frame, plus redaction primitives; **and** `bash scripts/t28-token-grep.sh` → `RESULT: PASS` | pass |
| self-signed server: native REST succeeds after trusting via `CertPromptSheet` | `SelfSignedTrustTests.testNativeCallFailsUntrustedThenSucceedsAfterTheCertificateIsTrusted` under `bash scripts/t28-selfsigned-check.sh` → `RESULT: PASS` (real HTTPS fixture on 127.0.0.1:18443) | pass |
| typed socket event matrix | `SocketClientTests.testTypedEventMatrix` (12 events including `plugin_something_new → .unhandled`) | pass |
| cert trust parity with the webview | `ServerTrustPolicyTests.testScopeMatchesWebviewCertificatePolicy` (cross-checks `WebViewContainer.CertChallengePolicy` over the host/server matrix) | pass |
| SSO hand-off keeps the webview, adopts its session | `AuthSessionTests.testAdoptingAWebviewSessionUsesTheCookieReaderAndVerifiesTheIdentity`, `testAdoptingAWebviewSessionDropsARejectedCookie`, `testCookieMatchingIsScopedToTheServersHost`, `testExpiredCookiesAreIgnored` | pass |

## 5. Divergences from upstream (required by the card, recorded here)

1. **Backoff is exponential with jitter** (`base 1 s`, `×2`, cap `60 s`, ±20 %), where mobile's
   WebSocket client is linear (`min(3 s × failCount, 5 min)` after 7 failures) and its REST client
   has no backoff at all. The card asks for exponential + jitter, and the REST side honours the
   server's `Retry-After` first (clamped to `maxDelay` — §7b F4). Since §7b F2 the socket ladder
   only resets after a connection has stayed up for `stableSessionInterval` (5 s), so upstream's
   "count failures even after an open" behaviour is matched for the accept-then-kill case.
2. **Resync is an injected closure**, not a global sync routine. The transport reports *when*
   (`.reconnected`); the caller decides *what* to refetch. This is what makes "assert resync fires
   once" testable — and since §7b F5 it really is once per dropout (the heartbeat timeout no longer
   asks for its own resync).
3. **Duplicate suppression is explicit and narrow** (`SocketEvent.dedupeKey`: post/user revisions
   and hello only, 512-entry window), where mobile relies on the server not replaying for
   non-reliable sockets. Events whose occurrence is the signal (`channel_viewed`, reactions,
   `status_change`, `preferences_changed`, `typing`) are never suppressed (§7b F3). The residual
   risk — a server replaying one of those after a reconnect — is a redundant refresh, not a loss.
4. **Trust is `CertTrust`-based, not pinning-based** (see §3).
5. **`Int64` milliseconds** in models instead of upstream's `Double`; **`JSONValue`** instead of
   `[String: Any]` for `props`/`metadata` (Sendable, no `Database.default.json(from:)` round-trip).
6. **MFA is a typed error first**: `POST /users/login` returning the documented
   `api.context.mfa_required` id maps to `.mfaRequired`, and the retry goes to `/users/login/mfa`.
   Wrong password (`.unauthorized`) and wrong code (`.invalidMFA`) stay distinguishable so the login
   screen can show the right copy.
7. **Per-server base URL** is component-joined (`MMBaseURL`), so sub-path installs work; upstream
   concatenates strings.

## 6. Limitations (stated, not hidden)

- **No device run.** Catalyst + iOS Simulator on this Mac; the self-signed check ran on Catalyst
  only (it needs a local TLS fixture and `openssl`, i.e. a host process).
- **No real Mattermost server was contacted** for the unit suite — by design (it must run offline).
  The HTTPS fixture is a 30-line static responder, not a Mattermost server.
- **Not wired into the UI yet.** `AuthSession`/`APIClient`/`SocketClient` are the transport layer;
  no screen calls them until T30+ per the ADR. `WebKitSessionCookieReader` is the intended SSO entry
  point but no view creates it yet (one line in the native shell card).
- **`X-MM-Session-Attributes` is not sent** (§3) — no native producer exists.
- **No APNs/push path here** (T43) and no push-proxy interaction: this card is REST + WS only.
- The self-signed test **skips** when no fixture is listening; that is deliberate (the suite must
  run offline), and the check script is the evidence that it passes when the fixture exists. Since
  §7b F8 that check also drives the **real `WebSocketTransport`** over `wss` (the fixture answers
  the upgrade with one `hello` frame), and `t28-selfsigned-check.sh` now fails if that test skipped,
  so the wss trust path is executed, not inspected.
- The backoff reset uses a wall clock (`now`, injected). `stableSessionInterval` (5 s) is a
  judgement call: a server that accepts, sends `hello` and dies inside five seconds keeps the
  ladder climbing (a flap), one that survives it is a session. Tests drive the clock, so the value
  is asserted, not assumed.
- `SocketClient` reconnection uses the injected clock; the live `SystemSocketClock` only sleeps, and
  a connection that silences without closing is caught by the heartbeat (30 s ping, 1 missed pong),
  not by a TCP keepalive.
- A **Catalyst/XCTest quirk** on this host: when an assertion fails inside an `async @MainActor`
  test, XCTest's issue recording deadlocks the runner (the same wedge T26/T27 recorded while
  symbolizing failures). Two real defects were nevertheless found this way and fixed (logout did not
  clear `userID`; the source-tree scan tripped a TCC prompt) — see §7. Tests that pass do not
  deadlock.

## 7. Defects found and fixed during implementation

1. **`logout()` left the `userID` secret behind.** Caught by
   `testLogoutClearsStoredCredentialsEvenWhenTheServerCallFails`; `logout` now clears both
   `authToken` and `userID` (a sign-out is a full clear; a 401 still clears only the token, because
   the identity is still useful for the re-auth prompt).
2. **A source-tree scan inside the test bundle hung** (a Catalyst app reading `~/Documents` blocks
   on a TCC prompt that never resolves headlessly). Removed from the suite; the same check now runs
   from the shell (`scripts/t28-token-grep.sh`) where it belongs.
3. **`CodingKeys` flattening bug** in `MMSocketFrame` (`try?` on `decodeIfPresent` produced a
   double optional that did not compile) — fixed before the first green run.
4. **`MMBaseURL.websocket()` built components from a `URL`** instead of `URLComponents`, which
   cannot mutate `scheme` — fixed before the first green run.

## 7b. T28-R repair — the T28-AV findings (F1–F9)

T28-AV (`t_4064841e`) audited HEAD `027ddeb` with `av_probes.swift` and found nine defects on top of
a passing acceptance suite. Each entry below: the probe that caught it, the fix, and the test that
now holds the line. Two are worth reading closely — F6(a) is **not** a defect (the auditor's tool
redacted the very input it was checking), and F2's fix is a heuristic with a stated interval.

| # | Severity | Verdict | Fix | Regression test(s) |
|---|---|---|---|---|
| F1 | HIGH | fixed | reader bound to the server's store; no default-argument init | `AuthSessionTests.testProductionReaderReadsTheServersOwnStoreAndNoOther`, `testAdoptingAWebSessionEndToEndThroughThePerServerCookieStore` |
| F2 | MEDIUM | fixed | ladder resets only after `stableSessionInterval` of open | `SocketClientTests.testRepeatedOpenThenInstantCloseEscalatesTheBackoffLadder`, `testALongLivedSessionThenADropStartsTheLadderAtBase`, `testALongLivedSessionResetsAnAlreadyClimbedLadder` |
| F3 | MEDIUM | fixed | replay keys narrowed to identities that cannot recur | `testTwoChannelViewedEventsOnOneConnectionAreBothDelivered`, `testAReAddedReactionIsDelivered`, `testOnlyReplayableIdentitiesCarryADedupeKey` |
| F4 | MEDIUM-LOW | fixed | server `Retry-After` clamped for the sleep only | `APIClientTests.testAbsurdRetryAfterIsClampedForTheSleepAndKeptInTheError` |
| F5 | LOW | fixed | heartbeat timeout no longer asks for a resync | `SocketClientTests.testHeartbeatTimeoutRecyclesTheConnectionAndResyncsOnceAfterTheReconnect` |
| F6 | LOW | (a) **not a defect**, (b) fixed | tests made self-proving; script is multi-line-aware and scans logs | `TokenLoggingTests` + `scripts/t28-token-grep.sh` (both directions exercised) |
| F7 | LOW | fixed | the upgrade really does carry `Authorization` | `testHandshakeHeadersCarryTheBearerTokenWhenOneIsConfigured`, `testHandshakeHeadersOmitAuthorizationWithoutAToken` |
| F8 | LOW | fixed | real `wss` exercised against the TLS fixture | `SelfSignedTrustTests.testRealWebSocketTransportOpensOnlyAfterTheCertificateIsTrusted` |
| F9 | LOW | fixed | take-a-token entry point deleted | (its two tests were deleted with it; `adoptWebSession` keeps its three) |

**F1 — the SSO reader read the wrong `WKWebsiteDataStore` (HIGH).**
Probe: a cookie written to `WKWebsiteDataStore(forIdentifier: serverA)` was returned by a reader
built on that store, returned `nil` by one built on `.default()`, and `nil` by
`WebKitSessionCookieReader()` — i.e. the production-shaped call. Every real server writes its session
into a per-server store (`ViewStore.ensureStore(for:)` → `WebViewStore(dataStoreIdentifier:)`), so
the SSO hand-off would have reported `notSignedIn` on every real sign-in.
Fix: `init(serverID:)` builds `WKWebsiteDataStore(forIdentifier:)`; there is **no** initializer with
a defaulted store, so the buggy call shape cannot be written again; an explicit `init(dataStore:)`
remains for callers that already hold a store. The cookie list is fetched with the async
`httpCookieStore.allCookies()` (same call `Diagnostics` already made).
Tests: two server UUIDs, one cookie — the owning server's reader returns it, the other server's
reader and the shared `.default()` store return `nil` (cross-server leak stays impossible), and the
full `adoptWebSession(using: WebKitSessionCookieReader(serverID:))` hand-off adopts it end to end.
Proven to bite: setting `init(serverID:)` back to `.default()` made the test fail (the runner then
wedges on failure recording — the known Catalyst quirk in §6 — which is what the interrupted log
shows).

**F2 — repeated kills hammered the server (MEDIUM).**
Probe: six `opened → closed` cycles produced `retryDelays == [1, 1, 1, 1, 1, 1]`, because
`run()` reset `attempt` on `.opened`.
Fix: `.opened` no longer touches the ladder. When a connection ends, the ladder resets only if the
connection stayed up for `Configuration.stableSessionInterval` (5 s, measured with an injected
`now`); otherwise it keeps climbing, so an accept-then-kill server backs off 1 → 2 → 4 → 8 …
Tests: 4 flap cycles assert `[1, 2, 4, 8]` (strictly escalating), one long-lived session then a
drop asserts `[1, 2]` (the card's acceptance), and a ladder already at 2 goes *back* to 1 after a
long-lived session (`[1, 1, 2]`), so the reset is a reset and not a no-op. The original
`testReconnectProducesOneBackoffSequenceAndOneResync` still asserts `[1, 2]`.
Proven to bite: setting `stableSessionInterval` to 0 reproduced the probe line by line —
`connection lost; attempt 1 in 1.00s` on every cycle instead of a climbing attempt number.

**F3 — duplicate suppression swallowed legitimate repeats (MEDIUM).**
Probe: two `channel_viewed` (seq 1, 2) → one delivered, one "duplicate"; `reaction_added →
reaction_removed → reaction_added` lost the re-add.
Fix: `SocketEvent.dedupeKey` now exists only for identities that cannot legitimately recur — `hello`,
post revisions (`id` + `update_at` + `delete_at` via `posted`/`post_edited`/`post_deleted`) and user
revisions (`id` + `update_at`). `channel_viewed`, `status_change`, `preferences_changed`, both
reaction events and `typing` are never suppressed. Residual risk, accepted and written into the
code: a server replaying one of those after a reconnect costs a redundant refresh — the opposite
trade, and the right one, because the old behaviour lost real events.
Tests: both `channel_viewed` delivered with `duplicateEventCount == 0`; the re-added reaction
delivered; a table test pins which events carry a key; the replayed-`posted`-after-reconnect test
still suppresses the replay and still counts two duplicates.

**F4 — `Retry-After` was uncapped (MEDIUM-LOW).**
Probe: `Retry-After: 86400` made `APIClient.perform` sleep 86 400 s, ignoring `maxDelay` (20 s).
Fix: the **slept** delay is `min(serverValue, retryPolicy.maxDelay)`; `MMError.rateLimited(retryAfter:)`
still carries the server's exact value, so a screen can say "try again in X".
Test: 429 + `Retry-After: 86400` sleeps exactly `[20]` and then throws `.rateLimited(retryAfter: 86400)`.

**F5 — one dropout resynced twice (LOW).**
Fix: `heartbeatTick()` recycles the connection without calling `resync`; the reconnect's
`.reconnected` is the single refetch point. `ResyncReason.heartbeatTimeout` was removed rather than
left dead.
Test: heartbeat timeout → `resyncCount == 0` and no reason recorded; the reconnect then yields
exactly `[.reconnected]` and `resyncCount == 1`.

**F6 — token evidence was weaker than it claimed (LOW).**
(a) **Not a defect.** The AV reported two vacuous assertions at `TokenLoggingTests:49` and `:171`
("`abc.def-123` / `def456` are not in the input"). They are: `grep -c 'abc\.def-123'` finds it twice
— line 48 (the `MMLog.redact` input) and line 49 (the assertion) — and `def456` likewise at 168/171.
The audit's tooling redacts `Bearer <credential>` in *its own output*, so the input line it read had
already been masked. Confirmation that the file really says so: the repair edits matched those exact
literals in place.
Hardened anyway, because a test that cannot show its own fixture contains the secret is one edit
away from vacuity: both tests now build the input by interpolation (`"… Bearer \(bearerSecret) …"`)
and assert `input.contains(secret)` **before** asserting the redaction, so the fixture self-check
fails loudly if someone neuters it.
(b) Fixed. The script's docstring now states it is the static half and points at `TokenLoggingTests`
for behaviour. Check 1b reassembles `Logger`/`MMLog` calls that span lines (awk, paren-balanced) before
matching — the old single-line grep missed exactly that shape. New check 4 scans every committed
`docs/**/*.log` for `Bearer <16+ chars>`, `MMAUTHTOKEN=<value>` and JSON `"token": "<value>"`
(`<redacted>` placeholders do not match). Both new checks were exercised: a planted two-line log
call and a fake `Bearer PROBE…` log line each turned the script red (`RESULT: FAIL`); with them
removed it passes over 30 committed log files.

**F7 — the header comment described an `Authorization` header that was never sent (LOW).**
Fix (the card's first option): `Configuration.headers` adds `Authorization: Bearer <token>` when a
token is configured, so the upgrade carries the bearer *and* the in-band challenge the comment
describes. The dictionary goes straight to the transport factory and is never logged; `TokenLoggingTests`
asserts the token is present in the header and absent from every captured log line.
Tests: header present with a token, absent without one.

**F8 — the real `WebSocketTransport` was untested (LOW).**
Fix: the TLS fixture is now a `ThreadingHTTPServer` that also answers `GET /api/v4/websocket` with
`101 Switching Protocols`, one unmasked `hello` text frame and a clean close. The new test drives the
real `URLSessionWebSocketTask` transport: the untrusted certificate fails the handshake (typed
`.failed` + a `CertificatePrompt`), recording the decision in `CertTrust` (what `CertPromptSheet`'s
Trust button does) makes the same transport open and receive `hello`. The check script now fails if
this test skipped, so a fixture-less run cannot pass silently.
Evidence: `docs/t28-selfsigned-2026-10-24.log` — `fixture: wss: upgrade accepted for
/api/v4/websocket`, `Executed 3 tests, with 0 failures`, `** TEST SUCCEEDED **`, `RESULT: PASS`.

**F9 — an unused take-a-token entry point (LOW).**
Fix: `AuthSession.adoptSSOSession(token:userID:username:)` deleted, with its two tests. The cookie
reader is the only producer of an SSO session, and the type's doc comment says so — a future JS
bridge has nothing to hand a token to.

## 8. Verification (commands and the runner's own verdict)

```
# Mac Catalyst, full unit suite
xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath build/ddata-t28 \
  -only-testing:MattermostTests DEBUG_INFORMATION_FORMAT=dwarf
  -> Executed 441 tests, with 2 tests skipped and 0 failures (0 unexpected) in 4.114 s
  -> ** TEST EXECUTE SUCCEEDED **      (log: docs/t28-catalyst-unit-2026-10-24.log)

# iOS Simulator (iPhone 16 Pro, iOS 18.3), full unit suite
xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=iOS Simulator,id=81A7F251-8B31-4945-8783-5A264C14B8D5' \
  -derivedDataPath build/ddata-t28-ios -only-testing:MattermostTests DEBUG_INFORMATION_FORMAT=dwarf
  -> see docs/t28-ios-unit-2026-10-24.log

# token grep (acceptance criterion "grep proves it")
bash scripts/t28-token-grep.sh
  -> RESULT: PASS — no token can reach a log line from the native transport layer

# self-signed TLS end to end
bash scripts/t28-selfsigned-check.sh 18443
  -> Executed 2 tests, with 0 failures (0 unexpected)
  -> RESULT: PASS — native TLS succeeds after the certificate decision is recorded in CertTrust
     (log: docs/t28-selfsigned-2026-10-24.log)

# T28-R re-run (repair round, 2026-10-24) — the numbers above are the T28 run, these are HEAD
xcodebuild test ... -derivedDataPath build/ddata-t28r -only-testing:MattermostTests DEBUG_INFORMATION_FORMAT=dwarf
  Mac Catalyst         -> Executed 451 tests, with 3 tests skipped and 0 failures (log: docs/t28r-catalyst-unit-2026-10-24.log)
  iPhone 16 Pro 18.3   -> Executed 451 tests, with 3 tests skipped and 0 failures (log: docs/t28r-ios-unit-2026-10-24.log)
  -> ** TEST SUCCEEDED ** on both (grepped, not inferred from xcodebuild's exit code)
  the 3 skips: MentionPollerTests.testLiveMentionsFetch_optIn (pre-existing opt-in live test) and the
  two certificate-fixture tests, which run and pass under scripts/t28-selfsigned-check.sh below.

bash scripts/t28-token-grep.sh
  -> 30 log files scanned; RESULT: PASS (the two new checks were first proven to fail — see §7b F6)

bash scripts/t28-selfsigned-check.sh 18443
  -> fixture: wss: upgrade accepted for /api/v4/websocket
  -> Executed 3 tests, with 0 failures (0 unexpected)
  -> RESULT: PASS — native TLS succeeds after the certificate decision is recorded in CertTrust
     (log: docs/t28-selfsigned-2026-10-24.log)
```

New-suite counts (Catalyst, after T28-R): `APIClientTests` 28, `AuthSessionTests` 20,
`SocketClientTests` 19, `ServerTrustPolicyTests` 11, `TokenLoggingTests` 7, `SelfSignedTrustTests` 3
(2 fixture-gated skips offline) — 88 tests across the T28 suites, all green (85 in the offline run).
