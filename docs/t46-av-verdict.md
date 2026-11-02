# T46-AV — adversarial validation of the permanent webview escape hatch

Card: `t_c0096b03` (T46-AV). Audit target: **`91399de`** — the commit reachable from `origin/main`
(`git ls-remote origin refs/heads/main` = `91399de862acead8da96a9f6fd00b1a5fcc4040e` at audit time,
which is also local `HEAD`). Re-derived from this tree and from my own runs, not from T46's summary.

---

## VERDICT: FAIL

Criterion 1 ("a working webview of **exactly that surface**") does not hold for two of the four
surfaces it names:

* **Boards** — the row opens a webview that paints 61 characters and shows nothing: a blank navy
  page after 75 s. T46 has **no test that opens the Boards row**, and the docs say one exists
  (`docs/dual-render.md` §13.6: "Boards, Playbooks and the System Console are real server routes and
  are asserted on the committed URL"). Measurement below.
* **plugin screens** — the row addresses `/plugins/<id>`, the server answers `301 → /`, and what the
  reader gets is the **workspace channel view** (Town Square), not the plugin. T46 documents this
  honestly (§7.4) and the shipped `docs/t46-shots/t46-plugin-screen.png` is a picture of exactly that
  — which is evidence for "the web app rendered", not for "this plugin's screen".

Criteria 2 (shared session, no second login), 3 (no leaked webview, on re-run) and 4 (the surfaces
documented) hold on my runs. One doc claim does not (F3), and the session mechanism the card argues
for is never exercised in the app (F4).

---

## 1. What I ran

Server: fixture `mm-perf` (`mattermost/mattermost-team-edition:release-9`, 9.11.19) on
`http://127.0.0.1:8065`; account `perfprobe` (`system_admin system_user`), password from
`scripts/perf_seed.py`. Simulator: iPhone 16 Pro `81A7F251-8B31-4945-8783-5A264C14B8D5`.
Host: macOS 26.3.1, Xcode 26.

### 1.1 Unit suite — Mac Catalyst, **clean derived-data path**

```
python3 scripts/qa-test.py --platform mac \
  --derived-data ~/Library/Developer/Xcode/DerivedData/av-t_c0096b03-run1 \
  --label t46av-units-1 --only-testing MattermostTests -- \
  -clonedSourcePackagesDirPath ~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa/SourcePackages
```

```
Executed 1891 tests, with 9 tests skipped and 0 failures (0 unexpected) in 75.072 (76.620) seconds
Test Suite 'T46WebFallbackTests' passed ... Executed 25 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

`build/logs/t46av-units-1.log`. The 9 skips are pre-existing env-gated suites (CertTrust keychain,
live mention fetch, two `NativeNavigationTests`, two `SelfSignedTrustTests`, three `T44CCallsEngineTests`)
— **none of them is T46's**; T46's 25/25 ran. T46's claimed "25 tests, 0 failures" reproduces, and the
target total grew `1866 → 1891` (+25), consistent with this card being the only addition.

*Derived data is a fresh path; `SourcePackages` is the one existing package cache.* A from-scratch
SPM resolve on this host hangs in GRDB's `SQLiteLib` submodule (repo QA note), so the cache is reused
— the build products, module cache and test bundle are all new.

### 1.2 Live suite + host sampler, run 1 (all four live tests)

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<scripts/perf_seed.py> \
python3 scripts/t46_leak_probe.py --run-test --sim id=81A7F251-… --label t46av-leak-1 \
  --only-testing MattermostUITests/T46WebFallbackUITests
```

```
Test Case '…testAPluginScreenIsAddressableByID' passed (23.216 seconds)
Test Case '…testPlaybooksOpensAtItsOwnRoute' passed (16.356 seconds)
Test Case '…testTheSystemConsoleOpensSignedInAndReturnsToTheShell' passed (16.576 seconds)
Test Case '…testTwentyOpenCloseCyclesEachRender' passed (115.766 seconds)
Executed 4 tests, with 0 failures (0 unexpected) in 171.914 (171.923) seconds
```

`build/logs/t46av-leak-1.log` — 4 executed, **0 skipped, 0 failed**, `** TEST SUCCEEDED **`. The
claimed 4/4 reproduces. The states the suite printed (`build/logs/t46av-leak-1.log`):

```
playbooks  : loaded|installed|http://127.0.0.1:8065/playbooks/start|chars=1358|requested=…/playbooks
console #1 : loaded|installed|http://127.0.0.1:8065/admin_console/about/license|chars=2105|requested=…/admin_console
cycles 1–20: loaded|installed|http://127.0.0.1:8065/admin_console/about/license|chars=2147|requested=…/admin_console
```

The leak half of that run **failed**:

```
peak WC : 2 (limit 4)   final WC : 1 after 15s idle
RESULT: FAIL - 1 WebContent process(es) still alive at rest
```

`build/t46-leak/t46av-leak-1.json`.

### 1.3 Live suite + sampler, run 2 (the twenty-cycle test alone)

```
… python3 scripts/t46_leak_probe.py --run-test --sim id=81A7F251-… --label t46av-leak-2
```

```
baseline WC : 3 (excluded)   peak WC : 1 (limit 4)   final WC : 0 after 15s idle
WC timeline : 0 -> 1 -> 0 (min 0, max 1)
RESULT: PASS
```

`build/t46-leak/t46av-leak-2.json`, `build/logs/t46av-leak-2.log`. This is the implementer's number
(peak 1, final 0) and it reproduces — see F5 for why run 1 did not.

### 1.4 Two auditor probes (created, measured, deleted; tree clean afterwards)

**Probe A — is the `.shared` path real?** A unit test that writes the server's triple through one
`WebViewStore`, drops it, reads through a fresh store on the same `WKWebsiteDataStore(forIdentifier:)`,
then runs two consecutive `WebFallbackModel.installSession()`s:

```
PROBE writer store sees: ["MMCSRF", "MMAUTHTOKEN", "MMUSERID"]
PROBE a fresh store on the same id sees: ["MMCSRF", "MMAUTHTOKEN", "MMUSERID"]
PROBE presentation sources: first=installed second=shared
```

`build/logs/t46av-probe-cookie.log`, 1 test, 0 failures. So the data store **does** carry the cookies
across store objects, and in-process a second presentation **is** `.shared`.

**Probe B — does the Boards row render Boards?** A live test that signs in natively, taps
`webFallbackRow.boards` and watches the pane's own value for 75 s:

```
PROBE boards state: loaded|installed|http://127.0.0.1:8065/boards|chars=0|requested=http://127.0.0.1:8065/boards
PROBE boards state: loaded|installed|http://127.0.0.1:8065/boards|chars=61|requested=http://127.0.0.1:8065/boards
PROBE boards final: loaded|installed|http://127.0.0.1:8065/boards|chars=61|requested=http://127.0.0.1:8065/boards
```

`build/logs/t46av-probe-boards.log` (90 s, 1 test) and the attached screenshot, exported to
`docs/t46-av-shots/t46av-boards-blank.png`: a dark navy rectangle, the "Preview Mode" banner and
nothing else. No spinner, no error, no "this server has no Boards" message.

Why:

```
$ docker exec mm-perf ls /mattermost/plugins
com.mattermost.calls
com.mattermost.nps
playbooks
```

**Boards (focalboard) is not installed on the fixture.** `/boards` is answered by the web app shell,
the SPA has no boards bundle to mount, and the surface is a blank page — 61 characters, which is the
preview banner's own text.

### 1.5 Licence / secrets

* `grep -rnE "https?://[a-z0-9.-]+"` over the new files: only `127.0.0.1:8065` (fixture) and
  `example.com` / `evil.example` placeholders in tests. No real workspace host.
* `git show 91399de`: no token-shaped literal, no `Bearer`/`Token:` value, no credential. `AGPL`
  appears only in comments stating that nothing was copied.
* No upstream source in the diff: the new files are this repo's own Swift; the landing-page flag and
  the cookie triple are named as *measured behaviour* of the server, not ported code.
  `docs/THIRD_PARTY_NOTICES.md` already cites `mattermost/mattermost` (Apache-2.0, pin `987e5712`) and
  `mattermost/mattermost-mobile` (Apache-2.0, `162f2560`) — nothing new to add for a route list.
* **No licence violation found.**

---

## 2. Criteria, with the evidence each rests on

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1a | System Console opens from native chrome, signed in, at its own surface | **PASS** | live test 3 (§1.2), `chars=2105` at `/admin_console/about/license`, `|installed|`, no `/login`; screenshot shows Edition and License, @perfprobe |
| 1b | Playbooks opens at its own route | **PASS** | live test 2, `chars=1358` at `/playbooks/start`; screenshot shows the Playbooks sidebar and "Get started with Playbooks" |
| 1c | **Boards** opens a working Boards surface | **FAIL** | Probe B (§1.4): `chars=61`, blank page, 75 s; no test in T46 opens the row; Boards not installed on the fixture |
| 1d | **plugin screens** open that plugin's surface | **FAIL (as written)** | `curl -s -o /dev/null -w '%{http_code} → %{redirect_url}' http://127.0.0.1:8065/plugins/com.mattermost.calls` = `301 → http://127.0.0.1:8065/`; `docs/t46-shots/t46-plugin-screen.png` is the workspace at Town Square. Documented (§7.4, §13.6) but it is not "exactly that surface" |
| 1e | back navigation returns to the native stack | **PASS (close only)** | live tests assert `nativeShell` after `webFallbackClose` and `webFallbackPane` gone; the in-sheet `webFallbackBack` button is never exercised (see §4) |
| 2 | the fallback shares the server's session (no second login) | **PASS** | every live state is `|installed|` from a **native** sign-in, no `/login` bounce, 20 consecutive reopenings each render signed in; `testClosingTheFallbackDoesNotLogTheServerOut` |
| 3 | torn down and recreated without leaking a webview | **PASS** | run 2 (§1.3) peak 1 over 20 cycles, final 0; run 1's final 1 explained in F5; object-level 20/20 weak handles in the unit suite |
| 4 | `docs/dual-render.md` says which surfaces are permanently web and why | **PASS, one wrong sentence** | §13.1–§13.5 are complete and match the code; §13.6's Boards sentence is false (F3) |

---

## 3. Findings (each with its reproduction)

### F1 — the Boards row renders nothing, and nothing says so (criterion 1c) — FAIL

`webFallbackRow.boards` is offered on every server, unconditionally, with no capability check. On a
server without the Boards plugin it opens a blank page.

```
# from the probe in §1.4, re-created then deleted
python3 scripts/qa-test.py --platform ios --sim id=81A7F251-… \
  --only-testing MattermostUITests/T46AVBoardsProbeUITests
→ PROBE boards final: loaded|installed|http://127.0.0.1:8065/boards|chars=61|requested=http://127.0.0.1:8065/boards
```

Reader sees `docs/t46-av-shots/t46av-boards-blank.png`. Suggested repair (not done here): ask the
server (`GET /api/v4/plugins/webapp` — T46 already reaches for it in the sidebar's "Browse plugins…"
copy but does not use it) and render the sheet's existing `webFallbackUnavailable` state when Boards
is not installed, or say "Boards is not enabled on this server".

### F2 — the plugin row is a request, not the plugin's screen (criterion 1d) — FAIL as written

```
$ curl -s -o /dev/null -w '%{http_code} → %{redirect_url}\n' http://127.0.0.1:8065/plugins/com.mattermost.calls
301 → http://127.0.0.1:8065/
```

The live test asserts `requested=/plugins/com.mattermost.calls` **and** a painted page; both are true
and neither is the plugin. If the criterion is to be met, the row has to reach the plugin's
client-side route (`/plug/<id>/…` inside the SPA) or the card has to say the plugin surface is not
reachable and drop the row to an id prompt that explains it. The card's own §7.4 text is honest; the
acceptance criterion is not met.

### F3 — the docs claim a Boards assertion that does not exist

`docs/dual-render.md` §13.6: "Boards, Playbooks and the System Console are real server routes and are
asserted on the committed URL." No test opens the Boards row, so that sentence is false for Boards
(it is true for Playbooks and the console).

```
$ grep -rn "webFallbackRow.boards" MattermostUITests        # no output
$ grep -rl "webFallbackRow.boards" build/logs/               # no output — never opened in any run
```

Had such a test existed it would have failed: my Boards probe's own 120-character threshold (T46's
`paintedSurfaceThreshold`) is not reached (`chars=61`).

### F4 — the `.shared` session path is never exercised in the app (mechanism, not behaviour)

22 of 22 observable states in the live run reported `|installed|`, including all twenty cycles
(`grep -o "|\(installed\|shared\|none\)|" build/logs/t46av-leak-1.log | sort | uniq -c` → `22 installed`).
My probe A shows a fresh store *does* see the triple and a second presentation *does* report
`.shared` in-process, so the difference is introduced by the live page/between presentations — not
identified here.

Consequence: `docs/dual-render.md` §13.4 ("the server's data store and its cookies outlive the
presentation, so reopening a surface is not a new login") is true in effect (the token is re-installed
every time, still no second login) but not in the mechanism claimed. The rule that matters — "a web
sign-in outranks the vault; never overwrite it" — is unit-tested and **never** exercised against a
real webview sign-in. The end state is fine; the claim is stronger than the evidence.

```
# both directions, one run
python3 scripts/qa-test.py --platform mac --label t46av-probe-cookie \
  --only-testing MattermostTests/T46AVProbeTests
```

### F5 — the leak probe's `final == 0` is host-state dependent; its peak is the load-bearing number

Run 1 failed the verdict rule with one lingering `WebContent` (pid 90703, started mid-run at 23:58:34):
it was **still alive 12 minutes later**, 7 MB RSS, no client app process on the host, `PPID 1`. Run 2,
started with that pid in the baseline, passed (peak 1, final 0). So the run-1 FAIL is a WebKit XPC
process outliving its app, not a retained `WKWebView` — but the probe cannot tell the two apart: its
"at rest" sample is taken **after XCTest has terminated the app**, when a leak and an app exit are
indistinguishable.

Reproduction: the two commands in §1.2 and §1.3, back to back, on this host.
Repair (not done here): sample once more *while the suite is still running and idle* (e.g. a
`--settle-inside` mode driving a final wait in the test), or attribute only `WebContent` pids whose
`responsible` app is the test host (`ps -o responsible_pid`).

The implementer's claimed numbers (peak 1, final 0) **do** reproduce on run 2; the run-1 failure is a
finding about the instrument, not proof of a leaked webview.

### F6 — the sidebar entry point is not in T46's commit (traceability, no functional effect)

`91399de` does not touch `Mattermost/UI/Native/Sidebar/ChannelSidebarView.swift`:
`git log -S"webFallbackRow" -- ChannelSidebarView.swift` → `37b6642` (T45-AV-R's accessibility commit
swept the untracked section up). The code is on `origin/main` and works; the card's commit does not
contain its own UI entry, so a reader auditing `91399de` alone cannot see how the sheet is reached.

---

## 4. Negative space (what the card silently does not cover)

| Gap | Why it matters | Status |
|---|---|---|
| the in-sheet **Back** button (`webFallbackBack`) | the only navigation control inside a surface; `canGoBack` is mirrored but no test taps it | untested, documented nowhere |
| **non-admin** reader + System Console | the row is offered to everyone; a member gets the console's own refusal inside the sheet | stated in `docs/parity.md`, no measurement |
| **dark mode / Dynamic Type / VoiceOver** for the sheet | the shell went through T45; the fallback sheet is new UI and skipped that pass | untested |
| a **webview-established** session (SSO) + fallback | F4: `.shared` never happens in the app | untested live |
| Boards without the plugin, plugin ids that 404 | F1 — no capability check, no empty state | untested |
| **server-side session survival** after 20 cycles | the suite proves the page renders signed in; it never asks the server whether the session is still valid for the *native* transport afterwards | untested (inferred from cycles 2–20 rendering) |
| Calls surface (T44d) | parity says the Calls surface is reached "from the channel header instead" — not this card's rows | out of scope, stated |

---

## 5. Host state I changed

* Created and deleted `MattermostTests/T46AVProbeTests.swift` and
  `MattermostUITests/T46AVBoardsProbeUITests.swift` (probes in §1.4); `git status` is clean apart from
  this document.
* Fixture `mm-perf` untouched; the `perfprobe` password came from `scripts/perf_seed.py`.
* A pre-existing Catalyst `Mattermost` app (1h41m old at run time) and two idle `WebKit.WebContent`
  XPC processes were running on the host; the sampler excludes what exists before launch, and F5 is
  where that matters.

## 6. What this host cannot validate

* **No server with Boards installed** → criterion 1c cannot be shown to work anywhere from here; the
  repair needs a fixture with focalboard or an explicit "not enabled" state.
* **A real plugin route** → `/plugins/<id>` on 9.11.19 always 301s to `/`; whether any deployment
  serves a page there is unknown.
* No APNs, no second server, no non-admin account on the fixture.
