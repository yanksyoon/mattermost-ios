# T46-AV-R — re-validation of criterion 1 on the repaired Boards/plugin surfaces

Card: `t_54c49efc` (T46-AV-R). Audit target: **`6affb0f`** — the commit reachable from `origin/main`
(`git ls-remote` = local `HEAD` = `6affb0f6f01ae3db576132c620937e6e8bf9a3a6` at audit time), i.e. T46-R's
repair of T46-AV's FAIL (`docs/t46-av-verdict.md` §1/§3/§4) on T46 (`91399de`). Re-measured from this
tree and from my own runs, not from T46-R's summary.

---

## VERDICT: FAIL

Criterion 1's **Boards** half is now real: the sheet asks the server which plugins it serves, renders
"Boards is not enabled on this server." on this fixture, and **issues no `/boards` request at all** —
measured on the server side, not inferred from the app. The session and leak evidence also holds (R4,
R5), with one artifact mismatch (§3 F4).

The **plugin-route** half is not done as the card defines it: the card says "the row, sheet title and
prompt must say 'Plugin route'", and the **sidebar row still reads "Plugin screen…"**.

```
PROBE row webFallbackRow.plugin: exists=true label=Plugin screen…
PROBE prompt navigationBar 'Plugin route' exists: true
```

`Mattermost/UI/Native/Sidebar/ChannelSidebarView.swift:263` hard-codes `Label("Plugin screen…")`; the
plugin row never reads `WebFallbackSurface.rowTitle` (only the `fixedMenu` loop above it does), so
T46-R's `rowTitle` change reached a property the shipped row does not use. T46-R's unit test
`T46WebFallbackTests.swift:38` asserts that unused property, which is why the suite is green over a
reader-facing label that still promises a screen. Screenshot:
`docs/t46-shots/t46avr-webview-row-labels.png` (Web view section: Boards, Playbooks, System Console,
**Plugin screen…**).

Repair card: **`t_14afc3a5`** (mmios-ios). Every other item below is PASS with its measurement.

---

## 1. What I ran

Server: fixture `mm-perf` (`mattermost/mattermost-team-edition:release-9`, 9.11.19) on
`http://127.0.0.1:8065`; account `perfprobe` (`system_admin system_user`), password from
`scripts/perf_seed.py`. Simulator: iPhone 16 Pro `81A7F251-8B31-4945-8783-5A264C14B8D5`. Host: macOS
26.3.1, Xcode 26. Worktree: a detached checkout of `6affb0f` (the shared checkout is shared with other
cards).

### 1.1 Unit suite — Mac Catalyst, clean derived data

```
python3 scripts/qa-test.py --platform mac \
  --derived-data ~/Library/Developer/Xcode/DerivedData/t46avr-units \
  --label t46avr-units-1 --only-testing MattermostTests -- \
  -clonedSourcePackagesDirPath ~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa/SourcePackages
```

```
Executed 1900 tests, with 9 tests skipped and 0 failures (0 unexpected) in 72.680 (73.610) seconds
Test Suite 'T46WebFallbackTests' passed ... Executed 34 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

`build/logs/t46avr-units-1.log`. T46-R's "1900 run / 9 skipped / 0 failed" and the 34-test T46 suite
reproduce exactly (`1891 → 1900` was the nine capability-gate tests).

### 1.2 Live suite + leak probe, through a loopback tee

The pane's `webFallbackPane` value is the **app's** claim ("I did not navigate"). To check that claim
from the other side of the socket, the whole live suite was pointed at a raw TCP tee on
`127.0.0.1:8077` forwarding to the fixture on `8065`, logging every request line. (The tee is a
throwaway instrument: it lived outside the repo and is described in §4.)

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8077 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<scripts/perf_seed.py> \
python3 scripts/t46_leak_probe.py --run-test --sim id=81A7F251-… \
  --label t46avr-live-2 --only-testing MattermostUITests/T46WebFallbackUITests
```

```
Test Case '…testBoardsIsEitherPaintedOrSaysItIsNotEnabled' passed (13.218 seconds)
Test Case '…testPlaybooksOpensAtItsOwnRoute' passed (16.269 seconds)
Test Case '…testTheSystemConsoleOpensSignedInAndReturnsToTheShell' passed (16.405 seconds)
Test Case '…testAPluginRouteIsAddressableByID' passed
Test Case '…testTwentyOpenCloseCyclesEachRender' passed
Executed 5 tests, with 0 failures (0 unexpected) in 209.758 (209.766) seconds
** TEST SUCCEEDED **
```

`build/logs/t46avr-live-2.log`, `build/logs/t46avr-live-2.probe.out`. T46-R's "5 tests, 0 failures"
reproduces (209.8 s here, 228 s there).

The states it printed:

```
T46 boards outcome: notEnabled — Boards is not enabled on this server.
T46 webFallbackRow.systemConsole state: loaded|installed|…:8077/admin_console/about/license|chars=2147|requested=…/admin_console
T46 plugin route state: loaded|installed|…:8077/ops/channels/town-square|chars=1567|requested=…:8077/plugins/com.mattermost.calls
```

The tee's log for the same run (`build/t46-leak/t46avr-live-2-proxy.log`, 2 029 lines / 1 615 request
lines):

```
$ grep -c 'GET /boards' build/t46-leak/t46avr-live-2-proxy.log
0
$ grep -c 'GET /api/v4/plugins/webapp' build/t46-leak/t46avr-live-2-proxy.log
25
```

**No `/boards` request was issued anywhere in the run** — not by the Boards test, not by the twenty
console cycles, not by the web app itself. (The 25 `plugins/webapp` lines are the gate plus the web app's
own boot fetch on each page.)

### 1.3 Leak probe (same run)

```
  samples        : 459 over 255.5s
  baseline WC    : 1 WebKit WebContent process(es) before launch (excluded)
  peak WC        : 3 (limit 4)
  at rest WC     : 0 while the app was alive and idle (37 samples)
  final WC       : 0 after 15s idle
RESULT: PASS
```

`build/t46-leak/t46avr-live-2.json`; the suite's own `T46_AT_REST_BEGIN`/`END` pair is in the log
(`grep -c T46_AT_REST build/logs/t46avr-live-2.log` → 2). **Peak here was 3, not T46-R's 1** (§3 F5).
At rest 0 over 37 samples and final 0 both reproduce.

### 1.4 Negative control — does the probe FAIL when it should?

A temporary UI test (`T46AVRBreakUITests`) drove the same `T46_AT_REST_BEGIN`/`END` window **with a
fallback sheet left open**:

```
[t46] at-rest worst sample: 1 attributed WebContent process(es) at t+24.0s (raw pids [53559], orphans excluded [])
  at rest WC     : 1 while the app was alive and idle (38 samples)
RESULT: FAIL - 1 WebContent process(es) alive while the app was idle with no sheet presented
```

`build/logs/t46avr-break-1.probe.out`, `build/t46-leak/t46avr-break-1.json`, exit code 1. The PASS in
§1.3 is therefore not a blind instrument: with a webview deliberately held across its window it reports
FAIL.

### 1.5 Boards probe — what the not-enabled sheet actually contains

A temporary UI test (`T46AVRBoardsProbeUITests`) tapped `webFallbackRow.boards` and read the sheet's own
tree, with the tee logging requests for that run only:

```
PROBE boards statement: Boards is not enabled on this server.
PROBE boards pane exists: true
PROBE boards pane value: Optional(idle|none|-|requested=http://127.0.0.1:8077/boards)
PROBE boards unavailable state exists: true value=Optional(notEnabled)
PROBE boards checking state still on screen: false
```

`build/logs/t46avr-probe-boards.log`. The tee for that run
(`build/t46-leak/t46avr-probe-boards-proxy.log`, 37 lines): `1` request for `/api/v4/plugins/webapp`
(the gate) and `0` for `/boards`. This is the difference between the fix and a caption over a blank page:
the caption is on screen, the pane is `idle` with committed URL `-`, and the server was never asked for
`/boards`.

### 1.6 Capability gate — an unanswered probe is not "not enabled"

The shipped tests inject the lister. A temporary unit probe (`T46AVRProbeTests`) exercised the **real**
request path:

```
PROBE wrong-port listing: nil in 0.0557s
PROBE fixture listing: ["com.mattermost.calls", "com.mattermost.nps", "playbooks"]
PROBE boards availability: notEnabled("focalboard") store.url=nil lastRequested=nil
```

`build/logs/t46avr-probe-unit2.log` (2 tests, 0 failed). A closed port gives `nil` in 56 ms — not an
empty set — and the model treats `nil` as "could not ask" (`.available`, the surface still opens), which
is pinned by `testAnUnansweredPluginListingStillOpensTheSurface` and by the endpoint tests for a 5xx and a
non-JSON body. With the real fixture listing the gate refuses, and **nothing is requested or committed**
(`store.url = nil`, `lastRequestedURL = nil`).

### 1.7 Plugin-row label probe

```
PROBE row webFallbackRow.boards: exists=true label=Boards
PROBE row webFallbackRow.playbooks: exists=true label=Playbooks
PROBE row webFallbackRow.systemConsole: exists=true label=System Console
PROBE row webFallbackRow.plugin: exists=true label=Plugin screen…
PROBE prompt navigationBar 'Plugin route' exists: true
PROBE prompt field exists: true
```

`build/logs/t46avr-probe-labels.log`; screenshot exported into
`docs/t46-shots/t46avr-webview-row-labels.png`. The sheet and the prompt say **route**; the row does not.

---

## 2. The card's items, measured

| # | Item | Verdict | Measurement |
|---|---|---|---|
| 1 | **Boards** statement, no navigation, no `/boards` request | **PASS** | `T46 boards outcome: notEnabled — Boards is not enabled on this server.`; pane `idle\|none\|-\|requested=…/boards`; `unavailable` value `notEnabled`; **0** `GET /boards` in the tee for the suite (§1.2) and for a dedicated Boards probe (§1.5) |
| 1b | the **painted** half (a server that serves focalboard) | **NOT MEASURED** | the fixture serves no `focalboard` (`GET /api/v4/plugins/webapp` → calls, nps, playbooks) and I did not install it; unit-tested only with an injected listing (`testASurfaceWhosePluginTheServerServesLoads`). Stated in `docs/dual-render.md` §13.7 and `docs/t46-build-note.md` §9.1 |
| 2 | the capability gate's honesty (`nil` vs empty set) | **PASS** | real wrong port → `nil` in 55.7 ms; real fixture → the set without `focalboard`; `nil` still opens the surface (unit test + code path); a 5xx / garbage body → `nil` (unit) |
| 3 | **Plugin route**: row, sheet title, prompt; shot renamed; no doc calls it a screen | **FAIL** | sheet title `Plugin route: com.mattermost.calls` and prompt `Plugin route` are asserted and pass; **the row's label is `Plugin screen…`** (§1.7); `t46-plugin-screen.png` is gone (renamed in `6affb0f`) but `docs/dual-render.md` §13.2, `docs/parity.md`'s T46 row and two shipped doc comments still describe the row as a route it does not say |
| 4 | Session: docs claim only the re-install; names-only observable; no cookie value in a log | **PASS** | my run: **43** `\|installed\|`, **0** `\|shared\|`, **0** `\|none\|`, **0** `\|cookies=` (the jar read was empty at every decision, i.e. T46-R's runs B/C behaviour); T46-R's run A log carries 32 `\|cookies=MMAUTHTOKEN,MMCSRF,MMUSERID,rl_…` lines — **names only**; no `MMAUTHTOKEN=` and no token-shaped literal in my logs; `docs/dual-render.md` §13.3/13.4 claim only the re-install |
| 5 | Leak: at rest **while alive**, orphans excluded, probe can fail | **PASS** | at rest 0 over 37 samples inside the suite's own window, final 0, peak 3 ≤ 4; negative control FAILs (at rest 1) when a sheet is held across the window; baseline app pids recorded (`[47416]`) in my run and in `t46r-live-6.json` |
| 6 | Docs: §13.6's false sentence gone; numbers match or are corrected | **PASS WITH FINDINGS** | no "asserted on the committed URL" claim survives in `dual-render`/`build-note` (only quoted as the finding); units and live numbers reproduce; **peak differs (3 vs 1)** and the live-5 orphan narrative does not match its artifact (§3 F4/F5) |
| — | Negative space (§13.7) stated, not treated as new failures | **PASS** | `docs/dual-render.md` §13.7 lists all six gaps T46-AV §4 named; I added none |

---

## 3. Findings

### F1 — the plugin row still says "Plugin screen…" (the FAIL) — item 3

```
$ sed -n '258,266p' Mattermost/UI/Native/Sidebar/ChannelSidebarView.swift
            // A plugin screen is whatever the plugin serves at `/plugins/<id>`; the id is the only
            // thing the shell cannot know, so this row asks for it instead of guessing a list.
            Button {
                webSheet = .pluginPrompt
            } label: {
                Label("Plugin screen…", systemImage: "puzzlepiece.extension")
```

Measured label: `Plugin screen…` (§1.7). The sheet and prompt are correct, so the repair is half applied;
and because the unit test pins `rowTitle` — a property only `fixedMenu` reads — no test notices. Failing
sentence in the docs: `docs/dual-render.md` §13.2's table ("Plugin route… | `webFallbackRow.plugin`"),
`docs/parity.md`'s T46 row ("with `rowTitle` so the plugin row says \"Plugin route…\"").

### F2 — stale "Plugin screen" doc comments in shipped source

`Mattermost/UI/Native/Web/WebFallbackSurface.swift:174` — "it is reached through its own row
(\"Plugin screen…\")" (about `fixedMenu`, where the row is no longer called that) — and
`Mattermost/UI/Native/Web/WebFallbackView.swift:213` — "The \"Plugin screen…\" prompt:" (its title is
"Plugin route"). The type is still `PluginScreenPrompt`. No functional effect; they are exactly the
documentation item 3 says must not survive.

### F3 — the Boards test's decisive assertion is conditional

`MattermostUITests/T46WebFallbackUITests.swift:146` wraps the "no navigation" assertions in
`if pane.exists`. Measured: the pane **does** exist in the not-enabled state (§1.5), so the assertion ran
in this build — but a change that hides the pane from the accessibility tree turns it into a silent
no-op and the test still passes. Low severity, worth hardening while the row label is being fixed.

### F4 — `docs/t46-build-note.md` §9.5's live-5 "orphan" is not what its own JSON records

§9.5 says live-5 "shows pid 18048 alive through all 38 at-rest samples **and still alive 15 s after the
app exited** … under this rule it is an orphan". The artifact says:

```
$ grep -E '"(at_rest_webcontent|final_webcontent|final_app_alive)"' build/t46-leak/t46r-live-5.json
  "at_rest_webcontent": 1,
  "final_webcontent": 1,
  "final_app_alive": true
```

and it has **no `baseline_app_pids` key**; its samples carry `"app_pid": 47416` — the stale Catalyst
`Mattermost` app on this host, not the simulator app under test. So that run cannot show "the app
exited": it recorded the app as alive, which is the attribution bug §9.5 says was fixed. Under the
current rule a re-score would either exclude 18048 (baseline catching 47416, as in `t46r-live-6.json` and
my run) or FAIL the run — the committed JSON supports neither sentence. `docs/dual-render.md` §13.4
repeats the claim.

### F5 — "peak 1" is a run-specific number, not a property

`docs/t46-build-note.md` §9.5, `docs/dual-render.md` §13.4 and `docs/parity.md` cite "peak 1". My run of
the same suite on the same fixture measured **peak 3** (limit 4) with the same PASS. Also 37 at-rest
samples against their 41 (interval-dependent), both all-zero. The contract (peak ≤ 4, at rest 0) holds;
the peak is not stable, and the docs should attribute it to its run.

### F6 — the probe's FAIL message names a state it cannot know

The FAIL text is "…alive while the app was idle with no sheet presented", but in my negative control a
sheet **was** presented by design — the probe counts processes, it does not know whether a sheet is up.
Cosmetic; worth rewording to "at rest (the suite's window)".

---

## 4. Host state I changed

* **The fixture's Docker VM died mid-audit** and I restarted it: at 01:16 direct `curl` to
  `127.0.0.1:8065` hung, `docker` CLI hung on a pre-existing `docker exec … psql` (another card's
  process, left alone), and `docker ps -a` afterwards showed `mm-perf` and `mm-perf-db` `Exited (255)`.
  I quit and relaunched Docker Desktop, then `docker start mm-perf-db`, `docker start mm-perf`.
  Verified: `/api/v4/system/ping` 200, `GET /api/v4/plugins/webapp` → calls/nps/playbooks **still no
  focalboard**, `POST /users/login` for `perfprobe` 200. No fixture data or plugin set changed. Run
  `t46avr-live-1` was launched into that outage (5 skipped, "no Mattermost server at 127.0.0.1:8077") and
  is **not** used as evidence.
* Created, measured and deleted four probe files in the worktree (not committed):
  `MattermostTests/T46AVRProbeTests.swift`, `MattermostUITests/T46AVRBoardsProbeUITests.swift`,
  `MattermostUITests/T46AVRBreakUITests.swift`, `MattermostUITests/T46AVRLabelProbeUITests.swift`.
* The loopback tee (`proxy.py`, outside the repo) is not committed; its logs are
  `build/t46-leak/t46avr-*-proxy.log`.
* Killed a runaway `pyright-langserver` (17.8 % of memory) of my own profile during the outage; not part
  of the tested system.
* Added `docs/t46-shots/t46avr-webview-row-labels.png` (the sidebar's Web view section, exported from the
  label probe's `xcresult`).

## 5. What this host cannot validate

* **Boards on a server that serves focalboard** — the fixture ships none and I did not install it; the
  "painted" half of the row's contract is unmeasured here (unit-tested with an injected listing only).
* **A plugin route that serves a real plugin page** — `/plugins/<id>` 301s to `/` on 9.11.19 for every
  installed plugin; my run reproduces the workspace render (`/ops/channels/town-square`, `chars=1567`).
* No APNs, no second server, no non-admin account on the fixture; the §13.7 gaps (Back button, dark
  mode/Dynamic Type/VoiceOver, SSO-established session, server-side survival) remain stated, not measured.

---

## 6. Gates

Units, live and the leak probe ran as in §1. `python3 scripts/verify-pushed.py` for this verdict commit is
quoted in the card's closing comment / summary. The dual-render gate script was run on the doc edits this
card makes (see the closing comment).
