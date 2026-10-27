// T45 — profile pictures: fetched through the session, fetched once, bounded, and honest about the
// two different ways an avatar can be absent.
//
// The report behind this card was "avatars render blank/initials everywhere". The visible half is
// the feature (`PostAvatarView` had no request at all); the half that would keep it broken is the
// failure policy, so that is what most of this file pins:
//
//  * a `404` (the server's "this account has no picture") is remembered — a 200-row list must not
//    fire 200 doomed requests per scroll;
//  * a transient failure (offline, timeout, 5xx) is **not** remembered as permanent: it is retried
//    after `retryWindow`, because "no network for a second" is not "no picture ever";
//  * the request itself goes through `APIClient` (bearer token from the vault, `/api/v4` path) and
//    never a bare URL — the webview's cookie is not visible to the native transport, which is
//    exactly why an `AsyncImage` would draw nothing here.

import UIKit
import XCTest
@testable import Mattermost

// MARK: - The store

@MainActor
final class AvatarImageStoreTests: XCTestCase {

    private var directory: URL!
    private var disk: AvatarDiskCache!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("avatar-store-tests-\(UUID().uuidString)", isDirectory: true)
        disk = AvatarDiskCache(directory: directory)
    }

    override func tearDown() async throws {
        await disk.removeAll()
        disk = nil
        directory = nil
    }

    // MARK: Fixtures

    /// A tiny PNG: the store's job is identity and policy, not pixels.
    private func png() -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format)
        return renderer.image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.pngData() ?? Data()
    }

    /// A hand-moved clock, so the retry window and the disk TTL are tested without waiting.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_793_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    // MARK: - One request per face

    func testOneRequestServesEveryAvatarOfTheSameAuthor() async {
        var requests: [String] = []
        let store = AvatarImageStore(load: { userID in
            requests.append(userID)
            return self.png()
        })

        let first = await store.image(for: "user-1")
        let second = await store.image(for: "user-1")

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(requests, ["user-1"], "the second avatar must read the cache, not the server")
        XCTAssertNotNil(store.cached("user-1"), "a returning row draws without awaiting the network")
        XCTAssertEqual(store.cachedCount, 1)
        XCTAssertEqual(store.inFlightCount, 0, "the shared request must be released when it finishes")
    }

    func testConcurrentAvatarsOfTheSameAuthorShareOneRequest() async {
        var requests = 0
        let store = AvatarImageStore(load: { _ in
            requests += 1
            return self.png()
        })

        async let a = store.image(for: "user-1")
        async let b = store.image(for: "user-1")
        async let c = store.image(for: "user-1")
        let all = await (a, b, c)

        XCTAssertNotNil(all.0)
        XCTAssertNotNil(all.1)
        XCTAssertNotNil(all.2)
        XCTAssertEqual(requests, 1, "three rows drawing one author cost one request")
    }

    // MARK: - The two kinds of absence

    func testAnAccountWithoutAPictureIsAskedOnceAndThenLeftAlone() async {
        var requests = 0
        let store = AvatarImageStore(load: { _ in
            requests += 1
            throw MMError.notFound
        })

        let first = await store.image(for: "user-2")
        let second = await store.image(for: "user-2")
        let third = await store.image(for: "user-2")

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertNil(third)
        XCTAssertEqual(requests, 1, "a known 404 must not be re-requested on every redraw")
        XCTAssertEqual(store.missedCount, 1)
    }

    func testATransientFailureIsRetriedAfterTheWindowInsteadOfBeingRememberedForever() async {
        let clock = Clock()
        var requests = 0
        var fail = true
        let store = AvatarImageStore(load: { _ in
            requests += 1
            if fail { throw MMError.offline }
            return self.png()
        }, retryWindow: 30, now: { clock.now })

        let first = await store.image(for: "user-3")
        XCTAssertNil(first, "offline: draw the initials")

        let second = await store.image(for: "user-3")
        XCTAssertNil(second)
        XCTAssertEqual(requests, 1, "inside the window the store does not hammer a failing server")

        fail = false
        clock.advance(31)
        let third = await store.image(for: "user-3")

        XCTAssertNotNil(third, "a transient failure must not be a permanent miss")
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(store.missedCount, 0)
    }

    func testANewSessionCanAskAboutAPictureTheOldOneDidNotFind() async {
        var requests = 0
        let store = AvatarImageStore(load: { _ in
            requests += 1
            throw MMError.notFound
        })

        _ = await store.image(for: "user-4")
        store.clearFailures()
        _ = await store.image(for: "user-4")

        XCTAssertEqual(requests, 2, "the miss was true of that session, not of the account")
    }

    func testTheMemoryCacheIsBounded() {
        let store = AvatarImageStore(load: { _ in self.png() })
        for index in 0..<(AvatarImageStore.memoryLimit + 5) {
            store.store(UIImage(), for: "user-\(index)")
        }

        XCTAssertEqual(store.cachedCount, AvatarImageStore.memoryLimit)
        XCTAssertNil(store.cached("user-0"), "the oldest face is the one evicted")
        XCTAssertNotNil(store.cached("user-\(AvatarImageStore.memoryLimit + 4)"))
    }

    // MARK: - The disk cache

    func testAPictureOnDiskIsDrawnByANewStoreWithoutARequest() async {
        var requests = 0
        let writer = AvatarImageStore(load: { _ in
            requests += 1
            return self.png()
        }, disk: disk)
        _ = await writer.image(for: "user-5")
        XCTAssertEqual(requests, 1)

        // A relaunch: fresh memory, same caches directory.
        let relaunched = AvatarImageStore(load: { _ in
            requests += 1
            return self.png()
        }, disk: disk)
        let image = await relaunched.image(for: "user-5")

        XCTAssertNotNil(image)
        XCTAssertEqual(requests, 1, "the face survived the relaunch, so nothing was requested")
        let onDisk = await disk.count()
        XCTAssertEqual(onDisk, 1)
    }

    func testAStalePictureIsRefreshedAndStillDrawnWhenTheRefreshFails() async {
        let clock = Clock()
        let writer = AvatarImageStore(load: { _ in self.png() }, disk: disk, now: { clock.now })
        _ = await writer.image(for: "user-6")

        clock.advance(AvatarImageStore.diskTTL + 1)
        var requests = 0
        let reader = AvatarImageStore(load: { _ in
            requests += 1
            throw MMError.offline
        }, disk: disk, now: { clock.now })
        let image = await reader.image(for: "user-6")

        XCTAssertEqual(requests, 1, "past the TTL the store revalidates")
        XCTAssertNotNil(image, "a failed refresh still draws last week's face, not the initials")
    }

    func testAPermanentMissDropsThePictureItHadOnDisk() async {
        let clock = Clock()
        let writer = AvatarImageStore(load: { _ in self.png() }, disk: disk, now: { clock.now })
        _ = await writer.image(for: "user-7")
        let written = await disk.count()
        XCTAssertEqual(written, 1)

        clock.advance(AvatarImageStore.diskTTL + 1)
        let reader = AvatarImageStore(load: { _ in throw MMError.notFound },
                                      disk: disk, now: { clock.now })
        let image = await reader.image(for: "user-7")

        XCTAssertNil(image, "the account has no picture any more: the initials are the truth")
        let remaining = await disk.count()
        XCTAssertEqual(remaining, 0, "and the old bytes must not come back")
    }

    func testTheDiskCacheIsBoundedByBytes() async {
        let tiny = AvatarDiskCache(directory: directory.appendingPathComponent("tiny"), byteLimit: 12)
        for index in 0..<5 {
            await tiny.store(Data(repeating: 0xAB, count: 10), for: "user-\(index)", at: Date())
        }
        let held = await tiny.count()
        XCTAssertLessThanOrEqual(held, 1, "50 bytes into a 12-byte budget must be trimmed")
        await tiny.removeAll()
    }

    func testA200ThatIsNotAnImageIsAFailedFetchAndIsRetried() async {
        let clock = Clock()
        var requests = 0
        let store = AvatarImageStore(load: { _ in
            requests += 1
            return Data("<html>not an image</html>".utf8)
        }, retryWindow: 30, now: { clock.now })

        let garbage = await store.image(for: "user-8")
        XCTAssertNil(garbage)
        _ = await store.image(for: "user-8")
        XCTAssertEqual(requests, 1, "garbage is inside the retry window too")

        clock.advance(31)
        _ = await store.image(for: "user-8")
        XCTAssertEqual(requests, 2, "but it is not a permanent miss")
    }
}

// MARK: - The request

/// What only a request can get wrong: the path, the bearer token, and how a 404 surfaces.
final class AvatarImageAPITests: XCTestCase {

    private let userID = "user0000000000000000000001"

    private func client(_ transport: APITransport) throws -> APIClient {
        try APIClient(serverURL: URL(string: "https://mm.example")!,
                      transport: transport,
                      retryPolicy: .none,
                      tokenProvider: { "tok" })
    }

    func testTheImageRequestCarriesTheSessionTokenToTheImageEndpoint() async throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let transport = FakeAPITransport(stubs: [
            .ok(APIResponse(statusCode: 200, headers: ["Content-Type": "image/png"], body: bytes)),
        ])
        let client = try client(transport)

        let received = try await client.userImage(userID: userID)

        XCTAssertEqual(received, bytes)
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url.path, "/api/v4/users/\(userID)/image")
        XCTAssertEqual(request.headers["Authorization"], "Bearer tok",
                       "the avatar is fetched with the vault's token, never a cookie")
    }

    func testAnAccountWithoutAPictureAnswers404AndThatIsNotFound() async throws {
        // The store's permanent-miss classification depends on exactly this mapping.
        let transport = FakeAPITransport(stubs: [
            .ok(.json(["id": "api.context.404.app_error", "message": "not found"], status: 404)),
        ])
        let client = try client(transport)

        do {
            _ = try await client.userImage(userID: userID)
            XCTFail("a 404 must throw")
        } catch let error as MMError {
            XCTAssertEqual(error, .notFound)
        }
    }
}
