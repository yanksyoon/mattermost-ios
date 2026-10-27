# T34-QA — the live suite on this host: four red causes, three of them not product

Card `t_667988fd` (QA lane; parent T35). Base `41e0e06` (== `origin/main` when this card started).
**Nothing in the product changed.** The diff is the test file, `docs/test-plan.md` §7 and this note.

The card asked for three decisions: the anchor test's settle window, the socket flake's need for a
deterministic wait, and what to do about the automation-host crash on large trees. A fourth cause was
found while measuring, and it is the one that made the suite red at `41e0e06` **today**: the suite
could no longer open its channel at all.

| # | symptom | cause | verdict |
| --- | --- | --- | --- |
| 1 | `testLoadingOlderPostsDoesNotMoveTheAnchoredPost` fails ~52 s, "the anchored post … left the screen" | settle window could lock onto a stable-but-wrong position, and the row scans were a snapshot storm | **test bug** — rewritten; decision in §2 |
| 2 | `testANewPostAppearsWithoutReloadAndTheUnreadLineFollowsLastViewedAt` fails intermittently | two different things share that symptom (see §3) | **one render race (test bug, fixed), one delivery loss (product defect, filed)** |
| 3 | app process lost, `EXC_BAD_ACCESS` in the accessibility framework, later tests cascade | one accessibility round trip **per element** on a 120-row tree | **harness bug** — one snapshot per question; decision in §4 |
| 4 | every test fails 0.06 s after launch, or "the sidebar must list #t34-showcase" | the throwaway server grew to 40 channels; the sidebar is a lazy list and 15 rows are realised | **environment drift + test bug** — bounded scroll; §5 |

## 1. What was measured before anything was edited

The working tree arrived with an **uncommitted** rewrite of this file (+114/−28 vs HEAD; flagged in
this card's thread by three different workers). It was read first, kept, and is the base of this
round's diff. Its core is right: one cheap single-element read per poll, three agreeing measurements
≥0.75 s apart, the assertion compared against the pre-insert frame, and a socket failure that probes
before it complains. Two things in it were wrong or incomplete, both measured here:

* **`allElementsBoundByIndex` is not "one snapshot".** It resolves one element per accessibility round
  trip, exactly like `element(boundBy:)`: `build/logs/t34q-run1.log` logs
  `Find the Any (Element at index N)` every **0.32 s** for indices 0…27 inside a single `postRows`
  call (98 such queries in one 7-test run; `build/logs/t34f-ipad-head.log` shows 0.29 s each on a
  60-row list). The comment claimed the query storm was fixed; the log says it was not.
* **The suite could not open its channel.** A red run (the first attempt this morning) had all seven
  tests fail at `launchAndOpen` with "the sidebar must list #t34-showcase" and a tree that held 15
  realised channel rows starting at "T35 Composer" — no `#t34-*` row at all. That run was killed when
  the fix was started and its log was **overwritten** by the re-run under the same label (its partial
  xcresult, `…/TestResults/t34q-run1-e8f971.xcresult`, has no `Info.plist` and cannot be read). The
  underlying condition is not lost, because it is measurable in every surviving run: the row is
  absent on a fresh launch, the 10 s `waitForExistence` fails, and the scroll loop finds it —
  **7 of 7 launches in each of** `build/logs/t34q-final1.log`, `t34q-final3.log`, `t34q-final4.log`
  (`grep -c 'Waiting 10.0s for "channelSidebar.channel' ` → 7, one `Swipe up "Sidebar" CollectionView`
  per launch in the same files), and `t34q-sidebar-probe.log` shows the row needed 2 `swipeUp`s after
  8 `swipeDown`s failed to reach it.

## 2. Decision — the anchor settle window

**Keep three agreeing measurements ≥0.75 s apart, with a 30 s budget, and one single-element read per
poll — but only because agreement is not the assertion.** Three facts, each from a run:

1. *A stable-but-wrong position still fails.* The settled frame is compared with the frame captured
   **before** the page insert (`accuracy: 2` pt), and the failure message carries the residual, the
   pane's loaded-post count and the rows actually on screen. Agreement only decides *when to look*.
2. *The budget is not competing with slow snapshots any more.* The poll reads
   `element(app, top.identifier)` (one element, ~0.3–0.5 s), not the row list. In
   `build/logs/t34q-anchor-snapshot.log` the loop settled at t=48.27 s and was done by t=52.40 s —
   three measurements, ~4.1 s — inside a 30 s budget. The 20 s budget was never the problem; the
   tree walks inside the loop were.
3. *Two reads 250 ms apart are not a settle.* Three reads at 0.75 s give ≥1.5 s of stillness, which is
   longer than the pane's own restore loop (~1.2 s of 16 ms steps, `ChannelView.restoreReader`).

The mutation proof that the assertion is not vacuous is in §8 — and it also shows the limit: the live
test detects a jump but does **not** isolate the restore that is supposed to prevent it.

## 3. Decision — the socket flake

**A deterministic wait cannot fix a frame that never arrives; the other half of the symptom was a
real render race and is now waited for.**

* *The render race* — `build/logs/t34f-iph17-socket1.log` (iPhone 17 Pro, iOS 26): the row **existed**
  and `bodyText` read `''` — the markdown blocks are published by a later layout pass. The test now
  waits (≤20 s, one single-element query per poll) for the first `post.<id>.body.block` to be
  non-empty, then asserts on the text. That is the condition the test means: "the message is readable
  on screen", not "an element with this identifier exists".
* *The delivery loss* — the T34-R5 instrumentation (still in `docs/t34r5-build-note.md` §5) shows a
  failing run's own socket log with only `socket open` / `authentication_challenge` / `ping` and **no
  `posted` frame at all**; it reproduces at base `38c3180`, and an 8 s or 30 s pre-sleep changes
  nothing. No wait in the test can create a frame the socket never delivered. So the test now
  **diagnoses** instead of guessing: after the 45 s miss it posts a second message (does the socket
  deliver *anything* now?), then relaunches (does the pane render the measured post from the server's
  own page?). One message, one verdict: socket delivery vs. rendering.
* The product half is real and is **not** fixed here: `SocketTeamEventSource.events(for:token:)`
  builds `SocketClient` without a `resync` closure (`TeamSidebarCoordinator.swift:81`), so a frame
  lost across a reconnect is never refetched — the miss is permanent until relaunch. Filed as a
  product card; the T34 suite is not the place to paper over it.

## 4. Decision — the automation-host crash on large trees

**Fewer snapshot queries is the right lever, and the unit is "one question per snapshot", not "one
call per element".** `XCUIElement.snapshot()` returns the whole accessibility tree in one round trip;
`postRows`, `bodyText` and `describeRows` now walk it (`snapshotNodes`). Measured effect:

| | per-element queries in a 7-test run | result |
| --- | --- | --- |
| before (`allElementsBoundByIndex`) | 98 | `t34q-run1`: 7/7, 482.6 s |
| after (`app.snapshot()` walk) | **0** | `t34q-final1`: 7/7, 452.2 s |

Two green full-suite runs and no lost app process under the new rule; the two `EXC_BAD_ACCESS`
reports from 2026-10-25 (`Mattermost-2026-10-25-210015.ips`, `-210758.ips`, both `SIGSEGV` at
`KERN_INVALID_ADDRESS 0x0`, frame `-[XCTAccessibilityFramework attributesForElement:attributes:error:]`
→ `-[XCElementSnapshot children]`) are the signature this targets. The rule and the "count a lost
host as one failure, not N" rule are now in `docs/test-plan.md` §7.

**Not claimed:** that the harness can never die. It still can, for host reasons — see
`t34q-final2` in §6, where the simulator's render service (`SimRenderServer`, SIGTRAP at 08:13:04)
and Docker both went down mid-run. That run has no verdict, and none is invented for it.

## 5. The new red — the sidebar outgrew one screen

`perfprobe` is a member of **40** channels in team `perf` (38 team channels; measured over the REST
API on 2026-10-27: `GET /api/v4/users/me/teams/{team}/channels` → 40,
`GET /api/v4/teams/{team}/channels` → 38, `t34-fold`/`t34-showcase` present and `delete_at = 0`). The
sidebar is a lazy `UICollectionView`: a launch realised 15 rows starting at "T35 Composer" (content
offset −1932 pt) and `#t34-showcase` was not in the tree, so `channelSidebar.channel.<id>` never
existed and the test failed before touching a post (before the fix, six of seven tests failed this way).

This is a test assumption breaking on environment drift, not a product defect — a person scrolls.
`launchAndOpen` now scrolls the sidebar, bounded (5 down the list, 5 back) and only when the row is
missing. Direction is measured, not guessed: in `build/logs/t34q-sidebar-probe.log`, eight
`swipeDown`s did not find the row and two `swipeUp`s did (it is **below** the realised window), which
is why up comes first. Cost when the row is hidden: ~8–10 s per launch; zero when it is visible.

## 6. Runs (all on this host, all real output)

Simulator: iPad Pro 11-inch (M5), `DC3E9FB7-E4A0-4B24-8DBB-7960A059EC7A`, iOS 26.0.
Server: Mattermost 9.11.19 (docker `mm-perf` / `mm-perf-db`) at `127.0.0.1:8065`, account `perfprobe`.
Command: `TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe
TEST_RUNNER_MM_AUTH_PASSWORD=… python3 scripts/qa-test.py --platform ios --sim id=DC3E9FB7-… \
--only-testing MattermostUITests/T34ChannelPostListUITests --label <label>`

| label | code under test | verdict | notes |
| --- | --- | --- | --- |
| `t34q-run1` | inherited settle rewrite + sidebar scroll + socket content wait | **7/7, 482.6 s** | 98 per-element queries; no lost process; no new `.ips` |
| `t34q-sidebar-probe` | showcase test only | **pass, 118.8 s** | 8 `swipeDown` + 2 `swipeUp` to find the row |
| `t34q-anchor-snapshot` | anchor test only, snapshot rewrite | **pass, 85.1 s** | 0 per-element queries; settled in ~4.1 s |
| `t34q-final1` | full suite, snapshot rewrite | **7/7, 452.2 s** | 0 per-element queries; no lost process; no new `.ips` |
| `t34q-final2` | full suite, back-to-back after `final1` | **HOST FAILURE — no verdict** | test 6: `Failed to get matching snapshots: Timed out while evaluating UI query` (494.7 s); test 7: `App event loop idle notification not received` after 2055 s, run killed. `SimRenderServer-2026-10-27-081304.ips` (SIGTRAP) at 08:13:04; **no** `Mattermost` crash report; the Docker daemon and `mm-perf` were found dead afterwards (host load average 92). |
| `t34q-final3-dockerdown` | full suite, Docker down | **no verdict** | every test skipped in 0.06 s: `Could not connect to the server` / `Socket SO_ERROR [61: Connection refused]` for `127.0.0.1:8065` |
| `t34q-final3`, `t34q-final4` | full suite ×2, consecutive, after `docker start mm-perf-db mm-perf` | **7/7 in 442.6 s**, **7/7 in 444.4 s** | 0 per-element queries in both; no lost process; no new `Mattermost` `.ips`; the two runs that back this card |
| `t34q-mutation` | anchor test, `ChannelView` restore call removed (product code, reverted) | **pass, 80.3 s** | see §8 — the test does *not* fail without the restore |
| `t34q-mutationB` | anchor test, pane scrolled to the bottom on purpose instead of restored (reverted) | **fail, 82.2 s** | `moved -230.5 pt from y=302.0 across a page insert (the pane holds 120 posts; rows on screen: …)` — see §8 |

`t34q-final2` is the honest counter-example to "the fix removes the crash": on a host where the
simulator's render service and the server both die mid-run, the suite cannot produce a verdict. What
it *does* show is the difference from the October runs: the app process was not lost, there is no
`Mattermost` crash report, and the failure is an XCTest query/idle timeout — i.e. the harness, not the
product, which is exactly the attribution this card needed.

## 7. Guards

* The suite refuses to be a liar: `setUp` pings the server and each test skips on a thrown error, so a
  down server reports as "no verdict", not as seven product failures (`t34q-final3-dockerdown`).
* The suite is re-run **twice consecutively** with the committed file; both runs must be green for the
  label "green on this host" (`t34q-final3`, `t34q-final4`).
* A deliberate jump must still fail the anchor test (mutation B, §8). A removed restore does not
  (§8) — that is a documented limit of the live oracle, not a guard.

## 8. Mutation: the assertion can fail, but it does not isolate the restore

Two mutations against `Mattermost/UI/Native/Channel/ChannelView.swift`, each built and run, each
reverted immediately (`git status` clean afterwards; the product file is unmodified in the commit).

**Mutation A — remove the restore.** `restoreReader(restore, proxy:)` replaced with `_ = restore` in
the `onChange(of: model.pendingScrollRestore)` handler, so a merged older page is never scrolled back.
The run *passed* (`t34q-mutation`, 80.3 s).

That is a finding, not a green tick: **the live test does not prove the restore path.** The condition
it asserts — the anchored row keeps its y across a page insert — still held on this host without the
restore. Why is not established here (candidates: SwiftUI/UIKit already preserving the reader's place
for this prepend at iOS 26, or the page being merged while the rows above it are still un-realised).
It cannot be dismissed as "the test is broken", because:

**Mutation B — jump the pane on purpose.** The same handler replaced with
`scrollController.scrollToBottom()` after the merge. The run **failed** (`t34q-mutationB`, 82.2 s) with

```
XCTAssertEqualWithAccuracy failed: ("71.5") is not equal to ("302.0") +/- ("2.0")
- the anchored post post.dnysfb453ifnj8ykub96zrmsth moved -230.5 pt from y=302.0 across a page
  insert (the pane holds 120 posts; rows on screen: post.1sqnpixfw7y9mjk1saw48ezctr@-734.0, …)
```

so the assertion is not vacuous, the 2 pt tolerance is real, and the failure message carries the
residual, the loaded-post count and the rows on screen.

Follow-up filed for the channel owner: either explain/pin the mechanism that keeps the anchor without
the restore (a unit test on the restore handoff, or a log-based assertion), or state in the parity
row that iOS 18+ anchoring — not `restoreReader` — is what a reader gets on this OS. Until then the
suite's claim is "the list does not jump", not "the restore works"; those are different sentences and
only the first one has live evidence.

**Closed by the channel owner (task `t_a4d02070`, `docs/t34-anchor-pin.md`).** Option 1 plus the
measurement: the loop is now `ScrollRestoreRunner` (driver-able by a fake surface, 9 unit tests), the
caller is pinned in-process by `T34ChannelViewRestoreWiringTests` (the real list in a window), and the
live anchor test reads a `ScrollRestoreReport` published at `channelPostList.scrollRestore` — a value
only the restore writes. Deleting the restore call now fails 4 assertions in 2 tests (`build/logs/t34pin-mutationA.log`);
deleting only the *application* of the correction fails 11 (`t34pin-mutationC.log`). The mechanism is
measured too: on this host the report reads `firstResidual=0.0 corrections=0` (iOS 26.0), i.e. the OS
kept the row and the restore correctly had nothing to do — the first of the two candidates, now stated
in `docs/parity.md` (T34, Limits) rather than left as a question.

## 9. What is still not validated here (no fabricated passes)

* **One host, one simulator, one server.** iPad Pro 11-inch (M5) on iOS 26.0 against a throwaway
  9.11.19 stack; no iPhone run of the full suite in this round (the iPhone 17 Pro / iOS 26 evidence is
  the single socket test in `t34f-iph17-socket1.log`), no physical device, no production workspace.
* **Harness stability is mitigated, not solved.** `t34q-final2` shows the simulator's render service
  can still die under host load; the note records the signature so the next reader does not read it as
  product failures.
* **The socket delivery defect is not fixed.** The test names it; the product card owns it.
* **The live anchor test does not isolate `restoreReader`.** Mutation A (§8): the suite is green with
  the restore removed. It asserts the reader-visible property ("the list does not jump"), which is the
  one that matters to a person, but a regression inside the restore loop would not be caught by it —
  that needs the owner's unit/pin (follow-up filed).
* **Two-channel sidebar order is not understood.** Why `#t34-*` sorts below "T35 Composer" on this
  server was not investigated (it is not alphabetical). The test does not depend on the order — it
  scrolls both directions — but the ordering itself is unexplained.

## 10. Repro

```
# the throwaway stack (must be up: the suite skips otherwise)
docker start mm-perf-db && docker start mm-perf
curl -s http://127.0.0.1:8065/api/v4/system/ping   # {"status":"OK"}

TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<seeded probe account, see scripts/perf_seed.py> \
python3 scripts/qa-test.py --platform ios --sim id=DC3E9FB7-E4A0-4B24-8DBB-7960A059EC7A \
  --only-testing MattermostUITests/T34ChannelPostListUITests --label t34q-local

# what the runs are judged on
grep -c "Element at index" build/logs/t34q-local.log        # expect 0
grep -n "Test Case.*\(passed\|failed\)" build/logs/t34q-local.log
```

The sidebar channel count is server state, not fixture state: 40 memberships today. If the count
grows further, the bounded scroll (5×2) is what to raise, not the assertion.
