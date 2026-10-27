// Profile pictures for the native surfaces.
//
// Avatars were initials-only: `PostAvatarView` drew a coloured circle and the author's initials and
// nothing else — there was no request, no cache, and no place a picture could come from. On a server
// where everyone has uploaded one, that reads as "avatars are broken" rather than "avatars are not
// implemented", and the initials are indistinguishable from a user who really has no picture.
//
// So: one small store per pane, keyed by user id, fetching `GET /users/{id}/image` through the same
// authenticated client as every other read (the bearer token from the vault — never the webview's
// cookie, which the native transport cannot see). The circle-and-initials stays as the fallback while
// a picture is loading and for a user who has none, which is exactly what it was before.

import SwiftUI

/// Decoded profile pictures, one entry per user id.
///
/// `@MainActor` because it is read from views and written after an `await` back on the main actor, and
/// `ObservableObject` so a row redraws when its picture lands.
@MainActor
final class AvatarImageStore: ObservableObject {
    /// How many pictures are kept at once. 36 pt avatars are a few KB decoded; 200 of them is a
    /// bounded cache that survives a long scroll without holding a whole team's faces forever.
    static let limit = 200

    /// One request for one user's bytes.
    private let load: (String) async throws -> Data

    /// user id → decoded picture.
    @Published private var pictures: [String: UIImage] = [:]
    /// Insertion order, oldest first, for eviction.
    private var order: [String] = []
    /// Users the server has no picture for (or whose fetch failed). A miss is remembered so a list of
    /// 200 rows does not issue 200 doomed requests on every redraw; `clearFailures()` forgets them
    /// when the reason might have changed (a reconnect, a new session).
    private var misses: Set<String> = []
    /// One in-flight request per user: every avatar of the same author waits on the same task.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init(load: @escaping (String) async throws -> Data) {
        self.load = load
    }

    convenience init(service: ChannelServing) {
        self.init { userID in try await service.userImage(userID: userID) }
    }

    /// The picture for `userID`, or `nil` while it is loading or when there is none.
    func image(for userID: String) async -> UIImage? {
        guard !userID.isEmpty else { return nil }
        if let hit = pictures[userID] { return hit }
        if misses.contains(userID) { return nil }
        if let task = inFlight[userID] { return await task.value }

        let task = Task<UIImage?, Never> { [load] in
            guard let data = try? await load(userID), let image = UIImage(data: data) else {
                return nil
            }
            return image
        }
        inFlight[userID] = task
        let image = await task.value
        inFlight[userID] = nil

        if let image {
            store(image, for: userID)
        } else {
            misses.insert(userID)
        }
        return image
    }

    /// A picture already in hand (used by a caller that has the bytes for another reason).
    func store(_ image: UIImage, for userID: String) {
        pictures[userID] = image
        order.removeAll { $0 == userID }
        order.append(userID)
        evictIfNeeded()
    }

    /// Forget the remembered misses, e.g. after signing in again.
    func clearFailures() {
        misses.removeAll()
    }

    /// Diagnostics (tests): how many pictures are held.
    var cachedCount: Int { pictures.count }

    private func evictIfNeeded() {
        while order.count > Self.limit, let oldest = order.first {
            order.removeFirst()
            pictures[oldest] = nil
        }
    }
}

/// The pane's avatar store, injected once so a row does not have to thread it through every initialiser.
private struct AvatarImageStoreKey: EnvironmentKey {
    static let defaultValue: AvatarImageStore? = nil
}

extension EnvironmentValues {
    var avatarImages: AvatarImageStore? {
        get { self[AvatarImageStoreKey.self] }
        set { self[AvatarImageStoreKey.self] = newValue }
    }
}
