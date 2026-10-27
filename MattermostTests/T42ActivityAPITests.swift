// T42 — the requests the *client* actually sends for the mentions feed, pinned at the transport seam.
//
// The pure rules live in `T42ActivityTests`; this file exists for the things only a request can get
// wrong, and all of them are measured facts rather than preferences (`ActivityAPI.swift` header,
// `scripts/t42_activity_probe.py` against Mattermost 9.11.19):
//
//  1. the mentions read is `POST /posts/search` with **no team in the path** (`GET /users/me/mentions`
//     and `/teams//posts/search` both 404), and the body is the search screen's own shape with
//     `is_or_search: true` and the keys as `terms`;
//  2. the mention keys come from `GET /users/me`'s `notify_props` — a *string* `"true"`, not a Bool;
//  3. `POST /channels/members/{me}/mark_read` takes a bare JSON **array** of channel ids and answers
//     `{status, last_viewed_at_times}`;
//  4. `GET /users/{me}/teams/{team}/channels/members` is the per-team read-cursor list.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0, `app/client/rest/posts.ts`,
// `app/actions/remote/search.ts`. Licence: Apache-2.0, attribution in docs/THIRD_PARTY_NOTICES.md §19.

import XCTest
@testable import Mattermost

final class T42ActivityAPITests: XCTestCase {

    private let myID = "user0000000000000000000001"
    private let teamID = "team0000000000000000000001"
    private let channelID = "chan0000000000000000000001"

    private func client(_ transport: APITransport) throws -> APIClient {
        try APIClient(serverURL: URL(string: "https://mm.example")!,
                      transport: transport,
                      retryPolicy: .none,
                      tokenProvider: { "tok" })
    }

    private func bodyObject(_ data: Data?) throws -> [String: Any] {
        let data = try XCTUnwrap(data)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - The mentions window

    func testTheMentionsReadIsTheCrossTeamSearchPost() async throws {
        let payload: [String: Any] = [
            "order": ["post0000000000000000000001"],
            "posts": ["post0000000000000000000001": ["id": "post0000000000000000000001",
                                                     "create_at": 1_700_000_000_000,
                                                     "user_id": "user0000000000000000000002",
                                                     "channel_id": channelID,
                                                     "message": "hey @perfprobe"]],
            "has_next": false,
        ]
        let transport = FakeAPITransport(stubs: [.ok(.json(payload, status: 200))])
        let client = try client(transport)

        let results = try await client.mentionSearch(terms: "deploybot @perfprobe ", page: 0, perPage: 60)

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.method, .post)
        // No team segment: the empty-team form of the route does not survive the router (measured).
        XCTAssertEqual(request.url.path, "/api/v4/posts/search")

        let body = try bodyObject(request.body)
        XCTAssertEqual(body["terms"] as? String, "deploybot @perfprobe ")
        XCTAssertEqual(body["is_or_search"] as? Bool, true)
        XCTAssertEqual(body["page"] as? Int, 0)
        XCTAssertEqual(body["per_page"] as? Int, 60)

        XCTAssertEqual(results.order, ["post0000000000000000000001"])
        XCTAssertEqual(results.orderedPosts.first?.message, "hey @perfprobe")
    }

    func testTheProfileReadCarriesNotifyPropsAsStrings() async throws {
        let payload: [String: Any] = [
            "id": myID,
            "username": "perfprobe",
            "first_name": "Perf",
            "last_name": "Probe",
            "notify_props": ["mention_keys": "deploybot", "first_name": "true", "channel": "false"],
        ]
        let transport = FakeAPITransport(stubs: [.ok(.json(payload, status: 200))])
        let client = try client(transport)

        let profile = try await client.activityProfile()

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.url.path, "/api/v4/users/me")

        XCTAssertEqual(profile.id, myID)
        XCTAssertEqual(profile.firstName, "Perf")
        // The derivation reads the flags as strings — a Bool decode would answer nil for both values.
        let keys = MentionKeys.derive(profile)
        XCTAssertEqual(keys.keys.map(\.key), ["deploybot", "Perf", "@perfprobe"])
        XCTAssertEqual(keys.searchTerms, "deploybot Perf @perfprobe ")
    }

    // MARK: - Read state

    func testMarkingChannelsReadPostsABareArray() async throws {
        let payload: [String: Any] = ["status": "OK",
                                      "last_viewed_at_times": [channelID: 1_700_000_000_000]]
        let transport = FakeAPITransport(stubs: [.ok(.json(payload, status: 200))])
        let client = try client(transport)

        let response = try await client.markChannelsRead(channelIDs: [channelID], userID: myID)

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url.path, "/api/v4/channels/members/\(myID)/mark_read")

        // A bare array, not `{"channel_ids": [...]}` — the natural guess, and a 400.
        let data = try XCTUnwrap(request.body)
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String])
        XCTAssertEqual(array, [channelID])

        XCTAssertEqual(response.status, "OK")
        XCTAssertEqual(response.lastViewedAtTimes[channelID], 1_700_000_000_000)
    }

    func testTheTeamReadCursorsAreOnePagedRequest() async throws {
        let payload: [[String: Any]] = [["channel_id": channelID, "user_id": myID,
                                         "last_viewed_at": 1_700_000_000_000,
                                         "mention_count": 2, "msg_count": 9,
                                         "roles": "channel_user"]]
        let transport = FakeAPITransport(stubs: [.ok(.json(payload, status: 200))])
        let client = try client(transport)

        let members = try await client.channelMembersForTeam(teamID: teamID, userID: myID)

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url.path,
                       "/api/v4/users/\(myID)/teams/\(teamID)/channels/members")
        let query = try XCTUnwrap(request.url.query)
        XCTAssertTrue(query.contains("per_page=200"))
        XCTAssertEqual(members.first?.lastViewedAt, 1_700_000_000_000)
        XCTAssertEqual(members.first?.mentionCount, 2)
    }
}
