// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0,
// `ios/Gekidou/Sources/Gekidou/Networking/Network.swift` + `Network+Delegate.swift` and
// `@mattermost/react-native-network-client@1.11.4` (the URLSession design). Own implementation
// per docs/path-b-adr.md §3 — a protocol seam (`APITransport`) that upstream does not have, so
// every transport test in this repo runs without a socket.

import Foundation
import Security

enum HTTPMethod: String, Equatable, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

/// One HTTP request, transport-agnostic. `APIRequest` deliberately has no notion of "server" or
/// "token": the `APIClient` resolves both before it hands the request over, so a fake transport
/// sees exactly the bytes the network would.
struct APIRequest: Equatable, Sendable {
    var method: HTTPMethod
    var url: URL
    var headers: [String: String] = [:]
    var body: Data?
    var timeout: TimeInterval = 30

    func urlRequest() -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method.rawValue
        request.httpBody = body
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }
}

/// One HTTP response, transport-agnostic.
struct APIResponse: Equatable, Sendable {
    var statusCode: Int
    var headers: [String: String]
    var body: Data

    /// Case-insensitive header lookup (HTTP header names are case-insensitive and servers vary:
    /// Mattermost sends `Token:` on login, `Etag:` for caching).
    func header(_ name: String) -> String? {
        if let exact = headers[name] { return exact }
        for (key, value) in headers where key.caseInsensitiveCompare(name) == .orderedSame {
            return value
        }
        return nil
    }

    /// The `Token` response header `POST /users/login` carries, falling back to the
    /// `MMAUTHTOKEN` cookie (the mobile client accepts either — `MattermostClient.login`).
    var sessionToken: String? {
        if let token = header("Token")?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return token
        }
        for (key, value) in headers where key.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
            if let token = Self.cookieValue(named: "MMAUTHTOKEN", in: value) { return token }
        }
        return nil
    }

    private static func cookieValue(named name: String, in setCookieHeader: String) -> String? {
        for part in setCookieHeader.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame else {
                continue
            }
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

/// The test seam. Every unit test in `MattermostTests/APIClientTests.swift`,
/// `AuthSessionTests.swift` and `SocketClientTests.swift` runs against a fake of this protocol, so
/// the suite needs no server and no network.
protocol APITransport: AnyObject {
    func send(_ request: APIRequest) async throws -> APIResponse
}

/// A transport that can report how much of a request body it has written.
///
/// Separate from `APITransport` so every existing fake keeps compiling and behaving: `APIClient`
/// falls back to a plain `send` when the transport does not implement this, so an upload still goes
/// out — only the progress bar has nothing to draw. (T35, the composer's attachment upload: the
/// download side already reports progress through `URLSessionDownloadDelegate`, this is the same
/// signal in the other direction.)
protocol UploadTransport: APITransport {
    /// Send `request`, calling `onSendProgress(bytesSent, bytesExpected)` as the body is written.
    /// `bytesExpected` is 0 when the stack cannot know the total.
    func send(_ request: APIRequest,
              onSendProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> APIResponse
}

/// `URLSession`-backed transport for one server.
///
/// The session carries `TransportSessionDelegate`, which consults the same per-origin `CertTrust`
/// bag the webview uses on every server-trust challenge (T28 acceptance criterion 4). A
/// self-signed server is therefore trusted (or refused) once, for both the webview and the native
/// client.
final class URLSessionTransport: NSObject, UploadTransport {

    let delegate: TransportSessionDelegate
    private let session: URLSession
    private let origin: String

    init(serverURL: URL,
         certTrust: CertTrust = CertTrust(),
         onUntrustedCertificate: ((CertificatePrompt) -> Void)? = nil,
         configuration: URLSessionConfiguration = URLSessionTransport.defaultConfiguration()) {
        self.origin = serverURL.absoluteString
        self.delegate = TransportSessionDelegate(serverURL: serverURL,
                                                 certTrust: certTrust,
                                                 onUntrustedCertificate: onUntrustedCertificate)
        self.session = URLSession(configuration: configuration,
                                  delegate: delegate,
                                  delegateQueue: nil)
        super.init()
    }

    deinit {
        session.invalidateAndCancel()
    }

    static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["X-Requested-With": "XMLHttpRequest"]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 10
        return configuration
    }

    func send(_ request: APIRequest) async throws -> APIResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request.urlRequest())
        } catch let error as APITransportError {
            throw error
        } catch let error as URLError {
            throw Self.map(error, origin: origin)
        } catch {
            throw APITransportError.other(error.localizedDescription)
        }
        return try Self.convert(data: data, response: response)
    }

    /// The upload direction: same request, same TLS decision, plus `didSendBodyData`.
    ///
    /// `URLSession.upload(for:from:delegate:)` hands task-level callbacks (which include the byte
    /// counter) to `delegate`, while server-trust challenges still go to the session's own delegate —
    /// so a self-signed server that the user trusted for the webview is trusted here too, and the
    /// progress numbers come from the stack rather than from a timer that assumes a throughput.
    func send(_ request: APIRequest,
              onSendProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> APIResponse {
        let progressDelegate = UploadProgressDelegate(onProgress: onSendProgress)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request.urlRequest(),
                                                       from: request.body ?? Data(),
                                                       delegate: progressDelegate)
        } catch let error as APITransportError {
            throw error
        } catch let error as URLError {
            throw Self.map(error, origin: origin)
        } catch {
            throw APITransportError.other(error.localizedDescription)
        }
        // The delegate is only referenced by the running task; keep it alive until the response is in.
        withExtendedLifetime(progressDelegate) {}
        return try Self.convert(data: data, response: response)
    }

    /// Shared response handling for both directions.
    private static func convert(data: Data, response: URLResponse) throws -> APIResponse {
        guard let http = response as? HTTPURLResponse else {
            throw APITransportError.other("non-HTTP response")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let name = key as? String, let text = value as? String { headers[name] = text }
        }
        return APIResponse(statusCode: http.statusCode, headers: headers, body: data)
    }

    static func map(_ error: URLError, origin: String) -> APITransportError {
        switch error.code {
        case .timedOut:
            return .timeout
        case .cancelled:
            return .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
             .callIsActive:
            return .offline
        // `secureConnectionFailed` is what Apple's stack reports when the TLS handshake is
        // refused below the trust layer (a declined or untrusted self-signed chain on some
        // configurations reports -1200 rather than -1202). It is grouped with the certificate
        // failures so the UI surfaces the cert prompt path instead of "you are offline".
        case .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
             .clientCertificateRejected, .clientCertificateRequired, .secureConnectionFailed:
            return .certificateUntrusted(origin: origin)
        default:
            return .other(error.localizedDescription)
        }
    }
}

/// The one `URLSession` delegate both transports use: TLS server-trust for HTTP and for `wss`,
/// plus the WebSocket open/close callbacks `URLSessionWebSocketTask` needs.
///
/// Kept as a separate object from the transports on purpose: `URLSession` retains its delegate, so
/// a transport that made itself the delegate could never deallocate.
final class TransportSessionDelegate: NSObject, URLSessionDelegate, URLSessionWebSocketDelegate {

    private let certTrust: CertTrust
    private let serverURL: URL
    private let onUntrustedCertificate: ((CertificatePrompt) -> Void)?

    /// Set by `WebSocketTransport` to learn when the socket is actually open: `URLSession` has no
    /// other reliable "open" signal for `URLSessionWebSocketTask`.
    var onWebSocketOpen: ((URLSessionWebSocketTask) -> Void)?
    var onWebSocketClose: ((URLSessionWebSocketTask, URLSessionWebSocketTask.CloseCode, Data?) -> Void)?

    init(serverURL: URL,
         certTrust: CertTrust,
         onUntrustedCertificate: ((CertificatePrompt) -> Void)?) {
        self.serverURL = serverURL
        self.certTrust = certTrust
        self.onUntrustedCertificate = onUntrustedCertificate
        super.init()
    }

    // MARK: Server trust

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let space = challenge.protectionSpace
        let trust = space.serverTrust
        let systemValidates = trust.map { SecTrustEvaluateWithError($0, nil) } ?? false
        let presented = ServerTrustPolicy.leafCertificate(from: trust)
        let origin = ServerTrustPolicy.originURL(host: space.host, port: space.port) ?? serverURL
        let recorded = certTrust.trustedCertificate(for: origin)
        let explicitlyUntrusted = certTrust.isExplicitlyUntrusted(for: origin)

        let decision = ServerTrustPolicy.decision(challengeHost: space.host,
                                                  serverHost: serverURL.host,
                                                  systemValidates: systemValidates,
                                                  presented: presented?.certificate,
                                                  recorded: recorded,
                                                  explicitlyUntrusted: explicitlyUntrusted)
        switch decision {
        case .performDefaultHandling:
            completionHandler(.performDefaultHandling, nil)
        case .accept:
            guard let trust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
            MMLog.info("MMTransport", "accepted previously-trusted certificate for \(space.host)")
        case .reject:
            completionHandler(.cancelAuthenticationChallenge, nil)
            MMLog.info("MMTransport", "rejected explicitly-untrusted certificate for \(space.host)")
        case .prompt:
            if let presented {
                let prompt = CertificatePrompt(origin: origin,
                                               certificate: presented.certificate,
                                               info: presented.info)
                onUntrustedCertificate?(prompt)
            }
            // Default handling still fails the request (typed `.certificateUntrusted`), which is
            // what the caller needs while the sheet is up. The retry after the user trusts the
            // certificate is accepted by the `.accept` branch above.
            completionHandler(.performDefaultHandling, nil)
            MMLog.info("MMTransport", "unseen certificate for \(space.host) -> prompting")
        }
    }

    // MARK: WebSocket lifecycle

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        onWebSocketOpen?(webSocketTask)
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        onWebSocketClose?(webSocketTask, closeCode, reason)
    }
}

/// The per-upload task delegate that turns `didSendBodyData` into one callback.
///
/// It exists as its own object because `URLSessionTaskDelegate` callbacks for a single task must not
/// be routed through the session's shared `TransportSessionDelegate` — that object is the *TLS*
/// decision point and lives for the whole app; upload callbacks are per request and must be thrown
/// away with it (otherwise two concurrent uploads would share one progress closure).
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let onProgress: @Sendable (Int64, Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        onProgress(totalBytesSent, totalBytesExpectedToSend)
    }
}
