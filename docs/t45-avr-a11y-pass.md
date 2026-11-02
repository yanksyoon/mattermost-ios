# T45-AV-R — the AX3+ repair, measured

Repair for the FAIL verdict on T45's accessibility criterion (`docs/t45-av-validation.md`, verdict at
`0329aff`, repairs filed by `t_7de91bcf`). This note is the evidence for the seven items in the card
`t_9485f05c`; every number below was produced on this host, and every claim that could not be
measured says so.

* **Host**: iPhone 16 Pro simulator, `81A7F251-8B31-4945-8783-5A264C14B8D5`, iOS 26.5 SDK.
* **Fixture**: `http://127.0.0.1:8065`, account `perfprobe`, team `perf`, channel `T8G probe 0071`
  (`nirxhq5q37fj7c7364biok58ew`, 352 channels so the list really scrolls) and `perf/off-topic`.
* **Text size**: `xcrun simctl ui <udid> content_size …` — the *system* setting, so the app follows it
  exactly as a reader would; AX1 = `accessibility-medium`, AX3 = `accessibility-extra-large`,
  AX5 = `accessibility-extra-extra-extra-large`.
* **Contrast**: `xcrun simctl ui <udid> increase_contrast enabled|disabled`.
* **Instrument**: a temporary XCUITest (`MattermostUITests/T45AVRProbeUITests.swift`) that signs in
  once over REST, seeds the server entry + a live token (`-uiTestSeedStoredToken`), so the sign-in
  form — which cannot be driven at AX5, the password field is under the keyboard — is never needed,
  then walks list → channel → settings and runs `XCUIApplication.performAccessibilityAudit(for:
  [.textClipped])`. **The probe was created, measured and deleted**; it is not shipped.

Reproduce the whole pass with:

```
python3 scripts/qa-test.py --platform ios --sim id=<udid> --label t45avr-ax5 \
  --only-testing MattermostUITests/T45AVRProbeUITests/testSidebarCapture \
  --only-testing MattermostUITests/T45AVRProbeUITests/testChannelCapture \
  --only-testing MattermostUITests/T45AVRProbeUITests/testSettingsCapture
```

with `TEST_RUNNER_MM_A11Y_BASE` / `_LOGIN` / `_PASSWORD` / `_LABEL` / `_SHOT_DIR` in the environment
(the probe `XCTSkip`s without them).

## 1. The channel title (card item 1) — fixed, measured at AX3 and AX5

**What T45 shipped.** `.mmLineLimit(2)` + `.layoutPriority(1)` on the title, in a one-row `HStack`
with the four header glyphs. `layoutPriority` decides who gets the *line budget*, not the *width*: at
AX5 the four glyph buttons alone are wider than the row, so the title got the remainder and drew
nothing (`docs/t45-av-shots/ax5-channel.png`); at AX3 it drew `T8` / `G` / `pr…`.

**What it does now** (`Mattermost/UI/Native/Channel/ChannelView.swift`, `header`): at an accessibility
size the header **reflows** — the `#` and the title keep the first row and the four glyphs move to a
row of their own:

| size | `nativeChannelTitle` frame | drawn | audit `textClipped` |
|---|---|---|---|
| default | 153 × 20 | `T8G probe 0071`, one line | 0 |
| AX3 | 342 × 48 | `T8G probe` / `0071`, two lines, no ellipsis | **0** |
| AX5 | 325 × 125 | `T8G probe` / `0071`, three lines, no ellipsis | **0** |

Evidence: `docs/t45-av-shots/t45avr-channel-default.png`, `…-ax3.png`, `…-ax5.png`. At AX5 the glyphs
are on their own row under the title (`t45avr-channel-ax5.png`); nothing is shrunk, nothing is
ellipsised, and the title is the same size the reader asked for.

`ChannelPaneTitle`'s one-line cap also became `mmLineLimit(1)` — one line at the designed sizes,
unbounded at an accessibility size, which is the pass's own policy (`AccessibleType.swift`).

## 2. The Settings download row (card item 2) — audit clean at AX3 and AX5

**What T45 shipped.** `LabeledContent` with the path as the value and `.lineLimit(2)`. At AX3 the
label column squeezed `Download Location` into `Down-/load/Location` and the value — a sandbox path
three times the width of its column — was cut to `/Users/…/Downloads/`; the audit reported
`Text clipped` on it.

**What it does now** (`Mattermost/UI/SettingsView.swift`, `downloadLocationRow`): at an accessibility
size the row stacks — label block above the path, both at the row's full width — and the value's line
cap is gone (`.lineLimit(nil)`, `truncationMode(.middle)` still applies at the designed sizes). The
value keeps `accessibilityLabel "Download location"` + `accessibilityValue <the whole path>`, so a
narrower drawing can never hide what the row points at.

| size | `Text clipped` on the settings screen | path drawn |
|---|---|---|
| default | 0 for the row's label, 1 for the value (by design: 2-line cap + middle truncation) | `/Users/…/Downloads` truncated in the middle |
| AX3 | **0** | whole path, wrapped at `/` |
| AX5 | **0** | whole path, wrapped at `/` |

Evidence: `docs/t45-av-shots/t45avr-settings-ax3.png`, `…-settings-row-ax3.png`,
`…-settings-ax5.png`, `…-settings-row-ax5.png` (the `-row-` frames are the same screen scrolled to the
row, which is below the fold at AX3+).

**How the audit was actually satisfied — the measurement matters.** The audit's `Text clipped` on the
row's two label sentences survived every shape a SwiftUI author can give them, with **byte-identical
frames**:

| shape at AX3 | labels reported | frames |
|---|---|---|
| two loose `Text`s in a `VStack` | 2 | 181×96, 294×116 |
| `VStack` + `.accessibilityElement(children: .contain)` | 2 | 181×96, 294×116 |
| `VStack` + `children: .ignore` + short label + value | 2 | 181×96, 294×116 |
| the same two `Text`s inside `LabeledContent`'s label slot | 2 | 181×96, 294×116 |
| `LabeledContent { path } label: { … }` (two-column) at AX5 | 0 — **because the label column collapsed to zero width and drew nothing** | — |
| `LabeledContent { EmptyView() } label: { … }` at AX5 | 1 | 221×117 |
| **one `Text` (`heading + "\n" + caption`, two styles) with label + value** | **0** | — |

The frames are the *wrapped text the capture shows* (AX3's heading was even drawn on a single 296×43
line and still reported), so the finding tracks the element shape, not the drawing. What clears it is
the shape the path value already used: **one text layer carrying an explicit `accessibilityLabel` and
`accessibilityValue`**. The row's label is therefore one `Text` built with `+` (heading at
`subheadline`, explanation at `caption`, so the hierarchy is unchanged) carrying
`label "Download location"` / `value "Files are saved to the app's Downloads folder."`. VoiceOver
reads one clean sentence per row instead of three fragments, and the audit is quiet at both sizes.
The zero-audit-by-invisible-label arrangement was rejected, not copied: an audit that passes because
the label was not drawn is not evidence.

## 3. The sidebar (card item 3) — five real captures, and what they found

All five captures show the channel list itself: window chrome, team rail, WORKSPACE block, channel
rows, tab bar. Files (in `docs/t45-av-shots/`):

| file | size | what to look at |
|---|---|---|
| `t45avr-sidebar-default.png` | default | WORKSPACE + `+` on one row, `Local Mattermost`, `Perf`, Threads 3, Jump to a channel…, WEB VIEW, T8G rows, tab bar |
| `t45avr-sidebar-ax1.png` | AX1 | the same, one step up |
| `t45avr-sidebar-ax3.png` | AX3 | WORKSPACE block reflowed (`+` under the title), `Local` / `Mattermost`, `Threads` on one line with the badge under it |
| `t45avr-sidebar-ax5.png` | AX5 | the same at the largest size; `docs/t45-av-shots/t45avr-sidebar-rows-ax5.png` is one screen further down (WEB VIEW, Boards, Playbooks, System Console) |
| `t45avr-sidebar-increase-contrast.png` | default + Increase Contrast | the same list with the setting on |

**What the captures found, and the fixes** (all in `Mattermost/UI/Native/Sidebar/ChannelSidebarView.swift`
unless noted):

* `WORK-/SPACE` at AX5 — the section header kept `Text` and the 44 pt `+` on one row, leaving ~215 pt
  for an upper-cased nine-letter word. At an accessibility size the header now stacks (`+` under the
  title).
* `Thre-/ads` at AX5 — even with the badge moved below the title, the inline glyph left ~245 pt for a
  seven-letter word needing ~280. At an accessibility size the Threads row's title is drawn without
  the inline glyph (full width); the row still announces "Threads" through its
  `.accessibilityRepresentation`.
* `Local Matterm…` at AX5 (`Mattermost/UI/Native/NativePanePlaceholders.swift`) — the server row had a
  hard `.lineLimit(2)`; it now uses `mmLineLimit(2)` (three lines at an accessibility size), so
  `Local` / `Matter-most` is drawn whole. **Hyphenation stays here and on long channel names**
  (`Play-books`, `System Con-sole` at AX5): a single word wider than the row is hyphenated by
  SwiftUI's line breaker rather than truncated. Every character is drawn and there is no ellipsis;
  the alternative would be shrinking the reader's chosen size, which the pass does not do.

Two `Text clipped` findings remain on the sidebar at every size, including the default one, and they
are **pre-existing shapes from T8e, not this card**:

* `nativeSidebar` — the anchor row hands VoiceOver a `.accessibilityRepresentation { Text(server.name) }`;
  the audit measures that representation against the row (306 × 207 at AX5) although the drawn text is
  complete in the capture.
* `channelSidebar.workspaceHeader` — `.textCase(.uppercase)` re-renders `Workspace` as `WORKSPACE`,
  so the audit compares the upper-cased label with a frame laid out for the lower-cased word. The
  capture shows the word complete.

Both are recorded here rather than "fixed" by changing what the row says.

## 4. Increase Contrast (card item 4) — the three targets, with the setting on and off

`ContrastPolicy` reads `colorSchemeContrast` in exactly three places: the date separator rule
(`separatorOpacity(0.18) → 0.396`, i.e. ×2.2 clamped at 1), the markdown quote bar and the code-block
border (`borderWidth(1) → 1.5`). The captures put all three in frame, once with the setting **on** and
once **off**, on the same channel and the same post:

* `docs/t45-av-shots/t45avr-contrast-top-on.png` / `…-top-off.png` — `Sunday, October 25, 2026`
  between its two rules: the rules are visibly darker with the setting on.
* `docs/t45-av-shots/t45avr-contrast-posts-on.png` / `…-posts-off.png` — the blockquote's vertical bar
  and the fenced code block's border on the seeded post (`# T45-AV-R contrast probe` … a quoted line
  and a `swift` block), same scroll position.

The post was seeded through the API (`scripts/qa-test.py` not involved; the seed script is a scratch
file, the post `wixfukt1ijdt7fcc5ricgz71dh` lives in `perf/off-topic`), because the fixture's
`off-topic` had no quote or code block to measure.

## 5. The scan can see the app's own button shape (card item 5) — mutation-proven

`scripts/t45_a11y_inventory.py`'s `unnameable_buttons()` used to slice from the first `{` after
`Button` to its *action* closure's `}`, so `Button { … } label: { Image(systemName: …) }` — the shape
every toolbar glyph in this app uses (`RootView.swift:66-92`) — was never inspected. It is now
brace-balanced: the scan finds the `label:` closure, and if there is none, the trailing closure.

Measured with a probe file (`Mattermost/UI/Native/Composer/T45AVRProbe.swift`, **created, measured,
deleted**) containing exactly one unnamed glyph button:

```
unnamed glyph buttons          2
RESULT: FAIL — 2 unnamed glyph buttons      (exit 1)
```

(the probe's `Button` *and* an inner `Button`-shaped `Image` closure are both reported — the gate no
longer has to guess which closure it is looking at). With the probe deleted: `RESULT: PASS`, exit 0,
`unnamed glyph buttons 0`. The checked-in manifest carries `unnamed_buttons: []`, so
`T45A11yInventoryTests.testNoIconOnlyButtonIsUnnamed` fails on the same shape without the probe file.

## 6. Reduce Motion and the one-line cap are gated (card item 6) — mutation-proven

Both were printed and never failed. Now `--check` exits non-zero when an animation site does not
consult `accessibilityReduceMotion`, and when a bare `.lineLimit(1)` sits on scaling text outside the
documented three (a count badge, an avatar initial, and a fixed rail cell — all drawn inside a fixed
box, none able to truncate). Each violation is reported by file and fragment, and an exemption that
stops matching a site is itself a failure (`stale_line_limit_exemptions`), so the gate cannot rot into
a list of dead allowances.

Probes, each created alone, measured, and deleted:

| probe | shape | `--check` (exit 1) |
|---|---|---|
| A | `Button { … } label: { Image(systemName: "paperplane") }` with no label | `RESULT: FAIL — 2 unnamed glyph buttons` |
| B | `withAnimation(.easeOut(duration: 0.3)) { … }` with no Reduce Motion read | `unguarded animation Mattermost/UI/Native/Composer/T45AVRProbe.swift:12` / `RESULT: FAIL — 1 animation sites that do not consult Reduce Motion` |
| C | `Text("…long…").lineLimit(1)` on scaling text | `bare lineLimit(1) Mattermost/UI/Native/Composer/T45AVRProbe.swift:10` / `RESULT: FAIL — 1 bare .lineLimit(1) sites outside the documented three` |

With the probes removed the same command prints `RESULT: PASS` and:

```
font sites (fixed points)     35  {'composer': 10, 'channel': 6, 'settings': 2, 'thread': 1}
  exempt by design             6
  glyph geometry (by rule)    29
  unowned (not T45's files)    0
  UNEXPLAINED text             0
Dynamic Type conversions      48 text, 25 symbols, 3 columns
variable line limits          18
bare lineLimit(1) left         3  (3 exempt, 0 unexplained)
unnamed glyph buttons          0
animation sites                5 (5 consult reduce motion)
accessibilityReduceMotion      5
colorSchemeContrast            3
accessibilityLabel            99
accessibilityHint              4
accessibilityIdentifier      478
```

`EXCLUDED_FILES` names the files T45 does not own (per `docs/parallel-work.md` §6) instead of
pretending they are clean, and `--check` prints every unexplained site by file and line.

## 7. The VoiceOver claim (card item 7) — corrected, not replaced

`MattermostTests/T45A11yTests.swift` cited `MattermostUITests/T45A11yUITests.swift`, which does not
exist and never did. The reference is gone; the file now says what is true: no test in this repository
covers what a screen *looks* like or what VoiceOver *says*, the captures are the visual evidence, and
a VoiceOver pass is a manual/assistive procedure this host cannot run (there is no supported way to
read spoken output back from a headless simulator).

## What is not fixed, stated plainly

* **Hyphenation of words wider than the row** (AX5: `Matter-most`, `Play-books`, `System Con-sole`).
  Nothing is truncated and no ellipsis is drawn; preventing it would mean shrinking the reader's text
  or dropping to one line per row.
* **Two `Text clipped` findings on the sidebar** — both are T8e's element shapes (a
  `.accessibilityRepresentation`, and `.textCase` on a header), both drawn in full in the captures,
  and both present at the default size as well, i.e. not introduced here.
* **The settings screen still has one `Text clipped` at the default size**: the path, by design —
  two lines with a middle ellipsis, with the whole path in the row's `accessibilityValue`. The card's
  criterion was AX3/AX5.
* **A VoiceOver run.** Not executed. Nothing here claims otherwise.
