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
a Release build gets:

```
Other, identifier: 'nativeChannelPane'
  Other, {{16.0, 162.7}, {140.3, 57.7}}, identifier: 'nativeChannelTitle', label: '0 T05 Header e3e65838'
    Button, label: '0 T05 Header e3e65838, View info'
      StaticText, label: '0 T05 Header e3e65838'
      StaticText, label: 'View info'
  Button, {{253.0, 163.3}, {19.7, 19.0}}, identifier: 'nativeChannelInfoButton', label: 'Channel info'
  Button, identifier: 'nativeProfileButton'
  Button, identifier: 'nativeChannelPinnedButton'
  Button, identifier: 'calls.joinButton'
  Button, identifier: 'nativeChannelThreadsButton'
  ScrollView, {{0.0, 230.7}, {402.0, 453.0}}, identifier: 'channelPostList'
```

Full dumps: `build/logs/ios-20261105-032013.log` (default surface, and the 404 run).
The dump is also captured after the fix in the 200-bookmarks run (see §4).

Before the fix the same dump (default launch, `channelInfo` resolved `web`) had **no**
`nativeChannelInfoButton` line at all — that is what the owner saw: a header with no way into
channel info. (The pre-fix tree is also what made the owner's separate "no channel header" reading
fair: the pane draws the display name and nothing that says the header is pressable; there was no
"View info" affordance either.)

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

Live (`MattermostUITests/T05ChannelHeaderUITests.swift`, real server at `127.0.0.1:8065`; three of
the four tests run with **no `-surfaceMode` arguments**):

* `testATheHeaderAndItsControlsAreOnTheDefaultSurface` — title label == the channel's **display
  name** while the URL name differs (`0-t05-header-<id>` vs `0 T05 Header <id>`); the info glyph
  exists; a tap on the title opens the sheet; the sheet names the channel and offers the members row.
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
  -> 15 tests, 0 failures          (build/logs/mac-20261105-032640.log)

scripts/qa-test.py --platform mac
  -> 2214 tests, 9 skipped, 1 failure — the failure is T53MediaFootprintTests'
     testAStagedPayloadIsWrittenToDiskRatherThanHeldInMemory, which fails **alone** on this host
     too (measured growth 82 MB / 174 MB / 806 MB across three runs against a 32 MB bound) and
     touches nothing this card changed; see §6

scripts/qa-test.py --platform ios --sim id=81A7F251-… \
  --only-testing MattermostUITests/T05ChannelHeaderUITests
  with TEST_RUNNER_MM_AUTH_* and TEST_RUNNER_MM_BOOKMARKS_SERVER=http://127.0.0.1:8078
  -> 4 tests, 0 skipped, 0 failures (build/logs/ios-20261105-040505.log, 126 s)
     A the default surface: header + info glyph, title == display name, sheet + members row
     B title tap and glyph → the same sheet, one presentation each, Done dismisses
     C 404 on bookmarks: no bar, zero height, header hittable, sheet intact, no bookmarks in it
     D 200 on bookmarks (proxy): bar between header and list, chips in sort_order, one fetch,
       pane and bar still there after a chip tap
```

Evidence artefacts from that run: the AX dump of the default surface (`ax-channel-header-default`)
and of the 200 bar (`ax-channel-header-bookmarks-200`), attached to the xcresult; the bar's own
line in the 200 dump is

```
ScrollView, {{0.0, 208.3}, {402.0, 48.0}}, identifier: 'channelBookmarks.bar'
  Button, {{12.0, 218.3}, {80.0, 28.0}}, identifier: 'channelBookmark.t05bookmark0000000000000001', label: 'Apple'
  Button, {{100.0, 218.3}, {87.3, 28.0}}, identifier: 'channelBookmark.t05bookmark0000000000000002', label: 'Mango'
  Button, {{195.3, 218.3}, {80.7, 28.0}}, identifier: 'channelBookmark.t05bookmark0000000000000003', label: 'Zebra'
```

— 48 pt tall as upstream, `Apple`/`Mango`/`Zebra` (sort orders 10/20/30) although the fixture's
array arrives as Zebra/Apple/Mango, with the title above it (`…162.7–198.4`) and the post list
below (`y=257.0`).

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
