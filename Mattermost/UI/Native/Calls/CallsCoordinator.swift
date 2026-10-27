// T44d — the calls surface's owner, at app scope.
//
// Two jobs, both of which need to outlive a view:
//
//  1. **The join entry point.** "Is there a call in this channel?" is asked of the server
//     (`GET /plugins/com.mattermost.calls/calls/{id}/active`) — the only honest source, measured in
//     `docs/t44d-build-note.md` §3.2: the plugin's `call_start`/`call_end` frames are not delivered
//     to a plain authenticated member who has not loaded/`view`ed the channel, and this app does not
//     send the web client's `view`.
//  2. **The one live call.** A call is app-scoped, not pane-scoped: a rotation, a channel switch or
//     a sheet must not drop it. The model is owned here (like every other coordinator in
//     `MattermostApp`), and the pane only presents it.
//
// Neither job opens a socket. The transport is the rail's one `SocketClient` per server, handed over
// by `TeamSidebarCoordinator` (see `callsTransport(for:)`); the engine's `CallsSignallingPort` and the
// surface's `CallsEventBridge` are two *readers* of that one connection.

import Foundation
import Combine

@MainActor
final class CallsCoordinator: ObservableObject {

    /// Channels with an active call, per server — what the channel header's join button renders from.
    @Published private(set) var activeCallChannels: [UUID: Set<String>] = [:]

    /// The live call, if any. `nil` once it ends — the views observe the model directly.
    @Published private(set) var surface: CallsCallModel?

    /// Servers where Calls is not usable, with the reason (diagnostics + the Settings read-out later).
    @Published private(set) var unavailable: [UUID: String] = [:]

    /// Why the last join attempt failed, shown once by the entry point. `nil` when nothing failed.
    @Published private(set) var lastError: String?

    func clearError() { lastError = nil }

    private weak var auth: AuthCoordinator?
    private weak var serverStore: ServerStore?

    /// Seams. Production: `SessionCallsSurfaceService` over the session's client, the rail's socket,
    /// and a real `CallsEngine`. Tests: a fake for each, so the rules below are exercised with no
    /// server, no plugin, no WebRTC and no microphone.
    var serviceFactory: ((ServerConfig) -> CallsSurfaceServing)?
    var transportProvider: ((ServerConfig) async -> (any CallsSocketTransport)?)?
    var engineFactory: ((any CallsSocketTransport, CallsPluginVersion) -> any CallsEngineDriving)?

    private var pluginVersions: [UUID: CallsPluginVersion] = [:]
    /// Channels with a refresh in flight, so the 20 s poll and an appearance cannot stack requests.
    private var refreshingChannels: Set<String> = []

    /// Seam: which user is signed in on a server. Production reads `AuthCoordinator`; tests set this
    /// so the rules can be exercised without a session, a vault or a network.
    var userIDProvider: ((UUID) -> String?)?

    func bind(auth: AuthCoordinator?, serverStore: ServerStore?) {
        self.auth = auth
        self.serverStore = serverStore
    }

    // MARK: - Entry point

    func isCallActive(serverID: UUID, channelID: String) -> Bool {
        activeCallChannels[serverID]?.contains(channelID) ?? false
    }

    /// Whether the channel header should offer Calls at all.
    ///
    /// Unknown servers answer `true`: the first probe decides, and hiding the button until a probe
    /// has run would mean it never appears (nothing else asks). A server that answered `404` to the
    /// plugin route is remembered as unavailable and gets no button.
    func isCallsAvailable(serverID: UUID) -> Bool {
        unavailable[serverID] == nil
    }

    /// Ask the server whether this channel has a call, and publish the answer.
    ///
    /// Three outcomes are deliberately different:
    ///  * `true`/`false` — the server's answer, published;
    ///  * `404` — Calls is not installed (or not enabled) on this server: remembered, published as
    ///    "no call", and not retried on every pane appearance;
    ///  * any other failure — **keep the last known answer**. A blip must not hide a live call's
    ///    join button, and must not claim one exists.
    func refreshActiveCall(server: ServerConfig, channelID: String) async {
        guard !channelID.isEmpty else { return }
        guard signedInUserID(for: server.id) != nil else {
            setActive(false, serverID: server.id, channelID: channelID)
            return
        }
        guard unavailable[server.id] == nil else {
            setActive(false, serverID: server.id, channelID: channelID)
            return
        }
        let key = "\(server.id.uuidString)/\(channelID)"
        guard !refreshingChannels.contains(key) else { return }
        refreshingChannels.insert(key)
        defer { refreshingChannels.remove(key) }

        do {
            let active = try await service(for: server).isCallActive(channelID: channelID)
            setActive(active, serverID: server.id, channelID: channelID)
        } catch MMError.notFound {
            unavailable[server.id] = "Calls is not installed on this server"
            setActive(false, serverID: server.id, channelID: channelID)
        } catch {
            MMLog.debug("MMCalls", "active-call check failed for \(channelID): \(error)")
        }
    }

    /// The plugin build installed on a server, fetched once and remembered (the protocol gate).
    func pluginVersion(for server: ServerConfig) async throws -> CallsPluginVersion {
        if let cached = pluginVersions[server.id] { return cached }
        do {
            let version = try await service(for: server).pluginVersion()
            pluginVersions[server.id] = version
            return version
        } catch MMError.notFound {
            unavailable[server.id] = "Calls is not installed on this server"
            throw MMError.notFound
        }
    }

    // MARK: - The live call

    /// Join the call in `channelID`, publishing the model the call screen renders.
    ///
    /// Returns `nil` when the call cannot be started at all (no session, no socket, no plugin) — the
    /// caller's button then simply does nothing visible, and the reason is logged.
    func startCall(server: ServerConfig,
                   channelID: String,
                   channelName: String?) async -> CallsCallModel? {
        if let surface, !surface.phase.isTerminal {
            // One call at a time, like every VoIP client: a second join would put two sessions of
            // this account in the same call and make the mute control ambiguous.
            return surface.channelID == channelID ? surface : nil
        }
        guard let transport = await transportProvider?(server) else {
            MMLog.error("MMCalls", "no socket for \(server.url) — cannot join a call")
            lastError = "Not connected — the app has no live connection to this server."
            return nil
        }
        let version: CallsPluginVersion
        do {
            version = try await pluginVersion(for: server)
        } catch {
            MMLog.error("MMCalls", "cannot join: \(error)")
            lastError = "This server has no working Mattermost Calls plugin."
            return nil
        }
        let engine = engineFactory?(transport, version)
            ?? CallsEngine(signalling: CallsSignallingPort(socket: transport, version: version),
                           policy: .joinWithoutMicrophone)
        let model = CallsCallModel(server: server,
                                   channelID: channelID,
                                   channelName: channelName,
                                   myUserID: signedInUserID(for: server.id) ?? "",
                                   engine: engine,
                                   service: service(for: server),
                                   events: await CallsEventBridge.stream(from: transport),
                                   video: CallsVideoCapability.forBuild(plugin: version,
                                                                       engineCapturesVideo: CallsEngine.capturesVideo))
        model.onEnded = { [weak self] in
            if self?.surface?.id == model.id { self?.surface = nil }
        }
        surface = model
        await model.start()
        // A call is certainly active in this channel now: the join button must not stay hidden after
        // the reader leaves and returns.
        setActive(true, serverID: server.id, channelID: channelID)
        return model
    }

    /// Leave whatever call is live (sign-out, server removal, an explicit close).
    func endCall() async {
        guard let surface else { return }
        self.surface = nil
        await surface.leave()
    }

    // MARK: - Socket

    /// One event from one server's socket (the rail routes plugin frames here).
    ///
    /// Only the two frames that change "is there a call in this channel" are used. Everything a
    /// live call renders arrives on the model's own subscription.
    func handle(_ event: SocketEvent, serverID: UUID) {
        guard case .plugin(let name, let data) = event,
              let calls = CallsEvent(name: name, data: data) else { return }
        switch calls {
        case .callState(let channelID, _):
            guard !channelID.isEmpty else { return }
            setActive(true, serverID: serverID, channelID: channelID)
        case .callEnded(let channelID):
            guard !channelID.isEmpty else { return }
            setActive(false, serverID: serverID, channelID: channelID)
        case .callStarted, .signal, .joinAck, .userJoined, .userLeft, .muteChanged,
             .voiceChanged, .handChanged, .screenShareChanged, .hostChanged, .error, .unhandled:
            break
        }
    }

    /// A sign-out/expiry/server removal drops the call and every remembered fact about that server.
    ///
    /// The bookkeeping is synchronous (a header must stop offering a call the instant the session is
    /// gone); only the engine teardown is awaited.
    func authPhaseChanged(_ serverID: UUID) {
        let live = surface?.server.id == serverID ? surface : nil
        if live != nil { surface = nil }
        activeCallChannels[serverID] = nil
        pluginVersions[serverID] = nil
        unavailable[serverID] = nil
        if let live { Task { await live.leave() } }
    }

    // MARK: - Internals

    /// The signed-in user for a server: the test seam when set, otherwise the auth coordinator.
    private func signedInUserID(for serverID: UUID) -> String? {
        if let userIDProvider { return userIDProvider(serverID) }
        return auth?.userID(for: serverID)
    }

    private func service(for server: ServerConfig) -> CallsSurfaceServing {
        if let serviceFactory { return serviceFactory(server) }
        let auth = self.auth
        return SessionCallsSurfaceService {
            guard let auth, let session = try? auth.session(for: server) else { return nil }
            return session.client
        }
    }

    private func setActive(_ active: Bool, serverID: UUID, channelID: String) {
        var channels = activeCallChannels[serverID] ?? []
        let was = channels.contains(channelID)
        guard was != active else { return }
        if active { channels.insert(channelID) } else { channels.remove(channelID) }
        activeCallChannels[serverID] = channels
    }
}
