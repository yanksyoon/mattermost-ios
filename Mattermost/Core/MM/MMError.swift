// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0, `app/client/rest/error.ts` and
// `Network+Error.swift` — own typed vocabulary per docs/path-b-adr.md §3.

import Foundation

/// The transport's typed error vocabulary.
///
/// Every failure a native screen must react to differently has its own case, because the four
/// reactions are genuinely different:
///
///  - `.unauthorized` → surface re-auth (`AuthSession.needsReauth`), never silently retry.
///  - `.forbidden` / `.notFound` → the screen is wrong or the user lost access; do not retry.
///  - `.rateLimited` → retry after the server's `Retry-After`; the client already does, and the
///    case survives exhaustion so a caller can show "try again in Ns".
///  - `.timeout` / `.offline` → a retryable transport failure; retried for idempotent GETs.
///  - `.certificateUntrusted` → present `CertPromptSheet`; retrying before the user decides is
///    pointless, so this is deliberately NOT retried.
///
/// `message` carries the server's human-readable `message` only (already redacted at the log
/// boundary; it is never logged here at all).
enum MMError: Error, Equatable {
    case unauthorized(message: String?)
    case forbidden(message: String?)
    case notFound
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int, message: String?)
    case client(status: Int, message: String?)
    case mfaRequired(message: String?)
    case timeout
    case offline
    case certificateUntrusted(origin: String)
    case cancelled
    case malformedResponse(String)
    case transport(String)
    case invalidURL(String)
    case notSignedIn
    /// The server's MFA challenge came back for a request that already carried an MFA token.
    case invalidMFA(message: String?)
}

extension MMError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Your session has expired. Please sign in again."
        case .forbidden: return "You do not have permission to do that."
        case .notFound: return "That item no longer exists."
        case .rateLimited(let retryAfter):
            if let retryAfter { return "The server is busy. Try again in \(Int(retryAfter.rounded()))s." }
            return "The server is busy. Try again shortly."
        case .server(let status, let message):
            return message ?? "The server had a problem (\(status))."
        case .client(_, let message): return message ?? "That request was rejected."
        case .mfaRequired: return "Enter your multi-factor authentication code."
        case .invalidMFA(let message): return message ?? "That authentication code was not accepted."
        case .timeout: return "The server took too long to respond."
        case .offline: return "You appear to be offline."
        case .certificateUntrusted(let origin):
            return "The certificate presented by \(origin) is not trusted yet."
        case .cancelled: return "The request was cancelled."
        case .malformedResponse: return "The server sent a response this app could not read."
        case .transport: return "Could not reach the server."
        case .invalidURL: return "That server address is not valid."
        case .notSignedIn: return "You are not signed in."
        }
    }
}

/// Transport-level failures, before any HTTP semantics exist. Kept separate from `MMError` so the
/// retry policy can decide on `APITransportError` alone, and so a test fake can return exactly
/// the failure a real `URLSession` would.
enum APITransportError: Error, Equatable {
    case timeout
    case offline
    case cancelled
    /// TLS chain rejected by `NSURLSession` (or by our trust delegate). The prompt to resolve it
    /// is emitted separately through `URLSessionTransport.onUntrustedCertificate`.
    case certificateUntrusted(origin: String)
    case other(String)
}
