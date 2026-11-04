# t_05caa678 — the channel screen's header, channel info and bookmarks

Reported (owner): "on the channel screen I cannot see channel bookmarks, the channel header, or
channel info. Clicking the channel header should display the channel details."

## 1. What was measured, and which of the four causes it was

The card named four possibilities; the answer is **(b), with two separate reasons** — and a third
thing that simply did not exist:

| # | Claim | Measured | Verdict |
|---|-------|----------|---------|
| (a) | the header is not rendered in the pane on screen | the AX dump of the channel pane (below) carries `nativeChannelTitle` with the channel's display name, `nativeChannelInfoButton`, `nativeProfileButton`, `nativeChannelPinnedButton`, `calls.joinButton`, `nativeChannelThreadsButton`, then `channelPostList` | **false** |
| (b) | it is rendered but its controls are gated off | `.channelInfo` was **not** in `SurfaceDefaults.nativeApprovedSurfaces`, and the info glyph is drawn only when `resolver.resolvedMode(for: .channelInfo) == .native` → on a default (Release-shaped) launch the only entry to channel info was not drawn | **true — this is the defect** |
| (b2) | the title was not a control at all | `ChannelPaneTitle` was a `Text` + a glyph; upstream's `onTitlePress` makes the whole title open channel info | **true — a second gate, in the design** |
| (c) | the sheet presents but its body never fills | the sheet has no bookmarks fetch at all (`ChannelInfoView.swift`: its own header comment lists bookmarks as deliberately absent); it renders the overview and the members row as soon as it is opened | **false** (the prime suspect did not exist to fail) |
| (d) | rendered off-screen / zero height | the dump shows the title at `{{16.0, 162.7}, {140.3, 57.7}}` and the post list at `y=230.7`, i.e. the header is on screen with real height | **false** |

And the third thing: **channel bookmarks did not exist in the app at all.** No model, no service, no
view, no route — `grep -rn bookmark Mattermost` matched only "Saved messages" glyphs and post
options. T52's build note (§5) recorded the route as unavailable on this server and split the work
off; the split was never picked up.

### Evidence: the AX dump (mandatory on this card)

Produced by the live suite itself (`dumpAccessibilityTree`, attached to the run and printed into the
test log), on a **native** launch with **no `-surfaceMode` arguments** — i.e. the surface resolution
a Release build computes. Run `build/logs/ios-20261105-042142.log`, dump
`channel-header-default-surface` (5 tests / 0 skipped / 0 failed, `** TEST SUCCEEDED **`):

```
Other, {{0.0, 162.3}, {402.0, 711.7}}, identifier: 'nativeChannelPane'
  Other, {{16.0, 162.7}, {140.3, 57.7}}, identifier: 'nativeChannelTitle', label: '0 T05 Header 13945f7f'
    Button, {{16.0, 162.7}, {140.3, 57.7}}, label: '0 T05 Header 13945f7f, View info'
      Image, {{18.0, 183.3}, {15.3, 16.3}}, identifier: 'number'
      StaticText, {{43.3, 162.7}, {113.0, 42.3}}, label: '0 T05 Header 13945f7f'
      StaticText, {{43.3, 206.0}, {52.0, 14.3}}, label: 'View info'
      Image, {{99.3, 208.7}, {5.3, 9.3}}, identifier: 'chevron.right', label: 'Forward'
  Button, {{253.0, 163.3}, {19.7, 19.0}}, identifier: 'nativeChannelInfoButton', label: 'Channel info'
  Button, {{280.7, 163.3}, {19.7, 19.0}}, identifier: 'nativeProfileButton', label: 'My profile'
  Button, {{308.3, 162.3}, {19.7, 21.7}}, identifier: 'nativeChannelPinnedButton', label: 'Pinned messages'
  Button, {{336.0, 164.0}, {19.7, 17.7}}, identifier: 'calls.joinButton', label: 'Start call', value: idle
  Button, {{363.7, 163.7}, {22.3, 19.3}}, identifier: 'nativeChannelThreadsButton', label: 'Threads'
  ScrollView, {{0.0, 230.7}, {402.0, 453.0}}, identifier: 'channelPostList'
```

The same run dumps the pane **with the info sheet open** (`channel-info-sheet-open`, taken after the
title tap, not before it), which is where the third identifier the card names appears:

```
Other, {{0.0, 72.0}, {402.0, 802.0}}, identifier: 'channelInfo.sheet'
  Other,  {{16.0, 86.0}, {48.3, 28.3}}, identifier: 'channelInfo.done', label: 'Done'
  StaticText, {{151.3, 89.7}, {99.3, 20.3}}, label: 'Channel info'
  StaticText, {{67.0, 176.0}, {215.7, 24.0}}, identifier: 'channelInfo.title', label: '0 T05 Header 13945f7f'
  StaticText, {{40.0, 206.0}, {88.3, 15.7}}, label: 'Public channel'
  StaticText, {{140.3, 206.0}, {59.7, 15.7}}, identifier: 'channelInfo.memberCount', label: '1 member'
```

### The pre-fix state: from the gate, and from a capture that actually exists

There is **no AX dump of the pre-fix build**, and this note does not claim one. That build was never
kept, the suite in this file did not exist then, and `git show 7e269b1` is the only record. What the
pre-state is, stated so it can be checked rather than believed:

* `git show 7e269b1:Mattermost/Core/RenderMode.swift` —
  `nativeApprovedSurfaces = [.auth, .calls, .sidebar, .channelView, .composer, .search, .activity]`
  — `.channelInfo` is absent, so `defaultMode(for: .channelInfo)` returned `.web`.
* `git show 7e269b1:Mattermost/UI/Native/Channel/ChannelView.swift` —
  `if resolver.resolvedMode(for: .channelInfo) == .native { Button { showsChannelInfo = true } … }`
  gates the *only* entry to channel info (the title was `ChannelPaneTitle`'s label, not a control).

Both halves are executable today, so the pre-state is **measured rather than remembered**:
`testE` launches with `-surfaceMode channelInfo=web`, which drives the resolver into exactly the
answer `7e269b1`'s default produced, and dumps what that draws
(`channel-header-channelInfo-web`, same run):

```
Button, {{280.7, 163.3}, {19.7, 19.0}}, identifier: 'nativeProfileButton', label: 'My profile'
Button, {{308.3, 162.3}, {19.7, 21.7}}, identifier: 'nativeChannelPinnedButton', label: 'Pinned messages'
Button, {{336.0, 164.0}, {19.7, 17.7}}, identifier: 'calls.joinButton', label: 'Start call', value: idle
Button, {{363.7, 163.7}, {22.3, 19.3}}, identifier: 'nativeChannelThreadsButton', label: 'Threads'
```

`nativeChannelInfoButton` is absent from that tree while every other control is present — the gate's
own output, and the same shape the owner saw. Two honest caveats: (i) this is today's binary with the
switch forced, not the old binary, so it shows the gate's behaviour and not the old build's whole
screen; (ii) the *title* row differs from `7e269b1` by design — today the title is still the control
with the `View info ›` subtitle even with the gate off, which is the second half of the fix and is
what `testE` asserts (`channel-info-sheet-channelInfo-web` shows `channelInfo.title` open after a
title tap with the surface at `web`).

### Which build produced these dumps, and why not Release Catalyst

The card asks for a **Release** Catalyst build. On this host that capture cannot exist, measured
three ways — so this records the substitution rather than implying the card's wording was met:

1. **The project's test targets do not build in Release.** Measured:
   `python3 scripts/qa-test.py --platform mac --only-testing MattermostTests/SurfaceModeResolverTests/testNativeByDefaultRequiresApproval -- -configuration Release`
   → `xcodebuild rc=65`, `MattermostTests/APIClientTests.swift:3:18: error: unable to resolve Swift
   module dependency to a compatible module: 'Mattermost'` (`build/logs/mac-20261105-042526.log`).
   The app module is not importable from a Release build, so no XCTest — unit or UI — can host an AX
   dump there.
2. **The live suite's launch seams are DEBUG-only.** `-uiTestSeedServer` / `-uiTestSeedServerName`
   sit inside `#if DEBUG` (`Mattermost/MattermostApp.swift:288-325`), and `-surfaceMode` is parsed
   only when `debugAffordances` is on (`Mattermost/Core/SurfaceModeResolver.swift:94-103`). A Release
   app ignores both, so the suite could not sign in or reach a channel even if it built.
3. **What the card actually cares about is the compiled default, and that is proven separately.**
   The tests pass no surface flag, and `SurfaceDefaults.defaultMode(for:)` reads
   `nativeApprovedSurfaces` with no `#if DEBUG` anywhere in `SurfaceDefaults`, so a Debug run's
   resolution equals Release's. The Release contract is pinned by
   `SurfaceModeResolver.releaseSemantics(...)` — "exactly what a Release build computes
   (`overrides == [:]`, `launchOverrides == [:]`)" per its own comment — in
   `testPersistedOverrideIsIgnoredWithoutDebugAffordances` (a stored `channelInfo=web` is ignored and
   the surface resolves `.native`), `testLaunchOverrideIsIgnoredWithoutDebugAffordances` and
   `testReleaseSemanticsStillHonourRemoteDefaultAndCompileDefault`
   (`build/logs/mac-20261105-042837.log`: 4 run / 0 failed), plus
   `testNativeByDefaultRequiresApproval`/`testOnlyTheApprovedRegistryDefaultsToNative` for the
   registry literal.

So: dumps from an **iOS Simulator Debug** build of the native shell, with the surface resolution a
Release build gets (no flags, compile-time default), and the Release path itself asserted in the
unit suite. A Release Catalyst AX dump is **not** produced on this host and is not claimed.

The identifier-bearing lines of all seven dumps are committed verbatim — extracted from the run,
not retyped — in `docs/t_05caa678-ax-evidence.txt`, because `build/logs/` is git-ignored and an
auditor months from now cannot be asked to trust a path that no longer exists. Every line in that
file was checked against `build/logs/ios-20261105-042142.log` (`comm` over the sorted lines outside
`docs/` and the log: no line in the evidence file is absent from the log).

## 2. What changed

| # | Change | Where |
|---|--------|-------|
| 1 | `.channelInfo` is **native by default** — the flip T40 never made, on T55-AV-R's PASS (`docs/t55-revalidation-build-note.md` §3.5) | `Mattermost/Core/RenderMode.swift` (registry + ledger row, case comment) |
| 2 | the **whole title is the control** that opens `ChannelInfoSheet`, with upstream's two-line label (`<display name>` / `View info ›`); `nativeChannelTitle` stays the stable identifier | `Mattermost/UI/Native/Channel/ChannelView.swift` (`titleView`, `ChannelPaneTitle`) |
| 3 | the title's tap is **not** gated by the `.channelInfo` switch (the glyph still is) — with the pane owning the webview there is no web client to answer that tap, so a gate here is the defect | same |
| 4 | a **bookmarks bar** directly under the header and above the post list, in the server's `sort_order`; absent and zero-height when there are none or the server answers 404 | `Mattermost/UI/Native/Channel/ChannelBookmarks.swift` (new), `ChannelView.swift` (pane body + task) |
| 5 | one bookmarks model per channel, created and cached beside the window it belongs to | `Mattermost/UI/Native/Channel/ChannelPaneCoordinator.swift` |
| 6 | channel info does **not** list bookmarks (upstream has one place; it had none either, so nothing was removed — recorded rather than silently "confirmed") | `ChannelInfoView.swift` (unchanged; its header comment already says so) |
| 7 | the surface pins follow the flip: the approved set literal, and every resolver test that used `.channelInfo` as its "web by default" stand-in — there is no unapproved surface left, so those tests now pin the override *mechanics* against the surface's real default (`.native`) instead of a fabricated `web` | `MattermostTests/SurfaceModeResolverTests.swift`, `MattermostTests/ViewStoreTests.swift` |

### Every gate on the header, and why each one is allowed to stay

| Control | Gate | Justification |
|---|---|---|
| title → channel info | **none** | it is the pane's own control; upstream makes the whole title pressable (`header.tsx` `onTitlePress`), and it is the only entry that must survive any surface state |
| `nativeChannelInfoButton` | `.channelInfo` native | the surface's own affordance; now native by default, so it is drawn |
| `nativeProfileButton` | `offersAuthorProfile` (row host) **and** a known user id | a popover belongs to the view that draws the rows; both conditions are satisfied in a native pane |
| `nativeChannelPinnedButton` | `.search` native | pinned posts are T39's sheet; `.search` is approved native |
| `calls.joinButton` | `.calls` native | Calls renders natively and its entry only exists in a native pane |
| `nativeChannelThreadsButton` | none | the thread pane is a sub-region of the pane host |

### One piece of hardening, not a fix

The bar's model shares an in-flight fetch: two callers that arrive together await one request, and
the fetch runs in an unstructured `Task` so a cancelled view cannot leave the bar in `.loading`
forever. `testOverlappingAppearancesShareOneRequest` pins it. It went in while chasing what turned
out to be another channel's request (see §4) and stays because SwiftUI does re-run `.task`.

### Upstream parity, verified at the pin (`mattermost-mobile` `162f2560`, v2.45.0)

* `app/screens/channel/header/header.tsx` — `onTitlePress` → `navigateToScreen(Screens.CHANNEL_INFO, …)`;
  the subtitle is the member count, or `View info` with a `chevron-right` when there is none; the
  title is the pressed element (`NavigationHeader`), not a separate icon.
* `app/screens/channel/header/header.tsx:145` — `shouldRenderBookmarks={shouldRender}` and
  `showBookmarkBar = isBookmarksEnabled && hasBookmarks && shouldRenderBookmarks`;
  `<ChannelHeaderBookmarks>` sits **between** the navigation header and the channel banner.
* `app/screens/channel/header/bookmarks.tsx` — the bar renders `<ChannelBookmarks … showInInfo={false}>`
  under the header.
* `app/components/channel_bookmarks/channel_bookmarks.tsx` — a horizontal `FlatList` at 48pt,
  `testID 'channel_header.bookmarks.list'`, and **`return null`** when there is nothing to draw
  (upstream's own "zero height, no empty state" rule).
* `app/components/channel_bookmarks/channel_bookmark/channel_bookmark.tsx` — `testID
  'channel_bookmark.<id>'`, a link opens its `linkUrl`.
* `app/client/rest/channel_bookmark.ts` — `getChannelBookmarksForChannel` → `GET
  /channels/{id}/bookmarks`, answering an **array** of `ChannelBookmarkWithFileInfo`.

## 3. The server, measured

Re-measured for this card with `scripts/t52_channel_probe.py` against the pinned 9.11.19 Team
Edition fixture (`mm-perf`, `127.0.0.1:8065`):

```
GET /channels/{id}/bookmarks  -> 404 api.context.404.app_error
  "There doesn't appear to be an api call for the url='/api/v4/channels/<id>/bookmarks'"
```

So the 404 rule is a fact about this server, and the bar is absent here by design — no error state,
no empty box, no spinner. A **200** server does not exist on this host, so the 200 half is proven
against a transport fixture instead of a skipped test.

## 4. Tests, and what each actually ran against

Unit (`MattermostTests/T05ChannelBookmarksTests.swift`, 15 tests, no server):

* `sort_order` is the draw order; equal orders keep the server's arrival order (the sort is stable);
* a tombstoned row and a row with no id are not drawn;
* **404 → `.unavailable`, `isVisible == false`, `outcome == "bookmarks=unsupported status=404"`**;
  a timeout is the same absence;
* an empty 200 is `.loaded` with nothing drawn (same pixels, different fact);
* one fetch per appearance; an unavailable answer is not retried per appearance; an explicit
  refetch keeps the rows;
* **overlapping appearances share one request** (regression pin for the live finding below);
* a chip opens only `http`/`https`; an unnamed chip reads as a word, never an id; glyph per type;
* the wire shape decodes an array with missing optional fields.

Live (`MattermostUITests/T05ChannelHeaderUITests.swift`, real server at `127.0.0.1:8065`; four of
the five tests run with **no `-surfaceMode` arguments**):

* `testATheHeaderAndItsControlsAreOnTheDefaultSurface` — title label == the channel's **display
  name** while the URL name differs (`0-t05-header-<id>` vs `0 T05 Header <id>`); the info glyph
  exists; a tap on the title opens the sheet; the sheet names the channel and offers the members row;
  dumps the pane (`channel-header-default-surface`) and the sheet **with it open**
  (`channel-info-sheet-open`, the one containing `channelInfo.title`).
* `testBTheHeaderTapAndTheGlyphOpenTheSameSheetOnce` — both entries open `channelInfo.sheet`, one
  presentation each time, and `Done` dismisses it.
* `testCA404OnBookmarksLeavesTheHeaderAndTheSheetIntact` — premise re-asserted (`GET …/bookmarks` is
  404); no `channelBookmarks.bar` / `.error` / `.empty`; post-list top − title bottom < 48 (zero
  height); header hittable; the sheet still renders overview + members; no bookmarks row or section
  in the sheet.
* `testDABookmarks200DrawsTheBarInServerOrder` — runs against
  `scripts/t05_bookmarks_proxy.py` (a transport proxy in front of the real server that answers only
  this route). Fixture order 30/10/20 with names Zebra/Apple/Mango, so only `sort_order` can pass;
  the bar must list them left-to-right in that order, sit between title and post list, be fetched
  **once**, and still be there after a chip tap (the pane stays open).
* `testEForcingTheChannelInfoSurfaceToWebHidesTheGlyphNotTheEntry` — the one test that *does* pass a
  flag (`-surfaceMode channelInfo=web`), because its subject is the pre-fix gate rather than the
  default: the glyph must be absent, the title must still be the control, and the sheet must still
  open. It is also where the card's pre-fix evidence comes from (§1).

### Two failures the 200 test produced, neither of them the app's

1. `bookmarks_requests: 2` — see above: the second request was **another channel's** bar.
2. Then the bar drew **nothing at all**: the per-channel counter I had just added indexed the
   regex with a name the pattern did not have (`group("channel")` on `([^/]+)`), so the fixture
   raised inside its handler and the client saw a dropped connection. The screen looked exactly
   like "the app does not draw the bar on a 200".

   Repaired twice over: the pattern names the group (`(?P<channel>…)`), and every request is now
   wrapped so a fixture exception becomes a logged `500` instead of a dead socket — a fixture bug
   must never be able to read as an app defect again. Verified before the suite:
   `curl /api/v4/channels/abc123/bookmarks` → `200`, status → `{"bookmarks_requests_by_channel":
   {"abc123": 1}}`.

### One test-driving defect it also exposed

The first time the bar *did* draw, the dump showed the restored channel (`0 T05 Header 1937b60c`,
an archived fixture from an earlier run) — not the channel the test had just created. `openChannel`
asserted only that *a* title existed. It now waits for the title to equal the created channel's
**display name** and retries the switcher row once (a row tapped while the keyboard animates can
land on the keyboard). Both failures were reported as failures while they lasted; nothing was
skipped or loosened.

## 5. Results

```
scripts/qa-test.py --platform mac --only-testing MattermostTests/T05ChannelBookmarksTests
  -> 15 tests, 0 failures          (build/logs/mac-20261105-042458.log, 25 s)
     (the same run that first went green was mac-20261105-032833.log — an earlier revision of this
     note cited mac-20261105-032640.log, which never existed: qa-test labels by run start and the
     neighbouring runs are 032342/032833/032905)

scripts/qa-test.py --platform mac \
  --only-testing …/testPersistedOverrideIsIgnoredWithoutDebugAffordances \
  --only-testing …/testLaunchOverrideIsIgnoredWithoutDebugAffordances \
  --only-testing …/testReleaseSemanticsStillHonourRemoteDefaultAndCompileDefault \
  --only-testing …/testNativeByDefaultRequiresApproval
  -> 4 tests, 0 failures           (build/logs/mac-20261105-042837.log, 13 s)
     the Release contract: debugAffordances off == what a shipped build computes, `.channelInfo`
     resolves `.native`

scripts/qa-test.py --platform mac --only-testing …/testNativeByDefaultRequiresApproval \
  -- -configuration Release
  -> xcodebuild rc=65, BUILD FAILED (build/logs/mac-20261105-042526.log)
     not this card: the test target cannot import the app module from a Release build at all
     (`APIClientTests.swift:3:18: unable to resolve Swift module dependency … 'Mattermost'`); it is
     why the card's "Release Catalyst AX dump" is substituted — see §1

scripts/qa-test.py --platform mac
  -> 2214 tests, 9 skipped, 1 failure — the failure is T53MediaFootprintTests'
     testAStagedPayloadIsWrittenToDiskRatherThanHeldInMemory, which fails **alone** on this host
     too (measured growth 82 MB / 174 MB / 806 MB across three runs against a 32 MB bound) and
     touches nothing this card changed; see §6

scripts/qa-test.py --platform ios --sim id=81A7F251-… \
  --only-testing MattermostUITests/T05ChannelHeaderUITests
  with TEST_RUNNER_MM_AUTH_* and TEST_RUNNER_MM_BOOKMARKS_SERVER=http://127.0.0.1:8078
  -> 5 tests, 0 skipped, 0 failures (build/logs/ios-20261105-042142.log, 180 s)
     A the default surface: header + info glyph, title == display name, sheet + members row
     B title tap and glyph → the same sheet, one presentation each, Done dismisses
     C 404 on bookmarks: no bar, zero height, header hittable, sheet intact, no bookmarks in it
     D 200 on bookmarks (proxy): bar between header and list, chips in sort_order, one fetch,
       pane and bar still there after a chip tap
     E the gate forced to web: glyph absent, title still the entry, sheet still opens
```

Evidence artefacts from that run: the AX dumps `ax-channel-header-default-surface`,
`ax-channel-info-sheet-open`, `ax-channel-header-bookmarks-404`, `ax-channel-info-sheet-404`,
`ax-channel-header-bookmarks-200`, `ax-channel-header-channelInfo-web` and
`ax-channel-info-sheet-channelInfo-web`, all attached to the xcresult by the suite itself (and the
same text printed into the log). The 200 run's bar lines are

```
ScrollView, {{0.0, 230.3}, {402.0, 48.0}}, identifier: 'channelBookmarks.bar'
  Button, {{12.0, 240.3}, {80.0, 28.0}}, identifier: 'channelBookmark.t05bookmark0000000000000001', label: 'Apple'
  Button, {{100.0, 240.3}, {87.3, 28.0}}, identifier: 'channelBookmark.t05bookmark0000000000000002', label: 'Mango'
  Button, {{195.3, 240.3}, {80.7, 28.0}}, identifier: 'channelBookmark.t05bookmark0000000000000003', label: 'Zebra'
```

— 48 pt tall as upstream, `Apple`/`Mango`/`Zebra` (sort orders 10/20/30) although the fixture's
array arrives as Zebra/Apple/Mango, with the title ending at `y=220.4` above it and the post list
starting at `y=279.0` below it: `220.4 < 230.3 < 279.0`, so the bar is under the header and above the
list, and it is the only thing between them.

## 6. What is NOT proven here, and why

* **A live 200 from a real Mattermost server.** The pinned fixture has no bookmarks route; the 200
  test therefore runs against a transport fixture that returns the documented array shape. The shape
  itself is grounded on upstream's client (`ChannelBookmarkWithFileInfo[]`) and the server's API, not
  on a response this host can produce.
* **File bookmarks' tap.** Upstream opens the gallery (T38's preview); this bar draws a file chip as a
  label rather than a button, because a button that opens nothing is worse. Link chips are buttons.
* **The owner's visual confirmation** (the card's `DONE` line): the AX dump, the tests and this note
  are the machine evidence; the owner still has to look at the screen.
* `scripts/verify-dual-render-gates.sh --allow-approved-registry` currently reports **one** FAIL,
  gate 1: `Mattermost/MattermostApp.swift:653,656` + `NotificationInputRouting.swift:182`
  `setOverride` calls outside `#if DEBUG`. That is a pre-existing textual false positive from
  `t_ba355551` (every `NotificationInputRouting.setOverride` matches the gate's pattern for
  `SurfaceModeResolver.setOverride`) — verified identical on `HEAD` in a clean worktree. It is not
  this card's and is not fixed here.
* **`T53MediaFootprintTests/testAStagedPayloadIsWrittenToDiskRatherThanHeldInMemory` is red on this
  host and red before this card.** It fails standing alone, three times, measuring 82 MB, 174 MB and
  806 MB of footprint growth for a 32 MB staged payload — a probe that reads the whole process's
  footprint rather than the staging path's. Nothing in the media pipeline is touched by this card
  (`git status` above is the complete change set). It is recorded rather than "fixed" by raising the
  bound, because a real regression there would then be invisible.

## 7. Round 2 — the review's evidence findings, and what changed

Review round 1 accepted the behaviour (its own re-run: 15/15 unit, 4/4 live) and returned six items,
all of them about the record rather than the screen. Each is closed here; **no product code changed
in this round** — `git diff` over `Mattermost/` is comments only (checked:
`git diff -U0 Mattermost/ | grep -E '^[+-]' | grep -v '^[+-]\s*//'` is empty), which is why the
2214-test suite result above still describes this tree.

| # | Finding | Closed by |
|---|---|---|
| 1 | the note claimed a pre-fix dump showed no `nativeChannelInfoButton`; no such dump exists, and the cited log was produced after the change | §1 "The pre-fix state": the claim is deleted, the pre-state is quoted from `7e269b1`'s registry literal and gate, and a capture that *does* exist (`testE`, `-surfaceMode channelInfo=web`) is attached. The same false sentence in `RenderMode.swift`'s approval ledger was corrected too. |
| 2 | no AX dump contained `channelInfo.title`, which the card lists as required | `dumpAccessibilityTree` moved after the tap in `testA` (`channel-info-sheet-open`) and added in `testC`/`testE`; the dump in §1 shows the identifier and the display name |
| 3 | the dump is an iOS-Simulator Debug build, not the card's Release Catalyst | §1 "Which build produced these dumps": the substitution is recorded with three measurements — Release test targets do not build (`mac-20261105-042526.log`, rc=65), the launch seams are `#if DEBUG`, and the Release contract is asserted through `releaseSemantics` (`mac-20261105-042837.log`, 4/0/0) |
| 4 | `build/logs/mac-20261105-032640.log` resolves to nothing | §5 cites `mac-20261105-042458.log` for this round's 15 and `mac-20261105-032833.log` for the original, and says why the old path was wrong |
| 5 | `ChannelInfoView.swift:16-18` still said `.channelInfo` is `.web` until T40-AV approves the flip | rewritten: native by default since this card, title tap ungated and why, glyph gated, bookmarks belong to the bar |
| 6 | two test comments described assertions the suite does not make | file header now states where each bookmarks rule is asserted (offline / live-404 / live-200-against-proxy); the chip-tap comment says the target is unit-tested and the screen's survival is what is live-asserted |

Re-run after the round (all in §5): live 5/5, unit 15/15, Release-contract 4/4.
