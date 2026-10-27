# T40 — native channel info, membership and channel management

Card: `t_5799c879` (validation: `t_06786ced`, adversarial). Surface: **S22** channel info + add
members, **S23** member list / manage, **S24** browse channels, plus leave, channel settings and
archive/unarchive. Gated by `-surfaceMode channelInfo=native`; the surface is **not** in
`nativeApprovedSurfaces` (that list is still `[.auth]`), so nothing here is on by default until its
`-AV` card passes.

Behaviour reference: `mattermost/mattermost-mobile` @ `v2.45.0` (`162f2560…`), Apache-2.0 — read for
rules, reimplemented in SwiftUI; the exact file set is in `docs/THIRD_PARTY_NOTICES.md` §17 and
`docs/component-map.md` §S22–S24. The webapp (AGPL-3.0) was **observed only**, never copied.

## 1. What shipped

`Mattermost/UI/Native/ChannelInfo/` — 14 files, 3,494 lines:

| File | What it owns |
|---|---|
| `ChannelInfoModels.swift` | every **pure** rule: the channel kind, the default channel, `ChannelInfoCapabilities.derive` (all gates from permission ids), `offeredActions`, `ChannelPatchDraft` (limits, `isDirty`, a diff-only patch), the leave/close and archive prompts, the header derivation, `ChannelMemberDerivation` (order, admin badge, presence), `BrowseChannelsDerivation` (entries, sections, `joinTarget`) |
| `MMChannelAdminTypes.swift` | the wire shapes the admin endpoints answer (`MMChannelPatch`, `MMChannelStats`, `MMPrincipal`, `MMTeamMembership`, `MMChannelMember`, `MMRole`) |
| `ChannelInfoAPI.swift` | the requests, one method each, on the same `APIClient` the rest of the app uses |
| `ChannelInfoService.swift` | `ChannelInfoServing` (the test seam) + the session-backed implementation |
| `ChannelInfoViewModel.swift` | load, permission union, member paging, optimistic add + rollback, remove, leave/close, archive/unarchive, socket reconcile |
| `ChannelInfoCoordinator.swift` | one model per (server, channel) with an LRU of 4, one browse model per (server, team), the rail's socket fan-in |
| `ChannelInfoView.swift` | the sheet: header, purpose, member count, the action rows, three confirmations, the read-only note |
| `ChannelMembersView.swift` | the member list: search, count, per-row remove |
| `AddMembersViewModel.swift` / `AddMembersView.swift` | the picker: the untitled list, then the typed search |
| `ChannelSettingsViewModel.swift` / `ChannelSettingsView.swift` | the settings form, its validation copy, save, archive/unarchive |
| `BrowseChannelsViewModel.swift` / `BrowseChannelsView.swift` | the browser: joined, others, term, join |

Host wiring (`Mattermost/`):

- `ChannelView.swift` — the pane header's `nativeChannelInfoButton` and the sheet it presents.
- `ChannelSidebarView.swift` — the browser's entry (`nativeSidebarBrowseChannels`) and its sheet,
  beside "All threads" because that list is where a channel you do not have would be looked for.
- `Core/MM/SocketEvent.swift` — four new cases: `channelUpdated(MMChannel)`,
  `channelRestored(SocketChannelEvent)`, `userAdded(SocketMembershipChange)`,
  `userRemoved(SocketMembershipChange)` (channel id, team id, user id, remover id).
- `UI/Native/Sidebar/TeamSocketScope.swift` — attribution for them: `channel_updated` by the
  channel's own id/team, `channel_restored` by its envelope, `user_added`/`user_removed` by the
  envelope's channel (with the payload's `team_id` as a fallback), each with the reasoning written
  down where the decision is.
- `MattermostApp.swift` — one `ChannelInfoCoordinator` per app, bound to auth, navigation and the
  server store.
- `ChannelViewModel`, `ThreadViewModel`, `GlobalThreadsViewModel` — the no-op case lists kept
  exhaustive (none of them owns a membership or a channel rename).

Fixtures: `scripts/t40_channel_seed.py` (three channels and the plain `system_user` account
`t40member`) and `scripts/t40_channel_probe.py` (the measured contract below). Neither carries a
credential: the fixture password comes from `MM_PROBE_PASSWORD`.

## 2. The measured server contract

All of this is `scripts/t40_channel_probe.py` output against Mattermost **9.11.19** at
`127.0.0.1:8065` (log: `docs/t40-channel-probe-2026-10-26.log`), not read from a type definition:

| Call | Answer |
|---|---|
| `POST /roles/names` with my system + team + channel role names | the roles, each with its `permissions` array; the administrator's union is **271 ids across 4 roles** |
| `GET /channels/{id}/stats` | `{"channel_id", "member_count", "guest_count", "pinnedpost_count", "files_count"}` — the channel object itself carries **no** count |
| `PUT /channels/{id}/patch` purpose 250 / 251 | 200 / 400 `model.channel.is_valid.purpose.app_error` |
| … header 1024 / 1025 | 200 / 400 `model.channel.is_valid.header.app_error` |
| … display name 64 / 65 | 200 / 400 `model.channel.is_valid.display_name.app_error` |
| `POST /channels/{id}/members` | 201 with the membership row (`roles: channel_user`, counters at 0) |
| `DELETE /channels/{id}/members/{uid}` | 200 `{"status":"OK"}` |
| `DELETE /channels/{id}` then `POST /channels/{id}/restore` | 200, `delete_at` set / `delete_at: 0` back |
| `GET /users?in_team={t}&not_in_channel={c}` | 200 with the team's other members |
| `POST /users/search` with **no** term | **400** `api.context.invalid_body_param.app_error` |
| `PUT /users/{id}/preferences` `direct_channel_show=false` | 200 — and the DM's membership rows both survive (2 before, 2 after) |
| `POST /channels` with a name an **archived** channel holds | fails, and `GET /teams/{t}/channels/name/{n}` answers 404 — a per-run scratch name is the only reliable probe |

Two facts shaped the design more than the rest:

1. **This server's stock `channel_user` role carries the administrator ids** (`delete_public_channel`,
   `manage_public_channel_members`, `manage_public_channel_properties`; 27 ids in total). A client
   that gated on the role *name* would be wrong in both directions on this server: it would hide
   actions the account may take, and a scheme that renamed a role would unlock actions it may not.
   So `ChannelInfoCapabilities.derive` reads the permission set and nothing else.
2. **`POST /users/search` cannot build the empty picker** (400 on an empty term). The picker's first
   screen is therefore `GET /users?in_team&not_in_channel`, and the typed screen is
   `POST /users/search` — two sources, in that order, which is why `AddMembersViewModel` has two
   states rather than one.

## 3. The rules that follow (and where they are pinned)

- **A gate is a permission id, never a role name.** `ChannelInfoCapabilities.derive` is the only
  place any of the five questions is answered, and `offeredActions` is the only list the view draws
  from. A test asserts both directions with the same channel: the permission set without the id
  offers nothing, the set with it offers exactly the rows that id allows
  (`testAdminPermissionsOfferEveryActionOnAPublicChannel`, `testNoChannelOffersNothing`).
- **"Not offered" and "not performable" cannot disagree.** Every write in `ChannelInfoViewModel`
  re-checks the same flag and refuses with a sentence (`refused`), so a path that reached the view
  model without the row still cannot write. The live security test drives the *screen* as a plain
  member whose `channel_user` role was stripped of the administrator ids for the test (the name stays
  `channel_user`), and asserts that no administrator row exists to tap.
- **A DM is closed, not left.** `ChannelLeavePrompt.make` returns `.closeDirectMessage` for `D`/`G`,
  and the view model performs the `direct_channel_show=false` preference write instead of
  `DELETE …/members/me` — because the membership row survives a close (measured), and a client that
  "left" a DM would lose the conversation from its own sidebar while the server still considered it
  joined.
- **The default channel cannot be left** (unless the reader is a guest), and it is recognised by URL
  name `town-square` — the server has no `is_default` flag.
- **A patch carries only what changed.** `ChannelsPatch` writes what it receives, so echoing an
  unchanged header back would rewrite a field somebody else may have edited between this screen's
  read and its save (`testPurposeOnlyEditSendsOnlyThePurpose`, which also asserts the encoder omits a
  nil rather than sending `null`).
- **A nil profile or status is not invented.** A member with no profile row falls back to the user id
  and a member with no status is "Unknown", never "Offline" (`ChannelMemberDerivation`).
- **A join lands in the channel.** `BrowseChannelsDerivation.joinTarget` hands the router an id *and*
  a name, and the view navigates to the channel on success — the acceptance criterion is a test
  (`testBrowsingAndJoiningAPublicChannelNavigatesIntoIt`), not a hope.
- **Membership events reconcile in place**: `applyUserAdded` is idempotent by user id (the optimistic
  row and the socket event that confirms it are the same row), `user_removed` for me closes the sheet
  and drops the channel, and `channel_updated` patches an open info screen.

## 4. Reachability

`-surfaceMode channelInfo=native` (dual-render flag, `docs/dual-render.md`). With it:

- a channel pane's header draws the info button (`nativeChannelInfoButton`);
- the channel sidebar draws "Browse channels" (`nativeSidebarBrowseChannels`).

Both resolve the **same** surface, so a build cannot have one without the other. The surface is not
in `nativeApprovedSurfaces`; it flips only after `T40-AV` (`t_06786ced`) passes.

## 5. Verification

Run on this host on 2026-10-26, Mattermost **9.11.19** at `127.0.0.1:8065`:

| What | Command | Result |
|---|---|---|
| Full Catalyst unit suite (clean derived data) | `python3 scripts/qa-test.py --platform mac --only-testing MattermostTests --label t40r-units2` | **1,306 tests, 4 skipped, 0 failures**, `RESULT: PASS` (`build/logs/t40r-units2.log`; 1,305 before this round + the sidebar test F3 pins) |
| T40 unit tests only | `… --only-testing MattermostTests/T40ChannelInfoTests` | **49 run, 0 skipped, 0 failed** (`build/logs/t40-units2.log`) |
| Server probe | `MM_PROBE_PASSWORD=… python3 scripts/t40_channel_probe.py` | exit 0; every call in §2 answered as stated (`docs/t40-channel-probe-2026-10-26.log`) |
| Live UI suite (T40-R) | `TEST_RUNNER_MM_AUTH_*=… python3 scripts/qa-test.py --platform ios --sim id=81A7F251… --only-testing MattermostUITests/T40ChannelInfoUITests --label t40r-suite11` | **8 run / 0 skipped / 0 failed**, `** TEST SUCCEEDED **` (`build/logs/t40r-suite11.log`; §5.1) |

The 4 skips in the full suite are the ones the repo already documents (CertTrust/Keychain, MentionPoller
live opt-in, SelfSignedTrust ×2) — none is T40's.

The screenshot `docs/t40-shots/t40-01-channel-info.png` was exported from the live run's own attachment
(`01-channel-info`), i.e. the app drawing the server's real channel: title **T40 Standup**, "Public
channel · 2 members", purpose "Daily standup notes", header "Standup at 09:15", and the five action rows
(Add members / Members · 2 members / Channel settings / Archive channel / Leave channel) that the
administrator's permission set allows. Nothing about it is a fixture rendering.

### 5.1 What the live suite proves, and what it does not (yet)

Re-measured on 2026-10-26 after the T40-R repairs, on this host. **One direct run is the verdict:**

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=… python3 scripts/qa-test.py --platform ios --sim id=81A7F251-… \
  --derived-data ~/Library/Developer/Xcode/DerivedData/mmios-t40r \
  --only-testing MattermostUITests/T40ChannelInfoUITests --label t40r-suite11
# -> Executed 8 tests, with 0 failures (0 unexpected) in 200.190 seconds
# -> ** TEST SUCCEEDED **            (build/logs/t40r-suite11.log)
```

**The relay run is the wire witness, not a second verdict** (`build/logs/t40r-suite10.log` /
`build/logs/t40r-relay-suite10.txt`, app pointed at `http://127.0.0.1:8066` through the logging TCP
relay). Its request log carries what T40-AV measured missing:

```
20:52:36 > POST /api/v4/channels/eu5tcwy7z3ghich67ifk5us53a/members HTTP/1.1
20:55:14 > PUT  /api/v4/channels/eu5tcwy7z3ghich67ifk5us53a/patch   HTTP/1.1
20:57:46 > DELETE /api/v4/channels/eu5tcwy7z3ghich67ifk5us53a/members/9apc1tb413nupgssgyhzjpmezr HTTP/1.1
20:52:46 > POST /api/v4/channels/eu5tcwy7z3ghich67ifk5us53a/restore HTTP/1.1
```

(5 `POST …/members`, 4 `PUT …/patch`, 3 `DELETE …/members/{id}` and 8 `POST …/restore` in that window.)
That run **failed its two socket-dependent tests** and only those two — the browser join never reached the
sidebar and none of the three reconcile events landed. **A relay cannot host a socket assertion**: the app
opens `GET /api/v4/websocket` through it (relay log lines 13, 22, 23, 29, 41, 60, 68, 69) and no frame ever
arrives — the request line goes through the forwarder, the long-lived frame stream does not — so nothing
reaches `ChannelInfoViewModel`. (One real relay bug was found and fixed on the way —
`socket.create_connection(timeout=10)` left a 10 s *read* timeout on every upstream socket, so even an idle
websocket died — but that was not the whole cause and the two tests still saw no events.) Both relay
attempts (`t40r-suite9`, `t40r-suite10`) failed **exactly** those two tests and nothing else, while every
direct-to-8065 run (`t40r-suite6`, `-suite7`, `-suite8`, `-suite11`) passed them. The relay is evidence of
the writes, not of the socket.

The suite now has **eight** live tests, two of them added for F8:

| Test | What it asserts against the server |
|---|---|
| `testInfoScreenRendersTheServersHeaderPurposeAndMembers` | the title/purpose/header it draws are the server's; the member count equals `GET /channels/{id}/members` |
| `testAddingAndRemovingAMemberReachesTheServer` | one row tap enables Add and the button counts the selection; the add is in `GET …/members`; the row appears; the removal is gone from `GET …/members` |
| `testPurposeAndHeaderPersistOnTheServer` | the Save row enables on a change, the tap lands, and `GET /channels/{id}` carries both new fields |
| `testLeavingAPublicChannelRemovesTheMembershipAndTheRow` | the leave removes my membership on the server and the info sheet closes with it. **It does not assert the sidebar row**, and the name is kept from the earlier form on purpose: after a leave the shell sits on the channel tab with a disabled Back and no sidebar to return to (measured twice, suite4 and suite6), so the row assertion failed on *navigation*, not on the row. The row's removal rests on the `ChannelSidebarService` unit test (my own `user_removed` → `.reloadNeeded`) and on the same event path proven in the other direction by the browse test's join. The shell's post-leave navigation is a gap in §6, not a channel-info defect |
| `testBrowsingAndJoiningAPublicChannelNavigatesIntoIt` | the join is on the server; the pane opens; its title is the **display name**; the sidebar gains the row |
| `testAnAccountWithoutThePermissionIsOfferedNoAdminAction` | signed in as the plain `t40member`: no administrator row is offered, and the server 403s the same write from that account's own token |
| `testArchivingAndUnarchivingAChannelReachesTheServer` | archive → `delete_at != 0`, the screen says archived and offers Unarchive → `delete_at == 0`, the banner clears |
| `testTheOpenInfoScreenFollowsRenameAndMembershipEvents` | with the sheet open: `channel_updated` moves the title, `user_added` raises the count and adds the row, `user_removed` removes it — all from the test process, no reload |

What it does **not** prove:

- **The permission experiment is a shared-role experiment.** It narrows `channel_user` on the fixture server;
  §5.3 F7/F9 state the hazard and both repairs. It cannot be run against a server this card does not own.
- **No real device, no APNs, no push proxy.** Every test is on the iPhone 16 Pro simulator against
  `127.0.0.1:8065`.
- **Nothing offline**: the screen reads REST + socket live and the suite never kills the network.
- **Presence is a snapshot** (§6), so no test asserts a live status change.
- The suite's own credibility depends on the **bundle under test**: a shared `-derivedDataPath` and a shared
  booted device made one run execute a *different card's* stale test bundle (caught by the source paths in
  the log). Every verdict in this note was produced with a card-scoped derived-data path and the app
  uninstalled first; `build/logs/t40r-suite11.log` is that run (and `t40r-suite8.log` the one before it).

One harness instability is real and remains: XCUITest's accessibility-snapshot machinery can crash the app
process (`EXC_BAD_ACCESS` in `_platform_strcmp` under `runtime_issue_os_log_fault_callback`, after
`__LIBTRACE_CLIENT_QUARANTINED_DUE_TO_HIGH_LOGGING_VOLUME__`). It is not a crash in this card's code — the
stack is XCTest's own. It killed the info test in `t40r-suite7` and then vanished from `t40r-suite8`,
`t40r-suite10` and `t40r-suite11`, where the same test ran green; the difference is the tests' launch environment:
`OS_ACTIVITY_MODE=disable` in the app process (XCTest injects `XCTAutomationSupport` there, and its
per-snapshot fault logging is the volume libtrace quarantines on) plus the app's own `-uiTestLogLevel error`
seam. Both are test-only. A red run that names this stack is the harness, not the surface.


### 5.2 Repairs this round

- `ChannelPatchDraft.patch(comparedTo:)` sent all three fields whenever anything changed; it now sends
  only what changed (the unit test that caught it is `testPurposeOnlyEditSendsOnlyThePurpose`).
- `ChannelInfoCapabilities` gained `hasChannel`, so "no channel" offers **no** rows — before, the member
  list row was drawn in a state with no channel at all (`testNoChannelOffersNothing`).
- The browse split's ordering test asserted an others-then-joined order that contradicted the section
  order the screen draws; the list is one alphabetical list and the *test* was wrong.
- Two unit tests compared a footer count against the number of rows loaded while the fixture's
  `member_count` said 3; the fixture is now self-consistent (the count is the server's).
- `testUnarchiveNeedsManageTeam` granted `manage_team` mid-test and expected the cached gates to move;
  it now re-loads, which is what a role change actually looks like to the app.
- The channel browser moved from the bottom "Threads" section (a `List` renders lazily — the row was
  off screen, hence unreachable) into the Workspace section beside the channel switcher.
- The leave hand-off moved from `ChannelInfoSheet` (which holds the model as a plain `@State`, so its
  body never re-runs on a published change and its `.onChange` never fired) into `ChannelInfoView`,
  which observes the model. This is what turned the leave test green.
- The live suite makes **one** admin login per test process: the server rate-limits `/users/login`
  per IP, which skipped a whole run with `HTTP 429`.

## 5.3 T40-R — the findings (F1–F9), their causes, and what changed

`t_06786ced` (T40-AV) verified this card against the running server and found findings that the unit
tests could not see, because each one lives in the **SwiftUI side of a live screen**:

| # | Measured symptom | Cause (measured) | Repair |
|---|---|---|---|
| F1 | The Add Members button stayed "Add 0 members" after a row tap; the tap ran nothing | `AddMembersView` held its `AddMembersViewModel` in a plain `@State`. SwiftUI subscribes to `objectWillChange` for `@StateObject`/`@ObservedObject`, **not** for a reference type parked in `@State`, so the body never re-ran: `canSubmit` was the value from first draw, the toolbar button stayed `.disabled`, and a disabled button's tap is a no-op | the view is split: `AddMembersView` creates the picker in `.task` and `AddMembersPicker` holds it as `@ObservedObject` |
| F2 | The settings Save never sent `PUT …/patch` | Same defect in `ChannelSettingsView` (`@State` form model) → the Save row never enabled | `ChannelSettingsForm` observes the form model; the test asserts the row says it can save *before* tapping it |
| F3 | The sidebar did not gain a channel I had just joined (nor drop one I left) | `ChannelSidebarService.handle` answered `.ignored` to `user_added` / `user_removed`. A join is invisible to the counter refresh (`GET /users/me/teams/{t}/channels/members` lists what the server already had for me) and a leave is still in it, so no refresh could ever draw or drop the row | my own `user_added`/`user_removed` → `.reloadNeeded` (one full `GET …/channels` behind the existing debounce); **anybody else's** → `.ignored` (their activity is not a change to my list, and reloading on it would be a request storm). Pinned by `MattermostTests/T33-ChannelSidebarTests.testMyOwnMembershipChangeAsksForAFullReloadAndSomebodyElsesDoesNot` (the debounced-reload hand-off is the one `testAChannelCreatedEventReloadsTheListOncePerDebounce` already pins, and the live browse test proves it end to end) |
| F4 | The pane's title stayed the URL slug (`t40-browse-me`) after a browser join | Same observation defect in `ChannelPaneContent`: the model is in `@State`, `loadChannelHeader()` publishes the server's display name a beat after the pane opens, and nothing repainted | `ChannelPaneTitle` — a view that observes the model — draws the glyph and the title; the pane's own body keeps the `@State` reference |
| F5 | The non-admin test never reached its assertion | It waited for `teamSidebar.team.<id>`, but `TeamSwitchViewModel.content` returns `.single` for an account with one team and `TeamSidebarView` draws no rail row in that state. `t40member` is in one team, so the wait could never resolve | the test reveals its channel row directly (the security assertion needs the row, not the rail) |
| F6 | The browser's row tap "did nothing" | `browseChannels.row.<id>` is not in the accessibility tree until the sheet's lazy `List` has been scrolled to it: the browser lists **every** public channel of the team (dozens). Every earlier run — the AV's probe included — tapped an element that did not exist yet. The "sheet-tap defect" this note blamed in §5.1 was wrong for this screen | the test drags the sheet until the row exists (`revealInSheet`), then taps it |
| F7 | The card's notes and the parity row claimed "2 of 6 green" | That number was the **best of three runs**, not a run: the implementer's last two printed 1/6 (`build/logs/t40-live5.log`) and 0/6 (`build/logs/t40-live4.log`), and the AV's clean run printed 2/6. The failures were also put down to "the sheet-tap defect", which is not what the browse test hit (F6) | §5.1 now states what one clean run prints, names each test's measured cause, and the T40 row of `docs/parity.md` carries the same counts. The single "green" number is gone from both |
| F8 | Archive/unarchive and "does an open sheet follow the socket" were never exercised | they were not in the suite | two new live tests: archive → `delete_at != 0` → the screen's archived banner and Unarchive row → `delete_at == 0`; and, with the info sheet open, `channel_updated` (rename) / `user_added` / `user_removed` from the test process, each asserted on the open screen |
| F9 | A killed run leaves the shared fixture unmanageable, and the "the server refuses the write" assertion once answered 201 | The permission experiment writes a **server-wide** role (`PATCH /roles/name/channel_user`); a process killed between the write and the restore never puts it back (measured twice — one run died with "Lost connection to the application"), so the next card's live fixture is stripped. The `201` came from testing that premise against a role a sibling card had already restored | the test asserts the experiment is in effect (role at the stock member's 8 ids) **before** it draws any conclusion, reads the role back after the write, and asks `/users/me` with the member's own token to prove which account made the request; `setUp` restores the fixture's 27 ids when the administrator ids are missing; the test restores as soon as its assertions are done instead of waiting for `tearDown`; `scripts/t40_channel_seed.py --reset-roles` stays the out-of-band repair. §6 states the hazard |

Two harness defects were found in the same round, and both had been hiding assertions:

1. **`swipeLeft()` on a member row does not open its swipe actions.** The identifier sits on the row's
   avatar `StaticText` (~32pt), so the synthesised gesture is too short to be a row swipe — the swipe ran
   and the Remove button never existed. The test drags across the row's own width instead.
2. **A navigation-bar tap is not a safe way to dismiss the keyboard.** `app.navigationBars.firstMatch`
   can resolve to the **shell's** bar behind a presented sheet; tapping it closed the sheet, so the
   settings form was gone before Save was ever looked for (`Failed to get matching snapshot` on the
   following step). The test scrolls the form instead.
3. **An implicitly-unwrapped test property interpolated into a URL is `Optional(…)`.** The browse test's
   reset (`DELETE …/members/\(userID)` with `userID: String!`) sent
   `/members/Optional("jruqq…")` — the relay log caught it (`t40r-relay-suite9.txt`, 20:55:13) — and the
   `try?` swallowed the 404, so the channel stayed joined between runs. Force-unwrapped at the one place
   it is used.

## 6. Known limits (stated, not hidden)

- **Not ported**: mobile's per-tab channel-info tree (files, pinned, notification preferences,
  bookmarks) — this screen draws the header, the member list and the action rows, and pinned posts
  are T39's sheet; public↔private conversion; bookmark management; mute/notification settings; the
  archived-channel browser (an archived channel is a not-joinable row in the browser instead); inviting
  by **email** (the picker adds existing team members only).
- **"Rename" means the display name.** The URL name is never sent by the settings form — upstream does
  not either, because it is the channel's address and changing it breaks every link to the channel.
- **A rename does not repaint the channel pane's own title** until the pane is reopened: the title
  belongs to the pane, which reads the sidebar's channel list, and that list is not patched by
  `channel_updated` (the info sheet is). Stated here rather than papered over.
- **The member list is paged 60 at a time.** The footer count is the server's `member_count`, so the
  number is right while the rows may be partial; there is no "load more" beyond the page the list
  asks for on open.
- **Presence is a snapshot** (`POST /users/status/ids`), not a subscription: no websocket status
  events on this screen, so a dot can be stale until the list is reopened.
- **The permission union is fetched once per open** (`POST /roles/names`). A role change made while
  the screen is open appears on the next `load()`.
- **Nothing here is available offline**: the screen reads REST + socket live and does not use the T29
  store.
- **The live suite needs the server's login rate limiter to be unbothered.** `/users/login` is
  throttled per IP; when a probe script and the suite share the address, tests skip with
  `HTTP 429` in the message rather than failing. The suite now makes **one** admin login per test
  process to stay out of it.
- **The non-admin test mutates a shared server role.** Its experiment `PATCH`es `channel_user`
  (`stripChannelUserPermissions`), which is server-wide, not per-membership: a run killed between the
  write and the restore leaves *every* card's fixture on that server stripped (twice measured). Repairs,
  in order of preference: `python3 scripts/t40_channel_seed.py --reset-roles` (the out-of-band one), the
  suite's own `setUp` restore when the administrator ids are missing, and the restore-with-assertions
  the test does before `tearDown`. The better design — a per-membership custom role — is not
  implemented; the hazard is stated instead of hidden.
- **After a leave the shell has nowhere to go.** The leave is correct on the server and the sheet
  closes with it, but the shell stays on the channel tab with a disabled Back and no sidebar, so the
  "the row is gone" assertion cannot be reached by navigation (§5.1). A shell-navigation gap, not a
  channel-info one.
- **Archive/unarchive and the socket reconcile now have live evidence** (`testArchivingAndUnarchiving…`,
  `testTheOpenInfoScreenFollowsRenameAndMembershipEvents`), where before T40-R they had unit tests only.
  What that live evidence does **not** cover: an archive performed by *another* client while the sheet is
  open (the rename and both membership events are covered; archive is asserted from this app's own tap).

### 6.1 Why the permission experiment is not a per-membership role (measured)

The safer design T40-AV asked for — a custom role granted to one membership instead of patching the
server-wide `channel_user` — cannot be built against this server, measured on 9.11.19 with the
administrator's own token:

```
POST /api/v4/roles                          -> 404 api.context.404.app_error
GET  /api/v4/roles/name/channel_user        -> 200, 27 ids
GET  /api/v4/roles/name/channel_admin       -> 200, 18 ids
GET  /api/v4/roles/name/guest               -> 404 app.role.get_by_name.app_error
GET  /api/v4/roles/name/team_user           -> 200, 10 ids
```

There is no role-creation endpoint, and the only two roles a channel membership can carry are
`channel_user` and the **more** privileged `channel_admin` — so the experiment has to narrow
`channel_user` and put it back, which is exactly the hazard §6 states. The unit-level alternative (a fake
permission union) already exists and is what `T40ChannelInfoTests` pins; the live test exists to prove the
real server answers 403.
