# T0f — the channel header's subtitle is the member count

Behaviour reference: mattermost/mattermost-mobile @ v2.45.0
(`162f2560d0e1df073220f7701d5a67cc17c8abeb`):

- `app/screens/channel/header/header.tsx:255` — the subtitle
  `"{count, plural, one {# member} other {# members}}"`, and `View info` when there is no count;
- `app/screens/channel/header/index.ts:103` — the count is
  `channelInfo.pipe(combineLatestWith(dmUser), switchMap(([ci, dm]) => of$(dm ? undefined : ci?.memberCount)))`,
  i.e. **undefined for a direct message**, so a DM never shows a number even though the server has one.

Licence Apache-2.0; no upstream source copied (the plural is the same ICU rule this repo already
applies in `ChannelInfoHeader.membersText`).

## What the server answers (measured, not assumed)

`scripts/t0f_member_count_probe.py` against the 9.11.19 fixture (`127.0.0.1:8065`):

| call | result |
|---|---|
| `GET /channels/{id}` (a fresh public channel) | **no `member_count` key at all** — the channel object carries `total_msg_count` and nothing about members |
| `GET /channels/{id}/stats` right after create | `member_count: 1`, `guest_count: 0` |
| the same after `POST /channels/{id}/members {user_id: t43buddy}` | `member_count: 2` |
| `GET /channels/{id}/stats` for a `D` channel | `member_count: 2` — a DM *has* a count; upstream simply never reads it |

The first row is the one that decided the seam: the card said "already on `MMChannel`", and it is not.
`MMChannel` (T34) decodes `/channels/{id}` and has no count field, so the header has to ask
`/stats` — the same call the channel-info screen makes (`ChannelInfoServing.stats`).

## The implementation

- `Mattermost/UI/Native/Channel/ChannelService.swift` — `ChannelServing.memberCount(channelID:)`
  (`Int64?`), implemented by `SessionChannelService` as `APIClient.channelStats(channelID:).memberCount`
  (no ETag: people join and leave while the pane is open). The protocol default is `nil`, so a stub
  service keeps the fallback instead of inventing a number.
- `Mattermost/UI/Native/Channel/ChannelViewModel.swift` —
  - `memberCount: Int64?` (`nil` = unknown), published so the header re-renders;
  - `loadMemberCount(for:)`, called at the end of `loadChannelHeader()`: **never for a `D` channel**
    (upstream's `dm ? undefined : …`), under the load's generation guard, and a thrown error leaves
    `nil` (a refused request is *unknown*, not zero — the same rule `membership(channelID:)` follows);
  - `headerSubtitle(memberCount:)` — the rule in one place. `guard let count, count > 0` mirrors
    upstream's **truthiness** test `if (memberCount)`, so `0` falls back to `View info` too, and the
    plural is delegated to `ChannelInfoHeader.membersText(count:)` so the pane header and the
    channel-info sheet cannot disagree about "1 member";
  - `user_added` / `user_removed` moved out of the ignored-cases arm: a frame for **this** channel moves
    a *known* count by ±1, clamped at zero. An unknown count stays unknown (a delta cannot invent a
    total), and another channel's frame is ignored.
- `Mattermost/UI/Native/Channel/ChannelView.swift` (`ChannelPaneTitle`) — draws the subtitle from
  `model.memberCount` instead of the string literal. The **AX label is untouched**
  (`displayTitle`, identifier `nativeChannelTitle`); the subtitle rides as the control's
  `accessibilityValue`, because it is drawn inside `.accessibilityElement(children: .ignore)` and a
  count that only sighted readers can see is exactly the kind of claim this board cannot verify.

## Evidence

**Unit** — `MattermostTests/T0fChannelHeaderSubtitleTests.swift`, 9 cases:

| case | what it pins |
|---|---|
| `testAKnownCountIsTheServersNumberWithTheServerPlural` | 1 → "1 member", 2 → "2 members", 40 → "40 members", 1234 → "1234 members" |
| `testNoCountAndAZeroCountBothFallBackToViewInfo` | `nil`, `0` and `-1` → "View info" (upstream tests truthiness) |
| `testTheHeaderAndTheChannelInfoSheetAgreeAboutTheSameCount` | the two surfaces pluralise identically |
| `testAChannelLoadsItsCountIntoTheHeader` | one `/stats` call per load, value on the model, subtitle from it |
| `testAGroupMessageAlsoShowsItsCount` | a GM keeps its count (upstream only hides a DM's) |
| `testADirectMessageKeepsTheFallbackAndAsksNobody` | a DM makes **no** count request and shows the fallback |
| `testAFailedStatsCallLeavesTheFallbackRatherThanZero` | a refused request is unknown, not zero |
| `testJoinAndLeaveFramesMoveTheCountForThisChannelOnly` | +1/−1 for this channel, floor at 0, other channels ignored |
| `testAnUnknownCountIsNotInventedByAJoinFrame` | a delta on an unknown count leaves it unknown |

**Live** — `MattermostUITests/T05ChannelHeaderUITests` against the real 9.11.19 fixture, whole suite:
`7 run, 1 skipped, 0 failed` (`build/logs/t0f-live-t05b.log`). `testD` (bookmarks 200) needs
`TEST_RUNNER_MM_BOOKMARKS_SERVER`; run on its own with `scripts/t05_bookmarks_proxy.py` it passes too
(`build/logs/t0f-live-t05d.log`, `1 run, 0 skipped, 0 failed`). The two new cases:

- `testFTheSubtitleIsTheServersMemberCountNotAConstant` — a channel the test creates has exactly one
  member, and the AX dump reads
  `identifier: 'nativeChannelTitle', label: '0 T05 Header c6e90dca', value: 1 member`;
- `testGATwoMemberChannelSaysMembers` — a real second membership row (`POST /channels/{id}/members`
  for `t43buddy`) makes the server answer `member_count: 2`, and the dump reads
  `value: 2 members` while the label stays the display name.

Both cases assert the AX **label** equals the display name, so the contract every other suite waits on
(`nativeChannelTitle`) is proven unchanged in the same run. Both were re-run **at this card's commit**
in a worktree of it (`build/logs/t0f-live-at-head.log`, `2 run, 0 skipped, 0 failed`), where the dumps
read `value: 1 member` and `value: 2 members` again.

**Regression** — the whole unit target at this commit: `2294 run, 8 skipped, 0 failed` (`rc=0`),
including the 126-case channel slice (`build/logs/t0f-regression-unit.log`).

**Parity** — row `channel-header / member-count-subtitle` is now `native` / `parity` with the eight
citations above; `parity/check_scan.py` OK (159 rows, 323 evidence refs, HEAD run log agrees) and
`parity/generate.py --check` reports 0 drifted artifacts, 0 fatal findings. `docs/PARITY.md`
regenerated: 133 yes / 3 partial / 17 to be implemented.

## Limits, stated

- The count is read **once per load**. A change made by somebody else reaches the header through the
  `user_added` / `user_removed` frames; there is no periodic refetch, which matches upstream (it
  observes a locally-patched `channel_info` row, not a timer).
- Until `/stats` answers, the subtitle is `View info` — upstream's own first frame.
- A group message shows its count (upstream's `dmUser` is defined for `DM_CHANNEL` only).
- A **zero** count renders `View info`, not "0 members": that is upstream's `if (memberCount)`, and it
  is what the server itself answers for a channel whose last member has just left.

## Operational note

The shared checkout was not buildable while this card was in flight (another card's untracked
`ConvertGMToChannelView.swift` had a duplicate `body`). The T05 suite ran in a worktree of `de59f71`
plus this card's patch; the whole unit target and both parity gates ran in a worktree of this card's
commit (`~/.hermes/kanban/boards/mattermost-ios/workspaces/t_0f8e0eb2/wt2`), and the two new live cases
were re-run there too. The commit was staged with `git apply --cached` of this card's own hunks so the
other in-flight cards' uncommitted edits in `ChannelView.swift` / `ChannelViewModel.swift` were not
swept in.
