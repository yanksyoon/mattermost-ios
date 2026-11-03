# t_c941e3d3 — the live sidebar's own channels are not above the fold

Fixture/QA card. It changes **test code and its documentation only**; no product file is touched.
Everything below was measured on this host in this run (2026-11-04), not inherited from the card.

- server: `http://127.0.0.1:8065`, Mattermost 9.11.19 (the local throwaway fixture)
- account: `perfprobe` (`scripts/perf_seed.py`)
- device: `iPhone 16 Pro t941e3d3` (`9C883EB3-B410-4859-A443-A38A910F3396`), iOS 18.3.1 simulator
- tree: §1–§6 were measured on a detached worktree at `origin/main` = **eab5a8a**; the published
  runs in **§7** were re-taken on `origin/main` = **f631629** (the tree that carries the repair)
  with only the three test files below modified; derived data
  `…/DerivedData/mattermost-ios-qa-t941` (the shared `mattermost-ios-qa`
  was locked by another card's build: `unable to attach DB … database is locked`)
- runner: `scripts/qa-test.py` (guarded; derived data outside `~/Documents` because a TCC-denied
  debug-map open wedges a failing run — see the runner's own docstring)

## 1. The measurement, re-taken

`/api/v4/users/me/teams/{perf}/channels` for `perfprobe` answers **359** joined channels (the card
was written at 351; the fixture has kept growing). The two channels the suites open from the sidebar
sit at **index 15** (`t36-threads`, `psw97y5zqpfnpembwxraizuije`) and **index 347** (`t44-calls`,
`wikybttr8tnfzkxge9rk7aipph`) of that list — and the sidebar orders by its own activity rule, not by
that list order, so the rendered position is not the API index.

The sidebar is `ScrollView` + `LazyVStack` (`NativeChannelSidebarContent.scrollIdentifier` =
`channelSidebar.scroll`). A row outside the materialised window is **not in the accessibility tree
at all**, so to XCUITest "the row does not exist" and "the row is 4 000 pt below the fold" are the
same answer to an existence query. That is the whole defect: `T36.openChannel` waited 40 s for
`channelSidebar.channel.<id>` and tapped it, with no scroll step, and 5/5 tests died at that line;
T44D died at the same step.

## 2. The decision: (b), a shared scroll-to-row helper

Deterministic test-side repair, no fixture account work:

- `MattermostUITests/ShellSettle.swift` gains `ShellSettle.revealSidebarChannel(_:channelID:
  maxDownSwipes:maxUpSwipes:) -> SidebarReveal`, which scrolls the **sidebar's own surface**
  (`ShellSettle.channelSidebarScroll`, i.e. the identified scroll view, never
  `app.collectionViews.firstMatch` — that query is not the sidebar and swiped nothing) until
  `channelSidebar.channel.<id>` exists, and returns the row together with **how many swipes it
  took** and, on failure, how many channel rows were drawn. Both bounds are finite (24 down, 32 up)
  and neither is silent.
- `T36-ThreadsUITests.openChannel` and `T44DCallsUITests.revealSidebarRow` call it and put the
  report into their own failure messages.
- Search order is deliberate: down fast first (a row far below is cheap to reach), then back **up
  slowly**, because a fast flick crosses several screens and a lazy stack materialises a row only
  while it is near the viewport — an overshoot then looks exactly like absence.
- The hot path asks a **type-scoped** `buttons` query and only falls back to the any-type
  `descendants` form at a phase boundary: an any-type query per swipe is what `docs/t8d-build-note.md`
  §1–§2 measured as the app-process log-budget hazard (the serialiser runs inside the app).

**Why not (a), a dedicated account.** It would have to be seeded with every channel the live suites
open (T36's `t36-threads`, T44D's `t44-calls`, and whatever the next card adds), and the obvious
cheap candidate is already taken: `t36reply` is hard-coded as T36's **second author**
(`T36-ThreadsUITests.swift:41`), so logging in as it would collapse the two-author premise the suite
exists to test. A scroll helper is fixture-independent, needs no server state, and reports its cost,
so it keeps working when the shared server grows again — which it already did (351 → 359).

The fixture requirement is now written where a reader of each suite finds it: a paragraph in
`T36-ThreadsUITests.swift`'s header and in `T44DCallsUITests.swift`'s header, each naming the
measured channel count, the lazy list, and the helper.

**T31 needs no change.** `T31WebSessionHarvestUITests` has no per-row sidebar step: it reads the
rendered `channelSidebar.channel.*` set and asserts that the intersection with the server's member
ids is non-empty — a lazy window is fine for that assertion. Its one red test fails *before* any
sidebar interaction (§5).

No assertion was weakened, skipped or deleted in any of the three suites.

## 3. T36ThreadsUITests — 5 run / 0 skipped / 0 failed

```
python3 scripts/qa-test.py --platform ios --sim id=9C883EB3-… \
  --derived-data ~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa-t941 \
  --only-testing MattermostUITests/T36ThreadsUITests --label t941-t36-1104b
```

`docs/t941-t36-live-2026-11-04.log` (the runner's own copy: `build/logs/t941-t36-1104b.log`) —
`Executed 5 tests, with 0 failures (0 unexpected) in 663.233 s`,
`** TEST SUCCEEDED **`. Every one of the five printed the same measured cost:

```
[shellsettle] channelSidebar.channel.psw97y5zqpfnpembwxraizuije: realised after 17 swipe(s) of the sidebar
```

| test | result | time |
|---|---|---|
| testFollowPersistsAndTheFollowedThreadsListPages | passed | 134.4 s |
| testReplyingUpdatesTheRootsReplyCountAndTheThreadTakesSocketReplies | passed | 136.9 s |
| testTheThreadDrawsTheWholeChainInOrderIncludingTheCollapsedAndDeletedReply | passed | 182.0 s |
| testTheUnreadThreadStateIsTheServers | passed | 101.0 s |
| testTwoRepliesInARowFromTheThreadComposerBothLandInTheThread | passed | 108.9 s |

This is the same suite that was **10 failures / 5 tests** on base `e59e11a` and on `t_cdcc1f38`,
every failure at the old line 793 ("the sidebar must list channel …").

## 4. T44DCallsUITests — 2 run / 0 skipped / 0 failed

Run 2 (the recorded one): `docs/t941-t44d-live-2026-11-04.log` (runner: `build/logs/t941-t44d-1104-run2.log`) —
`Executed 2 tests, with 0 failures (0 unexpected) in 189.559 s`, `** TEST SUCCEEDED **`:
`testMuteSurvivesTheSnapshotAndLeaveEndsTheCall` 93.8 s, `testStartCallCreatesTheCallOnTheServerAndLeaveEndsIt`
95.8 s. Both printed `…wikybttr8tnfzkxge9rk7aipph: realised after 18 swipe(s) of the sidebar`.

**Run 1 was 1/2, and the failure was not the sidebar** (the sidebar step passed twice — 18 swipes in
both tests). `t941-t44d-1104.log`: `testStartCall…` passed (85.8 s) while
`testMuteSurvives…` failed at `T44DCallsUITests.swift:155` ("the control bar must offer mute").
Cause, measured from the same log: the **microphone permission was still undetermined** on this
device, so the join's 30 s window went on the system prompt — the log shows the springboard alert
'"Mattermost" Would Like to Access the Microphone' being handled with **Allow at t = 14.58 s of the
*next* test's launch** (i.e. after the mute test had already tapped Join). `CallsControlSet.derive`
draws the mute control only when the call is live **and** audio capture is granted
(`CallsSurfaceModels.swift:360`), so no grant = no control. With the grant in place the same test
passed alone (`t941-t44d-mute-rerun.log`, 94.0 s) and then in the full suite (run 2). **A fresh
simulator therefore needs one launch that answers the microphone prompt before T44D's numbers mean
anything** — that is an environment step, stated here so the next reader does not read it as a
regression.

## 5. T31WebSessionHarvestUITests — 2 run / 1 failed (separate defect, not this card's)

`docs/t941-t31-live-2026-11-04.log` (runner: `build/logs/t941-t31-1104.log`) —
`Executed 2 tests, with 1 failure (0 unexpected) in 80.025 s`;
`testWithoutAWebviewSessionTheSameLaunchStillAsksForSignIn` passed (6.8 s, the control), and
`testAWebviewOnlySessionRendersTheNativeWorkspaceWithoutSigningInAgain` failed at l. 84 after 73 s:
the webview-cookie launch renders **`nativeAuthSurface`** (the sign-in form: `loginIDField`,
`loginPasswordField`, `loginSubmitButton`, `authUseWebViewButton`) instead of `nativeShell`. Identical
failure, identical line, on base `e59e11a` and on `t_cdcc1f38` — and T31 has no sidebar step at all,
so this repair cannot move it. It is filed as its own card with this log; it is **not** folded into
this fix and T31 is **not** green.

## 6. What is not validated here

- T31's harvest path stays red (§5) — an open, separate defect.
- T44D's audio path is host-sensitive (`docs/t44d-build-note.md` §4.2): these runs were green at a
  bursty host load average of 30–60 with one simulator booted; a quiet host is still the reliable
  configuration.
- The helper's up-sweep (32 slow swipes) was **not** exercised as a *recovery* path on this server —
  all three suites found their row on the down sweep (17/18 swipes). The bound exists for a row that
  sorts *below* the initial viewport position; it is untested against a real overshoot here.
- No CI leg is claimed: these are local live runs against the fixture server.
- Nothing here says the sidebar *orders* its rows a particular way: the sweep proves the row is
  reachable, not where it sits. The API index of `t36-threads` (15 of 359) and the 17 swipes it takes
  to reach it are different numbers because the sidebar sorts by activity, not by that list.

## 7. Publish, and the two assumptions `origin/main` had changed (measured, re-run)

§1–§6 were written before the repair could be published. Publishing it landed it on a **moved**
`origin/main`: the worktree was at `f631629`, carrying `t_295b0a32` (launch opens the saved channel,
else the team's town hall) and `t_e73f31ce`. The card's runs could not be reported as the published
tree's numbers without re-taking them, and the re-run found that the moved tree had changed **two**
things the suites assumed. Both were found by running, not by reading, and both are recorded here
with the logs that show them.

**1. The launch lands on a pushed channel pane, so the sidebar is not in the tree at all.**
Run 2 on `f631629` (`docs/t941-t36-pane-first-2026-11-04.log`): 5 run / 5 failed, every failure

```
the sidebar must list channel psw97y5zqpfnpembwxraizuije
  (not realised after 0 swipe(s) of the sidebar, 0 channel row(s) drawn at the end)
```

and the dump on screen is `nativeChannelPane` titled "Town Square" with a `Back` button. Zero swipes:
the sweep never started, because `channelSidebar.scroll` does not exist while a pane covers the list.
`ShellSettle.revealSidebarChannel` therefore waits for the landing (`nativeChannelPane`, ≤6 s), pops it
with `Back` — the same tap `revealTabs` uses, bounded at 3 — pauses for the pop animation, and only then
sweeps. `SidebarReveal` gained a `pops` field and its report says
`realised after 17 swipe(s) of the sidebar, after 1 Back tap(s) to the channel list`.

**2. `signIn` waited on `nativeShell`, which the pushed pane removes.** With the pop in place but the
suites' own `signIn` still asserting `element(app, "nativeShell").waitForExistence(timeout: 40)`,
run 3 (`build/logs/t941-t36-pub3.log`, kept out of the repo) was **4 run / 1 failed**: four tests saw
the shell before the push and one (`testTheThreadDrawsTheWholeChainInOrder…`) did not, failing at
"signing in must reach the shell" with the pane in the dump. That is a race, not a product bug.
`T36ThreadsUITests.signIn` and `T44DCallsUITests.signIn` now call `ShellSettle.waitForSignedIn`, the one
helper that answers "are we in?" for the list, the tab bar **and** the pushed pane.

**3. The push lands one frame after the list is drawn, so the order above matters.** Run 4, with the
pop but *before* the landing wait (`docs/t941-t36-swipe-race-2026-11-04.log`), was 5 run / 5 failed at

```
ShellSettle.swift:222: Failed to swipe up "channelSidebar.scroll" Any:
  No matches found for first query match sequence: `Descendants matching type Any` -> …
```

The list was there when the query first resolved and gone when the swipe event was synthesized. Hence
wait-then-pop-then-pause; a sweep started during the hand-over is a hard failure, not a slow one.

### Runs on the tree that carries the repair (`f631629` + commit `256c6c7`)

- `T36ThreadsUITests` **5 run / 0 skipped / 0 failed**, `Executed 5 tests, with 0 failures (0
  unexpected) in 431.261 s`, `** TEST SUCCEEDED **` —
  `docs/t941-t36-live-2026-11-04-published.log`. All five printed the same cost:
  `…psw97y5zqpfnpembwxraizuije: realised after 17 swipe(s) of the sidebar, after 1 Back tap(s)`.

  | test | result | time |
  |---|---|---|
  | testFollowPersistsAndTheFollowedThreadsListPages | passed | 99.1 s |
  | testReplyingUpdatesTheRootsReplyCountAndTheThreadTakesSocketReplies | passed | 85.1 s |
  | testTheThreadDrawsTheWholeChainInOrderIncludingTheCollapsedAndDeletedReply | passed | 83.2 s |
  | testUnreadThreadStateIsTheServers | passed | 79.1 s |
  | testTwoRepliesInARowFromTheThreadComposerBothLandInTheThread | passed | 84.8 s |

- `T44DCallsUITests` **2 run / 0 skipped / 0 failed**, `Executed 2 tests, with 0 failures (0
  unexpected) in 155.011 s`, `** TEST SUCCEEDED **` —
  `docs/t941-t44d-live-2026-11-04-published.log`; both `…wikybttr8tnfzkxge9rk7aipph: realised after
  18 swipe(s) of the sidebar, after 1 Back tap(s)`. The microphone grant from §4 was already in place
  on this device, so the §4 environment step was not re-paid.
- `T31WebSessionHarvestUITests` **2 run / 1 failed** — unchanged and *not* fixed here
  (`docs/t941-t31-live-2026-11-04-published.log`). `testWithoutAWebviewSessionTheSameLaunchStillAsksForSignIn`
  passed (5.9 s); `testAWebviewOnlySessionRendersTheNativeWorkspaceWithoutSigningInAgain` failed at
  `T31WebSessionHarvestUITests.swift:84` after 66.1 s, and the dump on this newer tree is again
  **`nativeAuthSurface`** (`loginIDField`, `loginPasswordField`, `loginSubmitButton`,
  `authUseWebViewButton`) — the native sign-in form, not `nativeShell`. That is the separate card
  `t_4528b67e`, and this run confirms its premise on `f631629`; T31 is **not** green.

### What the publish itself was

`git apply --3way` of the preserved patch onto `f631629`: the three test files applied cleanly, and the
only delta the merge had to carry was `ShellSettle.swift`'s doc comments from `t_295b0a32` (the patch was
authored on `eab5a8a`); no conflict, no semantic change from that side. One commit, `256c6c7`, holds the
three test files plus this note and the four `eab5a8a` logs; the §7 runs above are recorded in a
documentation commit on top of it, which names `256c6c7`.

Suite names and test counts did not change (T36 5, T44D 2, T31 2), so `docs/parity.md`'s T36/T44d rows
stand; this note is the citation they gain.
