# T52 — channel-info completeness (notification preferences, files, shared channels)

Branch `t52/channel-info-completeness` (worktree `.worktrees/t_8c85e851`), based on `origin/main`
at `da171b4`. Behaviour reference: `mattermost/mattermost-mobile` **v2.45.0**, commit
`162f2560d0e1df073220f7701d5a67cc17c8abeb` — `app/screens/channel_notification_preferences/` and
`app/screens/channel_files/`. Server: the pinned fixture, Mattermost **9.11.19** at
`http://127.0.0.1:8065`.

The card's subject is the gap between what the T40/T51 channel-info screen showed and what the
Mattermost client offers a channel member: per-channel notification preferences, the channel's files,
a shared-with row for group messages, and the pinned row that T39 already built but never linked
from here. The Electron side of this migration is the desktop app's channel menu; nothing here is a
native re-implementation of chat — every row writes through the server's own route.

## 1. What shipped

| Row | Route | Where |
| --- | --- | --- |
| Notification preferences | `PUT /channels/{cid}/members/{uid}/notify_props` (partial body), then `GET …/members/{uid}` | `ChannelNotificationsView.swift`, `ChannelNotifyModels.swift` |
| Files | `POST /teams/{tid}/files/search` with `terms: "in:<channel-name>"` | `ChannelFilesView.swift`, `ChannelFilesModels.swift`, `ChannelFilesViewModel.swift` |
| Pinned messages | existing T39 sheet (`GET /channels/{cid}/pinned`) | `ChannelInfoView.swift` → `PinnedPostsView` |
| Shared with | `GET /channels/{cid}/common_teams`, **only for `type == "G"`** | `ChannelInfoModels.swift` (`ChannelSharedTeamsDerivation`) |
| Bookmarks | — | **not shipped**, see §5 |

Files:

* new `Mattermost/UI/Native/ChannelInfo/ChannelNotifyModels.swift` — `ChannelNotifyDesktopLevel`
  (`default` / `all` / `mention` / `none`), `ChannelNotifyMarkUnread` (`all` / `mention`),
  `ChannelNotifyDraft` (decodes the server's `notify_props`, carries the raw string for a value this
  build does not know, and computes the **partial** body), `ChannelNotifySave` (`changedFields`).
* new `ChannelFilesModels.swift` — `ChannelFileSearchResult` (`file_infos` is a **map keyed by file
  id**, not an array), `ChannelFileInfo` (tolerant: a text file's row has no `width`/`height`), and
  `ChannelFileDerivation.rows` (server order first) / `hasMore`.
* new `ChannelFilesViewModel.swift` — one page at a time, de-duplicated by id, end-of-list from the
  server's cursor.
* new `ChannelNotificationsView.swift` — the form: level picker, "Mute channel" (which is
  `mark_unread == "mention"`), "Ignore @channel, @all and @here", Save, and a "Saved" line fed by the
  server's read-back. Unknown server values are shown verbatim rather than silently coerced.
* new `ChannelFilesView.swift` — the list, its `N files` count line, its empty and failure states, and
  a row that opens **T38's** preview/gallery (one file renderer, not two).
* `ChannelInfoView.swift` — three new rows, the shared-with section, and the two new destinations.
* `ChannelInfoViewModel.swift` — `permissionsAvailable`, `notifyDraft`/`refreshNotifyProps`/
  `saveNotifyProps`, `commonTeams`/`loadCommonTeams`, `makeFilesModel`, and `refreshChannel`.
* `ChannelInfoAPI.swift` / `ChannelInfoService.swift` — the two routes above; `setNotifyProps` is a
  **required** protocol method whose default implementation **throws**, so a fake that does not model
  the write fails loudly instead of producing a green test in which nothing was sent (T40-AV F1's
  failure mode).
* `ChannelView.swift` — passes `navigation`, `imageStore` and `attachmentDownloads` down to the sheet
  (the files rows and the pinned sheet need them).
* `MattermostTests/T52ChannelInfoCompletenessTests.swift` — 23 unit tests.
* `MattermostUITests/T52ChannelInfoUITests.swift` — 3 live tests.
* `docs/t52-build-note.md` — this note.
* `scripts/t52_channel_probe.py`, `scripts/t52_channel_files_probe.py`,
  `scripts/t52_channel_file_count_probe.py` — the server-contract probes §2 is measured with.
* `MattermostTests/T40ChannelInfoTests.swift` — the expected `offeredActions` lists gained the three
  new rows. Nothing else in T40 changed.

## 2. The server contract, measured (not assumed)

Probes: `scripts/t52_channel_probe.py`, `scripts/t52_channel_files_probe.py`,
`scripts/t52_channel_file_count_probe.py` — run against the fixture, output below is from those runs.

1. **`notify_props` is a partial update.** `PUT …/notify_props` with `{"desktop":"mention"}` leaves
   `mark_unread` and `ignore_channel_mentions` untouched; the answer is `{"status":"OK"}`, which is
   not proof of the stored value, so the screen re-reads the membership. `mark_unread: "mention"` is
   Mattermost's whole definition of a muted channel, so the mute switch is that one field.
2. **There is no `GET /channels/{id}/files`** (404, measured), and `channel_id:<id>` is not an
   operator this server's file search understands (200, no files). `in:<channel-name>` is, and it
   agrees exactly with the file ids in the channel's posts: 16/16 for `t38-files` and 40/40 for
   `t38-av-heavy`.
3. **`stats.files_count` is not the list's count.** `t38-files` answers
   `stats.files_count = 48` while `files/search` answers 16 distinct files — the stats field counts
   files the channel's message list cannot show (files whose posts were deleted, and file uploads not
   attached to a visible post). The screen therefore never prints `files_count`; its count line is the
   number of rows the server's search answered. This is exactly the kind of "two numbers that look
   like the same number" mismatch that T40-AV was carded to catch.
4. **The search's answer is map-shaped and ordered.** `file_infos` is a dictionary keyed by file id,
   `order` is the server's own ordering, `next_file_info_id` is the cursor. A text file's info has no
   `width`/`height`/`mime_type`, which is why `MMFileInfo` cannot be used to decode it.
5. **`common_teams` is a group-message route.** On a `G` channel it answers 200 with the shared team
   objects (this single-team fixture: the one team both members are in). On every other type —
   measured over 300+ open channels — it answers
   `400 app.channel.get_common_teams.incorrect_channel_type`, "Channel is not a group message."
   The client therefore asks only for `G`, and a failure is "no row", never a blank row.
6. **A direct or group message cannot be named by the files route.** A GM's `name` is an opaque hash
   and its `team_id` is empty, so `in:<name>` cannot target it (`t52_gm_files_probe.py`: a GM with one
   file answers zero). The files row is withheld for `D`/`G` rather than drawing an empty list that
   says "no files" about a conversation that has them.
7. **The channel's newest post is a system message.** `POST /posts/{id}/pin` answers
   `400 api.post.update_post.system_message.app_error` for it; a regular post pins with 200 and appears
   in `GET /channels/{id}/pinned`. The live test creates its own regular post for this reason.

## 3. Decisions

* **One ordered action list.** `ChannelInfoCapabilities.offeredActions` stays the single list the
  screen draws from, so "a user with no channel permissions is offered nothing" stays an exhaustive
  assertion instead of a per-row memory exercise. The three new rows are inserted at the position the
  screen draws them: after Members, before Settings.
* **The new rows are not permission-gated reads.** Every channel member may set their own
  notification preferences and read the channel's files/pins; the server enforces `read_channel`,
  which the screen can only be on at all if the account has it. `.files` is withheld for `D`/`G`
  (measurement 6), and `.pinned`/`.notifications` are offered everywhere.
* **`permissionsAvailable == false` renders the screen read-only with a note** instead of hiding it —
  a permissions lookup that failed is not evidence that the member has nothing.
* **Save sends only what changed, then trusts the read-back.** `changedFields(comparedTo:)` compares
  against the server's own values captured when the form opened; after a 200 the screen re-reads the
  membership and resets its baseline to that answer. A value the build does not know is never sent
  back untouched — only a field the reader actually changed travels.
* **Files reuse T38's screens.** A row is a `PostAttachment`; tapping an image opens T38's gallery,
  anything else T38's single-file preview. No second file renderer.
* **The shared-with row is drawn from the server.** `ChannelSharedTeamsDerivation` takes the server's
  team objects, drops deleted and blank ones, de-duplicates and joins the display names. The client
  does not guess "Connected Workspaces" from a channel type.
* **Pinned reuses T39's sheet.** The row presents `PinnedPostsView` (already built and tested); no new
  pinned list was written.

## 4. Tests

Unit — `MattermostTests/T52ChannelInfoCompletenessTests.swift`, **23** tests, no network, no clock:

```
python3 scripts/qa-test.py --platform ios --sim "id=81A7F251-8B31-4945-8783-5A264C14B8D5" \
  --derived-data ~/Library/Developer/Xcode/DerivedData/mmios-t52 \
  --only-testing MattermostTests/T52ChannelInfoCompletenessTests -- -parallel-testing-enabled NO
```

Result: `tests: 23 run, 0 skipped, 0 failed` (run `t52-units5`, 55 s).

They cover: the server's level vocabulary verbatim; a draft that reads the server's values and sends
**only** changed fields; an unknown level shown as the server sent it and never echoed back; mute
being `mark_unread == "mention"`; the row's subtitle; file rows in the server's `order`; files the
order array forgot appended newest-first; a text file without `mime_type` decoded (not dropped); an
unreadable file info dropped rather than drawn blank; `hasMore` from the cursor (empty, repeated, and
not-in-page); `D`/`G` withholding the files row; a files model built from the **channel's** team when
the model was created without one; the shared-team name derivation; and the view model's save path —
partial body, server read-back adopted, and a refused save when the preferences could not be read.

Live — `MattermostUITests/T52ChannelInfoUITests.swift`, 3 tests, against the fixture:

```
python3 ~/.hermes/profiles/mmios-ios/cache/scratch/t52_live_run.py \
  "MattermostUITests/T52ChannelInfoUITests" t52-live
```

The launcher reads the fixture password from `scripts/perf_seed.py` and hands it to `qa-test.py`
through the environment only; no password appears in a command line, a log, or this note.

Result: **`tests: 3 run, 0 skipped, 0 failed`** (run `t52-live-r5`, 204 s):

1. `testANotificationLevelIsWrittenAndSurvivesARelaunch` — set `Mentions and keywords`, Save, then the
   **server's** membership answers `desktop == "mention"` with `mark_unread` unchanged; relaunch
   without resetting state and the info row still says the level (the relaunch restores the channel as
   a pushed pane, and the sheet is opened from it).
2. `testThePinnedRowOpensTheChannelsPinnedSheet` — pin a regular post through the API, open the row,
   and the sheet lists `pinnedPosts.row.<postID>`.
3. `testTheFilesListMatchesTheServersFilesForThisChannel` — the oracle is `files/search` for the same
   channel; the count line equals it and the server's file ids appear as rows.

Each test creates its own channel, posts one file to it and deletes the channel in `tearDown`, so a
run leaves the fixture as it found it (checked with `t52_leftovers_probe.py` after the passing run: one
channel was left by an earlier **killed** run, deleted by `t52_cleanup.py`; the passing run left none).

Full unit bundle, to prove nothing else moved:

```
--only-testing MattermostTests   →  tests: 2050 run, 8 skipped, 0 failed   (run t52-allunits2, 94 s)
```

## 5. Not shipped: channel bookmarks

Measured on the fixture: `GET /config` answers `FeatureFlags.ChannelBookmarks = false`, and every
`/channels/{id}/bookmarks` route answers **404** `api.context.404.app_error` — the feature does not
exist in this server build (`scripts/t52_channel_probe.py` §bookmarks,
`~/.hermes/profiles/mmios-ios/cache/scratch/t52_bookmark_flag.py`). The card allows the split, so the
bookmark half is carded separately rather than written blind against a route the fixture refuses: a
row that can only ever answer "not found" is not a completeness row. The card is **t_1da9ddc4** and
opens with the three measured lines above.

## 6. Defects found and fixed in this card

* **A `Codable` wire type that cannot encode.** `ChannelFileSearchResult` synthesized `Encodable`
  only if `ChannelFileInfo` were `Encodable`; it is decode-only by design. The build failed, the type
  is now `Decodable`.
* **`Self.notifyProps` in a stored-property initializer** — covariant `Self` is not allowed there;
  the fake names the type.
* **A test expectation that assumed the wrong tiebreak.** Two files created in the same second are
  ordered by name, not by insertion; the expectation, not the code, was wrong.
* **`_ = stats`** — an earlier edit discarded the stats fetch; restored with the generation guard
  intact, so a stale response still cannot overwrite a newer channel.
* **`loadMore` compared its cursor after assigning it**, which made `hasMore` always false. Fixed to
  compare before the assignment.
* **The sidebar's scroll container is a `ScrollView`, not a collection view** (T52-R1). The live suite's
  reveal helper asked `app.collectionViews.firstMatch`, matched nothing, and returned without scrolling
  — so the test failed looking for a row 25 screens down while never scrolling once. Measured from the
  accessibility tree: `channelSidebar.scroll`. The tests also stopped navigating to a channel seeded by
  an earlier suite: the account is in **358** channels on this team, and each test now creates its own
  channel whose name starts with `0`, which sorts it to the top.
* **A relaunch does not put `nativeShell` in the tree** (T52-R2/R3). The relaunch test asserted that
  anchor and failed on the configuration it had just created: a launch without
  `-uiTestResetPersistedState` restores the last channel as a **pushed pane** (`nativeChannelPane`,
  no tab bar). Fixed by using `ShellSettle.waitForSignedIn`, then opening the sheet from the restored
  pane.
* **`Optional("…")` in a URL** (T52-R1). String interpolation of an implicitly-unwrapped `String!`
  renders `Optional("jruqq…")`, so `PUT …/members/Optional("…")/notify_props` answered 404.
* **The files screen pushed before its model existed** (T52-R3). `ChannelFilesView` created its model
  in `.task` and the destination pushed regardless; when creation failed the screen sat on a spinner
  forever, indistinguishable from a slow page and with no request sent. The row now builds the model
  from its own tap, the push happens only when it exists, and a failure says so in the banner. The
  model's team now comes from the **channel** (`channel.teamId`) when the view model was created
  without one — the old guard read the view model's `teamID`, which is empty until the channel is read.
* **The files count line is uppercased by the grouped-list header styling** (T52-R4). The list said
  `1 FILE` while the test asked for a `StaticText` labelled `1 file`; comparing the element's own label
  case-insensitively is what the assertion meant.

## 7. One flake seen, outside this card

The first full unit-bundle run (`--only-testing MattermostTests`, run `t52-allunits`, 2049 tests) had
one failure: `T46WebFallbackTests/testTwentyFallbacksLeaveNoWebViewAlive` (`1 of 20 fallback webviews
are still alive after teardown`). It passes alone, and the next full run (`t52-allunits2`, **2050**
tests — one more than the first because of the extra T52 test added in between) was **0 failed**. It is
a teardown-timing test in the T46 fallback suite, not touched by this card. Reported rather than
silently averaged away.

## 8. Publish

Committed on `t52/channel-info-completeness` (worktree `.worktrees/t_8c85e851`) from `origin/main`
`7067353` and pushed to `main`; `git ls-remote origin refs/heads/main` was asserted equal to local
`HEAD` after the push. Staged by pathspec: the 11 ChannelInfo/Channel sources, the T40 expectation
update, the two new test files, this note, and the three probes — nothing outside T52's paths.

`scripts/__pycache__/` (a probe artefact) was left untracked and unstaged.
