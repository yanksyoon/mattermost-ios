import Foundation
import Combine
import WebKit
import UIKit

/// Native counterpart of the desktop `src/main/downloadsManager.ts`. Parity row:
/// `downloadsManager` -> `DownloadWorker` (`URLSessionDownloadTask` into the app
/// `Documents/Downloads` directory, `WKDownloadDelegate` for webview-initiated files,
/// persistent download journal, and a Share-to-Files export via `UIDocumentPicker`).
/// Status: native, Phase 2.
///
/// Two download entry points converge here so every byte the shell moves is journaled:
///
///  1. **Shell-initiated** — `download(url:)` starts a `URLSessionDownloadTask` on the
///     worker's own `URLSession` (so it can be the session download delegate and observe
///     `didFinishDownloadingTo` / `didWriteData`). Files land in `URL.downloadsDirectory`.
///  2. **Webview-initiated** — the worker's `DownloadFlow` *is* a `WKDownloadDelegate`: when a
///     download is produced for the embedded web app (attachments, <a download> files), its
///     `.delegate` is set to the flow, which decides the Downloads destination and journals the
///     finish/failure.
///
/// Security boundary: like the desktop download manager, this never exposes local filesystem
/// paths to page JS — a `WKDownloadDelegate` only ever receives a destination *we* choose, and
/// `Bridge`/`window.desktop` stays out of the Downloads directory.
///
/// Layering note: `DownloadWorker` itself is Combine's `ObservableObject` so it can be an app
/// `@StateObject` (mounted once, injected app-wide), while the actual protocol implementations
/// (`URLSessionDownloadDelegate` + `WKDownloadDelegate`) live on the nested `DownloadFlow`,
/// an `NSObject` — Combine's `ObservableObject` cannot itself satisfy an `NSObjectProtocol`.
@MainActor
final class DownloadWorker: ObservableObject {

    /// The persistent journal (newest-first) the DownloadsView binds to.
    let history: DownloadHistory

    /// The transfer engine: owns the download `URLSession` and the webview download delegate,
    /// and journals every move into `history`. `lazy` so it can capture `self` (its `owner`
    /// back-reference) only after this worker is fully initialised.
    lazy var flow: DownloadFlow = DownloadFlow(owner: self)

    init(history: DownloadHistory) {
        self.history = history
    }

    /// Begin downloading `url` into the app Downloads directory and journal it. Returns the
    /// in-flight record so callers can observe progress or cancel it by id.
    @discardableResult
    func download(url: URL) -> DownloadRecord {
        flow.startDownload(url: url)
    }

    /// Cancel an in-flight download; the task's completion flips the record to `.cancelled`.
    func cancel(id: UUID) {
        flow.cancel(id: id)
    }

    /// Re-issue a failed / cancelled / wait-to-retry download by its journal record.
    @discardableResult
    func retry(_ record: DownloadRecord) -> DownloadRecord? {
        flow.retry(record)
    }

    // MARK: Share / move into the Files app

    /// Build an export document-picker for a landed file, so the user can move/copy it out of
    /// the app Downloads directory into the Files app (desktop popout context-menu "Share" /
    /// "Open in Files"). `asCopy: false` (default) *moves* the original rather than duplicating
    /// it, per the UIKit recommendation; the picker reports the new location via
    /// `didPickDocuments(atURLs:)`. Returns nil when the record has no landed file to export.
    func exportPicker(for record: DownloadRecord, asCopy: Bool = false) -> UIDocumentPickerViewController? {
        guard record.state == .done, let target = record.targetURL else {
            Logger.debug("DownloadWorker", "no landed file to export for \(record.id)")
            return nil
        }
        let picker = UIDocumentPickerViewController(forExporting: [target], asCopy: asCopy)
        // Root the picker at Downloads so "the file we just downloaded" is the obvious starting
        // point, mirroring the desktop share sheet opening the downloads folder.
        picker.directoryURL = URL.downloadsDirectory
        picker.allowsMultipleSelection = false
        return picker
    }

    // MARK: Journal passthroughs

    /// Shortcut for `history.remove(id:)` used by the DownloadsView delete affordance.
    func remove(id: UUID) { history.remove(id: id) }
    /// Shortcut for clearing completed/cancelled/failed rows.
    func clearFinished() { history.clearFinished() }

    // MARK: Pure filename & destination helpers (unit-testable)

    /// Reduce an arbitrary suggested filename to a safe basename: trim surrounding whitespace
    /// and keep only the final path component, so a server-injected `../../x/y` collapses to
    /// `y` and can never escape the Downloads directory. Falls back to `download` when nothing
    /// usable remains.
    static func sanitizedFilename(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.contains("/") { name = Self.rawLastComponent(of: name, separator: "/") }
        if name.contains("\\") { name = Self.rawLastComponent(of: name, separator: "\\") }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "download" }
        return name
    }

    /// The final path component of `value` split on `separator` (a `SubSequence`, -> `String`).
    /// Empty when `value` has no component at all (e.g. `"////"`), so the caller's fallback applies.
    private static func rawLastComponent(of value: String, separator: String) -> String {
        value.split(separator: separator).last.map(String.init) ?? ""
    }

    /// Pick a non-colliding file name for `base` against the names already in `existing`:
    /// `report.pdf` -> `report (2).pdf`, `report (3).pdf`, … The first free name is returned
    /// (desktop download-dedup behaviour).
    static func uniqueFilename(_ base: String, existing: [String]) -> String {
        if !existing.contains(base) { return base }
        var stem = base
        var ext = ""
        if let dot = base.lastIndex(of: "."), dot > base.startIndex {
            stem = String(base[..<dot])
            if let last = base.split(separator: ".").last { ext = "." + String(last) }
        }
        var n = 2
        while true {
            let candidate = "\(stem) (\(n))\(ext)"
            if !existing.contains(candidate) { return candidate }
            n += 1
        }
    }

    /// The full `file://` URL a download named `suggestedFilename` should land under in
    /// `directory`, deduplicated against `existingNames`.
    static func resolveDestination(for suggestedFilename: String, in directory: URL,
                                   existingNames: [String]) -> URL {
        let name = Self.uniqueFilename(Self.sanitizedFilename(suggestedFilename),
                                       existing: existingNames)
        return directory.appendingPathComponent(name)
    }

    // MARK: DownloadFlow — the NSObject that implements the Foundation/WebKit download protocols

    final class DownloadFlow: NSObject, URLSessionDownloadDelegate, WKDownloadDelegate {
        /// Back-reference to the observable worker that owns the journal and public API.
        weak var owner: DownloadWorker?

        /// A dedicated session with this flow as its download delegate, so shell-initiated
        /// `URLSessionDownloadTask`s report progress/completion without disturbing
        /// `URLSession.shared`. `lazy` because `URLSession(configuration:delegate:self)` uses
        /// `self` as the delegate and can only run after `super.init()`.
        lazy var session: URLSession = URLSession(configuration: URLSessionConfiguration.default,
                                                  delegate: self,
                                                  delegateQueue: nil)
        /// Maps an in-flight session download task to its journal record id.
        var activeTasks = Dictionary<URLSessionDownloadTask, UUID>()
        /// Maps an in-flight webview download to its journal record id.
        var activeDownloads = Dictionary<WKDownload, UUID>()

        init(owner: DownloadWorker) {
            self.owner = owner
        }

        // MARK: Shell-initiated downloads

        @discardableResult
        func startDownload(url: URL) -> DownloadRecord {
            var record = DownloadRecord(
                filename: DownloadWorker.sanitizedFilename(url.lastPathComponent),
                source: url.absoluteString)
            owner?.history.add(record)

            let request = URLRequest(url: url)
            let task = session.downloadTask(with: request)
            activeTasks[task] = record.id
            Logger.info("DownloadWorker", "started download \(url.absoluteString)")
            return record
        }

        func cancel(id: UUID) {
            guard owner?.history.find(id: id)?.state == .downloading else { return }
            for task in activeTasks.keys {
                if activeTasks[task] == id {
                    task.cancel()
                    break
                }
            }
        }

        @discardableResult
        func retry(_ record: DownloadRecord) -> DownloadRecord? {
            guard let source = URL(string: record.source) else {
                Logger.info("DownloadWorker", "no source to retry for \(record.filename)")
                return nil
            }
            var next = record
            next.state = .downloading
            next.receivedBytes = 0
            next.totalBytes = 0
            next.finishedAt = nil
            owner?.history.update(next)

            let request = URLRequest(url: source)
            let task = session.downloadTask(with: request)
            activeTasks[task] = next.id
            return next
        }

        // MARK: URLSessionDownloadDelegate (shell-initiated task callbacks)

        func urlSession(_ session: URLSession, downloadTask task: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            guard let id = activeTasks.removeValue(forKey: task),
                  let record = owner?.history.find(id: id) else { return }
            var next = record
            next.destination = landing(for: record).absoluteString
            next.state = .done
            next.finishedAt = Date()
            owner?.history.update(next)
            Logger.info("DownloadWorker", "finished \(record.filename) -> \(next.destination)")
        }

        func urlSession(_ session: URLSession, downloadTask task: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard let id = activeTasks[task], let record = owner?.history.find(id: id) else { return }
            var next = record
            next.receivedBytes = totalBytesWritten
            next.totalBytes = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : record.totalBytes
            owner?.history.update(next)
        }

        // MARK: WKDownloadDelegate (webview-initiated downloads)

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            // The downloadable file is written where we decide — never under the webview's
            // control. Deduplicate against the names already in the journal so a re-download of
            // the same filename collides into "file (2).ext" instead of silently overwriting.
            let dest = DownloadWorker.resolveDestination(
                for: suggestedFilename,
                in: URL.downloadsDirectory,
                existingNames: journalFileNames)
            var record = DownloadRecord(
                filename: DownloadWorker.sanitizedFilename(dest.lastPathComponent),
                source: "",
                destination: dest.absoluteString)
            owner?.history.add(record)
            activeDownloads[download] = record.id
            completionHandler(dest)
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let id = activeDownloads.removeValue(forKey: download),
                  let record = owner?.history.find(id: id) else { return }
            var next = record
            next.state = .done
            next.finishedAt = Date()
            owner?.history.update(next)
            Logger.info("DownloadWorker", "webview download finished \(record.filename)")
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            guard let id = activeDownloads.removeValue(forKey: download),
                  let record = owner?.history.find(id: id) else { return }
            var next = record
            next.state = resumeData == nil ? .error : .waitToRetry
            next.finishedAt = Date()
            owner?.history.update(next)
            Logger.error("DownloadWorker", "download failed \(record.filename): \(error.localizedDescription)")
        }

        // MARK: Local helpers

        /// Where a finished task's file should land, deduplicated against the journal so a
        /// second download of the same name doesn't overwrite the first.
        private func landing(for record: DownloadRecord) -> URL {
            DownloadWorker.resolveDestination(for: record.filename, in: URL.downloadsDirectory,
                                             existingNames: journalFileNames)
        }

        /// File names already in the journal (used to keep downloads from overwriting each other).
        private var journalFileNames: [String] {
            owner?.history.records.compactMap { $0.filename } ?? []
        }
    }
}