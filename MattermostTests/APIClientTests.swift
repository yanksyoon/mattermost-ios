import Foundation
import XCTest
@testable import Mattermost

/// T28 acceptance criteria for the REST v4 client, all against `FakeAPITransport` (no network):
/// success, 401, 403, 404, 429 + `Retry-After`, timeout, malformed JSON, 5xx, ETag/304,
/// pagination cursor round-trips, per-server base URLs and the retry/backoff policy.
final class APIClientTests: XCTestCase {

    private let serverURL = URL(string: "https://mm.example.com")!

    // MARK: - Helpers

    private func makeClient(_ transport: FakeAPITransport,
                            server: URL? = nil,
                            token: String? = "test-token",
                            retryPolicy: APIClient.RetryPolicy = APIClient.RetryPolicy(
                                maxAttempts: 3, baseDelay: 0.5, maxDelay: 20, jitterRatio: 0),
                            delays: ((TimeInterval) -> Void)? = nil) throws -> APIClient {
        try APIClient(serverURL: server ?? serverURL,
                      transport: transport,
                      retryPolicy: retryPolicy,
                      tokenProvider: { token },
                      sleep: { seconds in delays?(seconds) },
                      random: { 0 })
    }

    private func userJSON(id: String = "u1", username: String = "ada") -> [String: Any] {
        ["id": id, "username": username, "email": "ada@example.com",
         "first_name": "Ada", "last_name": "Lovelace", "nickname": "ada",
         "delete_at": 0, "update_at": 1_700_000_000_000]
    }

    private func postListJSON(order: [String]) -> [String: Any] {
        var posts: [String: Any] = [:]
        for id in order {
            posts[id] = ["id": id, "message": "hello \(id)", "create_at": 100,
                         "update_at": 100, "delete_at": 0, "user_id": "u1",
                         "channel_id": "c1", "root_id": ""]
        }
        return ["order": order, "posts": posts,
                "next_post_id": order.last ?? "", "prev_post_id": order.first ?? ""]
    }

    // MARK: - Success + auth headers

    func testSuccessDecodesTypedResponseAndSkipsAuthForPing() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.json(["status": "OK", "version": "9.11.19"]))])
        let client = try makeClient(transport)
        let pong = try await client.ping()
        XCTAssertEqual(pong.status, "OK")
        XCTAssertEqual(pong.version, "9.11.19")
        XCTAssertEqual(transport.lastRequest?.url.absoluteString,
                       "https://mm.example.com/api/v4/system/ping")
        XCTAssertNil(transport.lastRequest?.headers["Authorization"],
                     "an unauthenticated probe must not carry the bearer token")
    }

    func testAuthenticatedRequestCarriesBearerAndRequestedWith() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.json(userJSON()))])
        let client = try makeClient(transport, token: "tok-123")
        let me = try await client.currentUser()
        XCTAssertEqual(me.username, "ada")
        XCTAssertEqual(transport.lastRequest?.headers["Authorization"], "Bearer tok-123")
        XCTAssertEqual(transport.lastRequest?.headers["X-Requested-With"], "XMLHttpRequest")
        XCTAssertEqual(transport.lastRequest?.headers["Accept"], "application/json")
    }

    func testMissingTokenFailsWithoutSendingARequest() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.json(userJSON()))])
        let client = try makeClient(transport, token: nil)
        do {
            _ = try await client.currentUser()
            XCTFail("expected .notSignedIn")
        } catch {
            XCTAssertEqual(error as? MMError, .notSignedIn)
        }
        XCTAssertEqual(transport.requestCount, 0)
    }

    // MARK: - Typed error mapping

    func testUnauthorizedSurfacesReauthAndThrowsTypedError() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(["id": "api.context.session_expired.app_error",
                       "message": "Invalid or expired session, please login again.",
                       "status_code": 401], status: 401))
        ])
        let client = try makeClient(transport)
        var reauthFired = 0
        client.onUnauthorized = { reauthFired += 1 }
        do {
            _ = try await client.currentUser()
            XCTFail("expected .unauthorized")
        } catch {
            XCTAssertEqual(error as? MMError,
                           .unauthorized(message: "Invalid or expired session, please login again."))
        }
        XCTAssertEqual(reauthFired, 1, "401 must surface re-auth exactly once")
        XCTAssertEqual(transport.requestCount, 1, "a 401 is not retried")
    }

    func testForbiddenIsTyped() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(["id": "api.context.permissions.app_error", "message": "Forbidden"], status: 403))
        ])
        let client = try makeClient(transport)
        do {
            _ = try await client.currentUser()
            XCTFail("expected .forbidden")
        } catch {
            XCTAssertEqual(error as? MMError, .forbidden(message: "Forbidden"))
        }
    }

    func testNotFoundIsTypedAndNotRetried() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.status(404))])
        let client = try makeClient(transport)
        do {
            _ = try await client.currentUser()
            XCTFail("expected .notFound")
        } catch {
            XCTAssertEqual(error as? MMError, .notFound)
        }
        XCTAssertEqual(transport.requestCount, 1)
    }

    // MARK: - 429 / Retry-After

    func testRateLimitedHonoursRetryAfterThenSucceeds() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(["message": "Too many requests"], status: 429, headers: ["Retry-After": "2"])),
            .ok(.json(userJSON()))
        ])
        var delays: [TimeInterval] = []
        let client = try makeClient(transport, delays: { delays.append($0) })
        let me = try await client.currentUser()
        XCTAssertEqual(me.id, "u1")
        XCTAssertEqual(delays, [2], "the server's Retry-After wins over the computed backoff")
        XCTAssertEqual(transport.requestCount, 2)
    }

    func testRateLimitedExhaustionSurfacesRetryAfter() async throws {
        let transport = FakeAPITransport(repeating: .json(["message": "Too many requests"],
                                                          status: 429,
                                                          headers: ["Retry-After": "3"]))
        let client = try makeClient(transport)
        do {
            _ = try await client.currentUser()
            XCTFail("expected .rateLimited")
        } catch {
            XCTAssertEqual(error as? MMError, .rateLimited(retryAfter: 3))
        }
        XCTAssertEqual(transport.requestCount, 3, "maxAttempts attempts, then give up")
    }

    /// T28-AV F4: a hostile `Retry-After: 86400` must not park the app for a day. The **sleep** is
    /// clamped to `maxDelay`; the thrown error keeps the server's exact value for the UI.
    func testAbsurdRetryAfterIsClampedForTheSleepAndKeptInTheError() async throws {
        let transport = FakeAPITransport(repeating: .json(["message": "Too many requests"],
                                                          status: 429,
                                                          headers: ["Retry-After": "86400"]))
        var delays: [TimeInterval] = []
        let client = try makeClient(transport,
                                    retryPolicy: APIClient.RetryPolicy(maxAttempts: 2,
                                                                       baseDelay: 0.5,
                                                                       maxDelay: 20,
                                                                       jitterRatio: 0),
                                    delays: { delays.append($0) })
        do {
            _ = try await client.currentUser()
            XCTFail("expected .rateLimited")
        } catch {
            XCTAssertEqual(error as? MMError, .rateLimited(retryAfter: 86400),
                           "the server's value survives in the typed error")
        }
        XCTAssertEqual(delays, [20], "the slept delay is clamped to RetryPolicy.maxDelay")
        XCTAssertTrue(delays.allSatisfy { $0 <= 20 })
        XCTAssertEqual(transport.requestCount, 2)
    }

    func testRetryAfterHTTPDateIsParsed() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let date = now.addingTimeInterval(7)
        let response = APIResponse.status(429, headers: ["Retry-After": formatter.string(from: date)])
        let retryAfter = try XCTUnwrap(APIClient.retryAfter(from: response, now: now))
        XCTAssertEqual(retryAfter, 7, accuracy: 0.001)
    }

    // MARK: - 5xx / timeout

    func testServerErrorIsRetriedWithExponentialBackoffThenSucceeds() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(["message": "boom"], status: 503)),
            .ok(.json(["message": "boom"], status: 500)),
            .ok(.json(userJSON()))
        ])
        var delays: [TimeInterval] = []
        let client = try makeClient(transport, delays: { delays.append($0) })
        _ = try await client.currentUser()
        XCTAssertEqual(delays, [0.5, 1.0], "exponential: base, base*2")
        XCTAssertEqual(transport.requestCount, 3)
    }

    func testServerErrorAfterExhaustionIsTyped() async throws {
        let transport = FakeAPITransport(repeating: .json(["message": "database is down"], status: 500))
        let client = try makeClient(transport)
        do {
            _ = try await client.currentUser()
            XCTFail("expected .server")
        } catch {
            XCTAssertEqual(error as? MMError, .server(status: 500, message: "database is down"))
        }
        XCTAssertEqual(transport.requestCount, 3)
    }

    func testTimeoutIsRetriedThenSurfacesTypedTimeout() async throws {
        let transport = FakeAPITransport(repeatingError: APITransportError.timeout)
        let client = try makeClient(transport)
        do {
            _ = try await client.currentUser()
            XCTFail("expected .timeout")
        } catch {
            XCTAssertEqual(error as? MMError, .timeout)
        }
        XCTAssertEqual(transport.requestCount, 3)
    }

    func testOfflineIsRetriedAndSurfacedAsTypedOffline() async throws {
        let transport = FakeAPITransport(repeatingError: APITransportError.offline)
        let client = try makeClient(transport)
        do {
            _ = try await client.currentUser()
            XCTFail("expected .offline")
        } catch {
            XCTAssertEqual(error as? MMError, .offline)
        }
    }

    func testCertificateFailureIsNotRetried() async throws {
        let transport = FakeAPITransport(repeatingError: APITransportError.certificateUntrusted(origin: "https://mm.example.com"))
        let client = try makeClient(transport)
        do {
            _ = try await client.currentUser()
            XCTFail("expected .certificateUntrusted")
        } catch {
            XCTAssertEqual(error as? MMError, .certificateUntrusted(origin: "https://mm.example.com"))
        }
        XCTAssertEqual(transport.requestCount, 1, "trust has to be decided before any retry")
    }

    // MARK: - Malformed payloads

    func testMalformedJSONIsTypedWithoutLeakingTheBody() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.text("{not-json", status: 200))])
        let client = try makeClient(transport)
        do {
            _ = try await client.ping()
            XCTFail("expected .malformedResponse")
        } catch let error as MMError {
            guard case .malformedResponse(let detail) = error else {
                return XCTFail("expected .malformedResponse, got \(error)")
            }
            XCTAssertTrue(detail.contains("MMPing"), "the error names the type, not the payload")
            XCTAssertFalse(detail.contains("not-json"), "the raw body must not be embedded")
        }
    }

    func testPostWithNonDecodableBodyThrowsMalformedResponse() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.text("[]", status: 200))])
        let client = try makeClient(transport)
        do {
            _ = try await client.post(MMUser.self, path: "/users/login", body: ["login_id": "ada"])
            XCTFail("expected .malformedResponse")
        } catch let error as MMError {
            guard case .malformedResponse = error else {
                return XCTFail("expected .malformedResponse, got \(error)")
            }
        }
    }

    // MARK: - ETag / If-None-Match

    func testConditionalGetSendsIfNoneMatchAndReplaysCachedBodyOn304() async throws {
        let etag = "\"7f1c2\""
        let transport = FakeAPITransport(stubs: [
            .ok(.json(userJSON(), status: 200, headers: ["Etag": etag])),
            .ok(.status(304))
        ])
        let client = try makeClient(transport)

        let first = try await client.currentUser()
        XCTAssertEqual(first.id, "u1")
        XCTAssertNil(transport.requests[0].headers["If-None-Match"],
                     "the first GET has no validator yet")

        let second = try await client.currentUser()
        XCTAssertEqual(second, first, "a 304 replays the cached body")
        XCTAssertEqual(transport.requests[1].headers["If-None-Match"], etag)
        XCTAssertEqual(transport.requestCount, 2)
    }

    func testConditionalGetIsNotUsedForWrites() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(userJSON(), status: 200, headers: ["Etag": "\"abc\""])),
            .ok(.json(["status": "OK"]))
        ])
        let client = try makeClient(transport)
        _ = try await client.currentUser()
        _ = try await client.postForResponse(path: "/users/logout", body: nil)
        XCTAssertNil(transport.requests[1].headers["If-None-Match"],
                     "If-None-Match belongs on GET only")
        XCTAssertEqual(transport.requests[1].method, .post)
    }

    func testPostEncodesBodyWithJSONContentType() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.json([userJSON()]))])
        let client = try makeClient(transport)
        _ = try await client.users(ids: ["u1", "u2"])
        XCTAssertEqual(transport.lastRequest?.method, .post)
        XCTAssertEqual(transport.lastRequest?.headers["Content-Type"], "application/json; charset=utf-8")
        XCTAssertEqual(String(data: transport.lastRequest?.body ?? Data(), encoding: .utf8),
                       "[\"u1\",\"u2\"]")
    }

    // MARK: - Pagination cursors

    func testPageCursorRoundTripsIntoBeforeAfterQueries() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(postListJSON(order: ["p30", "p29", "p28"]))),
            .ok(.json(postListJSON(order: ["p27", "p26", "p25"]))),
            .ok(.json(postListJSON(order: ["p31"])))
        ])
        let client = try makeClient(transport)

        let firstPage = try await client.posts(channelID: "c1", page: .first(perPage: 60))
        XCTAssertEqual(firstPage.order, ["p30", "p29", "p28"])
        XCTAssertEqual(queryValue(transport.requests[0], "page"), "0")
        XCTAssertEqual(queryValue(transport.requests[0], "per_page"), "60")
        XCTAssertEqual(transport.requests[0].url.path, "/api/v4/channels/c1/posts")

        // Older page: the oldest id the server just returned becomes the `before` cursor.
        let older = try XCTUnwrap(MMPostPage.first(perPage: 60).nextOlderPage(from: firstPage))
        XCTAssertEqual(older.cursor, .before("p28"))
        let secondPage = try await client.posts(channelID: "c1", page: older)
        XCTAssertEqual(secondPage.order.first, "p27")
        XCTAssertEqual(queryValue(transport.requests[1], "before"), "p28")
        XCTAssertEqual(queryValue(transport.requests[1], "per_page"), "60")
        XCTAssertNil(queryValue(transport.requests[1], "page"))

        // Newer page (catching up after a gap): newest id becomes the `after` cursor.
        let newer = try XCTUnwrap(older.nextNewerPage(from: secondPage))
        XCTAssertEqual(newer.cursor, .after("p27"))
        _ = try await client.posts(channelID: "c1", page: newer)
        XCTAssertEqual(queryValue(transport.requests[2], "after"), "p27")
    }

    func testPaginationStopsWhenServerSaysNoMore() {
        let exhausted = MMPostList(order: ["p1"], posts: [:], nextPostID: "", prevPostID: "", hasNext: false)
        XCTAssertNil(MMPostPage.first().nextOlderPage(from: exhausted))
        let empty = MMPostList(order: [], posts: [:], nextPostID: "", prevPostID: "")
        XCTAssertNil(MMPostPage.first().nextOlderPage(from: empty))
    }

    func testPageCursorClampsPerPageToTheServerMaximum() {
        let page = MMPostPage(cursor: .page(2), perPage: 500)
        let items = page.queryItems
        XCTAssertEqual(items.first { $0.name == "per_page" }?.value, "200",
                       "the API silently truncates above 200; the client asks for a legal page")
        XCTAssertEqual(items.first { $0.name == "page" }?.value, "2")
    }

    func testSinceCursorIsMilliseconds() {
        let page = MMPostPage(cursor: .since(1_700_000_000_123), perPage: 60)
        XCTAssertEqual(page.queryItems.first { $0.name == "since" }?.value, "1700000000123")
    }

    // MARK: - Per-server base URL resolution

    func testSubPathServerKeepsItsBasePath() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.json(userJSON()))])
        let client = try makeClient(transport,
                                    server: URL(string: "https://corp.example.com/company/mattermost")!)
        _ = try await client.currentUser()
        XCTAssertEqual(transport.lastRequest?.url.absoluteString,
                       "https://corp.example.com/company/mattermost/api/v4/users/me")
    }

    func testExplicitPortIsPreserved() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.json(["status": "OK"]))])
        let client = try makeClient(transport, server: URL(string: "http://127.0.0.1:8065")!)
        _ = try await client.ping()
        XCTAssertEqual(transport.lastRequest?.url.absoluteString,
                       "http://127.0.0.1:8065/api/v4/system/ping")
    }

    // MARK: - Retry policy arithmetic

    func testBackoffIsExponentialAndCapped() {
        let policy = APIClient.RetryPolicy(maxAttempts: 8, baseDelay: 0.5, maxDelay: 5, jitterRatio: 0)
        XCTAssertEqual(policy.delay(forAttempt: 1, random: 0), 0.5, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(forAttempt: 2, random: 0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(forAttempt: 3, random: 0), 2.0, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(forAttempt: 4, random: 0), 4.0, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(forAttempt: 5, random: 0), 5.0, accuracy: 0.0001,
                       "capped at maxDelay")
        XCTAssertEqual(policy.delay(forAttempt: 20, random: 0), 5.0, accuracy: 0.0001)
    }

    func testBackoffJitterStaysWithinTheBand() {
        let policy = APIClient.RetryPolicy(maxAttempts: 3, baseDelay: 1, maxDelay: 100, jitterRatio: 0.25)
        XCTAssertEqual(policy.delay(forAttempt: 1, random: 0), 0.75, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(forAttempt: 1, random: 0.5), 1.0, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(forAttempt: 1, random: 0.999), 1.25, accuracy: 0.01)
    }
}
