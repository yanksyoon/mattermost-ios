import XCTest
@testable import Mattermost
import Foundation

/// A stubbable `URLProtocol` so ServerAPI/ServerInfo/ServerURLValidator tests run entirely offline.
/// Set `MockURLProtocol.handler` before each request; it receives the URLRequest and returns the
/// `(HTTPURLResponse, Data)` to hand back (or throws to simulate a transport failure).
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension XCTestCase {
    /// Ephemeral URLSession whose traffic is answered by MockURLProtocol.
    func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    func jsonResponse(_ object: Any, status: Int, headers: [String: String] = [:]) throws -> (HTTPURLResponse, Data) {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        let http = HTTPURLResponse(
            url: URL(string: "http://mattermost.example")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
        return (http, data)
    }

    func textResponse(_ text: String, status: Int, headers: [String: String] = [:]) -> (HTTPURLResponse, Data) {
        let http = HTTPURLResponse(
            url: URL(string: "http://mattermost.example")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
        return (http, Data(text.utf8))
    }
}

// MARK: - ServerAPI (serverAPI.ts port)

final class ServerAPITests: XCTestCase {

    func testGetReturnsBodyOn200() async throws {
        MockURLProtocol.handler = { _ in
            self.textResponse(#"{"status":"OK"}"#, status: 200)
        }
        defer { MockURLProtocol.handler = nil }

        let api = ServerAPI(session: mockSession())
        let response = try await api.get(url: URL(string: "https://a.example/api/v4/system/ping")!)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(response.body.contains("status"))
        XCTAssertEqual(response.errorReason, ServerAPI.ErrorReason())
    }

    func testGetDetectsPreAuthOn403() async throws {
        MockURLProtocol.handler = { _ in
            self.textResponse("forbidden", status: 403, headers: ["x-reject-reason": "pre-auth"])
        }
        defer { MockURLProtocol.handler = nil }

        let api = ServerAPI(session: mockSession())
        let response = try await api.get(url: URL(string: "https://a.example/api/v4/system/ping")!)
        XCTAssertEqual(response.statusCode, 403)
        XCTAssertTrue(response.errorReason.needsPreAuth)
    }

    func testGetDetectsBasicAuthOn401() async throws {
        MockURLProtocol.handler = { _ in
            self.textResponse("unauthorized", status: 401, headers: ["www-authenticate": "Basic realm=\"x\""])
        }
        defer { MockURLProtocol.handler = nil }

        let api = ServerAPI(session: mockSession())
        let response = try await api.get(url: URL(string: "https://a.example/api/v4/system/ping")!)
        XCTAssertEqual(response.statusCode, 401)
        XCTAssertTrue(response.errorReason.needsBasicAuth)
    }

    func testGetThrowsOnClientCertRequired() async {
        MockURLProtocol.handler = { _ in
            throw NSError(domain: NSURLErrorDomain,
                          code: NSURLErrorClientCertificateRequired,
                          userInfo: [NSLocalizedDescriptionKey: "client cert"])
        }
        defer { MockURLProtocol.handler = nil }

        let api = ServerAPI(session: mockSession())
        do {
            _ = try await api.get(url: URL(string: "https://a.example/")!)
            XCTFail("expected clientCertRequired error")
        } catch let err as ServerAPI.APIError {
            guard case .clientCertRequired = err else {
                return XCTFail("expected .clientCertRequired, got \(err)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}

// MARK: - ServerInfo (serverInfo.ts port)

final class ServerInfoTests: XCTestCase {
    private let base = URL(string: "https://community.mattermost.com")!

    func testPingSucceedsOn200() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v4/system/ping")
            return self.textResponse(#"{"status":"OK"}"#, status: 200)
        }
        defer { MockURLProtocol.handler = nil }

        let info = ServerInfo(baseURL: base, api: ServerAPI(session: mockSession()))
        try await info.pingServer() // must not throw
    }

    func testPingThrowsOnNon200() async {
        MockURLProtocol.handler = { _ in
            self.textResponse("down", status: 503)
        }
        defer { MockURLProtocol.handler = nil }

        let info = ServerInfo(baseURL: base, api: ServerAPI(session: mockSession()))
        do {
            try await info.pingServer()
            XCTFail("expected badStatus error")
        } catch let e as ServerProbeError {
            guard case .badStatus = e else { return XCTFail("expected .badStatus, got \(e)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testFetchConfigDataDecodesNameProbe() async throws {
        let body = """
        {"Version":"9.1.0","SiteURL":"https://community.mattermost.com","SiteName":"Community","HelpLink":"/help","ReportAProblemLink":"report"}
        """
        var hitConfigPath = false
        MockURLProtocol.handler = { request in
            hitConfigPath = request.url?.path == "/api/v4/config/client"
                && request.url?.query == "format=old"
            return self.textResponse(body, status: 200)
        }
        defer { MockURLProtocol.handler = nil }

        let info = ServerInfo(baseURL: base, api: ServerAPI(session: mockSession()))
        let remote = try await info.fetchConfigData()
        XCTAssertTrue(hitConfigPath)
        XCTAssertEqual(remote.siteName, "Community")
        XCTAssertEqual(remote.serverVersion, "9.1.0")
        XCTAssertEqual(remote.siteURL, "https://community.mattermost.com")
    }

    func testFetchConfigDataThrowsNotMattermostOnJunkBody() async {
        MockURLProtocol.handler = { _ in
            self.textResponse("<html>not mattermost</html>", status: 200)
        }
        defer { MockURLProtocol.handler = nil }

        let info = ServerInfo(baseURL: base, api: ServerAPI(session: mockSession()))
        do {
            _ = try await info.fetchConfigData()
            XCTFail("expected notMattermost error")
        } catch let e as ServerProbeError {
            guard case .notMattermost = e else { return XCTFail("expected .notMattermost, got \(e)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}