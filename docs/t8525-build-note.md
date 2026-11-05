# T8525 — channel info: the "Ignore mentions" switch (`notify_props.ignore_channel_mentions`)

Behaviour reference: `mattermost/mattermost-mobile` **v2.45.0**, commit
`162f2560d0e1df073220f7701d5a67cc17c8abeb` — `app/screens/channel_info/options/ignore_mentions/`
(`ignore_mentions.tsx` writes the field, `index.ts`'s `isChannelMentionsIgnored` derives the switch) and
`app/screens/channel_info/options/index.tsx` (which channel types get the row).
Server: the pinned fixture, Mattermost **9.11.19** at `http://127.0.0.1:8065`, and its own source at
`release-9.11` (`server/channels/app/mention_keywords.go`, `server/public/model/channel_member.go`).
Apache-2.0, read for behaviour and reimplemented; no upstream source copied.

The card asks for three things: a row in channel info's notification section, the write through the same
`notify_props` PATCH path, and a policy drop reason with its own diagnostic. All three are below — but
**the card's premise about the wire values was wrong**, and that mattered (§3).

## 1. What shipped

| Piece | Where |
| --- | --- |
| The switch, drawn for every channel type but a DM | `Mattermost/UI/Native/ChannelInfo/ChannelInfoView.swift` (`ignoreMentionsSection`) |
| Its state (derived, never a local flag) | `ChannelNotifyModels.swift` — `ChannelMentionIgnoreState`, `ChannelMentionIgnoreToggle` |
| The account-level half of `"default"` | `MMChannelAdminTypes.swift` — `MMPrincipal.notifyProps` / `.channelMentions` |
| The write, through `ChannelInfoService.setNotifyProps` | `ChannelInfoViewModel.setIgnoreMentions(_:)` |
| The drop reasons | `Notification/MentionNotificationPolicy.swift` — `.mentionsIgnored`, `.mutedChannelMentionsIgnored` |
| Unit tests (24) | `MattermostTests/T8525IgnoreMentionsTests.swift`, one correction in `T43NotificationInputTests.swift` |
| Live tests (2) | `MattermostUITests/T8525IgnoreMentionsUITests.swift` |
| The probe §2 and §3 are measured with | `scripts/t8525_ignore_mentions_probe.py` |

The body of the write is **one field**: `{"ignore_channel_mentions": "on" | "off"}`, and only when the
server's current value differs from the target. It is proven by the same read-back the preferences screen
uses (`GET …/members/{uid}`), so the switch always shows the server's answer, never the tap.

## 2. The server contract, measured

`python3 scripts/t8525_ignore_mentions_probe.py` — **11 checks, 0 failures** (fixture `mm-perf`, 9.11.19):

```
account notify_props.channel       = 'true'
membership notify_props (baseline)  = {"channel_auto_follow_threads": "off", "desktop": "default",
                                       "email": "default", "ignore_channel_mentions": "default",
                                       "mark_unread": "all", "push": "default"}

PUT ignore_channel_mentions='on'       -> HTTP 200  stored='on'
PUT ignore_channel_mentions='off'      -> HTTP 200  stored='off'
PUT ignore_channel_mentions='default'  -> HTTP 200  stored='default'
PUT ignore_channel_mentions='all'      -> HTTP 200  stored='all'

mention_count delta after @channel/off              = +1
mention_count delta after @channel/on               = +0
mention_count delta after @channel/all              = +1
mention_count delta after @channel/muted+default    = +0
mention_count delta after @channel/muted+off        = +1
mention_count delta after @perfprobe/on             = +1
```

The counter delta is the observable because `mention_count` is computed from the same mention keywords
the server uses to decide notifications; the probe posts as `t43buddy` into a throwaway channel
(`#t8525-ignore`) and reads `perfprobe`'s membership between posts.

The server's own rule, for the record (`release-9.11`, `server/channels/app/mention_keywords.go:74`):

```go
ignoreChannelMentions := channelNotifyProps[model.IgnoreChannelMentionsNotifyProp] == model.IgnoreChannelMentionsOn ||
    (channelNotifyProps[model.MarkUnreadNotifyProp] == model.UserNotifyMention &&
     channelNotifyProps[model.IgnoreChannelMentionsNotifyProp] == model.IgnoreChannelMentionsDefault)
if profile.NotifyProps[model.ChannelMentionsNotifyProp] == "true" && !ignoreChannelMentions {
    k["@channel"] = …; k["@all"] = …; k["@here"] = …
}
```

and the vocabulary the model validates (`server/public/model/channel_member.go:216`,
`IsIgnoreChannelMentionsValid`): `"on" | "off" | "default"` — nothing else.

## 3. The card's premise, corrected

The card says the toggle writes `notify_props.ignore_channel_mentions ("all"/"default")`. Measured, both
halves are wrong:

* the **pinned client** writes `"on"` / `"off"` (`ignore_mentions.tsx`, the file the card cites);
* the **server** stores `"all"` verbatim — the `PUT …/notify_props` route does not validate — but honours
  it exactly like `"off"` (`@channel` delta +1 above). Writing `"all"` would be a switch that changes
  nothing, with a green UI test to prove it.

So the switch writes `"on"` / `"off"` and never `"default"` (turning it off from a channel whose
`"default"` resolved against an account setting of "ignore channel mentions" would otherwise re-inherit
the very value it just showed as on). A field it does **not** understand — which today includes a stored
`"all"` — is drawn with the server's own string, cannot be flipped, and the refusal names it:
`This channel's mention setting is "all", which this app does not know how to change.`

The policy half of the card ("teach the policy the new drop reason") turned out to be a **correction** as
well. Before this card, `ignore_channel_mentions == "on"` dropped *every* notification from the channel,
including one that named the reader — contradicting the app's own footer copy ("Ignoring channel-wide
mentions still notifies you when you are named directly") and the measurement (+1). The policy now drops
only a **broadcast** mention, and names which setting did it:

| Situation | Decision |
| --- | --- |
| `"on"`, post says `@channel`/`@all`/`@here` | `.drop(.mentionsIgnored)` — "this channel is set to ignore @channel, @all and @here" |
| `"on"`, post names the reader | deliver |
| muted + `"default"`, post is a broadcast mention | `.drop(.mutedChannelMentionsIgnored)` — "this channel is muted, so @channel, @all and @here do not notify you" |
| muted + `"default"`, post names the reader | deliver (measured: the mute does not stop mentions) |
| muted + `"off"`, post is a broadcast mention | deliver (measured +1) |
| `"all"` stored, post is a broadcast mention | deliver — the value is not honoured |
| any setting, post mentions nobody | `.drop(.notAMention)` — the reason must not claim something was ignored |
| a DM/GM | the setting does not apply; the mute is the only switch (`upstream: type !== "D"`, and a DM's `@channel` names nobody) |

Both reasons report `recordsAsHandled == true`: the reader's own configuration decided, so the T14 poll
must not deliver the post later.

## 4. Verification

* unit: `scripts/qa-test.py --only-testing MattermostTests/T8525IgnoreMentionsTests` plus the four suites
  the policy change can move (`T43NotificationInputTests`, `T43NativeNotificationFeedTests`,
  `T54MentionBannerTests`, `T52ChannelInfoCompletenessTests`) — see §6 for the run.
* live: `scripts/qa-test.py --only-testing MattermostUITests/T8525IgnoreMentionsUITests` against the
  fixture: the switch writes `ignore_channel_mentions: "on"` and leaves `mark_unread` / `desktop` alone
  (read from the server, not the screen), the switch comes back "on" after a relaunch, and the
  notification-preferences screen shows the same value for the same field.
* the probe is re-runnable and restores the fixture it borrows (it removes the buddy from `#t8525-ignore`
  and puts the membership's `notify_props` back).

## 5. What is not covered

* No APNs on this host, so "the mention stops notifying" is asserted at the **policy** and at the
  **server's own counter** (the probe), not at a delivered/absent push notification.
* The live suite runs on the simulator only; no device soak.
* The switch is the **channel-wide** setting only. Upstream's channel-info row is the only place this
  setting is offered; the per-channel notification screen keeps its own three-state control for the same
  field, and the two agree because both read the same membership and write the same route (the second
  live test asserts that agreement).
* The account-level `notify_props.channel` is read from `GET /users/me`; a server that omits
  `notify_props` there leaves a `"default"` channel unresolvable, and the row then offers a Retry rather
  than drawing an "off" nobody chose.

## 6. Runs

Raw output is in `build/logs/` (`t8525-units.log`, `t8525-live*.log`, `t8525-probe.log`).

**Unit — green.** Run in a throwaway worktree of `HEAD` holding only this card's diff, because three other
cards are mid-flight in the shared checkout and one of them leaves its test target uncompilable:

```
python3 scripts/qa-test.py --platform ios --sim id=81A7F251-… \
  --label t8525-units --derived-data ~/Library/Developer/Xcode/DerivedData/mattermost-ios-t8525 \
  --only-testing MattermostTests/T8525IgnoreMentionsTests \
  --only-testing MattermostTests/T43NotificationInputTests \
  --only-testing MattermostTests/T43NativeNotificationFeedTests \
  --only-testing MattermostTests/T54MentionBannerTests \
  --only-testing MattermostTests/T52ChannelInfoCompletenessTests
```

130 tests, 0 failures; 22 of them are `T8525IgnoreMentionsTests`.

**Live — green** on the `T50 iPhone` simulator (iOS 26.5, `id=35A85DD5-…`):

```
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 … \
python3 scripts/qa-test.py --platform ios --sim id=35A85DD5-… \
  --label t8525-live8 --only-testing MattermostUITests/T8525IgnoreMentionsUITests
→ Executed 2 tests, with 0 failures … ** TEST SUCCEEDED **
```

**Probe — green** against the same server (`mm-perf`, 127.0.0.1:8065): `11 checks, 0 failure(s)`, and it
restores the membership it borrowed (`HTTP 200 -> stored 'default'`).

**Shared checkout — green too.** The same three suites run in place in
`/Users/yangsooyoon/Documents/yanks/code/mattermost-ios` (the integration line, with the other cards'
in-flight edits alongside this one): `Executed 84 tests, with 0 failures … ** TEST SUCCEEDED **`, 22 of
them `T8525IgnoreMentionsTests`. So the card's diff compiles next to the work it has to live with, not
only in isolation.

Three measured facts from getting there, all worth keeping:

* `--sim "name=iPhone 16 Pro"` is now ambiguous on this host (two devices carry that name) and
  `xcodebuild` answers `Unable to find a device matching the provided destination`. Address the
  simulator by `id=`.
* The same suite dies as `signal kill` / `Lost connection to the application` on a saturated host
  (5–6 concurrent `xcodebuild test` runs, ~60 MB free of 16 GB). It is not a code failure: the
  pre-existing `T52ChannelInfoUITests/testANotificationLevelIsWrittenAndSurvivesARelaunch` fails the
  same way on that simulator in the same window, never finding its own freshly created channel.
* A SwiftUI `Toggle` row only flips when its **control** is hit; the row's label is not a button, so
  `element.tap()` (centre of a row-wide element) does nothing while `isEnabled` still reads `true`.
  The suite aims at the trailing edge: `toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()`.
  Before that fix the live run showed the toggle present, enabled, value `0`, and **no PUT on the wire**.

