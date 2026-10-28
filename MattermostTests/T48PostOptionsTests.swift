// T48 — the post options surface (S38): the ordered offer derivation, the permalink, the saved-state
// patches, and the view model's writes against a fake service.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0, `app/screens/post_options/index.ts`
// (the gates) and `post_options.tsx` (the render order), `app/components/common_post_options/*`,
// `app/client/rest/posts.ts` (`markPostAsUnread`). Apache-2.0; see docs/THIRD_PARTY_NOTICES.md §18.
//
// The measured server facts the derivation rests on (pin permission ids absent, `post_edited` on pin,
// `preferences_deleted` on unsave, `set_unread` answering the membership row) are in
// `PostOptionsModels.swift`'s header and re-measurable with `scripts/t48_post_options_probe*.py`.

import XCTest
@testable import Mattermost

@MainActor
final class T48PostOptionsTests: XCTestCase {

    private let channelID = "chan0000000000000000000001"
    private let teamID = "team0000000000000000000001"
    private let me = "user0000000000000000000001"
    private let other = "user0000000000000000000002"

    // MARK: - Fixtures

    private func row(id: String = "post0000000000000000000001",
                     author: String? = nil,
                     message: String = "hello",
                     rootID: String = "",
                     replyCount: Int = 0,
                     isPinned: Bool = false,
                     isFollowing: Bool = false,
                     type: String = "",
                     deleteAt: Int64 = 0,
                     props: JSONValue? = nil) -> PostRowModel {
        let post = MMPost(id: id,
                          deleteAt: deleteAt,
                          isPinned: isPinned,
                          userId: author ?? other,
                          channelId: channelID,
                          rootId: rootID,
                          message: message,
                          type: type,
                          props: props,
                          replyCount: replyCount,
                          isFollowing: isFollowing)
        let users = [post.userId: MMUser(id: post.userId, username: "them", firstName: "Them")]
        return PostListDerivation.row(post: post,
                                      users: users,
                                      myUserID: me,
                                      grouped: false)
    }

    private func actions(reply: Bool = false,
                         edit: Bool = false,
                         delete: Bool = false,
                         react: Bool = false,
                         options: Bool = true) -> PostRowActions {
        PostRowActions(canReply: reply,
                       canEdit: edit,
                       canDelete: delete,
                       onReply: {},
                       onEdit: {},
                       onDelete: {},
                       onShowOptions: {},
                       canReact: react,
                       onReact: {},
                       showsOptions: options)
    }

    /// The facts a full administrator sees on somebody else's plain root post in a channel pane.
    private func adminFacts() -> PostOptionFacts {
        var facts = PostOptionFacts()
        facts.viewerID = me
        facts.authorID = other
        facts.message = "hello"
        facts.replyCount = 1
        facts.threadFollowing = false
        facts.canReact = true
        facts.canReply = true
        facts.canEdit = false
        facts.canDelete = false
        facts.permissions = [PostOptionsPermissionID.createPost, "read_channel"]
        facts.teamName = "perf"
        facts.surface = .channel
        return facts
    }

    // MARK: - The ordered derivation

    func testTheOrderIsUpstreamsRenderOrder() {
        let offered = PostOptionsCapabilities.derive(adminFacts()).offeredOptions
        XCTAssertEqual(offered,
                       [.react, .reply, .followThread, .markUnread, .copyLink, .save, .copyText, .pin],
                       "post_options.tsx draws react, reply, follow, mark unread, copy link, "
                       + "(translation), save, copy text, pin, edit, delete — in that order")
    }

    func testEditAndDeleteComeAfterPinAndOnlyWhenTheHostAllowsThem() {
        var facts = adminFacts()
        facts.canEdit = true
        facts.canDelete = true
        let offered = PostOptionsCapabilities.derive(facts).offeredOptions
        XCTAssertEqual(Array(offered.suffix(2)), [.edit, .delete])
        XCTAssertEqual(offered.firstIndex(of: .pin), offered.count - 3)
    }

    func testAnUnknownPermissionLookupWithholdsPin() {
        var facts = adminFacts()
        facts.permissions = nil
        XCTAssertFalse(PostOptionsCapabilities.derive(facts).offeredOptions.contains(.pin),
                       "no permission answer is the closed state, not a guess")

        facts.permissions = []
        XCTAssertFalse(PostOptionsCapabilities.derive(facts).offeredOptions.contains(.pin))
    }

    func testTheNamedPinIdsAreHonouredWhenTheServerCarriesThem() {
        var facts = adminFacts()
        facts.permissions = [PostOptionsPermissionID.pinPost]
        XCTAssertTrue(PostOptionsCapabilities.derive(facts).offeredOptions.contains(.pin))

        facts.permissions = [PostOptionsPermissionID.unpinPost]
        XCTAssertTrue(PostOptionsCapabilities.derive(facts).offeredOptions.contains(.pin))
    }

    func testOnARealServerTheFallbackIsTheChannelsWritePermission() {
        // Measured: 9.11.19 has no pin_post/unpin_post id at all, and a plain system_user pins 200.
        var facts = adminFacts()
        facts.permissions = [PostOptionsPermissionID.createPost]
        XCTAssertTrue(PostOptionsGate.canPin(permissions: facts.permissions))
        XCTAssertTrue(PostOptionsCapabilities.derive(facts).offeredOptions.contains(.pin))

        facts.permissions = ["read_channel"]
        XCTAssertFalse(PostOptionsCapabilities.derive(facts).offeredOptions.contains(.pin),
                       "an account that cannot post in the channel is not offered a pin it would be refused")
    }

    func testPinAndSaveFollowTheStateTheyDescribe() {
        var facts = adminFacts()
        facts.isPinned = true
        facts.isSaved = true
        let offered = PostOptionsCapabilities.derive(facts).offeredOptions
        XCTAssertTrue(offered.contains(.unpin))
        XCTAssertFalse(offered.contains(.pin))
        XCTAssertTrue(offered.contains(.unsave))
        XCTAssertFalse(offered.contains(.save))
    }

    func testMarkUnreadIsNotOfferedOnMyOwnPost() {
        var facts = adminFacts()
        facts.authorID = me
        XCTAssertFalse(PostOptionsCapabilities.derive(facts).offeredOptions.contains(.markUnread),
                       "upstream canMarkAsUnread: my own post is not markable")
    }

    func testAWebhookPostIsMarkableUnreadEvenWhenItCarriesMyId() {
        var facts = adminFacts()
        facts.authorID = me
        facts.isWebhook = true
        XCTAssertTrue(PostOptionsCapabilities.derive(facts).offeredOptions.contains(.markUnread))
    }

    func testCopyTextNeedsAMessageAndCopyLinkNeedsTheTeamsName() {
        var facts = adminFacts()
        facts.message = "   "
        var offered = PostOptionsCapabilities.derive(facts).offeredOptions
        XCTAssertTrue(offered.contains(.copyLink))
        XCTAssertFalse(offered.contains(.copyText), "no text, no Copy Text row")

        facts.message = "hello"
        facts.teamName = nil
        offered = PostOptionsCapabilities.derive(facts).offeredOptions
        XCTAssertFalse(offered.contains(.copyLink), "a permalink cannot be built without the team name")
        XCTAssertFalse(offered.contains(.copyText), "upstream's Copy Text is gated on the permalink")
    }

    func testFollowIsAChannelSurfaceOptionAndNeedsAThread() {
        var facts = adminFacts()
        facts.surface = .thread
        XCTAssertFalse(PostOptionsCapabilities.derive(facts).offeredOptions.contains(.followThread),
                       "upstream withholds Follow on the thread screen; its bell owns that action")

        facts = adminFacts()
        facts.replyCount = 0
        XCTAssertFalse(PostOptionsCapabilities.derive(facts).offeredOptions.contains(.followThread),
                       "a root with no replies has no thread row on 9.11.19 (measured 404)")

        facts = adminFacts()
        XCTAssertTrue(PostOptionsCapabilities.derive(facts).offeredOptions.contains(.followThread))

        facts.threadFollowing = true
        XCTAssertTrue(PostOptionsCapabilities.derive(facts).offeredOptions.contains(.unfollowThread))
        XCTAssertFalse(PostOptionsCapabilities.derive(facts).offeredOptions.contains(.followThread))
    }

    func testASystemOrDeletedOrPendingRowIsOfferedNoServerOption() {
        for (system, deleted, pending) in [(true, false, false), (false, true, false), (false, false, true)] {
            var facts = adminFacts()
            facts.isSystem = system
            facts.isDeleted = deleted
            facts.isPending = pending
            facts.canReact = false
            facts.canReply = false
            let offered = PostOptionsCapabilities.derive(facts).offeredOptions
            XCTAssertTrue(offered.isEmpty, "nothing but host options, and those were all false: \(offered)")
        }
    }

    func testAnArchivedChannelOffersNoWrites() {
        var facts = adminFacts()
        facts.isArchived = true
        let offered = PostOptionsCapabilities.derive(facts).offeredOptions
        XCTAssertFalse(offered.contains(.pin))
        XCTAssertFalse(offered.contains(.markUnread))
        XCTAssertFalse(offered.contains(.followThread))
        // Saving is my own preference, not a write into the channel, so it survives the archive —
        // as do both read-only options.
        XCTAssertTrue(offered.contains(.save))
        XCTAssertTrue(offered.contains(.copyText))
        XCTAssertTrue(offered.contains(.copyLink))
    }

    // MARK: - The permalink

    func testThePermalinkIsThePathTheServerServes() {
        XCTAssertEqual(PostPermalink.string(serverURL: "https://mm.example.com",
                                            teamName: "perf",
                                            postID: "abc"),
                       "https://mm.example.com/perf/pl/abc")
        XCTAssertEqual(PostPermalink.string(serverURL: "https://mm.example.com/",
                                            teamName: "perf",
                                            postID: "abc"),
                       "https://mm.example.com/perf/pl/abc",
                       "a trailing slash must not produce a double slash")
        XCTAssertEqual(PostPermalink.string(serverURL: "http://127.0.0.1:8065",
                                            teamName: "a b",
                                            postID: "abc"),
                       "http://127.0.0.1:8065/a%20b/pl/abc",
                       "the team is a path segment and is escaped")
    }

    func testNoPermalinkIsInventedFromMissingParts() {
        XCTAssertNil(PostPermalink.string(serverURL: "", teamName: "perf", postID: "abc"))
        XCTAssertNil(PostPermalink.string(serverURL: "https://mm.example.com", teamName: "", postID: "abc"))
        XCTAssertNil(PostPermalink.string(serverURL: "https://mm.example.com", teamName: "perf", postID: ""))
        XCTAssertNil(PostPermalink.string(serverURL: "not a url", teamName: "perf", postID: "abc"))
    }

    // MARK: - Saved state

    func testSavedStateAppliesOnlyTheFlaggedCategory() {
        let rows = [MMPreference(category: APIClient.savedPostCategory, name: "a", value: "true"),
                    MMPreference(category: APIClient.savedPostCategory, name: "b", value: "false"),
                    MMPreference(category: "theme", name: "c", value: "true")]
        var saved = SavedPostDerivation.savedIDs(from: rows)
        XCTAssertEqual(saved, ["a"])

        saved = SavedPostDerivation.updated(saved,
                                            with: [MMPreference(category: APIClient.savedPostCategory,
                                                                name: "d", value: "true")],
                                            deleted: false)
        XCTAssertEqual(saved, ["a", "d"])

        saved = SavedPostDerivation.updated(saved,
                                            with: [MMPreference(category: APIClient.savedPostCategory,
                                                                name: "a", value: "true")],
                                            deleted: true)
        XCTAssertEqual(saved, ["d"], "preferences_deleted removes regardless of the row's value")
    }

    // MARK: - The view model

    @MainActor
    final class FakePostOptionsService: PostOptionsServing {
        var permissionsValue: Set<String> = [PostOptionsPermissionID.createPost]
        var savedIDs: Set<String> = []
        var archived = false
        var teamNameValue: String? = "perf"
        /// The channel's own team, which wins over the team the route carried.
        var channelTeamIDValue = "team0000000000000000000001"
        var failure: Error?

        private(set) var permissionRequests: [(channelID: String, teamID: String, userID: String)] = []
        private(set) var savedRequests = 0
        private(set) var teamNameRequests: [String] = []
        private(set) var savedCalls: [(postID: String, saved: Bool, userID: String)] = []
        private(set) var pinnedCalls: [(postID: String, pinned: Bool)] = []
        private(set) var unreadCalls: [(postID: String, userID: String)] = []
        private(set) var followCalls: [(teamID: String, rootID: String, following: Bool)] = []

        func permissions(channelID: String, teamID: String, userID: String) async throws -> Set<String> {
            if let failure { throw failure }
            permissionRequests.append((channelID, teamID, userID))
            return permissionsValue
        }

        func savedPostIDs() async throws -> Set<String> {
            if let failure { throw failure }
            savedRequests += 1
            return savedIDs
        }

        func isArchived(channelID: String) async throws -> Bool {
            if let failure { throw failure }
            return archived
        }

        func channelTeamID(channelID: String) async throws -> String {
            if let failure { throw failure }
            return channelTeamIDValue
        }

        func teamName(teamID: String) async throws -> String? {
            if let failure { throw failure }
            teamNameRequests.append(teamID)
            return teamNameValue
        }

        func setSaved(postID: String, saved: Bool, userID: String) async throws {
            if let failure { throw failure }
            savedCalls.append((postID, saved, userID))
        }

        func setPinned(postID: String, pinned: Bool) async throws {
            if let failure { throw failure }
            pinnedCalls.append((postID, pinned))
        }

        func markUnread(postID: String, userID: String) async throws -> MMChannelMember {
            if let failure { throw failure }
            unreadCalls.append((postID, userID))
            return MMChannelMember(channelId: "chan0000000000000000000001",
                                   userId: userID,
                                   lastViewedAt: 1,
                                   msgCount: 41)
        }

        func setFollowing(teamID: String, rootID: String, following: Bool) async throws {
            if let failure { throw failure }
            followCalls.append((teamID, rootID, following))
        }
    }

    private func model(_ service: FakePostOptionsService) -> PostOptionsViewModel {
        PostOptionsViewModel(channelID: channelID,
                             serverURL: "http://127.0.0.1:8065",
                             myUserID: me,
                             service: service)
    }

    func testActivationReadsTheStateTheRowsCannotKnowByIdempotently() async {
        let service = FakePostOptionsService()
        service.savedIDs = ["post0000000000000000000004"]
        service.permissionsValue = [PostOptionsPermissionID.createPost]
        let options = model(service)

        await options.activate(teamID: teamID, teamName: nil)
        XCTAssertEqual(options.permissions, [PostOptionsPermissionID.createPost])
        XCTAssertEqual(options.savedPostIDs, ["post0000000000000000000004"])
        XCTAssertEqual(options.teamName, "perf")
        XCTAssertEqual(service.permissionRequests.count, 1)
        XCTAssertEqual(service.savedRequests, 1)

        await options.activate(teamID: teamID, teamName: nil)
        XCTAssertEqual(service.permissionRequests.count, 1, "a second appearance must not re-read")
        XCTAssertEqual(service.savedRequests, 1)
    }

    func testTheChannelsOwnTeamNamesThePermalinkNotTheRoutesTeam() async {
        // Measured on the live fixture: the channel was #t36-threads of team `perf`, the shell's
        // route still carried team `ops`, and Copy Link produced `…/ops/pl/<post>` — a link to a
        // channel that does not exist in that team. The channel's own team_id is the authority.
        let service = FakePostOptionsService()
        service.channelTeamIDValue = "team-of-the-channel"
        let options = model(service)

        await options.activate(teamID: "stale-team-from-the-route", teamName: "ops")
        XCTAssertEqual(service.teamNameRequests, ["team-of-the-channel"],
                       "the permalink's team must come from GET /channels/{id}, not the route")
        XCTAssertEqual(options.teamName, "perf")
        XCTAssertEqual(service.permissionRequests.map(\.teamID), ["team-of-the-channel"],
                       "the role union belongs to the channel's team too")
    }

    func testTheOfferedListComesFromTheStoreAndTheLoadedState() async {
        let service = FakePostOptionsService()
        let options = model(service)
        let row = row(replyCount: 1)
        await options.activate(teamID: teamID, teamName: "perf")

        var offered = options.offeredOptions(for: row, actions: actions(), surface: .channel)
        XCTAssertTrue(offered.contains(.copyLink))
        XCTAssertTrue(offered.contains(.save))
        XCTAssertTrue(offered.contains(.pin))
        XCTAssertTrue(offered.contains(.followThread))
        XCTAssertTrue(offered.contains(.markUnread))

        // Another client saved it: the menu must offer Unsave without a reload.
        options.handle(.preferencesChanged([MMPreference(category: APIClient.savedPostCategory,
                                                         name: row.id,
                                                         value: "true")]))
        offered = options.offeredOptions(for: row, actions: actions(), surface: .channel)
        XCTAssertTrue(offered.contains(.unsave))
        XCTAssertFalse(offered.contains(.save))

        // …and unsaved it again, which is the frame the server actually publishes.
        options.handle(.preferencesDeleted([MMPreference(category: APIClient.savedPostCategory,
                                                         name: row.id,
                                                         value: "true")]))
        offered = options.offeredOptions(for: row, actions: actions(), surface: .channel)
        XCTAssertTrue(offered.contains(.save))
    }

    func testASecondClientsPinAndFollowMoveTheMenu() async {
        let service = FakePostOptionsService()
        let options = model(service)
        let row = row(replyCount: 1)
        await options.activate(teamID: teamID, teamName: "perf")

        XCTAssertTrue(options.offeredOptions(for: row, actions: actions(), surface: .channel).contains(.pin))

        options.handle(.postEdited(MMPost(id: row.id, isPinned: true)))
        var offered = options.offeredOptions(for: row, actions: actions(), surface: .channel)
        XCTAssertTrue(offered.contains(.unpin), "post_edited carries is_pinned; the open sheet moves")

        options.handle(.threadFollowChanged(SocketThreadFollowChanged(threadID: row.id,
                                                                      state: true,
                                                                      replyCount: 1)))
        offered = options.offeredOptions(for: row, actions: actions(), surface: .channel)
        XCTAssertTrue(offered.contains(.unfollowThread))
        XCTAssertFalse(offered.contains(.followThread))
    }

    func testEveryOfferedOptionPerformsARealWriteOrPutsAStringOnThePasteboard() async {
        let service = FakePostOptionsService()
        let options = model(service)
        let row = row(replyCount: 1)
        await options.activate(teamID: teamID, teamName: "perf")

        // Only the options this test can attribute to the fake: the host closures (reply/edit/delete/
        // react) are the pane's, and are asserted by their own tests.
        let offered = options.offeredOptions(for: row, actions: actions(), surface: .channel)
        XCTAssertFalse(offered.isEmpty)

        for option in offered {
            let outcome = await options.perform(option, row: row)
            switch option {
            case .copyText, .copyLink:
                guard case .copied(let text) = outcome else {
                    return XCTFail("\(option) must produce the string to copy, got \(outcome)")
                }
                XCTAssertFalse(text.isEmpty)
            default:
                XCTAssertEqual(outcome, .performed, "\(option) must be a real request, got \(outcome)")
            }
        }

        XCTAssertEqual(service.savedCalls.map(\.saved), [true])
        XCTAssertEqual(service.pinnedCalls.map(\.pinned), [true])
        XCTAssertEqual(service.unreadCalls.map(\.postID), [row.id])
        XCTAssertEqual(service.followCalls.map(\.following), [true])
        // The copy link is the server-shaped permalink, not a path this build invented.
        let link = options.offeredOptions(for: row, actions: actions(), surface: .channel)
        if link.contains(.copyLink) {
            guard case .copied(let permalink) = await options.perform(.copyLink, row: row) else {
                return XCTFail("copy link failed")
            }
            XCTAssertEqual(permalink, "http://127.0.0.1:8065/perf/pl/\(row.id)")
        }
    }

    func testAFailedWriteSaysWhyAndLeavesTheStateAlone() async {
        let service = FakePostOptionsService()
        let options = model(service)
        let row = row()
        await options.activate(teamID: teamID, teamName: "perf")
        service.failure = MMError.forbidden(message: nil)

        guard case .failed(let message) = await options.perform(.save, row: row) else {
            return XCTFail("a refused write must come back as .failed")
        }
        XCTAssertTrue(message.contains("Could not save"), message)
        XCTAssertFalse(options.savedPostIDs.contains(row.id))
        XCTAssertTrue(service.savedCalls.isEmpty)
    }

    func testAMarkUnreadWriteHandsTheServersCountersToTheHost() async {
        let service = FakePostOptionsService()
        let options = model(service)
        var membership: MMChannelMember?
        options.onUnreadChange = { membership = $0 }
        let row = row()
        await options.activate(teamID: teamID, teamName: "perf")

        let outcome = await options.perform(.markUnread, row: row)
        XCTAssertEqual(outcome, .performed)
        XCTAssertEqual(service.unreadCalls.map(\.userID), [me])
        XCTAssertEqual(membership?.msgCount, 41, "the server's own arithmetic, not a local decrement")
    }

    func testAnArchivedChannelWithholdsTheWrites() async {
        let service = FakePostOptionsService()
        service.archived = true
        let options = model(service)
        let row = row(replyCount: 1)
        await options.activate(teamID: teamID, teamName: "perf")
        let offered = options.offeredOptions(for: row, actions: actions(), surface: .channel)
        XCTAssertFalse(offered.contains(.pin))
        XCTAssertFalse(offered.contains(.markUnread))
        XCTAssertFalse(offered.contains(.followThread))
        XCTAssertTrue(offered.contains(.save), "a saved-post preference is not a channel write")
        XCTAssertTrue(offered.contains(.copyLink), "reading a link is not a write")
    }
}
