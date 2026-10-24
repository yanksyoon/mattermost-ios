import Foundation
import XCTest
@testable import Mattermost

/// T28 acceptance criteria for the WebSocket v4 client: authentication challenge on open, the
/// typed event matrix, sequence gating, duplicate suppression across a reconnect, exactly one
/// backoff sequence per drop, one resync per reconnect, and the heartbeat timeout.
final class SocketClientTests: XCTestCase {

    private let socketURL = URL(string: "wss://mm.example.com/api/v4/websocket")!

    // MARK: - Fixtures

    private func post(_ id: String, message: String = "hi", updateAt: Int64 = 1_700_000_000_000) -> [String: Any] {
        ["id": id, "message": message, "create_at": 1_700_000_000_000,
         "update_at": updateAt, "delete_at": 0, "edit_at": 0,
         "user_id": "u1", "channel_id": "c1", "root_id": ""]
    }

    /// Mattermost sends `data.post` as a JSON *string*; this is the real wire shape.
    private func postEvent(_ id: String, name: String = "posted", updateAt: Int64 = 1_700_000_000_000) -> String {
        let inner = (try? JSONSerialization.data(withJSONObject: post(id, updateAt: updateAt))) ?? Data()
        return String(decoding: inner, as: UTF8.self)
    }

    private struct Harness {
        let client: SocketClient
        let factory: ScriptedTransportFactory
        let box: EventBox
        let consumer: Task<Void, Never>
    }

    private func makeHarness(_ transports: [ScriptedSocketTransport],
                             clock: SocketClock = TestSocketClock(autoRelease: true),
                             token: String? = "tok-socket",
                             pingInterval: TimeInterval? = nil,
                             backoff: SocketClient.Backoff = SocketClient.Backoff(base: 1,
                                                                                 factor: 2,
                                                                                 maxDelay: 60,
                                                                                 jitterRatio: 0),
                             resync: (@Sendable (SocketClient.ResyncReason) async -> Void)? = nil) async -> Harness {
        let factory = ScriptedTransportFactory(transports)
        let client = SocketClient(configuration: SocketClient.Configuration(
            url: socketURL,
            token: token,
            origin: "https://mm.example.com",
            pingInterval: pingInterval,
            backoff: backoff),
            transportFactory: { url, headers in factory.make(url, headers) },
            clock: clock,
            random: { 0.5 },
            resync: resync)
        let stream = await client.subscribe()
        let box = EventBox()
        let consumer = box.consume(stream)
        return Harness(client: client, factory: factory, box: box, consumer: consumer)
    }

    // MARK: - Connect

    func testOpenSendsAuthenticationChallengeAndDeliversHello() async throws {
        let transport = ScriptedSocketTransport()
        let harness = await makeHarness([transport])
        await harness.client.start()
        await waitUntil("transport created") { harness.factory.created.count == 1 }

        transport.push(.opened)
        await waitUntil("authentication challenge sent") {
            transport.sent.contains { $0.contains("authentication_challenge") }
        }
        transport.pushEvent("hello", seq: 1, data: ["connection_id": "conn-1",
                                                  "server_version": "9.11.19"])

        await waitUntil("hello delivered") { harness.box.count == 1 }
        XCTAssertEqual(harness.box.events.first,
                       .hello(SocketHello(connectionID: "conn-1", serverVersion: "9.11.19")))

        let state = await harness.client.state
        XCTAssertEqual(state, .open)
        let frame = try XCTUnwrap(transport.sent.first { $0.contains("authentication_challenge") })
        XCTAssertTrue(frame.contains("tok-socket"), "the token travels in the challenge frame")
        XCTAssertEqual(harness.factory.madeHeaders.first?["Origin"], "https://mm.example.com")

        await harness.client.stop()
        harness.consumer.cancel()
    }

    func testSocketURLIsWSSWithReliableParameters() throws {
        let base = try XCTUnwrap(MMBaseURL(URL(string: "https://corp.example.com/company/mm")!))
        let url = try XCTUnwrap(base.websocket(connectionID: "conn-9", sequenceNumber: 12))
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.path, "/company/mm/api/v4/websocket")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first { $0.name == "connection_id" }?.value, "conn-9")
        XCTAssertEqual(components.queryItems?.first { $0.name == "sequence_number" }?.value, "12")

        let plain = try XCTUnwrap(MMBaseURL(URL(string: "http://127.0.0.1:8065")!))
        XCTAssertEqual(plain.websocket()?.scheme, "ws")
        XCTAssertEqual(base.origin, "https://corp.example.com")
    }

    // MARK: - Reconnect / backoff / resync

    func testReconnectProducesOneBackoffSequenceAndOneResync() async throws {
        let console = ScriptedSocketTransport()
        let failed = ScriptedSocketTransport()
        let recovered = ScriptedSocketTransport()
        let resyncReasons = ResyncLog()
        let harness = await makeHarness([console, failed, recovered],
                                        resync: { reason in resyncReasons.append(reason) })

        await harness.client.start()
        await waitUntil("first transport") { harness.factory.created.count == 1 }
        console.push(.opened)
        await waitUntil("first open handled") { await harness.client.state == .open }
        console.push(.closed(code: 1006, reason: nil))

        // Second connection fails to open at all: the backoff must escalate.
        await waitUntil("second transport") { harness.factory.created.count == 2 }
        failed.push(.failed("connection reset"))

        await waitUntil("third transport") { harness.factory.created.count == 3 }
        recovered.push(.opened)

        await waitUntil("resync after reconnect") { resyncReasons.count == 1 }
        let delays = await harness.client.retryDelays
        XCTAssertEqual(delays, [1, 2], "exactly one backoff sequence: base, then base*2")
        XCTAssertEqual(resyncReasons.reasons, [.reconnected])
        let resyncCount = await harness.client.resyncCount
        XCTAssertEqual(resyncCount, 1, "one resync per reconnect, never a duplicate")

        await harness.client.stop()
        harness.consumer.cancel()
    }

    func testFirstConnectDoesNotResync() async throws {
        let transport = ScriptedSocketTransport()
        let resyncReasons = ResyncLog()
        let harness = await makeHarness([transport], resync: { reason in resyncReasons.append(reason) })
        await harness.client.start()
        await waitUntil("transport") { harness.factory.created.count == 1 }
        transport.push(.opened)
        await waitUntil("open") { await harness.client.state == .open }
        transport.pushEvent("hello", seq: 1, data: ["connection_id": "c", "server_version": "1"])
        await waitUntil("hello") { harness.box.count == 1 }
        XCTAssertEqual(resyncReasons.count, 0, "the first connect is not a resync")
        await harness.client.stop()
        harness.consumer.cancel()
    }

    // MARK: - Duplicate suppression

    func testReplayedEventsAfterReconnectAreNotDeliveredTwice() async throws {
        let first = ScriptedSocketTransport()
        let second = ScriptedSocketTransport()
        let resyncReasons = ResyncLog()
        let harness = await makeHarness([first, second],
                                        resync: { reason in resyncReasons.append(reason) })

        await harness.client.start()
        await waitUntil("first transport") { harness.factory.created.count == 1 }
        first.push(.opened)
        first.pushEvent("hello", seq: 1, data: ["connection_id": "conn-1", "server_version": "9"])
        first.pushEvent("posted", seq: 2, data: ["post": postEvent("p1")])
        await waitUntil("initial events") { harness.box.count == 2 }
        first.push(.closed(code: 1006, reason: nil))

        await waitUntil("second transport") { harness.factory.created.count == 2 }
        second.push(.opened)
        // The server replays the last post after the reconnect (same identity, new seq) and then
        // sends the genuinely new one.
        second.pushEvent("hello", seq: 1, data: ["connection_id": "conn-1", "server_version": "9"])
        second.pushEvent("posted", seq: 2, data: ["post": postEvent("p1")])
        second.pushEvent("posted", seq: 3, data: ["post": postEvent("p2", updateAt: 1_700_000_100_000)])

        await waitUntil("replayed stream drained") {
            await harness.client.deliveredEventCount == 3
        }
        let events = harness.box.events
        let postedIDs = events.compactMap { event -> String? in
            if case .posted(let post) = event { return post.id }
            return nil
        }
        XCTAssertEqual(postedIDs, ["p1", "p2"], "the replayed p1 is suppressed, p2 is delivered")
        let duplicates = await harness.client.duplicateEventCount
        XCTAssertEqual(duplicates, 2, "replayed hello and replayed posted are both suppressed")
        XCTAssertEqual(resyncReasons.count, 1)
        XCTAssertEqual(harness.box.count, 3)

        await harness.client.stop()
        harness.consumer.cancel()
    }

    func testTypingIsNeverDeduplicated() async throws {
        let transport = ScriptedSocketTransport()
        let harness = await makeHarness([transport])
        await harness.client.start()
        await waitUntil("transport") { harness.factory.created.count == 1 }
        transport.push(.opened)
        let typing = ["channel_id": "c1", "parent_id": "", "user_id": "u2"]
        transport.pushEvent("typing", seq: 1, data: typing)
        transport.pushEvent("typing", seq: 2, data: typing)

        await waitUntil("both typing events") { harness.box.count == 2 }
        let duplicates = await harness.client.duplicateEventCount
        XCTAssertEqual(duplicates, 0, "typing is transient: identical frames are both delivered")
        await harness.client.stop()
        harness.consumer.cancel()
    }

    func testSequenceGateDropsAReplayOnTheSameConnection() async throws {
        let transport = ScriptedSocketTransport()
        let harness = await makeHarness([transport])
        await harness.client.start()
        await waitUntil("transport") { harness.factory.created.count == 1 }
        transport.push(.opened)
        transport.pushEvent("posted", seq: 5, data: ["post": postEvent("p1")])
        transport.pushEvent("posted", seq: 4, data: ["post": postEvent("p2")])

        await waitUntil("first event") { harness.box.count == 1 }
        // Give the run loop a chance to (not) deliver the stale frame.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(harness.box.count, 1, "seq 4 arrived after seq 5: dropped before delivery")
        await harness.client.stop()
        harness.consumer.cancel()
    }

    // MARK: - Heartbeat

    func testHeartbeatTimeoutRecyclesTheConnectionAndResyncs() async throws {
        let transport = ScriptedSocketTransport()
        let clock = TestSocketClock(autoRelease: false)
        let resyncReasons = ResyncLog()
        let harness = await makeHarness([transport],
                                        clock: clock,
                                        pingInterval: 0.01,
                                        resync: { reason in resyncReasons.append(reason) })

        await harness.client.start()
        await waitUntil("transport") { harness.factory.created.count == 1 }
        transport.push(.opened)
        await waitUntil("open") { await harness.client.state == .open }

        clock.release() // first tick: sends a ping
        await waitUntil("ping sent") { transport.sent.contains { $0.contains("\"ping\"") } }

        clock.release() // second tick with no pong: recycle
        await waitUntil("connection recycled") { transport.closeCount == 1 }
        XCTAssertEqual(resyncReasons.reasons, [.heartbeatTimeout])

        await harness.client.stop()
        harness.consumer.cancel()
    }

    func testPongClearsTheMissedPongCount() async throws {
        let transport = ScriptedSocketTransport()
        let clock = TestSocketClock(autoRelease: false)
        let harness = await makeHarness([transport], clock: clock, pingInterval: 0.01)

        await harness.client.start()
        await waitUntil("transport") { harness.factory.created.count == 1 }
        transport.push(.opened)
        await waitUntil("open") { await harness.client.state == .open }

        clock.release()
        await waitUntil("first ping") { transport.sent.count == 2 } // challenge + ping
        transport.push(.text(ScriptedSocketTransport.reply(seq: 2, text: "pong")))

        clock.release()
        await waitUntil("second ping") { transport.sent.count == 3 }
        XCTAssertEqual(transport.closeCount, 0, "a pong resets the miss count, so no recycle")

        await harness.client.stop()
        harness.consumer.cancel()
    }

    // MARK: - Typed event matrix

    func testTypedEventMatrix() async throws {
        let transport = ScriptedSocketTransport()
        let harness = await makeHarness([transport])
        await harness.client.start()
        await waitUntil("transport") { harness.factory.created.count == 1 }
        transport.push(.opened)

        var seq = 0
        func next() -> Int { seq += 1; return seq }

        transport.pushEvent("hello", seq: next(), data: ["connection_id": "conn-7",
                                                       "server_version": "9.11.19"])
        transport.pushEvent("posted", seq: next(), data: ["post": postEvent("p1")])
        transport.pushEvent("post_edited", seq: next(),
                            data: ["post": postEvent("p1", updateAt: 1_700_000_200_000)])
        transport.pushEvent("post_deleted", seq: next(),
                            data: ["post": postEvent("p1", updateAt: 1_700_000_300_000)])
        transport.pushEvent("channel_viewed", seq: next(),
                            data: ["channel_id": "c1", "user_id": "u1"])
        transport.pushEvent("typing", seq: next(),
                            data: ["channel_id": "c1", "parent_id": "p1", "user_id": "u2"])
        transport.pushEvent("status_change", seq: next(), data: ["user_id": "u2", "status": "away"])
        transport.pushEvent("preferences_changed", seq: next(), data: [
            "preferences": [["user_id": "u1", "category": "theme", "name": "useMilitaryTime", "value": "true"]]
        ])
        transport.pushEvent("user_updated", seq: next(), data: [
            "user": ["id": "u2", "username": "grace", "update_at": 1_700_000_400_000]
        ])
        transport.pushEvent("reaction_added", seq: next(), data: [
            "reaction": "{\"user_id\":\"u2\",\"post_id\":\"p1\",\"emoji_name\":\"+1\",\"create_at\":5}"
        ])
        transport.pushEvent("reaction_removed", seq: next(), data: [
            "reaction": "{\"user_id\":\"u2\",\"post_id\":\"p1\",\"emoji_name\":\"+1\",\"create_at\":5}"
        ])
        transport.pushEvent("plugin_something_new", seq: next(), data: ["x": 1])

        await waitUntil("all events") { harness.box.count == 12 }
        let events = harness.box.events
        XCTAssertEqual(events.map(\.name), [
            "hello", "posted", "post_edited", "post_deleted", "channel_viewed", "typing",
            "status_change", "preferences_changed", "user_updated", "reaction_added",
            "reaction_removed", "plugin_something_new"
        ])
        XCTAssertEqual(events[1], .posted(MMPost(id: "p1", createAt: 1_700_000_000_000,
                                                 updateAt: 1_700_000_000_000, userId: "u1",
                                                 channelId: "c1", message: "hi")))
        if case .preferencesChanged(let preferences) = events[7] {
            XCTAssertEqual(preferences.first?.name, "useMilitaryTime")
            XCTAssertEqual(preferences.first?.value, "true")
        } else {
            XCTFail("expected preferences_changed")
        }
        if case .reactionAdded(let reaction) = events[9] {
            XCTAssertEqual(reaction.emojiName, "+1")
            XCTAssertEqual(reaction.postId, "p1")
        } else {
            XCTFail("expected reaction_added")
        }
        XCTAssertEqual(events[11], .unhandled(name: "plugin_something_new"))

        await harness.client.stop()
        harness.consumer.cancel()
    }

    // MARK: - Lifecycle

    func testStopFinishesSubscriberStreams() async throws {
        let transport = ScriptedSocketTransport()
        let harness = await makeHarness([transport])
        await harness.client.start()
        await waitUntil("transport") { harness.factory.created.count == 1 }
        transport.push(.opened)
        await waitUntil("open") { await harness.client.state == .open }

        await harness.client.stop()
        await waitUntil("stream finished") { harness.box.streamFinished }
        let state = await harness.client.state
        XCTAssertEqual(state, .idle)
        harness.consumer.cancel()
    }
}

/// Ordered record of resync reasons requested by the client.
final class ResyncLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SocketClient.ResyncReason] = []

    var reasons: [SocketClient.ResyncReason] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var count: Int { reasons.count }

    func append(_ reason: SocketClient.ResyncReason) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(reason)
    }
}
