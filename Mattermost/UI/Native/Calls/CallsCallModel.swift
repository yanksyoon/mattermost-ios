// T44d — one live call, as a value the call screen observes.
//
// The engine (T44c) is an actor that publishes a **snapshot**; the plugin's participant deltas
// (`user_muted`, `user_raise_hand`, `user_voice_on`, `user_joined`, `call_state`) arrive on the
// server's socket. This model is where those two inputs become screen state, and it is deliberately
// the only place in the surface that talks to either: the views read `@Published` values and call
// `toggleMute()`/`leave()`, and nothing else.
//
// Why the deltas are handled here rather than in the engine: `CallsEngine.handle` explicitly
// ignores them ("call-state deltas: a surface card renders them; the engine only needs the fact
// that they are flowing"). Without this model a colleague's mute would only appear on the next full
// `call_state`, which the plugin does not publish on a mute.

import Foundation

/// The engine, as the model needs it. A protocol so the unit suite drives the coordinator with a
/// scripted engine: no WebRTC, no microphone, no TCC prompt.
///
/// `CallsEngine` conforms in one line (an actor's isolated methods satisfy the `async` requirements).
protocol CallsEngineDriving: Sendable {
    func start(channelID: String) async -> CallsEngineState
    func stop() async
    func setMuted(_ muted: Bool) async
    func setHandRaised(_ raised: Bool) async
    func currentSnapshot() async -> CallsEngineSnapshot
}

extension CallsEngine: CallsEngineDriving {}

/// One call, from the reader's point of view.
@MainActor
final class CallsCallModel: ObservableObject, Identifiable {

    /// Stable identity for `.fullScreenCover(item:)`.
    let id = UUID()
    let server: ServerConfig
    let channelID: String
    let channelName: String?
    /// The reader's own user id — which tile is "(you)" and whose session the controls act on.
    let myUserID: String
    /// Whether this build can carry video (see `CallsVideoCapability`; false today, which is why no
    /// camera control renders).
    let video: CallsVideoCapability

    @Published private(set) var phase: CallsSurfacePhase = .idle
    @Published private(set) var participants: [CallsParticipant] = []
    @Published private(set) var microphone: CallsMicrophonePermission = .undetermined
    /// The reader's own session state, which the mute/hand controls write and the tiles render.
    @Published private(set) var isMuted = true
    @Published private(set) var hasRaisedHand = false
    @Published private(set) var durationLabel = "00:00"
    /// Anything the engine or the plugin reported (`error` frames, a failed negotiation).
    @Published private(set) var error: String?

    private let engine: any CallsEngineDriving
    private let service: CallsSurfaceServing
    private let clock: () -> Date
    /// How often the engine snapshot is read. The snapshot is a polled value, not a stream: cheap
    /// (a struct copy), and 0.4 s is below the threshold where "Connecting…" feels stuck.
    private let snapshotInterval: TimeInterval

    private var call: CallsCall?
    private var profiles: [String: MMUser] = [:]
    private var speaking: Set<String> = []
    private var pendingProfiles: Set<String> = []
    private var wasConnected = false

    private var eventPump: Task<Void, Never>?
    private var enginePump: Task<Void, Never>?
    private var durationPump: Task<Void, Never>?

    /// Called once when the call reaches a terminal state (the coordinator drops its reference).
    var onEnded: (() -> Void)?

    init(server: ServerConfig,
         channelID: String,
         channelName: String?,
         myUserID: String,
         engine: any CallsEngineDriving,
         service: CallsSurfaceServing,
         events: AsyncStream<CallsEvent>,
         video: CallsVideoCapability = .unsupported(reason: "no camera path"),
         snapshotInterval: TimeInterval = 0.4,
         clock: @escaping () -> Date = Date.init) {
        self.server = server
        self.channelID = channelID
        self.channelName = channelName
        self.myUserID = myUserID
        self.engine = engine
        self.service = service
        self.video = video
        self.snapshotInterval = snapshotInterval
        self.clock = clock
        self.events = events
    }

    private let events: AsyncStream<CallsEvent>

    static func == (lhs: CallsCallModel, rhs: CallsCallModel) -> Bool { lhs.id == rhs.id }

    // MARK: - Derived

    /// What the control bar offers right now.
    var controls: CallsControlSet {
        CallsControlSet.derive(phase: phase, microphone: microphone, isMuted: isMuted,
                               hasRaisedHand: hasRaisedHand, video: video)
    }

    /// The banner a refused or unanswered microphone grant shows. `nil` when the mic is granted.
    var microphoneMessage: String? { microphone.noMicrophoneMessage }

    /// The header's one-line state ("Connecting…", "In call", "Reconnecting…", "Call ended").
    var statusText: String { phase.statusText }

    // MARK: - Lifecycle

    /// Join and start rendering. Idempotent: a second call while the first is live is a no-op.
    func start() async {
        guard phase == .idle else { return }
        phase = .joining
        startEventPump()
        startDurationPump()
        _ = await engine.start(channelID: channelID)
        startEnginePump()
    }

    /// Leave and tear down. Safe to call twice (the view's dismissal also calls it).
    func leave() async {
        guard !phase.isTerminal else { return }
        await engine.stop()
        phase = .ended
        stopPumps()
        onEnded?()
    }

    // MARK: - Controls

    /// Mute/unmute **this** session through the engine, optimistically in the UI.
    ///
    /// The optimistic write matters: the plugin confirms with `user_muted`/`user_unmuted`, which is
    /// a round trip, and a button that does nothing for 200 ms reads as broken. The server's event
    /// (handled below) is what settles the state.
    func toggleMute() async {
        guard controls.canToggleMute else { return }
        let next = !isMuted
        isMuted = next
        applyOwnSession { $0.unmuted = !next }
        await engine.setMuted(next)
    }

    /// Raise/lower the hand, with the same optimistic write.
    func toggleHand() async {
        guard controls.canToggleHand else { return }
        let raised = !hasRaisedHand
        hasRaisedHand = raised
        applyOwnSession { $0.raisedHandAt = raised ? Self.nowMillis(clock()) : 0 }
        await engine.setHandRaised(raised)
    }

    private func applyOwnSession(_ mutate: (inout CallsSession) -> Void) {
        guard var current = call else { return }
        guard let index = current.sessions.firstIndex(where: { $0.userID == myUserID }) else { return }
        mutate(&current.sessions[index])
        call = current
        rebuildParticipants()
    }

    // MARK: - Pumps

    private func startEventPump() {
        eventPump?.cancel()
        eventPump = Task { [weak self] in
            guard let self else { return }
            for await event in self.events {
                if Task.isCancelled { return }
                await self.handle(event)
            }
        }
    }

    private func startEnginePump() {
        enginePump?.cancel()
        enginePump = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.applySnapshot()
                try? await Task.sleep(nanoseconds: UInt64(max(0.05, self.snapshotInterval) * 1_000_000_000))
            }
        }
    }

    private func startDurationPump() {
        durationPump?.cancel()
        durationPump = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshDuration()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopPumps() {
        eventPump?.cancel(); eventPump = nil
        enginePump?.cancel(); enginePump = nil
        durationPump?.cancel(); durationPump = nil
    }

    private func refreshDuration() {
        guard let start = call?.startAt, start > 0 else {
            durationLabel = "00:00"
            return
        }
        durationLabel = CallsDuration.format(startAtMilliseconds: start, now: clock())
    }

    /// Read the engine's snapshot once and fold it into the screen state.
    ///
    /// Not `private`, like `handle`: this is the model's other input, and the test target drives it
    /// directly to pin what a snapshot may and may not do (see `CallsSurfacePhase.fold`).
    func applySnapshot() async {
        let snapshot = await engine.currentSnapshot()
        microphone = snapshot.microphonePermission
        if let reported = snapshot.call, reported != call {
            call = reported
            rebuildParticipants()
            await resolveProfilesIfNeeded()
        }
        // The snapshot is the authority for the reader's own session, whatever the optimistics say.
        if let mine = call?.session(forUser: myUserID) {
            isMuted = !mine.unmuted
            hasRaisedHand = mine.raisedHand
        }
        if !snapshot.error.isNilOrEmpty, snapshot.error != error {
            error = snapshot.error
        }
        foldPhase(CallsSurfacePhase.derive(engine: snapshot.state,
                                           connectionState: snapshot.connectionState,
                                           wasConnected: wasConnected))
    }

    private func foldPhase(_ next: CallsSurfacePhase) {
        if next == .connected { wasConnected = true }
        let folded = CallsSurfacePhase.fold(phase, next)
        guard folded != phase else { return }
        phase = folded
        if folded.isTerminal {
            stopPumps()
            onEnded?()
        }
    }

    // MARK: - Socket deltas

    /// Fold one frame the socket delivered.
    ///
    /// `startEventPump` is the only caller in the app; the method is deliberately not `private`,
    /// because it *is* the surface's frame rules and the test target drives it directly (the same
    /// shape `GlobalThreadsViewModel.handle` has). That lets a rule be pinned with no task, no
    /// stream and no wall-clock budget between the call and the assertions.
    func handle(_ event: CallsEvent) async {
        switch event {
        case .callState(let channelID, let reported):
            guard channelID.isEmpty || channelID == self.channelID else { return }
            call = reported
            rebuildParticipants()
            await resolveProfilesIfNeeded()

        case .callEnded(let channelID):
            guard channelID.isEmpty || channelID == self.channelID else { return }
            foldPhase(.ended)

        case .muteChanged(let channelID, let userID, let sessionID, let unmuted):
            guard appliesToThisCall(channelID) else { return }
            mutateSession(sessionID: sessionID, userID: userID) { $0.unmuted = unmuted }
            if userID == myUserID { isMuted = !unmuted }

        case .handChanged(let channelID, let userID, let sessionID, let raised):
            guard appliesToThisCall(channelID) else { return }
            // The event is raise/unraise (measured: `user_raise_hand` / `user_unraise_hand`); the
            // ordering timestamp travels only in `call_state`. A locally received raise is stamped
            // with this client's clock and settles on the next `call_state` refresh, which carries
            // the plugin's own `raised_hand` value.
            let raisedHandAt = raised
                ? Int64((clock().timeIntervalSince1970 * 1000).rounded())
                : 0
            mutateSession(sessionID: sessionID, userID: userID) { $0.raisedHandAt = raisedHandAt }
            if userID == myUserID { hasRaisedHand = raised }

        case .voiceChanged(let channelID, let userID, let sessionID, let isSpeaking):
            guard appliesToThisCall(channelID) else { return }
            _ = userID
            if isSpeaking { speaking.insert(sessionID) } else { speaking.remove(sessionID) }
            rebuildParticipants()

        case .userJoined(let channelID, let userID, let sessionID):
            guard appliesToThisCall(channelID) else { return }
            upsert(userID: userID, sessionID: sessionID)
            await resolveProfilesIfNeeded()

        case .userLeft(let channelID, let userID, let sessionID):
            guard appliesToThisCall(channelID) else { return }
            removeSession(sessionID: sessionID, userID: userID)

        case .hostChanged(let channelID, let hostID):
            guard appliesToThisCall(channelID) else { return }
            call?.hostID = hostID
            rebuildParticipants()

        case .screenShareChanged(let channelID, let userID, let sessionID, let sharing):
            _ = userID
            guard appliesToThisCall(channelID) else { return }
            if sharing {
                call?.screenSharingSessionID = sessionID
            } else if call?.screenSharingSessionID == sessionID {
                call?.screenSharingSessionID = ""
            }
            rebuildParticipants()

        case .error(let message):
            error = message

        case .callStarted, .signal, .joinAck, .unhandled:
            break
        }
    }

    /// Whether a participation delta belongs to the call this model is drawing.
    ///
    /// The measured payload names its channel (`channelID`); a member of several channels with live
    /// calls would otherwise fold another call's participants (and mute state) into these tiles.
    /// A frame that names no channel is applied — dropping a real delta is the worse failure.
    private func appliesToThisCall(_ channelID: String) -> Bool {
        channelID.isEmpty || channelID == self.channelID
    }

    private func mutateSession(sessionID: String, userID: String,
                               _ mutate: (inout CallsSession) -> Void) {
        guard var current = call,
              let index = current.sessions.firstIndex(where: {
                  sessionID.isEmpty ? $0.userID == userID : $0.sessionID == sessionID
              }) else { return }
        mutate(&current.sessions[index])
        call = current
        rebuildParticipants()
    }

    private func upsert(userID: String, sessionID: String) {
        guard var current = call else { return }
        if current.sessions.contains(where: { $0.sessionID == sessionID }) { return }
        current.sessions.append(CallsSession(sessionID: sessionID, userID: userID))
        call = current
        rebuildParticipants()
    }

    private func removeSession(sessionID: String, userID: String) {
        guard var current = call else { return }
        current.sessions.removeAll {
            sessionID.isEmpty ? $0.userID == userID : $0.sessionID == sessionID
        }
        speaking.remove(sessionID)
        call = current
        rebuildParticipants()
    }

    // MARK: - Participants

    private func rebuildParticipants() {
        participants = CallsParticipantDirectory.participants(call: call,
                                                              profiles: profiles,
                                                              myUserID: myUserID,
                                                              speaking: speaking)
        refreshDuration()
    }

    /// Fetch the participants' profiles once each, batched (one `POST /users/ids` per arrival wave).
    /// A failed lookup is not fatal: the tile falls back to the user id.
    private func resolveProfilesIfNeeded() async {
        guard let call else { return }
        let missing = Set(call.sessions.map(\.userID)).subtracting(profiles.keys).subtracting(pendingProfiles)
        guard !missing.isEmpty else { return }
        pendingProfiles.formUnion(missing)
        defer { pendingProfiles.subtract(missing) }
        do {
            let users = try await service.users(ids: Array(missing))
            for user in users { profiles[user.id] = user }
            rebuildParticipants()
        } catch {
            MMLog.debug("MMCalls", "participant profiles unavailable: \(error)")
        }
    }

    static func nowMillis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
