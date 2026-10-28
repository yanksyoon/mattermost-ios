# An edit overwrote — and on success deleted — the channel's draft

Card: `t_50a0f378`. Branch: `wt/t_50a0f378`. Base: `0f1029f` (post-T36 main).

## 1. What the reader saw

1. A half-written message in the channel composer, then **Edit** on any post: the first keystroke in
   the edit box replaced the unsent message with the post being edited. Cancelling the edit left the
   composer showing the abandoned edit, not the draft.
2. With an unsent message in the channel composer, an edit that **landed** deleted the draft row: the
   message was gone from the store as well as the screen.

The composer's own header says "editing has no draft (the post itself is the record)". Nothing
enforced it.

## 2. Why — and the third link the fix exposed

1. **`draftRootID` was `mode.rootID`**, which returns `""` for `.editing`. `""` is not "no key": it is
   the **channel's own** draft row (the store's identity is `(channel, root)`, and a top-level
   composer writes `""`). So the edit box addressed the channel's row from the first keystroke on.
2. **The write path believed it.** `textChanged` → `scheduleDraftSave` → the write built
   `ComposerDraft(channelID:, rootID: "", message: <the post's text>)` and saved it.
3. **The success path deleted it.** `finishSuccessfully` captured `let draftRoot = draftRootID`
   (still `""`, because it is read *before* the mode is reset) and deleted `(channel, "")`.

4. **And the deeper defect: the write read the mode when it ran, not when the change happened.** This
   was found by the fix's own tests, not by reading: a keystroke in the edit box schedules a write;
   `FakeComposerService.patchPost` answers without suspending, so the edit completes first — by the
   time the write ran, `mode` was `.newPost` again and `text` had been cleared, so the write resolved
   `""` + `""`, saw an "empty draft", and **deleted the channel's row**. A trace from this session
   (`drafts.writeSignal.recorded`, before the pipeline fix):

   ```
   typed:          writes=[]                                             rows=[]                        mode=newPost
   saved:          writes=["|half a thought"]                            rows=["|half a thought"]       mode=newPost
   editing:        writes=["|half a thought","|half a thought"]          rows=["|half a thought"]       mode=editing(p1)
   typed-in-edit:  writes=["|half a thought","|half a thought"]          rows=["|half a thought"]       mode=editing(p1)
   sent:           writes=["|half a thought","|half a thought"]          rows=["|half a thought"]       mode=newPost
   drained:        writes=[…, "DELETE", "DELETE"]                        rows=[]                        mode=newPost
   ```

   So fixing only `draftRootID` would have left half the card's falsifier standing: "with a channel
   draft present, edit a post and send it → the channel draft must still be there."

## 3. The repair (three connections, one invariant)

1. **`draftRootID` is `String?`** — `.newPost` → `""` (the channel's row), `.reply(root)` → `root`,
   `.editing` → **`nil`**. "No draft" is now a case the compiler forces every call site to handle, so
   no site can address `""` by accident again. The three sites: `restoreDraftIfNeeded` (guard: don't
   read), `saveDraftNow`/`writePendingDraft` (guard: don't write), `finishSuccessfully`
   (`if let draftRoot`: don't delete).
2. **A write carries the change it belongs to.** `scheduleDraftSave` captures a `DraftSnapshot`
   (`rootID`, `message`, `files`, `generation`) at the moment of the change; the writer writes *that*
   snapshot, never "whatever the mode says now". The coalescing is unchanged — a change arriving
   during a write still folds into one follow-up, and the follow-up carries the latest snapshot.
   `draftGeneration` is bumped by `finishSuccessfully`, so a write captured before a landed command
   cannot land after the delete and resurrect the words that were just sent (the case
   schedule-time capture would otherwise introduce).
3. **`beginEditing` flushes before it switches modes** (`await saveDraftNow()`, the pattern
   `cancelMode` already used). With the key now `nil` in edit mode, a channel draft whose write was
   still queued would otherwise have no key to land under. It is `async` for exactly this reason; the
   two call sites (`ChannelView` row menu, `ThreadView` row menu) wrap it in a `Task`.
4. `cancelMode`'s `if !mode.isEditing` branch is gone: in edit mode a draft write is now structurally
   a no-op, so the rule lives in one place instead of two.

No store format change: still one `draft` row per `(channel, thread root)`, same `ComposerDraft` →
`MMDraft` mapping.

## 4. Verification

* **New unit cases: 8** in `MattermostTests/T35ComposerViewModelTests.swift` (class 40 → 48), under
  "Edit mode owns no draft (kanban t_50a0f378)". They cover both halves of the card's falsifier in a
  channel composer, both paths in a thread composer, the read path, and the queued-write flush.
* **Class run:** `xcodebuild test … -only-testing:MattermostTests/T35ComposerViewModelTests` →
  48 passed, 0 failed (`build/logs/t50a0f378/t35c.log`).
* **Full unit suite:** `MattermostTests` → **1758 run / 8 skipped / 0 failures**, `XCODEBUILD_EXIT=0`
  (`build/logs/t50a0f378/units-final.log`). Baseline `0f1029f`: 1750 / 8 / 0 — the difference is the
  8 new cases.
* **Falsifier (pre-fix code + the new tests):** a second worktree from the fix commit with `main`'s
  `ComposerViewModel.swift`, `ChannelView.swift` and `ThreadView.swift` restored — **7 of the 8 fail**,
  including the card's two halves verbatim:

  ```
  testTypingInAnEditNeverTouchesTheChannelsDraftRow: ("the post being edited — now changed")
                                                     is not equal to ("half a thought")
  testCancellingAnEditRestoresTheChannelsOwnDraft:   ("") is not equal to ("half a thought")
  testASuccessfulEditKeepsTheChannelsDraftRow:       ("nil") is not equal to ("half a thought")
  testAnEditHasNoDraftKeyAtAll:                      XCTAssertNil failed: ""
  testBeginEditingFlushesAChannelDraftThatWasStillQueued:
                                                     ("nil") is not equal to ("typed and not yet written")
  testATypedThreadDraftSurvivesAnEditInTheThreadPane:
        rowID "" message "before, changed" — the thread's edit box wrote into the channel's row
  testASuccessfulEditInAThreadKeepsTheThreadsAndTheChannelsDrafts:
        ("nil") is not equal to ("channel thought") — a landed thread edit deleted the channel draft
  ```

  The one that passes on the old code is `testRestoringADraftNeverFillsTheEditBox`: the read path was
  already defended by the pre-existing "only fill an empty composer" guard, so it is kept as an
  invariant guard rather than a falsifier. The falsifier runs, kept next to this tree's other
  evidence, are `build/logs/t50a0f378/falsifier/falsifier.log` (the five channel-side cases) and
  `…/falsifier2.log` (the two thread-side cases).

## 5. Not done in this session

* **No live XCUITest.** The throwaway server these live checks use (`mm-perf` on `127.0.0.1:8065`,
  `scripts/perf_probe.sh --server-start`) is not running and the Docker daemon is not up on this host;
  the stub server (`build/uitest-server/mm_stub.py`) has no post/edit routes, only auth + sidebar. So
  the reader-visible flow is pinned at the view-model level (with the product store implementation
  behind the test double), not through the UI. The UI wiring this leaves untested is one line:
  `onEdit: { Task { await composer?.beginEditing(row.post) } }` (`ChannelView.swift`,
  `ThreadView.swift`).
* No device or Mac Catalyst run for this change (simulator only, iPhone 16 Pro,
  `81A7F251-8B31-4945-8783-5A264C14B8D5`).
