// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: `app/screens/saved_posts/` (the Saved tab list, its empty state and its swipe action),
//        `app/screens/pinned_messages/` (the channel's pinned list, opened from the channel header),
//        `app/actions/remote/post.ts` (the reads), `app/actions/remote/preference.ts` (unsave),
//        `app/actions/websocket/posts.ts` (`post_edited` patches a pinned row in place).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §16; no
// upstream source copied.
//
// Saved and pinned are the same list with two different sources, so they are one model with a `kind`
// rather than two files that drift. What differs is what a row's action writes and what a live change
// means: unsaving removes the row from *this* list, while unpinning removes it here **and** flips the
// channel's own row to "not pinned" — which is the card's "un-pinning updates in place".

import Foundation
import Combine

@MainActor
final class PostCollectionViewModel: ObservableObject {

    enum Kind: String, Equatable {
        case saved
        case pinned

        var title: String { self == .saved ? "Saved messages" : "Pinned messages" }
        /// The verb on the row's button.
        var removeTitle: String { self == .saved ? "Unsave" : "Unpin" }
        var emptyTitle: String {
            self == .saved ? "No saved messages yet" : "Nothing is pinned here"
        }
        var emptyBody: String {
            self == .saved
                ? "Save a message from its menu and it appears here, for this team."
                : "Pin a message from its menu to keep it at the top of this channel's list."
        }
    }

    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    // MARK: State

    let kind: Kind
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var rows: [PostRowModel] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = false
    /// Rows whose write is in flight (the button shows a spinner and cannot be double-tapped).
    @Published private(set) var busyPostIDs: Set<String> = []
    /// Set when the socket says a post was saved *elsewhere*: the list is stale and the view reloads.
    @Published private(set) var pendingReload = false

    // MARK: Collaborators

    private let service: SearchServing
    /// Saved posts are **team-scoped** on this client: the tab lives inside a team and the request
    /// carries `?team_id=`. That is narrower than the web/desktop Saved screen, which lists every
    /// team's saved posts — `docs/t39-search-build-note.md` §6 states it, and the row names the
    /// channel it came from so a row never arrives without a place.
    var teamID: String?
    var channelID: String?
    var myUserID: String?
    /// Told (postID, isPinned) after a successful pin/unpin, so the channel's own row can flip.
    var onPinnedChange: ((String, Bool) -> Void)?

    private var posts: [MMPost] = []
    private var users: [String: MMUser] = [:]
    /// The channels the saved rows live in, for the row's own "#channel" line.
    private(set) var channels: [String: MMChannel] = [:]
    private var page = 0
    private var generation = 0

    init(kind: Kind, service: SearchServing, myUserID: String? = nil) {
        self.kind = kind
        self.service = service
        self.myUserID = myUserID
    }

    // MARK: - Reading

    func load(ifNeeded: Bool = true) async {
        if ifNeeded, phase == .loaded { return }
        await reload()
    }

    func reload() async {
        guard kind == .saved ? (teamID != nil || channelID != nil) : (channelID != nil) else {
            phase = .idle
            return
        }
        generation += 1
        let requested = generation
        phase = .loading
        page = 0
        errorMessage = nil
        do {
            let list = try await fetch(page: 0)
            guard requested == generation else { return }
            posts = list.orderedPosts
            hasMore = list.order.count >= service.pageSize
            await loadProfiles(requested: requested)
            guard requested == generation else { return }
            await loadChannels(requested: requested)
            guard requested == generation else { return }
            rebuild()
            phase = .loaded
        } catch {
            guard requested == generation else { return }
            let message = Self.message(for: error, kind: kind)
            errorMessage = message
            phase = .failed(message)
        }
    }

    @discardableResult
    func loadMore() async -> Bool {
        guard phase == .loaded, hasMore, !isLoadingMore else { return false }
        isLoadingMore = true
        defer { isLoadingMore = false }
        generation += 1
        let requested = generation
        do {
            let next = page + 1
            let list = try await fetch(page: next)
            guard requested == generation else { return false }
            var known = Set(posts.map(\.id))
            var fresh: [MMPost] = []
            for post in list.orderedPosts where !known.contains(post.id) {
                known.insert(post.id)
                fresh.append(post)
            }
            page = next
            hasMore = list.order.count >= service.pageSize
            posts.append(contentsOf: fresh)
            await loadProfiles(requested: requested)
            guard requested == generation else { return false }
            await loadChannels(requested: requested)
            guard requested == generation else { return false }
            rebuild()
            return !fresh.isEmpty
        } catch {
            guard requested == generation else { return false }
            errorMessage = Self.message(for: error, kind: kind)
            return false
        }
    }

    private func fetch(page: Int) async throws -> MMPostList {
        switch kind {
        case .saved:
            return try await service.savedPosts(teamID: teamID,
                                                page: page,
                                                perPage: service.pageSize)
        case .pinned:
            guard let channelID else { throw MMError.notFound }
            return try await service.pinnedPosts(channelID: channelID,
                                                 page: page,
                                                 perPage: service.pageSize)
        }
    }

    private func loadProfiles(requested: Int) async {
        let ids = SearchResultRows.profileIDs(posts).filter { users[$0] == nil }
        guard !ids.isEmpty, let fetched = try? await service.users(ids: ids) else { return }
        guard requested == generation else { return }
        for user in fetched { users[user.id] = user }
    }

    /// The channels the saved rows came from, in one batched lookup.
    ///
    /// Only the Saved list needs this: the pinned sheet is one channel and says so in its title. A
    /// failure leaves the rows without their `#channel` line rather than failing the list — the same
    /// degradation rule as the author batch.
    private func loadChannels(requested: Int) async {
        guard kind == .saved, let teamID, !teamID.isEmpty else { return }
        let missing = SearchResultRows.channelIDs(posts).filter { channels[$0] == nil }
        guard !missing.isEmpty,
              let fetched = try? await service.channels(ids: missing, teamID: teamID) else { return }
        guard requested == generation else { return }
        for channel in fetched { channels[channel.id] = channel }
    }

    /// `#channel` (or a DM's name) for a row, when the list knows it. `nil` for the pinned sheet.
    func channelLabel(for postID: String) -> String? {
        guard kind == .saved,
              let post = posts.first(where: { $0.id == postID }),
              let channel = channels[post.channelId] else { return nil }
        return SearchResultCopy.channelLabel(channel)
    }

    private func rebuild() {
        rows = posts.map { post in
            PostListDerivation.row(post: post, users: users, myUserID: myUserID, grouped: false)
        }
    }

    // MARK: - Writing

    /// Unsave / unpin one post and drop the row **in place** (no refetch: a reload would make the
    /// list flicker for a change the client already knows the outcome of).
    @discardableResult
    func remove(_ postID: String) async -> Bool {
        guard !busyPostIDs.contains(postID) else { return false }
        busyPostIDs.insert(postID)
        defer { busyPostIDs.remove(postID) }
        errorMessage = nil
        do {
            switch kind {
            case .saved:
                try await service.setSaved(postID: postID, saved: false, userID: myUserID ?? "")
            case .pinned:
                try await service.setPinned(postID: postID, pinned: false)
            }
            posts.removeAll { $0.id == postID }
            rebuild()
            if kind == .pinned { onPinnedChange?(postID, false) }
            return true
        } catch {
            errorMessage = Self.writeMessage(for: error, kind: kind)
            return false
        }
    }

    /// Pin or unpin one post from a list that is not this one (a channel row's menu).
    @discardableResult
    func setPinned(_ pinned: Bool, postID: String) async -> Bool {
        guard !busyPostIDs.contains(postID) else { return false }
        busyPostIDs.insert(postID)
        defer { busyPostIDs.remove(postID) }
        do {
            try await service.setPinned(postID: postID, pinned: pinned)
            if !pinned {
                posts.removeAll { $0.id == postID }
                rebuild()
            }
            onPinnedChange?(postID, pinned)
            return true
        } catch {
            errorMessage = Self.writeMessage(for: error, kind: kind)
            return false
        }
    }

    // MARK: - The socket

    /// One event from the server's socket. Returns whether this list changed.
    @discardableResult
    func handle(_ event: SocketEvent) -> Bool {
        switch event {
        case .preferencesChanged(let preferences):
            guard kind == .saved else { return false }
            var changed = false
            for preference in preferences where preference.category == APIClient.savedPostCategory {
                let saved = preference.value == "true"
                let known = posts.contains { $0.id == preference.name }
                if !saved, known {
                    posts.removeAll { $0.id == preference.name }
                    changed = true
                } else if saved, !known, !preference.name.isEmpty {
                    // Saved on another device: this list does not hold the post, so it has to be
                    // refetched rather than invented. The view reloads when it sees this flip.
                    pendingReload = true
                    changed = true
                }
            }
            if changed { rebuild() }
            return changed
        case .preferencesDeleted(let preferences):
            // Measured (T48 socket probe): unsaving publishes `preferences_deleted`, a frame of its
            // own. Before this case existed the event was `.unhandled` and a post unsaved on another
            // device stayed on this screen until the list was reopened.
            guard kind == .saved else { return false }
            let removed = preferences.filter { $0.category == APIClient.savedPostCategory }
            guard !removed.isEmpty else { return false }
            let before = posts.count
            let names = Set(removed.map(\.name))
            posts.removeAll { names.contains($0.id) }
            guard posts.count != before else { return false }
            rebuild()
            return true
        case .postEdited(let post):
            guard let index = posts.firstIndex(where: { $0.id == post.id }) else { return false }
            posts[index] = post
            rebuild()
            return true
        case .postDeleted(let post):
            guard posts.contains(where: { $0.id == post.id }) else { return false }
            posts.removeAll { $0.id == post.id }
            rebuild()
            return true
        default:
            return false
        }
    }

    /// Clear the "reload because the socket told us" flag after the view has reloaded.
    func consumePendingReload() {
        pendingReload = false
    }

    // MARK: - Copy

    static func message(for error: Error, kind: Kind) -> String {
        let subject = kind == .saved ? "saved messages" : "pinned messages"
        return MMErrorCopy.message(for: error,
                                   offline: "You are offline. \(subject.capitalized) will load when the connection is back.",
                                   timeout: "The server did not answer in time.",
                                   unauthorized: "Your session has expired. Sign in again to see your \(subject).",
                                   forbidden: "You do not have permission to read these \(subject).",
                                   notFound: "This \(kind == .saved ? "team" : "channel") no longer exists.",
                                   rateLimited: "The server is rate limiting this app. Try again shortly.",
                                   fallback: "\(kind.title) could not be loaded.")
    }

    static func writeMessage(for error: Error, kind: Kind) -> String {
        let verb = kind == .saved ? "unsave" : "unpin"
        return MMErrorCopy.message(for: error,
                                   offline: "You are offline. The message is still \(kind == .saved ? "saved" : "pinned").",
                                   timeout: "The server did not answer in time, so the message is unchanged.",
                                   unauthorized: "Your session has expired. Sign in again to \(verb) this message.",
                                   forbidden: "You do not have permission to \(verb) this message.",
                                   notFound: "This message no longer exists.",
                                   rateLimited: "The server is rate limiting this app. Try again shortly.",
                                   fallback: "The message could not be \(kind == .saved ? "unsaved" : "unpinned").")
    }
}
