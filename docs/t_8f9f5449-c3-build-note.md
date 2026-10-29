# `t_8f9f5449` C3 — the profile popover's **Call** and **Add to a channel** rows

Card: **`t_296843e5`** (epic `t_8f9f5449`, slice C3). Behaviour reference: `mattermost/mattermost`
**v9.11.0** — the webapp popover and `components/add_user_to_channel_modal/`. Apache-2.0; behaviour
ported with attribution per `docs/THIRD_PARTY_NOTICES.md` §18, no upstream source copied.

Worktree: `.worktrees/t_296843e5`, branch `t_296843e5`, from local `main` **26531b5**.

---

## 1. What this slice adds

| Surface | Before C3 | After C3 |
|---|---|---|
| `ProfileActionSet` | Message + the two self rows | **+ `.addToChannel`, + `.call`**, in upstream's DOM order, gated by a **context** (`ProfileActionContext`), not by ad-hoc view conditions |
| The Call row's job | — | creates the DM (`POST /channels/direct`, T41's path) and hands the join to the pane through `CallsCoordinator.requestStart` |
| The Add to a channel row's job | — | pushes a **team-scoped picker** (`AddToChannelPickerView`), fed by `ChannelMemberAdminDirectory` |
| Channel-member permission rule | inline in `ChannelInfoCapabilities.derive` | **one** static rule, `ChannelInfoCapabilities.canManageMembers(channel:permissions:)`, applied per channel by both callers |
| Calls entry points | channel header only (T44d) | channel header **and** the profile's Call row — one surface, two routes |

The card's own row matrix (`docs/t_8f9f5449-profile-popover-parity.md` §4) is now a **pure function**
and every cell is a unit test (§3).

### 1.1 One rule, two quantifiers

`ChannelInfoCapabilities.canManageMembers` was lifted out of `derive` so the picker can ask the same
question of **every** channel in the team. The rule is unchanged: not archived, not a DM/GM, not the
default channel, and the permission ids the channel's **visibility** names
(`manage_public_channel_members` / `manage_private_channel_members`) are in the reader's role union.
`ChannelMemberAdminAnswer` then answers three things from one pass:

* `manageableChannelIDs` / `manageableChannels` — the list the picker draws;
* `canManageAnyChannelMembers` — the ∃ the popover's row is gated on.

`ChannelMemberAdminDirectory` caches that answer per **(server, team)** and is forgotten on
`ProfileCoordinator.deactivate` — the same lifecycle rule T40's coordinators use.

### 1.2 The intent, not a second write

"Send message" and "Call" perform the **same** write (`POST /channels/direct`) and differ only in
what the host does once the channel exists. `ProfileConversationIntent` (`.open` / `.call`) carries
that difference out of the view model so the sheet publishes one channel and cannot mistake one row
for the other (`ProfileViewModel.openConversation(intent:)`).

### 1.3 Why the Call row does not present the call

`CallsJoinEntry` owns `CallsSurfaceView`. The profile row lives in a **sheet**, and a full-screen
cover raised from inside a sheet is T40's measured nested-presentation failure (a confirmation action
that never ran, zero requests on the wire). So the row writes the DM, opens it, and calls
`CallsCoordinator.requestStart(serverID:channelID:)` — a **one-shot, app-scoped** intent the pane
consumes on mount and spends through `startCall`. `consumeStart` answers `false` for a pane it was
not meant for, so an intent can never start a call in a channel the reader did not ask for.

---

## 2. Files

New:

* `Mattermost/UI/Native/ChannelInfo/ChannelMemberAdminDirectory.swift` — the team-scoped
  "may I manage the members of a channel here?" answer, per-(server, team) cache, `forget`.
* `Mattermost/UI/Native/ChannelInfo/AddToChannelPickerViewModel.swift` — rows, search, selection,
  already-a-member detection, optimistic add with rollback.
* `Mattermost/UI/Native/ChannelInfo/AddToChannelPicker.swift` — the pushed picker (container +
  `AddToChannelPickerContent`, §4.1).
* `MattermostTests/T5449ProfileActionMatrixTests.swift` (18), `MattermostTests/T5449AddToChannelPickerTests.swift` (14).
* `MattermostUITests/T5449ProfileActionsUITests.swift` (2 live tests).

Changed:

* `Profile/ProfileModels.swift` — `ProfileActionContext`, the extended matrix, `ProfileRowGate`,
  `ProfileConversationIntent`.
* `Profile/ProfileViewModel.swift` — the conversation + intent, the DM shortcut.
* `Profile/ProfileCoordinator.swift` — the write rows' context (`prepareActions`), the directory seam,
  `isTeamMember`, `forget` on deactivate.
* `Profile/ProfileView.swift` — the two rows, their reasons, the picker push, the intent hand-off.
* `ChannelInfo/ChannelInfoModels.swift` — `canManageMembers` lifted out; `derive` uses it.
* `ChannelInfo/ChannelInfoService.swift` — `myChannelMemberships()`, `teamMembership(teamID:userID:)`.
* `Calls/CallsCoordinator.swift` — `pendingStarts`, `requestStart`, `pendingStart`, `consumeStart`,
  cleanup on reset/deactivate.
* `Calls/CallsJoinEntry.swift` — consumes the intent (§4.2), `onDismiss` owns the dismissal rule (§4.3).
* `Calls/CallsSurfaceView.swift` — no longer leaves the call on `onDisappear` (§4.3).
* `MattermostTests/T40ChannelInfoTests.swift`, `T47CreateChannelTests.swift` — fakes satisfy the two
  new service methods.
* `MattermostTests/T429ProfileTapTests.swift` — the old five-cell calls now go through
  `actionContext(...)`; their expectations are unchanged (an all-defaults context offers neither write
  row).
* `Profile/ProfilePresentationHost.swift` — C2's **pushed** profile (`t_2fa3bbe1`, merged while this
  branch was open) carries the same two rows, so its route has to honour the intent too:
  `openConversation(_:intent:)` asks the pane to join on `.call`. Without it the pushed form would draw
  a Call row that only opened the DM.
* `docs/parity.md` — the **T41** row (rows now offered, with identifiers) and the **T44d** row (the
  profile's Call row as a second route into the surface).

---

## 3. Evidence

Units — `python3 scripts/qa-test.py --platform ios --sim "name=iPhone 16 Pro,OS=18.3.1"`:

| run | what | result |
|---|---|---|
| `build/logs/t5449-c3-units4.log` | the two new classes | **32 run / 0 skipped / 0 failed** |
| `build/logs/t5449-c3-final-units2.log` | the whole `MattermostTests` target, final code | **1,825 run / 8 skipped / 0 failed — `RESULT: PASS`** |
| `build/logs/t5449-c3-rebased-units2.log` | after rebasing onto `main` **7f38b14** (C2 `t_2fa3bbe1` merged) | **1,828 run / 8 skipped / 0 failed — `RESULT: PASS`** |

The first full-suite attempt (`t5449-c3-final-units.log`) reported one failure,
`T35ComposerDraftStoreTests.testAllDraftsAreNewestFirst`, and the re-run of the suite passed with the
same binary. That test passes in isolation (`build/logs/t5449-c3-t35.log`, 10/10), so it is a
pre-existing order/timing flake in T35's draft ordering, not a consequence of this card. It is
recorded here rather than hidden.

Live (real server `127.0.0.1:8065`, 9.11.19; fixture account `perfprobe`, `t41buddy`):

| run | what | result |
|---|---|---|
| `build/logs/t5449-c3-ui-add2.log` | `testAddToChannelAddsTheAuthorToTheChosenChannel` | **1/1 green** |
| `build/logs/t5449-c3-ui-call8.log`, `…callstab1.log`, `…callstab2.log` | `testCallOpensTheDirectChannelAndJoins` | **1/1 green, three consecutive runs** |
| `build/logs/t5449-c3-ui-final.log` | the whole suite, final code | **2 run / 0 skipped / 0 failed — `RESULT: PASS`** |
| `build/logs/t5449-c3-ui-rebased.log` | the whole suite after the rebase onto `7f38b14` | **2 run / 0 skipped / 0 failed — `RESULT: PASS`** |

What the live tests assert, and against whose word:

* **Call** — `profile.call` exists on another human; tapping it dismisses the sheet; the **DM** pane
  opens; `callsSurface` mounts **from the pane** (never from the sheet); `GET
  /plugins/com.mattermost.calls/calls/{dmChannelID}/active` answers `{"active":true}` for the *DM*,
  not for the channel the profile was opened from; `calls.leaveButton` returns it to `{"active":false}`.
* **Add to a channel** — `profile.addToChannel` pushes the picker; the picker's own search narrows the
  list to this card's throwaway channel (`t5449-add`, created by the test, member removed in `setUp`);
  `Add to channel` enables; after the tap `GET /channels/{id}/members/{t41buddy}` answers **200** —
  the server's answer, not the view's.

Attachments from these runs: `docs/t5449-shots/` (call row, picker ready, after-leave).

The two rows' **negative** cells are unit-pinned, deliberately: live-tapping "the Call row is absent
while a call is live elsewhere" means starting a second concurrent call to watch a row disappear,
which is exactly the fragile flow T40/T44d recorded. `testTheCallRowIsAbsentWhileACallIsLiveElsewhere`
pins it.

---

## 4. Four measurements this card needed (and the bugs they found)

Each of these was a **live** symptom first, then a code change, then a re-run. They are the reason the
implemented shape is not the shape in the first draft.

### 4.1 A picker whose model nobody observes

`build/logs/t5449-c3-ui-add1.log`: the picker opened, the search field accepted `T5449 picker
fixture` (its own accessibility `value` carried it) and **the list never changed** — the row was the
sixth in an unfiltered list, off screen, so the test could not find it. Cause: `content(_ model:)` and
`loaded(_ model:)` took the view model as a **plain parameter**, so a `Binding(get:set:)` wrote into
an object SwiftUI was not observing. Fix: `AddToChannelPickerContent` is its own view with
`@ObservedObject var model` (and `TextField(text: $model.query)`); the container keeps the load.

### 4.2 An intent that cancelled the join it started

`.task(id: startIntentKey)` — with `startIntentKey` **including** the pending intent — is invalidated
by the very act of consuming it: `consumeStart` clears `pendingStarts`, the id changes, SwiftUI
cancels the in-flight task, and the join died inside the plugin-version request. Measured twice:
first as the generic "This server has no working Mattermost Calls plugin." alert
(`build/logs/t5449-c3-ui-call1.log`), then, with a temporary DEBUG suffix in the alert, as the exact
error — **`cancelled`** (`build/logs/t5449-c3-ui-call2.log`). Fix: consume from `.task(id: channelID)`
(the pane's channel, which consumption does not touch) and `.onReceive(calls.$pendingStarts)`, and
start the call in a `Task` nobody owns. `onChange` was tried first and is not enough: it compares
against the value captured at the last body evaluation, and a pane rebuilt in the same turn as the
write loses that baseline — measured as a join that simply never ran
(`build/logs/t5449-c3-ui-call3.log`, `…call4.log`).

### 4.3 "Call ended" one frame after joining

With the intent finally consumed, `callsSurface` mounted and said **Call ended**
(`build/logs/t5449-c3-ui-callr1.log`, screenshot exported from that run's own attachment). Two
controls settled whose fault it was, both green under the same load:

* channel header button in a **public** channel → call active on the server
  (`build/logs/t5449-c3-ui-control1.log`);
* channel header button in the **same DM** → call active on the server
  (`build/logs/t5449-c3-ui-control2.log`).

So neither the DM nor the host was the problem: the difference was that my route presents the surface
while the pane is still being inserted. `CallsSurfaceView.onDisappear` ran `model.leave()` — and
`onDisappear` also fires when SwiftUI substitutes presented content during a re-render of the
presenting pane, which ended the call it had just joined. Fix: the dismissal rule moved to
`fullScreenCover(onDismiss:)` in `CallsJoinEntry` (`calls.endCall()`), the event SwiftUI raises for an
actual dismissal. Leave / Close / swipe-down / the pane going away all still end the call — `t5449-c3-ui-call8.log`
onwards, three consecutive greens.

### 4.4 What the fixture server cannot tell us

`channel_user` on this server carries `manage_public_channel_members` and
`manage_private_channel_members` — T40's documented role hazard (`docs/t40-build-note.md` §6 F9), still
in place. So on **this** server every public channel the reader is in is manageable, and the live Add
test proves the *write*, not the *breadth* of the permission rule. The rule itself is pinned by unit
tests with clean role fixtures (§3), including the private/public split in both directions.

`MattermostUITests/T44DCallsUITests` cannot run on this fixture right now: both of its tests stop at
"`#t44-calls` must be listed in the sidebar" (`build/logs/t5449-c3-t44d-regress.log`) — the account is
in 351 channels, so that channel is not in the sidebar's window. That failure is identical **before**
this card's changes (it is the fixture, not a regression), and the behaviour those tests assert —
Leave ends the call on the server — is asserted by this card's Call test, which the `onDismiss` change
touches.

---

## 5. Identifiers

| id | what |
|---|---|
| `profile.call` / `profile.callReason` | the Call row and, when it is absent, why ("You are already in a call.") |
| `profile.addToChannel` / `profile.addToChannelReason` | the Add to a channel row and its reason |
| `addToChannel.picker` | the picker screen |
| `addToChannel.search` | its filter field |
| `addToChannel.row.<channelID>` | one channel (its accessibility value is the subtitle; "Member" once known) |
| `addToChannel.empty` | no manageable channel, or no search match |
| `addToChannel.alreadyMember` | "… is already a member of this channel." (Add is disabled beside it) |
| `addToChannel.submit` | "Add to channel" |
| `addToChannel.banner` / `addToChannel.error` / `addToChannel.retry` | write failure / read failure / retry |
| `calls.joinButton`, `callsSurface`, `calls.leaveButton` | T44d's, unchanged — the Call row routes *into* them |

---

## 6. Limits that stay

* **Not proved ⇒ not drawn.** The Add row needs three facts proved (`hasTeam`,
  `inCurrentTeam == true`, `canManageAnyChannelMembers == true`). An unresolved fact hides the row
  **silently** (`ProfileRowGate.absent(nil)`); a fact proved *against* the reader hides it with a
  sentence. The row pops in when the coordinator's answer lands — one appearance, never an offer that
  is withdrawn again.
* **The picker lists the team's *joined* channels** (`GET /users/me/teams/{tid}/channels`), which is
  upstream's list — not every channel in the team, and it cannot join a channel as a side effect.
* **The picker's search matches the display name only** (`AddToChannelRow.title`). Upstream matches the
  URL name as well (T40's browse derivation does); typing `t5449-add` for a channel displayed as
  "T5449 picker fixture" will not match. Stated, not hidden.
* **A DM/GM and the default channel are never offered**, even to an admin — that is the rule, not a
  gap.
* **The Call row is absent while a call is live elsewhere** ("You are already in a call."). Switching
  calls is upstream's `switch_call_modal`, which is not ported (`t_8f9f5449` §5).
* **No media claim.** This card proves signalling: the join reaches the server, the server reports the
  call active, leaving ends it. Whether audio flows is T44's own unverified gate (0/3 ICE candidates
  reachable on this fixture, `docs/t44-build-note.md`), and screen share/camera remain absent by
  construction (T44d §6).
* **A bot gets no Call row**; it does get Add to a channel (that is how an integration joins one).
* **`channel_user`'s role on this fixture server is mutated** — see §4.4. Repair with
  `python3 scripts/t40_channel_seed.py --reset-roles` before trusting a *permission-breadth* run.
* The picker's list is read fresh per open **unless** the team answer is already cached by the sheet's
  own open (`ChannelMemberAdminDirectory`); a channel created by another client between the sheet
  opening and the picker opening appears on the next open, not in the cached list.
* **`docs/parity.md` carries the behaviour, not the counts.** Both the T41 and the T44d rows are edited
  by sibling cards (C1 `t_6d420e01`, C2 `t_2fa3bbe1`) in the same table cell; the test counts and run
  logs live in this note so three cards do not fight over one fencepost.
* The **third row of the card's acceptance list** — "the Call row is absent while a call is live" — is
  unit-pinned rather than live-tapped (§3).

---

## 7. How to run

```
python3 scripts/qa-test.py --platform ios --sim "name=iPhone 16 Pro,OS=18.3.1" \
  --only-testing MattermostTests/T5449ProfileActionMatrixTests \
  --only-testing MattermostTests/T5449AddToChannelPickerTests

TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<scripts/perf_seed.py> \
  python3 scripts/qa-test.py --platform ios --sim "name=iPhone 16 Pro,OS=18.3.1" \
  --only-testing MattermostUITests/T5449ProfileActionsUITests
```

`--sim` must pin the runtime (`name=iPhone 16 Pro,OS=18.3.1`): with the bare name, xcodebuild resolves
against the *latest* runtime, where this device does not exist, and the run dies with "Unable to find a
device matching the provided destination specifier".
