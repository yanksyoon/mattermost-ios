// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0
// (`162f2560d0e1df073220f7701d5a67cc17c8abeb`), Apache-2.0:
//   app/products/calls/screens/call_screen/participant_card.tsx  (tile: avatar, muted, hand, host, "(you)")
//   app/products/calls/screens/call_screen/call_screen.tsx       (per-card state, controls, connecting)
//   app/products/calls/utils.ts                                  (`sortSessions`, `getHandsRaised`)
//   app/products/calls/components/elapsed_timer.tsx              (mm:ss / h:mm:ss formatting)
//   app/products/calls/components/call_status_timer.tsx          (Connecting… / Calling…)
// Licence: Apache-2.0 — behaviour reimplemented per docs/THIRD_PARTY_NOTICES.md §22; no upstream
// source copied. SwiftUI decomposition is this repo's own (docs/component-map.md §1).
//
// Everything in this file is **pure**: value types and functions with no view, no socket, no
// WebRTC and no clock of their own. That is what makes the card's unit-testable claims — participant
// ordering, control-state derivation, duration and label formatting — testable on a machine with no
// server, no microphone and no second peer.
//
// Measured inputs (docs/t44d-build-note.md §2):
//  * `call_state.sessions[]` = `{session_id, user_id, unmuted, raised_hand}` with `raised_hand` a
//    **unix-millisecond timestamp** (`0` = lowered) — not a bool;
//  * a session joins **muted** (`unmuted: false`), so a freshly joined tile reads "muted";
//  * the host is `host_id`, which is not always `owner_id` (host transfer).

import Foundation

// MARK: - Participant

/// One participant tile.
///
/// A user can be in a call from more than one device, so the identity is the **session**, not the
/// user: two sessions of one account are two tiles (upstream renders them the same way). `isMe`
/// marks the reader's own session, which is the one the mute control acts on.
struct CallsParticipant: Equatable, Identifiable, Sendable {
    /// The Calls session id (`call_state.sessions[].session_id`) — the tile's identity.
    var sessionID: String
    var userID: String
    var username: String
    /// `nickname` → `first last` → `username`, the order every other native surface uses
    /// (`PostListDerivation.displayName(for:)`); `""` until the batched profile read lands.
    var displayName: String
    var isMuted: Bool
    /// `user_voice_on` / `user_voice_off` for this session (the plugin's own audio-level events).
    var isSpeaking: Bool
    /// `raised_hand`: unix milliseconds, `0` = lowered.
    var raisedHandAt: Int64
    var isHost: Bool
    /// This is the reader's own session.
    var isMe: Bool
    /// Someone is sharing their screen in this session. The native surface **does not render a
    /// share control** (T44d scope: screen share needs the T44e broadcast extension); it renders
    /// that another participant is sharing, because the call still plays their audio.
    var isSharingScreen: Bool

    var id: String { sessionID }

    var hasRaisedHand: Bool { raisedHandAt > 0 }

    /// The name drawn on the tile, with the reader's own row marked the way upstream marks it.
    var label: String {
        let name = displayName.isEmpty ? (username.isEmpty ? "Unknown user" : username) : displayName
        return isMe ? "\(name) (you)" : name
    }

    /// The tile's state as words, for the accessibility value and for VoiceOver.
    ///
    /// Order matches what the tile draws left-to-right: hand, voice/mute, host, sharing.
    var stateDescription: String {
        var parts: [String] = []
        if hasRaisedHand { parts.append("hand raised") }
        if isMuted { parts.append("muted") } else if isSpeaking { parts.append("speaking") } else { parts.append("unmuted") }
        if isHost { parts.append("host") }
        if isSharingScreen { parts.append("sharing screen") }
        return parts.joined(separator: ", ")
    }

    /// Avatar initials, from the same rule as every other avatar in this app.
    var initials: String {
        let source = displayName.isEmpty ? username : displayName
        let words = source.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first }.map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}

// MARK: - Participant derivation and ordering

enum CallsParticipantDirectory {

    /// Build the tile rows from the call state plus whatever profiles have been fetched.
    ///
    /// Unresolved users still get a tile (name falls back to the id): a participant the reader
    /// cannot name is still in the call, and hiding the tile would misreport who is there.
    static func participants(call: CallsCall?,
                             profiles: [String: MMUser],
                             myUserID: String?,
                             speaking: Set<String> = []) -> [CallsParticipant] {
        guard let call else { return [] }
        let rows = call.sessions.map { session -> CallsParticipant in
            let user = profiles[session.userID]
            return CallsParticipant(sessionID: session.sessionID,
                                    userID: session.userID,
                                    username: user?.username ?? "",
                                    displayName: user.map(displayName(for:)) ?? "",
                                    isMuted: !session.unmuted,
                                    isSpeaking: speaking.contains(session.sessionID),
                                    raisedHandAt: session.raisedHandAt,
                                    isHost: call.isHost(userID: session.userID),
                                    isMe: myUserID.map { $0 == session.userID } ?? false,
                                    isSharingScreen: call.screenSharingSessionID == session.sessionID)
        }
        return sorted(rows)
    }

    /// Upstream's `sortSessions`, reimplemented as one total order:
    ///
    /// 1. raised hands first, oldest hand first (the wire's timestamp is the tiebreaker, which is
    ///    what upstream's `a.raisedHand - b.raisedHand` does);
    /// 2. then unmuted before muted;
    /// 3. then by display name, case- and diacritic-insensitively (`localeCompare` semantics);
    /// 4. then by session id, so the order is total even for two identical names (Swift's sort is
    ///    not stable, so the name alone cannot be the last key).
    ///
    /// The presenter (screen share) sorts first upstream. This card renders no share control and the
    /// surface takes no share decision, but the ordering key is kept: a share started from the
    /// webview client still moves that tile to the front, which is what a reader expects.
    static func sorted(_ participants: [CallsParticipant]) -> [CallsParticipant] {
        participants.sorted { precedes($0, $1) }
    }

    static func precedes(_ a: CallsParticipant, _ b: CallsParticipant) -> Bool {
        if a.isSharingScreen != b.isSharingScreen { return a.isSharingScreen }
        if a.hasRaisedHand != b.hasRaisedHand { return a.hasRaisedHand }
        if a.hasRaisedHand, b.hasRaisedHand, a.raisedHandAt != b.raisedHandAt {
            return a.raisedHandAt < b.raisedHandAt
        }
        if a.isMuted != b.isMuted { return !a.isMuted }
        let nameA = a.displayName.isEmpty ? a.username : a.displayName
        let nameB = b.displayName.isEmpty ? b.username : b.displayName
        let folded = nameA.compare(nameB, options: [.caseInsensitive, .diacriticInsensitive])
        if folded != .orderedSame { return folded == .orderedAscending }
        return a.sessionID < b.sessionID
    }

    /// The name rule shared with `PostListDerivation`: nickname, then full name, then username.
    /// Duplicated here rather than imported because `PostListDerivation` is a post-list type and a
    /// call tile must not depend on the post list (and the rule is one line to keep in step).
    static func displayName(for user: MMUser) -> String {
        if !user.nickname.isEmpty { return user.nickname }
        let full = [user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " ")
        if !full.isEmpty { return full }
        return user.username
    }
}

// MARK: - Duration and labels

enum CallsDuration {

    /// `mm:ss` until an hour, then `h:mm:ss` — or `h:mm` when the caller truncates (`truncateWhenLong`,
    /// which is what the call header does).
    ///
    /// `startAtMilliseconds <= 0` means "no start time" (the plugin's `start_at` is absent until the
    /// call is up) and reads `00:00`; so does a start time in the future — the plugin's clock is the
    /// server's, and a skewed client can be behind it. Neither must render a negative or a
    /// 50-hour clock.
    static func format(startAtMilliseconds: Int64,
                       now: Date,
                       truncateWhenLong: Bool = false) -> String {
        guard startAtMilliseconds > 0 else { return "00:00" }
        let nowMillis = Int64((now.timeIntervalSince1970 * 1000).rounded())
        let totalSeconds = (nowMillis - startAtMilliseconds) / 1000
        guard totalSeconds > 0 else { return "00:00" }

        let seconds = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minutes = totalMinutes % 60
        let hours = totalMinutes / 60

        if hours > 0 && truncateWhenLong {
            return "\(hours):\(twoDigits(minutes))"
        }
        if hours > 0 {
            return "\(hours):\(twoDigits(minutes)):\(twoDigits(seconds))"
        }
        return "\(twoDigits(minutes)):\(twoDigits(seconds))"
    }

    /// `"12:04"`, `"1:02:09"`, `"2:05"` — the same strings the tests pin.
    static func twoDigits(_ value: Int64) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

// MARK: - Phase

/// What the call screen is telling the reader. One case per state the card names.
enum CallsSurfacePhase: Equatable, Sendable {
    /// Not started (the model exists, the engine has not been asked yet).
    case idle
    /// Mic asked/answered, `join` on the wire, waiting for the plugin.
    case joining
    /// Joined; the offer/answer is in flight (the client offers, so this is the normal second beat).
    case connecting
    /// ICE reported connected/completed: media can flow.
    case connected
    /// Was connected and the transport dropped — the engine renegotiates, the reader is told.
    case reconnecting
    /// The plugin ended the call, or the reader left.
    case ended
    /// The call could not be established.
    case failed(String)

    /// The one-line state the screen shows above the tiles.
    var statusText: String {
        switch self {
        case .idle: return "Not in a call"
        case .joining: return "Joining…"
        case .connecting: return "Connecting…"
        case .connected: return "In call"
        case .reconnecting: return "Reconnecting…"
        case .ended: return "Call ended"
        case .failed(let reason): return "Call failed: \(reason)"
        }
    }

    var isLive: Bool {
        switch self {
        case .connected, .reconnecting: return true
        default: return false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .ended, .failed: return true
        default: return false
        }
    }

    /// Map the engine's state machine onto the screen's.
    ///
    /// `wasConnected` and `connectionState` are what make **reconnecting** observable: the engine
    /// has no reconnecting case (it reports libwebrtc's `iceConnectionState`/`connectionState`
    /// strings and keeps its own state at `.connected`), so a drop is a `.connected` engine whose
    /// transport is `disconnected`/`failed`/`checking` after it had been up. Without that input a
    /// dropped call would keep reading "In call".
    static func derive(engine: CallsEngineState,
                       connectionState: String,
                       wasConnected: Bool) -> CallsSurfacePhase {
        switch engine {
        case .idle:
            return .idle
        case .requestingPermission, .joining:
            return .joining
        case .offering, .negotiating, .connecting:
            return .connecting
        case .permissionDenied:
            // Only reachable under `.requireMicrophone`; the surface states the refusal either way.
            return .failed("microphone access was refused")
        case .connected:
            let dropped = ["disconnected", "failed", "checking"].contains(connectionState.lowercased())
            if wasConnected && dropped { return .reconnecting }
            return .connected
        case .failed(let reason):
            return .failed(reason)
        case .ended:
            return .ended
        }
    }
}

// MARK: - Video (camera) capability

/// Whether this build can turn a camera on in a call.
///
/// **This card renders no camera control, deliberately, and this type is why** — it is the same
/// rule the card states for screen share ("the control must be absent, not present-and-inert"),
/// applied to the other control the card names:
///
///  * the plugin under test (0.29.8) has no `video_on`/`video_off` at all — `CallsPluginVersion
///    .supportsVideo` is false;
///  * the T44c engine never sends video and captures no camera (its own hand-off says "no video:
///    `video_on`/`video_off` modelled and version-gated but never sent; camera stays webview-only");
///  * the named reference implementation has no camera control either — `mattermost-mobile` v2.45.0's
///    `call_screen.tsx` does not mention video once (measured: `grep -c video` → 0).
///
/// So a camera button here would be a control that cannot do anything. The capability is modelled
/// (and unit-tested) so the day a video-capable engine lands, `CallsControlSet.showsCamera` flips
/// without this file changing. See `docs/t44d-build-note.md` §5.
enum CallsVideoCapability: Equatable, Sendable {
    case unsupported(reason: String)
    case supported

    var isSupported: Bool { self == .supported }

    /// The gate: BOTH the plugin build and this engine must be able to carry video.
    static func forBuild(plugin: CallsPluginVersion, engineCapturesVideo: Bool) -> CallsVideoCapability {
        guard engineCapturesVideo else {
            return .unsupported(reason: "this build has no camera capture path (T44c)")
        }
        guard plugin.supportsVideo else {
            return .unsupported(reason: "Calls plugin \(plugin) has no video_on/video_off")
        }
        return .supported
    }
}

// MARK: - Controls

/// What the control bar offers, derived once so the view has no decision of its own.
///
/// The rules, each of which a test pins:
///  * mute and raise-hand need a **live** call and a granted microphone — a denied mic must not
///    offer "Unmute" (upstream draws the button unavailable in exactly that case);
///  * leave is offered until the call is over, including while joining (a user who changes their
///    mind mid-join must be able to leave);
///  * the hand control exists on every plugin build (raise/unraise are in the 0.29.8 ∩ 1.x set);
///  * the camera control exists only when `CallsVideoCapability` says so — never inert;
///  * screen share is **not modelled here at all** (absent, not disabled): it needs the T44e
///    broadcast extension.
struct CallsControlSet: Equatable, Sendable {
    var canToggleMute: Bool
    var canToggleHand: Bool
    var canLeave: Bool
    var muteTitle: String
    var handTitle: String
    var showsCamera: Bool
    /// Why the camera control is absent, when it is — carried so the build note and any future
    /// diagnostics can state it instead of guessing.
    var cameraUnavailableReason: String?

    static func derive(phase: CallsSurfacePhase,
                       microphone: CallsMicrophonePermission,
                       isMuted: Bool,
                       hasRaisedHand: Bool,
                       video: CallsVideoCapability = .unsupported(reason: "no camera path")) -> CallsControlSet {
        let live = phase.isLive
        let canCapture = microphone.canCaptureAudio
        let camera: Bool
        var cameraReason: String?
        switch video {
        case .supported:
            camera = live
            if !live { cameraReason = "not in a call" }
        case .unsupported(let reason):
            camera = false
            cameraReason = reason
        }
        return CallsControlSet(canToggleMute: live && canCapture,
                               canToggleHand: live && canCapture,
                               canLeave: !phase.isTerminal,
                               muteTitle: isMuted ? "Unmute" : "Mute",
                               handTitle: hasRaisedHand ? "Lower hand" : "Raise hand",
                               showsCamera: camera,
                               cameraUnavailableReason: cameraReason)
    }
}

// MARK: - Microphone copy

extension CallsMicrophonePermission {
    /// What the reader is told when the grant is not `.granted`. A call can still be joined (the
    /// web client's behaviour) — the banner says the app is listening, not speaking.
    var noMicrophoneMessage: String? {
        switch self {
        case .granted: return nil
        case .denied: return "No microphone access — you can hear the call but not speak. "
            + "Allow the microphone in Settings to talk."
        case .restricted: return "Microphone access is restricted by this device's policy — "
            + "you can hear the call but not speak."
        case .undetermined: return "Microphone permission has not been answered — "
            + "you can hear the call but not speak."
        }
    }
}
