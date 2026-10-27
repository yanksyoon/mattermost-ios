// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0,
// `ios/Gekidou/Sources/Gekidou/Networking/Network.swift` (`buildApiUrl`: `serverUrl + "/api/v4" +
// endpoint`) and `app/client/websocket/index.ts` (the https→wss rewrite plus
// `/api/v4/websocket`). Own implementation per docs/path-b-adr.md §3 — the upstream helper is
// string concatenation, which silently breaks on a server deployed under a sub-path and on a
// trailing slash. This repo's `ServerURL.normalize` keeps sub-paths, so the join has to be real.

import Foundation

/// Per-server base URL resolution for the native transport.
///
/// Mattermost can be served from a sub-path (`https://host/company/mattermost`) as well as from a
/// root origin. Every native call must therefore be `serverBasePath + /api/v4 + endpoint`, and the
/// WebSocket the same with the `wss` scheme. A naive `URL(string: serverURL + "/api/v4" + path)`
/// double-slashes or drops the sub-path; this type joins components once and is unit-tested for
/// root, sub-path, explicit port, and `http` (self-hosted dev) servers.
struct MMBaseURL: Equatable, Sendable {
    /// The configured server URL, as stored by `ServerStore` (no trailing slash).
    let serverURL: URL

    /// Normalized copy of the server's path (`""` for a root install, `/company/mm` for a
    /// sub-path install).
    let basePath: String

    init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty,
              let host = url.host, !host.isEmpty else {
            return nil
        }
        var path = url.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path == "/" { path = "" }
        self.serverURL = url
        self.basePath = path
    }

    /// `https://host[:port][base]/api/v4/<path>?<query>`.
    func apiV4(_ path: String, query: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = serverURL.scheme?.lowercased()
        components.host = serverURL.host
        components.port = serverURL.port
        var fullPath = basePath + "/api/v4"
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if !trimmed.isEmpty { fullPath += "/" + trimmed }
        components.path = fullPath
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }

    /// `https://host[:port][base]/<path>` — a server path **outside** `/api/v4`.
    ///
    /// Plugin REST routes live at `/plugins/<plugin id>/…`, not under `/api/v4` (measured: Calls
    /// 0.29.8 answers `GET /plugins/com.mattermost.calls/version` and 404s the same path under
    /// `/api/v4`). Same base-path join as `apiV4`, so a server deployed under a sub-path works.
    func absolute(_ path: String) -> URL? {
        var components = URLComponents()
        components.scheme = serverURL.scheme?.lowercased()
        components.host = serverURL.host
        components.port = serverURL.port
        var fullPath = basePath
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if !trimmed.isEmpty { fullPath += "/" + trimmed }
        components.path = fullPath
        return components.url
    }

    /// The WebSocket v4 endpoint for this server: `ws(s)://host[:port][base]/api/v4/websocket`.
    ///
    /// `reliable` adds the `connection_id` / `sequence_number` query parameters the server's
    /// reliable-WebSocket feature uses to replay what a client missed while disconnected
    /// (mobile `app/client/websocket/index.ts` lines 120-124).
    func websocket(connectionID: String? = nil, sequenceNumber: Int? = nil) -> URL? {
        guard let apiURL = apiV4("/websocket"),
              var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: return nil
        }
        var query = components.queryItems ?? []
        if let connectionID, !connectionID.isEmpty {
            query.append(URLQueryItem(name: "connection_id", value: connectionID))
            query.append(URLQueryItem(name: "sequence_number", value: String(sequenceNumber ?? 0)))
        }
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }

    /// The `Origin` header value the server checks on the WebSocket handshake.
    var origin: String {
        var components = URLComponents()
        components.scheme = serverURL.scheme?.lowercased()
        components.host = serverURL.host
        if let port = serverURL.port { components.port = port }
        return components.string ?? serverURL.absoluteString
    }
}
