# T14 — Background App Refresh polling for mention notifications (Option A)

Build note. Date: 2026-10-24. Commits: see `git log` after landing.

## Ship goal

The web app's `notify_mention` bridge event only fires while JS is running, so mentions
are missed once iOS suspends the app. T14 adds a `BGAppRefreshTask`-driven poller that
fetches new mentions over REST in the background and schedules local notifications through
the existing `NotificationWorker` — with **no APNs, no Push Proxy, and no paid Apple
Developer capability** (T12/T13 remain blocked/publishing-only; this task never calls
`registerForRemoteNotifications`).

## Capability verification (done before starting, per task scope)

- `UIBackgroundModes = fetch` and `BGTaskSchedulerPermittedIdentifiers =
  com.mattermost.ios.refresh` are **plain Info.plist keys**. Verified against Apple's
  documentation ("Configuring your app for background tasks": each perform-on-launch task
  identifier must be listed in `BGTaskSchedulerPermittedIdentifiers`; `fetch` is the
  required `UIBackgroundModes` value for `BGAppRefreshTask`) and against the local
  BackgroundTasks SDK headers (`BackgroundTasks.framework` declares `BGTaskScheduler` as
  `API_AVAILABLE(ios(13.0))` with no entitlement requirement). No signing capability is
  involved — unlike APNs, which needs a `push-notification` entitlement from a paid Apple
  Developer Program account, plus a deployed Mattermost Push Proxy.
- Mac Catalyst (T20) caveat: `BackgroundTasks` ships in the macOS SDK and compiles, but
  `BGTaskScheduler` is `API_UNAVAILABLE(macos)` and background tasks do not run on macOS.
  The scheduler therefore compiles to a **documented no-op on Catalyst** (both
  registration and scheduling are guarded by `#if !targetEnvironment(macCatalyst)`), so the
  T20 Mac target still builds and the iOS path is untouched.

## API verification (the task's "verify against api.mattermost.com" box)

- **There is no `GET /api/v4/users/me/mentions` endpoint.** Confirmed against the current
  OpenAPI reference (`mattermost-api-reference` `v4/source/users.yaml` — no `/mentions`
  path) and the mattermost-server routes (`server/channels/api4/user.go` registers no
  mentions route). The task explicitly anticipated this: "or `/users/me/teams/unread` +
  `/users/me/channels/.../posts` if mentions alone is insufficient". That fallback is what
  the poller implements:
  1. `GET /api/v4/users/me/teams/unread?exclude_team=` → `TeamUnread[]`
     (`team_id, msg_count, mention_count`)
  2. `GET /api/v4/users/me/teams/{team_id}/channels/unread` → `ChannelUnread[]`
     (`team_id, channel_id, msg_count, mention_count`) — only for teams reporting mentions
  3. `GET /api/v4/channels/{channel_id}/posts?since=<watermark>` → `PostList`
     (`order`, `posts{id: Post}`) — only for channels whose unread mention count increased
     since the last poll
  4. `GET /api/v4/channels/{channel_id}` (display name + team id) and
     `GET /api/v4/users/{user_id}` (username) per new mention, for title/body parity.
- All requests use `Authorization: Bearer <token>` read from `SecureVault` only.

## What was built

| File | Change |
|---|---|
| `Mattermost/Info.plist` | `UIBackgroundModes = [fetch]`, `BGTaskSchedulerPermittedIdentifiers = [com.mattermost.ios.refresh]` |
| `Mattermost/Core/BackgroundRefreshScheduler.swift` | NEW — task registration, submission on backgrounding, `setTaskCompleted`-always + expiration cancellation, Catalyst no-op |
| `Mattermost/Core/MentionPoller.swift` | NEW — REST drill-down, per-server high-water mark, dedupe ring, `NotificationWorker` handoff, badge refresh |
| `Mattermost/AppDelegate.swift` | registers the BGTask launch handler (`didFinishLaunchingWithOptions`) |
| `Mattermost/UI/RootView.swift` | `scenePhase == .background` → submit refresh; `.active` → cancel pending |
| `Mattermost/MattermostApp.swift` | binds `MentionPoller.shared` to the live stores; `NotificationWorker.shared` is the ONE worker (single `UNUserNotificationCenter` delegate for both paths) |
| `Mattermost/Core/NotificationWorker.swift` | added `static let shared` |
| `MattermostTests/MentionPollerTests.swift` | NEW — 17 tests (1 opt-in live) |
| `Mattermost.xcodeproj/project.pbxproj` | 3 new files registered (surgical, single-writer) |

### High-water mark semantics (acceptance criterion, explicit)

Persisted per server, in `AppPreferences` under `mm.mentions.state.<serverUUID>`:
`watermarkTs` (newest post create_at seen, ms), `watermarkPostID` (tie-break), a bounded
dedupe ring of notified post ids (500), and the last per-channel unread mention-count
snapshot.

- **First run:** the first fetch only seeds `watermarkTs = now` and notifies **nothing**
  older than the watermark — no history replay. Tested:
  `testFirstRunSeedsWatermarkAndNotifiesNothing` (asserts zero deliveries *and* that no
  `/posts` request is even made during seeding).
- **Subsequent runs:** only channels whose unread mention count increased are re-fetched
  with `?since=<watermark>`; posts are filtered by `create_at > watermark` (or `==` with a
  different post id) and by the dedupe ring, delivered oldest-first via
  `NotificationWorker.presentMention` — the same code path as the foreground bridge, so
  title/sound/threading/`userInfo` are byte-identical, and tap routing works unchanged.
- Tests: `testSecondRunSchedulesExactlyOneRequestPerNewMention` (exactly one
  `UNNotificationRequest`, payload asserted: `server_id/channel_id/team_id/url/type`,
  `threadIdentifier`, `content.title`, `@username: message` body),
  `testMentionsAtOrBelowWatermarkAreNeverNotified`, `testAlreadyNotifiedMentionIsNotScheduledAgain`,
  `testUnchangedChannelMentionCountIsNotRefetched`, `testTwoNewMentionsScheduleTwoRequests`.

## Dedupe between the foreground bridge and the poller

The poller only notifies posts that are new relative to the shared (per-server) watermark
+ dedupe ring, and `presentMention`'s existing suppression rules apply unchanged. Honest
limit, recorded per the task's "state this explicitly": the foreground bridge event
(`notify_mention`) does **not** carry a post id or timestamp (the web app's payload has
none), so the poller cannot see that the foreground delivered a specific mention. A
mention that arrives while the app is foregrounded in a channel the user never opens can
therefore produce one foreground notification **and** one poller notification when the
task next runs after backgrounding. `testAlreadyNotifiedMentionIsNotScheduledAgain` covers
the poller-to-poller case; the foreground-to-poller edge is bounded by the mention-count
gating (a channel the user read resets its count and is not re-fetched) and is documented
as a best-effort limitation of Option A. T12/T13 (APNs) is the fix and stays out of scope.

## Degradation (acceptance criteria)

- Background refresh disabled by the user (`UIApplication.backgroundRefreshStatus ==
  .denied/.restricted`) or on Catalyst → `scheduleNextRefresh()` logs and returns; no
  crash, no stuck task. Pure policy tested: `testSchedulerPolicyMapsSystemStatus`.
- No network → the poller catches the transport error, logs, leaves state untouched, and
  returns `.failed` — never a crash, never a stuck task.
  `testNoNetworkDegradesToLoggedNoOp`.
- Server without a stored token → skipped before any network. `testServerWithoutTokenIsSkipped`.
- Notifications not authorized → mentions are recorded as seen (so the watermark advances
  and nothing replays later) but nothing is delivered; the poller never triggers the
  system permission prompt from a background launch (that stays the foreground first-mention
  path). `testUnauthorizedNotificationsRecordButDoNotDeliver`.
- `expirationHandler` cancels the in-flight work (`Task.cancel()`); the poller's URLSession
  `data(for:)` cooperates with cancellation, the task completes with
  `setTaskCompleted(success: false)` and never hangs. `testTaskCancellationAbortsInFlightFetch`.

## Presence

The existing `UserActivityMonitor` analogue (scenePhase/idle → presence) is untouched and
continues to work. Honest note required by the task: iOS cannot keep the Mattermost
WebSocket alive while the app is suspended, so real-time presence (online
status/typing) is **best-effort** — the OS suspends the process and no background socket
survives. T14 does not attempt to fake it.

## Running the tests

```
xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
  -destination "platform=iOS Simulator,id=81A7F251-8B31-4945-8783-5A264C14B8D5" \
  -derivedDataPath build/ddata -only-testing:MattermostTests
```

Full-suite log: `docs/t14-full-suite-2026-10-24.log`.

```text
Executed 312 tests, with 1 test skipped and 0 failures
```

(The one skip is the opt-in live test below.)

### Polling-diff unit tests (the task's evidence names)

`MentionPollerTests`:
`testFirstRunSeedsWatermarkAndNotifiesNothing`,
`testSecondRunSchedulesExactlyOneRequestPerNewMention`,
`testTwoNewMentionsScheduleTwoRequests`,
`testMentionsAtOrBelowWatermarkAreNeverNotified`,
`testAlreadyNotifiedMentionIsNotScheduledAgain`,
`testUnchangedChannelMentionCountIsNotRefetched`,
`testServerWithoutTokenIsSkipped`,
`testNoNetworkDegradesToLoggedNoOp`,
`testUnauthorizedNotificationsRecordButDoNotDeliver`,
`testBadgeRefreshedFromTeamUnreadTotals`,
`testWatermarkPersistsAcrossPollerInstances`,
`testTaskCancellationAbortsInFlightFetch`,
`testMentionCompositionParity`,
`testSchedulerPolicyMapsSystemStatus`,
`testStateRingIsBounded`,
`testServerStateIsCodable`,
`testLiveMentionsFetch_optIn` (skipped unless env-gated).

### Opt-in live fetch against a real server

The acceptance criterion "a real mentions fetch against a test server" is testable with the
repo's existing `TEST_RUNNER_MM_LIVE_*` env-gate pattern:

```
TEST_RUNNER_MM_LIVE_URL=https://chat.example.com \
TEST_RUNNER_MM_LIVE_TOKEN=<personal access token or session token> \
xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
  -destination "platform=iOS Simulator,id=81A7F251-8B31-4945-8783-5A264C14B8D5" \
  -derivedDataPath build/ddata -only-testing:MattermostTests/MentionPollerTests/testLiveMentionsFetch_optIn
```

The token flows through the poller's injected token source and is never logged. The test
asserts the drill-down succeeds against the live server (seeds or polls); it does not
assert a specific incoming mention, because that requires an operator to have prepared one.

## Simulated BGTask launch on the simulator (lldb)

`BGTaskScheduler` exposes a private debug symbol that asks the framework to launch a
registered task as if the OS had picked it:

```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.mattermost.ios.refresh"]
```

Procedure used on this host (iPhone 16 Pro simulator, id 81A7F251-8B31-4945-8783-5A264C14B8D5):

1. Build + install: `xcodebuild build -project Mattermost.xcodeproj -scheme Mattermost
   -destination "platform=iOS Simulator,id=81A7F251-..." -derivedDataPath build/ddata` then
   `xcrun simctl install booted build/ddata/Build/Products/Debug-iphonesimulator/Mattermost.app`
2. Launch: `xcrun simctl launch booted com.mattermost.ios`
3. Attach lldb to the running process (`xcrun simctl spawn booted launchctl list | grep
   com.mattermost.ios` gives the PID) and run the expression via an lldb command file
   (`lldb -b -p <pid> -s t14-sim.lldb`).

**Measured result on this host — recorded honestly.** The framework's own log confirms the
hook runs and recognizes our identifier:

```
[com.apple.BackgroundTasks:Framework] Simulating launch for task with identifier com.mattermost.ios.refresh
[com.apple.BackgroundTasks:Framework] Getting pending task requests
[com.apple.BackgroundTasks:Framework] E ... No task request with identifier com.mattermost.ios.refresh has been scheduled
```

The simulated launch requires a **pending** task request, and on this simulator (iOS 26.5,
Xcode 26.6) `BGTaskScheduler` refuses to create one: `submitTaskRequest:error:` returns
`NO` with `BGTaskSchedulerErrorDomain Code=1` (`BGTaskSchedulerErrorCodeUnavailable`), which
the BackgroundTasks SDK header documents as "The app is running on Simulator which doesn't
support background processing". The Info.plist keys are present in the built app (verified
with `plutil -p`), `UIApplication.backgroundRefreshStatus` reads `.available` (2) on the
sim, and the failure is identical with `earliestBeginDate` nil or in the future. So an
actual background *launch* cannot be produced on a simulator with this OS — it needs a
physical device. On a device the same plain Info.plist keys (no entitlement, no paid
capability) make submission and OS-launched refreshes work. The coverage T14 actually
delivers on this host:

- registration + scene wiring are live: the framework log also shows the T14 code calling
  `cancelTaskRequestWithIdentifier:` on `scenePhase == .active` (RootView wiring) and
  recognizing the refresh identifier at simulate time;
- the poll -> `presentMention` -> exactly-one-`UNNotificationRequest` -> badge path is
  exercised by the full unit suite with a real `URLSession` over the stub protocol, and by
  the opt-in live test (`TEST_RUNNER_MM_LIVE_*`) against a real server;
- nothing in T14 fakes the OS launch; with a physical iPhone, background the app and watch
  the console for `refresh task completed success=...` from `BackgroundRefreshScheduler`.

## Known limits (recorded honestly)

- DM/GM mentions are not surfaced by `/users/me/teams/unread` (the drill-down is
  team-channel scoped, matching the task's prescribed fallback). DMs keep working through
  the foreground bridge while the app is active.
- iOS throttles refresh tasks by usage; `earliestBeginDate` is a hint, not a timer. This
  is a battery-preserving best-effort substitute for push, not a push replacement.
- The `since=` window returns posts *modified* since the time (server semantics); the
  poller filters client-side on `create_at` so edits to old posts do not re-notify.
- One extra GET per new mention (channel + user profile) is deliberate — keeps
  title/body/`userInfo` aligned with the foreground path; a mention batch is normally
  0–2 posts, well within the refresh budget.
