# T38 whole class: why one test dies per run, and what makes it stop

Card `t_8d093748` (found while adding T38's zoom + share cases; **not** a regression from those cases,
which pass in isolation 8/8 — see `docs/parity/module-scan.tsv`, `files-attachments / zoom-and-share-an-image`).

## 0. Verdict

**Not the host, not an app memory limit: the app process is crashing inside the XCTest automation code
that runs inside it, and the trigger is the log volume that same code produces.** Running the whole
`T38AttachmentsUITests` class (6 cases) on this host with **one** booted simulator lost one test in
**2 of 2** runs, so host pressure is not the cause. The doomed process dies of a fatal signal (the
kernel logs a crash corpse and ReportCrash formulates a fatal report — no jetsam kill), at a
per-launch RSS plateau of 383–407 MB that is identical to the documented bounded plateau in
`docs/t38-build-note.md` §3.1 and does not grow across launches. What it *was* doing at that instant
is logging: 1,139,035 lines / 161 MB in 346 s, of which **639,217 lines are the
`com.apple.dt.xctest` subsystem and 539 lines are the app's own `Logger` (0.05 %)**. The last line the
process emitted, captured live, is

```
2026-11-06 03:58:47.442 F Mattermost[70974:595b4e] (libsystem_trace.dylib) QUARANTINED DUE TO HIGH LOGGING VOLUME
```

one millisecond before the kernel's `AMFI: Denying core dump for pid 70974 (Mattermost)` +
`Mattermost[70974] Corpse allowed 1 of 5`. Turning that one subsystem's logging off **in the
simulator** (`log config`, no code change) takes the same class to **6/6 in 337 s** with 47,032 log
lines instead of 1,139,035.

## 1. Runs

All runs: `/Users/yangsooyoon/Documents/yanks/code/mattermost-ios`, iPhone 16 Pro / iOS 18.3,
sim `81A7F251-8B31-4945-8783-5A264C14B8D5`, **only that simulator booted**, fixture
`scripts/t38_attachment_seed.py` already seeded (mm-perf 9.11.19 at 127.0.0.1:8065).

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
python3 scripts/qa-test.py --platform ios --sim "id=81A7F251-8B31-4945-8783-5A264C14B8D5" \
  --only-testing "MattermostUITests/T38AttachmentsUITests" --label <label>
```

| # | label | xctest log subsystem | result | wall | victim |
|---|---|---|---|---|---|
| 1 | `t38-repro-1` | default | **6 run, 1 failed** (rc 65) | 514 s | `testSavingAGalleryImageShowsItInTheDownloadsScreen` — app died at t=13.3 s, querying `channelSidebar.scroll` |
| 2 | `t38-repro-2` | default | **6 run, 1 failed** (rc 65) | 465 s | `testDoubleTapAndPinchZoomToTheCapAndTheSecondDoubleTapRestores` — "Lost connection to the application (pid 70974) / Couldn't communicate with a helper application", app died at t=50.2 s |
| 3 | `t38-repro-3-noaxlog` | `level:off` | **6 run, 0 failed** (rc 0) | 337 s | — |
| 4 | `t38-repro-4-noaxlog` | `level:off` | **6 run, 0 failed** (rc 0) | 336 s | — |

Host state during runs 1–2 (sampled 1 Hz, `scripts/t38_live_pressure_sample.py`): 10 cores,
load 5.5–34.5, free memory 30–66 %, one booted simulator, no other simulator or Mattermost process.
The earlier finding's "6 booted simulators, 16.7 GB RSS, 47 % free" was therefore *not* required.

## 2. The process crashed — it was not killed for memory

Both failing runs, from the unified log around the death:

```
kernel[0]  (AppleMobileFileIntegrity) AMFI: Denying core dump for pid <pid> (Mattermost)
kernel[0]  Mattermost[<pid>] Corpse allowed 1 of 5
ReportCrash  Parsing corpse data for pid <pid>
ReportCrash  Formulating fatal 309 report for corpse[<pid>] Mattermost
OSAnalytics  client log create type 309 result FAILED: Log limit exceeded
```

Two things follow.

1. A crash corpse exists, so the process died of a fatal signal. A jetsam kill leaves no corpse, and
   the host's `com.apple.xnu:memorystatus` stream — 1,163 records across the 34 minutes that covered all
   four class runs — contains **zero** mentions of the app and zero `jettisoned` records.

2. **The missing `.ips` files in the original finding are a reporting rate limit, not a silent kill.**
   `Log limit exceeded` is OSAnalytics refusing to write the report; it happened in *both* runs here.
   So "two of three runs left no crash report" was not evidence of jetsam — the reports were dropped.

Memory, sampled 1 Hz from outside (`ps` RSS; footprint per `docs/t38-build-note.md` §3.1's method):

| run | per-launch RSS peak | across the 6 launches |
|---|---|---|
| 1 | 386, 392, 404, 389, 383, 383 MB | flat |
| 2 | 383, 386, 386, 392, 407, 386 MB | flat |
| 3 (pass) | 395, 401, 385, 397, 370, 384 MB | flat |
| 4 (pass) | 390, 385, 421, 385, 432, 423 MB | flat |

Same plateau whether the class passes or dies — the two **passing** runs reached a higher peak
(432 MB) than the failing ones — and the documented physical footprint for this path is 144–152 MB
(§3.1): not a limit, and not reached by growth.


## 3. What it was doing when it died

Run 2, the app pid's own last twelve log lines (all `com.apple.dt.xctest`), 03:58:47.441–.442:

```
Fetching AX attributes XC_kAXXCAttributeValue for AX element pid: 70974, elementOrHash.elementID: …
Got attributes, transferring to dictionary for return.
Other, label: 'T38 attachments', value: 2 members (AX element … ) faulted …
… [First Match] no match found for transformer `Elements matching predicate '"attachmentGallery.page.m3xugfjpt…
Activity for state dumps
QUARANTINED DUE TO HIGH LOGGING VOLUME
```

The query is T38's own gallery-page seam (`attachmentGallery.page.<fileID>`, added by `t_ccf6837d`) —
i.e. the crash is not the app drawing a bitmap; it is the automation layer walking a large
accessibility tree. Volume, measured with a live `log stream` on the app process for the whole run:

| | run 2 (fails) | run 3 (passes) |
|---|---|---|
| lines from the app process | **1,139,035** | 47,032 |
| file size | 160.9 MB | 7.7 MB |
| mean / peak lines per second | 1,948 / 10,032 | 208 / 1,133 |
| `com.apple.dt.xctest` lines | **639,217** | 6 |
| the app's own `com.mattermost.ios` Logger | 539 | 507 |

That attribution agrees with the one already measured for this repo in `docs/t8d-build-note.md` §2.1
(84 % `com.apple.dt.xctest`, 0.03 % the app's `Logger`): XCTest fetches ~10 accessibility attributes
per element it visits and logs three lines per fetch, so a full-tree
`descendants(matching: .any)` walk of this account's sidebar costs ~1 MB of log per query. Run 2
issued 441 such existence/find queries in 350 s.

The one surviving report in `~/Library/Logs/DiagnosticReports` from the earlier finding
(`Mattermost-2026-11-05-135743.ips`) is the same mechanism seen at the moment of the crash:
SIGSEGV on the main thread, `-[XCElementSnapshot value]` → `_fetchSimpleValueForKey:` →
`_os_log_fault_impl` → `__LIBTRACE_CLIENT_QUARANTINED_DUE_TO_HIGH_LOGGING_VOLUME__` →
`firehose_client_start_quarantine` → … → `runtime_issue_os_log_fault_callback` → `_platform_strcmp`
(NULL). Once libtrace quarantines the process, the next *fault* that automation code raises lands in a
callback that does not tolerate a NULL format argument, and the app dies inside whatever assertion is
in flight. That is why the victim moves and why "vanished" and "crashed in XCTest" are one problem,
not two (question 3 of the card): a crash in that callback does not always get a report written.

## 4. The causal test

Nothing in the app or the tests changed between runs 1–2 and 3–4. The only difference is a
simulator-side logging setting:

```
xcrun simctl spawn 81A7F251-8B31-4945-8783-5A264C14B8D5 \
  log config --subsystem com.apple.dt.xctest --mode "level:off"
xcrun simctl spawn 81A7F251-8B31-4945-8783-5A264C14B8D5 \
  log config --subsystem com.apple.dt.xctest --status     # -> Mode for 'com.apple.dt.xctest'  OFF PERSIST_OFF
```

Effects measured in runs 3 and 4: the class goes 6/6 twice (337 s, 336 s; xcodebuild rc 0, and no
kernel crash corpse in either window); the app-process log volume drops 24× (1,139,035 → 47,032 lines;
160.9 → 7.7 MB); the app's own logging is unchanged (539 → 507 lines); the runs get faster (465/514 s →
337/336 s) because the AX logging was real work. The human-readable xcodebuild log is **not**
diminished: run 3 has the same 310 "Checking existence of" step lines and the same ~1,500 total lines as
run 2, so failure messages and `app.debugDescription` dumps survive.

The setting was restored to the simulator's default after run 4
(`log config --subsystem com.apple.dt.xctest --reset` → `INFO PERSIST_DEFAULT`), so this host is back
the way it was found and a re-run of the baseline will fail again.


## 5. Answers to the card's questions

1. **Is it environmental?** No. 2 of 2 runs lost a test with one booted simulator and 30–66 % free
   memory; the sizes of the numbers in the original finding were coincidental.
2. **Is it an app-side leak or a limit?** No. RSS is a flat plateau across all six launches in all
   three measured runs; the documented footprint is ~150 MB; the process is not jetsam-killed; and the
   class passes with the *same* memory profile once the automation logging stops.
3. **Is the XCTest-AX crash a second problem?** No. It is the same event, and the "silent terminations"
   were crashes whose reports OSAnalytics rate-limited away (§2).
4. **Can it still be blamed on the new zoom/share cases?** No. In both failing runs the two new cases
   were not the victim in run 1 (`testSaving…`), and in run 2 the victim died in the zoom case's own
   gallery-page query — a seam query, not a bitmap or a share. The victim moves from run to run and is
   determined by which AX query is in flight when the quarantine fault fires.

## 6. What is not validated

- **Two clean runs under the mitigation are not proof of a fix.** 2/2 clean against 5/5 losses (the
  three from the original finding plus runs 1–2 here) is a strong signal but a small sample; the change
  has to live in the harness and then the class has to run repeatedly (`t_8d093748`'s follow-up card).

- **No real device.** The mechanism is the simulator's os_log firehose quarantining a process; a device
  has the same libtrace machinery but the firehose budget differs, and nothing here was run on one.
- **No root-cause fix in the app's control.** The app's share of the volume is 0.05 %; the remaining
  lever inside the repo is the number of full-tree AX walks the suites perform (441 in one class run),
  which is a harness change, not an app one.
- The mitigation was applied by hand to one simulator; a fresh boot of that simulator resets it.

## 7. Reproducing

```
# baseline (fails ~1 test per run): leave the subsystem at default
python3 scripts/t38_live_pressure_sample.py 700 > build/logs/t38-repro-mem.csv &   # 1 Hz app/runner/host
log stream --style compact --level info --predicate 'process == "Mattermost"' \
  > build/logs/t38-repro-applog.log &                                             # volume + last lines
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 … python3 scripts/qa-test.py … --label t38-repro

# mitigation
xcrun simctl spawn 81A7F251-8B31-4945-8783-5A264C14B8D5 \
  log config --subsystem com.apple.dt.xctest --mode "level:off"
```

Correlating a death: the app pid disappearing from `build/logs/t38-repro-mem-*.csv` gives the epoch;
`log show --start … --predicate 'eventMessage CONTAINS "<pid>"'` gives the kernel corpse and the
ReportCrash verdict for that pid, and `grep '\[<pid>' build/logs/t38-repro-applog.log | tail`
gives the process's last words.

## 8. Files

| path | what it is |
|---|---|
| `build/logs/t38-repro-1.log`, `t38-repro-2.log` | the two failing class runs |
| `build/logs/t38-repro-3-noaxlog.log`, `t38-repro-4-noaxlog.log` | the two runs with the subsystem off |
| `build/logs/t38-repro-mem-{1,2,3,4}.csv` | 1 Hz app/runner RSS + host load/free for each run |
| `build/logs/t38-repro-applog-2.log` | 1,139,035-line live capture of the app process (160.9 MB) — the doomed pid's last 12 lines are §3 |
| `build/logs/t38-repro-applog-3.log` | the same capture for the passing run (47,032 lines) |
| `scripts/t38_live_pressure_sample.py` | the sampler used here (app + runner RSS, load, free %) |
| `~/Library/Logs/DiagnosticReports/Mattermost-2026-11-05-135743.ips` | the one surviving crash report of this class (pre-existing) |
