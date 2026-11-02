# `t_10d3db63` — C4-R: the pushed Call row's route is now run, and the "drawn twice" cause is runtime-scoped

Card: **`t_10d3db63`** (follow-up to the C4 adversarial validation `t_76a52cbe`).
Base: local `main` **`ffc22f7`** (= live `origin/main`). Two follow-ups, neither a product change:

| # | Finding (`t_76a52cbe`) | What this card does |
|---|---|---|
| 1 | the pushed profile's **Call** row was drawn and its tap path (`pop → open the DM → requestStart`) was never exercised by any test | `PushedProfileScreen.route` — a static seam — plus three unit tests in `MattermostTests/T5449ProfilePresentationTests.swift` that run the ordering with no UI and no audio |
| 2 | the "same post is drawn twice" cause of C3's pinned-tap failure was written as if universal; it reproduces on iOS 18.x and **not** on iOS 26.5 | `docs/t_dc0ea74d-build-note.md` §3/§3.1/§5 and the T41 row of `docs/parity.md` corrected to the measured scope |

---

## 1. Finding 1 — the pushed Call route is run, not just read

`1d67294` gave `PushedProfileScreen` the sheet's `.call` rule in `openConversation(_:intent:)`
(`ProfilePresentationHost.swift:209-221`): `dismiss()` (the pop), then
`navigation.openChannel(request)`, then `CallsCoordinator.requestStart(serverID:channelID:)`. No test
ran it: `grep -rn "ProfileConversationIntent" MattermostTests MattermostUITests` answered nothing, and
the only `profile.call` **press** was the sheet's own test (`testCallOpensTheDirectChannelAndJoins`,
which exercises `ProfileSheet.openConversation` — a different function). The live pushed-form test
asserts the row is drawn and presses only **Add to a channel**, deliberately: pressing Call starts a
real calls session, and T44d §4.2 records the measured `AURemoteIO::Initialize` abort under host load.

### 1.1 The change

`Mattermost/UI/Native/Profile/ProfilePresentationHost.swift`: `openConversation` keeps its shape and
forwards to a new `@MainActor static func route(_:intent:serverID:dismiss:open:requestStart:)`, which is
the entire body that used to be there. The three collaborators are closures so the unit target can
observe them; production passes the real ones:

```swift
Self.route(channel,
           intent: intent,
           serverID: server.id,
           dismiss: { dismiss() },
           open: navigation.map { navigation in { _ = navigation.openChannel($0) } },
           requestStart: { calls.requestStart(serverID: $0, channelID: $1) })
```

`open: nil` is "this push has no `NativeNavigation`" (a preview, or a host that only draws the screen):
the route then pops and stops — there is no pane to open, and certainly no pane to join.

No behaviour changed: the executed statements and their order are identical to `1d67294`, and the
request is built the same way (`serverID`, `channelID`, `teamID`/`channelName` nil when the server sent
`""`).

### 1.2 The tests (`MattermostTests/T5449ProfilePresentationTests.swift` §4)

| test | what it pins |
|---|---|
| `testThePushedCallRoutePopsThenOpensTheDMThenAsksThePaneToJoin` | the recorded steps are exactly `["dismiss", "open", "start <serverID>/<dmID>"]`; the request names this server and the DM the model created; a DM's `team_id: ""` / empty name become `nil` |
| `testThePushedMessageRouteOpensTheDMAndNeverAsksForACall` | `.open` records `["dismiss", "open"]` — Message must not hand the pane a call intent; a team-scoped channel's `team_id` and name do travel |
| `testThePushedRouteWithoutNavigationOnlyPops` | `open: nil` records `["dismiss"]`, builds no request, and never asks for a call |

Why a seam rather than a live XCUITest: the live form is the audio hazard the suite already documents,
it can kill the runner rather than fail the test, and CI does not run XCUITest suites at all (the
`test(ios-simulator)` leg runs `MattermostTests` only), so a live test would be unrun on every push.
The seam runs in the unit leg of both CI test jobs. The sheet's live test keeps the server-side oracle
(`GET /plugins/com.mattermost.calls/calls/{dm}/active` → `active:false` after Leave); this card does not
duplicate it.

**The limit that stays, stated rather than hidden:** what the tests run is `route`, not the four-line
forwarding in `openConversation` — that line names each closure once and cannot be observed without
mounting the view. Everything that decides *what happens and in what order* is inside `route`.

### 1.3 Mutation evidence (the tests are not vacuous)

| mutation (temporary, reverted) | result |
|---|---|
| `requestStart` moved **before** `dismiss()`/`open()` | `testThePushedCallRoutePopsThenOpensTheDMThenAsksThePaneToJoin` **fails**: `["start …/channel-dm", "dismiss", "open"]` is not `["dismiss", "open", "start …/channel-dm"]` (`build/logs/t_10d3db63-mut-order.log`) |
| the intent guard flipped (`if intent == .open`) | **2 failures**: the Call test records no start; the Message test records one (`build/logs/t_10d3db63-mut-intent.log`) |

Both reverted; the restored tree is what the runs in §3 measure.

---

## 2. Finding 2 — the duplicate is runtime-scoped

C4's diagnosis of C3's pinned-author-tap failure ("the pinned sheet is over the channel pane, the same
post is drawn twice, `.firstMatch` answered the covered copy") is **right for the runtime C3 measured**
— iPhone 16 Pro / iOS 18.x, where `push6.log` records the header at y 637.6 against the sheet's row at
y 720. It is **not** a property of the host: on `origin/main` (`ffc22f7`) built for iPhone 17 Pro
**iOS 26.5** the identifier is exposed once (probe `copies=1`, 36 pt, inside the row, hittable) and the
pre-fix app-wide lookup passes (`build/logs/t_76a52cbe-mut-lookup.log`, 1 run / 0 failed). The 18.5
simulator on this host would not launch the app, so the 18.x shape is recorded from C3's tree, not
re-measured here.

Corrected, in the two places the record stated it as universal:

* `docs/t_dc0ea74d-build-note.md` §3 — the narrative and its table now say "on the runtime C3 measured
  (iPhone 16 Pro / iOS 18.x)", and a new **§3.1** carries the iOS 26.5 probe, the pre-fix lookup pass,
  and the sentence the card asked for: *"on the runtimes measured (iOS 18.x) the identifier was drawn
  twice; the row-scoped lookup makes the tap independent of whether the covered copy is exposed (iOS
  26.5 exposes one)."* §5's limits bullet is scoped the same way, and its Call-route bullet now points
  at the seam from §1.
* `docs/parity.md`, T41 row — the same scoping, plus a pointer to the new route pin and §3.1.

**The fix is not reverted and the product-defect claim is not re-opened** — the row-scoped lookup is
correct in both shapes, which is the reason to keep it, and the product was never at fault in either
run.

---

## 3. Runs

Host: macOS 26.3.1, iPhone 17 Pro simulator **iOS 26.5**, derived data outside the TCC folders
(`scripts/qa-test.py`'s default). Logs are `build/logs/` in this checkout.

| run | spec | outcome |
|---|---|---|
| `t_10d3db63-route-units` | `--platform ios --only-testing MattermostTests/T5449ProfilePresentationTests` | **6 run / 0 skipped / 0 failed** (`build/logs/t_10d3db63-route-units.log`) — the three existing pins + the three new ones |
| `t_10d3db63-mut-order` | same file, `requestStart` moved before the pop (temporary) | **1 run / 1 failed** — the Call test, on the order alone; reverted |
| `t_10d3db63-mut-intent` | same file, guard flipped to `.open` (temporary) | **6 run / 2 failed** — Call and Message; reverted |
| `t_10d3db63-units-full` | `--platform ios --only-testing MattermostTests` (whole unit target) | **1833 run / 8 skipped / 0 failed**, `** TEST SUCCEEDED **` (`build/logs/t_10d3db63-units-full.log`) — 1830 before this card + the 3 new tests; the 8 skips are the target's standing ones, unchanged |
| `t_10d3db63-units-catalyst` | `--platform mac --only-testing MattermostTests` | **1833 run / 9 skipped / 0 failed**, `** TEST SUCCEEDED **` (`build/logs/t_10d3db63-units-catalyst.log`) — the Catalyst-only halves of the standing skips |

No XCUITest was run or changed: nothing in this card presses a control, and the SwiftUI change is
confined to a method body whose behaviour is pinned by the unit target.

---

## 4. Limits that stay

* `openConversation`'s forwarding line is not executed by any test (§1.2) — the ordering it forwards to
  is, exhaustively.
* The pushed Call row is still **not pressed live**. A real calls session is T44d §4.2's audio hazard,
  and CI never runs XCUITest; the sheet's live test remains the only live Call-path measurement.
* The iOS 18.x duplicate shape is not reproducible on this host (the 18.5 simulator will not launch the
  app); §3.1 cites C3's log and the iOS 26.5 probe rather than claiming a fresh 18.x run.
