import XCTest
import UserNotifications
@testable import Mattermost

/// The **shipped** notification path (t_ba355551), end to end with the real `NotificationWorker`, the
/// real `NotificationInputRouting`, `SessionStore` and `MentionLedger` — only the server is faked.
///
/// The bug this file pins: a Release build used to force `NotificationInputMode.bridge` as a
/// process-wide constant. On the native workspace no web pane is mounted, so the page never reported
/// `notify_mention`, the socket refused every `posted` frame because the constant said `.bridge`, and
/// the T14 poller does not register on Catalyst. Three inputs, all silent: the Settings test button
/// worked and a real message produced nothing.
///
/// Every test here drives the **derived** answer — no `setOverride`, no launch flag — because that is
/// what a shipped binary runs. The old suites injected the mode, so they could be green while the
/// shipped default delivered nothing; that is exactly what these cases would have caught:
///
///   1. native pane, DM with no @mention from another account → one scheduled request, banner + sound,
///      the feed records `delivered`, and `NotificationInput` names the socket in the log;
///   2. native pane, channel post that does not name the reader → nothing scheduled;
///   3. web pane mounted → the socket stays silent and the page delivers exactly one banner;
///   4. a muted channel still notifies a real mention; a DM with `desktop: none` does not;
///   5. the reader's own post → nothing;
///   6. the conversation on screen → suppressed, and the ledger still handles it.
///
/// Adversarial addenda: both inputs live for one server still produce ONE banner (the reason the gate
/// exists), and a Release-semantics routing refuses to be forced.
@MainActor
final class T43ShippedDefaultTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var server: ServerConfig!
    private var mock: T43ShippedRecordingScheduling!
    private var worker: NotificationWorker!
    private var badge: T43ShippedRecordingBadge!
    private var sessionStore: SessionStore!
    private var serverStore: ServerStore!
    private var viewStore: ViewStore!
    private var routing: NotificationInputRouting!
    private var ledger: MentionLedger!
    private var feed: NativeNotificationFeed!
    private var service: T43ShippedFakeService!
    private var logs: [String] = []

    override func setUp() {
        super.setUp()
        suiteName = "T43ShippedDefaultTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let preferences = AppPreferences(defaults: defaults)
        server = ServerConfig(name: "Local", url: URL(string: "http://127.0.0.1:8065")!)
        serverStore = ServerStore(preferences: preferences)
        _ = serverStore.add(server)
        serverStore.switchTo(id: server.id)
        viewStore = ViewStore()
        viewStore.setPrimary(server.id)

        mock = T43ShippedRecordingScheduling()
        worker = NotificationWorker(scheduling: mock, preferences: preferences)
        worker.serverStore = serverStore
        worker.viewStore = viewStore
        worker.isAppActive = { false }

        badge = T43ShippedRecordingBadge()
        sessionStore = SessionStore(preferences: preferences, badgeSetter: badge)

        // **No override.** This is the shipped resolution: derive the input from the mounted pane.
        routing = NotificationInputRouting()
        ledger = MentionLedger(preferences: preferences)
        service = T43ShippedFakeService()
        feed = NativeNotificationFeed(routing: routing, ledger: ledger)
        feed.bind(serverStore: serverStore, sessionStore: sessionStore, viewStore: viewStore)
        feed.serviceFactory = { [service] _ in service! }
        feed.deliverMention = { [worker] mention, serverID in
            await worker!.presentMention(mention, fromServerID: serverID)
        }
        feed.badgeRefreshDelay = 0
        feed.now = { Date(timeIntervalSince1970: 1_700_000_000) }

        logs = []
        #if DEBUG
        Logger.testSink = { [weak self] line in self?.logs.append(line) }
        #endif
    }

    override func tearDown() {
        #if DEBUG
        Logger.testSink = nil
        #endif
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        server = nil
        mock = nil
        worker = nil
        badge = nil
        sessionStore = nil
        serverStore = nil
        viewStore = nil
        routing = nil
        ledger = nil
        feed = nil
        service = nil
        logs = []
        super.tearDown()
    }

    // MARK: - Fixtures

    private func post(id: String = "post1", message: String = "are you around?",
                      userID: String = "buddy", channelID: String = "dm1",
                      type: String = "") -> MMPost {
        MMPost(id: id, createAt: 1_700_000_000_000, deleteAt: 0, userId: userID,
               channelId: channelID, message: message, type: type)
    }

    /// A direct conversation: `type == "D"` is what makes an unmoted message notify, which is the
    /// owner's reported case ("a real message (DM, no @mention)").
    private func directChannel() {
        service.channelResult = .success(
            MMChannel(id: "dm1", name: "buddy--perfprobe", displayName: "Direct message", type: "D",
                      teamId: "team1"))
        service.membership = MMChannelMember(
            channelId: "dm1", userId: "me",
            notifyProps: .object(["desktop": .string("default"),
                                  "ignore_channel_mentions": .string("default"),
                                  "mark_unread": .string("all")]))
    }

    private func publicChannel(displayName: String = "T43 notify") {
        service.channelResult = .success(
            MMChannel(id: "ch1", name: "t43-notify", displayName: displayName, type: "O",
                      teamId: "team1"))
        service.membership = MMChannelMember(
            channelId: "ch1", userId: "me",
            notifyProps: .object(["desktop": .string("default"),
                                  "ignore_channel_mentions": .string("default"),
                                  "mark_unread": .string("all")]))
    }

    private func settle() async {
        await feed.flushBadgeRefresh(for: server.id)
        for _ in 0..<50 { await Task.yield() }
    }

    private func assertOneDelivered(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(mock.added.count, 1, "exactly one banner", file: file, line: line)
        XCTAssertEqual(feed.lastRecord?.outcome, "delivered",
                       "the read-out must say it was delivered", file: file, line: line)
        XCTAssertEqual(feed.lastRecord?.delivered, true, file: file, line: line)
        XCTAssertEqual(feed.lastRecord?.surface, "system notification",
                       "no banner slot in this host: the system notification is the one presentation",
                       file: file, line: line)
    }

    // MARK: - 1. The owner's case: a native pane, a DM, no @mention

    func testANativePaneDeliversADirectMessageThatNamesNobody() async {
        directChannel()
        await feed.handle(.posted(post()), server: server)
        await settle()

        assertOneDelivered()
        XCTAssertEqual(mock.added.first?.content.title, "Local: Direct message")
        XCTAssertEqual(mock.added.first?.content.body, "@t43buddy: are you around?")
        XCTAssertNotNil(mock.added.first?.content.sound,
                        "a banner with sound: the account's desktop_sound is true and nobody muted it")

        XCTAssertEqual(routing.socketMentions, 1, "one mention, counted once")
        XCTAssertEqual(routing.socketDelivered, 1)
        XCTAssertEqual(routing.socketDropped, 0)
        XCTAssertEqual(routing.webPaneCount, 0, "this is a native pane: no web view is mounted")
        XCTAssertEqual(routing.liveModeLabel, NotificationInputMode.socket.label,
                       "the Settings read-out must name the live path: Native socket")
        XCTAssertTrue(ledger.hasHandled("post1", for: server.id),
                      "the delivering input writes the ring, so the T14 poll cannot repeat it")

        #if DEBUG
        XCTAssertTrue(logs.contains { $0.contains("NotificationInput") && $0.contains("Native socket") },
                      "NotificationInput must log the socket mode line — the diagnostics pull had zero "
                      + "NotificationInput lines on the installed 0.1.7 build:\n\(logs.joined(separator: "\n"))")
        #endif
    }

    // MARK: - 2. A channel post that does not name the reader is not a notification

    func testANativePaneIgnoresAChannelPostThatDoesNotNameTheReader() async {
        publicChannel()
        await feed.handle(.posted(post(message: "nothing to see here", channelID: "ch1")), server: server)
        await settle()

        XCTAssertEqual(mock.added.count, 0)
        XCTAssertEqual(routing.socketMentions, 0)
        XCTAssertEqual(routing.socketDelivered, 0)
        XCTAssertFalse(ledger.hasHandled("post1", for: server.id),
                       "\"not a mention\" is not a delivery decision: the post stays pollable")
    }

    // MARK: - 3. A web pane: the socket goes silent and the page delivers once

    func testAWebPaneMakesTheSocketSilentAndThePageDeliversOnce() async {
        publicChannel()
        let store = WebViewStore()
        let coordinator = WebViewContainer.Coordinator(
            store: store, serverID: server.id, serverURL: server.url,
            sessionStore: sessionStore, notificationWorker: worker)
        coordinator.mentionInput = routing
        // Exactly what `makeUIView` reports when the web app's pane mounts.
        routing.paneKindChanged(serverID: server.id, isWeb: true)
        routing.socketStateChanged(serverID: server.id, live: true)
        XCTAssertEqual(routing.liveModeLabel, NotificationInputMode.bridge.label,
                       "a mounted web pane is the page's server: the read-out says Web view bridge")

        await feed.handle(.posted(post(message: "@perfprobe look", channelID: "ch1")), server: server)
        await settle()
        XCTAssertEqual(mock.added.count, 0, "the page is the input while it draws the pane")
        XCTAssertEqual(routing.socketDelivered, 0)
        XCTAssertFalse(ledger.hasHandled("post1", for: server.id),
                       "a silenced socket must leave the post pollable (T43-R F1)")

        let frame = MentionNotification(title: "T43 notify", body: "@t43buddy said hi",
                                        channelID: "ch1", teamID: "team1",
                                        serverURL: server.url.absoluteString)
        coordinator.handleNotifyMention(frame)
        await settle()
        XCTAssertEqual(mock.added.count, 1, "the page's report is the one banner")
        XCTAssertEqual(routing.bridgeAccepted, 1)
        XCTAssertEqual(routing.bridgeRefused, 0, "and it is never refused while it is the input")
    }

    // MARK: - 4. The reader's own configuration still decides

    func testAMutedChannelStillNotifiesARealMention() async {
        publicChannel()
        service.membership = MMChannelMember(
            channelId: "ch1", userId: "me",
            notifyProps: .object(["desktop": .string("default"),
                                  "ignore_channel_mentions": .string("default"),
                                  "mark_unread": .string("mention")]))
        await feed.handle(.posted(post(message: "@perfprobe hi", channelID: "ch1")), server: server)
        await settle()

        assertOneDelivered()
        XCTAssertEqual(mock.added.first?.content.title, "Local: T43 notify")
        XCTAssertEqual(mock.added.first?.content.body, "@t43buddy: @perfprobe hi")
    }

    func testADirectMessageWithNotificationsOffDoesNotNotify() async {
        directChannel()
        service.profileResult = .success(
            ActivityProfile(id: "me", username: "perfprobe", firstName: "Percy", lastName: "Probe",
                            notifyProps: .object(["desktop": .string("none"),
                                                  "desktop_sound": .string("true"),
                                                  "channel": .string("true"),
                                                  "mention_keys": .string(""),
                                                  "first_name": .string("false")])))
        await feed.handle(.posted(post()), server: server)
        await settle()

        XCTAssertEqual(mock.added.count, 0, "desktop notifications are off for this account")
        XCTAssertEqual(feed.lastRecord?.outcome, MentionDropReason.notificationsDisabled.label)
        XCTAssertTrue(ledger.hasHandled("post1", for: server.id),
                      "the reader's own setting decided it: the poll must not override it")
    }

    // MARK: - 5. Your own post is never your own notification

    func testTheReadersOwnPostDeliversNothing() async {
        directChannel()
        await feed.handle(.posted(post(userID: "me")), server: server)
        await settle()

        XCTAssertEqual(mock.added.count, 0)
        XCTAssertEqual(routing.socketMentions, 0)
    }

    // MARK: - 6. The conversation on screen is suppressed, and still handled

    func testTheConversationOnScreenIsSuppressedAndStillHandled() async {
        directChannel()
        worker.isAppActive = { true }
        feed.isAppActive = { true }
        worker.visibleChannel = { _ in .channel("dm1") }
        feed.visibleChannel = { _ in .channel("dm1") }

        await feed.handle(.posted(post()), server: server)
        await settle()

        XCTAssertEqual(mock.added.count, 0, "the reader is looking at this conversation")
        XCTAssertEqual(feed.lastRecord?.outcome, "you are looking at this channel")
        XCTAssertTrue(ledger.hasHandled("post1", for: server.id),
                      "a suppressed mention is still handled, so the poller does not re-deliver it later")
    }

    // MARK: - Adversarial: both inputs live for one server -> one banner

    /// The reason `NotificationInputGate` exists. A native pane plus a live socket makes the socket the
    /// input; a page frame for the same post must then be refused, not scheduled a second time.
    func testBothInputsLiveForOneServerProduceExactlyOneBanner() async {
        directChannel()
        let store = WebViewStore()
        let coordinator = WebViewContainer.Coordinator(
            store: store, serverID: server.id, serverURL: server.url,
            sessionStore: sessionStore, notificationWorker: worker)
        coordinator.mentionInput = routing
        routing.socketStateChanged(serverID: server.id, live: true)

        await feed.handle(.posted(post()), server: server)
        await settle()
        XCTAssertEqual(mock.added.count, 1, "the socket delivered")

        // A surface webview that does not claim the pane (T46's fallback) can still report — and must be
        // refused while the native socket is this server's live input.
        coordinator.handleNotifyMention(MentionNotification(title: "Direct message",
                                                            body: "@t43buddy: are you around?",
                                                            channelID: "dm1", teamID: "team1",
                                                            serverURL: server.url.absoluteString))
        await settle()
        XCTAssertEqual(mock.added.count, 1, "exactly one banner for the same post: the gate refused the second")
        XCTAssertEqual(routing.bridgeRefused, 1)
        XCTAssertEqual(routing.bridgeAccepted, 0)
    }

    // MARK: - Adversarial: a Release build cannot be forced

    /// The other half of the bug: even if a Release binary somehow carried a forced mode, the routing
    /// refuses it — the shipped answer must follow the pane. `debugAffordances: false` is the seam a
    /// Release build's `NotificationPathStore` uses.
    func testAReleaseSemanticsRoutingRefusesToForceTheInput() async {
        routing.setOverride(.bridge, debugAffordances: false)
        XCTAssertNil(routing.overrideMode, "a Release build cannot force the mention input")
        XCTAssertEqual(routing.mode(for: server.id), .socket,
                       "and the derivation still gives a native pane its socket")

        directChannel()
        await feed.handle(.posted(post()), server: server)
        await settle()
        XCTAssertEqual(mock.added.count, 1, "delivery is unaffected by the refused override")
    }
}

// MARK: - Doubles

/// A recording notification centre: the only seam `NotificationWorker` needs.
private final class T43ShippedRecordingScheduling: NotificationScheduling {
    var delegate: UNUserNotificationCenterDelegate?
    var status: UNAuthorizationStatus = .authorized
    private(set) var added: [UNNotificationRequest] = []

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }
    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func add(_ request: UNNotificationRequest) async throws { added.append(request) }
}

private final class T43ShippedRecordingBadge: BadgeSettable {
    private(set) var values: [Int] = []
    func setBadge(_ count: Int) { values.append(count) }
}

/// The server, faked: one profile, one channel, one membership row and the counters read.
@MainActor
private final class T43ShippedFakeService: ActivityServing {
    var calls: [String] = []
    var profileResult = Result<ActivityProfile, Error>.success(
        ActivityProfile(id: "me", username: "perfprobe", firstName: "Percy", lastName: "Probe",
                        notifyProps: .object([
                            "desktop": .string("mention"),
                            "desktop_sound": .string("true"),
                            "channel": .string("true"),
                            "mention_keys": .string(""),
                            "first_name": .string("false"),
                        ])))
    var channelResult = Result<MMChannel, Error>.success(
        MMChannel(id: "dm1", name: "buddy--perfprobe", displayName: "Direct message", type: "D",
                  teamId: "team1"))
    var membership: MMChannelMember? = MMChannelMember(
        channelId: "dm1", userId: "me",
        notifyProps: .object(["desktop": .string("default"),
                              "ignore_channel_mentions": .string("default"),
                              "mark_unread": .string("all")]))
    var users = [MMUser(id: "buddy", username: "t43buddy")]
    var counters: [MMTeamUnread] = []

    var pageSize: Int { 60 }

    func profile() async throws -> ActivityProfile {
        calls.append("profile")
        return try profileResult.get()
    }

    func mentions(terms: String, page: Int, perPage: Int) async throws -> MMSearchResults {
        calls.append("mentions")
        return MMSearchResults(order: [], posts: [:])
    }

    func channel(id: String) async throws -> MMChannel {
        calls.append("channel")
        return try channelResult.get()
    }

    func users(ids: [String]) async throws -> [MMUser] {
        calls.append("users")
        return users.filter { ids.contains($0.id) }
    }

    func channelRead(channelID: String, userID: String) async throws -> MMChannelMember {
        calls.append("channelRead")
        if let membership { return membership }
        throw MMError.notSignedIn
    }

    func badgeCounters() async throws -> [MMTeamUnread] {
        calls.append("badgeCounters")
        return counters
    }
}
