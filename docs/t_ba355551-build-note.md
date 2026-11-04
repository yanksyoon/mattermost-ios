# t_ba355551 — the mention input is derived from the pane, not forced by a constant

Reported: a Release build of the native workspace delivered **no** mention notification. The Settings
`Send a test notification` button worked (it calls the worker directly), and the read-out said the
socket was the input — but a real message from another account produced nothing.

## What was measured, and why it happened

`NotificationInputGate` answered "which input is live" with a process-wide constant:
`NotificationPathStore.compileDefault` → `.bridge` in Release. A Release native workspace mounts no
web view, so nothing reported a mention on that side; and the same constant made the socket **refuse**
every `posted` event. Two inputs, both silent, in the one configuration that ships.

The constant was doing two jobs at once:

- the **shipped answer** — which must follow what is actually rendering;
- a **debug affordance** — force one input to reproduce a dual-render run.

t_ba355551 separates them. `NotificationPathStore` keeps only the debug tier (launch flag → persisted
row), and it is DEBUG/PERF_PROBE-only: a Release build reads neither and yields `nil`.

## What this change adds

| # | Requirement | Where |
| - | ----------- | ----- |
| 1 | A native pane must deliver a real mention with no flag | `NotificationInputGate.mode(for:)` — `webPane.contains(id) ? .bridge : .socket` |
| 2 | A web pane must keep the page as the input (the socket stays silent) | same rule; `acceptsSocket` keeps `&& !webPane.contains(id)` so a forced `.socket` cannot double-fire on a dual-render run |
| 3 | The read-out must name the live answer, and say where it came from | `NotificationInputRouting.liveModeLabel`; `NotificationInputSection`'s `Mention input` row + detail (`derived…` / `forced by…`) |
| 4 | A Release build must not be able to force the input | `setOverride` refuses unless `debugAffordances`; `NotificationPathStore` never produces an override there |
| 5 | One diagnostics line naming the input, once per change | `NotificationInputRouting.logInputInForce`, emitted from `acceptsSocket` (before a refusal too), `acceptsBridge`, and `paneKindChanged` |
| 6 | Counters: one mention, one delivery | `socketDelivered` / `socketSuppressed` / `bridgeAccepted` / `bridgeRefused`, surfaced as the Settings rows `From the socket` and `From the web view` |

Files:

```
Mattermost/UI/Native/Notification/NotificationInputRouting.swift   (derived gate; debug-only override; per-server log line)
Mattermost/UI/Native/Notification/NotificationPathStore.swift      (no compile-time default; DEBUG-only tiers; `overrideMode`)
Mattermost/UI/Native/Notification/NotificationInputSection.swift   (mode row names the derived answer + its provenance)
Mattermost/UI/Native/Notification/NativeNotificationFeed.swift     (asks `routing.acceptsSocket` so the line has a witness)
Mattermost/MattermostApp.swift                                     (store → routing override wiring)
MattermostTests/T43ShippedDefaultTests.swift                       (new: 9 tests, the shipped path end to end)
MattermostTests/T43NotificationInputTests.swift                    (derivation tests replace the constant tests)
MattermostTests/T43NativeNotificationFeedTests.swift               (no more `setMode(.socket)` in setUp)
MattermostTests/T54MentionBannerTests.swift                        (same)
MattermostUITests/T43NotificationUITests.swift                     (new shipped-default test; webview config forces `channelView=web`)
MattermostUITests/T54MentionBannerUITests.swift                    (drops `-notificationPath socket`: the banner suite is the shipped path)
docs/parity.md                                                     (T43 row: the flip is taken, by measurement)
docs/t_ba355551-shots/t_ba355551-shipped-default.png               (live read-out, attached by the UI test)
```

## Verified against a real server

Mattermost 9.x in the local `mm-perf` container (`http://127.0.0.1:8065`), simulator **T50 iPhone**
(iPhone 16 Pro, iOS 26.5), app launched by `MattermostUITests` with **no** `-notificationPath` flag,
signed in through the native login form, mention posted by `t43buddy` into `t43-notify` while the app
was foreground on Settings.

```
testTheShippedDefaultDeliversANativeMention ... passed (20.879 seconds)
  notificationPath.mode          = Native socket
  notificationPath.webPanes      = 0
  notificationPath.liveSockets   = 1
  notificationPath.socket        = delivered=1 suppressed=0
  notificationPath.bridge        = accepted=0 refused=0
  notifications=status=authorized requested=false lastSchedule=none
```

The read-out in the attached screenshot reads:

```
Mention input                    Native socket
  derived from the server's pane: native → Native socket, web view → Web view bridge
Web view panes mounted           0
Servers with a live socket       1
From the socket                  1 delivered · 0 suppressed
From the web view                0 accepted · 0 refused
Page can report (window.desktop) not installed
Last mention delivered           T43 notify
```

Suite results:

```
python3 scripts/qa-test.py --platform ios --sim "T50 iPhone" \
  --only-testing MattermostUITests/T43NotificationUITests            -> 4 run, 0 failed (129 s)
python3 scripts/qa-test.py --platform ios --sim "T50 iPhone" \
  --only-testing MattermostUITests/T43NotificationUITests \
  --only-testing MattermostUITests/T54MentionBannerUITests           -> 6 of 8 passed; the two webview
                                                                        configs could not mount a web
                                                                        pane (see below), fixed by
                                                                        `-surfaceMode channelView=web`
                                                                        and then green 4/4
python3 scripts/qa-test.py --platform mac \
  --only-testing .../T43ShippedDefaultTests --only-testing .../T43NotificationInputTests \
  --only-testing .../T43NativeNotificationFeedTests --only-testing .../T54MentionBannerTests
                                                                     -> 94 run, 0 failed (31 s)
xcodebuild test … MattermostTests                                    -> 2195 run, 11 skipped,
                                                                        1 failed: T53MediaFootprintTests
                                                                        (pre-existing host flake, see
                                                                        docs/t_c941e3d3-build-note.md)
xcodebuild build -configuration Release -destination 'macOS,variant=Mac Catalyst'
                                                                     -> BUILD SUCCEEDED
```

### The test that would have caught it

`MattermostTests/T43ShippedDefaultTests` drives the real `NotificationWorker`, the real gate and the
real `NativeNotificationFeed` with a `UNUserNotificationCenter` double:

- `testANativePaneDeliversADirectMessageThatNamesNobody` — a DM with no `@mention`, one request,
  banner + sound (`content.sound != nil`), `outcome=delivered`, `socketDelivered == 1`;
- `testAMutedChannelStillNotifiesARealMention`, `testADirectMessageWithNotificationsOffDoesNotNotify`,
  `testTheReadersOwnPostDeliversNothing`, `testTheConversationOnScreenIsSuppressedAndStillHandled`;
- `testAWebPaneLetsThePageDeliverAndTheSocketStaysSilent` — the web pane mounted: the socket schedules
  nothing, the page delivers exactly one;
- `testBothInputsLiveForOneServerProduceExactlyOneBanner` — the adversarial case: socket live **and** a
  bridge frame for the same post → one request, `bridgeRefused == 1`;
- `testAReleaseSemanticsRoutingRefusesToForceTheInput` — `setOverride(.socket, debugAffordances: false)`
  leaves the gate deriving;
- `testTheReadOutNamesTheSocketAndCountsTheOneDelivery` — the Settings numbers.

Mutation check, run for real (`build/logs/t_ba355551-mutation-revert-derivation.log`): reverting **only**
`mode(for:)` to the old `return .bridge` constant turns 7 of those 9 red, including test 1 and the
"both inputs live" case — `Executed 9 tests, with 26 failures`.

## What I could not capture on this host, and why

- **The app's own `os_log` line and a `usernoted` `presented=1` row for the live run.** On the iOS 26.5
  simulator the app's `os_log` output does not reach `xcrun simctl spawn … log show/stream` for that
  subsystem (0 records, while SpringBoard records for the same bundle id appear), and
  `usernotificationsd`'s rows are privacy-redacted:
  `usernotificationsd: (65D3FA3E-…) [com.apple.usernotificationsd:Connections] <compose failure [shared UUID]>`.
  The app's `DeliveredNotifications.plist` is also empty after the run, so Notification Center's
  delivered list is not usable as proof either. What *is* measured is the app's own read-out
  (`status=authorized`, `delivered=1`, `Last mention delivered: T43 notify`) plus the scheduled request
  the worker records — that is the evidence quoted above. A macOS-Catalyst proof of the `usernoted`
  row is still open: the Catalyst build reads `status=authorized`, but a session seeded through the
  `-uiTestSeedStoredToken` test seam never authenticates its socket (only `authentication_challenge`
  and pings, no `posted` events), so a mention cannot reach it without the login form.
- **A second live device.** The UI tests resolve `iPhone 16 Pro` to `T50 iPhone` on this host, so every
  live number above is from that one device/runtime.

## Behaviour notes for the next card

- `NotificationInputSection`'s row now reads `Native socket` / `Web view bridge` / `Per server` (two
  servers with different panes). The detail line says whether that was derived or forced, which is the
  difference between the shipped answer and a debug run.
- The bridge fallback is unchanged and deliberate: a server whose pane is native but whose socket is
  *not yet* live still accepts a page frame, because a mention nobody hears is worse than a fallback.
  A live socket closes it (`acceptsBridge`), so the double-banner case stays impossible.
