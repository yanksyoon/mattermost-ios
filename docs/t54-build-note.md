# T54 — the in-app mention banner (S25)

Branch `main` (this card runs in a `dir` workspace, not a worktree), based on `origin/main` at
`11c49c7`. Behaviour reference: `mattermost/mattermost-mobile` **v2.45.0**
(`162f2560d0e1df073220f7701d5a67cc17c8abeb`) — `app/screens/in_app_notification/`,
`app/screens/snack_bar/`. Server: the pinned fixture, Mattermost **9.11.19** at
`http://127.0.0.1:8065`. Devices: iPhone 16 Pro (iOS 18.3.1) and iPad Pro 11 (iOS 18.3.1, the
regular-width layout).

The card's claim is about what a **running app** shows a reader, so the evidence below is a real
mention posted by a second account (`t43buddy`) through `POST /posts` while the app is open in
another channel, read back through the app's own accessibility tree — not a stub agreeing with
itself.

## 1. What shipped

| Piece | Behaviour | Where |
| --- | --- | --- |
| The surface decision | Pure. Given the T43 `MentionDecision` and what the shell is showing (app active? primary server? which conversation?), answers `inAppBanner` / `systemNotification` / `suppressed(reason)`. The mention **rules** are not restated. | `Notification/InAppMentionBanner.swift` (`MentionPresentationPolicy`, `MentionSurfaceContext`, `MentionPresentation`) |
| The one banner slot | At most one banner. A newer mention takes the slot (latest wins — no backlog, which would replay stale mentions). Six-second bound, cancelled/rearmed on replacement, `openCurrent()` dismisses *then* routes. | `InAppMentionBannerCenter` |
| The banner | Channel as the title, `@author: message` as the body, material card, tappable as one accessibility element, swipe to dismiss, VoiceOver announcement on arrival. | `InAppMentionBannerView`, `InAppMentionBannerHost` |
| Mount point | **One** overlay above `RootView`'s whole `NavigationStack` — so it is not a per-screen overlay: the sidebar, a compact push and a regular split view are all inside it. Adds no view and no hit-test area while nothing is showing. | `Mattermost/UI/RootView.swift` |
| Feed wiring | `NativeNotificationFeed` asks the presentation policy on the `.deliver` branch and writes the **same** `MentionLedger` before handing the mention to either surface. No banner host in the process (`bannerCenter == nil`) ⇒ the pre-T54 system path, verbatim. | `Notification/NativeNotificationFeed.swift` |
| Tap funnel | `mentionBanner.onOpen` → `NativeNavigation.routeMention(serverID:channelID:teamID:postID:)` — the same call a system-notification tap makes, post id included | `MattermostApp.bindShellStores` |
| Shared facts | The worker and the feed read **one** `visibleChannel` closure and **one** `isAppActive` closure (installed together in `bindShellStores`), so the two surfaces cannot disagree about what the reader is looking at | `MattermostApp.swift` |
| Permission | `NotificationWorker.prepareAuthorization()` extracted from `presentMention`; the banner path calls it off the delivery path (see §3) | `Core/NotificationWorker.swift` |
| Read-out | `Record.surface` (`in-app banner` / `system notification`) is in Settings' last-mention row, so a live run can say *where* a delivered mention went | `NotificationInputSection.swift` |

The rule, in one table (each row is a unit test):

| policy decision | app | server | on screen | surface |
| --- | --- | --- | --- | --- |
| `.drop(any)` | any | any | any | suppressed(policy reason) |
| `.deliver` | background | any | any | system notification |
| `.deliver` | foreground | not primary | any | in-app banner |
| `.deliver` | foreground | primary | `.channel(same)` | suppressed (channel on screen) |
| `.deliver` | foreground | primary | `.unknown` (webview) | suppressed (the page owns the rule) |
| `.deliver` | foreground | primary | `.channel(other)` | in-app banner |
| `.deliver` | foreground | primary | `.noChannel` | in-app banner |

## 2. The live measurement

Fixture: `python3 scripts/t43_notification_seed.py --url http://127.0.0.1:8065 --json` (accounts
`perfprobe`/`t43buddy`; channels `t43-notify` and `t43-muted`). Command:

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password in scripts/perf_seed.py> \
python3 scripts/qa-test.py --platform ios --sim "iPhone 16 Pro" \
  --only-testing MattermostUITests/T54MentionBannerUITests
# 4 run, 0 skipped, 0 failed  (build/logs/ios-20261103-213941.log)
```

and, for the regular layout:

```
python3 scripts/qa-test.py --platform ios --sim "id=122E4BC7-…" \
  --only-testing MattermostUITests/T54MentionBannerUITests/testAForegroundMentionInAnotherChannelIsABannerThatOpensThePost
# 1 run, 0 skipped, 0 failed  (build/logs/ios-20261103-213548.log)
```

What the four phone tests measure, in order:

1. **The card's headline case.** The app is open in **T43 muted** with a draft typed in the composer
   (`"T54 draft"`). `t43buddy` posts `"T54 UI … banner: @perfprobe you were named"` into **T43
   notify**. The `mentionBanner` element appears (post `jrrskutqkfnb5d6o4stkabjwjw`) and its
   accessibility label contains both the channel (`T43 notify`) and the author (`@t43buddy`). The
   test then types `" stays"` — the composer reads `"T54 draft stays"`, i.e. **the banner did not
   take the keyboard**. Tapping the banner lands on `postFocus.jrrskutqkfnb5d6o4stkabjwjw` in
   `#T43 notify`, and the banner is gone. The read-out then says
   `post=jrrskutqkfnb5d6o4stkabjwjw channel=… outcome=delivered surface=in-app banner` with
   `delivered=1 suppressed=0`.
2. **Suppression.** Open in **T43 notify**, the buddy posts the same kind of mention there: no banner
   appears at all for 15 s, and the read-out says `outcome=you are looking at this channel`,
   `delivered=0 suppressed=1`.
3. **Bounded.** With `-uiTestBannerDuration 4`, an untouched banner is gone inside 15 s.
4. **Swipe.** A swipe up on the banner hides it.

Evidence PNGs (`xcrun xcresulttool export attachments` from those runs) are in `docs/t54-shots/`:
`phone-banner-over-channel-a.png` (banner over an open channel, composer focused, keyboard up),
`phone-landed-on-the-post.png`, `phone-settings-readout.png`,
`ipad-banner-over-channel-a.png` (banner spanning **both** columns of the split view),
`ipad-landed-on-the-post.png`.

**Both layouts**: on iPad the split view opens collapsed in portrait, so the test shows the sidebar
with its own `ToggleSidebar` control, opens a channel from it, and then measures the same three facts
(banner appears; label names channel + author; tap lands on the post). That is the "reachable in both
layouts" criterion, measured on the regular-width layout rather than inferred from the compact one.

## 3. A real bug the live run found (and the fix)

The first live run failed exactly one test: the banner never appeared on the **first** mention of the
run. The captured tree showed the app behind a modal system alert with no `mentionBanner` element for
the whole 45 s wait, while the later runs (permission already answered) showed it immediately.

Cause: the banner path called `await prepareAuthorization()` **before** presenting, and
`UNUserNotificationCenter.requestAuthorization` suspends until the reader answers the alert. So the
first mention of an install was held hostage by the OS permission prompt — a banner that never
appeared under its own prompt. Fix: the ledger, the banner and the record happen first, and the ask is
fired afterwards in a `Task` (never on the delivery path). Kept T8's contract (asked once, on the first
mention) without letting a modal alert gate a surface that needs no permission. The live test also
answers the alert if it is up (`dismissNotificationPermissionAlertIfPresent`) so the banner underneath
can be tapped on a fresh device.

## 4. Mutation check — the "channel on screen" rule is load-bearing

Deleted the `case .channel(visible) where visible == channelID → .suppressed(.channelOnScreen)` row
from `MentionPresentationPolicy` and re-ran the two tests that pin it:

```
# build/logs/ios-20261103-211810.log
testAForegroundMentionInTheChannelOnScreenIsSuppressed
  XCTAssertEqual failed: ("inAppBanner(silent: false)") is not equal to
  ("suppressed(Mattermost.MentionPresentationBlock.channelOnScreen)")
testWithTheChannelOnScreenNeitherSurfaceIsUsed
  XCTAssertNil failed: "MentionBanner(… postID: "post1" …)"
  XCTAssertEqual failed: ("Optional("delivered")") is not equal to
  ("Optional("you are looking at this channel")")
→ 2 run, 3 failed
```

Restored, re-ran: 23 run / 0 failed (`build/logs/ios-20261103-211633.log`).

## 5. The double path (banner ⇒ no second banner, no system notification)

Three layers, all green:

* **Unit, real feed + real ledger + real worker (`T54MentionBannerTests`).** One mention ⇒
  `bannerCenter.shownCount == 1`, `NotificationScheduling.added.count == 0` (nothing scheduled), one
  `delivered`. The same `posted` frame delivered twice ⇒ `alreadyDelivered`, `shownCount` still 1,
  `added` still 0, ledger has the post.
* **Unit, poller.** `MentionPoller.isNew(post, relativeTo: ledger.state(for:))` is `false` for a post
  the banner consumed — the T43 ring is the only ledger, and the banner writes it.
* **Live.** The read-out after the banner was tapped shows exactly one delivery for that post
  (`delivered=1 suppressed=0`, `surface=in-app banner`) after an 8 s wait, and no second
  `mentionBanner` element appears.

**Honest limit:** the *absence* of a system notification cannot be observed from XCUITest (the system
banner is outside the app and outside its accessibility tree). The claim rests on the surface the app
itself reports (`surface=in-app banner`), the fact that `UNUserNotificationCenter.add` was never
called (asserted in the unit path, where the centre is a recording double), and the ledger refusal.

## 6. Bounds and deliberate limits

* **It overlays the navigation bar.** The host is mounted outside the `NavigationStack` (that is what
  makes it survive a push and reach both layouts), so for its six seconds it covers the bar strip —
  visible in `docs/t54-shots/phone-banner-over-channel-a.png`. Transient, and the same thing an iOS
  system banner does.
* **No banner over a presented sheet.** A sheet is a separate presentation; a mention arriving while
  Settings or a gallery is open shows nothing until the sheet closes. Upstream's snackbar has the same
  containment; not claimed otherwise.
* **Latest wins, no backlog.** A replacement is immediate; a queue was rejected because it would show
  a reader a minute-old mention after a newer one.
* **Path A (webview pane) is unchanged.** `visibleChannel` answers `.unknown`, the presentation is
  `suppressed(.webPaneOwnsFocus)`, and the page keeps its own focused-channel rule — the T8 behaviour.
* **`-uiTestBannerDuration <s>`** (DEBUG only) moves the banner's lifetime for a live test that has to
  interact with it. The bound itself is unit-tested and the live default is exercised by test 3.

## 7. Tests

| Run | Result | Log |
| --- | --- | --- |
| `MattermostTests/T54MentionBannerTests` | 23 run / 0 skipped / 0 failed | `ios-20261103-211633` |
| whole `MattermostTests` (final tree) | **2133 run / 8 skipped / 0 failed** | `ios-20261103-215642` |
| `MattermostUITests/T54MentionBannerUITests` (iPhone 16 Pro, final tree) | 4 run / 0 failed | `ios-20261103-215923` |
| `…/testAForegroundMentionInAnotherChannelIsABannerThatOpensThePost` (iPad Pro 11) | 1 run / 0 failed | `ios-20261103-213548` |
| `MattermostUITests/T43NotificationUITests` (regression, same code path) | 2 run / 2 failed — **both pre-existing** | `ios-20261103-214502` |

The two T43 failures are `testDualRenderKeepsOneSourceAndNeverRefusesThePage` and
`testThePageBridgeIsInstalledOnlyWhenAsked`, and both fail on their *first* assertion
(`app.webViews.firstMatch.waitForExistence`) because they were written for the pre-2026-10-27 world
where the pane resolved **web** by default. Verified against pristine `HEAD` (`11c49c7`) in a throwaway
worktree (`.worktrees/t54-baseline`, since removed): the same two tests, the same two lines, the same
failure (`ios-20261103-215033`). They are stale tests of a surface decision, not a T54 regression —
and they are a candidate card of their own (T43's dual-render assertions need the `-surfaceMode` flag
the 2026-10-27 decision made necessary).

## 8. Files

```
Mattermost/UI/Native/Notification/InAppMentionBanner.swift          (new — policy, slot, view, host)
Mattermost/UI/Native/Notification/NativeNotificationFeed.swift      (surface decision + Record.surface)
Mattermost/UI/Native/Notification/NotificationInputSection.swift    (surface in the read-out)
Mattermost/Core/NotificationWorker.swift                            (prepareAuthorization extracted)
Mattermost/MattermostApp.swift                                      (owner, wiring, shared facts, tap funnel)
Mattermost/UI/RootView.swift                                        (one host above the stack)
MattermostTests/T54MentionBannerTests.swift                         (new)
MattermostUITests/T54MentionBannerUITests.swift                     (new)
docs/t54-shots/*.png                                                (live evidence)
```
