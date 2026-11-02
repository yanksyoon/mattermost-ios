# T46-AV2 — adversarial re-audit of F1–F4 on the repaired web fallback

Card: `t_a07e4108` (T46-AV2). Audit target: **`7cb3e5415e75678b2c06019a3e9190c824526a2c`** — the commit
reachable from `origin/main` (`git rev-parse HEAD` = `git rev-parse origin/main` = `7cb3e54` at audit
time), i.e. the repair of `docs/t46-avr-verdict.md`'s F1–F4 made by `t_14afc3a5`. Every number below is
from a run I made on this host in a detached worktree at that SHA
(`.worktrees/t_a07e4108-av`), not from the repair's summary.

Fixture: `mm-perf` (`mattermost/mattermost-team-edition:release-9`, 9.11.19) on `http://127.0.0.1:8065`,
account `perfprobe`, password from `scripts/perf_seed.py`; `GET /api/v4/plugins/webapp` → calls, nps,
playbooks — **no focalboard**. Simulator: iPhone 16 Pro
`81A7F251-8B31-4945-8783-5A264C14B8D5` (iOS 18.3). Host: macOS 26.3.1, Xcode 26.

---

## VERDICT: PASS

The repair reached the thing the reader taps. The shipped plugin row renders the catalogue's
`rowTitle`, the live suite asserts **the row's own label**, and my run of that suite measured
`label=Plugin route…`. F1.4's doc claims are true as written, F2's live-5 re-scoring is gone and the
artifacts cited in its place support every number quoted, F3 attributes each leak number to its run
under the stated contract (peak ≤ 4, at rest 0), and F4's Boards assertions are unconditional. The
gates reproduce: units 1900 run / 9 skipped / 0 failed, live 5 run / 0 skipped / 0 failed, leak probe
peak 2 / at rest 0 over 39 samples / final 0 → `RESULT: PASS`, dual-render gates `RESULT: PASS`.

---

## 1. What I ran

### 1.1 Unit suite — Mac Catalyst

```
cd .worktrees/t_a07e4108-av
python3 scripts/qa-test.py --platform mac \
  --derived-data ~/Library/Developer/Xcode/DerivedData/t46av2-units \
  --label t46av2-units-1 --only-testing MattermostTests -- \
  -clonedSourcePackagesDirPath ~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa/SourcePackages
```

```
run        : t46av2-units-1
outcome    : finished (xcodebuild rc=0, 137s)
tests      : 1900 run, 9 skipped, 0 failed
log        : …/.worktrees/t_a07e4108-av/build/logs/t46av2-units-1.log
xcresult   : ~/Library/Developer/Xcode/DerivedData/t46av2-units/TestResults/t46av2-units-1-ceed06.xcresult
RESULT: PASS
```

From the log itself:

```
Test Suite 'T46WebFallbackTests' passed at 2026-11-03 01:50:00.629.
	 Executed 34 tests, with 0 failures (0 unexpected) in 0.671 (0.700) seconds
	 Executed 1900 tests, with 9 tests skipped and 0 failures (0 unexpected) in 72.916 (73.942) seconds
** TEST SUCCEEDED **
```

(`build/logs/t46av2-units-1.log:9367, 9820, 9867`.) T46's own 34 unit tests are green here, and they are
**not** what decides F1 — see §2.

### 1.2 Live suite + leak probe (one run, the probe wraps the suite)

```
export TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe
export TEST_RUNNER_MM_AUTH_PASSWORD=<scripts/perf_seed.py>
python3 scripts/t46_leak_probe.py --run-test --sim id=81A7F251-8B31-4945-8783-5A264C14B8D5 \
  --label t46av2-live-1 --only-testing MattermostUITests/T46WebFallbackUITests
```

```
[suite] run        : t46av2-live-1
[suite] outcome    : finished (xcodebuild rc=0, 271s)
[suite] tests      : 5 run, 0 skipped, 0 failed
[suite] log        : …/.worktrees/t_a07e4108-av/build/logs/t46av2-live-1.log
[suite] xcresult   : ~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa/TestResults/t46av2-live-1-0a2837.xcresult
[suite] RESULT: PASS

T46 web-fallback leak probe
  run            : t46av2-live-1 (run-test)
  suite exit     : 0
  samples        : 520 over 286.2s
  baseline WC    : 1 WebKit WebContent process(es) before launch (excluded)
  peak WC        : 2 (limit 4)
  at rest WC     : 0 while the app was alive and idle (39 samples)
  final WC       : 0 after 15s idle
  WC timeline    : 0 -> 2 -> 0 (min 0, max 2)

RESULT: PASS - no WebContent process outlived the sheet while the app was alive, and the peak stayed within one presentation
```

Artifact: `build/t46-leak/t46av2-live-1.json` —
`{"peak_webcontent":2,"at_rest_samples":39,"at_rest_webcontent":0,"at_rest_orphan_pids":[],
"at_rest_window_seen":true,"final_app_alive":false,"final_webcontent":0,"baseline_app_pids":[47416],"max_peak":4}`.
The five test cases (all passed):

```
testAPluginRouteIsAddressableByID                        passed (25.813 s)
testBoardsIsEitherPaintedOrSaysItIsNotEnabled            passed (12.803 s)
testPlaybooksOpensAtItsOwnRoute                          passed (16.205 s)
testTheSystemConsoleOpensSignedInAndReturnsToTheShell    passed (17.374 s)
testTwentyOpenCloseCyclesEachRender                      passed (136.920 s)
	 Executed 5 tests, with 0 failures (0 unexpected) in 209.115 (209.121) seconds
```

### 1.3 Dual-render gates and the published SHA

```
bash scripts/verify-dual-render-gates.sh --allow-approved-registry
RESULT: PASS — dual-render debug affordances cannot reach a Release build.

python3 scripts/verify-pushed.py        # before my commit, on 7cb3e54
  [PASS] LOCAL==REMOTE  7cb3e541 on both
  [PASS] NO WORKTREES   none tracked
  [PASS] NO SECRETS     none tracked
RESULT: PASS — the work is published.
```

The verdict commit's own `verify-pushed` line and SHA are in the card's completion handoff
(this file is the only commit T46-AV2 makes).

---

## 2. The six checks

| # | Check | Verdict | Measurement |
|---|---|---|---|
| 1 | **F1 — the row, not the property** | **PASS** | shipped row renders the catalogue: `ChannelSidebarView.swift:275` `Label(Self.pluginRow.rowTitle, systemImage: Self.pluginRow.systemImage)` where `static let pluginRow = WebFallbackSurface(kind: .plugin)` (`:237`) and `rowTitle` = `"Plugin route…"` (`WebFallbackSurface.swift:95-97`); the live suite asserts **the row's own label**; my run measured `PROBE row webFallbackRow.plugin: exists=true label=Plugin route…` |
| 2 | **F1.4 — §13.2 table and parity's T46 row true as written** | **PASS** | `docs/dual-render.md:807` row `\| Plugin route… \| webFallbackRow.plugin \|` — measured true in my run; `docs/parity.md:127` says the row renders `WebFallbackSurface(kind: .plugin).rowTitle` and the suite asserts `row.label == "Plugin route…"` — both true in the code and in my run |
| 3 | **F2 — §9.5 / §13.4 drop the live-5 re-scoring or cite supporting JSON** | **PASS** | dropped, not re-worded: `docs/t46-build-note.md:445` "No run in this repo has recorded an orphan under the current rule, and this note does not claim one"; the three runs cited match their artifacts (§2.3) |
| 4 | **F3 — run-attributed numbers under the contract peak ≤ 4 / at rest 0** | **PASS** | contract stated in `docs/t46-build-note.md:432` and `docs/dual-render.md:892`; numbers attributed per run (`1 / 41`, `1 / 38`, `3 / 37`); "the peak is not a property of the card; it is a number per run" (`docs/dual-render.md:917`); my own run measured peak **2** over 39 samples and PASSes under the same contract |
| 5 | **F4 — Boards "no navigation" assertion not wrapped in `if pane.exists`** | **PASS** | `MattermostUITests/T46WebFallbackUITests.swift:154-164` are plain `XCTAssertTrue`/`XCTAssertEqual` calls under `if outcome == "notEnabled"` (the branch the fixture takes); the only `if pane.exists` left (`:119`) is the wait loop that *finds* the outcome, and failing to find one fails `:136` |
| 6 | **gates re-run on this host** | **PASS** | units 1900/9/0 (§1.1), live 5/0/0 (§1.2), leak peak 2 / at rest 0 over 39 / final 0 → `RESULT: PASS` (§1.2), dual-render gates PASS (§1.3) |

### 2.1 F1 — the row the reader taps

```
$ grep -n "rowTitle\|pluginRow" -r Mattermost/
Mattermost/UI/Native/Sidebar/ChannelSidebarView.swift:235:    /// … `rowTitle` is "Plugin route…" either
Mattermost/UI/Native/Sidebar/ChannelSidebarView.swift:237:    static let pluginRow = WebFallbackSurface(kind: .plugin)
Mattermost/UI/Native/Sidebar/ChannelSidebarView.swift:257:                    Label(surface.rowTitle, systemImage: surface.systemImage)
Mattermost/UI/Native/Sidebar/ChannelSidebarView.swift:275:                Label(Self.pluginRow.rowTitle, systemImage: Self.pluginRow.systemImage)
Mattermost/UI/Native/Sidebar/ChannelSidebarView.swift:278:            .accessibilityIdentifier("webFallbackRow.plugin")
Mattermost/UI/Native/Web/WebFallbackSurface.swift:95:    public var rowTitle: String {
```

The assertion, and its unconditionality (`MattermostUITests/T46WebFallbackUITests.swift:265-271`, no
enclosing `if`):

```swift
print("PROBE row webFallbackRow.plugin: exists=\(row.exists) label=\(row.label)")
XCTAssertEqual(row.label, "Plugin route…", …)
XCTAssertFalse(row.label.contains("Plugin screen"), …)
```

My run printed (`build/logs/t46av2-live-1.log:3968`):

```
PROBE row webFallbackRow.plugin: exists=true label=Plugin route…
```

`grep -rn "Plugin screen" Mattermost/` has **no shipped string use** — two doc comments only, both
recording the rename (`WebFallbackView.swift:215`, `:239`). The sheet and prompt agree
(`T46 plugin route state: loaded|installed|http://127.0.0.1:8065/ops/channels/town-square|chars=251|requested=http://127.0.0.1:8065/plugins/com.mattermost.calls`), and the prompt is
`PluginRoutePrompt` (`WebFallbackView.swift:217`, `ChannelSidebarView.swift:182`).

The unit test pinning `rowTitle` is not treated as evidence for this point: the 34 green unit tests
(§1.1) say nothing about what the row renders; the label above was read from the running app's
accessibility tree.

### 2.2 F1.4 — the docs' row claims

`docs/dual-render.md` §13.2's table says the fourth row is **`Plugin route…`** with identifier
`webFallbackRow.plugin`; measured true. Its "Repaired" note cites
`PROBE row webFallbackRow.plugin: exists=true label=Plugin route…` in `build/logs/t46avrr-live-1.log`;
that line is at `:3993` of that log and I reproduced it independently as `:3968` of mine.
`docs/parity.md`'s T46 row carries the same claim plus the leak numbers — checked in §2.3 — and adds no
claim I could not measure except the ones it explicitly marks as unmeasured (focalboard-served Boards,
the orphan branch).

### 2.3 F2 — the artifact behind every cited number

```
$ for f in t46r-live-6 t46avrr-live-1 t46avr-live-2 t46r-live-5; do \
    printf '%-16s has_baseline=%s ' $f "$(jq -r 'has("baseline_app_pids")' build/t46-leak/$f.json)"; \
    jq -c '{peak_webcontent,at_rest_samples,at_rest_webcontent,final_webcontent,final_app_alive}' build/t46-leak/$f.json; done
t46r-live-6      has_baseline=true  {"peak_webcontent":1,"at_rest_samples":41,"at_rest_webcontent":0,"final_webcontent":0,"final_app_alive":false}
t46avrr-live-1   has_baseline=true  {"peak_webcontent":1,"at_rest_samples":38,"at_rest_webcontent":0,"final_webcontent":0,"final_app_alive":false}
t46avr-live-2    has_baseline=true  {"peak_webcontent":3,"at_rest_samples":37,"at_rest_webcontent":0,"final_webcontent":0,"final_app_alive":false}
t46r-live-5      has_baseline=false {"peak_webcontent":2,"at_rest_samples":38,"at_rest_webcontent":1,"final_webcontent":1,"final_app_alive":true}
```

* `1 / 41`, `1 / 38`, `3 / 37` — exactly what `docs/t46-build-note.md:434-435`,
  `docs/dual-render.md:913-916` and `docs/parity.md`'s T46 row quote, from those three files.
* `t46r-live-5.json` has **no `baseline_app_pids` key** and records `at_rest_webcontent: 1`,
  `final_webcontent: 1`, `final_app_alive: true` — exactly the state `docs/t46-build-note.md:446-454`
  and `docs/dual-render.md:919-925` describe as the pre-fix attribution bug. No doc now derives an
  orphan from it; `grep -rn "live-5" docs/*.md` returns only those disclaimers (plus the historical
  quote in the previous verdict, allowed).

### 2.4 F3 — contract vs. numbers

The contract is stated as *peak ≤ 4 attributed `WebContent` processes, and 0 while the app is alive and
idle* (`docs/t46-build-note.md:432`, `docs/dual-render.md:892-893`, `docs/parity.md`), and every number
carries its run label. There is no surviving "peak 1" presented as a property; `docs/t46-build-note.md`'s
§7.5 block is explicitly "Same run" and cites its own report. My run adds a fourth observation, peak
**2** (limit 4) with at rest 0 over 39 samples — PASS under the stated contract, and one more data point
for "per run".

### 2.5 F4 — the Boards branch is unconditional

My fixture takes the not-enabled branch and the test passed with the pane's own state asserted:

```
T46 boards outcome: notEnabled — Boards is not enabled on this server.
```

followed by `XCTAssertTrue(pane.exists)`, `hasPrefix("idle|")`, `committedURL == "-"`,
`webFallbackUnavailable` exists (`T46WebFallbackUITests.swift:154-164`) — no `if pane.exists` around
them.

---

## 3. Findings outside the six (recorded, not a T46 regression)

Per the card's scope rule these are comments, not reasons to send T46 round a third time.

* `MattermostUITests/T46WebFallbackUITests.swift:263-264` has a duplicated clause ("Measured on the /
  Measured on the repaired build: …") from the edit. Cosmetic, comment text only.
* `docs/parity.md`'s T46 row quotes the probe as `PROBE row webFallbackRow.plugin label=Plugin route…`,
  dropping `exists=true`. Abbreviated quote of a line that exists; not a false claim.
* `docs/dual-render.md:950` says "The row and the sheet are labelled **\"Plugin route…\"**"; the
  sheet's title is `Plugin route: <id>` (no ellipsis). §13.2's table is precise, so the imprecision is
  local to that sentence.

---

## 4. Host state I changed

* Created the detached worktree `.worktrees/t_a07e4108-av` at `7cb3e54` (the shared checkout is shared
  with other cards). Logs and the leak report are written **inside it** (`build/logs/t46av2-*`,
  `build/t46-leak/t46av2-live-1.json`, untracked).
* New derived data at `~/Library/Developer/Xcode/DerivedData/t46av2-units` (units). The live run used
  the shared `mattermost-ios-qa` derived data because `scripts/t46_leak_probe.py` spawns
  `scripts/qa-test.py` without a `--derived-data` flag.
* Fixture `mm-perf` **untouched**: no plugin installed or removed, no data changed (focalboard still
  absent, `/api/v4/system/ping` 200 before and after).
* One aborted launch (`cut: bad delimiter` while extracting the fixture password into the environment)
  started nothing; the run used is the one labelled `t46av2-live-1`.

## 5. What this host cannot validate

* **Boards painted on a server that serves `focalboard`** — the fixture ships none and I did not install
  it. The not-enabled branch is what this host proves; the painted branch is unit-tested with an
  injected listing only. Stated in `docs/dual-render.md` §13.7 and `docs/t46-build-note.md` §9.1, and I
  add nothing to that list.
* **The orphan branch of the leak probe** — stated in the code, unexercised by any run here
  (`at_rest_orphan_pids: []` in every cited run, including mine). The docs now say so.
* **A real device / APNs** — not involved in T46 and not available on this host.
