# t_ecfda04e — notifications were never authorised

Reported: "How can I have Mattermost notifications? Having no notifications is quite difficult to
work with at the moment." No banners, no badges, no sound.

## What was measured, and why it happened

```
plutil -p ~/Library/Preferences/com.apple.ncprefs.plist | grep com.mattermost.ios   -> no entry
defaults read com.mattermost.ios | grep -i notif                                    -> nothing
```

`UNUserNotificationCenter` had never been authorised for this install: the system prompt was never
shown. The only caller of `requestAuthorization` was
`NotificationWorker.prepareAuthorization()`, reached from `presentMention` — i.e. only when a mention
actually arrived on the delivery path. An install with a quiet team, a muted server, or a
foreground-only session sat at `.notDetermined` for ever, and Settings neither offered a way to ask
nor said what the state was.

The delivery plumbing was already there and is untouched: `NotificationWorker` builds the
`UNMutableNotificationContent`, sets `content.sound = .default` for non-silent mentions
(`mentionSound(silent:soundName:)`, desktop `Mention.ts` rule), and `SessionStore.setBadgeCount`
drives the app-icon badge. Nothing could fire because nothing was allowed to.

## What this change adds

| # | Requirement | Where |
| - | ----------- | ----- |
| 1 | Always-available `Enable notifications` that calls `prepareAuthorization()` on demand | `Mattermost/UI/Native/Notification/NotificationAuthorizationSection.swift`, `SettingsView.notificationsSection` |
| 1 | Status in plain words + `Send a test notification` through the mention path | same; `NotificationWorker.sendTestNotification()` |
| 2 | Read `authorizationStatus` once at launch and surface it | `NotificationWorker.init` → `reloadAuthorizationStatus()` (already there, now logged); row also re-reads on entry |
| 3 | `.notDetermined` must say the app has not been allowed yet | `NotificationWorker.authorizationCopy(for:)` |
| 4 | One diagnostics line | `NotificationWorker.diagnosticsLine` + `DiagnosticsContext.notificationDiagnostics` (step-6 payload) |

Files:

```
Mattermost/Core/NotificationWorker.swift                                  (+ diagnostics, test banner, shared identifier)
Mattermost/Core/Diagnostics.swift                                         (NotificationDiagnosticsSnapshot + step-6 keys)
Mattermost/UI/SettingsView.swift                                          (Notifications section: status row, buttons)
Mattermost/UI/Native/Notification/NotificationAuthorizationSection.swift  (new)
MattermostTests/NotificationWorkerTests.swift                             (+8 tests)
MattermostTests/DiagnosticsTests.swift                                    (step-6 line assertion)
```

### The row's copy

| `UNAuthorizationStatus` | Short | Full sentence |
| --- | --- | --- |
| `.authorized` | Allowed | Allowed - notifications can appear |
| `.provisional` | Allowed | Allowed quietly - notifications may not interrupt |
| `.ephemeral` | Allowed | Allowed for this session |
| `.denied` | Not allowed | Not allowed - open System Settings |
| `.notDetermined` | Not allowed yet | Not allowed yet - the app has not been allowed to notify you |
| `@unknown` | Unknown | Unknown - the system did not report a permission |

The `denied` case also draws an `Open System Settings` row (`UIApplication.openSettingsURLString`).
`Enable notifications` stays visible in every state: on `.notDetermined` it raises the system prompt;
on `.denied` it can only re-read (iOS shows the prompt once), which the copy explains.

### The test banner

`sendTestNotification()` runs the same gate as a mention (`.authorized`/`.provisional`/`.ephemeral`
proceed, `.denied` and `.notDetermined` return a recorded `notSent`), then builds a
`UNNotificationRequest` with the **same identifier shape as a mention** —
`NotificationWorker.notificationIdentifier(serverID:channelID:)` →
`mention.<server uuid>.<channel id>.<request uuid>` — and `content.sound = .default`. Its
`userInfo.type` is `test`, not `mention`, so a tap on the test banner does not navigate
(`route(userInfo:)` only accepts `mention`): the test names no real channel.

### Diagnostics

One line, logged at launch, on every status read, and on every scheduling attempt:

```
notifications=status=<authorized|provisional|ephemeral|denied|notDetermined|unknown> requested=<bool> lastSchedule=<scheduled|denied|notDetermined|addFailed|suppressed|missingServer|none>
```

Real output from this change's Catalyst test run (test host, mock center):

```
[NotificationWorker] notifications=status=denied requested=false lastSchedule=denied event=schedule
[NotificationWorker] notifications=status=authorized requested=false lastSchedule=scheduled event=status-read
```

The shareable diagnostics report carries the same line in step 6
(`notificationsDiagnostics`), plus `notificationsRequested` and `notificationsLastSchedule`, so the
next "I get no notifications" report answers the question without reading `ncprefs.plist`.

## Operator parity acceptance list

1. **Levels (`notify_props.desktop` default|all|mention|none)** — `MentionNotificationPolicy` owns
   this and the enable/test paths are downstream of it and bypass nothing. `none` and the mention
   level are implemented and tested (`MentionDropReason.notificationsDisabled`). **Recorded gap, not
   fixed here:** for a non-DM channel the policy delivers only when the reader is mentioned; the
   `desktop == "all"` branch ("every post in an unmuted channel notifies") is not implemented
   (`MentionNotificationPolicy.decision`, step 4). That is a policy gap of the socket/poller input,
   not an authorisation gap, and fixing it would widen this card — it is deliberately left alone and
   named here.
2. **Per-channel prefs win** — implemented: channel `notify_props.desktop == "none"` →
   `.channelNotificationsOff`, `ignore_channel_mentions == "on"` → `.mentionsIgnored`,
   `mark_unread == "mention"` mutes messages but not mentions (the comment at step 3 records the
   measured server behaviour).
3. **Sound** — implemented: `desktop_sound == "false"` → silent banner; `soundName == "None"` →
   silent; otherwise `.default`. Named desktop sounds (Bing/Ding/…) map to the system default on
   purpose (documented in the class header, line 21) — kept, as the operator asked, and stated here
   rather than silently shipping a different sound set.
4. **Badge** — `SessionStore` is the only counter (`badgeNumber(mentions:hasUnread:anyExpired:)`
   over the per-server `mentionCount` fed by the `unreads-and-mentions` bridge), and
   `SessionStore:179` applies it with `setBadgeCount`. This change does not touch the badge math, and
   the test banner deliberately does not move it (a test is not an unread).
5. **Focus** — unchanged T8 rule: foreground + visible channel suppresses; a mention elsewhere in the
   open window banners. Pinned by `testForegroundVisibleServerIsSuppressed`,
   `testBackgroundedPrimaryServerSchedules` and T43's channel-level tests.
6. **Click** — unchanged: `userInfo` carries `server_id`/`channel_id`/`team_id`/`url`, and
   `testTapRoutesToServerAndChannelWhenSPAReady` / `testTapQueuesPathUntilSPAReady` assert the route
   rather than assuming it. The test banner intentionally does not route.
7. **Quiet hours / DND** — the OS owns suppression and the app does not fight it. Neither
   `presentMention` nor the row claims delivery: the outcomes are `scheduled`, and the test-button
   copy says "If it does not appear, the system or a Focus mode is holding it."

## Tests

```
xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath <scratch>/dd \
  -only-testing:MattermostTests/NotificationWorkerTests -only-testing:MattermostTests/DiagnosticsTests
-> Executed 50 tests, with 0 failures (25 NotificationWorkerTests + 25 DiagnosticsTests)
```

New tests (all functional, against a recording `NotificationScheduling` stub):

- `testPrepareAuthorizationRequestsExactlyOnceAcrossRepeatedCalls` — one request across three calls,
  `hasRequestedAuthorization` true, the preference persisted as `true`.
- `testDeniedStatusIsSurfacedAsTheDeniedCopy` — `.denied` reads "Not allowed - open System Settings".
- `testNotDeterminedCopySaysTheAppHasNotBeenAllowedYet` — the card's original failure state, said out
  loud, and distinct from `denied`.
- `testAuthorizationStatusIsReadOnLaunch` — the launch read surfaces the OS answer.
- `testTestNotificationSchedulesOneRequestWithTheMentionIdentifierShape` — exactly one request, four
  dot-separated identifier parts (`mention`/server uuid/`test-notification`/request uuid), same title
  composition and sound as a mention, `userInfo.type == "test"`.
- `testTestNotificationDoesNotScheduleWhenDenied` — nothing scheduled, `lastSchedule=denied`.
- `testMentionWhileNotDeterminedAsksThenSchedulesOnceAuthorized` — the T8 first-mention behaviour
  still asks, and once authorised the next mention schedules exactly one banner.
- `testDiagnosticsLineShape` — the exact line, and that the snapshot carries the same string.

Whole Catalyst unit suite on the same tree: **2141 passed, 11 skipped, 1 failed** —
`T53MediaFootprintTests.testAStagedPayloadIsWrittenToDiskRatherThanHeldInMemory` ("staging 33554432
bytes grew the footprint by 301351488 bytes"). It fails when re-run alone as well. It is a
process-footprint measurement that does not touch notification code, and this change does not stage
media payloads; a pristine-baseline run could not be completed because the host lost access to the
working copy mid-run (see "Host notes"). It is recorded here rather than presented as green.

Release build:

```
xcodebuild -project Mattermost.xcodeproj -scheme Mattermost -configuration Release \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath <scratch>/dd-release build
-> ** BUILD SUCCEEDED **
```

## Host notes (why the commit was produced from a clone)

Seven `mmios-ios`/`mmios-qa` cards were dispatched at 04:02 into the **same** `dir` workspace
(`/Users/yangsooyoon/Documents/yanks/code/mattermost-ios`). While this card ran, HEAD moved under it
(`7eab509` → `eab5a8a`, another card's publish) and the working tree filled with other cards'
uncommitted edits (14 files at one point). Building or committing in place would have compiled and
shipped someone else's half-finished work. This change was therefore verified and committed from an
isolated worktree of `HEAD` and then a fresh clone of `origin/main`, carrying only this card's six
files.

At 04:14 the host stopped permitting access to `~/Documents` from this session (`EPERM` on readdir
for the repo and its parents, while `stat` still worked), so the shared working copy could no longer
be committed to. The clone path was used for the push. If the board wants the shared directory to
remain the single source of truth, that workspace collision needs fixing before more cards land.

**hotspot:** `/Users/yangsooyoon/Documents/yanks/code/mattermost-ios` — seven concurrent workers in
one `dir` workspace; HEAD and the index are shared.

## Live proof — NOT captured, and why

The operator's definition of done asks for a screenshot/recording of a banner with sound and a
non-zero dock badge on a Release Catalyst build. **The host's screen is locked** (screenshot
evidence: the login window, "Touch ID or Enter Password", `wake-check.png`), so no one can tap
Settings → Enable notifications or accept the system permission dialog, and no banner can be shown
on screen. `screencapture` before waking the display returned an all-black image; after waking it,
the login window. The Release build itself succeeds and is registered with LaunchServices at

```
<scratch>/dd-release/Build/Products/Release-maccatalyst/Mattermost.app
```

What to do after unlocking (three taps, no rebuild needed):

1. `open <scratch>/dd-release/Build/Products/Release-maccatalyst/Mattermost.app`
2. Settings (gear) → Notifications → **Enable notifications** → **Allow** in the system dialog.
   That dialog writes the `com.mattermost.ios` entry `ncprefs` has never had.
3. **Send a test notification** → a banner with sound appears; the row's diagnostics line reads
   `notifications=status=authorized requested=true lastSchedule=scheduled`.

The dock badge comes from a real unread (`SessionStore`), not from the test banner, so it needs a
mention/unread on the signed-in server.
