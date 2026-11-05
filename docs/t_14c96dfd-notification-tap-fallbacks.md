# t_14c96dfd — notification taps when the post or channel is gone

Behaviour reference: `mattermost/mattermost-mobile` **v2.45.0 @ 162f2560d0e1df073220f7701d5a67cc17c8abeb**
(`app/utils/notification/index.ts` → `notificationError`, `app/actions/remote/notifications.ts` →
`openNotification` / `fetchNotificationData`).
Server of record for the measurements below: **Mattermost 9.11.19**, the `mm-perf` fixture container on
`http://127.0.0.1:8065`.

## 1. What the pinned client does

`notificationError` (133-line file, read at the pinned commit) carries one title and four sentences, and
every one of them is followed by `navigateToRoot()`:

| upstream outcome | title | sentence |
| --- | --- | --- |
| `no_post` | `Message not found` | `The message has not been found.` |
| `not_channel_member` | `Message not found` | `This message belongs to a channel where you are not a member.` |
| `not_team_member` | `Message not found` | `This message belongs to a team where you are not a member.` |
| `no_connection` | `Message not found` | `The server is unreachable and it was not possible to retrieve the specific message information for the notification.` |

The tap path that produces them is `fetchNotificationData`: `fetchMyChannel(channel_id, user_id)` — a
`GET /channels/{id}/members/me` plus a `GET /channels/{id}` — and, for a **thread** notification, a
`GET /posts/{root_id}`. A tap must never dead-end: the reader is always left on a conversation list with
a sentence explaining why the message is not there.

## 2. What the server actually answers (measured)

`scripts/t14c_notification_tap_probe.py` creates its own fixtures (a channel both accounts are in, a
public and a private channel the *non-admin* buddy owns, an archived channel, a DM, a live post, a
soft-deleted post) and records the status, error id and `delete_at` for every request a tap can make.
Two accounts are used on purpose: the fixture `perfprobe` account is a **system admin**, and a system
admin can read channels it is not a member of — measuring only the admin would hide the real fallback.

```
$ python3 scripts/t14c_notification_tap_probe.py --url http://127.0.0.1:8065
membership: /users/me/teams/{t}/channels/{c} is not a route  404  id=api.context.404.app_error
membership: channel I am in                           200
membership: public channel I am not in                404  id=app.channel.get_member.missing.app_error
membership: private channel I am not in               404  id=app.channel.get_member.missing.app_error
membership: channel that does not exist               403  id=api.context.permissions.app_error
membership: archived channel I was never in           404  id=app.channel.get_member.missing.app_error
membership: direct message                            200
membership: (non-admin) a channel it is in            200
membership: (non-admin) a public channel it is not in  403  id=api.context.permissions.app_error
membership: (non-admin) a private channel it is not in  403  id=api.context.permissions.app_error
membership: (non-admin) archived channel it was in     200
membership: (non-admin) a channel that does not exist  403  id=api.context.permissions.app_error
channel: (non-admin) a public channel it is not in     200  delete_at=0
channel: (non-admin) a private channel it is not in    403  id=api.context.permissions.app_error
channel: (non-admin) archived channel it was in        200  delete_at=1793850354863
channel: channel I am in                               200  delete_at=0
channel: public channel I am not in                    200  delete_at=0
channel: private channel I am not in                   200  delete_at=0
channel: archived channel                              200  delete_at=1793850354863
channel: channel that does not exist                   404  id=app.channel.get.existing.app_error
post: live post                                        200  delete_at=0
post: soft-deleted post                                404  id=app.post.get.app_error
post: post in a public channel I am not in             200  delete_at=0
post: post that does not exist                         404  id=app.post.get.app_error
post: post in a private channel I am not in            200  delete_at=0   (as a system admin)
post: (non-admin) post in a private channel it is not  403  api.context.permissions.app_error
```

The four facts the implementation had to be built around:

1. **`/users/me/teams/{team}/channels/{channel}` is not a route on 9.11.19.** It answers the router's own
   `api.context.404.app_error` even for a channel the account is in, so it cannot be used as a membership
   probe. `GET /channels/{id}/members/me` is the endpoint upstream's `getChannelMember(id, 'me')` uses,
   and it answers 200 / 404 / 403.
2. **"Not a member" is 404 for a system admin and 403 for an ordinary account** — and 403 is also what a
   channel id that does not exist answers. Both are the same answer to a reader: *not in it*.
3. **`GET /channels/{id}` answers 200 for a public channel the account is not in** — reading a public
   channel is allowed, membership is not. So the channel fetch is not a membership test; it only
   distinguishes "still there" (200, including an archived channel with `delete_at != 0`) from "gone"
   (404 `app.channel.get.existing.app_error`).
4. **A soft-deleted post and an id that never existed answer the same 404** `app.post.get.app_error`, so
   the client cannot and need not distinguish them ("The message has not been found." covers both).

## 3. What this client does now

`NotificationWorker.route(userInfo:)` (was: parse `type == mention`, open the channel path) is now:

1. **Local first — no request.** `NotificationTapResolver.localMembership` asks the channel list the
   sidebar has already loaded (`NativeChannelDirectory.membership`, implemented by
   `ChannelSidebarCoordinator`). A row in that list is `.member` and the tap routes exactly as before —
   **the happy path makes no network call**, which is the card's cost rule. Absence is `.unknown`, not
   `.notMember`: the sidebar hides archived channels, so a member of an archived channel is absent, and a
   tap that trusted absence would tell that reader they had left a channel they can still read.
2. **Only then the server** — the pinned client's own pair: `GET /channels/{id}/members/me`, then
   `GET /channels/{id}`. 404/403 → `.notMember` (upstream's channel sentence), 404 on the channel fetch
   → `.gone` (the membership row outlived the channel), 401 → `.sessionExpired` (route: the auth surface
   is the answer), transport failure → `.unreachable` (the Connection sentence), anything else →
   `.unknown` (route as before: a dead end invented by a flaky network is worse than an empty pane).
3. **A thread mention also checks its root** (`root_id`) with `GET /posts/{root_id}` — the one case where
   the post *is* the destination, exactly upstream's CRT path. A plain channel mention that carries a
   `post_id` is **not** probed: its destination is the channel.
4. Otherwise route. The native funnel now carries `postID ?? rootID`, so a thread tap opens the pane at
   the message.

A fallback sets `NotificationWorker.tapFailure`, which `RootView` draws as upstream's alert
(`Alert.alert('Message not found', <sentence>)`) over the channel list the fallback lands on — native:
`NativeNavigation.openHome(serverID:)`; webview: the SPA's server root through the same queue a
cold-launch tap uses. An archived channel is **not** a fallback: it routes, and the pane's composer
banner ("You are viewing an archived channel. New messages cannot be posted.") explains it, as upstream
does.

### Mapping table

| state | probe result | copy | destination |
| --- | --- | --- | --- |
| member, live | list row, or 200 + 200 | — | the channel |
| member, archived | 200 + 200 `delete_at != 0` | — | the channel (pane banner) |
| not a member | 404 / 403 on `/members/me` | "…not a member." | channel list |
| channel gone | 200 then 404 on `/channels/{id}` | "…not a member." | channel list |
| post gone | 404 on `/posts/{root_id}` | "The message has not been found." | channel list |
| post not permitted | 403 on `/posts/{root_id}` | "…not a member." | channel list |
| unreachable | offline / timeout / transport | Connection sentence | channel list |
| session expired | 401 | — (no fallback) | the server's auth surface |
| cannot say | no resolver, no session, 5xx | — | the channel (pre-card behaviour) |

`notTeamMember` exists in the pinned copy and has a case here, but nothing produces it yet: this shell's
taps carry a team id only as a hint, and a team the account is not in is caught by the channel probe
(403) first.

## 4. Files

| file | change |
| --- | --- |
| `Mattermost/Core/NotificationWorker.swift` | `route(userInfo:)` is `async` and returns `NotificationTapOutcome`; the local→remote→post sequence; `tapFailure` / `dismissTapFailure()`; `landOnChannelList`; `postID ?? rootID` into the funnel; `NotificationTapPayload`, `NotificationChannelMembership`, `NotificationPostState`, `NotificationTapFailure`, `NotificationTapOutcome`, `NotificationTapResolving` |
| `Mattermost/UI/Native/Notification/NotificationTapResolver.swift` | new: `SessionNotificationTapResolver` (local list, the two membership probes, the post probe, the status → state table) |
| `Mattermost/Core/Native/NativeNavigation.swift` | `NativeChannelDirectory.membership(serverID:channelID:teamID:)` + default `.unknown` |
| `Mattermost/UI/Native/Sidebar/ChannelSidebarCoordinator.swift` | implements it from the loaded list (positive answers only) |
| `Mattermost/Core/MM/MMEndpoints.swift` | `channelMember(channelID:)`; `post(id:useETag:)` / `channel(id:useETag:)` gain `useETag: false` for probes whose answer *is* the question |
| `Mattermost/Core/MM/MMTypes.swift` | `MMChannelMembership` |
| `Mattermost/UI/RootView.swift` | the alert, over every layout |
| `Mattermost/MattermostApp.swift` | installs the resolver on the worker at bind time |
| `scripts/t14c_notification_tap_probe.py` | new: the measurement above (self-seeding, idempotent) |

## 5. Tests

`MattermostTests/NotificationWorkerTests.swift` (18 new cases) — verbatim copy (all five sentences and
the title), live tap costs no request, left channel, channel gone, deleted thread root, live thread root
carrying the post, no post probe for a channel mention, unreachable, `.unknown` routes as before, no
resolver routes as before, the webview path's root push, unconfigured server, malformed payload, the
resolver's 403/404/200/`delete_at`/post status table over a scripted transport, dismissal.

`MattermostTests/T33-ChannelSidebarTests.swift` (3 new cases) — a loaded row is `.member`; absence and an
unloaded list are `.unknown` (the list cannot prove a negative).

Green: `MattermostTests/NotificationWorkerTests` 45/45, `T33ChannelSidebarTests` 83/83,
`NativeNavigationTests` 38/38 (166 cases, 0 failures).

## 6. Not done here

- **Real APNs / a real Mattermost Push Proxy.** The payload fields (`post_id`, `root_id`) are read in the
  pinned client's shape, but this host has no push entitlement, certificate or proxy, so a *delivered*
  push with those fields was never produced; the unit cases feed the payloads directly.
- **No UI test of the alert itself.** It is a SwiftUI alert on `RootView` driven by a published value;
  the copy and the landing are unit-tested, the presentation is not.
- `notTeamMember` has no producer yet (see §3).
- The full unit target cannot be reported green from this working tree: `MattermostTests/
  Td088ConvertGMToChannelTests.swift` (another card's in-flight file) does not compile
  (`cannot convert 'Dictionary<String, Any>.Keys?' to '[String]?'`, line 270). The three suites above
  were run with that file parked out of the target.

## 7. Re-running

```
docker start mm-perf-db mm-perf            # 9.11.19 fixture on 127.0.0.1:8065
python3 scripts/t14c_notification_tap_probe.py --url http://127.0.0.1:8065 [--json]
xcodebuild -project Mattermost.xcodeproj -scheme Mattermost \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  test -only-testing:MattermostTests/NotificationWorkerTests -only-testing:MattermostTests/T33ChannelSidebarTests
```
