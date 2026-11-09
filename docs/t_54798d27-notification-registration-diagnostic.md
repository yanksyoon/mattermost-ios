# t_54798d27 — the notification diagnostic contradicted itself; what it actually measured

## The report

An install (0.71.1, build 372, from main `8c04b4a`) logged, on macOS 26.3.1:

```
notifications=status=authorized registration=notRegistered alerts=banner requested=true
    lastSchedule=none event=launch-ask-skipped
```

…while the same process wrote the badge (`Setting badge count to 49`, `hasError: 0`), and
`~/Library/Preferences/com.apple.ncprefs.plist` did not hold this bundle (only
`Mattermost.Desktop`). The line asked a reader to choose between "authorized" and "not
registered", and there was no way to tell which token was lying.

## What was measured (2026-11-09, macOS 26.3.1)

### 1. The app still says `notRegistered`, and it is not the table's fault

The installed build (`/Applications/Mattermost(ios).app`, 372) was relaunched with the unified log
streaming. It reproduced the report exactly:

```
2026-11-09 18:02:04.547 I  Mattermost[23997] [com.mattermost.ios:NotificationWorker]
    notifications=status=authorized registration=notRegistered alerts=banner requested=true
    lastSchedule=none event=status-read
2026-11-09 18:02:05.842 I  Mattermost[23997] [com.mattermost.ios:NotificationWorker]
    … event=launch-ask-skipped
```

### 2. Why the reader answers that

An instrumented Catalyst probe (`-target arm64-apple-ios15.0-macabi`, same
`FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)` call as
`SystemNotificationRegistrationReader.defaultTables`) was run in two shapes.

Direct from the terminal (how the gate script runs):

```
OK bytes=62134 exists=true path=~/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist
    apps=137 bundleHit=true
OK bytes=35820 exists=true path=~/Library/Preferences/com.apple.ncprefs.plist
    apps=114 bundleHit=false
```

Launched as an app bundle by LaunchServices (`open Probe.app`) — the shipping shape of this app:

```
FAIL NSCocoaErrorDomain/257 exists=true access=-1/1 path=…/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist
FAIL NSCocoaErrorDomain/257 exists=true access=-1/1 path=…/group.com.apple.usernoted/db2/db
OK   bytes=35820 path=~/Library/Preferences/com.apple.ncprefs.plist
     apps=114 bundleHit=false
```

So inside the app the live table **exists but is unreadable**: `EPERM` on the whole
`group.com.apple.usernoted` container, sandbox entitlements or not. The reader's old verdict
counted a table it could not read as one that had been read and lacked the row, and reported
`.notRegistered`. The fact it had actually established was narrower: *the only readable table has no
row for this bundle*.

### 3. The OS does hold the registration — in the daemon's database

`group.com.apple.usernoted/db2/db` (SQLite) is the delivery daemon's own store:

```
sqlite> select app_id, identifier, badge from app where identifier like '%mattermost%';
84|mattermost.desktop|
147|com.mattermost.ios|40

sqlite> select count(*) from record where app_id=147 and presented=1;
12
```

The 12 records are this app's delivered notifications; the most recent is `2026-11-09 11:36`, a real
mention (`title = "Canonical: Someone mentioned you"`,
`identifier = mention.3E4B80BD-….qiaeuu….538A61D0-….`). The daemon row also carries a non-zero badge
(`40`).

`record.presented` is **not** a reliable "a banner was drawn" flag: three test banners logged by
`usernoted` as `Presenting … as banner` in this session all recorded `presented = 0`, and so did a
`ScriptEditor2` notification presented in the same window. The authoritative presentation evidence
is the daemon's own log line, used in §4 below.

The legacy `ncprefs.plist` is **not** a mirror of that table: of 118 user-domain apps in the daemon
`app` table, 107 have a settings row and **11 do not** — and none of the 107 is missing from the
daemon. A settings row is a subset; its absence cannot be promoted to "unregistered".

### 4. A test notification presents — with the app frontmost and in the background

The build was installed and launched through LaunchServices (`open -n … --args
-testNotificationProbe <seconds>`, the same app shape as the shipping install). The probe calls
`NotificationWorker.sendTestNotification()` — the Settings button's product path — after the delay.

Frontmost at delivery (probe 10 s):

```
18:16:57.945 [NotificationWorker] scheduled test notification ->
    mention.3E4B80BD-….test-notification.9C519E81-…
18:16:58     usernoted: Presenting <… app:"com.mattermost.ios"
    req:"mention…test-notification.9C519E81-…"> as banner (["badge", "sound", "alert"])
```

Another app frontmost at delivery (probe 25 s; Finder activated before the delay expired, Brave
frontmost at the moment of delivery):

```
18:18:37.513 usernoted: Presenting <… app:"com.mattermost.ios"
    req:"mention…test-notification.512F5B6E-…"> as banner (["badge", "sound", "alert"])
```

So the request path is live in the app bundle for which the reader says `.settingsRowAbsent`. That is
the fact that decides the branch: the probe's question was wrong, not the OS's answer.

The same run's diagnostic line (launch, PID 28500, launched by LaunchServices) was:

```
notifications=status=authorized registration=settingsRowAbsent
    tables=usernoted:unreadable,ncprefs:absent alerts=banner requested=true
    lastSchedule=none event=status-read
notifications=status=authorized registration=settingsRowAbsent
    tables=usernoted:unreadable,ncprefs:absent alerts=banner requested=true
    lastSchedule=none event=launch-ask-skipped reason=status-authorized
```

Both facts are true at once, and the skip carries its reason. The old line said
`registration=notRegistered` with no reason.

### 5. The Settings copy and the log

Before this card, an authorized install whose readable table lacked the row rendered as:

```
statusLabel:  "Not registered"
copy:         "Not registered with macOS - nothing can appear"
hint:         "Open System Settings > Notifications, find Mattermost in the list, and allow it."
```

Every sentence in that block asserted a state the probe cannot know, on an install whose
notifications were presented by the daemon 12 times. `launch-ask-skipped` likewise carried no
reason, so "we did not ask" and "there was nothing to ask" were indistinguishable.

## What changed

| # | Requirement | Where |
| - | ----------- | ----- |
| 1 | No token claims two things; an unreadable table is not an absent row | `NotificationRegistration.settingsRowAbsent` (`registered` / `settingsRowAbsent` / `unknown`); `SystemNotificationRegistrationReader` classifies each table `row` / `absent` / `missing` / `unreadable` |
| 2 | The diagnostics name the per-table outcome | `registration=<token> tables=usernoted:unreadable,ncprefs:absent` in `NotificationWorker.diagnosticsLine`; `notificationsRegistrationTables` in the shareable report |
| 3 | Settings tells the measured truth and offers no detour | `authorizationCopy` / `statusLabel`; `needsSystemSettings` no longer fires on the absent state; the "Open System Settings … allow it" hint is gone |
| 4 | The launch skip says why | `event=launch-ask-skipped reason=status-authorized` (also `no-session`, `status-denied`, `asked-this-process`) |
| 5 | The gate does not read unreadable as absent | `scripts/verify-notification-registration.sh`: an existing-but-unreadable live table with an absent legacy one exits 2 ("not evidence the app is unregistered"), with a self-test case |

Settings copy for this state:

```
Allowed - macOS has no notification settings row this app can read; badges and banners still work
```

That is exactly what was measured: the OS allows it, the app cannot read the row, the daemon
presents banners and holds the badge.

## Tests (T1–T4)

| Test | Pins |
| ---- | ---- |
| `testDiagnosticsCarriesTheAbsentStateBesideAuthorizedStatus` (T1) | `status=authorized registration=settingsRowAbsent` are two facts; copy/label match |
| `testLaunchAsksWhenNotDeterminedAndASessionExists` (T2) | absent table + `.notDetermined` still asks |
| `testLaunchDoesNotAskWhenAuthorizedWithNoReadableRow` (T3) | absent table + `.authorized` asks nothing |
| `testAllowedCopyWithNoReadableRowNeverClaimsNothingCanAppear` (T4) | copy never says "Not registered"/"nothing can appear"; no System Settings detour |
| `testSilentStyleWinsOverTheAbsentSettingsRow` | `alerts=none` keeps its actionable copy |
| `testLaunchSkipReasonNamesTheFactThatSuppressedTheAsk` | the log justification |
| `NotificationRegistrationTests` | per-table classification: `usernoted:unreadable,ncprefs:absent` is `.settingsRowAbsent`; an unreadable live table falls back; a missing/broken table is `.unknown` |
| `DiagnosticsTests.testPermissionsStepReflectsProviderSnapshot` | the report carries the token and the per-table detail |

## What this does not claim

- **No screenshot of a banner.** `screencapture` on this host fails ("could not create image from
  display"). Presentation is evidenced by the delivery daemon's own `Presenting … as banner` log
  line for both probe runs, not by a picture, and `record.presented` is not used for that claim.
- **The probe is a test seam, not product behaviour.** `-testNotificationProbe <seconds>` is inert
  without the argument and exists because the XCUITest bundle cannot run on this host's Catalyst
  destination; it calls the same `sendTestNotification()` the Settings button calls.
- **No APNs / no Mattermost Push Proxy.** Everything above is the local-banner path.
- The app still cannot read the live table; it now reports that it cannot, instead of reporting what
  it concluded from the table it could read. If Apple ever exposes the registration fact through
  `UNUserNotificationCenter`, the reader can drop the file probe and the `.settingsRowAbsent` state
  with it.
