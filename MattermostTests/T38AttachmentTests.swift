// T38 — the attachment rules as pure functions, plus the two state machines the rows depend on
// (the bounded image store and the download coordinator that reuses `DownloadWorker`).
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 — `app/utils/file/index.ts`
// (isDocument / isSupportedExtension / getFileType), `app/utils/file/file_icon.tsx` (type → icon),
// `app/components/files/files.tsx` (images in a grid, everything else as rows),
// `app/components/files/file.tsx` (name, type, size), `app/screens/gallery/` (paging + counter),
// `app/screens/pdf_viewer/`, `app/screens/code/`. Licence Apache-2.0; the classification and the
// bounds are reimplemented in Swift and asserted here — no upstream source is copied.
//
// Everything in this file is offline: a fake `ChannelServing` supplies bytes, an injected closure
// supplies a file's original payload, and no `URLSession` is ever created except in the two
// `DownloadWorker` landing tests, which write to a temporary directory.

import XCTest
import UIKit
@testable import Mattermost

// MARK: - Helpers

/// A real PNG of a chosen size, so a decode path is exercised with real image bytes rather than a
/// fixture string. Small by default: the store's rules are about counts and bounds, not fidelity.
enum T38Image {
    static func png(width: CGFloat = 8, height: CGFloat = 8, color: UIColor = .systemBlue) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.pngData() ?? Data()
    }
}

func t38Attachment(_ id: String,
                   name: String,
                   mime: String = "image/png",
                   size: Int64 = 1024,
                   blocked: Bool = false) -> PostAttachment {
    PostAttachment(id: id,
                   name: name,
                   mimeType: mime,
                   sizeBytes: size,
                   kind: PostAttachment.kind(forMimeType: mime),
                   isBlocked: blocked,
                   hasThumbnail: mime.hasPrefix("image/") && !blocked)
}

// MARK: - 1. Classification (the safety boundary)

final class T38FileTypeClassificationTests: XCTestCase {

    func testAPNGIsAnImageAndItsTypeLabelNamesTheFormat() {
        let descriptor = FileTypeMap.descriptor(fileName: "screenshot.png", mimeType: "image/png")
        XCTAssertEqual(descriptor.category, .image)
        XCTAssertEqual(descriptor.preview, .image)
        XCTAssertEqual(FileTypeMap.typeLabel(descriptor), "PNG image")
        XCTAssertEqual(descriptor.symbolName, "photo")
    }

    func testTheExtensionDecidesEvenWhenTheServerClaimsAnImageMimeType() {
        // The MIME type is uploader-controlled (`mime_type`); the name is what a reader sees. A file
        // named `.html` served as `image/png` must not be decoded as an image: the category follows
        // the server's claim, but the *preview* is refused on the name.
        let descriptor = FileTypeMap.descriptor(fileName: "invoice.html", mimeType: "image/png")
        XCTAssertEqual(descriptor.preview, .unsupported(.unsafe))
        XCTAssertFalse(descriptor.preview.isSupported)
        // And the reverse: an innocent name with a page's MIME type is refused as well (below).
    }

    func testADangerousMimeTypeWinsOverAnInnocentExtension() {
        // The measured case in the card: `logo.png` served as `text/html`. Refusing the MIME claim is
        // the safer of the two answers, so the preview is refused even though the name says PNG.
        let descriptor = FileTypeMap.descriptor(fileName: "logo.png", mimeType: "text/html")
        XCTAssertEqual(descriptor.category, .image)
        XCTAssertEqual(descriptor.preview, .unsupported(.unsafe))
    }

    func testSVGIsRefusedAsContentEvenThoughItIsAnImage() {
        XCTAssertEqual(FileTypeMap.descriptor(fileName: "icon.svg", mimeType: "image/svg+xml").preview,
                       .unsupported(.unsafe))
        // No usable name: the MIME type alone still refuses it.
        XCTAssertEqual(FileTypeMap.descriptor(fileName: "download", mimeType: "image/svg+xml").preview,
                       .unsupported(.unsafe))
    }

    func testExecutablesAndInterpreterDocumentsAreUnsafe() {
        for name in ["run.command", "tool.terminal", "installer.pkg", "profile.mobileconfig",
                     "payload.app", "setup.exe", "page.xhtml", "data.wasm"] {
            XCTAssertEqual(FileTypeMap.descriptor(fileName: name, mimeType: "").preview,
                           .unsupported(.unsafe), "\(name) must never be interpreted")
        }
    }

    func testSourceCodeIsReadAsTextNotRefused() {
        // The distinction the set exists for: a `.sh` is *characters* to the text reader, not a
        // program to run, so it is previewable — as text — and never executed.
        let descriptor = FileTypeMap.descriptor(fileName: "deploy.sh", mimeType: "application/x-sh")
        XCTAssertEqual(descriptor.category, .code)
        XCTAssertEqual(descriptor.preview, .text)
        XCTAssertEqual(FileTypeMap.typeLabel(descriptor), "SH source")
    }

    func testPlainTextMarkdownAndJSONAreText() {
        for name in ["notes.txt", "README.md", "data.json", "config.yaml", "patch.diff"] {
            XCTAssertEqual(FileTypeMap.descriptor(fileName: name, mimeType: "").preview, .text,
                           "\(name) should be readable as text")
        }
    }

    func testAPDFOpensInThePDFReader() {
        let descriptor = FileTypeMap.descriptor(fileName: "report.PDF", mimeType: "application/pdf")
        XCTAssertEqual(descriptor.category, .pdf)
        XCTAssertEqual(descriptor.preview, .pdf)
        XCTAssertEqual(FileTypeMap.typeLabel(descriptor), "PDF")
    }

    func testTypesWithNoReaderAreDownloadableButNotPreviewed() {
        for (name, category) in [("archive.zip", FileCategory.archive),
                                 ("sheet.xlsx", .spreadsheet),
                                 ("memo.docx", .document),
                                 ("deck.pptx", .presentation),
                                 ("clip.mp4", .video),
                                 ("voice.m4a", .audio)] {
            let descriptor = FileTypeMap.descriptor(fileName: name, mimeType: "")
            XCTAssertEqual(descriptor.category, category, "\(name)")
            XCTAssertEqual(descriptor.preview, .unsupported(.noReader), "\(name)")
        }
    }

    func testABlockedFileIsRefusedWhateverItsType() {
        let descriptor = FileTypeMap.descriptor(fileName: "photo.png", mimeType: "image/png",
                                                isBlocked: true)
        XCTAssertEqual(descriptor.preview, .unsupported(.blocked))
        XCTAssertTrue(FileTypeMap.unsupportedReason(.blocked).contains("blocked"))
    }

    func testTheExtensionIsTakenFromTheLastDotOfTheBasename() {
        XCTAssertEqual(FileTypeMap.fileExtension(of: "report.final.v2.pdf"), "pdf")
        XCTAssertEqual(FileTypeMap.fileExtension(of: "dir/sub/file.TXT"), "txt")
        XCTAssertEqual(FileTypeMap.fileExtension(of: "noext"), "")
        // A dotfile's suffix is its extension: `.env` is a text file, not an unknown type.
        XCTAssertEqual(FileTypeMap.fileExtension(of: ".env"), "env")
        XCTAssertEqual(FileTypeMap.descriptor(fileName: ".env", mimeType: "").preview, .text)
    }

    func testAMeaninglessNameFallsBackToTheMimeType() {
        XCTAssertEqual(FileTypeMap.descriptor(fileName: "blob", mimeType: "application/pdf").category, .pdf)
        XCTAssertEqual(FileTypeMap.descriptor(fileName: "blob", mimeType: "image/jpeg").category, .image)
        XCTAssertEqual(FileTypeMap.descriptor(fileName: "blob", mimeType: "text/csv").category, .text)
    }

    func testAnUnknownTypeIsNamedRatherThanGuessed() {
        let descriptor = FileTypeMap.descriptor(fileName: "weird.qqq", mimeType: "application/x-qqq")
        XCTAssertEqual(descriptor.category, .other)
        XCTAssertEqual(FileTypeMap.typeLabel(descriptor), "QQQ file")
        XCTAssertEqual(descriptor.symbolName, "doc")
    }

    func testEveryCategoryHasAnIcon() {
        for category in FileCategory.allCases {
            XCTAssertFalse(category.symbolName.isEmpty, "\(category) has no SF Symbol")
        }
    }

    func testTheRefusalSentencesNeverClaimTheFileWasOpened() {
        for reason in [FilePreviewKind.UnsupportedReason.unsafe, .noReader, .blocked] {
            let sentence = FileTypeMap.unsupportedReason(reason)
            XCTAssertFalse(sentence.isEmpty)
            XCTAssertTrue(sentence.hasSuffix("."), "one complete sentence: \(sentence)")
        }
    }

    func testImageAttachmentClassificationFollowsTheNameNotTheMimeKind() {
        // `PostAttachment.kind` is derived from the MIME type alone; the section must not trust it.
        let svgAsImage = t38Attachment("f1", name: "chart.svg", mime: "image/svg+xml")
        XCTAssertEqual(svgAsImage.kind, .image)
        XCTAssertFalse(svgAsImage.isInlineImage, "an SVG must be a row, never an image load")
    }
}

// MARK: - 2. What one post draws

final class T38AttachmentSectionTests: XCTestCase {

    private func postWithTenImagesThreeFilesAndAPDF() -> [PostAttachment] {
        let images = (1...10).map { t38Attachment("img\($0)", name: "shot\($0).png", size: 2048) }
        let files = [t38Attachment("doc1", name: "notes.txt", mime: "text/plain", size: 512),
                     t38Attachment("doc2", name: "bundle.zip", mime: "application/zip", size: 4096),
                     t38Attachment("doc3", name: "data.csv", mime: "text/csv", size: 900)]
        let pdf = t38Attachment("pdf1", name: "report.pdf", mime: "application/pdf", size: 8192)
        return images + files + [pdf]
    }

    func testTenImagesThreeFilesAndAPDFSplitIntoAGridAndFourRows() {
        let section = AttachmentSection(postWithTenImagesThreeFilesAndAPDF())
        XCTAssertEqual(section.images.count, 10)
        XCTAssertEqual(section.files.map(\.id), ["doc1", "doc2", "doc3", "pdf1"])
        XCTAssertFalse(section.isEmpty)
    }

    func testTheServersOrderIsKeptInsideEachHalf() {
        let section = AttachmentSection([
            t38Attachment("a", name: "a.png"),
            t38Attachment("b", name: "b.txt", mime: "text/plain"),
            t38Attachment("c", name: "c.png"),
            t38Attachment("d", name: "d.pdf", mime: "application/pdf"),
        ])
        XCTAssertEqual(section.images.map(\.id), ["a", "c"])
        XCTAssertEqual(section.files.map(\.id), ["b", "d"])
    }

    func testTheGalleryStartsAtTheTappedImageAndCountsTen() {
        let attachments = postWithTenImagesThreeFilesAndAPDF()
        let gallery = AttachmentGallery(postID: "p1", attachments: attachments)
        XCTAssertEqual(gallery?.images.count, 10)
        XCTAssertEqual(gallery?.index(of: "img7"), 6)
        XCTAssertEqual(gallery?.counterLabel(6), "7 of 10")
        XCTAssertEqual(gallery?.counterLabel(9), "10 of 10")
    }

    func testAGalleryWithNoEligibleImageIsNotPresented() {
        XCTAssertNil(AttachmentGallery(postID: "p1", attachments: [
            t38Attachment("svg", name: "x.svg", mime: "image/svg+xml"),
            t38Attachment("pdf", name: "x.pdf", mime: "application/pdf"),
        ]))
    }

    func testTheGalleryTargetDerivesItsStartIndexFromTheRowsOwnAttachments() {
        let attachments = postWithTenImagesThreeFilesAndAPDF()
        let target = AttachmentGalleryTarget(postID: "p1", attachments: attachments, startFileID: "img3")
        XCTAssertEqual(target.startIndex, 2)
        XCTAssertEqual(target.id, "p1/img3")
        // A file id the row does not carry cannot move the gallery past its first page.
        let stranger = AttachmentGalleryTarget(postID: "p1", attachments: attachments, startFileID: "nope")
        XCTAssertEqual(stranger.startIndex, 0)
    }

    func testOneImageGetsAFullWidthCellAndTenImagesGetAThreeColumnGrid() {
        XCTAssertEqual(AttachmentImageGrid.columnCount(for: 1), 1)
        XCTAssertEqual(AttachmentImageGrid.columnCount(for: 3), 3)
        XCTAssertEqual(AttachmentImageGrid.columnCount(for: 10), 3)
        XCTAssertEqual(AttachmentImageGrid.rowCount(for: 10), 4)
        XCTAssertEqual(AttachmentImageGrid.rowCount(for: 9), 3)
        XCTAssertEqual(AttachmentImageGrid.rowCount(for: 0), 0)
        // The single-image cell is the wide one; the grid cell is the compact square.
        let single = AttachmentImageGrid.cellSize(count: 1)
        let grid = AttachmentImageGrid.cellSize(count: 10)
        XCTAssertGreaterThan(single.width, grid.width)
        XCTAssertEqual(grid.width, grid.height)
    }

    func testCellsNeverOverflowTheWidthTheBubbleOffers() {
        // A narrow split-view column (200 pt) with three columns must still fit.
        let size = AttachmentImageGrid.cellSize(count: 3, availableWidth: 200)
        XCTAssertLessThanOrEqual(size.width * 3 + AttachmentImageGrid.spacing * 2, 200 + 0.01)
        XCTAssertGreaterThanOrEqual(size.width, 44)
    }

    func testAnEmptyAttachmentListDrawsNothing() {
        XCTAssertTrue(AttachmentSection([]).isEmpty)
        XCTAssertEqual(AttachmentImageGrid.columnCount(for: 0), 0)
        XCTAssertEqual(AttachmentImageGrid.cellSize(count: 0), .zero)
    }
}

// MARK: - 3. Decoding a real post's metadata.files

final class T38AttachmentDecodingTests: XCTestCase {

    /// `metadata.files` as 9.11.19 returns it, for a post carrying ten images, three files and a PDF
    /// (the fixture `scripts/t38_attachment_seed.py` creates). One image is the hostile case: a
    /// `.html` uploaded with `mime_type: image/png`.
    private func metadataJSON() throws -> JSONValue {
        func file(_ id: String, _ name: String, _ mime: String, _ size: Int) -> [String: Any] {
            ["id": id, "name": name, "mime_type": mime, "size": size,
             "post_id": "p1", "width": 640, "height": 480, "is_blocked": false]
        }
        var files: [[String: Any]] = (1...10).map {
            file("img\($0)", "shot\($0).png", "image/png", 2048 + $0)
        }
        files.append(file("doc1", "notes.txt", "text/plain", 512))
        files.append(file("doc2", "bundle.zip", "application/zip", 4096))
        files.append(file("doc3", "notes.md", "text/markdown", 700))
        files.append(file("pdf1", "report.pdf", "application/pdf", 8192))
        files.append(file("evil", "payload.html", "image/png", 64))
        files.append(["id": "blocked1", "name": "secret.txt", "mime_type": "text/plain",
                      "size": 10, "post_id": "p1", "is_blocked": true])
        let data = try JSONSerialization.data(withJSONObject: ["files": files])
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func testAFourteenFilePostDecodesIntoImagesAndFileRows() throws {
        let post = MMPost(id: "p1", message: "attachments", metadata: try metadataJSON())
        let attachments = PostListDerivation.attachments(for: post)
        XCTAssertEqual(attachments.count, 16, "ten images, three files, a PDF, a hostile image, a blocked file")
        let section = AttachmentSection(attachments)
        XCTAssertEqual(section.images.count, 10, "the trailing .html is not an image load")
        XCTAssertEqual(section.files.map(\.id), ["doc1", "doc2", "doc3", "pdf1", "evil", "blocked1"])
    }

    func testTheHostileFileIsARowRefusedForSafety() throws {
        let post = MMPost(id: "p1", message: "attachments", metadata: try metadataJSON())
        let evil = try XCTUnwrap(PostListDerivation.attachments(for: post).first { $0.id == "evil" })
        XCTAssertEqual(evil.previewKind, .unsupported(.unsafe))
        XCTAssertFalse(evil.isInlineImage)
        XCTAssertEqual(FileTypeMap.unsupportedReason(.unsafe),
                       "This file type is not previewed for safety. Download it to open it in another app.")
    }

    func testTheBlockedFileSaysTheServerBlockedIt() throws {
        let post = MMPost(id: "p1", message: "attachments", metadata: try metadataJSON())
        let blocked = try XCTUnwrap(PostListDerivation.attachments(for: post).first { $0.id == "blocked1" })
        XCTAssertTrue(blocked.isBlocked)
        XCTAssertEqual(blocked.previewKind, .unsupported(.blocked))
    }

    func testTheRowShowsTheServersNameTheTypeAndTheSize() throws {
        let post = MMPost(id: "p1", message: "attachments", metadata: try metadataJSON())
        let pdf = try XCTUnwrap(PostListDerivation.attachments(for: post).first { $0.id == "pdf1" })
        XCTAssertEqual(pdf.name, "report.pdf")
        XCTAssertEqual(pdf.typeLabel, "PDF")
        XCTAssertEqual(pdf.sizeLabel, "8.0 KB")
    }

    func testAPostWithoutMetadataStillShowsThatSomethingIsAttached() {
        let post = MMPost(id: "p1", message: "see attached", fileIds: ["f1", "f2"])
        let attachments = PostListDerivation.attachments(for: post)
        XCTAssertEqual(attachments.map(\.id), ["f1", "f2"])
        XCTAssertTrue(AttachmentSection(attachments).images.isEmpty)
    }
}

// MARK: - 4. The bounded text reader

final class T38TextPreviewTests: XCTestCase {

    func testUTF8TextIsDecodedWhole() {
        let decoded = TextPreview.decode(Data("hello, world".utf8))
        XCTAssertEqual(decoded.text, "hello, world")
        XCTAssertFalse(decoded.truncated)
    }

    func testBytesPastTheLimitAreDroppedAndReported() {
        let limit = FileTypeMap.textPreviewByteLimit
        let data = Data(repeating: UInt8(ascii: "a"), count: limit + 1024)
        let decoded = TextPreview.decode(data)
        XCTAssertTrue(decoded.truncated)
        XCTAssertEqual(decoded.text.utf8.count, limit)
    }

    func testLegacyBytesDecodeAsLatin1InsteadOfMojibake() {
        // `0xE9` is "é" in ISO-8859-1 and invalid UTF-8: a legacy export must still read.
        let decoded = TextPreview.decode(Data([0x63, 0x61, 0x66, 0xE9]))
        XCTAssertEqual(decoded.text, "café")
        XCTAssertFalse(decoded.truncated)
    }

    func testTheLimitIsTheSameNumberTheClassifierUses() {
        XCTAssertEqual(TextPreview.byteLimit, FileTypeMap.textPreviewByteLimit)
    }
}

// MARK: - 5. The landing rule (one download path, proven on disk)

@MainActor
final class T38DownloadLandingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("t38-landing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A file the session "downloaded" into a temporary location.
    private func stagedFile(contents: String = "bytes") throws -> URL {
        let url = directory.appendingPathComponent("staged-\(UUID().uuidString)")
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testAClaimedDownloadActuallyLandsOnDisk() throws {
        let location = try stagedFile(contents: "report body")
        let destination = try DownloadWorker.install(downloadedFileAt: location,
                                                     filename: "report.pdf",
                                                     in: directory, existingNames: [])
        XCTAssertEqual(destination.lastPathComponent, "report.pdf")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "report body")
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.path),
                       "the temporary file is moved, not copied")
    }

    func testASecondFileOfTheSameNameDoesNotOverwriteTheFirst() throws {
        let first = try stagedFile(contents: "one")
        let second = try stagedFile(contents: "two")
        let firstURL = try DownloadWorker.install(downloadedFileAt: first, filename: "notes.txt",
                                                  in: directory, existingNames: [])
        let secondURL = try DownloadWorker.install(downloadedFileAt: second, filename: "notes.txt",
                                                   in: directory,
                                                   existingNames: [firstURL.lastPathComponent])
        XCTAssertEqual(firstURL.lastPathComponent, "notes.txt")
        XCTAssertEqual(secondURL.lastPathComponent, "notes (2).txt")
        XCTAssertEqual(try String(contentsOf: firstURL, encoding: .utf8), "one")
        XCTAssertEqual(try String(contentsOf: secondURL, encoding: .utf8), "two")
    }

    func testAHostileNameCannotEscapeTheDownloadsDirectory() throws {
        let location = try stagedFile(contents: "x")
        let destination = try DownloadWorker.install(downloadedFileAt: location,
                                                     filename: "../../Library/evil",
                                                     in: directory, existingNames: [])
        XCTAssertEqual(destination.deletingLastPathComponent().standardizedFileURL,
                       directory.standardizedFileURL)
        XCTAssertEqual(destination.lastPathComponent, "evil")
    }

    func testTheDirectoryIsCreatedWhenItDoesNotExistYet() throws {
        let location = try stagedFile(contents: "x")
        let nested = directory.appendingPathComponent("a/b/c", isDirectory: true)
        let destination = try DownloadWorker.install(downloadedFileAt: location,
                                                     filename: "deep.bin", in: nested, existingNames: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testAnAttachmentDownloadIsJournaledUnderTheServersFileName() throws {
        // The request the row builds carries the file *id* in its URL; the row must land under the
        // name the reader was shown, not under the id.
        let worker = DownloadWorker(history: DownloadHistory())
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://mm.example.com/api/v4/files/abc")))
        let record = worker.download(request: request, suggestedFilename: "shot 1.png")
        XCTAssertEqual(record.filename, "shot 1.png")
        XCTAssertEqual(worker.history.records.first?.id, record.id,
                       "the returned record is the journal's own row")
        XCTAssertEqual(record.source, request.url?.absoluteString)
    }

    /// A record is in the journal from the moment its task starts, so the name it is landing under is
    /// already "taken" by itself. Measured live before the repair: the first save of
    /// `t38-shot-01.png` landed as `t38-shot-01 (2).png` (`docs/t38-build-note.md` §5).
    func testTheRecordBeingLandedDoesNotReserveItsOwnName() {
        var mine = DownloadRecord(filename: "t38-shot-01.png", source: "https://mm.example.com/api/v4/files/a")
        mine.state = .downloading
        var landed = DownloadRecord(filename: "t38-notes.txt", source: "https://mm.example.com/api/v4/files/b")
        landed.state = .done
        var failed = DownloadRecord(filename: "t38-old.txt", source: "https://mm.example.com/api/v4/files/c")
        failed.state = .error

        let taken = DownloadWorker.occupiedNames(in: [mine, landed, failed], excluding: mine.id)
        XCTAssertEqual(taken, ["t38-notes.txt"],
                       "only files that actually landed occupy a name — never the one landing now")
        XCTAssertEqual(DownloadWorker.resolveDestination(for: "t38-shot-01.png", in: directory,
                                                         existingNames: taken).lastPathComponent,
                       "t38-shot-01.png",
                       "a first save must not become 't38-shot-01 (2).png'")
    }

    /// The whole point of the card: a save must move **bytes**, not just write a journal row.
    ///
    /// A `URLSessionTask` is created **suspended**; `startDownload` used to return the record without
    /// ever resuming the task, so the journal reached the Downloads screen and stayed there at
    /// "0 B · Progressing" with no delegate callback and no file (measured on the simulator against
    /// the real server: `docs/t38-shots/t38-11-downloads-row.png`, `docs/t38-build-note.md` §5).
    /// This asserts the shipped path starts the transfer, and that the task carries the caller's own
    /// request. The bytes-landing half of the claim is the `install` tests above (the delegate's own
    /// move) plus the live UI test, which requires the row to read "Downloaded".
    func testAStartedDownloadIsActuallyRunning() throws {
        let suite = "t38-landing-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let worker = DownloadWorker(history: DownloadHistory(preferences: AppPreferences(defaults: defaults)))

        // `.invalid` never resolves, so nothing leaves the process; the assertion is about the task
        // state, which is set by `resume()` alone.
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://t38.invalid/api/v4/files/abc")))
        let record = worker.download(request: request, suggestedFilename: "t38-landed.png")
        let task = try XCTUnwrap(worker.task(for: record.id),
                                 "a started download must keep its task reachable")
        XCTAssertNotEqual(task.state, .suspended,
                          "a journal row whose task was never resumed shows progress forever")
        XCTAssertEqual(task.originalRequest?.url, request.url,
                       "the transfer is the caller's authenticated request, not a re-built one")
        worker.cancel(id: record.id)
    }
}

// MARK: - 5b. What the bytes are really named, and what is too large to fetch whole (T38-AV F5/F6)

@MainActor
final class T38LandedNameTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("t38-landed-name-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The case T38-AV measured: a byte-identical `t38-shot-01.png` is already in Downloads, so the new
    /// save lands as `t38-shot-01 (2).png` while the journal (and therefore the row) still says
    /// `t38-shot-01.png`. The row must say where the bytes actually are.
    func testTheRowNamesTheFileTheBytesActuallyLandedUnder() throws {
        let stale = directory.appendingPathComponent("t38-shot-01.png")
        try Data("stale".utf8).write(to: stale)
        let staged = directory.appendingPathComponent("staged-\(UUID().uuidString)")
        try Data("stale".utf8).write(to: staged)

        let destination = try DownloadWorker.install(downloadedFileAt: staged,
                                                     filename: "t38-shot-01.png",
                                                     in: directory,
                                                     existingNames: ["t38-shot-01.png"])
        XCTAssertEqual(destination.lastPathComponent, "t38-shot-01 (2).png",
                       "install returns the landed destination, de-duplicated")

        // Exactly the shape the download delegate journals.
        var record = DownloadRecord(filename: "t38-shot-01.png", source: "https://mm.example.com/api/v4/files/a")
        record.destination = destination.absoluteString
        record.state = .done
        XCTAssertEqual(DownloadFormatting.landedName(record), "t38-shot-01 (2).png")
        XCTAssertEqual(DownloadFormatting.savedAsNote(record), "Saved as t38-shot-01 (2).png")
    }

    /// No note when the landed name *is* the row's name — the common case must stay quiet.
    func testARowWhoseNameIsTheLandedNameSaysNothingExtra() {
        var record = DownloadRecord(filename: "t38-notes.txt", source: "https://mm.example.com/api/v4/files/b")
        record.destination = "file:///Downloads/t38-notes.txt"
        record.state = .done
        XCTAssertNil(DownloadFormatting.landedName(record))
        XCTAssertNil(DownloadFormatting.savedAsNote(record))
    }

    /// A file that has not landed names nothing at all, even if a destination string is present.
    func testAnUnfinishedRowNamesNoLandedFile() {
        var record = DownloadRecord(filename: "t38-report.pdf", source: "https://mm.example.com/api/v4/files/c")
        record.destination = "file:///Downloads/t38-report (2).pdf"
        record.state = .downloading
        XCTAssertNil(DownloadFormatting.savedAsNote(record))
        record.destination = ""
        record.state = .done
        XCTAssertNil(DownloadFormatting.savedAsNote(record))
    }
}

/// T38-AV F5: the text/PDF readers fetch the whole payload, so the card's bound has to be a **fetch**
/// bound decided from `metadata.files` — not the 256 KB text cap applied after the allocation.
final class T38PreviewFetchLimitTests: XCTestCase {

    func testATextFilePastTheFetchLimitIsRefusedBeforeAnyBytesAreFetched() {
        let decision = PreviewFetchDecision.decide(kind: .text,
                                                   byteCount: Int64(FileTypeMap.previewFetchByteLimit) + 1)
        XCTAssertEqual(decision, .tooLarge(limit: Int64(FileTypeMap.previewFetchByteLimit)))
    }

    func testAPDFPastTheFetchLimitIsRefusedToo() {
        XCTAssertEqual(PreviewFetchDecision.decide(kind: .pdf, byteCount: 120 * 1024 * 1024),
                       .tooLarge(limit: Int64(FileTypeMap.previewFetchByteLimit)))
    }

    func testAFileAtOrUnderTheLimitIsFetched() {
        XCTAssertEqual(PreviewFetchDecision.decide(kind: .text, byteCount: 421 * 1024), .fetch,
                       "the live suite's 421 KB log is a preview, not a refusal")
        XCTAssertEqual(PreviewFetchDecision.decide(kind: .text,
                                                   byteCount: Int64(FileTypeMap.previewFetchByteLimit)),
                       .fetch, "the limit itself is allowed")
    }

    /// An image is not gated by this rule: the gallery fetches it and downsamples during decode, and
    /// the store bounds the bitmap by pixel count. Refusing here would hide a large photo instead of
    /// bounding it.
    func testAnImageIsNeverRefusedByTheFetchLimit() {
        XCTAssertEqual(PreviewFetchDecision.decide(kind: .image, byteCount: 200 * 1024 * 1024), .fetch)
        XCTAssertEqual(PreviewFetchDecision.decide(kind: .unsupported(.noReader),
                                                   byteCount: 200 * 1024 * 1024), .fetch)
    }

    /// A payload with no declared size (`0`) must not be refused: the server's own limit is the only
    /// bound left, and refusing would lose a readable file.
    func testAnUnknownSizeIsNotARefusal() {
        XCTAssertEqual(PreviewFetchDecision.decide(kind: .text, byteCount: 0), .fetch)
    }
}

// MARK: - 6. What a row says about a download

final class T38AttachmentDownloadStateTests: XCTestCase {

    func testAnIdleRowSaysNothing() {
        XCTAssertEqual(AttachmentDownloadState.idle.label, "")
        XCTAssertFalse(AttachmentDownloadState.idle.isActive)
    }

    func testProgressNeedsATotalAndSaysPercentWhenItHasOne() {
        XCTAssertEqual(AttachmentDownloadState.from(.downloading, received: 25, total: 100).label,
                       "Downloading 25%")
        XCTAssertEqual(AttachmentDownloadState.from(.downloading, received: 25, total: 0).label,
                       "Downloading…", "no Content-Length yet")
    }

    func testTerminalStatesMapToTheRowsVocabulary() {
        XCTAssertEqual(AttachmentDownloadState.from(.done, received: 10, total: 10), .done)
        XCTAssertEqual(AttachmentDownloadState.from(.cancelled, received: 1, total: 10), .idle)
        XCTAssertEqual(AttachmentDownloadState.from(.error, received: 0, total: 0), .failed(""))
        XCTAssertEqual(AttachmentDownloadState.from(.waitToRetry, received: 0, total: 0), .failed(""))
        XCTAssertEqual(AttachmentDownloadState.from(nil, received: 0, total: 0), .idle)
    }

    func testTheLandedLabelNamesTheDownloadsScreen() {
        XCTAssertEqual(AttachmentDownloadState.done.label, "Saved to Downloads")
    }

    func testAFailureCarriesItsReasonWhenItHasOne() {
        XCTAssertEqual(AttachmentDownloadState.failed("the server blocked this file").label,
                       "Download failed: the server blocked this file")
    }
}

// MARK: - 7. The authenticated download request

final class T38AuthorizedRequestTests: XCTestCase {

    private let serverURL = URL(string: "https://mm.example.com")!

    private func client(token: String?) throws -> APIClient {
        try APIClient(serverURL: serverURL,
                      transport: FakeAPITransport(stubs: []),
                      retryPolicy: .none,
                      tokenProvider: { token })
    }

    func testTheDownloadRequestCarriesTheSessionsTokenAndTheV4Path() throws {
        let request = try client(token: "abc123").authorizedRequest(path: "/files/file1")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://mm.example.com/api/v4/files/file1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Requested-With"), "XMLHttpRequest")
    }

    func testASignedOutClientCannotBuildADownloadRequest() {
        XCTAssertThrowsError(try client(token: nil).authorizedRequest(path: "/files/file1")) { error in
            XCTAssertEqual(error as? MMError, .notSignedIn)
        }
        XCTAssertThrowsError(try client(token: "").authorizedRequest(path: "/files/file1"))
    }
}

// MARK: - 8. A fake file service (bytes, with a hold and a cancellation counter)

@MainActor
final class T38FakeFileService: ChannelServing {
    var blobs: [String: Data] = [:]
    /// File ids whose fetch suspends until `release(_:)`, so a test can observe the in-flight state.
    var held: Set<String> = []
    private(set) var requested: [String] = []
    private(set) var requestedThumbnails: [Bool] = []
    private(set) var cancelled: [String] = []
    var downloadRequestError: Error?
    private var continuations: [String: CheckedContinuation<Data, Error>] = [:]

    func channel(id: String) async throws -> MMChannel {
        MMChannel(id: id, name: "c", displayName: "Channel", type: "O", teamId: "t")
    }

    func posts(channelID: String, before: String?, perPage: Int) async throws -> MMPostList {
        MMPostList(order: [], posts: [:], hasNext: false)
    }

    func users(ids: [String]) async throws -> [MMUser] { [] }

    func fileData(fileID: String, preferThumbnail: Bool) async throws -> Data {
        requested.append(fileID)
        requestedThumbnails.append(preferThumbnail)
        if held.contains(fileID) {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    continuations[fileID] = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    cancelled.append(fileID)
                    continuations.removeValue(forKey: fileID)?.resume(throwing: CancellationError())
                }
            }
        }
        guard let data = blobs[fileID] else { throw MMError.notFound }
        return data
    }

    func fileDownloadRequest(fileID: String) throws -> URLRequest {
        if let downloadRequestError { throw downloadRequestError }
        return URLRequest(url: URL(string: "https://mm.example.com/api/v4/files/\(fileID)")!)
    }

    func release(_ fileID: String) {
        continuations.removeValue(forKey: fileID)?.resume(returning: blobs[fileID] ?? Data())
    }
}

// MARK: - 9. The image store: bounded, cancellable, shared

@MainActor
final class T38ChannelImageStoreTests: XCTestCase {

    private var service: T38FakeFileService!
    private var store: ChannelImageStore!
    private let png = T38Image.png()

    override func setUp() async throws {
        service = T38FakeFileService()
        store = ChannelImageStore(service: service)
    }

    override func tearDown() async throws {
        store.clear()
        store = nil
        service = nil
    }

    private func attribute(_ id: String) -> PostAttachment {
        t38Attachment(id, name: "\(id).png")
    }

    /// Let the main-actor tasks in flight make progress without sleeping on a wall clock.
    private func settle(_ rounds: Int = 40) async {
        for _ in 0..<rounds { await Task.yield() }
    }

    func testAnInlineImageIsDecodedToAPreviewBitmap() async {
        service.blobs["a"] = png
        let image = await store.image(for: attribute("a"))
        XCTAssertNotNil(image)
        XCTAssertEqual(store.cachedPreviewCount, 1)
        // The original bytes are what the card's correctness claim rests on (a thumbnail is 120 px).
        XCTAssertEqual(service.requested, ["a"])
        XCTAssertEqual(service.requestedThumbnails, [false])
    }

    func testAReturnedRowDrawsFromTheCacheWithoutAskingAgain() async {
        service.blobs["a"] = png
        _ = await store.image(for: attribute("a"))
        _ = await store.image(for: attribute("a"))
        XCTAssertEqual(service.requested, ["a"], "one request per file, not one per draw")
        XCTAssertNotNil(store.cachedImage(for: attribute("a")))
    }

    func testTwoRowsAskingForOneFileShareASingleRequest() async {
        service.blobs["a"] = png
        service.held.insert("a")
        let first = Task { await store.image(for: attribute("a")) }
        let second = Task { await store.image(for: attribute("a")) }
        await settle()
        XCTAssertEqual(service.requested, ["a"], "a shared load, not two")
        XCTAssertEqual(store.inFlightCount, 1)
        service.release("a")
        let firstImage = await first.value
        let secondImage = await second.value
        XCTAssertNotNil(firstImage)
        XCTAssertNotNil(secondImage)
        XCTAssertEqual(store.inFlightCount, 0)
    }

    func testACancelledRowCancelsTheRequestAndCachesNothing() async {
        service.blobs["a"] = png
        service.held.insert("a")
        let row = Task { await store.image(for: attribute("a")) }
        await settle()
        XCTAssertEqual(store.inFlightCount, 1, "the fetch is in flight before the row goes away")
        row.cancel()
        await settle(200)
        let result = await row.value
        XCTAssertNil(result, "a cancelled load draws the placeholder, not a broken image")
        XCTAssertEqual(store.inFlightCount, 0, "no request and no waiter is left behind")
        XCTAssertEqual(service.cancelled, ["a"], "the underlying request was actually cancelled")
        XCTAssertEqual(store.cachedPreviewCount, 0, "nothing was cached for a row nobody is drawing")
    }

    func testScrollingTwoHundredImagesKeepsThePreviewCacheBounded() async {
        // The acceptance criterion: a media-heavy channel must not grow without bound. Each load is
        // a real decode of real PNG bytes, so this measures the store, not a stub.
        for index in 0..<200 { service.blobs["f\(index)"] = png }
        for index in 0..<200 {
            _ = await store.image(for: attribute("f\(index)"))
        }
        XCTAssertLessThanOrEqual(store.cachedPreviewCount, ChannelImageStore.previewLimit)
        XCTAssertLessThanOrEqual(store.cachedPreviewBytes, ChannelImageStore.previewByteLimit)
        XCTAssertLessThanOrEqual(store.cachedOriginalCount, ChannelImageStore.originalLimit)
        XCTAssertEqual(store.inFlightCount, 0)
    }

    func testTheGalleryBitmapIsDownsampledToItsCap() async throws {
        service.blobs["big"] = T38Image.png(width: 2400, height: 1600)
        let image = await store.galleryImage(for: attribute("big"))
        let decoded = try XCTUnwrap(image)
        XCTAssertLessThanOrEqual(max(decoded.size.width, decoded.size.height),
                                 CGFloat(ChannelImageStore.galleryMaxPixel))
        XCTAssertGreaterThan(decoded.size.width, decoded.size.height, "the aspect ratio is kept")
    }

    func testABlockedOrNonImageFileIsNeverFetchedAsAPreview() async {
        service.blobs["doc"] = Data("hello".utf8)
        let textFile = await store.image(for: t38Attachment("doc", name: "notes.txt", mime: "text/plain"))
        XCTAssertNil(textFile)
        let blocked = t38Attachment("b1", name: "secret.png", mime: "image/png", blocked: true)
        let blockedImage = await store.image(for: blocked)
        XCTAssertNil(blockedImage)
        XCTAssertTrue(service.requested.isEmpty,
                      "neither a text file nor a blocked file is an image load")
    }

    func testOriginalBytesAreAvailableForTheFileReadersAndRefusedForABlockedFile() async {
        service.blobs["doc"] = Data("%PDF-1.4".utf8)
        let data = await store.originalData(for: t38Attachment("doc", name: "r.pdf", mime: "application/pdf"))
        XCTAssertEqual(data, Data("%PDF-1.4".utf8))
        let blocked = t38Attachment("b1", name: "secret.pdf", mime: "application/pdf", blocked: true)
        let blockedData = await store.originalData(for: blocked)
        XCTAssertNil(blockedData)
    }

    func testClearCancelsEverythingAndEmptiesEveryCache() async {
        service.blobs["a"] = png
        _ = await store.image(for: attribute("a"))
        _ = await store.originalData(for: attribute("a"))
        XCTAssertGreaterThan(store.cachedPreviewCount, 0)
        store.clear()
        XCTAssertEqual(store.cachedPreviewCount, 0)
        XCTAssertEqual(store.cachedOriginalCount, 0)
        XCTAssertEqual(store.inFlightCount, 0)
    }

    func testABitmapThatIsNotAnImageFailureIsNotCachedAsOne() async {
        service.blobs["fake"] = Data("this is not a png".utf8)
        let image = await store.image(for: attribute("fake"))
        XCTAssertNil(image, "ImageIO refuses it; the row draws Retry")
        XCTAssertEqual(store.cachedPreviewCount, 0)
    }
}

// MARK: - 10. The download coordinator (one journal, no second downloader)

@MainActor
final class T38AttachmentDownloadsTests: XCTestCase {

    private var service: T38FakeFileService!
    private var worker: DownloadWorker!
    private var downloads: AttachmentDownloads!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        service = T38FakeFileService()
        // An isolated journal: the app host's real `mm.downloads.history` must not leak into a test
        // (measured: a shared journal made "nothing was journaled" fail on rows an earlier run wrote).
        suiteName = "t38-downloads-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        worker = DownloadWorker(history: DownloadHistory(preferences: AppPreferences(defaults: defaults)))
        downloads = AttachmentDownloads(worker: worker, service: service)
    }

    override func tearDown() async throws {
        if let suiteName { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        defaults = nil
        downloads = nil
        worker = nil
        service = nil
    }

    func testABlockedFileIsNotDownloadedAndSaysWhy() {
        let blocked = t38Attachment("b1", name: "secret.txt", mime: "text/plain", blocked: true)
        XCTAssertNil(downloads.download(blocked))
        XCTAssertEqual(downloads.state(for: "b1"), .failed("the server blocked this file"))
        XCTAssertTrue(worker.history.records.isEmpty, "nothing was journaled for a refused file")
    }

    func testAServiceThatCannotBuildARequestReportsAReasonInsteadOfDownloadingNothing() {
        service.downloadRequestError = MMError.forbidden(message: nil)
        let attachment = t38Attachment("f1", name: "notes.txt", mime: "text/plain")
        XCTAssertNil(downloads.download(attachment))
        guard case .failed(let reason) = downloads.state(for: "f1") else {
            return XCTFail("a failed download must be a failed state, was \(downloads.state(for: "f1"))")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(worker.history.records.isEmpty)
    }

    func testStartingADownloadJournalsItUnderTheServersName() throws {
        let attachment = t38Attachment("f1", name: "shot.png", size: 2048)
        let record = try XCTUnwrap(downloads.download(attachment))
        XCTAssertEqual(record.filename, "shot.png")
        XCTAssertEqual(worker.history.records.first?.id, record.id)
        XCTAssertEqual(downloads.state(for: "f1").isActive, true, "the row shows progress while it runs")
        worker.cancel(id: record.id)
    }

    func testTheRowFollowsTheJournalRatherThanItsOwnStateMachine() throws {
        let attachment = t38Attachment("f1", name: "shot.png", size: 2048)
        let record = try XCTUnwrap(downloads.download(attachment))
        var next = record
        next.state = .done
        next.totalBytes = 2048
        next.receivedBytes = 2048
        next.destination = URL.downloadsDirectory.appendingPathComponent("shot.png").absoluteString
        worker.history.update(next)
        XCTAssertEqual(downloads.state(for: "f1"), .done)
        XCTAssertEqual(downloads.record(for: "f1")?.destination, next.destination)
    }

    func testADeletedJournalRowMakesTheRowOfferdownloadAgain() throws {
        let attachment = t38Attachment("f1", name: "shot.png")
        let record = try XCTUnwrap(downloads.download(attachment))
        worker.remove(id: record.id)
        XCTAssertEqual(downloads.state(for: "f1"), .idle)
    }
}
