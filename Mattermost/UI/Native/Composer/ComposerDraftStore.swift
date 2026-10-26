// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/actions/views/advanced_text_editor.ts / draft_handler (the draft is written on every
//        keystroke burst and read back when the composer mounts), app/database/schema/server/
//        table_schemas/draft.ts + ios/Gekidou/Sources/Gekidou/Storage/Database+Posts.swift (the
//        drafts table), app/screens/global_drafts (the list the same table feeds).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §12.
//
// This file is the bridge between the composer and T29's store, and it deliberately adds **no new
// storage format**: a draft is written to `DraftRepository` as the `draft` row T29 already defined
// (identity = channel + thread root), so `MMDraft`/`MMSchema` do not change and a future global-drafts
// screen reads the same rows. What is new here is only the mapping between that row and the
// composer's own value type, plus the per-server store lifetime.
//
// Why the store is per server and lazily opened: the row's identity is a channel id, which is only
// unique inside one server's database (two servers can legitimately have the same channel id —— a
// restored backup, a re-created team), so drafts are kept in one SQLite file per server — the same
// partitioning T29 chose for posts. Opening is deferred to the first draft the composer touches, so
// a session that never types anything never pays for a database.

import Foundation

/// What the composer needs from storage.
@MainActor
protocol ComposerDraftStoring: AnyObject {
    func load(channelID: String, rootID: String) async -> ComposerDraft?
    func save(_ draft: ComposerDraft) async
    func delete(channelID: String, rootID: String) async
    /// Most recently edited first — the shape a global-drafts list needs.
    func allDrafts(limit: Int) async -> [ComposerDraft]
    /// Sign-out / "clear local data".
    func clear() async
}

// MARK: - Mapping to the T29 row

enum ComposerDraftMapping {

    /// `ComposerDraft` → the `draft` row fields T29 owns.
    ///
    /// The attachment descriptors go into `files` as a JSON array of
    /// `{id, name, mime_type, size}`: that is what makes "uploaded, not sent" survive a relaunch, and
    /// it keeps the row's `message` a plain string (upstream's draft row does the same).
    static func row(_ draft: ComposerDraft) -> MMDraft {
        MMDraft(channelId: draft.channelID,
                rootId: draft.rootID,
                message: draft.message,
                files: jsonValue(of: draft.files),
                metadata: nil,
                type: "",
                updateAt: draft.updateAt)
    }

    /// The inverse. A row whose `files` blob cannot be read keeps its message: losing the text because
    /// an attachment list is malformed would be the worst possible failure mode here.
    static func draft(_ row: MMDraft) -> ComposerDraft {
        ComposerDraft(channelID: row.channelId,
                      rootID: row.rootId,
                      message: row.message,
                      files: storedFiles(from: row.files),
                      updateAt: row.updateAt)
    }

    static func jsonValue(of files: [ComposerStoredFile]) -> JSONValue? {
        guard !files.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(files),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return value
    }

    static func storedFiles(from value: JSONValue?) -> [ComposerStoredFile] {
        guard let value,
              let data = try? JSONEncoder().encode(value),
              let files = try? JSONDecoder().decode([ComposerStoredFile].self, from: data) else {
            return []
        }
        return files
    }
}

// MARK: - GRDB-backed store

/// The production store: T29's `DraftRepository`, one file per server.
@MainActor
final class RepositoryComposerDraftStore: ComposerDraftStoring {
    private let repository: DraftRepository

    init(repository: DraftRepository) {
        self.repository = repository
    }

    func load(channelID: String, rootID: String) async -> ComposerDraft? {
        do {
            guard let row = try repository.draft(channelID: channelID, rootID: rootID) else {
                return nil
            }
            let draft = ComposerDraftMapping.draft(row)
            return draft.isEmpty ? nil : draft
        } catch {
            MMLog.debug("ComposerDraft", "read failed: \(error.localizedDescription)")
            return nil
        }
    }

    func save(_ draft: ComposerDraft) async {
        // An emptied composer deletes the row instead of storing a blank one: "no draft" and "a draft
        // of nothing" must not be two states, or clearing the input would leave a row that a relaunch
        // restores as an empty composer with a stale timestamp.
        guard !draft.isEmpty else {
            await delete(channelID: draft.channelID, rootID: draft.rootID)
            return
        }
        do {
            try await repository.save(ComposerDraftMapping.row(draft))
        } catch {
            MMLog.debug("ComposerDraft", "save failed: \(error.localizedDescription)")
        }
    }

    func delete(channelID: String, rootID: String) async {
        do {
            _ = try await repository.delete(channelID: channelID, rootID: rootID)
        } catch {
            MMLog.debug("ComposerDraft", "delete failed: \(error.localizedDescription)")
        }
    }

    func allDrafts(limit: Int) async -> [ComposerDraft] {
        let rows = (try? repository.drafts(limit: limit)) ?? []
        return rows.map(ComposerDraftMapping.draft).filter { !$0.isEmpty }
    }

    func clear() async {
        _ = try? await repository.deleteAll()
    }
}

// MARK: - In-memory store

/// The test double, and the fallback when a server's database cannot be opened (a full disk, a
/// migration failure). A composer whose drafts live only in memory still sends messages; it just
/// forgets them on relaunch, which is strictly better than a composer that refuses to type.
@MainActor
final class InMemoryComposerDraftStore: ComposerDraftStoring {
    private var rows: [String: ComposerDraft] = [:]

    init() {}

    private func key(_ channelID: String, _ rootID: String) -> String { "\(channelID)/\(rootID)" }

    func load(channelID: String, rootID: String) async -> ComposerDraft? {
        let draft = rows[key(channelID, rootID)]
        return (draft?.isEmpty ?? true) ? nil : draft
    }

    func save(_ draft: ComposerDraft) async {
        guard !draft.isEmpty else {
            await delete(channelID: draft.channelID, rootID: draft.rootID)
            return
        }
        rows[key(draft.channelID, draft.rootID)] = draft
    }

    func delete(channelID: String, rootID: String) async {
        rows[key(channelID, rootID)] = nil
    }

    func allDrafts(limit: Int) async -> [ComposerDraft] {
        guard limit > 0 else { return [] }
        return rows.values
            .filter { !$0.isEmpty }
            .sorted { $0.updateAt > $1.updateAt }
            .prefix(limit)
            .map { $0 }
    }

    func clear() async {
        rows.removeAll()
    }

    /// Tests only: how many rows are stored (the "a cleared composer leaves no row" rule).
    var count: Int { rows.count }
}

// MARK: - Per-server store lifetime

/// One draft store per server, opened on first use.
@MainActor
final class ComposerDraftStoreProvider {

    /// Where the per-server databases live. `Application Support/MattermostStores/<server id>.sqlite`.
    ///
    /// `nonisolated` because it is a pure path computation: the double is created in tests from a
    /// non-isolated context, and a directory URL has no actor of its own.
    nonisolated static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("MattermostStores", isDirectory: true)
    }

    private var stores: [UUID: ComposerDraftStoring] = [:]
    private let directory: URL
    private let makeStore: ((ServerConfig) throws -> ComposerDraftStoring)?

    /// - Parameter makeStore: test seam. Production leaves it nil and opens a GRDB store.
    init(directory: URL = ComposerDraftStoreProvider.defaultDirectory,
         makeStore: ((ServerConfig) throws -> ComposerDraftStoring)? = nil) {
        self.directory = directory
        self.makeStore = makeStore
    }

    func store(for server: ServerConfig) -> ComposerDraftStoring {
        if let existing = stores[server.id] { return existing }
        let store: ComposerDraftStoring
        if let makeStore, let made = try? makeStore(server) {
            store = made
        } else if makeStore != nil {
            store = InMemoryComposerDraftStore()
        } else if let opened = Self.openStore(for: server, in: directory) {
            store = opened
        } else {
            MMLog.debug("ComposerDraft", "falling back to in-memory drafts for \(server.id.uuidString)")
            store = InMemoryComposerDraftStore()
        }
        stores[server.id] = store
        return store
    }

    /// Forget one server's drafts (sign-out, or the server being removed).
    func clear(_ serverID: UUID) {
        guard let store = stores.removeValue(forKey: serverID) else { return }
        Task { await store.clear() }
    }

    static func path(for server: ServerConfig, in directory: URL) -> URL {
        directory.appendingPathComponent("\(server.id.uuidString).sqlite")
    }

    private static func openStore(for server: ServerConfig, in directory: URL) -> ComposerDraftStoring? {
        do {
            let path = path(for: server, in: directory).path
            let store = try MMStore.open(at: path,
                                         serverID: server.id.uuidString,
                                         serverURL: server.url)
            return RepositoryComposerDraftStore(repository: SQLiteDraftRepository(store: store))
        } catch {
            MMLog.debug("ComposerDraft", "store open failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Delete every server's draft database. Used by the `-uiTestResetPersistedState` seam so a test
    /// that types a draft cannot leak it into the next test, and by "clear local data".
    nonisolated static func deleteAllStores(in directory: URL = ComposerDraftStoreProvider.defaultDirectory) {
        try? FileManager.default.removeItem(at: directory)
    }
}
