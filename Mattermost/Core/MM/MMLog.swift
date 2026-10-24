import Foundation
import os.log

/// Token-safe logging for the native transport layer (T28).
///
/// The card's acceptance criterion is "no token in any log line". Two defences, both tested:
///
///  1. **Never log the material.** `APIClient` / `AuthSession` / `SocketClient` log a method, a
///     path, a status code and a typed error — never a request/response body, a header bag, or a
///     WebSocket frame. The `MMLog` surface is the only logging entry point in `Core/MM`.
///  2. **Redact what a caller might smuggle in.** A server-controlled error message (`message`,
///     `detailed_error`) or a URL that some caller built with a credential in it can embed a
///     token. `redact(_:)` strips the credential shapes below before the line reaches `Logger`,
///     so a future call site cannot leak by accident.
///
/// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0,
/// `app/utils/log.ts` — own implementation per docs/path-b-adr.md §3. The mobile client carries
/// the same concern (`logWarning(msg)` on a failed socket reply would print `seq_reply` frames);
/// this layer refuses to log frames at all.
enum MMLog {

    /// `Bearer <credential>` in any casing.
    private static let bearerPattern = try? NSRegularExpression(
        pattern: "(?i)bearer\\s+[A-Za-z0-9._~+/=-]+", options: [])

    /// `token=…`, `"token": "…"`, `Authorization: …`, `MMAUTHTOKEN=…`, `preauth_secret=…`.
    /// The value stops at whitespace, a quote, a comma, a semicolon or a closing brace.
    private static let keyValuePattern = try? NSRegularExpression(
        pattern: "(?i)(mmauthtoken|authorization|preauth_secret|preauthsecret|token|password|login_id)"
            + "(\\s*[\"']?\\s*[:=]\\s*[\"']?)([^\"',;}\\s&]+)",
        options: [])

    private static let lock = NSLock()

    /// Replace every credential-shaped substring with `<redacted>`. Pure and idempotent, so the
    /// redaction itself is unit-testable without touching `Logger`.
    static func redact(_ message: String) -> String {
        var out = message
        lock.lock()
        defer { lock.unlock() }
        if let bearerPattern {
            out = bearerPattern.stringByReplacingMatches(
                in: out, options: [], range: NSRange(out.startIndex..., in: out),
                withTemplate: "Bearer <redacted>")
        }
        if let keyValuePattern {
            out = keyValuePattern.stringByReplacingMatches(
                in: out, options: [], range: NSRange(out.startIndex..., in: out),
                withTemplate: "$1$2<redacted>")
        }
        return out
    }

    static func debug(_ category: String, _ message: String) {
        Logger.debug(category, redact(message))
    }

    static func info(_ category: String, _ message: String) {
        Logger.info(category, redact(message))
    }

    static func error(_ category: String, _ message: String) {
        Logger.error(category, redact(message))
    }
}
