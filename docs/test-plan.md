# Test plan — T17: unit (XCTest) + UI (XCUITest) + device parity soak

Design of record: `~/.hermes/plans/2026-10-08_mattermost-desktop-ios-migration.md` §7.
Scope: the native shell services (Core/) and shell chrome (UI/) the migration builds. The chat
UI itself lives in the Mattermost web app and is out of scope except as a webview smoke target.

Legend: **PASS** = executed on this host with real output; **BLOCKED@host** = cannot be
validated on this host (needs a real Mattermost server / APNs / physical device); **N/A** = no
iOS analog by design.

---

## 1. Unit tests (XCTest) — `MattermostTests`

Approach: deterministic, no live network. Stores take an injected `AppPreferences` over a
per-test `UserDefaults` suite; `SecureVault` forges a unique Keychain namespace per test;
badge math uses a recording `BadgeSettable` mock; download logic is pure and unit tested with
live transfers deliberately excluded (a `URLSessionDownloadTask`/`WKDownload` needs a reachable
server + interactive webview — runtime concerns, covered by UI/soak below).

Command:
```
scripts/qa-test.py --platform ios --only-testing MattermostTests
# or, raw xcodebuild (keep derived data OUTSIDE ~/Documents -- see §6):
xcodebuild -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'id=C36282C3-F865-4270-9164-28220818CFCE' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa \
  -only-testing:MattermostTests test-without-building
```

| Area (task) | File(s) | Status |
|---|---|---|
| ServerStore CRUD | `MattermostTests/ServerStoreTests.swift` | **PASS** 5/5 |
| Vault round-trip (relaunch persistence, per-server isolation) | `MattermostTests/SecureVaultTests.swift` | **PASS** 9/9 |
| Badge math (cross-server mentions/unread/expired + showUnreadBadge) | `MattermostTests/SessionStoreTests.swift` | **PASS** 14/14 |
| Deep-link routing (parse/route/queue/unmatched/add-offer) | `MattermostTests/DeepLinkRouterTests.swift` | **PASS** 12/12 |
| Download dedup + journal CRUD/trim + sanitize/unique filename | `MattermostTests/DownloadWorkerTests.swift` | **PASS** 20/20 (2026-10-23) |

Execution evidence (run 2026-10-23 14:41 +08): **220 tests run, 220 pass, 0 fail**
(`** TEST SUCCEEDED **` for the whole scheme; UI target 6/6 below).
The 7 failures seen on 2026-10-22 were fixed at their source on 2026-10-23, not filtered out:
- 6 came from over-escaped fixtures in `DownloadWorkerTests.swift` (`"…\\(…)"` instead of
  `"…\(…)"`), which made every `DownloadHistoryTests` case share one `UserDefaults` suite and
  every `record(_:)` source identical — dedup/trim/order assertions were comparing against
  literal `file-\(i).txt`. Unescaped; assertions now exercise real values.
- 1 was a genuine `DownloadWorker.sanitizedFilename` defect: a separator-only name (`"////"`)
  returned `"////"` instead of the `download` fallback, so a slash-bearing name could reach
  `appendingPathComponent`. `rawLastComponent` now yields `""` for a component-less value.
The same double-escaping was present in 10 production log statements and 3 other test fixtures;
all fixed (zero remaining hits for `\\(` in `Mattermost/` and `MattermostTests/`).

## 2. UI tests (XCUITest) — `MattermostUITests` (NEW target this task)

Approach: launch with `-uiTestResetPersistedState` (a DEBUG seam in `MattermostApp.init()` that
wipes UserDefaults-backed shell state so each test starts from a genuine fresh first-run;
Keychain is deliberately untouched) → deterministic, order-independent.
Offline determinism: a local stub Mattermost server (`build/uitest-server/mm_stub.py`) answers
`/api/v4/system/ping` + `/api/v4/config/client?format=old` + an HTML login page + a downloadable
file, served over the host loopback that the simulator shares. Add-server validation therefore
proceeds against the stub, not a flaky public server. `NSAllowsLocalNetworking` (ATS) was added
so the shell's `URLSession` probe can reach the plain-HTTP on-network stub while public-internet
traffic still requires HTTPS (scoped, per design risk R2).

Command (stubs first, see §5):
```
python3 build/uitest-server/mm_stub.py --port 8111 --name "Local Mattermost Test" &
python3 build/uitest-server/mm_stub.py --port 8443 --tls \
   build/uitest-server/cert.pem,build/uitest-server/key.pem --name "Self Signed Test" &
xcodebuild -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'id=C36282C3-F865-4270-9164-28220818CFCE' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa \
  -only-testing:MattermostUITests test
```

| Flow (task) | Test | Status |
|---|---|---|
| Onboarding → first-run pager | `testOnboardingPagerGetStartedOpensAddServerForm` | **PASS** |
| Add server → login-through-webview (stub login HTML) | `testAddServerThroughFormThenWebviewLoad` | **PASS** (webview loads stub login page) |
| Server switch (2 servers → switch) | `testServerSwitchBetweenTwoServers` | **PASS** |
| Settings persist (download-history Stepper across reopen) | `testSettingsDownloadHistoryLimitPersists` | **PASS** |
| Downloads list (empty-state over fresh journal) | `testDownloadsOpensToEmptyState` | **PASS** |
| Cert prompt (self-signed TLS stub → CertPromptSheet) | `testCertPromptShownForSelfSignedServer` | **PASS** |

Execution evidence (run 2026-10-22 04:33): **6/6 PASS, 0 failures.**

Testability changes made to the app (all sealed behind no-arg behavior / identifiers only):
- `MattermostApp.init()`: reordered store creation into `init()` so the reset/seed seam can run
  first; added `-uiTestResetPersistedState` (wipe shell stores) and
  `-uiTestSeedSelfSignedServer <url>` (pre-populate one self-signed server so the webview hits
  the trust challenge). Both inert without the argument.
- `RootView`: `accessibilityIdentifier`s for `addServerToolbarButton`, `serverSwitcher`;
  removed the hard-coded `accessibilityLabel("Switch server")` so the switcher's accessible
  label reads the active server name (better VoiceOver too).
- `Mattermost/Info.plist`: `NSAllowsLocalNetworking=true` (scoped ATS, design risk R2).

## 3. Real-device parity soak (candidate script)

Cannot run on this host: needs a real Mattermost server with real accounts, APNs entitlement
(no `.p8`), and a physical device for background/foreground / terminated-state notify delivery.
Record what the soak must cover so it's testable when infra lands:

- Add ≥2 servers (one the active community server; one a private/self-hosted instance).
- Sign in on both; verify cross-server **app-icon badge correctness** (mentions sum, unread
  dot, expired) — background via `simctl`/carrier, each server's mention count independent.
- **Push while terminated**: kill the app, deliver a silent/APNs payload via the Push Proxy,
  relaunch, assert the notification + badge reconcile with the server state.
- Calls screen-share quality (needs Broadcast Extension + WebRTC on device).
- Regression parity: run the same login / thread / settings flows weekly on desktop and iOS,
  log divergences (design §7 "Regression net").

## 4. What cannot be validated on this host (explicit, no fabricated pass)

- **APNs / remote push** — needs an Apple `.p8`, a configured Push Proxy + DiagnosticId, and the
  Push Notifications capability. Design risk R1. Covered partially by the Push Proxy simulacrum
  (T12) but real delivery is unverified.
- **Real login-through-webview** against a production Mattermost instance with a real account —
  the stub only proves the shell mounts a webview and loads *a* login HTML; full OAuth/SSO +
  session persistence on a real server is unverified here.
- **Real-download end-to-end** (webview-initiated file download landing in the journal) and
  Share-to-Files export on device — unit-tested logic + empty-state UI are verified; the live
  transfer path needs a logged-in server + device.
- **Real-device soak** (§3) — physical hardware only.

These are recorded as remaining validation, not passed.

## 5. Local stub server (committed fixture)

`build/uitest-server/mm_stub.py` + generated `cert.pem`/`key.pem` (self-signed for
cert-prompt). Simulator ↔ host loopback: iOS simulator shares the Mac's network stack, so
`127.0.0.1` from the app reaches the host stub. Regenerate the cert any time:
```
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -keyout build/uitest-server/key.pem -out build/uitest-server/cert.pem \
  -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1"
```

## 6. Harness: a *failing* unit test used to wedge the test host (T14b)

Symptom: `xcodebuild test` stalls forever at `Test Case '…' started.`, no failure line, no
`** TEST FAILED **`; only the caller's timeout ends it (`** BUILD INTERRUPTED **`). It happens
only when a test *fails*, so an intentionally-broken test is indistinguishable from a deadlock in
product code. Reproduced deterministically with `XCTAssertEqual(1, 2)` in `WebViewStoreTests` (log
and `sample` attached to the T14b board card: `t_14b5684e`).

Not a product bug. When an assertion fails, XCTest symbolizes the failure **in-process**; `sample`
of the wedged host puts the main thread at

```
-[XCTestCase recordIssue:] -> -[XCTSourceCodeFrame symbolInfoWithError:]
  -> -[XCTInProcessSymbolicationService …] -> CSSymbolOwnerGetSymbolWithAddress
  -> CSCppSymbolOwnerCache::create_symbol_owner_data -> extract_debug_map_data_from_header
  -> CSSymbolicatorCreateWithPathArchitectureFlagsAndNotification -> CSFileIsCoreFile
  -> fopen -> open$NOCANCEL                      (blocked, 0 % CPU)
```

(`build/logs/t14/sample-ios-sim-74129.txt` at the time of writing; also attached to the card),
line-for-line the stack in the ticket. CoreSymbolication
opens the object files named in the binary's debug map. When the build products sit inside a
**TCC-protected folder** — this repo lives in `~/Documents`, so every `-derivedDataPath build/…`
does — `sandboxd` asks `tccd` for access on behalf of `com.mattermost.ios` and the `open()` blocks
until the consent is answered. Nothing answers in a non-interactive run, so it blocks forever.
`tccd` shows the request at the same millisecond the failing case starts:

```
tccd[436] [com.apple.TCC:access] AUTHREQ_ATTRIBUTION … accessing={TCCDProcess:
  identifier=com.mattermost.ios, pid=74129 …, binary_path=…/CoreSimulator/Devices/…/Mattermost.app/Mattermost}
```

The Catalyst occurrence in `t_ca6db268` (pid 68124) shows the same request with
`service=kTCCServiceSystemPolicyAllFiles` and
`Failed to match existing code requirement for subject com.mattermost.ios` — an ad-hoc-signed host
gets a fresh TCC subject per build, so the consent would have to be re-granted on every rebuild.
Passing runs never symbolize, which is why the suite looked green: only the failing path reads the
protected folder.

**Fix — `scripts/qa-test.py` (guarded runner):**
- derives into `~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa` by default and *refuses* a
  derived-data path inside `~/Documents`, `~/Desktop`, `~/Downloads` unless
  `--allow-tcc-unsafe-derived-data` is given (that is the wedge trigger, not a style preference);
- watches the run: if tests have started and output stops for `--stall-timeout` (default 240 s), it
  samples the test host, kills the run, prints the `recordIssue -> CSSymbolOwner -> open` diagnosis
  plus the `tccd` lines, and exits **124** — a wedge can no longer look like "still running";
- writes a `.xcresult`, parses `** TEST SUCCEEDED **` / `** TEST FAILED **` and returns
  0 / 1 / 2 / 124 (`xcodebuild` returns 65 on a reported failure, but nothing at all on a hang);
- `--self-test` is the standing break-proof: it injects a deliberately failing test into
  `MattermostTests/WebViewStoreTests.swift`, runs it, asserts a source-located `error:` line,
  `** TEST FAILED **`, a non-zero exit and no wedge, then reverts the file (it refuses to run if
  that file is dirty).

Rule that follows: **never point a test run's derived data into `~/Documents`** — use
`scripts/qa-test.py`, or `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/…` for raw
`xcodebuild`. A `build/…` path is fine for plain `xcodebuild build`, but any run in which a test
may fail will hang there.

**The same rule applies to the test's *inputs*, not just its derived data** (t_fc31e308). A test
that builds a path from `#filePath` and opens it reads the checkout — `~/Documents` from the shared
checkout — and the test host's `open()` blocks on the same consent that never arrives. The suite
then dies mid-run on that one case: the full `MattermostTests` lane stopped at
`T56SelectionTests.testNoHTMLParserInEitherRenderer` (4681 cases into one run, 8874 into another),
`sample` of the host showing 100 % of samples in `open()` under
`String(contentsOf:)`, and `qa-test.py` returning 124 after 240 s of silence. Fix in place:

- the two renderer sources that T56 scans are copied into the test bundle at build time by the
  **"Bundle Scanned Sources"** phase on the MattermostTests target, and
  `MattermostTests/SourceScan.swift` reads them from `Bundle(for:)` — the invariant still scans the
  real source text of the build under test, but nothing reads the checkout at run time;
- `qa-test.py` now *predicts* the whole class: if the checkout is inside `~/Documents`,
  `~/Desktop` or `~/Downloads` and any `MattermostTests`/`MattermostUITests` line still builds a
  URL from `#filePath`, it refuses before building (exit 2, naming file:line) unless
  `--allow-tcc-unsafe-source-read` is given. That is on top of the stall watcher: the guard is for
  the next regression, the watcher is for everything nobody predicted.

## 7. Harness: enumerating a long list one element at a time kills the UI-test host (T34-QA)

Second harness failure, different from §6 and unrelated to TCC. On a long post list the **app
process is lost** with `EXC_BAD_ACCESS (SIGSEGV, KERN_INVALID_ADDRESS at 0x0)` on its main thread:

```
-[XCTAccessibilityFramework attributesForElement:attributes:error:]
  -> -[XCElementSnapshot children] -> __XCTPerformOnMainRunLoop_block_invoke
```

Crash reports: `~/Library/Logs/DiagnosticReports/Mattermost-2026-10-25-210015.ips` and
`-210758.ips` (both `SIGSEGV`, signal/subtype checked in the file). It fired while the test was
snapshotting the post list after a page insert (120 rows), and every later test in the suite then
failed as a cascade — which reads like "three product failures" and is not.

Cause, measured rather than inferred: `query.count`, `element(boundBy:)` and
`allElementsBoundByIndex` each resolve **one element per accessibility round trip** — 0.29-0.32 s
each on this host (`build/logs/t34f-ipad-head.log`, indices 0-45 in one call;
`build/logs/t34q-run1.log`, 98 such queries in one 7-test run). The snapshot work is served on the
app's main thread, which is the thread the list's own layout/scroll-restore runs on.

Rule that follows: **ask the accessibility tree one question per snapshot, not one per element.**
`XCUIElement.snapshot()` returns the whole tree in a single round trip; walk it in the test
(`T34-ChannelPostListUITests.snapshotNodes`). Under that rule the same suite shows 0 per-element
queries (`grep -c 'Element at index' build/logs/t34q-final1.log` → 0) and two consecutive full-suite
runs without losing the process. When a run *does* lose the host, count it as one harness failure -
not as N test failures — and check the crash reports before believing the test names.

## 8. An assertion of a user-visible property does not pin the code that produces it (T34 anchor pin)

Third lesson, and the one that cost a green suite its meaning. `testLoadingOlderPostsDoesNotMoveTheAnchoredPost`
asserts "the anchored row keeps its y across a page insert". QA deleted the restore call and the test
**still passed** on this host (`docs/t34qa-build-note.md` §8 mutation A): on iOS 18+ the scroll view
preserves the reader's place for a prepend by itself, so the property held for a reason the test was not
about. The suite's claim was therefore "the list does not jump" — true and worth having — and not "the
restore works".

Rules that follow (implemented in `ScrollRestoreRunner` + `T34ScrollRestorePathTests` +
`T34ChannelViewRestoreWiringTests`, `docs/t34-anchor-pin.md`):

1. **If the OS (or any layer under test) can produce the asserted property on its own, the test needs a
   second signal that only the code path under test emits.** Here: `ScrollRestoreReport`, published on
   the model and read by the live test through `channelPostList.scrollRestore`. It names the post,
   counts frames and corrections, and states whether the layout settled. No report ⇒ no restore.
2. **Lift the logic out of the `View` so it can be driven without a window.** The loop takes a
   `ScrollRestoreSurface` (four closures) and a `pause` closure; the fake surface simulates the page
   insert, so the arithmetic, the sign, the single application and the un-laid-out fallback are
   millisecond tests instead of an 80 s simulator run.
3. **Pin the caller separately, in-process, with the real view.** `UIHostingController` + a
   `UIWindow` + the real `ChannelPostListView` + a `requestScrollRestore`: the anchor must be consumed
   and a report published. This is the level that actually catches the deleted call, in ~2 s.
4. **Mutate both levels and record which one catches what.** Mutation A (delete the call) fails the two
   hosted wiring tests and nothing else; mutation C (compute the correction, never apply it) fails the
   runner tests and nothing else. A pin nobody has seen fail is a guess; a pin whose red case is not
   written down is a story.
5. **Do not turn the report into the assertion.** The frame comparison stays: it is the user-visible
   property, and QA's mutation B (scroll the pane to the bottom on purpose) proves it can fail. The
   report answers "did our code run", the frame answers "is the reader where they were". A green run
   needs both.

## 9. Platform metrics: Catalyst's `UIFontMetrics` ignores the trait, `phys_footprint` does not measure retention, and unstructured `Task`s do not start in order (t_9f5de5d7)

The Mac lane (`scripts/qa-test.py --platform mac --only-testing MattermostTests`) compiles and runs
the whole 2526-case unit target; with `t_21b2f119` landed it finally reported a verdict instead of
`Executed 0 tests`, and three assertion failures were left over. All three were the *test* asserting a
platform metric, not product defects — but two of them had to be re-measured rather than relaxed,
because "the number is different on Catalyst" is true of a working test too.

**1. Dynamic Type cannot be synthesized through a trait on Catalyst.** A probe in
`MattermostTests` (deleted after the measurement) resolved `.body` four ways:

| call | iOS 18.5 sim | Mac Catalyst |
|---|---|---|
| `UIFont.preferredFont(forTextStyle: .body)` (ambient) | 17.0 | 17.0 |
| `UIFontMetrics(forTextStyle: .body).scaledFont(for:compatibleWith: AX5 traits)` | **48.0** | **17.0** |
| `UIFont.preferredFont(forTextStyle: .body, compatibleWith: AX5 traits)` | **53.0** | **17.0** |
| `UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: AX5 traits)` | **48.0** | **17.0** |

`UIWindowScene.traitCollection.preferredContentSizeCategory` is `.large` on both. So Catalyst ignores
an explicitly handed trait collection, and a Catalyst process has no way to ask for a larger text size
through one. The *product* is not affected: `ComposerView` assigns
`UIFont.preferredFont(forTextStyle: .body)` (ambient) and takes its limits from
`@Environment(\.dynamicTypeSize)` — the same ambient source — so a Mac at the default text size gets
17 pt and `.tablet` limits, with no split between font and box.

Rule: **a test that needs an accessibility text size must assign the font.** It may not rely on
`UIFontMetrics(scaledFont:compatibleWith:)` on Catalyst. `ComposerInputHeightTests
.testChangingTheLimitsReMeasuresTheSameText` now assigns the size the iOS run resolves and still
asserts growth; a mutant that makes `remeasure()` ignore the view's font fails it with
`78.0 is not greater than 78.0` on Catalyst.

Not validated: a Mac whose *Accessibility → Display → Text Size* is set larger (this host has
`FontSizeCategory.global = DEFAULT` in `com.apple.universalaccess`; a test run must not change a
user's accessibility setting). If Catalyst maps that setting into the trait collection at all, the
ambient paths above are the ones the composer already uses — unverified either way.

**2. "Is the payload held in memory" has two shapes, and no single counter sees both** (t_9f5de5d7,
reworked by t_822c89af). All numbers below are from this host on 2026-11-06: iOS 18.3 simulator
`81A7F251` (Xcode 26.6, iOS 26.5 SDK) and Mac Catalyst on the same tree outside TCC.

*The primitive*, with no `URLSession` anywhere — one 32 MB file, one retained `Data`
(`build/logs/t822-data-ios1.log`):

| retention | `phys_footprint` | `internal` | `external` | `resident` | `virtual_size` |
|---|---|---|---|---|---|
| `Data(contentsOf:)` | **+33.6 MB** | +33.6 MB | +32 KB | +33.6 MB | +33.6 MB |
| `Data(contentsOf:options: .mappedIfSafe)` | **0** | 0 | 0 | 0 | **+33.6 MB** |

So a *heap* retention is footprint, and a *mapped* retention is invisible to footprint, `internal`,
`external` and `resident` alike — it is address space only. Which one `Data(contentsOf:)` produces is
Foundation's choice, not the test's: on the 18.5 runtime the same mutant measured **+3.1 MB**
(t_9f5de5d7) while here on 18.3 it measures **+36.6 MB** (t822-case-ios-m-read.log). A guard built on
one shape silently passes the other.

*Peak sampling does not rescue it.* Sampling `TASK_VM_INFO.phys_footprint` every 0.5 ms through a
clean 32 MB chunked transfer peaks **47–62 MB** above the start (`build/logs/t822-probe-ios2.log`) —
CFNetwork's own scratch, i.e. above the payload the peak was supposed to bound. The kernel's own
`ledger_phys_footprint_peak`/`internal_peak` tell the same story (+65 MB of scratch).

*Catalyst's scratch is worse than a tolerance problem.* Six identical transfers in one process:
**+806 MB**, +0.85, 0, +1.6, **+98.8**, 0 (`build/logs/t822-probe-mac-clean6.log`). The bursts do not
go away after a warm-up, so no before/after or peak bound is assertable there on a working build.

What `T53MediaFootprintTests` asserts now:

1. **both platforms, exact**: all 32 MB are on disk, written by the app's own cache;
2. **both platforms, exact**: no VM region of this process is backed by a file in the cache
   directory (walk with `mach_vm_region_recurse` + `proc_regionfilename`; match on the directory's
   UUID name, because the kernel reports `/private/var/...` where `FileManager` says `/var/...`).
   This is the mapped shape, and it is the only memory claim Catalyst can carry;
3. **iOS only**: `phys_footprint` grew by less than the payload — the heap shape. Do not "fix" a
   Catalyst delta by widening the bound; it is noise, not a tolerance.

The falsifier is `scripts/t53_retention_mutant.py` (never committed to the tree; `apply`/`revert` a
six-line retention in `MediaFileCache`), and the case is required to fail on it:

| mutant | iOS 18.3 | Mac Catalyst |
|---|---|---|
| `read` — `Data(contentsOf:)` kept | **FAIL** footprint 36,553,024 | PASS — heap retention, no bound here |
| `heap` — byte copy kept | **FAIL** footprint 36,061,440 | PASS — same |
| `mapped` — `.mappedIfSafe` kept | **FAIL** region 33,554,432 (footprint only 1,966,144) | **FAIL** region 33,554,432 |

Clean runs for the same case: four fresh iOS processes at 1.05–2.75 MB of footprint with no mapped
region, and inside the whole 2526-case bundle 1.05 MB (iOS) / 37.6 MB (Catalyst, unasserted) — so the
iOS bound has a >10x margin on this host. It is still a *bound*, not an audit: retention of less than
a whole payload inside the window is not caught, and the comment in the case says so.

Not validated: the heap shape on Mac Catalyst (unmeasurable above); and the 18.5 runtime, which
today's build cannot run on this host at all — dyld aborts on the missing
`libswiftWebKit.dylib` before the test host connects (`build/logs/t822-probe-ios1.log`), so the 3.1 MB
reading in t_822c89af was not reproducible here and is carried as that card's measurement only.

**3. Two unstructured `Task`s do not start in creation order.** `T4fTypingTests
.testANewFrameRestartsTheWindowAndTheOldTimerCannotClearIt` sent two typing frames and then waited for
two parks on the gated clock, assuming park order == frame order. It is not: a probe of exactly that
shape (400 tasks) parked in reverse ~390 times out of 400 under load, and even **two** tasks parked in
reverse in **24 of 500 rounds** on an idle machine. `releaseOne()` then resumed the *newer* window,
whose expiry is legitimate, and the case failed with `nil != "Terry Buddy is typing..."` — the same
message a real product regression produces. The case now waits for the first park before sending the
second frame (`build/logs/t21b2-mac-unit-head2.log` was the observed flake).

Rule: **a gated-clock test must establish the order it is about, not assume it**: wait for the earlier
park before emitting the next event. The claim stays falsifiable — deleting the cancel check *and* the
generation guard still fails the reordered case with the original message.

**4. `MediaFileCache.existingFile(fileID:)` matches by prefix.** A file staged under id
`big-control` is returned for a later request for `big` (`hasPrefix(fileID + "-")`), so a "warm-up
then measure" version of the T53 case measured *nothing*: the second `stagedFile` short-circuited to
the control file, the disk assertion passed trivially and the delta was 0. Any test that stages twice
in one process needs ids where neither is a prefix of the other.
