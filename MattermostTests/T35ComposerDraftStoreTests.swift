// T35 — the draft store: one row per (channel, thread root) in T29's `draft` table, one SQLite file
// per server, and "an empty draft is no draft" as the composer's rule rather than the store's.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0,
// `app/database/schema/server/table_schemas/draft.ts` and the draft helpers in
// `ios/Gekidou/Sources/Gekidou/Storage/Database+Posts.swift`. Licence Apache-2.0;
// see docs/THIRD_PARTY_NOTICES.md §12.
//
// The store adds **no new format**: it writes the `MMDraft` row T29 already defined, which is what
// lets a future global-drafts screen (S26) read the same rows.

import Foundation
import XCTest
@testable import Mattermost

@MainActor
final class T35ComposerDraftStoreTests: XCTestCase {

    private var harness: StoreHarness!
    private var store: RepositoryComposerDraftStore!

    override func setUpWithError() throws {
        harness = try StoreHarness()
        store = RepositoryComposerDraftStore(repository: harness.drafts)
    }

    override func tearDownWithError() throws {
        harness.cleanup()
        harness = nil
        store = nil
    }

    private func draft(_ channel: String, root: String = "", message: String,
                       files: [ComposerStoredFile] = [], at: Int64 = 1) -> ComposerDraft {
        ComposerDraft(channelID: channel, rootID: root, message: message, files: files, updateAt: at)
    }

    func testADraftSurvivesACloseAndReopen() async throws {
        await store.save(draft("c1", message: "half a thought", at: 10))
        await store.save(draft("c2", root: "r1", message: "thread thought", at: 11))

        let reopened = try harness.reopen()
        defer { reopened.close() }
        let afterRelaunch = RepositoryComposerDraftStore(repository: SQLiteDraftRepository(store: reopened))

        let channelDraft = await afterRelaunch.load(channelID: "c1", rootID: "")
        XCTAssertEqual(channelDraft?.message, "half a thought")
        let threadDraft = await afterRelaunch.load(channelID: "c2", rootID: "r1")
        XCTAssertEqual(threadDraft?.message, "thread thought")
    }

    func testAChannelAndItsThreadKeepSeparateDrafts() async {
        await store.save(draft("c1", message: "channel"))
        await store.save(draft("c1", root: "r1", message: "thread"))

        let channelDraft = await store.load(channelID: "c1", rootID: "")
        let threadDraft = await store.load(channelID: "c1", rootID: "r1")
        XCTAssertEqual(channelDraft?.message, "channel")
        XCTAssertEqual(threadDraft?.message, "thread")
        // Loading the channel's draft must not answer with the thread's.
        XCTAssertNotEqual(channelDraft?.message, "thread")
    }

    func testAnUploadedAttachmentSurvivesARelaunch() async throws {
        let files = [ComposerStoredFile(id: "f1", name: "diagram.png", mimeType: "image/png", size: 2048)]
        await store.save(draft("c1", message: "see attached", files: files, at: 5))

        let reopened = try harness.reopen()
        defer { reopened.close() }
        let afterRelaunch = RepositoryComposerDraftStore(repository: SQLiteDraftRepository(store: reopened))
        let restored = await afterRelaunch.load(channelID: "c1", rootID: "")
        XCTAssertEqual(restored?.message, "see attached")
        // The file keeps its server id, which is what makes it sendable without re-uploading.
        XCTAssertEqual(restored?.files, files)
    }

    func testSavingAnEmptyDraftDeletesTheRow() async {
        await store.save(draft("c1", message: "text"))
        let saved = await store.load(channelID: "c1", rootID: "")
        XCTAssertNotNil(saved)

        await store.save(draft("c1", message: ""))
        let cleared = await store.load(channelID: "c1", rootID: "")
        XCTAssertNil(cleared)
        XCTAssertEqual(try? harness.drafts.count(), 0)
    }

    func testRepeatedSavesKeepOneRowPerChannelAndTheNewestText() async {
        for index in 1...20 {
            await store.save(draft("c1", message: "typing \(index)", at: Int64(index)))
        }
        XCTAssertEqual(try? harness.drafts.count(), 1)
        let stored = await store.load(channelID: "c1", rootID: "")
        XCTAssertEqual(stored?.message, "typing 20")
    }

    func testAllDraftsAreNewestFirst() async {
        await store.save(draft("c1", message: "old", at: 1))
        await store.save(draft("c2", message: "new", at: 3))
        await store.save(draft("c3", message: "middle", at: 2))

        let list = await store.allDrafts(limit: 10)
        XCTAssertEqual(list.map(\.channelID), ["c2", "c3", "c1"])
        let none = await store.allDrafts(limit: 0)
        XCTAssertEqual(none.count, 0)
    }

    func testClearWipesEveryDraft() async {
        await store.save(draft("c1", message: "a"))
        await store.save(draft("c2", message: "b"))
        await store.clear()
        let list = await store.allDrafts(limit: 10)
        XCTAssertEqual(list.count, 0)
    }

    // MARK: - The per-server provider

    func testTheProviderOpensOneStorePerServerInItsOwnFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("t35-drafts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let provider = ComposerDraftStoreProvider(directory: directory)
        let first = ServerConfig(name: "One", url: URL(string: "https://one.example.com")!)
        let second = ServerConfig(name: "Two", url: URL(string: "https://two.example.com")!)

        let one = provider.store(for: first)
        let again = provider.store(for: first)
        let other = provider.store(for: second)

        // One store object per server (so two panes of one server share the file)…
        XCTAssertTrue((one as AnyObject) === (again as AnyObject))
        XCTAssertFalse((one as AnyObject) === (other as AnyObject))
        // …and the two files cannot be the same file: a channel id is only unique inside one server.
        XCTAssertNotEqual(ComposerDraftStoreProvider.path(for: first, in: directory),
                          ComposerDraftStoreProvider.path(for: second, in: directory))
    }

    func testThePerServerStoreReallyPersistsThroughGRDB() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("t35-drafts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let server = ServerConfig(name: "One", url: URL(string: "https://one.example.com")!)
        let provider = ComposerDraftStoreProvider(directory: directory)
        await provider.store(for: server).save(draft("c1", message: "kept across a reopen"))

        // A new provider (the app after a relaunch) opens the same file and finds the draft.
        let relaunched = ComposerDraftStoreProvider(directory: directory)
        let restored = await relaunched.store(for: server).load(channelID: "c1", rootID: "")
        XCTAssertEqual(restored?.message, "kept across a reopen")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: ComposerDraftStoreProvider.path(for: server, in: directory).path),
            "the per-server draft database is a file on disk, not a memory cache")
    }

    // MARK: - The in-memory double

    func testTheInMemoryStoreHasTheSameRules() async {
        let memory = InMemoryComposerDraftStore()
        await memory.save(draft("c1", message: "text"))
        XCTAssertEqual(memory.count, 1)
        let saved = await memory.load(channelID: "c1", rootID: "")
        XCTAssertEqual(saved?.message, "text")

        await memory.save(draft("c1", message: ""))
        XCTAssertEqual(memory.count, 0)
        let cleared = await memory.load(channelID: "c1", rootID: "")
        XCTAssertNil(cleared)
    }
}
