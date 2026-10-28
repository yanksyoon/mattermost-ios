// T47 — the rules behind creating a channel and the sidebar's create menu, with no network and no clock.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0,
// `app/screens/create_or_edit_channel/` (create mode, `validateDisplayName`, the derived URL name),
// `app/screens/home/channel_list/` (the `+` menu), `app/client/rest/channels.ts` (`createChannel`),
// `app/screens/create_direct_message/` (the people picker).
//
// Everything here is asserted through the seams the screen actually uses:
//   * `ChannelNameRule` for the server's URL-name rule (the measurements are in
//     `CreateChannelModels.swift`'s header and re-runnable with `scripts/t47_create_channel_probe.py`);
//   * `ChannelCreateDraft` for the derived name and the `POST /channels` body;
//   * `ChannelCreatePermissions`/`ChannelCreateMenu` for the permission **ids** and the menu order;
//   * `ChannelCreateViewModel` against a fake `ChannelCreationServing` for the gate and the write;
//   * `DirectMessageDerivation` + `NewDirectMessageViewModel` for the picker.

import XCTest
import SwiftUI
@testable import Mattermost

@MainActor
final class T47CreateChannelTests: XCTestCase {

    private let teamID = "team0000000000000000000001"
    private let myUserID = "user0000000000000000000001"
    private let channelID = "chan0000000000000000000001"

    // MARK: - Fakes

    /// A `ChannelCreationServing` that answers from memory and records every write.
    @MainActor
    final class FakeCreateService: ChannelCreationServing {
        var principalValue = MMPrincipal(id: "user0000000000000000000001",
                                         username: "me",
                                         roles: "system_user")
        var teamRoles = "team_user"
        var rolesByName: [String: MMRole] = [:]
        var createFailure: Error?
        var createAnswer: (MMChannelCreate) -> MMChannel = { body in
            MMChannel(id: "chan0000000000000000000001",
                      name: body.name,
                      displayName: body.displayName,
                      type: body.type,
                      teamId: body.teamID)
        }
        var teamPeople: [MMUser] = []
        var searchResults: [MMUser] = []
        var statusesByID: [String: MMStatus] = [:]
        var directChannelAnswer = MMChannel(id: "chan-dm000000000000000001", name: "dm",
                                            displayName: "", type: "D")
        var directChannelFailure: Error?

        private(set) var bodies: [MMChannelCreate] = []
        private(set) var roleRequests: [[String]] = []
        private(set) var directCalls: [[String]] = []
        private(set) var searchTerms: [String] = []

        func grant(_ permissions: [String],
                   to roleNames: [String] = ["system_user", "team_user"]) {
            for name in roleNames {
                rolesByName[name] = MMRole(id: "role-\(name)", name: name, permissions: permissions)
            }
        }

        func createChannel(_ body: MMChannelCreate) async throws -> MMChannel {
            bodies.append(body)
            if let createFailure { throw createFailure }
            return createAnswer(body)
        }

        func teamMembers(teamID: String, page: Int, perPage: Int) async throws -> [MMUser] {
            teamPeople
        }

        func searchTeamMembers(teamID: String, term: String, page: Int, perPage: Int) async throws -> [MMUser] {
            searchTerms.append(term)
            return searchResults
        }

        func createDirectChannel(userIDs: [String]) async throws -> MMChannel {
            directCalls.append(userIDs)
            if let directChannelFailure { throw directChannelFailure }
            return directChannelAnswer
        }

        // MARK: The rest of `ChannelInfoServing` (unused by this surface)

        func channel(id: String) async throws -> MMChannel { throw MMError.notFound }
        func stats(channelID: String) async throws -> MMChannelStats { MMChannelStats(channelID: channelID) }
        func principal() async throws -> MMPrincipal { principalValue }
        func myMembership(channelID: String) async throws -> MMChannelMember { throw MMError.notFound }
        func myTeamMembership(teamID: String) async throws -> MMTeamMembership {
            MMTeamMembership(userId: principalValue.id, teamId: teamID, roles: teamRoles)
        }
        func rolePermissions(names: [String]) async throws -> [MMRole] {
            roleRequests.append(names)
            return names.compactMap { rolesByName[$0] }
        }
        func members(channelID: String, page: Int, perPage: Int) async throws -> [MMChannelMember] { [] }
        func member(channelID: String, userID: String) async throws -> MMChannelMember { throw MMError.notFound }
        func users(ids: [String]) async throws -> [MMUser] { [] }
        func statuses(ids: [String]) async throws -> [MMStatus] { ids.compactMap { statusesByID[$0] } }
        func patch(channelID: String, patch: MMChannelPatch) async throws -> MMChannel { throw MMError.notFound }
        func archive(channelID: String) async throws -> MMChannel { throw MMError.notFound }
        func restore(channelID: String) async throws -> MMChannel { throw MMError.notFound }
        func addMember(channelID: String, userID: String) async throws -> MMChannelMember { throw MMError.notFound }
        func removeMember(channelID: String, userID: String) async throws {}
        func closeDirectChannel(userID: String, channelID: String) async throws {}
        func myTeamChannels(teamID: String) async throws -> [MMChannel] { [] }
        func teamPublicChannels(teamID: String, page: Int, perPage: Int) async throws -> [MMChannel] { [] }
        func usersNotInChannel(teamID: String, channelID: String,
                               page: Int, perPage: Int) async throws -> [MMUser] { [] }
        func searchUsersNotInChannel(teamID: String, channelID: String, term: String) async throws -> [MMUser] { [] }
    }

    private func makeModel(_ service: FakeCreateService,
                           kind: ChannelInfoKind = .open) -> ChannelCreateViewModel {
        ChannelCreateViewModel(teamID: teamID, kind: kind, service: service)
    }

    // MARK: - 1. The URL-name rule (measured, not guessed)

    func testTheRuleAcceptsLowercaseDigitsHyphenAndUnderscore() {
        for name in ["general", "t47-probe", "t47_probe", "a", "1234", "off-topic-2"] {
            XCTAssertTrue(ChannelNameRule.isValid(name), "\(name) must be accepted")
        }
    }

    func testTheRuleRefusesTheShapesTheServerRefuses() {
        // Every one of these answered 400 `model.channel.is_valid.1_or_more.app_error` on 9.11.19.
        for name in ["T47-Probe", "t47 probe", "t47.probe", "-t47", "_t47", "", "café", "t47/probe"] {
            XCTAssertFalse(ChannelNameRule.isValid(name), "\(name) must be refused")
        }
    }

    func testTheRuleAcceptsATrailingHyphenBecauseTheServerDoes() {
        // Measured: the server accepts `t47probe…-` (201). Refusing it here would be a client that
        // disagrees with the server in the harmless direction — but it would also be a rule invented
        // rather than ported.
        XCTAssertTrue(ChannelNameRule.isValid("t47-trailing-"))
    }

    func testTheRuleAccepts64CharactersAndRefuses65() {
        let sixtyFour = String(repeating: "a", count: 64)
        let sixtyFive = String(repeating: "b", count: 65)
        XCTAssertTrue(ChannelNameRule.isValid(sixtyFour))
        XCTAssertNotNil(ChannelNameRule.validationMessage(for: sixtyFive),
                        "65 characters answered 500 on the server; the client must refuse it locally")
    }

    func testALeadingSeparatorIsNamedInTheMessage() {
        let message = ChannelNameRule.validationMessage(for: "-probe")
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.lowercased().contains("start"), "message was \(message!)")
    }

    // MARK: - 2. The derived URL name

    func testTheDisplayNameDerivesADashedURLName() {
        XCTAssertEqual(ChannelNameRule.makeURLName(fromDisplayName: "T47 Probe Public"), "t47-probe-public")
        XCTAssertEqual(ChannelNameRule.makeURLName(fromDisplayName: "  Padded  "), "padded")
    }

    func testDiacriticsAreFoldedIntoTheURLName() {
        XCTAssertEqual(ChannelNameRule.makeURLName(fromDisplayName: "Café Olé"), "cafe-ole")
        XCTAssertEqual(ChannelNameRule.makeURLName(fromDisplayName: "Señor Team"), "senor-team")
    }

    func testPunctuationCollapsesToASingleSeparator() {
        XCTAssertEqual(ChannelNameRule.makeURLName(fromDisplayName: "Hello,   World!!!"), "hello-world")
        XCTAssertEqual(ChannelNameRule.makeURLName(fromDisplayName: "Q&A / Support"), "q-a-support")
    }

    func testLeadingAndTrailingSeparatorsAreTrimmed() {
        XCTAssertEqual(ChannelNameRule.makeURLName(fromDisplayName: "!!! Hello"), "hello")
        XCTAssertEqual(ChannelNameRule.makeURLName(fromDisplayName: "Hello ?"), "hello")
        XCTAssertEqual(ChannelNameRule.makeURLName(fromDisplayName: "---"), "")
    }

    func testADisplayNameWithNoUsableCharactersSuggestsNothing() {
        XCTAssertEqual(ChannelNameRule.makeURLName(fromDisplayName: "日本語"), "",
                       "an empty suggestion is honest; a made-up name is not")
    }

    func testALongDisplayNameIsTruncatedTo64WithoutATrailingSeparator() {
        let long = String(repeating: "word ", count: 20)          // 100 characters
        let derived = ChannelNameRule.makeURLName(fromDisplayName: long)
        XCTAssertEqual(derived.count, 64)
        XCTAssertFalse(derived.hasSuffix("-"), "a truncation must not leave a trailing separator")
        XCTAssertTrue(ChannelNameRule.isValid(derived))
    }

    func testEveryDerivedNameIsAcceptedByTheRule() {
        // A property, not an example: whatever the reader types as a display name, the suggestion the
        // form fills in is a name the server will take (or is empty, which the form then refuses).
        let displayNames = ["T47 Probe", "  spaced  out  ", "Ünïcodé Tëam", "a", "123",
                            "What?", "This is a longer display name with punctuation: yes!",
                            String(repeating: "x", count: 200), "日本語", "---"]
        for displayName in displayNames {
            let derived = ChannelNameRule.makeURLName(fromDisplayName: displayName)
            if derived.isEmpty { continue }
            XCTAssertTrue(ChannelNameRule.isValid(derived),
                          "\(displayName.debugDescription) → \(derived.debugDescription) must be acceptable")
        }
    }

    // MARK: - 3. The draft

    func testTheURLNameFollowsTheDisplayNameUntilTheReaderEditsIt() {
        var draft = ChannelCreateDraft()
        draft.setDisplayName("T47 Probe")
        XCTAssertEqual(draft.urlName, "t47-probe")
        XCTAssertTrue(draft.isURLNameDerived)

        draft.setDisplayName("T47 Probe Public")
        XCTAssertEqual(draft.urlName, "t47-probe-public", "the suggestion keeps following the display name")

        draft.setURLName("t47-mine")
        XCTAssertEqual(draft.urlName, "t47-mine")
        XCTAssertFalse(draft.isURLNameDerived)

        draft.setDisplayName("Something Else")
        XCTAssertEqual(draft.urlName, "t47-mine",
                       "once the reader types the address, a further edit must not rewrite it")
        XCTAssertEqual(draft.suggestedURLName, "something-else")
    }

    func testValidationRefusesAnEmptyDisplayNameAndTheServersLimits() {
        let permissions = ChannelCreatePermissions(canCreatePublic: true, canCreatePrivate: true,
                                                   canBrowse: true, canCreateDirectMessage: true)

        var draft = ChannelCreateDraft()
        XCTAssertEqual(draft.validation(permissions: permissions), "A channel name is required.")

        draft.setDisplayName("T47 Probe")
        XCTAssertNil(draft.validation(permissions: permissions))

        var longPurpose = draft
        longPurpose.purpose = String(repeating: "p", count: ChannelCreateDraft.maxPurposeLength + 1)
        XCTAssertNotNil(longPurpose.validation(permissions: permissions))

        var longHeader = draft
        longHeader.header = String(repeating: "h", count: ChannelCreateDraft.maxHeaderLength + 1)
        XCTAssertNotNil(longHeader.validation(permissions: permissions))

        var longName = draft
        longName.setDisplayName(String(repeating: "d", count: ChannelCreateDraft.maxDisplayNameLength + 1))
        XCTAssertNotNil(longName.validation(permissions: permissions))
    }

    func testAMalformedURLNameIsRefusedEvenWhenTheDisplayNameIsFine() {
        let permissions = ChannelCreatePermissions(canCreatePublic: true, canCreatePrivate: false,
                                                   canBrowse: true, canCreateDirectMessage: true)
        var draft = ChannelCreateDraft()
        draft.setDisplayName("Fine name")
        draft.setURLName("Not Fine")
        XCTAssertNotNil(draft.validation(permissions: permissions))
    }

    func testTheBodyCarriesTheServersOwnFieldNamesAndTheChosenType() throws {
        let permissions = ChannelCreatePermissions(canCreatePublic: true, canCreatePrivate: true,
                                                   canBrowse: true, canCreateDirectMessage: true)
        var draft = ChannelCreateDraft(kind: .privateChannel)
        draft.setDisplayName("T47 Private")
        draft.purpose = "purpose"
        draft.header = "header"
        XCTAssertTrue(draft.canSubmit(permissions: permissions))

        let body = draft.body(teamID: teamID)
        XCTAssertEqual(body.teamID, teamID)
        XCTAssertEqual(body.name, "t47-private")
        XCTAssertEqual(body.displayName, "T47 Private")
        XCTAssertEqual(body.type, "P")
        XCTAssertEqual(body.purpose, "purpose")
        XCTAssertEqual(body.header, "header")

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        XCTAssertEqual(Set(json?.keys.map { $0 } ?? []),
                       ["team_id", "name", "display_name", "type", "purpose", "header"],
                       "the wire keys are the server's, not Swift's")
    }

    func testADirectOrGroupMessageIsNotCreatedThroughThisBody() {
        XCTAssertNil(ChannelInfoKind.direct.createType)
        XCTAssertNil(ChannelInfoKind.group.createType)
        XCTAssertEqual(ChannelInfoKind.open.createType, "O")
        XCTAssertEqual(ChannelInfoKind.privateChannel.createType, "P")
    }

    // MARK: - 4. The create menu (permission ids, never role names)

    func testTheMenuIsCreateBrowseDirectMessageInThatOrder() {
        let permissions = ChannelCreatePermissions(canCreatePublic: true, canCreatePrivate: true,
                                                   canBrowse: true, canCreateDirectMessage: true)
        XCTAssertEqual(ChannelCreateMenu.orderedActions(for: permissions),
                       [.createChannel, .browseChannels, .createDirectMessage])
    }

    func testNoPermissionsOfferAnEmptyMenu() {
        XCTAssertEqual(ChannelCreateMenu.orderedActions(for: .none), [])
    }

    func testCreateIsOfferedWithEitherCreateIdAndTheKindsFollowTheGrant() {
        let publicOnly = ChannelCreatePermissions.derive(from: [ChannelCreatePermissionID.createPublicChannel])
        XCTAssertEqual(ChannelCreateMenu.orderedActions(for: publicOnly), [.createChannel])
        XCTAssertEqual(publicOnly.creatableKinds, [.open])

        let privateOnly = ChannelCreatePermissions.derive(from: [ChannelCreatePermissionID.createPrivateChannel])
        XCTAssertEqual(ChannelCreateMenu.orderedActions(for: privateOnly), [.createChannel])
        XCTAssertEqual(privateOnly.creatableKinds, [.privateChannel])
        XCTAssertFalse(privateOnly.canCreate(.open))

        let neither = ChannelCreatePermissions.derive(from: [ChannelPermissionID.listTeamChannels,
                                                            ChannelCreatePermissionID.createDirectChannel])
        XCTAssertEqual(ChannelCreateMenu.orderedActions(for: neither),
                       [.browseChannels, .createDirectMessage])
        XCTAssertFalse(neither.canCreateAnyChannel)
    }

    func testRoleNamesGrantNothingWithoutTheirPermissionIds() {
        // The gate reads the union of **ids**. A role name that sounds like permission —
        // `channel_admin` — grants nothing on its own.
        let fromNames: Set<String> = ["system_user", "team_admin", "channel_admin"]
        XCTAssertEqual(ChannelCreatePermissions.derive(from: fromNames), .none)
    }

    // MARK: - 5. The form's model: load, gate, write

    func testTheFormLoadsTheUnionOfSystemAndTeamRoleIds() async {
        let service = FakeCreateService()
        service.grant([ChannelCreatePermissionID.createPublicChannel], to: ["system_user"])
        service.grant([ChannelCreatePermissionID.createPrivateChannel], to: ["team_user"])
        let model = makeModel(service)

        await model.load()

        XCTAssertEqual(service.roleRequests.count, 1)
        XCTAssertEqual(Set(service.roleRequests[0]), ["system_user", "team_user"],
                       "the union is system + team roles")
        XCTAssertTrue(model.permissions.canCreatePublic)
        XCTAssertTrue(model.permissions.canCreatePrivate)
        XCTAssertEqual(model.menuActions, [.createChannel])
    }

    func testTheFormOpensOnAKindTheReaderMayCreate() async {
        let service = FakeCreateService()
        service.grant([ChannelCreatePermissionID.createPrivateChannel])
        let model = makeModel(service, kind: .open)
        await model.load()
        XCTAssertEqual(model.draft.kind, .privateChannel,
                       "drawing a Public form for a reader who may only create private channels offers a refused first option")
    }

    func testACreateWithPermissionSendsTheBodyAndPublishesTheServersChannel() async {
        let service = FakeCreateService()
        service.grant([ChannelCreatePermissionID.createPublicChannel, ChannelCreatePermissionID.createPrivateChannel])
        let model = makeModel(service)
        await model.load()
        model.draft.setDisplayName("T47 Created")
        model.setKind(.privateChannel)

        let channel = await model.create()

        XCTAssertEqual(service.bodies.count, 1)
        XCTAssertEqual(service.bodies.first?.name, "t47-created")
        XCTAssertEqual(service.bodies.first?.type, "P")
        XCTAssertEqual(service.bodies.first?.teamID, teamID)
        XCTAssertEqual(channel?.id, "chan0000000000000000000001")
        XCTAssertEqual(model.createdChannel?.id, "chan0000000000000000000001")
        XCTAssertNil(model.errorMessage)
    }

    func testACreateWithoutThePermissionSendsNothing() async {
        // Two independent checks stand between an unpermitted reader and `POST /channels`:
        // `ChannelCreateViewModel.create()`'s own guard, and `draft.validation(permissions:)`, which
        // this model consults right after it. Measured: deleting *either one alone* leaves this test
        // green, because the other still refuses — so the mutation that proves this test is deleting
        // the permission clause from both (docs/t47-build-note.md §4). What the test pins down is the
        // outcome that matters: no body reaches the service and the reader is told why.
        let service = FakeCreateService()
        service.grant([ChannelPermissionID.listTeamChannels])
        let model = makeModel(service)
        await model.load()
        model.draft.setDisplayName("T47 Sneaky")

        let channel = await model.create()

        XCTAssertNil(channel)
        XCTAssertTrue(service.bodies.isEmpty, "an unpermitted create must never reach POST /channels")
        XCTAssertNotNil(model.errorMessage)
    }

    func testTheKindCannotBeSwitchedToAKindWithoutItsPermission() async {
        let service = FakeCreateService()
        service.grant([ChannelCreatePermissionID.createPublicChannel])
        let model = makeModel(service)
        await model.load()

        model.setKind(.privateChannel)

        XCTAssertEqual(model.draft.kind, .open)
        XCTAssertNotNil(model.errorMessage)
    }

    func testAValidationFailureSendsNothing() async {
        let service = FakeCreateService()
        service.grant([ChannelCreatePermissionID.createPublicChannel])
        let model = makeModel(service)
        await model.load()

        // A display name with nothing usable in it leaves the URL name empty: the server would answer
        // 400 `model.channel.is_valid.1_or_more.app_error`.
        model.draft.setDisplayName("日本語")
        XCTAssertFalse(model.canSubmit)

        let channel = await model.create()
        XCTAssertNil(channel)
        XCTAssertTrue(service.bodies.isEmpty)
    }

    func testADuplicateNameSurfacesTheServersOwnSentence() async {
        let service = FakeCreateService()
        service.grant([ChannelCreatePermissionID.createPublicChannel])
        service.createFailure = MMError.client(status: 400,
                                               message: "A channel with that name already exists on the same team.")
        let model = makeModel(service)
        await model.load()
        model.draft.setDisplayName("T47 Duplicate")

        let channel = await model.create()

        XCTAssertNil(channel)
        XCTAssertEqual(model.errorMessage,
                       "A channel with that name already exists on the same team.",
                       "the 400's message is the reader's sentence; a generic one would hide the only fixable case")
        XCTAssertEqual(service.bodies.count, 1)
    }

    func testAChannelOfTheWrongKindIsNotNavigatedTo() async {
        let service = FakeCreateService()
        service.grant([ChannelCreatePermissionID.createPublicChannel, ChannelCreatePermissionID.createPrivateChannel])
        // The server answers a public channel although a private one was asked for.
        service.createAnswer = { body in
            MMChannel(id: "chan-wrong", name: body.name, displayName: body.displayName,
                      type: "O", teamId: body.teamID)
        }
        let model = makeModel(service, kind: .privateChannel)
        await model.load()

        model.draft.setDisplayName("T47 Wrong Kind")
        let channel = await model.create()

        XCTAssertNil(channel)
        XCTAssertNil(model.createdChannel)
        XCTAssertNotNil(model.errorMessage)
    }

    // MARK: - 6. The direct-message picker

    func testThePickerListsTheTeamWithoutMe() {
        let users = [MMUser(id: myUserID, username: "me", firstName: "Me"),
                     MMUser(id: "u2", username: "alice", firstName: "Alice", lastName: "A"),
                     MMUser(id: "u3", username: "bob", nickname: "Bobby")]
        let rows = DirectMessageDerivation.rows(users: users, statuses: [:], myUserID: myUserID, term: "")
        XCTAssertEqual(rows.map(\.id), ["u2", "u3"], "alice before bobby; never my own row")
        XCTAssertEqual(rows.first?.displayName, "Alice A")
        XCTAssertEqual(rows.last?.displayName, "Bobby")
        XCTAssertEqual(rows.first?.initials, "AA")
    }

    func testThePickerTermMatchesTheDisplayNameAndTheUsername() {
        let users = [MMUser(id: "u2", username: "alice", firstName: "Alice"),
                     MMUser(id: "u3", username: "bob", firstName: "Robert")]
        XCTAssertEqual(DirectMessageDerivation.rows(users: users, statuses: [:],
                                                    myUserID: nil, term: "ali").map(\.id), ["u2"])
        XCTAssertEqual(DirectMessageDerivation.rows(users: users, statuses: [:],
                                                    myUserID: nil, term: "bob").map(\.id), ["u3"])
        XCTAssertEqual(DirectMessageDerivation.rows(users: users, statuses: [:],
                                                    myUserID: nil, term: "zzz").map(\.id), [])
    }

    func testThePickerCarriesPresenceAndSaysUnknownRatherThanOffline() {
        let users = [MMUser(id: "u2", username: "alice"), MMUser(id: "u3", username: "bob")]
        let statuses = ["u2": MMStatus(userId: "u2", status: "away")]
        let rows = DirectMessageDerivation.rows(users: users, statuses: statuses, myUserID: nil, term: "")
        XCTAssertEqual(rows.first { $0.id == "u2" }?.statusLabel, "Away")
        XCTAssertEqual(rows.first { $0.id == "u3" }?.statusLabel, "Unknown")
    }

    func testTappingARowCreatesTheConversationWithBothIdsAndPublishesIt() async {
        let service = FakeCreateService()
        service.teamPeople = [MMUser(id: myUserID, username: "me"),
                              MMUser(id: "u2", username: "alice", firstName: "Alice")]
        let model = NewDirectMessageViewModel(teamID: teamID, service: service)
        await model.load()
        XCTAssertEqual(model.rows.map(\.id), ["u2"])

        let channel = await model.open(model.rows[0])

        XCTAssertEqual(service.directCalls.count, 1)
        XCTAssertEqual(service.directCalls.first, [myUserID, "u2"])
        XCTAssertEqual(channel?.type, "D")
        XCTAssertEqual(model.openedChannel?.id, "chan-dm000000000000000001")
    }

    func testThePickerRefusesToCreateAConversationWithNoSignedInUser() async {
        let service = FakeCreateService()
        service.principalValue = MMPrincipal()      // an empty principal: no id
        service.teamPeople = [MMUser(id: "u2", username: "alice", firstName: "Alice")]
        let model = NewDirectMessageViewModel(teamID: teamID, service: service)
        await model.load()

        let channel = await model.open(DirectMessageCandidate(id: "u2", displayName: "Alice",
                                                              username: "alice", initials: "A",
                                                              status: ""))
        XCTAssertNil(channel)
        XCTAssertTrue(service.directCalls.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }
}
