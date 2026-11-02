# T47-AV — adversarial validation of the create-channel surface and the direct-message picker

Card: `t_e1ddfba4` (T47-AV). Audit target: **`8643fbff4bbf6e2095f62aea057a9d53c642cdb1`**
(`git rev-parse HEAD` = `git rev-parse origin/main` = `8643fbf` at audit time). Everything below is a run
I made on this host in a detached worktree at that SHA
(`…/scratch/t47av-wt-032533`), not a number copied from the build note. The shipped suite is
`MattermostUITests/T47CreateChannelUITests.swift` + `MattermostTests/T47CreateChannelTests.swift`; the
adversarial suite added here is `MattermostUITests/T47CreateChannelAVUITests.swift`.

Fixture: `mm-perf` (`mattermost/mattermost-team-edition:release-9`, 9.11.19) on `http://127.0.0.1:8065`,
account `perfprobe` (password from `scripts/perf_seed.py`), restricted probe account `t47av-restricted`.
Simulator: iPhone 16 Pro `81A7F251-8B31-4945-8783-5A264C14B8D5` (iOS 18.3). Host: macOS 26.3.1, Xcode 26.

---

## VERDICT: PASS-WITH-FINDINGS — and the shipped live suite does not reproduce at HEAD

The feature's claims survive the attacks: the two client gates are load-bearing (mutations §3), a server
404/403 reaches the screen and creates nothing (live §2, tests 1 and 2), a wrong-kind answer is refused,
a half-typed draft is not persisted, and opening the same conversation twice finds one channel. The
adversarial suite I added passes **4/4** against the server's own records (§2).

But the note's §5.2 live verdict does **not** reproduce at HEAD: the shipped two-test suite is
**0/2** on two runs, and one of the two runs both mis-reported its failure (*"POST /channels never
landed"* while the channel existed on the server, in a different team) and **left a live channel behind**
(§1.2, F7/F8). The immediate cause of every sidebar assertion is the suite's own `revealSidebarRow`,
which queries `collectionViews` while the sidebar has been a `ScrollView` (`channelSidebar.scroll`) since
T8f — it never scrolls, so a row below the first viewport "does not exist". The rows do exist: the AV
suite finds them by swiping the app (§2, test 4). So the red is a harness defect, not a product
regression — but until it is fixed, the note's live paragraph is unproven, and its "every run archives
what it created" sentence is false in the red path.

Findings F1–F8 and their repair cards are in §6–§7. Nothing here is on by default: the surface still
requires `-surfaceMode channelInfo=native`.

---

## 1. What I ran

### 1.1 Unit suites at HEAD

```
python3 scripts/qa-test.py --platform ios --sim id=81A7F251-… \
  --only-testing MattermostTests --label t47av-units2
# -> Executed 1941 tests, with 8 tests skipped and 0 failures        (log:14689)
# -> ** TEST SUCCEEDED **                                         (log:14700)
```

T47's own class alone, after the mutation runs were reverted:

```
--only-testing MattermostTests/T47CreateChannelTests --label t47av-units-restored
# -> Executed 34 tests, with 0 failures (0 unexpected) in 0.160 s   (log:1226)
# -> ** TEST SUCCEEDED **                                        (log:1236)
```

### 1.2 The shipped live suite — red, and once wrong about why

Run A (`t47av-ui-t47`, app opened on **Operations**):

```
T47CreateChannelUITests.swift:112: the create menu must be offered to an account that may create channels
T47CreateChannelUITests.swift:421: no channel named t47-ui-1793648428 appeared within 30s — POST /channels never landed
T47CreateChannelUITests.swift:146/148/150/151/152/154: nil is not equal to … (the oracle has no channel)
```

At the 30-second failure the tree showed `channelSidebar.loading` ("Loading channels…") still spinning
and **no `channelSidebar.createMenu`**: the `+` is drawn only once the create model has loaded, and
`ChannelSidebarView.swift:131-137` loads that model **after** `await resolved.load(ifNeeded:)` (the
global-threads read) in the same `.task(id: model.teamID)`. One slow read starves the other (F1).

The channel *was* created — in Operations, the team the app had opened — while the oracle looked in
`GET /users/me/teams[0]` (perf). The test called that "POST never landed". Its cleanup then ran
`createdChannelIDs.append(channel["id"] ?? "")` on the empty oracle answer, so the `DELETE` in `tearDown`
had an empty id (silently, `allowFailure: true`). The channel stayed live:

```
fixture audit, after the runs:  ('ops', 't47-ui-1793648428', 'kcx3gfapq3ygbcd1zdpxyuwhra', 'P', 1793648486096, delete_at 0)
my cleanup:                     DELETE /channels/kcx3gfapq3ygbcd1zdpxyuwhra -> 200, delete_at 1793649730840
```

Run B (`t47av-ui-t47b`, app opened on **Perf**): the create path worked end to end (the oracle found the
channel, the pane was titled with the display name) and failed only at the sidebar:

```
T47CreateChannelUITests.swift:170: the sidebar must list the channel that was just created
T47CreateChannelUITests.swift:182: the created channel must survive a relaunch (it lives on the server)
T47CreateChannelUITests.swift:267: the sidebar must list the conversation that was just opened
# -> Executed 2 tests, with 3 failures                            (log:1404)
```

No swipe was ever logged: `revealSidebarRow` asks `app.collectionViews.firstMatch` for a container,
gets nothing, and returns without scrolling. The sidebar's own identifier is
`ScrollView … identifier: 'channelSidebar.scroll'`.

### 1.3 The adversarial suite (added here) — 4/4

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AV_RESTRICTED_LOGIN=t47av-restricted \
python3 scripts/qa-test.py --platform ios --sim id=81A7F251-… \
  --only-testing MattermostUITests/T47CreateChannelAVUITests --label t47av-ui-av4
# -> Executed 4 tests, with 0 failures (0 unexpected) in 195.062 s  (log:902)
# -> ** TEST SUCCEEDED **                                          (log:910)
```

| test | what it does | verdict |
|---|---|---|
| `testTheServerRefusesACreateAfterTheTeamRoleIsRevoked` | restricted account signs in (TOS accepted first), opens the create form as `team_user`, the role is flipped to `team_admin` in the fixture, the form is submitted → the server's 403 copy on screen, **no channel** in the team | PASS (19.5 s) |
| `testAHalfTypedDraftDoesNotSurviveARelaunchAndNothingIsSent` | half-typed name/URL, verified 404 at the server, Cancel → reopen (draft is **still there**), terminate + relaunch → empty form, still 404 | PASS (34.7 s) |
| `testOpeningTheSameConversationTwiceFindsOneChannel` | picker → tap a teammate → back → picker → tap again: the server's pair-name record has **one** channel, whose members are exactly the two people; the sidebar holds that one row | PASS (116.6 s) |
| `testThePickerOffersADeactivatedTeamMemberThatSearchHides` | opening list (`GET /users?in_team`) offers a deactivated account; typing the same username yields nobody; the offered row opens a DM | PASS (23.2 s) — recorded as F3 |

The suite's own `revealSidebarRow` swipes the application (`app.swipeUp(velocity: .fast)`) rather than
querying a container; that is what finds the row.

### 1.4 Not obtained: the relaunch wire witness

A one-test harness (`T47AVWireUITests`, not committed) pointed the app at `t47_logging_relay.py` on
`:8066` to record the requests. The run died before the relaunch — `Restarting after unexpected exit,
crash, or test timeout` — with 0 tests executed (`t47av-wire3.log:282`, `:295`), the relay hazard the
T40/T47 notes already record. The relay log shows the **first** launch's reads
(`GET /users/me/teams/ocz…/channels`, `POST /roles/names`, …) and nothing after a relaunch. So the
"the row after a relaunch came from `GET …/channels`" claim rests on the shipped test's own code path
(no local channel store; the sidebar load is an HTTP read) and on the row being found — **not** on a
wire capture I made. What is still needed is stated in §8.

---

## 2. What the server said (probes)

All from `scripts/t47_av_probe.py` (setup/teardown) and the scratch probes listed in §5:

- **The client's permission answer and the server's agree, and the server is the authority.** A
  `team_user` may create public and private channels in this team; after the role flip, `POST /channels`
  is 403 `api.context.permissions.app_error` and `GET /teams/{tid}/channels/name/{name}` stays 404.
- **Wrong kind is refused by the server too.** Creating `type: "D"` (and `G`) through `POST /channels`
  is 400; a direct conversation is only `POST /channels/direct`.
- **`POST /channels/direct` is create-or-find**: 201 on both paths with the same channel id (I read the
  id from the first call and got it again from the second).
- **A direct or group channel cannot be deleted**: `DELETE /api/v4/channels/{id}` →
  `400 api.channel.delete_channel.type.invalid — Unable to delete direct or group message channels`.
  This is why the AV DM tests leave a conversation behind (F8).
- **`GET /users?in_team=` returns deactivated accounts** (`delete_at` non-zero), while
  `POST /users/search` with `allow_inactive: false` does not. The opening list and the typed list
  therefore disagree, which is exactly what test 4 records (F3).
- **Terms of service**: `POST /users/me/terms_of_service` accepts **`termsOfServiceId`** (camelCase);
  the snake-case key is `400 api.context.invalid_body_param.app_error`. The AV suite's restricted sign-in
  works only with the camelCase body (the T49 gate otherwise holds the shell shut).

---

## 3. Mutations — do the unit tests pin what they claim?

Each mutation was applied to the worktree, the T47 class run alone, then reverted; the restored run is
§1.1 (34/34 green).

| mutation | expected | measured |
|---|---|---|
| `CreateChannelViewModel.create()` gate neutered (`guard true \|\| permissions.canCreate(draft.kind)`) | the "no permission sends nothing" test still catches it via the model's `validation(permissions:)` gate | **green** — 34/0 (`t47av-mut-gate1.log:482`) |
| both gates neutered (`create()` **and** `CreateChannelDraft.validation`) | `testACreateWithoutThePermissionSendsNothing` fails | **red** — 3 failures in that test (`t47av-mut-gate2.log:423`) |
| the wrong-kind check deleted from `create()` | `testAChannelOfTheWrongKindIsNotNavigatedTo` fails | **red** — 3 failures in that test (`t47av-mut-kind.log:427`) |
| the picker's presence label deleted from `NewDirectMessageView` | if the suite pinned the view, something must fail | **green** — 34/0 (`t47av-mut-view.log:308`) |

The fourth row is the important one: the picker's "Unknown rather than offline" test
(`testThePickerCarriesPresenceAndSaysUnknownRatherThanOffline`) asserts a **model** property, and the
view never reads it for an empty status (`NewDirectMessageView.swift:96` draws the label only when
`!candidate.status.isEmpty`). Delete the label and the suite is unchanged (F2).

The first row says the two gates are redundant-but-paired: the `create()` guard can be removed without a
red test, because `validation(permissions:)` (called two lines below it) is what the test observes. That
is fine as defense in depth, but "the security gate is what the test protects" is not what the test
measures.

---

## 4. The attacks the card named, one by one

| attack | result |
|---|---|
| **permission gating** — create without permission | client: both gates present; mutation row 2 shows the pair is load-bearing. server: 403 reaches the screen, nothing created (live test 1). **PASS**, with F1 for the read-failure path |
| **a `team_user`'s answer is not the server's** | the app's gate uses the same `permissions.canCreate`; when the role is flipped mid-session the client still believes it may create and the server answers 403; the form shows the server's sentence and navigates nowhere. **PASS** |
| **wrong kind answered (P asked, O/D given)** | `create()` refuses a non-empty `type` that differs from `draft.kind`, and the oracle is never reached; server refuses `D`/`G` through `POST /channels` anyway. **PASS**, but the comparison reads `draft.kind` *after* the await (F4) |
| **404 before → exists** | the draft test's oracle reads 404 both before and after a half-typed draft; the create test reads the channel only after the tap. **PASS** |
| **draft persistence across a relaunch** | not persisted; but a **cancelled** draft is still there when the sheet reopens (the model is per (server, team) and `consumeCreatedChannel()` is never called). Live in test 2; F6 |
| **sidebar row after a relaunch** | the shipped test cannot reach it (harness, §1.2); the AV DM test's relaunch-free row is found after swiping. **NOT PROVEN at HEAD** — see §8 |
| **DM picker: unknown vs offline** | the model says "Unknown"; the view draws nothing for an unknown status, so "Unknown" is never on screen, and the unit test stays green with the label deleted (mutation row 4). **PASS-WITH-FINDING** (F2) |
| **DM picker: deactivated account** | the opening list offers it and the row opens a conversation; typing the same name finds nobody. **Recorded** (F3) |
| **DM picker: idempotency** | one channel for two taps; members are exactly the pair. **PASS** |
| **no test leaves a live channel behind** | the shipped red run **did** leave one (`t47-ui-1793648428`, archived by me); its cleanup is `try?` + `allowFailure: true` + an empty id on the failure path. A DM cannot be deleted at all (server 400), so the AV DM tests leave conversations. **FAIL** (F8) |

---

## 5. Fixture state after the audit

- `t47-ui-1793648428` (ops, leaked by run A): archived by me, `delete_at 1793649730840`.
- Probe DMs left live (the server refuses to delete them): `bxa9njsp…__jruqqzxtobg…` (restricted↔perfprobe),
  `jruqqzxtobg…__jruqqzxtobg…` (self), `4k7irwrwifrn…__jruqqzxtobg…` (perfprobe↔the deactivated ops member
  the picker test opened a conversation with). None carries a `t47` name, so no future create can collide
  with them; they are permanent because of the 400 above.
- `t47av-restricted`: roles restored to the fixture's `team_user` (the test's `tearDown` writes the
  original roles back); its terms-of-service acceptance remains (a real, accepted document — harmless,
  and required for any future restricted-account run).
- `probe-roles-2` (perf) predates this audit; untouched.

---

## 6. Findings

**F1 — the `+` is starved by an unrelated read, and its error path is unreachable.**
`ChannelSidebarView.swift:127-140` loads the create model after `await resolved.load(ifNeeded:)` in one
`.task`; a slow threads read leaves `createModel` nil, so no `+` is drawn at all. Measured in §1.2 run A:
30 s, `channelSidebar.loading` still spinning, no `nativeSidebarCreateMenu`. And when only the permission
read fails, `rolePermissions` becomes `.none`, `menuActions` is empty, the button is not drawn, and the
model's `.failed` sentence + retry live in `CreateChannelForm` — a sheet that is only presented from the
menu that is not there. A reader cannot tell "you may not" from "I could not ask", and cannot retry.

**F2 — the picker's "Unknown" is never rendered.** `NewDirectMessageView.swift:96` requires
`!candidate.status.isEmpty` before drawing `statusLabel`, so an unknown presence draws nothing; the unit
test pins the model's label, not the view (mutation §3 row 4). Dead label or dead test — one of them must
go.

**F3 — the opening list offers deactivated accounts.** `GET /users?in_team=` includes them (§2); the
picker filters only the signed-in user, so a deactivated person is offered and tapping them opens a DM
(live test 4). Upstream's picker does not offer them; the typed search does not either — the two lists
disagree inside one sheet.

**F4 — the wrong-kind check reads a kind the reader can still change.** `create()` awaits
`service.createChannel(draft.body(...))` and afterwards compares `channel.type` to `draft.kind`
(`CreateChannelViewModel.swift:160`). If the segmented control changes during the await (the form stays
interactive while `isCreating`), the comparison is against the *new* kind: an honest P/O answer from the
requested kind is reported as "the server answered a channel this app did not ask for". Capture the
requested kind before the await and compare against that.

**F5 — a failed principal read makes the picker offer the signed-in user.** `NewDirectMessageView`'s
`principal()` is `try?`-swallowed; `myID` stays nil, the self-row filter does nothing, and the load's
error copy says "signed out" for what may be a network failure. State the failure, or refuse the list;
do not silently include the reader.

**F6 — a draft is never reset.** `consumeCreatedChannel()` and `consumeOpenedChannel()` have no callers
(only their definitions match a repository-wide grep), so Cancel→reopen restores the previous form
(live, test 2) and a successful create leaves its channel in the model. A reopened sheet shows the last
attempt's fields.

**F7 — the shipped live suite is red at HEAD because its scroll helper cannot scroll.** `revealSidebarRow`
uses `app.collectionViews.firstMatch`; the sidebar is `channelSidebar.scroll` (a `ScrollView`) since T8f.
Every sidebar assertion in both tests fails for that reason (§1.2). The team is also unpinned: the app
opens on `model.entries.first` of the rail while the oracle reads `GET /users/me/teams[0]`; when those
disagree the create lands in the app's team, the oracle looks in another, and the test reports "POST
/channels never landed" (§1.2 run A).

**F8 — cleanup failures are invisible and DMs cannot be cleaned at all.** `tearDown` sends
`DELETE /channels/{id}` with `try?` and `allowFailure: true`; on the oracle-failure path the recorded id
is `""`, so nothing is deleted and nothing is said. The red run leaked a live private channel (§1.2).
And a DM cannot be deleted (400, §2), so the DM half of the suite cannot honour "every run archives what
it created" — it can only decline to create one, or use a pair that already exists.

---

## 7. Repair cards filed

- **T47-AV-R1** (channelInfo): F1 + F6 — load the create model in parallel with the threads read, give
  the permission-read failure a reachable retry, reset the draft on dismiss/success and call the consume
  functions.
- **T47-AV-R2** (channelInfo): F2 + F3 + F5 — the picker's three honesty gaps (never "Unknown",
  deactivated accounts offered, the reader offered when the principal read fails).
- **T47-AV-R3** (channelInfo): F4 — capture the requested kind before the await.
- **T47-AV-R4** (tests): F7 + F8 — the live harness: swipe the sidebar, pin the team the app is actually
  on (and pass it to the oracle), record the created id independently of the oracle, assert the archive,
  and treat "created a DM" as a fixture mutation to avoid rather than an archive target.

---

## 8. What is still needed

1. **A green re-run of the shipped live suite at a commit whose harness is repaired (T47-AV-R4).** Until
   then §5.2 of the build note is unproven, and its "every run archives" sentence is false on the red
   path.
2. **The relaunch wire witness.** The relay run died before the relaunch (§1.4). The claim needs either a
   stable relay run (T40's libtrace hazard worked around) or a proxy that survives the app's logging.
3. **A real-device parity soak.** Nothing here touched a physical phone; the picker's presence display
   and the DM list's ordering are exactly the kind of thing that differs under a real socket.
4. **APNs/notification-driven DM open** was not in this card and is not covered.
