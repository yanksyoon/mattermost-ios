// T35 — the composer's read endpoints, pinned to the shapes the server actually answers.
//
// Why these tests exist: both bugs below were found by the **live** suite, not by unit tests, and
// both were silent — `try?` in the view model turned "wrong shape" into "no suggestions", which reads
// exactly like "the user typed a name nobody has". A decode that cannot be exercised offline is a
// decode nobody checks, so the envelope and the HTTP method of each endpoint are asserted here:
//
//   * `GET /users/autocomplete` answers `{"users": [...]}`, **not** a bare array (9.11.19, measured).
//   * `/teams/{id}/channels/search` is **POST with a JSON body**; the GET form is a 404
//     `api.context.404.app_error` on the same server, which is not a decode error and cannot be
//     caught by a decode test.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0, `app/client/rest/users.ts`
// (`autocompleteUsers`), `app/client/rest/channels.ts` (`searchChannels`). Apache-2.0; endpoints
// reimplemented against https://api.mattermost.com — see docs/THIRD_PARTY_NOTICES.md §11.

import XCTest
@testable import Mattermost

final class T35ComposerAPITests: XCTestCase {

    private let serverURL = URL(string: "https://mm.example.com")!

    private func makeClient(_ transport: APITransport) throws -> APIClient {
        try APIClient(serverURL: serverURL,
                      transport: transport,
                      retryPolicy: APIClient.RetryPolicy(maxAttempts: 1, baseDelay: 0,
                                                         maxDelay: 0, jitterRatio: 0),
                      tokenProvider: { "test-token" },
                      sleep: { _ in },
                      random: { 0 })
    }

    private func userJSON(id: String, username: String) -> [String: Any] {
        ["id": id, "username": username, "delete_at": 0, "create_at": 0, "update_at": 0,
         "email": "\(username)@example.com", "nickname": "", "first_name": "", "last_name": "",
         "position": "", "roles": "system_user", "locale": "en"]
    }

    private func channelJSON(id: String, name: String) -> [String: Any] {
        ["id": id, "name": name, "display_name": name, "team_id": "team-1", "type": "O",
         "create_at": 0, "update_at": 0, "delete_at": 0, "total_msg_count": 0]
    }

    /// The query a request carries, as a dictionary (`APIRequest` holds a `URL`, not a path + query).
    private func query(_ request: APIRequest) -> [String: String] {
        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        var result: [String: String] = [:]
        for item in components?.queryItems ?? [] { result[item.name] = item.value ?? "" }
        return result
    }

    // MARK: - The @ list

    func testTheAutocompleteEnvelopeIsAnObjectWithAUsersArray() async throws {
        let transport = FakeAPITransport(repeating: .json(["users": [userJSON(id: "u1", username: "kim")]]))
        let client = try makeClient(transport)

        let users = try await client.autocompleteUsers(term: "ki", inChannel: "chan-1",
                                                       inTeam: "team-1", limit: 20)

        // A bare-array decode returns nothing here (the envelope is an object) and the live app then
        // shows no names at all, which is the bug this pins.
        XCTAssertEqual(users.map(\.username), ["kim"])
        XCTAssertEqual(users.first?.id, "u1")
    }

    func testAnEmptyAutocompleteAnswerIsAnEmptyListAndNotAThrow() async throws {
        // `{}` — a term with no matches. The decode must not throw, or every miss looks like an
        // outage to the composer.
        let transport = FakeAPITransport(repeating: .json([:]))
        let client = try makeClient(transport)

        let users = try await client.autocompleteUsers(term: "nobody", inChannel: nil,
                                                       inTeam: nil, limit: 20)
        XCTAssertTrue(users.isEmpty)
    }

    func testTheAutocompleteRequestCarriesTheMembershipScopes() async throws {
        let transport = FakeAPITransport(repeating: .json(["users": [userJSON(id: "u1", username: "kim")]]))
        let client = try makeClient(transport)

        _ = try await client.autocompleteUsers(term: "ki", inChannel: "chan-1",
                                               inTeam: "team-1", limit: 20)

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.url.path, "/api/v4/users/autocomplete")
        let items = query(request)
        XCTAssertEqual(items["name"], "ki")
        XCTAssertEqual(items["limit"], "20")
        // `in_channel_id` is what makes the server restrict the answer to the channel's members;
        // `in_team_id` narrows it to the team.
        XCTAssertEqual(items["in_channel_id"], "chan-1")
        XCTAssertEqual(items["in_team_id"], "team-1")
    }

    func testTheAutocompleteRequestOmitsScopesItDoesNotKnow() async throws {
        let transport = FakeAPITransport(repeating: .json(["users": []]))
        let client = try makeClient(transport)

        _ = try await client.autocompleteUsers(term: "ki", inChannel: "", inTeam: nil, limit: 20)

        let request = try XCTUnwrap(transport.lastRequest)
        let names = query(request).keys
        XCTAssertFalse(names.contains("in_channel_id"), "an empty id must not be sent as a scope")
        XCTAssertFalse(names.contains("in_team_id"))
    }

    // MARK: - The # list

    func testChannelSearchIsAPostWithAJSONBody() async throws {
        let transport = FakeAPITransport(repeating: .json([channelJSON(id: "c1", name: "town-square")]))
        let client = try makeClient(transport)

        let channels = try await client.searchChannels(teamID: "team-1", term: "town", limit: 20)

        XCTAssertEqual(channels.map(\.name), ["town-square"])
        let request = try XCTUnwrap(transport.lastRequest)
        // The GET form of this path is a 404 on the pinned server; the method is the contract.
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url.path, "/api/v4/teams/team-1/channels/search")
        XCTAssertTrue(query(request).isEmpty, "the term belongs in the body, not the query")

        let body = try XCTUnwrap(request.body)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["term"] as? String, "town")
        XCTAssertEqual(json["limit"] as? Int, 20)
    }

    func testChannelSearchDecodesABareArray() async throws {
        // Unlike the user list, this endpoint answers with the array itself — the two shapes are
        // deliberately asserted apart, because "one of them is wrapped" is exactly the mistake.
        let transport = FakeAPITransport(repeating: .json([]))
        let client = try makeClient(transport)
        let channels = try await client.searchChannels(teamID: "team-1", term: "zzz", limit: 20)
        XCTAssertTrue(channels.isEmpty)
    }

    // MARK: - The member list

    func testTheMemberListIsABareArrayWithPaging() async throws {
        let transport = FakeAPITransport(repeating: .json([
            ["channel_id": "chan-1", "user_id": "u1", "roles": "channel_user",
             "last_viewed_at": 0, "msg_count": 0, "mention_count": 0, "notify_props": [:] as [String: Any]]
        ]))
        let client = try makeClient(transport)

        let members = try await client.channelMembers(channelID: "chan-1", page: 0, perPage: 200)

        XCTAssertEqual(members.map(\.userId), ["u1"])
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url.path, "/api/v4/channels/chan-1/members")
        let items = query(request)
        XCTAssertEqual(items["page"], "0")
        XCTAssertEqual(items["per_page"], "200")
    }
}
