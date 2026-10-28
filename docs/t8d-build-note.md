# T8d — the app-loss is a SIGSEGV at the firehose quarantine; the trigger is the accessibility serialiser's log volume, not our a11y defects

Card: `t_8d033037` (QA's `t_635046c9` §B, `docs/t635-build-note.md`). Baseline tree `0aeb82a`
(T95-B). Host: `MacBook-Pro-6.local`, Xcode 26.6 (17F113), iOS 18.3.1 sim `81A7F251`.

This note answers the card's four acceptance criteria in order, then lists what is still open.
Everything below is measured on this host today; where a number was not obtained it says so.

---

## Verdicts, up front

1. **The crash is in the app process and it is instantaneous at the quarantine.** A current
   `.ips` (2026-10-28 03:27:31) has the full stack the card asked for, and the same pid's log
   says `QUARANTINED DUE TO HIGH LOGGING VOLUME` **1.5 ms** before `exited due to SIGSEGV`. §1.
2. **The trigger is log volume, and the volume is XCUITest's accessibility serialiser running
   inside the app process** — 84 % of 184.9 MB of app log in five minutes — **not** the app's
   `Logger` (0.1 %) and **not** the app's accessibility *runtime issues* (0.1 MB, and they are a
   SwiftUI↔XCTest element-type disagreement, not a VoiceOver defect). The card's premise for
   gap 2 is falsified; what actually has to be cut is snapshot volume. §2.
3. **A VoiceOver user cannot hit this crash** — the faulting frame is XCTest's callback in
   `XCTAutomationSupport`, which is only loaded into the app when the test daemon bootstraps it;
   all 17 SIGSEGV reports have it loaded, no other report class does. §3.
4. **The batch app-loss did not recur in the A/B** — 2 quarantine events in the baseline batch,
   0 in the fixed batch, 0 SIGSEGV in both — but the crash needs a heavier run to reproduce at
   all, so that is "the trigger is cut on these paths", not "the class is gone". §5.

---

## 1. AC1 — the faulting stack of a current crash, and the command that produced it

### 1.1 The report

`~/Library/Logs/DiagnosticReports/Mattermost-2026-10-28-032731.ips` — captured **today**, and it
contradicts `docs/t635-build-note.md` §B's "no `.ips` is written for the newer crashes": one was
written at 03:27 and none since, so the reporting gap is **intermittent**, not closed (see §1.4).

Read with (`build/logs/t8d/ips.py` in this tree is a copy of the reader used):

```
python3 build/logs/t8d/ips.py ~/Library/Logs/DiagnosticReports/Mattermost-2026-10-28-032731.ips
```

```
proc: Mattermost  pid 30256  captureTime 2026-10-28 03:27:10.5574 -0500
exception: EXC_BAD_ACCESS, SIGSEGV, KERN_INVALID_ADDRESS at 0x0
termination: SIGNAL 11, byProc "exc handler", byPid 30256
faultingThread 0 (com.apple.main-thread), triggered
  _platform_strcmp                                  +64
  XCTAutomationSupport   runtime_issue_os_log_fault_callback          +104
  libsystem_trace        _os_log_invoke_callback                       +200
  libsystem_trace        _os_log_impl_flatten_and_send                 +7540
  libsystem_trace        _os_log                                     +164
  libsystem_trace        _os_log_fault_impl                            +20
  libsystem_trace        __LIBTRACE_CLIENT_QUARANTINED_DUE_TO_HIGH_LOGGING_VOLUME__  +100
  libdispatch            firehose_client_start_quarantine              +52
  libdispatch            firehose_buffer_stream_chunk_install        +1032
  libdispatch            voucher_activity_trace_v_2                  +1104
  libsystem_trace        _os_log_impl_flatten_and_send                 +7144
  libsystem_trace        _os_log                                     +164
  libsystem_trace        _os_log_impl                                  +20
  XCTAutomationSupport   -[XCElementSnapshot _fetchSimpleValueForKey:]  +588
  XCTAutomationSupport   -[XCElementSnapshot children]                 +116
  XCTAutomationSupport   -[XCTElementSnapshotDescendantsEnumerator nextObject]
  XCTAutomationSupport   -[XCTFilteringTransformerIterator nextMatch]
  XCTAutomationSupport   -[XCTElementQuery _firstMatchingSnapshotForInput:…]
  XCTAutomationSupport   +[XCTRuntimeIssueContext captureIssuesWithContext:inScope:]
  CoreFoundation         __CFRUNLOOP_IS_CALLING_OUT_TO_A_BLOCK__
  UIKitCore              -[UIApplication _run] → UIApplicationMain
  SwiftUI                runApp<A>(_:) → static App.main()
  Mattermost.debug.dylib static MattermostApp.$main() +40
```

This is the same class the two Oct-26 reports carry, and it is **new information** in two respects:

* the app was **already quarantined** when `-[XCElementSnapshot _fetchSimpleValueForKey:]`
  called `_os_log_impl` — an *ordinary* `os_log`, not a fault. Any `os_log` taken while a
  snapshot is in flight is enough; our logging level is irrelevant to it;
* `+[XCTRuntimeIssueContext captureIssuesWithContext:inScope:]` is on the stack: XCTest is
  capturing runtime issues *during* the query, i.e. the crash happens in the code path the card
  points at, but it is entered by the snapshot, not by an issue being found.

### 1.2 The same pid, 1.5 ms apart, in the simulator's own log

```
xcrun simctl spawn 81A7F251-8B31-4945-8783-5A264C14B8D5 log show \
  --start '2026-10-28 03:27:09' --end '2026-10-28 03:27:20' \
  --predicate 'process == "launchd_sim"' --style syslog | grep -E 'SIGSEGV|exited'
```

```
2026-10-28 03:27:10.481876  Mattermost[30256]: (libsystem_trace.dylib) QUARANTINED DUE TO HIGH LOGGING VOLUME
2026-10-28 03:27:10.483393  launchd_sim: … com.mattermost.ios[611b] [30256] exited due to SIGSEGV |
                                          sent by exc handler[30256], ran for 43230ms
```

Saved: `build/logs/t8d/simlog-0327-crash-window.txt`, `build/logs/t8d/ips-032731-stack.txt`.
**Quarantine → SIGSEGV in 1.5 ms, same pid.** The quarantine entry itself is the log call that
walks into XCTest's fault callback and dereferences the NULL — there is no 20-second window to
catch, which is why an `lldb` breakpoint on `runtime_issue_os_log_fault_callback` is not needed to
get a stack: the crash report has it.

### 1.3 What the app was doing

The pid logged **20.6 MB in the 45 s before it died** (12.3 MB in the last full minute, peak
2.4 MB in a single second, `build/logs/t8d/pid30256.log`), serving
`Elements matching predicate '"channelSidebar.channel.…" IN identifiers'` queries — T33's sidebar
poll. Rate is what trips the quarantine; 200 KB/s average with 2 MB/s bursts is enough.

### 1.4 The reporting gap, measured

| run | quarantine | SIGSEGV | `.ips` written |
|---|---|---|---|
| `t33` run at 03:27 (pid 30256) | 03:27:10.481876 | 03:27:10.483393 | **yes** (03:27:31) |
| `t8d-base-A` (pid 2715) | 05:30:30.886659 | none | no |
| `t8d-fix-B` | see §5 | see §5 | — |

So `ReportCrash` writing a file is intermittent on this host. The **reliable** record is
`launchd_sim` + the `QUARANTINED` line, both greppable per run:

```
xcrun simctl spawn <udid> log show --start … --end … \
  --predicate 'eventMessage CONTAINS "QUARANTINED DUE TO HIGH LOGGING"' --style syslog
```

---

## 2. AC1/AC2 gap 2 — why the fault path is entered at all (it is not the a11y issues)

### 2.1 Volume, attributed

`xcrun simctl spawn 81A7F251… log show --start '03:24' --end '03:29' --predicate 'process == "Mattermost"' --info --debug --style syslog`
(`build/logs/t8d/log-0324-0329.txt`, 1,549,101 lines):

| subsystem | bytes | share |
|---|---|---|
| `com.apple.dt.xctest` (`XCTAutomationSupport`, inside the app process) | **154.84 MB** | **84 %** |
| continuation lines of the same records | 27.30 MB | 15 % |
| UIKit keyboard / event dispatch / CFNetwork / WebKit (all together) | ~3.5 MB | 2 % |
| **our `Logger` (`com.mattermost.ios`)** | **216 lines ≈ 0.05 MB** | **0.03 %** |

Same measurement for the baseline batch (`t8d-base-A`, 05:26–05:35): **79.5 MB** total, 78 % of it
`com.apple.dt.xctest`. `Logger` does not appear in the top 12 subsystems of either window.

XCTest fetches ~10 accessibility attributes per element it visits and logs **three lines per
fetch** (`Fetching AX attributes …`, `Got attributes, transferring to dictionary for return.`,
`AX element … faulted in { … } for <attribute>`). Measured cost:

| query shape (same screen) | queries | per query |
|---|---|---|
| `descendants(matching: .any).matching(identifier:)` — e.g. `nativeChannelPane` | 32 | **1.08 MB** |
| `descendants(matching: .any)` + `identifier BEGINSWITH 'channelSidebar.channel.'` | 117 | **1.05 MB** |
| `otherElements[…]`/`tabBars`/`textFields` — type-scoped | 46 | **0.09–0.19 MB** |

329 queries in five minutes, median 274 KB and 54 elements, worst 1.5 MB and 249 elements
(`build/logs/t8d/qcost.py`). One `app.debugDescription` of the drawn shell is a 250-element tree.

**Conclusion for the card:** the app's own logging is a rounding error, and the `-uiTestLogLevel`
seam cannot move this number. The volume is produced by (a) how big the accessibility tree is and
(b) how often the suites walk all of it. Both are addressable; neither is "turn logging off".

### 2.2 The "accessibility runtime issues" are one class, and it is not ours

From the run's `.xcresult` (`xcrun xcresulttool export diagnostics`, §3.1), the app's stderr/stdout
archive contains **370** occurrences of **one** runtime issue, and nothing else:

```
Automation type mismatch; legacy system derived element type 9 from class
SwiftUI.AccessibilityNode:UIResponder, traits 1108101562369,
but AXAutomationType returned 14 which maps to 14
```

Type 9 is `button` (derived from the button trait, bit 0 of that traits value), type 14 is
`popUpButton`. These are SwiftUI `Menu`s — the app has five (`grep -rn "Menu {" Mattermost/`,
one of them on the composer path, `ComposerView.swift:304`). It is logged at **Default** level, not
as a fault (0.1 MB of 79.5 MB), and it is **not a VoiceOver defect**: VoiceOver reads a menu as a
menu. There is no app-side fix short of replacing `Menu` with a non-menu control, which would be a
UX change made to satisfy the test harness. Recorded as *known, not actioned* (§6, card).

### 2.3 The real accessibility defects on the pane/list/composer paths

Not reported by XCTest — they are visible in the serialised tree instead, as `Image` elements whose
label is an SF Symbol name (`build/logs/t8d/.../StandardOutputAndStandardError-com.mattermost.ios.txt`):

| element as it appears in the serialised tree | occurrences in run A's dumps | VoiceOver says |
|---|---|---|
| `Image, identifier: 'number', label: 'number'` | 518 | "number" (channel glyph) |
| `Image, label: 'person.badge.key'` | 49 | "person badge key" |
| `Image, label: 'server.rack'` | 45 | "server rack" |
| `Image, label: 'person.3'` | 44 | "person three" |
| `Image, label: 'exclamationmark.magnifyingglass'` | 2 | "exclamationmark magnifyingglass" |

(counts are appearances across the batch's snapshots, not distinct views — the same glyph is
re-serialised on every query; what matters is that it is a separate accessibility element at all)

Fixed in this card (each also removes one element from every snapshot, i.e. ~6 KB of test log per
query):

| file | change |
|---|---|
| `Mattermost/UI/Native/NativePanePlaceholders.swift` | `row(_:systemImage:)` glyph and `NativePaneNote` glyph → `.accessibilityHidden(true)` (the anchor row already did this and documents why) |
| `Mattermost/UI/Native/Composer/ComposerView.swift` | autocomplete suggestion glyph → `.accessibilityHidden(true)` (the row is a labelled button; the symbol name was leaking into its reading) |
| `Mattermost/UI/Native/Channel/PostRowView.swift` | thread-reply `chevron.right` → `.accessibilityHidden(true)` |

Not fixed here, same class, outside the three paths the card names (grep list for the follow-up
card): `UI/Native/Search/SearchView.swift`, `UI/Native/Activity`, `UI/Native/ChannelInfo` (uses
`Label(_:systemImage:)`, which is fine), `UI/Native/Thread`, `UI/Native/Files`.

### 2.4 Where the volume was cut

| file | change | why |
|---|---|---|
| `MattermostUITests/ShellSettle.swift` | `waitForSignedIn` now uses `app.otherElements[…]` (typed) for `nativeShell`/`nativeChannelPane` and polls at 0.5 s instead of 0.25 s | it is the gate before every test in eight suites; ~10× cheaper per look, ~4× fewer looks |
| `MattermostUITests/T95ShellLayoutUITests.swift` | the launch-window sampler (`firstMoment`, every 0.1 s for the whole window — the single heaviest thing in the batch at 34.5 MB) and every `nativeShell`/`nativeChannelPane` lookup use the same typed query; `nativeChannelTitle` uses `app.staticTexts` | 32 × 1.08 MB → 32 × ~0.1 MB without changing the window's 0.1 s resolution or any assertion |
| `Mattermost/MattermostApp.swift` | the `-uiTestLogLevel` comment now states the measured facts: the crash kills **the app**, not "the test process", and this seam covers 0.03 % of the volume | the old comment is what let the class be read as "test-process noise" for two weeks |

Element types were not guessed: `nativeChannelPane`, `nativeShell` → `Other`; `nativeChannelTitle`,
`searchSummary` → `StaticText`; `searchField` → `TextField`; `searchSubmit`, `searchResult.*`,
`pinnedPosts.row.*` → `Button`, all read off the tree in `t8d-base-A`'s diagnostics.

---

## 3. AC3 — can a **user** (VoiceOver, no XCTest) hit this crash?

**No, and the reason is structural: the NULL dereference is in XCTest's code, not in ours.**

1. The faulting frame is `runtime_issue_os_log_fault_callback`, a function inside
   `XCTAutomationSupport.framework`. That framework is **loaded into the app by the test daemon**,
   which the app's own log shows at every test launch:
   `XCTTargetBootstrap … Attempting to load …/XCTAutomationSupport.framework` followed by
   `Received request to exchange capabilities … "query runtime issue reporting" = 1`.
   Without a test run there is no bootstrap, no framework, and no callback registered with
   `libsystem_trace` — so the quarantine fault has no callback to walk into.
2. Every crash report that carries this signature has `XCTAutomationSupport` in `usedImages`:
   **17/17 SIGSEGV**; the reports without it are all a different class (5 dyld `SIGABRT`,
   7 `SIGTRAP` Swift assertions, `build/logs/t8d/…`, script `…/xt.py`). There is no SIGSEGV in the
   archive that lacks it.
3. A VoiceOver user *does* reach the other frame in the October stacks
   (`UIAccessibility _copyMultipleAttributeValuesCallback` ← `AXRuntime
   _AXXMIGCopyMultipleAttributeValues`): VoiceOver is an accessibility client and drives the same
   MIG entry. What it does **not** have is XCTest's `os_log` callback. Being quarantined is also
   not itself fatal — the quarantine was reached here 22 times in six hours on this device and
   only the runs that then took a snapshot *with the callback installed* died.

**What is not answered on this host, stated plainly:** whether a VoiceOver user's query pattern
could drive the app over the firehose quarantine at all, and what a quarantined-but-not-crashed app
looks like to them (dropped log lines, no crash). That needs a real device with VoiceOver; there is
no real device here, and the iOS simulator has no VoiceOver.

### 3.4 The same check, run: a manual launch never loads the framework

```
xcrun simctl terminate 81A7F251… com.mattermost.ios
xcrun simctl launch    81A7F251… com.mattermost.ios        # pid 14781, 05:51:17
xcrun simctl spawn 81A7F251… log show --start '05:51:15' --end '05:51:45' \
  --predicate 'process == "Mattermost"' --info --debug --style syslog
```

The app's only XCTest lines in that launch are the bootstrap **declining** (`build/logs/t8d/manual-launch.log`):

```
(XCTTargetBootstrap) Registering for test daemon availability notify post.
(XCTTargetBootstrap) notify_get_state check indicated test daemon not ready.   ×3
```

— no `Attempting to load …/XCTAutomationSupport.framework`, no capability exchange, hence no
runtime-issue callback and no crash path. And the volume that trips quarantine is not there either:
**0.1 MB in 25 s (4 KB/s)** against **300–420 KB/s** under XCUITest (75–100×).

---

## 4. AC2 at a glance

| the card asks | where it is answered |
|---|---|
| enumerate the app's accessibility runtime issues from an `.xcresult` | §2.2 — 370 occurrences of one class, from `xcrun xcresulttool export diagnostics` and the app's 61.9 MB stderr/stdout archive inside it |
| fix the ones on the channel-pane / sidebar / composer paths, or file them | §2.2 (the one class found: **no app-side fix**, recorded + card) and §2.3 (the defects XCTest does *not* report: decorative glyphs whose label is the SF Symbol name — **fixed** on those three paths, remainder filed as `t_ce08486d`) |
| evidence that the "trigger" is the a11y runtime issues | **it is not** — §2.1; the trigger is snapshot log volume, and the runtime issues are 0.1 % of it |

The card's framing ("they are VoiceOver-visible defects in our own views") is half right: there
**are** VoiceOver-visible defects in our views on those paths, but XCTest does not report them as
runtime issues — it reports a SwiftUI↔XCTest element-type disagreement that VoiceOver never sees.
Both halves are dealt with above.

---

## 5. AC4 — the batch A/B

Batch: `T95ShellLayoutUITests` (2 methods, 1 is an iPad-only skip) + `T39JumpUITests` (2) +
`T39SearchUITests` (4) = **8 tests**, not the 5 the card names — the suites grew with T95-A/T95-B.
Same device (`81A7F251`, iPhone 16 Pro, iOS 18.3.1), same derived data, same command:

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=… \
python3 scripts/qa-test.py --platform ios --sim id=81A7F251-8B31-4945-8783-5A264C14B8D5 \
  --derived-data ~/Library/Developer/Xcode/DerivedData/mmios-t8d --log-dir build/logs/t8d \
  --label t8d-base-A --timeout 2400 \
  --only-testing MattermostUITests/T95ShellLayoutUITests \
  --only-testing MattermostUITests/T39JumpUITests \
  --only-testing MattermostUITests/T39SearchUITests \
  -- -clonedSourcePackagesDirPath ~/Library/Developer/Xcode/DerivedData/mmios-t95b/SourcePackages
```

| | A — `0aeb82a` (before) | B — pane/ShellSettle/a11y only | B2 — all of the above + T39 typed lookups |
|---|---|---|---|
| result | 8 executed, **1 failed**, 1 skipped | 8 executed, 0 failed, 1 skipped | 8 executed, **0 failed**, 1 skipped (`** TEST SUCCEEDED **`) |
| log | `build/logs/t8d/t8d-base-A.log` | `build/logs/t8d/t8d-fix-B.log` | `build/logs/t8d/t8d-fix-B2.log` |
| test time | 188.6 s | 173.0 s | 176.1 s |
| app log volume (all app pids) | **79.5 MB** (421 KB/s) | 59.2 MB (342 KB/s) | **52.6 MB** (299 KB/s) |
| worst single app process | **30.7 MB** — quarantined | 11.8 MB | **11.8 MB** |
| quarantine events | **1** (05:30:30, pid 2715, during `T95ShellLayout`) | **0** | **0** |
| SIGSEGV | 0 | 0 | 0 |
| heaviest single query | `nativeChannelPane`, any-type, ×32 = **34.5 MB** (1.08 MB each) | same identifier, `otherElements`, ×111 = 5.5 MB (**47 KB each**) | same |

The one A failure is the app-loss, not an assertion about the shell: `T95ShellLayoutUITests.swift:144`
("the tab bar must still be on screen at the end of the launch window") is what a dead app looks
like, and XCTest logs `Checking for crash reports corresponding to unexpected termination of
com.mattermost.ios` straight after it. That is the card's symptom, reproduced on today's `main`.
It did not recur in either after-run, and this test now costs ~23× less app log per look.

**How far to trust that.** The batch reproduces the app-loss when a process crosses the quarantine
threshold, which on this host means ~30 MB in one process within a minute (A). The after-runs peaked
at 11.8 MB and were never quarantined, so *this* batch no longer reaches the trigger — but 52.6 MB
of the remaining 299 KB/s is still XCTest logging our ~250-element tree, and the queries that cost
the most now are ones this card does not own:

| remaining cost in B2 | queries | MB | owner |
|---|---|---|---|
| XCTest's own `identifier == "NotificationShortLookView" OR elementType == 7` poll | 65 | 7.5 | XCTest, not ours |
| `channelSidebar.channel.<id>` any-type (T33's suite, not in this batch) | 12 | 12.4 | T33 suite |
| `pinnedPosts.row.*`, `searchResult.*`, `teamSidebar.team.*` single lookups | 15 | 7.1 | T39Search / T33 suites |
| `nativeChannelPane` typed sampler (the fix in this card) | 111 | 5.3 | fixed here |

So the honest claim is **"the trigger is cut on the paths this card measured; the class is reduced,
not proven gone."** A whole-suite run (121 UI tests, 70 min) will still accumulate, and the largest
remaining lever is the accessibility tree size (~250 elements), which needs row combining on the
sidebar/list paths — a change that moves identifiers and therefore belongs to a parity-visible card,
not to a crash card (filed, §6).

Unit net after these changes (`t8d-units`, same command with `--only-testing MattermostTests`):
**1725 run, 8 skipped, 0 failed** — the four `.accessibilityHidden(true)` additions and the
comment rewrite changed no unit assertion (`build/logs/t8d/t8d-units.log`).

---

## 6. Open / filed elsewhere

* **`t_ce08486d`** (mmios-architect) — the a11y/volume follow-up: the drawn shell is ~250
  accessibility elements and each one costs ~6 KB of test log per snapshot; decide the identifier
  semantics for combining sidebar/list rows into one element each (and finish the decorative-glyph
  sweep in `Search`, `Activity`, `Thread`, `Files`). That is the remaining lever; it moves
  identifiers, which is why it is a parity-visible card and not this one.
* **The `Menu` automation-type mismatch (370 occurrences)** is recorded in §2.2 as *known, no
  action*: it is XCTest's legacy element-type derivation disagreeing with SwiftUI, logged at Default
  level, 0.1 MB of 79.5 MB, not a VoiceOver defect. Same card carries the note so it is not
  rediscovered as a bug.
* **The reporting gap is intermittent, not closed** (§1.4). One `.ips` appeared at 03:27, none for
  the 05:30 quarantine. Use `launchd_sim` + the `QUARANTINED` line as the record of a run, not the
  presence of a crash file.
* **`docs/t95a-build-note.md` §3's "fell back to the sign-in surface"** stays out of this card, as
  the card says: same pid, no signal. If it needs an owner it is a suite card (T95-B `t_a1842f6c`),
  and T95-B's own note does not mention it — it is still unowned.
* **Not measured here:** a whole-suite (121 UI test / 70 min) run after these changes — the class is
  reduced on the batch, not proven gone; and any real-device/VoiceOver behaviour (§3).

## Artifacts (gitignored except this note)

* `build/logs/t8d/ips-032731-stack.txt` — the faulting stack above, as text.
* `build/logs/t8d/simlog-0327-crash-window.txt` — quarantine → SIGSEGV, same pid.
* `build/logs/t8d/log-0324-0329.txt` (184.9 MB, 1.55 M lines) — the volume measurement window.
* `build/logs/t8d/runA-app.log` — the baseline batch's app log slice.
* `build/logs/t8d/t8d-base-A.log`, `t8d-fix-B.log` — the two batch runs.
* `build/logs/t8d/diag-A/` — the exported `.xcresult` diagnostics (incl. the 61.9 MB app
  stdout/stderr archive the runtime issues and the tree types were read from).
* Reader scripts (copies): `build/logs/t8d/ips.py`, `…/vol.py`, `…/qcost.py`, `…/qbypred.py`,
  `…/rate.py`, `…/xt.py`.
