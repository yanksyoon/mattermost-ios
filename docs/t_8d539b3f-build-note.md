# t_8d539b3f — Direct messages: the 20 most recent in the list, the rest behind "Load more"

Owner requirement, as quoted on the card: **"only load recent 20 in view"**.

This note records what was built, the two mechanisms that keep it from lying (unread rows are never
hidden, and search is not limited to what is on screen), and the evidence — unit tests, a live UI
test that taps the real control on a seeded server, and three screenshots exported from that run.

---

## 1. What changed

| File | Change |
| --- | --- |
| `Mattermost/UI/Native/Sidebar/ChannelSidebarModels.swift` | `ChannelSidebarGroup` now carries **every** row of the group (`entries`, in draw order) *and* the page currently drawn (`visibleEntries`), plus `showsLoadMore`, `hiddenCount`, `loadMoreIdentifier`. `ChannelSidebarDerivation.groups(from:selectedChannelID:selectedChannelName:revealed:)` takes the revealed page sizes and computes the page. Page size is `directMessagesPageSize = 20`, and only `direct_message` is paged. |
| `Mattermost/UI/Native/Sidebar/ChannelSidebarService.swift` | `ChannelListViewModel` owns the revealed count per category (`revealedCount(categoryID:)`), `loadMore(categoryID:)` (adds one page, refuses when nothing is hidden), and passes `revealed` into the derivation. `searchResults(for:)` keeps reading `allEntries` — every row of every group, not the visible page. |
| `Mattermost/UI/Native/Sidebar/ChannelSidebarView.swift` | The group body iterates `group.visibleEntries`; when `group.showsLoadMore` it appends `DirectMessagesLoadMoreRow` — a **row in the group's body**, where the next conversation would be, not a toolbar control. |
| `Mattermost/MattermostApp.swift` | The `-dmPagingSnapshot <dir>` evidence probe (Release product, inert without the argument). See §5 for why its output is *not* the evidence shipped here. |
| `MattermostTests/T8dDirectMessagePagingTests.swift` | 11 unit tests (§3). |
| `MattermostUITests/T8dDirectMessagePagingUITests.swift` | 1 live UI test against a seeded local server (§4). |
| `scripts/t8d_dm_seed.py` | Seeds N direct-message channels for the fixture account and writes the env snippet the live test reads. |

## 2. The rules, and why each one exists

1. **The page is the head of the existing `recent` sort.** `entries` and `visibleEntries` are the same
   array, sliced — no second ordering, no client-side "recent" of its own. `ChannelSidebarGroup`
   still holds the full list, so nothing that reads *data* (header roll-up, footer totals, deep-link
   resolution, search) can see a truncated group.
2. **20 exactly, for `direct_message` only.** The owner's number is the page size; other categories
   still draw every row (a channel list with a "Load more" under Channels is not what was asked for).
3. **Unread is never hidden by the page.** A row below the page whose own `showsUnreadEmphasis` is
   true is promoted into the drawn page and appended **after** it, so: (a) an unread DM can never be
   invisible, and (b) the first 20 rows never move when something below them becomes unread. On the
   seeded run one row was promoted (`Buddy Profile`), so the drawn page was 21 rows + the control —
   visible in `t8d-01-page-and-load-more.png`.
4. **The control is a row and disappears when nothing is left.** `loadMore` refuses when
   `hiddenCount == 0`, and `showsLoadMore` is false then, so the row cannot be drawn over a complete
   list. Its accessibility **value** is `"N remaining"` — the count is not only a drawing detail, it
   is readable by the test (and by VoiceOver).
5. **Search bypasses the page.** The quick switcher filters `allEntries`, so typing a name searches
   every DM, not the 20 on screen. A unit test pins this: `dm30` (past the first page) is found by
   typing `ana`, and `person` matches 44 fixture DMs — including `dm40` and `dm44`, a page past what
   is drawn.
6. **Revealed state is session-only, per server + team.** `ChannelListViewModel` holds it; nothing is
   persisted, so a relaunch is back to 20 (pinned by a test that builds a second model), and a team
   switch does not inherit another team's pages.

## 3. Unit tests — 11, green

`MattermostTests/T8dDirectMessagePagingTests.swift` — 11 tests, all green:

| Test | What it pins |
| --- | --- |
| `testFortyFiveDirectMessagesDrawTheTwentyMostRecentAndALoadMoreSayingTwentyFiveRemaining` | 45 DMs → `entries` = all 45 (by id), `visibleEntries` = the first 20 of the **existing** recency sort, `hiddenCount == 25`, identifier `channelSidebar.loadMore.direct_messages`. Two activations → 40 → 45, `showsLoadMore == false`; a third (stale/double) tap is a no-op and the stored page stays 60. |
| `testTwentyFiveDirectMessagesNeedOneLoadMoreAndThenTheControlIsGone` | 25 DMs → 20 drawn, 5 hidden, one activation finishes it. |
| `testAnUnreadDirectMessageBeyondThePageIsDrawnWithoutPressingLoadMore` | an unread DM at recency position 30 is drawn with no tap, **appended** after the first 20 (order untouched), `hiddenCount == 24`, and the header's own dot/`Unread` value agree with it. |
| `testPromotionIsStableAcrossBadgeRefreshes` | two identical counter refreshes do not reshuffle the drawn list, and a revealed page keeps its promotions in place. |
| `testReadingAPromotedDirectMessageOnlyRemovesItFromTheTail` | a `channel_viewed` for the promoted DM drops it back below the cap; the first 20 never move. |
| `testFilteringSearchesEveryDirectMessageAndClearingItComesBackToThePage` | `ana` finds `dm30` (below the cap); `person` matches **44** rows including `dm40`/`dm44`; filtering does not page the sidebar, and a revealed page survives a filter round-trip. |
| `testAFreshModelStartsOnTheFirstPageEvenAfterAnotherSessionRevealedMore` | no persistence: a second model (a relaunch) starts at 20 and `revealedCount` is `nil`. |
| `testTheGroupRollUpAndTheTotalsAreComputedOverEveryDirectMessageNotThePage` | 22 drawn (20 + 2 unread beyond), yet header roll-up, mentions, `unreadChannels` and `totals` are byte-identical to a group that draws all 45. |
| `testOnlyTheDirectMessagesGroupIsPaged` | a 45-row `channels` group draws all 45 with no control (`revealed == .max`), while DMs draw 20. |
| `testTheLoadMoreRowIsItsOwnControlWithAStableIdentifierAndTheRemainingCountAsItsValue` | the row is a separate identifier from the header, value `"24 remaining"` / `"1 remaining"`, and a 12-DM group draws all 12 with no control. |
| `testTheDerivationPagesTheDirectMessagesGroupToTwentyOnItsOwn` | the page arithmetic on the derivation alone: default 20, `revealed: 40` → 40 drawn, and a below-page value (`revealed: 1`) cannot shorten the first page. |

```
$ python3 scripts/qa-test.py --platform mac --only-testing MattermostTests/T8dDirectMessagePagingTests --label t8d-units
tests      : 11 run, 0 skipped, 0 failed          ← build/logs/t8d-units.log
** TEST SUCCEEDED **
```

**Full suite:** `build/logs/t8d-units-full.log` — **2231 tests, 9 skipped, 1 failure**. The failure is
`T53MediaFootprintTests/testAStagedPayloadIsWrittenToDiskRatherThanHeldInMemory` (a media-staging
memory-footprint assertion: *staging 33554432 bytes grew the footprint by 76693696 bytes*). It also
fails **on its own**, with no sidebar test in the process and this card's code untouched —
`build/logs/t8d-t53-isolated.log`: *grew the footprint by 805701312 bytes*. It is a host-dependent
footprint measurement, not a regression from this card; every T33 sidebar test in the same run passed.

## 4. Live UI test — 1 test, green, real tap

`MattermostUITests/T8dDirectMessagePagingUITests` runs on the booted simulator against the local
Mattermost (Docker `mm-perf` + `mm-perf-db`, `http://127.0.0.1:8065`) with 45 seeded DMs, signs in
through the native login, and then:

- asserts the row is drawn with label `Load more` and a positive `N remaining`;
- asserts the **last drawn channel row ends above the control's top edge** (the row comes after the
  rows, read off frames on one screen);
- asserts the oldest seeded DM is **not** in the tree before any tap (the page really is hiding it);
- taps the control, re-finds it, and requires the remaining count to **fall** each time, breaking
  when the control disappears;
- asserts the oldest seeded DM is afterwards reachable by scrolling, and that the control is gone.

Measured on this host (`build/logs/t8d-ui-shots3.log`):

```
[t8d] drawn: label=Load more value=34 remaining
[t8d] tap 2 from "14 remaining" removed the control
[t8d] Load more taps=2 remaining: [34, 14]
tests      : 1 run, 0 skipped, 0 failed          (145 s)
** TEST SUCCEEDED **
```

34 hidden → one page loaded → 14 hidden → the last page loaded → the control removed. 55 DMs on the
fixture account: the 45 seeded ones plus DMs left by earlier cards' fixtures.

Reproduce:

```
docker start mm-perf-db mm-perf                     # if not already up
python3 scripts/t8d_dm_seed.py --count 45           # idempotent; writes the fixture + the env file
source build/logs/t8d-dm-fixture.env                # exports TEST_RUNNER_MM_DM_COUNT / _OLDEST
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
python3 scripts/qa-test.py --platform ios \
  --only-testing MattermostUITests/T8dDirectMessagePagingUITests --label t8d-ui
```

Without the fixture env the test **skips** with a message that says how to seed it — it never invents
a fixture.

Screenshots (exported from that run's `xcresult` with `scripts/t37_export_shots.py`):

| File | What it shows |
| --- | --- |
| `docs/t8d539b3f-shots/t8d-01-page-and-load-more.png` | the end of the Direct messages group: `T8d User 12 … 20`, the promoted unread `Buddy Profile`, then **`Load more   34 remaining`**, then the footer. |
| `docs/t8d539b3f-shots/t8d-02-after-one-load.png` | after one tap: rows continue to `T8d User 40`, `Buddy Profile`, **`Load more   14 remaining`**. |
| `docs/t8d539b3f-shots/t8d-03-all-loaded.png` | after the last tap: the list runs to `opsbot` with **no control** and the footer directly below. |

## 5. The Release probe, and why its output is not the evidence here

`-dmPagingSnapshot <dir>` (`MattermostApp.swift`) photographs the page and writes a note per step. It
was written first and run on the Release Catalyst build — and it exposed two things worth recording:

1. It activated the control **through the accessibility tree, with a fallback to the model call**, and
   on a large real list the drawn row had not been realised by the `LazyVStack` at the moment it
   looked, so the note said `activatedVia=model` and `a11y=objects=499 matches=0`. A note that admits
   the fallback is not dishonest, but a *screenshot* taken after a model call proves nothing about a
   tap. That is why the shipped evidence is the XCUITest above, where `control.tap()` is real.
2. It ran against whatever account was signed in — in this case a **production** server with 198 DMs.
   Its note files carried that host, 198 channel ids, and colleagues' names in the PNGs, so the whole
   directory was **not committed**. (It did confirm the mechanism at scale: 198 entries, `revealed=20`,
   `hidden=172`, and 26 drawn rows = 20 recent + 6 unread DMs promoted from beyond the page — the
   promotion rule, visible in the numbers.)

The probe stays in the app (it is inert without the argument and useful for future sidebar work) but
it is **not** this card's evidence, and it must not be pointed at a real account and committed.

## 6. Limits that stay

- The revealed page is **session-only** — a relaunch is back to 20, and there is no "show only 20
  again" control once a page has been revealed.
- Only `direct_message` is paged; Channels, Favourites and custom categories are untouched.
- Because unread rows are promoted, the drawn page can be **more than 20 rows** (21 on the seeded
  run). That is deliberate: an unread DM is never hidden by paging.
- The remaining count is `entries.count - visibleEntries.count`, i.e. derived from the group's own
  data. A socket-driven refresh that adds or removes a DM moves the count — it does not pin it.
- The quick-switcher result list is unaffected by the page (it reads `allEntries`), so a search can
  show rows the sidebar is not drawing. That is the intended behaviour, not a leak.
- The seeder leaves its fixture on the local server (45 DM channels + 45 `t8d_*` users) for re-runs;
  it is idempotent, so re-running it does not create duplicates.
