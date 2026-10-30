# C2 — the profile popover on search / saved+pinned / mentions, and the nested-tap restructure

Card `t_2fa3bbe1` (C2 of `t_8f9f5449`). Spec of record:
`docs/t_8f9f5449-profile-popover-parity.md` §2.2 (presentation legality), §2.3 (the per-host table),
§2.4 (why a list host is not special), §3 (the nested-tap restructure) and §9 (the acceptance table).
Sibling cards: C1 `t_07216319` (thread host + the `rowHost:` rename, merged as `26531b5`), C3
`t_296843e5` (Call and Add to a channel).

Work happened on branch `t_2fa3bbe1` in the worktree `.worktrees/t_2fa3bbe1` (the shared checkout was
in use by another card — see §7).

## 1. What this card changes

| file | change |
|---|---|
| `Mattermost/UI/Native/Profile/ProfilePresentationHost.swift` | **new.** `ProfilePresentation` (`.sheet`/`.push`), the `\.profilePresentation` environment value (default `.sheet`), the one `ProfilePresentationHost` modifier + `.profilePresentationHost(_:server:navigation:)`, and `PushedProfileScreen` (the existing `ProfileScreen` behind the stack's back button, its model resolved through `ProfileCoordinator` in `.task` exactly as `ProfileSheet` does — `profilePush` is its identifier). |
| `Mattermost/UI/Native/Profile/ProfileView.swift` | `ProfileTarget` gains `Hashable` (what `.navigationDestination(item:)` keys on; one line plus its doc comment). Nothing else in this file is touched — C3 is the other card writing here. |
| `Mattermost/UI/Native/Search/SearchView.swift` | `SearchView` reads the resolver, owns one `ProfilePopoverState`, gates the author tap on `resolvedMode(for: .search)` and attaches `.profilePresentationHost`. `SearchResultRowView` **stops being a `Button`**: same `VStack`, `.contentShape(Rectangle())` + `.onTapGesture` + `.isButton` trait, `onShowProfile` passed into `PostRowView`, `.combine` + explicit label kept, `Open profile` accessibility action added. |
| `Mattermost/UI/Native/Search/SavedPinnedViews.swift` | `PostCollectionView` takes `rowHost:` (from `SavedPaneContent`: `resolvedMode(for: .search)`; from `PinnedPostsView`: `.native` as a fact), owns one `ProfilePopoverState`, and its row gets the same restructure + an explicit VoiceOver sentence. `PinnedPostsView` sets `.environment(\.profilePresentation, .push)` on its own `NavigationStack`'s content. |
| `Mattermost/UI/Native/Activity/MentionsView.swift` | `ActivityFeedView` reads the resolver, owns one `ProfilePopoverState`, gates on `resolvedMode(for: .activity)` and attaches the helper; `ActivityRowView` gets the same restructure (`Open profile` added beside the existing mark-read action). |
| `Mattermost/UI/Native/NativeShellView.swift` | the regular layout's `lookupSheet` content sets `.environment(\.profilePresentation, .push)` — one line, inside the sheet's `NavigationStack`; the compact tabs keep the default. |
| `MattermostTests/T5449ProfilePresentationTests.swift` | **new.** Three pins: the environment default is `.sheet`; the push resolves *the target's* account through the coordinator's cache; the destination identity is the account (`Hashable` + the one-slot state machine). |
| `MattermostUITests/T5449ListProfileUITests.swift` | **new.** The four live tests of spec §9 (search, saved, mentions, pinned-as-push), each against `GET /users/{authorID}`. |
| `docs/parity.md` | T39 and T42 rows: the row shape changed (not a `Button`, one combined element, `Open profile` action) and the host clauses (sheet vs push). |
| `docs/t_8f9f5449-c2-build-note.md` | this note. |

## 2. The row restructure, and why it is not a style change

All three list hosts wrapped `PostRowView` in a `Button(action: onOpen)`. With `onShowProfile` wired
that made the author's avatar and name buttons **inside a button's label**, which SwiftUI does not
hit-test reliably: the tap either does nothing or wins for the row and jumps. The fix is the shape
`ReactionBarView` already documents — a plain view with an explicit gesture and the button trait
re-added for VoiceOver:

```swift
VStack { … PostRowView(…, onShowProfile: …) }
    .contentShape(Rectangle())
    .onTapGesture { onOpen() }
    .accessibilityAddTraits(.isButton)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(…)
    .accessibilityAction(named: Text("Open profile")) { … }
```

The avatar and the name stay real `Button`s inside the row, so a tap on them never reaches the row's
gesture — that is what the live tests tap. (On the search and mentions rows they are the *only*
`Button`s; a saved/pinned row also carries its pre-existing `savedPosts.remove.<id>` button and the
`savedPosts.channel.<id>` channel element, both measured in §6.2 — the correction to this sentence in
C2's validation, F5.) Accessibility keeps **one labelled element per
row** (`T8e`: a 60-row list must not become 180 VoiceOver stops) and adds an explicit
`Open profile` action, and each site's comment now records what the first live run measured: the row's
leaves stay **addressable** inside it (`PostRowView` is `.contain`; an outer `.combine` does not
flatten a nested container), so the author is a normal element tap, not a coordinate — see §6.2/§6.3.

Identifiers are unchanged: `searchResult.<postID>`, `activity.row.<postID>`, `savedPosts.row.<postID>`,
`pinnedPosts.row.<postID>`. The saved/pinned row gained an explicit label
(`"<channel>, <author>: <text>"`, `"<author>: <text>"` when the list knows no channel) — it had none
before, and a row without a label reads as its first child only.

## 3. Presentation legality, as built

`ProfilePresentation` lives in the environment, default `.sheet`:

* `NativeShellView`'s regular-layout lookup sheet → `.push` (its `NavigationStack`);
* `PinnedPostsView` → `.push` (its own `NavigationStack`);
* every other host → default `.sheet` (the compact tabs, and both pane destinations).

The helper attaches exactly one modifier, chosen by that value:

```swift
.sheet(item: $state.target) { ProfileSheet(…) }                       // .sheet
.navigationDestination(item: $state.target) { PushedProfileScreen(…) } // .push
```

`.navigationDestination(item:)` needs `Hashable`, hence the one-line `ProfileTarget` conformance (iOS
17 floor is the project's own `IPHONEOS_DEPLOYMENT_TARGET`). `PushedProfileScreen` draws the same
`ProfileScreen` — same identifiers — with the stack's back button as its dismissal, and never presents
anything itself: the alternative is the nested sheet T40 measured (`AddMembersView`'s submit never ran).

## 4. Tests

### 4.1 Unit — `MattermostTests/T5449ProfilePresentationTests.swift`

No server, no UI:

* `testTheEnvironmentDefaultIsTheSheetEveryOtherHostDraws` — a host that sets nothing keeps T41's
  presentation (a `.push` default would attach `navigationDestination` outside a stack everywhere and
  open nothing), and the value is settable;
* `testThePushResolvesTheTargetedAccountThroughTheCoordinator` — the push draws the *tapped* account
  (not `myModel`), a second push at the same account reuses the warm model, a different account is a
  different model, and the count is exactly two (the coordinator's cache is the only allocator);
* `testTheDestinationIdentityIsTheAccount` — `Hashable`/`Equatable` on `ProfileTarget` plus the
  one-slot machine (`present` twice re-aims, never stacks).

### 4.2 Live — `MattermostUITests/T5449ListProfileUITests.swift`

Five tests, one per row in spec §9, each seeding its own post in `#t429-tap` with a unique marker,
asserting the profile's `profile.username` against `GET /users/{authorID}`:

1. `testTheAuthorOfASearchResultOpensTheirProfile` — search a marker that only exists in a `t41buddy`
   post; the row's label must contain the author's display name; `tapAuthorHeader` asserts the author's
   own button exists **inside** the row and taps it → the sheet; then `profile.done`, a tap on the row
   body (`0.55, 0.80`) still opens the post (`postFocus.<id>`).
2. `testTheAuthorOfASavedPostOpensTheirProfile` — the same post saved with
   `PUT /users/{me}/preferences` (`flagged_post`, T39's path), opened from the Saved tab. This is the
   host whose row draws a channel line, i.e. the one that made the fixed coordinate fail (§6.3).
3. `testTheAuthorOfAMentionOpensTheirProfile` — `t41buddy` posts `@perfprobe …`; the feed's newest row
   is that post.
4. `testTheAuthorOfAPinnedPostPushesTheProfile` — the post pinned (`POST /posts/{id}/pin`), the pane's
   pinned sheet opened, the author tapped: `profilePush` exists, `profile.username` matches the server,
   `profileSheet` is **absent**; then the push is popped and the pinned list must come back (§6.5,
   corrected in §8.4 — the pop was a silent no-op until `t_a8a0bac4`).
5. `testTheAuthorOfASearchResultInTheLookupSheetPushesTheProfile` (`t_a8a0bac4`, C2 validation F4) —
   the **regular** layout's push site: `NativeShellView`'s `lookupSheet`. Search opened from the detail
   column's toolbar, a result's author tapped: `profilePush` exists, `profileSheet` absent,
   `profile.username` is the server's. Needs a regular-width destination (iPad, landscape) and
   **skips** on a phone, like the other layout-dependent tests in this target — on this suite's iPhone
   run it is the one skip (§8.3).

`tapAuthorHeader` is the one route all five use: it resolves `post.<id>.avatar` (falling back to
`.author`), asserts the resolved header is a **`Button`** (not merely that an element with that
identifier exists — C2 validation F2, `t_a8a0bac4`), asserts the header's centre lies inside the row's
frame — so a row whose identifier and a header whose frame belong to different views cannot pass — and
taps it.

`popProfile` is the one pop route the two push tests use: it taps the back button of the pushed
profile's **own** bar (`navigationBars["Profile"].buttons.element(boundBy: 0)`) — measured; see §8.4.

## 5. Gates and run logs

All numbers are from runs on this worktree (branch `t_2fa3bbe1`), iPhone 17 Pro simulator,
`~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa-t5449c2`.

| run | command (abridged) | outcome |
|---|---|---|
| units | `qa-test.py --platform ios --only-testing MattermostTests --label t5449c2-units1` | **1796 run, 8 skipped, 0 failed** (`build/logs/t5449c2-units1-console.log`) — the tree's 1793 plus this card's 3 |
| live, first attempt | `--only-testing MattermostUITests/T5449ListProfileUITests --label t5449c2-live1` | 4 run, **5 failed** (`build/logs/t5449c2-live1.log`) — every failure was the test's own premise, see §6 |
| live, after the corrections | same spec, `--label t5449c2-live2` | **4 run, 0 skipped, 0 failed**, 129 s (`build/logs/t5449c2-live2-console.log`) |
| dual-render gates | `bash scripts/verify-dual-render-gates.sh --allow-approved-registry` | **PASS** — "dual-render debug affordances cannot reach a Release build" (213 object ids defined exactly once; `130 + 105 + 31` git-tracked files in the three synchronized trees, and `none of the 264 source file(s) … has a hand-written project-file entry`). The count was **stale in the first version of this row**: it said 261, which is what the gate printed on the card branch *before* the merge brought main's files in. Re-run at the audited tree `7f38b14`: `130 + 105 + 31` / `264` (C2 validation F5). Verdict identical, PASS. |
| regression | `--only-testing T39SearchUITests --only-testing T42ActivityUITests --only-testing T70AuthorNamesUITests --only-testing T5449ThreadProfileUITests` | see §5.1 |

Per-test timings from `t5449c2-live2`: mention 22.9 s, pinned 33.4 s, saved 20.5 s, search 29.7 s.

### 5.1 Regression on the suites that drive these rows

`--label t5449c2-regress1` — **10 run, 0 skipped, 0 failed**, PASS
(`build/logs/t5449c2-regress1-console.log`):

* `T39SearchUITests` (4) — `testSearchRendersTheServersMatchAndOpensItAtThePost` (the row still opens
  the post after the restructure), `testUnsaveFromTheSavedTabRemovesTheRowAndThePreference`,
  `testUnpinFromThePinnedSheetRemovesTheRowAndThePin` (the row's `savedPosts.remove.` /
  `pinnedPosts.*` siblings are still reachable), `testAMalformedQueryExplainsItselfInsteadOfShowingAnEmptyList`;
* `T42ActivityUITests` (4) — including `testTappingARowOpensItsChannel` (the activity row's own tap
  survived the restructure) and `testTheMentionsTabListsMyMentionsFromTheServer`;
* `T70AuthorNamesUITests` (1) — `testNoAuthorInTheChannelReadsUnknownUser` (the author labels these
  rows draw are unchanged);
* `T5449ThreadProfileUITests` (1) — C1's `testTheAuthorOfAThreadReplyOpensTheirProfile`, the sheet form
  in the thread host, still green after `ProfileTarget` became `Hashable`.

`--label t5449c2-regress2` — **11 run, 0 skipped, 0 failed**, PASS (932 s,
`build/logs/t5449c2-regress2-console.log`): `T429ProfileTapUITests` (the channel-row tap law this card's
restructure imitates) and `T41ProfileUITests` (the sheet itself, including its dismissal and the
`openConversation` route). Together with regress1 that is every suite that reads a row or a profile.

## 6. Measurements and findings

The first live run is the interesting artifact: it **refuted two claims the spec makes** and one claim
this card's own brief repeats. Both are recorded here rather than quietly worked around, because the
next person will otherwise re-derive them.

**6.1 The row restructure does what it is for.** The three hosts now expose the row as a single
labelled element (measured, saved row): `Button, {{16.0, 302.3}, {346.3, 68.3}}, identifier:
'savedPosts.row.<id>', label: '#t36-threads, T36 Reply: t48 save target …'`. Tapping the author's
avatar opens the profile in all four hosts (search/saved/mentions → `profileSheet`, pinned →
`profilePush`).

**6.2 Finding — the inner author is still addressable, so spec §3's "one element per row" consequence is
wrong.** §3 says that under `.accessibilityElement(children: .combine)` the inner `post.<id>.author`
"is not an addressable element", and that a coordinate tap is therefore "the only addressable path".
Measured in all three hosts:

```
saved row  Button {{16.0, 302.3}, {346.3, 68.3}}   'savedPosts.row.<id>'
  ├─ Button {{17.3, 302.3}, {94.3, 14.3}}          'savedPosts.channel.<id>'
  ├─ Button {{28.0, 324.7}, {36.0, 36.0}}          'post.<id>.avatar'   label 'Buddy Profile profile'
  ├─ Button {{74.0, 324.7}, {72.7, 18.0}}          'post.<id>.author'   label 'Buddy Profile'
  └─ Button {{368.3, 302.3}, {17.7, 20.3}}         'savedPosts.remove.<id>'
```

The reason is structural: `PostRowView` is itself `.accessibilityElement(children: .contain)`, and an
outer `.combine` does not flatten a nested container. The row *identifier* is one labelled element
(T39/T42 resolve it, T8e's intent), but its leaves remain traversable — so VoiceOver sees the author
button as well, which is exactly the affordance the restructure is protecting. No builder should
"fix" this by removing the row identifier: it is what the suites and the custom action key on.

**6.3 Finding — the brief's coordinate is miscalibrated for rows that draw a channel line.** The
brief (and spec §3) prescribe `CGVector(dx: 0.18, dy: 0.22)` of the row. On the saved row above that
point is `(16 + 62.3, 302.3 + 15.0) = (78.3, 317.3)` — the channel line ends at 316.6 and the author
header starts at 324.7, so the tap lands in the row's own padding and **opens the post**. It happens
to work for the search and pinned rows (no channel line inside the row element), which is why the
first run half-passed and looked like a wiring bug. The tests therefore tap the measured element
(`post.<id>.avatar`, the same target C1's thread test taps) and keep a coordinate only for "the rest
of the row still opens the post" (`0.55, 0.80`, inside the body text).

**6.4 Finding — the Saved list's own identifier is not exposed.** `element(app, "savedPosts")` never
resolves (40 s wait), while `savedPosts.row.*`, `.channel.*` and `.remove.*` all do; the enclosing
`CollectionView` carries `nativeSavedPane` instead. The `List`'s `.accessibilityIdentifier` is
swallowed by the pane's own identifier on this runtime. `savedPosts`/`pinnedPosts` are kept in the
source (the brief requires it) but nothing can wait on them: `revealRow`'s list lookup is a no-op
fallback, here and in T39. The tests wait on the row, which is the real proof the list drew.

**6.5 Finding — a pushed destination hides the screen beneath it.** With `profilePush` on top,
`pinnedPosts` is not in the tree at all, so "the list is still underneath" cannot be asserted by
`exists`. The pinned test proves the stack by **popping** it: the pinned list comes back and
`profilePush` goes away. That is a stronger claim than the original assertion — a push that had
replaced the sheet would have had nothing to pop back to.

> **Correction (`t_a8a0bac4`, §8.4):** this section's first version said the pop used `BackButton`.
> On this runtime `BackButton` never resolves in that position, and the fallback it described —
> `navigationBars.buttons["Back"]` — resolves the **shell's** back button *under the sheet*, whose tap
> is a silent no-op (hit point `(-1, -1)`). The pop therefore never happened and the two assertions
> that follow could not pass; they are green only since the pop moved into `popProfile`, which taps the
> pushed profile's own bar.

## 7. Not in this card

* Call and Add to a channel rows — C3 `t_296843e5`.
* `GlobalThreadsView` — not a host (thread-summary rows; participant avatars open the thread), no change.
* The channel pane's own four `.sheet` modifiers (spec finding F2) — untouched.
* `ProfileSheet.openConversation` and `PushedProfileScreen.openConversation` stay two copies of one
  route: `ProfileView.swift` is C3's file in this programme, and the two dismissals genuinely differ
  (a sheet dismisses itself, a push pops). A shared helper can land once C3 settles.

## 8. The adversarial validation's F2–F5, corrected (`t_a8a0bac4`)

`docs/t_0c520c78-c2-validation.md` §5 audited this card with six mutations and found one substantive
finding (F1: the restructure's causal claim is unmeasured — its own card) plus four evidence/coverage
defects, F2–F5. This section records their correction. **No product behaviour changed**: the only
modified files are `MattermostUITests/T5449ListProfileUITests.swift` and this note (F1 is not addressed
here).

### 8.1 F2 — the affordance assertion was type-blind (now red on the inert shape, by name)

`tapAuthorHeader` resolved the header with `descendants(matching: .any)` and asserted only that it
existed, while its message claimed "the row must draw the author's own button". The validation measured
that with `onShowProfile: nil` the same identifier resolves to a **`StaticText`**: the assertion passed,
the tap did nothing, and the run reddened three steps later at the presentation assertion — a
misattributed cause.

The helper now asserts the resolved element's type:

```swift
XCTAssertEqual(header.elementType, .button,
               "the author must be a control, not inert text: \(header.debugDescription)")
```

**Measured red, on that line.** Mutation: the search results row's callback replaced with `nil`
(`SearchView.swift`, the exact shape the validation measured as M7), rebuilt, one test run:

```
qa-test.py --only-testing MattermostUITests/T5449ListProfileUITests/testTheAuthorOfASearchResultOpensTheirProfile \
  --label t_a8a0bac4-f2-mutation2
→ 1 run, 0 skipped, 4 failed (build/logs/t_a8a0bac4-f2-mutation2.log)

T5449ListProfileUITests.swift:503: error: … XCTAssertEqual failed:
  ("XCUIElementType(rawValue: 48)") is not equal to ("XCUIElementType(rawValue: 9)")
  - the author must be a control, not inert text: Attributes: StaticText, 0x…,
    {{66.0, 273.3}, {96.3, 18.0}}, identifier: 'post.<id>.author', label: 'Buddy Profile'
```

The later failures (`:128`, `:131`, `:133`) still occur — the tap still does nothing — but the run is
now diagnosed on the affordance, by name, which is what F2 asked for. The mutation was reverted before
every run quoted below.

### 8.2 F3 — the file header now states what the code does

The old header claimed the author button is "not addressable", that the test "taps the row at a point
inside the author header", and that it "asserts `post.<id>.author` is absent first". None of that was
true of this file: it taps `post.<id>.avatar` (falling back to `.author`), asserts that element is a
`Button`, and never asserts absence. The header now reads:

* the tap is an **element, not a coordinate** — `PostRowView` is `.accessibilityElement(children:
  .contain)`, so an outer `.combine` does not flatten the nested container and both `post.<id>.avatar`
  and `post.<id>.author` stay addressable inside the row;
* the test taps the avatar (falling back to the name) and asserts the element type (§8.1);
* it is **not** a fixed fraction: `(0.18, 0.22)` of a row that draws a channel line lands *in* that
  line and opens the post instead of the profile — the measurement that replaced the coordinate
  (§6.3);
* spec §3's "not addressable, so tap a coordinate" is named as the claim the first live run refuted
  (§6.2).

### 8.3 F4 — the regular layout's lookup-sheet push has a test

Claim 2 names two push containers. `PinnedPostsView` was covered (test 4). `NativeShellView`'s
regular-layout `lookupSheet` — the only other `.environment(\.profilePresentation, .push)` site — was
not: all four live tests climb the compact layout through `ShellSettle.tapTab`, where Search/Saved/
Mentions are tabs and the default `.sheet` is the legal presentation.

New test: `testTheAuthorOfASearchResultInTheLookupSheetPushesTheProfile` (`MARK: - 5`). It seeds a
`t41buddy` post, launches on a regular-width destination in landscape, selects `#perf` in the split
sidebar (the search pane takes its team from the shell's location), opens Search from the detail
column's **toolbar** (`shellSearchButton`), waits for the sheet's own `searchSheetClose` +
`nativeSearchPane` (the sheet's chrome proves the container), searches the marker, taps the author, and
asserts `profilePush` exists, `profileSheet` is absent, and `profile.username` equals
`GET /users/{buddyID}.username`. It then pops the push with `popProfile` (§8.4) and asserts the sheet's
Done button and the result row are back — the stack, measured by popping it.

`Open profile` (the custom accessibility action all three hosts carry) stays **source-only**: XCUITest
cannot invoke a custom accessibility action. That is now said in the test's doc comment instead of
being left implied.

Runs:

| destination | result |
|---|---|
| iPad Pro (11-inch, 4th gen), iOS 26.5, landscape | `--only-testing …/testTheAuthorOfASearchResultInTheLookupSheetPushesTheProfile` → **1 run, 0 skipped, 0 failed**, 71.738 s, `** TEST SUCCEEDED **` (`build/logs/t_a8a0bac4-lookupsheet-ipad1.log`) |
| iPhone 16 Pro, iOS 26.5 (the suite's usual destination) | **skipped** (34.6 s) — the destination drew the compact layout, so there is no detail-column toolbar. Same convention as every other layout-dependent test in this target: skip, never fail. |

**Not vacuous.** Removing the sheet's `.environment(\.profilePresentation, .push)` (one mutation run on
the same iPad) reds the new test exactly where the law lives:

```
T5449ListProfileUITests.swift:325: error: … a profile opened from inside the lookup sheet must be
  pushed on that sheet's own stack
T5449ListProfileUITests.swift:328: error: … no nested sheet: T40 measured a sheet opened from inside
  a sheet whose confirmation never ran
→ 1 run, 0 skipped, 2 failed (build/logs/t_a8a0bac4-f4-mutation2.log)
```

— the same two assertions C2's validation measured red at the pinned site. (A first attempt at that
mutation lost its test host before XCTest recorded a result — `t_a8a0bac4-f4-mutation.log`,
"Restarting after unexpected exit" — and is treated as simulator noise, not as evidence either way; the
second attempt reproduced the assertion-level red.)

### 8.4 A defect this card found by running the suite: the pop was a no-op

`t_a8a0bac4-live-phone1` reddened test 4 at `:253` and `:256` ("popping the profile must return to the
pinned list"). The failures were not in the push — `profilePush` and `profile.username` were already
green — they were in the pop. The log's tap shows why:

```
t = 40.65s  Computed hit point {-1, -1} after scrolling to visible
```

`element(app, "BackButton")` never resolves in that position, so the test fell to
`app.navigationBars.buttons["Back"]`, which resolves the **shell's** back button (label "Back", at
`{{16, 113.8}, {62.6, 40.5}}`) — the one *underneath* the pinned sheet. The sheet covers it, XCUITest
computes an invalid hit point, and the tap is a silent no-op. The pushed profile's own bar is a second
navigation bar, titled **Profile**, whose leading button carries the previous screen's title
("Pinned in t429-tap"). Reproduced deterministically with a single-test run
(`build/logs/t_a8a0bac4-pinned-retry.log`, 1 run / 2 failed).

Fix: `popProfile(in:)` taps `navigationBars["Profile"].buttons.element(boundBy: 0)`. After it:
`--only-testing …/testTheAuthorOfAPinnedPostPushesTheProfile` → **1 run, 0 failed**, 86 s,
`** TEST SUCCEEDED **` (`build/logs/t_a8a0bac4-pinned-popfix.log`). §6.5 is corrected above; §4.2 now
names the helper.

### 8.5 F5 — the nits

* `T5449ListProfileUITests.swift`'s pop-back message had `\\n` in a Swift string, so the failure text
  printed a literal `\n` instead of a newline. Fixed (the message is now built with a plain `\n`
  escape). A second, identical slip in the new test's `XCTUnwrap` message (`GET /users/\\(buddyID!)`)
  is fixed at the same time.
* §5's "261 synchronized sources" did not match the gate at the audited tree. **Re-measured, not
  copied**: in a detached worktree at `7f38b14` the gate prints `130 + 105 + 31` git-tracked files and
  `none of the 264 source file(s) … has a hand-written project-file entry`; at this card's base
  (`79e1c9d`, which is newer) it prints `133 + 107 + 32` and `270`. The §5 row now states the
  `7f38b14` numbers and names the tree; the verdict is PASS in both trees.
* §2's "the avatar and the name stay the only real `Button`s" was true of the search and mentions rows
  only. A saved/pinned row also carries `savedPosts.remove.<id>` (a real button) and the
  `savedPosts.channel.<id>` element. Corrected in place.

### 8.6 This card's runs

All on the card branch's base (`79e1c9d`), server Mattermost 9.11.19 at `127.0.0.1:8065`, simulator
runtime iOS 26.5:

| run | command (abridged) | outcome |
|---|---|---|
| live, whole target | `--only-testing MattermostUITests/T5449ListProfileUITests --label t_a8a0bac4-live-phone2` | **5 run, 1 skipped, 0 failed** (172.3 s), `** TEST SUCCEEDED **` |
| live, F4 test on a regular layout | `--only-testing …/testTheAuthorOfASearchResultInTheLookupSheetPushesTheProfile` on an iPad Pro 11-inch | **1 run, 0 skipped, 0 failed** (71.7 s) |
| F2 mutation | `--only-testing …/testTheAuthorOfASearchResultOpensTheirProfile` with `onShowProfile: nil` | 1 run, **4 failed**, first red at `:503` by name |
| F4 mutation | the lookup sheet's push declaration removed, F4 test on the same iPad | 1 run, **2 failed** — `:325` (`profilePush` must exist) and `:328` (`profileSheet` absent) |
| pinned pop | `--only-testing …/testTheAuthorOfAPinnedPostPushesTheProfile` | **1 run, 0 failed** (86 s) |
| dual-render gates | `bash scripts/verify-dual-render-gates.sh --allow-approved-registry` | **PASS** at `7f38b14` (`130 + 105 + 31`, `264`) and at `79e1c9d` (`133 + 107 + 32`, `270`) |

Per-test timings from `t_a8a0bac4-live-phone2`: mention 48.3 s, pinned 35.4 s, saved 22.3 s,
lookup-sheet **skipped** 34.6 s, search 31.8 s.

Not run in this card: `MattermostTests`. No file under `Mattermost/` differs from the base
(`git diff --stat` is the two files above), so the unit suite's inputs are unchanged.
