# T33 — native channel sidebar (S08: list, categories, ordering, unread, mute, favourites, quick switcher)

Card: `t_79b18ed2` (T33). Surface: `sidebar` (S08 `channel list`), behind `-surfaceMode sidebar=native`.
Predecessors: T30 (shell/navigation + `nativeSidebar` identifiers), T32/T32-R (team rail, one socket per
server). Successor: T33-AV (adversarial validation), which must not trust this note.

## 1. What this card is

The rail from T32 fronts a channel list. This card replaces T30's placeholder with the real one: the
server's channel **categories** and their order, the channel rows with their type glyph, bold-while-
unread name, mute marker and mention badge, an aggregate footer, and a quick switcher (⌘K equivalent)
that fuzzy-matches channels and DMs and navigates through `NativeNavigation`.

It is a *read-mostly* surface with exactly three writes, each of which the server owns:

| User action | Write |
|---|---|
| reorder a channel (context menu **Move up/Move down**) | `PUT /users/{uid}/teams/{tid}/channels/categories` — the whole category array |
| favourite / unfavourite | the same `PUT`, with the channel added to / removed from the `favorites` category |
| mute / unmute | `PUT /channels/{cid}/members/{uid}/notify_props` with `mark_unread: mention` / `all` |

## 2. Source of truth and licence boundary

Reference is `mattermost/mattermost-mobile` at **v2.45.0**, commit
`162f2560d0e1df073220f7701d5a67cc17c8abeb` (Apache-2.0). The files read, and what each fixed, are listed
in `docs/THIRD_PARTY_NOTICES.md` §10. No TypeScript is copied or transpiled; the Swift types are written
against `https://api.mattermost.com` and this repo's own `APIClient`/`SocketClient`/`NativeNavigation`.
SF Symbols stand in for every `compass-icons` glyph.

## 3. Files

| File | Lines | Role |
|---|---|---|
| `Mattermost/UI/Native/Sidebar/ChannelSidebarModels.swift` | 738 | the **derivation** — everything that can be decided without I/O: category/channel tree, sort rules (manual / recent / alpha, muted last in alpha), unread = `max(total_msg_count − msg_count, 0)`, the mute rule, favourites, archived filtering, search terms + fuzzy ranking, the two content states, the aggregate (desktop-exact: a muted channel counts for nothing), the order a write's array answer leaves behind |
| `Mattermost/UI/Native/Sidebar/ChannelSidebarService.swift` | 672 | I/O: load, counter refresh (a failed members call is reported, never treated as "all read"), category reads/writes — `PUT` the **bare array** and rebase on the array it answers with (T33-R/F1); a **generation** guard so a stale load can never overwrite a newer team; the socket event → outcome mapping (`channel_viewed`, `multiple_channels_viewed`, `post_unread`, `channel_member_updated`, `sidebar_category_updated`, `channel_created`, `channel_deleted`) |
| `Mattermost/UI/Native/Sidebar/ChannelSidebarCoordinator.swift` | 318 | one `ChannelListViewModel` per **server**; subscribes to `NativeNavigation.location` and to the auth phase; **reuses T32's single socket** (`TeamSocketScope`) instead of opening a second one; publishes the channel→team map the scope needs; coalesces socket-driven refreshes at **1500 ms** (the rail's own debounce) into one counter refresh — or one **full reload** after a `channel_created` |
| `Mattermost/UI/Native/Sidebar/ChannelSidebarAPI.swift` | 93 | the endpoints, in one place (the categories write decodes `[MMSidebarCategory]`) |
| `Mattermost/UI/Native/Sidebar/ChannelSidebarView.swift` | 388 | the UI: category sections with collapse, rows, aggregate footer, quick-switcher button, context menu |
| `Mattermost/UI/Native/Sidebar/QuickSwitcherView.swift` | 153 | the ⌘K sheet: search field + result list |
| `MattermostTests/T33-ChannelSidebarTests.swift` | 1335 | 73 unit tests (pure derivation + view model against a fake service + coordinator + the socket frame decodes) |
| `MattermostUITests/T33-ChannelSidebarUITests.swift` | 811 | 8 **live** UI tests against a real server (see §6) |
| `MattermostUITests/T33-ChannelSidebarStubTests.swift` | 264 | 5 stub-backed UI tests: the flag **both ways**, a fixed server order, a DM found by username, the error state, and a categories write that 500s |
| `scripts/t33_channel_seed.py` | 188 | idempotent fixture: the second user is a member of the team's channels, everything is read, nothing is muted, and it prints the server's own numbers + category list |

The stub server (`build/uitest-server/mm_stub.py`) grew the T33 fixtures this suite needs
(`stub_channels()`, `stub_channel_members()`, `stub_categories()`, `--channels-fail`,
`--categories-fail` — added by T33-R2 for the failed-collapse path — and a `do_PUT`
that echoes both writes), so the sidebar's rules can be driven deterministically without mutating a
real fixture before every run.

Touched elsewhere (minimal, each with a comment saying why):

- `Mattermost/Core/MM/MMTypes.swift` — `MMChannel` gains `create_at`/`delete_at`; the category wire types.
- `Mattermost/Core/MM/APIClient.swift` — a `PUT` with a JSON body that decodes a typed answer (the
  categories write is the first write in this client that returns a new server state).
- `Mattermost/Core/Store/MMStoreModels.swift` — `MMChannelMember` tolerates both wire shapes
  (`/users/me/channel_members` omits fields that `/channels/{id}/members` sends).
- `Mattermost/UI/Native/Sidebar/TeamSidebarCoordinator.swift` — hands the channel→team map to
  `TeamSocketScope`, so `post_unread` for a non-selected team is refused without a second socket.
- `Mattermost/UI/Native/NativePanePlaceholders.swift` — mounts the list inside the pane (the T30
  placeholder stays for `sidebar=web`).
- `Mattermost/MattermostApp.swift` — app-level `@StateObject` + `.environmentObject`, and
  `authPhaseChanged` wiring, exactly like the rail.
- `Mattermost/UI/Native/NativeShellView.swift` — split column 260/320/420 instead of 200/260/340: the
  column holds the 64 pt rail *and* the list, and at 260 the list was ~196 pt wide where "Off-Topic"
  drew as "Off-…" (found by looking at the first screenshot, not by a test).

## 4. The rules, and where each comes from

### 4.1 Grouping and order = the server's sidebar categories

On the pinned server (v9.11.19) the sidebar's storage is **not** a `Preferences` row — a probe of
`GET /users/{id}/preferences` returns categories `channel_approximate_view_time`, `onboarding_task_list`,
`recommended_next_steps`, `system_notice`, `teams_order`, `tutorial_step` and nothing about the sidebar.
The authority is the dedicated endpoint the web app itself uses:

```
GET  /api/v4/users/{uid}/teams/{tid}/channels/categories
→ {"order": ["favorites_<uid>_<tid>", "channels_<uid>_<tid>", "direct_messages_<uid>_<tid>"],
   "categories": [{"id": …, "type": "channels", "sorting": "", "channel_ids": [...], "collapsed": false}, …]}
PUT  /api/v4/users/{uid}/teams/{tid}/channels/categories      (the whole array — what a reorder writes)
```

So "matches the server's `sidebar_preferences`" is read as "matches the server's category list", which is
what the card's reference endpoint resolves to on this server version. The client draws:

- categories in the server's `order`;
- `channels` / `direct_messages` under those keys, a custom category under its `display_name`;
- a channel in exactly **one** place (a stale layout that lists a channel twice would otherwise draw it
  twice — the derivation de-duplicates, first category wins);
- a channel the server's categories do not list is appended to the default category for its kind rather
  than dropped (that is the state a fresh membership is in before the server's own grouping catches up);
- an empty category is not drawn — except favourites, whose emptiness is the "nothing favourited" state;
- archived channels (`delete_at != 0`) are hidden, unless it is the channel currently open.

Sorting per category: `manual` (the server's `channel_ids` order), `recent` (`last_post_at`, then
`create_at`), `alpha` (display name, **muted last**, tie by id — mobile's `sortChannels`).

### 4.2 Unread, mentions, mute

`unread = max(total_msg_count − msg_count, 0)` where the two numbers come from different payloads
(`/users/me/teams/{tid}/channels` and `/users/me/channel_members`) — the web app's arithmetic, and the
live test asserts against the server's own two numbers rather than against a computed fixture.

Muted = `member.notify_props.mark_unread == "mention"` (mobile's `isChannelMuted`). The row rule, which
is the whole of criterion 3:

| state | bold | badge |
|---|---|---|
| muted, 5 unread messages | no | none |
| muted, 1 mention | **yes** | count |
| unmuted, unread messages, no mention | yes | dot |
| unmuted, mentions | yes | count |

**A finding this card had to settle** (found by a live test failing, then probed on the server): the
server's counters are *not* mute-aware. With `mark_unread: mention`, `total_msg_count` and `msg_count`
still move apart by one after an ordinary post, so the server reports 1 unread message in a muted
channel; only the client suppresses it. The live test therefore asserts the server's 1 **and** the row's
silence, so the second assertion cannot be vacuous. Mentions are incremented regardless — which is what
`mark_unread: mention` means.

That also fixed an inconsistency the first screenshot exposed: the aggregate footer excluded muted
channels *entirely*, while the T32 rail above it badges the server's `teams/unread`, which counts the
muted channel's mention. The first repair kept a muted channel's mentions in the footer so the two
read-outs agreed — **T33-AV F2 measured that against criterion 3 and it lost**: desktop's
`getTeamsUnreadStatuses` skips a muted channel before *either* count, and the criterion says "the same
way desktop does". The footer is therefore desktop-exact (no messages **and** no mentions from a muted
channel), and the rail/footer difference is recorded as what it is in `docs/parity.md`: the rail badges
the server's team total, the footer is this client's badge total. See §12.

### 4.3 Quick switcher

Local-first: it ranks the loaded channels (no request per keystroke). Order: exact name, prefix,
word-start, substring, then subsequence ("pffd" finds `perf-feed` — asserted live), with a small bonus for
DMs and favourites; `#name` and `@handle` are accepted; DMs match the other person's username, not the
`id__id` channel name. Tap → `NativeNavigation.openChannel`, the same funnel a deep link uses.

## 5. Socket, lifetime, and why nothing can go stale

T32 owns **one socket per server**. T33 plugs into it:

- `ChannelSidebarCoordinator` hands `TeamSocketScope` the channel→team map after every load, so an event
  is accepted only if it belongs to the team on screen.
- Events that matter, all now **modelled** (`SocketEvent`, decoded from the frame the pinned server
  actually sends — measured, see `docs/t33r-build-note.md` §2 and `docs/t33r2-build-note.md` §2):
  `posted`, `post_edited`, `post_deleted`, `preferences_changed` → `.refreshNeeded` (one coalesced
  counter refresh per **1500 ms**, the rail's own debounce); `channel_viewed` for **me** → zero that
  row; `multiple_channels_viewed` for me → the **view call's** event (`POST
  /channels/members/{uid}/view`, `data.channel_times`), applied as "these rows are read" — this is what
  clears a row read in another client of mine without a relaunch (T33-AV2 F1);
  `post_unread` for me → the server's counters applied (this is the **mark-unread** event,
  `POST /users/{uid}/posts/{pid}/set_unread` — it is not the answer to a view, which the earlier
  version of this paragraph claimed); `channel_member_updated` for me → the
  membership row (mute set in another client) applied; `sidebar_category_updated` → the layout the
  server stored is applied to the open list (that is what makes an external reorder/collapse visible
  without a relaunch); `channel_created` → one debounced **full** reload; `channel_deleted` → the
  ordinary counter refresh (the channel read drops it).
- Team switch: the location subscription compares the model's team with `NativeNavigation.location`; a
  different team **always** reloads (a SwiftUI re-mount of the same team does not — `load(ifNeeded:)`
  answers from `loadedTeamID`).
- A load carries a generation number; a response that arrives after a newer load or a team switch is
  dropped, not merged.
- Sign-out/expiry/server removal → `deactivate` (no list, no channel→team map outliving the credential).
- App-level ownership (`@StateObject` in `MattermostApp`), so the list survives a pane rebuild and does
  not refetch on every navigation.

## 6. Acceptance criteria → evidence

| Criterion | Where it is decided | Test | Live evidence |
|---|---|---|---|
| Ordering/grouping match the server's sidebar layout; **a reorder persists across relaunch** | `ChannelSidebarDerivation.groups/sorted`; `ChannelSidebarService.move` → `PUT categories` | `testGroupsFollowTheServersOrderAndOwnTheirChannels`, `testTheOrderArrayDecidesTheDrawnOrderAndUnknownCategoriesAreAppended`, `testManualSortingUsesTheCategoryChannelIds`, `testRecentSortingUsesTheNewerOfLastPostAndCreation`, `testAlphaSortingPutsMutedChannelsLastThenAlphabetically`, `testMovingAChannelPersistsManualOrderToTheServer`, `testAReorderSurvivesARelaunch` (a second model loads from the array the fake server was given) | `testAReorderThroughTheContextMenuWritesTheServerAndSurvivesRelaunch` — long-presses a row, taps **Move up**, reads the server's `channel_ids` back, **asserts the row on screen is in the new order and that no `channelSidebar.actionError` exists** (the two things the T33-AV F1 defect needed), kills the app, relaunches, compares row positions; then restores the order through the same write (t33-09, t33-10); stub-backed `testTheListDrawsTheStubsCategoriesInTheServersOrder` pins "server order, not alphabetical" |
| Unread/mention bold state updates live from socket events | `ChannelSidebarView`'s badge rules via `entry.showsUnreadEmphasis`; `handle(_:)` + coalesced `refreshCounters` | `testPostedAsksForARefreshAndTheRefreshMovesTheBadge`, `testChannelViewedByThisUserClearsTheCounterLocally`, `testAnotherUsersViewDoesNotClearMyCounter`, `testAReadFromAnotherClientClearsEveryRowItNames`, `testAnotherUsersMultipleViewDoesNotClearMyRows`, `testAMultipleViewOfUnknownChannelsIsIgnored`, `testMultipleChannelsViewedDecodesTheChannelTimesMap`, `testAFailedCounterRefreshKeepsTheLastNumbersAndLabelsThemStale` | `testUnreadAndMentionBoldStateMovesLiveAfterAnotherUsersPost` — a second account posts over the real socket; the row goes bold, then a mention badge appears, and the badge equals the server's `mention_count` (`t33-04`, `t33-05`); `testAReadFromAnotherClientOfTheSameUserClearsTheRow` — the same user's **view call** clears the row it just badged, through `multiple_channels_viewed` (`t33-13`; fails on `d9d55c5`, see `docs/t33r2-build-note.md` §5) |
| Muted channels show no bold/count; totals exclude them | `ChannelSidebarEntry` badge rules + `totals` | `testAMutedChannelShowsNoBoldAndNoBadgeForUnreadMessages`, `testAMutedChannelStillSurfacesAnExplicitMention`, `testTotalsExcludeAMutedChannelsMessagesAndMentionsLikeDesktop` | `testAMutedChannelShowsNoUnreadStateAndLeavesTheTotals` — mutes through the API, another user posts, the server reports 1 unread, the row says "Muted" and no "Unread", the footer stays silent; then a mention **badges the row** but still leaves the footer silent (desktop rule, T33-AV F2), while the same traffic in an unmuted channel does move it (`t33-06`, `t33-07`, `t33-08`); stub-backed `testTheListDrawsTheStubsCategoriesInTheServersOrder` pins the same rule from a fixed fixture |
| Quick switcher fuzzy-matches channels and DMs, navigates | `ChannelListViewModel.searchResults` | `testSearchRanksExactThenPrefixThenWordStartThenSubstringThenSubsequence`, `testSearchAcceptsAChannelHashAndADirectMessageHandle` | `testTheQuickSwitcherFuzzyFindsAChannelAndOpensIt` — types `pffd`, taps the only result, asserts the pane title is the server's channel name **and that the sheet is gone** (`t33-02`, `t33-03`); stub-backed `testTheQuickSwitcherFindsADirectMessageByTheOtherPersonsName` — a DM found by the other person's username, then tapped: the switcher closes and the DM's own pane opens (see §11) |
| Reachable behind the dual-render flag, rendering **real** server data | `NativePanePlaceholders` / `SurfaceModeResolver` | `ChannelListViewModel` construction is gated in the pane (the stub suite asserts both ways) | `testTheSidebarRendersTheServersChannelsAndCategories` — every channel the API returns is on screen, labelled with the server's `display_name` (`t33-01`); stub-backed `testTheFlagDecidesWhetherTheNativeListIsMounted` asserts flag **off** exposes no `channelSidebar.*` identifier at all, and `testAFailedChannelReadShowsTheErrorAndARetry` asserts the error state |

Screenshots are in `docs/t33-shots/` (`t33-01` … `t33-09`), all taken from the running app against
`http://127.0.0.1:8065`, none from a fixture.

## 7. Identifiers (the contract T33-AV and T34 will use)

| Identifier | Element |
|---|---|
| `nativeSidebar` | T30's pane anchor row (unchanged) |
| `nativeTeamSidebar` | T32's team region (unchanged) |
| `channelSidebar.category.<type>` | a category header (`channels`, `direct_messages`, `favorites`, or the custom category's id) — a button, taps collapse/expand |
| `channelSidebar.channel.<channel id>` | a channel row; `label` = the server's `display_name`, `value` = "Selected, Muted, 2 mentions, Unread" style sentence |
| `channelSidebar.quickSwitcher` | the ⌘K button in the pane |
| `channelSidebar.quickSwitcher.field` | the switcher's search field |
| `channelSidebar.quickSwitcher.result.<channel id>` | a result row |
| `channelSidebar.totals` | the aggregate footer; `label` is "All caught up" or "2 mentions, 3 unread messages" |

## 8. Evidence runs

See §9 for the final commands and their verdicts.

## 9. Commands

```sh
# fixture (idempotent; local throwaway server only)
python3 scripts/t33_channel_seed.py --url http://127.0.0.1:8065

# unit suite, Mac Catalyst (the DoD's runner)
python3 scripts/qa-test.py --platform mac --label t33-units

# the nine T33 UI tests (4 stub-backed + 5 live), iPad Pro 11-inch (M5), iOS 26.0 simulator
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password in scripts/perf_seed.py> \
python3 scripts/qa-test.py --platform ios --sim DC3E9FB7-E4A0-4B24-8DBB-7960A059EC7A \
  --only-testing MattermostUITests/T33ChannelSidebarUITests \
  --only-testing MattermostUITests/T33ChannelSidebarStubTests

# whole UI suite (regression: T30/T31/T32 untouched)
TEST_RUNNER_MM_AUTH_SERVER=… python3 scripts/qa-test.py --platform ios --sim <same> \
  --only-testing MattermostUITests --label t33-uisuite
```

UI tests cannot run on **Mac Catalyst** on this host (the UI-test target's `MACOSX_DEPLOYMENT_TARGET`
is newer than macOS 26.3.1 — pre-existing, recorded in the T32 note §13). The iOS simulator is the
supported destination; the unit suite runs on Catalyst as the DoD asks.

## 10. Limits that stay (so T33-AV does not have to find them the hard way)

- **No drag-and-drop.** A reorder is the context menu's **Move up/Move down**, which writes the same
  `PUT categories` a drag writes. Drag gestures on a `List` inside the split column were not attempted.
- **No category create/rename/delete** and no "create channel" — those are S10's forms; this card reads
  whatever categories the server has.
- **Favourites are a write to the `favorites` category**, not a `favorite_channel` preference row. The
  legacy preference is only read as a fallback for a layout that predates server categories.
- **The quick switcher searches loaded channels only** (one team's list + its DMs). It does not search
  users or the server's message index — that is S09 (`find_channels` / `browse_channels`).
- **The team list is not refreshed on `team_*` events** (T32's limit, unchanged); the channel list is.
- **`teams_order` is read, not written** (T32); **`channel_order`** (the legacy flat order) is not read at
  all — the categories endpoint supersedes it.
- **Only the selected team's channels are loaded.** A second team's list is fetched on switch, not kept
  warm (one request per switch, `ifNeeded` prevents a refetch of the same team).
- **Approximate counting** (`channel_approximate_view_time`) is not implemented: counts come from the
  server's exact numbers.
- **No offline cache for the list** beyond what T29 stores: the sidebar is fetched on activation and
  refreshed from the socket; it does not read a stale list from SQLite while the network is down (it
  shows its error state with a retry).
- The **aggregate footer** is this shell's own read-out (the desktop/web sidebar has no footer); its
  rule is documented in §4.2 and asserted in
  `testTotalsExcludeAMutedChannelsMessagesAndMentionsLikeDesktop`.

## 11. The dead touch zone found while making the stub suite green (fixed here)

The stub suite's first runs failed on `testTheQuickSwitcherFindsADirectMessageByTheOtherPersonsName`,
and the failure was not the test's fault. `XCUIElement.tap()` taps an element's **centre**, and on
these rows the centre is dead:

- A `Button` with `.buttonStyle(.plain)` hit-tests its **label's content shape**, not the row its
  layout frame fills. Every row here is `Image + Text … Spacer() + badge`, so the half of the row
  after the `Spacer` — which is what VoiceOver and XCUITest both report as part of the row, and what
  a person naturally taps when the name is short — swallowed the tap and did nothing.
- Evidence: with the defect, a centre tap left the switcher open and — confirmed by probe logging —
  the button's action body **never ran**; the same row tapped at `dx: 0.15` (over the glyph) worked.
  The `sheet` therefore looked "sticky", which is how it was first mis-diagnosed.
- Fix: `.contentShape(Rectangle())` **inside the label** (not on the `Button`: applied there it does
  not widen the hit shape) for `ChannelSidebarRow`, `CategoryHeader` and the switcher's result rows.
  Same tap point now activates the row, so a person tapping the right half of any of these rows gets
  the row instead of nothing.
- Two test consequences, both fixed: the live switcher test only asserted the pane title, which is in
  the accessibility tree **behind** a presented sheet, so it could pass with the switcher still
  covering the screen; it now also asserts the sheet closed. The stub DM test now asserts the full
  gesture — found by username, chosen, sheet gone, the DM's own pane open.

Also corrected in this pass: the earlier note in the stub test claimed "the stub DM has an empty
`team_id`, so the route funnel refuses it". That was wrong — probe logging showed
`outcome=opened(... channelID: stubchandm00000000000000004 ...)` for that very channel. DM routing
never was the problem; the tap never fired.

Two facts for T33-AV, recorded rather than papered over:

- The channel pane's header shows the location's `channelName`, so a DM opened from the sidebar or
  the switcher reads `id__<a>__<b>` until the header learns to render `directLabels` — that is T34's
  surface, not T33's, and it is why the stub DM test asserts that raw name (it is what the shell
  draws today).
- The rail's rows (T32) use the same `Button` + `.plain` + `Spacer` pattern; they were **not** touched
  by this card. Their taps are only exercised at the row's leading edge by T32's tests, so the same
  dead zone may exist there and is worth a look under T32's card.

## 12. T33-R — the repairs from T33-AV

Validator: T33-AV (card `t_21b7e8d6`, report `T33-AV-verdict.md`). Repair card `t_eb428329`; the
detailed record (measured payloads, every finding, the runs) is `docs/t33r-build-note.md`. In one line
each:

| Finding | Repair |
|---|---|
| **F1** (HIGH) the categories write's answer did not decode, so a reorder/favourite was applied on the server and rolled back in the UI | the write now decodes **`[MMSidebarCategory]`** (the endpoint's real answer shape — measured: the array body is what it accepts and what it returns) and rebases the groups on it; `order` is kept from the drawn layout and only extended by a category the answer introduced. `setCollapsed` no longer `try?`-discards the write: it applies the server's answer and reports a failure. Regression: on-screen row + "no `channelSidebar.actionError`" added to the live reorder test, plus unit tests on the decode, the rebase and the collapse |
| **F2** (MEDIUM) a muted channel's mentions reached the footer aggregate | `totals` skips a muted channel entirely (desktop's `getTeamsUnreadStatuses`); `docs/parity.md` records that the T32 rail badges the server's `teams/unread` — a separate read-out, not the footer's source |
| **F3** (MEDIUM) an external layout change never reached the open list | `sidebar_category_updated` is now a modelled event, and its payload rebases the open list (no request, no relaunch). Live test: an external `PUT` while the app runs, asserting the rows move and the app did not relaunch |
| **F4** (LOW) four socket events the docs claimed were not modelled | `channel_created`, `channel_deleted`, `channel_member_updated` and `post_unread` are typed, scoped and acted on (reload / counter refresh / membership row / exact counters) — measured payloads in `docs/t33r-build-note.md` §2 |
| **F5** (LOW) a partial counter refresh zeroed every badge and claimed freshness | a failed `/users/me/channel_members` is reported (`ChannelSidebarRefresh.membersFailed`), the last numbers stay, and `countsAreStale` is set; an empty members answer for a channel-bearing team is treated the same way |
| **F6** (LOW) the shipped reorder test's cleanup was a no-op | `restoreChannelsOrder` sends the **bare array** and asserts 200 |
| **F7** (LOW) the debounce was documented as 300 ms | the docs now say **1500 ms** (the code and the rail's own `unreadRefreshDelay`); the default is deliberate |
