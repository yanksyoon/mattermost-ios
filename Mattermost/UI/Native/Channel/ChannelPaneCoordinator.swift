// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/channel/channel.tsx (one mounted channel screen at a time; it owns the post list
//        state and is torn down on channel switch), app/actions/websocket/posts.ts (the channel's
//        list is patched by posted/post_edited/post_deleted/reaction_* as they arrive),
//        app/screens/channel/actions.ts (a channel switch loads the new channel's first page).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §10; no
// upstream source copied. The coordinator decomposition mirrors T33's `ChannelSidebarCoordinator`
// (one owner, one model per key, one socket), which is this repo's convention (component-map.md §1).
//
// Why a coordinator and not a `@StateObject` in the view:
//  - the view is re-created on every navigation (a push, a detail-column swap, a rotation), and a
//    model that dies with it would refetch the page and lose the reader's scroll position;
//  - `posted` arrives on the rail's socket (`TeamSidebarCoordinator.onTeamEvent`), which is the
//    app's single WebSocket per server — a view cannot be the subscriber without owning a socket.
//
// The model cache is bounded (LRU, 6 channels per server): a session that opens forty channels must
// not keep forty pages of posts alive. Eviction is safe because a model is rebuilt from the server on
// the next appearance (nothing is written back to the store).

import Foundation
import Combine

/// Owns one `ChannelViewModel` per (server, channel) and routes the rail's socket events into them.
@MainActor
final class ChannelPaneCoordinator: ObservableObject {

    /// How many channels keep a warm window per server.
    static let warmChannelLimit = 6

    private var auth: AuthCoordinator?
    private var navigation: NativeNavigation?
    private var serverStore: ServerStore?

    private var models: [UUID: [String: ChannelViewModel]] = [:]
    /// Most-recently-activated channel ids per server, newest last.
    private var recent: [UUID: [String]] = [:]
    private var imageStores: [UUID: ChannelImageStore] = [:]
    private var emojiCatalogues: [UUID: EmojiCatalogue] = [:]
    /// T38: per-server attachment download state (shares the app's one `DownloadWorker` journal).
    private var attachmentDownloadsStores: [UUID: AttachmentDownloads] = [:]
    /// T37: recently-used emoji, per server (the store itself is keyed by server **and** user).
    private var emojiRecents: [UUID: EmojiRecentsStore] = [:]
    /// T35: one composer per channel, kept beside its list so a channel switch restores both the
    /// window and the half-typed message.
    private var composers: [UUID: [String: ComposerViewModel]] = [:]
    /// T35: the per-server draft databases (one SQLite file each, opened on first use).
    private let draftStores = ComposerDraftStoreProvider()

    /// Test seam: replaces the production session-backed service (T33's `serviceFactory`).
    var serviceFactory: ((ServerConfig) -> ChannelServing)?
    /// Test seam: replaces the production composer service.
    var composerServiceFactory: ((ServerConfig) -> ComposerServing)?
    /// Test seam: replaces the production draft store.
    var draftStoreFactory: ((ServerConfig) -> ComposerDraftStoring)?

    /// Diagnostics: how many models are alive (one test asserts the cache is bounded).
    var modelCount: Int { models.values.reduce(0) { $0 + $1.count } }

    /// The model currently on screen for a server, if any.
    func activeModel(serverID: UUID, channelID: String) -> ChannelViewModel? {
        models[serverID]?[channelID]
    }

    func bind(auth: AuthCoordinator?,
              navigation: NativeNavigation?,
              serverStore: ServerStore?) {
        self.auth = auth
        self.navigation = navigation
        self.serverStore = serverStore
    }

    /// The model for one channel, created on first use.
    func model(for server: ServerConfig, channelID: String, channelName: String?) -> ChannelViewModel {
        if let existing = models[server.id]?[channelID] {
            touch(serverID: server.id, channelID: channelID)
            return existing
        }
        let model = ChannelViewModel(channelID: channelID,
                                     channelName: channelName,
                                     service: service(for: server),
                                     myUserID: auth?.userID(for: server.id))
        models[server.id, default: [:]][channelID] = model
        touch(serverID: server.id, channelID: channelID)
        evictIfNeeded(serverID: server.id)
        return model
    }

    /// Attachment bytes for one server (one cache per server, shared by every channel's rows).
    func imageStore(for server: ServerConfig) -> ChannelImageStore {
        if let existing = imageStores[server.id] { return existing }
        let store = ChannelImageStore(service: service(for: server))
        imageStores[server.id] = store
        return store
    }

    /// The server's custom emoji (one catalogue per server: the list is a team-wide fact, and every
    /// channel's rows resolve the same `:name:`s).
    func emojiCatalogue(for server: ServerConfig) -> EmojiCatalogue {
        if let existing = emojiCatalogues[server.id] { return existing }
        let catalogue = EmojiCatalogue(service: service(for: server))
        emojiCatalogues[server.id] = catalogue
        return catalogue
    }

    /// T38: the attachment download state for one server, created on first use.
    ///
    /// Per server, not per channel, for the same reason the image cache is: the same file can appear in
    /// two channels, and a save started in one must read as saved in the other. The worker is passed in
    /// by the view (`@EnvironmentObject` at the app root) rather than owned here, because the Downloads
    /// screen and the rows must share exactly one journal.
    func attachmentDownloads(for server: ServerConfig, worker: DownloadWorker) -> AttachmentDownloads {
        if let existing = attachmentDownloadsStores[server.id] { return existing }
        let downloads = AttachmentDownloads(worker: worker, service: service(for: server))
        attachmentDownloadsStores[server.id] = downloads
        return downloads
    }

    /// T37: the recently-used emoji, one store per server **and** user.
    ///
    /// Per user as well as per server because the list is personal: two accounts on one server must
    /// not see each other's latest reactions. Cached here (rather than built by each sheet) so the
    /// picker and the reaction write record into the *same* in-memory list, and a sheet that opens
    /// after a react already shows it.
    func emojiRecents(for server: ServerConfig) -> EmojiRecentsStore {
        if let existing = emojiRecents[server.id] { return existing }
        let store = EmojiRecentsStore(serverID: server.id,
                                      userID: auth?.userID(for: server.id) ?? "")
        emojiRecents[server.id] = store
        return store
    }

    /// The service for one server: the test factory when one is installed, otherwise the session's
    /// own `APIClient`, resolved **per call** so a service built before the session finished
    /// restoring is not permanently signed out (T33's `SessionChannelSidebarService` has the same
    /// note).
    private func service(for server: ServerConfig) -> ChannelServing {
        if let serviceFactory { return serviceFactory(server) }
        let auth = self.auth
        return SessionChannelService {
            guard let auth, let session = try? auth.session(for: server) else { return nil }
            return session.client
        }
    }

    private func composerService(for server: ServerConfig) -> ComposerServing {
        if let composerServiceFactory { return composerServiceFactory(server) }
        let auth = self.auth
        return SessionComposerService {
            guard let auth, let session = try? auth.session(for: server) else { return nil }
            return session.client
        }
    }

    private func draftStore(for server: ServerConfig) -> ComposerDraftStoring {
        if let draftStoreFactory { return draftStoreFactory(server) }
        return draftStores.store(for: server)
    }

    /// The composer for one channel, created on first use and wired to that channel's list.
    ///
    /// The sink is attached here rather than in the view because the composer must be able to write
    /// into the list even when the view has gone away (a send that completes while the reader is in
    /// another pane still has to reconcile its optimistic row).
    func composer(for server: ServerConfig,
                  channelID: String,
                  channelName: String?,
                  teamID: String?,
                  emojiCatalogue: EmojiCatalogue?) -> ComposerViewModel {
        let list = model(for: server, channelID: channelID, channelName: channelName)
        if let existing = composers[server.id]?[channelID] {
            existing.attach(sink: list)
            return existing
        }
        let composer = ComposerViewModel(channelID: channelID,
                                         service: composerService(for: server),
                                         drafts: draftStore(for: server),
                                         sink: list,
                                         teamID: teamID,
                                         myUserID: auth?.userID(for: server.id),
                                         emojiCatalogue: emojiCatalogue)
        composers[server.id, default: [:]][channelID] = composer
        return composer
    }

    /// Drop one channel's composer (its draft is already on disk).
    func forgetComposer(serverID: UUID, channelID: String) {
        composers[serverID]?[channelID] = nil
    }

    /// The appearance pass: point the model at the channel on screen and load it once.
    @discardableResult
    func activate(server: ServerConfig,
                  channelID: String,
                  channelName: String?) async -> ChannelViewModel {
        let model = model(for: server, channelID: channelID, channelName: channelName)
        await model.load(ifNeeded: true)
        return model
    }

    /// One event from the server's socket (already scoped to the team on screen by the rail).
    ///
    /// Delivered to every warm model for that server; each model keeps only its own channel's posts
    /// (`ChannelViewModel.accepts`), so a busy server cannot leak one channel's traffic into another.
    func handle(_ event: SocketEvent, serverID: UUID) async {
        guard let byChannel = models[serverID], !byChannel.isEmpty else { return }
        for (_, model) in byChannel {
            model.handle(event)
        }
    }

    /// Sign-out / expiry / server removal: drop the server's windows.
    func deactivate(_ serverID: UUID) {
        models[serverID] = nil
        recent[serverID] = nil
        // The composer goes with the list: a draft is already in the store, and the store is cleared
        // below (a signed-out device keeps no half-typed messages from the previous session).
        composers[serverID] = nil
        draftStores.clear(serverID)
        imageStores[serverID]?.clear()
        imageStores[serverID] = nil
        attachmentDownloadsStores[serverID] = nil
        // A new session may be a different team with a different emoji list, so the catalogue is
        // dropped with everything else rather than surviving a sign-out.
        emojiCatalogues[serverID]?.clear()
        emojiCatalogues[serverID] = nil
    }

    func authPhaseChanged(_ serverID: UUID) {
        deactivate(serverID)
    }

    // MARK: Cache

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
