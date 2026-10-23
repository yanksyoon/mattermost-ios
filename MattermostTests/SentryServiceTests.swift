import XCTest
@testable import Mattermost
import Foundation

/// DSN-gated Sentry handler tests (T19a). The defining property under test: with no DSN
/// configured, `SentryService.start()` MUST NOT invoke the SDK start hook (no-op path), and
/// with a DSN configured the SDK start guard must hand options to the hook. The real Sentry
/// Cocoa SDK is NOT linked on this host (SwiftPM cannot reach github.com — see
/// docs/t19a-build-note.md), so the hook is a fake here; the production hook lives in
/// SentrySDKLink.swift behind `#if canImport(Sentry)`.
final class SentryServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SentryService.shared.resetForTests()
    }

    // MARK: - The DSN guard

    func testStartIsNoOpWhenDSNAbsent() {
        var hookCalls = 0
        SentryService.shared.startHook = { _ in hookCalls += 1 }

        SentryService.shared.start(dsn: nil)

        XCTAssertEqual(hookCalls, 0, "SentrySDK.start must NOT be called without a DSN")
        XCTAssertFalse(SentryService.shared.isStarted)
    }

    func testStartIsNoOpWhenDSNEmpty() {
        var hookCalls = 0
        SentryService.shared.startHook = { _ in hookCalls += 1 }

        SentryService.shared.start(dsn: "")

        XCTAssertEqual(hookCalls, 0)
        XCTAssertFalse(SentryService.shared.isStarted)
    }

    func testStartGuardExercisedWhenDSNPresent() throws {
        var captured: SentryStartOptions?
        SentryService.shared.startHook = { captured = $0 }

        SentryService.shared.start(dsn: "https://ph@example.ingest.sentry.io/1",
                                   environment: "stable",
                                   initialUserID: "install-42")

        let options = try XCTUnwrap(captured)
        XCTAssertEqual(options.dsn, "https://ph@example.ingest.sentry.io/1")
        XCTAssertEqual(options.environment, "stable")
        XCTAssertEqual(options.initialUserID, "install-42")
        XCTAssertTrue(options.attachStacktrace)
        XCTAssertFalse(options.sendDefaultPii, "desktop Sentry.init({sendDefaultPii: false})")
        XCTAssertTrue(SentryService.shared.isStarted)
    }

    /// The stub build has no SDK link installed: with a DSN present, start() records the
    /// intent and must not crash or fake a start.
    func testStartWithDSNAndNoHookIsInertButDocumented() {
        SentryService.shared.startHook = nil
        SentryService.shared.start(dsn: "https://ph@example.ingest.sentry.io/1")
        XCTAssertFalse(SentryService.shared.isStarted, "No SDK linked -> hook absent -> no external call")
    }

    func testDSNReadsFromInfoPlistStyleOverride() {
        XCTAssertFalse(SentryService.dsnConfigured(override: nil))
        XCTAssertFalse(SentryService.dsnConfigured(override: ""))
        XCTAssertTrue(SentryService.dsnConfigured(override: "https://ph@example.ingest.sentry.io/1"))
    }

    // MARK: - Environment

    func testPrereleaseEnvironmentDetection() {
        XCTAssertTrue(SentryService.isPrereleaseBuild(version: "0.1.0-beta.2"))
        XCTAssertTrue(SentryService.isPrereleaseBuild(version: "0.1.0-develop.1"))
        XCTAssertFalse(SentryService.isPrereleaseBuild(version: "0.1.0"))
        XCTAssertEqual(SentryService.defaultEnvironment(version: "0.1.0-beta.2"), "prerelease")
        XCTAssertEqual(SentryService.defaultEnvironment(version: "0.1.0"), "stable")
    }

    // MARK: - Breadcrumbs

    func testBreadcrumbsAreBufferedAndForwardedWhenHookPresent() {
        var forwarded: [SentryBreadcrumb] = []
        SentryService.shared.breadcrumbHook = { forwarded.append($0) }

        SentryService.shared.addBreadcrumb(category: "bridge", message: "received notify_mention")
        SentryService.shared.addBreadcrumb(category: "app", message: "didFinishLaunching", level: "debug")

        XCTAssertEqual(SentryService.shared.breadcrumbSnapshot().count, 2)
        XCTAssertEqual(forwarded.count, 2)
        XCTAssertEqual(forwarded.first?.category, "bridge")
        XCTAssertEqual(forwarded.first?.message, "received notify_mention")
    }

    func testBreadcrumbBufferIsBounded() {
        for i in 0..<250 {
            SentryService.shared.addBreadcrumb(category: "flood", message: "m\(i)")
        }
        let snapshot = SentryService.shared.breadcrumbSnapshot()
        XCTAssertLessThanOrEqual(snapshot.count, 100, "Buffer must be capped")
        XCTAssertEqual(snapshot.last?.message, "m249")
    }

    // MARK: - Uncaught exception handler

    /// Desktop electron records uncaughtException-* crash files; the shell's handler writes
    /// them into the same directory diagnostics step10 scans. Invoked directly (firing a real
    /// uncaught exception would kill the test host).
    func testUncaughtExceptionHandlerWritesCrashFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

        let exception = NSException(name: .genericException,
                                    reason: "boom",
                                    userInfo: ["k": "v"])
        SentryService.shared.handleUncaughtException(exception, into: dir)

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let crashFiles = files.filter { $0.hasPrefix("uncaughtException-") && $0.hasSuffix(".txt") }
        XCTAssertEqual(crashFiles.count, 1)
        let contents = try String(contentsOf: dir.appendingPathComponent(crashFiles[0]), encoding: .utf8)
        XCTAssertTrue(contents.contains("name: "))
        XCTAssertTrue(contents.contains("boom"))

        try? FileManager.default.removeItem(at: dir)
    }

    func testInstallUncaughtExceptionHandlerSetsFlag() {
        // Reset the singleton-installed flag so the install path is exercised fresh.
        SentryService.shared.resetUncaughtExceptionHandlerForTesting()
        SentryService.shared.installUncaughtExceptionHandler()
        XCTAssertTrue(SentryService.shared.uncaughtExceptionHandlerInstalled)
        // Installing twice must be idempotent (no crash, still installed).
        SentryService.shared.installUncaughtExceptionHandler()
        XCTAssertTrue(SentryService.shared.uncaughtExceptionHandlerInstalled)
    }

    // MARK: - Crash directory matches diagnostics step10

    func testCrashReportsDirectoryIsDocumentsDiagnostics() {
        let dir = SentryService.crashReportsDirectory()
        XCTAssertEqual(dir.lastPathComponent, "Diagnostics")
        XCTAssertTrue(dir.path.contains("Documents"))
    }
}
