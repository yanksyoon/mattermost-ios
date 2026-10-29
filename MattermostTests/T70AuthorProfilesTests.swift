// Card t_70b41028 — authors rendered as "Unknown user" because one bad id failed the whole batch.
//
// The report came from an installed build: usernames in a channel read "Unknown user". The rule that
// draws a name (`PostListDerivation.author(for:users:)`) reads the post's `props.username` and then
// the literal "Unknown user" when the profile map has no entry, so the rows were *honest* — the map
// was empty. The view model filled it with five lines that had three defects (empty ids in the body,
// one unbounded request, and a swallowed error), each of which could lose the entire batch:
//
//   let missing = userIDs.filter { users[$0] == nil }
//   let loaded = (try? await service.users(ids: missing)) ?? []
//
// These tests are written against the *contract* rather than against the new code: the fake refuses
// any request whose body carries an empty id (the strict shape of `POST /users/ids`; the pinned
// 9.x server answers `200 []` instead — measured, `docs/t_70b41028-author-profiles.md` §3 — so a
// body with `""` is a wrong request even where it is not yet a fatal one), and can refuse a whole
// request on demand (the timeout/401/500 the old `try?` swallowed, which is the failure that really
// empties the map on a live server).

import XCTest
@testable import Mattermost

@MainActor
final class T70AuthorProfilesTests: XCTestCase {

    // MARK: - Fake

    /// A `ChannelServing` that answers like the pinned server: a request carrying `""` is refused,
    /// and an id the server has no account for is simply absent from the answer.
    @MainActor
    final class FakeService: ChannelServing {
        var pageSize = 60
        var pages: [MMPostList] = []
        var usersByID: [String: MMUser] = [:]
        /// When set, every profile request fails with this error (a 400/401/timeout, in the tests).
        var userError: Error?

        private(set) var userRequests: [[String]] = []
        private var served = 0

        func channel(id: String) async throws -> MMChannel { throw MMError.notFound }

        func posts(channelID: String, before: String?, perPage: Int) async throws -> MMPostList {
            let slot = min(served, max(0, pages.count - 1))
            served += 1
            return pages.isEmpty ? MMPostList(order: [], posts: [:]) : pages[slot]
        }

        func users(ids: [String]) async throws -> [MMUser] {
            userRequests.append(ids)
            // Mattermost: `POST /users/ids` with an empty element is a 400 for the whole body.
            if ids.contains("") {
                throw MMError.client(status: 400, message: "Invalid or missing user_id")
            }
            if let userError { throw userError }
            return ids.compactMap { usersByID[$0] }
        }

        func fileData(fileID: String, preferThumbnail: Bool) async throws -> Data {
            throw MMError.notFound
        }
    }

    // MARK: - Fixtures

    private let channelID = "chan-1"

    private func post(_ id: String, at millis: Int64, user: String,
                      message: String? = nil, type: String = "", props: JSONValue? = nil) -> MMPost {
        MMPost(id: id, createAt: millis, userId: user, channelId: channelID,
               message: message ?? "message \(id)", type: type, props: props)
    }

    private func usernameProps(_ username: String) -> JSONValue {
        // The shape the server sends for a system message: `props` is an object of strings.
        (try? JSONDecoder().decode(JSONValue.self,
                                   from: Data("{\"username\":\"\(username)\"}".utf8))) ?? .null
    }

    private func list(_ posts: [MMPost]) -> MMPostList {
        MMPostList(order: posts.map(\.id),
                   posts: Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) }))
    }

    private func rows(_ model: ChannelViewModel) -> [PostRowModel] {
        model.items.compactMap { item in
            if case .post(let row) = item { return row }
            return nil
        }
    }

    private func row(_ model: ChannelViewModel, for postID: String) -> PostRowModel? {
        rows(model).first { $0.post.id == postID }
    }

    private func model(_ service: ChannelServing,
                       profiles: UserProfileCache? = nil) -> ChannelViewModel {
        ChannelViewModel(channelID: channelID,
                         channelName: "Town Square",
                         service: service,
                         myUserID: "me",
                         profiles: profiles,
                         now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    // MARK: - 1. The regression: one empty id must not cost the page its authors

    /// The card's regression test. A page carries a system post whose `user_id` is `""` (join/leave
    /// messages on the pinned server look exactly like this) and two ordinary authors. Before the
    /// repair the empty id went into the body, the server refused the request, `try?` swallowed it,
    /// and **both** named authors drew "Unknown user" — the reported symptom, in one page.
    func testAPageWithAnEmptyUserIdStillNamesEveryOtherAuthor() async {
        let service = FakeService()
        service.usersByID = ["u1": MMUser(id: "u1", username: "ada", firstName: "Ada", lastName: "Lovelace"),
                             "u2": MMUser(id: "u2", username: "grace", firstName: "Grace", lastName: "Hopper")]
        service.pages = [list([
            post("p3", at: 3_000, user: "u2"),
            post("p2", at: 2_000, user: "", message: "ada joined the channel.",
                 type: "system_join_channel", props: usernameProps("ada")),
            post("p1", at: 1_000, user: "u1"),
        ])]
        let model = model(service)

        await model.load(ifNeeded: false)

        // The empty id never reached a request body…
        XCTAssertEqual(service.userRequests.count, 1)
        XCTAssertFalse(service.userRequests.joined().contains(""))
        // …so both authors are named from their profiles, not from the fallback.
        XCTAssertEqual(row(model, for: "p1")?.author.displayName, "Ada Lovelace")
        XCTAssertEqual(row(model, for: "p3")?.author.displayName, "Grace Hopper")
        XCTAssertFalse(rows(model).contains { $0.author.displayName == "Unknown user" })
        XCTAssertEqual(model.lastProfileLoad?.requested, 2)
        XCTAssertEqual(model.lastProfileLoad?.resolved, 2)
    }

    /// The same page as the *old* code saw it: this is the server's own refusal, so the test above is
    /// only meaningful while this stays true. (A request with `""` in it fails — the fake threw it
    /// away, and with `try?` every author on the page would have been left unnamed.)
    func testAServerRefusesAProfileRequestThatCarriesAnEmptyID() async {
        let service = FakeService()
        do {
            _ = try await service.users(ids: ["u1", ""])
            XCTFail("the pinned server rejects an empty user id in the body")
        } catch let error as MMError {
            XCTAssertEqual(error, .client(status: 400, message: "Invalid or missing user_id"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - 2. A refused request leaves what the client already knows

    /// A 400 on the profile batch must not turn a name the client already holds into "Unknown user".
    /// The author in the store resolves from `UserProfileCache` before any request is made; the author
    /// the failed chunk would have named keeps the honest `props` username — never the literal
    /// "Unknown user" for somebody the page can still name.
    func testA400LeavesKnownAuthorsNamedAndTheRestOnTheirPropsUsername() async {
        let cache = UserProfileCache()
        cache.remember([MMUser(id: "u1", username: "ada", firstName: "Ada", lastName: "Lovelace")])

        let service = FakeService()
        service.usersByID = ["u2": MMUser(id: "u2", username: "grace")]
        service.userError = MMError.client(status: 400, message: "Invalid or missing user_id")
        service.pages = [list([
            post("p2", at: 2_000, user: "u2", message: "hello", props: usernameProps("grace")),
            post("p1", at: 1_000, user: "u1", message: "hey"),
        ])]
        let model = model(service, profiles: cache)

        await model.load(ifNeeded: false)

        XCTAssertEqual(row(model, for: "p1")?.author.displayName, "Ada Lovelace")
        XCTAssertEqual(row(model, for: "p2")?.author.displayName, "grace")
        XCTAssertFalse(rows(model).contains { $0.author.displayName == "Unknown user" })
        // The failure is reported, not swallowed.
        XCTAssertEqual(model.lastProfileLoad?.cached, 1)
        XCTAssertEqual(model.lastProfileLoad?.sent, 1)
        XCTAssertEqual(model.lastProfileLoad?.failed, 1)
        XCTAssertNotNil(model.lastProfileLoad?.error)
        XCTAssertTrue(model.profileDiagnostics.contains("err="))
        XCTAssertFalse(model.profileDiagnostics.contains("err=-"))
    }

    // MARK: - 3. A large page is fetched in chunks

    /// A page (plus a long-lived channel) can carry more distinct authors than one body should: every
    /// request stays at or below 100 ids, and every author is still named.
    func testAPageWithMoreThanOneHundredAuthorsIsResolvedInChunks() async {
        let service = FakeService()
        var posts: [MMPost] = []
        for index in 1...250 {
            let id = "u\(index)"
            service.usersByID[id] = MMUser(id: id, username: "user\(index)")
            posts.append(post("p\(index)", at: Int64(1_000 + index), user: id))
        }
        service.pages = [list(posts)]
        let model = model(service)

        await model.load(ifNeeded: false)

        XCTAssertEqual(service.userRequests.count, 3, "250 ids → 100 + 100 + 50")
        XCTAssertTrue(service.userRequests.allSatisfy { $0.count <= 100 },
                      "one body per 100 ids; observed sizes \(service.userRequests.map(\.count))")
        XCTAssertEqual(model.lastProfileLoad?.requested, 250)
        XCTAssertEqual(model.lastProfileLoad?.resolved, 250)
        XCTAssertEqual(rows(model).count, 250)
        XCTAssertFalse(rows(model).contains { $0.author.displayName == "Unknown user" })
    }

    // MARK: - 4. One failed chunk costs only its own ids

    /// The real chunk-isolation case, with the fake refusing a *specific* chunk: the all-or-nothing
    /// failure is what made the report look like a whole channel.
    func testAFailedChunkKeepsTheAuthorsTheOtherChunksNamed() async {
        let service = ChunkSelectiveFailureService(failingChunkIndex: 1)
        var posts: [MMPost] = []
        for index in 1...250 {
            let id = "u\(index)"
            service.usersByID[id] = MMUser(id: id, username: "user\(index)")
            posts.append(post("p\(index)", at: Int64(1_000 + index), user: id))
        }
        service.pages = [list(posts)]
        let model = model(service)

        await model.load(ifNeeded: false)

        XCTAssertEqual(service.userRequests.count, 3)
        XCTAssertEqual(model.lastProfileLoad?.requested, 250)
        XCTAssertEqual(model.lastProfileLoad?.failed, 100, "the middle chunk's 100 ids")
        XCTAssertEqual(model.lastProfileLoad?.resolved, 150)
        XCTAssertNotNil(model.lastProfileLoad?.error)
        // Named rows: everything but the refused chunk.
        XCTAssertEqual(rows(model).filter { $0.author.displayName != "Unknown user" }.count, 150)
    }

    /// A `ChannelServing` whose `users(ids:)` refuses the chunk with the given index (0-based).
    @MainActor
    final class ChunkSelectiveFailureService: ChannelServing {
        var pageSize = 60
        var pages: [MMPostList] = []
        var usersByID: [String: MMUser] = [:]
        private(set) var userRequests: [[String]] = []
        private let failingChunkIndex: Int
        private var served = 0

        init(failingChunkIndex: Int) { self.failingChunkIndex = failingChunkIndex }

        func channel(id: String) async throws -> MMChannel { throw MMError.notFound }

        func posts(channelID: String, before: String?, perPage: Int) async throws -> MMPostList {
            let slot = min(served, max(0, pages.count - 1))
            served += 1
            return pages.isEmpty ? MMPostList(order: [], posts: [:]) : pages[slot]
        }

        func users(ids: [String]) async throws -> [MMUser] {
            let index = userRequests.count
            userRequests.append(ids)
            if index == failingChunkIndex {
                throw MMError.client(status: 400, message: "Invalid or missing user_id")
            }
            return ids.compactMap { usersByID[$0] }
        }

        func fileData(fileID: String, preferThumbnail: Bool) async throws -> Data {
            throw MMError.notFound
        }
    }

    // MARK: - 5. The cache is consulted before the network

    func testProfilesAlreadyInHandCostNoRequest() async {
        let cache = UserProfileCache()
        cache.remember([MMUser(id: "u1", username: "ada", firstName: "Ada")])

        let service = FakeService()
        service.usersByID = ["u1": MMUser(id: "u1", username: "ada", firstName: "Ada")]
        service.pages = [list([post("p1", at: 1_000, user: "u1")])]
        let model = model(service, profiles: cache)

        await model.load(ifNeeded: false)

        XCTAssertTrue(service.userRequests.isEmpty, "a warm cache must not ask again")
        XCTAssertEqual(row(model, for: "p1")?.author.displayName, "Ada")
        XCTAssertEqual(model.lastProfileLoad?.cached, 1)
        XCTAssertEqual(model.lastProfileLoad?.sent, 0)
    }

    // MARK: - 6. The diagnostics line

    /// The card asks for the counts in a diagnostics line. `profileDiagnostics` is what the
    /// `-shellSnapshot` dump prints on a live server; the totals accumulate across the pane's loads so
    /// a one-id socket patch after the page cannot overwrite the page's story.
    func testTheDiagnosticsLineReportsRequestedCachedSentAndResolved() async {
        let cache = UserProfileCache()
        cache.remember([MMUser(id: "u1", username: "ada")])

        let service = FakeService()
        service.usersByID = ["u2": MMUser(id: "u2", username: "grace")]
        service.pages = [list([
            post("p2", at: 2_000, user: "u2"),
            post("p1", at: 1_000, user: "u1"),
            post("p0", at: 500, user: "", type: "system_join_channel",
                 props: usernameProps("ada")),
        ])]
        let model = model(service, profiles: cache)

        await model.load(ifNeeded: false)

        let line = model.profileDiagnostics
        XCTAssertTrue(line.contains("requested=2"), line)
        XCTAssertTrue(line.contains("cached=1"), line)
        XCTAssertTrue(line.contains("sent=1"), line)
        XCTAssertTrue(line.contains("resolved=2"), line)
        XCTAssertTrue(line.contains("failed=0"), line)
        XCTAssertTrue(line.contains("err=-"), line)
    }

    // MARK: - 7. ProfileBatch's own rules, without a view model

    func testCleanDropsEmptyIDsAndDuplicatesInInputOrder() {
        XCTAssertEqual(ProfileBatch.clean(["b", "", "a", "b", ""]), ["b", "a"])
        XCTAssertEqual(ProfileBatch.clean([]), [])
        XCTAssertEqual(ProfileBatch.clean(["", ""]), [])
    }

    func testChunksAreAtMostOneHundredIdsAndCoverEveryID() {
        let ids = (1...250).map { "u\($0)" }
        let chunks = ProfileBatch.chunks(ids)
        XCTAssertEqual(chunks.map(\.count), [100, 100, 50])
        XCTAssertEqual(chunks.flatMap { $0 }, ids)
        XCTAssertEqual(ProfileBatch.chunks([]), [])
    }

    func testAnEmptyIDListMakesNoRequestAtAll() async {
        var calls = 0
        let report = await ProfileBatch.load(["", "", "u1", "u1"], fetch: { _ in
            calls += 1
            return []
        })
        XCTAssertEqual(calls, 1, "the duplicate is folded, but the one real id is asked for once")
        XCTAssertEqual(report.requested, 1)

        calls = 0
        let none = await ProfileBatch.load(["", ""], fetch: { _ in
            calls += 1
            return []
        })
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(none.requested, 0)
    }

    /// Errors reach the report instead of being dropped on the floor — the third defect.
    func testAFailedFetchIsReportedWithItsError() async {
        let report = await ProfileBatch.load(["u1", "u2"], fetch: { _ in
            throw MMError.timeout
        })
        XCTAssertEqual(report.requested, 2)
        XCTAssertEqual(report.failed, 2)
        XCTAssertEqual(report.resolved, 0)
        XCTAssertEqual(report.chunks, 1)
        XCTAssertNotNil(report.error)
        XCTAssertTrue(report.line(pane: "test").contains("err="))
    }
}
