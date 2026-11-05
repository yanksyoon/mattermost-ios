// t_d088f075 — the rules behind "convert a group message to a private channel", with no network.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0,
// `app/screens/convert_gm_to_channel/` (the form, the message box, the no-common-team state),
// `app/screens/channel_settings/index.ts` (`convertGMOptionAvailable`: server ≥ 9.1 && type `G` && not a
// guest), `app/actions/remote/channel.ts` (`convertGroupMessageToPrivateChannel`),
// `app/client/rest/channels.ts` (`POST /channels/{id}/convert_to_channel?team-id=`).
//
// Everything is asserted through the seams the screen actually uses:
//   * `ConvertGMToChannelGate` for the gate (the four facts upstream consults);
//   * `ConvertGMToChannelDraft` for the derived URL name and the request body — the name comes from
//     `ChannelNameRule`, the same rule `ChannelCreateDraft` uses;
//   * `ConvertGMToChannelCopy` / `ConvertGMToChannelFailure` for the copy and where a failure is drawn;
//   * `ConvertedChannelTarget` for the navigation target;
//   * `ConvertGMToChannelViewModel` against a fake `ChannelConversionServing` for the reads, the gate on
//     the write, and the answer checks.
//
// The measurements the fixtures rest on are in `ConvertGMToChannelModels.swift`'s header and are
// re-runnable with `scripts/td088_convert_gm_probe.py`.

import XCTest
import SwiftUI
@testable import Mattermost

@MainActor
final class Td088ConvertGMToChannelTests: XCTestCase {

    private let meID = "user0000000000000000000001"
    private let teamID = "team0000000000000000000001"
    private let otherTeamID = "team0000000000000000000002"
    private let gmID = "gm000000000000000000000001"

    // MARK: - Fixtures

    private func channel(type: String = "G", deleteAt: Int64 = 0, name: String = "gmname") -> MMChannel {
        MMChannel(id: gmID, name: name, displayName: "", type: type, teamId: "", deleteAt: deleteAt)
    }

    private func team(_ id: String, name: String) -> MMTeam {
        MMTeam(id: id, name: name, displayName: name.capitalized)
    }

    private func user(_ id: String, first: String, last: String = "") -> MMUser {
        MMUser(id: id, username: id, firstName: first, lastName: last)
    }

    /// A `ChannelConversionServing` that answers from memory and records every write.
    @MainActor
    final class FakeConversionService: ChannelConversionServing {
        var channelValue = MMChannel(id: "gm000000000000000000000001", name: "gm", type: "G")
        var commonTeamValues: [MMTeam] = []
        var commonTeamsFailure: Error?
        var memberValues: [MMChannelMember] = []
        var userValues: [MMUser] = []
        var principalValue = MMPrincipal(id: "user0000000000000000000001", username: "me", roles: "system_user")
        var versionValue: String? = "9.11.19"
        var convertFailure: Error?
        /// What the server answers. Defaults to the measured shape: same id, `P`, the target team.
        var convertAnswer: (String, String, String, String) -> MMChannel = { channelID, teamID, displayName, name in
            MMChannel(id: channelID, name: name, displayName: displayName, type: "P", teamId: teamID)
        }

        struct Conversion: Equatable {
            var channelID: String
            var teamID: String
            var displayName: String
            var name: String
        }

        private(set) var conversions: [Conversion] = []
        private(set) var commonTeamReads = 0

        func channel(id: String) async throws -> MMChannel { channelValue }
        func stats(channelID: String) async throws -> MMChannelStats { MMChannelStats(channelID: channelID) }
        func principal() async throws -> MMPrincipal { principalValue }
        func myMembership(channelID: String) async throws -> MMChannelMember { throw MMError.notFound }
        func myTeamMembership(teamID: String) async throws -> MMTeamMembership {
            MMTeamMembership(userId: principalValue.id, teamId: teamID, roles: "team_user")
        }
        func teamMembership(teamID: String, userID: String) async throws -> MMTeamMembership {
            throw MMError.notFound
        }
        func rolePermissions(names: [String]) async throws -> [MMRole] { [] }
        func members(channelID: String, page: Int, perPage: Int) async throws -> [MMChannelMember] {
            memberValues
        }
        func member(channelID: String, userID: String) async throws -> MMChannelMember { throw MMError.notFound }
        func users(ids: [String]) async throws -> [MMUser] { userValues.filter { ids.contains($0.id) } }
        func statuses(ids: [String]) async throws -> [MMStatus] { [] }
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

        func commonTeams(channelID: String) async throws -> [MMTeam] {
            commonTeamReads += 1
            if let commonTeamsFailure { throw commonTeamsFailure }
            return commonTeamValues
        }

        func serverVersionID() async -> String? { versionValue }

        func convertGroupMessage(channelID: String, teamID: String,
                                 displayName: String, name: String) async throws -> MMChannel {
            conversions.append(Conversion(channelID: channelID, teamID: teamID,
                                          displayName: displayName, name: name))
            if let convertFailure { throw convertFailure }
            return convertAnswer(channelID, teamID, displayName, name)
        }
    }

    private func makeModel(_ service: FakeConversionService,
                           type: String = "G",
                           isGuest: Bool = false,
                           version: String? = "9.11.19") -> ConvertGMToChannelViewModel {
        ConvertGMToChannelViewModel(channel: channel(type: type),
                                    isGuest: isGuest,
                                    serverVersion: version,
                                    service: service)
    }

    // MARK: - 1. The gate (upstream `convertGMOptionAvailable`)

    func testAGroupMessageOnAModernServerIsOfferedToAMember() {
        XCTAssertTrue(ConvertGMToChannelGate.isAvailable(kind: .group, isGuest: false,
                                                         isArchived: false, serverVersion: "9.11.19"))
    }

    func testOnlyAGroupMessageMayBeConverted() {
        for kind in [ChannelInfoKind.open, .privateChannel, .direct] {
            XCTAssertFalse(ConvertGMToChannelGate.isAvailable(kind: kind, isGuest: false,
                                                              isArchived: false, serverVersion: "9.11.19"),
                           "\(kind) is not a group message; the server refuses it with "
                               + "app.channel.get_common_teams.incorrect_channel_type")
        }
    }

    func testAGuestIsNotOfferedTheConversion() {
        XCTAssertFalse(ConvertGMToChannelGate.isAvailable(kind: .group, isGuest: true,
                                                          isArchived: false, serverVersion: "9.11.19"))
    }

    func testAnArchivedGroupMessageIsNotOffered() {
        XCTAssertFalse(ConvertGMToChannelGate.isAvailable(kind: .group, isGuest: false,
                                                          isArchived: true, serverVersion: "9.11.19"))
    }

    func testTheFeatureFloorIsServerNineOne() {
        XCTAssertFalse(ConvertGMToChannelGate.isAvailable(kind: .group, isGuest: false,
                                                          isArchived: false, serverVersion: "9.0.9"))
        XCTAssertTrue(ConvertGMToChannelGate.isAvailable(kind: .group, isGuest: false,
                                                         isArchived: false, serverVersion: "9.1.0"))
        XCTAssertTrue(ConvertGMToChannelGate.isAvailable(kind: .group, isGuest: false,
                                                         isArchived: false, serverVersion: "10.0.0"))
    }

    func testAnUnreadableVersionDoesNotHideTheAction() {
        // A proxy may strip `X-Version-Id`. The floor is availability, not security: the write is still
        // the server's to refuse, and hiding a working action is the worse error.
        for version in ["", "not-a-version", "9"] {
            XCTAssertTrue(ConvertGMToChannelGate.isAvailable(kind: .group, isGuest: false,
                                                             isArchived: false, serverVersion: version),
                          "a version of \(version.debugDescription) must not close the row")
        }
    }

    func testTheVersionParsesTheServersOwnHeader() {
        // Measured on 9.11.19: `X-Version-Id: 9.11.19.16643067630.729911b46…false`.
        XCTAssertEqual(ServerVersionNumber("9.11.19.16643067630.729911b468d3b08e14e08ba4871cbc68.false"),
                       ServerVersionNumber("9.11.19"))
        XCTAssertEqual(ServerVersionNumber("9.1"), ServerVersionNumber("9.1.0"))
        XCTAssertEqual(ServerVersionNumber("v10.2.3"), ServerVersionNumber("10.2.3"))
        XCTAssertNil(ServerVersionNumber("nightly"))
        XCTAssertNil(ServerVersionNumber(""))
    }

    func testTheInfoScreensGateAndTheConversionScreensGateAgree() {
        let capabilities = ChannelInfoCapabilities.derive(channel: channel(type: "G"),
                                                          permissions: [],
                                                          isGuest: false,
                                                          serverVersion: "9.11.19")
        XCTAssertTrue(capabilities.canConvertGroupMessage)
        XCTAssertEqual(ConvertGMToChannelGate.isAvailable(kind: capabilities.kind,
                                                          isGuest: false,
                                                          isArchived: capabilities.isArchived,
                                                          serverVersion: "9.11.19"),
                       capabilities.canConvertGroupMessage)

        let open = ChannelInfoCapabilities.derive(channel: channel(type: "O"),
                                                  permissions: [],
                                                  isGuest: false,
                                                  serverVersion: "9.11.19")
        XCTAssertFalse(open.canConvertGroupMessage)
        XCTAssertFalse(open.offeredActions.contains(.convertToChannel))

        let guest = ChannelInfoCapabilities.derive(channel: channel(type: "G"),
                                                   permissions: [],
                                                   isGuest: true,
                                                   serverVersion: "9.11.19")
        XCTAssertFalse(guest.canConvertGroupMessage)
    }

    func testTheRowSitsBetweenTheSettingsRowAndArchive() {
        // A public channel cannot convert, so the sequence is asserted on a GM whose permissions give it
        // nothing else: convert is the row after the member list, notifications and pinned.
        let capabilities = ChannelInfoCapabilities.derive(channel: channel(type: "G"),
                                                          permissions: [],
                                                          isGuest: false,
                                                          serverVersion: "9.11.19")
        let actions = capabilities.offeredActions
        XCTAssertEqual(actions.last, .leave)
        let convertIndex = try? XCTUnwrap(actions.firstIndex(of: .convertToChannel))
        let pinnedIndex = try? XCTUnwrap(actions.firstIndex(of: .pinned))
        XCTAssertNotNil(convertIndex)
        XCTAssertNotNil(pinnedIndex)
        if let convertIndex, let pinnedIndex {
            XCTAssertGreaterThan(convertIndex, pinnedIndex,
                                 "the conversion is drawn with the destructive options, not the reads")
        }
    }

    // MARK: - 2. The draft and the body

    func testTheURLNameFollowsTheDisplayNameByTheCreateRules() {
        var draft = ConvertGMToChannelDraft()
        draft.setDisplayName("Design Team")
        XCTAssertEqual(draft.urlName, "design-team")
        XCTAssertEqual(draft.urlName, ChannelNameRule.makeURLName(fromDisplayName: "Design Team"),
                       "the conversion must use the create form's rule, not a second one")

        draft.setDisplayName("Café Ops")
        XCTAssertEqual(draft.urlName, "cafe-ops")

        // A display name with nothing usable leaves the address empty — the reader types it.
        draft.setDisplayName("日本語")
        XCTAssertEqual(draft.urlName, "")
        XCTAssertNotNil(draft.validation(teams: [team(teamID, name: "perf")]),
                        "an empty URL name is refused locally, because the server answers 400/500")
    }

    func testAClaimedURLNameIsNotRewritten() {
        var draft = ConvertGMToChannelDraft()
        draft.setDisplayName("Design Team")
        draft.setURLName("design")
        draft.setDisplayName("Design Team Two")
        XCTAssertEqual(draft.urlName, "design", "a claimed address belongs to the reader")
    }

    func testTheBodyCarriesTheMeasuredKeysAndTheTrimmedName() {
        var draft = ConvertGMToChannelDraft()
        draft.setDisplayName("  Design Team  ")
        draft.teamID = teamID
        let body = draft.body(channelID: gmID)

        XCTAssertEqual(body.channelID, gmID)
        XCTAssertEqual(body.teamID, teamID)
        XCTAssertEqual(body.displayName, "Design Team")
        XCTAssertEqual(body.name, "design-team")

        let object = (try? JSONEncoder().encode(body)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let keys = object.map { Set($0.keys) } ?? []
        XCTAssertEqual(keys,
                       Set(["channel_id", "team_id", "display_name", "name"]),
                       "the server reads these four keys (measured)")
    }

    func testTheDraftRefusesWhatTheServerRefuses() {
        let teams = [team(teamID, name: "perf")]

        var empty = ConvertGMToChannelDraft()
        empty.teamID = teamID
        XCTAssertEqual(empty.validation(teams: teams), "A channel name is required.")

        var noTeam = ConvertGMToChannelDraft()
        noTeam.setDisplayName("Design Team")
        XCTAssertEqual(noTeam.validation(teams: teams), "Choose a team for the new channel.")

        var wrongTeam = ConvertGMToChannelDraft()
        wrongTeam.setDisplayName("Design Team")
        wrongTeam.teamID = otherTeamID
        XCTAssertEqual(wrongTeam.validation(teams: teams),
                       "Choose a team the group's members all belong to.")

        var tooLong = ConvertGMToChannelDraft()
        tooLong.setDisplayName(String(repeating: "a", count: 65))
        tooLong.teamID = teamID
        XCTAssertEqual(tooLong.validation(teams: teams),
                       "The name must be 64 characters or fewer.",
                       "65 characters is a 500 on the server, so it is refused locally")

        var underscore = ConvertGMToChannelDraft()
        underscore.setDisplayName("design_team-2")
        underscore.teamID = teamID
        XCTAssertNil(underscore.validation(teams: teams), "an underscore in the middle is accepted (measured)")
        XCTAssertTrue(underscore.canSubmit(teams: teams))
    }

    // MARK: - 3. Copy

    func testTheWarningListsTheOtherMembersTheWayUpstreamFormatsAList() {
        XCTAssertEqual(ConvertGMToChannelCopy.list([]), "yourself")
        XCTAssertEqual(ConvertGMToChannelCopy.list(["Alice"]), "Alice")
        XCTAssertEqual(ConvertGMToChannelCopy.list(["Alice", "Bob"]), "Alice and Bob")
        XCTAssertEqual(ConvertGMToChannelCopy.list(["Alice", "Bob", "Carol"]),
                       "Alice, Bob and Carol")
        XCTAssertTrue(ConvertGMToChannelCopy.warningBody(memberNames: ["Alice", "Bob"])
            .contains("the Group Message with Alice and Bob to a Channel"))
        XCTAssertTrue(ConvertGMToChannelCopy.warningBody(memberNames: [])
            .contains("with yourself"))
    }

    func testAFailureIsDrawnUnderTheControlItBelongsTo() {
        let duplicate = ConvertGMToChannelFailure.classify(
            MMError.client(status: 400,
                           message: "A channel with that name already exists on the same team."))
        XCTAssertEqual(duplicate.field, .name)
        XCTAssertEqual(duplicate.message, "A channel with that name already exists on the same team.")

        let wrongTeam = ConvertGMToChannelFailure.classify(
            MMError.client(status: 400,
                           message: "The specified team ID in conversion request does not contain all the group message members"))
        XCTAssertEqual(wrongTeam.field, .team)

        let notAGroup = ConvertGMToChannelFailure.classify(
            MMError.client(status: 400, message: "Channel is not a group message."))
        XCTAssertEqual(notAGroup.field, .banner)
        XCTAssertEqual(notAGroup.message, ConvertGMToChannelCopy.refused)

        let offline = ConvertGMToChannelFailure.classify(MMError.offline)
        XCTAssertEqual(offline.field, .banner)
        XCTAssertTrue(offline.message.lowercased().contains("offline"))
    }

    // MARK: - 4. The navigation target

    func testTheConvertedChannelIsTheSameConversationInTheNewTeam() {
        let answer = MMChannel(id: gmID, name: "design-team", displayName: "Design Team",
                               type: "P", teamId: teamID)
        let target = ConvertedChannelTarget(channel: answer, requestedTeamID: otherTeamID)
        XCTAssertEqual(target?.channelID, gmID, "the id survives the conversion (measured)")
        XCTAssertEqual(target?.channelName, "design-team")
        XCTAssertEqual(target?.teamID, teamID, "the server's team wins over the requested one")

        let notAPrivateChannel = MMChannel(id: gmID, name: "gm", type: "G", teamId: teamID)
        XCTAssertNil(ConvertedChannelTarget(channel: notAPrivateChannel, requestedTeamID: teamID),
                     "navigating into a conversation the server did not convert would be a lie")
    }

    // MARK: - 5. The view model

    func testLoadReadsTheCommonTeamsAndPreselectsTheFirst() async {
        let service = FakeConversionService()
        service.commonTeamValues = [team(teamID, name: "perf"), team(otherTeamID, name: "ops")]
        service.memberValues = [MMChannelMember(channelId: gmID, userId: meID),
                                MMChannelMember(channelId: gmID, userId: "user2"),
                                MMChannelMember(channelId: gmID, userId: "user3")]
        service.userValues = [user("user2", first: "Alice"), user("user3", first: "Bob", last: "Jones")]

        let model = makeModel(service)
        await model.load()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.teams.count, 2)
        XCTAssertEqual(model.draft.teamID, teamID, "upstream preselects commonTeams[0]")
        XCTAssertTrue(model.showsTeamPicker, "two teams are a choice, so the row is drawn")
        XCTAssertEqual(model.memberNames, ["Alice", "Bob Jones"], "the reader is not named in the warning")
        XCTAssertTrue(model.warningBody.contains("Alice and Bob Jones"))
    }

    func testNoCommonTeamShowsTheStateInsteadOfAForm() async {
        let service = FakeConversionService()
        service.commonTeamValues = []

        let model = makeModel(service)
        await model.load()

        XCTAssertEqual(model.phase, .noCommonTeams)
        XCTAssertFalse(model.canSubmit)
        XCTAssertNil(model.draft.teamID)
    }

    func testLoadFailureKeepsARetry() async {
        let service = FakeConversionService()
        service.commonTeamsFailure = MMError.offline

        let model = makeModel(service)
        await model.load()

        guard case .failed(let message) = model.phase else {
            return XCTFail("an unreadable team list must be a failure, not an empty 'no common team'")
        }
        XCTAssertTrue(message.lowercased().contains("offline"))
        XCTAssertFalse(model.canSubmit)
    }

    func testConvertSendsTheFrozenBodyAndAnswersTheTarget() async {
        let service = FakeConversionService()
        service.commonTeamValues = [team(teamID, name: "perf")]
        let model = makeModel(service)
        await model.load()
        model.draft.setDisplayName("Design Team")
        XCTAssertTrue(model.canSubmit)

        let converted = await model.convert()

        XCTAssertEqual(service.conversions,
                       [.init(channelID: gmID, teamID: teamID,
                              displayName: "Design Team", name: "design-team")])
        XCTAssertEqual(converted?.id, gmID)
        XCTAssertEqual(converted?.type, "P")
        XCTAssertEqual(model.target, ConvertedChannelTarget(channel: converted!,
                                                            requestedTeamID: teamID))
    }

    func testConvertRefusesWhenTheGateIsClosed() async {
        // A direct message: the row is not drawn, and a caller that reaches `convert()` anyway sends
        // nothing — hiding a row is a UI state, refusing the write is the guarantee.
        let service = FakeConversionService()
        service.commonTeamValues = [team(teamID, name: "perf")]
        let model = makeModel(service, type: "D")
        await model.load()
        model.draft.setDisplayName("Design Team")

        let converted = await model.convert()

        XCTAssertNil(converted)
        XCTAssertTrue(service.conversions.isEmpty, "no request may leave the device")
        XCTAssertEqual(model.errorMessage, ConvertGMToChannelCopy.refused)
    }

    func testAGuestCannotConvertEither() async {
        let service = FakeConversionService()
        service.commonTeamValues = [team(teamID, name: "perf")]
        let model = makeModel(service, isGuest: true)
        await model.load()
        model.draft.setDisplayName("Design Team")

        XCTAssertFalse(model.canSubmit)
        let converted = await model.convert()
        XCTAssertNil(converted)
        XCTAssertTrue(service.conversions.isEmpty)
    }

    func testADuplicateNameIsDrawnUnderTheNameField() async {
        let service = FakeConversionService()
        service.commonTeamValues = [team(teamID, name: "perf")]
        service.convertFailure = MMError.client(
            status: 400,
            message: "A channel with that name already exists on the same team.")
        let model = makeModel(service)
        await model.load()
        model.draft.setDisplayName("Design Team")

        let converted = await model.convert()

        XCTAssertNil(converted)
        XCTAssertNil(model.target)
        XCTAssertEqual(model.nameErrorMessage,
                       "A channel with that name already exists on the same team.")
        XCTAssertNil(model.errorMessage, "the sentence belongs under the field, not in the banner")
        XCTAssertEqual(service.conversions.count, 1, "the write was attempted exactly once")
    }

    func testAnAnswerThatIsNotAPrivateChannelIsReportedNotNavigated() async {
        let service = FakeConversionService()
        service.commonTeamValues = [team(teamID, name: "perf")]
        service.convertAnswer = { channelID, teamID, displayName, name in
            MMChannel(id: channelID, name: name, displayName: displayName, type: "G", teamId: teamID)
        }
        let model = makeModel(service)
        await model.load()
        model.draft.setDisplayName("Design Team")

        let converted = await model.convert()

        XCTAssertNil(converted)
        XCTAssertNil(model.target)
        XCTAssertEqual(model.errorMessage, "The server answered a channel this app did not ask for.")
    }

    func testTheSubmitButtonNeedsAName() async {
        let service = FakeConversionService()
        service.commonTeamValues = [team(teamID, name: "perf")]
        let model = makeModel(service)
        await model.load()

        XCTAssertFalse(model.canSubmit, "an empty name is not sendable")
        model.draft.setDisplayName("Design Team")
        XCTAssertTrue(model.canSubmit)
        model.draft.setDisplayName("   ")
        XCTAssertFalse(model.canSubmit)
    }

    func testTheNameFieldIsQuietUntilSomethingIsTyped() async {
        let service = FakeConversionService()
        service.commonTeamValues = [team(teamID, name: "perf")]
        let model = makeModel(service)
        await model.load()

        XCTAssertNotNil(model.validationMessage, "the draft itself is unsendable while empty")
        XCTAssertNil(model.visibleValidationMessage,
                     "an untouched field draws no red note — the disabled button is the signal")
        model.draft.setDisplayName("Design Team")
        XCTAssertNil(model.visibleValidationMessage)
        model.draft.setDisplayName("x")
        XCTAssertNil(model.visibleValidationMessage, "one character is a legal name")
        model.draft.setDisplayName(String(repeating: "a", count: 65))
        XCTAssertEqual(model.visibleValidationMessage, model.validationMessage,
                       "anything typed is judged")
    }

    func testATeamTheServerWouldRefuseIsNotSelectable() async {
        let service = FakeConversionService()
        service.commonTeamValues = [team(teamID, name: "perf")]
        let model = makeModel(service)
        await model.load()

        model.selectTeam(team(otherTeamID, name: "ops"))
        XCTAssertEqual(model.draft.teamID, teamID, "a team outside the common list is not a target")
    }
}
