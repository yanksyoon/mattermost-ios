import Foundation
import WebKit
import Combine

/// Maps each configured server (by uuid) to its own `WKWebView` + **isolated** persistent
/// `WKWebsiteDataStore`. Native counterpart of desktop `ViewManager` (`views/viewManager.ts`):
/// one web contents view per server, with a tracked "primary" view.
/// Parity row: `ViewManager` -> `ViewStore`. Status: native, P1.2/P1.3.
///
/// Why a store per server: the shell keeps every server's webview alive for the app's lifetime
/// (desktop keeps tabs' web contents alive too), so switching back to a server is instant and
/// does not re-run sign-in. Isolation comes from `WKWebsiteDataStore(forIdentifier:)` keyed by
/// the server's uuid — cookies, localStorage and IndexedDB (i.e. the Mattermost session) are
/// strictly per-server, so two servers can be signed in as different users simultaneously.
@MainActor
final class ViewStore: ObservableObject {

    /// The server whose scene is currently on screen. Drives which scene is visible; the other
    /// scenes stay mounted (hidden) so their webviews keep their state.
    @Published private(set) var primaryServerID: UUID?

    /// Per-server webview stores. Deliberately **not** `@Published`: views call `view(for:)`
    /// while building their body, and publishing from inside a body update would loop.
    /// Scene identity is driven by `ServerStore.servers` instead.
    private(set) var stores: [UUID: WebViewStore] = [:]

    init() {}

    // MARK: Access

    /// The store for a server, created on first use and reused afterwards. Calling this twice
    /// for the same server returns the identical instance (session continuity).
    func view(for server: ServerConfig) -> WebViewStore {
        if let existing = stores[server.id] { return existing }
        let store = WebViewStore(dataStoreIdentifier: server.id)
        stores[server.id] = store
        return store
    }

    func view(forServerID id: UUID) -> WebViewStore? {
        stores[id]
    }

    /// All mounted stores, ordered by the servers' display order.
    func mountedStores(for servers: [ServerConfig]) -> [WebViewStore] {
        servers.compactMap { stores[$0.id] }
    }

    // MARK: Primary view

    func setPrimary(_ serverID: UUID) {
        primaryServerID = serverID
    }

    // MARK: Removal

    /// Tear down a removed server: drop its webview and delete its isolated on-disk data store
    /// (desktop's `ServerManager.removeServer` also purges that server's session/config).
    func remove(serverID: UUID) {
        stores[serverID] = nil
        if primaryServerID == serverID { primaryServerID = nil }
        Task {
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: serverID)
                Logger.info("ViewStore", "purged data store for removed server \(serverID)")
            } catch {
                // Purge failures are not fatal: the server is already gone from the shell, and
                // an orphaned data store is invisible to the user (it is keyed by a dead uuid).
                Logger.error("ViewStore", "failed to purge data store \(serverID): \(error)")
            }
        }
        Logger.info("ViewStore", "removed server \(serverID) and released its webview")
    }
}
