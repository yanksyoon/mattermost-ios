// T4g — the composer's posting state: the state derivation, the socket patch, and the local refusal.
//
// Upstream reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560…), `app/components/post_draft/
// post_draft.tsx` (archive beats read-only), `post_draft/index.ts` (the derivation from
// `channel.deleteAt`, `observeIsReadOnlyChannel` and `observePermissionForChannel(… CREATE_POST)`),
// `post_draft/archived/index.tsx` and `post_draft/read_only/index.tsx` (the copy). Licence
// Apache-2.0, see docs/THIRD_PARTY_NOTICES.md §12.
//
// The file is in two halves, and they are deliberately separate:
//
//   * `ComposerPostingState.derive` is **pure**: no server, no clock, no view. Every combination the
//     pinned server can produce is a case below, including the two that must *not* draw a banner
//     (a permission lookup that never answered, and a read-only role set on an archived channel
//     where the archived copy wins);
//   * `ComposerViewModel` against a fake service, so "refused locally" is measured as "the fake saw
//     no create", not inferred from a missing row on screen.

import Combine
import XCTest
@testable import Mattermost

@MainActor
final class T4gPostingStateTests: XCTestCase {

    private let channelID = "chan-t4g"

    // MARK: - Fakes

    /// The posting-policy seam: answers whatever facts the test scripts, and records every ask so
    /// "no request" can be asserted as "the policy was not asked again".
    @MainActor
    final class FakePolicy: ComposerPostingPolicyServing {
        var answer: ComposerPostingFacts?
        private(set) var askedChannelIDs: [String] = []
        private(set) var askedTeamIDs: [String?] = []
        /// Fires once per ask, so a test can await the call rather than poll for it.
        let asked = TestSignal<String>()

        func facts(channelID: String, teamID: String?) async -> ComposerPostingFacts? {
            askedChannelIDs.append(channelID)
            askedTeamIDs.append(teamID)
            asked.send(channelID)
            return answer
        }
    }

    /// The composer's REST seam. Only the write paths are modelled: this card never reads posts, and
    /// a fake that cannot post is exactly what makes "no request was made" observable.
    @MainActor
    final class FakeService: ComposerServing {
        private(set) var createBodies: [ComposerPostBody] = []
        private(set) var patchCalls: [String] = []
        private(set) var deleteCalls: [String] = []
        private(set) var commandCalls: [String] = []
        var meResult = MMUser(id: "u1", username: "me")

        func createPost(_ body: ComposerPostBody) async throws -> MMPost {
            createBodies.append(body)
            return MMPost(id: "post-\(createBodies.count)",
                          userId: "u1",
                          channelId: body.channelId,
                          message: body.message)
        }

        func patchPost(id: String, message: String, fileIDs: [String]) async throws -> MMPost {
            patchCalls.append(id)
            return MMPost(id: id, userId: "u1", message: message)
        }

        func deletePost(id: String) async throws {
            deleteCalls.append(id)
        }

        func upload(_ upload: ComposerUpload,
                    channelID: String,
                    onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> MMFileInfo {
            MMFileInfo(id: "file-1", postId: "", name: upload.filename,
                       fileExtension: "txt", mimeType: upload.mimeType,
                       size: Int64(upload.data.count))
        }

        func me() async throws -> MMUser { meResult }

        func executeCommand(_ command: String, channelID: String, teamID: String?,
                            rootID: String?) async throws -> ComposerCommandResponse {
            commandCalls.append(command)
            return ComposerCommandResponse(responseType: "ephemeral", text: "")
        }
    }

    /// The draft seam. In memory, so a send's draft bookkeeping is exercised without GRDB.
    @MainActor
    final class MemoryDrafts: ComposerDraftStoring {
        private var rows: [String: ComposerDraft] = [:]
        func load(channelID: String, rootID: String) async -> ComposerDraft? {
            rows["\(channelID)/\(rootID)"]
        }
        func save(_ draft: ComposerDraft) async { rows["\(draft.channelID)/\(draft.rootID)"] = draft }
        func delete(channelID: String, rootID: String) async { rows["\(channelID)/\(rootID)"] = nil }
        func allDrafts(limit: Int) async -> [ComposerDraft] {
            Array(rows.values.sorted { $0.updateAt > $1.updateAt }.prefix(limit))
        }
        func clear() async { rows.removeAll() }
    }

    private func makeComposer(policy: FakePolicy? = nil,
                              service: FakeService? = nil,
                              drafts: MemoryDrafts? = nil) -> ComposerViewModel {
        ComposerViewModel(channelID: channelID,
                          service: service ?? FakeService(),
                          drafts: drafts ?? MemoryDrafts(),
                          teamID: "team-1",
                          myUserID: "u1",
                          posting: policy)
    }

    private func channel(deleteAt: Int64 = 0) -> MMChannel {
        MMChannel(id: channelID, name: "t4g-posting", displayName: "T4g Posting",
                  type: "O", teamId: "team-1", deleteAt: deleteAt)
    }

    /// A live channel whose roles carry `create_post` — the ordinary case.
    private var postingFacts: ComposerPostingFacts {
        ComposerPostingFacts(channel: channel(), permissions: [ChannelPermissionID.createPost])
    }

    // MARK: - 1. The derivation (pure)

    func testAnArchivedChannelDerivesTheArchivedStateAndUpstreamsCopy() {
        let state = ComposerPostingState.derive(ComposerPostingFacts(channel: channel(deleteAt: 1_700_000_000),
                                                                   permissions: [ChannelPermissionID.createPost]))
        XCTAssertEqual(state, .archived)
        XCTAssertFalse(state.canPost)
        XCTAssertEqual(state.message,
                       "You are viewing an archived channel. New messages cannot be posted.",
                       "the copy is upstream's `archivedChannelMessage`")
        XCTAssertEqual(state.identifier, "channelComposer.archivedBanner")
    }

    func testAMembershipWithoutCreatePostDerivesTheReadOnlyState() {
        // The scheme case: the roles answered, and `create_post` is not among their permissions.
        let state = ComposerPostingState.derive(ComposerPostingFacts(channel: channel(),
                                                                   permissions: [ChannelPermissionID.readChannel]))
        XCTAssertEqual(state, .readOnly)
        XCTAssertFalse(state.canPost)
        XCTAssertEqual(state.message, "This channel is read-only.",
                       "the copy is upstream's `mobile.create_post.read_only`")
        XCTAssertEqual(state.identifier, "channelComposer.readOnlyBanner")
    }

    func testCreatePostAmongTheRolesLeavesTheComposerOpen() {
        XCTAssertEqual(ComposerPostingState.derive(postingFacts), .open)
        XCTAssertTrue(ComposerPostingState.derive(postingFacts).canPost)
    }

    func testAnArchivedChannelIsArchivedEvenWhenTheRolesWouldAllowPosting() {
        // Upstream's precedence: `channelIsArchived` is answered before the permission is consulted,
        // so an administrator looking at an archived channel gets the archived copy — not the input
        // and not the read-only copy.
        let facts = ComposerPostingFacts(channel: channel(deleteAt: 42),
                                        permissions: Set(ChannelPermissionID.all))
        XCTAssertEqual(ComposerPostingState.derive(facts), .archived)
    }

    func testAnUnansweredPermissionLookupIsNotADenial() {
        // No answer (offline, a proxy that strips `/roles/names`): the composer stays open and the
        // server's own refusal is what the reader sees — the defect this card fixes, in reverse.
        let state = ComposerPostingState.derive(ComposerPostingFacts(channel: channel(), permissions: nil))
        XCTAssertEqual(state, .open)
        XCTAssertTrue(state.canPost)
        XCTAssertFalse(ComposerPostingState.deniesPosting(permissions: nil))
        XCTAssertTrue(ComposerPostingState.deniesPosting(permissions: [ChannelPermissionID.readChannel]))
    }

    func testAnAnsweredLookupWithoutCreatePostIsTheOnlyReadOnlyAnswer() {
        XCTAssertEqual(ComposerPostingState.derive(ComposerPostingFacts(channel: channel(),
                                                                      permissions: [])),
                       .readOnly,
                       "an answered lookup with no permissions is a denial — that is the server's answer")
    }

    // MARK: - 2. The model applies it

    func testTheStateIsAppliedFromThePolicyAndReachesTheViewThroughCanSend() async {
        let policy = FakePolicy()
        policy.answer = ComposerPostingFacts(channel: channel(deleteAt: 99), permissions: nil)
        let composer = makeComposer(policy: policy)

        await composer.resolvePostingState()

        XCTAssertEqual(composer.posting, .archived)
        XCTAssertEqual(policy.askedChannelIDs, [channelID], "the state is asked for this channel, once")
        composer.textChanged("hello", caret: 5)
        XCTAssertFalse(composer.canSend, "the send button must be disabled while the banner is up")
    }

    func testAnAnsweredReadOnlyRoleSetIsAppliedToo() async {
        let policy = FakePolicy()
        policy.answer = ComposerPostingFacts(channel: channel(), permissions: [ChannelPermissionID.readChannel])
        let composer = makeComposer(policy: policy)
        await composer.resolvePostingState()
        XCTAssertEqual(composer.posting, .readOnly)
    }

    func testANoAnswerLeavesTheComposerOpenAndTheTextSendable() async {
        let policy = FakePolicy()
        policy.answer = nil
        let composer = makeComposer(policy: policy)
        await composer.resolvePostingState()
        XCTAssertEqual(composer.posting, .open)
    }

    func testTheFireAndForgetRefreshAppliesTheAnswer() async {
        // The view's `.task` path: `refreshPostingState()` spawns the worker. Await the policy's call,
        // then the state (the model's continuation runs right after the answer).
        let policy = FakePolicy()
        policy.answer = ComposerPostingFacts(channel: channel(deleteAt: 1), permissions: nil)
        let composer = makeComposer(policy: policy)
        composer.refreshPostingState()
        _ = await policy.asked.wait(until: { $0 == self.channelID })
        let applied = await waitFor { composer.posting == .archived }
        XCTAssertTrue(applied, "refreshPostingState() must apply the answer, state=\(composer.posting)")
    }

    // MARK: - 3. The refusal

    func testAnArchivedSendIsRefusedLocallyWithTheBannersOwnSentence() async {
        let service = FakeService()
        let policy = FakePolicy()
        policy.answer = ComposerPostingFacts(channel: channel(deleteAt: 7), permissions: nil)
        let composer = makeComposer(policy: policy, service: service)
        await composer.resolvePostingState()

        composer.textChanged("this must not reach the server", caret: 32)
        await composer.send()

        XCTAssertTrue(service.createBodies.isEmpty,
                      "an archived channel must make no create request: \(service.createBodies)")
        XCTAssertTrue(service.patchCalls.isEmpty)
        XCTAssertTrue(service.deleteCalls.isEmpty)
        XCTAssertEqual(composer.phase, .failed(ComposerPostingState.archived.message),
                       "the refusal must carry the banner's sentence, not an invented one")
        XCTAssertEqual(composer.text, "this must not reach the server",
                       "a refused send keeps the words")
    }

    func testAReadOnlySendIsRefusedWithTheReadOnlySentence() async {
        let service = FakeService()
        let policy = FakePolicy()
        policy.answer = ComposerPostingFacts(channel: channel(), permissions: [ChannelPermissionID.readChannel])
        let composer = makeComposer(policy: policy, service: service)
        await composer.resolvePostingState()

        composer.textChanged("no", caret: 2)
        await composer.send()

        XCTAssertTrue(service.createBodies.isEmpty)
        XCTAssertEqual(composer.phase, .failed("This channel is read-only."))
        XCTAssertEqual(composer.text, "no")
    }

    func testARefusedSlashCommandIsNotExecutedEither() async {
        // `/help` is a write too (it runs a server command), and the same guard covers it.
        let service = FakeService()
        let policy = FakePolicy()
        policy.answer = ComposerPostingFacts(channel: channel(deleteAt: 1), permissions: nil)
        let composer = makeComposer(policy: policy, service: service)
        await composer.resolvePostingState()

        composer.textChanged("/help", caret: 5)
        await composer.send()

        XCTAssertTrue(service.commandCalls.isEmpty, "a command is a write: \(service.commandCalls)")
        XCTAssertEqual(composer.phase, .failed(ComposerPostingState.archived.message))
    }

    func testAnOpenChannelStillSendsNormally() async {
        // The negative control: the guard must not cost a normal channel its send.
        let service = FakeService()
        let policy = FakePolicy()
        policy.answer = postingFacts
        let composer = makeComposer(policy: policy, service: service)
        await composer.resolvePostingState()
        XCTAssertEqual(composer.posting, .open)

        composer.textChanged("hello", caret: 5)
        await composer.send()

        XCTAssertEqual(service.createBodies.count, 1, "an open channel posts: \(service.createBodies)")
        XCTAssertEqual(service.createBodies.first?.message, "hello")
        XCTAssertEqual(composer.phase, .idle)
    }

    // MARK: - 4. The socket

    func testArchivingTheChannelOnTheSocketReplacesTheInputWithoutAskingAgain() async {
        // The frame already carries `delete_at`, so the banner must not cost a request — a reader in a
        // channel somebody archives gets the banner promptly even on a bad connection.
        let policy = FakePolicy()
        policy.answer = postingFacts
        let composer = makeComposer(policy: policy)
        await composer.resolvePostingState()
        XCTAssertEqual(composer.posting, .open)
        let asksBefore = policy.askedChannelIDs.count

        composer.handle(.channelDeleted(SocketChannelEvent(channelID: channelID,
                                                           teamID: "team-1",
                                                           deleteAt: 1_700_000_000)))

        XCTAssertEqual(composer.posting, .archived)
        XCTAssertEqual(policy.askedChannelIDs.count, asksBefore,
                       "a `channel_deleted` frame carries the fact; asking the server again is a request for nothing")
        XCTAssertFalse(composer.canSend)
    }

    func testAChannelUpdateCarryingDeleteAtArchivesToo() async {
        let policy = FakePolicy()
        policy.answer = postingFacts
        let composer = makeComposer(policy: policy)
        await composer.resolvePostingState()

        var updated = channel()
        updated.deleteAt = 1_700_000_001
        composer.handle(.channelUpdated(updated))

        XCTAssertEqual(composer.posting, .archived)
    }

    func testARestoreReReadsTheFactsAndBringsTheInputBack() async {
        // `channel_restored` names only the id (9.11.19), so the state is re-read rather than guessed.
        let policy = FakePolicy()
        policy.answer = ComposerPostingFacts(channel: channel(deleteAt: 5), permissions: nil)
        let composer = makeComposer(policy: policy)
        await composer.resolvePostingState()
        XCTAssertEqual(composer.posting, .archived)

        policy.answer = postingFacts
        composer.handle(.channelRestored(SocketChannelEvent(channelID: channelID, teamID: "team-1")))
        let reopened = await waitFor { composer.posting == .open }
        XCTAssertTrue(reopened, "a restored channel must re-open the composer, state=\(composer.posting)")
        XCTAssertGreaterThanOrEqual(policy.askedChannelIDs.count, 2, "the restore is re-read")
    }

    func testAnotherChannelsLifecycleLeavesThisComposerAlone() async {
        let policy = FakePolicy()
        policy.answer = postingFacts
        let composer = makeComposer(policy: policy)
        await composer.resolvePostingState()

        composer.handle(.channelDeleted(SocketChannelEvent(channelID: "someone-else", teamID: "team-1",
                                                           deleteAt: 1)))
        var other = channel()
        other.id = "someone-else"
        composer.handle(.channelUpdated(other))

        XCTAssertEqual(composer.posting, .open, "one channel's archive must not close another's composer")
    }

    // MARK: - Helpers

    /// Wait (briefly) for the model's fire-and-forget continuation. Bounded: a wrong answer fails in
    /// three seconds rather than hanging the suite.
    private func waitFor(timeout: TimeInterval = 3, _ predicate: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return predicate()
    }
}
