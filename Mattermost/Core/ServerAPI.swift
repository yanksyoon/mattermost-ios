import Foundation

/// Native counterpart of desktop `src/main/server/serverAPI.ts` (`getServerAPI`).
/// A thin `URLSession` GET shim used by the server-info probes. HTTP status codes are kept
/// (not coerced into thrown errors) so callers can distinguish 401 basic-auth requests,
/// 403 pre-auth requests, and TLS client-certificate requests — mirroring how Electron's
/// `net.request` surfaces those via an `errorReason` hint.
///
/// Parity row: `serverInfo`/`serverAPI` (`src/main/server/serverAPI.ts`) -> `ServerAPI`
/// (URLSession). Status: native, P1. `ServerAPI` is protocol-free by design so the caller
/// can hand it an `URLSession` backed by a stubbed `URLProtocol` in tests.
struct ServerAPI {

    /// The session used for probes. Defaults to the shared session; tests inject an
    /// ephemeral session with a mock `URLProtocol` (mirroring the fresh Electron session
    /// partition `session.fromPartition('server-validation')` used by the desktop app so
    /// validation probes carry no user cookies).
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Hints surfaced from a probe's response or transport error (desktop `ErrorReason`).
    struct ErrorReason: Equatable {
        var needsBasicAuth = false
        var needsPreAuth = false
        var needsClientCert = false
    }

    /// A completed probe response. `errorReason` is derived from status/headers so the
    /// validator doesn't have to re-inspect them.
    struct Response: Equatable {
        var statusCode: Int
        var body: String
        var errorReason: ErrorReason
    }

    /// Thrown for transport-level failures (no HTTP response received).
    enum APIError: Error, Equatable {
        case transport(String)
        case clientCertRequired
        case nonHTTPResponse
    }

    /// GET `url`. Throws only for transport failures; successes and HTTP error statuses
    /// both return a `Response` (desktop's `getServerAPI` calls the success callback only on
    /// status 200 but still exposes the status to the error path).
    func get(url: URL) async throws -> Response {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = "GET"

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as NSError {
            // TLS client-certificate requirement shows up as a transport error
            // (desktop: message includes `ERR_SSL_CLIENT_AUTH_CERT_NEEDED`).
            if error.domain == NSURLErrorDomain,
               error.code == NSURLErrorClientCertificateRequired {
                throw APIError.clientCertRequired
            }
            throw APIError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.nonHTTPResponse
        }
        return Response(
            statusCode: http.statusCode,
            body: String(data: data, encoding: .utf8) ?? "",
            errorReason: Self.errorReason(for: http.statusCode, headers: http.allHeaderFields)
        )
    }

    /// Mirror desktop's header-based error-reason detection. HTTP headers are case-insensitive, so
    /// search them case-insensitively (HTTPURLResponse.allHeaderFields preserves the original case,
    /// which for `www-authenticate` / `x-reject-reason` can be mixed).
    private static func errorReason(for status: Int, headers: [AnyHashable: Any]) -> ErrorReason {
        func value(_ name: String) -> String? {
            headers.first { key, _ in
                (key as? String)?.caseInsensitiveCompare(name) == .orderedSame
            }?.value as? String
        }
        var reason = ErrorReason()
        if status == 401, let wwwAuth = value("www-authenticate"),
           wwwAuth.lowercased().contains("basic") {
            reason.needsBasicAuth = true
        }
        if status == 403, let reject = value("x-reject-reason"),
           reject.lowercased().contains("pre-auth") {
            reason.needsPreAuth = true
        }
        return reason
    }
}