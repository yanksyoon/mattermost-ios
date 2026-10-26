// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: `app/screens/home/search/` (one screen, one state per team), `app/screens/saved_posts/`,
//        `app/screens/pinned_messages/`, `app/actions/websocket/preferences.ts` (a preference change
//        is pushed to open lists), `app/actions/websocket/posts.ts` (`post_edited` patches a row).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §16; no
// upstream source copied. The coordinator decomposition mirrors T33's `ChannelSidebarCoordinator` and
// T34's `ChannelPaneCoordinator` (one owner, one model per key, no socket of its own), which is this
// repo's convention (component-map.md §1).
//
// Why a coordinator and not `@StateObject` in the tab:
//  - a tab switch, a push and a rotation re-create the view; a model that died with it would lose the
//    result list (and re-run the search) on every visit to the sidebar;
//  - the saved/pinned lists are patched by the app's single per-server socket
//    (`TeamSidebarCoordinator.onTeamEvent`), which a view cannot subscribe to.

import Foundation
import Combine

@MainActor
final class SearchCoordinator: ObservableObject {

    private var auth: AuthCoordinator?
    private var serverStore: ServerStore?
    /// Test seam: replaces the production session-backed service (T33/T34's `serviceFactory` shape).
    var serviceFactory: ((ServerConfig) -> SearchServing)?
    /// Test seam: replaces the recent-search store, so a test does not write a defaults domain.
    var recentStoreFactory: ((String) -> RecentSearchStoring)?

    /// One search model per (server, team): the same reader on two teams keeps two histories.
    private var searches: [String: SearchViewModel] = [:]
    /// One saved list per server (team-scoped by the model's `teamID`).
    private var savedLists: [UUID: PostCollectionViewModel] = [:]
    /// One pinned list per (server, channel).
    private var pinnedLists: [UUID: [String: PostCollectionViewModel]] = [:]

    var modelCount: Int {
        searches.count + savedLists.count + pinnedLists.values.reduce(0) { $0 + $1.count }
    }

    func bind(auth: AuthCoordinator?, serverStore: ServerStore?) {
        self.auth = auth
        self.serverStore = serverStore
    }

    // MARK: - Models

    func search(for server: ServerConfig, teamID: String) -> SearchViewModel {
        let key = "\(server.id.uuidString).\(teamID)"
        if let existing = searches[key] { return existing }
        let storeKey = UserDefaultsRecentSearchStore.key(serverID: server.id, teamID: teamID)
        let store = recentStoreFactory?(storeKey) ?? UserDefaultsRecentSearchStore()
        let model = SearchViewModel(service: service(for: server),
                                    recents: RecentSearchesStore(store: store, key: storeKey),
                                    myUserID: auth?.userID(for: server.id))
        model.teamID = teamID
        searches[key] = model
        return model
    }

    func saved(for server: ServerConfig) -> PostCollectionViewModel {
        if let existing = savedLists[server.id] { return existing }
        let model = PostCollectionViewModel(kind: .saved,
                                            service: service(for: server),
                                            myUserID: auth?.userID(for: server.id))
        savedLists[server.id] = model
        return model
    }

    func pinned(for server: ServerConfig, channelID: String) -> PostCollectionViewModel {
        if let existing = pinnedLists[server.id]?[channelID] { return existing }
        let model = PostCollectionViewModel(kind: .pinned,
                                            service: service(for: server),
                                            myUserID: auth?.userID(for: server.id))
        model.channelID = channelID
        pinnedLists[server.id, default: [:]][channelID] = model
        return model
    }

    /// Forget one channel's pinned list (the channel pane is gone; the list is rebuilt from the server
    /// on the next open, and nothing is written back).
    func forgetPinned(serverID: UUID, channelID: String) {
        pinnedLists[serverID]?[channelID] = nil
    }

    // MARK: - The socket

    /// One event from the server's socket (already scoped to the team on screen by the rail).
    ///
    /// Only the collection lists care: a search result set is a snapshot of a query, and re-running it
    /// on every `posted` would be a request per message on the server. Saved/pinned lists *are* live —
    /// a preference change or a pin from another device must show up.
    func handle(_ event: SocketEvent, serverID: UUID) {
        if let saved = savedLists[serverID] {
            saved.handle(event)
        }
        for (_, model) in pinnedLists[serverID] ?? [:] {
            model.handle(event)
        }
    }

    /// Sign-out / expiry / server removal: drop everything fetched with that credential.
    func authPhaseChanged(_ serverID: UUID) {
        deactivate(serverID)
    }

    func deactivate(_ serverID: UUID) {
        let prefix = serverID.uuidString + "."
        for key in searches.keys where key.hasPrefix(prefix) {
            searches[key] = nil
        }
        savedLists[serverID] = nil
        pinnedLists[serverID] = nil
    }

    // MARK: - Service

    private func service(for server: ServerConfig) -> SearchServing {
        if let serviceFactory { return serviceFactory(server) }
        let auth = self.auth
        return SessionSearchService {
            guard let auth, let session = try? auth.session(for: server) else { return nil }
            return session.client
        }
    }
}
