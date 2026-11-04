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
//   - `bridge`  — the web app's `notify_mention` frame (Path A, T8);
//   - `socket`  — the server's own `posted` WebSocket frame (Path B, the native data path).
//
// Both must never fire for the same mention. That rule lives here, in one value type that both inputs
// ask, so the answer cannot fork between them — the same shape `SurfaceModeResolver` gives the
// dual-render switch.
//
// **Which input a server uses is measured, not configured** (`NotificationInputGate.mode(for:)`): a
// mounted webview makes the page that server's input, a native pane makes the socket it. This card
// (t_ba355551) replaced the process-wide `.bridge` constant that used to answer that question in a
// Release build: it shipped a binary where no web pane existed (the native workspace) and the socket
// was refused by the same constant, so a real message produced nothing while the Settings test button
// still worked. The launch/persisted tiers in `NotificationPathStore` remain as a **debug override**
// (they exist only in DEBUG/PERF_PROBE builds), never as the shipped answer.

import Foundation
import Combine

/// Which input tells the shell that a mention happened.
enum NotificationInputMode: String, CaseIterable, Codable, Sendable {
    /// Path A: the server's web app reports `notify_mention` over the bridge. Derived for a server
    /// while its pane is the web app (the page is the only side that can see the channel on screen).
    case bridge
    /// Path B: the socket's `posted` event is the shell's own input. Derived for a server whose pane
    /// is native — the shipped workspace render.
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
/// - `mode(for:)` is the only place a server's live input is decided. With no override it is a
///   **measurement of the mounted pane**: a web pane means the page is the input (it is the only side
///   that knows which channel the reader is looking at), a native pane means the socket is.
/// - `overrideMode` forces the answer for every server. It is a **debug affordance only** — the
///   `-notificationPath` launch flag or `NotificationPathStore`'s persisted row, neither of which a
///   Release build reads.
/// - Once a server's input is the socket, the bridge is **refused while that server's socket pump is
///   live** — that refusal is what makes a dual-render run produce one banner instead of two. The
///   bridge is still accepted for a server whose socket is not up (signed out, no token yet, a
///   reconnect gap), because a hole in coverage is a worse failure than a fallback: the alternative is
///   a mention nobody hears.
struct NotificationInputGate: Equatable {
    /// The forced input, or `nil` for the shipped behaviour (derived from the pane that is rendering).
    var overrideMode: NotificationInputMode? = nil
    /// Servers whose socket pump is running *right now*. The rail is the only writer
    /// (`TeamSidebarCoordinator`), from the pump's own lifetime.
    var socketLive: Set<UUID> = []
    /// Servers whose pane is **the web app right now** (`WebViewContainer` reports mount/unmount).
    ///
    /// This is the dual-render answer, and it is a measurement, not a preference: while the web app
    /// is drawing the pane, *the page* is the only party that knows which channel the reader is
    /// looking at — the native shell cannot see inside it (`visibleChannel` answers `.unknown`, and a
    /// server-wide suppression there silently swallowed every mention: measured, `delivered=0
    /// suppressed=1` with the webview mounted). So a mounted webview makes the page the input and the
    /// socket stays silent, which is exactly the pre-T43 behaviour and cannot double-fire. The native
    /// socket takes over the moment the pane is native, which is when Path B actually renders.
    var webPane: Set<UUID> = []

    /// The one place a server's live input is decided.
    ///
    /// A native pane has no page to report a mention, so the socket is the input; a web pane is the
    /// only side that can see the channel on screen, so the page is. A debug override (if one is in
    /// force) wins over both.
    func mode(for serverID: UUID) -> NotificationInputMode {
        if let overrideMode { return overrideMode }
        return webPane.contains(serverID) ? .bridge : .socket
    }

    /// Whether the socket input may deliver for this server.
    func acceptsSocket(serverID: UUID) -> Bool {
        // Liveness is not re-tested: the socket only produces events while its pump is live, so a
        // scripted event in a test is a legitimate socket input. A mounted web pane still silences it
        // even under a forced `.socket` override — the page is the only witness of what is on screen.
        mode(for: serverID) == .socket && !webPane.contains(serverID)
    }

    /// Whether a `notify_mention` frame from this server's webview may deliver.
    func acceptsBridge(serverID: UUID) -> Bool {
        !(mode(for: serverID) == .socket && !webPane.contains(serverID) && socketLive.contains(serverID))
    }

    /// Why a `notify_mention` frame was refused, for the log line and the Settings read-out. `nil`
    /// when the frame would be accepted.
    func bridgeRefusalReason(serverID: UUID) -> String? {
        guard !acceptsBridge(serverID: serverID) else { return nil }
        return "the native socket is this server's live mention input"
    }
}

/// The app-wide arbitration state: the forced override (if any), the per-server socket liveness and web
/// pane sets, and the counters a human can read back in Settings. One instance (`shared`) is what the
/// shell wires; tests build their own.
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

    /// The last input logged per server, so the mode line is emitted when the answer changes rather
    /// than once per post in a busy channel.
    private var loggedMode: [UUID: NotificationInputMode] = [:]

    /// The forced input in force, if any (debug builds only — see `setOverride`).
    var overrideMode: NotificationInputMode? { gate.overrideMode }

    /// The mode one server is using right now.
    func mode(for serverID: UUID) -> NotificationInputMode { gate.mode(for: serverID) }

    var liveSocketCount: Int { gate.socketLive.count }
    var webPaneCount: Int { gate.webPane.count }

    /// What the Settings read-out names: the one input in force across the servers that have reported
    /// a pane or a socket. Two servers can legitimately differ (one web pane, one native), and then the
    /// row says "Per server" instead of picking one and lying about the other.
    var liveModeLabel: String {
        let modes = Set(gate.webPane.union(gate.socketLive).map { gate.mode(for: $0) })
        switch modes.count {
        case 0: return (gate.overrideMode ?? .socket).label
        case 1: return modes.first!.label
        default: return "Per server"
        }
    }

    // MARK: - Adopting state

    /// Adopt the debug override (`nil` clears it), keeping the liveness the rail already reported — a
    /// switch at runtime must not forget which sockets are up, or the bridge would be refused for the
    /// wrong reason.
    ///
    /// A Release build **refuses to force**: the shipped input follows the pane, and no launch flag or
    /// stored row can ask for anything else (`NotificationPathStore` never yields one there).
    ///
    /// `debugAffordances` is a test seam in the shape of `NotificationPathStore.releaseSemantics`: the
    /// shipped default is this build's own flag, and a Release binary has no initialiser that could pass
    /// `true`.
    func setOverride(_ mode: NotificationInputMode?) {
        setOverride(mode, debugAffordances: NotificationPathStore.debugAffordancesEnabled)
    }

    /// The seam itself, for the test that asks the question a Release binary answers.
    func setOverride(_ mode: NotificationInputMode?, debugAffordances: Bool) {
        guard debugAffordances || mode == nil else {
            Logger.error("NotificationInput",
                         "refused to force the mention input on \(mode!.label): this build derives it "
                         + "from the mounted pane")
            return
        }
        applyOverride(mode)
    }

    private func applyOverride(_ mode: NotificationInputMode?) {
        guard gate.overrideMode != mode else { return }
        gate.overrideMode = mode
        if let mode {
            Logger.info("NotificationInput", "mention input forced -> \(mode.label)")
        } else {
            Logger.info("NotificationInput",
                        "mention input override cleared -> derived from the mounted pane")
        }
        // The edge-triggered per-server lines must be re-emitted under the new answer.
        loggedMode.removeAll()
    }

    func socketStateChanged(serverID: UUID, live: Bool) {
        if live {
            gate.socketLive.insert(serverID)
        } else {
            gate.socketLive.remove(serverID)
        }
    }

    /// The webview pane for `serverID` mounted (`isWeb == true`) or went away. A mounted page is the
    /// input for that server: it is the only input that knows which channel the reader is looking at.
    func paneKindChanged(serverID: UUID, isWeb: Bool) {
        let changed = isWeb ? gate.webPane.insert(serverID).inserted
                            : gate.webPane.remove(serverID) != nil
        guard changed else { return }
        logInputInForce(serverID: serverID)
    }

    /// Say, once per change, which input this process is using for a server. Called from the paths
    /// that act on the decision (the socket before it delivers, the webview before it reports), so the
    /// line always has a witness — a launch-time line would be a guess about what mounts later.
    @discardableResult
    func logInputInForce(serverID: UUID) -> NotificationInputMode {
        let mode = gate.mode(for: serverID)
        guard loggedMode[serverID] != mode else { return mode }
        loggedMode[serverID] = mode
        let why: String
        if gate.overrideMode != nil {
            why = "forced by the -notificationPath override"
        } else if gate.webPane.contains(serverID) {
            why = "derived: a web view is drawing this server's pane"
        } else {
            why = "derived: this server's pane is native, so the socket reports mentions"
        }
        Logger.info("NotificationInput",
                    "mention input for \(serverID.uuidString.prefix(8)) -> \(mode.label) (\(why))")
        return mode
    }

    /// The socket input's decision for a server, with the resolved input named in the log first: this
    /// is the line a diagnostics pull quotes, and it must exist even for a refusal.
    func acceptsSocket(serverID: UUID) -> Bool {
        logInputInForce(serverID: serverID)
        return gate.acceptsSocket(serverID: serverID)
    }

    /// Whether a bridge frame may deliver for this server. Counts the decision so the Settings
    /// read-out can show that the web path produced **zero** while the socket was the input.
    func acceptsBridge(serverID: UUID) -> Bool {
        logInputInForce(serverID: serverID)
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
