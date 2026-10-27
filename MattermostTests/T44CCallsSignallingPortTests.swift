// T44c — the signalling port: the exact frames a native client puts on the core socket, and the
// filter that keeps another session's signalling out of this call.
//
// Everything here runs against `FakeCallsSocket`, which is the whole point of the
// `CallsSocketTransport` seam: no server, no upgrade, no token, no plugin. What is asserted is the
// wire contract the plugin reads (`server/websocket.go`, `server/client_message.go` at v0.29.8):
//
//   * `join` / `leave` / `mute` / `unmute` / `raise_hand` / `ice` are JSON **text** frames whose
//     `data` is an object — `join` names its channel as `channelID` (not `channel_id`; measured: the
//     plugin rejects the snake_case key as "missing channelID");
//   * `ice`'s `data.data` is a JSON **string**;
//   * `sdp` is a MessagePack **binary** frame whose `data.data` is a bin of zlib(JSON);
//   * a signal belonging to another session of the same account must not reach the engine, and the
//     only trustworthy way to learn "this session" is the `connID` on the first `answer`.

import Foundation
import XCTest
@testable import Mattermost

final class T44CCallsSignallingPortTests: XCTestCase {

    private let version = CallsPluginVersion(major: 0, minor: 29, patch: 8)

    // MARK: - join / leave

    func testJoinSendsTheChannelAsChannelID() async throws {
        let socket = FakeCallsSocket()
        let port = CallsSignallingPort(socket: socket, version: version)

        try await port.join(channelID: "chan1")

        let frame = try XCTUnwrap(socket.textFrames.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8))
                                    as? [String: Any])
        XCTAssertEqual(object["action"] as? String, "custom_com.mattermost.calls_join")
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual(data["channelID"] as? String, "chan1")
        // The measured rejection: a `channel_id` join is dropped with "missing channelID".
        XCTAssertNil(data["channel_id"])
        XCTAssertNotNil(object["seq"] as? Int, "the core socket correlates replies by seq")
    }

    func testLeaveSendsTheSameEnvelope() async throws {
        let socket = FakeCallsSocket()
        let port = CallsSignallingPort(socket: socket, version: version)

        try await port.leave(channelID: "chan1")

        let object = try json(socket.textFrames.first)
        XCTAssertEqual(object["action"] as? String, "custom_com.mattermost.calls_leave")
        XCTAssertEqual((object["data"] as? [String: Any])?["channelID"] as? String, "chan1")
    }

    /// The seq is a client-side counter shared by every action, because the core socket's reply
    /// correlation is per connection.
    func testEveryFrameTakesTheNextSequenceNumber() async throws {
        let socket = FakeCallsSocket()
        let port = CallsSignallingPort(socket: socket, version: version)

        try await port.join(channelID: "chan1")
        try await port.setMuted(true, channelID: "chan1")
        try await port.setMuted(false, channelID: "chan1")
        try await port.send(candidate: CallsIceCandidate(candidate: "candidate:1 1 udp 1 10.0.0.1 1 typ host"))

        let seqs = try socket.textFrames.map { try json($0)["seq"] as? Int }
        XCTAssertEqual(seqs, [1, 2, 3, 4])
    }

    // MARK: - sdp is binary

    func testSDPGoesOutAsAMessagePackBinaryFrame() async throws {
        let socket = FakeCallsSocket()
        let port = CallsSignallingPort(socket: socket, version: version)
        let description = CallsSessionDescription(kind: .offer,
                                                  sdp: "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n")

        try await port.send(description: description)

        XCTAssertTrue(socket.textFrames.isEmpty,
                      "an sdp frame must never be sent as text: the plugin type-asserts []byte")
        let frame = try XCTUnwrap(socket.binaryFrames.first)

        var reader = MiniMessagePackReader(bytes: [UInt8](frame))
        guard case .map(let entries) = try reader.readValue() else {
            return XCTFail("not a MessagePack map")
        }
        XCTAssertEqual(entries["action"], .string("custom_com.mattermost.calls_sdp"))
        guard case .map(let data)? = entries["data"], case .binary(let packed)? = data["data"] else {
            return XCTFail("data.data must be a bin")
        }
        XCTAssertEqual(try CallsSDPCodec.unpack(packed), description)
    }

    /// An answer to the SFU's re-offer takes the same path — if it went out as text the plugin would
    /// drop it and the client would keep its own receive-only transceivers.
    func testAnswerAlsoUsesTheBinaryPath() async throws {
        let socket = FakeCallsSocket()
        let port = CallsSignallingPort(socket: socket, version: version)

        try await port.send(description: CallsSessionDescription(kind: .answer, sdp: "v=0\r\n"))

        XCTAssertEqual(socket.binaryFrames.count, 1)
        XCTAssertTrue(socket.textFrames.isEmpty)
    }

    // MARK: - ice is text

    func testCandidateGoesOutAsATextFrameWithAJSONStringPayload() async throws {
        let socket = FakeCallsSocket()
        let port = CallsSignallingPort(socket: socket, version: version)
        let candidate = CallsIceCandidate(candidate: "candidate:1 1 udp 1 10.0.0.1 5000 typ host",
                                          sdpMid: "0", sdpMLineIndex: 0)

        try await port.send(candidate: candidate)

        XCTAssertTrue(socket.binaryFrames.isEmpty, "`ice` is not a msgpack action")
        let object = try json(socket.textFrames.first)
        XCTAssertEqual(object["action"] as? String, "custom_com.mattermost.calls_ice")
        let inner = try XCTUnwrap((object["data"] as? [String: Any])?["data"] as? String,
                                  "`ice`'s data.data must be a JSON **string**, not an object")
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(inner.utf8))
                                    as? [String: Any])
        XCTAssertEqual(decoded["candidate"] as? String, candidate.candidate)
        XCTAssertEqual(decoded["sdpMid"] as? String, "0")
        XCTAssertEqual(decoded["sdpMLineIndex"] as? Int, 0)
    }

    /// The empty candidate is the "end of candidates" marker: there is no plugin action for it and
    /// sending one produces a plugin-side error, so it is dropped locally.
    func testEmptyCandidateIsNotSent() async throws {
        let socket = FakeCallsSocket()
        let port = CallsSignallingPort(socket: socket, version: version)

        try await port.send(candidate: CallsIceCandidate(candidate: ""))

        XCTAssertTrue(socket.textFrames.isEmpty)
        XCTAssertTrue(socket.binaryFrames.isEmpty)
    }

    // MARK: - session state actions

    func testMuteAndUnmuteCarryTheChannel() async throws {
        let socket = FakeCallsSocket()
        let port = CallsSignallingPort(socket: socket, version: version)

        try await port.setMuted(true, channelID: "chan1")
        try await port.setMuted(false, channelID: "chan1")

        let actions = try socket.textFrames.map { try json($0)["action"] as? String }
        XCTAssertEqual(actions, ["custom_com.mattermost.calls_mute",
                                 "custom_com.mattermost.calls_unmute"])
        for frame in socket.textFrames {
            XCTAssertEqual((try json(frame)["data"] as? [String: Any])?["channelID"] as? String,
                           "chan1")
        }
    }

    func testHandAndCallStateActions() async throws {
        let socket = FakeCallsSocket()
        let port = CallsSignallingPort(socket: socket, version: version)

        try await port.setHandRaised(true, channelID: "chan1")
        try await port.setHandRaised(false, channelID: "chan1")
        try await port.requestCallState(channelID: "chan1")

        let actions = try socket.textFrames.map { try json($0)["action"] as? String }
        XCTAssertEqual(actions, ["custom_com.mattermost.calls_raise_hand",
                                 "custom_com.mattermost.calls_unraise_hand",
                                 "custom_com.mattermost.calls_call_state"])
    }

    // MARK: - session filter

    func testAnswerNamesThisSessionsConnIDAndIsForwarded() async throws {
        let socket = FakeCallsSocket()
        let port = CallsSignallingPort(socket: socket, version: version)
        let collector = EventCollector(port.events)

        await port.receive(answerEvent(connID: "abc123", sdp: "v=0\r\n"))

        let events = await collector.waitFor(1)
        guard case .signal(let signal)? = events.first else {
            return XCTFail("expected a signal, got \(events)")
        }
        XCTAssertEqual(signal.connID, "abc123")
        let learned = await port.connID
        XCTAssertEqual(learned, "abc123")
    }

    /// Two sockets of one account both receive the join ack (it is broadcast per user), so a signal
    /// for the *other* session must not be applied: doing so connects this peer to a stranger's call.
    func testASecondSessionsSignallingIsDropped() async throws {
        let socket = FakeCallsSocket()
        let port = CallsSignallingPort(socket: socket, version: version)
        let collector = EventCollector(port.events)

        await port.receive(answerEvent(connID: "mine", sdp: "v=0\r\n"))
        await port.receive(answerEvent(connID: "theirs", sdp: "v=0\r\n"))
        await port.receive(candidateEvent(connID: "theirs"))
        await port.receive(candidateEvent(connID: "mine"))

        let events = await collector.waitFor(2)
        XCTAssertEqual(events.count, 2, "only this session's answer and candidate")
        guard case .signal(let answer)? = events.first,
              case .description(let description) = answer.payload else {
            return XCTFail("expected the answer first")
        }
        XCTAssertEqual(answer.connID, "mine")
        XCTAssertEqual(description.kind, .answer)

        guard case .signal(let candidate)? = events.last, case .candidate = candidate.payload else {
            return XCTFail("expected the candidate second")
        }
        XCTAssertEqual(candidate.connID, "mine")

        let dropped = await port.droppedForeignSignals
        XCTAssertEqual(dropped, 2, "the foreign answer and the foreign candidate")
    }

    /// Before an answer arrives, an **offer** could belong to any session: there is no key to check
    /// it against. Dropping it is the safe direction — the SFU re-offers after the answer anyway.
    func testAnOfferBeforeTheAnswerIsDropped() async throws {
        let socket = FakeCallsSocket()
        let port = CallsSignallingPort(socket: socket, version: version)
        let collector = EventCollector(port.events)

        await port.receive(offerEvent(connID: "someone", sdp: "v=0\r\n"))

        let events = await collector.waitFor(1, timeout: 0.3)
        XCTAssertTrue(events.isEmpty, "an unattributable offer must not be forwarded")
        let known = await port.connID
        XCTAssertNil(known)
    }

    /// After the session is known, a re-offer addressed to it **is** forwarded — that is the
    /// post-connect renegotiation the engine has to answer (T44b §5).
    func testAServerReOfferForThisSessionIsForwarded() async throws {
        let socket = FakeCallsSocket()
        let port = CallsSignallingPort(socket: socket, version: version)
        let collector = EventCollector(port.events)

        await port.receive(answerEvent(connID: "mine", sdp: "v=0\r\n"))
        await port.receive(offerEvent(connID: "mine", sdp: "v=0\r\nm=audio 9\r\n"))

        let events = await collector.waitFor(2)
        guard events.count == 2, case .signal(let signal) = events[1],
              case .description(let description) = signal.payload else {
            return XCTFail("expected the re-offer, got \(events)")
        }
        XCTAssertEqual(description.kind, .offer)
        XCTAssertTrue(description.sdp.contains("m=audio"))
    }

    func testJoinAckAndCallStateAreForwarded() async throws {
        let socket = FakeCallsSocket()
        let port = CallsSignallingPort(socket: socket, version: version)
        let collector = EventCollector(port.events)

        await port.receive(.plugin(name: "custom_com.mattermost.calls_join",
                                   data: callsRaw(#"{"connID":"abc123"}"#)))
        await port.receive(.plugin(
            name: "custom_com.mattermost.calls_call_state",
            data: callsRaw(#"{"channel_id":"chan1","call":"{\"id\":\"call1\",\"channel_id\":\"chan1\"}"}"#)))

        let events = await collector.waitFor(2)
        XCTAssertEqual(events.first, .joinAck(connID: "abc123"))
        guard case .callState(let channelID, let call)? = events.last else {
            return XCTFail("expected call_state, got \(events)")
        }
        XCTAssertEqual(channelID, "chan1")
        XCTAssertEqual(call.id, "call1")
    }

    /// A non-Calls plugin frame stays out of the typed stream; a Calls frame this build does not
    /// model is carried as `unhandled` rather than silently dropped.
    func testForeignAndUnknownFramesBehave() async throws {
        let socket = FakeCallsSocket()
        let port = CallsSignallingPort(socket: socket, version: version)
        let collector = EventCollector(port.events)

        await port.receive(.plugin(name: "custom_com.other.plugin_thing", data: callsRaw("{}")))
        await port.receive(.posted(MMPost(id: "p1", createAt: 0, updateAt: 0, userId: "u",
                                          channelId: "c", message: "")))
        let foreign = await collector.waitFor(1, timeout: 0.3)
        XCTAssertTrue(foreign.isEmpty)

        await port.receive(.plugin(name: "custom_com.mattermost.calls_future",
                                   data: callsRaw("{}")))
        let events = await collector.waitFor(1)
        XCTAssertEqual(events, [.unhandled(name: "future")])
    }

    // MARK: - failures

    func testAFailedSendIsCountedAndRethrown() async throws {
        let socket = FakeCallsSocket()
        socket.sendError = FakeCallsSocket.Failure()
        let port = CallsSignallingPort(socket: socket, version: version)

        do {
            try await port.join(channelID: "chan1")
            XCTFail("the failure must reach the caller — a silently dropped join is a call that "
                    + "never starts")
        } catch {
            XCTAssertTrue(error is FakeCallsSocket.Failure)
        }
        let failures = await port.sendFailures
        XCTAssertEqual(failures, 1)
    }

    // MARK: - version gating

    /// The two builds differ: `video_on`/`video_off` exist only on 1.x. The gate is data, so the
    /// same binary speaks to both.
    func testVideoActionsAreGatedOnThePluginVersion() {
        let old = CallsPluginVersion(major: 0, minor: 29, patch: 8)
        let new = CallsPluginVersion(major: 1, minor: 0, patch: 0)
        XCTAssertFalse(CallsProtocol.Action.videoOn.isAvailable(in: old))
        XCTAssertFalse(CallsProtocol.Action.videoOff.isAvailable(in: old))
        XCTAssertTrue(CallsProtocol.Action.videoOn.isAvailable(in: new))
        XCTAssertTrue(CallsProtocol.Action.join.isAvailable(in: old))
        XCTAssertTrue(CallsProtocol.Action.sdp.isAvailable(in: new))
    }

    // MARK: - Fixtures

    private func json(_ text: String?) throws -> [String: Any] {
        let text = try XCTUnwrap(text)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func answerEvent(connID: String, sdp: String) -> SocketEvent {
        signalEvent(connID: connID, inner: ["type": "answer", "sdp": sdp])
    }

    private func offerEvent(connID: String, sdp: String) -> SocketEvent {
        signalEvent(connID: connID, inner: ["type": "offer", "sdp": sdp])
    }

    private func candidateEvent(connID: String) -> SocketEvent {
        signalEvent(connID: connID, inner: [
            "type": "candidate",
            "candidate": ["candidate": "candidate:1 1 udp 1 10.0.0.1 5000 typ host",
                          "sdpMid": "0",
                          "sdpMLineIndex": 0] as [String: Any],
        ])
    }

    /// The measured shape: `data` is `{data: <JSON **string**>, connID: <string>}` — the inner
    /// description is double-encoded, exactly as the plugin publishes it.
    private func signalEvent(connID: String, inner: [String: Any]) -> SocketEvent {
        let innerData = try! JSONSerialization.data(withJSONObject: inner,
                                                    options: [.sortedKeys, .withoutEscapingSlashes])
        let innerString = String(decoding: innerData, as: UTF8.self)
        let outer: [String: Any] = ["connID": connID, "data": innerString]
        let outerData = try! JSONSerialization.data(withJSONObject: outer)
        return .plugin(name: "custom_com.mattermost.calls_signal",
                       data: callsRaw(String(decoding: outerData, as: UTF8.self)))
    }
}

// MARK: - Collecting the typed stream

/// Drains a port's `AsyncStream` into an array so a test can wait for "n events" or for "nothing at
/// all" without racing an iterator. One long-lived consumer is the only shape `AsyncStream` supports
/// safely; creating a fresh iterator per assertion would silently drop buffered events.
final class EventCollector: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [CallsEvent] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<CallsEvent>) {
        task = Task { [self] in
            for await event in stream {
                lock.lock()
                storage.append(event)
                lock.unlock()
            }
        }
    }

    deinit { task?.cancel() }

    var events: [CallsEvent] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    /// Wait until at least `count` events have arrived, or `timeout` elapses. Returns what it has —
    /// a caller that expected more asserts on the count.
    func waitFor(_ count: Int, timeout: TimeInterval = 3) async -> [CallsEvent] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = events
            if current.count >= count { return current }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return events
    }
}

/// The socket seam, faked: records both send paths and lets a test feed events in.
final class FakeCallsSocket: CallsSocketTransport, @unchecked Sendable {

    struct Failure: Error {}

    private let lock = NSLock()
    private var textStorage: [String] = []
    private var binaryStorage: [Data] = []
    private let stream: AsyncStream<SocketEvent>
    private let continuation: AsyncStream<SocketEvent>.Continuation
    /// Set to make every send throw.
    var sendError: Error?

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: SocketEvent.self,
                                                        bufferingPolicy: .bufferingNewest(64))
    }

    var textFrames: [String] {
        lock.lock(); defer { lock.unlock() }
        return textStorage
    }

    var binaryFrames: [Data] {
        lock.lock(); defer { lock.unlock() }
        return binaryStorage
    }

    func subscribe() async -> AsyncStream<SocketEvent> { stream }

    func sendTextFrame(_ text: String) async throws {
        if let sendError { throw sendError }
        lock.lock(); textStorage.append(text); lock.unlock()
    }

    func sendBinaryFrame(_ frame: Data) async throws {
        if let sendError { throw sendError }
        lock.lock(); binaryStorage.append(frame); lock.unlock()
    }

    /// Push a frame in as if the socket had delivered it.
    func push(_ event: SocketEvent) { continuation.yield(event) }
}
