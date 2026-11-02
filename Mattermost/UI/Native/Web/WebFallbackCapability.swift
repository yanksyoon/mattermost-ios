// T46-R — "is this surface actually served here?" (`docs/dual-render.md` §13.6, R1).
//
// The escape hatch offers Boards and Playbooks on every server, but both are **product plugins**:
// `/boards` and `/playbooks` are answered by the web app's HTML shell whether or not the bundle
// that paints them is installed. Measured on a 9.11.19 Team Edition fixture with no focalboard
// plugin: the Boards row painted the "Preview Mode" banner and 61 characters of nothing
// (`docs/t46-av-verdict.md` §F1, `docs/t46-av-shots/t46av-boards-blank.png`).
//
// The server will say which plugins it serves, and it says it in one request that needs no extra
// privilege beyond the reader's own session:
//
//     GET /api/v4/plugins/webapp
//     [{"id":"playbooks", …, "webapp":{"bundle_path":"/static/playbooks/…js"}}, …]
//
// Only the ids matter here. This file is the request and nothing else: the decision (what to do
// with the answer) lives in `WebFallbackModel.availability`, where it is unit-tested against a
// fake listing instead of a network.

import Foundation

/// The plugin ids a server serves to the web app, or `nil` when the server could not be asked.
struct WebFallbackPluginListing {

    /// The shape this file needs from the endpoint's answer (it returns much more; unknown keys
    /// are ignored, so a newer server is not a decode failure).
    private struct Entry: Decodable {
        let id: String
    }

    /// Ask `GET /api/v4/plugins/webapp` for the ids of the plugins whose webapp bundle the server
    /// will serve.
    ///
    /// - Returns: the ids, or `nil` when the question could not be answered — no network, a
    ///   non-2xx answer (a 401 on a session the shell has not installed yet, a 404 on a server
    ///   that does not expose the route), or a body that is not a plugin list.
    ///
    /// `nil` is deliberately **not** "the server serves nothing". The two are different decisions
    /// for a reader: "Boards is not enabled on this server" is a statement of fact, while "the
    /// shell could not ask" is an admission, and the fallback keeps the old behaviour in that case
    /// (load the route and let the page speak) rather than claiming a product is missing.
    ///
    /// The bearer token is the shell's own (`SecureVault`), sent as Mattermost's REST auth header.
    /// The endpoint answers without auth on the fixtures measured here, but a server that requires
    /// a session must get the reader's, or the fallback would be asked about a server it is
    /// signed in to and answer "unknown" every time.
    static func pluginIDs(for server: ServerConfig,
                          token: String?,
                          session: URLSession = .shared) async -> Set<String>? {
        guard let url = MMBaseURL(server.url)?.apiV4("plugins/webapp") else { return nil }
        var request = URLRequest(url: url)
        // Short: this gate decides whether a sheet opens at all, and it is not worth a spinner
        // that outlives the reader's patience. Ten seconds is longer than any local or LAN
        // Mattermost needs for a plugin list and short enough to report a dead server as dead.
        request.timeoutInterval = 10
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            let entries = try JSONDecoder().decode([Entry].self, from: data)
            return Set(entries.map(\.id))
        } catch {
            return nil
        }
    }
}
