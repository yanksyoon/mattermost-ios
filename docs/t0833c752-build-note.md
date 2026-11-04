# t_0833c752 — the reply count belongs to a root, in the channel and only there

Owner report: *"inside the thread view every reply shows a number of replies. It should only appear in
the channel view, and only for a thread that actually has replies."*

## 1. What was measured, before anything was changed

**The server side of the report.** On the pinned local server (Mattermost 9.11.19, `mm-perf`),
`GET /api/v4/posts/{root}/thread?per_page=60` answers the thread's **total** on **every post of the
thread**, replies included (`scripts`-style probe, run 2026-11-05):

```
thread eike65p3uprf3fuu9dwdi9i47y thread.reply_count 3 root post.reply_count 0
  post eike65p3  root_id=          reply_count=3
  post r1ei5zhp  root_id=eike65p3  reply_count=3
  post sqqyxsr6  root_id=eike65p3  reply_count=3
  post ww4s5pmn  root_id=eike65p3  reply_count=3
```

The same shape is on the search endpoint — a search hit that is a reply answers `reply_count: 2` with
a non-empty `root_id`. So a client that draws "N replies" from `post.reply_count` on any row says that
**every reply has a thread**.

**Our two defects.** The symptom had two independent causes:

1. `PostListDerivation.row` copied `post.replyCount` verbatim (`PostListModels.swift`), so a reply row
   carried the thread's total — a model that says a reply has a thread of its own.
2. `PostRowView.replyLine` drew whenever `row.replyCount > 0`, with no check on the surface, so even a
   correct root drew the line inside the thread pane (a reply count under the thread's own root is
   wrong too: upstream puts the count in the thread screen's header).

Fixing only (2) would have hidden the symptom in the thread pane and left every other channel-context
list (search, mentions, saved, pinned — they all draw replies as rows) claiming the reply is a root.

## 2. Upstream parity, read from the pin

Reference `mattermost/mattermost-mobile` @ `162f2560d0e1df073220f7701d5a67cc17c8abeb` (v2.45.0):

* `app/components/post_list/post/index.ts` — the thread record is looked up **by the post's own id**:
  `thread: isCRTEnabled ? observeThreadById(database, post.id) : of$(undefined)`. A reply's id is not a
  thread id (threads are keyed by their root), so a reply never has one; only a root does.
* `app/components/post_list/post/post.tsx` — the overview footer is drawn only when
  `isCRTEnabled && thread && location !== Screens.THREAD && !(rootId && location === Screens.PERMALINK)`.
  The thread screen therefore draws **no** overview on any row, its own root included.
* `app/components/post_list/thread_overview/thread_overview.tsx` — `if (repliesCount === 0) return null;`
  (and it is the component that names the count).
* `app/screens/thread/thread_post_list/thread_post_list.tsx` — renders `[...posts, rootPost]` with
  `location={Screens.THREAD}`; the count lives in the screen's header summary, not on a row.

Ours already had the header equivalent (`threadPane.subtitle`, `ThreadView.swift` — "3 replies ·
#t36-threads") and the Follow sheet's precedent (`surface == .channel && row.post.rootId.isEmpty`,
`PostRowView.swift`), which is the rule the reply line never got.

## 3. The change

* `Mattermost/UI/Native/Channel/PostListModels.swift`
  * new `enum PostReplyLine`:
    * `count(for:)` — the root's own count, **0 for any reply** whatever the server said;
    * `showsLine(surface:post:count:)` — `surface == .channel && post.rootId.isEmpty && count > 0`.
  * `PostListDerivation.row` builds `replyCount` through `PostReplyLine.count` and clears
    `participants` for a reply (the avatar stack is the root's; it is only ever read by this line).
* `Mattermost/UI/Native/Channel/PostRowView.swift`
  * `var surface: PostOptionsSurface = .channel` — the same two-value vocabulary the options sheet
    gates Follow on, defaulted for the channel-context hosts (search/mentions/saved/pinned).
  * `replyLine` is gated by `PostReplyLine.showsLine(...)`; when the gate is closed the view builder
    emits **nothing** — no hidden element, no identifier.
* `Mattermost/UI/Native/Thread/ThreadView.swift`
  * the thread's rows are constructed with `surface: .thread`, so no row of the pane (root included)
    produces a `post.<id>.replyCount` element. The pane's header subtitle is unchanged and remains the
    only count inside the thread.

Nothing here is configuration-gated: no `#if DEBUG` or `#if PERF_PROBE` appears in any changed file.

## 4. Tests

### Unit pins (`MattermostTests/T36ChannelReplyLineTests`)

* `testAReplyRowCarriesNoThreadCountEvenWhenTheServerSendsOne` — `PostListDerivation.row` on a reply
  with the server's `reply_count = 3` yields `replyCount == 0` and no participants; the root keeps 3.
* `testTheLineIsDrawnOnlyForARootOnTheChannelSurface` — the five render cases as one pure rule
  (channel root 3 → drawn; thread root → not; thread reply → not; channel root 0 → not; a reply row in
  a channel-context list with a non-zero server count → not).

```
python3 scripts/qa-test.py --platform ios --sim "id=35A85DD5-A711-4EC3-9CEA-15F38EA647EB" \
  --only-testing MattermostTests/T36ChannelReplyLineTests --label t0833-units2
  -> 9 run, 0 skipped, 0 failed          (build/logs/t0833-units2.log)

python3 scripts/qa-test.py --platform ios --sim "id=35A85DD5-A711-4EC3-9CEA-15F38EA647EB" \
  --only-testing MattermostTests --label t0833-units-full
  -> 2199 run, 8 skipped, 0 failed       (build/logs/t0833-units-full.log)
```

### Live tests (real server, real app; identifiers only, never text scanning)

`MattermostUITests/T36ThreadsUITests` — new section *2c. The count belongs to a root in the channel*:

1. `testTheChannelRootCarriesExactlyOneTappableReplyLine` — a fresh root with three replies: exactly
   one element matching `post.<root>.replyCount`, it is hittable, its value is the server's `"3"`, and
   tapping it mounts `threadPane` + `threadPostList`.
2. `testTheThreadRootRowCarriesNoReplyLine` — open the thread from that line: `post.<root>.replyCount`
   does **not** exist, `thread.post.<root>` does, and `threadPane.subtitle` still names the replies.
3. `testNoReplyRowInTheThreadCarriesAReplyLine` — each of the three replies is a `thread.post.<id>`
   row and none of them has a `post.<id>.replyCount` element.
4. `testARootWithNoRepliesCarriesNoReplyLine` — a root with no replies draws no element at all.
5. `MattermostUITests/T39SearchUITests/testAReplyInTheResultsCarriesNoReplyLine` — the "reply that is a
   root of nothing" case, measured where a reply **is** a row of a channel-context list: the server's
   search answers the fixture reply with `root_id` set and `reply_count > 0` (asserted in the test),
   the result row `searchResult.<id>` is drawn, and `post.<id>.replyCount` does not exist.

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN=perfprobe TEST_RUNNER_MM_AUTH_PASSWORD=… \
python3 scripts/qa-test.py --platform ios --sim "id=35A85DD5-A711-4EC3-9CEA-15F38EA647EB" \
  --only-testing MattermostUITests/T36ThreadsUITests/testTheChannelRootCarriesExactlyOneTappableReplyLine \
  --only-testing MattermostUITests/T36ThreadsUITests/testTheThreadRootRowCarriesNoReplyLine \
  --only-testing MattermostUITests/T36ThreadsUITests/testNoReplyRowInTheThreadCarriesAReplyLine \
  --only-testing MattermostUITests/T36ThreadsUITests/testARootWithNoRepliesCarriesNoReplyLine \
  --label t0833-live
  -> 4 run, 0 skipped, 0 failed          (365 s, build/logs/t0833-live.log)

… --only-testing MattermostUITests/T39SearchUITests/testAReplyInTheResultsCarriesNoReplyLine \
  --label t0833-live-search
  -> 1 run, 0 skipped, 0 failed          (46 s, build/logs/t0833-live-search.log)
```

### Mutation check (did the tests bite?)

The pre-fix rule was reinstated in `PostReplyLine` — `count` returns `max(post.replyCount, 0)` for any
post and `showsLine` returns `count > 0` regardless of surface — and two of the tests were re-run:

```
… --only-testing MattermostUITests/T39SearchUITests/testAReplyInTheResultsCarriesNoReplyLine \
  --only-testing MattermostUITests/T36ThreadsUITests/testTheThreadRootRowCarriesNoReplyLine \
  --label t0833-mutation-prefix
  -> 2 run, 2 failed  (build/logs/t0833-mutation-prefix.log)
     T36-ThreadsUITests.swift:374: "the thread pane's root row must not repeat the reply count"
     T39SearchUITests.swift:162: "a reply has no thread of its own: no replyCount element may be drawn"
```

Both are red, then the rule was restored and both are green (above). A first, narrower mutation —
only the derivation reverted — did **not** red the search test: the view's own `root_id` gate still
refused the line. The two gates are deliberate (the model must not carry a reply's count, and the view
must not draw a thread's count on the thread surface); the mutation above removes both, which is the
pre-fix product.

## 5. Screenshots (real server, native panes)

Exported from the live run's own attachments into `docs/t0833-shots/`:

| file | what it shows |
|---|---|
| `t0833-01-channel-root-reply-line.png` | channel timeline: `t0833 line root` with **"3 replies ›"** and one participant avatar; the root with no replies (`t0833 lonely root`) has none |
| `t0833-02-thread-opened-from-the-line.png` | the thread that line opened: header **"3 replies · #t36-threads"**, four rows, **no reply count under any row** |
| `t0833-03-thread-root-without-a-reply-line.png` | thread pane, root row drawn, no `replyCount` element |
| `t0833-04-thread-replies-without-reply-lines.png` | thread pane, all three reply rows, no reply counts |
| `t0833-05-channel-root-without-replies.png` | channel timeline, a root with zero replies: nothing under it |
| `t0833-06-search-reply-without-a-reply-line.png` | search result for a reply (`reply_count: 2` on the wire): the row draws the message only, no count |

## 6. Release

```
xcodebuild build -project Mattermost.xcodeproj -scheme Mattermost -configuration Release \
  -destination "platform=iOS Simulator,id=35A85DD5-A711-4EC3-9CEA-15F38EA647EB" \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/mattermost-ios-release
  -> ** BUILD SUCCEEDED **   (product: …/Release-iphonesimulator/Mattermost.app)
```

The product also **runs**: installed on the same simulator it launches into the native shell against
the persisted session and draws a native channel timeline, which is the same view tree the screenshots
above show.

**What this host cannot produce, stated plainly.** A screenshot taken from a **Release-configuration
run of the UI suite** is not obtainable here, for one measured reason: the scheme's test action builds
`MattermostTests`, whose `@testable import Mattermost` needs `ENABLE_TESTABILITY`, and whose
`PerfProbeTests` needs the app's `PERF_PROBE` types. `-configuration Release ENABLE_TESTABILITY=YES`
therefore fails in `MattermostTests/PerfProbeTests.swift:21` (`cannot find 'PerfProbe' in scope`) before
any UI test can be built; without testability it fails earlier at `APIClientTests.swift:3`. A Release
product also ignores `-uiTestSeedServer`/`-uiTestForgetSession`/`-uiTestResetPersistedState` — they are
inside `#if DEBUG` in `MattermostApp` — so the suite has no way to sign a Release app in, and driving
it by `mattermost://` deep link from `simctl` stops at iOS's "Open in Mattermost?" confirmation, which
no tool on this host can tap (`osascript` keystrokes are not permitted; `idb` is not installed).

So the six screenshots are from the **Debug live run against the real server**, and the Release claim
rests on the build above plus the fact that every changed file is configuration-free (`PostReplyLine`
and the row's `surface` parameter compile and behave identically in both configurations). This is a
limit of the evidence, not of the fix, and it is recorded here rather than papered over.
