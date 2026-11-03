# t_6e9a1d8a — Threads says "These threads are not available" when no team resolved

Behaviour reference: `mattermost/mattermost-mobile` v2.45.0 (`162f2560d0e1…`),
`app/screens/global_threads/` and `app/actions/remote/thread.ts` (`fetchThreads` →
`GET /users/me/teams/{team}/threads`). Server used for the live checks: `https://chat.canonical.com`
(the QA store's own session), plus the pinned 9.11.19 measurements already recorded in
`ThreadAPI.swift`.

## 1. The symptom, reproduced on a Release build of HEAD

The card's first step was to rule out a stale QA Debug build. It is **not** stale — HEAD reproduces.

* Build: `Release-maccatalyst` from a pristine worktree of **HEAD `db73a3d`** (not the working tree):

  ```
  git worktree add …/scratch/t6e9-head db73a3d
  xcodebuild build -project Mattermost.xcodeproj -scheme Mattermost -configuration Release \
    -destination "platform=macOS,variant=Mac Catalyst" \
    -derivedDataPath ~/Library/Developer/Xcode/DerivedData/mmios-t6e9-head
  → ** BUILD SUCCEEDED **      (build/logs/t6e9/head-release-catalyst-build.log)
  ```

* Route used: `mattermost://chat.canonical.com/town-square/threads` — a threads route carrying a
  team **name** that resolves to no team id. (Any route, tab or row that reaches the pane without a
  team id reproduced the same screen; the deep link is just the one that can be triggered without
  racing the sidebar's first load.)
* Observation: `screencapture` is refused on this host (no Screen Recording permission for the
  shell), so the screen was read through the **accessibility tree** (`AXUIElement`, scratch
  `axdump.swift`) and the network through the **unified log**:

  ```
  AXGroup id=nativeThreadsList
    AXStaticText id=globalThreads.title      desc=Threads
    AXStaticText id=globalThreads.subtitle   desc=No threads yet
    AXImage      id=globalThreads.failed     desc=Alert
    AXStaticText id=globalThreads.failed     desc=These threads are not available.
    AXButton     id=globalThreads.failed     desc=Try again
  ```

  ```
  log show --predicate 'processID == 31964' --info --debug | grep 84557434
  1  task=84557434 kind=redirection  status=301
  1  task=84557434 kind=task success status=404
  ```

  i.e. the reported screen is the server's 404 for a list URL built from a missing team.
  The `Try again` button re-runs the same wrong request.

* Host quirk, recorded so the next reader does not chase it: the Xcode-built Catalyst bundle cannot
  launch as-is — its embedded `WebRTC.framework` is ad-hoc with no Team ID and dyld refuses the
  mapping (`different Team IDs`). The evidence run used a copy re-signed
  `codesign --force --deep --sign -`; the executable's code and sources are unchanged.

## 2. The defect

Four places turned "we do not know the team" into a URL, or hid the fact:

| Where | What it did |
| --- | --- |
| `GlobalThreadsViewModel.reload()` | called `service.threads(teamID: "")` with no guard → `/users/me/teams//threads` (301 → 404) and then drew the 404 copy |
| `ThreadCoordinator.globalModel(for:teamID:)` | cached the teamless model under `"default"`, so the broken list outlived the team |
| `GlobalThreadsView` / `NativeThreadsTabView` | passed `navigation.location.teamID ?? ""` — the empty string was decided at the call site |
| `ChannelSidebarView.openThreads()` | passed `model.teamID` (a `String?`) straight into the route |
| `NativeNavigation.location(for:server:)` | `resolved?.teamID ?? request.teamID`, so a `.threads` route kept `nil` instead of asking the shell which team it is showing |

Nothing recorded *what* had been asked for, which is why the screen needed a live server to explain.

## 3. The fix

* **A missing team is a state, not a server answer.** `GlobalThreadsViewModel.Phase` gained
  `.noTeam`; `reload()` and `loadMore()` never build a request from an empty team, and the pane draws
  "Choose a team to see your threads." (`globalThreads.noTeam`) instead of the 404 copy. The failure
  state is untouched — this does not weaken an empty state to hide an error.
* **No teamless model is cached.** `ThreadCoordinator.globalModel(for:teamID:)` takes `String?` and
  returns an uncached placeholder when no team is known; a real team is cached once, so the pane's
  `.task(id: navigation.location.teamID)` loads exactly once.
* **The route carries the team.** `NativeNavigation` completes a `.threads` route from the shell's
  current team through a new `NativeChannelDirectory.currentTeamID(serverID:)` seam (implemented by
  `ChannelSidebarCoordinator` from the loaded channel list). A team the caller named always wins.
  `ChannelSidebarView.openThreads()` refuses a nil/empty team instead of routing it. The same
  fallback fills `ThreadCoordinator.teamID(for:)`, so a thread's follow/read writes are not built
  from an empty team either.
* **The next occurrence is diagnosable.** A failed list request records
  `path=/users/me/teams/<id>/threads status=<http status>` in `lastFailureDiagnostic` **and** logs it
  through `Logger` (category `Threads`). `MMError` knows the status; this joins it with the path.

## 4. Verification on the fixed build

Same Release Catalyst configuration, built from the fixed tree and re-signed the same way. Same
route `mattermost://chat.canonical.com/town-square/threads` (same signed-in session):

```
AXGroup id=nativeThreadsList
  AXStaticText id=globalThreads.title    desc=Threads
  AXStaticText id=globalThreads.subtitle desc=5406 threads
  AXTabGroup   id=globalThreads.tabs
  AXButton     id=globalThreads.row.eug858mynpy3bnm1qo31x55ohh desc=Thanh, 7:49 PM, …
  … rows follow, no globalThreads.failed
```

The route resolved to the team the shell is showing, the list answered 200 and the pane drew real
rows (a list that size cannot come from anywhere but a successful `…/threads` page). No 301/404 in
that run's CFNetwork summaries.

## 5. Tests (`MattermostTests/ThreadsTeamResolutionTests.swift`)

Functional style, no section comments:

* an empty team issues **zero** service calls and reports `.noTeam` (recorded fake call count, not
  the copy);
* a model with a team asks `/users/me/teams/<id>/threads` **exactly once** (captured team → path);
* a 404 keeps the existing copy **and** records `path…` + `status=404`, and the line reaches the
  `Logger` sink;
* no model is cached under an empty key (`globalModelCount == 0`, two distinct placeholders), and the
  real team's model is one object;
* a teamless request/`model(for:rootID:)` takes the shell's team when one is showing;
* a `.threads` route without a team takes the shell's team; a route that names one keeps it.

`FakeThreadService.threadListRequests` now records the team id it was asked for (it recorded only
`before`/`unreadOnly`, which is why the wrong team could previously hide).

Runs:

* `MattermostTests/ThreadsTeamResolutionTests` — **8 tests, 0 failed**
  (`build/logs/t6e9/t6e9-units4.log`); `T36GlobalThreadsViewModelTests` (20) still green;
* neighbours `NativeNavigationTests`, `T33ChannelSidebarTests`, `T4dUnreadThreadsTests` — 121 tests,
  2 skipped, 0 failed (`build/logs/t6e9/t6e9-neighbors.log`);
* whole `MattermostTests` — **2110 tests, 10 skipped, 0 failed**, `** TEST SUCCEEDED **`
  (`build/logs/t6e9/t6e9-full-units.log`).

A HEAD-only probe (a scratch test file in the throwaway worktree, not committed) asserted the
pre-fix behaviour at `db73a3d`: one request from an empty team and `phase == .failed("These threads
are not available.")` — it passed **before** the fix, which is what made this a code defect rather
than an install problem:

```swift
let service = FakeThreadService(); service.loadError = MMError.notFound
let model = GlobalThreadsViewModel(teamID: "", service: service, myUserID: "me")
await model.load()
XCTAssertEqual(service.threadListRequests.count, 1)                                   // asked anyway
XCTAssertEqual(model.phase, .failed("These threads are not available."))             // 404 -> the copy
```

## 6. What could not be measured here

* A 4xx on the fixed build could not be provoked without a second server the signed-in user is not a
  member of; the diagnostic line is covered by the unit test above (path + `status=404` + log sink).
* The release-install discipline is not addressed: the running QA app was a **Debug-maccatalyst**
  product (`…/mattermost-ios-qa/Build/Products/Debug-maccatalyst/Mattermost.app`, pid 47416, quit for
  this run). It was equally affected — the defect is in the source, so this card is code, not
  install discipline.
