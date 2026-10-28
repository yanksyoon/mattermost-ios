# T95-A — launch policy parity, and the shell layout pinned as upstream behaviour

Card: `t_2e160986` (implementation of D1/D2 in `docs/t95-shell-tab-bar-decision.md` §2–§3).
Date: 2026-10-27. Commit: `bc0bfce` on `main`.

---

## 1. What changed

| file | change |
|---|---|
| `Mattermost/Core/Native/NativeNavigation.swift` | `LaunchDestination` lost `townHallNames`, `townHall`, `townHallAvailable`, `fallbackChannelID`. `request(saved:available:serverID:teamID:teamName:)` returns the saved channel's request **only** when the record is on this server and still in `available` (or `available` has not loaded), `nil` otherwise. The block comment above `LastChannel` that claimed upstream "falls back to the team's town hall" is corrected to the pinned policy. |
| `Mattermost/UI/Native/Sidebar/ChannelSidebarCoordinator.swift` | `applyLaunchDestinationIfNeeded` no longer computes `hasTownHall`/`fallback`; the doc comment states upstream's last-thread → last-channel → `HOME` policy and that a gone channel opens nothing. The guards (`!location.opensADestination`, other-server) and the event-driven re-decide on `$groups` are unchanged. `lastLaunchDecision` now records `-> none` when nothing is opened, so a diagnostic can tell "decided nothing" from "never decided". |
| `Mattermost/UI/Native/NativeShellView.swift` | The layout-decision comment gains a paragraph: the compact push **covers** the tab bar on purpose, citing `(authenticated)/_layout.tsx:61-64`, `(home)/_layout.tsx:23-36`, `screens/navigation.ts:31-51,62-77` and the Mobile v2 design section *Hiding the Bottom Tab Bar in Channels*; a change that keeps the bar is a deviation card, not a bug fix. |
| `MattermostUITests/T39JumpUITests.swift`, `MattermostUITests/T39SearchUITests.swift` | Both `openSearch` doc comments now say what is true: a launch with nothing saved lands on the channel list with its tab bar; a launch that restored a channel shows a pushed pane with `Back` (upstream's own path), and the helper pops back first because that is what a reader does. |
| `MattermostTests/LastChannelLaunchTests.swift` | Rewritten around the four policy cases: saved channel present → that channel; saved channel gone → `nil`; nothing saved → `nil`; saved channel on another server → `nil`. Two rules kept: an unloaded list trusts the saved channel, and a record saved without a team is completed from the launch context. |
| `MattermostUITests/T95ShellLayoutUITests.swift` | New live suite (one test) — the parity assertion for D1+D2. |

## 2. Evidence, with the commands that produced it

Derived data: `~/Library/Developer/Xcode/DerivedData/mmios-t95a`; packages reused from
`~/Library/Developer/Xcode/DerivedData/mmios-t40r/SourcePackages` (`-clonedSourcePackagesDirPath`).
Fixtures: `mm-perf` (Mattermost 9.11.19) at `127.0.0.1:8065`, iPhone 16 Pro `81A7F251…` iOS 18.3.

### 2.1 Unit suite (green)

```
python3 scripts/qa-test.py --platform ios --sim id=81A7F251-8B31-4945-8783-5A264C14B8D5 \
  --derived-data ~/Library/Developer/Xcode/DerivedData/mmios-t95a --log-dir build/logs/t95a \
  --label t95a-units-full --timeout 2400 --only-testing MattermostTests \
  -- -clonedSourcePackagesDirPath ~/Library/Developer/Xcode/DerivedData/mmios-t40r/SourcePackages
```

→ `Executed 1725 tests, with 8 tests skipped and 0 failures (0 unexpected) in 35.479 s`,
`** TEST SUCCEEDED **` (`build/logs/t95a/t95a-units-full.log`).

`LastChannelLaunchTests` alone (`--only-testing MattermostTests/LastChannelLaunchTests`,
`build/logs/t95a/t95a-units-focus.log`) → **8 tests, 0 failures**: the four policy cases
(`testTheSavedChannelWinsWhenItStillExists`, `testASavedChannelThatIsGoneOpensNothing`,
`testNothingSavedOpensNothing`, `testASavedChannelFromAnotherServerOpensNothing`) plus the two kept
rules and the store round trips.

### 2.2 The new UI test (green)

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
python3 scripts/qa-test.py --platform ios --sim id=81A7F251-8B31-4945-8783-5A264C14B8D5 \
  --derived-data ~/Library/Developer/Xcode/DerivedData/mmios-t95a --log-dir build/logs/t95a \
  --label t95a-uilayout-4 --timeout 1200 --only-testing MattermostUITests/T95ShellLayoutUITests \
  -- -clonedSourcePackagesDirPath ~/Library/Developer/Xcode/DerivedData/mmios-t40r/SourcePackages
```

→ `Test Case '…testALaunchWithNothingSavedShowsTheTabBarAndAChannelPushCoversIt' passed (29.372 seconds)`,
`Executed 1 test, with 0 failures (0 unexpected) in 29.372 (29.373) seconds`, `** TEST SUCCEEDED **`
(`build/logs/t95a/t95a-uilayout-4.log`). The same test passed on its first attempt at 31.327 s
(before the launch helper's "signed in" wait was widened, `build/logs/t95a/t95a-uilayout-2.log`).

The run's three screenshots were exported from the `.xcresult`
(`xcrun xcresulttool export attachments`) and inspected:

| file (`build/logs/t95a/attachments-ui4/`) | what it shows |
|---|---|
| `t95a-1-launch-nothing-saved.png` | the channel list on the **Channels** tab, the five-tab bar (Channels / Threads / Search / Mentions / Saved) at the bottom, "Loading channels…" in the list, and **no** channel pane |
| `t95a-2-channel-covers-the-bar.png` | `# Town Square` pushed full-height with a `Back` chevron in the navigation bar and **no** tab bar |
| `t95a-3-back-restores-the-bar.png` | `Back` popped: the channel list with the tab bar (and no pane) |

What it measures, in order:

1. `-uiTestResetPersistedState` + seeded server + native surfaces, signed in through the native form:
   `app.tabBars.firstMatch` exists (and its `Search` button), `nativeChannelPane` does **not** — a
   launch with nothing saved stays on the channel list, i.e. upstream's `HOME`;
2. tap the team default channel's sidebar row → `nativeChannelPane` exists, `nativeChannelTitle`
   names that channel, `app.navigationBars.buttons["Back"]` exists, and `app.tabBars.count == 0`;
3. tap `Back` → the tab bar is back and the pane is gone.

### 2.3 Falsifiability — the recorded red

The deleted branch was reinstated temporarily (a `townHallFallbackMutant` in `LaunchDestination` plus
the coordinator call site), rebuilt, and the same test run
(`build/logs/t95a/t95a-mutant-townhall-2.log`):

```
T95ShellLayoutUITests.swift:88: error: … XCTAssertFalse failed - a launch with nothing saved must NOT
open a channel — LaunchDestination restores the last channel and nothing else, so no town hall may be
pushed (this is the assertion a reinstated fallback breaks):
Executed 1 test, with 1 failure (0 unexpected) in 11.619 s
** TEST FAILED **
```

Reverted with `git checkout -- Mattermost/Core/Native/NativeNavigation.swift
Mattermost/UI/Native/Sidebar/ChannelSidebarCoordinator.swift`; the green run above is on the reverted
tree (`git status` clean apart from the new test file at that point).

An earlier mutant recording (`build/logs/t95a/t95a-mutant-townhall.log`) failed one step earlier, in
the test's own launch helper, because a pushed destination removes `nativeShell` from the
accessibility tree (T37-R2 F-1b). That was a real weakness in the helper — it decided the outcome
before the assertion could — and it is fixed: the helper now accepts "shell **or** pane **or** tab
bar" as "signed in", which is what moved the red onto the parity assertion itself.

## 3. One red run that is not a product red (recorded, not hidden)

Run `t95a-uilayout-3-final` (`build/logs/t95a/t95a-uilayout-3-final.log`) went red at step 2 after
**passing step 1**: the town-square row never appeared, and the hierarchy captured at failure is the
**sign-in surface** with empty fields — `nativeAuthSurface`, `Sign in to Local Mattermost`,
`loginIDField` empty, `Log In` disabled.

* Same process throughout (pid 88629 in both the launch and the failure snapshots), no `.ips` crash
  report in `~/Library/Logs/DiagnosticReports` or the simulator's `CrashReporter/DiagnosticLogs`.
* No `sessionExpiredBanner` in the tree, so this is the shell's `.signedOut` branch, not the
  expiry path (`AuthCoordinator.restore` → `setPhase(.signedOut)` when neither the vault nor the
  webview holds a token).
* The same code passed before (31.3 s) and after (29.4 s) this run.

Recorded here and handed to **T95-B** (suite stabilisation) rather than papered over: a live suite
that intermittently lands back on its own sign-in surface is a suite-level problem, and it is not
caused by the launch policy — the launch in that run had *no* channel pushed (step 1 was green).

## 4. Not done here

* Suites that relied on the implicit town-hall push (T34 waits on `channelPostList` straight after
  launch, and the T36/T40/T42/T47/T48 equivalents) are **T95-B**. They were not run in this card, and
  no suite was "fixed" by re-adding the fallback.
* Upstream restores the last **thread** before the last channel; `LaunchDestination` has no thread
  branch. That is deviation **D-2** of the decision record, not this card.
* The regular/iPad layout has no bottom tab bar (**D-1**), unchanged.
