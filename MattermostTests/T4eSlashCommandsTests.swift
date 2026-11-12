// T4e — slash commands in the native composer: the `/` source, the per-team list and its cache, the
// execute call, and the answer's own path back into the timeline.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb),
// `app/components/autocomplete/slash_suggestion/slash_suggestion.tsx` + `slash_suggestion_item.tsx`,
// `app/actions/remote/command.ts`, `app/client/rest/integrations.ts`,
// `app/hooks/handle_send_message.ts` (`sendCommand`). Licence Apache-2.0 — see
// docs/THIRD_PARTY_NOTICES.md §12; no upstream source copied.
//
// Every server shape asserted here was measured on the pinned 9.11.19 fixture
// (`scripts/t4e_slash_probe.py`): `GET /commands?team_id=` answers a **bare array** of 33 records for
// team `perf`, `/help` answers `{"response_type":"ephemeral","text":…}`, `/nosuchcommand` answers
// **404** with the sentence in the body, and the answer to an ephemeral command arrives on the socket
// as `ephemeral_message` carrying a post whose `type` is `system_ephemeral`.

import XCTest
@testable import Mattermost

// MARK: - The pure rules

final class T4eSlashCommandTests: XCTestCase {

    // MARK: The `/` trigger

    func testABareSlashIsATriggerAtTheStartOfTheMessage() {
        let trigger = ComposerTriggerParser.trigger(in: "/", caret: 1)
        XCTAssertEqual(trigger?.kind, .slash)
        XCTAssertEqual(trigger?.term, "")
        XCTAssertEqual(trigger?.range, NSRange(location: 0, length: 1),
                       "the range is the token a completion replaces")
    }

    func testTheTermIsTheTypedPrefixAndTheRangeCoversTheWholeFirstWord() {
        let trigger = ComposerTriggerParser.trigger(in: "/hel", caret: 4)
        XCTAssertEqual(trigger?.kind, .slash)
        XCTAssertEqual(trigger?.term, "hel")
        XCTAssertEqual(trigger?.range, NSRange(location: 0, length: 4))

        // A caret parked inside the token (`/hel|p`): the term is what has been typed up to the
        // caret, but the range must reach the end of the word, or completing `/help` leaves the `p`
        // behind ("/help p").
        let parked = ComposerTriggerParser.trigger(in: "/help", caret: 4)
        XCTAssertEqual(parked?.term, "hel")
        XCTAssertEqual(parked?.range, NSRange(location: 0, length: 5),
                       "a command's completion replaces the whole first token")
    }

    /// The rule that keeps a sentence about a command from being one: upstream draws its list only
    /// while `value[0] === '/'`.
    func testASlashThatIsNotTheFirstWordIsNotATrigger() {
        XCTAssertNil(ComposerTriggerParser.trigger(in: "see /help", caret: 9))
        XCTAssertNil(ComposerTriggerParser.trigger(in: "please /", caret: 8))
        XCTAssertNil(ComposerTriggerParser.trigger(in: "https:/", caret: 7))
    }

    func testASlashPathIsNotACommandTrigger() {
        // Command triggers are `[a-z0-9_-]+`: a second slash is a path, not a command prefix.
        XCTAssertNil(ComposerTriggerParser.trigger(in: "/a/b", caret: 4))
    }

    func testOnceTheFirstWordIsFinishedThereIsNoSlashTrigger() {
        // The caret sits after a space: the token before it is empty, so the list closes. Upstream
        // would now ask the server for argument suggestions (a separate endpoint, see the file
        // header of ComposerCommands.swift); with no Apps framework there is nothing to ask for.
        XCTAssertNil(ComposerTriggerParser.trigger(in: "/help ", caret: 6))
        XCTAssertNil(ComposerTriggerParser.trigger(in: "/help me", caret: 8))
    }

    func testTheOtherSourcesAreUnchanged() {
        XCTAssertEqual(ComposerTriggerParser.trigger(in: "@ki", caret: 3)?.kind, .mention)
        XCTAssertEqual(ComposerTriggerParser.trigger(in: "#to", caret: 3)?.kind, .channel)
        XCTAssertEqual(ComposerTriggerParser.trigger(in: ":smi", caret: 4)?.kind, .emoji)
        XCTAssertNil(ComposerTriggerParser.trigger(in: "mail me@example.com", caret: 19))
    }

    func testCompletingACommandReplacesTheTypedPrefixAndAddsOneSpace() {
        let trigger = ComposerTriggerParser.trigger(in: "/he", caret: 3)!
        let suggestion = ComposerSuggestion(kind: .slash, value: "help", label: "/help",
                                            detail: "Show Mattermost help message",
                                            insertion: slashInsertion("help"), glyph: nil,
                                            hint: nil)
        let result = ComposerTriggerParser.apply(suggestion, to: "/he", trigger: trigger)
        XCTAssertEqual(result?.text, "/help ")
        XCTAssertEqual(result?.caret, 6)
    }

    // MARK: The command string

    func testTheCommandStringIsTheMessageOnlyWhenItStartsWithASlashAndHasATrigger() {
        XCTAssertEqual(ComposerSlashCommand.command(in: "/help"), "/help ")
        XCTAssertEqual(ComposerSlashCommand.command(in: "/HELP now"), "/help now",
                       "the trigger is lower-cased; the arguments keep their case")
        XCTAssertEqual(ComposerSlashCommand.command(in: "  /help  "), "/help ",
                       "the message is trimmed before it is read")
        XCTAssertNil(ComposerSlashCommand.command(in: "hello"))
        XCTAssertNil(ComposerSlashCommand.command(in: "see /help"))
        XCTAssertNil(ComposerSlashCommand.command(in: "/"), "a bare slash is not a command")
        XCTAssertNil(ComposerSlashCommand.command(in: "/ help"), "a space ends an empty trigger")
    }

    func testAnEmDashBecomesADoubleDashBeforeTheServerParsesIt() {
        // Upstream `filterEmDashForCommand`: a paste from a word processor carries U+2014, which the
        // server's flag parser would not read as `--`.
        XCTAssertEqual(ComposerSlashCommand.command(in: "/echo \u{2014}hi"), "/echo --hi")
    }

    func testCodeKeepsItsBodyVerbatimApartFromTrailingSpace() {
        XCTAssertEqual(ComposerSlashCommand.command(in: "/code  let x = 1  \n"), "/code   let x = 1")
        XCTAssertEqual(ComposerSlashCommand.command(in: "/echo  hi  "), "/echo hi")
    }

    // MARK: The list's decode and filter

    private func commandJSON(trigger: String,
                             displayName: String? = nil,
                             autoComplete: Bool = true,
                             hint: String = "",
                             desc: String = "",
                             deleteAt: Int64 = 0) -> [String: Any] {
        ["id": "", "token": "", "create_at": 0, "update_at": 0, "delete_at": deleteAt,
         "creator_id": "", "team_id": "", "trigger": trigger, "method": "", "username": "",
         "icon_url": "", "auto_complete": autoComplete, "auto_complete_desc": desc,
         "auto_complete_hint": hint, "display_name": displayName ?? trigger,
         "description": "", "url": "", "plugin_id": ""]
    }

    func testTheCommandListDecodesTheServersBareArray() throws {
        let payload: [[String: Any]] = [
            commandJSON(trigger: "status", hint: "[:emoji_name:] [status_message] or clear",
                        desc: "Set or clear your status"),
            commandJSON(trigger: "help", desc: "Show Mattermost help message"),
        ]
        let commands = try JSONDecoder().decode([MMCommand].self,
                                                from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(commands.map(\.trigger), ["status", "help"])
        XCTAssertEqual(commands[0].autoCompleteHint, "[:emoji_name:] [status_message] or clear")
        XCTAssertEqual(commands[0].autoCompleteDesc, "Set or clear your status")
        XCTAssertTrue(commands[0].autoComplete)
        XCTAssertEqual(commands[0].deleteAt, 0)
    }

    func testACommandRecordMissingFieldsStillDecodes() throws {
        // A custom integration from another server version may answer without the optional fields;
        // one missing `auto_complete_hint` must not take the whole list down.
        let partial = Data(#"{"trigger":"deploy","auto_complete":true}"#.utf8)
        let command = try JSONDecoder().decode(MMCommand.self, from: partial)
        XCTAssertEqual(command.trigger, "deploy")
        XCTAssertEqual(command.autoCompleteHint, "")
        XCTAssertEqual(command.displayName, "")
        XCTAssertTrue(command.autoComplete)
    }

    func testTheOfferedListDropsWhatTheMobileClientCannotHonour() {
        let commands = [
            MMCommand(trigger: "help"),
            // Upstream's `COMMANDS_TO_HIDE_ON_MOBILE`: three unimplemented, three desktop-only.
            MMCommand(trigger: "collapse"), MMCommand(trigger: "expand"), MMCommand(trigger: "logout"),
            MMCommand(trigger: "shortcuts"), MMCommand(trigger: "search"), MMCommand(trigger: "settings"),
            // `auto_complete: false` is the server saying "do not offer this".
            MMCommand(trigger: "secret", autoComplete: false),
            // A deleted integration and an empty trigger are not rows either.
            MMCommand(trigger: "gone", deleteAt: 42),
            MMCommand(trigger: ""),
            // Two records for one trigger (a plugin and a built-in can collide) collapse to one row.
            MMCommand(trigger: "help"),
        ]
        XCTAssertEqual(ComposerCommandList.offered(commands).map(\.trigger), ["help"],
                       "only the command the client can actually run survives")
    }

    func testTheSuggestionRowsCarryTheArgumentHintAndTheInsertion() {
        let commands = [
            MMCommand(trigger: "invite", displayName: "invite",
                      autoCompleteDesc: "Invite a user to a channel",
                      autoCompleteHint: "@[username]... ~[channel]..."),
            MMCommand(trigger: "help", displayName: "help",
                      autoCompleteDesc: "Show Mattermost help message"),
        ]
        let rows = ComposerCommandList.suggestions(commands, term: "")
        XCTAssertEqual(rows.map(\.value), ["help", "invite"], "sorted by what is typed")
        XCTAssertEqual(rows[1].label, "/invite")
        XCTAssertEqual(rows[1].insertion, "/invite")
        XCTAssertEqual(rows[1].hint, "@[username]... ~[channel]...")
        XCTAssertEqual(rows[1].detail, "Invite a user to a channel")
        XCTAssertNil(rows[0].hint, "no hint on the wire, no hint in the row")
        XCTAssertEqual(rows[0].id, "slash-help")
    }

    func testTheTermMatchesTheTriggerOrTheDisplayNameAsAPrefixOnly() {
        let commands = [
            MMCommand(trigger: "msg", displayName: "message"),
            MMCommand(trigger: "groupmsg", displayName: "message"),
            MMCommand(trigger: "help", displayName: "help"),
        ]
        // Upstream matches `display_name.startsWith(term) || trigger.startsWith(term)`.
        XCTAssertEqual(ComposerCommandList.suggestions(commands, term: "mes").map(\.value),
                       ["groupmsg", "msg"], "both match on their display name, sorted by insertion")
        XCTAssertEqual(ComposerCommandList.suggestions(commands, term: "HEL").map(\.value), ["help"],
                       "the keyboard capitalises the first letter")
        XCTAssertTrue(ComposerCommandList.suggestions(commands, term: "sg").isEmpty,
                      "a substring match is not what upstream does")
    }

    // MARK: The wire shapes

    func testTheExecuteBodyUsesTheDocumentedFieldNames() throws {
        let body = ComposerCommandBody(command: "/help ", channelId: "chan-1",
                                       teamId: "team-1", rootId: nil)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        XCTAssertEqual(object?["command"] as? String, "/help ")
        XCTAssertEqual(object?["channel_id"] as? String, "chan-1")
        XCTAssertEqual(object?["team_id"] as? String, "team-1")
        XCTAssertNil(object?["root_id"], "an absent root must not be sent as an empty string")
    }

    func testTheExecuteBodyCarriesARootForAThreadCommand() throws {
        let body = ComposerCommandBody(command: "/help ", channelId: "chan-1",
                                       teamId: "team-1", rootId: "root-9")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        XCTAssertEqual(object?["root_id"] as? String, "root-9")
    }

    func testTheServersAnswerDecodesBothOfItsShapes() throws {
        let ephemeral = Data(#"""
        {"response_type":"ephemeral","text":"Mattermost is an open source platform…","username":"","channel_id":"","icon_url":"","type":"","props":null,"goto_location":"","trigger_id":"","skip_slack_parsing":false,"attachments":null,"extra_responses":null}
        """#.utf8)
        let answer = try JSONDecoder().decode(ComposerCommandResponse.self, from: ephemeral)
        XCTAssertTrue(answer.isEphemeral)
        XCTAssertEqual(answer.text, "Mattermost is an open source platform…")
        XCTAssertEqual(answer.gotoLocation, "")

        let inChannel = Data(#"{"response_type":"in_channel","text":""}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(ComposerCommandResponse.self, from: inChannel).isEphemeral)

        // `{}` must decode rather than throw: a command integration can answer an empty body, and a
        // decode failure there would read as "the command failed" when it did not.
        let empty = try JSONDecoder().decode(ComposerCommandResponse.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.text, "")
    }

    // MARK: The per-team cache

    @MainActor
    func testTheCommandListIsFetchedOncePerTeamAndShared() async {
        let catalogue = SlashCommandCatalogue()
        var fetches = 0
        let commands = [MMCommand(trigger: "help")]

        let first = await catalogue.commands(teamID: "team-1") {
            fetches += 1
            return commands
        }
        let second = await catalogue.commands(teamID: "team-1") {
            fetches += 1
            return commands
        }
        let otherTeam = await catalogue.commands(teamID: "team-2") {
            fetches += 1
            return [MMCommand(trigger: "deploy")]
        }

        XCTAssertEqual(fetches, 2, "one fetch per team, not one per composer")
        XCTAssertEqual(first.map(\.trigger), ["help"])
        XCTAssertEqual(second.map(\.trigger), ["help"])
        XCTAssertEqual(otherTeam.map(\.trigger), ["deploy"])
        XCTAssertEqual(catalogue.fetchCount, 2)
    }

    @MainActor
    func testConcurrentReadersJoinOneFetch() async {
        let catalogue = SlashCommandCatalogue()
        var fetches = 0
        // The fetch never returns until the second caller is waiting on the same task, which is the
        // shape of "two panes mount at once".
        async let slow: [MMCommand] = catalogue.commands(teamID: "team-1") {
            fetches += 1
            try? await Task.sleep(for: .milliseconds(40))
            return [MMCommand(trigger: "help")]
        }
        async let alsoSlow: [MMCommand] = catalogue.commands(teamID: "team-1") {
            fetches += 1
            return [MMCommand(trigger: "help")]
        }
        let (a, b) = await (slow, alsoSlow)
        XCTAssertEqual(fetches, 1, "a second caller joins the in-flight request")
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(b.count, 1)
    }

    @MainActor
    func testAFailedFetchIsNotCachedSoTheNextSlashRetries() async {
        let catalogue = SlashCommandCatalogue()
        var attempts = 0
        let failed = await catalogue.commands(teamID: "team-1") {
            attempts += 1
            throw MMError.offline
        }
        XCTAssertTrue(failed.isEmpty)
        XCTAssertNil(catalogue.cached(teamID: "team-1"))

        let recovered = await catalogue.commands(teamID: "team-1") {
            attempts += 1
            return [MMCommand(trigger: "help")]
        }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(recovered.map(\.trigger), ["help"])
    }

    @MainActor
    func testAnEmptyTeamIDNeverFetches() async {
        let catalogue = SlashCommandCatalogue()
        var fetches = 0
        let commands = await catalogue.commands(teamID: "") {
            fetches += 1
            return [MMCommand(trigger: "help")]
        }
        XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(fetches, 0, "GET /commands without a team_id is a 400 on the server")
    }

    // MARK: The socket frame

    /// The frame below is the one measured from 9.11.19 after a `/help` (`scripts/t4e_slash_probe.py`),
    /// with the text shortened: `ephemeral_message`, a post **as a JSON string**, `type:
    /// system_ephemeral`, broadcast to the caller.
    func testTheMeasuredEphemeralFrameDecodesIntoAnAnswerRow() throws {
        let frame = try JSONDecoder().decode(MMSocketFrame.self, from: Data(#"""
        {"event":"ephemeral_message","data":{"post":"{\"id\":\"81pg65qxbinxi86af1xdj7ud4y\",\"create_at\":1793844277045,\"update_at\":0,\"edit_at\":0,\"delete_at\":0,\"is_pinned\":false,\"user_id\":\"jruqqzxtobg7tn4wehwmwjjo5c\",\"channel_id\":\"n7cmmoggg38fxn54ffs3w8q4ja\",\"root_id\":\"\",\"original_id\":\"\",\"message\":\"**Channels** - Stay connected with your team\",\"type\":\"system_ephemeral\",\"props\":{},\"hashtags\":\"\",\"pending_post_id\":\"\",\"reply_count\":0,\"last_reply_at\":0,\"participants\":null,\"metadata\":{}}"},"broadcast":{"omit_users":null,"user_id":"jruqqzxtobg7tn4wehwmwjjo5c","channel_id":"n7cmmoggg38fxn54ffs3w8q4ja","team_id":"","connection_id":"","omit_connection_id":""},"seq":2}
        """#.utf8))

        guard case .ephemeralMessage(let post)? = SocketEvent(frame: frame) else {
            return XCTFail("an ephemeral_message frame must decode into a typed event")
        }
        XCTAssertEqual(post.type, "system_ephemeral")
        XCTAssertEqual(post.channelId, "n7cmmoggg38fxn54ffs3w8q4ja")
        XCTAssertEqual(post.message, "**Channels** - Stay connected with your team")
        XCTAssertTrue(post.rootId.isEmpty)
        XCTAssertTrue(SocketEvent(frame: frame)?.name == "ephemeral_message")
    }

    func testAnEphemeralFrameWhosePostIsNotAPostIsDropped() throws {
        let frame = try JSONDecoder().decode(MMSocketFrame.self, from: Data(#"""
        {"event":"ephemeral_message","data":{},"seq":3}
        """#.utf8))
        XCTAssertNil(SocketEvent(frame: frame), "a malformed frame must be dropped, never half-decoded")
    }
}

// MARK: - The endpoint and the message it refuses with

final class T4eSlashAPITests: XCTestCase {

    private let serverURL = URL(string: "https://mm.example.com")!

    private func makeClient(_ transport: APITransport) throws -> APIClient {
        try APIClient(serverURL: serverURL,
                      transport: transport,
                      retryPolicy: APIClient.RetryPolicy(maxAttempts: 1, baseDelay: 0,
                                                         maxDelay: 0, jitterRatio: 0),
                      tokenProvider: { "test-token" },
                      sleep: { _ in },
                      random: { 0 })
    }

    func testTheCommandListIsAGetWithTheTeamQuery() async throws {
        let transport = FakeAPITransport(repeating: .json([
            ["trigger": "help", "auto_complete": true, "auto_complete_desc": "Show Mattermost help message",
             "auto_complete_hint": "", "display_name": "help", "delete_at": 0, "id": "", "team_id": ""],
        ]))
        let client = try makeClient(transport)

        let commands = try await client.commands(teamID: "team-1")

        XCTAssertEqual(commands.map(\.trigger), ["help"])
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.url.path, "/api/v4/commands")
        let components = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "team_id" })?.value, "team-1")
    }

    func testExecutingACommandPostsToCommandsExecute() async throws {
        let transport = FakeAPITransport(repeating: .json(["response_type": "ephemeral",
                                                           "text": "help text"]))
        let client = try makeClient(transport)

        let answer = try await client.executeCommand(
            ComposerCommandBody(command: "/help ", channelId: "chan-1", teamId: "team-1", rootId: nil))

        XCTAssertEqual(answer.responseType, "ephemeral")
        XCTAssertEqual(answer.text, "help text")
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url.path, "/api/v4/commands/execute")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: Any]
        XCTAssertEqual(body?["command"] as? String, "/help ")
        XCTAssertEqual(body?["channel_id"] as? String, "chan-1")
        XCTAssertEqual(body?["team_id"] as? String, "team-1")
    }

    /// The sentence `/nosuchcommand` refuses with is the one the reader must see; the generic 404
    /// mapping (`MMError.notFound`, "this channel is gone") would replace it.
    func testAnUnknownCommandKeepsTheServersSentence() async throws {
        let transport = FakeAPITransport(repeating: .json([
            "id": "api.command.execute_command.not_found.app_error",
            "message": "Command with a trigger of 'nosuchcommand' not found. To send a message beginning with \"/\", try adding an empty space at the beginning of the message.",
            "status_code": 404,
        ], status: 404))
        let client = try makeClient(transport)

        do {
            _ = try await client.executeCommand(
                ComposerCommandBody(command: "/nosuchcommand ", channelId: "chan-1",
                                    teamId: "team-1", rootId: nil))
            XCTFail("a 404 must throw")
        } catch let error as MMError {
            guard case .client(let status, let message) = error else {
                return XCTFail("expected .client(404), got \(error)")
            }
            XCTAssertEqual(status, 404)
            XCTAssertEqual(message, "Command with a trigger of 'nosuchcommand' not found. To send a message beginning with \"/\", try adding an empty space at the beginning of the message.")
            XCTAssertEqual(ComposerErrorCopy.message(for: error), message,
                           "the composer shows the server's sentence, not its own copy")
        }
    }

    /// The other half of the same switch: a 404 that is *not* a command keeps the generic mapping, so
    /// no screen starts showing raw API prose because of this card.
    func testAnyOtherNotFoundStillReadsAsGone() async throws {
        let transport = FakeAPITransport(repeating: .json(["message": "not found"], status: 404))
        let client = try makeClient(transport)
        do {
            _ = try await client.createPost(ComposerPostBody(channelId: "chan-1", message: "hi",
                                                             rootId: nil, fileIds: nil,
                                                             pendingPostId: nil))
            XCTFail("a 404 must throw")
        } catch let error as MMError {
            XCTAssertEqual(error, .notFound)
        }
    }
}

// MARK: - The composer's behaviour

@MainActor
final class T4eSlashComposerTests: XCTestCase {

    private let channelID = "chan-1"

    @MainActor
    final class FakeService: ComposerServing {
        var commandList: Result<[MMCommand], Error> = .success([])
        var executeResults: [Result<ComposerCommandResponse, Error>] = []
        var executeDelay: Duration = .zero

        private(set) var commandFetches: [String] = []
        private(set) var executed: [(command: String, channelID: String, teamID: String?, rootID: String?)] = []
        private(set) var created: [ComposerPostBody] = []

        func createPost(_ body: ComposerPostBody) async throws -> MMPost {
            created.append(body)
            throw MMError.offline
        }
        func patchPost(id: String, message: String, fileIDs: [String]) async throws -> MMPost {
            throw MMError.offline
        }
        func deletePost(id: String) async throws { throw MMError.offline }
        func upload(_ upload: ComposerUpload, channelID: String,
                    onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> MMFileInfo {
            throw MMError.offline
        }
        func users(term: String, channelID: String, teamID: String?, limit: Int) async throws -> ComposerUserCandidates { ComposerUserCandidates() }
        func channels(term: String, teamID: String, limit: Int) async throws -> [MMChannel] { [] }
        func channelMembers(channelID: String) async throws -> ComposerMembership.MemberList { .unknown }
        func me() async throws -> MMUser { MMUser(id: "u1", username: "me") }

        func commands(teamID: String) async throws -> [MMCommand] {
            commandFetches.append(teamID)
            return try commandList.get()
        }

        func executeCommand(_ command: String, channelID: String, teamID: String?,
                            rootID: String?) async throws -> ComposerCommandResponse {
            executed.append((command, channelID, teamID, rootID))
            if executeDelay > .zero { try? await Task.sleep(for: executeDelay) }
            guard !executeResults.isEmpty else {
                throw MMError.offline
            }
            return try executeResults[min(executed.count - 1, executeResults.count - 1)].get()
        }
    }

    @MainActor
    final class RecordingSink: ComposerPostSink {
        var inserted: [MMPost] = []
        func insertPendingPost(_ post: MMPost) { inserted.append(post) }
        func confirmPendingPost(id: String, with post: MMPost) {}
        func removePendingPost(id: String) {}
        func replacePost(_ post: MMPost) {}
        func tombstonePost(id: String) {}
        func post(withPendingID pendingID: String) -> MMPost? { nil }
    }

    private var service: FakeService!
    private var sink: RecordingSink!
    private var drafts: InMemoryComposerDraftStore!
    private var catalogue: SlashCommandCatalogue!
    private var model: ComposerViewModel!

    override func setUp() async throws {
        service = FakeService()
        sink = RecordingSink()
        drafts = InMemoryComposerDraftStore()
        catalogue = SlashCommandCatalogue()
        model = ComposerViewModel(channelID: channelID, service: service, drafts: drafts,
                                  sink: sink, teamID: "team-1", myUserID: "u1",
                                  commandCatalogue: catalogue,
                                  autocompleteDebounce: .zero)
    }

    private func makeModel(teamID: String?) -> ComposerViewModel {
        let model = ComposerViewModel(channelID: channelID, service: service, drafts: drafts,
                                      sink: sink, teamID: teamID, myUserID: "u1",
                                      commandCatalogue: catalogue,
                                      autocompleteDebounce: .zero)
        return model
    }

    /// The suggestion source is fire-and-forget behind a zero debounce: wait for it to publish
    /// rather than assuming one `Task.yield()` is enough.
    private func waitForSuggestions(_ model: ComposerViewModel,
                                    _ condition: @escaping ([ComposerSuggestion]) -> Bool) async -> [ComposerSuggestion] {
        for _ in 0..<400 {
            if condition(model.suggestions) { return model.suggestions }
            await Task.yield()
        }
        return model.suggestions
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    private func ephemeralAnswer(_ text: String = "Mattermost is an open source platform…")
        -> ComposerCommandResponse {
        ComposerCommandResponse(responseType: "ephemeral", text: text)
    }

    // MARK: 1. Sending runs the command

    func testSendingASlashMessageExecutesItAndInsertsNoPendingRow() async {
        service.executeResults = [.success(ephemeralAnswer())]
        model.textChanged("/help", caret: 5)
        XCTAssertTrue(model.canSend)

        await model.send()

        XCTAssertEqual(service.executed.count, 1)
        XCTAssertEqual(service.executed[0].command, "/help ",
                       "the line is normalized before it is sent (upstream `sendCommand`)")
        XCTAssertEqual(service.executed[0].channelID, channelID)
        XCTAssertEqual(service.executed[0].teamID, "team-1")
        XCTAssertNil(service.executed[0].rootID)
        XCTAssertTrue(service.created.isEmpty, "a command is not a post")
        XCTAssertTrue(sink.inserted.isEmpty,
                      "a command has no optimistic row: it may answer ephemerally, in the channel, or not at all")
        XCTAssertEqual(model.text, "", "a successful command consumes the line")
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.lastCommandResponse?.isEphemeral, true)
    }

    func testASuccessfulCommandClearsTheDraftRow() async {
        service.executeResults = [.success(ephemeralAnswer())]
        model.textChanged("/help", caret: 5)
        // The write-through draft store has the line on disk before the send.
        let wrote = await waitUntil { [drafts] in
            await drafts?.load(channelID: self.channelID, rootID: "")?.message == "/help"
        }
        XCTAssertTrue(wrote, "the write-through draft store must hold the typed line")

        await model.send()

        // The draft row is deleted by a fire-and-forget store call (the send path must not block on
        // disk), so the assertion is "the row is gone", awaited rather than assumed.
        let cleared = await waitUntil { [drafts] in
            await drafts?.load(channelID: self.channelID, rootID: "") == nil
        }
        XCTAssertTrue(cleared,
                      "the line was consumed by the server; keeping it would re-run the command on the next Send")
    }

    func testACommandInAThreadCarriesTheRoot() async {
        let threadSink = ThreadSink(anchor: ComposerThreadAnchor(rootID: "root-9", authorLabel: "Ana"))
        let threadModel = ComposerViewModel(channelID: channelID, service: service, drafts: drafts,
                                            sink: threadSink, teamID: "team-1", myUserID: "u1",
                                            commandCatalogue: catalogue, autocompleteDebounce: .zero)
        threadModel.beginReply(to: MMPost(id: "root-9", channelId: channelID, message: "root"),
                               authorLabel: "Ana")
        service.executeResults = [.success(ephemeralAnswer())]

        threadModel.textChanged("/help", caret: 5)
        await threadModel.send()

        XCTAssertEqual(service.executed.last?.rootID, "root-9")
        XCTAssertTrue(threadSink.inserted.isEmpty)
    }

    /// A sink that claims to be a thread's list. Kept out of `RecordingSink` so its default stays the
    /// channel shape every other test wants.
    @MainActor
    final class ThreadSink: ComposerPostSink {
        let threadAnchor: ComposerThreadAnchor?
        var inserted: [MMPost] = []
        init(anchor: ComposerThreadAnchor) { threadAnchor = anchor }
        func insertPendingPost(_ post: MMPost) { inserted.append(post) }
        func confirmPendingPost(id: String, with post: MMPost) {}
        func removePendingPost(id: String) {}
        func replacePost(_ post: MMPost) {}
        func tombstonePost(id: String) {}
        func post(withPendingID pendingID: String) -> MMPost? { nil }
    }

    // MARK: 2. A refused command

    func testARefusedCommandShowsTheServersSentenceAndKeepsTheWords() async {
        let sentence = "Command with a trigger of 'nosuchcommand' not found. To send a message beginning with \"/\", try adding an empty space at the beginning of the message."
        service.executeResults = [.failure(MMError.client(status: 404, message: sentence))]
        model.textChanged("/nosuchcommand", caret: 15)

        await model.send()

        XCTAssertEqual(model.phase, .failed(sentence), "the server's own sentence, not a generic one")
        XCTAssertEqual(model.text, "/nosuchcommand", "the words stay in the input")
        XCTAssertTrue(sink.inserted.isEmpty, "and no pending row was ever drawn")
        let stored = await drafts.load(channelID: channelID, rootID: "")
        XCTAssertEqual(stored?.message, "/nosuchcommand",
                       "the refused line is written through for the retry")
    }

    func testRetryRerunsTheSameCommandLine() async {
        let sentence = "Command with a trigger of 'nosuchcommand' not found."
        service.executeResults = [.failure(MMError.client(status: 404, message: sentence)),
                                  .success(ephemeralAnswer())]
        model.textChanged("/nosuchcommand", caret: 15)
        await model.send()
        XCTAssertEqual(model.phase, .failed(sentence))

        await model.retry()

        XCTAssertEqual(service.executed.count, 2)
        XCTAssertEqual(service.executed.map(\.command), ["/nosuchcommand ", "/nosuchcommand "])
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.text, "")
    }

    // MARK: 3. The `/` source

    func testTypingSlashOffersTheTeamsCommandsWithTheirHints() async {
        service.commandList = .success([
            MMCommand(trigger: "help", autoCompleteDesc: "Show Mattermost help message"),
            MMCommand(trigger: "invite", autoCompleteDesc: "Invite a user to a channel",
                      autoCompleteHint: "@[username]... ~[channel]..."),
            MMCommand(trigger: "settings", autoCompleteDesc: "Open the Settings dialog"),
        ])
        model.textChanged("/", caret: 1)

        let suggestions = await waitForSuggestions(model) { !$0.isEmpty }

        XCTAssertEqual(suggestions.map(\.value), ["help", "invite"],
                       "the desktop-only `settings` is not offered on mobile")
        XCTAssertEqual(suggestions.first(where: { $0.value == "invite" })?.hint,
                       "@[username]... ~[channel]...")
        XCTAssertEqual(service.commandFetches, ["team-1"])
    }

    func testTheListIsFetchedOnceForEveryComposerOfTheTeam() async {
        service.commandList = .success([MMCommand(trigger: "help")])
        let second = makeModel(teamID: "team-1")

        model.textChanged("/", caret: 1)
        _ = await waitForSuggestions(model) { !$0.isEmpty }
        second.textChanged("/h", caret: 2)
        let rows = await waitForSuggestions(second) { !$0.isEmpty }

        XCTAssertEqual(rows.map(\.value), ["help"])
        XCTAssertEqual(service.commandFetches, ["team-1"], "the second composer reads the cache")
        XCTAssertEqual(catalogue.fetchCount, 1)
    }

    func testAFailedCommandListDrawsNoListAndIsRetriedNextTime() async {
        service.commandList = .failure(MMError.offline)
        model.textChanged("/", caret: 1)
        let asked = await waitUntil { [service] in (service?.commandFetches.count ?? 0) == 1 }
        XCTAssertTrue(asked, "typing / must ask the server for the list")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(model.suggestions.isEmpty)

        service.commandList = .success([MMCommand(trigger: "help")])
        model.textChanged("/h", caret: 2)
        let rows = await waitForSuggestions(model) { !$0.isEmpty }
        XCTAssertEqual(rows.map(\.value), ["help"])
        XCTAssertEqual(service.commandFetches, ["team-1", "team-1"])
    }

    func testASlashInsideASentenceDoesNotOpenTheList() async {
        service.commandList = .success([MMCommand(trigger: "help")])
        model.textChanged("see /hel", caret: 8)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(model.suggestions.isEmpty)
        XCTAssertTrue(service.commandFetches.isEmpty, "nothing was asked for")
        XCTAssertNil(model.activeTrigger)
    }

    func testAComposerWithoutATeamOffersNoCommands() async {
        let teamless = makeModel(teamID: nil)
        teamless.textChanged("/", caret: 1)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(teamless.suggestions.isEmpty)
        XCTAssertTrue(service.commandFetches.isEmpty)
    }

    func testCompletingACommandReplacesThePrefixAndClosesTheList() async {
        service.commandList = .success([MMCommand(trigger: "help")])
        model.textChanged("/he", caret: 3)
        let rows = await waitForSuggestions(model) { !$0.isEmpty }
        guard let help = rows.first else { return XCTFail("no rows") }

        let caret = model.apply(help)

        XCTAssertEqual(model.text, "/help ")
        XCTAssertEqual(caret, 6)
        XCTAssertTrue(model.suggestions.isEmpty)
        XCTAssertNil(model.activeTrigger)
    }

    func testEditingAPostNeverOffersCommands() async {
        service.commandList = .success([MMCommand(trigger: "help")])
        var post = MMPost(id: "p1", createAt: 1, userId: "u1", channelId: channelID,
                          message: "an existing message")
        post.fileIds = []
        await model.beginEditing(post)
        model.textChanged("/", caret: 1)

        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(model.suggestions.isEmpty)
        XCTAssertNil(model.activeTrigger)
        XCTAssertTrue(service.commandFetches.isEmpty)
    }
}
