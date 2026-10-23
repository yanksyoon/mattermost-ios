import Foundation
import UIKit
import AVFoundation
import UserNotifications
import WebKit

// MARK: - Diagnostics port (desktop src/main/diagnostics -> native iOS)
//
// Port of the desktop `src/main/diagnostics` module (`index.ts`, `DiagnosticStep.ts`,
// `steps/step0..step11`, `steps/internal/{utils,obfuscators,loggerHooks}.ts`).
// Parity row (design doc §4c): `diagnostics` (23 steps) -> `DiagnosticsService` reusing the
// step order (log level, connectivity, config, session, server connect, permissions, perf);
// produces a shareable report.
//
// STEP-COUNT RECONCILIATION (verified against mattermost/desktop master on 2026-10-23):
//   The desktop `steps/` directory contains step0..step11 (TWELVE real steps), plus
//   `step.template.ts` (a copy-paste template, never registered) and `internal/` shared
//   helpers (not steps). The design doc's "23 steps" (§4c) and T19's "19 steps" are both
//   stale numbers; the actual registered step set in `index.ts`'s SORTED_STEPS is 12.
//   Every one of the 12 is ported here, in the same order and with the same step names.
//
// Semantics notes vs desktop:
//   - electron-log file transport   -> an in-memory `DiagnosticsLog` transcript (formatted
//     like electron-log: `[2026-10-23 15:07:09.123] [level] message`); step8 counts levels
//     from it exactly like the desktop counts its log file.
//   - `session.defaultSession.cookies` -> the shell's session data in Keychain via
//     `SecureVault` (presence only, never values) + `ServerConfig.hasSession`.
//   - `BrowserWindow`/`WebContents` checks -> per-server `WebViewStore` status snapshots
//     (mounted, URL present, no page error, not loading).
//   - `process.*`/`powerMonitor` (Node) -> `ProcessInfo` + `UIDevice` equivalents.
//   - Obfuscation is applied at report assembly (masking + truncation), replicating the
//     desktop loggerHooks mask at export time; nothing sensitive rides the report.

/// Regexes and masks ported from desktop `src/common/constants.ts`.
enum DiagnosticsConstants {
    static let onlineEndpoint = "https://community.mattermost.com/api/v4/system/ping"
    static let logsMaxStringLength = 63

    static let cookieUserID = "MMUSERID"
    static let cookieCSRF = "MMCSRF"
    static let cookieAuthToken = "MMAUTHTOKEN"

    static let regexEmail = #"[a-zA-Z0-9.!#$%&’*+/=?^_`{|}~-]+@[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)*"#
    static let regexIPv4 = #"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#
    /// Any http(s) URL, matched greedily to the next whitespace. For masking we always replace
    /// the WHOLE URL, so the host shape must not matter (the old bounded-TLD form missed hosts
    /// with a 7+ character TLD, e.g. `a.example`, and let the path regex eat the remainder).
    static let regexURL = #"https?://\S+"#
    /// A run of slash-separated path segments ("same as darwin" in desktop constants) — matched
    /// as one token so `/Users/alice/secret.txt` collapses to a single PATH, not one per segment.
    static let regexPath = #"(?:/[\w.\-]+)+"#
    /// electron-log file line: `[2026-10-23 15:07:09.123] [info] message`
    static let regexLogFileLine = #"\[(\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}.\d{3})\]\s\[(silly|debug|verbose|info|warn|error)\]\s+(.*)"#
}

/// Data-masking port of desktop `steps/internal/obfuscators.ts` + `truncateString`/constants.
enum DiagnosticsObfuscator {

    /// `truncateString(str, 63)`: keep `prefix(4) + "..." + suffix(2)` for long strings.
    static func truncateString(_ str: String, maxLength: Int = DiagnosticsConstants.logsMaxStringLength) -> String {
        if str.count >= maxLength {
            return "\(str.prefix(4))...\(str.suffix(2))"
        }
        return str
    }

    /// `maskDataInString` port. Returns "" for anything password-looking, then masks emails,
    /// IPv4s, URLs and paths, and truncates long tokens (the desktop masks tokens that way).
    static func maskDataInString(_ raw: String) -> String {
        if raw.isEmpty { return raw }
        if raw.lowercased().contains("password") { return "" }

        var masked = raw
        masked = replace(masked, pattern: DiagnosticsConstants.regexEmail, with: "EMAIL")
        masked = replace(masked, pattern: DiagnosticsConstants.regexIPv4, with: "IPV4")
        masked = replace(masked, pattern: DiagnosticsConstants.regexURL, with: "URL")
        masked = replace(masked, pattern: DiagnosticsConstants.regexPath, with: "PATH")

        // Very long strings (tokens) are truncated after splitting on , | space | newline.
        let tokens = masked.components(separatedBy: CharacterSet(charactersIn: ", |\r\n").union(.whitespaces))
        return tokens.map { truncateString($0) }.joined(separator: " ")
    }

    /// `obfuscateByType` port over Any. Arrays and dictionaries recurse.
    static func mask(_ value: Any) -> Any {
        if let str = value as? String { return maskDataInString(str) }
        if let arr = value as? [Any] { return arr.map { mask($0) } }
        if let dict = value as? [String: Any] {
            return dict.reduce(into: [String: Any]()) { acc, pair in
                if pair.key != "__proto__" { acc[pair.key] = mask(pair.value) }
            }
        }
        return value
    }

    private static func replace(_ string: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return string }
        let range = NSRange(string.startIndex..., in: string)
        return regex.stringByReplacingMatches(in: string, options: [], range: range, withTemplate: replacement)
    }
}

/// JSON-safe report value. Payloads are converted here so a report can be exported as JSON
/// without needing `Any` anywhere in the Codable surface.
enum DiagValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([DiagValue])
    case object([String: DiagValue])

    static func make(from value: Any) -> DiagValue {
        switch value {
        case is NSNull: return .null
        case let b as Bool: return .bool(b)
        case let i as Int: return .number(Double(i))
        case let d as Double: return .number(d)
        case let f as Float: return .number(Double(f))
        case let s as String: return .string(DiagnosticsObfuscator.maskDataInString(s))
        case let url as URL: return .string(DiagnosticsObfuscator.maskDataInString(url.absoluteString))
        case let date as Date: return .string(ISO8601DateFormatter().string(from: date))
        case let uuid as UUID: return .string(uuid.uuidString)
        case let error as Error: return .string(DiagnosticsObfuscator.maskDataInString(error.localizedDescription))
        case let arr as [Any]: return .array(arr.map { make(from: $0) })
        case let dict as [String: Any]: return .object(dict.reduce(into: [String: DiagValue]()) { $0[$1.key] = make(from: $1.value) })
        default: return .string(DiagnosticsObfuscator.maskDataInString(String(describing: value)))
        }
    }

    // A report must read as ordinary JSON on the wire (desktop diagnostics writes plain values),
    // so this enum encodes into a single-value container instead of the compiler-synthesised
    // `{"string": {"_0": ...}}` shape. Decode mirrors that: null, bool, number, string,
    // array, object — in that order of specificity.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([DiagValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: DiagValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "DiagValue: unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

// MARK: - Diagnostics log (electron-log analog)

/// Rustic in-memory log transcript in electron-log line format; step0 "configures" it (creates
/// the reports directory + filename) and step8 counts levels from it — the iOS analog of the
/// desktop's `logger.transports.file`.
final class DiagnosticsLog {
    private(set) var lines: [String] = []
    var directory: URL?
    var filename = "diagnostics_log.txt"

    func configure(directory: URL) throws {
        self.directory = directory
        filename = "diagnostics_\(DiagnosticsDate.dateTimeInFilename()).txt"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func append(_ level: String, _ message: String) {
        let date = DiagnosticsDate.logLineDate()
        lines.append("[\(date)] [\(level)] \(message)")
    }

    var text: String { lines.joined(separator: "\n") }
}

enum DiagnosticsDate {
    /// Desktop `dateTimeInFilename`: `d-M-yyyy_H-m-s-SSS` (month is 0-based, matching JS).
    static func dateTimeInFilename(date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.day, .month, .year, .hour, .minute, .second, .nanosecond], from: date)
        let ms = (c.nanosecond ?? 0) / 1_000_000
        return String(format: "%d-%d-%d_%d-%d-%d-%d",
                      c.day ?? 0, (c.month ?? 1) - 1, c.year ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0, ms)
    }

    /// electron-log line date: `yyyy-MM-dd HH:mm:ss.SSS`.
    static func logLineDate(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}

// MARK: - Step model (DiagnosticStep.ts + types/diagnostics.ts port)

struct DiagnosticStepResponse {
    var succeeded: Bool
    var message: String?
    var payload: Any?
}

struct DiagnosticStep {
    let name: String
    let retries: Int
    let run: (DiagnosticsLog) async -> DiagnosticStepResponse

    init(name: String, retries: Int = 0, run: @escaping (DiagnosticsLog) async -> DiagnosticStepResponse) {
        self.name = name
        self.retries = retries
        self.run = run
    }
}

/// One executed step's row in the report (desktop `DiagnosticsReportObject` + the duration that
/// `addDurationToFnReturnObject` attaches).
struct DiagnosticStepEntry: Codable, Equatable {
    let step: Int
    let name: String
    let succeeded: Bool
    let message: String?
    let durationMs: Int
    let payload: DiagValue?
}

// MARK: - Context

struct WebViewStatusItem: Equatable {
    var serverID: UUID
    var serverName: String
    var mounted: Bool
    var hasURL: Bool
    var hasPageError: Bool
    var isLoading: Bool
}

struct PermissionsSnapshot: Equatable {
    var notificationsStatus: String
    var downloadsWritable: Bool
    var diagnosticsWritable: Bool
    var microphoneStatus: String
    var cameraStatus: String
}

protocol DiagnosticsSystemStatusProviding {
    func permissionSnapshot(diagnosticsDirectory: URL) async -> PermissionsSnapshot
}

/// Session-cookie analog of desktop `session.defaultSession.cookies.get({})`. The real
/// provider reads the per-server WKWebsiteDataStore cookie jar; tests inject fixed snapshots.
protocol DiagnosticsSessionProviding {
    func sessionData(for server: ServerConfig) async -> SessionDataSnapshot
}

struct SessionDataSnapshot: Equatable {
    var hasUserID: Bool
    var hasCSRF: Bool
    var hasAuthToken: Bool
}

/// Reads MMUSERID / MMCSRF / MMAUTHTOKEN cookies from the server's isolated website-data store
/// (the same store the shell's webview session lives in).
struct WebKitCookieSessionProvider: DiagnosticsSessionProviding {
    func sessionData(for server: ServerConfig) async -> SessionDataSnapshot {
        let store = WKWebsiteDataStore(forIdentifier: server.id)
        let cookies = await store.httpCookieStore.allCookies()
        return SessionDataSnapshot(
            hasUserID: cookies.contains { $0.name == DiagnosticsConstants.cookieUserID },
            hasCSRF: cookies.contains { $0.name == DiagnosticsConstants.cookieCSRF },
            hasAuthToken: cookies.contains { $0.name == DiagnosticsConstants.cookieAuthToken }
        )
    }
}

/// Snapshot of the shell's persisted settings + identity, built on the main thread by the app
/// shell and handed to the (nonisolated) diagnostics runner.
struct ShellSettingsSnapshot: Equatable {
    var themeSyncing: Bool
    var downloadHistoryLimit: Int
    var appLanguage: String?
    var logLevel: String
    var appName: String
    var appVersion: String
    var buildNumber: String
}

/// Value-type context the diagnostics runner operates on. The app shell builds this on the
/// main actor (reading stores / webviews / vault); the runner never touches UI state.
struct DiagnosticsContext {
    var servers: [ServerConfig] = []
    var preferences: AppPreferences = AppPreferences()
    var vault: SecureVault = SecureVault()
    var settings: ShellSettingsSnapshot
    var webViewStatuses: [WebViewStatusItem] = []
    var systemStatusProvider: DiagnosticsSystemStatusProviding = SystemDiagnosticsStatus()
    var sessionProvider: DiagnosticsSessionProviding = WebKitCookieSessionProvider()
    var session: URLSession = .shared
    /// Injectable for localhost/offline testing; defaults to the desktop IS_ONLINE_ENDPOINT.
    var onlineEndpoint: URL = URL(string: DiagnosticsConstants.onlineEndpoint)!
    var diagnosticsDirectory: URL
    var crashReportsDirectory: URL
    var generatedAt: Date = Date()
}

/// The report exported by a run (mirrors desktop `DiagnosticsReport` + app metadata).
struct DiagnosticsReport: Codable, Equatable {
    var generatedAt: Date
    var appName: String
    var appVersion: String
    var buildNumber: String
    var steps: [DiagnosticStepEntry]
}

// MARK: - Service

/// Native counterpart of desktop `src/main/diagnostics/index.ts` (`DiagnosticsModule`).
struct DiagnosticsService {

    private let context: DiagnosticsContext
    private var steps: [DiagnosticStep] = []

    init(context: DiagnosticsContext) {
        self.context = context
        self.steps = Self.sortedSteps(context: context)
    }

    // MARK: Step set — desktop SORTED_STEPS order (step0..step11)

    static func sortedSteps(context: DiagnosticsContext) -> [DiagnosticStep] {
        var steps: [DiagnosticStep] = []
        steps.append(step0logConfig(context: context))
        steps.append(step1InternetConnection(context: context))
        steps.append(step2ConfigValidation(context: context))
        steps.append(step3ServerConnectivity(context: context))
        steps.append(step4SessionDataValidation(context: context))
        steps.append(step5BrowserWindows(context: context))
        steps.append(step6Permissions(context: context))
        steps.append(step7Performance(context: context))
        steps.append(step8LogHeuristics(context: context))
        steps.append(step9Config(context: context))
        steps.append(step10CrashReports(context: context))
        steps.append(step11Auth(context: context))
        return steps
    }

    /// Desktop `getStepCount()`
    var stepCount: Int { steps.count }

    /// Desktop `Diagnostics.run()` — execute every step in order, capture duration, return the
    /// shareable report. Never throws: a step failure is a report row, not a run failure.
    func run() async -> DiagnosticsReport {
        let log = DiagnosticsLog()
        var entries: [DiagnosticStepEntry] = []

        var index = 0
        for step in steps {
            let start = Date()
            let response = await step.run(log)
            let duration = Int(Date().timeIntervalSince(start) * 1000)
            entries.append(DiagnosticStepEntry(
                step: index,
                name: step.name,
                succeeded: response.succeeded,
                message: response.message,
                durationMs: duration,
                payload: response.payload.map { DiagValue.make(from: $0) }
            ))
            let status = response.succeeded ? "✓" : "✗"
            log.append(response.succeeded ? "info" : "warn", "[\(index)] \(step.name) -> \(status) (\(duration)ms) \(response.message ?? "")")
            index += 1
        }

        return DiagnosticsReport(
            generatedAt: context.generatedAt,
            appName: context.settings.appName,
            appVersion: context.settings.appVersion,
            buildNumber: context.settings.buildNumber,
            steps: entries
        )
    }

    // MARK: Report assembly (desktop `printReport` markdown + JSON export)

    /// Markdown report, port of the desktop `printReport` table + the log transcript details.
    func markdownReport(_ report: DiagnosticsReport, logText: String = "") -> String {
        var out = ""
        out += "#################### Mattermost iOS Diagnostics Report START ####################\n"
        out += "generatedAt: \(ISO8601DateFormatter().string(from: report.generatedAt))\n"
        out += "app: \(report.appName) \(report.appVersion) (\(report.buildNumber))\n"
        out += "\n| index | name | succeeded |\n"
        out += "| --- | --- | --- |\n"
        for row in report.steps {
            out += "| \(row.step) | \(row.name) | \(row.succeeded) |\n"
        }
        let ok = report.steps.filter(\.succeeded).count
        out += "| \(ok) out of \(report.steps.count) steps succeeded |\n"
        out += "\n## Step details\n"
        for row in report.steps {
            out += "\n### [\(row.step)] \(row.name) — \(row.succeeded ? "succeeded" : "FAILED") (\(row.durationMs)ms)\n"
            if let message = row.message, !message.isEmpty { out += "message: \(message)\n" }
            if let payload = row.payload {
                out += "payload: \(Self.jsonString(payload) ?? "{}")\n"
            }
        }
        if !logText.isEmpty {
            out += "\n## Diagnostics log\n\(logText)\n"
        }
        out += "#################### Mattermost iOS Diagnostics Report END ####################\n"
        return out
    }

    static func jsonEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// The decoder that reads what `jsonEncoder()` writes. `Date` must round-trip: the encoder
    /// emits ISO-8601 for humans reading the report, so the decoder has to match it (a default
    /// `JSONDecoder` expects a `timeIntervalSinceReferenceDate` Double and throws typeMismatch).
    static func jsonDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func jsonString(_ report: DiagnosticsReport) -> String? {
        guard let data = try? jsonEncoder().encode(report) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func jsonString(_ value: DiagValue) -> String? {
        guard let data = try? jsonEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Write the shareable report files (`diagnostics_<ts>.txt` markdown + `.json`).
    /// Returns the two URLs. Throws on filesystem failure (step0 already created the dir).
    func writeReportFiles(_ report: DiagnosticsReport, to directory: URL) throws -> (txt: URL, json: URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = "diagnostics_\(DiagnosticsDate.dateTimeInFilename(date: report.generatedAt))"
        let txtURL = directory.appendingPathComponent("\(base).txt")
        let jsonURL = directory.appendingPathComponent("\(base).json")
        let md = markdownReport(report, logText: "")
        try md.write(to: txtURL, atomically: true, encoding: .utf8)
        guard let json = Self.jsonString(report) else { throw DiagnosticsExportError.encodingFailed }
        try json.write(to: jsonURL, atomically: true, encoding: .utf8)
        return (txtURL, jsonURL)
    }

    enum DiagnosticsExportError: Error {
        case encodingFailed
    }

    // MARK: internal network helper — desktop `isOnline`

    /// GET `url` and require a JSON body with `{"status":"OK"}`. Transport errors (including
    /// offline) resolve to `false`; the step then reports failed exactly like the desktop.
    static func isOnline(url: URL, session: URLSession, logger: DiagnosticsLog? = nil) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, _) = try await session.data(for: request)
            guard !data.isEmpty,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger?.append("error", "isOnline: cannot parse response from \(url.absoluteString)")
                return false
            }
            if (body["status"] as? String) == "OK" {
                return true
            }
            logger?.append("debug", "isOnline: unexpected body from \(url.absoluteString)")
            return false
        } catch {
            logger?.append("error", "isOnline failed for \(url.absoluteString): \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Steps

private func okStep(_ message: String, payload: Any? = nil) -> DiagnosticStepResponse {
    DiagnosticStepResponse(succeeded: true, message: message, payload: payload)
}

private func failStep(_ message: String, payload: Any? = nil) -> DiagnosticStepResponse {
    DiagnosticStepResponse(succeeded: false, message: message, payload: payload)
}

extension DiagnosticsService {

    /// Step-0 logConfig: create the reports directory and configure the log filename.
    static func step0logConfig(context: DiagnosticsContext) -> DiagnosticStep {
        DiagnosticStep(name: "diagnostic-Step-0: logConfig") { log in
            do {
                try log.configure(directory: context.diagnosticsDirectory)
                log.append("debug", "ConfigureLogger \(log.filename) in \(context.diagnosticsDirectory.path)")
                return okStep("Step-0 finished successfully", payload: [
                    "directory": context.diagnosticsDirectory.path,
                    "filename": log.filename,
                ])
            } catch {
                log.append("warn", "Diagnostics Step-0 Failure \(error.localizedDescription)")
                return failStep("Step-0 failed", payload: error)
            }
        }
    }

    /// Step-1 internetConnection: desktop `IS_ONLINE_ENDPOINT` ping.
    static func step1InternetConnection(context: DiagnosticsContext) -> DiagnosticStep {
        DiagnosticStep(name: "diagnostic-Step-1: internetConnection") { log in
            let url = context.onlineEndpoint
            log.append("debug", "Checking internet connectivity via \(url.absoluteString)")
            let online = await isOnline(url: url, session: context.session, logger: log)
            if online {
                return okStep("Step-1 finished successfully")
            }
            return failStep("Step-1 failed")
        }
    }

    /// Step-2 configValidation: validate what the shell persists (desktop reads config.json and
    /// runs the Joi validator against it; iOS validates the decoded `[ServerConfig]`).
    static func step2ConfigValidation(context: DiagnosticsContext) -> DiagnosticStep {
        DiagnosticStep(name: "diagnostic-Step-2: configValidation") { log in
            do {
                let stored: [ServerConfig]? = context.preferences.get([ServerConfig].self,
                                                                      forKey: AppPreferences.Keys.servers)
                guard let stored else {
                    return okStep("Step-2 finished successfully", payload: ["configStored": false])
                }
                for server in stored {
                    if server.name.isEmpty || server.name.trimmingCharacters(in: .whitespaces).isEmpty {
                        throw NSError(domain: "Diagnostics", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "Config validation failed. Server has an empty name."])
                    }
                    guard server.url.scheme != nil, server.url.host != nil else {
                        throw NSError(domain: "Diagnostics", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "Config validation failed. Server \(server.name) has an invalid URL."])
                    }
                }
                log.append("debug", "Config validation ok for \(stored.count) server(s)")
                return okStep("Step-2 finished successfully", payload: [
                    "configStored": true,
                    "servers": stored.map { ["name": $0.name, "url": $0.url.absoluteString] },
                ])
            } catch {
                log.append("warn", "Diagnostics Step-2 Failure \(error.localizedDescription)")
                return failStep("Step-2 failed", payload: error)
            }
        }
    }

    /// Step-3 serverConnectivity: ping every configured server at `/api/v4/system/ping`.
    static func step3ServerConnectivity(context: DiagnosticsContext) -> DiagnosticStep {
        DiagnosticStep(name: "diagnostic-Step-3: serverConnectivity") { log in
            let servers = context.servers
            guard !servers.isEmpty else {
                return failStep("Step-3 failed", payload: ["message": "No servers configured"])
            }
            var results: [[String: Any]] = []
            for server in servers {
                guard !server.name.isEmpty, !server.url.absoluteString.isEmpty else {
                    results.append(["name": server.name, "error": "Invalid server configuration"])
                    continue
                }
                guard let pingURL = URL(string: "\(server.url.absoluteString)/api/v4/system/ping") else {
                    results.append(["name": server.name, "error": "Invalid server URL"])
                    continue
                }
                log.append("debug", "Pinging server \(server.url.absoluteString)")
                let online = await isOnline(url: pingURL, session: context.session, logger: log)
                results.append(["name": server.name, "online": online])
                if !online {
                    log.append("warn", "Server appears to be offline: \(server.url.absoluteString)")
                }
            }
            let allOnline = results.allSatisfy { ($0["online"] as? Bool) == true }
            if allOnline {
                return okStep("Step-3 finished successfully", payload: results)
            }
            return failStep("Step-3 failed", payload: results)
        }
    }

    /// Step-4 sessionDataValidation: desktop requires MMUSERID/MMCSRF/MMAUTHTOKEN cookies;
    /// iOS reads the same three cookie names from each server's isolated website-data store.
    static func step4SessionDataValidation(context: DiagnosticsContext) -> DiagnosticStep {
        DiagnosticStep(name: "diagnostic-Step-4: sessionDataValidation") { log in
            let servers = context.servers
            guard !servers.isEmpty else {
                log.append("error", "Step-4: No session data found (no servers configured)")
                return failStep("Step-4 failed", payload: ["message": "No cookies found"])
            }
            var checks: [[String: Any]] = []
            for server in servers {
                let data = await context.sessionProvider.sessionData(for: server)
                checks.append([
                    "server": server.name,
                    "userID": data.hasUserID,
                    "csrf": data.hasCSRF,
                    "authToken": data.hasAuthToken,
                ])
                if !data.hasUserID || !data.hasCSRF || !data.hasAuthToken {
                    log.append("error", "Step-4: Not all required cookies found for \(server.name)")
                }
            }
            // Desktop: fail when ANY required cookie is missing.
            let allPresent = checks.allSatisfy { ($0["userID"] as? Bool) == true && ($0["csrf"] as? Bool) == true && ($0["authToken"] as? Bool) == true }
            if allPresent {
                return okStep("Step-4 finished successfully", payload: checks)
            }
            return failStep("Step-4 failed", payload: checks)
        }
    }

    /// Step-5 BrowserWindowsChecks: per-server webview status (exists, url loaded, no page
    /// error, not loading) — the iOS analog of `browserWindowVisibilityStatus`+`webContentsCheck`.
    static func step5BrowserWindows(context: DiagnosticsContext) -> DiagnosticStep {
        DiagnosticStep(name: "diagnostic-Step-5: BrowserWindowsChecks") { log in
            let servers = context.servers
            let statuses = context.webViewStatuses
            guard !servers.isEmpty else {
                let payload: [String: Any] = ["message": "No servers configured", "webViewStatuses": []]
                return failStep("Step-5 failed", payload: payload)
            }
            var rows: [[String: Any]] = []
            for status in statuses {
                rows.append([
                    "server": status.serverName,
                    "mounted": status.mounted,
                    "hasURL": status.hasURL,
                    "pageError": status.hasPageError,
                    "loading": status.isLoading,
                ])
            }
            let allOk = statuses.allSatisfy {
                $0.mounted && $0.hasURL && !$0.hasPageError
            }
            if allOk {
                return okStep("Step-5 finished successfully", payload: rows)
            }
            log.append("warn", "Step-5: some webview checks failed")
            return failStep("Step-5 failed", payload: ["webViewStatuses": rows])
        }
    }

    /// Step-6 PermissionsCheck: notifications + file-system writability + media permissions.
    static func step6Permissions(context: DiagnosticsContext) -> DiagnosticStep {
        DiagnosticStep(name: "diagnostic-Step-6: PermissionsCheck") { log in
            do {
                let snapshot = await context.systemStatusProvider.permissionSnapshot(
                    diagnosticsDirectory: context.diagnosticsDirectory
                )
                let payload: [String: Any] = [
                    "notificationsSupported": snapshot.notificationsStatus != "not-determined",
                    "notificationsStatus": snapshot.notificationsStatus,
                    "fileSystem": [
                        "downloadsWritable": snapshot.downloadsWritable,
                        "diagnosticsWritable": snapshot.diagnosticsWritable,
                    ],
                    "mediaAccessStatus": [
                        "mic": snapshot.microphoneStatus,
                        "camera": snapshot.cameraStatus,
                    ],
                ]
                return okStep("Step-6 finished successfully", payload: payload)
            } catch {
                log.append("warn", "Diagnostics Step-6 Failure \(error.localizedDescription)")
                return failStep("Step-6 failed", payload: error)
            }
        }
    }

    /// Step-7 PerformanceAndMemory: process info, memory/CPU state, battery, identity.
    static func step7Performance(context: DiagnosticsContext) -> DiagnosticStep {
        DiagnosticStep(name: "diagnostic-Step-7: PerformanceAndMemory") { log in
            let info = ProcessInfo.processInfo
            let device = UIDevice.current
            let payload: [String: Any] = [
                "process": [
                    "systemUptime": info.systemUptime,
                    "activeProcessorCount": info.activeProcessorCount,
                    "processorCount": info.processorCount,
                    "physicalMemory": info.physicalMemory,
                    "thermalState": Self.thermalStateName(info.thermalState),
                    "systemVersion": info.operatingSystemVersionString,
                    "memoryFootprintBytes": Self.memoryFootprint(),
                    "lowPowerModeEnabled": info.isLowPowerModeEnabled,
                ],
                "device": [
                    "name": device.name,
                    "model": device.model,
                    "systemName": device.systemName,
                    "systemVersion": device.systemVersion,
                    "batteryLevel": device.batteryLevel >= 0 ? device.batteryLevel : nil,
                    "batteryState": Self.batteryStateName(device.batteryState),
                ],
                "locale": Locale.current.identifier,
                "timeZone": TimeZone.current.identifier,
                "generatedAt": ISO8601DateFormatter().string(from: context.generatedAt),
                "sentryDSNConfigured": SentryService.dsnConfigured(),
            ]
            return okStep("Step-7 finished successfully", payload: payload)
        }
    }

    /// Step-8 LogHeuristics: count log levels in the transcript + error percentage.
    static func step8LogHeuristics(context: DiagnosticsContext) -> DiagnosticStep {
        DiagnosticStep(name: "diagnostic-Step-8: LogHeuristics") { log in
            let counted = DiagnosticsLogCounter.countLevels(in: log.lines)
            let percentage = counted.linesCount > 0
                ? (Double(round((100.0 * Double(counted.logLevelAmounts["error"] ?? 0) / Double(counted.linesCount)) * 10) / 10))
                : 0.0
            let payload: [String: Any] = [
                "logLevels": counted.logLevelAmounts,
                "percentageOfErrors": percentage,
                "linesCount": counted.linesCount,
            ]
            return okStep("Step-8 finished successfully", payload: payload)
        }
    }

    /// Step-9 Config: dump the shell's persisted settings (sanitized).
    static func step9Config(context: DiagnosticsContext) -> DiagnosticStep {
        DiagnosticStep(name: "diagnostic-Step-9: Config") { _ in
            let s = context.settings
            let payload: [String: Any] = [
                "themeSyncing": s.themeSyncing,
                "downloadHistoryLimit": s.downloadHistoryLimit,
                "appLanguage": s.appLanguage ?? "system",
                "logLevel": s.logLevel,
                "appVersion": s.appVersion,
                "buildNumber": s.buildNumber,
                "serverCount": context.servers.count,
            ]
            return okStep("Step-9 finished successfully", payload: payload)
        }
    }

    /// Step-10 CrashReports: list uncaughtException-* files written by SentryService's handler.
    static func step10CrashReports(context: DiagnosticsContext) -> DiagnosticStep {
        DiagnosticStep(name: "diagnostic-Step-10: CrashReports") { log in
            do {
                let fm = FileManager.default
                let dir = context.crashReportsDirectory
                let allFiles = try fm.contentsOfDirectory(atPath: dir.path)
                let crashFiles = allFiles.filter { $0.hasPrefix("uncaughtException-") }.sorted()
                var data: [[String: String]] = []
                for fileName in crashFiles {
                    let full = dir.appendingPathComponent(fileName)
                    let contents = try String(contentsOf: full, encoding: .utf8)
                    data.append(["fileName": fileName, "data": contents])
                }
                let payload: [String: Any] = [
                    "pathOfCrashReports": dir.path,
                    "crashReportData": data,
                ]
                return okStep("Step-10 finished successfully", payload: payload)
            } catch {
                log.append("warn", "Diagnostics Step-10 Failure \(error.localizedDescription)")
                return failStep("Step-10 failed", payload: error)
            }
        }
    }

    /// Step-11 AuthSSO: per-server session metadata (cookie names presence only, never values),
    /// mirroring the desktop cookie-name/expiry dump.
    static func step11Auth(context: DiagnosticsContext) -> DiagnosticStep {
        DiagnosticStep(name: "diagnostic-Step-11: AuthSSO") { _ in
            var rows: [[String: Any]] = []
            for server in context.servers {
                let data = await context.sessionProvider.sessionData(for: server)
                rows.append([
                    "server": server.name,
                    "host": server.url.host ?? "",
                    "hasUserID": data.hasUserID,
                    "hasCSRF": data.hasCSRF,
                    "hasAuthToken": data.hasAuthToken,
                    "sessionFlag": server.hasSession,
                ])
            }
            return okStep("Step-11 finished successfully", payload: ["sessionData": rows])
        }
    }

    // MARK: small helpers

    static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func batteryStateName(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unknown: return "unknown"
        case .unplugged: return "unplugged"
        case .charging: return "charging"
        case .full: return "full"
        @unknown default: return "unknown"
        }
    }

    static func memoryFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int64(info.phys_footprint)
    }
}

/// Counts desktop-style log levels over a list of lines (utils.ts `countLogLevels`).
enum DiagnosticsLogCounter {
    static func countLevels(in lines: [String]) -> (logLevelAmounts: [String: Int], linesCount: Int) {
        var amounts = ["silly": 0, "debug": 0, "verbose": 0, "info": 0, "warn": 0, "error": 0]
        var linesCount = 0
        guard let regex = try? NSRegularExpression(pattern: DiagnosticsConstants.regexLogFileLine, options: [.caseInsensitive]) else {
            return (amounts, linesCount)
        }
        for line in lines {
            let ns = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, options: [], range: ns), match.numberOfRanges >= 3 else { continue }
            linesCount += 1
            let levelRange = match.range(at: 2)
            if let levelRange = Range(levelRange, in: line) {
                let level = String(line[levelRange]).lowercased()
                if amounts[level] != nil { amounts[level]! += 1 }
            }
        }
        return (amounts, linesCount)
    }
}

/// Real system status provider (notifications via UNUserNotificationCenter, media via
/// AVFoundation, file-system via FileManager). Injected into types in tests.
struct SystemDiagnosticsStatus: DiagnosticsSystemStatusProviding {
    func permissionSnapshot(diagnosticsDirectory: URL) async -> PermissionsSnapshot {
        var notifications = "not-determined"
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: notifications = "granted"
        case .denied: notifications = "denied"
        case .notDetermined: notifications = "not-determined"
        case .ephemeral: notifications = "granted"
        @unknown default: notifications = "not-determined"
        }

        let fm = FileManager.default
        let downloadsOK = fm.isWritableFile(atPath: URL.downloadsDirectory.path)
        let diagOK = fm.isWritableFile(atPath: diagnosticsDirectory.path)

        return PermissionsSnapshot(
            notificationsStatus: notifications,
            downloadsWritable: downloadsOK,
            diagnosticsWritable: diagOK,
            microphoneStatus: Self.mediaStatus(for: .audio),
            cameraStatus: Self.mediaStatus(for: .video)
        )
    }

    private static func mediaStatus(for mediaType: AVMediaType) -> String {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not-determined"
        @unknown default: return "not-determined"
        }
    }
}
