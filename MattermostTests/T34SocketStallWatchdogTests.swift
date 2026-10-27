// T34-R5 follow-up — the socket's *other* half: an open, pingable socket that stops delivering.
//
// `T34SocketResyncTests` pins the reconnect repair: a frame lost across a dropped connection is
// refetched. It cannot cover the failure the T34-R5 log actually *looks* like — `socket open`,
// `authentication_challenge`, `ping`, and no `posted`, with no `connection lost` line either: the
// connection stays up, the server keeps answering the heartbeat, and no server event arrives. Nothing
// reports that gap; `handleOpen` is the only place a resync fires, and there is no open.
//
// These tests are the delivery watchdog (`SocketClient.StallWatchdog`) end to end but without a
// network: a scripted transport that answers every `ping` with a pong and pushes no event, the **real**
// `SocketTeamEventSource` / `SocketClient` / `TeamSidebarCoordinator` / `ChannelPaneCoordinator` /
// `ChannelViewModel` chain, and a clock the test steps by hand so "150 s of silence" is a decision, not
// a sleep.
//
// Two clocks, because the two kinds of scenario need different control:
//  * `SteppedSocketClock` — every sleep parks until the test releases *that duration*, and releasing
//    advances the shared wall clock. Used where the heartbeat must really exchange a ping/pong: two
//    loops share the clock and arrival order is the scheduler's choice, so release is by duration.
//  * `InstantSocketClock` + `TestNow` — sleeps return at once, time moves by hand. Used where the
//    reconnect's *backoff* must be let through (its delay carries jitter and is not a number the test
//    should guess); with `heartbeatInterval: nil` there is no heartbeat to spin, and the watchdog can
//    only fire when `now` moves.

import XCTest
@testable import Mattermost

@MainActor
final class T34SocketStallWatchdogTests: XCTestCase {

    // MARK: - Clocks

    /// A hand-stepped clock: `sleep(for:)` parks until the test releases a waiter asking for exactly
    /// that duration, and a release moves the shared wall clock forward by it.
    ///
    /// Release is **by duration**, never by arrival: the heartbeat and the delivery watchdog are two
    /// loops on one clock and which of them parks first is up to the scheduler, so "release the next
    /// sleep" could advance the wrong loop and make the test assert about the wrong thing.
    final class SteppedSocketClock: SocketClock, @unchecked Sendable {
        /// One park, as a signal value: which duration, and how many times *that* duration has parked.
        /// The ordinal is what makes "the second 30 s sleep" awaitable — a bare duration would let the
        /// second wait match the first park (kanban t_00fb623c).
        struct Park: Sendable, Equatable {
            let seconds: TimeInterval
            let ordinal: Int
        }

        private struct Waiter {
            let id: UUID
            let seconds: TimeInterval
            var continuation: CheckedContinuation<Void, Never>?
            var released = false
        }

        private let lock = NSLock()
        private var waiters: [Waiter] = []
        private var current: Date
        private var parkCounts: [TimeInterval: Int] = [:]

        /// Fires for every sleep that reaches its park, with its ordinal.
        let parkSignal = TestSignal<Park>()

        init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
            self.current = start
        }

        var now: Date {
            lock.lock()
            defer { lock.unlock() }
            return current
        }

        /// The closure `SocketClient(now:)` takes: the same time the sleeps move.
        var provider: @Sendable () -> Date { { self.now } }

        /// How many sleeps asking for `seconds` are parked right now.
        func parked(_ seconds: TimeInterval) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return waiters.filter { $0.seconds == seconds && !$0.released }.count
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock()
            current = current.addingTimeInterval(seconds)
            lock.unlock()
        }

        func sleep(for seconds: TimeInterval) async {
            guard seconds > 0 else { return }
            let id = UUID()
            lock.lock()
            if Task.isCancelled {
                lock.unlock()
                return
            }
            waiters.append(Waiter(id: id, seconds: seconds))
            lock.unlock()

            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                        // Released (or cancelled) between the append and the park.
                        lock.unlock()
                        continuation.resume()
                        return
                    }
                    if waiters[index].released || Task.isCancelled {
                        waiters.remove(at: index)
                        lock.unlock()
                        continuation.resume()
                        return
                    }
                    waiters[index].continuation = continuation
                    parkCounts[seconds, default: 0] += 1
                    let ordinal = parkCounts[seconds] ?? 0
                    lock.unlock()
                    parkSignal.send(Park(seconds: seconds, ordinal: ordinal))
                }
            } onCancel: {
                self.release(id: id)
            }
        }

        /// Release one parked sleep of `seconds`, advancing the clock by it. `false` when none is parked.
        @discardableResult
        func release(_ seconds: TimeInterval) -> Bool {
            lock.lock()
            guard let index = waiters.firstIndex(where: { $0.seconds == seconds && !$0.released }),
                  waiters[index].continuation != nil else {
                lock.unlock()
                return false
            }
            let waiter = waiters.remove(at: index)
            current = current.addingTimeInterval(waiter.seconds)
            let continuation = waiter.continuation
            lock.unlock()
            continuation?.resume()
            return true
        }

        private func release(id: UUID) {
            lock.lock()
            guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                lock.unlock()
                return
            }
            let waiter = waiters.remove(at: index)
            current = current.addingTimeInterval(waiter.seconds)
            let continuation = waiter.continuation
            lock.unlock()
            continuation?.resume()
        }
    }

    /// A clock whose sleeps return at once (after yielding), so the socket's loops run as fast as the
    /// machine while wall time is moved by hand through `TestNow`.
    final class InstantSocketClock: SocketClock, @unchecked Sendable {
        private let lock = NSLock()
        private var delays: [TimeInterval] = []

        var requestedDelays: [TimeInterval] {
            lock.lock()
            defer { lock.unlock() }
            return delays
        }

        func sleep(for seconds: TimeInterval) async {
            lock.lock()
            delays.append(seconds)
            lock.unlock()
            // Yield, not return: a loop that never suspends would hog its executor thread for the whole
            // test (the watchdog is one such loop).
            await Task.yield()
        }
    }

    // MARK: - Fakes

    /// A `ChannelServing` whose newest page can change between calls — the shape of the defect: the post
    /// exists on the server and was never delivered over the socket.
    @MainActor
    final class FakeChannelService: ChannelServing {
        var pageSize: Int
        /// Answers for `before == nil`, consumed in order; the last one repeats.
        var firstPages: [MMPostList]
        var olderPages: [String: MMPostList] = [:]
        var membershipRow: MMChannelMember?
        var failure: Error?
        private(set) var firstPageRequests = 0
        private(set) var membershipRequests = 0
        private var served = 0

        init(pageSize: Int = 60, firstPages: [MMPostList] = []) {
            self.pageSize = pageSize
            self.firstPages = firstPages
        }

        func channel(id: String) async throws -> MMChannel {
            MMChannel(id: id, name: "town-square", displayName: "Town Square", type: "O")
        }

        func posts(channelID: String, before: String?, perPage: Int) async throws -> MMPostList {
            if let failure { throw failure }
            if before == nil {
                firstPageRequests += 1
                let slot = min(served, max(0, firstPages.count - 1))
                served += 1
                return firstPages.isEmpty ? MMPostList(order: [], posts: [:]) : firstPages[slot]
            }
            return olderPages[before ?? ""] ?? MMPostList(order: [], posts: [:])
        }

        func users(ids: [String]) async throws -> [MMUser] { [] }

        func fileData(fileID: String, preferThumbnail: Bool) async throws -> Data { Data() }

        func membership(channelID: String) async throws -> MMChannelMember? {
            membershipRequests += 1
            return membershipRow
        }
    }

    /// The rail's own service seam: nothing here is under test, the rail only has to activate.
    @MainActor
    final class FakeTeamSidebarService: TeamSidebarServing {
        func load() async throws -> TeamSidebarData {
            TeamSidebarData(teams: [MMTeam(id: "team-1", name: "perf", displayName: "Perf")])
        }
        func unreads() async throws -> [MMTeamUnread] { [] }
        func icon(for teamID: String, lastUpdateAt: Int64) async -> Data? { nil }
    }

    // MARK: - Fixtures

    private let channelID = "chan-1"
    /// Test-scaled watchdog numbers. The production values (150 s / 30 s / ×4) and why are in
    /// `SocketClient.StallWatchdog`; a test that waited them out would take minutes and prove nothing
    /// extra about the rule.
    private let watchdog = SocketClient.StallWatchdog(threshold: 40, checkInterval: 10, quietMultiplier: 4)
    private let heartbeatInterval: TimeInterval = 30

    private func server() -> ServerConfig {
        ServerConfig(name: "Example", url: URL(string: "https://mm.example.com")!)
    }

    private func post(_ id: String, at millis: Int64, message: String? = nil,
                      user: String = "u1") -> MMPost {
        MMPost(id: id, createAt: millis, userId: user, channelId: channelID,
               message: message ?? "message \(id)")
    }

    private func list(_ posts: [MMPost]) -> MMPostList {
        MMPostList(order: posts.map(\.id),
                   posts: Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) }))
    }

    /// The whole production chain for a delivery stall: the real source (over a scripted transport), the
    /// real rail, the real pane coordinator and the real list model. Only the two servers are fake.
    private struct AppHarness {
        let rail: TeamSidebarCoordinator
        let pane: ChannelPaneCoordinator
        let source: SocketTeamEventSource
        let channelService: FakeChannelService
        let factory: ScriptedTransportFactory
        let server: ServerConfig
        let transport: ScriptedSocketTransport
        /// Events the rail forwarded to the pane, bumped *after* the pane handled each one.
        let delivered: SignalCounter
        /// Refetches the rail asked the pane for, bumped after `pane.resync` returned.
        let resynced: SignalCounter
    }

    private func makeHarness(pages: [MMPostList],
                             transports: [ScriptedSocketTransport],
                             clock: SocketClock,
                             now: @escaping @Sendable () -> Date,
                             heartbeat: TimeInterval?,
                             visible: Bool) async -> AppHarness {
        let channelService = FakeChannelService(pageSize: 60, firstPages: pages)
        let factory = ScriptedTransportFactory(transports)
        let source = SocketTeamEventSource(
            transportFactory: { url, headers, _ in factory.make(url, headers) },
            clock: clock,
            heartbeatInterval: heartbeat,
            stallWatchdog: watchdog,
            now: now)
        let server = server()

        let pane = ChannelPaneCoordinator()
        pane.serviceFactory = { _ in channelService }
        pane.bind(auth: nil, navigation: nil, serverStore: nil)
        await pane.activate(server: server, channelID: channelID, channelName: "Town Square")

        let rail = TeamSidebarCoordinator(events: source,
                                         unreadRefreshDelay: 0,
                                         makeService: { _ in FakeTeamSidebarService() },
                                         tokenProvider: { _ in "tok-socket" })
        // The app's own wirings (`MattermostApp.bindShellStores`): a delivered event reaches the pane, a
        // gap makes the pane refetch, and the watchdog's visibility gate is answered by the shell. The
        // counters are the test's observation point — bumped after the pane finished, so "the refetch
        // landed" is a signal, not a poll of `model.post(id:)` or `rail.socketResyncCount`.
        let delivered = SignalCounter()
        let resynced = SignalCounter()
        rail.onTeamEvent = { [weak pane] serverID, event in
            Task {
                await pane?.handle(event, serverID: serverID)
                delivered.bump()
            }
        }
        rail.onSocketResync = { [weak pane] serverID in
            Task {
                await pane?.resync(serverID: serverID)
                resynced.bump()
            }
        }
        rail.isSurfaceVisible = { _ in visible }
        await rail.activate(server)
        return AppHarness(rail: rail, pane: pane, source: source, channelService: channelService,
                          factory: factory, server: server,
                          transport: transports.isEmpty ? ScriptedSocketTransport() : transports[0],
                          delivered: delivered, resynced: resynced)
    }

    /// How many times each duration has been stepped in this test, so `step` waits for the *next* park of
    /// that duration and not one that already happened.
    private var steppedParks: [TimeInterval: Int] = [:]

    /// Release one parked sleep of `seconds` on a `SteppedSocketClock`, waiting until it is parked.
    ///
    /// The wait is a signal (`parkSignal`), not a poll: the clock records each park with its ordinal, so
    /// the second 30 s sleep is awaitable even though the first one is already history.
    private func step(_ clock: SteppedSocketClock, _ seconds: TimeInterval,
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

    // MARK: - The card's scenario

    /// Open and pingable, delivering nothing: the pane refetches within the watchdog's window.
    ///
    /// This is the test the card asks for. The transport answers **every** ping with the protocol's pong
    /// and pushes no server event, so the socket is provably alive on the heartbeat and provably carrying
    /// nothing — the state `handleOpen`'s resync can never see. Without the watchdog the lost `b` stays
    /// lost until relaunch, exactly as measured in T34-R5.
    func testASilentButPingableSocketRefetchesTheOpenWindow() async throws {
        let a = post("a", at: 1_000)
        let b = post("b", at: 2_000)
        let clock = SteppedSocketClock()
        let transport = ScriptedSocketTransport(answersPingsWithPong: true)
        let harness = await makeHarness(pages: [list([a]), list([b, a])],
                                        transports: [transport],
                                        clock: clock,
                                        now: clock.provider,
                                        heartbeat: heartbeatInterval,
                                        visible: true)
        let model = try XCTUnwrap(harness.pane.activeModel(serverID: harness.server.id, channelID: channelID))
        XCTAssertEqual(model.loadedPostIDs, ["a"], "the pane starts on the newest page")
        XCTAssertEqual(harness.channelService.firstPageRequests, 1)

        await awaitSignal("the first connection", signal: harness.factory.createdSignal) { $0 == 1 }
        transport.push(.opened)
        await awaitSignal("the authentication challenge", signal: transport.sentSignal) {
            $0.contains("authentication_challenge")
        }
        XCTAssertEqual(harness.rail.socketResyncCount, 0, "a first connect is not a gap")

        // The heartbeat's own evidence: two pings, two pongs, no event. The second ping is only safe if
        // the first pong was consumed (the heartbeat recycles on one missed pong), so this pair proves
        // the socket is *pingable* while delivering nothing — the distinction the watchdog exists for.
        await step(clock, heartbeatInterval)
        await awaitSignal("the first ping", signal: transport.pongSignal) { $0 == 1 }
        await step(clock, heartbeatInterval)
        // `heartbeatTick` recycles when `missedPongs >= maxMissedPongs` and only otherwise writes the
        // ping, so a *second* answered ping is itself the proof that the first pong was folded before
        // the next tick was released — no settle for it (kanban t_00fb623c).
        await awaitSignal("the second ping", signal: transport.pongSignal) { $0 == 2 }
        XCTAssertEqual(harness.factory.created.count, 1, "the pong was consumed, so no recycle happened")
        XCTAssertEqual(harness.rail.socketResyncCount, 0, "a pong is liveness, not delivery")

        // No server event for the window while the channel is on screen ⇒ a gap, repaired.
        await step(clock, watchdog.checkInterval)
        await awaitSignal("the stalled delivery to be repaired", signal: harness.resynced.signal) { $0 == 1 }
        XCTAssertNotNil(model.post(id: "b"), "the refetch is what puts the lost post on screen")

        XCTAssertEqual(model.loadedPostIDs, ["b", "a"], "the window is the server's, in its order")
        XCTAssertEqual(harness.channelService.firstPageRequests, 2, "one load plus exactly one stall sweep")
        XCTAssertEqual(model.resyncCount, 1)
        XCTAssertEqual(model.lastResyncInsertedCount, 1)
        XCTAssertEqual(harness.pane.resyncCount, 1)
        XCTAssertEqual(harness.rail.socketResyncCount, 1, "one gap, one refetch")
        XCTAssertEqual(harness.source.stallResyncCount, 1, "and it was found by silence, not by a reconnect")
        XCTAssertEqual(model.phase, .loaded)
    }

    /// The negative half, and the card's second assertion: a healthy-but-quiet socket with **nothing on
    /// screen** must not resync. Otherwise every backgrounded app with a phone in a pocket would sweep
    /// six warm windows every few minutes, and the watchdog would be a poll.
    func testAQuietSocketWithNothingOnScreenDoesNotRefetch() async throws {
        let a = post("a", at: 1_000)
        let b = post("b", at: 2_000)
        let clock = SteppedSocketClock()
        let transport = ScriptedSocketTransport(answersPingsWithPong: true)
        let harness = await makeHarness(pages: [list([a]), list([b, a])],
                                        transports: [transport],
                                        clock: clock,
                                        now: clock.provider,
                                        heartbeat: heartbeatInterval,
                                        visible: false)
        let model = try XCTUnwrap(harness.pane.activeModel(serverID: harness.server.id, channelID: channelID))

        await awaitSignal("the first connection", signal: harness.factory.createdSignal) { $0 == 1 }
        transport.push(.opened)
        await awaitSignal("the authentication challenge", signal: transport.sentSignal) {
            $0.contains("authentication_challenge")
        }

        // Well past the window: 30 s of heartbeat plus three checks. The 150 ms at the end is a fixed
        // *absence* window (pile b): there is no event for "the watchdog did not fire", so a bounded
        // settle is the only way to give a wrong fire the chance to happen.
        await step(clock, heartbeatInterval)
        for _ in 0..<3 { await step(clock, watchdog.checkInterval) }
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertNil(model.post(id: "b"))
        XCTAssertEqual(harness.channelService.firstPageRequests, 1, "nothing on screen is not a gap")
        XCTAssertEqual(harness.pane.resyncCount, 0)
        XCTAssertEqual(harness.rail.socketResyncCount, 0)
        XCTAssertEqual(harness.source.stallResyncCount, 0)
    }

    /// No double fire with `handleOpen`'s resync, and the watchdog's window restarts at the open.
    ///
    /// A reconnect already refetched (`T34SocketResyncTests`), so the watchdog must not add a second
    /// sweep for the same gap — and it must not be *suppressed* forever either: a socket that reconnects
    /// and then stays silent is the wedge again, one window later.
    func testAReconnectDoesNotDoubleFireAndRestartsTheWatchdogsWindow() async throws {
        let a = post("a", at: 1_000)
        let now = TestNow()
        let clock = InstantSocketClock()
        let first = ScriptedSocketTransport()
        let second = ScriptedSocketTransport()
        let harness = await makeHarness(pages: [list([a])],
                                        transports: [first, second],
                                        clock: clock,
                                        now: now.provider,
                                        heartbeat: nil,
                                        visible: true)
        let model = try XCTUnwrap(harness.pane.activeModel(serverID: harness.server.id, channelID: channelID))

        await awaitSignal("the first connection", signal: harness.factory.createdSignal) { $0 == 1 }
        first.push(.opened)
        await awaitSignal("the authentication challenge", signal: first.sentSignal) {
            $0.contains("authentication_challenge")
        }
        XCTAssertEqual(harness.rail.socketResyncCount, 0)

        first.close()
        await awaitSignal("the reconnect", signal: harness.factory.createdSignal) { $0 == 2 }
        second.push(.opened)
        await awaitSignal("the reconnect's own resync", signal: harness.resynced.signal) { $0 == 1 }
        XCTAssertEqual(harness.channelService.firstPageRequests, 2, "one load plus the reconnect sweep")
        XCTAssertEqual(harness.source.stallResyncCount, 0)

        // Below the window since the open: the watchdog must stay quiet. Absence, so a fixed settle.
        now.advance(watchdog.threshold - 10)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(harness.rail.socketResyncCount, 1, "the open reset the watchdog's clock")
        XCTAssertEqual(model.resyncCount, 1)

        // Past the window, still silent: that *is* the wedge again, and it is repaired again.
        now.advance(20)
        await awaitSignal("the stall after the reconnect", signal: harness.resynced.signal) { $0 == 2 }
        XCTAssertEqual(harness.source.stallResyncCount, 1)
        XCTAssertEqual(harness.pane.resyncCount, 2)
        XCTAssertEqual(harness.channelService.firstPageRequests, 3)
    }

    /// A socket that keeps carrying events is never treated as stalled, however fast virtual time runs.
    func testASocketThatKeepsDeliveringIsNeverTreatedAsStalled() async throws {
        let a = post("a", at: 1_000)
        let now = TestNow()
        let clock = InstantSocketClock()
        let transport = ScriptedSocketTransport()
        let harness = await makeHarness(pages: [list([a])],
                                        transports: [transport],
                                        clock: clock,
                                        now: now.provider,
                                        heartbeat: nil,
                                        visible: true)
        let model = try XCTUnwrap(harness.pane.activeModel(serverID: harness.server.id, channelID: channelID))

        await awaitSignal("the first connection", signal: harness.factory.createdSignal) { $0 == 1 }
        transport.push(.opened)
        await awaitSignal("the authentication challenge", signal: transport.sentSignal) {
            $0.contains("authentication_challenge")
        }

        // Four events, each a little under the window apart: 120 virtual seconds of a *live* socket.
        // Each post is awaited as the pane's delivery signal, so "it arrived" is not a poll.
        for index in 0..<4 {
            now.advance(watchdog.threshold - 10)
            let id = "live-\(index)"
            transport.pushEvent("posted", seq: index + 1,
                                data: ["post": try Self.postJSON(post(id, at: 3_000 + Int64(index)))])
            await awaitSignal("the delivered post \(id)", signal: harness.delivered.signal) {
                $0 == index + 1
            }
            XCTAssertNotNil(model.post(id: id), "the socket's frame reached the window")
        }
        // Absence window: no event exists for "the watchdog did not fire".
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(harness.rail.socketResyncCount, 0, "events are delivery: no gap")
        XCTAssertEqual(harness.source.stallResyncCount, 0)
        XCTAssertEqual(harness.channelService.firstPageRequests, 1)
        XCTAssertEqual(model.resyncCount, 0)
    }

    /// A client that cannot answer "is anything on screen?" does not start a watchdog at all.
    ///
    /// This is the shape that must never pass silently: a `StallWatchdog` configured with no visibility
    /// predicate would have to guess, and guessing means either refetching for an idle socket (a poll) or
    /// never refetching (the defect). `SocketTeamEventSource` logs the state when it builds such a client.
    func testAClientWithoutAVisibilityPredicateNeverStartsWithAWatchdog() async throws {
        let clock = SteppedSocketClock()
        let transport = ScriptedSocketTransport()
        let factory = ScriptedTransportFactory([transport])
        let recorder = ResyncRecorder()
        let client = SocketClient(
            configuration: SocketClient.Configuration(
                url: URL(string: "wss://mm.example.com/api/v4/websocket")!,
                token: "tok-socket",
                origin: "https://mm.example.com",
                pingInterval: nil,
                stallWatchdog: watchdog),
            transportFactory: { url, headers in factory.make(url, headers) },
            clock: clock,
            now: clock.provider,
            resync: { reason in await recorder.record(reason) })
        await client.start()
        await awaitSignal("the transport", signal: factory.createdSignal) { $0 == 1 }
        transport.push(.opened)
        await awaitSignal("the authentication challenge", signal: transport.sentSignal) {
            $0.contains("authentication_challenge")
        }

        XCTAssertEqual(clock.parked(watchdog.checkInterval), 0,
                       "no visibility answer ⇒ no watchdog loop at all")
        clock.advance(watchdog.threshold * 4)
        // Absence window: no loop exists to publish "I did not fire".
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(recorder.reasons, [])
        let delivered = await client.deliveredEventCount
        XCTAssertEqual(delivered, 0)
        await client.stop()
    }

    /// Records the reasons the client asked for a resync with.
    @MainActor
    final class ResyncRecorder {
        private(set) var reasons: [SocketClient.ResyncReason] = []
        func record(_ reason: SocketClient.ResyncReason) { reasons.append(reason) }
    }

    /// The post row as the socket carries it: `data.post` is a JSON **string**, encoded from `MMPost`
    /// (the row has ~15 required keys; a hand-built frame that misses one is dropped by the decoder).
    static func postJSON(_ post: MMPost) throws -> String {
        let data = try JSONEncoder().encode(post)
        return String(decoding: data, as: UTF8.self)
    }
}
