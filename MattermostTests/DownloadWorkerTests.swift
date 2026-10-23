import XCTest
@testable import Mattermost

/// Unit tests for the download subsystem (T7): the `DownloadRecord` Codable model, the
/// `DownloadHistory` journal + its persistence/dedup/trim, and `DownloadWorker`'s pure
/// filename/destination/export-decision helpers.
///
/// Live transfers are NOT exercised here — a `URLSessionDownloadTask` needs a reachable HTTP
/// server and a `WKDownload` needs an interactive webview; both are simulator/runtime
/// concerns. What is unit-tested is every piece of logic the shell owns and that tests can
/// run deterministically: JSON round-trip, state transitions, journal CRUD/trim/dedup, safe
/// filename derivation, destination resolution, and the share/export decision.
final class DownloadRecordTests: XCTestCase {

    func testDefaultsToDownloading() {
        let record = DownloadRecord()
        XCTAssertEqual(record.state, .downloading)
        XCTAssertEqual(record.filename, "")
        XCTAssertNil(record.finishedAt)
        XCTAssertNil(record.targetURL)
    }

    func testCodableRoundTripAllFieldsSet() throws {
        let t = Date()
        let original = DownloadRecord(
            filename: "report.pdf",
            source: "https://community.mattermost.com/api/v4/files/abc",
            destination: URL.downloadsDirectory.appendingPathComponent("report.pdf").absoluteString,
            state: .done,
            totalBytes: 2048,
            receivedBytes: 2048,
            startedAt: t,
            finishedAt: t)
        guard let encoded = try? JSONEncoder().encode(original) else { return XCTFail("encode failed") }
        guard let decoded = try? JSONDecoder().decode(DownloadRecord.self, from: encoded) else {
            return XCTFail("decode failed")
        }
        XCTAssertEqual(decoded.state, .done)
        XCTAssertEqual(decoded.filename, "report.pdf")
        XCTAssertEqual(decoded.source, original.source)
        XCTAssertEqual(decoded.receivedBytes, decoded.totalBytes)
        XCTAssertEqual(decoded.startedAt, decoded.finishedAt)
        XCTAssertEqual(decoded.targetURL?.absoluteString, original.destination)
    }

    func testCodableRoundTripNullOptionals() throws {
        let original = DownloadRecord(filename: "clip.mp4", state: .downloading, receivedBytes: 512)
        guard let encoded = try? JSONEncoder().encode(original) else { return XCTFail("encode failed") }
        guard let decoded = try? JSONDecoder().decode(DownloadRecord.self, from: encoded) else {
            return XCTFail("decode failed")
        }
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.finishedAt)
        XCTAssertNil(decoded.targetURL)
    }

    func testTargetURLIsNilUntilLanded() {
        XCTAssertNil(DownloadRecord(filename: "x.bin").targetURL)
    }
}

@MainActor
final class DownloadHistoryTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        let suiteName = "DownloadHistoryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeHistory() -> DownloadHistory {
        DownloadHistory(preferences: AppPreferences(defaults: defaults))
    }

    private func record(_ name: String, state: DownloadState = .done) -> DownloadRecord {
        DownloadRecord(filename: name, source: "https://s.example/\(name)", state: state)
    }

    func testAddIsNewestFirstAndFindable() {
        let history = makeHistory()
        history.add(record("a.txt"))
        history.add(record("b.txt"))
        XCTAssertEqual(history.records.count, 2)
        XCTAssertEqual(history.records[0].filename, "b.txt")
        XCTAssertNotNil(history.find(id: history.records[0].id))
    }

    func testAddDeduplicatesSameSource() {
        let history = makeHistory()
        history.add(record("a.txt"))
        let replacement = DownloadRecord(filename: "a.txt", source: "https://s.example/a.txt")
        history.add(replacement)
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records[0].id, replacement.id)
    }

    func testAddKeepsDistinctSources() {
        let history = makeHistory()
        history.add(DownloadRecord(filename: "a.txt", source: "https://s.example/a.txt"))
        history.add(DownloadRecord(filename: "a.txt", source: "https://t.example/a.txt"))
        XCTAssertEqual(history.records.count, 2)
    }

    func testUpdatePersistsStateTransition() {
        let history = makeHistory()
        let r = record("big.bin", state: .downloading)
        history.add(r)
        let finished = DownloadRecord(
            id: r.id,
            filename: r.filename,
            source: r.source,
            state: .done,
            totalBytes: 100,
            receivedBytes: 100,
            startedAt: r.startedAt)
        history.update(finished)
        let stored = history.find(id: r.id)!
        XCTAssertEqual(stored.state, .done)
        XCTAssertEqual(stored.receivedBytes, 100)
        XCTAssertEqual(stored.totalBytes, 100)
    }

    func testUpdateUnknownAdds() {
        let history = makeHistory()
        history.update(DownloadRecord(filename: "new.txt", source: "https://s.example/new.txt"))
        XCTAssertEqual(history.records.count, 1)
    }

    func testRemove() {
        let history = makeHistory()
        let a = record("a.txt")
        let b = record("b.txt")
        history.add(a)
        history.add(b)
        history.remove(id: a.id)
        XCTAssertNil(history.find(id: a.id))
        XCTAssertNotNil(history.find(id: b.id))
    }

    func testClearFinishedKeepsOnlyInFlight() {
        let history = makeHistory()
        history.add(record("done.txt", state: .done))
        history.add(DownloadRecord(filename: "inflight.txt", source: "https://s.example/inflight.txt", state: .downloading))
        history.clearFinished()
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records[0].filename, "inflight.txt")
    }

    func testHistorySurvivesFreshInstance_simulatingRelaunch() {
        let history = makeHistory()
        history.add(record("kept.txt", state: .done))
        // A brand-new store over the SAME defaults must read the journal back from disk.
        let reloaded = makeHistory()
        XCTAssertEqual(reloaded.records.count, 1)
        XCTAssertEqual(reloaded.records[0].filename, "kept.txt")
    }

    func testTrimsToMaxRecordsNewestFirst() {
        let history = makeHistory()
        for i in 0 ..< 60 {
            history.add(record("file-\(i).txt"))
        }
        XCTAssertEqual(history.records.count, DownloadHistory.maxRecords)
        // The newest is still at the front; the 10 oldest were dropped.
        XCTAssertEqual(history.records[0].filename, "file-59.txt")
        XCTAssertEqual(history.records.last!.filename, "file-10.txt")
    }
}

@MainActor
final class DownloadWorkerTests: XCTestCase {

    private var workerDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        let suiteName = "DownloadWorkerTests-\(UUID().uuidString)"
        workerDefaults = UserDefaults(suiteName: suiteName)!
        workerDefaults.removePersistentDomain(forName: suiteName)
    }

    private func makeWorker() -> DownloadWorker {
        DownloadWorker(history: DownloadHistory(preferences: AppPreferences(defaults: workerDefaults)))
    }

    // MARK: sanitizedFilename

    func testSanitizedKeepsBasenameAndTrims() {
        XCTAssertEqual(DownloadWorker.sanitizedFilename("  report.pdf  "), "report.pdf")
        XCTAssertEqual(DownloadWorker.sanitizedFilename("/etc/passwd"), "passwd")
        XCTAssertEqual(DownloadWorker.sanitizedFilename("team/files/README.md"), "README.md")
        XCTAssertEqual(DownloadWorker.sanitizedFilename("a\\b\\c.txt"), "c.txt")
    }

    func testSanitizedCollapsesTraversal() {
        // A "../../etc/shadow" style injection must never escape the Downloads dir name.
        XCTAssertEqual(DownloadWorker.sanitizedFilename("../../etc/shadow"), "shadow")
    }

    func testSanitizedFallsBackWhenEmpty() {
        XCTAssertEqual(DownloadWorker.sanitizedFilename("   "), "download")
        XCTAssertEqual(DownloadWorker.sanitizedFilename("////"), "download")
    }

    // MARK: uniqueFilename

    func testUniqueKeepsBaseWhenFree() {
        XCTAssertEqual(DownloadWorker.uniqueFilename("report.pdf", existing: []), "report.pdf")
        XCTAssertEqual(DownloadWorker.uniqueFilename("report.pdf", existing: ["a.txt"]), "report.pdf")
    }

    func testUniqueSuffixesOnCollision() {
        XCTAssertEqual(DownloadWorker.uniqueFilename("report.pdf", existing: ["report.pdf"]), "report (2).pdf")
        XCTAssertEqual(
            DownloadWorker.uniqueFilename("report.pdf", existing: ["report.pdf", "report (2).pdf"]),
            "report (3).pdf")
    }

    func testUniqueNoExtensionCase() {
        XCTAssertEqual(DownloadWorker.uniqueFilename("notes", existing: ["notes"]), "notes (2)")
    }

    func testUniqueKeepsLastExtensionOnly() {
        XCTAssertEqual(DownloadWorker.uniqueFilename("report.tar.gz", existing: ["report.tar.gz"]),
                       "report.tar (2).gz")
    }

    // MARK: resolveDestination

    func testResolveDestinationBuildsDownloadsFileURL() {
        let dir = URL.downloadsDirectory
        let wanted = dir.appendingPathComponent("spec.pdf")
        XCTAssertEqual(
            DownloadWorker.resolveDestination(for: "spec.pdf", in: dir, existingNames: []),
            wanted)
    }

    func testResolveDestinationDeduplicatesInDirectory() {
        let dir = URL.downloadsDirectory
        let dest = DownloadWorker.resolveDestination(for: "spec.pdf", in: dir, existingNames: ["spec.pdf"])
        XCTAssertEqual(dest.lastPathComponent, "spec (2).pdf")
    }

    // MARK: exportPicker (Share / move into Files)

    func testExportPickerNilWhenNothingLanded() {
        let worker = makeWorker()
        XCTAssertNil(worker.exportPicker(for: DownloadRecord(filename: "a.txt", state: .downloading)))
        XCTAssertNil(worker.exportPicker(for: DownloadRecord(filename: "a.txt", state: .error)))
    }

    func testExportPickerBuiltForLandedFileAndMovesByDefault() {
        let worker = makeWorker()
        // The picker is only constructible for a file that actually landed on disk, so stage one.
        let landed = URL.downloadsDirectory.appendingPathComponent("a.txt")
        try? FileManager.default.createDirectory(at: URL.downloadsDirectory,
                                                 withIntermediateDirectories: true)
        try? Data("payload".utf8).write(to: landed)
        defer { try? FileManager.default.removeItem(at: landed) }
        var done = DownloadRecord(filename: "a.txt", state: .done)
        done.destination = landed.absoluteString
        guard let picker = worker.exportPicker(for: done) else { return XCTFail("expected a picker") }
        // A share-to-Files export must MOVE (asCopy == false) the original, per UIKit guidance.
        XCTAssertEqual(picker.directoryURL, URL.downloadsDirectory)
        XCTAssertFalse(picker.allowsMultipleSelection)
    }
}