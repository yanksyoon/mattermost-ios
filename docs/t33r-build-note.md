# T33-R — the T33-AV repairs (native channel sidebar, S08)

Card: `t_eb428329` (repair). Validator it answers: T33-AV (`t_21b7e8d6`, `T33-AV-verdict.md`).
Base: `111718a` (T33). This note records **what was measured**, **what changed** for each finding, and
**how it was verified** — the same standard the T33 note is held to. It does not re-litigate the parts
T33-AV found green (list, grouping, unread/mention rows, mute suppression, quick switcher with real DMs,
flag gating, licence surface).

## 1. Order of work

F1 (HIGH) → F2 → F3 → F4 → F5 → F6 → F7. Nothing was deferred; nothing was re-scoped.

## 2. Measured on the pinned server before writing code

The validator's claims were re-measured on this host against the local throwaway server
(`mattermost/mattermost-team-edition:release-9`, `Version: 9.11.19`) with a one-off WebSocket probe (the
agent's own, not shipped: log in, open `ws://127.0.0.1:8065/api/v4/websocket`, act, dump every frame that
is not `hello`/`typing`/`status_change`). What that returned, verbatim in shape:

| Action | Frames the server publishes | Payload |
|---|---|---|
| `PUT /users/{uid}/teams/{tid}/channels/categories` with the **bare array** | `sidebar_category_updated` | `data.updatedCategories` = **JSON string** of the stored category array (id, user_id, team_id, sort_order, sorting, type, display_name, muted, collapsed, channel_ids); `broadcast.team_id` = the team, `broadcast.user_id` = me |
| …with the GET's `{order, categories}` envelope | ~~none~~ | HTTP **400** `api.context.invalid_body_param.app_error` — no event, nothing stored |
| `POST /channels/{cid}` (create) | `posted` (system message), `channel_created` | `data.channel_id`, `data.team_id` |
| `DELETE /channels/{cid}` | `posted` (system message), `channel_deleted` | `data.channel_id`, `data.delete_at`; **team only in `broadcast.team_id`** |
| `POST /channels/{cid}/members` (somebody else joins) | `user_added`, `posted` | — |
| `PUT /channels/{cid}/members/{uid}/notify_props` (my mute) | `channel_member_updated` (server source: `app/channel.go` `sendUpdateChannelMemberEvent`) | `data.channelMember` = **JSON string** of the whole membership row (channel_id, user_id, msg_count, mention_count, notify_props, …) |
| `POST /channels/members/{uid}/view` (**read**) | `multiple_channels_viewed`, `thread_read_changed` | `data.channel_times` = `{channel_id: last_viewed_at_ms}`; `broadcast.user_id` = me, **no channel, no team**. Published only when the view moved the read cursor. **Not** `post_unread` — see the next row (corrected in T33-R2/AV2-F1, re-measured: `docs/t33r2-build-note.md` §2) |
| mark-unread: `POST /users/{uid}/posts/{pid}/set_unread` | `post_unread` (server source: `app/channel.go` `sendWebSocketPostUnreadEvent`) | `data.msg_count`, `mention_count`, `mention_count_root`, `urgent_mention_count`, `last_viewed_at`, `post_id`; **channel and team only in `broadcast`** |

Two facts follow, and they are why the repairs look the way they do:

1. **The categories write's answer is a bare array, and the server tells every other client of mine
   over the socket** (`sidebar_category_updated`, team-scoped). F1 is a decode bug; F3 is a *missing
   event*, not a missing refetch. Applying the event's payload is both cheaper and more immediate than
   re-reading `GET …/categories` on a timer.
2. `post_unread`'s channel id exists **only** in the envelope, so the frame decoder needed `broadcast`
   (`MMSocketBroadcast`, `user_id`/`channel_id`/`team_id`) to type it at all.
3. **Corrected after T33-AV2 (F1):** this table originally attributed `post_unread` to the view call.
   The view call is answered by `multiple_channels_viewed`, and this repair's decoder did not model
   it — a channel read in another client of the same user left the row badged (measured). T33-R2
   re-measured both paths and modelled the event; `docs/t33r2-build-note.md` §2 has the frames.

## 3. What changed, finding by finding

### F1 (HIGH) — the categories write's answer now decodes; no write is rolled back

- `APIClient.updateSidebarCategories` decodes **`[MMSidebarCategory]`**, not `MMSidebarCategories`
  (`ChannelSidebarAPI.swift`). The doc comment records the measured request/answer shape and the 400
  the old body produced.
- `ChannelSidebarServing.save` returns `[MMSidebarCategory]`; `ChannelListViewModel.move`,
  `setFavorite` and `setCollapsed` rebase on it through one `applyLayout(_:)`.
- The drawn **order** is not thrown away with the answer: `ChannelSidebarDerivation.order(afterSaved:previous:)`
  keeps the previous order for every category the answer still contains and appends only a category the
  answer introduced (a `favorites` category created by a first favourite) — the write's array carries no
  `order`, and a channel move does not reorder categories.
- `setCollapsed` no longer `_ = try?`: it applies the server's answer on success and, on failure, puts
  the category's previous state back and sets `actionError` — same contract as a failed move. A local
  collapse that the server never stored would otherwise flip back at the next launch with no explanation.
- Regression tests: `testTheCategoriesWriteAnswerIsTheBareArrayTheServerSends` (the array decodes, and
  the keyed shape **throws** — the exact old defect), `testTheCategoryOrderSurvivesAnArrayAnswerAndTakesANewCategory`,
  `testAMoveRebasesOnTheServersAnswerInsteadOfRollingBack`, `testACollapseReachesTheServerAndSurvivesItsAnswer`,
  `testAFailedCollapsePutsTheCategoryBackAndSaysWhy`. Live: the shipped reorder test now asserts (a) the
  server order changed, (b) **the row on screen is in the new order**, (c) **no `channelSidebar.actionError`**;
  and `testCollapsingACategoryReachesTheServerAndSurvivesRelaunch` drives a real collapse and relaunch and
  asserts the server's stored value is what draws.

  **What that live collapse test does *not* prove** (T33-AV2 F3): it passes on base `111718a` too. The
  old `setCollapsed` already sent the **bare array**, so the server stored the collapse and the relaunch
  drew it; only the *answer's* decode threw and `_ = try?` swallowed it. The defect this repair removes
  is therefore **silent failure** — a write that fails is neither rolled back nor reported — and that is
  pinned at the unit level by `testAFailedCollapsePutsTheCategoryBackAndSaysWhy` and, since T33-R2, by a
  stub-backed UI test with a categories write that 500s
  (`testAFailedCollapsePutsTheCategoryBackAndSaysWhy` in the stub suite, `--categories-fail`). The
  earlier reading "the server never learns it" was wrong: it learned it, and then the client could not
  read the answer.

### F2 (MEDIUM) — the footer aggregate is desktop-exact

- `ChannelSidebarDerivation.totals` skips a muted channel **before** adding anything: no messages *and*
  no mentions, matching `selectors/entities/channels.ts` `getTeamsUnreadStatuses` ("if channel is muted,
  we skip its count"). The row is unchanged — a mention through a mute still badges on the row.
- `docs/parity.md` no longer claims the rail-alignment divergence; it records that T32's rail badges the
  server's `teams/unread` (a separate read-out, not the footer's source), so the two can differ by one
  muted mention and the footer deliberately follows desktop.
- Tests: `testTotalsExcludeAMutedChannelsMessagesAndMentionsLikeDesktop` (totals and the row, in one
  test, so the two rules cannot drift apart); the live muted test now asserts the footer stays
  "All caught up" after a muted mention, then that **unmuted** traffic does move it (non-vacuous).

### F3 (MEDIUM) — an external layout change reaches the open list

- `SocketEvent` gains `sidebarCategoryUpdated(SocketSidebarCategoryUpdate)`; `TeamSocketScope` accepts it
  for the team it names; `ChannelListViewModel.handle` applies the payload through the same
  `applyLayout(_:)` a local write uses and returns `.layoutChanged` (the coordinator fetches nothing —
  the event *is* the new state).
- Tests: `testACategoryUpdateFromAnotherClientReachesTheOpenList` (payload applied, no request, another
  team's layout ignored) and `testSidebarCategoryUpdatedDecodesTheStringPayload`; live
  `testALayoutChangeFromAnotherClientReachesTheOpenListWithoutARelaunch` — an external `PUT` while the
  app runs, asserting the rows move and `app.state == .runningForeground`.

### F4 (LOW) — the four claimed events are now modelled (not struck from the docs)

`channel_created`, `channel_deleted`, `channel_member_updated` and `post_unread` are typed with the
payloads measured in §2, scoped by `TeamSocketScope`, and acted on:

| Event | What the model does |
|---|---|
| `post_unread` (me) | the server's `msg_count`/`mention_count`/`last_viewed_at` applied to that row directly — no request, no local increment that could drift |
| `channel_member_updated` (me) | the whole membership row replaced (a mute set in another client, `manually_unread`, counters) |
| `channel_created` | `.reloadNeeded` → **one** debounced full reload (a counter refresh cannot add a row, and a new DM needs its label resolved) |
| `channel_deleted` | `.refreshNeeded` → the channel read drops the archived channel (archived rows are already hidden by the derivation except the one on screen) |

The rail also refreshes its counters on `post_unread` (`TeamSidebarCoordinator.handle`), since that event
moves the server's `teams/unread` too.

Tests: `testPostUnreadAppliesTheServersOwnCounters`, `testAnotherClientsMuteArrivesInMyMembershipRow`,
`testChannelCreatedAsksForAFullReloadAndDeletedForACounterRefresh`,
`testAChannelCreatedEventReloadsTheListOncePerDebounce`, `testTheScopeAttributesTheNewEventsToTheActiveTeam`,
and the four decode tests (`testSidebarCategoryUpdatedDecodesTheStringPayload`,
`testPostUnreadDecodesItsChannelFromTheEnvelope`, `testChannelMemberUpdatedDecodesTheRow`,
`testChannelCreatedAndDeletedDecodeTheirIds`).

### F5 (LOW) — a partial counter refresh keeps the last numbers and marks them stale

- `SessionChannelSidebarService.refresh` no longer swallows a non-401 `/users/me/channel_members`
  failure: it returns the channels it did get with `membersFailed = true` (`ChannelSidebarRefresh`).
- `ChannelSidebarData.replaceCounters(channels:members:membersFailed:)` keeps the previous members when
  the answer says it failed — and also when an empty membership answer arrives for a team that has
  channels (the shape the swallowed failure took), because that is not "everything is read" either. It
  returns whether the rows can be trusted; the model turns that into `countsAreStale`.
- Tests: `testAPartialCounterRefreshKeepsTheNumbersAndMarksThemStale` (**the production shape**:
  `membersFailed` + empty list) and `testAnEmptyMembersAnswerIsNotTreatedAsEverythingRead`, alongside the
  pre-existing throwing shape (`testAFailedCounterRefreshKeepsTheLastNumbersAndLabelsThemStale`).

### F6 (LOW) — the test's cleanup is a real write

`restoreChannelsOrder` sent the GET body (`{order, categories}`) and discarded the error, so the fixture
drifted every run. It now goes through `writeCategories(_:because:)`, which sends the **bare array** and
asserts `200`. The two new live tests reuse the same helper (external write, collapse) so there is one
place that knows the write's shape.

### F7 (LOW) — the debounce is documented as what it is

`ChannelSidebarCoordinator(refreshDelay:)` defaults to **1.5 s** and `MattermostApp` passes nothing; the
rail's `unreadRefreshDelay` is also 1.5 s. The default is deliberate (one screen, one debounce), and the
docs were wrong: §3/§5 of `docs/t33-build-note.md` and the T33 parity row now say 1500 ms.

## 4. Fixture

`scripts/t33_channel_seed.py` now also creates (idempotently, `POST /channels/direct`) the
perfprobe↔opsbot DM the quick-switcher DM case needs. Before this, that DM existed only because a
validator probe had made it by hand; a re-seeded server would have had no DM and the case would have
depended on run order.

## 5. Files touched

| File | Why |
|---|---|
| `Mattermost/Core/MM/SocketEvent.swift` | `MMSocketBroadcast` (+ `MMSocketFrame.broadcast`), the four new typed events and `sidebar_category_updated`, their decode (JSON-string-or-object payloads), `name`, `dedupeKey` |
| `Mattermost/UI/Native/Sidebar/ChannelSidebarAPI.swift` | the categories write decodes `[MMSidebarCategory]` |
| `Mattermost/UI/Native/Sidebar/ChannelSidebarService.swift` | protocol `save` returns the array; `refresh` reports a members failure; the event → outcome mapping and the local applies (`post_unread`, membership row, layout); `setCollapsed` applies/reports; `applyLayout` |
| `Mattermost/UI/Native/Sidebar/ChannelSidebarModels.swift` | `membersFailed` on `ChannelSidebarRefresh`; `replaceCounters` returns "trusted" and keeps the old rows; `totals` desktop-exact; `order(afterSaved:previous:)` |
| `Mattermost/UI/Native/Sidebar/ChannelSidebarCoordinator.swift` | `.layoutChanged`/`.applied` fetch nothing; `.reloadNeeded` = one debounced full reload (`reloadCount`); 1.5 s documented; `deactivate` clears the pending reload |
| `Mattermost/UI/Native/Sidebar/TeamSocketScope.swift` | the five new cases, attributed by channel (or by team for `channel_created`/`sidebar_category_updated`) |
| `Mattermost/UI/Native/Sidebar/TeamSidebarCoordinator.swift` | `post_unread` also refreshes the rail's counters |
| `MattermostTests/T33-ChannelSidebarTests.swift` | 17 new tests (51 → 68), the totals test rewritten to the desktop rule, the fake returns the production answer shape |
| `MattermostUITests/T33-ChannelSidebarUITests.swift` | reorder test asserts the row on screen + no action error; muted test asserts the footer stays silent; two new live tests (external layout, collapse); the cleanup writes the bare array and asserts 200 |
| `scripts/t33_channel_seed.py` | creates the DM |
| `docs/t33-build-note.md`, `docs/parity.md` | F2 rule, F4/F7 event and debounce text, test counts, §12 pointer |

No new production surface, no new dependency, and the sidebar surface stays **out** of
`SurfaceDefaults.nativeApprovedSurfaces` (still `[.auth]`) — the flip is a separate decision after
T33-AV re-validates this repair.

## 6. Runs

See §7 for the exact commands. Verdicts are the runner's own (`scripts/qa-test.py` prints
`RESULT: PASS` only when `xcodebuild` exits 0):

| Run | Command | Verdict | Counts |
|---|---|---|---|
| Catalyst units, T33 class | `qa-test.py --platform mac --only-testing MattermostTests/T33ChannelSidebarTests --label t33r-units` | **PASS** (`rc=0`) | 68 run / 0 skipped / 0 failed |
| Catalyst units, whole `MattermostTests` | `qa-test.py --platform mac --label t33r-units-all` | **PASS** (`rc=0`, 62 s) | 765 run / 4 skipped / 0 failed |
| T33 UI suite (7 live + 4 stub), iPad Pro 11-inch M5 / iOS 26.0, real 9.11.19 server | `qa-test.py --platform ios --sim 289B1C9B-D933-4181-BB0B-8EA48B874F66 --only-testing MattermostUITests/T33ChannelSidebarUITests --only-testing MattermostUITests/T33ChannelSidebarStubTests --label t33r-ui2` | **PASS** (`rc=0`, 391 s) | 11 run / 0 skipped / 0 failed |

The first UI run of this pass was **FAIL** on two expectations, both recorded because they are the
interesting kind:

1. `T33ChannelSidebarStubTests/testTheListDrawsTheStubsCategoriesInTheServersOrder` — the stub fixture
   still expected the *old* footer (`"3 mentions, 3 unread messages"`); the app now answers
   `"2 mentions, 3 unread messages"`, i.e. the F2 rule, from the same fixture. The stub's expectation
   was updated (`build/uitest-server/mm_stub.py` also takes the bare array now, and 400s the keyed
   body like the real server).
2. `T33ChannelSidebarUITests/testTheSidebarRendersTheServersChannelsAndCategories` — it asserted every
   row's label equals the server's `display_name`, which for a DM is empty and whose `name` is
   `id__a__b`; the row correctly drew **`opsbot`**. That test only passed before because the fixture
   had no DM at the moment it ran (the T33-AV probe made one by hand *after* it). The seed now creates
   the DM (§4), so the assertion is resolved the way the app resolves it (`expectedLabel(for:)`) and a
   GM is asserted not to be drawn as its raw id. This is a test-fixture bug that the repair exposed,
   not a production regression.

Both fixed; the rerun is the **PASS** in the table above. Every UI test ran against the real server (no
stub) except the four `T33ChannelSidebarStubTests`, and the screenshots XCTest attached to that run were
exported (`xcrun xcresulttool export attachments`) into `docs/t33-shots/` — `t33-01`…`t33-12`, refreshed
from this build, including the three new ones:

| Shot | What it shows |
|---|---|
| `t33-10-reorder-on-screen.png` | the row on screen after "Move up", before any relaunch — the T33-AV F1 defect left this unchanged |
| `t33-11-external-layout.png` | the list **after another client's `PUT`** while the app was running: `Town Square` first, and `opsbot` as the DM's label |
| `t33-12-collapsed-after-relaunch.png` | a cold start with `CHANNELS` collapsed — the server's stored `collapsed: true`, drawn |

One artefact in that `.xcresult` is **not** from this card: a crash report attached to the stub DM test
is `EXC_BREAKPOINT` inside `T34MarkdownTests.testEmphasisNests()` (`Array._checkSubscript`), i.e. an
index out of range in T34's own untracked test in the other worker's checkout. Nothing in the T33-R
diff is on that stack, and the app process did not crash; recorded here so a later reader does not
mistake it for this repair.

### The licence surface

`SurfaceDefaults.nativeApprovedSurfaces` is still `[.auth]` (`Mattermost/Core/RenderMode.swift:92`), i.e.
the sidebar did **not** flip itself on the strength of this repair. The gate script agrees:

```
$ bash scripts/verify-dual-render-gates.sh --allow-approved-registry
RESULT: PASS — dual-render debug affordances cannot reach a Release build.
```

(`--allow-approved-registry` is required because the one `.auth` entry's evidence is T31-AV's, not this
run's: without the flag, gate 5 correctly refuses to accept an approval registry from an arbitrary run.)

### Where these runs happened, and why

`Mattermost/UI/Native/Channel/` is **untracked work in progress from another card (T34)** in the main
checkout; with it present, `xcodebuild` fails inside `MarkdownParser.swift` before reaching T33's code.
So the runs above were made in a dedicated worktree of this branch's base
(`.worktrees/t33r`, `git worktree add .worktrees/t33r 111718a`) carrying exactly this repair's diff —
the tree that gets committed is the same content for every file this card touches, and nothing from
T34 was read, built or changed. `build-for-testing` in that worktree: **TEST BUILD SUCCEEDED**.

