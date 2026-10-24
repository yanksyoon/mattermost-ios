# T26-R — dual-render harness follow-ups (AV findings F1–F6)

Date: 2026-10-24 · Host: macOS 26.3.1, Xcode 26.6 (17F113) · Repo:
`/Users/yangsooyoon/Documents/yanks/code/mattermost-ios` (branch `main`, on top of T26 `8a91318`)
Repair card: `t_96f5f1c9` (from validator `t_04eafa2c`, verdict PASS-WITH-FINDINGS).
Contract of record: **`docs/dual-render.md`** (updated by this card).

## 1. What this card changes

| # | Finding | Resolution |
|---|---|---|
| R1 | unit-bundle skip misattributed to the live-SSO test | `docs/t26-build-note.md` §7 now names the correct test per bundle (unit: `MentionPollerTests.testLiveMentionsFetch_optIn`; UI: `testSSOReachesIdentityProviderWithoutCertificatePrompt`) |
| R2 | persisted override had no Release gate | **choice (a)**: tiers 1+2 are read only when `SurfaceModeResolver.debugAffordancesEnabled` (`#if DEBUG`), and a Release build writes nothing (`persist()` early-returns). Consequence documented: a Debug→Release upgrade drops the stored choice. |
| R3 | `-AV` gate covered only the compile-time default | made structural: `setOverride`/`clearOverride`/`clearAllOverrides` inside `#if DEBUG`, single initialiser taking the gate is `private`, `SurfaceInspector.swift` wholly `#if DEBUG`, plus `scripts/verify-dual-render-gates.sh`. §5 now enumerates every route to a native decision. |
| R4 | native surfaces still load the webview (no memory win) | documented in `docs/dual-render.md` §11; the eviction/parking decision is filed as `t_58d5611e` (architect) — not implemented here. |
| R5 | reset semantics vs launch override | reset paths now drop launch overrides too (`clearAllOverrides` clears both tiers; `clearOverride` clears that surface's launch entry); "Reset all" is enabled by `hasAnyOverride` |
| R6 | mid-load toggle could strand a stopped webview | **reproduced** with a new XCUITest + slow-subresource stub, then **fixed** in two variants: `WebViewStore.loadNeed`/`loadIfNeeded(_:)` resumes a committed-but-unfinished navigation, and `stopForDismantle()` records the interruption synchronously so a KVO-lagged `isLoading` cannot answer "in flight, leave it alone" (the batch run exposed this second race after the first fix). A stopped navigation is also no longer recorded as a `pageError` (`markPageLoadFailed`/`isCancellation`) |

## 2. Code changes (surgical)

| File | Change |
|---|---|
| `Mattermost/Core/SurfaceModeResolver.swift` | `isDebug` → `debugAffordancesEnabled` (`#if DEBUG || PERF_PROBE` — see §4); one `private` initialiser takes the gate; explicit empty-tier branch; `decodePersistedOverrides` extracted; writers (`setOverride`, `clearOverride`, `clearAllOverrides`) moved inside `#if DEBUG`; `clearOverride`/`clearAllOverrides` also drop launch overrides; `hasAnyOverride`; `persist()` returns early without debug affordances; DEBUG-only `releaseSemantics(...)` test seam |
| `Mattermost/UI/SurfaceInspector.swift` | whole file wrapped in `#if DEBUG`; "Reset all" enabled on `hasAnyOverride` |
| `Mattermost/Core/WebViewStore.swift` | `hasFinishedPageLoad` + `markPageLoadStarted/Finished`; `LoadNeed` + pure `loadNeed(...)` + `loadIfNeeded(_:)` (load / resume / leave alone); `stopForDismantle()` records an interrupted page synchronously; `markPageLoadFailed`/`isCancellation` keep a stopped navigation resumable; `load()` clears the finished flag |
| `Mattermost/UI/WebViewContainer.swift` | coordinator calls `markPageLoadStarted()` (didStartProvisional) and `markPageLoadFinished()` (didFinish); failure callbacks route through `markPageLoadFailed`; `dismantleUIView` calls `store.stopForDismantle()` instead of touching `webView.stopLoading()` directly |
| `Mattermost/UI/ContentView.swift` | `loadIfNeeded()` (the `url == nil` guard) replaced by `store.loadIfNeeded(server.url)` on both appear paths |
| `scripts/verify-dual-render-gates.sh` | **new**: mechanical gate for R2/R3 (writer declarations + call sites inside `#if DEBUG`, read-path/persist gate, private initialiser, inspector wrapper, no `remoteDefault` producer, `PERF_PROBE` absent from project settings, empty registry) |
| `MattermostTests/SurfaceModeResolverTests.swift` | +7 tests (R2 Release semantics via the seam, R5 reset/hasAnyOverride) |
| `MattermostTests/WebViewStoreTests.swift` | +5 tests (`testLoadNeedTruthTable`, `testStopForDismantleRecordsOnlyUnfinishedPages`, `testCancellationIsNotAPageError`, `testGenuineFailureIsAPageError`, `testLoadIfNeededLeavesAFinishedPageAlone`) |
| `MattermostUITests/MattermostUITests.swift` | +1 UI flow (`testMidLoadSurfaceToggleResumesTheInterruptedWebview`) + `stubStalledHTTP` constant + `isFixtureReachable` preflight (the flow skips with the stub command when `:8112` is not running, instead of failing on a missing gitignored fixture) |

`build/uitest-server/mm_stub.py` gained `--stall-image SECONDS` (slow `/slow.png` + `onload`-gated
`Sign in` button). **That path is gitignored** (`.gitignore:2` = `build/`), like the whole stub
fixture, so the change is reproduced verbatim in §6 below: start the stub like this before running
the new UI flow:

```
python3 build/uitest-server/mm_stub.py --port 8112 --stall-image 45 --name "Slow Test"
```

## 3. Evidence

### Gate script (R2/R3)

```
$ bash scripts/verify-dual-render-gates.sh
== 1. arbitrary-mode writers are declared and called only inside #if DEBUG ==
  ok    setOverride declared inside #if DEBUG (Mattermost/Core/SurfaceModeResolver.swift:161)
  ok    clearOverride declared inside #if DEBUG (Mattermost/Core/SurfaceModeResolver.swift:171)
  ok    clearAllOverrides declared inside #if DEBUG (Mattermost/Core/SurfaceModeResolver.swift:180)
  ok    every call site of setOverride/clearOverride/clearAllOverrides is inside #if DEBUG
== 2. tiers 1 and 2 are gated behind the compile-time debugAffordancesEnabled ==
  ok    debugAffordancesEnabled is a compile-time DEBUG (or DEBUG || PERF_PROBE) true/false constant
  ok    read path (init) decodes no override when debug affordances are off
  ok    the one initialiser that takes the flag is private
  ok    persist() writes nothing when debug affordances are off
== 2b. PERF_PROBE (the only other way to enable the debug tiers) is not in the project ==
  ok    PERF_PROBE appears in no .pbxproj/.xcconfig/project.yml — command line only
== 3. the inspector view is entirely #if DEBUG ==
  ok    Mattermost/UI/SurfaceInspector.swift is wrapped in a single #if DEBUG ... #endif
== 4. no production producer for the remote (tier 3) default ==
  ok    no production assignment to remoteDefault (tier 3 stays a seam)
== 5. the -AV approval registry ==
  ok    nativeApprovedSurfaces is empty (no surface is native-by-default)

RESULT: PASS — dual-render debug affordances cannot reach a Release build.
$
```

**Negative controls** (the gate is not vacuous — both were run and reverted):

* making the flag-taking initialiser non-`private` →
  `FAIL  the initialiser taking debugAffordances is not private (Release code could opt in)`, exit 1;
* putting `SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) PERF_PROBE` in an `.xcconfig` →
  `FAIL  PERF_PROBE is defined in project build settings …` (`./NegativeProbe.xcconfig:1`), exit 1.
  After removing it: `RESULT: PASS`, exit 0.

### Mac Catalyst, full unit suite

```
xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build/ddata-t26r -only-testing:MattermostTests DEBUG_INFORMATION_FORMAT=dwarf
```

* `Executed 347 tests, with 1 test skipped and 0 failures (0 unexpected) in 4.004 s`
* `** TEST SUCCEEDED **` — exit 0
* Log: `docs/t26r-catalyst-unit-2026-10-24.log`
* 335 → 347: +7 resolver tests (R2/R5) +5 webview tests (R6). The 1 skip is the same network-gated
  `MentionPollerTests.testLiveMentionsFetch_optIn` (R1).

### R6 repro — pre-fix (the bug, on the simulator)

`testMidLoadSurfaceToggleResumesTheInterruptedWebview`, launched **before** the fix was applied,
against `mm_stub.py --port 8112 --stall-image 45`:

* the stub log showed `stalled-page served` **twice** (page load + a duplicate `onAppear` load) and
  `slow.png requested` twice — all **before** the toggle; **no request after it**;
* the test's 75 s wait for `Sign in` expired (`t = 113.94s  Collecting debug information to assist
  test failure triage`), i.e. the interrupted navigation was never resumed and the pane stayed
  incomplete. Reproduction confirmed.
* The run was killed during failure triage (this host wedges `xcodebuild` while symbolizing a
  failure — the same host limit T26 recorded), so the pre-fix log has no verdict line; the step log
  and the stub's request log are the evidence.
* Log: `docs/t26r-ui-repro-pre-fix-2026-10-24.log`.

### iOS Simulator — unit suite + the three dual-render UI flows (post-fix)

```
xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=iOS Simulator,id=81A7F251-8B31-4945-8783-5A264C14B8D5' \
  -derivedDataPath build/ddata-t26r-ios \
  -only-testing:MattermostTests \
  -only-testing:MattermostUITests/MattermostUITests/testLaunchArgumentRendersNativeChannelViewWithChromeIntact \
  -only-testing:MattermostUITests/MattermostUITests/testSurfaceInspectorTogglesChannelViewAndReturnsToWorkingState \
  -only-testing:MattermostUITests/MattermostUITests/testMidLoadSurfaceToggleResumesTheInterruptedWebview \
  DEBUG_INFORMATION_FORMAT=dwarf
```

* Unit: `Executed 347 tests, with 1 test skipped and 0 failures (0 unexpected) in 2.509 s`
* `testLaunchArgumentRendersNativeChannelViewWithChromeIntact` — **passed (17.675 s)**
* `testSurfaceInspectorTogglesChannelViewAndReturnsToWorkingState` — **passed (43.071 s)**
* `testMidLoadSurfaceToggleResumesTheInterruptedWebview` — **passed (79.236 s)**: with the fix in
  place the interrupted load is re-issued when the web branch returns, the stub serves `/` and
  `/slow.png` again, and `Sign in` appears — the same flow that failed pre-fix (§3). The stub's own
  log for this run shows two `stalled-page served` lines and two `slow.png requested` lines, i.e. one
  original load plus the resume.
* `** TEST SUCCEEDED **` — exit 0
* Log: `docs/t26r-ios-unit-and-dual-render-2026-10-24.log` (this log is the **batch** run — all three
  UI flows in one `xcodebuild` invocation, the configuration that exposed variant 2 of R6).
* Prerequisite for the third flow: the slow stub must be running:
  `python3 build/uitest-server/mm_stub.py --port 8112 --stall-image 45 --name "Slow Test"`
  (plus the usual `:8111` HTTP and `:8443` TLS stubs for the other two). If it is not, the flow
  **skips** with that command in the message (`isFixtureReachable` preflight) rather than failing.

### R6, variant 2 — the batch run exposed a second way to strand the page

After the first fix, a batch run (the same command as above) failed the mid-load flow once at
14:23 — `Waiting 75.0s for "Sign in" Button` started at `t = 39.41s` and triage began at
`t = 114.49s`, i.e. no resume at all — while single-test runs of the same binary passed. Honest
limits of that datapoint: the run was killed by this session's command timeout during triage, the
stub instance in use had no log redirection, and the log at
`docs/t26r-ios-unit-and-dual-render-2026-10-24.log` was **overwritten by the verifying re-run** that
now sits there, so the failing run's full output and `.xcresult` are not preserved.

What the code said: `loadNeed` consulted `webView.isLoading`, which `stopLoading()` flips to `false`
**asynchronously** (KVO). A re-attach inside that window read `true`, answered "in flight, leave it
alone" — and nothing ever retried. Fix: `stopForDismantle()` records the interruption synchronously
at the moment the branch goes away, and that recorded fact is consulted **before** `isLoading`
(`testLoadNeedTruthTable`'s stale-`isLoading` row, `testStopForDismantleRecordsOnlyUnfinishedPages`).
The same round added `markPageLoadFailed`/`isCancellation`: a stopped navigation
(`NSURLErrorCancelled`, WebKit 102) must not become `pageError`, because that both paints the retry
overlay over a paused page and makes `loadNeed` answer `.none`. Instrumentation note: a temporary
`NSLog` in that path never fired during the passing runs (`[t26r-diag]` absent from the log), so the
cancellation handling is **defensive and unit-pinned**, not the cause of the batch failure — that was
the `isLoading` race. The re-run in the batch configuration passed (79.2 s, `** TEST SUCCEEDED **`).

### Release build gate (R2)

```
xcodebuild build -project Mattermost.xcodeproj -scheme Mattermost -configuration Release \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath build/ddata-t26r-release
```

* `** BUILD SUCCEEDED **` — exit 0 (log: `docs/t26r-release-build-2026-10-24.log`). The DEBUG-only
  in-source gate compiles cleanly: `setOverride`/`clearOverride`/`clearAllOverrides` are absent from
  the Release compile, so `SurfaceInspector.swift` (its only caller) is absent too.
* Binary check on `Release-maccatalyst/Mattermost.app/Contents/MacOS/Mattermost`:

```
Per-surface renderer switch      0
Reset all to defaults            0
surfaceInspectorButton           0
launch override                  0
surfaceInspectorDone             0
mm.surfaceModes                  2
navigation failed                2
```

  The five DEBUG-only strings are gone; `navigation failed` is present because the new
  failure/state logging is Release code by design (it records the decision, not a debug affordance).
  `mm.surfaceModes` survives as an inert literal: the key constant is still compiled (it is
  referenced by `persist()`), but `persist()` early-returns in Release and `init` never decodes the
  tier — so the string proves nothing about behaviour, which is why the behavioural claim rests on
  the source gates (gate script, §3) and the DEBUG-only `releaseSemantics` unit tests rather than on
  `strings`. The Release build was **re-run after the final code changes** (347-test Debug suite
  green) because moving `setOverride`/`clearOverride`/`clearAllOverrides` and the whole inspector
  behind `#if DEBUG` is exactly the kind of edit a Debug-only test run cannot validate.
* **Not proven here:** a *Release-build runtime* run of the toggle path. Driving it would need the
  Release app launched with a pre-seeded `mm.surfaceModes` row and a server configured through the
  UI; the code path is instead pinned by
  `testPersistedOverrideIsIgnoredWithoutDebugAffordances`/`testLaunchOverrideIsIgnoredWithoutDebugAffordances`
  (which construct exactly what a Release compile computes) and by the gate script. Flagged rather
  than faked.

### Clean-tree verification (the commits are self-contained)

T27's untracked perf work was in the tree for every run above, so the two commits were re-verified
from a **detached worktree at HEAD that contains none of it**
(`git worktree add --detach … 64f2d2a`; no `PerfProbe.swift`, no `PerfProbe` reference in
`MattermostApp.swift`, no `-perfProbe` registration in `project.pbxproj`):

```
$ xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
    -destination 'platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath <scratch>/t26r-verify-dd -only-testing:MattermostTests DEBUG_INFORMATION_FORMAT=dwarf
Executed 347 tests, with 1 test skipped and 0 failures (0 unexpected) in 2.927 s
** TEST SUCCEEDED **   (exit 0)
```

* Log: `docs/t26r-clean-tree-verify-2026-10-24.log`. This is the strongest single check on the
  commit split: it proves nothing in the landed code depends on a symbol that only exists in T27's
  uncommitted files.

## 4. Decisions recorded

* **R2 = option (a)** (gate the persisted tier behind `#if DEBUG`), because the `-AV` programme's
  invariant is "an `-AV`-less build stays web everywhere", and a shipped build honouring a
  debug-written `native` row would put a real user on a stand-in. Cost, stated in
  `docs/dual-render.md` §8: a Debug→Release upgrade on the same install drops the stored per-surface
  choice (back to the compile-time default). Revisit condition: when the first surface is approved
  (`nativeApprovedSurfaces` non-empty), the Release escape hatch must become persistent — accepting
  `.web` rows only — which is a deliberate design change, filed with R4's decision card.
* **R5 = make the reset coherent** (rather than document the asymmetry): "Reset all to defaults"
  clears stored rows *and* this run's launch entries, and is enabled by `hasAnyOverride`.
* **R6 = resume, don't remove `stopLoading()`**: the dismantle stays resource-friendly
  (`stopLoading()`), and the shell re-issues a committed-but-unfinished navigation when the web
  branch returns. Keeping `stopLoading()` also keeps the "toggle away" behaviour cheap while §11's
  eviction question is open.
* **R6 variant 2 = record the interruption at dismantle time** (rather than trusting
  `webView.isLoading` or adding a timer/retry loop): the flag is set synchronously in
  `dismantleUIView`, so the resume decision cannot depend on KVO timing. A retry timer was rejected —
  it would paper over the race with latency and could re-issue a load that is genuinely in flight.
* **Cancellations are not page errors** (`markPageLoadFailed`/`isCancellation`): defensive, because a
  stopped navigation must not paint the retry overlay or block the resume. Measured honestly: the
  temporary `NSLog` in that path never fired in the passing runs, so this was not the batch
  failure's cause (see §3).
* **`PERF_PROBE` coordination (T27)**: `debugAffordancesEnabled` is `#if DEBUG || PERF_PROBE` so the
  perf harness (parked behind this card, measuring a Release-optimised binary) can still launch
  `-surfaceMode`. It cannot leak into a shipped build: the condition is passed per-invocation on the
  `xcodebuild` command line, and gate check 2b fails if it ever appears in `.pbxproj`/`.xcconfig`/
  `project.yml`. This is the only cross-card seam in this diff.

## 5. Files / logs

* New: `scripts/verify-dual-render-gates.sh`, `docs/t26r-build-note.md`, this card's logs.
* Untouched on purpose: `Mattermost.xcodeproj/project.pbxproj` and `Mattermost/MattermostApp.swift`
  (T27's untracked `PerfProbe` work was in the tree during this card; it is **not** part of this
  commit, and no new file needed target wiring here). The only T27-facing line in this diff is the
  `PERF_PROBE` clause in `debugAffordancesEnabled` (§4) — it must land *before* T27 runs so the perf
  harness builds against a resolver it can steer.
* Commit split: code (`Mattermost/Core/*`, `Mattermost/UI/*`, `MattermostTests/*`,
  `MattermostUITests/*`, `scripts/verify-dual-render-gates.sh`) is separate from docs
  (`docs/dual-render.md`, `docs/t26-build-note.md`, `docs/t26r-build-note.md` + logs).

## 6. The R6 stub fixture, verbatim (gitignored path)

`build/uitest-server/mm_stub.py` — added on top of the T26 stub:

```python
    def _stalled_html(self):
        """Page whose main document commits fast but whose `<img>` never finishes (R6 fixture)."""
        html = (
            "<html><head><title>Local MM Sign in</title></head><body>"
            "<h1>Local MM Sign in</h1>"
            "<img id='slow' src='/slow.png' style='width:4px;height:4px' "
            "onload=\"document.getElementById('loginButton').hidden=false\">"
            "<button id='loginButton' hidden>Sign in</button>"
            "</body></html>"
        )
        return self._send(200, html, "text/html")

    def _slow_image(self):
        """1x1 GIF trickled across `stall_image` seconds: the image (and the page load) hangs."""
        gif = (b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff!\xf9\x04\x01"
               b"\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;")
        delay = getattr(self.server, "stall_image", 0.0)
        self.send_response(200)
        self.send_header("Content-Type", "image/gif")
        self.send_header("Content-Length", str(len(gif)))
        self.send_header("Connection", "close")
        self.end_headers()
        half = len(gif) // 2
        self.wfile.write(gif[:half])
        self.wfile.flush()
        time.sleep(delay)
        self.wfile.write(gif[half:])
        self.wfile.flush()
```

`GET /` routes to `_stalled_html` when `--stall-image > 0`, `GET /slow.png` routes to
`_slow_image`, and the server class is a `ThreadingHTTPServer` in that mode so the trickled
response cannot block the validation endpoints (`/api/v4/system/ping`, `/api/v4/config/client`).

## 7. Host limits re-confirmed

* `xcodebuild test` wedges while symbolizing a failing assertion (CoreSymbolication); the pre-fix
  R6 run was killed in triage instead of printing a verdict. All verdict lines quoted above are from
  runs that printed the runner's own `** TEST SUCCEEDED **`.
* WebKit exposes web-content accessibility only once a load settles, so XCUITest cannot assert on a
  *partially* rendered document: the R6 flow asserts the incomplete-load precondition as "no
  `Sign in` button yet" and the completion as "`Sign in` appears".
