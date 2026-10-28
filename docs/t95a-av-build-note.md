# T95-A-AV — adversarial validation: launch policy parity and the retracted tab-bar claim

Card: `t_3a33a5ff` (QA validation of `t_2e160986`, T95-A). Date: 2026-10-28.

**Validated commit: `2baddc6845fa8868bf0ef855ac8fe16ea9759313`** — `git ls-remote origin
refs/heads/main` answered the same sha at the start (01:29:26 EDT) and after the last run (01:52), and
`git status` was clean in the shared checkout throughout, so this is a pushed tree, not a
verified-but-unpushed one.

Host: macOS 26.3.1, Xcode 26.6. Fixture: `mm-perf` Mattermost 9.11.19 (docker) at
`127.0.0.1:8065`, account `perfprobe`. Device: iPhone 16 Pro `81A7F251-8B31-4945-8783-5A264C14B8D5`,
iOS 18.3.1. Builds ran from a detached worktree of `origin/main`
(`~/.hermes/profiles/mmios-qa/cache/scratch/t95av/wt-t95a`) and from a parent-commit worktree
(`…/wt-parent` @ `bbe0aa1`), never in the shared checkout, so no second writer touched the repo.

## Verdict: PASS-WITH-FINDINGS

The launch-policy change is real, it removes the invented town hall rather than hiding it, and it is
guarded by a deterministic unit test that reds on the parent tree. The retraction is carried out in
the code comments. The pinned-upstream parity claims check out at the pin. Five findings are
recorded below; the two that matter are F1 (the live UI test is not a reliable falsifier of the
legacy code — it passes on the parent) and F3 (D2's regular-layout half is asserted nowhere).

---

## 1. Claim by claim

| # | claim attacked | result | evidence |
|---|---|---|---|
| 1 | the decision's retraction is carried out; no comment still asserts the tab bar is always on screen | **PASS** | `T39JumpUITests.swift:233-241` and `T39SearchUITests.swift:245-254` (`openSearch`) now say the compact push covers the bar, cite `docs/t95-shell-tab-bar-decision.md` §2, and pop back first; `NativeShellView.swift:38-47` states the same with the pinned route files. `grep -rn -i "upstream keeps the tab bar\|tab bar is always\|always on screen" docs/ Mattermost/ MattermostTests/ MattermostUITests/` finds them only in `docs/t95-shell-tab-bar-decision.md` (as the withdrawn premise) and `docs/t39-r2-build-note.md` §6 F-1 — the latter is another card's record and is deliberately not rewritten (the decision doc names it as withdrawn). `docs/t95-shell-tab-bar-decision.md` is on `main` (commit `39c7216`, ancestor of `2baddc6`). |
| 2 | the fix does not paper over the race; no implicit town-hall push came back to get green | **PASS (with F1 on the UI half)** | `LaunchDestination.request` returns `nil` when nothing is saved (`Mattermost/Core/Native/NativeNavigation.swift:828-843`); `grep -rn "townHall" Mattermost/ MattermostTests/` → no match (only a prose comment "no town hall" at `MattermostTests/LastChannelLaunchTests.swift:73`); no launch seam pushes a channel (`grep -rn "uiTest" Mattermost/` — the seams are reset/seed/assume-signed-in/log-level/attach/paging, none opens a destination); the T95-A diff on `NativeShellView` is comments only (`git diff bbe0aa1 2baddc6 -- …/NativeShellView.swift`). Red/green/mutant in §2. |
| 3 | parity is real: the quoted upstream lines exist at `162f2560` | **PASS** | §3 — tag→sha re-resolved from the GitHub API and four files re-fetched at the sha. |
| 4 | the T39 suites still measure (run/skip/pass, no 0-test pass) | **PASS (one batch red traced to the known app-loss, F5)** | §4 — `T95ShellLayoutUITests` 1/1, `T39JumpUITests` 2/2, `T39SearchUITests` 4/4 alone; 0 skipped everywhere. |
| 5 | the second-order effect (auto-open the town hall on launch, and the regular/detail layout) is handled or deferred with a card id | **HANDLED, one coverage gap (F3)** | `docs/t95-shell-tab-bar-decision.md` §3 decides it (restore the last channel on both layouts, else nothing; regular lands on the split view with an empty detail), and the code follows. The "auto-open town hall" question is closed by the decision, not deferred; the suites that relied on the implicit push are carded as **T95-B = `t_a1842f6c`**. The regular-layout consequence is decided but untested (F3). |

## 2. The red / green / mutant triple (measured, this attempt)

All runs used `scripts/qa-test.py` (exit 1 on a reported failure; derived data outside `~/Documents`
because a failing XCTest wedges when CoreSymbolication opens debug-map objects in a TCC-protected
folder — memory and `scripts/qa-test.py` docstring).

**Parent red** — `bbe0aa1` (the commit T95-A's diff is measured against) plus T95-A's *test* file
copied in, so only the test is new and the product code is the old one:

```
cp wt-t95a/MattermostTests/LastChannelLaunchTests.swift wt-parent/MattermostTests/
cd wt-parent && python3 scripts/qa-test.py --platform ios --sim id=81A7F251-… \
  --derived-data ~/Library/Developer/Xcode/DerivedData/t95av-parent --log-dir …/build/logs/t95av \
  --label parent-units-2 --only-testing MattermostTests/LastChannelLaunchTests
```

→ `Executed 8 tests, with 6 failures (0 unexpected) in 0.716 s`, `** TEST FAILED **`
(`build/logs/t95av/parent-units-2.log`). The documented reason, verbatim:
`LastChannelLaunchTests.swift:75: error: … XCTAssertNil failed: "NativeChannelRequest(… channelName:
Optional("town-square") …)" - with nothing saved the destination is the channel list, as upstream's
HOME is`. Four tests red, including `testASavedChannelFromAnotherServerOpensNothing` and
`testASavedRecordWithoutATeamIsCompletedFromTheLaunch` (the old fallback answered for every
"no saved channel" case, not only the empty store).

**T95-A green** — same test file, product code at `2baddc6`:

→ `tests: 8 run, 0 skipped, 0 failed` (16 s, `build/logs/t95av/t95a-units-focus-3.log`), and again
after the mutant was reverted (`t95a-units-focus-4-after-revert.log`, 8/0/0). Full unit target:
`tests: 1725 run, 8 skipped, 0 failed` (49 s, `t95a-units-full-2.log`) — the 8 skips are the
pre-existing ones the parent's own run recorded.

**Mutant red** — one added branch in `LaunchDestination.request` (the only edit, reverted with
`git checkout -- Mattermost/Core/Native/NativeNavigation.swift`; `git status` clean afterwards):

```swift
if saved == nil, let teamID {
    return NativeChannelRequest(serverID: serverID, teamID: teamID,
                                teamName: teamName, channelName: "town-square")
}
```

```
tests: 1 run, 0 skipped, 1 failed   (qa-test summary; the unit line is below)
  LastChannelLaunchTests.swift:75 / :77  XCTAssertNil failed … "with nothing saved …"
  T95ShellLayoutUITests.swift:88: error: … XCTAssertFalse failed - a launch with nothing saved must
  NOT open a channel — LaunchDestination restores the last channel and nothing else, so no town hall
  may be pushed (this is the assertion a reinstated fallback breaks):
  Executed 8 tests, with 2 failures … / Executed 1 test, with 1 failure (0 unexpected) in 10.377 s
```

(`build/logs/t95av/t95av-mutant-reinstate-1.log`.) So the assertion is live in both layers, and the
UI red lands on the parity assertion itself — not in the launch helper.

## 3. Parity at the pin — re-checked from the tag, not from a branch

```
GET /repos/mattermost/mattermost-mobile/git/ref/tags/v2.45.0
  → refs/tags/v2.45.0  162f2560d0e1df073220f7701d5a67cc17c8abeb  commit
```

`docs/component-map.md:8` pins `M` to the same sha. The files below were fetched from
`raw.githubusercontent.com/…/162f2560…/` and kept in
`~/.hermes/profiles/mmios-qa/cache/scratch/t95av/parity/`:

| claim in `docs/t95-shell-tab-bar-decision.md` §1 | file at the pin | measured |
|---|---|---|
| the authenticated `Stack` declares only `(home)` | `app/routes/(authenticated)/_layout.tsx:61-64` | `<GlobalClassificationBannerContainer …><Stack screenOptions={stackScreenOptions}><Stack.Screen name='(home)'/></Stack>` — the only screen |
| `(home)` is the `Tabs` navigator | `app/routes/(authenticated)/(home)/_layout.tsx:23-36` | `<Tabs … backBehavior='none' tabBar={(props) => (<TabBar …/>)}>` + five `Tabs.Screen`s (CHANNEL_LIST first) |
| `channel` is a sibling route of `(home)` in that Stack | `app/routes/(authenticated)/channel.tsx:4` | `export {default} from '@screens/channel';` — a route file at the `(authenticated)` level, i.e. auto-registered next to `(home)` |
| tab screens map under `(home)`, everything else at the top level, opened with `router.push` | `app/screens/navigation.ts:31-51, 62-77` | `if (HOME_TAB_SCREENS.has(screen)) { return '/(authenticated)/(home)/' + screen }` … `router.push({pathname: route, params})` (`:71`) |
| cold start = last thread, else last channel, else `HOME` | `app/init/launch.ts:250-257, 290-294` | `lastViewedThread…` / `else if lastViewedChannel…` / `else setLoadTarget('HOME')`; the fall-through route is `/(authenticated)/(home)` |

No quoted line was missing at the pin, so there is no HIGH finding on claim 3. The Mobile v2 design
quote ("Hiding the Bottom Tab Bar in Channels") is on an authenticated Confluence page; I did **not**
re-fetch it, so that half is taken from `docs/t95-upstream-layout-evidence-2026-10-27.log`, not
independently re-measured here (see §7).

## 4. Do the suites still measure?

One batch invocation on `2baddc6`, all three live suites, env `TEST_RUNNER_MM_AUTH_SERVER/_LOGIN/
_PASSWORD` (fixture account), label `t95av-live-t39-shell-2`:

```
python3 scripts/qa-test.py --platform ios --sim id=81A7F251-… \
  --derived-data ~/Library/Developer/Xcode/DerivedData/t95av --log-dir …/build/logs/t95av \
  --label t95av-live-t39-shell-2 --timeout 590 \
  --only-testing MattermostUITests/T95ShellLayoutUITests \
  --only-testing MattermostUITests/T39JumpUITests \
  --only-testing MattermostUITests/T39SearchUITests
```

→ `Executed 7 tests, with 1 failure (0 unexpected) in 259.244 s`
(`build/logs/t95av/t95av-live-t39-shell-2.log`), **0 skipped**:

| suite | run | passed | skipped | note |
|---|---|---|---|---|
| `T95ShellLayoutUITests` | 1 | 1 (28.070 s) | 0 | the parity assertion, green on `2baddc6` |
| `T39JumpUITests` | 2 | 2 (46.162 s, 42.269 s) | 0 | |
| `T39SearchUITests` | 4 | 3 | 0 | `testSearchRenders…` red at `T39SearchUITests.swift:258` |

The one red is **not an assertion**: `Failed to get matching snapshots: Lost connection to the
application (pid 58764)` during `openSearch`'s first query, 15 s into the test, with no `.ips` in
`~/Library/Logs/DiagnosticReports` or the simulator's `CrashReporter/DiagnosticLogs` (scanned for the
last 40 min). A/B: the same suite alone is `tests: 4 run, 0 skipped, 0 failed` (168 s,
`t95av-t39search-alone-1.log`), and an earlier batch run of the same two suites on the same tree was
6/6 green (`build/logs/t95av/t39-live-1.log`, 247.959 s). That is the pre-existing "app process
vanishes mid-batch" symptom already carded as `t_635046c9` (symptom B), reproduced once more here.

The T95-A UI test is not a 0-test pass: it executed 1 test, it was not skipped (no
`XCTSkip` line), and the three attached states were exported from this run's `.xcresult` and
inspected — `build/logs/t95av/attachments-live2/t95a-{1,2,3}-*.png`: (1) the channel list with the
five-tab bar (Channels/Threads/Search/Mentions/Saved) and no pane; (2) `# Town Square` full height
with a `Back` chevron and **no tab bar**; (3) `Back` → the list and the bar return, no pane left.

## 5. The implicit push is gone (the thing that must not have come back)

* `LaunchDestination.request(saved:available:serverID:teamID:teamName:)` has no `townHallNames`,
  `townHallAvailable` or `fallbackChannelID`; `git diff bbe0aa1 2baddc6` shows the old branch deleted,
  not bypassed (`NativeNavigation.swift:828-843`).
* Nothing in `Mattermost/` or `MattermostTests/` names a town hall as behaviour
  (`grep -rn "townHall"` → no match; `grep -rn -i "town hall"` → one comment saying the opposite).
* No launch argument, seam or flag opens a channel: the `-uiTest*` arguments in the product are
  reset/seed/forget-session/assume-signed-in/log-level/attach-fixture/expose-paging/expose-load-earlier,
  none of which selects a destination.

## 6. Findings

**F1 (MEDIUM, coverage) — the live UI test does not catch the legacy implementation it was written
for.** At the parent commit `bbe0aa1` with the town-hall fallback intact, and with T95-A's own test
file copied in unchanged, `T95ShellLayoutUITests` **passed** twice: `parent-layout-2` this attempt
(42 s, `build/logs/t95av/parent-layout-2.log`) and `parent-layout-1` from an earlier attempt of this
card (30.593 s, `build/logs/t95av/parent-layout-1.log`). The timeline shows why: the 5 s
`nativeChannelPane` window at `T95ShellLayoutUITests.swift:88` runs at t≈9-14 s, the parent's push is
event-driven (`townHallAvailable` is computed from the sidebar groups once the directory arrives), and
the test then finds the sidebar row and opens the channel itself — so the legacy push, when it lands,
lands outside the window. A *synchronous* reinstatement (the §2 mutant) does red the same assertion in
10.4 s. Consequence: the red/green pair the card asks for exists, but the parent red is the **unit**
test; `docs/t95a-build-note.md` §2.3 is accurate about its mutant and must not be read as "the parent
tree reded the UI test". No product change is implied; the unit test is the gate.

**F2 (LOW, coverage) — D1's half of the new test has never been shown able to fail.** No run has redded
`T95ShellLayoutUITests.swift:122` (`XCTAssertTrue(waitUntil { app.tabBars.count == 0 })`, "the pushed
pane covers the tab bar"); the only mutation exercised reinstates D2's fallback. The D1 assertion's
falsifiability is argued from the route structure (§3), which is verified at the pin, but it is not
measured. A "keep the tab bar" regression would need per-tab stacks — not a one-line mutant — so this
is recorded rather than faked.

**F3 (LOW, coverage) — D2's regular-layout consequence is asserted nowhere.** The decision says a
launch with nothing saved on regular lands on the split view with an empty detail
(`NativeEmptyDestinationView`). `T95ShellLayoutUITests` is compact-only (`app.tabBars`, an iPhone
destination) and `LastChannelLaunchTests` is layout-independent, so no test would red if the regular
layout started inventing a destination. Follow-up carded (§8).

**F4 (LOW, docs/ownership) — the non-product red is handed to a card that does not cover it.**
`docs/t95a-build-note.md` §3 hands the intermittent "app fell back to its sign-in surface mid-test"
red to "T95-B (suite stabilisation)". T95-B (`t_a1842f6c`) is about suites opening the channel they
need and one settle helper; its body never mentions a sign-in-surface fallback. The closest owner is
`t_635046c9` (symptom B: the process vanishes mid-batch). Commented there.

**F5 (measurement) — the T39 batch red is the known process loss, not a launch regression.** See §4:
failure is a lost application connection at `T39SearchUITests.swift:258`, no crash report, and the
suite is 4/4 green alone on the same tree. The suite still measures (7 run / 0 skipped).

## 7. What was not validated on this host

* The Mobile v2 design-doc sentence (authenticated Confluence page) was not re-fetched; only the
  pinned code was re-verified. If D1 ever needs the design half re-litigated, that page is the source.
* The whole UI suite (T33/T34/T36/T40/T42/T47/T48) was **not** run here — that is T95-B's acceptance
  criterion. So "no suite passes only because a channel was pushed for it" is unverified for those
  suites; what is proven here is that the product no longer pushes one.
* The regular/iPad layout was not exercised (no iPad destination was run; the new UI test is
  compact-only) — F3.
* No real device and no APNs were involved in any of this.

## 8. Worst case, stated exactly

If the launch policy regresses — anything invents a destination when `LastChannelStore` is empty —
the first red is:

```
MattermostTests/LastChannelLaunchTests.testNothingSavedOpensNothing
MattermostTests/LastChannelLaunchTests.swift:75
  XCTAssertNil(request(saved: nil, available: ["chan-1", "chan-town"]),
               "with nothing saved the destination is the channel list, as upstream's HOME is")
```
(`:77` is the same for an unloaded list). Measured red on the parent tree (`bbe0aa1`, 6 of 8 tests
failed) and on the reinstated-fallback mutant (`:75`, `:77`).

The live backstop is:

```
MattermostUITests/T95ShellLayoutUITests.testALaunchWithNothingSavedShowsTheTabBarAndAChannelPushCoversIt
MattermostUITests/T95ShellLayoutUITests.swift:88
  XCTAssertFalse(element(app, "nativeChannelPane").waitForExistence(timeout: 5),
                 "a launch with nothing saved must NOT open a channel — … no town hall may be pushed")
```
measured red against a synchronous fallback (10.377 s) — but green on the parent's own conditional
push (F1), so it is a backstop, not the gate.

## 9. Artifacts

* `build/logs/t95av/parent-units-2.log` — parent red, 8 run / 6 failed.
* `build/logs/t95av/t95a-units-focus-3.log`, `…-4-after-revert.log` — 8/0/0 each.
* `build/logs/t95av/t95a-units-full-2.log` — 1725 run / 8 skipped / 0 failed.
* `build/logs/t95av/t95av-mutant-reinstate-1.log` — units 2 failures, UI 1 failure at `:88`.
* `build/logs/t95av/t95av-live-t39-shell-2.log` — 7 run / 0 skipped / 1 failed (app loss).
* `build/logs/t95av/t95av-t39search-alone-1.log` — 4/0/0.
* `build/logs/t95av/parent-layout-2.log`, `parent-layout-1.log` — the UI test green on the parent.
* `build/logs/t95av/attachments-live2/t95a-{1,2,3}-*.png` — the three states, exported from this
  run's `.xcresult` and inspected.
* `t39-live-1.log` — the earlier 6/6 batch on the same tree (corroboration for F5).
