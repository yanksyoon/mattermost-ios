# T28 build note — native transport: AuthSession + REST v4 client + WebSocket v4 client

- **Status:** delivered 2026-10-24. Handed to **T28-AV** (adversarial validation).
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
| `Mattermost/Core/MM/APIClient.swift` | 372 | async/await REST v4 client: bearer auth from the vault, typed decode, ETag/`If-None-Match` + 304 replay, retry with exponential backoff + jitter honouring `Retry-After`, `401 → onUnauthorized`. |
| `Mattermost/Core/MM/MMEndpoints.swift` | 92 | Typed endpoint wrappers used by this card and inherited by screens: `ping`, `currentUser`, `posts(channelID:page:)`, `thread(rootPostID:)`, `post(id:)`, `channel(id:)`, `users(ids:)`, `preferences`, `statuses`. |
| `Mattermost/Core/MM/AuthSession.swift` | 268 | Login, MFA, session restore, logout, SSO adoption, 401 → re-auth surfacing. Credentials in the **existing** `SecureVault` (`authToken` + `userID`). |
| `Mattermost/Core/MM/WebSessionAdoption.swift` | 96 | Reads the `HttpOnly` `MMAUTHTOKEN` cookie the webview already holds via `WKWebsiteDataStore.httpCookieStore` (shell side only, never page JS) + pure `SessionCookiePolicy` matching. |
| `Mattermost/Core/MM/ServerTrustPolicy.swift` | 105 | The pure TLS decision matrix (third party / public chain / recorded accept / recorded refusal / prompt) shared by HTTP and `wss`. |
| `Mattermost/Core/MM/SocketEvent.swift` | 254 | `MMSocketFrame` + the typed `SocketEvent` matrix (hello, posted, post_edited, post_deleted, channel_viewed, typing, status_change, preferences_changed, user_updated, reaction_added/removed, `unhandled(name:)`) with per-event dedupe keys. |
| `Mattermost/Core/MM/SocketClient.swift` | 430 | Actor-based WebSocket v4 client: authentication challenge, hello, 30 s ping with missed-pong timeout, exponential backoff with jitter, one resync per reconnect, cross-reconnect duplicate suppression, multi-subscriber typed stream. `WebSocketTransport` is the `URLSessionWebSocketTask` implementation sharing the same trust delegate. |
| `Mattermost/Core/Logger.swift` *(modified, +11)* | — | `#if DEBUG` `Logger.testSink` so tests can prove what would be logged. Cannot exist in a Release binary. |
| `MattermostTests/{APIClientTests,AuthSessionTests,SocketClientTests,ServerTrustPolicyTests,TokenLoggingTests,SelfSignedTrustTests,T28TestSupport}.swift` | 1 555 | 78 new tests (77 green + 1 fixture-gated skip in the ordinary run; the fixture run is green too). |
| `scripts/t28-token-grep.sh` | 62 | The grep the card asks for, as a runnable check (exit 0/1). |
| `scripts/t28-selfsigned-check.sh`, `scripts/t28_selfsigned_fixture.py` | 88 + 66 | Generates a throwaway self-signed cert for 127.0.0.1, serves `/api/v4/system/ping` over HTTPS, runs the self-signed test, prints `RESULT: PASS/FAIL`. |

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
   server's `Retry-After` first.
2. **Resync is an injected closure**, not a global sync routine. The transport reports *when*
   (`ResyncReason.reconnected` / `.heartbeatTimeout`); the caller decides *what* to refetch. This is
   what makes "assert resync fires once" testable.
3. **Duplicate suppression is explicit** (`SocketEvent.dedupeKey` over a 512-entry window), where
   mobile relies on the server not replaying for non-reliable sockets. The reconnect test proves a
   replayed `posted` is dropped and a genuinely new post still arrives.
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
  run offline), and the check script is the evidence that it passes when the fixture exists.
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
```

New-suite counts (Catalyst): `APIClientTests` 27, `AuthSessionTests` 20, `SocketClientTests` 11,
`ServerTrustPolicyTests` 11, `TokenLoggingTests` 7, `SelfSignedTrustTests` 2 (1 fixture-gated skip
in the offline run) — 78 new tests, all green.
