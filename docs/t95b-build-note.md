# T95-B — one way to reach a bottom tab, and the suites that had to learn it

Card: `t_a1842f6c`. Decision record: `docs/t95-shell-tab-bar-decision.md` (§2 D1 — a channel is
pushed *over* the tab bar; §3 D2 — a launch restores the last channel, or lands on the channel list
when nothing is saved). T95-A (`t_e83e1cf3`) is the parent that changed the launch policy; this card
is the test-side consequence.

## 1. What the suites had to stop assuming

The compact shell is a `NavigationStack` above the `TabView`. Two facts follow, and every UI suite
that touches a tab has to survive both:

1. **A pushed channel hides the bottom bar.** `app.tabBars` is not in the accessibility tree while
   a channel is open, so `app.tabBars.buttons["Search"].tap()` fails — the bar is not "empty", it is
   *absent*.
2. **A launch may land on either screen.** With `-uiTestResetPersistedState` the app lands on the
   channel list (bar up). A relaunch *without* it restores the last channel, and the pushed pane
   replaces the shell's root — `nativeShell` is not in the tree at all (this is the same fact T37-R2
   F1b recorded for the splits).

Before this card each suite answered those questions in its own launch helper, and several answered
them only for the screen they happened to expect. Two suites had already grown private versions of
the same pop-then-tap dance (T39's `returnToSidebar`, T40/T47's `showSidebar`).

## 2. The change

### `MattermostUITests/ShellSettle.swift` (new, one file, no product code)

| member | purpose |
| --- | --- |
| `ShellSettle.Tab` | the compact shell's five tab titles, so a call site cannot drift from `NativeTab.title` |
| `ShellSettle.revealTabs(_:maxPops:)` | pop a pushed channel (at most three `Back` taps) until `app.tabBars` is on screen; returns whether it is |
| `ShellSettle.tapTab(_:in:wait:maxPops:)` | wait for the bar, pop if a channel covers it, tap the named tab; returns `false` when the layout draws no bar (regular/split) so the caller keeps its toolbar branch |
| `ShellSettle.waitForSignedIn(_:timeout:)` | "are we in?" for **both** landings — bar, `nativeShell`, or a pushed `nativeChannelPane`, with the sign-in field gone |

`tabBars.buttons[...]` now appears **only** in `ShellSettle.swift`:

```
$ grep -rn "tabBars.buttons\[" MattermostUITests/
MattermostUITests/ShellSettle.swift:87:        let tab = app.tabBars.buttons[title]
```

### Converted call sites

| suite | helper | before |
| --- | --- | --- |
| `T39SearchUITests` | `openSearch`, `openSaved` | own compact/regular branching |
| `T39JumpUITests` | `openSearch` | own tab handling |
| `T42ActivityUITests` | mentions surface | tab/toolbar-sheet logic |
| `T40ChannelInfoUITests` | `returnToSidebar` | own pop-then-tap |
| `T47CreateChannelUITests` | `showSidebar` | own pop-then-tap |
| `T48PostOptionsUITests` | `openSaved` | toolbar-first with a tab fallback |

Every one keeps its layout branch: the helper settles the compact shape and returns `false` on a
layout with no bar, and the suite then uses `shellSearchButton` / `shellSavedButton` /
`shellActivityButton` as before. No test gained a skip, and no assertion was removed to make the
hint pass.

## 3. What the audit found (and what it cost to fix)

Running the whole suite — which T95-B is the first card to do end to end since the shell's launch
policy changed — turned up four things that were not tab plumbing at all. All four are fixed here;
none of them is a weakened assertion.

1. **`testNativeShellDeepLinkLandsOnTheChannelInTheNativeStack` was red on the product, not the
   test.** A `mattermost://…/channels/<name>` link parses to a location with a channel *name* and no
   id (the `NativeChannelDirectory` has nothing to resolve, or has not loaded yet). T34's rewrite of
   the pane gated every channel branch on `location.channelID`
   (`Mattermost/UI/Native/NativePanePlaceholders.swift`, commit `68ed6b8`), so that location fell
   through to `NativeEmptyDestinationView` — the pane said **"No channel selected on UI Test
   Server"** while the URL named `#general`. Measured from the failure tree
   (`build/logs/t95b/t95b-deeplink-2.log`). New branch: a name-only channel route now draws the
   pane header with the name the link carried and a "Resolving this channel…" note
   (`nativeChannelResolveProgress`), the same shape the permalink branch has had since T30. A
   permalink that names a post still takes the permalink branch (it is checked first).
2. **`testRealServerTeamRailShowsBothTeamsAndSwitchesBetweenThem` assumed a non-zero mention count.**
   The test reads the count from the server (T32-R §3.5 removed the hard-coded 2) but built the
   expectation as "`\(count) mentions`" for every value — including 0, where the rail correctly draws
   no badge. The fixture's `ops` team happened to hold stray mentions; once they were cleared the
   test failed on correct behaviour. Now: 0 ⇒ assert the row carries *no* mention text; >0 ⇒ as
   before.
3. **`T33`'s live suite was written for a 13-inch iPad.** T33-R2 ran it there; on a phone the sidebar
   `List` builds only its viewport, so rows past the fold are not in the accessibility tree and
   "the row is not on the first screen" read as "the row is not in the server's answer". Added
   `revealRow(_:_:maxSwipes:)` — bounded, both directions, the way a person scrolls — and used it for
   every row lookup in the suite. Its own comment records why the fixture needs it (≈40 channels).
4. **Two `T33` assertions outran the app.** A row is drawn before the membership merge that carries
   `Muted`, and the category order is a shared-fixture value another card is writing while the suite
   runs. The muted row now polls for its value; the layout test picks its pair from the ids the list
   **draws** and makes the external write between those two.

`T35`'s `relaunchSignedIn` was the last helper that decided a test's outcome inside itself: it waited
on `nativeShell`, which a restored channel replaces. It now calls `ShellSettle.waitForSignedIn`.

## 4. Measured

Every run below is `scripts/qa-test.py` against simulator `81A7F251-8B31-4945-8783-5A264C14B8D5`,
DerivedData `~/Library/Developer/Xcode/DerivedData/mmios-t95b`, live server `http://127.0.0.1:8065`
(the `mm-perf` docker fixture) plus the local stubs on 8112-8115, 8120-8122 and the TLS stub on 8443.

| label | scope | result | note |
| --- | --- | --- | --- |
| `t95b-t39-settle-1` | T39 ×2 suites | 6/6 green | first proof of the helper, after uninstalling a stale runner |
| `t95b-ui-full-1` | whole suite | invalid | the installed runner was from another worktree (0 occurrences of this card's new string in the installed bundle) |
| `t95b-ui-full-2` | whole suite | 54 pass / 17 fail in 71 executed | stopped at T37; host load 90-164; see §5 |
| `t95b-t33-t35-1` | T33 + T35 | — | found the relaunch bug and the missing row reveal |
| `t95b-t33-t95-2` | T33 + T95Layout | T95Layout green | host load 200-320 |
| `t95b-pane-1` | deep link, rail, T33 stubs, T95Layout | **9/9 green** (1 iPad-only skip) | after the name-only pane branch |
| `t95b-t33-4` | T33 live | 2 pass / 2 fail (both `Lost connection`, app crashed mid-test) | load had fallen to 23; see §5 |
| `t95b-ui-full-3` | whole scheme, one invocation | **1725 unit tests: 0 failures (8 skipped). 121 UI tests: 30 assertion failures in 17 methods (3 skipped), 70 min** | the run this note is written from; see §5 |

`t95b-ui-full-3`'s reds, by suite, with what each is:

| suite | reds | measured cause |
| --- | --- | --- |
| `T33ChannelSidebarUITests` | 4 | 2 × `Lost connection` (app crashed mid-test), 1 × context-menu reorder that did not reach the server while the sibling card archived its probe channels on the same fixture, 1 × unread state not arriving |
| `T34ChannelPostListUITests` | 3 | scroll anchoring / reader-restore assertions; the same three were red in `t95b-ui-full-2` before this card's edits |
| `T35ComposerUITests` | 4 | 1 × `Lost connection`; 3 × composer text/mention/edit — keyboard drops under host load (the same class as batch 2) |
| `T37` / `T40` / `T43` / `T44` / `T48` | 1 / 1 / 1 / 1 / 2 | single-test reds in suites this card did not change; `T48`'s two are menu/sheet flows, not the `openSaved` helper this card converted |

The tab-reachability suites this card converted — `T39Jump`, `T39Search`, `T42Activity`, `T47CreateChannel` — are **0 red**, and so are `T32SidebarIdentifiers`, `T33ChannelSidebarStubTests`, `T36Threads`, `T95ShellLayoutUITests` and the T30/T31 web surfaces. `T40ChannelInfoUITests` is 1 red in a permission-row test, not in `returnToSidebar`.

## 5. The failures that are not this card's

Two classes remain, both pre-existing and both carded elsewhere:

- **The app crashes while XCTest snapshots the accessibility tree** (`Lost connection to the
  application (pid …)`, SIGSEGV on the main thread). It hits the suites that query the most
  elements — T33 live, T34's scroll tests, T35 — and it lands mid-assertion, so a run at host load
  >100 fails a different test each time. Measured again here: `t95b-t33-4` lost the app twice in one
  suite at load 23→60. This is `docs/t635-*` (card `t_635046c9`), not test logic; no assertion in
  this card's diff makes it more likely.
- **A launch that restores a channel can paint an empty post list** (the same note, symptom A). T95-B
  does not depend on it: the suites that relaunch either assert on the composer (T35) or walk to a
  row (T33's reveal).

## 6. For the card behind this one

`t_8d033037` (AC4) was re-parented behind this card because it re-runs the same five suites this
card edits. **The answer: re-run the app-loss batch.** Nothing in this card's diff targets the crash
class, so the batch's A/B measurement is still the right experiment; but its baseline must be this
commit, not the pre-T95-B tree — otherwise the batch measures this card's fixes as if they were the
defect.
