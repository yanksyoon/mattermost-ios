# T8g §4 — the compact shell's bar draws material, so a list never renders its rows among the chrome

Card `t_560103f6` (mmios-ios), split out of the architect card `t_af56f51a` (T8g,
`docs/t8g-sticky-header-decision.md` §4). Host `MacBook-Pro-6.local`, Xcode 26.6 (17F113),
phone simulator **T8G iPhone 16 Pro** `D6471056-F671-4C32-AE7C-00D4B3447FFE` (iOS 18.3.1),
regular-layout simulator **iPad Pro 11-inch (M4)** `495B0295-5421-4667-92FD-DA47D89BD6E0` (iOS 18.3.1),
fixture server `mm-perf` at `127.0.0.1:8065`.

---

## 0. Verdict, up front

**The defect was real and is fixed with one scoped modifier.** Over a scrolled phone sidebar the shell's
navigation bar drew no material, so list rows were painted *through* the toolbar's own controls and the
status bar. Measured on the same 402 × 94 pt strip of the bar, between the list at rest and the list
scrolled until rows sit behind it:

| | before | after |
|---|---|---|
| differing pixels in the bar's own strip | **66.66 %** | **0.00 %** |
| bar frame (from the accessibility tree) | `{{0.0, 56.3}, {402.0, 96.0}}` | unchanged |
| rows sitting behind the bar at the sampled scroll | 2 | 2 (2–3 across runs) |
| pinned section caption (`channelSidebar.category.*`) | — | **y = 166.3** |
| shell elements / realised rows / per-row cost | 154 / 41 / 2.76 | 154 / 41 / 2.76 |

The fix is `RootView.CompactToolbarMaterial`: `.toolbarBackground(Color(.systemGroupedBackground),
for: .navigationBar)` + `.toolbarBackground(.visible, for: .navigationBar)`, applied **only** when the
layout is compact **and** the pane resolves native (`paintsCompactChrome`), to the navigation stack's root
content and to the `navigationDestination` content (a pushed native pane has its own bar). No identifier
was added and no element was added to a row. The webview pane — the shipping configuration, which this
card did not measure — is untouched by construction and by measurement (§3).

The regular (iPad/Mac) layout is untouched too, and that is **measured**, not asserted: an iPad in
landscape before and after the change differs in **134 of 4,036,560 pixels (0.0033 %)**, and the differing
bounding box is `x 1635…1653, y 100…112` — the status-bar clock digits, which changed between runs.

**Not claimed:** the fixture on this host had to be re-seeded (§1) — the recorded 347-channel fixture was
not present; real-device VoiceOver was not exercised; the `List` case (pre-T8f) is still unmeasured (the
card says so, and this card changes no container); dark appearance was not re-measured.

---

## 1. The fixture, first, because it was not there

The card (and T8e/T8f) measure against "the 347-channel fixture, 11 categories" on `127.0.0.1:8065`.
The docker stack on this host was down (`Exited (255)`), and when restarted its database held **46
channels in 3 categories total, 41 rows for `perfprobe` in team `perf`**
(`build/logs/t8g/census-before.txt`). No committed script seeds that fixture, so it is recreated
additively and idempotently by `build/logs/t8g/seed_347.py`:

```
team channels now: 40 (rows the sidebar draws: 41)
channels now: 346 (created 306)
  category T8G group 1..8: 10 channels each
FINAL channels(member)=347 categories=11
   favorites | Favorites | 0
   custom | T8G group 8..1 | 10 each
   channels | Channels | 267
   direct_messages | Direct Messages | 4
```

Nothing was deleted, no post was written, no channel was muted. The built-in `channels` category keeps
the long run of rows (267) the trees name, and the eight custom categories give the sidebar its 11
groups. `build/logs/t8g/census.py` is the reader.

---

## 2. Before: the bar has no material (measured, not eyeballed)

Reproduced with the new T33 test (§4) on the unfixed tree, `build/logs/t8g/t8g-before.log`:

```
T8G chrome: bar=(0.0, 56.33333333333334, 402.0, 96.0) strip=(0.0, 56.33333333333334, 402.0, 94.0) rowsBehind=2 differingPixels=66.66%
T8G chrome: descendants=154 rows=41 elementsMinusRows=113 perRow=2.76
```

The bar's frame is exactly the one the card quotes from T8f's tree (`{{0.0, 56.3}, {402.0, 96.0}}`,
bottom edge 152.3); the list still runs the full window height and scrolls under it. Two channel rows
sit inside the bar's strip at the sampled scroll, and **two thirds of the bar's pixels change** when the
list scrolls — the bar is drawing the list, not itself.

`build/logs/t8g/before-shots/t8g-02-sidebar-scrolled.png` is the picture: the row
`T8G probe 0061` is drawn straight through the `Local Mattermost` server switcher, and the category
caption `T8G GROUP 8` is drawn in the status-bar strip (the clock's line), with the back/reload buttons
also sitting on top of rows. That is the card's "two texts on each other", still reproducible on this
tree.

**Causation check (the card's working hypothesis, confirmed by the fix behaving as predicted):** there is
still no `.toolbarBackground`/`.toolbarBackgroundStyle` anywhere in `Mattermost/`, the bar is the
`NavigationStack` toolbar declared in `RootView`, and the panes live in the `TabView`'s tab content
(`NativeShellView.compactLayout`). iOS 18's scroll-edge effect needs the scroll view to be the
navigation controller's content scroll view; nested two levels inside a `TabView` tab it never is, so the
bar keeps its scroll-edge (transparent) appearance permanently. Painting the bar explicitly makes it
opaque — measured below, same strip, same device, same fixture.

---

## 3. The change

`Mattermost/UI/RootView.swift`:

```swift
private struct CompactToolbarMaterial: ViewModifier {
    /// `compact layout && native pane` — computed by the caller, which is where both facts live.
    let applies: Bool

    func body(content: Content) -> some View {
        if applies {
            content
                .toolbarBackground(Color(.systemGroupedBackground), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        } else {
            content
        }
    }
}

private var paintsCompactChrome: Bool {
    horizontalSizeClass == .compact && paneMode == .native
}
```

applied as `.modifier(CompactToolbarMaterial(applies: paintsCompactChrome))` twice — on the stack's root
content (after its `.toolbar { … }`, where the switcher/downloads/settings/`+` chrome is declared) and on
the `navigationDestination` content (which re-declares the same chrome for a pushed native pane). The colour
is the surface the compact sidebar is drawn on (`ChannelSidebarView.body` paints
`Color(.systemGroupedBackground)`), so the bar and the list's own background are the same colour and no
seam appears; `.visible` is the explicit switch, not left to the scroll-edge machinery that does not
engage here.

**Why `paneMode == .native` is in the condition.** The webview pane is the *shipping* configuration and
this card never measured it; painting its bar would be an unmeasured restyle of a screen the card is not
about. It was measured anyway, to show the scoping keeps it: same launch, web pane, before vs after the
change is **1046 of 3,162,132 pixels (0.0331 %) differing**, bounding box `x 174…271, y 79…116` — the
status-bar clock (`1:34` vs `1:35`); the web page, its inset and the bar over it are otherwise identical
(`build/logs/t8g/web-mode-before.png` / `web-mode-after-scoped.png`, `web-mode-diff.txt`). With the
material on, the WKWebView's own content-inset adjustment keeps the page below the bar, so nothing was
being clipped either — the difference was only the strip's colour, which is still not this card's to
change.

`Mattermost/UI/NativeShellView.swift` is **not** changed: the measurement put the bar in `RootView`'s
`NavigationStack`, and the `TabView` that hosts the panes needed no per-tab stack. Putting the material on
each tab's content instead (the card's option 3) would not cover the pushed native pane, whose
`navigationDestination` re-declares the same toolbar chrome on its own bar — so the modifier is declared
at the stack's content and at the destination content, which is where those two bars come from.

Why **not** the card's option 2 (a `.safeAreaInset(edge: .top)` opaque header): it moves the content
top, which would move the pinned caption off the measured 166.3 and re-open the pinning contract the
architect card had just settled — and it changes the list's frame, which the suites' `revealRow` reads.
Option 1 paints without moving anything, and the pinned caption stayed at **exactly 166.3** (§4).
Option 3 (per-tab stacks) was not needed: with the material declared, the appearance no longer depends on
the scroll-edge detection.

---

## 4. The regression test (`MattermostUITests/T33-ChannelSidebarUITests.swift`)

New test #9, `testTheChromeCoversTheListAsItScrollsUnderIt`, on the live fixture:

1. sign in, wait for the sidebar and its rows;
2. read the **bar's own rect** from the tree;
3. capture the bar's strip from a screenshot at rest (downsampled to one sample per point, RGBA);
4. swipe the list (the run's existing scroll surface, `ShellSettle.channelSidebarScroll`) until rows
   *are* behind the bar — the precondition is read from the tree, so a run that never scrolled fails
   for the honest reason;
5. capture the same strip again and require **< 2 % of samples to differ by more than 8/255**, with the
   measured fraction, the strip's size and the row count in the failure message;
6. record (and assert) that a section caption is still pinned just below the chrome (a preservation
   guard: it passed before the fix too — the caption was legible, the rows above it were not);
7. print the shell's element/row counts (T8e/T8f's per-row cost).

Two screenshots are attached to every run (`t8g-01-sidebar-at-rest`, `t8g-02-sidebar-scrolled`); on a
regular-width device the test takes a landscape screenshot of that layout (`t8g-03-regular-layout`) and
skips the compact invariant, which is what makes §5's iPad before/after comparison a two-run affair.

**After the fix** (`build/logs/t8g/t8g-after3.log`):

```
T8G chrome: bar=(0.0, 56.33333333333334, 402.0, 96.0) strip=(0.0, 56.33333333333334, 402.0, 94.0) rowsBehind=3 differingPixels=0.00%
T8G chrome: captions=…dtjdmdo1h7d8xxro3fi6jdzody@166.3, …zyo5nogyspbhzkik8q18mayije@508.7, …@984.3, …@1460.0 (+ one scrolled above the bar at -2.7)
T8G chrome: descendants=154 rows=41 elementsMinusRows=113 perRow=2.76
```

The same test **fails on the unfixed tree** with `XCTAssertLessThan(66.66 %, 2 %)` — the falsifier is
the run in §2, which is why this test is a regression guard and not a tautology. Three rows behind the
bar still exist in the fixed tree (the content did not move); they are simply not visible, because the
bar is opaque.

On the final tree and the final test file (`build/logs/t8g/t8g-final-chrome.log`, 1 run / 0 failed):

```
T8G chrome: bar=(0.0, 56.33333333333334, 402.0, 96.0) strip=(0.0, 56.33333333333334, 402.0, 94.0) rowsBehind=2 differingPixels=0.00%
T8G chrome: captions=…uje1k54pqbngmxpipbf33poppa@5.3, …dtjdmdo1h7d8xxro3fi6jdzody@166.3, …zyo5nogyspbhzkik8q18mayije@516.7, …@992.3, …@1468.0
T8G chrome: descendants=154 rows=41 elementsMinusRows=113 perRow=2.76
```

Screenshots: `build/logs/t8g/after-shots/` (fixed) against `build/logs/t8g/before-shots/` (unfixed), both
from this test's own attachments.

---

## 5. The regular/iPad layout is unchanged (measured)

Same test, iPad Pro 11-inch (M4), landscape — where `NavigationSplitView` shows the sidebar column —
once on the tree **without** the modifier (`git stash push -- Mattermost/UI/RootView.swift`; run
`t8g-ipad-before2`, 1 run / 1 skipped / 0 failed) and once with it (`t8g-ipad-after`, same). Screenshots:
`build/logs/t8g/regular-before/t8g-03-regular-layout.png` and `regular-after/…`; the reader is
`build/logs/t8g/pngdiff.py` (stdlib PNG decode, no Pillow on this host):

```
2420x1668: differing 134 / 4036560 = 0.0033%
  differing bbox: x 1635..1653, y 100..112
```

The only pixels that differ are the status-bar clock digits, which were two different times in the two
runs. The sidebar column, its rows, its bar and the detail pane are byte-identical, which is what
"the regular layout is unchanged" means here.

---

## 6. Gates

| gate | result |
|---|---|
| units (`MattermostTests`, same command as T8f) | **1758 run / 8 skipped / 0 failed** on the final tree (`build/logs/t8g/t8g-final-units.log`, 59 s; higher than T8f's 1725/8/0 because later cards added tests — the real numbers this tree gives) |
| `MattermostUITests/T32SidebarIdentifiersTests` + `T33ChannelSidebarStubTests` (stubs 8111, 8116–8122) | **11 run / 0 skipped / 0 failed** on the final tree (`build/logs/t8g/t8g-final-stub.log`, 188 s) |
| `T33ChannelSidebarUITests` live, 347-channel fixture | **9 run / 2 skipped / 6 failed** (`build/logs/t8g/t8g-t33live.log`, 2261 s) against base `2d2b903`'s **8 run / 2 skipped / 6 failed** and T8f's 8 / 2 / 4 — **not worse**: the failure count is the base's, and the one extra test is this card's, which passed |
| the chrome test itself (phone, fixed tree) | **1 run / 0 failed** (`t8g-after3`, 116 s) and again inside the live suite **PASS (26.5 s)**; **re-run green on the final `paneMode`-scoped tree and on the final test file** (`t8g-after4-scoped`, 60 s; `t8g-final-chrome`, 57 s: 0.00 % differing, pinned caption at 166.3, 154 elements / 41 rows); on the unfixed tree **1 run / 1 failed** with the 66.66 % measurement |
| the chrome test (iPad) | **1 run / 1 skipped / 0 failed**, deliberately (regular layout, screenshot only) |
| webview pane, before vs after the change | **1046 / 3,162,132 pixels (0.0331 %)** — the status-bar clock only (§3) |

The live suite ran on the tree before `paneMode == .native` was added to the condition; that condition is
true for every test in the suite (`launchAndSignIn` passes `-surfaceMode shell=native`), and the only test
that observes the paint was re-run on the final tree and passed — so the result stands for the shipped
shape, and the difference between the two trees is a boolean that is true in this configuration.

Live-suite failures, by class — all pre-existing, none in the chrome test: two
`QUARANTINED DUE TO HIGH LOGGING VOLUME` lines in the run window (12:59:13 pid 32597, 13:08:39), one
`Lost connection to the application (pid 32597)`, one "the server's `channels` category must draw"
followed by "application com.mattermost.ios is not running", one 1405 s `testUnreadAndMention…` that
ends in "No matches found", and one `testAReadFromAnotherClient…` whose unread badge never arrived in
45 s (it then skips: "no membership row"). No `Mattermost` `.ips` was written by the run
(`…/data/Library/Logs/CrashReporter/` is empty).

**Two flakes hit this card's own runs and are not the change:** `t8g-after` (the first fixed-tree run) found
the shell back on the auth surface 15 s after sign-in (`loginView` in the tree, same pid, no crash
report) — the launch `AuthCoordinator.restoreAll` / native sign-in race, unrelated to a toolbar
background; the identical tree passed immediately afterwards (`t8g-after2`) and again with the final test
(`t8g-after3`). The first unit run, `t8g-units`, wedged in `T34ChannelViewRestoreWiringTests`'s
expectation wait (DTXConnectionServices in the main-thread stack,
`build/logs/t8g/sample-host-28314.txt`); the re-run `t8g-units2` is the number in the table.

---

## 7. What this card changed

* `Mattermost/UI/RootView.swift` — `CompactToolbarMaterial` (`applies: paintsCompactChrome` =
  compact width **and** native pane), applied to the stack's root content and to the
  `navigationDestination` content. **Product change: this is the fix.**
* `MattermostUITests/T33-ChannelSidebarUITests.swift` — test #9, its screenshot/pixel helpers
  (`PixelStrip`, `pixelStrip`, `fractionDiffering`), and the regular-layout branch.
* `docs/t8g-sticky-header-decision.md` — §4 gets its outcome appended (the decision record is not
  rewritten).
* `docs/parity.md` — the T8g bullet's "still required and open" becomes the measured outcome.
* This note, plus the measurement scripts and the before/after evidence under `build/logs/t8g/`
  (`census*.txt`, `seed_347.py`, `pngdiff.py`, `before-shots/`, `after-shots/`, `regular-{before,after}/`,
  `web-mode-{before,after-scoped}.png`, the run logs `t8g-*.log`).

## 8. Not claimed

* No real device; the evidence is the iPhone 16 Pro / iPad Pro 11-inch (M4) simulators on iOS 18.3.1.
* The fixture is the re-seeded one described in §1 — same shape (347 rows / 11 categories), not
  necessarily the same channel ids as the run T8f recorded.
* The `List` case stays unmeasured, as the card states; nothing here says the pre-T8f container was
  better or worse.
* Dark mode was not re-measured: the modifier uses the semantic `systemGroupedBackground`, but the
  evidence above is light appearance only.
* The **webview pane's** bar appearance is deliberately left as it was: it is the shipping configuration
  and this card measured the native shell, so the material does not apply there (§3 states the measured
  before/after: clock digits only). Whatever the webview pane should look like is a separate decision,
  not an outcome of this card.
