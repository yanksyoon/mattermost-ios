// T8525 — the channel-info "Ignore mentions" switch (`notify_props.ignore_channel_mentions`) and the
// two drop reasons it feeds, with no network and no clock.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// `app/screens/channel_info/options/ignore_mentions/` — `ignore_mentions.tsx` writes
// `ignore_channel_mentions: "on" | "off"`, and `index.ts`'s `isChannelMentionsIgnored` resolves a
// channel's `"default"` against the account's own `notify_props.channel`. Apache-2.0, read for
// behaviour and reimplemented here.
//
// The card for this work says the field carries `"all"` / `"default"`. It does not, and the difference
// is not cosmetic — measured on the pinned 9.11.19 fixture (`scripts/t8525_ignore_mentions_probe.py`,
// 11/11 checks, docs/t8525-build-note.md §2):
//   * `"on"` / `"off"` / `"default"` are the values the client writes and the server honours;
//   * `"all"` is **stored verbatim** by `PUT …/notify_props` (the route does not validate) and honoured
//     exactly like `"off"`: a `@channel` post still moves `mention_count`. Writing it would be a toggle
//     that changes nothing, so this build never writes it — and it never rewrites one it finds.
//   * `"on"` removes **only** the broadcast keys: a post that names the reader still counts (delta +1),
//     which is why `MentionNotificationPolicy` no longer drops the whole channel for it.
//   * a **muted** channel with `ignore_channel_mentions: "default"` drops the broadcast keys too
//     (`server/channels/app/mention_keywords.go:74`), which is the second drop reason this card asks for.

import XCTest
@testable import Mattermost

@MainActor
final class T8525IgnoreMentionsTests: XCTestCase {

    private let channelID = "chan8525000000000000000001"
    private let teamID = "team8525000000000000000001"
    private let myUserID = "user8525000000000000000001"

    // MARK: - Fake

    @MainActor
    final class FakeService: ChannelInfoServing {
        var channel = MMChannel(id: "chan8525000000000000000001",
                                name: "t8525-channel",
                                displayName: "T8525 channel",
                                type: "O",
                                teamId: "team8525000000000000000001")
        var statsValue = MMChannelStats(channelID: "chan8525000000000000000001", memberCount: 2)
        /// The account row: `notify_props.channel` is what `"default"` resolves against.
        var principalValue = MMPrincipal(id: "user8525000000000000000001",
                                         username: "me",
                                         roles: "system_user",
                                         notifyProps: .object(["channel": .string("true")]))
        var membership: MMChannelMember? = MMChannelMember(
            channelId: "chan8525000000000000000001",
            userId: "user8525000000000000000001",
            roles: "channel_user",
            notifyProps: FakeService.notifyProps())
        /// What the read-back answers **after** a write; `nil` means "the same membership as before".
        var memberAfterWrite: MMChannelMember?
        var memberReadFailure: Error?
        var notifyWriteFailure: Error?

        private(set) var notifyWrites: [[String: String]] = []
        private(set) var notifyWriteUsers: [String] = []

        static func notifyProps(ignore: String = "default",
                                markUnread: String = "all",
                                desktop: String = "default") -> JSONValue {
            .object([
                "desktop": .string(desktop),
                "mark_unread": .string(markUnread),
                "ignore_channel_mentions": .string(ignore),
                "email": .string("default"),
            ])
        }

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
            if let memberReadFailure { throw memberReadFailure }
            if let memberAfterWrite { return memberAfterWrite }
            guard let membership else { throw MMError.notFound }
            return membership
        }
        func patch(channelID: String, patch: MMChannelPatch) async throws -> MMChannel { channel }
        func archive(channelID: String) async throws -> MMChannel { channel }
        func restore(channelID: String) async throws -> MMChannel { channel }
        func addMember(channelID: String, userID: String) async throws -> MMChannelMember {
            MMChannelMember(channelId: channelID, userId: userID)
        }
        func removeMember(channelID: String, userID: String) async throws {}
        func closeDirectChannel(userID: String, channelID: String) async throws {}
        func myTeamChannels(teamID: String) async throws -> [MMChannel] { [] }
        func teamPublicChannels(teamID: String, page: Int, perPage: Int) async throws -> [MMChannel] { [] }
        func usersNotInChannel(teamID: String, channelID: String,
                               page: Int, perPage: Int) async throws -> [MMUser] { [] }
        func searchUsersNotInChannel(teamID: String, channelID: String,
                                     term: String) async throws -> [MMUser] { [] }

        func setNotifyProps(channelID: String, userID: String, fields: [String: String]) async throws {
            notifyWriteUsers.append(userID)
            notifyWrites.append(fields)
            if let notifyWriteFailure { throw notifyWriteFailure }
        }
    }

    private func makeModel(_ service: FakeService) -> ChannelInfoViewModel {
        ChannelInfoViewModel(channelID: service.channel.id,
                             teamID: teamID,
                             fallbackTitle: nil,
                             service: service)
    }

    // MARK: - The derivation (pure)

    func testAnExplicitChannelValueWinsOverTheAccountSetting() {
        XCTAssertEqual(ChannelMentionIgnoreToggle.resolve(channelValue: "on",
                                                          accountChannelMentions: true), .ignoring)
        XCTAssertEqual(ChannelMentionIgnoreToggle.resolve(channelValue: "off",
                                                          accountChannelMentions: false), .notIgnoring)
    }

    func testDefaultResolvesAgainstTheAccountsChannelMentions() {
        // Upstream `isChannelMentionsIgnored`: with the account's own channel mentions off, a channel at
        // "default" is ignoring; with them on, it is not.
        XCTAssertEqual(ChannelMentionIgnoreToggle.resolve(channelValue: "default",
                                                          accountChannelMentions: true), .notIgnoring)
        XCTAssertEqual(ChannelMentionIgnoreToggle.resolve(channelValue: "default",
                                                          accountChannelMentions: false), .ignoring)
        XCTAssertEqual(ChannelMentionIgnoreToggle.resolve(channelValue: nil,
                                                          accountChannelMentions: true), .notIgnoring)
        XCTAssertEqual(ChannelMentionIgnoreToggle.resolve(channelValue: "",
                                                          accountChannelMentions: false), .ignoring)
    }

    func testAnUnknownAccountSettingIsUnreadableNotOff() {
        XCTAssertEqual(ChannelMentionIgnoreToggle.resolve(channelValue: "default",
                                                          accountChannelMentions: nil), .unreadable)
        XCTAssertFalse(ChannelMentionIgnoreState.unreadable.isWritable)
        XCTAssertFalse(ChannelMentionIgnoreState.unreadable.isOn)
    }

    /// `"all"` — the value the card names — is not a value of this setting. It is quoted, not mapped.
    func testAnUnknownServerValueIsQuotedAndNotFlippable() {
        XCTAssertEqual(ChannelMentionIgnoreToggle.resolve(channelValue: "all",
                                                          accountChannelMentions: true),
                       .unknown("all"))
        XCTAssertFalse(ChannelMentionIgnoreState.unknown("all").isWritable)
    }

    func testTheWriteIsAlwaysExplicit() {
        XCTAssertEqual(ChannelMentionIgnoreToggle.wireValue(true), "on")
        XCTAssertEqual(ChannelMentionIgnoreToggle.wireValue(false), "off")
    }

    // MARK: - The write (through the same notify_props path)

    func testFlippingTheSwitchWritesOneFieldAndFollowsTheReadBack() async {
        let service = FakeService()
        let model = makeModel(service)
        await model.load()
        XCTAssertEqual(model.ignoreMentionsState, .notIgnoring, "the fixture starts at the account default")
        service.memberAfterWrite = MMChannelMember(channelId: channelID, userId: myUserID,
                                                   roles: "channel_user",
                                                   notifyProps: FakeService.notifyProps(ignore: "on"))

        let succeeded = await model.setIgnoreMentions(true)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(service.notifyWrites.count, 1)
        XCTAssertEqual(service.notifyWriteUsers, [myUserID])
        XCTAssertEqual(service.notifyWrites.first, ["ignore_channel_mentions": "on"],
                       "only this field travels; nothing else about the channel is rewritten")
        XCTAssertEqual(model.notifyDraft?.ignoreMentions, "on", "the state follows the server's read-back")
        XCTAssertEqual(model.ignoreMentionsState, .ignoring)
        XCTAssertEqual(model.notifyDraft?.markUnread, "all", "the mute was not touched")
    }

    /// Turning it off from a state that was **derived** from the account setting writes `"off"`, never
    /// `"default"` — `"default"` would re-inherit the very setting that made the switch show "on".
    func testTurningOffFromAnAccountDefaultWritesOffNotDefault() async {
        let service = FakeService()
        service.principalValue.notifyProps = .object(["channel": .string("false")])
        let model = makeModel(service)
        await model.load()
        XCTAssertEqual(model.ignoreMentionsState, .ignoring)
        service.memberAfterWrite = MMChannelMember(channelId: channelID, userId: myUserID,
                                                   notifyProps: FakeService.notifyProps(ignore: "off"))

        let succeeded = await model.setIgnoreMentions(false)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(service.notifyWrites.first, ["ignore_channel_mentions": "off"])
        XCTAssertEqual(model.ignoreMentionsState, .notIgnoring)
    }

    func testFlippingToTheStoredValueSendsNothing() async {
        let service = FakeService()
        service.membership = MMChannelMember(channelId: channelID, userId: myUserID,
                                             notifyProps: FakeService.notifyProps(ignore: "on"))
        let model = makeModel(service)
        await model.load()

        let succeeded = await model.setIgnoreMentions(true)

        XCTAssertTrue(succeeded)
        XCTAssertTrue(service.notifyWrites.isEmpty, "a switch already at the server's value is not a write")
    }

    func testAFailedWriteLeavesTheSwitchAtTheServersValue() async {
        let service = FakeService()
        let model = makeModel(service)
        await model.load()
        service.notifyWriteFailure = MMError.forbidden(message: nil)

        let succeeded = await model.setIgnoreMentions(true)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(model.ignoreMentionsState, .notIgnoring, "a failed write claims nothing")
        XCTAssertEqual(model.banner, "You do not have permission to do that.")
    }

    func testAnUnknownServerValueIsNeverRewritten() async {
        let service = FakeService()
        service.membership = MMChannelMember(channelId: channelID, userId: myUserID,
                                             notifyProps: FakeService.notifyProps(ignore: "all"))
        let model = makeModel(service)
        await model.load()
        XCTAssertEqual(model.ignoreMentionsState, .unknown("all"))
        XCTAssertFalse(model.canToggleIgnoreMentions)

        let succeeded = await model.setIgnoreMentions(false)

        XCTAssertFalse(succeeded)
        XCTAssertTrue(service.notifyWrites.isEmpty)
        XCTAssertEqual(model.refusedMessage,
                       "This channel's mention setting is \"all\", which this app does not know how to change.")
    }

    func testUnreadablePreferencesRefuseTheWrite() async {
        let service = FakeService()
        service.membership = nil                       // the membership read failed
        let model = makeModel(service)
        await model.load()
        XCTAssertFalse(model.notifyPropsAvailable)

        let succeeded = await model.setIgnoreMentions(true)

        XCTAssertFalse(succeeded)
        XCTAssertTrue(service.notifyWrites.isEmpty, "a guess must never become a write")
        XCTAssertEqual(model.refusedMessage, "Your notification preferences could not be read.")
    }

    // MARK: - Where the switch is drawn

    func testTheSwitchIsDrawnForEveryTypeButADirectMessage() async {
        for type in ["O", "P", "G"] {
            let service = FakeService()
            service.channel.type = type
            let model = makeModel(service)
            await model.load()
            XCTAssertTrue(model.showsIgnoreMentionsSwitch, "type \(type) must offer the switch")
        }
        let direct = FakeService()
        direct.channel.type = "D"
        let model = makeModel(direct)
        await model.load()
        XCTAssertFalse(model.showsIgnoreMentionsSwitch,
                       "upstream draws no ignore-mentions row for a direct message")
    }

    func testTheAccountSettingIsReadFromTheSameProfileThePermissionsUse() async {
        let service = FakeService()
        service.principalValue.notifyProps = .object(["channel": .string("false")])
        let model = makeModel(service)
        await model.load()
        XCTAssertEqual(model.accountChannelMentions, false)
        XCTAssertEqual(model.ignoreMentionsState, .ignoring)
    }

    func testASocketMembershipUpdateMovesTheSwitch() async {
        let service = FakeService()
        let model = makeModel(service)
        await model.load()
        XCTAssertEqual(model.ignoreMentionsState, .notIgnoring)

        model.handle(event: .channelMemberUpdated(SocketChannelMemberUpdate(
            member: MMChannelMember(channelId: channelID, userId: myUserID,
                                    notifyProps: FakeService.notifyProps(ignore: "on")))))

        XCTAssertEqual(model.ignoreMentionsState, .ignoring,
                       "another client's flip lands here through the same membership read")
    }

    // MARK: - The policy contract, measured

    private func reader() -> MentionReader {
        MentionReader(userID: "me",
                      keys: MentionKeys(keys: [MentionKey("@perfprobe"), MentionKey("Terry", caseSensitive: true),
                                               MentionKey("@channel"), MentionKey("@all"), MentionKey("@here")]))
    }

    private func post(_ message: String) -> MMPost {
        MMPost(id: "post1", createAt: 0, updateAt: 0, editAt: 0, deleteAt: 0, userId: "buddy",
               channelId: "ch1", rootId: "", message: message, type: "", props: nil)
    }

    private func channel(type: String = "O") -> MMChannel {
        MMChannel(id: "ch1", name: "t8525-ignore", displayName: "T8525 ignore", type: type,
                  teamId: "team1")
    }

    private func member(ignore: String = "default", markUnread: String = "all",
                        desktop: String = "default") -> MMChannelMember {
        MMChannelMember(channelId: "ch1", userId: "me",
                        notifyProps: .object(["desktop": .string(desktop),
                                              "ignore_channel_mentions": .string(ignore),
                                              "mark_unread": .string(markUnread)]))
    }

    private func decision(_ message: String,
                          ignore: String = "default",
                          markUnread: String = "all",
                          channelType: String = "O") -> MentionDecision {
        MentionNotificationPolicy.decision(post: post(message),
                                           reader: reader(),
                                           channel: channel(type: channelType),
                                           membership: member(ignore: ignore, markUnread: markUnread))
    }

    func testIgnoresChannelMentionsDropsABroadcastMention() {
        XCTAssertEqual(decision("@channel standup in five", ignore: "on"), .drop(.mentionsIgnored))
        XCTAssertEqual(decision("@all standup in five", ignore: "on"), .drop(.mentionsIgnored))
        XCTAssertEqual(decision("@here standup in five", ignore: "on"), .drop(.mentionsIgnored))
    }

    /// The measured correction: `"on"` removes the *broadcast* keys only. A post that names the reader
    /// still moves the server's `mention_count` (delta +1) and therefore still delivers.
    func testADirectMentionStillDeliversWhenBroadcastMentionsAreIgnored() {
        XCTAssertEqual(decision("@perfprobe can you look?", ignore: "on"), .deliver(silent: false))
    }

    func testAMutedChannelIgnoresBroadcastsOnlyWhileTheSettingIsDefault() {
        XCTAssertEqual(decision("@channel standup", markUnread: "mention"),
                       .drop(.mutedChannelMentionsIgnored))
        XCTAssertEqual(decision("@channel standup", ignore: "off", markUnread: "mention"),
                       .deliver(silent: false),
                       "muted + off keeps the broadcast mention (measured delta +1)")
        XCTAssertEqual(decision("@perfprobe can you look?", markUnread: "mention"),
                       .deliver(silent: false),
                       "a muted channel still notifies a real mention")
    }

    func testAnUnmutedChannelKeepsBroadcastMentions() {
        XCTAssertEqual(decision("@channel standup"), .deliver(silent: false))
        XCTAssertEqual(decision("@channel standup", ignore: "default", markUnread: "all"),
                       .deliver(silent: false))
    }

    /// `"all"` is storable but not honoured: the server treats it like `"off"` (measured delta +1).
    func testTheStoredButUnhonouredAllValueDoesNotSuppressAnything() {
        XCTAssertEqual(decision("@channel standup", ignore: "all"), .deliver(silent: false))
    }

    func testAPostThatMentionsNobodyIsNotAMentionNotAnIgnoredOne() {
        XCTAssertEqual(decision("lunch?", ignore: "on"), .drop(.notAMention),
                       "the drop has to name the right reason: nothing was ignored, nothing named you")
    }

    func testADirectMessageIsGovernedByItsMuteNotByTheBroadcastSetting() {
        XCTAssertEqual(decision("are you around?", ignore: "on", channelType: "D"),
                       .deliver(silent: false),
                       "upstream draws no ignore-mentions row for a DM; @channel names nobody there")
        XCTAssertEqual(decision("are you around?", ignore: "on", markUnread: "mention", channelType: "D"),
                       .drop(.channelNotificationsOff))
    }

    func testTheTwoIgnoreReasonsHaveTheirOwnDiagnostics() {
        XCTAssertEqual(MentionDropReason.mentionsIgnored.label,
                       "this channel is set to ignore @channel, @all and @here")
        XCTAssertEqual(MentionDropReason.mutedChannelMentionsIgnored.label,
                       "this channel is muted, so @channel, @all and @here do not notify you")
        XCTAssertNotEqual(MentionDropReason.mentionsIgnored.label,
                          MentionDropReason.mutedChannelMentionsIgnored.label)
        for reason in [MentionDropReason.mentionsIgnored, .mutedChannelMentionsIgnored] {
            XCTAssertTrue(reason.recordsAsHandled,
                          "the reader's own setting decided it, so the poll must not deliver it later")
            XCTAssertFalse(reason.label.isEmpty)
        }
    }
}
