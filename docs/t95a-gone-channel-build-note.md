# T95-A-AV-R follow-up — the launch decide reads an empty `available`, and a channel the reader has left is opened at relaunch

Card `t_fcbd5cc8` (measurement card, follow-up to `t_c81a4bad`). **No product change ships from this
card.** What it ships is a measurement, a falsifier, and a repair card.

Question asked: *does a relaunch whose saved channel the account has already left open that channel's
pane, or does the shell stay on the channel list?*

Answer, measured: **it opens the pane.** Every run that reached the relaunch measured a
`nativeChannelPane` present, titled with the left channel's display name, in the first sample after
the new process was foreground, and still there 30 s later; the tab bar was gone (the compact push
covers it). The `-shellSnapshot` diagnostics of a **clean** build record the decide:

```
sidebar=team=ocz148uck3r88dcjikj497bosh phase=loaded stage=loaded 0 groups service=labels ok (4) groups=2 channels=42 err=- launch=entries=0 saved=dqjbyw37ftfi3ehsdi3mentxso -> opened(Mattermost.NativeLocation(… channelID: Optional("dqjbyw37ftfi3ehsdi3mentxso"), channelName: Optional("t95gone-1793176842"), …))
```

`groups=2 channels=42` and `launch=entries=0` in the same line: the sidebar knew 42 channels when the
decide ran, and the decide handed `LaunchDestination.request` **zero**. `saved=` is the channel
`perfprobe` had just left.

---

## 1. The measurement

Harness: `MattermostUITests/T95GoneChannelLaunchUITests.swift`. It drives the real launch path; no
store bytes are fabricated:

1. create a probe channel through the API (`POST /channels`, public, so leaving it is legal and it
   disappears from the account's channel list);
2. launch **with** `-uiTestResetPersistedState`, sign in, open the probe channel through the sidebar's
   quick switcher (a 42-channel fixture does not put every row in the accessibility tree — the first
   attempt of this test failed exactly there, see §5 `t95gone-probe-1`), and assert the pane names it;
3. terminate, then **leave** the channel over the API (`DELETE /channels/{id}/members/{user}` → 200)
   and read the account's channel list back: `stillJoined=false`;
4. relaunch **without** `-uiTestResetPersistedState` (that seam wipes the store) and without
   `-uiTestForgetSession` (a sign-in would be a different launch), sampling pane / title / tab bars /
   directory every 400 ms from the moment the new process is foreground.

The store is the product's own: opening the channel in step 2 writes it, and the host-side read of the
simulator's `Library/Preferences/com.mattermost.ios.plist` after the run shows it:

```json
{"serverID":"7C2D4C9E-C62F-4663-A2CC-0B3C3DBB8FB7","teamID":"ocz148uck3r88dcjikj497bosh",
 "teamName":"perf","channelID":"dqjbyw37ftfi3ehsdi3mentxso","channelName":"t95gone-1793176842",
 "openedAt":814869673.021657}
```

### What the reader sees

`MEASURE` lines from the final clean run (`t95gone-clean-4-snapshot`):

```
1793176874.265 MEASURE trace t=0.01 pane=true title='T95 Gone Probe' tabs=0 rows=true shell=false signIn=false
1793176874.982 MEASURE trace t=1.06 pane=true title='T95 Gone Probe' tabs=0 rows=false shell=false signIn=false
1793176904.516 MEASURE landing=pane directory rows at 0.01 s after launch; landing at 0.01 s; window=30.0s from the directory
1793176904.539 MEASURE paneAt=0.01 s after launch title='T95 Gone Probe' tabBarsNow=0
```

Three observations, all recorded as expected failures in that run (the suite stays green, §2):

```
XCTExpectFailure: matcher accepted Assertion Failure at …:299: XCTAssertNil failed: "0.0117…" - the shell opened a channel pane 0.01 s after the relaunch … title='T95 Gone Probe' tabBars=0.
XCTExpectFailure: matcher accepted Assertion Failure at …:308: XCTAssertFalse failed - the pane at launch names the channel the account has left (#t95gone-1793176842) …
XCTExpectFailure: matcher accepted Assertion Failure at …:312: XCTAssertGreaterThan failed: ("0") is not greater than ("0") - a launch that lands on the channel list keeps its tab bar (D1) …
```

The same three reproduce on the committed file (`t95gone-clean-5`, `Executed 1 test, with 0 failures
(0 unexpected) in 102.495`, three matched expected failures, `paneAt=0.01 … tabBarsNow=0`), with one
cosmetic difference worth knowing when reading the logs: the pane title at first sight is sometimes the
channel *slug* (`title='t95gone-1793177221'`) rather than the display name — the header starts as the
slug and `loadChannelHeader()` replaces it a beat later, so assertion 308 accepts either spelling and
both of them are the left channel, not a different one.

The window screenshot taken by `-shellSnapshot` in a clean build
(`docs/t95a-gone-channel-relaunch.png`) shows the pushed pane: header `# T95 Gone Probe`, a `Back`
chevron instead of the tab bar, and the channel's own system posts — `perfprobe joined the channel.`
/ `@perfprobe left the channel.` The reader is sitting in the channel they left.

### Reproduced without XCTest

Same measurement without the test harness, on the installed clean build, store intact:

```
xcrun simctl launch --terminate-running-process <udid> com.mattermost.ios \
  -surfaceMode shell=native -surfaceMode auth=native -surfaceMode sidebar=native \
  -shellSnapshot <container>/tmp/t95gone-snap       # after leaving dqjbyw37…
```

80 s later `<container>/tmp/t95gone-snap.txt` holds `location=… channelID: Optional("dqjbyw37…"),
pane: .channel` and the `launch=entries=0 saved=dqjbyw37… -> opened(…)` line quoted at the top, and
`<container>/tmp/t95gone-snap.window.png` is the screenshot described above.

---

## 2. Attribution — which decide opens it

An instrumented build (throwaway `t95probeFile()` writing to the app's own tmp, `Date()`-stamped at
every decide site and at every location apply; reverted before anything was committed) records four
facts about the relaunch of a left channel:

* `activate` and the location-change `defer` both call the decide **before the directory arrives**
  (`groups=0 phase=idle`), and one of them opens the saved channel then;
* the `$groups` sink fires with the arriving value while `model.groups` is still the **previous** one —
  `sink groups=2 modelGroups=0` — which is the `@Published` willSet read this card was filed about;
* **the sink's decide is the one that calls `openChannel` for the gone channel on a loaded-ish model**
  (`decide enter … groups=0 phase=loaded` → `decide OPEN entries=0`), immediately after the sink;
* the earlier opens leave `navigation.location.opensADestination` **false** by the time the sink's
  decide runs (measured: `decide enter opensDest=false` at `…843.595`, 0.33 s after the first
  `apply … opensDest=true` at `…843.254`).

Raw lines and the mutant that isolates the effect are in
`docs/t95a-gone-channel-evidence-2026-10-28.log` §C–§D.

### The isolating mutant (M1): fix only the willSet read

Throwaway mutant, the card's own proposal — the sink hands the decide the value the publisher is
delivering (`applyLaunchDestinationIfNeeded(…:arrivingEntries: groups.flatMap(\.entries))`) instead of
the stale `model.groups`. Nothing else changed.

| tree | visible pane in the 30 s window |
|---|---|
| product | **yes** — `pane=true` from the first sample, title = the left channel, tabs=0 (3/3 runs, plus the clean-build and no-XCTest measurements above) |
| M1 (sink reads the arriving value) | **no** — `paneAt=nil`, `landing=shell`, tab bar present (3/3 runs) |

So the willSet read is not merely theoretical: **the visible defect tracks the sink's `openChannel`
call.** With M1 the sink's decide answers `entries=42 → none` and no pane ever appears.

But M1 does **not** stop the coordinator from opening the gone channel: the location-change decide
still runs `decide OPEN entries=0 saved=cwyytjj…` and applies a location for it in every M1 run
(`apply loc channel=cwyytjj… opensDest=true`). It simply does not end up on screen. Why an open this
early is not rendered is **not measured here** (dropped by an unmounted `NavigationStack`, or
overwritten 0.33 s later — see the `opensDest=false` line above); what is measured is that the pane
follows the sink's call.

---

## 3. The repair card

Filed for `mmios-architect`: card **`t_e0cef465`** (child of this card, so it starts once this
measurement lands). The spec it must honour:

1. **The minimum that makes the measured symptom disappear** is the willSet fix — pass `groups`
   through the sink (or re-read after the publish settles) so the directory-arrival decide sees the
   directory. Measured on M1, 3/3 runs, no pane.
2. **That is not sufficient as policy.** After M1 the coordinator still calls `openChannel` for a
   saved channel that is gone (`entries=0`), from `activate` and from the location-change `defer`.
   On this fixture those opens are invisible; the reason is unmeasured, so a change that makes them
   render (a different mount order, a different device) would restore the defect with the sink fix in
   place. The fix has to make the *decision* right, not just the late one: either do not trust an
   empty `available` at launch (decide "nothing" until the directory is loaded, and re-decide when it
   arrives), or allow a later decide to correct an earlier open.
3. Keep `LaunchDestination.request(saved:available:)`'s contract and its unit tests; the defect is
   in which `available` the coordinator hands it and when, not in the function.
4. `MattermostUITests/T95GoneChannelLaunchUITests.swift` is the falsifier. Its assertions are wrapped
   in `XCTExpectFailure` (strict): when the repair lands they stop failing, the expectation goes
   unmatched and **the test fails** — remove the wrapper, keep the assertions. Do not delete the test
   to make it green.

---

## 4. What this card does **not** establish

* **No error pane was measured.** On this fixture the account (`perfprobe`) is a system admin and
  Mattermost 9.11 answers `200` for a channel it has left (`GET /channels/{id}`, and `/posts`) and
  even for an archived one; the pane renders the channel normally (screenshot in §1). The card's
  premise that such a pane "shows an error instead of a conversation" is therefore **not** reproduced
  here — it needs a non-admin account and a private channel, which this measurement did not drive.
  What is reproduced is the unsolicited destination itself, which is the policy violation.
* **Why the early open does not render in M1 is not measured** (§2). The repair must not depend on it.
* **Phone layout only.** The regular/iPad layout has no compact push; whether the same decide opens
  the split view's detail column was not measured.
* **No real device, no APNs.** Simulator only (iPhone 16 Pro, iOS 18.3.1 runtime).

---

## 5. Runs

Runner: `scripts/qa-test.py` (guarded; derived data outside `~/Documents`), fixture `mm-perf`
(Mattermost 9.11.19 on `127.0.0.1:8065`, account `perfprobe`), simulator `614CEE50-8613-434D-BFBB-8F3B858F4B9A`
(iPhone 16 Pro, created for T95-A-AV-R). Credentials come from `TEST_RUNNER_MM_AUTH_*`; no credential
appears in a log or on a command line.

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=… python3 scripts/qa-test.py --platform ios --sim id=614CEE50-… \
  --derived-data ~/Library/Developer/Xcode/DerivedData/t95gone --label <label> \
  --only-testing MattermostUITests/T95GoneChannelLaunchUITests \
  -- -clonedSourcePackagesDirPath ~/Library/Developer/Xcode/DerivedData/t95av2/SourcePackages
```

| label | tree | result |
|---|---|---|
| `t95gone-probe-1` | product | **FAIL (setup)**: the probe channel never became a sidebar row after 25 swipes — the sidebar renders only rows in view on a 42-channel fixture. The test was rewritten to open through the quick switcher. |
| `t95gone-probe-2` | product + probe | **RED**: `paneAt=0.12` s after the directory, `title='t95gone-…'`, `tabBars=0` |
| `t95gone-probe-3`, `-4` | product + probe | **RED** (same shape; `decision=entries=0 saved=<left channel> -> opened(…)` in the probe log) |
| `t95gone-mutant-sink-1`, `-2` | product + **M1** | **PASS** — `landing=shell`, `paneAt=nil`, `tabBars=1` |
| `t95gone-probe-5-trace` | product + probe | **not evidence**: the sampling loop started before the relaunch handshake finished and sampled the *terminating* process (pane at `t=0.01`, then "Application is not running"). The test now waits for the old process to be `.notRunning` and for the new one to be `.runningForeground` before the clock starts. |
| `t95gone-probe-6-trace` | product + probe | **not evidence**: the app process vanished 131 s into an unbounded sampling loop (the T635 symptom on this host). The window is now bounded by the landing itself. |
| `t95gone-probe-7-trace` | product + probe | **RED** with the full trace; the probe log pins the decide (§2) |
| `t95gone-mutant-sink-3-trace` | product + **M1** | **PASS** with the same trace: `t=0.02 pane=false … shell=true rows=true`, unchanged for 30 s |
| `t95gone-clean-1` | **clean** | **PASS** with 1 expected failure: `continueAfterFailure=false` stopped the test at the first assertion, so the title/tab-bar observations were never recorded. The test now raises `continueAfterFailure` for the measurement block only. |
| `t95gone-clean-2-snapshot` | clean | **FAIL (harness)**: window start keyed on the directory only; when the pane covers the sidebar no row is ever in the tree, so the loop ran 240 s and the app died at 131 s. Window start is now the directory **or** the landing. |
| `t95gone-clean-3-snapshot` | clean | **FAIL (harness)**: `XCTAssertNotNil(rowsAt)` refused the reproducing case (a pane covering the sidebar legitimately hides every row). Replaced by a recorded window start. |
| **`t95gone-clean-4-snapshot`** | **clean** | **PASS**, 3/3 expected failures recorded, 103 s — the citable run (§1) |
| **`t95gone-clean-5`** | **clean** (committed file, + fixture cleanup) | **PASS**, 102 s, the same three expected failures — re-run after adding the probe channel's archive step, so the verified tree is the committed one |
| simctl launch, store intact | **clean** | reproduced without XCTest; `-shellSnapshot` diagnostics + screenshot (§1) |

`-shellSnapshot` note: the seam writes to the path it is given, and an iOS simulator app can only write
inside its own container. Two consequences, both met on this card: a host path such as `/tmp/x` writes
nothing (the parent card's `/tmp/t95probe-*.log` leaves no file on this runtime), and a
container-absolute path goes stale whenever `xcodebuild` reinstalls the app between runs (the container
UUID changed between every one of the runs above). The clean-build diagnostics quoted in §1 therefore
come from a `simctl launch` with the container path resolved immediately before it, not from the
XCTest relaunch.

---

## 6. Files

* `MattermostUITests/T95GoneChannelLaunchUITests.swift` — the falsifier (skips without the fixture;
  **fails** when the expectation is unmatched, i.e. after the repair).
* `docs/t95a-gone-channel-build-note.md` (this file).
* `docs/t95a-gone-channel-evidence-2026-10-28.log` — every raw line quoted above, plus the probe logs
  of the product tree and of M1.
* `docs/t95a-gone-channel-relaunch.png` — the clean build's window screenshot of the relaunch, taken by
  the `-shellSnapshot` seam: the pushed pane for the channel the account had left.
* No product file, no launch argument, no store format: `git diff origin/main -- Mattermost/
  MattermostTests/ Mattermost.xcodeproj/` is empty for this card (the probe and M1 were reverted;
  `git status` shows only the new test file).
