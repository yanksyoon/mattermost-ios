# T41 — native user profile, presence and custom status

Card: `t_bb460e89` (validation: `t_980fc302`, adversarial). Surface: **S24** profile popover + full
profile + status setter + custom status. Gated by `-surfaceMode profile=native`; the surface is **not**
in `SurfaceDefaults.nativeApprovedSurfaces` (that list is still `[.auth]`), so nothing here is on by
default until its `-AV` card passes.

Behaviour reference: `mattermost/mattermost-mobile` @ `v2.45.0` (`162f2560…`), Apache-2.0 — read for
rules, reimplemented in SwiftUI; the exact file set is in `docs/THIRD_PARTY_NOTICES.md` §18 and
`docs/component-map.md` §S24. The webapp (AGPL-3.0) was **observed only**, never copied.

## 1. What shipped

`Mattermost/UI/Native/Profile/` — 7 files:

| File | What it owns |
|---|---|
| `ProfileModels.swift` | every **pure** rule: `MMUserProfile` (decode of `GET /users/{id}`, including the double-decoded `props.customStatus`), `UserCustomStatus` (+ `isActive`, the Go zero-time rule), `MMUserTimezone` (the string `useAutomaticTimezone`), `UserPresence`/`UserStatusSnapshot` (the four wire values, `manual`, `dnd_end_time`, the socket patch that keeps what the frame omits), `StatusDuration` (the server's own vocabulary and its expiry arithmetic), `CustomStatusBody` (the flat write, with the expiry the server demands) + `CustomStatusDraft` (validation copy), `CustomStatusEmoji`, `ProfileRoleLabel`, `AutoAwayRule`, `DMShortcut`, `ProfileDateFormat` (every string the screen draws, with an injectable clock/locale) |
| `ProfileAPI.swift` | the requests, one method each, on the same `APIClient` the rest of the app uses (`GET /users/{id}`, `POST /users/ids`, `PUT /users/{id}/status`, `PUT|DELETE /users/{id}/status/custom`, `POST /channels/direct`, `GET /users/{id}/profile_image`) |
| `ProfileService.swift` | `ProfileServing` (the test seam) + the session-backed implementation |
| `ProfileViewModel.swift` | load (profile **and** presence in parallel), the "fetched, never invented" failure state, optimistic presence and custom-status writes with rollback, the DM shortcut, the socket patch (`status_change` / `user_updated`), and the presence refresh loop |
| `ProfileCoordinator.swift` | one model per (server, user) with an LRU of 6, the per-server presence memory, the rail's socket fan-in, and the auto-away pass |
| `ProfileView.swift` | the sheet and the screen: avatar (authenticated bytes or initials), name/@username, presence row, custom-status pill, role badges, the fact rows (position, nickname, email, local time, activity, member-since), "Send message", the status-setter and custom-status entry points, banner/error/retry states |
| `StatusSetterView.swift` | the status setter (four choices + the DND clear-after picker) and the custom-status editor (emoji palette, text, clear-after, validation, save/clear) |

Host wiring (`Mattermost/`):

- `ChannelView.swift` — the pane header's `nativeProfileButton` (my own profile) and the item-bound
  profile sheet, shared with a tapped message author.
- `PostRowView.swift` — a tap on a message author's avatar opens that account's profile (inert while
  the surface resolves web, so there is never a second, native popover beside the webview's own).
- `MattermostApp.swift` — one `ProfileCoordinator` per app (bound to auth + the server store), the
  rail's socket fan-in, the `scenePhase` → auto-away trigger, and the
  `-uiTestProfilePresenceInterval` seam.
- `Core/MM/MMTypes.swift` — `MMStatus.dndEndTime` (`dnd_end_time`, epoch ms), without which a
  do-not-disturb can only be drawn as permanent.

Fixtures/probes: `scripts/t41_profile_seed.py` (the `t41-profile` channel, the second human account
`t41buddy`, one post by it, and the probe account back to `online` with no custom status) and
`scripts/t41_profile_probe.py` (the measured contract, §2). Neither carries a credential in the repo;
the fixture passwords are throwaway local values and are documented as such in both files.

## 2. The measured server contract

All of this is `scripts/t41_profile_probe.py` output against Mattermost **9.11.19** at
`127.0.0.1:8065` (transcript: `docs/t41-profile-probe-2026-10-26.log`, exit 0 — every expectation
held), not read off a type definition:

| Call | Answer |
|---|---|
| `GET /users/{id}` | `roles`, `position`, `nickname`, `timezone`, `props` — and **no** `custom_status` field |
| `props.customStatus` | a **JSON string**: `{"emoji","text","duration","expires_at"}` (decoded twice) |
| `timezone.useAutomaticTimezone` | the **string** `"true"`/`"false"`, not a bool |
| `is_bot` / `last_activity_at` on the user object | absent/null rather than `false`/`0`; `last_activity_at` is not a profile field |
| `PUT /users/{id}/status/custom` | flat body accepted; a `custom_status` wrapper is **400** `invalid_body_param` |
| durations | `""`, `thirty_minutes`, `one_hour`, `four_hours`, `today`, `this_week`, `date_and_time` accepted (with a future `expires_at`); `30m`/`1h`/`99y` → **400**; a duration **without** a future `expires_at` → **400**; `expires_at: ""` → **400** (Go cannot parse it) |
| an unknown emoji | **400** `api.custom_status.set_custom_statuses.emoji_not_found` |
| "no expiry" on the wire | the Go zero time `0001-01-01T00:00:00Z` — an ordinary *past* date |
| `GET …/status/custom` | **404**: there is no read route; the status is read from the user's props |
| `DELETE …/status/custom` | `{"status":"OK"}` |
| `PUT /users/me/status` | `{user_id, status, dnd_end_time}`; `online` comes back `manual: false`, `away`/`dnd` `manual: true`; `dnd_end_time` is epoch **ms**; anything outside online/away/dnd/offline → 400 |
| `POST /users/status/ids` | rows of `{user_id, status, manual, last_activity_at, dnd_end_time}` |
| socket `status_change` | `{user_id, status}` and **nothing else** — and it is addressed to the account that **changed** (see below) |
| `POST /channels/direct` | **201** on the first call *and* on a repeat that finds the existing conversation (same id) |
| `GET /users/{id}/profile_image` | **404** for an account without a picture (the screen draws initials) |

Three of these changed the design, and each is worth stating because the card's premise assumed
otherwise:

1. **A colleague's `status_change` never reaches this client.** The server publishes the event with
   `broadcast.user_id` set to the account that changed (`app/platform/status.go`:
   `NewWebSocketEvent(StatusChange, "", "", status.UserId, …)`), so it is delivered to **that
   account's own connections**. Measured both directions with a raw client that provably receives
   team-scoped events (`posted` for another account arrives), and on connect/disconnect too.
   Consequence: an open profile re-reads `POST /users/status/ids` every 15 s while it is open
   (`ProfileViewModel.runPresenceUpdates`, cancelled when the sheet closes) — which is how the web
   client learns a colleague's presence as well. `status_change` still matters, for **my own**
   status (another device of mine, or the auto-away echo), and the live suite measures both halves
   separately.
2. **`away` is `manual: true` on the server.** An auto-away write is therefore indistinguishable from
   a deliberate choice *by its flag alone*. The coordinator keeps the server's answer to its own
   write and hands it to the rule, so the return restores what this client changed without undoing
   somebody else's choice (§6, F1).
3. **`/users/name/{username}` is not a route on this server** (404), `/users/username/{username}` is.
   The seed script and the buddy-facing live test both used the wrong one, which made every
   buddy-dependent assertion *skip* rather than fail (§6, F3).

## 3. How it is put together

- **One coordinator, one model per (server, user), LRU 6.** The sheet is re-created on every
  presentation, `status_change`/`user_updated` arrive on the rail's single socket, and auto-away has
  to happen with no profile open at all — so the owner is app-level (the same decomposition as T40's
  `ChannelInfoCoordinator` and T33's sidebar coordinator).
- **Fetched, not faked.** A profile that is not stored is read from the server; a failed read is an
  error with a retry, never a row assembled from a user id (`testAFailedLoadIsAnErrorWithNoInventedProfile`).
- **Optimistic writes with rollback.** Presence and custom status change on screen before the round
  trip and roll back with a sentence naming what failed — a status is a promise to colleagues.
- **The setter is mine alone.** `PUT /users/{id}/status/custom` writes to the id in the path, so the
  setter and the custom-status row are drawn only on my own profile; somebody else's profile says
  why "Send message" is absent instead of presenting a control that cannot work.
- **Auto-away is a pure rule + one trigger.** `AutoAwayRule` decides; `MattermostApp`'s
  `scenePhase` observation supplies the facts and `ProfileCoordinator` performs the write.
- **Presentation has no nested sheets.** The status setter and the custom-status editor are pushes on
  the sheet's own stack — T40-AV measured a nested sheet whose confirmation action never ran, and a
  status setter that looks responsive but sends nothing is the one failure this surface cannot
  afford.

## 4. Identifiers an XCUITest can rely on

`profileSheet`, `profile.done`, `profile.loading`, `profile.name`, `profile.username`,
`profile.presence`, `profile.customStatus`, `profile.roles`, `profile.localTime`, `profile.lastActive`,
`profile.joined`, `profile.position`, `profile.nickname`, `profile.email`, `profile.avatar`,
`profile.message`, `profile.messageReason`, `profile.setStatus`, `profile.customStatusRow`,
`profile.clearStatus`, `profile.banner`, `profile.error`, `profile.retry`, `nativeProfileButton`,
`post.<postID>.avatar`, `statusSetter`, `statusSetter.option.<online|away|dnd|offline>`,
`statusSetter.current`, `statusSetter.dnd.<duration>`, `statusSetter.done`,
`statusSetter.custom`, `statusSetter.clear`, `statusSetter.banner`, `customStatus.editor`,
`customStatus.emoji.<name>`, `customStatus.text`, `customStatus.duration.<duration>`,
`customStatus.expiry`, `customStatus.validation`, `customStatus.banner`, `customStatus.save`,
`customStatus.clear`, `customStatus.cancel`.

## 5. Evidence

_Measured on this host; logs in `build/logs/` (gitignored) and shots in `docs/t41-shots/`._

| What | Command | Result |
|---|---|---|
| Probe (server contract) | `uv run --with websockets python3 scripts/t41_profile_probe.py --log docs/t41-profile-probe-2026-10-26.log` | exit 0 — every expectation held; transcript committed |
| Catalyst unit suite | `python3 scripts/qa-test.py --platform mac --only-testing MattermostTests --label t41-units8` | **1,378 run / 4 skipped / 0 failed**, `TEST SUCCEEDED` (`build/logs/t41-units8.log`); T41 = **72** of them (64 `T41ProfileTests` + 8 `T41ProfileAPITests`) |
| Live UI suite | `TEST_RUNNER_MM_AUTH_*=… python3 scripts/qa-test.py --platform ios --sim id=81A7F251… --only-testing MattermostUITests/T41ProfileUITests --label t41-suite8` | **7 run / 0 skipped / 0 failed** in 157 s, `TEST SUCCEEDED` (`build/logs/t41-suite8.log`; `t41-suite7.log` also 7/7 before it) |
| Screenshots | `python3 scripts/t37_export_shots.py <that run's .xcresult> docs/t41-shots` | 7 exported (below) |

The four skips in the unit suite are pre-existing and unrelated (CertTrust/Keychain ×1, MentionPoller
live opt-in ×1, SelfSignedTrust ×2).

### 5.1 The live suite, test by test

iPhone 16 Pro, iOS 18.3.1 simulator, real server `127.0.0.1:8065`, app launched through
`scripts/qa-test.py` with `TEST_RUNNER_MM_AUTH_*`:

| # | Test | Asserts, against the **server** as oracle | Shot |
|---|---|---|---|
| 1 | `testBackgroundingAgesMyPresenceAndForegroundRestoresIt` | backgrounding writes `away` (`manual: true`), returning writes `online` back — `GET /users/{me}/status` read by the test process | `t41-auto-away-returned.png` |
| 2 | `testChoosingDoNotDisturbReachesTheServer` | tapping "Do not disturb" in the setter leaves `dnd` on the server, and the sheet's row says so | `t41-presence-dnd.png` |
| 3 | `testCustomStatusIsStoredThenClearedOnTheServer` | the emoji + text written in the editor appear in the account's `props.customStatus` (read by a **second** session), and clearing removes them | `t41-custom-status.png` |
| 4 | `testMyOwnPresenceFollowsTheSocketImmediately` | another session writes my status; the open profile follows **within 10 s while the batch poll is pushed out to 120 s** — so only `status_change` can explain it | `t41-presence-socket.png` |
| 5 | `testPresenceFollowsAnotherClientsChangeWhileTheProfileIsOpen` | the buddy's **own** session writes `dnd`, then `away`; the open profile follows both, at a 3 s poll | `t41-presence-follows-server.png` |
| 6 | `testProfilePopoverShowsTheServersOwnIdentity` | the sheet's name/username/roles/local-time rows are the server's values for that account | `t41-my-profile.png` |
| 7 | `testSendMessageOpensTheDirectChannelWithTheAuthor` | the DM the server holds between the two accounts is the channel the app opens | `t41-send-message.png` |

### 5.2 The runs that died, and their cause

Two runs failed with **`Lost connection to the application`** — the app killed by `SIGSEGV` (launchd:
`exited due to SIGSEGV | sent by exc handler`, after 41.6 s), always inside the peer-presence test
while it polled the accessibility tree every 0.25 s for up to 40 s, and with no crash report produced
anywhere on the host or in the simulator container.

The cause is the harness, not this surface, and T40-R had already found and named it: XCTest injects
`XCTAutomationSupport` into the **app** process and a UI run makes it log one os_log *fault* per
captured runtime issue; libtrace then quarantines that process
(`__LIBTRACE_CLIENT_QUARANTINED_DUE_TO_HIGH_LOGGING_VOLUME__`) and the next accessibility snapshot
dereferences a NULL (`_platform_strcmp` under `runtime_issue_os_log_fault_callback`). Two crash
reports from T40's suite are the same signature. The volume is what a screenshot-polling test
maximises, which is why this test hit it and the short ones did not.

Applied here, as there: `app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"` plus
`-uiTestLogLevel error` in `launchApp` (test-only; the app is unchanged). Additionally this test now
launches with `-uiTestProfilePresenceInterval 3`, so its two waits are 15 s rather than 40 s — its
runtime fell from 62–84 s to 25 s. With both in place the suite is **7/7 in `t41-suite7` and
`t41-suite8`** (157 s).

## 6. Defects this round found and fixed

Each was found by an executable check, not by reading the code:

| # | Defect | How it showed | Fix |
|---|---|---|---|
| F1 | **Auto-away never reverted.** `AutoAwayRule.onForeground` refused to restore because this client's own `away` write comes back `manual: true`, so the "somebody else changed it" guard matched it. | the live auto-away test: background aged the server to `away`, then coming back left it `away` | `onForeground(…, ownWrite:)` — the server's answer to *our* write is the one manual status the return may undo; the coordinator keeps it (`autoAwayWrites`). Pinned by `testTheClientsOwnAwayWriteIsTheOneManualStatusTheReturnMayUndo`. |
| F2 | **A do-not-disturb could never show its end time.** `ProfileViewModel.snapshot(from:)` dropped `dnd_end_time`, so "Do not disturb until 4:15" was dead code. | reading the decoder against the probe's row shape | `MMStatus.dndEndTime` + the mapping; pinned by `testThePresenceSnapshotKeepsTheDoNotDisturbEndTime`. |
| F3 | **Every buddy-dependent assertion skipped instead of running.** `/users/name/{username}` is 404 on 9.11.19 (the route is `/users/username/{username}`), so the seed re-tried to create the account, the probe reported "no buddy", and the live test's `XCTSkip` hid it. | the seed failed with `username_exists`, then the probe printed `SKIP no buddy account` | all three fixed to `/users/username/…`; the probe now re-measures §4/§6 instead of skipping. |
| F4 | **`POST /channels/direct` does not answer 200 on a repeat.** The header claimed 201-then-200; the probe measured **201 both times** (same id). The code accepts any 2xx, so this was a documentation defect — corrected rather than left as a plausible-looking claim. | probe §6 | comment corrected in `ProfileAPI.swift`; the probe asserts 2xx + same id. |
| F5 | **The probe the code cites did not exist.** Three source files and both test files referenced `scripts/t41_profile_probe.py` and `docs/t41-profile-probe-2026-10-26.log`; neither was in the tree. | `ls scripts/t41* docs/t41*` | probe written and run; transcript committed. |
| F6 | **Peer presence assumed to arrive over the socket.** The card's first acceptance criterion assumed `status_change` carries a colleague's change; it does not (§2.1). Without a read loop the row froze at whatever the first read said. | the live socket test: the server said `dnd`, the screen still said `Online` | the presence refresh loop (§3) + the criterion split into two measured halves (a peer's change through the batch, my own through the socket). |
| F7 | **The DND "clears after" list drew every choice twice** — an inline `Picker` *and* the four buttons, so eight rows and two ticks on "30 minutes". | looking at the run's own screenshot (`docs/t41-shots/t41-presence-dnd.png`) instead of trusting the test's pass | the picker is gone; the rows are the control (they carry the identifiers the test taps), and the shot was re-exported from the run after the fix. |
| F8 | **The auto-away preference was overwritten by the server's own echo** of this client's `away` write: the coordinator adopted every `status_change` about my account as "a choice made elsewhere", so the return found nothing to put back and left the reader away. | the same live test, after F1 was fixed: background → `away` on the server, foreground → still `away` | `AutoAwayRule.adoptsSocketStatus` — an `away` frame is ignored as a preference while this client owns an auto-away; any other value (dnd, offline) still wins. Pinned by `testTheEchoOfMyOwnAutoAwayWriteDoesNotBecomeMyPreference`. |

## 7. What is measured, and what is not

The live suite drives the real app against a real 9.11.19 server and asserts **the server** as the
oracle wherever the criterion is about persistence. What it deliberately does not cover:

- The **browser** half of "appears on other clients": the custom status is asserted from the account's
  own `props.customStatus` (the same field the web client renders) and from the server's answer to a
  *second* session, but this run did not drive the web app itself — the headless browser available to
  this session could not establish a web session (the web client's login flow refuses a cookie
  injected by script). That verification is left to the `-AV` card, which can sign in interactively.
- Auto-away is measured on iOS only: `XCUIDevice.press(.home)` does not exist on Mac Catalyst, so the
  test **skips** there by name rather than pretending (`#if targetEnvironment(macCatalyst)`).
- The status setter's DND clear-after picker is unit-pinned (`StatusDuration`) and drawn by the live
  tap, but no live test picks an expiry; the write it would send is covered by
  `testTodayIsSentWithTheEndOfDayExpiry` / `testAFixedDurationAlwaysCarriesAFutureExpiryInRFC3339WithMilliseconds`.
- A peer's presence is polled every 15 s while a profile is open; a change made while the **sheet is
  closed** appears on the next open (one read). There is no background presence subscription, and
  none is possible over this server's socket (§2.1).
- The avatar is fetched through `APIClient` (an `AsyncImage` could not carry the bearer); the fixture
  accounts have no picture, so the live shots show the initials fallback. A real picture's bytes are
  unit-tested through the service seam only.
- Local time, member-since and activity strings are unit-pinned with an injected clock and locale;
  the live test only asserts the local-time row exists.
