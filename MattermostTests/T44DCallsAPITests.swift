// T44d — the two plugin facts the calls surface reads over REST, asserted at the byte level.
//
// The point of this file is that `CallsAPI` does **not** go through `/api/v4`: Calls' routes live at
// the server root (`/plugins/com.mattermost.calls/…`, measured on the fixture), and a client that
// prefixed them with `/api/v4` would 404 on every server while looking perfectly correct in review.

import Foundation
import XCTest
@testable import Mattermost

final class T44DCallsAPITests: XCTestCase {

    private let serverURL = URL(string: "https://mm.example.com")!

    private func makeClient(_ transport: FakeAPITransport) throws -> APIClient {
        try APIClient(serverURL: serverURL,
                      transport: transport,
                      retryPolicy: APIClient.RetryPolicy(maxAttempts: 1, baseDelay: 0,
                                                         maxDelay: 0, jitterRatio: 0),
                      tokenProvider: { "test-token" },
                      sleep: { _ in },
                      random: { 0 })
    }

    // MARK: - Version

    /// The measured body: `{"build": "936dd00…", "version": "0.29.8"}`.
    func testPluginVersionRequestGoesToTheServerRootAndParses() async throws {
        let transport = FakeAPITransport(repeating: .json(["build": "936dd00e", "version": "0.29.8"]))
        let client = try makeClient(transport)

        let version = try await client.callsPluginVersion()
        XCTAssertEqual(version, .v0_29_8)

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.url.absoluteString,
                       "https://mm.example.com/plugins/com.mattermost.calls/version")
        XCTAssertFalse(request.url.path.contains("/api/v4"), "a plugin route is not under /api/v4")
        XCTAssertEqual(request.headers["Authorization"] ?? request.headers["authorization"],
                       "Bearer test-token")
    }

    /// A server without the plugin 404s; the surface reads that as "no Calls here", not as a failure.
    func testMissingPluginSurfacesAsNotFound() async throws {
        let transport = FakeAPITransport(repeating: .json(["id": "not_found"], status: 404))
        let client = try makeClient(transport)
        do {
            _ = try await client.callsPluginVersion()
            XCTFail("expected notFound")
        } catch let error as MMError {
            XCTAssertEqual(error, .notFound)
        }
    }

    /// A non-semantic version string is a server problem, reported as a malformed response rather
    /// than silently becoming 0.0.0 (which would have flipped every gate the wrong way).
    func testNonSemanticVersionIsAMalformedResponse() async throws {
        let transport = FakeAPITransport(repeating: .json(["version": "unknown"]))
        let client = try makeClient(transport)
        do {
            _ = try await client.callsPluginVersion()
            XCTFail("expected malformedResponse")
        } catch let error as MMError {
            guard case .malformedResponse = error else {
                return XCTFail("expected malformedResponse, got \(error)")
            }
        }
    }

    // MARK: - Active call

    func testActiveCallProbeUsesTheChannelsOwnRoute() async throws {
        let transport = FakeAPITransport(repeating: .json(["active": true]))
        let client = try makeClient(transport)

        let active = try await client.callsCallIsActive(channelID: "chan1")
        XCTAssertTrue(active)
        XCTAssertEqual(try XCTUnwrap(transport.lastRequest).url.absoluteString,
                       "https://mm.example.com/plugins/com.mattermost.calls/calls/chan1/active")

        let idle = FakeAPITransport(repeating: .json(["active": false]))
        let idleActive = try await makeClient(idle).callsCallIsActive(channelID: "chan2")
        XCTAssertFalse(idleActive)
    }

    /// The route answers `{"active": bool}`; anything else is not a call, and must not crash the
    /// header that polls it.
    func testActiveCallProbeFailsOnAMalformedBody() async throws {
        let transport = FakeAPITransport(repeating: .json(["call": "yes"]))
        let client = try makeClient(transport)
        do {
            _ = try await client.callsCallIsActive(channelID: "chan1")
            XCTFail("expected a decode failure")
        } catch {
            XCTAssertFalse(error is MMError && error as? MMError == .notFound,
                           "a 200 with the wrong body is not \"no plugin\"")
        }
    }
}
