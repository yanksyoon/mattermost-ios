# C1 — the profile popover on the thread host, and `paneHost:` → `rowHost:`

Card `t_07216319` (C1 of `t_8f9f5449`). Spec of record:
`docs/t_8f9f5449-profile-popover-parity.md` §2.1–§2.3, §3. Sibling cards: C2 `t_2fa3bbe1`
(search / saved+pinned / mentions + the nested-tap restructure), C3 `t_296843e5` (Call and Add to a
channel). F1 (`t_7ffa9e76`) decided `.threads` is **retired** — `docs/t_7ffa9e76-threads-surface-retirement.md`
— so the thread host's `rowHost: .native` is not an interim reading but the permanent contract.

## 1. What this card changes

| file | change |
|---|---|
| `Mattermost/Core/RenderMode.swift` | `ProfilePopoverPolicy.offersAuthorTap(paneHost:profileSurface:)` → `(rowHost:profileSurface:)`. Doc table now says **row host**, names two non-channel hosts (`SearchView`, `MentionsView`), and records why the thread pane passes a fact instead of a resolver read (F1, now retired). Arity and the read-and-ignored `.profile` argument unchanged. |
| `Mattermost/UI/Native/Channel/ChannelView.swift` | `ChannelListSheet` gains `case profile(ProfileTarget)` (+ its `id`), handled in `ChannelPostListView.sheetContent`; `ChannelPostListView` gains the optional `server` / `navigation` the case needs; the pane's call site now passes `rowHost:`. The pane's own `.sheet` for its profile (`profilePopover`, T41/T429) is **untouched** — the spec keeps that presentation as shipped. |
| `Mattermost/UI/Native/Thread/ThreadView.swift` | `ThreadPostListView` gains `offersAuthorProfile` + `server` + `navigation`; `rowView` passes `onShowProfile` into `PostRowView`; `sheetContent` answers `.profile` with `ProfileSheet`. `ThreadPaneContent.offersAuthorProfile` computes the predicate with `rowHost: .native` as a fact about the view. **No new `.sheet` modifier** — the profile rides the list's one existing item-bound slot. |
| `MattermostTests/T429ProfileTapTests.swift` | the four cells (and two derived call sites) renamed mechanically; the doc comment says row host. |
| `MattermostTests/T5449ProfileHostPolicyTests.swift` | **new.** The four-cell truth table × the four row hosts (channel timeline, thread pane, search, mentions) = 16 cells, plus a "`.profile` is never consulted" property pin and the shipped-defaults/`.web`-pane pair. |
| `MattermostUITests/T5449ThreadProfileUITests.swift` | **new.** One live test: a reply's author, tapped in the thread pane, opens that author's profile; the username comes from `GET /users/{authorID}`. |
| `docs/parity.md` (T41 row) | the "entry points" sentence: the thread host is no longer "one of the four post hosts still owed" — it ships here; search / saved+pinned / mentions stay C2. |

## 2. The rule, and the one host that passes a fact

```
offersAuthorTap(rowHost: SurfaceRenderMode, profileSurface: SurfaceRenderMode) -> Bool
    (.native, _) -> true
    (.web,    _) -> false
```

`profileSurface` is still parsed and discarded. That is deliberate: it is the truth-table pin for
`t_42968927`'s defect (`.profile` resolving `web` removed the tap while the rows were drawn natively),
and `T5449ProfileHostPolicyTests.testTheProfileSurfaceIsNeverConsulted` asserts the answer does not move
with it.

The channel pane passes `resolver.resolvedMode(for: SurfaceDefaults.paneHostSurface)`. The thread pane
passes `.native` **as a fact**, because nothing in `Mattermost/` consults `resolvedMode(for: .threads)`
(F1), and because the retirement doc settles that the thread pane can only exist inside the native pane
host: a `web` thread pane would be a note over a released webview. Reading the resolver there would have
answered `web` on the shipped defaults and taken the tap off a natively drawn row — the same defect one
level down. The comment at the call site says so and cites the retirement doc; no `.threads` flag is
added or read anywhere in this card.

## 3. Why the thread host folds into `ChannelListSheet`

`ThreadPostListView` already owns exactly one `.sheet(item:)` for the row menu, the emoji picker, the
reactor list, the gallery and the preview. The spec forbids a second modifier on the same view tree (F2
records the channel pane's four `.sheet`s as the shape that silently drops presentations), so the profile
became `ChannelListSheet.profile(ProfileTarget)` and is presented by that same slot. Both switches over
the enum handle it (the channel list's and the thread list's), so the enum stays total and a future host
cannot forget a case.

Only the **callback** is gated:

```swift
onShowProfile: offersAuthorProfile
    ? { userID in sheet = .profile(ProfileTarget(userID: userID)) }
    : nil
```

so (a) `.profile` resolving `web` cannot remove the affordance, and (b) a preview host that passes no
closure keeps the inert drawing (`PostRowView` already draws plain, non-button name/avatar in that case).

## 4. Tests

### 4.1 Unit — `MattermostTests/T5449ProfileHostPolicyTests.swift`

No network, no UI. Four tests:

* `testEveryRowHostFollowsTheTruthTable` — 4 cells × 4 hosts, 16 assertions, each failure naming the host;
* `testTheThreadSearchAndActivityRowHostsOfferTheTap` — the three hosts the parent card added on top of
  the pane's four cells, asserted by name;
* `testTheProfileSurfaceIsNeverConsulted` — for each host and each row-host mode, `.profile` = web and
  `.profile` = native must agree;
* `testTheShippedDefaultsOfferTheTapForTheChannelAndThreadHosts` and
  `testAWebPaneTakesTheTapOffEvenWithANativeProfileCard` — the two real resolver states, pinned through
  `SurfaceModeResolver` rather than through a literal.

The file deliberately names the hosts as strings, not `Surface` cases: the search/activity hosts' resolver
reads are C2's to decide, and `.threads` is retired (a test that read it would be deleted by
`t_cdcc1f38`).

### 4.2 Live — `MattermostUITests/T5449ThreadProfileUITests.swift`

`testTheAuthorOfAThreadReplyOpensTheirProfile`. Fixture in `#t429-tap` (T429's channel — **never**
`#t41-profile`, which T429 §5.1 records as having reddened T41's DM test): a root by `perfprobe`, then a
reply **as `t41buddy`**, so the reply's author differs from the root's and the row draws a header with a
real avatar and name; a reply by the same author inside the grouping window would be a grouped row with no
header and the test would prove nothing. The test signs in, opens the channel, taps the root's
`post.<id>.replyCount` to open the thread, then taps the reply's author affordance and asserts
`profileSheet` exists and `profile.username` equals `GET /users/{authorID}`'s `username` — the server's
value, not a local string. It launches **without** `-surfaceMode profile=native` (T429's lesson: the flag
hides this class of defect).

## 5. Findings (measured while building this card)

### 5.1 The author element in a thread is `post.<id>.author`, not `thread.post.<id>.author`

The card assumed the thread row prefixes its children. It does not: `ThreadPostListView` applies
`thread.post.<id>` to the row **container**, and `PostRowView`'s leaves keep their own identifiers. The
measured accessibility tree of the thread pane (attachment `ECB64299…txt` of the failing run below) shows

```
Other,  identifier: 'thread.post.necc65zn67yqprd35ikhcecp5y'
  Button, identifier: 'post.necc65zn67yqprd35ikhcecp5y.avatar', label: ' profile'
  Button, identifier: 'post.necc65zn67yqprd35ikhcecp5y.author', {{58.0, 365.7}, {0.0, 14.0}}
```

T36 recorded the same composition for the tombstone marker under `thread.post.<id>`; this card's test
uses the real identifier and asserts the name button exists.

### 5.2 The reply's author name is drawn **empty** in the thread pane, so the name is a 0×0 target

Same tree: the reply's avatar label is `" profile"` (no name) and the name button is `{0.0, 14.0}` — a
zero-width target XCTest cannot tap ("Failed: Not hittable: Button, {{58.0, 365.7}, {0.0, 14.0}}").
`Text("")` is what a `PostAuthor` with an empty `displayName` draws, which means the thread model holds a
**profile with no fields** for that author: `ThreadViewModel.loadProfiles` filters on `users[id] == nil`,
so a stub entry proves "known" and the fetch never runs (the "Unknown user" fallback only fires when the
user is absent, not when it is blank). The stub can only come from a `thread_updated` frame's id-only
`participants` (`ThreadViewModel.apply(thread:)` stores whatever the frame carries into `users`); the REST
thread answer on this server carries `participants: null`, so that is the only insertion path. That last
step is a **hypothesis**, not a measurement: the socket frame was not captured. It is a separate defect
from this card's — the popover is wired either way — and it is filed as **`t_e73f31ce`** rather than
fixed here, because the fix belongs to `ThreadViewModel`'s profile merge, not to the popover.

The live test therefore taps the **avatar** (`post.<replyID>.avatar`, 36×36, hittable) and asserts the
name button's existence separately. Both affordances share one callback (`PostRowView.onShowProfile`), so
this exercises the same route the card is about.

## 6. Gates and run logs

All runs: iPhone 17 Pro simulator, `scripts/qa-test.py`, logs under `build/logs/` on this tree.

| gate | command | result |
|---|---|---|
| whole unit target | `python3 scripts/qa-test.py --platform ios --sim "name=iPhone 17 Pro" --only-testing MattermostTests --label t5449-units5` | **1793 run / 8 skipped / 0 failed**, `** TEST SUCCEEDED **` (`build/logs/t5449-units5.log`) — the base is 1788/8/0, plus this card's 5 |
| dual-render gates | `bash scripts/verify-dual-render-gates.sh --allow-approved-registry` | `RESULT: PASS — dual-render debug affordances cannot reach a Release build.` (gate 5 allowed by the flag, gate 8 counts the two new files as tracked) |
| C1's live suite | `… --only-testing MattermostUITests/T5449ThreadProfileUITests --label t5449-live4` | **1 run / 0 skipped / 0 failed** (`build/logs/t5449-live4.log`) |
| T429 re-run (the pane's tap) | `… --only-testing MattermostUITests/T429ProfileTapUITests --label t5449-t429-run1` | **4 run / 0 skipped / 0 failed** (`build/logs/t5449-t429-run1.log`) |
| T41 re-run (the sheet) | `… --only-testing MattermostUITests/T41ProfileUITests --label t5449-t41-run1` | **7 run / 0 skipped / 0 failed** (`build/logs/t5449-t41-run1.log`) |

The live environment was `TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065`,
`TEST_RUNNER_MM_AUTH_LOGIN=perfprobe`, the fixture password from `scripts/perf_seed.py`.

### 6.1 Host instability, measured and named (not this card's)

The host carried a load average of 130–330 during this work (several other cards' `xcodebuild` runs in
parallel), and three of the earlier attempts were killed by **runner crashes**, not by test failures:

* `t5449-units2` — 2 restarts (`Restarting after unexpected exit…`), 999 of 1788 tests reported, "failing"
  `DownloadWorkerTests.testResolveDestinationBuildsDownloadsFileURL` and
  `T34ChannelViewRestoreWiringTests.testTheListTurnsAPendingAnchorIntoARestoreAndConsumesIt`, both of which
  then passed in isolation (`t5449-units-recheck`, `t5449-units-recheck2`) and in the clean run;
* `t5449-units4` — 3 restarts, 1517 reported, "failing" `MMStoreConcurrencyTests…` and
  `MMStoreSizeTests…` (GRDB tests this card does not touch), 0 real failures;
* `t5449-live2` / `t5449-live3` — the UI runner died during launch / while typing into the quick switcher
  (`kAXError -25218`), 0 tests reported; the same binary was green in `t5449-live4`.

Every crash happened *inside the runner* (the accessibility/SwiftUI host), and the set of "failing" tests
changes from run to run — the signature of the load, not of this diff. The clean runs above are the
evidence used for the gates.

## 7. Not in this card

* Search / saved+pinned / mentions hosts and the `Button`-in-`Button` restructure — C2 `t_2fa3bbe1`.
* Call and Add to a channel rows — C3 `t_296843e5`.
* A presentation change (anchored popover instead of the sheet) — a T41 product decision, spec §7.
* `ChannelPaneContent`'s own four `.sheet` modifiers (F2) — untouched, as the spec requires.
* The blank reply-author name (§5.2) — follow-up card, not fixed here.
