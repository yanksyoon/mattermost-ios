# T56 — post bodies are selectable as one range (card t_38e0eac6)

Owner report: *"The texts on the messages cannot be copied via mouse drag. Make the text copy-able via
mouse drag (highlight) and copy."*

## What was wrong

`MarkdownView` drew a post body block by block, and each block was its own `Text` with
`.textSelection(.enabled)` (`Mattermost/UI/Native/Channel/Markdown/MarkdownView.swift:53`,
`:222`). SwiftUI scopes selection to a single `Text`, so a selection could never cross from paragraph 1
into paragraph 2 — a multi-paragraph post could not be selected as one message, and a drag over the
body mostly became a scroll. Nothing was copied per post; `PostRowView.swift:677` is the "Copied"
confirmation sheet, not a body selection path.

## What shipped

One read-only selectable surface per post **body**, spanning every block:

* `Mattermost/UI/Native/Channel/Markdown/MarkdownSelectionView.swift` (new)
  * `MarkdownBodyText` builds an `NSAttributedString` from the **parsed runs** (`MarkdownBlock` /
    `MarkdownInline`) — never `NSAttributedString(html:)`, never a `WKWebView`. Fonts, colours, code
    cards, quote bars, lists and custom-emoji attachments are re-created as attributes; the quote bar
    and code card are drawn by a small `NSLayoutManager` subclass so they stay part of the same text.
  * `MarkdownBodyUITextView`: `isEditable = false`, `isSelectable = true`, `isScrollEnabled = false`,
    `backgroundColor = .clear`, `textContainerInset = .zero`, `lineFragmentPadding = 0`, and a
    self-sizing height (`height(forWidth:)` via the layout manager) so it lays out where the `Text`
    blocks did.
  * Link taps go through `textView(_:shouldInteractWith:in:interaction:)` to the existing opener
    closure — default URL handling is not re-enabled, so a tap cannot open Safari blindly.
  * `-uiTestLegacyBlockBody` restores the old per-block renderer; `-uiTestExposeBodySelection`
    publishes the live selection / copied text on the text view's accessibility value for the live
    tests (both flags are test seams; neither changes the shipped path).
* `Mattermost/UI/Native/Channel/PostRowView.swift`: the body is now `SelectableMarkdownBody` (one
  element with identifier `post.<id>.body.block0`), or the legacy block stack when the revert flag is
  set.

Security invariant unchanged: the body is drawn from the parity parser's runs, so raw HTML stays
literal text. `MattermostTests/T34MarkdownTests.swift::testHTMLIsDrawnAsTextNeverInterpreted` is
untouched and still passes, and the new source scan in `T56SelectionTests` asserts there is no
`NSAttributedString(html:` / `WKWebView(` call site in either renderer.

Parity: this is **desktop** selection behaviour (ordinary selection over the whole message, Cmd+C).
mattermost-mobile deliberately does not make post bodies selectable — RN `Text` is `selectable` only
for context `table_cell`, and only when `copyAndPasteProtection` is off — so this is a documented
divergence, not a mobile-parity item. The claim note lives on `M:app/screens/channel` in
`parity/claims.tsv`.

## Tests

Unit — `MattermostTests/T56SelectionTests.swift`, 14 tests, all pass:

| test | property |
|---|---|
| `testThreeParagraphsAreOneRange` | one `NSRange` covers all three paragraphs, in order |
| `testCopyingTheRangePutsTheWholeBodyOnThePasteboard` | real `UITextView.copy(nil)` → real `UIPasteboard` == drawn text (T2) |
| `testCodeBlockCopiesWithoutFenceCharacters` | T3 |
| `testTheSurfaceIsReadOnlyButSelectableAndSelfSizing` | T1/T4 surface contract |
| `testLinksStayTappableAndRouteThroughTheOpener` | T4 |
| `testHTMLIsStillDrawnAsTextNeverInterpreted` + `testNoHTMLParserInEitherRenderer` | T5 |
| `testSelectingOnePostCannotReachAnother` | AV isolation |
| `testTheSurfaceSizesItselfToItsWidth`, builder tests (headings, lists, quotes, emoji attachment, highlight) | layout/attributes |

```
python3 scripts/qa-test.py --platform ios --sim "id=<udid>" \
  --only-testing MattermostTests/T56SelectionTests
# 14 run, 0 skipped, 0 failed
```

Live — `MattermostUITests/T56SelectionUITests.swift`, 2 tests, all pass against the dev server:

* `testOneSelectableBodyPerPostAndTheSystemCopyCopiesIt` — the body is one `textView` whose AX label
  carries all three paragraphs; a long press selects text from that surface; the system menu offers
  **Copy**; tapping it puts the selected text on the pasteboard (read back in-process, so no
  cross-app paste prompt); the copy contains no neighbouring-message marker.
* `testTheLegacyPerBlockRendererCannotSelectAcrossParagraphs` — with `-uiTestLegacyBlockBody` the body
  is three `staticText`s, there is no `textView`, and no gesture produces a selection seam: the AV
  revert.

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=… \
TEST_RUNNER_MM_AUTH_PASSWORD=… python3 scripts/qa-test.py --platform ios --sim "id=<udid>" \
  --only-testing MattermostUITests/T56SelectionUITests
# 2 run, 0 skipped, 0 failed   (log: build/logs/t56-live16.log)
```

Observations from the live run (log lines `T56-SELECTED`, `T56-MENU`, `T56-COPIED`):
`selection:` from the body text view, menu `['Copy', 'Look Up', 'Translate']`, `copied:T56`.

## Perf (T6) — 200 posts, same build, two arms

`scripts/t56_perf_seed.py --posts 200` seeds `#t56-perf`; `MattermostUITests/T56PerfProbeUITests`
scrolls it six passes in one arm (`native` = shipped surface, `legacy` = `-uiTestLegacyBlockBody` on
the same build); `scripts/t56_perf_sample.sh` samples the app process's RSS; `scripts/t56_perf_fold.py`
folds only the `PROBE-START…PROBE-END` window.

| run | arm | samples | median RSS | p95 RSS | peak RSS | median pass |
|---|---|---:|---:|---:|---:|---:|
| 1 | legacy (per-block `Text`) | 203 | 105.5 MB | 185.2 MB | 186.2 MB | 21.10 s |
| 1 | native (one surface) | 209 | 135.6 MB | 142.9 MB | 143.2 MB | 21.73 s |
| 2 | legacy | 199 | 67.4 MB | 120.6 MB | 121.3 MB | 21.02 s |
| 2 | native | 208 | 100.4 MB | 101.0 MB | 101.0 MB | 21.88 s |

Read, honestly: median RSS is consistently ~30 MB higher with the text view (legacy 67.4/105.5 MB vs
native 100.4/135.6 MB), the native peak is consistently *lower* (101/143 MB vs 121/186 MB), and the
scroll pass is consistently ~0.7 s slower (21.0/21.1 s vs 21.7/21.9 s, ≈ +3.5 %). This is real
overhead, not noise — it repeats in the same direction in both pairs. It is judged acceptable rather
than gated because the timeline is a `LazyVStack`: only the visible screenful (~6 rows) owns a text
view, so the delta is bounded by screenful and does not grow with the 200-post page. The card's
fallback (gate the *interaction* so the selection surface activates on drag) was deliberately not
taken: drag-select needs the selectable surface to exist **before** the drag begins, so gating it
behind the drag would defeat the feature. Single-run spread is wide on this simulator (legacy medians
67.4 vs 105.5 MB), so treat the 30 MB figure as a direction, not a precision value.

Fold: `python3 scripts/t56_perf_fold.py build/logs/t56-rss-{legacy,legacy2,native,native2}.csv`
(the fold takes the log named after each CSV, `t56-perf-<arm>.log`, for the `PROBE-START…PROBE-END`
window, and keeps only the pid with the most samples so a winding-down previous launch is never
averaged in).

There is **no frame-time instrument** in this repo (verified: no `CADisplayLink`/hitch collector
anywhere), so this note reports RSS and pass wall time and does not invent a frame-time figure.

## What could not be verified on this host (stated, not faked)

* **Catalyst UI tests do not build here.** The UI-test target is iOS-only in practice:
  `MattermostUITests/T38AttachmentsUITests.swift` calls `XCUIElement.pinch`, which does not exist in
  the macOS XCUITest API, so `-destination 'platform=macOS,variant=Mac Catalyst'` fails to compile
  the whole test bundle. (`MACOSX_DEPLOYMENT_TARGET` was briefly added to the UI-test target to try
  this; it was reverted.) The Catalyst *app* builds, but this host has no reachable display
  (`screencapture`: "could not create image from display"), so a manual mouse drag cannot be driven
  either.
* **A synthetic touch drag cannot exercise the iOS selection UI end-to-end.** Measured: a 0.9 s press
  followed by an 87 pt drag delivered ~18 pt of movement, and a second `press(forDuration:thenDragTo:)`
  after the selection existed did not move the selection at all — the system's edit menu takes the
  tail of the gesture. The live test therefore proves the surface, the selection origin and the
  system Copy; the *drag* itself is the platform's `UITextView` behaviour (click-drag selects on
  Catalyst; long-press + handles on iOS), which this host cannot run.

So the Done line "drag-select works on a Release build with a mouse" is **argued from the mechanism
plus the unit/live evidence, not observed on Catalyst here** — the honest gap. A Catalyst-capable
host needs `xcodebuild test -destination 'platform=macOS,variant=Mac Catalyst'` after making the UI
suite build for macOS (guard `pinch`), then the same two live tests.
