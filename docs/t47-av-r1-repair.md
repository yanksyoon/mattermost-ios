# T47-AV-R1 — the create menu stops waiting behind the threads read, and a dismissed draft resets

Card: `t_f2ae238e`. Parent: `t_e1ddfba4` (T47-AV). Findings repaired: **F1a** (the `+` starved by an
unrelated read), **F1b** (a failed permission read indistinguishable from "no permission", with an
unreachable retry) and **F6** (a draft that survives Cancel → reopen and a `createdChannel` that is
never consumed), from `docs/t47-av-verdict.md` §6.

Base: detached worktree at `origin/main` `4cd5bdc`. Host: macOS 26.3.1, Xcode 26, simulator
`T47R1 iPhone 16 Pro` (`030FAA4D-A561-4C7A-8F18-4472A379914F`, iOS 18.3), fixture `mm-perf` 9.11.19 on
`http://127.0.0.1:8065` (`perfprobe`, password from `scripts/perf_seed.py`; restricted account
`t47av-restricted`). Every number below is from a run on this host, not from the build note.

---

## 1. What changed

### 1.1 F1a — two tasks, not one sequence

`Mattermost/UI/Native/Sidebar/ChannelSidebarView.swift`. The one `.task(id: model.teamID)` used to read

```swift
await resolved.load(ifNeeded: true)          // GET /users/me/teams/{id}/threads
let create = channelInfo.createModel(...)
createModel = create
if create.phase != .ready { await create.load() }
```

so the create model's permission read was queued behind the threads read. It is now **two `.task`
modifiers** (two tasks): the threads read in one, the create and direct-message models in the other.
The models are handed to `@State` **before** the create task's first `await`, so the header has them as
soon as the task is scheduled. The `+` is drawn by `ChannelCreateMenuButton`, which observes the model;
nothing about it depends on the threads read any more.

### 1.2 F1b — "could not ask" is not "you may not"

Two changes, one in the model and one in the menu:

* `ChannelCreateViewModel.load()` no longer swallows the two reads that decide the permission union.
  It was `try? await myTeamMembership` and `(try? await rolePermissions(...)) ?? []` — a failed read
  became `permissions == .none`, the same state a reader without the permission has. Both are `try await`
  now, so a failed read ends in `.failed(sentence)`.
* `ChannelCreateViewModel.failureMessage` exposes that sentence, and `ChannelCreateMenuButton` draws the
  `+` in the `.failed` state too: its menu carries the failure sentence and a **"Try again"**
  (`nativeSidebarCreateRetry`) that re-runs `load()`. The `.ready`-with-an-empty-menu case still draws
  no `+` — that is the reader who genuinely may not create, and it is now the only silent case.

The copy and the retry that already existed inside `CreateChannelForm` are unchanged; they are simply no
longer the only way to reach them.

### 1.3 F6 — the sheet tells the model the attempt is over

`ChannelCreateViewModel.consumeCreatedChannel()` had no callers and `resetDraft()` replaces it:

```swift
func resetDraft() {
    draft = ChannelCreateDraft(kind: permissions.creatableKinds.first ?? .open)
    errorMessage = nil
    createdChannel = nil
}
```

`CreateChannelView` calls it from `.onDisappear`, which is the one hook every ending goes through —
Cancel, an interactive swipe-down, and a completed create. The fresh draft opens on the first kind the
reader may create (the same rule the first draft follows), so a reopened form cannot offer a kind the
submit would refuse. `NewDirectMessageViewModel.consumeOpenedChannel()` was the other caller-less
function named by F6; it is deleted (`openedChannel` stays — it is the model's published result, which
the picker's tests assert).

## 2. The new fixtures

Neither claim can be produced against the real server: one is about *ordering* under a slow read, the
other about a *failure* of one endpoint. `scripts/t47_r1_fixture_proxy.py` is a transport proxy (the same
shape as T49's `t49_no_tos_proxy.py`): it forwards everything unchanged and bends exactly one path.

| mode | what it does |
|---|---|
| `--threads-delay N` | holds every `GET /api/v4/users/me/teams/{id}/threads` for `N` seconds |
| `--fail-permission-reads N` | answers `500` to the first `N` permission reads (`POST /api/v4/roles/names`, `GET /api/v4/teams/{id}/members/me`), then forwards |
| `GET /__fixture/status` | the counters the live test asserts against (`threads_in_flight`, `threads_delayed`, `permission_requests`, `permission_failures_served`) |

Smoke test of the proxy itself (before any app touched it):

```
$ python3 scripts/t47_r1_fixture_proxy.py --listen 8078 --threads-delay 2 --fail-permission-reads 1
$ curl -s -o /dev/null -w "%{http_code}\n" -X POST …/api/v4/roles/names -d '{"role_names":["system_user"]}'
500
$ curl -s -o /dev/null -w "%{http_code}\n" -X POST …/api/v4/roles/names -d '{"role_names":["system_user"]}'
401
$ curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" …/users/me/teams/abc/threads
401 2.035622s
$ curl -s http://127.0.0.1:8078/__fixture/status     # while a threads request was held
{"threads_requests": 2, "threads_in_flight": 1, "threads_delayed": 2, …}
```

The WebSocket upgrade is **not** proxied (`GET /api/v4/websocket 400` in the logs); the app falls back
exactly as it does against an unreachable socket, and the suite does not depend on socket events.

## 3. What was run

### 3.1 Unit suite — `MattermostTests/T47CreateChannelTests`

```
python3 scripts/qa-test.py --platform ios --sim id=030FAA4D-… \
  --derived-data ~/Library/Developer/Xcode/DerivedData/mattermost-ios-t47r1 \
  --only-testing MattermostTests/T47CreateChannelTests --label t47r1-units2 \
  -- -clonedSourcePackagesDirPath ~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa/SourcePackages
# -> Executed 39 tests, with 0 failures (0 unexpected) in 0.080 (0.168) seconds   (log:4665)
# -> ** TEST SUCCEEDED **                                                          (log:4677)
```

39 = the 34 that shipped plus five new ones (§3.4). `t47r1-units.log` is a first attempt that died in
`Early unexpected exit … signal kill`; the host was running six concurrent `xcodebuild test` jobs at the
time (sibling cards). The private simulator and private derived data above are the isolated re-run.

### 3.2 The live suite — 5/6, the failure named and attributed

```
env TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
    TEST_RUNNER_MM_AUTH_PASSWORD=… TEST_RUNNER_MM_AV_RESTRICTED_LOGIN=t47av-restricted \
    TEST_RUNNER_MM_AV_RESTRICTED_PASSWORD=… \
    TEST_RUNNER_MM_AV_STALL_SERVER=http://127.0.0.1:8076 \
    TEST_RUNNER_MM_AV_PERMISSION_SERVER=http://127.0.0.1:8077 \
  xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
    -destination "platform=iOS Simulator,id=030FAA4D-…" \
    -only-testing MattermostUITests/T47CreateChannelAVUITests …
# -> Executed 6 tests, with 1 failure (0 unexpected) in 556.863 (556.877) seconds   (log:748)   [run 1]
# -> ** TEST FAILED **                                                             (log:763)
# second full run (t47r1-ui6.log, permission proxy restarted so its budget was fresh):
# -> Executed 6 tests, with 2 failures (0 unexpected) in 439.779 (439.801) seconds  (log:916)   [run 2]
```

The environment variables must be in the **environment** of `xcodebuild` (as above), not passed as
`KEY=VALUE` arguments: as arguments they become build settings and are never injected into the test
runner — measured, `t47r1-ui3.log:107` shows all six tests skipping with
`set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD`.

| test | run 1 (`ui4`) | run 2 (`ui6`) |
|---|---|---|
| `testAFailedPermissionReadOffersARetryThatActuallyReloads` (new) | **PASS** 64.7 s | **PASS** 96.3 s |
| `testAHalfTypedDraftDoesNotSurviveARelaunchAndNothingIsSent` (assertion flipped) | **PASS** 46.4 s | **PASS** 74.6 s |
| `testOpeningTheSameConversationTwiceFindsOneChannel` | **FAIL** 302.9 s | **FAIL** 134.1 s |
| `testTheCreateMenuAppearsWhileTheThreadsReadIsStalled` (new) | **PASS** 75.2 s | **PASS** 57.9 s |
| `testThePickerOffersADeactivatedTeamMemberThatSearchHides` | **PASS** 32.7 s | **PASS** 49.7 s |
| `testTheServerRefusesACreateAfterTheTeamRoleIsRevoked` | **PASS** 34.9 s | **PASS** 27.1 s |

The one failing test is the direct-message one, and it is **not this card's code** — but the two runs
failed at *different* lines, so both are reported:

* run 1, line 284 — host starvation. The app's main thread could not be scheduled:

  ```
  T47CreateChannelAVUITests.swift:284: error: … Failed to get matching snapshots:
    Unable to perform work on main run loop, process main thread busy for 30.0s      (log:458)
      t =  148.92s         App event loop idle notification not received, will attempt to continue.
  ```

  `uptime` at that moment: load averages **769.66 820.46 689.77**, six booted simulators and six
  concurrent `xcodebuild test` jobs (five sibling cards).

* run 2, line 473 — a **harness race**, and a useful one: `showSidebar` returns as soon as
  `nativeSidebar` exists *anywhere* in the tree, and on iPhone the sidebar is the NavigationStack root,
  so while a channel pane is pushed the sidebar is still in the hierarchy. `showSidebar` returned
  without popping, and `openDirectMessagePicker` then waited 30 s for a `+` that was behind the pane:

  ```
  T47CreateChannelAVUITests.swift:473: error: … the create menu must be offered:
  … Element subtree: … NavigationBar … Button 'Back' … Button identifier: 'serverSwitcher' …
  ```

  Filed on the harness card as a comment (`t_40082af1`, T47-AV-R4, which owns `revealSidebarRow` /
  `showSidebar`), not fixed here.

At the same commit the DM test **passes on its own**, which is what attributes both failures to
environment/harness rather than to the product:

```
-only-testing …/testOpeningTheSameConversationTwiceFindsOneChannel
# -> Test Case '…testOpeningTheSameConversationTwiceFindsOneChannel' passed (168.754 seconds)   (t47r1-ui5.log:527)
# -> ** TEST SUCCEEDED **                                                                      (t47r1-ui5.log:541)
```

### 3.3 The two new live tests, with their evidence

**F1a — the `+` while the threads read is held.** Proxy log (`build/logs/t47r1-proxy-stall.log`), in
order: the threads read is held, and the rest of the create path completes while it is held.

```
GET /api/v4/users/me/teams/ocz148uck3r88dcjikj497bosh/threads (fixture: delaying 60s)
GET /api/v4/users/me 200
GET /api/v4/users/me/teams/ocz148uck3r88dcjikj497bosh/channels 200
GET /api/v4/teams/ocz148uck3r88dcjikj497bosh/members/jruqqzxtobg7tn4wehwmwjjo5c 200
POST /api/v4/roles/names 200
```

The test found the `+` 0.2 s after the shell appeared and opened the form from it:

```
t =  69.82s     Checking existence of "nativeSidebar" Any
t =  69.89s     Checking existence of "nativeSidebarCreateMenu" Button
t =  70.94s         Checking existence of `"nativeSidebarCreateMenu" Button`
t =  71.13s Added attachment named 'r1a-create-menu-while-threads-stalled'
t =  73.00s     Tap "nativeSidebarCreate.createChannel" Button
t =  74.73s         Checking existence of `"createChannel.displayName" TextField`
Test Case '…testTheCreateMenuAppearsWhileTheThreadsReadIsStalled' passed (75.204 seconds)
```

and read the fixture's own counters while the read was still held — `threads_delayed: 1`,
`threads_in_flight: 1` (the assertions that make the claim, not the screenshot).

**F1b — the failed permission read, and a retry that asks again.** Proxy log
(`build/logs/t47r1-proxy-permission.log`):

```
GET /api/v4/teams/ocz148uck3r88dcjikj497bosh/members/jruqqzxtobg7tn4wehwmwjjo5c 200
POST /api/v4/roles/names 500 (fixture: permission read refused)
...
POST /api/v4/roles/names 200
```

The test opened the `+` in the failed state, found `nativeSidebarCreateRetry`, tapped it, and then found
the real menu row `nativeSidebarCreate.createChannel`; the counters it asserted are
`permission_requests` **2** with `permission_failures_served` **1** — i.e. the retry made a second
request rather than re-rendering the first answer. Note: this build issues the team-membership read as
`/teams/{id}/members/{user_id}`, so the refusal lands on `POST /roles/names`; the membership half is
covered by the unit test in §3.4, not by this live run.

**F6 — the flipped assertion.** `testAHalfTypedDraftDoesNotSurviveARelaunchAndNothingIsSent` typed
`T47 AV Draft <stamp>`, cancelled, reopened, and now asserts the absence of the draft:

```
XCTAssertFalse(reopenedName.contains(displayName), "a cancelled draft must not survive: …")
XCTAssertFalse(reopenedURL.contains(urlName),    "the derived URL went with the name; …")
XCTAssertFalse(app.buttons["createChannel.submit"].isEnabled, "an empty draft cannot be submitted")
```

(The old assertion was `XCTAssertEqual(reopened.value as? String, displayName)` with a `RECORDED
BEHAVIOUR` comment.) XCUITest reports an empty text field's *placeholder* as its `value`, so the assertion
is the absence of the typed name, not the presence of `""` — the disabled Create button is the positive
half.

### 3.4 The unit tests added

`MattermostTests/T47CreateChannelTests.swift`, section 5b/5c:

| test | what it pins |
|---|---|
| `testAFailedRoleReadIsAFailureAndNotAnEmptyMenuOfNoPermission` | a failed `POST /roles/names` is `.failed` with a sentence, **and** the reader who answered with no grant is `.ready` with an empty menu — the two are distinguishable |
| `testARetryAfterAFailedReadLoadsAgainAndOffersTheMenu` | the retry re-runs the read (`roleRequests == 2`) and the same model becomes `.ready` with the real menu |
| `testAFailedTeamMembershipReadFailsTheLoadInsteadOfDroppingTheTeamRoles` | a failed `GET …/members/me` no longer silently drops the team roles; a later successful read keeps the team grant |
| `testResetDraftEmptiesTheFieldsTheErrorAndTheCreatedChannel` | fields, derived URL, `urlNameEdited`, `errorMessage` and `createdChannel` are all cleared by `resetDraft()` |
| `testAResetDraftOpensOnAKindTheReaderMayCreate` | a reset form opens on a kind the submit would accept |

The fake gained `principalFailure` / `teamMembershipFailure` / `rolesFailure` so a test can make one
read fail while the others answer.

### 3.5 Mutations — are the two new live tests load-bearing?

Both defects were put back into the product in one worktree edit, the two new tests run alone, then the
mutation reverted and the same two tests re-run.

| mutation | expected | measured |
|---|---|---|
| `ChannelCreateViewModel.load()` back to `(try? await service.rolePermissions(…)) ?? []` | `testAFailedPermissionReadOffersARetryThatActuallyReloads` fails — with the failure swallowed, no `+` is drawn | **red** — failed (73.5 s) at `:382 "a failed permission read must not look like \"you may not\""` (`t47r1-mutation.log:384`) |
| `ChannelSidebarView`'s create task made to `await threads.…load(ifNeeded:)` first (the pre-repair sequencing) | `testTheCreateMenuAppearsWhileTheThreadsReadIsStalled` fails — the `+` waits out the 60 s stall | **red** — failed (66.0 s) at `:340 "the \`+\` must not wait behind the threads read"` (`t47r1-mutation.log:660`) |
| reverted (the repaired tree) | both green | **green** — `Executed 2 tests, with 0 failures … in 65.853` (41.9 s + 23.9 s, `t47r1-restored.log:408`) |

That also answers the sanity question a reader should ask about F1a's timing: with the old sequencing the
`+` cannot appear until the 60 s hold ends, so a 25 s wait fails — which is exactly what the mutation
measured.

### 3.6 Re-verified after the rebase onto `origin/main`

The runs above were made on the commit `4c65d26`, based on `4cd5bdc`. `origin/main` had moved to
`2c3b7f1` (T47-AV-R3's `create()` capture and T47-AV-R4's harness work), so the repair was rebased to
`a3f0ccb` and re-run there. One conflict (`T47CreateChannelTests.swift`, both cards adding a section at
the same anchor) was resolved by keeping both — R3's F4 tests stay section 5b, this card's become 5c/5d.

```
xcodebuild test … -only-testing MattermostTests/T47CreateChannelTests
# -> Executed 41 tests, with 0 failures (0 unexpected) in 0.327 (0.344) seconds   (t47r1-units3.log:600)   [39 mine + R3's 2]

xcodebuild test … -only-testing …/testAFailedPermissionReadOffersARetryThatActuallyReloads \
                 -only-testing …/testTheCreateMenuAppearsWhileTheThreadsReadIsStalled \
                 -only-testing …/testAHalfTypedDraftDoesNotSurviveARelaunchAndNothingIsSent
# -> testAFailedPermissionReadOffersARetryThatActuallyReloads   passed (30.043 seconds)      (t47r1-rebased-live.log:196)
# -> testAHalfTypedDraftDoesNotSurviveARelaunchAndNothingIsSent   passed (167.158 seconds)   (t47r1-rebased-live.log:351)
# -> testTheCreateMenuAppearsWhileTheThreadsReadIsStalled   passed (40.916 seconds)         (t47r1-rebased-live.log:426)
# -> Executed 3 tests, with 0 failures (0 unexpected) in 238.118                            (t47r1-rebased-live.log:428)
```

Line numbers quoted in §3.2 and §3.5 are those of the tree the runs used (`4c65d26`); the merged file
gained a line in the header, so they are +1 at `a3f0ccb`.

## 4. Not done here

* **The live suite is 5/6 in both full runs, not 6/6** — the DM test's two failure signatures are
  quoted and attributed in §3.2, and the same test passes on its own at this commit. It should be
  re-run on a host that is not running five other cards' suites, and the `showSidebar` race belongs to
  `t_40082af1` (T47-AV-R4).
* `testTheCreateMenuAppearsWhileTheThreadsReadIsStalled` and
  `testAFailedPermissionReadOffersARetryThatActuallyReloads` **skip** unless the two fixture proxies are
  running; the suite stays runnable without them (4 of 6 tests need only the server).
* The first live attempt (`t47r1-ui3.log`) skipped all six tests because the `TEST_RUNNER_*` values were
  passed as xcodebuild *arguments*; that is a trap worth knowing about and is recorded in §3.2.
