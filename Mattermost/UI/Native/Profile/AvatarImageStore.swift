// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 — `app/utils/image.ts`
// (`getAvatarUri` builds `/users/{id}/image?` from the *session's* client, and the resulting bytes go
// through the Gekidou image cache), `app/components/user_avatar` (initials while loading and for an
// account with no picture). Licence: Apache-2.0 — behaviour ported with attribution per
// docs/THIRD_PARTY_NOTICES.md §18; no upstream source copied. The cache bounds, the disk TTL and the
// failure policy below are this client's own and are stated where chosen.
//
// **Why a store and not `AsyncImage`.** `GET /users/{id}/image` sits behind the session: the request
// has to carry the bearer token from the vault, and it has to go through the same `APIClient` as
// every other read (same base URL, same 401 funnel, same certificate decision). `AsyncImage` can
// only send a bare URL, and the webview's `MMAUTHTOKEN` cookie is invisible to the native transport
// — so an `AsyncImage` is exactly the blank avatar this card is about.
//
// **Two failures, two policies.** This is the part the report is really about:
//  * `404` is the server saying *this account has no picture*. That is a fact for the whole session:
//    remembering it is what stops a 200-row list from firing 200 doomed requests on every scroll.
//  * offline / timeout / 5xx means *not now*. Remembering that forever is how one dropped request
//    becomes faces that never come back until relaunch, so it is remembered only for `retryWindow`
//    and the next attempt after that window is a real one.
// A stale picture already on disk is drawn while a refresh fails: last week's face beats initials.

import SwiftUI
import UIKit

/// The on-disk half of the avatar cache: one file per account, under `Caches/`.
///
/// A cache directory on purpose — the system may purge it under pressure and the cost of a purge is
/// one request per visible face, never a wrong answer.
actor AvatarDiskCache {

    /// How many bytes of faces are kept per server. 36 pt avatars are a few KB each, so this is a
    /// few thousand accounts; the bound exists so a purge is never the only bound.
    static let byteLimit = 24 * 1024 * 1024

    private let directory: URL
    private let byteLimit: Int
    private let fileManager = FileManager.default

    init(directory: URL, byteLimit: Int = AvatarDiskCache.byteLimit) {
        self.directory = directory
        self.byteLimit = byteLimit
    }

    /// One directory per server: the same user id on two servers is two accounts and two pictures,
    /// and signing out of one must not leak its faces into the other's cache.
    static func defaultDirectory(for serverID: UUID) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return caches
            .appendingPathComponent("profile-images", isDirectory: true)
            .appendingPathComponent(serverID.uuidString, isDirectory: true)
    }

    /// The bytes for one account and when they were written; `nil` when this account has no entry.
    func entry(for key: String) -> (data: Data, modified: Date)? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let modified = attributes?[.modificationDate] as? Date ?? .distantPast
        return (data, modified)
    }

    /// Write one account's bytes, stamped with the store's clock, then trim.
    ///
    /// The timestamp is passed in rather than taken from the file system so the store's notion of
    /// "when did we write this" is the same clock that decides staleness (and so a test can move it).
    /// A cache that cannot write is not something the reader has to see: the memory cache and the
    /// initials still work.
    func store(_ data: Data, for key: String, at date: Date) {
        guard !data.isEmpty else { return }
        let url = fileURL(for: key)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            trim()
        } catch {
            return
        }
    }

    func remove(_ key: String) {
        try? fileManager.removeItem(at: fileURL(for: key))
    }

    func removeAll() {
        try? fileManager.removeItem(at: directory)
    }

    /// How many files are held (tests, and the diagnostics line).
    func count() -> Int {
        (try? fileManager.contentsOfDirectory(atPath: directory.path).count) ?? 0
    }

    /// A file name that cannot escape the directory. Account ids are hex-ish in practice, so this
    /// normally changes nothing; it is here so a hostile id cannot become a path.
    private func fileURL(for key: String) -> URL {
        var safe = key.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character
                : "_"
        }
        if safe.isEmpty { safe = Array("unknown") }
        return directory.appendingPathComponent(String(safe)).appendingPathExtension("img")
    }

    /// Keep the newest `byteLimit` bytes, oldest first to go.
    private func trim() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? fileManager.contentsOfDirectory(at: directory,
                                                             includingPropertiesForKeys: keys)
        else { return }

        var files: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let size = values?.fileSize ?? 0
            total += size
            files.append((url, size, values?.contentModificationDate ?? .distantPast))
        }
        guard total > byteLimit else { return }
        for file in files.sorted(by: { $0.date < $1.date }) {
            guard total > byteLimit else { break }
            try? fileManager.removeItem(at: file.url)
            total -= file.size
        }
    }
}

/// Decoded profile pictures, one entry per account, fetched through the session's client.
///
/// `@MainActor` because it is read from views and written after an `await` back on the main actor.
@MainActor
final class AvatarImageStore: ObservableObject {

    /// How many decoded pictures are kept at once. A 36 pt face is a few KB decoded; 200 of them
    /// survives a long scroll without holding a whole team's faces forever.
    static let memoryLimit = 200
    /// A picture on disk is drawn without a request for this long. Faces change rarely, and the
    /// endpoint is cheap; a week is a bound, not a promise.
    static let diskTTL: TimeInterval = 7 * 24 * 60 * 60
    /// How long a *transient* failure keeps the next attempt away. Long enough that scrolling a list
    /// does not hammer a server that is already struggling, short enough that a recovery is noticed.
    static let retryWindow: TimeInterval = 30

    /// One request for one account's bytes (`GET /users/{id}/image`).
    private let load: (String) async throws -> Data
    private let disk: AvatarDiskCache?
    private let ttl: TimeInterval
    private let retryWindow: TimeInterval
    private let now: () -> Date

    /// user id → decoded picture.
    @Published private var pictures: [String: UIImage] = [:]
    /// Insertion order, oldest first, for eviction.
    private var order: [String] = []
    /// Accounts the server says have **no** picture. Permanent for the session, by design.
    private var misses: Set<String> = []
    /// Accounts whose last fetch failed for a reason that may pass (`now` is when to try again).
    private var retryAfter: [String: Date] = [:]
    /// One in-flight request per account: every avatar of the same author waits on the same task.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init(load: @escaping (String) async throws -> Data,
         disk: AvatarDiskCache? = nil,
         ttl: TimeInterval = AvatarImageStore.diskTTL,
         retryWindow: TimeInterval = AvatarImageStore.retryWindow,
         now: @escaping () -> Date = Date.init) {
        self.load = load
        self.disk = disk
        self.ttl = ttl
        self.retryWindow = retryWindow
        self.now = now
    }

    convenience init(service: ChannelServing, disk: AvatarDiskCache? = nil) {
        self.init(load: { userID in try await service.userImage(userID: userID) }, disk: disk)
    }

    // MARK: - Reading

    /// The picture for `userID`, or `nil` while it is loading, when the account has none, or when
    /// the last attempt failed and the retry window has not passed. Callers draw their initials on
    /// `nil` — that is the whole contract.
    func image(for userID: String) async -> UIImage? {
        guard !userID.isEmpty else { return nil }
        if let hit = pictures[userID] {
            touch(userID)
            return hit
        }
        if misses.contains(userID) { return nil }
        if let until = retryAfter[userID] {
            guard now() >= until else { return nil }
            retryAfter[userID] = nil
        }
        if let task = inFlight[userID] { return await task.value }

        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.loadImage(userID)
        }
        inFlight[userID] = task
        let image = await task.value
        inFlight[userID] = nil
        return image
    }

    /// A picture already decoded in this session, without touching the network or the disk. Lets a
    /// returning row draw on its first frame instead of flashing its initials.
    func cached(_ userID: String) -> UIImage? {
        guard let image = pictures[userID] else { return nil }
        touch(userID)
        return image
    }

    /// A picture already in hand for another reason (a profile screen that fetched the bytes).
    func store(_ image: UIImage, for userID: String) {
        remember(image, for: userID)
    }

    /// Forget the remembered failures, e.g. after signing in again or a reconnect.
    ///
    /// The permanent misses go too: "this account has no picture" was true of that session, and a
    /// new one is entitled to ask again.
    func clearFailures() {
        misses.removeAll()
        retryAfter.removeAll()
    }

    // MARK: - Diagnostics

    var cachedCount: Int { pictures.count }
    var inFlightCount: Int { inFlight.count }
    var missedCount: Int { misses.count }

    // MARK: - Loading

    /// Memory, then disk, then the network. Main-actor, so the state machine needs no lock.
    private func loadImage(_ userID: String) async -> UIImage? {
        var stale: (image: UIImage, data: Data)?

        if let disk, let entry = await disk.entry(for: userID), let image = UIImage(data: entry.data) {
            if now().timeIntervalSince(entry.modified) < ttl {
                remember(image, for: userID)
                return image
            }
            // Past the TTL: keep it as the answer if the refresh fails, do not draw it yet.
            stale = (image, entry.data)
        }

        do {
            let data = try await load(userID)
            guard let image = UIImage(data: data) else {
                // A 200 that is not an image (a proxy's HTML page, a truncated body) is a fetch that
                // failed, not an account without a picture.
                noteTransientFailure(userID)
                return stale?.image
            }
            remember(image, for: userID)
            misses.remove(userID)
            await disk?.store(data, for: userID, at: now())
            return image
        } catch {
            if Self.isPermanentMiss(error) {
                // The server has no picture for this account. Remember it, drop any old bytes, and
                // draw the initials — this is an answer, not a failure.
                misses.insert(userID)
                retryAfter[userID] = nil
                await disk?.remove(userID)
                return nil
            }
            noteTransientFailure(userID)
            if let stale {
                // Give the bytes we already have a fresh lease so the next scroll does not ask
                // again straight away; the picture stays truthful until the retry succeeds.
                await disk?.store(stale.data, for: userID, at: now())
                return stale.image
            }
            return nil
        }
    }

    /// `404` is the server's "no picture"; a rejected request is the same fact for this session.
    /// Everything else (offline, timeout, 5xx, transport) is "not now".
    private static func isPermanentMiss(_ error: Error) -> Bool {
        guard let error = error as? MMError else { return false }
        switch error {
        case .notFound, .forbidden:
            return true
        case .client(let status, _):
            return status == 404
        default:
            return false
        }
    }

    private func noteTransientFailure(_ userID: String) {
        retryAfter[userID] = now().addingTimeInterval(retryWindow)
    }

    // MARK: - Cache bookkeeping

    private func remember(_ image: UIImage, for userID: String) {
        pictures[userID] = image
        misses.remove(userID)
        retryAfter[userID] = nil
        touch(userID)
        evictIfNeeded()
    }

    private func touch(_ userID: String) {
        order.removeAll { $0 == userID }
        order.append(userID)
    }

    private func evictIfNeeded() {
        while order.count > Self.memoryLimit, let oldest = order.first {
            order.removeFirst()
            pictures[oldest] = nil
        }
    }
}

/// The server's picture for one account, drawn **over** whatever the caller draws underneath it
/// (the initials). With no store in the environment, no picture, or a fetch still in flight, this is
/// an empty view — every caller keeps exactly the fallback it had before.
struct AvatarPicture: View {
    let userID: String
    var size: CGFloat = 36

    @Environment(\.avatarImages) private var avatars
    @State private var picture: UIImage?

    var body: some View {
        ZStack {
            // A transparent, sized placeholder on purpose: the picture is drawn *after* the fetch, so
            // before it lands there is nothing to draw — and a body that reduces to `EmptyView` has no
            // lifetime, so the `.task` below would never run and the picture would never arrive. (That
            // chicken-and-egg is exactly the shape of the bug this card is about.)
            Color.clear
            if let picture {
                Image(uiImage: picture)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onChange(of: userID) { _, _ in
            // A recycled row keeps its `@State`: drop the previous author's face before the next
            // fetch, never draw the wrong person while it loads.
            picture = nil
        }
        .task(id: userID) {
            guard let avatars, !userID.isEmpty else { return }
            if let cached = avatars.cached(userID) {
                picture = cached
                return
            }
            picture = await avatars.image(for: userID)
        }
    }
}

/// The pane's avatar store, injected once so a row does not have to thread it through every
/// initialiser. `nil` by default: previews and tests keep the initials, and a surface that has no
/// session cannot invent a picture.
private struct AvatarImageStoreKey: EnvironmentKey {
    static let defaultValue: AvatarImageStore? = nil
}

extension EnvironmentValues {
    var avatarImages: AvatarImageStore? {
        get { self[AvatarImageStoreKey.self] }
        set { self[AvatarImageStoreKey.self] = newValue }
    }
}
