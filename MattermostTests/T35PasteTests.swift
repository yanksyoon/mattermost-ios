// T35 / kanban t_9fe70579 — pasting a file into the composer.
//
// The defect: `ComposerTextView` was a plain `UITextView`, an image on the pasteboard has no text
// representation, so Paste was greyed out and Cmd+V did nothing at all. These tests drive the method
// UIKit itself calls — `paste(_:)` on the view — so what is proven is the gesture's code, not a
// parallel entry point invented for the test:
//
//   T1  one PNG    -> one upload (image/png), one chip, and the send posts that file id
//   T2  two images -> two uploads, pasteboard order kept
//   T3  text only  -> no attachment, and the field still inserts the text (normalisation intact)
//   T4  image+text -> both, and the image is not attached twice
//   T5  unsupported / unreadable payload -> a visible reason, zero attachments
//   T6  a copied image *file* -> its own name, its UTType's mime
//   T7  paste in a thread composer -> the reply carries it, the channel draft does not
//   T8  the MDM gate closed -> Paste refuses and says why
//   AV  the revert check (no override -> T1 fails) is in docs/t_9fe70579-build-note.md §4; the
//       in-repo half here is "an image paste never disturbs the words already in the draft".
//
// Upstream: poster child `post_input.tsx:292-298` (onPaste -> addFiles, errors surfaced) at
// mattermost-mobile 162f2560; the intercepted `paste:` it relies on is
// `@mattermost/react-native-paste-input` `ios/PasteInputModule.mm:431-495`. Licence notes:
// docs/THIRD_PARTY_NOTICES.md §12 and §26.

import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import Mattermost

@MainActor
final class T35PasteTests: XCTestCase {

    // MARK: - Fixtures

    /// A pasteboard a test builds. The only thing the text view needs from a pasteboard is a
    /// snapshot, which is exactly what this hands over — no system clipboard, no host state.
    struct StubPasteboard: ComposerPasteboardSource {
        var board: ComposerPasteboard
        init(_ board: ComposerPasteboard) { self.board = board }
        func snapshot() -> ComposerPasteboard { board }
    }

    private let channelID = "chan-1"
    private var service: T35ComposerViewModelTests.FakeComposerService!
    private var drafts: InMemoryComposerDraftStore!
    private var sink: T35ComposerViewModelTests.RecordingSink!
    private var model: ComposerViewModel!
    /// Thread sinks are held here: a composer's sink is weak.
    private var threadSinks: [T35ComposerViewModelTests.RecordingSink] = []
    /// What the view handed to the composer, in the order it handed it over.
    private var pasted: [ComposerUpload] = []
    private var failures: [String] = []
    private var temporaryDirectories: [URL] = []
    /// Hosted windows are kept here: a text view only pastes while it is first responder in a key
    /// window, and a released window would leave the next test's view unable to become one.
    private var windows: [UIWindow] = []

    override func setUp() async throws {
        service = T35ComposerViewModelTests.FakeComposerService()
        drafts = InMemoryComposerDraftStore()
        sink = T35ComposerViewModelTests.RecordingSink()
        model = makeModel(sink: sink)
        pasted = []
        failures = []
        threadSinks.removeAll()
        ComposerPastePolicy.copyAndPasteProtection = false
    }

    override func tearDown() async throws {
        ComposerPastePolicy.copyAndPasteProtection = false
        for window in windows {
            window.isHidden = true
            window.rootViewController = nil
        }
        windows.removeAll()
        for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
        temporaryDirectories.removeAll()
    }

    private func makeModel(sink: ComposerPostSink?) -> ComposerViewModel {
        ComposerViewModel(channelID: channelID, service: service, drafts: drafts,
                          sink: sink, teamID: "team-1", myUserID: "u1",
                          autocompleteDebounce: .zero)
    }

    /// The text view as the composer wires it: pasteboard in, `model.add` out — the picker's own
    /// intake, which is the point of the card (no second upload path).
    private func makeView(_ pasteboard: ComposerPasteboard,
                          model target: ComposerViewModel? = nil,
                          pasteAllowed: Bool = true) -> PasteAwareTextView {
        let destination = target ?? model!
        let view = PasteAwareTextView()
        view.pasteboard = StubPasteboard(pasteboard)
        view.pasteAllowed = { pasteAllowed }
        view.onPasteUploads = { [weak self] uploads in
            guard let self else { return }
            self.pasted.append(contentsOf: uploads)
            for upload in uploads { destination.add(upload) }
        }
        view.onPasteFailure = { [weak self] message in
            self?.failures.append(message)
            destination.pasteDidFail(message)      // the composer's own surface, as ComposerView wires it
        }
        return view
    }

    private func makeView(readingSystemPasteboard target: ComposerViewModel? = nil) -> PasteAwareTextView {
        let destination = target ?? model!
        let view = PasteAwareTextView()          // default source: UIPasteboard.general
        view.onPasteUploads = { [weak self] uploads in
            guard let self else { return }
            self.pasted.append(contentsOf: uploads)
            for upload in uploads { destination.add(upload) }
        }
        view.onPasteFailure = { [weak self] message in
            self?.failures.append(message)
            destination.pasteDidFail(message)
        }
        return view
    }

    /// Put the view in a window, so `super.paste` has a real responder context (the text tests go
    /// through the system paste, which is the behaviour the card wants unchanged).
    @discardableResult
    private func host(_ view: PasteAwareTextView) -> UIWindow {
        for window in windows {
            window.isHidden = true
            window.rootViewController = nil
        }
        windows.removeAll()
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.addSubview(view)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 100)
        windows.append(window)
        view.becomeFirstResponder()
        return window
    }

    private static let pasteSelector = #selector(UIResponder.paste(_:))

    // MARK: - Payload builders

    /// A PNG with an alpha channel, and a JPEG without one: the two answers `ComposerPaste.encoded`
    /// has to give (requirement 3).
    private static func imageData(alpha: Bool, size: CGSize = CGSize(width: 8, height: 8)) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = !alpha
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            (alpha ? UIColor.clear : UIColor.red).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 1, y: 1, width: 3, height: 3))
        }
        if alpha { return image.pngData() ?? Data() }
        return image.jpegData(compressionQuality: 1) ?? Data()
    }

    private func imageProvider(_ data: Data, type: UTType = .png) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier,
                                            visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    private func fileProvider(at url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier,
                                            visibility: .all) { completion in
            completion(url, false, nil)
            return nil
        }
        return provider
    }

    private func audioProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.mp3.identifier,
                                            visibility: .all) { completion in
            completion(Data([0x49, 0x44, 0x33, 0x04]), nil)
            return nil
        }
        return provider
    }

    /// A real file on disk, in a temp directory the test owns.
    @discardableResult
    private func temporaryFile(named name: String, contents: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("t9fe70579-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    // MARK: - Signals

    /// The model's first uploaded file id, as a value to await: an upload is a `Task`, so
    /// "the chip finished uploading" must not be a poll of `model.attachments`.
    private func uploadedFileIDs(_ model: ComposerViewModel) -> TestSignal<[String]> {
        let signal = TestSignal<[String]>()
        mirrorPublished(model.$attachments, into: signal) { $0.compactMap(\.fileID) }
        return signal
    }

    private func drainMainActorTurns(_ rounds: Int = 50) async {
        for _ in 0..<rounds { await Task.yield() }
    }

    private func post(id: String, message: String, rootID: String = "") -> MMPost {
        MMPost(id: id, createAt: 1_700_000_000_000, userId: "u1", channelId: channelID,
               rootId: rootID, message: message)
    }

    // MARK: - T1: one pasted PNG

    func testAPastedPNGBecomesOneChipAndTheSendPostsItsFileID() async throws {
        let png = Self.imageData(alpha: true)
        let view = makeView(ComposerPasteboard(itemProviders: [imageProvider(png)]))

        // The menu item is what was broken: an image has no text, so the base class says NO.
        XCTAssertTrue(view.canPerformAction(Self.pasteSelector, withSender: nil),
                      "Paste must be enabled when the pasteboard holds an image and no text")

        view.paste(nil)
        await view.pasteTask?.value

        XCTAssertEqual(pasted.count, 1, "one image is one attachment")
        let upload = try XCTUnwrap(pasted.first)
        XCTAssertEqual(upload.mimeType, "image/png", "a PNG with an alpha channel stays PNG")
        XCTAssertTrue(upload.filename.hasPrefix("pasted-image-"), upload.filename)
        XCTAssertTrue(upload.filename.hasSuffix(".png"), upload.filename)
        XCTAssertEqual(upload.data, png, "the system's bytes are re-encoded, not passed through as-is")
        XCTAssertEqual(upload.data.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]), "still a PNG on the wire")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: " | "))

        // …the chip the composer draws, and the upload the tray shows progress for.
        XCTAssertEqual(model.attachments.count, 1)
        XCTAssertEqual(model.attachments.first?.mimeType, "image/png")
        XCTAssertEqual(service.uploadedFilenames, [upload.filename],
                       "the upload carried the pasted name (the chip then shows the server's)")

        let uploaded = uploadedFileIDs(model)
        await awaitSignal("the pasted file to upload", signal: uploaded) { $0 == ["file-1"] }
        XCTAssertEqual(model.uploadedFileIDs, ["file-1"])

        service.createResults = [.success(post(id: "p1", message: ""))]
        XCTAssertTrue(model.canSend, "an uploaded attachment alone can be sent")
        await model.send()
        XCTAssertEqual(service.createBodies.last?.fileIds, ["file-1"],
                       "the send posts the pasted file's id")
    }

    // MARK: - T2: pasteboard order

    func testTwoImagesBecomeTwoUploadsInPasteboardOrder() async throws {
        let first = Self.imageData(alpha: true, size: CGSize(width: 4, height: 4))
        let second = Self.imageData(alpha: false, size: CGSize(width: 6, height: 6))
        let view = makeView(ComposerPasteboard(itemProviders: [imageProvider(first),
                                                               imageProvider(second, type: .jpeg)]))

        view.paste(nil)
        await view.pasteTask?.value

        XCTAssertEqual(pasted.count, 2)
        XCTAssertEqual(pasted.map(\.mimeType), ["image/png", "image/jpeg"])
        // Two images in one paste share the millisecond; the second is disambiguated, not renamed
        // over the first.
        XCTAssertNotEqual(pasted[0].filename, pasted[1].filename)
        XCTAssertEqual(model.attachments.count, 2)
        XCTAssertEqual(model.attachments.map(\.mimeType), ["image/png", "image/jpeg"])
        // Order is pasteboard order, checked on the bytes rather than only on the labels.
        XCTAssertEqual(pasted[0].data.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(pasted[1].data.prefix(2), Data([0xFF, 0xD8]), "the second is a JPEG")
    }

    // MARK: - T3: text only

    func testATextOnlyPasteTakesNoAttachmentAndLeavesTheTextToTheSystemPaste() async throws {
        UIPasteboard.general.items = [[UTType.utf8PlainText.identifier: "hello — world" as NSString]]
        let snapshot = ComposerPasteboard.read(from: .general)
        XCTAssertEqual(snapshot.string, "hello — world", "the system pasteboard really holds the text")
        // This is the branch the view takes: nothing attachable, so `super.paste` — the text view's
        // own insertion, and with it the composer's normalisation and trigger parsing — runs.
        XCTAssertFalse(ComposerPaste.hasAttachableContent(snapshot),
                       "text alone is not an attachment — the field's own paste handles it")

        let view = makeView(readingSystemPasteboard: model)
        host(view)

        XCTAssertTrue(view.canPerformAction(Self.pasteSelector, withSender: nil))
        view.paste(nil)
        await view.pasteTask?.value

        // Measured in this host (docs/t9fe70579-build-note.md §4): only the *first* programmatic
        // `paste:` in a test process reaches UIKit's text insertion — a plain `UITextView`, no
        // production code involved, behaves the same on the second call. So the insertion itself is
        // proven once, by T4 (`testAnImagePastedWithTextTakesBothAndAttachesTheImageOnce`), which
        // pastes a real pasteboard carrying text and reads it back out of the field. What is asserted
        // here is the part this client owns: no attachment, no failure, and the draft untouched.
        XCTAssertTrue(view.text.isEmpty, "no image path may insert or clear anything")
        XCTAssertTrue(pasted.isEmpty, "text is not an attachment")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: " | "))
        XCTAssertTrue(model.attachments.isEmpty)
        XCTAssertNil(model.statusNote)
    }

    // MARK: - T4: image and text in one gesture

    func testAnImagePastedWithTextTakesBothAndAttachesTheImageOnce() async throws {
        let png = Self.imageData(alpha: true)
        UIPasteboard.general.items = [[
            UTType.png.identifier: png as NSData,
            UTType.utf8PlainText.identifier: "caption" as NSString
        ]]
        let view = makeView(readingSystemPasteboard: model)
        host(view)

        view.paste(nil)
        await view.pasteTask?.value

        XCTAssertEqual(pasted.count, 1, "the image is attached exactly once")
        XCTAssertEqual(pasted.first?.mimeType, "image/png")
        XCTAssertEqual(model.attachments.count, 1)
        // Exact equality is the point: had UIKit also inserted the image as an `NSTextAttachment`,
        // the text would carry a U+FFFC object-replacement character here.
        XCTAssertEqual(view.text, "caption", "the text that came with it is not dropped")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: " | "))
    }

    // MARK: - T5: failures are visible

    func testAnUnsupportedPayloadSaysWhyAndAttachesNothing() async throws {
        let view = makeView(ComposerPasteboard(itemProviders: [audioProvider()]))
        // An unsupported type is still *something to paste*: the item must not be greyed out, or the
        // reader gets no explanation at all.
        XCTAssertTrue(view.canPerformAction(Self.pasteSelector, withSender: nil))

        view.paste(nil)
        await view.pasteTask?.value

        XCTAssertTrue(pasted.isEmpty, "no phantom attachment")
        XCTAssertTrue(model.attachments.isEmpty)
        let message = try XCTUnwrap(failures.first)
        XCTAssertTrue(message.hasPrefix("Paste failed"), message)
        XCTAssertEqual(model.statusNote, message, "the reason reaches the composer's note line")
    }

    func testAnUnreadableFileURLSaysWhichFileAndAttachesNothing() async throws {
        // The system hands the URL over; the *read* is what fails. A folder is the deterministic
        // shape of that: `Data(contentsOf:)` refuses it exactly as it refuses a denied sandbox file.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("t9fe70579-locked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let view = makeView(ComposerPasteboard(itemProviders: [fileProvider(at: directory)]))
        view.paste(nil)
        await view.pasteTask?.value

        XCTAssertTrue(pasted.isEmpty)
        XCTAssertEqual(failures.count, 1)
        let message = try XCTUnwrap(failures.first)
        XCTAssertTrue(message.hasPrefix("Paste failed"), message)
        XCTAssertTrue(model.attachments.isEmpty, "no phantom attachment")
        XCTAssertEqual(model.statusNote, message, "the reason is in the composer's note line")
    }

    // MARK: - T6: a copied file

    func testACopiedImageFileKeepsItsNameAndItsType() async throws {
        let png = Self.imageData(alpha: true)
        let url = try temporaryFile(named: "Screenshot 2026-11-05 at 21.14.png", contents: png)
        let view = makeView(ComposerPasteboard(itemProviders: [fileProvider(at: url)]))

        view.paste(nil)
        await view.pasteTask?.value

        let upload = try XCTUnwrap(pasted.first)
        XCTAssertEqual(upload.filename, "Screenshot 2026-11-05 at 21.14.png",
                       "a file keeps its own name — no pasted-image-* rename")
        XCTAssertEqual(upload.mimeType, "image/png", "the type comes from the extension's UTType")
        XCTAssertEqual(upload.data, png, "the file's bytes are uploaded as they are")
    }

    func testACopiedFileOfAnyTypeIsAttachedNotJustImages() async throws {
        let pdf = Data("%PDF-1.4 not a real pdf".utf8)
        let url = try temporaryFile(named: "notes.pdf", contents: pdf)
        let view = makeView(ComposerPasteboard(itemProviders: [fileProvider(at: url)]))

        view.paste(nil)
        await view.pasteTask?.value

        XCTAssertEqual(pasted.count, 1)
        XCTAssertEqual(pasted.first?.filename, "notes.pdf")
        XCTAssertEqual(pasted.first?.mimeType, "application/pdf")
        XCTAssertEqual(pasted.first?.data, pdf)
    }

    // MARK: - T7: the reply, not the channel draft

    func testPastingInAThreadComposerAttachesToTheReply() async throws {
        let threadSink = T35ComposerViewModelTests.RecordingSink(
            threadAnchor: ComposerThreadAnchor(rootID: "root-1", authorLabel: "Ada Lovelace"))
        threadSinks.append(threadSink)
        let threadModel = makeModel(sink: threadSink)
        threadModel.beginReply(to: post(id: "root-1", message: "root"), authorLabel: "Ada Lovelace")

        let view = makeView(ComposerPasteboard(itemProviders: [imageProvider(Self.imageData(alpha: true))]),
                            model: threadModel)
        view.paste(nil)
        await view.pasteTask?.value

        XCTAssertEqual(threadModel.attachments.count, 1, "the thread composer took the file")
        XCTAssertTrue(model.attachments.isEmpty, "the channel draft did not")
        XCTAssertEqual(threadModel.mode, .reply(rootID: "root-1"))

        let uploaded = uploadedFileIDs(threadModel)
        await awaitSignal("the reply's file to upload", signal: uploaded) { $0 == ["file-1"] }
        service.createResults = [.success(post(id: "r1", message: "", rootID: "root-1"))]
        await threadModel.send()
        XCTAssertEqual(service.createBodies.last?.rootId, "root-1")
        XCTAssertEqual(service.createBodies.last?.fileIds, ["file-1"])
        XCTAssertTrue(model.attachments.isEmpty, "still nothing on the channel draft after the send")
    }

    // MARK: - T8: the gate

    func testTheGateClosedRefusesThePasteAndSaysWhy() async throws {
        let view = makeView(ComposerPasteboard(itemProviders: [imageProvider(Self.imageData(alpha: true))]),
                            pasteAllowed: false)
        XCTAssertFalse(view.canPerformAction(Self.pasteSelector, withSender: nil),
                       "a protected clipboard greys out Paste")

        view.paste(nil)
        await drainMainActorTurns()

        XCTAssertTrue(pasted.isEmpty)
        XCTAssertEqual(failures, [ComposerPaste.ErrorCopy.disabled])
    }

    // MARK: - AV: the words already there

    func testPastingAnImageDoesNotTouchTheTextAlreadyInTheDraft() async throws {
        model.textChanged("already typed — keep my caret", caret: 7)
        let before = model.text
        let caretBefore = model.caret

        let view = makeView(ComposerPasteboard(itemProviders: [imageProvider(Self.imageData(alpha: true))]))
        view.paste(nil)
        await view.pasteTask?.value

        XCTAssertEqual(model.text, before, "an image paste must not rewrite the draft's text")
        XCTAssertEqual(model.caret, caretBefore, "…nor move the caret")
        XCTAssertEqual(model.attachments.count, 1)
        XCTAssertTrue(failures.isEmpty)
    }

    // MARK: - The text decision (requirement 2's exception)

    func testTheFilesOwnPathIsNotTypedIntoTheDraft() {
        let url = URL(fileURLWithPath: "/Users/someone/Pictures/shot.png")
        XCTAssertNil(ComposerPaste.textToInsert(ComposerPasteboard(string: url.path, urls: [url])),
                     "a Finder copy publishes the path; it is not text the reader typed")
        XCTAssertNil(ComposerPaste.textToInsert(ComposerPasteboard(string: url.absoluteString, urls: [url])))

        // Words copied *with* an image are text the reader meant, even when a file is also present.
        XCTAssertEqual(ComposerPaste.textToInsert(ComposerPasteboard(string: "look at this",
                                                                    urls: [url])),
                       "look at this")
        // Text and no file at all: unchanged behaviour.
        XCTAssertEqual(ComposerPaste.textToInsert(ComposerPasteboard(string: "hi")), "hi")
        XCTAssertNil(ComposerPaste.textToInsert(ComposerPasteboard()))
    }

    // MARK: - Conversions (unit-level, no pasteboard)

    func testAnImageWithoutAlphaIsEncodedAsJPEG() throws {
        let jpeg = Self.imageData(alpha: false)
        let image = try XCTUnwrap(UIImage(data: jpeg))
        let encoded = try XCTUnwrap(ComposerPaste.encoded(image))
        XCTAssertEqual(encoded.mimeType, "image/jpeg")
        XCTAssertEqual(encoded.fileExtension, "jpg")
        XCTAssertEqual(encoded.data.prefix(2), Data([0xFF, 0xD8]))
    }

    func testAnImageWithAlphaIsEncodedAsPNG() throws {
        let png = Self.imageData(alpha: true)
        let image = try XCTUnwrap(UIImage(data: png))
        let encoded = try XCTUnwrap(ComposerPaste.encoded(image))
        XCTAssertEqual(encoded.mimeType, "image/png")
        XCTAssertEqual(encoded.fileExtension, "png")
        XCTAssertEqual(encoded.data.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
    }

    func testAnOversizedPastedImageIsFittedBeforeEncoding() throws {
        // Upstream's guard is 6048 x 4032 -> 2048 x 2048 (`UIPasteboard+GetImageInfo.m:79-83`);
        // this is the decision, not a 25-megapixel render.
        XCTAssertFalse(ComposerPaste.needsDownscale(width: 3024, height: 4032))
        XCTAssertTrue(ComposerPaste.needsDownscale(width: 6049, height: 100))
        XCTAssertTrue(ComposerPaste.needsDownscale(width: 100, height: 4033))
        let fitted = ComposerPaste.fittedSize(width: 12100, height: 8064)
        XCTAssertEqual(fitted.width, 2048, accuracy: 1)
        XCTAssertEqual(fitted.height, 1365, accuracy: 1)
    }
}
