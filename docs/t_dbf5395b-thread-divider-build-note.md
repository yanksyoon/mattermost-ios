# t_dbf5395b — the thread pane's unread divider: drawn from a frozen read position, with an identifier a test can find

Status: fixed. Unit + live coverage; the parity row `thread /
unread-divider-from-thread-viewed-at` moves from **Partial** to **parity**.

## 1. What was unproven — and why "just add a test" did not work

The parity scan (t_0230e17e) recorded the value as wired but unproven: `ThreadViewModel` tracked
`lastViewedAt` (`:137`, pre-change numbering) and a `thread_read_changed` frame moved it (`:626`,
same), and `rebuild()` already called `PostListDerivation.items(…, lastViewedAt:)`. What was missing
was a case and an identifier.

Trying that first is what exposed the real problem. `ThreadPaneContent` marks the thread read as soon
as it appears (`ThreadView.swift:128`), and the read endpoint answers with the thread whose
`last_viewed_at` is **now**. `apply(thread:)` adopted that number, `rebuild()` re-derived the list, and
nothing was newer than the read any more — the divider existed only for the frames between the load
and the read answer. Measured with `curl`-level probes (`probe_thread_divider.py`, 9.11.19 on
127.0.0.1:8065, team `perf` / channel `t36-threads`):

```
PUT /users/me/teams/{t}/threads/{id}/read/{marker}  -> 200
answer keys: delete_at, id, is_urgent, last_reply_at, last_viewed_at, participants, post,
             reply_count, unread_mentions, unread_replies
answer last_viewed_at == marker, unread_replies 1
GET  /users/me/teams/{t}/threads/{id}               -> last_viewed_at == marker, unread_replies 3
PUT  …/read/{now}                                   -> last_viewed_at == now, unread_replies 0
```

So a divider drawn straight from the read answer is unobservable in the app and unassertable in a live
test. A live case written against the old wiring failed for exactly that reason (see §4).

## 2. Upstream's rule (pinned mobile v2.45.0 @162f2560)

- `app/database/models/server/thread.ts:43-59` — **two** fields: `last_viewed_at` (the server's read
  position) and `viewed_at` ("the timestamp showing when the user's last opened this thread (this is
  used for the new line message indicator)").
- `app/screens/thread/thread_post_list/thread_post_list.tsx:89` — the pane hands `thread?.viewedAt`
  to `PostList`, not `last_viewed_at`.
- `app/actions/websocket/threads.ts` `handleThreadReadChangedEvent` — `last_viewed_at` always; `viewed_at`
  only when `!isThreadVisible`, with the comment "Do not update viewing data if the user is currently
  in the same thread".
- `app/actions/remote/thread.ts` — `markThreadAsRead` updates `last_viewed_at` on mount;
  `markThreadAsUnread` sets `viewed_at: post.createAt - 1`.
- `app/utils/post_list/index.ts:258` — `if (lastViewedAt && …)`: a zero marker draws no line at all.

## 3. The repair

`Mattermost/UI/Native/Thread/ThreadViewModel.swift`

- `dividerViewedAt` (+ `hasTakenDividerPosition`) is the read position the **pane's** line is drawn
  from: taken once from the thread row's `last_viewed_at` when the row arrives with the load
  (`takeDividerPosition`, called from `loadThreadRow`). It is not moved by this pane's own read
  (`markRead` → `apply(thread:)`), by a `thread_read_changed` frame for this thread, by
  `thread_updated`, by a follow toggle or by a gap sweep. It **is** moved by the two reads that happen
  outside the pane: a whole-team `thread_read_changed` (empty `thread_id`) and "mark as unread"
  (`dividerViewedAt = post.createAt - 1`, upstream's own stamp).
- `rebuild()` feeds `dividerViewedAt ?? lastViewedAt` to the **same** `PostListDerivation.items` the
  channel timeline uses, so the placement rule cannot drift between the two lists.
- `lastViewedAt` keeps its meaning as the server's read position (it is what the counters are about
  and what an older answer may not move back); it is no longer what draws the line.
- `unreadDividerPostID` — a diagnostic that answers "which post is the line in front of", so a test
  does not re-implement the list walk.

`Mattermost/UI/Native/Channel/PostRowView.swift`, `Mattermost/UI/Native/Thread/ThreadView.swift`

- `NewMessagesDividerView` takes its accessibility identifier as a parameter (default
  `channelNewMessages`, unchanged for the channel timeline). The thread pane passes
  `threadNewMessages` — the same rule its rows already follow (`thread.post.<id>`, never `post.<id>`),
  so a live case cannot pass on the channel's line and the channel's cases cannot pick up the pane's.

## 4. Tests

`MattermostTests/T36ThreadViewModelTests.swift` (four cases, all through the real `PostListDerivation`):

- `testTheUnreadDividerSitsBeforeTheFirstUnseenReply` — `last_viewed_at: 150` with a root at 100 and
  replies at 200/300: the divider is an item between rows, below the root, immediately before `r1`.
- `testNoDividerWithoutAFollowedRowOrWhenEverythingIsRead` — a 404 thread row (not following) and a row
  read past every post both draw nothing; `nil` is unknown, not "everything is read".
- `testOpeningThePaneDoesNotEraseTheDividerItJustDrew` — after `markRead()` answers a thread with
  `last_viewed_at: 10_000`, the badge is cleared and the line is **still** before `r1`; a per-thread
  read frame leaves it there; a whole-team read at 20_000 removes it.
- `testMarkUnreadPutsTheDividerInFrontOfTheChosenReply` — the line lands before `r2`, and the write was
  really made (`markUnreadCalls`).

`MattermostUITests/T36-ThreadsUITests.swift`:

- `testTheUnreadDividerSitsBeforeTheFirstUnseenReply` — live, against 9.11.19. The fixture creates a
  root (second author) and a reply of mine, **writes** the read marker
  (`PUT …/threads/{id}/read/{ts}`, asserting the answer echoes it), then posts two unseen replies from
  the other account. The oracle is the server: `unread_replies == 2`, `last_viewed_at == marker`, and
  the first post with `create_at > last_viewed_at` in chronology. The test opens the thread from the
  followed list, waits for the server to report `unread_replies == 0` (the pane's mount read), and then
  asserts `threadNewMessages` exists, is labelled "New messages", sits **below** my read reply and
  **above** the first unseen reply, and that `channelNewMessages` is not on screen.

Mutation evidence (the point of the card): reverting only the derivation input to
`lastViewedAt` — i.e. the pre-fix behaviour — makes both the unit case and the live case fail:

```
MattermostTests/T36ThreadViewModelTests.swift:329: XCTAssertEqual failed: ("nil") is not equal to
  ("Optional("r1")") - the line must outlive the read the pane performed on mount
MattermostUITests/T36-ThreadsUITests.swift:678: XCTAssertTrue failed - a thread opened with unread
  replies must draw the divider, and keep it after the read it performs on mount
```

## 5. Runs

- `scripts/qa-test.py --only-testing MattermostTests/T36ThreadViewModelTests --label t_dbf5395b-unit`
  → 32 run, 0 skipped, 0 failed (`build/logs/t_dbf5395b-unit.log`).
- `… --only-testing MattermostUITests/T36ThreadsUITests/testTheUnreadDividerSitsBeforeTheFirstUnseenReply
  --label t_dbf5395b-live` → 1 run, 0 skipped, 0 failed, 129 s, attachment
  `t36-14-pane-divider` (`build/logs/t_dbf5395b-live.log`; the exported screenshot is
  `docs/t36-shots/t_dbf5395b-pane-divider.png` — root, my seen reply, the "New messages" line, then
  the two unseen replies).
- Mutation probe `--label t_dbf5395b-mutation` → 2 failed, the two messages above
  (`build/logs/t_dbf5395b-mutation.log`).
- Same unit class after the final wording of the derivation input (`--label t_dbf5395b-unit2`) → 32/0/0.
- Whole unit target for the parity log (`--only-testing MattermostTests --label parity-scan-unit`) →
  2235 run, 8 skipped (opt-in), **0 failed**, `xcodebuild rc=0`
  (`build/logs/parity-scan-unit.log`). `python3 parity/check_scan.py` → "311 evidence refs checked …
  OK: columns, vocabulary, refs and the HEAD run all agree". `parity/generate.py` regenerated
  `docs/PARITY.md`: **131 yes / 4 partial**; the two fatal `STALE-VERDICT` findings `--check` reports
  (`M:app/screens/create_or_edit_channel`, `X:web-fallback`) pre-exist this change (t_2fc694a9).

### The channel's identifier (regression check)

`NewMessagesDividerView()`'s default argument is `channelNewMessages`, so the channel timeline's call
site is unchanged by construction, and the pane's live case asserts that identifier is **not** on
screen while the pane is. Running T34's live channel-divider case
(`T34ChannelPostListUITests/testANewPostAppearsWithoutReloadAndTheUnreadLineFollowsLastViewedAt`) was
**not possible on this fixture**: it fails in `launchAndOpen` —

```
MattermostUITests/T34-ChannelPostListUITests.swift:657: XCTAssertTrue failed - the sidebar must list #t34-showcase
```

— twice (`build/logs/t_dbf5395b-channel-divider2.log`, `…-divider3.log`). The account is now in
**406** channels of team `perf` (measured with `/users/me/teams/{t}/channels`) while that suite's local
reveal budget is 5+5 swipes, tuned for the ~40 channels measured on 2026-10-27. The failure is at
launch, before any divider assertion, and the suite was not part of the parent scan's live set
(`parity-live` ran T36/T05/T8d), so it is a pre-existing fixture-scale limitation, not a regression
from this card. Carded as follow-up so the T34 live suite is usable again.
