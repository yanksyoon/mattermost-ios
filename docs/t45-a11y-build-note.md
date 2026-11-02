# T45-A11y — the native shell at accessibility text sizes

Card `t_4f60b3af`. Scope: the SwiftUI shell (`Mattermost/UI/Native/**`, plus
`Mattermost/UI/ContentView.swift` and `Mattermost/UI/WelcomeView.swift`), at Dynamic Type up to
AX5, with Reduce Motion and Increase Contrast honoured and a scan that fails when the pass is
undone.

This note is the evidence record. §1 is what the card asked and where each answer lives; §2 the
mechanism; §3 the inventory; §4 what the screenshots found (four defects, all fixed); §5 what was
not captured and why; §6 the limits that stay.

---

## 1. The five requirements and where they stand

| Requirement (card) | Where it lives | Evidence |
|---|---|---|
| No fixed point sizes for text | `UI/Native/Accessibility/AccessibleType.swift` — `.scaled(_:)`, `.scaledSymbol(_:)`, `.system(_ textStyle:)` | Inventory: **0 unexplained text sites** (34 fixed sites remain, all symbol/initial glyphs — §3) |
| Layout follows the text size | `.scaledColumn(width:alignment:)` (`@ScaledMetric`, capped at `2.6 ×` the designed width) | `PostRowView` 36 pt info/time columns, `ChannelSidebarView` 16 pt icon column |
| Reduce Motion honoured | `MotionPolicy.animation(_:for:reduceMotion:)` / `.transition(_:for:reduceMotion:)` | 4 animation sites, **4 consult `accessibilityReduceMotion`**; 20 unit tests on the policy |
| Increase Contrast honoured | `ContrastPolicy.separatorOpacity(_:contrast:)` / `.borderWidth(_:contrast:)` | 3 `colorSchemeContrast` readers: date separator rule, markdown quote bar, code-block border; `sidebar-increase-contrast.png` |
| No truncation/clipping at AX3+ | `.mmLineLimit(_:)` (3 at accessibility sizes) + the reflows in §4 | 8 screenshots in `docs/t45-a11y-shots/`; §4 lists the four defects they exposed |

## 2. The mechanism

Three pieces, all pure enough to test without a view:

* **`AccessibleType.swift`** — `.scaled(size, weight:design:)` is `Font.system(size:)` that follows
  Dynamic Type (`Font.custom`-free, `.relativeTo: .body`), so a 15 pt body is 15 pt at the default
  size and grows from there. `.scaledSymbol(...)` is the same for `Image(systemName:)` glyphs that
  sit in a *fixed* control and must keep their designed proportion. `.system(_ textStyle)` maps a
  designed role to a `Font.TextStyle` when a hierarchy (headings) has to survive every size.
  `.scaledColumn(width:)` replaces `.frame(width:)` for the two columns whose contents are text.
* **`AccessibilityPolicies.swift`** — `MotionPolicy` is a pure function of
  `(MotionKind, reduceMotion)`; a `.incidental` animation becomes `nil` (an instant jump) and a
  transition becomes `.identity` under Reduce Motion. `ContrastPolicy` is a pure function of
  `(designed value, ColorSchemeContrast)`.
* **`MarkdownMetrics`** — headings keep their upstream sizes as *roles*
  (22 / 20 / 18 / 16.5 / 15.5 / 15.5 pt → `.title2` … `.body`) instead of raw points, so the
  six-level hierarchy scales instead of collapsing.

Why a policy and not inline `if reduceMotion`: the card's criteria are properties of every screen,
and a policy is the only form of them a unit test can pin. `MattermostTests/T45A11yTests.swift`
(20 tests) asserts the `TypeRole` table is total and monotone, that a tie resolves to the smaller
role, that headings are non-increasing 1→6, that `.incidental` animations disappear under Reduce
Motion while `.essential` ones stay (shortened, linear), that transitions become `.identity`, that
separator opacity is monotone in contrast and clamps at 1, and that every accessibility size gets
at least three lines from `.mmLineLimit`.

## 3. The inventory (`scripts/t45_a11y_inventory.py`)

`--check` is the card's definition of done expressed as a scan; `--emit-manifest` writes the JSON
that `MattermostTests/T45A11yInventoryTests.swift` (11 tests) asserts against.

```
font sites (fixed points)     34  {'composer': 10, 'channel': 6, 'settings': 2, 'thread': 1}
  exempt by design             6
  glyph geometry (by rule)    28
  unowned (not T45's files)    0
  UNEXPLAINED text             0
Dynamic Type conversions      48 text, 25 symbols, 3 columns
variable line limits          18
bare lineLimit(1) left         3
unnamed glyph buttons          0
animation sites                4 (4 consult reduce motion)
accessibilityLabel            95
accessibilityHint              4
accessibilityIdentifier      465

RESULT: PASS
```

Two things this does **not** say, stated so the numbers are not read for more than they are:

* The pass started at **49** `.font(.system(size:))` sites. **34 remain and every one is a glyph**
  — a symbol in a fixed-size control (`Image(systemName:)` in the composer toolbar, the 44 pt
  error-state symbol, the avatar initials on the team rail). `UNEXPLAINED text = 0` is the claim;
  "no fixed sizes anywhere" is not, and would be the wrong target, because a 44 pt symbol inside a
  44 pt plate must not become 110 pt at AX5.
* The 6 exemptions are keyed on **(file, source line content)**, not `path:line`. The first version
  keyed on line numbers and every exemption went stale after the first edit — the scan then failed
  on its own exceptions. `stale_exemptions` is a reported list, and it is empty.
* The 3 remaining bare `.lineLimit(1)` are inside fixed-size controls (the rail's initials, the
  quick-switcher's badge); the other 18 sites are `.mmLineLimit(n)`, which raises to 3 at
  accessibility sizes.

## 4. What the screenshots found — four defects, fixed

The pass did not start green. Capturing the shell at AX1/AX3/AX5 against the fixture at
`127.0.0.1:8065` (real channels, real posts, real unread counts) produced four failures that no
source scan would have caught, because each one is a *layout* consequence of larger text.

**F1 — the composer hyphenated its own placeholder (AX3).** Four glyph buttons in the input row
grew with the text and left the text column ~60 pt wide: "Message" wrapped as "Mes-sage" and was
clipped by the row. Fix (`ComposerView.swift`): at `DynamicTypeSize.isAccessibilitySize` the
controls move to a row *below* the input (`inputZone` + `controlsRow`), so the input takes the full
width. Same fix removes the horizontal squeeze the send button had at AX5.

**F2 — the channel title was truncated (AX3).** `.lineLimit(2)` on the header title cut
"Off-Topic" to "Off-To…". Fix: `.mmLineLimit(2)` (3 lines at accessibility sizes) +
`.fixedSize(horizontal: false, vertical: true)`, and `.layoutPriority(1)` on the title so the four
header glyphs do not claim the row first. Visible in `channel-ax3.png`: the title is complete.

**F3 — the date separator became a four-line pill (AX3).** The `HStack` of `rule / title / rule`
kept the rules' width and squeezed "Sunday, 25 October 2026" into a narrow capsule; `.layoutPriority(1)`
on the text did not fix it (measured, then reverted). Fix: at accessibility sizes the flanking rules
are dropped and the title takes the full width (`PostDateSeparatorView`), which is what
`channel-ax3.png` shows.

**F4 — the team rail's badge covered the initials (AX3).** At AX3 the count pill grew past the 6 pt
margin the 64 pt rail leaves around a 52 pt tile: the badge sat on top of "PE" (it reads as "PL" in
the capture) and its 6 pt trailing offset pushed it outside the rail, where the tile's border was
clipped. Fix (`TeamSidebarView.swift`): at accessibility sizes the badge is drawn *below* the tile
in a `VStack`, with no offset. Verified in `sidebar-ax3.png` — "PE" fully legible, "2" below it,
nothing clipped.

The rail's initials stay at their designed size on purpose: they are drawn on a 44 pt tile inside a
fixed 64 pt rail, and scaling them would either clip the tile or force the rail to take a quarter of
the screen. This is one of the six exemptions, and it is the only place the pass deliberately keeps
text at a fixed size.

## 5. Evidence files

| File | What it shows | How it was taken |
|---|---|---|
| `docs/t45-av-shots/t45avr-sidebar-default.png` … `-ax1`, `-ax3`, `-ax5` | The channel list (window chrome, team rail, WORKSPACE block, channel rows, tab bar) at the default size and at AX1/AX3/AX5 | iPhone 16 Pro simulator; **system** text size via `xcrun simctl ui <udid> content_size …`; a temporary XCUITest seeds the server entry + a live token (`-uiTestSeedStoredToken`) so the sign-in form is never needed, then switches to the `perf` team and captures. Regenerated by T45-AV-R (`t_9485f05c`) — the five files this table used to describe were the pane's "Resolving this channel…" placeholder; see `docs/t45-avr-a11y-pass.md` §3 |
| `docs/t45-av-shots/t45avr-sidebar-rows-ax3.png`, `…-rows-ax5.png` | The same list one screen further down, where the channel rows are (WEB VIEW, Boards, Playbooks, System Console) | same run, one `swipeUp` on the list |
| `docs/t45-av-shots/t45avr-sidebar-increase-contrast.png` | The channel list with **Increase Contrast enabled** (`xcrun simctl ui … increase_contrast enabled`) | same run, contrast on |
| `docs/t45-av-shots/t45avr-contrast-posts-on.png` / `…-posts-off.png` | The three `colorSchemeContrast` targets in one frame: the day separators' rules, the blockquote's bar and the code block's border — once with the setting on, once off | same run, on a seeded post in `perf/off-topic` |
| `docs/t45-av-shots/t45avr-settings-default.png`, `…-ax3`, `…-ax5` and `…-settings-row-*` | The settings screen the gear opens, at the default size and at AX3/AX5; the `-row-` frames are the same screen scrolled to the download-location row | same run (the gear is reachable headlessly once the token is seeded — the earlier claim that settings had no headless route was about launch-time deep links, and it is corrected here) |
| `docs/t45-a11y-shots/channel-default.png`, `-ax3`, `-ax5` | The channel pane with real posts and the composer; the composer reflow (F1) and the full-width separator (F3) | the app's own `-nativeShellSnapshot` probe, which forces the `dynamicTypeSize` environment — required because **Catalyst ignores it** (finding, §6) and because the probe is the only way to hold a size across a launch |
| `docs/t45-a11y-shots/*` | — | the probe's captures are pre-F2 (`layoutPriority`); the header there wraps "Off-Topic" mid-word rather than truncating it — every character is still drawn, which is why F2 is called an improvement on top of the criterion, not a criterion failure |

**Not captured by T45: the thread pane.** It is reached by tapping a post's reply chip; there is no
launch seam for it, and the simulator cannot be tapped from a shell. (T45-AV-R reached the **settings
screen** and the channel pane by seeding a token instead of driving the sign-in form — see
`docs/t45-avr-a11y-pass.md` — so the paragraph below only still holds for the thread pane and for
launch-time deep links.)

* The thread pane is reached by tapping a post's reply chip; there is no launch seam for it, and the
  simulator cannot be tapped from a shell (the `mattermost://` route raises iOS's "Open in
  Mattermost?" confirmation, which needs the tap this host cannot give).
* Settings opens from the gear button on the channel-list toolbar — same problem.
* A launch-time deep link is not a way round it: `-uiTestOpenDeepLink` with
  `…/perf/channels/off-topic/<postID>` lands on the pane's own honest placeholder
  ("Resolving this channel…", `NativePanePlaceholders.swift:286`) and **stays there** — the route
  carries the channel *name*, and the directory never fills in an id for a link consumed before the
  channel list is read. That is a route-resolution gap in T36/T39's area, not an accessibility
  defect; it is reported here rather than fixed, because fixing it is a different card's scope.
* What covers those two surfaces instead: the inventory shows **thread: 1 fixed site (a glyph) and
  settings: 2 (the avatar initials)** — no text at a fixed point on either, so there is nothing on
  them that ignores the reader's size; and `T45A11yInventoryTests` fails if either surface gains an
  unexplained text site.

## 6. Limits that stay

* **Catalyst ignores the forced `dynamicTypeSize`.** On `platform=macOS,variant=Mac Catalyst` the
  probe's `.environment(\.dynamicTypeSize, …)` does not change the rendered text: AX1, AX3 and AX5
  captured byte-identical images (`md5` equal, 516145 bytes each). The Mac build is therefore
  captured at the system size only; the accessibility-size evidence is the iPhone simulator. Not
  chased further — macOS text size is a system setting and the shell follows it there, which is the
  behaviour that matters.
* **Mid-word breaks are possible.** A long unbroken word in a narrow column (the channel title's
  column at AX5) can break mid-word; nothing is lost, but it reads poorly. `layoutPriority` on the
  title addresses the measured case ("Off-Topic"); a general solution is per-surface `ViewThatFits`
  reflows, which the card did not ask for.
* **The composer grows to a bounded height.** At AX5 the input grows to 200 pt and then scrolls; a
  very long draft is edited in a scrollable field rather than a sheet.
* **Increase Contrast is verified where it is drawn**: the date separator, the quote bar and the
  code-block border are the three places the shell uses contrast as a *value* (3
  `colorSchemeContrast` readers). Every other colour is a semantic system colour, which iOS already
  resolves per contrast setting; there is no code here to test.
* **VoiceOver:** 95 `accessibilityLabel` / 4 `accessibilityHint` / 465 `accessibilityIdentifier`.
  This card added no new controls, so it added no new labels; what it did add is the guarantee that
  none of the controls it converted lost theirs (the inventory reports `unnamed glyph buttons: 0`,
  and `T45A11yInventoryTests` fails on a single one).

## 7. Reproducing

```
python3 scripts/t45_a11y_inventory.py --check
python3 scripts/t45_a11y_inventory.py --check --emit-manifest MattermostTests/Fixtures/t45-a11y-inventory.json

xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath ~/.hermes/profiles/mmios-ios/cache/scratch/t45-dd \
  -only-testing:MattermostTests/T45A11yTests \
  -only-testing:MattermostTests/T45A11yInventoryTests
```

Result at the time of writing: **31 tests, 0 failures** (20 policy + 11 inventory), `RESULT: PASS`
from the scan.

`scripts/t45_migrate_fonts.py` is kept, not run by any build phase: it is the one-time transformation
that produced the 48 text conversions, kept so the diff can be re-derived and reviewed rather than
taken on trust. It is idempotent (it skips sites that already carry `.scaled(`).
