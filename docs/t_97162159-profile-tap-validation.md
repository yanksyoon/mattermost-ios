# Adversarial validation of `8ab51f0` — the author profile tap

Card: `t_97162159` (validation of `t_42968927`). Validated commit: `8ab51f0` (parent `0ca64f8`).
Validated note: `docs/t_42968927-profile-popover.md`.
Trees: `wt-fix` = `8ab51f0`; `wt-base` = `0ca64f8` + **only** `MattermostUITests/T429ProfileTapUITests.swift`.
Server: Mattermost 9.11.19 at `127.0.0.1:8065` (`mm-perf`, accounts `perfprobe` + `t41buddy`).
Devices: iPhone 16 Pro / iOS 18.3.1 (the runs that count, see §7) and iPhone 17 Pro / iOS 26.5 (contaminated, §7).
All logs referenced below are in `build/logs/t429av-*.log`.

**Where the tree stands while this was being written:** `main` advanced to `26531b5` after the
validation runs, and now contains C1 of `t_8f9f5449` (`f2fb0db`, card `t_07216319`) — "a thread reply's
author opens the profile, and the gate names the row host" — which renames
`ProfilePopoverPolicy.offersAuthorTap(paneHost:)` to `rowHost:` and calls the same policy from the
thread host. That is a different card on a different commit; **everything below is measured against
`8ab51f0`**, which is the commit this validation was asked to judge. C1 does not invalidate the
findings (the policy's native/web truth table is unchanged by a parameter rename), but it does mean
the mutation diffs here no longer apply verbatim to `main`.

## Verdict

**PASS-WITH-FINDINGS.** The claimed repair is real and the tests detect it rather than merely pass on
it: the tap is red on the pre-fix tree and green on the fix tree under the **same shipped-default
launch**, each of the three named mutations reddens the intended test, and the author's own
evidence reproduces.

Findings (none of them a defect in the product change):

| # | finding | severity |
|---|---|---|
| F1 | `testTappingTheAuthorNameOpensTheSameProfile`'s first assertion is **vacuous about affordance-ness**: the `post.<id>.author` identifier exists on the pre-fix plain `Text` too, so "the author's name must be an affordance" passes on an inert label. The test still catches the defect — through the *next* assertion (`the profile sheet must mount`, line 190), which is where both the pre-fix replay and mutation (b) fail. | low |
| F2 | The note's "a second tap re-targets the sheet rather than stacking a second sheet" is **not exercised and not reachable**: both entry points (row avatar, row name, header avatar) sit behind the presented sheet, and `.sheet(item:)` does not rebuild its content when `item` changes while presented. "One presentation" is structural and measured; "re-arming" is unproven and inert. It should be written as "one presentation; the re-aim path is unreachable from the UI". | low |
| F3 | Two of the four truth-table cells (`paneHost = .web`, both `.profile` columns) are **unreachable in the product**: `ContentView` mounts the native shell (and therefore `ChannelPaneContent`) only inside `SurfaceHost(SurfaceDefaults.paneHostSurface)`, so a native pane cannot exist while the pane host resolves web. `testAWebPaneTakesTheTapOffWithItsRows` pins a state the app cannot build. Defensive, not live coverage. | info |
| F4 | The note's deactivated row was **unit-only; it no longer is** (this validation produced a live fixture, §4.3). Also measured: 9.11.19 **accepts** `POST /channels/direct` with a deactivated half (201) — the client's gate is a policy choice, not a server refusal. | info |
| F5 | Fixture collision: another in-flight card (`t_07216319`, C1 of `t_8f9f5449`) is now posting `t_07216319 thread …` into **`#t429-tap`** (8 messages were in the channel during these runs). The T429 suite survives it (its setUp re-posts and re-checks newest) but two cards' live suites share one channel. | low |
| F6 | The known wedge (§6) reproduces **in this card's own suite on the pre-fix tree**, so "it never reaches this card's code" is the wrong reason to call it unrelated. The right reasons are measured: it reproduces without the change, at arbitrary navigation/text-input steps, and on this host it is dominated by **another card's UI run on the same simulator**. | low |

## 1. Detection, not just greenness

### 1.1 The pre-fix replay

`wt-base` = `0ca64f8` with `MattermostUITests/T429ProfileTapUITests.swift` copied in from `8ab51f0`.
Nothing else was moved: the card's instruction to move `MattermostTests/T429ProfileTapTests.swift`
aside cannot arise, because that file is **new in the fix commit** and does not exist on `0ca64f8`
(verified: `ls` → No such file). The suite compiles and runs unchanged against the pre-fix product.

```
run        : t429av-prefix-replay
3 assertion failures, 1 harness timeout, then the stall guard killed the run (xcodebuild rc=124, 722 s)
log        : build/logs/t429av-prefix-replay.log
```

| test | failure |
|---|---|
| `testTappingTheAvatarOpensThatAuthorsProfile` | `:116 this is the reported defect: the author's avatar must be an affordance on the shipped defaults` |
| `testBothAffordancesOpenOnePopoverAtATime` | `:149 avatar affordance missing:` + `Failed to tap "post.<id>.avatar" … No matches found` |
| `testTappingTheAuthorNameOpensTheSameProfile` | `:190 the profile sheet must mount:` — **the name element existed and its tap did nothing** (that is F1) |
| `testThePanesOwnProfileEntryIsOfferedWhileProfileResolvesWeb` | `Failed to get matching snapshots: Timed out while evaluating UI query` at the quick-switcher step, then `App event loop idle notification not received` and no output for 240 s |

Verdict on the claim: **confirmed in substance, corrected in form.** The author's log has 4 run / 8
failed in 257 s; mine has 4 run / 4 failed in the same way plus a harness wedge. All four tests are
red on the pre-fix tree, three of them on the exact assertions the note quotes; the fourth died in
the harness before it could assert. The note's "every test failing on its first assertion" is not
quite right for the name test — it fails on its *second* (see F1).

### 1.2 Mutation (a) — the policy consults `.profile` again

`ProfilePopoverPolicy.offersAuthorTap` replaced with `paneHost == .native && profileSurface == .native`
(the pre-fix rule), everything else untouched:

```
run : t429av-mut-a      9 run / 2 failed
:70 XCTAssertTrue failed - native pane + web profile card is the reported defect: the tap must exist
:89 XCTAssertTrue failed - this is the exact pair the card reported as broken
```

The truth-table test **and** the shipped-defaults test go red, and nothing else does. Confirmed.

### 1.3 Mutation (b) — the author's name back to plain text

`PostRowView.authorName` reduced to the inert `Text` (identifier kept), avatar button untouched:

```
run : t429av-mut-b-name2   1 run / 2 failed
:190 XCTAssertTrue failed - the profile sheet must mount:
```

Red — but at line **190**, not at line 132 (`the author's name must be an affordance`), which passed:
that is F1, measured rather than argued. The first attempt (`t429av-mut-b-name.log`) died in a
simulator keyboard hang with no assertion at all; it was re-run after a simulator reboot and is the
run quoted here.

### 1.4 Mutation (c) — the header's own control gated on `.profile` again

```
run : t429av-mut-c-header   1 run / 2 failed
:174 XCTAssertTrue failed - the pane header must offer the signed-in profile:
```

Confirmed. Each mutation reddens exactly the test the card says it should, and each red assertion
names the defect rather than a downstream symptom.

## 2. Is the live test vacuous about the state it claims to cover?

The suite launches **without** `-surfaceMode profile=native`; that is visible in its source and in
the xcconfig-free argument list. What was missing was a measurement that the resulting resolution is
the regression pair in *that* launch configuration. Two independent pieces:

1. **A probe pinning the exact argument list.** A throwaway unit test (not part of the fix) built a
   `SurfaceModeResolver` from `T429ProfileTapUITests.launchApp()`'s arguments verbatim:

   ```
   PROBE-T429AV launch-arguments resolution: auth=native sidebar=native channelView=native
   composer=native threads=web search=web profile=web activity=web settings=web channelInfo=web
   calls=native plugins=web
   ```

   `channelView=native` **and** `profile=web` — the pair the card reported. With the T41 flag added,
   `profile=native` (also asserted), which is exactly the flag that hid the defect.
   (`build/logs/t429av-probe-launchargs.log`, 2 run / 0 failed.)

2. **The pre-fix replay is the second proof.** Those same arguments on `0ca64f8` produce a red suite
   at the avatar/name/header assertions. Pre-fix, the tap is offered **iff** `.profile == native`; the
   suite being red therefore *measures* that `.profile` resolved web in the launch that the green run
   also uses. A green run and a red run cannot be explained by two different resolutions.

This is the strongest available in-app evidence: the app exposes no "resolved mode" element in the
test build (the Surface inspector is a separate `-surfaceInspectorSnapshot` seam that needs a manual
sign-in), so the arguments plus the resolver pin plus the pre-fix red are the chain.

## 3. One presentation

* Unit: `T429ProfileTapTests` 9/9 green on the fix tree; mutation (a) shows 2 of those are load-bearing.
* Live, the suite's own case: `testBothAffordancesOpenOnePopoverAtATime` **1 run / 0 failed** solo
  (`t429av-one-popover.log`, 217 s) — it never passed inside my contended full-suite runs (§7), so it
  was run alone to isolate it from that contention.
* **New probe (this validation): a re-render while the sheet is open.** Open the buddy's profile on the
  shipped defaults, then POST as that same account so the pane takes a socket update, wait 8 s, and
  assert the tree still holds exactly one `profileSheet` and the same `@username`
  (`testANewPostDoesNotStackOrSwapTheOpenProfile`, **1/1**, 30.9 s, screenshot
  `t429av-rerender-open-profile`). The `Binding(get:set:)` over `@State profilePopover` survives a
  redraw; nothing stacks, nothing is swapped.
* **F2 correction.** "A second tap re-targets the sheet" is not tested and cannot be: the sheet covers
  the row and the header, so a second tap cannot occur while it is presented; and SwiftUI's
  `.sheet(item:)` does not re-evaluate its content when `item` changes during presentation, so even a
  programmatic re-aim would not repaint. The honest statement is "the pane holds one presentation
  slot", which is structural and now measured under a redraw.

## 4. The action matrix against the server

### 4.1 Another member — Message offered, and the DM really opens

`MattermostUITests/T41ProfileUITests/testSendMessageOpensTheDirectChannelWithTheAuthor`
**1 run / 0 failed** (84 s, `build/logs/t429av-t41-dm.log`). Its oracle is server-side: a `type: "D"`
channel between the two accounts must exist after the tap. Confirmed.

### 4.2 My own profile — no Message, a reason, the status rows

`testProfilePopoverShowsTheServersOwnIdentity` **1 run / 0 failed** (87 s,
`build/logs/t429av-t41-identity.log`): name/username from the server, "no message shortcut", "…it says
why", presence and local-time rows. That suite launches with `-surfaceMode profile=native`, which is
correct for an action-set claim (the rows do not depend on the surface).
On the **shipped defaults** the pane's own entry opens the signed-in account:
`testThePanesOwnProfileEntryIsOfferedWhileProfileResolvesWeb` passed in both green runs and asserts
`profile.username == @perfprobe`.

### 4.3 A deactivated account — no longer unit-only

The note said this case is unit-only because the server has no deactivated fixture. It has one now:
`scripts/t429av_deactivated_fixture.py` creates `t429gone`, adds it to `#t429-tap`, posts as it,
deactivates it, and measures what 9.11.19 does with it. New live probe on the **shipped defaults**
(`MattermostUITests/T429AVDeactivatedProbeUITests`, not committed to the product tree):

```
run : t429av-probe-deactivated2   2 run / 0 failed
testADeactivatedAuthorOffersNoMessageRowAndSaysWhy  passed (25.0 s)
   → the sheet mounts, @t429gone, NO profile.message,
     profile.messageReason == "This account has been deactivated, so it cannot be messaged."
testANewPostDoesNotStackOrSwapTheOpenProfile         passed (30.9 s)   [§3]
screenshot: t429av-deactivated (sheet for @t429gone, Offline, no Send message in the action area)
```

Server measurements behind it (all recorded in `build/logs/t429av-deactivated-fixture.log`):

| probe | 9.11.19 answer |
|---|---|
| `GET /users/{id}` after deactivation | 200, `delete_at` set, username intact — the sheet can render it |
| `POST /users/ids` | returns the account with `delete_at` set — the post list can resolve its author |
| `POST /channels/direct` **with the deactivated half** | **201 Created** — the server does **not** refuse; a DM would be created that nobody can read |

So `DMShortcut.canMessage`'s reason ("the server would answer a DM channel whose other half can never
read it") is accurate as a statement about a dead channel, but the note's phrasing should not be read
as "the server blocks it" — it does not. The client's gate is a policy choice, and it is now measured
on both sides.

## 5. Fixture hygiene and idempotency

* `#t41-profile` (T41's channel): **37 messages, 0 `t_42968927` residue**, before and after every run
  here (`build/logs/t429av-fixture-state*.txt`). The note's cleanup claim holds.
* `#t429-tap` is reused by id, not recreated: `oqapun5nwjn7zrjpp8ifoi97qe` in every probe.
* Two consecutive full-suite runs, **4 run / 0 skipped / 0 failed each** (156 s, then 114 s —
  `t429av-fix-green4-ios18.log`, `t429av-fix-green5-idempotent.log`). 0 skipped means the setUp's
  `isNewestPost` check held for all eight fixtures, i.e. the newest-post lookup works on a channel
  that already holds ~60 posts.
* Between those two runs the channel went **63 → 71 messages (+8, exactly two per test)**, the member
  list stayed at **2**, and the `t41buddy added to the channel by perfprobe` system message stayed at
  **1** — membership is not re-added.
* **F5:** 8 `t_07216319 thread …` messages were also present. Another card is posting into this
  card's channel today; see the hotspot comment on the card.

## 6. The known wedge

The note records a combined `T41 + T429` run wedging for 20 minutes inside T41's `revealSidebarRow`.
What this validation adds:

1. **It is not T41-specific.** My pre-fix replay wedged inside **T429's own** `openChannel` (quick
   switcher), on the **pre-fix** tree: `App event loop idle notification not received` at `t = 106 s`,
   then `Failed to get matching snapshots: Timed out while evaluating UI query`, then 240 s of no
   output while a test was executing (`build/logs/t429av-prefix-replay.log`). So "it never reaches
   this card's code" is not the reason it is unrelated; the fact that it reproduces **without** this
   change is.
2. **On this host the dominant cause is measurable: simulator contention.** Another card's UI run was
   live on the same simulator while my runs were failing —

   ```
   xcodebuild test … -destination platform=iOS Simulator,name=iPhone 17 Pro
     -derivedDataPath …/mattermost-ios-qa-t5449 …
   ```

   — and my logs show the app being terminated under the tests (`application com.mattermost.ios is not
   running`, `Restarting after unexpected exit, crash, or test timeout`, `Unable to monitor
   animations`), always at a text-input or navigation step, never in profile code. Moving every run to
   the **other** simulator (iPhone 16 Pro) produced 4/4 twice, 0 skipped, and made each mutation and
   probe deterministic. Host load average during the contaminated window: 60–200 on 10 cores
   (`mds_stores` indexing the new DerivedData plus the other card's builds).
3. **T41's helper is fine solo.** Both T41 tests re-run for §4 went through `revealSidebarRow` and
   passed: 84 s and 87 s, no wedge.
4. **The combined run did not reproduce the wedge.** `T41ProfileUITests` + `T429ProfileTapUITests` in one
   `xcodebuild test` on iPhone 16 Pro: **11 run / 1 failed** in 570 s
   (`build/logs/t429av-combined-t41-t429.log`). The T429 half was **4/4 green** inside the combined
   run, and — the point of the exercise — the T41 test that wedged for the author
   (`testPresenceFollowsAnotherClientsChangeWhileTheProfileIsOpen`) **passed in 68.8 s**, and no
   `revealSidebarRow` wedge occurred at all. The one failure was
   `T41ProfileUITests.testMyOwnPresenceFollowsTheSocketImmediately`, `:338 "the socket's status_change
   must land well inside…"` — a websocket-timing assertion in a different card's test, and the
   *inverse* of the author's run (there it passed and the presence test wedged; here it failed and the
   presence test passed). Two runs, two different flake targets, no common test: that is a flaky T41
   socket/presence pair under host load, not a property of this change and not a reproducible wedge.
   The author's 20-minute hang is therefore consistent with "observed once, not reproducible" — see
   §7 for what that leaves unresolved.

## 7. What I could not validate

* **A clean iPhone 17 Pro / iOS 26.5 reproduction of the 4/4.** The author's `t429-live-ownchannel.log`
  does show 4/4 (101 s) on that device, but that simulator was held by another card's UI run during
  this validation, and every run I attempted there lost the app mid-test to that contention. My
  independent 4/4 is on iPhone 16 Pro / iOS 18.3.1, twice, 0 skipped. The note's 26.5 numbers are not
  contradicted — they are simply not independently reproduced here.
* **A physical device.** No device is attached, so the whole validation is simulator-only, like the
  note's own evidence.
* **The author's 20-minute wedge.** Not reproduced in 4 attempts (two solo T429 runs, one combined
  `T41 + T429` run, plus the T41 solos). That is not a refutation — a hang observed once can be
  rare — and the harness has a second, independent failure mode that *is* reproducible
  (same-simulator contention, §6.2). What is settled is that the wedge is not a property of
  `8ab51f0`: it fired in this card's own suite on the **pre-fix** tree, and the combined run that was
  supposed to hang ran 11 tests to completion.
* **The re-aim path** (§3, F2) — unreachable from the UI; no evidence exists either way.
* **T70's probe** was adapted by the same commit (`staticTexts` → label-based `descendants`) because
  the author's name is no longer a `staticText`. I did not re-run T70: it is a different card's live
  suite, its assertion is a count of "Unknown user" rows, and the adaptation is a query-type change
  with no assertion weakened. It remains unverified by this validation.
* The probe files used here (`T429AVProbeTests`, `T429AVDeactivatedProbeUITests`, the two scripts) are
  **validation instruments**, not part of `8ab51f0`; they are attached to the card, not committed.

## 8. Claim-by-claim

| claim in `docs/t_42968927-profile-popover.md` | verdict | evidence |
|---|---|---|
| the gate was `.profile`'s resolution, so a native pane drew an inert avatar and plain name | confirmed | pre-fix red at `:116/:149/:190`, §1.1 |
| the tap now follows the pane host, not `.profile` | confirmed | mutation (a) red at `:70/:89` |
| the name is now a button on the same callback | **confirmed for behaviour, not asserted for affordance-ness** | mutation (b) red at `:190` (F1) |
| the header's own control follows the same rule | confirmed | mutation (c) red at `:174` |
| the pane holds one presentation | confirmed | unit 9/9; one-popover 1/1; re-render probe 1/1 |
| "a second tap re-targets it" | **unproven / unreachable** | F2 |
| another member ⇒ Message, DM really opens | confirmed | T41 DM 1/1 + server oracle |
| own profile ⇒ no Message + reason + status rows | confirmed | T41 identity 1/1; header test on the shipped defaults |
| deactivated ⇒ no rows, with a reason; unit-only | **superseded: now live-measured** | probe 1/1; server 201 measurement (F4) |
| Call / Add to channel / Invite / Manage absent, reason recorded | confirmed as recorded (no live row to test) | source + note §4; audit not re-derived |
| shipped defaults = `.channelView` native, `.profile` web | confirmed in the live launch args | probe pin, §2 |
| live suite 4/4 on 9.11.19 | **confirmed independently**, on iOS 18.3.1 (26.5 not re-reproduced) | green4/green5 |
| pre-fix 4 run / 8 failed | confirmed as 4 red / 1 of them before its first assertion | §1.1 |
| whole unit target 1788 / 8 skipped / 0 failed | confirmed on my build | `t429av-units-full.log` |
| dual-render gates PASS with `--allow-approved-registry` | confirmed | `verify-dual-render-gates.sh` → RESULT: PASS |
| `#t41-profile` residue cleaned; no re-pollution | confirmed | 37 messages, 0 residue, two probes |
| the 20-minute wedge is a pre-existing harness hazard | confirmed, **with the cause measured and the reason corrected** | §6 (F6) |
