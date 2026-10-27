// T44c — the engine, driven end to end through its seams.
//
// These tests exercise the real libwebrtc peer connection (the framework is linked into this target),
// but **not** the real world: `CallsSignalling` is faked, the microphone grant is faked, and the
// audio session is faked. The second half of each negotiation is a genuine second
// `RTCPeerConnection`, so the SDP the engine produces is fed to libwebrtc itself — an offer that only
// looks like an offer fails here.
//
// What is pinned (each rule is a measured fact from docs/t44-build-note.md §5 / t44b §5):
//  * the client offers; it never waits for the SFU to offer first (a silent client is dropped at the
//    plugin's 10 s signalling timeout);
//  * the offer goes out only **after** the join frame, even when the ack races the join;
//  * a denied microphone is a visible state, not a silent failure — and `joinWithoutMicrophone` joins
//    anyway (the web client's behaviour) while still surfacing the refusal;
//  * the SFU's `answer` is applied and moves the engine to `.connecting`;
//  * a **server-initiated re-offer** is answered with an `answer` on the binary `sdp` path — the step
//    without which inbound RTP stays at zero;
//  * trickled candidates are only sent after the offer (the plugin has no session to route them to
//    before the `sdp` lands), and remote candidates that arrive before the answer are queued;
//  * `stop()` leaves the call, closes the connection and gives the audio session back.

import Foundation
import XCTest
@preconcurrency import WebRTC
@testable import Mattermost

final class T44CCallsEngineTests: XCTestCase {

    private let timings = CallsEngineTimings(iceGatheringTimeout: 2,
                                             joinAckTimeout: 2,
                                             pollInterval: 0.01,
                                             permissionTimeout: 2)

    // MARK: - Start

    func testStartAsksForTheMicThenJoinsThenOffers() async throws {
        let signalling = FakeCallsSignalling()
        let permissions = FakeCallsPermissions(result: .granted)
        let engine = CallsEngine(signalling: signalling, permissions: permissions,
                                 audioSession: FakeCallsAudioSession(), timings: timings)

        // The ack is queued before `start` runs: the engine must still join first.
        signalling.push(.joinAck(connID: "abc"))

        let state = await engine.start(channelID: "chan1")
        XCTAssertEqual(state, .negotiating, "offer sent, waiting for the SFU's answer")

        XCTAssertEqual(permissions.requests, 1)
        XCTAssertEqual(signalling.joins, ["chan1"])
        XCTAssertEqual(signalling.descriptions.count, 1)
        let offer = try XCTUnwrap(signalling.descriptions.first)
        XCTAssertEqual(offer.kind, .offer)
        XCTAssertTrue(offer.sdp.contains("m=audio"), "a call offer without an audio m-line is not "
                      + "a call: the SFU would have nothing to forward")
        XCTAssertTrue(offer.sdp.contains("a=sendrecv"))

        // The join must precede the offer in the frame order: an `sdp` before a `join` has no session.
        // Trickled candidates follow the offer, never precede it.
        XCTAssertEqual(signalling.order.first, "join")
        XCTAssertEqual(signalling.order.dropFirst().first, "sdp:offer",
                       "the offer is the second frame: \(signalling.order)")
        let offerIndex = try XCTUnwrap(signalling.order.firstIndex(of: "sdp:offer"))
        for (index, frame) in signalling.order.enumerated() where frame == "ice" {
            XCTAssertGreaterThan(index, offerIndex,
                                 "a candidate before the offer has no session to reach")
        }

        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.offersSent, 1)
        XCTAssertTrue(snapshot.mediaEngineCreated)
    }

    /// When the plugin's ack is lost (it is broadcast, not a reply), the engine must still offer
    /// rather than hang: the offer is valid without an ack.
    func testOfferHappensEvenWithoutAJoinAck() async throws {
        let signalling = FakeCallsSignalling()
        let engine = CallsEngine(signalling: signalling,
                                 permissions: FakeCallsPermissions(result: .granted),
                                 audioSession: FakeCallsAudioSession(),
                                 timings: CallsEngineTimings(iceGatheringTimeout: 0.3,
                                                            joinAckTimeout: 0.2,
                                                            pollInterval: 0.01,
                                                            permissionTimeout: 1))

        let state = await engine.start(channelID: "chan1")
        XCTAssertEqual(state, .negotiating)
        XCTAssertEqual(signalling.descriptions.first?.kind, .offer)
    }

    // MARK: - Permission

    func testDeniedMicrophoneIsAVisibleState() async throws {
        let signalling = FakeCallsSignalling()
        let engine = CallsEngine(signalling: signalling,
                                 permissions: FakeCallsPermissions(result: .denied),
                                 audioSession: FakeCallsAudioSession(),
                                 timings: timings)

        let state = await engine.start(channelID: "chan1")

        XCTAssertEqual(state, .permissionDenied)
        XCTAssertTrue(signalling.joins.isEmpty, "a call with no microphone is not joined silently")
        XCTAssertTrue(signalling.descriptions.isEmpty)
        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.microphonePermission, .denied)
        XCTAssertNotNil(snapshot.error, "the refusal is recorded, not swallowed")
    }

    /// The web client's behaviour: you may decline the microphone and still be in the call, muted.
    func testJoinWithoutMicrophoneStillNegotiates() async throws {
        let signalling = FakeCallsSignalling()
        let engine = CallsEngine(signalling: signalling,
                                 permissions: FakeCallsPermissions(result: .denied),
                                 audioSession: FakeCallsAudioSession(),
                                 policy: .joinWithoutMicrophone,
                                 timings: timings)
        signalling.push(.joinAck(connID: "abc"))

        let state = await engine.start(channelID: "chan1")

        XCTAssertEqual(state, .negotiating)
        XCTAssertEqual(signalling.joins, ["chan1"])
        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.microphonePermission, .denied,
                       "the refusal is still surfaced: the UI has to say 'no mic'")
    }

    func testAudioSessionFailureIsRecordedButDoesNotStopTheCall() async throws {
        let signalling = FakeCallsSignalling()
        let audio = FakeCallsAudioSession()
        audio.activateError = FakeCallsAudioSession.Failure()
        let engine = CallsEngine(signalling: signalling,
                                 permissions: FakeCallsPermissions(result: .granted),
                                 audioSession: audio, timings: timings)
        signalling.push(.joinAck(connID: "abc"))

        let state = await engine.start(channelID: "chan1")

        XCTAssertEqual(state, .negotiating, "signalling can proceed without an audio device")
        let snapshot = await engine.currentSnapshot()
        XCTAssertNotNil(snapshot.error)
    }

    // MARK: - A real second peer connection

    func testTheSFUsAnswerIsAppliedAndTheEngineConnects() async throws {
        try requirePeerTestHost()
        let signalling = FakeCallsSignalling()
        let engine = CallsEngine(signalling: signalling,
                                 permissions: FakeCallsPermissions(result: .granted),
                                 audioSession: FakeCallsAudioSession(),
                                 timings: timings)
        signalling.push(.joinAck(connID: "abc"))

        let started = await engine.start(channelID: "chan1")
        XCTAssertEqual(started, .negotiating)
        let offer = try XCTUnwrap(signalling.descriptions.first)

        // The remote side: a real libwebrtc peer that answers the engine's offer.
        let peer = PeerFixture()
        let answer = try await peer.answer(to: offer)
        signalling.push(.signal(CallsSignal(connID: "abc",
                                            payload: .description(answer))))

        let state = await engine.waitForState([.connecting, .connected], timeout: 5)
        XCTAssertTrue([.connecting, .connected].contains(state), "state was \(state)")

        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.remoteSDP, answer.sdp)
        XCTAssertEqual(snapshot.offersSent, 1)
        XCTAssertNil(snapshot.error)

        await engine.stop()
        peer.close()
    }

    /// The post-connect renegotiation. Without answering this the engine has transceivers the SFU
    /// never connects, and inbound RTP stays at zero (T44b §5 measured exactly that).
    func testAServerReOfferIsAnswered() async throws {
        try requirePeerTestHost()
        let signalling = FakeCallsSignalling()
        let engine = CallsEngine(signalling: signalling,
                                 permissions: FakeCallsPermissions(result: .granted),
                                 audioSession: FakeCallsAudioSession(),
                                 timings: timings)
        signalling.push(.joinAck(connID: "abc"))

        _ = await engine.start(channelID: "chan1")
        let offer = try XCTUnwrap(signalling.descriptions.first)
        let peer = PeerFixture()
        let answer = try await peer.answer(to: offer)
        signalling.push(.signal(CallsSignal(connID: "abc", payload: .description(answer))))
        _ = await engine.waitForState([.connecting, .connected], timeout: 5)

        // The SFU now offers at us.
        let reOffer = try await peer.reOffer()
        signalling.push(.signal(CallsSignal(connID: "abc", payload: .description(reOffer))))

        let answered = await waitUntil(timeout: 5) {
            signalling.descriptions.contains { $0.kind == .answer }
        }
        XCTAssertTrue(answered, "the engine must answer the SFU's re-offer")

        let ourAnswer = try XCTUnwrap(signalling.descriptions.last { $0.kind == .answer })
        XCTAssertTrue(ourAnswer.sdp.contains("m=audio") || ourAnswer.sdp.contains("a=sendrecv"),
                      "the answer must describe the audio session, got: \(ourAnswer.sdp.prefix(120))")

        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.serverOffersAnswered, 1)
        XCTAssertNil(snapshot.error)

        await engine.stop()
        peer.close()
    }

    /// A candidate that arrives before the answer is queued, not dropped and not applied to a
    /// description-less connection (libwebrtc rejects that, and the call then has no pair).
    func testARemoteCandidateBeforeTheAnswerIsQueuedAndTheCallStillConnects() async throws {
        try requirePeerTestHost()
        let signalling = FakeCallsSignalling()
        let engine = CallsEngine(signalling: signalling,
                                 permissions: FakeCallsPermissions(result: .granted),
                                 audioSession: FakeCallsAudioSession(),
                                 timings: timings)
        signalling.push(.joinAck(connID: "abc"))
        _ = await engine.start(channelID: "chan1")
        let offer = try XCTUnwrap(signalling.descriptions.first)

        // A candidate for a session we have no remote description for yet.
        signalling.push(.signal(CallsSignal(connID: "abc", payload: .candidate(
            CallsIceCandidate(candidate: "candidate:1 1 udp 1 10.0.0.1 5000 typ host",
                              sdpMid: "0", sdpMLineIndex: 0)))))
        let received = await waitUntil(timeout: 3) {
            (await engine.currentSnapshot()).candidatesReceived == 1
        }
        XCTAssertTrue(received)

        let peer = PeerFixture()
        let answer = try await peer.answer(to: offer)
        signalling.push(.signal(CallsSignal(connID: "abc", payload: .description(answer))))

        let state = await engine.waitForState([.connecting, .connected], timeout: 5)
        XCTAssertTrue([.connecting, .connected].contains(state), "state was \(state)")
        let snapshot = await engine.currentSnapshot()
        XCTAssertNil(snapshot.error, "a queued candidate must not surface as an error")

        await engine.stop()
        peer.close()
    }

    // MARK: - Local candidates

    /// Trickle only after the offer: before the `sdp` frame the plugin has no RTC session to route an
    /// `ice` message to.
    func testLocalCandidatesAreSentOnlyAfterTheOffer() async throws {
        let signalling = FakeCallsSignalling()
        let engine = CallsEngine(signalling: signalling,
                                 permissions: FakeCallsPermissions(result: .granted),
                                 audioSession: FakeCallsAudioSession(),
                                 timings: timings)
        signalling.push(.joinAck(connID: "abc"))

        _ = await engine.start(channelID: "chan1")

        let anyCandidate = await waitUntil(timeout: 2) { !signalling.candidates.isEmpty }
        // Gathering on a loopback-only host can legitimately produce nothing; that is not a failure,
        // so the assertion is on the *order* when there is something to order.
        if anyCandidate {
            let firstCandidateIndex = try XCTUnwrap(signalling.order.firstIndex { $0 == "ice" })
            let offerIndex = try XCTUnwrap(signalling.order.firstIndex { $0 == "sdp:offer" })
            XCTAssertLessThan(offerIndex, firstCandidateIndex,
                              "a candidate before the offer has no session to reach")
        }

        await engine.stop()
    }

    // MARK: - Session state

    func testMuteSendsTheSessionStateAndDisablesTheTrack() async throws {
        let signalling = FakeCallsSignalling()
        let engine = CallsEngine(signalling: signalling,
                                 permissions: FakeCallsPermissions(result: .granted),
                                 audioSession: FakeCallsAudioSession(),
                                 timings: timings)
        signalling.push(.joinAck(connID: "abc"))
        _ = await engine.start(channelID: "chan1")

        await engine.setMuted(true)
        await engine.setMuted(false)

        XCTAssertEqual(signalling.mutes.map { "\($0.0):\($0.1)" }, ["chan1:true", "chan1:false"])
        await engine.stop()
    }

    func testHandRaiseIsForwarded() async throws {
        let signalling = FakeCallsSignalling()
        let engine = CallsEngine(signalling: signalling,
                                 permissions: FakeCallsPermissions(result: .granted),
                                 audioSession: FakeCallsAudioSession(),
                                 timings: timings)
        signalling.push(.joinAck(connID: "abc"))
        _ = await engine.start(channelID: "chan1")

        await engine.setHandRaised(true)
        XCTAssertEqual(signalling.hands.map { "\($0.0):\($0.1)" }, ["chan1:true"])
        await engine.stop()
    }

    func testStopLeavesClosesAndGivesTheAudioSessionBack() async throws {
        let signalling = FakeCallsSignalling()
        let audio = FakeCallsAudioSession()
        let engine = CallsEngine(signalling: signalling,
                                 permissions: FakeCallsPermissions(result: .granted),
                                 audioSession: audio, timings: timings)
        signalling.push(.joinAck(connID: "abc"))
        _ = await engine.start(channelID: "chan1")

        await engine.stop()

        XCTAssertEqual(signalling.leaves, ["chan1"])
        XCTAssertEqual(audio.activations, 1)
        XCTAssertEqual(audio.deactivations, 1)
        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.state, .ended)
        XCTAssertFalse(snapshot.mediaEngineCreated, "the factory and connection must be released")
    }

    /// The call ended on the server (`call_end`): the engine's own state says so, so a surface does
    /// not keep drawing a call that is over.
    func testCallEndMovesTheEngineToEnded() async throws {
        let signalling = FakeCallsSignalling()
        let engine = CallsEngine(signalling: signalling,
                                 permissions: FakeCallsPermissions(result: .granted),
                                 audioSession: FakeCallsAudioSession(),
                                 timings: timings)
        signalling.push(.joinAck(connID: "abc"))
        _ = await engine.start(channelID: "chan1")

        signalling.push(.callEnded(channelID: "chan1"))
        let ended = await waitUntil(timeout: 3) {
            (await engine.currentSnapshot()).state == .ended
        }
        XCTAssertTrue(ended)
        await engine.stop()
    }

    // MARK: - Stats

    func testStatisticsReadTheEngineWithoutCrashing() async throws {
        let signalling = FakeCallsSignalling()
        let engine = CallsEngine(signalling: signalling,
                                 permissions: FakeCallsPermissions(result: .granted),
                                 audioSession: FakeCallsAudioSession(),
                                 timings: timings)
        signalling.push(.joinAck(connID: "abc"))
        _ = await engine.start(channelID: "chan1")

        let stats = await engine.statistics()
        // No media has flowed yet, so the counters are zero — but reading them must work, because
        // that read is what the conformance probe logs.
        XCTAssertEqual(stats.inboundPackets, 0)
        XCTAssertEqual(stats.outboundPackets, 0)
        await engine.stop()
    }

    // MARK: - Helpers

    /// A second `RTCPeerConnectionFactory` builds a second audio device module, and a test-host
    /// process **blocks inside CoreAudio** doing that on this host: the run wedges while logging
    /// `HALC_ShellObject::HasProperty: call to the proxy failed, Error: 2684` every 30 s (measured;
    /// `docs/t44c-calls-engine.md` §6 — `coreaudiod` is up, but the plugin host's CoreAudio proxy is
    /// not reachable from the xctest process). The single-factory tests below are unaffected, which is
    /// why only the peer-negotiation tests are gated.
    ///
    /// They are **opt-in** rather than silently skipped: set `MM_CALLS_PEER_TESTS=1` on a host with a
    /// working audio device to run them. Anything else would either hang the suite or claim a
    /// negotiation these assertions never exercised.
    private func requirePeerTestHost() throws {
        let enabled = ProcessInfo.processInfo.environment["MM_CALLS_PEER_TESTS"] == "1"
        try XCTSkipUnless(enabled,
                          "peer-negotiation test: needs a second RTCPeerConnectionFactory, which "
                          + "blocks in CoreAudio on this host. Re-run with MM_CALLS_PEER_TESTS=1 on a "
                          + "host with audio (docs/t44c-calls-engine.md §6).")
    }

    private func waitUntil(timeout: TimeInterval,
                           _ condition: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }
}

// MARK: - Fakes

final class FakeCallsSignalling: CallsSignalling, @unchecked Sendable {

    let events: AsyncStream<CallsEvent>
    private let continuation: AsyncStream<CallsEvent>.Continuation
    private let lock = NSLock()

    private var joinsStorage: [String] = []
    private var leavesStorage: [String] = []
    private var descriptionsStorage: [CallsSessionDescription] = []
    private var candidatesStorage: [CallsIceCandidate] = []
    private var mutesStorage: [(String, Bool)] = []
    private var handsStorage: [(String, Bool)] = []
    /// The order the engine put frames on the wire — `join`, `sdp:offer`, `ice`, …
    private var orderStorage: [String] = []

    /// Set to make every send throw (a dead socket).
    var sendError: Error?

    init() {
        (events, continuation) = AsyncStream.makeStream(of: CallsEvent.self,
                                                        bufferingPolicy: .bufferingNewest(64))
    }

    var joins: [String] { locked { joinsStorage } }
    var leaves: [String] { locked { leavesStorage } }
    var descriptions: [CallsSessionDescription] { locked { descriptionsStorage } }
    var candidates: [CallsIceCandidate] { locked { candidatesStorage } }
    var order: [String] { locked { orderStorage } }
    var mutes: [(String, Bool)] { locked { mutesStorage } }
    var hands: [(String, Bool)] { locked { handsStorage } }

    func start() {}
    func stop() {}

    func join(channelID: String) async throws {
        if let sendError { throw sendError }
        locked { joinsStorage.append(channelID); orderStorage.append("join") }
    }

    func leave(channelID: String) async throws {
        locked { leavesStorage.append(channelID); orderStorage.append("leave") }
    }

    func send(description: CallsSessionDescription) async throws {
        if let sendError { throw sendError }
        locked {
            descriptionsStorage.append(description)
            orderStorage.append("sdp:\(description.kind.rawValue)")
        }
    }

    func send(candidate: CallsIceCandidate) async throws {
        if let sendError { throw sendError }
        locked { candidatesStorage.append(candidate); orderStorage.append("ice") }
    }

    func setMuted(_ muted: Bool, channelID: String) async throws {
        locked { mutesStorage.append((channelID, muted)) }
    }

    func setHandRaised(_ raised: Bool, channelID: String) async throws {
        locked { handsStorage.append((channelID, raised)) }
    }

    func requestCallState(channelID: String) async throws {}

    /// Deliver an event to the engine.
    func push(_ event: CallsEvent) { continuation.yield(event) }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

final class FakeCallsPermissions: CallsPermissionRequesting, @unchecked Sendable {

    private let lock = NSLock()
    private let result: CallsMicrophonePermission
    private var requestsStorage = 0

    init(result: CallsMicrophonePermission) { self.result = result }

    var requests: Int {
        lock.lock(); defer { lock.unlock() }
        return requestsStorage
    }

    func requestMicrophone(timeout: TimeInterval) async -> CallsMicrophonePermission {
        lock.lock(); requestsStorage += 1; lock.unlock()
        return result
    }

    func currentMicrophonePermission() -> CallsMicrophonePermission { result }
}

final class FakeCallsAudioSession: CallsAudioSessionControlling, @unchecked Sendable {

    struct Failure: Error {}

    private let lock = NSLock()
    private var activationsStorage = 0
    private var deactivationsStorage = 0
    var activateError: Error?

    var activations: Int {
        lock.lock(); defer { lock.unlock() }
        return activationsStorage
    }

    var deactivations: Int {
        lock.lock(); defer { lock.unlock() }
        return deactivationsStorage
    }

    func activateForCall() throws {
        if let activateError { throw activateError }
        lock.lock(); activationsStorage += 1; lock.unlock()
    }

    func deactivate() {
        lock.lock(); deactivationsStorage += 1; lock.unlock()
    }

    func currentConfiguration() -> String { "playAndRecord/voiceChat" }
}

// MARK: - A second, real peer connection

/// The other end of a negotiation, built from libwebrtc itself: it answers the engine's offer and can
/// re-offer. Nothing here touches the network — the SDP is exchanged in memory, which is exactly the
/// half of the protocol the engine is responsible for.
final class PeerFixture {

    private let factory: RTCPeerConnectionFactory
    private let connection: RTCPeerConnection

    init() {
        factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                           decoderFactory: RTCDefaultVideoDecoderFactory())
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.iceServers = []
        connection = factory.peerConnection(
            with: configuration,
            constraints: RTCMediaConstraints(mandatoryConstraints: [
                "OfferToReceiveAudio": "true", "OfferToReceiveVideo": "false",
            ], optionalConstraints: nil),
            delegate: nil)!
    }

    func answer(to offer: CallsSessionDescription) async throws -> CallsSessionDescription {
        try await apply(.offer, sdp: offer.sdp)
        let answer = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            connection.answer(for: CallsEngine.offerAnswerConstraints()) { description, error in
                if let description { continuation.resume(returning: description) }
                else { continuation.resume(throwing: error ?? CallsEngineError.noLocalDescription) }
            }
        }
        try await setLocal(answer)
        guard let local = connection.localDescription else {
            throw CallsEngineError.noLocalDescription
        }
        return CallsSessionDescription(kind: .answer, sdp: local.sdp)
    }

    /// A genuine re-offer from the far side (a new audio line, which is what the SFU adds when it
    /// starts forwarding media toward the client).
    func reOffer() async throws -> CallsSessionDescription {
        let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil,
                                                                  optionalConstraints: nil))
        let track = factory.audioTrack(with: source, trackId: "remote-audio")
        _ = connection.add(track, streamIds: ["sfu"])

        let offer = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            connection.offer(for: CallsEngine.offerAnswerConstraints()) { description, error in
                if let description { continuation.resume(returning: description) }
                else { continuation.resume(throwing: error ?? CallsEngineError.noLocalDescription) }
            }
        }
        try await setLocal(offer)
        guard let local = connection.localDescription else {
            throw CallsEngineError.noLocalDescription
        }
        return CallsSessionDescription(kind: .offer, sdp: local.sdp)
    }

    func close() {
        connection.close()
    }

    private func apply(_ type: RTCSdpType, sdp: String) async throws {
        let description = RTCSessionDescription(type: type, sdp: sdp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setRemoteDescription(description) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func setLocal(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(description) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
