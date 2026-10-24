// T29 — in-memory implementations of every repository protocol.
//
// Why they exist (card scope 3: "an in-memory implementation for tests"):
//   1. A screen card (T32+) can build a view model against a populated store without touching disk.
//   2. `RepositoryContractTests` runs one set of assertions against both implementations, so the
//      protocol — not the SQL — is the contract. If the two disagree, the test says which.
//   3. A future "what if the store is unavailable" path has somewhere to degrade to.
//
// The state lives in one `InMemoryStore` (not one dictionary per repository) so cross-repository
// behaviour is real: deleting a channel must also remove its posts, exactly like the SQL version.

import Foundation

/// Shared mutable state behind the in-memory repositories. One lock, because every operation is an
/// in-process dictionary touch — there is no I/O to overlap.
final class InMemoryStore: @unchecked Sendable {
    private let lock = NSLock()
    let retention: MMRetentionPolicy

    private var posts: [String: MMPost] = [:]
    private var reactions: [ReactionKey: MMReaction] = [:]
    private var files: [String: MMFileInfo] = [:]
    private var channels: [String: MMChannel] = [:]
    private var members: [MemberKey: MMChannelMember] = [:]
    private var users: [String: MMUser] = [:]
    private var teams: [String: MMTeam] = [:]
    private var drafts: [MemberKey: MMDraft] = [:]
    private var cursors: [CursorKey: MMSyncCursor] = [:]
    private var preferences: [PreferenceKey: MMPreference] = [:]

    init(retention: MMRetentionPolicy = .unbounded) {
        self.retention = retention
    }

    struct ReactionKey: Hashable, Sendable {
        let postID: String
        let userID: String
        let emojiName: String
    }

    struct MemberKey: Hashable, Sendable {
        let first: String
        let second: String
    }

    struct CursorKey: Hashable, Sendable {
        let scope: MMSyncCursorScope
        let scopeKey: String
    }

    struct PreferenceKey: Hashable, Sendable {
        let userID: String
        let category: String
        let name: String
    }

    @discardableResult
    func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: Posts

    func post(_ id: String) -> MMPost? { withLock { posts[id] } }

    /// Same version guard as the SQL upsert: a payload older than what is stored is ignored.
    func upsertPost(_ post: MMPost) {
        withLock {
            if let existing = posts[post.id], post.updateAt < existing.updateAt { return }
            var stored = post
            // `post.props` is NOT NULL DEFAULT '{}' in the schema, so a nil round-trips as `{}`.
            // Normalising here keeps the two implementations observationally identical.
            if stored.props == nil { stored.props = .object([:]) }
            posts[post.id] = stored
        }
    }

    func markDeleted(_ postID: String, at deleteAt: Int64) {
        withLock {
            guard var post = posts[postID] else { return }
            post.deleteAt = deleteAt
            post.updateAt = max(post.updateAt, deleteAt)
            post.message = ""
            post.messageSource = ""
            post.props = .object([:])
            post.metadata = nil
            post.fileIds = []
            posts[postID] = post
            reactions = reactions.filter { $0.key.postID != postID }
        }
    }

    func channelPosts(_ channelID: String) -> [MMPost] {
        withLock {
            posts.values
                .filter { $0.channelId == channelID }
                .sorted { ($0.createAt, $0.id) > ($1.createAt, $1.id) }
        }
    }

    func threadPosts(_ rootID: String) -> [MMPost] {
        withLock {
            posts.values
                .filter { $0.rootId == rootID }
                .sorted { ($0.createAt, $0.id) < ($1.createAt, $1.id) }
        }
    }

    func evict(channelID: String, keepingNewest keep: Int) -> Int {
        withLock {
            let ordered = posts.values
                .filter { $0.channelId == channelID }
                .sorted { ($0.createAt, $0.id) > ($1.createAt, $1.id) }
            let doomed = ordered.dropFirst(max(0, keep))
            guard !doomed.isEmpty else { return 0 }
            for post in doomed {
                posts.removeValue(forKey: post.id)
            }
            let doomedIDs = Set(doomed.map(\.id))
            reactions = reactions.filter { !doomedIDs.contains($0.key.postID) }
            files = files.filter { !doomedIDs.contains($0.value.postId) }
            return doomed.count
        }
    }

    func postCount(inChannel channelID: String) -> Int {
        withLock { posts.values.filter { $0.channelId == channelID }.count }
    }

    func upsertReaction(_ reaction: MMReaction) {
        withLock {
            reactions[ReactionKey(postID: reaction.postId, userID: reaction.userId,
                                  emojiName: reaction.emojiName)] = reaction
        }
    }

    func removeReaction(postID: String, userID: String, emojiName: String) {
        withLock {
            reactions.removeValue(forKey: ReactionKey(postID: postID, userID: userID,
                                                      emojiName: emojiName))
        }
    }

    func reactions(postID: String) -> [MMReaction] {
        withLock {
            reactions.values
                .filter { $0.postId == postID }
                .sorted { ($0.createAt, $0.emojiName) < ($1.createAt, $1.emojiName) }
        }
    }

    func reactionCount() -> Int { withLock { reactions.count } }

    func upsertFile(_ file: MMFileInfo) { withLock { files[file.id] = file } }

    func files(postID: String) -> [MMFileInfo] {
        withLock {
            files.values.filter { $0.postId == postID }.sorted { $0.name < $1.name }
        }
    }

    func fileCount() -> Int { withLock { files.count } }

    // MARK: Channels

    func upsertChannel(_ channel: MMChannel) { withLock { channels[channel.id] = channel } }

    func channel(_ id: String) -> MMChannel? { withLock { channels[id] } }

    func channels(teamID: String) -> [MMChannel] {
        withLock {
            channels.values
                .filter { $0.teamId == teamID }
                .sorted { ($0.lastPostAt, $0.displayName) > ($1.lastPostAt, $1.displayName) }
        }
    }

    func upsertMember(_ member: MMChannelMember) {
        withLock {
            var stored = member
            // Same normalisation as the SQL column default ('{}').
            if stored.notifyProps == nil { stored.notifyProps = .object([:]) }
            members[MemberKey(first: member.channelId, second: member.userId)] = stored
        }
    }

    func member(channelID: String, userID: String) -> MMChannelMember? {
        withLock { members[MemberKey(first: channelID, second: userID)] }
    }

    func allMembers(userID: String) -> [MMChannelMember] {
        withLock { members.values.filter { $0.userId == userID } }
    }

    /// Mirrors the SQL: a view clears counters, records the view time, clears a manual mark.
    func markRead(channelID: String, userID: String, viewedAt: Int64) {
        withLock {
            guard var member = members[MemberKey(first: channelID, second: userID)] else { return }
            member.lastViewedAt = max(member.lastViewedAt, viewedAt)
            member.lastUpdateAt = max(member.lastUpdateAt, viewedAt)
            member.msgCount = 0
            member.mentionCount = 0
            member.urgentMentionCount = 0
            member.manuallyUnread = false
            members[MemberKey(first: channelID, second: userID)] = member
        }
    }

    func setUnread(channelID: String, userID: String, messageCount: Int64,
                   mentionCount: Int64, lastViewedAt: Int64) {
        withLock {
            guard var member = members[MemberKey(first: channelID, second: userID)] else { return }
            member.msgCount = messageCount
            member.mentionCount = mentionCount
            member.lastViewedAt = max(member.lastViewedAt, lastViewedAt)
            members[MemberKey(first: channelID, second: userID)] = member
        }
    }

    func setManuallyUnread(channelID: String, userID: String, unread: Bool) {
        withLock {
            guard var member = members[MemberKey(first: channelID, second: userID)] else { return }
            member.manuallyUnread = unread
            members[MemberKey(first: channelID, second: userID)] = member
        }
    }

    /// Removes the channel, its memberships and its posts (with reactions/files).
    @discardableResult
    func deleteChannel(_ channelID: String) -> Int {
        let removedPosts = evict(channelID: channelID, keepingNewest: 0)
        withLock {
            members = members.filter { $0.key.first != channelID }
            channels.removeValue(forKey: channelID)
        }
        return removedPosts
    }

    func recentChannels(userID: String, limit: Int) -> [MMChannel] {
        withLock {
            allMembersLocked(userID: userID)
                .sorted { $0.lastViewedAt > $1.lastViewedAt }
                .compactMap { channels[$0.channelId] }
                .prefix(max(0, limit))
                .map { $0 }
        }
    }

    private func allMembersLocked(userID: String) -> [MMChannelMember] {
        members.values.filter { $0.userId == userID }
    }

    // MARK: Users

    func upsertUser(_ user: MMUser) {
        withLock {
            if let existing = users[user.id], user.updateAt < existing.updateAt { return }
            users[user.id] = user
        }
    }

    func user(_ id: String) -> MMUser? { withLock { users[id] } }

    func users(ids: [String]) -> [MMUser] {
        withLock { ids.compactMap { users[$0] } }
    }

    func searchUsers(prefix: String, limit: Int) -> [MMUser] {
        withLock {
            users.values
                .filter { $0.username.lowercased().hasPrefix(prefix.lowercased()) }
                .sorted { $0.username < $1.username }
                .prefix(max(0, limit))
                .map { $0 }
        }
    }

    func userCount() -> Int { withLock { users.count } }

    // MARK: Teams

    func upsertTeam(_ team: MMTeam) { withLock { teams[team.id] = team } }

    func team(_ id: String) -> MMTeam? { withLock { teams[id] } }

    // MARK: Drafts

    func saveDraft(_ draft: MMDraft) {
        withLock {
            var stored = draft
            // Same normalisation as the SQL column default ('[]').
            if stored.files == nil { stored.files = .array([]) }
            drafts[MemberKey(first: draft.channelId, second: draft.rootId)] = stored
        }
    }

    func draft(channelID: String, rootID: String) -> MMDraft? {
        withLock { drafts[MemberKey(first: channelID, second: rootID)] }
    }

    func deleteDraft(channelID: String, rootID: String) -> Bool {
        withLock { drafts.removeValue(forKey: MemberKey(first: channelID, second: rootID)) != nil }
    }

    func deleteAllDrafts() -> Int {
        withLock {
            let count = drafts.count
            drafts.removeAll()
            return count
        }
    }

    func drafts(limit: Int) -> [MMDraft] {
        withLock {
            drafts.values.sorted { $0.updateAt > $1.updateAt }.prefix(max(0, limit)).map { $0 }
        }
    }

    func draftCount() -> Int { withLock { drafts.count } }

    // MARK: Cursors

    func setCursor(_ cursor: String, scope: MMSyncCursorScope, scopeKey: String, updatedAt: Int64) {
        withLock {
            cursors[CursorKey(scope: scope, scopeKey: scopeKey)] =
                MMSyncCursor(scope: scope, scopeKey: scopeKey, cursor: cursor, updatedAt: updatedAt)
        }
    }

    func cursor(scope: MMSyncCursorScope, scopeKey: String) -> MMSyncCursor? {
        withLock { cursors[CursorKey(scope: scope, scopeKey: scopeKey)] }
    }

    func cursors(scope: MMSyncCursorScope) -> [MMSyncCursor] {
        withLock {
            cursors.values.filter { $0.scope == scope }.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    func deleteCursor(scope: MMSyncCursorScope, scopeKey: String) -> Bool {
        withLock { cursors.removeValue(forKey: CursorKey(scope: scope, scopeKey: scopeKey)) != nil }
    }

    func deleteAllCursors() -> Int {
        withLock {
            let count = cursors.count
            cursors.removeAll()
            return count
        }
    }

    // MARK: Preferences

    func upsertPreference(_ preference: MMPreference) {
        withLock {
            preferences[PreferenceKey(userID: preference.userId, category: preference.category,
                                      name: preference.name)] = preference
        }
    }

    func preferences(userID: String, category: String) -> [MMPreference] {
        withLock {
            preferences.values
                .filter { $0.userId == userID && $0.category == category }
                .sorted { $0.name < $1.name }
        }
    }

    func preferenceValue(userID: String, category: String, name: String) -> String? {
        withLock {
            preferences[PreferenceKey(userID: userID, category: category, name: name)]?.value
        }
    }

    func deletePreference(userID: String, category: String, name: String) -> Bool {
        withLock {
            preferences.removeValue(forKey: PreferenceKey(userID: userID, category: category,
                                                         name: name)) != nil
        }
    }

    func deletePreferences(userID: String) -> Int {
        withLock {
            let before = preferences.count
            preferences = preferences.filter { $0.key.userID != userID }
            return before - preferences.count
        }
    }

    func preferenceCount() -> Int { withLock { preferences.count } }
}

// MARK: - PostRepository

final class InMemoryPostRepository: PostRepository {
    private let store: InMemoryStore
    private let retention: MMRetentionPolicy

    init(store: InMemoryStore, retention: MMRetentionPolicy? = nil) {
        self.store = store
        self.retention = retention ?? store.retention
    }

    func upsert(_ posts: [MMPost]) async throws {
        for post in posts {
            store.upsertPost(post)
        }
        guard retention.evictOnWrite,
              let maxPosts = retention.maxPostsPerChannel,
              let threshold = retention.writeThreshold else { return }
        for channelID in Set(posts.map(\.channelId)) {
            if store.postCount(inChannel: channelID) > threshold {
                store.evict(channelID: channelID, keepingNewest: maxPosts)
            }
        }
    }

    func markDeleted(_ postID: String, at deleteAt: Int64) async throws {
        store.markDeleted(postID, at: deleteAt)
    }

    func upsertReactions(_ reactions: [MMReaction]) async throws {
        reactions.forEach(store.upsertReaction)
    }

    func removeReaction(postID: String, userID: String, emojiName: String) async throws {
        store.removeReaction(postID: postID, userID: userID, emojiName: emojiName)
    }

    func upsertFiles(_ files: [MMFileInfo]) async throws {
        files.forEach(store.upsertFile)
    }

    func evict(channelID: String, keepingNewest count: Int) async throws -> Int {
        store.evict(channelID: channelID, keepingNewest: count)
    }

    func evictIfNeeded(channelID: String) async throws -> Int {
        guard retention.evictOnWrite, let maxPosts = retention.maxPostsPerChannel else { return 0 }
        guard store.postCount(inChannel: channelID) > maxPosts else { return 0 }
        return store.evict(channelID: channelID, keepingNewest: maxPosts)
    }

    func post(_ postID: String) throws -> MMPost? { store.post(postID) }

    func posts(inChannel channelID: String, before createAt: Int64?, limit: Int) throws -> [MMPost] {
        guard limit > 0 else { return [] }
        let ordered = store.channelPosts(channelID)
        let filtered = createAt.map { boundary in ordered.filter { $0.createAt < boundary } } ?? ordered
        return Array(filtered.prefix(limit))
    }

    func posts(inThread rootID: String, limit: Int) throws -> [MMPost] {
        guard limit > 0 else { return [] }
        let root = store.post(rootID)
        let replies = Array(store.threadPosts(rootID).suffix(max(0, limit - 1)))
        return (root.map { [$0] } ?? []) + replies
    }

    func reactions(postID: String) throws -> [MMReaction] { store.reactions(postID: postID) }

    func files(postID: String) throws -> [MMFileInfo] { store.files(postID: postID) }

    func count(inChannel channelID: String) throws -> Int { store.postCount(inChannel: channelID) }
}

// MARK: - ChannelRepository

final class InMemoryChannelRepository: ChannelRepository {
    private let store: InMemoryStore

    init(store: InMemoryStore) { self.store = store }

    func upsert(_ channels: [MMChannel]) async throws {
        channels.forEach(store.upsertChannel)
    }

    func upsertMembership(_ members: [MMChannelMember]) async throws {
        members.forEach(store.upsertMember)
    }

    func markRead(channelID: String, userID: String, viewedAt: Int64) async throws {
        store.markRead(channelID: channelID, userID: userID, viewedAt: viewedAt)
    }

    func setUnread(channelID: String, userID: String, messageCount: Int64,
                   mentionCount: Int64, lastViewedAt: Int64) async throws {
        store.setUnread(channelID: channelID, userID: userID, messageCount: messageCount,
                        mentionCount: mentionCount, lastViewedAt: lastViewedAt)
    }

    func setManuallyUnread(channelID: String, userID: String, unread: Bool) async throws {
        store.setManuallyUnread(channelID: channelID, userID: userID, unread: unread)
    }

    func delete(channelID: String) async throws -> Int {
        store.deleteChannel(channelID)
    }

    func channel(_ channelID: String) throws -> MMChannel? { store.channel(channelID) }

    func channels(teamID: String) throws -> [MMChannel] { store.channels(teamID: teamID) }

    func recentChannels(userID: String, limit: Int) throws -> [MMChannel] {
        store.recentChannels(userID: userID, limit: limit)
    }

    func membership(channelID: String, userID: String) throws -> MMChannelMember? {
        store.member(channelID: channelID, userID: userID)
    }

    func unread(channelID: String, userID: String) throws -> MMChannelUnread {
        guard let member = store.member(channelID: channelID, userID: userID) else {
            return .empty(channelID)
        }
        return MMChannelUnread(member: member)
    }

    func unreadByChannel(userID: String) throws -> [String: MMChannelUnread] {
        let unread = store.allMembers(userID: userID).map(MMChannelUnread.init(member:))
            .filter(\.isUnread)
        return Dictionary(uniqueKeysWithValues: unread.map { ($0.channelID, $0) })
    }

    func unreadTotals(userID: String) throws -> MMUnreadTotals {
        let members = store.allMembers(userID: userID)
        return MMUnreadTotals(
            messageCount: members.reduce(0) { $0 + $1.msgCount },
            mentionCount: members.reduce(0) { $0 + $1.mentionCount },
            urgentMentionCount: members.reduce(0) { $0 + $1.urgentMentionCount },
            unreadChannelCount: members.filter { $0.msgCount > 0 || $0.manuallyUnread }.count)
    }
}

// MARK: - DraftRepository

final class InMemoryDraftRepository: DraftRepository {
    private let store: InMemoryStore

    init(store: InMemoryStore) { self.store = store }

    func save(_ draft: MMDraft) async throws { store.saveDraft(draft) }

    func delete(channelID: String, rootID: String) async throws -> Bool {
        store.deleteDraft(channelID: channelID, rootID: rootID)
    }

    func deleteAll() async throws -> Int { store.deleteAllDrafts() }

    func draft(channelID: String, rootID: String) throws -> MMDraft? {
        store.draft(channelID: channelID, rootID: rootID)
    }

    func drafts(limit: Int) throws -> [MMDraft] { store.drafts(limit: limit) }

    func count() throws -> Int { store.draftCount() }
}

// MARK: - SyncCursorRepository

final class InMemorySyncCursorRepository: SyncCursorRepository {
    private let store: InMemoryStore

    init(store: InMemoryStore) { self.store = store }

    func set(_ cursor: String, scope: MMSyncCursorScope, scopeKey: String, updatedAt: Int64) async throws {
        store.setCursor(cursor, scope: scope, scopeKey: scopeKey, updatedAt: updatedAt)
    }

    func cursor(scope: MMSyncCursorScope, scopeKey: String) throws -> MMSyncCursor? {
        store.cursor(scope: scope, scopeKey: scopeKey)
    }

    func all(scope: MMSyncCursorScope) throws -> [MMSyncCursor] {
        store.cursors(scope: scope)
    }

    func clear(scope: MMSyncCursorScope, scopeKey: String) async throws -> Bool {
        store.deleteCursor(scope: scope, scopeKey: scopeKey)
    }

    func clearAll() async throws -> Int { store.deleteAllCursors() }

    func setLastSocketEventID(_ eventID: String, serverID: String, updatedAt: Int64) async throws {
        store.setCursor(eventID, scope: .serverSocketEvent, scopeKey: serverID, updatedAt: updatedAt)
    }

    func lastSocketEventID(serverID: String) throws -> String? {
        store.cursor(scope: .serverSocketEvent, scopeKey: serverID)?.cursor
    }

    func setLastPostID(_ postID: String, channelID: String, updatedAt: Int64) async throws {
        store.setCursor(postID, scope: .channelLastPost, scopeKey: channelID, updatedAt: updatedAt)
    }

    func lastPostID(channelID: String) throws -> String? {
        store.cursor(scope: .channelLastPost, scopeKey: channelID)?.cursor
    }
}

// MARK: - PreferenceRepository

final class InMemoryPreferenceRepository: PreferenceRepository {
    private let store: InMemoryStore

    init(store: InMemoryStore) { self.store = store }

    func upsert(_ preferences: [MMPreference]) async throws {
        preferences.forEach(store.upsertPreference)
    }

    func preferences(userID: String, category: String) throws -> [MMPreference] {
        store.preferences(userID: userID, category: category)
    }

    func value(userID: String, category: String, name: String) throws -> String? {
        store.preferenceValue(userID: userID, category: category, name: name)
    }

    func delete(userID: String, category: String, name: String) async throws -> Bool {
        store.deletePreference(userID: userID, category: category, name: name)
    }

    func deleteAll(userID: String) async throws -> Int {
        store.deletePreferences(userID: userID)
    }

    func count() throws -> Int { store.preferenceCount() }
}

// MARK: - UserRepository

final class InMemoryUserRepository: UserRepository {
    private let store: InMemoryStore

    init(store: InMemoryStore) { self.store = store }

    func upsert(_ users: [MMUser]) async throws { users.forEach(store.upsertUser) }

    func user(_ userID: String) throws -> MMUser? { store.user(userID) }

    func users(ids: [String]) throws -> [MMUser] { store.users(ids: ids) }

    func searchUsers(usernamePrefix: String, limit: Int) throws -> [MMUser] {
        let prefix = usernamePrefix.hasPrefix("@")
            ? String(usernamePrefix.dropFirst())
            : usernamePrefix
        guard !prefix.isEmpty else { return [] }
        return store.searchUsers(prefix: prefix, limit: limit)
    }

    func count() throws -> Int { store.userCount() }
}
