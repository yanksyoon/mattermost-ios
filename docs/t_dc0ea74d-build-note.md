# `t_dc0ea74d` — the pushed profile resolves its write rows, and the pinned author tap measured properly

Card: **`t_dc0ea74d`** (follow-up to C3 `t_296843e5`, epic `t_8f9f5449`).
Base: local `main` **b82de6d**. Branch: `t_dc0ea74d`.

Two defects were filed out of C3's build note (`docs/t_8f9f5449-c3-build-note.md` §6.1). One of them was a
real gap in C2's host; the other was **not in the product at all** — it was the test's element lookup, and
this note says so rather than claiming a fix to an affordance that always worked.

---

## 1. What changed

| File | Change |
|---|---|
| `Mattermost/UI/Native/Profile/ProfilePresentationHost.swift` | `PushedProfileScreen` now makes **the sheet's own `prepareActions` call** (same four arguments) between `load()` and the presence loop; it reads `CallsCoordinator` and `SurfaceModeResolver` from the environment; it passes `teamID: navigation?.location.teamID` into `ProfileScreen` (without it the pushed Add row would draw and its destination render nothing); and `openConversation` honours `ProfileConversationIntent.call` — pop, open the DM, hand the join to the pane through `CallsCoordinator.requestStart`, exactly as `ProfileSheet` does. Doc comments that said "the push resolves no write rows" are gone. |
| `MattermostUITests/T5449ListProfileUITests.swift` | `tapAuthorHeader` resolves `post.<id>.avatar` / `.author` **inside the row** instead of app-wide, and asserts `isHittable`. Comment records why (§3). |
| `MattermostUITests/T5449ProfileActionsUITests.swift` | New live test `testThePushedProfileCarriesTheSameWriteRows` (the pushed form draws `profile.call` + `profile.addToChannel`, and the Add row presses through to `addToChannel.picker`); `launchApp(nativeLookup:)` so that one test can turn on the lookup surface the pinned sheet lives behind. |
| `docs/t_8f9f5449-c2-build-note.md` | §8.7 — the correction. |
| `docs/t_8f9f5449-c3-build-note.md` | §6.1 — one line saying both findings landed and pointing here. |
| `docs/parity.md` | T41 row: the write rows exist in **both** forms now, with the pinned-tap finding stated. |

No new identifier: the pushed form already drew the same `ProfileScreen`, so `profile.call`,
`profile.addToChannel` and `addToChannel.picker` are the identifiers it now offers there too.

---

## 2. Defect 1 — the pushed form resolved no write rows (real, fixed)

`PushedProfileScreen.task` resolved the model and started presence, but never called
`ProfileCoordinator.prepareActions`. `ProfileViewModel.actionContext` therefore stayed `unknown`, and by
C3's matrix (`ProfileActionSet.resolve`: **unknown is absent, not assumed**) the pushed form offered
neither `.call` nor `.addToChannel` — Message and the self rows only.

The fix is the sheet's call, verbatim, in the same position in `.task`:

```swift
await coordinator.prepareActions(model: resolved,
                                 server: server,
                                 teamID: navigation?.location.teamID,
                                 callsAvailable: calls.isCallsAvailable(serverID: server.id),
                                 callsSurfaceNative: resolver.resolvedMode(for: .calls) == .native,
                                 hasLiveCallElsewhere: calls.hasLiveCall)
```

Two `@EnvironmentObject`s were added for it. The one thing that is *not* the sheet's call — the `teamID`
argument to `ProfileScreen` — was added at the same time: `ProfileScreen` renders the picker destination
only `if let teamID`, so a pushed Add row without it would be a button that opens nothing.

`.call` from the push had to be given the sheet's intent rule as well, or the row would have been an
offer that could not be kept: the push pops, the DM becomes the shell's location, and
`CallsCoordinator.requestStart` carries the join to the pane's `CallsJoinEntry`. Nothing in this change
presents the call surface from the push (T40's measured nested-presentation failure).

---

## 3. Defect 2 — the pinned author tap: the affordance was fine, the lookup was not

C3 measured, six ways, that tapping a pinned row's author did not open the profile and filed it as "the
author affordance is not receiving touches in that host", with the `List` row's `.onTapGesture` winning
over `PostRowView`'s nested `Button`s as the prime suspect (explicitly a hypothesis).

**That diagnosis is withdrawn.** The element is not unique in that host. The pinned sheet is presented
over the channel pane, the pinned post belongs to that same channel, and the row is therefore drawn
twice: `{{27.0, 637.6}, {33.1, 33.1}}` inside `channelPostList` under the sheet, and
`{{32.0, 557.0}, {36.0, 36.0}}` inside `pinnedPosts` on it. The test resolved
`element(app, "post.<id>.avatar")` app-wide, so `.firstMatch` answered the **covered** copy in the pane.
Everything C3 measured follows from that one fact, and nothing from the product:

| C3's observation | What it was |
|---|---|
| `header.tap()` → `Computed hit point {-1, -1}`, nothing happens | the resolved element is covered by the sheet, so XCUITest cannot compute a hit point |
| `header.isHittable` never becomes true, on a drawn row mid-list | same — hittability is computed *under the cover* |
| a raw coordinate tap at the avatar's frame performs the **row's** action | that frame is inside the sheet at a *different* row (`open(row)` on it, hence the dismiss + jump) |
| the frame is "inside the row and inside the visible list" | true of the *sheet's* row; the header being tapped was the other copy — C3's `push6.log` records the failed containment assert this produces: header at y 637.6, revealed row at y 720 |
| C2's own test got past the tap in one run | in that run `.firstMatch` answered the sheet's copy — the tree order of the two copies is not stable between launches |
| the two tests disagree | they address different copies, not different behaviour |

Fix (test-only, this card): the header is resolved **inside the row** —
`row.descendants(matching: .any).matching(identifier: "post.<id>.avatar").firstMatch` — which makes the
identifier honest, makes the existing containment assert mean what it says, and lets a new
`isHittable` assert catch a future ambiguity at the affordance instead of three assertions later.

The product-side `List` row is untouched: an `onTapGesture` on a container does not need to be replaced
for this, and C2 (`t_c297b96a`) already measured that the row's structure is not what blocks the tap —
with the pre-C2 `Button` container restored, the author's own action still runs.

---

## 4. Runs

All on `127.0.0.1:8065` (Mattermost 9.11.19), iPhone 17 Pro simulator, iOS 26.5, load average ≤ 3.4 at
start. `docs/`-adjacent logs are `build/logs/*.log` in this checkout.

| run | spec | outcome |
|---|---|---|
| `t_dc0ea74d-pinned` | `--only-testing MattermostUITests/T5449ListProfileUITests/testTheAuthorOfAPinnedPostPushesTheProfile` **alone** | **1 run / 0 failed**, 43.0 s, `** TEST SUCCEEDED **`. The tap logs `Tap "post.<id>.avatar" Button` and `profilePush` exists 1.4 s later; the pop-back assertion is green. (Before the lookup fix, the same test is C3's `…push6.log`: containment assert red at the wrong copy.) |
| `t_dc0ea74d-listprofile` | `--only-testing MattermostUITests/T5449ListProfileUITests` (all five) | **5 run / 1 skipped / 0 failed**, 128.9 s. The skip is the iPad-only lookup-sheet push (compact layout on a phone, its documented skip). mention 22.6 s, pinned 39.0 s, saved 20.8 s, lookup-sheet skipped 17.2 s, search 29.4 s. |
| `t_dc0ea74d-pushrows2` | `--only-testing MattermostUITests/T5449ProfileActionsUITests/testThePushedProfileCarriesTheSameWriteRows` **alone** | **1 run / 0 failed**, 41.0 s. `profilePush` present, `profileSheet` absent, `profile.call` and `profile.addToChannel` both drawn in the pushed form, and the Add row opens `addToChannel.picker`. No call is started, so the audio caveat does not apply. |
| `t_dc0ea74d-pushrows` | the same test **before** `nativeLookup: true` was added | 0 run / 1 failure — and the failure is the reason the flag exists: `nativeChannelPinnedButton` is gated on `resolvedMode(for: .search) == .native`, and this suite's `launchApp` did not turn the lookup group on. Kept in the log directory as the record; the helper now says so where it is declared. |
| `t_dc0ea74d-addpush` | Add-to-a-channel + the new push test, one invocation | 2 run / **1 failed**: the push test green (40.4 s); the Add test **wedged the app** — `addToChannel.submit` tapped at t=34.8 s, then "App event loop idle notification not received" and four minutes of unanswered accessibility snapshots (`Failed to get matching snapshot: Timed out while evaluating UI query`) |
| `t_dc0ea74d-add-retry` | the Add test **alone**, immediately after | **1 run / 0 failed** (35.4 s) — so the wedge above is a simulator/app episode, not a reproducible failure; that test's path (picker → submit → optimistic add) is not touched by this card and its launch arguments are unchanged (`launchApp()`'s new parameter defaults to `false`) |
| `t_dc0ea74d-call` | `--only-testing …/testCallOpensTheDirectChannelAndJoins` **alone** (audio) | 1 run / **2 failed**: `callsSurface` absent at 60 s and `/calls/{dm}/active` still false — the failure dump shows the DM pane drawn with `calls.joinButton` at `value: joining`, i.e. the **join never completed**, not a wrong route. The profile's Call row had dismissed the sheet and opened the DM as it should |
| `t_dc0ea74d-call2` | the same test **alone**, immediately after | **1 run / 0 failed** (32.9 s), the call joined and `Leave` ended it on the server. Two runs of the same code, one red one green: this is T44d §4.2's recorded Calls flakiness (and the reason the suite says "run alone on a quiet host"), not something this card changed — the sheet's Call path is untouched by it |
| `t_dc0ea74d-units` | `--only-testing MattermostTests` (whole unit target) | **1830 run / 8 skipped / 0 failed** (40.3 s), `** TEST SUCCEEDED **` — the eight skips are the target's standing ones (CertTrust/Keychain, the live opt-in, SelfSignedTrust ×2, the Catalyst-only halves), unchanged by this card |

### 4.1 What was *not* re-run

`T44DCallsUITests` stays unrunnable on this fixture (its sidebar lookup, unchanged before this card —
C3 §6.2). The sheet's own two live tests are unchanged in behaviour: `launchApp()`'s default is
`nativeLookup: false`, i.e. byte-identical launch arguments to the shipped suite.

---

## 5. Limits that stay

* The authored tap is **only** exercised through the pinned sheet on iPhone: it is the one push container
  the compact layout has. The regular layout's lookup sheet has its own test
  (`testTheAuthorOfASearchResultInTheLookupSheetPushesTheProfile`), which needs an iPad and **skips** on a
  phone — so the pushed write rows are live-proved in one of the two push containers, not both. The other
  container differs only in which `NavigationStack` the push rides on; both draw the same
  `PushedProfileScreen`.
* The pushed Call row is asserted, not pressed, in the live test — pressing it starts a real call, which
  is T44's own audio gate. Its route is the sheet's (unit-pinned in `T5449ProfileActionMatrixTests` plus
  `CallsCoordinator`'s `requestStart`/`consumeStart` rules), and the one line that differs between the two
  hosts is `dismiss()` vs `dismiss()`-then-`requestStart`, written out in `PushedProfileScreen`.
* A pinned post is drawn **twice** while its sheet is open (pane underneath, sheet on top). That is
  ordinary iOS presentation, not a defect, but any test — present or future — that looks up
  `post.<id>.*` app-wide in that host is resolving an ambiguous identifier. §3 is the record.
* `pinnedPosts` is a `CollectionView` in the tree; `savedPosts` is not exposed at all (C2 §6.4). The new
  test's `revealRow` swipes the list when the row is below the fold and is tolerant of the identifier
  being absent, the same convention as C2's.
