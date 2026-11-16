# t_bc22d0b3 — the header's account control: last in the cluster, one toolbar

The account menu button was drawn *between* the channel-info and pinned glyphs, in a 34 pt frame
holding a 28 pt avatar, in a row that baseline-aligned its children. Four separate defects, one
visible symptom: the row read as "slightly off".

This note records what was changed, the numbers the row is now built from, and how each of them was
*measured* rather than eyeballed. It also records, plainly, the one thing that could not be run on
this host (the live XCUITest suite) and why.

---

## 1. What was wrong

| # | Defect | Where it was | What it is now |
|---|--------|--------------|----------------|
| 1 | Order | `AccountMenuControl` between the info glyph and the pinned glyph | last item in the cluster, after Threads |
| 2 | Optical weight | 28 pt avatar in its own 34 pt frame beside ~17 pt glyphs with *no* frame | every control in the same 32 pt frame; avatar is a 20 pt disc inside it |
| 3 | Alignment | controls flattened into the title's `HStack(alignment: .firstTextBaseline)` | one explicit cluster, `HStack(alignment: .center)` |
| 4 | Two badges, one corner | presence dot and custom-status emoji placed by two independent `alignment:` + `offset:` pairs, one of which sat 4 pt outside the picture | four rectangles from one place (`AccountMenuControlLayout`), dot bottom-trailing, emoji top-trailing |

Upstream reference: `webapp/channels/src/components/global_header/right_controls/right_controls.tsx`
renders `PlanUpgradeButton`, `AtMentionsButton`, `SavedPostsButton`, `Pluggable`, the tour,
`SettingsButton`, then **`UserAccountMenu`** — the far-right item, never in the middle of the icon
run. Upstream's trigger (`user_account_menuButton.tsx`) draws the custom-status emoji *and* the
presence mark at once (a `CustomStatusEmoji` beside the avatar plus a `userStatusIconWrapper` holding
a 16 px status icon); it can afford two marks side by side because its trigger is wider than 32 px.

**Decision on the two badges:** both are drawn, one per corner — presence at the bottom-trailing
(the corner every avatar in this app uses), custom status at the top-trailing. Replacing the dot with
the emoji would have been the other allowed option, but upstream does not replace it: it shows both,
in a wider control. Keeping both is the closer port, and the two marks are 9.5 pt apart at the
nearest edges — measured, not asserted (§3.2).

## 2. The numbers

`ChannelHeaderMetrics` (`Mattermost/UI/Native/Channel/ChannelHeaderMetrics.swift`):

| Constant | Value | Why |
|----------|-------|-----|
| `controlSide` | **32 pt** | one frame for every control; it is also the hit target (card minimum: 28) |
| `controlSpacing` | **6 pt** | the one gap between adjacent controls |
| `glyphPointSize` | **17 pt** | the body size the four glyphs were already drawn at; their symbol box is ~17×17 |
| `horizontalPadding` | **16 pt** | SwiftUI's default for `padding(.horizontal)`, spelled out so the trailing gap is a number a test can assert |

`AccountMenuControlLayout` (`Mattermost/UI/Native/Account/AccountMenuLayout.swift`):

| Rect | Value (control space, origin top-leading) | Why |
|------|-------------------------------------------|-----|
| avatar | `(6, 6, 20, 20)` | 20 pt disc against a ~17 pt glyph box = 1.18×, the ratio upstream's web header uses (24 px avatar beside ~20 px icons); the old 28 vs 17 was 1.65× |
| presence dot | `(22.5, 22.5, 7, 7)` | centre on the avatar's bottom-trailing corner, half hanging past the disc |
| custom-status badge | `(19, 0, 13, 13)` | top-trailing, wholly inside the frame; 13/20 is upstream's 14 px emoji on a 24 px avatar |
| separation | **9.5 pt** | `dot.minY − badge.maxY`; the unit test pins ≥ 6 |

The marks are placed with **padding**, not `offset`. `offset` is a drawing transform: the rect that
lays out (and that any measurement sees) would stay at the container's origin while the pixels moved
— which is precisely how a "looks right" layout drifts unnoticed. With padding, the drawn rect and
the measured rect are the same rectangle.

## 3. What was measured

### 3.1 The row (regular width, real Catalyst build)

Method: the app reports its own laid-out rects through `-uiTestExposeHeaderGeometry`
(`channelHeader.geometry`, also logged as `Tbc22d0b3: header geometry …`), captured from a real run
of this branch's build against the fixture server (`perf` team, `#off-topic`, pane width 1010 pt).

```
padding=16.0 space=channelHeader controlSpace=accountMenuControl side=32.0
header=320.0,201.0,1010.0,56.5
nativeChannelInfoButton=810.0,12.2,32.0,32.0
nativeChannelPinnedButton=848.0,12.2,32.0,32.0
calls.joinButton=886.0,12.2,32.0,32.0
nativeChannelThreadsButton=924.0,12.2,32.0,32.0
accountMenuButton=962.0,12.2,32.0,32.0
accountMenu.avatar=6.0,6.0,20.0,20.0
accountMenu.presenceDot=22.5,22.5,7.0,7.0
accountMenu.customStatusEmoji=none
```

* **Order** — `minX` 810 → 848 → 886 → 924 → 962, i.e. channel-info → pinned → Calls → Threads →
  **account**, which is also source order and upstream order.
* **Alignment** — every control is 32 pt tall with `minY` 12.2, so every `midY` is **28.2 pt**.
  Spread: **0.0 pt** (test tolerance 1).
* **Spacing** — frame-to-frame gaps 848−842, 886−880, 924−918, 962−956 = **6.0 pt each**. Spread 0.0.
* **Trailing gap** — last control ends at 994, header is 1010 wide: **16.0 pt**, equal to
  `padding`. Nothing is drawn to the right of the account control but the header's own padding.

### 3.2 The badges (custom status set on the server: `grinning`, "tbc22d0b3 header")

```
accountMenu.avatar=6.0,6.0,20.0,20.0
accountMenu.presenceDot=22.5,22.5,7.0,7.0
accountMenu.customStatusEmoji=19.0,0.0,13.0,13.0
```

* Dot and badge do **not** intersect: the badge ends at y = 13, the dot starts at y = 22.5 →
  **9.5 pt apart**, on opposite corners.
* Both are inside the 32 pt control (`badge.maxX` 32, `dot.maxY` 29.5). Before this card the emoji was
  offset to 32 in a 28 pt box; now its frame *is* inside the control.
* The avatar is 20 pt and both marks hang over it (the dot's centre is exactly its bottom-trailing
  corner, 26,26).

### 3.3 Pixels, from the app's own `drawHierarchy` capture

`-nativeShellSnapshot` writes window PNGs at 2× (2660×1996). Scanning the header band
(y 405…505 px) for ink runs, x 2200…2660 px:

| capture | run widths (pt) | ink gaps (pt) | last ink → right edge |
|---------|-----------------|---------------|-----------------------|
| no custom status | info 17.0, pin 13.0, phone 15.5, threads 18.5, avatar+dot 23.5 | 23.0, 24.0, 21.0, 18.5 | **18.5 pt** |
| custom status set | info 17.0, pin 13.0, phone 15.5, threads 18.5, avatar+marks 26.0 | 23.0, 24.0, 21.0, 18.5 | **16.0 pt** |

Reading the numbers honestly:

* the **frame** gaps are 6.0 pt each (§3.1); the *ink* gaps differ (18.5–24 pt) because glyphs have
  different ink widths inside identical 32 pt frames (the pin is 13 pt of ink, the thread bubble
  18.5) — that is expected and is not a spacing defect;
* the **trailing** distance is exactly the 16 pt padding when a custom status is set, because the
  emoji badge reaches the control's trailing edge (x = 32); without one the last ink is the presence
  dot, which stops 2.5 pt inside the frame → 18.5 pt from the edge;
* avatar + dot ink is 23.5 pt = the 20 pt disc plus the 3.5 pt of dot hanging past it, and with the
  emoji the union is 26.0 pt = 32 − 6, which is the 20 pt disc plus the badge's overhang. Both match
  the rects in §3.2 to 0.5 pt;
* vertical: glyph ink centres land at 458.0–458.5 px and the avatar's at 458.4 px → **within
  0.5 pt**, i.e. the centre line the seam reports is the centre line on screen.

Screenshots (2× crops of the header row, `docs/`):

* `docs/tbc22d0b3-header-regular.png` — no custom status, account control last, dot at the disc's
  bottom-trailing corner.
* `docs/tbc22d0b3-header-custom-status.png` — custom status set: emoji top-trailing, dot
  bottom-trailing, clearly separate.

Reproducing §3.3: `scripts/tbc22d0b3_measure.swift` reads a capture and prints the ink runs and gaps
(`swift scripts/tbc22d0b3_measure.swift <png> <y0> <y1> <x0> <x1> <scale>`); its header comment holds
the launch arguments that produce the capture.

## 4. Tests

`MattermostTests/Tbc22d0b3HeaderGeometryTests.swift` — 7 unit tests, green on this host:

```
tests      : 7 run, 0 skipped, 0 failed
log        : build/logs/tbc22d0b3-units.log
```

They pin the arithmetic the row is built from: one frame for every control, an avatar at 1.0–1.3×
the glyph box (the defect was 1.65×), the avatar centred, the dot straddling the disc's
bottom-trailing corner, the badge on the trailing half inside the frame, and the two marks in
different corners with ≥ 6 pt between them.

`MattermostUITests/Tbc22d0b3HeaderClusterUITests.swift` — the five live assertions the card asks for
(order by `minX` **and** by accessibility order, one `midY`, equal gaps + the trailing gap equal to
the padding, badge separation, accessibility order and the trigger's status value). They read the
four glyph controls' frames from the OS and the badges/header from the seam.

### The live suite could not be run on this host

`xcodebuild` builds the UI-test bundle, then the runner never starts:

```
MattermostUITests-Runner (85474) encountered an error (The test runner hung before establishing connection.)
** TEST FAILED **            (rc=65, 479 s)
```

The cause is not this change: `/usr/sbin/DevToolsSecurity -status` says
`Developer mode is currently disabled`, and the simulator run needs
`DTServiceHubClient` to bless the runner (`unable to connect to
"com.apple.instruments.deviceservice.lockdown" … failed to bless service hub`). Enabling it needs
`sudo DevToolsSecurity -enable && sudo xcodebuild -runFirstLaunch`, and this session has no sudo
(`sudo -n true` → `a password is required`). So **no** XCUITest suite ran here, including the
existing `T41ProfileUITests`, `T429ProfileTapUITests`, `TModalDismissUITests` and the composer/header
suites — not because they fail, but because no UI test can start on this host until developer mode is
switched on. What that leaves:

* the geometry the live tests assert was measured directly from a real build instead (§3.1–3.3),
  through the same seam the live test reads;
* the identifiers those suites address are unchanged —
  `accountMenuButton`, `nativeChannelInfoButton`, `nativeChannelPinnedButton`,
  `nativeChannelThreadsButton`, `calls.joinButton` all still exist and are still the controls' own
  identifiers (`grep` them in the diff: only `.trailingControl(...)` / `.headerGeometry(...)`
  modifiers and the moved account block are added);
* `Scripts/qa-test.py --platform mac --only-testing MattermostTests` (the full unit suite) was run for
  regressions from the header's padding/alignment change:

```
run        : tbc22d0b3-full-units
outcome    : finished (xcodebuild rc=0, 171s)
tests      : 2672 run, 15 skipped, 0 failed
log        : build/logs/tbc22d0b3-full-units.log
```

**What a reviewer on a host with developer mode should run:**

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
python3 scripts/qa-test.py --platform ios --sim <sim> \
  --only-testing MattermostUITests/Tbc22d0b3HeaderClusterUITests   # the five new assertions
  --only-testing MattermostUITests/T41ProfileUITests \
  --only-testing MattermostUITests/T429ProfileTapUITests \
  --only-testing MattermostUITests/TModalDismissUITests            # the identity-surface suites
```

## 5. Adversarial checks (the mutations the card asks for)

Each mutation was applied, built, and measured; then reverted.

| Mutation | Result |
|----------|--------|
| Account control moved back between the info and pinned glyphs | seam: `info=810, account=848, pinned=886, calls=924, threads=962` → axis order ≠ source order and the account control is not last → **order assertion red** |
| Shared frame removed and the cluster reverted to `firstTextBaseline` | seam: glyph `midY` 25.0 / 25.25 / 25.25 / 25.25 vs avatar **28.2** → a **3.0 pt** drift against a 1 pt tolerance → **alignment assertion red** |
| Both badges moved to the top-trailing corner | unit tests: **6 assertion failures**, e.g. `presence (25.0, 0.0, 7.0, 7.0) and the custom-status badge (19.0, 0.0, 13.0, 13.0) must not overlap` and `0.0 is less than 6.0 - less than 6 pt apart` (`build/logs/tbc22d0b3-mutation-badges.log`) |

The first two are view-level defects, so they are caught by the seam measurement the live test reads
(and by pixel measurement of the captures: the mutated build's avatar sat 3 pt lower than the glyph
row); the third is caught by the unit tests outright.

## 6. Files

| File | What changed |
|------|--------------|
| `Mattermost/UI/Native/Channel/ChannelHeaderMetrics.swift` (new) | the cluster's numbers, the `trailingControl` / `headerGeometry` modifiers, `ChannelHeaderFramesKey`, `ChannelHeaderGeometrySeam`, `-uiTestExposeHeaderGeometry` plumbing |
| `Mattermost/UI/Native/Channel/ChannelView.swift` | `header` centre-aligns and owns one explicit `trailingCluster`; `trailingControls` reordered (account last) and every glyph put in the shared frame; `headerFrames` state + seam; `ChannelUITestHook.exposesHeaderGeometry`; the account control's doc comment corrected |
| `Mattermost/UI/Native/Account/AccountMenuLayout.swift` (new) | `AccountMenuControlLayout`: the four rectangles, the sizes, and the badge-separation property |
| `Mattermost/UI/Native/Account/AccountMenuView.swift` | the trigger drawn from those rectangles (padding-placed, not offset-placed); badge sized from the layout; the file-header comment that claimed "the same corner upstream puts it in" now states that it is the last item in the right-hand cluster |
| `Mattermost/UI/Native/Calls/CallsJoinEntry.swift` | the Calls button takes the cluster's frame/glyph weight on the button itself, so "no Calls plugin" leaves no empty 32 pt slot in the row |
| `MattermostTests/Tbc22d0b3HeaderGeometryTests.swift` (new) | 7 unit tests over the layout arithmetic |
| `MattermostUITests/Tbc22d0b3HeaderClusterUITests.swift` (new) | the five live assertions |

`padding(.horizontal)` became `padding(.horizontal, 16)`: same value on iOS (16 is the default), now
a number the trailing-gap assertion can compare against instead of "whatever the platform default is".
