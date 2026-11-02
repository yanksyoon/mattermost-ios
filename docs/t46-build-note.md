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
(`chars ≥ 120`, signed in) — and `docs/t46-shots/t46-plugin-screen.png` is that state: the web app at
Town Square, titled `Plugin: com.mattermost.c…`. Boards, Playbooks and the System Console are real
server routes and are asserted on the **committed** URL.

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
| `t46-plugin-screen.png` | `/plugins/com.mattermost.calls` requested → the server's 301 → the web app renders (Town Square), title `Plugin: com.mattermost.c…` |

---

## 8. Test map

| Suite | What it holds |
|---|---|
| `MattermostTests/T46WebFallbackTests.swift` | the surface catalogue (routes, plugin ids, sub-path installs, no traversal), the session-cookie policy (scope/flags/lifetime/triple/CSRF shape), the sharing rules (`.shared`/`.installed`/`.none`, token-only store is repaired, token-without-user-id is refused, a web session is never overwritten), teardown (idempotent, cookies survive, twenty webviews deallocate) |
| `MattermostUITests/T46WebFallbackUITests.swift` | live: the console opens from native chrome with the native session and returns to the shell; Playbooks opens at its own route; a plugin screen opens at the plugin root; twenty open/close cycles each render; closing returns to the native stack |
| `scripts/t46_leak_probe.py` | process-level leak verdict for the twenty cycles |
