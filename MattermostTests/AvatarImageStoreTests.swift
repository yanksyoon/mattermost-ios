// Profile pictures: fetched once, shared, bounded, and honest about a miss.

import UIKit
import XCTest
@testable import Mattermost

final class AvatarImageStoreTests: XCTestCase {
    /// A 1×1 image is enough: the store's job is identity, not pixels.
    private func thumbnail() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    @MainActor
    func testAPictureIsFetchedOnceAndSharedByEveryAvatarOfThatUser() async {
        var requests: [String] = []
        let store = AvatarImageStore { userID in
            requests.append(userID)
            return self.thumbnail().pngData()!
        }

        let first = await store.image(for: "user-1")
        let second = await store.image(for: "user-1")

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(requests, ["user-1"], "a second avatar of the same author must read the cache")
    }

    @MainActor
    func testAUserWithoutAPictureIsAskedForOnceAndThenLeftAlone() async {
        var requests = 0
        let store = AvatarImageStore { _ in
            requests += 1
            throw MMError.notFound
        }

        let first = await store.image(for: "user-2")
        let second = await store.image(for: "user-2")

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(requests, 1, "a known miss must not be re-requested on every redraw")
    }

    @MainActor
    func testFailuresCanBeForgotten() async {
        var attempt = 0
        let store = AvatarImageStore { _ in
            attempt += 1
            throw MMError.notFound
        }
        _ = await store.image(for: "user-3")
        store.clearFailures()
        _ = await store.image(for: "user-3")

        XCTAssertEqual(attempt, 2, "a new session may have the picture the old one did not")
    }

    @MainActor
    func testTheCacheIsBounded() {
        let store = AvatarImageStore { _ in self.thumbnail().pngData()! }
        for index in 0..<(AvatarImageStore.limit + 5) {
            store.store(thumbnail(), for: "user-\(index)")
        }

        XCTAssertEqual(store.cachedCount, AvatarImageStore.limit)
    }
}
