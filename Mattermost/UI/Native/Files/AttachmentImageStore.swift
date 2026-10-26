// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 — `app/utils/image.ts` +
// `app/components/files/image_file.tsx` (`getFileUrl(file.id)` — the *original* bytes, not
// `/thumbnail`) and Gekidou `Cache/ImageCache*` (a file/memory cache in front of the endpoint).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §15; no
// upstream source copied. The bounds below are this client's own and are stated where chosen.
//
// **Why the original bytes and not `/files/{id}/thumbnail`** — measured on the pinned 9.11.19 server
// (`scripts/t38_file_probe.py`, `docs/t38-build-note.md` §2): a 240×160 PNG's thumbnail comes back
// 120×80 / 282 bytes. Drawn at the 300 pt bubble width that is a blurred preview, and the card's
// criterion is that the image "renders correctly". So an inline preview fetches the file and
// **downsamples it here** (`inlineMaxPixel`, exactly 2× the largest cell) — bounded on the client, at
// full quality, without a second server configuration.
//
// What this store is for: the post list asks it for every image on screen, the gallery asks it for one
// full-size image, and a media-heavy channel scrolls past hundreds of files. So it is a **bounded**
// cache, and every load is **cancellable**:
//
//  * previews — decoded `UIImage`s, capped by entry count *and* by estimated decoded bytes (the bitmap,
//    not the compressed payload: 16 previews at 600² RGBA is already 23 MB).
//  * originals — the bytes of one file, capped by entry count and by data bytes, for the gallery's
//    share/save path. The gallery never draws an original: it draws a downsampled copy
//    (`galleryMaxPixel`) so a 50-megapixel photograph costs a 2048² bitmap, not 200 MB.
//  * eviction is LRU by access (a hidden row is re-fetched on the way back; the server is the source of
//    truth and the bytes are cheap).
//  * a load that nobody is waiting for any more is cancelled. The row's `.task` is cancelled by
//    SwiftUI when the row leaves the tree, the store drops the waiter, and when the last waiter goes
//    the underlying request is cancelled and nothing is cached. This is the difference between "scroll
//    fast and move on" and "leave 300 requests and 300 images behind" — the property the T27 probe
//    measures, and which `docs/t38-build-note.md` §3.1 records for this card (4 posts × 10 images of
//    ~2 MB each in #t38-heavy, six scroll passes: RSS first third 449.5 → last third 375.4 MB, physical
//    footprint 144.0 → 151.7 MB, per-pass peaks 459.9 → 379.1 MB).
//
// Concurrency: `@MainActor`, like every other view model in this tree. The network call is a single
// `await` on an injected closure, so tests drive the whole state machine against a fake and never a
// socket.

import Foundation
import UIKit
import ImageIO

@MainActor
final class ChannelImageStore: ObservableObject {

    /// Preview budget: at most this many decoded previews…
    static let previewLimit = 40
    /// …and at most this many bytes of them (estimated decoded size). A 600² RGBA bitmap is 1.4 MB.
    static let previewByteLimit = 24 * 1024 * 1024
    /// Full-byte budget for the gallery's share/save path.
    static let originalLimit = 6
    static let originalByteLimit = 48 * 1024 * 1024
    /// Inline previews are decoded to this long edge: 2× the widest inline cell (300 pt), so they are
    /// crisp on a retina display and no larger than one cell can use.
    static let inlineMaxPixel = 600
    /// The gallery draws at this long edge: enough to zoom into, small enough to stay bounded.
    static let galleryMaxPixel = 2048
    /// How many downsampled gallery bitmaps are kept at once.
    static let galleryBitmapLimit = 3

    /// Loads one file's **original** bytes (`GET /files/{id}`).
    private let loadOriginal: (String) async throws -> Data

    /// key → decoded image. Keys are `preview/<fileID>` and `display/<fileID>`.
    private var images: [String: UIImage] = [:]
    /// key → cost in bytes (decoded estimate).
    private var imageCosts: [String: Int] = [:]
    /// key → original bytes. Key is `original/<fileID>`.
    private var originals: [String: Data] = [:]
    /// LRU order, oldest first, for both caches (keys are namespaced so one list is enough).
    private var order: [String] = []
    /// One in-flight load per key; several rows may be waiting on it.
    private var inFlight: [String: InFlight] = [:]

    /// A shared request with a waiter count. Reference type so awaiters can decrement it after the
    /// fact (`dropWaiter`) without holding a strong path back into the store.
    private final class InFlight {
        let task: Task<Any?, Never>
        var waiters: Int
        init(task: Task<Any?, Never>) { self.task = task; self.waiters = 1 }
    }

    init(loadOriginal: @escaping (String) async throws -> Data) {
        self.loadOriginal = loadOriginal
    }

    convenience init(service: ChannelServing) {
        self.init { fileID in
            try await service.fileData(fileID: fileID, preferThumbnail: false)
        }
    }

    // MARK: Diagnostics (tests, and the T27 probe's journal)

    /// How many decoded previews are held right now.
    var cachedPreviewCount: Int {
        images.keys.filter { $0.hasPrefix("preview/") }.count
    }
    /// Estimated decoded bytes held by the preview cache.
    var cachedPreviewBytes: Int {
        images.keys.filter { $0.hasPrefix("preview/") }.reduce(0) { $0 + (imageCosts[$1] ?? 0) }
    }
    /// How many original payloads are held right now.
    var cachedOriginalCount: Int { originals.count }
    var cachedOriginalBytes: Int { originals.values.reduce(0) { $0 + $1.count } }
    /// Loads currently in flight (any key). After a cancelled row this must return to zero.
    var inFlightCount: Int { inFlight.count }

    // MARK: Inline previews

    /// A preview for an inline cell. Returns nil when the bytes are unavailable or the caller went
    /// away — the row then draws its placeholder or its file row, never a broken image.
    func image(for attachment: PostAttachment) async -> UIImage? {
        guard attachment.isInlineImage else { return nil }
        let key = "preview/\(attachment.id)"
        if let cached = images[key] {
            touch(key)
            return cached
        }
        guard let data = await originalBytes(fileID: attachment.id) else { return nil }
        guard !Task.isCancelled else { return nil }
        guard let image = Self.downsample(data: data, maxPixel: Self.inlineMaxPixel) else { return nil }
        cache(image, key: key)
        return image
    }

    /// The cached preview, if it is already decoded. Lets a returning row draw instantly instead of
    /// flashing its placeholder.
    func cachedImage(for attachment: PostAttachment) -> UIImage? {
        let key = "preview/\(attachment.id)"
        guard let image = images[key] else { return nil }
        touch(key)
        return image
    }

    // MARK: Gallery

    /// The file's own bytes, for share and save. Capped: a gallery that pages through ten originals
    /// keeps at most `originalLimit` of them.
    ///
    /// Not restricted to images: the PDF and text readers need the same bytes, and both refuse to
    /// interpret anything (a `PDFDocument` and a `Text` view, never a web view).
    func originalData(for attachment: PostAttachment) async -> Data? {
        guard !attachment.isBlocked else { return nil }
        return await originalBytes(fileID: attachment.id)
    }

    /// What the gallery draws: a downsampled bitmap (`galleryMaxPixel` long edge) so the view's memory
    /// does not scale with the file's pixel count.
    func galleryImage(for attachment: PostAttachment) async -> UIImage? {
        let key = "display/\(attachment.id)"
        if let cached = images[key] {
            touch(key)
            return cached
        }
        guard let data = await originalBytes(fileID: attachment.id) else { return nil }
        guard !Task.isCancelled else { return nil }
        guard let image = Self.downsample(data: data, maxPixel: Self.galleryMaxPixel) else { return nil }
        cache(image, key: key)
        return image
    }

    // MARK: Lifecycle

    /// Drop everything and cancel every load (server switch, sign-out, pane teardown).
    func clear() {
        images.removeAll()
        imageCosts.removeAll()
        originals.removeAll()
        order.removeAll()
        for (_, load) in inFlight { load.task.cancel() }
        inFlight.removeAll()
    }

    /// Drop one file (a re-upload under the same id, or a decode the reader retried).
    func invalidate(fileID: String) {
        for prefix in ["preview/", "original/", "display/"] {
            let key = prefix + fileID
            images[key] = nil
            imageCosts[key] = nil
            originals[key] = nil
            order.removeAll { $0 == key }
        }
    }

    // MARK: Loads

    /// The original bytes for one file, shared by every caller asking for it at the same time.
    private func originalBytes(fileID: String) async -> Data? {
        let key = "original/\(fileID)"
        if let cached = originals[key] {
            touch(key)
            return cached
        }
        let load = inFlightLoad(for: key, fileID: fileID)
        let value = await awaitValue(load, key: key)
        guard let data = value as? Data else { return nil }
        originals[key] = data
        order.removeAll { $0 == key }
        order.append(key)
        trim()
        return data
    }

    private func inFlightLoad(for key: String, fileID: String) -> InFlight {
        if let existing = inFlight[key] {
            existing.waiters += 1
            return existing
        }
        // The load is owned by the store, not by the caller, so two rows drawing the same file share
        // one request. Its result is typed as `Any` because one dictionary serves both caches.
        let task: Task<Any?, Never> = Task { [loadOriginal] in
            do { return try await loadOriginal(fileID) } catch { return nil }
        }
        let load = InFlight(task: task)
        inFlight[key] = load
        return load
    }

    /// Wait for a shared load, and give up our place if the caller is cancelled.
    ///
    /// `Task.value` on an unstructured task is not itself cancelled when the *awaiting* task is, so the
    /// cancellation handler is what makes the load cancellable: the last waiter to leave cancels the
    /// request and forgets it. The result is discarded either way (`nil`), and nothing is cached.
    private func awaitValue(_ load: InFlight, key: String) async -> Any? {
        let value = await withTaskCancellationHandler {
            await load.task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.dropWaiter(load, key: key)
            }
        }
        finish(load, key: key)
        return value
    }

    private func dropWaiter(_ load: InFlight, key: String) {
        load.waiters -= 1
        guard load.waiters <= 0 else { return }
        load.task.cancel()
        if inFlight[key] === load { inFlight[key] = nil }
    }

    /// Called when a shared task finished (successfully or not): the entry is removed only if it is
    /// still this load.
    private func finish(_ load: InFlight, key: String) {
        if inFlight[key] === load { inFlight[key] = nil }
    }

    // MARK: Cache bookkeeping

    private func cache(_ image: UIImage, key: String) {
        images[key] = image
        imageCosts[key] = Self.cost(of: image)
        order.removeAll { $0 == key }
        order.append(key)
        trim()
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func trim() {
        func evict(_ key: String) {
            images[key] = nil
            imageCosts[key] = nil
            originals[key] = nil
        }
        func evictOldest(prefix: String) -> Bool {
            guard let index = order.firstIndex(where: { $0.hasPrefix(prefix) }) else { return false }
            evict(order.remove(at: index))
            return true
        }
        // Previews: count first, then bytes. Both loops keep the *newest* entries, which are the ones
        // on screen.
        while cachedPreviewCount > Self.previewLimit {
            guard evictOldest(prefix: "preview/") else { break }
        }
        while cachedPreviewBytes > Self.previewByteLimit {
            guard evictOldest(prefix: "preview/") else { break }
        }
        // Gallery bitmaps: one is the common case, a page of them is a few.
        while images.keys.filter({ $0.hasPrefix("display/") }).count > Self.galleryBitmapLimit {
            guard evictOldest(prefix: "display/") else { break }
        }
        // Originals: count then bytes.
        while originals.count > Self.originalLimit {
            guard evictOldest(prefix: "original/") else { break }
        }
        while cachedOriginalBytes > Self.originalByteLimit {
            guard evictOldest(prefix: "original/") else { break }
        }
    }

    // MARK: Decoding

    /// A decoded bitmap of at most `maxPixel` on its long edge.
    ///
    /// `kCGImageSourceShouldCacheImmediately` matters: it forces the decode here, on this call, instead
    /// of leaving a lazy decode that would happen during a scroll frame.
    nonisolated static func downsample(data: Data, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            // Not a format ImageIO recognises: a nil here just means the row draws its placeholder.
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// Estimated decoded cost of an image, in bytes.
    nonisolated static func cost(of image: UIImage) -> Int {
        if let cg = image.cgImage {
            return cg.bytesPerRow * cg.height
        }
        return Int(image.size.width * image.size.height * image.scale * image.scale * 4)
    }
}
