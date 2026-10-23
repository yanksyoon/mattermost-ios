import Foundation
import Combine

/// Registry of configured Mattermost servers. Native counterpart of desktop `ServerManager`
/// (`servers/serverManager.ts`, `servers/MattermostServer.ts`). Parity row:
/// `ServerManager` -> `ServerStore` (ObservableObject, `@Published [ServerConfig]`, CRUD,
/// uuid/server, events mirror `SERVER_ADDED/REMOVED/SWITCHED`). Status: native, P0.1.
final class ServerStore: ObservableObject {

    /// Pushed on every mutation and on launch so downstream (UI, ViewStore) can observe events.
    enum Event {
        case added(ServerConfig)
        case removed(ServerConfig)
        case updated(ServerConfig)
        case switched(ServerConfig)
    }

    @Published private(set) var servers: [ServerConfig] = []
    @Published var activeServerID: UUID? {
        didSet { persistActiveServer() }
    }

    private let preferences: AppPreferences
    private let eventSubject = PassthroughSubject<Event, Never>()

    /// Observable stream of server lifecycle events (mirrors desktop `SERVER_*` IPC events).
    var events: AnyPublisher<Event, Never> {
        eventSubject.eraseToAnyPublisher()
    }

    init(preferences: AppPreferences = AppPreferences()) {
        self.preferences = preferences
        load()
    }

    // MARK: Queries

    var activeServer: ServerConfig? {
        guard let id = activeServerID else { return nil }
        return servers.first { $0.id == id }
    }

    /// Server that should be shown on launch: last-active wins, else first by order.
    var initialServer: ServerConfig? {
        if let lastActive = servers.sorted(by: { $0.lastActiveAt > $1.lastActiveAt }).first,
           lastActive.lastActiveAt != .distantPast {
            return lastActive
        }
        return servers.sorted { $0.order < $1.order }.first
    }

    // MARK: Mutations

    /// Normalised host (or `host:port` when a non-default port is set). Used for the
    /// duplicate check below, mirroring desktop `ServerManager`'s ``host``-keyed registry:
    /// two servers pointing at the same host would be ambiguous in the switcher and confuse
    /// which session/badge belongs to which row.
    private func identityKey(for url: URL) -> String {
        var base = url.host ?? ""
        // Only a *non-default* port makes the host ambiguous with another server. `https://a`
        // and `https://a:443` are the same host (desktop ServerManager keys by host), so the
        // default HTTPS/HTTP ports are collapsed before comparison.
        if let port = url.port, port != defaultPort(forScheme: url.scheme) {
            base += ":\(port)"
        }
        return base.lowercased()
    }

    private func defaultPort(forScheme scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    /// Whether a server already targets the same host as `config` (case/port-insensitive).
    func containsServer(withSameHostAs config: ServerConfig) -> Bool {
        let key = identityKey(for: config.url)
        return servers.contains { identityKey(for: $0.url) == key }
    }

    /// Port of desktop `ServerManager.lookupServerByURL(inputURL, ignoreScheme)` used by the
    /// add-server form's URL validation: find the configured server whose URL matches `candidate`
    /// (optionally ignoring scheme, mirroring the desktop `true` argument when checking a
    /// secure/probed URL). Two servers share a URL when their hosts match and the candidate's path
    /// falls within the server's configured path.
    func lookupServer(by candidate: URL, ignoringScheme: Bool = false) -> ServerConfig? {
        servers.first { config in
            let candidateHost = (candidate.host ?? "").lowercased()
            let serverHost = (config.url.host ?? "").lowercased()
            guard candidateHost == serverHost else { return false }

            if !ignoringScheme, candidate.scheme?.lowercased() != config.url.scheme?.lowercased() {
                return false
            }

            let candidatePath = formattedPath(candidate.path)
            let serverPath = formattedPath(config.url.path)
            return candidatePath.hasPrefix(serverPath)
        }
    }

    private func formattedPath(_ path: String) -> String {
        path.isEmpty ? "/" : path.hasSuffix("/") ? path : path + "/"
    }

    /// Whether the server list has ever been persisted (true even if every server was later
    /// removed). Lets the UI distinguish a genuine first launch from an intentionally-emptied
    /// list so it doesn't re-seed defaults.
    var hasEverConfiguredServers: Bool {
        preferences.contains(AppPreferences.Keys.servers)
    }

    /// Register a new server. Returns the stored `ServerConfig`, or `nil` when the host is
    /// already configured (mirrors desktop `ServerManager.addServer` refusing duplicates).
    @discardableResult
    func add(_ config: ServerConfig) -> ServerConfig? {
        guard !containsServer(withSameHostAs: config) else {
            Logger.info("ServerStore", "rejected duplicate server for host \(config.url.host ?? config.url.absoluteString)")
            return nil
        }
        var config = config
        config.order = servers.count
        servers.append(config)
        save()
        eventSubject.send(.added(config))
        return config
    }

    func update(_ config: ServerConfig) {
        guard let idx = servers.firstIndex(where: { $0.id == config.id }) else { return }
        servers[idx] = config
        save()
        eventSubject.send(.updated(config))
    }

    @discardableResult
    func remove(id: UUID) -> ServerConfig? {
        guard let idx = servers.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = servers.remove(at: idx)
        if activeServerID == removed.id { activeServerID = servers.first?.id }
        save()
        eventSubject.send(.removed(removed))
        return removed
    }

    func switchTo(id: UUID) {
        guard let idx = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[idx].lastActiveAt = Date()
        activeServerID = id
        save()
        eventSubject.send(.switched(servers[idx]))
    }

    // MARK: Persistence

    private func save() {
        preferences.set(servers, forKey: AppPreferences.Keys.servers)
    }

    private func load() {
        servers = preferences.get([ServerConfig].self, forKey: AppPreferences.Keys.servers) ?? []
        activeServerID = loadActiveServerID() ?? initialServer?.id
    }

    private func persistActiveServer() {
        guard let id = activeServerID else { return }
        preferences.set(id.uuidString, forKey: AppPreferences.Keys.servers + ".active")
    }

    private func loadActiveServerID() -> UUID? {
        guard let raw = preferences.string(forKey: AppPreferences.Keys.servers + ".active") else { return nil }
        return UUID(uuidString: raw)
    }
}