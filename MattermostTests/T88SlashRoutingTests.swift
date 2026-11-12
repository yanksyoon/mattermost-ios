// T88 — plugin commands and app commands: which endpoint a line belongs to, and the two instructions
// a command's answer can carry back (`trigger_id`, `goto_location`).
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb),
//   app/actions/remote/command.ts  — `executeCommand` (the four ids, the apps check, the trigger id),
//                                    `executeAppCommand`, `handleGotoLocation`
//   app/hooks/handle_send_message.ts — `sendCommand` (follows `goto_location` except for `/leave`)
//   app/components/autocomplete/slash_suggestion/app_command_parser/app_command_parser.ts —
//                                    `isAppCommand` (a binding's label, and only with an argument)
//   app/managers/integrations_manager.ts — the correlation the trigger id exists for
//   app/managers/apps_manager.ts    — `isAppsEnabled` / bindings, and what a failed bindings fetch means
// Licence Apache-2.0 — see docs/THIRD_PARTY_NOTICES.md §12; no upstream source copied.
//
// Everything the server side of these tests asserts was measured on the pinned 9.11.19 fixture with
// `scripts/t88_slash_plugin_probe.py` + `scripts/t88_slash_stub.py`:
//   * `GET /commands` carries the active plugins' commands (`call`, `playbook`) with
//     `auto_complete: true`, no `plugin_id` and an `autocomplete_data` block; custom integrations
//     carry a non-empty `id`;
//   * every plugin and custom command's answer carries a `trigger_id`; a built-in's does not
//     (`/help` answers `trigger_id: ""` — the server sets it only on the plugin/custom paths);
//   * a command with two `extra_responses` arrives as three socket events (two `ephemeral_message`,
//     one `posted`), and a command that opens a dialog sends `open_dialog` keyed by the very
//     `trigger_id` the answer carried;
//   * `goto_location` arrives in the answer and nowhere else — the socket carries only the text;
//   * `FeatureFlagAppsEnabled` is `true` on a server whose Apps plugin is **not installed**
//     (`/plugins/com.mattermost.apps/api/v1/bindings` → 404).

import XCTest
@testable import Mattermost

// MARK: - The pure rules

final class T88CommandRoutingTests: XCTestCase {

    // MARK: The request body

    /// Upstream builds `{channel_id, team_id, root_id: rootId, parent_id: rootId}` from one argument
    /// (`command.ts:41-46`). A plugin reads `args.ParentId`; a custom HTTP integration sees neither id
    /// (measured), so this is parity for the plugin path and harmless for the other.
    func testTheExecuteBodySendsParentIdBesideRootId() throws {
        let body = ComposerCommandBody(command: "/call start ", channelId: "chan-1",
                                       teamId: "team-1", rootId: "root-9")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        XCTAssertEqual(object?["root_id"] as? String, "root-9")
        XCTAssertEqual(object?["parent_id"] as? String, "root-9")
    }

    func testAChannelCommandSendsNeitherId() throws {
        let body = ComposerCommandBody(command: "/help ", channelId: "chan-1", teamId: "team-1",
                                       rootId: nil)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        XCTAssertNil(object?["root_id"], "an absent root must not be sent as an empty string")
        XCTAssertNil(object?["parent_id"], "and neither must its twin")
    }

    // MARK: Which endpoint

    /// The one rule `AppCommandParser.isAppCommand` is: `command.startsWith(label + ' ')`. The
    /// trailing space is load-bearing — **a bare app trigger is not an app command**, so `/gif`
    /// goes to `/commands/execute` even on a server that binds `/gif`, and `/gif cats` does not.
    func testAnAppCommandIsRecognisedOnlyOnceItHasAnArgument() {
        let posture = ComposerAppsPosture(isEnabled: true, commandLabels: ["gif"])
        XCTAssertEqual(ComposerCommandRouting.destination(for: "/gif cats", posture: posture),
                       .app(binding: "/gif"))
        XCTAssertEqual(ComposerCommandRouting.destination(for: "/GIF Cats", posture: posture),
                       .app(binding: "/gif"), "the line is compared lower-cased, as upstream does")
        XCTAssertEqual(ComposerCommandRouting.destination(for: "/gif", posture: posture), .execute,
                       "upstream requires the space; a bare trigger is not an app command")
        XCTAssertEqual(ComposerCommandRouting.destination(for: "/gifs cats", posture: posture),
                       .execute, "a longer trigger is a different command")
    }

    func testAppsSwitchedOffSendsEveryLineToCommandsExecute() {
        let posture = ComposerAppsPosture(isEnabled: false, commandLabels: ["gif"])
        XCTAssertEqual(ComposerCommandRouting.destination(for: "/gif cats", posture: posture),
                       .execute,
                       "the labels are only consulted when the framework is switched on")
        XCTAssertEqual(ComposerCommandRouting.destination(for: "/help", posture: .unavailable),
                       .execute)
    }

    /// A label may arrive with or without its slash; both name the same command.
    func testALabelIsNormalisedWhenItIsBuilt() {
        XCTAssertEqual(ComposerAppsPosture(isEnabled: true, commandLabels: ["gif", "/meets", " "]).commandLabels,
                       ["/gif", "/meets"])
    }

    /// Two apps can share a prefix (`/gif` and `/gif-maker`): the longer label owns the line.
    func testTheLongestMatchingLabelOwnsTheLine() {
        let posture = ComposerAppsPosture(isEnabled: true, commandLabels: ["/gif", "/gif-maker"])
        XCTAssertEqual(ComposerCommandRouting.destination(for: "/gif-maker new", posture: posture),
                       .app(binding: "/gif-maker"))
        XCTAssertEqual(ComposerCommandRouting.destination(for: "/gif cat", posture: posture),
                       .app(binding: "/gif"))
    }

    /// `/leave` answers with a location too, and following it would drag the reader back into the
    /// channel the command just removed them from.
    func testAGotoLocationIsFollowedExceptAfterLeave() {
        XCTAssertTrue(ComposerCommandRouting.followsGotoLocation("/somecommand "))
        XCTAssertFalse(ComposerCommandRouting.followsGotoLocation("/leave-something else"),
                       "upstream's test is `startsWith('/leave')`, so even `/leave-x` is spared — the order "
                       + "of the two lines is: navigate unless the line begins with /leave")
        XCTAssertFalse(ComposerCommandRouting.followsGotoLocation("/leave "))
        XCTAssertFalse(ComposerCommandRouting.followsGotoLocation("/LEAVE"))
    }

    // MARK: The two server facts, read through the real client

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

    /// `/config/client?format=old` is a flat name → value map, and a flag can arrive as a JSON boolean
    /// or as a string. Measured: `FeatureFlagAppsEnabled` is a boolean `true` on 9.11.19, on a server
    /// whose apps plugin is not installed at all.
    func testTheAppsFlagIsReadFromThePublicConfigInEitherShape() async throws {
        let transport = FakeAPITransport(repeating: .json(["FeatureFlagAppsEnabled": true,
                                                           "EnableCommands": "true"]))
        let client = try makeClient(transport)
        let enabled = try await client.clientConfigFlag("FeatureFlagAppsEnabled")
        XCTAssertTrue(enabled)
        let commands = try await client.clientConfigFlag("EnableCommands")
        XCTAssertTrue(commands, "a flag published as the string \"true\" reads as true")
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url.path, "/api/v4/config/client")
        XCTAssertEqual(request.url.query, "format=old")
    }

    func testAMissingOrFalseFlagReadsAsFalse() async throws {
        let transport = FakeAPITransport(repeating: .json(["FeatureFlagAppsEnabled": false]))
        let off = try await makeClient(transport).clientConfigFlag("FeatureFlagAppsEnabled")
        XCTAssertFalse(off)
        let missing = FakeAPITransport(repeating: .json([:]))
        let absent = try await makeClient(missing).clientConfigFlag("FeatureFlagAppsEnabled")
        XCTAssertFalse(absent)
    }

    /// The bindings answer is a list of apps, each carrying its own `bindings` array (upstream's
    /// `normalizeBindings` flattens exactly that). Only `command`-location bindings can claim a
    /// slash line; a `channel_header` or `in_post` binding must not.
    func testOnlyCommandBindingsBecomeLabels() async throws {
        let transport = FakeAPITransport(repeating: .json([
            ["app_id": "gif",
             "bindings": [
                ["label": "/gif", "location": "command"],
                ["label": "/gif-post", "location": "in_post"],
                ["location": "command", "label": ""],
             ]],
            ["app_id": "meets", "bindings": [["label": "meets", "location": "command"]]],
        ]))
        let labels = try await makeClient(transport)
            .appsCommandLabels(userID: "u1", channelID: "chan-1", teamID: "team-1")
        XCTAssertEqual(labels.sorted(), ["/gif", "meets"])
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url.path, "/api/v4/plugins/com.mattermost.apps/api/v1/bindings")
        let query = request.url.query ?? ""
        XCTAssertTrue(query.contains("channel_id=chan-1"))
        XCTAssertTrue(query.contains("team_id=team-1"))
        XCTAssertTrue(query.contains("user_id=u1"))
    }

    /// A shape this client does not draw must not throw on the send path: the apps answer is walked
    /// as raw JSON, so an object with no bindings is simply no labels.
    func testAnUnexpectedBindingsShapeYieldsNoLabelsRatherThanThrowing() async throws {
        let transport = FakeAPITransport(repeating: .json([]))
        let labels = try await makeClient(transport)
            .appsCommandLabels(userID: "", channelID: "chan-1", teamID: nil)
        XCTAssertTrue(labels.isEmpty)
    }
}

// MARK: - The live witness (real server; env-gated like every live test here)

/// The same composer, the same service, the same client — against the pinned 9.11.19 fixture, with the
/// stub integration from `scripts/t88_slash_stub.py` answering. What this adds over the fakes above:
/// the answers are decoded from real wire bytes, so a field name or a type that drifted cannot pass.
///
/// Run (dev fixture; credentials are the throwaway ones in `scripts/perf_seed.py`):
///
///     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
///     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
///     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
///     python3 scripts/qa-test.py --sim "T88 iPhone 16 Pro" \
///       --only-testing MattermostTests/T88LiveSlashTests
///
/// Each test skips (never fails) when the environment or the fixture is missing.
@MainActor
final class T88LiveSlashTests: XCTestCase {

    private var serverURL: URL!
    private var token = ""
    private var userID = ""
    private var teamID = ""
    private var channelID = ""

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        let loginID = env["MM_AUTH_LOGIN"] ?? ""
        let password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live slash test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        _ = try call("/system/ping", authenticated: false)
        let session = try authenticate(login: loginID, password: password)
        token = session.token
        userID = session.userID
        let teams = try JSONSerialization.jsonObject(with: call("/users/me/teams")) as? [[String: Any]] ?? []
        guard let team = teams.first(where: { $0["name"] as? String == "perf" }),
              let id = team["id"] as? String else {
            throw XCTSkip("team #perf is missing on this fixture")
        }
        teamID = id
        let channel = try JSONSerialization.jsonObject(
            with: call("/teams/\(teamID)/channels/name/t35-composer")) as? [String: Any] ?? [:]
        guard let id = channel["id"] as? String else {
            throw XCTSkip("channel #t35-composer is missing — run scripts/t35_composer_seed.py")
        }
        channelID = id
    }

    // MARK: The wiring the fake tests cannot prove

    private func service() -> SessionComposerService {
        let url = serverURL!
        let token = token
        return SessionComposerService {
            try? APIClient(serverURL: url,
                           transport: URLSessionTransport(serverURL: url),
                           tokenProvider: { token })
        }
    }

    private func composer() -> ComposerViewModel {
        ComposerViewModel(channelID: channelID,
                          service: service(),
                          drafts: InMemoryComposerDraftStore(),
                          sink: T88ComposerCommandTests.SilentSink(),
                          teamID: teamID,
                          myUserID: userID,
                          commandCatalogue: SlashCommandCatalogue(),
                          autocompleteDebounce: .zero)
    }

    /// `FeatureFlagAppsEnabled` is `true` here while `/plugins/com.mattermost.apps/…/bindings` 404s, so
    /// the posture is exactly the state upstream treats as "the framework is on, no app commands" —
    /// and the shape this client reads has to survive the 404 rather than throw.
    func testTheAppsQuestionOnAFixtureWithoutTheAppsPlugin() async {
        let posture = await service().appsPosture(channelID: channelID, teamID: teamID, userID: userID)
        XCTAssertTrue(posture.isEnabled, "FeatureFlagAppsEnabled is true on 9.11.19 by default")
        XCTAssertTrue(posture.commandLabels.isEmpty,
                      "no apps plugin on the fixture ⇒ the bindings 404 ⇒ no labels, not a failure")
    }

    /// The plugin command's answer, decoded from the real body: `trigger_id` set, `goto_location`
    /// empty, `response_type` ephemeral. Then the same answer through the composer, which must hand the
    /// id to the dialog presenter.
    func testTheComposerHandsOnTheTriggerIdAPluginAnswerCarries() async throws {
        let model = composer()
        var presented: [String] = []
        model.onTriggerID = { presented.append($0) }

        model.textChanged("/t88dialog", caret: 10)
        await model.send()

        XCTAssertEqual(model.phase, .idle, "a 200 answer is a success")
        let triggerID = try XCTUnwrap(model.lastCommandResponse?.triggerID)
        XCTAssertFalse(triggerID.isEmpty, "a plugin/custom command's answer carries a trigger_id")
        XCTAssertEqual(presented, [triggerID])
    }

    /// `goto_location` is in the answer body only — no socket frame carries it — so the composer's hook
    /// is the whole mechanism.
    func testTheComposerFollowsALiveGotoLocation() async throws {
        let model = composer()
        var navigated: [String] = []
        model.onGotoLocation = { navigated.append($0) }

        model.textChanged("/t88goto", caret: 8)
        await model.send()

        XCTAssertEqual(navigated.count, 1, "the answer carries goto_location; nothing else does")
        let location = try XCTUnwrap(navigated.first)
        XCTAssertTrue(location.contains("/perf/channels/town-square"), "got \(location)")
    }

    /// A command the server does not know is a 404 whose body is the sentence a reader must see, and
    /// the words stay in the box.
    func testAnUnknownCommandKeepsTheServersSentence() async {
        let model = composer()
        model.textChanged("/nosuchcommand", caret: 14)
        await model.send()

        guard case .failed(let sentence) = model.phase else {
            return XCTFail("expected a failure, got \(model.phase)")
        }
        XCTAssertTrue(sentence.contains("Command with a trigger of 'nosuchcommand' not found"),
                      "the server's own sentence, not a generic one: \(sentence)")
        XCTAssertEqual(model.text, "/nosuchcommand", "the words stay where they can be fixed")
    }

    /// The measured multi-answer: two `extra_responses` beside the command's own text. The composer
    /// sends nothing of its own for them — the three socket frames are the rows — so all it must do is
    /// complete without inventing a post.
    func testAMultiAnswerCompletesWithoutPostingAnything() async {
        let model = composer()
        var navigated: [String] = []
        model.onGotoLocation = { navigated.append($0) }
        model.textChanged("/t88multi", caret: 9)
        await model.send()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(navigated.isEmpty)
        XCTAssertEqual(model.text, "", "a consumed command clears the box")
    }

    // MARK: Plumbing (the fixture's own API, as the UI tests do it)

    private struct Session { var token: String; var userID: String }

    private func call(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                      authenticated: Bool = true) throws -> Data {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4" + path))
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authenticated { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let semaphore = DispatchSemaphore(value: 0)
        var answer = Data()
        var failure: Error?
        URLSession.shared.dataTask(with: request) { data, _, error in
            answer = data ?? Data()
            failure = error
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        if let failure { throw failure }
        return answer
    }

    private func authenticate(login: String, password: String) throws -> Session {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/users/login"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["login_id": login,
                                                                       "password": password])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let semaphore = DispatchSemaphore(value: 0)
        var token = ""
        var userID = ""
        URLSession.shared.dataTask(with: request) { data, response, _ in
            token = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Token") ?? ""
            if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                userID = object["id"] as? String ?? ""
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        guard !token.isEmpty, !userID.isEmpty else { throw XCTSkip("login failed on the fixture") }
        return Session(token: token, userID: userID)
    }
}


@MainActor
final class T88ComposerCommandTests: XCTestCase {

    private let channelID = "chan-1"

    @MainActor
    final class FakeService: ComposerServing {
        var posture: ComposerAppsPosture = .unavailable
        var executeResults: [Result<ComposerCommandResponse, Error>] = []

        private(set) var executed: [(command: String, channelID: String, teamID: String?, rootID: String?)] = []
        private(set) var postureAsks: [(channelID: String, teamID: String?, userID: String)] = []

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
                   limit: Int) async throws -> ComposerUserCandidates { ComposerUserCandidates() }
        func channels(term: String, teamID: String, limit: Int) async throws -> [MMChannel] { [] }
        func channelMembers(channelID: String) async throws -> ComposerMembership.MemberList { .unknown }
        func me() async throws -> MMUser { MMUser(id: "u1", username: "me") }
        func commands(teamID: String) async throws -> [MMCommand] { [] }
        func executeCommand(_ command: String, channelID: String, teamID: String?,
                            rootID: String?) async throws -> ComposerCommandResponse {
            executed.append((command, channelID, teamID, rootID))
            guard !executeResults.isEmpty else { throw MMError.offline }
            return try executeResults[min(executed.count - 1, executeResults.count - 1)].get()
        }
        func appsPosture(channelID: String, teamID: String?,
                         userID: String) async -> ComposerAppsPosture {
            postureAsks.append((channelID, teamID, userID))
            return posture
        }
    }

    @MainActor
    final class SilentSink: ComposerPostSink {
        var inserted: [MMPost] = []
        func insertPendingPost(_ post: MMPost) { inserted.append(post) }
        func confirmPendingPost(id: String, with post: MMPost) {}
        func removePendingPost(id: String) {}
        func replacePost(_ post: MMPost) {}
        func tombstonePost(id: String) {}
        func post(withPendingID pendingID: String) -> MMPost? { nil }
    }

    private func model(_ service: FakeService,
                       sink: ComposerPostSink? = nil) -> ComposerViewModel {
        ComposerViewModel(channelID: channelID,
                          service: service,
                          drafts: InMemoryComposerDraftStore(),
                          sink: sink ?? SilentSink(),
                          teamID: "team-1",
                          myUserID: "u1",
                          commandCatalogue: SlashCommandCatalogue(),
                          autocompleteDebounce: .zero)
    }

    // MARK: Plugin commands still execute

    /// The measured fixture state: `FeatureFlagAppsEnabled` is true, the apps plugin is not installed
    /// so its bindings 404 and there are no app commands. A plugin command must then take the ordinary
    /// path — this is `/call help` and `/playbook list`, which answer with a `trigger_id` and draw
    /// their text from the socket.
    func testAPluginCommandExecutesThroughCommandsExecute() async {
        let service = FakeService()
        service.posture = ComposerAppsPosture(isEnabled: true, commandLabels: [])
        let model = self.model(service)
        service.executeResults = [.success(ComposerCommandResponse(responseType: "ephemeral",
                                                                  text: "Invalid subcommand",
                                                                  triggerID: "trig-1"))]

        model.textChanged("/call help", caret: 10)
        await model.send()

        XCTAssertEqual(service.executed.count, 1)
        XCTAssertEqual(service.executed.first?.command, "/call help",
                       "the trigger is lower-cased, the arguments keep their case")
        XCTAssertEqual(service.postureAsks.first?.userID, "u1",
                       "the bindings are asked for with the reader's own id, as upstream's getAppsBindings does")
        XCTAssertEqual(model.phase, .idle)
    }

    // MARK: App commands do not

    /// An app command is **not** a slash command: posting it to `/commands/execute` is the one thing
    /// upstream never does, and the server answers it with "Command with a trigger of 'gif' not found"
    /// for a command the server does have. Until the Apps runtime is ported (S34 D2), the honest answer
    /// is a sentence that says so — and **no request**.
    func testALineOwnedByAnAppBindingIsNotPostedToCommandsExecute() async {
        let service = FakeService()
        service.posture = ComposerAppsPosture(isEnabled: true, commandLabels: ["/gif"])
        let model = self.model(service)

        model.textChanged("/gif cats", caret: 9)
        await model.send()

        XCTAssertTrue(service.executed.isEmpty, "an app command must not reach /commands/execute")
        XCTAssertEqual(model.phase, .failed(ComposerCommandRouting.appRuntimeUnavailable))
        XCTAssertEqual(model.text, "/gif cats",
                       "nothing was sent, so the words stay where the reader can fix them")
    }

    /// The trailing-space rule from the pure tests, seen from the composer: a bare `/gif` is executed
    /// the ordinary way even on a server that binds it.
    func testABareAppTriggerStillExecutesTheOrdinaryWay() async {
        let service = FakeService()
        service.posture = ComposerAppsPosture(isEnabled: true, commandLabels: ["/gif"])
        let model = self.model(service)
        service.executeResults = [.success(ComposerCommandResponse(responseType: "ephemeral",
                                                                  text: "GIF help"))]

        model.textChanged("/gif", caret: 4)
        await model.send()

        XCTAssertEqual(service.executed.count, 1)
    }

    // MARK: The answer's own instructions

    /// The dialog handshake. `POST /commands/execute` answers a plugin or custom command with a
    /// `trigger_id`; the plugin then pushes `open_dialog` keyed by it, and only a matching pair may be
    /// shown (measured: the frame's `trigger_id` is exactly the answer's). The composer's whole part is
    /// to keep that id alive and hand it on.
    func testTheTriggerIdAnAnswerCarriesLeavesForTheDialogPresenter() async {
        let service = FakeService()
        let model = self.model(service)
        var presented: [String] = []
        model.onTriggerID = { presented.append($0) }
        service.executeResults = [.success(ComposerCommandResponse(responseType: "ephemeral",
                                                                  text: "dialog requested",
                                                                  triggerID: "trig-7"))]

        model.textChanged("/t88dialog", caret: 10)
        await model.send()

        XCTAssertEqual(presented, ["trig-7"])
        XCTAssertEqual(model.lastCommandResponse?.triggerID, "trig-7")
    }

    /// A built-in answers with an empty `trigger_id` (`/help` measured: `""`), and an empty id must not
    /// be presented — it would be a dialog key that can never match.
    func testAnAnswerWithoutATriggerIdPresentsNothing() async {
        let service = FakeService()
        let model = self.model(service)
        var presented: [String] = []
        model.onTriggerID = { presented.append($0) }
        service.executeResults = [.success(ComposerCommandResponse(responseType: "ephemeral",
                                                                  text: "help"))]

        model.textChanged("/help", caret: 5)
        await model.send()

        XCTAssertTrue(presented.isEmpty)
    }

    /// `goto_location` arrives in the answer and nowhere else — the socket delivers only the text — so
    /// the client is the only thing that can navigate.
    func testAGotoLocationIsHandedToTheShell() async {
        let service = FakeService()
        let model = self.model(service)
        var navigated: [String] = []
        model.onGotoLocation = { navigated.append($0) }
        service.executeResults = [.success(ComposerCommandResponse(
            responseType: "ephemeral",
            text: "taking you there",
            gotoLocation: "https://mm.example.com/perf/channels/town-square"))]

        model.textChanged("/t88goto", caret: 8)
        await model.send()

        XCTAssertEqual(navigated, ["https://mm.example.com/perf/channels/town-square"])
    }

    /// `/leave` answers with a location as well; following it would bounce the reader back into the
    /// channel the command just removed them from.
    func testALeaveCommandDoesNotFollowItsGotoLocation() async {
        let service = FakeService()
        let model = self.model(service)
        var navigated: [String] = []
        model.onGotoLocation = { navigated.append($0) }
        service.executeResults = [.success(ComposerCommandResponse(
            responseType: "ephemeral", text: "left", gotoLocation: "https://mm.example.com/perf"))]

        model.textChanged("/leave", caret: 6)
        await model.send()

        XCTAssertTrue(navigated.isEmpty)
    }
}
