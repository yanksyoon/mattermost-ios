# T36 — native thread pane and Threads list (S13)

Card: `t_a138bba0` (implementation), validated separately by `T36-AV`.
Upstream pin: `mattermost/mattermost-mobile` @ `v2.45.0`
(`162f2560d0e1df073220f7701d5a67cc17c8abeb`), Apache-2.0. The webapp was observed in the running
client only (AGPL-3.0, never copied). Attribution: `docs/THIRD_PARTY_NOTICES.md` §13.

## 1. What this replaces (parity)

`docs/component-map.md` §S13 (`thread_pane`, `thread` screen, `global_threads`) and the reply line
`thread_overview` under a root post. `docs/parity.md`'s T36 row is the authority for what is covered
and what stays out; this note records how it was built and what the server actually answered.

| Surface | Files | Reached by |
|---|---|---|
| Thread pane (root + chain, load earlier, follow bell, reply composer) | `UI/Native/Thread/ThreadView.swift`, `ThreadViewModel.swift`, `ThreadService.swift`, `ThreadAPI.swift`, `ThreadCoordinator.swift` | `post.<rootID>.replyCount` in the channel timeline, or a row of the Threads list |
| Followed-threads list (All / Unreads, paged) | `UI/Native/Thread/GlobalThreadsView.swift`, `GlobalThreadsViewModel.swift`, `GlobalThreadsModels.swift` | the channel header's `nativeChannelThreadsButton` |
| Reply line under a root (participants + count) | `UI/Native/Channel/PostRowView.swift`, `PostRowModel.participants` | the channel timeline |
| Wire types + socket events | `Core/MM/MMThreadTypes.swift`, `Core/MM/SocketEvent.swift` (`thread_updated`, `thread_follow_changed`, `thread_read_changed`), `Core/MM/MMErrorCopy.swift` | every model above |

Gating: the pane and the list are the `shell` surface, so `-surfaceMode shell=native` is the only flag
they need. The thread's **reply box** is T35's `composer` surface (`-surfaceMode composer=native`):
with the composer on `web` the pane draws a placeholder instead of opening a second draft/send path —
two write surfaces for one draft key is exactly the corruption T36-AV should look for.

## 2. The server contract, measured (no app involved)

`scripts/t36_thread_probe.py` (18 facts, all PASS against Mattermost 9.11.19 at `127.0.0.1:8065`,
output below is the run committed with this card). Every fact below is also pinned by a unit test, so
a later server that changes one of them fails a test rather than silently degrading the pane.

```
  [PASS] the session works — /users/me -> 200
  [PASS] thread list answers — -> 200
  [PASS] thread list carries its totals inline — total=14
  [PASS] a thread object has no is_following field — 14 threads
  [PASS] a thread carries its own reply_count and last_reply_at
  [PASS] a thread carries its root post
  [PASS] thread id == root post id — k6rmrfxhp7fbf8qatupf4sf4tr
  [PASS] thread reply_count is the authority (may differ from post.reply_count) — thread=1 post=0
  [PASS] GET /posts/{id}/thread answers — -> 200
  [PASS] the thread endpoint returns the root inside order
  [PASS] the thread endpoint returns the root inside posts
  [PASS] PUT …/following follows — -> 200
  [PASS] a followed thread is readable — -> 200
  [PASS] PUT …/read/{ts} answers the thread — -> 200
  [PASS] the read answer carries unread_replies — unread_replies=0
  [PASS] an unfollowed thread answers 404 (that IS 'not following') — -> 404
  [PASS] ?channel_id= is accepted but ignored — scoped total=14 vs 14
  [PASS] GET /channels/{id}/threads does not exist — -> 404
```

Four consequences the code is built around (each is also in `docs/THIRD_PARTY_NOTICES.md` §13):

1. **`…/threads/mention_counts` (the path the card names) is 404.** The counters come from
   `?totalsOnly=true` (`total_unread_threads`, `total_unread_mentions`), which the list uses; the
   dead path is pinned so nobody "restores" it.
2. **No `is_following` field.** Following is list membership; `GET …/threads/{id}` is 200 when
   followed and **404** once not. That is the only honest oracle, and the live suite uses it.
3. **A deleted reply leaves the thread.** `/posts/{id}/thread` omits it even with
   `includeDeleted=true` (ignored), so a tombstone can only exist if the reader already had the
   reply — the socket `post_deleted` path. `ThreadDerivation.chain` keeps such a reply; a test pins it.
4. **`reply_count` disagrees between the thread object and its root post** (measured 2 vs 0), so the
   drawn count is `max(thread.reply_count, root.reply_count, replies loaded)`.

## 3. How it is built (and why in this shape)

Pure logic first, then one observable model per thing on screen, then a coordinator — the same
decomposition T34/T35 shipped, so the pane's rules are unit-testable without a server or a view:

- `ThreadDerivation` (in `ThreadModels.swift`): the chain (root once, first; replies oldest-first
  with an id tiebreak; a foreign `root_id` dropped; a tombstoned reply kept), the reply-count rule
  above, the participant stack (server participants first, then loaded reply authors, capped at
  `participantLimit`), the activity key `max(last_reply_at, post.create_at)` that a followed list is
  ordered by, and the unread badge copy (mentions win).
- `GlobalThreadsDerivation` (in `GlobalThreadsModels.swift`): the row's one-line preview
  (markdown stripped, 140 chars), "You" for my own root, the tab counter copy, and the paging cursor
  (`before` = the last id the server sent).
- `ThreadViewModel`: one thread's chain, its `fromPost`/`fromCreateAt` cursor, follow state
  (`unknown`/`on`/`off`, written optimistically and reverted when the server refuses), read marking
  that takes the server's returned counters, socket patch in place, and the composer's sink so a
  reply is optimistic in this pane and replaced by the server's post.
- `GlobalThreadsViewModel`: the All/Unreads tabs (the same endpoint with `unread=true`), paging, a
  `thread_updated` that inserts a thread the page does not hold, an unfollow that removes a row, a
  `thread_read_changed` that moves/drops the row.
- `ThreadCoordinator`: one model per open root (LRU 4), one list per team, one reply composer per
  thread, and the **only** object that sees both a thread and the channel model drawing its root —
  that is why a reply updates the root's reply line without the channel pane owning thread state.
- Channel side: `ChannelViewModel.recordReply`/`applyThread`/`applyReplyActivity`. A reply is still
  **not** a channel row (T34-AV-F1's rule is unchanged: `isTimelineRow`); it patches its root's count
  instead of being dropped, and a replayed `posted` cannot inflate the count because only a reply
  newer than `last_reply_at` counts.

## 4. Tests

### 4.1 Unit (Catalyst) — green

```
$ python3 scripts/qa-test.py --platform mac --only-testing MattermostTests
run        : mac-20261025-222455
outcome    : finished (xcodebuild rc=0, 61s)
tests      : 1085 run, 4 skipped, 0 failed
RESULT: PASS
```

`** TEST SUCCEEDED **` in `build/logs/mac-20261025-222455.log` (the runner's own verdict;
`build/logs/t36-units-full2.log` is the wrapper log). The 4 skips are the pre-existing ones
(CertTrust, the opt-in MentionPoller, 2× self-signed) — none is T36. T36 adds **75** tests:

- `MattermostTests/T36ThreadModelsTests.swift`, `T36ThreadViewModelTests.swift`,
  `T36GlobalThreadsViewModelTests.swift`, `T36ChannelReplyLineTests.swift`: decode/derive/format plus
  the model's page/socket/follow/read rules against a fake service and a fake socket — no server, no
  view.
- The T34/T35 tests that asserted "a reply's socket echo is *ignored*" were updated to the new truth
  (`patched`, no new row, root count 1) rather than deleted, and `T34ChannelPageRequestTests` now
  asserts the channel page asks for `collapsedThreadsExtended=true` (the reply line's avatar stack
  needs the extended form).

### 4.2 Live UI (`MattermostUITests/T36-ThreadsUITests`, real server) — see §6 for the state of this

Fixture: `scripts/t36_thread_seed.py` — channel `t36-threads` in team `perf`, a second author
`t36reply` (so a participant stack has two people and an unread reply can exist), the main chain and
65 paged threads. The main chain is created **last** on purpose, so it sits at the top of the
channel's newest-first page instead of behind 65 roots.

## 5. Limits (also in `docs/parity.md`)

- A thread is the newest 60 replies with "load earlier" — there is no jump-to-unread **inside** a
  long chain; the pane opens at the newest reply.
- No thread options menu: the model implements mark-unread, the UI draws the bell only (no "open in
  channel" entry).
- A `.threads` route that names a channel but no post renders the **global** list, because the server
  has no channel-scoped thread list (measured above) and upstream's `threads_button` opens the global
  one too.
- Following writes through, but the bell is `disabled` while the follow state is unknown (a failed
  read leaves it unknown rather than guessing).
- A reply sent from the **channel** composer only moves the root's count (it is not a channel row);
  only the thread's own composer shows an optimistic reply.
- The pane and the list do not use the T29 store: no threads offline.

## 6. FINDINGS FOR T36-AV — the live suite's first full run

Command (real Mattermost 9.11.19 at `127.0.0.1:8065`, throwaway credentials):

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
python3 scripts/qa-test.py --platform ios --sim 81A7F251-8B31-4945-8783-5A264C14B8D5 \
  --only-testing MattermostUITests/T36ThreadsUITests
```

Result (`build/logs/ios-20261025-223746.log`, wrapper `build/logs/t36-live3.log`):

```
Executed 4 tests, with 7 failures (0 unexpected) in 194.747 seconds
RESULT: FAIL
```

Per test:

| Test | Verdict |
|---|---|
| `testReplyingUpdatesTheRootsReplyCountAndTheThreadTakesSocketReplies` | **PASS (27.5 s)** — reply sent, server minted it under the root, the open thread drew it, a reply from a *second client* arrived over the socket, Back returned to the channel and the root's reply line carried the server's count. The card's second acceptance criterion is measured. |
| `testTheThreadDrawsTheWholeChainInOrderIncludingTheCollapsedAndDeletedReply` | FAIL — 2 assertions, see F1 and F2 |
| `testFollowPersistsAndTheFollowedThreadsListPages` | FAIL — the expected row was not drawn, see F3 |
| `testTheUnreadThreadStateIsTheServers` | FAIL — the server's counter was 0, see F4 |

No screenshot artifact was exported from this run for `docs/`: the screen *is* reachable and renders
real server data (the run's own failure dumps show the pane, the reply line and the Threads list with
the server's rows and counts), but a run that is red must not be the one whose screenshots are
presented as proof. T36-AV should export `docs/t36-shots/` from the first green run.

### F1 — (test defect, fixed here, still unverified live) the tombstone is drawn under a different identifier

The test asserted `thread.post.<id>.deleted`; `PostRowView`'s tombstone marker is
`post.<id>.deleted` (the thread row wraps the same view and only re-identifies the row itself,
`ThreadView.swift` §"A reply in a thread … `.accessibilityIdentifier("thread.post.\(row.id)")`").
Fixed in this commit; the pane's tombstone path has still **not** been observed live — T36-AV should
re-run that test. The product code does keep the row (`ThreadViewModel` `.postDeleted` →
`applyTombstone`, `replyCount - 1`), so the expectation is that the fixed assertion passes.

### F2 — (product, medium) replies with equal `create_at` are drawn in id order, not the server's order

```
T36-ThreadsUITests.swift:136: XCTAssertGreaterThan failed: ("334.66") is not greater than ("407.66")
 — reply 4sdwnodax… must be drawn below e3us5q7c…
 frames were [root 256.7, f1 407.7, f2 334.7, f3 501.7]
```

The three seeded replies are created by three back-to-back HTTP calls, so two of them can share a
millisecond. `ThreadDerivation.chain` sorts by `create_at` **then id** (deterministic tiebreak), but
the server's `order` array already carries the authoritative sequence, and with a tie the id tiebreak
reverses two adjacent replies. The fix belongs in the derivation: keep the server's `order` when it
sends one and use create_at/id only for posts that arrive without it. Not yet changed, because the
same derivation is what the 75 unit tests pin — a change needs a test that reproduces the tie first.

### F3 — (unexplained, medium) the followed list did not draw a thread created seconds earlier

The app's list (from the run's own accessibility dump) drew rows down from `10:36 PM` — including
`globalThreads.row.wos7tcw3z3rgjptkkndcmu1wpo` ("T36 main thread — the root of the chain.", 3
replies) — but not the thread the test had just created (root as `t36reply`, reply as me), whose
`GET …/threads/{id}` answered **200** in `setUp` immediately before the app launched. The header
subtitle also read `"No threads yet"` while rows were drawn, i.e. `ThreadTotals` was empty for a page
that was not. Two candidate causes, both worth a probe:

- the list request was served from a cached page (the row set looks like the state *before* the
  fixture was created) — `ThreadAPI.userThreads` and `thread(postID:)` both pass `useETag: false`, so
  this would have to be `URLCache`, not the ETag path; and
- `GlobalThreadsViewModel.totals` is filled by a separate `totalsOnly` call whose answer is not
  applied to the same snapshot as the page.

T36-AV should reproduce with a thread whose id it prints, then read the list from the app and from
`curl` in the same second.

### F4 — (product/test, medium) a thread cannot be observed unread while its channel is open

Measured on this server, no app involved (`POST /channels/members/{uid}/view`):

```
before view: 1
view call: 200
after view: 0
```

The app opens the channel under test (it must, to reach the Threads button), and that view call — or
a view the channel pane repeats on new posts — clears the collapsed-thread counter for every thread
in the channel. The test's own oracle therefore read `unreadReplies: 0` even with a 350 ms gap
between my reply and the other author's:

```
T36-ThreadsUITests.swift:312: the fixture leaves one unread reply for me; the server says
 Optional(ThreadEntry(id: "3qzp3tb433yipe49b57uc7abwc", unreadReplies: 0, unreadMentions: 0,
 replyCount: 2, authorLabel: "")) (unread_mentions 0)
```

This is a real client question, not only a test question: if the channel pane re-views on every
`posted`, the thread badge can never be shown for a channel the reader has open. T36-AV should
measure whether the pane sends `view` on a socket `posted`, and whether upstream does the same; the
unread badge itself is otherwise unverified live (unit-tested only).

### What this round did not do

- No `docs/t36-shots/` export (see above), so the card's "screenshot artifact proving real server
  data" is **not** satisfied by this commit. The screenshot names are already attached by the suite
  (`t36-01`…`t36-13`); exporting them needs one green run.
- `docs/parity.md`'s T36 row says `native ✅ (T36) behind -surfaceMode shell=native` with the limits;
  it now also points here for the live-suite state.
