// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: `app/screens/home/recent_mentions/recent_mentions.tsx` (refetch on focus, pull to refresh, the
//        one list), `app/actions/remote/search.ts` (`fetchRecentMentions`), `app/actions/websocket/
//        posts.ts` (an open list applies `posted`/`post_edited`/`post_deleted`), `app/actions/websocket/
//        threads.ts` + `app/actions/websocket/channels.ts` (`thread_read_changed`,
//        `multiple_channels_viewed`: my read state moved in another client).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §19; no
// upstream source copied. The model shape is this repo's own, mirroring `GlobalThreadsViewModel` and
// `PostCollectionViewModel`: generation-guarded loads, a service seam, and merge rules a test pins.
//
// ## Why the feed is a search, not a counter
//
// `GET /users/me/mentions` does not exist on this server (measured — T14 recorded the same absence, and
// T42's probe re-measured it). The official client therefore builds the mentions list from
// `POST /posts/search` with the reader's **mention keys** as the terms, and that is what this model
// does: the server answers its own mention set, and the client filters nothing out of it. A locally
// aggregated list ("every `posted` frame that looked like a mention") could only show what arrived while
// the app was open, which is not a mentions inbox.
//
// ## Where read state and the badge come from (two different places, on purpose)
//
//  - **A row's unread dot** is the reader's read cursor: `create_at > last_viewed_at` for a root post, and
//    the thread's own `unread_mentions`/`unread_replies` for a reply (collapsed threads are `always_on`
//    on the pinned server, so a channel's cursor does not move when a thread is read — measured).
//  - **The badge** is `SessionStore`'s: this model fetches the same `/users/me/teams/unread` counters the
//    background `MentionPoller` polls and hands them to `SessionStore.serverBadgeInput` /
//    `updateMentions`. It never keeps a badge number of its own, so "the feed and the badge disagree"
//    cannot be a second counter drifting — only the server's own numbers.
//
// Measured, and stated because it looks like a bug in the feed: reading one thread clears that thread's
// counters but does **not** decrement the channel's `mention_count` (9.11.19 recomputes the channel row
// on a channel read, not on a thread read). The badge therefore keeps counting a thread mention the feed
// draws as read until the channel itself is read — the server's arithmetic, mirrored rather than
// second-guessed. `docs/t42-build-note.md` §2 records the measurement.

import Foundation
import Combine

@MainActor
final class MentionsViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// What one socket event did to this feed (diagnostics/tests; never rendered).
    enum EventOutcome: Equatable {
        case ignored
        case inserted
        case patched
        case removed
        case readStateChanged
    }

    // MARK: Published state

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var filter: ActivityFilter = .all
    /// Every row in the window, newest first.
    @Published private(set) var rows: [ActivityRow] = []
    /// The rows the filter keeps — what the list draws.
    @Published private(set) var visibleRows: [ActivityRow] = []
    /// The reader's own mention keys, once known (empty before the first load).
    @Published private(set) var keys = MentionKeys(keys: [])
    /// A failed *write* (a mark-read that did not land), shown as a banner over the list. Reads use
    /// `phase` instead: a failed load has no rows to put a banner over.
    @Published private(set) var actionError: String?
    @Published private(set) var isMarking = false
    /// The row a live socket event just added, so the list can mark it (and a test can find it).
    @Published private(set) var insertedRowID: String?
    @Published private(set) var lastEventOutcome: EventOutcome = .ignored

    /// Diagnostics.
    var loadedCount: Int { rows.count }
    var loadedPostIDs: [String] { rows.map(\.postID) }
    func row(postID: String) -> ActivityRow? { rows.first { $0.postID == postID } }
    var unreadCount: Int { rows.filter(\.isUnread).count }
    var subtitle: String { ActivityDerivation.subtitle(rows: rows) }
    var emptyCopy: String { ActivityDerivation.emptyCopy(filter: filter, totalRows: rows.count) }

    // MARK: Collaborators

    private let service: ActivityServing
    private let myUserID: String?
    private let now: () -> Int64
    /// The badge hand-off: `(mentionCount, isUnread)`, the two numbers `SessionStore.updateMentions` takes.
    /// Injected rather than reached for, so a test can assert exactly what the feed told the store
    /// (and so this model has no path to a badge number of its own).
    var onBadgeInput: ((Int, Bool) -> Void)?

    // MARK: Private state

    private var profile: ActivityProfile?
    private var channels: [String: MMChannel] = [:]
    private var users: [String: MMUser] = [:]
    private var cursors: [String: ActivityChannelCursor] = [:]
    private var threadUnread: [String: ActivityThreadUnread] = [:]
    /// The teams whose read state has been fetched — one `channels/members` call each, cached per load
    /// cycle rather than per row.
    private var loadedReadTeams = Set<String>()
    private var generation = 0
    private var badgeTask: Task<Void, Never>?

    // MARK: Init

    init(service: ActivityServing,
         myUserID: String? = nil,
         now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.service = service
        self.myUserID = myUserID
        self.now = now
    }

    // MARK: - Loading

    func load(ifNeeded: Bool = true) async {
        if ifNeeded, phase == .loaded { return }
        await reload()
    }

    /// Read the window again from the server. Also the pull-to-refresh path and the "the tab came back
    /// into view" path (upstream refetches on focus).
    func reload() async {
        generation += 1
        let requested = generation
        phase = .loading
        actionError = nil
        do {
            let reader = try await self.reader(requested: requested)
            let window = try await service.mentions(terms: reader.keys.searchTerms,
                                                    page: 0,
                                                    perPage: service.pageSize)
            guard requested == generation else { return }

            var posts = window.orderedPosts
            // The database-backed search ignores `page` (measured: `page: 1` answers an empty `order`),
            // so one extra page is attempted only when the server says there is one — and an empty
            // page ends the loop. `has_next` is false on 9.11.19, so the shipping path makes one
            // request; a future Elasticsearch server pages normally.
            var page = 1
            var hasNext = window.hasNext ?? false
            while hasNext, page <= 3 {
                let next = try await service.mentions(terms: reader.keys.searchTerms,
                                                      page: page, perPage: service.pageSize)
                guard requested == generation else { return }
                if next.order.isEmpty { break }
                posts += next.orderedPosts.filter { post in !posts.contains { $0.id == post.id } }
                hasNext = next.hasNext ?? false
                page += 1
            }

            await loadContext(for: posts, requested: requested)
            guard requested == generation else { return }

            loadedReadTeams = []
            await loadReadState(for: posts, requested: requested)
            guard requested == generation else { return }

            rows = ActivityDerivation.rows(posts: posts, channels: channels, users: users,
                                          myUserID: reader.profile.id,
                                          cursors: cursors, threadUnread: threadUnread)
            publish()
            phase = .loaded
            await refreshBadge()
        } catch {
            guard requested == generation else { return }
            phase = .failed(Self.message(for: error))
        }
    }

    /// The reader's profile + keys, fetched once per model (they change only in settings, and a mentions
    /// window is not the settings screen).
    private func reader(requested: Int) async throws -> (profile: ActivityProfile, keys: MentionKeys) {
        if let profile, !keys.isEmpty { return (profile, keys) }
        let profile = try await service.profile()
        guard requested == generation else { throw CancellationError() }
        self.profile = profile
        let keys = MentionKeys.derive(profile)
        self.keys = keys
        return (profile, keys)
    }

    /// Channels and authors for one window: one `GET /channels/{id}` per unseen channel and one
    /// `POST /users/ids` per window. Both are best effort — a row without its channel still draws, with
    /// the id the server sent, instead of failing the feed.
    private func loadContext(for posts: [MMPost], requested: Int) async {
        let missingChannels = ActivityDerivation.channelIDs(posts).filter { channels[$0] == nil }
        for channelID in missingChannels.prefix(60) {
            guard requested == generation else { return }
            if let channel = try? await service.channel(id: channelID) {
                channels[channelID] = channel
            }
        }
        let missingUsers = ActivityDerivation.profileIDs(posts).filter { users[$0] == nil }
        if !missingUsers.isEmpty, let loaded = try? await service.users(ids: missingUsers) {
            for user in loaded { users[user.id] = user }
        }
    }

    /// Read cursors + thread read state for the window.
    ///
    /// The channel cursor comes from the team's `channels/members` list (one request per team on screen),
    /// with a per-channel fallback for a row whose channel belongs to no team list (a DM/GM). Threads come
    /// from `?unread=true`, one request per team: under collapsed threads a reply's read state is *only*
    /// there, because reading a thread does not move the channel cursor.
    private func loadReadState(for posts: [MMPost], requested: Int) async {
        guard let userID = readerID else { return }
        let teams = Set(posts.compactMap { channels[$0.channelId]?.teamId }.filter { !$0.isEmpty })
        for teamID in teams.sorted() where !loadedReadTeams.contains(teamID) {
            guard requested == generation else { return }
            if let members = try? await service.channelReads(teamID: teamID, userID: userID) {
                for member in members {
                    cursors[member.channelId] = ActivityChannelCursor(channelID: member.channelId,
                                                                     lastViewedAt: member.lastViewedAt,
                                                                     mentionCount: Int(member.mentionCount))
                }
                loadedReadTeams.insert(teamID)
            }
            if let threads = try? await service.unreadThreads(teamID: teamID) {
                for thread in threads { threadUnread[thread.rootID] = thread }
            }
        }
        // A DM/GM mention (a message that names a key inside a direct message) lives on no team: read its
        // row's cursor directly. Only for channels the team lists did not cover.
        for channelID in Set(posts.map(\.channelId)) where cursors[channelID] == nil {
            guard requested == generation else { return }
            if let member = try? await service.channelRead(channelID: channelID, userID: userID) {
                cursors[channelID] = ActivityChannelCursor(channelID: channelID,
                                                          lastViewedAt: member.lastViewedAt,
                                                          mentionCount: Int(member.mentionCount))
            }
        }
    }

    private var readerID: String? { profile?.id ?? myUserID }

    // MARK: - Filtering

    func select(filter newFilter: ActivityFilter) {
        guard newFilter != filter else { return }
        filter = newFilter
        publish()
    }

    // MARK: - Marking read

    /// Read one row.
    ///
    /// A reply is read by its **thread** (`PUT …/threads/{id}/read/{ts}`), which is precise: it moves the
    /// thread's cursor and nothing else. A root post is read by its **channel** (`POST
    /// /channels/members/{me}/mark_read`) because Mattermost has no "read up to this post" endpoint —
    /// checked against the server's own route table, not assumed. Both labels in the view say exactly
    /// that, which is why they are two actions rather than one button that means two things.
    @discardableResult
    func markRead(_ row: ActivityRow) async -> Bool {
        guard !isMarking else { return false }
        isMarking = true
        actionError = nil
        defer { isMarking = false }
        do {
            if row.isThreadRow, let teamID = row.teamID, !teamID.isEmpty {
                let thread = try await service.markThreadRead(teamID: teamID, rootID: row.rootID,
                                                              at: now())
                threadUnread[thread.rootID] = thread
            } else {
                guard let userID = readerID else { throw MMError.notSignedIn }
                let response = try await service.markChannelsRead(channelIDs: [row.channelID],
                                                                 userID: userID)
                apply(cursors: response.lastViewedAtTimes)
            }
            rebuildRows()
            await refreshBadge()
            return true
        } catch {
            actionError = Self.writeMessage(for: error)
            return false
        }
    }

    /// Read every unread row's channel in one request (the server's own multi-channel form).
    @discardableResult
    func markAllRead() async -> Bool {
        guard !isMarking else { return false }
        let channelIDs = ActivityDerivation.unreadChannelIDs(rows)
        guard !channelIDs.isEmpty else { return true }
        guard let userID = readerID else {
            actionError = Self.writeMessage(for: MMError.notSignedIn)
            return false
        }
        isMarking = true
        actionError = nil
        defer { isMarking = false }
        do {
            let response = try await service.markChannelsRead(channelIDs: channelIDs, userID: userID)
            apply(cursors: response.lastViewedAtTimes)
            // The server recomputes those channel rows on a read, thread mentions included, so every reply
            // row in them is read now. Clearing the thread state of those rows is what makes "mark all
            // read" empty the list instead of leaving the reply rows behind.
            let roots = Set(rows.filter { channelIDs.contains($0.channelID) }.map(\.rootID)
                .filter { !$0.isEmpty })
            let stamp = now()
            for rootID in roots {
                let thread = threadUnread[rootID]
                threadUnread[rootID] = ActivityThreadUnread(rootID: rootID, unreadReplies: 0,
                                                            unreadMentions: 0,
                                                            lastViewedAt: max(thread?.lastViewedAt ?? 0, stamp))
            }
            rebuildRows()
            await refreshBadge()
            return true
        } catch {
            actionError = Self.writeMessage(for: error)
            return false
        }
    }

    private func apply(cursors times: [String: Int64]) {
        for (channelID, viewedAt) in times {
            let existing = cursors[channelID]
            cursors[channelID] = ActivityChannelCursor(channelID: channelID,
                                                      lastViewedAt: max(existing?.lastViewedAt ?? 0, viewedAt),
                                                      mentionCount: 0)
        }
    }

    // MARK: - The badge (SessionStore's numbers, never this model's)

    /// Fetch the server counters and hand them to the store.
    ///
    /// `SessionStore.serverBadgeInput` is the **one** function that turns these counters into
    /// `(mentions, isUnread)`; the background `MentionPoller` calls the same one. This model only
    /// transports them, so there is no second badge arithmetic anywhere in the app.
    func refreshBadge() async {
        guard let counters = try? await service.badgeCounters(), !counters.isEmpty else { return }
        let input = SessionStore.serverBadgeInput(mentionCounts: counters.map(\.mentionCount),
                                                  messageCounts: counters.map(\.msgCount))
        onBadgeInput?(input.mentions, input.isUnread)
    }

    // MARK: - Socket

    /// Apply one event (already scoped to a server by the rail).
    ///
    /// The feed is **live**: a mention that arrives while it is open appears without a manual refresh.
    /// That is the difference between a mentions inbox and a snapshot — and the card's third acceptance
    /// criterion. The filter for "is this a mention of me" is `ActivityDerivation.isLiveMention`
    /// (`props.mentions` when the server sends it, the reader's own keys otherwise — measured: 9.11.19
    /// sends no `mentions` prop).
    @discardableResult
    func handle(_ event: SocketEvent) -> EventOutcome {
        switch event {
        case .posted(let post):
            guard ActivityDerivation.isLiveMention(post, myUserID: readerID, keys: keys,
                                                  channel: channels[post.channelId]) else {
                return record(.ignored)
            }
            // The row needs its channel (name + team) and author; both are fetched off the main path so a
            // burst of mentions does not stall the list. The insert happens when they land, and until then
            // the row is simply not there yet — never drawn half-known.
            Task { [weak self] in await self?.insert(post: post) }
            return record(.inserted)
        case .postEdited(let post):
            guard rows.contains(where: { $0.postID == post.id }) else { return record(.ignored) }
            Task { [weak self] in await self?.patch(post: post) }
            return record(.patched)
        case .postDeleted(let post):
            let before = rows.count
            rows.removeAll { $0.postID == post.id }
            guard rows.count != before else { return record(.ignored) }
            publish()
            scheduleBadgeRefresh()
            return record(.removed)
        case .multipleChannelsViewed(let viewed):
            // My read state moved in another client of mine. These are the server's own cursors, and only
            // the channels in this window are applied.
            var changed = false
            for (channelID, viewedAt) in viewed.channelTimes where cursors[channelID] != nil {
                apply(cursors: [channelID: viewedAt])
                changed = true
            }
            guard changed else { return record(.ignored) }
            rebuildRows()
            scheduleBadgeRefresh()
            return record(.readStateChanged)
        case .postUnread(let unread):
            // Somebody marked a post unread (from any client): the channel's cursor moved back and its
            // counters went up. Taking the frame's own numbers keeps the row's dot exact.
            guard cursors[unread.channelID] != nil else { return record(.ignored) }
            cursors[unread.channelID] = ActivityChannelCursor(channelID: unread.channelID,
                                                             lastViewedAt: unread.lastViewedAt,
                                                             mentionCount: Int(unread.mentionCount))
            rebuildRows()
            scheduleBadgeRefresh()
            return record(.readStateChanged)
        case .threadReadChanged(let change):
            if change.threadID.isEmpty {
                // "the whole team's threads are read": every reply row in this window is read now.
                for (rootID, thread) in threadUnread {
                    threadUnread[rootID] = ActivityThreadUnread(rootID: thread.rootID,
                                                                unreadReplies: 0, unreadMentions: 0,
                                                                lastViewedAt: max(thread.lastViewedAt,
                                                                                  change.timestamp))
                }
            } else if let thread = threadUnread[change.threadID] {
                threadUnread[change.threadID] = ActivityThreadUnread(rootID: thread.rootID,
                                                                    unreadReplies: change.unreadReplies,
                                                                    unreadMentions: change.unreadMentions,
                                                                    lastViewedAt: max(thread.lastViewedAt,
                                                                                      change.timestamp))
            } else {
                return record(.ignored)
            }
            rebuildRows()
            scheduleBadgeRefresh()
            return record(.readStateChanged)
        case .channelUpdated(let channel):
            channels[channel.id] = channel
            rebuildRows()
            return record(.patched)
        case .userUpdated(let user):
            guard users[user.id] != nil else { return record(.ignored) }
            users[user.id] = user
            rebuildRows()
            return record(.patched)
        case .hello, .typing, .statusChange, .preferencesChanged, .preferencesDeleted, .reactionAdded, .reactionRemoved,
             .sidebarCategoryUpdated, .channelCreated, .channelDeleted, .channelRestored,
             .userAdded, .userRemoved, .channelMemberUpdated, .threadUpdated, .threadFollowChanged,
             .channelViewed, .plugin, .unhandled:
            // `.plugin` frames belong to a plugin's own client code (Calls reads them off the socket
            // directly); a mentions feed has no use for one.
            return record(.ignored)
        }
    }

    private func insert(post: MMPost) async {
        if channels[post.channelId] == nil,
           let channel = try? await service.channel(id: post.channelId) {
            channels[post.channelId] = channel
        }
        if users[post.userId] == nil, let loaded = try? await service.users(ids: [post.userId]) {
            for user in loaded { users[user.id] = user }
        }
        // A mention in a channel this window has never seen has no cursor yet: read it, so the row's dot
        // is the server's answer rather than "unread because unknown".
        if cursors[post.channelId] == nil, let userID = readerID,
           let member = try? await service.channelRead(channelID: post.channelId, userID: userID) {
            cursors[post.channelId] = ActivityChannelCursor(channelID: post.channelId,
                                                           lastViewedAt: member.lastViewedAt,
                                                           mentionCount: Int(member.mentionCount))
        }
        let row = ActivityDerivation.rows(posts: [post], channels: channels, users: users,
                                         myUserID: readerID, cursors: cursors,
                                         threadUnread: threadUnread)
        guard let newRow = row.first else { return }
        rows = ActivityDerivation.inserting(newRow, into: rows)
        insertedRowID = newRow.postID
        publish()
        scheduleBadgeRefresh()
    }

    private func patch(post: MMPost) async {
        guard let index = rows.firstIndex(where: { $0.postID == post.id }) else { return }
        rows[index].model = PostListDerivation.row(post: post, users: users,
                                                   myUserID: readerID, grouped: false)
        publish()
    }

    private func scheduleBadgeRefresh() {
        badgeTask?.cancel()
        badgeTask = Task { [weak self] in
            // Coalesce a burst of events into one counter read: the server recomputes these numbers on its
            // own schedule, and a request per frame would be a request per message.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshBadge()
        }
    }

    private func record(_ outcome: EventOutcome) -> EventOutcome {
        lastEventOutcome = outcome
        return outcome
    }

    // MARK: - Derivation

    private func rebuildRows() {
        rows = ActivityDerivation.rows(posts: rows.map(\.model.post), channels: channels,
                                      users: users, myUserID: readerID,
                                      cursors: cursors, threadUnread: threadUnread)
        publish()
    }

    private func publish() {
        visibleRows = ActivityDerivation.visible(rows, filter: filter)
    }

    // MARK: - Copy

    static func message(for error: Error) -> String {
        MMErrorCopy.message(for: error,
                            offline: "You are offline. Your mentions will load when the connection is back.",
                            timeout: "The server did not answer in time.",
                            unauthorized: "Your session has expired. Sign in again to read your mentions.",
                            forbidden: "You do not have permission to read your mentions.",
                            notFound: "Your mentions are not available on this server.",
                            rateLimited: "The server is rate limiting this app. Try again shortly.",
                            fallback: "Your mentions could not be loaded.")
    }

    static func writeMessage(for error: Error) -> String {
        MMErrorCopy.message(for: error,
                            offline: "You are offline. This mention stays unread until the connection is back.",
                            timeout: "The server did not answer in time — nothing was marked read.",
                            unauthorized: "Your session has expired. Sign in again to mark this read.",
                            forbidden: "You do not have permission to mark this read.",
                            notFound: "That channel or thread no longer exists.",
                            rateLimited: "The server is rate limiting this app. Try again shortly.",
                            fallback: "This mention could not be marked read.")
    }
}
