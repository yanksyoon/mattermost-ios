# t_4528b67e — T31 harvest: a webview-cookie launch rendered `nativeAuthSurface`

Date: 2026-11-04. Host: this Mac, iPhone 16 Pro `t941e3d3`
(`9C883EB3-B410-4859-A443-A38A910F3396`), iOS 18.3.1, fixture server Mattermost 9.11.19 at
`http://127.0.0.1:8065`, account `perfprobe`. Base: `origin/main` **0236b9c**.

## §0 Result

`MattermostUITests/T31WebSessionHarvestUITests`: **2 run / 0 skipped / 0 failed, 17.097 s**
(`docs/t4528b67e-t31-live-2026-11-04.log`). It was 2 run / 1 failed, 72–80 s, on four separate runs
across two trees before this card.

Two **independent** defects were in that one red line, and neither was the harvest:

1. the fixture never had a session at all — the seeded `MMAUTHTOKEN` was **silently dropped** by
   WebKit, so the launch resolved signed out and the native sign-in surface appeared exactly as
   designed (§2). Fixed in the product write path (`WebSessionCookieInstaller`, §3) and in the launch
   seam (§4);
2. once a session did exist, the test's *landing* and *grouping* assumptions were false for this tree
   and this fixture — the launch policy of `t_295b0a32` pushes a channel pane over the list (so
   `nativeShell` is never in the tree), and `perfprobe` has custom channel sections (so
   `channelSidebar.category.channels` is never drawn) (§5). Both assertions were **replaced by
   stronger ones**, none were skipped or deleted.

## §1 What the red line was, before any change

Same failure on four runs, two trees, two accounts of it already in the parent card
(`t_c941e3d3`): `T31WebSessionHarvestUITests.swift:84` — "a webview-signed-in launch must render the
native workspace" — with the accessibility dump showing `nativeAuthSurface`
(`authServerTitle`, `loginIDField`, `loginPasswordField`, `loginSubmitButton`, `authUseWebViewButton`).
The control test (`…WithoutAWebviewSession…`) passed every time, so the launch path itself was fine.

`AuthCoordinator.restore` is the only place that can produce that screen on this launch: no vault
token (`-uiTestForgetSession`), so `AuthSession.restore()` returns `nil` with `needsReauth == false`,
and the next step is `adoptExistingWebSessionIfPresent`. Its failure is logged — and the app log said:

```
MMAuth: no webview session to adopt for Local Mattermost: notSignedIn
```

`MMError.notSignedIn` is thrown by `AuthSession.adoptWebSession` in exactly one place: the reader
returned no token. So the harvest was asked, asked the store, and got nothing.

## §2 Measurement A — the seeded cookie never existed

Instrumented DEBUG probes on the running app (`-uiTestSeedWebSessionCookie <token>` launch, shell=native,
`log show --info` for `com.mattermost.ios`). The store the reader and the seam both use is
`WKWebsiteDataStore(forIdentifier: server.id)`.

```
06:21:56.909  T31: uiTest: planted a webview session cookie for Local Mattermost
06:21:56.909  T31: probe t0 immediate: []
06:21:59.002  T31: probe t2 after 2s: []
06:21:59.366  T31: probe t2b write again: ["MMAUTHTOKEN@127.0.0.1"]
06:22:01.632  T31: probe t4 after webview: ["MMAUTHTOKEN@127.0.0.1"]
06:22:02.243  T31: probe reader … cookies=["MMAUTHTOKEN@127.0.0.1/"]
06:22:02.321  MMAuth: signed in as perfprobe on 127.0.0.1
06:22:02.343  MMAuth: adopted the webview session for Local Mattermost
```

Read that as: `setCookie` returned **and kept nothing** (t0), the cookie did not appear later either
(t2 — so it was discarded, not delayed), and the *same write* issued once the store's WebKit
**Networking** process was up was kept (t2b) — after which the harvest adopted it and the native
transport authenticated (`signed in as perfprobe`).

The surrounding WebKit log shows why the first window is special: the store's Networking process is
launched lazily at first use, and the seam wrote inside that launch:

```
06:21:56.450  (WebKit) NetworkProcessProxy::NetworkProcessProxy
06:21:56.454  Launching process … bundleID: com.apple.WebKit.Networking
06:21:56.465  Sending launch request: …
06:21:56.502  T31: uiTest: planted …            ← the write, ~40 ms into the launch
06:21:56.503  T31: probe t0 immediate: []       ← nothing kept
```

Ruled out, by measurement, before settling on that explanation:

* **store-instance incoherence.** A probe test wrote cookies through one
  `WKWebsiteDataStore(forIdentifier:)` instance and read them through a second and then a third
  instance of the same identifier: both saw them immediately (`PROBE reader.allCookies (immediate) =
  [PROBE_HOST@mm.example.com,PROBE_IP@127.0.0.1]`), and still saw them after the writer was released.
* **IP-literal domains.** The same probe wrote cookies for `127.0.0.1` as happily as for
  `mm.example.com`; the harvest's domain matcher is not the problem (and the token in §2 above is
  `@127.0.0.1`).
* **the auth gate asking for native sign-in anyway.** Once the cookie existed the gate resolved
  `signedIn` and the workspace drew (§4 shows the tree).

So the T31 suite was red because *its fixture was empty*, and `setCookie`'s completion handler is not
a success signal.

## §3 Fix A — writes are verified, in every place the shell installs a session

`Mattermost/Core/MM/WebSessionAdoption.swift`:

* `SessionCookieStoring` — the cookie store a writer installs into (`WKHTTPCookieStore` in
  production, a scripted double in the unit suite);
* `WebSessionCookieInstaller` — write → **read back** → retry (bounded, 8 × 250 ms by default) →
  return the **names that never landed**. Success means the cookie is *in the store*, not that
  `await` returned;
* `SessionCookiePolicy.isPresent` — presence by name **and value and scope**, so a previous launch's
  token under the same name is never mistaken for the write (that would report success for a dropped
  write and then harvest a dead credential).

Two call sites, both previously fire-and-forget:

* `MattermostApp.seedWebviewSessionCookieIfRequested` — the UI-test seam (since superseded, §4);
* `WebFallbackModel.installSessionCookieIfNeeded` (T46) — the one that shares the shell's session with
  a web fallback pane in **production**. It now reports `.none` instead of `.installed` when the
  cookies never reached the store, so the pane cannot sit on the web login while the shell believes
  it shared its session.

Unit evidence (`docs/t4528b67e-units-2026-11-04.log`, 48 run / 0 failed), new file
`MattermostTests/T31HarvestCookieInstallTests.swift`:

* `testTheInstallerRetriesAWriteTheStoreDiscards` — 2 dropped writes, kept on the 3rd; 3 write calls;
* `testTheInstallerNamesWhatADeadStoreNeverKept` — bounded at the configured rounds, names the
  cookie;
* `testAPreviousTokenOfTheSameNameIsNotTheWrite` / `testPresenceNeedsTheSameValueDomainAndPath` — the
  presence rule;
* `testARealStoreKeepsTheInstalledCookieAndTheProductionReaderFindsIt` — installer → real
  `WKWebsiteDataStore(forIdentifier:)` → `WebKitSessionCookieReader`, i.e. the production chain.

The T46 suite and the T31 harvest units were re-run with it (`T46WebFallbackTests`,
`T31WebSessionHarvestTests`): all green in the same 48.

## §4 Fix A was not enough: launching WebKit inside a UI run kills the app on this host

The first live run **with the verified installer** did not fail an assertion — it lost the app:

```
t = 15.91s  Checking existence of "nativeShell" Any
<unknown>:0: error: … : com.mattermost.ios crashed in <external symbol>
```

`~/Library/Logs/DiagnosticReports/Mattermost-2026-11-04-063031.ips`:

```
EXC_BAD_ACCESS, SIGSEGV, KERN_INVALID_ADDRESS at 0x0     faultingThread 0 (main)
  _platform_strcmp
  XCTAutomationSupport   runtime_issue_os_log_fault_callback
  libsystem_trace        _os_log_impl_flatten_and_send → _os_log_fault_impl
  WebKit                 AuxiliaryProcessProxy::didFinishLaunching
  WebKit                 NetworkProcessProxy::didFinishLaunching
```

That is the host pathology this repo already documents twice (`docs/t8d-build-note.md` §1,
`docs/t635-build-note.md` `SIGSEGV` section, `docs/t48-av-r5-repair.md`): **XCTest's own fault callback
runs inside the app**, and a **fault-level** `os_log` taken then dereferences NULL. The fault here is
WebKit's own: when its Networking process takes more than a second to launch it records
`RELEASE_LOG_FAULT("Networking process … took N seconds to launch")` — measured `1.474087 s` on this
simulator. Lowering the app's `os_log` volume (the `-uiTestLogLevel` seam) shrinks the window; nothing
in the app removes the trigger, and the seam's whole job was to start that process.

So the launch seam no longer starts a WebKit process in a UI run
(`Mattermost/MattermostApp.swift`, `seedWebviewSessionIfRequested`):

* the argument is now `-uiTestSeedWebSessionToken <token>`; it arms
  `AuthCoordinator.seedWebSession(token:for:)`, and the harvest's reader for that one server answers
  with the seeded session (`SeededWebSessionCookieReader`, DEBUG only, compiled out of Release);
* **what the test measures is unchanged**: no vault token → `AuthCoordinator.restore` →
  `adoptExistingWebSessionIfPresent` → `adoptWebSession` → `GET /users/me` with that token → vault
  write → `phase .signedIn` → every native pane authenticated from it. All of it production code;
* what is substituted is the *delivery* of the webview's session, the same choice the repo already
  makes for `-uiTestOpenDeepLink` (XCUITest cannot perform a `mattermost://` open). The real
  delivery — reading `WKWebsiteDataStore(forIdentifier:)` — is pinned by unit tests against a real
  store (`testTheProductionReaderFindsTheSessionInTheServersOwnWebsiteDataStore`,
  `testARealStoreKeepsTheInstalledCookieAndTheProductionReaderFindsIt`), plus
  `testALaunchSeededWebviewSessionIsAdoptedLikeARealCookie`, which pins the seam itself.

The measurement that the harvest is sound on the real path is in §2 (`adopted the webview session
for Local Mattermost`, `signed in as perfprobe`) — the harvest itself never needed repairing.

## §5 The suite's two remaining premises were false on this tree and this fixture

With the session in place the run got **past** the gate and failed at line 84 anyway
(`docs/t4528b67e-t31-live-2-landing-2026-11-04.log`). The dump at that failure is a signed-in shell:

```
Other … identifier: 'nativeChannelPane'
  StaticText … identifier: 'nativeChannelTitle', label: 'Town Square'
  ScrollView … identifier: 'channelPostList'
    … identifier: 'post.…' … label: 'Perf Probe'
```

`nativeShell` was nowhere in the tree — because since `t_295b0a32` a signed-in launch opens a channel
and **pushes it over** the list (`docs/t_c941e3d3-build-note.md` §7 measured the same thing for T36).
That is the shell's launch policy, not the harvest, so the assertion is now
`ShellSettle.waitForSignedIn(app, timeout: 60)` — the one helper that answers "are we in?" for both
landings, and which fails with the whole tree in its message. The `nativeAuthSurface`-absent and
`loginIDField`-absent assertions are untouched, so the claim "signed in, not the sign-in screen" is
still asserted twice.

Next failure (`docs/t4528b67e-t31-live-3-grouping-2026-11-04.log`, line 107):
`channelSidebar.category.channels` was never drawn. The dump shows why — the list is on screen and
grouped, but `perfprobe` has **custom channel sections**, so the default "Channels" pseudo-category
does not exist:

```
Button … identifier: 'channelSidebar.workspaceHeader', label: 'WORKSPACE'
Button … identifier: 'channelSidebar.category.custom.uje1k54pqbngmxpipbf33poppa', label: 'T8G group 8'
Button … identifier: 'channelSidebar.channel.…', label: 'T8G probe 0071'
```

Naming that one identifier was an assumption about the fixture account. The assertion is now "at
least one `channelSidebar.category.*` header of this account's own grouping is drawn", and the
row/identity assertion below it (a non-empty intersection between the drawn
`channelSidebar.channel.*` ids and the channel ids the **server** says this account is a member of)
is unchanged and still the substantive check — it is what fails if the token never reached the native
transport.

Supporting changes, in `MattermostUITests/ShellSettle.swift`:

* `revealChannelList(_:maxPops:)` — the "wait for the pushed pane, then `Back` until the channel list
  is on screen" step, extracted from `revealSidebarChannel` (which keeps its behaviour: T36 17 swipes
  + 1 Back, T44d 18 + 1, identical to `docs/t941-t36-live-2026-11-04-published.log`);
* the category and row queries in this suite are **typed** (`buttons`) rather than any-type, because
  the T8d note's log-volume quarantine is what makes the §4 crash more likely (`docs/t8d-build-note.md`
  §2).

## §6 Runs (all on this host, this device, the 9.11.19 fixture)

| what | result | log |
|---|---|---|
| units: harvest + install + T46 fallback (+T31 auth) | **48 run / 0 skipped / 0 failed** | `docs/t4528b67e-units-2026-11-04.log` |
| T31 harvest, installer only | app **SIGSEGV** (§4) | `docs/t4528b67e-t31-live-crash-2026-11-04.log` |
| T31 harvest, seeded reader | line 84, `nativeShell` (§5) | `docs/t4528b67e-t31-live-2-landing-2026-11-04.log` |
| T31 harvest, `waitForSignedIn` | line 107, grouping (§5) | `docs/t4528b67e-t31-live-3-grouping-2026-11-04.log` |
| **T31 harvest, final** | **2 run / 0 skipped / 0 failed, 17.097 s** | `docs/t4528b67e-t31-live-2026-11-04.log` |
| **T31 harvest, repeat** | **2 run / 0 skipped / 0 failed, 17.987 s** | `docs/t4528b67e-t31-live-repeat-2026-11-04.log` |
| **T31 harvest, on the published tree** (`origin/main` **89abc4c**) | **2 run / 0 skipped / 0 failed, 18.178 s** | `docs/t4528b67e-t31-live-published-2026-11-04.log` |
| T36 + T44d (shared sidebar helper) | **7 run / 0 skipped / 0 failed, 620 s** | `docs/t4528b67e-sidebar-regression-2026-11-04.log` |

The three failing runs above are kept on purpose: they are the measurement chain, not noise.

## §7 What is not claimed

* The **harvest** is not newly claimed to work in every webview case. What is claimed is narrower and
  measured: with a session in the store, a launch with no vault token adopts it, verifies it with
  `GET /users/me`, persists it and draws the native workspace (§2). The SSO sheet's own adoption was
  already unit-tested and is untouched.
* The **UI** suite no longer launches a WebKit cookie store; the real store read is unit-tested. That
  is a deliberate split forced by §4, and it is the one place a reader could call the coverage
  different. The alternative — the real write — was measured to (a) not land and (b) crash the app.
* The `WebSessionCookieInstaller` retry window (8 × 250 ms) is sized from one measurement of a slow
  simulator; a slower host could still exhaust it. When it does, the caller now says so
  (`T31: … never landed` / `WebFallback: … never reached the store`) instead of pretending.
* No APNs, no real push proxy, no CI leg: everything here is a local live run on this simulator.

## Files

```
Mattermost/Core/MM/WebSessionAdoption.swift          + SessionCookieStoring, WebKitCookieStore,
                                                       WebSessionCookieInstaller, isPresent,
                                                       SeededWebSessionCookieReader (DEBUG)
Mattermost/MattermostApp.swift                        seam → -uiTestSeedWebSessionToken
Mattermost/UI/Native/Auth/AuthCoordinator.swift       seedWebSession + cookieReader(for:)
Mattermost/UI/Native/Web/WebFallbackModel.swift       verified install (T46), .none when it fails
MattermostTests/T31HarvestCookieInstallTests.swift    new: 6 tests
MattermostTests/T31WebSessionHarvestTests.swift       + the launch-seam test
MattermostUITests/ShellSettle.swift                   revealChannelList (extracted)
MattermostUITests/T31WebSessionHarvestUITests.swift   landing + grouping premises, typed queries
docs/t4528b67e-*.log                                  the six runs above
```
