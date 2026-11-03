# T47-AV-R2 — the DM picker's three honesty gaps

Card: `t_4067a703` (T47-AV-R2), filed by `t_e1ddfba4` from `docs/t47-av-verdict.md` §1.3, §2, §3
(mutation row 4), §6 (F2, F3, F5). Worktree: `…/kanban/boards/mattermost-ios/workspaces/t_4067a703`,
branch `t47avr2`, cut from `origin/main` = `4cd5bdc` and published on top of `0a4800e` (after
`2c3b7f1`/`d4aadac` and `ff1f907` landed) — see §2 for what each rebase forced.

Fixture: `mm-perf` (Mattermost 9.11.19) on `http://127.0.0.1:8065`, account `perfprobe` (password in
`scripts/perf_seed.py`), restricted probe account `t47av-restricted` (password in
`scripts/t47_av_probe.py:47`). Simulator: a device of this run's own,
`T47AVR2 iPhone 16 Pro` (`4844768F-1CDA-437F-A397-F1066C010201`, iOS 18.3), because the host was running
three other cards' builds at the same time and the shared simulator lost its test runner twice
(`Mach error -308`, and one `BUILD INTERRUPTED`) before this isolation. Builds used a private derived
data dir (`~/Library/Developer/Xcode/DerivedData/t47avr2-dd`), not the shared
`mattermost-ios-qa` one.

**Fixture correction.** The card says "ops team has a deactivated member". Measured today
(`scripts/t47_avr2_probe.py`): **Ops has 9 active members and none deactivated**; the deactivated
member is in **Perf**, the account this run's oracle uses —
`@t429gone` (`dgsywreb67bs8p6s9eu8w8fskw`, `delete_at 1793303134446`), Perf being `GET
/users/me/teams[0]` for `perfprobe`.

---

## 1. What changed

### F2 — "Unknown" is never rendered (`Mattermost/UI/Native/ChannelInfo/NewDirectMessageView.swift`)

The row drew `statusLabel` only when `!candidate.status.isEmpty`, so the one presence a reader most
needs named — the server answered nothing — drew nothing, while
`testThePickerCarriesPresenceAndSaysUnknownRatherThanOffline` kept pinning a property no view read
(§3 mutation row 4 of the verdict).

- the presence is now **always** drawn (`Text(candidate.statusLabel)`, no empty check), and carries its
  own identifier `newDM.status.<userID>`;
- the row's explicit `.accessibilityLabel(candidate.displayName)` is gone, and the label is what the row
  draws (`.accessibilityElement(children: .combine)`). That is deliberate: an explicit label would have
  let the drawn text be deleted while the spoken label stayed, which is the shape of F2. Now the
  presence cannot leave the accessibility tree without leaving the screen;
- `DirectMessageCandidate.statusLabel` is documented as never empty ("a presence the server did not
  answer is `Unknown`, never `Offline` and never nothing").

### F3 — the opening list offered deactivated accounts (`CreateChannelModels.swift`)

`DirectMessageDerivation.rows` now filters `deleteAt == 0`. That is the single funnel both reads pass
through (`GET /users?in_team=` for the opening list, `POST /users/search` for a typed term), so the two
lists inside one sheet now agree about who exists. Measured on the fixture: the opening list returns
`@t429gone`; the search is sent `allow_inactive: false` and does not.

### F5 — a failed principal read offered the reader (`CreateChannelViewModel.swift`)

`principal()` was `try?`-swallowed, so `myUserID` stayed nil, the self-row filter did nothing, the
signed-in reader was offered in their own list — and the failure was reported as "signed out" even when
the cause was the network.

- `ensurePrincipal()` reads `GET /users/me` once per load (`load()` **and** `search()`), and a throw is
  no longer swallowed; an answer without an id becomes `MMError.unauthorized`;
- a failed read now **builds no list at all** (`abandon(with:)` drops `rows`, `users` and `myUserID`),
  so the reader cannot appear by omission;
- the sentence names the cause it saw (`NewDirectMessageViewModel.copy`): offline / timeout /
  session expired / forbidden each have their own words;
- `newDM.retry` (already drawn in the `.failed` state) re-runs `load()`, and the identity is read again
  rather than remembered as nil.

---

## 2. Measurements

Everything below was run on the **final** tree: this card rebased onto `origin/main`, which moved three
times under it while it ran — `2c3b7f1` (T47-AV-R4) + `d4aadac` (T47-AV-R3), then `ff1f907` (T47-AV-R1),
then `0a4800e` (T50, profile editing). Each rebase was re-verified, not assumed: units and the live
suite were re-run after every one, and the numbers quoted here are the last run on the last tree.

```
git log --oneline -5        # final tree
  f6ffabb test(t47-av-r2): the merged fake keeps one principalFailure, and the note carries the final run
  563152d docs(t47-av-r2): the probe ships with the note …
  916f6f1 docs(t47-av-r2): the picker repair's measurements, its two mutations, and what is not proven
  4e7006e fix(channelInfo): the DM picker says Unknown, offers no deactivated account, and never offers the reader
  0a4800e feat(profile): T50 the reader can edit their own name, picture and profile fields (t_44721717)
```

The merge with T47-AV-R1 needed one fix: both cards added a `principalFailure` knob to the test fake
(`FakeCreateService`), and the merged file did not compile until the duplicate was removed
(`t47avr2-units-final2.log:286: invalid redeclaration of 'principalFailure'`). That is recorded because
the first post-rebase unit run is in the log as a **build failure**, not a test result. The T50 rebase
needed nothing.

Units, final tree (private derived data, own simulator):

```
python3 scripts/qa-test.py --platform ios --sim id=4844768F-… --derived-data …/t47avr2-dd \
  --only-testing MattermostTests/T47CreateChannelTests --label t47avr2-units-final4
# -> 46 run, 0 skipped, 0 failed                                  RESULT: PASS   (build/logs/t47avr2-units-final4.log)
```

46 = the AV's 34 originals + this card's 5 (`testThePickerDoesNotOfferADeactivatedTeamMember`,
`testThePickerDoesNotBuildAListWithoutThePrincipal`,
`testThePickerNamesAnExpiredSessionRatherThanANetworkFailure`,
`testThePickerTreatsAnEmptyPrincipalAsSignedOut`, `testThePickerRetriesTheLoadOnceThePrincipalReads`) +
T47-AV-R3's 2 + T47-AV-R1's 5. With only this card on `2c3b7f1` the class was 41 run / 0 failed
(`t47avr2-units-rebased.log`); `testThePickerCarriesPresenceAndSaysUnknownRatherThanOffline` also gained
the "never empty" assertions.

Live, the flipped test alone (the repaired behaviour, first measurement on the pre-rebase tree):

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe … \
  python3 scripts/qa-test.py … --only-testing MattermostUITests/T47CreateChannelAVUITests/testThePickerDoesNotOfferADeactivatedTeamMemberThatSearchHides --label t47avr2-ui-t2a
# -> 1 run, 0 skipped, 0 failed, 59.7 s                            RESULT: PASS   (build/logs/t47avr2-ui-t2a.log)
```

The test was renamed from `testThePickerOffersADeactivatedTeamMemberThatSearchHides`: the old name
described the behaviour it recorded, and the recorded behaviour is gone. The old name is still in
`docs/t47-av-verdict.md` §1.3, which is the parent card's record of the run it made — not rewritten
here.

The test reads the team the app is actually on off the rail (`teamSidebar.team.<id>`'s accessibility
value says "Current team") and switches to the oracle's team when they differ — the F7 class of
mismatch, not repaired here (that is T47-AV-R4's card) but kept out of this test's way.

Live, the whole suite (the card's fourth acceptance point), final tree:

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=… TEST_RUNNER_MM_AV_RESTRICTED_LOGIN=t47av-restricted \
TEST_RUNNER_MM_AV_RESTRICTED_PASSWORD=… \
  python3 scripts/qa-test.py --platform ios --sim id=4844768F-… --derived-data …/t47avr2-dd \
  --only-testing MattermostUITests/T47CreateChannelAVUITests --label t47avr2-ui-final1
# -> Executed 6 tests, with 2 tests skipped and 0 failures (0 unexpected) in 199.317 s   RESULT: PASS
#    testTheServerRefusesACreateAfterTheTeamRoleIsRevoked            passed (20.197 s)
#    testThePickerDoesNotOfferADeactivatedTeamMemberThatSearchHides  passed (25.642 s)
#    testAHalfTypedDraftDoesNotSurviveARelaunchAndNothingIsSent      passed (35.062 s)
#    testOpeningTheSameConversationTwiceFindsOneChannel              passed (117.902 s)
#    testTheCreateMenuAppearsWhileTheThreadsReadIsStalled            SKIPPED (needs TEST_RUNNER_MM_AV_STALL_SERVER)
#    testAFailedPermissionReadOffersARetryThatActuallyReloads         SKIPPED (needs TEST_RUNNER_MM_AV_PERMISSION_SERVER)
#    T47-AV-R2: deactivated @t429gone (dgsywreb67bs8p6s9eu8w8fskw) absent over a 1-swipe sweep;
#                last active row 74gs84fwhb85mdpfqjzuku6hsr reached
#    T47-AV-R2: first row zph6uw3t6if69p89wcihf1nd5c reads "Cleo Busy, @t41av3, Do not disturb";
#                the server says "Do not disturb"
#    (build/logs/t47avr2-ui-final-0a4800e.log:824, :793, :798, :929)
```

That is the run labelled `t47avr2-ui-final1` on the final tree; it was copied to
`t47avr2-ui-final-0a4800e.log` because the retry wrapper reuses attempt numbers, which overwrote the
label's first log (an earlier green on `ff1f907`, same 4 passed / 2 skipped, 196.6 s). Every
"`t47avr2-ui-final1`" run since has been green; the copy is the one the line numbers above point at.

The suite is six tests now, not four: T47-AV-R1 added the two proxy-backed ones, and they skip unless
its fixture proxy is running (they are R1's measurement, published in `docs/t47-av-r1-repair.md`). The
card's four are the four `passed` lines above.

Attempts that are **not** counted as measurements of this change, kept in the log for what they are
(the host carried three or four other cards' simulator builds throughout — load average 488–1003,
measured):

| log | outcome | cause |
|---|---|---|
| `t47avr2-ui-suite.log` | 4 run, 1 skipped, 4 failures | `+` menu drew no row / sheet never mounted; test 1 skipped because the restricted credentials reach a UI test only as `TEST_RUNNER_MM_AV_RESTRICTED_*` |
| `t47avr2-ui-suite-b.log` | 3 failures | the above plus one lost login keystroke (`Failed to tap loginIDField TextField: Timed out while synthesizing event`) |
| `t47avr2-ui-suite-attempt1.log` | 4 run, 0 failed, 527.8 s | **green**, pre-rebase tree (`2c3b7f1`) |
| `t47avr2-ui-suite-rebased1.log` | 4 run, 1 failure | my test died in `signIn` with `Unable to monitor event loop` — the automation session, not the test |
| `t47avr2-ui-suite-rebased2.log`, `…rebased3.log` | 4 run, 1 failure each | `testOpeningTheSameConversationTwiceFindsOneChannel` lost the create menu's row under load (F1, fixed by R1 after these runs) |
| `t47avr2-ui-suite-rebased4.log` | aborted | this card rebased onto R1's publish instead of finishing a run against a tree that was about to be replaced |

### Mutations — is the flipped test load-bearing?

| mutation (applied, run, reverted) | expected | measured |
|---|---|---|
| `.filter { $0.deleteAt == 0 }` removed from `DirectMessageDerivation.rows` | the opening-list assertion fails | **red** — `the opening list must not offer deactivated @t429gone … (swipes: 1, last row reached: 74gs84f…2011)` (`t47avr2-mut-a2.log`, 1 run / 1 failed) |
| the row's whole presence branch deleted from `NewDirectMessageView` | the presence assertion fails | **red** — `the row must state its presence ("Do not disturb"); it reads "Cleo Busy, @t41av3"` (`t47avr2-mut-b.log`, 1 run / 1 failed, 120 s) |

The second row is the one the AV could not get: at `8643fbf` deleting the same branch left all 34 unit
tests green (verdict §3, mutation row 4). The same mutation is now red **on the live test**, and the
label it printed — `"Cleo Busy, @t41av3"` instead of `"Cleo Busy, @t41av3, Do not disturb"` — is the
proof that the spoken label is the drawn text, not a parallel property.

One earlier attempt at mutation (a) (`t47avr2-mut-a.log`) is **not** counted: it failed for a harness
reason, not the assertion — the `+` menu drew no "create direct message" row and the sheet never
mounted (`the create menu must offer nativeSidebarCreate.createDirectMessage`). That is the F1
flakiness the parent card already recorded (the create model is starved behind the threads read), and
it reappears under load; the retry above is the measurement.

---

## 3. What is proven, and what is not

**Proven.** The opening list and the typed search now agree (live: the deactivated row is absent over a
full sweep that is proved to have reached the end of the list, and typing the account's own username
still yields the empty state). Every drawn row states its presence and the spoken label carries it
(live, and the deletion mutation is red). A picker that cannot learn who "me" is builds nothing and says
which failure it saw, with a retry that works (unit).

**Not proven — stated rather than implied.**

- **"Unknown" on screen was not witnessed on this fixture.** Every member of Perf has a status row, and
  `POST /users/status/ids` answers `offline` for a user who has never connected, so a live user with *no*
  status cannot be produced on this server. What is pinned is: the label is drawn unconditionally (no
  empty-string branch remains — mutation (b) shows the drawn text is the only source of the row's
  label), and the mapping is "Unknown" for anything outside the four server statuses (unit). A stub
  fixture that omits a status from `/users/status/ids` would close this; the T33 stub
  (`build/uitest-server/mm_stub.py`) has no DM-picker routes at all today, so that is a new stub
  surface, not a switch.
- **F5's network path is unit-only.** Making `GET /users/me` fail inside a running app needs a relay in
  front of the server, and the T47-AV relay run crashed the runner before it could measure anything
  (verdict §1.4) — not repeated here. The unit tests drive the real view model through
  `ChannelCreationServing` and assert the emitted sentences.
- **The T45 inventory manifest was not regenerated.** A live scan of this tree reports
  `accessibilityLabel 99`, `accessibilityIdentifier 512`, while the checked-in manifest still says 96 /
  467 — it was already stale from other cards' work before this one. `T45A11yInventoryTests` reads the
  manifest, not the tree, so nothing here is asserted about this change; the scan's own checks pass on
  this tree (`unnamed glyph buttons 0`, `UNEXPLAINED text 0`, unknown fonts 0).
- **Fixture state.** This card's runs left no channel behind: the repaired test never taps a row, and
  the two mutation runs never opened a conversation. The DM leaks listed in the verdict §5 are the
  parent card's, and are permanent by design (`DELETE /channels/{id}` refuses D and G).

## 4. A sibling defect, filed rather than fixed here

`AddMembersViewModel.absorb` (`Mattermost/UI/Native/ChannelInfo/AddMembersViewModel.swift:190`) maps
`GET /users?in_team=&not_in_channel=` with no `delete_at` check — the same F3 shape on the add-people
picker. Measured with `scripts/t47_avr2_probe.py` (the `add-people list` lines):

```
perf-feed      not-in-channel rows= 16 deactivated=1 -> ['t429gone']
probe-roles-2  not-in-channel rows= 17 deactivated=1 -> ['t429gone']
```

Filed as `t_e65e6018` (child of this card) rather than repaired here: it is a different surface, and
its fix belongs with its own test.

