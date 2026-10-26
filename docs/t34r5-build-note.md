# T34-R5 — closing the T34-AV findings (a reply is a channel row, or it is not)

Card: `t_cf23dcd7` (repair of the validator's findings, not of the product). Validator whose findings it
closes: T34-AV (`t_1ca87edd`, verdict PASS-WITH-FINDINGS). Base: `38c3180` (`origin/main`, T34-R4). No
surface flip: `SurfaceDefaults.nativeApprovedSurfaces` is still `[.auth]` and `paneOwningSurfaces` still
`[]` — nothing in this card is a decision about which surface is native.

Three findings, one of them material:

| finding | what the validator measured | what this card does |
| --- | --- | --- |
| **F1** (material) | the same reply is drawn when it arrives in a page (288 of `perf-feed`'s 503 rows) and dropped when it arrives over the socket (`drawn_after_page_load=true`, `drawn_over_socket=false`) | decision **(a)**: the centre timeline holds **top-level posts only**, stated once (`ChannelViewModel.isTimelineRow`) and used by **both** paths; the page request also asks the server for its own thread-collapsed view (`collapsedThreads=true`) |
| **F2** (minor) | `post.<id>` has no accessibility label (the text is in `post.<id>.body.block<n>`), so `row.label.contains(…) \|\| …` was always false on its first half; `blockLabel` was dead code with a prefix that never matched | the assertion reads the body blocks through a corrected `bodyText(_:postID:)` helper; `blockLabel` is gone |
| **F3** (minor) | `docs/parity.md`'s T34 limits omit the body-image rule and don't state the reply rule | both are in the T34 row now, plus the reply-count limit the chosen rule implies |

## 1. Why decision (a), and how it was measured before any code was written

The card offered (a) filter replies out of the window, or (b) accept replies live and keep them inline.
**(a) is what a thread-collapsed Mattermost client shows** — the centre channel is roots; a reply lives in
the thread pane (S11/T36). (b) would have shipped 288 top-level rows that answer nothing, with no thread
affordance until T36, which is exactly the drawing the validator called a defect.

(a) has a cheap version and an expensive version, and the pinned server decides which. Probes (throwaway,
`scripts/`-style `urllib`, read-only, run against the live stack at `127.0.0.1:8065`, team `perf`,
channel `perf-feed` = 503 posts = 215 roots + 288 replies):

```
GET /channels/{id}/posts?per_page=60                        returned=60  roots=25  replies=35
GET /channels/{id}/posts?per_page=60&collapsed=true         returned=60  roots=25  replies=35
GET /channels/{id}/posts?per_page=60&collapsedThreads=true  returned=60  roots=60  replies=0
GET /channels/{id}/posts?per_page=60&skipFetchThreads=true  returned=60  roots=25  replies=35
```

So the server (9.11.19) has the filter, and `APIClient.posts(channelID:page:collapsedThreads:)` already
knew the parameter — `ChannelAPI.channelPosts` just never passed it. The full walk, with the cursor the
client uses:

```
plain walk             : 503 ids, 215 roots, pages [200, 200, 103]
collapsedThreads walk  : 215 ids, replies=0, pages [60,60,60,35] ; duplicates 0 ; == roots of plain walk
```

That is the whole of decision (a)'s expensive half removed: the page is 60 **rows**, so `hasMore` (page
length), the paging tests and the live paging probe keep meaning 60 posts — the window is not "60 raw,
27 roots". The client-side filter stays anyway, because the request is one hop away from a proxy that
strips an unknown query parameter, and because the socket path needs the same predicate regardless.

## 2. Implementation

`Mattermost/UI/Native/Channel/ChannelViewModel.swift`

* `static func isTimelineRow(_:channelID:)` / `timelineRows(_:channelID:)` — the membership rule in one
  place: `!id.isEmpty && rootId.isEmpty && channelId == thisChannel`. `load`/`loadEarlier` merge the
  page through `timelineRows`, and `accepts(post:)` is now a one-line call to it, so the socket and the
  page cannot disagree again.
* `private var pageCursor: String?` — the server's `before` cursor, set from the **page's** oldest id
  (`page.orderedPosts.last?.id`) on the first load and advanced per page in `loadEarlier`. It is kept
  apart from `oldestLoadedPostID` on purpose: the kept rows can start after the page's real end, and a
  cursor taken from them would step back inside the page just read.
* `loadEarlier` walks pages in a bounded loop (`maximumPageHops = 10`) while a page yields no new row.
  A page that is entirely replies is normal in a busy thread channel, and the previous code ended the
  window there (`hasMore = false`), which would have left the sentinel saying "This is the beginning of
  the channel" with posts still unread. A page that ends on the cursor itself is the server ignoring
  `before`: the cursor then advances to the oldest *new* id on that page, and a page with nothing new is
  no progress at all — stop, never spin (the pre-existing `testARepeatedPageStopsInsteadOfLooping` still
  pins that).

`Mattermost/UI/Native/Channel/ChannelAPI.swift` — `channelPosts(channelID:page:collapsedThreads: Bool = true)`
appends `collapsedThreads=true` (and nothing else: not `collapsedThreadsExtended`, whose thread metadata
is heavier and is T36's to need). `ChannelService.swift` passes `collapsedThreads: true` **explicitly**,
so a future default flip cannot silently put replies back into the list.

## 3. Tests

Unit (`MattermostTests/`):

| test | pins |
| --- | --- |
| `T34ChannelViewModelTests.testARepliesPageDrawsNoRowsAndTheSameReplyIsDroppedOverTheSocket` | the page half and the socket half give the same answer for the **same** post |
| `…testTheOlderCursorIsThePagesOldestIDEvenWhenThatPostIsAReply` | the cursor is the page's oldest id (`r`), not the oldest kept row (`a`) |
| `…testARepliesOnlyPageIsWalkedThroughInsteadOfEndingTheWindow` | two full pages of replies are consumed inside one `loadEarlier` and the row behind them is merged |
| `…testARepeatedPageStopsInsteadOfLooping` (existing) | a server that ignores `before` still stops |
| `T34ChannelPageRequestTests.testTheProductionServiceAsksTheServerForTheThreadCollapsedPage` | the **production** `SessionChannelService` sends `collapsedThreads=true` (through `FakeAPITransport`, so the URL is the assertion), on the newest page and on an older one |
| `T34FixtureTests.testPagingTheLongChannelThroughTheRealPagerReproducesTheCapturedSequence` | the pager over the re-captured fixture: `collapsedThreads: true`, 215 rows, pages `[100,100,15]`, exact id order, no duplicate at any boundary, cursor list `[nil, #100, #200]` |

The fixture was re-captured (`scripts/t34_capture_fixture.py` now sends `collapsedThreads=true` and
records it; the script fails if the capture still holds a reply). It is now 215 posts / `[100,100,15]`
instead of 503 / `[100×5, 3]` — the point of the repair: the old capture was a page shape the app never
received, so the pager test *proved* the defect instead of catching it. A leftover `t34 ui live post …`
from an earlier UI run was deleted from the throwaway channel before the capture, so the committed
fixture is the seeded set.

Live (`MattermostUITests/T34ChannelPostListUITests`, now **7** tests): the new
`testAThreadReplyIsNeverAChannelRowHoweverItArrives` is the validator's probe, hardened —
1. the app's page (`collapsedThreads=true`) does not contain the reply, while the *same* channel without
   the parameter does (so the negative assertion is about the request, not about a lost post);
2. the root is drawn and the reply is neither a row nor a body block;
3. a reply posted **while the pane is open** does not appear (45 s);
4. a top-level post posted right after **does** appear over the socket — without step 4, step 3 would also
   pass on a dead socket.

F2's assertion is repaired in the same file (`bodyText` reads `post.<id>.body.block<n>`; the dead
`blockLabel` with the never-matching `post.<id>.block` prefix is gone), and the suite's own server helper
now requests `collapsedThreads=true` too, so the test's oracle and the app's list answer the same question.

## 4. Documentation (F3)

`docs/parity.md`, T34 row: the component description now states the membership rule and the
`collapsedThreads=true` request; the limits state (i) the centre timeline holds top-level posts only,
including that a reply arriving over the socket does not refresh its root's `reply_count` until the pane
is reopened (a real limit of the chosen rule, and T36's to fix), and (ii) that an image in a post **body**
(`![alt](url)`) is drawn as alt text + link and never fetched — `MarkdownView` says so in code, the parity
row did not.

## 5. Runs

See §6 for the exact commands. Results are recorded here verbatim from `scripts/qa-test.py`:

| what | verdict |
| --- | --- |
| units, Mac Catalyst (`--only-testing MattermostTests`) | `t34r5-units-catalyst`: **Executed 905 tests, with 4 tests skipped and 0 failures** (33.1 s) |
| live UI suite `MattermostUITests/T34ChannelPostListUITests` (7 tests, iPad Pro 11-inch M5 `DC3E9FB7`, live `mm-perf` at `127.0.0.1:8065`) | `t34r5-ui` run 1: **6 of 7**, `t34r5-ui-run2` and `t34r5-ui-run3`: **7 of 7, 0 failed** |

### The one intermittent test, and why it is not this card's

Run 1 failed `testANewPostAppearsWithoutReloadAndTheUnreadLineFollowsLastViewedAt` (the F2 test) at
`XCTAssertTrue failed - a posted message must appear over the socket without a reload`. It is not a
regression of this card, and the next paragraph is the measurement, not a guess:

* the **same test fails on the base commit `38c3180`** (a detached worktree of it, same simulator, same
  server, label `t34r5-base-F2`) — `MattermostUITests/…:416 … a posted message must appear over the
  socket without a reload`. So it was already intermittent before this card's diff.
* with `MMLog` instrumentation on the pane path (`ChannelPaneCoordinator.handle` → model), a failing run
  shows the app's own socket log with **only** `socket open`, `sent authentication_challenge`, `sent
  ping` — no `posted` frame reaches the coordinator at all; a passing run logs exactly one
  `coordinator.handle … models=1` + one `posted … root=- mine=…` for the measured id. The loss is in
  socket delivery, upstream of the row rule this card changed (the rule is unit-pinned in
  `T34ChannelViewModelTests`, including the case where a `posted` frame *does* arrive).
* adding a 8 s or a 30 s delay before the test's post does not change the outcome, so it is not "the
  post is made before the socket is up".

Intermittency, counted rather than asserted: across this card's runs the F2 test failed 6 times — 5 in
this worktree (`t34r5-ui` run 1, `t34r5-ui-socket1`, `…-socket-sleep`, `…-socket-sleep30`,
`…-socketlog`) and once on the **base commit `38c3180`** (`t34r5-base-F2`, a detached worktree, same
simulator and server) — and passed 3 times (`t34r5-ui-diag`, `t34r5-ui-run2`, `t34r5-ui-run3`). The
last three are the two full-suite runs that back this card, both 7/7. Recorded here rather than papered
over: a socket that stops delivering frames without a reconnect is a `socket resync` concern
(T35/T38 — `SocketClient` backoff/heartbeat), not a T34 row-membership concern, and the T34 rule itself
is unit-pinned including the case where a `posted` frame *does* arrive. The instrumentation was removed
before the commit (`git diff` shows no `T34DIAG` line).

## 6. Repro

```
# unit target, Mac Catalyst (no server needed)
python3 scripts/qa-test.py --platform mac --only-testing MattermostTests --label t34r5-units-catalyst

# the live suite (needs the throwaway stack: docker start mm-perf-db && docker start mm-perf)
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<seeded probe account> \
python3 scripts/qa-test.py --platform ios --sim id=DC3E9FB7-E4A0-4B24-8DBB-7960A059EC7A \
  --only-testing MattermostUITests/T34ChannelPostListUITests --label t34r5-ui

# the fixtures (idempotent, writes MattermostTests/Fixtures/*.json)
python3 scripts/t34_capture_fixture.py --url http://127.0.0.1:8065
```

## 7. Honest limits that remain after this card

* **Live evidence is one simulator and one server.** The suite runs against the local throwaway 9.11.19
  stack; a server that ignores `collapsedThreads` (older, or behind a proxy that drops unknown query
  parameters) falls back to the client filter, which is unit-tested but has no live run behind it.
* **The reply count of a root is stale until reload.** With replies out of the window, a reply arriving
  over the socket patches nothing (it is not a row); T36's thread affordance is what will need
  `reply_count`, and it will have to refresh it from the socket or on demand.
* **`collapsedThreadsExtended` is deliberately not sent**, so the server does not attach thread
  participants/metadata to each root. T36 can add it when it draws threads.
* **A page of 60 rows is not 60 messages.** With 288 replies in `perf-feed`, one page now covers fewer
  *messages* than the pre-repair 60-post page did per thread-heavy stretch — that is the cost of the
  correct rule, not a regression in paging (the 215 roots are all reachable, measured).
