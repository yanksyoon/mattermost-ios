# T49 — the terms-of-service gate, and sign-up / forgot-password (S06, S04)

The parity gap this card closed: a server that requires custom terms showed the native sign-in,
accepted the login, and then mounted the native shell with the acceptance still outstanding — the
server refused every write and the app had no screen that said why. The inventory also had no
account creation and no password reset (S04).

Behaviour reference: `mattermost/mattermost-mobile` at `162f2560d0e1df073220f7701d5a67cc17c8abeb`
(v2.45.0) — `app/queries/servers/terms_of_service.ts` (`showToS` = licensed + enabled + not
accepted), `app/screens/terms_of_service/terms_of_service.tsx`, `app/actions/remote/terms_of_service.ts`,
`app/screens/forgot_password/index.tsx`, `app/client/rest/tos.ts`.

---

## 1. What shipped

| Surface | Native counterpart |
| --- | --- |
| TOS gate after login **and** after restore | `TermsOfServiceGate` (pure derivation) + `AuthCoordinator` (per-server state) + `TermsOfServiceView` (blocking screen) |
| Remembering the verdict across the optimistic launch window | `TermsOfServiceVerdictStore` (per-server, `UserDefaults`), read by `AuthCoordinator.authState(for:)` before `restore()` answers |
| Server-side TOS read / accept | `ServerTermsOfServiceAPI`: `GET /api/v4/terms_of_service`, `GET /api/v4/users/me`, `POST /api/v4/users/me/terms_of_service` |
| Sign-up (S04) | `SignUpView` / `SignUpViewModel` → `POST /api/v4/users`, then the verification message state |
| Forgot / reset password (S04) | `ForgotPasswordView` / `ForgotPasswordViewModel` → `POST /api/v4/users/password/reset/send`, then the confirmation state |
| The server's own rules and copy | `ServerAuthPolicy`, decoded from `GET /api/v4/config/client?format=old` |

New files:

```
Mattermost/UI/Native/Auth/TermsOfServiceGate.swift        (the rule, no I/O)
Mattermost/UI/Native/Auth/TermsOfServiceVerdicts.swift    (launch-memory store)
Mattermost/UI/Native/Auth/TermsOfServiceView.swift        (blocking screen + document webview)
Mattermost/UI/Native/Auth/ServerAuthPolicy.swift          (policy decode + account/TOS requests)
Mattermost/UI/Native/Auth/SignUpView.swift
Mattermost/UI/Native/Auth/ForgotPasswordView.swift
MattermostTests/T49TermsOfServiceTests.swift              (41 unit tests)
MattermostUITests/T49TermsOfServiceUITests.swift          (4 live tests)
scripts/t49_no_tos_proxy.py                               (the "no custom terms" fixture, §3)
docs/t49-shots/*.png                                      (evidence, §6)
```

Modified: `AuthCoordinator.swift` (verdicts, `checkTerms` on sign-in/restore/SSO, `acceptTermsOfService`,
public-client seam, sign-out clears the verdict), `LoginView.swift` ("Forgot password?" and
"Create an account" → one account sheet), `NativeShellView.swift` (the gate mounts instead of the
shell), `NativeNavigation.swift` (`NativeAuthState.termsOfServiceRequired`), `MMTypes.swift`
(`terms_of_service_id` / `terms_of_service_create_at` on `MMUser`), `MattermostApp.swift` (wiring),
`Logger.swift` (§7.1).

## 2. The rule

`TermsOfServiceGate.decide(phase:terms:)` — the card's "pure gate derivation", `AuthPhase` ×
`TermsOfServiceState` → blocked / signedIn:

| `AuthPhase` | `.unknown` | `.notRequired` | `.accepted` | `.pending` | `.unreadable` |
| --- | --- | --- | --- | --- | --- |
| `.signedIn` | signedIn | signedIn | signedIn | **TOS gate** | **TOS gate** |
| `.signedOut` | signedOut | signedOut | signedOut | signedOut | signedOut |
| `.expired` | signedOut | signedOut | signedOut | signedOut | signedOut |
| `.unresolved` | signedIn | signedIn | signedIn | **TOS gate** | **TOS gate** |
| `.signedInUnverified`, `.connecting` … | as `.signedIn` | | | | |

Three deliberate choices:

* `.unknown` is *today's behaviour*, not an acceptance: a build with no provider wired (unit-test
  hosts) and a server that was never asked must behave exactly as before T49. `.unreadable` is the
  opposite — a 5xx, a transport failure or an unparseable body is **not** an acceptance, so it blocks
  with the gate's Retry (fail closed).
* `.notRequired` is the tolerant half: `404` (no document published / feature off) and `400`
  (`custom terms of service feature is disabled`) both mean "nothing to accept". That is a **decoded
  status**, not a string sniff: the gate never looks at the body.
* The verdict is remembered per server URL, so the shell answers the gate during the optimistic
  launch window (a token is in the vault, `restore()` has not returned yet) instead of showing the
  workspace for one round trip and then yanking it. Sign-out clears it — it belonged to the
  credential that went away.

Accept is verified, not assumed: after `POST /users/me/terms_of_service` the gate re-reads
`GET /users/me` and refuses to unblock unless the server echoes the document id back. A gate that
believes its own request is the fake gate the card forbids.

## 3. Server behaviour measured on this fixture (9.11.19)

The fixture is `mm-perf` (`mattermost/mattermost-team-edition:release-9`) on `http://127.0.0.1:8065`
with `mm-perf-db` (Postgres 16). Facts measured on it, because the card asked for a live run:

1. **Custom TOS is license-gated.** `PUT /api/v4/config/patch` with
   `{"ServiceSettings":{"EnableCustomTermsOfService":true}}` answers `200`, but the value never
   appears in `GET /api/v4/config/client?format=old` and `/api/v4/license` shows no enterprise
   feature. Team Edition cannot turn the feature on through its API.
2. **The endpoints still answer** once a document exists:
   `GET /api/v4/terms_of_service` → `200 {"id","create_at","user_id","text"}`;
   `GET /api/v4/users/{id}/terms_of_service` → `200 {"user_id","terms_of_service_id","create_at"}`
   when accepted, `404 app.user_terms_of_service.get_by_user.no_rows.app_error` when not.
   `DELETE /api/v4/users/{id}/terms_of_service` does not exist (`404` "no api call for the url").
3. **The document is cached in memory.** Deleting the `termsofservice` row does not change the
   endpoint's answer until the cache expires (~15 min observed); inserting a row appears at once.
   Container restart would clear it, but container lifecycle commands are refused in this session's
   sandbox, so the "no terms" run uses the proxy in §4 instead.
4. `RequireEmailVerification=false`, `EnableUserCreation=true`, `SMTPServer=localhost` with nothing
   listening — so account creation succeeds and the reset mail **cannot** be sent (see §6.3).

Fixture SQL (document `aaaaaaaaaaaaaaaaaaaaaaaaaa`, user `jruqqzxtobg7tn4wehwmwjjo5c` = `perfprobe`):

```sql
INSERT INTO termsofservice (id, createat, userid, text)
VALUES ('aaaaaaaaaaaaaaaaaaaaaaaaaa', 1793644926809, 'jruqqzxtobg7tn4wehwmwjjo5c',
        'T49 fixture terms: accept these local test terms before your workspace mounts.')
ON CONFLICT (id) DO NOTHING;

-- pending: no acceptance row. accepted: insert one.
DELETE FROM usertermsofservice WHERE userid = 'jruqqzxtobg7tn4wehwmwjjo5c';
INSERT INTO usertermsofservice (userid, termsofserviceid, createat)
VALUES ('jruqqzxtobg7tn4wehwmwjjo5c', 'aaaaaaaaaaaaaaaaaaaaaaaaaa', <epoch ms>);
```

## 4. The "no custom terms" fixture

`mm-perf` caches its document, so it cannot be made to answer `404` on demand (§3.3).
`scripts/t49_no_tos_proxy.py` forwards every request to the real server unchanged and answers `404`
for `GET /api/v4/terms_of_service` only — the same answer a server with the feature off gives. It
logs every proxied request, which is what makes the "no gate" run evidence rather than an absence:

```
python3 scripts/t49_no_tos_proxy.py --listen 8066 --upstream http://127.0.0.1:8065 \
  --log build/logs/t49-no-tos-proxy.log
```

Measured log from the passing run (`build/logs/t49-no-tos-proxy.log`):

```
POST /api/v4/users/login 200
GET /api/v4/terms_of_service 404 (stubbed: no custom terms)
```

This is a transport fixture, not a fake gate: it never rewrites a body or a status the app reads
except the one endpoint that says "there is nothing to accept", and the *pending* half of the card
was proven against the real server's real document (§6.1).

## 5. How to run

```bash
# units — 1941 tests, 8 skipped (live suites), 0 failures
xcodebuild test-without-building -project Mattermost.xcodeproj -scheme Mattermost \
  -configuration Debug -destination 'platform=iOS Simulator,id=81A7F251-8B31-4945-8783-5A264C14B8D5' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa \
  -only-testing:MattermostTests

# live: pending terms → gate → accept → workspace (fixture reset by §3's SQL)
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<scripts/perf_seed.py> \
TEST_RUNNER_MM_TOS_STATE=pending \
xcodebuild test-without-building ... -only-testing:MattermostUITests/T49TermsOfServiceUITests

# live: a server without terms → no gate (proxy from §4)
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8066 ... TEST_RUNNER_MM_TOS_STATE=none \
xcodebuild test-without-building ... \
  -only-testing:MattermostUITests/T49TermsOfServiceUITests/testAServerWithoutTermsShowsNoGate
```

`MM_TOS_STATE` decides which fixture the run is, and every test skips (never fails) without it —
the same opt-in shape as `TEST_RUNNER_MM_LIVE_*`.

## 6. Evidence

### 6.1 Units — `MattermostTests` green

`1941 tests, 8 skipped, 0 failures` (`TEST EXECUTE SUCCEEDED`). The 41 T49 tests:

| Suite | Tests | What it pins |
| --- | --- | --- |
| `T49TermsOfServiceGateTests` | 7 | the table in §2: pending blocks, accepted passes, no-terms never gates, unreadable fails closed, unknown is today's behaviour |
| `T49AuthCoordinatorGateTests` | 12 | sign-in/restore/SSO run the check, the shell never sees `.signedIn` while pending, accept unblocks only when the server echoes the id, sign-out forgets the verdict, the remembered verdict blocks the launch window |
| `T49TermsOfServiceAPITests` | 5 | `GET /terms_of_service` shape, 404 and 400 → no terms, 5xx throws, `POST /users/me/terms_of_service` body `{termsOfServiceId, accepted:true}` |
| `T49AccountRequestTests` | 4 | `POST /users` and `POST /users/password/reset/send` bodies, no `Authorization` header, a 500 reset is an error, the policy decodes 9.11's string-valued config |
| `T49ServerAuthPolicyTests` | 5 | defaults on an older server, the 14–72 copy and rule, absent TOS key is "not stated", email shape, `terms_of_service_id` decode |
| `T49SignUpViewModelTests` | 4 | button gating, account creation + verification state, local short-password stop with the server's sentence, server copy shown verbatim |
| `T49ForgotPasswordViewModelTests` | 3 | invalid address never reaches the server, sent state, a failed send shown honestly |
| `T49LoggerConcurrencyTests` | 1 | §7.1's race |

### 6.2 Live — pending terms: gate → accept → workspace (PASS)

`Executed 4 tests, with 1 test skipped and 0 failures` in 44.4 s (`build/logs/t49-ui-final.xcresult`;
one skipped = the `MM_TOS_STATE=none` fixture). Printed by the run:

```
T49 gate state: pending, document=aaaaaaaaaaaaaaaaaaaaaaaaaa
T49 accept observed on server: user=jruqqzxtobg7tn4wehwmwjjo5c terms=aaaaaaaaaaaaaaaaaaaaaaaaaa
```

The test asserts, in order: the server has a document and the user has not accepted it (its own
`GET`s, before the app launches); after sign-in `termsOfServiceGate` exists and `nativeShell` does
not; `termsOfServiceText` carries the fixture text; after tapping Accept the shell mounts and the
gate is gone; and then — the part a screen cannot fake — `GET /users/{id}/terms_of_service` returns
`terms_of_service_id= aaaaaaaaaaaaaaaaaaaaaaaaaa`. Postgres confirms one `usertermsofservice` row
with `createat` from the run.

Screenshots: `docs/t49-shots/t49-gate-pending.png` (title, "To continue to Local Mattermost, accept
the Terms of Service this server requires.", the document text, "Read the full terms", Accept,
"Decline and sign out") and `docs/t49-shots/t49-workspace-after-accept.png` (the native shell:
sidebar, WORKSPACE, WEB VIEW, channel list).

### 6.3 Live — a server without terms shows no gate (PASS)

`testAServerWithoutTermsShowsNoGate` passed in 17.6 s against §4's proxy; the test first asserts the
fixture publishes no document, then signs in and requires `nativeShell` within 90 s and no gate after
a 3 s settle window. The proxy log is §4's.

### 6.4 Live — sign-up and forgot-password reach the server

* `testSignUpCreatesAnAccountOnTheServer` (PASS, 20.1 s): the form's own fields, submit, the
  "Check your email" state, and then `GET /api/v4/users/email/<address>` from the test process finds
  the account — the request really reached the server. Screenshot:
  `docs/t49-shots/t49-signup-result.png`.
* `testForgotPasswordReportsTheServersAnswer` (PASS, 12.3 s): the reset form submits and the app
  shows the server's own failure — `Failed to send password reset email successfully.` — because this
  fixture has no SMTP (`SMTPServer=localhost`, nothing listening). That is the honest recorded
  outcome the card allows for; the request itself is asserted end-to-end by the unit test on the
  body and by the form reaching a terminal state here. Screenshot:
  `docs/t49-shots/t49-forgot-password-result.png` (the error state, not a fake "sent").

## 7. Findings that are not the card

### 7.1 The app crashed at launch inside `Logger` — a real race, fixed

The first full `MattermostTests` run of this change **aborted before any test started**: the host
app died with `NSInvalidArgumentException: -[__NSCFNumber objectForKey:]` in `Logger.os(_:)`, reached
from `MMLog.debug` inside `APIClient.perform` during `AuthCoordinator.restoreAll`. `Logger.cache`
was an unsynchronised `static var [String: OSLog]` written from every thread that logs; T49 adds one
more concurrent reader at launch, which is what made the pre-existing race reproducible.
`Logger` now guards the cache and the level gate with an `NSLock` (`Mattermost/Core/Logger.swift`),
and `T49LoggerConcurrencyTests` exercises 32 threads × 100 lines so a regression fails the suite
instead of the app.

### 7.2 `SecureField` in a sheet takes one character per `typeText`

Measured while writing the live sign-up test: `XCUIElement.typeText` into the sign-up sheet's
`SecureField` lands **one** character (the field reads `•`, the form says "at least 8 characters"),
twice, including character-by-character entry with a delay. The same call on the sheet's plain
`TextField`, and on the sign-in form's `SecureField`, works. The test therefore fills the two secure
fields through the pasteboard (`UIPasteboard.general` + the field's Paste menu), which is a single
insertion into the same control; the form then reads `ready` and the account is created. Nothing in
the app was changed to accommodate this — it is a driver quirk, recorded here so the next person
does not "fix" the form for it.

### 7.3 Not verified

* No live server here can answer `5xx` for `/terms_of_service` on demand, so "fail closed" is proven
  by unit tests (`.unreadable("…")` and a stubbed 500), not by a live run.
* A real license-enabled Mattermost with custom TOS enabled was not available; the gate's own
  licence check is therefore *not* implemented as a separate condition. Mobile's `showToS` requires
  the licence, but on an unlicensed server the document endpoint is the only thing the client can
  see, and a client-side licence condition we cannot observe would either gate every server or none.
