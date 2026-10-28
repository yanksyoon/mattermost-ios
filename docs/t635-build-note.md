# T635 — the restored channel pane can paint zero rows, and the app process dies mid-batch

Card: `t_635046c9` (T37-R2 follow-up). Date: 2026-10-28.
Product tree measured: `origin/main` **5f55bf6**, whose product code is byte-identical to `2baddc6`
(`git diff --stat 2baddc6 HEAD` → `docs/t95a-av-build-note.md` only). Every build used below came from
a detached worktree at `2baddc6` (`~/.hermes/profiles/mmios-qa/cache/scratch/t95av/wt-t95a`), never from
the shared checkout, which had a concurrent worker editing `MattermostUITests/*` while this card ran
(steward note 02:05). No test source was edited by this card.

Fixture: Mattermost 9.11.19 (docker `mm-perf`) at `http://127.0.0.1:8065`, account `perfprobe`.
Devices: iPhone 16 Pro `81AD82E4` (iOS 18.3), iPhone 16 Pro `81A7F251` (iOS 18.3.1), iPhone 16 Pro
`3A3B41D0` (iOS 18.3). Host load 4.2–6.5 during the runs.

---

## Verdicts

| symptom | verdict | who owns the fix |
|---|---|---|
| **A** — a launch that restores a channel paints an empty post list | **REAL PRODUCT DEFECT**, reproduced **5/5 launches today** without XCTest (five `simctl` launches, screenshots at 12 s / 40 s / 85 s) | native shell (`mmios-ios`), card filed from this one |
| **B** — the app process disappears mid-batch | **NOT** host contention and **not** a harness kill: the app process **crashes with SIGSEGV** while XCTest snapshots the accessibility tree. 11 SIGSEGV exits in ~2.5 h of UI running, **0** SIGKILL, **0** jetsam kills | harness/simulator crash class already documented in `MattermostApp.swift:128-140`; the actionable half is capturing a stack + the app's accessibility runtime issues (card filed) |

Two things in the card body are corrected by measurement:

1. **The "persisted anchor" hypothesis for A is wrong.** Nothing persists a scroll anchor. The channel
   path has no `UserDefaults`/`@AppStorage` at all (`grep -rn "UserDefaults\|@AppStorage"
   Mattermost/UI/Native/Channel Mattermost/UI/Native/Sidebar` → no match), `ScrollAnchor` is
   in-memory only (`ChannelViewModel.requestScrollRestore`, `ChannelViewModel.swift:955`), and
   `mm.native.lastChannel` carries only `{serverID, teamID, teamName, channelID, channelName, openedAt}`
   (`LastChannelStore`, `NativeNavigation.swift:784-812`) — no post id, no offset. The restore that
   matters is the *initial scroll position of the list*, not a reader anchor.
2. **"No crash report" was a search artefact.** `~/Library/Logs/DiagnosticReports/` holds **29**
   `Mattermost-*.ips` reports (Oct 22 → Oct 27 15:25) — the newest predates the 21:33 batch runs, and
   sim crash reporting stops writing for these newer events, so the earlier searches were right about
   *those windows* and wrong about the conclusion: launchd records a crash signal for every one of them.

---

## A — the reproduction, with no XCTest in the loop

State needed: a signed-in server **with a saved last channel**. `81AD82E4` was left in that state by the
T37-R2 campaign; the current build was installed over it (`simctl install` keeps the data container and
keychain), and the installed `Mattermost.debug.dylib` was verified by sha256 to be the `2baddc6` build
(`555a7c36c2fef6bfc9c45608a612e8f7ddf908b924e38bfd276d83668e35709a`, the same file as
`~/Library/Developer/Xcode/DerivedData/t95av/Build/Products/Debug-iphonesimulator/Mattermost.app`).

```bash
UDID=81AD82E4-B711-45B7-A539-33D9E861A7A5
xcrun simctl install  $UDID ~/Library/Developer/Xcode/DerivedData/t95av/Build/Products/Debug-iphonesimulator/Mattermost.app
xcrun simctl terminate $UDID com.mattermost.ios
xcrun simctl launch $UDID com.mattermost.ios \
  -uiTestSeedServer http://127.0.0.1:8065 -uiTestSeedServerName "Local Mattermost" \
  -surfaceMode shell=native -surfaceMode auth=native -surfaceMode sidebar=native -surfaceMode composer=native \
  -AppleLanguages "(en)" -AppleLocale en_US
sleep 12;  xcrun simctl io $UDID screenshot 12s.png      # …and again at 40 s / 85 s
```

Note what is **absent**: `-uiTestResetPersistedState` (the launch must *restore*), and any XCTest
process. The helper is `build/logs/t635/manual-relaunch.sh` (gitignored).

### Measured

| launch | 12 s | 40 s | 85 s | screenshot |
|---|---|---|---|---|
| 1 | blank | blank | — | `build/logs/t635/manual/82E4cur-1-{12,40}s.png` |
| 2 | blank | blank | — | `…/82E4cur-2-{12,40}s.png` |
| 3 | blank | blank | — | `…/82E4cur-3-{12,40}s.png` |
| 4 | blank | blank | — | `…/82E4cur-4-{12,40}s.png` |
| 5 | — | — | blank | `…/82E4cur-5-85s.png` |
| (pre-reinstall build, same device) | blank | blank | — | `…/82E4-1-{12,40}s.png` |

"Blank" = the pane is on screen exactly as the T37-R2 screenshots show it: nav bar with `Back` and
`Local Mattermost`, pane header `# T36 Threads` with the calls and threads buttons, the composer
(`Message`, `+`, emoji, send), and **no row, no spinner, no error, no "No messages yet"** in the list
area. It never fills in — 85 s measured, matching the card's `manual-relaunch-85s.png`.

### Why this is the list's scroll position and not a failed fetch

`ChannelView.body` (`ChannelView.swift:78-92`) renders exactly four things:

| phase | what is drawn |
|---|---|
| `.idle`, `.loading` | spinner + "Loading messages…" (`loadingState`, `:502-512`) |
| `.failed(message)` | wifi icon + message + **Try again** (`failureState`, `:514-530`) |
| `.loaded`, `items.isEmpty` | "No messages yet" + body text (`emptyState`, `:532-…`) |
| `.loaded`, `items` non-empty | `list` |

None of the first three is on screen, so the pane is `.loaded` with a **non-empty** window: the rows
exist in `model.items` and only the viewport is wrong (a `LazyVStack` materialises nothing when the
scroll offset is outside the content, which is also why the accessibility tree shows `channelPostList`
with no `post.*` child — exactly what `t37r2-alone-b1.log` recorded at 33.39–35.74 s).

The title is the proof that the launch's network path worked: the saved record's `channelName` is the
slug **`t36-threads`**, the screen shows **`T36 Threads`**, which only `loadChannelHeader()` (an
authenticated `GET /channels/{id}`) can produce (`ChannelView.swift:1009-1032`, `ChannelPaneTitle`).
So the session was valid and the server answered at launch; the post page is not the thing that failed.

Ruled out:

* **not a fetch failure** — `.failed` would have drawn the retry card (above);
* **not an empty channel page** — the fixture's newest page is 60 posts, all top-level:
  `scripts`-style probe `~/.hermes/profiles/mmios-qa/cache/scratch/t635/t36_page_probe.py` →
  `first page … top-level (root_id empty): 60, replies: 0` for `t36-threads`
  (`psw97y5zqpfnpembwxraizuije`, `total_msg_count 544`); also, an all-replies page would have landed in
  `emptyState` ("No messages yet"), which is not what the screen shows;
* **not `-uiTestResetPersistedState` wiping state** — the flag is not passed and the app is demonstrably
  restoring (`Back` + a pushed pane + the saved channel);
* **not the dead window of a previous process** — 5 launches, 5 different pids, same screen.

What is left, and what the follow-up card has to pin with instrumentation (the app logs nothing here):
the **initial scroll offset**. The list is built with `InitialBottomAnchor`
(`defaultScrollAnchor(.bottom, for: .initialOffset)` on iOS 18, `ChannelView.swift:932-941`) plus a
`pinToBottom()` loop that runs when `items.count` goes 0 → n (`:219-225`); both are computed against a
`contentHeight` that is measured while the lazy rows are still arriving
(`ChannelScrollController.scrollToBottom`, `ChannelScrollPosition.swift:205`). A first-page publish that lands
between the two — or an iOS 18 `initialOffset` resolution taken before the rows have heights — leaves the
offset outside a multi-page content, which is the state the screenshots show. This card does not claim
which of the two; it claims the pane is `.loaded` and non-empty, so the defect is in the pane's
*positioning*, and it is reproducible with no XCTest in the loop.

### What was not achieved for A

* **No A/B by deleting `mm.native.lastChannel`.** Editing the container plist from the host does not
  reach the app: `cfprefsd` keeps the value and the app rewrites the record (`openedAt` moved from
  `07:08:46` to `07:11:02` after a "deleted" key). The delete must go through the app
  (`-uiTestResetPersistedState`) or through `cfprefsd`.
* **No tap** — `simctl` has no touch input and `idb` is not installed on this host, so "Back to an empty
  sidebar list" (part of the card's report) was not re-measured here.

---

## B — the process does not "go away", it crashes

`launchd_sim` records every app exit with its reason. Three windows, still retained in the simulator
unified log (`.hermes/…/t635/exits-*.txt`):

| device | window (local) | SIGSEGV | SIGKILL | SIGTERM by `xcodebuild` (normal teardown) | exit(0)/exit(1) |
|---|---|---|---|---|---|
| `81A7F251` | 01:00–01:52 (`t95av-live-t39-shell-2` + `t635-recents-1`) | **1** | 0 | 12 | 3 / 2 |
| `81AD82E4` | 21:15–22:45 (T37-R2 campaign) | **6** | 0 | 58 | 0 |
| `3A3B41D0` | 21:15–22:45 (T37-R2 campaign) | **4** | 0 | 38 | 0 |
| **total** | ~2.5 h of UI running | **11** | **0** | 108 | 5 |

No jetsam, no memory-pressure kill, no `SIGKILL` from the runner or from the host in any window.

The red in `t95av-live-t39-shell-2` is one of them, with its full context:

```
2026-10-28 01:35:17.665 launchd_sim  [user/501/UIKitApplication:com.mattermost.ios[cb14] [58764]:]
    exited due to SIGSEGV | sent by exc handler[58764], ran for 14114ms
2026-10-28 01:35:17.667 runningboardd  termination reported by launchd (2, 11, 11)
2026-10-28 01:35:23.122 ReportCrash     loadStoreInfo [platform 7] com.mattermost.ios …
```

and the app's own last log lines (14 ms before) are XCTest's accessibility serialiser running **inside
the app process**:

```
2026-10-28 01:35:17.651 Mattermost[58764] [com.apple.dt.xctest:Default] StaticText, label: 'Local
    Mattermost' (AX element pid: 58764, elementOrHash.elementID: …) faulted in { …
```

The archived reports for this process say what that costs when it goes wrong. Two of the 29
`Mattermost-*.ips` in `~/Library/Logs/DiagnosticReports` carry the exact signature:

```
Mattermost-2026-10-26-195654.ips / -200837.ips
  exception: EXC_BAD_ACCESS, SIGSEGV, KERN_INVALID_ADDRESS at 0x0000000000000000
  faultingThread 0 (com.apple.main-thread)
    _platform_strcmp
    XCTAutomationSupport   runtime_issue_os_log_fault_callback
    libsystem_trace        _os_log_invoke_callback → _os_log_impl_flatten_and_send
    libsystem_trace        __LIBTRACE_CLIENT_QUARANTINED_DUE_TO_HIGH_LOGGING_VOLUME__
    UIAccessibility        _copyMultipleAttributeValuesCallback
    AXRuntime              _AXXMIGCopyMultipleAttributeValues
```

That is the class `MattermostApp.swift:128-140` already documents ("XCTest's own snapshot callback
dereferences a NULL and the test process dies mid-suite … `_platform_strcmp` under
`runtime_issue_os_log_fault_callback`"), and the reason the `-uiTestLogLevel` launch seam exists. Its
mitigation lowers `os_log` volume but does not remove the trigger: the app's accessibility *runtime
issues* are still logged as faults while a snapshot is being taken.

Consequences for how this card's symptom B is characterised:

* it is **an app-process crash under XCUITest's accessibility snapshotting**, not contention on a shared
  simulator and not a scheduler/host kill. The victim rotating across tests is what a snapshot-time
  crash looks like (whichever test is snapshotting when the 60 s quarantine window fills dies);
* it is **not** "the app process vanishes without a crash report" — a crash *signal* is recorded every
  time; what is missing is the `.ips`. Simulator crash-report writing stops after **2026-10-27 15:25**
  on this host (`ls -lt ~/Library/Logs/DiagnosticReports/Mattermost*.ips`), and `ReportCrash` still runs
  (`loadStoreInfo … com.mattermost.ios`, `is not a MetricKit client`) without leaving a file. That is a
  diagnostics gap on the host, and it is why an archived stack has to be borrowed from Oct 26;
* the batch runs also lose the **runner** separately — `t635-recents-1` (this card, 01:58–02:00) went
  `Restarting after unexpected exit, crash, or test timeout` at 01:59:17 with the app's exits all
  legitimate `SIGTERM … sent by xcodebuild`; the runner's own exit was not recorded by `launchd_sim`
  (only the replacement runner's `exit(0), ran for 1025ms` is). So "the app process vanished" in a
  `xcodebuild` log can also mean "the test process vanished", and the two need different stacks.

### `docs/t95a-build-note.md` §3 (F4) — is that red this one?

**No.** That run recorded the sign-in surface with the **same pid** in the launch and failure snapshots
(88629, quoted in §3) and no signal/exit — an app that crashed cannot keep its pid. It is a `.signedOut`
re-entry with the process alive (`AuthCoordinator.restore` → `setPhase(.signedOut)`, no
`sessionExpiredBanner`), i.e. a suite/launch-path problem of its own kind, not symptom B. It did not
reproduce in the five manual launches measured here. It still has no owner of record: `t_a1842f6c`
(T95-B) does not mention it.

---

## What is still unvalidated (stated, not papered over)

* **The exact scroll-offset cause for A.** This card proves the state (`.loaded`, non-empty window,
  nothing materialised, 5/5 launches) and the repro; pinning `contentOffset` vs `contentSize` at first
  layout needs instrumentation the app does not have today (no log line in the channel path).
* **Real device + APNs** — not involved anywhere here.
* **Taps.** "Back to an empty sidebar list" and "does re-opening the channel fix it" need touch input;
  `simctl` has none and `idb` is not installed on this host.
* **The 7 original batch losses cannot all be re-classified.** The simulator unified log has rotated
  past them (queries before 21:15 on `81AD82E4` and before 01:00 on `81A7F251` return nothing); the 11
  events in the table above are what is still retained, and they are all the same class.
* **Whether a VoiceOver user hits the crasher.** The crash needs an accessibility client hammering the
  tree; a real device with VoiceOver is the only way to know, and there is no real device here.

## Artifacts (all gitignored except this note)

* `build/logs/t635/manual/82E4cur-1…5-*.png` — the five blank launches (12 s / 40 s / 85 s).
* `build/logs/t635/t635-recents-1.log` — the runner-restart run (not a product assertion failure).
* `~/.hermes/profiles/mmios-qa/cache/scratch/t635/` — `exits-*.txt` (launchd exit tables),
  `simlog-0135.txt` (the 01:35 crash window), `t36-page-probe.txt`, `classify_exits.py`,
  `t36_page_probe.py`, `manual-relaunch.sh` copy.
