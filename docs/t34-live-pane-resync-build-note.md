# T34-R5b — the thread pane and the mentions feed join the gap sweep

Card `t_e0077228` (follow-up of `t_d2eace51`, the delivery watchdog, and `t_bb3d3d64`, the reconnect
resync). Written on `eab5a8a` — the tree `docs/t34-socket-stall-watchdog-build-note.md` was pushed on — and
**re-derived on `f0dc3d8`**, the `origin/main` this card is published on (the tree moved five commits while
the card waited; the rebase was textually clean except §7's numbers, which are the rebased runs).

That note's §5 named this card's hole and refused to guess at it: after a reconnect or a watchdog-confirmed
stall, **only the channel pane** repaired itself. A reader sitting in an open thread, or on the mentions feed,
was looking at a window nothing would refresh until they left the screen and came back — and their only
refetch, `reload()`, **blanks the list to a spinner and drops every older page they had paged in**. So the
panes could not simply be hung off `onSocketResync`; each one needed a **merge** first. That is what this
card writes.

## 1. What was built

| file | change |
| --- | --- |
| `Mattermost/UI/Native/Thread/ThreadViewModel.swift` | `resyncAfterGap() -> Int` — fetch the newest replies page, merge it over the replies the reader holds (never resurrecting a held tombstone), adopt the server root, re-read the follow/unread row (`refreshThreadRowAfterGap`), re-derive `replyCount` / `last_reply_at`; `phase` untouched. Diagnostics `resyncCount`, `lastResyncInsertedCount`. |
| `Mattermost/UI/Native/Thread/GlobalThreadsViewModel.swift` | `resyncAfterGap() -> Int` — fetch the list's first page for the current tab, **prepend** only threads newer than the newest held row, never replace a held row, take the counters only when the page carries totals; same two counters. |
| `Mattermost/UI/Native/Thread/ThreadCoordinator.swift` | `resync(serverID:) -> Int` — server-scoped sweep of every **loaded** thread model and every loaded threads list of that server, plus `resyncCount`, `hasLoadedThread(serverID:rootID:)`, `hasLoadedThreadList(serverID:)`. |
| `Mattermost/UI/Native/Activity/MentionsViewModel.swift` | `resyncAfterGap() -> Int` — page 0 merged into the rows held (a held mention is re-derived from the server's copy, a new one inserted, nothing dropped), read cursors re-read with `force: true` and adopted **forward-only**, rows recomputed against them. `loadReadState(…, force:)` and `adopt(_:forwardOnly:)` are the two seams that make the re-read possible. |
| `Mattermost/UI/Native/Activity/ActivityCoordinator.swift` | `resync(serverID:) -> Int`; `setFeedOnScreen` / `isFeedOnScreen` / `hasLoadedFeedOnScreen` (the feed is a tab or a sheet, so no `NativeLocation` names it — the view reports its own appearance); `resyncCount`. |
| `Mattermost/Core/Native/NativeSurfaceVisibility.swift` (**new**) | the watchdog's visibility gate as one value: foreground ∧ native routing ∧ (feed on screen ∧ loaded, or the location names **this** server's loaded thread pane / threads list / channel window). |
| `Mattermost/MattermostApp.swift` | `onSocketResync` now fans out to `threadCoordinator.resync` and `activityCoordinator.resync` beside `channelPaneCoordinator.resync`, **one `Task` per pane** (the handler is awaited on the socket's open path, so it must return at once and panes must not queue behind each other); `isSurfaceVisible` is one literal binding of `NativeSurfaceVisibility`. |
| `Mattermost/UI/Native/Activity/MentionsView.swift` | `ActivityFeedView` reports `setFeedOnScreen(server.id, …)` on appear/disappear. |
| `Mattermost.xcodeproj/project.pbxproj` | registers `NativeSurfaceVisibility.swift` — `Mattermost/Core/Native` is a **classic** group, not one of the six synchronized roots, so a new file there needs the four normal entries. |
| `MattermostTests/T34LivePaneResyncTests.swift` (**new**) | 7 tests, §4. |
| `scripts/t34live_mutations.sh` (**new**) | the four mutations of §5b, one at a time, each reverted with `git checkout --`, so "a mutation per new assertion" is runnable rather than only described. |
| `docs/parity.md` | the T34 row: the resync clause and the watchdog clause now say three surfaces, and the evidence lists this file. |
| `docs/t34-socket-stall-watchdog-build-note.md` | §3 and §5 marked superseded, pointing here (they said "the gate names the channel pane only"). |

Nothing new was invented for *when* a repair runs: the same `TeamSidebarCoordinator.onSocketResync` seam the
channel pane already used, and it is still reason-agnostic — a reconnect and a watchdog stall are the same gap.

## 2. The merge rules, one per surface

All three are the rule T34-R5 chose over `reload()` for the channel pane: **fetch the newest page, merge it
into what the reader holds, leave `phase` alone.** What "merge" means differs per surface because the
surfaces differ:

* **Thread pane** (`ThreadViewModel.resyncAfterGap`). The thread endpoint answers the root plus the newest
  replies in `order`; the reader may also hold older pages from `loadEarlier()`. The newest page is merged
  over the held replies (`ThreadDerivation.merge`, dedupe by id, order by `create_at`), so **the older page
  survives** and only genuinely new replies are inserted. Two asymmetries on purpose: a reply the reader holds
  as a **tombstone** (`delete_at > 0`) is never replaced by a server copy — a copy of a deleted post can only
  be a stale read, and resurrecting it is worse than a stale count; and the root's `reply_count` /
  `last_reply_at` are taken as `max(server, held)` and then re-derived from the thread row, because the count
  on the root post lags the row that counts the chain. A **failed** sweep returns 0 and changes nothing.
* **Threads list** (`GlobalThreadsViewModel.resyncAfterGap`). A gap can add threads, and the list's socket is
  as lossy as any other — so it joins. It is a *list of rows the server ordered*, so the rule is a
  **prepend-only** merge: a fetched thread the list already holds is dropped (the held row is the one the
  socket has been patching, and replacing it with a page copy could move a row the reader is watching), and a
  new one is kept only when it is **newer than the newest held row** — anything older belongs to a page the
  list has not paged to, and inserting it would break the cursor `loadMore()` continues from. In the Unreads
  tab only unread threads are added, for the same reason the tab exists.
* **Mentions feed** (`MentionsViewModel.resyncAfterGap`). The feed is a *search window* over many channels,
  and its rows are derived from posts + cursors. So it merges **posts**, not rows: a held post is replaced by
  the server's copy, a missing one appended, and `rows` is re-derived — which is the point, because the
  read cursors are re-read in the same sweep (`force: true`, forward-only), so a mention read on another
  client during the gap **stops drawing as unread** instead of waiting for a frame that was lost. Nothing the
  feed holds is dropped (a mention deleted during the gap stays until a `post_deleted` frame or the next
  `reload()`), and `insertedRowID` is set from the first inserted post without disturbing scroll.

## 3. Why the sweep is server-scoped

`ThreadCoordinator.resync(serverID:)` sweeps **every** loaded model of that server, not only the one on
screen: one WebSocket per server carries every thread's frames, so a gap loses them for all of the warm
chains (up to `warmThreadLimit`) and the team's threads list. A thread switched to afterwards that quietly
lacks one reply is the same defect one tap away. This is exactly what `ChannelPaneCoordinator.resync` already
does for its warm windows, and it is why the gate below can answer "a thread pane is visible" without knowing
*which* thread the sweep touched.

Models that are not `.loaded` are skipped: an unopened thread's first load *is* its fetch, and a `.failed` one
is waiting for the reader's retry, not for a repair.

## 4. The gate, and why it is now a value

The watchdog only treats a silent-but-open socket as a wedge when somebody is looking at data that socket
feeds (`SocketClient`'s `isSurfaceVisible`). Before this card that answer was **the channel pane only**, and
the stall note says why: naming a pane the app does not repair would spend page fetches on a window nothing
can fix. Now that three surfaces repair, the answer has to name all three:

```
NativeSurfaceVisibility.isVisible(serverID):
    foreground && native routing
    && ( the mentions feed is on screen and loaded            // ActivityCoordinator, reported by the view
      || the location names this server and (
             a thread pane  -> that thread's chain is loaded   // ThreadCoordinator.hasLoadedThread
           | the threads list -> any list is loaded            // ThreadCoordinator.hasLoadedThreadList
           | a channel        -> a window is loaded            // ChannelPaneCoordinator.hasLoadedWindow
         ))
```

Two things are load-bearing:

* **The feed is asked first and on its own.** It is a tab on a phone and a sheet in the regular layout, so
  the `NativeLocation` still names the channel the reader came from — whose window may well be evicted. Asking
  the location first would answer "nobody is looking" while the reader stares at the feed.
* **The rule lives in a struct of closures, not inline in `MattermostApp.bindShellStores`.** That wiring is
  inside an `App`, which no unit test can construct, so the rule could only be asserted by reading it. As a
  value, `T34LivePaneResyncTests` exercises every branch (and every "not yet" case) with no UI, and the app's
  wiring is one literal that cannot invent a fourth rule. Same reason
  `NotificationWorker.visibleChannel` answers rather than the socket guessing.

A `.loading` / `.failed` window answers `false` on purpose, as before: its own load is the fetch. `false` only
costs a delay; a wrong `true` turns the watchdog into a poll.

## 5. Tests, and the runs that back them

`MattermostTests/T34LivePaneResyncTests.swift` — 7 tests, Mac Catalyst, no server and no simulator. The
harness builds the **production** objects (`TeamSidebarCoordinator` + `SocketTeamEventSource` +
`ScriptedSocketTransport`, `ChannelPaneCoordinator`, `ThreadCoordinator`, `ActivityCoordinator`) and binds
`NativeSurfaceVisibility` to them exactly as `MattermostApp` does, so the test drives the shipped gate and the
shipped merge, not a copy.

| test | what it pins |
| --- | --- |
| `testAReconnectRefetchesAnOpenThreadAndKeepsTheOlderPageTheReaderLoaded` | **the card's scenario, main half.** A thread pane on screen with an older page loaded; the transport drops and reconnects; the reply the server published during the gap (`r3`) is merged in, the older page (`r1`) **survives**, `phase` stays `.loaded`, `hasMore` is untouched by the sweep, exactly one extra newest-page request, `reply_count` 2 → 3 and `last_reply_at` → 4000 adopted from the server. |
| `testAConfirmedStallRefetchesAnOpenThreadAndKeepsItsOlderPage` | the same repair for a **stall** (`ScriptedSocketTransport` answers pings forever, `SteppedSocketClock` walks the 150 s window): `source.stallResyncCount == 1` — found by silence, not by a reconnect — and the chain is repaired with the older page intact. |
| `testAReconnectRefetchesTheMentionsFeedAndKeepsThePageItHadPagedIn` | the feed: two search pages loaded, then a reconnect delivers a mention (`m4`) that landed during the gap; `m4` is inserted **and the second page's row (`m1`) survives**, rows are re-derived oldest-to-newest, one extra search request. |
| `testAConfirmedStallRefetchesTheMentionsFeed` | the feed on a stall, visible **only** through the view's own `setFeedOnScreen` report (no channel/thread window loaded): the mention appears, one refetch, `resyncCount == 1`. |
| `testAReconnectPrependsAThreadTheListDidNotHold` | the threads list: a thread newer than the newest held row is prepended; the held row `t1`, whose page copy says `reply_count: 9`, is **not** replaced (still 2) — held rows are the socket's, not the page's. |
| `testAPaneThatIsNotOnScreenIsNotRefetched` | the negative half: a loaded thread and a loaded feed, but the location names a channel whose window is not loaded and the feed is not on screen ⇒ past the full watchdog window nothing fires, `socketResyncCount == 0`, and **no** page request is spent. |
| `testTheGateNamesTheFeedAThreadPaneTheThreadsListAndTheChannelPane` | the gate table itself: foreground/routing off ⇒ false; a loaded channel window ⇒ true; a thread pane with a loaded chain ⇒ true, without one ⇒ false; the threads list ⇒ true only when a list loaded; the feed ⇒ true on screen, false otherwise; and another server's thread/channel is never this server's surface. |

Runs (this host, Mac Catalyst, `scripts/qa-test.py --platform mac`):

| label | scope | outcome |
| --- | --- | --- |
| `t34live-t34-all` | `T34LivePaneResyncTests` + `T34SocketStallWatchdogTests` + `T34SocketResyncTests` | **19 run, 0 failed** (7 + 5 + 7) — the two earlier T34 files are unweakened, `build/logs/t34live-t34-all.log` |
| `t34live-units-final` | `--only-testing MattermostTests` (whole unit target) | see §7, `build/logs/t34live-units-final.log` |
| `t34live-mutA` | the thread pane is not swept (`ThreadCoordinator.resync`'s model loop deleted) | **exactly the two thread tests red** (`["r1","r2"]` where `["r1","r2","r3"]` is owed; refetch count 1 where 2), 5 green, `build/logs/t34live-mutA.log` |
| `t34live-mutB` | the feed is not swept (`ActivityCoordinator.resync` no longer calls the model) | **exactly the two feed tests red** (inserted mention missing, `["m3","m2","m1"]` where `["m4","m3","m2","m1"]` is owed), 5 green, `build/logs/t34live-mutB.log` |
| `t34live-mutC` | the gate is not asked (`isVisible` returns `true` past the foreground check) | **exactly** `testAPaneThatIsNotOnScreenIsNotRefetched` (1 refetch where 0 is owed, 2 page requests) **and** the gate test red, 5 green, `build/logs/t34live-mutC.log` |
| `t34live-mutD` | the threads list is not swept | **exactly** `testAReconnectPrependsAThreadTheListDidNotHold` red, 6 green, `build/logs/t34live-mutD.log` |
| `t34live-1` | first run, before two assertion labels were corrected (they counted *earlier-page* requests as newest-page requests) | 3 assertion failures on **2** tests, both on those labels — the numbers in the tests were wrong, not the code; `build/logs/t34live-1.log` |
| `t34live-units-1` / `-final` | `--only-testing MattermostTests` (whole unit target), at the final tree | **2152 run, 11 skipped, 1 failed** — both runs, the same test: `T53MediaFootprintTests.testAStagedPayloadIsWrittenToDiskRatherThanHeldInMemory`, `build/logs/t34live-units-final.log` |
| `t34live-t53` | `T53MediaFootprintTests` alone, on the same tree | **1 failed** — the same test. It measures `phys_footprint` delta around a 32 MB `MediaFileCache.stagedFile` call and demands < 32 MB; this host reported **94 MB / 344 MB / 778 MB** on three runs (its own comment records 0.44 MB and 5.1 MB on quiet isolated runs and blames allocator state). No media code is touched by this card, the delta moves by hundreds of MB between identical runs, and the test's assertion above the budget (`all 33554432 bytes are on disk`) passes. Recorded, not hidden — and **not** claimed as green. |

### 5b. Re-derived on the rebased tree (`f0dc3d8` + the card's commit `b90fc8b`)

The runs above were made on `eab5a8a`. Everything below was re-run after the rebase, on the tree this card
publishes; `build/` is gitignored, so the logs stay with the host that made them.

| label | scope | outcome |
| --- | --- | --- |
| `t34live-rerun-t34-all` | `T34LivePaneResyncTests` + `T34SocketStallWatchdogTests` + `T34SocketResyncTests` | **19 run, 0 skipped, 0 failed** (7 + 5 + 7) — the two earlier files are unweakened by the rebase, `build/logs/t34live-rerun-t34-all.log` |
| `t34live-rerun-units` | `--only-testing MattermostTests` (whole unit target) | **2177 run, 11 skipped, 1 failed** — the one failure is `T53MediaFootprintTests.testAStagedPayloadIsWrittenToDiskRatherThanHeldInMemory` (331,481,792 bytes against a 32 MB budget), the pre-existing host flake above; `build/logs/t34live-rerun-units.log` |
| `t34live-rerun-t53` | that test alone, on **this** tree | **1 failed**, 685,131,200 bytes → fails in isolation too, so it is not a whole-target interaction this card introduced, `build/logs/t34live-rerun-t53.log` |
| `pristine-t53` | that test alone on a **pristine `origin/main` `f0dc3d8` worktree**, none of this card applied | **1 failed**, 777,881,216 bytes → the failure is the base's, not this card's, `build/logs/pristine-t53.log` in that worktree |
| `t34live-rerun-mutA` | the thread pane's merge not called (`_ = await model.resyncAfterGap()` deleted from `ThreadCoordinator.resync`'s model loop) | **exactly** `testAReconnectRefetchesAnOpenThreadAndKeepsTheOlderPageTheReaderLoaded` + `testAConfirmedStallRefetchesAnOpenThreadAndKeepsItsOlderPage` red, 5 green, `build/logs/t34live-rerun-mutA.log` |
| `t34live-rerun-mutB` | the feed's merge not called (`_ = await model.resyncAfterGap()` deleted from `ActivityCoordinator.resync`) | **exactly** `testAReconnectRefetchesTheMentionsFeedAndKeepsThePageItHadPagedIn` + `testAConfirmedStallRefetchesTheMentionsFeed` red, `build/logs/t34live-rerun-mutB.log` |
| `t34live-rerun-mutC` | the gate not asked (`return true` right after the foreground/routing guard in `NativeSurfaceVisibility.isVisible`) | **exactly** `testAPaneThatIsNotOnScreenIsNotRefetched` + `testTheGateNamesTheFeedAThreadPaneTheThreadsListAndTheChannelPane` red, `build/logs/t34live-rerun-mutC.log` |
| `t34live-rerun-mutD` | the threads list not swept (`_ = await list.resyncAfterGap()` deleted from `ThreadCoordinator.resync`'s list loop) | **exactly** `testAReconnectPrependsAThreadTheListDidNotHold` red, 6 green, `build/logs/t34live-rerun-mutD.log` |

Each mutation was applied alone, run against `T34LivePaneResyncTests` only, and reverted with
`git checkout -- <file>` before the next: the driver is `scripts/t34live_mutations.sh` (it ends by printing
`git status --short`, which must show no modified file), and the tree that was committed is that restored
tree. On the rebased tree **no mutation needed a new expectation** — the four anchors still assert what §5
says they assert.

## 6. What this does **not** prove, and the limits that stay

* **No live (XCUITest) variant.** Making a running app's socket go silent from outside needs a debug seam that
  kills only inbound frames; the scripted transport drives the production client and the production merge,
  which is the stronger proof. The card asked for the scripted path.
* **A repair is bounded by what one page can see.** A gap longer than a page of replies / a page of the feed
  (60 rows) is repaired to "the newest 60 plus what you already had" — the same limit
  `docs/t34-socket-resync-build-note.md` §4 states for the channel pane. A mention that fell out of page 0 is
  not re-fetched; a reply older than the newest page is only found by paging back.
* **A deleted post stays drawn.** Deleted during the gap, it is not in the sweep's page, so it stays until a
  `post_deleted` frame or the next `reload()`. (A reply the reader already holds as a tombstone is never
  un-deleted — the opposite direction is guarded in the merge.)
* **The feed's unread state is only as fresh as its cursors.** The sweep re-reads `channels/members` per team
  and per-channel fallbacks for the window; a mention whose channel is in neither the window nor a team list is
  left as it was.
* **A stall is still repaired within `threshold + checkInterval` (≈3 min), not instantly** — unchanged from the
  watchdog note; this card extends *which* panes are repaired, not how fast a gap is noticed.
* **Cost per fire.** One newest-page request per loaded thread model, per loaded list, per feed, plus the
  feed's read-state requests and one `GET /channels/{id}` per unseen channel in the window. It is a sweep of
  what the session keeps warm, exactly like the channel pane's; the watchdog's quiet multiplier still caps the
  steady-state rate on a socket that stays silent.
* **Delivery.** The work was written and verified twice: once on `eab5a8a` (the runs in §5) and again on
  `f0dc3d8` after the rebase (§5b). The first attempt could **not** be delivered — part way through that run
  the host's shell lost access to `~/Documents` (`Operation not permitted` on every path under it), which is
  both the main checkout and the object store the worktree is linked to, so no commit and no push were
  possible; the card was left blocked rather than closed on local history. This tree is committed and pushed
  to `origin/main`; §7 names the commits and the `git ls-remote` assertion.

## 7. Runs at the final tree, and delivery

* `t34live-rerun-t34-all` on the rebased tree (`f0dc3d8` + this card) — **19 run, 0 failed** (§5b).
* `t34live-rerun-units` — `MattermostTests` whole target, same tree: **2177 run, 11 skipped, 1 failed**, the
  single failure being the T53 media-footprint test, which fails alone on this tree (685 MB) **and** alone on
  a pristine `f0dc3d8` worktree (777 MB), i.e. it is the base's, in this host, both before and after this
  card (§5, §5b; logs `build/logs/t34live-rerun-units.log`, `t34live-rerun-t53.log`, and `pristine-t53.log`
  in the pristine worktree). Nothing here touches media code, and every T34 test is green.
* Mutations A / B / C / D re-derived on the rebased tree (§5b), each reverted before the next, the restored
  tree being the one committed.
* The earlier tree's runs are kept above (`t34live-t34-all` 19/19, `t34live-units-final` 2152/11/1) so the two
  derivations can be compared; the rebase added 25 tests from other cards and changed none of ours.
* **Published.** Code and docs are `4785275` on `origin/main`, rebased onto `f0dc3d8`; the three T34 files were
  re-run on that published tree — **19 run, 0 failed** (`build/logs/t34live-published-t34-all.log`) — and
  `git ls-remote origin refs/heads/main` was asserted equal to the local `HEAD` (`4785275`). The push is the
  card's gate, not a convenience: the earlier attempt had no commit at all.

## 8. Repro

```
# the card's own file
python3 scripts/qa-test.py --platform mac --only-testing MattermostTests/T34LivePaneResyncTests --label t34live
# the three T34 files together (the earlier two must not weaken)
python3 scripts/qa-test.py --platform mac --only-testing MattermostTests/T34LivePaneResyncTests \
    --only-testing MattermostTests/T34SocketStallWatchdogTests \
    --only-testing MattermostTests/T34SocketResyncTests --label t34live-t34-all
# whole unit target
python3 scripts/qa-test.py --platform mac --only-testing MattermostTests --label t34live-units

# mutation A: delete `_ = await model.resyncAfterGap()` from ThreadCoordinator.resync's model loop
#   expected: the two thread tests red
# mutation B: delete `_ = await model.resyncAfterGap()` from ActivityCoordinator.resync
#   expected: the two feed tests red
# mutation C: `return true` after the foreground guard in NativeSurfaceVisibility.isVisible
#   expected: testAPaneThatIsNotOnScreenIsNotRefetched + the gate test red
# mutation D: delete `_ = await list.resyncAfterGap()` from ThreadCoordinator.resync's list loop
#   expected: testAReconnectPrependsAThreadTheListDidNotHold red
```

All four in one go, applied and reverted automatically:

```
bash scripts/t34live_mutations.sh      # writes build/logs/t34live-rerun-mut{A,B,C,D}.log
```
