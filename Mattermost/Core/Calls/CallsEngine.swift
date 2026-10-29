// The WebRTC engine wrapper: peer-connection lifecycle, the local audio track, ICE trickle, and the
// two SDP roles Calls actually needs.
//
// Protocol facts this implements (all measured — docs/t44-build-note.md §5, docs/t44b-calls-media-path.md §5):
//
//  1. **The client is the offerer.** The SFU never offers first; a client that joins and waits is
//     disconnected at the plugin's 10 s signalling timeout (probe check 8). So `start()` joins with a
//     local audio track added and lets negotiation produce the offer.
//  2. **The SFU re-offers after ICE connects**, and that offer carries the media the SFU forwards
//     toward this client. A client that ignores it receives nothing at all (T44b: inbound-rtp
//     counters at zero). Both roles are therefore implemented here: `offer` → set local → send, and
//     `offer` from the peer → set remote → answer → send.
//  3. **`sdp` only exists on the binary MessagePack path** (`CallsSDPCodec`), while **`ice` is a JSON
//     string** on the text path (`CallsIceCandidate.jsonString`).
//
// What this type deliberately does not do: no UI, no call surface, no participant rendering — it is
// the engine a later surface card renders. It also does not own the socket: `CallsSignalling` is the
// seam, so the whole lifecycle below runs in a unit test against `FakeCallsSignalling` with no
// server, no plugin and no microphone.

import AVFoundation
import Foundation
@preconcurrency import WebRTC

/// Where the engine is. Every state is reachable and every terminal state says why.
enum CallsEngineState: Equatable, Sendable {
    case idle
    /// Asking for the microphone (`AVCaptureDevice.requestAccess`).
    case requestingPermission
    /// The grant was refused and the caller required one. A **visible** state, not a silent nothing.
    case permissionDenied
    /// Joined the call on the socket; waiting for the plugin's ack before offering.
    case joining
    /// The offer exists and is being sent.
    case offering
    /// The offer went out; waiting for the SFU's answer.
    case negotiating
    /// The answer was applied; ICE is in progress.
    case connecting
    /// ICE reported connected/completed: media can flow.
    case connected
    case failed(String)
    case ended

    var isTerminal: Bool {
        switch self {
        case .failed, .ended: return true
        default: return false
        }
    }
}

/// What to do when the microphone grant is refused.
enum CallsEnginePolicy: Equatable, Sendable {
    /// A call with no microphone is not a call: refuse to start, and surface `.permissionDenied`.
    case requireMicrophone
    /// Join anyway (the web client's behaviour when the user denies the mic: you hear the call and
    /// are muted). The grant is still surfaced, so the caller can render "no mic".
    case joinWithoutMicrophone
}

/// Timings, injectable so tests do not sleep for real seconds.
struct CallsEngineTimings: Sendable {
    /// How long to wait for ICE gathering to complete before sending the offer with what we have.
    var iceGatheringTimeout: TimeInterval = 3
    /// How long to wait for the plugin's `join` ack before offering anyway.
    var joinAckTimeout: TimeInterval = 5
    /// Poll interval for gathering/ack waits.
    var pollInterval: TimeInterval = 0.05
    /// Timeout handed to the microphone prompt.
    var permissionTimeout: TimeInterval = 10

    static let test = CallsEngineTimings(iceGatheringTimeout: 0.5, joinAckTimeout: 0.5,
                                         pollInterval: 0.01, permissionTimeout: 0.2)
}

/// A snapshot of what the engine knows — the value a diagnostics screen or the conformance probe
/// logs. Cheap to produce, safe to take from any context.
struct CallsEngineSnapshot: Equatable, Sendable {
    var state: CallsEngineState = .idle
    var microphonePermission: CallsMicrophonePermission = .undetermined
    var audioSession: String = ""
    var channelID: String = ""
    /// The session's own connection id (learned from the first answer — see `CallsSignallingPort`).
    var connID: String?
    var localSDP: String?
    var remoteSDP: String?
    var offersSent = 0
    /// How many SFU re-offers were answered (the post-connect renegotiation, T44b §5).
    var serverOffersAnswered = 0
    var candidatesSent = 0
    var candidatesReceived = 0
    var iceConnectionState: String = "new"
    var connectionState: String = "new"
    var remoteAudioTracks = 0
    /// The `call_state` the plugin published for this call.
    var call: CallsCall?
    var error: String?
    /// Peak RSS accounting is the probe's job, not the engine's; this is the libwebrtc-side truth.
    var mediaEngineCreated = false
}

/// The `getStats()` fields worth logging for an audio call — the same counters the browser harness
/// (`scripts/t44b_rtp_spike.js`) reported, read from libwebrtc's statistics report.
struct CallsRTPStats: Equatable, Sendable {
    var outboundPackets: Int64 = 0
    var outboundBytes: Int64 = 0
    var inboundPackets: Int64 = 0
    var inboundBytes: Int64 = 0
    var inboundSamples: Int64 = 0
    var inboundLost: Int64 = 0
    var inboundJitter: Double = 0
    var selectedPair: String?
    var localCandidateType: String?
    var remoteCandidateType: String?
}

// MARK: - Engine

actor CallsEngine {

    private let signalling: any CallsSignalling
    private let permissions: any CallsPermissionRequesting
    private let audioSession: any CallsAudioSessionControlling
    private let policy: CallsEnginePolicy
    private let timings: CallsEngineTimings

    private var snapshot = CallsEngineSnapshot()
    private var eventTask: Task<Void, Never>?
    /// Set once the `join` frame has been written. The offer waits for it: the plugin has no session
    /// to route an `sdp` to before the join lands, and the ack can arrive while `join` is still in
    /// flight (it is broadcast, not a reply).
    private var joinSent = false
    /// The one in-flight negotiation. Both the ack path and the post-join path await it, so `start()`
    /// never reports a state before the offer frame exists.
    private var offerTask: Task<Void, Never>?
    private var didSendOffer = false
    private var hasRemoteDescription = false
    private var pendingRemoteCandidates: [CallsIceCandidate] = []
    private var pendingLocalCandidates: [CallsIceCandidate] = []
    private var answeredJoinAck = false
    private var stopping = false

    // libwebrtc objects. The factory is created per call: it is the expensive object (§5 of the
    // spike: ~6 MB) and a call is the only thing that needs it.
    private var factory: RTCPeerConnectionFactory?
    private var peerConnection: RTCPeerConnection?
    private var audioTrack: RTCAudioTrack?
    private var delegate: CallsPeerConnectionDelegate?
    /// Where libwebrtc's blocking `close()` runs. Never the engine's executor (see
    /// `teardownMediaEngine()`); injectable only so a test can hold the close open.
    private let teardown: any CallsMediaTeardownScheduling

    init(signalling: any CallsSignalling,
         permissions: any CallsPermissionRequesting = SystemCallsPermissions(),
         audioSession: any CallsAudioSessionControlling = SystemCallsAudioSession(),
         policy: CallsEnginePolicy = .requireMicrophone,
         timings: CallsEngineTimings = CallsEngineTimings(),
         teardown: any CallsMediaTeardownScheduling = CallsMediaTeardownQueue.shared) {
        self.signalling = signalling
        self.permissions = permissions
        self.audioSession = audioSession
        self.policy = policy
        self.timings = timings
        self.teardown = teardown
    }

    // MARK: - Observation

    func currentSnapshot() -> CallsEngineSnapshot { snapshot }

    var state: CallsEngineState { snapshot.state }

    /// The snapshot after every event the engine folds — the seam a surface (and a test) awaits
    /// instead of polling `currentSnapshot()` on a clock (kanban t_00fb623c).
    ///
    /// The engine is an actor with no published state of its own: without this, "the `call_state`
    /// landed" can only be observed by reading the snapshot until it changes, and a host freeze
    /// between two reads reds the test even though the engine did nothing wrong. Called from inside
    /// the actor, so the value handed out is consistent with the fold that produced it.
    private var snapshotObserver: (@Sendable (CallsEngineSnapshot) -> Void)?

    /// Install the observer. Call before `start()`: an event that arrives with no observer installed
    /// is not replayed (the current snapshot is still readable through `currentSnapshot`).
    func observeSnapshots(_ observer: @escaping @Sendable (CallsEngineSnapshot) -> Void) {
        snapshotObserver = observer
    }

    private func publishSnapshot() {
        snapshotObserver?(snapshot)
    }

    // MARK: - Lifecycle

    /// Ask for the microphone, join the call, and offer. Returns the state it reached — a caller
    /// that needs the whole negotiation awaited gets `.connecting`/`.connected` from
    /// `waitForState(_:timeout:)`.
    @discardableResult
    func start(channelID: String) async -> CallsEngineState {
        guard snapshot.state == .idle || snapshot.state == .ended else { return snapshot.state }
        stopping = false
        snapshot = CallsEngineSnapshot()
        snapshot.channelID = channelID
        joinSent = false
        offerTask?.cancel()
        offerTask = nil
        didSendOffer = false
        answeredJoinAck = false
        hasRemoteDescription = false
        pendingRemoteCandidates.removeAll()
        pendingLocalCandidates.removeAll()

        // 1. Capture permission — BEFORE the engine starts. A denied grant is a state.
        snapshot.state = .requestingPermission
        let permission = await permissions.requestMicrophone(timeout: timings.permissionTimeout)
        snapshot.microphonePermission = permission
        if !permission.canCaptureAudio {
            MMLog.info("MMCalls", "microphone permission \(permission)")
            if policy == .requireMicrophone {
                snapshot.state = .permissionDenied
                snapshot.error = "microphone access was \(permission)"
                return snapshot.state
            }
            // Joining anyway: the app is audible but muted, which is what the web client does when
            // the user refuses the mic.
        }

        // 2. The engine.
        snapshot.state = .joining
        do {
            try audioSession.activateForCall()
        } catch {
            // Not fatal: some hosts (a Catalyst build in a test runner with no audio device) refuse
            // the session. The call can still be signalled and, on a device, will be silent.
            MMLog.error("MMCalls", "audio session activation failed: \(error)")
            snapshot.error = "audio session: \(error)"
        }
        snapshot.audioSession = audioSession.currentConfiguration()
        createMediaEngine()

        // 3. Socket side: join, then offer (the client offers — the SFU never does first).
        eventTask?.cancel()
        let events = signalling.events
        eventTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
        signalling.start()
        do {
            try await signalling.join(channelID: channelID)
        } catch {
            snapshot.state = .failed("join: \(error)")
            snapshot.error = "join: \(error)"
            return snapshot.state
        }
        joinSent = true
        // 4. Offer once the plugin has acked the join (or after the ack timeout — an ack can be lost
        //    to the per-user broadcast and the offer is still valid). An ack that arrived while the
        //    join was in flight also lands here: `answeredJoinAck` makes the wait return at once.
        await waitForJoinAckThenOffer()
        return snapshot.state
    }

    /// Tear the call down: leave on the socket, close the peer connection, release the audio session.
    func stop() async {
        stopping = true
        if !snapshot.channelID.isEmpty {
            try? await signalling.leave(channelID: snapshot.channelID)
        }
        eventTask?.cancel()
        eventTask = nil
        offerTask?.cancel()
        offerTask = nil
        // Stop the audio unit **before** releasing the peer connection/factory. The ADM belongs to the
        // factory; deactivating the session afterwards tears down an audio unit whose owner is already
        // gone, which is one half of the AudioToolbox deadlock measured in
        // `SystemCallsAudioSession.activateForCall`.
        audioTrack?.isEnabled = false
        audioSession.deactivate()
        teardownMediaEngine()
        if !snapshot.state.isTerminal { snapshot.state = .ended }
        signalling.stop()
    }

    /// Mute/unmute **this** session. The plugin's session state is what every other participant's UI
    /// renders, and a session joins muted, so a client that never sends `unmute` looks muted even
    /// while its RTP flows (docs/t44b-calls-media-path.md §6).
    func setMuted(_ muted: Bool) async {
        guard !snapshot.channelID.isEmpty else { return }
        if let track = audioTrack { track.isEnabled = !muted }
        do {
            try await signalling.setMuted(muted, channelID: snapshot.channelID)
        } catch {
            MMLog.error("MMCalls", "could not \(muted ? "mute" : "unmute"): \(error)")
        }
    }

    func setHandRaised(_ raised: Bool) async {
        guard !snapshot.channelID.isEmpty else { return }
        try? await signalling.setHandRaised(raised, channelID: snapshot.channelID)
    }

    /// `getStats()`, mapped to the counters an audio-call report needs.
    func statistics() async -> CallsRTPStats {
        guard let peerConnection else { return CallsRTPStats() }
        let report = await withCheckedContinuation { (continuation: CheckedContinuation<RTCStatisticsReport?, Never>) in
            peerConnection.statistics { continuation.resume(returning: $0) }
        }
        guard let report else { return CallsRTPStats() }
        return Self.read(report)
    }

    /// Block until the engine reaches one of `states`, or the timeout elapses. Returns the state it
    /// actually saw, so a caller never has to guess whether the wait or the call won.
    func waitForState(_ states: [CallsEngineState], timeout: TimeInterval) async -> CallsEngineState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if states.contains(snapshot.state) { return snapshot.state }
            if snapshot.state.isTerminal { return snapshot.state }
            try? await Task.sleep(nanoseconds: UInt64(max(0.001, timings.pollInterval) * 1_000_000_000))
        }
        return snapshot.state
    }

    // MARK: - Signalling events

    private func handle(_ event: CallsEvent) async {
        guard !stopping else { return }
        switch event {
        case .joinAck(let connID):
            MMLog.debug("MMCalls", "join ack (connID hint \(connID.prefix(6)))")
            answeredJoinAck = true
            await offerIfNeeded()

        case .callState(_, let call):
            snapshot.call = call
            answeredJoinAck = true
            await offerIfNeeded()

        case .signal(let signal):
            await handle(signal)

        case .callEnded:
            MMLog.info("MMCalls", "call ended by the server")
            snapshot.state = .ended

        case .error(let message):
            snapshot.error = message
            MMLog.error("MMCalls", "plugin error: \(message)")

        case .muteChanged, .voiceChanged, .handChanged, .screenShareChanged, .userJoined,
             .userLeft, .hostChanged, .callStarted, .unhandled:
            // Participation deltas are folded into the call this engine publishes, so
            // `snapshot.call` is genuinely authoritative (see `fold(_:)`).
            fold(event)
        }
        publishSnapshot()
    }

    /// Fold one participation delta into `snapshot.call`.
    ///
    /// T44c left these to the surface ("a surface card renders them"), and the live T44d run showed
    /// why that is wrong: the plugin sends the **delta** for a control, and not always a fresh
    /// `call_state` with it (measured 0.29.8 — `user_unmuted` arrived alone). The surface's own rule
    /// is "the snapshot wins", so a stale `snapshot.call` reverted a confirmed unmute within one poll
    /// interval — the mute control snapped back to `muted` 3 s after the server had broadcast
    /// `user_unmuted`. The same staleness would drop a second participant's tile whose `user_joined`
    /// the surface had folded. The engine owns the call state, so it folds the deltas.
    ///
    /// A delta for another channel is ignored: a client can be a member of two channels with a live
    /// call, and folding one call's participants into the other's tiles would be worse than stale.
    private func fold(_ event: CallsEvent) {
        guard var call = snapshot.call, !call.channelID.isEmpty else { return }
        switch event {
        case let .muteChanged(channelID, userID, sessionID, unmuted):
            guard channelID == call.channelID else { return }
            mutate(&call, sessionID: sessionID, userID: userID) { $0.unmuted = unmuted }

        case let .handChanged(channelID, userID, sessionID, raised):
            guard channelID == call.channelID else { return }
            // The event carries raise/unraise only; the ordering timestamp travels in `call_state`.
            // Stand in with this client's clock, which is what the surface does, so the participant
            // ordering stays total until the next `call_state` lands with the plugin's value.
            let stamp = raised ? Int64((Date().timeIntervalSince1970 * 1000).rounded()) : 0
            mutate(&call, sessionID: sessionID, userID: userID) { $0.raisedHandAt = stamp }

        case let .userJoined(channelID, userID, sessionID):
            guard channelID == call.channelID, !sessionID.isEmpty else { return }
            if !call.sessions.contains(where: { $0.sessionID == sessionID }) {
                call.sessions.append(CallsSession(sessionID: sessionID, userID: userID))
            }

        case let .userLeft(channelID, _, sessionID):
            guard channelID == call.channelID, !sessionID.isEmpty else { return }
            call.sessions.removeAll { $0.sessionID == sessionID }

        case let .hostChanged(channelID, hostID):
            guard channelID == call.channelID, !hostID.isEmpty else { return }
            call.hostID = hostID

        case let .screenShareChanged(channelID, _, sessionID, sharing):
            guard channelID == call.channelID else { return }
            if sharing {
                call.screenSharingSessionID = sessionID
            } else if call.screenSharingSessionID == sessionID {
                call.screenSharingSessionID = ""
            }

        case .voiceChanged, .callStarted, .unhandled:
            return

        default:
            return
        }
        snapshot.call = call
    }

    /// Apply a mutation to the session a delta names, matching on `session_id` first and falling back
    /// to the user (a client's own session is the one case where the id can lag the first event).
    private func mutate(_ call: inout CallsCall, sessionID: String, userID: String,
                        _ body: (inout CallsSession) -> Void) {
        if !sessionID.isEmpty,
           let index = call.sessions.firstIndex(where: { $0.sessionID == sessionID }) {
            body(&call.sessions[index])
            return
        }
        let mine = call.sessions.indices.filter { call.sessions[$0].userID == userID }
        guard mine.count == 1, let index = mine.first else { return }
        body(&call.sessions[index])
    }

    private func handle(_ signal: CallsSignal) async {
        guard let peerConnection else { return }
        switch signal.payload {
        case .description(let description):
            if description.kind == .answer {
                await applyAnswer(description, peerConnection: peerConnection)
            } else if description.kind == .offer {
                await answerServerOffer(description, peerConnection: peerConnection)
            }

        case .candidate(let candidate):
            snapshot.candidatesReceived += 1
            guard hasRemoteDescription else {
                // Measured ordering hazard: the SFU can trickle before its answer is applied. The
                // browser client queues these too (`rtc_peer.ts`), and dropping them costs a
                // connectivity check.
                pendingRemoteCandidates.append(candidate)
                return
            }
            await addRemoteCandidate(candidate, peerConnection: peerConnection)

        case .unknown(let type):
            MMLog.debug("MMCalls", "ignoring unmodelled signal type \(type)")
        }
    }

    private func applyAnswer(_ description: CallsSessionDescription,
                             peerConnection: RTCPeerConnection) async {
        do {
            try await peerConnection.setRemoteDescriptionAsync(.answer, sdp: description.sdp)
            hasRemoteDescription = true
            snapshot.remoteSDP = description.sdp
            if snapshot.state == .negotiating || snapshot.state == .offering {
                snapshot.state = .connecting
            }
            MMLog.info("MMCalls", "SFU answer applied (\(description.sdp.count) chars)")
            await flushPendingRemoteCandidates(peerConnection: peerConnection)
        } catch {
            snapshot.error = "answer: \(error)"
            snapshot.state = .failed("could not apply the SFU answer: \(error)")
            MMLog.error("MMCalls", snapshot.error ?? "")
        }
    }

    /// The post-connect renegotiation: the SFU offers, the client answers. Skipping this is the
    /// difference between zero inbound RTP and a working call (T44b §5).
    private func answerServerOffer(_ description: CallsSessionDescription,
                                   peerConnection: RTCPeerConnection) async {
        do {
            try await peerConnection.setRemoteDescriptionAsync(.offer, sdp: description.sdp)
            hasRemoteDescription = true
            let constraints = Self.offerAnswerConstraints()
            let answer = try await peerConnection.answerAsync(constraints)
            try await peerConnection.setLocalDescriptionAsync(answer)
            guard let local = peerConnection.localDescription else {
                throw CallsEngineError.noLocalDescription
            }
            snapshot.serverOffersAnswered += 1
            snapshot.localSDP = local.sdp
            try await signalling.send(description:
                CallsSessionDescription(kind: .answer, sdp: local.sdp))
            MMLog.info("MMCalls", "answered the SFU's re-offer (\(local.sdp.count) chars, "
                + "re-offers answered: \(snapshot.serverOffersAnswered))")
            await flushPendingRemoteCandidates(peerConnection: peerConnection)
        } catch {
            snapshot.error = "server offer: \(error)"
            MMLog.error("MMCalls", "could not answer the SFU's re-offer: \(error)")
        }
    }

    private func addRemoteCandidate(_ candidate: CallsIceCandidate,
                                    peerConnection: RTCPeerConnection) async {
        let ice = RTCIceCandidate(sdp: candidate.candidate,
                                  sdpMLineIndex: candidate.sdpMLineIndex ?? 0,
                                  sdpMid: candidate.sdpMid)
        do {
            try await peerConnection.addAsync(ice)
        } catch {
            // A candidate that cannot be added is usually a race with a description change; ICE
            // will pick another pair.
            MMLog.debug("MMCalls", "could not add remote candidate \(candidate.hostAndPort ?? "?"): \(error)")
        }
    }

    private func flushPendingRemoteCandidates(peerConnection: RTCPeerConnection) async {
        let queued = pendingRemoteCandidates
        pendingRemoteCandidates.removeAll()
        for candidate in queued {
            await addRemoteCandidate(candidate, peerConnection: peerConnection)
        }
    }

    // MARK: - Offer

    /// Offer at most once, and make every caller wait for the *same* negotiation.
    ///
    /// Both the ack path (`handle`) and the post-join path (`start`) reach this, and they interleave:
    /// the ack can land while `join` is still in flight. Whoever gets here first creates the task and
    /// everyone awaits it, so `start` returns only once the offer is really on the wire — the bug this
    /// replaced returned `.offering` with no frame sent, because the ack's handler was still awaiting
    /// libwebrtc when `start` returned.
    private func offerIfNeeded() async {
        if let inFlight = offerTask {
            await inFlight.value
            return
        }
        guard joinSent, peerConnection != nil else { return }
        let task = Task { [weak self] in
            await self?.performOffer()
            return ()
        }
        offerTask = task
        await task.value
    }

    private func waitForJoinAckThenOffer() async {
        let deadline = Date().addingTimeInterval(timings.joinAckTimeout)
        while Date() < deadline && !answeredJoinAck && offerTask == nil {
            try? await Task.sleep(nanoseconds: UInt64(max(0.001, timings.pollInterval) * 1_000_000_000))
        }
        if offerTask == nil {
            MMLog.info("MMCalls", "offering without a join ack (timed out after "
                + "\(timings.joinAckTimeout)s)")
        }
        await offerIfNeeded()
    }

    private func performOffer() async {
        guard let peerConnection else { return }
        snapshot.state = .offering
        do {
            let constraints = Self.offerAnswerConstraints()
            let offer = try await peerConnection.offerAsync(constraints)
            try await peerConnection.setLocalDescriptionAsync(offer)
            await waitForGatheringComplete(peerConnection)

            guard let local = peerConnection.localDescription else {
                throw CallsEngineError.noLocalDescription
            }
            snapshot.localSDP = local.sdp
            // From here on, gathered candidates may be trickled: the plugin only has a session to
            // route an `ice` message to once this frame has been accepted.
            didSendOffer = true
            try await signalling.send(description:
                CallsSessionDescription(kind: .offer, sdp: local.sdp))
            snapshot.offersSent += 1
            snapshot.state = .negotiating
            let candidateLines = local.sdp.components(separatedBy: "a=candidate:").count - 1
            MMLog.info("MMCalls", "offer sent (\(local.sdp.count) chars, \(candidateLines) "
                + "candidate line(s) inline), waiting for the SFU's answer")

            await flushPendingLocalCandidates()
        } catch {
            snapshot.error = "offer: \(error)"
            snapshot.state = .failed("could not offer: \(error)")
            MMLog.error("MMCalls", snapshot.error ?? "")
        }
    }

    /// Poll `iceGatheringState` up to the timeout. Waiting for `complete` (bounded) is what makes the
    /// offer carry usable candidates even when the socket cannot carry trickle; the plugin's SFU
    /// needs at least one candidate it can reach.
    private func waitForGatheringComplete(_ peerConnection: RTCPeerConnection) async {
        let deadline = Date().addingTimeInterval(timings.iceGatheringTimeout)
        while Date() < deadline {
            if peerConnection.iceGatheringState == .complete { return }
            try? await Task.sleep(nanoseconds: UInt64(max(0.001, timings.pollInterval) * 1_000_000_000))
        }
        MMLog.debug("MMCalls", "ICE gathering did not complete within \(timings.iceGatheringTimeout)s; "
            + "sending the offer with what gathered")
    }

    private func flushPendingLocalCandidates() async {
        let queued = pendingLocalCandidates
        pendingLocalCandidates.removeAll()
        for candidate in queued {
            do {
                try await signalling.send(candidate: candidate)
                snapshot.candidatesSent += 1
            } catch {
                MMLog.debug("MMCalls", "could not trickle \(candidate.hostAndPort ?? "?"): \(error)")
            }
        }
        if !queued.isEmpty {
            MMLog.info("MMCalls", "trickled \(queued.count) local candidate(s)")
        }
    }

    // MARK: - Media engine

    private func createMediaEngine() {
        let encoder = RTCDefaultVideoEncoderFactory()
        let decoder = RTCDefaultVideoDecoderFactory()
        let factory = RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: decoder)
        self.factory = factory

        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        // No STUN/TURN on purpose: Match the browser harness (T44b used `{iceServers: []}`) — host
        // candidates are the deployment default for a server that publishes its SFU port, and a TURN
        // server would have to come from the plugin's `/turn-credentials` route (a later card).
        configuration.iceServers = []

        let delegate = CallsPeerConnectionDelegate()
        delegate.onIceCandidate = { [weak self] candidate in
            Task { await self?.localCandidateGenerated(candidate) }
        }
        delegate.onIceConnectionState = { [weak self] state in
            Task { await self?.iceStateChanged(state) }
        }
        delegate.onConnectionState = { [weak self] state in
            Task { await self?.connectionStateChanged(state) }
        }
        delegate.onNegotiationNeeded = { [weak self] in
            Task { await self?.negotiationNeeded() }
        }
        delegate.onRemoteTrack = { [weak self] in
            Task { await self?.remoteAudioTrackAdded() }
        }
        self.delegate = delegate

        guard let peerConnection = factory.peerConnection(
                with: configuration, constraints: Self.offerAnswerConstraints(), delegate: delegate) else {
            snapshot.state = .failed("libwebrtc refused to create a peer connection")
            snapshot.error = snapshot.state.plainDescription
            return
        }
        self.peerConnection = peerConnection

        // The local audio track is what makes the offer carry an audio m-line, which is what makes the
        // SFU forward anything. It is added *before* the offer (the client is the offerer).
        let source = factory.audioSource(with: Self.offerAnswerConstraints())
        let track = factory.audioTrack(with: source, trackId: "audio0")
        audioTrack = track
        _ = peerConnection.add(track, streamIds: ["calls"])
        snapshot.mediaEngineCreated = true
        MMLog.info("MMCalls", "media engine created (factory + audio track + peer connection)")
    }

    /// Tear the media engine down **without** letting libwebrtc's teardown wedge the engine.
    ///
    /// `RTCPeerConnection.close()` blocks until libwebrtc's own threads have finished with the
    /// connection, and on a host where that never happens it blocks *forever*. Measured on this
    /// programme's CI runners (t_01f65f1d, runs 40899137785/40895827104): an XCTest spindump of the
    /// hung process samples `peerConnection.close()` 495/495 times inside `__psynch_cvwait`, with
    /// libwebrtc's `signaling_thread` and `worker_thread` idle — and because it was called here, on
    /// the engine's executor, the wedge was the whole engine: `stop()` never returned, the snapshot
    /// never became `.ended`, `signalling.stop()` never ran and the audio session was handed back
    /// only because it is deactivated before this call. A reader on such a host would sit in a call
    /// that is over, forever.
    ///
    /// So the blocking half runs on its own queue, is not awaited, and the engine is finished as
    /// soon as it has dropped its references. `audioTrack.isEnabled` stays on the actor: it is the
    /// ordering the caller depends on (stop the audio unit while its factory is alive) and the
    /// spindump shows it returning — the wedge is `close()` alone.
    private func teardownMediaEngine() {
        audioTrack?.isEnabled = false

        let connection = peerConnection
        let factory = factory
        peerConnection = nil
        audioTrack = nil
        delegate = nil
        self.factory = nil
        snapshot.mediaEngineCreated = false
        guard connection != nil || factory != nil else { return }

        teardown.schedule {
            connection?.close()
            // The factory owns the audio device module the connection just used; keeping it alive
            // until this block ends means a `close()` that never returns leaks one thread and one
            // factory rather than wedging every later call's teardown.
            withExtendedLifetime(factory) {}
        }
    }

    // MARK: - Delegate callbacks (already hopped onto the actor)

    private func localCandidateGenerated(_ candidate: CallsIceCandidate) {
        guard !stopping else { return }
        if didSendOffer {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.signalling.send(candidate: candidate)
                    await self.countSentCandidate()
                } catch {
                    await self.logTrickleFailure(candidate, error: error)
                }
            }
        } else {
            // Buffered until the offer is on the wire: the plugin has no RTC session to route an
            // `ice` message to before the sdp frame lands.
            pendingLocalCandidates.append(candidate)
        }
    }

    private func countSentCandidate() {
        snapshot.candidatesSent += 1
    }

    private func logTrickleFailure(_ candidate: CallsIceCandidate, error: Error) {
        MMLog.debug("MMCalls", "could not trickle \(candidate.hostAndPort ?? "?"): \(error)")
    }

    private func iceStateChanged(_ state: RTCIceConnectionState) {
        snapshot.iceConnectionState = Self.describe(state)
        switch state {
        case .connected, .completed:
            if snapshot.state != .ended { snapshot.state = .connected }
        case .failed:
            snapshot.state = .failed("ICE failed")
            snapshot.error = "ICE connection failed"
        default:
            break
        }
        MMLog.info("MMCalls", "ICE state: \(snapshot.iceConnectionState)")
    }

    private func connectionStateChanged(_ state: RTCPeerConnectionState) {
        snapshot.connectionState = Self.describe(state)
        if state == .connected && snapshot.state != .ended {
            snapshot.state = .connected
        }
    }

    private func negotiationNeeded() {
        // `onNegotiationNeeded` fires when the track is added; the offer is driven explicitly from
        // `performOffer()` instead, because the join must land before the `sdp` frame. A second
        // negotiation from our side is not needed for audio-only Calls.
        MMLog.debug("MMCalls", "negotiation needed (offer is driven explicitly)")
    }

    private func remoteAudioTrackAdded() {
        snapshot.remoteAudioTracks += 1
        MMLog.info("MMCalls", "remote audio track \(snapshot.remoteAudioTracks) added")
    }

    // MARK: - Constants / mapping

    /// The offer/answer constraints the browser client uses (`rtc_peer.ts`):
    /// `{OfferToReceiveAudio: true, OfferToReceiveVideo: false}`.
    static func offerAnswerConstraints() -> RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: [
            "OfferToReceiveAudio": "true",
            "OfferToReceiveVideo": "false",
        ], optionalConstraints: nil)
    }

    static func describe(_ state: RTCIceConnectionState) -> String {
        switch state {
        case .new: return "new"
        case .checking: return "checking"
        case .connected: return "connected"
        case .completed: return "completed"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        case .count: return "count"
        @unknown default: return "unknown"
        }
    }

    static func describe(_ state: RTCPeerConnectionState) -> String {
        switch state {
        case .new: return "new"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .failed: return "failed"
        case .closed: return "closed"
        @unknown default: return "unknown"
        }
    }

    /// Map a libwebrtc statistics report onto the audio counters the T44b harness reported. Only the
    /// audio `outbound-rtp` / `inbound-rtp` rows and the nominated candidate pair are read.
    static func read(_ report: RTCStatisticsReport) -> CallsRTPStats {
        var stats = CallsRTPStats()
        var candidates: [String: (type: String, candidateType: String)] = [:]
        var selectedPairID: String?

        for (id, entry) in report.statistics {
            switch entry.type {
            case "outbound-rtp":
                guard (entry.values["kind"] as? String) == "audio"
                        || (entry.values["mediaType"] as? String) == "audio" else { continue }
                stats.outboundPackets += int64(entry.values["packetsSent"])
                stats.outboundBytes += int64(entry.values["bytesSent"])
            case "inbound-rtp":
                guard (entry.values["kind"] as? String) == "audio"
                        || (entry.values["mediaType"] as? String) == "audio" else { continue }
                stats.inboundPackets += int64(entry.values["packetsReceived"])
                stats.inboundBytes += int64(entry.values["bytesReceived"])
                stats.inboundSamples += int64(entry.values["totalSamplesReceived"])
                stats.inboundLost += int64(entry.values["packetsLost"])
                if let jitter = entry.values["jitter"] as? NSNumber {
                    stats.inboundJitter = max(stats.inboundJitter, jitter.doubleValue)
                }
            case "local-candidate", "remote-candidate":
                candidates[id] = (entry.type,
                                  entry.values["candidateType"] as? String ?? "")
            case "candidate-pair":
                let state = entry.values["state"] as? String ?? ""
                let nominated = (entry.values["nominated"] as? NSNumber)?.boolValue ?? false
                if nominated || state == "succeeded" {
                    selectedPairID = id
                    if let local = entry.values["localCandidateId"] as? String,
                       let remote = entry.values["remoteCandidateId"] as? String {
                        stats.localCandidateType = candidates[local]?.candidateType
                        stats.remoteCandidateType = candidates[remote]?.candidateType
                        stats.selectedPair = "\(local)→\(remote) (\(state))"
                    }
                }
            default:
                break
            }
        }
        if stats.selectedPair == nil, let id = selectedPairID {
            stats.selectedPair = id
        }
        return stats
    }

    private static func int64(_ value: NSObject?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) ?? 0 }
        return 0
    }
}

// MARK: - Small helpers

extension CallsEngine {
    /// Whether this build can put a camera into a call: **it cannot**.
    ///
    /// T44c modelled `video_on`/`video_off` in `CallsProtocol.Action` and version-gates them
    /// (`CallsPluginVersion.supportsVideo`), but never sends them and never creates a video track or
    /// an `RTCCameraVideoCapturer` — its own hand-off records "camera stays webview-only". The
    /// plugin this programme tests against (0.29.8) has no video actions at all.
    ///
    /// This constant is the one place the surface reads that fact (`CallsVideoCapability
    /// .forBuild(plugin:engineCapturesVideo:)`), so the camera control is **absent** rather than
    /// present-and-inert, and flips on by itself the day an engine that captures video lands.
    static let capturesVideo = false
}

// MARK: - Media-engine teardown

/// Where the engine runs libwebrtc's **blocking** teardown.
///
/// It exists as a seam for one measured reason: `RTCPeerConnection.close()` can block forever
/// (t_01f65f1d — spindump of the hung CI process, 495/495 samples in `__psynch_cvwait`), so a test
/// has to be able to hold that close open and prove the engine still finishes `stop()`. Production
/// uses `CallsMediaTeardownQueue`.
protocol CallsMediaTeardownScheduling: Sendable {
    /// Run `work` somewhere that is neither the engine's executor nor the caller's thread, and do
    /// **not** wait for it.
    func schedule(_ work: @escaping @Sendable () -> Void)
}

/// The production teardown queue: concurrent, so one `close()` that never returns cannot queue every
/// later call's teardown behind it, and a wedge is *reported* after `warnAfter` instead of being silent.
///
/// libwebrtc offers no cancellation for a blocking `close()` (and cancelling its threads is not
/// something to do), so the only honest options are "don't await it" and "say so".
final class CallsMediaTeardownQueue: CallsMediaTeardownScheduling, @unchecked Sendable {

    static let shared = CallsMediaTeardownQueue()

    /// How long a close may run before it is reported. 10 s is ~30× the measured close on a healthy
    /// host (3–14 ms after the last "trickled" line) and far below the 300 s test allowance.
    static let defaultWarnAfter: TimeInterval = 10

    /// The deadline this queue reports at — `defaultWarnAfter` in production. Injectable only so a
    /// test can observe the report without spending 10 s on it (kanban t_16e785f5); every production
    /// instance is `shared`.
    let warnAfter: TimeInterval

    init(warnAfter: TimeInterval = CallsMediaTeardownQueue.defaultWarnAfter) {
        self.warnAfter = warnAfter
    }

    private static let queue = DispatchQueue(label: "org.mattermost.calls.media-teardown",
                                             qos: .userInitiated,
                                             attributes: .concurrent)

    /// `schedule` runs on the caller's thread, so the flag needs a lock rather than isolation.
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        func finish() { lock.lock(); finished = true; lock.unlock() }
        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    }

    func schedule(_ work: @escaping @Sendable () -> Void) {
        let started = Date()
        let completion = Completion()
        let warnAfter = self.warnAfter
        Self.queue.async {
            work()
            completion.finish()
            let waited = Date().timeIntervalSince(started)
            if waited > warnAfter {
                MMLog.error("MMCalls", String(format: "libwebrtc close took %.1fs (off the engine; the call already ended)", waited))
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + warnAfter) {
            guard !completion.isFinished else { return }
            MMLog.error("MMCalls", "libwebrtc close() has not returned after \(Int(warnAfter))s; the engine is not blocked by it (t_01f65f1d)")
        }
    }
}

enum CallsEngineError: Error, Equatable, CustomStringConvertible {
    case noLocalDescription
    case peerConnectionUnavailable
    case timedOut(String)

    var description: String {
        switch self {
        case .noLocalDescription: return "the engine has no local description"
        case .peerConnectionUnavailable: return "no peer connection"
        case .timedOut(let what): return "timed out waiting for \(what)"
        }
    }
}

private extension CallsEngineState {
    var plainDescription: String {
        if case .failed(let why) = self { return why }
        return "\(self)"
    }
}

// MARK: - libwebrtc delegate bridge

/// `RTCPeerConnectionDelegate` in ObjC, hopped onto the actor by its owner.
///
/// Lives outside the actor on purpose: libwebrtc invokes it on its own signalling thread, so the
/// callbacks must not be actor-isolated. They extract value types (`CallsIceCandidate`, enums) and
/// hand them over in a `Task`; no libwebrtc object crosses an isolation boundary.
final class CallsPeerConnectionDelegate: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {

    var onIceCandidate: ((CallsIceCandidate) -> Void)?
    var onIceConnectionState: ((RTCIceConnectionState) -> Void)?
    var onConnectionState: ((RTCPeerConnectionState) -> Void)?
    var onNegotiationNeeded: (() -> Void)?
    var onRemoteTrack: (() -> Void)?

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didGenerate candidate: RTCIceCandidate) {
        let value = CallsIceCandidate(candidate: candidate.sdp,
                                      sdpMid: candidate.sdpMid,
                                      sdpMLineIndex: Int32(candidate.sdpMLineIndex))
        onIceCandidate?(value)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange stateChanged: RTCIceConnectionState) {
        onIceConnectionState?(stateChanged)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange newState: RTCPeerConnectionState) {
        onConnectionState?(newState)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                       didAdd receiver: RTCRtpReceiver,
                        streams: [RTCMediaStream]) {
        if receiver.track?.kind == "audio" { onRemoteTrack?() }
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        onNegotiationNeeded?()
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didOpen dataChannel: RTCDataChannel) {}
}

// MARK: - Async wrappers over the completion-handler API

extension RTCPeerConnection {

    func offerAsync(_ constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            offer(for: constraints) { description, error in
                if let description { continuation.resume(returning: description) }
                else { continuation.resume(throwing: error ?? CallsEngineError.noLocalDescription) }
            }
        }
    }

    func answerAsync(_ constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            answer(for: constraints) { description, error in
                if let description { continuation.resume(returning: description) }
                else { continuation.resume(throwing: error ?? CallsEngineError.noLocalDescription) }
            }
        }
    }

    func setLocalDescriptionAsync(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setLocalDescription(description) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func setRemoteDescriptionAsync(_ type: RTCSdpType, sdp: String) async throws {
        let description = RTCSessionDescription(type: type, sdp: sdp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setRemoteDescription(description) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func addAsync(_ candidate: RTCIceCandidate) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            add(candidate) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
