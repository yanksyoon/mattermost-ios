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

    /// One engine publication: the snapshot, and how many events the engine had folded when it fired.
    ///
    /// The ordinal is what lets a test assert an **absence** safely ("buddy is no longer a session"):
    /// `TestSignal` remembers every value, so a bare `session(forUser:) == nil` predicate would be
    /// satisfied by a snapshot from *before* the join. Awaiting the fold that should have removed it
    /// anchors the read to the right event, and replaces polling `currentSnapshot()` on a clock
    /// (kanban t_00fb623c).
    struct Publication: Sendable {
        let ordinal: Int
        let snapshot: CallsEngineSnapshot
    }

    /// Subscribe to the engine's own publication point. Install it *after* `startedEngine()` (the
    /// join ack is folded during `start()`) and before the events under test are pushed.
    private func observe(_ engine: CallsEngine) async -> TestSignal<Publication> {
        let signal = TestSignal<Publication>()
        let counter = SignalCounter()
        await engine.observeSnapshots { snapshot in
            signal.send(Publication(ordinal: counter.bump(), snapshot: snapshot))
        }
        return signal
    }

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

        let answered = await signalling.descriptionSignal.wait(until: { $0 == "answer" }, timeout: 5)
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
        let published = await observe(engine)
        let offer = try XCTUnwrap(signalling.descriptions.first)

        // A candidate for a session we have no remote description for yet.
        signalling.push(.signal(CallsSignal(connID: "abc", payload: .candidate(
            CallsIceCandidate(candidate: "candidate:1 1 udp 1 10.0.0.1 5000 typ host",
                              sdpMid: "0", sdpMLineIndex: 0)))))
        await awaitSignal("the queued candidate to be counted", signal: published) {
            $0.snapshot.candidatesReceived == 1
        }

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

        let anyCandidate = await signalling.candidateSentSignal.wait(until: { _ in true }, timeout: 2)
        // Gathering on a loopback-only host can legitimately produce nothing; that is not a failure,
        // so the assertion is on the *order* when there is something to order. The 2 s is therefore a
        // bounded observation window on a signal, not a budget for a value that must arrive.
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

    /// A confirmed `user_unmuted` must survive the next snapshot read.
    ///
    /// The live T44d run measured the opposite: the plugin broadcast `user_unmuted`, the control
    /// showed "unmuted", and 3 s later it read "muted" again because `CallsEngine` ignored the delta
    /// and the surface's "the snapshot wins" rule re-applied a stale `call_state`. The engine now
    /// folds the delta, so the snapshot carries the unmute.
    func testAConfirmedUnmuteSurvivesTheNextSnapshot() async throws {
        let (signalling, engine) = await startedEngine()
        let published = await observe(engine)
        signalling.push(.callState(channelID: "chan1",
                                   call: call(sessions: [CallsSession(sessionID: "s1", userID: "me",
                                                                      unmuted: false)])))
        await awaitSignal("the call state to land", signal: published) {
            $0.snapshot.call?.session(forUser: "me")?.unmuted == false
        }
        // Every publication after this point is numbered from here, so the *third* event's snapshot is
        // `base + 2` whether or not the join ack was folded after the observer was installed.
        let base = published.recorded.last?.ordinal ?? 0

        signalling.push(.muteChanged(channelID: "chan1", userID: "me", sessionID: "s1", unmuted: true))

        await awaitSignal("the engine to fold `user_unmuted`", signal: published) {
            $0.ordinal > base && $0.snapshot.call?.session(forUser: "me")?.unmuted == true
        }
        await engine.stop()
    }

    /// A delta that names another channel's call must not touch this one.
    func testADeltaForAnotherChannelIsNotFolded() async throws {
        let (signalling, engine) = await startedEngine()
        let published = await observe(engine)
        signalling.push(.callState(channelID: "chan1",
                                   call: call(sessions: [CallsSession(sessionID: "s1", userID: "me",
                                                                      unmuted: false)])))
        await awaitSignal("the call state to land", signal: published) {
            $0.snapshot.call?.session(forUser: "me")?.unmuted == false
        }
        let base = published.recorded.last?.ordinal ?? 0

        signalling.push(.muteChanged(channelID: "chan2", userID: "me", sessionID: "s1", unmuted: true))
        signalling.push(.userJoined(channelID: "chan2", userID: "stranger", sessionID: "s9"))
        // Both events are folds, and every fold publishes: awaiting `base + 2` is the fence that proves
        // neither touched this call (no settle on the clock).
        await awaitSignal("both foreign-channel deltas to be folded", signal: published) {
            $0.ordinal >= base + 2
        }

        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.call?.session(forUser: "me")?.unmuted, false)
        XCTAssertNil(snapshot.call?.session(forUser: "stranger"),
                     "another channel's participant must not become a tile in this call")
        await engine.stop()
    }

    /// A second participant appears and leaves: the tiles follow the deltas, not only `call_state`.
    func testUserJoinedAndLeftMoveTheSessions() async throws {
        let (signalling, engine) = await startedEngine()
        let published = await observe(engine)
        signalling.push(.callState(channelID: "chan1",
                                   call: call(sessions: [CallsSession(sessionID: "s1", userID: "me")])))
        await awaitSignal("the call state to land", signal: published) {
            $0.snapshot.call?.sessions.count == 1
        }
        let base = published.recorded.last?.ordinal ?? 0

        signalling.push(.userJoined(channelID: "chan1", userID: "buddy", sessionID: "s2"))
        await awaitSignal("`user_joined` to add a session", signal: published) {
            $0.snapshot.call?.session(forUser: "buddy") != nil
        }

        signalling.push(.userLeft(channelID: "chan1", userID: "buddy", sessionID: "s2"))
        // The absence is anchored to the fold that should remove it: `base + 2` is `user_left`.
        await awaitSignal("`user_left` to drop the session", signal: published) { $0.ordinal >= base + 2 }
        let afterLeave = await engine.currentSnapshot()
        XCTAssertNil(afterLeave.call?.session(forUser: "buddy"))
        await engine.stop()
    }

    /// Raise/lower and a host change are deltas too, and the surface reads both from the snapshot.
    func testRaisedHandAndHostChangeAreFolded() async throws {
        let (signalling, engine) = await startedEngine()
        let published = await observe(engine)
        signalling.push(.callState(channelID: "chan1",
                                   call: call(sessions: [CallsSession(sessionID: "s1", userID: "me")])))
        await awaitSignal("the call state to land", signal: published) {
            $0.snapshot.call?.session(forUser: "me") != nil
        }
        let base = published.recorded.last?.ordinal ?? 0

        signalling.push(.handChanged(channelID: "chan1", userID: "me", sessionID: "s1", raised: true))
        await awaitSignal("`user_raise_hand` to reach the call state", signal: published) {
            $0.snapshot.call?.session(forUser: "me")?.raisedHand == true
        }

        signalling.push(.handChanged(channelID: "chan1", userID: "me", sessionID: "s1", raised: false))
        await awaitSignal("`user_lower_hand` to be folded", signal: published) {
            $0.ordinal >= base + 2 && $0.snapshot.call?.session(forUser: "me")?.raisedHand == false
        }

        signalling.push(.hostChanged(channelID: "chan1", hostID: "me"))
        await awaitSignal("the host change to be folded", signal: published) {
            $0.snapshot.call?.hostID == "me"
        }
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
        XCTAssertEqual(signalling.stops, 1)
        XCTAssertEqual(audio.activations, 1)
        XCTAssertEqual(audio.deactivations, 1)
        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.state, .ended)
        XCTAssertFalse(snapshot.mediaEngineCreated, "the factory and connection must be released")
    }

    /// The CI hang, held open: `stop()` must finish while libwebrtc's `close()` never returns.
    ///
    /// Measured on both CI legs (t_01f65f1d, runs 40899137785 and 40895827104): the test thread sat
    /// in `peerConnection.close()` for the whole 5-minute allowance — 495/495 spindump samples in
    /// `__psynch_cvwait`, with libwebrtc's `signaling_thread` and `worker_thread` idle. `stop()`
    /// called that close on the engine's executor, so the engine went with it: no `.ended`, no
    /// `signalling.stop()`, and a reader would be stuck in a call the server had already ended.
    ///
    /// This hands the close to a scheduler that holds it (never runs it) and requires the engine's
    /// whole teardown contract to be finished anyway. It fails on an engine that awaits the close:
    /// there it never returns and the wait below reports after 10 s.
    func testStopFinishesWhileLibwebrtcCloseIsHeldOpen() async throws {
        let signalling = FakeCallsSignalling()
        let audio = FakeCallsAudioSession()
        let teardown = HoldingCallsMediaTeardown()
        let engine = CallsEngine(signalling: signalling,
                                 permissions: FakeCallsPermissions(result: .granted),
                                 audioSession: audio,
                                 timings: timings,
                                 teardown: teardown)
        signalling.push(.joinAck(connID: "abc"))
        _ = await engine.start(channelID: "chan1")

        let returned = TestSignal<Bool>()
        Task {
            await engine.stop()
            returned.send(true)
        }
        await awaitSignal("`stop()` to finish while libwebrtc's close() is held open",
                          signal: returned, timeout: 10)

        XCTAssertEqual(teardown.held, 1, "the blocking close is handed to the teardown scheduler")
        XCTAssertEqual(signalling.leaves, ["chan1"], "the socket side is finished before the close")
        XCTAssertEqual(signalling.stops, 1, "the socket is stopped even though close() never returns")
        XCTAssertEqual(audio.deactivations, 1)
        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.state, .ended)
        XCTAssertFalse(snapshot.mediaEngineCreated)
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
        let published = await observe(engine)

        signalling.push(.callEnded(channelID: "chan1"))
        await awaitSignal("the engine to move to .ended", signal: published) {
            $0.snapshot.state == .ended
        }
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

    /// An engine started against a fake signalling layer, plus the fake (so a test can push events).
    private func startedEngine() async -> (FakeCallsSignalling, CallsEngine) {
        let signalling = FakeCallsSignalling()
        let engine = CallsEngine(signalling: signalling,
                                 permissions: FakeCallsPermissions(result: .granted),
                                 audioSession: FakeCallsAudioSession(),
                                 timings: timings)
        signalling.push(.joinAck(connID: "abc"))
        _ = await engine.start(channelID: "chan1")
        return (signalling, engine)
    }

    /// A `call_state` payload for folding tests: one call on `chan1` with the given sessions.
    private func call(sessions: [CallsSession]) -> CallsCall {
        CallsCall(id: "call1", channelID: "chan1", startAt: 1_793_000_000_000,
                  hostID: "me", sessions: sessions)
    }
}

// MARK: - Fakes

final class FakeCallsSignalling: CallsSignalling, @unchecked Sendable {

    let events: AsyncStream<CallsEvent>
    private let continuation: AsyncStream<CallsEvent>.Continuation
    private let lock = NSLock()

    private var joinsStorage: [String] = []
    private var leavesStorage: [String] = []
    private var stopsStorage = 0
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
    /// How many times the engine stopped the socket — part of `stop()`'s contract, and the half the
    /// CI hang used to skip (t_01f65f1d).
    var stops: Int { locked { stopsStorage } }
    var descriptions: [CallsSessionDescription] { locked { descriptionsStorage } }
    var candidates: [CallsIceCandidate] { locked { candidatesStorage } }
    var order: [String] { locked { orderStorage } }
    var mutes: [(String, Bool)] { locked { mutesStorage } }
    var hands: [(String, Bool)] { locked { handsStorage } }

    /// Frames the engine wrote, as running counts — a test awaits these instead of polling
    /// `descriptions` / `candidates` on a clock (kanban t_00fb623c).
    let descriptionSignal = TestSignal<String>()
    let candidateSentSignal = TestSignal<Int>()
    private var candidatesSent = 0

    func start() {}
    func stop() { locked { stopsStorage += 1 } }

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
        descriptionSignal.send(description.kind.rawValue)
    }

    func send(candidate: CallsIceCandidate) async throws {
        if let sendError { throw sendError }
        let count: Int = locked { candidatesStorage.append(candidate); orderStorage.append("ice")
            candidatesSent += 1
            return candidatesSent
        }
        candidateSentSignal.send(count)
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

// MARK: - A teardown that never finishes

/// Holds libwebrtc's close open forever, the way the CI runner does (t_01f65f1d), without owning one:
/// the work is accepted and never run, so a `stop()` that waits for it can never return.
final class HoldingCallsMediaTeardown: CallsMediaTeardownScheduling, @unchecked Sendable {

    private let lock = NSLock()
    private var heldStorage: [@Sendable () -> Void] = []

    /// How many teardowns were handed over — one per call, each still "in flight".
    var held: Int {
        lock.lock(); defer { lock.unlock() }
        return heldStorage.count
    }

    func schedule(_ work: @escaping @Sendable () -> Void) {
        lock.lock(); heldStorage.append(work); lock.unlock()
    }
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
