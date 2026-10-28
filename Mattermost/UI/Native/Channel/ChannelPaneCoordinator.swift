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
    /// Profile pictures, one cache per server: a face is a fact about the server, not about a
    /// channel, and the channel pane, the thread panes and the member lists all ask for the same ones.
    private var avatarStores: [UUID: AvatarImageStore] = [:]
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
    /// T48: per-channel post-options state (permissions, saved set, pin/follow patches). One per
    /// channel, kept beside the window it describes.
    private var postOptionsModels: [UUID: [String: PostOptionsViewModel]] = [:]

    /// Test seam: replaces the production session-backed service (T33's `serviceFactory`).
    var serviceFactory: ((ServerConfig) -> ChannelServing)?
    /// Test seam: replaces the production composer service.
    var composerServiceFactory: ((ServerConfig) -> ComposerServing)?
    /// Test seam: replaces the production post-options service (T48).
    var postOptionsServiceFactory: ((ServerConfig) -> PostOptionsServing)?
    /// Test seam: replaces the production draft store.
    var draftStoreFactory: ((ServerConfig) -> ComposerDraftStoring)?

    /// Diagnostics: how many models are alive (one test asserts the cache is bounded).
    var modelCount: Int { models.values.reduce(0) { $0 + $1.count } }

    /// The model currently on screen for a server, if any.
    func activeModel(serverID: UUID, channelID: String) -> ChannelViewModel? {
        models[serverID]?[channelID]
    }

    /// Whether this server holds a **loaded** window for that channel right now.
    ///
    /// The socket's delivery watchdog (`SocketClient.StallWatchdog`) asks this before it treats a
    /// silent-but-open socket as a wedge: if the channel on screen has a window, a frame the server
    /// published is missing from something somebody is reading; if it has none, silence is just quiet.
    /// A `.loading` or `.failed` model answers `false` — its own load is the fetch, and a window that
    /// never loaded has nothing a refetch could put right.
    func hasLoadedWindow(serverID: UUID, channelID: String) -> Bool {
        models[serverID]?[channelID]?.phase == .loaded
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

    /// Profile pictures for one server, created on first use.
    ///
    /// One store per server and not per pane: the channel timeline, the thread pane, the global
    /// threads tab and the member list all draw the same faces, and a face must cost one request.
    /// The bytes are also kept on disk under the server's own caches directory, so a relaunch draws
    /// them before any request is made.
    func avatarStore(for server: ServerConfig) -> AvatarImageStore {
        if let existing = avatarStores[server.id] { return existing }
        let store = AvatarImageStore(service: service(for: server),
                                     disk: AvatarDiskCache(directory: AvatarDiskCache.defaultDirectory(for: server.id)))
        avatarStores[server.id] = store
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
        return SessionChannelService(profiles: UserProfileCache.shared(for: server.id)) {
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

    private func postOptionsService(for server: ServerConfig) -> PostOptionsServing {
        if let postOptionsServiceFactory { return postOptionsServiceFactory(server) }
        let auth = self.auth
        return SessionPostOptionsService {
            guard let auth, let session = try? auth.session(for: server) else { return nil }
            return session.client
        }
    }

    /// T48: the post-options state for one channel, created on first use.
    ///
    /// Per channel rather than per server: the permission union, the archived flag and the channel's
    /// own saved rows are channel facts, and a menu opened in one channel must never decide from
    /// another channel's state.
    func postOptions(for server: ServerConfig, channelID: String) -> PostOptionsViewModel {
        if let existing = postOptionsModels[server.id]?[channelID] { return existing }
        let model = PostOptionsViewModel(channelID: channelID,
                                         serverURL: server.url.absoluteString,
                                         myUserID: auth?.userID(for: server.id) ?? "",
                                         service: postOptionsService(for: server))
        postOptionsModels[server.id, default: [:]][channelID] = model
        return model
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
        // T48: the post-options state is fed first and independently of the channel windows — a thread
        // pane can be open on a channel whose timeline was never loaded (opened from the global
        // threads list), and its menu still has to follow a pin or a save from another client.
        for (_, options) in postOptionsModels[serverID] ?? [:] {
            options.handle(event)
        }
        guard let byChannel = models[serverID], !byChannel.isEmpty else { return }
        for (_, model) in byChannel {
            model.handle(event)
        }
    }

    /// The server's socket dropped and came back: repair every window this server already loaded.
    ///
    /// This is the other half of T34-R5's finding. `posted` patches a window in place, so an event that
    /// is never delivered is never applied — and the server does not replay what it published while the
    /// connection was down. The rail's `SocketClient` reports the reconnect once; this is where the
    /// screen makes good on it.
    ///
    /// *Every warm channel*, not only the one on screen: the socket is server-scoped, so a `posted` for
    /// any of the six kept channels can have been lost, and a channel switched to afterwards that
    /// quietly lacks a message is the same defect one tap away. `resyncAfterReconnect()` merges the
    /// newest page into whatever window each model holds, so an off-screen window is repaired in place.
    ///
    /// Only *loaded* models are resynced: an idle model has nothing to repair (its first load fetches the
    /// newest page anyway) and asking the server for a channel nobody has opened would be work and a
    /// request for nothing.
    ///
    /// Returns how many models were resynced, and counts the round in `resyncCount` (tests: "never
    /// resyncs" and "resyncs on every connect" otherwise look identical).
    @discardableResult
    func resync(serverID: UUID) async -> Int {
        guard let byChannel = models[serverID], !byChannel.isEmpty else { return 0 }
        var repaired = 0
        for (_, model) in byChannel where model.phase == .loaded {
            _ = await model.resyncAfterReconnect()
            repaired += 1
        }
        if repaired > 0 { resyncCount += 1 }
        return repaired
    }

    /// How many reconnect rounds this coordinator repaired (diagnostics/tests).
    private(set) var resyncCount = 0

    /// Sign-out / expiry / server removal: drop the server's windows.
    func deactivate(_ serverID: UUID) {
        models[serverID] = nil
        recent[serverID] = nil
        postOptionsModels[serverID] = nil
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
