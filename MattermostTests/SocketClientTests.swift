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
                             now: @escaping @Sendable () -> Date = { Date() },
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
            now: now,
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

    /// T28-AV F7: the header comment claimed the upgrade carries `Authorization` *and* the in-band
    /// challenge. Only the challenge existed. The factory must receive the bearer header too.
    func testHandshakeHeadersCarryTheBearerTokenWhenOneIsConfigured() async {
        let transport = ScriptedSocketTransport()
        let harness = await makeHarness([transport], token: "tok-header-1")
        await harness.client.start()
        await waitUntil("transport") { harness.factory.created.count == 1 }

        let headers = harness.factory.madeHeaders.first
        XCTAssertEqual(headers?["Authorization"], "Bearer tok-header-1")
        XCTAssertEqual(headers?["Origin"], "https://mm.example.com")
        XCTAssertEqual(headers?["X-Requested-With"], "XMLHttpRequest")

        await harness.client.stop()
        harness.consumer.cancel()
    }

    /// ... and an anonymous socket (no token) must not carry an empty bearer header.
    func testHandshakeHeadersOmitAuthorizationWithoutAToken() async {
        let transport = ScriptedSocketTransport()
        let harness = await makeHarness([transport], token: nil)
        await harness.client.start()
        await waitUntil("transport") { harness.factory.created.count == 1 }

        XCTAssertNil(harness.factory.madeHeaders.first?["Authorization"])

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

    // MARK: - Backoff ladder vs. an accept-then-kill server (T28-AV F2)

    /// A server that accepts the upgrade and closes immediately must not be reconnected at the
    /// base delay forever: `retryDelays` has to escalate, or k kills hammer the server k times a
    /// second. (Before the fix this produced `[1, 1, 1, 1]`.)
    func testRepeatedOpenThenInstantCloseEscalatesTheBackoffLadder() async throws {
        let transports = (0..<4).map { _ in ScriptedSocketTransport() }
        let now = TestNow()
        let harness = await makeHarness(transports, now: now.provider)

        await harness.client.start()
        for (index, transport) in transports.enumerated() {
            await waitUntil("transport \(index + 1)") {
                harness.factory.created.count == index + 1
            }
            transport.push(.opened)
            await waitUntil("open \(index + 1)") { await harness.client.state == .open }
            now.advance(0.1) // a flap, not a session: far below stableSessionInterval (5 s)
            transport.push(.closed(code: 1006, reason: nil))
            await waitUntil("retry \(index + 1) scheduled") {
                await harness.client.retryDelays.count == index + 1
            }
        }

        let delays = await harness.client.retryDelays
        XCTAssertEqual(delays, [1, 2, 4, 8],
                       "open-then-instant-close must climb the ladder, not reset it")
        for (previous, next) in zip(delays, delays.dropFirst()) {
            XCTAssertGreaterThan(next, previous, "delays must strictly escalate")
        }

        await harness.client.stop()
        harness.consumer.cancel()
    }

    /// A connection that stays up counts as a session, so the ladder starts over: the card's
    /// acceptance "one long-lived open then a drop still asserts [1, 2]".
    func testALongLivedSessionThenADropStartsTheLadderAtBase() async throws {
        let first = ScriptedSocketTransport()
        let second = ScriptedSocketTransport()
        let now = TestNow()
        let harness = await makeHarness([first, second], now: now.provider)

        await harness.client.start()
        await waitUntil("first transport") { harness.factory.created.count == 1 }
        first.push(.opened)
        await waitUntil("open") { await harness.client.state == .open }
        now.advance(10) // well past stableSessionInterval
        first.push(.closed(code: 1006, reason: nil))

        await waitUntil("second transport") { harness.factory.created.count == 2 }
        second.push(.failed("connection reset"))
        await waitUntil("two retries") { await harness.client.retryDelays.count == 2 }

        let delays = await harness.client.retryDelays
        XCTAssertEqual(delays, [1, 2],
                       "a long-lived session resets the ladder; the next failure doubles from base")

        await harness.client.stop()
        harness.consumer.cancel()
    }

    /// The reset is a *reset*, not a no-op: a ladder that had already climbed to 2 goes back to 1
    /// after a long-lived session instead of continuing at 2.
    func testALongLivedSessionResetsAnAlreadyClimbedLadder() async throws {
        let first = ScriptedSocketTransport()
        let second = ScriptedSocketTransport()
        let third = ScriptedSocketTransport()
        let now = TestNow()
        let harness = await makeHarness([first, second, third], now: now.provider)

        await harness.client.start()
        await waitUntil("first transport") { harness.factory.created.count == 1 }
        first.push(.failed("connection refused"))

        await waitUntil("second transport") { harness.factory.created.count == 2 }
        second.push(.opened)
        await waitUntil("open") { await harness.client.state == .open }
        now.advance(10)
        second.push(.closed(code: 1006, reason: nil))

        await waitUntil("third transport") { harness.factory.created.count == 3 }
        third.push(.failed("connection refused"))
        await waitUntil("three retries") { await harness.client.retryDelays.count == 3 }

        let delays = await harness.client.retryDelays
        XCTAssertEqual(delays, [1, 1, 2],
                       "refused -> 1, long-lived session resets -> 1, refused -> 2")

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

    // MARK: - Legitimate repeats are not duplicates (T28-AV F3)

    /// Viewing the same channel twice is two real events. The old content-hashed dedupe key
    /// dropped the second one on the same connection.
    func testTwoChannelViewedEventsOnOneConnectionAreBothDelivered() async throws {
        let transport = ScriptedSocketTransport()
        let harness = await makeHarness([transport])
        await harness.client.start()
        await waitUntil("transport") { harness.factory.created.count == 1 }
        transport.push(.opened)
        let viewed = ["channel_id": "c1", "user_id": "u1"]
        transport.pushEvent("channel_viewed", seq: 1, data: viewed)
        transport.pushEvent("channel_viewed", seq: 2, data: viewed)

        await waitUntil("both channel_viewed events") { harness.box.count == 2 }
        XCTAssertEqual(harness.box.events.map(\.name), ["channel_viewed", "channel_viewed"])
        let duplicates = await harness.client.duplicateEventCount
        XCTAssertEqual(duplicates, 0, "a second view of the same channel is not a replay")

        await harness.client.stop()
        harness.consumer.cancel()
    }

    /// add → remove → add is three real events; the re-add must reach subscribers.
    func testAReAddedReactionIsDelivered() async throws {
        let transport = ScriptedSocketTransport()
        let harness = await makeHarness([transport])
        await harness.client.start()
        await waitUntil("transport") { harness.factory.created.count == 1 }
        transport.push(.opened)
        let reaction = "{\"user_id\":\"u2\",\"post_id\":\"p1\",\"emoji_name\":\"+1\",\"create_at\":5}"
        transport.pushEvent("reaction_added", seq: 1, data: ["reaction": reaction])
        transport.pushEvent("reaction_removed", seq: 2, data: ["reaction": reaction])
        transport.pushEvent("reaction_added", seq: 3, data: ["reaction": reaction])

        await waitUntil("all three reaction events") { harness.box.count == 3 }
        XCTAssertEqual(harness.box.events.map(\.name),
                       ["reaction_added", "reaction_removed", "reaction_added"])
        let duplicates = await harness.client.duplicateEventCount
        XCTAssertEqual(duplicates, 0, "the re-add after a remove is a new event, not a duplicate")

        await harness.client.stop()
        harness.consumer.cancel()
    }

    /// The narrow dedupe keys still do their job for identities that cannot legitimately recur.
    func testOnlyReplayableIdentitiesCarryADedupeKey() {
        let post = MMPost(id: "p1", createAt: 1, updateAt: 2, userId: "u1", channelId: "c1", message: "hi")
        XCTAssertEqual(SocketEvent.posted(post).dedupeKey, "posted|p1|2|0")
        XCTAssertEqual(SocketEvent.postEdited(post).dedupeKey, "post_edited|p1|2|0")
        XCTAssertNil(SocketEvent.channelViewed(SocketChannelViewed(channelID: "c1", userID: "u1")).dedupeKey)
        XCTAssertNil(SocketEvent.statusChange(SocketStatusChange(userID: "u1", status: "away")).dedupeKey)
        XCTAssertNil(SocketEvent.typing(SocketTyping(channelID: "c1", parentID: "", userID: "u2")).dedupeKey)
        XCTAssertNil(SocketEvent.preferencesChanged([]).dedupeKey)
        XCTAssertNil(SocketEvent.reactionAdded(MMReaction(userId: "u2", postId: "p1",
                                                          emojiName: "+1", createAt: 5)).dedupeKey)
        XCTAssertNil(SocketEvent.reactionRemoved(MMReaction(userId: "u2", postId: "p1",
                                                             emojiName: "+1", createAt: 5)).dedupeKey)
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

    func testHeartbeatTimeoutRecyclesTheConnectionAndResyncsOnceAfterTheReconnect() async throws {
        let transport = ScriptedSocketTransport()
        let reconnect = ScriptedSocketTransport()
        let clock = TestSocketClock(autoRelease: false)
        let resyncReasons = ResyncLog()
        let harness = await makeHarness([transport, reconnect],
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
        // T28-AV F5: the timeout itself must NOT resync — the reconnect is the one refetch point.
        XCTAssertEqual(resyncReasons.count, 0,
                       "a heartbeat timeout recycles the socket; the reconnect reports the resync")

        await waitUntil("backoff scheduled") { clock.requestedDelays.contains { $0 >= 0.5 } }
        clock.release() // let the run loop reconnect
        await waitUntil("reconnected transport") { harness.factory.created.count == 2 }
        reconnect.push(.opened)

        await waitUntil("resync after the reconnect") { resyncReasons.count == 1 }
        XCTAssertEqual(resyncReasons.reasons, [.reconnected],
                       "exactly one resync for the whole dropout")
        let resyncCount = await harness.client.resyncCount
        XCTAssertEqual(resyncCount, 1)

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
