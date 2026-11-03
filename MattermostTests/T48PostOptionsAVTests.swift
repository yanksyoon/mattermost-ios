// T48-AV — the adversarial pass over the post-options menu (S38).
//
// The T48 build note (docs/t48-build-note.md) measured the happy path and one known socket gap. This
// suite attacks the claims a reader of that note cannot check from the note itself:
//
//   1. **the channel's own team names the permalink, under adversity.** The note's fix reads
//      `GET /channels/{id}` and takes `team_id` from the channel. This suite asks what happens when
//      the route supplied another team's *name* and the channel's own name read fails: does the
//      route's name survive into `/ops/pl/<post>`?
//   2. **an archived channel offers no writes.** The note's table says so for every row; the
//      derivation is asked directly, with edit/delete allowed by the host.
//   3. **Edit and Delete follow the server's permission ids** (`edit_post` / `delete_post`), which is
//      what the note's table claims. The host's own `canEdit`/`canDelete` are ownership answers; the
//      derivation is asked whether the server's grant is consulted at all.
//   4. **the known gap is delivery, not the model.** A `preferences_changed` frame applied to the
//      view model must flip the offered row; if it does, the live gap is downstream of the model.
//
// The tests marked with `expectKnownDefect` record defects this pass found (repair cards named in
// the reason). The marker is strict: once the product is fixed, the test fails as "unexpectedly
// passed", which is the signal to remove it — the same mechanism the T48 note used for its known
// gap. `T48AV_STRICT=1` runs them unmarked; that is how this pass produced the red output quoted in
// docs/t48-av-build-note.md, and how the defects stay reproducible once they are fixed.
//
// R4 (t_610b979b) removed the two F5 markers: Edit and Delete now read `edit_post` / `delete_post`
// and the channel's archive, so those two tests assert the fixed behaviour as ordinary expectations.
// The helper stays for the findings still open (F1/F3/F4).
//
// Run:
//
//     python3 scripts/qa-test.py --platform ios --sim id=<udid> \
//       --only-testing MattermostTests/T48PostOptionsAVTests

import XCTest
@testable import Mattermost

@MainActor
final class T48PostOptionsAVTests: XCTestCase {

    private let channelID = "chan0000000000000000000001"
    private let routeTeamID = "team-route-ops-000000000001"
    private let channelTeamID = "team-channel-perf-000000001"
    private let me = "user0000000000000000000001"
    private let other = "user0000000000000000000002"

    // MARK: - Fixtures

    private func row(id: String = "post0000000000000000000001",
                     author: String? = nil,
                     message: String = "hello",
                     rootID: String = "",
                     replyCount: Int = 0) -> PostRowModel {
        let post = MMPost(id: id,
                          userId: author ?? other,
                          channelId: channelID,
                          rootId: rootID,
                          message: message,
                          replyCount: replyCount)
        let users = [post.userId: MMUser(id: post.userId, username: "them", firstName: "Them")]
        return PostListDerivation.row(post: post,
                                      users: users,
                                      myUserID: me,
                                      grouped: false)
    }

    private func actions(edit: Bool = false, delete: Bool = false) -> PostRowActions {
        PostRowActions(canReply: true,
                       canEdit: edit,
                       canDelete: delete,
                       onReply: {},
                       onEdit: {},
                       onDelete: {},
                       onShowOptions: {},
                       showsOptions: true)
    }

    /// The fake from the T48 unit suite, with the one behaviour this suite needs to steer: a channel
    /// whose `team_id` is readable while its *name* cannot be resolved (the route's name is then the
    /// only name the model holds).
    @MainActor
    final class FakeService: PostOptionsServing {
        var channelTeamIDValue = "team-channel-perf-000000001"
        var teamNameValue: String? = "perf"
        /// The name read for the channel's team fails (offline / 403 / rate limit).
        var teamNameFails = false
        /// The channel's own team cannot be read (a deep link, or the app offline mid-activation).
        var channelTeamIDFails = false
        var permissionsValue: Set<String> = [PostOptionsPermissionID.createPost]
        var savedIDs: Set<String> = []

        func permissions(channelID: String, teamID: String, userID: String) async throws -> Set<String> {
            permissionsValue
        }

        func savedPostIDs() async throws -> Set<String> { savedIDs }

        func isArchived(channelID: String) async throws -> Bool { false }

        func channelTeamID(channelID: String) async throws -> String {
            if channelTeamIDFails { throw URLError(.notConnectedToInternet) }
            return channelTeamIDValue
        }

        func teamName(teamID: String) async throws -> String? {
            if teamNameFails { throw URLError(.notConnectedToInternet) }
            return teamNameValue
        }

        func setSaved(postID: String, saved: Bool, userID: String) async throws {}
        func setPinned(postID: String, pinned: Bool) async throws {}
        func markUnread(postID: String, userID: String) async throws -> MMChannelMember {
            MMChannelMember(channelId: "chan0000000000000000000001",
                            userId: userID, lastViewedAt: 1, msgCount: 41)
        }
        func setFollowing(teamID: String, rootID: String, following: Bool) async throws {}

        /// T48-AV-R3: the follow answer is the server's (CRT thread-row membership). The default is the
        /// "not followed" answer, which is what the fixture posts in this suite are.
        var followAnswer: Bool? = false

        func isFollowing(teamID: String, rootID: String) async throws -> Bool? { followAnswer }
    }

    /// Mark a finding as a known defect: with the marker in place the suite stays green while the
    /// defect exists, and the test reports "unexpectedly passed" the moment it is fixed — the signal
    /// to delete the marker. The strict run quoted in docs/t48-av-build-note.md §AV unit is produced
    /// by making this method a no-op (`_ = why`).
    private func expectKnownDefect(_ why: String) {
        XCTExpectFailure(why)
    }

    private func model(_ service: FakeService) -> PostOptionsViewModel {
        PostOptionsViewModel(channelID: channelID,
                             serverURL: "http://127.0.0.1:8065",
                             myUserID: me,
                             service: service)
    }

    // MARK: - 1. The permalink under a stale route

    /// The note's fix, asked the way the live bug happened: the route carried team `ops`, the channel
    /// belongs to `perf`, and both reads answer. The link must be the channel's.
    func testTheChannelsOwnTeamNamesThePermalinkWhenTheRouteCarriedAnotherTeam() async {
        let service = FakeService()
        let options = model(service)

        await options.activate(teamID: routeTeamID, teamName: "ops")

        XCTAssertEqual(options.teamName, "perf",
                       "GET /users/me/teams resolves the channel's team to `perf`; the route said ops")
        guard case .copied(let link) = await options.perform(.copyLink, row: row()) else {
            return XCTFail("Copy Link must produce a string for a readable post with a known team")
        }
        // The post id of the fixture row, and the channel's team — never the route's.
        XCTAssertEqual(link, "http://127.0.0.1:8065/perf/pl/post0000000000000000000001")
    }

    /// The adversarial half: the channel's `team_id` is known to differ from the route's, but the
    /// name read for the channel's team fails (offline, 403, a rate limit). The route's `ops` must
    /// not survive: a permalink built from it (`/ops/pl/<post>`) is a link to a team the channel is
    /// not in — the exact class of defect the fix was written for, one failed request away.
    ///
    /// Repaired by R2 (card `t_9acf2b1c`, docs/t48-av-r2-repair.md): the supplied name is a fallback
    /// only while the channel's team is unknown or is the route's own, and `teamName` starts empty.
    func testAFailedTeamNameReadMustNotLeaveTheRoutesTeamInThePermalink() async {
        let service = FakeService()
        service.teamNameFails = true
        let options = model(service)

        await options.activate(teamID: routeTeamID, teamName: "ops")

        // The channel's own team was read and is not the route's: a name equal to the route's is a
        // guess, and the derivation's own rule is "no name, no Copy Link" rather than a wrong path.
        XCTAssertNotEqual(options.teamName, "ops",
                          "the channel belongs to \(channelTeamID); `ops` is the route's team, not its")
        let offered = options.offeredOptions(for: row(), actions: actions(), surface: .channel)
        XCTAssertFalse(offered.contains(.copyLink),
                       "with the channel team's name unreadable, Copy Link must be absent, not wrong")

        if case .copied(let link) = await options.perform(.copyLink, row: row()) {
            XCTFail("a link was produced while the channel's team name is unknown: \(link)")
        }
    }

    /// The repair is narrow: R2 drops the route's name only when the channel's own team was **read**
    /// and is another team. When `GET /channels/{id}` fails — a deep link that carries no team, the
    /// app offline during activation — the route's team and name are the only facts there are, and
    /// they are the same team the shell just showed. Copy Link must keep working, not disappear.
    func testAnUnreadableChannelTeamStillUsesTheRoutesName() async {
        let service = FakeService()
        service.channelTeamIDFails = true
        service.teamNameFails = true
        let options = model(service)

        await options.activate(teamID: routeTeamID, teamName: "ops")

        XCTAssertEqual(options.teamName, "ops",
                       "with the channel's team unread, the route's team is the only one there is")
        let offered = options.offeredOptions(for: row(), actions: actions(), surface: .channel)
        XCTAssertTrue(offered.contains(.copyLink))
        guard case .copied(let link) = await options.perform(.copyLink, row: row()) else {
            return XCTFail("Copy Link must still work when only the route's team is known")
        }
        XCTAssertEqual(link, "http://127.0.0.1:8065/ops/pl/post0000000000000000000001")
    }

    /// The other side of the same boundary: the channel's team **was** read and it is the team the
    /// route named, so the route's name describes the right team. A failed name read is a fallback,
    /// not a reason to withhold the row.
    func testAMatchingChannelTeamKeepsTheRoutesNameWhenTheNameReadFails() async {
        let service = FakeService()
        service.channelTeamIDValue = routeTeamID
        service.teamNameFails = true
        let options = model(service)

        await options.activate(teamID: routeTeamID, teamName: "ops")

        XCTAssertEqual(options.teamName, "ops")
        XCTAssertTrue(options.offeredOptions(for: row(), actions: actions(), surface: .channel)
            .contains(.copyLink))
    }

    // MARK: - 2. The archived channel

    /// Upstream's `channelIsArchived` withholds every write, and the T48 note's table says the same
    /// for Edit and Delete ("my own post, `edit_post`, channel not archived"). The derivation is
    /// asked with the host's own answers for a post that is mine, in an archived channel.
    ///
    /// R4 (t_610b979b): the archive is now a term in the reply/edit/delete gates, so this is an
    /// ordinary expectation rather than a recorded defect.
    func testAnArchivedChannelOffersNoEditOrDelete() {
        var facts = PostOptionFacts()
        facts.viewerID = me
        facts.authorID = me
        facts.message = "mine"
        facts.canReply = true
        facts.canEdit = true
        facts.canDelete = true
        facts.permissions = [PostOptionsPermissionID.createPost]
        facts.teamName = "perf"
        facts.isArchived = true

        let offered = PostOptionsCapabilities.derive(facts).offeredOptions
        XCTAssertFalse(offered.contains(.edit), "an archived channel offers no edit")
        XCTAssertFalse(offered.contains(.delete), "an archived channel offers no delete")
        XCTAssertFalse(offered.contains(.reply), "an archived channel offers no reply")
    }

    // MARK: - 3. The server's permission ids

    /// The note's table gates Edit on `edit_post` and Delete on `delete_post`. A derivation whose
    /// facts carry only `create_post` — an account that may write but not edit — must not offer them.
    /// The host's `canEdit`/`canDelete` are ownership answers (`ComposerRowPermissions.menu`), so if
    /// the ids are not consulted here the row is offered and the server refuses it after the sheet
    /// has already dismissed.
    ///
    /// R4 (t_610b979b): the ids are now read in `PostOptionsViewModel.facts` and again in `derive`.
    func testEditAndDeleteAreWithheldWithoutTheServersEditAndDeleteIds() async {
        let service = FakeService()
        service.permissionsValue = [PostOptionsPermissionID.createPost]
        let options = model(service)
        // The union is read by activate(); asking facts() before it answers with no ids at all.
        await options.activate(teamID: channelTeamID, teamName: "perf")
        let mine = row(author: me)

        let facts = options.facts(for: mine,
                                  actions: actions(edit: true, delete: true),
                                  surface: .channel)
        XCTAssertEqual(facts.permissions, [PostOptionsPermissionID.createPost], "the premise")
        XCTAssertFalse(facts.canEdit, "`edit_post` is not in the account's union: Edit must be absent")
        XCTAssertFalse(facts.canDelete, "`delete_post` is not in the account's union: Delete must be absent")
    }

    // MARK: - 4. The known gap, at the model

    /// The build note's known gap says `preferences_changed` does not move an already open menu, and
    /// that the defect is `SocketEvent` → coordinator → model rather than the model's state patch.
    /// This test holds the model to its half: given the frame, the offered row flips. If it passes,
    /// the live gap is strictly downstream (delivery), which is what the repair card asserts.
    func testTheModelFlipsSaveToUnsaveOnAPreferencesFrame() {
        let options = model(FakeService())
        let postID = "post0000000000000000000001"
        let target = row(id: postID)

        XCTAssertTrue(options.offeredOptions(for: target, actions: actions(), surface: .channel)
            .contains(.save), "the premise: nothing is saved yet")

        options.handle(.preferencesChanged([MMPreference(userId: me,
                                                          category: APIClient.savedPostCategory,
                                                          name: postID,
                                                          value: "true")]))

        let offered = options.offeredOptions(for: target, actions: actions(), surface: .channel)
        XCTAssertTrue(offered.contains(.unsave), "preferences_changed must flip Save → Unsave")
        XCTAssertFalse(offered.contains(.save))

        options.handle(.preferencesDeleted([MMPreference(userId: me,
                                                         category: APIClient.savedPostCategory,
                                                         name: postID,
                                                         value: "true")]))
        XCTAssertTrue(options.offeredOptions(for: target, actions: actions(), surface: .channel)
            .contains(.save), "preferences_deleted must flip Unsave → Save")
    }

    /// The pin half of the same claim: a `post_edited` for somebody else's post patches the state the
    /// open menu derives from. This is the path the live suite measured as working.
    func testTheModelFlipsPinToUnpinOnAPostEditedFrame() async {
        let options = model(FakeService())
        let postID = "post0000000000000000000001"
        let target = row(id: postID)
        // canPin reads the union, which activate() loads; the fixture grants create_post.
        await options.activate(teamID: channelTeamID, teamName: "perf")

        XCTAssertTrue(options.offeredOptions(for: target, actions: actions(), surface: .channel)
            .contains(.pin), "the premise: the post is not pinned")

        options.handle(.postEdited(MMPost(id: postID,
                                          isPinned: true,
                                          userId: other,
                                          channelId: channelID,
                                          message: "hello")))

        XCTAssertTrue(options.offeredOptions(for: target, actions: actions(), surface: .channel)
            .contains(.unpin), "post_edited(is_pinned: true) must flip Pin → Unpin")
    }
}
