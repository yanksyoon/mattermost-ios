import XCTest
@testable import Mattermost
import Foundation

// MARK: - ServerURLValidator (port of ServerHub.handleServerURLValidation)

final class ServerURLValidatorTests: XCTestCase {

    /// Configure the mock to answer a live Mattermost server: ping 200, config 200 with the given
    /// SiteName/SiteURL.
    private func stubLiveServer(siteName: String, siteURL: String, version: String = "9.1.0") {
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/v4/system/ping" {
                return self.textResponse(#"{"status":"OK"}"#, status: 200)
            }
            if request.url?.path == "/api/v4/config/client" {
                let body = "{\"Version\":\"\(version)\",\"SiteURL\":\"\(siteURL)\",\"SiteName\":\"\(siteName)\",\"HelpLink\":\"/help\",\"ReportAProblemLink\":\"report\"}"
                return self.textResponse(body, status: 200)
            }
            return self.textResponse("not found", status: 404)
        }
    }

    private func validator(with lookup: @escaping (URL) -> ServerConfig? = { _ in nil }) -> ServerURLValidator {
        ServerURLValidator(api: ServerAPI(session: mockSession()),
                           existingServerLookup: lookup)
    }

    func testValidServerReturnsOKWithNameProbe() async {
        stubLiveServer(siteName: "My Team", siteURL: "https://mm.example")
        defer { MockURLProtocol.handler = nil }

        let result = await validator().validate(rawURL: "https://mm.example", currentServerID: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.serverName, "My Team")       // name probe auto-fills the display name
        XCTAssertEqual(result.serverVersion, "9.1.0")
        XCTAssertEqual(result.validatedURL, "https://mm.example")
    }

    func testGenericMattermostNameDefaultsToHostLabel() async {
        // Desktop: siteName === 'Mattermost' -> use remoteURL.host.split('.')[0]
        stubLiveServer(siteName: "Mattermost", siteURL: "https://community.mattermost.com")
        defer { MockURLProtocol.handler = nil }

        let result = await validator().validate(rawURL: "community.mattermost.com", currentServerID: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.serverName, "community")
        XCTAssertEqual(result.validatedURL, "https://community.mattermost.com")
    }

    func testMissingURL() async {
        defer { MockURLProtocol.handler = nil }
        let result = await validator().validate(rawURL: "   ", currentServerID: nil)
        XCTAssertEqual(result.status, .missing)
    }

    func testInvalidURL() async {
        defer { MockURLProtocol.handler = nil }
        let result = await validator().validate(rawURL: "ht tp://", currentServerID: nil)
        XCTAssertEqual(result.status, .invalid)
    }

    func testOptions() async {
        // Exercise toggling the ignoreScheme flag through lookup on a configured host.
        let config = ServerConfig(name: "X", url: URL(string: "https://mm.example")!)
        var lookupCalled = false
        let result = await validator { url in
            lookupCalled = true
            return url.host == "mm.example" ? config : nil
        }.validate(rawURL: "https://mm.example", currentServerID: nil)
        XCTAssertTrue(lookupCalled)
        XCTAssertEqual(result.status, .urlExists)
        XCTAssertEqual(result.existingServerName, "X")
    }

    func testServerNotFoundForCurrentIDExemptedFromDuplicate() async {
        // When editing a server, that same server's URL must not be flagged as a duplicate.
        let config = ServerConfig(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                                  name: "X", url: URL(string: "https://mm.example")!)
        stubLiveServer(siteName: "My Team", siteURL: "https://mm.example")
        defer { MockURLProtocol.handler = nil }

        let result = await validator { $0.host == "mm.example" ? config : nil }
            .validate(rawURL: "https://mm.example", currentServerID: config.id)
        XCTAssertEqual(result.status, .ok) // same id -> not a duplicate
    }

    func testNotMattermostWhenProbeReturnsHTML() async {
        MockURLProtocol.handler = { _ in
            self.textResponse("<html>nope</html>", status: 200)
        }
        defer { MockURLProtocol.handler = nil }

        let result = await validator().validate(rawURL: "https://notmattermost.example", currentServerID: nil)
        XCTAssertEqual(result.status, .notMattermost)
    }

    func testHTTPSUpgradeFallsBackToHTTPInsecure() async {
        // https fails to connect; http responds with a live config -> desktop reports INSECURE.
        MockURLProtocol.handler = { request in
            if request.url?.scheme == "https" {
                return self.textResponse("https refused", status: 500)
            }
            if request.url?.path == "/api/v4/system/ping" {
                return self.textResponse(#"{"status":"OK"}"#, status: 200)
            }
            let body = "{\"Version\":\"9.1.0\",\"SiteURL\":\"http://mm.example\",\"SiteName\":\"Team\",\"HelpLink\":\"/help\",\"ReportAProblemLink\":\"report\"}"
            return self.textResponse(body, status: 200)
        }
        defer { MockURLProtocol.handler = nil }

        let result = await validator().validate(rawURL: "http://mm.example", currentServerID: nil)
        XCTAssertEqual(result.status, .insecure)
        XCTAssertEqual(result.validatedURL, "http://mm.example")
    }

    func testPreAuthRequiredOn403() async {
        MockURLProtocol.handler = { _ in
            self.textResponse("forbidden", status: 403, headers: ["x-reject-reason": "pre-auth"])
        }
        defer { MockURLProtocol.handler = nil }

        let result = await validator().validate(rawURL: "https://mmauth.example", currentServerID: nil)
        XCTAssertEqual(result.status, .preAuthRequired)
    }

    func testBasicAuthRequiredOn401() async {
        MockURLProtocol.handler = { _ in
            self.textResponse("unauthorized", status: 401, headers: ["www-authenticate": "Basic realm=\"x\""])
        }
        defer { MockURLProtocol.handler = nil }

        let result = await validator().validate(rawURL: "https://mmba.example", currentServerID: nil)
        XCTAssertEqual(result.status, .basicAuthRequired)
    }

    func testURLNotMatchedWhenSiteURLDiffersAndUnreachable() async {
        // live config replies with a SiteURL different from the typed URL, and that SiteURL is
        // unreachable -> URL_NOT_MATCHED
        stubLiveServer(siteName: "Team", siteURL: "https://real.example")
        // Make the siteURL probe fail: stubLiveServer's handler returns 404 for unknown paths but
        // ping+config for the NEW url also need to fail. Override after stubbing.
        MockURLProtocol.handler = { request in
            if request.url?.host == "real.example" { return self.textResponse("down", status: 500) }
            if request.url?.path == "/api/v4/system/ping" {
                return self.textResponse(#"{"status":"OK"}"#, status: 200)
            }
            return self.textResponse("{\"Version\":\"9.1.0\",\"SiteURL\":\"https://real.example\",\"SiteName\":\"Team\",\"HelpLink\":\"/help\",\"ReportAProblemLink\":\"report\"}", status: 200)
        }
        defer { MockURLProtocol.handler = nil }

        let result = await validator().validate(rawURL: "https://someone.example", currentServerID: nil)
        XCTAssertEqual(result.status, .urlNotMatched)
    }

    func testURLUpdatedAdoptsConfiguredSiteURL() async {
        // config reports a SiteURL that IS reachable and differs -> desktop fixes the URL for us.
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/v4/system/ping" {
                return self.textResponse(#"{"status":"OK"}"#, status: 200)
            }
            if request.url?.path == "/api/v4/config/client" {
                // report the canonical URL regardless of which host was probed
                return self.textResponse("{\"Version\":\"9.1.0\",\"SiteURL\":\"https://canonical.example\",\"SiteName\":\"Team\",\"HelpLink\":\"/help\",\"ReportAProblemLink\":\"report\"}", status: 200)
            }
            return self.textResponse("not found", status: 404)
        }
        defer { MockURLProtocol.handler = nil }

        let result = await validator().validate(rawURL: "https://canonical.example", currentServerID: nil)
        XCTAssertEqual(result.status, .ok) // typed == siteURL -> OK, not URLUpdated
        XCTAssertEqual(result.validatedURL, "https://canonical.example")
    }

    // MARK: parseURL port

    func testParseURLCollapsesDoubleSlashesInPath() throws {
        let url = try XCTUnwrap(ServerURLValidator.parseURL("https://a.example//team//main"))
        XCTAssertEqual(url.path, "/team/main")
    }

    func testParseURLRejectsNul() {
        XCTAssertNil(ServerURLValidator.parseURL("https://a.example/%00"))
        XCTAssertNil(ServerURLValidator.parseURL("https://a.example/\0frag"))
    }

    func testParseURLRejectsTooLong() {
        let long = "https://a.example/" + String(repeating: "x", count: 9_000)
        XCTAssertNil(ServerURLValidator.parseURL(long))
    }
}

// MARK: - ServerStore.lookupServer (parity lookupServerByURL)

final class ServerStoreLookupTests: XCTestCase {

    private func makeStore() -> ServerStore {
        let suiteName = "ServerStoreLookup-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ServerStore(preferences: AppPreferences(defaults: defaults))
    }

    func testLookupMatchesSameHostIgnoringScheme() {
        let store = makeStore()
        _ = store.add(ServerConfig(name: "A", url: URL(string: "https://a.example")!))
        let hit = store.lookupServer(by: URL(string: "http://a.example")!, ignoringScheme: true)
        XCTAssertEqual(hit?.url.host, "a.example")
    }

    func testLookupRespectsSchemeWhenNotIgnored() {
        let store = makeStore()
        _ = store.add(ServerConfig(name: "A", url: URL(string: "https://a.example")!))
        XCTAssertNil(store.lookupServer(by: URL(string: "http://a.example")!,
                                        ignoringScheme: false))
        XCTAssertNotNil(store.lookupServer(by: URL(string: "https://a.example")!,
                                           ignoringScheme: false))
    }

    func testLookupMatchesPathUnderServerRoot() {
        let store = makeStore()
        _ = store.add(ServerConfig(name: "A", url: URL(string: "https://a.example/team")!))
        let inner = store.lookupServer(by: URL(string: "https://a.example/team/main")!,
                                       ignoringScheme: true)
        XCTAssertEqual(inner?.name, "A")
        let other = store.lookupServer(by: URL(string: "https://a.example/other")!,
                                       ignoringScheme: true)
        XCTAssertNil(other)
    }
}

// MARK: - ServerFormModel (form validation state)

@MainActor
final class ServerFormModelTests: XCTestCase {

    private func stubLiveServer() {
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/v4/system/ping" {
                return self.textResponse(#"{"status":"OK"}"#, status: 200)
            }
            let body = "{\"Version\":\"9.1.0\",\"SiteURL\":\"https://mm.example\",\"SiteName\":\"Acme\",\"HelpLink\":\"/help\",\"ReportAProblemLink\":\"report\"}"
            return self.textResponse(body, status: 200)
        }
    }

    func testValidateCurrentAutoFillsNameAndAllowsSave() async {
        stubLiveServer()
        defer { MockURLProtocol.handler = nil }

        let model = ServerFormModel(validator: ServerURLValidator(api: ServerAPI(session: mockSession())))
        model.name = ""
        model.urlText = "https://mm.example"
        await model.validateCurrent()

        XCTAssertEqual(model.validationResult?.status, .ok)
        XCTAssertEqual(model.suggestedName, "Acme")
        XCTAssertEqual(model.name, "Acme")        // auto-filled from the name probe
        XCTAssertTrue(model.canSave)
        XCTAssertFalse(model.isURLBlocked)
    }

    func testSaveBlockedWhenURLMissingOrInvalid() async {
        defer { MockURLProtocol.handler = nil }
        let model = ServerFormModel(validator: ServerURLValidator(api: ServerAPI(session: mockSession())))
        model.name = "Acme"

        model.urlText = ""
        await model.validateCurrent()
        XCTAssertEqual(model.validationResult?.status, .missing)
        XCTAssertTrue(model.isURLBlocked)
        XCTAssertFalse(model.canSave)

        model.urlText = "ht tp://"
        await model.validateCurrent()
        XCTAssertEqual(model.validationResult?.status, .invalid)
        XCTAssertTrue(model.isURLBlocked)
        XCTAssertFalse(model.canSave)
    }

    func testSaveBlockedUntilNameProvided() async {
        stubLiveServer()
        defer { MockURLProtocol.handler = nil }

        let model = ServerFormModel(validator: ServerURLValidator(api: ServerAPI(session: mockSession())))
        model.urlText = "https://mm.example"
        await model.validateCurrent()
        // Auto-fill provides a name, so force it empty to test the name gate.
        model.name = "   "
        XCTAssertFalse(model.canSave)
        model.name = "Acme"
        XCTAssertTrue(model.canSave)
    }

    func testURLMessageTextForStates() async {
        defer { MockURLProtocol.handler = nil }
        let model = ServerFormModel(validator: ServerURLValidator(api: ServerAPI(session: mockSession())))

        model.urlText = ""
        await model.validateCurrent()
        XCTAssertEqual(model.urlMessage?.tone, .error)

        XCTAssertTrue(model.canSave == false)
    }
}