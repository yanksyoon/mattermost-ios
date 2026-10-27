# T43 — one live mention input per server

Card: **T43** (notification-input convergence). Design of record:
`.hermes/plans/2026-10-08_mattermost-desktop-ios-migration.md` (Path A). Parity rows: `docs/parity.md`
(T8 notifications, T14 polling, this card's row).

## 1. The problem, stated as a measurement

The shell had **two** things that could turn a post into a banner:

* the webview's `notify_mention` bridge frame, which the web app emits when it decides to notify
  (`WebViewContainer.Coordinator.handleNotifyMention` → `NotificationWorker.presentMention`), and
* `MentionPoller` (T14), which polls mention counters while the app is backgrounded and then builds its
  own `MentionNotification`.

Each owned its own dedupe state (`MentionPoller` persisted `ServerMentionState` in `AppPreferences`;
the bridge path owned nothing). Nothing prevented a post that the poller had already delivered from being
delivered again by the bridge, or — the case that matters once any surface renders natively — by a second
input reading the same socket. And the worker's foreground rule was *server-wide*: while the app was in the
foreground on server S, **every** mention of S was suppressed, including mentions in channels the reader was
not looking at.

T43 makes the input a **choice**: exactly one live input per server, one high-water mark shared by both, and
a policy that mirrors the server's own decision instead of guessing.

## 2. What was measured against the server, not assumed

`scripts/t43_notification_probe.py` against the pinned **9.11.19** server at `http://127.0.0.1:8065`
(full output: `docs/t43-notification-probe-2026-10-27.log`, **9 PASS / 0 FAIL**, exit 0):

| Question the input path depends on | Measured answer |
| --- | --- |
| Does `GET /users/me` carry the desktop setting? | Yes — `notify_props` = `channel, comments, desktop, desktop_sound, desktop_threads, email, email_threads, first_name, mention_keys, push, push_status, push_threads` (`desktop: mention`, `desktop_sound: true`, `channel: true`, `mention_keys: ""`). |
| Does a channel membership carry a per-channel override? | Yes — `desktop: default`, `ignore_channel_mentions: default`, `mark_unread: all` (and `mark_unread: mention` on the muted fixture). |
| Is a muted channel still a notification? | Yes — posting a mention in the muted channel moved the server's own `mention_count` 1 → 2. So mute is **not** consulted for a real mention. |
| Does the `posted` event carry `props.mentions`? | **No** — `props: {}`. The reader's own keys are the shipping path (the same finding T42 recorded). |
| Does a DM membership carry `notify_props`? | Yes — a DM notification is decided from the membership, like a channel. |
| Is `@perf` a mention of `@perfprobe`? | No — whole-token match only (T42's `MentionKeys`, reused). |

## 3. What was built

New directory `Mattermost/UI/Native/Notification/` (6 files, all target members through
`PBXFileSystemSynchronizedRootGroup` — no `project.pbxproj` edit):

| File | Role | Counterpart it mirrors |
| --- | --- | --- |
| `NotificationInputRouting.swift` | **Pure decision**: `NotificationInputMode` (`.bridge` / `.socket`), the gate (`acceptsBridge`, `acceptsSocket`), the set of servers whose socket is live, and the per-input counters the Settings read-out shows. | desktop `src/main/notifications/index.ts` — every renderer `NOTIFY_MENTION` funnels through **one** `NotificationManager`; there is no second path. |
| `NotificationPathStore.swift` | The switch: launch argument `-notificationPath socket\|bridge\|native\|web` → persisted debug override → compile default (`.bridge`). Debug-only affordances, exactly like `SurfaceModeResolver` / `RenderMode`. | desktop's notification toggle, but resolving the way this repo already resolves surfaces. |
| `MentionNotificationPolicy.swift` | The decision `posted` → deliver/drop, from the server's own inputs: account `notify_props.desktop ∈ {all, mention, none}`, channel `notify_props.desktop`, `ignore_channel_mentions ∈ {all, root, never}`, `desktop_sound`, DM/GM rules, own post, deleted, system post, and a whole-token key match **including** `@channel`/`@all`/`@here` when `notify_props.channel == "true"`. | server `app/notification.go` `sendNotification`; mobile v2.45.0 `app/utils/notification/index.ts`. |
| `MentionLedger.swift` | **One** per-server high-water mark (`watermarkTs` + `watermarkPostID`) and one 500-id ring, shared by both inputs; `merge` unions the ring instead of replacing it, so a socket event that lands while a poll is in flight is not lost. Persisted under the **same** key T14 used. | the dedupe T14 already shipped, now owned by both inputs. |
| `NativeNotificationFeed.swift` | The native input: consumes the rail's `posted` events, applies the policy, builds the *same* `MentionNotification` the bridge builds, delivers through `NotificationWorker.presentMention`, coalesces one badge read per burst, keeps a bounded diagnostic ring (`lastRecord`). | mobile v2.45.0 `app/actions/websocket/posts.ts` (`posted` handling). |
| `NotificationInputSection.swift` | The Settings read-out (a section, not a screen): which input is live, web-view panes mounted, servers with a live socket, `delivered · suppressed` from the socket, `accepted · refused` from the webview, and the last mention's post/channel/outcome. | — (diagnostic surface for the `-AV` gate). |

### 3a. Dual-render: who is the input when the webview is mounted

`NotificationInputRouting` also tracks **which servers' panes are the web app** (`WebViewContainer`
reports mount/unmount). A mounted webview makes the **page** that server's input and silences the socket.

This was not the first design, and the first design was wrong in a way only a live run could show. With
the socket as the input and the webview mounted, a mention reached `NotificationWorker`, whose
`visibleChannel` answers `.unknown` for a webview pane (the shell cannot see inside it), so the
conservative T8 rule suppressed it — while the gate refused the page's own report at the same time.
Measured on the first dual-render run: `delivered=0 suppressed=1 mentions=1` — **zero banners**, not two.
The rule is therefore a measurement: the side that can see the screen is the input, and the other one is
silent. It also means the flip is safe — the native socket takes over exactly when the pane is native.

The unit test `testAMountedWebPaneSilencesTheSocketAndLetsThePageDeliver` drives the real
`WebViewContainer.Coordinator` through both panes.

**T43-R (F2): what the *live* dual-render test can actually observe, and what it cannot.** The T43 version
asserted `accepted <= 1` after mounting the web app next to the live socket — and that assertion was
vacuous, because `window.desktop.notifyMention` is installed only with `-desktopBridge`
(`WebViewStore.desktopBridgeEnabled`, off by default: advertising the shim sends the web app down its
Electron path, where the channel view never loads — README "What is not there yet"). In the shipped
configuration the page **structurally cannot emit a `notify_mention` frame**, so `accepted` is 0 for a
reason that has nothing to do with the gate, and "≤ 1" was satisfied by zero evidence. The repair states
the reality instead of leaning on the wording:

* the Settings read-out now has `notificationPath.pageBridge` (`installed` / `not installed`) fed from the
  **same constant that decides whether the shim is installed**, so a run can say which of the two it is;
* `testDualRenderKeepsOneSourceAndNeverRefusesThePage` asserts the configuration's premises: `pageBridge`
  = "not installed", `webPanes` = 1, `liveSockets` = 1, the socket **0 delivered and 0 suppressed** (the
  gate stops it before the policy, so no delivery decision was made at all), the page **0 refused** — so
  zero banners is what this configuration produces *by construction*, not by arbitration;
* `testThePageBridgeIsInstalledOnlyWhenAsked` mounts the same pane **with** `-desktopBridge` and asserts
  the read-out flips to `installed` — otherwise `pageBridge` could be a constant and the run above would
  still pass;
* the one-source rule itself is proven where a page report exists: `testAMountedWebPaneSilencesTheSocketAndLetsThePageDeliver`
  and `testTheWebViewPathIsRefusedWhileTheSocketIsLive` inject the frame at the real
  `WebViewContainer.Coordinator.handleNotifyMention` call site (accepted=1 → one banner; refused while the
  socket is the input; accepted again once the socket is gone).

A live run *with* `-desktopBridge` cannot supply banner evidence even in principle on this host: the shim
makes the web app take its Electron path and the channel view never loads (`README` §"The workspace renders
after sign-in"), so the web app's own notification code never runs to emit anything. Passing the flag only
proves the shim's presence — which is what the test above measures.

Changed:

| File | Change |
| --- | --- |
| `Mattermost/Core/NotificationWorker.swift` | Owns the routing/path dependency and a channel-context value; **foreground suppression is per channel, not per server** (`visibleChannel` → `.channel(id)` / `.noChannel` / `.unknown`). `.unknown` (the webview pane, which cannot say which channel is on screen) keeps T8's conservative server-wide rule. |
| `Mattermost/Core/MentionPoller.swift` | Writes/reads the shared `MentionLedger` and emits the **same** `MentionNotification` the socket input emits, so both inputs are indistinguishable downstream. |
| `Mattermost/UI/Native/Sidebar/TeamSidebarCoordinator.swift` | One pre-scope event seam (`onServerEvent`) — the rail's socket is the one socket per server, and a mention in **another team** is still a mention of the reader, so the feed reads the stream *before* `TeamSocketScope` filters it. `onSocketStateChange` reports liveness. |
| `Mattermost/UI/WebViewContainer.swift` | `handleNotifyMention` refuses the page's frame while the native socket is live for that server, and counts the refusal. This single check is what makes a dual-render run (webview still drawing, native input live) produce one banner. |
| `Mattermost/MattermostApp.swift` | Owns the path store + feed, binds the seams above, installs the service factory, hands the rail's events over, calls `authPhaseChanged`, resolves a tapped mention and a deep link to the same `NativeLocation`, and passes both objects to `RootView`. |
| `Mattermost/UI/RootView.swift`, `UI/SettingsView.swift` | Thread the two objects to the Settings read-out (optional, so previews and any bare SettingsView call still compile). |
| `Mattermost/UI/Native/Activity/ActivityModels.swift` | `MentionKeys.matchesIncludingBroadcasts` — the *inbox* rule (`matches`) deliberately skips `@channel`/`@all`/`@here` because the mentions window is a personal-mentions search; a *notification* is the other question, and the server does notify a reader who enabled channel mentions. `matchedKey` is untouched. |

Fixtures and probes (both idempotent, both exit 0):

* `scripts/t43_notification_seed.py` — accounts `perfprobe` (reader) and `t43buddy` (the only way to
  produce a mention *of me*), channels `t43-notify` and `t43-muted` (`mark_unread: mention`).
* `scripts/t43_notification_probe.py` — the table in §2, asserted against the live server.

### 3b. T43-R: the ledger ordering (F1) and socket liveness (F3)

**F1 — the ring was written by an input that was not allowed to deliver.** `NativeNotificationFeed`
wrote `MentionLedger.observe` *before* the mode gate, so in the shipped `.bridge` mode — where the page
is the input and the socket delivers nothing — the socket still recorded every mention as handled.
`MentionPoller.isNew` refuses anything in the ring, so the next background poll could never deliver it.
Measured by T43-AV on post `rfu9jjxubtrdxm5kb4sipmfjkw` (`create_at 1793085556434`, `t43buddy` →
`@perfprobe` in `t43-notify`): the app's read-out never left `none` (no delivery, no record) while
`mm.mentions.state.34D540A3-…` gained `notifiedPostIDs = ["rfu9jjxubtrdxm5kb4sipmfjkw"]` and that
`watermarkTs`. The same hole existed in a dual-render pane, where the gate also answers "not me".

The rule now, and the code that enforces it:

| Where | Rule |
| --- | --- |
| `NativeNotificationFeed.handle` | the **gate is checked first**; a post this input is not allowed to deliver is counted for the read-out and written **nowhere** — it stays pollable. |
| the `.deliver` branch | the ring is written by the delivery attempt that actually happened (unchanged: the poller's own rule, so a denied permission is not retried every message). |
| the `.drop` branch | a drop writes the ring only when the **reader's own configuration** decided it (`MentionDropReason.recordsAsHandled`: `notificationsDisabled`, `channelNotificationsOff`, `mentionsIgnored`). `notAMention` and `noChannelContext` do **not**: the first is not a delivery decision the server agrees with, the second is a failed lookup the next poll may succeed at. |

Pinned by `MattermostTests/T43NativeNotificationFeedTests`: the old
`testTheSocketInputIsSilentInBridgeMode` asserted the bug ("the ledger is still fed"); it is now
`testInBridgeModeTheSocketDeliversNothingAndLeavesThePostPollable`, which asserts the post is **not** in
the ring *and* `MentionPoller.isNew` still returns true for it. `testAFailedLookupLeavesThePostPollable`
and `testAConfiguredDropIsRecordedAsHandled` pin the two directions of the drop rule, and
`testAMountedWebPaneSilencesTheSocketAndLetsThePageDeliver` gained the same negative for the dual-render
pane.

**F3 — liveness was reported before the handshake.** `TeamSidebarCoordinator` reported
`onSocketStateChange(server.id, true)` as soon as `SocketTeamEventSource.events(for:token:)` returned a
stream, but `SocketClient.start()` is fire-and-forget: it spawns the connect loop and returns, so the
read-out could say "1 live socket" while the WebSocket was still connecting. A mention posted into that
window was lost — measured as `testASocketMentionReachesTheShellOnce` failing once in four executions
(read-out `none` after the 40 s wait), then passing 3/3 on retry. Liveness is now reported on the **first
event the server sends** (`hello` is the protocol's first event on every connection) and withdrawn when
the pump ends. Pinned by `MattermostTests/T43RSocketLivenessTests` (stream created → nothing reported;
`hello` → exactly one `true`; a second event → no second report; stream closed → `false`).

Two consequences stated rather than hidden:

* the Settings read-out's `liveSockets` now reads 1 only after the server answered, so the AC1 test's wait
  means what it says ("a mention posted now will arrive on this connection");
* in the window between "stream created" and `hello` the socket is *not* the live input, so the web
  bridge is not refused there — it is the correct fallback for a connection that does not exist yet.

## 4. Decisions

1. **One source, chosen at the process boundary.** `NotificationInputRouting` is the single place both
   inputs ask "am I the input?" — the answer is per server, from two measurements the shell already has:
   *which pane is mounted* (a webview means the page is the input, because only it can see the screen) and
   *which sockets are live* (a native pane with a dead socket still falls back to the page, so a mention is
   never silently lost). Both rules are one-line predicates on one value type, so they are unit-tested
   rather than argued about.
2. **The flip is not taken here.** The shipped default stays `.bridge`, exactly as the card requires
   (`-AV` is the architect's adversarial validation, not this card's). `-notificationPath socket` proves
   the native input today, and the Settings section is the read-out that validation will judge.
3. **One ledger, read before write.** The feed reads `alreadyHandled` *before* it records the post. The
   first implementation recorded first and then checked, which made every first mention look like a
   replay — caught by `T43NativeNotificationFeedTests` (19 of 20 failing) before it could ship.
4. **The ring is written by the input that delivered.** (T43-R F1; the T43 text said the opposite.) The
   socket wrote the shared ledger whether or not it was the live input, on the theory that "this post
   exists" was still truthful — but the ring means *already handled*, and `MentionPoller.isNew` refuses
   its contents, so a mention the socket was gated out of became undeliverable everywhere. The gate is now
   checked before any write, a delivery attempt (or a drop the reader's own configuration decided) is what
   records a post, and a post that was neither delivered nor decided stays pollable.
5. **Foreground suppression compares the channel**, which is what the web app does for a focused channel,
   and what makes "a mention in another channel of the visible server is still one banner" true.
6. **The badge stays one arithmetic.** The feed never increments a number: it reads the server's
   per-team counters and hands them to `SessionStore` (`serverBadgeInput`/`applyServerCounters`), the same
   path T42 and T14 use. A failed counters read changes nothing rather than inventing a `+1`.

## 5. Evidence

| What | Command | Result |
| --- | --- | --- |
| T43 unit tests (rules) | `xcodebuild test … -only-testing:MattermostTests/T43NotificationInputTests` | **37 / 37**, `build/logs/t43-units5.log` |
| T43 unit tests (the path, with the real worker + session store, only the server faked) | `… -only-testing:MattermostTests/T43NativeNotificationFeedTests` | **21 / 21**, `build/logs/t43-units5.log` |
| Whole Catalyst suite (no regression in T8/T14/T42 or the bridge) | `xcodebuild test … -only-testing:MattermostTests` (Mac Catalyst) | **1483 run / 4 skipped / 0 failed**, `build/logs/t43-catalyst-full3.log` |
| Live UI, native pane + default + dual-render | `TEST_RUNNER_MM_AUTH_* python3 scripts/qa-test.py --platform ios --sim id=146D23D9… --only-testing MattermostUITests/T43NotificationUITests` | **3 run / 0 skipped / 0 failed**, `build/logs/t43-live9.log` |
| Live UI, T43 + T42 together (the shared mentions models did not regress) | same runner, both suites | **7 run / 0 skipped / 0 failed**, `build/logs/t43-live10.log` |
| Screenshots | exported from `t43-live10`'s attachments | `docs/t43-shots/t43-native-mention.png`, `docs/t43-shots/t43-dual-render.png` |

**T43-R verification (2026-10-27, iPhone 16 Pro / iOS 18.3.1 vs Mattermost 9.11.19 at `127.0.0.1:8065`).**
Clean derived data throughout: `~/Library/Developer/Xcode/DerivedData/t43r-catalyst` (never built before
this card) for Catalyst, `~/Library/Developer/Xcode/DerivedData/t43r-ui` for the live suite.

| What | Command | Result |
| --- | --- | --- |
| Probe (DoD) | `python3 scripts/t43_notification_probe.py --url http://127.0.0.1:8065` | **9 PASS / 0 FAIL**, exit **0**, `build/logs/t43r-probe.log` |
| T43 unit tests (three suites) | `xcodebuild test … -only-testing:MattermostTests` (Catalyst) | **37** input + **23** feed + **4** liveness = **64**, 0 failures, 0 skipped |
| Whole Catalyst suite (DoD) | same command, whole `MattermostTests` | **1,489 run / 4 tests skipped / 0 failures**, `** TEST SUCCEEDED **`, `build/logs/t43r-catalyst-full.log` (the four skipped are pre-existing, not T43's) |
| Live suite, five consecutive runs (DoD: ≥3) | `TEST_RUNNER_MM_AUTH_* python3 scripts/qa-test.py --platform ios --sim id=81A7F251… --only-testing MattermostUITests/T43NotificationUITests` | **4 run / 0 skipped / 0 failed** in each of `t43r-live1…5.log`; per-run AC1 (`testASocketMentionReachesTheShellOnce`): **17.450 s / 16.219 s / 16.141 s / 16.099 s / 15.998 s** — all passed; dual-render **22.368 / 22.369 / 22.475 / 22.475 / 22.556 s** |
| F1 ledger A/B | `--only-testing` each of `testTheDefaultStillUsesTheWebViewInput` (`.bridge`) and `testASocketMentionReachesTheShellOnce` (`.socket`), then read the app's persisted `mm.mentions.state.*` | `.bridge`: **no `mm.mentions.state.*` key at all** while the server holds the mention the run posted (`9duyey8ugigwbghhbzwi7citch`) → still pollable; `.socket`: `notifiedPostIDs = ["igwxzyrguidotcktpj4417whbe"]`, `watermarkTs 1793087393076` — the delivered post, recorded once. Transcript: `docs/t43r-f1-ledger-evidence.txt`; runs `build/logs/t43r-f1-{neg,pos}.log` |

The first screenshot is the card's claim in one frame: an iOS banner **“Local Mattermost: T43 notify —
@t43buddy: … @perfprobe you were named”** sitting above the read-out **“From the socket: 1 delivered ·
0 suppressed”**, **“From the web view: 0 accepted · 0 refused”**, **“Last mention delivered … delivered”**.
The second is the dual-render run: **“Web view panes mounted: 0”** is what the native run shows and the
dual-render shot shows the web app mounted with **1 live socket, 0 delivered, 0 refused** and the footer
explaining that the page is the input.

What the four live tests actually assert (they skip, never fail, without a server):

1. `testASocketMentionReachesTheShellOnce` — launch with `-notificationPath socket`; the read-out says the
   input is **Native socket** and **1** server has a live socket (so the banner cannot be a poller — and,
   since T43-R, "live" means the server's `hello` arrived, see §3b); the buddy posts a mention of me while
   the app is in the foreground on another channel; the read-out's last mention is **that post id**, in
   **that channel id**, `outcome=delivered`, and the socket counter is **exactly 1 delivered / 0 suppressed**.
2. `testTheDefaultStillUsesTheWebViewInput` — launch with no flag; the read-out says **Web view bridge**;
   a fresh mention produces nothing on the socket path for 12 s and the counter stays 0 (the native input is
   inert until the flip, and it no longer writes the shared ring either — §3b F1).
3. `testDualRenderKeepsOneSourceAndNeverRefusesThePage` — the pane host stays on the web app
   (`app.webViews` non-empty) **and** the rail's socket is live (`liveSockets` 1, `webPanes` 1); the read-out
   says **`pageBridge` = "not installed"**, so the page cannot report; a fresh mention delivers nothing
   through the socket, records no delivery, is not recorded as a suppression either, and the page is never
   refused (`refused` 0, `accepted` 0 — structurally, see §3a).
4. `testThePageBridgeIsInstalledOnlyWhenAsked` — the same mount with `-desktopBridge`: the read-out flips to
   **`pageBridge` = "installed"** with `webPanes` still 1, proving the row in (3) measures the shim rather
   than a constant.

Unit tests worth naming, because they are the card's bullet points:

* `testTheSamePostTwiceIsOneBanner`, `testAPollCannotRedeliverWhatThisPathAlreadyDelivered` — one banner,
  one high-water mark.
* `testInBridgeModeTheSocketDeliversNothingAndLeavesThePostPollable` — T43-R F1's negative: the socket that
  was gated out writes nothing, so `MentionPoller.isNew` still sees the post. (The test it replaced,
  `testTheSocketInputIsSilentInBridgeMode`, asserted the opposite — the bug itself.)
* `testAFailedLookupLeavesThePostPollable`, `testAConfiguredDropIsRecordedAsHandled` — the two directions of
  the drop rule: a transient failure must not swallow a mention, the reader's own "notifications off" must.
* `T43RSocketLivenessTests` (four tests) — liveness is the server's `hello`, not the stream's creation; one
  report per pump; withdrawn when the pump ends.
* `testTheWebViewPathIsRefusedWhileTheSocketIsLive` — drives the real `WebViewContainer.Coordinator`, proving
  the call site consults the gate (not just that the gate has an opinion), and that the bridge works again
  when the socket goes away.
* `testTheUserInfoContractIsUnchanged` — `server_id/channel_id/team_id/url/type` and **no other key**: the
  Notification Service Extension and the tap router decode exactly that set.
* `testAForegroundMentionInAnotherChannelStillNotifies`,
  `testAMentionInTheChannelOnScreenIsSuppressed`,
  `testAWebviewPaneKeepsTheWholeServerRule` — the new suppression rule and its conservative fallback.
* `testTheBadgeFollowsTheServersOwnCounters`, `testTheBadgeIsNotIncrementedLocally` — one arithmetic.
* `testADroppedMentionIsRecordedWithItsReason`, `testAnUnresolvableChannelIsNotANotification` — a drop is
  visible, not silent.
* `testDefaultModeIsTheCompileDefault`, `testLaunchArgumentSelectsTheSocketInput`,
  `testReleaseSemanticsIgnoreLaunchAndStoredRows` — the switch resolves the way the repo's surfaces do.

## 6. Limits that stay (stated, not hidden)

* **The flip is not taken.** The shipped default is the webview bridge. `-notificationPath socket` is the
  proof path until T43's `-AV` approves the compile default; flipping it is a one-line change in
  `NotificationPathStore.compileDefault` plus the Settings footer copy.
* **No APNs, no push proxy.** The native input is a socket while the app runs and T14's `BGAppRefreshTask`
  poll while it is backgrounded. A mention that arrives while the app is *suspended* is still delivered by
  the **next** background refresh, not by a push — Option A remains the plan of record on this host.
* **No in-app toast.** Upstream's `in_app_notification` (a banner inside the app for a mention in another
  channel) is not ported; a mention in another channel while the app is foreground produces a *system*
  notification, which is what the screenshot shows.
* **`desktop_threads` / “follow thread” is not implemented.** A reply that names me is delivered (it is a
  `posted` event and it carries my key); the per-account thread preference that would notify me of replies
  that *don't* name me is not modelled.
* **No per-channel notification editing.** The policy *reads* `notify_props.desktop` and
  `ignore_channel_mentions`; the screens to change them are another card (T40's channel settings does not
  offer them).
* **A muted DM** is treated as muted (membership `mark_unread: mention` → policy drop). Only the
  muted-*channel* mention was measured on 9.11.19; the DM case follows the same membership field, but it is
  not separately measured on this server.
* **Text matching is the shipping path** (`props.mentions` is absent, §2), so a post that spells my
  username in a code block notifies — that is the server's own behaviour too, not a local invention.
* **A page-delivered banner cannot be written into the ring.** The desktop `notifyMention` frame carries
  `{title, body, channelId, teamId, url, silent, soundName}` and **no post id**, so the page path has nothing
  to key `notifiedPostIDs` with. Consequence, stated: a mention the page already showed can be notified
  again by the next T14 background poll. That direction is the pre-existing T8/T14 duplicate and is not
  introduced by T43; the direction this repair removed is the harmful one (the socket marking handled what
  it never delivered, which made a mention undeliverable *everywhere*).
* **The read-out is diagnostic only**: counters are per-run (they reset on launch) and the last-mention ring
  keeps 20 entries. `notificationPath.pageBridge` reports this process's shim install, which is a launch
  argument — not a per-server fact.

## 7. Files

Added: `Mattermost/UI/Native/Notification/{NotificationInputRouting,NotificationPathStore,MentionNotificationPolicy,MentionLedger,NativeNotificationFeed,NotificationInputSection}.swift`,
`MattermostTests/{T43NotificationInputTests,T43NativeNotificationFeedTests}.swift`,
`MattermostUITests/T43NotificationUITests.swift`,
`scripts/{t43_notification_seed,t43_notification_probe}.py`,
`docs/t43-notification-probe-2026-10-27.log`, `docs/t43-shots/t43-native-mention.png`, this note.

Added by **T43-R**: `MattermostTests/T43RSocketLivenessTests.swift` (F3), `NOTICE` (F5 — the repo had no
root notice; `docs/THIRD_PARTY_NOTICES.md` §20 is the T43 entry behind the per-file headers).

Modified: `Mattermost/Core/{NotificationWorker,MentionPoller}.swift`,
`Mattermost/MattermostApp.swift`, `Mattermost/UI/{RootView,SettingsView,WebViewContainer}.swift`,
`Mattermost/UI/Native/Sidebar/TeamSidebarCoordinator.swift`,
`Mattermost/UI/Native/Activity/ActivityModels.swift`, `docs/parity.md`.

Modified by **T43-R**: `Mattermost/UI/Native/Notification/{NativeNotificationFeed,MentionNotificationPolicy,NotificationInputSection}.swift`
(F1 ledger ordering + drop rule; F2's `notificationPath.pageBridge` row),
`Mattermost/UI/Native/Sidebar/TeamSidebarCoordinator.swift` (F3 liveness),
`Mattermost/Core/WebViewStore.swift` (F2: one `desktopBridgeEnabled` constant read by the install and the
read-out), `Mattermost/Core/MentionPoller.swift` (F4 comment), `MattermostTests/T43NativeNotificationFeedTests.swift`,
`MattermostUITests/T43NotificationUITests.swift` (F2 assertions + the shim test), `docs/{parity,THIRD_PARTY_NOTICES}.md`.

Identifiers the UI test drives: `notificationPath.mode`, `notificationPath.webPanes`,
`notificationPath.liveSockets`, `notificationPath.socket` (`delivered=… suppressed=… mentions=… posts=…`),
`notificationPath.bridge` (`accepted=… refused=…`), `notificationPath.pageBridge`
(`installed` / `not installed`, T43-R F2), `notificationPath.lastMention`
(`post=… channel=… outcome=…`), inside `settingsView` (opened from `settingsToolbarButton`).
