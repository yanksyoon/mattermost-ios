# T48-AV-R5 — the live suite gets its own session, a copy that polls, and a refusal that says why

> **Second pass, 2026-11-04.** The two gates this pass left open (a second consecutive green run, and
> the refused write) are now measured, and the pin test's red run was traced to **one more harness
> defect** — the sheet's last row is not the row a synthesized tap on it reaches. See
> [§Second pass](#second-pass--2026-11-04-the-row-the-suite-never-pressed-and-the-two-open-gates) at the
> end of this note; everything above it is the first pass, kept as written.

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

---

## Second pass — 2026-11-04: the row the suite never pressed, and the two open gates

The first pass shipped the four repairs and one clean live run, and left two gates open. This pass spent
both on a quiet host and found **one more harness defect**, which is why the pin test was red on every
attempt before this change.

### 5. The sheet's last row is not the row a tap on it reaches (new, measured)

The pin test failed on every attempt — `build/logs/t48r5-live-b.log`, `t48r5-pin-probe.log`,
`t48r5-pin-probe2.log`, `t48r5-pin-probe5.log` — with

```
XCTAssertTrue failed - Pin must reach POST /posts/{id}/pin; the server does not hold it
XCTAssertTrue failed - the options sheet must open
XCTAssertTrue failed - a pinned post must offer Unpin on the next open
```

and **no app-side error line**. That is exactly the ambiguity §3 exists to remove ("a transport failure
or a tap that never reached the action"), and the answer was a third option. An instrumented build — a
temporary `Logger.error` at the head of `PostOptionsSheet.press` and `PostOptionsViewModel.perform`,
**not committed** — named it:

```
00:30:02.916  [com.mattermost.ios:T48P] press enter reply
```

at the timestamp of the runner's tap on `postOptions.pin`, and the teardown screenshot shows the
**thread composer** ("Replying to T36 Reply") over the channel list. The tap did reach the app — as the
row above.

Measured layout in the `.medium` detent (accessibility frames, 402 × 874 pt): React 580, Reply 624,
Mark as Unread 668, Copy Link 712, Save 756, Copy Text 800, **Pin to Channel 844–888**. The last row runs
under the bottom edge, and Reply is 338 points above Pin — exactly the detent's own height.

`app.swipeUp()` once after the sheet opens (to `.large`) fixes it deterministically: the same tap then
logs `press enter pin` → `perform enter pin post … busy=-` → `press pin returned from perform`, and the
write is on the server (`build/logs/t48r5-pin-probe4.log`, one test, green). A 0.8 s sleep before the
same tap does **not** fix it (`build/logs/t48r5-pin-probe5.log`), so the presentation animation is not the
explanation.

`openMenu` now expands the sheet before any test presses a row, and the comment there carries this
measurement. It is a statement about a **synthesized touch**: whether a reader's finger at that point
reaches the row is *not* established here.

### 6. The toolchain crash that cost four of this pass's runs (not this repo's)

Four full-suite runs ended with `Failed to application com.mattermost.ios is not running` in the copy
test, each with the same crash report on disk (`~/Library/Logs/DiagnosticReports/Mattermost-2026-11-04-*.ips`
— six today: 00:00:24, 00:02:30, 00:19:50, 00:51:08, 01:06:39, 01:21:46):

```
EXC_BAD_ACCESS (SIGSEGV) / KERN_INVALID_ADDRESS at 0x0 — main thread
  libsystem_platform.dylib  _platform_strcmp
  XCTAutomationSupport      runtime_issue_os_log_fault_callback
  libsystem_trace.dylib     _os_log_invoke_callback
  libsystem_trace.dylib     _os_log_impl_flatten_and_send
  libsystem_trace.dylib     __LIBTRACE_CLIENT_QUARANTINED_DUE_TO_HIGH_LOGGING_VOLUME__
```

Xcode's automation support crashes the app under test when libtrace quarantines that process for logging
volume, and its fault callback `strcmp`s a NULL system string. The volume is Xcode's own:
`log show --last 12m --predicate 'process == "Mattermost"'` is 1,469,438 lines, of which 851,992 are
`com.apple.dt.xctest` accessibility chatter and **15** are this app's `com.mattermost.ios` subsystem — so
it is not this repo's `Logger`, and `OS_ACTIVITY_MODE` cannot filter it (the flood is default-level, not
debug). The same signature interrupted the T48-AV pass at 20:12 the day before, so it predates this card.

The practical consequence, measured: after a run that finishes normally, the **next** run on the same
simulator boot tends to take it; a `simctl shutdown` + `boot` before each run produced the two clean runs
below. That is simulator hygiene, not a code change, and it is written down so the next pass does not
re-discover it.

### 7. The refused write, measured live

The mutation from §"The refused-write proof" was applied for one run and reverted: the fixture post is
deleted between `openMenu` and the pin tap, and 9.11.19 answers `POST /posts/{id}/pin` with **403**
(`api.context.permissions.app_error`; measured directly against the fixture before the run). Result:
**exactly one red test** and the app log names the status, read back from the simulator:

```
[com.mattermost.ios:T48] post option pin failed for post 7ikoeqyx9tbafy7ro616tftaxy in channel
psw97y5zqpfnpembwxraizuije: HTTP 403 — forbidden(message: Optional("You do not have the appropriate permissions."))
```

The same test then also goes red on its next two assertions, because the deleted post's row is gone from
the channel — `Executed 6 tests, with 3 failures (0 unexpected)`, i.e. one red test carrying three
assertion failures, the other five green.

### Runs — this pass, in order (iPhone 16 Pro / iOS 18.3, `7EE01BD0-121B-4DBE-B9FF-47C41900C6B7`)

| Run | Result | Log |
| --- | --- | --- |
| `t48r5-live-b` — before the row fix | 6 run / 2 tests red (pin per §5, copy by §6) | `build/logs/t48r5-live-b.log` |
| `t48r5-pin-probe` — pin alone, before the fix | 1 run / 3 failed | `build/logs/t48r5-pin-probe.log` |
| `t48r5-pin-probe2` — instrumented | 1 run / 3 failed — `press enter reply` at the tap | `build/logs/t48r5-pin-probe2.log` |
| `t48r5-pin-probe4` — sheet expanded | **1 run / 0 failed** — `press enter pin` | `build/logs/t48r5-pin-probe4.log` |
| `t48r5-pin-probe5` — 0.8 s sleep, not expanded | 1 run / 3 failed | `build/logs/t48r5-pin-probe5.log` |
| `t48r5-live-c` | **6 run / 0 skipped / 0 failed**, 401.0 s | `build/logs/t48r5-live-c.log` |
| `t48r5-live-d` | 6 run / 1 test red — §6 | `build/logs/t48r5-live-d.log` |
| `t48r5-live-e` | **6 / 0 / 0**, 396.5 s | `build/logs/t48r5-live-e.log` |
| `t48r5-live-f` | 6 run / 1 test red — §6 | `build/logs/t48r5-live-f.log` |
| `t48r5-live-g` | **6 / 0 / 0**, 423.4 s | `build/logs/t48r5-live-g.log` |
| `t48r5-live-h` | 6 run / 1 test red — §6 | `build/logs/t48r5-live-h.log` |
| `t48r5-live-i` | **6 / 0 / 0**, 399.8 s | `build/logs/t48r5-live-i.log` |
| `t48r5-live-j` | 6 run / 1 test red — §6, during Copy Text | `build/logs/t48r5-live-j.log` |
| `t48r5-live-k` (**simulator rebooted first**) | **6 / 0 / 0**, 401.5 s | `build/logs/t48r5-live-k.log` |
| `t48r5-live-l` (**simulator rebooted first**) | **6 / 0 / 0**, 402.4 s | `build/logs/t48r5-live-l.log` |
| `t48r5-refusal2` (mutated) | 6 run, **one red test** (pin, 3 assertions), 481.4 s — §7 | `build/logs/t48r5-refusal2.log` |

**Two consecutive green runs: `k` then `l`, 6/6 both times, no skips** (each preceded by a simulator
reboot, §6). The suite has six tests, not five: R3 added
`testAFollowedRootStillOffersUnfollowAfterARelaunch` on top of the five this card names.

The live suite still never calls `URLSession.shared` — the only occurrence of that name in the file is
the comment explaining why (`grep -n "URLSession.shared" MattermostUITests/T48PostOptionsUITests.swift`),
every request goes through `restSession`, and all six tests log in fresh on every run (the runner's own
`login` calls answer 200 in each run above).

### What this pass still does not establish

* A real device: none is attached; every run is a simulator.
* Whether the crash in §6 has any non-toolchain trigger — the evidence says the volume is Xcode's, but
  the quarantine threshold itself is opaque.
* Whether a reader's finger at the sheet's bottom edge reaches the row a synthesized tap misses (§5).
* APNs / push-driven menu state: no APNs credentials on this host.

