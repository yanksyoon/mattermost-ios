// Behaviour reference: mattermost-plugin-calls' REST surface as *measured* on the fixture
// (Calls 0.29.8, build 936dd00) with `scripts/t44d_probe_rest.py` — not from the plugin's source:
//   GET /plugins/com.mattermost.calls/version               -> {"build": "936dd00…", "version": "0.29.8"}
//   GET /plugins/com.mattermost.calls/calls/{id}/active     -> {"active": true|false}
//   GET /plugins/com.mattermost.calls/calls/{id}            -> 404 (does not exist on 0.29.8)
//   GET /plugins/com.mattermost.calls/config                -> {"DefaultEnabled": false, …}
// Record: docs/t44d-build-note.md §2. The routes are at the server root, not under /api/v4.
//
// T44d owns exactly two facts from the plugin over REST: whether a call is active in a channel
// (the join-call entry point's source of truth) and which plugin build is installed (the version
// gate the protocol already needs). Everything else about a live call comes from the socket.

import Foundation

extension APIClient {

    /// `GET /plugins/com.mattermost.calls/version`.
    ///
    /// Throws `MMError.notFound` when the plugin is not installed (the route 404s), which the
    /// surface treats as "Calls is not available on this server" rather than as an error.
    func callsPluginVersion() async throws -> CallsPluginVersion {
        struct Payload: Decodable {
            let version: String
            let build: String?
        }
        let payload = try await getPlugin(Payload.self, path: "/plugins/com.mattermost.calls/version")
        guard let version = CallsPluginVersion(string: payload.version) else {
            throw MMError.malformedResponse("Calls plugin version \(payload.version) is not semantic")
        }
        return version
    }

    /// `GET /plugins/com.mattermost.calls/calls/{channel_id}/active` — `{"active": bool}`.
    ///
    /// This is the entry point's only honest source: the plugin's `call_start`/`call_end` frames are
    /// broadcast to participants and to clients that have that channel *loaded*, and this app does
    /// not send the web client's channel `view` (measured: a plain authenticated member's socket
    /// receives nothing when a call starts — docs/t44d-build-note.md §2).
    func callsCallIsActive(channelID: String) async throws -> Bool {
        struct Payload: Decodable { let active: Bool }
        let payload = try await getPlugin(Payload.self,
                                          path: "/plugins/com.mattermost.calls/calls/\(channelID)/active")
        return payload.active
    }
}
