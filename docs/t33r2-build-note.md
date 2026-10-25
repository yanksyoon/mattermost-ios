# T33-R2 — closing the T33-AV2 docs/coverage findings (no surface flip)

Card: `t_98c39e49` (repair of the review's findings, not of the product). Validator whose findings it
closes: T33-AV2 (`t_8c99e10a`, `T33-AV2-verdict.md`). Base: `d9d55c5` (T33-R). Branch: `t33r2`.

Scope statement, up front: **this card changes exactly one behaviour** — it models the
`multiple_channels_viewed` event (AV2-F1 decision **(a)**). Everything else is documentation, a test
comment, a stub fixture mode and test coverage. `SurfaceDefaults.nativeApprovedSurfaces` is untouched
(still `[.auth]`); the sidebar flip remains a separate decision.

## 1. Why the one behaviour change, and which option the card chose

AV2-F1 offered two outcomes: (a) model `multiple_channels_viewed`, or (b) record it as a known gap.
**This card did (a).** The reason is the measured user-visible consequence, not tidiness: with the list
open, a *second client of the same user* reads a channel, the server's unread goes to 0, and the row
kept reading `Unread` until some unrelated event triggered a counter refresh (the validator measured
≥15 s). A stale badge is exactly the class of defect the sidebar must not ship with. The decode is one
map and one `clearCounters` loop per channel, so the risk is small and is pinned by five unit tests, one
scope test and one live UI test (§4).

## 2. Measured before writing the code

One throwaway probe (not shipped), against the pinned server (`mattermost/mattermost-team-edition:release-9`,
`Version: 9.11.19`, `127.0.0.1:8065`), with a **real websocket** authenticated as the fixture user. It
seeds an unread post as `opsbot`, then performs each call and dumps every frame verbatim. The frames
below are the server's own JSON (whitespace trimmed), not a reconstruction:

```
POST /api/v4/channels/members/{uid}/view            -> 200
  event: multiple_channels_viewed
  data: {"channel_times": {"re4jed6wti8e8g9jt8aza9ewye": 1792961099716}}
  broadcast: {"user_id": "<me>", "channel_id": "", "team_id": ""}
  event: thread_read_changed
  data: {"timestamp": 1792961101768}
  broadcast: {"user_id": "<me>", "channel_id": "re4jed6wti8e8g9jt8aza9ewye", "team_id": ""}

POST /api/v4/users/{uid}/posts/{pid}/set_unread     -> 200
  event: post_unread
  data: {"last_viewed_at": 1792961099715, "mention_count": 0, "mention_count_root": 0,
         "msg_count": 76, "msg_count_root": 76, "post_id": "<pid>", "urgent_mention_count": 0}
  broadcast: {"user_id": "<me>", "channel_id": "<channel>", "team_id": "<team>"}
```

Facts this settles, each of which the earlier docs got wrong in some way:

1. The **view** call is answered by `multiple_channels_viewed` + `thread_read_changed`. It does **not**
   emit `post_unread`. `post_unread` belongs to the **mark-unread** call
   (`POST /users/{uid}/posts/{pid}/set_unread`, mattermost's `Client4.SetPostUnread`).
2. `multiple_channels_viewed` names **neither a channel nor a team** in its envelope: the only routing
   fact is `broadcast.user_id` (me). The channels are the keys of `data.channel_times`, whose values are
   the server's `last_viewed_at` in ms. So team attribution has to come from the channel ids.
3. The event is published **only when the view moved the read cursor**. A view of an already-read
   channel emitted *no* frame at all in the first probe run (that is why the probe seeds unread first).
   A client can therefore never depend on a view producing an event.
4. `post_unread`'s channel *and* team are in the envelope (the T33-R note said "channel and team only in
   `broadcast`" — that is right), and `data` carries `msg_count`, `msg_count_root`, `mention_count`,
   `mention_count_root`, `urgent_mention_count`, `last_viewed_at`, `post_id`.

## 3. Finding by finding

### AV2-F1 (MEDIUM) — the documented "view clears the row" path was not the server's path

- **Code narrowed, not just docs.** `Mattermost/Core/MM/SocketEvent.swift`: the `post_unread` doc now
  says "sent to **me** when a post is **marked unread**", names
  `POST /users/{uid}/posts/{pid}/set_unread`, and points at this note for the measurement.
- **The event is modelled.** New `SocketMultipleChannelsViewed { userID, channelTimes }` + case
  `multipleChannelsViewed`, decoded from `data.channel_times`, `name` = `multiple_channels_viewed`,
  `dedupeKey` = nil (a repeated view of the same channel is a genuine event). A frame with no
  `channel_times` is dropped rather than typed with an empty map.
- **Applied like `channel_viewed`.** `ChannelSidebarService.handle`: the frame clears every channel it
  names that the loaded member rows hold (a channel the list does not have is skipped — "read" is no
  reason to insert a row), and returns `.counters` so the footer moves too. `TeamSocketScope` accepts it
  when **any** named channel belongs to the team on screen (it may not be attributed by envelope),
  and `TeamSidebarCoordinator` refreshes the rail's `teams/unread` on it, because a read moves those too.
- **Docs corrected** (`docs/t33r-build-note.md` §2 table + a numbered correction after it,
  `docs/t33-build-note.md` §5, the T33 row of `docs/parity.md`): the view path no longer claims a
  follow-up `post_unread`; the mark-unread endpoint is named; the row also records the new event.
- **Coverage**: unit `testMultipleChannelsViewedDecodesTheChannelTimesMap`,
  `testAMultipleChannelsViewedFrameWithoutTimesIsDropped`,
  `testAReadFromAnotherClientClearsEveryRowItNames`, `testAnotherUsersMultipleViewDoesNotClearMyRows`,
  `testAMultipleViewOfUnknownChannelsIsIgnored`, plus the scope assertions in
  `testTheScopeAttributesTheNewEventsToTheActiveTeam`; live
  `testAReadFromAnotherClientOfTheSameUserClearsTheRow` — **the discriminating UI test**: a post from
  another user badges the row, then the same user's *view call* must clear it within 15 s. On
  `d9d55c5` that test's last assertion fails (the validator measured it, this card re-measured the
  frame). `t33-13-external-view` is the screenshot.

### AV2-F2 (LOW) — three stale line counts

Re-measured with `wc -l` in this tree, and the whole table was re-checked, not only the three rows
(`docs/t33-build-note.md` §3): `T33-ChannelSidebarUITests.swift` 687 → **811**,
`T33-ChannelSidebarStubTests.swift` 214 → **264**, `scripts/t33_channel_seed.py` 167 → **188**;
`ChannelSidebarService.swift` 658 → **672** and `T33-ChannelSidebarTests.swift` 1245 → **1335** also
moved *because of this card*, so they are updated in the same edit. The test counts in that table and in
`docs/parity.md` follow: 68 → **73** unit tests, 7 → **8** live UI tests, 4 → **5** stub-backed UI tests.

### AV2-F3 (LOW) — the collapse test did not discriminate, and its comment said the wrong thing

- **Comment corrected, and the reading corrected.** `T33ChannelSidebarUITests`'s collapse test now says
  what it pins (a collapse is stored and drawn from the server after a relaunch) and what it does not
  (it passes on base `111718a` as well, because the old `setCollapsed` already PUT the bare array; only
  the answer's decode threw and `_ = try?` swallowed it). `docs/t33r-build-note.md` §3/F1 says the same:
  the defect is **silent failure**, pinned at unit level by
  `testAFailedCollapsePutsTheCategoryBackAndSaysWhy`.
- **The failure path now has a UI-level discriminating test.** `build/uitest-server/mm_stub.py` gained
  `--categories-fail` (500 on the categories `PUT`, the only way to make one write fail on demand);
  `T33ChannelSidebarStubTests.testAFailedCollapsePutsTheCategoryBackAndSaysWhy` asserts the banner
  (`channelSidebar.actionError`) appears *and* the rows come back. On the old `try?` code the header
  would have stayed collapsed with no banner, so this test fails there — it discriminates.
- **Order independence.** The live suite's `setUp` now calls `resetFixtureToVisibleAndRead()`
  (`collapsed=false`, only actually-muted channels unmuted, everything read). The tests clean up in
  `defer`, which does not run when the test host dies; the validator observed a collapsed category
  turning the *next* test's "channel … not on screen" assertion into a false failure. Channels *order*
  is deliberately not reset: the reorder test records what it found and restores exactly that.

## 4. Files touched

| File | Why |
|---|---|
| `Mattermost/Core/MM/SocketEvent.swift` | `post_unread` doc narrowed to mark-unread (+ endpoint); `SocketMultipleChannelsViewed` + `.multipleChannelsViewed` case, decode, `name`, `dedupeKey` |
| `Mattermost/UI/Native/Sidebar/ChannelSidebarService.swift` | applies the view event to every loaded channel it names; `handle` doc corrected |
| `Mattermost/UI/Native/Sidebar/TeamSocketScope.swift` | attributes the team-less view event by its channel ids |
| `Mattermost/UI/Native/Sidebar/TeamSidebarCoordinator.swift` | the rail also refreshes its counters on the view event |
| `MattermostTests/T33-ChannelSidebarTests.swift` | 5 new unit tests (2 decode, 3 model) + scope assertions |
| `MattermostUITests/T33-ChannelSidebarUITests.swift` | `setUp` fixture reset; new live test for an external read; the collapse test's comment corrected |
| `MattermostUITests/T33-ChannelSidebarStubTests.swift` | new failing-collapse UI test (stub 8122) |
| `build/uitest-server/mm_stub.py` | `--categories-fail` |
| `docs/t33r-build-note.md`, `docs/t33-build-note.md`, `docs/parity.md` | the corrections above, re-measured line counts and test counts |
| `docs/t33r2-build-note.md` | this note |

Not touched: `Mattermost/Core/RenderMode.swift` (no surface flip), any T34 file, any T33 UI code.

## 5. Runs

Verdicts are `scripts/qa-test.py`'s own (`RESULT: PASS` only when `xcodebuild` exits 0), on this host.

<!-- RUNS -->

| Run | Command | Verdict | Counts |
|---|---|---|---|
| Catalyst units, whole `MattermostTests` | `qa-test.py --platform mac --label t33r2-units-all` | **PASS** (`rc=0`, 45 s) | **770 run / 4 skipped / 0 failed** (765 + this card's 5) |
| Catalyst units, the T33 class alone | `qa-test.py --platform mac --only-testing MattermostTests/T33ChannelSidebarTests --label t33r2-units` | **PASS** (`rc=0`, 45 s) | **73 run / 0 skipped / 0 failed** (68 + 5) |
| **The acceptance command**: 8 live + 5 stub UI tests, iPad Pro 11-inch (M5) / iOS 26.0, real 9.11.19 server + stubs 8120/8121/8122 | `qa-test.py --platform ios --sim DC3E9FB7-… --only-testing MattermostUITests/T33ChannelSidebarUITests --only-testing MattermostUITests/T33ChannelSidebarStubTests --label t33r2-ui-all2` | **PASS** (`rc=0`, 278 s) | **13 run / 0 skipped / 0 failed** — the single green full invocation T33-AV2 could not get on this host |
| Stub suite alone (`--categories-fail` fixture included) | `… --only-testing MattermostUITests/T33ChannelSidebarStubTests --label t33r2-ui-stubs` | **PASS** (`rc=0`, 132 s) | **5 run / 0 skipped / 0 failed** |
| The new live view test alone | `… --only-testing …/testAReadFromAnotherClientOfTheSameUserClearsTheRow --label t33r2-ui-extview` | **PASS** (`rc=0`, 23 s) | 1 run / 0 skipped / 0 failed |
| The collapse test alone (after rebooting the simulator) | `… --only-testing …/testCollapsingACategoryReachesTheServerAndSurvivesRelaunch --label t33r2-ui-collapse3` | **PASS** (`rc=0`, 49 s) | 1 run / 0 skipped / 0 failed |
| Licence surface | `bash scripts/verify-dual-render-gates.sh --allow-approved-registry` | **PASS** | `nativeApprovedSurfaces = [.auth]` (`RenderMode.swift:92`), unchanged in this diff |

### The new tests discriminate (mutation runs, by design FAIL)

A test that passes on both sides of a repair proves nothing, so both new failure-path tests were run
against a tree that does not carry the fix. The worktrees carried **only** this card's test files (no
production change), and were removed afterwards.

| Tree | Test | Result |
|---|---|---|
| `d9d55c5` (T33-R: the event is not modelled) | `T33ChannelSidebarUITests/testAReadFromAnotherClientOfTheSameUserClearsTheRow` | **FAIL, 1 run / 1 failed** — `… must clear the row through multiple_channels_viewed (T33-AV2 F1), got 'Unread' 15 s later`. The AV2-F1 gap, reproduced by the shipped test. |
| `111718a` (T33: `setCollapsed` was `_ = try?`) | `T33ChannelSidebarStubTests/testAFailedCollapsePutsTheCategoryBackAndSaysWhy` | **FAIL** on exactly the two intended assertions: no `channelSidebar.actionError` ("the old code discarded it with `try?` and said nothing") and the rows did not come back. |
| `111718a` (same run) | the **shipped live** `testCollapsingACategoryReachesTheServerAndSurvivesRelaunch` | **PASS** (34 s) — which is exactly AV2-F3's point and what the corrected comment on that test now says: it does not discriminate; the stub test does. |

### Environment incidents (recorded, not attributed to this card)

1. **One combined UI invocation lost six tests to test-host restarts.** `t33r2-ui-all` ended
   `rc=65` with `0 run` in the runner's summary and six tests named under "Failing tests" that have no
   pass/fail line: XCTest restarted the runner 6 times ("Restarting after unexpected exit, crash, or
   test timeout"), and the tests lost that way never start. Host log:
   `~/Library/Logs/DiagnosticReports/SimRenderServer-2026-10-25-140150.ips` — the simulator's render
   server crashed at 14:01:50, mid-run. Every lost test then passed individually.
2. **`simctl shutdown` + `boot` fixed it.** After rebooting the iPad, `t33r2-ui-all2` was green
   **13/13 in one invocation** (278 s), so the suite does not need per-test runs on a healthy host.
3. **The collapse test failed twice before the reboot** (`t33r2-ui-collapse`, `…-collapse2`: `0 run`,
   `rc=65`) at the relaunch leg, with the runner restarting after `app.terminate()`. This is the same
   leg T33-AV2 saw flake once; after the reboot it passed (49 s) and it also passed inside the 13/13
   run.

## 6. What this card does **not** claim

- **The app still never posts a view.** With no message pane (T34) there is nothing to read inside the
  app, so the client only *consumes* the event today. T34's post list / the view call is where a read
  becomes an action this app performs; the docs say so and the flip decision should be taken with it.
- **`thread_read_changed` is not modelled.** Threads are S13/T36; the event is dropped as `unhandled`
  (it still counts). Nothing in the sidebar depends on it.
- **`post_unread`'s `msg_count_root` / `mention_count_root` are not used.** The root (thread) counters
  are T36's; the sidebar reads the channel-level numbers it draws.
- **No drag-and-drop, no category management, no create-channel** — unchanged T33 limits.

## 7. A collision to expect in the shared checkout (T34)

`Mattermost/UI/Native/Channel/ChannelViewModel.swift` (T34's **untracked** work in the main checkout at
the time of writing) switches over `SocketEvent` exhaustively, ending in
`case .hello, .typing, …, .postUnread, .unhandled:`. Adding `.multipleChannelsViewed` to the enum makes
that switch non-exhaustive, so the next build of the shared checkout fails with
`Switch must be exhaustive` in **T34's file**, not in any file this card touched. The fix is one token:

```swift
case .hello, .typing, .statusChange, .preferencesChanged, .userUpdated,
     .sidebarCategoryUpdated, .channelCreated, .channelDeleted, .channelMemberUpdated,
     .multipleChannelsViewed, .postUnread, .unhandled:
```

Nothing T33 owns needed that line: `TeamSocketScope`, `ChannelSidebarService` and `TeamSidebarCoordinator`
handle the case, and `MattermostTests`/`MattermostUITests` build clean. The collision is recorded here
rather than fixed across a card boundary, and flagged on T34's card (`t_c5100c73`).
