# T26-R R4a — webview release policy (§12): implementation evidence

Task: `t_64ee78c9` · assignee `mmios-ios` · repo `/Users/yangsooyoon/Documents/yanks/code/mattermost-ios`
Decision of record: `docs/dual-render.md` §12 (written by `t_b562e16b`). Nothing in §12 was re-decided.

## Commits

| SHA | Subject | Scope |
|---|---|---|
| `ed62126` | feat(dual-render): webview release policy — pane-owning, approved, honest reload (T26-R R4a) | 13 files, +831/−69 |
| `45f3f70` | docs(dual-render): record the §12 release policy implementation and its measurement (T26-R R4a) | `docs/dual-render.md` +22 |

`ed62126` is on `main` (parent `5fd6ce9`, T27's landed baseline). `45f3f70` is docs-only and
pathspec-limited (`git commit -- docs/dual-render.md`); a sibling worker's `Mattermost/Core/MM/*`
(T28) edits were live in the shared tree throughout and were never staged.

Artifacts committed with this note (repo convention, alongside `t26-native-pane.png`):

```
docs/t26r-r4a-build-note.md        this file
docs/t26r-r4a-reopening.png        the blocking "Reopening web view…" state (live run)
docs/t26r-r4a-reopened-session.png the reopened web app, session intact (no sign-in form)
docs/t26r-r4a-gate-2026-10-24.log  verify-dual-render-gates.sh output at 45f3f70 (RESULT: PASS)
```

Test/build transcripts live outside the repo (`build/` is ignored); their worktree paths are named per
row below.

Files in `ed62126`:

```
Mattermost/Core/PerfProbe.swift                |  53 +++-   nativeEvicted arm (§12.6)
Mattermost/Core/RenderMode.swift               |  20 ++    paneOwningSurfaces (empty), paneHostSurface
Mattermost/Core/ViewStore.swift                | 147 +++-  ensureStore/release/lastURLs/WebViewReleasePolicy
Mattermost/MattermostApp.swift                 |   9 +-   probe seam
Mattermost/UI/ContentView.swift                | 147 +++-  WebPaneHost + WebPaneReopening (webPaneReopening)
Mattermost/UI/RootView.swift                   | 130 +++-  the only release(serverID:) caller + sweeps
Mattermost/UI/SurfaceHost.swift                |   2 +-
MattermostTests/NotificationWorkerTests.swift  |   4 +-
MattermostTests/SurfaceModeResolverTests.swift |   4 +-
MattermostTests/ViewStoreTests.swift           | 194 +++-  5 new release-policy tests
MattermostUITests/MattermostUITests.swift      | 117 +++-  testReleasedPaneReopensWebViewWithSessionAndHonestState
scripts/perf_probe.sh                          |   5 +-   nativeEvicted in the mode list
scripts/verify-dual-render-gates.sh            |  68 +++   2 new gates
```

Both registries stay empty in the shipping configuration
(`static let nativeApprovedSurfaces: Set<Surface> = []`,
`static let paneOwningSurfaces: Set<Surface> = []`). `release(serverID:)` has exactly one production
call site, `RootView.swift:260`; `PerfProbe.swift:310` is the `#if DEBUG || PERF_PROBE` measurement arm.

## Tests

All verification ran in a worktree of `ed62126`
(`/Users/yangsooyoon/.hermes/profiles/mmios-ios/cache/scratch/r4a-verify`), because the shared checkout
carried a sibling's in-progress `Mattermost/Core/MM/*` that did not compile at the time. `git status`
in that worktree was clean against `ed62126` for every run below.

| Bundle | Where | Result | Verdict line |
|---|---|---|---|
| `MattermostTests` (363 tests) | Mac Catalyst, `build/r4a/logs/catalyst-unit-final.log` | 363 executed, 1 skipped, **0 failures** | `** TEST SUCCEEDED **` |
| `MattermostTests` (363 tests) | iOS Simulator (iPhone 17 Pro, iOS 26.5), `build/r4a/logs/sim-unit-1749.log` | 363 executed, 1 skipped, **0 failures** | `** TEST SUCCEEDED **` |
| `MattermostUITests` dual-render flows | iOS Simulator, `build/r4a/logs/ui-final.log` | 4 executed, **0 failures** | `** TEST SUCCEEDED **` |

The single skip in both unit bundles is the pre-existing opt-in network test
(`MentionPollerTests.testLiveMentionsFetch_optIn`).

`MattermostTests/ViewStoreTests.swift` — the five new tests, all green on both platforms (suite = 14
tests total):

* `testMayReleaseTruthTable` — every row of the four-condition table, including `allowUnapproved`,
  and `navigationInFlight == true` blocking in every other combination.
* `testNavigationInFlightAlwaysBlocksRelease`, `testApprovedButNotPaneOwningNeverReleases`
* `testReleaseKeepsLastURLAndDoesNotPurgeDataStore` — records the committed URL, drops the store, and
  the re-created store keeps the same `dataStoreIdentifier` (asserted through the identifier, not by
  reading cookies).
* `testNonCreatingAccessorNeverResurrects`, `testEnsureStoreReturnsFreshInstanceAfterRelease` (identity
  changes after release, stays stable while alive — keeps `testWebViewInstanceIsStableAcrossSurfaceToggles`)
* `testEmptyRegistriesMakeReleaseUnreachable` — the shipping configuration cannot release at all.

UI flows (the card's four):

* `testReleasedPaneReopensWebViewWithSessionAndHonestState` — PASSED. Asserts sign-in page on the
  first load (it plants the cookie), flips the pane native through the debug inspector, asserts the
  webview is gone and the history chrome is gone, taps "Use web view", asserts the blocking
  `webPaneReopening` state, then the workspace rendering **without** a login form and the chrome back.
  The cookie-session stub's own log for the run (`/private/tmp/mm_stub_8113.log`) alternates
  `session page: sign-in (cookie planted)` on each first load and `session page: workspace after 3.0s
  (cookie present)` on the reopen — the reopened webview presented the persisted `MMAUTHTOKEN`.
* `testLaunchArgumentRendersNativeChannelViewWithChromeIntact` — PASSED (unchanged)
* `testSurfaceInspectorTogglesChannelViewAndReturnsToWorkingState` — PASSED (unchanged)
* `testMidLoadSurfaceToggleResumesTheInterruptedWebview` — PASSED (unchanged)

## Gate script

`bash scripts/verify-dual-render-gates.sh` at `45f3f70` → exit 0, `RESULT: PASS — dual-render debug
affordances cannot reach a Release build.` The two new checks print:

```
== 6. pane ownership is a subset of the -AV approval registry ==
  ok    paneOwningSurfaces is empty (no card owns the pane) — trivially a subset of nativeApprovedSurfaces []
== 7. the release-policy bypass (allowUnapproved: true) compiles only in a debug region ==
  ok    all 1 call site(s) passing allowUnapproved: true are inside a debug region (Mattermost/Core/ViewStore.swift:201); a Release build cannot reach it
```

Both checks were proved to *fail* when violated (temporarily putting `.channelView` in
`paneOwningSurfaces`; temporarily adding an unguarded `allowUnapproved: true` call site — each produced
`RESULT: FAIL`, then reverted): the checks are not vacuous.

## Release build

`xcodebuild build -project Mattermost.xcodeproj -scheme Mattermost -configuration Release -destination
"generic/platform=iOS Simulator" -derivedDataPath build/r4a-release` → `** BUILD SUCCEEDED **`
(`build/r4a/logs/release.log`).

| Literal | Debug (`Mattermost.debug.dylib`) | Release (`Mattermost.app/Mattermost`) |
|---|---|---|
| `releaseWebViewForTesting` | 1 | **0** |
| `webPaneReopening` | 1 | 2 (a shipping a11y identifier) |

`SWIFT_ACTIVE_COMPILATION_CONDITIONS` is empty for Release (no `DEBUG`), `SWIFT_OPTIMIZATION_LEVEL = -O`.
The Debug hit is the control that the technique discriminates: the same `strings` scan finds the literal
in the DEBUG build and not in the Release executable, so the release path cannot be armed in a shipping
build even by a launch argument.

Pre-existing, not from this card: `-uiTestResetPersistedState` (the T26 XCUITest reset seam in
`MattermostApp.init`, written by T26, untouched here) *is* present in the Release binary (2 hits) because
that guard was never wrapped in `#if DEBUG`. Flagged for the owner of that seam; it does not affect the
release policy (the policy's own seam is DEBUG-gated and stripped).

## Perf (§12.6 metric)

`bash scripts/perf_probe.sh --skip-build --targets catalyst --modes web,shell,native,nativeEvicted
--repeat 2 --no-baseline --out-root build/perf-r4a-final`

* run root: `/Users/yangsooyoon/.hermes/profiles/mmios-ios/cache/scratch/r4a-verify/build/perf-r4a-final/20261024-175054`
* `failed runs: 0`; every arm `probe.failed_stages == []`
* `--targets catalyst` because no Simulator `PERF_PROBE` build exists on this host (`build/perf-sim`
  absent); the T27 baseline this is compared against is the Catalyst one.
* every arm: `tracked_pids.webcontent | length` checked (T27-AV F2 double-count guard) — 1 for `web`
  and `native`, **0** for `nativeEvicted` and `shell`.

Steady kernel `phys_footprint` (MiB, from each `run.json` `.steady.snapshot.phys_footprint_bytes`),
repeat 1 / repeat 2:

| arm | steady MiB | Δ vs shell | WebContent pids | WebContent RSS (MB) | peak total RSS (MB) |
|---|---|---|---|---|---|
| `web` | 494.2 / 495.7 | +464.7 / +466.2 | 1 / 1 | 832.7 / 835.9 | 1136.8 / 1142.6 |
| `native` | 281.5 / 280.1 | +252.0 / +250.6 | 1 / 1 | 445.1 / 428.2 | 713.4 / 696.4 |
| `nativeEvicted` | **34.9 / 35.2** | **+5.4 / +5.7** | **0 / 0** | **0 / 0** | 609.2 / 595.8 |
| `shell` | 29.5 / 29.5 | — | 0 / 0 | 0 / 0 | 85.0 / 85.1 |

Reading:

* `nativeEvicted` shows `webcontent == []` and sits **5.4–5.7 MiB above the shell floor** — the card's
  bar was ≤ shell + 60 MiB. The per-server webview's memory is returned, not parked.
* `native` (this card's "before" on the same build) still carries one live WebContent and 281 MiB steady;
  releasing it is worth **~246 MiB** steady, and the WebContent process disappears entirely.
* `nativeEvicted`'s *peak* (609.2 / 595.8 MB) still contains the WebContent its store spun up before
  release (345.3 / 322.0 MB) — peak is not the number to read for release, and §12.6 says so.
* The `web` arm lands ~12 % below T27's published 592.1 MB, i.e. the same non-reproduction T27-AV
  measured on four re-runs (493–527 MB). No claim here rests on that absolute number; the metric is the
  evicted-vs-shell delta.
* Per-arm `run.json` copies: `evidence/perf/catalyst-<arm>[-r2].run.json`.

## Screenshots

* `evidence/webPaneReopening.png` — the blocking return state: spinner + "Reopening web view…" in the
  pane, native chrome strip still mounted, no web content.
* `evidence/reopened-session-intact.png` — the same pane a moment later: the stub's signed-in workspace
  ("Workspace", sidebar, seeded post) with the webview chrome back and **no sign-in form**.

Both are `XCTAttachment` screenshots taken by the test itself
(`add(XCTAttachment(screenshot:))`, `lifetime = .keepAlways`) and exported from the passing
`.xcresult` of this session's UI run
(`build/r4a-sim/Logs/Test/Test-Mattermost-2026.10.24_17-53-46-+0800.xcresult`, test
`testReleasedPaneReopensWebViewWithSessionAndHonestState`, 38.4 s, passed);
`evidence/screenshots-manifest.json` is that export's manifest.

Note on `scripts/perf_probe.sh`: the only change in `ed62126` is adding `nativeEvicted` to the
`--modes` vocabulary (+5/−2); the harness itself (collection, sampling, reporting) is T27's, untouched.

## Notes for the -AV audit (t_9eb2954f)

1. `paneOwningSurfaces` is empty by design, so `allowUnapproved` alone can never reach `release(...)`.
   The DEBUG-only `-releaseWebViewForTesting` launch flag stands in for **both** -AV claims (approved
   and pane-owning) for the duration of a UI-test run; the pure predicate still requires pane ownership,
   and the seam supplies the claim rather than weakening the rule (`testEmptyRegistriesMakeReleaseUnreachable`
   pins this).
2. The honest state's gate is `isReopen && !hasFinishedPageLoad`, not `url == nil`: `WKWebView.url`
   becomes non-nil at the *start* of the provisional navigation, so a url gate never shows for a slow
   return load.
3. `PerfProbe`'s `nativeEvicted` arm calls the production `release(serverID:)` directly rather than
   routing through `WebViewReleasePolicy` with `allowUnapproved: true`; the reason is in the code
   (`Mattermost/Core/PerfProbe.swift:298-303`) — a measurement arm must not fake an `-AV` claim about a
   card. The gate therefore sees exactly one `allowUnapproved: true` site.
4. `docs/dual-render.md` gained a factual status paragraph for R4a (`45f3f70`) including the measured
   numbers above; §12 itself is untouched.
