// T40 — the rules behind the channel-info surface, with no network and no clock.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0, `app/queries/servers/role.ts`
// (the capability observers), `app/utils/channel/index.ts` (`isDefaultChannel`, `validateDisplayName`),
// `app/screens/create_or_edit_channel/` (the patch body), `app/screens/manage_channel_members/`
// (`sortUsers`), `app/screens/channel_settings/archive/` (the confirmations),
// `app/components/channel_actions/leave_channel_label` (the DM/GM close), `app/screens/browse_channels/`.
//
// Everything here is asserted through the seams the screen actually uses:
//   * `ChannelInfoCapabilities.derive` for the gates (a permission `Set`, never a role name);
//   * `ChannelPatchDraft` for what a save sends;
//   * `ChannelMemberDerivation` for the list's rows;
//   * `ChannelInfoViewModel` against a fake `ChannelInfoServing` for the writes and the socket;
//   * `BrowseChannelsViewModel` for join-and-navigate.
//
// The measured server facts these tests are built on are in the source headers and are re-measurable
// with `scripts/t40_channel_probe.py` against the pinned 9.11.19 server.

import XCTest
import SwiftUI
@testable import Mattermost

@MainActor
final class T40ChannelInfoTests: XCTestCase {

    private let channelID = "chan0000000000000000000001"
    private let teamID = "team0000000000000000000001"
    private let myUserID = "user0000000000000000000001"

    // MARK: - Fakes

    /// A `ChannelInfoServing` that answers from memory and records every write.
    @MainActor
    final class FakeChannelInfoService: ChannelInfoServing {
        var memberPageSize = 60
        var pickerPageSize = 50

        var channel = MMChannel(id: "chan0000000000000000000001",
                                name: "off-topic",
                                displayName: "Off-Topic",
                                type: "O",
                                teamId: "team0000000000000000000001",
                                header: "",
                                purpose: "")
        var statsValue = MMChannelStats(channelID: "chan0000000000000000000001", memberCount: 3)
        var principalValue = MMPrincipal(id: "user0000000000000000000001",
                                    username: "me",
                                    roles: "system_user")
        var myMembership: MMChannelMember? = MMChannelMember(channelId: "chan0000000000000000000001",
                                                            userId: "user0000000000000000000001",
                                                            roles: "channel_user")
        var myTeamMembership: MMTeamMembership? = MMTeamMembership(userId: "user0000000000000000000001",
                                                                   teamId: "team0000000000000000000001",
                                                                   roles: "team_user")
        /// role name → the role the server would answer.
        var rolesByName: [String: MMRole] = [:]
        /// Pages of memberships, served in order; the last one repeats.
        var memberPages: [[MMChannelMember]] = [[]]
        var usersByID: [String: MMUser] = [:]
        var statusesByID: [String: MMStatus] = [:]
        var addFailure: Error?
        var removeFailure: Error?
        var patchFailure: Error?
        var archiveFailure: Error?
        var restoreFailure: Error?
        var closeFailure: Error?
        var channelFailure: Error?
        var teamChannels: [MMChannel] = []
        var publicChannels: [MMChannel] = []
        var archivedChannels: [MMChannel] = []
        var notInChannel: [MMUser] = []
        var searchResults: [MMUser] = []
        var addMemberResult: (String) -> MMChannelMember = { userID in
            MMChannelMember(channelId: "chan0000000000000000000001", userId: userID)
        }

        private(set) var roleRequests: [[String]] = []
        private(set) var addCalls: [(channelID: String, userID: String)] = []
        private(set) var removeCalls: [(channelID: String, userID: String)] = []
        private(set) var closeCalls: [(userID: String, channelID: String)] = []
        private(set) var patchCalls: [MMChannelPatch] = []
        private(set) var archiveCalls = 0
        private(set) var restoreCalls = 0
        private(set) var memberPageRequests: [Int] = []
        private(set) var userIDRequests: [[String]] = []
        private var servedPages = 0

        /// Give every role name the given permission set (the server's own shape: roles carry ids).
        func grant(_ permissions: [String],
                   to roleNames: [String] = ["system_user", "team_user", "channel_user"]) {
            for name in roleNames {
                rolesByName[name] = MMRole(id: "role-\(name)", name: name, permissions: permissions)
            }
        }

        func channel(id: String) async throws -> MMChannel {
            if let channelFailure { throw channelFailure }
            return channel
        }

        func stats(channelID: String) async throws -> MMChannelStats { self.statsValue }

        func principal() async throws -> MMPrincipal { self.principalValue }

        func myMembership(channelID: String) async throws -> MMChannelMember {
            guard let myMembership else { throw MMError.notFound }
            return myMembership
        }

        func myTeamMembership(teamID: String) async throws -> MMTeamMembership {
            guard let myTeamMembership else { throw MMError.notFound }
            return myTeamMembership
        }

        /// This fake only answers about its own principal: another id is "no such membership",
        /// which is the same shape the server gives for an account that is not in the team.
        func teamMembership(teamID: String, userID: String) async throws -> MMTeamMembership {
            let mine = try await myTeamMembership(teamID: teamID)
            guard mine.userId == userID else { throw MMError.notFound }
            return mine
        }

        func rolePermissions(names: [String]) async throws -> [MMRole] {
            roleRequests.append(names)
            return names.compactMap { rolesByName[$0] }
        }

        func members(channelID: String, page: Int, perPage: Int) async throws -> [MMChannelMember] {
            memberPageRequests.append(page)
            let pageRows = memberPages[min(page, memberPages.count - 1)]
            servedPages += 1
            return pageRows
        }

        func member(channelID: String, userID: String) async throws -> MMChannelMember {
            addMemberResult(userID)
        }

        func users(ids: [String]) async throws -> [MMUser] {
            userIDRequests.append(ids)
            return ids.compactMap { usersByID[$0] }
        }

        func statuses(ids: [String]) async throws -> [MMStatus] {
            ids.compactMap { statusesByID[$0] }
        }

        func patch(channelID: String, patch: MMChannelPatch) async throws -> MMChannel {
            patchCalls.append(patch)
            if let patchFailure { throw patchFailure }
            var updated = channel
            if let displayName = patch.displayName { updated.displayName = displayName }
            if let purpose = patch.purpose { updated.purpose = purpose }
            if let header = patch.header { updated.header = header }
            channel = updated
            return updated
        }

        func archive(channelID: String) async throws -> MMChannel {
            archiveCalls += 1
            if let archiveFailure { throw archiveFailure }
            var archived = channel
            archived.deleteAt = 1_793_021_123_729
            channel = archived
            return archived
        }

        func restore(channelID: String) async throws -> MMChannel {
            restoreCalls += 1
            if let restoreFailure { throw restoreFailure }
            var restored = channel
            restored.deleteAt = 0
            channel = restored
            return restored
        }

        func addMember(channelID: String, userID: String) async throws -> MMChannelMember {
            addCalls.append((channelID, userID))
            if let addFailure { throw addFailure }
            return addMemberResult(userID)
        }

        func removeMember(channelID: String, userID: String) async throws {
            removeCalls.append((channelID, userID))
            if let removeFailure { throw removeFailure }
        }

        func closeDirectChannel(userID: String, channelID: String) async throws {
            closeCalls.append((userID, channelID))
            if let closeFailure { throw closeFailure }
        }

        func myTeamChannels(teamID: String) async throws -> [MMChannel] { teamChannels }

        func teamPublicChannels(teamID: String, page: Int, perPage: Int) async throws -> [MMChannel] {
            page == 0 ? publicChannels : []
        }

        func archivedTeamChannels(teamID: String, page: Int, perPage: Int) async throws -> [MMChannel] {
            archivedChannels
        }

        func usersNotInChannel(teamID: String, channelID: String,
                               page: Int, perPage: Int) async throws -> [MMUser] {
            page == 0 ? notInChannel : []
        }

        func searchUsersNotInChannel(teamID: String, channelID: String, term: String) async throws -> [MMUser] {
            searchResults
        }
    }

    private func makeModel(service: FakeChannelInfoService,
                           type: String = "O",
                           name: String = "off-topic") -> ChannelInfoViewModel {
        service.channel.type = type
        service.channel.name = name
        return ChannelInfoViewModel(channelID: service.channel.id,
                                    teamID: teamID,
                                    fallbackTitle: nil,
                                    service: service)
    }

    private func member(_ userID: String, roles: String = "channel_user", admin: Bool = false)
        -> MMChannelMember {
        MMChannelMember(channelId: channelID, userId: userID, roles: roles, schemeAdmin: admin)
    }

    private func user(_ id: String, username: String, first: String, last: String) -> MMUser {
        MMUser(id: id, username: username, email: "", firstName: first, lastName: last, nickname: "")
    }

    // MARK: - Capabilities: the permission ids decide, never the role names

    func testAdminPermissionsOfferEveryActionOnAPublicChannel() {
        let caps = ChannelInfoCapabilities.derive(
            channel: MMChannel(id: channelID, name: "off-topic", displayName: "Off-Topic", type: "O"),
            permissions: [ChannelPermissionID.managePublicChannelMembers,
                          ChannelPermissionID.managePublicChannelProperties,
                          ChannelPermissionID.deletePublicChannel,
                          ChannelPermissionID.manageTeam,
                          ChannelPermissionID.listTeamChannels,
                          ChannelPermissionID.joinPublicChannels],
            isGuest: false)
        XCTAssertTrue(caps.canManageMembers)
        XCTAssertTrue(caps.canManageSettings)
        XCTAssertTrue(caps.canLeave)
        XCTAssertTrue(caps.canArchive)
        XCTAssertFalse(caps.canUnarchive)
        XCTAssertTrue(caps.canBrowseChannels)
        XCTAssertTrue(caps.canJoinPublicChannels)
        XCTAssertEqual(caps.offeredActions,
                       [.addMembers, .members, .settings, .archive, .leave])
    }

    /// A stock member's permission set: the member list is offered, nothing else. This is the assertion
    /// the card calls a security property — the rows an administrator sees are not drawn from the role's
    /// *name*.
    func testPlainMemberIsOfferedOnlyTheMemberList() {
        let caps = ChannelInfoCapabilities.derive(
            channel: MMChannel(id: channelID, name: "off-topic", displayName: "Off-Topic", type: "O"),
            permissions: [ChannelPermissionID.readChannel],
            isGuest: false)
        XCTAssertFalse(caps.canManageMembers)
        XCTAssertFalse(caps.canManageSettings)
        XCTAssertFalse(caps.canArchive)
        XCTAssertFalse(caps.canUnarchive)
        XCTAssertTrue(caps.canLeave)
        XCTAssertEqual(caps.offeredActions, [.members, .leave])
    }

    /// The role-name trap: a role called `channel_admin` whose permission array is empty grants nothing.
    /// (The mirror case is real — the fixture's `channel_user` carries `delete_public_channel` — which is
    /// why the gate never reads a name.)
    func testRoleNameGrantsNothingWithoutPermissions() {
        let roles = [MMRole(id: "r1", name: "channel_admin", permissions: []),
                     MMRole(id: "r2", name: "system_admin", permissions: [])]
        let permissions = ChannelPermissions.union(roles: roles)
        XCTAssertTrue(permissions.isEmpty)
        let caps = ChannelInfoCapabilities.derive(
            channel: MMChannel(id: channelID, name: "off-topic", type: "O"),
            permissions: permissions,
            isGuest: false)
        XCTAssertEqual(caps.offeredActions, [.members, .leave])
    }

    func testAPermissiveRoleNamedUserStillGrantsItsPermissions() {
        // The measured inverse of the test above: this server's `channel_user` really does carry the
        // administrator ids, and the screen must follow the ids (hiding an allowed action is a bug too).
        let capabilities = ChannelInfoCapabilities.derive(
            channel: MMChannel(id: channelID, name: "off-topic", type: "O"),
            permissions: [ChannelPermissionID.deletePublicChannel,
                          ChannelPermissionID.managePublicChannelMembers],
            isGuest: false)
        XCTAssertTrue(capabilities.canArchive)
        XCTAssertTrue(capabilities.canManageMembers)
    }

    func testNoChannelOffersNothing() {
        let caps = ChannelInfoCapabilities.derive(channel: nil,
                                                  permissions: Set(ChannelPermissionID.all),
                                                  isGuest: false)
        XCTAssertEqual(caps, .none)
        XCTAssertTrue(caps.offeredActions.isEmpty)
    }

    func testDirectAndGroupMessagesOfferNoAdminActions() {
        for type in ["D", "G"] {
            let caps = ChannelInfoCapabilities.derive(
                channel: MMChannel(id: channelID, name: "dm", type: type),
                permissions: Set(ChannelPermissionID.all),
                isGuest: false)
            XCTAssertFalse(caps.canManageMembers, "type \(type)")
            XCTAssertFalse(caps.canManageSettings, "type \(type)")
            XCTAssertFalse(caps.canArchive, "type \(type)")
            XCTAssertFalse(caps.canUnarchive, "type \(type)")
            XCTAssertTrue(caps.canLeave, "type \(type)")
            XCTAssertEqual(caps.offeredActions, [.members, .leave], "type \(type)")
        }
    }

    func testDefaultChannelCannotBeLeftOrManagedExceptByAGuest() {
        let member = ChannelInfoCapabilities.derive(
            channel: MMChannel(id: channelID, name: "town-square", type: "O"),
            permissions: Set(ChannelPermissionID.all),
            isGuest: false)
        XCTAssertFalse(member.canManageMembers)
        XCTAssertFalse(member.canLeave)
        XCTAssertFalse(member.canArchive)
        XCTAssertEqual(member.offeredActions, [.members, .settings])

        let guest = ChannelInfoCapabilities.derive(
            channel: MMChannel(id: channelID, name: "town-square", type: "O"),
            permissions: [ChannelPermissionID.readChannel],
            isGuest: true)
        XCTAssertTrue(guest.canLeave)
        XCTAssertTrue(guest.offeredActions.contains(.leave))
    }

    func testArchivedChannelLosesManagementAndOffersUnarchiveToATeamAdmin() {
        let archived = MMChannel(id: channelID, name: "old-stuff", type: "O", deleteAt: 1_793_021_123_729)
        let admin = ChannelInfoCapabilities.derive(
            channel: archived,
            permissions: [ChannelPermissionID.managePublicChannelMembers,
                          ChannelPermissionID.managePublicChannelProperties,
                          ChannelPermissionID.deletePublicChannel,
                          ChannelPermissionID.manageTeam],
            isGuest: false)
        XCTAssertFalse(admin.canManageMembers)
        XCTAssertFalse(admin.canManageSettings)
        XCTAssertFalse(admin.canArchive)
        XCTAssertTrue(admin.canUnarchive)
        XCTAssertEqual(admin.offeredActions, [.members, .unarchive, .leave])

        let member = ChannelInfoCapabilities.derive(channel: archived,
                                                    permissions: [ChannelPermissionID.readChannel],
                                                    isGuest: false)
        XCTAssertFalse(member.canUnarchive)
        XCTAssertEqual(member.offeredActions, [.members, .leave])
    }

    /// The private-channel gates are separate ids: holding the *public* ones must not unlock a private
    /// channel (a server that grants only the public pair is a common configuration).
    func testPrivateChannelUsesItsOwnPermissionIds() {
        let caps = ChannelInfoCapabilities.derive(
            channel: MMChannel(id: channelID, name: "secret", type: "P"),
            permissions: [ChannelPermissionID.managePublicChannelMembers,
                          ChannelPermissionID.managePublicChannelProperties,
                          ChannelPermissionID.deletePublicChannel],
            isGuest: false)
        XCTAssertFalse(caps.canManageMembers)
        XCTAssertFalse(caps.canManageSettings)
        XCTAssertFalse(caps.canArchive)

        let allowed = ChannelInfoCapabilities.derive(
            channel: MMChannel(id: channelID, name: "secret", type: "P"),
            permissions: [ChannelPermissionID.managePrivateChannelMembers,
                          ChannelPermissionID.managePrivateChannelProperties,
                          ChannelPermissionID.deletePrivateChannel],
            isGuest: false)
        XCTAssertTrue(allowed.canManageMembers)
        XCTAssertTrue(allowed.canManageSettings)
        XCTAssertTrue(allowed.canArchive)
    }

    func testAnUnknownChannelTypeIsTreatedAsPublic() {
        let caps = ChannelInfoCapabilities.derive(
            channel: MMChannel(id: channelID, name: "future", type: "X"),
            permissions: [ChannelPermissionID.managePublicChannelMembers],
            isGuest: false)
        XCTAssertEqual(caps.kind, .open)
        XCTAssertTrue(caps.canManageMembers)
    }

    // MARK: - Role union

    func testRoleNamesUnionAllThreeSourcesAndDeduplicate() {
        let names = ChannelPermissions.roleNames(systemRoles: "system_user system_admin",
                                                 teamRoles: "team_user",
                                                 channelRoles: "channel_user system_user")
        XCTAssertEqual(names, ["system_user", "system_admin", "team_user", "channel_user"])
    }

    func testPermissionUnionIsTheRolesOwnIds() {
        let roles = [MMRole(id: "1", name: "system_user", permissions: ["read_channel"]),
                     MMRole(id: "2", name: "channel_user", permissions: ["create_post"])]
        XCTAssertEqual(ChannelPermissions.union(roles: roles), ["read_channel", "create_post"])
    }

    // MARK: - The settings form

    func testUnchangedDraftSendsNoPatch() {
        let channel = MMChannel(id: channelID, name: "off-topic", displayName: "Off-Topic", type: "O",
                                header: "h", purpose: "p")
        let draft = ChannelPatchDraft(channel: channel)
        XCTAssertFalse(draft.isDirty(comparedTo: channel, kind: .open))
        XCTAssertNil(draft.patch(comparedTo: channel, kind: .open))
        XCTAssertNil(draft.validation(for: .open))
    }

    func testPurposeOnlyEditSendsOnlyThePurpose() throws {
        let channel = MMChannel(id: channelID, name: "off-topic", displayName: "Off-Topic", type: "O",
                                header: "keep me", purpose: "old")
        var draft = ChannelPatchDraft(channel: channel)
        draft.purpose = "new purpose"
        let patch = try XCTUnwrap(draft.patch(comparedTo: channel, kind: .open))
        XCTAssertEqual(patch.purpose, "new purpose")
        XCTAssertNil(patch.header)
        XCTAssertNil(patch.displayName)
        // The encoder must omit a nil field entirely rather than send `null` (which the server reads as
        // "set this to empty").
        let json = String(decoding: try JSONEncoder().encode(patch), as: UTF8.self)
        XCTAssertTrue(json.contains("\"purpose\""))
        XCTAssertFalse(json.contains("\"header\""))
        XCTAssertFalse(json.contains("null"))
    }

    func testDirectMessagePatchCarriesOnlyTheHeader() {
        let channel = MMChannel(id: channelID, name: "dm", type: "D", header: "old")
        var draft = ChannelPatchDraft(channel: channel)
        draft.displayName = "ignored"
        draft.purpose = "ignored"
        draft.header = "new header"
        let patch = draft.patch(comparedTo: channel, kind: .direct)
        XCTAssertEqual(patch?.header, "new header")
        XCTAssertNil(patch?.displayName)
        XCTAssertNil(patch?.purpose)
    }

    func testFieldLimitsAreTheServersOwn() {
        let channel = MMChannel(id: channelID, name: "off-topic", displayName: "Off-Topic", type: "O")
        var atLimits = ChannelPatchDraft(channel: channel)
        atLimits.displayName = String(repeating: "d", count: 64)
        atLimits.purpose = String(repeating: "p", count: 250)
        atLimits.header = String(repeating: "h", count: 1024)
        XCTAssertNil(atLimits.validation(for: .open))

        var overPurpose = atLimits
        overPurpose.purpose = String(repeating: "p", count: 251)
        XCTAssertEqual(overPurpose.validation(for: .open),
                       "The purpose must be 250 characters or fewer.")

        var overHeader = atLimits
        overHeader.header = String(repeating: "h", count: 1025)
        XCTAssertEqual(overHeader.validation(for: .open),
                       "The header must be 1024 characters or fewer.")

        var overName = atLimits
        overName.displayName = String(repeating: "d", count: 65)
        XCTAssertEqual(overName.validation(for: .open),
                       "The name must be 64 characters or fewer.")

        var emptyName = ChannelPatchDraft(channel: channel)
        emptyName.displayName = "   "
        XCTAssertEqual(emptyName.validation(for: .open), "A channel name is required.")
    }

    // MARK: - Member rows

    func testMemberRowsSortByDisplayNameAndCarryTheAdminBadge() {
        let members = [member("u1", roles: "channel_user"),
                       member("u2", roles: "channel_admin", admin: true),
                       member("u3", roles: "channel_user")]
        let users = ["u1": user("u1", username: "zoe", first: "Zoe", last: "Adams"),
                     "u2": user("u2", username: "amy", first: "amy", last: "Baker"),
                     "u3": user("u3", username: "bob", first: "Bob", last: "Clark")]
        let statuses = ["u2": MMStatus(userId: "u2", status: "online")]
        let rows = ChannelMemberDerivation.rows(members: members, users: users,
                                               statuses: statuses, myUserID: "u3")
        XCTAssertEqual(rows.map(\.displayName), ["amy Baker", "Bob Clark", "Zoe Adams"])
        XCTAssertEqual(rows[0].roleLabel, "Channel Admin")
        XCTAssertEqual(rows[1].roleLabel, "")
        XCTAssertTrue(rows[1].isMe)
        XCTAssertEqual(rows.first(where: { $0.id == "u2" })?.status, "online")
        // A missing status is "unknown", never "offline".
        XCTAssertEqual(rows.first(where: { $0.id == "u1" })?.status, "")
        XCTAssertEqual(rows.first(where: { $0.id == "u1" })?.statusLabel, "Unknown")
    }

    func testAdminFallbackComesFromTheRolesStringWhenSchemeAdminIsAbsent() {
        let rows = ChannelMemberDerivation.rows(members: [member("u1", roles: "channel_admin", admin: false)],
                                               users: ["u1": user("u1", username: "a", first: "A", last: "B")],
                                               statuses: [:],
                                               myUserID: nil)
        XCTAssertTrue(rows[0].isChannelAdmin)
    }

    func testMissingProfileFallsBackToTheUserID() {
        let rows = ChannelMemberDerivation.rows(members: [member("u9")], users: [:], statuses: [:],
                                                myUserID: nil)
        XCTAssertEqual(rows[0].displayName, "u9")
        XCTAssertEqual(rows[0].initials, "U")
        XCTAssertFalse(rows[0].initials.isEmpty)
    }

    func testInitialsAreGraphemeSafe() {
        XCTAssertEqual(ChannelMemberDerivation.initials("Ada Lovelace"), "AL")
        XCTAssertEqual(ChannelMemberDerivation.initials("Grace Brewster Murray Hopper"), "GB")
        XCTAssertEqual(ChannelMemberDerivation.initials("madonna"), "M")
        XCTAssertEqual(ChannelMemberDerivation.initials("😀 Comet"), "😀C")
        XCTAssertEqual(ChannelMemberDerivation.initials(""), "?")
    }

    // MARK: - Leave / archive copy and the DM rule

    func testLeaveIsACloseForDirectAndGroupMessages() {
        XCTAssertEqual(ChannelLeavePrompt.make(kind: .open, displayName: "off-topic").action, .leave)
        XCTAssertEqual(ChannelLeavePrompt.make(kind: .privateChannel, displayName: "secret").action, .leave)
        XCTAssertEqual(ChannelLeavePrompt.make(kind: .direct, displayName: "Ada").action, .closeDirectMessage)
        XCTAssertEqual(ChannelLeavePrompt.make(kind: .group, displayName: "Ada, Grace").action, .closeDirectMessage)
        XCTAssertEqual(ChannelLeavePrompt.make(kind: .direct, displayName: "Ada").title,
                       "Close direct message")
        XCTAssertEqual(ChannelLeavePrompt.make(kind: .open, displayName: "off-topic").title,
                       "Leave channel")
    }

    func testArchiveCopyNamesTheChannelType() {
        let prompt = ChannelArchivePrompt.archive(kind: .privateChannel, displayName: "secret")
        XCTAssertEqual(prompt.title, "Archive private channel")
        XCTAssertTrue(prompt.message.contains("private channel secret"))
        let unarchive = ChannelArchivePrompt.unarchive(kind: .open, displayName: "old")
        XCTAssertEqual(unarchive.title, "Unarchive public channel")
    }

    // MARK: - Browse derivation

    func testBrowseSplitsJoinedFromOthersAndFiltersByTerm() {
        let joined = MMChannel(id: "c1", name: "off-topic", displayName: "Off-Topic", type: "O")
        let other = MMChannel(id: "c2", name: "café", displayName: "Café", type: "O")
        let dm = MMChannel(id: "c3", name: "dm", displayName: "Ada", type: "D")
        let archived = MMChannel(id: "c4", name: "old", displayName: "Old", type: "O", deleteAt: 99)
        let entries = BrowseChannelsDerivation.entries(channels: [joined, other, dm, archived],
                                                      joined: ["c1"],
                                                      term: "")
        // One list, alphabetically by display name (diacritic-insensitive: Café before Off-Topic before
        // Old) — `sections` is what groups it, and a DM never appears. The grouping is not baked into
        // the order, so a typed term keeps the same sort as the unfiltered list.
        XCTAssertEqual(entries.map(\.id), ["c2", "c1", "c4"])
        let sections = BrowseChannelsDerivation.sections(entries)
        XCTAssertEqual(sections.joined.map(\.id), ["c1"])
        XCTAssertEqual(sections.others.map(\.id), ["c2", "c4"])
        XCTAssertTrue(entries.first { $0.id == "c4" }?.isJoinable == false)

        // Diacritic-insensitive on the display name, and the URL name is searchable too.
        XCTAssertEqual(BrowseChannelsDerivation.entries(channels: [joined, other, dm, archived],
                                                        joined: [], term: "cafe").map(\.id), ["c2"])
        XCTAssertEqual(BrowseChannelsDerivation.entries(channels: [joined, other, dm, archived],
                                                        joined: [], term: "off").map(\.id), ["c1"])
        XCTAssertTrue(BrowseChannelsDerivation.entries(channels: [joined, other, dm, archived],
                                                       joined: [], term: "zzz").isEmpty)
    }

    // MARK: - View model: load

    func testLoadDerivesCapabilitiesMembersAndCount() async {
        let service = FakeChannelInfoService()
        service.statsValue = MMChannelStats(channelID: channelID, memberCount: 2)
        service.memberPages = [[member("u1"), member("u2")]]
        service.usersByID = ["u1": user("u1", username: "ada", first: "Ada", last: "Lovelace"),
                             "u2": user("u2", username: "grace", first: "Grace", last: "Hopper")]
        service.principalValue = MMPrincipal(id: myUserID, username: "ada", roles: "system_user")
        service.myTeamMembership = MMTeamMembership(userId: myUserID, teamId: teamID, roles: "team_user")
        service.grant([ChannelPermissionID.managePublicChannelMembers,
                       ChannelPermissionID.managePublicChannelProperties])
        let model = makeModel(service: service)

        await model.load()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.capabilities.canManageMembers)
        XCTAssertTrue(model.capabilities.canManageSettings)
        XCTAssertFalse(model.capabilities.canArchive)
        XCTAssertEqual(model.memberRows.map(\.username), ["ada", "grace"])
        XCTAssertEqual(model.memberCountText, "2 members")
        XCTAssertEqual(model.header?.title, "Off-Topic")
        XCTAssertEqual(model.header?.membersText, "2 members")
        XCTAssertTrue(model.permissionsAvailable)
        // One role request for the union, not one per role.
        XCTAssertEqual(service.roleRequests.count, 1)
        XCTAssertTrue(service.roleRequests[0].contains("channel_user"))
    }

    func testLoadSurfacesAChannelFailureAsARetryableState() async {
        let service = FakeChannelInfoService()
        service.channelFailure = MMError.notFound
        let model = makeModel(service: service)
        await model.load()
        XCTAssertEqual(model.phase, .failed("This channel no longer exists."))
    }

    /// The permission lookup failing must not offer anything: the screen goes read-only and says so.
    func testPermissionLookupFailureLeavesTheScreenReadOnly() async {
        let service = FakeChannelInfoService()
        service.rolesByName = [:]           // every name unknown → no permissions at all
        service.memberPages = [[member("u1")]]
        let model = makeModel(service: service)

        await model.load()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(model.permissionsAvailable)
        XCTAssertFalse(model.capabilities.canManageMembers)
        XCTAssertEqual(model.offeredActionsForTest, [.members, .leave])
        XCTAssertEqual(model.readOnlyNote,
                       "Actions are unavailable right now. Your permissions could not be checked.")
    }

    func testPagingAsksForTheNextPageOnlyWhenAFullPageCameBack() async {
        let service = FakeChannelInfoService()
        service.memberPageSize = 2
        service.memberPages = [[member("u1"), member("u2")], [member("u3")]]
        let model = makeModel(service: service)
        service.grant([ChannelPermissionID.readChannel])

        await model.load()
        XCTAssertTrue(model.hasMoreMembers)
        await model.loadMoreMembers()
        XCTAssertFalse(model.hasMoreMembers)
        XCTAssertEqual(model.memberRows.count, 3)
        XCTAssertEqual(service.memberPageRequests, [0, 1])
    }

    // MARK: - View model: writes and their gates

    func testAddMembersIsOptimisticAndConfirmedByTheServer() async {
        let service = FakeChannelInfoService()
        service.memberPages = [[member("u1")]]
        // The footer count is the server's `member_count`, not the number of rows loaded — so the fixture
        // says 1 (the only member) and the optimistic add makes it 2.
        service.statsValue = MMChannelStats(channelID: channelID, memberCount: 1)
        service.grant([ChannelPermissionID.managePublicChannelMembers])
        let model = makeModel(service: service)
        await model.load()

        let added = await model.addMembers(["u2"],
                                           profiles: ["u2": user("u2", username: "grace",
                                                                 first: "Grace", last: "Hopper")])
        XCTAssertTrue(added)
        XCTAssertEqual(service.addCalls.map(\.userID), ["u2"])
        XCTAssertTrue(model.memberRows.contains { $0.id == "u2" })
        XCTAssertEqual(model.memberCountText, "2 members")   // 1 from stats + the optimistic row
    }

    func testAFailedAddRollsTheOptimisticRowBack() async {
        let service = FakeChannelInfoService()
        service.memberPages = [[member("u1")]]
        service.addFailure = MMError.forbidden(message: nil)
        service.grant([ChannelPermissionID.managePublicChannelMembers])
        let model = makeModel(service: service)
        await model.load()

        let added = await model.addMembers(["u2"])

        XCTAssertFalse(added)
        XCTAssertFalse(model.memberRows.contains { $0.id == "u2" })
        XCTAssertEqual(model.banner, "You do not have permission to do that.")
    }

    /// The defence in depth: even asked directly, a view model whose capability is false performs no
    /// write. This is what "not reachable by any path" means for a UI that has no deep link into it.
    func testAddMembersWithoutThePermissionPerformsNoWrite() async {
        let service = FakeChannelInfoService()
        service.memberPages = [[member("u1")]]
        service.grant([ChannelPermissionID.readChannel])
        let model = makeModel(service: service)
        await model.load()

        let added = await model.addMembers(["u2"])

        XCTAssertFalse(added)
        XCTAssertTrue(service.addCalls.isEmpty)
        XCTAssertEqual(model.refusedMessage,
                       "You do not have permission to add members to this channel.")
    }

    func testRemoveMemberWithoutThePermissionPerformsNoWrite() async {
        let service = FakeChannelInfoService()
        service.memberPages = [[member("u1"), member("u2")]]
        service.grant([ChannelPermissionID.readChannel])
        let model = makeModel(service: service)
        await model.load()

        let removed = await model.removeMember(userID: "u2")

        XCTAssertFalse(removed)
        XCTAssertTrue(service.removeCalls.isEmpty)
        XCTAssertNotNil(model.refusedMessage)
    }

    func testRemoveMemberOptimisticallyRemovesAndRestoresOnFailure() async {
        let service = FakeChannelInfoService()
        service.memberPages = [[member("u1"), member("u2")]]
        service.removeFailure = MMError.server(status: 500, message: nil)
        service.grant([ChannelPermissionID.managePublicChannelMembers])
        let model = makeModel(service: service)
        await model.load()

        let removed = await model.removeMember(userID: "u2")

        XCTAssertFalse(removed)
        XCTAssertTrue(model.memberRows.contains { $0.id == "u2" })
        XCTAssertNotNil(model.banner)
        XCTAssertEqual(service.removeCalls.map(\.userID), ["u2"])
    }

    func testRemovingMyselfIsALeave() async {
        let service = FakeChannelInfoService()
        service.principalValue = MMPrincipal(id: myUserID, username: "me", roles: "system_user")
        service.memberPages = [[member(myUserID)]]
        service.grant([ChannelPermissionID.managePublicChannelMembers])
        let model = makeModel(service: service)
        await model.load()

        _ = await model.removeMember(userID: myUserID)

        XCTAssertEqual(service.removeCalls.map(\.userID), [myUserID])
        XCTAssertTrue(model.didLeave)
    }

    /// The card's DM/GM rule: closing a direct message writes the `direct_channel_show` preference and
    /// does **not** delete the membership row.
    func testLeavingADirectMessageClosesItInsteadOfRemovingTheMembership() async {
        let service = FakeChannelInfoService()
        service.channel = MMChannel(id: channelID, name: "dm-hash", displayName: "Ada", type: "D",
                                    teamId: teamID)
        service.memberPages = [[member(myUserID)]]
        service.principalValue = MMPrincipal(id: myUserID, username: "me", roles: "system_user")
        service.grant([ChannelPermissionID.readChannel])
        let model = makeModel(service: service, type: "D", name: "dm-hash")
        await model.load()

        let left = await model.leave()

        XCTAssertTrue(left)
        XCTAssertEqual(service.closeCalls.map(\.channelID), [channelID])
        XCTAssertTrue(service.removeCalls.isEmpty)
        XCTAssertTrue(model.didLeave)
    }

    func testLeavingAPublicChannelRemovesTheMembership() async {
        let service = FakeChannelInfoService()
        service.principalValue = MMPrincipal(id: myUserID, username: "me", roles: "system_user")
        service.memberPages = [[member(myUserID)]]
        service.grant([ChannelPermissionID.readChannel])
        let model = makeModel(service: service)
        await model.load()

        let left = await model.leave()

        XCTAssertTrue(left)
        XCTAssertEqual(service.removeCalls.map(\.userID), [myUserID])
        XCTAssertTrue(service.closeCalls.isEmpty)
    }

    func testSaveRefusesWithoutTheSettingsPermission() async {
        let service = FakeChannelInfoService()
        service.memberPages = [[member("u1")]]
        service.grant([ChannelPermissionID.managePublicChannelMembers])
        let model = makeModel(service: service)
        await model.load()

        let saved = await model.save(MMChannelPatch(displayName: "New name"))

        XCTAssertFalse(saved)
        XCTAssertTrue(service.patchCalls.isEmpty)
        XCTAssertNotNil(model.refusedMessage)
    }

    func testSaveAppliesTheServersAnswer() async {
        let service = FakeChannelInfoService()
        service.memberPages = [[member("u1")]]
        service.grant([ChannelPermissionID.managePublicChannelProperties])
        let model = makeModel(service: service)
        await model.load()

        let saved = await model.save(MMChannelPatch(purpose: "Team talk"))

        XCTAssertTrue(saved)
        XCTAssertEqual(model.channel?.purpose, "Team talk")
        XCTAssertEqual(service.patchCalls.first?.purpose, "Team talk")
    }

    func testArchiveFlipsTheScreenIntoTheArchivedState() async {
        let service = FakeChannelInfoService()
        service.memberPages = [[member("u1")]]
        service.grant([ChannelPermissionID.deletePublicChannel])
        let model = makeModel(service: service)
        await model.load()
        XCTAssertTrue(model.capabilities.canArchive)

        let archived = await model.archive()

        XCTAssertTrue(archived)
        XCTAssertTrue(model.isArchived)
        XCTAssertFalse(model.capabilities.canArchive)
        XCTAssertFalse(model.capabilities.canManageMembers)
        XCTAssertEqual(service.archiveCalls, 1)
    }

    func testUnarchiveNeedsManageTeam() async {
        let service = FakeChannelInfoService()
        service.channel = MMChannel(id: channelID, name: "old", type: "O",
                                    teamId: teamID, deleteAt: 1_793_021_123_729)
        service.memberPages = [[member("u1")]]
        service.grant([ChannelPermissionID.deletePublicChannel])
        let model = makeModel(service: service)
        await model.load()

        let refused = await model.unarchive()
        XCTAssertFalse(refused)
        XCTAssertEqual(service.restoreCalls, 0)

        service.grant([ChannelPermissionID.manageTeam])
        // The gates are derived at load time from the permission union of that load (a real server does
        // not change a user's roles under them mid-session), so a second `load` is what a freshly-granted
        // role looks like: re-read, then the action appears.
        await model.load()
        let restored = await model.unarchive()
        XCTAssertTrue(restored)
        XCTAssertEqual(service.restoreCalls, 1)
        XCTAssertFalse(model.isArchived)
    }

    // MARK: - View model: socket reconciliation

    func testUserAddedEventAddsTheMemberExactlyOnce() async {
        let service = FakeChannelInfoService()
        service.memberPages = [[member("u1")]]
        service.statsValue = MMChannelStats(channelID: channelID, memberCount: 1)
        service.grant([ChannelPermissionID.readChannel])
        let model = makeModel(service: service)
        await model.load()

        model.applyUserAdded(userID: "u2")
        model.applyUserAdded(userID: "u2")

        XCTAssertEqual(model.memberRows.filter { $0.id == "u2" }.count, 1)
        XCTAssertEqual(model.memberCountText, "2 members")
    }

    func testMyOwnRemoveEventClosesTheScreen() async {
        let service = FakeChannelInfoService()
        service.principalValue = MMPrincipal(id: myUserID, username: "me", roles: "system_user")
        service.memberPages = [[member(myUserID), member("u2")]]
        service.grant([ChannelPermissionID.readChannel])
        let model = makeModel(service: service)
        await model.load()

        model.handle(event: .userRemoved(SocketMembershipChange(channelID: channelID,
                                                                teamID: teamID,
                                                                userID: myUserID)))
        XCTAssertTrue(model.didLeave)

        // Somebody else's removal only drops their row.
        let other = makeModel(service: service)
        await other.load()
        other.handle(event: .userRemoved(SocketMembershipChange(channelID: channelID,
                                                                teamID: teamID,
                                                                userID: "u2")))
        XCTAssertFalse(other.didLeave)
        XCTAssertFalse(other.memberRows.contains { $0.id == "u2" })
    }

    func testChannelUpdatedEventRetitlesAndRegates() async {
        let service = FakeChannelInfoService()
        service.memberPages = [[member("u1")]]
        service.grant([ChannelPermissionID.managePublicChannelProperties])
        let model = makeModel(service: service)
        await model.load()
        XCTAssertTrue(model.capabilities.canManageSettings)

        var renamed = service.channel
        renamed.displayName = "Renamed"
        renamed.purpose = "New purpose"
        model.handle(event: .channelUpdated(renamed))

        XCTAssertEqual(model.header?.title, "Renamed")
        XCTAssertEqual(model.header?.purpose, "New purpose")
        XCTAssertTrue(model.capabilities.canManageSettings)
    }

    func testChannelDeletedEventShowsTheArchivedState() async {
        let service = FakeChannelInfoService()
        service.memberPages = [[member("u1")]]
        service.grant([ChannelPermissionID.deletePublicChannel])
        let model = makeModel(service: service)
        await model.load()

        model.handle(event: .channelDeleted(SocketChannelEvent(channelID: channelID,
                                                               teamID: teamID,
                                                               deleteAt: 1_793_021_123_729)))

        XCTAssertTrue(model.isArchived)
        XCTAssertFalse(model.capabilities.canArchive)
    }

    func testStatusChangeEventUpdatesAnExistingRowOnly() async {
        let service = FakeChannelInfoService()
        service.memberPages = [[member("u1")]]
        service.usersByID = ["u1": user("u1", username: "ada", first: "Ada", last: "Lovelace")]
        service.statusesByID = ["u1": MMStatus(userId: "u1", status: "offline")]
        service.grant([ChannelPermissionID.readChannel])
        let model = makeModel(service: service)
        await model.load()
        XCTAssertEqual(model.memberRows.first?.status, "offline")

        model.handle(event: .statusChange(SocketStatusChange(userID: "u1", status: "online")))
        XCTAssertEqual(model.memberRows.first?.status, "online")

        // A status for somebody who is not in the list changes nothing (no phantom row).
        model.handle(event: .statusChange(SocketStatusChange(userID: "stranger", status: "online")))
        XCTAssertEqual(model.memberRows.count, 1)
    }

    // MARK: - Browse: join and the permission gate

    func testJoinAddsTheMemberAndAnswersTheChannelToOpen() async throws {
        let service = FakeChannelInfoService()
        service.principalValue = MMPrincipal(id: myUserID, username: "me", roles: "system_user")
        service.grant([ChannelPermissionID.listTeamChannels, ChannelPermissionID.joinPublicChannels])
        service.teamChannels = []
        service.publicChannels = [MMChannel(id: "c1", name: "new-room", displayName: "New room", type: "O")]
        let model = BrowseChannelsViewModel(teamID: teamID, service: service)

        await model.load()
        XCTAssertTrue(model.canJoinPublicChannels)
        let entry = try XCTUnwrap(model.sections.others.first)
        let opened = await model.join(entry)

        XCTAssertEqual(opened, "c1")
        XCTAssertEqual(service.addCalls.map(\.userID), [myUserID])
        XCTAssertTrue(model.joinedIDs.contains("c1"))
    }

    func testJoinWithoutThePermissionPerformsNoWrite() async throws {
        let service = FakeChannelInfoService()
        service.principalValue = MMPrincipal(id: myUserID, username: "me", roles: "system_user")
        service.grant([ChannelPermissionID.listTeamChannels])
        service.publicChannels = [MMChannel(id: "c1", name: "new-room", displayName: "New room", type: "O")]
        let model = BrowseChannelsViewModel(teamID: teamID, service: service)

        await model.load()
        XCTAssertFalse(model.canJoinPublicChannels)
        let entry = try XCTUnwrap(model.sections.others.first)
        let opened = await model.join(entry)

        XCTAssertNil(opened)
        XCTAssertTrue(service.addCalls.isEmpty)
        XCTAssertEqual(model.errorMessage, "You do not have permission to join channels on this team.")
    }

    func testTappingAChannelIAmAlreadyInDoesNotJoin() async throws {
        let service = FakeChannelInfoService()
        service.principalValue = MMPrincipal(id: myUserID, username: "me", roles: "system_user")
        service.grant([ChannelPermissionID.listTeamChannels, ChannelPermissionID.joinPublicChannels])
        let joined = MMChannel(id: "c1", name: "off-topic", displayName: "Off-Topic", type: "O")
        service.teamChannels = [joined]
        service.publicChannels = [joined]
        let model = BrowseChannelsViewModel(teamID: teamID, service: service)

        await model.load()
        let entry = try XCTUnwrap(model.sections.joined.first)
        let opened = await model.join(entry)

        XCTAssertEqual(opened, "c1")
        XCTAssertTrue(service.addCalls.isEmpty)
    }

    // MARK: - The add-members picker

    func testPickerOpensOnAListAndSearchesWhenGivenATerm() async {
        let service = FakeChannelInfoService()
        service.notInChannel = [user("u1", username: "ada", first: "Ada", last: "Lovelace")]
        service.searchResults = [user("u2", username: "grace", first: "Grace", last: "Hopper")]
        let picker = AddMembersViewModel(channelID: channelID, teamID: teamID, service: service)

        await picker.load()
        XCTAssertEqual(picker.rows.map(\.id), ["u1"])

        await picker.search("gra")
        XCTAssertEqual(picker.rows.map(\.id), ["u2"])

        // Clearing the field returns to the list (a search with an empty term is a 400).
        await picker.search("")
        XCTAssertEqual(picker.rows.map(\.id), ["u1"])
    }

    func testPickerSelectionSurvivesATermChange() async {
        let service = FakeChannelInfoService()
        service.notInChannel = [user("u1", username: "ada", first: "Ada", last: "Lovelace")]
        service.searchResults = [user("u2", username: "grace", first: "Grace", last: "Hopper")]
        let picker = AddMembersViewModel(channelID: channelID, teamID: teamID, service: service)
        await picker.load()

        picker.toggle("u1")
        await picker.search("gra")
        picker.toggle("u2")

        XCTAssertEqual(picker.selectedIDs.sorted(), ["u1", "u2"])
        XCTAssertEqual(Set(picker.selectedProfiles.keys), ["u1", "u2"])
        XCTAssertEqual(picker.submitTitle, "Add 2 members")
    }
}

// MARK: - Test-only conveniences

private extension ChannelInfoViewModel {
    /// `offeredActions` through the view model (the screen draws `model.actions`; the tests assert the
    /// same list without reaching into `capabilities`).
    var offeredActionsForTest: [ChannelInfoActionID] { actions }
}
