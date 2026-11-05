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

    private func makeWorker(registration: NotificationRegistration = .unknown,
                            delivery: NotificationDeliverySettings = .unknown) -> NotificationWorker {
        mock.deliverySettingsValue = delivery
        return NotificationWorker(scheduling: mock,
                                  preferences: AppPreferences(defaults: defaults),
                                  registration: FixedNotificationRegistrationReader(registration))
    }

    /// The smallest shell a tap can land in: one configured server, a mounted view store, and the native
    /// router driven by the documented `-surfaceMode` launch tier (the same flag T30's tests use).
    private func makeTapShell(mode: String = "shell=native") -> TapShell {
        let worker = makeWorker()
        let preferences = AppPreferences(defaults: defaults)
        let serverStore = ServerStore(preferences: preferences)
        let server = makeServer()
        _ = serverStore.add(server)
        let viewStore = ViewStore()
        let bridge = TapRecordingBridge()
        viewStore.ensureStore(for: server).bridge.delegate = bridge

        let navigation = NativeNavigation(resolver: SurfaceModeResolver(
            preferences: preferences, arguments: ["-surfaceMode", mode]))
        navigation.serverStore = serverStore
        navigation.viewStore = viewStore
        navigation.authGate = TapSignedInGate()

        worker.serverStore = serverStore
        worker.viewStore = viewStore
        worker.nativeNavigation = navigation
        worker.reactAppInitialized(serverID: server.id)

        return TapShell(worker: worker, serverStore: serverStore, viewStore: viewStore,
                        navigation: navigation, bridge: bridge, serverID: server.id)
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

    func testRouteIgnoresNonMentionUserInfo() async {
        let worker = makeWorker()
        let serverStore = ServerStore(preferences: AppPreferences(defaults: defaults))
        let server = makeServer()
        _ = serverStore.add(server)
        worker.serverStore = serverStore
        worker.viewStore = ViewStore()

        // A non-mention notification (e.g. a future download-complete) must not route.
        let outcome = await worker.route(userInfo: ["type": "download", "server_id": server.id.uuidString, "channel_id": "x"])
        XCTAssertEqual(outcome, .ignored)
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
    /// t_e4d5a252 added `registration=` beside `status=` (and `alerts=`, the style the system will
    /// draw), so the read-out can never say "allowed" while nothing can appear.
    func testDiagnosticsLineShape() async {
        mock.authorizationStatusValue = .denied
        let worker = makeWorker()
        await worker.reloadAuthorizationStatus()
        _ = await worker.prepareAuthorization() // denied installs do not re-ask

        XCTAssertEqual(worker.diagnosticsLine,
                       "notifications=status=denied registration=unknown alerts=unknown requested=false lastSchedule=none")
        XCTAssertEqual(worker.diagnosticsSnapshot.line, worker.diagnosticsLine)
    }

    // MARK: - t_e4d5a252: state-driven authorisation and the OS registration fact
    //
    // The reported failure was not a delivery bug: on a fresh install macOS has no notification
    // registration row for this bundle, so every add() is dropped, and nothing ever asked because
    // `prepareAuthorization` gated the ask on a *persisted* "already asked" flag. These tests pin the
    // new rules: the OS status is the only gate (T1), a denial is never re-prompted (T2), an
    // authorized install still schedules (T3), and the diagnostics/Settings read-out carries the
    // registration fact (T4).

    /// T1: `.notDetermined` asks **even when** the persisted flag says this install already asked —
    /// the flag may not survive the code identity it belonged to.
    func testNotDeterminedAsksEvenWhenThePersistedFlagSaysItAlreadyAsked() async {
        mock.authorizationStatusValue = .notDetermined
        let preferences = AppPreferences(defaults: defaults)
        preferences.set(true, forKey: AppPreferences.Keys.notificationPermissionRequested)
        let worker = NotificationWorker(scheduling: mock, preferences: preferences,
                                        registration: FixedNotificationRegistrationReader(.unknown))

        let status = await worker.prepareAuthorization()

        XCTAssertEqual(mock.requestAuthorizationCount, 1,
                       "a persisted permissionRequested=true must not swallow the ask")
        XCTAssertEqual(mock.requestedOptions, [.alert, .sound, .badge])
        XCTAssertEqual(status, .notDetermined)
    }

    /// T2: denied is never re-prompted, reads as denied, and points at System Settings.
    func testDeniedIsNeverRePromptedAndPointsAtSystemSettings() async {
        mock.authorizationStatusValue = .denied
        let worker = makeWorker()

        let first = await worker.prepareAuthorization()
        let second = await worker.prepareAuthorization()

        XCTAssertEqual(mock.requestAuthorizationCount, 0, "a denial cannot be re-asked")
        XCTAssertEqual(first, .denied)
        XCTAssertEqual(second, .denied)
        XCTAssertEqual(worker.authorizationStatus, .denied)
        XCTAssertEqual(worker.authorizationCopy, "Not allowed - open System Settings")
        XCTAssertEqual(worker.statusLabel, "Not allowed")
    }

    /// T3: authorized still schedules a mention — the T8 behaviour must not regress.
    func testAuthorizedMentionStillSchedules() async {
        mock.authorizationStatusValue = .authorized
        let worker = makeWorker(registration: .registered)
        let serverStore = ServerStore(preferences: AppPreferences(defaults: defaults))
        let server = makeServer()
        _ = serverStore.add(server)
        worker.serverStore = serverStore
        worker.isAppActive = { false }

        let outcome = await worker.presentMention(makeMention(), fromServerID: server.id)

        guard case .scheduled = outcome else { return XCTFail("expected scheduled, got \(outcome)") }
        XCTAssertEqual(mock.requestAuthorizationCount, 0)
        XCTAssertEqual(mock.added.count, 1)
        XCTAssertEqual(worker.lastScheduleOutcome, "scheduled")
    }

    /// T4: the diagnostics token carries `notRegistered` when the OS has no row for this bundle,
    /// even though the system says `.authorized`.
    func testDiagnosticsCarriesNotRegisteredWhenTheOSHasNoRow() async {
        mock.authorizationStatusValue = .authorized
        let worker = makeWorker(registration: .notRegistered)

        await worker.reloadAuthorizationStatus()

        XCTAssertEqual(worker.registrationState, .notRegistered)
        XCTAssertEqual(worker.diagnosticsLine,
                       "notifications=status=authorized registration=notRegistered alerts=unknown requested=false lastSchedule=none")
        XCTAssertEqual(worker.diagnosticsSnapshot.registration, "notRegistered")
        XCTAssertEqual(worker.diagnosticsSnapshot.line, worker.diagnosticsLine)
    }

    /// The other half of the same confusion (found while verifying T4): the OS **has** a row, the app
    /// is allowed, and the system's style for it is `none` — so every request is delivered to
    /// Notification Center and no banner is ever drawn. The read-out must say that, not "Allowed".
    func testDiagnosticsAndCopyNameTheSilentStyle() async {
        mock.authorizationStatusValue = .authorized
        let worker = makeWorker(registration: .registered,
                                delivery: NotificationDeliverySettings(alertStyle: "none"))

        await worker.reloadAuthorizationStatus()

        XCTAssertEqual(worker.diagnosticsLine,
                       "notifications=status=authorized registration=registered alerts=none requested=false lastSchedule=none")
        XCTAssertEqual(worker.statusLabel, "No banners")
        XCTAssertEqual(worker.authorizationCopy,
                       "Allowed, but notifications are set to none - no banner can appear")
        XCTAssertTrue(worker.needsSystemSettings, "the reader can only fix this in System Settings")
        XCTAssertTrue(worker.isAllowed, "the authorization itself is not the problem here")
    }

    /// A registered, allowed bundle whose style can be drawn is plain "Allowed" and needs no detour.
    func testBannerStyleKeepsThePlainAllowedReading() async {
        mock.authorizationStatusValue = .authorized
        let worker = makeWorker(registration: .registered,
                                delivery: NotificationDeliverySettings(alertStyle: "banner"))

        await worker.reloadAuthorizationStatus()

        XCTAssertEqual(worker.statusLabel, "Allowed")
        XCTAssertFalse(worker.needsSystemSettings)
        XCTAssertEqual(worker.diagnosticsSnapshot.alerts, "banner")
    }

    /// The Settings row must not read "Allowed" for an authorized bundle the OS cannot deliver into.
    func testAllowedCopyNamesTheMissingRegistration() async {
        mock.authorizationStatusValue = .authorized
        let worker = makeWorker(registration: .notRegistered)

        await worker.reloadAuthorizationStatus()

        XCTAssertEqual(worker.authorizationCopy, "Not registered with macOS - nothing can appear")
        XCTAssertEqual(worker.statusLabel, "Not registered")
        XCTAssertEqual(NotificationWorker.statusLabel(for: .authorized, registration: .registered), "Allowed")
        XCTAssertEqual(NotificationWorker.authorizationCopy(for: .authorized, registration: .registered),
                       "Allowed - notifications can appear")
        XCTAssertEqual(NotificationWorker.authorizationCopy(for: .notDetermined, registration: .notRegistered),
                       "Not allowed yet - the app has not been allowed to notify you",
                       "a fresh install has no row yet; the copy still has to ask, not accuse")
    }

    /// Item 2: launch asks on a fresh install **with a session**, and stays quiet without one.
    func testLaunchAsksWhenNotDeterminedAndASessionExists() async {
        mock.authorizationStatusValue = .notDetermined
        let worker = makeWorker()

        await worker.askOnLaunchIfNeeded(hasSession: true)

        XCTAssertEqual(mock.requestAuthorizationCount, 1)
        XCTAssertTrue(worker.hasRequestedAuthorization)
    }

    func testLaunchDoesNotAskWithoutASession() async {
        mock.authorizationStatusValue = .notDetermined
        let worker = makeWorker()

        await worker.askOnLaunchIfNeeded(hasSession: false)

        XCTAssertEqual(mock.requestAuthorizationCount, 0, "nothing to notify about before sign-in")
    }

    /// An install that already asked is never asked again (the persisted fact plus the status gate).
    func testLaunchDoesNotAskWhenTheOSHasAlreadyAnswered() async {
        mock.authorizationStatusValue = .authorized
        let worker = makeWorker(registration: .registered)
        _ = await worker.prepareAuthorization(registeringAuthorizedInstall: true) // e.g. Settings already did
        XCTAssertEqual(mock.requestAuthorizationCount, 1)

        await worker.askOnLaunchIfNeeded(hasSession: true)

        XCTAssertEqual(mock.requestAuthorizationCount, 1, "launch does not repeat an answered ask")
        XCTAssertEqual(worker.registrationState, .registered)
    }

    /// Measured on this card: macOS 26 answers `.authorized` for an app that was never asked, so an
    /// install can read `authorized` with `requested=false` forever. One silent registration call on
    /// launch makes the records agree; a second launch does not repeat it.
    func testLaunchRegistersOnceWhenTheOSSaysAuthorizedButNeverAsked() async {
        mock.authorizationStatusValue = .authorized
        let worker = makeWorker(registration: .registered)

        await worker.askOnLaunchIfNeeded(hasSession: true)

        XCTAssertEqual(mock.requestAuthorizationCount, 1)
        XCTAssertTrue(worker.hasRequestedAuthorization)

        await worker.askOnLaunchIfNeeded(hasSession: true)
        XCTAssertEqual(mock.requestAuthorizationCount, 1, "one registration call per process")
    }

    // MARK: - Tap fallbacks when the post or channel is gone (t_14c96dfd)
    //
    // Upstream: `openNotification` → `fetchNotificationData`, and `notificationError`
    // (`app/utils/notification/index.ts`): "Message not found" + one sentence, then `navigateToRoot()`.
    // These cases pin the behaviour *and* the cost rule the card states — a tap on a live conversation
    // makes no request at all — plus the three fallbacks the acceptance criterion names (post 404, not a
    // member, channel gone).

    /// The sentences, verbatim from the pinned client (`notificationError`).
    func testFallbackCopyIsThePinnedClientsVerbatim() {
        XCTAssertEqual(NotificationTapFailure.title, "Message not found")
        XCTAssertEqual(NotificationTapFailure.postNotFound.message, "The message has not been found.")
        XCTAssertEqual(NotificationTapFailure.notChannelMember.message,
                       "This message belongs to a channel where you are not a member.")
        XCTAssertEqual(NotificationTapFailure.channelGone.message,
                       "This message belongs to a channel where you are not a member.",
                       "upstream has one sentence for a channel: left, removed and archived all use it")
        XCTAssertEqual(NotificationTapFailure.notTeamMember.message,
                       "This message belongs to a team where you are not a member.")
        XCTAssertEqual(NotificationTapFailure.unreachable.message,
                       "The server is unreachable and it was not possible to retrieve the specific " +
                       "message information for the notification.")
        XCTAssertEqual(Set(NotificationTapFailure.allCases.map(\.diagnosticsToken)).count,
                       NotificationTapFailure.allCases.count,
                       "the log token is the case name, never the sentence")
    }

    /// The happy path: the loaded channel list knows the channel, so the tap routes and **nothing** is
    /// asked of the server.
    func testTapOnAKnownChannelRoutesWithNoRequest() async {
        let shell = makeTapShell()
        let resolver = ScriptedTapResolver(local: .member)
        shell.worker.tapResolver = resolver

        let outcome = await shell.worker.route(userInfo: shell.payload(channelID: "town-square"))

        XCTAssertEqual(outcome, .routed)
        XCTAssertEqual(resolver.remoteCalls, 0, "a live tap must cost no request")
        XCTAssertEqual(resolver.postCalls, 0)
        XCTAssertEqual(shell.navigation.location.channelID, "town-square")
        XCTAssertNil(shell.worker.tapFailure, "a tap that lands has no copy to show")
        XCTAssertTrue(shell.bridge.pushedPaths.isEmpty,
                      "the native shell must not also drive the SPA's history")
    }

    /// Not a member: the list cannot say (it hides nothing it has not loaded — and absence is not
    /// proof), the server says, the reader is told in upstream's words and left on the channel list.
    func testTapOnAChannelTheReaderLeftShowsTheSentenceAndLandsOnTheList() async {
        let shell = makeTapShell()
        let resolver = ScriptedTapResolver(local: .unknown, remote: .notMember)
        shell.worker.tapResolver = resolver

        let outcome = await shell.worker.route(userInfo: shell.payload(channelID: "left-behind"))

        XCTAssertEqual(outcome, .failed(.notChannelMember))
        XCTAssertEqual(resolver.remoteCalls, 1, "absence from the list is not proof; the server is asked")
        XCTAssertEqual(shell.worker.tapFailure?.message,
                       "This message belongs to a channel where you are not a member.")
        XCTAssertEqual(shell.worker.tapFailure?.rawValue, "notChannelMember")
        XCTAssertNil(shell.navigation.location.channelID, "the reader landed on the channel list")
        XCTAssertTrue(shell.navigation.path.isEmpty, "and nothing is pushed over it")
        XCTAssertTrue(shell.bridge.pushedPaths.isEmpty, "no channel path was pushed into the SPA")

        shell.worker.dismissTapFailure()
        XCTAssertNil(shell.worker.tapFailure, "the alert is dismissible")
    }

    /// Channel gone: the account's membership row outlived the channel (`GET /channels/{id}` → 404).
    /// The answer is upstream's channel sentence — not a blank pane.
    func testTapOnAChannelThatNoLongerExistsShowsTheSentenceAndLandsOnTheList() async {
        let shell = makeTapShell()
        let resolver = ScriptedTapResolver(local: .unknown, remote: .gone)
        shell.worker.tapResolver = resolver

        let outcome = await shell.worker.route(userInfo: shell.payload(channelID: "deleted-room"))

        XCTAssertEqual(outcome, .failed(.channelGone))
        XCTAssertEqual(resolver.remoteCalls, 1, "exactly one probe, and only because the list could not say")
        XCTAssertEqual(resolver.postCalls, 0, "a channel that is gone is not worth a post probe")
        XCTAssertEqual(shell.worker.tapFailure?.message,
                       "This message belongs to a channel where you are not a member.")
        XCTAssertNil(shell.navigation.location.channelID)
        XCTAssertTrue(shell.bridge.pushedPaths.isEmpty)
    }

    /// Post 404: a thread mention whose root was deleted between delivery and tap.
    func testTapOnADeletedThreadRootShowsThePostSentenceAndLandsOnTheList() async {
        let shell = makeTapShell()
        let resolver = ScriptedTapResolver(local: .member, post: .gone)
        shell.worker.tapResolver = resolver

        let outcome = await shell.worker.route(
            userInfo: shell.payload(channelID: "town-square", rootID: "deleted-root"))

        XCTAssertEqual(outcome, .failed(.postNotFound))
        XCTAssertEqual(resolver.remoteCalls, 0, "the channel was known; only the post was asked about")
        XCTAssertEqual(resolver.postCalls, 1)
        XCTAssertEqual(resolver.lastPostID, "deleted-root")
        XCTAssertEqual(shell.worker.tapFailure?.message, "The message has not been found.")
        XCTAssertNil(shell.navigation.location.channelID)
        XCTAssertTrue(shell.bridge.pushedPaths.isEmpty)
    }

    /// A post that resolves keeps the old behaviour — and carries the post id through the native funnel,
    /// which is what makes the pane open *at* the message (upstream's CRT tap).
    func testTapOnALiveThreadRootRoutesWithThePost() async {
        let shell = makeTapShell()
        let resolver = ScriptedTapResolver(local: .member, post: .exists)
        shell.worker.tapResolver = resolver

        let outcome = await shell.worker.route(
            userInfo: shell.payload(channelID: "town-square", rootID: "live-root"))

        XCTAssertEqual(outcome, .routed)
        XCTAssertEqual(resolver.postCalls, 1)
        XCTAssertEqual(shell.navigation.location.channelID, "town-square")
        XCTAssertEqual(shell.navigation.location.postID, "live-root")
        XCTAssertNil(shell.worker.tapFailure)
    }

    /// A plain channel mention that carries a post id is *not* probed: upstream only looks the post up
    /// for a thread notification, and the destination (the channel) does not need it to exist.
    func testPostProbeIsNotTakenForAChannelMention() async {
        let shell = makeTapShell()
        let resolver = ScriptedTapResolver(local: .member, post: .gone)
        shell.worker.tapResolver = resolver

        let outcome = await shell.worker.route(
            userInfo: shell.payload(channelID: "town-square", postID: "some-post"))

        XCTAssertEqual(outcome, .routed, "a post-only mention still lands in its channel")
        XCTAssertEqual(resolver.postCalls, 0)
    }

    /// Unreachable: upstream's Connection sentence, and the same landing.
    func testTapOnAnUnreachableServerShowsTheConnectionSentence() async {
        let shell = makeTapShell()
        let resolver = ScriptedTapResolver(local: .unknown, remote: .unreachable)
        shell.worker.tapResolver = resolver

        let outcome = await shell.worker.route(userInfo: shell.payload(channelID: "town-square"))

        XCTAssertEqual(outcome, .failed(.unreachable))
        XCTAssertEqual(shell.worker.tapFailure?.message,
                       "The server is unreachable and it was not possible to retrieve the specific " +
                       "message information for the notification.")
        XCTAssertNil(shell.navigation.location.channelID)
    }

    /// A probe that cannot answer must not invent a dead end: `.unknown` everywhere routes as the card
    /// found it.
    func testTapStillRoutesWhenTheResolverCannotSay() async {
        let shell = makeTapShell()
        let resolver = ScriptedTapResolver(local: .unknown, remote: .unknown)
        shell.worker.tapResolver = resolver

        let outcome = await shell.worker.route(userInfo: shell.payload(channelID: "cold-room"))

        XCTAssertEqual(outcome, .routed)
        XCTAssertEqual(resolver.remoteCalls, 1)
        XCTAssertEqual(shell.navigation.location.channelID, "cold-room")
        XCTAssertNil(shell.worker.tapFailure)
    }

    /// No resolver installed (a host that never opts in): the pre-card path, byte for byte.
    func testTapWithoutAResolverRoutesAsBefore() async {
        let shell = makeTapShell()

        let outcome = await shell.worker.route(userInfo: shell.payload(channelID: "town-square"))

        XCTAssertEqual(outcome, .routed)
        XCTAssertEqual(shell.navigation.location.channelID, "town-square")
        XCTAssertNil(shell.worker.tapFailure)
    }

    /// The webview path (Path A) has no native channel list: the fallback still lands somewhere honest —
    /// the SPA's server root — rather than pushing the channel that no longer resolves.
    func testFallbackOnTheWebviewPathSendsTheSPAToItsRoot() async {
        let shell = makeTapShell(mode: "shell=web")
        let resolver = ScriptedTapResolver(local: .unknown, remote: .notMember)
        shell.worker.tapResolver = resolver

        let outcome = await shell.worker.route(userInfo: shell.payload(channelID: "left-behind"))

        XCTAssertEqual(outcome, .failed(.notChannelMember))
        XCTAssertEqual(shell.bridge.pushedPaths, ["/"],
                       "the reader is sent to the channel list, not to the vanished channel")
        XCTAssertEqual(shell.worker.tapFailure?.message,
                       "This message belongs to a channel where you are not a member.")
    }

    /// A tap for a server this device does not have is not a "message not found": nothing is shown,
    /// because there is nothing to open and no list to land on.
    func testTapForAnUnconfiguredServerReportsNoServerWithoutCopy() async {
        let shell = makeTapShell()
        shell.worker.tapResolver = ScriptedTapResolver(local: .notMember)

        let outcome = await shell.worker.route(
            userInfo: shell.payload(serverID: UUID(), channelID: "town-square"))

        XCTAssertEqual(outcome, .noServer)
        XCTAssertNil(shell.worker.tapFailure)
    }

    /// A payload the shell cannot make sense of is ignored, not treated as a fallback.
    func testMalformedMentionPayloadIsIgnored() async {
        let shell = makeTapShell()
        shell.worker.tapResolver = ScriptedTapResolver(local: .notMember)

        let outcome = await shell.worker.route(userInfo: ["type": "mention", "server_id": "not-a-uuid",
                                                          "channel_id": "x"])
        XCTAssertEqual(outcome, .ignored)
        XCTAssertNil(shell.worker.tapFailure)
    }

    // MARK: - The session-backed resolver's status table
    //
    // The mapping is only honest if it is the server's own: every status below was measured on
    // Mattermost 9.11.19 by `scripts/t14c_notification_tap_probe.py`.

    func testMembershipProbeStatusTable() {
        XCTAssertEqual(SessionNotificationTapResolver.membershipFailure(MMError.notFound), .notMember)
        XCTAssertEqual(SessionNotificationTapResolver.membershipFailure(MMError.forbidden(message: nil)),
                       .notMember, "an ordinary account gets 403 where a system admin gets 404")
        XCTAssertEqual(SessionNotificationTapResolver.membershipFailure(MMError.unauthorized(message: nil)),
                       .sessionExpired)
        XCTAssertEqual(SessionNotificationTapResolver.membershipFailure(MMError.notSignedIn),
                       .sessionExpired, "no token is no session: the auth surface is the answer")
        XCTAssertEqual(SessionNotificationTapResolver.membershipFailure(MMError.offline), .unreachable)
        XCTAssertEqual(SessionNotificationTapResolver.membershipFailure(MMError.timeout), .unreachable)
        XCTAssertEqual(SessionNotificationTapResolver.membershipFailure(MMError.server(status: 500, message: nil)),
                       .unknown, "a server error is not the reader's answer; route as before")
    }

    func testMembershipProbeIsNotAMemberWhenTheServerForbids() async throws {
        let shell = try ScriptedTapShellResolver(status: 403, body: #"{"id":"api.context.permissions.app_error"}"#)
        XCTAssertNotNil(shell.resolver.clientProvider, "the scripted client must be installed")
        let state = await shell.resolver.remoteMembership(serverID: UUID(), channelID: "c1")
        XCTAssertEqual(state, .notMember)
        XCTAssertEqual(shell.transport.requestCount, 1, "one probe, no channel fetch after a refusal")
    }

    func testMembershipProbeIsNotAMemberWhenTheServerDoesNotKnowIt() async throws {
        let shell = try ScriptedTapShellResolver(status: 404,
                                                 body: #"{"id":"app.channel.get_member.missing.app_error"}"#)
        let state = await shell.resolver.remoteMembership(serverID: UUID(), channelID: "c1")
        XCTAssertEqual(state, .notMember)
    }

    /// An **archived** channel is still a destination: upstream navigates into it and the pane draws the
    /// composer's archived banner, so the tap must not be answered with "not a member".
    func testMembershipProbeRoutesAnArchivedChannel() async throws {
        let membership = #"{"channel_id":"c1","user_id":"u1"}"#
        let archived = #"{"id":"c1","name":"gone","display_name":"Gone","type":"O","team_id":"t1","delete_at":1793850354863}"#
        let shell = try ScriptedTapShellResolver(stubs: [(200, membership), (200, archived)])
        let state = await shell.resolver.remoteMembership(serverID: UUID(), channelID: "c1")
        XCTAssertEqual(state, .member, "archived is the pane's banner, not the tap's sentence")
        XCTAssertEqual(shell.transport.requestCount, 2, "membership, then the channel's existence")
    }

    /// The channel that answered its membership row but is not there any more: that is `gone`.
    func testMembershipProbeReportsGoneWhenTheChannelVanished() async throws {
        let membership = #"{"channel_id":"c1","user_id":"u1"}"#
        let shell = try ScriptedTapShellResolver(stubs: [
            (200, membership),
            (404, #"{"id":"app.channel.get.app_error","message":"Unable to find the existing channel."}"#),
        ])
        let state = await shell.resolver.remoteMembership(serverID: UUID(), channelID: "c1")
        XCTAssertEqual(state, .gone)
    }

    func testMembershipProbeReportsMemberForALiveChannel() async throws {
        let membership = #"{"channel_id":"c1","user_id":"u1"}"#
        let live = #"{"id":"c1","name":"general","display_name":"General","type":"O","team_id":"t1","delete_at":0}"#
        let shell = try ScriptedTapShellResolver(stubs: [(200, membership), (200, live)])
        let state = await shell.resolver.remoteMembership(serverID: UUID(), channelID: "c1")
        XCTAssertEqual(state, .member)
    }

    func testPostProbeStatusTable() async throws {
        let deleted = try ScriptedTapShellResolver(status: 404, body: #"{"id":"app.post.get.app_error"}"#)
        let deletedState = await deleted.resolver.postState(serverID: UUID(), postID: "p1")
        XCTAssertEqual(deletedState, .gone, "a soft-deleted post and an id that never existed answer alike")

        let live = #"{"id":"p1","create_at":1,"delete_at":0,"channel_id":"c1","user_id":"u1"}"#
        let present = try ScriptedTapShellResolver(status: 200, body: live)
        let presentState = await present.resolver.postState(serverID: UUID(), postID: "p1")
        XCTAssertEqual(presentState, .exists)

        let forbidden = try ScriptedTapShellResolver(status: 403, body: "{}")
        let forbiddenState = await forbidden.resolver.postState(serverID: UUID(), postID: "p1")
        XCTAssertEqual(forbiddenState, .notPermitted)
    }
}

/// Recording stand-in for `UNUserNotificationCenter`. Status + side effects are controllable so
/// every branch of the worker's permission/gating logic is exercised deterministically.
@MainActor
private final class MockScheduling: NotificationScheduling {
    var delegate: UNUserNotificationCenterDelegate?

    var authorizationStatusValue: UNAuthorizationStatus = .notDetermined
    var deliverySettingsValue: NotificationDeliverySettings = .unknown
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

    func deliverySettings() async -> NotificationDeliverySettings {
        deliverySettingsValue
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

// MARK: - Tap-fallback harness (t_14c96dfd)

/// Records SPA pushes; a native-mode shell should never use it.
@MainActor
private final class TapRecordingBridge: JsBridge {
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

@MainActor
private final class TapSignedInGate: NativeAuthGate {
    func authState(for server: ServerConfig) -> NativeAuthState { .signedIn }
}

/// A `NotificationTapResolving` that answers from a script and counts what it was asked.
@MainActor
private final class ScriptedTapResolver: NotificationTapResolving {
    var local: NotificationChannelMembership
    var remote: NotificationChannelMembership
    var post: NotificationPostState

    private(set) var remoteCalls = 0
    private(set) var postCalls = 0
    private(set) var lastPostID: String?

    init(local: NotificationChannelMembership = .unknown,
         remote: NotificationChannelMembership = .unknown,
         post: NotificationPostState = .unknown) {
        self.local = local
        self.remote = remote
        self.post = post
    }

    func localMembership(serverID: UUID, channelID: String,
                         teamID: String?) -> NotificationChannelMembership { local }

    func remoteMembership(serverID: UUID, channelID: String) async -> NotificationChannelMembership {
        remoteCalls += 1
        return remote
    }

    func postState(serverID: UUID, postID: String) async -> NotificationPostState {
        postCalls += 1
        lastPostID = postID
        return post
    }
}

/// The production resolver wired to a scripted transport, so the HTTP status → state table is
/// exercised end to end (request shape included) without a vault or a session.
@MainActor
private struct ScriptedTapShellResolver {
    let resolver: SessionNotificationTapResolver
    let transport: FakeAPITransport

    init(status: Int, body: String) throws {
        try self.init(stubs: [(status, body)])
    }

    init(stubs: [(Int, String)]) throws {
        let transport = FakeAPITransport(stubs: stubs.map { status, body in
            .ok(APIResponse(statusCode: status,
                            headers: ["Content-Type": "application/json"],
                            body: Data(body.utf8)))
        })
        let client = try APIClient(serverURL: URL(string: "https://mm.example")!,
                                   transport: transport,
                                   retryPolicy: .none,
                                   tokenProvider: { "test-token" })
        let resolver = SessionNotificationTapResolver()
        resolver.clientProvider = { _ in client }
        self.resolver = resolver
        self.transport = transport
    }
}

/// One server, a mounted server store, and the native router — the smallest shell a tap can land in.
@MainActor
private struct TapShell {
    let worker: NotificationWorker
    let serverStore: ServerStore
    let viewStore: ViewStore
    let navigation: NativeNavigation
    let bridge: TapRecordingBridge
    let serverID: UUID

    func payload(serverID: UUID? = nil, channelID: String,
                 postID: String? = nil, rootID: String? = nil) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            "type": "mention",
            "server_id": (serverID ?? self.serverID).uuidString,
            "channel_id": channelID,
            "team_id": "team42",
        ]
        if let postID { info["post_id"] = postID }
        if let rootID { info["root_id"] = rootID }
        return info
    }
}
