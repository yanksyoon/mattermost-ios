// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: `app/screens/home/recent_mentions/` (one screen per server; it refetches on focus rather than
//        holding a second source of truth), `app/actions/websocket/posts.ts` + `threads.ts` (an open list
//        applies the socket events). Licence: Apache-2.0 — behaviour ported with attribution per
//        docs/THIRD_PARTY_NOTICES.md §19; no upstream source copied.
//
// Why a coordinator and not a `@StateObject` in the tab (the convention every T32+ surface follows,
// component-map.md §1):
//  - a tab switch, a push and a rotation re-create the view; a model that died with it would refetch the
//    whole window on every visit and lose the read-state it had just applied;
//  - the feed is patched by the app's single per-server socket
//    (`TeamSidebarCoordinator.onTeamEvent`), which a view cannot subscribe to;
//  - the badge hand-off belongs to exactly one object per server, so two mounted views of the feed cannot
//    push two different counter reads into `SessionStore`.

import Foundation
import Combine

@MainActor
final class ActivityCoordinator: ObservableObject {

    private var auth: AuthCoordinator?
    private var serverStore: ServerStore?
    /// `SessionStore` is the badge's single source of truth (T8). The feed hands it the server's own
    /// counters through `SessionStore.serverBadgeInput`; it never computes a badge number.
    private weak var sessionStore: SessionStore?

    /// Test seam: replaces the production session-backed service (T33/T34's `serviceFactory` shape).
    var serviceFactory: ((ServerConfig) -> ActivityServing)?

    /// One feed per server — the mentions window is cross-team by definition, so there is no team key.
    private var models: [UUID: MentionsViewModel] = [:]

    var modelCount: Int { models.count }

    func bind(auth: AuthCoordinator?, serverStore: ServerStore?, sessionStore: SessionStore?) {
        self.auth = auth
        self.serverStore = serverStore
        self.sessionStore = sessionStore
    }

    // MARK: - The model

    func model(for server: ServerConfig) -> MentionsViewModel {
        if let existing = models[server.id] {
            // The badge closure captures the store weakly and the server id, so a re-bind (a restored
            // session, a store replaced by the scene) still lands on the right per-server row.
            existing.onBadgeInput = badgeHandoff(for: server)
            return existing
        }
        let model = MentionsViewModel(service: service(for: server),
                                      myUserID: auth?.userID(for: server.id))
        model.onBadgeInput = badgeHandoff(for: server)
        models[server.id] = model
        return model
    }

    /// The one place the feed's counters reach the badge.
    ///
    /// `SessionStore.updateMentions(serverID:mentionCount:unreadMessages:isUnread:)` is the same call the
    /// background `MentionPoller` makes, and `SessionStore.badgeNumber` is the only badge arithmetic in
    /// the app — so "the feed and the badge disagree" is never two counters, only the server's own
    /// numbers arriving twice. The message total rides along so the app icon can show a number instead
    /// of desktop's dot (card `t_93eca948`).
    private func badgeHandoff(for server: ServerConfig) -> (Int, Int, Bool) -> Void {
        { [weak self] mentions, messages, isUnread in
            self?.sessionStore?.updateMentions(serverID: server.id,
                                               mentionCount: mentions,
                                               unreadMessages: messages,
                                               isUnread: isUnread)
        }
    }

    // MARK: - The socket

    /// Repair the feed after a socket gap (a reconnect, or the delivery watchdog's confirmed stall).
    ///
    /// One model per server, and the merge (`MentionsViewModel.resyncAfterGap`) keeps every row it holds
    /// — the whole reason this is not a `reload()`: a gap is not a reason to blank the reader's list to a
    /// spinner and drop the mentions the socket or an extra page had added.
    ///
    /// Returns how many models were swept (`0` when the feed was never loaded — its own first load is the
    /// fetch, and there is no window a gap could have corrupted).
    @discardableResult
    func resync(serverID: UUID) async -> Int {
        guard let model = models[serverID], model.phase == .loaded else { return 0 }
        _ = await model.resyncAfterGap()
        resyncCount += 1
        return 1
    }

    /// How many gap sweeps this coordinator ran (diagnostics/tests).
    private(set) var resyncCount = 0

    // MARK: - On screen

    /// The servers whose mentions feed is mounted on screen right now.
    ///
    /// "The feed is visible" is not a fact the navigation model owns: the feed is a top-level tab on a
    /// phone and a sheet in the regular layout, and neither writes a `NativeLocation`. The only object
    /// that knows is the view drawing it, so `ActivityFeedView` reports its appearance here and the
    /// delivery watchdog's gate reads it (see `NativeSurfaceVisibility`).
    private var feedsOnScreen: Set<UUID> = []

    func setFeedOnScreen(_ serverID: UUID, _ onScreen: Bool) {
        if onScreen { feedsOnScreen.insert(serverID) } else { feedsOnScreen.remove(serverID) }
    }

    func isFeedOnScreen(serverID: UUID) -> Bool { feedsOnScreen.contains(serverID) }

    /// Whether that server's feed is **on screen and loaded** — the one fact the watchdog's gate needs.
    ///
    /// The two halves are deliberately not separable at the call site: a feed that is on screen but never
    /// loaded has its own first fetch to do it, and a loaded feed nobody is looking at must not be
    /// swept. Answering `true` for either alone is how a gate becomes a poll.
    func hasLoadedFeedOnScreen(serverID: UUID) -> Bool {
        feedsOnScreen.contains(serverID) && models[serverID]?.phase == .loaded
    }

    /// One event from the server's socket (already scoped to a team by the rail).
    ///
    /// The feed is not team-scoped — a mention from another team still belongs in it — so every event
    /// reaches the model and the model keeps only what concerns it. `TeamSocketScope` refusing an
    /// unattributable event is fine here: a refusal costs the row until the next refresh, and the model
    /// never sees a half-attributed event.
    func handle(_ event: SocketEvent, serverID: UUID) {
        models[serverID]?.handle(event)
    }

    // MARK: - Lifetime

    func authPhaseChanged(_ serverID: UUID) {
        deactivate(serverID)
    }

    /// Sign-out / expiry / server removal: the window was fetched with that credential, so it goes with it.
    func deactivate(_ serverID: UUID) {
        models[serverID] = nil
    }

    // MARK: - Service

    private func service(for server: ServerConfig) -> ActivityServing {
        if let serviceFactory { return serviceFactory(server) }
        let auth = self.auth
        return SessionActivityService {
            guard let auth, let session = try? auth.session(for: server) else { return nil }
            return session.client
        }
    }
}
