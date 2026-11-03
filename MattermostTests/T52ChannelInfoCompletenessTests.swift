// T52 — the rules behind the channel-info rows this card adds (notification preferences, the channel's
// files, the shared-teams row), with no network and no clock.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 — `app/screens/channel_notification_
// preferences/` (levels, mute, ignore-mentions), `app/screens/channel_files/` (the paged list), and
// the `updateChannelNotifyProps` / `searchFiles` calls in `app/actions/remote/`. Apache-2.0, read for
// behaviour and reimplemented here; no upstream source copied.
//
// The two acceptance criteria these tests carry:
//   * "pure derivations for the preference levels … with unit tests; unreadable/unknown notification
//     levels fail to the server's current value, never a guess" — `ChannelNotifyDraft` is asserted
//     both ways: a value this build does not know is never coerced, never echoed back, and never
//     turned into a default; a failed membership read offers no draft at all.
//   * "every write is proven on the wire" — the view-model tests assert the **fields sent** and the
//     **read-back** the draft is replaced with, so a save that sent nothing (T40-AV F1) fails here too.
//
// The measured server facts (docs/t52-build-note.md §2, `scripts/t52_channel_probe.py`) are what the
// fixtures below are copied from: `notify_props` of a membership; the `file_infos` **map** and
// `next_file_info_id` cursor of `POST /teams/{tid}/files/search`; `common_teams` answering only for a
// group message.

import XCTest
@testable import Mattermost

@MainActor
final class T52ChannelInfoCompletenessTests: XCTestCase {

    private let channelID = "chan0000000000000000000001"
    private let teamID = "team0000000000000000000001"
    private let myUserID = "user0000000000000000000001"

    // MARK: - Fake

    @MainActor
    final class FakeT52Service: ChannelInfoServing {

        var channel = MMChannel(id: "chan0000000000000000000001",
                                name: "t52-channel",
                                displayName: "T52 channel",
                                type: "O",
                                teamId: "team0000000000000000000001")
        var statsValue = MMChannelStats(channelID: "chan0000000000000000000001", memberCount: 2)
        var principalValue = MMPrincipal(id: "user0000000000000000000001",
                                         username: "me",
                                         roles: "system_user")
        var membership: MMChannelMember? = MMChannelMember(
            channelId: "chan0000000000000000000001",
            userId: "user0000000000000000000001",
            roles: "channel_user",
            notifyProps: FakeT52Service.notifyProps)
        /// What `GET …/members/{uid}` answers **after** a write (the server's own read-back).
        var memberAfterWrite: MMChannelMember?
        var memberReadFailure: Error?
        var notifyWriteFailure: Error?
        var filePages: [ChannelFileSearchResult] = []
        var fileFailure: Error?
        var commonTeamsValue: [MMTeam] = []
        var commonTeamsFailure: Error?

        private(set) var notifyWrites: [[String: String]] = []
        private(set) var notifyWriteUsers: [String] = []
        private(set) var memberReads = 0
        private(set) var fileRequests: [(teamID: String, channelName: String, page: Int)] = []
        private(set) var commonTeamsRequests = 0

        static let notifyProps: JSONValue = .object([
            "desktop": .string("default"),
            "mark_unread": .string("all"),
            "ignore_channel_mentions": .string("default"),
            "email": .string("default"),
        ])

        func channel(id: String) async throws -> MMChannel { channel }
        func stats(channelID: String) async throws -> MMChannelStats { statsValue }
        func principal() async throws -> MMPrincipal { principalValue }
        func myMembership(channelID: String) async throws -> MMChannelMember {
            guard let membership else { throw MMError.notFound }
            return membership
        }
        func myTeamMembership(teamID: String) async throws -> MMTeamMembership {
            MMTeamMembership(userId: principalValue.id, teamId: teamID, roles: "team_user")
        }
        func teamMembership(teamID: String, userID: String) async throws -> MMTeamMembership {
            MMTeamMembership(userId: userID, teamId: teamID, roles: "team_user")
        }
        func rolePermissions(names: [String]) async throws -> [MMRole] { [] }
        func members(channelID: String, page: Int, perPage: Int) async throws -> [MMChannelMember] { [] }
        func member(channelID: String, userID: String) async throws -> MMChannelMember {
            memberReads += 1
            if let memberReadFailure { throw memberReadFailure }
            if let memberAfterWrite { return memberAfterWrite }
            guard let membership else { throw MMError.notFound }
            return membership
        }
        func users(ids: [String]) async throws -> [MMUser] { [] }
        func statuses(ids: [String]) async throws -> [MMStatus] { [] }
        func patch(channelID: String, patch: MMChannelPatch) async throws -> MMChannel { channel }
        func archive(channelID: String) async throws -> MMChannel { channel }
        func restore(channelID: String) async throws -> MMChannel { channel }
        func addMember(channelID: String, userID: String) async throws -> MMChannelMember {
            MMChannelMember(channelId: channelID, userId: userID)
        }
        func removeMember(channelID: String, userID: String) async throws {}
        func closeDirectChannel(userID: String, channelID: String) async throws {}
        func myTeamChannels(teamID: String) async throws -> [MMChannel] { [] }
        func myChannelMemberships() async throws -> [MMChannelMember] { [] }
        func teamPublicChannels(teamID: String, page: Int, perPage: Int) async throws -> [MMChannel] { [] }
        func archivedTeamChannels(teamID: String, page: Int, perPage: Int) async throws -> [MMChannel] { [] }
        func usersNotInChannel(teamID: String, channelID: String,
                               page: Int, perPage: Int) async throws -> [MMUser] { [] }
        func searchUsersNotInChannel(teamID: String, channelID: String,
                                     term: String) async throws -> [MMUser] { [] }

        func setNotifyProps(channelID: String, userID: String, fields: [String: String]) async throws {
            notifyWriteUsers.append(userID)
            notifyWrites.append(fields)
            if let notifyWriteFailure { throw notifyWriteFailure }
        }

        func channelFiles(teamID: String, channelName: String,
                          page: Int, perPage: Int) async throws -> ChannelFileSearchResult {
            fileRequests.append((teamID: teamID, channelName: channelName, page: page))
            if let fileFailure { throw fileFailure }
            return page < filePages.count ? filePages[page] : ChannelFileSearchResult()
        }

        func commonTeams(channelID: String) async throws -> [MMTeam] {
            commonTeamsRequests += 1
            if let commonTeamsFailure { throw commonTeamsFailure }
            return commonTeamsValue
        }
    }

    private func makeModel(_ service: FakeT52Service,
                           type: String = "O",
                           name: String = "t52-channel") -> ChannelInfoViewModel {
        service.channel.type = type
        service.channel.name = name
        return ChannelInfoViewModel(channelID: service.channel.id,
                                    teamID: teamID,
                                    fallbackTitle: nil,
                                    service: service)
    }

    // MARK: - Notification levels

    func testLevelVocabularyIsTheServersOwnStrings() {
        XCTAssertEqual(ChannelNotifyDesktopLevel.allCases.map(\.rawValue),
                       ["default", "all", "mention", "none"])
        XCTAssertEqual(ChannelNotifyMarkUnread.allCases.map(\.rawValue), ["all", "mention"])
        XCTAssertEqual(ChannelNotifyIgnoreMentions.allCases.map(\.rawValue),
                       ["default", "on", "off"])
    }

    func testDraftReadsTheServersValuesVerbatim() {
        let member = MMChannelMember(channelId: channelID,
                                     userId: myUserID,
                                     notifyProps: .object([
                                        "desktop": .string("mention"),
                                        "mark_unread": .string("mention"),
                                        "ignore_channel_mentions": .string("on"),
                                        "push": .string("all"),
                                     ]))
        let draft = ChannelNotifyDraft(member: member)
        XCTAssertEqual(draft.desktop, "mention")
        XCTAssertEqual(draft.desktopLevel, .mention)
        XCTAssertTrue(draft.isMuted)
        XCTAssertTrue(draft.ignoresChannelMentions)
        XCTAssertEqual(draft.ignoreMentionsLevel, .on)
        XCTAssertTrue(draft.unrecognisedValues.isEmpty)
    }

    /// The card's "unreadable/unknown notification levels fail to the server's current value": a level
    /// this build has never heard of is carried **verbatim**, typed accessors answer `nil`, and the row
    /// quotes the server rather than claiming "Account default".
    func testAnUnknownLevelIsNeverCoercedToADefault() {
        let draft = ChannelNotifyDraft(values: ["desktop": "nonsense",
                                                "mark_unread": "whenever",
                                                "ignore_channel_mentions": "sometimes"])
        XCTAssertNil(draft.desktopLevel)
        XCTAssertNil(draft.markUnreadLevel)
        XCTAssertNil(draft.ignoreMentionsLevel)
        XCTAssertEqual(draft.desktop, "nonsense")
        XCTAssertEqual(draft.unrecognisedValues.map(\.field), ["Notifications", "Mute channel",
                                                              "Ignore @mentions"])
        XCTAssertEqual(ChannelNotifyRowSummary.subtitle(for: draft), "Server setting: nonsense")
    }

    func testAMutedChannelSaysSoFirstInTheRowSummary() {
        let muted = ChannelNotifyDraft(values: ["desktop": "all", "mark_unread": "mention"])
        XCTAssertEqual(ChannelNotifyRowSummary.subtitle(for: muted), "Muted")
        let level = ChannelNotifyDraft(values: ["desktop": "none", "mark_unread": "all"])
        XCTAssertEqual(ChannelNotifyRowSummary.subtitle(for: level), "Never")
        let accountDefault = ChannelNotifyDraft(values: ["desktop": "default", "mark_unread": "all"])
        XCTAssertEqual(ChannelNotifyRowSummary.subtitle(for: accountDefault), "Account default")
        XCTAssertEqual(ChannelNotifyRowSummary.subtitle(for: nil), "")
    }

    /// A save carries exactly the fields the reader changed — nothing else is rewritten.
    func testChangedFieldsCarryOnlyWhatTheReaderChanged() {
        let server = ChannelNotifyDraft(values: ["desktop": "default", "mark_unread": "all",
                                                 "ignore_channel_mentions": "default"])
        let edited = server.setting(desktop: .mention)
        XCTAssertEqual(edited.changedFields(comparedTo: server), ["desktop": "mention"])
        XCTAssertTrue(server.changedFields(comparedTo: server).isEmpty)
        let muted = server.setting(markUnread: .mention)
        XCTAssertEqual(muted.changedFields(comparedTo: server), ["mark_unread": "mention"])
        let ignoring = server.setting(ignoreMentions: .on)
        XCTAssertEqual(ignoring.changedFields(comparedTo: server), ["ignore_channel_mentions": "on"])
    }

    /// The unknown-value rule on the **write** side: a value this build does not understand is not
    /// echoed back, even though the server would accept it (measured: `desktop: "nonsense"` → 200).
    func testAnUnknownServerValueIsNeverSentBackWhenAnotherFieldChanged() {
        let server = ChannelNotifyDraft(values: ["desktop": "nonsense", "mark_unread": "all"])
        let edited = server.setting(markUnread: .mention)
        XCTAssertEqual(edited.changedFields(comparedTo: server), ["mark_unread": "mention"])
        // ... and a draft that is still the unknown value (the reader changed nothing) sends nothing.
        XCTAssertTrue(server.changedFields(comparedTo: server).isEmpty)
    }

    func testUnreadablePreferencesProduceNoDraft() {
        let empty = ChannelNotifyDraft(member: MMChannelMember(channelId: channelID, userId: myUserID))
        XCTAssertFalse(empty.isReadable)
        XCTAssertEqual(ChannelNotifyRowSummary.subtitle(for: empty), "")
    }

    // MARK: - View model: notification preferences

    func testTheInfoLoadCarriesTheServersNotifyProps() async {
        let service = FakeT52Service()
        let model = makeModel(service)
        await model.load()
        XCTAssertTrue(model.notifyPropsAvailable)
        XCTAssertTrue(model.notificationsReadable)
        XCTAssertEqual(model.notifyDraft?.desktop, "default")
        XCTAssertEqual(model.notifyDraft?.markUnread, "all")
    }

    func testSavingNotificationPreferencesSendsOnlyChangedFieldsAndReadsTheServerBack() async {
        let service = FakeT52Service()
        let model = makeModel(service)
        await model.load()
        // The server's read-back differs from the optimistic guess in a second field: the model must
        // follow the read-back, not the draft it sent.
        service.memberAfterWrite = MMChannelMember(
            channelId: channelID,
            userId: myUserID,
            roles: "channel_user",
            notifyProps: .object(["desktop": .string("mention"),
                                  "mark_unread": .string("mention"),
                                  "ignore_channel_mentions": .string("default")]))
        let draft = (model.notifyDraft ?? ChannelNotifyDraft())
            .setting(desktop: .mention)
            .setting(ignoreMentions: .on)

        let succeeded = await model.saveNotifyProps(draft)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(service.notifyWrites.count, 1)
        XCTAssertEqual(service.notifyWriteUsers, [myUserID])
        XCTAssertEqual(service.notifyWrites.first,
                       ["desktop": "mention", "ignore_channel_mentions": "on"],
                       "only the fields the reader changed travel")
        XCTAssertGreaterThanOrEqual(service.memberReads, 1, "the write is proven by a read")
        XCTAssertEqual(model.notifyDraft?.markUnread, "mention",
                       "the draft follows the server's answer, not the request")
    }

    func testASaveWithNothingChangedSendsNoRequest() async {
        let service = FakeT52Service()
        let model = makeModel(service)
        await model.load()
        let succeeded = await model.saveNotifyProps(model.notifyDraft ?? ChannelNotifyDraft())
        XCTAssertTrue(succeeded)
        XCTAssertTrue(service.notifyWrites.isEmpty)
    }

    func testSaveRefusesWhenThePreferencesCouldNotBeRead() async {
        let service = FakeT52Service()
        service.membership = nil                      // the membership read failed
        let model = makeModel(service)
        await model.load()
        XCTAssertFalse(model.notifyPropsAvailable)
        XCTAssertFalse(model.notificationsReadable)

        let succeeded = await model.saveNotifyProps(ChannelNotifyDraft(values: ["desktop": "all"]))

        XCTAssertFalse(succeeded)
        XCTAssertTrue(service.notifyWrites.isEmpty, "a guess must never become a write")
        XCTAssertEqual(model.refusedMessage,
                       "Your notification preferences could not be read.")
    }

    func testAFailedWriteLeavesTheDraftAtTheServersValues() async {
        let service = FakeT52Service()
        let model = makeModel(service)
        await model.load()
        service.notifyWriteFailure = MMError.forbidden(message: nil)

        let succeeded = await model.saveNotifyProps((model.notifyDraft ?? ChannelNotifyDraft())
            .setting(desktop: .none))

        XCTAssertFalse(succeeded)
        XCTAssertEqual(model.notifyDraft?.desktop, "default",
                       "a failed write must not claim the new level")
        XCTAssertEqual(model.banner, "You do not have permission to do that.")
    }

    // MARK: - Shared teams

    func testCommonTeamsIsAskedOnlyForAGroupMessage() async {
        let service = FakeT52Service()
        service.commonTeamsValue = [MMTeam(id: teamID, name: "perf", displayName: "Perf")]
        let open = makeModel(service, type: "O")
        await open.load()
        XCTAssertEqual(service.commonTeamsRequests, 0)
        XCTAssertTrue(open.commonTeams.isEmpty)

        let group = makeModel(service, type: "G")
        await group.load()
        XCTAssertEqual(service.commonTeamsRequests, 1)
        XCTAssertEqual(ChannelSharedTeamsDerivation.summary(group.commonTeams), "Perf")
    }

    func testSharedTeamsDerivationDropsEmptyAndDeletedTeams() {
        let teams = [MMTeam(id: "1", name: "perf", displayName: "Perf"),
                     MMTeam(id: "2", name: "ops", displayName: ""),
                     MMTeam(id: "3", name: "gone", displayName: "Gone", deleteAt: 1),
                     MMTeam(id: "4", name: "perf2", displayName: "Perf")]
        XCTAssertEqual(ChannelSharedTeamsDerivation.names(teams), ["Perf", "ops"])
    }

    // MARK: - Files: the wire shape

    func testFileRowsFollowTheServersOrder() throws {
        let json = """
        {"order":["b","a"],
         "file_infos":{
           "a":{"id":"a","post_id":"p1","name":"a.txt","extension":"txt","mime_type":"text/plain","size":12,"create_at":1},
           "b":{"id":"b","post_id":"p2","name":"b.png","extension":"png","mime_type":"image/png","size":34,"create_at":2,"width":4,"height":4}
         },
         "next_file_info_id":""}
        """
        let result = try JSONDecoder().decode(ChannelFileSearchResult.self, from: Data(json.utf8))
        let rows = ChannelFileDerivation.rows(from: result)
        XCTAssertEqual(rows.map(\.id), ["b", "a"])
        XCTAssertEqual(rows.first?.postID, "p2")
        XCTAssertTrue(rows[0].isInlineImage)
        XCTAssertFalse(rows[1].isInlineImage)
        XCTAssertEqual(rows[1].attachment.name, "a.txt")
        XCTAssertEqual(rows[1].attachment.sizeBytes, 12)
    }

    /// A text file's search row carries no `width`/`height` (measured); decoding it must not drop the
    /// row — which is why this list has its own tolerant `ChannelFileInfo` rather than `MMFileInfo`.
    func testATextFileWithoutImageFieldsIsStillARow() throws {
        let json = """
        {"order":["t"],
         "file_infos":{"t":{"id":"t","post_id":"p","name":"notes.txt","extension":"txt","size":9}},
         "next_file_info_id":""}
        """
        let result = try JSONDecoder().decode(ChannelFileSearchResult.self, from: Data(json.utf8))
        let rows = ChannelFileDerivation.rows(from: result)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.attachment.previewKind, .text)
    }

    func testFilesSentWithoutAnOrderAreListedNewestFirst() throws {
        let json = """
        {"order":[],
         "file_infos":{
           "old":{"id":"old","post_id":"p1","name":"old.txt","create_at":10},
           "new":{"id":"new","post_id":"p2","name":"new.txt","create_at":20},
           "tie":{"id":"tie","post_id":"p3","name":"Alpha.txt","create_at":20}
         }}
        """
        let result = try JSONDecoder().decode(ChannelFileSearchResult.self, from: Data(json.utf8))
        // Same second: the name is the tiebreak (case-insensitive ascending), so "Alpha.txt" lands
        // before "new.txt" — deterministic, which is what matters for a list with no server order.
        XCTAssertEqual(ChannelFileDerivation.rows(from: result).map(\.id), ["tie", "new", "old"])
    }

    func testAnUnreadableFileInfoIsDroppedRatherThanDrawnBlank() throws {
        let json = """
        {"order":["good","bad"],
         "file_infos":{"good":{"id":"good","name":"ok.txt"},"bad":{"name":"no id"}}}
        """
        let result = try JSONDecoder().decode(ChannelFileSearchResult.self, from: Data(json.utf8))
        XCTAssertEqual(ChannelFileDerivation.rows(from: result).map(\.id), ["good"])
    }

    func testHasMoreFollowsTheServersCursor() {
        let info = ChannelFileInfo(id: "a")
        XCTAssertFalse(ChannelFileDerivation.hasMore(after: ChannelFileSearchResult(
            order: ["a"], fileInfos: ["a": info], nextFileInfoID: "")))
        XCTAssertTrue(ChannelFileDerivation.hasMore(after: ChannelFileSearchResult(
            order: ["a"], fileInfos: ["a": info], nextFileInfoID: "z")))
        XCTAssertFalse(ChannelFileDerivation.hasMore(after: ChannelFileSearchResult(
            order: ["a"], fileInfos: ["a": info], nextFileInfoID: "a")),
                       "a cursor that repeats a row already sent is the end, not an infinite scroll")
    }

    // MARK: - Files: the list

    func testTheFilesListPagesUntilTheCursorStops() async {
        let service = FakeT52Service()
        service.filePages = [
            ChannelFileSearchResult(order: ["a"],
                                    fileInfos: ["a": ChannelFileInfo(id: "a", postID: "p1",
                                                                     name: "a.txt", size: 1)],
                                    nextFileInfoID: "b"),
            ChannelFileSearchResult(order: ["b"],
                                    fileInfos: ["b": ChannelFileInfo(id: "b", postID: "p2",
                                                                     name: "b.txt", size: 2)],
                                    nextFileInfoID: ""),
        ]
        let files = ChannelFilesViewModel(channelID: channelID, teamID: teamID,
                                          channelName: "t52-channel", service: service)
        await files.load()
        XCTAssertEqual(files.rows.map(\.id), ["a"])
        XCTAssertTrue(files.hasMore)

        await files.loadMore()
        XCTAssertEqual(files.rows.map(\.id), ["a", "b"])
        XCTAssertFalse(files.hasMore)
        XCTAssertEqual(service.fileRequests.map(\.page), [0, 1])
        XCTAssertEqual(service.fileRequests.first?.channelName, "t52-channel")
        XCTAssertEqual(service.fileRequests.first?.teamID, teamID)
    }

    func testAFailedFirstPageIsAnErrorTheScreenCanName() async {
        let service = FakeT52Service()
        service.fileFailure = MMError.forbidden(message: nil)
        let files = ChannelFilesViewModel(channelID: channelID, teamID: teamID,
                                          channelName: "t52-channel", service: service)
        await files.load()
        XCTAssertEqual(files.phase, .failed("You do not have permission to look at this channel's files."))
        XCTAssertTrue(files.rows.isEmpty)
    }

    func testFilesIsNotOfferedForADirectOrGroupMessage() async {
        let service = FakeT52Service()
        let group = makeModel(service, type: "G")
        await group.load()
        XCTAssertFalse(group.actions.contains(.files))
        XCTAssertNil(group.makeChannelFilesModel())
        XCTAssertTrue(group.actions.contains(.notifications))
        XCTAssertTrue(group.actions.contains(.pinned))

        let open = makeModel(service, type: "O")
        await open.load()
        XCTAssertTrue(open.actions.contains(.files))
        XCTAssertNotNil(open.makeChannelFilesModel())
    }

    /// T52-R3: a model created **without** a team (the sheet's default, or a deep link) must build the
    /// files model from the channel the server answered — the empty-team guard used to leave the pushed
    /// screen on a spinner with no request sent.
    func testAFilesModelIsBuiltFromTheChannelsTeamWhenTheModelWasCreatedWithoutOne() async {
        let service = FakeT52Service()
        let model = ChannelInfoViewModel(channelID: channelID,
                                         teamID: "",
                                         fallbackTitle: nil,
                                         service: service)
        await model.load()
        let files = model.makeChannelFilesModel()
        XCTAssertNotNil(files)
        XCTAssertEqual(files?.teamID, "team0000000000000000000001")
        XCTAssertEqual(files?.channelName, "t52-channel")
    }
}
