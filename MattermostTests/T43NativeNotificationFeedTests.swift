import XCTest
import UserNotifications
@testable import Mattermost

/// T43's input path end to end, with the real `NotificationWorker` (and a recording notification centre),
/// the real `SessionStore`, the real `MentionLedger` — and only the server faked. What this file pins:
///
///   * a socket mention produces **exactly one** banner, and the same post delivered twice does not;
///   * the banner's `userInfo` is byte-identical to the contract T13's Notification Service Extension and
///     the tap router read (`server_id`, `channel_id`, `team_id`, `url`, `type`);
///   * the socket input is silent in the shipped `.bridge` mode, while the screen's team scope no longer
///     decides anything for notifications;
///   * the badge is fed through `SessionStore`'s single arithmetic, never a local increment;
///   * the foreground rule compares **channels** when the native shell can say which one is on screen, so a
///     mention in another channel of the visible server is still one banner.
@MainActor
final class T43NativeNotificationFeedTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var server: ServerConfig!
    private var mock: T43RecordingScheduling!
    private var worker: NotificationWorker!
    private var badge: T43RecordingBadge!
    private var sessionStore: SessionStore!
    private var serverStore: ServerStore!
    private var viewStore: ViewStore!
    private var routing: NotificationInputRouting!
    private var ledger: MentionLedger!
    private var feed: NativeNotificationFeed!
    private var service: T43FakeService!

    override func setUp() {
        super.setUp()
        suiteName = "T43FeedTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let preferences = AppPreferences(defaults: defaults)
        server = ServerConfig(name: "Local", url: URL(string: "http://127.0.0.1:8065")!)
        serverStore = ServerStore(preferences: preferences)
        _ = serverStore.add(server)
        serverStore.switchTo(id: server.id)
        viewStore = ViewStore()
        viewStore.setPrimary(server.id)

        mock = T43RecordingScheduling()
        worker = NotificationWorker(scheduling: mock, preferences: preferences)
        worker.serverStore = serverStore
        worker.viewStore = viewStore
        worker.isAppActive = { false }

        badge = T43RecordingBadge()
        sessionStore = SessionStore(preferences: preferences, badgeSetter: badge)

        routing = NotificationInputRouting()
        routing.setMode(.socket)
        ledger = MentionLedger(preferences: preferences)
        service = T43FakeService()
        feed = NativeNotificationFeed(routing: routing, ledger: ledger)
        feed.bind(serverStore: serverStore, sessionStore: sessionStore)
        feed.serviceFactory = { [service] _ in service! }
        feed.deliverMention = { [worker] mention, serverID in
            await worker!.presentMention(mention, fromServerID: serverID)
        }
        feed.badgeRefreshDelay = 0
        feed.now = { Date(timeIntervalSince1970: 1_700_000_000) }
    }

    override func tearDown() {
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
        super.tearDown()
    }

    // MARK: - Fixtures

    private func post(id: String = "post1", message: String = "T43 please look @perfprobe",
                      userID: String = "buddy", channelID: String = "ch1",
                      type: String = "", deleteAt: Int64 = 0) -> MMPost {
        MMPost(id: id, createAt: 1_700_000_000_000, deleteAt: deleteAt, userId: userID,
               channelId: channelID, message: message, type: type)
    }

    private func membership(desktop: String = "default", ignoreMentions: String = "default",
                            markUnread: String = "all") -> MMChannelMember {
        MMChannelMember(channelId: "ch1", userId: "me", notifyProps: .object([
            "desktop": .string(desktop),
            "ignore_channel_mentions": .string(ignoreMentions),
            "mark_unread": .string(markUnread),
        ]))
    }

    /// Let the feed's own `Task`s (the coalesced badge read) run to completion.
    private func settle() async {
        await feed.flushBadgeRefresh(for: server.id)
        for _ in 0..<50 { await Task.yield() }
    }

    private func userInfo(_ request: UNNotificationRequest) -> [String: String] {
        let raw = request.content.userInfo
        var result: [String: String] = [:]
        for (key, value) in raw where key is String {
            result[key as! String] = (value as? String) ?? ""
        }
        return result
    }

    // MARK: - Exactly one banner

    func testASocketMentionProducesExactlyOneBanner() async {
        await feed.handle(.posted(post()), server: server)
        await settle()

        XCTAssertEqual(mock.added.count, 1, "one mention, one banner")
        XCTAssertEqual(feed.deliveredCount, 1)
        XCTAssertEqual(routing.socketMentions, 1)
        XCTAssertEqual(routing.socketDelivered, 1)
        XCTAssertTrue(ledger.hasHandled("post1", for: server.id))
    }

    func testTheSamePostTwiceIsOneBanner() async {
        await feed.handle(.posted(post()), server: server)
        await feed.handle(.posted(post()), server: server)
        await settle()

        XCTAssertEqual(mock.added.count, 1, "the ring refuses the replay, so a duplicate frame cannot double-notify")
        XCTAssertEqual(feed.lastRecord?.outcome, "already notified for this post")
    }

    func testAPostThatDoesNotNameTheReaderDeliversNothing() async {
        await feed.handle(.posted(post(message: "nothing to see here")), server: server)
        await settle()
        XCTAssertEqual(mock.added.count, 0)
        XCTAssertEqual(routing.socketMentions, 0)
    }

    func testTheReadersOwnPostIsIgnoredBeforeAnyRequest() async {
        await feed.handle(.posted(post(userID: "me")), server: server)
        await settle()
        XCTAssertEqual(mock.added.count, 0)
        XCTAssertEqual(service.calls, ["profile"],
                       "the reader is identified once (its keys are needed for every decision); no channel "
                       + "read, no body lookup, no counters")
    }

    func testASystemPostIsIgnored() async {
        await feed.handle(.posted(post(type: "system_join_channel")), server: server)
        await settle()
        XCTAssertEqual(mock.added.count, 0)
    }

    func testADeletedPostIsNotRecordedOrDelivered() async {
        await feed.handle(.posted(post(deleteAt: 99)), server: server)
        await settle()
        XCTAssertEqual(mock.added.count, 0)
    }

    // MARK: - The userInfo contract (T13's extension and the tap router read these keys)

    func testTheUserInfoContractIsUnchanged() async {
        await feed.handle(.posted(post()), server: server)
        await settle()

        guard let request = mock.added.first else { return XCTFail("no notification was scheduled") }
        let info = userInfo(request)
        XCTAssertEqual(info["server_id"], server.id.uuidString)
        XCTAssertEqual(info["channel_id"], "ch1")
        XCTAssertEqual(info["team_id"], "team1")
        XCTAssertEqual(info["url"], server.url.absoluteString)
        XCTAssertEqual(info["type"], "mention")
        XCTAssertEqual(Set(info.keys), ["server_id", "channel_id", "team_id", "url", "type"],
                       "no key may be added or lost: the extension and the router decode exactly this")
    }

    func testTheBannerTextMatchesTheWebappsContract() async {
        await feed.handle(.posted(post()), server: server)
        await settle()

        guard let request = mock.added.first else { return XCTFail("no notification was scheduled") }
        XCTAssertEqual(request.content.title, "Local: T43 notify",
                       "desktop composes \"server: channel\"")
        XCTAssertEqual(request.content.body, "@t43buddy: T43 please look @perfprobe")
        XCTAssertEqual(request.content.threadIdentifier, "ch1", "grouped per channel like the bridge path")
    }

    // MARK: - One source per server (the dual-render guarantee)

    /// The live dual-render case, at the call sites: with the web app drawing the pane, the socket
    /// delivers nothing **and** the page's own report is accepted — one source, one banner. Before this
    /// rule the socket kept the mention and the worker's conservative `.unknown` suppression ate it, so a
    /// dual-render run produced *no* banner at all (measured: `delivered=0 suppressed=1`).
    func testAMountedWebPaneSilencesTheSocketAndLetsThePageDeliver() async {
        let store = WebViewStore()
        let coordinator = WebViewContainer.Coordinator(
            store: store, serverID: server.id, serverURL: server.url,
            sessionStore: sessionStore, notificationWorker: worker)
        coordinator.mentionInput = routing
        // Exactly what `makeUIView` reports when the web app's pane mounts.
        routing.paneKindChanged(serverID: server.id, isWeb: true)

        await feed.handle(.posted(post()), server: server)
        await settle()
        XCTAssertEqual(mock.added.count, 0, "the page is the input while it draws the pane")
        XCTAssertEqual(feed.deliveredCount, 0)

        let frame = MentionNotification(title: "T43 notify", body: "@t43buddy said hi",
                                        channelID: "ch1", teamID: "team1",
                                        serverURL: server.url.absoluteString)
        coordinator.handleNotifyMention(frame)
        await settle()
        XCTAssertEqual(mock.added.count, 1, "the page's report is the one banner")
        XCTAssertEqual(routing.bridgeAccepted, 1)
        XCTAssertEqual(routing.bridgeRefused, 0, "and it was never refused")

        // The pane goes native (the webview unmounts): the socket is the input again.
        routing.paneKindChanged(serverID: server.id, isWeb: false)
        await feed.handle(.posted(post(id: "post2")), server: server)
        await settle()
        XCTAssertEqual(mock.added.count, 2)
        XCTAssertEqual(feed.deliveredCount, 1)
    }

    func testTheSocketInputIsSilentInBridgeMode() async {
        routing.setMode(.bridge)
        await feed.handle(.posted(post()), server: server)
        await settle()

        XCTAssertEqual(mock.added.count, 0, "Path A still owns the banners in the shipped default")
        XCTAssertEqual(feed.deliveredCount, 0)
        XCTAssertTrue(ledger.hasHandled("post1", for: server.id),
                      "the ledger is still fed: the poller's watermark must not fall behind a live socket")
    }

    func testALiveSocketMakesTheBridgeRefuseAndAFinishedPumpHandsItBack() {
        XCTAssertTrue(routing.acceptsBridge(serverID: server.id), "before the pump reports itself the bridge is the input")
        feed.socketStateChanged(serverID: server.id, live: true)
        XCTAssertFalse(routing.acceptsBridge(serverID: server.id),
                       "this refusal is what stops the webview path double-firing during dual-render")
        XCTAssertEqual(routing.liveSocketCount, 1)

        feed.socketStateChanged(serverID: server.id, live: false)
        XCTAssertTrue(routing.acceptsBridge(serverID: server.id), "a socket that is gone is not the input")
    }

    // MARK: - Foreground suppression compares the channel on screen

    func testAForegroundMentionInAnotherChannelStillNotifies() async {
        worker.isAppActive = { true }
        worker.visibleChannel = { _ in .channel("another-channel") }

        await feed.handle(.posted(post()), server: server)
        await settle()
        XCTAssertEqual(mock.added.count, 1,
                       "the reader is looking at a different channel: this is exactly the card's one-banner case")
    }

    func testAMentionInTheChannelOnScreenIsSuppressed() async {
        worker.isAppActive = { true }
        worker.visibleChannel = { _ in .channel("ch1") }

        await feed.handle(.posted(post()), server: server)
        await settle()
        XCTAssertEqual(mock.added.count, 0)
        XCTAssertEqual(feed.lastRecord?.outcome, "you are looking at this channel")
        XCTAssertTrue(ledger.hasHandled("post1", for: server.id),
                      "a suppressed mention is still handled, so the poller does not re-deliver it later")
    }

    func testWithNoChannelOpenOnTheVisibleServerTheBannerArrives() async {
        worker.isAppActive = { true }
        worker.visibleChannel = { _ in .noChannel }
        await feed.handle(.posted(post()), server: server)
        await settle()
        XCTAssertEqual(mock.added.count, 1)
    }

    func testAWebviewPaneKeepsTheWholeServerRule() async {
        worker.isAppActive = { true }
        worker.visibleChannel = { _ in .unknown }
        await feed.handle(.posted(post()), server: server)
        await settle()
        XCTAssertEqual(mock.added.count, 0,
                       "Path A cannot see the page's channel, so the conservative T8 rule still applies there")
    }

    // MARK: - The badge (one arithmetic)

    func testTheBadgeFollowsTheServersOwnCounters() async {
        service.counters = [MMTeamUnread(teamId: "team1", mentionCount: 2, msgCount: 3),
                            MMTeamUnread(teamId: "team2", mentionCount: 5, msgCount: 4)]
        await feed.handle(.posted(post()), server: server)
        await settle()

        XCTAssertEqual(service.badgeCalls, 1, "one coalesced counters read per mention burst")
        let mentions = await sessionStore.totalMentions
        XCTAssertEqual(mentions, 7,
                       "SessionStore.serverBadgeInput is the one arithmetic: 2 + 5 from the server")
        XCTAssertEqual(badge.values.last, 7, "the app icon is set from the same number")
    }

    func testTheBadgeIsNotIncrementedLocally() async {
        service.counters = [MMTeamUnread(teamId: "team1", mentionCount: 3, msgCount: 3)]
        // A second mention whose counters read fails must not invent a number.
        service.failCounters = true
        await feed.handle(.posted(post(id: "post2")), server: server)
        await settle()
        XCTAssertEqual(sessionStore.totalMentions, 0, "no counters, no badge change: never a local +1")
    }

    // MARK: - Drops are recorded with a reason

    func testADroppedMentionIsRecordedWithItsReason() async {
        service.membership = membership(desktop: "none")
        await feed.handle(.posted(post()), server: server)
        await settle()

        XCTAssertEqual(mock.added.count, 0)
        XCTAssertEqual(feed.lastRecord?.outcome, "notifications are off for this channel")
        XCTAssertEqual(routing.lastDropReason, "notifications are off for this channel")
    }

    func testAnUnresolvableChannelIsNotANotification() async {
        service.failChannel = true
        await feed.handle(.posted(post()), server: server)
        await settle()

        XCTAssertEqual(mock.added.count, 0, "no channel context, no guess")
        XCTAssertEqual(feed.lastRecord?.outcome, "the channel could not be resolved")
    }

    // MARK: - One high-water mark with the T14 poller

    func testAPollCannotRedeliverWhatThisPathAlreadyDelivered() async {
        await feed.handle(.posted(post()), server: server)
        await settle()

        let pollPost = MentionPost(id: "post1", createAt: 1_700_000_000_000, userId: "buddy",
                                   channelId: "ch1", message: "T43 please look @perfprobe")
        XCTAssertFalse(MentionPoller.isNew(pollPost, relativeTo: ledger.state(for: server.id)),
                       "the feed wrote the ring the poller reads: one state, so the known T14 duplicate is closed")
    }

    // MARK: - The webview path is refused while the socket is live (the dual-render duplicate)

    /// The actual call site the page's `notify_mention` frame reaches: `WebViewContainer.Coordinator`.
    /// This is the second half of "one source per server" — the gate test above proves the rule, this
    /// proves the webview actually consults it instead of delivering anyway.
    func testTheWebViewPathIsRefusedWhileTheSocketIsLive() async {
        let store = WebViewStore()
        let coordinator = WebViewContainer.Coordinator(
            store: store, serverID: server.id, serverURL: server.url,
            sessionStore: sessionStore, notificationWorker: worker)
        coordinator.mentionInput = routing

        let frame = MentionNotification(title: "T43 notify", body: "@t43buddy said hi",
                                        channelID: "ch1", teamID: "team1",
                                        serverURL: server.url.absoluteString)
        routing.socketStateChanged(serverID: server.id, live: true)
        coordinator.handleNotifyMention(frame)
        await settle()
        XCTAssertEqual(mock.added.count, 0,
                       "the page must not deliver while the native socket is the input")
        XCTAssertEqual(routing.bridgeRefused, 1, "and the refusal is counted, not silent")

        routing.socketStateChanged(serverID: server.id, live: false)
        coordinator.handleNotifyMention(frame)
        await settle()
        XCTAssertEqual(mock.added.count, 1,
                       "once the socket is gone the bridge is the input again — the default path still works")
        XCTAssertEqual(routing.bridgeAccepted, 1)
    }
}

// MARK: - Doubles

/// A recording notification centre: the only seam `NotificationWorker` needs.
private final class T43RecordingScheduling: NotificationScheduling {
    var delegate: UNUserNotificationCenterDelegate?
    var status: UNAuthorizationStatus = .authorized
    private(set) var added: [UNNotificationRequest] = []

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }
    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func add(_ request: UNNotificationRequest) async throws { added.append(request) }
}

private final class T43RecordingBadge: BadgeSettable {
    private(set) var values: [Int] = []
    func setBadge(_ count: Int) { values.append(count) }
}

/// The server, faked: one profile, one channel, one membership row and the counters read.
@MainActor
private final class T43FakeService: ActivityServing {
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
        MMChannel(id: "ch1", name: "t43-notify", displayName: "T43 notify", type: "O",
                  teamId: "team1"))
    var membership: MMChannelMember? = MMChannelMember(
        channelId: "ch1", userId: "me",
        notifyProps: .object(["desktop": .string("default"),
                              "ignore_channel_mentions": .string("default"),
                              "mark_unread": .string("all")]))
    var users = [MMUser(id: "buddy", username: "t43buddy")]
    var counters: [MMTeamUnread] = []
    var failChannel = false
    var failCounters = false
    private(set) var badgeCalls = 0

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
        if failChannel { throw MMError.notSignedIn }
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
        badgeCalls += 1
        if failCounters { throw MMError.notSignedIn }
        return counters
    }
}
