# T34-R5 follow-up — the socket's missing half: a reconnect now refetches what it missed

Card `t_bb3d3d64` (product half of the T34 socket flake; the test half was `t_667988fd`, T34-QA).
Base `a96bde0` (== `origin/main` when this card started). No surface flag changes: this is the rail's
socket and T34's pane, both already behind `-surfaceMode shell=native`.

The card asked one question and one test:

1. **Decide** whether `SocketTeamEventSource` / the channel pane passes a `resync` closure to
   `SocketClient`, or whether the pane refetches on its own when the socket reports a gap — or, if the
   answer is "no resync by design", say so where the limit is documented.
2. **A test that can fail** for that path. Today nothing tested it.

**Answer to (1): yes — a reconnect is a gap, and the pane now refetches on it.** `SocketClient` has
carried `resync: (@Sendable (ResyncReason) async -> Void)?`, invoked once per reconnect, since T28
(`SocketClient.swift:301-303`); `SocketTeamEventSource` built every client **without** it, so an event
the server published while the connection was down was never delivered and never refetched — permanent
until relaunch. That is now wired: `SocketTeamEventSource` → `TeamSidebarCoordinator.onSocketResync` →
`ChannelPaneCoordinator.resync(serverID:)` → `ChannelViewModel.resyncAfterReconnect()`.

**Answer to (2): the unit half of the card's own alternative**, and more than it asked for: the tests
drive the **real** `SocketTeamEventSource` and `SocketClient` over a scripted transport through the real
coordinator and the real list model — no fake stands in for the seam the defect was in. Mutation A
(deleting the `resync:` argument again) fails exactly the two wiring tests; that is measured, not
asserted (`build/logs/t34resync-mutationA.log`).

## 1. The decision, and why not the other two options

| option | verdict |
| --- | --- |
| **pass a `resync` and refetch** (chosen) | A WebSocket reconnect loses everything the server published in between, and Mattermost does **not** replay it on the new connection. The client is the only party that knows the gap exists, and it already reports it once per reconnect. The refetch is what makes "the socket is live" mean "the window is current". |
| the pane refetches "when the socket reports a gap" | That *is* this option — the gap report is `SocketClient.resync`. There is no second channel through which a gap is reported, so "the pane does it on its own" would mean polling, which is strictly worse (a request per interval, awake or not). |
| no resync by design | Rejected: it makes a dropped frame permanent. T34-R5 measured a `posted` that reached no model at all, and an 8 s or 30 s delay before the post changed nothing, so this is not "the post was made before the socket was up". |

The resync is deliberately **narrow**:

* it refetches the **newest page** (60 rows, `collapsedThreads=true` — the same request the first load
  makes) and **merges** it. `reload()` would replace the window and drop every older page the reader
  scrolled back through, and with it the scroll anchor;
* rows already held are **replaced in place** (an edit made while the socket was down), never reordered;
* `last_viewed_at` is refetched from `GET /channels/{id}/members/me` and adopted only when it moved
  **forward** (the channel was read on another client), which is what moves the "New messages" divider;
* it runs for **every warm channel** of that server, not just the one on screen: the socket is
  server-scoped, so a `posted` for any of the six kept windows can have been lost, and a channel
  switched to afterwards that quietly lacks a message is the same defect one tap away;
* it is a **no-op on a model that never loaded** (its first load is the fetch) and a **failed** refetch
  leaves the window and the phase alone — the rows on screen are still the server's page as of the last
  load, and the next reconnect tries again.

Cost, stated rather than hidden: one `posts` request plus one `membership` request per warm channel per
reconnect (≤6 channels ⇒ ≤12 small requests). A reconnect is rare, and the alternative is a wrong
window. The handler itself is **synchronous** (`TeamSidebarCoordinator.socketResynced`): `SocketClient`
awaits `resync` on its open path, before the receive loop reads the next frame, so the refetch is
started as its own task by the app wiring (`MattermostApp`, `Task { await channelPaneCoordinator?.resync(…) }`).

## 2. What changed (files)

* `Mattermost/UI/Native/Sidebar/TeamSidebarCoordinator.swift`
  * `TeamEventSourcing.setResyncHandler(_:)` — new protocol requirement, with an empty default for the
    test fakes, so a fake that does not model reconnects still compiles (the same degradation rule as
    `transport(for:token:)`'s `nil` default in T44d).
  * `SocketTeamEventSource` passes `resync:` into every `SocketClient`, reading the handler **at call
    time** (a handler installed after the first connection still receives the next reconnect). No
    handler installed is **logged**, not swallowed — that silent state is what shipped for two rounds.
  * `SocketTeamEventSource` gained three test seams next to the ones `SocketClient` already has: a
    `transportFactory`, a `clock`, and `heartbeatInterval` (`nil` disables the 30 s heartbeat). The
    heartbeat seam is not decoration: the heartbeat **recycles the connection** on a missed pong, so a
    test driving reconnects through a released clock would otherwise produce heartbeat reconnects it
    cannot tell from the one it caused (the first version of this test did exactly that).
  * `TeamSidebarCoordinator.onSocketResync: ((UUID) -> Void)?` + `socketResyncCount`, and
    `socketResynced(_:)`, which counts the reconnect, hands it to the panes, and refetches the team
    counters through the existing debounced path (a resync is exactly the case where a local increment
    would have missed events).
* `Mattermost/UI/Native/Channel/ChannelPaneCoordinator.swift` — `resync(serverID:) async -> Int`:
  resyncs every **loaded** model of that server, counts the round (`resyncCount`).
* `Mattermost/UI/Native/Channel/ChannelViewModel.swift` — `resyncAfterReconnect() async -> Int`, the
  merge rule above, plus `resyncCount` / `lastResyncInsertedCount` diagnostics.
* `Mattermost/MattermostApp.swift` — the one wiring line in `bindShellStores`, beside the existing
  `onTeamEvent` / `onServerEvent` / `onSocketStateChange` fan-ins.
* `MattermostTests/T34SocketResyncTests.swift` — 7 tests (below).
* `docs/parity.md` — the T34 row's limits now state what this repair covers and what it does not.

## 3. Tests, and the runs that back them

`MattermostTests/T34SocketResyncTests.swift` (7 tests, `MattermostTests` on Mac Catalyst):

| test | what it pins |
| --- | --- |
| `testAPostMadeWhileTheSocketWasDownAppearsAfterTheReconnect` | the card's scenario: pane open on page 1 ⇒ `first.close()` ⇒ the server now holds `b` and nothing is pushed on the second connection ⇒ `second.push(.opened)` ⇒ **`b` appears with no relaunch**; exactly 2 newest-page requests (1 load + 1 refetch); `socketResyncCount == 1`, `pane.resyncCount == 1`, `model.resyncCount == 1` |
| `testAFirstConnectDoesNotRefetchTheWindowAndTheSocketStillDelivers` | a **first** connect must not refetch — and a live `posted` frame still travels the ordinary path, so "no refetch" is measured with the pump provably working |
| `testAHandlerInstalledAfterTheConnectionStillReceivesTheReconnect` | the handler is read at call time, not captured when the client was built |
| `testAResyncMergesTheNewestPageAndKeepsTheOlderPagesTheReaderLoaded` | new row inserted, held row replaced by the server's copy, reply kept out (`isTimelineRow`), older page still loaded |
| `testAResyncAdoptsALastViewedAtThatMovedForwardAndNeverMovesItBack` | the "New messages" divider moves to where the server says, and a stale membership row cannot move it back |
| `testAnIdlePaneIsNotResynced` | an unopened channel is not refetched |
| `testAFailedResyncLeavesTheWindowAndThePhaseAlone` | a 503 mid-refetch leaves the window and `.loaded` intact; the attempt is still counted |

Runs (this host, Mac Catalyst, `scripts/qa-test.py --platform mac`):

| label | scope | outcome |
| --- | --- | --- |
| `t34resync-5` | `--only-testing MattermostTests/T34SocketResyncTests` | **7 run, 0 failed** (80 s), `build/logs/t34resync-5.log` |
| `t34resync-units` | `--only-testing MattermostTests` (whole unit target) | **1603 run, 7 skipped, 0 failed** (108 s), `build/logs/t34resync-units.log` |
| `t34resync-mutationA` | `resync:` argument deleted from `SocketTeamEventSource` | **9 assertion failures, 2 tests red** — only the two wiring tests (the other five test the merge rule directly), `build/logs/t34resync-mutationA.log` |
| `t34resync-mutationB` | the merge replaced by a reload (`posts = fresh`) | **red as it must be**: the older page and the held row are dropped (`["b"] is not equal to ["b", "a"]`, `["d"] is not equal to ["d", "c", "b", "a"]`), `build/logs/t34resync-mutationB.log` |

Mutation A is the evidence the card asked for: with the closure gone the test that says "the lost post
appears" fails, and it fails for the right reason (no refetch happened), not because something else
broke.

**These runs were made in a worktree, on purpose.** The shared checkout was mid-edit by a sibling card
(`t_a4d02070`, the T34 restore-wiring work) and did not compile at the time (`MattermostApp.swift`
multi-line string indentation, in that card's hunk), so this branch was built and tested at
`.worktrees`-equivalent `HEAD` + this diff only, in
`/Users/yangsooyoon/.hermes/kanban/boards/mattermost-ios/workspaces/t_bb3d3d64/repo`. The log files
therefore record that path in their absolute filenames; the code they ran is exactly the commit this
note ships with.

## 4. What this does **not** prove, and the limits that stay

* **Whether the observed T34-R5 loss was a reconnect is still unproven.** The surviving log excerpt from
  `docs/t34r5-build-note.md` §5 shows `socket open` / `authentication_challenge` / `ping` and no
  `posted`; it also shows no `connection lost` line, which *suggests* the connection stayed up and the
  server simply did not deliver — a case this repair cannot catch, because there is no reconnect to
  report. The excerpt is partial (only the quoted lines survive), so this is a suggestion, not a
  measurement. Raising it rather than claiming the flake is fixed: what this card fixes is the gap the
  code provably had.
* **A socket that stays open and stops delivering is not repaired.** The heartbeat still exchanges pings,
  the connection never drops, and no resync fires. Catching that needs an idle-delivery watchdog (open +
  authenticated + no server event for N minutes while a pane is visible ⇒ treat as a gap). Filed as
  `t_d2eace51` (this card's follow-up) rather than guessed at here.
* **A post deleted while the connection was down stays drawn.** The newest page does not carry deleted
  posts, and a merge never removes a row it was not told about; the row corrects on the next page load.
* **More than a page of posts during one outage**: the newest 60 rows are refetched, so a channel that
  received more than 60 rows while the socket was down shows the newest 60 and the rest only after
  `loadEarlier` (which is the same 60-row page rule the pane already has).
* **Only the channel pane resyncs.** The thread pane, the mentions feed, channel info and presence still
  repair on their next appearance. `TeamSidebarCoordinator.onSocketResync` is the seam for them; each
  needs its own merge rule, and inventing one per pane inside this card would have been guesswork.
* **No live (XCUITest) variant of this test.** Killing the app's own transport from outside the process
  needs a debug launch-argument seam that closes the socket on demand; that belongs to the T34 live suite
  (QA lane), not here. The card allowed the unit alternative, and this is the stronger of the two because
  it drives the production source rather than a fake.

## 5. Repro

```
# unit target, Mac Catalyst (no server, no simulator)
python3 scripts/qa-test.py --platform mac --only-testing MattermostTests/T34SocketResyncTests --label t34resync
python3 scripts/qa-test.py --platform mac --only-testing MattermostTests --label t34resync-units

# mutation A — the wiring is what the test needs
#   remove `resync:` from the SocketClient(...) construction in SocketTeamEventSource
python3 scripts/qa-test.py --platform mac --only-testing MattermostTests/T34SocketResyncTests --label t34resync-mutationA
# expected: testAPostMadeWhileTheSocketWasDownAppearsAfterTheReconnect +
#           testAHandlerInstalledAfterTheConnectionStillReceivesTheReconnect red, 5 green
```
