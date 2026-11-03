# T47-AV-R2-FU — the add-people picker offered deactivated teammates

Card: `t_e65e6018`, filed by `t_4067a703` (§4 of `docs/t47-av-r2-note.md`) because the DM picker's
repair was scoped to that surface. Worktree: `~/.hermes/kanban/boards/mattermost-ios/workspaces/
t_e65e6018/wt`, branch `t47fux`.

The work was cut from `origin/main` = `bde77c5`, paused (reclaimed), and resumed after the tree had moved
on: it is now rebased onto `origin/main` = `66ea335` — one commit, `309fa43`, which carries the fix and
both tests. The rebase applied cleanly; the only overlap was `MattermostTests/T40ChannelInfoTests.swift`,
where T52 (`911d694`) had changed the `offeredActions` expectations in the permission tests and this card
adds a new test at the end of the class: different methods, no conflict, and both sets of assertions run
in the same 50-test class below.

Fixture: Mattermost 9.11.19 on `http://127.0.0.1:8065`, account `perfprobe` (password in
`scripts/perf_seed.py`). Simulator: `T47FUXW iPhone 17 Pro` (iOS 26.5, `118EBD7B-…`), the card's own
device, with a private derived-data dir (`~/Library/Developer/Xcode/DerivedData/t47fux-dd`).

---

## 1. What changed

### The filter, at the one place both reads meet

`AddMembersViewModel.absorb` (`Mattermost/UI/Native/ChannelInfo/AddMembersViewModel.swift:206`) now drops
`deleteAt != 0`:

```swift
rows = users
    .filter { $0.deleteAt == 0 && !selectedIDs.contains($0.id) }
    .map { user in Candidate(id: user.id, …) }
```

Both reads of the sheet go through `absorb` — the opening list (`GET /users?in_team=&not_in_channel=`)
and the typed search (`POST /users/search` with `not_in_channel_id`) — so the two lists inside one sheet
can no longer disagree about who exists. The file header states the rule beside the two upstream rules it
already documented.

Re-measured on 2026-11-04 with `scripts/t_e65e6018_probe.py` (read-only; `per_page=50`, the size the app
sends):

```
team Perf (ocz148uck3r88dcjikj497bosh)
channels visible to perfprobe: 359; t40-standup present: True

#t40-standup (eu5tcwy7z3ghich67ifk5us53a)
  opening list rows=15 active=14 deactivated=1 -> [('t429gone', 'dgsywreb67bs8p6s9eu8w8fskw', 1793303134446)]
  order (usernames): ['probeone832551', 't36avb93601', …, 't429gone', 't42buddy', …, 't48av-restricted']
  last active row in server order: t48av-restricted 6b64cdkbspbddef8w9zsbz8jwe
  search term 't429g': rows=0 contains deactivated=False

#perf-feed (71jj7bz8rbrjbq7szjw9amzoqa)
  opening list rows=16 active=15 deactivated=1 -> [('t429gone', …)]
  search term 't429g': rows=0 contains deactivated=False
```

That is the sibling of T47-AV-R2's F3 asymmetry, confirmed again on 9.11.19: the list endpoint returns
the deactivated account, the search endpoint (sent `allow_inactive: false`) does not.

### A unit test on the derivation

`MattermostTests/T40ChannelInfoTests.testPickerDoesNotOfferADeactivatedTeamMemberInEitherRead` drives the
real view model through `FakeChannelInfoService` and pins three things: the opening list keeps the live
people and drops the deactivated one (server order preserved), the typed search is filtered too — the
fake is handed a deactivated row on purpose, so the sheet does not depend on the server remembering
`allow_inactive` — and clearing the term returns the live list (the filter drops an account, not the
list).

### A live assertion that fails if the filter goes away

`MattermostUITests/T40ChannelInfoUITests.testTheAddPickerDoesNotOfferADeactivatedTeamMember` (section 2b
of the file) opens a real channel's add-members sheet against the live server and asserts:

1. the oracle is the endpoint the picker itself calls; the deactivated account is in the server's answer,
   and the server's own typed search excludes it (the asymmetry is re-proved before anything is claimed
   about the app);
2. the opening list **sweeps to its last row** (the oracle's last active row; `absorb` does not sort, so
   that is the last row the picker draws once deactivated accounts are filtered) and the deactivated
   row is looked for after every swipe — absence over a sweep proved to have reached the end, not a
   snapshot;
3. typing the account's own username shows the picker's empty state and no row for it.

### The other add-members live test now reaches the picker

`testAddingAndRemovingAMemberReachesTheServer` is this file's add/remove test and it opens the picker
this card changed, but it reached the channel with `openChannel` — the sidebar scroll — and that helper
gives up after 25 swipes. Measured on this tree, the full suite's first run:

```
t47fux-live-suite-rb: T40ChannelInfoUITests.swift:896: error:
  -[testAddingAndRemovingAMemberReachesTheServer] : XCTAssertTrue failed - the sidebar must list
  #t40-standup:
  … then: Failed to tap "channelSidebar.channel.eu5tcwy7z3ghich67ifk5us53a" Any: No matches found
```

That is the fixture, not the product: #t40-standup is one of 359 channels in Perf (`T8G probe 0071` …
in the accessibility tree), so its row is dozens of swipes down. The test now opens the channel through
the sidebar's own **quick switcher** (`channelSidebar.quickSwitcher` → `…result.<channelID>`) — the
helper this card added for its own test, and what a reader with a long sidebar actually uses. It passes
(§2.2), so the picker's write path is exercised on the repaired tree rather than skipped.

No write is performed by the new test: it never taps a row, so it leaves no membership behind.

---

## 2. Measurements

All of these are on the final tree: `66ea335` (origin/main) + `309fa43` (this card), iOS simulator
`118EBD7B` with `--derived-data …/t47fux-dd`.

### 2.1 Units

```
python3 scripts/qa-test.py --platform ios --sim id=118EBD7B-… --derived-data …/t47fux-dd \
  --only-testing MattermostTests/T40ChannelInfoTests --label t47fux-units-rb
# -> 50 run, 0 skipped, 0 failed, 159 s                RESULT: PASS (build/logs/t47fux-units-rb.log)
#    testPickerDoesNotOfferADeactivatedTeamMemberInEitherRead … passed (0.004 s)
```

The class was 49 tests before this card (and T52 had already moved its `offeredActions` expectations);
the new one makes 50, and it is in the run.

### 2.2 Live, the repaired behaviour

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe … \
  python3 scripts/qa-test.py --platform ios --sim id=118EBD7B-… --derived-data …/t47fux-dd \
  --only-testing MattermostUITests/T40ChannelInfoUITests/testTheAddPickerDoesNotOfferADeactivatedTeamMember \
  --label t47fux-live-rb1
# -> 1 run, 0 skipped, 0 failed, 86 s                  RESULT: PASS (build/logs/t47fux-live-rb1.log)
#    T47-AV-R2-FU: deactivated @t429gone (dgsywreb67bs8p6s9eu8w8fskw) absent over a 1-swipe sweep;
#                  last row 6b64cdkbspbddef8w9zsbz8jwe reached
```

One swipe reached the end because the filtered list is 14 rows on this fixture; the sweep's own
precondition (the oracle's last active row on screen) is what makes the single swipe sufficient.

```
  --only-testing MattermostUITests/T40ChannelInfoUITests/testAddingAndRemovingAMemberReachesTheServer \
  --label t47fux-live-addremove-rb
# -> 1 run, 0 skipped, 0 failed, 74 s                  RESULT: PASS
#    (build/logs/t47fux-live-addremove-rb.log — add lands on the server, picker closes, member list
#     shows the row, Remove reaches the server)
```

### 2.3 Mutation — is the change load-bearing?

Mutation: the filter deleted from `absorb` (`.filter { !selectedIDs.contains($0.id) }`), applied, run,
reverted (`git status` clean after both runs).

**Unit, iOS, final tree** (self-contained: no server involved)

```
# -> 50 run, 0 skipped, 3 failed                       RESULT: FAIL (build/logs/t47fux-mut-units-rb.log)
T40ChannelInfoTests.swift:1047: XCTAssertEqual failed: ("[\"u1\", \"gone\", \"u2\"]") is not equal to
  ("[\"u1\", \"u2\"]") - the opening list must not offer deactivated @t429gone — the server's
  GET /users?in_team=&not_in_channel= does, and the sheet cannot offer an account the typed search
  hides (rows: ["u1", "gone", "u2"])
T40ChannelInfoTests.swift:1053: XCTAssertTrue failed - the typed search must not offer deactivated
  @t429gone either — one sheet cannot hold two populations (rows: ["gone"])
T40ChannelInfoTests.swift:1060: XCTAssertEqual failed: ("[\"u1\", \"gone\", \"u2\"]") …
```

**Live, iOS, final tree** (the same mutated source, live server)

```
# -> 1 run, 0 skipped, 1 failed                        RESULT: FAIL (build/logs/t47fux-mut-live-rb.log)
T40ChannelInfoUITests.swift:347: XCTAssertFalse failed - the opening list must not offer deactivated
  @t429gone — the typed search already hides them, and the two lists cannot disagree inside one sheet
  (swipes: 1, last row reached: 6b64cdkbspbddef8w9zsbz8jwe):
```

The live failure is at the intended sentence, and the same run proves the sweep had reached the last row
(`last row reached: 6b64…jwe`), so the red is the deactivated row being drawn, not a truncated sweep.

### 2.4 The full UI suite was attempted, and what it showed

`--only-testing MattermostUITests/T40ChannelInfoUITests` on the final tree: the first test
(`testAddingAndRemovingAMemberReachesTheServer`) failed on the sidebar helper (§1) — a harness defect,
already recorded as a follow-up in the parent card. That test is now repaired and green. The run was
stopped in the third test to stop burning the shared fixture; **the rest of the file was not measured on
this tree**, and the third test's failure under a killed runner is not evidence about anything. The two
tests this card touches are the two measured above.

---

## 3. What is proven, and what is not

**Proven.** The add-people picker's opening list and its typed search offer the same population, and the
deactivated account is in neither: the live test sweeps the real list to its last row on the live server,
finds no `addMembers.row.<t429gone>`, and the typed search shows the empty state. The add/remove path
through the same picker still works end to end against the server. Removing the filter turns the unit
test red at three assertions and the live test red at the sweep assertion, both on the published tree
(§2.3). The whole `T40ChannelInfoTests` class is green on the published tree (50/50, iOS; §2.1).

**Not proven — stated rather than implied.**

- **The rest of `T40ChannelInfoUITests` was not re-run** (§2.4). The file's other tests still navigate
  with the sidebar helper and hit the same fixture-size defect; that is a harness repair, not part of
  this card.
- **A page past the first was not measured live.** The filter sits in `absorb`, which every page passes
  through, so a later page cannot leak a deactivated account by construction — but the fixture's list is
  15 rows against a 50-row page, so a live second page does not exist here.
- **No attempt was made to *add* a deactivated account** (the server would accept it; that is why the
  guard is client-side). Neither test writes with the deactivated account.
- **The T45 accessibility manifest was not regenerated** (it was already stale from other cards; the new
  test draws no new identifiers beyond the ones already in the file).

---

## 4. Follow-ups this card does not take

- The **sidebar scroll** helper (`openChannel`, `revealSidebarRow`, 25 swipes) is too short for a team with
  359 channels. Two of this card's live runs were spent on it. The quick switcher is the way round it
  (`openChannelViaSwitcher` here); pulling it into `ShellSettle` and switching the rest of the file to it
  is the durable repair.
- The **simulator launch wedge** under host load (pre-existing; T47-AV-R2 recorded two lost runners) cost
  the previous attempt eight runs. A warm-device pre-flight (`probe/live_warm_device.sh` in this card's
  workspace) is the workaround; a shared helper in `scripts/qa-test.py` would be the fix.

---

## 5. Publish

The publish commit (this note's final revision) and the assertion
`git ls-remote origin refs/heads/main` == local `git rev-parse HEAD` are recorded in the card's closing
comment, because a commit cannot name its own SHA. Code commit: `309fa43` on `66ea335`.
