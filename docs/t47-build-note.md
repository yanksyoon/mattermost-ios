# T47 — creating a channel and starting a direct message from the sidebar `+`

Card: `t_2739ca53`. Surfaces: **S09** find/browse (the create entry point), **S10** create channel, and
the direct-message entry point beside them. Gated by `-surfaceMode channelInfo=native`; the surface is
**not** in `nativeApprovedSurfaces` (that list is still `[.auth]`), so nothing here is on by default until
its `-AV` card passes — the same posture as T40.

Behaviour reference: `mattermost/mattermost-mobile` @ `v2.45.0` (`162f2560…`), Apache-2.0 —
`app/screens/create_or_edit_channel/`, `app/screens/create_direct_message/`, `app/actions/remote/channel.ts`,
`app/client/rest/channels.ts`, `app/client/rest/users.ts`. Read for rules, reimplemented in SwiftUI; the
file set and licence line are recorded in `docs/THIRD_PARTY_NOTICES.md` §17–§18 and
`docs/component-map.md` §S09–S10. The webapp (AGPL-3.0) was observed only, never copied.

## 1. What shipped

`Mattermost/UI/Native/ChannelInfo/` — 5 new files, 1,136 lines:

| File | What it owns |
|---|---|
| `CreateChannelModels.swift` (409) | every **pure** rule: `ChannelCreateKind` (`O`/`P`), the permission ids (`create_public_channel`, `create_private_channel`, `create_direct_channel`), `ChannelCreatePermissions` (menu order + which kinds are offered), `ChannelCreateDraft` (display name, derived URL name, the name rule, `validation(permissions:)`, `body(teamID:)`), `NewDirectMessageCandidate` (initials, status label, `emptyCopy`) |
| `CreateChannelService.swift` (62) | `ChannelCreationServing` (the test seam, inheriting `ChannelInfoServing`) + the `SessionChannelInfoService` conformance: `createChannel`, `teamMembers`, `searchTeamMembers`, `createDirectChannel`, and `statusesOrEmpty` (a presence failure is “unknown”, never “offline”) |
| `CreateChannelViewModel.swift` (349) | draft state, kind toggle, the two permission gates, submit, the created-channel hand-off, `menuActions`, the failure copy |
| `CreateChannelView.swift` (195) | the form: Public/Private picker (or a fixed value when only one kind is allowed), display name, URL name, purpose/header, the validation sentence, Create/Cancel |
| `NewDirectMessageView.swift` (121) | the people picker: team list, typed search, presence, one tap opens the conversation |

Host wiring:

- `Sidebar/ChannelSidebarView.swift` — the channel-list section header's `+`
  (`nativeSidebarCreateMenu` → `ChannelCreateMenuButton`), the two sheets, and `land(on:)`, which routes a
  created DM/channel through `NativeNavigation.openChannel`. The button observes the model itself because a
  `@State`-held model read inside the sidebar body would never re-render (the T40-R defect class).
- `ChannelInfo/ChannelInfoCoordinator.swift` — `createModels[serverID][teamID]` and
  `directMessageModels[serverID][teamID]`, created on the sidebar's team task and cleared in `deactivate`.
- `ChannelInfo/ChannelInfoAPI.swift` — `POST /channels`, `GET /users?in_team=`, `POST /users/search`,
  `POST /channels/direct`.
- `ChannelInfo/MMChannelAdminTypes.swift` — `MMChannelCreate` (the request body) and
  `MMChannelMemberPage`.
- `ChannelInfo/ChannelInfoService.swift` — `client()` `private` → internal, so the creation extension in the
  other file can reach it (one class, two files, no second client).

Fixtures and tools:

- `scripts/t47_create_channel_probe.py` (223) — the server-side oracle for the create rules;
  log: `docs/t47-channel-probe-2026-10-27.log`.
- `scripts/t47_logging_relay.py` (149) — a logging TCP relay in front of the fixture, used only as the
  wire witness; log: `docs/t47-relay-witness-2026-10-27.log`. No credential in either script; the password
  comes from `MM_PROBE_PASSWORD`.

## 2. The measured server contract

Mattermost **9.11.19** (team edition, `docker` fixture at `127.0.0.1:8065`), measured by
`scripts/t47_create_channel_probe.py` — full output in `docs/t47-channel-probe-2026-10-27.log`.

Who may create: both the admin union (271 permission ids) and the plain member union (23 ids) carry
`create_public_channel`, `create_private_channel` and `create_direct_channel`, so the menu is driven by the
ids, not by a role name.

`POST /channels`:

| Input | Answer |
|---|---|
| `type=O` / `type=P` | `201`, the channel; `creator_id` = the caller; the creator is added as a member (`member_count: 1`); it appears in `GET /users/me/teams/{tid}/channels` |
| `name` lower-case letters/digits/`-`/`_` | `201` |
| `name` with an upper-case letter, a space, a dot, a leading `-`, a leading `_`, or empty | `400` `model.channel.is_valid.1_or_more.app_error` — *“Name must be 1 or more lowercase alphanumeric character.”* |
| trailing `-` | `201` (legal, and the app trims it anyway) |
| `name` 64 chars | `201`; 65 chars → **`500`** `app.channel.create_channel.internal_error` (a server bug, not a `400`) |
| `display_name` empty | `400 api.context.invalid_body_param.app_error` — the body field is required |
| `display_name` 64 / 65 | `201` / `400 model.channel.is_valid.display_name.app_error` |
| `purpose` 250 / 251 | `201` / `400 model.channel.is_valid.purpose.app_error` |
| `header` 1024 / 1025 | `201` / `400 model.channel.is_valid.header.app_error` |
| a name already in the team | `400 store.sql_channel.save_channel.exists.app_error` — *“A channel with that name already exists on the same team.”* |
| unknown team | `404 app.channel.get_channels.not_found.app_error` |
| `type=X` | `400 model.channel.is_valid.type.app_error` |
| `type=D` | `400 api.channel.create_channel.direct_channel.app_error` — *“Must use createDirectChannel API service…”* |

A DM is therefore **only** `POST /channels/direct`, and that call is create-or-find (`201` on both paths,
the same channel id). Its channel is named `<userid>__<userid>`, ids sorted, and it is type `D` — both
asserted by the live UI suite's oracle, which also reads `GET /channels/{id}/members` back.

The DM picker's reads, measured in the same UI run (witness log): `GET /users?in_team={tid}` for the
opening list, `POST /users/search` with a term for the typed search, `POST /users/status/ids` for presence.

## 3. The rules that follow, and where they are pinned

| Rule | Where |
|---|---|
| The menu exists only for actions the server's permission ids allow, in upstream's order (create, browse, direct) | `ChannelCreatePermissions.menuActions` — units `testTheMenuIsCreateBrowseDirectMessageInThatOrder`, `testNoPermissionsOfferAnEmptyMenu`, `testCreateIsOfferedWithEitherCreateIdAndTheKindsFollowTheGrant`, `testRoleNamesGrantNothingWithoutTheirPermissionIds` |
| A reader who may not create private channels is shown a public form, and the toggle cannot switch to a kind they cannot create | `ChannelCreateViewModel.load()` / `setKind(_:)` — units `testTheFormOpensOnAKindTheReaderMayCreate`, `testTheKindCannotBeSwitchedToAKindWithoutItsPermission`, `testTheFormLoadsTheUnionOfSystemAndTeamRoleIds` |
| The URL name is derived from the display name: diacritics folded, everything outside `[a-z0-9_-]` collapsed to one `-`, separators trimmed | `ChannelCreateDraft.makeURLName` — units `testTheDisplayNameDerivesADashedURLName`, `testDiacriticsAreFoldedIntoTheURLName`, `testPunctuationCollapsesToASingleSeparator`, `testLeadingAndTrailingSeparatorsAreTrimmed`, `testALongDisplayNameIsTruncatedTo64WithoutATrailingSeparator`, `testADisplayNameWithNoUsableCharactersSuggestsNothing`, `testTheURLNameFollowsTheDisplayNameUntilTheReaderEditsIt` |
| The URL name rule: 1–64, lower-case letters/digits/`-`/`_`, no leading `-`/`_` | `ChannelCreateDraft.validationMessage(for:)` — units `testTheRuleAcceptsLowercaseDigitsHyphenAndUnderscore`, `testTheRuleRefusesTheShapesTheServerRefuses`, `testTheRuleAcceptsATrailingHyphenBecauseTheServerDoes`, `testALeadingSeparatorIsNamedInTheMessage`, `testEveryDerivedNameIsAcceptedByTheRule` |
| 64/65 on the URL name is refused client-side (the server answers `500`, which is not an error a reader can act on) | `CreateChannelDraft.maxLength` + unit `testTheRuleAccepts64CharactersAndRefuses65` |
| Two independent permission gates stand between a reader and `POST /channels` | `create()`'s guard **and** `validation(permissions:)` — see §4, unit `testACreateWithoutThePermissionSendsNothing` |
| A create that answers a channel of a different kind is not navigated to | `create()` — mutation-checked in §4, unit `testAChannelOfTheWrongKindIsNotNavigatedTo` |
| A duplicate name surfaces the server's own sentence | `CreateChannelViewModel.copy(for:)` — unit `testADuplicateNameSurfacesTheServersOwnSentence` |
| A presence failure is unknown, never offline | `statusesOrEmpty` — unit `testThePickerCarriesPresenceAndSaysUnknownRatherThanOffline` |
| One tap in the picker opens the conversation (no select-then-Start) | `NewDirectMessageView` — unit `testTappingARowCreatesTheConversationWithBothIdsAndPublishesIt`, asserted live in §5.2 |

## 4. Mutation checks (measured, not asserted)

Three single-site mutations, each run through `scripts/qa-test.py --only-testing
MattermostTests/T47CreateChannelTests` in the isolated worktree:

| Mutation | Result |
|---|---|
| `create()`'s `guard permissions.canCreate(draft.kind)` → `guard true \|\| …` | **still green** — `draft.validation(permissions:)` refuses independently. Two gates, not one; the comment in `testACreateWithoutThePermissionSendsNothing` says so. |
| the same guard **and** the permission clause in `validation(permissions:)` both neutered | `testACreateWithoutThePermissionSendsNothing` **red** (3 assertions: nil channel, empty body list, error message) |
| `if !channel.type.isEmpty, channel.type != draft.kind.rawValue` (the wrong-kind answer) deleted | `testAChannelOfTheWrongKindIsNotNavigatedTo` **red** (3 assertions) |

Each mutation was reverted before the verification runs below.

## 5. Verification

### 5.1 Unit tests — whole target, green

```
python3 scripts/qa-test.py --platform mac --only-testing MattermostTests \
  --derived-data ~/Library/Developer/Xcode/DerivedData/mattermost-ios-t47 --label t47-final-units
# -> Executed 1703 tests, with 9 tests skipped and 0 failures (0 unexpected) in 60.169 (61.354) seconds
# -> RESULT: PASS
```

T47 alone: **34 tests**, `Executed 34 tests, with 0 failures (0 unexpected) in 0.070 (0.079) seconds`.
They use handwritten fakes (`FakeCreateService`) — no network, no clock.

### 5.2 Live UI suite — the verdict, straight at the server

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=… python3 scripts/qa-test.py --platform ios \
  --sim id=9EC24144-… --only-testing MattermostUITests/T47CreateChannelUITests --label t47-verdict2
# -> Test Case '…SendsPostChannelsAndTheNewChannelSurvivesRelaunch' passed (49.9 s)
# -> Test Case '…StartsADirectMessageWithATeammate' passed (45.6 s)
# -> 2 run, 0 skipped, 0 failed, RESULT: PASS
```

What the first test asserts, against the server's own records: the private channel
`t47-ui-<stamp>` was **404 before** the tap and afterwards exists with `creator_id` = the signed-in
user, `type: P`, the `display_name` typed into the form and `create_at` inside this run; the pane is
titled with that display name; the sidebar row exists; and the row is still there after a relaunch with
no `-uiTestForgetSession` (so it came from `GET /users/me/teams/{tid}/channels`).

The second asserts: the picker lists the teammate (searched by username), one tap opens the conversation,
the pane is titled with the person, and the server answers a type `D` channel named `<id>__<id>` whose
members are exactly the two people — read back through `POST /channels/direct` (create-or-find) and
`GET /channels/{id}/members`, then found in the sidebar.

Every run archives what it created (`tearDown`), because a channel name is not reusable after an archive.

### 5.3 Wire witness — the two requests, on the wire, from the app

Same suite, app pointed at `http://127.0.0.1:8066`, the relay forwarding to the fixture
(`docs/t47-relay-witness-2026-10-27.log`, 117 lines). Both tests passed there too. The lines that matter:

```
20:09:54 -> POST /api/v4/channels HTTP/1.1                       <- the private channel, from the form
20:09:54 -> GET  /api/v4/users/me/teams/ocz…/channels HTTP/1.1   <- the list reload that makes the row
20:09:55 -> GET  /api/v4/channels/hss5yiss…/posts?page=0…        <- the pane of the created channel
20:10:40 -> POST /api/v4/users/search HTTP/1.1                   <- the picker's typed search
20:10:40 -> POST /api/v4/users/status/ids HTTP/1.1               <- presence for the picker's rows
20:10:42 -> POST /api/v4/channels/direct HTTP/1.1                <- the tap that opened the DM
20:10:42 -> GET  /api/v4/channels/kahpoaziefgr…/members/me       <- the DM pane
20:10:43 -> POST /api/v4/channels/direct HTTP/1.1                <- the test's oracle, one second later
```

The app's `POST /channels/direct` at `…:42` precedes the oracle's at `…:43`: the conversation the oracle
then reads is the one the app's tap created. `POST /api/v4/channels` carries the
`{"purpose":"","type":"P","name":"t47-ui-…","header":"","team_id":"…","display_name":"T47 UI …"}` body and
the server answers `201 Created` (both visible in the `--dump` run, `build/logs/t47-relay4.txt`).

## 6. Known limits (stated, not hidden)

- **The surface is not approved.** Everything here sits behind `-surfaceMode channelInfo=native`; the
  T47 `-AV` card is what puts it in front of a reviewer. Nothing is on by default.
- **The relay is a witness, not a verdict path.** It breaks the app's WebSocket (`GET /api/v4/websocket`
  → `403`, visible in the witness log), so the app runs without its socket there. That is fine for a
  request-line witness and it is why the verdict runs go straight at `:8065`.
- **The relay's first version had a logging bug, and the log was wrong, not the app.** It split each read
  on CRLF; when a read ended mid-header, the next request line arrived glued to that header
  (`Authorization: Bearer …POST /api/v4/channels HTTP/1.1`) and was silently dropped. Two runs "proved"
  the app never sent `POST /channels` while the channel existed on the server. The script now searches each
  connection's stream for request lines (`REQUEST_LINE`); the witness above is from the fixed version.
  Anyone re-using this relay should keep that fix.
- **A sheet presented from a `confirmationDialog` action can be swallowed.** Measured under the relay
  (2 runs in a row): the tap on *Create a direct message* registered, the dialog dismissed, and the sheet
  never mounted, so the UI test failed at "the sheet must mount". Cause: the sheet's presentation was
  requested in the same run-loop turn in which UIKit was still dismissing the action sheet. The menu
  action now hops one turn (`DispatchQueue.main.async`), and the UI test re-opens the menu once and tries
  again if the sheet is not up. Both tests pass on the direct path and through the relay after that change.
- **No group DM, no channel conversion, no category work.** The card's scope is create-channel and
  start-a-DM; upstream's “create a group message” and GM→private conversion are different screens and are
  not here (they remain on the parity table).
- **The 65-character URL name is refused client-side only because the server answers `500`.** If a later
  server fixes that to a `400`, this rule can become a plain validation message; the code says which
  measurement it rests on.
- **`creator_id` on a read-back is not universal.** `GET /channels/{id}` carries `creator_id` for channels
  created through the API; the seeded `town-square` has it empty. The live suite therefore asserts the
  creator on the create answer's own record (`GET /teams/{tid}/channels/name/{name}`), not on a seeded one.

## 7. Identifiers (for the reviewer and the next card)

- Menu: `nativeSidebarCreateMenu`; rows `nativeSidebarCreate.createChannel`,
  `nativeSidebarCreate.browseChannels`, `nativeSidebarCreate.createDirectMessage`.
- Form: `createChannel.sheet`, `createChannel.form`, `createChannel.displayName`, `createChannel.urlName`,
  `createChannel.urlNameHint`, `createChannel.purpose`, `createChannel.header`, `createChannel.kind`
  (picker) / `createChannel.kindFixed`, `createChannel.validation`, `createChannel.error`,
  `createChannel.retry`, `createChannel.createError`, `createChannel.submit`, `createChannel.cancel`.
- Picker: `newDM.sheet`, `newDM.list`, `newDM.row.<userID>`, `newDM.empty`, `newDM.error`, `newDM.retry`,
  `newDM.cancel`, `newDM.openError`.
- Landing: `nativeChannelTitle` (the pane), `channelSidebar.channel.<channelID>` (the sidebar row).
- Tests: `MattermostTests/T47CreateChannelTests` (34), `MattermostUITests/T47CreateChannelUITests` (2).
- Run scripts: `scripts/t47_create_channel_probe.py` (server contract), `scripts/t47_logging_relay.py`
  (wire witness).

## 8. This card was verified in an isolated worktree, and why

The shared checkout was being edited at the same time by another card (T48, post options): at 19:33 the
Mac Catalyst build failed in `Thread/ThreadView.swift:261` on a symbol T48 was mid-move, not on anything in
this card. Rather than sit on a tree that does not compile, the T47 tree was re-created from `HEAD` in a
git worktree (`…/scratch/t47-wt`) with **only** T47's files applied, and every number in §5 was measured
there: `git status` in that worktree shows T47's files and nothing else. The commit in the shared checkout
carries the same file set (paths limited to T47's), which is the exact state that was verified.
