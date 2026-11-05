# t_e4d5a252 — notifications never register with macOS on a fresh install

Reported (owner): "Can you tell me why notification doesn't work?"

The answer is **not** the earlier delivery bugs (`t_6a2b0fb4`/`t_ba355551` fixed those). The app was
examining mentions and scheduling requests; the operating system had nowhere to put them.

## The measured state (2026-11-05, this Mac)

Installed build: `/Applications/Mattermost(ios).app`, 0.71.0 (371), `CFBundleIdentifier =
com.mattermost.ios`, signed ad-hoc.

1. **The mention ledger advances.** `defaults read com.mattermost.ios` →
   `mm.mentions.state.3E4B80BD-…` has `watermarkTs 1793883323855` and 115 notified post ids, so the
   app reads mentions and writes them as handled.
2. **The OS has no notification row for the bundle.**

   ```
   plutil -p ~/Library/Preferences/com.apple.ncprefs.plist | grep -i mattermost
     "bundle-id" => "Mattermost.Desktop"          # the official Electron client
   ```

   The same table lists 114 bundle ids; `com.mattermost.ios` is not one of them.
3. **This install never asked.** `mm.notifications.permissionRequested` is absent from the domain.

Consequence: `UNUserNotificationCenter.add()` accepts the request into the queue and the OS drops
it. `notificationSettings()` can still answer `.authorized` (from an identity the new build no
longer has) or `.notDetermined`. The app's own "scheduled" outcome therefore proves nothing about
presentation.

### Why nothing ever asked again

`NotificationWorker.prepareAuthorization()` asked only when

```swift
statusBefore == .notDetermined && !hasRequestedAuthorization
```

and `hasRequestedAuthorization` came from a **persisted** UserDefaults flag
(`mm.notifications.permissionRequested`). The flag outlives the code identity that earned it: every
install re-signs ad-hoc (`codesign --force --deep -s -`), macOS discards the registration, and the
flag keeps saying "already asked". The only two callers were Settings → Notifications and the first
mention that reached the in-app banner path; the install runbook opens neither, so the prompt was
never presented.

## What this change does

| # | Requirement | Where |
| - | ----------- | ----- |
| 1 | Authorization is **state-driven**: `.notDetermined` may always ask; the persisted flag is history, never a gate | `NotificationWorker.prepareAuthorization()` — gate is `didAskThisProcess` (process-scoped) + the OS status |
| 2 | Ask at first launch of a new install when a session exists | `NotificationWorker.askOnLaunchIfNeeded(hasSession:)`, called from `MattermostApp`'s scene `.task` after `restoreAll` |
| 3 | Settings names the missing-registration case and offers a way out | `NotificationWorker.authorizationCopy/statusLabel(for:registration:)`; `NotificationAuthorizationRows` shows "Not registered with macOS - nothing can appear", a hint, and `Open System Settings` |
| 4 | The diagnostics line carries the OS registration fact | `registration=<registered\|notRegistered\|unknown>` in `NotificationWorker.diagnosticsLine`; `notificationsRegistration` in diagnostics step 6 |
| 5 | The install runbook gates on it | `scripts/verify-notification-registration.sh` |
| 6 | The signing trade-off is decided and recorded | this document, §"Signing decision" |

New seam: `Mattermost/UI/Native/Notification/NotificationRegistration.swift`

- `NotificationRegistration` (`.registered` / `.notRegistered` / `.unknown`) with the diagnostics
  token; `.unknown` is what a phone answers (there is no such table in iOS) and is never rendered as
  a failure.
- `NCPrefsNotificationRegistrationReader` parses `apps[*].bundle-id` out of
  `~/Library/Preferences/com.apple.ncprefs.plist`. It resolves the path through the user-domain
  `Library` directory rather than `homeDirectoryForCurrentUser` (unavailable in the iOS SDK). The Mac
  build is not sandboxed (`codesign -d --entitlements` on the Catalyst product shows no
  `com.apple.security.app-sandbox`), so that is the real `~/Library`.
- `FixedNotificationRegistrationReader` for tests.

The worker re-reads the fact at launch, on every foreground (`MattermostApp.onChange(of: scenePhase)`
→ `activate()`), whenever Settings appears, and after every authorization round-trip, so a grant made
in System Settings stops the row saying "Not registered" without a relaunch.

## Verification

### Unit tests (iPhone 16 Pro simulator, iOS 18.3.1, id `81A7F251-…`)

```
python3 scripts/qa-test.py --only-testing MattermostTests \
  --label t_e4d5a252-full
  -> 2493 run / 8 skipped / 0 failed, xcodebuild rc=0 (111 s)
  log: build/logs/t_e4d5a252-full.log
```

The card's tests, in `MattermostTests/NotificationWorkerTests.swift` unless noted:

| Test | Pins |
| ---- | ---- |
| `testNotDeterminedAsksEvenWhenThePersistedFlagSaysItAlreadyAsked` (T1) | a persisted `permissionRequested=true` does not swallow the ask |
| `testDeniedIsNeverRePromptedAndPointsAtSystemSettings` (T2) | denial is not re-prompted; status/copy are denied |
| `testAuthorizedMentionStillSchedules` (T3) | the T8 mention → request path is unchanged |
| `testDiagnosticsCarriesNotRegisteredWhenTheOSHasNoRow` (T4) | `registration=notRegistered` beside `status=authorized` |
| `testAllowedCopyNamesTheMissingRegistration` (T4/Settings) | the row says "Not registered with macOS - nothing can appear" |
| `testLaunchAsksWhenNotDeterminedAndASessionExists` / `…WithoutASession` / `…AlreadyAnswered` | the launch ask, and its two silences |
| `NotificationRegistrationTests` (new file) | the reader's parser: present, absent, similar id, missing table, empty id, broken file, tokens |

AV pass — restore the old gate (`&& !hasRequestedAuthorization`) and re-run T1:

```
--only-testing MattermostTests/NotificationWorkerTests/testNotDeterminedAsksEvenWhenThePersistedFlagSaysItAlreadyAsked
  XCTAssertEqual failed: ("0") is not equal to ("1") - a persisted permissionRequested=true must not swallow the ask
  RESULT: FAIL        (build/logs/t_e4d5a252-av-revert.log)
```

With the fix restored, the same test passes in the 2493-test run above.

### Mac Catalyst product

The XCUITest target does not compile for Catalyst on this host (`XCUIElement.pinch`, pre-existing,
unrelated), so the unit-test scheme cannot run there; the **app target** does build:

```
xcrun xcodebuild build -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=macOS,variant=Mac Catalyst'
  -> BUILD SUCCEEDED, 0 errors        (build/logs/t_e4d5a252-macbuild.log)
```

### The real reader against the real table

The reader source from the app target, compiled unchanged and run against this host:

```
path=/Users/yangsooyoon/Library/Preferences/com.apple.ncprefs.plist
com.mattermost.ios=notRegistered
Mattermost.Desktop=registered
com.example.definitely-absent=notRegistered
```

So the parse answers the two questions that matter: the Electron client's row is found, this
bundle's missing row is reported, and an absent id is not mistaken for one of them.

### The install gate

```
bash scripts/verify-notification-registration.sh --self-test
  OK: self-test passed (registered -> 0, absent -> 1, unreadable -> 2)     exit 0

bash scripts/verify-notification-registration.sh
  FAIL: com.mattermost.ios has no Notification Center registration in
        /Users/yangsooyoon/Library/Preferences/com.apple.ncprefs.plist - open the app >
        Settings > Notifications > Enable notifications > Allow (or System Settings >
        Notifications > Mattermost), then re-run this check.                exit 1
```

That exit 1 is the reported failure, reproduced by the gate that will now block a "delivered" claim.

## Runbook (mandatory last step of every install)

```
1. Install /Applications/Mattermost(ios).app
2. Open it. On a fresh code identity it now asks by itself (launch ask, when a session exists).
   If it does not: Settings → Notifications → Enable notifications → Allow.
3. bash scripts/verify-notification-registration.sh          # must exit 0
4. Settings → Notifications → Send a test notification       # only now is a banner meaningful
```

A build is not delivered until step 3 passes. The cleanup/install card `t_e8c5ee86` should call the
script as its last step.

## Signing decision (item 6)

**Ad-hoc signing stays, and the re-grant step is mandatory after every install.**

The durable alternative — a stable self-signed identity whose designated requirement does not change
between builds — was evaluated and not taken on this host:

| Option | Grant survives a reinstall | Cost measured here |
| ------ | -------------------------- | ------------------ |
| ad-hoc `codesign -s -` (current) | **no** — every build is a new code identity | one human "Allow" per install; the app now asks for it itself, and the gate proves it |
| self-signed identity | yes, while the certificate and its designated requirement are unchanged | requires creating and importing a code-signing identity into the login keychain (`security find-identity -v -p codesigning` → **0 valid identities** on this host), keeping its private key stable across machines, and teaching every build/publish script to use the name instead of `-`. Notification Center registration is also keyed to bundle id + path, so a moved `.app` can still reset it. |

Rationale: the self-signed identity is a *distribution* decision, not just a build flag — a release
downloaded by someone else cannot carry this host's private key, so the grant still resets for them
unless the same identity is shipped (which is not a thing). Ad-hoc keeps the artifact reproducible
from any machine; the price is one Allow per install, and the card's whole point is that the app
now asks for it by itself and the install script refuses to call the build delivered until the OS
agrees.

If this ever becomes a paid-developer-account build (board card H1), Developer ID signing gives a
stable designated requirement for free and this table's second row becomes the right answer.

## What this does **not** claim

- No notification can be presented until a human clicks Allow once for the current code identity.
  The fix makes the app ask and makes the miss visible; it cannot fabricate a registration.
- Real APNs and a live Mattermost Push Proxy are not exercised here (no certificate/credentials on
  this host). Everything above is the local-banner path.
- The screenshot proof of a presented banner belongs to `t_6a2b0fb4`; this card supplies the gate
  that makes such a capture trustworthy.

## Files

```
Mattermost/UI/Native/Notification/NotificationRegistration.swift   (new: the OS registration reader)
Mattermost/Core/NotificationWorker.swift                           (state-driven ask; launch ask; copy; diagnostics)
Mattermost/Core/Diagnostics.swift                                  (registration in the snapshot and step 6)
Mattermost/UI/Native/Notification/NotificationAuthorizationSection.swift  (state naming, hint, Settings button)
Mattermost/MattermostApp.swift                                     (launch ask after restoreAll; refresh on foreground)
MattermostTests/NotificationWorkerTests.swift                      (T1–T4 + launch ask)
MattermostTests/NotificationRegistrationTests.swift                (new: reader parser)
MattermostTests/DiagnosticsTests.swift                             (registration in step 6)
scripts/verify-notification-registration.sh                        (new: install gate + self-test)
docs/installing.md                                                 (runbook step)
```
