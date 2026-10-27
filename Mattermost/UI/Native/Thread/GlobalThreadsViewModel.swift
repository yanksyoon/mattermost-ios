// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/global_threads/threads_list/index.tsx (the paged list, `onEndReached` fetching
//        the next `before` page), app/actions/remote/thread.ts (`fetchThreads`: page by page id,
//        `is_following` implied by membership, `totalsOnly` for the tab counters), and
//        app/actions/websocket/threads.ts (thread_updated / thread_follow_changed /
//        thread_read_changed applied to a list that is on screen).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §13; no
// upstream source copied. The model shape is this repo's own, mirroring `ChannelListViewModel`:
// generation-guarded loads, a service seam, and merge rules a test pins.

import Foundation
import Combine

/// The team's followed threads: two tabs, paged, kept current by the socket.
@MainActor
final class GlobalThreadsViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// What one socket event did to this list.
    enum EventOutcome: Equatable {
        case ignored
        case patched
        case inserted
        case removed
        case unread
    }

    // MARK: Identity

    let teamID: String

    // MARK: Published state

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var tab: GlobalThreadsTab = .all
    @Published private(set) var threads: [MMThread] = []
    @Published private(set) var rows: [GlobalThreadRow] = []
    @Published private(set) var totals: ThreadTotals = .zero
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = false
    @Published private(set) var loadMoreError: String?
    /// The last socket event's effect (diagnostics/tests; never rendered).
    @Published private(set) var lastEventOutcome: EventOutcome = .ignored

    /// Diagnostics/tests.
    var loadedCount: Int { threads.count }
    var loadedThreadIDs: [String] { threads.map(\.id) }
    func thread(id: String) -> MMThread? { threads.first { $0.id == id } }
    /// The tab's own counter line ("3 unread threads").
    ///
    /// It is derived from the totals **as displayed** — the server's counters, bounded below by the
    /// rows on screen (`GlobalThreadsDerivation.displayedTotals`) — so an empty counter set can never
    /// be drawn over a list that has rows (T36-AV F3).
    var subtitle: String {
        GlobalThreadsDerivation.tabSubtitle(totals: displayedTotals, tab: tab)
    }

    /// The server's totals, corrected by what is actually drawn.
    var displayedTotals: ThreadTotals {
        GlobalThreadsDerivation.displayedTotals(totals, drawn: threads)
    }

    /// What the rail's Threads entry draws while this list's pane is closed: the unread count and
    /// whether the row is emphasised. One derivation for the sidebar and the phone's tab badge, so the
    /// two surfaces cannot report different numbers for the same team.
    var railEntry: ThreadsRailEntry {
        GlobalThreadsDerivation.railEntry(totals: totals, drawn: threads)
    }

    // MARK: Collaborators

    private let service: ThreadServing
    private let myUserID: String?
    private let now: () -> Date
    private let calendar: Calendar
    private let locale: Locale

    // MARK: Private state

    private var users: [String: MMUser] = [:]
    /// The `before` cursor for the next page — the **last thread id the server sent**.
    private var before: String?
    private var generation = 0

    // MARK: Init

    init(teamID: String,
         service: ThreadServing,
         myUserID: String? = nil,
         now: @escaping () -> Date = { Date() },
         calendar: Calendar = .current,
         locale: Locale = .current) {
        self.teamID = teamID
        self.service = service
        self.myUserID = myUserID
        self.now = now
        self.calendar = calendar
        self.locale = locale
    }

    // MARK: - Loading

    func load(ifNeeded: Bool = true) async {
        if ifNeeded, phase == .loaded { return }
        await reload()
    }

    func reload() async {
        generation += 1
        let requested = generation
        phase = .loading
        loadMoreError = nil
        before = nil
        do {
            let page = try await service.threads(teamID: teamID, before: nil,
                                                 perPage: service.pageSize,
                                                 unreadOnly: tab == .unreads)
            guard requested == generation else { return }
            threads = ThreadDerivation.sorted(page.threads)
            apply(totals: page)
            before = ThreadDerivation.nextBeforeCursor(page: page, pageSize: service.pageSize)
            hasMore = ThreadDerivation.hasMore(page: page, pageSize: service.pageSize)
            await loadProfiles(for: GlobalThreadsDerivation.profileIDs(in: page.threads))
            guard requested == generation else { return }
            publish()
            phase = .loaded
            // No second call for the counters: this server answers them on the list itself
            // (measured — `total`, `total_unread_threads`, `total_unread_mentions`,
            // `total_unread_urgent_mentions` all come back with the page), so `MMThreadList.totals`
            // is authoritative here.
        } catch {
            guard requested == generation else { return }
            phase = .failed(Self.message(for: error))
        }
    }

    /// Switch tabs. Both tabs are the same endpoint with `unread=true`, so the list is refetched —
    /// keeping the old rows while the new tab loads would show read threads under "Unreads".
    func select(tab newTab: GlobalThreadsTab) async {
        guard newTab != tab else { return }
        tab = newTab
        threads = []
        rows = []
        before = nil
        hasMore = false
        phase = .idle
        await reload()
    }

    /// The next page (a full page means "ask again").
    @discardableResult
    func loadMore() async -> Bool {
        guard phase == .loaded, hasMore, !isLoadingMore, let cursor = before else { return false }
        isLoadingMore = true
        loadMoreError = nil
        defer { isLoadingMore = false }
        let requested = generation
        do {
            let page = try await service.threads(teamID: teamID, before: cursor,
                                                 perPage: service.pageSize,
                                                 unreadOnly: tab == .unreads)
            guard requested == generation else { return false }
            let grew = page.threads.contains { incoming in
                !threads.contains { $0.id == incoming.id }
            }
            threads = ThreadDerivation.mergeThreads(existing: threads, page: page.threads)
            apply(totals: page)
            before = ThreadDerivation.nextBeforeCursor(page: page, pageSize: service.pageSize)
            hasMore = grew && ThreadDerivation.hasMore(page: page, pageSize: service.pageSize)
            await loadProfiles(for: GlobalThreadsDerivation.profileIDs(in: page.threads))
            guard requested == generation else { return false }
            publish()
            return grew
        } catch {
            guard requested == generation else { return false }
            loadMoreError = Self.message(for: error)
            return false
        }
    }

    private func loadProfiles(for ids: [String]) async {
        let missing = ids.filter { users[$0] == nil }
        guard !missing.isEmpty else { return }
        let loaded = (try? await service.users(ids: missing)) ?? []
        for user in loaded { users[user.id] = user }
    }

    /// Take a page's counters, but never let a page that omitted them zero the header.
    ///
    /// The counters describe the whole team, not the page that was asked for, so a `total`-less answer
    /// (a proxy that strips it, or a future server) must leave the previous counters standing — and
    /// `displayedTotals` keeps the line honest even if they really are zero.
    private func apply(totals page: MMThreadList) {
        guard page.includesTotals else { return }
        totals = page.totals
    }

    // MARK: - Socket

    /// Apply one event (already scoped to the team on screen).
    ///
    ///  - `thread_updated` is only sent to followers, so its arrival is also an insert on a list that
    ///    does not hold the thread yet (a reply to a thread followed on another device);
    ///  - `thread_follow_changed` with `state == false` removes the row — an unfollowed thread does
    ///    not belong to a list of followed threads, and the server's own list drops it too;
    ///  - `thread_read_changed` moves the badge and the row's position in "Unreads" without a refetch;
    ///  - `post_deleted` for a listed thread's **root** removes the row: the whole chain 404s once the
    ///    root is gone (measured), so the row would only open onto an error.
    @discardableResult
    func handle(_ event: SocketEvent) -> EventOutcome {
        let outcome: EventOutcome
        switch event {
        case .threadUpdated(let update):
            let thread = Self.followedThread(from: update)
            if let index = threads.firstIndex(where: { $0.id == thread.id }) {
                threads[index] = thread
                outcome = .patched
            } else {
                threads = ThreadDerivation.mergeThreads(existing: threads, page: [thread])
                outcome = .inserted
            }
            // A thread that just became unread belongs in the Unreads tab.
            if tab == .unreads, !thread.unread.isUnread {
                threads.removeAll { $0.id == thread.id }
            }
            scheduleProfileLoad(for: thread)
        case .threadFollowChanged(let change):
            if change.state {
                if let index = threads.firstIndex(where: { $0.id == change.threadID }) {
                    threads[index].replyCount = max(change.replyCount, threads[index].replyCount)
                    outcome = .patched
                } else {
                    // Following a thread that is not in the list: the next load will carry it. Keeping
                    // a placeholder row here would have to invent its root post.
                    outcome = .ignored
                }
            } else {
                let before = threads.count
                threads.removeAll { $0.id == change.threadID }
                outcome = threads.count == before ? .ignored : .removed
            }
        case .threadReadChanged(let change):
            if change.threadID.isEmpty {
                for index in threads.indices {
                    threads[index].unreadReplies = 0
                    threads[index].unreadMentions = 0
                    threads[index].lastViewedAt = max(threads[index].lastViewedAt, change.timestamp)
                }
                totals = ThreadTotals(total: totals.total, unreadThreads: 0, unreadMentions: 0,
                                      unreadUrgentMentions: 0)
                outcome = .unread
            } else if let index = threads.firstIndex(where: { $0.id == change.threadID }) {
                // The team's counters move with the thread, and the event carries that move: the
                // thread's new unread state **and** what it was before. Without this the header's
                // "N unread threads" (and the rail badge beside it) kept announcing a thread the
                // reader had just read from another client until the next page load — the same
                // question answered two ways, which is the T36-AV F3 class of defect.
                //
                // The model's own copy is the "before" value on purpose, not
                // `change.previousUnreadReplies`: a replayed event then finds the thread already read
                // and decrements nothing, so a duplicate frame cannot inflate the drop.
                let wasUnread = threads[index].unread.isUnread
                let wasMentions = threads[index].unreadMentions
                threads[index].unreadReplies = change.unreadReplies
                threads[index].unreadMentions = change.unreadMentions
                threads[index].lastViewedAt = max(threads[index].lastViewedAt, change.timestamp)
                if wasUnread, !threads[index].unread.isUnread, totals.unreadThreads > 0 {
                    totals.unreadThreads -= 1
                }
                if wasMentions > change.unreadMentions {
                    totals.unreadMentions = max(0, totals.unreadMentions
                                                - (wasMentions - change.unreadMentions))
                }
                if tab == .unreads, !threads[index].unread.isUnread {
                    threads.removeAll { $0.id == change.threadID }
                }
                outcome = .unread
            } else {
                return record(.ignored)
            }
        case .postDeleted(let post):
            // A deleted **root** takes its whole chain with it: after deleting a thread's root,
            // `GET /posts/{root}/thread` *and* `GET /posts/{reply}/thread` both answer 404 (measured,
            // T36-AV F5), while `GET …/threads/{root}` can still answer 200. A list that kept the row
            // would therefore offer a row that opens onto "This thread no longer exists.", so the row
            // goes with the root. A deleted reply is not this list's business: the thread survives.
            let before = threads.count
            threads.removeAll { $0.id == post.id }
            guard threads.count != before else { return record(.ignored) }
            outcome = .removed
        case .hello, .typing, .statusChange, .preferencesChanged, .userUpdated, .posted,
             .postEdited, .reactionAdded, .reactionRemoved, .channelViewed,
             .multipleChannelsViewed, .sidebarCategoryUpdated, .channelCreated, .channelDeleted,
             .channelUpdated, .channelRestored, .userAdded, .userRemoved,
             .channelMemberUpdated, .postUnread, .plugin, .unhandled:
            // `.plugin` frames belong to a plugin's own client code (Calls reads them off the socket
            // directly); a list of followed threads has no use for one.
            return record(.ignored)
        }
        publish()
        return record(outcome)
    }

    private func record(_ outcome: EventOutcome) -> EventOutcome {
        lastEventOutcome = outcome
        return outcome
    }

    private static func followedThread(from update: SocketThreadUpdated) -> MMThread {
        // `thread_updated` is delivered to followers (measured), and the thread object it carries has
        // no `is_following` field — arriving at all is the follow fact.
        update.thread
    }

    private func scheduleProfileLoad(for thread: MMThread) {
        let ids = GlobalThreadsDerivation.profileIDs(in: [thread]).filter { users[$0] == nil }
        guard !ids.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.loadProfiles(for: ids)
            self.publish()
        }
    }

    // MARK: - Derivation

    private func publish() {
        threads = ThreadDerivation.sorted(threads)
        rows = GlobalThreadsDerivation.rows(threads: threads,
                                            users: users,
                                            myUserID: myUserID,
                                            now: now(),
                                            calendar: calendar,
                                            locale: locale)
    }

    static func message(for error: Error) -> String {
        MMErrorCopy.message(for: error,
                            offline: "You are offline. Your threads will load when the connection is back.",
                            timeout: "The server did not answer in time.",
                            unauthorized: "Your session has expired. Sign in again to read your threads.",
                            forbidden: "You do not have permission to read these threads.",
                            notFound: "These threads are not available.",
                            rateLimited: "The server is rate limiting this app. Try again shortly.",
                            fallback: "Your threads could not be loaded.")
    }
}
