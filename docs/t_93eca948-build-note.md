# t_93eca948 — an unread channel draws its unread count

Build note for the card *"Sidebar: an unread channel shows the number of unread messages, not just
a dot"*. Measured on this machine against the local 9.11.19 fixture (`http://127.0.0.1:8065`, Docker
`mm-perf` + `mm-perf-db`), the Mac Catalyst unit host and the iPhone 16 Pro simulator
(`81A7F251-8B31-4945-8783-5A264C14B8D5`).

## 1. What changed, and why it is a divergence

Upstream draws **mentions** as a number and **unread-ness** as bold text plus a count-less dot:

* mobile, pin `162f2560`, `app/components/channel_item/channel_item.tsx:210-218` —
  `Badge value={mentionsCount} visible={mentionsCount > 0}`; the bold label at `:137-138` is the
  whole unread signal;
* webapp v12.0.1, `sidebar_channel_link.tsx:26,134-152` — `ChannelMentionBadge` for mentions, and
  `isUnread && unreadMentions === 0` is a separate state with no number (the dot).

The owner wants 40 new posts to read differently from 2, so the row now draws the unread **message**
count. That is a **deliberate divergence, not a parity fix**, recorded in three places so a later
parity sweep does not "fix" it back:

* `Mattermost/UI/Native/Sidebar/ChannelSidebarModels.swift` — `ChannelSidebarEntry.badge` and
  `ChannelSidebarBadge.unread` name the card and both upstream refs;
* `Mattermost/UI/Native/Sidebar/ChannelSidebarView.swift` — the row's badge view says the dot was the
  pre-card marker;
* `docs/parity/module-scan.tsv` rows `unread-is-a-delta-bold-row-and-dot` and
  `a-group-is-marked-when-any-row-is-an-unread-fact` now cite this card in `ours_ref`
  (`docs/PARITY.md` is the regenerated render).

## 2. Where the number comes from

`unread = max(0, channel.total_msg_count − member.msg_count)`, both fields already in the sidebar
payload. No new request per row, nothing synthesised from `last_viewed_at`, and no local counting of
websocket posts.

Live arithmetic from the passing run (`T93 ARITHMETIC`):

| channel | `total_msg_count` | `msg_count` | row drew |
|---|---|---|---|
| off-topic | 398 | 358 | `40` |
| perf-feed | 567 | 565 | `2` |

Re-read from the server *during* the run (`T93 SERVER-DURING-RUN`), the same two numbers, and the
app's own accessibility values read `Unread, 40 unread messages` / `Unread, 2 unread messages`.

## 3. A real bug this card exposed (fixed here)

`GET /users/me/channel_members` **paginates**, and without `page`/`per_page` the 9.11.19 fixture
answers **60 rows for an account with 429 memberships** — measured: neither `off-topic` nor
`perf-feed` was among them, so the sidebar drew no badge at all while the server said 40 and 2. The
counters live on those rows, so `ChannelSidebarAPI.myChannelMembers()` now walks every page
(`per_page=200`, bounded) and stops on the first short page. Covered by
`testTheMembershipReadWalksEveryPageBecauseTheCountsLiveThere` (three stubbed pages → 410 rows, pages
asked for by number). Without this the feature was correct in unit tests and invisible in the app.

## 4. The decisions the card asked for

1. **Count, not dot.** `ChannelSidebarBadge.dot` and `isDot` are gone; zero unread draws **nothing**
   (no dot, no `0`).
2. **Mentions win, one badge per row.** A channel with both unread posts and mentions draws the
   **mention** count in the theme's red — never two badges. Two cases rather than a number plus a
   flag: `.mentions(count, urgent:)` and `.unread(count)` (accent blue). `urgent_mention_count > 0`
   makes the same number louder (a 1.5 pt ring) and never changes the digits.
3. **Muted suppresses the count**, and the bold label with it; an explicit mention on a muted channel
   still badges, which is what `mark_unread = "mention"` means.
4. **Clears in the same tick.** Opening a channel posts `channel_viewed` (t_e9550303); the row's own
   `applyRead` removes the number immediately, and another device's `channel_viewed` does the same
   without a reload. Both unit-tested; the first is live-tested
   (`testOpeningTheChannelClearsItsCountWithoutARelaunch`, 29.2 s, passed).
5. **Two ceilings.** Mentions cap at `99+` (upstream `Badge` behaviour); unread caps at `999+`,
   chosen here — exact up to 999, four characters from 1000 on.
6. **Cost unchanged.** 50 redraws cost zero service calls (`testFiftyRedrawsCostZeroRequests`); the
   number is a subtraction over data already loaded.
7. **No dot left behind.** Row and category header share one `ChannelSidebarBadgePill`, so the two
   indicators cannot drift; the group header rolls its rows' numbers up (collapsed groups count their
   hidden rows); the app-icon badge (`SessionStore.badgeNumber`) carries the unread **message** total
   instead of collapsing unread to `1`, and still lets a mention beat it.

## 5. Evidence

* **Unit**: `MattermostTests/T93eca948UnreadCountTests.swift` — 17 cases (40, 2, 1000, zero, mentions
  vs unread, urgent, muted, read-on-open, remote `channel_viewed`, multi-channel view, full reload,
  redraw cost, membership paging, render). Whole lane at this HEAD: **2637 run / 14 skipped / 0
  failed** (`build/logs/parity-scan-unit.log`).
* **Render** (Mac Catalyst, no fixture needed): `docs/t_93eca948-shots/unread-counts.png` — header
  `999+`, rows `40`, `2`, `999+`, mention `3` (red), urgent `1` (red, ringed), muted (nothing), read
  (nothing), and a collapsed `Design` header still counting its hidden rows (`12`).
* **Live** (simulator, fixture): `docs/t_93eca948-shots/live-two-counts.png` — Off-Topic **40** and
  Perf Feed **2** side by side in the running app, both rows bold, the Channels header rolling up
  **42**, beside a collapsed "T8G GROUP 1". Suite: `MattermostUITests/T93UnreadCountUITests.swift`,
  2 tests, both passed (29.2 s + 23.1 s).

## 6. Adversarial mutations (both reverted; `md5` of the file compared before and after)

* **A — badge reads `mention_count` only** (`badge` returns `.none` for every non-mention row):
  `testAnUnreadChannelWithFortyPostsDrawsTheNumberForty` **fails** —
  `("Optional(ChannelSidebarBadge.none)") is not equal to ("Optional(ChannelSidebarBadge.unread(40))")`,
  and `nil` instead of `"40"`. Log: `build/logs/t93-mutation-a.log`.
* **B — unread counted locally as a boolean** (`unreadCount: … > 0 ? 1 : 0` in the entry factory, i.e.
  the pre-card dot as a number): `testAFullReloadReDerivesTheNumberFromTheServerFields` **fails** —
  `Optional(1) is not equal to Optional(50)`. Log: `build/logs/t93-mutation-b.log`.
* Reverted file `md5 096fd6052c2f84ef1ab7be1cf94ecdfe` before and after both runs.

## 7. Parity gates

`python3 parity/generate.py --check` → rc 0; `python3 parity/check_scan.py` → rc 0
(`rows: 161 across 16 modules; 340 evidence refs checked / OK`).
