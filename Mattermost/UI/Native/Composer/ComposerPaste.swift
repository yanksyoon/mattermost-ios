// A paste that carries files — a screenshot, a Finder copy, a PDF — becomes an attachment through
// the same intake as a picked file (`ComposerViewModel.add`), and a paste that carries only text is
// left to the text view's own `paste:`, so the composer's existing text rules still run.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0
// (`162f2560d0e1df073220f7701d5a67cc17c8abeb`)
//   app/components/post_draft/post_input/post_input.tsx:6
//       import PasteableTextInput, {type PastedFile} from '@mattermost/react-native-paste-input';
//   :292-298
//       const onPaste = useCallback(async (error, files) => {
//           if (error) { showPasteFilesErrorDialog(intl); }
//           addFiles(await extractFileInfo(files));
//       }, [addFiles, intl]);
//   :383-399   <PasteableTextInput disableCopyPaste={disableCopyAndPaste} onPaste={onPaste} … />
//   :170       const disableCopyAndPaste = managedConfig.copyAndPasteProtection === 'true';
//   :50-68     the dialog: `mobile.files_paste.error_title` ("Paste failed"), `_description`,
//              `_dismiss`
// and the native module the paste is actually taken from —
//   @mattermost/react-native-paste-input@2.0.1 (npm gitHead `671378e2`, MIT, © 2020 Elias Nahum;
//   a fork of luisfcofv's library):
//   ios/PasteInputModule.mm:325-386   paste: and canPerformAction:withSender: are *swizzled* onto the
//                                     TextInput's class — the same seam this file's `PasteAwareTextView`
//                                     overrides. Nothing here is a JS callback.
//   ios/PasteInputModule.mm:431-495   paste: takes the files; when *no* file can be extracted the
//                                     system handler runs (:455-462), which is how plain text still
//                                     lands in the field. When files are found, super is **not**
//                                     called (so a Finder copy's path is not typed into the draft);
//                                     this file inserts the text as well when the pasteboard holds
//                                     text that is not merely a representation of the copied file —
//                                     the card's requirement 2, which is stricter than upstream.
//   ios/PasteInputModule.mm:498-525   canPerformAction: returns YES for paste: whenever the pasteboard
//                                     has anything at all (:514-521: hasImages || hasURLs ||
//                                     hasStrings || numberOfItems), and NO for cut/copy/paste under
//                                     the MDM flag (:501-511).
//   ios/UIPasteboard+GetImageInfo.m:16-82  per-pasteboard-item order, one file per item; :94 the
//                                     downscale guard (6048 x 4032 -> 2048 x 2048); :98-102 PNG for
//                                     public.png, JPEG otherwise.
// Licence: Apache-2.0 for the mobile read set, MIT for the paste library — behaviour ported with
// attribution per docs/THIRD_PARTY_NOTICES.md §26; no upstream source copied.

import Foundation
import UIKit
import UniformTypeIdentifiers

// MARK: - The pasteboard, as this path sees it

/// Everything a paste can carry, read once into a value.
///
/// A value rather than a live `UIPasteboard` because every decision this file makes — is Edit > Paste
/// enabled? is there text to insert as well as a file? what became an attachment? — is then a pure
/// function of a snapshot a test can build without a system pasteboard (requirement 8: the providers
/// are read *as well as* `.images`/`.urls`, because a macOS-backed pasteboard exposes its types
/// lazily).
struct ComposerPasteboard {
    /// The string representation, when the pasteboard has one. Read through `hasStrings` first so a
    /// lazy (Catalyst) pasteboard is not asked to materialise every flavour.
    var string: String?
    /// One provider per pasteboard **item**, in pasteboard order — the order the attachments keep.
    var itemProviders: [NSItemProvider]
    /// `UIPasteboard.images` — the fallback when a host offers no providers (older iOS pasteboards).
    var images: [UIImage]
    /// `UIPasteboard.urls` — the fallback for a file URL when a host offers no providers.
    var urls: [URL]?

    init(string: String? = nil,
         itemProviders: [NSItemProvider] = [],
         images: [UIImage] = [],
         urls: [URL]? = nil) {
        self.string = string
        self.itemProviders = itemProviders
        self.images = images
        self.urls = urls
    }
}

extension ComposerPasteboard {
    /// Snapshot the system pasteboard. Nothing is loaded here: `itemProviders` is a list of promises,
    /// and reading through them is `ComposerPaste.read`.
    static func read(from pasteboard: UIPasteboard = .general) -> ComposerPasteboard {
        ComposerPasteboard(string: pasteboard.hasStrings ? pasteboard.string : nil,
                           itemProviders: pasteboard.itemProviders,
                           images: pasteboard.hasImages ? (pasteboard.images ?? []) : [],
                           urls: pasteboard.hasURLs ? pasteboard.urls : nil)
    }
}

/// Where a snapshot comes from. A seam, so a test pastes a pasteboard it built (`StubPasteboard` in
/// the tests) while production reads `UIPasteboard.general`.
protocol ComposerPasteboardSource {
    func snapshot() -> ComposerPasteboard
    /// Whether the pasteboard **declares** a file, asked without loading any item's data.
    ///
    /// This is the question the menu is built with, and it has to stay data-free: on iOS 16+ reading
    /// `string`/`images`/`urls` (or an item's bytes) from another app's pasteboard is a permissioned
    /// operation, and doing that while UIKit builds an edit menu blocks the main thread until the
    /// person answers the system prompt — the app stops responding to touches and to accessibility
    /// for as long as the prompt stands. `types` and `itemProviders` are metadata: no prompt.
    func declaresAttachableContent() -> Bool
}

extension ComposerPasteboardSource {
    /// The same answer for any source that is not the system pasteboard (a test's stub): there is no
    /// permission to ask about, so the snapshot's own declaration is the answer.
    func declaresAttachableContent() -> Bool {
        ComposerPaste.hasAttachableContent(snapshot())
    }
}

struct SystemPasteboard: ComposerPasteboardSource {
    func snapshot() -> ComposerPasteboard { .read(from: .general) }

    func declaresAttachableContent() -> Bool {
        ComposerPaste.declaresAttachableContent(in: .general)
    }
}

// MARK: - The one gate

/// Managed copy/paste protection — upstream's `managedConfig.copyAndPasteProtection`
/// (`post_input.tsx:170`), which hides cut/copy/paste when an MDM profile sets it.
///
/// **Documented divergence:** this client reads no MDM profile (there is no managed-config source in
/// the app yet), so the flag is `false` in every build and the gate is the single place a config
/// reader would be wired when one lands — deliberately one flag and one check
/// (`PasteAwareTextView.canPerformAction` / `paste`), not a check per payload (docs/
/// t_9fe70579-build-note.md §5).
enum ComposerPastePolicy {
    static var copyAndPasteProtection = false
}

// MARK: - The intake

enum ComposerPaste {

    /// What one paste produced: the files the composer should take, and the failures to say out loud.
    ///
    /// A failure never accompanies a phantom attachment: the upload is only appended when its bytes
    /// were really read and encoded.
    struct Outcome: Equatable {
        var uploads: [ComposerUpload] = []
        var failures: [String] = []

        var isEmpty: Bool { uploads.isEmpty && failures.isEmpty }
    }

    /// One encoded image, before it is named.
    struct EncodedImage: Equatable {
        var data: Data
        var mimeType: String
        var fileExtension: String
    }

    /// The sentences a failure is shown with. Upstream's own copy where upstream has it, so the same
    /// words reach the reader as on the mobile client.
    enum ErrorCopy {
        /// `mobile.files_paste.error_title`.
        static let title = "Paste failed"
        static func message(_ detail: String) -> String { "\(title). \(detail)" }
        /// `mobile.files_paste.error_description`, for a payload whose bytes the system could not hand
        /// over at all.
        static let generic = message("An error occurred while pasting the file(s). Please try again.")
        static let unsupported = message("That kind of item cannot be pasted into a message.")
        static let undecodableImage = message("The image could not be decoded.")
        /// The MDM gate (upstream hides the menu item instead of explaining it; a flag that turns the
        /// gesture off must still say why — card requirement T8).
        static let disabled = message("Copy and paste is turned off on this device.")
        static func unreadable(_ name: String) -> String {
            message("\(name.isEmpty ? "The file" : "\"\(name)\"") could not be read.")
        }
    }

    // MARK: What a paste would do

    /// Whether this pasteboard carries anything that should become an attachment.
    ///
    /// This is what `canPerformAction` asks: an image or a file URL has no text representation, so
    /// without it Edit > Paste stays greyed out and Cmd+V does nothing at all (the reported defect).
    static func hasAttachableContent(_ pasteboard: ComposerPasteboard) -> Bool {
        if !pasteboard.itemProviders.isEmpty {
            return pasteboard.itemProviders.contains(where: isAttachable)
        }
        return !pasteboard.images.isEmpty || !fileURLs(in: pasteboard).isEmpty
    }

    /// The same question asked of the live pasteboard **without loading any item's data**.
    ///
    /// `types`/`hasImages`/`itemProviders` are metadata queries: iOS answers them without a paste
    /// approval round trip. `string`, `images`, `urls` and any `loadItem` are data reads, and on
    /// iOS 16+ they block until the person answers the system prompt — which must not happen while a
    /// menu is being built (`PasteAwareTextView.canPerformAction`).
    static func declaresAttachableContent(in pasteboard: UIPasteboard) -> Bool {
        let providers = pasteboard.itemProviders
        if !providers.isEmpty { return providers.contains(where: isAttachable) }
        return pasteboard.hasImages
    }

    static func isAttachable(_ provider: NSItemProvider) -> Bool {
        let types = provider.registeredTypeIdentifiers
        // A provider with no declared types is a promise, not an empty item: on Catalyst the types are
        // resolved on load. Paste stays enabled and `read` decides; if nothing can be taken, no
        // attachment appears and no text is lost.
        if types.isEmpty { return true }
        // Anything that is not the text representation is something this path has to account for —
        // including a type it cannot take, because that has to be *said* rather than silently
        // ignored (requirement 6). This is upstream's rule (`PasteInputModule.mm:513-521`: any
        // content at all enables the item).
        return types.contains { !isTextLike($0) }
    }

    /// The text representations a pasteboard also carries — `public.utf8-plain-text`, `public.html`,
    /// a link's `public.url`. Those are the system paste's business; everything else is an attachment
    /// or a failure this path has to report.
    static func isTextLike(_ identifier: String) -> Bool {
        guard let type = UTType(identifier) else { return false }
        if type.conforms(to: .fileURL) || type.conforms(to: .image) { return false }
        return type.conforms(to: .text) || type.conforms(to: .url)
    }

    /// The text this paste should insert **in addition to** its files, or `nil` when it carries none.
    ///
    /// The exception is the one a Finder copy needs: the pasteboard holds the file's own path or
    /// `file://` URL as its text representation, and typing that path into the draft is not what the
    /// reader asked for. Upstream avoids it by never calling the system handler when files were found;
    /// this keeps the reader's own text instead of dropping it (card requirement 2).
    static func textToInsert(_ pasteboard: ComposerPasteboard) -> String? {
        guard let string = pasteboard.string, !string.isEmpty else { return nil }
        for url in fileURLs(in: pasteboard) where describes(string, url) { return nil }
        return string
    }

    // MARK: Reading

    /// Turn the snapshot into uploads and failures, in pasteboard order.
    ///
    /// `now` is the clock the pasted image is named from (`pasted-image-<epoch-ms>.<ext>`); a test
    /// pins it, and two images in the same millisecond are disambiguated with a `-2` suffix rather
    /// than by sharing a name the tray cannot tell apart.
    static func read(_ pasteboard: ComposerPasteboard,
                     now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) async -> Outcome {
        let accumulator = Accumulator()
        let millis = now()

        if !pasteboard.itemProviders.isEmpty {
            for provider in pasteboard.itemProviders {
                await read(provider, millis: millis, into: accumulator)
            }
            return accumulator.outcome
        }
        // No providers: the arrays are the only description of what was copied (the fallback the card
        // asks for — providers first, `.images`/`.urls` when a host exposes none).
        for image in pasteboard.images {
            append(image: image, millis: millis, into: accumulator)
        }
        for url in fileURLs(in: pasteboard) {
            let result = readFile(at: url)
            if let file = result.copiedFile {
                append(file: file, into: accumulator)
            } else if let failure = result.failure {
                accumulator.failures.append(failure)
            }
        }
        return accumulator.outcome
    }

    // MARK: Conversions

    /// Upstream's downscale guard (`UIPasteboard+GetImageInfo.m:94`): an image wider than 6048 px
    /// or taller than 4032 px is fitted into 2048 x 2048 before it is encoded. This is a
    /// **conversion**, not a refusal — nothing is rejected for being large (card requirement 7).
    static let pixelGuard = CGSize(width: 6048, height: 4032)
    static let pixelFit = CGSize(width: 2048, height: 2048)

    /// Whether a bitmap of this pixel size is past upstream's guard.
    static func needsDownscale(width: CGFloat, height: CGFloat) -> Bool {
        width > pixelGuard.width || height > pixelGuard.height
    }

    /// The size a bitmap past the guard is drawn at: 2048 on the long edge, aspect kept.
    static func fittedSize(width: CGFloat, height: CGFloat) -> CGSize {
        let scale = min(pixelFit.width / max(width, 1), pixelFit.height / max(height, 1))
        return CGSize(width: max(1, (width * scale).rounded()),
                      height: max(1, (height * scale).rounded()))
    }

    /// PNG when the bitmap carries alpha, JPEG otherwise (card requirement 3; upstream's
    /// `public.png` → PNG, everything else → JPEG, `UIPasteboard+GetImageInfo.m:98-102`).
    static func encoded(_ image: UIImage) -> EncodedImage? {
        let prepared = downscaledForPaste(image)
        // A bitmap with no `cgImage` has no alpha information to read; PNG is the lossless answer.
        let carriesAlpha = prepared.cgImage.map(hasAlphaChannel) ?? true
        if carriesAlpha {
            guard let data = prepared.pngData() else { return nil }
            return EncodedImage(data: data, mimeType: "image/png", fileExtension: "png")
        }
        guard let data = prepared.jpegData(compressionQuality: 1) else { return nil }
        return EncodedImage(data: data, mimeType: "image/jpeg", fileExtension: "jpg")
    }

    /// Decode, then encode. Runs off the main thread (`read` awaits it in a detached task) because a
    /// pasted screenshot is decoded and re-encoded, and that is not work the composer's input may
    /// block on.
    static func encoded(fromImageData data: Data) -> EncodedImage? {
        guard let image = UIImage(data: data) else { return nil }
        return encoded(image)
    }

    static func downscaledForPaste(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard needsDownscale(width: width, height: height) else { return image }
        let size = fittedSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    static func hasAlphaChannel(_ cgImage: CGImage) -> Bool {
        switch cgImage.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            return true
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        @unknown default:
            return true
        }
    }

    /// A Finder-copied file keeps its own name and its own type: the UTType the extension names, then
    /// this repo's extension table (the picker's rule), then the generic type.
    static func mimeType(forFilename filename: String) -> String {
        let ext = (filename as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return mime
        }
        return MMMultipart.mimeType(forFilename: filename)
    }

    // MARK: Private

    /// The running result of one paste. A class because the reader is a sequence of `await`s; every
    /// appender runs on the same task, so there is nothing to lock.
    private final class Accumulator {
        var uploads: [ComposerUpload] = []
        var failures: [String] = []
        var names: Set<String> = []

        var outcome: Outcome { Outcome(uploads: uploads, failures: failures) }
    }

    private static func read(_ provider: NSItemProvider,
                             millis: Int64,
                             into accumulator: Accumulator) async {
        let types = provider.registeredTypeIdentifiers
        var failure: String?

        // A file URL first: a copied *file* is one attachment with the file's own name, not an image
        // conversion (requirement 3's second sentence).
        let fileType = types.first(where: { UTType($0)?.conforms(to: .fileURL) == true })
            ?? (types.isEmpty ? UTType.fileURL.identifier : nil)
        if let fileType {
            let (file, fileFailure) = await loadFile(from: provider, type: fileType)
            if let file {
                append(file: file, into: accumulator)
                return
            }
            failure = fileFailure
        }

        let imageType = types.first(where: { UTType($0)?.conforms(to: .image) == true })
            ?? (types.isEmpty ? UTType.png.identifier : nil)
        if let imageType {
            do {
                if let data = try await loadData(from: provider, type: imageType) {
                    await append(imageData: data, millis: millis, into: accumulator)
                    return
                }
                failure = failure ?? ErrorCopy.generic
            } catch {
                failure = failure ?? ErrorCopy.generic
            }
        }

        // Nothing attachable: text, a link and rich text are the system paste's business, and a
        // provider that declares nothing at all is a promise that answered with nothing.
        if types.isEmpty || types.allSatisfy(isTextLike) { return }
        accumulator.failures.append(failure ?? ErrorCopy.unsupported)
    }

    private static func append(image: UIImage, millis: Int64, into accumulator: Accumulator) {
        guard let encoded = encoded(image) else {
            accumulator.failures.append(ErrorCopy.undecodableImage)
            return
        }
        append(encoded, millis: millis, into: accumulator)
    }

    private static func append(imageData data: Data,
                               millis: Int64,
                               into accumulator: Accumulator) async {
        let encoded = await Task.detached(priority: .userInitiated) {
            ComposerPaste.encoded(fromImageData: data)
        }.value
        guard let encoded else {
            accumulator.failures.append(ErrorCopy.undecodableImage)
            return
        }
        append(encoded, millis: millis, into: accumulator)
    }

    private static func append(_ encoded: EncodedImage,
                               millis: Int64,
                               into accumulator: Accumulator) {
        let name = unique("pasted-image-\(millis).\(encoded.fileExtension)", in: accumulator)
        accumulator.uploads.append(ComposerUpload(filename: name,
                                                 mimeType: encoded.mimeType,
                                                 data: encoded.data))
    }

    /// A file the pasteboard handed over, already read.
    ///
    /// The bytes are read **inside** the provider's completion handler on purpose: a file
    /// representation is commonly a temporary copy the system owns, and it may not outlive the
    /// callback. Reading after the `await` was measured to fail for a copied `.pdf` in the simulator
    /// (t_9fe70579) while the same code passed for a `.png` — a lifetime race, not a type rule.
    private struct CopiedFile {
        var name: String
        var data: Data
    }

    private static func append(file: CopiedFile, into accumulator: Accumulator) {
        let name = unique(file.name.isEmpty ? "pasted-file" : file.name, in: accumulator)
        accumulator.uploads.append(ComposerUpload(filename: name,
                                                 mimeType: mimeType(forFilename: name),
                                                 data: file.data))
    }

    /// `name`, or `name-2`, `name-3` … when one paste already produced it. Upstream writes each pasted
    /// file to a temp path under `globallyUniqueString`; a timestamp alone repeats when two images
    /// arrive in the same millisecond.
    private static func unique(_ filename: String, in accumulator: Accumulator) -> String {
        guard accumulator.names.contains(filename) else {
            accumulator.names.insert(filename)
            return filename
        }
        let ns = filename as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            if !accumulator.names.contains(candidate) {
                accumulator.names.insert(candidate)
                return candidate
            }
            counter += 1
        }
    }

    private static func fileURLs(in pasteboard: ComposerPasteboard) -> [URL] {
        (pasteboard.urls ?? []).filter(\.isFileURL)
    }

    /// Is `string` the pasteboard's own representation of `url` rather than text the reader typed?
    /// A Finder copy publishes the path, and Safari's "copy link" publishes the URL — both mean the
    /// same file.
    private static func describes(_ string: String, _ url: URL) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == url.path || trimmed == url.absoluteString { return true }
        guard let parsed = URL(string: trimmed), parsed.isFileURL else { return false }
        return parsed.standardizedFileURL.path == url.standardizedFileURL.path
    }

    // MARK: Loading through a provider

    private static func loadData(from provider: NSItemProvider, type: String) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }

    /// Read a file the pasteboard is offering, or say why it could not be read.
    ///
    /// Two shapes are handled, because hosts differ: a file representation (whose URL may be a
    /// temporary copy — read inside the callback) and a `public.file-url` **data** representation,
    /// which is how some hosts publish the same thing.
    private static func loadFile(from provider: NSItemProvider,
                                 type: String) async -> (CopiedFile?, String?) {
        let handed: FileRead = await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if error != nil {
                    continuation.resume(returning: FileRead(
                        failure: ErrorCopy.unreadable(provider.suggestedName ?? "")))
                    return
                }
                guard let url = fileURL(from: item) else {
                    continuation.resume(returning: FileRead())
                    return
                }
                continuation.resume(returning: readFile(at: url))
            }
        }
        if let file = handed.copiedFile { return (file, nil) }
        if let failure = handed.failure { return (nil, failure) }

        // No file URL item: a data representation of the same type, or nothing at all.
        if let data = try? await loadData(from: provider, type: type) {
            if let url = fileURL(from: data) {
                let read = readFile(at: url)
                if let file = read.copiedFile { return (file, nil) }
            }
            return (CopiedFile(name: provider.suggestedName ?? "", data: data), nil)
        }
        return (nil, ErrorCopy.unreadable(provider.suggestedName ?? ""))
    }

    /// The result of touching a file URL: the bytes, or the reason there are none.
    private struct FileRead {
        var url: URL?
        var data: Data?
        var failure: String?

        var copiedFile: CopiedFile? {
            guard let url, let data else { return nil }
            return CopiedFile(name: url.lastPathComponent, data: data)
        }
    }

    /// Read a file URL now, while the system still vouches for it.
    private static func readFile(at url: URL) -> FileRead {
        // A file from the Files app or Finder is outside this app's container; a security-scoped URL
        // has to be opened for the read. `startAccessing…` answers false for a plain path, which needs
        // no release.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            return FileRead(url: url, data: try Data(contentsOf: url), failure: nil)
        } catch {
            return FileRead(failure: ErrorCopy.unreadable(url.lastPathComponent))
        }
    }

    private static func fileURL(from item: NSSecureCoding?) -> URL? {
        guard let item else { return nil }
        switch item {
        case let url as URL:
            return url
        case let url as NSURL:
            return url as URL
        case let data as Data:
            return fileURL(from: data)
        default:
            return nil
        }
    }

    private static func fileURL(from data: Data) -> URL? {
        if let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL { return url }
        // A host that publishes the URL as plain text under the file-URL identifier.
        if let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), url.isFileURL { return url }
        }
        return nil
    }
}
