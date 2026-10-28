# T37-R2 — `testRecentsSurviveRelaunch`: the wait, the shapes a relaunch lands in, and why the recents claim is unchanged

Date: 2026-10-27. Card: `t_1f9af95a` (T37-R2). Finding that opened it: T55-AV-R
(`t_6059f7ce`), `docs/t55-revalidation-build-note.md` §3.2 F-1/F-2.

**Only one file changed**: `MattermostUITests/T37-ReactionsUITests.swift` (+154 / −9). No product code,
no `Mattermost.xcodeproj` change, and none of the shared tree's T47/T48 files were touched
(`git status --porcelain` lists that single path).

---

## 1. What the card said, and what was actually wrong

The card's hypothesis was a single fixed budget: `element(app, "nativeShell").waitForExistence(timeout: 40)`
after `terminate()` + `launch()`. Measuring it here turned up **three** distinct causes, of which the fixed
budget is only the first:

* **F-1a — one element, one budget.** A single `waitForExistence` on `nativeShell` cannot distinguish
  "slow on a loaded host" from "never mounted", and it cannot see the sign-in branch the relaunch is
  allowed to take (`-uiTestForgetSession` is deliberately absent, so a session that did not survive lands
  on `loginIDField`).
* **F-1b — after a relaunch `nativeShell` is not in the tree at all.** A relaunch that restores a channel
  pushes that pane onto a `NavigationStack`; compact layout then shows the pane *over* the sidebar, and
  `nativeShell` — the accessibility container around the workspace — is **absent**, while
  `nativeChannelPane`, its title, the composer and `channelPostList` are all present. Measured:
  `t37r2-recents-alone.log`, an empty `nativeShell` match at 21:20:19.44 whose sibling `loginIDField` query
  is empty too, while the very same snapshot holds `nativeChannelPane` / `nativeChannelTitle` "T36 Threads"
  / `channelPostList` / `channelComposer`. The old test spends 40 s, then reds, against an app that is
  showing the screen it was about to read. This is also why T55's failure attachment at :391 caught an
  empty window while a later snapshot in the same run showed the pane.
* **F-1c — the restored pane can be empty.** On this host the restore also lands on a pane that draws its
  header and composer while `channelPostList` reports seven pages of content and paints **no rows at all**:
  85 s at load 5, on two different simulators (`manual-relaunch-12s/40s/85s.png`,
  `manual-max-relaunch.png`, `t37r2-alone-b1.log` / `-b2.log` — the `channelPostList` subtree is one
  zero-sized child). That is a product-level defect, not a test timing issue (see §5).

## 2. The change

`MattermostUITests/T37-ReactionsUITests.swift`:

| what | why |
|---|---|
| `relaunchLandingTimeout = 240` | outer deadline for a relaunch after a cold `terminate()`; 240 s against the 60–160 s measured on this host under load 140–275 |
| `Landing` (`shell` / `pane` / `signIn` / `neither`) + `waitForLanding(_:timeout:)` + `landing(of:)` | polls `nativeShell`, `nativeChannelPane` **and** `loginIDField` every 0.5 s and reports *which* appeared, instead of charging one element's budget for both branches |
| relaunch branch now `switch`es on the landing | `.shell`/`.pane` proceed; `.signIn` re-uses `signIn(…, shellTimeout: relaunchLandingTimeout)`; `.neither` fails naming **all three** identifiers plus `XCUIApplication.state`, and attaches a screenshot and the accessibility tree (only when the app is still running) |
| assertion after the relaunch is on `nativeChannelPane` | the surface the test then drives, not the shell's chrome — the card's item 2 |
| `openChannelAfterRelaunch(_:)` | accepts the restored pane only when its title is the fixture channel's server-side `display_name` **and** at least one `post.*` row exists; otherwise taps `Back` and takes the sidebar route (`openChannel`) like a reader would |
| `hasAnyPostRow(_:)` | "the pane is up" and "the channel is readable" are different facts on this host (F-1c) |
| `channelDisplayName` read from the server in `setUp` | the pane title is compared with the server's `display_name` for the channel resolved by ID, never a hard-coded string |
| `attach(relaunched, "t37r2-pane-after-relaunch")` | the screen the post-relaunch assertions were read from, kept with every run |

**The claim is untouched.** The test still writes a reaction through the picker, relaunches **without**
`-uiTestResetPersistedState`, and requires `emojiPicker.recent.<name>` after the relaunch. Nothing in the
change can make that assertion pass for a client that did not persist recents — §4 proves it by mutation.

## 3. Runs

Environment: macOS 26.3.1, Xcode 26.6 (17F113), Mattermost **9.11.19** (docker `mm-perf`) at
`127.0.0.1:8065`, fixture team `#perf`, channel `t36-threads` (`display_name` "T36 Threads",
`psw97y5zqpfnpembwxraizuije`). Runner: `scripts/qa-test.py`, derived data
`~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa`, source packages reused from `mmios-t40r`.

**Devices.** The reference simulator from T55 (`iPhone 16 Pro`, `81A7F251…`, iOS 18.3) was **in use by
another card** for most of this run (`pgrep -fl "xcodebuild test"` showed `t39r2` on it at 20:41, 20:52,
20:56, 20:59); two attempts there died with `Test crashed with signal kill` at ~18 s — the second
`xcodebuild` kills the first card's runner. Two dedicated devices were created for this card, **same
device type and runtime** as the reference (`simctl create … "iPhone 16 Pro" "iOS 18.3"`):
`T37R2 iPhone 16 Pro` (`81AD82E4-B711-45B7-A539-33D9E861A7A5`), later `T37R2b iPhone 16 Pro`
(`3A3B41D0-7B3A-4054-96C6-31853254B6D0`, fresh app container). `testRecentsSurviveRelaunch` was also run
on `iPhone 16 Pro Max` (`BAFE0119…`, iOS 18.3) while the 16 Pro was busy.

| run | device | load (1 min) at start | result |
|---|---|---|---|
| `t37r2-suite` (first full suite, before the last two edits) | 81AD82E4 | **151.5** | **10 run / 0 failed / 347 s**, recents 46.7 s |
| `t37r2-recents-max` (before `openChannelAfterRelaunch`) | BAFE0119 | 110.5 | fail: pane up at 36.5 s, then no sidebar row existed to tap — the F-1b shape |
| `t37r2-recents-max-2` (after it) | BAFE0119 | 40.6 | **PASS 50.9 s** |
| `t37r2-recents-alone` (first on 81AD82E4) | 81AD82E4 | 71.7 | fail 240 s: `nativeShell` empty while the pane was drawn — the evidence for F-1b |
| `t37r2-alone-b1`, `-b2` | 81AD82E4 | 14.2 | fail at the post after relaunch: restored pane painted no rows — F-1c |
| `t37r2-alone-c1` (final code) | 81AD82E4 | **6.6** | **PASS 57 s** |
| `t37r2-suite-final` … `-final5` (final code) | 81AD82E4 | 9.7 – 44.4 | 9/10 each; recents **passed 4×** (41.3, 66.2, 66.2, 67.0 s), failed once (158.9 s) when the app stopped rendering the restored pane and, after `Back`, the sidebar list, then reported "app is not running" |
| `t37r2-custom-alone` | 81AD82E4 | 6.4 | PASS 44 s (the test that lost its app connection in `-final3`/`-final4`) |
| `t37r2-suite-fresh`, `-fresh2` (fresh device, final code) | 3A3B41D0 | 21.6 / 16.7 | 9/10 each; recents **PASS 66.6 s** / **67.0 s**; the only red is `testServerCustomEmojiIsOfferedAndWritten` losing the app process (46.6 s / 30.2 s) |
| `t37r2-pair` (recents + custom emoji only) | 3A3B41D0 | 9.5 | **PASS 2/2** (68.2 s + 26.3 s) — the relaunch test does not poison the next one |
| `t37r2-mutant-m7` | 3A3B41D0 | 15.1 | fail, but by `Lost connection to the application` — **inconclusive** |
| `t37r2-mutant-m7b` | 3A3B41D0 | 14.3 | **fail 62.7 s at the recents row** — the intended red (§4) |
| `t37r2-revert-alone` (mutant reverted, rebuilt) | 3A3B41D0 | **15.3** | **PASS 68.6 s** |
| `t37r2-suite-final6` (final code) | 3A3B41D0 | 19.9 | 9/10; recents failed 160.7 s — restored pane blank, `Back` landed on a list that also never painted, then "app is not running" |

The batch runs after 21:33 also lost the app process in **different, non-relaunch** tests
(`testBurstOfTapsConvergesAndNeverDrifts` in `-final`, `testTappingAPill…` and
`testForeignReactionArrivesOverTheSocketOnce` in `-final2`, `testServerCustomEmojiIsOfferedAndWritten`
in `-final3`, `-final4`, `-fresh` and `-fresh2` — and that one passes alone in 44 s and passes in the
two-test `t37r2-pair`), each with `Lost connection to the application (pid …)` or `cannot request
screenshot data because it does not exist` and **no crash report** in
`~/Library/Logs/DiagnosticReports` or the simulator's `CrashReporter/DiagnosticLogs` (checked after
every red). That is the app process going away mid-test, the same class T55 recorded as "Timed out
waiting for AX loaded notification"; the host was running other cards' `xcodebuild` UI batches and, from
22:05, first-boot work on a fresh device (`diagnosticd`, `NewsToday2` at 100 %+ CPU, load 137).

## 4. Falsifiability — the recents claim still bites (mutant M7)

The risk in a card like this is buying green by weakening the last assertion. M7 removes the persistence
only: in `EmojiRecentsStore.record(_:)` the in-memory update stays and `defaults.set(updated, forKey:)` is
deleted, so the picker still shows the recent **within** the launch and a relaunch has nothing to restore.

Result (`t37r2-mutant-m7b`, 3A3B41D0, load 14.3): `testRecentsSurviveRelaunch` **failed in 62.7 s** at

```
MattermostUITests/T37-ReactionsUITests.swift:449: error: -[MattermostUITests.T37ReactionsUITests
testRecentsSurviveRelaunch] : XCTAssertTrue failed - the emoji picked before the relaunch must be in
the Recently Used row
```

The wait, the landing switch and `openChannelAfterRelaunch` all pass; the red lands exactly on the claim.
Reverting the mutation (`git checkout -- Mattermost/UI/Native/Emoji/EmojiRecents.swift`), rebuilding
(`build/logs/t37r2/build-5.log`, `** TEST BUILD SUCCEEDED **`) and re-running the same test on the same
device gives **PASS 68.6 s** (`t37r2-revert-alone`) — so the red is the mutation, not the host. (A first
mutant attempt, `t37r2-mutant-m7`, failed by `Lost connection to the application` instead and is recorded
as inconclusive, not as evidence.)

## 5. Findings this card does not own

* **F-1c is a product defect, not a test one**: a relaunch that restores a channel can paint header +
  composer + a populated `channelPostList` with **no rows**, indefinitely (85 s measured at load 5 on two
  devices), and when it happens the `Back` route to the sidebar list can also come up empty. Screenshots:
  `build/logs/t37r2/manual-relaunch-12s.png`, `-40s.png`, `-85s.png`, `manual-max-relaunch.png`,
  `manual-max-relaunch2.png`; trees: `t37r2-alone-b1.log`, `t37r2-suite-final5.log`,
  `t37r2-suite-final6.log`. The relaunch test now survives it by taking the reader's route when the restore
  paints nothing, but the screen itself is wrong and wants its own card.
* **The app process intermittently goes away mid-test** in batch runs on this host (seven runs; the victim
  rotates, `testRecentsSurviveRelaunch` included in `-final5`/`-final6`), with **no** crash report written.
  Alone, and in the two-test `t37r2-pair`, everything is green. This is why the final-code suite runs are
  9/10 rather than 10/10; it is not attributable to the change under review (the same red appears in tests
  that do not touch the relaunch block) but it is also not explained yet.
* **`nativeShell` disappears when a pane is pushed** (F-1b) — worth knowing for every other suite that
  uses `nativeShell` as an "app is ready" marker after navigation or restore; `nativeChannelPane` is the
  stable marker in that state.

## 6. Publish gate

Staged by explicit pathspec (`MattermostUITests/T37-ReactionsUITests.swift` +
`docs/t37r2-build-note.md`), pushed, `git ls-remote` verified. No T47/T48 file is in the commit.
`build/logs/t37r2/` is gitignored (full `xcodebuild` logs stay local, quoted here).
