import XCTest
import UserNotifications
import UIKit
@testable import Mattermost

/// Unit tests for T14 `MentionPoller` (the `BGAppRefreshTask`-driven Option-A mention
/// poller) + `BackgroundRefreshScheduler` policy. The `NotificationScheduling` seam from T8
/// is reused so a real `UNNotificationRequest` is produced per new mention without touching
/// the real notification centre. All HTTP traffic runs through the repo's `MockURLProtocol`
/// stub (see ServerInfoTests.swift) — tests are fully offline except the opt-in live test
/// gated by `TEST_RUNNER_MM_LIVE_*`.
///
/// First-run contract (acceptance criterion, asserted explicitly): the first real fetch only
/// SEEDS the per-server high-water mark and notifies nothing older than the watermark — no
/// history replay.
@MainActor
final class MentionPollerTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var requestedPaths: [String] = []

    override func setUp() {
        super.setUp()
        suiteName = "MentionPollerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        requestedPaths = []
        MockURLProtocol.handler = nil
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        defaults.removePersistentDomain(forName: suiteName)
        suiteName = nil
        defaults = nil
        super.tearDown()
    }

    // MARK: Helpers

    private func makeServer(id: UUID = UUID(), name: String = "Example") -> ServerConfig {
        ServerConfig(id: id, name: name, url: URL(string: "https://chat.example.com")!)
    }

    private func makeServerStore(with server: ServerConfig) -> ServerStore {
        let store = ServerStore(preferences: AppPreferences(defaults: defaults))
        _ = store.add(server)
        return store
    }

    private func makePoller(server: ServerConfig,
                            token: String = "test-token",
                            session: URLSession? = nil,
                            clock: Int64 = 1_700_000_000_000,
                            deliver: ((MentionNotification, UUID) async -> NotificationWorker.PresentOutcome)? = nil) -> MentionPoller {
        let poller = MentionPoller(preferences: AppPreferences(defaults: defaults),
                                   session: session ?? mockSession(),
                                   deliverMention: deliver,
                                   nowMs: { clock })
        poller.tokenProvider = { _ in token }
        poller.serverStore = makeServerStore(with: server)
        return poller
    }

    private func seedState(_ state: ServerMentionState, for serverID: UUID) {
        defaults.set(try? JSONEncoder().encode(state), forKey: MentionPoller.stateKey(for: serverID))
    }

    /// Record which request paths the stub saw during a test.
    private func recordingHandler(_ body: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { [weak self] request in
            self?.requestedPaths.append(request.url?.path ?? "")
            return try body(request)
        }
    }

    /// A `posts?since=`-style PostList body for the given post dicts.
    private func postsBody(_ posts: [[String: Any]]) throws -> (HTTPURLResponse, Data) {
        var dict: [String: Any] = [:]
        for post in posts {
            guard let id = post["id"] as? String else { continue }
            dict[id] = post
        }
        return try jsonResponse(["order": Array(dict.keys), "posts": dict], status: 200)
    }

    private func post(id: String, ts: Int64, channel: String, user: String = "u1", message: String = "hello") -> [String: Any] {
        ["id": id, "create_at": ts, "user_id": user, "channel_id": channel, "message": message]
    }

    // MARK: - First run seeds; nothing older than the watermark is notified

    func testFirstRunSeedsWatermarkAndNotifiesNothing() async {
        let server = makeServer()
        let now: Int64 = 1_700_000_000_000

        MockURLProtocol.handler = recordingHandler { request in
            let path = request.url!.path
            if path.hasSuffix("/users/me/teams/unread") {
                return try self.jsonResponse([["team_id": "team1", "mention_count": 2, "msg_count": 9]], status: 200)
            }
            if path.contains("/channels/unread") {
                return try self.jsonResponse([["team_id": "team1", "channel_id": "chanA", "mention_count": 2, "msg_count": 8]], status: 200)
            }
            return try self.textResponse("unexpected \(request.url!)", status: 404)
        }
        defer { MockURLProtocol.handler = nil }

        let recorder = DeliveryRecorder()
        let poller = makePoller(server: server, clock: now, deliver: recorder.deliver)
        poller.authorizationGate = { true }

        let result = await poller.poll(server: server, token: "test-token")

        XCTAssertEqual(result.outcome, .seeded, "first run must only seed the watermark")
        XCTAssertTrue(recorder.mentions.isEmpty, "first run must never notify — history must not replay")
        let state = poller.loadState(for: server.id)
        XCTAssertEqual(state.watermarkTs, now, "watermark seeded to now")
        XCTAssertEqual(state.channelMentionCounts["chanA"], 2)
        XCTAssertFalse(requestedPaths.contains { $0.hasSuffix("/posts") },
                       "seeding must not fetch posts — nothing may be considered 'new' on first run")
        // Second run right after must be a normal poll (seeded path skipped once marked).
        let second = poller.loadState(for: server.id)
        XCTAssertTrue(second.isSeeded)
    }

    // MARK: - Exactly one UNNotificationRequest per new mention, with payload parity

    func testSecondRunSchedulesExactlyOneRequestPerNewMention() async {
        let server = makeServer()
        seedState(ServerMentionState(watermarkTs: 10_000, watermarkPostID: "p1",
                                     notifiedPostIDs: [], channelMentionCounts: ["chanA": 1]),
                  for: server.id)

        MockURLProtocol.handler = recordingHandler { request in
            let path = request.url!.path
            if path.hasSuffix("/users/me/teams/unread") {
                return try self.jsonResponse([["team_id": "team1", "mention_count": 2, "msg_count": 9]], status: 200)
            }
            if path.contains("/channels/unread") {
                return try self.jsonResponse([["team_id": "team1", "channel_id": "chanA", "mention_count": 2, "msg_count": 8]], status: 200)
            }
            if path.hasSuffix("/channels/chanA/posts") {
                // The OLD post at/under the watermark comes back too (server returns
                // everything since); the poller must filter it out.
                return try self.postsBody([
                    self.post(id: "p1", ts: 10_000, channel: "chanA"),
                    self.post(id: "p2", ts: 11_000, channel: "chanA", user: "u2", message: "hi alice"),
                ])
            }
            if path.hasSuffix("/channels/chanA") {
                return try self.jsonResponse(["id": "chanA", "name": "town-square", "display_name": "Town Square", "team_id": "team1", "type": "O"], status: 200)
            }
            if path.hasSuffix("/users/u2") {
                return try self.jsonResponse(["id": "u2", "username": "alice"], status: 200)
            }
            return try self.textResponse("unexpected \(request.url!)", status: 404)
        }
        defer { MockURLProtocol.handler = nil }

        let mock = RecordingScheduling()
        mock.authorizationStatusValue = .authorized
        let worker = NotificationWorker(scheduling: mock, preferences: AppPreferences(defaults: defaults))
        // Retain the store: NotificationWorker.serverStore is weak.
        let workerStore = makeServerStore(with: server)
        worker.serverStore = workerStore
        worker.isAppActive = { false }

        let poller = makePoller(server: server, deliver: { mention, sid in
            await worker.presentMention(mention, fromServerID: sid)
        })
        poller.authorizationGate = { true }

        let result = await poller.poll(server: server, token: "test-token")

        guard case .polled(let notified, let watermark) = result.outcome else {
            return XCTFail("expected polled, got \(result.outcome)")
        }
        XCTAssertEqual(notified, 1, "exactly one mention is new")
        XCTAssertEqual(watermark, 11_000)

        XCTAssertEqual(mock.added.count, 1, "exactly one UNNotificationRequest per new mention")
        let request = try! XCTUnwrap(mock.added.first)
        let content = request.content
        XCTAssertEqual(content.title, "Example: Town Square", "displayTitle(serverName:title:) parity")
        XCTAssertEqual(content.body, "@alice: hi alice", "webapp @username: message body")
        XCTAssertEqual(content.threadIdentifier, "chanA", "threading parity")
        XCTAssertEqual(content.userInfo["type"] as? String, "mention")
        XCTAssertEqual(content.userInfo["server_id"] as? String, server.id.uuidString)
        XCTAssertEqual(content.userInfo["channel_id"] as? String, "chanA")
        XCTAssertEqual(content.userInfo["team_id"] as? String, "team1")
        XCTAssertEqual(content.userInfo["url"] as? String, server.url.absoluteString)

        let state = poller.loadState(for: server.id)
        XCTAssertEqual(state.watermarkTs, 11_000)
        XCTAssertEqual(state.watermarkPostID, "p2")
        XCTAssertTrue(state.hasNotified("p2"))
    }

    func testTwoNewMentionsScheduleTwoRequests() async {
        let server = makeServer()
        seedState(ServerMentionState(watermarkTs: 10_000, watermarkPostID: "p1",
                                     notifiedPostIDs: [], channelMentionCounts: ["chanA": 1]),
                  for: server.id)

        MockURLProtocol.handler = recordingHandler { request in
            let path = request.url!.path
            if path.hasSuffix("/users/me/teams/unread") {
                return try self.jsonResponse([["team_id": "team1", "mention_count": 3, "msg_count": 9]], status: 200)
            }
            if path.contains("/channels/unread") {
                return try self.jsonResponse([["team_id": "team1", "channel_id": "chanA", "mention_count": 3, "msg_count": 8]], status: 200)
            }
            if path.hasSuffix("/channels/chanA/posts") {
                return try self.postsBody([self.post(id: "p2", ts: 11_000, channel: "chanA"),
                                           self.post(id: "p3", ts: 12_000, channel: "chanA")])
            }
            if path.hasSuffix("/channels/chanA") {
                return try self.jsonResponse(["id": "chanA", "name": "town-square", "display_name": "Town Square", "team_id": "team1"], status: 200)
            }
            if path.contains("/users/") {
                return try self.jsonResponse(["id": "u1", "username": "bob"], status: 200)
            }
            return try self.textResponse("unexpected \(request.url!)", status: 404)
        }
        defer { MockURLProtocol.handler = nil }

        let mock = RecordingScheduling()
        mock.authorizationStatusValue = .authorized
        let worker = NotificationWorker(scheduling: mock, preferences: AppPreferences(defaults: defaults))
        // Retain the store: NotificationWorker.serverStore is weak.
        let workerStore = makeServerStore(with: server)
        worker.serverStore = workerStore
        worker.isAppActive = { false }

        let poller = makePoller(server: server, deliver: { mention, sid in
            await worker.presentMention(mention, fromServerID: sid)
        })
        poller.authorizationGate = { true }

        let result = await poller.poll(server: server, token: "test-token")
        guard case .polled(let notified, _) = result.outcome else { return XCTFail("expected polled") }
        XCTAssertEqual(notified, 2)
        XCTAssertEqual(mock.added.count, 2, "one request per new mention")
        XCTAssertEqual(mock.added.map(\.content.body), ["@bob: hello", "@bob: hello"], "ascending delivery order")
    }

    // MARK: - No replay below/at the watermark; ring dedupe

    func testMentionsAtOrBelowWatermarkAreNeverNotified() async {
        let server = makeServer()
        seedState(ServerMentionState(watermarkTs: 10_000, watermarkPostID: "p9",
                                     notifiedPostIDs: [], channelMentionCounts: ["chanA": 0]),
                  for: server.id)

        MockURLProtocol.handler = recordingHandler { request in
            let path = request.url!.path
            if path.hasSuffix("/users/me/teams/unread") {
                return try self.jsonResponse([["team_id": "team1", "mention_count": 1, "msg_count": 1]], status: 200)
            }
            if path.contains("/channels/unread") {
                return try self.jsonResponse([["team_id": "team1", "channel_id": "chanA", "mention_count": 1, "msg_count": 1]], status: 200)
            }
            if path.hasSuffix("/channels/chanA/posts") {
                // A stubborn stub returns the pre-watermark post; it must be ignored.
                return try self.postsBody([self.post(id: "old", ts: 9_999, channel: "chanA")])
            }
            return try self.textResponse("unexpected \(request.url!)", status: 404)
        }
        defer { MockURLProtocol.handler = nil }

        let recorder = DeliveryRecorder()
        let poller = makePoller(server: server, deliver: recorder.deliver)
        poller.authorizationGate = { true }

        let result = await poller.poll(server: server, token: "test-token")
        guard case .polled(let notified, let watermark) = result.outcome else { return XCTFail("expected polled") }
        XCTAssertEqual(notified, 0)
        XCTAssertEqual(watermark, 10_000, "watermark must not move below/at its value")
        XCTAssertTrue(recorder.mentions.isEmpty)
    }

    func testAlreadyNotifiedMentionIsNotScheduledAgain() async {
        let server = makeServer()
        // "p2" was already delivered by an earlier poll (dedupe ring).
        seedState(ServerMentionState(watermarkTs: 10_000, watermarkPostID: "p1",
                                     notifiedPostIDs: ["p2"], channelMentionCounts: ["chanA": 0]),
                  for: server.id)

        MockURLProtocol.handler = recordingHandler { request in
            let path = request.url!.path
            if path.hasSuffix("/users/me/teams/unread") {
                return try self.jsonResponse([["team_id": "team1", "mention_count": 1, "msg_count": 1]], status: 200)
            }
            if path.contains("/channels/unread") {
                return try self.jsonResponse([["team_id": "team1", "channel_id": "chanA", "mention_count": 1, "msg_count": 1]], status: 200)
            }
            if path.hasSuffix("/channels/chanA/posts") {
                return try self.postsBody([self.post(id: "p2", ts: 11_000, channel: "chanA")])
            }
            return try self.textResponse("unexpected \(request.url!)", status: 404)
        }
        defer { MockURLProtocol.handler = nil }

        let recorder = DeliveryRecorder()
        let poller = makePoller(server: server, deliver: recorder.deliver)
        poller.authorizationGate = { true }

        let result = await poller.poll(server: server, token: "test-token")
        guard case .polled(let notified, let watermark) = result.outcome else { return XCTFail("expected polled") }
        XCTAssertEqual(notified, 0, "the ring keeps a previously notified mention silent")
        XCTAssertEqual(watermark, 11_000, "watermark still advances past the already-notified post")
        XCTAssertTrue(recorder.mentions.isEmpty)
    }

    // MARK: - Drill-down gating: only channels whose mention count increased are fetched

    func testUnchangedChannelMentionCountIsNotRefetched() async {
        let server = makeServer()
        seedState(ServerMentionState(watermarkTs: 10_000, watermarkPostID: "p1",
                                     notifiedPostIDs: [], channelMentionCounts: ["chanA": 1]),
                  for: server.id)

        MockURLProtocol.handler = recordingHandler { request in
            let path = request.url!.path
            if path.hasSuffix("/users/me/teams/unread") {
                return try self.jsonResponse([["team_id": "team1", "mention_count": 1, "msg_count": 1]], status: 200)
            }
            if path.contains("/channels/unread") {
                // Same count as the snapshot — the channel was already seen, nothing new.
                return try self.jsonResponse([["team_id": "team1", "channel_id": "chanA", "mention_count": 1, "msg_count": 1]], status: 200)
            }
            return try self.textResponse("unexpected \(request.url!)", status: 404)
        }
        defer { MockURLProtocol.handler = nil }

        let recorder = DeliveryRecorder()
        let poller = makePoller(server: server, deliver: recorder.deliver)
        poller.authorizationGate = { true }

        let result = await poller.poll(server: server, token: "test-token")
        guard case .polled(let notified, _) = result.outcome else { return XCTFail("expected polled") }
        XCTAssertEqual(notified, 0)
        XCTAssertFalse(requestedPaths.contains { $0.hasSuffix("/posts") },
                       "no mention-count increase -> no posts fetch -> nothing to notify")
        XCTAssertTrue(recorder.mentions.isEmpty)
    }

    // MARK: - Degradation: no token / no network / no authorization

    func testServerWithoutTokenIsSkipped() async {
        let server = makeServer()
        let poller = makePoller(server: server)
        poller.tokenProvider = { _ in nil }

        let results = await poller.pollAllServers()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.outcome, .skippedNoToken)
        XCTAssertTrue(requestedPaths.isEmpty, "no token -> no network traffic at all")
    }

    func testNoNetworkDegradesToLoggedNoOp() async {
        let server = makeServer()
        seedState(ServerMentionState(watermarkTs: 10_000, watermarkPostID: "p1",
                                     notifiedPostIDs: [], channelMentionCounts: ["chanA": 1]),
                  for: server.id)
        MockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer { MockURLProtocol.handler = nil }

        let recorder = DeliveryRecorder()
        let poller = makePoller(server: server, deliver: recorder.deliver)
        poller.authorizationGate = { true }

        let result = await poller.poll(server: server, token: "test-token")
        guard case .failed = result.outcome else { return XCTFail("expected failed, got \(result.outcome)") }
        XCTAssertTrue(recorder.mentions.isEmpty, "no network -> no notifications")
        XCTAssertEqual(poller.loadState(for: server.id).watermarkTs, 10_000, "state untouched on failure")
    }

    func testUnauthorizedNotificationsRecordButDoNotDeliver() async {
        let server = makeServer()
        seedState(ServerMentionState(watermarkTs: 10_000, watermarkPostID: "p1",
                                     notifiedPostIDs: [], channelMentionCounts: ["chanA": 0]),
                  for: server.id)
        MockURLProtocol.handler = recordingHandler { request in
            let path = request.url!.path
            if path.hasSuffix("/users/me/teams/unread") {
                return try self.jsonResponse([["team_id": "team1", "mention_count": 1, "msg_count": 1]], status: 200)
            }
            if path.contains("/channels/unread") {
                return try self.jsonResponse([["team_id": "team1", "channel_id": "chanA", "mention_count": 1, "msg_count": 1]], status: 200)
            }
            if path.hasSuffix("/channels/chanA/posts") {
                return try self.postsBody([self.post(id: "p2", ts: 11_000, channel: "chanA")])
            }
            return try self.textResponse("unexpected \(request.url!)", status: 404)
        }
        defer { MockURLProtocol.handler = nil }

        let recorder = DeliveryRecorder()
        let poller = makePoller(server: server, deliver: recorder.deliver)
        poller.authorizationGate = { false } // notifications not authorized

        let result = await poller.poll(server: server, token: "test-token")
        guard case .polled(let notified, _) = result.outcome else { return XCTFail("expected polled") }
        XCTAssertEqual(notified, 0)
        XCTAssertTrue(recorder.mentions.isEmpty, "nothing delivered when not authorized")
        let state = poller.loadState(for: server.id)
        XCTAssertTrue(state.hasNotified("p2"), "attempt is recorded so it never replays")
        XCTAssertEqual(state.watermarkTs, 11_000)
    }

    // MARK: - Badge refresh via SessionStore

    func testBadgeRefreshedFromTeamUnreadTotals() async {
        let server = makeServer()
        let badge = PollingRecordingBadge()
        let sessionStore = SessionStore(preferences: AppPreferences(defaults: defaults), badgeSetter: badge)

        MockURLProtocol.handler = recordingHandler { request in
            let path = request.url!.path
            if path.hasSuffix("/users/me/teams/unread") {
                return try self.jsonResponse([
                    ["team_id": "team1", "mention_count": 2, "msg_count": 5],
                    ["team_id": "team2", "mention_count": 1, "msg_count": 0],
                ], status: 200)
            }
            if path.contains("/channels/unread") {
                return try self.jsonResponse([], status: 200)
            }
            return try self.textResponse("unexpected \(request.url!)", status: 404)
        }
        defer { MockURLProtocol.handler = nil }

        let poller = makePoller(server: server)
        poller.authorizationGate = { true }
        poller.sessionStore = sessionStore

        _ = await poller.poll(server: server, token: "test-token")

        XCTAssertEqual(sessionStore.states[server.id]?.mentionCount, 3, "mentions summed across teams")
        XCTAssertEqual(sessionStore.states[server.id]?.isUnread, true)
        XCTAssertEqual(sessionStore.badgeNumber, 3, "app-icon badge refreshed from the same fetch")
    }

    // MARK: - Persistence across poller instances

    func testWatermarkPersistsAcrossPollerInstances() async {
        let server = makeServer()
        seedState(ServerMentionState(watermarkTs: 42_000, watermarkPostID: "p7",
                                     notifiedPostIDs: ["p7"], channelMentionCounts: ["chanA": 2]),
                  for: server.id)
        let poller = makePoller(server: server)
        let state = poller.loadState(for: server.id)
        XCTAssertEqual(state.watermarkTs, 42_000)
        XCTAssertEqual(state.watermarkPostID, "p7")
        XCTAssertTrue(state.hasNotified("p7"))
        XCTAssertEqual(state.channelMentionCounts["chanA"], 2)
    }

    // MARK: - Cancellation stops the in-flight fetch (task expiration path)

    func testTaskCancellationAbortsInFlightFetch() async {
        let server = makeServer()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HangingURLProtocol.self]
        let session = URLSession(configuration: config)

        let poller = makePoller(server: server, session: session)
        poller.authorizationGate = { true }

        let task = Task { await poller.poll(server: server, token: "test-token") }
        try? await Task.sleep(nanoseconds: 200_000_000)
        // What the BGTask expiration handler does: cancel the in-flight work.
        task.cancel()
        let result = await task.value
        guard case .failed = result.outcome else {
            return XCTFail("expected the cancelled fetch to return failed, got \(result.outcome)")
        }
    }

    // MARK: - Pure helpers

    func testMentionCompositionParity() {
        let post = MentionPost(id: "p1", createAt: 100, userId: "u1", channelId: "c1", message: "hi")
        let channel = MentionChannelInfo(id: "c1", name: "town-square", displayName: "Town Square", teamId: "t1")
        let user = MentionUserInfo(id: "u1", username: "alice")
        let server = makeServer()

        let mention = MentionPoller.makeMention(post: post, channel: channel, user: user, server: server)
        XCTAssertEqual(mention.title, "Town Square")
        XCTAssertEqual(mention.body, "@alice: hi")
        XCTAssertEqual(mention.channelID, "c1")
        XCTAssertEqual(mention.teamID, "t1")
        XCTAssertEqual(mention.serverURL, server.url.absoluteString)
        XCTAssertFalse(mention.silent)
        XCTAssertNil(mention.soundName)

        let fallback = MentionPoller.makeMention(post: post, channel: nil, user: nil, server: server)
        XCTAssertEqual(fallback.title, "Someone mentioned you", "desktop default title")
        XCTAssertEqual(fallback.body, "hi", "fail-soft to the bare message")
    }

    func testSchedulerPolicyMapsSystemStatus() {
        XCTAssertTrue(BackgroundRefreshScheduler.isAvailable(status: .available))
        XCTAssertFalse(BackgroundRefreshScheduler.isAvailable(status: .denied), "user-disabled -> no-op")
        XCTAssertFalse(BackgroundRefreshScheduler.isAvailable(status: .restricted), "MDM/parental -> no-op")
    }

    func testStateRingIsBounded() {
        var state = ServerMentionState()
        for i in 0..<(ServerMentionState.maxNotifiedRing + 50) {
            state.recordNotified("id-\(i)")
        }
        XCTAssertEqual(state.notifiedPostIDs.count, ServerMentionState.maxNotifiedRing)
        XCTAssertFalse(state.hasNotified("id-0"), "oldest entry trimmed")
        XCTAssertTrue(state.hasNotified("id-\(ServerMentionState.maxNotifiedRing + 49)"))
    }

    func testServerStateIsCodable() throws {
        let state = ServerMentionState(watermarkTs: 5, watermarkPostID: "a",
                                       notifiedPostIDs: ["a", "b"], channelMentionCounts: ["c": 1])
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ServerMentionState.self, from: data)
        XCTAssertEqual(decoded, state)
    }

    // MARK: - Opt-in live fetch (real network; TEST_RUNNER_MM_LIVE_* env-gated)

    /// Real mentions fetch against a real server, exactly like the acceptance criterion's
    /// "a real mentions fetch against a test server". Skipped unless the operator sets:
    ///   TEST_RUNNER_MM_LIVE_URL=https://chat.example.com
    ///   TEST_RUNNER_MM_LIVE_TOKEN=<personal access token or session token>
    /// See docs/t14-build-note.md.
    func testLiveMentionsFetch_optIn() async throws {
        let env = ProcessInfo.processInfo.environment
        let rawURL = env["TEST_RUNNER_MM_LIVE_URL"] ?? ""
        let token = env["TEST_RUNNER_MM_LIVE_TOKEN"] ?? ""
        try XCTSkipUnless(!rawURL.isEmpty && !token.isEmpty,
                          "Live mention poll: set TEST_RUNNER_MM_LIVE_URL + TEST_RUNNER_MM_LIVE_TOKEN to run")
        guard let url = URL(string: rawURL) else {
            return XCTFail("TEST_RUNNER_MM_LIVE_URL is not a valid URL")
        }
        let server = ServerConfig(name: "Live", url: url)
        let recorder = DeliveryRecorder()
        let poller = MentionPoller(preferences: AppPreferences(defaults: defaults),
                                   deliverMention: { mention, sid in
                                       recorder.mentions.append((mention, sid))
                                       return .scheduled(identifier: "live-\(mention.channelID)")
                                   })
        poller.tokenProvider = { _ in token }
        poller.authorizationGate = { true }

        let result = await poller.poll(server: server, token: token)
        switch result.outcome {
        case .seeded, .polled:
            break // real fetch succeeded
        case .skippedNoToken:
            XCTFail("live run skipped unexpectedly")
        case .failed(let message):
            XCTFail("live run failed: \(message)")
        }
    }
}

// MARK: - Test doubles

/// Records delivered mentions (and returns the `.scheduled` outcome the worker would).
private final class DeliveryRecorder {
    var mentions: [(mention: MentionNotification, serverID: UUID)] = []
    func deliver(_ mention: MentionNotification, serverID: UUID) async -> NotificationWorker.PresentOutcome {
        mentions.append((mention, serverID))
        return .scheduled(identifier: "test-\(mentions.count)")
    }
}

/// Stand-in for `UNUserNotificationCenter` (same seam as T8's MockScheduling, private to
/// this file so the two suites stay independent).
private final class RecordingScheduling: NotificationScheduling {
    var delegate: UNUserNotificationCenterDelegate?
    var authorizationStatusValue: UNAuthorizationStatus = .notDetermined
    private(set) var added: [UNNotificationRequest] = []

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        authorizationStatusValue == .authorized || authorizationStatusValue == .provisional
    }
    func authorizationStatus() async -> UNAuthorizationStatus { authorizationStatusValue }
    func add(_ request: UNNotificationRequest) async throws { added.append(request) }
}

private final class PollingRecordingBadge: BadgeSettable {
    private(set) var last: Int = -1
    func setBadge(_ count: Int) { last = count }
}

/// A URLProtocol whose `startLoading` never completes, so an in-flight request hangs until
/// the surrounding Task is cancelled (and the URLSession task gets torn down).
private final class HangingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { /* deliberately never finishes */ }
    override func stopLoading() { /* cancelled by the URLSession */ }
}
