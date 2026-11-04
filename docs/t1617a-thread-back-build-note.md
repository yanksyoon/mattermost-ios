# t_1617a61c — the thread pane's leading control goes back to where the reader came from

Status: implemented, unit + live UI verified, Release Catalyst captured. Nothing here is pending on
a human, a credential, or a service this host cannot reach.

## 1. What this replaces (parity)

| Upstream (`mattermost/mattermost-mobile@162f2560`, the pinned commit) | This app |
| --- | --- |
| `app/routes/(authenticated)/thread.tsx` — the thread is a **screen** pushed onto the navigation stack, so `Header`'s `onBackPress` pops it | the thread is a **pane route** (`NativeLocation.pane == .threads` with a `postID`), so there is no stack chevron to pop |
| `app/components/navigation_header/header.tsx` — one `headerLeft` back control (`arrow-back-ios`), the title block, the Follow bell on the right | `ThreadPaneContent.header` — one leading `Button` (`threadPane.back`), the title/subtitle, the Follow bell |
| Back returns to `navigation.goBack()`, i.e. whatever was underneath the thread screen | Back returns to the **entry point the router recorded** (`NativeNavigation.threadEntryPoint`) |

The behaviour that has to match is not "a chevron exists" but "the control returns to the screen the
thread was opened from". Upstream gets that from the stack for free; a pane route has to remember it,
and remembering it from `location` is exactly what was wrong before (see §2).

## 2. The defect

The pane already drew a leading control, and `closeThread()` already existed — but it decided the
destination from `lastChannelLocation`. A thread opened from the **Threads list** carries the row's
own `channelID`, which matches the last channel the reader had open in that server, so Back from a
list-opened thread landed on **that channel** instead of the list. On a regular-width layout there
was also a *second* affordance: `RootView`'s toolbar `Back` (added for T36 when the pane had no
leading control at all), so the reader saw two back controls and they could disagree.

Three facts made the bug invisible to the tests that existed: the two entry-point tests were
`XCTSkip`ped, the navigation model holds `ServerStore` **weakly** (so a store passed as a temporary
deallocated before the first route and every assertion measured an unbound model), and the deep-link
test discarded the `NativeNavigationOutcome` it was handed.

## 3. What the router records, and why there

`ThreadEntryPoint` has two cases — `.channel` (a root or reply in a timeline) and `.threadsList` (a
row of the Threads list). It is recorded in `NativeNavigation.apply(_:)`, **before** the stack is
mutated, from three facts in order of authority:

1. the element the thread is being pushed onto — a `channel` element means the timeline, a `threads`
   element with no post means the list. This is the same pair of facts `apply` uses to decide where
   the thread stacks, so the entry point cannot disagree with the stack;
2. nothing pushed at all: the reader was on a tab, and the Threads tab **is** the list (the compact
   layout mounts `GlobalThreadsPaneContent` in it);
3. otherwise the previous location, then the thread's own route (a permalink or a notification names
   the conversation it belongs to).

Arriving anywhere that is not a thread clears the entry point, so a stale value can never be read by
the next thread's control. `closeThread()` switches on it: `.channel` → the conversation,
`.threadsList` → the list, never "whatever channel was last open".

Two stack rules in `apply(_:)` came with this, and both exist so the entry point and the stack agree:

* a **specific thread opened on top of the Threads list appends** to it (pane `.threads`, non-nil
  `postID`, over pane `.threads`, nil `postID`, same server) instead of replacing it. Back from the
  thread is therefore one step to the list, and the list's own model (page, position) comes back;
* a destination **already on the stack is a pop, not a push**: the elements beneath it stay beneath
  it. Without this, returning to the list would have reset the stack and lost the channel that the
  list itself was opened from.

For the tab case there is no list element to pop back to, and popping to the shell root is wrong on
its own terms: the root carries no **team**, and the list is team-scoped, so a bare root draws
`globalThreads.noTeam` instead of the rows the reader came from. `closeThreadToList()` therefore
opens the list for the current server **and team** (the channel key is dropped rather than turned
into a filter — there is no channel-scoped threads endpoint; see `docs/t36-build-note.md` §2).

## 4. The pane's control

`ThreadPaneContent.header` now draws **one** leading `Button`:

* `accessibilityIdentifier("threadPane.back")`, and a label that names the destination rather than the
  glyph — `Back to #t36-threads`, `Back to Threads`, and a plain `Back` when the thread was reached
  without a channel (a permalink);
* glyph follows the layout, because the pane is a push on a phone and a detail column on a wide
  window: `chevron.left` for compact, `xmark` for regular (`backGlyph`, via `horizontalSizeClass`);
* it is a `Button` with `.focusable()`, not a tap gesture, so on Catalyst it is in the tab order
  (tab to it, space to activate) and VoiceOver/XCUITest see one control with one label.

`RootView`'s toolbar back item no longer covers a thread — one leading affordance, not two. It still
covers the genuinely stranded route it was written for: a *channel* destination opened at a post (a
permalink, a search or saved result), whose stack was reset and whose header belongs to the channel
pane.

One honest nuance on the compact layout: the shell also draws its own navigation bar for the pushed
thread route, and *that* bar carries a plain `Back` (the standard stack pop, `sim-compact-01`). So on
a phone the reader sees the shell's `Back` above and the pane's chevron in the pane header. They are
two affordances for the same destination and they cannot disagree — the shell pops to the channel,
`closeThread()` re-opens it — but it is duplication that the regular-width layout does not have, and
the capture shows it rather than hiding it. Collapsing them would mean deleting one of the two, and
either choice changes the shell's push chrome rather than this card's behaviour.

## 5. Tests

### 5.1 Unit (`MattermostTests/NativeNavigationTests`, 38 tests, Catalyst) — green

Command: `python3 scripts/qa-test.py --platform mac --only-testing MattermostTests/NativeNavigationTests --label t1617a-back5` → exit 0.

New/rewritten:

* `testBackFromAChannelThreadReturnsToThatChannel` — channel timeline → thread → Back lands on the
  same server, team, channel and no post;
* `testBackFromAListOpenedThreadReturnsToTheListNotTheLastChannel` — the regression that started
  this: the thread's `channelID` matches the last channel, and Back must still go to the list;
* `testBackFromAThreadOpenedInTheThreadsTabReturnsToATeamScopedList` — the compact tab case: the
  list that comes back is team-scoped, not the shell root (a root has no team);
* `testAThreadOpenedFromTheThreadsListStacksOnTheList` — a specific thread appends on the list, and
  Back from the list is still the conversation;
* `testTheThreadBackDestinationIsChannelForATimelineThreadAndNilFromTheList` — `threadReturnChannel`
  is the channel for a timeline thread and `nil` for a list thread (the label's source).

Repaired alongside: both entry-point tests hold the `ServerStore` in a local `let` (the model's is
`weak`), and `testDeepLinkSwitchesServerAndOpensTheChannel` now asserts the returned outcome instead
of discarding it — otherwise all of this passed while measuring nothing.

### 5.2 Live UI (`MattermostUITests/T36ThreadsUITests`, real server) — green

Command:

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password from scripts/perf_seed.py> \
python3 scripts/qa-test.py --sim id=81A7F251-8B31-4945-8783-5A264C14B8D5 \
    --only-testing MattermostUITests/T36ThreadsUITests --label t1617a-t36full2
```

Result: `** TEST SUCCEEDED **` — all **7** tests, ~10 minutes, each `Test Case … passed` (no skips):

```
testFollowPersistsAndTheFollowedThreadsListPages                    99.499 s
testReplyingUpdatesTheRootsReplyCountAndTheThreadTakesSocketReplies  84.028 s
testTheThreadDrawsTheWholeChainInOrderIncludingTheCollapsedAndDeletedReply  83.635 s
testTheThreadHeaderBackFromTheThreadsListReturnsToTheList           92.900 s
testTheThreadHeaderBackReturnsToTheChannelItWasOpenedFrom            80.268 s
testTheUnreadThreadStateIsTheServers                           79.084 s
testTwoRepliesInARowFromTheThreadComposerBothLandInTheThread     84.194 s
```

The two new ones tap the real control and assert on the router, not on copy: the shell publishes the
resolved `NativeLocation` through `-uiTestExposeNavigationLocation` (`NativeDestinationPaneView`'s
`navigation.location` seam), so `pane=channel channel=<the thread's own channel> post=none` is the
assertion for "it went back to the conversation" and `pane=threads post=none` for "it went back to
the list". The channel test also reads `channelPostList.scrollGeometry` before and after
(`-uiTestExposeScrollGeometry`) and requires the same offset and the same top row — returning must
not scroll the timeline to the bottom.

Both tests keep four full-screen captures in the result bundle, exported to `docs/t1617a-shots/`:

| file | shows |
| --- | --- |
| `sim-compact-01-thread-header-back.png` | thread pane pushed on the phone: chevron, `Thread`, `1 reply · #t36-threads`, bell |
| `sim-compact-02-channel-returned.png` | after tapping it: `# T36 Threads` with the same root and its `1 reply`, pane gone |
| `sim-compact-03-list-thread-header-back.png` | a thread opened from the Threads list, same header |
| `sim-compact-04-threads-list-returned.png` | after Back: the Threads list, the row still there |

## 6. Evidence

### 6.1 Release Catalyst product (`docs/t1617a-shots/`)

The UI-test bundle cannot run on this host's Catalyst destination (its generated deployment target is
macOS 26.5; the host is 26.3.1 — `xcodebuild` refuses with *"My Mac's macOS 26.3.1 doesn't match
MattermostUITests's macOS 26.5 deployment target"*), so the Release screenshots come from inside the
product. `MattermostApp` gained an argument-gated probe — inert without both arguments, no `#if
DEBUG`, so it exists in the shipped configuration:

```
-threadBackSnapshot <dir> -threadBackTarget <channelID>,<rootID>
```

It opens the channel, opens the thread exactly as a reply line does (`openThreads` with the root's
post id), captures the window with `drawHierarchy` (no Screen Recording permission needed), then calls
`closeThread()` — the same function `threadPane.back` calls — and captures what is on screen after.

Run, on a Release Catalyst build (`-configuration Release`, `platform=macOS,variant=Mac Catalyst`,
re-signed ad-hoc — see `docs/t_ecfda04e-build-note.md` for why a fresh product needs that):

* `catalyst-thread.png` — thread pane as the detail column: leading **✕**, `Thread`, `1 reply`,
  Follow bell on the right; the root post and its reply are drawn; **no second back control** anywhere
  in the toolbar.
* `catalyst-back.png` — after `closeThread()`: the `# T36 Threads` timeline, with the same root post
  (`T1617 back probe root …`, `1 reply`) in view; the thread pane is gone.
* `catalyst-thread.txt` / `catalyst-back.txt` — the router's own state at each capture:
  `pane=threads post=k9ag5… entry=channel path=2` → `pane=channel post=none entry=nil path=1`.

### 6.2 What is *not* claimed

* The phone (compact) layout's ✕/chevron switch is covered by the live UI tests and the unit tests,
  not by a Catalyst screenshot: Catalyst is always `.regular`, so it only ever draws the ✕ path.
* No screenshot was captured of the Threads-list entry point on Catalyst; that path is covered by
  `testTheThreadHeaderBackFromTheThreadsListReturnsToTheList` and the unit tests.

## 7. Limits

* **Back from a list-opened thread re-opens the list rather than popping to a tab** on the compact
  layout when the list was the tab (there is no list element in the stack). The reader sees the list
  either way; the difference is that the tab bar is under one pushed pane instead of bare. Chosen
  because the alternative (pop to root) loses the team and draws `No threads yet`.
* **The interaction between this and the channel's own scroll restore is a known follow-up:** the
  timeline is required to keep its offset across the round trip (§5.2 asserts it), but the thread
  pane's own scroll position is not restored by `closeThread()`, because the pane is torn down. That
  is what upstream does too (the thread screen is popped), so it is parity, not a gap.
* **`ThreadEntryPoint` is process-lifetime state on the model**, not persisted: after a relaunch the
  pane is not open either, so there is nothing to be stale.
