// T39 — the saved-posts request the *client* actually sends, pinned at the transport seam.
//
// `SearchAPI.savedPosts` tries `GET /users/me/posts/flagged` first and falls back to
// `GET /users/me/teams/{team}/posts/saved` **only on a 404**. That order is a measured fact, not a
// preference: on the pinned server (Mattermost 9.11.19, `scripts/t39_search_probe.py`) the team-scoped
// path answers 404 and the flagged path answers 200, while newer servers carry the reverse. So the
// order and the "only on 404" condition are contract, and a fake transport is the only place that can
// hold both paths still.
//
// `SearchAPI.swift` used to cite this file before it existed (T39-AV F4). It exists now, and the
// `@testable` transport fake is `FakeAPITransport` (T28TestSupport).
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0, `app/client/rest/posts.ts`
// (`getFlaggedPosts`) and `app/actions/remote/post.ts`. Licence: Apache-2.0, attribution in
// docs/THIRD_PARTY_NOTICES.md §16.

import XCTest
@testable import Mattermost

final class T39SearchAPITests: XCTestCase {

    private let teamID = "team0000000000000000000001"

    // MARK: - Helpers

    private func client(_ transport: APITransport) throws -> APIClient {
        // `RetryPolicy.none`: a 404 must not be retried, and the assertion below counts requests.
        try APIClient(serverURL: URL(string: "https://mm.example")!,
                      transport: transport,
                      retryPolicy: .none,
                      tokenProvider: { "tok" })
    }

    private func postListJSON(id: String, channelID: String = "chan0000000000000000000001") -> [String: Any] {
        ["order": [id],
         "posts": [id: ["id": id, "channel_id": channelID, "user_id": "u1",
                        "create_at": 1_790_000_000_000, "message": "keep this"]]]
    }

    private func decodedIDs(_ list: MMPostList) -> [String] { list.order }

    // MARK: - The saved list

    /// The happy path: the primary endpoint answers, and there is exactly **one** request — no
    /// speculative call to the fallback, and no retry of the 200.
    func testTheSavedListUsesTheFlaggedPathFirstAndStopsThere() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(postListJSON(id: "p1"), status: 200)),
            .ok(.json(postListJSON(id: "p2"), status: 200))
        ])
        let client = try client(transport)

        let list = try await client.savedPosts(teamID: teamID, page: 0, perPage: 30)

        XCTAssertEqual(decodedIDs(list), ["p1"], "the primary answer is the list")
        XCTAssertEqual(transport.requestCount, 1, "a 200 must not be followed by the fallback")
        let url = try XCTUnwrap(transport.lastRequest?.url)
        XCTAssertEqual(url.path, "/api/v4/users/me/posts/flagged")
        XCTAssertTrue(url.query?.contains("team_id=\(teamID)") == true,
                      "the team filter travels with the primary request: \(url.absoluteString)")
    }

    /// The fallback order: a 404 from the flagged path is the *only* trigger, and the second request is
    /// the team-scoped spelling with the same paging query and **no** `team_id` (the path carries it).
    func testTheSavedListFallsBackToTheTeamScopedPathOn404() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(["id": "api.context.404.app_error", "message": "not found"], status: 404)),
            .ok(.json(postListJSON(id: "p9"), status: 200))
        ])
        let client = try client(transport)

        let list = try await client.savedPosts(teamID: teamID, page: 2, perPage: 30)

        XCTAssertEqual(decodedIDs(list), ["p9"], "the answer comes from the fallback")
        XCTAssertEqual(transport.requestCount, 2)
        let first = try XCTUnwrap(transport.requests.first?.url)
        let second = try XCTUnwrap(transport.lastRequest?.url)
        XCTAssertEqual(first.path, "/api/v4/users/me/posts/flagged")
        XCTAssertEqual(second.path, "/api/v4/users/me/teams/\(teamID)/posts/saved")
        XCTAssertTrue(second.query?.contains("page=2") == true, second.absoluteString)
        XCTAssertTrue(second.query?.contains("per_page=30") == true, second.absoluteString)
        XCTAssertFalse(second.query?.contains("team_id=") == true,
                       "the team-scoped path already names the team: \(second.absoluteString)")
    }

    /// Without a team there is nothing to fall back to, so the 404 is the answer — and the client must
    /// not invent a request to a path it cannot fill in.
    func testTheSavedListWithoutATeamReportsThe404InsteadOfFallingBack() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(["message": "not found"], status: 404)),
            .ok(.json(postListJSON(id: "p9"), status: 200))
        ])
        let client = try client(transport)

        do {
            _ = try await client.savedPosts(teamID: nil, page: 0, perPage: 30)
            XCTFail("a 404 with no team must be an error, not an empty list")
        } catch MMError.notFound {
            // expected
        }
        XCTAssertEqual(transport.requestCount, 1, "no team, no fallback request")
        XCTAssertFalse(try XCTUnwrap(transport.lastRequest?.url).query?.contains("team_id=") == true,
                       "an unknown team must not be sent as an empty filter")
    }

    /// A 500 is not a 404: it must surface as its own error rather than sliding onto the fallback and
    /// hiding a broken server behind a different endpoint.
    func testTheSavedListDoesNotFallBackOnANon404Failure() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(["message": "boom"], status: 500)),
            .ok(.json(postListJSON(id: "p9"), status: 200))
        ])
        let client = try client(transport)

        var failed = false
        do {
            _ = try await client.savedPosts(teamID: teamID, page: 0, perPage: 30)
        } catch {
            failed = true
        }
        XCTAssertTrue(failed, "a 500 must be reported")
        XCTAssertEqual(transport.requestCount, 1, "no fallback for a non-404")
        XCTAssertEqual(try XCTUnwrap(transport.lastRequest?.url).path,
                       "/api/v4/users/me/posts/flagged")
    }

    // MARK: - The search request

    /// `time_zone_offset` reaches the wire as **seconds**, which is the unit the server reads
    /// (T39-AV F1). The unit test on `SearchQuery.Body` pins the value; this pins that the value is
    /// what the client serialises into the request body, with the documented snake_case keys.
    func testTheSearchRequestCarriesTheSecondsOffsetOnTheWire() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(["order": [], "posts": [:]], status: 200))
        ])
        let client = try client(transport)
        let query = SearchQuery.compose(from: "deploy in:town-square on:2026-10-26",
                                        timeZoneOffsetSeconds: -25200)

        _ = try await client.searchPosts(teamID: teamID, body: query.body(page: 0, perPage: 60))

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url.path, "/api/v4/teams/\(teamID)/posts/search")
        let body = try XCTUnwrap(request.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["time_zone_offset"] as? Int, -25200)
        XCTAssertEqual(json["terms"] as? String, "deploy in:town-square on:2026-10-26")
        XCTAssertEqual(json["is_or_search"] as? Bool, false)
        XCTAssertEqual(json["include_deleted_channels"] as? Bool, true)
    }
}
