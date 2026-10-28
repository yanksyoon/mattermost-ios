# T55-AV-R — re-validation of the five repaired surfaces (T36, T37, T38, T39, T40)

Date: 2026-10-27. Card: `t_6059f7ce` (T55-AV-R). Judge: adversarial re-validation, not a re-run of the
repairs' own tests.

**Audit target**: `origin/main` = `634afd9ca939fa0003b19570ce7a8080fdeef99f` (`git ls-remote origin
refs/heads/main` read at 19:47 and again at 19:52; `git rev-parse HEAD` in the audit worktree is the
same SHA). Every run below was made from a **detached worktree at 634afd9**
(`~/.hermes/profiles/mmios-qa/cache/scratch/t55/wt`), not from the shared checkout. That matters: the
shared checkout carried 16 modified + 12 untracked Swift/test files owned by T47 (`t_2739ca53`) and T48
(`t_37f27c09`) while this round ran, and `Mattermost.xcodeproj/project.pbxproj` was clean, so those files
were not compiled anywhere. No run of mine could see them — see §6 for the isolation proof.

**Nothing in `Mattermost/` was changed by this card.** The audit worktree ends with two uncommitted
*test-file* edits used only to obtain evidence (§5: a cookie-free REST session and one adversarial live
test); they are validation scaffolding, not product code, and are not in this commit. The six mutation
edits this round applied were reverted with `git checkout --` and the worktree's product tree is clean
(`git status --porcelain` shows only those two `MattermostUITests/` files).

Environment for every run: macOS 26.3.1, Xcode 26.6 (17F113), iPhone 16 Pro
`81A7F251-8B31-4945-8783-5A264C14B8D5` (iOS 18.3), Mattermost **9.11.19** (BuildNumber 16643067630,
Docker container `mm-perf`) at `127.0.0.1:8065`, `ActiveSearchBackend=database`. Runs were made with
`scripts/qa-test.py` from the audit worktree, derived data
`~/Library/Developer/Xcode/DerivedData/t55-clean` (outside the TCC-protected folders), source packages
cloned from an existing resolution (`-clonedSourcePackagesDirPath …/mmios-t40r/SourcePackages` — a fresh
resolve hangs on GRDB's SQLiteLib submodule on this network).

**Host load is a first-class caveat, not an excuse**: `uptime` read **load average 140 – 275** during
this round, with two or three other cards' `xcodebuild` UI/unit runs and three booted simulators
concurrently (observed by `pgrep -fl "xcodebuild test"`: T47 on iPhone 16, T48 on iPhone 17 Pro, plus a
full `MattermostTests` Catalyst run). Every red result below was therefore re-run alone; the two that
survived isolation are reported as findings, not as passes.

---

## 1. Verdicts

| Surface | `-AV` that failed | repair | **verdict** | native-by-default recommendation |
|---|---|---|---|---|
| `.threads` (T36) | `t_06222199` F1 wrong order oracle | `t_22341211` | **PASS** | **yes** (thread pane; the `.sidebar` flip stays `t_c93b8337`'s) |
| reactions (T37, inside `.channelView`) | `t_de2110ce` F1 foreign `reaction_added` dropped | `t_cd4723f2` | **PASS-WITH-FINDINGS** | **yes for the reactions surface** — no blocker on F1; F-1/F-2 below are test-robustness items, not product reds |
| attachments (T38, inside `.channelView`) | `t_601158b0` F1 audit target had no T38 | `t_839eda57` | **PASS** | **yes** — F1 closed at the commit level, live suite 4/4 |
| `.search` (T39) | `t_3c83d5e7` F1 `time_zone_offset` in minutes | `t_37a4545b` | **PASS-WITH-FINDINGS** | **yes, conditional on the carded harness fix** — F1 is closed with a live red/green pair, but the shipped live suite cannot sign in on a host whose runner has signed in before (§4.4) |
| `.channelInfo` (T40) | `t_06786ced` F1/F2 writes never hit the wire | `t_995b2a6d` | **PASS** | **yes** — 8/8 live with server-state oracles, and the F1/F2 defect leaves a 5+3-assertion red when reintroduced |

No surface FAILs. Two follow-up cards are filed (§7) for defects in the *deliverables' test harnesses*
found while re-deriving the findings; neither is a product regression.

---

## 2. Runs this verdict rests on

`build/logs/t55/` holds the full `xcodebuild` logs (gitignored);
`docs/t55-evidence-2026-10-27.log` holds the verdict lines extracted from them.

| label | what | result |
|---|---|---|
| `t55-live-a` | T36 + T37 live | T36 **4 run / 0 failed** (140.5 s); T37 **10 run / 7 passed / 3 failed** (430.6 s); suite total 14 run / 9 assertion failures |
| `t55-live-a-retry` | the three T37 failures alone | burst **passed** 46.4 s, composer **passed** 39.3 s, recents **failed** 162.0 s |
| `t55-live-b` | T38 + T39 + T40 live | **19 run / 7 skipped / 0 failed** (380.5 s) — T38 4/4, T40 8/8, T39's 7 skipped on sign-in |
| `t55-live-t39` | T39 alone, attempt 1 | 7 skipped (sign-in) |
| `t55-live-t39b` | T39 alone, attempt 2 (status in the skip message) | 7 skipped, `status 401 api.context.session_expired.app_error` |
| `t55-live-t39c` | T39 alone with a cookie-free REST session | **7 run**: Jump 3/3 (51.9 / 39.6 / 40.0 s), Search 4 run / 2 passed / 2 failed |
| `t55-retry-isolated` | the two T39Search failures + the T37 relaunch test, alone | T39Search **both passed** (43.1 s, 48.4 s); recents **failed** 165.9 s |
| `t55-units-baseline` | T36ThreadViewModelTests, T37SocketReactionRoutingTests, T39SearchTests, T38PreviewFetchLimitTests, T40ChannelInfoTests — unmutated | **132 run / 0 failed / 0 skipped** |
| `t55-mutants` | same classes + four live tests, under the six mutations of §5 | units **83 run / 17 assertion failures in 9 test cases**; live **4 run / 4 failed** |
| `t55-live-all` | the first attempt, kept for honesty | runner failed to initialise ("Timed out waiting for AX loaded notification"), 0 tests — after which the simulator was power-cycled and every later run is listed above |

Server-side probes (no product code, `scripts/…` or scratch, logs in `build/logs/t55/`):

| probe | measurement |
|---|---|
| `t55-t36-order-probe.log` | 6 threads × 3 replies 150 ms apart × 5 reads: **2 of 6** threads answered a newer reply before an older one; **0 of 6** changed its answer between reads. T36-AV F1's premise, reproduced. |
| `t55-tz-separation.log` | `in:t34-showcase on:<day>` at −25200 (seconds) vs −420 (minutes): 2026-10-26 **1 vs 3**, 2026-10-25 **12 vs 10**, 2026-10-27 2 vs 2, 2026-10-24/23 0 vs 0. The seconds/minute distinction is live on this fixture today. |
| `t55-t39-probe.log` | `scripts/t39_search_probe.py --tz-offset-seconds -25200` → **RESULT: PASS** on 9.11.19, *with its own note* that −420 and −25200 agree for `on:2026-10-27` (the newest day no longer separates the encodings — §4.4 finding 2). |
| `t55-t38-mem-refold.log` | `scripts/t38_mem_fold.py` over the committed `docs/t38-mem-probe-2026-10-26.csv`, same window/passes as `docs/t38-build-note.md` §3.1 → output **identical** to `docs/t38-mem-fold-2026-10-26.txt` (`diff` empty). |

---

## 3. Finding → evidence → falsifiability, surface by surface

### 3.1 `.threads` (T36) — verdict PASS

*Original finding* (`t_06222199` F1): the live suite asserted the server's `order` array as the thread's
ordering, and that array is not chronological; the client's create-at sort was right.

*Reproduced the failure mode*: `t55-t36-order-probe.log` — 2 of 6 threads answer a newer reply before an
older one, identically across five GETs. With the old oracle, a correct client reds; with the new one it
does not. The repaired live test now takes its expectation from `create_at` and asserts the drawn rows'
frames increase down the screen (`T36-ThreadsUITests.swift:120-159`), and it attaches the
server-order-vs-chronology comparison instead of asserting the server array.

*Falsifiability*: mutation M1 (§5) restores the server array into `ThreadDerivation.chain` — the exact
regression T36-AV warned a naive "fix" would introduce — and **`testANonChronologicalServerOrderIsDrawnChronologically`
and `testRepliesInTheSameMillisecondAreOrderedById` fail (2 assertions)**.

*Oracle check*: the F2/F4 repairs are the ones that could have been bought with a weaker oracle, and they
were not: the fixture now writes the follow explicitly (`PUT …/following`) and reads
`GET …/threads?per_page=60` **before launching the app**, the unread test asserts the server's own
`unread_replies == 1` and compares the badge label with `entry.unreadLabel`, and both fixture posts are
authored-by assertions against the server's `user_id`. No screenshot or UI echo decides anything.

*Residual*: my live run passed 4/4 but I did not independently re-measure F7 (a native pane no longer
boots the web app behind itself) — the repair's own measurement stands; a second observer of that claim is
still owed. T36's live suite also passed while the host was loaded, which is worth noting because the old
suite did not.

### 3.2 reactions (T37) — verdict PASS-WITH-FINDINGS

*Original finding* (`t_de2110ce` F1): `TeamSocketScope` refused `reaction_added`/`reaction_removed`, and that
scope is the only socket→pane route, so a reaction another client wrote never drew a pill.

*Reproduced the failure mode and its removal*: with the mutation back to `return false` (M2) the live test
`testForeignReactionArrivesOverTheSocketOnce` fails with "the other reader's reaction must arrive over the
socket" (2 assertions), and with the repair in place it passes in 19.6 s; its control
`testForeignPostArrivesButItsReactionDoesNot` passes in 17.2 s. The test's oracle is the other client's own
token writing the reaction and `reactionUserIDs(...)` read back from the server, plus a pill that can only
appear through the socket — not a UI echo of something the app wrote itself.

*Falsifiability at unit level*: M2 reds `T37SocketReactionRoutingTests` with **12 assertions in 4 test
cases**, one of which drives the real `TeamSidebarCoordinator` → `ChannelPaneCoordinator` fan-in. (The repair
claimed "8 assertion failures"; I measure 12 at this commit — the gate bites harder than claimed, which is
the right direction.)

*Findings*:

1. **F-1 (test robustness, carded `t_1f9af95a`)** `testRecentsSurviveRelaunch` is red **3/3** on this host
   (batch 159.8 s, isolation 162.0 s, isolation again 165.9 s). It is **not** a blank app: the failure
   attachment at line 391 catches the tree before the shell exists, but the later snapshot inside the same
   test shows `nativeChannelPane`, `nativeChannelTitle` "T36 Threads" and the post list. The app restored
   the session and the channel after the test's 40 s shell budget had expired under load 250+. The test's
   wait is a fixed 40 s on a launch path that took 60–160 s on this host; it needs a longer, re-armed wait
   and should assert the pane it is actually going to use.
2. **F-2 (test robustness, same card)** the suite is load-sensitive: three of ten tests failed in the
   14-test batch and two of those pass alone. Nothing in the product changed between those runs.
3. The reaction *list* (reactor sheet) assertion is a UI label (`'T36 Reply @t36reply'` / `'Perf Probe (you)
   @perfprobe'`) with the server's member data as its input; it passed live, and the server read
   (`reactionUserIDs`) is what the write assertions use. Acceptable, but it is the one T37 assertion that is
   a UI echo rather than a server read.

### 3.3 attachments (T38) — verdict PASS

*Original finding* (`t_601158b0` F1): the audit target contained no T38 at all.

*Closed at the commit level*: `git ls-tree --name-only HEAD -- Mattermost/UI/Native/Files/` lists all seven
files (`AttachmentDownloads`, `AttachmentImageStore`, `AttachmentModels`, `AttachmentViews`,
`FilePreviewView`, `FileTypeMap`, `ImageViewer`), and every repair commit (`818264d`, `7e9cab3`, `f16bb54`,
`b807a6f`) is an ancestor of 634afd9. On the audit target, not on a worktree snapshot.

*F2 (memory criterion)*: the full 40-image probe was **not** re-run this round; instead I re-folded the
committed raw samples with the committed fold script and the exact window/passes from the build note — the
output is byte-identical to `docs/t38-mem-fold-2026-10-26.txt`. That checks the arithmetic behind the
claim, **not** the measurement itself. Re-measuring it is still the only way to close F2 to my standard,
and this note says so rather than inheriting the repair's number as mine.

*Live*: the suite is 4/4 with no skips (`testATenImagePost…` 56.5 s, `testSavingAGalleryImage…` 26.8 s,
`testTheFileRows…` 43.1 s, `testAnHTMLAttachmentIsRefused…` 20.8 s), on the real fixture channel
(`t38-files`, seeded idempotently with `scripts/t38_attachment_seed.py` before the run).

*Finding (F-3, oracle weakness, no card)*: the F5 fetch-limit oracle is partly self-referential.
`T38PreviewFetchLimitTests` builds its "past the limit" case as `FileTypeMap.previewFetchByteLimit + 1`, so
mutation M4 (32 MB → 4000 MB) only reds the **explicitly sized** `testAPDFPastTheFetchLimitIsRefusedToo`
(120 MB): 1 assertion. The text case keeps passing because both sides of the assertion moved with the
constant. A limit change would therefore be caught, but a *silent* widening by a factor of 125 is caught by
one test only. Worth fixing when the file is next touched; not a reason to withhold the surface.

### 3.4 `.search` (T39) — verdict PASS-WITH-FINDINGS

*Original finding* (`t_3c83d5e7` F1): `time_zone_offset` was sent in **minutes** where the API reads
**seconds**, so `on:`/`before:`/`after:` evaluated against a UTC day.

*Live, falsifiable, both directions*:

* Repaired tree: `T39JumpUITests/testOnDateModifierSendsTheTimezoneOffsetInSeconds` passes (39.6 s) and my
  own adversarial test on a fixed day the fixture separates — `in:t34-showcase on:2026-10-26`, where the
  server answers **1** post at −25200 s and **3** at −420 — passes in 40.0 s, i.e. the screen shows the
  reader's day.
* Mutation M3 (`body()` sends `timeZoneOffsetSeconds / 60`, the shipped defect): the same live test fails
  with `("3") is not equal to ("1") — the screen shows 3 for in:t34-showcase on:2026-10-26; seconds reads 1,
  minutes reads 3`. That is the original failure mode, reproduced on the repaired tree by reintroducing the
  bug, and it is red for the right reason.
* Unit pins: M3 also reds `T39SearchTests` with 2 assertions, including the request-body key.

*Findings*:

1. **F-4 (carded `t_c3957991`)** T39's two live suites could not sign in **at all** on this host, three
   attempts in a row: every test skipped with `status 401 api.context.session_expired.app_error` on
   `POST /users/login`. Cause: both helpers use `URLSession.shared`, whose cookie jar still holds an
   `MMAUTHTOKEN` from an earlier sign-in in the same runner container, and Mattermost answers a login that
   carries a dead session with 401. T36-R and T40-R already use a cookie-free ephemeral session for exactly
   this reason (`T40ChannelInfoUITests.swift:956-965`); T39 never adopted it. With that one change made
   **in the audit worktree only**, the suite signs in and the seven tests measure (results above). The
   shipped suite therefore reports "no evidence" on any host where any test has signed in before — this is
   the single most important thing to fix before the `.search` verdict is used, and it is why the flip
   recommendation is conditional.
2. **F-5 (no card, documented)** the shipped offset test anchors on the **newest** post's day, and that day
   no longer separates the two encodings (`t55-tz-separation.log`: `on:2026-10-27` answers 2 posts both
   ways), so the test can silently `XCTSkip` — the skip path is deliberate, but it means "green" can mean
   "not measured". My fixed-day test (audit-only) covers the gap; the durable fix is to anchor on a day the
   probe has shown to separate, as upstream's own fixture does.
3. Two of the four `T39Search` tests failed in the loaded batch (`neither the toolbar nor a tab opens
   search`; `loginIDField … no longer valid after interruption handling` — the app was still on the sign-in
   screen) and both pass alone in 43.1 s / 48.4 s. Environment, not product; recorded because the batch
   result must not be read as four passes.

### 3.5 `.channelInfo` (T40) — verdict PASS

*Original finding* (`t_06786ced` F1/F2): the add-member submit and the settings save never put a request on
the wire — the model was held in a plain `@State`, which never observes an `ObservableObject`, so the
buttons stayed disabled and no write could leave the app.

*Reproduced and removed*: the live suite is **8 run / 0 skipped / 0 failed** on this host (add 34.3 s,
  non-admin 19.7 s, archive/unarchive 36.2 s, browse/join 35.9 s, info 23.1 s, leave 25.0 s, settings
  28.0 s, socket reconcile 30.6 s). Its oracles are server reads made by the test process — `memberIDs()`
  through `GET /channels/{id}/members` with the explicit note "the app is not the oracle", and
  `GET /channels/{id}` re-read for purpose and header — not screenshots.

*Falsifiability*: M5/M6 put the picker and the settings draft back into `@State` (the shipped defect) and the
live tests red exactly where the `-AV` found it:

* add member: **5 assertions**, beginning "one row tap must enable the Add button; it says \"Add 0
  members\"" and including "the add must reach the server (the app is not the oracle)";
* settings save: **3 assertions** — Save stays disabled, then purpose and header never reach the server.

*Residual*: the wire-witness relay log (`build/logs/t40r-relay-suite10.txt`) is gitignored and its run is
correctly excluded as a verdict by the repair; I did not rebuild it. The live suite's server reads are the
same fact from the other end, and they are reproducible.

---

## 4. Mutation evidence (the falsifiability requirement)

Six one-line mutations, applied together in the audit worktree on top of 634afd9, then reverted
(`git checkout --`; `git status --porcelain` clean for `Mattermost/`).

| # | mutation (file) | what it restores | measured red |
|---|---|---|---|
| M1 | `Thread/ThreadModels.swift` — `chain` returns `[root] + dedupe(accepted)`, no chronological sort | the server's `order` array as the chain | `T36ThreadViewModelTests`: **2 assertions in 2 test cases** (incl. `testANonChronologicalServerOrderIsDrawnChronologically`) |
| M2 | `Sidebar/TeamSocketScope.swift` — reaction case returns `false` | T37-AV F1's gate | `T37SocketReactionRoutingTests`: **12 assertions in 4 test cases**; live `testForeignReactionArrivesOverTheSocketOnce`: **2 assertions** |
| M3 | `Search/SearchGrammar.swift` — `timeZoneOffset: timeZoneOffsetSeconds / 60` | T39-AV F1 (minutes) | `T39SearchTests`: **2 assertions**; live fixed-day offset test: **1 assertion** ("screen shows 3 … seconds reads 1, minutes reads 3") |
| M4 | `Files/FileTypeMap.swift` — `previewFetchByteLimit` 32 MB → 4000 MB | the post-allocation-only bound F5 removed | `T38PreviewFetchLimitTests`: **1 assertion** (only the explicitly sized 120 MB case — see F-3) |
| M5 | `ChannelInfo/AddMembersView.swift` — `@ObservedObject var picker` → `@State` | T40-AV F1 | live `testAddingAndRemovingAMemberReachesTheServer`: **5 assertions** |
| M6 | `ChannelInfo/ChannelSettingsView.swift` — `@ObservedObject var form` → `@State` | T40-AV F2 | live `testPurposeAndHeaderPersistOnTheServer`: **3 assertions** |

The unmutated baseline for the same four unit classes and the same live tests is §2
(`t55-units-baseline` 132/0; `t55-live-a`, `t55-live-b`, `t55-live-t39c` green). Every mutation reds
something a repair claims would red — except M4, which reds less than the repair's wording implies.

---

## 5. Validation scaffolding that is **not** in this commit

Two edits were made to the audit worktree's UI tests to obtain the evidence, and only there:

1. `T39JumpUITests.swift` / `T39SearchUITests.swift`: `URLSession.shared` → a cookie-free ephemeral
   `restSession` (§3.4 F-4), plus the status code and body added to the sign-in skip message that produced
   the 401 diagnosis.
2. `T39JumpUITests.swift`: one adversarial test, `testT55OnDateOffsetOnAFixtureDayThatSeparates`, which asks
   the same question as the shipped test on a day the fixture separates (`2026-10-26`).

They are described in full in the carded follow-up `t_1f6c0a41` so the fix can land properly rather than as
a QA worktree patch.

---

## 6. Isolation from the neighbours' in-flight work

The operator flagged that the shared checkout was being actively edited at 19:33 (T47 owns
`CreateChannel*`, `NewDirectMessageView`, `T47CreateChannel*`; T48 owns `PostOptions*`, `T48PostOptions*`;
shared files include `ChannelViewModel.swift`, `ChannelView.swift`, `ThreadViewModel.swift`,
`PostRowView.swift`, `SocketEvent.swift`, `ChannelSidebarService.swift`, `ChannelPaneCoordinator.swift`).

* Every run in §2 was made in a **detached worktree at 634afd9** (`git rev-parse HEAD` = 634afd9 in that
  worktree; its `git status` shows only the two test files of §5). The shared checkout's uncommitted files
  are not in that worktree at all, and `project.pbxproj` there is the committed one.
* The only red results in this round that were not host-load artefacts are inside my five surfaces, and each
  is named with its file: `MattermostUITests/T37-ReactionsUITests.swift` (recents, F-1) and
  `MattermostUITests/T39SearchUITests.swift` / `T39JumpUITests.swift` (sign-in cookie jar, F-4).
* No result here is attributed to T47/T48's files, and no card is filed against their work.

---

## 7. Cards filed from this round

* `t_c3957991` (mmios-ios) — **T39-R2**: the two T39 live suites must use a cookie-free REST session; today
  every test skips with 401 `session_expired` after any earlier sign-in in the runner. Includes the measured
  reproduction, the three logs, and the exact change (T40's `restSession` pattern) plus the fixed-day anchor
  for the offset test (F-5).
* `t_1f9af95a` (mmios-ios) — **T37-R2**: the recents-after-relaunch test's 40 s shell wait is too short on a
  loaded host (3/3 red, app restored after the budget), and the suite should re-arm its waits; it must not
  be read as a product failure, and it must not be left green-by-luck either.

---

## 8. What this round does **not** cover

* **`.sidebar`** — parked in `t_c93b8337` behind the human gate `t_4413b7b2`; nothing here bears on it.
* **`.composer`** (T35), **`.profile`** (T41), **`.activity`** (T42), **`.calls`** (T44/T44d) — untouched by
  this card, whatever their parity rows say.
* **The render registry.** `nativeApprovedSurfaces` is not flipped by this card; `.channelView` and
  `.sidebar` remain owner decisions (`t_c93b8337` for the sidebar; `.channelView` is separate). Four of the
  five surfaces validated here mount inside `.channelView`, so this note is the evidence that decision needs
  — it is not that decision.
* **Not re-measured this round**: T38's 40-image memory probe (re-folded only, §3.3), T36's F7
  web-app-behind-the-pane measurement, the T40 relay wire witness, any real-device/APNs path (no device and
  no APNs on this host), and `Load more results` on a database-backend search server (structurally
  unprovable — the server ignores `page`/`per_page`).

## 9. Bottom line

All five repairs close the findings they were opened for, and each closure is falsifiable: reintroducing the
defect reds the exact test the repair points at (17 unit assertions and 11 live assertions across six
mutations). The two things that keep this from being a clean five-for-five are in the deliverables' live
harnesses, not in the product: T39's cookie-carrying REST helper makes its live evidence unobtainable on this
host (carded, and worked around here to obtain the evidence anyway), and T37's relaunch test is tuned to a
quiet host (carded). One oracle weakness is recorded but not carded — T38's fetch-limit test moves with the
constant it is supposed to bound.
