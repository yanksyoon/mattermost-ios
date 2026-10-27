# T34-R5 follow-up — the socket that stays open and stops delivering: an idle-delivery watchdog

Card `t_d2eace51` (follow-up of `t_bb3d3d64`, the reconnect resync; build note
`docs/t34-socket-resync-build-note.md`). Base `389516d` (== `origin/main` when this card started).

The card's question is the hole that note's §4 named and did not repair: **a socket that keeps its
TCP/WebSocket connection, still answers the heartbeat (`ping` → pong), and simply stops delivering
server events is invisible to the client.** `handleOpen` is the only place a resync fired, and there is
no open. The T34-R5 failing runs logged `socket open` / `authentication_challenge` / `ping` and no
`posted` frame, with no `connection lost` / retry line either — so the observed flake *may* be this
wedge rather than a reconnect. **Nobody has proven which it was, and this note does not claim the flake
is fixed** (see §6).

## 1. What was built

A **delivery watchdog** in `SocketClient`, gated on a caller-supplied visibility answer, plus the two
app seams that carry that answer and the repair:

| file | change |
| --- | --- |
| `Mattermost/Core/MM/SocketClient.swift` | `StallWatchdog` (threshold / check interval / quiet multiplier), `ResyncReason.stalled`, an injected `isSurfaceVisible` predicate, the watchdog loop and per-connection lifecycle; the delivery clock (`lastServerEventAt`) is advanced **only** by a delivered server event, never by a pong; new diagnostics `pongCount`, `stallResyncCount`; `resyncCount` now means "resync requests" (reconnect + stall). |
| `Mattermost/UI/Native/Sidebar/TeamSidebarCoordinator.swift` | `TeamEventSourcing.setSurfaceVisibilityHandler(_:)` (empty default, so fakes still compile); `SocketTeamEventSource` passes the predicate and the watchdog config to every client, reads the handler **at call time**, logs the "no handler" state instead of silently having no watchdog, counts `.stalled` gaps, and gained `stallWatchdog:` / `now:` test seams. `TeamSidebarCoordinator.isSurfaceVisible` + the handler it installs in `init`; `onSocketResync` now carries *both* kinds of gap (a pane does not need to know which). |
| `Mattermost/UI/Native/Channel/ChannelPaneCoordinator.swift` | `hasLoadedWindow(serverID:channelID:)` — the pane's half of the visibility answer. |
| `Mattermost/MattermostApp.swift` | the shell's answer: foreground **and** the location names a channel on **this** server **and** the native pane holds a **loaded** window for it. |
| `MattermostTests/T34SocketStallWatchdogTests.swift` | 5 tests (below), with two clocks: a hand-stepped one where the heartbeat must really exchange a ping/pong, and an instant one + `TestNow` where the reconnect's jittered backoff must be let through. |
| `MattermostTests/T28TestSupport.swift` | `ScriptedSocketTransport` can now **answer every `ping` with the protocol's pong** (`answersPingsWithPong`, `pongsAnswered`) — the "open and pingable, delivering nothing" shape, without a fake standing in for the client. |
| `MattermostTests/T34SocketResyncTests.swift` | two lines: `stallWatchdog: nil` in its two `SocketTeamEventSource` builds. That file pins the **reconnect** path on an auto-releasing clock, where a watchdog loop would spin. No assertion in it changed — mutation C below re-measures its guarantee. |

The repair itself is the **same** resync the reconnect path runs — `TeamSidebarCoordinator.socketResynced`
→ `onSocketResync` → `ChannelPaneCoordinator.resync(serverID:)` → `ChannelViewModel.resyncAfterReconnect()`
(merge the newest page + a forward-only `last_viewed_at` into every warm window of that server, never a
reload). Nothing new was written to decide *what* to refetch; a gap is a gap.

## 2. The numbers, and why

`StallWatchdog(threshold: 150, checkInterval: 30, quietMultiplier: 4)`.

* **Threshold 150 s** — five heartbeat intervals. A pong proves the socket is *pingable*, not that it is
  *delivering*; that distinction is the whole card, so the window cannot be shorter than the 30 s cadence
  that gives "silence" meaning. It also has to be longer than an ordinary quiet spell: two minutes with
  nothing said in a channel is normal, and a shorter window would turn a healthy quiet server into a
  poll. Detection is at most `threshold + checkInterval` = **3 minutes**, which is the bound on how long
  a reader can sit in front of a stale window.
* **Check interval 30 s** — the granularity the socket already pays for (its heartbeat), and it is the
  only thing added to the timer budget.
* **Quiet multiplier 4** — after a fire that is followed by more silence the wait doubles (150 → 300 →
  600 s, capped at 4× = 10 min); **any** delivered server event resets it. Without it an
  idle-but-visible pane would pay a full warm-window sweep (≤6 channels × `posts` + `membership` = ≤12
  requests, and a 60-row page is not a small response) every 2.5 minutes forever. With it the steady-state
  cost is ≤12 small requests per 10 minutes, and a socket silent for an hour is not treated as more
  suspicious than one silent for three minutes. **The cost of the cap is a worst-case 10-minute recovery
  latency on a wedge that begins after a long quiet spell** — stated here rather than hidden.

Two things the watchdog deliberately does **not** do:

* **It does not fire while nothing is on screen.** The predicate is asked *last*, only when the silence
  already looks wrong, and `false` marks nothing, so the next tick asks again. An idle-but-healthy socket
  in the background costs no requests.
* **It does not recycle the connection.** A truly wedged socket could be forced to reconnect — but the
  app's one WebSocket per server is also what Calls rides (`TeamSidebarCoordinator.callsTransport`), and
  recycling it would drop a live call to fix a stale page. The resync restores the data over REST; the
  connection is left alone.

Not started at all when the caller supplied a `StallWatchdog` but **no** visibility predicate: a timer
that can only guess is either a poll or a no-op. `SocketTeamEventSource` logs that state when it builds
such a client, because "a seam nothing passes" is exactly what shipped for two rounds in T34-R5.

## 3. Where "visible" comes from

`SocketClient` holds no view and must not guess, so the app answers, the same way
`NotificationWorker.visibleChannel` is answered:

```
MattermostApp.bindShellStores:
  teamSidebarCoordinator.isSurfaceVisible = { serverID in
      app is active
      && navigation.acceptsNativeRouting              // the native pane is what renders it
      && location.serverID == serverID
      && location.channelID is non-empty
      && channelPaneCoordinator.hasLoadedWindow(serverID:channelID:)   // a `.loaded` model
  }
```

A `.loading` / `.failed` model answers `false` on purpose: its own load is the fetch, and a window that
never loaded has nothing a refetch could put right. This also means the gate matches the repair exactly:
today the only pane that refetches is the channel pane, so the only thing that counts as "visible" is a
loaded channel window.

## 4. Tests, and the runs that back them

`MattermostTests/T34SocketStallWatchdogTests.swift` — 5 tests, Mac Catalyst:

| test | what it pins |
| --- | --- |
| `testASilentButPingableSocketRefetchesTheOpenWindow` | **the card's scenario.** A scripted transport answers **every** ping with a pong and pushes no event; two ping/pong round-trips prove the socket is alive (the second ping is only reachable if the first pong was consumed — the heartbeat recycles on one missed pong); no server event for the window ⇒ the `posted` the server holds (`b`) appears in the open pane with **no relaunch**, 2 newest-page requests (1 load + 1 sweep), `rail.socketResyncCount == 1`, `source.stallResyncCount == 1` ("found by silence, not by a reconnect"). |
| `testAQuietSocketWithNothingOnScreenDoesNotRefetch` | the card's negative half: the same silent-but-pingable socket with `isSurfaceVisible == false` never refetches — 1 page request, no resync anywhere. |
| `testAReconnectDoesNotDoubleFireAndRestartsTheWatchdogsWindow` | a reconnect's own resync (§T34-R5) does **not** get a second sweep: the watchdog's window restarts at the open, so nothing fires below the threshold — and a socket that reconnects and then stays silent *is* the wedge again, one window later, and is repaired then. |
| `testASocketThatKeepsDeliveringIsNeverTreatedAsStalled` | four `posted` frames a little under the window apart (120 virtual seconds of a live socket) ⇒ no stall resync, no refetch. |
| `testAClientWithoutAVisibilityPredicateNeverStartsWithAWatchdog` | a `StallWatchdog` with no `isSurfaceVisible` starts **no loop at all** (`parked == 0`) — the client refuses to guess. |

Runs (this host, Mac Catalyst, `scripts/qa-test.py --platform mac`):

| label | scope | outcome |
| --- | --- | --- |
| `t34stall-1` | `--only-testing MattermostTests/T34SocketStallWatchdogTests` | **5 run, 0 failed** (per-test times 0.15–0.36 s), `build/logs/t34stall-1.log` |
| `t34stall-resync-1` | `--only-testing MattermostTests/T34SocketResyncTests` (the parent's file, after the two-line seam) | **7 run, 0 failed**, `build/logs/t34stall-resync-1.log` |
| `t34stall-units` | `--only-testing MattermostTests` (whole unit target) | see §7 — recorded in `build/logs/t34stall-units.log` |
| `t34stall-mutationA` | the watchdog is **never started** (`startStallWatchdog()` deleted from `handleOpen`) | **3 of 5 red**, including the card's test (`one gap, one refetch` = 0), `build/logs/t34stall-mutationA.log` |
| `t34stall-mutationB` | the **visibility gate** is not consulted | exactly the negative test red (`testAQuietSocketWithNothingOnScreenDoesNotRefetch`: 1 request where 0 is owed), 4 green, `build/logs/t34stall-mutationB.log` |
| `t34stall-mutationC` | `resync:` argument deleted from `SocketTeamEventSource` again | exactly `testAPostMadeWhileTheSocketWasDownAppearsAfterTheReconnect` + `testAHandlerInstalledAfterTheConnectionStillReceivesTheReconnect` red, 5 green — the parent card's mutation-A guarantee is **unchanged**, `build/logs/t34stall-mutationC.log` |

Re-derived on the rebased tree (`b684370`, onto `origin/main` `5ccbb5d`), because a rebase is a new tree
and the pre-rebase reds do not carry over:

| label | outcome |
| --- | --- |
| `t34stall-mutA-rebased` | **3 of 5 red** — the card's test fails by name (`one gap, one refetch` = 0), `build/logs/t34stall-mutA-rebased.log` |
| `t34stall-mutB-rebased` | exactly `testAQuietSocketWithNothingOnScreenDoesNotRefetch` red (1 request where 0 is owed), `build/logs/t34stall-mutB-rebased.log` |
| `t34stall-mutC-rebased` | exactly the parent's two wiring tests red, 5 green, `build/logs/t34stall-mutC-rebased.log` |

## 5. The other live panes — decided, and why only one joins

The card asks for a decision on the thread pane, the mentions feed, channel info and presence. **They do
not join `onSocketResync` in this card.** The reasons are concrete, not a shrug:

* **Thread pane (T36) and mentions feed (T42): they should join, and they cannot join yet.** Both panes'
  only refetch today is `reload()` / `performInitialLoad()`, which **replaces** the window and flips
  `phase = .loading`: the reader's list blanks to a spinner and every older page (`loadEarlier()`'s
  replies / the mention window's pages) is dropped. That is the exact defect T34-R5 rejected when it
  chose a merge over a reload for the channel pane. Joining means writing a merge per pane — the thread
  needs the root + the newest replies page + `reply_count` + the follow/unread row merged into what is
  held; the mentions feed needs its rows merged against read cursors it has already adopted. Filed as a
  follow-up card rather than guessed at here, and the seam they will use is the one that already exists
  (`onSocketResync`), which is now reason-agnostic.
* **Channel info (T40): stays on next appearance.** Its rows are membership/rename/archive facts a
  reader re-reads every time the screen appears, there is no long-lived window a lost frame silently
  corrupts, and a mid-screen refetch would reload a list under the reader's finger.
* **Presence (T41): stays.** Presence is eventual by construction: the next `status_change` /
  `user_updated` for that user self-heals it, and the memory reloads on appearance. A resync would have
  to sweep every profile the process remembers (a request per user) to repair something that repairs
  itself on the next event.

Until then the watchdog's **gate names the channel pane only** (`hasLoadedWindow`), so the watchdog stays
quiet while a thread pane covers the channel — the sweep it would run repairs windows nobody is looking
at, and the thread pane's own repair is the follow-up card.

## 6. What this does **not** prove, and the limits that stay

* **Whether the observed T34-R5 loss was a stall is still unproven.** The surviving log excerpt shows
  `socket open` / `authentication_challenge` / `ping` and no `posted`, and no `connection lost` line —
  which *suggests* an open socket that stopped delivering, but the excerpt is partial. This card makes
  that case **repairable**, it does not demonstrate that it happened, and **the flake is not claimed
  fixed.**
* **A stall is repaired within ~3 minutes, not within a test's 30 s wait.** A live T34 run that posts a
  message and waits 30 s would still fail on a stall: the watchdog's bound is `threshold + checkInterval`.
  It is a user-facing repair, not a rescue for the live suite.
* **A permanently silent socket is kept current, never reconnected** (§2). The connection is left alone
  because Calls rides it.
* **The refetch is the full warm-window sweep** (≤6 channels × 2 requests per fire), because it is the
  same resync the reconnect path runs — the card asked for exactly that. The quiet multiplier caps the
  steady-state cost; it does not make a single fire cheaper.
* **A post deleted while the connection was down / more than one page of traffic during an outage**:
  unchanged from `docs/t34-socket-resync-build-note.md` §4 (the newest 60 rows are what a sweep can see).
* **The gate is the channel pane.** While a thread pane, the search sheet or a detail screen covers it,
  the watchdog does not fire (the app answers `false`), and the badge counters are not repaired by it —
  they heal on the next delivered event or the next activation.
* **No live (XCUITest) variant.** Making a running app's socket go silent from outside needs a debug
  launch-argument seam that kills only the *inbound* frames; the card's ask was a scripted transport, and
  that is the stronger proof because it drives the production source and the production merge rule.

## 7. Runs at the pushed commit

The tree was rebased onto `origin/main` `5ccbb5d` (the anchor-pin card `t_a4d02070` published while this
card was running; only the `docs/parity.md` T34 row conflicted, resolved by taking `origin/main`'s line and
re-applying this card's two edits to it). Everything below is the **rebased** tree at `b684370`.

* `t34stall-1` — `T34SocketStallWatchdogTests` **5/5 green** (`build/logs/t34stall-1.log`), re-derived by the
  whole-target run below.
* `t34stall-resync-1` — `T34SocketResyncTests` **7/7 green** — the reconnect card's file, unweakened
  (`build/logs/t34stall-resync-1.log`).
* `t34stall-units-rebased` — `MattermostTests` whole target at the rebased tree: **1619 run, 7 skipped,
  0 failed** (114 s). `origin/main` measured 1614 before this commit; the difference is exactly this
  card's 5 new tests (`build/logs/t34stall-units-rebased.log`). The pre-rebase run on `389516d` was
  1608 run / 0 failed.
* Mutations A / B / C as tabled in §4 — measured, not asserted, each re-run on this tree.

## 8. Repro

```
# the watchdog's own tests (no server, no simulator)
python3 scripts/qa-test.py --platform mac --only-testing MattermostTests/T34SocketStallWatchdogTests --label t34stall
# the reconnect file it must not weaken
python3 scripts/qa-test.py --platform mac --only-testing MattermostTests/T34SocketResyncTests --label t34stall-resync
# whole unit target
python3 scripts/qa-test.py --platform mac --only-testing MattermostTests --label t34stall-units

# mutation A: delete `startStallWatchdog()` from `SocketClient.handleOpen`
#   expected: testASilentButPingableSocketRefetchesTheOpenWindow red ("one gap, one refetch" = 0)
# mutation B: delete `guard await isSurfaceVisible() else { return true }` from `stallWatchdogTick`
#   expected: testAQuietSocketWithNothingOnScreenDoesNotRefetch red
# mutation C: delete the `resync:` argument in `SocketTeamEventSource.events(for:)`
#   expected: T34SocketResyncTests' two wiring tests red (the parent card's guarantee)
```
