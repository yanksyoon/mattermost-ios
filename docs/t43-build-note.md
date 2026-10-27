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
| `NotificationInputSection.swift` | The Settings read-out (a section, not a screen): which input is live, servers with a live socket, `delivered · suppressed` from the socket, `accepted · refused` from the webview, and the last mention's post/channel/outcome. | — (diagnostic surface for the `-AV` gate). |

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

## 4. Decisions

1. **One source, chosen at the process boundary.** `NotificationInputRouting` is the single place both
   inputs ask "am I the input?"; the webview is refused only while *that server's* socket is live, so a
   server whose socket is down still gets its banners from the page.
2. **The flip is not taken here.** The shipped default stays `.bridge`, exactly as the card requires
   (`-AV` is the architect's adversarial validation, not this card's). `-notificationPath socket` proves
   the native input today, and the Settings section is the read-out that validation will judge.
3. **One ledger, read before write.** The feed reads `alreadyHandled` *before* it records the post. The
   first implementation recorded first and then checked, which made every first mention look like a
   replay — caught by `T43NativeNotificationFeedTests` (19 of 20 failing) before it could ship.
4. **The socket still feeds the ledger in bridge mode.** It delivers nothing, but it is a truthful "this
   post exists" signal, so the poller's watermark cannot fall behind a live socket and re-deliver history
   on the next background refresh.
5. **Foreground suppression compares the channel**, which is what the web app does for a focused channel,
   and what makes "a mention in another channel of the visible server is still one banner" true.
6. **The badge stays one arithmetic.** The feed never increments a number: it reads the server's
   per-team counters and hands them to `SessionStore` (`serverBadgeInput`/`applyServerCounters`), the same
   path T42 and T14 use. A failed counters read changes nothing rather than inventing a `+1`.

## 5. Evidence

| What | Command | Result |
| --- | --- | --- |
| T43 unit tests (rules) | `xcodebuild test … -only-testing:MattermostTests/T43NotificationInputTests` | **35 / 35**, `build/logs/t43-units1.log` |
| T43 unit tests (the path, with the real worker + session store, only the server faked) | `… -only-testing:MattermostTests/T43NativeNotificationFeedTests` | **20 / 20**, `build/logs/t43-units4.log` |
| Whole Catalyst suite (no regression in T8/T14/T42 or the bridge) | `xcodebuild test … -only-testing:MattermostTests` (Mac Catalyst) | **1480 run / 4 skipped / 0 failed**, `build/logs/t43-catalyst-full2.log` |
| Live UI, native input + default | `TEST_RUNNER_MM_AUTH_* python3 scripts/qa-test.py --platform ios --sim id=146D23D9… --only-testing MattermostUITests/T43NotificationUITests` | **2 run / 0 skipped / 0 failed**, `build/logs/t43-live4.log` |
| Live UI, T43 + T42 together (the shared mentions models did not regress) | same runner, both suites | **6 run / 0 skipped / 0 failed**, `build/logs/t43-live5.log` |
| Screenshot | exported from `t43-live5`'s attachments | `docs/t43-shots/t43-native-mention.png` |

The screenshot is the card's claim in one frame: an iOS banner **“Local Mattermost: T43 notify — @t43buddy:
… @perfprobe you were named”** sitting above the read-out **“From the socket: 1 delivered · 0 suppressed”**,
**“From the web view: 0 accepted · 0 refused”**, **“Last mention delivered … delivered”**.

What the two live tests actually assert (they skip, never fail, without a server):

1. `testASocketMentionReachesTheShellOnce` — launch with `-notificationPath socket`; the read-out says the
   input is **Native socket** and **1** server has a live socket (so the banner cannot be a poller); the
   buddy posts a mention of me while the app is in the foreground on another channel; the read-out's last
   mention is **that post id**, in **that channel id**, `outcome=delivered`, and the socket counter is
   **exactly 1 delivered / 0 suppressed**.
2. `testTheDefaultStillUsesTheWebViewInput` — launch with no flag; the read-out says **Web view bridge**;
   a fresh mention produces nothing on the socket path for 12 s and the counter stays 0 (the native input is
   inert until the flip).

Unit tests worth naming, because they are the card's bullet points:

* `testTheSamePostTwiceIsOneBanner`, `testAPollCannotRedeliverWhatThisPathAlreadyDelivered` — one banner,
  one high-water mark.
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
* **The read-out is diagnostic only**: counters are per-run (they reset on launch) and the last-mention ring
  keeps 20 entries.

## 7. Files

Added: `Mattermost/UI/Native/Notification/{NotificationInputRouting,NotificationPathStore,MentionNotificationPolicy,MentionLedger,NativeNotificationFeed,NotificationInputSection}.swift`,
`MattermostTests/{T43NotificationInputTests,T43NativeNotificationFeedTests}.swift`,
`MattermostUITests/T43NotificationUITests.swift`,
`scripts/{t43_notification_seed,t43_notification_probe}.py`,
`docs/t43-notification-probe-2026-10-27.log`, `docs/t43-shots/t43-native-mention.png`, this note.

Modified: `Mattermost/Core/{NotificationWorker,MentionPoller}.swift`,
`Mattermost/MattermostApp.swift`, `Mattermost/UI/{RootView,SettingsView,WebViewContainer}.swift`,
`Mattermost/UI/Native/Sidebar/TeamSidebarCoordinator.swift`,
`Mattermost/UI/Native/Activity/ActivityModels.swift`, `docs/parity.md`.

Identifiers the UI test drives: `notificationPath.mode`, `notificationPath.liveSockets`,
`notificationPath.socket` (`delivered=… suppressed=… mentions=… posts=…`),
`notificationPath.bridge` (`accepted=… refused=…`), `notificationPath.lastMention`
(`post=… channel=… outcome=…`), inside `settingsView` (opened from `settingsToolbarButton`).
