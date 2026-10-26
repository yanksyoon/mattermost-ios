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
| `app/components/common_post_options/` (edit/delete entries) | `PostRowView.contextMenu` → `ChannelView` row actions |
| `app/client/rest/posts.ts`, `files.ts`, `users.ts`, `channels.ts` | `ComposerAPI` on top of the existing `APIClient` |

Attribution: `docs/THIRD_PARTY_NOTICES.md` §11 (endpoints + component structure).

## 2. The write path, in order

1. **Type.** Every keystroke goes `ComposerTextView` (a `UITextView` bridge, because SwiftUI's
   `TextEditor` cannot report a caret) → `ComposerViewModel.textChanged` → the draft debounce (400 ms)
   and the trigger parser.
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
   server's meaning, and the draft is written immediately (the debounce may not have fired). Retry
   re-sends **the same** `pending_post_id`, so a request whose answer was lost cannot become two
   messages.
6. **Edit / delete.** `beginEditing` loads the post into the same composer; `PUT /posts/{id}` saves the
   message only. Delete is `DELETE /posts/{id}`, and the row keeps its slot as a tombstone — the same
   `applyTombstone` the socket uses, so a delete from this device and one from another device
   converge instead of fighting.
7. **Drafts.** One row per `(channel, thread root)` in T29's `draft` table, in a **per-server** SQLite
   file. Empty text **deletes** the row (the composer's rule). Backgrounding writes the draft
   synchronously (`scenePhase != .active`), so a kill cannot lose the last words.

## 3. Tests

### Unit (Catalyst) — 102 new tests in `MattermostTests/T35*.swift`

- `T35ComposerModelsTests` (25): trigger parsing (including "an email address is not a mention" and a
  caret at the end of the string), markdown edits on a selection, the multipart body layout,
  membership filtering, ranking, error copy.
- `T35ComposerViewModelTests` (30): optimistic insert + replacement, a failed send keeps the text,
  a stale autocomplete answer is dropped, upload progress and cancel, send with no words but an
  uploaded file, draft clearing, retry reusing the client id.
- `T35ChannelPendingRowTests` (9): reconciliation by `pending_post_id`, a reply's echo is not added to
  the channel, edit/delete tombstones, and "did my post land anyway?" (a *pending* row must not count
  as landed, or a retry would double-post).
- `T35ComposerDraftStoreTests` (12): per-`(channel, thread root)` rows, channel vs thread, empty
  deletes, in-memory parity, real persistence through a temp GRDB file.
- `T35UploadTests` (9): multipart `Content-Type`, both parts, progress from the transport, no retry.
- `T35ComposerAPITests` (7): the two endpoint shapes in §4, pinned.

Full Catalyst suite: **1007 run / 4 skipped / 0 failures** — `build/logs/t35-units-catalyst.log`
(`** TEST SUCCEEDED **`). Before T35 the same suite was 905, so T35 adds 102.

### Live UI (`MattermostUITests/T35ComposerUITests`, real server `127.0.0.1:8065`)

Fixture: `python3 scripts/t35_composer_seed.py --url http://127.0.0.1:8065` (channel `t35-composer`
in team `perf`, plus `t35-second-chat` in a second team `t35-second`).

Run: `TEST_RUNNER_MM_AUTH_SERVER=… TEST_RUNNER_MM_AUTH_LOGIN=… TEST_RUNNER_MM_AUTH_PASSWORD=…
python3 scripts/qa-test.py --platform ios --sim id=81A7F251-… --only-testing
MattermostUITests/T35ComposerUITests --label t35-live5`

Results are recorded from the runner's own verdict (`build/logs/t35-live*.log`). Last full run
(`t35-live5`): **5 of 7 green** —

| test | verdict |
| --- | --- |
| `testSendingAMessageAppearsOnceAndCarriesTheServersID` | passed (22.8 s) |
| `testAMentionCompletesFromTheChannelsMembersAndInsertsTheUsername` | passed (18.8 s) |
| `testAChannelMentionUsesTheTildeForm` | passed (20.2 s) |
| `testAnAttachmentUploadsWithProgressAndIsSentWithThePost` | passed (23.1 s) |
| `testADraftSurvivesATeamSwitch` | passed (46.7 s) |
| `testADraftIsRestoredAfterARelaunch` | **red** — the relaunch lands on the sidebar and the channel row is not in the tree (collapsed category), so the test cannot get back to the composer |
| `testMyOwnPostCanBeEditedAndDeletedFromTheRow` | **red** — the `contextMenu` long press is unreliable under XCUITest here: run 4 reached the Edit banner and saved the edit (screenshots `t35-08`/`t35-09` are that run) and then failed to find Delete; runs 5–7 could not raise the menu again |

Both reds are **test-driver/navigation** failures, not composer failures: the send, upload, autocomplete
and team-switch paths (which exercise the same composer, the same REST calls and the same draft store)
are green against the real server.

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

- **The draft-relaunch test has to navigate after relaunch.** The shell restores the *server*, not the
  push stack, so a relaunch lands on the sidebar; the test taps the channel row exactly as
  `launchAndOpen` does on a fresh start. That is app behaviour, not a test workaround — but it means
  "come back to the channel you were reading" is not a property this build has.
- **A channel inside a collapsed category has no sidebar row**, so a switch driven by the sidebar is
  not possible for every channel. The team-switch draft test therefore uses the second team's only
  channel, which is visible.
- **XCTest crashed once** while snapshotting the tree during a long press
  (`EXC_BAD_ACCESS` in `-[XCElementSnapshot identifier]`, `XCTAutomationSupport`, on the app's main
  thread; report `Mattermost-2026-10-25-194739.ips`). The app was not at fault and the same test
  passes on re-run; it is recorded here because a crash report exists and the validator will find it.
- The T34-R5 note's intermittent socket failure (`posted` never reaching `ChannelPaneCoordinator`)
  affects this suite too: the *row* still appears because the REST answer reconciles the optimistic
  row by id, which is exactly why that path does not depend on the socket.
