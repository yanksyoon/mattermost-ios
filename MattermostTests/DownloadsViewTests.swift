import XCTest
@testable import Mattermost

/// Tests for the `DownloadsView` surface: the row formatting helpers (ports of desktop
/// `renderer/utils.ts` `getFileSizeOrBytesProgress`/`getDownloadingFileStatus` + the
/// `pretty-bytes`-style formatter) and the `DownloadHistory` retention-cap wiring that the
/// Settings Stepper drives.
@MainActor
final class DownloadFormattingTests: XCTestCase {

    // MARK: prettyBytes (desktop pretty-bytes behavior: SI units, 1000-based)

    func testPrettyBytesZero() {
        XCTAssertEqual(DownloadFormatting.prettyBytes(0), "0 B")
    }

    func testPrettyBytesBytes() {
        XCTAssertEqual(DownloadFormatting.prettyBytes(1), "1 B")
        XCTAssertEqual(DownloadFormatting.prettyBytes(999), "999 B")
    }

    func testPrettyBytesKiloAndAbove() {
        XCTAssertEqual(DownloadFormatting.prettyBytes(1000), "1 kB")
        XCTAssertEqual(DownloadFormatting.prettyBytes(1024), "1.02 kB")
        XCTAssertEqual(DownloadFormatting.prettyBytes(1_000_000), "1 MB")
        XCTAssertEqual(DownloadFormatting.prettyBytes(1_500_000), "1.5 MB")
        XCTAssertEqual(DownloadFormatting.prettyBytes(1_900_000), "1.9 MB")
    }

    func testPrettyBytesNegative() {
        // Callers never pass negatives (journal clamps receivedBytes >= 0); formatting is
        // still total — mirror pretty-bytes' negative handling.
        XCTAssertEqual(DownloadFormatting.prettyBytes(-5), "-5 B")
    }

    // MARK: fileSizeOrBytesProgress (desktop getFileSizeOrBytesProgress)

    func testSizeForTerminalStateIsTotal() {
        var record = DownloadRecord(filename: "a.pdf", state: .done)
        record.totalBytes = 1_500_000
        XCTAssertEqual(DownloadFormatting.fileSizeOrBytesProgress(record), "1.5 MB")
    }

    func testSizeWhileDownloadingShowsReceivedOfTotal() {
        var record = DownloadRecord(filename: "a.pdf", state: .downloading)
        record.receivedBytes = 500_000
        record.totalBytes = 1_500_000
        XCTAssertEqual(DownloadFormatting.fileSizeOrBytesProgress(record), "500 kB of 1.5 MB")
    }

    func testSizeWhileDownloadingWithoutKnownTotal() {
        var record = DownloadRecord(filename: "a.pdf", state: .downloading)
        record.receivedBytes = 500_000
        record.totalBytes = 0
        XCTAssertEqual(DownloadFormatting.fileSizeOrBytesProgress(record), "0 B")
    }

    // MARK: fileStatus (desktop getDownloadingFileStatus)

    func testFileStatusMapsDoneToDownloaded() {
        XCTAssertEqual(DownloadFormatting.fileStatus(DownloadRecord(filename: "a", state: .done)), "Downloaded")
    }

    func testFileStatusMapsCancelledLikeDesktopDefault() {
        XCTAssertEqual(DownloadFormatting.fileStatus(DownloadRecord(filename: "a", state: .cancelled)), "Cancelled")
        XCTAssertEqual(DownloadFormatting.fileStatus(DownloadRecord(filename: "a", state: .error)), "Cancelled")
        XCTAssertEqual(DownloadFormatting.fileStatus(DownloadRecord(filename: "a", state: .waitToRetry)), "Cancelled")
    }

    func testFileStatusDownloading() {
        XCTAssertEqual(DownloadFormatting.fileStatus(DownloadRecord(filename: "a", state: .downloading)), "Progressing")
    }

    // MARK: fileSizeAndStatus combined

    func testSizeAndStatusCombinedForDone() {
        var record = DownloadRecord(filename: "report.pdf", state: .done)
        record.totalBytes = 1_500_000
        XCTAssertEqual(DownloadFormatting.fileSizeAndStatus(record), "1.5 MB • Downloaded")
    }

    // MARK: progress

    func testProgressFraction() {
        var record = DownloadRecord(filename: "a", state: .downloading)
        record.receivedBytes = 25
        record.totalBytes = 100
        XCTAssertEqual(DownloadFormatting.progress(record), 0.25, accuracy: 0.0001)
    }

    func testProgressUnknownTotalIsZero() {
        var record = DownloadRecord(filename: "a", state: .downloading)
        record.receivedBytes = 25
        record.totalBytes = 0
        XCTAssertEqual(DownloadFormatting.progress(record), 0)
    }

    func testProgressClamped() {
        var record = DownloadRecord(filename: "a", state: .downloading)
        record.receivedBytes = 200
        record.totalBytes = 100
        XCTAssertEqual(DownloadFormatting.progress(record), 1)
    }

    // MARK: iconName (desktop Thumbnail/getIconClassName)

    func testIconByExtension() {
        XCTAssertEqual(DownloadFormatting.iconName(for: "doc.pdf"), "doc.richtext")
        XCTAssertEqual(DownloadFormatting.iconName(for: "photo.JPG"), "photo")
        XCTAssertEqual(DownloadFormatting.iconName(for: "clip.mov"), "film")
        XCTAssertEqual(DownloadFormatting.iconName(for: "song.mp3"), "music.note")
        XCTAssertEqual(DownloadFormatting.iconName(for: "bundle.zip"), "archivebox")
    }

    func testIconFallsBackToGenericDoc() {
        XCTAssertEqual(DownloadFormatting.iconName(for: "mystery.xyzzy"), "doc")
        XCTAssertEqual(DownloadFormatting.iconName(for: "no-extension"), "doc")
    }
}

/// Tests for the retention-cap wiring between the Settings Stepper (`AppSettings.
/// downloadHistoryLimit`) and the live journal (`DownloadHistory.setMaxRecords`).
@MainActor
final class DownloadHistoryCapTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "DownloadHistoryCapTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeHistory() -> DownloadHistory {
        DownloadHistory(preferences: AppPreferences(defaults: defaults))
    }

    private func record(index: Int, state: DownloadState = .done) -> DownloadRecord {
        DownloadRecord(filename: "file-\(index).txt",
                       source: "https://s.example/file-\(index).txt",
                       state: state)
    }

    func testNewHistoryDefaultsToSettingsCap() {
        XCTAssertEqual(makeHistory().maxRecords, DownloadHistory.maxRecords)
    }

    func testSetMaxRecordsTrimsOldest() {
        let history = makeHistory()
        for i in 0..<10 { history.add(record(index: i)) }

        history.setMaxRecords(3)

        XCTAssertEqual(history.records.count, 3)
        // Newest first: indexes 9, 8, 7 survive; 6..0 dropped.
        XCTAssertEqual(history.records.map { $0.filename }, ["file-9.txt", "file-8.txt", "file-7.txt"])
    }

    func testSetMaxRecordsPersistsAcrossRelaunch() {
        let history = makeHistory()
        history.setMaxRecords(7)
        XCTAssertEqual(makeHistory().maxRecords, 7, "a fresh journal over the same defaults reads the new cap")
    }

    func testSetMaxRecordsClampsToRange() {
        let history = makeHistory()
        history.setMaxRecords(0)
        XCTAssertEqual(history.maxRecords, AppSettings.downloadHistoryLimitRange.lowerBound)
        history.setMaxRecords(10_000)
        XCTAssertEqual(history.maxRecords, AppSettings.downloadHistoryLimitRange.upperBound)
    }

    func testSetMaxRecordsSameValueIsNoOp() {
        let history = makeHistory()
        for i in 0..<4 { history.add(record(index: i)) }
        history.setMaxRecords(history.maxRecords)
        XCTAssertEqual(history.records.count, 4)
    }

    func testGrowthOfCapDoesNotDrop() {
        let history = makeHistory()
        history.setMaxRecords(2)
        for i in 0..<2 { history.add(record(index: i)) }
        history.setMaxRecords(5)
        XCTAssertEqual(history.records.count, 2, "growing the cap never loses rows")
    }
}
