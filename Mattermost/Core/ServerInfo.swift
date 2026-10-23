import Foundation

/// Native counterpart of desktop `src/main/server/serverInfo.ts` (`ServerInfo` class).
/// Probes a Mattermost server's public `/api/v4` endpoints over `URLSession`:
/// - `pingServer()`     -> GET `/api/v4/system/ping`  (liveness; the add-server form's first check)
/// - `fetchConfigData()` -> GET `/api/v4/config/client?format=old` (the "name probe": site name,
///   site URL, server version used to prefill the display name and to validate the URL)
///
/// Parity row: `serverInfo`/`serverAPI` (`src/main/server/serverInfo.ts`) -> `ServerInfo` +
/// `ServerAPI` (URLSession + Swift Codable). Status: native, P1.
struct ServerInfo {
    let baseURL: URL
    let api: ServerAPI

    init(baseURL: URL, api: ServerAPI = ServerAPI()) {
        self.baseURL = baseURL
        self.api = api
    }

    /// `{server.url}/api/v4/system/ping`. Desktop does not parse the body — just confirms the
    /// endpoint responds (throws on a transport error or a non-200 status).
    func pingServer() async throws {
        let url = baseURL.appendingPathComponent("api/v4/system/ping")
        let response = try await probe(url)
        try Self.throwIfNotOK(response, url: url)
    }

    /// `{server.url}/api/v4/config/client?format=old`. Returns the name/version/site probe the
    /// add-server form uses to validate a URL before saving. Mirrors desktop `fetchConfigData`.
    func fetchConfigData() async throws -> RemoteInfo {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v4/config/client"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "format", value: "old")]
        guard let url = components?.url else {
            throw ServerProbeError.malformedURL
        }

        let response = try await probe(url)
        try Self.throwIfNotOK(response, url: url)
        guard let config = try? JSONDecoder().decode(ClientConfig.self, from: Data(response.body.utf8)) else {
            throw ServerProbeError.notMattermost
        }
        return RemoteInfo(config: config)
    }

    /// Perform a probe GET, mapping transport-level failures onto the desktop error-reason hints.
    private func probe(_ url: URL) async throws -> ServerAPI.Response {
        do {
            return try await api.get(url: url)
        } catch ServerAPI.APIError.clientCertRequired {
            throw ServerProbeError.needsClientCert
        } catch let ServerAPI.APIError.transport(message) {
            throw ServerProbeError.transport(message)
        } catch {
            throw ServerProbeError.transport(error.localizedDescription)
        }
    }

    /// Map a transport failure or a non-200 response onto a `ServerProbeError` that preserves the
    /// desktop error-reason hints (pre-auth / basic-auth / client-cert).
    private static func throwIfNotOK(_ response: ServerAPI.Response, url: URL) throws {
        guard response.statusCode == 200 else {
            if response.errorReason.needsPreAuth { throw ServerProbeError.needsPreAuth }
            if response.errorReason.needsBasicAuth { throw ServerProbeError.needsBasicAuth }
            throw ServerProbeError.badStatus(url, response.statusCode)
        }
    }
}

/// Errors surfaced by the server-info probes, carrying enough context for the URL validator to
/// map onto the desktop `URLValidationStatus` states (pre-auth, basic-auth, client-cert).
enum ServerProbeError: Error, Equatable {
    case malformedURL
    case badStatus(URL, Int)
    case notMattermost
    case needsPreAuth
    case needsBasicAuth
    case needsClientCert
    case transport(String)
}

/// Decodable shape of `GET /api/v4/config/client?format=old`. The `?format=old` payload uses the
/// legacy capitalized keys (mirrors desktop `ClientConfig` in `types/server.ts`).
struct ClientConfig: Decodable {
    let version: String
    let siteURL: String
    let siteName: String
    let helpLink: String
    let reportAProblemLink: String

    enum CodingKeys: String, CodingKey {
        case version = "Version"
        case siteURL = "SiteURL"
        case siteName = "SiteName"
        case helpLink = "HelpLink"
        case reportAProblemLink = "ReportAProblemLink"
    }
}

/// The subset of remote server info the add-server form (and diagnostics) consume — native
/// counterpart of desktop `RemoteInfo` (`types/server.ts`). Only the fields serverInfo.ts
/// actually populates in the add flow are modeled; the plugin/license probes belong to
/// `fetchRemoteInfo` (not needed by the add-server form, added when diagnostics land in P6).
struct RemoteInfo: Equatable {
    var serverVersion: String?
    var siteName: String?
    var siteURL: String?
    var helpLink: String?
    var reportProblemLink: String?

    init(serverVersion: String? = nil,
         siteName: String? = nil,
         siteURL: String? = nil,
         helpLink: String? = nil,
         reportProblemLink: String? = nil) {
        self.serverVersion = serverVersion
        self.siteName = siteName
        self.siteURL = siteURL
        self.helpLink = helpLink
        self.reportProblemLink = reportProblemLink
    }

    init(config: ClientConfig) {
        self.init(serverVersion: config.version,
                  siteName: config.siteName,
                  siteURL: config.siteURL,
                  helpLink: config.helpLink,
                  reportProblemLink: config.reportAProblemLink)
    }
}