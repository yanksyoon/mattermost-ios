// T44d — the native call surface's decisions, pinned without a server, a socket, WebRTC, a
// microphone or a wall clock.
//
// Everything under test here is pure (`CallsSurfaceModels.swift`), which is the point of the split:
// participant ordering, the control set, the phase mapping, the duration strings and the camera
// capability can all be wrong in ways nobody sees on a happy-path call, and each of those rules is a
// parity claim taken from `mattermost-mobile` v2.45.0 (`app/products/calls/*`).

import Foundation
import XCTest
@testable import Mattermost

final class T44DCallsSurfaceTests: XCTestCase {

    // MARK: - Helpers

    private func user(_ id: String, _ username: String, nick: String = "",
                      first: String = "", last: String = "") -> MMUser {
        MMUser(id: id, username: username, email: "", firstName: first, lastName: last, nickname: nick)
    }

    private func participant(session: String = "s1", user userID: String = "u1",
                             name: String = "Ada", muted: Bool = false,
                             handAt: Int64 = 0, host: Bool = false, me: Bool = false,
                             speaking: Bool = false, sharing: Bool = false) -> CallsParticipant {
        CallsParticipant(sessionID: session, userID: userID, username: name.lowercased(),
                         displayName: name, isMuted: muted, isSpeaking: speaking,
                         raisedHandAt: handAt, isHost: host, isMe: me, isSharingScreen: sharing)
    }

    // MARK: - Participant rows

    /// The tile's name comes from the profile, and a participant whose profile has not arrived is
    /// still drawn (hiding them would misreport who is in the call).
    func testParticipantRowsSurviveMissingProfilesAndMarkTheReader() throws {
        let call = CallsCall(id: "c1", channelID: "chan1", startAt: 1_700_000_000_000,
                             hostID: "u1",
                             sessions: [CallsSession(sessionID: "s1", userID: "u1", unmuted: true),
                                        CallsSession(sessionID: "s2", userID: "u2", unmuted: false),
                                        CallsSession(sessionID: "s3", userID: "u3", unmuted: false)])
        let rows = CallsParticipantDirectory.participants(
            call: call,
            profiles: ["u1": user("u1", "ada", nick: "Ada L."),
                       "u2": user("u2", "grace", first: "Grace", last: "Hopper")],
            myUserID: "u1")

        XCTAssertEqual(rows.count, 3)
        let mine = try XCTUnwrap(rows.first { $0.userID == "u1" })
        XCTAssertEqual(mine.label, "Ada L. (you)")
        XCTAssertTrue(mine.isMe)
        XCTAssertTrue(mine.isHost)
        XCTAssertEqual(mine.initials, "AL")

        let grace = try XCTUnwrap(rows.first { $0.userID == "u2" })
        XCTAssertEqual(grace.label, "Grace Hopper", "full name when there is no nickname")

        let unknown = try XCTUnwrap(rows.first { $0.userID == "u3" })
        XCTAssertEqual(unknown.label, "Unknown user", "a row with no profile is still a row")
        XCTAssertEqual(unknown.stateDescription, "muted")
    }

    /// Upstream's `sortSessions`: the speaker of a share first, then raised hands oldest-first, then
    /// unmuted before muted, then by name, then by session id so the order is total.
    func testParticipantOrderMatchesUpstream() {
        let rows = [
            participant(session: "s6", user: "u6", name: "Zoe", muted: true),
            participant(session: "s2", user: "u2", name: "Bob", handAt: 2_000),
            participant(session: "s1", user: "u1", name: "Ada", handAt: 1_000),
            participant(session: "s4", user: "u4", name: "Dee", muted: true, sharing: true),
            participant(session: "s3", user: "u3", name: "Cara"),
            participant(session: "s5", user: "u5", name: "abe", muted: true)
        ]
        let order = CallsParticipantDirectory.sorted(rows).map(\.sessionID)
        // share, then hands (1_000 before 2_000), then unmuted by name ("Cara" before "Zoe"), then
        // muted by name ("abe" before "Dee" before "Zoe").
        XCTAssertEqual(order, ["s4", "s1", "s2", "s3", "s5", "s6"])
    }

    /// Two sessions of one account are two tiles — that is what a call from two devices looks like —
    /// and the identical display name must not make the order unstable.
    func testIdenticalNamesFallBackToSessionID() {
        let rows = [participant(session: "sB", user: "u1", name: "Ada"),
                    participant(session: "sA", user: "u1", name: "Ada")]
        XCTAssertEqual(CallsParticipantDirectory.sorted(rows).map(\.sessionID), ["sA", "sB"])
    }

    func testTileStateDescribesWhatItDraws() {
        XCTAssertEqual(participant(muted: true, handAt: 5, host: true).stateDescription,
                       "hand raised, muted, host")
        XCTAssertEqual(participant(muted: false, speaking: true).stateDescription, "speaking")
        XCTAssertEqual(participant(muted: false).stateDescription, "unmuted")
        XCTAssertEqual(participant(muted: true, sharing: true).stateDescription,
                       "muted, sharing screen")
    }

    // MARK: - Duration

    func testDurationReadsMinutesThenHours() {
        let start: Int64 = 1_700_000_000_000
        let at = { (seconds: Double) in Date(timeIntervalSince1970: 1_700_000_000 + seconds) }

        XCTAssertEqual(CallsDuration.format(startAtMilliseconds: start, now: at(0)), "00:00")
        XCTAssertEqual(CallsDuration.format(startAtMilliseconds: start, now: at(65)), "01:05")
        XCTAssertEqual(CallsDuration.format(startAtMilliseconds: start, now: at(3_600 + 129)),
                       "1:02:09")
        XCTAssertEqual(CallsDuration.format(startAtMilliseconds: start, now: at(3_600 + 129),
                                            truncateWhenLong: true), "1:02")
    }

    /// The plugin's `start_at` is server time; a client whose clock is behind it must read `00:00`,
    /// never a negative timer.
    func testDurationNeverGoesNegative() {
        let start: Int64 = 1_700_000_000_000
        let earlier = Date(timeIntervalSince1970: 1_700_000_000 - 30)
        XCTAssertEqual(CallsDuration.format(startAtMilliseconds: start, now: earlier), "00:00")
        XCTAssertEqual(CallsDuration.format(startAtMilliseconds: 0, now: earlier), "00:00")
    }

    // MARK: - Phase

    func testPhaseMapsTheEngineStates() {
        func phase(_ state: CallsEngineState, connection: String = "connected",
                   wasConnected: Bool = true) -> CallsSurfacePhase {
            CallsSurfacePhase.derive(engine: state, connectionState: connection,
                                     wasConnected: wasConnected)
        }
        XCTAssertEqual(phase(.idle), .idle)
        XCTAssertEqual(phase(.requestingPermission), .joining)
        XCTAssertEqual(phase(.joining), .joining)
        XCTAssertEqual(phase(.offering), .connecting)
        XCTAssertEqual(phase(.negotiating), .connecting)
        XCTAssertEqual(phase(.connecting), .connecting)
        XCTAssertEqual(phase(.connected), .connected)
        XCTAssertEqual(phase(.ended), .ended)
        XCTAssertEqual(phase(.failed("boom")), .failed("boom"))
        XCTAssertEqual(phase(.permissionDenied), .failed("microphone access was refused"))
    }

    /// "Reconnecting…" exists only because the engine keeps `.connected` while libwebrtc's transport
    /// reports a drop — without this mapping a dropped call would keep reading "In call".
    func testReconnectingNeedsAPriorConnectionAndAConfirmedDrop() {
        func phase(_ connection: String, _ wasConnected: Bool) -> CallsSurfacePhase {
            CallsSurfacePhase.derive(engine: .connected, connectionState: connection,
                                     wasConnected: wasConnected)
        }
        XCTAssertEqual(phase("disconnected", true), .reconnecting)
        XCTAssertEqual(phase("failed", true), .reconnecting)
        XCTAssertEqual(phase("CHECKING", true), .reconnecting, "libwebrtc's strings vary in case")
        XCTAssertEqual(phase("disconnected", false), .connected, "never up is not a reconnection")
        XCTAssertEqual(phase("connected", true), .connected)
        XCTAssertEqual(phase("new", true), .connected)
    }

    func testPhaseStatusTextIsTheHeaderLine() {
        XCTAssertEqual(CallsSurfacePhase.connecting.statusText, "Connecting…")
        XCTAssertEqual(CallsSurfacePhase.connected.statusText, "In call")
        XCTAssertEqual(CallsSurfacePhase.reconnecting.statusText, "Reconnecting…")
        XCTAssertEqual(CallsSurfacePhase.ended.statusText, "Call ended")
        XCTAssertTrue(CallsSurfacePhase.connected.isLive)
        XCTAssertFalse(CallsSurfacePhase.ended.isLive)
        XCTAssertTrue(CallsSurfacePhase.failed("x").isTerminal)
    }

    // MARK: - Controls

    func testMuteAndHandNeedALiveCallAndAMicrophone() {
        let granted = CallsControlSet.derive(phase: .connected, microphone: .granted,
                                             isMuted: true, hasRaisedHand: false)
        XCTAssertTrue(granted.canToggleMute)
        XCTAssertTrue(granted.canToggleHand)
        XCTAssertEqual(granted.muteTitle, "Unmute")
        XCTAssertEqual(granted.handTitle, "Raise hand")
        XCTAssertTrue(granted.canLeave)

        let denied = CallsControlSet.derive(phase: .connected, microphone: .denied,
                                           isMuted: true, hasRaisedHand: true)
        XCTAssertFalse(denied.canToggleMute, "a refused mic must not offer \"Unmute\"")
        XCTAssertFalse(denied.canToggleHand)
        XCTAssertEqual(denied.muteTitle, "Unmute", "the title still states the call's mute state")

        let connecting = CallsControlSet.derive(phase: .connecting, microphone: .granted,
                                                isMuted: true, hasRaisedHand: false)
        XCTAssertFalse(connecting.canToggleMute, "not live yet")
        XCTAssertTrue(connecting.canLeave, "a user who changes their mind mid-join can leave")

        let ended = CallsControlSet.derive(phase: .ended, microphone: .granted,
                                           isMuted: false, hasRaisedHand: false)
        XCTAssertFalse(ended.canLeave)
        XCTAssertEqual(ended.muteTitle, "Mute")
    }

    /// The camera control is **absent**, and the reason is carried rather than guessed: this build
    /// has no capture path, and the plugin under test has no `video_on` at all.
    func testCameraIsAbsentInThisBuildAndTheReasonTravels() throws {
        let plugin = try XCTUnwrap(CallsPluginVersion(string: "0.29.8"))
        let capability = CallsVideoCapability.forBuild(plugin: plugin, engineCapturesVideo: false)
        XCTAssertFalse(capability.isSupported)

        let controls = CallsControlSet.derive(phase: .connected, microphone: .granted,
                                              isMuted: true, hasRaisedHand: false,
                                              video: capability)
        XCTAssertFalse(controls.showsCamera)
        XCTAssertNotNil(controls.cameraUnavailableReason)
        XCTAssertTrue(controls.cameraUnavailableReason?.contains("camera") ?? false)
    }

    /// …and it flips on by itself when both halves are ready, without the view changing.
    func testCameraAppearsOnlyWhenEngineAndPluginBothCarryVideo() throws {
        let old = try XCTUnwrap(CallsPluginVersion(string: "0.29.8"))
        let new = try XCTUnwrap(CallsPluginVersion(string: "1.2.0"))

        let noEngine = CallsVideoCapability.forBuild(plugin: new, engineCapturesVideo: false)
        XCTAssertFalse(noEngine.isSupported, "an engine without capture cannot offer video")

        let noPlugin = CallsVideoCapability.forBuild(plugin: old, engineCapturesVideo: true)
        XCTAssertFalse(noPlugin.isSupported, "0.29.8 has no video_on/video_off")

        let both = CallsVideoCapability.forBuild(plugin: new, engineCapturesVideo: true)
        XCTAssertTrue(both.isSupported)

        let live = CallsControlSet.derive(phase: .connected, microphone: .granted,
                                          isMuted: true, hasRaisedHand: false, video: both)
        XCTAssertTrue(live.showsCamera)

        let connecting = CallsControlSet.derive(phase: .connecting, microphone: .granted,
                                                isMuted: true, hasRaisedHand: false, video: both)
        XCTAssertFalse(connecting.showsCamera, "no camera before the call is up")
    }

    // MARK: - Microphone copy

    func testMicrophoneBannerCopyIsSpecificToTheGrant() {
        XCTAssertNil(CallsMicrophonePermission.granted.noMicrophoneMessage)
        for permission in [CallsMicrophonePermission.denied, .restricted, .undetermined] {
            let message = permission.noMicrophoneMessage
            XCTAssertNotNil(message)
            XCTAssertTrue(message?.contains("hear the call") ?? false,
                          "a reader without a mic can still hear: \(message ?? "")")
        }
        XCTAssertTrue(CallsMicrophonePermission.denied.noMicrophoneMessage?
            .contains("Settings") ?? false)
    }

    // MARK: - Wire shape

    /// `raised_hand` is a unix-millisecond timestamp on this plugin (measured, T44d), and the old
    /// bool shape is still accepted — a `true` becomes `1` rather than being dropped.
    func testRaisedHandAcceptsTheTimestampShapeAndTheBoolShape() throws {
        func call(_ raised: String) throws -> CallsCall {
            let inner = #"{"id":"c1","channel_id":"chan1","start_at":1,"host_id":"u1","sessions":[{"session_id":"s1","user_id":"u1","unmuted":false,\#(raised)}]}"#
            let escaped = inner.replacingOccurrences(of: "\"", with: "\\\"")
            let payload = try XCTUnwrap(CallsEvent(
                name: "custom_com.mattermost.calls_call_state",
                data: callsRaw(#"{"channel_id":"chan1","call":"\#(escaped)"}"#)))
            guard case .callState(_, let call) = payload else {
                throw XCTSkip("not a call_state")
            }
            return try XCTUnwrap(call)
        }

        let timestamp = try call(#""raised_hand":1793094724582"#)
        XCTAssertEqual(timestamp.sessions.first?.raisedHandAt, 1_793_094_724_582)
        XCTAssertTrue(timestamp.hasRaisedHand(userID: "u1"))

        let lowered = try call(#""raised_hand":0"#)
        XCTAssertEqual(lowered.sessions.first?.raisedHandAt, 0)
        XCTAssertFalse(lowered.hasRaisedHand(userID: "u1"))

        let legacy = try call(#""raised_hand":true"#)
        XCTAssertEqual(legacy.sessions.first?.raisedHandAt, 1)
        XCTAssertTrue(legacy.hasRaisedHand(userID: "u1"))

        let missing = try call(#""unmuted":false"#)
        XCTAssertEqual(missing.sessions.first?.raisedHandAt, 0)
    }
}
