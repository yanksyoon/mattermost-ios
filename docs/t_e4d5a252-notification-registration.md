# t_e4d5a252 — notifications never register with macOS on a fresh install

Reported (owner): "Can you tell me why notification doesn't work?"

## The answer

**On this Mac the system does hold a notification row for `com.mattermost.ios`.** The card's evidence
was read from `~/Library/Preferences/com.apple.ncprefs.plist`, which macOS 26 stopped maintaining in
February 2026; every app installed since is missing from it, and all of them are present in the live
table the delivery daemon actually uses. The reader's own source, compiled and run outside an app
bundle (which is the only way it can see that table), answered:

```
bundle=com.mattermost.ios state=registered
```

**Correction (t_54798d27, 2026-11-09): the app itself cannot read that live table.** A
LaunchServices-launched app bundle gets `EPERM` on the whole `group.com.apple.usernoted` container,
so inside the app the only readable table is the stale legacy one and the worker reports
`registration=settingsRowAbsent tables=usernoted:unreadable,ncprefs:absent`. That is a limit of the
probe, not a delivery verdict: the daemon's `db2/db` holds this bundle's `app` row (badge included)
and t_54798d27's test banner was logged by `usernoted` as `Presenting … as banner`. See
`docs/t_54798d27-notification-registration-diagnostic.md` for the probe experiment and that evidence.

So registration was not the blocker here. What was missing is what that `requested=false` says: the
install had **never asked the system**, while `notificationSettings()` answered `.authorized` anyway
(macOS 26 reports an allow state for an app that was never prompted). Nothing in the app could tell
those two situations apart, and nothing could see the other state that looks identical to a user —
`alertStyle = none`, where every request is delivered into Notification Center and no banner is ever
drawn. Both are now read, named, and driven by the fix.

This is still **not** the earlier delivery bugs (`t_6a2b0fb4`/`t_ba355551` fixed those): the ledger
advances and requests reach `UNUserNotificationCenter`.

## What was measured (2026-11-05, macOS 26.3.1)

### Two tables, one of them stale

| Table | mtime | rows | contains `com.mattermost.ios` |
| ----- | ----- | ---- | ---------------------------- |
| `~/Library/Preferences/com.apple.ncprefs.plist` (legacy) | **2026-02-25 07:59** | 114 | **no** |
| `~/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist` (live) | **2026-11-05 22:24** | 137 | **yes** |

24 bundle ids exist only in the live table, and 1 only in the legacy one. Every app-level bundle in the
live-only set was installed **after** the legacy file's last write: Firefox (2026-09-17), ego lite
(09-08), Cap (05-13), CapCut (03-15) and this bundle (11-05). (The single exception is
`com.google.Chrome.framework.AlertNotificationService`, a helper Chrome registers on its own schedule,
not an app install.) Reading the legacy file alone therefore reports "not registered" for everything
installed this year — and would have failed every install on this host forever.

The live row for this bundle, read with `plistlib`:

```
mattermost.ios: auth=7 flags=312483854 path='/Applications/Mattermost(ios).app' src_entries=42
```

`src` holds one code-requirement entry per ad-hoc build this checkout has produced — that is the
re-signing cost this card documents, not a missing row. `auth=7` is the same value the working
per-app rows carry (Firefox, Element).

### Nothing had ever asked

```
defaults read com.mattermost.ios  ->  mm.notifications.permissionRequested is absent
```

A launch of the build made by this card logged:

```
2026-11-05 22:24:00 status-read    notifications=status=authorized registration=registered alerts=banner requested=false
2026-11-05 22:24:02 launch-ask     notifications=status=authorized registration=registered alerts=banner requested=false
```

`launch-ask` is the new reconciliation firing; `status-read` never follows it because the system
dialog owns the answer (see "What this does not claim"). **Correction (t_54798d27):** that run was the
binary launched directly from a Terminal, which can read the live table. The same build launched as
an app bundle by LaunchServices reports `registration=settingsRowAbsent
tables=usernoted:unreadable,ncprefs:absent` — the app cannot read the live table at all. Both lines
are recorded because the difference is the whole point of the follow-up card.

### The reader, executed against this host

The app's reader source, compiled unchanged and run on the real tables **outside an app bundle**
(the only shape that can see them; `state=` names below are the t_54798d27 tokens):

```
tables:
  [0] exists=true  .../Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist
  [1] exists=true  .../Library/Preferences/com.apple.ncprefs.plist
bundle=com.mattermost.ios                            state=registered
bundle=com.example.definitely.not.installed          state=settingsRowAbsent
```

Inside the app bundle the live table's `contents(atPath:)` returns nil (`EPERM`), so the same reader
answers `state=settingsRowAbsent tables=usernoted:unreadable,ncprefs:absent`.

## Why the card's premise did not survive verification

The failure the card describes — no row, every `add()` dropped — is real and is still detected: the
gate fails when **both readable tables** lack the bundle. It was not this install's state. Two
corrections follow from the measurements:

1. **The legacy file is a fallback, not the truth.** The reader reads the live table first and falls
   back to `com.apple.ncprefs.plist`; `.settingsRowAbsent` means every readable table lacks the
   bundle (it says nothing when a table could not be read), and `.unknown` (neither readable — e.g. a
   phone, which has no such table) is never rendered as a failure.
2. **"Allowed" was not the only misleading reading.** An authorized, registered install whose
   `alertStyle` is `none` draws nothing at all, and previously read as healthy. The worker now reads
   `UNNotificationSettings.alertStyle` beside the status, and both the Settings row and the
   diagnostics line name it (`alerts=none` → "No banners").

## What this change does

| # | Requirement | Where |
| - | ----------- | ----- |
| 1 | Authorization is **state-driven**: the persisted flag is history, never the gate | `NotificationWorker.shouldAsk(status:includingAuthorized:)` → `prepareAuthorization(registeringAuthorizedInstall:)`; `didAskThisProcess` is process-scoped |
| 2 | Ask at first launch of a new install when a session exists, and reconcile the macOS 26 case where the OS says `.authorized` without ever having asked | `NotificationWorker.askOnLaunchIfNeeded(hasSession:)`, called from `MattermostApp`'s scene `.task` after `restoreAll` |
| 3 | Settings names the state that is actually blocking a banner and offers a way out | `authorizationCopy/statusLabel(for:registration:delivery:)`; `NotificationAuthorizationRows` shows "No banners" / "Allowed, but notifications are set to none - no banner can appear", a hint, and `Open System Settings` (an allowed install with no readable settings row is **not** a failure state; see t_54798d27) |
| 4 | The diagnostics line carries the OS facts | `registration=<registered\|settingsRowAbsent\|unknown>` (+ `tables=<per-table outcome>` since t_54798d27) and `alerts=<none\|banner\|alert\|unknown>` in `NotificationWorker.diagnosticsLine`; `notificationsRegistration` + `notificationsRegistrationTables` + `notificationsAlertStyle` in step 6 |
| 5 | The install runbook gates on registration | `scripts/verify-notification-registration.sh` (live table first, legacy fallback) |
| 6 | The signing trade-off is decided and recorded | this document, §"Signing decision" |

New seam: `Mattermost/UI/Native/Notification/NotificationRegistration.swift`

- `NotificationRegistration` (`.registered` / `.settingsRowAbsent` / `.unknown`) with its diagnostics
  token. `.settingsRowAbsent` is the t_54798d27 rename of the old `.notRegistered`: it states that no
  *readable* table names the bundle, which is a fact, instead of asserting the OS has not registered
  it, which the probe cannot know.
- `SystemNotificationRegistrationReader` parses `apps[*].bundle-id` out of every configured table, in
  precedence order. Paths are built from the user-domain `Library` directory rather than
  `homeDirectoryForCurrentUser` (unavailable in the iOS SDK). The Mac build is not sandboxed
  (`codesign -d --entitlements` on the Catalyst product shows no `com.apple.security.app-sandbox`),
  so that is the real `~/Library`. **The live table is still unreadable from inside the app bundle**
  — `EPERM` on the group container, measured by t_54798d27 — which is why the reader reports the
  per-table outcomes instead of a registration verdict.
- `FixedNotificationRegistrationReader` for tests.
- `NotificationDeliverySettings(alertStyle:)` beside the scheduling seam, read from
  `UNNotificationCenterAdapter.deliverySettings()`.

The worker re-reads both facts at launch, on every foreground (`MattermostApp.onChange(of:
scenePhase)` → `activate()`), whenever Settings appears, and after every authorization round-trip, so
a change made in System Settings is reflected without a relaunch.

## Verification

### Unit tests (iPhone 16 Pro simulator, id `81A7F251-…`)

```
python3 scripts/qa-test.py --only-testing MattermostTests \
  --label t_e4d5a252-full3
  -> 2501 run / 8 skipped / 0 failed, xcodebuild rc=0 (79 s)
  log: build/logs/t_e4d5a252-full3.log

python3 scripts/qa-test.py --only-testing MattermostTests/NotificationWorkerTests \
  --only-testing MattermostTests/NotificationRegistrationTests \
  --only-testing MattermostTests/DiagnosticsTests --label t_e4d5a252-final
  -> 93 run / 0 skipped / 0 failed, xcodebuild rc=0
```

The card's tests, in `MattermostTests/NotificationWorkerTests.swift` unless noted:

| Test | Pins |
| ---- | ---- |
| `testNotDeterminedAsksEvenWhenThePersistedFlagSaysItAlreadyAsked` (T1) | a persisted `permissionRequested=true` does not swallow the ask |
| `testDeniedIsNeverRePromptedAndPointsAtSystemSettings` (T2) | denial is not re-prompted; status/copy are denied |
| `testAuthorizedMentionStillSchedules` (T3) | the T8 mention → request path is unchanged, and delivery still does not re-ask |
| `testDiagnosticsCarriesTheAbsentStateBesideAuthorizedStatus` (T4, renamed by t_54798d27) | `registration=settingsRowAbsent` beside `status=authorized` — two facts, no registration verdict |
| `testDiagnosticsAndCopyNameTheSilentStyle` (T4) | `alerts=none` → "No banners", the copy, and the Settings detour |
| `testBannerStyleKeepsThePlainAllowedReading` | a drawable style keeps the plain "Allowed" |
| `testAllowedCopyWithNoReadableRowNeverClaimsNothingCanAppear` (renamed by t_54798d27) | the row says "Allowed - macOS has no notification settings row this app can read; badges and banners still work", with no System Settings detour |
| `testLaunchAsksWhenNotDeterminedAndASessionExists` / `…WithoutASession` / `…AlreadyAnswered` / `testLaunchRegistersOnceWhenTheOSSaysAuthorizedButNeverAsked` | the launch ask, its two silences, and the macOS 26 authorized-but-never-asked reconciliation (one call per process) |
| `NotificationRegistrationTests` (new file) | the parser: live-only, legacy fallback, absent from both, unreadable table, similar id, empty id, broken file, default precedence, tokens |
| `DiagnosticsTests.testPermissionsStepReflectsProviderSnapshot` | `notificationsRegistration` + `notificationsAlertStyle` + the one-line read-out in the report |

AV — restore the pre-card gate and re-run the two behaviour tests:

```
python3 scripts/qa-test.py \
  --only-testing MattermostTests/NotificationWorkerTests/testNotDeterminedAsksEvenWhenThePersistedFlagSaysItAlreadyAsked \
  --only-testing MattermostTests/NotificationWorkerTests/testLaunchRegistersOnceWhenTheOSSaysAuthorizedButNeverAsked \
  --label t_e4d5a252-av-final
  -> 2 run, 5 assertions failed, xcodebuild rc=65
     testNotDeterminedAsks…: ("0") is not equal to ("1") - a persisted permissionRequested=true must not swallow the ask
     testLaunchRegistersOnce…: ("0") is not equal to ("1")
  log: build/logs/t_e4d5a252-av-final.log
```

With the fix restored, both pass in the 93-test and 2501-test runs above.

### Mac Catalyst product

```
xcrun xcodebuild build -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=macOS,variant=Mac Catalyst'
  -> ** BUILD SUCCEEDED **
```

This also proves `UNNotificationSettings.alertStyle` compiles for the Catalyst target.

### The install gate

```
bash scripts/verify-notification-registration.sh --self-test
  OK: self-test passed (live or legacy row -> 0, absent from both -> 1, unreadable -> 2)   exit 0

bash scripts/verify-notification-registration.sh
  OK: com.mattermost.ios is registered with the system notification table
      (live: …/group.com.apple.usernoted.plist)                                            exit 0

bash scripts/verify-notification-registration.sh --bundle-id com.example.not.installed
  FAIL: … has no notification-registration row in the live table … or the legacy one …     exit 1
```

The passing live check is the corrected fact, not a regression: the row exists on this OS. A build
whose bundle is in neither table still fails, and the message names the two ways to fix it.

## Runbook (mandatory last step of every install)

```
1. Install /Applications/Mattermost(ios).app
2. Open it. On a fresh code identity it asks by itself (launch ask, when a session exists), including
   on macOS 26 installs that already read "authorized" without ever having asked.
   If it does not: Settings → Notifications → Enable notifications → Allow.
3. bash scripts/verify-notification-registration.sh          # must exit 0
4. Check the diagnostics line still reads alerts=banner (not alerts=none).
5. Settings → Notifications → Send a test notification       # only now is a banner meaningful
```

A build is not delivered until step 3 passes. The cleanup/install card `t_e8c5ee86` should call the
script as its last step.

## Signing decision (item 6)

**Ad-hoc signing stays, and the re-grant step is mandatory after every install.**

The durable alternative — a stable self-signed identity whose designated requirement does not change
between builds — was evaluated and not taken on this host:

| Option | Grant survives a reinstall | Cost measured here |
| ------ | -------------------------- | ------------------ |
| ad-hoc `codesign -s -` (current) | **no** — every build is a new code identity, and the live table grows one `src` entry per build | one human "Allow" per install; the app now asks for it itself, and the gate proves the row exists |
| self-signed identity | yes, while the certificate and its designated requirement are unchanged | requires creating and importing a code-signing identity into the login keychain (`security find-identity -v -p codesigning` → **0 valid identities** on this host), keeping its private key stable, and teaching every build/publish script to use the name instead of `-`. Registration is also keyed to bundle id + path, so a moved `.app` can still reset it. |

Rationale: the self-signed identity is a *distribution* decision, not just a build flag — a release
downloaded by someone else cannot carry this host's private key, so the grant still resets for them
unless the same identity is shipped (which is not a thing). Ad-hoc keeps the artifact reproducible
from any machine; the price is one Allow per install, and the app now asks for it by itself.

If this ever becomes a paid-developer-account build (board card H1), Developer ID signing gives a
stable designated requirement for free and this table's second row becomes the right answer.

## What this does **not** claim

- **The Allow click is not verified here.** On this host the launch log shows `event=launch-ask` and no
  resulting `status-read` within 15 s: the system dialog owns the answer, and this session cannot see
  or click a window (`screencapture` → "could not create image from display"). So no screenshot of a
  presented banner is claimed. What is verified is that the app asks, that it reads the OS facts
  correctly from the real tables, and that the read-out names every state that suppresses a banner.
- Real APNs and a live Mattermost Push Proxy are not exercised (no certificate/credentials on this
  host). Everything above is the local-banner path.
- The legacy `ncprefs.plist` may gain a row again if the user changes the app's style in System
  Settings. The gate prefers the live table either way, so that cannot flip a verdict.

## Files

```
Mattermost/UI/Native/Notification/NotificationRegistration.swift   (new: the OS registration reader + delivery settings)
Mattermost/Core/NotificationWorker.swift                           (state-driven ask; launch reconciliation; copy; diagnostics)
Mattermost/Core/Diagnostics.swift                                  (registration + alert style in the snapshot and step 6)
Mattermost/UI/Native/Notification/NotificationAuthorizationSection.swift  (state naming, hints, Settings button)
Mattermost/MattermostApp.swift                                     (launch ask after restoreAll; refresh on foreground)
MattermostTests/NotificationWorkerTests.swift                      (T1–T4, silent style, launch ask + reconciliation)
MattermostTests/NotificationRegistrationTests.swift                (new: reader parser and precedence)
MattermostTests/DiagnosticsTests.swift                             (registration + style in step 6)
scripts/verify-notification-registration.sh                        (new: install gate + self-test)
docs/installing.md                                                 (runbook step)
```
