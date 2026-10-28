# T8f — the channel sidebar is a `ScrollView` + `LazyVStack`: the last 6 of 7 elements per row were the `List`

Card `t_a3d1c600` (follow-up to T8e, `t_ce08486d`, `docs/t8e-a11y-tree-decision.md`). Branch
`wt/t_a3d1c600`, based on **`b741a18`** (T8e's tip). Host `MacBook-Pro-6.local`, Xcode 26.6
(17F113), sim `81A7F251` (iPhone 16 Pro, iOS 18.3.1), fixture server `127.0.0.1:8065`
(`perfprobe`, seeded by `scripts/perf_seed.py`), stub servers 8120/8121/8122 for the stub suite.

T8e made every row **one** element and measured that a row still cost **7**: `Cell` + five empty
`Other` wrappers around the row's own element, i.e. the `List`'s scaffolding. This card removes the
`List`. The result is measured below on the same 8-test batch, with the same readers.

---

## 0. Verdicts, up front

1. **The per-row cost is now 1.** The drawn-shell snapshot of the channel list was
   **197 elements for 11 realised rows (17.9/row)**; it is now **127 elements for 26 realised rows
   (4.9/row)** — the six wrappers are gone, and the row's own element (T8e) is all that is left of a
   row. The `List`-provided chrome around the rows went with them: `elements − rows` on that screen
   **186 → 101**.
2. **One snapshot of the same screen now holds 2.4× as many rows in 36 % fewer elements.** The
   realised window changed with the container (26–36 rows per tree, was 7–21), so the honest
   comparison is per realised row, not per screen: **every query that walks the shell is 21–28 %
   cheaper** (`nativeChannelPane` 41.5 → 32.8 KB each; one `channelSidebar.channel.<id>` lookup
   0.93 → 0.67 MB each).
3. **The whole batch's app log is 50.5 → 45.9 MB (−9.1 %)**, of which XCTest's own serialiser
   33.13 → 29.73 MB (−10.3 %); its own `NotificationShortLookView` poll (7.5 MB) is untouched and
   still not ours.
4. **Nothing in the identifier contract moved** (`docs/t8e-a11y-tree-decision.md` §2.3): every row is
   still exactly one element with the same identifier, label, value and traits. One identifier is
   **new** — `channelSidebar.scroll`, on the list's scroll view — because the suites must scroll
   something, and the thing they used to scroll (the `List`'s `UICollectionView`) no longer exists.
5. **One `List` behaviour is lost, one was mis-recorded** (§4): the shell's toolbar draws **no
   background material over scrolled content** (the `List` case is unmeasured — see §4.3). The claim
   that **sticky section headers do not stick** is **retracted** — they do, and §4.2 carries the
   correction with the measurement (T8g, `docs/t8g-sticky-header-decision.md`). Row separators and the
   grouped/uppercase phone chrome *are* reproduced.

---

## 1. Method (re-runnable)

The A/B is the T8d/T8e batch — same 8 tests, same device, same derived data, same command — run once
on T8e's tip (`after2-app.log`, this card's **before**) and once on this branch (`after-app.log`):

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<fixtures, scripts/perf_seed.py> \
python3 scripts/qa-test.py --platform ios --sim id=81A7F251-8B31-4945-8783-5A264C14B8D5 \
  --derived-data ~/Library/Developer/Xcode/DerivedData/mmios-t8d --log-dir build/logs/t_a3d1c600 \
  --label t8f-after --timeout 2400 \
  --only-testing MattermostUITests/T95ShellLayoutUITests \
  --only-testing MattermostUITests/T39JumpUITests \
  --only-testing MattermostUITests/T39SearchUITests \
  -- -clonedSourcePackagesDirPath ~/Library/Developer/Xcode/DerivedData/mmios-t95b/SourcePackages
```

The app log for the run window (test suite started 07:26:55, ended 07:29:40), then the T8e readers
unchanged (`build/logs/t8e/*.py`), plus one new reader for the per-row cost:

```
xcrun simctl spawn 81A7F251-8B31-4945-8783-5A264C14B8D5 log show \
  --start '2026-10-28 07:26:50' --end '2026-10-28 07:29:50' \
  --predicate 'process == "Mattermost"' --info --debug --style syslog > after-app.log

python3 build/logs/t8e/shapes.py  after2-app.log after-app.log   # elements per snapshot
python3 build/logs/t8f/perrow.py  after2-app.log after-app.log   # rows vs elements in one tree
python3 build/logs/t8e/vol.py     after-app.log                  # bytes by subsystem
python3 build/logs/t8e/qbypred.py after-app.log                  # MB per query shape
python3 build/logs/t8e/glyphparents.py after-app.log             # symbol-labelled Images
python3 build/logs/t8e/rowpid.py  after-app.log                  # outermost row elements per launch
```

Artifacts are in the **main tree** (`build/logs/t8f/`: `after-app.log` 45.9 MB, `perrow.py`,
`before-shots/`, `after-shots/`, `final-shots/`, `live-shots/`, `batch-shots/`, `base-shot/`) and in
this worktree (`build/logs/t_a3d1c600/`: the run logs `t8f-before-stub.log`,
`t8f-after-stub.log`, `t8f-final-stub.log`, `t8f-after.log`, `t8f-units.log`,
`t8f-t33live.log`).

---

## 2. The change

| file | change |
|---|---|
| `Mattermost/UI/Native/Sidebar/ChannelSidebarView.swift` | `List { workspaceSection; channelSections; footerSection }.listStyle(.sidebar)` → `ScrollView { LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) { … } }`; new `channelSidebar.scroll` identifier on the scroll view; the phone's `List` chrome re-drawn by three new modifiers (`channelSidebarRowContent`, `channelSidebarRowSurface`, `channelSidebarSectionHeaderSurface`); a `@Environment(\.horizontalSizeClass)` so the grouped chrome is drawn on compact only |
| `MattermostUITests/ShellSettle.swift` | new `ShellSettle.channelSidebarScroll(_:)` — the **one** reader of the list's scroll element (identifier first, `collectionViews.firstMatch` kept only as a pre-T8f fallback) |
| `MattermostUITests/T33-ChannelSidebarUITests.swift` | `revealRow` scrolls `ShellSettle.channelSidebarScroll` instead of `nativeTeamSidebar.collectionViews.firstMatch`; doc comment updated |
| `MattermostUITests/T34-ChannelPostListUITests.swift`, `T45AvatarUITests.swift`, `T4dUnreadThreadsUITests.swift`, `T39SearchUITests.swift` | the same helper at the four other places that scrolled the sidebar through `collectionViews.firstMatch` (the card named T33's; these are the rest of the same idiom, and they are the suites most likely to break silently) |
| `docs/parity.md` | QA subsection for T8f |

The row *content* is untouched — `ChannelSidebarRow`, `CategoryHeader` and `ThreadsRailRow` keep their
`.accessibilityRepresentation` (T8e) and gain only the insets a `List` row used to supply.

---

## 3. Measured, before → after

### 3.1 Elements per snapshot

`shapes.py` (dominant shape of the drawn channel list) and `perrow.py` (rows vs elements inside one
tree):

| | before (`b741a18`) | after (this branch) |
|---|---|---|
| trees in the batch | 352 | 363 |
| drawn-shell snapshot (dominant) | **140 trees: 11 channel rows → 197 elements** | **153 trees: 26 channel rows → 127 elements** |
| elements per realised row incl. chrome | **17.9** | **4.9** |
| rows a tree with channel rows holds | 7 – 21 | 26 – 36 |
| elements − rows on the dominant shape (chrome) | 186 | 101 |
| largest tree of the batch | 234 | 234 |
| mean elements per tree | 121.8 | **94.2** (−22.7 %) |
| median elements per tree | 103 | 124 |
| trees with channel rows | 157 | 169 |

Read it two ways, because the container changed what gets realised:

* **Per row** — the number this card is about: a row cost 7 snapshot elements (T8e's `Cell` + five
  `Other` wrappers + the row itself) and now costs **1**. `perrow.py` shows the same shape: the
  before log's trees with channel rows are 7–21 rows in 33–230 elements; the after log's are 26–36
  rows in 58–147 elements — a tree with **34 rows now costs 63 elements**, where a tree with **21
  rows cost 230**.
* **Per screen** — the median went **up** (103 → 124) because a `LazyVStack` realises a larger
  window than a `List` did (26–36 rows instead of 7–21). That is a *different* claim from "the tree
  got smaller", and it is the one that matters for the firehose: the per-query byte cost (§3.2) is
  what went down, and it went down despite more rows being in the tree.

### 3.2 MB per query, and the batch total

| | before | after | Δ |
|---|---|---|---|
| batch wall time | 169.0 s | 164.7 s | −2.5 % |
| tests | 8 run / 1 skipped / 0 failed | 8 run / 1 skipped / 0 failed | — |
| app log, all pids | 50.5 MB | **45.9 MB** | **−9.1 %** |
| of which `com.apple.dt.xctest` | 33.13 MB | **29.73 MB** | **−10.3 %** |
| queries | 371 | 381 | — |
| bytes attributed to a query | 50.4 MB | 45.7 MB | −9.3 % |
| `nativeChannelPane`, typed (×123 / ×137) | 41.5 KB each | **32.8 KB each** | **−20.9 %** |
| one `channelSidebar.channel.<id>` lookup (×6) | 0.93 MB each | **0.67 MB each** | **−28.3 %** |
| XCTest's own `NotificationShortLookView` poll (×65 / ×63) | 7.5 MB | 7.3 MB | — (not ours) |

The 371 → 381 queries are the suite change, not the view: `ShellSettle.channelSidebarScroll` does an
identifier lookup where the old helpers took `collectionViews.firstMatch`, and `revealRow` now
scrolls the list itself (its old target resolved to the `List`, which after the swap would have been
nothing at all). More queries, fewer bytes each.

### 3.3 Glyphs

`glyphparents.py`: unchanged from T8e — the only symbol-labelled `Image`s left in the batch are the
tab bar's own two (`conversation` 167, `bookmark` 5). The channel list contributes none.

---

## 4. What the `List` gave us, kept or lost

### 4.1 Kept

* **Laziness.** `LazyVStack` realises only what is near the viewport, so a row below the fold is still
  absent from the tree — the property `revealRow` exists for. Measured: the live 347-channel fixture
  still needs scrolling to reach a row (T33 live, the same six tests and the same scroll paths).
* **Row separators.** Re-drawn per row: a hairline above every row but the first in a group
  (`channelSidebarRowSurface`), inset 16 pt, on compact only — `.sidebar` drew them, so they are
  ours now. Visible in `final-shots/t33-stub-01…png`.
* **The grouped phone chrome.** `.listStyle(.sidebar)` on a phone drew the rows on a grouped surface
  with an upper-cased secondary caption above each group. Re-drawn: grouped background behind the
  list, a white surface per row (`secondarySystemGroupedBackground`), a caption in
  `.footnote`/`.textCase(.uppercase)`/`.secondary` with its own opaque background. The stub suite's
  own screenshot is the before/after pair: `before-shots/9674E37B…png` vs
  `final-shots/3383AED8…png` — same rows, same order, same captions; the only visual differences are
  **square instead of rounded card corners** and a slightly taller row (44 pt, the old `List` row was
  ~50 pt in the workspace group).
* **Selection.** Nothing to keep: this `List` never had a `selection:` binding — a row is a `Button`
  that routes through `NativeNavigation`, and `.isSelected` rides the row's accessibility traits
  (T8e). Verified: `grep selection: ChannelSidebarView.swift` is empty.

### 4.2 Retracted: "sticky section headers do not stick" — **they do stick**

> **Correction (T8g, card `t_af56f51a`, 2026-10-28).** The paragraph below is **wrong** and is kept
> only because this note is a record. The headers **do** pin: across the same run's 62 trees that hold
> channel rows, `channelSidebar.category.channels` is at **y = 386.0** in the 25 trees where the list is
> at rest (in flow) and at **y = 166.3** in the 37 trees where it is scrolled, **unchanged across
> 498.4 pt of scrolling** (first channel row −314.3 … −812.7), with no third value. 166.3 is 14 pt
> below the navigation bar's bottom edge (152.3) — the list scrolls *under* the bar, so that is the pin
> point, not 0–60. The header at 166.3 is in the tree this section quotes, annotated "in flow".
> Full evidence, and the upstream side (v2.45.0 does **not** pin its category headers at all): 
> `docs/t8g-sticky-header-decision.md`. No behaviour loss; nothing to fix.

The original recording, quoted for the record:


```
ScrollView   {{64.0, 0.0}, {338.0, 874.0}}   channelSidebar.scroll
Button       {{80.0, -812.7}, {306.0, 44.0}} channelSidebar.channel.T38 media heavy
Button       {{80.0, -20.7},  {306.0, 44.0}} channelSidebar.channel.t44av-nooffer
Button       {{96.0, 166.3},  {274.0, 15.7}} channelSidebar.category.channels        ← in flow
Button       {{96.0, 477.3},  {274.0, 15.7}} channelSidebar.category.direct_messages ← in flow
```

The rows above the viewport's top belong to a category whose header is off screen — if it were
pinned, that header would be the element at the top of the scroll view, and it is not (no header
element in any of the run's 30+ trees has a `y` between 0 and 60). The run's own screenshot of the
scrolled list (`live-shots/FB636526…png`, the `t33-01` attachment) shows the same thing: the top of
the list is a `#` channel row, not a category caption.

`docs/parity.md` has no row that promises sticky headers (upstream's `category_list` does stick them
on iOS, so this is a **parity loss**, not a parity-neutral change), and making them stick by hand —
tracking the scroll offset and drawing a header overlay — is a separate change with its own risk.
Recorded here, with the code comment saying so, rather than left in a comment claiming a behaviour
that measurement contradicts. Filed as **`t_af56f51a`** against the architect (parity decision +
fix), together with §4.3.

**End of the retracted paragraph.** Everything in it is wrong — the window (`0 < y < 60`) misses the
pin point (166.3), the tree above shows the header at 166.3 with the first row at −812.7, the
screenshot shows `⌄ CHANNELS` at ≈172 pt, and upstream's `category_list` does **not** stick its
headers. Verdict in `docs/t8g-sticky-header-decision.md`; T8g closed it with no code change.

### 4.3 Lost/observed: the toolbar has no material over scrolled content

The list is a `ScrollView` at `{{64.0, 0.0}, {338.0, 874.0}}` — it runs the full height of the
window, under the shell's `NavigationBar` (`{{0.0, 56.3}, {402.0, 96.0}}`). At rest the safe-area
inset keeps the first caption below the bar (the stub screenshot: `WORKSPACE` at ≈180 pt), so nothing
is wrong until the list is scrolled; scrolled, rows pass **behind the toolbar's controls**, which
draw no background material (`live-shots/FB636526…png`). The bottom tab bar does draw one.

**I did not measure the `List` case**, and I will not claim this is a regression: the base build's run
of the same test (`build/logs/t_a3d1c600/base-shot.log`) dies in the app-loss class (§5) before it
takes its own screenshot, and there is no other pre-change phone frame of a *scrolled* channel list
in the repo (the `docs/t33-shots/*` frames are the iPad layout). What is certain is what the after
build draws. If the shell wants the bar to occlude content, that is a shell change
(`.toolbarBackground`), not a channel-list one — recorded so it is not rediscovered as a list bug.

**T8g: this one is required.** It is a legibility defect (two texts drawn on each other, and upstream
keeps the list below a fixed opaque header). Filed as `t_560103f6` for `mmios-ios` — a shell-chrome
card, with the fix in the shell's toolbar/inset, not here. Card and reasoning: T8g §4.

---

## 5. Test runs

| run | this branch | base / before |
|---|---|---|
| `T32SidebarIdentifiersTests` + `T33ChannelSidebarStubTests` (11 tests, stubs 8119–8122) | **11 run / 0 failed** — 3 times (before the change 167.2 s, after 152.2 s, final 153.1 s) | — (same suites, same stubs, at `b741a18`: 11/0 in 167.2 s) |
| the 8-test measurement batch | **8 run / 1 skipped / 0 failed** (164.7 s) | 8 / 1 / 0 (169.0 s, T8e) |
| `MattermostTests` (units) | **1725 run / 8 skipped / 0 failed** | 1725 / 8 / 0 (T8e) |
| `T33ChannelSidebarUITests` (live, 347-channel fixture) | **8 run / 2 skipped / 4 failed** (629.6 s) | **8 / 2 / 6 failed** (508.6 s, `2d2b903`, `build/logs/t8e/base-t33.log`) |

**The live suite is not worse than base — it is one test better, and it is still the app-loss
class.** Base's six failures include
`testTheSidebarRendersTheServersChannelsAndCategories` ("Application com.mattermost.ios is not
running", `:536`); on this branch that test **passes** (and its own `t33-01` screenshot is the one
quoted in §4). The four that still fail are the same four assertions on both trees — the line numbers
moved by the 7–9 lines `revealRow`'s own edit added — with the same messages:

```
:862 testALayoutChangeFromAnotherClientReachesTheOpenListWithoutARelaunch  Failed to application … is not running
:859 testAReorderThroughTheContextMenuWritesTheServerAndSurvivesRelaunch  Lost connection to the application (pid 77779)
     testUnreadAndMentionBoldStateMovesLiveAfterAnotherUsersPost          Lost connection … / XCTAssertTrue failed
     testAReadFromAnotherClientOfTheSameUserClearsTheRow                  XCTAssertTrue failed - the post must badge the row …
```

The signature is present in this run's simulator log, three times, and in a fresh crash report:

```
2026-10-28 07:39:07  Mattermost[75635]: QUARANTINED DUE TO HIGH LOGGING VOLUME
2026-10-28 07:41:06  Mattermost[77779]: QUARANTINED DUE TO HIGH LOGGING VOLUME
2026-10-28 07:46:25  Mattermost[80256]: QUARANTINED DUE TO HIGH LOGGING VOLUME
~/Library/Logs/DiagnosticReports/Mattermost-2026-10-28-073913.ips
```

So the suite that swipes a 347-channel list still crosses the firehose threshold on both trees; this
card's −21 % per snapshot is not enough to change its fate, and the card never claimed it would.
`testLoadingOlderPostsDoesNotMoveTheAnchoredPost` (T34, red on base too) was not re-run.

---

## 6. Not claimed / open

* **Not claimed:** that the app-loss class is gone, or that a whole-suite (121 UI test) run is
  faster. One 8-test batch and four suites were run.
* **Sticky headers are not lost** (§4.2) — **retracted** by T8g: they pin (y = 166.3, unmoved over
  498.4 pt of scroll), and upstream does not pin them at all. `docs/t8g-sticky-header-decision.md`.
* **Real-device VoiceOver is unmeasured** (no device; the simulator has none). The claim here is
  about the serialised tree and its byte cost, not about how it sounds.
* **The realised window is larger** (26–36 rows vs 7–21). That is why the per-tree *median* rose even
  as the per-query bytes fell; if a future card wants a smaller realised window, that is a
  `LazyVStack` tuning question, not this one.
* **`post.<id>` is untouched** (T8e §2.4): the post list's `.contain` container and its twelve
  descendant identifiers are exactly as they were. `grep` on `ChannelView.swift` in this diff: no
  post-row change at all.
* **The tab bar's two symbol-labelled images remain** (T8e §3.4) — still shell chrome, still not this
  card.
