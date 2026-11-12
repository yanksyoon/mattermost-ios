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

        let candidates = try await client.autocompleteUsers(term: "ki", inChannel: "chan-1",
                                                            inTeam: "team-1", limit: 20)

        // A bare-array decode returns nothing here (the envelope is an object) and the live app then
        // shows no names at all, which is the bug this pins.
        XCTAssertEqual(candidates.inChannel.map(\.username), ["kim"])
        XCTAssertEqual(candidates.inChannel.first?.id, "u1")
        // The server did not split: the key is absent, which is *not* the same as "nobody else".
        XCTAssertFalse(candidates.isClassified)
    }

    /// The mutant the card names: a response that carries `out_of_channel` and `agents` must decode
    /// all three groups. Before this test the type declared `users` only, so both were dropped in
    /// silence — a bot account (which is almost never a member) never reached the list.
    func testTheAutocompleteEnvelopeDecodesOutOfChannelAndAgents() async throws {
        let transport = FakeAPITransport(repeating: .json([
            "users": [userJSON(id: "u1", username: "kim")],
            "out_of_channel": [userJSON(id: "u2", username: "feedbackbot")],
            "agents": [userJSON(id: "u3", username: "aiagent")]
        ]))
        let client = try makeClient(transport)

        let candidates = try await client.autocompleteUsers(term: "bo", inChannel: "chan-1",
                                                            inTeam: "team-1", limit: 20)

        XCTAssertEqual(candidates.inChannel.map(\.username), ["kim"])
        XCTAssertEqual(candidates.outOfChannel?.map(\.username), ["feedbackbot"])
        XCTAssertEqual(candidates.agents?.map(\.username), ["aiagent"])
        XCTAssertTrue(candidates.isClassified, "the key was present: the server split the answer")
        XCTAssertEqual(candidates.everybody.count, 3)
    }

    func testAnEmptyAutocompleteAnswerIsAnEmptyListAndNotAThrow() async throws {
        // `{}` — a term with no matches. The decode must not throw, or every miss looks like an
        // outage to the composer.
        let transport = FakeAPITransport(repeating: .json([:]))
        let client = try makeClient(transport)

        let candidates = try await client.autocompleteUsers(term: "nobody", inChannel: nil,
                                                            inTeam: nil, limit: 20)
        XCTAssertTrue(candidates.isEmpty)
        XCTAssertTrue(candidates.inChannel.isEmpty)
    }

    /// The parameter **names** are the contract (kanban t_03f2dbfd, measured on 9.11.19):
    /// `in_team` (a team id) and `in_channel`. The old `in_team_id`/`in_channel_id` spellings are
    /// ignored by that server, which is why the list was team-wide and the client had to filter.
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
        XCTAssertEqual(items["in_team"], "team-1")
        XCTAssertEqual(items["in_channel"], "chan-1")
        XCTAssertNil(items["in_team_id"], "the server ignores this spelling")
        XCTAssertNil(items["in_channel_id"], "the server ignores this spelling")
    }

    /// A channel scope with no team is a `500` on the pinned server
    /// (`api.user.autocomplete_users.missing_team_id.app_error`), so it must not be sent alone.
    func testTheChannelScopeIsNeverSentWithoutATeam() async throws {
        let transport = FakeAPITransport(repeating: .json(["users": []]))
        let client = try makeClient(transport)

        _ = try await client.autocompleteUsers(term: "ki", inChannel: "chan-1", inTeam: nil, limit: 20)

        let request = try XCTUnwrap(transport.lastRequest)
        let names = query(request).keys
        XCTAssertFalse(names.contains("in_channel"), "a channel scope alone is a 500 on 9.11.19")
        XCTAssertFalse(names.contains("in_team"))
    }

    func testTheAutocompleteRequestOmitsScopesItDoesNotKnow() async throws {
        let transport = FakeAPITransport(repeating: .json(["users": []]))
        let client = try makeClient(transport)

        _ = try await client.autocompleteUsers(term: "ki", inChannel: "", inTeam: "", limit: 20)

        let request = try XCTUnwrap(transport.lastRequest)
        let names = query(request).keys
        XCTAssertFalse(names.contains("in_channel"), "an empty id must not be sent as a scope")
        XCTAssertFalse(names.contains("in_team"))
    }

    // MARK: - The bot list

    func testTheBotListIsABareArrayOfBotRecords() async throws {
        let transport = FakeAPITransport(repeating: .json([
            ["user_id": "u9", "username": "feedbackbot", "display_name": "Feedbackbot",
             "description": "", "owner_id": "nps", "create_at": 0, "update_at": 0, "delete_at": 0],
            ["user_id": "u8", "username": "gone-bot", "display_name": "Gone",
             "description": "", "owner_id": "x", "create_at": 0, "update_at": 0, "delete_at": 42]
        ]))
        let client = try makeClient(transport)

        let bots = try await client.bots()

        XCTAssertEqual(bots.map(\.userId), ["u9", "u8"])
        XCTAssertEqual(bots.filter(\.isLive).map(\.username), ["feedbackbot"])
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url.path, "/api/v4/bots")
        XCTAssertEqual(query(request)["per_page"], "200")
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
