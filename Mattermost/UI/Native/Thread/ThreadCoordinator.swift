// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/thread/index.tsx + app/screens/thread/thread.tsx (one mounted thread screen per
//        root, torn down when it closes), app/actions/websocket/threads.ts (the screen applies
//        thread_* events while it is open), app/screens/global_threads/ (one list per team).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §13; no
// upstream source copied. The coordinator decomposition mirrors T34's `ChannelPaneCoordinator`
// (one owner, one model per key, the rail's single socket fanned in), which is this repo's
// convention (component-map.md §1).
//
// Why a coordinator and not a `@StateObject` in the view:
//  - a thread's model must survive the view being re-created (a rotation, a detail-column swap);
//  - `thread_updated`/`thread_follow_changed`/`thread_read_changed` arrive on the rail's socket
//    (`TeamSidebarCoordinator.onTeamEvent`) — the app's single WebSocket per server — and a view
//    cannot be the subscriber without owning a socket;
//  - the reply count a thread moves has to reach the **channel timeline**, which is another model;
//    the coordinator is the only object that holds both.
//
// The model cache is bounded (4 open threads per server): a session that opens forty threads must
// not keep forty chains alive. Eviction is safe — a model rebuilds from the server on next open.

import Foundation
import Combine

/// Owns one `ThreadViewModel` per (server, root), one `GlobalThreadsViewModel` per (server, team),
/// and the composer each open thread replies with.
@MainActor
final class ThreadCoordinator: ObservableObject {

    /// How many open threads keep a warm chain per server.
    static let warmThreadLimit = 4
    /// How many thread composers keep a half-typed reply per server.
    static let warmComposerLimit = 4

    private var auth: AuthCoordinator?
    private var navigation: NativeNavigation?
    private var serverStore: ServerStore?
    /// The channel panes' owner: a thread's reply activity is published into the channel model that
    /// draws the root row.
    private weak var channelPanes: ChannelPaneCoordinator?

    private var models: [UUID: [String: ThreadViewModel]] = [:]
    private var recent: [UUID: [String]] = [:]
    private var globalModels: [UUID: [String: GlobalThreadsViewModel]] = [:]
    private var composers: [UUID: [String: ComposerViewModel]] = [:]
    private var composerOrder: [UUID: [String]] = [:]
    private let draftStores = ComposerDraftStoreProvider()

    /// Test seams, matching `ChannelPaneCoordinator`'s.
    var serviceFactory: ((ServerConfig) -> ThreadServing)?
    var composerServiceFactory: ((ServerConfig) -> ComposerServing)?
    var draftStoreFactory: ((ServerConfig) -> ComposerDraftStoring)?

    /// Diagnostics: how many thread models are alive (one test asserts the cache is bounded).
    var modelCount: Int { models.values.reduce(0) { $0 + $1.count } }

    func bind(auth: AuthCoordinator?,
              navigation: NativeNavigation?,
              serverStore: ServerStore?,
              channelPanes: ChannelPaneCoordinator?) {
        self.auth = auth
        self.navigation = navigation
        self.serverStore = serverStore
        self.channelPanes = channelPanes
    }

    // MARK: - Threads

    func model(for server: ServerConfig, rootID: String, channelID: String?) -> ThreadViewModel {
        if let existing = models[server.id]?[rootID] {
            touch(serverID: server.id, rootID: rootID)
            return existing
        }
        let model = ThreadViewModel(rootID: rootID,
                                    channelID: channelID ?? "",
                                    teamID: teamID(for: server),
                                    service: service(for: server),
                                    myUserID: auth?.userID(for: server.id),
                                    typing: typingTransport(for: server))
        // A reply moves the root's count on the channel timeline. Wired here (not in the view) so the
        // patch still happens when the channel pane is not the one on screen — the reader can open a
        // thread from the global list while a channel model is warm behind it.
        model.onReplyActivity = { [weak self] rootID, count, lastReplyAt in
            // `activeModel`, not `model(for:)`: this must patch a pane that is already open, never
            // create one for a channel nobody is looking at (an empty id would create one for "").
            self?.channelPanes?.activeModel(serverID: server.id, channelID: channelID ?? "")?
                .applyReplyActivity(rootID: rootID, count: count, lastReplyAt: lastReplyAt)
        }
        models[server.id, default: [:]][rootID] = model
        touch(serverID: server.id, rootID: rootID)
        evictIfNeeded(serverID: server.id)
        return model
    }

    /// The appearance pass: point the model at the thread on screen and load it once.
    @discardableResult
    func activate(server: ServerConfig,
                  rootID: String,
                  channelID: String?) async -> ThreadViewModel {
        let model = model(for: server, rootID: rootID, channelID: channelID)
        await model.load(ifNeeded: true)
        return model
    }

    func forgetThread(serverID: UUID, rootID: String) {
        models[serverID]?[rootID] = nil
        recent[serverID]?.removeAll { $0 == rootID }
        composers[serverID]?["\(rootID)"] = nil
    }

    /// T51 (S26): the drafts list deleted this thread's draft row — drop the warm composer's copy,
    /// so re-opening the thread does not show text whose row is gone.
    func discardDraft(serverID: UUID, channelID: String, rootID: String) {
        guard !rootID.isEmpty else { return }
        composers[serverID]?["\(channelID)/\(rootID)"]?.discardStoredDraft()
    }

    // MARK: - The thread's composer

    /// The composer that replies into one thread.
    ///
    /// Created only once the model knows the root's channel (a thread opened from a permalink or the
    /// global list does not carry one). The composer is T35's, in reply mode: same send path, same
    /// drafts (keyed by `(channel, thread root)`), same autocomplete — the only difference is the
    /// sink, which is this thread's model rather than a channel's.
    func composer(for server: ServerConfig,
                  model: ThreadViewModel,
                  emojiCatalogue: EmojiCatalogue?) -> ComposerViewModel? {
        guard let root = model.root, !model.channelID.isEmpty else { return nil }
        let key = "\(model.channelID)/\(model.rootID)"
        if let existing = composers[server.id]?[key] {
            existing.attach(sink: model)
            return existing
        }
        let composer = ComposerViewModel(channelID: model.channelID,
                                         service: composerService(for: server),
                                         drafts: draftStore(for: server),
                                         sink: model,
                                         teamID: model.teamID,
                                         myUserID: auth?.userID(for: server.id),
                                         emojiCatalogue: emojiCatalogue,
                                         typing: typingTransport(for: server))
        composer.beginReply(to: root, authorLabel: model.rootAuthorLabel)
        composers[server.id, default: [:]][key] = composer
        trackComposer(serverID: server.id, key: key)
        return composer
    }

    /// T4f: the typing seam, borrowed from the channel panes' owner.
    ///
    /// Borrowed, not built: `/config/client` and the rail's socket are per **server**, and a thread
    /// pane whose composer throttled at one interval while the channel's row expired at another is a
    /// bug with no symptom except a row that flickers. `ChannelPaneCoordinator` already owns that
    /// object; this coordinator reaches it through the reference it holds for reply counts.
    private func typingTransport(for server: ServerConfig) -> ComposerTypingTransporting? {
        channelPanes?.typingTransport(for: server)
    }

    private func trackComposer(serverID: UUID, key: String) {
        var order = composerOrder[serverID] ?? []
        order.removeAll { $0 == key }
        order.append(key)
        composerOrder[serverID] = order
        let excess = order.count - Self.warmComposerLimit
        if excess > 0 {
            for stale in order.prefix(excess) { composers[serverID]?[stale] = nil }
            composerOrder[serverID] = Array(order.dropFirst(excess))
        }
    }

    // MARK: - Global threads

    /// Diagnostics: how many global lists are cached (one per server+team).
    var globalModelCount: Int { globalModels.values.reduce(0) { $0 + $1.count } }

    /// The followed-threads list for one server and team.
    ///
    /// A **teamless** model is never cached. It is a placeholder whose only job is to draw "choose a
    /// team to see your threads"; memoising it (under the key `"default"`, as this used to) kept a
    /// model that can never load alive after the team resolved, and handed it to whichever caller
    /// came next. Without the entry, the pane's `.task(id: navigation.location.teamID)` builds the
    /// real model once the team arrives, and that model loads exactly once.
    ///
    /// When the caller has no team but the shell does (a tab tap writes no route), the shell's team
    /// is used — so the tab badge and the pane's list are the same object, rather than one honest
    /// placeholder beside one loaded list.
    func globalModel(for server: ServerConfig, teamID: String?) -> GlobalThreadsViewModel {
        let requested = (teamID?.isEmpty == false) ? teamID : nil
        guard let resolvedTeamID = requested ?? currentTeamID(for: server) else {
            return GlobalThreadsViewModel(teamID: "",
                                          service: service(for: server),
                                          myUserID: auth?.userID(for: server.id))
        }
        if let existing = globalModels[server.id]?[resolvedTeamID] { return existing }
        let model = GlobalThreadsViewModel(teamID: resolvedTeamID,
                                           service: service(for: server),
                                           myUserID: auth?.userID(for: server.id))
        globalModels[server.id, default: [:]][resolvedTeamID] = model
        return model
    }

    /// Drop every global list for a server (a team switch keeps them: one per team id).
    func forgetGlobal(serverID: UUID) {
        globalModels[serverID] = nil
    }

    /// The team the shell is currently showing on `server`, when one has resolved.
    ///
    /// The same fact the router completes a threads route with (`NativeChannelDirectory`), read here
    /// so a pane opened by a tab tap — which writes no route — does not sit on "choose a team" while
    /// the sidebar plainly shows one. It is a lookup, never a guess: no answer means "still no team".
    func currentTeamID(for server: ServerConfig) -> String? {
        guard let teamID = navigation?.directory?.currentTeamID(serverID: server.id),
              !teamID.isEmpty else { return nil }
        return teamID
    }

    // MARK: - Services

    private func teamID(for server: ServerConfig) -> String {
        // The navigation model's current location is the only source for "which team is on screen";
        // a thread opened without a location falls back to the team the sidebar is showing, and only
        // then to "no team" — the empty value a caller must treat as "not resolved"
        // (`GlobalThreadsViewModel.noTeam`), never as a URL segment.
        if let id = navigation?.location.teamID, !id.isEmpty { return id }
        return currentTeamID(for: server) ?? ""
    }

    private func service(for server: ServerConfig) -> ThreadServing {
        if let serviceFactory { return serviceFactory(server) }
        let auth = self.auth
        return SessionThreadService {
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

    // MARK: - Socket

    /// Repair this server's open thread panes and thread lists after a socket gap.
    ///
    /// The socket is **server-scoped**, so a gap loses frames for every thread the session keeps warm
    /// (up to `warmThreadLimit` chains and one list per team), not only the one on screen — a thread
    /// switched to afterwards that quietly lacks a reply is the same defect one tap away. That is the
    /// rule `ChannelPaneCoordinator.resync` already states for its six warm windows.
    ///
    /// Only `.loaded` models are swept: an unopened thread's first load is its fetch, and a `.failed`
    /// one is waiting for the reader's retry, not for a repair. Each model merges (see
    /// `ThreadViewModel.resyncAfterGap` / `GlobalThreadsViewModel.resyncAfterGap`), so a sweep never
    /// blanks a pane or drops an older page.
    ///
    /// Returns how many models were swept.
    @discardableResult
    func resync(serverID: UUID) async -> Int {
        var repaired = 0
        for (_, model) in (models[serverID] ?? [:]).sorted(by: { $0.key < $1.key }) where model.phase == .loaded {
            _ = await model.resyncAfterGap()
            repaired += 1
        }
        for (_, list) in (globalModels[serverID] ?? [:]).sorted(by: { $0.key < $1.key }) where list.phase == .loaded {
            _ = await list.resyncAfterGap()
            repaired += 1
        }
        if repaired > 0 { resyncCount += 1 }
        return repaired
    }

    /// How many gap sweeps this coordinator ran (diagnostics/tests).
    private(set) var resyncCount = 0

    /// Whether this server holds a **loaded** chain for that thread right now.
    ///
    /// The delivery watchdog asks this before it treats a silent-but-open socket as a wedge: a thread
    /// pane on screen with a chain is a surface a lost frame corrupts; one that is still loading has its
    /// own fetch to do it, and one that failed has nothing a refetch could put right.
    func hasLoadedThread(serverID: UUID, rootID: String) -> Bool {
        models[serverID]?[rootID]?.phase == .loaded
    }

    /// Whether any of this server's thread lists (`/…/threads`) is loaded — the threads pane without a
    /// post is the global list, whose team the gate does not need to know to answer this.
    func hasLoadedThreadList(serverID: UUID) -> Bool {
        (globalModels[serverID] ?? [:]).values.contains { $0.phase == .loaded }
    }

    /// One event from the server's socket (already scoped to the team on screen by the rail).
    ///
    /// Delivered to every warm thread model and to the global lists of that server; each model keeps
    /// only what concerns it (`threadID == rootID`, posts under its own root), so one busy thread
    /// cannot patch another.
    func handle(_ event: SocketEvent, serverID: UUID) async {
        for (_, model) in models[serverID] ?? [:] {
            model.handle(event)
        }
        for (_, list) in globalModels[serverID] ?? [:] {
            list.handle(event)
        }
    }

    /// Sign-out / expiry / server removal: drop the server's threads, lists and their composers.
    func deactivate(_ serverID: UUID) {
        models[serverID] = nil
        recent[serverID] = nil
        globalModels[serverID] = nil
        composers[serverID] = nil
        composerOrder[serverID] = nil
        draftStores.clear(serverID)
    }

    func authPhaseChanged(_ serverID: UUID) {
        deactivate(serverID)
    }

    // MARK: Cache

    private func touch(serverID: UUID, rootID: String) {
        var list = recent[serverID] ?? []
        list.removeAll { $0 == rootID }
        list.append(rootID)
        recent[serverID] = list
    }

    private func evictIfNeeded(serverID: UUID) {
        guard let list = recent[serverID], list.count > Self.warmThreadLimit else { return }
        let excess = list.count - Self.warmThreadLimit
        for rootID in list.prefix(excess) {
            models[serverID]?[rootID] = nil
        }
        recent[serverID] = Array(list.dropFirst(excess))
    }
}
