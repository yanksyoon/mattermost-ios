import XCTest
@testable import Mattermost

/// T43-R (F3) — **when** a server's socket counts as live.
///
/// The AC1 live test asks the Settings read-out for `liveSockets == 1` and only then posts a mention,
/// so that reading is a promise: "a mention posted now will arrive on this connection". T43 reported it
/// from `SocketClient.start()`, which is fire-and-forget (it spawns the connect loop and returns), so the
/// read-out could say "live" before the WebSocket handshake had happened — and a mention posted in that
/// window was lost. Measured: `testASocketMentionReachesTheShellOnce` failed once in four executions,
/// reading `none` after its 40 s wait.
///
/// The rule this file pins: liveness is reported on the **first event the server sends** (the protocol's
/// `hello` is the first one on every connection), never on the stream object's creation, and it is
/// withdrawn when the pump ends.
@MainActor
final class T43RSocketLivenessTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var retainedStores: [ServerStore] = []

    override func setUp() {
        super.setUp()
        suiteName = "T43RSocketLiveness-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        retainedStores.removeAll()
        super.tearDown()
    }

    private func server() -> ServerConfig {
        ServerConfig(name: "Local", url: URL(string: "http://127.0.0.1:8065")!)
    }

    private func navigation(_ servers: [ServerConfig]) -> NativeNavigation {
        let store = ServerStore(preferences: AppPreferences(defaults: defaults))
        for server in servers { _ = store.add(server) }
        retainedStores.append(store)
        let resolver = SurfaceModeResolver(preferences: AppPreferences(defaults: defaults),
                                           arguments: ["-surfaceMode", "shell=native"])
        let navigator = NativeNavigation(resolver: resolver)
        navigator.serverStore = store
        navigator.viewStore = ViewStore()
        navigator.authGate = T43RFixedAuthGate()
        return navigator
    }

    private func coordinator(_ events: T43RScriptedSocket,
                             navigation: NativeNavigation) -> TeamSidebarCoordinator {
        let coordinator = TeamSidebarCoordinator(events: events,
                                                 unreadRefreshDelay: 0.01,
                                                 makeService: { _ in T43RTinySidebarService() },
                                                 tokenProvider: { _ in "tok-t43r" })
        coordinator.bind(auth: AuthCoordinator(), navigation: navigation, serverStore: nil)
        return coordinator
    }

    // MARK: - The rule

    func testAStreamIsNotALiveSocket() async {
        let server = self.server()
        let events = T43RScriptedSocket()
        let coordinator = self.coordinator(events, navigation: navigation([server]))
        var states: [Bool] = []
        coordinator.onSocketStateChange = { _, live in states.append(live) }

        await coordinator.activate(server)
        await awaitSignal("the pump subscribes", signal: events.connectSignal) { $0 == 1 }
        // Absence check (pile b): "no report was made" has no event. Yielding only lets pending tasks
        // run; it is not a deadline for a value to arrive in.
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(events.connectCount, 1, "the pump exists")
        XCTAssertEqual(coordinator.subscriptionCount, 1)
        XCTAssertEqual(states, [],
                       "a created stream is not a connected socket: the handshake has not happened yet, "
                       + "and reporting it live is what lost a mention in the AC1 flake (F3)")
    }

    func testLivenessIsReportedWhenTheServersHelloArrives() async {
        let server = self.server()
        let events = T43RScriptedSocket()
        let coordinator = self.coordinator(events, navigation: navigation([server]))
        var states: [Bool] = []
        let live = TestSignal<Bool>()
        coordinator.onSocketStateChange = { _, isLive in
            states.append(isLive)
            live.send(isLive)
        }

        await coordinator.activate(server)
        // Subscribe first: an event emitted before the fake has a continuation would be dropped by the
        // fake, not by the code under test (the first draft of this file measured exactly that).
        await awaitSignal("the pump subscribes", signal: events.connectSignal) { $0 == 1 }
        XCTAssertEqual(states, [])

        events.emit(.hello(SocketHello(connectionID: "conn-1", serverVersion: "9.11.19")),
                    serverID: server.id)
        await awaitSignal("the hello is consumed and the socket reported live", signal: live) { $0 }
        XCTAssertEqual(states, [true], "one report, on the server's first event")
    }

    func testASecondEventDoesNotReportLivenessTwice() async {
        let server = self.server()
        let events = T43RScriptedSocket()
        let coordinator = self.coordinator(events, navigation: navigation([server]))
        var states: [Bool] = []
        let live = TestSignal<Bool>()
        coordinator.onSocketStateChange = { _, isLive in
            states.append(isLive)
            live.send(isLive)
        }
        // Every event the pump hands on, in order — the signal form of
        // `deliveredEventCount + refusedEventCount` (which is a poll of two counters).
        let consumed = SignalCounter()
        coordinator.onServerEvent = { _, _ in consumed.bump() }

        await coordinator.activate(server)
        await awaitSignal("the pump subscribes", signal: events.connectSignal) { $0 == 1 }
        events.emit(.hello(SocketHello(connectionID: "conn-1", serverVersion: "9.11.19")),
                    serverID: server.id)
        await awaitSignal("the hello is consumed", signal: live) { $0 }
        events.emit(.posted(MMPost(id: "p1", createAt: 1, deleteAt: 0, userId: "u1",
                                   channelId: "c1", message: "hi", type: "")),
                    serverID: server.id)
        await awaitSignal("both events are consumed", signal: consumed.signal) { $0 >= 2 }

        XCTAssertEqual(states, [true], "liveness is a state, not a per-event counter")
    }

    func testAFinishedPumpWithdrawsLiveness() async {
        let server = self.server()
        let events = T43RScriptedSocket()
        let coordinator = self.coordinator(events, navigation: navigation([server]))
        var states: [Bool] = []
        let live = TestSignal<Bool>()
        coordinator.onSocketStateChange = { _, isLive in
            states.append(isLive)
            live.send(isLive)
        }

        await coordinator.activate(server)
        await awaitSignal("the pump subscribes", signal: events.connectSignal) { $0 == 1 }
        events.emit(.hello(SocketHello(connectionID: "conn-1", serverVersion: "9.11.19")),
                    serverID: server.id)
        await awaitSignal("live first", signal: live) { $0 }

        await events.close(serverID: server.id)
        await awaitSignal("the pump ends and liveness is withdrawn", signal: live) { !$0 }
        XCTAssertEqual(states, [true, false])
    }
}

// MARK: - Doubles

@MainActor
private final class T43RFixedAuthGate: NativeAuthGate {
    func authState(for server: ServerConfig) -> NativeAuthState { .signedIn }
}

/// The rail's server: one team, nothing else — this file is about the socket's lifetime, not the rail.
@MainActor
private final class T43RTinySidebarService: TeamSidebarServing {
    func load() async throws -> TeamSidebarData {
        TeamSidebarData(teams: [MMTeam(id: "t1", name: "t1", displayName: "T1",
                                       lastTeamIconUpdatedAt: 0, deleteAt: 0)],
                        memberships: [MMTeamMembership(userId: "me", teamId: "t1", roles: "team_user",
                                                       deleteAt: 0)],
                        unreads: [MMTeamUnread(teamId: "t1", mentionCount: 0, msgCount: 0)],
                        order: ["t1"],
                        unreadsFailed: false)
    }

    func unreads() async throws -> [MMTeamUnread] {
        [MMTeamUnread(teamId: "t1", mentionCount: 0, msgCount: 0)]
    }

    func icon(for teamID: String, lastUpdateAt: Int64) async -> Data? { nil }
}

/// A scripted socket with **no** "connected" notion of its own — exactly the shape the real source has:
/// `events(for:token:)` returns a stream whether or not a handshake ever happens.
@MainActor
private final class T43RScriptedSocket: TeamEventSourcing {
    private(set) var connectCount = 0
    private(set) var openConnectionCount = 0
    private var continuations: [UUID: AsyncStream<SocketEvent>.Continuation] = [:]
    /// Fires with the running count of `events(for:token:)` calls — the pump's subscription as a
    /// signal instead of a poll of `connectCount`.
    let connectSignal = TestSignal<Int>()

    func events(for server: ServerConfig, token: String) async -> AsyncStream<SocketEvent>? {
        connectCount += 1
        connectSignal.send(connectCount)
        let (stream, continuation) = AsyncStream.makeStream(of: SocketEvent.self,
                                                            bufferingPolicy: .bufferingNewest(64))
        if continuations[server.id] == nil { openConnectionCount += 1 }
        continuations[server.id] = continuation
        return stream
    }

    func close(serverID: UUID) async {
        guard let continuation = continuations.removeValue(forKey: serverID) else { return }
        continuation.finish()
        openConnectionCount = max(0, openConnectionCount - 1)
    }

    func emit(_ event: SocketEvent, serverID: UUID) {
        continuations[serverID]?.yield(event)
    }
}
