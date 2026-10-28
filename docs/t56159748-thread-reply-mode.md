# A thread's composer dropped reply mode after one send — mechanism and repair

Card: `t_56159748` (reported by the user: *"I replied to a thread but the message was sent to the
channel."*). Workspace: `mmios-ios`, workdir `~/Documents/yanks/code/mattermost-ios`, base `a14d508`.

Two independent defects sat in the same screen. The first is silent data loss, the second orphans a
post on the server.

## 1. Defect 1 — the reported one: reply mode did not survive a send

The chain, all of it in code:

1. `ThreadCoordinator.composer(for:model:emojiCatalogue:)` creates the composer **once** per
   `(channel, thread root)` and arms it with `composer.beginReply(to: root, authorLabel:)`. Correct.
2. `ComposerViewModel.performCreate` builds the request with `rootId = mode.rootID`, then calls
   `finishSuccessfully(note: "Reply sent to the thread")` — with the default `keepMode: false`.
3. `finishSuccessfully` therefore ran `mode = .newPost; replyTarget = nil`.
4. The composer is cached (`ThreadCoordinator.composers[server]["channelID/rootID"]`) and handed back
   on the next appearance; the reuse path calls `existing.attach(sink: model)` and **nothing else** —
   reply mode is never re-armed.

So the first reply was a reply and every later send from the same pane was a top-level channel post,
while the composer still looked like a thread's reply box. That is exactly what the reader saw.

`finishSuccessfully`'s behaviour was not wrong in itself: it encodes the **channel** composer's
lifecycle, where a reply is one message and the box then belongs to the channel again. The bug is that
one lifecycle was applied to two different objects.

## 2. Defect 2 — `root_id` came from the tapped row

`ThreadView.onReply` called `beginReply(to: row.post)` for any row of the thread, so tapping Reply on a
*reply* sent that reply's id as `root_id`. Mattermost nests exactly one level: a nested `root_id` is
refused or orphans the post, and it also keyed the draft to a post that is not a thread root.

`root_id` and the banner's address are different things: the root is the thread's root no matter which
row was tapped, and the label still names the person whose row it was.

## 3. The repair

* **One signal says "this composer is a thread's".** `ComposerPostSink` gained
  `var threadAnchor: ComposerThreadAnchor?` (default `nil`, so a channel timeline keeps the old
  behaviour) carrying `rootID` + `authorLabel`. `ThreadViewModel` is the only conformer that returns
  one. `ComposerViewModel.threadAnchor` / `isThreadComposer` expose it.
* **The invariant lives in one place.** `finishSuccessfully` now calls `leaveTransientMode()`:
  a channel composer goes to `.newPost` (unchanged — pinned by a test), a **thread** composer always
  lands in `.reply(rootID: anchor.rootID)`. Because every finish path (create, edit, retry) runs
  through it, no caller can put a thread composer back into channel-post mode; the fix is not a
  `keepMode: !rootID.isEmpty` at one call site (that would also have broken the channel composer's
  one-shot reply, since a channel reply carries a root id too).
* **Edit mode is covered by the same rule.** The thread row menu's *Edit* is served by the thread's
  composer: landing an edit used to run the same "back to `.newPost`" step, so editing a reply and then
  typing put the next message in the channel. It now returns to reply mode on the thread's root.
* **`cancelMode` cannot become "post to the channel" either.** For a thread composer it returns to
  `.reply` on the anchor; and it no longer writes a draft when leaving **edit** mode (an edit has no
  draft row — the post is the record — and `.editing` has no draft root, so the write landed in the
  *channel's* draft row). `ComposerView` stops offering that Cancel where it could only mean "become a
  channel composer": a thread box draws it only while editing.
* **Defect 2 in one place.** `ThreadViewModel.replyTarget(from:)` returns
  `(thread root post, tapped row's author label)` — the root is `row.post` when the tapped row *is* the
  root, otherwise the loaded root. `ThreadView.onReply` passes both through to `beginReply`.

## 4. Tests

`MattermostTests/T35ComposerViewModelTests` (six new cases, 34 → 40 in the class):

| # | Case | Asserts |
|---|------|---------|
| 1 | `testASecondReplyFromTheSameThreadComposerStillCarriesTheRootID` | two sends from one thread composer: `root_id` on **both** (the regression for the report) |
| 2 | `testAThreadComposerIsStillInReplyModeAfterASend` | the **mode** is `.reply(rootID:)`, `replyTarget` and the draft key stayed the thread's |
| 3 | `testAReplyToANestedReplyCarriesTheThreadRootID` | a real `ThreadViewModel` (root + reply): the tapped reply yields the thread root, and the send carries `root_id == root` |
| 4 | `testTheChannelComposerGoesBackToChannelPostsAfterAReply` | the negative: a channel reply is one message and the next send has no `root_id` |
| 5 | `testAThreadComposerReturnsToReplyModeAfterAnEdit` | an edit in a thread lands back in `.reply`, not `.newPost` |
| 6 | `testCancellingAnEditInAThreadReturnsToTheThreadsReplyMode` | Cancel returns to the thread and does not write the post's text as the channel's draft |

**Falsifier (measured, not claimed).** With `leaveTransientMode` temporarily restored to the pre-fix
behaviour, case 1 fails with the service double's two captured requests:

```
XCTAssertEqual failed: ("[Optional("root-1"), nil]") is not equal to
                      ("[Optional("root-1"), Optional("root-1")]")
   - every send from a thread pane is a reply — the second one included
```

`build/logs/t56159748/falsifier.log`. Case 4 passes on that same build, which is what proves the fix
is targeted rather than a blanket "replies stick".

**Live (real app, real server).** `MattermostUITests/T36-ThreadsUITests.testTwoRepliesInARowFromTheThreadComposerBothLandInTheThread`
opens a thread on the local throwaway server (`127.0.0.1:8065`, fixture `scripts/t36_thread_seed.py`),
sends twice **without leaving the pane**, and reads both sends back from the server's own API: both
must carry `root_id == rootID` and both ids must be rows of the thread. Server is the oracle, so a
channel post cannot pass. (That suite signs in with `-surfaceMode composer=native`.)

```
t56159748          : 1 run, 0 skipped, 0 failed — PASS  (build/logs/t56159748/t56159748.log)
t56159748-live-falsifier: 1 run, 0 skipped, 2 failed — the pre-fix build
   Assertion: ("") is not equal to ("if4mpnnsxjyqdjfsodzfczjq6e")
     - the second reply from the same thread pane must stay in the thread
   Assertion: both replies must be rows of the thread (server list: [root, seeded, first])
```

So the live test reproduces the report against a server and passes on the fixed tree.

## 5. Adjacent findings (not fixed here, out of this card's scope)

1. `ThreadCoordinator.forgetThread` clears `composers[serverID]["\(rootID)"]`, but composers are keyed
   `"\(channelID)/\(rootID)"` — the composer is never dropped with its thread (the 4-entry
   `warmComposerLimit` still bounds it, and the key includes the root, so nothing is mis-reused).
2. In **edit** mode `draftRootID` is `""`, so a keystroke in the edit box writes the edited post's text
   into the **channel's** draft row (`scheduleDraftSave`). `cancelMode` no longer adds to that, but the
   per-keystroke write is untouched.
