import Foundation

// MARK: - SentryService (desktop src/main/sentryHandler.ts -> native iOS)
//
// Parity row (design doc §4c): `CriticalErrorHandler`/`SentryHandler` -> Sentry Cocoa SDK
// `SentrySDK.start`; `NSSetUncaughtExceptionHandler`.
//
// DSN GATING (hard requirement of T19a): this host has NO Sentry DSN and the Sentry Cocoa
// SDK is NOT linked into the Mattermost target (SwiftPM cannot reach github.com here — see
// docs/t19a-build-note.md). The desktop handler returns early when no DSN is configured:
// `if (!sentryDsn || empty) { log warn; return; }` — this port does the same:
//   - no DSN configured -> SentrySDK.start is NEVER called (no-op path, unit-tested).
//   - DSN configured    -> the SDK start guard runs: options are built and handed to
//     `startHook`, which `SentrySDKLink` wires to the real `SentrySDK.start` the moment the
//     SDK is added to the target (`#if canImport(Sentry)`). Until then the hook is absent,
//     start() records the intent and no external call is made (unit-tested).
//
// Crash reports: the uncaught-exception handler below is installed regardless of DSN — it
// writes `uncaughtException-<ts>.txt` into Documents/Diagnostics, which diagnostics step10
// scans (desktop electron writes crash files its diagnostics step reads; on iOS the shell
// owns that writer).

/// The subset of Sentry `Options` this shell configures (mirrors `Sentry.init({dsn,
/// sendDefaultPii, environment, attachStacktrace, initialScope.user.id})`).
struct SentryStartOptions: Equatable {
    var dsn: String
    var environment: String
    var attachStacktrace: Bool
    var sendDefaultPii: Bool
    var initialUserID: String?
}

/// A breadcrumb buffered by the shell and forwarded to Sentry when the SDK is linked
/// (desktop `Sentry.addBreadcrumb` around bridge/diagnostics events).
struct SentryBreadcrumb: Equatable {
    var category: String
    var message: String
    var level: String // "debug" | "info" | "warning" | "error"

    static func == (lhs: SentryBreadcrumb, rhs: SentryBreadcrumb) -> Bool {
        lhs.category == rhs.category && lhs.message == rhs.message && lhs.level == rhs.level
    }
}

final class SentryService {

    static let shared = SentryService()

    /// Where the real SDK start happens. Installed by `SentrySDKLink` when the SDK is linked
    /// into the target; replaced by tests to prove the guard.
    var startHook: ((SentryStartOptions) -> Void)?

    /// Forwarding path for live breadcrumbs once the SDK is linked.
    var breadcrumbHook: ((SentryBreadcrumb) -> Void)?

    /// Has `start()` actually invoked the SDK start hook in this process?
    private(set) var isStarted = false
    /// Has the uncaught-exception handler been installed?
    private(set) var uncaughtExceptionHandlerInstalled = false

    /// Bounded breadcrumb buffer (desktop keeps no buffer, but the diagnostics report can
    /// include recent shell events; cap so it can't grow unbounded).
    private(set) var breadcrumbs: [SentryBreadcrumb] = []
    private let breadcrumbCap = 100
    private let lock = NSLock()

    // MARK: DSN configuration

    /// Reads `SentryDSN` from Info.plist (or any override injected for tests).
    static func dsn(fromBundle bundle: Bundle = .main, override: String? = nil) -> String? {
        if let override { return override.isEmpty ? nil : override }
        guard let value = bundle.object(forInfoDictionaryKey: "SentryDSN") as? String else { return nil }
        return value.isEmpty ? nil : value
    }

    static func dsnConfigured(fromBundle bundle: Bundle = .main, override: String? = nil) -> Bool {
        dsn(fromBundle: bundle, override: override) != nil
    }

    /// Desktop `SentryHandler.init()` port. The DSN guard mirrors the desktop exactly:
    /// no DSN -> warn and return WITHOUT touching the SDK (no-op path).
    func start(dsn: String? = SentryService.dsn(),
               environment: String = SentryService.defaultEnvironment(),
               initialUserID: String? = nil) {
        guard let dsn, !dsn.isEmpty else {
            Logger.info("SentryService", "Sentry is enabled but not configured (no DSN provided); SDK start skipped (no-op)")
            return
        }
        let options = SentryStartOptions(
            dsn: dsn,
            environment: environment,
            attachStacktrace: true,
            sendDefaultPii: false,
            initialUserID: initialUserID
        )
        guard let startHook else {
            // SDK start hook not installed (SDK not linked into this build). Record the intent
            // so the diagnostics report can surface it; make NO external call.
            Logger.info("SentryService", "DSN configured but Sentry SDK start hook is not installed (SDK not linked); start intent recorded")
            return
        }
        startHook(options)
        isStarted = true
        Logger.info("SentryService", "Sentry initialized for error tracking (\(environment))")
    }

    /// Test seam: return the shared service to its pristine state. `SentryService.shared` is a
    /// process singleton, so without this every test after `testStartGuardExercisedWhenDSNPresent`
    /// inherits `isStarted = true` and a primed breadcrumb buffer — the assertions then fail for
    /// reasons that have nothing to do with the behaviour under test.
    func resetForTests() {
        lock.lock()
        defer { lock.unlock() }
        isStarted = false
        uncaughtExceptionHandlerInstalled = false
        breadcrumbs.removeAll()
        startHook = nil
        breadcrumbHook = nil
    }

    /// Desktop prerelease detection: a version like `0.1.0-beta.1` is prerelease; `0.1.0` is stable.
    static func isPrereleaseBuild(version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") -> Bool {
        version.range(of: #"-[a-zA-Z0-9.-]+"#, options: .regularExpression) != nil
    }

    static func defaultEnvironment(version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") -> String {
        isPrereleaseBuild(version: version) ? "prerelease" : "stable"
    }

    // MARK: Uncaught exception handler + crash files

    /// Install the C uncaught-exception handler that writes a crash file for diagnostics
    /// step10. Installed unconditionally (desktop electron records crash files regardless of
    /// Sentry); when the SDK is linked later it installs its own richer handler too.
    func installUncaughtExceptionHandler() {
        guard !uncaughtExceptionHandlerInstalled else { return }
        NSSetUncaughtExceptionHandler { exception in
            SentryService.shared.handleUncaughtException(exception)
        }
        uncaughtExceptionHandlerInstalled = true
        Logger.info("SentryService", "NSSetUncaughtExceptionHandler installed")
    }

    /// Test hook: lets unit tests re-exercise the install path without shipping a mutable
    /// public setter.
    func resetUncaughtExceptionHandlerForTesting() {
        uncaughtExceptionHandlerInstalled = false
    }

    /// Writes `uncaughtException-<ts>.txt` into Documents/Diagnostics (same directory
    /// diagnostics step10 scans). Testable directly without crashing the test host.
    func handleUncaughtException(_ exception: NSException, into directory: URL? = nil, fileManager: FileManager = .default) {
        let dir = directory ?? Self.crashReportsDirectory(fileManager: fileManager)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let detail = """
        uncaught exception at \(DiagnosticsDate.logLineDate())
        name: \(exception.name.rawValue)
        reason: \(exception.reason ?? "(no reason)")
        userInfo: \(exception.userInfo ?? [:])
        callStackReturnAddresses: \(exception.callStackReturnAddresses)
        callStackSymbols:
        \(exception.callStackSymbols.joined(separator: "\n"))
        """
        let fileName = "uncaughtException-\(DiagnosticsDate.dateTimeInFilename()).txt"
        let url = dir.appendingPathComponent(fileName)
        try? detail.write(to: url, atomically: true, encoding: .utf8)
        Logger.error("SentryService", "recorded uncaught exception to \(url.path)")
    }

    /// Documents/Diagnostics — the report + crash-file directory.
    static func crashReportsDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    // MARK: Breadcrumbs

    /// Buffer a breadcrumb (bounded) and, when the SDK is linked, forward it live.
    func addBreadcrumb(category: String, message: String, level: String = "info") {
        let crumb = SentryBreadcrumb(category: category, message: message, level: level)
        lock.lock()
        breadcrumbs.append(crumb)
        if breadcrumbs.count > breadcrumbCap {
            breadcrumbs.removeFirst(breadcrumbs.count - breadcrumbCap)
        }
        lock.unlock()
        breadcrumbHook?(crumb)
    }

    /// Diagnostics-report view of buffered breadcrumbs.
    func breadcrumbSnapshot() -> [SentryBreadcrumb] {
        lock.lock()
        defer { lock.unlock() }
        return breadcrumbs
    }
}
