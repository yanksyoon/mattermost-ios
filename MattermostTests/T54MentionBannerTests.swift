// T54 — the in-app mention banner, unit-tested at the two seams that are worth pinning:
//
//   1. `MentionPresentationPolicy` — the **surface** decision. One table, mirroring T43's policy tests:
//      every `MentionDropReason` suppresses, a backgrounded delivery is a system notification, and a
//      foreground delivery is a banner **unless** the conversation on screen is the mention's own.
//   2. `InAppMentionBannerCenter` — one visible banner, latest wins, a bounded lifetime, a tap that opens
//      the conversation and a VoiceOver announcement that names the channel and the author.
//
// Plus the end-to-end rule the card is emphatic about: a mention the banner consumed must not produce a
// second banner *or* a system notification on the next poll. That is `NativeNotificationFeed`'s ledger
// (T43), exercised here with a real feed, a real ledger, a real `NotificationWorker` and only the server
// faked — the same shape `T43NativeNotificationFeedTests` uses.
//
// The mutation check recorded in `docs/t54-build-note.md` removes the "channel on screen" row from
// `MentionPresentationPolicy` and re-runs this file: `testAForegroundMentionInTheChannelOnScreenIsSuppressed`
// and `testWithTheChannelOnScreenNeitherSurfaceIsUsed` must go red.

import XCTest
import UserNotifications
@testable import Mattermost

@MainActor
final class T54MentionBannerTests: XCTestCase {

    // MARK: - The presentation table (pure)

    func testEveryPolicyDropIsSuppressedWithItsPolicyReason() {
        let reasons: [MentionDropReason] = [.deleted, .ownPost, .systemPost, .notificationsDisabled,
                                            .channelNotificationsOff, .mentionsIgnored, .notAMention,
                                            .alreadyDelivered, .noChannelContext]
        for reason in reasons {
            let presentation = MentionPresentationPolicy.presentation(
                for: .drop(reason),
                channelID: "ch1",
                surface: MentionSurfaceContext(appIsActive: true, isPrimaryServer: true,
                                               onScreen: .channel("ch2")))
            XCTAssertEqual(presentation, .suppressed(.policy(reason)),
                           "a policy drop is a suppression on every surface, whatever is on screen")
        }
    }

    func testABackgroundedDeliveryIsASystemNotification() {
        for silent in [true, false] {
            let presentation = MentionPresentationPolicy.presentation(
                for: .deliver(silent: silent),
                channelID: "ch1",
                surface: MentionSurfaceContext(appIsActive: false, isPrimaryServer: true,
                                               onScreen: .noChannel))
            XCTAssertEqual(presentation, .systemNotification(silent: silent),
                           "backgrounded, an in-app banner is invisible — the system surface is the only one that can be seen")
        }
    }

    func testAForegroundMentionInTheChannelOnScreenIsSuppressed() {
        let presentation = MentionPresentationPolicy.presentation(
            for: .deliver(silent: false),
            channelID: "ch1",
            surface: MentionSurfaceContext(appIsActive: true, isPrimaryServer: true,
                                           onScreen: .channel("ch1")))
        XCTAssertEqual(presentation, .suppressed(.channelOnScreen),
                       "the reader is reading that conversation: neither surface is news")
    }

    func testAForegroundMentionInAWebPaneIsSuppressed() {
        let presentation = MentionPresentationPolicy.presentation(
            for: .deliver(silent: false),
            channelID: "ch1",
            surface: MentionSurfaceContext(appIsActive: true, isPrimaryServer: true, onScreen: .unknown))
        XCTAssertEqual(presentation, .suppressed(.webPaneOwnsFocus),
                       "Path A: the page owns the focused-channel rule — a second opinion can only add noise")
    }

    func testAForegroundMentionInAnotherChannelIsABanner() {
        let presentation = MentionPresentationPolicy.presentation(
            for: .deliver(silent: false),
            channelID: "ch1",
            surface: MentionSurfaceContext(appIsActive: true, isPrimaryServer: true,
                                           onScreen: .channel("another-channel")))
        XCTAssertEqual(presentation, .inAppBanner(silent: false),
                       "the whole point of the card: a foreground mention in another channel is visible")
    }

    func testAForegroundMentionWithNoChannelOpenIsABanner() {
        let presentation = MentionPresentationPolicy.presentation(
            for: .deliver(silent: false),
            channelID: "ch1",
            surface: MentionSurfaceContext(appIsActive: true, isPrimaryServer: true, onScreen: .noChannel))
        XCTAssertEqual(presentation, .inAppBanner(silent: false),
                       "nothing is open on the visible server, so nothing is being read")
    }

    func testAForegroundMentionOnANonPrimaryServerIsABanner() {
        let presentation = MentionPresentationPolicy.presentation(
            for: .deliver(silent: false),
            channelID: "ch1",
            surface: MentionSurfaceContext(appIsActive: true, isPrimaryServer: false,
                                           onScreen: .channel("ch1")))
        XCTAssertEqual(presentation, .inAppBanner(silent: false),
                       "another server's conversation cannot be the one on screen, even if the ids collide")
    }

    func testSilenceIsCarriedThroughEitherSurface() {
        let banner = MentionPresentationPolicy.presentation(
            for: .deliver(silent: true), channelID: "ch1",
            surface: MentionSurfaceContext(appIsActive: true, isPrimaryServer: true, onScreen: .noChannel))
        let system = MentionPresentationPolicy.presentation(
            for: .deliver(silent: true), channelID: "ch1",
            surface: MentionSurfaceContext(appIsActive: false, isPrimaryServer: true, onScreen: .noChannel))
        XCTAssertEqual(banner, .inAppBanner(silent: true))
        XCTAssertEqual(system, .systemNotification(silent: true))
    }

    // MARK: - The one banner slot

    private var banner: InAppMentionBannerCenter!
    private var announcements: [String] = []
    private var opened: [MentionBanner] = []

    override func setUp() {
        super.setUp()
        announcements = []
        opened = []
        banner = InAppMentionBannerCenter()
        banner.announce = { [weak self] text in self?.announcements.append(text) }
        banner.onOpen = { [weak self] value in self?.opened.append(value) }
        banner.now = { Date(timeIntervalSince1970: 1_700_000_000) }
    }

    override func tearDown() {
        banner = nil
        announcements = []
        opened = []
        super.tearDown()
    }

    private func model(postID: String = "post1", channelID: String = "ch1",
                       channelLabel: String = "T43 notify", body: String = "@t43buddy: @perfprobe look",
                       author: String? = "t43buddy") -> MentionBanner {
        MentionBanner(serverID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                      serverName: "Local", teamID: "team1", channelID: channelID,
                      channelLabel: channelLabel, postID: postID, author: author, body: body,
                      silent: false, receivedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testTheFirstBannerTakesTheSlot() {
        XCTAssertEqual(banner.present(model()), .shown)
        XCTAssertEqual(banner.current?.postID, "post1")
        XCTAssertEqual(banner.shownCount, 1)
        XCTAssertEqual(banner.replacedCount, 0)
        XCTAssertEqual(banner.lastOutcome, "shown")
    }

    func testASecondBannerReplacesTheVisibleOne() {
        banner.present(model(postID: "post1"))
        XCTAssertEqual(banner.present(model(postID: "post2")), .replacedVisible,
                       "latest wins: a banner never stacks")
        XCTAssertEqual(banner.current?.postID, "post2", "the visible banner is the newest one")
        XCTAssertEqual(banner.shownCount, 1)
        XCTAssertEqual(banner.replacedCount, 1)
    }

    func testAReplayOfTheSamePostIsIgnored() {
        banner.present(model(postID: "post1"))
        XCTAssertEqual(banner.present(model(postID: "post1")), .ignoredDuplicate)
        XCTAssertEqual(banner.shownCount, 1)
        XCTAssertEqual(banner.replacedCount, 0, "a replay is not a replacement")
    }

    func testABannerWithoutIdsIsNotShown() {
        XCTAssertEqual(banner.present(model(postID: "")), .ignoredIncomplete)
        XCTAssertNil(banner.current, "a banner that cannot be opened is not worth showing")
        XCTAssertEqual(banner.present(model(channelID: "")), .ignoredIncomplete)
    }

    func testTheBannerHidesItselfAfterABoundedTime() async {
        banner.visibleDuration = 0.05
        banner.present(model())
        XCTAssertNotNil(banner.current)
        await banner.flushAutoDismiss()
        XCTAssertNil(banner.current, "an in-app banner is time-bounded; it must not sit over the composer")
        XCTAssertEqual(banner.hiddenCount, 1)
    }

    func testAReplacementReschedulesTheTimer() async throws {
        banner.visibleDuration = 0.4
        banner.present(model(postID: "post1"))
        try await Task.sleep(nanoseconds: 250_000_000)
        banner.present(model(postID: "post2"))
        // The first banner's timer would have fired ~150 ms from here. The replacement must own the slot.
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(banner.current?.postID, "post2",
                       "the cancelled timer must not take the newer banner down early")
        await banner.flushAutoDismiss()
        XCTAssertNil(banner.current)
    }

    func testATapOpensThroughTheFunnelAndHidesTheBanner() {
        let value = model(postID: "post1")
        banner.present(value)
        banner.openCurrent()
        XCTAssertNil(banner.current, "the banner goes first, so it is not drawn over the channel it opened")
        XCTAssertEqual(opened.map(\.postID), ["post1"])
        XCTAssertEqual(opened.first?.channelID, "ch1")
        XCTAssertEqual(opened.first?.teamID, "team1", "the tap carries the team the router needs")
    }

    func testTheAnnouncementNamesTheChannelAndTheAuthor() {
        banner.present(model(channelLabel: "T43 notify", body: "@t43buddy: @perfprobe look"))
        XCTAssertEqual(announcements.first, "Mention in T43 notify: @t43buddy: @perfprobe look",
                       "VoiceOver must hear which channel and who — the same two facts the banner draws")
        XCTAssertEqual(banner.current?.announcement,
                       "Mention in T43 notify: @t43buddy: @perfprobe look")
    }

    func testTheBannerFallsBackToTheSystemPathsTitleWhenTheChannelHasNoName() {
        banner.present(model(channelLabel: "   "))
        XCTAssertEqual(banner.current?.title, MentionNotificationFormatting.defaultTitle,
                       "an unnamed channel still gets the neutral title the system notification uses")
    }

    // MARK: - End to end: the banner and the system path share one decision and one ledger

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var server: ServerConfig!
    private var mock: T54RecordingScheduling!
    private var worker: NotificationWorker!
    private var sessionStore: SessionStore!
    private var serverStore: ServerStore!
    private var viewStore: ViewStore!
    private var routing: NotificationInputRouting!
    private var ledger: MentionLedger!
    private var feed: NativeNotificationFeed!
    private var service: T54FakeService!
    private var permissionRequests = 0

    private func setUpFeed() {
        suiteName = "T54BannerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let preferences = AppPreferences(defaults: defaults)
        server = ServerConfig(name: "Local", url: URL(string: "http://127.0.0.1:8065")!)
        serverStore = ServerStore(preferences: preferences)
        _ = serverStore.add(server)
        serverStore.switchTo(id: server.id)
        viewStore = ViewStore()
        viewStore.setPrimary(server.id)

        mock = T54RecordingScheduling()
        worker = NotificationWorker(scheduling: mock, preferences: preferences)
        worker.serverStore = serverStore
        worker.viewStore = viewStore
        worker.isAppActive = { false }

        sessionStore = SessionStore(preferences: preferences, badgeSetter: T54RecordingBadge())

        routing = NotificationInputRouting()
        routing.setMode(.socket)
        ledger = MentionLedger(preferences: preferences)
        service = T54FakeService()

        banner = InAppMentionBannerCenter()
        banner.visibleDuration = 3600
        banner.announce = { _ in }

        feed = NativeNotificationFeed(routing: routing, ledger: ledger)
        feed.bind(serverStore: serverStore, sessionStore: sessionStore, viewStore: viewStore)
        feed.serviceFactory = { [service] _ in service! }
        feed.deliverMention = { [worker] mention, serverID in
            await worker!.presentMention(mention, fromServerID: serverID)
        }
        feed.badgeRefreshDelay = 0
        feed.now = { Date(timeIntervalSince1970: 1_700_000_000) }
        // The app's wiring, in miniature: the one banner slot, the same "what is on screen" answer for
        // both surfaces, and the permission seam.
        feed.bannerCenter = banner
        feed.isAppActive = { true }
        feed.visibleChannel = { _ in .channel("other-channel") }
        permissionRequests = 0
        feed.askForNotificationPermission = { [weak self] in self?.permissionRequests += 1 }
    }

    private func tearDownFeed() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        server = nil
        mock = nil
        worker = nil
        sessionStore = nil
        serverStore = nil
        viewStore = nil
        routing = nil
        ledger = nil
        feed = nil
        service = nil
        banner = nil
    }

    private func post(id: String = "post1", message: String = "T43 please look @perfprobe",
                      userID: String = "buddy", channelID: String = "ch1") -> MMPost {
        MMPost(id: id, createAt: 1_700_000_000_000, deleteAt: 0, userId: userID,
               channelId: channelID, message: message, type: "")
    }

    private func settle() async {
        await feed.flushBadgeRefresh(for: server.id)
        for _ in 0..<50 { await Task.yield() }
    }

    func testAForegroundMentionInAnotherChannelShowsOneBannerAndNoSystemNotification() async {
        setUpFeed()
        defer { tearDownFeed() }

        await feed.handle(.posted(post()), server: server)
        await settle()

        XCTAssertEqual(banner.shownCount, 1, "the banner is the foreground surface")
        XCTAssertEqual(banner.current?.postID, "post1")
        XCTAssertEqual(banner.current?.channelLabel, "T43 notify")
        XCTAssertEqual(banner.current?.author, "t43buddy", "the banner names the author")
        XCTAssertEqual(banner.current?.body, "@t43buddy: T43 please look @perfprobe")
        XCTAssertEqual(mock.added.count, 0,
                       "one policy, two presentations: a banner must not also schedule a system notification")
        XCTAssertEqual(feed.lastRecord?.surface, "in-app banner")
        XCTAssertEqual(feed.lastRecord?.outcome, "delivered")
        XCTAssertEqual(feed.deliveredCount, 1)
        // The ask is fired off the delivery path (the system prompt is modal), so give that task a turn
        // rather than assuming it has already run.
        for _ in 0..<100 where permissionRequests == 0 { await Task.yield() }
        XCTAssertEqual(permissionRequests, 1,
                       "the banner schedules nothing, but the first-mention permission prompt must still happen")
    }

    func testTheSameMentionCannotProduceASecondBannerOrANotification() async {
        setUpFeed()
        defer { tearDownFeed() }

        await feed.handle(.posted(post()), server: server)
        await settle()
        // The server replays the frame (or the input runs twice): the ledger is the one place that decides.
        await feed.handle(.posted(post()), server: server)
        await settle()

        XCTAssertEqual(banner.shownCount, 1)
        XCTAssertEqual(banner.replacedCount, 0)
        XCTAssertEqual(banner.current?.postID, "post1")
        XCTAssertEqual(mock.added.count, 0, "no system notification either way")
        XCTAssertEqual(feed.lastRecord?.outcome, MentionDropReason.alreadyDelivered.label)
        XCTAssertTrue(ledger.hasHandled("post1", for: server.id))
        XCTAssertEqual(feed.deliveredCount, 1)
    }

    func testAPollCannotRedeliverABannerConsumedMention() async {
        setUpFeed()
        defer { tearDownFeed() }

        await feed.handle(.posted(post()), server: server)
        await settle()

        let pollPost = MentionPost(id: "post1", createAt: 1_700_000_000_000, userId: "buddy",
                                   channelId: "ch1", message: "T43 please look @perfprobe")
        XCTAssertFalse(MentionPoller.isNew(pollPost, relativeTo: ledger.state(for: server.id)),
                       "the banner wrote the one ledger the T14 poll reads: a consumed mention cannot re-fire")
    }

    func testWithTheChannelOnScreenNeitherSurfaceIsUsed() async {
        setUpFeed()
        defer { tearDownFeed() }
        feed.visibleChannel = { _ in .channel("ch1") }
        worker.visibleChannel = { _ in .channel("ch1") }

        await feed.handle(.posted(post()), server: server)
        await settle()

        XCTAssertNil(banner.current, "the reader is looking at this channel: a banner is noise")
        XCTAssertEqual(mock.added.count, 0)
        XCTAssertEqual(feed.lastRecord?.outcome, "you are looking at this channel")
        XCTAssertTrue(ledger.hasHandled("post1", for: server.id),
                      "suppressed by what is on screen is still handled — the poll must not deliver it later")
    }

    func testABackgroundedMentionStillUsesTheSystemNotification() async {
        setUpFeed()
        defer { tearDownFeed() }
        feed.isAppActive = { false }
        worker.isAppActive = { false }

        await feed.handle(.posted(post()), server: server)
        await settle()

        XCTAssertNil(banner.current, "no in-app surface while the app is not open")
        XCTAssertEqual(mock.added.count, 1, "the pre-T54 system path, unchanged")
        XCTAssertEqual(feed.lastRecord?.surface, "system notification")
    }

    func testTheBannerTapCarriesTheIdsTheRouterNeeds() async {
        setUpFeed()
        defer { tearDownFeed() }
        var opened: [MentionBanner] = []
        banner.onOpen = { opened.append($0) }

        await feed.handle(.posted(post()), server: server)
        await settle()
        banner.openCurrent()

        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.postID, "post1", "a banner tap lands on the post, not only the channel")
        XCTAssertEqual(opened.first?.channelID, "ch1")
        XCTAssertEqual(opened.first?.teamID, "team1")
        XCTAssertEqual(opened.first?.serverID, server.id)
    }
}

// MARK: - Doubles

private final class T54RecordingScheduling: NotificationScheduling {
    var delegate: UNUserNotificationCenterDelegate?
    var status: UNAuthorizationStatus = .authorized
    private(set) var added: [UNNotificationRequest] = []

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }
    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func add(_ request: UNNotificationRequest) async throws { added.append(request) }
}

private final class T54RecordingBadge: BadgeSettable {
    private(set) var values: [Int] = []
    func setBadge(_ count: Int) { values.append(count) }
}

/// The server, faked: one profile, one channel, one membership row and the counters read.
@MainActor
private final class T54FakeService: ActivityServing {
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

    var pageSize: Int { 60 }

    func profile() async throws -> ActivityProfile { try profileResult.get() }

    func mentions(terms: String, page: Int, perPage: Int) async throws -> MMSearchResults {
        MMSearchResults(order: [], posts: [:])
    }

    func channel(id: String) async throws -> MMChannel { try channelResult.get() }

    func users(ids: [String]) async throws -> [MMUser] { users.filter { ids.contains($0.id) } }

    func channelRead(channelID: String, userID: String) async throws -> MMChannelMember {
        if let membership { return membership }
        throw MMError.notSignedIn
    }

    func badgeCounters() async throws -> [MMTeamUnread] { [] }
}
