import Foundation
import XCTest
@testable import Mattermost

// Shared fixtures for the T29 store tests. Everything here is deterministic: no network, no real
// clock, no Keychain, so the suite behaves the same on Catalyst and on the simulator.

/// A store in a fresh temporary directory, removed when the harness dies.
final class StoreHarness {
    let directory: URL
    let store: MMStore
    let posts: SQLitePostRepository
    let channels: SQLiteChannelRepository
    let drafts: SQLiteDraftRepository
    let cursors: SQLiteSyncCursorRepository
    let preferences: SQLitePreferenceRepository
    let users: SQLiteUserRepository

    init(retention: MMRetentionPolicy = .unbounded,
         migrations: [MMMigration] = MMMigration.allCases,
         serverID: String = "server-1") throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("t29-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try MMStore.open(at: directory.appendingPathComponent("app.db").path,
                                 serverID: serverID,
                                 serverURL: URL(string: "https://mm.invalid")!,
                                 retention: retention,
                                 migrations: migrations)
        posts = SQLitePostRepository(store: store)
        channels = SQLiteChannelRepository(store: store)
        drafts = SQLiteDraftRepository(store: store)
        cursors = SQLiteSyncCursorRepository(store: store)
        preferences = SQLitePreferenceRepository(store: store)
        users = SQLiteUserRepository(store: store)
    }

    var path: String { directory.appendingPathComponent("app.db").path }

    /// Reopens the same file with a (possibly different) chain — what a relaunch or an app upgrade
    /// actually does.
    func reopen(migrations: [MMMigration] = MMMigration.allCases,
                retention: MMRetentionPolicy = .unbounded) throws -> MMStore {
        store.close()
        return try MMStore.open(at: path, serverID: "server-1",
                                serverURL: URL(string: "https://mm.invalid")!,
                                retention: retention, migrations: migrations)
    }

    func cleanup() {
        store.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// The same repositories, backed by dictionaries instead of SQLite.
final class MemoryHarness {
    let inMemory = InMemoryStore()
    let posts: InMemoryPostRepository
    let channels: InMemoryChannelRepository
    let drafts: InMemoryDraftRepository
    let cursors: InMemorySyncCursorRepository
    let preferences: InMemoryPreferenceRepository
    let users: InMemoryUserRepository

    init(retention: MMRetentionPolicy = .unbounded) {
        posts = InMemoryPostRepository(store: inMemory, retention: retention)
        channels = InMemoryChannelRepository(store: inMemory)
        drafts = InMemoryDraftRepository(store: inMemory)
        cursors = InMemorySyncCursorRepository(store: inMemory)
        preferences = InMemoryPreferenceRepository(store: inMemory)
        users = InMemoryUserRepository(store: inMemory)
    }
}

// MARK: - Fixtures

enum T29Fixtures {
    static func channel(id: String,
                        teamID: String = "team-1",
                        displayName: String = "Town Square",
                        type: String = "O",
                        lastPostAt: Int64 = 0) -> MMChannel {
        MMChannel(id: id, name: id, displayName: displayName, type: type, teamId: teamID,
                  lastPostAt: lastPostAt, totalMsgCount: 0)
    }

    static func post(id: String,
                     channelID: String = "channel-1",
                     userID: String = "user-1",
                     createAt: Int64,
                     message: String = "hello",
                     rootID: String = "",
                     updateAt: Int64? = nil,
                     deleteAt: Int64 = 0) -> MMPost {
        MMPost(id: id,
               createAt: createAt,
               updateAt: updateAt ?? createAt,
               deleteAt: deleteAt,
               userId: userID,
               channelId: channelID,
               rootId: rootID,
               message: message)
    }

    static func member(channelID: String,
                       userID: String = "user-1",
                       msgCount: Int64 = 0,
                       mentionCount: Int64 = 0,
                       urgentMentionCount: Int64 = 0,
                       lastViewedAt: Int64 = 0,
                       lastUpdateAt: Int64 = 0,
                       manuallyUnread: Bool = false) -> MMChannelMember {
        MMChannelMember(channelId: channelID,
                        userId: userID,
                        lastViewedAt: lastViewedAt,
                        msgCount: msgCount,
                        mentionCount: mentionCount,
                        urgentMentionCount: urgentMentionCount,
                        lastUpdateAt: lastUpdateAt,
                        manuallyUnread: manuallyUnread)
    }

    static func user(id: String, username: String, updateAt: Int64 = 1, deleteAt: Int64 = 0) -> MMUser {
        MMUser(id: id, username: username, email: "\(username)@mm.invalid",
               firstName: "Ada", lastName: "Lovelace", nickname: username,
               deleteAt: deleteAt, updateAt: updateAt)
    }

    static func reaction(postID: String, userID: String = "user-2",
                         emojiName: String = "thumbsup", createAt: Int64 = 10) -> MMReaction {
        MMReaction(userId: userID, postId: postID, emojiName: emojiName, createAt: createAt)
    }

    static func file(id: String, postID: String, name: String = "diagram.png") -> MMFileInfo {
        MMFileInfo(id: id, postId: postID, name: name, fileExtension: "png",
                   mimeType: "image/png", size: 1024, width: 640, height: 480,
                   imageThumbnail: "", localPath: "", isBlocked: false)
    }

    static func draft(channelID: String, rootID: String = "", message: String,
                      updateAt: Int64 = 1) -> MMDraft {
        MMDraft(channelId: channelID, rootId: rootID, message: message, updateAt: updateAt)
    }

    /// A deterministic, verbose post body — the size measurement must not depend on `UUID()` or on
    /// how compressible a random string happens to be.
    static func body(seed: Int, words: Int = 24) -> String {
        let vocabulary = ["deploy", "rollback", "channel", "mention", "thread", "reaction",
                          "attachment", "index", "migration", "postgres", "release", "checklist",
                          "review", "staging", "canary", "latency", "timeout", "socket"]
        var state = UInt64(seed) &* 6364136223846793005 &+ 1442695040888963407
        var out: [String] = []
        for _ in 0..<words {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            out.append(vocabulary[Int(state >> 33) % vocabulary.count])
        }
        return out.joined(separator: " ")
    }
}

/// The repository protocols, bundled so one contract suite can run against either backing store.
struct RepositorySet {
    let posts: PostRepository
    let channels: ChannelRepository
    let drafts: DraftRepository
    let cursors: SyncCursorRepository
    let preferences: PreferenceRepository
    let users: UserRepository
}

extension StoreHarness {
    var repositories: RepositorySet {
        RepositorySet(posts: posts, channels: channels, drafts: drafts,
                      cursors: cursors, preferences: preferences, users: users)
    }
}

extension MemoryHarness {
    var repositories: RepositorySet {
        RepositorySet(posts: posts, channels: channels, drafts: drafts,
                      cursors: cursors, preferences: preferences, users: users)
    }
}
