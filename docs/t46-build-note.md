# T46 — the permanent webview escape hatch (card `t_a7a9f2ff`)

What the card asked for (`## Acceptance criteria`), and where each half is answered here:

| # | Criterion | Where |
|---|---|---|
| 1 | from native chrome, open a plugin / Boards / Playbooks / System Console surface and get a working webview of **exactly** that surface, with back navigation returning to the native stack | §2, §3, §7 |
| 2 | the fallback shares the server's session (**no second login**) | §4, §5 — the measurement this card turned on |
| 3 | the fallback can be torn down and recreated without leaking a webview | §6 |
| 4 | `docs/dual-render.md` says which surfaces are permanently web and why | `docs/dual-render.md` §13 |

Server under test: the fixture `mm-perf` (`mattermost/mattermost-team-edition:release-9`, 9.11.19) on
`http://127.0.0.1:8065`, plus the Playbooks/Boards/Calls plugins it ships. Builds: Catalyst
(`--platform mac`) for the unit suites, iPhone 16 Pro simulator for the live suites. Apple silicon,
Xcode 26.

---

## 1. Files

New (`Mattermost/UI/Native/Web/`, auto-included by the project's
`PBXFileSystemSynchronizedRootGroup`):

| File | What it is |
|---|---|
| `WebFallbackSurface.swift` | the catalogue: six permanently-web surfaces (`systemConsole`, `boards`, `playbooks`, `pluginScreens` + the generic `plugin(id:)` route, `calls`, `docs`), each with its route, its `Surface` case for `SurfaceMode`, and its sidebar title |
| `WebFallbackModel.swift` | one presentation: the store, the session handoff, the landing-page flag, the URL publisher, `tearDown()` |
| `WebFallbackView.swift` | the sheet's content: `WKWebView` host, load state, failure state with retry, toolbar (Back, Reload, Safari) |
| `WebAppLandingPage.swift` | the web app's first-visit landing page: its route, its `__landingPageSeen__` flag, the preload script, and the same-server fragment resolver |

Modified: `Mattermost/Core/MM/WebSessionAdoption.swift` (adds
`WebSessionCookiePolicy.sessionCookies(for:token:userID:csrf:now:)`), `Mattermost/UI/WebViewContainer.swift`
(the sheet's host hook), `Mattermost/UI/Native/Sidebar/ChannelSidebarView.swift` (the **Web view**
section that opens the sheet).

Tests: `MattermostTests/T46WebFallbackTests.swift` (unit), `MattermostUITests/T46WebFallbackUITests.swift`
(live, skipped unless `TEST_RUNNER_MM_AUTH_*` is set), `scripts/t46_leak_probe.py` (criterion 3).

---

## 2. Reaching a surface from native chrome

`ChannelSidebarView` draws a **Web view** section under the channel list — one row per catalogue
entry (`webFallbackRow.systemConsole`, `…boards`, `…playbooks`, `…calls`, `…plugin.<id>`) plus a
`Browse plugins…` sheet that lists what `GET /plugins/webapp` actually ships. A row presents
`WebFallbackView` as a sheet; the sheet's Close toolbar button dismisses it and the native stack is
exactly where it was (the live test asserts `nativeShell` exists again and `webFallbackPane` does
not). The pane is the surface itself, addressed by route — not the web app's channel view.

## 3. The landing page (a navigation bug, not a session bug)

A fresh per-server `WKWebsiteDataStore` has the web app's `hasSeenLandingPage` false, so the first
load of `/admin_console` renders the desktop **landing page** ("Where would you like to view this?")
*while the committed URL still contains `/admin_console`* — which is how an earlier UI test passed
while no console was on screen. Two independent levers, both kept:

1. **Seed the flag before the first request.** `WebAppLandingPage.preloadScript` writes
   `localStorage.__landingPageSeen__ = 'true'` at `atDocumentStart`, so the SPA's own
   `showLandingPageIfNecessary` never fires. The flag is a browser-side preference, not a credential.
2. **Skip it if it appears anyway** (`surfaceTarget(in:on:)`): if the store's storage is disabled and
   the SPA pushes `/landing#/admin_console`, the model follows the fragment — but only when it is the
   **configured server's** origin and inside its install path. The first implementation compared the
   landing page with *itself*, so `https://evil.example/landing#/admin_console` was followed;
   `T46WebFallbackTests.testAnythingThatIsNotASameServerSurfaceIsNotFollowed` fails against that rule.

## 4. Sharing the session — what "no second login" actually takes

### 4.1 The first design, and how it failed

`MMAUTHTOKEN` alone, written into the server's own `WKWebsiteDataStore`, before the first load. The
cookie did arrive — an echo server on `:8099` showed the exact header bytes, and a webview document
load of `/api/v4/users/me` authenticated with it. And still, the live console test landed on
`/login?redirect_to=%2Fadmin_console` in **2 of 4 runs** (and, in the end, in every run of the
twenty-cycle test).

### 4.2 Named cause (measured)

Instrumenting the page's own `fetch`/`XMLHttpRequest` calls, then the server's request log, gave the
whole sequence for one boot of `/admin_console` on a store holding only `MMAUTHTOKEN`:

| # | request | status |
|---|---|---|
| 1 | `GET /api/v4/config/client` · `/license/client` · `/plugins/webapp` | 200 |
| 2 | `GET /plugins/playbooks/api/v0/settings` | **200** — the session *is* valid |
| 3 | `POST /api/v4/users/logout` | **200** — the page signs itself out |
| 4 | `GET /api/v4/teams?page=0&per_page=200` | 401 → `/login?redirect_to=…` |

and in the server log at that instant:

```
level=debug msg="CSRF Header check failed for request - Please upgrade your web application or
custom app to set a CSRF Header" caller=web/handlers.go
level=debug msg="Received HTTP request" method=POST url=/api/v4/users/logout status_code=200
```

The web app's boot issues state-changing requests of its own (`PUT /api/v4/users/me/patch`,
`POST /api/v4/users/logout`); without a CSRF cookie it cannot sign them, and a session it cannot use
is a session it clears — and that logout deletes the session on the server, so the token the app
holds is dead for the native transport too.

### 4.3 What the server itself sets

A browser-shaped `POST /api/v4/users/login` answers with **three** cookies (measured, verbatim):

```
Set-Cookie: MMAUTHTOKEN=<token>; Path=/; Expires=+30d; Max-Age=2592000; HttpOnly
Set-Cookie: MMUSERID=<user id>; Path=/; Expires=+30d; Max-Age=2592000
Set-Cookie: MMCSRF=<26 chars>;  Path=/; Expires=+30d; Max-Age=2592000
```

`MMUSERID` is the identity the client reads to decide it is signed in; `MMCSRF` is the
double-submit token the client echoes in `X-CSRF-Token` (the server compares header to cookie, so the
value is not a server-held secret). The shell now installs the same triple, in the same scope:
`WebSessionCookiePolicy.sessionCookies(for:token:userID:csrf:now:)` — host-scoped, `path=/` (a
sub-path install is covered), `HttpOnly` on the token only, `secure` only for an `https` server, the
server's 30-day lifetime, and a fresh 26-character `[a-z0-9]` CSRF value per handoff.

### 4.4 Re-measured after the fix

Same spike, now through `WebFallbackModel.start()` (production path, no test-only cookie writes):

```
SPIKE t=0s  url=http://127.0.0.1:8065/admin_console               cookies=[MMAUTHTOKEN,MMCSRF,MMUSERID,…]
SPIKE t=2s  url=http://127.0.0.1:8065/admin_console/about/license  cookies=[…all three still present…]
SPIKE t=18s url=http://127.0.0.1:8065/admin_console/about/license  cookies=[…]
SPIKE source=installed
```

The console's own redirect (`/admin_console/about/license`) is the console running; no `/login`
bounce, and the session is still alive 18 s in. §7 is the live suite on the same path.

`MMUSERID` is read from `SecureVault(.userID)` — the entry the native sign-in writes — so a store
with a token but no user id installs **nothing** (`T46WebFallbackTests.testATokenWithNoUserIDIsNotHandedOver`):
half a handoff is exactly the state §4.2 documents.

---

## 5. What is measured, and what is not

Measured here: the cookie triple's names/scope/flags, the logout-and-401 boot sequence, the
post-fix boot, the four live acceptance runs (§7), the process behaviour of twenty cycles (§6).

**Not** measured, stated rather than implied:

- The web app's *exact* reason for calling `logout` on boot is inferred from its requests, not from
  its source — `mattermost-webapp` is AGPL-3.0 and this card only observes network behaviour (§4.2's
  log is the evidence). What the client does is measured; why its code chose to do it is not read.
- The triples are installed for a **native** sign-in (`SecureVault`). A session established *inside*
  the webview (SSO sheet) is the web's own and is left untouched — `hasUsableSession` requires all
  three cookies, so a webview sign-in is never overwritten by a stale native token.
- The System Console needs a server **admin** (`system_admin` or `system_user_manager`); nothing
  here changes what the console itself will show to a non-admin.
- The live suites need a real server and are skipped without `TEST_RUNNER_MM_AUTH_*`.

---

## 6. Teardown, recreate, and the memory claim

A presentation owns one `WebFallbackModel`, which owns one `WebViewStore` (one `WKWebView`). Closing
the sheet calls `tearDown()`: `stopLoading()`, nil the delegate, `loadHTMLString("")` is **not** used —
the store is dropped so the `WKWebView` deallocates, which is the same destroy-not-park rule as
`docs/dual-render.md` §12.2. The session cookies are **not** cleared (they belong to the server's
data store, not to the webview) — `testClosingTheFallbackDoesNotLogTheServerOut` pins that.

Object level: `testTwentyFallbacksLeaveNoWebViewAlive` — twenty created-and-torn-down models leave
twenty deallocated `WKWebView`s (weak handles).

Process level: `scripts/t46_leak_probe.py --run-test` runs the live twenty-cycle test and samples the
app's WebKit children (`ps`), attributing only pids that appeared after launch. Verdict rule: the
suite green, peak attributed `WebContent` processes ≤ `--max-peak` (4; WebKit pools processes, so the
neighbouring presentation's exit can overlap), and **0** after settling — a leaked webview keeps one
alive, which is where Path A's hundreds of megabytes came from.

---

## 7. Live runs

Everything below is this card's final re-run on 2026-11-02 (after the two earlier runs were reclaimed
and then ran out of iteration budget — the tree they left is what these runs measured). Server:
`mm-perf` (`mattermost/mattermost-team-edition:release-9`, 9.11.19) on `http://127.0.0.1:8065`,
account `perfprobe` (`system_admin system_user`), simulator iPhone 16 Pro `81A7F251`.

### 7.1 Unit suite — Mac Catalyst

```
python3 scripts/qa-test.py --platform mac --label t46-units-9 \
  --only-testing MattermostTests/T46WebFallbackTests
```

`build/logs/t46-units-9.log`: **25 tests, 0 skipped, 0 failed**, `** TEST SUCCEEDED **`. The two added
in this run are §7.3's formatter and the paint-probe boundary (`|chars=` present/absent/zero, and the
script must not touch `cookie`, `localStorage`, `fetch`, `eval` or the message handlers).

### 7.2 Live suite — iOS simulator

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
python3 scripts/t46_leak_probe.py --run-test --sim id=81A7F251-8B31-4945-8783-5A264C14B8D5 \
  --label t46-leak-r4 --only-testing MattermostUITests/T46WebFallbackUITests
```

`build/logs/t46-leak-r4.log`: **4 tests, 0 skipped, 0 failed** (196 s), `RESULT: PASS`. The suite is
the card's three criteria: the console opens from native chrome **with the native sign-in's session**
and closing it puts the native shell back (`webFallbackPane` gone, `nativeShell` present); Playbooks
opens at `/playbooks`; a plugin id opens `/plugins/<id>`; twenty open/close cycles each render.

Two earlier runs of the same suite on the same tree are what §7.3 and §7.4 are made of:
`t46-leak-r2` failed the plugin test on a **URL race** (`loading|…|http://127.0.0.1:8065/`, read
before the first navigation committed) and `t46-leak-r3` failed it on the **redirect** (measured, §7.4).

### 7.3 `loaded` is not `rendered`: the paint probe (found in this run)

The first live suite of this re-run passed every assertion while its console screenshot was a white
rectangle: `pageLoadState == .loaded` fires on the web app's **HTML shell** (3 471 bytes, `<title>
Mattermost</title>`), and the System Console's bundle routes to `/admin_console/about/license` and
paints roughly a second later. A URL-only assertion therefore certifies a blank page — the same class
of failure §3 documents for the landing page, one layer down.

The fix is a page-level reading, not a longer sleep. `WebFallbackModel` now evaluates one read-only
expression against its own page after `didFinish` (`document.body ? document.body.innerText.trim().length : 0`,
0.5 s apart, up to 20 times, stopping at ≥ 120 characters) and publishes the maximum as
`paintedCharacters`; `observableState` carries it as `|chars=N`. Measured on the fixture, console:

```
T46 webFallbackRow.systemConsole state: loaded|installed|http://127.0.0.1:8065/admin_console/about/license|chars=2105|requested=http://127.0.0.1:8065/admin_console
```

(`build/logs/t46-console-r9.log`.) The console's painted body is 2 105 characters; the screenshot in
§7.6 is taken after that assertion, so it is a picture of that state. Before the probe existed, the
same assertion attached a white rectangle (`t46-shots` as run 319 left it, replaced by this run's).

The live test now waits for `loaded` **and** `chars ≥ 120` before it attaches anything, so an empty
webview fails the suite instead of producing a plausible-looking artifact.

### 7.4 What `/plugins/<id>` actually answers on this server (measured)

The plugin row addresses `/plugins/<id>` exactly, and the server's answer is not a page there:

| Route | Status | `Location` |
|---|---|---|
| `/plugins/com.mattermost.calls` | 301 | `/` |
| `/plugins/playbooks` | 301 | `/` |
| `/plugins/focalboard` | 404 | — |
| `/plugins/com.mattermost.apps` | 404 | — |

A plugin's webapp is a **client-side** route inside the web app (the installed bundles are
`/static/playbooks/playbooks_…_bundle.js` etc. per `GET /api/v4/plugins/webapp`), not a server page,
so the plugin root can only 301 into the app. The live test therefore asserts both facts the shell
can be held to — the pane's `requested=` route is exactly
`http://127.0.0.1:8065/plugins/com.mattermost.calls`, and the page that comes back is painted
(`chars ≥ 120`, signed in) — and `docs/t46-shots/t46-plugin-route-request.png` (renamed from
`t46-plugin-screen.png` by T46-R) is that state: the web app at Town Square. It is evidence for "the
route request rendered the web app", **not** for "this plugin's screen" — the row and the sheet are
therefore labelled "Plugin route…" (T46-R R2, `docs/t46-av-verdict.md` §F2).

The last sentence of this section in T46 read "Boards, Playbooks and the System Console are real
server routes and are asserted on the **committed** URL." That was true for Playbooks and the console
and false for Boards: no test opened the Boards row (T46-AV §F3), and on this fixture — which ships no
focalboard plugin — it painted 61 characters and nothing else (§F1). T46-R added
`testBoardsIsEitherPaintedOrSaysItIsNotEnabled`; see §9.

### 7.5 Teardown and the memory claim — process level

Same run, external sampler (`scripts/t46_leak_probe.py`, the `ps`-based half):

```
baseline WC    : 1 WebKit WebContent process(es) before launch (excluded)
peak WC        : 1 (limit 4)
final WC       : 0 after 15s idle
peak WC RSS    : 530.5 MB (sum of this run's WebContent processes)
app RSS        : 63.5 MB (last sample)
WC timeline    : 0 -> 1 -> 0 (min 0, max 1)
RESULT: PASS
```

One presentation at a time, and nothing alive fifteen seconds after the suite ends — twenty
create/open/close cycles do not accumulate a `WebContent` process, which is the failure mode that
would defeat the memory goal. Report: `build/t46-leak/t46-leak-r4.json`.

### 7.6 Screenshots (exported from the run's own `xcresult`)

`python3 scripts/t37_export_shots.py <…>/t46-leak-r4-…xcresult docs/t46-shots`

| File | What it is |
|---|---|
| `t46-system-console-native-session.png` | the System Console signed in as **@perfprobe**, at Edition and License — the card's first criterion, on the native session |
| `t46-cycle-20-console.png` | the **twentieth** open/close cycle, same surface (byte-identical to the shot above: the screen is deterministic, which is itself the claim — cycle 20 renders exactly like cycle 1) |
| `t46-playbooks.png` | Playbooks at `/playbooks`, team `Perf`, RUNS/PLAYBOOKS lists |
| `t46-plugin-route-request.png` | `/plugins/com.mattermost.calls` requested → the server's 301 → the web app renders (Town Square). Renamed from `t46-plugin-screen.png` by T46-R: it is evidence for the route request, not for a plugin screen. |

---

## 8. Test map

| Suite | What it holds |
|---|---|
| `MattermostTests/T46WebFallbackTests.swift` | the surface catalogue (routes, plugin ids, sub-path installs, no traversal), the session-cookie policy (scope/flags/lifetime/triple/CSRF shape), the sharing rules (`.shared`/`.installed`/`.none`, token-only store is repaired, token-without-user-id is refused, a web session is never overwritten), teardown (idempotent, cookies survive, twenty webviews deallocate), and — T46-R — the capability gate (product plugin ids, not-enabled vs unanswerable, the console/plugin routes never gated, the endpoint's decode/5xx/garbage/sub-path/auth header) |
| `MattermostUITests/T46WebFallbackUITests.swift` | live: the console opens from native chrome with the native session and returns to the shell; Playbooks opens at its own route; **Boards paints `/boards` or says it is not enabled — never a blank page**; a plugin **route** opens at `/plugins/<id>` and is labelled as a route; twenty open/close cycles each render, each signed in, followed by a 20 s app-alive at-rest window; closing returns to the native stack |
| `scripts/t46_leak_probe.py` | process-level leak verdict for the twenty cycles: peak, and the at-rest count sampled inside the suite's `T46_AT_REST_BEGIN`/`END` window while the app is alive |

---

## 9. T46-R — the repair run (card `t_aa65ed88`)

T46-AV (`docs/t46-av-verdict.md`) returned **FAIL** on criterion 1 and filed five findings. This
section is the repair's measurements. Nothing above is deleted: the T46 numbers stand, and where a
claim was too strong it is corrected in place (§7.4) and here.

Run commands (all on this host, fixture `mm-perf` 9.11.19 at `http://127.0.0.1:8065`, iPhone 16 Pro
`81A7F251-…`):

```
python3 scripts/qa-test.py --platform mac \
  --derived-data ~/Library/Developer/Xcode/DerivedData/t46r-qa --label t46r-units-final3 \
  --only-testing MattermostTests -- \
  -clonedSourcePackagesDirPath ~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa/SourcePackages

TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<scripts/perf_seed.py> \
python3 scripts/t46_leak_probe.py --run-test --sim id=81A7F251-… \
  --label t46r-live-6 --only-testing MattermostUITests/T46WebFallbackUITests
```

```
units : Executed 1900 tests, with 9 tests skipped and 0 failures   ** TEST SUCCEEDED **
        (build/logs/t46r-units-final3.log; 1891 → 1900, the nine new tests are this card's)
live  : Executed 5 tests, with 0 failures (0 unexpected) in 228 s   ** TEST SUCCEEDED **
        (build/logs/t46r-live-6.log)
leak  : peak 1, at rest 0 while the app was alive (41 samples over 20 s), final 0
        RESULT: PASS   (build/t46-leak/t46r-live-6.json)
```

### 9.1 R1 — Boards painted a blank page (the FAIL)

**Before** (T46-AV §F1, not re-run here as the card instructed): a natively signed-in app, the
Boards row tapped, 75 s — `loaded|installed|http://127.0.0.1:8065/boards|chars=61`. The fixture ships
no focalboard plugin:

```
$ docker exec mm-perf ls /mattermost/plugins
com.mattermost.calls
com.mattermost.nps
playbooks
$ curl -s http://127.0.0.1:8065/api/v4/plugins/webapp   # ids: playbooks, com.mattermost.nps, com.mattermost.calls
```

**Repair: the capability check** (the first of the card's two options). `WebFallbackSurface` names the
product plugin a surface needs (`boards` → `focalboard`, `playbooks` → `playbooks`); `WebFallbackModel`
asks `GET /api/v4/plugins/webapp` **before the first navigation** and, when the answer excludes the
plugin, sets `availability = .notEnabled(id)` and returns without loading anything — no navigation, no
page, a sentence instead:

```
T46 boards outcome: notEnabled — Boards is not enabled on this server.
Test Case '…testBoardsIsEitherPaintedOrSaysItIsNotEnabled' passed (12.688 seconds)
```

The same test accepts the other half of the contract on a server that *does* serve focalboard
(`chars ≥ 120` at a `/boards…` URL); the fixture cannot show that, so it is unit-tested with an
injected listing instead, and `docs/dual-render.md` §13.7 states the gap.

An **unanswered** probe is not "not enabled": the surface opens and the page answers (a refusal on a
failed probe would break servers that work today). Pinned by
`testAnUnansweredPluginListingStillOpensTheSurface`.

### 9.2 R2 — the plugin row is a request, not a screen

Measured again on this fixture: `/plugins/com.mattermost.calls` → `301 → /`; `/plug/com.mattermost.calls`
answers `200` but no installed plugin on this server registers a client route there, so the row cannot
promise a plugin UI. The repair takes the card's second option — **say what it shows**: the row is
"Plugin route…", the sheet is "Plugin route: <id>", the id prompt's footer says the path may answer
with the workspace, and `t46-plugin-screen.png` is renamed `t46-plugin-route-request.png` (it is
evidence for the route request). The live test now asserts the sheet's own title and the measured
state:

```
T46 plugin route state: loaded|installed|http://127.0.0.1:8065/ops/channels/town-square|chars=1567|requested=http://127.0.0.1:8065/plugins/com.mattermost.calls
```

### 9.3 R3 — the docs claimed a Boards assertion that did not exist

Fixed where the claim was made: `docs/dual-render.md` §13.6 no longer says Boards "is asserted on the
committed URL alone"; it says the row is asserted as *painted or explicitly not enabled*, and §7.4 of
this note records what the old sentence got wrong. The sentence is true now because
`testBoardsIsEitherPaintedOrSaysItIsNotEnabled` exists (it is `grep`-able, and it ran — §9.1).

### 9.4 R4 — `.shared` was never exercised in the app

The observable state now carries the cookie **names** the store held at the decision point
(`|cookies=`, never a value), printed per presentation. Three runs of the same suite:

```
run A (build/logs/t46r-live-1.log): installed ×4, shared ×16   — the jar read empty 4 times, then complete
run B (build/logs/t46r-live-3.log): installed ×20, shared ×0   — the jar never became readable
run C (build/logs/t46r-live-6.log): installed ×20, shared ×0   — same, on the final code
```

A third probe (one presentation, 70 s idle, a second presentation; `build/logs/t46r-probe-gap.log`)
also read an empty jar → `installed`. So: **the store's cookie jar can carry the session forward, but a
later presentation cannot rely on reading it, and a wait does not fix it.** The load-bearing guarantee
is the re-install of the same triple from `SecureVault` — still no second login — and the live suite
now asserts exactly that for all twenty presentations (`.installed`/`.shared`, never `.none`, never
`/login`). `docs/dual-render.md` §13.3 and §13.4 are weakened to this measurement; the residual risk
(an empty read is indistinguishable from an empty store, so a webview-established session could be
overwritten) is stated in §13.7 rather than left silent.

### 9.5 R5 — the leak probe could not tell a leak from an app exit

The "at rest" sample now happens **while the app is alive**: the end of
`testTwentyOpenCloseCyclesEachRender` prints `T46_AT_REST_BEGIN`, holds the native shell on screen for
20 s with nothing presented, and prints `T46_AT_REST_END`. The probe tails the suite's log while it
runs (measured: the runner does not echo `xcodebuild`, so the first version of the tailer saw nothing),
samples inside that window, and reports:

```
[t46] suite printed T46_AT_REST_BEGIN - at-rest sampling starts now (the app is alive and idle)
at rest WC     : 0 while the app was alive and idle (41 samples)
peak WC        : 1 (limit 4)
final WC       : 0 after 15s idle
RESULT: PASS
```

The post-exit count is still reported, and it now has a job: **a pid that outlives the app is excluded
from the at-rest count** as an orphan, because the app's death tears its webviews down — a process that
survives it was never held by a webview the app retained. This is T46-AV §F5's run-1 failure mode (one
`WebContent` pid alive twelve minutes later with no client app). Measured both ways:
`build/t46-leak/t46r-live-5.json` — taken before the rule existed — shows pid 18048 alive through all
38 at-rest samples *and* still alive 15 s after the app exited (it was still there, in the next run's
baseline, minutes later): under this rule it is an orphan, not a retained webview.
`build/t46-leak/t46r-live-6.json` is the clean run above, with no orphan at all.

Two attribution bugs were found and fixed in the probe while doing this:

* **The app under test is not "the first `Mattermost` process".** This host carried a 1 h 41 m old
  Catalyst `Mattermost` app during T46-AV, and it is still running (pid 47416): `app_pid()` returned it
  while the simulator's app was starting, so "is the app alive" was answering about the wrong process.
  The probe now snapshots the app pids at start and only counts pids that appeared **after** it
  (`baseline_app_pids`).
* **The suite's markers are in the log, not on the pipe.** `scripts/qa-test.py` redirects `xcodebuild`
  into `build/logs/<label>.log`; the first tailer read only the subprocess pipe and reported "no
  `T46_AT_REST_BEGIN` window" for a run whose log contained it. The reader now tails both.

### 9.6 Host state this repair changed

* Fixture `mm-perf` **untouched**: focalboard is *not* installed, because the card's first option
  (the capability check) is the one taken and the not-enabled path is what this host can prove.
* Two temporary probes created, run and deleted: `MattermostTests/T46RProbeTests.swift` (does a cookie
  survive a `WKWebsiteDataStore` handle's death? — measured: yes in-process, which is why the empty
  jar above is not that) and `MattermostUITests/T46RSessionProbeUITests.swift` (the 70 s gap probe).
* `git mv docs/t46-shots/t46-plugin-screen.png docs/t46-shots/t46-plugin-route-request.png`.
* No secrets, no real workspace host: the only hosts in the new files are `127.0.0.1:8065` and
  `mm.example.com` placeholders.
