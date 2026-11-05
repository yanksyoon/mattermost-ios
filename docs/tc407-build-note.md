# t_c407645a — `channel_converted` in the native shell

Card: *"socket: a conversion on another client leaves the sidebar and pane stale."*

This note records what the pinned server actually sends, what the client now does with it, and how the
behaviour is proven. It is the evidence behind the comments in the code and the two test files.

## 1. What the server sends (measured, not assumed)

`scripts/tc407_channel_converted_probe.py` opens **two** websocket sessions (the actor and a member of
the conversation) and performs the conversions with the REST calls the app makes, dumping every frame.
Run against the pinned **9.11.19** server on `127.0.0.1:8065`; output in `build/logs/tc407-probe-1.log`.

### Case A — the card's scenario: a group message converted to a private channel

`POST /channels/{id}/convert_to_channel?team-id={tid}` → HTTP 200 `type=P`, same id.

Frames the converting user receives, all at +0.18s (the HTTP answer landed in the same millisecond):

| frame | payload |
|---|---|
| `channel_updated` | `data.channel` = the **whole converted channel** as a JSON string (`type=P`, `team_id`, `display_name`, `name`) |
| `sidebar_category_updated` | the moved row's categories |
| `posted` | the "converted to a channel" system post |
| `channel_member_updated` | the member's new roles (`channel_user channel_admin`) |

**No `channel_converted` at all.** The other member receives `channel_updated` + `sidebar_category_updated`
+ `posted` (it is delivered ~2s later — a websocket write throttle).

After the conversion: `GET /channels/{id}` → `type=P`; `GET /users/me/teams/{tid}/channels` lists it on the
target team only (it is gone from the other teams' lists).

### Case B — a privacy conversion: `PUT /channels/{id}/privacy {"privacy":"P"}`

Frames: `channel_updated` (whole record, as above), `posted`, **and** `channel_converted`:

```
channel_converted
  data        = {"channel_id": "uinxi77o7t86tckc1g5469zr5o"}      <- the id, and nothing else
  broadcast   = {"user_id":"", "channel_id":"", "team_id":"ocz148uck3r88dcjikj497bosh", ...}
```

So the frame the card names carries **only** the channel id, and the team is only in the envelope —
exactly the shape `channel_restored` has here. A decode that read `broadcast.channel_id` would drop every
real conversion.

### Case C — who receives it

A team member who is **not** in the conversation received no channel frames at all: the broadcast is
scoped to the conversation's members (`omit_users`), so the client's team scope is a second filter, not
the first.

### Cross-check against upstream

`mattermost-mobile` @ `162f2560d0e1df073220f7701d5a67cc17c8abeb`:
`app/actions/websocket/channel.ts:85` handles `CHANNEL_CONVERTED` by reading `msg.data.channel_id`, and
`:104` handles `CHANNEL_UPDATED`. Both check `EphemeralStore.isConvertingChannel(...)` first (`:86`,
`:104`) — the suppression rule this card needs, for **both** frames, because either one can be the echo
of the app's own write.

## 2. What the client does now

Decode (`Mattermost/Core/MM/SocketEvent.swift`)
- new `SocketChannelConverted` + `case channelConverted`. Id from `data.channel_id`, falling back to the
  envelope; team from the envelope; `channel_type` when a newer release adds it. No id anywhere → the
  frame is dropped rather than routed with an empty id.
- `conversionEchoChannelID`: the one place that says which frames can be the echo of the app's own
  conversion (`channelConverted` + `channel_updated`).

Routing
- `TeamSocketScope` accepts `.channelConverted` by the envelope's team or the channel→team map (same rule
  as `.channelRestored`).
- `TeamSidebarCoordinator.handle` drops a frame whose channel is in the in-flight registry **before**
  `onServerEvent` (a conversion echo is not a notification; the system `posted` that follows it is a
  separate frame and still arrives). Counted in `suppressedConversionEchoCount`.
- `NativeNavigation` owns the registry (`ChannelConversionTracking`: `beginChannelConversion` /
  `endChannelConversion` / `isConvertingChannel`), keyed by channel id, with a 120s trust window applied
  at read time.
- `ConvertGMToChannelViewModel.convert()` brackets the write with begin/defer-end, so the bracket closes
  on both answers.

Panes
- `ChannelViewModel`: `.channelUpdated` replaces the header from the payload (no request);
  `.channelConverted` re-reads the record (`applyHeader`) because the frame carries only the id.
  Both keep the pane's title/type honest; `awaitHeaderRefresh()` lets a test synchronise.
- `ChannelSidebarService`: `.channelUpdated(channel)` replaces the row (`.applied`, no request) or drops
  it when the record moved to another team; `.channelConverted` schedules the cheap refresh
  (`.refreshNeeded`).
- `ChannelSidebarCoordinator` also refreshes on `NativeNavigation.channelRevisions`, which the conversion
  flow bumps — the half that covers the app's **own** conversion, whose echo is suppressed.

## 3. Proof

- `MattermostTests/Tc407ChannelConvertedTests.swift` — 21 tests: the decode (measured frame verbatim, a
  newer shape, envelope fallback, id-less frame dropped), the team scope, the open pane
  (`channel_updated` applied without a request; `channel_converted` refetches; another channel's frame is
  ignored), the sidebar row (stops being a group message, drops a moved-elsewhere record, refresh for the
  id-only frame), the suppression rule (both frames while in flight, delivered again after, other
  channels unaffected, the flow brackets the write on success and on refusal).
- `MattermostUITests/Tc407ChannelConvertedUITests.swift` — live: the app opens a group message, the test
  converts it **from its own REST session** (the "another client"), and then asserts the open pane title
  and the sidebar row's label both become the new display name with no interaction, with the server as
  the oracle (`type=P`, same id).

Commands (this host):

```
xcodebuild -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=iOS Simulator,id=81A7F251-8B31-4945-8783-5A264C14B8D5' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa build-for-testing
xcodebuild test-without-building ... -only-testing:MattermostTests/Tc407ChannelConvertedTests

TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=<fixture> \
TEST_RUNNER_MM_AUTH_PASSWORD=<fixture> \
python3 scripts/qa-test.py --platform ios --only-testing MattermostUITests/Tc407ChannelConvertedUITests
```

Logs: `build/logs/tc407-probe-1.log`, `build/logs/tc407-unit-3.log`, `build/logs/tc407-ui-4.log`.

Results on this host (2026-11-05):

```
MattermostTests/Tc407ChannelConvertedTests   21 run, 0 failed   build/logs/tc407-unit-3.log
MattermostTests (whole suite)                2522 run, 8 skipped, 0 failed   build/logs/parity-scan-unit.log
MattermostUITests/Tc407ChannelConvertedUITests  1 run, 0 skipped, 0 failed (51.1s)   build/logs/tc407-ui-4.log
```

All three runs were `scripts/qa-test.py`/`xcodebuild` against the pinned local server and the iOS
simulator; the UI run was not skipped (a skip would have been reported as such).

## 4. A contract the live case had to learn

`POST /channels/{id}/convert_to_channel` reads the team from the **JSON body**
(`{"channel_id", "team_id", "display_name", "name"}` — the shape `ConvertGMToChannelDraft.body()
produces). Sending only `?team-id={tid}` with a body of `{"display_name","name"}` answers
**403 `api.context.permissions.app_error`** even for a `system_admin` account, because the handler's team
permission check runs against the empty team. `scripts/tc407_convert_403_probe.py` isolates this: the
conversion succeeds the moment `team_id` is in the body, and fails identically for a query-only POST with
any token. The app's own request was already correct (t_d088f075); only the UI test's second-client call
had to match it.

