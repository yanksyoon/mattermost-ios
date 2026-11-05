# t_e9550303 — channel read cursor: build note

Owner-reported defect: *"Once I've read the message, the blue dot and the bolded text does not go
away on the channel."*

## 1. What the app was missing

`markChannelsRead` existed but only the Mentions feed called it; the channel pane consumed a
`channel_viewed` echo and never sent anything. So `last_viewed_at` / `msg_count` / `mention_count`
never moved when a person opened a channel: the row's bold+dot and the group roll-up stayed until
another client or the Mentions feed moved the cursor.

## 2. Upstream behaviour (pinned mattermost/mobile `162f2560`, v2.45.0)

Paths were read from the pinned tree (the `app/actions/views/channel.ts` path in the card no longer
exists at that SHA; the actions live under `app/actions/{remote,local,websocket}/`):

| fact | source |
| --- | --- |
| the call is `POST /channels/members/me/view` | `app/client/rest/channels.ts:369` (`viewMyChannel`) |
| posted from the channel screen | `app/actions/remote/channel.ts` (`switchToChannel`, ~746) |
| posted when the post list's `posts.length` changes | `app/screens/channel/channel_post_list/channel_post_list.tsx:92` |
| local clear + `last_viewed_at` on success | `app/actions/local/channel.ts:175` (`markChannelAsViewed`) |
| another device's read clears the row too | `app/actions/websocket/channel.ts:141` (`channel_viewed`) |
| throttling | `app/hooks/throttled.ts` (leading-edge, per channel) |

Deliberate divergence: this pane posts the view when its page reaches `.loaded` **and** the pane is
visible **and** the scene is active **and** the newest row is on screen, rather than on mount
unconditionally. A pane that is loading, backgrounded or scrolled into history has not read the
message, and a cursor that advances then is worse than the bug being fixed.

## 3. Implementation

* `ChannelAPI.viewChannel` — the `POST /channels/members/me/view` client call.
* `ChannelServing.viewChannel` — service requirement with a no-op default so older fakes compile.
* `ChannelViewModel` — `// MARK: - Read state` block: in-flight guard, re-send when a post arrives
  mid-flight, `postViewIfNeeded()` invoked after load, after a post while visible, and after a
  resync; `MMChannelViewResponse` applied through `onViewed`.
* `ChannelReadApplication` — the one function that applies a landed view to the sidebar row, the
  group roll-up and `SessionStore`'s badge, plus the authoritative `GET /users/me/teams/unread`
  follow-up. Used by both `MattermostApp.bindShellStores` and the unit suite, so the three derived
  values are proven to move from the same answer.
* `ChannelSidebarService.applyRead` — clears one channel's counters, advances `lastViewedAt`,
  re-derives group markers and totals in a single `rebuild()`; `nil` membership is tolerated
  ("unknown", never "everything is read").
* `ChannelView` — `readerAtNewest` from the scroll controller (≤40 pt from the bottom, not being
  dragged), re-synced on appear, after activation, on `scenePhase == .active` and on reader
  movement; a pane routed at `focusPostID` cannot claim "at the bottom" before the jump lands.

## 4. Tests

`MattermostTests/ReadStateTests.swift` — 15 tests, **all green** (`ReadStateTests` 15/15):
T1 exactly one view with the channel id on open; T2 row/group/badge clear in the same update and a
different channel keeps its emphasis; T3 backgrounded scene, scrolled-up and hidden pane post
nothing; T4 `channel_viewed` from another device clears; T5 a new post while visible re-posts; T6
muted rows follow the dot-only rule.

Full unit target: `2428 run, 0 failed`.

Revert tests (each mutation applied, run, restored):

| mutation | result |
| --- | --- |
| delete `postViewIfNeeded()` after `.loaded` | T1 fails (`viewedChannelIDs` empty) |
| remove the visible/scene/at-newest gate | T3 fails (view posted while backgrounded) |
| remove the sidebar `applyRead` from `ChannelReadApplication` | T2 fails (row keeps Unread) |

Live UI (`MattermostUITests/T33ChannelSidebarUITests/testOpeningAnUnreadChannelClearsItsRow`,
real server `127.0.0.1:8065`): another user's post badges a row, the test taps it, the server's own
cursor moves (`msg_count == total_msg_count`, the test never calls the view endpoint) and the row
reads no Unread after returning to the list. `RESULT: PASS` (188 s, run `live-t9550303d`).

## 5. Release-build evidence

The XCUITest bundle cannot run in a Release configuration on this project (the test targets use
`@testable` and `PerfProbe`, both Debug-only — `xcodebuild test -configuration Release` stops at
`cannot find 'PerfProbe' in scope`). Following the repo's existing pattern (`-sidebarGroupSnapshot`,
`-dmPagingSnapshot`), `MattermostApp` gained an argument-gated **Release-shipping** probe:

```
-readStateSnapshot <dir> [-readStateChannel <name>] [-readStateListOnly]
```

It waits for the sidebar, picks an unread row, photographs the list, opens the channel through
`NativeNavigation.openChannel` (the same funnel a tap uses), waits for the row's emphasis to clear,
photographs the pane, and writes the model's own numbers to `read-state.txt`.

Release build: `xcodebuild -configuration Release … build` → **BUILD SUCCEEDED**.

Run against the real server with an unread seeded by another account (`opsbot`):

```
before_emphasis=true   before_badge=dot   before_rowValue=Unread   before_groupUnreadChannels=2
open_emphasis=false    open_badge=none    secondsToClear=1         open_groupUnreadChannels=1
after_emphasis=false   after_badge=none   remainingUnreadRows=1
```

So on the shipping build the row lost its bold and dot within one second of the channel being
opened, the group roll-up fell from 2 to 1 (the other unread channel correctly kept its dot), and
the state stayed cleared. `docs/t_e9550303-shots/read-state.txt` is that note;
`read-state-02-channel.png` is the Release app showing the channel it read.

### What is *not* claimed

* No Release screenshot of the **list** with the cleared row: on the phone layout the channel pane
  is a push, and `popToRoot()` from the probe did not reliably return to the list within the
  capture window (the two list-only runs in `read-state-list.txt` are the before/after model
  states, not the visual pair). The visual before/after pair comes from the live UI test
  (`docs/t_e9550303-shots/t9550303-01-unread-before-open.png` /
  `t9550303-02-read-after-open.png`, which show the CHANNELS header bold+dot before and grey
  without a dot after).
* No real APNs or push-proxy behaviour is involved in this card.

## 6. Found while proving it (separate card, not fixed here)

`GET /users/me/channel_members` is paginated at **60 rows** by default and `ChannelSidebarAPI
.myChannelMembers()` sends no `per_page`, while the fixture account is in 422 team channels. Rows
outside that page get no counters at all, so those channels can never show bold or a dot —
independently of the read cursor. The live test therefore seeds unread in channels that are inside
the page the app actually reads.
