// T44c — every Calls websocket event, decoded from a literal frame.
//
// The frames below are the wire shapes measured on plugin v0.29.8 (`server/websocket.go`). Three of
// them are the ones a client gets wrong:
//
//  * **`signal.data` is a JSON string, not an object.** The plugin publishes
//    `map[string]interface{}{"data": string(msg.Data), "connID": ...}`, so the description is
//    double-encoded. A decoder that reads `data` as an object sees `nil` and silently drops the
//    answer — a call that joins, offers, and never connects.
//  * **`call_state.call` is a JSON string too**, and it is the only event that carries the full
//    participant list.
//  * **`connID` lives on the event, not in the inner JSON.** It is how a socket tells its own
//    session's signalling from another session of the same account (the join ack cannot: it is
//    broadcast per user).

import Foundation
import XCTest
@testable import Mattermost

final class T44CCallsEventTests: XCTestCase {

    private let prefix = "custom_com.mattermost.calls_"

    // MARK: - Names

    func testNonCallsFramesDecodeToNil() {
        XCTAssertNil(CallsEvent(name: "posted", data: nil))
        XCTAssertNil(CallsEvent(name: "plugin_something_new", data: nil))
        XCTAssertNil(CallsEvent(name: "custom_com.other.plugin_thing", data: nil))
    }

    func testUnmodelledCallsEventIsKeptAsUnhandled() throws {
        let event = try XCTUnwrap(CallsEvent(name: prefix + "some_future_event",
                                             data: callsRaw("{}")))
        XCTAssertEqual(event, .unhandled(name: "some_future_event"))
        XCTAssertEqual(event.name, "some_future_event")
    }

    /// The prefix is `custom_` + plugin id + `_`; the *plugin id* contains dots, so a naive
    /// `split("_")` on the event name breaks. Pinned so nobody "simplifies" the prefix.
    func testPrefixKeepsTheDottedPluginID() {
        XCTAssertEqual(CallsProtocol.pluginID, "com.mattermost.calls")
        XCTAssertEqual(CallsProtocol.prefix, "custom_com.mattermost.calls_")
        XCTAssertEqual(CallsProtocol.eventName(from: "custom_com.mattermost.calls_join"), "join")
        XCTAssertNil(CallsProtocol.eventName(from: "custom_com.mattermost.calls"))
    }

    func testEveryModelledEventNameRoundTripsThroughTheEnum() {
        for event in CallsProtocol.Event.allCases {
            XCTAssertEqual(CallsProtocol.eventName(from: CallsProtocol.prefix + event.rawValue),
                           event.rawValue)
        }
    }

    // MARK: - join

    func testJoinAckCarriesTheSessionConnID() throws {
        let event = try XCTUnwrap(CallsEvent(name: prefix + "join",
                                            data: callsRaw(#"{"connID":"7f3a9c"}"#)))
        XCTAssertEqual(event, .joinAck(connID: "7f3a9c"))
    }

    /// A `join` without a `connID` cannot address signalling, so it is not an ack. Dropping it (nil)
    /// is deliberate: `nil` makes the engine fall back to its ack timeout, where an empty-string ack
    /// would look like a session that can never receive an answer.
    func testJoinWithoutConnIDIsNotAnAck() {
        XCTAssertNil(CallsEvent(name: prefix + "join", data: callsRaw("{}")))
        XCTAssertNil(CallsEvent(name: prefix + "join", data: callsRaw(#"{"connID":""}"#)))
        XCTAssertNil(CallsEvent(name: prefix + "join", data: nil))
    }

    // MARK: - signal

    func testSignalAnswerIsDoubleEncodedJSON() throws {
        let event = try XCTUnwrap(CallsEvent(
            name: prefix + "signal",
            data: signalPayload(connID: "abc",
                                inner: ["type": "answer", "sdp": "v=0\r\na=sendrecv\r\n"])))
        guard case .signal(let signal) = event else { return XCTFail("expected a signal") }
        XCTAssertEqual(signal.connID, "abc")
        XCTAssertEqual(signal.kind, "answer")
        guard case .description(let description) = signal.payload else {
            return XCTFail("expected a description")
        }
        XCTAssertEqual(description.kind, .answer)
        XCTAssertTrue(description.sdp.hasPrefix("v=0"))
    }

    /// The SFU's post-connect re-offer arrives exactly this way. Answering it is what makes inbound
    /// RTP non-zero (T44b §5); a decoder that only accepts `answer` here loses the media.
    func testSignalOfferDecodesAsAnOffer() throws {
        let event = try XCTUnwrap(CallsEvent(
            name: prefix + "signal",
            data: signalPayload(connID: "abc",
                                inner: ["type": "offer",
                                        "sdp": "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"])))
        guard case .signal(let signal) = event, case .description(let description) = signal.payload else {
            return XCTFail("expected an offer description")
        }
        XCTAssertEqual(description.kind, .offer)
        XCTAssertTrue(description.sdp.contains("m=audio"))
    }

    func testSignalCandidateDecodesWithItsIndexAndMid() throws {
        let event = try XCTUnwrap(CallsEvent(
            name: prefix + "signal",
            data: callsRaw(#"{"connID":"abc","data":"{\"type\":\"candidate\",\"candidate\":{\"candidate\":\"candidate:842163049 1 udp 1677729535 203.0.113.7 54321 typ srflx\",\"sdpMid\":\"0\",\"sdpMLineIndex\":0}}"}"#)))
        guard case .signal(let signal) = event, case .candidate(let candidate) = signal.payload else {
            return XCTFail("expected a candidate")
        }
        XCTAssertEqual(candidate.sdpMid, "0")
        XCTAssertEqual(candidate.sdpMLineIndex, 0)
        XCTAssertTrue(candidate.candidate.hasPrefix("candidate:842163049"))
        XCTAssertEqual(candidate.hostAndPort, "203.0.113.7:54321/udp")
    }

    /// The 1.x build sends `data` as a JSON **object** instead of a string in some paths. Both shapes
    /// must decode — the plugin changed this once already.
    func testSignalAcceptsAnObjectInsteadOfAJSONString() throws {
        let event = try XCTUnwrap(CallsEvent(
            name: prefix + "signal",
            data: callsRaw(#"{"connID":"abc","data":{"type":"answer","sdp":"v=0"}}"#)))
        guard case .signal(let signal) = event, case .description(let description) = signal.payload else {
            return XCTFail("expected a description")
        }
        XCTAssertEqual(description.kind, .answer)
    }

    /// A candidate whose `candidate` value is at the top level (rather than nested) is a shape the
    /// plugin's own webapp produces in one code path; it must not decode to an empty candidate.
    func testSignalCandidateAcceptsTheFlatShape() throws {
        let event = try XCTUnwrap(CallsEvent(
            name: prefix + "signal",
            data: callsRaw(#"{"connID":"abc","data":"{\"type\":\"candidate\",\"candidate\":\"candidate:1 1 udp 1 10.0.0.2 5000 typ host\",\"sdpMid\":\"audio\",\"sdpMLineIndex\":1}"}"#)))
        guard case .signal(let signal) = event, case .candidate(let candidate) = signal.payload else {
            return XCTFail("expected a candidate")
        }
        XCTAssertEqual(candidate.sdpMid, "audio")
        XCTAssertEqual(candidate.sdpMLineIndex, 1)
    }

    func testMalformedSignalIsDropped() {
        XCTAssertNil(CallsEvent(name: prefix + "signal", data: callsRaw("{}")))
        XCTAssertNil(CallsEvent(name: prefix + "signal",
                                data: callsRaw(#"{"connID":"abc","data":"not json"}"#)))
        XCTAssertNil(CallsEvent(name: prefix + "signal",
                                data: callsRaw(#"{"connID":"abc","data":"{\"sdp\":\"v=0\"}"}"#)))
    }

    // MARK: - call_state

    func testCallStateDecodesSessionsMuteAndHost() throws {
        let payload = """
        {"channel_id":"chan1","call":"{\\"id\\":\\"call1\\",\\"channel_id\\":\\"chan1\\",\\"start_at\\":1700000000000,\\"thread_id\\":\\"post1\\",\\"owner_id\\":\\"u1\\",\\"host_id\\":\\"u2\\",\\"sessions\\":[{\\"session_id\\":\\"s1\\",\\"user_id\\":\\"u1\\",\\"unmuted\\":true,\\"raised_hand\\":false},{\\"session_id\\":\\"s2\\",\\"user_id\\":\\"u2\\",\\"unmuted\\":false,\\"raised_hand\\":true}]}"}
        """
        let event = try XCTUnwrap(CallsEvent(name: prefix + "call_state", data: callsRaw(payload)))
        guard case .callState(let channelID, let call) = event else {
            return XCTFail("expected call_state")
        }
        XCTAssertEqual(channelID, "chan1")
        XCTAssertEqual(call.id, "call1")
        XCTAssertEqual(call.startAt, 1_700_000_000_000)
        XCTAssertEqual(call.threadID, "post1")
        XCTAssertEqual(call.sessions.count, 2)
        XCTAssertTrue(call.isUnmuted(userID: "u1"))
        XCTAssertFalse(call.isUnmuted(userID: "u2"))
        XCTAssertTrue(call.hasRaisedHand(userID: "u2"))
        // The host is not the owner on this call: a client that renders "host" from `owner_id` draws
        // the wrong name after a host transfer.
        XCTAssertEqual(call.hostID, "u2")
        XCTAssertEqual(call.ownerID, "u1")
        XCTAssertTrue(call.isHost(userID: "u2"))
        XCTAssertFalse(call.isHost(userID: "u1"))
    }

    func testCallStateWithASessionlessCallStillDecodes() throws {
        let payload = #"{"channel_id":"chan1","call":"{\"id\":\"call1\"}"}"#
        let event = try XCTUnwrap(CallsEvent(name: prefix + "call_state", data: callsRaw(payload)))
        guard case .callState(_, let call) = event else { return XCTFail("expected call_state") }
        XCTAssertEqual(call.id, "call1")
        XCTAssertEqual(call.channelID, "chan1", "the envelope's channel_id fills an absent one")
        XCTAssertTrue(call.sessions.isEmpty)
    }

    /// A malformed `call_state` must not become an empty call — an empty call renders as "no one is
    /// in this call" and invites the user to join a call that is actually full.
    func testMalformedCallStateIsDropped() {
        XCTAssertNil(CallsEvent(name: prefix + "call_state", data: callsRaw("{}")))
        XCTAssertNil(CallsEvent(name: prefix + "call_state",
                                data: callsRaw(#"{"call":"not json"}"#)))
        XCTAssertNil(CallsEvent(name: prefix + "call_state", data: callsRaw(#"{"call":null}"#)))
    }

    // MARK: - lifecycle events

    func testCallStartCarriesTheThreadThatHostsIt() throws {
        let event = try XCTUnwrap(CallsEvent(
            name: prefix + "call_start",
            data: callsRaw(#"{"id":"call1","post_id":"post1","thread_id":"post1","start_at":1700000000000,"owner_id":"u1","host_id":"u1"}"#)))
        guard case .callStarted(let started) = event else { return XCTFail("expected call_start") }
        XCTAssertEqual(started.id, "call1")
        XCTAssertEqual(started.threadID, "post1")
        XCTAssertEqual(started.startAt, 1_700_000_000_000)
    }

    func testCallEndNamesItsChannel() throws {
        let event = try XCTUnwrap(CallsEvent(name: prefix + "call_end",
                                            data: callsRaw(#"{"channel_id":"chan1"}"#)))
        XCTAssertEqual(event, .callEnded(channelID: "chan1"))
    }

    func testHostChangedPrefersSnakeCaseAndFallsBackToCamel() throws {
        let snake = try XCTUnwrap(CallsEvent(name: prefix + "call_host_changed",
                                            data: callsRaw(#"{"host_id":"u9"}"#)))
        XCTAssertEqual(snake, .hostChanged(channelID: "", hostID: "u9"))

        let camel = try XCTUnwrap(CallsEvent(name: prefix + "call_host_changed",
                                            data: callsRaw(#"{"hostID":"u8","channel_id":"c"}"#)))
        XCTAssertEqual(camel, .hostChanged(channelID: "c", hostID: "u8"))

        XCTAssertNil(CallsEvent(name: prefix + "call_host_changed", data: callsRaw("{}")))
    }

    func testUserEventsNameTheParticipantAndSession() throws {
        let joined = try XCTUnwrap(CallsEvent(
            name: prefix + "user_joined",
            data: callsRaw(#"{"channelID":"chan1","user_id":"u3","session_id":"s3"}"#)))
        XCTAssertEqual(joined, .userJoined(channelID: "chan1", userID: "u3", sessionID: "s3"))

        let left = try XCTUnwrap(CallsEvent(
            name: prefix + "user_left",
            data: callsRaw(#"{"channelID":"chan1","user_id":"u3","session_id":"s3"}"#)))
        XCTAssertEqual(left, .userLeft(channelID: "chan1", userID: "u3", sessionID: "s3"))

        let muted = try XCTUnwrap(CallsEvent(
            name: prefix + "user_muted",
            data: callsRaw(#"{"channelID":"chan1","user_id":"u3","session_id":"s3"}"#)))
        XCTAssertEqual(muted, .muteChanged(channelID: "chan1", userID: "u3", sessionID: "s3",
                                           unmuted: false))

        let unmuted = try XCTUnwrap(CallsEvent(
            name: prefix + "user_unmuted",
            data: callsRaw(#"{"channelID":"chan1","user_id":"u3","session_id":"s3"}"#)))
        XCTAssertEqual(unmuted, .muteChanged(channelID: "chan1", userID: "u3", sessionID: "s3",
                                             unmuted: true))

        let voice = try XCTUnwrap(CallsEvent(
            name: prefix + "user_voice_on",
            data: callsRaw(#"{"channelID":"chan1","userID":"u3","sessionID":"s3"}"#)))
        XCTAssertEqual(voice, .voiceChanged(channelID: "chan1", userID: "u3", sessionID: "s3",
                                            speaking: true))

        // The measured name, and the measured payload verbatim (T44d probe against 0.29.8): the
        // plugin publishes `user_raise_hand` with a camel-case `channelID`/`userID` and a
        // millisecond `raised_hand`.
        let hand = try XCTUnwrap(CallsEvent(
            name: prefix + "user_raise_hand",
            data: callsRaw(#"{"channelID":"chan1","raised_hand":1793095877275,"session_id":"s3","userID":"u3"}"#)))
        XCTAssertEqual(hand, .handChanged(channelID: "chan1", userID: "u3", sessionID: "s3",
                                          raised: true))

        let unraised = try XCTUnwrap(CallsEvent(
            name: prefix + "user_unraise_hand",
            data: callsRaw(#"{"channelID":"chan1","raised_hand":0,"session_id":"s3","userID":"u3"}"#)))
        XCTAssertEqual(unraised, .handChanged(channelID: "chan1", userID: "u3", sessionID: "s3",
                                              raised: false))

        let screen = try XCTUnwrap(CallsEvent(
            name: prefix + "user_screen_on",
            data: callsRaw(#"{"channelID":"chan1","user_id":"u3","session_id":"s3"}"#)))
        XCTAssertEqual(screen, .screenShareChanged(channelID: "chan1", userID: "u3",
                                                   sessionID: "s3", sharing: true))
    }

    /// `user_raised_hand` is **not** what 0.29.8 sends (`user_raise_hand` is), but `CallsProtocol`
    /// accepts it as an alias: a build that used the past-tense name must not have its hand events
    /// silently become `unhandled`, which is the failure mode that looks like "the feature works".
    func testPastTenseHandEventNameIsAcceptedAsAnAlias() throws {
        let event = try XCTUnwrap(CallsEvent(
            name: prefix + "user_raised_hand",
            data: callsRaw(#"{"channelID":"chan1","user_id":"u3","session_id":"s3"}"#)))
        XCTAssertEqual(event, .handChanged(channelID: "chan1", userID: "u3", sessionID: "s3",
                                           raised: true))
    }

    /// `user_*` events always name a user; one that does not is not decodable into a participant.
    func testUserEventWithoutAUserIsDropped() {
        XCTAssertNil(CallsEvent(name: prefix + "user_joined", data: callsRaw("{}")))
        XCTAssertNil(CallsEvent(name: prefix + "user_joined",
                                data: callsRaw(#"{"user_id":""}"#)))
    }

    func testErrorEventCarriesTheServerText() throws {
        let event = try XCTUnwrap(CallsEvent(name: prefix + "error",
                                            data: callsRaw(#"{"data":"call is full"}"#)))
        XCTAssertEqual(event, .error("call is full"))

        let fallback = try XCTUnwrap(CallsEvent(name: prefix + "error", data: callsRaw("{}")))
        XCTAssertEqual(fallback, .error("unspecified Calls error"))
    }

    // MARK: - SocketEvent integration

    /// A `custom_<plugin id>_<event>` frame is a first-class `SocketEvent.plugin` — not `unhandled`.
    /// The payload has to survive: the Calls decoder reads it.
    func testSocketEventRoutesCallsFramesAsPluginEvents() throws {
        let frame = try socketFrame(event: prefix + "join", seq: 1, data: #"{"connID":"abc"}"#)
        let event = try XCTUnwrap(SocketEvent(frame: frame))
        guard case .plugin(let name, let data) = event else {
            return XCTFail("expected .plugin, got \(event)")
        }
        XCTAssertEqual(name, prefix + "join")
        XCTAssertEqual(data["connID"]?.stringValue, "abc")
        XCTAssertEqual(CallsEvent(name: name, data: data), .joinAck(connID: "abc"))
    }

    /// …while a plugin event the app does not model still has a shape of its own, and a core event is
    /// untouched by the change.
    func testUnprefixedPluginFramesStayUnhandled() throws {
        let frame = try socketFrame(event: "plugin_something_new", seq: 2, data: "{}")
        let event = try XCTUnwrap(SocketEvent(frame: frame))
        XCTAssertEqual(event, .unhandled(name: "plugin_something_new"))
    }

    /// Decode a frame the way the real socket does — from JSON text, not from a memberwise init the
    /// decoder does not have.
    private func socketFrame(event: String, seq: Int, data: String) throws -> MMSocketFrame {
        let json = #"{"event":"\#(event)","seq":\#(seq),"data":\#(data),"broadcast":{}}"#
        return try JSONDecoder().decode(MMSocketFrame.self, from: Data(json.utf8))
    }

    /// The measured `signal` payload: `{connID, data: <JSON **string**>}`. Built with
    /// `JSONSerialization` rather than by hand because an SDP carries CRLFs, and CRLF inside a JSON
    /// string is only legal *escaped* — a hand-written literal silently produces invalid JSON (which
    /// is exactly how three fixtures in the first cut of this file were wrong).
    private func signalPayload(connID: String, inner: [String: Any]) -> MMRawJSON {
        let innerData = try! JSONSerialization.data(withJSONObject: inner,
                                                    options: [.sortedKeys, .withoutEscapingSlashes])
        let innerString = String(decoding: innerData, as: UTF8.self)
        let outer: [String: Any] = ["connID": connID, "data": innerString]
        let outerData = try! JSONSerialization.data(withJSONObject: outer)
        return callsRaw(String(decoding: outerData, as: UTF8.self))
    }
}
