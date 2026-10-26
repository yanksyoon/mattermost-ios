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
| Full Catalyst unit suite (clean derived data) | `python3 scripts/qa-test.py --platform mac --only-testing MattermostTests --label t40-full` | **1,305 tests, 4 skipped, 0 failures**, `** TEST SUCCEEDED **` (`build/logs/t40-full.log`) |
| T40 unit tests only | `… --only-testing MattermostTests/T40ChannelInfoTests` | **49 run, 0 skipped, 0 failed** (`build/logs/t40-units2.log`) |
| Server probe | `MM_PROBE_PASSWORD=… python3 scripts/t40_channel_probe.py` | exit 0; every call in §2 answered as stated (`docs/t40-channel-probe-2026-10-26.log`) |
| Live UI suite | `TEST_RUNNER_MM_AUTH_*=… python3 scripts/qa-test.py --platform ios --sim id=81A7F251… --only-testing MattermostUITests/T40ChannelInfoUITests` | **2 of 6 green** — see §5.1. Not claimed as a passing suite. |

The 4 skips in the full suite are the ones the repo already documents (CertTrust/Keychain, MentionPoller
live opt-in, SelfSignedTrust ×2) — none is T40's.

The screenshot `docs/t40-shots/t40-01-channel-info.png` was exported from the live run's own attachment
(`01-channel-info`), i.e. the app drawing the server's real channel: title **T40 Standup**, "Public
channel · 2 members", purpose "Daily standup notes", header "Standup at 09:15", and the five action rows
(Add members / Members · 2 members / Channel settings / Archive channel / Leave channel) that the
administrator's permission set allows. Nothing about it is a fixture rendering.

### 5.1 What the live suite proves, and what it does not (yet)

Green, twice, across the runs: **`testInfoScreenRendersTheServersHeaderPurposeAndMembers`** (the screen
renders the server's own header/purpose/member count — the assertion compares against
`GET /channels/{id}/members`) and, after the fix below, **`testLeavingAPublicChannelRemovesTheMembershipAndTheRow`**
(the leave reaches the server, the sheet closes, the row leaves the sidebar).

Red, and why — measured, not guessed:

- `testAddingAndRemovingAMemberReachesTheServer`, `testPurposeAndHeaderPersistOnTheServer`,
  `testBrowsingAndJoiningAPublicChannelNavigatesIntoIt` — the flows **start** correctly (the picker lists
  the team's non-members: `opsbot`, `probeone832551`, `t36avb93601`, … `t40member`; the browser sheet
  opens; the settings form draws) but the **row/button taps inside a sheet presented from another sheet
  do not reach the app**: the picker header stays "Add 0 members" after the row tap (and after a retry
  loop that re-taps until the submit button reports enabled), and the settings save never fires a write.
  This is the same class of failure for three different buttons, so it is one defect, not three.
- `testAnAccountWithoutThePermissionIsOfferedNoAdminAction` — the shell never lists the rail
  (`teamSidebar.team.<id>`) after signing in as `t40member`, so the security assertion never runs.
- `testInfoScreenRendersTheServersHeaderPurposeAndMembers` — green in one run, then **killed** in the next
  (`Lost connection to the application`): the crash report is `EXC_BAD_ACCESS` in
  `__LIBTRACE_CLIENT_QUARANTINED_DUE_TO_HIGH_LOGGING_VOLUME__` with
  `+[XCTRuntimeIssueContext captureIssuesWithContext:inScope:]` on the stack, i.e. XCTest's runtime-issue
  capture plus the simulator's logging quarantine, not a crash in this card's code.

So: the surface renders real server data and a leave round-trips, and the remaining live failures are a
sheet-tap defect plus a test-host instability that this card did **not** fix. They are listed here so
`T40-AV` (`t_06786ced`) starts from the truth rather than from a green number.

Two harness defects were found and fixed on the way, because each one had been hiding a real assertion:

1. the REST oracle used `URLSession.shared`, which replays a stale `MMAUTHTOKEN` cookie — the server
   answers `api.context.session_expired.app_error` (401) *before* it reads the body, so a correct
   password looked like a wrong one. The oracle now uses an ephemeral session with no cookie store
   (`httpCookieStorage = nil`, `httpShouldSetCookies = false`), exactly like the app's bearer-token path;
2. `serverURL.appendingPathComponent("/channels/{id}/members?per_page=200")` percent-encodes the `?`, so
   every read with a query string 404'd and the oracle silently read that as "0 members". `url(for:)`
   now splits the query off, and `getJSON` **throws** on a non-2xx rather than answering empty.

The fixture was also made idempotent: `scripts/t40_channel_seed.py` now resets the non-admin account's
password on every run (`PUT /users/{id}/password`), because an account created by an earlier run with a
different password made every live test skip with a 401 that looked like a code bug.

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
