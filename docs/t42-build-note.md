# T42 — native Recent Mentions (S25)

Surface: upstream's **Mentions** tab (`app/screens/home/recent_mentions/`), ported as a native
SwiftUI pane inside the shell. Gated by `-surfaceMode activity=native`; with the flag off the pane
says so instead of drawing a screen the dual-render switch called web.

## 1. What is on screen

`Mattermost/UI/Native/Activity/` — six files, one of which does no I/O:

| File | What it is |
| --- | --- |
| `ActivityModels.swift` | **Pure.** `ActivityProfile` (the `GET /users/me` decode that carries `notify_props`), `MentionKeys` (upstream's key derivation + whole-token matching), `ActivityChannelCursor`, `ActivityThreadUnread`, `ActivityRow`, `ActivityDerivation` (rows, order, read state, filter, subtitle/empty copy, the live-mention predicate, insertion, the markable channel ids). |
| `ActivityAPI.swift` | The four requests this surface needed and no earlier card had: `POST /posts/search` as the mentions window, `GET /users/me` into `ActivityProfile`, `GET /users/{me}/teams/{team}/channels/members`, `POST /channels/members/{me}/mark_read`. Everything else reuses an existing endpoint (`APIClient.users(ids:)`, `channel(id:)`, `channelMember(channelID:userID:)`, `teamUnreads()`, `userThreads(unreadOnly:)`, `markThreadRead(teamID:threadID:timestamp:)`). |
| `ActivityService.swift` | The `ActivityServing` seam + the session-backed implementation. |
| `MentionsViewModel.swift` | Load (reader keys → window → channel/author context → read cursors → rows), the filter, `markRead`/`markAllRead`, the badge hand-off, and the socket handler. |
| `ActivityCoordinator.swift` | One model per **server** (the window is cross-team by definition), the rail's socket fan-in, `authPhaseChanged` (sign-out/expiry drops the window), and the one badge closure. |
| `MentionsView.swift` | `MentionsPaneContent` (flag gate), the header (title, counter line, refresh, mark-all-read), the All/Unread filter, the list, the row (channel line, unread dot, thread marker, "New" marker, then the timeline's own `PostRowView`), empty/failure/loading states, and a write-failure banner. |

Host wiring: `NativeTab.activity` (title "Mentions", `bell.badge`) in
`Core/Native/NativeNavigation.swift`; the tab in `NativeShellView`'s compact layout and the
`shellActivityButton` toolbar sheet in the split layout (a Catalyst window is wide enough for the
split layout, and a screen that exists but cannot be reached is not ported); `ActivityCoordinator`
owned by `MattermostApp`, bound in `bindShellStores()`, fed from `TeamSidebarCoordinator.onTeamEvent`
and dropped on `authPhaseChanged`.

## 2. Measured facts this is built on

`scripts/t42_activity_probe.py` against the pinned server (Mattermost **9.11.19**, build 16643067630,
`ActiveSearchBackend: database`) — transcript in `docs/t42-activity-probe-2026-10-27.log`, **40 checks,
every expectation held, exit 0**:

1. **There is no mentions endpoint.** `GET /users/me/mentions` (the path this card named) is a 404, and
   so is `/teams//posts/search` — the empty team segment does not survive the router. The cross-team
   search is `POST /posts/search` with **no** team in the path, which is why upstream's
   `fetchRecentMentions` branches on `teamId`.
2. **One window.** `has_next` is false and `page: 1` answers an empty `order` on the database backend.
   The model therefore tries page 1 only when the server says there is one, and an empty page ends the
   loop — a "load more" that trusted `page` would silently stop.
3. **No `props.mentions`.** A post that incremented the mention counter carries `"props": {}`, so the
   client's own key match is the shipping path for a live socket mention, not a fallback for a rare
   shape. (`isLiveMention` still prefers `props.mentions` when a server sends it.)
4. **`last_viewed_at` is the cursor** and `0` means "never read on this account" (the server's own
   `mention_count > 0` with `last_viewed_at: 0` after a fresh membership). A row is unread when
   `post.create_at > last_viewed_at`.
5. **A reply's read state is not the channel's.** Marking the channel read left the seeded thread's
   `unread_mentions` at 1; only `PUT /users/me/teams/{t}/threads/{id}/read/{ts}` cleared it. So a reply
   row's dot comes from `GET …/threads?unread=true`, and its swipe action is "Mark thread read".
6. **`POST /channels/members/{me}/mark_read` takes a bare array.** The wrapped body
   `{"channel_ids": [...]}` is a 400; the answer is `{status: "OK", last_viewed_at_times: {...}}` — note
   the **uppercase** `"OK"`, which the Swift model keeps as an opaque string and never branches on.
7. **Live.** A mention posted by another account reaches my socket as `posted` with the post as a JSON
   **string** in `data.post`; a read performed by another session of my account reaches it as
   `multiple_channels_viewed` with `channel_times`. Both are what the feed applies.
8. **The badge has one arithmetic.** `SessionStore.serverBadgeInput(mentionCounts:messageCounts:)` is
   now the only place per-team counters become `(mentions, isUnread)`; `MentionPoller` (T35) was changed
   to call it through `applyServerCounters` instead of summing inline, and the feed calls the same one.
   Two callers, one badge.

## 3. Units

**46 T42 tests, 0 failures** (`build/logs/t42-units2.log`, `** TEST SUCCEEDED **`), and the whole
Catalyst unit bundle with them: **1,425 run / 4 skipped / 0 failures**
(`build/logs/t42-units3.log`, `** TEST SUCCEEDED **`) — the 1,379 of T41 plus these 46:

* `MattermostTests/T42ActivityTests.swift` (42) — keys (upstream order, the first-name flag and its
  case-sensitivity, the broadcast keys being excluded from the search terms and from matching),
  whole-token matching (`@perfprobe` vs `@perfprobex` vs `foo@perfprobe`), `isLiveMention` (own post,
  deleted, `props.mentions` winning, the empty-props shipping path), derivation (order and the id
  tiebreak, labels and teams, unresolved channels, cursor/thread read state, the filter, subtitle and
  empty copy, deduplicated markable channels, live insertion replacing itself), the view model against a
  fake service (one search with upstream's terms, one channel read + one batched author read, the DM
  cursor fallback, mark-root-read vs mark-reply-read, mark-all-read sending one request and clearing
  reply rows too, a failed write leaving the row unread with copy, a failed load, the filter switching
  with no request, live insert without a refetch, non-mentions and own posts ignored, a delete leaving
  the list, a read elsewhere being followed, a rename relabelling rows), and the badge seam
  (`serverBadgeInput` + `applyServerCounters` through a real `SessionStore`).
* `MattermostTests/T42ActivityAPITests.swift` (4) — at the transport seam: the search is a POST to
  `/api/v4/posts/search` with no team, `is_or_search: true` and the keys as `terms`; `GET /users/me`
  carries `notify_props` as strings and derives the keys; mark-read posts a **bare array** and decodes
  `{status: "OK", last_viewed_at_times}`; the team read-cursor list is one paged request.

## 4. Live verification

`MattermostUITests/T42ActivityUITests` — **4 run / 0 skipped / 0 failed** against the real server at
`127.0.0.1:8065` (iPhone 15 Pro, iOS 17.0.1, `build/logs/t42-ui-4.log`,
`xcresult t42-ui-4-94a10c`):

| Test | Oracle |
| --- | --- |
| `testTheMentionsTabListsMyMentionsFromTheServer` | the seeded mention's row exists and reads **unread**; a post that names nobody is **not** a row |
| `testMarkAllReadClearsTheDotsAndReachesTheServer` | the row is unread before; after tapping mark-all-read the server's `mention_count` for the channel is 0 **and** the row's label flips to "read" |
| `testAMentionArrivesWhileTheFeedIsOpen` | a mention posted by the buddy *after* the feed loaded appears with no tap and no refresh — only the socket can do that |
| `testTappingARowOpensItsChannel` | tapping a row opens its channel (`nativeChannelTitle`) |

Each test seeds its own fresh mentions through a second account (`t42buddy`), so test order cannot make
one pass or fail by accident. **A finding worth keeping**: posting in a channel moves the *author's*
read cursor to that post, so a control post authored by me reads my own earlier mention back to "read" —
the first run's `unread` assertion was measuring nothing until the control post was authored by the
buddy (`docs/t42-build-note.md` §5 F1).

Fixtures: `scripts/t42_activity_seed.py` (the `t42-activity` channel, the `t42buddy` account, four fresh
mentions — three roots and one thread reply — and one post that names nobody, left unread) and
`scripts/t42_activity_probe.py` (§2's transcript).

Screenshots: `docs/t42-shots/` (four PNGs exported from that run's own attachments, not mocked):
`t42-mentions-list.png`, `t42-mentions-marked-read.png`, `t42-mentions-live.png`,
`t42-mentions-opened-channel.png`.

## 5. Findings

* **F1 — a post moves the author's cursor.** `POST /posts` sets the author's channel `last_viewed_at` to
  that post, so anything authored by me counts as read for me. The UI test's control post had to move to
  the buddy account; the assertions were otherwise vacuous. This is server behaviour, not a client rule,
  and the feed's `post.create_at > last_viewed_at` test inherits it correctly (a post I wrote is read).
* **F2 — the card's route does not exist.** `GET /users/me/mentions` is a 404 on this server, so the
  window is the cross-team search. Recorded in `ActivityAPI.swift`'s header and §2.1.
* **F3 — `status` is uppercase `"OK"`.** A client comparing it to `"ok"` would treat every read as a
  failure. The Swift type keeps it opaque; the API test pins the real spelling.
* **F4 — a second spelling of a request would be a second behaviour.** Four endpoints already existed
  (`users(ids:)`, `channel(id:)`, `channelMember(...)`, `teamUnreads()`, `userThreads`, `markThreadRead`);
  the first draft of `ActivityAPI.swift` re-declared three of them and the compiler refused
  ("invalid redeclaration of `channelMember`"). The file now adds only what is genuinely new and points
  at the existing spelling for the rest.
* **F5 — a `where` on the second pattern of a `case` applies only to that pattern.** `case .idle,
  .loading where loadedCount == 0` drew an idle pane as empty instead of loading (the compiler warns);
  the content switch is now one case per phase with a shared `loading`/`rowsOrEmpty`.
* **F6 — the row identifier must be on one element.** A `.accessibilityIdentifier` on the ForEach
  content overrides the one on the row's inner `Button`, so the first UI run looked for
  `activity.rowButton.<id>` and found nothing while the identifier it wanted was `activity.row.<id>`.
  The inner identifier was removed rather than kept as dead weight.

## 6. Limits that stay

* The window is the server's **one** search window (60 by default, up to three pages when a server says
  `has_next`). A database-backed server answers one window per query and does not page, so a very busy
  account sees the newest 60 mentions and no "load more".
* Read state is per **channel** for a root post — Mattermost has no "read up to this post" route, so the
  root row's action marks the whole channel read (the swipe label says exactly that). A reply is read by
  its thread, which is precise.
* No in-app notification toast / snackbar (upstream's `in_app_notification`): this is the inbox, not the
  notification surface. Push notifications remain T14's worker.
* No "clear all"/"jump to first unread" controls, no saved-search of mentions, no per-channel mute from
  the row.
* Nothing here is available offline: a load without a session or network fails with copy and a retry.
* The feed is live while it exists: it is created when the pane is first shown and dropped on sign-out.
  A mention that arrives while the app is on another tab still lands (the coordinator subscribes to the
  socket, not the view), but a mention that arrives while the app is suspended is picked up on the next
  load.
