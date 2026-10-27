// Behaviour reference: mattermost-plugin-calls (server/websocket.go, server/client_message.go) read
// at the *installed* build (v0.29.8, commit 936dd00d3e456c843b846740aa76601d07e6a25a) and at the
// pinned protocol source (6b65e3b = v1.12.6-2). Own implementation from the measured wire contract;
// no plugin source is copied or transpiled. Record: docs/t44c-build-note.md, docs/t44-build-note.md §4.
//
// What this file is: the *names and the version gate* — the parts of the Calls protocol that are
// constant across the two plugin builds this programme has measured. The behavioural parts live in
// CallsEvents.swift (decode) and CallsSignallingPort.swift (the client half).

import Foundation

/// The Calls plugin's socket vocabulary.
///
/// Measured (T44, docs/t44-build-note.md §4.1): the plugin never opens its own socket. It hooks the
/// **core** `/api/v4/websocket` and every action/event is prefixed with
/// `custom_` + manifest id + `_`, so client actions are `custom_com.mattermost.calls_<type>` and
/// server events carry the same prefix. The prefix is compiled into the plugin
/// (`build/manifest/main.go:40`), not negotiated.
enum CallsProtocol {

    /// The plugin's manifest id (`plugin.json`).
    static let pluginID = "com.mattermost.calls"

    /// Action and event prefix. Index into it with `CallsProtocol.Action.rawValue` /
    /// `Event.rawValue`.
    static let prefix = "custom_" + pluginID + "_"

    /// The join payload's channel key. **`channelID`, not `channel_id`** — measured against the
    /// live 0.29.8 plugin (T44 check 3; a `channel_id` join is dropped with "missing channelID").
    static let channelKey = "channelID"

    /// Client → server actions (`server/client_message.go`).
    ///
    /// `videoOn` / `videoOff` exist only on 1.x; `CallsPluginVersion.supportsVideo` is the gate.
    /// The rest is the intersection of 0.29.8 and 1.x, which is what a client should speak
    /// (`docs/t44-build-note.md` §5 correction C3).
    enum Action: String, CaseIterable, Sendable {
        case join
        case leave
        case reconnect
        /// The SDP carrier. Must be a **MessagePack binary frame** whose `data.data` is a bin of
        /// zlib(JSON({type, sdp})) — the plugin type-asserts it to `[]byte`
        /// (`server/websocket.go:1226` at 0.29.8, `:1350` at 1.x) and the core JSON decoder can
        /// only produce a `string`, which the plugin drops with "invalid or missing sdp data".
        case sdp
        /// The ICE carrier. This one **is** a JSON string on the text path (`data.data` must be a
        /// `string` — `server/websocket.go` `clientMessageTypeICE`).
        case ice
        case mute
        case unmute
        case voiceOn = "voice_on"
        case voiceOff = "voice_off"
        case screenOn = "screen_on"
        case screenOff = "screen_off"
        case raiseHand = "raise_hand"
        case unraiseHand = "unraise_hand"
        case react
        case caption
        case metric
        case callState = "call_state"
        case ping
        /// 1.x only (`CallsPluginVersion.supportsVideo`).
        case videoOn = "video_on"
        /// 1.x only (`CallsPluginVersion.supportsVideo`).
        case videoOff = "video_off"

        /// The full action string on the socket.
        var wireValue: String { CallsProtocol.prefix + rawValue }

        /// Whether this build of the protocol has the action at all.
        func isAvailable(in version: CallsPluginVersion) -> Bool {
            switch self {
            case .videoOn, .videoOff: return version.supportsVideo
            case .caption: return version.supportsCaptions
            default: return true
            }
        }
    }

    /// Server → client events (`server/websocket.go` `wsEvent*`).
    enum Event: String, CaseIterable, Sendable {
        case signal
        case join
        case callState = "call_state"
        case callStart = "call_start"
        case callEnd = "call_end"
        case callHostChanged = "call_host_changed"
        case userConnected = "user_connected"
        case userDisconnected = "user_disconnected"
        case userJoined = "user_joined"
        case userLeft = "user_left"
        case userMuted = "user_muted"
        case userUnmuted = "user_unmuted"
        case userVoiceOn = "user_voice_on"
        case userVoiceOff = "user_voice_off"
        case userScreenOn = "user_screen_on"
        case userScreenOff = "user_screen_off"
        case userRaisedHand = "user_raised_hand"
        case userUnraisedHand = "user_unraised_hand"
        case error
    }

    /// The event name a plugin frame carries, stripped of the prefix — or `nil` when the frame is
    /// not a Calls frame at all.
    static func eventName(from wireName: String) -> String? {
        guard wireName.hasPrefix(prefix) else { return nil }
        return String(wireName.dropFirst(prefix.count))
    }
}

/// The Calls plugin's version, parsed from `GET /plugins/com.mattermost.calls/version`.
///
/// Two builds have been measured on this programme and they differ where it matters to a client:
/// **0.29.8** (the fixture) has no `video_on`/`video_off` and no `/rtc` REST route, while **1.x**
/// (the pinned protocol source) has both. A client must speak the intersection and version-gate the
/// additions (`docs/t44-build-note.md` §5, correction C3). The gate is data, not a build flag, so a
/// 1.x server can be exercised by the same binary.
struct CallsPluginVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    /// Parses `"0.29.8"`, `"1.12.6"`, and tolerates a `-prerelease`/`+build` suffix and a leading
    /// `v` (the plugin's own `version` field has neither, but a proxy may rewrite it).
    init?(string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") { text.removeFirst() }
        text = text.split(separator: "-").first.map(String.init) ?? text
        text = text.split(separator: "+").first.map(String.init) ?? text
        let parts = text.split(separator: ".")
        guard let first = parts.first, let major = Int(first) else { return nil }
        self.major = major
        self.minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        self.patch = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
    }

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static let v0_29_8 = CallsPluginVersion(major: 0, minor: 29, patch: 8)

    /// The `video_on` / `video_off` actions and the `/rtc` REST route arrive with 1.0.
    var supportsVideo: Bool { self >= CallsPluginVersion(major: 1, minor: 0, patch: 0) }

    /// `caption` (and the transcription bot's message pair) is a 0.26+ feature on this line.
    var supportsCaptions: Bool { self >= CallsPluginVersion(major: 0, minor: 26, patch: 0) }

    /// The data-channel signalling path (`join.dcSignaling`) is 1.x-only; this client never uses
    /// it (it keeps the SDP on the socket, which both builds accept), but the flag documents why.
    var supportsDataChannelSignalling: Bool { supportsVideo }

    /// The actions this client may send against this plugin build.
    var availableActions: [CallsProtocol.Action] {
        CallsProtocol.Action.allCases.filter { $0.isAvailable(in: self) }
    }

    static func < (lhs: CallsPluginVersion, rhs: CallsPluginVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}
