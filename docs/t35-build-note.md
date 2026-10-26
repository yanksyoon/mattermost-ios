# T35 — native composer (S14) + autocomplete (S15)

Card: `t_c5ae6d34`. Baseline: `d1d80c5` (T34-R5). Surface: `.composer`, gated behind
`-surfaceMode composer=native` **and** `-surfaceMode shell=native`; the default is still the
webview composer, because flipping it is T35-AV's decision, not this card's.

## 1. What this replaces (parity)

`docs/component-map.md` §S14/S15 lists the upstream files. This card ports their *behaviour* against
the documented REST v4 contract — no upstream source was copied:

| upstream (`mattermost-mobile`, Apache-2.0) | here |
| --- | --- |
| `app/components/post_draft/post_draft.tsx`, `post_input/`, `send_button/` | `ComposerView` (input, toolbar, banners) + `ComposerViewModel` (state machine) |
| `app/components/post_draft/draft_handler/`, `M app/actions/local/draft.ts` | `ComposerDraftStore` (GRDB, one file per server) |
| `app/components/post_draft/uploads/` | `ComposerViewModel.add/cancelUpload/retryUpload/removeAttachment` + `MMMultipart` |
| `app/components/autocomplete/*`, `app/components/autocomplete/at_mention/` | `ComposerTriggerParser` + `ComposerMembership` + `ComposerSuggestionRanking` |
| `app/screens/edit_post/` | `ComposerViewModel.beginEditing`/`performEdit` (same composer, edit mode) |
| `app/components/common_post_options/` (edit/delete entries) | `PostRowView`'s overflow button (`post.<id>.menu`) → one `PostOptionsSheet` per list, entries decided by `ComposerRowPermissions` (the `.contextMenu` long press this replaced is unreachable on iOS 26 — §7.1) |
| `app/client/rest/posts.ts`, `files.ts`, `users.ts`, `channels.ts` | `ComposerAPI` on top of the existing `APIClient` |

Attribution: `docs/THIRD_PARTY_NOTICES.md` §12 (upstream read set, the endpoints the server disagreed
with, and the webapp as observed-only).

## 2. The write path, in order

1. **Type.** Every keystroke goes `ComposerTextView` (a `UITextView` bridge, because SwiftUI's
   `TextEditor` cannot report a caret) → `ComposerViewModel.textChanged` → the draft store (written
   through on every change, no timer — §7.3) and the trigger parser.
2. **Autocomplete.** `@`, `#` and `:` start a *generation-guarded* task. A late answer from an older
   generation is dropped, so typing `kim` then `kimberly` cannot leave the first list on screen.
   `@` → `GET /users/autocomplete?name=&in_channel_id=&in_team_id=` answered as
   **`{"users":[…]}`**, then filtered against `GET /channels/{id}/members` **by user id**;
   `#` → `POST /teams/{id}/channels/search` with `{"term","limit"}` (POST — see §4);
   `:` → the built-in table plus T34's `EmojiCatalogue`.
3. **Attach.** `ComposerViewModel.add` starts one `POST /files` per file. Progress comes from the
   transport's `didSendBodyData` (the `DownloadWorker` convention, reversed), the tray's
   `accessibilityValue` publishes `queued` / `uploading <n>%` / `uploaded <file id>` /
   `failed <reason>`, and a cancel really cancels the task (`URLError.cancelled` → `MMError.cancelled`).
   **No automatic retry**: a replayed multipart upload can duplicate an attachment.
4. **Send.** `POST /posts` with the client's own `pending_post_id`. Before the request leaves, an
   optimistic row is inserted into the channel list with the id `pending:<uuid>` and a "Sending…"
   status. Then:
   - the **REST answer** replaces that row with the server's post (`confirmPendingPost`), and
   - the **socket echo** replaces the same row again (`reconcile` by `pending_post_id`).

   Whichever arrives first wins and the other is a no-op, because both paths key on the client id and
   `PostListDerivation`/`rebuild()` re-derive one row per post id. A second row for one send is not
   possible from either direction; the live test asserts zero `post.pending:` rows after the send and
   exactly one row for the server's id.
5. **Fail.** The optimistic row is withdrawn, the text **stays**, the failure banner shows the
   server's meaning, and the draft is written immediately (a failed send never waits on a timer). Retry
   re-sends **the same** `pending_post_id`, so a request whose answer was lost cannot become two
   messages **within one process lifetime**. That qualification is the whole of F6 and it is a real
   limit, not a footnote: `ComposerViewModel` keeps the client id and the failed phase in memory
   (`pendingCommand`, `phase`) and the draft store holds only the *text*, so after a process death the
   text comes back as a plain draft and the next Send mints a **new** `pending:<uuid>`. A request that
   *landed* while its answer was lost, followed by a kill, can therefore still become two posts —
   the server's idempotency is keyed on the id it was given, and the relaunched client no longer
   has it. The idempotency half is measured (the server replays a repeated `pending_post_id` as the
   same post: 201, same id, one row); the *duplicate* is not measured end-to-end, because proving it
   needs a host that can forward a `POST`, drop the answer and stop the server, which this host cannot
   do (T35-AV §3, `t35-av-findings.md`). Fixing it is product work — persist the pending id next to
   the draft and restore the retry affordance on relaunch — and is not part of this repair card; a
   card that claims it must also ship the probe.
6. **Edit / delete.** `beginEditing` loads the post into the same composer; `PUT /posts/{id}` saves the
   message only. Delete is `DELETE /posts/{id}`, and the row keeps its slot as a tombstone — the same
   `applyTombstone` the socket uses, so a delete from this device and one from another device
   converge instead of fighting.
7. **Drafts.** One row per `(channel, thread root)` in T29's `draft` table, in a **per-server** SQLite
   file. Empty text **deletes** the row (the composer's rule). Writing is *write-through*: every
   change is written at once, coalesced only while a write is already running, and backgrounding
   flushes explicitly — a debounce window is a window a killed process can fall into (§7.3).

## 3. Tests

### Unit (Catalyst) — 105 new tests in `MattermostTests/T35*.swift`

- `T35ComposerModelsTests` (36): trigger parsing (including "an email address is not a mention" and a
  caret at the end of the string), markdown edits on a selection, the multipart body layout,
  membership filtering, ranking, error copy, and the row-permission rule (`ComposerRowPermissions`:
  edit/delete only on my own post, never when the author is unknown, no menu on a system line, a
  tombstone or an optimistic row).
- `T35ComposerViewModelTests` (34): optimistic insert + replacement, a failed send keeps the text,
  a stale autocomplete answer is dropped, upload progress and cancel, send with no words but an
  uploaded file, draft clearing, retry reusing the client id, and §7's write-through draft policy.
- `T35ChannelPendingRowTests` (11): reconciliation by `pending_post_id`, a reply's echo is not added
  to the channel, edit/delete tombstones, and "did my post land anyway?" (a *pending* row must not
  count as landed, or a retry would double-post).
- `T35ComposerDraftStoreTests` (10): per-`(channel, thread root)` rows, channel vs thread, empty
  deletes, in-memory parity, real persistence through a temp GRDB file.
- `T35UploadTests` (7): multipart `Content-Type`, both parts, progress from the transport, no retry.
- `T35ComposerAPITests` (7): the endpoints whose shapes the server disagreed with (§4), pinned.

Full Catalyst suite: **1010 run / 4 skipped / 0 failures** — `build/logs/t35r2-units3-catalyst.log`
(`** TEST SUCCEEDED **`). Before T35 the same suite was 905, so T35 adds 105.

### Live UI (`MattermostUITests/T35ComposerUITests`, real server `127.0.0.1:8065`)

Fixture: `python3 scripts/t35_composer_seed.py --url http://127.0.0.1:8065` (channel `t35-composer`
in team `perf`, plus `t35-second-chat` in a second team `t35-second`).

Run (the destination is a device **id**: two "iPhone 16 Pro" simulators exist here and a name-based
destination cannot be resolved):

    TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
    TEST_RUNNER_MM_AUTH_PASSWORD=… xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
      -destination "platform=iOS Simulator,id=81A7F251-8B31-4945-8783-5A264C14B8D5" \
      -derivedDataPath ~/Library/Developer/Xcode/DerivedData/mattermost-ios-qa \
      -only-testing:MattermostUITests/T35ComposerUITests

Verdict from the runner (`build/logs/t35r2-live3.log`, `** TEST SUCCEEDED **`): **7 of 7 green**,
283 s total, 0 skipped —

| test | verdict |
| --- | --- |
| `testSendingAMessageAppearsOnceAndCarriesTheServersID` | passed (27.1 s) |
| `testAMentionCompletesFromTheChannelsMembersAndInsertsTheUsername` | passed (18.9 s) |
| `testAChannelMentionUsesTheTildeForm` | passed (22.0 s) |
| `testAnAttachmentUploadsWithProgressAndIsSentWithThePost` | passed (22.0 s) |
| `testADraftSurvivesATeamSwitch` | passed (48.0 s) |
| `testADraftIsRestoredAfterARelaunch` | passed (97.9 s) — restored from the real SQLite draft row |
| `testMyOwnPostCanBeEditedAndDeletedFromTheRow` | passed (47.3 s) — edit saved, delete confirmed by the server, tombstone drawn |

The screenshots in `docs/t35-shots/` are exported from **this** run's attachments (15 images,
including `t35-10-deleted` and `t35-15-draft-restored-after-relaunch`, which the earlier partial runs
never produced). An earlier full run (`t35-live5`) was 5/7; §7 is what changed.

## 4. Four real bugs the live suite found (all fixed, all now unit-pinned)

These are the reason the live suite exists — a stub that answers what the client expects would have
passed every one of them:

1. **`GET /users/autocomplete` answers an object, not an array.** `{"users":[ … ]}` — a bare-array
   decode throws, `try?` swallowed it, and every `@` term produced an empty list. The browser makes
   the same request and gets the same envelope.
2. **Channel search is POST.** `/teams/{id}/channels/search` answers **404 `api.context.404.app_error`**
   to a GET with `?term=` on 9.11.19 (measured with a bare `urllib` probe, no app involved); with
   `POST {"term","limit"}` it answers a bare array. `#` produced nothing at all before this.
3. **The membership filter compared names with ids.** The member list is `user_id`s; the suggestion's
   `value` is a username. A complete member list therefore filtered *every* person out. The
   suggestion now carries `userID`, and the filter reads that.
4. **An accessibility identifier on a SwiftUI container overwrites its children's.** Every element
   inside the composer reported `channelComposer`, so no part of the write surface (Send, input,
   toolbar) could be addressed by a test — and, for VoiceOver, none of them had its own name.
   `.accessibilityElement(children: .contain)` before the identifier fixes it; the same pattern was
   applied to the suggestion list, the banners, the tray and (renamed `previewPane` to avoid a
   duplicate) the preview.

Unit-test pressure found three more, before any device ran:

5. `ComposerTrigger.trailingSpace` indexed `character(at:)` one past the end when the caret was at the
   end of the text — a crash on every "insert suggestion at the end".
6. `post(withPendingID:)` answered "your post landed" for a row that was still *pending*, so the
   composer's retry could skip a resend it needed (or, worse, refuse one) — a pending row is not a
   landed post.
7. `retry()` minted a **fresh** `pending_post_id` instead of re-sending the same one, defeating the
   whole reconcile-by-id design on the exact path that needs it most.

## 5. Limits (also in `docs/parity.md`)

- The input has no rich text and no inline markdown styling while typing; preview is block-level.
- No emoji **picker** (S17/T37); `:` completes built-in names + T34's server catalogue.
- No slash commands; `@channel/@here/@all` are inserted as text without a confirmation step.
- `#` searches channels only (no user search), and only the loaded team's channels.
- **A reply is sent but not inserted optimistically**: a reply is not a row of the centre timeline
  (`ChannelViewModel.isTimelineRow`, T34-R5). The thread pane is S13/T36; until then a reply's send
  reports through the composer's status line.
- Scheduled posts (S40) are not implemented.
- The tray accepts what the pickers hand over: **no size check, no downscale, no camera capture**.
- An edit changes the message, not its attachments.
- Uploads are sequential per file, with no background continuation (a background will cancel in
  flight, and the tray offers Retry rather than silently re-uploading).
- The composer never reads the T29 store, so a draft is the only offline artefact.
- Cancelling a send that is already on the wire is not offered: the composer waits for the answer
  (the alternative — abandoning a request the server may have accepted — is the double-post path).

## 6. Test-environment notes (honest, for T35-AV)

- **The draft-relaunch test has to navigate after relaunch.** The shell restores the *server* and the
  sidebar, not the push stack — and the restored **team** is whatever the shell last selected, which
  is not necessarily the fixture's team (measured: after relaunch the app was on team "Operations"
  while the channel lives in team "perf"). The test therefore walks the path a person walks: back to
  the sidebar, pick the team, then find the channel through the **quick switcher** — the sidebar's
  own list is a `List`, so a row outside the viewport is not in the accessibility tree at all and
  tapping by identifier would depend on scroll position. This is app behaviour (no navigation-stack
  restore), not a workaround in the product.
- **A channel inside a collapsed category has no sidebar row**, so a switch driven by the sidebar is
  not possible for every channel. The team-switch draft test therefore uses the second team's only
  channel, which is visible.
- **XCTest crashed once** while snapshotting the tree during a long press
  (`EXC_BAD_ACCESS` in `-[XCElementSnapshot identifier]`, `XCTAutomationSupport`, on the app's main
  thread; report `Mattermost-2026-10-25-194739.ips`). The app was not at fault and the same test
  passes on re-run; it is recorded here because a crash report exists and the validator will find it.
  The long press is gone from the suite anyway (§7.1).
- The T34-R5 note's intermittent socket failure (`posted` never reaching `ChannelPaneCoordinator`)
  affects this suite too: the *row* still appears because the REST answer reconciles the optimistic
  row by id, which is exactly why that path does not depend on the socket.

## 7. Round 2 — the two last reds, and the three bugs behind them

Run 123 closed at 5/7 live. The two reds turned out to be two product bugs and one wrong oracle.
All three are fixed in the tree; the whole suite is 7/7 (§3) and the units are 1010/0.

### 7.1 `.contextMenu` is unreachable on iOS 26 → the row's actions are a visible button + sheet

`PostRowView` put Reply/Edit/Delete in a `.contextMenu` (long press). Evidence from run 124
(`build/logs/t35r2-live1.log`, failure tree): the press opened **`Copy`** and **`Share…`** — the
*text* menu — with none of the app's items. The long press lands in the body's `Text`, so the system
wins the gesture. Two earlier runs also crashed the automation framework while snapshotting that
menu (see §6).

The row now draws an overflow button (`post.<id>.menu`, label "Message actions") that presents one
`PostOptionsSheet` per list (`postOptions.edit` / `.delete` / `.reply` / `.cancel`). That is also the
upstream idiom: mattermost-mobile opens a post-options sheet rather than using a long-press menu.
Who may edit or delete is one pure rule, `ComposerRowPermissions` (it was duplicated, and the copies
disagreed), unit-pinned including the two "unknown" cases — an empty post author and an unresolved
session user are **not** treated as "mine".

Since the sheet is a plain `List` of `Button`s, the identifiers are stable: the edit path (banner,
prefilled text, save, `(edited)`) and the delete path (server + tombstone) both pass.

### 7.2 The delete oracle was wrong: this server answers **404**, not `delete_at`

The test proved "the server marked it deleted" by reading `GET /posts/{id}` and expecting
`delete_at > 0`. Against a real Mattermost 9.11.19 that is false. Measured with no app involved
(`scripts/t35_softdelete_oracle.py`): create → `DELETE` (200) → `GET /posts/{id}` = **404**, the post is
gone from the channel window, and `PUT` after delete = **403 "You do not have the appropriate
permissions."**. The app was deleting correctly all along; the assertion was reading the wrong
answer.

The test now accepts either answer (a 404 **or** `delete_at > 0`) *and* requires the channel window
to stop listing the post. The tombstone is then revealed with the same `revealPost` helper the rest
of the suite uses — an off-screen row of a `LazyVStack` is not in the tree at all, which is why the
"row must keep its slot" assertion failed on a tree that did contain the tombstone.

### 7.3 A draft written only on a debounce is a draft the process can outlive

Acceptance criterion: *the text is never lost (including after app backgrounding)*. The draft was
written by a 400 ms debounce task. Measured two ways:

- run 124, first attempt: type, kill, relaunch → the app's **SQLite file had an empty `draft`
  table** (checked directly with `sqlite3` in the simulator container), i.e. the write never ran;
- a later attempt after adding a leading write: the relaunch restored **`t`** — the first character
  only, because that was the single write that had landed before the kill. A partial draft is worse
  than an obvious loss, because it looks like the reader's own text.

The write is now **write-through with coalescing**, no timer: every change writes immediately, and a
change that arrives while a write is in flight folds into exactly one follow-up write carrying the
latest text. A fast typist still cannot queue one write per keystroke, and there is no window in
which a keystroke lives only in memory. `draftDebounce` is gone from `ComposerViewModel`; the
property is pinned by `testEveryKeystrokeIsOnDiskWithoutWaitingForATimer` (asserts the first
keystroke, the last keystroke of a burst, and that a fresh model over the same store restores
exactly what was typed). The live relaunch test now passes in 97.9 s.

Backgrounding is still handled separately (`ChannelView.onChange(of: scenePhase)` →
`saveDraftNow()`), which is the case the card names explicitly.

### 7.4 What is still not done here

- The screenshots are the app against the seeded local server; they are real data (the channel's
  own posts, a real upload id) but they are **not** a real workspace: this host has no Mattermost
  server with production traffic.
- A relaunch does not restore the navigation stack (§6), so "back where you were" is not a property
  of this build; T30's routing owns that.
- The live suite's `-uiTestSeedServer` seam registers a fresh server row per launch, and each row
  gets its own SQLite file under `Application Support/MattermostStores/`; a long session of UI runs
  leaves one file per launch (~260 KB each, measured 50+ after a day of runs). That is test-seam
  hygiene (idempotent seeding by URL), not a composer bug — recorded so it is not mistaken for one.

### 7.5 The T34 suite is red on this host, and it is not this card's change

The row-actions change adds one element per row, so T34's live suite was re-run against it rather
than assumed. It is **not** green, and a base-commit A/B shows the failures were already there:

| test | with T35's rows | at `d1d80c5` (T35's two row files swapped out) |
| --- | --- | --- |
| `testLoadingOlderPostsDoesNotMoveTheAnchoredPost` | fails, 52.7 s: "the anchored post `post.m6mep5dut3y6feem8fzejj4jpr` left the screen" | **fails, 51.9 s, same post, same message** (`build/logs/t34-anchor-base.log`) |
| `testANewPostAppearsWithoutReloadAndTheUnreadLineFollowsLastViewedAt` | fails: no socket row | fails the same way (the flake T34-R5 documented) |
| `testReachingTheTop…`, `testThePostListRendersTheServersShowcase` | fail | fail — they run after the app has been killed (below) |

Both full-suite runs also lost the app process, with the automation-session signature of §7.4/§6
(`~/Library/Logs/DiagnosticReports/Mattermost-2026-10-25-210015.ips`, `-210758.ips`). So: the anchor
failure and the flake are pre-existing on this host, the crash is the harness's, and the two tests
after the crash are cascade. Nothing in this table is evidence against the composer work, and
nothing in it was "fixed" here — the T34 lane owns it.

One consequence worth writing down: the T35 live suite passes 7/7 *because* it is short — the app is
not kept alive long enough for the automation session to die on it. A suite that snapshots 120 rows
does, on this host, most runs.

## 8. Round 3 (T35-R) — the T35-AV findings, closed

Card `t_e7eeaa46` closes the six findings of T35-AV (`t_3042a50f`, `t35-av-findings.md`). No part of
the write surface changed in this round: it is documentation, one attribution section, one coverage
assertion, and one product limit that is now stated instead of overstated. Everything below was
re-derived in this tree, not copied from the AV's worktree.

| finding | disposition |
| --- | --- |
| **F1** no repo-level NOTICE entry | `docs/THIRD_PARTY_NOTICES.md` **§12** added in the shape of §7–§11: the upstream read set, the endpoints whose shapes the server disagreed with, `app/screens/global_drafts/` as read-and-not-ported, and the webapp as **observed only** (nothing copied). §1 above and the six `Composer*.swift` headers now point at §12 — they had pointed at §11, which is T34's section. |
| **F2** global drafts undocumented | `docs/parity.md`'s T35 row now says it in "limits that stay": **no global drafts list** — drafts are per `(channel, thread root)`, there is no S14 `GlobalDraftsView`, and the screen is unowned on the board. |
| **F3** stale build-note lines | Both corrected to the shipped behaviour: §2 step 1 describes the write-through draft store (the 400 ms debounce is gone, §7.3), and §1's parity table maps row actions to `post.<id>.menu` + `PostOptionsSheet`, not `PostRowView.contextMenu`. |
| **F4** the live `@` test could not fail | Repaired and **proved to fail**. See §8.1. |
| **F5** no card id in `d7f3036`'s body | History is not rewritten. Recorded here, with the convention for this lane from now on: every commit body names `T35` **and** the card it serves. The commits of this card carry `t_e7eeaa46`, and the last commit of a card is the one whose body most needs it, because that is the commit a validator reads. |
| **F6** the "one message, not two" guarantee is process-local | **Documented, not fixed** — option (a) of the finding, chosen because option (b) is product work (persist the pending id next to the draft, restore the retry affordance on relaunch) that would need its own unit test and the AV-08 probe shape, and this card's brief is "do not re-open the surface". §2.5 and the parity row now say the guarantee holds **within one process lifetime** and why: the client id and the failed phase are in `ComposerViewModel`'s memory, the draft store keeps only the text. See §8.2 for the half that *is* measured. |

### 8.1 F4 — the `@` test now fails if the membership filter is deleted

The old test typed `@per` and offered the signed-in account (`perfprobe`), who **is** a member of
`#t35-composer`, so a client with no filter at all passed it. Measured on this server: the
autocomplete answer for `per` is `[perfprobe]` — one member, nothing to filter — while the answer for
**`p`** is `[opsbot, perfprobe, playbooks, probeone832551, probezero959035]`, and `perfprobe` is the
only member among them. So the test:

1. types **`@p`**;
2. asks the server itself for the same answer (`GET /users/autocomplete?name=p&in_channel_id=…`) and
   asserts it contains `perfprobe` **and** the non-members `opsbot` / `probeone832551` — the oracle
   that makes the negative half non-vacuous (a client that queried nothing would also "pass"
   `XCTAssertFalse`);
3. asserts the member is offered and taps it, then that `@perfprobe` is inserted;
4. asserts `composerSuggestion.user-opsbot` and `composerSuggestion.user-probeone832551` do **not**
   exist.

Both directions, run here:

| run | command | result |
| --- | --- | --- |
| suite, real code | `scripts/qa-test.py --platform ios --sim id=81A7F251… --only-testing MattermostUITests/T35ComposerUITests --label t35r-f4` | **7 run / 0 skipped / 0 failed, 322 s**, `RESULT: PASS` (`build/logs/t35r-f4.log`); the mention test 19.2 s |
| the same one test, with the filter **deleted** (`ComposerMembership.filter` returns every candidate) | `… --only-testing …/testAMentionCompletesFromTheChannelsMembersAndInsertsTheUsername --label t35r-f4-mutation` | **failed (22.1 s)** on both negatives — `T35-ComposerUITests.swift:157` and `:159`, `XCTAssertFalse failed - a team member who is not in this channel must not be offered` (`build/logs/t35r-f4-mutation.log`, `RESULT: FAIL`) |

The mutation was reverted before anything was committed (`git diff` for `ComposerModels.swift` is the
NOTICE-reference line and nothing else), and the passing suite above is the unmutated tree — the two
runs are in that order, so the file that ships is the file that passed.

Scope note: this round changes **one** test and no product code. `#` completion stays covered by
`testAChannelMentionUsesTheTildeForm`; `:` completion and the markdown preview are covered only by the
AV's AV-03 probe, and the reply path only by AV-07 — both are AV evidence, not suite coverage, and
T36 owns the reply surface (§5).

### 8.2 F6 — what is measured, and what is not

`scripts/av_t35_pending_id_replay.py` (added here from the AV's probe, so the claim is reproducible
without the AV's worktree) re-measured the server's idempotency on this instance with no app involved:

    first create  : 201, id nynbequyiprkpyd5d3go63zsjc, pending_post_id pending:av-replay-1792989954284
    replay        : 201, **same id**
    posts in the channel carrying that message: 1   → `deduped_by_server: true`

So *replaying the same `pending_post_id` is safe*, and the retry path inside one process really cannot
duplicate a send. What is **not** measured — and is now written down as a limit rather than a
guarantee — is the cross-process case: a request that landed while its answer was lost, then a process
death, then a Send under a new id. Proving that needs a host that can forward a `POST`, drop the
answer and stop the server (T35-AV §3 could not do it here either: the relay mis-framed HTTP/1.1
keep-alive and `docker stop` is refused by this runner). A card that fixes it must ship that probe
with it.
