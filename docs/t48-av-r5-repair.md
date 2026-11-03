# T48-AV-R5 — the live suite gets its own session, a copy that polls, and a refusal that says why

Repairs `docs/t48-av-build-note.md` §F6 (card `t_ff68111a`). The menu's writes were never in doubt —
the T48-AV pass measured every one of them on 9.11.19. What did not reproduce was the **suite**: the
five live tests claimed green by `docs/t48-build-note.md` ran 1-of-5 on a clean device, and the two
failures it did produce were two harness defects and one product-visible symptom, not the menu.

Base for this pass: `da171b4`, rebased onto `bde77c5` (T48-AV-R2) before publishing. Fixture:
Mattermost **9.11.19** on `127.0.0.1:8065` (container `mm-perf`), accounts `perfprobe` / `t36reply`
(`scripts/perf_seed.py`, `scripts/t36_thread_seed.py`).

## What changed

| # | Defect (T48-AV §F6) | Repair | File |
| --- | --- | --- | --- |
| 1 | the tests' own REST client is `URLSession.shared`, whose cookie store carries `MMAUTHTOKEN` between tests and makes a correct login answer 401 | a cookie-free `URLSessionConfiguration.ephemeral` (`restSession`), and the login token is read from the `Token:` **response header** | `MattermostUITests/T48PostOptionsUITests.swift` |
| 2 | the pasteboard read-back is one 400 ms sleep, so a string that did land can be reported as "not copied" | the sheet polls the pasteboard for up to **2 s** and withdraws the row only when the window closes empty; the suite waits for the `postOptions.copied` row **while scrolling**, instead of asserting `.exists` on the first turn | `Mattermost/UI/Native/Channel/PostRowView.swift`, `MattermostUITests/T48PostOptionsUITests.swift` |
| 3 | a refused write returns `.failed` with no log, so "the server does not hold it" cannot be traced to a status | `perform`'s catch logs the option, the post id, the channel and the HTTP status at error level (`HTTP none` when the failure never reached the server) | `Mattermost/UI/Native/Channel/PostOptionsViewModel.swift`, `Mattermost/Core/MM/MMError.swift` |
| 4 | a red run carries nothing on screen: every `attach` sits on the success path | `addTeardownBlock` attaches a screenshot whenever the case recorded a failure | `MattermostUITests/T48PostOptionsUITests.swift` |

### 1. A session that carries no cookie

`synchronous` runs on `Self.restSession` — `URLSessionConfiguration.ephemeral` with
`httpCookieStorage = nil`, `httpShouldSetCookies = false`, `httpCookieAcceptPolicy = .never` — the shape
T47-AV measured and shipped (`T47CreateChannelAVUITests.restSession`). No request in the file builds on
`URLSession.shared` any more; the only occurrence of that name is the comment that says why:

```
$ grep -n "URLSession.shared" MattermostUITests/T48PostOptionsUITests.swift
614:    /// `URLSession.shared` carries `MMAUTHTOKEN` between tests in one runner process; T47-AV measured
```

`authenticate` reads `Token:` from the response header first, with the body copy only as a fallback for a
server that omits the header. Measured against the fixture, the header is the **only** place the
credential exists — the 9.11.19 login body carries no `token`:

```
login 200 token header: True body token: False
```

### 2. The pasteboard read-back polls

`UIPasteboard`'s write reaches the system pasteboard asynchronously. The sheet wrote the string, showed
it, and then re-read **once** 400 ms later; on this host that single read answered `nil` for a copy that
had landed, the row was withdrawn, and the reader got "Could not put this on the clipboard." That is the
exact symptom T48-AV reproduced — `Copy Link` green with the server's own permalink, `Copy Text` red one
tap later, same mechanism.

`PostOptionsSheet.press` now polls every 100 ms for up to 2 s and withdraws the row only if the window
closes with the string still absent. The runner still never reads `UIPasteboard`: that rule stands (iOS
26 raises the system paste prompt for the runner and wedges the run).

The suite also stops asserting `.exists` on the copied row immediately after the tap. `revealAppendedRow`
polls **and** scrolls together: `revealOption`'s burst of swipes finishes before the row exists, so the
row is then appended below the fold with nothing left to scroll to.

Measured: in the clean run below, both copy options passed in one session —
`testTheMenuOffersTheMissingOptionsAndCopyLinkIsTheServersPermalink passed (155.298 seconds)` — which is
the pair T48-AV could not get green together.

### 3. A refused write says what it was

```
T48: post option pin failed for post <post id> in channel <channel id>: HTTP 403 — forbidden(message: nil)
```

`MMError.httpStatus` is the mapping (`401`/`403`/`404`/`429`, the carried status for `.server`/`.client`,
`nil` for offline, timeout, decode and other non-HTTP failures), and `perform`'s catch logs once per
refused write. The sheet's reader-facing sentence is unchanged.

Three unit tests pin the half that can be pinned without a server:

* `testTheHttpStatusIsTheOneTheRefusalCameFrom` — the mapping, including `nil` for a timeout;
* `testARefusedWriteLogsTheOptionTheStatusAndThePost` — one error line per refused write, carrying the
  option, the post id and `403`;
* `testAWriteThatNeverReachedTheServerLogsNoStatus` — a timeout says `HTTP none` instead of inventing one.

### 4. A red run carries its screen

`setUpWithError` installs a teardown block that attaches `t48-failure-<test>` whenever
`testRun?.totalFailureCount > 0` and the app is still running. The success-path attachments are unchanged.

The first version keyed on `testRun?.hasSucceeded != true`; teardown runs before XCTest settles the case,
so that was false for a passing test too and attached a screenshot to every green test as well (measured:
run 1 produced five `t48-failure-…` images, four of them green). `totalFailureCount` is the signal that
exists at teardown time.

## Runs — measured on this host

Host: macOS 26.3.1, iOS 26.5 simulator `iPhone 17 Pro` (`6B6991BF-6816-44EE-8FEA-284712F6ECBB`), erased
and booted before the first run. Every run uses the repo's guarded runner (`scripts/qa-test.py`) with a
cloned source-package directory (a fresh resolve hangs on GRDB's SQLiteLib submodule).

| Run | Tree | Result | Artifact |
| --- | --- | --- | --- |
| T48 options units | `da171b4` + this change | **26 run / 0 skipped / 0 failures**, `RESULT: PASS` (23 shipped + 3 new) | `build/logs/t48r5-units.log` |
| Clean live suite (run 1) | `da171b4` + this change | **5 run / 4 passed / 1 expected failure / 0 unexpected / 0 skipped**, 608.5 s — the failure is the known `preferences_changed` socket gap, recorded with `XCTExpectFailure`; both copy options green | `build/logs/t48r5-live1.log` |
| Clean live suite (run 2) | same | **environment, not counted**: `Failed to get matching snapshots: Error getting main window kAXErrorServerNotFound`, `Failed to terminate com.mattermost.ios` — five sibling workers were building in this checkout, load average 500–990 | `build/logs/t48r5-live2.log` |
| Refused-write live run | same, plus the temporary mutation below | **environment, not counted**: `Failed to install or launch the test runner: Error returned in reply from CoreSimulatorService: Connection interrupted` — the runner never started, so nothing was measured | `build/logs/t48r5-refused.log` |
| Build after the rebase onto `bde77c5` | `bde77c5` + this change | **`** TEST BUILD SUCCEEDED **`** — compile-verified with `build-for-testing`; the one conflict (`T48PostOptionsTests.swift`) was an append-vs-append with R4's tests, and both blocks are kept | `/tmp/t48r5-compile.out` |

The clean run's summary line, verbatim:

```
Executed 5 tests, with 1 failure (0 unexpected) in 608.453 (608.473) seconds
```

### The refused-write proof (prepared, **not** measured live)

The mutation is three lines in `testPinFromTheMenuShowsInThePinnedSheet` — delete the fixture post
through the API between `openMenu` and the pin tap, which 9.11.19 answers with **403** (measured in
T48-AV §1):

```swift
_ = try sendJSON("DELETE", "/api/v4/posts/\(postID)", body: nil, token: secondToken)
revealOption(app, "postOptions.pin").tap()
```

On a quiet host this should produce `5 run / 1 failure` (the other four tests create their own posts) and
the app log quoted in §3, readable from the simulator afterwards:

```bash
xcrun simctl spawn <device> log show --last 30m \
  --predicate 'subsystem == "com.mattermost.ios" AND category == "T48"' --style compact
```

It is **not claimed as measured**: the run that carried it never launched its runner. What *is* measured
is the unit half (above) and that the line is emitted at error level through the same `Logger` the app
uses everywhere.

## What this pass does not establish

* **Two consecutive green live runs.** One clean run reproduced 4-of-5 green with the fifth in its
  documented expected-failure, and both copy options passed together for the first time; the second run
  and the refused run were both lost to host contention (two different simulator failures, quoted above).
  The card's "green twice in a row on a quiet host" is therefore **not** claimed — it is one run short,
  and the exact commands are below so the next pass can spend them on a quiet host.
* The live `403` in the app log — the mutation is written down above, not executed to completion.
* A real device: none is attached; every run is a simulator.
* APNs / push-driven menu state: no APNs credentials on this host.

## Reproduce

```bash
cd <worktree at bde77c5 + this change>
# units
python3 scripts/qa-test.py --platform ios --sim id=6B6991BF-6816-44EE-8FEA-284712F6ECBB \
  --only-testing MattermostTests/T48PostOptionsTests \
  --derived-data ~/Library/Developer/Xcode/DerivedData/mmios-t48r5wt \
  -- -clonedSourcePackagesDirPath ~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa/SourcePackages
# live (five tests)
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> python3 scripts/qa-test.py --platform ios \
  --sim id=6B6991BF-6816-44EE-8FEA-284712F6ECBB \
  --only-testing MattermostUITests/T48PostOptionsUITests \
  --derived-data ~/Library/Developer/Xcode/DerivedData/mmios-t48r5wt \
  -- -clonedSourcePackagesDirPath ~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa/SourcePackages
```
