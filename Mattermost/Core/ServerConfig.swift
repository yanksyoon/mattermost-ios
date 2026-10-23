import Foundation

/// A configured Mattermost server (native counterpart of desktop `MattermostServer.ts` /
/// `ServerManager`). Parity row: `ServerManager` -> `ServerStore` (P0/P1 above represents the
/// store; this is the per-server model). Status: native, P0.1.
public struct ServerConfig: Codable, Identifiable, Equatable, Hashable {
    /// Stable identity. The desktop app keys servers by uuid too.
    public var id: UUID
    public var name: String
    public var url: URL
    /// Display order in the server switcher.
    public var order: Int
    /// When the user last switched to this server (drives "select last active" on launch).
    public var lastActiveAt: Date
    /// Whether a session/token exists for this server (drives badge/session-expired states).
    public var hasSession: Bool

    public init(id: UUID = UUID(),
                name: String,
                url: URL,
                order: Int = 0,
                lastActiveAt: Date = .distantPast,
                hasSession: Bool = false) {
        self.id = id
        self.name = name
        self.url = url
        self.order = order
        self.lastActiveAt = lastActiveAt
        self.hasSession = hasSession
    }
}

/// URL helpers — native counterpart of desktop `utils/url.ts`.
enum ServerURL {
    /// Normalize a raw user-entered string into a Mattermost server base URL.
    /// Applies the same defaulting the desktop add-server form does:
    /// - trims whitespace
    /// - requires a scheme, defaulting to https when absent
    /// - strips a trailing slash so hosts read `https://community.mattermost.com`.
    ///
    /// Throws `ServerURLError` when the input is empty or cannot form a valid https URL.
    static func normalize(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ServerURLError.empty }

        var candidate = trimmed
        // The desktop add-server form defaults a schemeless host to https (never http).
        if !candidate.lowercased().hasPrefix("http://") && !candidate.lowercased().hasPrefix("https://") {
            candidate = "https://" + candidate
        }
        guard let components = URLComponents(string: candidate),
              let host = components.host, !host.isEmpty else {
            throw ServerURLError.invalid
        }

        // Rebuild cleanly: normalize scheme case, drop an empty path, keep explicit port.
        var out = URLComponents()
        out.scheme = (components.scheme ?? "https").lowercased()
        out.host = components.host
        out.port = components.port
        out.path = trimmedPath(components.path)
        guard let url = out.url else { throw ServerURLError.invalid }
        return url
    }

    private static func trimmedPath(_ path: String) -> String {
        var p = path
        while p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

enum ServerURLError: LocalizedError {
    case empty
    case invalid

    var errorDescription: String? {
        switch self {
        case .empty: return "Please enter a server URL."
        case .invalid: return "That doesn't look like a valid server URL."
        }
    }
}