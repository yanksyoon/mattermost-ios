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
            if let delay = userDelays[term] { try? await Task.sleep(for: delay) }
            return userResults[term] ?? []
        }

        func channels(term: String, teamID: String, limit: Int) async throws -> [MMChannel] {
            channelTerms.append((term, teamID))
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

        func insertPendingPost(_ post: MMPost) { inserted.append(post) }
        func confirmPendingPost(id: String, with post: MMPost) { confirmed.append((id, post)) }
        func removePendingPost(id: String) { removed.append(id) }
        func replacePost(_ post: MMPost) { replaced.append(post) }
        func tombstonePost(id: String) { tombstoned.append(id) }
        func post(withPendingID pendingID: String) -> MMPost? { landed[pendingID] }
    }

    private var service: FakeComposerService!
    private var sink: RecordingSink!
    private var drafts: InMemoryComposerDraftStore!
    private var model: ComposerViewModel!

    override func setUp() async throws {
        service = FakeComposerService()
        sink = RecordingSink()
        drafts = InMemoryComposerDraftStore()
        model = ComposerViewModel(channelID: channelID, service: service, drafts: drafts,
                                  sink: sink, teamID: "team-1", myUserID: "u1",
                                  autocompleteDebounce: .zero, draftDebounce: .zero)
    }

    private func serverPost(id: String, message: String, rootID: String = "",
                            at millis: Int64 = 1_700_000_000_000) -> MMPost {
        MMPost(id: id, createAt: millis, userId: "u1", channelId: channelID, rootId: rootID,
               message: message)
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
        let first = Task { await self.model.send() }
        await waitUntil("the create to be in flight") { self.model.phase == .sending }
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
        await waitUntil("the debounced draft write") {
            await self.drafts.load(channelID: self.channelID, rootID: "") != nil
        }

        // A relaunch: a brand-new model over the same store.
        let reopened = ComposerViewModel(channelID: channelID, service: service, drafts: drafts,
                                         sink: RecordingSink(), autocompleteDebounce: .zero,
                                         draftDebounce: .zero)
        await reopened.restoreDraftIfNeeded()
        XCTAssertEqual(reopened.text, "half a thought")
        XCTAssertEqual(reopened.caret, 14)
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
        // The clear is fire-and-forget on success; give it a turn to land.
        await waitUntil("the draft row to be deleted") {
            await self.drafts.load(channelID: self.channelID, rootID: "") == nil
        }
    }

    // MARK: - Edit and delete

    func testEditingSendsAPatchForTheSamePostAndKeepsItsFiles() async {
        var post = serverPost(id: "p1", message: "before")
        post.fileIds = ["f1", "f2"]
        service.patchResults = [.success(serverPost(id: "p1", message: "after"))]

        model.beginEditing(post)
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
        model.beginEditing(serverPost(id: "p1", message: "before"))
        model.textChanged("after", caret: 5)
        await model.send()
        XCTAssertEqual(model.text, "after")
        XCTAssertTrue(model.canSend, "a failed edit must be retryable without retyping")
        XCTAssertEqual(model.mode, .editing(postID: "p1"))
        guard case .failed = model.phase else { return XCTFail("expected a failure phase") }
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

    // MARK: - 4. Autocomplete

    func testMentionsAreFilteredToTheChannelsMembers() async {
        service.userResults["ki"] = [MMUser(id: "u1", username: "kim"), MMUser(id: "u9", username: "kimbo")]
        service.members = ComposerMembership.MemberList(ids: ["u1"], isComplete: true)

        model.textChanged("@ki", caret: 3)
        await waitUntil("the mention list") { !self.model.suggestions.isEmpty }
        XCTAssertEqual(model.suggestions.filter { $0.kind == .user }.map(\.value), ["kim"])
        XCTAssertEqual(service.userTerms, ["ki"])
    }

    func testAFailedMemberListDoesNotHideAnyone() async {
        service.userResults["ki"] = [MMUser(id: "u9", username: "kimbo")]
        service.memberListError = MMError.timeout

        model.textChanged("@ki", caret: 3)
        await waitUntil("the mention list") { !self.model.suggestions.isEmpty }
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
        await waitUntil("the first request to leave") { self.service.userTerms == ["ki"] }
        model.textChanged("@kim", caret: 4)
        await waitUntil("the newer term's answer") {
            self.model.suggestions.contains { $0.value == "kimb" }
        }
        // Give the superseded answer time to land, then confirm it changed nothing.
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.suggestions.filter { $0.kind == .user }.map(\.value), ["kimb"])
    }

    func testChannelsComeFromTheTeamSearchAndInsertATilde() async {
        service.channelResults = [MMChannel(id: "c9", name: "town square", displayName: "Town Square")]
        model.textChanged("see #town", caret: 9)
        await waitUntil("the channel list") {
            self.model.suggestions.contains { $0.kind == .channel }
        }
        let channel = model.suggestions.first { $0.kind == .channel }
        XCTAssertEqual(channel?.insertion, "~town-square")
        XCTAssertEqual(service.channelTerms.first?.teamID, "team-1")
    }

    func testEmojiComeFromTheBuiltInTableAndTheServersCatalogue() async {
        model.textChanged(":tad", caret: 4)
        await waitUntil("the emoji list") { !self.model.suggestions.isEmpty }
        XCTAssertEqual(model.suggestions.first?.value, "tada")
        XCTAssertEqual(model.suggestions.first?.insertion, ":tada:")
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
        model.add(ComposerUpload(filename: "a.png", mimeType: "image/png", data: Data([1, 2, 3])))
        await waitUntil("the upload to finish") { self.model.attachments.first?.isUploaded == true }

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
        model.add(ComposerUpload(filename: "a.png", mimeType: "image/png", data: Data([1, 2, 3])))
        // The transport reported 1 of 3 bytes; the row must show a fraction, not a spinner that
        // guesses. 1/3 is what the fake sent, so the number on screen is the number the stack gave.
        await waitUntil("a progress report on the attachment") {
            if case .uploading(let progress) = self.model.attachments.first?.state {
                return progress > 0
            }
            return false
        }
        if case .uploading(let progress) = model.attachments[0].state {
            XCTAssertEqual(progress, 1.0 / 3.0, accuracy: 0.001)
        } else {
            XCTFail("expected the attachment to be uploading, was \(model.attachments[0].state)")
        }
        await waitUntil("the upload to finish") { self.model.attachments.first?.isUploaded == true }
    }

    func testAnUploadedAttachmentLetsAnEmptyMessageBeSentAndRidesAlong() async {
        service.createResults = [.success(serverPost(id: "p1", message: ""))]
        model.add(ComposerUpload(filename: "a.png", mimeType: "image/png", data: Data([1, 2, 3])))
        await waitUntil("the upload to finish") { self.model.attachments.first?.isUploaded == true }
        XCTAssertTrue(model.canSend)

        await model.send()
        XCTAssertEqual(service.createBodies.first?.fileIds, ["file-1"])
    }

    func testSendIsBlockedWhileAnUploadIsStillInFlight() async {
        service.uploadDelay = .milliseconds(150)
        model.add(ComposerUpload(filename: "a.png", mimeType: "image/png", data: Data([1])))
        model.textChanged("hi", caret: 2)
        XCTAssertFalse(model.canSend, "a message must not reference a file the server does not have yet")
        await waitUntil("the upload to finish") { self.model.attachments.first?.isUploaded == true }
        XCTAssertTrue(model.canSend)
    }

    func testCancellingAnUploadReallyStopsItAndOffersRetry() async {
        service.uploadDelay = .seconds(10)
        model.add(ComposerUpload(filename: "a.png", mimeType: "image/png", data: Data([1])))
        let id = model.attachments[0].id
        await waitUntil("the upload to start") { self.model.attachments[0].isUploading }

        model.cancelUpload(id: id)
        XCTAssertEqual(model.attachments[0].state, .failed("Upload cancelled"))
        XCTAssertFalse(model.attachments[0].isUploading)

        // Retry re-sends the bytes the composer kept, without going back to the picker.
        service.uploadDelay = .zero
        model.retryUpload(id: id)
        await waitUntil("the retried upload") { self.model.attachments[0].isUploaded }
        XCTAssertEqual(service.uploadAttempts, 2)
        XCTAssertEqual(service.uploadedFilenames, ["a.png", "a.png"])
    }

    func testAFailedUploadIsReportedOnItsRow() async {
        service.uploadResult = .failure(MMError.timeout)
        model.add(ComposerUpload(filename: "a.png", mimeType: "image/png", data: Data([1])))
        await waitUntil("the upload to fail") {
            if case .failed = self.model.attachments.first?.state { return true }
            return false
        }
        XCTAssertEqual(model.attachments.first?.state,
                       .failed(ComposerErrorCopy.message(for: MMError.timeout)))
        // The message text is untouched by an upload failure.
        XCTAssertFalse(model.isUploading)
    }

    func testRemovingAnAttachmentCancelsItAndDropsItFromTheDraft() async {
        service.uploadDelay = .seconds(10)
        model.add(ComposerUpload(filename: "a.png", mimeType: "image/png", data: Data([1])))
        let id = model.attachments[0].id
        await waitUntil("the upload to start") { self.model.attachments[0].isUploading }

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
