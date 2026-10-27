// Behaviour reference: mattermost-plugin-calls `server/websocket.go` (`wsEvent*` constants and the
// payloads published at each site), measured on the fixture with `scripts/t44_calls_probe.py` and
// `scripts/t44b_rtp_spike.js`. Own implementation from the wire contract.
//
// The decode layer: one `MMSocketFrame` in, one typed `CallsEvent` (or `nil`) out. Nothing here
// talks to a socket, a UI or WebRTC — which is what makes every branch below unit-testable with a
// literal frame.

import Foundation

/// A `signal` event's inner payload.
///
/// Measured shape: the event's `data` is `{data: <JSON string>, connID: <string>}`; the inner JSON is
/// `{type:"answer"|"offer"|"candidate", sdp?: string, candidate?: object}`.
///
/// The **`connID` is part of the model**, not an afterthought: the plugin publishes signalling with
/// `WebSocketBroadcast{ConnectionID: us.connID}` *and* the join ack is broadcast per user, so with two
/// sockets of one account a socket cannot tell which session a signal belongs to from the ack. The
/// reliable key is `data.connID` on the first `answer` a socket receives
/// (`docs/t44b-calls-media-path.md` §5, T44c card comment item 2) — the port filters on it.
struct CallsSignal: Equatable, Sendable {
    enum Payload: Equatable, Sendable {
        case description(CallsSessionDescription)
        case candidate(CallsIceCandidate)
        /// A signal type this build does not model (`rollback`, a future addition). Carried so the
        /// caller can log it instead of silently dropping the stream.
        case unknown(String)
    }

    var connID: String
    var payload: Payload

    var kind: String {
        switch payload {
        case .description(let description): return description.kind.rawValue
        case .candidate: return "candidate"
        case .unknown(let type): return type
        }
    }
}

/// Everything the Calls plugin can say, typed.
enum CallsEvent: Equatable, Sendable {
    /// The plugin acknowledged a `join` and named the session's connection.
    case joinAck(connID: String)
    /// SDP or ICE from the SFU, addressed to one `connID`.
    case signal(CallsSignal)
    /// The whole call state (`call_state`), already decoded from its JSON string.
    case callState(channelID: String, call: CallsCall)
    /// A call started in a channel this client is watching.
    case callStarted(CallsStartedCall)
    /// The call ended.
    case callEnded(channelID: String)
    /// The host changed (`call_host_changed`).
    case hostChanged(channelID: String, hostID: String)
    /// A participant's session appeared (`user_connected` / `user_joined`).
    ///
    /// Every participation delta carries the channel it belongs to (`channelID` in the measured
    /// payload, T44d) — kept because a client can be a member of several channels with a live call
    /// and must not fold another call's participants into the one it is drawing.
    case userJoined(channelID: String, userID: String, sessionID: String)
    /// A participant's session disappeared (`user_left` / `user_disconnected`).
    case userLeft(channelID: String, userID: String, sessionID: String)
    /// A participant muted or unmuted (`user_muted` / `user_unmuted`).
    case muteChanged(channelID: String, userID: String, sessionID: String, unmuted: Bool)
    /// A participant's voice stream started or stopped (`user_voice_on` / `user_voice_off`).
    case voiceChanged(channelID: String, userID: String, sessionID: String, speaking: Bool)
    /// A hand was raised or lowered (`user_raise_hand` / `user_unraise_hand` — measured names).
    case handChanged(channelID: String, userID: String, sessionID: String, raised: Bool)
    /// A screen share started or stopped (`user_screen_on` / `user_screen_off`).
    case screenShareChanged(channelID: String, userID: String, sessionID: String, sharing: Bool)
    /// The plugin reported an error for this session (`error`).
    case error(String)
    /// A plugin event this build does not model. Kept (not dropped) so a newer server cannot make
    /// the stream look complete when it is not.
    case unhandled(name: String)

    /// Decode one plugin frame from its name and `data` payload.
    ///
    /// Returns `nil` when the frame is not a Calls frame, or when its payload is malformed beyond
    /// the point of being useful — a malformed `call_state` must not become an empty call.
    init?(name: String, data: MMRawJSON?) {
        guard let name = CallsProtocol.eventName(from: name) else { return nil }

        switch name {
        case CallsProtocol.Event.join.rawValue:
            guard let connID = data?["connID"]?.stringValue, !connID.isEmpty else { return nil }
            self = .joinAck(connID: connID)

        case CallsProtocol.Event.signal.rawValue:
            guard let connID = data?["connID"]?.stringValue else { return nil }
            guard let inner = Self.jsonStringOrObject(data?["data"]) else { return nil }
            guard case .object(let fields) = inner,
                  let type = fields["type"]?.stringValue else { return nil }
            if type == "candidate" {
                // Nested (`{candidate: {candidate, sdpMid, sdpMLineIndex}}`) is the measured shape —
                // it is what `RTCIceCandidate`'s JSON form is under the plugin's `candidate` key. A
                // flat form (`{candidate: "candidate:…", sdpMid, …}`) is also accepted: it is a shape
                // the plugin's JS client has produced, and dropping the whole signal for it would
                // cost a connectivity check for no benefit.
                let nested = fields["candidate"].flatMap { CallsIceCandidate(payload: $0) }
                guard let candidate = nested ?? CallsIceCandidate(payload: inner) else {
                    return nil
                }
                self = .signal(CallsSignal(connID: connID, payload: .candidate(candidate)))
            } else if let kind = CallsSessionDescription.Kind(rawValue: type),
                      kind != .rollback,
                      let sdp = fields["sdp"]?.stringValue, !sdp.isEmpty {
                self = .signal(CallsSignal(
                    connID: connID,
                    payload: .description(CallsSessionDescription(kind: kind, sdp: sdp))))
            } else {
                self = .signal(CallsSignal(connID: connID, payload: .unknown(type)))
            }

        case CallsProtocol.Event.callState.rawValue:
            guard let raw = data?["call"] else { return nil }
            let channelID = data?["channel_id"]?.stringValue ?? ""
            guard let call = try? CallsCall(payload: raw, channelID: channelID) else {
                return nil
            }
            self = .callState(channelID: call.channelID.isEmpty ? channelID : call.channelID,
                              call: call)

        case CallsProtocol.Event.callStart.rawValue:
            self = .callStarted(CallsStartedCall(
                id: data?["id"]?.stringValue ?? "",
                postID: data?["post_id"]?.stringValue ?? "",
                threadID: data?["thread_id"]?.stringValue ?? "",
                startAt: data?["start_at"]?.int64Value ?? 0,
                ownerID: data?["owner_id"]?.stringValue ?? "",
                hostID: data?["host_id"]?.stringValue ?? ""))

        case CallsProtocol.Event.callEnd.rawValue:
            self = .callEnded(channelID: data?["channel_id"]?.stringValue ?? "")

        case CallsProtocol.Event.callHostChanged.rawValue:
            guard let hostID = data?["host_id"]?.stringValue ?? data?["hostID"]?.stringValue,
                  !hostID.isEmpty else { return nil }
            self = .hostChanged(channelID: data?["channel_id"]?.stringValue ?? "", hostID: hostID)

        case CallsProtocol.Event.userConnected.rawValue, CallsProtocol.Event.userJoined.rawValue:
            guard let userID = Self.userID(from: data) else { return nil }
            self = .userJoined(channelID: Self.channelID(from: data), userID: userID,
                               sessionID: Self.sessionID(from: data))

        case CallsProtocol.Event.userLeft.rawValue, CallsProtocol.Event.userDisconnected.rawValue:
            guard let userID = Self.userID(from: data) else { return nil }
            self = .userLeft(channelID: Self.channelID(from: data), userID: userID,
                             sessionID: Self.sessionID(from: data))

        case CallsProtocol.Event.userMuted.rawValue, CallsProtocol.Event.userUnmuted.rawValue:
            guard let userID = Self.userID(from: data) else { return nil }
            self = .muteChanged(channelID: Self.channelID(from: data),
                                userID: userID,
                                sessionID: Self.sessionID(from: data),
                                unmuted: name == CallsProtocol.Event.userUnmuted.rawValue)

        case CallsProtocol.Event.userVoiceOn.rawValue, CallsProtocol.Event.userVoiceOff.rawValue:
            guard let userID = Self.userID(from: data) else { return nil }
            self = .voiceChanged(channelID: Self.channelID(from: data),
                                 userID: userID,
                                 sessionID: Self.sessionID(from: data),
                                 speaking: name == CallsProtocol.Event.userVoiceOn.rawValue)

        case CallsProtocol.Event.userRaisedHand.rawValue,
             CallsProtocol.Event.userUnraisedHand.rawValue:
            guard let userID = Self.userID(from: data) else { return nil }
            self = .handChanged(channelID: Self.channelID(from: data),
                                userID: userID,
                                sessionID: Self.sessionID(from: data),
                                raised: name == CallsProtocol.Event.userRaisedHand.rawValue)

        case CallsProtocol.Event.userScreenOn.rawValue,
             CallsProtocol.Event.userScreenOff.rawValue:
            guard let userID = Self.userID(from: data) else { return nil }
            self = .screenShareChanged(channelID: Self.channelID(from: data),
                                       userID: userID,
                                       sessionID: Self.sessionID(from: data),
                                       sharing: name == CallsProtocol.Event.userScreenOn.rawValue)

        case CallsProtocol.Event.error.rawValue:
            // `data.data` is the error text (`{"data": "..."}`), and some builds use `error`.
            let text = data?["data"]?.stringValue
                ?? data?["error"]?.stringValue
                ?? data?["message"]?.stringValue
            self = .error(text ?? "unspecified Calls error")

        default:
            self = .unhandled(name: name)
        }
    }

    /// The event name without the plugin prefix (for logs and `unhandled`).
    var name: String {
        switch self {
        case .joinAck: return CallsProtocol.Event.join.rawValue
        case .signal: return CallsProtocol.Event.signal.rawValue
        case .callState: return CallsProtocol.Event.callState.rawValue
        case .callStarted: return CallsProtocol.Event.callStart.rawValue
        case .callEnded: return CallsProtocol.Event.callEnd.rawValue
        case .hostChanged: return CallsProtocol.Event.callHostChanged.rawValue
        case .userJoined: return CallsProtocol.Event.userJoined.rawValue
        case .userLeft: return CallsProtocol.Event.userLeft.rawValue
        case .muteChanged: return CallsProtocol.Event.userMuted.rawValue
        case .voiceChanged: return CallsProtocol.Event.userVoiceOn.rawValue
        case .handChanged: return CallsProtocol.Event.userRaisedHand.rawValue
        case .screenShareChanged: return CallsProtocol.Event.userScreenOn.rawValue
        case .error: return CallsProtocol.Event.error.rawValue
        case .unhandled(let name): return name
        }
    }

    /// `user_*` events name the participant in `user_id`; `userID` is also accepted because the
    /// 1.x build's `user_voice_*` publishes `userID`.
    static func userID(from data: MMRawJSON?) -> String? {
        let candidates = [data?["user_id"], data?["userID"], data?["userId"]]
        for value in candidates {
            if let id = value?.stringValue, !id.isEmpty { return id }
        }
        return nil
    }

    static func sessionID(from data: MMRawJSON?) -> String {
        data?["session_id"]?.stringValue ?? data?["sessionID"]?.stringValue ?? ""
    }

    /// The channel a participation delta belongs to.
    ///
    /// Measured on 0.29.8: `{"channelID": "...", "session_id": "...", "userID": "...",
    /// "raised_hand": 1793095877275}` — the camel-case `channelID`, while the session is snake-case.
    /// Both spellings are accepted because the 1.x line has used `channel_id` in `call_state`.
    /// `""` means the frame did not say, and callers treat that as "applies to whatever is open"
    /// rather than dropping a real delta.
    static func channelID(from data: MMRawJSON?) -> String {
        data?["channelID"]?.stringValue ?? data?["channel_id"]?.stringValue ?? ""
    }

    /// A payload that may be a JSON **string** (the escaping `signal` and `call_state` use) or the
    /// object itself.
    static func jsonStringOrObject(_ raw: JSONValue?) -> JSONValue? {
        guard let raw else { return nil }
        if case .string(let text) = raw {
            guard let data = text.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(JSONValue.self, from: data)
        }
        return raw
    }
}
