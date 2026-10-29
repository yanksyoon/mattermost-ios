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
from this card's — the popover is wired either way — and it is filed as a follow-up card rather than
fixed here, because the fix belongs to `ThreadViewModel`'s profile merge, not to the popover.

The live test therefore taps the **avatar** (`post.<replyID>.avatar`, 36×36, hittable) and asserts the
name button's existence separately. Both affordances share one callback (`PostRowView.onShowProfile`), so
this exercises the same route the card is about.

## 6. Gates and run logs

_TBD — filled from the runs below._

## 7. Not in this card

* Search / saved+pinned / mentions hosts and the `Button`-in-`Button` restructure — C2 `t_2fa3bbe1`.
* Call and Add to a channel rows — C3 `t_296843e5`.
* A presentation change (anchored popover instead of the sheet) — a T41 product decision, spec §7.
* `ChannelPaneContent`'s own four `.sheet` modifiers (F2) — untouched, as the spec requires.
* The blank reply-author name (§5.2) — follow-up card, not fixed here.
