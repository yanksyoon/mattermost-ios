// T44d — the calls surface's rules, driven through the real model and the real coordinator with
// fakes at the two seams (`CallsSurfaceServing`, `CallsEngineDriving`) and a fake socket.
//
// What is *not* faked away: the coordinator's gate (the only thing that decides whether a join button
// exists), the model's event folding, and the socket→`CallsEvent` bridge. So these tests cover the
// whole path from "a frame arrives on the server's one socket" to "the tile says muted", with no
// server, no plugin, no WebRTC and no microphone.
//
// **No test in this class waits on wall clock.** Each rule is driven through the model's own two
// inputs — `handle(_:)` (the event pump's per-frame entry point) and `applySnapshot()` (the engine
// pump's per-tick entry point) — and every assertion after that drive is synchronous. The two
// end-to-end tests that keep the whole wire (fake socket → `CallsEventBridge` → pump → model) wait
// on the model's own `@Published`/`onEnded` signals, whose 30 s is a hang detector, not a budget.
//
// Why this shape: t_21828c93 measured that a 3 s `waitUntil` poll in this class went red whenever the
// test host was not scheduled for 3 s (two suite runs on one simulator, or 4.5 s of `SIGSTOP`), i.e.
// the budget measured the machine, not the code. `scripts/qa-freeze-host.sh` is that check: with the
// host stopped for 4.5 s this class must stay green.

import Combine
import Foundation
import XCTest
@testable import Mattermost

// MARK: - Fakes

@MainActor
final class FakeCallsService: CallsSurfaceServing {
    var active: Result<Bool, Error> = .success(false)
    var version: Result<CallsPluginVersion, Error> = .success(.v0_29_8)
    var usersByID: [String: MMUser] = [:]

    var versionRequests = 0
    var activeRequests = 0
    var activeChannelIDs: [String] = []
    var requestedUserIDBatches: [[String]] = []

    func pluginVersion() async throws -> CallsPluginVersion {
        versionRequests += 1
        return try version.get()
    }

    func isCallActive(channelID: String) async throws -> Bool {
        activeRequests += 1
        activeChannelIDs.append(channelID)
        return try active.get()
    }

    func users(ids: [String]) async throws -> [MMUser] {
        requestedUserIDBatches.append(ids)
        return ids.compactMap { usersByID[$0] }
    }
}

/// Call counters a test can read **synchronously** (the engine itself is an actor, so an assertion on
/// its state would have to be `await`ed inside an autoclosure, which XCTest does not allow).
final class EngineCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var _started: [String] = []
    private var _mute: [Bool] = []
    private var _hand: [Bool] = []
    private var _stop = 0

    var startedChannels: [String] { lock.lock(); defer { lock.unlock() }; return _started }
    var muteCalls: [Bool] { lock.lock(); defer { lock.unlock() }; return _mute }
    var handCalls: [Bool] { lock.lock(); defer { lock.unlock() }; return _hand }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return _stop }

    func recordStart(_ channelID: String) { lock.lock(); _started.append(channelID); lock.unlock() }
    func recordMute(_ muted: Bool) { lock.lock(); _mute.append(muted); lock.unlock() }
    func recordHand(_ raised: Bool) { lock.lock(); _hand.append(raised); lock.unlock() }
    func recordStop() { lock.lock(); _stop += 1; lock.unlock() }
}

/// A scripted engine. `connect`/`setState` let a test make the model see "connected", a drop or
/// an end without a peer connection.
actor FakeCallsEngine: CallsEngineDriving {
    let calls = EngineCalls()
    private var state: CallsEngineState
    private var extra = CallsEngineSnapshot()

    init(state: CallsEngineState = .joining) {
        self.state = state
    }

    func setState(_ state: CallsEngineState) { self.state = state }

    /// Make the call "connected", with a microphone answer, in **one** actor hop.
    ///
    /// `setState` and `setSnapshot` are two `await`s, so the model's engine pump (0.4 s) can tick
    /// between them and read a connected state with the *previous* microphone answer — a state the
    /// real engine never reports, because it asks for the microphone before it connects. Scripting
    /// both at once keeps the fake honest and takes the ordering out of the test's hands.
    func connect(microphone: CallsMicrophonePermission = .granted) {
        state = .connected
        extra.connectionState = "connected"
        extra.microphonePermission = microphone
    }

    func start(channelID: String) async -> CallsEngineState {
        calls.recordStart(channelID)
        return state
    }

    func stop() async {
        calls.recordStop()
        state = .ended
    }

    func setMuted(_ muted: Bool) async { calls.recordMute(muted) }

    func setHandRaised(_ raised: Bool) async { calls.recordHand(raised) }

    func currentSnapshot() async -> CallsEngineSnapshot {
        var snapshot = extra
        snapshot.state = state
        return snapshot
    }
}

/// One socket, as the Calls surface uses it: a subscriber stream plus the two send paths the engine
/// needs. Frames are injected with `pushCalls`.
final class FakeCallsTransport: CallsSocketTransport, @unchecked Sendable {
    private let stream: AsyncStream<SocketEvent>
    private let continuation: AsyncStream<SocketEvent>.Continuation
    private let lock = NSLock()
    private var _textFrames: [String] = []

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: SocketEvent.self,
                                                       bufferingPolicy: .bufferingNewest(256))
    }

    var textFrames: [String] {
        lock.lock(); defer { lock.unlock() }
        return _textFrames
    }

    func pushCalls(_ name: String, _ json: String) {
        continuation.yield(.plugin(name: name, data: callsRaw(json)))
    }

    func subscribe() async -> AsyncStream<SocketEvent> { stream }

    func sendTextFrame(_ text: String) async throws {
        lock.lock(); _textFrames.append(text); lock.unlock()
    }

    func sendBinaryFrame(_ frame: Data) async throws {}
}

// MARK: - Tests

@MainActor
final class T44DCallsCoordinatorTests: XCTestCase {

    private var server: ServerConfig!
    private var service: FakeCallsService!
    private var transport: FakeCallsTransport!
    private var engine: FakeCallsEngine!
    private var coordinator: CallsCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        server = ServerConfig(name: "Fixture", url: URL(string: "https://mm.example.com")!,
                              hasSession: true)
        service = FakeCallsService()
        transport = FakeCallsTransport()
        engine = FakeCallsEngine()
        coordinator = CallsCoordinator()
        coordinator.userIDProvider = { _ in "me" }
        coordinator.serviceFactory = { [weak self] _ in self!.service }
        coordinator.transportProvider = { [weak self] _ in self?.transport }
        coordinator.engineFactory = { [weak self] _, _ in self!.engine }
    }

    override func tearDown() async throws {
        coordinator = nil
        engine = nil
        transport = nil
        service = nil
        server = nil
        try await super.tearDown()
    }

    /// Wait for a `@Published` value the model itself publishes, without polling.
    ///
    /// This is the model's **signal**, not a budget: `@Published` sends synchronously when the model
    /// folds an input, so the expectation is fulfilled by the state change itself and a slow host
    /// cannot make it miss (a `@Published` publisher also replays the current value on subscribe, so
    /// a change that lands between the `push` and this call is still observed).
    ///
    /// The timeout is a hang detector, not a latency budget: 30 s is ~3000× the measured latency of
    /// these folds (~10 ms). A pipeline that is broken reds here; a merely late one does not.
    private func awaitSignal<P: Publisher>(_ description: String,
                                           timeout: TimeInterval = 30,
                                           _ publisher: P,
                                           file: StaticString = #filePath, line: UInt = #line,
                                           _ predicate: @escaping (P.Output) -> Bool) async {
        let hit = XCTestExpectation(description: description)
        hit.assertForOverFulfill = false
        let token = publisher.sink(receiveCompletion: { _ in },
                                   receiveValue: { if predicate($0) { hit.fulfill() } })
        defer { token.cancel() }
        await fulfillment(of: [hit], timeout: timeout)
    }

    /// Decode one plugin frame exactly as `CallsEventBridge` does, so a test can hand the model the
    /// same typed event its pump folds — with no socket hop, no task and no clock in between.
    ///
    /// The decode is not bypassed: `CallsEvent(name:data:)` is what the bridge calls on every frame,
    /// so a fixture the plugin could not produce still fails here.
    private func callsEvent(_ name: String, _ json: String,
                            file: StaticString = #filePath, line: UInt = #line) throws -> CallsEvent {
        try XCTUnwrap(CallsEvent(name: name, data: callsRaw(json)), file: file, line: line)
    }

    private func startCall(_ channelID: String = "chan1",
                           name: String? = "Town Square") async -> CallsCallModel? {
        await coordinator.startCall(server: server, channelID: channelID, channelName: name)
    }

    /// A started call, or a test failure. Takes the value (not an autoclosure) so `await` happens
    /// before `XCTUnwrap`, which cannot suspend.
    private func call(_ model: CallsCallModel?,
                      file: StaticString = #filePath, line: UInt = #line) throws -> CallsCallModel {
        try XCTUnwrap(model, file: file, line: line)
    }

    /// A `call_state` frame's `call` value is a JSON **string** (measured), so the fixtures below
    /// escape it the way the server does.
    private func callStateFrame(channelID: String = "chan1", call: String) -> String {
        let escaped = call.replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"channel_id":"\#(channelID)","call":"\#(escaped)"}"#
    }

    // MARK: - Entry point

    func testRefreshPublishesTheServersAnswer() async {
        XCTAssertFalse(coordinator.isCallActive(serverID: server.id, channelID: "chan1"))

        service.active = .success(true)
        await coordinator.refreshActiveCall(server: server, channelID: "chan1")
        XCTAssertTrue(coordinator.isCallActive(serverID: server.id, channelID: "chan1"))
        XCTAssertEqual(service.activeChannelIDs, ["chan1"])

        service.active = .success(false)
        await coordinator.refreshActiveCall(server: server, channelID: "chan1")
        XCTAssertFalse(coordinator.isCallActive(serverID: server.id, channelID: "chan1"))
    }

    /// No Calls plugin ⇒ no button, said once, and not re-asked on every pane appearance.
    func testMissingPluginIsRememberedAndHidesTheButton() async {
        service.active = .failure(MMError.notFound)
        service.version = .failure(MMError.notFound)
        await coordinator.refreshActiveCall(server: server, channelID: "chan1")
        XCTAssertFalse(coordinator.isCallActive(serverID: server.id, channelID: "chan1"))
        XCTAssertEqual(service.activeRequests, 1)
        XCTAssertNotNil(coordinator.unavailable[server.id])

        await coordinator.refreshActiveCall(server: server, channelID: "chan2")
        XCTAssertEqual(service.activeRequests, 1, "a server without Calls is not asked again")

        // …and starting a call there fails cleanly instead of asking the socket to join nothing.
        let model = await startCall()
        XCTAssertNil(model)
        XCTAssertNil(coordinator.surface)
    }

    /// A transport failure must not hide a call that is really up (and must not invent one).
    func testTransportFailureKeepsTheLastKnownAnswer() async {
        service.active = .success(true)
        await coordinator.refreshActiveCall(server: server, channelID: "chan1")
        XCTAssertTrue(coordinator.isCallActive(serverID: server.id, channelID: "chan1"))

        service.active = .failure(MMError.transport("timed out"))
        await coordinator.refreshActiveCall(server: server, channelID: "chan1")
        XCTAssertTrue(coordinator.isCallActive(serverID: server.id, channelID: "chan1"),
                      "a blip keeps the join button")

        service.active = .success(false)
        await coordinator.refreshActiveCall(server: server, channelID: "chan1")
        XCTAssertFalse(coordinator.isCallActive(serverID: server.id, channelID: "chan1"),
                       "the server's next real answer wins")
    }

    func testSignedOutMeansNoJoinButton() async {
        coordinator.userIDProvider = { _ in nil }
        service.active = .success(true)
        await coordinator.refreshActiveCall(server: server, channelID: "chan1")
        XCTAssertFalse(coordinator.isCallActive(serverID: server.id, channelID: "chan1"))
        XCTAssertEqual(service.activeRequests, 0, "no session, no request")
    }

    // MARK: - Starting a call

    func testStartCallJoinsThroughTheEngineAndPublishesTheModel() async throws {
        let started = await startCall()
        let model = try XCTUnwrap(started)
        XCTAssertEqual(coordinator.surface?.id, model.id)
        XCTAssertEqual(engine.calls.startedChannels, ["chan1"])
        XCTAssertEqual(model.channelName, "Town Square")
        XCTAssertTrue(coordinator.isCallActive(serverID: server.id, channelID: "chan1"))
        XCTAssertEqual(service.requestedUserIDBatches.count, 0, "no participants yet, no profile read")
    }

    /// One call at a time: a second join would put two sessions of this account in a call and make
    /// the mute control ambiguous. The same channel's button is idempotent.
    func testOneCallAtATime() async throws {
        let first = try call(await startCall())
        let again = try call(await startCall())
        XCTAssertEqual(first.id, again.id)

        let other = await startCall("chan2")
        XCTAssertNil(other)
        XCTAssertEqual(coordinator.surface?.channelID, "chan1")
        XCTAssertEqual(engine.calls.startedChannels, ["chan1"])
    }

    func testNoTransportMeansNoCall() async {
        coordinator.transportProvider = { _ in nil }
        let model = await startCall()
        XCTAssertNil(model)
        XCTAssertNil(coordinator.surface)
    }

    /// The plugin build is the protocol gate: fetched once, then cached.
    func testPluginVersionIsFetchedOnce() async throws {
        let first = try await coordinator.pluginVersion(for: server)
        let second = try await coordinator.pluginVersion(for: server)
        XCTAssertEqual(first, .v0_29_8)
        XCTAssertEqual(second, first)
        XCTAssertEqual(service.versionRequests, 1)
    }

    // MARK: - The call itself

    /// A `call_state` frame produces one tile per session, with the reader marked and the host read
    /// from `host_id` — not from `owner_id`.
    ///
    /// The frame is decoded by `CallsEvent(name:data:)` (exactly what the bridge does) and folded by
    /// `CallsCallModel.handle` (exactly what the pump does); the assertions are then synchronous, so
    /// the tile rules are pinned against a state, not against a schedule.
    func testCallStateDrawsTheTilesAndResolvesNames() async throws {
        service.usersByID = [
            "me": MMUser(id: "me", username: "ada", firstName: "Ada", lastName: "Lovelace"),
            "u2": MMUser(id: "u2", username: "grace", firstName: "Grace", lastName: "Hopper")
        ]
        let model = try call(await startCall())

        await model.handle(try callsEvent("custom_com.mattermost.calls_call_state", callStateFrame(call: """
        {"id":"call1","channel_id":"chan1","start_at":1700000000000,"owner_id":"me","host_id":"u2",\
        "sessions":[{"session_id":"s1","user_id":"me","unmuted":false,"raised_hand":0},\
        {"session_id":"s2","user_id":"u2","unmuted":true,"raised_hand":1793094724582}]}
        """)))

        XCTAssertEqual(model.participants.count, 2, "one tile per session")
        XCTAssertEqual(model.participants.map(\.label), ["Grace Hopper", "Ada Lovelace (you)"],
                       "the raised hand sorts first")
        let host = try XCTUnwrap(model.participants.first { $0.userID == "u2" })
        XCTAssertTrue(host.isHost, "host comes from host_id")
        XCTAssertEqual(host.stateDescription, "hand raised, unmuted, host")
        XCTAssertTrue(model.participants.first { $0.userID == "me" }?.isMuted ?? false)
        XCTAssertEqual(service.requestedUserIDBatches.count, 1, "one batched profile read")
        XCTAssertEqual(Set(service.requestedUserIDBatches[0]), ["me", "u2"])

        // A second `call_state` for people whose profiles are already cached: nothing needs
        // fetching, so the tiles can only move because the fold itself rebuilds them. Without this
        // half, `resolveProfilesIfNeeded`'s own rebuild would hide a `call_state` that fails to.
        await model.handle(try callsEvent("custom_com.mattermost.calls_call_state", callStateFrame(call: """
        {"id":"call1","channel_id":"chan1","start_at":1700000000000,"owner_id":"me","host_id":"me",\
        "sessions":[{"session_id":"s1","user_id":"me","unmuted":false,"raised_hand":0}]}
        """)))
        XCTAssertEqual(model.participants.count, 1, "the host left, and the tiles followed")
        XCTAssertTrue(model.participants.first?.isHost ?? false, "the host moved to the reader")
        XCTAssertEqual(service.requestedUserIDBatches.count, 1, "cached profiles: no second read")
    }

    /// The deltas the engine deliberately does not model: mute, hand, voice, join/leave.
    ///
    /// Each delta is folded through `handle` and checked before the next one is delivered, so the
    /// test states what each frame does rather than what the tiles look like after a wait. The wire
    /// for the same frames (socket → bridge → pump → model) is pinned by
    /// `testParticipantDeltasFromTheSocketReachTheTiles`.
    func testParticipantDeltasUpdateTheTiles() async throws {
        service.usersByID = ["me": MMUser(id: "me", username: "ada"),
                             "u2": MMUser(id: "u2", username: "grace")]
        let model = try call(await startCall())

        await model.handle(try callsEvent("custom_com.mattermost.calls_call_state", callStateFrame(call: """
        {"id":"call1","channel_id":"chan1",\
        "sessions":[{"session_id":"s1","user_id":"me","unmuted":false}]}
        """)))
        XCTAssertEqual(model.participants.count, 1)
        XCTAssertTrue(model.isMuted)

        await model.handle(try callsEvent("custom_com.mattermost.calls_user_unmuted",
                                         #"{"channel_id":"chan1","user_id":"me","session_id":"s1"}"#))
        XCTAssertFalse(model.isMuted)
        XCTAssertEqual(model.participants.first?.stateDescription, "unmuted")

        await model.handle(try callsEvent("custom_com.mattermost.calls_user_joined",
                                         #"{"channel_id":"chan1","user_id":"u2","session_id":"s2"}"#))
        XCTAssertEqual(model.participants.count, 2)
        XCTAssertTrue(model.participants.contains { $0.userID == "u2" })

        await model.handle(try callsEvent("custom_com.mattermost.calls_user_voice_on",
                                         #"{"channel_id":"chan1","user_id":"u2","session_id":"s2"}"#))
        XCTAssertTrue(model.participants.first { $0.userID == "u2" }?.isSpeaking ?? false)

        await model.handle(try callsEvent("custom_com.mattermost.calls_user_left",
                                         #"{"channel_id":"chan1","user_id":"u2","session_id":"s2"}"#))
        XCTAssertEqual(model.participants.count, 1)
    }

    /// `call_end` ends the surface and tells the coordinator, so the header stops offering it.
    ///
    /// The frame goes in through `CallsCallModel.handle`, which is exactly what the event pump calls
    /// for every frame off the socket, and every check after it is synchronous — no task, no stream
    /// and no wall-clock budget between the fold and the assertions.
    ///
    /// That is the whole point of this shape: it used to `waitUntil("ended")` with the default 3 s
    /// budget, and it went red in whole-suite runs while passing alone (t_21828c93). Measured: the
    /// same frame folds in ~10 ms here, and the test failed at 3.4–3.7 s whenever something else on
    /// the machine kept the test host from being scheduled for that long (two suite runs on one
    /// simulator, or 4.5 s of SIGSTOP on the host) — the budget measured the host, not this code.
    /// The budget was not the only defect: the phase could also be folded to `.ended` and then
    /// re-opened by an engine snapshot that was already in flight, which no budget can observe
    /// (see `testASnapshotTakenBeforeTheEndCannotReopenTheCall`).
    /// The wire — fake socket → `CallsEventBridge` → the pump → this same `handle` — is pinned by
    /// `testCallEndFromTheSocketReachesTheModelAndReleasesTheCoordinator`.
    func testCallEndedEndsTheSurfaceAndReleasesTheCoordinator() async throws {
        let model = try call(await startCall())

        await model.handle(.callEnded(channelID: "chan1"))

        XCTAssertEqual(model.phase, .ended)
        XCTAssertNil(coordinator.surface, "a call that ended is not offered by the header any more")
        XCTAssertEqual(model.durationLabel, "00:00")
    }

    /// The same end through the real path: a `call_end` frame on the fake socket, decoded by
    /// `CallsEventBridge`, delivered by the model's event pump, folded by the model, released by the
    /// coordinator.
    ///
    /// The wait is tied to the model's own completion signal (`onEnded`, which the model fires after
    /// `phase = .ended` and which is what releases the coordinator), so there is no poll and no
    /// latency budget to be late against. The 30 s is a hang detector: it is ~3000x the measured
    /// latency of this path (~10 ms), and it exists only so a broken pipeline fails instead of
    /// hanging the suite. A stuck pipeline reds here; a merely late one does not.
    func testCallEndFromTheSocketReachesTheModelAndReleasesTheCoordinator() async throws {
        let model = try call(await startCall())
        let folded = XCTestExpectation(description: "the model folded call_end")
        let coordinatorOnEnded = model.onEnded
        model.onEnded = {
            coordinatorOnEnded?()
            folded.fulfill()
        }

        transport.pushCalls("custom_com.mattermost.calls_call_end",
                            #"{"channel_id":"chan1","call_id":"call1"}"#)

        await fulfillment(of: [folded], timeout: 30)

        // Both are already true when the signal fires: `foldPhase` sets `phase` and then calls
        // `onEnded`, and the coordinator's own `onEnded` is what clears `surface`. Checked, not waited for.
        XCTAssertEqual(model.phase, .ended)
        XCTAssertNil(coordinator.surface, "the header stops offering a call that ended")
        XCTAssertEqual(model.durationLabel, "00:00")
    }

    /// A snapshot that was taken before the end cannot re-open the call.
    ///
    /// The two inputs to `phase` are independent: an engine snapshot is polled every 0.4 s and a
    /// `call_end` frame arrives on the socket, so a snapshot can land one main-actor turn after the
    /// end. Before `CallsSurfacePhase.fold` existed, that snapshot set `phase` back to `.joining`
    /// (measured: this is the failure the old end-of-call assertion reported under load — "timed out
    /// waiting for ended", because its poll never saw `.ended` at all).
    ///
    /// Both inputs are driven directly, in the order a loaded process produces them, so nothing here
    /// depends on a clock.
    func testASnapshotTakenBeforeTheEndCannotReopenTheCall() async throws {
        let model = try call(await startCall())
        await engine.setState(.connected)
        await model.applySnapshot()
        XCTAssertEqual(model.phase, .connected)

        await model.handle(.callEnded(channelID: "chan1"))
        XCTAssertEqual(model.phase, .ended)

        await engine.setState(.joining)      // the snapshot that was in flight when the end arrived
        await model.applySnapshot()

        XCTAssertEqual(model.phase, .ended, "a call that ended is not re-opened by a stale snapshot")
        XCTAssertNil(coordinator.surface)
    }

    /// Mute is optimistic and reaches the engine.
    ///
    /// The snapshot is folded once through `applySnapshot()` — the engine pump's own per-tick entry
    /// point — so `phase`/`microphone`/`controls` are asserted against a state the test created, not
    /// against how fast the pump got there. That the pump really feeds this same method is pinned by
    /// `testEngineSnapshotReachesThePhaseAndMicrophoneWithoutAPoll`.
    func testMuteIsOptimisticAndReachesTheEngine() async throws {
        let model = try call(await startCall())
        await engine.connect(microphone: .granted)
        await model.applySnapshot()
        XCTAssertEqual(model.phase, .connected, "the engine's snapshot is what makes the call live")
        XCTAssertEqual(model.microphone, .granted)
        XCTAssertTrue(model.controls.canToggleMute)

        await model.toggleMute()
        XCTAssertFalse(model.isMuted, "the button flips before the round trip")
        XCTAssertEqual(engine.calls.muteCalls, [false])

        await model.toggleMute()
        XCTAssertTrue(model.isMuted)
        XCTAssertEqual(engine.calls.muteCalls, [false, true])
    }

    func testRaiseHandReachesTheEngineAndMarksTheTile() async throws {
        service.usersByID = ["me": MMUser(id: "me", username: "ada")]
        let model = try call(await startCall())
        await engine.connect(microphone: .granted)
        await model.applySnapshot()
        XCTAssertEqual(model.phase, .connected)
        XCTAssertEqual(model.microphone, .granted)

        await model.toggleHand()
        XCTAssertTrue(model.hasRaisedHand)
        XCTAssertEqual(model.controls.handTitle, "Lower hand")
        XCTAssertEqual(engine.calls.handCalls, [true])

        await model.toggleHand()
        XCTAssertFalse(model.hasRaisedHand)
        XCTAssertEqual(engine.calls.handCalls, [true, false])
    }

    /// A refused microphone joins anyway (the web client's behaviour) and says so; the controls that
    /// would send audio are not offered.
    func testDeniedMicrophoneStillJoinsAndExplainsItself() async throws {
        let model = try call(await startCall())
        await engine.connect(microphone: .denied)
        await model.applySnapshot()
        XCTAssertEqual(model.phase, .connected, "a refused mic must not keep the reader out of the call")
        XCTAssertEqual(model.microphone, .denied)
        XCTAssertNotNil(model.microphoneMessage)
        XCTAssertFalse(model.controls.canToggleMute)
        XCTAssertTrue(model.controls.canLeave)
    }

    /// The whole engine-side wire, on the model's own signal: nothing here drives `applySnapshot`
    /// and nothing polls. The engine pump starts in `CallsCallModel.start()`, reads the engine's
    /// snapshot once per tick and folds it into `phase`/`microphone`; the test waits for the fold
    /// itself to be published.
    ///
    /// This is the coverage the three synchronous snapshot tests above cannot give: a mutation that
    /// stops the pump from starting (or from asking the engine) leaves them green and reds this.
    func testEngineSnapshotReachesThePhaseAndMicrophoneWithoutAPoll() async throws {
        let model = try call(await startCall())
        await engine.connect(microphone: .granted)

        await awaitSignal("the pump folded a connected snapshot", model.$phase) { $0 == .connected }

        // Both were set by the same `applySnapshot`, in that order — checked, not waited for.
        XCTAssertEqual(model.microphone, .granted)
        XCTAssertTrue(model.controls.canToggleMute)
    }

    /// Leaving stops the engine once, and the coordinator drops the call.
    ///
    /// `leave()` is awaited by the test, and the release it performs is synchronous inside it
    /// (`onEnded` → the coordinator's handler), so there is nothing to wait for afterwards.
    func testLeavingStopsTheEngineOnce() async throws {
        let model = try call(await startCall())
        await model.leave()
        XCTAssertNil(coordinator.surface, "the header stops offering the call the reader left")
        XCTAssertEqual(engine.calls.stopCount, 1)
        await model.leave()
        XCTAssertEqual(engine.calls.stopCount, 1, "a second leave is a no-op")
    }

    // MARK: - Sign-out and socket bookkeeping

    func testAuthPhaseChangedDropsTheCallAndRememberedFacts() async throws {
        service.active = .success(true)
        await coordinator.refreshActiveCall(server: server, channelID: "chan1")
        let model = try call(await coordinator.startCall(server: server, channelID: "chan1", channelName: nil))
        _ = try await coordinator.pluginVersion(for: server)
        XCTAssertTrue(coordinator.isCallActive(serverID: server.id, channelID: "chan1"))

        // The teardown that needs the engine is detached by design (`authPhaseChanged` must not be
        // async — the header has to stop offering the call on the same turn), so the test waits on
        // the model's own end signal. `onEnded` fires *after* `engine.stop()` inside `leave()`, so
        // the counter is already settled when it does. Chained, so the coordinator still receives it.
        let released = XCTestExpectation(description: "the model released the call")
        let coordinatorOnEnded = model.onEnded
        model.onEnded = {
            coordinatorOnEnded?()
            released.fulfill()
        }

        coordinator.authPhaseChanged(server.id)
        XCTAssertNil(coordinator.surface)
        XCTAssertFalse(coordinator.isCallActive(serverID: server.id, channelID: "chan1"))

        await fulfillment(of: [released], timeout: 30)
        XCTAssertEqual(engine.calls.stopCount, 1)

        // The plugin build is re-read for the new session rather than reused across sign-outs.
        _ = try? await coordinator.pluginVersion(for: server)
        XCTAssertEqual(service.versionRequests, 2)
    }

    /// The same participant deltas as `testParticipantDeltasUpdateTheTiles`, through the real wire:
    /// a plugin frame on the fake socket → `CallsEventBridge` → the model's event pump → the fold.
    ///
    /// The waits are the model's own `@Published` values (30 s hang detector, not a latency budget),
    /// because this is the one place where the delivery is asynchronous by design. Every rule that
    /// can be stated declaratively is in the synchronous test above; what this one adds is that the
    /// pump, the bridge and the decode are wired at all.
    func testParticipantDeltasFromTheSocketReachTheTiles() async throws {
        service.usersByID = ["me": MMUser(id: "me", username: "ada"),
                             "u2": MMUser(id: "u2", username: "grace")]
        let model = try call(await startCall())

        transport.pushCalls("custom_com.mattermost.calls_call_state", callStateFrame(call: """
        {"id":"call1","channel_id":"chan1",\
        "sessions":[{"session_id":"s1","user_id":"me","unmuted":false}]}
        """))
        await awaitSignal("the own tile appears", model.$participants) { $0.count == 1 }
        XCTAssertTrue(model.isMuted)

        transport.pushCalls("custom_com.mattermost.calls_user_unmuted",
                            #"{"channel_id":"chan1","user_id":"me","session_id":"s1"}"#)
        await awaitSignal("the own tile unmutes", model.$isMuted) { $0 == false }
        XCTAssertEqual(model.participants.first?.stateDescription, "unmuted")

        transport.pushCalls("custom_com.mattermost.calls_user_joined",
                            #"{"channel_id":"chan1","user_id":"u2","session_id":"s2"}"#)
        // The name, not just the tile: the tile is rebuilt once for the arrival and again for the
        // batched profile read, so waiting on the name is the signal that both have landed.
        await awaitSignal("the second tile appears with its name", model.$participants) {
            $0.contains { $0.userID == "u2" && $0.username == "grace" }
        }
        XCTAssertEqual(model.participants.count, 2)

        transport.pushCalls("custom_com.mattermost.calls_user_left",
                            #"{"channel_id":"chan1","user_id":"u2","session_id":"s2"}"#)
        await awaitSignal("the second tile leaves", model.$participants) { $0.count == 1 }
    }

    /// `call_state` / `call_end` from the socket move the header's button; another channel's call is
    /// untouched, and a frame that is not a Calls frame is not this coordinator's business.
    func testSocketFramesMoveTheJoinButton() async {
        coordinator.handle(.plugin(name: "custom_com.mattermost.calls_call_state",
                                   data: callsRaw(#"{"channel_id":"chan1","call":"{}"}"#)),
                           serverID: server.id)
        XCTAssertTrue(coordinator.isCallActive(serverID: server.id, channelID: "chan1"))

        coordinator.handle(.plugin(name: "custom_com.mattermost.calls_call_state",
                                   data: callsRaw(#"{"channel_id":"chan2","call":"{\"id\":\"call2\",\"channel_id\":\"chan2\"}"}"#)),
                           serverID: server.id)
        XCTAssertTrue(coordinator.isCallActive(serverID: server.id, channelID: "chan2"))

        coordinator.handle(.plugin(name: "custom_com.mattermost.calls_call_end",
                                   data: callsRaw(#"{"channel_id":"chan1"}"#)),
                           serverID: server.id)
        XCTAssertFalse(coordinator.isCallActive(serverID: server.id, channelID: "chan1"))
        XCTAssertTrue(coordinator.isCallActive(serverID: server.id, channelID: "chan2"),
                      "another channel's call is untouched")

        coordinator.handle(.unhandled(name: "posted"), serverID: server.id)
        XCTAssertTrue(coordinator.isCallActive(serverID: server.id, channelID: "chan2"))
    }
}
