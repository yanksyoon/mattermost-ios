// Profiles the shell has already paid for.
//
// Why this exists (card t_c0e42801): a DM row's label is the *other* person's name, and the only
// source of that name is a profile. Every screen that draws a person — the channel timeline, a
// thread, the member list — already fetches those profiles with `POST /users/ids`; the sidebar then
// asked for the same ids again, from scratch, on every load. On a workspace with hundreds of direct
// messages that repeat request is the slowest step of the sidebar load, and it sat inside the load's
// deadline. Remembering what has already been fetched makes most of it free.
//
// Scope, deliberately narrow:
//  - **Per server.** `id`s are minted per instance, so two servers in the same process must never
//    answer for each other. The registry is keyed by `ServerConfig.id`, not by user id.
//  - **In memory only.** This is a cache, not a store: a relaunch starts empty and pays the requests
//    again (chunked — see `APIClient.users(ids:)`). Persisting it is a separate decision.
//  - **Not authority.** A stale profile is still a name, and the server's fresh answer overwrites it
//    (the underlying store keeps the higher `update_at`), so a rename reaches a row on the next fetch.

import Foundation

/// What has been learned about people on one server, kept for the lifetime of the process.
@MainActor
final class UserProfileCache {

    /// One cache per server, created on first use.
    ///
    /// A registry rather than an injected object because the two readers sit in different
    /// coordinators (`ChannelPaneCoordinator` owns the timeline that fetches the profiles,
    /// `ChannelSidebarCoordinator` owns the list that needs the names) and a profile is not a
    /// property of either screen. Sign-out drops the server's entry (`forget(serverID:)`).
    private static var registry: [UUID: UserProfileCache] = [:]

    static func shared(for serverID: UUID) -> UserProfileCache {
        if let existing = registry[serverID] { return existing }
        let cache = UserProfileCache()
        registry[serverID] = cache
        return cache
    }

    /// Sign-out, expiry, server removal: nothing this server fetched is reused.
    static func forget(serverID: UUID) {
        registry[serverID] = nil
    }

    /// Test seam: forget every server's profiles.
    static func forgetAll() {
        registry.removeAll()
    }

    /// The backing store. `InMemoryStore` (T29) already answers "give me these ids" in one locked
    /// pass and keeps the newer `update_at`, so there is no second dictionary to maintain here.
    private let store: InMemoryStore

    init(store: InMemoryStore = InMemoryStore()) {
        self.store = store
    }

    /// The profiles already in hand for `ids`; ids that were never fetched are simply absent.
    func known(ids: [String]) -> [MMUser] {
        guard !ids.isEmpty else { return [] }
        return store.users(ids: ids)
    }

    func known(id: String) -> MMUser? {
        store.user(id)
    }

    /// Record profiles a request (or the signed-in user's own session) just produced.
    func remember(_ users: [MMUser]) {
        users.forEach(store.upsertUser)
    }

    /// Diagnostics: how many profiles this server's cache holds.
    func count() -> Int { store.userCount() }
}
