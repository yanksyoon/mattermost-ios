import Foundation

/// Lifecycle of a single file download — native counterpart of the states tracked by the
/// desktop `downloadsManager.ts` (`DownloadItem.state`: `downloading`, `done`, `cancelled`,
/// `waitToRetry`, `error`). Parity row: `DownloadsManager` -> `DownloadWorker` +
/// `DownloadRecord`. Status: native, Phase 2.
public enum DownloadState : Int, CaseIterable, Codable {
    /// The task is actively transferring bytes to the local Downloads directory.
    case downloading = 0
    /// The file has been fully written under the app's Downloads directory.
    case done = 1
    /// The user cancelled it before completion.
    case cancelled = 2
    /// It failed transiently and can be retried (desktop `waitToRetry` → the Retry button).
    case waitToRetry = 3
    /// It failed and is not retryable.
    case error = 4
}

/// One row of the persistent download journal — native counterpart of the desktop
/// `DownloadItem` (`downloadsManager.ts`) plus the renderer `DownloadsDropdown` row model.
///
/// Codable so the whole history journal round-trips through `AppPreferences`/`UserDefaults`
/// exactly like the desktop `JsonFileManager` persisted the downloads list; `Equatable`/
/// `Hashable` so downloads can be compared and keyed by identity in tests and the UI.
public struct DownloadRecord : Codable, Equatable, Hashable, Identifiable {

    /// Stable per-download identity (desktop uses an incrementing id in-memory; we persist).
    public var id: UUID
    /// The user-facing file name (basename) the download lands under in Downloads.
    public var filename: String
    /// Where the bytes came from, as an absolute URL string. Empty when the origin is unknown
    /// (e.g. a webview blob download that only carries a suggested filename).
    public var source: String
    /// The local `file://` URL (as a string) of the landed file under Downloads. Empty until
    /// the download reaches a terminal state with the file on disk.
    public var destination: String
    public var state: DownloadState
    public var totalBytes: Int64
    public var receivedBytes: Int64
    public var startedAt: Date
    /// When the download reached a terminal state (`done`/`cancelled`/`error`).
    public var finishedAt: Date?

    public init(id: UUID = UUID(),
                filename: String = "",
                source: String = "",
                destination: String = "",
                state: DownloadState = .downloading,
                totalBytes: Int64 = 0,
                receivedBytes: Int64 = 0,
                startedAt: Date = Date(),
                finishedAt: Date? = nil) {
        self.id = id
        self.filename = filename
        self.source = source
        self.destination = destination
        self.state = state
        self.totalBytes = totalBytes
        self.receivedBytes = receivedBytes
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// The landed file as a `file://` URL once the download is on disk; `nil` until then.
    /// Convenience for callers (export-to-Files, share) that need a real `URL`, whereas the
    /// Codable field stores the string form.
    public var targetURL: URL? {
        guard !destination.isEmpty else { return nil }
        return URL(string: destination)
    }
}