# T8e — the drawn shell's accessibility tree: what one row may be, and where the log volume actually is

Card `t_ce08486d` (follow-up to T8d, `t_8d033037`, `docs/t8d-build-note.md`). Branch `wt/t_ce08486d`,
based on `2d2b903`. Host `MacBook-Pro-6.local`, Xcode 26.6 (17F113), sim `81A7F251` (iPhone 16 Pro,
iOS 18.3.1), fixture server `127.0.0.1:8065` (`perfprobe`, seeded by `scripts/perf_seed.py`).

This note answers the card's two questions — **which identifiers the suites may rely on** and
**whether combining rows gets the tree under 120 elements** — with measurements from two runs of the
same batch, then records the two things the card said not to "fix".

---

## 0. Verdicts, up front

1. **Each row is now one VoiceOver stop** — channel rows, category headers and team-rail icons.
   Measured on the drawn shell: **232 → 197 elements per snapshot (−15.1 %)**, per-row cost **9 → 7**,
   and **zero** `Image` elements whose label is an SF Symbol name are left on the pane / sidebar /
   composer / search paths (they were 1 815 appearances per batch).
2. **The card's "well under 120" is not reachable by combining rows, and the reason is measured**:
   6 of the 7 elements a channel row still costs are SwiftUI `List` scaffolding (`Cell` + five
   anonymous `Other`), not row content. The team rail — same app, same snapshot, built with
   `ScrollView` + `VStack` instead of `List` — costs **1** element per row. Removing the `List` is a
   different change with a suite-visible cost (§4), so it is filed, not done here.
3. **Post rows must not be combined**, and the card's premise for them is rejected: five suites
   assert twelve descendant identifiers inside a post row (§2.4). Combining would delete
   `post.<id>.attachment.<fileID>`, `.reaction.<emoji>`, `.replyCount`, `.menu`, `.showMore`,
   `.foldSummary`, `.body.block<N>`, … and would hide the attachment and reaction controls from
   VoiceOver. The post row keeps `.contain`.
4. **The batch's total log volume moves only −3.8 % (52.5 → 50.5 MB)** even though the tree is 15 %
   smaller: 7.5 MB of the remaining volume is XCTest's own `NotificationShortLookView` poll, which is
   not ours, and most queries this batch makes are not snapshots of the drawn shell (§3.3).

---

## 1. Method (re-runnable)

Both runs are the T8d batch — the same 8 tests, same device, same derived data, same command — so the
numbers are an A/B of the tree change alone:

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<fixtures, scripts/perf_seed.py> \
python3 scripts/qa-test.py --platform ios --sim id=81A7F251-8B31-4945-8783-5A264C14B8D5 \
  --derived-data ~/Library/Developer/Xcode/DerivedData/mmios-t8d --log-dir build/logs/t_ce08486d \
  --label a11y-base --timeout 2400 \
  --only-testing MattermostUITests/T95ShellLayoutUITests \
  --only-testing MattermostUITests/T39JumpUITests \
  --only-testing MattermostUITests/T39SearchUITests \
  -- -clonedSourcePackagesDirPath ~/Library/Developer/Xcode/DerivedData/mmios-t95b/SourcePackages
```

The app log for the run window, then four readers (copied into `build/logs/t8e/` so this note's
commands work from the main tree; the same scripts are the T8d set):

```
xcrun simctl spawn 81A7F251-8B31-4945-8783-5A264C14B8D5 log show \
  --start '2026-10-28 05:59:05' --end '2026-10-28 06:03:10' \
  --predicate 'process == "Mattermost"' --info --debug --style syslog > base-app.log

python3 build/logs/t8e/vol.py      base-app.log   # bytes by subsystem (xctest share)
python3 build/logs/t8e/qbypred.py  base-app.log   # MB per query shape
python3 build/logs/t8e/shapes.py   base-app.log after2-app.log   # elements per snapshot, same screen
python3 build/logs/t8e/glyphparents.py base-app.log              # SF-Symbol-labelled Images + parents
python3 build/logs/t8e/rowpid.py   base-app.log   # what each row kind costs, per app launch
```

`elemcost.py`, `rowcensus.py`, `glyphchain.py`, `tree_show.py`, `census.py` are the other readers.
The serialised trees are XCTest's own dumps inside the app's stdout/stderr record; a "tree" below is
one such dump, i.e. **one accessibility snapshot**.

---

## 2. Decision D1 — identifier semantics: an identifier is a contract on the element, not on its children

### 2.1 The rule

> A row identifier (`channelSidebar.channel.<id>`, `teamSidebar.team.<id>`,
> `channelSidebar.category.<slug>`) guarantees: **the identifier resolves to exactly one element, on
> that element's type/tappability, on its label and value strings, and on its frame.** It does **not**
> promise that the row has children, and no test may assert a descendant of a row whose content is
> presentation only.

A row may be collapsed to one element iff (a) no suite addresses a descendant of it, and (b) its label
and value are set explicitly on the row, not derived from the merged children. Where a decoration used
to carry information (the mute marker on a category header), the fact moves into the row's `value`,
which is what VoiceOver reads after the label.

### 2.2 What the mechanism actually is (measured, because the obvious one does not work)

| attempted on a channel row | result in the serialised tree |
|---|---|
| nothing (today) | `Cell → Other×5 → Button → Image('number') + StaticText` — 9 elements |
| `.accessibilityHidden(true)` on the glyph (already shipped since T33) | **no effect**: 1 488 `Image('number')` appearances per batch |
| `.accessibilityElement(children: .ignore)` on the `Button` | **wraps, does not replace**: `Other(id, label) → Button` — the Image/Text go, but one element stays under a new wrapper and the row's element type changes from `Button` to `Other` (a typed `app.buttons[...]` query would stop matching) |
| `.accessibilityElement(children: .combine)` on a container (the shipped idiom) | **does not remove children**: `StaticText(sidebarCurrentTeam)` still carried `Image('person.3')`; `channelSidebar.totals` still carried `Image('bell.badge')` |
| **`.accessibilityRepresentation { Button(label, action:) … }`** | **replaces the subtree**: the row is exactly one `Button` with the identifier, the label and the value — 1 element |

So the idiom this repo used for "one element" (`.combine`) and the idiom for decorative glyphs
(`.accessibilityHidden(true)`) both left elements behind, and that is why the T8d glyph sweep did not
move the tree. The working idiom is `.accessibilityRepresentation`, and it is now used on every row
this card owns.

### 2.3 The signed contract, row kind by row kind

| row | identifier | what the suites assert (all still true) | element after |
|---|---|---|---|
| channel row | `channelSidebar.channel.<id>` | existence; `.label` == display name (`T33-ChannelSidebarStubTests:58-59`, `T33-ChannelSidebarUITests:116-119`); `.value` carries mentions/unread/Muted (`T33-ChannelSidebarUITests:190,201,211,217,264-268`, `T33-ChannelSidebarStubTests:65,71-79`); tap opens the channel (`T34-ChannelPostListUITests:630`); frame order (`T33-ChannelSidebarUITests:757`); `identifier BEGINSWITH` (`T31WebSessionHarvestUITests:104`) | `Button`, 1 element, `.isSelected` trait kept |
| category header | `channelSidebar.category.<slug>` | existence (`T33-ChannelSidebarUITests:105,451`, `T33-ChannelSidebarStubTests:49-51`); tap collapses/expands (`:440`) | `Button`, label = category name, `value` = "Muted" when muted |
| team-rail row | `teamSidebar.team.<id>` | existence + `.label` == display name (`MattermostUITests:1277-1328`); tap switches team | `Button`, `.isSelected` trait kept |
| sidebar totals | `channelSidebar.totals` | `.label` == `"2 mentions, 3 unread messages"` / `"All caught up"` (`T33-ChannelSidebarStubTests:86`, `T33-ChannelSidebarUITests:272,291,302`) | `StaticText`, 1 element; the stale warning is appended to the sentence instead of living on a separate marker element |
| current team | `sidebarCurrentTeam` | `.label` == display name (`T32-SidebarIdentifiersTests:60,164`) | `StaticText`, 1 element |
| **post row** | `post.<id>` | **twelve descendant ids** — see 2.4 | `Other` container (`.contain`, unchanged) |

**Nothing was renamed, nothing was re-typed, and no label assertion moved.** The only label that
changed ownership is the category header's: it used to be derived from its `Text` child and is now set
explicitly (same string), and no suite reads it.

### 2.4 Why a post row is not combined — the ids that would die

Source: `PostRowView.swift`, `AttachmentViews.swift`, `ReactionBarView`, `MarkdownView.swift`; asserted
by T34, T35, T36, T37, T38:

```
post.<id>                post.<id>.author        post.<id>.avatar       post.<id>.body.block<N>
post.<id>.edited         post.<id>.system        post.<id>.deleted      post.<id>.pinned
post.<id>.menu           post.<id>.replyCount    post.<id>.showMore     post.<id>.foldSummary
post.<id>.pending        post.<id>.attachments   post.<id>.attachment.<fileID>[.download|.saved|.progress]
post.<id>.reaction.<emoji>                       post.<id>.addReaction
```

`post.<id>` itself is an `Other` container with `.accessibilityElement(children: .contain)` — a
VoiceOver group, not a stop, which is what a post should be. The decorative elements *inside* it are
handled separately: the thread chevron and the avatar image are already hidden (measured: `person.fill`
does not appear in the tree at all), and the pane header's glyph — the one that did leak — is fixed in
this card (`ChannelPaneTitle`).

---

## 3. What was changed, and the measured before/after

### 3.1 The changes

| file | change | why |
|---|---|---|
| `Sidebar/ChannelSidebarView.swift` | channel row, category header, both Threads rows, `channelSidebar.totals` → `.accessibilityRepresentation` | one row = one element; the `#`/badge/chevron/bell glyphs leave the tree |
| `Sidebar/TeamSidebarView.swift` | `TeamIconButton` → representation | initials/uploaded icon + badge leave the tree |
| `NativePanePlaceholders.swift` | `NativeSidebarAnchorRow`, `sidebarCurrentTeam`, `nativeSidebarSelectedChannel` → representation | 131 `server.rack` + 131 `person.3` + the pane's `#` glyph |
| `Channel/ChannelView.swift` | `ChannelPaneTitle` → representation | the pane header's `#` glyph (3 appearances) |
| `Search/SearchView.swift`, `Search/SavedPinnedViews.swift` | warning banner, saved-row channel line → representation | `exclamationmark.magnifyingglass`, `bookmark`-row `#` |
| `Auth/LoginView.swift` | SSO button → representation | `person.badge.key` (49) — the login screen every run passes through |
| `ChannelSidebarView.swift` (workspace section) | second `sidebarCurrentTeam` (`person.3`) → representation | the drawer's own copy of the row; there were two |

### 3.2 Elements per snapshot, same screen

From `shapes.py`: the dominant drawn-shell shape in both logs (the drawer with 11 channel rows):

| | trees | elements per snapshot | per channel row |
|---|---|---|---|
| before (`2d2b903`) | 133 | **232** | 9.0 |
| after (`wt/t_ce08486d`) | 140 | **197** | 7.0 |

−35 elements (−15.1 %). Largest tree over the whole batch 243 → 234, mean over all trees 135.4 → 121.8
(−10 %). The other shapes move the same way (a channel pane with a post list: 101 → 99).

Ruby-ish arithmetic, for the record: 11 rows × 2 elements saved = 22, plus 3 category headers × 2, plus
the rail's 3 icons × 1–2, plus the totals row × 2, plus the two pane-header rows.

### 3.3 MB, and what it does not prove

| | before | after | Δ |
|---|---|---|---|
| batch wall time | 173.9 s | 169.0 s | −2.8 % |
| tests | 8 run / 1 skipped / **0 failed** | 8 run / 1 skipped / **0 failed** | — |
| app log, all pids | 52.5 MB | 50.5 MB | −3.8 % |
| of which `com.apple.dt.xctest` | 34.26 MB (65 %) | 33.13 MB | −3.3 % |
| queries | 364 | 371 | — |
| median bytes per query | 47.8 KB | 41.9 KB | −12.3 % |
| `nativeChannelPane`, typed (×116 / ×123) | 47.4 KB each | 41.5 KB each | −12.5 % |
| one `channelSidebar.channel.<id>` lookup (×6) | 1.03 MB each | 0.92 MB each | −10.7 % |
| XCTest's own `NotificationShortLookView` poll (×65) | 7.6 MB | 7.5 MB | — (not ours) |

**How far to trust it.** Every query that walks a screen containing the sidebar is 10–12 % cheaper,
which is the tree change showing up where it should. The *batch* total moves only 3.8 % because
(a) XCTest's own notification poll is 7.5 MB of it and untouched, and (b) most of the batch's 371
queries are not snapshots of the drawn shell (search, post list, keyboard). Anyone quoting "-15 % log
volume" from this card would be quoting the tree, not the bytes: the tree is −15 %, the bytes are
−3.8 % on this batch, and the bytes are what trips the firehose quarantine.

### 3.4 Zero SF-Symbol-labelled Images on the named paths

`glyphparents.py` on the after log: the only two left in the whole batch are the **tab bar's** own
items — `Image('bubble.left.and.bubble.right.fill')` label `conversation` (151) and
`Image('bookmark.fill')` label `bookmark` (5). Those are `TabView` items in `NativeShellView`
(shell chrome, not a pane/sidebar/composer/search surface) and replacing a `Tab`'s label is a shell
change, so they are recorded here rather than done. Every other symbol-labelled image in the batch is
gone:

| before | after |
|---|---|
| `number` 1 488, `conversation` 142, `server.rack` 131, `person.3` 131, `person.badge.key` 49, `bookmark` 5, `bell.badge` 3, `exclamationmark.magnifyingglass` 2 | `conversation` 151, `bookmark` 5 (tab bar only) |

---

## 4. Decision D2 — the remaining 6 of 7 elements per row are the `List`, and that is a separate card

Measured in **one snapshot** of the drawn shell:

* channel list (`List { Section … }`, `.listStyle(.sidebar)`): per row `Cell` + five anonymous `Other`
  + the row's own element = **7 elements**; 6 of them contain nothing.
* team rail (`ScrollView { VStack { ForEach } }`, same screen, same snapshot): per row **1 element**.

That is the whole remaining lever: ~6 × (rows drawn) elements per snapshot, i.e. the drawn shell would
land near **130** on this screen if the wrappers went, and well under 120 on a 19-row list (which is
what the largest baseline tree is: 243 elements, 19 rows).

It is **not** done in this card, for reasons the swap has to answer first:

1. `T33-ChannelSidebarUITests.revealRow` scrolls `element(app, "nativeTeamSidebar").collectionViews
   .firstMatch` — that `CollectionView` **is** the `List`. A `ScrollView`+`LazyVStack` swap makes that
   helper find nothing and the "channel beyond the fold" tests (11 categories / 347 channels on this
   fixture) stop revealing rows. The suite must change with the view, so it needs T33's owner.
2. `List` here also provides the iOS sidebar's platform behaviours: separators, sticky section headers
   on the regular/iPad layout, `.listStyle(.sidebar)` selection. Losing them is a visual/parity change,
   not an accessibility one, and `docs/parity.md` has no row that would call it a defect.
3. The post list already does the right thing (it is a `ScrollView` + lazy stack: post rows cost 1
   element of wrapper), so the precedent exists in this app — this is about the sidebar, not the idiom.

Filed as a card against T33, with the numbers above, rather than smuggled into a crash card.

---

## 5. Decision D3 — the `Menu` automation-type mismatch is **known, not a defect, and not to be "fixed"**

370 occurrences per batch of exactly one runtime issue:

```
Automation type mismatch; legacy system derived element type 9 from class
SwiftUI.AccessibilityNode:UIResponder, traits 1108101562369, but AXAutomationType returned 14
```

* type 9 = `button`, type 14 = `popUpButton`: it is XCTest's **legacy** element-type derivation
  disagreeing with SwiftUI about a `Menu`, logged at **Default** level — 0.1 MB of a 79.5 MB batch
  (T8d's measurement), i.e. 0.1 %.
* **not a VoiceOver defect**: VoiceOver reads a menu as a menu; nothing in the tree is wrong.
* the app has **three** real `Menu { }` views (`UI/DownloadsView.swift:146`,
  `UI/Native/Composer/ComposerView.swift:304` on the composer path, `UI/RootView.swift:387`). T8d's
  note says five; `grep -rn "Menu {" Mattermost/` also matches `.contextMenu {` and
  `enum ChannelCreateMenu`, which are not menus. The count is corrected here; the conclusion is not.
* **no action.** Replacing them with non-menu controls would be a UX change made to satisfy the test
  harness, and VoiceOver would lose the "menu" affordance. Recorded so it is not rediscovered as a
  bug for the third time.

---

## 6. What else was run, and what it says

| run | branch `wt/t_ce08486d` | base `2d2b903` |
|---|---|---|
| the 8-test measurement batch (T95ShellLayout + T39Jump + T39Search) | 8 run / 1 skipped / **0 failed** (169.0 s) — twice | 8 run / 1 skipped / 0 failed (173.9 s) |
| `T42ActivityUITests` | 4 / 4 passed | — |
| `T32SidebarIdentifiersTests` | passed (the `sidebarCurrentTeam` labels) | — |
| `T33ChannelSidebarStubTests` | passed (row `.label` and `.value` strings) | — |
| `T33ChannelSidebarUITests` (live, 347-channel fixture) | 8 executed / 2 skipped / **6 failed** (637 s) | 8 executed / 2 skipped / **6 failed** (508 s) |
| `T34ChannelPostListUITests/testLoadingOlderPostsDoesNotMoveTheAnchoredPost` | failed alone (164 s) | failed (78 s, after the same cascade) |
| `MattermostTests` (units) | **1725 run, 8 skipped, 0 failed** | — |

**The T33 live failures are pre-existing and are the app-loss class, not this change.** Both trees
fail the *same* tests at the *same* lines with the same messages — `T33-ChannelSidebarUITests.swift:855
… com.mattermost.ios is not running`, `:850/:110 … Lost connection to the application`, and the
`row.value` assertions that follow a relaunch. The simulator's log for the branch run has the signature
itself: pid 37340 `QUARANTINED DUE TO HIGH LOGGING VOLUME` at 06:32:05.858, `exited due to SIGSEGV`
1.4 ms later (the T8d class, `docs/t8d-build-note.md` §1). That suite swipes a 347-channel list, so it
is the heaviest thing in the repo and crosses the threshold on both trees; the 10–12 % per-query cut
this card makes is not enough to change its fate, and this card never claimed it would.
`testLoadingOlderPosts…` (the load-earlier seam did not merge a second page in this fixture state) is
red on the base commit too.

### Not claimed / open

* **Not claimed:** that the quarantine class is gone. This card moves the tree, not XCTest's own
  poll; a whole-suite run (121 UI tests) was not repeated. The remaining per-snapshot cost is the
  `List` scaffolding (§4).
* **Tab bar**'s two symbol-labelled images remain (§3.4) — a `Tab` label change is shell work.
* **VoiceOver on a real device** is still unmeasured (T8d §3): the simulator has no VoiceOver, and
  the crash path needs `XCTAutomationSupport`, so nothing here is evidence about real-device VoiceOver
  behaviour beyond "fewer, better-named elements".
* **`post.<id>` is a container, not a stop** — if a future card wants the row to be one stop it has to
  delete twelve identifiers and five suites' assertions first (§2.4), which is a product decision, not
  an accessibility tweak.

## Artifacts (gitignored)

`build/logs/t8e/` (in the main tree, so they survive this worktree): `a11y-base.log`, `base-app.log`
(52.5 MB), `a11y-after2.log`, `after2-app.log` (50.5 MB), `a11y-validate2.log` (the affected suites
re-run), `base-t33.log` (the same suites on the base commit, the control), `probe-app.log` /
`probe2-app.log` (the two mechanism probes: `.ignore` and `.accessibilityRepresentation`), and the
readers named in §1.
