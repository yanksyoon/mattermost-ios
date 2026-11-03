# T48-AV — adversarial validation of the post options menu

Subject: T48, commit `00cd217` ("feat(posts): the post options menu offers what v2.45.0 offers"),
validated at `HEAD = 4cd5bdc`, published on top of `d4aadac` — the post-options sources are
byte-identical between the two (`git diff --stat 4cd5bdc..d4aadac` touches only T47's create-channel
files, so every count below still describes the tree this note lands on).
Card: `t_531f894e`. Fixture: Mattermost **9.11.19** on `127.0.0.1:8065` (container `mm-perf`).
This pass exists because T47 and T48 were closed on their build notes without one.

**Verdict: FAIL — repairable, no revert.** The writes the menu performs are real: mark-unread, save,
pin/unpin, edit and delete all landed on 9.11.19 and the server's record matched, and the pin fallback
and unsave patch are load-bearing tests (two mutations, both caught). None of the defects is in a write:
the menu does not exist on the lookup rows at all (F1), the socket decoder drops every preference frame
the server publishes (F2 — the root cause of the note's "known gap"), and the follow row can never
offer Unfollow Message because 9.11.19 publishes no follow flag anywhere (F3). Two documented gates are
not implemented (F4, F5), and the shipped live suite does not reproduce (F6). F1 is repairable: five
repair cards are filed from this pass (R1–R5), and the existing `t_fddfb0d5` now carries the measured
diagnosis of its gap. The scoreboard against the note: **one claim reproduced end to end** (the
23-test unit suite), **one live test reproduced** (Copy Link, on a clean device), **five live tests
not reproduced**, and **five claims that do not hold**.

## What this pass ran

| Run | Command | Result | Artifact |
|---|---|---|---|
| T48 units (23 tests) | `scripts/qa-test.py --platform ios --sim id=81A7F251-… --only-testing MattermostTests/T48PostOptionsTests` | **23 run / 0 skipped / 0 failed** — the note's count reproduces | `build/logs/t48av-units.log` |
| Server record probe | `uv run --with websockets python3 scripts/t48_av_probe.py` | every row's write measured against the server (table below) | `build/logs/t48av-probe.log` |
| Shipped live suite (run 1) | `TEST_RUNNER_MM_AUTH_*… --only-testing MattermostUITests/T48PostOptionsUITests` | **5 run / 0 skipped / 8 failures**, 491.8 s — host was wedged (see §F6) | `build/logs/t48av-live-shipped.log` |
| Shipped live suite, single test (clean device) | `…/testTheMenuOffersTheMissingOptionsAndCopyLinkIsTheServersPermalink` | **1 run / 2 failures**, 251.8 s — Copy Link green with the exact server URL, Copy Text red | `build/logs/t48av-live-smoke.log` |
| AV unit suite, strict | `‑‑only-testing MattermostTests/T48PostOptionsAVTests`, `expectKnownDefect` made a no-op, `--platform mac` | **6 run / 8 failures / 0 unexpected**, `** TEST FAILED **` — the three defect tests red (3+3+2 assertions), the three premise tests green | `build/logs/t48av-mac-units-strict2.log` |
| AV unit suite, as committed | same, marker in place | **6 run / 0 failures / 0 unexpected**, `** TEST SUCCEEDED **` | `build/logs/t48av-mac-units-final.log` |
| Mutation A | `PostOptionsGate.canPin` → `return true` | **23 run / 2 failures** (`testAnUnknownPermissionLookupWithholdsPin`, `testOnARealServerTheFallbackIsTheChannelsWritePermission`) | `build/logs/t48av-mutation-a.log` |
| Mutation B | `SavedPostDerivation.updated` ignores `deleted` | **23 run / 2 failures** (`testSavedStateAppliesOnlyTheFlaggedCategory`, `testTheOfferedListComesFromTheStoreAndTheLoadedState`) | `build/logs/t48av-mutation-b.log` |
| AV UI suite compile | `xcodebuild build-for-testing -destination 'platform=iOS Simulator,id=81A7F251-…'` | **`** TEST BUILD SUCCEEDED **`** — the file builds, it just never ran (see §Not measured) | `build/logs/t48av-compile-ui.log` |

The three unit rows after the live ones ran on **Mac Catalyst** (`--platform mac`), not the simulator: at
that point the host carried five to seven concurrent `xcodebuild test` processes (load average 468–965)
and the simulator `installApplication` step wedged twice, once past 20 minutes. The source under test is
identical and the Catalyst target compiles the same `Mattermost` module; the iOS simulator unit run
(the T48 23-test row) was measured earlier on a quiet host and is quoted from that run.

The live UI runs need `TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065`,
`TEST_RUNNER_MM_AUTH_LOGIN=perfprobe`, `TEST_RUNNER_MM_AUTH_PASSWORD=…` (fixture accounts in
`scripts/perf_seed.py` / `scripts/t36_thread_seed.py`) plus
`-- -clonedSourcePackagesDirPath …/mattermost-ios-qa/SourcePackages` (a fresh resolve hangs on
GRDB's SQLiteLib submodule).

## §1 Per-option verdicts

"Server record" is what `scripts/t48_av_probe.py` measured on 9.11.19 — not what the note claims.

| Option | Note's gate | Gate in the code | Server record (measured) | Verdict |
|---|---|---|---|---|
| Reply | `canReply`: channel not archived, post not deleted | `ComposerRowPermissions.menu` + `composerIsNative`; **no archived term**; host closure, no request | n/a (no write) | **PASS (write)** / gate over-offers in an archived channel (§F5) |
| Follow / Unfollow Message | the root has replies; flag on the root post's `is_following` | `replyCount > 0` **and** `threadFollowing != nil`; state = `row.post.isFollowing`, always `false` | `PUT …/threads/{root}/following` → 200 and the thread appears in `GET /users/me/teams/{team}/threads`; **no `is_following` key anywhere** (channel page row, `GET /posts/{id}`, thread endpoint, threads list) | **FAIL — F3** |
| Mark Unread | not my own post, not archived | `readable && !archived && (viewer != author \|\| webhook)` | `POST /users/{uid}/posts/{pid}/set_unread` → **200 answering the membership row**; `msg_count` 839 = the answer's 839; `last_viewed_at` 1793673932899 < `create_at` …900 → unread | **PASS** |
| Copy Link | the team's URL name is known | `offersCopyLink = readable && teamName non-empty`; the link is `{server}/{team}/pl/{post}` | `/perf/pl/<post>` **and** `/ops/pl/<post>` both answer `200 text/html` with the same 3,471 bytes — the server cannot tell a right link from a wrong one, so the client's string is the only claim | **PASS on the string, with F4** (the route's *name* survives a failed channel-team name read) |
| Copy Text | link + non-empty message | same + non-empty message | n/a (pasteboard) | **PASS (unit)** / live copy-text red in the only clean run (§F6) |
| Save / Remove | always | `readable` | `PUT /users/{uid}/preferences` → server holds `flagged_post`; frame: `preferences_changed` with `data.preferences` as a **JSON string**; unsave → `preferences_deleted`, same shape | **write PASS, live update FAIL — F2** |
| Pin / Unpin | `pin_post`/`unpin_post`/`create_post`, not archived | `PostOptionsGate.canPin` (ids, else `create_post`) | 271 permission ids for this admin union: `pin_post` **absent**, `unpin_post` **absent**, `create_post` present, **no id contains "pin"**; `POST /posts/{id}/pin` as another author → **200**, unpin → 200 | **PASS** (see §F5 for the sentence this does *not* reproduce) |
| Edit | my own, `edit_post`, not archived | **ownership only** — `ComposerRowPermissions.menu`; no permission id, no archived term; the sheet dismisses before the write | `PUT /posts/{id}/patch` as the author → 200, `edit_at` set | **FAIL — F5** (over-offer, refusal cannot be drawn) |
| Delete | my own, `delete_post`, not archived | **ownership only**, as Edit | `DELETE /posts/{id}` as the author → 200, then `GET` → 404; `POST /posts/{id}/pin` afterwards → **403** "You do not have the appropriate permissions." | **FAIL — F5** |
| Refused write | sheet stays open, reason inline | `perform` returns `.failed`; the sheet sets `postOptions.error` and does not dismiss | the 403 above is the refusal the live UI test forces | **PASS (unit)** / live assertion written, see §F6 |

### The pin gate, exactly as measured

The note's third bullet says "9.11.19's own `POST /posts/{id}/pin` refuses without a post-write role".
That sentence is **not reproduced** by this pass: an account made a channel member and then stripped
of its channel roles (`roles: ""`, verified by reading the member row back) **pinned successfully
(200)**, because `create_post` reaches it through `system_user`, not through the channel membership.
The endpoint checks the permission union; a channel-member role is not the unit that decides it. What
*is* reproduced is that the ids the note names do not exist (0 of 271, and no id contains "pin"), that
`create_post` does, and that the endpoint refuses a caller without the permission (403 for an account
with no membership at all). Whatever account the T48 worker used to measure the 403, the note should
say which one; as written it invites the reading that channel roles decide pinning.

## §F1 The lookup rows offer no post-options menu (repairable, not revert)

The note's first sentence is "The menu on a post row … now offers what Mattermost Mobile v2.45.0
offers". The sheet is mounted in the channel pane and the thread pane only. `PostRowView` builds no
ellipsis at all without `actions:` (`PostRowView.swift:258`), and three other hosts draw the same row
without them:

* `Mattermost/UI/Native/Search/SearchView.swift:451` — search results.
* `Mattermost/UI/Native/Activity/MentionsView.swift:379` — the mentions inbox.
* `Mattermost/UI/Native/Search/SavedPinnedViews.swift:254` — saved and pinned — **not** named by the
  ship-shaped QA card, found here by reading every `PostRowView(` call site.

The live reproducer is another card's and it is Release, no flags, both layouts:
`docs/t636e6483-ship-shaped-qa.md` §F1 — `post.<id>.menu is not in the tree` on a search-result and on
a mention row (`build/logs/t636e6483-iphone-release7.log`, `…ipad-release2.log`). I did not re-run that
suite (a Release build costs ~20 min on this host, and the call sites settle the cause); this pass's
contribution is the third row family and the judgement: **repairable**. A lookup row spans channels,
so the repair is a presenter keyed by the tapped row that reuses
`ChannelPaneCoordinator.postOptions(for:channelID:)`, not a one-line threading of closures.
Card **t_29925e81 (R1)**.

## §F2 The socket decoder drops every preference frame — the real cause of the "known gap"

`SocketEvent.init(frame:)` (`Mattermost/Core/MM/SocketEvent.swift:418-426`) reads
`frame.data?["preferences"]?.arrayValue` and returns `nil` when that is not an array. On 9.11.19 the
payload is a **string**:

```
[save]  {"event":"preferences_changed","preferences_type":"str",
         "raw_sample":"[{\"user_id\":\"jruqq…\",\"category\":\"flagged_post\",
                        \"name\":\"4nmfh6s7678fjjuekw8ykhb43c\",\"value\":\"true\"}]"}
[unsave]{"event":"preferences_deleted","preferences_type":"str", … same string …}
```

So the frame is dropped before any model sees it. That is exactly the asymmetry the note records: the
pin hop lands because `post_edited` carries an object, the save hop does not because its frame never
decodes. The unit test that covers this path (`SocketClientTests.swift:532`) pushes an *array* in
`data`, so it passes while the wire shape differs — the fixture, not the server, is what it measures.
The Saved screen (T39) and the sidebar's preference consumers sit behind the same two cases and are
equally dead against a live server. The repair belongs to **t_fddfb0d5** (already open); its card now
carries this measurement and the fix shape (accept both spellings, test the string form).

AV unit evidence that the model half is fine: `testTheModelFlipsSaveToUnsaveOnAPreferencesFrame` and
`testTheModelFlipsPinToUnpinOnAPostEditedFrame` pass — applying the frame by hand flips the row. The
defect is upstream of the model, as the note suspected, one layer further up than it guessed.

## §F3 The menu can never offer Unfollow Message

The note says the flag lives on the root post of the channel page. It lives nowhere: after a 200
follow, `is_following` is absent from the channel page's root row, from `GET /posts/{id}`, from
`GET /users/me/teams/{team}/threads/{root}` (keys: `delete_at, id, is_urgent, last_reply_at,
last_viewed_at, participants, post, reply_count, unread_mentions, unread_replies`) and from every row
of `GET /users/me/teams/{team}/threads`. The only server-side signal is that the thread **appears in
that list** only while followed (`found: false` before the follow, `true` after, `false` after the
unfollow — `[follow_write]` in the probe log).

Consequence: `row.post.isFollowing` decodes to its default `false` forever, so `threadFollowing` is
always `false` and the sheet always offers **Follow Thread**. The flip to Unfollow exists only in
memory (`followStates`, set by this device's write or by `thread_follow_changed`), so it is lost on
relaunch. Card **t_b28e8cfc (R3)**.

## §F4 Copy Link can still name the route's team

The `team_id` half of the fix is real: `activate` reads `GET /channels/{id}` and the role union follows
the channel's team (unit test `testTheChannelsOwnTeamNamesThePermalinkNotTheRoutesTeam` passes, and the
AV copy of it, `testTheChannelsOwnTeamNamesThePermalinkWhenTheRouteCarriedAnotherTeam`, passes too).
The **name** half is not: `activate` seeds `teamName` from the route's supplied name on its first line,
and when the channel-team name read throws, the `else if … teamName == nil` fallback cannot correct it
(`PostOptionsViewModel.swift:159-180`) — a permalink is then built as `/{route}/pl/{post}`.

Reproduced deterministically in `testAFailedTeamNameReadMustNotLeaveTheRoutesTeamInThePermalink`
(FakeService: the channel's team answers, its name read throws): `teamName == "ops"`,
`perform(.copyLink)` → `http://127.0.0.1:8065/ops/pl/<post>`. Card **t_9acf2b1c (R2)**.

The live cross-team scenario was **not** rebuilt: the shell's quick switcher is team-scoped
(`ChannelSidebarViewModel.searchResults` over the loaded team), so from a route team of `ops` there is
no way to open a `perf` channel in the shipped UI without a deep link, and a permalink deep link names
the team the URL names (`NativeNavigation.target(forPath:)`), i.e. it is consistent by construction.
What the live suite does assert is the exact string for the fixture channel (`/perf/pl/<post>`), and
that assertion passed in this pass's clean run.

## §F5 Edit and Delete: documented gates that do not exist

The note's table gates Edit on `edit_post` and Delete on `delete_post`, both "channel not archived".
`ComposerRowPermissions.menu` (`ComposerModels.swift:526-536`) answers ownership only —
`(reply: true, edit: mine, delete: mine)` — and `PostOptionsCapabilities.derive` copies `canEdit` /
`canDelete` into the list with no `isArchived` term (`PostOptionsModels.swift:242-243`). So:

* an archived channel still offers Edit, Delete (and Reply) on my own post — the note's "an archived
  channel offers no writes" holds for pin, mark-unread and follow only;
* an account whose `edit_post`/`delete_post` was revoked still sees both rows. The sheet dismisses on
  press before the host closure runs, so a refusal cannot be drawn inline — the very thing the note
  forbids for the other rows.

Two AV unit tests record it (`testAnArchivedChannelOffersNoEditOrDelete`,
`testEditAndDeleteAreWithheldWithoutTheServersEditAndDeleteIds`). Card **t_610b979b (R4)**.

## §F6 The shipped live suite does not reproduce

`docs/t48-build-note.md` claims five live UI tests green. Measured here:

* **Run 1 (host wedged).** `5 run / 0 skipped / 8 failures` in 491.8 s. Three of the failures are the
  runner losing the app (`Lost connection to the application (pid 2497)`,
  `Failed to get background assertion for target app with pid 0`); the host had five other
  `xcodebuild test` processes and a CoreSimulator launch host that refused to boot until
  `simctl shutdown all`. That run is **environment, not product** and is not counted against T48.
* **Clean run (simulator erased, rebooted, one test).** `1 run / 2 failures` in 251.8 s:
  Copy Link **passed** — `postOptions.copied` equalled `http://127.0.0.1:8065/perf/pl/<post>` — and
  Copy Text **failed**: `postOptions.copied` never appeared within 20 s, so the sheet's own 400 ms
  pasteboard read-back did not return the string it had just written — or the copy action never ran;
  the log cannot tell them apart, which is itself the defect. Same gate, same test, 30 s apart: the
  read-back is not reliable on this host, and it is the only evidence the suite accepts for a copy,
  with no retry behind it.
* **A second full run** was started and killed while wedged in `SimDevice installApplication`
  (`host_support_mig_install_app`), with the host at load average 468. It measured nothing and is
  **not** counted. The five-test suite therefore has **no reproduced green run** in this pass; the one
  clean test measured 1 of 5, and 0 of the five claims in the note's table are confirmed by a full run.

Two additional harness defects found by reading the file while diagnosing: the tests' own REST client
is `URLSession.shared` (`T48PostOptionsUITests.swift:569`) — the cookie-carrying session T47-AV measured
as making a correct login answer 401 — and `PostOptionsViewModel.perform`'s catch returns `.failed`
without logging anything, so "the server does not hold it" cannot be traced to a status. Card
**t_ff68111a (R5)**.

## §AV unit — MattermostTests/T48PostOptionsAVTests.swift

Six tests; three assert behaviour the product is supposed to have and three record defects
(`expectKnownDefect`, strict: they fail as "unexpectedly passed" once fixed). The strict run is
produced by making `expectKnownDefect` a no-op.

| Test | Asserts | Strict (defect present) |
|---|---|---|
| `testTheChannelsOwnTeamNamesThePermalinkWhenTheRouteCarriedAnotherTeam` | the channel's name wins when both reads answer | green |
| `testAFailedTeamNameReadMustNotLeaveTheRoutesTeamInThePermalink` | a failed name read must not yield `/ops/pl/…` | **red** (F4) |
| `testAnArchivedChannelOffersNoEditOrDelete` | archived ⇒ no edit/delete/reply | **red** (F5) |
| `testEditAndDeleteAreWithheldWithoutTheServersEditAndDeleteIds` | no `edit_post`/`delete_post` ⇒ no edit/delete | **red** (F5) |
| `testTheModelFlipsSaveToUnsaveOnAPreferencesFrame` | the model's branch flips on the frame (F2 is upstream) | green |
| `testTheModelFlipsPinToUnpinOnAPostEditedFrame` | `post_edited` flips pin (the hop that works) | green |

Counts, measured: **strict 6 run / 8 failures / 0 unexpected** (`** TEST FAILED **`), **as committed
6 run / 0 failures / 0 unexpected** (`** TEST SUCCEEDED **`). The failures in the strict run are exactly
the three defect tests — 3 assertions for F4, 3 for the archived gate, 2 for the permission ids — and
the three premise tests stay green, so a red strict run is a statement about the product, not about a
broken fixture. Making `expectKnownDefect` a no-op is the strict switch; it is one line and the note
says so instead of hiding it behind an environment variable the test host never receives.

## §Mutations — making a green test fail

Two mutations, each one line, run against `MattermostTests/T48PostOptionsTests` (the existing 23),
then reverted (the worktree's product sources are byte-identical to `origin/main` afterwards — `git
status` shows only the three new files):

* **A:** `PostOptionsGate.canPin` returns `true` unconditionally → **2 tests fail**
  (`testAnUnknownPermissionLookupWithholdsPin`, `testOnARealServerTheFallbackIsTheChannelsWritePermission`),
  3 assertion failures out of 23 tests.
* **B:** `SavedPostDerivation.updated` ignores `deleted` → **2 tests fail**
  (`testSavedStateAppliesOnlyTheFlaggedCategory`, `testTheOfferedListComesFromTheStoreAndTheLoadedState`).

The point is not that the suite is weak — it is to name which tests are load-bearing. Both gates this
pass leans on (the pin permission fallback, the unsave direction of the preference patch) are caught by
the shipped suite when broken, so the green 23/0 above is evidence, not silence.

## Not measured (and not counted as passes)

* **A real device / parity soak** — no physical device is attached to this host; every run is a
  simulator.
* **APNs / push-driven menu state** — no APNs credentials here.
* **The cross-team live permalink** — see §F4; the UI has no route that produces the mismatch, so only
  the unit-level reproduction is claimed.
* **The "refused write keeps the sheet open" claim, live** — the AV UI test for it
  (`MattermostUITests/T48PostOptionsAVUITests.swift`, `testTheSheetStaysOpenAndDrawsTheReasonWhenThePinIsRefused`)
  is written but **never executed**: the simulator's `installApplication` step wedged twice under the
  host load described above, and the file has no result line anywhere. Its refusal is measured
  server-side (`POST /posts/{id}/pin` on a deleted post → 403), the sheet's inline reason is covered at
  unit level by the shipped `testAFailedWriteSaysWhy`, and the live half is **not claimed**. Nor is
  the second AV UI test executed (`testTheOwnPostsMenuOpensOnTheThreadRoot`). Treat the file as a
  prepared attack, not as evidence.
* **A second client's pin/save with the sheet open, driven live** — the probe wrote from a second
  token and the frames are in `build/logs/t48av-probe.log`, and the shipped live suite's own save test
  failed the same way, but this pass never held the sheet open in the simulator while a second client
  wrote: the simulator would not take the app (see §F6). What the wire shows makes the live exercise
  foregone — the frame that would carry the change is dropped by the decoder (F2) — so the criterion is
  recorded as **not measured live**, diagnosed instead.
* **The pin 403 with a "post-write role" removed** — not reproduced (§1); the endpoint honoured a
  member with no channel roles.

## Repair cards filed from this pass

| Card | Finding |
|---|---|
| `t_29925e81` (R1) | the lookup rows (search, mentions, saved, pinned) offer no menu — F1 |
| `t_9acf2b1c` (R2) | Copy Link can name the route's team when the name read fails — F4 |
| `t_b28e8cfc` (R3) | no server follow flag; Unfollow Message unreachable — F3 |
| `t_610b979b` (R4) | Edit/Delete ignore `edit_post`/`delete_post` and the archive — F5 |
| `t_ff68111a` (R5) | the live suite does not reproduce: cookie session, pasteboard gate, silent failures — F6 |
| `t_fddfb0d5` (existing) | the save→remove socket gap — **diagnosed** here: the decoder drops the string payload (F2) |

## Reproduce

```bash
cd <worktree at origin/main>
# server + fixture (container mm-perf, 9.11.19)
docker start mm-perf && curl -s http://127.0.0.1:8065/api/v4/system/ping
# server record for every row (needs websockets for the preference frames)
uv run --with websockets python3 scripts/t48_av_probe.py
# unit suites
python3 scripts/qa-test.py --platform ios --sim id=81A7F251-8B31-4945-8783-5A264C14B8D5 \
  --only-testing MattermostTests/T48PostOptionsTests --derived-data … -- \
  -clonedSourcePackagesDirPath ~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa/SourcePackages
# live
TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
TEST_RUNNER_MM_AUTH_PASSWORD=… python3 scripts/qa-test.py --platform ios --sim id=… \
  --only-testing MattermostUITests/T48PostOptionsUITests
```
