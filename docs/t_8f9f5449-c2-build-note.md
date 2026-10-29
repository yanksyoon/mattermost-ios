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

The avatar and the name stay the only real `Button`s inside the row, so a tap on them never reaches
the row's gesture — that is what the live tests tap. Accessibility keeps **one labelled element per
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

Four tests, one per row in spec §9, each seeding its own post in `#t429-tap` with a unique marker,
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
   `profileSheet` is **absent**; then the push is popped and the pinned list must come back (§6.5).

`tapAuthorHeader` is the one route all four use: it resolves `post.<id>.avatar` (falling back to
`.author`), asserts the header's centre lies inside the row's frame — so a row whose identifier and a
header whose frame belong to different views cannot pass — and taps it.

## 5. Gates and run logs

All numbers are from runs on this worktree (branch `t_2fa3bbe1`), iPhone 17 Pro simulator,
`~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa-t5449c2`.

| run | command (abridged) | outcome |
|---|---|---|
| units | `qa-test.py --platform ios --only-testing MattermostTests --label t5449c2-units1` | **1796 run, 8 skipped, 0 failed** (`build/logs/t5449c2-units1-console.log`) — the tree's 1793 plus this card's 3 |
| live, first attempt | `--only-testing MattermostUITests/T5449ListProfileUITests --label t5449c2-live1` | 4 run, **5 failed** (`build/logs/t5449c2-live1.log`) — every failure was the test's own premise, see §6 |
| live, after the corrections | same spec, `--label t5449c2-live2` | **4 run, 0 skipped, 0 failed**, 129 s (`build/logs/t5449c2-live2-console.log`) |
| dual-render gates | `bash scripts/verify-dual-render-gates.sh --allow-approved-registry` | **PASS** — "dual-render debug affordances cannot reach a Release build" (213 object ids defined once; 261 synchronized sources with no hand-written entries) |
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
`exists`. The pinned test now proves the stack by **popping** it (`BackButton`): the pinned list comes
back and `profilePush` goes away. That is a stronger claim than the original assertion — a push that
had replaced the sheet would have had nothing to pop back to.

## 7. Not in this card

* Call and Add to a channel rows — C3 `t_296843e5`.
* `GlobalThreadsView` — not a host (thread-summary rows; participant avatars open the thread), no change.
* The channel pane's own four `.sheet` modifiers (spec finding F2) — untouched.
* `ProfileSheet.openConversation` and `PushedProfileScreen.openConversation` stay two copies of one
  route: `ProfileView.swift` is C3's file in this programme, and the two dismissals genuinely differ
  (a sheet dismisses itself, a push pops). A shared helper can land once C3 settles.
