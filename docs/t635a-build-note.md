# T635-A — a restored channel pane paints nothing: cause, fix, and the falsifier that reds on the old tree

Card: `t_7cb5dd3e` (filed by QA, `t_635046c9`). Date: 2026-10-28.
Product tree: `origin/main` **ecf4e7c** (= `5f55bf6`, product code identical to `2baddc6`).
Every build below came from a detached worktree of this repo (shared checkout had other workers' edits);
the fixture channel is the one QA used: `#t36-threads` (`psw97y5zqpfnpembwxraizuije`) in team `perf`.
Device: iPhone 16 Pro `81AD82E4-B711-45B7-A539-33D9E861A7A5` (iOS 18.3.1), fixture `mm-perf`
Mattermost 9.11.19 at `http://127.0.0.1:8065`.

---

## Verdict

**Fixed.** A launch that restores a saved channel now paints its newest row (5/5 `simctl` launches,
no XCTest in the loop), and the falsifier that measures it reds on the old product code and is green
on this one. The cause is **not** a bad fetch, an empty page, a session failure or a persisted anchor —
QA had already ruled those out, correctly. It is two coupled layout facts:

1. **The scroll-view resolver could not be built when it was needed.** `ScrollViewResolver` was the
   first child of the `LazyVStack`. A lazy stack builds only the children near the viewport, so a pane
   whose viewport had been left *past* its rows never built the resolver, the controller never
   attached, and both recovery paths (`pinToBottom`, `pollReaderPosition`) no-op on
   `isAttached == false`. Measured on the old tree with the geometry seam:
   `attached=false, size=0, viewport=0` for the whole 45 s run, `items=62`, `rows=0`.
2. **The initial position was never established from a row.** The list only exists once the model is
   `.loaded`, so its first layout already holds the whole first page and
   `onChange(of: items.count) { previous == 0 }` — the only thing that called `pinToBottom()` on a first
   load — never fires. What was left was `defaultScrollAnchor(.bottom, for: .initialOffset)`, which is
   resolved against an **estimated** content height and a viewport that is not yet real. Two stuck
   shapes were measured on consecutive launches, both frozen for the whole run:

   | shape | measured | meaning |
   |---|---|---|
   | the void | `offset=2635.3 size=3126.0 viewport=490.7 rows=0` (offset = `size − viewport`) | the viewport sits at the bottom of an estimate whose real height was 3296 — below every row the layout ever built. Nothing to materialise, so the estimate is never corrected |
   | the sliver | `offset=2638.3 size=3129.0 rows=1 topY=−15` | one row's top edge 15 pt above the viewport top, ~475 pt of blank pane under it. `distanceFromBottom = 0`, so "the content is at its end" is *true* here and proves nothing |

   A `LazyVStack` materialises only what is near the viewport. With the viewport in the void, nothing is
   built; with nothing built, the estimate is never replaced by real heights; with the estimate stale,
   the viewport stays in the void. That loop is why the pane was still blank at 85 s and why no spinner,
   error or "No messages yet" ever appeared — the pane is `.loaded` with a non-empty window the whole
   time, exactly as QA deduced.

## The fix (two parts, both in the channel list)

* `ChannelScrollPosition.swift` — `ScrollViewResolver` (a) is now mounted as a sibling of the lazy stack
  inside a zero-spacing `VStack` (it adds no height), and (b) **keeps looking** for its `UIScrollView`
  (≈4 s of 16 ms retries, stopping the moment it is found). The old form resolved once on the next
  main-queue turn and again on `updateUIView`; a pane that paints nothing receives no further
  `updateUIView` calls, and one launch in five came up with `attached=false` for that reason (launch 4 of
  the first verification run). A `.background` of the lazy stack was measured too: never attached.
* `ChannelView.swift` — `placeInitialPosition(_:)`: **one** placement per mount, when the list appears
  with a non-empty window. It waits (bounded, 5 s) for the pane's own layout, then places the pane by
  naming its newest **row** (`proxy.scrollTo(newest.id, anchor: .bottom)`), checks the claim against the
  scroll view itself (`lowestRowBottom >= viewportHeight − 20`), and — when the check fails because the
  lazy stack has nothing laid out where the viewport is — returns to the top of the content (always
  inside the real layout), lets real rows build, and places again. Four bounded rounds, then the
  existing `pinToBottom()` absorbs the bottom padding. Panes opened **at a post** (`opensAtPost`, from
  `focusPostID`, i.e. T39's jump) and windows that already fit their viewport are skipped: their
  position belongs to the jump, and this must not move a reader.

There is deliberately **no timer** and no "looks wrong, fix it" polling: after the placement the
viewport belongs to the reader, which is the property the T95-A launch policy assumes.

## The falsifier

New files (nothing in `MattermostUITests/T37-ReactionsUITests.swift`, which `t_1f9af95a` owns):

| file | what it is |
|---|---|
| `Mattermost/UI/Native/Channel/ChannelScrollDiagnostics.swift` | `-uiTestExposeScrollGeometry`: publishes `rows/visible/items/offset/size/viewport/lowestRow/fromBottom/inside/bottomRow` as the accessibility value of `channelPostList.scrollGeometry`, and appends the same reading to `Documents/t635-scroll-geometry.log`, so a **`simctl`-only** run (no XCTest) can be read back from the app container |
| `MattermostUITests/T635RestoredPaneUITests.swift` | `testARestoredChannelPaneShowsItsNewestRow` — signs in, opens the fixture channel, terminates, relaunches **without** `-uiTestResetPersistedState`, and asserts (a) at least one `post.<id>` row and (b) from the seam: `visible > 0` **and** a row reaching the viewport's bottom edge. `testReopeningTheChannelFromTheSidebarPaintsTheTimeline` — criterion 4 |
| `MattermostTests/T635ScrollGeometryTests.swift` | the five readings above, pinned as unit tests (the void, the sliver, the placed pane, an offset past the end, a detached list) |

**Red on the old product code** (worktree `wt-instr` = `ecf4e7c` + the instrumentation only, no fix):
`testARestoredChannelPaneShowsItsNewestRow` failed after 67.6 s with three failures, all of them the
product's:

```
…:91: error: a restored channel pane must paint at least one post row within 45 s (defect t_7cb5dd3e:
                 the pane painted none for 85 s). Last geometry: items=62 rows=0 visible=0 offset=0.0
                 size=0.0 viewport=0.0 lowestRow=-inf fromBottom=0.0 top=none
…:105: error: at least one laid-out row must intersect the viewport: items=62 rows=0 visible=0
                 offset=0.0 size=0.0 viewport=0.0 lowestRow=-inf fromBottom=0.0 top=none
…:107: error: the pane must open on its newest row — the lowest row must reach the viewport's bottom edge:
                 items=62 rows=0 visible=0 offset=0.0 size=0.0 viewport=0.0 …
```

`items=62, rows=0, size=0, viewport=0` is the whole defect in one line: 62 posts in the model, no
`UIScrollView` attached to the controller, nothing laid out, for as long as the test waited.

**Green on this tree**: `Executed 2 tests, with 0 failures` — `testARestoredChannelPaneShowsItsNewestRow`
28.2 s, `testReopeningTheChannelFromTheSidebarPaintsTheTimeline` 29.5 s (full class run, same build).
The unit bundle on the same commit is `Executed 1730 tests, with 8 tests skipped and 0 failures`
(`MattermostTests`, 36.7 s), which includes the five new `T635ScrollGeometryTests`.

## Criterion 3 — the `simctl`-only re-verification (no XCTest)

`scripts/t635a-restore-verify.sh` (`simctl install` over the existing data container + keychain, `terminate`,
`launch` **without** the reset seam, screenshot at 12 s, then read `Documents/t635-scroll-geometry.log`
out of the container):

```
bash scripts/t635a-restore-verify.sh …/dd-probe/Build/Products/Debug-iphonesimulator/Mattermost.app 5 12
```

The state under test is a **restore**, not a fresh open: the device's plist holds
`mm.native.lastChannel = {channelID: psw97y5zqpfnpembwxraizuije, channelName: t36-threads, team perf}`,
no launch passes `-uiTestResetPersistedState`, the pane comes up pushed (a `Back` chevron, no sidebar), and
the *same* procedure on the base build reproduces the card's blank pane — which a sidebar open does not
(§Criterion 4).

| launch | reading at 12 s (last sample of the launch's slice) | rows on screen | a row at the bottom edge |
|---|---|---|---|
| 1 | `rows=10 visible=10 items=62 offset=2805.3 size=3296.0 viewport=490.7 topY=35.7 lowestRow=478.0 fromBottom=0.0` | 10 | yes |
| 2 | `rows=10 visible=10 items=62 offset=2759.3 size=3250.0 viewport=490.7 topY=36.3 lowestRow=478.7 fromBottom=0.0` | 10 | yes |
| 3 | `rows=10 visible=10 items=62 offset=2805.3 size=3296.0 viewport=490.7 topY=35.7 lowestRow=478.0 fromBottom=0.0` | 10 | yes |
| 4 | `rows=10 visible=10 items=62 offset=2805.3 size=3296.0 viewport=490.7 topY=35.7 lowestRow=478.0 fromBottom=0.0` | 10 | yes |
| 5 | `rows=10 visible=10 items=62 offset=2805.3 size=3296.0 viewport=490.7 topY=35.7 lowestRow=478.0 fromBottom=0.0` | 10 | yes |

The screenshots agree (`<out>/launch-N-12s.png`): `# T36 Threads` with the newest post (`t37 socket target
1793174505`, 3:01 AM) as the last row, directly above the composer. Launch 2's content is 46 pt shorter
because a socket post arrived during that launch — the pane is live, not a frozen snapshot.

**The pane still starts in the void** — this is the round trip that shows the fix is a repair, not a
lucky layout. Launch 1's own log, first sample and the placement's two rounds, 0.5 s end to end:

```
t= 0.00s rows=0 visible=0 items=62 offset=2681.3 size=3172.0 viewport=490.7 lowestRow=-inf
place[0] scrollTo post-gyunhsayttyj3jj7gkm8negrxh lowestRowBottom=-inf covered=false   ← the void, as on the old tree
         (escalation: scrollToTop — the top of the content is always inside the real layout)
t= 0.25s rows=7 visible=7 items=62 offset=0.0     size=3172.0 viewport=490.7           ← real rows exist here
place[1] scrollTo post-gyunhsayttyj3jj7gkm8negrxh lowestRowBottom=490.67 covered=true
t= 0.51s rows=10 visible=10 items=62 offset=2805.3 size=3296.0 viewport=490.7          ← placed, and stays
```

So the exact shape QA's report was stuck in for 85 s (`offset=2681.3 size=3172.0 rows=0`) still occurs at
t=0 — it is what the estimated layout produces — and it is now repaired in under half a second, every
launch, before the user can see it.

One harness caveat, reported rather than hidden: on the **first** 5-launch attempt right after a
`simctl install` that followed an XCTest run, launches 1 and 2 were still on a blank launch window at 12 s
(no chrome, no pane mounted, no geometry log at all — the app had not finished starting; no crash report
was written). The same installed build then gave 3/3 rendered at 6 s in a cold probe
(`cold1-6s.png` … `cold3-45s.png`), and the 5/5 table above is a re-run on that state. A launch that slow
is a simulator/host stall, not the pane: the pane's own measure is `rows=0` with a mounted list, and there
was no list.

## Criterion 4 — does re-opening the channel from the sidebar repair the view?

**Yes, on the old tree, and the repair is a re-mount.** Measured with `simctl`-free touch input by
running `testReopeningTheChannelFromTheSidebarPaintsTheTimeline` against the **unfixed** tree
(`wt-instr`), which the test records as an attachment:

```
T635 criterion 4 — restored pane painted rows: false;
geometry: items=62 rows=0 visible=0 offset=0.0 size=0.0 viewport=0.0 fromBottom=0.0 top=none;
after Back + row tap, rows painted: true
```

So a reader who hits this has a two-tap workaround (`Back`, then the channel's row in the sidebar), and
the restored pane itself is the only broken state. Note the same attachment measured the repaired pane's
seam as `attached=false` as well: on the old tree the tap-opened pane's rows come from a *new* view
instance whose resolver never attached either, so the scroll machinery (the reader's anchor, the paging
restore) was inoperative there too — the same defect, one tap away from the card's report.

## What this does not fix / did not touch

* Symptom **B** (the SIGSEGV under XCTest's accessibility snapshots) is `t_8d033037` and untouched here.
  It is **reproducible in this codebase**: one crash report was written during this session
  (`~/Library/Logs/DiagnosticReports/Mattermost-2026-10-28-032731.ips`, `EXC_BAD_ACCESS` /
  `KERN_INVALID_ADDRESS at 0x0`, faulting frames
  `-[XCElementSnapshot _fetchSimpleValueForKey:]` → `_os_log_fault_impl` → `_platform_strcmp`), i.e. the
  same stack QA filed. It fired once across the UI-test runs in this session and did not affect any
  verdict below — every run reported its own pass/fail. Nothing in this change touches it.
* The 85 s blank pane is *not* re-measured on the old tree with the fix removed: the old tree cannot be
  measured by construction (the resolver never attaches, which is the defect). The old tree's evidence
  is the seam's own `attached=false, size=0, viewport=0` line, which is exactly that limitation.
* No new timeout, retry-on-a-timer, or background poll was added to the channel path. The placement is
  bounded, runs once per mount, and is skipped for post-routed panes and short windows.

## Commands used

```bash
# falsifier, red on the old product code (worktree at ecf4e7c + instrumentation)
xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=iOS Simulator,id=81AD82E4-…' -derivedDataPath …/dd-instr-test \
  -only-testing:MattermostUITests/T635RestoredPaneUITests    # TEST_RUNNER_MM_AUTH_* from scripts/perf_seed.py

# green on this tree
xcodebuild test … -only-testing:MattermostUITests/T635RestoredPaneUITests   # 2 passed
xcodebuild test … -only-testing:MattermostTests                            # full unit bundle
```
