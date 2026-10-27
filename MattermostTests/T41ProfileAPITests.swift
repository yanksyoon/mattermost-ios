// T41 — the requests the *client* actually sends, pinned at the transport seam.
//
// The pure rules live in `T41ProfileTests`; this file exists for the things only a request can get
// wrong, and all of them are measured facts rather than preferences (`ProfileModels.swift` header,
// `scripts/t41_profile_probe.py` against Mattermost 9.11.19):
//
//  1. `PUT /users/{id}/status/custom` takes the custom status **flat**. A body wrapped in
//     `custom_status` answers `400 invalid_body_param` — the most natural guess, and wrong.
//  2. `expires_at` is a Go `time.Time`: a non-empty duration with no future expiry is a 400, an empty
//     string is a decode failure, and the "no expiry" case is the **omitted key** (Go's zero time).
//  3. `PUT /users/me/status` takes `dnd_end_time` in epoch **milliseconds**.
//  4. `POST /channels/direct` takes a bare JSON **array** of ids and answers 201 the first time.
//  5. `POST /users/ids` is the batch profile read; it carries `props`, which is where the custom status
//     of somebody else lives.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0, `app/client/rest/users.ts` and
// `app/client/rest/channels.ts`. Licence: Apache-2.0, attribution in docs/THIRD_PARTY_NOTICES.md §18.

import XCTest
@testable import Mattermost

final class T41ProfileAPITests: XCTestCase {

    private let userID = "user0000000000000000000001"
    private let otherID = "user0000000000000000000002"

    private func client(_ transport: APITransport) throws -> APIClient {
        // `RetryPolicy.none`: these tests count requests, and a retry would make a 404 look like two.
        try APIClient(serverURL: URL(string: "https://mm.example")!,
                      transport: transport,
                      retryPolicy: .none,
                      tokenProvider: { "tok" })
    }

    private func jsonObject(_ data: Data?) throws -> [String: Any] {
        let data = try XCTUnwrap(data)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private var fixedNow: Date { Date(timeIntervalSince1970: 1_793_053_200) }

    // MARK: - Reading a profile

    func testTheProfileReadIsAGetOfTheUserEndpointAndDecodesProps() async throws {
        let payload: [String: Any] = [
            "id": otherID,
            "username": "avone72453",
            "first_name": "Ada",
            "last_name": "Vone",
            "position": "Analyst",
            "roles": "system_admin system_user",
            "props": ["customStatus": "{\"emoji\":\"coffee\",\"text\":\"Remote\",\"duration\":\"\",\"expires_at\":\"0001-01-01T00:00:00Z\"}"],
            "timezone": ["automaticTimezone": "America/Vancouver",
                         "manualTimezone": "",
                         "useAutomaticTimezone": "true"],
            "create_at": 1_700_000_000_000,
            "last_activity_at": 1_790_000_000_000,
        ]
        let transport = FakeAPITransport(stubs: [.ok(.json(payload, status: 200))])
        let client = try client(transport)

        let profile = try await client.userProfile(id: otherID)

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.url.path, "/api/v4/users/\(otherID)")
        XCTAssertEqual(profile.displayName, "Ada Vone")
        XCTAssertEqual(profile.customStatus?.text, "Remote")
        XCTAssertEqual(profile.localTimeZoneID, "America/Vancouver")
        XCTAssertTrue(profile.isSystemAdmin)
    }

    func testTheBatchProfileReadPostsTheIds() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.json([Any](), status: 200))])
        let client = try client(transport)

        _ = try await client.userProfiles(ids: [userID, otherID])

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url.path, "/api/v4/users/ids")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String])
        XCTAssertEqual(Set(body), Set([userID, otherID]))
    }

    // MARK: - The custom status write

    func testTheCustomStatusBodyIsFlatAndItsExpiryIsAnOmittedKeyOrARFC3339Date() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(["status": "OK"], status: 200)),
            .ok(.json(["status": "OK"], status: 200)),
        ])
        let client = try client(transport)

        let noExpiry = CustomStatusBody(emoji: "coffee", text: "Heads down", duration: "", expiresAt: nil)
        try await client.setCustomStatus(userID: userID, body: noExpiry)

        var request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, .put)
        XCTAssertEqual(request.url.path, "/api/v4/users/\(userID)/status/custom")
        var body = try jsonObject(request.body)
        XCTAssertNil(body["custom_status"], "the body is flat — wrapping it is a measured 400")
        XCTAssertEqual(body["emoji"] as? String, "coffee")
        XCTAssertEqual(body["text"] as? String, "Heads down")
        XCTAssertEqual(body["duration"] as? String, "")
        XCTAssertNil(body["expires_at"])

        let withExpiry = CustomStatusBody(emoji: "calendar", text: "Until the review", duration: "one_hour",
                                          expiresAt: fixedNow.addingTimeInterval(3600))
        try await client.setCustomStatus(userID: userID, body: withExpiry)

        request = try XCTUnwrap(transport.lastRequest)
        body = try jsonObject(request.body)
        XCTAssertEqual(body["duration"] as? String, "one_hour")
        let raw = try XCTUnwrap(body["expires_at"] as? String)
        XCTAssertTrue(raw.hasSuffix("Z"), raw)
        let parsed = try XCTUnwrap(ProfileTimestamp.date(fromServer: raw))
        XCTAssertEqual(parsed.timeIntervalSince1970,
                       fixedNow.addingTimeInterval(3600).timeIntervalSince1970, accuracy: 1)
    }

    func testClearingTheCustomStatusIsADeleteOfTheSameRoute() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.json(["status": "OK"], status: 200))])
        let client = try client(transport)

        try await client.clearCustomStatus(userID: userID)

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.method, .delete)
        XCTAssertEqual(request.url.path, "/api/v4/users/\(userID)/status/custom")
    }

    // MARK: - The presence write

    func testThePresenceWriteCarriesTheUserIdTheStatusAndAMillisecondDNDEnd() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(["user_id": userID, "status": "away", "manual": true], status: 200)),
        ])
        let client = try client(transport)

        _ = try await client.setMyStatus(.away, dndEndTime: nil, userID: userID)
        var request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.method, .put)
        XCTAssertEqual(request.url.path, "/api/v4/users/\(userID)/status")
        var body = try jsonObject(request.body)
        XCTAssertEqual(body["user_id"] as? String, userID)
        XCTAssertEqual(body["status"] as? String, "away")
        XCTAssertNil(body["dnd_end_time"])

        _ = try? await client.setMyStatus(.dnd, dndEndTime: 1_793_053_200_000, userID: userID)
        request = try XCTUnwrap(transport.lastRequest)
        body = try jsonObject(request.body)
        // Epoch milliseconds, not seconds: the endpoint answers `dnd_end_time` in ms (measured).
        XCTAssertEqual(body["dnd_end_time"] as? Int64, 1_793_053_200_000)
    }

    // MARK: - The DM shortcut

    func testTheDirectChannelRequestIsAnArrayOfBothIdsAndA201IsAccepted() async throws {
        let channel: [String: Any] = ["id": "dm00000000000000000000001",
                                      "name": "\(userID)__\(otherID)",
                                      "type": "D", "team_id": "", "display_name": ""]
        let transport = FakeAPITransport(stubs: [.ok(.json(channel, status: 201))])
        let client = try client(transport)

        let answer = try await client.directChannel(userIDs: [userID, otherID])

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url.path, "/api/v4/channels/direct")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String])
        XCTAssertEqual(body, [userID, otherID])
        XCTAssertEqual(answer.id, "dm00000000000000000000001")
        XCTAssertEqual(answer.type, "D")
    }

    func testAForbiddenDirectChannelIsATypedErrorTheScreenCanName() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(["id": "api.context.permissions.app_error",
                       "message": "You do not have the appropriate permissions."], status: 403)),
        ])
        let client = try client(transport)

        do {
            _ = try await client.directChannel(userIDs: [userID, otherID])
            XCTFail("a 403 must throw")
        } catch let error as MMError {
            guard case .forbidden = error else {
                return XCTFail("expected .forbidden, got \(error)")
            }
        }
    }

    // MARK: - The avatar

    func testAMissingProfileImageIsAnAnswerNotAnError() async throws {
        // Measured: an account without a picture answers 404, and that is the normal case — the screen
        // draws initials. `userProfileImage` therefore swallows the failure.
        let transport = FakeAPITransport(stubs: [
            .ok(.json(["id": "api.context.404.app_error", "message": "not found"], status: 404)),
        ])
        let client = try client(transport)

        let bytes = await client.userProfileImage(userID: otherID, lastUpdateAt: 1_790_000_000_000)
        XCTAssertNil(bytes)
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url.path, "/api/v4/users/\(otherID)/profile_image")
        XCTAssertTrue(request.url.query?.contains("_=1790000000000") ?? false,
                      "the cache-buster is the account's update_at: \(request.url.absoluteString)")
    }
}
