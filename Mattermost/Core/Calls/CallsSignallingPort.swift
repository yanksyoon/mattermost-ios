// The client half of the Calls signalling protocol: what a native client must say on the core
// WebSocket, in what order, and which of the SFU's answers belong to *this* session.
//
// Measured contract (docs/t44-build-note.md §4.1, docs/t44b-calls-media-path.md §5, and the
// conformance probe `scripts/t44_calls_probe.py` checks 3–8):
//
//   join      text frame, `{channelID}` — the payload key is `channelID`, not `channel_id`
//   sdp       **binary** MessagePack frame, `data.data` = zlib(JSON({type, sdp}))
//   ice       text frame, `data.data` = JSON(RTCIceCandidateInit)
//   unmute    text frame, `{channelID}`; the session state it flips is `call_state.sessions[].unmuted`
//   leave     text frame, `{channelID}`
//
// Design notes that are protocol, not taste:
//
//  * **One socket, no second connection.** Calls rides the core socket (the plugin hooks
//    `WebSocketMessageHasBeenPosted`), so this type is a *codec over* `SocketClient`, not a socket.
//  * **`connID` filtering.** The SFU publishes `signal` with `{connID: <session>, data: <JSON>}`, but
//    the `join` ack is broadcast **per user**, so two sockets of one account each receive both
//    sessions' signals and neither can tell which `connID` is its own from the ack. The reliable key
//    is `data.connID` on the **first `answer`** a socket receives (measured, T44b); every later
//    signal is filtered on it. A single-session client is unaffected, a two-peer driver is not.
//  * **The client offers.** The SFU never offers first: a client that joins and waits is disconnected
//    at the 10 s signalling timeout (probe check 8). After ICE connects the SFU *does* re-offer, and
//    that offer must be answered or no media is received (T44b §5) — so the caller has to handle
//    both roles, which is why `CallsEngine` does.

import Foundation

/// What `CallsEngine` needs from the signalling layer. A protocol so the engine can be driven by a
/// scripted fake in a test with no server, no socket and no plugin.
protocol CallsSignalling: Sendable {
    /// Typed Calls events for this session. One consumer (the engine).
    var events: AsyncStream<CallsEvent> { get }

    /// Begin forwarding plugin frames from the socket. Idempotent; call once before `join`.
    func start()

    /// Stop forwarding. The socket belongs to the app, not to the call, so this must not close it.
    func stop()

    func join(channelID: String) async throws
    func leave(channelID: String) async throws

    /// Send an SDP description on the **binary** path (offer, or answer to the SFU's re-offer).
    func send(description: CallsSessionDescription) async throws
    /// Send one trickled candidate on the text path.
    func send(candidate: CallsIceCandidate) async throws

    /// `unmute` / `mute` — the session state other participants render.
    func setMuted(_ muted: Bool, channelID: String) async throws
    /// `raise_hand` / `unraise_hand`.
    func setHandRaised(_ raised: Bool, channelID: String) async throws
    /// Ask the plugin to publish `call_state` again (`call_state` action).
    func requestCallState(channelID: String) async throws
}

/// The three socket operations the Calls port needs, and nothing else.
///
/// A protocol rather than the concrete `SocketClient` because that is the seam the port's tests use:
/// a fake records the exact frames a `join`/`sdp`/`ice` produces without a server, an upgrade, a
/// token or a plugin. `SocketClient` conforms in one line below and is the only production
/// conformance.
protocol CallsSocketTransport: Sendable {
    /// The socket's typed event stream. Each call returns a fresh subscriber stream.
    func subscribe() async -> AsyncStream<SocketEvent>
    /// One already-encoded text frame (every Calls action except `sdp`).
    func sendTextFrame(_ text: String) async throws
    /// One already-encoded MessagePack frame. `sdp` and nothing else.
    func sendBinaryFrame(_ frame: Data) async throws
}

extension SocketClient: CallsSocketTransport {}

/// The live implementation: `CallsEvent` decoding over `SocketClient`.
actor CallsSignallingPort: CallsSignalling {

    nonisolated let events: AsyncStream<CallsEvent>
    private let continuation: AsyncStream<CallsEvent>.Continuation

    private let socket: any CallsSocketTransport
    private let version: CallsPluginVersion
    private var forwarding: Task<Void, Never>?
    /// The session's own connection id, learned from the first `answer` (see the note above).
    private(set) var connID: String?
    private var seq = 0
    private(set) var droppedForeignSignals = 0
    private(set) var sendFailures = 0

    init(socket: any CallsSocketTransport, version: CallsPluginVersion) {
        self.socket = socket
        self.version = version
        let (stream, continuation) = AsyncStream.makeStream(of: CallsEvent.self,
                                                            bufferingPolicy: .bufferingNewest(256))
        self.events = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    // MARK: - Lifecycle

    nonisolated func start() {
        Task { await self.beginForwarding() }
    }

    private func beginForwarding() {
        guard forwarding == nil else { return }
        forwarding = Task { [weak self] in
            guard let stream = await self?.socket.subscribe() else { return }
            for await event in stream {
                guard let self else { return }
                await self.receive(event)
            }
        }
        MMLog.debug("MMCalls", "signalling port started (plugin \(version))")
    }

    /// Stop forwarding. The socket itself belongs to the app, not to the call.
    nonisolated func stop() {
        Task { await self.cancelForwarding() }
    }

    private func cancelForwarding() {
        forwarding?.cancel()
        forwarding = nil
    }

    /// One socket event in. Public for the tests, which is the only way to drive the filter without
    /// a server: the engine-level integration test uses a fake `CallsSignalling` instead.
    func receive(_ event: SocketEvent) {
        guard case .plugin(let name, let data) = event else { return }
        guard let callsEvent = CallsEvent(name: name, data: data) else { return }
        guard accept(callsEvent) else { return }
        continuation.yield(callsEvent)
    }

    /// The `connID` gate. Returns `false` for a signal addressed to a different session of the same
    /// account.
    private func accept(_ event: CallsEvent) -> Bool {
        switch event {
        case .signal(let signal):
            if let known = connID {
                guard signal.connID == known else {
                    droppedForeignSignals += 1
                    MMLog.debug("MMCalls", "dropped signal for another session "
                        + "(\(signal.kind), connID \(Self.short(signal.connID)) != \(Self.short(known)))")
                    return false
                }
                return true
            }
            // Unlearned: only an answer can name this socket's session. An offer that arrives first
            // belongs to whichever session the SFU answered first — accepting it would adopt a
            // stranger's connection.
            guard case .description(let description) = signal.payload,
                  description.kind == .answer else {
                droppedForeignSignals += 1
                MMLog.debug("MMCalls", "dropped \(signal.kind) before this session's answer")
                return false
            }
            connID = signal.connID
            MMLog.info("MMCalls", "session connID learned from the answer: \(Self.short(signal.connID))")
            return true

        case .joinAck(let ackConnID):
            // The ack is broadcast per user and can name another session; remember it only as a
            // hint. It is never used to filter.
            if connID == nil {
                MMLog.debug("MMCalls", "join ack (hint) connID \(Self.short(ackConnID))")
            }
            return true

        default:
            return true
        }
    }

    // MARK: - Client → server

    func join(channelID: String) async throws {
        beginForwarding()
        try await sendText(.join, data: [CallsProtocol.channelKey: channelID])
    }

    func leave(channelID: String) async throws {
        try await sendText(.leave, data: [CallsProtocol.channelKey: channelID])
    }

    func send(description: CallsSessionDescription) async throws {
        let frame = try CallsSDPCodec.sdpFrame(seq: nextSeq(), description: description)
        do {
            try await socket.sendBinaryFrame(frame)
            MMLog.info("MMCalls", "sent \(description.kind.rawValue) as a msgpack frame "
                + "(\(description.sdp.count) sdp chars, \(frame.count) frame bytes)")
        } catch {
            sendFailures += 1
            MMLog.error("MMCalls", "could not send \(description.kind.rawValue): \(error)")
            throw error
        }
    }

    func send(candidate: CallsIceCandidate) async throws {
        // A null candidate ("end of candidates") has nothing to send: the plugin has no message for
        // it, and the SDP already carries the gather-complete state.
        guard !candidate.candidate.isEmpty else { return }
        try await sendText(.ice, data: ["data": candidate.jsonString])
    }

    func setMuted(_ muted: Bool, channelID: String) async throws {
        // `unmute`/`mute` carry the channel so the plugin can attribute the message to a call;
        // measured as a payload-less action on 0.29.8 (`client_message.go`), and the web client
        // sends the channel — both are accepted, so the channel is always included.
        try await sendText(muted ? .mute : .unmute,
                           data: [CallsProtocol.channelKey: channelID])
    }

    func setHandRaised(_ raised: Bool, channelID: String) async throws {
        try await sendText(raised ? .raiseHand : .unraiseHand,
                           data: [CallsProtocol.channelKey: channelID])
    }

    func requestCallState(channelID: String) async throws {
        try await sendText(.callState, data: [CallsProtocol.channelKey: channelID])
    }

    // MARK: - Helpers

    private func nextSeq() -> Int {
        seq += 1
        return seq
    }

    private func sendText(_ action: CallsProtocol.Action, data: [String: Any]?) async throws {
        guard action.isAvailable(in: version) else {
            throw CallsSignallingError.unsupportedAction(action, version: version)
        }
        var frame: [String: Any] = ["action": action.wireValue, "seq": nextSeq()]
        if let data { frame["data"] = data }
        guard JSONSerialization.isValidJSONObject(frame),
              let payload = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: payload, encoding: .utf8) else {
            throw CallsSignallingError.couldNotEncode(action)
        }
        do {
            try await socket.sendTextFrame(text)
        } catch {
            sendFailures += 1
            MMLog.error("MMCalls", "could not send \(action.rawValue): \(error)")
            throw error
        }
    }

    private static func short(_ connID: String) -> String {
        String(connID.prefix(6))
    }
}

enum CallsSignallingError: Error, Equatable, CustomStringConvertible {
    case unsupportedAction(CallsProtocol.Action, version: CallsPluginVersion)
    case couldNotEncode(CallsProtocol.Action)

    var description: String {
        switch self {
        case .unsupportedAction(let action, let version):
            return "\(action.rawValue) does not exist on plugin \(version)"
        case .couldNotEncode(let action):
            return "could not encode the \(action.rawValue) frame"
        }
    }
}

/// A scripted `CallsSignalling` for tests: records what the engine sent, and lets the test push
/// events in. The engine's integration test is driven entirely through this, so no server, no
/// socket and no microphone is involved.
final class FakeCallsSignalling: CallsSignalling, @unchecked Sendable {

    enum Sent: Equatable {
        case join(channelID: String)
        case leave(channelID: String)
        case description(CallsSessionDescription)
        case candidate(CallsIceCandidate)
        case muted(Bool, channelID: String)
        case hand(Bool, channelID: String)
        case callStateRequest(channelID: String)
    }

    private let lock = NSLock()
    private var sentStorage: [Sent] = []
    private let continuation: AsyncStream<CallsEvent>.Continuation
    let events: AsyncStream<CallsEvent>
    var joinError: Error?
    var descriptionError: Error?

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: CallsEvent.self,
                                                            bufferingPolicy: .bufferingNewest(512))
        self.events = stream
        self.continuation = continuation
    }

    var sent: [Sent] {
        lock.lock()
        defer { lock.unlock() }
        return sentStorage
    }

    var descriptions: [CallsSessionDescription] {
        sent.compactMap { if case .description(let d) = $0 { return d } else { return nil } }
    }

    var candidates: [CallsIceCandidate] {
        sent.compactMap { if case .candidate(let c) = $0 { return c } else { return nil } }
    }

    func emit(_ event: CallsEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }

    func start() {}

    func stop() {}

    func join(channelID: String) async throws {
        lock.lock(); sentStorage.append(.join(channelID: channelID)); lock.unlock()
        if let joinError { throw joinError }
    }

    func leave(channelID: String) async throws {
        lock.lock(); sentStorage.append(.leave(channelID: channelID)); lock.unlock()
    }

    func send(description: CallsSessionDescription) async throws {
        lock.lock(); sentStorage.append(.description(description)); lock.unlock()
        if let descriptionError { throw descriptionError }
    }

    func send(candidate: CallsIceCandidate) async throws {
        lock.lock(); sentStorage.append(.candidate(candidate)); lock.unlock()
    }

    func setMuted(_ muted: Bool, channelID: String) async throws {
        lock.lock(); sentStorage.append(.muted(muted, channelID: channelID)); lock.unlock()
    }

    func setHandRaised(_ raised: Bool, channelID: String) async throws {
        lock.lock(); sentStorage.append(.hand(raised, channelID: channelID)); lock.unlock()
    }

    func requestCallState(channelID: String) async throws {
        lock.lock(); sentStorage.append(.callStateRequest(channelID: channelID)); lock.unlock()
    }
}
