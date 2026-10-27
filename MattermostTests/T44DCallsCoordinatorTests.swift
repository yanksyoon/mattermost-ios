// T44d — the calls surface's rules, driven through the real model and the real coordinator with
// fakes at the two seams (`CallsSurfaceServing`, `CallsEngineDriving`) and a fake socket.
//
// What is *not* faked away: the coordinator's gate (the only thing that decides whether a join button
// exists), the model's event folding, and the socket→`CallsEvent` bridge. So these tests cover the
// whole path from "a frame arrives on the server's one socket" to "the tile says muted", with no
// server, no plugin, no WebRTC and no microphone.

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

/// A scripted engine. `setState`/`setSnapshot` let a test make the model see "connected", a drop or
/// an end without a peer connection.
actor FakeCallsEngine: CallsEngineDriving {
    let calls = EngineCalls()
    private var state: CallsEngineState
    private var extra = CallsEngineSnapshot()

    init(state: CallsEngineState = .joining) {
        self.state = state
    }

    func setState(_ state: CallsEngineState) { self.state = state }
    func setSnapshot(_ mutate: (inout CallsEngineSnapshot) -> Void) { mutate(&extra) }

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

    /// Poll the main actor until `condition` holds — every state change here happens on the main
    /// actor from a task, so the alternative is a sleep that is slow and still racy.
    private func waitUntil(_ description: String,
                           timeout: TimeInterval = 3,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
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
    func testCallStateDrawsTheTilesAndResolvesNames() async throws {
        service.usersByID = [
            "me": MMUser(id: "me", username: "ada", firstName: "Ada", lastName: "Lovelace"),
            "u2": MMUser(id: "u2", username: "grace", firstName: "Grace", lastName: "Hopper")
        ]
        let model = try call(await startCall())
        await engine.setState(.connected)
        await engine.setSnapshot { $0.connectionState = "connected" }

        transport.pushCalls("custom_com.mattermost.calls_call_state", callStateFrame(call: """
        {"id":"call1","channel_id":"chan1","start_at":1700000000000,"owner_id":"me","host_id":"u2",\
        "sessions":[{"session_id":"s1","user_id":"me","unmuted":false,"raised_hand":0},\
        {"session_id":"s2","user_id":"u2","unmuted":true,"raised_hand":1793094724582}]}
        """))

        await waitUntil("two tiles") { model.participants.count == 2 }
        XCTAssertEqual(model.participants.map(\.label), ["Grace Hopper", "Ada Lovelace (you)"],
                       "the raised hand sorts first")
        let host = try XCTUnwrap(model.participants.first { $0.userID == "u2" })
        XCTAssertTrue(host.isHost, "host comes from host_id")
        XCTAssertEqual(host.stateDescription, "hand raised, unmuted, host")
        XCTAssertTrue(model.participants.first { $0.userID == "me" }?.isMuted ?? false)
        XCTAssertEqual(service.requestedUserIDBatches.count, 1, "one batched profile read")
        XCTAssertEqual(Set(service.requestedUserIDBatches[0]), ["me", "u2"])
    }

    /// The deltas the engine deliberately does not model: mute, hand, voice, join/leave.
    func testParticipantDeltasUpdateTheTiles() async throws {
        service.usersByID = ["me": MMUser(id: "me", username: "ada"),
                             "u2": MMUser(id: "u2", username: "grace")]
        let model = try call(await startCall())
        transport.pushCalls("custom_com.mattermost.calls_call_state",
                            callStateFrame(call: """
                            {"id":"call1","channel_id":"chan1",\
                            "sessions":[{"session_id":"s1","user_id":"me","unmuted":false}]}
                            """))
        await waitUntil("own tile") { model.participants.count == 1 }
        XCTAssertTrue(model.isMuted)

        transport.pushCalls("custom_com.mattermost.calls_user_unmuted",
                            #"{"channel_id":"chan1","user_id":"me","session_id":"s1"}"#)
        await waitUntil("own tile unmuted") { model.isMuted == false }
        XCTAssertEqual(model.participants.first?.stateDescription, "unmuted")

        transport.pushCalls("custom_com.mattermost.calls_user_joined",
                            #"{"channel_id":"chan1","user_id":"u2","session_id":"s2"}"#)
        await waitUntil("second tile") { model.participants.count == 2 }
        XCTAssertTrue(model.participants.contains { $0.userID == "u2" })

        transport.pushCalls("custom_com.mattermost.calls_user_voice_on",
                            #"{"channel_id":"chan1","user_id":"u2","session_id":"s2"}"#)
        await waitUntil("u2 speaking") {
            model.participants.first { $0.userID == "u2" }?.isSpeaking == true
        }

        transport.pushCalls("custom_com.mattermost.calls_user_left",
                            #"{"channel_id":"chan1","user_id":"u2","session_id":"s2"}"#)
        await waitUntil("back to one tile") { model.participants.count == 1 }
    }

    /// `call_end` ends the surface and tells the coordinator, so the header stops offering it.
    func testCallEndedEndsTheSurfaceAndReleasesTheCoordinator() async throws {
        let model = try call(await startCall())
        transport.pushCalls("custom_com.mattermost.calls_call_end",
                            #"{"channel_id":"chan1","call_id":"call1"}"#)
        await waitUntil("ended") { model.phase == .ended }
        await waitUntil("coordinator released") { coordinator.surface == nil }
        XCTAssertEqual(model.durationLabel, "00:00")
    }

    /// Mute is optimistic and reaches the engine.
    func testMuteIsOptimisticAndReachesTheEngine() async throws {
        let model = try call(await startCall())
        await engine.setState(.connected)
        await engine.setSnapshot {
            $0.connectionState = "connected"
            $0.microphonePermission = .granted
        }
        await waitUntil("connected with a microphone") {
            model.phase == .connected && model.microphone == .granted
        }
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
        await engine.setState(.connected)
        await engine.setSnapshot {
            $0.connectionState = "connected"
            $0.microphonePermission = .granted
        }
        await waitUntil("connected with a microphone") {
            model.phase == .connected && model.microphone == .granted
        }

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
        await engine.setState(.connected)
        await engine.setSnapshot {
            $0.connectionState = "connected"
            $0.microphonePermission = .denied
        }
        await waitUntil("connected without a mic") {
            model.phase == .connected && model.microphone == .denied
        }
        XCTAssertNotNil(model.microphoneMessage)
        XCTAssertFalse(model.controls.canToggleMute)
        XCTAssertTrue(model.controls.canLeave)
    }

    /// Leaving stops the engine once, and the coordinator drops the call.
    func testLeavingStopsTheEngineOnce() async throws {
        let model = try call(await startCall())
        await model.leave()
        await waitUntil("released") { coordinator.surface == nil }
        XCTAssertEqual(engine.calls.stopCount, 1)
        await model.leave()
        XCTAssertEqual(engine.calls.stopCount, 1, "a second leave is a no-op")
    }

    // MARK: - Sign-out and socket bookkeeping

    func testAuthPhaseChangedDropsTheCallAndRememberedFacts() async throws {
        service.active = .success(true)
        await coordinator.refreshActiveCall(server: server, channelID: "chan1")
        _ = try await coordinator.startCall(server: server, channelID: "chan1", channelName: nil)
        _ = try await coordinator.pluginVersion(for: server)
        XCTAssertTrue(coordinator.isCallActive(serverID: server.id, channelID: "chan1"))

        coordinator.authPhaseChanged(server.id)
        XCTAssertNil(coordinator.surface)
        XCTAssertFalse(coordinator.isCallActive(serverID: server.id, channelID: "chan1"))
        await waitUntil("engine stopped") { engine.calls.stopCount == 1 }

        // The plugin build is re-read for the new session rather than reused across sign-outs.
        _ = try? await coordinator.pluginVersion(for: server)
        XCTAssertEqual(service.versionRequests, 2)
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
