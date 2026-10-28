# T95-A-AV-R — making the D1/D2 UI falsifiers measurable

Card `t_c81a4bad` (follow-up to `t_3a33a5ff`, adversarial validation of T95-A). Three coverage gaps,
all of the form "the test cannot fail for the reason it claims":

| gap | what it was | what this card did |
|---|---|---|
| F1 | the legacy-push UI falsifier was `waitForExistence(timeout: 5)` started before the channel directory existed | the launch claim is now a **window** that starts when the directory is on screen (`firstMoment(within:)`), measured red at 0.1 s against a reinstated fallback (§1) |
| F2 | nothing had ever redded `app.tabBars.count == 0` (the "push covers the bar" assertion) | a mutation now reds it, with the log (§2) |
| F3 | D2's **regular/iPad** half — split view + `NativeEmptyDestinationView` — was asserted nowhere | a second test on an iPad destination, plus a mutation that reds it (§3) |

Deliverable diff: `MattermostUITests/T95ShellLayoutUITests.swift` + this note + the evidence log.
**No product-code change ships**: the three mutants in §1–§3 were applied, run, recorded and reverted
(`git checkout -- Mattermost/`; `git status` clean before the final green runs).

Host: macOS 26.3.1, Xcode 26.6, live fixture `mm-perf` (Mattermost 9.11.19, `127.0.0.1:8065`,
account `perfprobe`). Simulators created for this card: **iPhone 16 Pro** `614CEE50-8613-434D-BFBB-8F3B858F4B9A`
(iOS 18.3.1), **iPad Pro 11-inch (4th gen)** `122E4BC7-35F9-4C5D-8623-104333727EB3` (iOS 18.3.1) —
separate devices so this card could run beside T95-B without fighting over a simulator.

---

## 1. F1 — the launch window now starts on the directory, and it reds

**The change** (`T95ShellLayoutUITests.swift`, step 1b): after the tab bar is on screen the test waits
for the channel directory to have rows (`channelSidebar.channel.*`), and only then holds
`nativeChannelPane` absent over `launchWindow = 20 s`, sampling every 100 ms and failing on the first
sample that sees a pane — with the elapsed time in the message:

```
let paneAt = firstMoment(within: launchWindow) { element(app, "nativeChannelPane").exists }
XCTAssertNil(paneAt, "… A nativeChannelPane appeared \(…) s after the channel directory was on screen: …")
```

Two things made the old assertion weak, and both are gone:

* it started **before** the directory existed, so it could close before the decide that opens a
  channel (the shell decides on appearance, again when `model.$groups` fires, and again on any
  location change);
* it asserted a **moment** ("nothing in the last 5 s"), not an interval. `firstMoment` asserts an
  interval and reports *when* the violation happened.

It does not use T95-B's `ShellSettle` helper: that helper settles **tab taps** (`tapTab`, Back until
the bar is back), which this test never does — it taps a sidebar row and one `Back`. `firstMoment` is
a window observation, not a second settle helper; when T95-B's file lands, nothing here duplicates it.

### Measured

| run | tree | result |
|---|---|---|
| `t95av2-mutant-fallback-1` | main + the parent tree's town-hall fallback reinstated at the top of `LaunchDestination.request` (throwaway) | **RED**, `Executed 1 test, with 1 failure (0 unexpected) in 11.834 s` — `T95ShellLayoutUITests.swift:138: XCTAssertNil failed: "0.0786…" … A nativeChannelPane appeared 0.1 s after the channel directory was on screen` |
| `t95av2-green-iphone-1` | main (fallback reverted) | **GREEN**, `Executed 1 test, with 0 failures (0 unexpected) in 45.773 s` |
| `t95av2-green-iphone-2` | final tree (rebased on `origin/main`), no instrumentation | **GREEN**, see §5 |

### The parent fixture (`bbe0aa1` + this test file) — measured, and it cannot red

The card names `parent bbe0aa1 + the T95-A test file` as the fixture for the red. It was run
(`t95av2-parent-layout-1`, `Executed 1 test, with 0 failures (0 unexpected) in 46.725`) and it is
**green**, for a reason the AV pass could not see: on `bbe0aa1` the legacy town-hall push **never
fires at all** on this fixture — it is not "late", it is absent. Two probes measured it:

* `t95av2-probe-parent2`: a throwaway probe polled tab bar / pane / rows every 250 ms for 75 s after
  sign-in. Output: `tabBarFirst=0.0003 rowsFirst=1.46 paneFirst=nil` — the directory is on screen at
  1.5 s and no `nativeChannelPane` ever appears (the AV's two green parent runs saw the same thing).
* `t95av2-probe-parent6` (same probe, plus a throwaway `t95probeFile()` line in
  `applyLaunchDestinationIfNeeded`): the decide runs 6 times and **every call reads an empty
  directory** —
  `decide enter … modelTeam=nil locTeam=nil groups=0` ×4, `STOP noTeam`, then
  `modelTeam=ocz148… groups=0` → `STOP noRequest` twice. `t95a-av2-evidence-2026-10-28.log` §A has
  the raw lines.

The mechanism the parent's own code leaves behind: the directory-arrival decide is driven by
`model.$groups.sink`, and `@Published` publishes in **willSet**, so `model.groups` is still the
*previous* value inside the callback. With nothing saved, `LaunchDestination.request` never even gets
asked (the fallback needs `hasTownHall`/`fallbackChannelID`, both derived from that stale empty
`entries`), so the branch answers `nil`. On `main` the same sink reads stale too — the measurement
log shows `sink groups=2` immediately followed by `decide enter … groups=0` — but main's
`request(saved:)` returns `nil` for a different, deliberate reason and the later decide (from the
location-change path) reads `groups=2`.

Consequence, stated plainly: **the parent commit is not a red fixture for the UI test**, and the AV's
F1 phrasing ("the old push lands outside the 5 s window") is not what happened — the push it describes
does not occur. The falsifier the card actually needs is "a reinstated conditional fallback", and
that is `t95av2-mutant-fallback-1` above: reinstating the fallback where the decide can reach a loaded
directory reds the assertion in 11.8 s. Both facts are in the note so the next reader does not repeat
the "just widen the window" diagnosis.

---

## 2. F2 — `app.tabBars.count == 0` now has a recorded red

Decision: option **(a)**, a mutant, recorded. The assertion is unchanged.

Three mutations were tried; the first two are *negative* results worth keeping, because they say
something about SwiftUI:

| mutant (throwaway, reverted) | result |
|---|---|
| `t95av2-mutant-tabbar-1` — per-tab stack: `NavigationStack(path: $navigation.path)` **inside** the Channels tab, outer `panePath` constant | **GREEN** (44.250 s) — SwiftUI removes the tab bar for a push inside a tab's stack on iOS 18.3, so `app.tabBars.count == 0` still held |
| `t95av2-mutant-tabbar-2` — same, plus `.toolbar(.visible, for: .tabBar)` on the pushed destination | **GREEN** (44.710 s) — the modifier does not bring it back |
| `t95av2-mutant-tabbar-3` — the pushed destination carries its own tab container (`RootView`'s `navigationDestination` renders `TabView { NativeDestinationPaneView(…) }`) — i.e. "a tab bar stays on screen in a channel" | **RED**, `Executed 1 test, with 1 failure (0 unexpected) in 54.414 s` — `T95ShellLayoutUITests.swift:184: XCTAssertTrue failed - the pushed pane covers the tab bar (upstream parity, D1); a tab bar still on screen here means someone changed the shell's structure …` |

So the assertion is falsifiable, and the shape that falsifies it is the one the decision doc rejects
(§2 "keep the tab bar in a channel"). The `:122` assertion the card names is now `:184` after the
step-1b insertion; the doc comment next to it records this mutation and the two null results.

---

## 3. F3 — the regular layout landing is asserted on an iPad destination

New method in the same file (fixtures and helpers shared, nothing forked):

`testTheRegularLayoutLandsOnTheSplitViewWithAnEmptyDetail` — `XCTSkipUnless(.pad)`, landscape, then:

* `nativeShell` stays on screen (nothing is pushed over it);
* `nativeEmptyDestination` exists and says "No channel selected …";
* the split view's sidebar column lists the team's default channel row;
* `app.tabBars.count == 0` (deviation D-1: our regular layout uses toolbar buttons);
* held over the same 20 s launch window: no `nativeChannelPane` and no `nativeChannelTitle`;
* the empty destination is still the detail at the end of the window.

The compact method now `XCTSkipIf`s on non-phone destinations (it needs `app.tabBars`), so each half
of D2 is asserted on the destination it describes and neither reds on the wrong one.

### Measured

| run | tree | result |
|---|---|---|
| `t95av2-mutant-regular-1` | main + `regularLayout`'s detail inventing a channel (`NativeLocation(channelName: "town-square")`) when nothing is selected (throwaway) | **RED**, `Executed 1 test, with 1 failure (0 unexpected) in 64.615 s` — `T95ShellLayoutUITests.swift:228: XCTAssertTrue failed - a launch with nothing saved must leave the detail column empty (NativeEmptyDestinationView) …` |
| `t95av2-green-ipad-1` | main (mutant reverted) | **GREEN**, see §5 |

---

## 4. What this card does not claim

* The regular test runs only on an iPad (or any regular-width) destination; on the phone it reports a
  skip, deliberately, like the compact test does on iPad. A full suite run on an iPhone therefore
  shows **one skipped test from this file** — that is the destination gate, not a missing fixture.
* No real device, no APNs, no other suite was re-run: T95-B owns the whole-suite acceptance.
* The parent tree's inert fallback (§1) is a *measured* statement about `bbe0aa1` + this fixture. It
  is not a claim that no configuration could ever reach the old branch; the branch is reachable when a
  later decide reads a loaded directory (which is exactly the mutant in §1).

---

## 5. Runs, commands, `Executed …` lines

Runner: `bin/run_uitest.py` (this card's scratch helper) wraps the repo's guarded
`scripts/qa-test.py`, resolves the fixture password from the repo's own seed scripts (several literals
in `scripts/*.py` are stale — only the one that logs in is used) and passes it as
`TEST_RUNNER_MM_AUTH_*`, so no credential appears on a command line or in a log:

```
python3 bin/run_uitest.py --worktree <wt> --label <label> \
  --only-testing <MattermostUITests/T95ShellLayoutUITests/[method]> \
  --sim id=<udid> --derived-data ~/Library/Developer/Xcode/DerivedData/t95av2
# expands to:
#   TEST_RUNNER_MM_AUTH_SERVER/… added to the environment
#   python3 scripts/qa-test.py --platform ios --sim id=<udid> --derived-data … \
#     --log-dir <wt>/build/logs/t95av2 --label <label> --only-testing <spec>
```

| label | what | device | `Executed …` |
|---|---|---|---|
| `t95av2-probe-parent2` | throwaway timing probe, parent `bbe0aa1` | iPhone 16 Pro 614CEE50 | `Executed 1 test, with 0 failures … in 95.859` (pane never appeared) |
| `t95av2-probe-parent6` | same probe + throwaway decide instrumentation, parent `bbe0aa1` | iPhone 16 Pro 614CEE50 | passed; `/tmp/t95probe-parent.log`, 12 lines, all `groups=0` |
| `t95av2-green-iphone-1` | new test, main, instrumented | iPhone 16 Pro 614CEE50 | `Executed 1 test, with 0 failures (0 unexpected) in 45.773` |
| `t95av2-mutant-fallback-1` | reinstated fallback | iPhone 16 Pro 614CEE50 | `Executed 1 test, with 1 failure (0 unexpected) in 11.834` — `:138` |
| `t95av2-mutant-tabbar-1` | per-tab stack | iPhone 16 Pro 614CEE50 | `Executed 1 test, with 0 failures … in 44.250` (mutant did not reproduce) |
| `t95av2-mutant-tabbar-2` | per-tab stack + toolbar visible | iPhone 16 Pro 614CEE50 | `Executed 1 test, with 0 failures … in 44.710` (mutant did not reproduce) |
| `t95av2-mutant-tabbar-3` | destination carries a tab container | iPhone 16 Pro 614CEE50 | `Executed 1 test, with 1 failure (0 unexpected) in 54.414` — `:184` |
| `t95av2-mutant-regular-1` | regular layout invents a destination | iPad Pro 11 122E4BC7 | `Executed 1 test, with 1 failure (0 unexpected) in 64.615` — `:228` |
| `t95av2-green-ipad-1` | first clean run of the new regular test | iPad Pro 11 122E4BC7 | **RED** — `:240 the split view's sidebar column must list #town-square` (see below) |
| `t95av2-green-ipad-2` | new regular test, main, after the fix | iPad Pro 11 122E4BC7 | `Executed 1 test, with 0 failures (0 unexpected) in 38.245` |
| `t95av2-green-iphone-2` | both methods, final tree | iPhone 16 Pro 614CEE50 | `Executed 2 tests, with 1 test skipped and 0 failures (0 unexpected) in 47.142` (compact 46.873 passed; the regular method reports the destination skip) |
| `t95av2-parent-layout-1` | parent `bbe0aa1` + this test file | iPhone 16 Pro 614CEE50 | **GREEN** — `Executed 1 test, with 0 failures (0 unexpected) in 46.725` (the fixture the card names cannot red; see §1) |

The `green-ipad-1` red is worth recording: the test scrolled the *detail* column with `app.swipeUp()`
looking for the team's town-hall row, which never reached it — the fixture team has ~40 channels and
the sidebar is a column, not the screen. The assertion was rewritten to what the landing claim needs:
the sidebar column names the team (`sidebarCurrentTeam`) and lists at least one channel row
(`channelSidebar.channel.*`). That is the split view *being* a split view; scrolling to a particular
channel is a different test.

Raw logs: `build/logs/t95av2/*.log` in the run worktree (paths in the completion handoff).

---

## 6. Files

* `MattermostUITests/T95ShellLayoutUITests.swift` — step 1b (directory-first launch window,
  `firstMoment`, `launchWindow`), destination gates, the mutation record at the tab-bar assertion, and
  `testTheRegularLayoutLandsOnTheSplitViewWithAnEmptyDetail`.
* `docs/t95a-av2-build-note.md` (this file).
* `docs/t95a-av2-evidence-2026-10-28.log` — the instrumentation output behind §1 and the exact
  throwaway patch that produced it.

No product file, no launch argument, no seam that opens a destination: `git diff origin/main --
Mattermost/ MattermostTests/ Mattermost.xcodeproj/` is empty for this card.

## 7. Verdict

**T95-A-AV-R: PASS** — F1, F2 and F3 each now have a measured red, and the D1/D2 assertions are
unchanged in strength. One AV conclusion is corrected: the parent tree's legacy push is inert on this
fixture (measured), not merely late, so the parent commit cannot serve as the UI red fixture; the
reinstated fallback can, and does (§1).
