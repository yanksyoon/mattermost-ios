# C2 adversarial validation — the profile popover on search, saved/pinned and mentions (`7f38b14`)

Card: `t_0c520c78`. Subject: C2 of `t_8f9f5449`, built on `t_2fa3bbe1` (commits `8c96531` + `adc9a59`,
merged as `7f38b14`). Spec of record: `docs/t_8f9f5449-profile-popover-parity.md`. Build note under
audit: `docs/t_8f9f5449-c2-build-note.md`.

**Verdict: PASS-WITH-FINDINGS.** Every claim re-derived from the artifact reproduces, with one exception
of substance (F1: the row restructure — C2's headline justification — is *not* shown to be load-bearing;
the same live test passes with the pre-C2 `Button` container restored) and four evidence/coverage
defects of lower severity (F2–F5). No product defect was found in what C2 actually ships.

---

## 0. What was audited, and where

| fact | measured value |
|---|---|
| `git ls-remote origin refs/heads/main` (at audit start, 11:15 EDT) | `679b05fbb5ad2a86905e6fbd8f19111395e615aa` |
| is `7f38b14` reachable from the remote? | **yes** — `git merge-base --is-ancestor 7f38b14 origin/main` exits 0 (at audit start the remote head was C3's docs commit, two commits above C2) |
| the commit audited | `7f38b145115785ce725248656c252a9b193b1af9` ("Merge branch 't_2fa3bbe1'"), checked out **detached** in a separate worktree |
| diff scope vs the merge's first parent | 10 files, **1410 insertions, 96 deletions** — matches the card's own figure |
| tree state during every run | `git diff --stat 7f38b14` empty before the pristine runs and after every mutation was reverted (each mutation re-applied and reverted by explicit `git checkout --`) |

The remote moved again while this validation ran: at 12:05 EDT `refs/heads/main` is
`79e1c9d908a00ca912953fe2b6dc3ae286a22db3` (T7ffa: `a57fe67` + two docs commits) and `7f38b14` is still
an ancestor of it, so the audited commit remains on the remote's history. Nothing in this note was
measured on a tree newer than `7f38b14`.

**Finding #0 does not apply**: the commit under audit is on the remote's history. Note for the record:
at audit start local `main` in the shared checkout was `679b05f`, and C3 (`d1b6c92`, `e59e11a`) edits
the same `Profile*` files, so auditing "main" would audit a different tree. The detached worktree at
`7f38b14` is what every number below was measured on.

Environment: iPhone 17 Pro simulator (iOS 26.5, `id=6B6991BF-6816-44EE-8FEA-284712F6ECBB`), real
Mattermost 9.11.19 at `127.0.0.1:8065` (`perfprobe` + `t41buddy`), derived data
`~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa-t5449c2`, runner `scripts/qa-test.py`
(exit-code and stall guard). Host load during the runs was 8–15 (other board work); the pinned test's
33.5 s matches the build note's 33.4 s from a quiet host, so the load did not visibly distort these
runs.

Worktree audited:
`/Users/yangsooyoon/Documents/yanks/code/mattermost-ios/.worktrees/t_0c520c78/.worktrees/t_0c520c78-c2audit`
(log names below are relative to its `build/logs/`).

---

## 1. Claim 4 — the runs, re-derived (not taken from the summary)

Every count below is the runner's own `Executed N tests` line from that run's log.

| run | command (abridged) | runner's own counts | log |
|---|---|---|---|
| live (the four new tests) | `--only-testing MattermostUITests/T5449ListProfileUITests` | **4 run, 0 failed, 0 skipped**, 108.003 s, `** TEST SUCCEEDED **` | `t0c520c78-live-pristine.log` |
| regression 1 | `T39SearchUITests T42ActivityUITests T70AuthorNamesUITests T5449ThreadProfileUITests` | **10 run, 0 failed, 0 skipped**, 300.955 s (T39 4/151.242 s, T42 4/69.732 s, T5449-C1 thread 1/30.187 s, T70 1/49.793 s) | `t0c520c78-regress1.log` |
| units | `--only-testing MattermostTests` | **1796 run, 8 skipped, 0 failed**, 39.209 s | `t0c520c78-units.log` |
| regression 2 | `T429ProfileTapUITests T41ProfileUITests` | **11 run, 0 failed, 0 skipped**, 614.636 s (T429 4/99.190 s, T41 7/515 s), `** TEST SUCCEEDED **` | `t0c520c78-regress2.log` |
| dual-render gates | `bash scripts/verify-dual-render-gates.sh --allow-approved-registry` | **PASS** — `RESULT: PASS — dual-render debug affordances cannot reach a Release build.` (213 object ids defined exactly once; 130 + 105 + 31 git-tracked files in the three synchronized trees, "none of the 264 source file(s) … has a hand-written project-file entry" — 264 is the gate's basename set, two names recur across trees) | `t0c520c78-gates.log`, transcript in §6 |

All four of claim 4's numbers reproduce exactly (1796/8/0 units, 4/0/0 live, 10/0/0 and 11/0/0
regressions) — the one that needed re-running on this host was the live suite, and it is green.

Per-test timings from the pristine live run: mention 23.999 s, pinned 33.457 s, saved 20.318 s,
search 30.230 s.

---

## 2. Mutation test 1 — the three hosts' presentation calls (the F1-class vacuity check)

Each mutation was applied to the pristine tree, the tree rebuilt (the log shows `SwiftCompile …
<file>.swift` and a fresh `Ld … Mattermost.app/Mattermost` in the same run), the targeted live test(s)
run, then the file reverted with `git checkout --` and the tree re-verified against `7f38b14`.

| id | mutation (the pre-C2 shape) | expected | **measured** | log |
|---|---|---|---|---|
| **M1** | `SearchView.swift`: `.profilePresentationHost(…)` deleted, so the author tap writes `ProfilePopoverState` and nothing presents it | search red | **red** — `:118 a result's author tap must open the profile from this host`, `:121 the profile must mount`; 1 run / 3 failures | `t0c520c78-m1-search-nohelper.log` |
| **M2** | `SavedPinnedViews.swift` (`PostCollectionView`): helper deleted | saved red **and** pinned red | **red both** — saved `:157 a saved post's author tap must open the profile`; pinned `:222 a profile opened from inside the pinned sheet must be pushed on that sheet's own stack`; 2 run / 6 failures | `t0c520c78-m2-collection-nohelper.log` |
| **M3** | `MentionsView.swift` (`ActivityFeedView`): helper deleted | mention red | **red** — `:185 a mention's author tap must open the profile`; 1 run / 3 failures | `t0c520c78-m3-mentions-nohelper.log` |

Verdict on this class: **none of the three hosts' tests is vacuous.** Removing the helper reds the
test that covers that host, at the assertion that names the host, and nothing else is needed to make it
fail. This is the defect C1 shipped (a test that passed with the fix removed); C2 does not repeat it.

---

## 3. The no-nested-sheet claim — structure, and the mutation that proves the assertion bites

The pinned test asserts, in this order (`MattermostUITests/T5449ListProfileUITests.swift:214–231`):

1. `profilePush` exists (`:222`) — the pushed form's own identifier, which a sheet cannot carry;
2. `profile.username` exists and equals `"@" + GET /users/{authorID}.username` (`:226`, `:228`);
3. **`profileSheet` is absent** (`:230`) — "no nested sheet";
4. the push is popped with `BackButton` and the pinned list comes back (`:238`, `:242`) while
   `profilePush` goes away (`:246`).

That is the assertion the card asks for: `profileSheet` absence plus `profile.username` presence.

**M4 — the mutation that makes it fail for the right reason.** Delete
`.environment(\.profilePresentation, .push)` from `PinnedPostsView` (leaving the helper in place) and the
pinned sheet presents a profile *inside* the pinned sheet:

```
:222 XCTAssertTrue failed - a profile opened from inside the pinned sheet must be pushed on that sheet's own stack
:230 XCTAssertFalse failed - no nested sheet: T40 measured a sheet inside a sheet whose confirmation never ran
Executed 1 test, with 2 failures — log t0c520c78-m4-pinned-sheet-fallback.log
```

Two things this measures, and they matter for how the test should be read:

* the structural assertion (`profileSheet` absent) is the one that catches the nested sheet; the
  *behavioural* one does not — `profile.username` **passed** in the nested sheet, because a nested
  `ProfileSheet` mounts and reads the profile normally on iOS 26.5. The T40 hazard is the sheet's
  *confirmation action* never running, not its mounting, so a test that only checked "the profile
  appeared" would call a nested sheet a pass. The build note's choice of identifier-absence over a
  screenshot description is therefore load-bearing, measured;
* the positive `profilePush` assertion fires first, so the test also cannot pass by presenting a sheet.

---

## 4. The affordance claim — the row is not a control, the author is, and what the test actually checks

Source (all three hosts): the row container is a plain `VStack` + `.contentShape(Rectangle())` +
`.onTapGesture` + `.accessibilityAddTraits(.isButton)` + `.accessibilityElement(children: .combine)` +
the explicit label + `Open profile`; identifiers unchanged (`searchResult.<id>`, `activity.row.<id>`,
`savedPosts.row.<id>`, `pinnedPosts.row.<id>`); `PostRowView` draws the avatar and the name as real
`Button`s whenever `onShowProfile` is non-nil (`Mattermost/UI/Native/Channel/PostRowView.swift:288–300`,
`353–365` — the second range's `else` branch is the inert `Text` form M7 measures).

Measured element type in the pristine run — the author tap target is a **Button** in all four hosts
(the runner names the resolved element type when it taps):

```
Find the "post.tat1cuggptropxy4nf5cw3y8ro.avatar" Button   (mentions)
Find the "post.q5p5ofs7gfyjufws8fkk1h9a8c.avatar" Button   (pinned)
Find the "post.tdmkjx6ottn1xn7qa8kmruqunc.avatar" Button   (saved)
Find the "post.qt3a5ukfn7foierzcp8yhowdtw.avatar" Button   (search)
                                              — t0c520c78-live-pristine.log:3703, 3834, 3941, 4054
```

**M7 — does the affordance assertion fail on the inert shape?** Set `onShowProfile: nil` in
`SearchView` (the pre-C1 shape: the author is a plain `Text`, and the avatar has no identifier at all):

```
t = 22.55s Checking existence of `"post.<id>.avatar" Any`          ← absent, falls back to the name
t = 23.73s Find the "post.<id>.author" StaticText                  ← resolves, but as inert text
t = 23.83s Tap  "post.<id>.author" StaticText
:118 XCTAssertTrue failed - a result's author tap must open the profile from this host
                                              — t0c520c78-m7-search-inert-author.log
```

The suite does go red on the inert shape, so it is **not** C1's F1 (a test that passes on an inert
`Text`). But it reds at the *presentation* assertion, not at the affordance assertion
(`tapAuthorHeader`'s "the row must draw the author's own button"), because that assertion only checks
existence — `element(_:_:)` searches `descendants(matching: .any)`. See F2.

---

## 5. Findings

### F1 — (medium) the `Button` → gesture restructure is not shown to be load-bearing; the live suite cannot distinguish the pre-C2 row shape from the shipped one

**What the claim is.** Build note §2 and spec §3 state the causal chain: the three hosts wrapped
`PostRowView` in a `Button`, a `Button` inside a `Button`'s label "is not a reliable tap target in
SwiftUI", so the author tap "either never fired or fired the row's jump", and the restructure is what
makes it fire. The card asks whether the tests are vacuous with the fix removed.

**What was measured.** M5 restores the pre-C2 container in the search host — the whole row wrapped in
`Button(action: onOpen) { … }` with `.buttonStyle(.plain)`, the shipped `onShowProfile` callback kept —
and the shipped test **passes**:

```
SwiftCompile normal arm64 …/SearchView.swift (in target 'Mattermost')      ← the mutation is compiled
Ld …/Mattermost.app/Mattermost                                            ← and linked
Test Case '…testTheAuthorOfASearchResultOpensTheirProfile' passed (32.322 seconds)
Executed 1 test, with 0 failures — ** TEST SUCCEEDED **
                                              — t0c520c78-m5-search-button-row.log
```

The inner author `Button` stayed addressable inside the wrapping `Button` and **its own action ran**
(the sheet opened with `@t41buddy`, read from the server — the assertion that would have failed had the
tap been swallowed and the row's jump taken instead). So on this runtime a `Button`-inside-a-`Button`
label is a reliable tap target, and the restructure is not what makes the tap fire here.

**Consequence.** The justification for claim 3 is a hypothesis from the spec, not a measurement, and no
shipped test pins it: a change that re-wrapped these rows in a `Button` tomorrow would keep the suite
green. Two honest resolutions, and this card takes neither: measure the claimed failure on a real
device / under VoiceOver (where "not reliable" most plausibly bites), or restate the restructure as
hardening rather than a fix in the build note and spec §3.

**Scope of the measurement, stated so it is not over-read:** one simulator (iPhone 17 Pro, iOS 26.5),
compact layout, List-hosted rows, no VoiceOver, no device. The saved and mentions hosts were not
mutated this way (the saved row also carries a sibling `savedPosts.remove.<id>` `Button` and a channel
line, so its pre-C2 tree is not the same shape); only the search host's M5 result is measured.

**Reproduction.** Worktree at `7f38b14`; in `SearchResultRowView.body` wrap the `VStack` in
`Button(action: onOpen) { … }.buttonStyle(.plain)` and drop `.onTapGesture { onOpen() }`; run
`--only-testing MattermostUITests/T5449ListProfileUITests/testTheAuthorOfASearchResultOpensTheirProfile`.

### F2 — (low) `tapAuthorHeader`'s affordance assertion is type-blind: an inert `Text` passes it

`tapAuthorHeader` asserts `header.waitForExistence` with the message "the row must draw the author's
own button", but it resolves the element with `descendants(matching: .any)`. M7 measured a `StaticText`
satisfying that assertion (`t0c520c78-m7-search-inert-author.log:320–329` — `Find the
"post.<id>.author" StaticText`), after which the run failed at the presentation assertion. The suite
still bites; the *diagnosis* does not. One line fixes it:

```swift
XCTAssertEqual(header.elementType, .button,
               "the author must be a control, not inert text: \(header.debugDescription)")
```

Reproduction: set `onShowProfile: nil` at `SearchView.swift:330`, run the search test, read which
assertion fails.

### F3 — (low, docs) the shipped test file still states the claim §6.2/§6.3 of the build note retracted

`MattermostUITests/T5449ListProfileUITests.swift:11–15` says, in the present tense:

```
* **The tap is a coordinate, not an element.** … under `.accessibilityElement(children: .combine)`
  the inner `post.<id>.author` button is *not* addressable — the test taps the row at a point inside
  the author header and asserts `post.<id>.author` is absent first …
```

The code does the opposite (element tap on `post.<id>.avatar`, no absence assertion), and the build note
§6.2/§6.3 record that the claim was refuted by the first live run. The `tapAuthorHeader` doc comment
(≈l. 470) was corrected; the file header was not. A reader trusting the header will "restore" the
coordinate tap that §6.3 measured to open the post instead of the profile. Documentation defect only.

### F4 — (low, coverage) half of claim 2's push site is source-only

Claim 2 names two push containers: `PinnedPostsView` and `NativeShellView`'s regular-layout
`lookupSheet`. The pinned half is measured (pristine green, M4 red). The `NativeShellView` half has no
test at all: all four live tests reach their panes through `ShellSettle.tapTab` on an iPhone (compact
layout), and no suite opens a profile from inside the lookup sheet. `grep -rn "profilePresentation,
.push" Mattermost/UI/Native/NativeShellView.swift` is the only evidence for that line. An iPad /
regular-layout live test that opens search → author → `profilePush` would close it. Related, same gap:
the `Open profile` accessibility action (present in all three hosts) is not exercised by any test —
XCUITest cannot invoke a custom accessibility action, so that part of claim 3 is source-only by
construction and is stated here rather than counted as verified.

### F5 — (nit) three small inconsistencies

* `MattermostUITests/T5449ListProfileUITests.swift:244` contains `\\n` in a Swift string, so the failure
  message prints a literal `\n`.
* The build note §5 says the gate reported "261 synchronized sources"; at `7f38b14` the gate prints
  `130 + 105 + 31` git-tracked files and `264 source file(s)` for its basename set
  (`t0c520c78-gates.log`). The verdict is identical (PASS); the count is stale, consistent with the
  gate having been run on the card branch before the merge brought main's files in.
* The build note §2 says the avatar and the name "stay the only real `Button`s", which is true of the
  search and mentions rows but not of the saved/pinned row, which also carries
  `savedPosts.remove.<id>` (pre-existing) and a `channel` element.

---

## 6. Dual-render gates (verbatim verdict)

```
== 6. pane ownership is a subset of the -AV approval registry ==
  ok    paneOwningSurfaces ['channelView'] is a subset of nativeApprovedSurfaces […]
== 7. the release-policy bypass (allowUnapproved: true) compiles only in a debug region ==
  ok    all 1 call site(s) passing allowUnapproved: true are inside a debug region
== 8. the native UI tree is still a synchronized folder (T30b) ==
  ok    Mattermost/UI/Native: 130 git-tracked file(s)
  ok    MattermostTests: 105 git-tracked file(s)
  ok    MattermostUITests: 31 git-tracked file(s)
  ok    none of the 264 source file(s) in the synchronized trees has a hand-written project-file entry
== 9. project.pbxproj defines every object id exactly once ==
  ok    all 213 object ids are defined exactly once (213 definitions)
== 10. this diff adds no PBXFileReference outside the allowance (T30b) ==
  note  no change to Mattermost.xcodeproj/project.pbxproj against 7f38b14 — nothing to audit here

RESULT: PASS — dual-render debug affordances cannot reach a Release build.
```

Gate 10's "nothing to audit" was checked twice and is *not* an artifact of auditing a merge commit:
re-run with `--base 7f38b14^1` (C2's own diff) it still reports "no change to
`Mattermost.xcodeproj/project.pbxproj` against 7f38b14^1", i.e. C2 adds its two new source files
inside the synchronized trees and touches the project file not at all — which is the shape gate 8 and
gate 10 exist to keep. Log: `t0c520c78-gates-base.log` (same PASS verdict).

---

## 7. What is *not* validated here (stated, not hidden)

* No real device, no VoiceOver run. F1's resolution needs one.
* No APNs, and no push path in these surfaces (out of scope for C2).
* Regular/iPad layout: the lookup-sheet push (F4) and the split layout's own three pane destinations
  were not driven. All UI runs here are compact layout.
* `docs/parity.md` rows for T39/T42 were read and do carry the C2 clause (row shape + sheet/push);
  this card did not re-verify the rest of those rows' claims.
* The dual-render gates were run on `7f38b14` only; the `--base main` T30b audit of C2's own diff was
  not run (see §6).

## 8. Logs

All under
`.worktrees/t_0c520c78/.worktrees/t_0c520c78-c2audit/build/logs/` (the audited tree),
and the failure/summary extracts are committed beside this note as
`docs/t0c520c78-c2-evidence.log`:

`t0c520c78-live-pristine.log`, `t0c520c78-regress1.log`, `t0c520c78-regress2.log`,
`t0c520c78-units.log`, `t0c520c78-m1-search-nohelper.log`, `t0c520c78-m2-collection-nohelper.log`,
`t0c520c78-m3-mentions-nohelper.log`, `t0c520c78-m4-pinned-sheet-fallback.log`,
`t0c520c78-m5-search-button-row.log`, `t0c520c78-m7-search-inert-author.log`,
`t0c520c78-gates.log`.
