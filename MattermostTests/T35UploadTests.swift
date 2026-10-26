// T35 — the upload direction of `APIClient`: multipart bytes with the right `Content-Type`, progress
// from the transport's own byte count, and **no automatic retry** (a replayed upload can duplicate
// the bytes server-side).
//
// The download half of this convention is T7's `DownloadWorker`, which reports progress through
// `URLSessionDownloadDelegate`; this is the same signal in the other direction, so a person watching
// an upload sees the stack's own numbers rather than a timer's guess.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0, `app/client/rest/files.ts`
// (`uploadFile`) and `app/actions/remote/file.ts` (one file per request, cancel by task id).
// Licence Apache-2.0; see docs/THIRD_PARTY_NOTICES.md §12.

import XCTest
@testable import Mattermost

final class T35UploadTests: XCTestCase {

    private let serverURL = URL(string: "https://mm.example.com")!

    /// A transport that claims the upload capability, so the progress path in `APIClient` runs.
    final class FakeUploadTransport: UploadTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var stubs: [FakeAPITransport.Stub]
        private let fallback: FakeAPITransport.Stub?
        private(set) var requests: [APIRequest] = []
        private(set) var progressReports: [(Int64, Int64)] = []

        init(stubs: [FakeAPITransport.Stub] = [], fallback: FakeAPITransport.Stub? = nil) {
            self.stubs = stubs
            self.fallback = fallback
        }

        var requestCount: Int {
            lock.lock(); defer { lock.unlock() }
            return requests.count
        }

        var body: Data? {
            lock.lock(); defer { lock.unlock() }
            return requests.last?.body
        }

        var headers: [String: String] {
            lock.lock(); defer { lock.unlock() }
            return requests.last?.headers ?? [:]
        }

        func send(_ request: APIRequest) async throws -> APIResponse {
            lock.lock(); requests.append(request); lock.unlock()
            throw APITransportError.other("the progress path must be used for an upload")
        }

        func send(_ request: APIRequest,
                  onSendProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> APIResponse {
            lock.lock()
            requests.append(request)
            let stub: FakeAPITransport.Stub?
            if stubs.isEmpty { stub = fallback } else { stub = stubs.removeFirst() }
            lock.unlock()

            // Two reports, exactly as `URLSession`'s `didSendBodyData` would deliver them.
            onSendProgress(64, 128)
            onSendProgress(128, 128)
            lock.lock(); progressReports.append((128, 128)); lock.unlock()

            guard let stub else { throw APITransportError.other("no stub") }
            if let error = stub.error { throw error }
            guard let response = stub.response else { throw APITransportError.other("empty stub") }
            return response
        }
    }

    private func makeClient(_ transport: APITransport,
                            retryPolicy: APIClient.RetryPolicy = APIClient.RetryPolicy(
                                maxAttempts: 3, baseDelay: 0.5, maxDelay: 20, jitterRatio: 0)) throws -> APIClient {
        try APIClient(serverURL: serverURL,
                      transport: transport,
                      retryPolicy: retryPolicy,
                      tokenProvider: { "test-token" },
                      sleep: { _ in },
                      random: { 0 })
    }

    private func fileInfoJSON(id: String = "file-1", name: String = "a.png") -> [String: Any] {
        ["file_infos": [[
            "id": id, "name": name, "size": 3, "extension": "png",
            "mime_type": "image/png", "width": 0, "height": 0
        ]]]
    }

    // MARK: - The request

    func testAnUploadPostsMultipartWithTheChannelsIDAndTheFile() async throws {
        let transport = FakeUploadTransport(fallback: .ok(.json(fileInfoJSON())))
        let client = try makeClient(transport)
        let upload = ComposerUpload(filename: "a.png", mimeType: "image/png", data: Data([1, 2, 3]))

        var reported: [(Int64, Int64)] = []
        let info = try await client.uploadFile(upload, channelID: "chan-1") { sent, expected in
            reported.append((sent, expected))
        }

        XCTAssertEqual(info.id, "file-1")
        XCTAssertEqual(transport.requestCount, 1)
        // The multipart content type — not the JSON one `post(_:path:body:)` would set, which the
        // server answers with a 400.
        let contentType = transport.headers["Content-Type"] ?? ""
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="), contentType)
        XCTAssertEqual(transport.headers["Authorization"], "Bearer test-token")

        // The body really carries both parts, in the documented order.
        let body = try XCTUnwrap(transport.body)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"channel_id\""), text)
        XCTAssertTrue(text.contains("chan-1"))
        XCTAssertTrue(text.contains("name=\"files\"; filename=\"a.png\""))
        XCTAssertTrue(text.contains("Content-Type: image/png"))
        // The three payload bytes are in the body verbatim.
        XCTAssertTrue(body.range(of: Data([1, 2, 3])) != nil)

        // Progress came from the transport, twice, and reached the caller.
        XCTAssertEqual(reported.map { $0.0 }, [64, 128])
        XCTAssertEqual(reported.map { $0.1 }, [128, 128])
    }

    func testAnUploadIsNotRetried() async throws {
        // A 5xx is the case the GET path retries. For an upload, retrying could post the bytes twice:
        // the first attempt may have landed even though its answer was lost.
        let transport = FakeUploadTransport(fallback: .ok(.json(["message": "database is down"], status: 500)))
        let client = try makeClient(transport)
        let upload = ComposerUpload(filename: "a.png", mimeType: "image/png", data: Data([1]))

        do {
            _ = try await client.uploadFile(upload, channelID: "chan-1") { _, _ in }
            XCTFail("a 500 must surface as an error")
        } catch {
            // expected
        }
        XCTAssertEqual(transport.requestCount, 1, "an upload must never be replayed automatically")
    }

    func testAReadIsStillRetriedAfterAServerError() async throws {
        // The rule is about uploads, not about `APIClient`: an idempotent GET keeps its retry.
        let transport = FakeAPITransport(stubs: [.ok(.json(["message": "down"], status: 500)),
                                                 .ok(.json(["status": "OK"]))])
        let client = try makeClient(transport)
        struct Ping: Decodable { var status: String }
        let ping = try await client.get(Ping.self, path: "/system/ping", useETag: false)
        XCTAssertEqual(ping.status, "OK")
        XCTAssertEqual(transport.requestCount, 2)
    }

    func testAnEmptyFileListIsAnErrorNotAnEmptyAttachment() async throws {
        let transport = FakeUploadTransport(fallback: .ok(.json(["file_infos": []])))
        let client = try makeClient(transport)
        do {
            _ = try await client.uploadFile(ComposerUpload(filename: "a.png", mimeType: "image/png",
                                                           data: Data([1])),
                                            channelID: "chan-1") { _, _ in }
            XCTFail("a response with no file_infos must not be treated as a successful upload")
        } catch let error as MMError {
            guard case .malformedResponse = error else {
                return XCTFail("expected malformedResponse, got \(error)")
            }
        }
    }

    // MARK: - The autocomplete endpoints

    func testTheMentionQueryCarriesTheChannelAndTeamRestriction() async throws {
        // The envelope is `{"users": [...]}` — a bare array is what the server does *not* answer, and
        // the live app showed no names at all until this matched (T35ComposerAPITests pins the shape
        // on its own; this keeps the query assertion next to it).
        let transport = FakeAPITransport(repeating: .json(["users": [
            ["id": "u1", "username": "kim", "first_name": "Kim", "last_name": "Park",
             "delete_at": 0, "update_at": 1]
        ]]))
        let client = try makeClient(transport)
        let users = try await client.autocompleteUsers(term: "ki", inChannel: "chan-1",
                                                       inTeam: "team-1", limit: 20)
        XCTAssertEqual(users.map(\.username), ["kim"])
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url.path, "/api/v4/users/autocomplete")
        XCTAssertEqual(queryValue(request, "name"), "ki")
        // The documented membership restriction: the server returns people who can read the channel.
        XCTAssertEqual(queryValue(request, "in_channel_id"), "chan-1")
        XCTAssertEqual(queryValue(request, "in_team_id"), "team-1")
        XCTAssertEqual(queryValue(request, "limit"), "20")
    }

    func testTheChannelSearchUsesTheTeamsEndpoint() async throws {
        let transport = FakeAPITransport(repeating: .json([
            ["id": "c1", "name": "town-square", "display_name": "Town Square", "type": "O"]
        ]))
        let client = try makeClient(transport)
        let channels = try await client.searchChannels(teamID: "team-1", term: "town", limit: 20)
        XCTAssertEqual(channels.first?.name, "town-square")
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url.path, "/api/v4/teams/team-1/channels/search")
        // POST with the term in the body: the GET form of this path answers 404 on 9.11.19.
        XCTAssertEqual(request.method, .post)
        let body = try XCTUnwrap(request.body)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["term"] as? String, "town")
    }

    func testTheMemberPageIsCappedToWhatTheServerAccepts() async throws {
        let transport = FakeAPITransport(repeating: .json([
            ["channel_id": "c1", "user_id": "u1"]
        ]))
        let client = try makeClient(transport)
        let members = try await client.channelMembers(channelID: "c1", page: 2, perPage: 5000)
        XCTAssertEqual(members.first?.userId, "u1")
        XCTAssertEqual(queryValue(transport.lastRequest, "page"), "2")
        XCTAssertEqual(queryValue(transport.lastRequest, "per_page"), "200")
    }
}
