import XCTest
import UserNotifications
import WebKit
@testable import Mattermost

/// Unit tests for T8 `NotificationWorker` (desktop `main/notifications`): permission-on-first-
/// mention, mention → UNNotificationRequest mapping (title/sound/userInfo/thread), the
/// foreground visible-server suppression (desktop `view_should_not_notify`), and tap routing to
/// the right server/channel (desktop NOTIFICATION_CLICKED). The real `UNUserNotificationCenter`
/// is replaced by a recording mock; `UNMutableNotificationContent` / `UNNotificationRequest` are
/// real types so the scheduled payloads are asserted directly.
@MainActor
final class NotificationWorkerTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var mock: MockScheduling!

    override func setUp() {
        super.setUp()
        suiteName = "NotificationWorkerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        mock = MockScheduling()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        suiteName = nil
        defaults = nil
        mock = nil
        super.tearDown()
    }

    private func makeWorker() -> NotificationWorker {
        NotificationWorker(scheduling: mock, preferences: AppPreferences(defaults: defaults))
    }

    private func makeServer(id: UUID = UUID(), name: String = "Example") -> ServerConfig {
        ServerConfig(id: id, name: name, url: URL(string: "https://example.mattermost.com")!)
    }

    private func makeMention(channelID: String = "ch1", teamID: String = "team1",
                             title: String = "You were mentioned", body: String = "@user hi",
                             silent: Bool = false, soundName: String? = nil) -> MentionNotification {
        MentionNotification(title: title, body: body, channelID: channelID, teamID: teamID,
                            serverURL: "https://example.mattermost.com", silent: silent, soundName: soundName)
    }

    /// Let a fire-and-forget `Task { await ... }` from a Coordinator finish on the main actor.
    private func drainMainActorQueue() async {
        for _ in 0..<200 {
            if mock.added.count > 0 { break }
            await Task.yield()
        }
    }

    // MARK: Sound mapping (desktop Mention.ts)

    func testMentionSoundMapping() {
        XCTAssertEqual(NotificationWorker.mentionSound(silent: true, soundName: nil), .none)
        XCTAssertEqual(NotificationWorker.mentionSound(silent: true, soundName: "Ding"), .none)
        XCTAssertEqual(NotificationWorker.mentionSound(silent: false, soundName: "None"), .none)
        XCTAssertEqual(NotificationWorker.mentionSound(silent: false, soundName: "  None  "), .none, "trimmed like the renderer compares")
        XCTAssertEqual(NotificationWorker.mentionSound(silent: false, soundName: nil), .systemDefault)
        XCTAssertEqual(NotificationWorker.mentionSound(silent: false, soundName: "Ding"), .systemDefault)
        XCTAssertEqual(NotificationWorker.mentionSound(silent: false, soundName: "Bing"), .systemDefault)
    }

    // MARK: Title composition (desktop `"${serverName}: ${title}"` + default title)

    func testDisplayTitleComposition() {
        XCTAssertEqual(NotificationWorker.displayTitle(serverName: "Example", title: "Hello"), "Example: Hello")
        XCTAssertEqual(NotificationWorker.displayTitle(serverName: "Example", title: "   "), "Example: Someone mentioned you")
        XCTAssertEqual(NotificationWorker.displayTitle(serverName: nil, title: "Hello"), "Hello")
        XCTAssertEqual(NotificationWorker.displayTitle(serverName: "", title: ""), "Someone mentioned you")
    }

    // MARK: Permission flow (task T8: request on first mention)

    func testFirstMentionRequestsAuthorizationAndSchedulesWhenGranted() async {
        // The user answers the first prompt with "allow" -> status flips to authorized.
        mock.onRequestAuthorization = { self.mock.authorizationStatusValue = .authorized }
        mock.authorizationStatusValue = .notDetermined

        let worker = makeWorker()
        let serverStore = ServerStore(preferences: AppPreferences(defaults: defaults))
        let server = makeServer()
        _ = serverStore.add(server)
        worker.serverStore = serverStore
        worker.isAppActive = { false }

        let outcome = await worker.presentMention(makeMention(), fromServerID: server.id)

        guard case .scheduled(let identifier)? = Optional(outcome) else {
            return XCTFail("expected scheduled, got \(outcome)")
        }
        XCTAssertFalse(identifier.isEmpty)
        XCTAssertEqual(mock.requestAuthorizationCount, 1, "permission asked exactly once")
        XCTAssertEqual(mock.requestedOptions, [.alert, .sound, .badge])
        XCTAssertEqual(mock.added.count, 1)
    }

    func testSubsequentMentionsDoNotReRequestAuthorization() async {
        mock.authorizationStatusValue = .authorized
        let worker = makeWorker()
        let serverStore = ServerStore(preferences: AppPreferences(defaults: defaults))
        let server = makeServer()
        _ = serverStore.add(server)
        worker.serverStore = serverStore
        worker.isAppActive = { false }

        _ = await worker.presentMention(makeMention(), fromServerID: server.id)
        _ = await worker.presentMention(makeMention(), fromServerID: server.id)

        XCTAssertEqual(mock.requestAuthorizationCount, 0, "already granted -> no re-request")
        XCTAssertEqual(mock.added.count, 2)
    }

    func testPermissionRequestedFlagPersistsAcrossWorkerInstances() async {
        mock.authorizationStatusValue = .notDetermined
        mock.onRequestAuthorization = { self.mock.authorizationStatusValue = .authorized }

        let serverStore = ServerStore(preferences: AppPreferences(defaults: defaults))
        let server = makeServer()
        _ = serverStore.add(server)

        let first = makeWorker()
        first.serverStore = serverStore
        first.isAppActive = { false }
        _ = await first.presentMention(makeMention(), fromServerID: server.id)
        XCTAssertEqual(mock.requestAuthorizationCount, 1)

        // A fresh worker instance (same install/UserDefaults) must not re-ask.
        let second = makeWorker()
        mock.authorizationStatusValue = .authorized
        second.serverStore = serverStore
        second.isAppActive = { false }
        _ = await second.presentMention(makeMention(), fromServerID: server.id)
        XCTAssertEqual(mock.requestAuthorizationCount, 1, "asked once per install, not again on later workers")
    }

    func testDeniedDoesNotSchedule() async {
        mock.authorizationStatusValue = .denied
        let worker = makeWorker()
        let serverStore = ServerStore(preferences: AppPreferences(defaults: defaults))
        let server = makeServer()
        _ = serverStore.add(server)
        worker.serverStore = serverStore
        worker.isAppActive = { false }

        let outcome = await worker.presentMention(makeMention(), fromServerID: server.id)
        XCTAssertEqual(outcome, .notSent(.authorizationDenied))
        XCTAssertTrue(mock.added.isEmpty)
    }

    func testNotDeterminedAfterFirstAskDoesNotSchedule() async {
        // The user has not answered yet (prompt still up on the first mention).
        mock.authorizationStatusValue = .notDetermined
        let worker = makeWorker()
        let serverStore = ServerStore(preferences: AppPreferences(defaults: defaults))
        let server = makeServer()
        _ = serverStore.add(server)
        worker.serverStore = serverStore
        worker.isAppActive = { false }

        let outcome = await worker.presentMention(makeMention(), fromServerID: server.id)
        XCTAssertEqual(outcome, .notSent(.authorizationNotDetermined))
        XCTAssertEqual(mock.requestAuthorizationCount, 1)
        XCTAssertTrue(mock.added.isEmpty, "nothing shows until the user answers the prompt")
    }

    func testMissingServerDoesNotSchedule() async {
        mock.authorizationStatusValue = .authorized
        let worker = makeWorker()
        worker.isAppActive = { false }
        let unknown = UUID()
        let outcome = await worker.presentMention(makeMention(), fromServerID: unknown)
        XCTAssertEqual(outcome, .notSent(.missingServer))
        XCTAssertTrue(mock.added.isEmpty)
    }

    // MARK: Visible-server suppression (desktop view_should_not_notify)

    func testForegroundVisibleServerIsSuppressed() async {
        mock.authorizationStatusValue = .authorized
        let worker = makeWorker()
        let serverStore = ServerStore(preferences: AppPreferences(defaults: defaults))
        let server = makeServer()
        _ = serverStore.add(server)
        worker.serverStore = serverStore
        let viewStore = ViewStore()
        viewStore.setPrimary(server.id)
        worker.viewStore = viewStore
        worker.isAppActive = { true }

        let outcome = await worker.presentMention(makeMention(), fromServerID: server.id)
        XCTAssertEqual(outcome, .notSent(.viewShouldNotNotify))
        XCTAssertTrue(mock.added.isEmpty)
    }

    func testBackgroundedPrimaryServerSchedules() async {
        mock.authorizationStatusValue = .authorized
        let worker = makeWorker()
        let serverStore = ServerStore(preferences: AppPreferences(defaults: defaults))
        let server = makeServer()
        _ = serverStore.add(server)
        worker.serverStore = serverStore
        let viewStore = ViewStore()
        viewStore.setPrimary(server.id)
        worker.viewStore = viewStore
        worker.isAppActive = { false }

        let outcome = await worker.presentMention(makeMention(), fromServerID: server.id)
        guard case .scheduled = outcome else { return XCTFail("expected scheduled, got \(outcome)") }
    }

    // MARK: Scheduled payload (desktop displayMention options + push-proxy userInfo parity)

    func testScheduledRequestCarriesDesktopPayload() async {
        mock.authorizationStatusValue = .authorized
        let worker = makeWorker()
        let serverStore = ServerStore(preferences: AppPreferences(defaults: defaults))
        let server = makeServer(name: "Acme")
        _ = serverStore.add(server)
        worker.serverStore = serverStore
        worker.isAppActive = { false }

        _ = await worker.presentMention(
            makeMention(channelID: "town-square", teamID: "team42", title: "Hey", body: "look here", soundName: "Ding"),
            fromServerID: server.id)

        let request = try! XCTUnwrap(mock.added.first)
        let content = request.content
        XCTAssertEqual(content.title, "Acme: Hey", "desktop `${serverName}: ${title}`")
        XCTAssertEqual(content.body, "look here")
        XCTAssertEqual(content.threadIdentifier, "town-square", "group notifications per channel")
        XCTAssertNotNil(content.sound, "named sound falls back to the system default")
        XCTAssertEqual(content.userInfo["type"] as? String, "mention")
        XCTAssertEqual(content.userInfo["server_id"] as? String, server.id.uuidString)
        XCTAssertEqual(content.userInfo["channel_id"] as? String, "town-square")
        XCTAssertEqual(content.userInfo["team_id"] as? String, "team42")
        XCTAssertEqual(content.userInfo["url"] as? String, "https://example.mattermost.com")
    }

    func testSilentMentionHasNoSound() async {
        mock.authorizationStatusValue = .authorized
        let worker = makeWorker()
        let serverStore = ServerStore(preferences: AppPreferences(defaults: defaults))
        let server = makeServer()
        _ = serverStore.add(server)
        worker.serverStore = serverStore
        worker.isAppActive = { false }

        _ = await worker.presentMention(makeMention(silent: true), fromServerID: server.id)
        let request = try! XCTUnwrap(mock.added.first)
        XCTAssertNil(request.content.sound, "silent mentions must not play a sound")
    }

    // MARK: Tap routing (desktop notification click -> NOTIFICATION_CLICKED)

    func testTapRoutesToServerAndChannelWhenSPAReady() async {
        let worker = makeWorker()
        let serverStore = ServerStore(preferences: AppPreferences(defaults: defaults))
        let server = makeServer(name: "Routed")
        _ = serverStore.add(server)
        worker.serverStore = serverStore
        let viewStore = ViewStore()
        worker.viewStore = viewStore

        // Mount the server's webview and attach a recording bridge delegate (as the SPA would).
        let bridge = RecordingJsBridge()
        let store = viewStore.ensureStore(for: server)
        store.bridge.delegate = bridge
        worker.reactAppInitialized(serverID: server.id) // SPA already up

        worker.routeToChannel(serverID: server.id, channelID: "channel-9", teamID: "team1")

        XCTAssertEqual(serverStore.activeServerID, server.id, "shell switches to the mention's server")
        XCTAssertEqual(viewStore.primaryServerID, server.id)
        XCTAssertEqual(bridge.pushedPaths, ["/channels/channel-9"])
    }

    func testTapQueuesPathUntilSPAReady() async {
        let worker = makeWorker()
        let serverStore = ServerStore(preferences: AppPreferences(defaults: defaults))
        let server = makeServer()
        _ = serverStore.add(server)
        worker.serverStore = serverStore
        let viewStore = ViewStore()
        worker.viewStore = viewStore
        let bridge = RecordingJsBridge()
        let store = viewStore.ensureStore(for: server)
        store.bridge.delegate = bridge

        // Cold start: SPA not initialized yet -> path queued, nothing pushed.
        worker.routeToChannel(serverID: server.id, channelID: "cold-room", teamID: "team1")
        XCTAssertTrue(bridge.pushedPaths.isEmpty, "cannot SPA-navigate before the app is ready")

        // The web app signals react-app-initialized -> queued channel push flushes.
        worker.reactAppInitialized(serverID: server.id)
        XCTAssertEqual(bridge.pushedPaths, ["/channels/cold-room"])
    }

    func testRouteIgnoresNonMentionUserInfo() {
        let worker = makeWorker()
        let serverStore = ServerStore(preferences: AppPreferences(defaults: defaults))
        let server = makeServer()
        _ = serverStore.add(server)
        worker.serverStore = serverStore
        worker.viewStore = ViewStore()

        // A non-mention notification (e.g. a future download-complete) must not route.
        worker.route(userInfo: ["type": "download", "server_id": server.id.uuidString, "channel_id": "x"])
        XCTAssertNotEqual(serverStore.activeServerID, server.id, "only mention taps switch servers")
    }

    // MARK: Bridge -> Coordinator -> worker/store integration

    func testCoordinatorWiresMentionEventsIntoWorker() async {
        mock.authorizationStatusValue = .authorized
        let worker = makeWorker()
        let sessionStore = SessionStore(preferences: AppPreferences(defaults: defaults), badgeSetter: RecordingBadge())
        let serverStore = ServerStore(preferences: AppPreferences(defaults: defaults))
        let server = makeServer()
        _ = serverStore.add(server)
        worker.serverStore = serverStore
        worker.isAppActive = { false }

        let store = WebViewStore()
        let coordinator = WebViewContainer.Coordinator(
            store: store, serverID: server.id, serverURL: server.url,
            sessionStore: sessionStore, notificationWorker: worker)

        coordinator.handleNotifyMention(makeMention(channelID: "bridge-ch", title: "BridgeHey", body: "from bridge"))
        await drainMainActorQueue()

        XCTAssertEqual(mock.added.count, 1)
        XCTAssertEqual(mock.added.first?.content.title, "Example: BridgeHey")
    }

    func testCoordinatorWiresUnreadsAndExpiredIntoSessionStore() {
        let worker = makeWorker()
        let sessionStore = SessionStore(preferences: AppPreferences(defaults: defaults), badgeSetter: RecordingBadge())
        let server = makeServer()
        let store = WebViewStore()
        let coordinator = WebViewContainer.Coordinator(
            store: store, serverID: server.id, serverURL: server.url,
            sessionStore: sessionStore, notificationWorker: worker)

        coordinator.handleUnreadsAndMentions(true, mentionCount: 4)
        coordinator.handleSessionExpired(true)

        XCTAssertEqual(sessionStore.states[server.id]?.mentionCount, 4)
        XCTAssertEqual(sessionStore.states[server.id]?.isUnread, true)
        XCTAssertEqual(sessionStore.states[server.id]?.isExpired, true)
        XCTAssertEqual(sessionStore.badgeNumber, 4, "mentions drive the badge")
    }

    // MARK: - Settings authorisation surface (this card)
    //
    // The reported failure: nothing ever asked for permission, so the install stayed
    // `.notDetermined` for ever and Settings said nothing. These tests pin the user-initiated path,
    // the plain-words copy for every answer, the test-banner request shape, and that the T8
    // first-mention request still works (no regression).

    /// `prepareAuthorization()` asks the OS at most once, records that it asked, and keeps saying so
    /// on later calls — the Settings button can therefore be tapped repeatedly without a second prompt.
    func testPrepareAuthorizationRequestsExactlyOnceAcrossRepeatedCalls() async {
        mock.authorizationStatusValue = .notDetermined
        let worker = makeWorker()

        _ = await worker.prepareAuthorization()
        _ = await worker.prepareAuthorization()
        _ = await worker.prepareAuthorization()

        XCTAssertEqual(mock.requestAuthorizationCount, 1, "the system prompt is shown once per install")
        XCTAssertEqual(mock.requestedOptions, [.alert, .sound, .badge])
        XCTAssertTrue(worker.hasRequestedAuthorization, "the install records that it asked")
        let stored = defaults.data(forKey: AppPreferences.Keys.notificationPermissionRequested)
        XCTAssertEqual(stored, try? JSONEncoder().encode(true),
                       "the preference is persisted, not only in memory")
    }

    /// A `.denied` install must read as denied, not as silence.
    func testDeniedStatusIsSurfacedAsTheDeniedCopy() async {
        mock.authorizationStatusValue = .denied
        let worker = makeWorker()

        await worker.reloadAuthorizationStatus()

        XCTAssertEqual(worker.authorizationStatus, .denied)
        XCTAssertEqual(worker.authorizationCopy, "Not allowed - open System Settings")
        XCTAssertEqual(NotificationWorker.authorizationCopy(for: .denied),
                       "Not allowed - open System Settings")
    }

    /// `.notDetermined` is the state the card was filed for: the row has to say the app was never
    /// allowed, so an install that has never been asked no longer looks like a silent "off".
    func testNotDeterminedCopySaysTheAppHasNotBeenAllowedYet() async {
        mock.authorizationStatusValue = .notDetermined
        let worker = makeWorker()

        await worker.reloadAuthorizationStatus()

        XCTAssertEqual(worker.authorizationStatus, .notDetermined)
        XCTAssertTrue(worker.authorizationCopy.contains("not been allowed"),
                      "got: \(worker.authorizationCopy)")
        XCTAssertNotEqual(worker.authorizationCopy, NotificationWorker.authorizationCopy(for: .denied),
                          "not-determined and denied are different answers")
    }

    /// Launch reads the status once, so the row is truthful before the reader taps anything.
    func testAuthorizationStatusIsReadOnLaunch() async {
        mock.authorizationStatusValue = .denied
        let worker = makeWorker()

        var attempts = 0
        while worker.authorizationStatus == .notDetermined && attempts < 200 {
            await Task.yield()
            attempts += 1
        }

        XCTAssertEqual(worker.authorizationStatus, .denied, "the launch read surfaces the OS answer")
        XCTAssertEqual(worker.authorizationCopy, "Not allowed - open System Settings")
    }

    /// The test button schedules exactly one banner, through the mention path's request shape.
    func testTestNotificationSchedulesOneRequestWithTheMentionIdentifierShape() async {
        mock.authorizationStatusValue = .authorized
        let worker = makeWorker()
        let serverStore = ServerStore(preferences: AppPreferences(defaults: defaults))
        let server = makeServer(name: "Acme")
        _ = serverStore.add(server)
        worker.serverStore = serverStore

        let outcome = await worker.sendTestNotification()

        guard case .scheduled(let identifier) = outcome else {
            return XCTFail("expected scheduled, got \(outcome)")
        }
        XCTAssertEqual(mock.added.count, 1, "exactly one request")

        let parts = identifier.components(separatedBy: ".")
        XCTAssertEqual(parts.count, 4, "identifier shape is mention.<server>.<channel>.<request>: \(identifier)")
        XCTAssertEqual(parts[0], "mention")
        XCTAssertEqual(UUID(uuidString: parts[1])?.uuidString, server.id.uuidString,
                       "the test banner is attributed to a configured server")
        XCTAssertEqual(parts[2], "test-notification")
        XCTAssertNotNil(UUID(uuidString: parts[3]), "the request uuid is last")

        let request = try! XCTUnwrap(mock.added.first)
        XCTAssertEqual(request.content.title, "Acme: Test notification", "same title composition as a mention")
        XCTAssertEqual(request.content.threadIdentifier, "test-notification")
        XCTAssertEqual(request.content.userInfo["type"] as? String, "test",
                       "a test tap must not navigate: only `mention` routes")
        XCTAssertNotNil(request.content.sound)
        XCTAssertEqual(worker.lastScheduleOutcome, "scheduled")
    }

    /// The button must not lie when the OS refuses: nothing is scheduled, and the reason is recorded.
    func testTestNotificationDoesNotScheduleWhenDenied() async {
        mock.authorizationStatusValue = .denied
        let worker = makeWorker()

        let outcome = await worker.sendTestNotification()

        XCTAssertEqual(outcome, .notSent(.authorizationDenied))
        XCTAssertTrue(mock.added.isEmpty)
        XCTAssertEqual(worker.lastScheduleOutcome, "denied")
    }

    /// The T8 first-mention behaviour must not regress: a mention while `.notDetermined` asks, and
    /// once the answer is `authorized` the next mention schedules exactly one banner.
    func testMentionWhileNotDeterminedAsksThenSchedulesOnceAuthorized() async {
        mock.authorizationStatusValue = .notDetermined
        let worker = makeWorker()
        let serverStore = ServerStore(preferences: AppPreferences(defaults: defaults))
        let server = makeServer()
        _ = serverStore.add(server)
        worker.serverStore = serverStore
        worker.isAppActive = { false }

        let first = await worker.presentMention(makeMention(), fromServerID: server.id)
        XCTAssertEqual(first, .notSent(.authorizationNotDetermined))
        XCTAssertEqual(mock.requestAuthorizationCount, 1, "the mention still asks exactly once")
        XCTAssertTrue(mock.added.isEmpty)

        // The reader answered the prompt.
        mock.authorizationStatusValue = .authorized
        let second = await worker.presentMention(makeMention(), fromServerID: server.id)
        guard case .scheduled = second else { return XCTFail("expected scheduled, got \(second)") }
        XCTAssertEqual(mock.added.count, 1, "one banner once authorised")
        XCTAssertEqual(mock.requestAuthorizationCount, 1, "authorised -> no second request")
    }

    /// Card item 4: one line that answers "why do I get no notifications?" from a log or report.
    func testDiagnosticsLineShape() async {
        mock.authorizationStatusValue = .denied
        let worker = makeWorker()
        await worker.reloadAuthorizationStatus()
        _ = await worker.prepareAuthorization() // denied installs do not re-ask

        XCTAssertEqual(worker.diagnosticsLine,
                       "notifications=status=denied requested=false lastSchedule=none")
        XCTAssertEqual(worker.diagnosticsSnapshot.line, worker.diagnosticsLine)
    }
}

/// Recording stand-in for `UNUserNotificationCenter`. Status + side effects are controllable so
/// every branch of the worker's permission/gating logic is exercised deterministically.
@MainActor
private final class MockScheduling: NotificationScheduling {
    var delegate: UNUserNotificationCenterDelegate?

    var authorizationStatusValue: UNAuthorizationStatus = .notDetermined
    var onRequestAuthorization: (() -> Void)?

    private(set) var requestAuthorizationCount = 0
    private(set) var requestedOptions: UNAuthorizationOptions?
    private(set) var added: [UNNotificationRequest] = []

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestAuthorizationCount += 1
        requestedOptions = options
        onRequestAuthorization?()
        return authorizationStatusValue == .authorized || authorizationStatusValue == .provisional
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        authorizationStatusValue
    }

    func add(_ request: UNNotificationRequest) async throws {
        added.append(request)
    }
}

/// Records SPA-navigation pushes (JsBridge surface exercised by tap routing).
@MainActor
private final class RecordingJsBridge: JsBridge {
    weak var webView: WKWebView?
    var pushedPaths: [String] = []

    func handleNotifyMention(_ payload: MentionNotification) {}
    func handleUnreadsAndMentions(_ isUnread: Bool, mentionCount: Int) {}
    func handleSessionExpired(_ isExpired: Bool) {}
    func handleReactAppInitialized() {}
    func handleRequestBrowserHistoryStatus(_ completion: @escaping (BrowserHistoryStatus) -> Void) {
        completion(BrowserHistoryStatus(canGoBack: false, canGoForward: false))
    }
    func pushBrowserHistory(path: String) { pushedPaths.append(path) }
    func navigateHistory(byOffset offset: Int) {}
}
