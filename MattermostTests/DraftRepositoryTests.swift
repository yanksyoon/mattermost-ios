import Foundation
import XCTest
@testable import Mattermost

/// T29 — "draft persistence per channel": the composer's state must survive a relaunch, be separate
/// per channel and per thread root, and not grow a row per keystroke.
final class DraftRepositoryTests: XCTestCase {

    private var harness: StoreHarness!

    override func setUpWithError() throws { harness = try StoreHarness() }
    override func tearDownWithError() throws { harness.cleanup(); harness = nil }

    func testDraftSurvivesACloseAndReopen() async throws {
        try await harness.drafts.save(T29Fixtures.draft(channelID: "c1", message: "half a thought",
                                                        updateAt: 1_000))
        try await harness.drafts.save(T29Fixtures.draft(channelID: "c2", rootID: "r1",
                                                        message: "thread draft", updateAt: 1_001))

        let reopened = try harness.reopen()
        defer { reopened.close() }
        let drafts = SQLiteDraftRepository(store: reopened)
        XCTAssertEqual(try drafts.draft(channelID: "c1", rootID: "")?.message, "half a thought")
        XCTAssertEqual(try drafts.draft(channelID: "c2", rootID: "r1")?.message, "thread draft")
        XCTAssertEqual(try drafts.count(), 2)
    }

    func testRepeatedSavesKeepOneRowPerChannel() async throws {
        for index in 1...20 {
            try await harness.drafts.save(T29Fixtures.draft(channelID: "c1",
                                                            message: "typing \(index)",
                                                            updateAt: Int64(index)))
        }
        XCTAssertEqual(try harness.drafts.count(), 1)
        XCTAssertEqual(try harness.drafts.draft(channelID: "c1", rootID: "")?.message, "typing 20")
    }

    func testEmptyMessageIsStillADraftRow() async throws {
        // The composer decides that an empty draft means "gone"; the store must not invent that
        // policy, or a user who clears their text and comes back would lose attachments-only state.
        try await harness.drafts.save(T29Fixtures.draft(channelID: "c1", message: "text",
                                                        updateAt: 1))
        try await harness.drafts.save(T29Fixtures.draft(channelID: "c1", message: "", updateAt: 2))
        let stored = try harness.drafts.draft(channelID: "c1", rootID: "")
        XCTAssertEqual(stored?.message, "")
        XCTAssertEqual(try harness.drafts.count(), 1)
    }

    func testAttachmentJSONRoundTrips() async throws {
        var draft = T29Fixtures.draft(channelID: "c1", message: "see attached", updateAt: 1)
        draft.files = .array([
            .object(["id": .string("f1"), "name": .string("log.txt"), "size": .number(12)]),
        ])
        try await harness.drafts.save(draft)

        let stored = try harness.drafts.draft(channelID: "c1", rootID: "")
        XCTAssertEqual(stored?.files, .array([
            .object(["id": .string("f1"), "name": .string("log.txt"), "size": .number(12)]),
        ]))
    }

    func testNilFilesRoundTripsAsAnEmptyArray() async throws {
        try await harness.drafts.save(T29Fixtures.draft(channelID: "c1", message: "x", updateAt: 1))
        XCTAssertEqual(try harness.drafts.draft(channelID: "c1", rootID: "")?.files, .array([]))
    }

    func testDeleteAllRemovesEveryDraft() async throws {
        try await harness.drafts.save(T29Fixtures.draft(channelID: "c1", message: "a", updateAt: 1))
        try await harness.drafts.save(T29Fixtures.draft(channelID: "c2", message: "b", updateAt: 2))
        let deletedCount = try await harness.drafts.deleteAll()
        XCTAssertEqual(deletedCount, 2)
        XCTAssertEqual(try harness.drafts.count(), 0)
        let deletedAgain = try await harness.drafts.deleteAll()
        XCTAssertEqual(deletedAgain, 0)
    }

    func testRecentDraftsAreOrderedByLastEdit() async throws {
        try await harness.drafts.save(T29Fixtures.draft(channelID: "c1", message: "old", updateAt: 10))
        try await harness.drafts.save(T29Fixtures.draft(channelID: "c2", message: "new", updateAt: 30))
        try await harness.drafts.save(T29Fixtures.draft(channelID: "c3", message: "mid", updateAt: 20))
        XCTAssertEqual(try harness.drafts.drafts(limit: 10).map(\.channelId), ["c2", "c3", "c1"])
        XCTAssertEqual(try harness.drafts.drafts(limit: 1).map(\.channelId), ["c2"])
        XCTAssertEqual(try harness.drafts.drafts(limit: 0).count, 0)
    }
}
