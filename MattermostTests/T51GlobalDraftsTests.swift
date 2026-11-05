// T51 — the global drafts list (S26): what a row derives (snippet, age, channel label, thread vs
// channel), which drafts belong to a team, and that a delete is a store delete rather than a UI
// removal.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0,
// `app/screens/global_drafts/` + `app/database/schema/server/table_schemas/draft.ts`.
// Licence Apache-2.0; see docs/THIRD_PARTY_NOTICES.md §20.
//
// Scheduling (S40) is **not** covered here: this fixture answers 404 on every scheduled-post route
// (measured, docs/t51-build-note.md §6), so no scheduling request ships in this tree and the named
// follow-up card carries that half. The drafts half is fully exercised below.

import Foundation
import XCTest
@testable import Mattermost

@MainActor
final class T51GlobalDraftsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Fixtures

    private func label(_ id: String, _ display: String,
                       kind: SidebarChannelKind = .publicChannel,
                       name: String? = nil, team: String? = "t1") -> DraftChannelLabel {
        DraftChannelLabel(channelID: id, name: name ?? display.lowercased(),
                          displayName: display, kind: kind, teamID: team)
    }

    private func draft(_ channel: String, root: String = "", message: String,
                       files: Int = 0, at: Int64 = 1, team: String? = "t1") -> ComposerDraft {
        ComposerDraft(channelID: channel,
                      rootID: root,
                      message: message,
                      files: (0..<files).map {
                          ComposerStoredFile(id: "f\($0)", name: "a\($0).png",
                                             mimeType: "image/png", size: 1)
                      },
                      updateAt: at,
                      teamID: team)
    }

    private func ms(_ secondsFromNow: TimeInterval) -> Int64 {
        Int64(now.addingTimeInterval(secondsFromNow).timeIntervalSince1970 * 1000)
    }

    // MARK: - Snippets (pure)

    func testASnippetCollapsesEveryKindOfWhitespace() {
        XCTAssertEqual(GlobalDraftDerivation.snippet(message: "  hello\n\n  there\tfriend ", attachmentCount: 0),
                       "hello there friend")
    }

    func testAnAttachmentOnlyDraftNamesItsCount() {
        XCTAssertEqual(GlobalDraftDerivation.snippet(message: "", attachmentCount: 0), "Empty draft")
        XCTAssertEqual(GlobalDraftDerivation.snippet(message: "", attachmentCount: 1), "1 attachment")
        XCTAssertEqual(GlobalDraftDerivation.snippet(message: "", attachmentCount: 3), "3 attachments")
        // Whitespace-only text is the same as no text: the row must not look blank.
        XCTAssertEqual(GlobalDraftDerivation.snippet(message: "   \n ", attachmentCount: 2), "2 attachments")
    }

    func testALongSnippetIsCutAtTheLimitAndSaysSo() {
        let text = String(repeating: "a", count: GlobalDraftDerivation.snippetLimit) + "bcd"
        let snippet = GlobalDraftDerivation.snippet(message: text, attachmentCount: 0)
        XCTAssertEqual(snippet.count, GlobalDraftDerivation.snippetLimit + 1)
        XCTAssertTrue(snippet.hasSuffix("…"))
        // Exactly at the limit there is nothing to cut, so no ellipsis.
        let exact = String(repeating: "a", count: GlobalDraftDerivation.snippetLimit)
        XCTAssertEqual(GlobalDraftDerivation.snippet(message: exact, attachmentCount: 0), exact)
    }

    // MARK: - Age copy (pure)

    func testTheEditedCopyCountsTheWayTheListReadsIt() {
        XCTAssertEqual(GlobalDraftDerivation.editedCopy(updateAt: 0, now: now), "Saved earlier")
        XCTAssertEqual(GlobalDraftDerivation.editedCopy(updateAt: ms(-5), now: now), "Edited just now")
        XCTAssertEqual(GlobalDraftDerivation.editedCopy(updateAt: ms(-90), now: now), "Edited 1 min ago")
        XCTAssertEqual(GlobalDraftDerivation.editedCopy(updateAt: ms(-300), now: now), "Edited 5 min ago")
        XCTAssertEqual(GlobalDraftDerivation.editedCopy(updateAt: ms(-3600), now: now), "Edited 1 h ago")
        XCTAssertEqual(GlobalDraftDerivation.editedCopy(updateAt: ms(-7200), now: now), "Edited 2 h ago")
        XCTAssertEqual(GlobalDraftDerivation.editedCopy(updateAt: ms(-86_400), now: now), "Edited 1 d ago")
        XCTAssertEqual(GlobalDraftDerivation.editedCopy(updateAt: ms(-3 * 86_400), now: now), "Edited 3 d ago")
    }

    func testAnAgeOfAWeekOrMoreIsAnAbsoluteDate() {
        let old = now.addingTimeInterval(-30 * 86_400)
        let copy = GlobalDraftDerivation.editedCopy(
            updateAt: Int64(old.timeIntervalSince1970 * 1000), now: now)
        XCTAssertTrue(copy.hasPrefix("Edited "), copy)
        XCTAssertEqual(copy, "Edited " + GlobalDraftDerivation.absoluteDate(old))
    }

    /// A timestamp in the future (a clock that moved, a server-corrected row) must read as "just
    /// now", never as a negative age.
    func testAFutureTimestampReadsAsJustNow() {
        XCTAssertEqual(GlobalDraftDerivation.editedCopy(updateAt: ms(600), now: now), "Edited just now")
    }

    // MARK: - Rows (pure)

    func testRowsAreNewestFirstAndCarryTheChannelsLabel() {
        let labels = ["c1": label("c1", "Town Square", name: "town-square"),
                      "c2": label("c2", "Off Topic", name: "off-topic")]
        let rows = GlobalDraftDerivation.rows(
            drafts: [draft("c1", message: "older", at: 10),
                     draft("c2", message: "newer", at: 20)],
            teamID: "t1", labels: labels, now: now)
        XCTAssertEqual(rows.map { $0.channelID }, ["c2", "c1"])
        XCTAssertEqual(rows[0].title, "#Off Topic")
        XCTAssertEqual(rows[0].snippet, "newer")
        XCTAssertEqual(rows[0].availability, .listed)
    }

    func testADirectMessageRowIsTitledWithThePeopleNotTheChannelName() {
        let labels = ["d1": label("d1", "Ada Lovelace", kind: .directMessage, name: "u1__u2")]
        let rows = GlobalDraftDerivation.rows(drafts: [draft("d1", message: "hi")],
                                              teamID: "t1", labels: labels, now: now)
        XCTAssertEqual(rows.first?.title, "Ada Lovelace")
        XCTAssertEqual(rows.first?.kindCopy, "Direct message draft")
    }

    func testAThreadDraftIsMarkedAndPointsAtItsRoot() {
        let labels = ["c1": label("c1", "Town Square")]
        let rows = GlobalDraftDerivation.rows(drafts: [draft("c1", root: "root-1", message: "reply")],
                                              teamID: "t1", labels: labels, now: now)
        let row = try! XCTUnwrap(rows.first)
        XCTAssertTrue(row.isThreadDraft)
        XCTAssertEqual(row.kindCopy, "Thread draft")
        let request = row.request(serverID: UUID())
        XCTAssertEqual(request.postID, "root-1")
        XCTAssertEqual(request.channelID, "c1")
        XCTAssertEqual(request.teamID, "t1")
    }

    /// The card's decision: a draft in a channel the reader has left is **still listed** and
    /// explicitly marked, not hidden (hiding it would make it unreachable again — the defect this
    /// card closes).
    func testADraftForAChannelMissingFromTheTeamsListIsStillListedAndMarked() {
        let rows = GlobalDraftDerivation.rows(drafts: [draft("gone-1", message: "orphan")],
                                              teamID: "t1", labels: [:], now: now)
        let row = try! XCTUnwrap(rows.first)
        XCTAssertEqual(row.availability, .notListed)
        XCTAssertEqual(row.title, "Channel not in this team's list")
        XCTAssertEqual(row.channelLabel, nil)
        XCTAssertEqual(row.snippet, "orphan", "the words are still there, which is the point")
        XCTAssertEqual(row.request(serverID: UUID()).channelID, "gone-1")
    }

    /// Team scoping: a draft that knows its team appears only on that team.
    func testADraftBelongingToAnotherTeamIsNotListedHere() {
        let rows = GlobalDraftDerivation.rows(
            drafts: [draft("c1", message: "mine", team: "t1"),
                     draft("c2", message: "other team", team: "t2")],
            teamID: "t1", labels: ["c1": label("c1", "One"), "c2": label("c2", "Two")], now: now)
        XCTAssertEqual(rows.map { $0.channelID }, ["c1"])
    }

    /// A row written before T51 has no `team_id`. Hiding it would make an existing draft unreachable
    /// on every team, so it is listed (and its channel label still comes from the team on screen).
    func testADraftWithNoTeamIsListedOnEveryTeam() {
        let legacy = draft("c1", message: "old row", at: 5, team: nil)
        let onOne = GlobalDraftDerivation.rows(drafts: [legacy], teamID: "t1",
                                               labels: ["c1": label("c1", "One")], now: now)
        let onTwo = GlobalDraftDerivation.rows(drafts: [legacy], teamID: "t2",
                                               labels: ["c1": label("c1", "One")], now: now)
        XCTAssertEqual(onOne.count, 1)
        XCTAssertEqual(onTwo.count, 1)
        // …and the row adopts the team on screen, so opening it routes inside that team.
        XCTAssertEqual(onOne.first?.teamID, "t1")
    }

    func testAnEmptyRowIsNeverDrawn() {
        let rows = GlobalDraftDerivation.rows(drafts: [draft("c1", message: "")],
                                              teamID: "t1", labels: ["c1": label("c1", "One")], now: now)
        XCTAssertTrue(rows.isEmpty)
    }

    func testTheRowIdDistinguishesTheChannelDraftFromItsThreadDraft() {
        let channel = draft("c1", message: "a")
        let thread = draft("c1", root: "r1", message: "b")
        XCTAssertNotEqual(GlobalDraftRow(channelID: channel.channelID, rootID: channel.rootID,
                                         message: channel.message, attachmentCount: 0,
                                         updateAt: 1, availability: .listed, channelLabel: nil,
                                         teamID: "t1").id,
                          GlobalDraftRow(channelID: thread.channelID, rootID: thread.rootID,
                                         message: thread.message, attachmentCount: 0,
                                         updateAt: 1, availability: .listed, channelLabel: nil,
                                         teamID: "t1").id)
    }

    // MARK: - The view model: read, delete

    func testLoadReadsEveryDraftForThisTeamOutOfTheStore() async {
        let store = InMemoryComposerDraftStore()
        await store.save(draft("c1", message: "one", at: 10))
        await store.save(draft("c2", message: "two", at: 20, team: "t2"))
        await store.save(draft("c3", root: "r3", message: "thread", at: 30))
        let model = GlobalDraftsViewModel(teamID: "t1", drafts: store,
                                          labels: ["c1": label("c1", "One"),
                                                   "c3": label("c3", "Three")],
                                          now: { self.now })
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.rows.map { $0.channelID }, ["c3", "c1"])
        XCTAssertEqual(model.loadCount, 1)
    }

    func testDeleteRemovesTheRowFromTheStoreBeforeItLeavesTheList() async {
        let store = InMemoryComposerDraftStore()
        await store.save(draft("c1", message: "delete me"))
        let model = GlobalDraftsViewModel(teamID: "t1", drafts: store,
                                          labels: ["c1": label("c1", "One")], now: { self.now })
        await model.load()
        let row = try! XCTUnwrap(model.rows.first)
        await model.delete(row)
        XCTAssertTrue(model.rows.isEmpty, "the list must not keep a row the store dropped")
        XCTAssertNil(model.actionError)
        let stored = await store.allDrafts(limit: 10)
        XCTAssertTrue(stored.isEmpty, "the delete is a store delete, not a UI removal")
    }

    func testAVetoedDeleteKeepsTheRowAndSaysSo() async {
        let store = VetoingDraftStore(draft("c1", message: "stubborn"))
        let model = GlobalDraftsViewModel(teamID: "t1", drafts: store,
                                          labels: ["c1": label("c1", "One")], now: { self.now })
        await model.load()
        let row = try! XCTUnwrap(model.rows.first)
        await model.delete(row)
        XCTAssertEqual(model.rows.count, 1, "a row the store did not delete must stay visible")
        XCTAssertEqual(model.actionError, "That draft could not be deleted. Try again.")
    }

    func testTheWarmComposerIsAskedToDiscardTheDeletedRow() async {
        let store = InMemoryComposerDraftStore()
        await store.save(draft("c1", message: "x"))
        let model = GlobalDraftsViewModel(teamID: "t1", drafts: store,
                                          labels: ["c1": label("c1", "One")], now: { self.now })
        await model.load()
        var discarded: [String] = []
        await model.delete(model.rows[0], onDiscard: { discarded.append($0.id) })
        XCTAssertEqual(discarded, ["c1"])
    }

    // MARK: - The row ↔ storage mapping (no schema change)

    func testTheTeamRidesInTheRowsMetadataColumn() {
        let row = ComposerDraftMapping.row(draft("c1", message: "x", team: "team-abc"))
        XCTAssertEqual(row.metadata, .object(["team_id": .string("team-abc")]))
        // No new column: the rest of the row is exactly what T29 defined.
        XCTAssertEqual(row.channelId, "c1")
        XCTAssertEqual(row.message, "x")
        XCTAssertEqual(row.type, "")
    }

    func testADraftWithNoTeamWritesNoMetadataAndReadsBackAsUnknown() {
        let row = ComposerDraftMapping.row(draft("c1", message: "x", team: nil))
        XCTAssertNil(row.metadata)
        XCTAssertNil(ComposerDraftMapping.draft(row).teamID)
    }

    func testMalformedMetadataIsTeamUnknownRatherThanALostDraft() {
        var row = ComposerDraftMapping.row(draft("c1", message: "keep me", team: "t1"))
        row.metadata = .string("not an object")
        let restored = ComposerDraftMapping.draft(row)
        XCTAssertEqual(restored.message, "keep me")
        XCTAssertNil(restored.teamID)

        row.metadata = .object(["team_id": .number(3)])
        XCTAssertNil(ComposerDraftMapping.draft(row).teamID)
    }

    // MARK: - Through GRDB: it survives a relaunch and stays in one server's file

    private var harness: StoreHarness!

    override func tearDownWithError() throws {
        harness?.cleanup()
        harness = nil
    }

    func testTheTeamSurvivesARelaunchInTheSQLiteRow() async throws {
        harness = try StoreHarness()
        let store = RepositoryComposerDraftStore(repository: harness.drafts)
        await store.save(draft("c1", message: "survive", team: "team-abc"))

        let reopened = try harness.reopen()
        defer { reopened.close() }
        let afterRelaunch = RepositoryComposerDraftStore(repository: SQLiteDraftRepository(store: reopened))
        let restored = await afterRelaunch.load(channelID: "c1", rootID: "")
        XCTAssertEqual(restored?.message, "survive")
        XCTAssertEqual(restored?.teamID, "team-abc", "the metadata column is persisted, not just held in memory")
    }

    func testTwoServersNeverSeeEachOthersDrafts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t51-drafts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let one = ServerConfig(name: "One", url: URL(string: "https://one.example.com")!)
        let two = ServerConfig(name: "Two", url: URL(string: "https://two.example.com")!)
        let provider = ComposerDraftStoreProvider(directory: root)
        await provider.store(for: one).save(draft("same-channel-id", message: "server one"))
        await provider.store(for: two).save(draft("same-channel-id", message: "server two"))

        let oneRows = await provider.store(for: one).allDrafts(limit: 10)
        let twoRows = await provider.store(for: two).allDrafts(limit: 10)
        XCTAssertEqual(oneRows.map { $0.message }, ["server one"])
        XCTAssertEqual(twoRows.map { $0.message }, ["server two"])
        XCTAssertNotEqual(ComposerDraftStoreProvider.path(for: one, in: root),
                          ComposerDraftStoreProvider.path(for: two, in: root))
    }

    // MARK: - The composer side of the contract

    func testTheComposerStoresItsTeamsIDWithTheDraft() async {
        let store = InMemoryComposerDraftStore()
        let composer = ComposerViewModel(channelID: "c1", service: RefusingComposerService(),
                                         drafts: store, teamID: "team-abc")
        composer.textChanged("half a thought", caret: 14)
        await waitFor("the draft write") { await store.allDrafts(limit: 10).isEmpty == false }
        let stored = await store.allDrafts(limit: 10)
        XCTAssertEqual(stored.first?.teamID, "team-abc")
    }

    /// Deleting from the list while the channel's composer is warm must not leave the words in
    /// memory, or the next keystroke would write the row back and undo the delete.
    func testDiscardingTheRowAlsoEmptiesTheWarmComposer() async {
        let store = InMemoryComposerDraftStore()
        let composer = ComposerViewModel(channelID: "c1", service: RefusingComposerService(),
                                         drafts: store, teamID: "team-abc")
        composer.textChanged("delete me", caret: 9)
        await waitFor("the draft write") { await store.allDrafts(limit: 10).isEmpty == false }

        await store.delete(channelID: "c1", rootID: "")
        composer.discardStoredDraft()
        XCTAssertEqual(composer.text, "")
        XCTAssertTrue(composer.attachments.isEmpty)

        // A keystroke afterwards starts a genuinely new draft, not a resurrection of the old text.
        composer.textChanged("n", caret: 1)
        await waitFor("the new draft write") { await store.allDrafts(limit: 10).isEmpty == false }
        let stored = await store.allDrafts(limit: 10)
        XCTAssertEqual(stored.first?.message, "n")
    }

    func testDiscardingAnEditComposerLeavesItAlone() async {
        let store = InMemoryComposerDraftStore()
        let composer = ComposerViewModel(channelID: "c1", service: RefusingComposerService(),
                                         drafts: store)
        await composer.beginEditing(MMPost(id: "p1", channelId: "c1", message: "the post"))
        // An edit owns no draft row, so a discard (for the channel's row) must not clear the edit box.
        composer.discardStoredDraft()
        XCTAssertEqual(composer.text, "the post")
    }

    // MARK: - Helpers

    private func waitFor(_ what: String, timeout: TimeInterval = 5,
                         _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(what)")
    }
}

// MARK: - Fakes

/// A store whose delete is silently ignored — the one state the list must not paper over.
@MainActor
private final class VetoingDraftStore: ComposerDraftStoring {
    private var rows: [ComposerDraft]
    init(_ rows: ComposerDraft...) { self.rows = rows }

    func load(channelID: String, rootID: String) async -> ComposerDraft? {
        rows.first { $0.channelID == channelID && $0.rootID == rootID }
    }
    func save(_ draft: ComposerDraft) async { rows.append(draft) }
    func delete(channelID: String, rootID: String) async { /* refused */ }
    func allDrafts(limit: Int) async -> [ComposerDraft] {
        Array(rows.sorted { $0.updateAt > $1.updateAt }.prefix(limit))
    }
    func clear() async { rows = [] }
}

/// A composer service that never answers: the tests here are about the draft row, not the wire.
@MainActor
private final class RefusingComposerService: ComposerServing {
    func createPost(_ body: ComposerPostBody) async throws -> MMPost { throw MMError.offline }
    func patchPost(id: String, message: String, fileIDs: [String]) async throws -> MMPost { throw MMError.offline }
    func deletePost(id: String) async throws { throw MMError.offline }
    func upload(_ upload: ComposerUpload, channelID: String,
                onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> MMFileInfo {
        throw MMError.offline
    }
    func users(term: String, channelID: String, teamID: String?, limit: Int) async throws -> [MMUser] { [] }
    func channels(term: String, teamID: String, limit: Int) async throws -> [MMChannel] { [] }
    func channelMembers(channelID: String) async throws -> ComposerMembership.MemberList { .unknown }
    func me() async throws -> MMUser { MMUser(id: "u1", username: "me") }
    func executeCommand(_ command: String, channelID: String, teamID: String?,
                        rootID: String?) async throws -> ComposerCommandResponse {
        throw MMError.offline
    }
}
