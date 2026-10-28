// T35 — the composer's five rules, each against a fake service and a recording sink. No network, no
// real clock, no GRDB: the debounces are zero and the draft store is the in-memory one, so what is
// asserted is the behaviour the card names, not the latency of a host.
//
//   1. optimistic, then reconciled (by `pending_post_id`, never by message text);
//   2. a failed send keeps the words, on screen and on disk, and is retryable;
//   3. the draft is the durable record: per channel, per thread root, flushed on demand;
//   4. autocomplete cannot race itself, and a mention respects channel membership;
//   5. uploads report real progress, cancel for real, and retry the same bytes.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (`app/components/post_draft/`,
// `app/screens/edit_post/`); licence Apache-2.0, see docs/THIRD_PARTY_NOTICES.md §12.

import Combine
import XCTest
@testable import Mattermost

@MainActor
final class T35ComposerViewModelTests: XCTestCase {

    private let channelID = "chan-1"

    // MARK: - Fakes

    /// The service seam. Every answer is scripted, including how long it takes, which is what makes
    /// the stale-autocomplete test deterministic instead of a race the host decides.
    @MainActor
    final class FakeComposerService: ComposerServing {
        var createResults: [Result<MMPost, Error>] = []
        var createDelay: Duration = .zero
        var patchResults: [Result<MMPost, Error>] = []
        var deleteError: Error?
        var uploadResult: Result<MMFileInfo, Error> = .success(
            MMFileInfo(id: "file-1", postId: "", name: "a.png", fileExtension: "png",
                       mimeType: "image/png", size: 3))
        /// How long `upload` stays suspended before it answers, so a cancel can land mid-flight.
        var uploadDelay: Duration = .zero
        /// How long `users` waits for a given term.
        var userDelays: [String: Duration] = [:]
        var userResults: [String: [MMUser]] = [:]
        var channelResults: [MMChannel] = []
        var members: ComposerMembership.MemberList = .unknown
        var memberListError: Error?
        var meResult = MMUser(id: "u1", username: "me")

        private(set) var createBodies: [ComposerPostBody] = []
        private(set) var patchedIDs: [(id: String, message: String, fileIDs: [String])] = []
        private(set) var deletedIDs: [String] = []
        private(set) var userTerms: [String] = []
        private(set) var channelTerms: [(term: String, teamID: String)] = []
        private(set) var uploadedChannelIDs: [String] = []
        private(set) var uploadedFilenames: [String] = []
        private(set) var uploadAttempts = 0
        /// The terms the composer asked about, as signals: a test awaits "the first request left" or "the
        /// newer term's answer" instead of polling `userTerms` / `channelTerms` (kanban t_00fb623c).
        let userTermSignal = TestSignal<String>()
        /// `"term|teamID"`, so the value is a plain `String` (tuples are not generic arguments).
        let channelTermSignal = TestSignal<String>()

        func createPost(_ body: ComposerPostBody) async throws -> MMPost {
            createBodies.append(body)
            if createDelay > .zero { try? await Task.sleep(for: createDelay) }
            guard !createResults.isEmpty else { throw MMError.offline }
            let slot = min(createBodies.count - 1, createResults.count - 1)
            switch createResults[slot] {
            case .success(let post): return post
            case .failure(let error): throw error
            }
        }

        func patchPost(id: String, message: String, fileIDs: [String]) async throws -> MMPost {
            patchedIDs.append((id, message, fileIDs))
            guard !patchResults.isEmpty else { throw MMError.offline }
            switch patchResults[min(patchedIDs.count - 1, patchResults.count - 1)] {
            case .success(let post): return post
            case .failure(let error): throw error
            }
        }

        func deletePost(id: String) async throws {
            deletedIDs.append(id)
            if let deleteError { throw deleteError }
        }

        func upload(_ upload: ComposerUpload,
                    channelID: String,
                    onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> MMFileInfo {
            uploadAttempts += 1
            uploadedChannelIDs.append(channelID)
            uploadedFilenames.append(upload.filename)
            onProgress(1, 3)
            if uploadDelay > .zero {
                do {
                    try await Task.sleep(for: uploadDelay)
                } catch {
                    // The production transport maps a cancelled task to `MMError.cancelled`; the fake
                    // does the same so the view model's cancel branch is the one under test.
                    throw MMError.cancelled
                }
            }
            switch uploadResult {
            case .success(let info):
                onProgress(3, 3)
                return info
            case .failure(let error):
                throw error
            }
        }

        func users(term: String, channelID: String, teamID: String?, limit: Int) async throws -> [MMUser] {
            userTerms.append(term)
            userTermSignal.send(term)
            if let delay = userDelays[term] { try? await Task.sleep(for: delay) }
            return userResults[term] ?? []
        }

        func channels(term: String, teamID: String, limit: Int) async throws -> [MMChannel] {
            channelTerms.append((term, teamID))
            channelTermSignal.send("\(term)|\(teamID)")
            return channelResults
        }

        func channelMembers(channelID: String) async throws -> ComposerMembership.MemberList {
            if let memberListError { throw memberListError }
            return members
        }

        func me() async throws -> MMUser { meResult }
    }

    /// Records what the composer asked the list to do.
    @MainActor
    final class RecordingSink: ComposerPostSink {
        var inserted: [MMPost] = []
        var confirmed: [(id: String, post: MMPost)] = []
        var removed: [String] = []
        var replaced: [MMPost] = []
        var tombstoned: [String] = []
        /// A post that "already arrived" for these client ids (the retry-once case).
        var landed: [String: MMPost] = [:]
        /// Set for the sink that stands in for `ThreadViewModel`: the composer's reply-mode invariant
        /// (kanban t_56159748) keys off exactly this, so the double must be able to claim to be a
        /// thread's list.
        let threadAnchor: ComposerThreadAnchor?

        init(threadAnchor: ComposerThreadAnchor? = nil) {
            self.threadAnchor = threadAnchor
        }

        func insertPendingPost(_ post: MMPost) { inserted.append(post) }
        func confirmPendingPost(id: String, with post: MMPost) { confirmed.append((id, post)) }
        func removePendingPost(id: String) { removed.append(id) }
        func replacePost(_ post: MMPost) { replaced.append(post) }
        func tombstonePost(id: String) { tombstoned.append(id) }
        func post(withPendingID pendingID: String) -> MMPost? { landed[pendingID] }
    }

    /// The in-memory draft store behind a signal, so "the keystroke is on disk" is a value the store
    /// recorded rather than a poll of `drafts.load(...)` (kanban t_00fb623c).
    ///
    /// Behaviour is the product store's — every call is delegated to it — so the draft rules under test
    /// still run against the real implementation; only the observation is added.
    @MainActor
    final class SignallingDraftStore: ComposerDraftStoring {
        private let inner = InMemoryComposerDraftStore()
        /// Each write, as the draft that landed (`nil` for a delete).
        let writeSignal = TestSignal<ComposerDraft?>()

        var count: Int { inner.count }

        func load(channelID: String, rootID: String) async -> ComposerDraft? {
            await inner.load(channelID: channelID, rootID: rootID)
        }

        func save(_ draft: ComposerDraft) async {
            await inner.save(draft)
            writeSignal.send(draft.isEmpty ? nil : draft)
        }

        func delete(channelID: String, rootID: String) async {
            await inner.delete(channelID: channelID, rootID: rootID)
            writeSignal.send(nil)
        }

        func allDrafts(limit: Int) async -> [ComposerDraft] { await inner.allDrafts(limit: limit) }

        func clear() async { await inner.clear() }
    }

    private var service: FakeComposerService!
    private var sink: RecordingSink!
    private var drafts: SignallingDraftStore!
    private var model: ComposerViewModel!
    /// The thread doubles this test built (`makeThreadComposer`); held here because a composer's sink
    /// is weak.
    private var threadSinks: [RecordingSink] = []
    /// Live subscriptions that mirror the model's publishers into signals; kept for the test's lifetime.
    private var mirrors: [AnyCancellable] = []

    override func setUp() async throws {
        service = FakeComposerService()
        sink = RecordingSink()
        drafts = SignallingDraftStore()
        mirrors.removeAll()
        threadSinks.removeAll()
        model = ComposerViewModel(channelID: channelID, service: service, drafts: drafts,
                                  sink: sink, teamID: "team-1", myUserID: "u1",
                                  autocompleteDebounce: .zero)
    }

    // MARK: - Signals

    /// The first attachment's state, as the model publishes it — so "the upload finished" / "uploading" /
    /// "failed" are awaited values instead of a poll of `model.attachments` (kanban t_00fb623c).
    private func attachmentStates() -> TestSignal<ComposerAttachment.State?> {
        let signal = TestSignal<ComposerAttachment.State?>()
        mirrors.append(mirrorPublished(model.$attachments, into: signal) { $0.first?.state })
        return signal
    }

    /// Whether the suggestion list has anything in it, as the model publishes it.
    private func suggestionsSignal() -> TestSignal<Bool> {
        let signal = TestSignal<Bool>()
        mirrors.append(mirrorPublished(model.$suggestions, into: signal) { !$0.isEmpty })
        return signal
    }

    /// The suggestion values for one kind, in the order the model published them.
    private func suggestionValues(_ kind: ComposerSuggestion.Kind) -> TestSignal<[String]> {
        let signal = TestSignal<[String]>()
        mirrors.append(mirrorPublished(model.$suggestions, into: signal) { suggestions in
            suggestions.filter { $0.kind == kind }.map(\.value)
        })
        return signal
    }

    private func serverPost(id: String, message: String, rootID: String = "",
                            at millis: Int64 = 1_700_000_000_000) -> MMPost {
        MMPost(id: id, createAt: millis, userId: "u1", channelId: channelID, rootId: rootID,
               message: message)
    }

    /// Let the model's fire-and-forget tasks run — the success path's draft delete is one, and a
    /// test that asserts "no delete happened" has to give a wrong one the chance to happen.
    private func drainMainActorTurns(_ rounds: Int = 50) async {
        for _ in 0..<rounds { await Task.yield() }
    }

    // MARK: - 1. Send, optimistically

    func testSendInsertsAPendingRowThenReplacesItWithTheServersPost() async {
        let created = serverPost(id: "p1", message: "hello there")
        service.createResults = [.success(created)]

        model.textChanged("hello there", caret: 11)
        XCTAssertTrue(model.canSend)
        await model.send()

        // The optimistic row went in first, with a client id the server will echo…
        guard let optimistic = sink.inserted.first else {
            return XCTFail("the composer must insert an optimistic row before it asks the server")
        }
        XCTAssertEqual(optimistic.id, optimistic.pendingPostId)
        XCTAssertTrue(optimistic.id.hasPrefix("pending:"))
        // …and the body carried that same id, which is the whole reconciliation mechanism.
        XCTAssertEqual(service.createBodies.count, 1)
        XCTAssertEqual(service.createBodies[0].pendingPostId, optimistic.id)
        XCTAssertEqual(service.createBodies[0].message, "hello there")

        // The answer replaced the row rather than adding a second one.
        XCTAssertEqual(sink.confirmed.count, 1)
        XCTAssertEqual(sink.confirmed[0].id, optimistic.id)
        XCTAssertEqual(sink.confirmed[0].post.id, "p1")
        XCTAssertTrue(sink.removed.isEmpty)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.text, "")
    }

    func testASecondSendIsRefusedWhileTheFirstIsInFlight() async {
        let created = serverPost(id: "p1", message: "hello")
        service.createResults = [.success(created)]
        service.createDelay = .milliseconds(80)

        model.textChanged("hello", caret: 5)
        let sending = TestSignal<Bool>()
        mirrors.append(mirrorPublished(model.$phase, into: sending) { $0 == .sending })
        let first = Task { await self.model.send() }
        await awaitSignal("the create to be in flight", signal: sending) { $0 }
        await model.send()          // must be a no-op: `canSend` is false while sending
        await first.value

        XCTAssertEqual(service.createBodies.count, 1)
    }

    func testTextIsTrimmedBeforeItIsSentAndBlankTextIsNotSent() async {
        service.createResults = [.success(serverPost(id: "p1", message: "hi"))]
        model.textChanged("   \n  ", caret: 6)
        XCTAssertFalse(model.canSend)
        await model.send()
        XCTAssertTrue(service.createBodies.isEmpty)

        model.textChanged("\n  hi \n", caret: 7)
        await model.send()
        XCTAssertEqual(service.createBodies.first?.message, "hi")
    }

    // MARK: - 2. A failure keeps the words

    func testAFailedSendRemovesThePendingRowAndKeepsTheTextAndTheDraft() async {
        service.createResults = [.failure(MMError.timeout)]
        model.textChanged("do not lose me", caret: 14)
        await model.send()

        XCTAssertEqual(sink.inserted.count, 1)
        XCTAssertEqual(sink.removed.count, 1)
        XCTAssertEqual(sink.removed[0], sink.inserted[0].id)
        XCTAssertEqual(sink.confirmed.count, 0)
        // The words are still in the composer…
        XCTAssertEqual(model.text, "do not lose me")
        XCTAssertEqual(model.phase, .failed(ComposerErrorCopy.message(for: MMError.timeout)))
        // …and on disk, written immediately rather than waiting for the debounce.
        let stored = await drafts.load(channelID: channelID, rootID: "")
        XCTAssertEqual(stored?.message, "do not lose me")
        XCTAssertTrue(model.hasPendingCommand)
    }

    func testTypingAfterAFailureClearsTheError() async {
        service.createResults = [.failure(MMError.offline)]
        model.textChanged("hi", caret: 2)
        await model.send()
        guard case .failed = model.phase else { return XCTFail("expected a failure phase") }
        model.textChanged("hi again", caret: 8)
        XCTAssertEqual(model.phase, .idle)
    }

    func testRetryReSendsTheSameClientId() async {
        service.createResults = [.failure(MMError.timeout), .success(serverPost(id: "p1", message: "hi"))]
        model.textChanged("hi", caret: 2)
        await model.send()
        let firstID = service.createBodies[0].pendingPostId
        await model.retry()

        XCTAssertEqual(service.createBodies.count, 2)
        // The same `pending_post_id` on both attempts: a retry is the same send, so a server that
        // only echoed the first one cannot produce two rows.
        XCTAssertEqual(service.createBodies[1].pendingPostId, firstID)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.text, "")
    }

    func testRetryDoesNotPostAgainIfTheMessageActuallyLanded() async {
        service.createResults = [.failure(MMError.timeout)]
        model.textChanged("hi", caret: 2)
        await model.send()
        let pendingID = service.createBodies[0].pendingPostId!
        // The socket told the list about the post even though the request failed.
        sink.landed[pendingID] = serverPost(id: "p1", message: "hi")

        await model.retry()

        XCTAssertEqual(service.createBodies.count, 1, "a landed post must not be posted twice")
        XCTAssertEqual(sink.confirmed.count, 1)
        XCTAssertEqual(sink.confirmed[0].post.id, "p1")
        XCTAssertEqual(model.phase, .idle)
    }

    // MARK: - 3. Drafts

    func testTheDraftIsWrittenOnTypingAndRestoredByANewComposer() async {
        model.textChanged("half a thought", caret: 14)
        await awaitSignal("the debounced draft write", signal: drafts.writeSignal) {
            $0?.message == "half a thought"
        }
        let stored = await drafts.load(channelID: channelID, rootID: "")
        XCTAssertEqual(stored?.message, "half a thought", "the draft is on the store")

        // A relaunch: a brand-new model over the same store.
        let reopened = ComposerViewModel(channelID: channelID, service: service, drafts: drafts,
                                         sink: RecordingSink(), autocompleteDebounce: .zero)
        await reopened.restoreDraftIfNeeded()
        XCTAssertEqual(reopened.text, "half a thought")
        XCTAssertEqual(reopened.caret, 14)
    }

    /// T35 run 124: a process killed inside the old debounce window lost the draft — the app's
    /// SQLite file had an empty `draft` table after typing and killing it, and a follow-up run
    /// restored the first *character* only, because that was the single write that had landed. The
    /// write is now write-through with coalescing, so this asserts the property that matters: the
    /// text is on disk as soon as the keystroke has been handled, with no timer in between.
    func testEveryKeystrokeIsOnDiskWithoutWaitingForATimer() async {
        model.textChanged("k", caret: 1)
        await awaitSignal("the first keystroke's write", signal: drafts.writeSignal) { $0?.message == "k" }
        // A burst: each change is in the store as soon as its write lands, the last one included.
        for length in 2...12 {
            let text = String("keep me and".prefix(length))
            model.textChanged(text, caret: length)
        }
        await awaitSignal("the last keystroke's write", signal: drafts.writeSignal) {
            $0?.message == "keep me and"
        }
        // A relaunch reads exactly what was typed, from a brand-new model over the same store.
        let reopened = ComposerViewModel(channelID: channelID, service: service, drafts: drafts,
                                         sink: RecordingSink(), autocompleteDebounce: .zero)
        await reopened.restoreDraftIfNeeded()
        XCTAssertEqual(reopened.text, "keep me and")
    }

    func testClearingTheTextDeletesTheDraftRow() async {
        model.textChanged("typing", caret: 6)
        await model.saveDraftNow()
        let saved = await drafts.load(channelID: channelID, rootID: "")
        XCTAssertNotNil(saved)

        model.textChanged("", caret: 0)
        await model.saveDraftNow()
        let cleared = await drafts.load(channelID: channelID, rootID: "")
        XCTAssertNil(cleared)
        XCTAssertEqual(drafts.count, 0)
    }

    func testAThreadDraftIsSeparateFromTheChannelsDraft() async {
        model.textChanged("channel thought", caret: 15)
        await model.saveDraftNow()

        model.beginReply(to: serverPost(id: "root-1", message: "root"), authorLabel: "Ada")
        model.textChanged("thread thought", caret: 13)
        await model.saveDraftNow()

        let channelDraft = await drafts.load(channelID: channelID, rootID: "")
        let threadDraft = await drafts.load(channelID: channelID, rootID: "root-1")
        XCTAssertEqual(channelDraft?.message, "channel thought")
        XCTAssertEqual(threadDraft?.message, "thread thought")

        // Leaving reply mode writes the thread draft, then restores the channel's.
        await model.cancelMode()
        XCTAssertEqual(model.text, "channel thought")
        XCTAssertEqual(model.mode, .newPost)
    }

    func testARestoredDraftDoesNotOverwriteTextThePersonHasTypedSince() async {
        await drafts.save(ComposerDraft(channelID: channelID, message: "old draft", updateAt: 1))
        model.textChanged("new words", caret: 9)
        await model.restoreDraftIfNeeded()
        XCTAssertEqual(model.text, "new words")
    }

    func testASuccessfulSendClearsTheDraftRow() async {
        service.createResults = [.success(serverPost(id: "p1", message: "gone"))]
        model.textChanged("gone", caret: 4)
        await model.saveDraftNow()
        await model.send()
        // The clear is fire-and-forget on success: the store's own delete is the signal that it landed.
        await awaitSignal("the draft row to be deleted", signal: drafts.writeSignal) { $0 == nil }
        let cleared = await drafts.load(channelID: channelID, rootID: "")
        XCTAssertNil(cleared, "the draft row is gone")
    }

    // MARK: - Edit and delete

    func testEditingSendsAPatchForTheSamePostAndKeepsItsFiles() async {
        var post = serverPost(id: "p1", message: "before")
        post.fileIds = ["f1", "f2"]
        service.patchResults = [.success(serverPost(id: "p1", message: "after"))]

        await model.beginEditing(post)
        XCTAssertEqual(model.mode, .editing(postID: "p1"))
        XCTAssertEqual(model.text, "before")
        XCTAssertEqual(model.caret, 6)

        model.textChanged("after", caret: 5)
        await model.send()

        XCTAssertEqual(service.patchedIDs.count, 1)
        XCTAssertEqual(service.patchedIDs[0].id, "p1")
        XCTAssertEqual(service.patchedIDs[0].message, "after")
        // `PUT /posts/{id}` replaces the file list, so the post's own ids must be sent back.
        XCTAssertEqual(service.patchedIDs[0].fileIDs, ["f1", "f2"])
        XCTAssertEqual(sink.replaced.first?.message, "after")
        XCTAssertEqual(model.mode, .newPost)
        XCTAssertEqual(model.text, "")
    }

    func testAFailedEditKeepsTheEditedText() async {
        service.patchResults = [.failure(MMError.timeout)]
        await model.beginEditing(serverPost(id: "p1", message: "before"))
        model.textChanged("after", caret: 5)
        await model.send()
        XCTAssertEqual(model.text, "after")
        XCTAssertTrue(model.canSend, "a failed edit must be retryable without retyping")
        XCTAssertEqual(model.mode, .editing(postID: "p1"))
        guard case .failed = model.phase else { return XCTFail("expected a failure phase") }
    }

    // MARK: - Edit mode owns no draft (kanban t_50a0f378)
    //
    // `draftRootID` used to be `mode.rootID`, which is `""` for `.editing` — and `""` is the
    // **channel's** own draft row. So the edit box was silently reading, overwriting and deleting a
    // half-written channel message. The falsifier the card names has two halves and both are below:
    // typing in an edit must leave the channel's draft alone (and Cancel must restore it), and a
    // landed edit must not delete it.

    /// What makes the rest of this section structural rather than defensive: the edit box addresses
    /// no row at all, and every mode that owns one still says which.
    func testAnEditHasNoDraftKeyAtAll() async {
        XCTAssertEqual(model.draftRootID, "", "a channel composer owns the channel's own row")
        model.beginReply(to: serverPost(id: "root-1", message: "root"), authorLabel: "Ada")
        XCTAssertEqual(model.draftRootID, "root-1")
        await model.beginEditing(serverPost(id: "p1", message: "before"))
        XCTAssertNil(model.draftRootID, "an edit has no draft: the post itself is the record")
        await model.cancelMode()
        XCTAssertEqual(model.draftRootID, "", "and leaving it goes back to the channel's row")

        let (threadComposer, _) = makeThreadComposer()
        await threadComposer.beginEditing(serverPost(id: "r1", message: "before", rootID: "root-1"))
        XCTAssertNil(threadComposer.draftRootID, "a thread's edit box owns no row either")
    }

    /// Falsifier, half one — the write path. A reader with a half-written channel message who edits
    /// any post used to lose it on the first keystroke in the edit box.
    func testTypingInAnEditNeverTouchesTheChannelsDraftRow() async {
        model.textChanged("half a thought", caret: 14)
        await model.saveDraftNow()

        await model.beginEditing(serverPost(id: "p1", message: "the post being edited"))
        model.textChanged("the post being edited — now changed", caret: 35)
        await model.saveDraftNow()          // what backgrounding does
        await drainMainActorTurns()

        let written = drafts.writeSignal.recorded.compactMap { $0 }
        XCTAssertTrue(written.filter { $0.message.contains("changed") }.isEmpty,
                      "an edit must not write the post's text into a draft row at all")
        let channelDraft = await drafts.load(channelID: channelID, rootID: "")
        XCTAssertEqual(channelDraft?.message, "half a thought",
                       "the channel's unsent message is exactly what it was")
    }

    /// Falsifier, half one — end to end, and the form the card asks for: seed the draft, edit, type,
    /// cancel, **reopen the channel**. The composer must show the original draft and never the text
    /// of the post that was being edited.
    func testCancellingAnEditRestoresTheChannelsOwnDraft() async {
        model.textChanged("half a thought", caret: 14)
        await model.beginEditing(serverPost(id: "p1", message: "the post being edited"))
        model.textChanged("the post being edited, cut short", caret: 30)
        await model.cancelMode()

        XCTAssertEqual(model.mode, .newPost)
        XCTAssertEqual(model.text, "half a thought", "Cancel returns to the channel's draft")
        XCTAssertEqual(model.caret, 14)

        // "Reopen the channel": a brand-new composer over the same store.
        let reopened = ComposerViewModel(channelID: channelID, service: service, drafts: drafts,
                                         sink: RecordingSink(), autocompleteDebounce: .zero)
        await reopened.restoreDraftIfNeeded()
        XCTAssertEqual(reopened.text, "half a thought")
    }

    /// The read path: the view's `.task` can land after edit mode was entered, and it must not put
    /// the channel's half-written message into the box that holds the post being edited.
    func testRestoringADraftNeverFillsTheEditBox() async {
        model.textChanged("half a thought", caret: 14)
        await model.saveDraftNow()

        await model.beginEditing(serverPost(id: "p1", message: "the post being edited"))
        await model.restoreDraftIfNeeded()
        XCTAssertEqual(model.text, "the post being edited")
    }

    /// Falsifier, half two — the delete path. A landed edit used to resolve `draftRoot == ""` and
    /// delete the channel's row with it.
    func testASuccessfulEditKeepsTheChannelsDraftRow() async {
        service.patchResults = [.success(serverPost(id: "p1", message: "after"))]
        model.textChanged("half a thought", caret: 14)
        await model.saveDraftNow()

        await model.beginEditing(serverPost(id: "p1", message: "before"))
        model.textChanged("after", caret: 5)
        await model.send()
        await drainMainActorTurns()         // the success path's delete is fire-and-forget

        XCTAssertEqual(service.patchedIDs.count, 1)
        let channelDraft = await drafts.load(channelID: channelID, rootID: "")
        XCTAssertEqual(channelDraft?.message, "half a thought",
                       "sending an edit must not delete the channel's unsent message")
    }

    /// The flush `beginEditing` owes the mode it is leaving: text typed a moment ago may still be
    /// sitting in the write pipeline when the edit starts, and after the switch it has no key to be
    /// written under. (Before this card that queued write clobbered the row instead of being
    /// dropped — both are data loss.)
    func testBeginEditingFlushesAChannelDraftThatWasStillQueued() async {
        model.textChanged("typed and not yet written", caret: 26)
        await model.beginEditing(serverPost(id: "p1", message: "before"))
        let channelDraft = await drafts.load(channelID: channelID, rootID: "")
        XCTAssertEqual(channelDraft?.message, "typed and not yet written")
    }

    /// The same two paths in a thread pane, which is how the defect surfaced: the thread composer
    /// survives edit mode there (t_56159748), so its edit box could reach the contaminated key.
    func testATypedThreadDraftSurvivesAnEditInTheThreadPane() async {
        let (threadComposer, _) = makeThreadComposer()
        threadComposer.textChanged("thread thought", caret: 13)
        await threadComposer.saveDraftNow()

        await threadComposer.beginEditing(serverPost(id: "r1", message: "before",
                                                     rootID: "root-1"))
        threadComposer.textChanged("before, changed", caret: 15)
        // The write runs while the box is still an edit box — the ordering that made it address the
        // channel's `""` row.
        await drainMainActorTurns()
        await threadComposer.cancelMode()
        await drainMainActorTurns()

        let threadDraft = await drafts.load(channelID: channelID, rootID: "root-1")
        let channelRow = await drafts.load(channelID: channelID, rootID: "")
        XCTAssertEqual(threadDraft?.message, "thread thought")
        XCTAssertEqual(threadComposer.text, "thread thought",
                       "Cancel lands back on the thread's own draft")
        XCTAssertNil(channelRow, "and never on a channel row")
    }

    /// A landed edit leaves **every** draft row alone: the thread's own, and the channel's (which
    /// this composer cannot even see — the defect reached it anyway, through `""`).
    func testASuccessfulEditInAThreadKeepsTheThreadsAndTheChannelsDrafts() async {
        let (threadComposer, _) = makeThreadComposer()
        service.patchResults = [.success(serverPost(id: "r1", message: "after", rootID: "root-1"))]
        await drafts.save(ComposerDraft(channelID: channelID, message: "channel thought", updateAt: 1))
        threadComposer.textChanged("thread thought", caret: 13)
        await threadComposer.saveDraftNow()

        await threadComposer.beginEditing(serverPost(id: "r1", message: "before",
                                                     rootID: "root-1"))
        threadComposer.textChanged("after", caret: 5)
        await threadComposer.send()
        await drainMainActorTurns()

        let threadDraft = await drafts.load(channelID: channelID, rootID: "root-1")
        let channelDraft = await drafts.load(channelID: channelID, rootID: "")
        XCTAssertEqual(threadDraft?.message, "thread thought")
        XCTAssertEqual(channelDraft?.message, "channel thought",
                       "an edit inside a thread must not delete the channel composer's draft either")
    }

    func testDeletingAsksTheListToTombstoneTheRow() async {
        await model.delete(postID: "p1")
        XCTAssertEqual(service.deletedIDs, ["p1"])
        XCTAssertEqual(sink.tombstoned, ["p1"])
        XCTAssertEqual(model.statusNote, "Message deleted")
    }

    func testAFailedDeleteSaysSoAndLeavesTheRowAlone() async {
        service.deleteError = MMError.forbidden(message: nil)
        await model.delete(postID: "p1")
        XCTAssertTrue(sink.tombstoned.isEmpty)
        XCTAssertEqual(model.statusNote, ComposerErrorCopy.message(for: MMError.forbidden(message: nil)))
    }

    // MARK: - Reply mode

    func testAReplyCarriesTheRootIdAndIsNotDrawnInTheChannelList() async {
        let created = serverPost(id: "r1", message: "in the thread", rootID: "root-1")
        service.createResults = [.success(created)]

        model.beginReply(to: serverPost(id: "root-1", message: "root"), authorLabel: "Ada Lovelace")
        XCTAssertEqual(model.replyTarget, "Ada Lovelace")
        model.textChanged("in the thread", caret: 12)
        await model.send()

        XCTAssertEqual(service.createBodies.first?.rootId, "root-1")
        // A reply is the thread pane's row (S13/T36): an optimistic row here could never reconcile.
        XCTAssertTrue(sink.inserted.isEmpty)
        XCTAssertEqual(sink.confirmed.count, 1)
        XCTAssertEqual(model.statusNote, "Reply sent to the thread")
        XCTAssertEqual(model.mode, .newPost)
    }

    // MARK: - Reply mode, in a thread (kanban t_56159748)

    /// The composer `ThreadCoordinator` caches: one instance per (channel, thread root), armed with
    /// `beginReply(to: root, authorLabel:)` when it is created — and never re-armed after that,
    /// because reuse only calls `attach(sink:)`. That lifecycle is what the report exposed.
    ///
    /// The sink is kept here for the test's lifetime: `ComposerViewModel.sink` is weak (the list owns
    /// the composer, not the other way round), so a double nothing else holds would leave the composer
    /// looking exactly like a channel composer.
    private func makeThreadComposer(rootID: String = "root-1",
                                    authorLabel: String = "Ada Lovelace")
        -> (composer: ComposerViewModel, sink: RecordingSink) {
        let threadSink = RecordingSink(threadAnchor: ComposerThreadAnchor(rootID: rootID,
                                                                          authorLabel: authorLabel))
        threadSinks.append(threadSink)
        let composer = ComposerViewModel(channelID: channelID, service: service, drafts: drafts,
                                         sink: threadSink, teamID: "team-1", myUserID: "u1",
                                         autocompleteDebounce: .zero)
        composer.beginReply(to: serverPost(id: rootID, message: "root"), authorLabel: authorLabel)
        return (composer, threadSink)
    }

    /// The report itself: "I replied to a thread but the message was sent to the channel."
    ///
    /// Reproduced from code: the first reply carried `root_id`, the second did not — the composer had
    /// silently dropped to `.newPost` and created a top-level channel post, twice over the same pane.
    func testASecondReplyFromTheSameThreadComposerStillCarriesTheRootID() async {
        let (threadComposer, threadSink) = makeThreadComposer()
        service.createResults = [.success(serverPost(id: "r1", message: "one", rootID: "root-1")),
                                 .success(serverPost(id: "r2", message: "two", rootID: "root-1"))]

        threadComposer.textChanged("one", caret: 3)
        await threadComposer.send()
        threadComposer.textChanged("two", caret: 3)
        await threadComposer.send()

        XCTAssertEqual(service.createBodies.count, 2)
        XCTAssertEqual(service.createBodies.map(\.rootId), ["root-1", "root-1"],
                       "every send from a thread pane is a reply — the second one included")
        XCTAssertEqual(threadSink.confirmed.map(\.post.rootId), ["root-1", "root-1"])
    }

    /// The mode, not just the request body: what makes the defect recur is the composer's *state*, and
    /// a thread composer's steady state is reply mode on its sink's root.
    func testAThreadComposerIsStillInReplyModeAfterASend() async {
        let (threadComposer, _) = makeThreadComposer()
        service.createResults = [.success(serverPost(id: "r1", message: "hello", rootID: "root-1"))]

        threadComposer.textChanged("hello", caret: 5)
        await threadComposer.send()

        XCTAssertEqual(threadComposer.mode, .reply(rootID: "root-1"))
        // The banner still names who was addressed, and the draft key is the thread's, not the channel's.
        XCTAssertEqual(threadComposer.replyTarget, "Ada Lovelace")
        XCTAssertEqual(threadComposer.draftRootID, "root-1")
        XCTAssertEqual(threadComposer.statusNote, "Reply sent to the thread")
        XCTAssertTrue(threadComposer.isThreadComposer)
    }

    /// Defect 2: tapping Reply on a **reply** inside a thread used to pass that reply's own id as
    /// `root_id`. Mattermost nests one level only, so the request must carry the thread's root; only
    /// the banner's label names the tapped row's author.
    func testAReplyToANestedReplyCarriesTheThreadRootID() async throws {
        let threadService = FakeThreadService()
        threadService.root = serverPost(id: "root", message: "root")
        threadService.pages = [MMPostList(order: ["root", "r1"],
                                          posts: ["root": serverPost(id: "root", message: "root"),
                                                  "r1": serverPost(id: "r1", message: "a reply",
                                                                   rootID: "root", at: 200)])]
        let thread = ThreadViewModel(rootID: "root", channelID: channelID, teamID: "team-1",
                                     service: threadService)
        await thread.load()

        // The row the reader taps is a reply, not the root.
        let rows = thread.items.compactMap { item -> PostRowModel? in
            if case .post(let row) = item { return row }
            return nil
        }
        let tapped = try XCTUnwrap(rows.first { $0.post.id == "r1" },
                                   "the thread pane must draw r1")
        let target = try XCTUnwrap(thread.replyTarget(from: tapped))
        XCTAssertEqual(target.root.id, "root", "root_id is the thread's root, never the tapped reply")
        XCTAssertEqual(target.authorLabel, tapped.author.displayName,
                       "the banner still addresses the person whose row was tapped")

        service.createResults = [.success(serverPost(id: "r2", message: "nested", rootID: "root"))]
        let composer = ComposerViewModel(channelID: channelID, service: service, drafts: drafts,
                                         sink: thread, teamID: "team-1", myUserID: "u1",
                                         autocompleteDebounce: .zero)
        composer.beginReply(to: target.root, authorLabel: target.authorLabel)
        composer.textChanged("nested", caret: 6)
        await composer.send()

        XCTAssertEqual(service.createBodies.first?.rootId, "root")
        XCTAssertEqual(composer.mode, .reply(rootID: "root"))
    }

    /// The negative that keeps the fix honest: a channel composer's reply is **one** message, and the
    /// message after it is an ordinary channel post. Fixing defect 1 must not change this.
    func testTheChannelComposerGoesBackToChannelPostsAfterAReply() async {
        service.createResults = [.success(serverPost(id: "r1", message: "one", rootID: "root-1")),
                                 .success(serverPost(id: "p2", message: "two"))]

        model.beginReply(to: serverPost(id: "root-1", message: "root"), authorLabel: "Ada")
        model.textChanged("one", caret: 3)
        await model.send()
        XCTAssertEqual(model.mode, .newPost, "a channel reply is one message")

        model.textChanged("two", caret: 3)
        await model.send()
        XCTAssertEqual(service.createBodies.map(\.rootId), ["root-1", nil],
                       "the message after a channel reply is a top-level channel post")
    }

    /// The other caller the card asked about: the thread row menu's Edit is served by the *thread's*
    /// composer too, and a landed edit used to run the same "back to newPost" step — so editing a
    /// reply and then typing put the next message in the channel.
    func testAThreadComposerReturnsToReplyModeAfterAnEdit() async {
        let (threadComposer, _) = makeThreadComposer()
        service.patchResults = [.success(serverPost(id: "r1", message: "after", rootID: "root-1"))]

        await threadComposer.beginEditing(serverPost(id: "r1", message: "before", rootID: "root-1"))
        XCTAssertEqual(threadComposer.mode, .editing(postID: "r1"))
        threadComposer.textChanged("after", caret: 5)
        await threadComposer.send()

        XCTAssertEqual(threadComposer.mode, .reply(rootID: "root-1"),
                       "an edit inside a thread must not turn the box into a channel composer")
        XCTAssertEqual(threadComposer.replyTarget, "Ada Lovelace")
    }

    /// Cancel, from a thread's edit banner, goes back to the thread — and an abandoned edit is not a
    /// draft, so the post's words do not reappear in the channel's composer.
    func testCancellingAnEditInAThreadReturnsToTheThreadsReplyMode() async {
        let (threadComposer, _) = makeThreadComposer()
        await threadComposer.beginEditing(serverPost(id: "r1", message: "someone's words",
                                                    rootID: "root-1"))
        await threadComposer.cancelMode()

        XCTAssertEqual(threadComposer.mode, .reply(rootID: "root-1"))
        XCTAssertEqual(threadComposer.text, "")
        let channelDraft = await drafts.load(channelID: channelID, rootID: "")
        XCTAssertNil(channelDraft, "an abandoned edit is not the channel's draft")
    }

    // MARK: - 4. Autocomplete

    func testMentionsAreFilteredToTheChannelsMembers() async {
        service.userResults["ki"] = [MMUser(id: "u1", username: "kim"), MMUser(id: "u9", username: "kimbo")]
        service.members = ComposerMembership.MemberList(ids: ["u1"], isComplete: true)

        model.textChanged("@ki", caret: 3)
        await awaitSignal("the mention list", signal: suggestionsSignal()) { $0 }
        XCTAssertEqual(model.suggestions.filter { $0.kind == .user }.map(\.value), ["kim"])
        XCTAssertEqual(service.userTerms, ["ki"])
    }

    func testAFailedMemberListDoesNotHideAnyone() async {
        service.userResults["ki"] = [MMUser(id: "u9", username: "kimbo")]
        service.memberListError = MMError.timeout

        model.textChanged("@ki", caret: 3)
        await awaitSignal("the mention list", signal: suggestionsSignal()) { $0 }
        XCTAssertEqual(model.suggestions.filter { $0.kind == .user }.map(\.value), ["kimbo"])
    }

    func testAStaleAutocompleteAnswerIsDropped() async {
        service.userResults["ki"] = [MMUser(id: "u1", username: "kim")]
        service.userResults["kim"] = [MMUser(id: "u2", username: "kimb")]
        // The shorter term's request stays in flight (its sleep ignores cancellation, like a URL that
        // has already left the device), so its answer really does arrive — late. Without the
        // generation guard it would replace the list the person is actually looking at.
        service.userDelays["ki"] = .milliseconds(120)

        model.textChanged("@ki", caret: 3)
        await awaitSignal("the first request to leave", signal: service.userTermSignal) { $0 == "ki" }
        model.textChanged("@kim", caret: 4)
        await awaitSignal("the newer term's answer", signal: suggestionValues(.user)) {
            $0.contains("kimb")
        }
        // Absence window (pile b): the superseded answer arrives late, and there is no event for
        // "nothing changed" — a bounded settle is the only way to give the wrong write a chance.
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.suggestions.filter { $0.kind == .user }.map(\.value), ["kimb"])
    }

    func testChannelsComeFromTheTeamSearchAndInsertATilde() async {
        service.channelResults = [MMChannel(id: "c9", name: "town square", displayName: "Town Square")]
        model.textChanged("see #town", caret: 9)
        await awaitSignal("the channel list", signal: suggestionValues(.channel)) { !$0.isEmpty }
        let channel = model.suggestions.first { $0.kind == .channel }
        XCTAssertEqual(channel?.insertion, "~town-square")
        XCTAssertEqual(service.channelTerms.first?.teamID, "team-1")
    }

    func testEmojiComeFromTheBuiltInTableAndTheServersCatalogue() async {
        model.textChanged(":tad", caret: 4)
        await awaitSignal("the emoji list", signal: suggestionsSignal()) { $0 }
        XCTAssertEqual(model.suggestions.first?.value, "tada")
        XCTAssertEqual(model.suggestions.first?.insertion, ":tada:")

        // The second half of the name: the server's own catalogue is offered too. The page is a stub,
        // so a row here can only come from `identifiers` — a built-in table cannot produce it.
        let catalogue = EmojiCatalogue(loadPage: { _, _ in [MMEmoji(id: "e1", name: "t34parrot")] },
                                       loadImage: { _ in Data() })
        await catalogue.loadNamesIfNeeded()
        let withCatalogue = ComposerViewModel(channelID: channelID, service: service, drafts: drafts,
                                              sink: sink, teamID: "team-1", myUserID: "u1",
                                              emojiCatalogue: catalogue,
                                              autocompleteDebounce: .zero)
        let custom = TestSignal<Bool>()
        mirrors.append(mirrorPublished(withCatalogue.$suggestions, into: custom) { list in
            list.contains { $0.value == "t34parrot" }
        })
        withCatalogue.textChanged(":parrot", caret: 7)
        await awaitSignal("the custom emoji from the server catalogue", signal: custom) { $0 }
        XCTAssertEqual(withCatalogue.suggestions.first?.insertion, ":t34parrot:")
    }

    func testChoosingASuggestionRewritesTheTriggerAndReturnsTheCaret() {
        model.textChanged("hi @ki", caret: 6)
        let suggestion = ComposerSuggestion(kind: .user, value: "kim", label: "Kim", detail: "",
                                            insertion: "@kim", glyph: nil)
        let caret = model.apply(suggestion)
        XCTAssertEqual(model.text, "hi @kim ")
        XCTAssertEqual(caret, ("hi @kim " as NSString).length)
        XCTAssertNil(model.activeTrigger)
        XCTAssertTrue(model.suggestions.isEmpty)
    }

    // MARK: - 5. Uploads

    func testAnAttachmentUploadsWithProgressFromTheTransport() async {
        let states = attachmentStates()
        model.add(ComposerUpload(filename: "a.png", mimeType: "image/png", data: Data([1, 2, 3])))
        await awaitSignal("the upload to finish", signal: states) {
            if case .uploaded = $0 { return true }
            return false
        }

        let attachment = model.attachments[0]
        XCTAssertEqual(attachment.fileID, "file-1")
        XCTAssertEqual(attachment.filename, "a.png")
        XCTAssertEqual(service.uploadedChannelIDs, [channelID])
        XCTAssertEqual(model.uploadedFileIDs, ["file-1"])
        XCTAssertFalse(model.isUploading)
        // An uploaded file with no words is a sendable message (that is how a photo-only post works).
        XCTAssertTrue(model.canSend)
    }

    func testUploadProgressComesFromTheTransportsByteCount() async {
        service.uploadDelay = .milliseconds(200)
        let states = attachmentStates()
        model.add(ComposerUpload(filename: "a.png", mimeType: "image/png", data: Data([1, 2, 3])))
        // The transport reported 1 of 3 bytes; the row must show a fraction, not a spinner that
        // guesses. 1/3 is what the fake sent, so the number on screen is the number the stack gave.
        await awaitSignal("a progress report on the attachment", signal: states) {
            if case .uploading(let progress) = $0 { return progress > 0 }
            return false
        }
        if case .uploading(let progress) = states.recorded.last {
            XCTAssertEqual(progress, 1.0 / 3.0, accuracy: 0.001)
        } else {
            XCTFail("expected the attachment to be uploading, was \(String(describing: states.recorded.last))")
        }
        await awaitSignal("the upload to finish", signal: states) {
            if case .uploaded = $0 { return true }
            return false
        }
    }

    func testAnUploadedAttachmentLetsAnEmptyMessageBeSentAndRidesAlong() async {
        service.createResults = [.success(serverPost(id: "p1", message: ""))]
        let states = attachmentStates()
        model.add(ComposerUpload(filename: "a.png", mimeType: "image/png", data: Data([1, 2, 3])))
        await awaitSignal("the upload to finish", signal: states) {
            if case .uploaded = $0 { return true }
            return false
        }
        XCTAssertTrue(model.canSend)

        await model.send()
        XCTAssertEqual(service.createBodies.first?.fileIds, ["file-1"])
    }

    func testSendIsBlockedWhileAnUploadIsStillInFlight() async {
        service.uploadDelay = .milliseconds(150)
        let states = attachmentStates()
        model.add(ComposerUpload(filename: "a.png", mimeType: "image/png", data: Data([1])))
        model.textChanged("hi", caret: 2)
        XCTAssertFalse(model.canSend, "a message must not reference a file the server does not have yet")
        await awaitSignal("the upload to finish", signal: states) {
            if case .uploaded = $0 { return true }
            return false
        }
        XCTAssertTrue(model.canSend)
    }

    func testCancellingAnUploadReallyStopsItAndOffersRetry() async {
        service.uploadDelay = .seconds(10)
        let states = attachmentStates()
        model.add(ComposerUpload(filename: "a.png", mimeType: "image/png", data: Data([1])))
        let id = model.attachments[0].id
        await awaitSignal("the upload to start", signal: states) {
            if case .uploading = $0 { return true }
            return false
        }

        model.cancelUpload(id: id)
        XCTAssertEqual(model.attachments[0].state, .failed("Upload cancelled"))
        XCTAssertFalse(model.attachments[0].isUploading)

        // Retry re-sends the bytes the composer kept, without going back to the picker.
        service.uploadDelay = .zero
        model.retryUpload(id: id)
        await awaitSignal("the retried upload", signal: states) {
            if case .uploaded = $0 { return true }
            return false
        }
        XCTAssertEqual(service.uploadAttempts, 2)
        XCTAssertEqual(service.uploadedFilenames, ["a.png", "a.png"])
    }

    func testAFailedUploadIsReportedOnItsRow() async {
        service.uploadResult = .failure(MMError.timeout)
        let states = attachmentStates()
        model.add(ComposerUpload(filename: "a.png", mimeType: "image/png", data: Data([1])))
        await awaitSignal("the upload to fail", signal: states) {
            if case .failed = $0 { return true }
            return false
        }
        XCTAssertEqual(model.attachments.first?.state,
                       .failed(ComposerErrorCopy.message(for: MMError.timeout)))
        // The message text is untouched by an upload failure.
        XCTAssertFalse(model.isUploading)
    }

    func testRemovingAnAttachmentCancelsItAndDropsItFromTheDraft() async {
        service.uploadDelay = .seconds(10)
        let states = attachmentStates()
        model.add(ComposerUpload(filename: "a.png", mimeType: "image/png", data: Data([1])))
        let id = model.attachments[0].id
        await awaitSignal("the upload to start", signal: states) {
            if case .uploading = $0 { return true }
            return false
        }

        model.removeAttachment(id: id)
        XCTAssertTrue(model.attachments.isEmpty)
        await model.saveDraftNow()
        let stored = await drafts.load(channelID: channelID, rootID: "")
        XCTAssertNil(stored)
    }

    // MARK: - Preview and mode

    func testPreviewTogglesWithoutTouchingTheText() {
        model.textChanged("**bold**", caret: 8)
        model.togglePreview()
        XCTAssertTrue(model.isPreviewing)
        XCTAssertEqual(model.text, "**bold**")
        model.togglePreview()
        XCTAssertFalse(model.isPreviewing)
    }

    func testAMarkdownActionReturnsTheSelectionTheViewMustRestore() {
        model.textChanged("word", caret: 4)
        let selection = model.applyMarkdown(.bold, selection: NSRange(location: 0, length: 4))
        XCTAssertEqual(model.text, "**word**")
        XCTAssertEqual(selection, NSRange(location: 2, length: 4))
        XCTAssertEqual(model.caret, 6)
    }

    // MARK: - The clients own id

    func testTheAuthorIDIsWhoTheComposerWritesAs() {
        // The pane offers Edit/Delete only on my own posts; it asks the composer who that is.
        XCTAssertEqual(model.authorID, "u1")
    }
}
