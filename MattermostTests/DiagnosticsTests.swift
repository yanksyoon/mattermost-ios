import XCTest
@testable import Mattermost
import Foundation

/// Deterministic system-status provider for diagnostics tests (no real notification center /
/// AVFoundation in unit tests).
final class FakeSystemStatusProvider: DiagnosticsSystemStatusProviding {
    var snapshot: PermissionsSnapshot
    init(snapshot: PermissionsSnapshot) { self.snapshot = snapshot }

    func permissionSnapshot(diagnosticsDirectory: URL) async -> PermissionsSnapshot {
        snapshot
    }
}

/// Deterministic cookie-session provider (sessionData) for diagnostics tests.
final class FakeSessionProvider: DiagnosticsSessionProviding {
    var snapshotFor: (ServerConfig) -> SessionDataSnapshot
    init(_ snapshotFor: @escaping (ServerConfig) -> SessionDataSnapshot = { _ in
        SessionDataSnapshot(hasUserID: false, hasCSRF: false, hasAuthToken: false)
    }) {
        self.snapshotFor = snapshotFor
    }

    func sessionData(for server: ServerConfig) async -> SessionDataSnapshot {
        snapshotFor(server)
    }
}

final class DiagnosticsTests: XCTestCase {

    private var suite: UserDefaults!
    private var diagDir: URL!
    private var crashDir: URL!

    override func setUpWithError() throws {
        suite = UserDefaults(suiteName: "diagnostics-tests-\(UUID().uuidString)")!
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        diagDir = base.appendingPathComponent("Diagnostics", isDirectory: true)
        crashDir = base.appendingPathComponent("CrashReports", isDirectory: true)
        try FileManager.default.createDirectory(at: diagDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: crashDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        MockURLProtocol.handler = nil
        let base = diagDir.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: base)
        suite.removePersistentDomain(forName: "diagnostics-tests")
    }

    // MARK: helpers

    private func makeContext(servers: [ServerConfig] = [],
                             status: PermissionsSnapshot? = nil,
                             sessionSnap: @escaping (ServerConfig) -> SessionDataSnapshot = { _ in
                                 SessionDataSnapshot(hasUserID: false, hasCSRF: false, hasAuthToken: false)
                             },
                             onlineEndpoint: URL = URL(string: "https://community.mattermost.com/api/v4/system/ping")!,
                             webStatuses: [WebViewStatusItem] = [],
                             session: URLSession? = nil) -> DiagnosticsContext {
        DiagnosticsContext(
            servers: servers,
            preferences: AppPreferences(defaults: suite),
            vault: SecureVault(serviceNamespace: "diag-tests-\(UUID().uuidString)"),
            settings: ShellSettingsSnapshot(
                themeSyncing: true,
                downloadHistoryLimit: 10,
                appLanguage: nil,
                logLevel: "info",
                appName: "Mattermost",
                appVersion: "0.1.0",
                buildNumber: "1"
            ),
            webViewStatuses: webStatuses,
            systemStatusProvider: status.map(FakeSystemStatusProvider.init) ?? FakeSystemStatusProvider(
                snapshot: PermissionsSnapshot(notificationsStatus: "not-determined",
                                              downloadsWritable: true,
                                              diagnosticsWritable: true,
                                              microphoneStatus: "not-determined",
                                              cameraStatus: "not-determined")
            ),
            sessionProvider: FakeSessionProvider(sessionSnap),
            session: session ?? .shared,
            onlineEndpoint: onlineEndpoint,
            diagnosticsDirectory: diagDir,
            crashReportsDirectory: crashDir
        )
    }

    // MARK: - Step set reconciliation

    /// The desktop `steps/` dir registers step0..step11 (twelve real steps). The template and
    /// internal helpers are NOT steps. This test pins the exact names + order.
    func testStepEnumerationMatchesDesktopStepSet() {
        let steps = DiagnosticsService.sortedSteps(context: makeContext())
        let expected = [
            "diagnostic-Step-0: logConfig",
            "diagnostic-Step-1: internetConnection",
            "diagnostic-Step-2: configValidation",
            "diagnostic-Step-3: serverConnectivity",
            "diagnostic-Step-4: sessionDataValidation",
            "diagnostic-Step-5: BrowserWindowsChecks",
            "diagnostic-Step-6: PermissionsCheck",
            "diagnostic-Step-7: PerformanceAndMemory",
            "diagnostic-Step-8: LogHeuristics",
            "diagnostic-Step-9: Config",
            "diagnostic-Step-10: CrashReports",
            "diagnostic-Step-11: AuthSSO",
        ]
        XCTAssertEqual(steps.map(\.name), expected, "Desktop master has exactly 12 registered steps; reconcile step-count here")
        XCTAssertEqual(steps.count, 12, "T19 title said 19 and design doc §4c said 23 — actual desktop step set is 12")
    }

    // MARK: - Connectivity

    func testConnectivityStepSucceedsAgainstLocalhostEndpoint() async {
        let localhost = URL(string: "http://127.0.0.1:9898/api/v4/system/ping")!
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v4/system/ping")
            return self.textResponse(#"{"status":"OK"}"#, status: 200)
        }
        defer { MockURLProtocol.handler = nil }

        let context = makeContext(onlineEndpoint: localhost, session: mockSession())
        let step = DiagnosticsService.step1InternetConnection(context: context)
        let response = await step.run(DiagnosticsLog())
        XCTAssertTrue(response.succeeded, "Localhost ping with status OK must succeed")
    }

    /// Offline (transport error) -> step reports FAILED but the run still completes and the
    /// report assembles with all 12 rows (the "skip if no network" behaviour for tests).
    func testConnectivityStepFailsWhenOfflineButRunCompletes() async {
        MockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer { MockURLProtocol.handler = nil }

        let localhost = URL(string: "http://127.0.0.1:9898/api/v4/system/ping")!
        let service = DiagnosticsService(context: makeContext(onlineEndpoint: localhost, session: mockSession()))
        let report = await service.run()
        XCTAssertEqual(report.steps.count, 12)
        XCTAssertFalse(report.steps[1].succeeded, "Step-1 must be failed offline")
        // All other steps still reported (report assembly never aborts mid-run).
        XCTAssertEqual(report.steps.map(\.step), Array(0..<12))
    }

    // MARK: - Full report assembly

    func testFullReportAssemblyRunsAllTwelveSteps() async {
        let service = DiagnosticsService(context: makeContext())
        let report = await service.run()
        XCTAssertEqual(report.steps.count, 12)
        XCTAssertEqual(report.steps.map(\.step), Array(0..<12))
        XCTAssertEqual(report.steps.map(\.name).first, "diagnostic-Step-0: logConfig")
        XCTAssertEqual(report.steps.map(\.name).last, "diagnostic-Step-11: AuthSSO")
        for entry in report.steps {
            XCTAssertGreaterThanOrEqual(entry.durationMs, 0)
        }
        XCTAssertEqual(report.appName, "Mattermost")
        XCTAssertEqual(report.appVersion, "0.1.0")
    }

    func testReportJSONRoundTrips() async throws {
        let service = DiagnosticsService(context: makeContext())
        let report = await service.run()
        let json = try XCTUnwrap(DiagnosticsService.jsonString(report))
        let data = Data(json.utf8)
        let decoded = try DiagnosticsService.jsonDecoder().decode(DiagnosticsReport.self, from: data)
        XCTAssertEqual(decoded.steps.count, report.steps.count)
        XCTAssertEqual(decoded.steps[0].name, "diagnostic-Step-0: logConfig")
    }

    func testReportMarkdownContainsSummaryTable() async {
        let service = DiagnosticsService(context: makeContext())
        let report = await service.run()
        let md = service.markdownReport(report)
        XCTAssertTrue(md.contains("| index | name | succeeded |"))
        XCTAssertTrue(md.contains("| 0 | diagnostic-Step-0: logConfig |"))
        XCTAssertTrue(md.contains("out of 12 steps succeeded"))
        XCTAssertTrue(md.contains("Step details"))
    }

    func testWriteReportFilesProducesShareableFiles() async throws {
        let service = DiagnosticsService(context: makeContext())
        let report = await service.run()
        let (txt, json) = try service.writeReportFiles(report, to: diagDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: txt.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: json.path))
        XCTAssertTrue(txt.pathExtension == "txt")
        XCTAssertTrue(json.pathExtension == "json")
        let txtContents = try String(contentsOf: txt, encoding: .utf8)
        XCTAssertTrue(txtContents.contains("Mattermost iOS Diagnostics Report START"))
        let jsonData = try Data(contentsOf: json)
        let decoded = try DiagnosticsService.jsonDecoder().decode(DiagnosticsReport.self, from: jsonData)
        XCTAssertEqual(decoded.steps.count, 12)
    }

    // MARK: - Config validation (step2)

    func testConfigValidationFailsOnEmptyServerName() async {
        let bad = ServerConfig(name: "", url: URL(string: "https://a.example")!, order: 0, lastActiveAt: .distantPast, hasSession: false)
        suite.set(try! JSONEncoder().encode([bad]), forKey: AppPreferences.Keys.servers)
        let context = makeContext(servers: [bad])
        let step = DiagnosticsService.step2ConfigValidation(context: context)
        let response = await step.run(DiagnosticsLog())
        XCTAssertFalse(response.succeeded, "Empty server name must fail config validation (desktop Joi analog)")
    }

    func testConfigValidationSucceedsWithoutPersistedConfig() async {
        let context = makeContext(servers: [])
        let step = DiagnosticsService.step2ConfigValidation(context: context)
        let response = await step.run(DiagnosticsLog())
        XCTAssertTrue(response.succeeded, "No config stored is valid (desktop config defaults)")
    }

    // MARK: - Server connectivity (step3)

    func testServerConnectivityAllOnline() async {
        let server = ServerConfig(name: "Local", url: URL(string: "http://127.0.0.1:8111")!)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v4/system/ping")
            return self.textResponse(#"{"status":"OK"}"#, status: 200)
        }
        defer { MockURLProtocol.handler = nil }
        let context = makeContext(servers: [server], session: mockSession())
        let step = DiagnosticsService.step3ServerConnectivity(context: context)
        let response = await step.run(DiagnosticsLog())
        XCTAssertTrue(response.succeeded)
    }

    func testServerConnectivityFailsWhenServerOffline() async {
        let server = ServerConfig(name: "Local", url: URL(string: "http://127.0.0.1:8111")!)
        MockURLProtocol.handler = { _ in
            throw URLError(.cannotConnectToHost)
        }
        defer { MockURLProtocol.handler = nil }
        let context = makeContext(servers: [server], session: mockSession())
        let step = DiagnosticsService.step3ServerConnectivity(context: context)
        let response = await step.run(DiagnosticsLog())
        XCTAssertFalse(response.succeeded, "Any offline server fails the desktop step")
    }

    func testServerConnectivityFailsWithoutServers() async {
        let context = makeContext(servers: [])
        let step = DiagnosticsService.step3ServerConnectivity(context: context)
        let response = await step.run(DiagnosticsLog())
        XCTAssertFalse(response.succeeded)
    }

    // MARK: - Session validation (step4)

    func testSessionDataValidationAllCookiesPresent() async {
        let server = ServerConfig(name: "Local", url: URL(string: "https://a.example")!)
        let context = makeContext(servers: [server], sessionSnap: { _ in
            SessionDataSnapshot(hasUserID: true, hasCSRF: true, hasAuthToken: true)
        })
        let step = DiagnosticsService.step4SessionDataValidation(context: context)
        let response = await step.run(DiagnosticsLog())
        XCTAssertTrue(response.succeeded)
    }

    func testSessionDataValidationFailsWhenCookieMissing() async {
        let server = ServerConfig(name: "Local", url: URL(string: "https://a.example")!)
        let context = makeContext(servers: [server], sessionSnap: { _ in
            SessionDataSnapshot(hasUserID: true, hasCSRF: false, hasAuthToken: true)
        })
        let step = DiagnosticsService.step4SessionDataValidation(context: context)
        let response = await step.run(DiagnosticsLog())
        XCTAssertFalse(response.succeeded, "Missed MMCSRF must fail the desktop check")
    }

    // MARK: - Browser windows (step5)

    func testBrowserWindowsStepFailsForUnmountedWebview() async {
        let server = ServerConfig(name: "Local", url: URL(string: "https://a.example")!)
        let statuses = [WebViewStatusItem(serverID: server.id, serverName: server.name,
                                          mounted: false, hasURL: false, hasPageError: false, isLoading: false)]
        let context = makeContext(servers: [server], webStatuses: statuses)
        let step = DiagnosticsService.step5BrowserWindows(context: context)
        let response = await step.run(DiagnosticsLog())
        XCTAssertFalse(response.succeeded)
    }

    func testBrowserWindowsStepSucceedsWhenMountedAndLoaded() async {
        let server = ServerConfig(name: "Local", url: URL(string: "https://a.example")!)
        let statuses = [WebViewStatusItem(serverID: server.id, serverName: server.name,
                                          mounted: true, hasURL: true, hasPageError: false, isLoading: false)]
        let context = makeContext(servers: [server], webStatuses: statuses)
        let step = DiagnosticsService.step5BrowserWindows(context: context)
        let response = await step.run(DiagnosticsLog())
        XCTAssertTrue(response.succeeded)
    }

    // MARK: - Permissions (step6)

    func testPermissionsStepReflectsProviderSnapshot() async {
        let snapshot = PermissionsSnapshot(notificationsStatus: "granted",
                                           downloadsWritable: true,
                                           diagnosticsWritable: false,
                                           microphoneStatus: "denied",
                                           cameraStatus: "not-determined")
        let context = makeContext(status: snapshot)
        let step = DiagnosticsService.step6Permissions(context: context)
        let response = await step.run(DiagnosticsLog())
        XCTAssertTrue(response.succeeded, "Desktop permissions step succeeds even when permissions are denied")
        let payload = try! XCTUnwrap(response.payload)
        let dict = payload as! [String: Any]
        XCTAssertEqual(dict["notificationsSupported"] as? Bool, true)
        let fs = dict["fileSystem"] as! [String: Any]
        XCTAssertEqual(fs["diagnosticsWritable"] as? Bool, false)
    }

    // MARK: - Log heuristics (step8)

    func testLogHeuristicsCountsLevelsFromTranscript() async {
        let context = makeContext()
        let step = DiagnosticsService.step8LogHeuristics(context: context)
        let log = DiagnosticsLog()
        log.append("info", "one")
        log.append("warn", "two")
        log.append("error", "three")
        log.append("error", "four")
        let response = await step.run(log)
        XCTAssertTrue(response.succeeded)
        let payload = response.payload as! [String: Any]
        XCTAssertEqual(payload["linesCount"] as? Int, 4)
        let levels = payload["logLevels"] as! [String: Int]
        XCTAssertEqual(levels["info"], 1)
        XCTAssertEqual(levels["error"], 2)
        XCTAssertEqual(levels["warn"], 1)
        XCTAssertEqual(payload["percentageOfErrors"] as? Double, 50.0)
    }

    // MARK: - Crash reports (step10)

    func testCrashReportsStepReadsCrashFiles() async throws {
        let crashFile = crashDir.appendingPathComponent("uncaughtException-2026-10-23.txt")
        try "uncaught boom".write(to: crashFile, atomically: true, encoding: .utf8)
        let context = makeContext()
        let step = DiagnosticsService.step10CrashReports(context: context)
        let response = await step.run(DiagnosticsLog())
        XCTAssertTrue(response.succeeded)
        let payload = response.payload as! [String: Any]
        let data = payload["crashReportData"] as! [[String: String]]
        XCTAssertEqual(data.count, 1)
        XCTAssertTrue(data[0]["fileName"]!.hasPrefix("uncaughtException-"))
        XCTAssertEqual(data[0]["data"], "uncaught boom")
    }

    func testCrashReportsStepSucceedsWithNoCrashFiles() async {
        let context = makeContext()
        let step = DiagnosticsService.step10CrashReports(context: context)
        let response = await step.run(DiagnosticsLog())
        XCTAssertTrue(response.succeeded)
        let payload = response.payload as! [String: Any]
        XCTAssertEqual((payload["crashReportData"] as! [[String: Any]]).count, 0)
    }

    // MARK: - Obfuscator (steps/internal/obfuscators.ts port)

    func testObfuscatorMasksEmailURLIPv4PathToken() {
        let ob = DiagnosticsObfuscator.self
        XCTAssertEqual(ob.maskDataInString("mail me at alice@example.com now"), "mail me at EMAIL now")
        XCTAssertEqual(ob.maskDataInString("site is https://a.example/x?y=1 and done"),
                       "site is URL and done")
        XCTAssertEqual(ob.maskDataInString("router 192.168.1.1 online"), "router IPV4 online")
        XCTAssertEqual(ob.maskDataInString("file at /Users/alice/secret.txt please"), "file at PATH please")
        XCTAssertEqual(ob.maskDataInString("my password is hunter2"), "")
        XCTAssertTrue(ob.maskDataInString("password-ish thing").isEmpty)
    }

    func testObfuscatorTruncatesLongTokens() {
        let long = String(repeating: "A", count: 100)
        let masked = DiagnosticsObfuscator.maskDataInString(long)
        XCTAssertEqual(masked, "AAAA...AA", "Long tokens must truncate like desktop LOGS_MAX_STRING_LENGTH")
    }

    func testObfuscatorRecursesIntoDictionaries() {
        let result = DiagnosticsObfuscator.mask(["name": "hello", "token": "x1234567890", "nested": ["email": "b@c.io"]] as [String: Any])
        let dict = result as! [String: Any]
        XCTAssertEqual(dict["token"] as? String, "x1234567890") // 10 chars < 63, unchanged
        XCTAssertEqual((dict["nested"] as! [String: Any])["email"] as? String, "EMAIL")
    }

    // MARK: - Payload JSON safety

    func testDiagValueEncodesAsJSON() throws {
        let value = DiagValue.make(from: [
            "server": "abc@def.io", // masked at export
            "count": 3,
            "ok": true,
            "nothing": NSNull(),
        ])
        let data = try JSONEncoder().encode(value)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["server"] as? String, "EMAIL")
        XCTAssertEqual(obj["count"] as? Int, 3)
        XCTAssertEqual(obj["ok"] as? Bool, true)
    }

    // MARK: - dateTimeInFilename parity

    func testDateTimeInFilenameFormatMatchesDesktop() {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 10 // October
        comps.day = 23
        comps.hour = 15
        comps.minute = 7
        comps.second = 9
        comps.nanosecond = 123_000_000
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        XCTAssertEqual(DiagnosticsDate.dateTimeInFilename(date: date), "23-9-2026_15-7-9-123",
                       "Desktop uses 0-based month (JS getMonth)")
    }
}
