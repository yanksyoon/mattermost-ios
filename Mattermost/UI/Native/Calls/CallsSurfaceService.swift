// T44d — the calls surface's data seam.
//
// Same split every other screen card in this repo uses (`ChannelServing` T34, `SearchServing` T39,
// `ActivityServing` T42): a protocol the coordinator is written against, and one shipping
// implementation that is the only thing which knows about `AuthSession`/`APIClient`. The rules this
// card is judged on — whether the join button appears, what a tile says, what a control does — are
// model-level and drive a fake in the unit suite.

import Foundation

/// What the Calls surface needs from one server.
@MainActor
protocol CallsSurfaceServing: AnyObject {
    /// `GET /plugins/com.mattermost.calls/version` — the protocol gate (0.29.8 vs 1.x).
    func pluginVersion() async throws -> CallsPluginVersion
    /// `GET /plugins/com.mattermost.calls/calls/{id}/active` — is there a call to join here?
    func isCallActive(channelID: String) async throws -> Bool
    /// `POST /users/ids` — the participants' names, in one request.
    func users(ids: [String]) async throws -> [MMUser]
}

extension CallsSurfaceServing {
    /// A service that cannot resolve profiles still renders: tiles fall back to the user id.
    func users(ids: [String]) async throws -> [MMUser] { [] }
}

/// The production implementation: the session's own client, resolved **per call** so a service
/// built before the session restored is not permanently signed out (the note every other
/// `Session…Service` carries).
@MainActor
final class SessionCallsSurfaceService: CallsSurfaceServing {
    private let resolve: () -> APIClient?

    init(resolve: @escaping () -> APIClient?) {
        self.resolve = resolve
    }

    private func client() throws -> APIClient {
        guard let client = resolve() else { throw MMError.notSignedIn }
        return client
    }

    func pluginVersion() async throws -> CallsPluginVersion {
        try await client().callsPluginVersion()
    }

    func isCallActive(channelID: String) async throws -> Bool {
        try await client().callsCallIsActive(channelID: channelID)
    }

    func users(ids: [String]) async throws -> [MMUser] {
        guard !ids.isEmpty else { return [] }
        return try await client().users(ids: ids)
    }
}

// MARK: - Socket → typed Calls events

/// Turns the server's one WebSocket into a stream of typed Calls events.
///
/// The engine already consumes a `CallsSignallingPort` stream, and that port's `events` stream is
/// documented as one-consumer. The surface needs the same frames for a different job — the
/// participant deltas (`user_muted`, `user_raise_hand`, `user_voice_on`, `user_joined`) that the
/// engine deliberately does not model, because only a UI renders them. `SocketClient.subscribe()`
/// supports several subscribers on the one connection, so this bridge adds a second *reader* to the
/// same socket and never a second socket.
///
/// `connID` filtering is **not** this bridge's job: it only ever needs the call-level events, which
/// are broadcast to the channel's participants rather than addressed to one connection. Signals
/// (`answer`/`offer`/`candidate`) are dropped here — they belong to the engine's port.
enum CallsEventBridge {

    /// Decode plugin frames into Calls events, keeping only the call-level ones.
    static func stream(from transport: any CallsSocketTransport) async -> AsyncStream<CallsEvent> {
        let raw = await transport.subscribe()
        let (stream, continuation) = AsyncStream.makeStream(of: CallsEvent.self,
                                                            bufferingPolicy: .bufferingNewest(256))
        Task {
            for await event in raw {
                guard case .plugin(let name, let data) = event,
                      let calls = CallsEvent(name: name, data: data) else { continue }
                switch calls {
                case .signal, .joinAck, .unhandled:
                    // Signalling belongs to the engine's port (which owns the connID filter), and an
                    // unmodelled frame is not something a tile can draw.
                    continue
                default:
                    continuation.yield(calls)
                }
            }
            continuation.finish()
        }
        return stream
    }
}
