// T34-R5 / T34-QA — the socket's other half: a reconnect must refetch what it may have missed.
//
// The finding (`docs/t34r5-build-note.md` §5, `docs/t34qa-build-note.md` §3): `SocketTeamEventSource`
// built every `SocketClient` **without** a `resync` closure, so a frame the server published while the
// connection was down was never delivered and never refetched — the miss was permanent until the app
// was relaunched. Nothing tested that path, which is why it survived two rounds of socket-flake
// diagnosis: the T28 tests pin the *client's* resync seam, and no test asked whether the app passed one.
//
// These tests are the path, end to end but without a network. A scripted transport stands in for the
// WebSocket, the **real** `SocketTeamEventSource` and `SocketClient` drive the reconnect, and the real
// `TeamSidebarCoordinator` → `ChannelPaneCoordinator` → `ChannelViewModel` chain does the refetch
// against a fake `ChannelServing`. That is what makes them fail if the `resync` closure goes away
// again: no fake stands in for the seam the defect was in.

import XCTest
@testable import Mattermost

@MainActor
final class T34SocketResyncTests: XCTestCase {

    // MARK: - Fakes

    /// A `ChannelServing` whose newest page can change between calls — which is exactly the shape of the
    /// bug: the post exists on the server and was never delivered over the socket.
    @MainActor
    final class FakeChannelService: ChannelServing {
        var pageSize: Int
        /// Answers for `before == nil`, consumed in order; the last one repeats.
        var firstPages: [MMPostList]
        /// Answers keyed by the `before` cursor.
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

    private func member(_ lastViewedAt: Int64) -> MMChannelMember {
        MMChannelMember(channelId: channelID, userId: "me", roles: "channel_user",
                        schemeAdmin: false, schemeUser: true, lastViewedAt: lastViewedAt,
                        msgCount: 0, mentionCount: 0, urgentMentionCount: 0,
                        lastUpdateAt: 0, manuallyUnread: false, notifyProps: nil)
    }

    /// The whole production chain for a socket resync: the real source (over a scripted transport), the
    /// real rail, the real pane coordinator and the real list model. Only the two servers are fake.
    private struct AppHarness {
        let rail: TeamSidebarCoordinator
        let pane: ChannelPaneCoordinator
        let channelService: FakeChannelService
        let factory: ScriptedTransportFactory
        let server: ServerConfig
    }

    private func makeHarness(pages: [MMPostList],
                             transports: [ScriptedSocketTransport]) async -> AppHarness {
        let channelService = FakeChannelService(pageSize: 60, firstPages: pages)
        let factory = ScriptedTransportFactory(transports)
        let source = SocketTeamEventSource(
            transportFactory: { url, headers, _ in factory.make(url, headers) },
            clock: TestSocketClock(autoRelease: true),
            heartbeatInterval: nil)
        let server = server()

        let pane = ChannelPaneCoordinator()
        pane.serviceFactory = { _ in channelService }
        pane.bind(auth: nil, navigation: nil, serverStore: nil)
        await pane.activate(server: server, channelID: channelID, channelName: "Town Square")

        let rail = TeamSidebarCoordinator(events: source,
                                          unreadRefreshDelay: 0,
                                          makeService: { _ in FakeTeamSidebarService() },
                                          tokenProvider: { _ in "tok-socket" })
        // The app's own two wirings (`MattermostApp.bindShellStores`): a delivered event reaches the pane,
        // and a reconnect makes the pane refetch. Reproduced here rather than called directly, because the
        // direction of both closures is part of what regressed.
        rail.onTeamEvent = { [weak pane] serverID, event in
            Task { await pane?.handle(event, serverID: serverID) }
        }
        rail.onSocketResync = { [weak pane] serverID in
            Task { await pane?.resync(serverID: serverID) }
        }
        await rail.activate(server)
        return AppHarness(rail: rail, pane: pane, channelService: channelService,
                          factory: factory, server: server)
    }

    /// Poll on the main actor until `condition` holds (the socket hops between its actor and this one, so
    /// nothing here is a fixed sleep on a wall-clock guess).
    private func waitUntil(_ what: String,
                           timeout: TimeInterval = 10,
                           file: StaticString = #filePath,
                           line: UInt = #line,
                           _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out after \(Int(timeout))s waiting for \(what)", file: file, line: line)
    }

    // MARK: - The card's scenario

    /// Kill the socket with the pane open, post over REST, restore the socket: the post appears without a
    /// relaunch. Without the `resync` closure this test cannot pass — the frame for `b` is never sent on
    /// either connection, which is what T34-R5 measured.
    func testAPostMadeWhileTheSocketWasDownAppearsAfterTheReconnect() async throws {
        let a = post("a", at: 1_000)
        let b = post("b", at: 2_000)
        // Page 1 is what the pane loaded; page 2 is what the server holds after the outage (both posts —
        // `a` again, so the merge is exercised for a row the window already had).
        let first = ScriptedSocketTransport()
        let second = ScriptedSocketTransport()
        let harness = await makeHarness(pages: [list([a]), list([b, a])], transports: [first, second])

        let model = try XCTUnwrap(harness.pane.activeModel(serverID: harness.server.id, channelID: channelID))
        XCTAssertEqual(model.loadedPostIDs, ["a"], "the pane starts on the newest page")

        // The socket comes up, then dies while the reader is looking at the channel.
        await waitUntil("the first connection") { harness.factory.created.count == 1 }
        first.push(.opened)
        await waitUntil("the authentication challenge on the first connection") {
            first.sent.contains { $0.contains("authentication_challenge") }
        }
        XCTAssertEqual(harness.rail.socketResyncCount, 0, "a first connect is not a reconnect")
        first.close()

        // Nothing is pushed on the second connection: the server published `b` while the socket was down
        // and does not replay it. Only a refetch can produce the row.
        await waitUntil("the reconnect") { harness.factory.created.count == 2 }
        second.push(.opened)

        await waitUntil("the lost post to appear without a relaunch") { model.post(id: "b") != nil }

        XCTAssertEqual(model.loadedPostIDs, ["b", "a"], "the window is the server's, in its order")
        XCTAssertEqual(harness.channelService.firstPageRequests, 2,
                       "one load plus exactly one refetch for the reconnect")
        XCTAssertEqual(model.resyncCount, 1)
        XCTAssertEqual(model.lastResyncInsertedCount, 1)
        XCTAssertEqual(harness.pane.resyncCount, 1)
        XCTAssertEqual(harness.rail.socketResyncCount, 1, "one reconnect, one resync")
        XCTAssertEqual(model.phase, .loaded)
    }

    /// The negative half: a *first* connect must not refetch. Without this, "resync on every open" would
    /// pass the test above and quietly double every cold start's page requests.
    func testAFirstConnectDoesNotRefetchTheWindowAndTheSocketStillDelivers() async throws {
        let a = post("a", at: 1_000)
        let x = post("x", at: 2_000)
        let first = ScriptedSocketTransport()
        let harness = await makeHarness(pages: [list([a])], transports: [first])

        let model = try XCTUnwrap(harness.pane.activeModel(serverID: harness.server.id, channelID: channelID))
        XCTAssertEqual(harness.channelService.firstPageRequests, 1)

        await waitUntil("the first connection") { harness.factory.created.count == 1 }
        first.push(.opened)
        await waitUntil("the authentication challenge") {
            first.sent.contains { $0.contains("authentication_challenge") }
        }
        // A live frame still travels the ordinary path: this is the control that proves the pump is up, so
        // "no refetch" below means "no refetch", not "nothing happened at all".
        first.pushEvent("posted", seq: 1, data: ["post": try Self.postJSON(x)])
        await waitUntil("the delivered post") { model.post(id: "x") != nil }

        XCTAssertEqual(harness.channelService.firstPageRequests, 1, "a first connect is not a gap")
        XCTAssertEqual(harness.rail.socketResyncCount, 0)
        XCTAssertEqual(model.resyncCount, 0)
    }

    /// The rail's handler must be read at call time: a handler installed after the connection was built
    /// (a test rig, or any future caller that wires late) still receives the reconnect.
    func testAHandlerInstalledAfterTheConnectionStillReceivesTheReconnect() async {
        let server = server()
        let first = ScriptedSocketTransport()
        let second = ScriptedSocketTransport()
        let factory = ScriptedTransportFactory([first, second])
        let source = SocketTeamEventSource(
            transportFactory: { url, headers, _ in factory.make(url, headers) },
            clock: TestSocketClock(autoRelease: true),
            heartbeatInterval: nil)

        let recorder = ResyncRecorder()
        let stream = await source.events(for: server, token: "tok")
        XCTAssertNotNil(stream)
        await waitUntil("the first connection") { factory.created.count == 1 }
        first.push(.opened)
        await waitUntil("the challenge") { first.sent.contains { $0.contains("authentication_challenge") } }

        // Installed *after* the client exists.
        source.setResyncHandler { serverID in await recorder.record(serverID) }

        first.close()
        await waitUntil("the reconnect") { factory.created.count == 2 }
        second.push(.opened)
        await waitUntil("the resync handler to run") { recorder.ids.count == 1 }
        XCTAssertEqual(recorder.ids, [server.id])
    }

    /// Records the server ids the source reports a reconnect for. Main-actor, so the test can read it from
    /// its polling condition; the handler hops here the same way the coordinator does.
    @MainActor
    final class ResyncRecorder {
        private(set) var ids: [UUID] = []
        func record(_ id: UUID) { ids.append(id) }
    }

    // MARK: - The merge rule

    /// The refetch is a **merge**: new rows are inserted, edited rows are refreshed in place, replies stay
    /// out (T34-R5's membership rule), and the older pages the reader loaded survive.
    func testAResyncMergesTheNewestPageAndKeepsTheOlderPagesTheReaderLoaded() async {
        let service = FakeChannelService(pageSize: 2, firstPages: [list([post("c", at: 3_000),
                                                                       post("b", at: 2_000)])])
        service.olderPages["b"] = list([post("a", at: 1_000)])
        let model = makeModel(service)

        await model.load()
        XCTAssertEqual(model.loadedPostIDs, ["c", "b"])
        _ = await model.loadEarlier()
        XCTAssertEqual(model.loadedPostIDs, ["c", "b", "a"], "the reader reached the older page")

        // While the socket was down: `d` was posted, `c` was edited, `e` is a reply to `c`.
        var reply = post("e", at: 5_000)
        reply.rootId = "c"
        service.firstPages = [list([reply,
                                    post("d", at: 4_000),
                                    post("c", at: 3_000, message: "c edited"),
                                    post("b", at: 2_000)])]

        let inserted = await model.resyncAfterReconnect()

        XCTAssertEqual(inserted, 1, "only `d` is new; `c`/`b` are already held and `e` is not a row")
        XCTAssertEqual(model.loadedPostIDs, ["d", "c", "b", "a"],
                       "new row at the top, the older page still loaded")
        XCTAssertEqual(model.post(id: "c")?.message, "c edited", "an edit made while down is picked up")
        XCTAssertNil(model.post(id: "e"), "a reply is not a row of this timeline")
        XCTAssertEqual(model.resyncCount, 1)
        XCTAssertEqual(model.phase, .loaded)
    }

    /// `last_viewed_at` moves with the refetch, and only forwards: a reader who caught up on another
    /// client gets the divider where the server says it is, and a stale answer cannot move it back.
    func testAResyncAdoptsALastViewedAtThatMovedForwardAndNeverMovesItBack() async {
        let service = FakeChannelService(pageSize: 60, firstPages: [list([post("a", at: 1_000),
                                                                         post("b", at: 2_000)])])
        // The model starts from the sidebar's copy (authoritative, 2_500), so the load does not ask.
        let model = makeModel(service, lastViewedAt: 2_500)
        await model.load()
        XCTAssertFalse(model.items.contains(.newMessages), "nothing is newer than where the reader stopped")

        // Now the server says the reader read up to 3_000 on another client, and two posts are new.
        service.membershipRow = member(3_000)
        service.firstPages = [list([post("f", at: 3_500),
                                    post("d", at: 2_600),
                                    post("b", at: 2_000),
                                    post("a", at: 1_000)])]
        _ = await model.resyncAfterReconnect()

        XCTAssertEqual(model.postIDAfterNewMessages(), "f",
                       "the divider is where the server's last_viewed_at says, not at the first unseen row "
                       + "the stale copy would have marked (d at 2_600)")
        XCTAssertEqual(service.membershipRequests, 1, "the refetch asks the server, not the memory")

        // A stale (older) answer must not move the divider back.
        service.membershipRow = member(1_500)
        service.firstPages = [list([post("f", at: 3_500), post("d", at: 2_600)])]
        _ = await model.resyncAfterReconnect()
        XCTAssertEqual(model.postIDAfterNewMessages(), "f", "last_viewed_at never moves backwards")
    }

    /// A model that has never loaded is not resynced: its first load is the fetch, and asking the server
    /// for a channel nobody opened would be a request for nothing.
    func testAnIdlePaneIsNotResynced() async {
        let service = FakeChannelService(pageSize: 60, firstPages: [list([post("a", at: 1_000)])])
        let pane = ChannelPaneCoordinator()
        pane.serviceFactory = { _ in service }
        pane.bind(auth: nil, navigation: nil, serverStore: nil)
        let server = server()
        _ = pane.model(for: server, channelID: channelID, channelName: "Town Square")

        let repaired = await pane.resync(serverID: server.id)

        XCTAssertEqual(repaired, 0)
        XCTAssertEqual(pane.resyncCount, 0)
        XCTAssertEqual(service.firstPageRequests, 0, "an unopened channel is not refetched")
    }

    /// A failed refetch is not a failed pane: the rows on screen are still the server's page as of the
    /// last load, and the next reconnect tries again.
    func testAFailedResyncLeavesTheWindowAndThePhaseAlone() async {
        let service = FakeChannelService(pageSize: 60, firstPages: [list([post("a", at: 1_000)])])
        let model = makeModel(service)
        await model.load()
        service.failure = MMError.server(status: 503, message: "the server is restarting")

        let inserted = await model.resyncAfterReconnect()

        XCTAssertEqual(inserted, 0)
        XCTAssertEqual(model.loadedPostIDs, ["a"])
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.resyncCount, 1, "the attempt is counted; only the rows are unchanged")
    }

    // MARK: - Helpers

    private func makeModel(_ service: FakeChannelService,
                          lastViewedAt: Int64? = nil) -> ChannelViewModel {
        ChannelViewModel(channelID: channelID,
                         channelName: "Town Square",
                         service: service,
                         myUserID: "me",
                         lastViewedAt: lastViewedAt,
                         now: { Date(timeIntervalSince1970: 1_800_000_000) },
                         calendar: .current,
                         locale: Locale(identifier: "en_US_POSIX"))
    }

    /// The post row as the socket carries it: `data.post` is a JSON **string**.
    ///
    /// Encoded from `MMPost` rather than hand-built: the row has ~15 required keys, and a frame missing one
    /// (`reply_count`, `pending_post_id`, …) is dropped by the decoder — which is how the first version of
    /// this helper made "the socket still delivers" fail for the wrong reason.
    static func postJSON(_ post: MMPost) throws -> String {
        let data = try JSONEncoder().encode(post)
        return String(decoding: data, as: UTF8.self)
    }
}

private extension ChannelViewModel {
    /// The post the "New messages" divider is drawn in front of (nil when there is no divider).
    func postIDAfterNewMessages() -> String? {
        guard let index = items.firstIndex(of: .newMessages), items.indices.contains(index + 1) else {
            return nil
        }
        return items[index + 1].postID
    }
}
