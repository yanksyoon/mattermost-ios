// Behaviour reference: mattermost/desktop `src/main/notifications/index.ts` (one NotificationManager,
// every renderer `NOTIFY_MENTION` funnels into it) and mattermost/mattermost-mobile @ v2.45.0
// `app/notifications/index.ts` (the client decides locally whether a post is a notification, from the
// post, the channel and the reader's own notify props). Licence: Apache-2.0 / observed behaviour — the
// arbitration below is this repo's own; no upstream source was copied.
//
// T43's whole contribution is an **input**, not an output: `NotificationWorker` stays the one
// scheduler, and `SessionStore` stays the one badge arithmetic. What changes is *who tells the shell a
// mention happened*. Two inputs can say it:
//
//   - `bridge`  — the web app's `notify_mention` frame (Path A, today's only input, T8);
//   - `socket`  — the server's own `posted` WebSocket frame (Path B, the native data path).
//
// Both must never fire for the same mention. That rule lives here, in one value type that both inputs
// ask, so the answer cannot fork between them — the same shape `SurfaceModeResolver` gives the
// dual-render switch.

import Foundation
import Combine

/// Which input tells the shell that a mention happened.
enum NotificationInputMode: String, CaseIterable, Codable, Sendable {
    /// Path A: the server's web app reports `notify_mention` over the bridge (the shipped T8 input).
    case bridge
    /// Path B: the socket's `posted` event is the shell's own input (T43's native data path).
    case socket

    /// The word the Settings read-out and the logs use.
    var label: String {
        switch self {
        case .bridge: return "Web view bridge"
        case .socket: return "Native socket"
        }
    }

    /// What the `-notificationPath` launch argument may spell. `web`/`native` are accepted as the
    /// dual-render vocabulary the rest of the app speaks, so one flag name is not a separate dialect.
    static func parse(_ token: String) -> NotificationInputMode? {
        switch token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "bridge", "web": return .bridge
        case "socket", "native": return .socket
        default: return nil
        }
    }
}

/// The arbitration between the two mention inputs: **exactly one source per server at any moment**.
///
/// - `.bridge` (the compile-time default until `T43-AV` approves the flip): the web app is the input,
///   exactly as today, and the socket path delivers nothing. No behaviour changed.
/// - `.socket`: the server's socket is the input. While that server's pump is live the bridge is
///   **refused** — that refusal is what makes a dual-render run produce one banner instead of two.
///   The bridge is still accepted for a server whose socket is not up (signed out, no token yet, a
///   reconnect gap), because a hole in coverage is a worse failure than a fallback: the alternative is
///   a mention nobody hears.
struct NotificationInputGate: Equatable {
    var mode: NotificationInputMode = .bridge
    /// Servers whose socket pump is running *right now*. The rail is the only writer
    /// (`TeamSidebarCoordinator`), from the pump's own lifetime.
    var socketLive: Set<UUID> = []

    /// Whether the socket input may deliver for this server.
    func acceptsSocket(serverID: UUID) -> Bool {
        // The socket only produces events while its pump is live, so liveness is not re-tested here —
        // a scripted event in a test is a legitimate socket input.
        mode == .socket
    }

    /// Whether a `notify_mention` frame from this server's webview may deliver.
    func acceptsBridge(serverID: UUID) -> Bool {
        mode == .bridge || !socketLive.contains(serverID)
    }

    /// Why a `notify_mention` frame was refused, for the log line and the Settings read-out. `nil`
    /// when the frame would be accepted.
    func bridgeRefusalReason(serverID: UUID) -> String? {
        guard !acceptsBridge(serverID: serverID) else { return nil }
        return "the native socket is this server's live mention input"
    }
}

/// The app-wide arbitration state: the mode, the per-server socket liveness, and the counters a human
/// can read back in Settings. One instance (`shared`) is what the shell wires; tests build their own.
///
/// Observable because the Settings read-out and the diagnostics row are views over it — the same
/// reason `SessionStore` is one.
@MainActor
final class NotificationInputRouting: ObservableObject {

    /// The shell's instance. The rail publishes socket liveness here, the feed publishes what it did,
    /// and the webview asks `acceptsBridge` before it delivers.
    static let shared = NotificationInputRouting()

    @Published private(set) var gate = NotificationInputGate()

    // Read-outs. Deliberately plain counters, not a log: the Settings section shows the *current*
    // path and the last few facts, and a counter that never resets is the honest way to say
    // "the bridge has delivered nothing since launch".
    @Published private(set) var bridgeAccepted = 0
    @Published private(set) var bridgeRefused = 0
    @Published private(set) var socketPostsSeen = 0
    @Published private(set) var socketMentions = 0
    @Published private(set) var socketDelivered = 0
    @Published private(set) var socketDropped = 0
    @Published private(set) var lastDropReason: String?

    var mode: NotificationInputMode { gate.mode }
    var liveSocketCount: Int { gate.socketLive.count }

    /// Adopt `mode`, keeping the liveness the rail already reported (a switch at runtime must not
    /// forget which sockets are up, or the bridge would be refused for the wrong reason).
    func setMode(_ mode: NotificationInputMode) {
        guard gate.mode != mode else { return }
        gate.mode = mode
        Logger.info("NotificationInput", "mention input -> \(mode.label)")
    }

    func socketStateChanged(serverID: UUID, live: Bool) {
        if live {
            gate.socketLive.insert(serverID)
        } else {
            gate.socketLive.remove(serverID)
        }
    }

    /// Whether a bridge frame may deliver for this server. Counts the decision so the Settings
    /// read-out can show that the web path produced **zero** while the socket was the input.
    func acceptsBridge(serverID: UUID) -> Bool {
        let accepted = gate.acceptsBridge(serverID: serverID)
        if accepted {
            bridgeAccepted += 1
        } else {
            bridgeRefused += 1
            Logger.debug("NotificationInput", "notify_mention refused: \(gate.bridgeRefusalReason(serverID: serverID) ?? "")")
        }
        return accepted
    }

    func noteSocketPost(isMention: Bool) {
        socketPostsSeen += 1
        if isMention { socketMentions += 1 }
    }

    func noteSocketDelivery(delivered: Bool, reason: String?) {
        if delivered {
            socketDelivered += 1
        } else {
            socketDropped += 1
        }
        if let reason { lastDropReason = reason }
    }
}
