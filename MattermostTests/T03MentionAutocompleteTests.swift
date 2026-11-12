// T03 — the `@` list offers what a reader expects: bots, and people who are not in the channel.
//
// Why this file exists (kanban t_03f2dbfd). Three defects compounded, and any one of them was enough
// to hide a name:
//
//   1. `GET /users/autocomplete` was decoded down to `users` — `out_of_channel` and `agents` were
//      thrown away, and a bot account is almost never a channel member;
//   2. a bare `@` was short-circuited before any request, so the list could only ever be
//      `@channel`/`@here`/`@all`;
//   3. `ComposerMembership.filter` then deleted every `.user` row that was not a member.
//
// The measurements these tests encode (9.11.19, live fixture — see the card note):
//   * the server reads `in_team` (a team **id**) and `in_channel`; `in_team_id`/`in_channel_id` are
//     ignored, which is why the answer used to be team-wide;
//   * with the documented pair the answer is `{"users": …, "out_of_channel": …}`;
//   * bot user records carry no marker (`roles: "system_user"`), so the label comes from `GET /bots`.
//
// Every test is against a scripted service and a zero debounce: no network, no clock. The live half
// of the same behaviour is in `MattermostUITests/T35-ComposerUITests.swift`.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0, `app/components/autocomplete/
// at_mention/at_mention.tsx` (the in-channel list, `usersOutOfChannel`, and the term-filtered
// `agents`). Apache-2.0; see docs/THIRD_PARTY_NOTICES.md §12.

import Combine
import XCTest
@testable import Mattermost

@MainActor
final class T03MentionAutocompleteTests: XCTestCase {

    private let channelID = "chan-1"

    // MARK: - The scripted server

    @MainActor
    final class FakeService: ComposerServing {
        var answer = ComposerUserCandidates()
        var answerError: Error?
        /// How long the autocomplete request takes, per term.
        var delays: [String: Duration] = [:]
        /// The channel's members as profiles — the local half of a bare `@`.
        var people: [MMUser] = []
        var peopleError: Error?
        var bots: Set<String> = []
        var channelResults: [MMChannel] = []
        var members: ComposerMembership.MemberList = .unknown

        private(set) var userTerms: [String] = []
        private(set) var peopleFetches = 0
        private(set) var botFetches = 0
        /// "a term was asked for", so a test can wait for the request rather than poll.
        let termSignal = TestSignal<String>()

        func createPost(_ body: ComposerPostBody) async throws -> MMPost { throw MMError.offline }
        func patchPost(id: String, message: String, fileIDs: [String]) async throws -> MMPost {
            throw MMError.offline
        }
        func deletePost(id: String) async throws { throw MMError.offline }
        func upload(_ upload: ComposerUpload, channelID: String,
                    onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> MMFileInfo {
            throw MMError.offline
        }

        func users(term: String, channelID: String, teamID: String?,
                   limit: Int) async throws -> ComposerUserCandidates {
            userTerms.append(term)
            termSignal.send(term)
            if let delay = delays[term] { try? await Task.sleep(for: delay) }
            if let answerError { throw answerError }
            return answer
        }

        func channelPeople(channelID: String) async throws -> [MMUser] {
            peopleFetches += 1
            if let peopleError { throw peopleError }
            return people
        }

        func botUserIDs() async throws -> Set<String> {
            botFetches += 1
            return bots
        }

        func channels(term: String, teamID: String, limit: Int) async throws -> [MMChannel] {
            channelResults
        }

        func channelMembers(channelID: String) async throws -> ComposerMembership.MemberList {
            members
        }

        func me() async throws -> MMUser { MMUser(id: "u1", username: "me") }

        func executeCommand(_ command: String, channelID: String, teamID: String?,
                            rootID: String?) async throws -> ComposerCommandResponse {
            throw MMError.offline
        }
    }

    // MARK: - Fixtures

    private var service: FakeService!
    private var model: ComposerViewModel!
    private var mirrors: [AnyCancellable] = []

    override func setUp() async throws {
        service = FakeService()
        mirrors.removeAll()
        model = makeModel()
    }

    override func tearDown() async throws {
        mirrors.removeAll()
        model = nil
        service = nil
    }

    private func makeModel(debounce: Duration = .zero) -> ComposerViewModel {
        ComposerViewModel(channelID: channelID,
                          service: service,
                          drafts: InMemoryComposerDraftStore(),
                          sink: nil,
                          teamID: "team-1",
                          myUserID: "u1",
                          autocompleteDebounce: debounce)
    }

    private func suggestionValues(_ kind: ComposerSuggestion.Kind) -> TestSignal<[String]> {
        let signal = TestSignal<[String]>()
        mirrors.append(mirrorPublished(model.$suggestions, into: signal) { suggestions in
            suggestions.filter { $0.kind == kind }.map(\.value)
        })
        return signal
    }

    private func noteSignal() -> TestSignal<String?> {
        let signal = TestSignal<String?>()
        mirrors.append(mirrorPublished(model.$suggestionNote, into: signal))
        return signal
    }

    private func row(_ value: String) -> ComposerSuggestion? {
        model.suggestions.first { $0.value == value }
    }

    // MARK: - 1. A bare `@` is a list, in the first frame, without a request

    /// The card's first test, stated as strongly as it can be: the list is populated **synchronously**
    /// when `@` is typed, before the debounced request has even started (the assertion runs with no
    /// `await` in between), and that request is then scripted to take five seconds. A first paint that
    /// waited for the network could not pass this.
    func testABareAtDrawsTheChannelsMembersInTheFirstFrame() async {
        service.people = [MMUser(id: "u1", username: "kim", firstName: "Kim")]
        // A model built *after* the fixture is in place: the prefetch it starts in its initializer is
        // the work being measured here.
        model = makeModel()
        await model.awaitMentionSources()
        service.delays[""] = .seconds(5)

        model.textChanged("@", caret: 1)

        // Synchronous: nothing has awaited anything since the keystroke.
        XCTAssertEqual(row("kim")?.section, .inChannel,
                       "a bare @ must draw this channel's members: \(model.suggestions)")
        XCTAssertTrue(service.userTerms.isEmpty,
                      "the first frame must not wait for the request (terms asked: \(service.userTerms))")
        // …and the three addresses are still offered, *after* the people: a bare `@` answers "who is
        // here" first, and drawn above them they filled the visible list on their own.
        XCTAssertEqual(model.suggestions.filter { $0.kind == .specialMention }.map(\.value),
                       ["channel", "here", "all"])
        XCTAssertEqual(model.suggestions.first?.kind, .user,
                       "the first row of a bare @ must be a person: \(model.suggestions)")
        XCTAssertEqual(model.suggestions.last?.kind, .specialMention)

        // The request does still go out when a letter is typed, and its answer joins the list.
        service.answer = ComposerUserCandidates(inChannel: [MMUser(id: "u2", username: "kimba")],
                                               outOfChannel: [])
        service.delays[""] = .zero
        model.textChanged("@k", caret: 2)
        await awaitSignal("the answer for \u{22}k\u{22}", signal: suggestionValues(.user)) {
            $0.contains("kimba")
        }
        XCTAssertTrue(service.userTerms.contains("k"))
    }

    // MARK: - 2. A non-member is offered, in its own band

    func testANonMemberAppearsInTheNotInChannelBand() async throws {
        service.people = [MMUser(id: "u1", username: "bob")]
        await model.awaitMentionSources()
        // The server split: `users` claims both are in the channel, `out_of_channel` names a third.
        service.answer = ComposerUserCandidates(
            inChannel: [MMUser(id: "u1", username: "bob"), MMUser(id: "u9", username: "bonnie")],
            outOfChannel: [MMUser(id: "u5", username: "boomer")])
        service.members = ComposerMembership.MemberList(ids: ["u1"], isComplete: true)

        model.textChanged("@bo", caret: 3)
        await awaitSignal("the mention list", signal: suggestionValues(.user)) {
            $0.contains("bonnie") && $0.contains("boomer")
        }

        XCTAssertEqual(row("bob")?.section, .inChannel)
        // The server said "in channel"; the member list says otherwise, and that is the answer kept.
        XCTAssertEqual(row("bonnie")?.section, .notInChannel,
                       "a non-member must be offered in its own band, not dropped")
        XCTAssertEqual(row("boomer")?.section, .notInChannel)

        // Members come first in the drawn order — the reader's most likely target is on top.
        let values = model.suggestions.map(\.value)
        let bob = try XCTUnwrap(values.firstIndex(of: "bob"))
        let bonnie = try XCTUnwrap(values.firstIndex(of: "bonnie"))
        XCTAssertLessThan(bob, bonnie)
    }

    /// A mention of a non-member still works: choosing the row rewrites the trigger to `@name`.
    func testChoosingANonMemberInsertsTheMention() async throws {
        service.answer = ComposerUserCandidates(
            inChannel: [], outOfChannel: [MMUser(id: "u5", username: "boomer")])
        service.members = ComposerMembership.MemberList(ids: ["u1"], isComplete: true)

        model.textChanged("hi @boo", caret: 8)
        await awaitSignal("the out-of-channel row", signal: suggestionValues(.user)) {
            $0.contains("boomer")
        }
        let choice = try XCTUnwrap(row("boomer"))
        let caret = model.apply(choice)

        XCTAssertEqual(model.text, "hi @boomer ")
        XCTAssertEqual(caret, 11)
    }

    // MARK: - 3. A bot is offered and labelled

    func testABotAccountIsOfferedAndLabelled() async throws {
        service.bots = ["bot1"]
        service.answer = ComposerUserCandidates(
            inChannel: [], outOfChannel: [MMUser(id: "bot1", username: "feedbackbot")])
        service.members = ComposerMembership.MemberList(ids: ["u1"], isComplete: true)
        // The bot list is read when the composer is created; the fixture must be in place by then.
        model = makeModel()
        await model.awaitMentionSources()

        model.textChanged("@feed", caret: 5)
        await awaitSignal("the bot row", signal: suggestionValues(.user)) { $0.contains("feedbackbot") }

        let bot = try XCTUnwrap(row("feedbackbot"))
        XCTAssertEqual(bot.section, .notInChannel,
                       "a bot is not a member, and that is not a reason to hide it")
        XCTAssertEqual(bot.detail, "@feedbackbot · Bot", "the row must say it is a bot")
        XCTAssertEqual(bot.insertion, "@feedbackbot")
    }

    /// An AI agent comes from its own key, in its own band, labelled as an agent.
    func testAnAgentIsOfferedInItsOwnBand() async throws {
        service.answer = ComposerUserCandidates(inChannel: [],
                                                outOfChannel: [],
                                                agents: [MMUser(id: "a1", username: "asking-ai")])
        model.textChanged("@ask", caret: 4)
        await awaitSignal("the agent row", signal: suggestionValues(.user)) { $0.contains("asking-ai") }

        let agent = try XCTUnwrap(row("asking-ai"))
        XCTAssertEqual(agent.section, .agents)
        XCTAssertEqual(agent.detail, "@asking-ai · Agent")
    }

    /// A server that marks the role in the record needs no `GET /bots` at all.
    func testABotIsLabelledFromItsRoleWhenTheServerSaysSo() {
        let user = MMUser(id: "b2", username: "opsbot", roles: "system_user system_bot")
        XCTAssertTrue(user.isBotAccount)
        let row = ComposerMentionRow.suggestion(for: user, section: .notInChannel)
        XCTAssertEqual(row?.detail, "@opsbot · Bot")
    }

    /// 9.11.19's own marker, and the one that reaches a reader without admin rights: `is_bot` is on
    /// the autocomplete row's user record, so no `/bots` request is involved.
    func testABotIsLabelledFromTheServersIsBotField() throws {
        let json = Data(#"""
        {"id": "u9", "username": "feedbackbot", "roles": "system_user", "is_bot": true,
         "first_name": "", "last_name": "", "nickname": "", "delete_at": 0, "update_at": 1,
         "email": "", "terms_of_service_id": "", "terms_of_service_create_at": 0}
        """#.utf8)
        let user = try JSONDecoder().decode(MMUser.self, from: json)
        XCTAssertTrue(user.isBotAccount, "`is_bot` is the server saying so")
        XCTAssertFalse(MMUser(id: "u1", username: "kim").isBotAccount)
    }

    /// `GET /bots` decodes even though `system-bot` has no `delete_at` — the exact shape on 9.11.19.
    /// A strict decode of the array used to throw, and the `try?` around it turned every row's
    /// "Bot" label off with no other symptom.
    func testTheBotListDecodesARecordWithoutDeleteAt() throws {
        let json = Data(#"""
        [{"user_id": "b1", "username": "feedbackbot", "display_name": "Feedbackbot",
          "description": "Feedback", "owner_id": "u1", "delete_at": 0},
         {"user_id": "b2", "username": "system-bot", "display_name": "System",
          "description": "", "owner_id": ""}]
        """#.utf8)
        let bots = try JSONDecoder().decode([MMBot].self, from: json)
        XCTAssertEqual(bots.map(\.userId), ["b1", "b2"])
        XCTAssertTrue(bots.allSatisfy(\.isLive), "a missing delete_at means not deleted")
    }

    // MARK: - 4. The response type decodes all three groups
    //
    // The decode itself is pinned in `T35ComposerAPITests` next to the other envelope shapes:
    //   * `testTheAutocompleteEnvelopeDecodesOutOfChannelAndAgents` (this card's mutant),
    //   * `testTheAutocompleteRequestCarriesTheMembershipScopes` (`in_team` + `in_channel`),
    //   * `testTheChannelScopeIsNeverSentWithoutATeam` (a channel scope alone is a 500 on 9.11.19).
    // What this file adds is that the decoded groups are *used* (tests 2 and 3 above).

    // MARK: - 5. A failed request is not an empty list

    func testAFailedRequestKeepsTheLocalListAndSaysSo() async {
        service.people = [MMUser(id: "u1", username: "kim")]
        model = makeModel()
        await model.awaitMentionSources()
        service.answerError = MMError.server(status: 500, message: "boom")

        model.textChanged("@kim", caret: 4)
        await awaitSignal("the failure note", signal: noteSignal()) { $0 != nil }

        XCTAssertEqual(row("kim")?.section, .inChannel,
                       "the channel's members stay on screen when the request fails")
        XCTAssertEqual(model.suggestionNote, "Couldn't reach the server — showing this channel's members")
        XCTAssertEqual(service.userTerms, ["kim"], "the request was really attempted")
    }

    /// The control half: a *successful* answer that matches nobody has no note at all. Without this,
    /// "the note is present" could be true of every list.
    func testATermThatMatchesNobodyCarriesNoNote() async {
        service.answer = ComposerUserCandidates(inChannel: [], outOfChannel: [])
        model.textChanged("@zzzz", caret: 5)
        await awaitSignal("the request", signal: service.termSignal) { $0 == "zzzz" }
        // Absence window: the answer lands a hop later, and there is no event for "nothing changed".
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertNil(model.suggestionNote, "no matches is not a failure")
        XCTAssertTrue(model.suggestions.filter { $0.kind == .user }.isEmpty)
    }

    // MARK: - 6. The other three sources are untouched

    func testTheChannelAndEmojiListsAreUnchanged() async {
        service.channelResults = [MMChannel(id: "c1", name: "town-square", displayName: "Town Square")]
        model.textChanged("see #town", caret: 9)
        await awaitSignal("the channel list", signal: suggestionValues(.channel)) { !$0.isEmpty }
        XCTAssertEqual(row("town-square")?.insertion, "~town-square")
        // `.none` here is `Section.none`, not the optional's `nil` — spelled out for that reason.
        XCTAssertEqual(row("town-square")?.section, ComposerSuggestion.Section.none)

        XCTAssertFalse(hasHeader(ComposerSuggestionList.rows(model.suggestions)),
                       "a # list has no bands")

        model.textChanged(":tad", caret: 4)
        await awaitSignal("the emoji list", signal: suggestionValues(.emoji)) { $0.contains("tada") }
        XCTAssertEqual(row("tada")?.insertion, ":tada:")
        XCTAssertFalse(hasHeader(ComposerSuggestionList.rows(model.suggestions)),
                       "a : list has no bands")
    }

    // MARK: - No request storm

    /// One fetch per keystroke burst: the debounce and the generation guard decide that, and the
    /// local `@` preview must not add a request of its own. The member prefetch is counted
    /// separately, at one per composer.
    func testOneRequestPerKeystrokeBurst() async {
        // A fresh service, so the composer `setUp` built cannot be charged to this test's counters.
        service = FakeService()
        service.people = [MMUser(id: "u1", username: "kim")]
        model = makeModel(debounce: .milliseconds(80))
        await model.awaitMentionSources()

        model.textChanged("@k", caret: 2)
        model.textChanged("@ki", caret: 3)
        model.textChanged("@kim", caret: 4)
        await awaitSignal("the burst's single answer", signal: service.termSignal) { $0 == "kim" }
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(service.userTerms, ["kim"], "one request for the burst, not one per keystroke")
        XCTAssertEqual(service.peopleFetches, 1, "the member prefetch is per composer, not per keystroke")
    }
}

// MARK: - The drawn rows

/// `ComposerSuggestionList` is what the view iterates, so its shape is asserted as a pure value:
/// a header appears above a band that has rows, and nowhere else.
final class T03SuggestionListTests: XCTestCase {

    private func user(_ name: String, _ section: ComposerSuggestion.Section) -> ComposerSuggestion {
        ComposerSuggestion(kind: .user, value: name, label: name, detail: "@\(name)",
                           insertion: "@\(name)", glyph: nil, userID: "id-\(name)", section: section)
    }

    func testABandWithRowsGetsAHeaderAndTheFlatListGetsNone() {
        let special = ComposerSuggestion(kind: .specialMention, value: "channel", label: "@channel",
                                        detail: "", insertion: "@channel", glyph: "megaphone")
        let rows = ComposerSuggestionList.rows([special,
                                                user("kim", .inChannel),
                                                user("boomer", .notInChannel)])
        // The addresses are drawn last, and no header can sit above a band with no heading.
        XCTAssertEqual(rows.map(\.id), [
            "header-inChannel", "row-user-kim",
            "header-notInChannel", "row-user-boomer",
            "row-specialMention-channel"
        ])
        XCTAssertEqual(rows.compactMap(\.suggestion).map(\.value), ["kim", "boomer", "channel"])
    }

    /// A special mention is its own band: drawn after the people, with no heading of its own.
    func testASpecialMentionIsDrawnAfterThePeopleWithoutAHeading() {
        let special = ComposerSuggestion(kind: .specialMention, value: "here", label: "@here",
                                        detail: "", insertion: "@here", glyph: "megaphone",
                                        section: .special)
        let rows = ComposerSuggestionList.rows([special, user("kim", .inChannel)])
        XCTAssertEqual(rows.map(\.id), ["header-inChannel", "row-user-kim", "row-specialMention-here"])
        XCTAssertEqual(ComposerSuggestion.Section.special.title, nil)
    }

    func testAnEmptyBandIsNotDrawn() {
        let rows = ComposerSuggestionList.rows([user("kim", .inChannel)])
        XCTAssertEqual(rows.map(\.id), ["header-inChannel", "row-user-kim"])
    }

    func testTheListIsCappedPerBand() {
        let suggestions = (0..<20).map { user("kim\($0)", .inChannel) }
        let rows = ComposerSuggestionList.rows(suggestions)
        XCTAssertEqual(rows.compactMap(\.suggestion).count,
                       ComposerSuggestionList.cap(for: .inChannel))
    }
}

private func hasHeader(_ rows: [ComposerSuggestionList.Row]) -> Bool {
    rows.contains { if case .header = $0 { return true } else { return false } }
}
