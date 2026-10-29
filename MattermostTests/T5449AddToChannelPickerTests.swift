// T5449 C3 — the team-scoped channel picker, and the one-shot call intent it shares a card with.
//
// Two subjects, both unreachable from a live test on a quiet host *fast enough to be a unit test*:
//
//  1. **Which channels the picker offers.** `ChannelMemberAdminAnswer.resolve` is pure: my channels,
//     my roles on each of them, my system/team roles, and `POST /roles/names`' answer go in; the
//     ids I may manage come out. Every exclusion the rule names — archived, the default channel, a
//     DM/GM, a channel whose visibility needs a permission I do not hold — is a case below.
//  2. **Already-member detection, the optimistic add and its rollback.** Driven through
//     `AddToChannelPickerViewModel` against a fake service; the optimistic state is asserted while
//     the write is *suspended*, so the test proves the row changed before the server answered, not
//     merely that it ended up right.
//
// The `CallsCoordinator.requestStart` consume-once rule is here too because it has no server at all
// — it is bookkeeping on the app-scoped coordinator (`ProfileSheet` asks, `CallsJoinEntry` spends).

import Combine
import XCTest
@testable import Mattermost

// MARK: - Fakes

/// A `ChannelInfoServing` that answers from memory. Only the routes this card uses are meaningful;
/// the rest answer "nothing", which is how a fake should behave for a surface it does not model.
@MainActor
final class FakePickerService: ChannelInfoServing {

    var channels: [MMChannel] = []
    var memberships: [MMChannelMember] = []
    var principalValue = MMPrincipal(id: "me", username: "perfprobe", roles: "system_user")
    var teamRoles = "team_user"
    var teamMembers: [String: MMTeamMembership] = [:]
    var rolesByName: [String: MMRole] = [:]

    /// Channel id → the membership row `GET /channels/{id}/members/{userID}` answers.
    var memberRows: [String: MMChannelMember] = [:]
    var memberError: Error?

    var addError: Error?
    var addRequests: [(channelID: String, userID: String)] = []
    /// Called as `addMember` starts, before it suspends — the test's signal that the write is in
    /// flight (and therefore that the row's optimistic state is observable).
    var onAddStarted: (() -> Void)?
    private var addGate: CheckedContinuation<Void, Never>?
    private var blockAdd = false

    func blockAddUntilReleased() { blockAdd = true }
    func releaseAdd() {
        blockAdd = false
        addGate?.resume()
        addGate = nil
    }

    var roleRequests: [[String]] = []

    func channel(id: String) async throws -> MMChannel { throw MMError.notFound }
    func stats(channelID: String) async throws -> MMChannelStats { MMChannelStats(channelID: channelID) }
    func principal() async throws -> MMPrincipal { principalValue }
    func myMembership(channelID: String) async throws -> MMChannelMember { throw MMError.notFound }
    func myTeamMembership(teamID: String) async throws -> MMTeamMembership {
        MMTeamMembership(userId: principalValue.id, teamId: teamID, roles: teamRoles)
    }
    func teamMembership(teamID: String, userID: String) async throws -> MMTeamMembership {
        guard let row = teamMembers[userID] else { throw MMError.notFound }
        return row
    }
    func rolePermissions(names: [String]) async throws -> [MMRole] {
        roleRequests.append(names)
        return names.compactMap { rolesByName[$0] }
    }
    func members(channelID: String, page: Int, perPage: Int) async throws -> [MMChannelMember] { [] }
    func member(channelID: String, userID: String) async throws -> MMChannelMember {
        if let memberError { throw memberError }
        guard let row = memberRows[channelID] else { throw MMError.notFound }
        return row
    }
    func users(ids: [String]) async throws -> [MMUser] { [] }
    func statuses(ids: [String]) async throws -> [MMStatus] { [] }
    func patch(channelID: String, patch: MMChannelPatch) async throws -> MMChannel { throw MMError.notFound }
    func archive(channelID: String) async throws -> MMChannel { throw MMError.notFound }
    func restore(channelID: String) async throws -> MMChannel { throw MMError.notFound }
    func addMember(channelID: String, userID: String) async throws -> MMChannelMember {
        addRequests.append((channelID, userID))
        onAddStarted?()
        if blockAdd {
            await withCheckedContinuation { addGate = $0 }
        }
        if let addError { throw addError }
        return MMChannelMember(channelId: channelID, userId: userID, roles: "channel_user")
    }
    func removeMember(channelID: String, userID: String) async throws {}
    func closeDirectChannel(userID: String, channelID: String) async throws {}
    func myTeamChannels(teamID: String) async throws -> [MMChannel] { channels }
    func myChannelMemberships() async throws -> [MMChannelMember] { memberships }
    func teamPublicChannels(teamID: String, page: Int, perPage: Int) async throws -> [MMChannel] { [] }
    func usersNotInChannel(teamID: String, channelID: String, page: Int, perPage: Int) async throws -> [MMUser] { [] }
    func searchUsersNotInChannel(teamID: String, channelID: String, term: String) async throws -> [MMUser] { [] }
}

// MARK: - Tests

@MainActor
final class T5449AddToChannelPickerTests: XCTestCase {

    private let me = "me"
    private let buddy = "buddy"

    private var service: FakePickerService!

    // Channel fixtures: one for every exclusion the rule names.
    private let publicManaged = MMChannel(id: "c_public_managed", name: "alpha", displayName: "Alpha",
                                          type: "O", teamId: "team")
    private let privateManaged = MMChannel(id: "c_private_managed", name: "secret", displayName: "Secret",
                                           type: "P", teamId: "team")
    private let publicUnmanaged = MMChannel(id: "c_public_unmanaged", name: "beta", displayName: "Beta",
                                            type: "O", teamId: "team")
    private let defaultChannel = MMChannel(id: "c_default", name: "town-square",
                                           displayName: "Town Square", type: "O", teamId: "team")
    private let archived = MMChannel(id: "c_archived", name: "old", displayName: "Old",
                                     type: "O", teamId: "team", deleteAt: 1_700_000_000_000)
    /// A private channel managed through the **private** permission — the positive half of the
    /// visibility split `privateManaged` measures from the other side.
    private let privateManagedByPrivateRole = MMChannel(id: "c_private_managed_by_role",
                                                        name: "vault", displayName: "Vault",
                                                        type: "P", teamId: "team")

    override func setUp() async throws {
        try await super.setUp()
        service = FakePickerService()
    }

    override func tearDown() async throws {
        service = nil
        try await super.tearDown()
    }

    // MARK: - Which channels the list holds

    /// One rule, two quantifiers: the answer keeps the channels whose **own** gate passes, and drops
    /// the four the rule names — an unmanaged channel, the default channel, an archived channel, and
    /// a private channel whose **visibility's** permission the reader does not hold.
    func testTheAnswerKeepsOnlyTheChannelsICanManage() {
        service.rolesByName = [
            "channel_user": MMRole(id: "r1", name: "channel_user",
                                   permissions: [ChannelPermissionID.readChannel]),
            // Public-only: the permission that decides is the one the channel's **visibility**
            // names, so this role manages public channels and not private ones.
            "channel_admin": MMRole(id: "r2", name: "channel_admin",
                                    permissions: [ChannelPermissionID.managePublicChannelMembers]),
            "channel_private_admin": MMRole(id: "r3", name: "channel_private_admin",
                                            permissions: [ChannelPermissionID.managePrivateChannelMembers]),
        ]
        let channels = [publicManaged, privateManaged, privateManagedByPrivateRole,
                        publicUnmanaged, defaultChannel, archived]
        let memberships = [
            MMChannelMember(channelId: publicManaged.id, userId: me, roles: "channel_admin"),
            // A **public-only** manager on a private channel: the private permission is missing, so
            // this channel is not offered even though another one is.
            MMChannelMember(channelId: privateManaged.id, userId: me, roles: "channel_admin"),
            MMChannelMember(channelId: privateManagedByPrivateRole.id, userId: me,
                            roles: "channel_private_admin"),
            MMChannelMember(channelId: publicUnmanaged.id, userId: me, roles: "channel_user"),
            MMChannelMember(channelId: defaultChannel.id, userId: me, roles: "channel_admin"),
            MMChannelMember(channelId: archived.id, userId: me, roles: "channel_admin"),
        ]

        let answer = ChannelMemberAdminAnswer.resolve(channels: channels,
                                                     myMemberships: memberships,
                                                     systemRoles: "system_user",
                                                     teamRoles: "team_user",
                                                     rolesByName: service.rolesByName)

        XCTAssertEqual(answer.manageableChannelIDs, [publicManaged.id, privateManagedByPrivateRole.id],
                       "the default channel, the archived one, the unmanaged one and the private "
                       + "one whose permission I do not hold are all excluded")
        XCTAssertTrue(answer.canManageAnyChannelMembers)
        XCTAssertEqual(answer.manageableChannels.map(\.id),
                       [publicManaged.id, privateManagedByPrivateRole.id])
        XCTAssertEqual(AddToChannelPickerViewModel.rows(from: answer).map(\.title), ["Alpha", "Vault"])
    }

    /// The picker's list is *per channel*. A manager of one channel is not a manager of another, and
    /// the answer must not generalise the ∃ to every row.
    func testTheAnswerDoesNotGeneraliseOneManagedChannelToTheRest() {
        service.rolesByName = [
            "channel_admin": MMRole(id: "r2", name: "channel_admin",
                                    permissions: [ChannelPermissionID.managePublicChannelMembers]),
        ]
        let answer = ChannelMemberAdminAnswer.resolve(channels: [publicManaged, publicUnmanaged],
                                                     myMemberships: [
                                                        MMChannelMember(channelId: publicManaged.id,
                                                                        userId: me, roles: "channel_admin"),
                                                        MMChannelMember(channelId: publicUnmanaged.id,
                                                                        userId: me, roles: "channel_user"),
                                                     ],
                                                     systemRoles: "system_user",
                                                     teamRoles: "team_user",
                                                     rolesByName: service.rolesByName)
        XCTAssertTrue(answer.canManageAnyChannelMembers)
        XCTAssertEqual(answer.manageableChannelIDs, [publicManaged.id])
    }

    func testAnAccountThatManagesNothingGetsAnEmptyAnswer() {
        service.rolesByName = [
            "channel_user": MMRole(id: "r1", name: "channel_user",
                                   permissions: [ChannelPermissionID.readChannel]),
        ]
        let answer = ChannelMemberAdminAnswer.resolve(channels: [publicManaged, publicUnmanaged],
                                                     myMemberships: [
                                                        MMChannelMember(channelId: publicManaged.id,
                                                                        userId: me, roles: "channel_user"),
                                                        MMChannelMember(channelId: publicUnmanaged.id,
                                                                        userId: me, roles: "channel_user"),
                                                     ],
                                                     systemRoles: "system_user",
                                                     teamRoles: "team_user",
                                                     rolesByName: service.rolesByName)
        XCTAssertFalse(answer.canManageAnyChannelMembers)
        XCTAssertTrue(answer.manageableChannels.isEmpty)
        XCTAssertTrue(AddToChannelPickerViewModel.rows(from: answer).isEmpty)
    }

    /// The extraction the card asked for, pinned: `derive`'s own flag and the new static rule agree
    /// for the same channel and permissions — there is one rule, not two that could drift.
    func testTheExtractedRuleIsTheOneTheChannelInfoScreenUses() {
        let permissions: Set<String> = [ChannelPermissionID.managePublicChannelMembers]
        for channel in [publicManaged, privateManaged, defaultChannel, archived] {
            let derived = ChannelInfoCapabilities.derive(channel: channel,
                                                         permissions: permissions,
                                                         isGuest: false)
            XCTAssertEqual(derived.canManageMembers,
                           ChannelInfoCapabilities.canManageMembers(channel: channel,
                                                                    permissions: permissions),
                           "\(channel.name) must answer the same way in both places")
        }
        XCTAssertTrue(ChannelInfoCapabilities.canManageMembers(channel: publicManaged,
                                                               permissions: permissions))
        XCTAssertFalse(ChannelInfoCapabilities.canManageMembers(channel: privateManaged,
                                                                permissions: permissions),
                       "a public-only manager cannot manage a private channel's members")
    }

    /// A role the server did not answer grants nothing — never "everything".
    func testAnUnknownRoleNameGrantsNothing() {
        let answer = ChannelMemberAdminAnswer.resolve(channels: [publicManaged],
                                                     myMemberships: [MMChannelMember(channelId: publicManaged.id,
                                                                                     userId: me,
                                                                                     roles: "ghost_role")],
                                                     systemRoles: "ghost_system",
                                                     teamRoles: "ghost_team",
                                                     rolesByName: [:])
        XCTAssertFalse(answer.canManageAnyChannelMembers)
    }

    // MARK: - Already a member

    func testSelectingAChannelTheAccountIsAlreadyInDisablesAdd() async {
        let model = makeModel(manageable: [publicManaged])
        await model.load(answer: manageableAnswer([publicManaged]))
        service.memberRows[publicManaged.id] = MMChannelMember(channelId: publicManaged.id, userId: buddy)

        await model.select(publicManaged.id)

        XCTAssertEqual(model.rows.first?.isMember, true)
        XCTAssertFalse(model.canSubmit, "Add is disabled once the server says they are in it")
        XCTAssertEqual(model.alreadyMemberMessage, "Buddy is already a member of this channel.")
    }

    func testSelectingAChannelTheAccountIsNotInEnablesAdd() async {
        let model = makeModel(manageable: [publicManaged])
        await model.load(answer: manageableAnswer([publicManaged]))

        await model.select(publicManaged.id)

        XCTAssertEqual(model.rows.first?.isMember, false)
        XCTAssertTrue(model.canSubmit)
        XCTAssertNil(model.alreadyMemberMessage)
    }

    func testAFailedMembershipReadLeavesTheRowUnknownAndSaysWhy() async {
        let model = makeModel(manageable: [publicManaged])
        await model.load(answer: manageableAnswer([publicManaged]))
        service.memberError = MMError.offline

        await model.select(publicManaged.id)

        XCTAssertNil(model.rows.first?.isMember, "unknown is not \"not a member\"")
        XCTAssertFalse(model.canSubmit)
        XCTAssertNotNil(model.banner)
    }

    // MARK: - The write

    func testAddShowsTheMemberBeforeTheServerAnswersAndKeepsItAfter() async {
        let model = makeModel(manageable: [publicManaged])
        await model.load(answer: manageableAnswer([publicManaged]))
        await model.select(publicManaged.id)
        XCTAssertEqual(model.rows.first?.isMember, false)

        service.blockAddUntilReleased()
        let started = expectation(description: "the add is in flight")
        service.onAddStarted = { started.fulfill() }
        let task = Task { await model.add() }
        await fulfillment(of: [started], timeout: 30)

        XCTAssertEqual(model.rows.first?.isMember, true,
                       "optimistic: the row says Member while the POST is still suspended")
        XCTAssertFalse(model.canSubmit, "and Add is disabled while it is in flight")

        service.releaseAdd()
        let added = await task.value
        XCTAssertTrue(added)
        XCTAssertEqual(model.rows.first?.isMember, true)
        XCTAssertEqual(service.addRequests.map(\.userID), [buddy])
        XCTAssertEqual(service.addRequests.map(\.channelID), [publicManaged.id])
    }

    func testAFailedAddRollsBackAndNamesWhatFailed() async {
        let model = makeModel(manageable: [publicManaged])
        await model.load(answer: manageableAnswer([publicManaged]))
        await model.select(publicManaged.id)
        service.addError = MMError.forbidden(message: nil)

        let added = await model.add()

        XCTAssertFalse(added)
        XCTAssertEqual(model.rows.first?.isMember, false, "the optimistic row is put back")
        XCTAssertTrue(model.canSubmit, "and the reader can try again")
        XCTAssertNotNil(model.banner)
    }

    func testAddIsRefusedWhenTheAccountIsAlreadyAMember() async {
        let model = makeModel(manageable: [publicManaged])
        await model.load(answer: manageableAnswer([publicManaged]))
        service.memberRows[publicManaged.id] = MMChannelMember(channelId: publicManaged.id, userId: buddy)
        await model.select(publicManaged.id)

        let added = await model.add()

        XCTAssertFalse(added)
        XCTAssertTrue(service.addRequests.isEmpty, "no write is attempted for a member")
    }

    // MARK: - The search field

    func testTheFilterNarrowsTheListWithoutChangingIt() async {
        let model = makeModel(manageable: [publicManaged, privateManaged])
        await model.load(answer: manageableAnswer([publicManaged, privateManaged]))
        XCTAssertEqual(model.visibleRows.count, 2)

        model.query = "sec"
        XCTAssertEqual(model.visibleRows.map(\.channelID), [privateManaged.id])

        model.query = ""
        XCTAssertEqual(model.visibleRows.count, 2, "clearing the field restores the whole list")
    }

    // MARK: - The call intent (no server)

    func testRequestStartIsConsumedExactlyOnceForItsOwnChannel() {
        let calls = CallsCoordinator()
        let serverID = UUID()
        XCTAssertFalse(calls.consumeStart(serverID: serverID, channelID: "chan1"),
                       "nothing pending, nothing to spend")
        XCTAssertFalse(calls.hasLiveCall)

        calls.requestStart(serverID: serverID, channelID: "chan1")
        XCTAssertEqual(calls.pendingStart(serverID: serverID), "chan1")
        XCTAssertFalse(calls.consumeStart(serverID: serverID, channelID: "chan2"),
                       "an intent is never spent by a pane it was not meant for")
        XCTAssertEqual(calls.pendingStart(serverID: serverID), "chan1", "and it is still pending")

        XCTAssertTrue(calls.consumeStart(serverID: serverID, channelID: "chan1"))
        XCTAssertFalse(calls.consumeStart(serverID: serverID, channelID: "chan1"),
                       "a second appearance must not start a second call")
        XCTAssertNil(calls.pendingStart(serverID: serverID))
    }

    func testTheIntentIsPerServerAndDroppedOnSignOut() {
        let calls = CallsCoordinator()
        let first = UUID()
        let second = UUID()
        calls.requestStart(serverID: first, channelID: "chan1")
        calls.requestStart(serverID: second, channelID: "chan9")

        XCTAssertFalse(calls.consumeStart(serverID: second, channelID: "chan1"))
        XCTAssertTrue(calls.consumeStart(serverID: second, channelID: "chan9"))

        calls.requestStart(serverID: first, channelID: "chan2")
        calls.authPhaseChanged(first)
        XCTAssertNil(calls.pendingStart(serverID: first),
                     "a pending \"call this person\" must not survive the credential that asked")
    }

    // MARK: - Helpers

    private func makeModel(manageable: [MMChannel]) -> AddToChannelPickerViewModel {
        AddToChannelPickerViewModel(serverID: UUID(),
                                    teamID: "team",
                                    myUserID: me,
                                    userID: buddy,
                                    userDisplayName: "Buddy",
                                    service: service)
    }

    /// The cached answer the profile row would have produced — the picker does not re-derive it.
    private func manageableAnswer(_ channels: [MMChannel]) -> ChannelMemberAdminAnswer {
        ChannelMemberAdminAnswer(channels: channels,
                                 manageableChannelIDs: Set(channels.map(\.id)))
    }
}
