import Foundation

/// Native counterpart of desktop `URLValidationStatus` (`src/common/utils/constants.ts`).
/// The set of outcomes the add-server form can report for a candidate server URL.
enum URLValidationStatus: String, Equatable {
    case ok = "OK"
    case missing = "MISSING"
    case invalid = "INVALID"
    case insecure = "INSECURE"
    case urlExists = "URL_EXISTS"
    case notMattermost = "NOT_MATTERMOST"
    case urlNotMatched = "URL_NOT_MATCHED"
    case urlUpdated = "URL_UPDATED"
    case preAuthRequired = "PREAUTH_REQUIRED"
    case basicAuthRequired = "BASICAUTH_REQUIRED"
    case clientCertRequired = "CLIENTCERT_REQUIRED"
    case magicLink = "MAGIC_LINK"
}

/// The result of validating a candidate server URL — native counterpart of desktop
/// `URLValidationResult` (`types/server.ts`).
struct URLValidationResult: Equatable {
    var status: URLValidationStatus
    var validatedURL: String?
    var existingServerName: String?
    var serverVersion: String?
    var serverName: String?
}

/// The add-server form's URL validation engine. Direct port of the desktop
/// `ServerHub.handleServerURLValidation` + `testRemoteServer` (with `ServerInfo`/`serverAPI`)
/// in `src/app/serverHub.ts`. Validates a raw user-typed URL by:
///
///   1. requiring/normalizing it to a parseable http(s) URL (defaulting to https),
///   2. rejecting it if it already points at a configured server (`URL_EXISTS`),
///   3. probing `/api/v4/system/ping` then `/api/v4/config/client?format=old` on the most
///      secure URL (https) first and falling back to http when https fails,
///   4. mapping 401/403/client-cert into BasicAuth/PreAuth/ClientCert outcomes,
///   5. decoding the name probe -> `serverName` (defaulting the display name to the host label
///      when the server reports the generic "Mattermost" name), and
///   6. reconciling the probed SiteURL with the typed URL (URL_NOT_MATCHED / URL_UPDATED) and
///      flagging http-only connections (INSECURE).
///
/// `existingServerLookup` and `api` are injected so tests can stub the registry and network
/// (an `URLSession` backed by a mock `URLProtocol`) without hitting the real server.
struct ServerURLValidator {

    /// Max URL length the desktop `parseURL` accepts (bytes).
    private static let maxURLLength = 8_192
    private static let maxPathPruneDepth = 8

    private let api: ServerAPI
    private let existingServerLookup: (URL) -> ServerConfig?

    init(api: ServerAPI = ServerAPI(),
         existingServerLookup: @escaping (URL) -> ServerConfig? = { _ in nil }) {
        self.api = api
        self.existingServerLookup = existingServerLookup
    }

    /// Validate a raw URL string. `currentServerID` exempts the server being edited from the
    /// URL_EXISTS duplicate check (mirrors desktop passing `currentId` through the IPC call).
    func validate(rawURL: String, currentServerID: UUID?) async -> URLValidationResult {
        await validate(rawURL, currentServerID: currentServerID, originalURL: nil, depth: 0)
    }

    // MARK: - Ported engine

    /// Recursive core, mirroring `handleServerURLValidation`. `originalURL` is threaded through the
    /// path-pruning retries so the final NOT_MATTERMOST message reports what the user typed.
    private func validate(_ rawURL: String,
                          currentServerID: UUID?,
                          originalURL: String?,
                          depth: Int) async -> URLValidationResult {
        guard !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return URLValidationResult(status: .missing)
        }

        // Normalize the scheme. Desktop: isHttpUri/isHttpsUri validate the URL; a bare host that
        // doesn't start with "http" is prefixed with https://.
        var httpURL = rawURL
        if !Self.isValidHTTPURL(rawURL) {
            if Self.isValidURI(rawURL) && !rawURL.lowercased().hasPrefix("http") {
                httpURL = Self.forceScheme("https://", onto: rawURL)
            } else if !rawURL.lowercased().hasPrefix("https://") && !rawURL.lowercased().hasPrefix("http://") {
                httpURL = "https://" + rawURL
            }
        }

        guard let parsedURL = Self.parseURL(httpURL) else {
            return URLValidationResult(status: .invalid)
        }

        let original = originalURL ?? parsedURL.absoluteString

        // Upgrade an explicitly-http URL to https for probing; fall back to http only if https
        // is unreachable.
        let secureURL = Self.secureForm(of: parsedURL)

        // Reject as a duplicate unless it is the server being edited.
        if let existing = existingServerLookup(secureURL), existing.id != currentServerID {
            return URLValidationResult(
                status: .urlExists,
                validatedURL: existing.url.absoluteString,
                existingServerName: existing.name
            )
        }

        // Probe the most secure URL first; on failure try the insecure (http) fallback.
        var remoteInfo: RemoteInfo?
        var remoteURL = secureURL
        let insecureURL = Self.insecureForm(of: secureURL)

        var preAuthRequired = false
        var basicAuthRequired = false
        var clientCertRequired = false

        if let info = await testRemoteServer(secureURL) {
            remoteInfo = info
        } else {
            let httpsReason = await probeErrorReason(secureURL)

            if let insecureURL {
                if let info = await testRemoteServer(insecureURL) {
                    remoteInfo = info
                    remoteURL = insecureURL
                } else {
                    let httpReason = await probeErrorReason(insecureURL)
                    if httpsReason.needsPreAuth || httpReason.needsPreAuth {
                        preAuthRequired = true
                        remoteURL = httpsReason.needsPreAuth ? secureURL : insecureURL
                    }
                    if httpsReason.needsBasicAuth || httpReason.needsBasicAuth {
                        basicAuthRequired = true
                        remoteURL = httpsReason.needsBasicAuth ? secureURL : insecureURL
                    }
                    if httpsReason.needsClientCert || httpReason.needsClientCert {
                        clientCertRequired = true
                        remoteURL = httpsReason.needsClientCert ? secureURL : insecureURL
                    }
                }
            } else if httpsReason.needsPreAuth {
                preAuthRequired = true
            } else if httpsReason.needsBasicAuth {
                basicAuthRequired = true
            } else if httpsReason.needsClientCert {
                clientCertRequired = true
            }
        }

        if preAuthRequired {
            return URLValidationResult(status: .preAuthRequired,
                                       validatedURL: Self.stripTrailingSlash(remoteURL.absoluteString))
        }
        if basicAuthRequired {
            return URLValidationResult(status: .basicAuthRequired,
                                       validatedURL: Self.stripTrailingSlash(remoteURL.absoluteString))
        }
        if clientCertRequired {
            return URLValidationResult(status: .clientCertRequired,
                                       validatedURL: Self.stripTrailingSlash(remoteURL.absoluteString))
        }

        // Both probes failed / no Mattermost JSON came back: retry with the last path segment
        // removed (strips a bad team path back toward the server root) before giving up.
        guard let remoteInfo else {
            if parsedURL.path != "/", parsedURL.path.count > 1, depth < Self.maxPathPruneDepth {
                let pruned = Self.pruneLastPathSegment(of: original)
                if let prunedURL = Self.parseURL(pruned),
                   prunedURL != parsedURL {
                    return await validate(pruned, currentServerID: currentServerID,
                                          originalURL: original, depth: depth + 1)
                }
            }
            return URLValidationResult(status: .notMattermost,
                                       validatedURL: Self.stripTrailingSlash(original))
        }

        let serverName = Self.displayName(from: remoteInfo, remoteURL: remoteURL)

        if remoteURL.scheme == "http" {
            return URLValidationResult(status: .insecure,
                                       validatedURL: remoteURL.absoluteString,
                                       serverVersion: remoteInfo.serverVersion,
                                       serverName: serverName)
        }

        if let siteURL = remoteInfo.siteURL, let parsedSiteURL = Self.parseURL(siteURL),
           remoteURL.absoluteString != parsedSiteURL.absoluteString {
            if let existing = existingServerLookup(parsedSiteURL), existing.id != currentServerID {
                return URLValidationResult(
                    status: .urlExists,
                    validatedURL: existing.url.absoluteString,
                    existingServerName: existing.name
                )
            }
            if await testRemoteServer(parsedSiteURL) == nil {
                return URLValidationResult(status: .urlNotMatched,
                                           validatedURL: remoteURL.absoluteString,
                                           serverVersion: remoteInfo.serverVersion,
                                           serverName: serverName)
            }
            return URLValidationResult(status: .urlUpdated,
                                       validatedURL: parsedSiteURL.absoluteString,
                                       serverVersion: remoteInfo.serverVersion,
                                       serverName: serverName)
        }

        let status: URLValidationStatus = Self.isMagicLink(remoteURL, input: parsedURL) ? .magicLink : .ok
        return URLValidationResult(status: status,
                                   validatedURL: remoteURL.absoluteString,
                                   serverVersion: remoteInfo.serverVersion,
                                   serverName: serverName)
    }

    // MARK: - Remote probing

    /// Port of desktop `testRemoteServer`: construct a temp server for the URL, ping it, then
    /// fetch its config. Returns nil when either probe fails.
    private func testRemoteServer(_ url: URL) async -> RemoteInfo? {
        let info = ServerInfo(baseURL: url, api: api)
        guard (try? await info.pingServer()) != nil else { return nil }
        return try? await info.fetchConfigData()
    }

    /// Which auth/tls hint a url's *ping* probe produces (only consulted once the probe failed,
    /// mirroring how desktop reads `error.errorReason` on a failed test).
    private func probeErrorReason(_ url: URL) async -> ServerAPI.ErrorReason {
        let info = ServerInfo(baseURL: url, api: api)
        do {
            try await info.pingServer()
            return ServerAPI.ErrorReason()
        } catch let probe as ServerProbeError {
            switch probe {
            case .needsPreAuth: return ServerAPI.ErrorReason(needsPreAuth: true)
            case .needsBasicAuth: return ServerAPI.ErrorReason(needsBasicAuth: true)
            case .needsClientCert: return ServerAPI.ErrorReason(needsClientCert: true)
            default: return ServerAPI.ErrorReason()
            }
        } catch {
            return ServerAPI.ErrorReason()
        }
    }

    // MARK: - Ported URL helpers

    /// Desktop `parseURL`: collapses repeated slashes, rejects overly long / NUL-containing
    /// inputs, else `new URL()`. Returns nil when unparseable.
    static func parseURL(_ input: String) -> URL? {
        guard input.utf8.count <= maxURLLength else { return nil }
        guard !input.contains("\0"), !input.lowercased().contains("%00") else { return nil }
        // Desktop: inputURL.replace(/([^:/]\/)\/+/g, '$1') — collapse runs of slashes that follow
        // a single slash, but leave "://" (scheme separator) untouched.
        let pattern = #"([^:/]/)/+"#
        let collapsed = input.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        return URL(string: collapsed)
    }

    /// Desktop `isValidURL`: an http(s) URI that also parses.
    private static func isValidHTTPURL(_ url: String) -> Bool {
        guard let parsed = parseURL(url), let scheme = parsed.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Desktop `isValidURI`: any valid URI (scheme present), not just http(s).
    private static func isValidURI(_ url: String) -> Bool {
        guard let parsed = parseURL(url), let scheme = parsed.scheme else { return false }
        return !scheme.isEmpty
    }

    /// Desktop `url.replace(/^((.+):\/\/)?/, 'https://')` for a string that already carries a
    /// (non-http) scheme.
    private static func forceScheme(_ scheme: String, onto url: String) -> String {
        guard url.contains("://") else { return scheme + url }
        return scheme + url
    }

    /// Upgrade an http URL to https (desktop `parsedURL.toString().replace(/^http:/,'https:')`).
    private static func secureForm(of url: URL) -> URL {
        guard url.scheme == "http" else { return url }
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if comps?.scheme == "http" { comps?.scheme = "https" }
        return comps?.url ?? url
    }

    /// Downgrade an https URL to http (desktop `secureURL.toString().replace(/^https:/,'http:')`).
    private static func insecureForm(of url: URL) -> URL? {
        guard url.scheme == "https" else { return nil }
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.scheme = "http"
        return comps?.url
    }

    /// Desktop `remoteURL.toString().replace(/\/$/, '')` — strip exactly one trailing slash.
    private static func stripTrailingSlash(_ s: String) -> String {
        var s = s
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Desktop's path-pruning retry head (`parsedURL.toString().substring(0, lastIndexOf('/'))`):
    /// drop the final path segment of the original URL so a bad team path collapses to the root.
    private static func pruneLastPathSegment(of originalURL: String) -> String {
        guard let parsed = parseURL(originalURL),
              parsed.path.count > 1,
              var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false) else {
            return originalURL
        }
        let path = components.path
        let idx = path.lastIndex(of: "/") ?? path.startIndex
        components.path = String(path[..<idx])
        if let trimmed = components.url {
            // When the pruned path empties out, URLComponents re-appends a single "/", matching
            // the desktop `https://host/` -> `https://host` substring behaviour we rely on.
            return trimmed.absoluteString
        }
        return originalURL
    }

    /// Desktop: `remoteInfo.siteName === 'Mattermost' ? remoteURL.host.split('.')[0] : siteName`.
    private static func displayName(from info: RemoteInfo, remoteURL: URL) -> String {
        if info.siteName == "Mattermost" {
            return remoteURL.host?.split(separator: ".").first.map(String.init) ?? (remoteURL.host ?? "")
        }
        return info.siteName ?? (remoteURL.host ?? "")
    }

    /// Desktop `isMagicLinkUrl(serverURL, inputURL)`: the input path is `login/one_time_link` under
    /// the server root.
    private static func isMagicLink(_ serverURL: URL, input: URL) -> Bool {
        guard serverURL.host == input.host, input.scheme == serverURL.scheme else { return false }
        let serverPath = (serverURL.path.isEmpty ? "/" : serverURL.path) + "/"
        let inputPath = (input.path.isEmpty ? "/" : input.path) + "/"
        return inputPath.hasPrefix(serverPath + "login/one_time_link/")
    }
}