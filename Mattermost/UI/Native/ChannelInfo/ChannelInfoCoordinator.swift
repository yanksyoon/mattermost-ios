// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/channel_info/index.ts (one screen instance per channel, rebuilt from the server on
//        each open), app/actions/websocket/channel.ts + users.ts (`user_added`, `user_removed`,
//        `channel_updated`, `channel_deleted`, `channel_restored` handlers), and
//        app/actions/websocket/index.ts (the single socket per server).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §17; no
// upstream source copied. The coordinator decomposition mirrors T33's `ChannelSidebarCoordinator` and
// T34's `ChannelPaneCoordinator` (one owner, one model per key, one socket), which is this repo's
// convention (component-map.md §1).
//
// Why a coordinator and not a `@StateObject` in the screen:
//  - the screen is re-created on every sheet presentation, and a model that dies with it would re-read
//    the member list and the permission union on every open;
//  - `user_added` / `user_removed` / `channel_updated` arrive on the rail's socket
//    (`TeamSidebarCoordinator.onTeamEvent`), which is the app's single WebSocket per server — a view
//    cannot be the subscriber without owning a socket.
//
// The cache is bounded (LRU, 4 channels per server): the info screen of a channel the reader has moved
// away from holds a member list and a permission union, and forty of those is not a cache. Eviction is
// safe because every model is rebuilt from the server on the next open (nothing is written back).

import Foundation
import Combine

/// Owns one `ChannelInfoViewModel` per (server, channel) and one `BrowseChannelsViewModel` per
/// (server, team), and routes the rail's socket events into them.
@MainActor
final class ChannelInfoCoordinator: ObservableObject {

    /// How many channel-info models keep their member list warm per server.
    static let warmChannelLimit = 4

    private var auth: AuthCoordinator?
    private var navigation: NativeNavigation?
    private var serverStore: ServerStore?

    private var models: [UUID: [String: ChannelInfoViewModel]] = [:]
    /// Most-recently-opened channel ids per server, newest last.
    private var recent: [UUID: [String]] = [:]
    private var browseModels: [UUID: [String: BrowseChannelsViewModel]] = [:]

    /// Test seam: replaces the production session-backed service (T33's `serviceFactory`).
    var serviceFactory: ((ServerConfig) -> ChannelInfoServing)?

    /// Diagnostics: how many channel models are alive (one test asserts the cache is bounded).
    var modelCount: Int { models.values.reduce(0) { $0 + $1.count } }

    func bind(auth: AuthCoordinator?, navigation: NativeNavigation?, serverStore: ServerStore?) {
        self.auth = auth
        self.navigation = navigation
        self.serverStore = serverStore
    }

    // MARK: Models

    /// The info model for one channel, created on first use.
    func model(for server: ServerConfig,
               channelID: String,
               teamID: String,
               title: String?) -> ChannelInfoViewModel {
        if let existing = models[server.id]?[channelID] {
            // A title can arrive after the model was created (the channel pane learns it from the first
            // page); the model keeps the first non-empty one it was given.
            touch(serverID: server.id, channelID: channelID)
            return existing
        }
        let model = ChannelInfoViewModel(channelID: channelID,
                                         teamID: teamID,
                                         fallbackTitle: title,
                                         service: service(for: server))
        models[server.id, default: [:]][channelID] = model
        touch(serverID: server.id, channelID: channelID)
        evictIfNeeded(serverID: server.id)
        return model
    }

    /// The browse model for one team, created on first use.
    func browseModel(for server: ServerConfig, teamID: String) -> BrowseChannelsViewModel {
        if let existing = browseModels[server.id]?[teamID] { return existing }
        let model = BrowseChannelsViewModel(teamID: teamID, service: service(for: server))
        browseModels[server.id, default: [:]][teamID] = model
        return model
    }

    /// Drop one channel's model (after a leave or an archive, so a re-open re-reads the truth).
    func forget(serverID: UUID, channelID: String) {
        models[serverID]?[channelID] = nil
        recent[serverID]?.removeAll { $0 == channelID }
    }

    // MARK: Socket

    /// One event from the server's socket. Delivered by `TeamSidebarCoordinator.onTeamEvent`, i.e. the
    /// app's single WebSocket per server.
    func handle(_ event: SocketEvent, serverID: UUID) {
        // A membership/rename/archive event only matters to a screen that is open; an empty cache means
        // nothing to tell.
        if let byChannel = models[serverID], !byChannel.isEmpty {
            for (_, model) in byChannel {
                model.handle(event: event)
            }
        }
        // A channel appearing or being archived changes what the browser lists.
        switch event {
        case .channelCreated, .channelDeleted, .channelRestored, .userAdded, .userRemoved:
            for (_, model) in browseModels[serverID] ?? [:] {
                Task { await model.load() }
            }
        default:
            break
        }
    }

    /// Sign-out / expiry / server removal: drop everything this credential built.
    func deactivate(_ serverID: UUID) {
        models[serverID] = nil
        recent[serverID] = nil
        browseModels[serverID] = nil
    }

    func authPhaseChanged(_ serverID: UUID) {
        deactivate(serverID)
    }

    // MARK: Internals

    private func service(for server: ServerConfig) -> ChannelInfoServing {
        if let serviceFactory { return serviceFactory(server) }
        let auth = self.auth
        return SessionChannelInfoService {
            guard let auth, let session = try? auth.session(for: server) else { return nil }
            return session.client
        }
    }

    /// The service a sheet builds its own view model on (the add-members picker), so it resolves the
    /// session exactly like the info model does — one rule for how a screen gets a client.
    func serviceForSheet(_ server: ServerConfig) -> ChannelInfoServing { service(for: server) }

    private func touch(serverID: UUID, channelID: String) {
        var list = recent[serverID] ?? []
        list.removeAll { $0 == channelID }
        list.append(channelID)
        recent[serverID] = list
    }

    private func evictIfNeeded(serverID: UUID) {
        guard let list = recent[serverID], list.count > Self.warmChannelLimit else { return }
        let excess = list.count - Self.warmChannelLimit
        for channelID in list.prefix(excess) {
            models[serverID]?[channelID] = nil
        }
        recent[serverID] = Array(list.dropFirst(excess))
    }
}
