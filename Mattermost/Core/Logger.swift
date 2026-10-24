import Foundation
import os.log

/// Thin logging wrapper over `os.log` (native counterpart of desktop `src/common/log.ts`).
/// Parity row: `Log` (`common/log.ts`) -> `Logger` (os.log / OSLogger). Status: native, P0.
///
/// T11 adds a minimum-level gate backed by the desktop's `logLevel` setting
/// (`AppSettings.logLevel`, default `'info'`): messages below the configured severity are
/// dropped before they reach `os_log`, mirroring the desktop's log-level filtering. Levels
/// map onto `OSLogType`: error < warn < info < debug < verbose < silly.
enum Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.mattermost.ios"

    /// Per-category `OSLog` handles, lazily created so they aren't opened unless used.
    private static var cache: [String: OSLog] = [:]

    #if DEBUG
    /// Test-only mirror of every line about to be logged, before the level gate (T28). Used by
    /// `TokenLoggingTests` to prove no credential reaches a log line: the sink sees the same
    /// strings `os_log` would, so "not in the sink" means "not in the log". DEBUG builds only —
    /// it cannot exist in a Release binary.
    static var testSink: ((String) -> Void)?
    #endif

    /// Minimum severity allowed through to the system log. `info` matches the desktop default.
    private static var minimumLevel: OSLogType = .info

    /// Set the minimum severity that reaches `os_log` (desktop `logLevel` setting). Accepts
    /// the desktop's string values; unknown values keep the previous gate.
    nonisolated static func setMinimumLevel(_ level: String) {
        switch level {
        case "error": minimumLevel = .error
        case "warn": minimumLevel = .fault // OSLogType has no "warn"; fault is next-above-error
        case "info": minimumLevel = .info
        case "verbose", "debug", "silly": minimumLevel = .debug
        default: break
        }
    }

    private static func shouldLog(_ level: OSLogType) -> Bool {
        level.rawValue >= minimumLevel.rawValue
    }

    private static func os(_ category: String) -> OSLog {
        if let log = cache[category] { return log }
        let log = OSLog(subsystem: subsystem, category: category)
        cache[category] = log
        return log
    }

    static func log(_ level: OSLogType, _ category: String, _ message: String,
                    file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        testSink?("\(category): \(message)")
        #endif
        guard shouldLog(level) else { return }
        #if DEBUG
        let fname = (file as NSString).lastPathComponent
        os_log(level, log: os(category), "%{public}@ @ %{public}@:%d", "\(level).\(category): \(message)", "\(fname).\(function)", line)
        #else
        os_log(level, log: os(category), "%{public}@", message)
        #endif
    }

    static func debug(_ category: String, _ message: String) { log(.debug, category, message) }
    static func info(_ category: String, _ message: String) { log(.info, category, message) }
    static func error(_ category: String, _ message: String) { log(.error, category, message) }
}
