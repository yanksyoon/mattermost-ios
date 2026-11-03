// T34-R5b — the two panes that had no repair path now join the socket's gap sweep: an open **thread**
// and an open **mentions feed** are refetched on a reconnect *and* on the delivery watchdog's confirmed
// stall, and what they refetch is a **merge**.
//
// Why this is not just "call reload()": both panes' only refetch used to be `reload()` /
// `performInitialLoad()`, which flips `phase = .loading` (the reader's list blanks to a spinner) and
// rebuilds the window from one page (every older page — `loadEarlier()`'s replies, the mentions window's
// extra pages — is dropped). That is the defect T34-R5 rejected for the channel pane when it chose a
// merge over a reload (`docs/t34-socket-resync-build-note.md` §3). These tests pin the merge, the pager
// state that must survive it, and the visibility gate that decides whether a sweep runs at all.
//
// The harness is `T34SocketStallWatchdogTests`'s, extended by one pane: the **real**
// `SocketTeamEventSource` / `SocketClient` / `TeamSidebarCoordinator` over a scripted transport, the
// **real** `ThreadCoordinator` / `ActivityCoordinator` / `ChannelPaneCoordinator`, the **real** gate
// (`NativeSurfaceVisibility`), a hand-stepped clock, and fakes only for the two HTTP services. The clocks
// and the rail's fake service are reused from that file on purpose: one scripted-socket harness in this
// target, not a second one that can drift.

import XCTest
@testable import Mattermost

@MainActor
final class T34LivePaneResyncTests: XCTestCase {

    // MARK: - Fakes (HTTP only; every coordinator and the socket are the production ones)

    /// A `ThreadServing` whose answers are scripted per call, so "what the server holds now" is the
    /// test's decision — the shape of the defect: the reply exists on the server and was never delivered.
    @MainActor
    final class FakeThreadService: ThreadServing {
        var pageSize = 60
        /// Answers for `fromPost == nil` (the newest page), consumed in order; the last one repeats.
        var newestPages: [MMPostList] = []
        /// Older pages, keyed by the `fromPost` cursor the pane asked with.
        var earlierPages: [String: MMPostList] = [:]
        /// Answers for the threads list, consumed in order; the last one repeats.
        var listPages: [MMThreadList] = []
        var threadRow: MMThread?
        private(set) var newestPageRequests = 0
        private(set) var earlierPageRequests = 0
        private(set) var rowRequests = 0
        private var servedNewest = 0
        private var servedList = 0

        func thread(postID: String, fromPost: String?, fromCreateAt: Int64?,
                    perPage: Int) async throws -> MMPostList {
            if let fromPost {
                earlierPageRequests += 1
                return earlierPages[fromPost] ?? MMPostList()
            }
            newestPageRequests += 1
            guard !newestPages.isEmpty else { return MMPostList() }
            let slot = min(servedNewest, newestPages.count - 1)
            servedNewest += 1
            return newestPages[slot]
        }

        func threads(teamID: String, before: String?, perPage: Int,
                     unreadOnly: Bool) async throws -> MMThreadList {
            guard !listPages.isEmpty else { return MMThreadList() }
            let slot = min(servedList, listPages.count - 1)
            servedList += 1
            return listPages[slot]
        }

        func followedThread(teamID: String, threadID: String) async throws -> MMThread? {
            rowRequests += 1
            return threadRow
        }

        func setFollowing(teamID: String, threadID: String, following: Bool) async throws {}

        func markRead(teamID: String, threadID: String, at: Int64) async throws -> MMThread {
            threadRow ?? MMThread(id: threadID)
        }

        func markUnread(teamID: String, threadID: String, postID: String) async throws -> MMThread {
            threadRow ?? MMThread(id: threadID)
        }

        func post(id: String) async throws -> MMPost {
            newestPages.first?.posts[id] ?? MMPost(id: id)
        }

        func users(ids: [String]) async throws -> [MMUser] { [] }

        func addReaction(postID: String, emojiName: String, userID: String) async throws -> MMReaction {
            throw MMError.notSignedIn
        }

        func removeReaction(postID: String, emojiName: String, userID: String) async throws {}
    }

    /// An `ActivityServing` whose `POST /posts/search` answers are scripted per call, and whose read
    /// cursors are one team's membership rows.
    @MainActor
    final class FakeActivityService: ActivityServing {
        var pageSize = 60
        /// One answer per `mentions` call, consumed in order; the last one repeats.
        var answers: [MMSearchResults] = []
        var memberRows: [MMChannelMember] = []
        private(set) var searchRequests = 0
        private var served = 0

        func profile() async throws -> ActivityProfile {
            ActivityProfile(id: "me", username: "me", firstName: "Me")
        }

        func mentions(terms: String, page: Int, perPage: Int) async throws -> MMSearchResults {
            searchRequests += 1
            guard !answers.isEmpty else { return MMSearchResults() }
            let slot = min(served, answers.count - 1)
            served += 1
            return answers[slot]
        }

        func channel(id: String) async throws -> MMChannel {
            MMChannel(id: id, name: "town-square", displayName: "Town Square",
                      type: "O", teamId: "team-1")
        }

        func users(ids: [String]) async throws -> [MMUser] { [] }

        func channelReads(teamID: String, userID: String) async throws -> [MMChannelMember] {
            memberRows
        }

        func channelRead(channelID: String, userID: String) async throws -> MMChannelMember {
            memberRows.first { $0.channelId == channelID }
                ?? MMChannelMember(channelId: channelID, userId: userID, lastViewedAt: 0)
        }

        func unreadThreads(teamID: String) async throws -> [ActivityThreadUnread] { [] }

        func markThreadRead(teamID: String, rootID: String,
                            at timestamp: Int64) async throws -> ActivityThreadUnread {
            ActivityThreadUnread(rootID: rootID, unreadReplies: 0, unreadMentions: 0,
                                 lastViewedAt: timestamp)
        }

        func badgeCounters() async throws -> [MMTeamUnread] { [] }
    }

    /// A `ChannelServing` whose window is empty: the channel pane only has to exist and be *loaded* for
    /// the gate's channel branch to be answerable (and for the "the channel wiring is untouched" check).
    @MainActor
    final class FakeChannelService: ChannelServing {
        var pageSize = 60
        private(set) var firstPageRequests = 0

        func channel(id: String) async throws -> MMChannel {
            MMChannel(id: id, name: "town-square", displayName: "Town Square", type: "O")
        }

        func posts(channelID: String, before: String?, perPage: Int) async throws -> MMPostList {
            if before == nil { firstPageRequests += 1 }
            return MMPostList()
        }

        func users(ids: [String]) async throws -> [MMUser] { [] }

        func fileData(fileID: String, preferThumbnail: Bool) async throws -> Data { Data() }

        func membership(channelID: String) async throws -> MMChannelMember? { nil }
    }

    /// The location the shell is showing, mutable per test (the gate reads it at call time).
    @MainActor
    final class LocationBox {
        var location = NativeLocation()
    }

    // MARK: - Fixtures

    private let channelID = "chan-1"
    private let teamID = "team-1"
    private let rootID = "root"
    /// Test-scaled watchdog numbers, the same ones `T34SocketStallWatchdogTests` uses; the production
    /// values (150 s / 30 s / ×4) and why are in `SocketClient.StallWatchdog`.
    private let watchdog = SocketClient.StallWatchdog(threshold: 40, checkInterval: 10, quietMultiplier: 4)
    private let heartbeatInterval: TimeInterval = 30

    private func server() -> ServerConfig {
        ServerConfig(name: "Example", url: URL(string: "https://mm.example.com")!)
    }

    private func post(_ id: String, at millis: Int64, root: String = "", message: String? = nil) -> MMPost {
        MMPost(id: id, createAt: millis, userId: "u1", channelId: channelID,
               rootId: root, message: message ?? "message \(id)")
    }

    private func page(_ posts: [MMPost]) -> MMPostList {
        MMPostList(order: posts.map(\.id),
                   posts: Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) }))
    }

    private func mention(_ id: String, at millis: Int64, root: String = "") -> MMPost {
        post(id, at: millis, root: root, message: "@me see \(id)")
    }

    private func mentionPage(_ posts: [MMPost], hasNext: Bool = false) -> MMSearchResults {
        MMSearchResults(order: posts.map(\.id),
                        posts: Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) }),
                        hasNext: hasNext)
    }

    // MARK: - Harness

    private struct Harness {
        let rail: TeamSidebarCoordinator
        let pane: ChannelPaneCoordinator
        let threads: ThreadCoordinator
        let activity: ActivityCoordinator
        let source: SocketTeamEventSource
        let threadService: FakeThreadService
        let activityService: FakeActivityService
        let channelService: FakeChannelService
        let factory: ScriptedTransportFactory
        let server: ServerConfig
        let threadModel: ThreadViewModel?
        let feed: MentionsViewModel?
        let threadsList: GlobalThreadsViewModel?
        /// Bumped *after* each pane's sweep returned: "the refetch landed" is a signal, not a poll.
        let threadResynced: SignalCounter
        let feedResynced: SignalCounter
        let channelResynced: SignalCounter
    }

    private func makeHarness(transports: [ScriptedSocketTransport],
                             clock: SocketClock,
                             now: @escaping @Sendable () -> Date,
                             heartbeat: TimeInterval?,
                             location: LocationBox,
                             feedOnScreen: Bool,
                             threadPages: [MMPostList] = [],
                             earlierPages: [String: MMPostList] = [:],
                             threadRow: MMThread? = nil,
                             threadPageSize: Int = 60,
                             listPages: [MMThreadList] = [],
                             activityAnswers: [MMSearchResults] = [],
                             activityPageSize: Int = 60,
                             memberRows: [MMChannelMember] = [],
                             loadThread: Bool = false,
                             loadFeed: Bool = false,
                             loadThreadsList: Bool = false,
                             loadChannel: Bool = false) async -> Harness {
        let threadService = FakeThreadService()
        threadService.pageSize = threadPageSize
        threadService.newestPages = threadPages
        threadService.earlierPages = earlierPages
        threadService.threadRow = threadRow
        threadService.listPages = listPages

        let activityService = FakeActivityService()
        activityService.pageSize = activityPageSize
        activityService.answers = activityAnswers
        activityService.memberRows = memberRows

        let channelService = FakeChannelService()
        let factory = ScriptedTransportFactory(transports)
        let source = SocketTeamEventSource(
            transportFactory: { url, headers, _ in factory.make(url, headers) },
            clock: clock,
            heartbeatInterval: heartbeat,
            stallWatchdog: watchdog,
            now: now)
        let config = server()

        let pane = ChannelPaneCoordinator()
        pane.serviceFactory = { _ in channelService }
        pane.bind(auth: nil, navigation: nil, serverStore: nil)
        if loadChannel {
            await pane.activate(server: config, channelID: channelID, channelName: "Town Square")
        }

        let threads = ThreadCoordinator()
        threads.serviceFactory = { _ in threadService }
        threads.bind(auth: nil, navigation: nil, serverStore: nil, channelPanes: pane)

        let activity = ActivityCoordinator()
        activity.serviceFactory = { _ in activityService }
        activity.bind(auth: nil, serverStore: nil, sessionStore: nil)

        var threadModel: ThreadViewModel?
        if loadThread {
            threadModel = await threads.activate(server: config, rootID: rootID, channelID: channelID)
        }
        var feed: MentionsViewModel?
        if loadFeed {
            let model = activity.model(for: config)
            await model.load(ifNeeded: false)
            feed = model
        }
        var threadsList: GlobalThreadsViewModel?
        if loadThreadsList {
            let list = threads.globalModel(for: config, teamID: teamID)
            await list.load(ifNeeded: false)
            threadsList = list
        }
        activity.setFeedOnScreen(config.id, feedOnScreen)

        let rail = TeamSidebarCoordinator(events: source,
                                         unreadRefreshDelay: 0,
                                         makeService: { _ in T34SocketStallWatchdogTests.FakeTeamSidebarService() },
                                         tokenProvider: { _ in "tok-socket" })
        // The app's own wiring (`MattermostApp.bindShellStores`), one `Task` per pane, with a counter
        // after each so a test awaits "the sweep landed" instead of polling a request count.
        let threadResynced = SignalCounter()
        let feedResynced = SignalCounter()
        let channelResynced = SignalCounter()
        rail.onSocketResync = { [weak pane, weak threads, weak activity] serverID in
            Task {
                await pane?.resync(serverID: serverID)
                channelResynced.bump()
            }
            Task {
                await threads?.resync(serverID: serverID)
                threadResynced.bump()
            }
            Task { @MainActor in
                await activity?.resync(serverID: serverID)
                feedResynced.bump()
            }
        }
        // The real gate, bound to the real coordinators — the same rules the app binds in
        // `bindShellStores`, so these tests exercise the shipped answer rather than a copy of it.
        let visibility = NativeSurfaceVisibility(
            appIsActive: { true },
            acceptsNativeRouting: { true },
            location: { location.location },
            channelWindowLoaded: { [weak pane] serverID, channel in
                pane?.hasLoadedWindow(serverID: serverID, channelID: channel) ?? false
            },
            threadLoaded: { [weak threads] serverID, root in
                threads?.hasLoadedThread(serverID: serverID, rootID: root) ?? false
            },
            threadListLoaded: { [weak threads] serverID in
                threads?.hasLoadedThreadList(serverID: serverID) ?? false
            },
            feedOnScreen: { [weak activity] serverID in
                activity?.hasLoadedFeedOnScreen(serverID: serverID) ?? false
            })
        rail.isSurfaceVisible = { serverID in visibility.isVisible(serverID: serverID) }

        await rail.activate(config)
        return Harness(rail: rail, pane: pane, threads: threads, activity: activity,
                       source: source, threadService: threadService,
                       activityService: activityService, channelService: channelService,
                       factory: factory, server: config, threadModel: threadModel, feed: feed,
                       threadsList: threadsList, threadResynced: threadResynced,
                       feedResynced: feedResynced, channelResynced: channelResynced)
    }

    /// How many times each duration has been stepped in this test, so `step` waits for the *next* park
    /// of that duration and not one that already happened (the same helper the watchdog tests use).
    private var steppedParks: [TimeInterval: Int] = [:]

    private func step(_ clock: T34SocketStallWatchdogTests.SteppedSocketClock, _ seconds: TimeInterval,
                      file: StaticString = #filePath, line: UInt = #line) async {
        let ordinal = (steppedParks[seconds] ?? 0) + 1
        steppedParks[seconds] = ordinal
        let parked = await clock.parkSignal.wait(until: {
            $0.seconds == seconds && $0.ordinal >= ordinal
        })
        XCTAssertTrue(parked, "no parked \(Int(seconds))s sleep to release", file: file, line: line)
        let released = clock.release(seconds)
        XCTAssertTrue(released, "no parked \(Int(seconds))s sleep to release", file: file, line: line)
    }

    /// Drive a first connection to the authentication challenge: the state every scenario starts from.
    private func connect(_ transport: ScriptedSocketTransport,
                         factory: ScriptedTransportFactory,
                         count: Int) async {
        await awaitSignal("connection \(count)", signal: factory.createdSignal) { $0 == count }
        transport.push(.opened)
        await awaitSignal("the authentication challenge", signal: transport.sentSignal) {
            $0.contains("authentication_challenge")
        }
    }

    private func threadLocation(_ config: ServerConfig) -> NativeLocation {
        NativeLocation(serverID: config.id, teamID: teamID, channelID: channelID,
                       postID: rootID, pane: .threads)
    }

    // MARK: - The thread pane

    /// A reply the server published while the socket was down reaches an open thread on the reconnect —
    /// **and** the older page the reader had scrolled back through is still there.
    func testAReconnectRefetchesAnOpenThreadAndKeepsTheOlderPageTheReaderLoaded() async throws {
        let root = post(rootID, at: 1_000)
        let r1 = post("r1", at: 2_000, root: rootID)
        let r2 = post("r2", at: 3_000, root: rootID)
        let r3 = post("r3", at: 4_000, root: rootID)
        let now = TestNow()
        let clock = T34SocketStallWatchdogTests.InstantSocketClock()
        let first = ScriptedSocketTransport()
        let second = ScriptedSocketTransport()
        let box = LocationBox()
        let harness = await makeHarness(
            transports: [first, second], clock: clock, now: now.provider, heartbeat: nil,
            location: box, feedOnScreen: false,
            // pageSize 2: the first page holds the root and the newest reply, so `hasMore` is true and
            // `loadEarlier()` can pull the older one — the page a reload would have thrown away.
            threadPages: [page([root, r2]), page([root, r2, r3])],
            earlierPages: ["r2": page([root, r1])],
            threadRow: MMThread(id: rootID, replyCount: 2, lastReplyAt: 3_000, post: root),
            threadPageSize: 2,
            loadThread: true)
        box.location = threadLocation(harness.server)
        let model = try XCTUnwrap(harness.threadModel)

        XCTAssertEqual(model.loadedReplyIDs, ["r2"], "the pane starts on the newest page")
        let grew = await model.loadEarlier()
        XCTAssertTrue(grew, "the older page is loaded, as a reader would")
        XCTAssertEqual(model.loadedReplyIDs, ["r1", "r2"])
        XCTAssertTrue(model.hasMore, "the pager still says there is more")
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(harness.threadService.newestPageRequests, 1, "one load of the newest page")
        XCTAssertEqual(harness.threadService.earlierPageRequests, 1, "plus one older page")

        await connect(first, factory: harness.factory, count: 1)
        XCTAssertEqual(harness.rail.socketResyncCount, 0, "a first connect is not a gap")

        // The server's chain moved while the socket was down: a reply and the row's counters.
        harness.threadService.threadRow = MMThread(id: rootID, replyCount: 3, lastReplyAt: 4_000, post: root)

        first.close()
        await connect(second, factory: harness.factory, count: 2)
        await awaitSignal("the thread's refetch", signal: harness.threadResynced.signal) { $0 == 1 }

        XCTAssertEqual(model.loadedReplyIDs, ["r1", "r2", "r3"],
                       "the lost reply is merged in and the older page survives")
        XCTAssertTrue(model.hasMore, "the pager state is untouched by the sweep")
        XCTAssertEqual(model.phase, .loaded, "a sweep never blanks the chain")
        XCTAssertEqual(harness.threadService.newestPageRequests, 2, "exactly one refetch for one gap")
        XCTAssertEqual(model.resyncCount, 1)
        XCTAssertEqual(model.lastResyncInsertedCount, 1, "the count the diagnostics publish")
        XCTAssertEqual(harness.threads.resyncCount, 1)
        XCTAssertEqual(model.replyCount, 3, "the server's reply_count is adopted")
        XCTAssertEqual(model.root?.lastReplyAt, 4_000, "and its last_reply_at")
        XCTAssertEqual(model.followState, .following, "the follow/unread row is refreshed, not dropped")
        XCTAssertEqual(harness.source.stallResyncCount, 0, "this gap was the reconnect, not a stall")
    }

    /// The other trigger: an open, pingable socket that stopped delivering. The watchdog asks the shell
    /// whether anybody is looking — with a **thread pane** on screen the answer is now `true`, and the
    /// chain is repaired without blanking.
    func testAConfirmedStallRefetchesAnOpenThreadAndKeepsItsOlderPage() async throws {
        let root = post(rootID, at: 1_000)
        let r1 = post("r1", at: 2_000, root: rootID)
        let r2 = post("r2", at: 3_000, root: rootID)
        let r3 = post("r3", at: 4_000, root: rootID)
        let clock = T34SocketStallWatchdogTests.SteppedSocketClock()
        let transport = ScriptedSocketTransport(answersPingsWithPong: true)
        let box = LocationBox()
        let harness = await makeHarness(
            transports: [transport], clock: clock, now: clock.provider,
            heartbeat: heartbeatInterval,
            location: box, feedOnScreen: false,
            threadPages: [page([root, r2]), page([root, r2, r3])],
            earlierPages: ["r2": page([root, r1])],
            threadRow: MMThread(id: rootID, replyCount: 2, lastReplyAt: 3_000, post: root),
            threadPageSize: 2,
            loadThread: true)
        box.location = threadLocation(harness.server)
        let model = try XCTUnwrap(harness.threadModel)
        let grew = await model.loadEarlier()
        XCTAssertTrue(grew, "the older page is loaded before the stall")
        XCTAssertEqual(model.loadedReplyIDs, ["r1", "r2"])

        await connect(transport, factory: harness.factory, count: 1)
        await step(clock, heartbeatInterval)
        await awaitSignal("the first ping", signal: transport.pongSignal) { $0 == 1 }
        await step(clock, heartbeatInterval)
        await awaitSignal("the second ping", signal: transport.pongSignal) { $0 == 2 }
        XCTAssertEqual(harness.rail.socketResyncCount, 0, "a pong is liveness, not delivery")

        harness.threadService.threadRow = MMThread(id: rootID, replyCount: 3, lastReplyAt: 4_000, post: root)

        await step(clock, watchdog.checkInterval)
        await awaitSignal("the stalled thread to be repaired", signal: harness.threadResynced.signal) { $0 == 1 }

        XCTAssertEqual(model.loadedReplyIDs, ["r1", "r2", "r3"], "merged, not replaced")
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.lastResyncInsertedCount, 1)
        XCTAssertEqual(model.resyncCount, 1)
        XCTAssertEqual(harness.threadService.newestPageRequests, 2)
        XCTAssertEqual(harness.source.stallResyncCount, 1, "found by silence, not by a reconnect")
        XCTAssertEqual(harness.rail.socketResyncCount, 1, "one gap, one refetch")
    }

    // MARK: - The mentions feed

    /// A mention the server published while the socket was down reaches an open feed — and the row that
    /// only the feed's **second** search page had is still drawn, which a `reload()` would have dropped.
    func testAReconnectRefetchesTheMentionsFeedAndKeepsThePageItHadPagedIn() async throws {
        let m1 = mention("m1", at: 1_000)
        let m2 = mention("m2", at: 2_000)
        let m3 = mention("m3", at: 3_000)
        let m4 = mention("m4", at: 4_000)
        let now = TestNow()
        let clock = T34SocketStallWatchdogTests.InstantSocketClock()
        let first = ScriptedSocketTransport()
        let second = ScriptedSocketTransport()
        let box = LocationBox()
        let harness = await makeHarness(
            transports: [first, second], clock: clock, now: now.provider, heartbeat: nil,
            location: box, feedOnScreen: false,
            // pageSize 2 with `has_next` on the first answer: the feed's own reload pages once, so `m1`
            // is a row from page 1 — held state a replacement would silently drop.
            activityAnswers: [mentionPage([m3, m2], hasNext: true),
                              mentionPage([m1]),
                              mentionPage([m4, m3])],
            activityPageSize: 2,
            memberRows: [MMChannelMember(channelId: channelID, userId: "me", lastViewedAt: 0)],
            loadFeed: true)
        box.location = threadLocation(harness.server)
        let feed = try XCTUnwrap(harness.feed)
        XCTAssertEqual(feed.loadedPostIDs, ["m3", "m2", "m1"], "two pages, newest first")
        XCTAssertEqual(feed.phase, .loaded)
        XCTAssertEqual(harness.activityService.searchRequests, 2)

        await connect(first, factory: harness.factory, count: 1)
        first.close()
        await connect(second, factory: harness.factory, count: 2)
        await awaitSignal("the feed's refetch", signal: harness.feedResynced.signal) { $0 == 1 }

        XCTAssertEqual(feed.loadedPostIDs, ["m4", "m3", "m2", "m1"],
                       "the new mention is inserted and the second page's row survives")
        XCTAssertEqual(feed.phase, .loaded, "a sweep never blanks the feed")
        XCTAssertEqual(harness.activityService.searchRequests, 3, "exactly one refetch for one gap")
        XCTAssertEqual(feed.resyncCount, 1)
        XCTAssertEqual(feed.lastResyncInsertedCount, 1)
        XCTAssertEqual(harness.activity.resyncCount, 1)
        XCTAssertEqual(harness.source.stallResyncCount, 0, "this gap was the reconnect")
    }

    /// The stall trigger for the feed: the feed is the visible surface, so the watchdog asks and the
    /// shell answers `true` — without the channel pane holding anything, which is what makes the old
    /// channel-only gate deaf here.
    func testAConfirmedStallRefetchesTheMentionsFeed() async throws {
        let m1 = mention("m1", at: 1_000)
        let m2 = mention("m2", at: 2_000)
        let clock = T34SocketStallWatchdogTests.SteppedSocketClock()
        let transport = ScriptedSocketTransport(answersPingsWithPong: true)
        let box = LocationBox()
        let harness = await makeHarness(
            transports: [transport], clock: clock, now: clock.provider,
            heartbeat: heartbeatInterval,
            location: box, feedOnScreen: true,
            activityAnswers: [mentionPage([m1]), mentionPage([m2, m1])],
            memberRows: [MMChannelMember(channelId: channelID, userId: "me", lastViewedAt: 0)],
            loadFeed: true)
        // No channel window and no thread: the *feed* is the only thing on screen.
        box.location = NativeLocation()
        let feed = try XCTUnwrap(harness.feed)
        XCTAssertEqual(feed.loadedPostIDs, ["m1"])

        await connect(transport, factory: harness.factory, count: 1)
        await step(clock, heartbeatInterval)
        await awaitSignal("the first ping", signal: transport.pongSignal) { $0 == 1 }
        await step(clock, heartbeatInterval)
        await awaitSignal("the second ping", signal: transport.pongSignal) { $0 == 2 }
        XCTAssertEqual(harness.rail.socketResyncCount, 0)

        await step(clock, watchdog.checkInterval)
        await awaitSignal("the stalled feed to be repaired", signal: harness.feedResynced.signal) { $0 == 1 }

        XCTAssertEqual(feed.loadedPostIDs, ["m2", "m1"], "merged, not replaced")
        XCTAssertEqual(feed.phase, .loaded)
        XCTAssertEqual(feed.lastResyncInsertedCount, 1)
        XCTAssertEqual(harness.activityService.searchRequests, 2)
        XCTAssertEqual(harness.source.stallResyncCount, 1)
    }

    // MARK: - Nothing on screen is not a gap

    /// The negative half: a loaded thread and a loaded feed, **neither on screen**, and a quiet-but-pingable
    /// socket — no sweep. This is the assertion that keeps the watchdog a repair rather than a poll, and it
    /// is the one the gate exists for.
    func testAPaneThatIsNotOnScreenIsNotRefetched() async throws {
        let root = post(rootID, at: 1_000)
        let r2 = post("r2", at: 3_000, root: rootID)
        let m1 = mention("m1", at: 1_000)
        let clock = T34SocketStallWatchdogTests.SteppedSocketClock()
        let transport = ScriptedSocketTransport(answersPingsWithPong: true)
        let box = LocationBox()
        let harness = await makeHarness(
            transports: [transport], clock: clock, now: clock.provider,
            heartbeat: heartbeatInterval,
            location: box, feedOnScreen: false,
            threadPages: [page([root, r2])],
            threadRow: MMThread(id: rootID, replyCount: 1, lastReplyAt: 3_000, post: root),
            activityAnswers: [mentionPage([m1])],
            loadThread: true,
            loadFeed: true)
        // The shell is showing something else entirely (no channel, no thread, not the feed).
        box.location = NativeLocation()
        let model = try XCTUnwrap(harness.threadModel)
        let feed = try XCTUnwrap(harness.feed)
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(feed.phase, .loaded)

        await connect(transport, factory: harness.factory, count: 1)
        await step(clock, heartbeatInterval)
        for _ in 0..<3 { await step(clock, watchdog.checkInterval) }
        // Absence window: there is no event for "the watchdog did not fire".
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(harness.rail.socketResyncCount, 0, "nothing on screen is not a gap")
        XCTAssertEqual(harness.source.stallResyncCount, 0)
        XCTAssertEqual(harness.threadService.newestPageRequests, 1, "the thread was not refetched")
        XCTAssertEqual(harness.activityService.searchRequests, 1, "the feed was not refetched")
        XCTAssertEqual(model.resyncCount, 0)
        XCTAssertEqual(feed.resyncCount, 0)
    }

    // MARK: - The threads list (decided: it joins the sweep)

    /// The Threads list joins the sweep: a thread the reader started following during the gap is
    /// prepended, and a held row is **not** replaced by the newest page's older copy.
    func testAReconnectPrependsAThreadTheListDidNotHold() async throws {
        let held = MMThread(id: "t1", replyCount: 2, lastReplyAt: 2_000, post: post("t1", at: 2_000))
        // The same thread as the server's newest page draws it — a *stale* copy: the held row's counters
        // are the socket's, and a sweep must not walk them backwards.
        let heldStale = MMThread(id: "t1", replyCount: 1, lastReplyAt: 2_000, post: post("t1", at: 2_000))
        let fresh = MMThread(id: "t9", replyCount: 1, lastReplyAt: 9_000, post: post("t9", at: 9_000))
        let now = TestNow()
        let clock = T34SocketStallWatchdogTests.InstantSocketClock()
        let first = ScriptedSocketTransport()
        let second = ScriptedSocketTransport()
        let box = LocationBox()
        let harness = await makeHarness(
            transports: [first, second], clock: clock, now: now.provider, heartbeat: nil,
            location: box, feedOnScreen: false,
            listPages: [MMThreadList(threads: [held]),
                        MMThreadList(threads: [fresh, heldStale])],
            loadThreadsList: true)
        box.location = NativeLocation(serverID: harness.server.id, teamID: teamID, pane: .threads)
        let list = try XCTUnwrap(harness.threadsList)
        XCTAssertEqual(list.loadedThreadIDs, ["t1"])
        XCTAssertEqual(list.thread(id: "t1")?.replyCount, 2)

        await connect(first, factory: harness.factory, count: 1)
        first.close()
        await connect(second, factory: harness.factory, count: 2)
        await awaitSignal("the list's refetch", signal: harness.threadResynced.signal) { $0 == 1 }

        XCTAssertEqual(list.loadedThreadIDs, ["t9", "t1"], "the new thread is prepended")
        XCTAssertEqual(list.thread(id: "t1")?.replyCount, 2, "a held row is not replaced by a stale copy")
        XCTAssertEqual(list.phase, .loaded)
        XCTAssertEqual(list.resyncCount, 1)
        XCTAssertEqual(list.lastResyncInsertedCount, 1)
        XCTAssertEqual(harness.threads.resyncCount, 1)
    }

    // MARK: - The gate itself

    /// One assertion per branch of the shipped gate (`NativeSurfaceVisibility`), without a socket or a
    /// clock: the watchdog's question is answered the same way for a thread pane, the threads list, the
    /// feeds and the channel pane, and never for a surface it cannot prove is loaded.
    func testTheGateNamesTheFeedAThreadPaneTheThreadsListAndTheChannelPane() {
        let serverID = UUID()
        let otherServerID = UUID()
        var place = NativeLocation()
        var feedServers: Set<UUID> = []
        var channelLoaded = false
        var threadLoaded = false
        var listLoaded = false
        let gate = NativeSurfaceVisibility(
            appIsActive: { true },
            acceptsNativeRouting: { true },
            location: { place },
            channelWindowLoaded: { _, _ in channelLoaded },
            threadLoaded: { _, _ in threadLoaded },
            threadListLoaded: { _ in listLoaded },
            feedOnScreen: { feedServers.contains($0) })

        XCTAssertFalse(gate.isVisible(serverID: serverID), "nothing on screen, nothing to repair")

        // A channel window, as before this card.
        place = NativeLocation(serverID: serverID, channelID: "chan-1")
        XCTAssertFalse(gate.isVisible(serverID: serverID), "the channel window is not loaded yet")
        channelLoaded = true
        XCTAssertTrue(gate.isVisible(serverID: serverID), "a loaded channel window is a surface")

        // A thread pane covering that channel — the old gate's blind spot.
        place = NativeLocation(serverID: serverID, channelID: "chan-1", postID: "root", pane: .threads)
        XCTAssertFalse(gate.isVisible(serverID: serverID), "the thread's chain is not loaded yet")
        threadLoaded = true
        XCTAssertTrue(gate.isVisible(serverID: serverID), "a loaded thread pane is a surface")

        // The threads list: the same pane, no post.
        place = NativeLocation(serverID: serverID, teamID: "team-1", pane: .threads)
        XCTAssertFalse(gate.isVisible(serverID: serverID), "a list that never loaded is not a surface")
        listLoaded = true
        XCTAssertTrue(gate.isVisible(serverID: serverID), "a loaded threads list is a surface")

        // The mentions feed: no location names it, so the view's own report is the fact.
        place = NativeLocation()
        listLoaded = false
        feedServers = [serverID]
        XCTAssertTrue(gate.isVisible(serverID: serverID), "an on-screen, loaded feed is a surface")

        // And it never answers for a server whose surface is not the one on screen.
        XCTAssertFalse(gate.isVisible(serverID: otherServerID), "another server is not this one's surface")
        feedServers = []
        place = NativeLocation(serverID: otherServerID, channelID: "chan-1")
        XCTAssertFalse(gate.isVisible(serverID: serverID), "a channel on another server is not this one")
    }
}
