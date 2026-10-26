// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0,
// `ios/Gekidou/Sources/Gekidou/Networking/Network.swift` (bearer auth, `X-Requested-With`,
// `/api/v4` prefix, response handling) plus `app/client/rest/index.ts` and
// `app/client/rest/error.ts` (typed errors). Own implementation per docs/path-b-adr.md §3 — the
// upstream client is completion-handler based and reaches a singleton `Keychain`/`Database`; this
// one is `async`/`await`, per-server, and every collaborator is injected so tests need no network.

import Foundation

/// Async/await REST v4 client for one server.
///
/// Responsibilities (and nothing else — screens own their own state):
///  - **URL shaping**: `/api/v4` + path under the server's base path (`MMBaseURL`).
///  - **Auth**: `Authorization: Bearer <token>` from the injected token provider, which is backed
///    by the existing `SecureVault` — T28 does not introduce a second credential store.
///  - **Typed decoding**: `Codable` request/response models, tolerant of missing fields.
///  - **Conditional GET**: `ETag` / `If-None-Match`, replaying the cached body on `304`.
///  - **Retry**: idempotent GETs only, exponential backoff with jitter, honouring `Retry-After`
///    on `429` and on retryable `5xx`.
///  - **Typed errors**: `MMError`, with `401` also firing `onUnauthorized` so `AuthSession` can
///    surface re-auth (acceptance criterion 1).
final class APIClient: @unchecked Sendable {

    /// Retry policy for idempotent requests. Values are deliberately conservative: the app is
    /// interactive, and the socket path (not REST) is what keeps a screen current.
    struct RetryPolicy: Equatable, Sendable {
        var maxAttempts: Int = 3
        var baseDelay: TimeInterval = 0.5
        var maxDelay: TimeInterval = 20
        /// `0.25` spreads each attempt by ±25 %, so a fleet of clients that lost the same server
        /// does not reconnect in lock-step.
        var jitterRatio: Double = 0.25

        static let none = RetryPolicy(maxAttempts: 1)

        /// Delay before retry number `attempt` (1-based): `base * 2^(attempt-1)`, capped, then
        /// jittered by `random` ∈ [0, 1).
        func delay(forAttempt attempt: Int, random: Double) -> TimeInterval {
            let exponential = baseDelay * pow(2, Double(max(0, attempt - 1)))
            let capped = min(exponential, maxDelay)
            let offset = capped * jitterRatio * (random * 2 - 1)
            return max(0, capped + offset)
        }
    }

    /// A `304 Not Modified` cached body.
    private struct CachedResponse {
        var etag: String
        var response: APIResponse
    }

    let baseURL: MMBaseURL
    let retryPolicy: RetryPolicy

    private let transport: APITransport
    private let tokenProvider: () -> String?
    private let sleep: (TimeInterval) async -> Void
    private let random: () -> Double
    private let lock = NSLock()
    private var cache: [String: CachedResponse] = [:]

    /// Fired on every `401` (before the typed error is thrown). `AuthSession` sets this to mark
    /// itself `needsReauth` and drop the stored token; screens observe that and show re-auth.
    var onUnauthorized: (() -> Void)?
    /// Test/diagnostics hook: (attempt, delay, reason-without-secrets).
    var onRetryScheduled: ((Int, TimeInterval, String) -> Void)?

    init(serverURL: URL,
         transport: APITransport,
         retryPolicy: RetryPolicy = RetryPolicy(),
         tokenProvider: @escaping () -> String? = { nil },
         sleep: @escaping (TimeInterval) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
         },
         random: @escaping () -> Double = { Double.random(in: 0..<1) }) throws {
        guard let baseURL = MMBaseURL(serverURL) else {
            throw MMError.invalidURL(serverURL.absoluteString)
        }
        self.baseURL = baseURL
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.tokenProvider = tokenProvider
        self.sleep = sleep
        self.random = random
    }

    /// Convenience: a client whose token comes from the existing per-server `SecureVault`
    /// (`authToken`), against a real `URLSession` transport that shares the webview's `CertTrust`.
    convenience init(serverURL: URL,
                     vault: SecureVault,
                     certTrust: CertTrust = CertTrust(),
                     onUntrustedCertificate: ((CertificatePrompt) -> Void)? = nil,
                     retryPolicy: RetryPolicy = RetryPolicy()) throws {
        let transport = URLSessionTransport(serverURL: serverURL,
                                            certTrust: certTrust,
                                            onUntrustedCertificate: onUntrustedCertificate)
        try self.init(serverURL: serverURL,
                      transport: transport,
                      retryPolicy: retryPolicy,
                      tokenProvider: { vault.getSecret(key: .authToken, serverURL: serverURL) })
    }

    // MARK: - Public API

    /// Typed GET.
    func get<T: Decodable>(_ type: T.Type,
                           path: String,
                           query: [URLQueryItem] = [],
                           requiresAuth: Bool = true,
                           useETag: Bool = true) async throws -> T {
        let response = try await perform(method: .get, path: path, query: query,
                                         body: nil, requiresAuth: requiresAuth,
                                         useETag: useETag)
        return try decode(type, from: response)
    }

    /// Raw GET (diagnostics, file bytes, endpoints whose shape a screen card owns).
    func getData(path: String,
                 query: [URLQueryItem] = [],
                 requiresAuth: Bool = true,
                 useETag: Bool = true) async throws -> Data {
        let response = try await perform(method: .get, path: path, query: query,
                                         body: nil, requiresAuth: requiresAuth,
                                         useETag: useETag)
        return response.body
    }

    /// An authenticated `URLRequest` for one file's bytes — the seam the **download** path transfers
    /// (S18/T38).
    ///
    /// `DownloadWorker` must not learn how to authenticate: the token belongs to this client and to
    /// nothing else (the same boundary that keeps it out of the webview's JavaScript). This builds the
    /// identical `/api/v4` URL and the identical `Authorization`/`X-Requested-With` pair every other
    /// call sends, so a downloaded attachment is fetched exactly like a drawn one. No ETag, no body:
    /// a file download is a plain GET, and the worker's own task handles progress and cancellation.
    ///
    /// A 401 during the transfer surfaces as a failed download rather than a re-auth prompt; the row
    /// reports it, and the next ordinary request brings the session back (`AuthSession` owns that).
    func authorizedRequest(path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard let url = baseURL.apiV4(path, query: query) else {
            throw MMError.invalidURL(path)
        }
        guard let token = tokenProvider(), !token.isEmpty else { throw MMError.notSignedIn }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        return request
    }

    /// POST with a `Codable` body and a typed response.
    func post<T: Decodable, Body: Encodable>(_ type: T.Type,
                                             path: String,
                                             body: Body,
                                             requiresAuth: Bool = true) async throws -> T {
        let data = try encode(body)
        let response = try await perform(method: .post, path: path, query: [],
                                         body: data, requiresAuth: requiresAuth,
                                         useETag: false)
        return try decode(type, from: response)
    }

    /// PUT with a `Codable` body and a typed response.
    ///
    /// Added for T33 (S08): the sidebar categories write is `PUT …/channels/categories` whose answer
    /// is the re-read category list, and the web/native clients both rely on the server's answer
    /// rather than on an optimistic local guess. No ETag on a write (there is nothing to
    /// conditionally revalidate).
    func put<T: Decodable, Body: Encodable>(_ type: T.Type,
                                            path: String,
                                            body: Body) async throws -> T {
        let data = try encode(body)
        let response = try await perform(method: .put, path: path, query: [],
                                         body: data, requiresAuth: true,
                                         useETag: false)
        return try decode(type, from: response)
    }

    /// PUT whose response body the caller does not consume (`notify_props`, which answers
    /// `{"status":"OK"}`).
    @discardableResult
    func putForResponse<Body: Encodable>(path: String, body: Body) async throws -> APIResponse {
        let data = try encode(body)
        return try await perform(method: .put, path: path, query: [],
                                 body: data, requiresAuth: true,
                                 useETag: false)
    }

    /// POST returning the full response (login needs the `Token` header, not just the body).
    @discardableResult
    func postForResponse(path: String,
                         body: Data?,
                         requiresAuth: Bool = true) async throws -> APIResponse {
        try await perform(method: .post, path: path, query: [], body: body,
                          requiresAuth: requiresAuth, useETag: false)
    }

    /// `POST /files` — one file, `multipart/form-data`, with the transport's own byte count.
    ///
    /// Why this is not `post(_:path:body:)`: the body is not JSON, so the `Content-Type` has to be the
    /// multipart one the encoder produced (a JSON header on a multipart body is a 400 the app would
    /// then retry), and the caller wants progress. Both are threaded through `perform` so the upload
    /// keeps the same auth, 401 → re-auth, `/api/v4` prefix and TLS decision as every other call —
    /// a second bespoke client here would be the security regression the auth notes forbid
    /// (`AuthSession.client` is the only authenticated client a screen may use).
    ///
    /// Uploads are **not** retried on 429/5xx: a retried upload would re-post the bytes and, if the
    /// first attempt actually landed, leave an orphaned file. The composer offers Retry to the person
    /// instead, which is the same choice upstream's upload queue makes.
    func uploadMultipart<T: Decodable>(_ type: T.Type,
                                       path: String,
                                       fields: [MMMultipart.Field],
                                       file: MMMultipart.File,
                                       onProgress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws -> T {
        let encoded = MMMultipart.encode(fields: fields, files: [file],
                                         boundary: MMMultipart.makeBoundary())
        let response = try await perform(method: .post, path: path, query: [],
                                         body: encoded.body, requiresAuth: true,
                                         useETag: false,
                                         contentType: encoded.contentType,
                                         timeout: 120,
                                         onProgress: onProgress)
        return try decode(type, from: response)
    }

    /// `POST /users/logout` with an **explicitly supplied** bearer token.
    ///
    /// The one caller is `AuthSession.revokeSession(discardedToken:)`, and it exists because of the
    /// sign-out ordering (T31-AV F2): the local credential is deleted *before* the revocation, so the
    /// injected token provider (which reads the vault) would answer `nil` and the logout would go out
    /// unauthenticated. There is deliberately no general `token:` parameter on `postForResponse` —
    /// a screen must not be able to authenticate as somebody else's token; this method can only do
    /// one thing, to one path.
    @discardableResult
    func revokeSession(token: String) async throws -> APIResponse {
        try await perform(method: .post, path: "/users/logout", query: [], body: nil,
                          requiresAuth: true, useETag: false, explicitToken: token)
    }

    /// DELETE with no response body contract (Mattermost returns `{"status":"OK"}`).
    @discardableResult
    func delete(path: String, requiresAuth: Bool = true) async throws -> APIResponse {
        try await perform(method: .delete, path: path, query: [], body: nil,
                          requiresAuth: requiresAuth, useETag: false)
    }

    /// Decode a response body into a model, mapping a decode failure onto
    /// `MMError.malformedResponse`.
    func decode<T: Decodable>(_ type: T.Type, from response: APIResponse) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch {
            // `DecodingError` describes the coding path, never the payload values, so this cannot
            // smuggle post content or a token into a log line.
            throw MMError.malformedResponse("\(T.self): \(Self.describe(error))")
        }
    }

    func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw MMError.malformedResponse("encoding \(T.self): \(Self.describe(error))")
        }
    }

    // MARK: - Request pipeline

    private struct RetryableFailure {
        var reason: String
        var retryAfter: TimeInterval?
        var status: Int
        var message: String?
    }

    private enum AttemptOutcome {
        case success(APIResponse)
        case retry(RetryableFailure)
    }

    private func perform(method: HTTPMethod,
                         path: String,
                         query: [URLQueryItem],
                         body: Data?,
                         requiresAuth: Bool,
                         useETag: Bool,
                         explicitToken: String? = nil,
                         contentType: String? = nil,
                         timeout: TimeInterval? = nil,
                         onProgress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> APIResponse {
        guard let url = baseURL.apiV4(path, query: query) else {
            throw MMError.invalidURL(path)
        }
        var headers: [String: String] = ["Accept": "application/json"]
        if body != nil {
            headers["Content-Type"] = contentType ?? "application/json; charset=utf-8"
        }
        if requiresAuth {
            guard let token = explicitToken ?? tokenProvider(), !token.isEmpty else {
                throw MMError.notSignedIn
            }
            headers["Authorization"] = "Bearer \(token)"
            headers["X-Requested-With"] = "XMLHttpRequest"
        }
        // Conditional GET: ask the server for a 304 when we still hold its ETag. `If-None-Match`
        // is only ever added for GET — a stale validator on a write would be a bug.
        if useETag, let cached = cachedResponse(for: url) {
            headers["If-None-Match"] = cached.etag
        }

        var attempt = 0
        while true {
            attempt += 1
            var request = APIRequest(method: method, url: url, headers: headers, body: body)
            if let timeout { request.timeout = timeout }
            let outcome = try await makeAttempt(request, useETag: useETag, onProgress: onProgress)
            switch outcome {
            case .success(let response):
                return response
            case .retry(let failure):
                // Only an idempotent request may be replayed: a GET, and never an upload (a retried
                // upload can duplicate the bytes server-side; see `uploadMultipart`).
                let idempotent = method == .get && onProgress == nil
                guard idempotent, attempt < retryPolicy.maxAttempts else {
                    throw Self.error(for: failure)
                }
                // The server's `Retry-After` is honoured, but never trusted to block the app: a
                // hostile or misconfigured `Retry-After: 86400` must not park a request for a day.
                // The *slept* delay is clamped; the thrown `.rateLimited(retryAfter:)` keeps the
                // server's exact value so a screen can still say "try again in 24 h".
                let delay: TimeInterval
                if let serverDelay = failure.retryAfter {
                    delay = min(serverDelay, retryPolicy.maxDelay)
                } else {
                    delay = retryPolicy.delay(forAttempt: attempt, random: random())
                }
                onRetryScheduled?(attempt, delay, failure.reason)
                MMLog.debug("MMAPI", "retrying \(method.rawValue) \(path) attempt \(attempt + 1) "
                    + "after \(String(format: "%.2f", delay))s (\(failure.reason))")
                await sleep(delay)
            }
        }
    }

    private func makeAttempt(_ request: APIRequest,
                             useETag: Bool,
                             onProgress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> AttemptOutcome {
        let response: APIResponse
        do {
            if let onProgress, let uploads = transport as? UploadTransport {
                response = try await uploads.send(request, onSendProgress: onProgress)
            } else {
                response = try await transport.send(request)
            }
        } catch let error as APITransportError {
            switch error {
            case .timeout:
                return .retry(RetryableFailure(reason: "timeout", retryAfter: nil, status: 0, message: nil))
            case .offline:
                return .retry(RetryableFailure(reason: "offline", retryAfter: nil, status: 0, message: nil))
            case .cancelled:
                throw MMError.cancelled
            case .certificateUntrusted(let origin):
                // Never retried: the user has to make a trust decision first.
                throw MMError.certificateUntrusted(origin: origin)
            case .other(let message):
                throw MMError.transport(message)
            }
        }

        switch response.statusCode {
        case 200...299:
            storeETag(from: response, for: request.url, useETag: useETag)
            return .success(response)
        case 304:
            guard useETag, let cached = cachedResponse(for: request.url) else {
                throw MMError.malformedResponse("HTTP 304 without a cached body")
            }
            return .success(cached.response)
        case 401:
            let payload = Self.errorPayload(in: response.body)
            if payload?.id == MMServerErrorPayload.mfaRequiredID {
                throw MMError.mfaRequired(message: payload?.message)
            }
            onUnauthorized?()
            throw MMError.unauthorized(message: payload?.message)
        case 403:
            throw MMError.forbidden(message: Self.errorPayload(in: response.body)?.message)
        case 404:
            throw MMError.notFound
        case 429:
            return .retry(RetryableFailure(reason: "429",
                                           retryAfter: Self.retryAfter(from: response),
                                           status: 429,
                                           message: Self.errorPayload(in: response.body)?.message))
        case 500...599:
            let message = Self.errorPayload(in: response.body)?.message
            if [500, 502, 503, 504].contains(response.statusCode) {
                return .retry(RetryableFailure(reason: "\(response.statusCode)",
                                               retryAfter: Self.retryAfter(from: response),
                                               status: response.statusCode,
                                               message: message))
            }
            throw MMError.server(status: response.statusCode, message: message)
        default:
            throw MMError.client(status: response.statusCode,
                                 message: Self.errorPayload(in: response.body)?.message)
        }
    }

    // MARK: - Error mapping helpers

    private static func error(for failure: RetryableFailure) -> MMError {
        if failure.status == 429 {
            return .rateLimited(retryAfter: failure.retryAfter)
        }
        if failure.status >= 500 {
            return .server(status: failure.status, message: failure.message)
        }
        if failure.status == 0 {
            return failure.reason == "timeout" ? .timeout : .offline
        }
        return .transport(failure.reason)
    }

    static func errorPayload(in body: Data) -> MMServerErrorPayload? {
        try? JSONDecoder().decode(MMServerErrorPayload.self, from: body)
    }

    /// `Retry-After` is either delta-seconds or an HTTP-date (RFC 7231 §7.1.3).
    static func retryAfter(from response: APIResponse, now: Date = Date()) -> TimeInterval? {
        guard let value = response.header("Retry-After")?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(value) {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    private static func describe(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case .keyNotFound(let key, _): return "missing key \(key.stringValue)"
            case .typeMismatch(let type, _): return "type mismatch (\(type))"
            case .valueNotFound(let type, _): return "missing value (\(type))"
            case .dataCorrupted: return "malformed JSON"
            @unknown default: return "decoding failure"
            }
        }
        return String(describing: type(of: error))
    }

    // MARK: - ETag cache

    private func cachedResponse(for url: URL) -> CachedResponse? {
        lock.lock()
        defer { lock.unlock() }
        return cache[url.absoluteString]
    }

    private func storeETag(from response: APIResponse, for url: URL, useETag: Bool) {
        guard useETag, let etag = response.header("ETag") ?? response.header("Etag"),
              !etag.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        cache[url.absoluteString] = CachedResponse(etag: etag, response: response)
    }

    /// Drop the conditional-GET cache (logout, server switch, explicit refresh).
    func clearETagCache() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }
}
