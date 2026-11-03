// T48-AV-R1 (card `t_29925e81`) — the post options menu on the **lookup** rows: search results, the
// mentions feed, and the saved and pinned lists.
//
// Subject: `PostOptionsLookup.swift`. The units here pin the three claims a UI test cannot state
// precisely:
//
//   1. a lookup row resolves the model of **its own** channel (`ChannelPaneCoordinator`'s per-channel
//      cache — the same instance the channel pane holds), never "whatever channel the pane last
//      showed";
//   2. the offered rows are `PostOptionsCapabilities.derive` for that channel's facts, read from the
//      server by the sheet's own activation;
//   3. the two host facts that are **lookup** facts, not model facts: the four composer-backed
//      options (react/reply/edit/delete) are not offered because this host cannot perform them, and
//      the activation carries no team hint (the channel's team answers, never the pane's).
//
// The live half — a real menu drawn on a search-result, mention, saved and pinned row in the shipped
// configuration, and a save/unpin pressed in it landing on 9.11.19 — lives in
// `MattermostUITests/T93BNativeByDefaultUITests.swift` (T48-AV-R1's own tests) and in
// `docs/t48-av-r1-lookup-post-options.md`.

import XCTest
@testable import Mattermost

@MainActor
final class T48R1LookupPostOptionsTests: XCTestCase {

    private let teamID = "team0000000000000000000001"
    private let me = "user0000000000000000000001"
    private let other = "user0000000000000000000002"
    private let channelA = "chan000000000000000000000001"
    private let channelB = "chan000000000000000000000002"

    // MARK: - Fixtures

    private func row(id: String,
                     channelID: String,
                     author: String? = nil,
                     message: String = "a message from another channel",
                     isPinned: Bool = false,
                     replyCount: Int = 0) -> PostRowModel {
        let post = MMPost(id: id,
                          isPinned: isPinned,
                          userId: author ?? other,
                          channelId: channelID,
                          rootId: "",
                          message: message,
                          replyCount: replyCount)
        let users = [post.userId: MMUser(id: post.userId, username: "them", firstName: "Them")]
        return PostListDerivation.row(post: post, users: users, myUserID: me, grouped: false)
    }

    /// One server value for the whole test case.
    ///
    /// `ServerConfig` mints a new id per instance, and the coordinator's model cache is keyed by
    /// server id: two `ServerConfig()` calls are two independent caches, which would make "the
    /// presentation shares the channel pane's model" unfalsifiable. Held, not constructed per call.
    private lazy var serverValue = ServerConfig(name: "Local",
                                               url: URL(string: "http://127.0.0.1:8065")!)

    private func server() -> ServerConfig { serverValue }

    /// The coordinator's own cache is what a lookup row resolves through, so the tests use it rather
    /// than a bare `PostOptionsViewModel`: "the same instance the channel pane would use" is part of
    /// the guarantee (`PostOptionsLookup.swift`'s header).
    private func panes(_ service: FakeService) -> ChannelPaneCoordinator {
        let panes = ChannelPaneCoordinator()
        panes.postOptionsServiceFactory = { _ in service }
        return panes
    }

    /// One server, two channels: every channel-scoped read answers per channel, which is exactly what
    /// the tests need to prove the row's own channel decides.
    final class FakeService: PostOptionsServing {
        var permissionsByChannel: [String: Set<String>] = [:]
        var archivedChannels: Set<String> = []
        var channelTeams: [String: String] = [:]
        var teamNames: [String: String] = [:]
        var saved: Set<String> = []
        var failure: Error?

        private(set) var permissionRequests: [(channelID: String, teamID: String)] = []
        private(set) var archivedRequests: [String] = []
        private(set) var savedCalls: [(postID: String, saved: Bool)] = []
        private(set) var pinnedCalls: [(postID: String, pinned: Bool)] = []

        func permissions(channelID: String, teamID: String, userID: String) async throws -> Set<String> {
            if let failure { throw failure }
            permissionRequests.append((channelID, teamID))
            return permissionsByChannel[channelID] ?? []
        }

        func savedPostIDs() async throws -> Set<String> {
            if let failure { throw failure }
            return saved
        }

        func isArchived(channelID: String) async throws -> Bool {
            if let failure { throw failure }
            archivedRequests.append(channelID)
            return archivedChannels.contains(channelID)
        }

        func channelTeamID(channelID: String) async throws -> String {
            if let failure { throw failure }
            return channelTeams[channelID] ?? "team0000000000000000000001"
        }

        func teamName(teamID: String) async throws -> String? {
            if let failure { throw failure }
            return teamNames[teamID] ?? "perf"
        }

        func setSaved(postID: String, saved: Bool, userID: String) async throws {
            if let failure { throw failure }
            savedCalls.append((postID, saved))
        }

        func setPinned(postID: String, pinned: Bool) async throws {
            if let failure { throw failure }
            pinnedCalls.append((postID, pinned))
        }

        func markUnread(postID: String, userID: String) async throws -> MMChannelMember {
            if let failure { throw failure }
            return MMChannelMember(channelId: "chan000000000000000000000001",
                                   userId: userID, lastViewedAt: 1, msgCount: 7)
        }

        func setFollowing(teamID: String, rootID: String, following: Bool) async throws {
            if let failure { throw failure }
        }

        /// The follow *read* (T48-AV-R3): this suite measures which channel a row's menu resolves
        /// against, not follow state, so it answers "unknown" — the sheet then withholds both
        /// directions rather than guessing, which is the protocol's own closed default.
        func isFollowing(teamID: String, rootID: String) async throws -> Bool? {
            if let failure { throw failure }
            return nil
        }
    }

    // MARK: - 1. The row's own channel

    func testTheMenuResolvesTheRowsOwnChannel() throws {
        let service = FakeService()
        let panes = panes(service)
        let rowA = row(id: "postA", channelID: channelA)
        let rowB = row(id: "postB", channelID: channelB)

        let a = try XCTUnwrap(PostOptionsLookup.presentation(for: rowA, server: server(), panes: panes))
        let b = try XCTUnwrap(PostOptionsLookup.presentation(for: rowB, server: server(), panes: panes))

        XCTAssertEqual(a.options.channelID, channelA, "the search result's sheet is channel A's")
        XCTAssertEqual(b.options.channelID, channelB, "the mention's sheet is channel B's")
        XCTAssertFalse(a.options === b.options, "two channels are two models, never one shared state")
        XCTAssertTrue(a.options === panes.postOptions(for: server(), channelID: channelA),
                      "the cache is the one the channel pane holds — one model per channel, one socket feed")

        XCTAssertNil(PostOptionsLookup.presentation(for: row(id: "postC", channelID: ""),
                                                    server: server(), panes: panes),
                     "a row that names no channel has no model to derive from, so no menu")
    }

    // MARK: - 2. The offer is derived from that channel's facts

    func testTheOfferIsDerivedFromTheRowsChannelNotTheOneOnScreen() async throws {
        let service = FakeService()
        // Channel A: may write (create_post reaches pin through `PostOptionsGate.canPin`).
        // Channel B: no permissions at all, and archived — two independent gates, both channel facts.
        service.permissionsByChannel = [channelA: [PostOptionsPermissionID.createPost], channelB: []]
        service.archivedChannels = [channelB]
        let panes = panes(service)
        let rowA = row(id: "postA", channelID: channelA)
        let rowB = row(id: "postB", channelID: channelB)

        let a = try XCTUnwrap(PostOptionsLookup.presentation(for: rowA, server: server(), panes: panes))
        let b = try XCTUnwrap(PostOptionsLookup.presentation(for: rowB, server: server(), panes: panes))
        await PostOptionsLookup.activate(a)
        await PostOptionsLookup.activate(b)

        XCTAssertEqual(service.permissionRequests.map(\.channelID), [channelA, channelB],
                       "each sheet asks about the channel it was opened on")
        XCTAssertEqual(service.archivedRequests, [channelA, channelB])

        let offeredA = a.options.offeredOptions(for: rowA,
                                               actions: PostOptionsLookupActions.menuOnly,
                                               surface: .channel)
        XCTAssertTrue(offeredA.contains(.pin), "channel A can write, so Pin is offered there")
        XCTAssertTrue(offeredA.contains(.markUnread))

        let offeredB = b.options.offeredOptions(for: rowB,
                                               actions: PostOptionsLookupActions.menuOnly,
                                               surface: .channel)
        XCTAssertFalse(offeredB.contains(.pin), "channel B has no post-write permission")
        XCTAssertFalse(offeredB.contains(.markUnread), "an archived channel offers no writes")
        XCTAssertTrue(offeredB.contains(.copyLink), "a read still offers the permalink")

        // And B's activation did not reach into A's model: the sheet on A is unchanged by it.
        let againA = a.options.offeredOptions(for: rowA,
                                              actions: PostOptionsLookupActions.menuOnly,
                                              surface: .channel)
        XCTAssertEqual(againA, offeredA)
    }

    func testTheSavedRowOffersUnsaveAndThePinnedRowOffersUnpin() async throws {
        let service = FakeService()
        service.permissionsByChannel = [channelA: [PostOptionsPermissionID.createPost]]
        let panes = panes(service)
        let savedRow = row(id: "postSaved", channelID: channelA)
        let pinnedRow = row(id: "postPinned", channelID: channelA, isPinned: true)
        service.saved = [savedRow.id]

        let saved = try XCTUnwrap(PostOptionsLookup.presentation(for: savedRow,
                                                                server: server(), panes: panes))
        await PostOptionsLookup.activate(saved)
        let offeredSaved = saved.options.offeredOptions(for: savedRow,
                                                       actions: PostOptionsLookupActions.menuOnly,
                                                       surface: .channel)
        XCTAssertTrue(offeredSaved.contains(.unsave),
                      "a row that came from the Saved list must offer Unsave — the surface this card exists for")
        XCTAssertFalse(offeredSaved.contains(.save))

        let pinned = try XCTUnwrap(PostOptionsLookup.presentation(for: pinnedRow,
                                                                  server: server(), panes: panes))
        await PostOptionsLookup.activate(pinned)
        let offeredPinned = pinned.options.offeredOptions(for: pinnedRow,
                                                          actions: PostOptionsLookupActions.menuOnly,
                                                          surface: .channel)
        XCTAssertTrue(offeredPinned.contains(.unpin),
                      "a row that came from the pinned sheet must offer Unpin")
    }

    // MARK: - 3. What this host can actually perform

    func testTheLookupRowOffersOnlyTheOptionsItsHostCanPerform() async throws {
        let service = FakeService()
        service.permissionsByChannel = [channelA: [PostOptionsPermissionID.createPost,
                                                   "edit_post",
                                                   "delete_post"]]
        let panes = panes(service)
        // My own post: the channel pane would offer Edit and Delete from the same model.
        let mine = row(id: "postMine", channelID: channelA, author: me)
        let presentation = try XCTUnwrap(PostOptionsLookup.presentation(for: mine,
                                                                        server: server(), panes: panes))
        await PostOptionsLookup.activate(presentation)

        let lookupActions = try XCTUnwrap(PostOptionsLookupActions.rowActions(for: mine,
                                                                             onShowOptions: {}))
        XCTAssertTrue(lookupActions.showsOptions, "the ellipsis is the whole point of the repair")
        XCTAssertTrue(lookupActions.hasAnyAction, "`PostRowView` draws no button without this")
        XCTAssertFalse(lookupActions.canReply)
        XCTAssertFalse(lookupActions.canEdit)
        XCTAssertFalse(lookupActions.canDelete)
        XCTAssertFalse(lookupActions.canReact,
                       "a lookup host has no composer, picker or draft sink — the four host options are absent")

        let offeredLookup = presentation.options.offeredOptions(for: mine,
                                                               actions: lookupActions,
                                                               surface: .channel)
        XCTAssertFalse(offeredLookup.contains(.edit))
        XCTAssertFalse(offeredLookup.contains(.delete))
        XCTAssertFalse(offeredLookup.contains(.reply))
        XCTAssertFalse(offeredLookup.contains(.react))
        XCTAssertTrue(offeredLookup.contains(.save), "the server-backed rows are what this host can do")

        // The same model and facts, with the channel pane's own actions: the composer-backed rows
        // come back. That is the proof the difference is the **host**, not the model's state.
        let paneActions = PostRowActions(canReply: false, canEdit: true, canDelete: true,
                                         onReply: {}, onEdit: {}, onDelete: {},
                                         onShowOptions: {}, canReact: false, onReact: {},
                                         showsOptions: true)
        let offeredPane = presentation.options.offeredOptions(for: mine,
                                                             actions: paneActions,
                                                             surface: .channel)
        XCTAssertTrue(offeredPane.contains(.edit))
        XCTAssertTrue(offeredPane.contains(.delete))

        XCTAssertNil(PostOptionsLookupActions.rowActions(for: row(id: "postC", channelID: ""),
                                                         onShowOptions: {}),
                     "no channel means no menu — an ellipsis that opens nothing is the defect, not the fix")
    }

    // MARK: - 4. The sheet's own reads and the refusal it draws

    func testTheLookupActivationAsksTheChannelForItsTeamAndNotThePane() async throws {
        let service = FakeService()
        service.channelTeams = [channelB: "team-of-the-other-channel"]
        service.teamNames = ["team-of-the-other-channel": "ops",
                             "team0000000000000000000001": "perf"]
        let panes = panes(service)
        // A mention from another team's channel while the shell is looking at `teamID`.
        let mention = row(id: "postMention", channelID: channelB)
        let presentation = try XCTUnwrap(PostOptionsLookup.presentation(for: mention,
                                                                        server: server(), panes: panes))

        await PostOptionsLookup.activate(presentation)

        XCTAssertEqual(presentation.options.teamID, "team-of-the-other-channel",
                       "the channel's own team is the one the sheet works in")
        XCTAssertEqual(presentation.options.teamName, "ops",
                       "…and the one the permalink is built from")
        XCTAssertEqual(service.permissionRequests.map(\.teamID), ["team-of-the-other-channel"],
                       "the role union belongs to the channel's team too")
    }

    func testARefusedWriteFromTheLookupSheetKeepsItsReason() async throws {
        let service = FakeService()
        service.saved = ["postPinned"]
        let panes = panes(service)
        let row = row(id: "postPinned", channelID: channelA, isPinned: true)
        let presentation = try XCTUnwrap(PostOptionsLookup.presentation(for: row,
                                                                        server: server(), panes: panes))
        await PostOptionsLookup.activate(presentation)
        XCTAssertTrue(presentation.options.offeredOptions(for: row,
                                                          actions: PostOptionsLookupActions.menuOnly,
                                                          surface: .channel).contains(.unsave))

        service.failure = MMError.forbidden(message: nil)
        guard case .failed(let message) = await presentation.options.perform(.unsave, row: row) else {
            return XCTFail("a refused unsave must come back as .failed, so the sheet stays open and says why")
        }
        XCTAssertTrue(message.contains("Could not save"), message)
        XCTAssertEqual(message, "Could not save. You do not have permission to do that.")
        XCTAssertTrue(presentation.options.savedPostIDs.contains(row.id),
                      "a refused unsave must leave the state alone; the sheet redraws from it")
        XCTAssertTrue(service.savedCalls.isEmpty)
    }
}
