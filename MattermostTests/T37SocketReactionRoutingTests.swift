import XCTest
@testable import Mattermost

/// T37-R — F1: a reaction that **another client** wrote must reach the open pane.
///
/// The T37-AV round measured the defect end to end: the server pushed `reaction_added` to this app's
/// own user (`av-ws-watch.log`, twice), a foreign `posted` on the same socket arrived, and the
/// reaction never drew a pill in 30 s (`av-t37-socket.log`, `av-t37-contrast.log`). The cause was one
/// gate: `TeamSocketScope.accepts` refused the reaction event types, and that scope is the **only**
/// route from the one socket into the channel and thread panes
/// (`MattermostApp.swift` → `TeamSidebarCoordinator.onTeamEvent` → `ChannelPaneCoordinator.handle`).
///
/// The card's own unit tests called `ChannelViewModel.handle(.reactionAdded(…))` directly, which is
/// why the gate shipped untested. So this file pins the three links that run in the app, in order:
///
///  1. the wire frame carries the reaction's `channel_id` into the typed event (measured payload);
///  2. the scope attributes a reaction to the team on screen instead of refusing every one;
///  3. the event reaches a pane's **model** through the rail's coordinator and
///     `onTeamEvent` — the production fan-in — not by calling `handle` on the model.
@MainActor
final class T37SocketReactionRoutingTests: XCTestCase {

    // MARK: - Fixtures

    private var suiteName: String!
    private var defaults: UserDefaults!
    /// `NativeNavigation.serverStore` is weak, so the test has to own the store for the life of the
    /// case — otherwise routing answers `.needsServerAdd` and the location never names a server.
    private var retainedStores: [ServerStore] = []

    override func setUp() {
        super.setUp()
        suiteName = "T37SocketReactionRoutingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func preferences() -> AppPreferences { AppPreferences(defaults: defaults) }

    private func server() -> ServerConfig {
        ServerConfig(name: "Local", url: URL(string: "https://mm.example")!)
    }

    // MARK: - 1. The measured frame carries its channel

    /// The frame shape is not a guess: it is the one `av-ws-watch.log` captured from 9.11.19, where the
    /// reaction is a **JSON string** and the channel lives *inside* it (the scope's old comment claimed
    /// a reaction "names a post, not a channel" — it names both).
    func testTheMeasuredReactionFrameCarriesItsChannelIntoTheEvent() throws {
        let frame = try JSONDecoder().decode(MMSocketFrame.self, from: Data(#"""
        {"event":"reaction_added","seq":7,"data":{"reaction":"{\"user_id\":\"e1i1fb9qy3gupkhsxitibaqkjh\",\"post_id\":\"ymaxujxbwbro9eftrpy3zx6fpo\",\"emoji_name\":\"tada\",\"create_at\":1700000000000,\"channel_id\":\"psw97y5zqpfnpembwxraizuije\"}"},"broadcast":{"user_id":"","channel_id":"","team_id":""}}
        """#.utf8))

        guard case .reactionAdded(let reaction)? = SocketEvent(frame: frame) else {
            return XCTFail("a measured reaction_added frame must decode into a typed event")
        }
        XCTAssertEqual(reaction.postId, "ymaxujxbwbro9eftrpy3zx6fpo")
        XCTAssertEqual(reaction.emojiName, "tada")
        XCTAssertEqual(reaction.userId, "e1i1fb9qy3gupkhsxitibaqkjh")
        XCTAssertEqual(reaction.channelId, "psw97y5zqpfnpembwxraizuije",
                       "the channel is what lets the scope attribute the reaction to a team")
    }

    /// A remove takes the same path (the app must not keep a pill the server no longer holds), and a
    /// frame whose reaction object is stripped of `channel_id` must still decode rather than be
    /// dropped — the client tolerates a payload it cannot attribute.
    func testAReactionFrameWithoutAChannelStillDecodes() throws {
        let frame = try JSONDecoder().decode(MMSocketFrame.self, from: Data(#"""
        {"event":"reaction_removed","seq":8,"data":{"reaction":"{\"user_id\":\"u2\",\"post_id\":\"p1\",\"emoji_name\":\"smile\",\"create_at\":1}"}}
        """#.utf8))
        guard case .reactionRemoved(let reaction)? = SocketEvent(frame: frame) else {
            return XCTFail("a reaction_removed frame must decode into a typed event")
        }
        XCTAssertEqual(reaction.userId, "u2")
        XCTAssertEqual(reaction.channelId, "", "no channel on the wire, no channel on the event")
    }

    // MARK: - 2. The scope attributes a reaction instead of refusing it

    /// The gate that shipped untested. Three cases, because they are three different answers:
    /// the open channel (attributable without the channel→team map), a channel the directory maps to
    /// the team on screen, and a channel of another team (refused — the scope's whole purpose).
    func testTheScopeAttributesAReactionByItsChannel() {
        let scope = TeamSocketScope(teamID: "team1", activeChannelID: "c1",
                                    channelTeams: ["c2": "team1", "x1": "team2"])

        XCTAssertTrue(scope.accepts(.reactionAdded(
            MMReaction(userId: "u2", postId: "p1", emojiName: "tada", createAt: 1, channelId: "c1"))),
                      "a reaction in the channel on screen belongs to the team on screen")
        XCTAssertTrue(scope.accepts(.reactionAdded(
            MMReaction(userId: "u2", postId: "p2", emojiName: "tada", createAt: 1, channelId: "c2"))),
                      "a reaction in another channel of the active team must arrive too")
        XCTAssertTrue(scope.accepts(.reactionRemoved(
            MMReaction(userId: "u2", postId: "p2", emojiName: "tada", createAt: 1, channelId: "c2"))),
                      "a removal is attributed exactly like an add")
        XCTAssertFalse(scope.accepts(.reactionAdded(
            MMReaction(userId: "u2", postId: "p9", emojiName: "tada", createAt: 1, channelId: "x1"))),
                       "another team's reaction must not reach the surface on screen")
        XCTAssertFalse(scope.accepts(.reactionRemoved(
            MMReaction(userId: "u2", postId: "p9", emojiName: "tada", createAt: 1, channelId: "x1"))))
    }

    /// An unattributable reaction (a proxy frame with the channel stripped) is **accepted**, and every
    /// pane keeps only its own posts (`postsByID[reaction.postId] != nil`), so a delivery into the wrong
    /// team's surface reaches no model at all. Same reasoning the scope already uses for
    /// `threadFollowChanged`: refusing would only make an open pane miss its own event.
    func testAnUnattributableReactionIsAcceptedAndEachPaneFiltersByPost() {
        let scope = TeamSocketScope(teamID: "team1", activeChannelID: "c1")
        XCTAssertTrue(scope.accepts(.reactionAdded(
            MMReaction(userId: "u2", postId: "p1", emojiName: "tada", createAt: 1))))
    }

    /// With no team selected the scope accepts everything (its stated rule), so a reaction that lands
    /// before the rail has resolved a team is not silently lost. This is the state the app is in for
    /// the first moments after launch.
    func testAReactionIsAcceptedBeforeAnyTeamIsSelected() {
        XCTAssertTrue(TeamSocketScope().accepts(.reactionAdded(
            MMReaction(userId: "u2", postId: "p1", emojiName: "tada", createAt: 1, channelId: "c1"))))
    }

    // MARK: - 3. The production fan-in reaches the pane's model

    /// The regression test for the defect itself: a `reaction_added` arrives on the rail's socket, the
    /// rail's scope admits it, `onTeamEvent` hands it to the pane coordinator exactly as
    /// `MattermostApp` wires it (`Task { await channelPaneCoordinator?.handle(event, serverID:) }`),
    /// and the row in the open channel grows its pill. Nothing here calls
    /// `ChannelViewModel.handle` — that is the bypass the old tests used and the reason this shipped.
    func testASocketReactionReachesTheOpenPanesRowThroughTheRail() async {
        let server = server()
        let navigation = makeNavigation([server])
        _ = navigation.activate(serverID: server.id)

        let events = T37RFakeTeamEventSource()
        let railService = T37RFakeTeamSidebarService()
        railService.data = TeamSidebarData(teams: [MMTeam(id: "perf", name: "perf", displayName: "Perf")],
                                           memberships: [MMTeamMembership(userId: "me", teamId: "perf",
                                                                          roles: "team_user")],
                                           unreads: [MMTeamUnread(teamId: "perf")],
                                           order: ["perf"])
        let rail = TeamSidebarCoordinator(events: events,
                                         unreadRefreshDelay: 0.01,
                                         makeService: { _ in railService },
                                         tokenProvider: { _ in "tok-t37r" })
        rail.bind(auth: AuthCoordinator(), navigation: navigation, serverStore: nil)

        let channelService = T37RFakeChannelService(pageSize: 3,
                                               firstPages: [MMPostList(
                                                order: ["p1"],
                                                posts: ["p1": MMPost(id: "p1", createAt: 1_000,
                                                                     userId: "u1", channelId: "c1",
                                                                     message: "react to me")])])
        let panes = ChannelPaneCoordinator()
        panes.serviceFactory = { _ in channelService }
        // The one line of app wiring this test exists to exercise. The counter is bumped after the pane
        // finished handling the event, so "the row grew its pill" is a signal, not a poll of the model.
        let delivered = SignalCounter()
        rail.onTeamEvent = { serverID, event in
            Task {
                await panes.handle(event, serverID: serverID)
                delivered.bump()
            }
        }

        await rail.activate(server)
        await awaitSignal("the rail subscribes its one socket", signal: events.subscribedSignal) { $0 == 1 }

        // The reader is looking at channel c1 of team perf — that is what the scope is built from.
        _ = navigation.openChannel(NativeChannelRequest(serverID: server.id,
                                                        teamID: "perf",
                                                        channelID: "c1"))
        let scope = rail.scope(for: server.id)
        XCTAssertEqual(scope?.teamID, "perf", "the scope must follow the open channel's team")
        XCTAssertEqual(scope?.activeChannelID, "c1", "the scope must know the open channel")
        let model = panes.model(for: server, channelID: "c1", channelName: "town")
        await model.load()
        XCTAssertEqual(model.loadedPostIDs, ["p1"], "the fixture row must be in the window first")
        XCTAssertTrue(pillNames(model, postID: "p1").isEmpty)

        // Another client reacts. Only the socket can deliver this.
        events.emit(.reactionAdded(MMReaction(userId: "u2", postId: "p1", emojiName: "tada",
                                              createAt: 5_000, channelId: "c1")),
                    serverID: server.id)
        await awaitSignal("the foreign reaction reaches the open pane's row",
                          signal: delivered.signal) { $0 == 1 }
        XCTAssertEqual(pillNames(model, postID: "p1"), ["tada"],
                       "the foreign reaction must draw its pill")
        XCTAssertEqual(rail.refusedEventCount, 0,
                       "the reaction must be delivered, not refused — that refusal was the defect")

        // The control the AV card used: another team's channel is still refused by the scope, so the
        // fix cannot be "accept everything the socket says".
        //
        // A refusal publishes nothing (the scope's answer *is* the absence of a delivery), so the wait is
        // a **fence**: an accepted but inert removal for a post this window does not hold is emitted
        // right after it. The pump consumes the stream in order, so the fence's delivery proves the
        // refused event was already handled, and the counter read next is settled.
        events.emit(.reactionAdded(MMReaction(userId: "u3", postId: "p1", emojiName: "smile",
                                              createAt: 5_100, channelId: "other-team-channel")),
                    serverID: server.id)
        events.emit(.reactionRemoved(MMReaction(userId: "u3", postId: "not-in-this-window",
                                                emojiName: "tada", createAt: 5_150, channelId: "c1")),
                    serverID: server.id)
        await awaitSignal("the fence after the other team's reaction",
                          signal: delivered.signal) { $0 == 2 }
        XCTAssertEqual(rail.refusedEventCount, 1, "another team's reaction is refused")
        XCTAssertEqual(pillNames(model, postID: "p1"), ["tada"],
                       "the surface on screen must not draw another team's reaction")

        // And a removal by that client takes the pill away again.
        events.emit(.reactionRemoved(MMReaction(userId: "u2", postId: "p1", emojiName: "tada",
                                                createAt: 5_200, channelId: "c1")),
                    serverID: server.id)
        await awaitSignal("the foreign removal reaches the pane", signal: delivered.signal) { $0 == 3 }
        XCTAssertTrue(pillNames(model, postID: "p1").isEmpty, "the pill is cleared")
    }

    /// The thread pane hangs off the same gate (`MattermostApp` feeds the same `onTeamEvent` into
    /// `ThreadCoordinator`), so the scope's answer for a reaction is the thread pane's answer too. This
    /// pins the routing half for threads; the live suite does not drive a thread-pane reaction (recorded
    /// as undriven in `docs/t37-build-note.md`).
    func testTheSameGateAdmitsAReactionForTheThreadPanesServer() {
        let scope = TeamSocketScope(teamID: "team1", activeChannelID: "c1",
                                    channelTeams: ["c2": "team1"])
        XCTAssertTrue(scope.accepts(.reactionAdded(
            MMReaction(userId: "u2", postId: "root", emojiName: "tada", createAt: 1, channelId: "c2"))),
                      "a thread pane on a channel of the active team receives its reactions")
    }

    // MARK: - Helpers

    private func pillNames(_ model: ChannelViewModel, postID: String) -> [String] {
        model.items.compactMap { item -> PostRowModel? in
            if case .post(let row) = item, row.id == postID { return row }
            return nil
        }.first?.reactions.map(\.emojiName) ?? []
    }

    private func makeNavigation(_ servers: [ServerConfig]) -> NativeNavigation {
        let store = ServerStore(preferences: preferences())
        for server in servers { _ = store.add(server) }
        retainedStores.append(store)
        let resolver = SurfaceModeResolver(preferences: preferences(),
                                          arguments: ["-surfaceMode", "shell=native"])
        let navigation = NativeNavigation(resolver: resolver)
        navigation.serverStore = store
        navigation.viewStore = ViewStore()
        navigation.authGate = T37RFixedAuthGate()
        return navigation
    }
}

// MARK: - Seams

@MainActor
private final class T37RFixedAuthGate: NativeAuthGate {
    func authState(for server: ServerConfig) -> NativeAuthState { .signedIn }
}

@MainActor
private final class T37RFakeTeamSidebarService: TeamSidebarServing {
    var data = TeamSidebarData()

    func load() async throws -> TeamSidebarData { data }
    func unreads() async throws -> [MMTeamUnread] { data.unreads }
    func icon(for teamID: String, lastUpdateAt: Int64) async -> Data? { nil }
}

/// A scripted socket: one stream per server, events pushed by the test.
@MainActor
private final class T37RFakeTeamEventSource: TeamEventSourcing {
    private(set) var isSubscribed = false
    private(set) var openConnectionCount = 0
    private var continuations: [UUID: AsyncStream<SocketEvent>.Continuation] = [:]
    /// Fires with the running count of `events(for:token:)` calls — the subscription as a signal.
    let subscribedSignal = TestSignal<Int>()
    private var subscriptions = 0

    func events(for server: ServerConfig, token: String) async -> AsyncStream<SocketEvent>? {
        subscriptions += 1
        subscribedSignal.send(subscriptions)
        let (stream, continuation) = AsyncStream.makeStream(of: SocketEvent.self,
                                                           bufferingPolicy: .bufferingNewest(64))
        if continuations[server.id] == nil { openConnectionCount += 1 }
        continuations[server.id] = continuation
        isSubscribed = true
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

/// The channel pane's server, answering one canned page.
@MainActor
private final class T37RFakeChannelService: ChannelServing {
    let pageSize: Int
    var firstPages: [MMPostList]
    private var served = 0

    init(pageSize: Int, firstPages: [MMPostList]) {
        self.pageSize = pageSize
        self.firstPages = firstPages
    }

    func channel(id: String) async throws -> MMChannel {
        MMChannel(id: id, name: "town", displayName: "Town", type: "O", teamId: "perf")
    }

    func posts(channelID: String, before: String?, perPage: Int) async throws -> MMPostList {
        if before == nil {
            let slot = min(served, max(0, firstPages.count - 1))
            served += 1
            return firstPages.isEmpty ? MMPostList(order: [], posts: [:]) : firstPages[slot]
        }
        return MMPostList(order: [], posts: [:])
    }

    func users(ids: [String]) async throws -> [MMUser] { [] }
    func fileData(fileID: String, preferThumbnail: Bool) async throws -> Data { throw MMError.notFound }
    func membership(channelID: String) async throws -> MMChannelMember? { nil }
}
