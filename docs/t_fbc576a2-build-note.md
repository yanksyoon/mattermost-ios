# t_fbc576a2 — the composer grows, stops at its cap, scrolls, and keeps the caret on screen

Status: implemented and measured on this host (iPhone 16 Pro simulator, iOS 18.3.1, the live
9.11.19 fixture at `127.0.0.1:8065`). Unit suite 21/21, live suite 4/4, Release build runs the
40-line case. The one thing this note records as *not* reproduced live is a Catalyst window resize
(§7).

## 1. The defect

The composer's input was a `UITextView` created with

```swift
view.isScrollEnabled = false                      // ComposerView.swift, makeUIView
…
.frame(minHeight: … ? 56 : 34,
       maxHeight: … ? 220 : 140)                  // …and its frame
```

Two independent mistakes that only bite together. A `maxHeight` frame makes SwiftUI stop *growing*
the field at the cap, and `isScrollEnabled = false` leaves the text view with no way to show the
rest: it kept drawing its text into a box that was too short, clipped it, and the caret walked below
the visible edge as soon as the message passed four or five lines. Upstream has neither.

## 2. Upstream's rule (pinned mattermost-mobile v2.45.0, `162f2560`)

`app/components/post_draft/post_input/post_input.tsx`:

| line | what it says |
| --- | --- |
| `:171` | `const maxHeight = isTablet ? 150 : 88;` |
| `:172` | `const pasteInputStyle = useMemo(() => ({...style.input, maxHeight}), …)` |
| `:388` | `multiline={true}` on the `TextInput` that renders that style |

So upstream has **one growing input with a ceiling**: it grows with its content up to `maxHeight`
and scrolls internally past it. There is no declarative height and no switch that turns a scroller
off. React Native's multiline `TextInput` is a scroller that is clamped by `maxHeight`; the caret is
kept visible by the text input itself.

## 3. The rule, as one value (`Mattermost/UI/Native/Composer/ComposerInputHeight.swift`, new)

```swift
contentHeight = ceil(sizeThatFits(width: w, height: .greatestFiniteMagnitude).height)
height        = min(max(contentHeight, minimum), cap)
scrolls       = contentHeight > cap
```

`ceil` because `sizeThatFits` returns fractional points and truncating draws a field one point short
of its last line — the same clipping defect in miniature. The switch is `>` and not `>=`: a message
that fits exactly at the cap must not show a scroller.

### The numbers

| case | minimum | cap | source |
| --- | --- | --- | --- |
| phone | 34 | **88** | upstream's `maxHeight` with `isTablet == false` (`post_input.tsx:171`); 402 pt of field fits ~4 `body` lines |
| tablet | 34 | **150** | upstream's `maxHeight` with `isTablet == true`; ~6 lines |
| Mac window | 34 | **150** | *this card's choice* (see below) |
| accessibility text sizes (any device) | 56 | **220** | T45's floor/ceiling, kept unchanged; not an upstream number |

**Why the Mac window gets 150 and not 88.** Upstream has no Mac value, so the card had to pick one.
A Mac Catalyst window reports `UIUserInterfaceIdiom.pad` — Catalyst presents a tablet interface, and
every other part of this shell is the same code on an iPad — so 150 is the ceiling the window already
inherits, and 150 pt of a 900 pt-wide composer is still six lines. 88 was not chosen: a Mac window
would hit it after four lines and start scrolling while two thirds of the composer is visibly empty.

The class is chosen from the **idiom** (`ComposerInputHeight.deviceClass(idiom:isMacCatalyst:)`), not
from the window width: the card asks for a resized window to re-*measure* at the same cap, and a
width-derived policy would change the cap when the window is dragged narrow. The `isMacCatalyst`
check is explicit because Catalyst reports `.pad` anyway — the code should not depend on that
documented-by-accident detail.

**Why accessibility sizes keep 220.** Upstream's `maxHeight` is in dp and its input lets
`allowFontScaling` grow the *text* inside a fixed box. This shell's earlier Dynamic Type pass (T45)
raised both the floor to 56 and the ceiling to 220 so that an AX3 line (~40 pt) is not clipped by a
34 pt box. 220 holds about five AX3 lines; 150 would hold under four. This card does not touch that
pair.

## 4. Where the re-measure events come from

| event | source |
| --- | --- |
| first layout, and every width change (Catalyst window resize) | `ComposerInputTextView.layoutSubviews` — the only callback that sees either; it measures only when the width actually changed, so an applied height cannot loop |
| every keystroke | `Coordinator.textViewDidChange` → `remeasure()` |
| a programmatic edit: suggestion insert, toolbar action, **draft restore**, clear after a send | `ComposerTextView.updateUIView` → `remeasure()` |
| Dynamic Type change | `ComposerView` recomputes `ComposerInputHeight.limits(for: typeSize)`; `updateUIView` assigns the new font **first**, then `limits`, whose `didSet` re-measures |
| width change | see `layoutSubviews` |

The SwiftUI side owns the frame and nothing else:

```swift
@State private var inputHeight = ComposerInputHeight.Limits.phone.minimum
…
.frame(height: inputHeight)                       // not minHeight/maxHeight
```

`onMeasure` only writes the state when the number changed, so a layout pass cannot cost a render.
The `ComposerInputTextView` never sets its own frame height — the measure and the frame cannot
disagree.

## 5. Keeping the caret visible (the part that needed measurement)

`keepCaretVisible()` runs after every edit and scrolls `selectedRange` into view. The first version
called `scrollRangeToVisible` once. The live suite proved that insufficient, twice over:

1. **The scroll can be lost.** Driving a long `typeText` left the field at `offset=0.0` with
   `sel=len=2244` for the whole 60 s poll: the scroll ran while UIKit had not yet laid out the
   inserted tail, and nothing re-applied it. Fixed by scrolling in three places — immediately, on
   the next runloop turn, and from `layoutSubviews` when the field is **resized** while a scroll is
   owed (the resize-only condition matters: `layoutSubviews` also fires for scrolling, and
   correcting there would cancel a reader's own swipe).
2. **The scroll lands slightly short.** Once the field *was* scrolled, the seam still read
   `caret=0` with `offset=1606.3 caretMaxY=1700.7 bounds=1694.3`: `scrollRangeToVisible` fits the
   caret's **glyph line** into the container, and the caret rectangle hangs a little lower — its
   descent plus the field's 6 pt bottom inset — so the bottom 6.4 pt of the caret sat outside the
   visible rect. Fixed by nudging `contentOffset` by exactly the shortfall after the platform call,
   clamped to the scroller's own bounds (and never scrolling past the caret, which also fixes the
   stale-`contentSize` case when the view has not been laid out yet).

Evidence, same test and host, 3 iterations each:

| before the nudge | after |
| --- | --- |
| 2 of 3 failed: `caret=0 offset=1606.3 caretY=1677.0 caretMaxY=1700.7 bounds=1694.3` (`build/logs/t_fbc576a2-iter.log`) | 3 of 3 passed (`build/logs/t_fbc576a2-iter2.log`) |

## 6. What did **not** change

- `ComposerReturnPolicy` and the `shouldChangeTextIn` decision: Return sends, Shift+Return inserts a
  newline. The only change in that method is that the shift state is read from
  `parent.isShiftPressed()` (a closure with the platform default) so a unit test can substitute a
  hardware shift. Default behaviour is identical.
- `channelComposer.input` (identifier and label) and `channelComposer.send`.
- The accessibility text-size reflow (T45), the wording of the banners (T4g), uploads, autocomplete.

## 7. Tests

### Unit — `MattermostTests/ComposerInputHeightTests.swift` (21 cases, 0 failures)

They drive the production `ComposerInputTextView` (a real `UITextView` with the composer's font and
insets), so the heights are measured by UIKit, not by the test.

| requirement | case |
| --- | --- |
| T1 one line is the floor, no scroller | `testOneLineIsTheMinimumHeightAndDoesNotScroll` (phone and tablet) |
| T2 grows monotonically below the cap | `testTheFieldGrowsLineByLineAndStillDoesNotScrollAtFiveLines`, `testTheFieldAlsoGrowsOnAPhoneBelowItsLowerCap` |
| T3 past the cap is exactly the cap + scrolls | `testPastTheCapTheHeightIsExactlyTheCapAndTheFieldScrolls` (both caps) |
| T4 deleting shrinks and stops scrolling | `testDeletingBackBelowTheCapShrinksTheFieldAndStopsItScrolling` |
| T5 caret visible at the end of a capped message | `testTheCaretAtTheEndOfALongMessageIsScrolledIntoView` |
| T6 Shift+Return at the cap inserts, does not send, caret visible | `testShiftReturnAtTheCapInsertsANewlineKeepsTheCaretVisibleAndDoesNotSend`; Return still sends: `testReturnAtTheCapStillSendsAndDoesNotInsert` |
| T7 two widths re-measure | `testANarrowerWidthReMeasuresTheHeight` (drives `layoutSubviews`, the event a window resize delivers) |
| exactly at the cap / cap + 1 | `testExactlyAtTheCapDoesNotScroll`, `testOnePointPastTheCapScrolls`, and `testTheFirstLineCountPastTheCapIsOneLinePastIt` (the first real line count whose text passes 88 pt, within one line of it) |
| Dynamic Type re-measures | `testChangingTheLimitsReMeasuresTheSameText` (font + limits, as the real environment change arrives) |
| the scroll is re-applied after the runloop | `testTheCaretScrollIsRepeatedAfterTheRunloopTurns`, `testAFastBurstOfInsertionsKeepsTheCaretVisible` (caret rect strictly inside the field) |
| limits and device classes | `testTheLimitsAreUpstreamsValuesAndTheAccessibilityCeilingIsKept`, `testTheDeviceClassComesFromTheIdiomAndCatalystIsTablet`, `testTheLimitsForADeviceAndTextSize` |

**The regression the card asks for.** Reverting the switch to the original defect
(`if isScrollEnabled != next.scrolls { isScrollEnabled = false }`) and running the falsifiers gives
**2 of 3 red** — `testPastTheCapTheHeightIsExactlyTheCapAndTheFieldScrolls` ("the field has to scroll
internally past the cap") and `testTheScrollerFollowsTheMeasurementRatherThanAConstant` — with the
caret test still green (`scrollRangeToVisible` scrolls a non-scrollable text view programmatically,
which is why the caret test alone is not a sufficient falsifier). Log: `build/logs/t_fbc576a2-mutant.log`.
The mutant was reverted immediately; the tree carries the real line.

### Live — `MattermostUITests/ComposerInputHeightUITests.swift` (4 cases, 0 failures, 275 s)

Real composer, real shell, real server, real typing. Everything is read back from the production
`ComposerInputDiagnostics` seam (`-uiTestExposeComposerInputGeometry`, published as
`channelComposer.inputGeometry` with `height / content / cap / scrolls / caret / offset / sel / len /
caretY / caretMaxY / bounds`), so "the caret is visible" is the production `isCaretOnScreen` and not
a screenshot judgement.

| case | what it proves |
| --- | --- |
| `testAOneLineComposerIsTheMinimumHeightAndDoesNotScroll` | height 34, `scrolls=0`, cap 88 (an iPhone is upstream's phone class), caret on screen; `channelComposer.input` and `channelComposer.send` still exist |
| `testALongMessageStopsAtTheCapScrollsAndKeepsTheCaretVisible` | ~2 250 characters typed as one wrapping paragraph: height exactly 88, content 1 706, `scrolls=1`, caret visible — and still visible after three further characters typed at the end |
| `testALongRestoredDraftIsMeasuredAndItsCaretIsVisible` | the same message comes back from the draft store after a relaunch: restored verbatim, height still the cap, scroller on, caret visible (draft restoration re-measures) |
| `testAccessibilityTextSizesUseTheAccessibilityLimits` | launched at an accessibility text size: cap 220 and the field grows to what the AX font needs (it skips rather than passes if the simulator ignores the override — it did not: the run is green with `cap=220`) |

Log: `build/logs/t_fbc576a2-live6.log` (the suite's final green run; the earlier `-live5` log is the
same four cases before the sign-in helper was made conditional).

What the live suite deliberately does **not** claim:

- **Shift+Return** at the cap: the simulator has no hardware modifier to synthesize. The production
  path is the same `shouldChangeTextIn` the unit test drives, and this card does not change it.
- **Window resize** (T7): XCUITest cannot resize a Catalyst window reliably. The production event a
  resize delivers is `layoutSubviews` with a new width, which
  `testANarrowerWidthReMeasuresTheHeight` drives on the real view (402 → 200 pt, measuring bigger and
  publishing a new `Measurement`). A live Catalyst resize remains unproven *here*; it is the one
  acceptance item this host cannot execute.

## 8. Release

The Release proof uses the repo's own Release smoke scheme (`MattermostReleaseSmoke`, which builds
`MattermostUITests` only — the unit bundle cannot compile with testability off, so a
`-configuration Release` run of the whole scheme stops in `MattermostTests`):

    TEST_RUNNER_MM_KEEP_STATE=1 xcodebuild test -project Mattermost.xcodeproj \
      -scheme MattermostReleaseSmoke -configuration Release \
      -destination "platform=iOS Simulator,id=81A7F251-8B31-4945-8783-5A264C14B8D5" \
      -only-testing:MattermostUITests/ComposerInputHeightUITests/testALongMessageStopsAtTheCapScrollsAndKeepsTheCaretVisible

Result: **1 test, 0 failures, 89.5 s** (`build/logs` is not written by a bare `xcodebuild`; the run's
output is kept as `release8.out` in this card's scratch notes). The Release build is the one under
`…/DerivedData/mattermost-ios-release/Build/Products/Release-iphonesimulator`.

Two things the Release configuration changes, both real product behaviour rather than test scaffolding:

- `-uiTestSeedServer` / `-uiTestSeedStoredToken` / `-uiTestOpenDeepLink` are `#if DEBUG`, so a Release
  reset launch is a genuine first run: onboarding → add-server form → (login form if the vault has no
  session). `signIn` drives exactly that, conditionally — it only touches the add-server form when the
  form is actually on screen (`textFields["Server URL"]`), because `addServerToolbarButton` is shell
  chrome that exists even with a server seeded, and tapping it would leave the sheet up over the
  composer.
- `MM_KEEP_STATE=1` tells the suite to launch without `-uiTestResetPersistedState`, so the Release
  run starts on the server + session the Debug suite already established in the container (the state
  a returning reader has). Without it the add-server form's URL probe has to run first and the run is
  dominated by a first-run flow that is not this card's subject.

## 9. Files

- new: `Mattermost/UI/Native/Composer/ComposerInputHeight.swift` (the rule, the measuring text view,
  the diagnostics seam)
- new: `MattermostTests/ComposerInputHeightTests.swift`
- new: `MattermostUITests/ComposerInputHeightUITests.swift`
- changed: `Mattermost/UI/Native/Composer/ComposerView.swift` — limits passed in, measured frame
  instead of `minHeight/maxHeight`, re-measure on edit/update, the diagnostics seam, the shift
  closure
- new: this note

No parity row is added: `docs/parity/module-scan.tsv` has rows for the composer's send, drafts,
autocomplete, uploads, toolbar, preview and Return policy, but none for the input's *height*; the
behaviour it mirrors is `post_input.tsx`'s `maxHeight`, cited above.
